//
//  FigureDetectorTests.swift
//  Rescriva (fork of Open Scanner)
//
//  The classical figure detector on small synthetic pages: real text drawn
//  with Core Text (its OCR lines made by hand), a photo-like gradient with
//  noise, a bar chart, and the pages that must not give a figure — text
//  only, a ruled table, a flat or gradient-shaded box, a dark border, a
//  region covered by a table, and a photo that mustn't join another over
//  the text beside it. Then placement: captions (not sentences about the
//  figure), text inside a picture (never prose), reading order, and the
//  whole pass as Rebuilder runs it.
//

import CoreGraphics
import CoreText
import UIKit
import XCTest
@testable import scanner

final class FigureDetectorTests: XCTestCase {

	// MARK: Finding figures

	func testAPhotoAmongTextIsExactlyOneFigureWithItsBox() throws {
		let page = TextPage()
		let lines = page.paragraph(rows: 6, top: 70) + page.paragraph(rows: 6, top: 660)
		page.photo(CGRect(x: 150, y: 320, width: 500, height: 300))

		let found = FigureDetector.detect(in: try page.image(), lines: lines, excluding: [])

		XCTAssertEqual(found.count, 1)
		let box = try XCTUnwrap(found.first?.box)
		assertBox(box, equals: page.normalized(CGRect(x: 150, y: 320, width: 500, height: 300)))
		XCTAssertGreaterThan(found.first?.confidence ?? 0, 0.8)
	}

	func testATextOnlyPageHasNoFigures() throws {
		let page = TextPage()
		var lines = [page.text("A Heading In Bold", at: CGPoint(x: 70, y: 40), size: 40, bold: true)]
		lines += page.paragraph(rows: 18, top: 120)

		XCTAssertEqual(FigureDetector.detect(in: try page.image(), lines: lines, excluding: []), [])
		XCTAssertEqual(FigureDetector.detect(in: try page.image(), lines: [], excluding: []), [],
					   "text the OCR missed is still not a picture")
	}

	func testARuledTableHasNoFigures() throws {
		let page = TextPage()
		let columns: [CGFloat] = [80, 330, 520, 720], rows: [CGFloat] = [200, 260, 320, 380, 440, 500]
		for x in columns {
			page.fill(CGRect(x: x - 2, y: rows[0] - 2, width: 4, height: rows[rows.count - 1] - rows[0] + 4))
		}
		for y in rows {
			page.fill(CGRect(x: columns[0] - 2, y: y - 2, width: columns[columns.count - 1] - columns[0] + 4, height: 4))
		}
		var lines: [RecognizedLine] = []
		for row in 0..<(rows.count - 1) {
			for column in 0..<(columns.count - 1) {
				lines.append(page.text("cell \(row)\(column)", at: CGPoint(x: columns[column] + 16, y: rows[row] + 18), size: 18))
			}
		}

		XCTAssertEqual(FigureDetector.detect(in: try page.image(), lines: lines, excluding: []), [])
	}

	func testAFlatShadedBoxIsNotAFigure() throws {
		let page = TextPage()
		page.fill(CGRect(x: 100, y: 300, width: 600, height: 260), gray: 0.62)
		let lines = (0..<4).map { row in
			page.text("A note printed on a shaded panel", at: CGPoint(x: 130, y: 330 + CGFloat(row) * 50), size: 20, gray: 1)
		}

		XCTAssertEqual(FigureDetector.detect(in: try page.image(), lines: lines, excluding: []), [], "with text on it")
		let plain = TextPage()
		plain.fill(CGRect(x: 100, y: 300, width: 600, height: 260), gray: 0.3)
		XCTAssertEqual(FigureDetector.detect(in: try plain.image(), lines: [], excluding: []), [], "one flat colour")
	}

	func testADarkBorderAlongThePageEdgeIsNotAFigure() throws {
		let page = TextPage()
		let lines = page.paragraph(rows: 10, top: 200)
		page.photo(CGRect(x: 0, y: 0, width: 36, height: 1000))
		page.photo(CGRect(x: 0, y: 950, width: 800, height: 50))
		page.photo(CGRect(x: 740, y: 120, width: 60, height: 500))

		XCTAssertEqual(FigureDetector.detect(in: try page.image(), lines: lines, excluding: []), [])
	}

