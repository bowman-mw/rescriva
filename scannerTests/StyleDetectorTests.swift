//
//  StyleDetectorTests.swift
//  Rescriva (fork of Open Scanner)
//
//  The style detector's harness: paragraphs laid out and drawn with TextKit
//  (Core Text) in a sans, a serif and a mono font with known bold, italic,
//  underlined and struck-through words, then read as drawn and again after a
//  blur and JPEG at 0.6, and after a blur, a 0.5° turn, noise and JPEG at 0.6.
//  The detector reads them through synthetic OCR lines (each laid-out line's
//  text and box). Per style, precision must be at least 95% across the whole
//  set and recall at least 50% on the clean renders. Also: plain pages,
//  upright words made of diagonals (never italic), handwriting-like lines, rules and table borders, headings, thin pages,
//  low-confidence and tiny lines, the Rebuilder pass on the stored JPEG,
//  putting styles into a page's runs, and the cut, band, stroke-width and
//  slant helpers. The renders of a set are read side by side to keep the
//  run short.
//

import UIKit
import XCTest
@testable import scanner

/// `StyleDetector` and `StylePlacement` on synthetic pages and runs.
final class StyleDetectorTests: XCTestCase {

	// MARK: The harness

	func testStylesInSansSerifAndMonoMeetPrecisionAndRecall() throws {
		let pages = try Family.all.map { try StyledPage(markup: Sample.styled, family: $0) }
		var clean = StyleScore()
		var every = StyleScore()
		for reading in try Self.readings(of: pages) {
			every.add(reading.styles, expected: reading.expected)
			if reading.isClean {
				clean.add(reading.styles, expected: reading.expected)
			}
		}
		print("StyleDetector clean renders — \(clean.summary)")
		print("StyleDetector every render — \(every.summary)")
		for (name, style) in StyleScore.styles {
			XCTAssertGreaterThanOrEqual(every.precision(style), 0.95, "\(name) precision — \(every.summary)")
			XCTAssertGreaterThanOrEqual(clean.recall(style), 0.5, "\(name) recall on clean renders — \(clean.summary)")
		}
	}

	func testAPlainPageGetsNoStylesInAnyFontOrRender() throws {
		let pages = try Family.all.map { try StyledPage(markup: Sample.plain, family: $0) }
		var score = StyleScore()
		var readWords = 0
		for reading in try Self.readings(of: pages) {
			score.add(reading.styles, expected: reading.expected)
			for line in reading.styles {
				readWords += line.styles.compactMap { $0 }.count
				for (word, styles) in zip(line.words, line.styles) where StyleDetector.letterCount(word) < 3 {
					XCTAssertNil(styles, "words under 3 letters abstain: \(word)")
				}
			}
		}
		XCTAssertGreaterThan(readWords, 100, "plain pages are read, not skipped")
		XCTAssertEqual(score.claims, 0, score.summary)
	}

	func testUprightWordsMadeOfDiagonalsAreNotItalic() throws {
		// The / strokes of v, w, x and y lean about 20°, as far as an italic; their \ strokes give them away.
		let diagonals = """
			They made a solemn vow to keep the wavy line and the savvy plan. Chapter XXV covers the treaty \
			while the view was lovely. Wow, the crowd went wild as wax melted away, and envoys came by sky way. \
			Was it the way she saw yes or the ways we always vow, says every savvy envoy to the waves.
			"""
		let faces = [
			Family.sans,
			Family(regular: "HelveticaNeue", bold: "HelveticaNeue-Bold", italic: "HelveticaNeue-Italic"),
			Family(regular: "ArialMT", bold: "Arial-BoldMT", italic: "Arial-ItalicMT"),
		]
		for family in faces {
			let page = try StyledPage(markup: Sample.plain + "\n" + diagonals, family: family)

			let read = StyleDetector.detect(page.image, lines: page.lines, roles: page.roles)

			let italic = read.flatMap { line in
				zip(line.words, line.styles).filter { $0.1?.contains(.italic) ?? false }.map(\.0)
			}
			XCTAssertGreaterThan(read.count, 4, "\(family.regular): the page is read")
			XCTAssertEqual(italic, [], family.regular)
		}
		let leaningBothWays = StyleDetector.WordReading(strokeWidth: 3, slant: 20, edgeHits: 20, uprightHits: 2, mirroredHits: 19,
														underline: false, strikethrough: false)
		XCTAssertFalse(StyleDetector.isItalic(leaningBothWays, pageSlant: 0))
		var sheared = leaningBothWays
		sheared.mirroredHits = 5
		XCTAssertTrue(StyleDetector.isItalic(sheared, pageSlant: 0))
	}

	// MARK: Abstaining

