//
//  PDFOptionsTests.swift
//  Rescriva (fork of Open Scanner)
//
//  The searchable PDF's options: how pages fit on their paper (page size, A4
//  and Letter, portrait and landscape images), the image quality presets and
//  their encoding (JPEG, or one bit per pixel for black and white), the text
//  layer, notes and Annotate marks following the image's rect (and their
//  page, after pages move), pages drawn from their stored data, and password
//  protection, down to a whole export from an in-memory scan — and, with the
//  same in-memory scan, the Markdown export and "Copy for AI".
//

import CoreData
import PDFKit
import UIKit
import XCTest
@testable import scanner

final class PDFOptionsTests: XCTestCase {
	/// Keeps in-memory stores alive for the test's duration.
	private var containers: [NSPersistentContainer] = []

	// MARK: Page fit

	func testPageSizeKeepsEachPageTheShapeOfItsImage() {
		let portrait = PDFPageLayout.fitting(aspect: 0.75, on: .pageSize)
		XCTAssertEqual(portrait.pageRect, CGRect(x: 0, y: 0, width: 612, height: 816))
		XCTAssertEqual(portrait.imageRect, portrait.pageRect, "the image fills its page")

		let landscape = PDFPageLayout.fitting(aspect: 4.0 / 3.0, on: .pageSize)
		XCTAssertEqual(landscape.pageRect.width, 792)
		XCTAssertEqual(landscape.pageRect.height, 594, accuracy: 1e-9)
		XCTAssertEqual(landscape.imageRect, landscape.pageRect)
	}

	func testAPortraitImageOnA4FillsTheWidthInsideTheMarginAndIsCentred() {
		let layout = PDFPageLayout.fitting(aspect: 0.75, on: .a4)

		XCTAssertEqual(layout.pageRect, CGRect(x: 0, y: 0, width: 595.28, height: 841.89))
		XCTAssertEqual(layout.imageRect.minX, 18, accuracy: 1e-6)
		XCTAssertEqual(layout.imageRect.width, 559.28, accuracy: 1e-6)
		XCTAssertEqual(layout.imageRect.height, 559.28 / 0.75, accuracy: 1e-6)
		XCTAssertEqual(layout.imageRect.midY, 841.89 / 2, accuracy: 1e-6)
	}

	func testALandscapeImageTurnsTheSheet() {
		let letter = PDFPageLayout.fitting(aspect: 1.5, on: .letter)
		XCTAssertEqual(letter.pageRect.size, CGSize(width: 792, height: 612))
		XCTAssertEqual(letter.imageRect.minX, 18, accuracy: 1e-6)
		XCTAssertEqual(letter.imageRect.size.width, 756, accuracy: 1e-6)
		XCTAssertEqual(letter.imageRect.size.height, 504, accuracy: 1e-6)
		XCTAssertEqual(letter.imageRect.minY, 54, accuracy: 1e-6)

		let a4 = PDFPageLayout.fitting(aspect: 1.6, on: .a4)
		XCTAssertEqual(a4.pageRect.size, CGSize(width: 841.89, height: 595.28))
		XCTAssertEqual(a4.imageRect.width, 805.89, accuracy: 1e-6)
		XCTAssertEqual(a4.imageRect.midY, 595.28 / 2, accuracy: 1e-6)
	}

	func testATallImageOnLetterFillsTheHeightAndIsCentredAcross() {
		let layout = PDFPageLayout.fitting(aspect: 0.5, on: .letter)

		XCTAssertEqual(layout.pageRect.size, CGSize(width: 612, height: 792))
		XCTAssertEqual(layout.imageRect, CGRect(x: 117, y: 18, width: 378, height: 756))
	}