	func testTablesDiagramsAndEquationsAreNeverFigures() throws {
		let page = TextPage()
		page.photo(CGRect(x: 150, y: 320, width: 500, height: 300))
		let table = RescrivaBlock(content: .table(rows: [[TableCell(runs: [RescrivaRun(text: "x")])]]),
							   box: page.normalized(CGRect(x: 140, y: 310, width: 520, height: 320)))

		let excluded = FigureDetector.exclusions(in: [table, RescrivaBlock(content: .paragraph(runs: [], alignment: .leading),
																		  box: NormalizedBox(x: 0, y: 0, width: 1, height: 1))])

		XCTAssertEqual(excluded, [table.box].compactMap { $0 }, "only the table's box; paragraphs aren't excluded")
		XCTAssertEqual(FigureDetector.detect(in: try page.image(), lines: [], excluding: excluded), [])
	}

	func testABarChartIsOneFigureAcrossItsBars() throws {
		let page = TextPage()
		let lines = page.paragraph(rows: 4, top: 60)
		let heights: [CGFloat] = [120, 220, 180, 300, 260, 150]
		for (index, height) in heights.enumerated() {
			page.fill(CGRect(x: 160 + CGFloat(index) * 80, y: 600 - height, width: 48, height: height), gray: 0.25)
		}

		let found = FigureDetector.detect(in: try page.image(), lines: lines, excluding: [])

		XCTAssertEqual(found.count, 1, "the bars face each other across paper, so they join")
		assertBox(try XCTUnwrap(found.first?.box), equals: page.normalized(CGRect(x: 160, y: 300, width: 448, height: 300)))
	}

	func testTwoPhotosWithACaptionBetweenStayTwoFigures() throws {
		let page = TextPage()
		page.photo(CGRect(x: 200, y: 120, width: 400, height: 260))
		let caption = page.text("Figure 1. The upper photograph", at: CGPoint(x: 260, y: 392), size: 18)
		page.photo(CGRect(x: 200, y: 418, width: 400, height: 260))

		let found = FigureDetector.detect(in: try page.image(), lines: [caption], excluding: [])

		XCTAssertEqual(found.count, 2)
		XCTAssertLessThan(found[0].box.y, found[1].box.y, "in reading order")
	}

	func testAPhotoAboveAWiderOneDoesNotJoinItOverTheTextBesideIt() throws {
		let page = TextPage()
		page.photo(CGRect(x: 60, y: 160, width: 480, height: 300))
		let wrapped = (0..<10).map { row in
			page.text("text wrapped beside", at: CGPoint(x: 570, y: 170 + CGFloat(row) * 28), size: 16)
		}
		page.photo(CGRect(x: 60, y: 490, width: 680, height: 200))

		let found = FigureDetector.detect(in: try page.image(), lines: wrapped, excluding: [])

		XCTAssertEqual(found.count, 2, "two pictures, not one box over the text")
		for figure in found {
			XCTAssertFalse(wrapped.contains { figure.box.rect.contains($0.box) }, "no wrapped line inside \(figure.box)")
		}
	}

	func testAShadedPanelWithAGradientIsNotAFigure() throws {
		let page = TextPage()
		page.gradient(CGRect(x: 80, y: 280, width: 640, height: 220), from: 0.8, to: 0.66)
		let lines = (0..<3).map { row in
			page.text("A note printed on a shaded callout panel here", at: CGPoint(x: 110, y: 310 + CGFloat(row) * 50), size: 20, gray: 1)
		}

		XCTAssertEqual(FigureDetector.detect(in: try page.image(), lines: lines, excluding: []), [])
	}