	func testAHandwritingLikeLineWithJitteredXHeightsAbstains() throws {
		let text = NSMutableAttributedString(attributedString: try Markup.attributed(Sample.plain, family: .sans, points: 36))
		text.append(NSAttributedString(string: "\n"))
		let words = ["Meeting", "notes", "about", "budget", "tablet", "launch", "plans"]
		let sizes: [CGFloat] = [28, 44, 32, 48, 30, 42, 34]
		for (index, word) in words.enumerated() {
			let face = index == 2 ? Family.sans.bold : Family.sans.regular
			let font = try XCTUnwrap(UIFont(name: face, size: sizes[index]))
			text.append(NSAttributedString(string: word + (index + 1 < words.count ? " " : ""), attributes: [.font: font]))
		}
		let page = try StyledPage(text: text)
		let jittered = page.lines.count - 1
		XCTAssertEqual(page.lines.last?.text, words.joined(separator: " "))

		let read = StyleDetector.detect(page.image, lines: page.lines, roles: page.roles)

		XCTAssertFalse(read.isEmpty, "the typed lines above it are read")
		XCTAssertFalse(read.contains { $0.line == jittered }, "word x-heights varying like handwriting: the line abstains")
	}

	func testARuleUnderALineAndATableBorderAreNotUnderlines() throws {
		let page = try StyledPage(markup: Sample.plain, family: .sans) { lines in
			UIColor.black.setFill()
			guard let ruled = lines[safe: 1], let boxed = lines[safe: 3] else { return }
			// A rule across the page just under line 1's baseline, where an underline would sit.
			UIRectFill(CGRect(x: 0, y: ruled.baseline + 0.2 * ruled.xHeight, width: 1400, height: 2))
			// A table cell ruled close around line 3, its sides running on into the next row.
			let cell = boxed.rect.insetBy(dx: -8, dy: -4)
			let bottom = boxed.baseline + 0.25 * boxed.xHeight
			UIRectFill(CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: 2))
			UIRectFill(CGRect(x: cell.minX, y: bottom, width: cell.width, height: 2))
			UIRectFill(CGRect(x: cell.minX, y: cell.minY, width: 2, height: bottom - cell.minY + 40))
			UIRectFill(CGRect(x: cell.maxX - 2, y: cell.minY, width: 2, height: bottom - cell.minY + 40))
		}

		let read = StyleDetector.detect(page.image, lines: page.lines, roles: page.roles)

