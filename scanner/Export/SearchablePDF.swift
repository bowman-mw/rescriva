//
//  SearchablePDF.swift
//  Rescriva (fork of Open Scanner)
//
//  The PDF scan every iPhone gets: each page image with an invisible OCR
//  text layer laid over the words, so the PDF looks like the scan and its
//  text is selectable and searchable. Replaces Open Scanner's image-only
//  `pdfDocument()`. Words fixed in Review reach the text layer through
//  `TextLayerReconciler`. Notes become PDF annotations; marks from Annotate
//  are drawn over the page. Paper size, image quality and an optional
//  password come from `PDFExportOptions`.
//

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import PDFKit
import UIKit

enum SearchablePDF {
	/// One page to write: the image and its recognized lines.
	struct Page {
		var image: UIImage
		var lines: [RecognizedLine]
		/// Notes to pin to the page (top-left anchored at their box, if any).
		var notes: [(text: String, box: NormalizedBox?)] = []
		/// Pen, highlighter and shape marks from Annotate, drawn over the image without its look.
		var marks: [PageMark] = []
		/// The look still to apply when the page is written (`.original` when the image already
		/// has it). Black and white pages may be stored at one bit per pixel.
		var look: LookFilter = .original
		/// The stored page `image` was made from, when it was: the pixels are then decoded from it
		/// only as the page is written, and let go after, so a long scan never holds every page's
		/// decoded pixels at once (`image` itself is never drawn, and only gives the page's shape).
		var imageData: Data? = nil
	}

	/// Pages for a scan, carrying its look (applied as each page is written, so only one page's
	/// pixels are decoded at a time), the text layer with the fixes made in Review (see
	/// `TextLayerReconciler`) and (optionally) the rebuilt document's notes.
	@MainActor
	static func pages(for scan: Scan, includeNotes: Bool) async -> [Page] {
		let document = scan.rebuiltDocument
		let captures = scan.capturesArray
		var pages: [Page] = []
		var layers: [(lines: [RecognizedLine], rebuilt: RescrivaPage?)] = []
		for (index, capture) in captures.enumerated() {
			guard let image = capture.image else { continue }
			let lines = capture.recognizedItemsArray.map(\.recognizedLine)
			// The rebuilt page made from this capture, if any; without one the layer is the OCR as read.
			let rebuilt = document.flatMap {
				TextLayerReconciler.page(in: $0, captureID: capture.id, index: index, captureCount: captures.count)
			}
			// Notes come from the same rebuilt page as the text layer, found by capture, not by position:
			// after pages were moved or deleted, the page at this position is another capture's.
			pages.append(Page(image: image, lines: lines, notes: includeNotes ? notes(on: rebuilt) : [],
							  marks: capture.pageMarks, look: scan.lookFilter, imageData: capture.imageData))
			layers.append((lines, rebuilt))
		}
		// Aligning a dense page takes tens of milliseconds, so the text layers are made off the main thread.
		let reconciled = await Task.detached(priority: .userInitiated) {
			layers.map { TextLayerReconciler.textLayer($0.lines, page: $0.rebuilt) }
		}.value
		assert(reconciled.count == pages.count, "one text layer per page")
		for index in pages.indices {
			pages[index].lines = reconciled[index]
		}
		return pages
	}

	/// A rebuilt page's notes: the page's own, unpinned, then each block's at its box.
	private static func notes(on page: RescrivaPage?) -> [(text: String, box: NormalizedBox?)] {
		guard let page else { return [] }
		var notes: [(text: String, box: NormalizedBox?)] = page.notes.map { ($0.text, nil) }
		for block in page.blocks {
			notes += block.notes.map { ($0.text, block.box) }
		}
		return notes
	}

	/// Writes the PDF: each page laid out on `options.paperSize` (`PDFPageLayout`), its image with
	/// its look at `options.quality`, its marks, the invisible text layer and the notes all in the
	/// one image rect, and the whole file encrypted when `options` has a password. Slow for long
	/// scans (each page's look and encoding); safe off the main thread.
	static func render(_ pages: [Page], title: String, options: PDFExportOptions = PDFExportOptions()) -> Data {
		// The image rect of each page, computed once: the image, its marks, text layer and notes share it.
		let layouts = pages.map { PDFPageLayout.fitting(aspect: $0.image.aspectRatio, on: options.paperSize) }
		assert(layouts.count == pages.count, "one layout per page")
		let format = UIGraphicsPDFRendererFormat()
		format.documentInfo = documentInfo(title: title, password: options.encryptionPassword)
		let renderer = UIGraphicsPDFRenderer(bounds: layouts.first?.pageRect ?? PDFPageLayout.fitting(aspect: 0, on: .pageSize).pageRect,
											 format: format)
		let data = renderer.pdfData { context in
			for (page, layout) in zip(pages, layouts) {
				autoreleasepool {
					// Decoded here from the stored page when there is one, so its pixels go with this step.
					let source = page.imageData.flatMap { UIImage(data: $0) } ?? page.image
					let image = PDFImageEncoder.encoded(LookRenderer.apply(page.look, to: source), quality: options.quality,
														bilevel: page.look == .blackAndWhite)
					context.beginPage(withBounds: layout.pageRect, pageInfo: [:])
					// The page image, in the rect its marks, text layer and notes share. Marks go over
					// the image, without its look, clipped to it, and under the invisible text.
					image.draw(in: layout.imageRect)
					MarkRenderer.draw(page.marks, in: layout.imageRect, context: context.cgContext)
					drawInvisibleText(page.lines, in: layout.imageRect, context: context.cgContext)
				}
			}
		}
		guard pages.contains(where: { !$0.notes.isEmpty }) else { return data }
		return annotated(data, pages: pages, layouts: layouts, password: options.encryptionPassword) ?? data
	}