	func testAcceptanceLeansTowardAMiss() {
		let photo = FigureDetector.RegionMeasures(widthShare: 0.5, heightShare: 0.3, aspect: 1.6, fill: 0.95, solidity: 1,
												  textShare: 0, colourSpread: 60, edges: [], surfaceSpread: 30)
		XCTAssertTrue(FigureDetector.accepts(photo))
		var shaded = photo
		shaded.surfaceSpread = 2
		XCTAssertFalse(FigureDetector.accepts(shaded), "one smooth shading")
		var strip = photo
		strip.heightShare = 0.02
		XCTAssertFalse(FigureDetector.accepts(strip), "a rule or band")
		var tiny = photo
		tiny.widthShare = 0.1
		tiny.heightShare = 0.1
		XCTAssertFalse(FigureDetector.accepts(tiny), "under 2% of the page")
		var wordy = photo
		wordy.textShare = 0.5
		XCTAssertFalse(FigureDetector.accepts(wordy), "mostly text")
		var flat = photo
		flat.colourSpread = 4
		XCTAssertFalse(FigureDetector.accepts(flat), "one flat colour")
		var lines = photo
		lines.solidity = 0.2
		XCTAssertFalse(FigureDetector.accepts(lines), "thin lines and frames")
		var corner = photo
		corner.edges = [.left, .top]
		XCTAssertFalse(FigureDetector.accepts(corner), "touching two edges")
		var shadow = photo
		shadow.edges = [.bottom]
		shadow.heightShare = 0.08
		shadow.widthShare = 0.5
		XCTAssertFalse(FigureDetector.accepts(shadow), "a band along one edge")
		var bleed = photo
		bleed.edges = [.right]
		bleed.widthShare = 0.4
		XCTAssertTrue(FigureDetector.accepts(bleed), "a photo running off one side")
		var whole = photo
		whole.widthShare = 0.95
		whole.heightShare = 0.95
		XCTAssertFalse(FigureDetector.accepts(whole), "the page itself")
	}

	func testCellMaskClosingOpeningAndRegions() throws {
		var mask = FigureDetector.CellMask(columns: 10, rows: 6)
		for column in 1...3 { for row in 1...3 where !(column == 2 && row == 2) { mask.bits[row * 10 + column] = true } }
		for column in 6...8 { mask.bits[1 * 10 + column] = true }
		XCTAssertTrue(mask.closed(radius: 1)[2, 2], "a one-cell hole closes")
		XCTAssertEqual(mask.opened(radius: 1)[7, 1], false, "a one-cell line opens away")
		let regions = try XCTUnwrap(mask.regions(minCells: 3, limit: 4))
		XCTAssertEqual(regions.count, 2)
		XCTAssertEqual(regions.first, FigureDetector.CellRect(minColumn: 1, minRow: 1, maxColumn: 3, maxRow: 3))
		XCTAssertNil(mask.regions(minCells: 1, limit: 1), "more regions than the limit: a noisy page")
		XCTAssertEqual(mask.count(in: FigureDetector.CellRect(minColumn: 8, minRow: 0, maxColumn: 40, maxRow: 40)), 1, "clipped to the grid")
	}

	// MARK: Placement

	func testACaptionWordedLineBelowBecomesTheCaptionAndLeavesTheFlow() throws {
		let figure = DetectedFigure(box: NormalizedBox(x: 0.2, y: 0.3, width: 0.6, height: 0.3), confidence: 0.9)
		let before = paragraph("Some text above.", y: 0.2)
		let caption = paragraph("Figure 2: Quarterly revenue by region", x: 0.25, y: 0.615, width: 0.5)
		let after = paragraph("More text after the figure, which goes on for a while.", y: 0.7)

		let placed = FigurePlacement.placing([figure], into: [before, caption, after], lines: [])

		XCTAssertEqual(placed.count, 3)
		XCTAssertEqual(placed[0].id, before.id)
		XCTAssertEqual(placed[2].id, after.id)
		guard case .figure(let assetID, let text, let altText) = placed[1].content else { return XCTFail("a figure in reading order") }
		XCTAssertNotNil(assetID.flatMap(UUID.init(uuidString:)), "a fresh asset id")
		XCTAssertEqual(text, "Figure 2: Quarterly revenue by region")
		XCTAssertNil(altText)
		XCTAssertEqual(placed[1].box, figure.box)
		XCTAssertEqual(placed[1].provenance?.engine, "figureDetector")
	}