		XCTAssertTrue(read.contains { $0.line == 1 }, "the ruled line is still read")
		let underlined = read.flatMap { reading in reading.styles.compactMap { $0 }.filter { $0.contains(.underline) } }
		XCTAssertTrue(underlined.isEmpty, "rules and table borders aren't underlines: \(read)")
	}

	func testHeadingsAreNeverMadeBoldButKeepTheirOtherStyles() throws {
		let page = try StyledPage(markup: Sample.styled, family: .sans)
		let heading = try XCTUnwrap(page.lines.firstIndex { $0.text.contains("review") })
		var roles = page.roles
		roles[heading] = .heading

		let read = StyleDetector.detect(page.image, lines: page.lines, roles: roles)

		let headingStyles = read.first { $0.line == heading }?.styles.compactMap { $0 } ?? []
		XCTAssertFalse(headingStyles.contains { $0.contains(.bold) }, "headings are bold already")
		XCTAssertTrue(read.contains { $0.line != heading && $0.styles.contains { $0?.contains(.bold) ?? false } },
					  "body lines still get bold")
	}

	func testAPageWithTooFewBodyWordsAbstains() throws {
		let page = try StyledPage(markup: "The quarterly *review* covers revenue, hiring and the roadmap.", family: .sans)

		XCTAssertTrue(StyleDetector.detect(page.image, lines: page.lines, roles: page.roles).isEmpty,
					  "fewer than 20 body words: nothing to compare with")
		let data = try XCTUnwrap(UIImage(cgImage: page.image).jpegData(compressionQuality: 0.75))
		XCTAssertTrue(StyleDetector.detect(data, lines: page.lines, roles: page.roles).isEmpty)
	}

	func testLowConfidenceLinesTinyTextAndSkippedLinesAbstain() throws {
		let page = try StyledPage(markup: Sample.styled, family: .sans)
		var lines = page.lines
		lines[2].confidence = 0.5
		var roles = page.roles
		roles[3] = .skip

		let read = StyleDetector.detect(page.image, lines: lines, roles: roles)

		XCTAssertFalse(read.isEmpty)
		XCTAssertFalse(read.contains { $0.line == 2 }, "read with confidence under 0.6")
		XCTAssertFalse(read.contains { $0.line == 3 }, "a table or figure line")
		let tiny = try StyledPage(markup: Sample.styled, family: .sans, points: 14)
		XCTAssertTrue(StyleDetector.detect(tiny.image, lines: tiny.lines, roles: tiny.roles).isEmpty,
					  "x-height under 12 px")
	}

	// MARK: The Rebuilder

	func testTheRebuilderStylesTypedPagesFromTheStoredJPEGAndLeavesWhiteboardsAlone() async throws {
		let page = try StyledPage(markup: Sample.styled, family: .sans)
		let data = try XCTUnwrap(UIImage(cgImage: page.image).jpegData(compressionQuality: 0.75))
		let snapshot = await Rebuilder.PageSnapshot(imageData: data, lines: page.lines, aspect: page.size.width / page.size.height).decodingImage()
		XCTAssertNotNil(snapshot.image, "the stored JPEG decodes once for every pass")
		let blocks = Rebuilder.heuristicBlocks(page.lines)
		let typed = RescrivaPage(source: .typed, blocks: blocks)
		let whiteboard = RescrivaPage(source: .whiteboard, blocks: blocks)

		let rebuilt = await Rebuilder.detectStyles(in: [typed, whiteboard], pages: [snapshot, snapshot])

		XCTAssertEqual(rebuilt.count, 2)
		XCTAssertEqual(rebuilt[1], whiteboard, "whiteboard pages are left alone")
		XCTAssertEqual(rebuilt[0].blocks.map(\.content.plainText), blocks.map(\.content.plainText), "styling never changes the text")
		let runs = rebuilt[0].blocks.flatMap { Self.runs(of: $0) }
		let expected = Sample.styledWords
		for run in runs {
			let words = StyleDetector.words(in: run.text).map(StyleDetector.key(for:)).filter { $0.count >= 3 }
			for (name, style) in StyleScore.styles where run.has(style) {
				XCTAssertTrue(words.allSatisfy { expected[style, default: []].contains($0) }, "\(name) on \"\(run.text)\"")
			}
		}
		XCTAssertTrue(runs.contains { $0.bold }, "bold words are found")
		XCTAssertTrue(runs.contains { $0.underline }, "underlined words are found")
	}

	// MARK: Placement

	func testAStyledWordSplitsItsRunAndTheTextStaysTheSame() {
		let page = Self.page(paragraph: "The quick brown fox jumps over")
		let found = [LineStyles(line: 0, words: ["The", "quick", "brown", "fox", "jumps", "over"],
								styles: [[], [.bold], [], nil, [.italic, .underline], []])]

		let styled = StyleDetector.applying(found, lines: Self.lines(["The quick brown fox jumps over"]), to: page)

		let runs = Self.runs(of: styled.blocks[0])
		XCTAssertEqual(runs.plainText, "The quick brown fox jumps over")
		XCTAssertEqual(runs.map(\.text), ["The ", "quick", " brown fox ", "jumps", " over"])
		XCTAssertEqual(runs.map(\.bold), [false, true, false, false, false])
		XCTAssertTrue(runs[3].italic && runs[3].underline)
		XCTAssertEqual(runs[0].id, Self.runs(of: page.blocks[0])[0].id, "the first piece keeps the run's id")
	}

	func testAnUnderlinedPhraseStaysOneRunWithItsSpace() {
		let page = Self.page(paragraph: "Please read the attached summary today")
		let found = [LineStyles(line: 0, words: ["Please", "read", "the", "attached", "summary", "today"],
								styles: [[], [], nil, [.underline], [.underline], []])]

		let styled = StyleDetector.applying(found, lines: Self.lines(["Please read the attached summary today"]), to: page)

		let runs = Self.runs(of: styled.blocks[0])
		XCTAssertEqual(runs.map(\.text), ["Please read the ", "attached summary", " today"])
		XCTAssertEqual(runs.map(\.underline), [false, true, false])
	}

	func testALoneMatchAmongMisreadWordsIsNotStyled() {
		let page = Self.page(paragraph: "The quick brown fox")
		let found = [LineStyles(line: 0, words: ["Tha", "quick", "brewn", "fax"], styles: [[], [.bold], [], []])]

		let styled = StyleDetector.applying(found, lines: Self.lines(["Tha quick brewn fax"]), to: page)

		XCTAssertEqual(styled, page, "no neighbour agrees, so the alignment can't be trusted")
	}

	func testAFlaggedWordKeepsItsFlagAndTakesTheStyleWhole() throws {
		let flag = RescrivaFlag(kind: .word, title: "Did you mean…", detail: "", read: "quick", options: [])
		let runs = [RescrivaRun(text: "The "), RescrivaRun(text: "quick", flag: flag), RescrivaRun(text: " brown fox")]
		let page = RescrivaPage(blocks: [RescrivaBlock(content: .paragraph(runs: runs, alignment: .leading),
												 box: NormalizedBox(x: 0.1, y: 0.1, width: 0.8, height: 0.05))])
		let found = [LineStyles(line: 0, words: ["The", "quick", "brown", "fox"], styles: [[], [.italic], [], []])]

		let styled = StyleDetector.applying(found, lines: Self.lines(["The quick brown fox"]), to: page)

		let after = Self.runs(of: styled.blocks[0])
		XCTAssertEqual(after.map(\.text), ["The ", "quick", " brown fox"])
		XCTAssertEqual(after[1].flag, flag)
		XCTAssertTrue(after[1].italic)
		XCTAssertFalse(after[0].italic || after[2].italic)
	}

	func testListItemsAreMatchedPastTheirBullets() throws {
		let items = [ListItem(runs: [RescrivaRun(text: "Buy fresh milk")]), ListItem(runs: [RescrivaRun(text: "Call the bank")])]
		let page = RescrivaPage(blocks: [RescrivaBlock(content: .list(style: .bullet, items: items),
												 box: NormalizedBox(x: 0.1, y: 0.1, width: 0.8, height: 0.12))])
		let lines = [RecognizedLine(text: "• Buy fresh milk", confidence: 0.9, alternatives: [], box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05)),
					 RecognizedLine(text: "• Call the bank", confidence: 0.9, alternatives: [], box: CGRect(x: 0.1, y: 0.16, width: 0.5, height: 0.05))]
		let found = [LineStyles(line: 1, words: ["•", "Call", "the", "bank"], styles: [nil, [], nil, [.strikethrough]])]

		let styled = StyleDetector.applying(found, lines: lines, to: page)

		guard case .list(_, let after) = styled.blocks[0].content else { return XCTFail("still a list") }
		XCTAssertEqual(after[0].runs.map(\.text), ["Buy fresh milk"])
		XCTAssertEqual(after[1].runs.map(\.text), ["Call the ", "bank"])
		XCTAssertEqual(after[1].runs.map(\.strikethrough), [false, true])
	}

	func testLinesTakeTheRoleOfTheOneTextBlockHoldingThem() {
		let box = { (y: Double) in NormalizedBox(x: 0.1, y: y, width: 0.8, height: 0.1) }
		let blocks = [RescrivaBlock(content: .heading(level: 1, runs: [RescrivaRun(text: "Title")]), box: box(0.0)),
					  RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Body")], alignment: .leading), box: box(0.2)),
					  RescrivaBlock(content: .table(rows: [[TableCell(runs: [RescrivaRun(text: "Cell")])]]), box: box(0.4)),
					  RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Caption")], alignment: .leading), box: box(0.6)),
					  RescrivaBlock(content: .figure(assetID: nil, caption: nil, altText: nil), box: box(0.6))]
		let lines = [0.05, 0.25, 0.45, 0.65, 0.85].map { y in
			RecognizedLine(text: "Words", confidence: 0.9, alternatives: [], box: CGRect(x: 0.2, y: y - 0.02, width: 0.5, height: 0.04))
		}

		let roles = StyleDetector.roles(for: lines, blocks: blocks)

		XCTAssertEqual(roles, [.heading, .body, .skip, .skip, .skip], "table, a figure over the text, and no block at all are skipped")
	}

	// MARK: Pure helpers

	func testTheLineIsCutAtItsWidestGapsOnlyWhenTheyAreClearlyWordGaps() {
		// Three words: letter gaps of 1 and 2 columns, word gaps of 6 and 7.
		let inked = Self.columns("..xx.xxx......xx.xx.xx.......xxxx..")
		XCTAssertEqual(StyleDetector.wordSpans(inked, count: 3, xHeight: 20), [2..<8, 14..<22, 29..<33])
		XCTAssertNil(StyleDetector.wordSpans(inked, count: 4, xHeight: 20), "a fourth word would need a letter gap")
		XCTAssertNil(StyleDetector.wordSpans(inked, count: 2, xHeight: 20), "a word gap left over: OCR saw fewer words than there are")
		XCTAssertNil(StyleDetector.wordSpans(Self.columns("xx.....xx....xx"), count: 2, xHeight: 20), "gaps too alike to tell apart")
		XCTAssertEqual(StyleDetector.wordSpans(Self.columns(".xxx.xx."), count: 1, xHeight: 20), [1..<7])
	}

	func testTheBandIsTheDensestRunOfRowsAndAThinRowDoesNotSplitIt() throws {
		let band = try XCTUnwrap(StyleDetector.Band(profile: [0, 1, 0, 10, 12, 4, 11, 10, 2, 0]))
		XCTAssertEqual(band.rows, 3..<8)
		XCTAssertNil(StyleDetector.Band(profile: [0, 0, 0]))
	}

	func testStrokeWidthIsTheSameForUprightAndDiagonalStrokes() throws {
		// A 5 px upright stem, and a stroke 5 px across leaning at 45° (7 px across each row).
		let upright = (0..<40).map { _ in [10..<15] }
		let diagonal = (0..<40).map { row in [(10 + row)..<(17 + row)] }

		let stem = try XCTUnwrap(StyleDetector.WordShape.strokeWidth(upright, width: 80, rows: 0..<40))
		let leaning = try XCTUnwrap(StyleDetector.WordShape.strokeWidth(diagonal, width: 80, rows: 0..<40))

		XCTAssertEqual(stem, 5, accuracy: 0.5)
		XCTAssertEqual(leaning, 5, accuracy: 0.5)
		let doubled = (0..<40).map { _ in [10..<20] }
		XCTAssertEqual(try XCTUnwrap(StyleDetector.WordShape.strokeWidth(doubled, width: 80, rows: 0..<40)) / stem, 2, accuracy: 0.15)
	}

	func testTheSlantIsTheShearThatStandsTheStemsUpright() throws {
		let height = 58
		let stems = { (degrees: Double) in
			(0..<height).map { row -> [Range<Int>] in
				let lean = Int((Double(height - row) * tan(degrees * .pi / 180)).rounded())
				return [10, 30, 50, 70].map { ($0 + lean)..<($0 + lean + 4) }
			}
		}

		XCTAssertEqual(StyleDetector.WordShape.dominantSlant(stems(0), height: height, width: 110), 0)
		let italic = try XCTUnwrap(StyleDetector.WordShape.dominantSlant(stems(12), height: height, width: 110))
		XCTAssertEqual(italic, 12, accuracy: 1)
		XCTAssertNil(StyleDetector.WordShape.dominantSlant([[0..<3]], height: 1, width: 10), "too little ink to judge")
	}

	func testSpreadIsTheInterquartileRangeOverTheMedian() {
		XCTAssertEqual(StyleDetector.spread([20]), 0)
		XCTAssertEqual(StyleDetector.spread([20, 22]), 2.0 / 22, accuracy: 1e-9)
		XCTAssertEqual(StyleDetector.spread([20, 20, 21, 20, 30, 20, 21, 20]), 1.0 / 20, accuracy: 1e-9, "one tall word doesn't count")
		XCTAssertGreaterThan(StyleDetector.spread([14, 23, 16, 25, 15, 22, 17]), 0.15)
	}

	// MARK: Helpers

	/// What the detector read on one render of a page.
	private struct Reading {
		var styles: [LineStyles]
		var expected: [[RunStyles]]
		var isClean: Bool
	}

	/// Each page read as drawn and after each perturbation, the renders read side by side.
	private static func readings(of pages: [StyledPage]) throws -> [Reading] {
		let renders: [Perturbation?] = [nil] + Perturbation.all
		let jobs = pages.flatMap { page in renders.map { (page: page, perturbation: $0) } }
		let lock = NSLock()
		var results = [Result<Reading, Error>?](repeating: nil, count: jobs.count)
		DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
			let job = jobs[index]
			let outcome = Result { () throws -> Reading in
				guard let perturbation = job.perturbation else {
					let read = StyleDetector.detect(job.page.image, lines: job.page.lines, roles: job.page.roles)
					return Reading(styles: read, expected: job.page.expected, isClean: true)
				}
				let scanned = try perturbation.applied(to: job.page)
				let read = StyleDetector.detect(scanned.data, lines: scanned.lines, roles: job.page.roles)
				return Reading(styles: read, expected: job.page.expected, isClean: false)
			}
			lock.lock()
			results[index] = outcome
			lock.unlock()
		}
		return try results.map { try XCTUnwrap($0).get() }
	}

	private static func page(paragraph text: String) -> RescrivaPage {
		RescrivaPage(blocks: [RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: text)], alignment: .leading),
									  box: NormalizedBox(x: 0.1, y: 0.1, width: 0.8, height: 0.05))])
	}

	private static func lines(_ texts: [String]) -> [RecognizedLine] {
		texts.enumerated().map { index, text in
			RecognizedLine(text: text, confidence: 0.9, alternatives: [],
						   box: CGRect(x: 0.1, y: 0.1 + 0.06 * Double(index), width: 0.8, height: 0.05))
		}
	}

	private static func runs(of block: RescrivaBlock) -> [RescrivaRun] {
		switch block.content {
		case .heading(_, let runs), .paragraph(let runs, _): return runs
		case .list(_, let items): return items.flatMap(\.runs)
		default: return []
		}
	}

	private static func columns(_ pattern: String) -> [Bool] {
		pattern.map { $0 == "x" }
	}
}

