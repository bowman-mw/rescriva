//
//  Rebuilder.swift
//  Rescriva (fork of Open Scanner)
//
//  Turns a scan's pages into a RescrivaDocument, on the phone:
//    tier 1 — Vision's document reader (iOS 26) for paragraphs, lists and
//             tables, plus the plan's heuristics (line height → heading,
//             leading dashes → bullets, boxes → checkboxes);
//    tier 2 — Apple Intelligence re-ranks the readings of uncertain words on
//             Smart-tier iPhones;
//    tier 3 — bundled Core ML models for diagrams and equations are not
//             shipped yet, so those regions stay in the page image.
//  Every tier also finds each page's photos and charts as figures, with their
//  captions (FigureDetector, FigurePlacement), marks bold, italic, underlined
//  and struck-through words on typed pages (StyleDetector, StylePlacement),
//  and samples its background, accent palette and clearly coloured text
//  (PageColorSampler). Pages with columns read down each column in turn
//  (ReadingOrder). Uncertain words become flags for the review screen.
//

import Foundation
import CoreData
import ImageIO
import UIKit
import Vision

/// The steps the Rebuilding screen shows.
enum RebuildStage: Int, CaseIterable, Comparable {
	case reading, structure, ordering, checking

	static func < (lhs: RebuildStage, rhs: RebuildStage) -> Bool { lhs.rawValue < rhs.rawValue }

	/// Stages for this tier and document, in order.
	static func stages(for tier: DeviceTier, document: RescrivaDocument?) -> [RebuildStage] {
		tier == .smart ? [.reading, .structure, .ordering, .checking] : [.reading, .structure, .ordering]
	}

	/// Step label; mentions the equation and diagram when the document has them.
	func label(for document: RescrivaDocument?) -> String {
		let blocks = document?.pages.flatMap(\.blocks) ?? []
		let hasEquation = blocks.contains { if case .equation = $0.content { return true }; return false }
		let hasDiagram = blocks.contains { if case .diagram = $0.content { return true }; return false }
		switch self {
		case .reading:
			return String(localized: "Reading every word")
		case .structure:
			return hasEquation ? String(localized: "Finding headings, lists and the equation") : String(localized: "Finding headings, lists and tables")
		case .ordering:
			return hasDiagram ? String(localized: "Rebuilding the diagram as shapes") : String(localized: "Putting everything in reading order")
		case .checking:
			return String(localized: "Double-checking with Apple Intelligence")
		}
	}
}

/// How far a rebuild has got: its step and, in the steps that go a page or a word at a time, how
/// many of them are done (0 of 0 when the step isn't counted).
struct RebuildProgress: Equatable, Sendable {
	var stage: RebuildStage
	var done = 0
	var total = 0

	/// "Page 12 of 54" or "Word 40 of 126"; nil when the step isn't counted.
	var detail: String? {
		guard total > 0 else { return nil }
		let current = min(done + 1, total)
		switch stage {
		case .reading: return String(localized: "Reading page \(current) of \(total)")
		case .structure: return String(localized: "Page \(current) of \(total)")
		case .ordering: return nil
		case .checking: return String(localized: "Word \(current) of \(total)")
		}
	}
}

/// Builds and caches the rebuilt document for a scan. The rebuild itself (`build`) works from a
/// value copy of the scan (`ScanSnapshot`) and never touches Core Data; `document(for:)` and
/// `refreshStalePages(of:)` are the thin wrappers that read the scan's pages and write its
/// document back.
@MainActor
struct Rebuilder {
	let tier: DeviceTier

	/// Returns the scan's document, rebuilding only what changed since the last rebuild: nothing
	/// when its pages are the same; just the pages re-made since (`refreshStalePages`), so every
	/// other page keeps its Review work; or the whole document when pages were added, removed or
	/// moved. `progress` is called as each stage starts and, in the counted stages, as each page or
	/// word is done. A document a newer Rescriva wrote (`Scan.rebuiltDocumentState`) is left as it
	/// is: the document returned is built afresh and never cached over it (`mayCache`).
	func document(for scan: Scan, progress: @escaping @MainActor (RebuildProgress) -> Void) async -> RescrivaDocument {
		let captureIDs = scan.capturesArray.compactMap(\.id)
		if let existing = scan.rebuiltDocument, existing.sourceCaptureIDs == captureIDs {
			guard existing.hasStalePages else {
				for stage in RebuildStage.stages(for: tier, document: existing) {
					progress(RebuildProgress(stage: stage))
				}
				return existing
			}
			if let refreshed = await refreshStalePages(of: scan, progress: progress) {
				return refreshed
			}
		}
		return await rebuildWhole(scan, progress: progress)
	}

	/// Rebuilds every page and caches the document, unless the scan changed meanwhile (`mayCache`)
	/// or the rebuild was cancelled, which leaves pages unbuilt.
	private func rebuildWhole(_ scan: Scan, progress: @escaping @MainActor (RebuildProgress) -> Void) async -> RescrivaDocument {
		let startingData = scan.rebuiltData
		await recognizeMissingText(in: scan.capturesArray, progress: progress)
		let snapshot = Self.snapshot(of: scan, pages: scan.capturesArray)
		let document = await build(snapshot, progress: progress)

		// A page re-made while this ran (PageReprocessor) holds new pixels under the same capture id:
		// caching this document, built from the old ones, would hand it back for good. And a document
		// written meanwhile for these pages (a re-made page spliced in, Review edits) must not be lost.
		guard !Task.isCancelled, Self.mayCache(snapshot.pages, captureIDs: snapshot.captureIDs, startedWith: startingData, of: scan)
		else { return document }
		Self.store(document, on: scan)
		return document
	}

	/// Builds the document for `snapshot`, touching nothing but the snapshot: each page through its
	/// passes (`buildPages`), then the steps over the whole (`finishing`). Once cancelled, the pages
	/// left come back empty, one per snapshot page. The main actor is for the spelling checker,
	/// Apple Intelligence and `progress`; the passes run off it.
	func build(_ snapshot: ScanSnapshot, progress: @escaping @MainActor (RebuildProgress) -> Void = { _ in }) async -> RescrivaDocument {
		progress(RebuildProgress(stage: .structure, total: snapshot.pages.count))
		let built = await buildPages(snapshot.pages, source: snapshot.source, output: snapshot.output) { done in
			progress(RebuildProgress(stage: .structure, done: done, total: snapshot.pages.count))
		}
		return await finishing(RescrivaDocument(title: snapshot.title, pages: built, sourceCaptureIDs: snapshot.captureIDs),
							   pages: snapshot.pages, progress: progress)
	}

