//
//  RescrivaRendererTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Unit tests for the export renderers: the ZIP writer, the shared OOXML
//  helpers, LaTeX → OMML, Word, PowerPoint, plain text and Markdown.
//

import XCTest
@testable import scanner

/// Exercises every renderer against small IR documents and inspects the
/// packages they produce (the ZIP writer only stores, so the tests read the
/// archives back with a tiny STORED-only reader).
final class RescrivaRendererTests: XCTestCase {

	// MARK: Fixtures

	/// A well-known 1×1 PNG.
	private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==") ?? Data()

	private func openFlag(_ read: String) -> RescrivaFlag {
		RescrivaFlag(kind: .word, title: "Did you mean…", detail: "Vision wasn't sure about this word", read: read,
				  options: [.init(label: "anomalous"), .init(label: "Keep as read")], resolution: nil)
	}

	/// Two pages: heading, flagged paragraph with notes, equation, diagram and
	/// checklist; then a table with a merged cell, a nested ordered list and a figure.
	private func sampleDocument() -> (document: RescrivaDocument, flaggedRun: RescrivaRun) {
		let flagged = RescrivaRun(text: "anomolous", flag: openFlag("anomolous"))
		let saturated = RescrivaRun(text: "saturated")
		let paragraph = RescrivaBlock(content: .paragraph(runs: [
			RescrivaRun(text: "The enzyme becomes "), saturated, RescrivaRun(text: "; trial 3 looked "), flagged,
			RescrivaRun(text: " <check> & retry", bold: true),
		], alignment: .justified), fontClass: .serif, notes: [
			RescrivaNote(text: "Ask Priya whether trial 3 used fresh buffer.", created: Date(timeIntervalSince1970: 0)),
			RescrivaNote(text: "Saturated or saturating?", created: Date(timeIntervalSince1970: 60), runID: saturated.id),
		])
		let stroke = RGBColor(hex: 0x5A7A52)
		let edgeFlag = RescrivaFlag(kind: .edge, title: "Arrow?", detail: "", read: "", options: [], resolution: nil)
		let diagram = Diagram(nodes: [
			.init(id: "S", label: "Substrate", shape: .rectangle, box: NormalizedBox(x: 0.05, y: 0.1, width: 0.25, height: 0.2), stroke: stroke),
			.init(id: "E", label: "Enzyme", shape: .ellipse, box: NormalizedBox(x: 0.05, y: 0.65, width: 0.25, height: 0.25), stroke: RGBColor(hex: 0xC0674A)),
			.init(id: "ES", label: "ES \"complex\"", shape: .diamond, box: NormalizedBox(x: 0.4, y: 0.35, width: 0.25, height: 0.25), stroke: stroke),
			.init(id: "P", label: "Product", shape: .roundedRectangle, box: NormalizedBox(x: 0.72, y: 0.35, width: 0.25, height: 0.25), stroke: stroke),
		], edges: [
			.init(id: "1", from: "S", to: "ES"),
			.init(id: "2", from: "E", to: "ES"),
			.init(id: "3", from: "ES", to: "P", label: "kcat"),
			.init(id: "4", from: "P", to: "E", flag: edgeFlag),
		], caption: "Michaelis–Menten")
		let page1 = RescrivaPage(blocks: [
			RescrivaBlock(content: .heading(level: 1, runs: [RescrivaRun(text: "Week 6 — Enzyme kinetics")])),
			paragraph,
			RescrivaBlock(content: .equation(latex: "v = \\frac{V_{max}[S]}{K_m + [S]}", linear: "v = Vmax[S] / (Km + [S])", display: true)),
			RescrivaBlock(content: .diagram(diagram)),
			RescrivaBlock(content: .list(style: .checkbox, items: [
				ListItem(runs: [RescrivaRun(text: "Repeat trial 3 at 37°C")], checked: false),
				ListItem(runs: [RescrivaRun(text: "Plot Lineweaver–Burk")], checked: true),
			])),
		])
		let page2 = RescrivaPage(size: .widescreen, blocks: [
			RescrivaBlock(content: .table(rows: [
				[TableCell(runs: [RescrivaRun(text: "[S]")]), TableCell(runs: [RescrivaRun(text: "Rate")], columnSpan: 2)],
				[TableCell(runs: [RescrivaRun(text: "0.5")]), TableCell(runs: [RescrivaRun(text: "12.1")]), TableCell(runs: [RescrivaRun(text: "11.8")])],
				[TableCell(runs: [RescrivaRun(text: "2.0")]), TableCell(runs: [RescrivaRun(text: "30.4")]), TableCell(runs: [RescrivaRun(text: "29.9")])],
			]), box: NormalizedBox(x: 0.05, y: 0.1, width: 0.5, height: 0.4)),
			RescrivaBlock(content: .list(style: .ordered, items: [
				ListItem(runs: [RescrivaRun(text: "Prepare dilutions")]),
				ListItem(runs: [RescrivaRun(text: "0.5 mM")], level: 1),
				ListItem(runs: [RescrivaRun(text: "Run assay")]),
			])),
			RescrivaBlock(content: .figure(assetID: "fig", caption: "Figure 1", altText: "Bar chart")),
		], notes: [RescrivaNote(text: "Bring the figure on Thursday.", created: Date(timeIntervalSince1970: 120))])
		return (RescrivaDocument(title: "Week 6 & <kinetics>", pages: [page1, page2]), flagged)
	}

