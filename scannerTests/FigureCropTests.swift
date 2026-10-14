//
//  FigureCropTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Cutting a figure's picture out: the box on the page mapped back through
//  the recipe's quad and each turn to the original photo (checked against a
//  page re-made from that photo, pixel for pixel), the stored-page fallback
//  and the size cap; where the pictures are kept and when they go; and the
//  export carrying them into Word (sized to the text width, aspect kept) and
//  PowerPoint (at the figure's box).
//

import CoreData
import CoreImage
import UIKit
import XCTest
@testable import scanner

@MainActor
final class FigureCropTests: XCTestCase {

	/// A non-trivial crop: every side slanted, no two sides parallel.
	private let quad = PageQuad(topLeft: CGPoint(x: 0.12, y: 0.1), topRight: CGPoint(x: 0.85, y: 0.16),
								bottomRight: CGPoint(x: 0.9, y: 0.88), bottomLeft: CGPoint(x: 0.08, y: 0.8))
	/// In-memory containers kept alive for the test's contexts.
	private var containers: [NSPersistentContainer] = []

	override func tearDown() {
		containers.removeAll()
		super.tearDown()
	}

	// MARK: Mapping

	func testTheWholePageMapsToTheQuadAndItsCentreToTheDiagonals() throws {
		let whole = NormalizedBox(x: 0, y: 0, width: 1, height: 1)
		let mapped = try XCTUnwrap(FigureCrop.originalQuad(of: whole, quad: quad, quarterTurns: 0))
		assertPoints(mapped.corners, quad.corners)

		// A projective map sends the square's centre to where the quad's diagonals cross.
		let centre = try XCTUnwrap(Homography(unitSquareTo: quad)?.apply(CGPoint(x: 0.5, y: 0.5)))
		let crossing = try XCTUnwrap(intersection(quad.topLeft, quad.bottomRight, quad.topRight, quad.bottomLeft))
		XCTAssertEqual(centre.x, crossing.x, accuracy: 1e-9)
		XCTAssertEqual(centre.y, crossing.y, accuracy: 1e-9)

		let identity = try XCTUnwrap(FigureCrop.originalQuad(of: NormalizedBox(x: 0.2, y: 0.3, width: 0.4, height: 0.1),
															 quad: .fullFrame, quarterTurns: 0))
		assertPoints(identity.corners, [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.6, y: 0.3), CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.2, y: 0.4)])
	}

	func testEachTurnNamesTheCornersAsTheyAppearOnThePage() throws {
		let whole = NormalizedBox(x: 0, y: 0, width: 1, height: 1)
		// The page's top-left corner, turned clockwise a quarter at a time, is the quad's
		// top-left, bottom-left, bottom-right and top-right corner.
		let expected: [[CGPoint]] = [
			quad.corners,
			[quad.bottomLeft, quad.topLeft, quad.topRight, quad.bottomRight],
			[quad.bottomRight, quad.bottomLeft, quad.topLeft, quad.topRight],
			[quad.topRight, quad.bottomRight, quad.bottomLeft, quad.topLeft],
		]
		for turns in 0..<4 {
			let mapped = try XCTUnwrap(FigureCrop.originalQuad(of: whole, quad: quad, quarterTurns: turns))
			assertPoints(mapped.corners, expected[turns], "turns \(turns)")
			XCTAssertTrue(mapped.isConvex)
		}
		// PageCleanup leaves a degenerate quad uncorrected, so its page is the whole photo.
		let folded = PageQuad(topLeft: .zero, topRight: CGPoint(x: 0.5, y: 0.5), bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0.2, y: 0.2))
		let box = NormalizedBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
		let uncorrected = try XCTUnwrap(FigureCrop.originalQuad(of: box, quad: folded, quarterTurns: 0))
		assertPoints(uncorrected.corners, [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.4, y: 0.2), CGPoint(x: 0.4, y: 0.6), CGPoint(x: 0.1, y: 0.6)])
	}

	func testACropFromTheOriginalMatchesThePageAtEveryTurn() throws {
		let original = try gradientOriginal(width: 1200, height: 900)
		let box = NormalizedBox(x: 0.18, y: 0.22, width: 0.42, height: 0.3)
		for turns in 0..<4 {
			let recipe = PageRecipe(quad: quad, mode: nil, rotation: turns, removeShadows: false, keepMarkerColors: false)
			let page = try XCTUnwrap(PageReprocessor.render(original: original, recipe: recipe))
			let pageSize = CGSize(width: page.width, height: page.height)
			let crop = try render(try XCTUnwrap(FigureCrop.crop(original, box: box, recipe: recipe, pageSize: pageSize)))

			let boxAspect = box.width * pageSize.width / (box.height * pageSize.height)
			XCTAssertEqual(Double(crop.width) / Double(crop.height), boxAspect, accuracy: 0.03, "turns \(turns): the box's proportions")
			XCTAssertGreaterThanOrEqual(crop.width * crop.height, Int(box.width * box.height * pageSize.width * pageSize.height * 0.7),
										"turns \(turns): at least the page's resolution")
			let pagePixels = try Pixels(page), cropPixels = try Pixels(crop)
			for point in [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.2), CGPoint(x: 0.3, y: 0.85), CGPoint(x: 0.5, y: 0.5)] {
				let onPage = pagePixels.color(at: CGPoint(x: box.x + point.x * box.width, y: box.y + point.y * box.height))
				let inCrop = cropPixels.color(at: point)
				XCTAssertEqual(onPage.red, inCrop.red, accuracy: 10, "turns \(turns) at \(point)")
				XCTAssertEqual(onPage.green, inCrop.green, accuracy: 10, "turns \(turns) at \(point)")
			}
		}
	}

	func testAPageNotTheShapeItsRecipeMakesIsCutFromThePage() throws {
		let original = try gradientOriginal(width: 1200, height: 900)
		let box = NormalizedBox(x: 0.18, y: 0.22, width: 0.42, height: 0.3)
		for turns in 0..<4 {
			let recipe = PageRecipe(quad: quad, mode: nil, rotation: turns, removeShadows: false, keepMarkerColors: false)
			let page = try XCTUnwrap(PageReprocessor.render(original: original, recipe: recipe))
			let size = CGSize(width: page.width, height: page.height)
			XCTAssertTrue(FigureCrop.isMade(size, by: recipe, from: original), "turns \(turns): the recipe's own page")
			// Turned once more outside the editor (Quick Look), or its pixels not synced yet.
			XCTAssertFalse(FigureCrop.isMade(CGSize(width: size.height, height: size.width), by: recipe, from: original), "turns \(turns)")
		}
		// The crop then comes from the stored page as it is: the page's own proportions, not the original's.
		let recipe = PageRecipe(quad: quad, mode: nil, rotation: 0, removeShadows: false, keepMarkerColors: false)
		let rendered = try XCTUnwrap(PageReprocessor.render(original: original, recipe: recipe))
		let turned = try XCTUnwrap(PageReprocessor.rotated(rendered, quarterTurns: 1))
		let pageData = try XCTUnwrap(UIImage(cgImage: turned).jpegData(compressionQuality: 0.9))
		let data = try XCTUnwrap(FigureCrop.jpeg(pageData: pageData, box: box, recipe: recipe, original: original))
		let info = try XCTUnwrap(RescrivaImageInfo(data: data))
		let padded = FigureCrop.padded(box)
		XCTAssertEqual(Double(info.pixelWidth), padded.width * Double(turned.width), accuracy: 2)
		XCTAssertEqual(Double(info.pixelHeight), padded.height * Double(turned.height), accuracy: 2)
	}

	func testWithoutAnOriginalTheCropComesFromThePageWithAMargin() throws {
		let original = try gradientOriginal(width: 1000, height: 800)
		let pageData = try XCTUnwrap(UIImage(cgImage: original).jpegData(compressionQuality: 0.9))
		let box = NormalizedBox(x: 0.2, y: 0.25, width: 0.5, height: 0.4)

		let data = try XCTUnwrap(FigureCrop.jpeg(pageData: pageData, box: box, recipe: nil, original: nil))

		let info = try XCTUnwrap(RescrivaImageInfo(data: data))
		XCTAssertEqual(info.format, .jpeg)
		let padded = FigureCrop.padded(box)
		XCTAssertEqual(Double(info.pixelWidth), padded.width * 1000, accuracy: 2)
		XCTAssertEqual(Double(info.pixelHeight), padded.height * 800, accuracy: 2)
		let edge = FigureCrop.padded(NormalizedBox(x: 0.005, y: 0.5, width: 0.995, height: 0.2))
		XCTAssertEqual(edge.x, 0, "kept on the page")
		XCTAssertEqual(edge.width, 1, accuracy: 1e-9, "kept on the page")
		XCTAssertEqual(edge.y, 0.49, accuracy: 1e-9)
		XCTAssertEqual(edge.height, 0.22, accuracy: 1e-9)
	}

	func testCropsAreCappedNear2000Pixels() throws {
		let big = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 6000, height: 3000))
		let crop = try XCTUnwrap(FigureCrop.crop(page: big, box: NormalizedBox(x: 0, y: 0, width: 1, height: 1)))
		XCTAssertLessThanOrEqual(max(crop.extent.width, crop.extent.height), 2000)
		XCTAssertEqual(crop.extent.width / crop.extent.height, 2, accuracy: 0.01)
		let size = FigureCrop.aspectSize(pixels: 1_000_000, aspect: 4)
		XCTAssertEqual(size.width, 2000)
		XCTAssertEqual(size.height, 500)
	}

	// MARK: Storage

	func testTheStoreKeepsCutsAndPrunesPictures() throws {
		let store = makeStore()
		let scanID = UUID(), other = UUID()
		let kept = UUID().uuidString, dropped = UUID().uuidString
		try store.save(Data([1, 2, 3]), for: kept, scanID: scanID)
		try store.save(Data([4]), for: dropped, scanID: scanID)
		try store.save(Data([5]), for: kept, scanID: other)
		XCTAssertNil(store.fileURL(for: "../../escape", scanID: scanID), "asset ids from synced documents are never paths")
		XCTAssertThrowsError(try store.save(Data([1]), for: "not-a-uuid", scanID: scanID))

		XCTAssertEqual(store.prune(scanID: scanID, keeping: [kept]), 1)
		XCTAssertEqual(store.data(for: kept, scanID: scanID), Data([1, 2, 3]))
		XCTAssertNil(store.data(for: dropped, scanID: scanID))
		XCTAssertEqual(store.pruneOrphans(keeping: [scanID]), 1, "the other scan was deleted elsewhere")
		XCTAssertNil(store.data(for: kept, scanID: other))
		store.removeAll(for: scanID)
		XCTAssertNil(store.data(for: kept, scanID: scanID))
	}

	func testAMissingPictureIsCutAgainAndStored() throws {
		let store = makeStore()
		let pageData = try XCTUnwrap(UIImage(cgImage: try gradientOriginal(width: 400, height: 300)).jpegData(compressionQuality: 0.9))
		let source = FigureSource(assetID: UUID().uuidString, box: NormalizedBox(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
								  pageData: pageData, recipe: nil, captureID: nil)
		let scanID = UUID()

		let made = try XCTUnwrap(store.imageData(for: source, scanID: scanID, originals: OriginalStore(directory: store.directory)))

		XCTAssertEqual(store.data(for: source.assetID, scanID: scanID), made)
	}

	func testFiguresAreCutAPageAtATimeAndAStoredOneNeedsNoOriginal() throws {
		let store = makeStore()
		let pageData = try XCTUnwrap(UIImage(cgImage: try gradientOriginal(width: 400, height: 300)).jpegData(compressionQuality: 0.9))
		let recipe = PageRecipe(quad: .fullFrame, mode: nil, rotation: 0, removeShadows: false, keepMarkerColors: false)
		let pages = [UUID(), UUID()]
		func source(_ page: UUID?) -> FigureSource {
			FigureSource(assetID: UUID().uuidString, box: NormalizedBox(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
						 pageData: pageData, recipe: recipe, captureID: page)
		}
		let sources = [source(pages[0]), source(pages[0]), source(pages[1]), source(nil), source(nil)]

		XCTAssertEqual(FigureAssets.byPage(sources).map { $0.map(\.assetID) },
					   [[sources[0].assetID, sources[1].assetID], [sources[2].assetID], [sources[3].assetID], [sources[4].assetID]])
		let scanID = UUID()
		try store.save(Data([1, 2]), for: sources[0].assetID, scanID: scanID)
		var decodes = 0
		XCTAssertEqual(store.imageData(for: sources[0], scanID: scanID) { decodes += 1; return nil }, Data([1, 2]))
		XCTAssertEqual(decodes, 0, "a stored picture needs no original")
		XCTAssertNotNil(store.imageData(for: sources[1], scanID: scanID) { decodes += 1; return nil }, "cut from the page without one")
		XCTAssertEqual(decodes, 1)
	}

	func testFiguresOnAStalePageAreNotKept() {
		let ids = [UUID(), UUID()]
		let first = UUID().uuidString, second = UUID().uuidString
		var document = RescrivaDocument(title: "Doc", pages: [
			RescrivaPage(blocks: [RescrivaBlock(content: .figure(assetID: first, caption: nil, altText: nil))]),
			RescrivaPage(blocks: [RescrivaBlock(content: .figure(assetID: second, caption: nil, altText: nil)),
							   RescrivaBlock(content: .figure(assetID: nil, caption: "Drawn", altText: nil))]),
		], sourceCaptureIDs: ids)
		XCTAssertEqual(document.liveFigureAssetIDs, [first, second])
		document.staleCaptureIDs = [ids[1]]
		XCTAssertEqual(document.liveFigureAssetIDs, [first], "the re-made page's boxes don't match its new pixels")
	}

	func testARecreatedFigureLetsItsPictureGo() throws {
		let store = makeStore()
		let scanID = UUID()
		let redrawn = UUID().uuidString, kept = UUID().uuidString
		let figure = RescrivaBlock(content: .figure(assetID: redrawn, caption: "Figure 1", altText: nil))
		var document = RescrivaDocument(title: "Doc", pages: [RescrivaPage(blocks: [
			figure, RescrivaBlock(content: .figure(assetID: kept, caption: nil, altText: nil)),
		])])
		try store.save(Data([1]), for: redrawn, scanID: scanID)
		try store.save(Data([2]), for: kept, scanID: scanID)
		var drawing = try XCTUnwrap(RecreateSource.startingDiagram(for: figure.content, aspect: 1))
		_ = drawing.addNode(shape: .rectangle, box: NormalizedBox(x: 0.1, y: 0.1, width: 0.3, height: 0.3), label: "Start",
							stroke: RGBColor(hex: 0x2E3A4A), fill: nil)

		// What Review does when Recreate saves: the drawing replaces the figure, then the scan's pictures are pruned.
		document.updateBlock(figure.id) { RecreateSource.apply(drawing, to: &$0) }
		XCTAssertEqual(document.liveFigureAssetIDs, [kept])
		XCTAssertEqual(store.prune(scanID: scanID, keeping: document.liveFigureAssetIDs), 1)
		XCTAssertNil(store.data(for: redrawn, scanID: scanID), "the redrawn figure's picture goes")
		XCTAssertEqual(store.data(for: kept, scanID: scanID), Data([2]))
	}

	// MARK: Export

	func testExportCarriesTheFiguresIntoWordAndPowerPoint() async throws {
		let store = makeStore()
		let context = try makeContext()
		let box = NormalizedBox(x: 0.05, y: 0.3, width: 0.9, height: 0.3)
		let scan = try makeScan(figureBox: box, in: context)
		let assetID = try XCTUnwrap(figureAssetID(in: scan))

		let docxURL = try await ExportService.makeFile(for: scan, format: .docx, includeNotes: false, figures: store)
		addTeardownBlock { try? FileManager.default.removeItem(at: docxURL.deletingLastPathComponent()) }
		let picture = try XCTUnwrap(store.data(for: assetID, scanID: try XCTUnwrap(scan.id)), "cut from the page and stored")
		let info = try XCTUnwrap(RescrivaImageInfo(data: picture))
		let docxEntries = try ZipTestReader.entries(try Data(contentsOf: docxURL))
		XCTAssertEqual(docxEntries.first { $0.name == "word/media/image1.jpeg" }?.data, picture, "the picture is in the Word file")
		let documentXML = String(decoding: docxEntries.first { $0.name == "word/document.xml" }?.data ?? Data(), as: UTF8.self)
		let extent = try XCTUnwrap(attributes(of: "wp:extent", in: documentXML))
		XCTAssertLessThanOrEqual(extent.cx, OOXML.emu(inches: 6.0), "no wider than the text")
		XCTAssertEqual(Double(extent.cx) / Double(extent.cy), info.aspect, accuracy: 0.01, "aspect kept")

		let pptxURL = try await ExportService.makeFile(for: scan, format: .pptx, includeNotes: false, figures: store)
		addTeardownBlock { try? FileManager.default.removeItem(at: pptxURL.deletingLastPathComponent()) }
		let pptxEntries = try ZipTestReader.entries(try Data(contentsOf: pptxURL))
		XCTAssertEqual(pptxEntries.first { $0.name == "ppt/media/image1.jpeg" }?.data, picture, "the picture is in the PowerPoint file")
		let slideXML = String(decoding: pptxEntries.first { $0.name == "ppt/slides/slide1.xml" }?.data ?? Data(), as: UTF8.self)
		let placed = try XCTUnwrap(pictureFrame(in: slideXML))
		// A portrait page on a 16:9 slide: fitted to the slide's height and centred.
		let frameWidth = 6_858_000.0 * 612 / 792
		let frame = CGRect(x: (12_192_000 - frameWidth) / 2, y: 0, width: frameWidth, height: 6_858_000)
		let target = CGRect(x: frame.minX + box.x * frame.width, y: frame.minY + box.y * frame.height,
							width: box.width * frame.width, height: box.height * frame.height)
		XCTAssertTrue(target.insetBy(dx: -2, dy: -2).contains(placed), "at the figure's box")
		XCTAssertEqual(placed.midX, target.midX, accuracy: 2)
		XCTAssertEqual(placed.midY, target.midY, accuracy: 2)
		XCTAssertEqual(Double(placed.width / placed.height), info.aspect, accuracy: 0.01)
	}

	// MARK: Helpers

	private func assertPoints(_ actual: [CGPoint], _ expected: [CGPoint], _ message: String = "",
							  file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
		for (a, e) in zip(actual, expected) {
			XCTAssertEqual(a.x, e.x, accuracy: 1e-6, message, file: file, line: line)
			XCTAssertEqual(a.y, e.y, accuracy: 1e-6, message, file: file, line: line)
		}
	}

	/// Where line a1–a2 crosses line b1–b2.
	private func intersection(_ a1: CGPoint, _ a2: CGPoint, _ b1: CGPoint, _ b2: CGPoint) -> CGPoint? {
		let d = (a1.x - a2.x) * (b1.y - b2.y) - (a1.y - a2.y) * (b1.x - b2.x)
		guard abs(d) > 1e-12 else { return nil }
		let t = ((a1.x - b1.x) * (b1.y - b2.y) - (a1.y - b1.y) * (b1.x - b2.x)) / d
		return CGPoint(x: a1.x + t * (a2.x - a1.x), y: a1.y + t * (a2.y - a1.y))
	}

	/// A photo whose red rises left to right and green top to bottom, so every spot has its own colour.
	private func gradientOriginal(width: Int, height: Int) throws -> CGImage {
		var bytes = [UInt8](repeating: 255, count: width * height * 4)
		for y in 0..<height {
			for x in 0..<width {
				let index = (y * width + x) * 4
				bytes[index] = UInt8(255 * x / max(1, width - 1))
				bytes[index + 1] = UInt8(255 * y / max(1, height - 1))
				bytes[index + 2] = 128
			}
		}
		let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
		return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
									 space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
									 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
									 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
	}

	private func render(_ image: CIImage) throws -> CGImage {
		let context = CIContext(options: [.cacheIntermediates: false])
		return try XCTUnwrap(context.createCGImage(image, from: image.extent.integral, format: .RGBA8,
												   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
	}

	/// An image's sRGB pixels, read at normalized points (top-left origin).
	private struct Pixels {
		let width: Int
		let height: Int
		let bytes: [UInt8]

		init(_ image: CGImage) throws {
			width = image.width
			height = image.height
			var buffer = [UInt8](repeating: 0, count: width * height * 4)
			let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
			let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
				guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
											  bytesPerRow: image.width * 4, space: space,
											  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
				context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
				return true
			}
			XCTAssertTrue(drawn)
			bytes = buffer
		}

		func color(at point: CGPoint) -> (red: Double, green: Double) {
			let x = min(width - 1, max(0, Int(point.x * Double(width))))
			let y = min(height - 1, max(0, Int(point.y * Double(height))))
			let index = (y * width + x) * 4
			return (Double(bytes[index]), Double(bytes[index + 1]))
		}
	}

	/// A temporary figures folder, removed after the test.
	private func makeStore() -> FigureStore {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RescrivaFigures-\(UUID().uuidString)", isDirectory: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		return FigureStore(directory: directory)
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

	/// A one-page scan rebuilt into a document with one figure at `figureBox`.
	private func makeScan(figureBox: NormalizedBox, in context: NSManagedObjectContext) throws -> Scan {
		let scan = try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: "Scan", into: context) as? Scan)
		scan.id = UUID()
		scan.title = "Figures"
		let capture = try XCTUnwrap(NSEntityDescription.insertNewObject(forEntityName: "ScanCapture", into: context) as? ScanCapture)
		let captureID = UUID()
		capture.id = captureID
		capture.order = 0
		capture.createImage(fullSizedImage: UIImage(cgImage: try gradientOriginal(width: 612, height: 792)))
		scan.addToCaptures(capture)
		let figure = RescrivaBlock(content: .figure(assetID: UUID().uuidString, caption: "Figure 1: A gradient", altText: nil), box: figureBox)
		scan.rebuiltDocument = RescrivaDocument(title: "Figures", pages: [RescrivaPage(blocks: [figure])], sourceCaptureIDs: [captureID])
		try context.save()
		return scan
	}

	private func figureAssetID(in scan: Scan) -> String? {
		for block in scan.rebuiltDocument?.pages.flatMap(\.blocks) ?? [] {
			if case .figure(let assetID, _, _) = block.content { return assetID }
		}
		return nil
	}

	/// The `cx` and `cy` of the first `<element …>` in a part's XML (read back with `ZipTestReader`).
	private func attributes(of element: String, in text: String) -> (cx: Int, cy: Int)? {
		guard let start = text.range(of: "<\(element) cx=\"") else { return nil }
		let rest = text[start.upperBound...]
		let numbers = rest.prefix(60).split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
		guard numbers.count == 2 else { return nil }
		return (numbers[0], numbers[1])
	}

	/// The first picture's frame in a slide's XML, in EMU.
	private func pictureFrame(in text: String) -> CGRect? {
		guard let picture = text.range(of: "<p:pic>"), let offset = text.range(of: "<a:off x=\"", range: picture.upperBound..<text.endIndex) else { return nil }
		let numbers = text[offset.upperBound...].prefix(120).split(whereSeparator: { !$0.isNumber }).prefix(4).compactMap { Double($0) }
		guard numbers.count == 4 else { return nil }
		return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
	}
}