	/// Writes `document` back as the scan's and lets go of the figure pictures only the old one used.
	private static func store(_ document: RescrivaDocument, on scan: Scan) {
		scan.rebuiltDocument = document
		scan.lastUpdate = Date()
		scan.managedObjectContext?.saveQuietly()
		FigureAssets.prune(scan)
	}

	/// The steps each page goes through, a page at a time so a long document shows steady progress
	/// (`pageDone`, with how many are built): read for structure, then (Smart tier) diagrams and
	/// equations, then pictures (and reading order again with them), then type styles, then
	/// colours. Each page's pixels are decoded once, here, for every pass (`PageSnapshot.image`)
	/// and let go before the next page's. Diagrams are numbered as figures from 1 within `pages`.
	/// Once cancelled, the pages left come back empty: one page per snapshot, never cached
	/// (`rebuildWhole`).
	private func buildPages(_ pages: [PageSnapshot], source: PageSource, output: OutputKind,
							pageDone: @MainActor (Int) -> Void = { _ in }) async -> [RescrivaPage] {
		var built: [RescrivaPage] = []
		var diagramsSoFar = 0
		for stored in pages {
			guard !Task.isCancelled else {
				built.append(RescrivaPage(source: source))
				continue
			}
			let page = await stored.decodingImage()
			var single = [await Self.buildPage(page, source: source, output: output)]
			if tier == .smart {
				single = await Self.detectDiagrams(in: single, pages: [page], numberingAfter: diagramsSoFar)
				diagramsSoFar += single.map(PageSplice.diagramCount).reduce(0, +)
				single = await Self.detectEquations(in: single, lines: [page.lines])
			}
			single = await Self.detectFigures(in: single, pages: [page])
			single = Self.orderingPictures(in: single, pages: [page])
			single = await Self.detectStyles(in: single, pages: [page])
			built += await Self.sampleColors(in: single, pages: [page])
			pageDone(built.count)
		}
		assert(built.count == pages.count, "one built page per snapshot")
		return built
	}

	/// The steps over the built document: word flags refined, (Smart tier) re-ranked by Apple
	/// Intelligence, and each page's OCR text fingerprinted.
	private func finishing(_ document: RescrivaDocument, pages: [PageSnapshot],
						   progress: @escaping @MainActor (RebuildProgress) -> Void) async -> RescrivaDocument {
		assert(document.pages.count == pages.count, "one built page per snapshot")
		progress(RebuildProgress(stage: .ordering))
		var result = Self.refineWordFlags(document)
		if tier == .smart {
			progress(RebuildProgress(stage: .checking))
			result = await AppleIntelligence.rerankFlags(in: result) { done, total in
				progress(RebuildProgress(stage: .checking, done: done, total: total))
			}
		}
		return Self.recordingSourceText(of: pages, in: result)
	}

	// MARK: Re-made pages

	/// Rebuilds each page of the scan's cached document that was re-made since the rebuild, once it
	/// has been read again, through the same steps as a whole rebuild, and splices it in
	/// (`PageSplice`): every other page keeps its content and Review work. Returns the cached
	/// document afterwards (a page still being read, or re-made again meanwhile, stays stale for
	/// its own refresh), or nil when the scan has no cached document for its current pages.
	@discardableResult
	func refreshStalePages(of scan: Scan, progress: @escaping @MainActor (RebuildProgress) -> Void = { _ in }) async -> RescrivaDocument? {
		guard !scan.isDeleted, let cached = scan.rebuiltDocument,
			  cached.sourceCaptureIDs == scan.capturesArray.compactMap(\.id) else { return nil }
		let stale = cached.staleCaptureIDs ?? []
		guard !stale.isEmpty else { return cached }
		await recognizeMissingText(in: scan.capturesArray.filter { capture in capture.id.map { stale.contains($0) } ?? false },
								   progress: progress)
		for captureID in stale {
			await refreshPage(captureID, of: scan, progress: progress)
		}
		let refreshed = scan.rebuiltDocument
		return refreshed?.sourceCaptureIDs == scan.capturesArray.compactMap(\.id) ? refreshed : nil
	}

	/// Rebuilds one re-made page and splices it into the scan's document as it is by then. Skipped
	/// while the page is still being read; dropped when it was re-made again while it was built
	/// (`isCurrent`), or another refresh spliced it first (`PageSplice.splicing`), and when cancelled.
	private func refreshPage(_ captureID: UUID, of scan: Scan, progress: @escaping @MainActor (RebuildProgress) -> Void) async {
		guard let capture = scan.capturesArray.first(where: { $0.id == captureID }),
			  !RecognitionTracker.shared.isReading(capture) else { return }
		let snapshot = Self.snapshot(of: scan, pages: [capture])
		let single = await build(snapshot, progress: progress)
		guard !Task.isCancelled, let page = snapshot.pages.first, let rebuilt = single.pages.first,
			  Self.isCurrent(page, captureID: captureID, of: scan),
			  let document = scan.rebuiltDocument,
			  let spliced = PageSplice.splicing(rebuilt, for: captureID, into: document,
												captureIDs: scan.capturesArray.compactMap(\.id)) else { return }
		Self.store(spliced, on: scan)
	}

	/// `document` with each page's OCR text fingerprinted (`TextLayerReconciler.digest`), so the
	/// PDF text layer can tell when lines were edited or deleted after this rebuild.
	nonisolated static func recordingSourceText(of pages: [PageSnapshot], in document: RescrivaDocument) -> RescrivaDocument {
		assert(document.pages.count == pages.count, "one rebuilt page per scan page")
		var result = document
		for index in result.pages.indices {
			guard let page = pages[safe: index] else { continue }
			result.pages[index].sourceTextDigest = TextLayerReconciler.digest(of: page.lines)
		}
		return result
	}

	/// True when the scan still has the pages `pages` was copied from: the same captures, holding
	/// the same pixels. (Lines edited meanwhile don't count: an edit after a rebuild never
	/// invalidates it either, and the text layer checks each page's fingerprint itself.)
	static func isCurrent(_ pages: [PageSnapshot], captureIDs: [UUID], of scan: Scan) -> Bool {
		guard !scan.isDeleted, scan.managedObjectContext != nil else { return false }
		let captures = scan.capturesArray
		guard captures.count == pages.count, captures.compactMap(\.id) == captureIDs else { return false }
		return zip(captures, pages).allSatisfy { capture, page in capture.imageData == page.imageData }
	}