	func testCaptionsAboveNeedACaptionWord() {
		let box = NormalizedBox(x: 0.2, y: 0.3, width: 0.6, height: 0.3)
		let above = paragraph("Table 3 – Results of the second trial", x: 0.2, y: 0.26, width: 0.6, height: 0.025)
		let plainAbove = paragraph("Results of the second trial run", x: 0.3, y: 0.26, width: 0.4, height: 0.025)
		XCTAssertEqual(FigurePlacement.captionRank(above, figure: box, lines: []), 1)
		XCTAssertNil(FigurePlacement.captionRank(plainAbove, figure: box, lines: []))
		XCTAssertTrue(FigurePlacement.startsLikeCaption("Fig. 4 Growth"))
		XCTAssertTrue(FigurePlacement.startsLikeCaption("Source: World Bank"))
		XCTAssertTrue(FigurePlacement.startsLikeCaption("CHART 1"))
		XCTAssertFalse(FigurePlacement.startsLikeCaption("Table salt is mostly sodium chloride"))
		XCTAssertFalse(FigurePlacement.startsLikeCaption("Figures show growth"))
		XCTAssertFalse(FigurePlacement.startsLikeCaption("Map of the area"))
		XCTAssertFalse(FigurePlacement.startsLikeCaption("Chart a course through the data"))
		XCTAssertTrue(FigurePlacement.startsLikeCaption("Table IV – Yields"))
		XCTAssertTrue(FigurePlacement.startsLikeCaption("Plate B. The north wall"))
	}

	func testAPlainCaptionIsOneShortCentredLineBelow() {
		let box = NormalizedBox(x: 0.2, y: 0.3, width: 0.6, height: 0.3)
		let frame = NormalizedBox(x: 0.3, y: 0.61, width: 0.4, height: 0.022)
		let line = RecognizedLine(text: "The harbour at dawn, from the east", confidence: 1, alternatives: [],
								  box: CGRect(x: 0.3, y: 0.61, width: 0.4, height: 0.022))
		let plain = paragraph("The harbour at dawn, from the east", x: frame.x, y: frame.y, width: frame.width, height: frame.height)
		XCTAssertEqual(FigurePlacement.captionRank(plain, figure: box, lines: [line]), 2)
		XCTAssertNil(FigurePlacement.captionRank(plain, figure: box, lines: [line, line]), "two lines: a paragraph")
		XCTAssertNil(FigurePlacement.captionRank(plain, figure: box, lines: []), "unknown lines: not sure")

		let wide = paragraph("The harbour at dawn, from the east", x: 0.1, y: 0.61, width: 0.8, height: 0.022)
		XCTAssertNil(FigurePlacement.captionRank(wide, figure: box, lines: [line]), "wider than the figure: body text")
		let ticks = paragraph("Q1 Q2 Q3 Q4", x: frame.x, y: frame.y, width: frame.width, height: frame.height)
		XCTAssertNil(FigurePlacement.captionRank(ticks, figure: box, lines: [line]), "axis labels are not a caption")
		var flagged = plain
		flagged.content = .paragraph(runs: [RescrivaRun(text: "The harbour at "),
											RescrivaRun(text: "dawm", flag: RescrivaFlag(kind: .word, title: "", detail: "", read: "dawm", options: []))],
									 alignment: .leading)
		XCTAssertNil(FigurePlacement.captionRank(flagged, figure: box, lines: [line]), "an unconfirmed word stays where Review can fix it")
		let far = paragraph("Figure 1: The harbour", x: 0.3, y: 0.7, width: 0.4, height: 0.022)
		XCTAssertNil(FigurePlacement.captionRank(far, figure: box, lines: []), "too far below")
	}