// MARK: - Samples and fonts

/// Text for the synthetic pages. Markup: `*bold*`, `/italic/`, `_underline_`, `~strikethrough~`.
private enum Sample {
	static let styled = """
		The quarterly *review* covers revenue, hiring and the product roadmap for the coming year. Our _central_ \
		finding is that /customer/ retention improved across every region, while ~legacy~ support costs fell \
		sharply. The team *shipped* four major releases and /closed/ most of the open issues before the deadline.
		Please read the _attached summary_ before the meeting, and note that the ~draft~ budget is *final* now. \
		Several /important/ decisions remain open, including the *staffing* plan for next year and the _launch_ \
		schedule for the new ~tablet~ product line in /Europe/ and beyond.
		"""

	static let plain = String(styled.filter { !"*/_~".contains($0) })

	/// Keys of the words drawn in each style.
	static let styledWords: [RunStyles: Set<String>] = [
		.bold: ["review", "shipped", "final", "staffing"],
		.italic: ["customer", "closed", "important", "europe"],
		.underline: ["central", "attached", "summary", "launch"],
		.strikethrough: ["legacy", "draft", "tablet"],
	]
}

/// A font family's regular, bold and italic faces.
private struct Family {
	let regular: String
	let bold: String
	let italic: String

	static let sans = Family(regular: "Helvetica", bold: "Helvetica-Bold", italic: "Helvetica-Oblique")
	static let serif = Family(regular: "TimesNewRomanPSMT", bold: "TimesNewRomanPS-BoldMT", italic: "TimesNewRomanPS-ItalicMT")
	static let mono = Family(regular: "Menlo-Regular", bold: "Menlo-Bold", italic: "Menlo-Italic")
	static let all = [sans, serif, mono]
}