	/// True when the scan still has `captureID`, holding the pixels `page` was copied from.
	static func isCurrent(_ page: PageSnapshot, captureID: UUID, of scan: Scan) -> Bool {
		guard !scan.isDeleted, scan.managedObjectContext != nil,
			  let capture = scan.capturesArray.first(where: { $0.id == captureID }) else { return false }
		return capture.imageData == page.imageData
	}

	/// True when a whole rebuild of `pages`, begun while the scan held `startingData`, may cache its
	/// document: the pages are still the scan's (`isCurrent`), the scan's document isn't one only a
	/// newer Rescriva can read (kept for it), and no document for these pages was written since the
	/// rebuild began (a re-made page spliced in, Review edits, another rebuild), which caching
	/// would overwrite.
	static func mayCache(_ pages: [PageSnapshot], captureIDs: [UUID], startedWith startingData: Data?, of scan: Scan) -> Bool {
		guard isCurrent(pages, captureIDs: captureIDs, of: scan), !scan.rebuiltDocumentState.needsNewerApp else { return false }
		return scan.rebuiltData == startingData || scan.rebuiltDocument?.sourceCaptureIDs != captureIDs
	}

	/// Runs OCR on `captures` that don't have text yet (and aren't already being read), counting
	/// them off in `progress`, then waits for each one being read elsewhere to be done
	/// (`RecognitionTracker.waitUntilRead`; a cancelled rebuild stops waiting).
	private func recognizeMissingText(in captures: [ScanCapture], progress: @MainActor (RebuildProgress) -> Void) async {
		let unread = captures.filter { $0.recognizedItemsArray.isEmpty }
		progress(RebuildProgress(stage: .reading, total: unread.count))
		for (index, capture) in unread.enumerated() where !Task.isCancelled && capture.recognizedItemsArray.isEmpty && !RecognitionTracker.shared.isReading(capture) {
			guard let image = capture.image else { continue }
			await PageOCR.process(capture, image: image)
			progress(RebuildProgress(stage: .reading, done: index + 1, total: unread.count))
		}
		for capture in captures where !Task.isCancelled {
			await RecognitionTracker.shared.waitUntilRead(capture)
		}
	}

	// MARK: Snapshots

	/// What a rebuild needs from a scan, copied off Core Data: `build` works from this alone.
	struct ScanSnapshot: Sendable {
		var title: String
		var source: PageSource
		var output: OutputKind
		/// The captures the pages were copied from, in order (`RescrivaDocument.sourceCaptureIDs`).
		var captureIDs: [UUID]
		var pages: [PageSnapshot]
	}

	/// What the rebuild needs from one page, copied off Core Data, plus its pixels once decoded.
	struct PageSnapshot: Sendable {
		var imageData: Data?
		var lines: [RecognizedLine]
		var aspect: Double
		/// The page decoded from `imageData` by `decodingImage`, the one decode a rebuild makes of
		/// it; nil until then, and for data that doesn't decode.
		var image: CGImage? = nil

		/// The snapshot with its page decoded, off the main actor, for every pass to read.
		nonisolated func decodingImage() async -> PageSnapshot {
			guard image == nil, let imageData else { return self }
			var decoded = self
			decoded.image = Rebuilder.decodedPage(imageData)
			return decoded
		}

		/// The page for a pass to read: the one decoded for the rebuild, or, for a snapshot made by
		/// hand (as tests do), decoded now.
		var decodedImage: CGImage? {
			image ?? imageData.flatMap(Rebuilder.decodedPage)
		}
	}

	/// What the rebuild needs from the scan and the pages `captures` (its own, in order), copied
	/// off Core Data.
	static func snapshot(of scan: Scan, pages captures: [ScanCapture]) -> ScanSnapshot {
		ScanSnapshot(title: scan.displayTitle, source: scan.pageSource ?? .typed, output: scan.output,
					 captureIDs: captures.compactMap(\.id), pages: captures.map(snapshot(of:)))
	}

	/// What the rebuild needs from one capture, copied off Core Data.
	static func snapshot(of capture: ScanCapture) -> PageSnapshot {
		PageSnapshot(imageData: capture.imageData, lines: capture.recognizedItemsArray.map(\.recognizedLine),
					 aspect: Double(capture.thumbnail?.aspectRatio ?? 0.75))
	}

	/// The page's pixels as stored, decoded now rather than on first draw, so the one decode is
	/// shared: Vision reads it and each detector draws it to its own working size. No EXIF turn, so
	/// the pixels line up with the boxes Vision read off the same unturned image.
	nonisolated static func decodedPage(_ data: Data) -> CGImage? {
		guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
		let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
		return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
	}