	/// The PDF's document info: title and creator, plus user and owner passwords (128-bit keys)
	/// when there is a password, which encrypts the file.
	static func documentInfo(title: String, password: String?) -> [String: Any] {
		var info: [String: Any] = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Rescriva"]
		guard let password, !password.isEmpty else { return info }
		info[kCGPDFContextUserPassword as String] = password
		info[kCGPDFContextOwnerPassword as String] = password
		info[kCGPDFContextEncryptionKeyLength as String] = 128
		return info
	}

	/// `data` with each page's notes pinned as text annotations inside its image rect, written back
	/// with the same password; nil when it can't be opened or written (the caller keeps `data`).
	private static func annotated(_ data: Data, pages: [Page], layouts: [PDFPageLayout], password: String?) -> Data? {
		guard let document = PDFDocument(data: data) else { return nil }
		if document.isLocked {
			guard let password, document.unlock(withPassword: password) else { return nil }
		}
		for (index, page) in pages.enumerated() {
			guard let pdfPage = document.page(at: index), let layout = layouts[safe: index] else { continue }
			let rect = layout.imageRect
			let pageHeight = layout.pageRect.height
			for (offset, note) in page.notes.enumerated() {
				// PDF space is bottom-up; pin each note at its block's top-left corner in the image.
				let x = rect.minX + (note.box?.x ?? 0.04) * rect.width
				let y = pageHeight - (rect.minY + (note.box?.y ?? 0.04) * rect.height) - 20 - CGFloat(offset) * 4
				let annotation = PDFAnnotation(bounds: CGRect(x: x, y: y, width: 20, height: 20), forType: .text, withProperties: nil)
				annotation.contents = note.text
				annotation.color = RescrivaPalette.highlighter.onPaper
				pdfPage.addAnnotation(annotation)
			}
		}
		guard let password, !password.isEmpty else { return document.dataRepresentation() }
		return document.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: password,
													 PDFDocumentWriteOption.ownerPasswordOption: password])
	}

	/// Draws each line invisibly over its box, scaled to the box's width.
	private static func drawInvisibleText(_ lines: [RecognizedLine], in rect: CGRect, context: CGContext) {
		for line in lines where !line.text.isEmpty && line.box.width > 0 && line.box.height > 0 {
			let box = CGRect(x: rect.minX + line.box.minX * rect.width, y: rect.minY + line.box.minY * rect.height,
							 width: line.box.width * rect.width, height: line.box.height * rect.height)
			let font = CTFontCreateWithName("Helvetica" as CFString, max(box.height * 0.82, 1), nil)
			let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
			let ctLine = CTLineCreateWithAttributedString(attributed)
			var ascent: CGFloat = 0
			var descent: CGFloat = 0
			let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
			guard width > 0 else { continue }
			context.saveGState()
			context.setTextDrawingMode(.invisible)
			context.textMatrix = .identity
			context.translateBy(x: box.minX, y: box.maxY)
			context.scaleBy(x: box.width / width, y: -1)
			context.textPosition = CGPoint(x: 0, y: descent)
			CTLineDraw(ctLine, context)
			context.restoreGState()
		}
	}
}

/// Applies a scan's "Look" to page images for export.
enum LookRenderer {
	private static let context = CIContext(options: [.useSoftwareRenderer: false])

	/// `image` with `look`: the one recipe the export and the preview share (see
	/// `LookRenderer.preview`). Safe off the main thread.
	static func apply(_ look: LookFilter, to image: UIImage) -> UIImage {
		guard look != .original, let input = CIImage(image: image) else { return image }
		guard let output = looked(look, input), let cgImage = context.createCGImage(output, from: input.extent) else { return image }
		return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
	}

	/// Core Image for `look`: tone controls for Color and Gray, `PageLooks` for B&W and Ink; nil
	/// for Original.
	private static func looked(_ look: LookFilter, _ input: CIImage) -> CIImage? {
		switch look {
		case .color:
			return colorControls(input, saturation: 1.08, contrast: 1.05)
		case .gray:
			return colorControls(input, saturation: 0, contrast: 1.05)
		case .blackAndWhite:
			return PageLooks.blackAndWhite(input)
		case .ink:
			return PageLooks.ink(input, context: context)
		case .original:
			return nil
		}
	}

	private static func colorControls(_ input: CIImage, saturation: Float, contrast: Float) -> CIImage? {
		let filter = CIFilter.colorControls()
		filter.inputImage = input
		filter.saturation = saturation
		filter.contrast = contrast
		filter.brightness = 0
		return filter.outputImage
	}
}

extension Array {
	subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}