/// Builds the attributed text for a marked-up sample.
private enum Markup {
	static func attributed(_ markup: String, family: Family, points: CGFloat) throws -> NSAttributedString {
		let regular = try XCTUnwrap(UIFont(name: family.regular, size: points), family.regular)
		let bold = try XCTUnwrap(UIFont(name: family.bold, size: points), family.bold)
		let italic = try XCTUnwrap(UIFont(name: family.italic, size: points), family.italic)
		let paragraph = NSMutableParagraphStyle()
		paragraph.lineHeightMultiple = 1.3
		let result = NSMutableAttributedString()
		var isBold = false, isItalic = false, isUnderlined = false, isStruck = false
		for character in markup {
			switch character {
			case "*": isBold.toggle()
			case "/": isItalic.toggle()
			case "_": isUnderlined.toggle()
			case "~": isStruck.toggle()
			default:
				var attributes: [NSAttributedString.Key: Any] = [.font: isBold ? bold : isItalic ? italic : regular,
																 .foregroundColor: UIColor.black, .paragraphStyle: paragraph]
				if isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
				if isStruck { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
				result.append(NSAttributedString(string: String(character), attributes: attributes))
			}
		}
		return result
	}
}

// MARK: - Drawn pages

/// One laid-out line: its text, its box as Vision would report it (from the tallest face's
/// ascender to the deepest descender), its baseline and x-height, and each word's drawn styles.
private struct DrawnLine {
	var text: String
	var rect: CGRect
	var baseline: CGFloat
	var xHeight: CGFloat
	var styles: [RunStyles]
}

/// A page of text laid out and drawn with TextKit at 1 px per point, black on white, with its
/// OCR lines and the styles each word was drawn in.
private struct StyledPage {
	var image: CGImage
	var size: CGSize
	var lines: [RecognizedLine]
	/// Per line, per word: the styles all its letters were drawn in.
	var expected: [[RunStyles]]
	var roles: [LineRole] { lines.map { _ in .body } }