	/// Builds one page: Vision's document reader when available, heuristics otherwise (and when
	/// the reader fails, which is logged).
	nonisolated static func buildPage(_ page: PageSnapshot, source: PageSource, output: OutputKind) async -> RescrivaPage {
		let size: PageSize = page.aspect > 1
			? PageSize(width: 960, height: 960 / page.aspect)
			: PageSize(width: 612, height: 612 / max(page.aspect, 0.2))
		var blocks: [RescrivaBlock] = []
		if #available(iOS 26.0, *), let image = page.decodedImage {
			do {
				blocks = try await documentBlocks(image)
			} catch {
				Log.rebuild.error("Vision's document reader failed on a page, so its layout comes from the heuristics: \(error)")
			}
		}
		if blocks.isEmpty {
			blocks = heuristicBlocks(page.lines, aspect: page.aspect)
		}
		return RescrivaPage(source: source, size: size, blocks: blocks)
	}

	// MARK: Figures (every tier)

	/// Finds the photos, charts and other pictures on each page (`FigureDetector`) and places them as
	/// figure blocks with their captions (`FigurePlacement`). Runs after the diagram and equation
	/// passes, whose regions are never figures, and skips whiteboards, whose solid areas are sticky
	/// notes and marker fills rather than pictures.
	nonisolated static func detectFigures(in built: [RescrivaPage], pages: [PageSnapshot]) async -> [RescrivaPage] {
		var result = built
		for index in result.indices where result[index].source != .whiteboard {
			guard let snapshot = pages[safe: index], let image = snapshot.decodedImage else { continue }
			let found = FigureDetector.detect(in: image, lines: snapshot.lines, excluding: FigureDetector.exclusions(in: result[index].blocks))
			guard !found.isEmpty else { continue }
			result[index].blocks = FigurePlacement.placing(found, into: result[index].blocks, lines: snapshot.lines)
		}
		return result
	}

	// MARK: Reading order with pictures (every tier)

	/// Puts each page holding a figure or a diagram back in reading order with its pictures among
	/// the blocks (`ReadingOrder`): a picture spanning both columns reads between the stretches of
	/// columns above and below it. The text was put in order before the pictures were found; a page
	/// the order is unsure of, or finds no columns on, keeps the order it has.
	nonisolated static func orderingPictures(in built: [RescrivaPage], pages: [PageSnapshot]) -> [RescrivaPage] {
		var result = built
		for index in result.indices where result[index].blocks.contains(where: isPicture) {
			guard let snapshot = pages[safe: index] else { continue }
			let lineHeight = median(snapshot.lines.map { Double($0.box.height) })
			guard let ordered = ReadingOrder.ordered(result[index].blocks, lineHeight: lineHeight, aspect: snapshot.aspect) else { continue }
			result[index].blocks = ordered
		}
		return result
	}

	/// True for a figure or a diagram.
	nonisolated static func isPicture(_ block: RescrivaBlock) -> Bool {
		switch block.content {
		case .figure, .diagram: return true
		case .heading, .paragraph, .list, .table, .equation: return false
		}
	}

	// MARK: Type styles (every tier)

	/// Marks bold, italic, underlined and struck-through words on typed pages (`StyleDetector`) and
	/// splits their runs where a word's style differs (`StylePlacement`). Runs after the figure
	/// pass, so text inside pictures is never styled. Whiteboard and handwritten pages are left
	/// alone: pen pressure, slant and marker width aren't styling.
	nonisolated static func detectStyles(in built: [RescrivaPage], pages: [PageSnapshot]) async -> [RescrivaPage] {
		var result = built
		for index in result.indices where result[index].source == .typed {
			guard let snapshot = pages[safe: index], let image = snapshot.decodedImage else { continue }
			let roles = StyleDetector.roles(for: snapshot.lines, blocks: result[index].blocks)
			let found = StyleDetector.detect(image, lines: snapshot.lines, roles: roles)
			guard !found.isEmpty else { continue }
			result[index] = StyleDetector.applying(found, lines: snapshot.lines, to: result[index])
		}
		return result
	}

	// MARK: Page colours (every tier)

	/// Samples each page's background, accent palette and clearly coloured
	/// text from its cleaned image (see `PageColorSampler`). Runs after the
	/// diagram and equation passes so it only colours the text that's left.
	nonisolated static func sampleColors(in built: [RescrivaPage], pages: [PageSnapshot]) async -> [RescrivaPage] {
		var result = built
		for index in result.indices {
			guard let image = pages[safe: index]?.decodedImage,
				  let colors = PageColorSampler.sample(image, blocks: result[index].blocks, source: result[index].source)
			else { continue }
			result[index] = PageColorSampler.applying(colors, to: result[index])
		}
		return result
	}

	// MARK: Tier 3 — diagrams (classical Vision baseline for now)

	/// Finds a drawn diagram on each page and rebuilds it as shapes and
	/// arrows; the text blocks it absorbed (labels, "→" glyphs) are removed.
	/// Figures are numbered on from `earlier`, the diagrams on pages before.
	nonisolated static func detectDiagrams(in built: [RescrivaPage], pages: [PageSnapshot], numberingAfter earlier: Int = 0) async -> [RescrivaPage] {
		var result = built
		var figureNumber = earlier
		for index in result.indices {
			guard let snapshot = pages[safe: index], let image = snapshot.decodedImage,
				  let found = DiagramDetector.detect(in: image, lines: snapshot.lines)
			else { continue }
			figureNumber += 1
			var diagram = found.diagram
			diagram.caption = figureCaption(figureNumber, source: result[index].source)
			result[index].blocks = placing(diagram, frame: found.frame, into: result[index].blocks)
		}
		return result
	}

	/// "Figure 2 · redrawn from the page", or "… rebuilt from the whiteboard".
	nonisolated static func figureCaption(_ number: Int, source: PageSource) -> String {
		let origin = source == .whiteboard ? String(localized: "rebuilt from the whiteboard") : String(localized: "redrawn from the page")
		return String(localized: "Figure \(number) · \(origin)")
	}

	/// Drops the short text blocks sitting inside the diagram's frame and puts
	/// the diagram where it was drawn, in reading order.
	nonisolated static func placing(_ diagram: Diagram, frame: NormalizedBox, into blocks: [RescrivaBlock]) -> [RescrivaBlock] {
		let area = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height).insetBy(dx: -0.01, dy: -0.01)
		var kept = blocks.filter { block in
			guard let box = block.box else { return true }
			let centre = CGPoint(x: box.x + box.width / 2, y: box.y + box.height / 2)
			let shortText = block.content.plainText.count <= Self.maxAbsorbedTextLength
			let isText: Bool
			switch block.content {
			case .heading, .paragraph, .list: isText = true
			default: isText = false
			}
			return !(isText && shortText && area.contains(centre))
		}
		let diagramBlock = RescrivaBlock(content: .diagram(diagram), box: frame, provenance: Provenance(engine: "diagramDetector", confidence: 1))
		let insertAt = kept.firstIndex { ($0.box?.y ?? 0) > frame.y } ?? kept.endIndex
		kept.insert(diagramBlock, at: insertAt)
		return kept
	}

	/// Text blocks longer than this inside a diagram's frame are kept (they're prose, not labels).
	nonisolated static let maxAbsorbedTextLength = 60

	// MARK: Tier 3 — equations (text-based for now)

	/// Most OCR readings compared for one equation line.
	nonisolated static let maxEquationReadings = 8

	/// Single-line paragraphs that read as math become equations. The document
	/// reader's text is cross-checked against the line reader's text and Vision's
	/// alternatives for the same spot, keeping the reading with balanced brackets;
	/// on Smart-tier iPhones Apple's on-device model then refines the LaTeX. A line
	/// whose LaTeX doesn't convert stays text.
	nonisolated static func detectEquations(in pages: [RescrivaPage], lines: [[RecognizedLine]]) async -> [RescrivaPage] {
		var result = pages
		for pageIndex in result.indices {
			let pageLines = lines[safe: pageIndex] ?? []
			for blockIndex in result[pageIndex].blocks.indices {
				let block = result[pageIndex].blocks[blockIndex]
				guard case .paragraph(let runs, _) = block.content else { continue }
				let text = runs.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
				guard !text.isEmpty, text.count <= EquationDetector.maxLineLength, !text.contains("\n"),
					  EquationDetector.mathScore(text) >= EquationDetector.threshold,
					  let best = bestEquationReading([text] + overlappingReadings(block.box, in: pageLines))
				else { continue }
				let latex = await EquationDetector.refine(best.latex, linear: best.text)
				result[pageIndex].blocks[blockIndex].content = .equation(latex: latex, linear: best.text, display: true)
				result[pageIndex].blocks[blockIndex].provenance = Provenance(engine: "equationDetector", confidence: EquationDetector.mathScore(best.text))
			}
		}
		return result
	}

	/// The line reader's readings (text and alternatives) of lines mostly inside `box`.
	nonisolated static func overlappingReadings(_ box: NormalizedBox?, in lines: [RecognizedLine]) -> [String] {
		guard let box else { return [] }
		let frame = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
		return lines.filter { line in
			let overlap = line.box.intersection(frame)
			return !overlap.isNull && overlap.width * overlap.height >= 0.5 * line.box.width * line.box.height
		}.flatMap { [$0.text] + $0.alternatives }
	}

	/// The reading with the fewest unbalanced brackets and stray bars whose
	/// LaTeX converts; earlier readings win ties.
	nonisolated static func bestEquationReading(_ readings: [String]) -> (text: String, latex: String)? {
		var best: (text: String, latex: String, penalty: Int)?
		for reading in readings.prefix(Self.maxEquationReadings) {
			let text = reading.trimmingCharacters(in: .whitespacesAndNewlines)
			guard EquationDetector.mathScore(text) >= EquationDetector.threshold,
				  let latex = EquationDetector.latex(fromLinear: text) else { continue }
			let penalty = bracketPenalty(text)
			if penalty < (best?.penalty ?? Int.max) {
				best = (text, latex, penalty)
			}
		}
		return best.map { ($0.text, $0.latex) }
	}

	/// Unbalanced (), [], {} and "|" (a common misread of a bracket) cost points.
	nonisolated static func bracketPenalty(_ text: String) -> Int {
		var penalty = text.filter { $0 == "|" }.count * 2
		for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] as [(Character, Character)] {
			penalty += abs(text.filter { $0 == open }.count - text.filter { $0 == close }.count) * 3
		}
		return penalty
	}

	// MARK: Tier 1 — Vision document reader

	@available(iOS 26.0, *)
	nonisolated static func documentBlocks(_ image: CGImage) async throws -> [RescrivaBlock] {
		var request = RecognizeDocumentsRequest()
		request.textRecognitionOptions.maximumCandidateCount = 3
		request.textRecognitionOptions.useLanguageCorrection = true
		guard let document = try await request.perform(on: image).first?.document else { return [] }

		var placed: [(box: NormalizedBox, block: RescrivaBlock)] = []
		let medianLine = median(document.paragraphs.flatMap(\.lines).map { Double(box($0.boundingRegion).height) })

		for table in document.tables {
			let rows: [[TableCell]] = table.rows.enumerated().map { rowIndex, row in
				var seenColumns = Set<Int>()
				return row.compactMap { cell in
					// Vision repeats a merged cell in every slot it covers; keep it once, where it starts.
					guard cell.rowRange.lowerBound == rowIndex, seenColumns.insert(cell.columnRange.lowerBound).inserted else { return nil }
					return TableCell(runs: [RescrivaRun(text: cell.content.text.transcript)],
									 rowSpan: cell.rowRange.count, columnSpan: cell.columnRange.count)
				}
			}
			let frame = box(table.boundingRegion)
			placed.append((frame, RescrivaBlock(content: .table(rows: rows.filter { !$0.isEmpty }), box: frame, provenance: Provenance(engine: "vision", confidence: 1))))
		}

		for list in document.lists {
			let frame = box(list.boundingRegion)
			guard !placed.contains(where: { contains($0.box, frame) }) else { continue }
			var style: ListStyle = .bullet
			var items: [ListItem] = []
			for item in list.items {
				var text = item.itemString
				var checked: Bool?
				if let mark = checkboxMark(item.markerString + text) {
					style = .checkbox
					checked = mark.checked
					text = mark.remainder
				} else if let marker = item.markerType {
					switch marker {
					case .bullet, .hyphen: style = .bullet
					default: style = .ordered
					}
				}
				items.append(ListItem(runs: runs(for: item.content.text.lines, fallback: text), checked: checked))
			}
			placed.append((frame, RescrivaBlock(content: .list(style: style, items: items), box: frame, provenance: Provenance(engine: "vision", confidence: 1))))
		}

		if let title = document.title {
			let frame = box(title.boundingRegion)
			placed.append((frame, RescrivaBlock(content: .heading(level: 1, runs: runs(for: title.lines, fallback: title.transcript)), box: frame, provenance: Provenance(engine: "vision", confidence: 1))))
		}

		for paragraph in document.paragraphs {
			let frame = box(paragraph.boundingRegion)
			if placed.contains(where: { contains($0.box, frame) }) { continue }
			let lineHeight = paragraph.lines.isEmpty ? frame.height : frame.height / Double(paragraph.lines.count)
			let paragraphRuns = runs(for: paragraph.lines, fallback: paragraph.transcript)
			let content: BlockContent
			if paragraph.lines.count == 1, let item = listItem(RecognizedLine(text: paragraph.transcript, confidence: 1, alternatives: [], box: .zero)) {
				content = .list(style: item.style, items: [item.item])
			} else if paragraph.lines.count == 1, medianLine > 0, lineHeight > medianLine * 1.35, paragraph.transcript.count < 80 {
				content = .heading(level: 2, runs: paragraphRuns)
			} else {
				content = .paragraph(runs: paragraphRuns, alignment: alignment(paragraph.textAlignment))
			}
			placed.append((frame, RescrivaBlock(content: content, box: frame, provenance: Provenance(engine: "vision", confidence: 1))))
		}

		return harmonizeChecklists(readingOrdered(placed, lineHeight: medianLine, aspect: Double(image.width) / Double(max(image.height, 1))))
	}

	/// The document reader's blocks in reading order: top to bottom, then down each column where the
	/// page has columns (`ReadingOrder`). The reader's own order is no help: it reads side-by-side
	/// blocks in bands across the columns.
	nonisolated static func readingOrdered(_ placed: [(box: NormalizedBox, block: RescrivaBlock)], lineHeight: Double, aspect: Double) -> [RescrivaBlock] {
		let byPosition = placed.sorted { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) }
		guard let order = ReadingOrder.order(byPosition.map(\.box.rect), lineHeight: lineHeight, aspect: aspect) else {
			return byPosition.map(\.block)
		}
		assert(order.count == byPosition.count, "every block once")
		return order.map { byPosition[$0].block }
	}

	/// Runs for recognized lines, splitting out uncertain words as flags.
	@available(iOS 26.0, *)
	nonisolated static func runs(for lines: [RecognizedTextObservation], fallback: String) -> [RescrivaRun] {
		guard !lines.isEmpty else { return [RescrivaRun(text: fallback)] }
		var result: [RescrivaRun] = []
		for (index, observation) in lines.enumerated() {
			let candidates = observation.topCandidates(3)
			guard let top = candidates.first else { continue }
			let line = RecognizedLine(text: top.string, confidence: top.confidence,
									  alternatives: candidates.dropFirst().map(\.string), box: .zero)
			result.append(contentsOf: flaggedRuns(for: line))
			if index < lines.count - 1 {
				result.append(RescrivaRun(text: " "))
			}
		}
		return coalesce(result)
	}

	// MARK: Heuristics (no document reader)

	/// Groups recognized lines into blocks by position and leading markers, reading down each column
	/// in turn where the page (`aspect` wide per unit of height) has columns (`ReadingOrder`).
	nonisolated static func heuristicBlocks(_ lines: [RecognizedLine], aspect: Double = ReadingOrder.Tuning.typicalAspect) -> [RescrivaBlock] {
		let byPosition = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
		let medianHeight = median(byPosition.map { Double($0.box.height) })
		let sorted = ReadingOrder.order(byPosition.map(\.box), lineHeight: medianHeight, aspect: aspect).map { $0.map { byPosition[$0] } } ?? byPosition
		var blocks: [RescrivaBlock] = []
		var paragraph: [RecognizedLine] = []

		func flushParagraph() {
			guard let first = paragraph.first else { return }
			let frame = union(paragraph.map(\.box))
			var runs: [RescrivaRun] = []
			for (index, line) in paragraph.enumerated() {
				runs.append(contentsOf: flaggedRuns(for: line))
				if index < paragraph.count - 1 { runs.append(RescrivaRun(text: " ")) }
			}
			let isHeading = paragraph.count == 1 && medianHeight > 0 && Double(first.box.height) > medianHeight * 1.35 && first.text.count < 80
			let content: BlockContent = isHeading
				? .heading(level: blocks.isEmpty ? 1 : 2, runs: coalesce(runs))
				: .paragraph(runs: coalesce(runs), alignment: .leading)
			blocks.append(RescrivaBlock(content: content, box: frame, provenance: Provenance(engine: "heuristics", confidence: Double(first.confidence))))
			paragraph = []
		}

		for line in sorted {
			if let item = listItem(line) {
				flushParagraph()
				let frame = NormalizedBox(line.box)
				if case .list(let style, var items) = blocks.last?.content, style == item.style,
				   continuesList(blocks.last?.box, with: frame) {
					items.append(item.item)
					blocks[blocks.count - 1].content = .list(style: style, items: items)
					// The box grows to cover every item: slides place the list by it, and its colour is read from it.
					blocks[blocks.count - 1].box = covering(blocks[blocks.count - 1].box, frame)
				} else {
					blocks.append(RescrivaBlock(content: .list(style: item.style, items: [item.item]), box: frame, provenance: Provenance(engine: "heuristics", confidence: Double(line.confidence))))
				}
				continue
			}
			if let previous = paragraph.last {
				let gap = line.box.minY - previous.box.maxY
				let aligned = abs(line.box.minX - paragraph[0].box.minX) < 0.04
				let similar = abs(line.box.height - previous.box.height) < max(line.box.height, previous.box.height) * 0.35
				if gap > previous.box.height * 0.9 || !aligned || !similar {
					flushParagraph()
				}
			}
			paragraph.append(line)
		}
		flushParagraph()
		return harmonizeChecklists(blocks)
	}

	private nonisolated static func listItem(_ line: RecognizedLine) -> (style: ListStyle, item: ListItem)? {
		let text = line.text.trimmingCharacters(in: .whitespaces)
		if let mark = checkboxMark(text) {
			return (.checkbox, ListItem(runs: flaggedRuns(for: RecognizedLine(text: mark.remainder, confidence: line.confidence, alternatives: [], box: line.box)), checked: mark.checked))
		}
		for bullet in ["• ", "- ", "– ", "* ", "· ", "‣ "] where text.hasPrefix(bullet) {
			let rest = String(text.dropFirst(bullet.count))
			return (.bullet, ListItem(runs: [RescrivaRun(text: rest)]))
		}
		if let match = text.firstMatch(of: /^(\d{1,2})[.)]\s+(.+)$/) {
			return (.ordered, ListItem(runs: [RescrivaRun(text: String(match.2))]))
		}
		return nil
	}

	// MARK: Flags

	/// Splits a line into runs, flagging the one word Vision's alternatives
	/// disagree on when its confidence is low.
	nonisolated static func flaggedRuns(for line: RecognizedLine) -> [RescrivaRun] {
		guard line.confidence < 0.6, let flag = wordFlag(for: line) else {
			return [RescrivaRun(text: line.text)]
		}
		let words = line.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
		var runs: [RescrivaRun] = []
		let before = words[..<flag.index].joined(separator: " ")
		let after = words[(flag.index + 1)...].joined(separator: " ")
		if !before.isEmpty { runs.append(RescrivaRun(text: before + " ")) }
		let options = flag.options.map { RescrivaFlag.Option(label: $0) } + [RescrivaFlag.Option(label: flag.word, note: String(localized: "keep as read"))]
		runs.append(RescrivaRun(text: flag.word, flag: RescrivaFlag(kind: .word, title: String(localized: "Did you mean…"),
															  detail: String(localized: "Vision wasn’t sure about this word"),
															  read: flag.word, options: options)))
		if !after.isEmpty { runs.append(RescrivaRun(text: " " + after)) }
		return runs
	}

	/// The single word where the alternatives differ from the top reading. An alternative that only
	/// moves punctuation at that word's edges ("No." for "No", "SOC" for "SOC)") reads the same
	/// word, so it neither offers an option nor picks the word.
	nonisolated static func wordFlag(for line: RecognizedLine) -> (index: Int, word: String, options: [String])? {
		let words = line.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
		var index: Int?
		var options: [String] = []
		for alternative in line.alternatives {
			let altWords = alternative.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
			guard altWords.count == words.count else { continue }
			let differing = zip(words, altWords).enumerated().filter { $0.element.0 != $0.element.1 }
			guard differing.count == 1, let diff = differing.first,
				  !WordFlagRules.differsOnlyInEdgePunctuation(diff.element.0, diff.element.1) else { continue }
			if index == nil { index = diff.offset }
			if diff.offset == index, !options.contains(diff.element.1) { options.append(diff.element.1) }
		}
		guard let index, !options.isEmpty else { return nil }
		return (index, words[index], options)
	}

	/// Narrows each open word flag to the options worth asking about on its page, and drops the
	/// flags left with none (`refinedWordFlag`). Runs on the main actor because the spelling
	/// checker lives there.
	static func refineWordFlags(_ document: RescrivaDocument) -> RescrivaDocument {
		var refined = document
		for pageIndex in refined.pages.indices {
			let source = refined.pages[pageIndex].source
			for blockIndex in refined.pages[pageIndex].blocks.indices {
				refined.pages[pageIndex].blocks[blockIndex].content.mapRuns { runs in
					runs.map { run in
						guard let flag = run.flag, flag.kind == .word, flag.resolution == nil else { return run }
						var run = run
						run.flag = refinedWordFlag(flag, on: source)
						return run
					}
				}
			}
		}
		return refined
	}

	/// `flag` offering only the alternatives worth a question on a `source` page, then the reading
	/// itself ("keep as read"); nil when no alternative is (`typedQuestions`, `writtenQuestions`).
	static func refinedWordFlag(_ flag: RescrivaFlag, on source: PageSource) -> RescrivaFlag? {
		assert(flag.kind == .word, "only word flags offer other readings")
		let keep = flag.options.first { $0.label == flag.read }
		let alternatives = flag.options.map(\.label).filter { $0 != flag.read }
		let questions = source == .typed
			? typedQuestions(read: flag.read, alternatives: alternatives)
			: writtenQuestions(read: flag.read, alternatives: alternatives)
		guard !questions.isEmpty else { return nil }
		var refined = flag
		refined.options = questions.map { RescrivaFlag.Option(label: $0) } + (keep.map { [$0] } ?? [])
		return refined
	}

	/// On a typed page, which prints its glyphs plainly, the reader is far more often right than
	/// not, and a needless question costs more than a missed one: a reading that is already a
	/// word, a code or a number isn't questioned, and an alternative is offered only when it is a
	/// correctly spelled word and not the reading with glyphs Vision dropped or its punctuation or
	/// case changed (`WordFlagRules.isVariant`: "39" or "3." for "3.9", "Cel" for "Cell").
	static func typedQuestions(read: String, alternatives: [String]) -> [String] {
		guard !SpellCheck.isWord(read) else { return [] }
		return alternatives.filter { !WordFlagRules.isVariant($0, of: read) && SpellCheck.isDictionaryWord($0) }
	}

	/// On a handwritten or whiteboard page, where a dot or a stroke really can go either way: a
	/// correctly spelled reading is questioned only with the other real words Vision considered
	/// (misspelled ones are noise), and a misspelled reading offers every alternative, real words
	/// first.
	static func writtenQuestions(read: String, alternatives: [String]) -> [String] {
		let realWords = alternatives.filter(SpellCheck.isWord)
		guard !SpellCheck.isWord(read) else { return realWords }
		return realWords + alternatives.filter { !realWords.contains($0) }
	}

	// MARK: Geometry helpers

	@available(iOS 26.0, *)
	nonisolated static func box(_ region: NormalizedRegion) -> NormalizedBox {
		let rect = region.normalizedPath.boundingBox
		return NormalizedBox(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
	}

	@available(iOS 26.0, *)
	nonisolated static func alignment(_ value: DocumentObservation.Container.Text.Alignment?) -> TextAlignment {
		switch value {
		case .center: return .center
		case .trailing: return .trailing
		default: return .leading
		}
	}

	nonisolated static func contains(_ outer: NormalizedBox, _ inner: NormalizedBox) -> Bool {
		let slack = 0.01
		return inner.x >= outer.x - slack && inner.y >= outer.y - slack
			&& inner.x + inner.width <= outer.x + outer.width + slack
			&& inner.y + inner.height <= outer.y + outer.height + slack
	}

	nonisolated static func union(_ rects: [CGRect]) -> NormalizedBox {
		let rect = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
		return NormalizedBox(rect)
	}

	/// True when an item at `item` reads on from the list at `list`: it starts at about the list's
	/// left edge, just below its last line. A list in the next column (read after this one, see
	/// `ReadingOrder`) or further down the page starts a list of its own, so the list's box never
	/// spans the columns. True when either box is missing, as lists were merged before.
	nonisolated static func continuesList(_ list: NormalizedBox?, with item: NormalizedBox?) -> Bool {
		guard let list, let item else { return true }
		let height = max(item.height, 1e-3)
		let gap = item.y - (list.y + list.height)
		return abs(item.x - list.x) < 0.04 && gap > -0.5 * height && gap < 2 * height
	}

	/// The smallest box covering both; either one alone when the other is missing.
	nonisolated static func covering(_ first: NormalizedBox?, _ second: NormalizedBox?) -> NormalizedBox? {
		guard let first else { return second }
		guard let second else { return first }
		let rects = [first, second].map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
		return union(rects)
	}

	nonisolated static func median(_ values: [Double]) -> Double {
		let sorted = values.filter { $0 > 0 }.sorted()
		guard !sorted.isEmpty else { return 0 }
		return sorted[sorted.count / 2]
	}

	/// Leading checkbox glyphs: ☐ □ [ ] (open) and ☑ ☒ ✓ [x] (checked).
	nonisolated static func checkboxMark(_ text: String) -> (checked: Bool, remainder: String)? {
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		for (mark, checked) in [("☐", false), ("□", false), ("[ ]", false), ("☑", true), ("☒", true), ("✓", true), ("[x]", true), ("[X]", true)] where trimmed.hasPrefix(mark) {
			return (checked, String(trimmed.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces))
		}
		return nil
	}

	/// Joins adjacent unflagged runs with identical styling.
	nonisolated static func coalesce(_ runs: [RescrivaRun]) -> [RescrivaRun] {
		var result: [RescrivaRun] = []
		for run in runs {
			if var last = result.last, last.flag == nil, run.flag == nil,
			   last.bold == run.bold, last.italic == run.italic, last.underline == run.underline {
				last.text += run.text
				result[result.count - 1] = last
			} else {
				result.append(run)
			}
		}
		return result
	}

	/// Handwritten checklists come back from OCR mixed up: ☐ read as "•", ☑ as
	/// "©" or "®". Next to other list items, those become one checklist.
	nonisolated static func harmonizeChecklists(_ blocks: [RescrivaBlock]) -> [RescrivaBlock] {
		var result = blocks
		func isList(_ block: RescrivaBlock?) -> Bool {
			if case .list(let style, _) = block?.content { return style != .ordered }
			return false
		}
		for index in result.indices {
			guard case .paragraph(let runs, _) = result[index].content else { continue }
			let text = runs.plainText.trimmingCharacters(in: .whitespaces)
			guard let first = text.first, "©®".contains(first), isList(result[safe: index - 1]) || isList(result[safe: index + 1]) else { continue }
			let rest = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
			result[index].content = .list(style: .checkbox, items: [ListItem(runs: [RescrivaRun(text: rest)], checked: true)])
		}
		for index in result.indices {
			// Only a lone "•" item: a real bullet list next to a checklist stays a bullet list.
			guard case .list(.bullet, let items) = result[index].content, items.count == 1 else { continue }
			let besideChecklist = [result[safe: index - 1], result[safe: index + 1]].contains { block in
				if case .list(.checkbox, _) = block?.content { return true }
				return false
			}
			guard besideChecklist else { continue }
			result[index].content = .list(style: .checkbox, items: items.map { item in
				var item = item
				item.checked = false
				return item
			})
		}
		return mergeAdjacentChecklists(result)
	}

	/// Consecutive checkbox lists, one just below the other (`continuesList`), become one list, its
	/// box covering them all.
	nonisolated static func mergeAdjacentChecklists(_ blocks: [RescrivaBlock]) -> [RescrivaBlock] {
		var result: [RescrivaBlock] = []
		for block in blocks {
			if case .list(.checkbox, let items) = block.content, case .list(.checkbox, let previous) = result.last?.content,
			   continuesList(result.last?.box, with: block.box) {
				result[result.count - 1].content = .list(style: .checkbox, items: previous + items)
				result[result.count - 1].box = covering(result[result.count - 1].box, block.box)
			} else {
				result.append(block)
			}
		}
		return result
	}
}