	func testEveryFitKeepsTheAspectInsideTheMarginCentred() {
		for paper in [PDFPaperSize.a4, .letter] {
			for aspect in [0.2, 0.5, 0.707, 0.75, 1, 1.1, 1.414, 1.78, 3] as [CGFloat] {
				let layout = PDFPageLayout.fitting(aspect: aspect, on: paper)
				let room = layout.pageRect.insetBy(dx: PDFPageLayout.margin, dy: PDFPageLayout.margin)
				XCTAssertTrue(room.insetBy(dx: -1e-6, dy: -1e-6).contains(layout.imageRect), "\(paper) \(aspect)")
				XCTAssertEqual(layout.imageRect.width / layout.imageRect.height, aspect, accuracy: 1e-6)
				XCTAssertEqual(layout.imageRect.midX, layout.pageRect.midX, accuracy: 1e-6)
				XCTAssertEqual(layout.imageRect.midY, layout.pageRect.midY, accuracy: 1e-6)
				XCTAssertEqual(layout.pageRect.width > layout.pageRect.height, aspect > 1, "the sheet follows the image")
				let touches = abs(layout.imageRect.width - room.width) < 1e-6 || abs(layout.imageRect.height - room.height) < 1e-6
				XCTAssertTrue(touches, "the image is as large as the margin allows")
			}
		}
	}

	func testAnImageWithoutAUsableShapeGetsALetterShapedPage() {
		for aspect in [0, -1, .nan, .infinity] as [CGFloat] {
			let layout = PDFPageLayout.fitting(aspect: aspect, on: .pageSize)
			XCTAssertEqual(layout.pageRect.width, 612)
			XCTAssertEqual(layout.pageRect.height, 612 / PDFPageLayout.fallbackAspect, accuracy: 1e-6)
		}
	}

	// MARK: Image quality

	func testQualityPresets() {
		XCTAssertEqual(PDFImageQuality.allCases.map(\.maxPixels), [2400, 1800, 1200])
		XCTAssertEqual(PDFImageQuality.allCases.map(\.jpegQuality), [0.8, 0.7, 0.6])
		XCTAssertEqual(PDFImageQuality.allCases.map(\.rawValue), ["high", "medium", "small"])
		XCTAssertEqual(PDFPaperSize.allCases.map(\.rawValue), ["page", "a4", "letter"])
	}

	func testEachQualityCapsTheLongSideAndNeverEnlarges() throws {
		let large = try page(width: 3000, height: 2000)
		XCTAssertEqual(PDFImageEncoder.pixelSize(of: large, maxPixels: 2400), CGSize(width: 2400, height: 1600))
		XCTAssertEqual(PDFImageEncoder.pixelSize(of: large, maxPixels: 1800), CGSize(width: 1800, height: 1200))
		XCTAssertEqual(PDFImageEncoder.pixelSize(of: large, maxPixels: 1200), CGSize(width: 1200, height: 800))
		let small = try page(width: 800, height: 600)
		XCTAssertEqual(PDFImageEncoder.pixelSize(of: small, maxPixels: 2400), CGSize(width: 800, height: 600))

		var sizes: [Int] = []
		for quality in PDFImageQuality.allCases {
			let encoded = PDFImageEncoder.encoded(large, quality: quality, bilevel: false)
			let cgImage = try XCTUnwrap(encoded.cgImage)
			XCTAssertEqual(max(cgImage.width, cgImage.height), Int(quality.maxPixels))
			XCTAssertEqual(cgImage.bitsPerComponent, 8)
			sizes.append(SearchablePDF.render([SearchablePDF.Page(image: large, lines: [])], title: "Q",
											  options: PDFExportOptions(quality: quality)).count)
		}
		XCTAssertEqual(sizes, sizes.sorted(by: >), "smaller presets make smaller files: \(sizes)")
	}

	func testABlackAndWhitePageIsStoredAtOneBitPerPixelWhenThatIsSmaller() throws {
		let text = try page(width: 1200, height: 1600)

		let bilevel = try XCTUnwrap(PDFImageEncoder.encoded(LookRenderer.apply(.blackAndWhite, to: text), quality: .high, bilevel: true).cgImage)
		let jpeg = try XCTUnwrap(PDFImageEncoder.encoded(LookRenderer.apply(.blackAndWhite, to: text), quality: .high, bilevel: false).cgImage)

		XCTAssertEqual(bilevel.bitsPerPixel, 1)
		XCTAssertEqual(bilevel.width, 1200)
		XCTAssertEqual(jpeg.bitsPerComponent, 8)
		let oneBit = SearchablePDF.render([SearchablePDF.Page(image: text, lines: [], look: .blackAndWhite)], title: "B&W")
		let gray = SearchablePDF.render([SearchablePDF.Page(image: text, lines: [], look: .gray)], title: "Gray")
		XCTAssertTrue(String(decoding: oneBit, as: UTF8.self).contains("/BitsPerComponent 1"))
		XCTAssertLessThan(oneBit.count * 2, gray.count, "\(oneBit.count) bytes against \(gray.count)")
	}