	private var options: RenderOptions {
		RenderOptions(includeNotes: true, assets: ["fig": onePixelPNG], author: "Rescriva Tester")
	}

	// MARK: Archive reading

	/// Reads a STORED-only ZIP (what `ZipArchive` writes) into ordered entries,
	/// checking every CRC.
	private func entries(_ archive: Data) throws -> [(name: String, data: Data)] {
		let bytes = [UInt8](archive)
		func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
		func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
		let end = bytes.count - 22
		XCTAssertGreaterThanOrEqual(end, 0)
		XCTAssertEqual(u32(end), 0x0605_4B50, "end-of-central-directory signature")
		let count = u16(end + 10)
		var cursor = u32(end + 16)
		var result: [(name: String, data: Data)] = []
		for _ in 0..<count {
			XCTAssertEqual(u32(cursor), 0x0201_4B50, "central directory signature")
			let crc = UInt32(u32(cursor + 16))
			let size = u32(cursor + 20)
			let nameLength = u16(cursor + 28)
			let extraLength = u16(cursor + 30)
			let commentLength = u16(cursor + 32)
			let offset = u32(cursor + 42)
			let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
			XCTAssertEqual(u32(offset), 0x0403_4B50, "local header signature for \(name)")
			let start = offset + 30 + u16(offset + 26) + u16(offset + 28)
			let data = Data(bytes[start..<(start + size)])
			XCTAssertEqual(ZipArchive.crc32(data), crc, "CRC for \(name)")
			result.append((name, data))
			cursor += 46 + nameLength + extraLength + commentLength
		}
		return result
	}

	private func parts(_ archive: Data) throws -> [String: String] {
		var map: [String: String] = [:]
		for entry in try entries(archive) where entry.name.hasSuffix(".xml") || entry.name.hasSuffix(".rels") {
			map[entry.name] = String(decoding: entry.data, as: UTF8.self)
		}
		return map
	}

	private func assertWellFormed(_ parts: [String: String], file: StaticString = #filePath, line: UInt = #line) {
		for (name, xml) in parts {
			let parser = XMLParser(data: Data(xml.utf8))
			XCTAssertTrue(parser.parse(), "\(name) is not well-formed: \(String(describing: parser.parserError))", file: file, line: line)
		}
	}

	// MARK: ZIP and OOXML helpers

	func testCRC32MatchesTheStandardCheckValue() {
		XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
		XCTAssertEqual(ZipArchive.crc32(Data()), 0)
	}

	func testZipWritesContentTypesFirstThenInsertionOrder() throws {
		var archive = ZipArchive(modified: Date(timeIntervalSince1970: 1_700_000_000))
		try archive.add("b.txt", text: "bee")
		try archive.add(ZipArchive.contentTypesPath, text: "<Types/>")
		try archive.add("a/c.xml", text: "<c/>")
		let read = try entries(try archive.archiveData())
		XCTAssertEqual(read.map(\.name), ["[Content_Types].xml", "b.txt", "a/c.xml"])
		XCTAssertEqual(read[1].data, Data("bee".utf8))
	}

	func testZipRejectsDuplicateAndAbsolutePaths() throws {
		var archive = ZipArchive()
		try archive.add("x.xml", text: "<x/>")
		XCTAssertThrowsError(try archive.add("x.xml", text: "<y/>"))
		XCTAssertThrowsError(try archive.add("/abs.xml", text: "<y/>"))
	}