	func testTextClearlyInsideAFigureBecomesItsAltText() throws {
		let figure = DetectedFigure(box: NormalizedBox(x: 0.2, y: 0.3, width: 0.6, height: 0.3), confidence: 0.9)
		let label = paragraph("Sales  2024", x: 0.3, y: 0.35, width: 0.2, height: 0.03)
		let axis = paragraph("Q1 Q2 Q3", x: 0.3, y: 0.55, width: 0.3, height: 0.03)
		let straddling = paragraph("A line that runs past the figure's edge", x: 0.1, y: 0.4, width: 0.8, height: 0.03)
		let table = RescrivaBlock(content: .table(rows: [[TableCell(runs: [RescrivaRun(text: "x")])]]),
							   box: NormalizedBox(x: 0.3, y: 0.45, width: 0.1, height: 0.05))

		let placed = FigurePlacement.placing([figure], into: [label, straddling, table, axis], lines: [])

		XCTAssertEqual(placed.map(\.id).filter { [label.id, axis.id].contains($0) }, [], "the labels leave the flow")
		XCTAssertTrue(placed.contains { $0.id == straddling.id }, "not clearly inside: kept")
		XCTAssertTrue(placed.contains { $0.id == table.id }, "only text blocks are swallowed")
		let figureBlock = try XCTUnwrap(placed.first { $0.content.isFigure })
		guard case .figure(_, let caption, let altText) = figureBlock.content else { return XCTFail("a figure") }
		XCTAssertNil(caption)
		XCTAssertEqual(altText, "Sales 2024 Q1 Q2 Q3")
	}

	func testAFigureWithProseInsideIsNotPlaced() throws {
		let figure = DetectedFigure(box: NormalizedBox(x: 0.1, y: 0.3, width: 0.8, height: 0.3), confidence: 0.9)
		let prose = paragraph("A note printed on a shaded panel that runs on for two lines of plain body text here.",
							  x: 0.15, y: 0.35, width: 0.7, height: 0.06)
		let lines = [CGRect(x: 0.15, y: 0.35, width: 0.7, height: 0.025), CGRect(x: 0.15, y: 0.385, width: 0.5, height: 0.025)]
			.map { RecognizedLine(text: "line", confidence: 1, alternatives: [], box: $0) }
		let blocks = [paragraph("Above.", y: 0.1), prose]

		XCTAssertEqual(FigurePlacement.placing([figure], into: blocks, lines: lines), blocks, "the paragraph stays; the picture is missed")
		let label = paragraph("Sales by region and quarter, in millions of dollars, 2020 to 2024", x: 0.15, y: 0.35, width: 0.7, height: 0.025)
		XCTAssertEqual(FigurePlacement.placing([figure], into: [label], lines: Array(lines.prefix(1))).filter(\.content.isFigure).count, 1,
					   "a one-line label is not prose")
		let long = paragraph(String(repeating: "Label ", count: 90), x: 0.15, y: 0.35, width: 0.7, height: 0.025)
		XCTAssertEqual(FigurePlacement.placing([figure], into: [long], lines: []), [long], "more text than alt text holds")
	}

	func testASentenceAboutAFigureIsNotItsCaption() {
		let box = NormalizedBox(x: 0.2, y: 0.3, width: 0.6, height: 0.3)
		let sentence = paragraph("Figure 2 shows that revenue grew in every region.", x: 0.2, y: 0.62, width: 0.6, height: 0.03)
		XCTAssertNil(FigurePlacement.captionRank(sentence, figure: box, lines: []))
		XCTAssertTrue(FigurePlacement.readsAsSentence("Table 1 lists the results"))
		XCTAssertFalse(FigurePlacement.readsAsSentence("Figure 2: Revenue by region"))
		XCTAssertFalse(FigurePlacement.readsAsSentence("Figure 2 Revenue by region"))
		XCTAssertFalse(FigurePlacement.readsAsSentence("Fig. 3 – the harbour at dawn"))
		let caption = paragraph("Figure 2 Revenue by region", x: 0.3, y: 0.62, width: 0.4, height: 0.03)
		XCTAssertEqual(FigurePlacement.captionRank(caption, figure: box, lines: []), 0)
	}

	func testRemovingAFigureBringsItsWordsBackAsText() throws {
		let box = NormalizedBox(x: 0.2, y: 0.3, width: 0.6, height: 0.3)
		let figure = RescrivaBlock(content: .figure(assetID: UUID().uuidString, caption: "Figure 1: Sales", altText: "Q1 Q2"), box: box)
		let other = paragraph("Body text.", y: 0.7)
		var document = RescrivaDocument(title: "Doc", pages: [RescrivaPage(blocks: [figure, other])])

		document.removeFigure(other.id)
		XCTAssertEqual(document.pages[0].blocks.count, 2, "only figures are removed this way")
		document.removeFigure(figure.id)

		let blocks = document.pages[0].blocks
		XCTAssertEqual(blocks.map(\.content.plainText), ["Q1 Q2", "Figure 1: Sales", "Body text."])
		XCTAssertEqual(blocks[0].box, box)
		XCTAssertGreaterThan(blocks[1].box?.y ?? 0, box.y + box.height, "the caption just below where the figure was")
	}