	func testPackedBitsMarkPaperAndInk() throws {
		let space = CGColorSpaceCreateDeviceGray()
		let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: space,
											  bitmapInfo: CGImageAlphaInfo.none.rawValue))
		context.setFillColor(gray: 1, alpha: 1)
		context.fill(CGRect(x: 0, y: 0, width: 10, height: 2))
		context.setFillColor(gray: 0, alpha: 1)
		context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
		context.fill(CGRect(x: 9, y: 1, width: 1, height: 1))
		let gray = try XCTUnwrap(context.makeImage())

		let bits = try XCTUnwrap(PDFImageEncoder.packedBits(gray))

		// Two bytes a row; the top row (y = 1 in the context) has ink at both ends.
		XCTAssertEqual([UInt8](bits), [0b0111_1111, 0b1000_0000, 0b1111_1111, 0b1100_0000])
	}

	// MARK: Text layer and notes

	func testTheTextLayerAndNotesFollowTheImageRect() throws {
		let image = try page(width: 600, height: 800)
		let line = RecognizedLine(text: "Quarterly", confidence: 1, alternatives: [], box: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.05))
		let pages = [SearchablePDF.Page(image: image, lines: [line], notes: [("Check this", NormalizedBox(x: 0.5, y: 0.5, width: 0.1, height: 0.1))])]
		let layout = PDFPageLayout.fitting(aspect: 0.75, on: .a4)

		let data = SearchablePDF.render(pages, title: "Fit", options: PDFExportOptions(paperSize: .a4))

		let document = try XCTUnwrap(PDFDocument(data: data))
		let pdfPage = try XCTUnwrap(document.page(at: 0))
		XCTAssertEqual(pdfPage.bounds(for: .mediaBox).size, layout.pageRect.size)
		let rect = layout.imageRect
		let found = try XCTUnwrap(document.findString("Quarterly", withOptions: []).first)
		let bounds = found.bounds(for: pdfPage)
		XCTAssertEqual(bounds.midX, rect.minX + 0.5 * rect.width, accuracy: 6, "the word sits over its box in the image")
		XCTAssertEqual(bounds.midY, layout.pageRect.height - (rect.minY + 0.525 * rect.height), accuracy: 8)
		let note = try XCTUnwrap(pdfPage.annotations.first { $0.contents == "Check this" })
		XCTAssertEqual(note.bounds.minX, rect.minX + 0.5 * rect.width, accuracy: 0.5, "the note is pinned in the image, not the margin")
		XCTAssertEqual(note.bounds.maxY, layout.pageRect.height - (rect.minY + 0.5 * rect.height), accuracy: 0.5)
	}

	func testMarksAreDrawnInTheImageRectWithoutTheLook() throws {
		let image = try TestDrawing(width: 600, height: 800).image { context, size in TestDrawing.fill(context, size: size, level: 1) }
		// A short red stroke near the image's bottom-right corner, which is margin on the A4 sheet.
		let mark = PageMark(kind: .pen, points: [CGPoint(x: 0.94, y: 0.95), CGPoint(x: 0.96, y: 0.95)], color: 0xD0392B, width: 0.02)
		let pages = [SearchablePDF.Page(image: image, lines: [], marks: [mark], look: .gray)]
		let layout = PDFPageLayout.fitting(aspect: 0.75, on: .a4)

		let data = SearchablePDF.render(pages, title: "Marks", options: PDFExportOptions(paperSize: .a4))

		let pdfPage = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
		let sheet = layout.pageRect.size
		let pixels = try TestPixels(pdfPage.thumbnail(of: sheet, for: .mediaBox))
		let scale = CGFloat(pixels.width) / sheet.width
		let rect = layout.imageRect
		let onMark = pixels.colour(at: CGPoint(x: (rect.minX + 0.95 * rect.width) * scale, y: (rect.minY + 0.95 * rect.height) * scale))
		XCTAssertGreaterThan(onMark.red, 0.6, "the mark sits at its place in the image")
		XCTAssertLessThan(onMark.green, 0.4, "in its own colour: the page's gray look isn't applied to it")
		let onSheet = pixels.colour(at: CGPoint(x: 0.95 * sheet.width * scale, y: 0.95 * sheet.height * scale))
		XCTAssertGreaterThan(onSheet.green, 0.8, "not placed on the whole sheet")
	}

	func testAMarkReachingPastThePageStopsAtTheImageEdge() throws {
		let image = try TestDrawing(width: 600, height: 800).image { context, size in TestDrawing.fill(context, size: size, level: 1) }
		// A stroke down from inside the page to below it, as a new crop or a split can leave one.
		let mark = PageMark(kind: .pen, points: [CGPoint(x: 0.5, y: 0.9), CGPoint(x: 0.5, y: 1.06)], color: 0xD0392B, width: 0.02)
		let pages = [SearchablePDF.Page(image: image, lines: [], marks: [mark])]
		let layout = PDFPageLayout.fitting(aspect: 0.75, on: .a4)
		let rect = layout.imageRect
		XCTAssertLessThan(rect.minY + 1.04 * rect.height, layout.pageRect.maxY - 4, "the stroke's end is over the sheet's margin")

		let data = SearchablePDF.render(pages, title: "Clipped", options: PDFExportOptions(paperSize: .a4))

		let pdfPage = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
		let sheet = layout.pageRect.size
		let pixels = try TestPixels(pdfPage.thumbnail(of: sheet, for: .mediaBox))
		let scale = CGFloat(pixels.width) / sheet.width
		let inside = pixels.colour(at: CGPoint(x: rect.midX * scale, y: (rect.minY + 0.95 * rect.height) * scale))
		XCTAssertGreaterThan(inside.red, 0.6, "drawn on the page")
		XCTAssertLessThan(inside.green, 0.4)
		let margin = pixels.colour(at: CGPoint(x: rect.midX * scale, y: (rect.minY + 1.04 * rect.height) * scale))
		XCTAssertGreaterThan(margin.green, 0.8, "the margin around the scan stays blank")
	}

	func testAPageIsDrawnFromItsStoredDataWhenItHasSome() throws {
		// The image only gives the shape; the pixels come from the stored page as it is written.
		let blank = try TestDrawing(width: 600, height: 800).image { context, size in TestDrawing.fill(context, size: size, level: 1) }
		let dark = try TestDrawing(width: 600, height: 800).image { context, size in TestDrawing.fill(context, size: size, level: 0.1) }
		let stored = try XCTUnwrap(dark.jpegData(compressionQuality: 0.8))

		let data = SearchablePDF.render([SearchablePDF.Page(image: blank, lines: [], imageData: stored)], title: "Stored")

		let pdfPage = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
		let thumbnail = try XCTUnwrap(pdfPage.thumbnail(of: CGSize(width: 30, height: 40), for: .mediaBox).cgImage)
		let level = try averageGray(thumbnail)
		XCTAssertLessThan(level, 0.3, "drawn from the stored page, not the placeholder image: \(level)")
	}

	@MainActor
	func testPDFNotesFollowTheirPageAfterPagesMove() async throws {
		let context = try makeContext()
		let scan = try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: "Scan", into: context) as? Scan)
		scan.id = UUID()
		var captures: [ScanCapture] = []
		for order in 0..<2 {
			let capture = try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: "ScanCapture", into: context) as? ScanCapture)
			capture.id = UUID()
			capture.order = Int32(order)
			capture.createImage(fullSizedImage: try page(width: 300, height: 400))
			scan.addToCaptures(capture)
			captures.append(capture)
		}
		let note = RescrivaNote(text: "On the first page", created: Date(timeIntervalSinceReferenceDate: 700_000_000))
		scan.rebuiltDocument = RescrivaDocument(title: "Moved", pages: [RescrivaPage(notes: [note]), RescrivaPage()],
											 sourceCaptureIDs: captures.compactMap(\.id))
		// The first page moves to the end after the rebuild.
		captures[0].order = 1
		captures[1].order = 0
		try context.save()

		let pages = await SearchablePDF.pages(for: scan, includeNotes: true)

		XCTAssertEqual(pages.map { $0.notes.map(\.text) }, [[], ["On the first page"]], "the note stays with its page")
		XCTAssertTrue(pages.allSatisfy { $0.imageData != nil }, "decoded only as each page is written")
	}

	// MARK: Password

	func testAPasswordEncryptsThePDFAndUnlocksIt() throws {
		let pages = [SearchablePDF.Page(image: try page(width: 600, height: 800), lines: [])]

		let locked = SearchablePDF.render(pages, title: "Secret", options: PDFExportOptions(password: "rescriva-test"))
		let open = SearchablePDF.render(pages, title: "Open", options: PDFExportOptions(password: ""))

		try assertLocked(locked, password: "rescriva-test")
		let plain = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: open as CFData))))
		XCTAssertFalse(plain.isEncrypted, "an empty password means none")
	}

	func testAPasswordProtectedPDFWithNotesStaysEncrypted() throws {
		let pages = [SearchablePDF.Page(image: try page(width: 600, height: 800), lines: [], notes: [("Pinned", nil)])]

		let data = SearchablePDF.render(pages, title: "Secret", options: PDFExportOptions(paperSize: .letter, password: "s3cret pass"))

		try assertLocked(data, password: "s3cret pass")
		let document = try XCTUnwrap(PDFDocument(data: data))
		XCTAssertTrue(document.isLocked)
		XCTAssertTrue(document.unlock(withPassword: "s3cret pass"))
		XCTAssertTrue(document.page(at: 0)?.annotations.contains { $0.contents == "Pinned" } ?? false)
	}

	func testOptionsNeverPrintThePassword() {
		let options = PDFExportOptions(paperSize: .a4, quality: .small, password: "hunter2")
		XCTAssertFalse(options.description.contains("hunter2"))
		XCTAssertFalse(String(describing: options).contains("hunter2"))
		XCTAssertEqual(options.encryptionPassword, "hunter2")
		XCTAssertNil(PDFExportOptions(password: "").encryptionPassword)
	}

	@MainActor
	func testExportingAScanUsesThePaperQualityAndPassword() async throws {
		let context = try makeContext()
		let scan = try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: "Scan", into: context) as? Scan)
		scan.id = UUID()
		scan.title = "Options"
		scan.lookFilter = .blackAndWhite
		let capture = try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: "ScanCapture", into: context) as? ScanCapture)
		capture.id = UUID()
		capture.order = 0
		capture.createImage(fullSizedImage: try page(width: 1200, height: 1600))
		scan.addToCaptures(capture)
		try context.save()

		let options = PDFExportOptions(paperSize: .a4, quality: .small, password: "rescriva")
		let url = try await ExportService.makeFile(for: scan, format: .pdf, includeNotes: false, pdfOptions: options)
		addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

		let data = try Data(contentsOf: url)
		try assertLocked(data, password: "rescriva")
		let document = try XCTUnwrap(PDFDocument(data: data))
		XCTAssertTrue(document.unlock(withPassword: "rescriva"))
		let size = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).size
		XCTAssertEqual(size.width, 595.28, accuracy: 0.01)
		XCTAssertEqual(size.height, 841.89, accuracy: 0.01)
	}

	// MARK: Markdown

	/// The `.md` export writes the rebuilt document as Markdown with a Mermaid diagram and the
	/// notes, and "Copy for AI" gets the very same text.
	@MainActor
	func testExportingMarkdownWritesTheRebuiltDocumentAndCopyForAIMatches() async throws {
		let context = try makeContext()
		let scan = try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: "Scan", into: context) as? Scan)
		scan.id = UUID()
		scan.title = "Spring fair"
		scan.output = .docx
		let capture = try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: "ScanCapture", into: context) as? ScanCapture)
		let captureID = UUID()
		capture.id = captureID
		capture.order = 0
		capture.createImage(fullSizedImage: try page(width: 600, height: 800))
		scan.addToCaptures(capture)
		let ink = RGBColor(hex: 0x1D2233)
		let diagram = Diagram(nodes: [
			.init(id: "a", label: "Stalls", shape: .rectangle, box: NormalizedBox(x: 0.05, y: 0.2, width: 0.3, height: 0.3), stroke: ink),
			.init(id: "b", label: "Raffle", shape: .ellipse, box: NormalizedBox(x: 0.6, y: 0.2, width: 0.3, height: 0.3), stroke: ink),
		], edges: [.init(id: "1", from: "a", to: "b")])
		scan.rebuiltDocument = RescrivaDocument(title: "Spring fair", pages: [RescrivaPage(blocks: [
			RescrivaBlock(content: .heading(level: 1, runs: [RescrivaRun(text: "Spring fair")])),
			RescrivaBlock(content: .list(style: .checkbox, items: [ListItem(runs: [RescrivaRun(text: "Book the hall")], checked: true)])),
			RescrivaBlock(content: .diagram(diagram)),
		], notes: [RescrivaNote(text: "Bring the banner.", created: Date(timeIntervalSince1970: 0))])], sourceCaptureIDs: [captureID])
		try context.save()

		let url = try await ExportService.makeFile(for: scan, format: .md, includeNotes: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		XCTAssertEqual(url.lastPathComponent, "Spring fair.md")
		let text = try String(contentsOf: url, encoding: .utf8)
		XCTAssertTrue(text.hasPrefix("# Spring fair\n\n- [x] Book the hall\n\n```mermaid\nflowchart TD\n"))
		XCTAssertTrue(text.contains("    n1 --> n2\n```"))
		XCTAssertTrue(text.hasSuffix("## Notes\n\n- Page 1: Bring the banner.\n"))

		let copied = await ExportService.markdown(for: scan, includeNotes: true)
		XCTAssertEqual(copied, text, "Copy for AI puts the same text on the pasteboard")
		let quiet = await ExportService.markdown(for: scan, includeNotes: false)
		XCTAssertFalse(quiet.contains("## Notes"))
		XCTAssertTrue(quiet.hasPrefix("# Spring fair\n"))
	}

	// MARK: Helpers

	/// Encrypted, closed until unlocked, refuses a wrong password and opens with `password`.
	private func assertLocked(_ data: Data, password: String, file: StaticString = #filePath, line: UInt = #line) throws {
		let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))), file: file, line: line)
		XCTAssertTrue(document.isEncrypted, file: file, line: line)
		XCTAssertFalse(document.isUnlocked, file: file, line: line)
		XCTAssertFalse(document.unlockWithPassword("wrong"), file: file, line: line)
		XCTAssertTrue(document.unlockWithPassword(password), file: file, line: line)
		XCTAssertTrue(document.isUnlocked, file: file, line: line)
		XCTAssertEqual(document.numberOfPages, 1, file: file, line: line)
	}

	/// The mean grey level (0–1) of `image`.
	private func averageGray(_ image: CGImage) throws -> Double {
		let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
											  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
		context.interpolationQuality = .medium
		context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
		let pixels = try XCTUnwrap(context.makeImage()?.dataProvider?.data) as Data
		return Double(try XCTUnwrap(pixels.first)) / 255
	}

	/// A page of grey text lines on white.
	private func page(width: Int, height: Int) throws -> UIImage {
		try TestDrawing(width: width, height: height).image { context, size in
			TestDrawing.fill(context, size: size, level: 0.97)
			let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.darkGray]
			for row in 0..<Int(size.height / 60) {
				("Minutes of the meeting, item \(row): budget, rota and the spring fair." as NSString)
					.draw(at: CGPoint(x: 40, y: 30 + CGFloat(row) * 60), withAttributes: attributes)
			}
		}
	}

	/// An in-memory library on the app's own model.
	private func makeContext() throws -> NSManagedObjectContext {
		let container = NSPersistentContainer(name: "scanner", managedObjectModel: PersistenceController.shared.container.managedObjectModel)
		let description = NSPersistentStoreDescription()
		description.type = NSInMemoryStoreType
		container.persistentStoreDescriptions = [description]
		var loadError: Error?
		container.loadPersistentStores { _, error in loadError = error }
		if let loadError { throw loadError }
		containers.append(container)
		return container.viewContext
	}
}