	init(markup: String, family: Family, points: CGFloat = 36, decorate: ([DrawnLine]) -> Void = { _ in }) throws {
		try self.init(text: Markup.attributed(markup, family: family, points: points), decorate: decorate)
	}

	init(text: NSAttributedString, width: CGFloat = 1400, decorate: ([DrawnLine]) -> Void = { _ in }) throws {
		let margin: CGFloat = 60
		let storage = NSTextStorage(attributedString: text)
		let layout = NSLayoutManager()
		let container = NSTextContainer(size: CGSize(width: width - 2 * margin, height: .greatestFiniteMagnitude))
		container.lineFragmentPadding = 0
		layout.addTextContainer(container)
		storage.addLayoutManager(layout)
		let glyphs = layout.glyphRange(for: container)
		let size = CGSize(width: width, height: (layout.usedRect(for: container).height + 2 * margin).rounded(.up))
		let origin = CGPoint(x: margin, y: margin)
		var drawn: [DrawnLine] = []
		layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, range, _ in
			guard let line = Self.line(range, fragment: fragment, layout: layout, container: container, text: text, origin: origin) else { return }
			drawn.append(line)
		}
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		format.opaque = true
		format.preferredRange = .standard
		let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
			UIColor.white.setFill()
			context.fill(CGRect(origin: .zero, size: size))
			layout.drawBackground(forGlyphRange: glyphs, at: origin)
			layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
			decorate(drawn)
		}
		image = try XCTUnwrap(rendered.cgImage)
		self.size = size
		lines = drawn.map { line in
			RecognizedLine(text: line.text, confidence: 0.95, alternatives: [],
						   box: CGRect(x: line.rect.minX / size.width, y: line.rect.minY / size.height,
									   width: line.rect.width / size.width, height: line.rect.height / size.height))
		}
		expected = drawn.map(\.styles)
	}

	private static func line(_ glyphs: NSRange, fragment: CGRect, layout: NSLayoutManager, container: NSTextContainer,
							 text: NSAttributedString, origin: CGPoint) -> DrawnLine? {
		let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
		let string = (text.string as NSString).substring(with: characters)
		let trimmed = string.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
		guard !trimmed.isEmpty else { return nil }
		let range = NSRange(location: characters.location, length: (trimmed as NSString).length)
		let bounds = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
		let baseline = origin.y + fragment.minY + layout.location(forGlyphAt: glyphs.location).y
		var ascender: CGFloat = 0, descender: CGFloat = 0, xHeight: CGFloat = 0
		text.enumerateAttribute(.font, in: range) { value, _, _ in
			guard let font = value as? UIFont else { return }
			ascender = max(ascender, font.ascender)
			descender = min(descender, font.descender)
			xHeight = max(xHeight, font.xHeight)
		}
		var styles: [RunStyles] = []
		var offset = 0
		for word in trimmed.split(separator: " ", omittingEmptySubsequences: false) {
			let length = (String(word) as NSString).length
			if length > 0 {
				styles.append(drawnStyles(of: text, in: NSRange(location: range.location + offset, length: length)))
			}
			offset += length + 1
		}
		let rect = CGRect(x: origin.x + bounds.minX, y: baseline - ascender, width: bounds.width, height: ascender - descender)
		return DrawnLine(text: trimmed, rect: rect, baseline: baseline, xHeight: xHeight, styles: styles)
	}

	/// The styles every letter in `range` was drawn in.
	private static func drawnStyles(of text: NSAttributedString, in range: NSRange) -> RunStyles {
		var shared: RunStyles?
		let string = text.string as NSString
		for index in range.location..<(range.location + range.length) {
			guard let scalar = Unicode.Scalar(string.character(at: index)), CharacterSet.letters.contains(scalar) else { continue }
			let attributes = text.attributes(at: index, effectiveRange: nil)
			var styles: RunStyles = []
			let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
			if traits.contains(.traitBold) { styles.insert(.bold) }
			if traits.contains(.traitItalic) { styles.insert(.italic) }
			if (attributes[.underlineStyle] as? Int ?? 0) != 0 { styles.insert(.underline) }
			if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { styles.insert(.strikethrough) }
			shared = shared.map { $0.intersection(styles) } ?? styles
		}
		return shared ?? []
	}
}