/// Which of Vision's alternative readings of a word are that same word: the reading with glyphs
/// dropped, or with its punctuation, symbols or case changed. Those come from the reader's
/// lower-ranked guesses, not from doubt about which word is printed.
enum WordFlagRules {
	/// True when `alternative` differs from `read` only in punctuation at the word's edges:
	/// "No." / "No", "(2)" / "2)", "SOC)" / "SOC".
	static func differsOnlyInEdgePunctuation(_ read: String, _ alternative: String) -> Bool {
		guard read != alternative else { return false }
		return read.trimmingCharacters(in: .punctuationCharacters) == alternative.trimmingCharacters(in: .punctuationCharacters)
	}

	/// True when `alternative`'s letters and digits, case aside, are `read`'s or some of them in
	/// order: "39" and "3." for "3.9", "3" and "0" for "30", "(A)" for "(Ah)", "SiCore" for
	/// "SiCore™", "amprus" for "amprius"; and when it has no letters or digits at all.
	static func isVariant(_ alternative: String, of read: String) -> Bool {
		isSubsequence(lettersAndDigits(alternative), of: lettersAndDigits(read))
	}

	/// The letters and digits of `text`, lowercased.
	static func lettersAndDigits(_ text: String) -> [Character] {
		Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
	}

	/// True when every character of `part` appears in `whole`, in the same order.
	static func isSubsequence(_ part: [Character], of whole: [Character]) -> Bool {
		guard part.count <= whole.count else { return false }
		var remaining = part[...]
		for character in whole where remaining.first == character {
			remaining = remaining.dropFirst()
		}
		return remaining.isEmpty
	}
}

