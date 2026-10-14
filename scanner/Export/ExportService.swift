//
//  ExportService.swift
//  Rescriva (fork of Open Scanner)
//
//  Writes a scan to a file in the chosen format, ready for the share sheet.
//  Word, PowerPoint, Markdown and plain text come from the rebuilt
//  RescrivaDocument (Word and PowerPoint with its figures' pictures, from
//  FigureStore, and a typeset picture of every equation the OMML converter
//  can't handle); the searchable PDF comes from the page images and their
//  recognized text. Everything slow renders off the main actor.
//

import Foundation

/// The five export formats. Stored token.
enum ExportFormat: String, CaseIterable, Identifiable {
	case docx, pptx, pdf, md, txt

	var id: String { rawValue }

	var fileExtension: String { ".\(rawValue)" }

	var label: LocalizedStringResource {
		switch self {
		case .docx: return "Word document"
		case .pptx: return "PowerPoint"
		case .pdf: return "Searchable PDF"
		case .md: return "Markdown"
		case .txt: return "Plain text"
		}
	}

	var detail: LocalizedStringResource {
		switch self {
		case .docx: return "Editable text, tables, equation and diagram"
		case .pptx: return "One slide per page, with theme colors"
		case .pdf: return "Looks like the scan, text is selectable"
		case .md: return "Headings, lists, tables and Mermaid diagrams for AI tools"
		case .txt: return "Just the words"
		}
	}

	/// Where notes go in this format.
	var notesLabel: LocalizedStringResource {
		switch self {
		case .docx: return "Notes as Word comments"
		case .pptx: return "Notes as speaker notes"
		case .pdf: return "Notes as PDF annotations"
		case .md: return "Notes as a Notes section"
		case .txt: return "Include notes"
		}
	}

	/// Word, PowerPoint and Markdown need a rebuild-capable iPhone.
	var needsRebuild: Bool { self == .docx || self == .pptx || self == .md }
}

/// Builds export files.
@MainActor
enum ExportService {
	/// Writes `scan` as `format` into a fresh temporary folder and returns the file URL. Word and
	/// PowerPoint files carry the figures' pictures from `figures` (cut now when missing); a PDF
	/// follows `pdfOptions` (paper, image quality, password).
	static func makeFile(for scan: Scan, format: ExportFormat, includeNotes: Bool,
						 pdfOptions: PDFExportOptions = PDFExportOptions(),
						 figures: FigureStore = .shared) async throws -> URL {
		let data: Data
		var options = RenderOptions()
		options.includeNotes = includeNotes
		await settleStalePages(of: scan)
		switch format {
		case .pdf:
			let pages = await SearchablePDF.pages(for: scan, includeNotes: includeNotes)
			let title = scan.displayTitle
			// Each page's look and encoding take a moment, so the PDF is written off the main thread.
			data = await Task.detached(priority: .userInitiated) {
				SearchablePDF.render(pages, title: title, options: pdfOptions)
			}.value
		case .txt:
			if let document = scan.rebuiltDocument {
				data = Data(PlainTextRenderer.render(document, options: options).utf8)
			} else {
				let text = scan.capturesArray
					.map { $0.recognizedItemsArray.compactMap(\.transcript).joined(separator: "\n") }
					.joined(separator: "\n\n")
				data = Data(text.utf8)
			}
		case .md:
			let document = await currentDocument(for: scan)
			let renderOptions = options
			data = await Task.detached(priority: .userInitiated) {
				Data(MarkdownRenderer.render(document, options: renderOptions).utf8)
			}.value
		case .docx, .pptx:
			let document = await currentDocument(for: scan)
			// Pictures are gathered here, on the main actor, so the renderers stay pure.
			let figurePictures = await FigureAssets.assets(for: document, of: scan, store: figures)
			options.assets = figurePictures.merging(EquationPictures.pictures(for: document)) { figure, _ in figure }
			let renderOptions = options
			// Packaging a long document is real work (XML, DEFLATE), so it runs off the main thread;
			// the document and the options are value types, copied into the task.
			data = try await Task.detached(priority: .userInitiated) {
				if format == .docx {
					return try DOCXRenderer.render(document, options: renderOptions)
				}
				return try PPTXRenderer.render(document, options: renderOptions)
			}.value
		}
		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("Exports", isDirectory: true)
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let url = folder.appendingPathComponent(fileName(for: scan, format: format))
		try data.write(to: url, options: .atomic)
		return url
	}

	/// The scan as Markdown with Mermaid diagrams, for "Copy for AI": the same text the `.md`
	/// export writes. Empty when the scan has no words.
	static func markdown(for scan: Scan, includeNotes: Bool) async -> String {
		await settleStalePages(of: scan)
		let document = await currentDocument(for: scan)
		let options = RenderOptions(includeNotes: includeNotes)
		return await Task.detached(priority: .userInitiated) {
			MarkdownRenderer.render(document, options: options)
		}.value
	}

	/// "Lab notes — week 6.docx", made safe for file systems.
	static func fileName(for scan: Scan, format: ExportFormat) -> String {
		let base = scan.displayTitle.safeFileName()
		return (base.isEmpty ? "Scan" : base) + format.fileExtension
	}

	/// A page re-made moments ago may still be waiting for its part of the rebuilt document;
	/// settles it first, so the notes and words exported with it match its new pixels.
	private static func settleStalePages(of scan: Scan) async {
		guard scan.rebuiltDocument?.hasStalePages == true else { return }
		_ = await Rebuilder(tier: DeviceTier.current).refreshStalePages(of: scan)
	}

	/// The scan's rebuilt document, rebuilding first if it has none or its
	/// pages changed.
	private static func currentDocument(for scan: Scan) async -> RescrivaDocument {
		await Rebuilder(tier: DeviceTier.current).document(for: scan) { _ in }
	}
}

extension EquationPictures {
	/// A typeset PNG for every equation in `document` that `needsPicture`, keyed by
	/// `assetKey(for:)`, drawn from the app's own equation preview; an equation the preview can't
	/// typeset either gets none (the renderers then print its linear text). Runs on the main
	/// actor, before the renderers, which only read the result.
	@MainActor
	static func pictures(for document: RescrivaDocument) -> [String: Data] {
		var pictures: [String: Data] = [:]
		for page in document.pages {
			for block in page.blocks {
				guard case .equation(let latex, _, _) = block.content, needsPicture(latex) else { continue }
				let key = assetKey(for: latex)
				guard pictures[key] == nil, let data = EquationView.pngData(latex: latex, scale: scale) else { continue }
				pictures[key] = data
			}
		}
		return pictures
	}
}