	func testRemovingAFigureKeepsItsNotes() throws {
		let note = RescrivaNote(text: "Chart is upside down", created: Date(), runID: UUID())
		var labelled = RescrivaBlock(content: .figure(assetID: "a", caption: nil, altText: "Q1 Q2"), box: NormalizedBox(x: 0.2, y: 0.3, width: 0.6, height: 0.3))
		labelled.notes = [note]
		var bare = RescrivaBlock(content: .figure(assetID: "b", caption: nil, altText: nil), box: NormalizedBox(x: 0.2, y: 0.7, width: 0.6, height: 0.2))
		bare.notes = [note]
		var document = RescrivaDocument(title: "Doc", pages: [RescrivaPage(blocks: [labelled, bare])])

		document.removeFigure(labelled.id)
		document.removeFigure(bare.id)

		XCTAssertEqual(document.pages[0].blocks.first?.notes.map(\.text), ["Chart is upside down"], "on the restored words")
		XCTAssertNil(document.pages[0].blocks.first?.notes.first?.runID)
		XCTAssertEqual(document.pages[0].notes.map(\.text), ["Chart is upside down"], "on the page when nothing is restored")
	}

	// MARK: The whole pass

	func testRebuilderPlacesThePhotoWithItsCaptionAndLabel() async throws {
		let page = TextPage()
		var lines = page.paragraph(rows: 5, top: 60)
		page.photo(CGRect(x: 150, y: 300, width: 500, height: 300))
		lines.append(page.text("LABEL", at: CGPoint(x: 330, y: 420), size: 30, gray: 1))
		lines.append(page.text("Figure 1. A test photograph", at: CGPoint(x: 260, y: 612), size: 18))
		lines += page.paragraph(rows: 5, top: 680)
		let data = try XCTUnwrap(UIImage(cgImage: try page.image()).jpegData(compressionQuality: 0.9))
		let snapshot = await Rebuilder.PageSnapshot(imageData: data, lines: lines, aspect: 0.8).decodingImage()
		XCTAssertNotNil(snapshot.image, "the stored JPEG decodes once for every pass")
		let built = RescrivaPage(blocks: Rebuilder.heuristicBlocks(lines))

		let pages = await Rebuilder.detectFigures(in: [built], pages: [snapshot])

		let figures = pages[0].blocks.filter(\.content.isFigure)
		XCTAssertEqual(figures.count, 1)
		guard case .figure(_, let caption, let altText) = figures.first?.content else { return XCTFail("a figure") }
		XCTAssertEqual(caption, "Figure 1. A test photograph")
		XCTAssertEqual(altText, "LABEL", "the word printed on the photo moved into it")
		XCTAssertFalse(pages[0].blocks.contains { $0.content.plainText.contains("test photograph") && !$0.content.isFigure })
		let whiteboard = RescrivaPage(source: .whiteboard, blocks: built.blocks)
		let skipped = await Rebuilder.detectFigures(in: [whiteboard], pages: [snapshot])
		XCTAssertEqual(skipped[0].blocks, whiteboard.blocks, "whiteboards are left alone")
	}

	// MARK: Helpers