/// Spelling check for flag candidates, in the user's language.
@MainActor
enum SpellCheck {
	/// True for a correctly spelled word, an acronym or code, or a token without letters.
	static func isWord(_ token: String) -> Bool {
		let word = trimmed(token)
		guard word.contains(where: \.isLetter) else { return true }
		// Acronyms and codes (API, Q3, v2) aren't dictionary words but aren't misreads either.
		if word.count <= 5, word == word.uppercased() || word.contains(where: \.isNumber) { return true }
		return isSpelledRight(word)
	}

	/// True for a correctly spelled word of letters (apostrophes and hyphens allowed); never for a
	/// number, code or acronym, whose spelling says nothing about how it was read.
	static func isDictionaryWord(_ token: String) -> Bool {
		let word = trimmed(token)
		guard word.contains(where: \.isLetter), word.allSatisfy({ $0.isLetter || "'’-".contains($0) }) else { return false }
		return isSpelledRight(word)
	}

	/// `token` without the punctuation and symbols around it.
	private static func trimmed(_ token: String) -> String {
		token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
	}

	/// True when the spelling checker finds nothing misspelled in `word`.
	private static func isSpelledRight(_ word: String) -> Bool {
		guard !word.isEmpty else { return false }
		let checker = UITextChecker()
		let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
		let available = UITextChecker.availableLanguages
		let code = available.first { $0.hasPrefix(language) } ?? "en_US"
		let range = checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length),
												  startingAt: 0, wrap: false, language: code)
		return range.location == NSNotFound
	}
}

extension NormalizedBox {
	init(_ rect: CGRect) {
		self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
	}
}