	func testDOSTimestampEncoding() {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone.current
		let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 13, minute: 45, second: 30)) ?? Date()
		let stamp = ZipArchive.dosDateTime(date)
		XCTAssertEqual(stamp.date, UInt16((2026 - 1980) << 9 | 10 << 5 | 10))
		XCTAssertEqual(stamp.time, UInt16(13 << 11 | 45 << 5 | 15))
	}

	func testXMLEscapingStripsIllegalCharacters() {
		XCTAssertEqual(OOXML.escape("a<b&c\"d'e\u{0001}f\u{FFFE}g\th"), "a&lt;b&amp;c&quot;d&apos;ef" + "g\th")
	}

	func testImageSniffing() {
		XCTAssertEqual(RescrivaImageInfo(data: onePixelPNG), RescrivaImageInfo(format: .png, pixelWidth: 1, pixelHeight: 1))
		var jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
		jpeg += [UInt8](repeating: 0, count: 14)
		jpeg += [0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x20, 0x00, 0x40, 0x03]
		jpeg += [UInt8](repeating: 0, count: 9)
		XCTAssertEqual(RescrivaImageInfo(data: Data(jpeg)), RescrivaImageInfo(format: .jpeg, pixelWidth: 64, pixelHeight: 32))
		XCTAssertNil(RescrivaImageInfo(data: Data("GIF89a".utf8)))
		XCTAssertNil(RescrivaImageInfo(data: Data([0xFF, 0xD8, 0xFF])))
	}

	// MARK: Shared layout helpers

	func testTableGridHonoursHTMLStyleSpans() {
		let cell = { (text: String, rows: Int, columns: Int) in
			TableCell(runs: [RescrivaRun(text: text)], rowSpan: rows, columnSpan: columns)
		}
		let wide = RescrivaTableGrid(rows: [[cell("A", 1, 2)], [cell("B", 1, 1), cell("C", 1, 1), cell("D", 1, 1)]])
		XCTAssertEqual(wide.columnCount, 3)
		XCTAssertEqual(wide.rows[0][1], .covered(row: 0, column: 0))
		XCTAssertEqual(wide.rows[0][2], .empty)

		let tall = RescrivaTableGrid(rows: [[cell("A", 2, 1), cell("B", 1, 1)], [cell("C", 1, 1)]])
		XCTAssertEqual(tall.columnCount, 2)
		XCTAssertEqual(tall.rows[1][0], .covered(row: 0, column: 0))
		XCTAssertEqual(tall.originCell(row: 1, column: 1)?.cell.runs.plainText, "C")
		XCTAssertEqual(tall.originCell(row: 1, column: 0)?.cell.runs.plainText, "A")
	}

	func testDiagramGeometryClipsToOutlines() {
		typealias Geometry = RescrivaDiagramGeometry
		let rect = Geometry.Frame(x: 0, y: 0, width: 100, height: 50, shape: .rectangle)
		let right = Geometry.boundaryPoint(of: rect, toward: (500, 25))
		XCTAssertEqual(right.x, 100, accuracy: 0.001)
		XCTAssertEqual(right.y, 25, accuracy: 0.001)
		let ellipse = Geometry.Frame(x: 0, y: 0, width: 100, height: 50, shape: .ellipse)
		let below = Geometry.boundaryPoint(of: ellipse, toward: (50, 400))
		XCTAssertEqual(below.y, 50, accuracy: 0.001)
		let diamond = Geometry.Frame(x: 0, y: 0, width: 100, height: 100, shape: .diamond)
		let diagonal = Geometry.boundaryPoint(of: diamond, toward: (150, 150))
		XCTAssertEqual(diagonal.x, 75, accuracy: 0.001)
		let other = Geometry.Frame(x: 300, y: 0, width: 100, height: 50, shape: .rectangle)
		let segment = Geometry.clippedSegment(from: rect, to: other, minimumLength: 1)
		XCTAssertEqual(segment?.x1 ?? 0, 100, accuracy: 0.001)
		XCTAssertEqual(segment?.x2 ?? 0, 300, accuracy: 0.001)
		let overlapping = Geometry.Frame(x: 10, y: 0, width: 100, height: 50, shape: .rectangle)
		XCTAssertNil(Geometry.clippedSegment(from: rect, to: overlapping, minimumLength: 1))
	}

	// MARK: LaTeX → OMML

	func testLaTeXSubsetConverts() throws {
		let fraction = try XCTUnwrap(LaTeXToOMML.convert("v = \\frac{V_{max}[S]}{K_m + [S]}"))
		XCTAssertTrue(fraction.hasPrefix("<m:oMath>"))
		XCTAssertTrue(fraction.contains("<m:f><m:num>"))
		XCTAssertTrue(fraction.contains("<m:sSub>"))
		let nary = try XCTUnwrap(LaTeXToOMML.convert("\\sum_{i=1}^{n} x_i^2"))
		XCTAssertTrue(nary.contains("<m:nary>"))
		XCTAssertTrue(nary.contains("<m:sSubSup>"))
		let radical = try XCTUnwrap(LaTeXToOMML.convert("\\sqrt{\\alpha \\cdot \\beta} \\pm \\left( x \\right]"))
		XCTAssertTrue(radical.contains("<m:rad>"))
		XCTAssertTrue(radical.contains("\u{03B1}"))
		XCTAssertTrue(radical.contains("<m:begChr m:val=\"(\"/><m:endChr m:val=\"]\"/>"))
		let relations = try XCTUnwrap(LaTeXToOMML.convert("a \\leq b \\neq c \\approx \\infty \\times 2"))
		XCTAssertTrue(relations.contains("\u{2264}"))
		XCTAssertTrue(relations.contains("\u{221E}"))
		XCTAssertTrue(XMLParser(data: Data(("<r xmlns:m=\"m\" xmlns:w=\"w\">" + fraction + nary + radical + "</r>").utf8)).parse())
	}

	func testLaTeXOutsideTheSubsetReturnsNil() {
		XCTAssertNil(LaTeXToOMML.convert(""))
		XCTAssertNil(LaTeXToOMML.convert("\\frac{1}{2"))
		XCTAssertNil(LaTeXToOMML.convert("a^{b"))
		XCTAssertNil(LaTeXToOMML.convert("x}"))
		XCTAssertNil(LaTeXToOMML.convert("\\begin{matrix} a & b \\end{matrix}"))
		XCTAssertNil(LaTeXToOMML.convert("\\unknowncommand{x}"))
		XCTAssertNil(LaTeXToOMML.convert("\\left( x"))
		XCTAssertNil(LaTeXToOMML.convert(String(repeating: "{", count: 100) + String(repeating: "}", count: 100)))
	}

	// MARK: DOCX

	func testDOCXPackageStructure() throws {
		let (document, _) = sampleDocument()
		let archive = try DOCXRenderer.render(document, options: options)
		let names = try entries(archive).map(\.name)
		XCTAssertEqual(names.first, "[Content_Types].xml")
		for required in ["_rels/.rels", "docProps/core.xml", "docProps/app.xml", "word/document.xml", "word/styles.xml",
						 "word/numbering.xml", "word/settings.xml", "word/_rels/document.xml.rels", "word/comments.xml",
						 "word/media/image1.png"] {
			XCTAssertTrue(names.contains(required), "missing \(required)")
		}
		let xml = try parts(archive)
		assertWellFormed(xml)
		XCTAssertTrue(xml["docProps/core.xml"]?.contains("<dc:title>Week 6 &amp; &lt;kinetics&gt;</dc:title>") ?? false)
	}

	func testDOCXMapsEveryBlockToANativeConstruct() throws {
		let (document, flagged) = sampleDocument()
		let body = try XCTUnwrap(try parts(try DOCXRenderer.render(document, options: options))["word/document.xml"])
		XCTAssertTrue(body.contains("<w:pStyle w:val=\"Heading1\"/>"))
		XCTAssertTrue(body.contains("<w:jc w:val=\"both\"/>"))
		XCTAssertTrue(body.contains("w:ascii=\"Georgia\""))
		XCTAssertTrue(body.contains("<m:oMathPara><m:oMath>"))
		XCTAssertTrue(body.contains("<w14:checkbox><w14:checked w14:val=\"1\"/>"))
		XCTAssertTrue(body.contains("mc:Ignorable=\"w14 wp14\""))
		XCTAssertTrue(body.contains("<wpg:wgp>"))
		XCTAssertTrue(body.contains("prst=\"diamond\""))
		XCTAssertTrue(body.contains("<a:tailEnd type=\"triangle\""))
		XCTAssertTrue(body.contains("<w:gridSpan w:val=\"2\"/>"))
		XCTAssertTrue(body.contains("<w:numId w:val=\"2\"/>"))
		XCTAssertTrue(body.contains("<w:ilvl w:val=\"1\"/>"))
		XCTAssertTrue(body.contains("<pic:pic>"))
		XCTAssertTrue(body.contains("<w:pStyle w:val=\"Caption\"/>"))
		XCTAssertTrue(body.contains("&lt;check&gt; &amp; retry"))
		// Open flags render as read with no markup.
		XCTAssertTrue(body.contains(">\(flagged.text)</w:t>"))
		XCTAssertFalse(body.contains("(?)"))
		// No page break between scanned pages.
		XCTAssertFalse(body.contains("w:type=\"page\""))
	}

	func testDOCXNotesBecomeAnchoredComments() throws {
		let (document, _) = sampleDocument()
		let xml = try parts(try DOCXRenderer.render(document, options: options))
		let body = try XCTUnwrap(xml["word/document.xml"])
		let comments = try XCTUnwrap(xml["word/comments.xml"])
		for id in 0..<3 {
			XCTAssertTrue(body.contains("<w:commentRangeStart w:id=\"\(id)\"/>"), "range start \(id)")
			XCTAssertTrue(body.contains("<w:commentReference w:id=\"\(id)\"/>"), "reference \(id)")
		}
		XCTAssertTrue(comments.contains("Ask Priya whether trial 3 used fresh buffer."))
		XCTAssertTrue(comments.contains("w:author=\"Rescriva Tester\""))
		// The run-anchored note wraps exactly the "saturated" run.
		XCTAssertTrue(body.contains("<w:commentRangeStart w:id=\"1\"/><w:r><w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\" w:cs=\"Georgia\"/></w:rPr><w:t xml:space=\"preserve\">saturated</w:t></w:r><w:commentRangeEnd w:id=\"1\"/>"))
	}

	func testDOCXWithoutNotesHasNoComments() throws {
		let (document, _) = sampleDocument()
		var noNotes = options
		noNotes.includeNotes = false
		let xml = try parts(try DOCXRenderer.render(document, options: noNotes))
		XCTAssertNil(xml["word/comments.xml"])
		XCTAssertFalse(xml["word/document.xml"]?.contains("comment") ?? true)
		XCTAssertFalse(xml["word/_rels/document.xml.rels"]?.contains("comments") ?? true)
	}

	func testDOCXRowSpanWritesVerticalMergeContinuation() throws {
		let table = BlockContent.table(rows: [
			[TableCell(runs: [RescrivaRun(text: "Tall")], rowSpan: 2), TableCell(runs: [RescrivaRun(text: "B")])],
			[TableCell(runs: [RescrivaRun(text: "C")])],
		])
		let document = RescrivaDocument(title: "T", pages: [RescrivaPage(blocks: [RescrivaBlock(content: table)])])
		let body = try XCTUnwrap(try parts(try DOCXRenderer.render(document))["word/document.xml"])
		XCTAssertTrue(body.contains("<w:vMerge w:val=\"restart\"/>"))
		XCTAssertTrue(body.contains("<w:vMerge/></w:tcPr><w:p></w:p></w:tc><w:tc><w:tcPr><w:tcW w:w=\"4680\" w:type=\"dxa\"/></w:tcPr><w:p><w:r><w:t xml:space=\"preserve\">C</w:t>"))
		XCTAssertTrue(body.hasSuffix("<w:p/><w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/><w:cols w:space=\"720\"/></w:sectPr></w:body></w:document>"))
	}

	func testDOCXEquationFallsBackToItalicLinearText() throws {
		let document = RescrivaDocument(title: "E", pages: [RescrivaPage(blocks: [
			RescrivaBlock(content: .equation(latex: "\\begin{pmatrix} a \\end{pmatrix}", linear: "(a)", display: true)),
		])])
		let body = try XCTUnwrap(try parts(try DOCXRenderer.render(document))["word/document.xml"])
		XCTAssertFalse(body.contains("<m:oMath"))
		XCTAssertTrue(body.contains("<w:i/><w:iCs/></w:rPr><w:t xml:space=\"preserve\">(a)</w:t>"))
	}

	func testDOCXMissingFigureAssetBecomesPlaceholderText() throws {
		let document = RescrivaDocument(title: "F", pages: [RescrivaPage(blocks: [
			RescrivaBlock(content: .figure(assetID: "missing", caption: nil, altText: "A chart")),
		])])
		let archive = try DOCXRenderer.render(document)
		XCTAssertFalse(try entries(archive).contains { $0.name.hasPrefix("word/media/") })
		XCTAssertTrue(try parts(archive)["word/document.xml"]?.contains("[Figure: A chart]") ?? false)
	}

	// MARK: PPTX

	func testPPTXPackageStructureAndSpeakerNotes() throws {
		let (document, _) = sampleDocument()
		let archive = try PPTXRenderer.render(document, options: options)
		let names = try entries(archive).map(\.name)
		XCTAssertEqual(names.first, "[Content_Types].xml")
		for required in ["ppt/presentation.xml", "ppt/_rels/presentation.xml.rels", "ppt/presProps.xml", "ppt/viewProps.xml",
						 "ppt/tableStyles.xml", "ppt/theme/theme1.xml", "ppt/slideMasters/slideMaster1.xml",
						 "ppt/slideLayouts/slideLayout1.xml", "ppt/slideLayouts/slideLayout2.xml",
						 "ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slides/_rels/slide2.xml.rels",
						 "ppt/notesMasters/notesMaster1.xml", "ppt/notesSlides/notesSlide1.xml",
						 "ppt/notesSlides/notesSlide2.xml", "ppt/media/image1.png"] {
			XCTAssertTrue(names.contains(required), "missing \(required)")
		}
		XCTAssertFalse(names.contains("ppt/slides/slide3.xml"))
		let xml = try parts(archive)
		assertWellFormed(xml)
		XCTAssertTrue(xml["ppt/presentation.xml"]?.contains("<p:sldSz cx=\"12192000\" cy=\"6858000\"/>") ?? false)
		XCTAssertTrue(xml["ppt/notesSlides/notesSlide1.xml"]?.contains("Ask Priya whether trial 3 used fresh buffer.") ?? false)
		XCTAssertTrue(xml["ppt/notesSlides/notesSlide2.xml"]?.contains("Bring the figure on Thursday.") ?? false)
		XCTAssertTrue(xml["ppt/theme/theme1.xml"]?.contains("<a:accent3><a:srgbClr val=\"\(PPTXRenderer.defaultAccents[2])\"/></a:accent3>") ?? false)
	}

	func testPPTXSlideContent() throws {
		let (document, flagged) = sampleDocument()
		let xml = try parts(try PPTXRenderer.render(document, options: options))
		let slide1 = try XCTUnwrap(xml["ppt/slides/slide1.xml"])
		XCTAssertTrue(slide1.contains("<p:ph type=\"title\"/>"))
		XCTAssertTrue(slide1.contains("Week 6 — Enzyme kinetics"))
		XCTAssertTrue(slide1.contains("<p:cxnSp>"))
		XCTAssertTrue(slide1.contains("<a:stCxn id="))
		XCTAssertTrue(slide1.contains("<a:endCxn id="))
		XCTAssertTrue(slide1.contains("prst=\"ellipse\""))
		XCTAssertTrue(slide1.contains("\u{2611} "))
		XCTAssertTrue(slide1.contains("\u{2610} "))
		XCTAssertTrue(slide1.contains("v = Vmax[S] / (Km + [S])"))
		XCTAssertTrue(slide1.contains("<a:t>\(flagged.text)</a:t>"))
		XCTAssertTrue(xml["ppt/slides/_rels/slide1.xml.rels"]?.contains("slideLayout1.xml") ?? false)
		let slide2 = try XCTUnwrap(xml["ppt/slides/slide2.xml"])
		XCTAssertTrue(slide2.contains("<a:tbl>"))
		XCTAssertTrue(slide2.contains("gridSpan=\"2\""))
		XCTAssertTrue(slide2.contains("hMerge=\"1\""))
		XCTAssertTrue(slide2.contains("<a:buAutoNum type=\"arabicPeriod\"/>"))
		XCTAssertTrue(slide2.contains("<a:buAutoNum type=\"alphaLcPeriod\"/>"))
		XCTAssertTrue(slide2.contains("<p:pic>"))
		XCTAssertTrue(xml["ppt/slides/_rels/slide2.xml.rels"]?.contains("slideLayout2.xml") ?? false)
	}

	func testPPTXWithoutNotesHasNoNotesParts() throws {
		let (document, _) = sampleDocument()
		var noNotes = options
		noNotes.includeNotes = false
		let names = try entries(try PPTXRenderer.render(document, options: noNotes)).map(\.name)
		XCTAssertFalse(names.contains { $0.contains("notesSlide") || $0.contains("notesMaster") })
	}

	func testPPTXSlideSizeFollowsTheFirstPage() throws {
		func size(_ page: PageSize) throws -> String? {
			let document = RescrivaDocument(title: "S", pages: [RescrivaPage(size: page)])
			return try parts(try PPTXRenderer.render(document))["ppt/presentation.xml"]
		}
		XCTAssertTrue(try size(PageSize(width: 1024, height: 768))?.contains("<p:sldSz cx=\"9144000\" cy=\"6858000\" type=\"screen4x3\"/>") ?? false)
		XCTAssertTrue(try size(.widescreen)?.contains("cx=\"12192000\"") ?? false)
		XCTAssertTrue(try size(.letter)?.contains("cx=\"12192000\"") ?? false)
	}

	func testEdgeDirectionsAndParallelogramsReachEveryFormat() throws {
		let ink = RGBColor(hex: 0x222222)
		let diagram = Diagram(nodes: [
			.init(id: "in", label: "Input", shape: .parallelogram, box: NormalizedBox(x: 0.05, y: 0.1, width: 0.25, height: 0.2), stroke: ink),
			.init(id: "api", label: "API", shape: .rectangle, box: NormalizedBox(x: 0.4, y: 0.1, width: 0.2, height: 0.2), stroke: ink),
			.init(id: "db", label: "Store", shape: .rectangle, box: NormalizedBox(x: 0.75, y: 0.1, width: 0.2, height: 0.2), stroke: ink),
		], edges: [
			.init(id: "1", from: "in", to: "api", direction: .none),
			.init(id: "2", from: "api", to: "db", direction: .both),
		])
		let document = RescrivaDocument(title: "D", pages: [RescrivaPage(blocks: [RescrivaBlock(content: .diagram(diagram))])])

		let docx = try XCTUnwrap(try parts(try DOCXRenderer.render(document))["word/document.xml"])
		XCTAssertTrue(docx.contains("prst=\"parallelogram\""))
		XCTAssertEqual(docx.components(separatedBy: "<a:headEnd type=\"triangle\"").count - 1, 1, "only the two-way edge has a head at its start")
		XCTAssertEqual(docx.components(separatedBy: "<a:tailEnd type=\"triangle\"").count - 1, 1, "the plain line has no head at all")

		let slide = try XCTUnwrap(try parts(try PPTXRenderer.render(document))["ppt/slides/slide1.xml"])
		XCTAssertTrue(slide.contains("prst=\"parallelogram\""))
		XCTAssertEqual(slide.components(separatedBy: "<a:headEnd type=\"triangle\"").count - 1, 1)
		XCTAssertEqual(slide.components(separatedBy: "<a:tailEnd type=\"triangle\"").count - 1, 1)

		let markdown = MarkdownRenderer.render(document)
		XCTAssertTrue(markdown.contains("    n1[/\"Input\"/]\n"))
		XCTAssertTrue(markdown.contains("    n1 --- n2\n    n2 <--> n3\n```"))
		let text = PlainTextRenderer.render(document)
		XCTAssertTrue(text.contains("Input — API\nAPI ↔ Store"))
	}

	func testEmptyDocumentsStillProduceValidPackages() throws {
		let empty = RescrivaDocument(title: "", pages: [])
		let docx = try parts(try DOCXRenderer.render(empty))
		assertWellFormed(docx)
		XCTAssertTrue(docx["word/document.xml"]?.contains("<w:body><w:p/><w:sectPr>") ?? false)
		let pptx = try parts(try PPTXRenderer.render(empty))
		assertWellFormed(pptx)
		XCTAssertNotNil(pptx["ppt/slides/slide1.xml"], "an empty deck still gets one blank slide")
		XCTAssertNil(pptx["ppt/slides/slide2.xml"])
		XCTAssertEqual(PlainTextRenderer.render(empty), "")
		XCTAssertEqual(MarkdownRenderer.render(empty), "")
	}

	func testPPTXRowSpanUsesVerticalMerge() throws {
		let table = BlockContent.table(rows: [
			[TableCell(runs: [RescrivaRun(text: "Big")], rowSpan: 2, columnSpan: 2), TableCell(runs: [RescrivaRun(text: "R")])],
			[TableCell(runs: [RescrivaRun(text: "S")])],
		])
		let document = RescrivaDocument(title: "T", pages: [RescrivaPage(blocks: [RescrivaBlock(content: table)])])
		let slide = try XCTUnwrap(try parts(try PPTXRenderer.render(document))["ppt/slides/slide1.xml"])
		XCTAssertTrue(slide.contains("<a:tc gridSpan=\"2\" rowSpan=\"2\">"))
		XCTAssertTrue(slide.contains("<a:tc vMerge=\"1\">"))
		XCTAssertTrue(slide.contains("<a:tc hMerge=\"1\" vMerge=\"1\">"))
		XCTAssertEqual(slide.components(separatedBy: "</a:tc>").count - 1, 6)
	}

	// MARK: Plain text and Markdown

	func testPlainText() {
		let (document, _) = sampleDocument()
		let text = PlainTextRenderer.render(document, options: options)
		XCTAssertTrue(text.hasPrefix("Week 6 — Enzyme kinetics\n\nThe enzyme becomes saturated; trial 3 looked anomolous <check> & retry"))
		XCTAssertTrue(text.contains("\n\n---\n\n"))
		XCTAssertTrue(text.contains("\u{2610} Repeat trial 3 at 37°C\n\u{2611} Plot Lineweaver–Burk"))
		XCTAssertTrue(text.contains("1. Prepare dilutions\n  a. 0.5 mM\n2. Run assay"))
		XCTAssertTrue(text.contains("[S]\tRate\t\n0.5\t12.1\t11.8"))
		XCTAssertTrue(text.contains("\nNotes\n- Page 1: Ask Priya"))
		XCTAssertTrue(text.contains("- Page 1, on \u{201C}saturated\u{201D}: Saturated or saturating?"))
		XCTAssertFalse(text.contains("(?)"))
		var noNotes = options
		noNotes.includeNotes = false
		XCTAssertFalse(PlainTextRenderer.render(document, options: noNotes).contains("Notes"))
	}

	func testMarkdownForAI() {
		let (document, _) = sampleDocument()
		let markdown = MarkdownRenderer.render(document, options: options)
		XCTAssertTrue(markdown.hasPrefix("# Week 6 — Enzyme kinetics\n\n"))
		XCTAssertTrue(markdown.contains("looked anomolous (?) **\\<check> & retry**"))
		XCTAssertTrue(markdown.contains("$$v = \\frac{V_{max}[S]}{K_m + [S]}$$"))
		XCTAssertTrue(markdown.contains("```mermaid\nflowchart TD\n    n1[\"Substrate\"]\n    n2((\"Enzyme\"))\n    n3{\"ES #quot;complex#quot;\"}\n    n4(\"Product\")"))
		XCTAssertTrue(markdown.contains("    n3 -->|\"kcat\"| n4\n    %% uncertain\n    n4 --> n2\n```"))
		XCTAssertTrue(markdown.contains("- [ ] Repeat trial 3 at 37°C\n- [x] Plot Lineweaver–Burk"))
		XCTAssertTrue(markdown.contains("| [S] | Rate |  |\n| --- | --- | --- |\n| 0.5 | 12.1 | 11.8 |"))
		XCTAssertTrue(markdown.contains("1. Prepare dilutions\n  1. 0.5 mM\n2. Run assay"))
		XCTAssertTrue(markdown.contains("![Figure 1](figure-1 \"Bar chart\")"))
		XCTAssertTrue(markdown.contains("## Notes\n\n- Page 1: Ask Priya"))

		let quiet = MarkdownRenderer.render(document, options: options, markUncertain: false)
		XCTAssertFalse(quiet.contains("(?)"))
		XCTAssertFalse(quiet.contains("%% uncertain"))
		XCTAssertTrue(quiet.contains("n4 --> n2"))
	}

	func testMarkdownEscapesInlineSyntaxAndKeepsEmphasisValid() {
		let runs = [
			RescrivaRun(text: "Use 2*3 and snake_case "),
			RescrivaRun(text: "bold ", bold: true),
			RescrivaRun(text: "both", bold: true, italic: true),
			RescrivaRun(text: " gone", strikethrough: true),
		]
		let document = RescrivaDocument(title: "M", pages: [RescrivaPage(blocks: [
			RescrivaBlock(content: .paragraph(runs: runs, alignment: .leading)),
			RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "# not a heading")], alignment: .leading)),
		])])
		let markdown = MarkdownRenderer.render(document, options: RenderOptions(includeNotes: false))
		XCTAssertTrue(markdown.contains("Use 2\\*3 and snake\\_case **bold** ***both*** ~~gone~~"))
		XCTAssertTrue(markdown.contains("\\# not a heading"))
	}
}