// MARK: - Perturbations

/// What a scan does to a page before the detector reads it: a blur, a slight turn, sensor noise
/// and JPEG compression. The OCR boxes turn with the page (Vision reports the upright box around
/// each turned line).
private struct Perturbation {
	var blurPasses: Int
	var degrees: Double
	var noise: Int
	var quality: CGFloat

	static let soft = Perturbation(blurPasses: 1, degrees: 0, noise: 0, quality: 0.6)
	static let scanned = Perturbation(blurPasses: 1, degrees: 0.5, noise: 10, quality: 0.6)
	static let all = [soft, scanned]

	func applied(to page: StyledPage) throws -> (data: Data, lines: [RecognizedLine]) {
		let gray = try XCTUnwrap(StyleDetector.Gray(image: page.image, maxSide: 4096))
		var pixels = rotated(gray)
		for _ in 0..<blurPasses {
			pixels = blurred(pixels, width: gray.width, height: gray.height)
		}
		pixels = noised(pixels)
		let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
		let image = try XCTUnwrap(CGImage(width: gray.width, height: gray.height, bitsPerComponent: 8, bitsPerPixel: 8,
										  bytesPerRow: gray.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
										  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
		let data = try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: quality))
		let lines = page.lines.map { line in
			var turned = line
			turned.box = turnedBox(line.box, size: page.size)
			return turned
		}
		return (data, lines)
	}

	/// Each output pixel sampled (bilinear) from the page turned back about its centre; white outside.
	private func rotated(_ gray: StyleDetector.Gray) -> [UInt8] {
		guard degrees != 0 else { return gray.pixels }
		let angle = degrees * .pi / 180, cosine = cos(angle), sine = sin(angle)
		let cx = Double(gray.width) / 2, cy = Double(gray.height) / 2
		var out = [UInt8](repeating: 255, count: gray.pixels.count)
		for y in 0..<gray.height {
			for x in 0..<gray.width {
				let dx = Double(x) - cx, dy = Double(y) - cy
				let sx = cx + dx * cosine + dy * sine, sy = cy - dx * sine + dy * cosine
				let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
				guard x0 >= 0, y0 >= 0, x0 + 1 < gray.width, y0 + 1 < gray.height else { continue }
				let fx = sx - Double(x0), fy = sy - Double(y0)
				let at = { (px: Int, py: Int) in Double(gray.pixels[py * gray.width + px]) }
				let value = (at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx) * (1 - fy) + (at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx) * fy
				out[y * gray.width + x] = UInt8(max(0, min(255, value.rounded())))
			}
		}
		return out
	}