	private func paragraph(_ text: String, x: Double = 0.1, y: Double, width: Double = 0.8, height: Double = 0.03) -> RescrivaBlock {
		RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: text)], alignment: .leading),
				   box: NormalizedBox(x: x, y: y, width: width, height: height))
	}

	private func assertBox(_ box: NormalizedBox, equals expected: NormalizedBox, accuracy: Double = 0.015,
						   file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertEqual(box.x, expected.x, accuracy: accuracy, "x", file: file, line: line)
		XCTAssertEqual(box.y, expected.y, accuracy: accuracy, "y", file: file, line: line)
		XCTAssertEqual(box.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
		XCTAssertEqual(box.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
	}
}

/// An 800 × 1000 white page in top-left coordinates, with real text drawn by Core Text.
private final class TextPage {
	let width = 800
	let height = 1000
	private let context: CGContext?

	init() {
		context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
							space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
							bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		context?.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
		context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
	}

	/// `rect` (top-left origin) in the context's bottom-left space.
	private func flipped(_ rect: CGRect) -> CGRect {
		CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
	}

	func normalized(_ rect: CGRect) -> NormalizedBox {
		NormalizedBox(x: rect.minX / CGFloat(width), y: rect.minY / CGFloat(height),
					  width: rect.width / CGFloat(width), height: rect.height / CGFloat(height))
	}

	func fill(_ rect: CGRect, gray: CGFloat = 0.13) {
		context?.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
		context?.fill(flipped(rect))
	}

	/// A grey panel shading smoothly from `from` at its top to `to` at its bottom.
	func gradient(_ rect: CGRect, from: CGFloat, to: CGFloat) {
		let colours = [CGColor(srgbRed: from, green: from, blue: from, alpha: 1), CGColor(srgbRed: to, green: to, blue: to, alpha: 1)]
		guard let context, let shading = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours as CFArray,
													  locations: [0, 1]) else { return }
		let area = flipped(rect)
		context.saveGState()
		context.clip(to: area)
		context.drawLinearGradient(shading, start: CGPoint(x: area.midX, y: area.maxY), end: CGPoint(x: area.midX, y: area.minY), options: [])
		context.restoreGState()
	}

	/// A photo stand-in: a colour gradient with fixed pseudo-random noise.
	func photo(_ rect: CGRect) {
		let w = Int(rect.width), h = Int(rect.height)
		var bytes = [UInt8](repeating: 255, count: w * h * 4)
		var seed: UInt32 = 0x1234_5678
		for y in 0..<h {
			for x in 0..<w {
				seed = seed &* 1_664_525 &+ 1_013_904_223
				let noise = Double(seed >> 24) / 255 * 60 - 30
				let base = 40 + 150 * Double(x) / Double(max(w, 1)) + 30 * Double(y) / Double(max(h, 1)) + noise
				let index = (y * w + x) * 4
				bytes[index] = UInt8(max(0, min(255, base)))
				bytes[index + 1] = UInt8(max(0, min(255, base * 0.85 + 10)))
				bytes[index + 2] = UInt8(max(0, min(255, base * 0.6 + 40)))
			}
		}
		guard let provider = CGDataProvider(data: Data(bytes) as CFData),
			  let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
								  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
								  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
								  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
		context?.draw(image, in: flipped(rect))
	}

	/// Draws `string` with its top-left at `origin` and returns its OCR line.
	@discardableResult
	func text(_ string: String, at origin: CGPoint, size: CGFloat, bold: Bool = false, gray: CGFloat = 0.1) -> RecognizedLine {
		let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
		let attributes: [NSAttributedString.Key: Any] = [
			NSAttributedString.Key(kCTFontAttributeName as String): font,
			NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1),
		]
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
		var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
		let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
		if let context {
			context.textPosition = CGPoint(x: origin.x, y: CGFloat(height) - origin.y - ascent)
			CTLineDraw(line, context)
		}
		let box = CGRect(x: origin.x, y: origin.y, width: lineWidth, height: ascent + descent)
		return RecognizedLine(text: string, confidence: 1, alternatives: [],
							  box: CGRect(x: box.minX / CGFloat(width), y: box.minY / CGFloat(height),
										  width: box.width / CGFloat(width), height: box.height / CGFloat(height)))
	}

	/// `rows` lines of body text from `top`, 30 px apart.
	func paragraph(rows: Int, top: CGFloat) -> [RecognizedLine] {
		(0..<rows).map { row in
			let words = row % 3 == 2 ? "and so the story goes on." : "The quick brown fox jumps over the lazy dog again"
			return text(words, at: CGPoint(x: 70, y: top + CGFloat(row) * 30), size: 18)
		}
	}

	func image() throws -> CGImage {
		try XCTUnwrap(context?.makeImage())
	}
}