	/// The upright box around `box` turned with the page.
	private func turnedBox(_ box: CGRect, size: CGSize) -> CGRect {
		let angle = degrees * .pi / 180
		let cx = size.width / 2, cy = size.height / 2
		let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
					   CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)].map { corner in
			let dx = corner.x * size.width - cx, dy = corner.y * size.height - cy
			return CGPoint(x: (cx + dx * cos(angle) - dy * sin(angle)) / size.width, y: (cy + dx * sin(angle) + dy * cos(angle)) / size.height)
		}
		let xs = corners.map(\.x), ys = corners.map(\.y)
		return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
	}

	/// A [1 2 1] / 4 blur across and down.
	private func blurred(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
		var across = pixels
		for y in 0..<height {
			for x in 1..<(width - 1) {
				let row = y * width
				across[row + x] = UInt8((Int(pixels[row + x - 1]) + 2 * Int(pixels[row + x]) + Int(pixels[row + x + 1]) + 2) / 4)
			}
		}
		var down = across
		for y in 1..<(height - 1) {
			for x in 0..<width {
				down[y * width + x] = UInt8((Int(across[(y - 1) * width + x]) + 2 * Int(across[y * width + x]) + Int(across[(y + 1) * width + x]) + 2) / 4)
			}
		}
		return down
	}

	/// Uniform noise of ±`noise` grey levels from a fixed seed, so every run sees the same page.
	private func noised(_ pixels: [UInt8]) -> [UInt8] {
		guard noise > 0 else { return pixels }
		var state: UInt64 = 0x9E3779B97F4A7C15
		return pixels.map { value in
			state = state &* 6364136223846793005 &+ 1442695040888963407
			let offset = Int((state >> 33) % UInt64(2 * noise + 1)) - noise
			return UInt8(max(0, min(255, Int(value) + offset)))
		}
	}
}

// MARK: - Scoring

/// Per-style counts of words the detector styled rightly, wrongly, or missed.
private struct StyleScore {
	static let styles: [(name: String, style: RunStyles)] = [("bold", .bold), ("italic", .italic),
															 ("underline", .underline), ("strikethrough", .strikethrough)]
	private var hits: [String: Int] = [:]
	private var wrong: [String: Int] = [:]
	private var missed: [String: Int] = [:]

	/// Every style the detector claimed, right or wrong.
	var claims: Int { hits.values.reduce(0, +) + wrong.values.reduce(0, +) }

	var summary: String {
		Self.styles.map { name, style in
			"\(name): \(hits[name, default: 0]) right, \(wrong[name, default: 0]) wrong, \(missed[name, default: 0]) missed"
				+ " (precision \(String(format: "%.2f", precision(style))), recall \(String(format: "%.2f", recall(style))))"
		}.joined(separator: "; ")
	}

	mutating func add(_ found: [LineStyles], expected: [[RunStyles]]) {
		let byLine = Dictionary(found.map { ($0.line, $0.styles) }, uniquingKeysWith: { first, _ in first })
		for (line, words) in expected.enumerated() {
			for (index, truth) in words.enumerated() {
				let said = byLine[line].flatMap { $0[safe: index] ?? nil } ?? []
				for (name, style) in Self.styles {
					switch (said.contains(style), truth.contains(style)) {
					case (true, true): hits[name, default: 0] += 1
					case (true, false): wrong[name, default: 0] += 1
					case (false, true): missed[name, default: 0] += 1
					case (false, false): break
					}
				}
			}
		}
	}

	func precision(_ style: RunStyles) -> Double {
		let name = Self.name(of: style)
		let claimed = hits[name, default: 0] + wrong[name, default: 0]
		return claimed == 0 ? 1 : Double(hits[name, default: 0]) / Double(claimed)
	}

	func recall(_ style: RunStyles) -> Double {
		let name = Self.name(of: style)
		let actual = hits[name, default: 0] + missed[name, default: 0]
		return actual == 0 ? 1 : Double(hits[name, default: 0]) / Double(actual)
	}

	private static func name(of style: RunStyles) -> String {
		styles.first { $0.style == style }?.name ?? ""
	}
}

private extension RescrivaRun {
	func has(_ style: RunStyles) -> Bool {
		(style.contains(.bold) && bold) || (style.contains(.italic) && italic)
			|| (style.contains(.underline) && underline) || (style.contains(.strikethrough) && strikethrough)
	}
}
