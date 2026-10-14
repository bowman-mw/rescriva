//
//  RescrivaRendererTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Unit tests for the export renderers: the ZIP writer, the shared OOXML
//  helpers, LaTeX → OMML, the equation pictures, Word, PowerPoint, plain
//  text and Markdown.
//

import Compression
import XCTest
@testable import scanner

/// Reads a ZIP that `ZipArchive` wrote (STORED or DEFLATE entries, no data
/// descriptors) back into ordered entries, inflating with Apple's decoder and
/// checking every CRC. Shared by the renderer tests and any test that looks
/// inside an exported package.
enum ZipTestReader {
	struct Entry {
		let name: String
		let data: Data
		let method: Int
		let compressedSize: Int
	}

	static func entries(_ archive: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [Entry] {
		let bytes = [UInt8](archive)
		func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
		func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
		let end = bytes.count - 22
		XCTAssertGreaterThanOrEqual(end, 0, file: file, line: line)
		XCTAssertEqual(u32(end), 0x0605_4B50, "end-of-central-directory signature", file: file, line: line)
		let count = u16(end + 10)
		var cursor = u32(end + 16)
		var result: [Entry] = []
		for _ in 0..<count {
			XCTAssertEqual(u32(cursor), 0x0201_4B50, "central directory signature", file: file, line: line)
			let flags = u16(cursor + 8)
			let method = u16(cursor + 10)
			let crc = UInt32(u32(cursor + 16))
			let compressedSize = u32(cursor + 20)
			let size = u32(cursor + 24)
			let nameLength = u16(cursor + 28)
			let extraLength = u16(cursor + 30)
			let commentLength = u16(cursor + 32)
			let offset = u32(cursor + 42)
			let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
			XCTAssertEqual(flags & 0x0008, 0, "\(name) must not use a data descriptor", file: file, line: line)
			XCTAssertEqual(u32(offset), 0x0403_4B50, "local header signature for \(name)", file: file, line: line)
			XCTAssertEqual(u16(offset + 4), 20, "\(name) version needed", file: file, line: line)
			XCTAssertEqual(u16(offset + 8), method, "\(name) method agrees between headers", file: file, line: line)
			XCTAssertEqual(u32(offset + 18), compressedSize, "\(name) compressed size agrees", file: file, line: line)
			XCTAssertEqual(u32(offset + 22), size, "\(name) size agrees", file: file, line: line)
			let start = offset + 30 + u16(offset + 26) + u16(offset + 28)
			let payload = Data(bytes[start..<(start + compressedSize)])
			let data: Data
			switch method {
			case 0:
				data = payload
			case 8:
				data = inflate(payload, size: size) ?? Data()
				XCTAssertEqual(data.count, size, "\(name) inflates to its size", file: file, line: line)
			default:
				XCTFail("\(name) uses method \(method)", file: file, line: line)
				data = Data()
			}
			XCTAssertEqual(ZipArchive.crc32(data), crc, "CRC for \(name)", file: file, line: line)
			result.append(Entry(name: name, data: data, method: method, compressedSize: compressedSize))
			cursor += 46 + nameLength + extraLength + commentLength
		}
		return result
	}

	/// Raw DEFLATE → bytes, with Apple's decoder, independent of the writer.
	static func inflate(_ payload: Data, size: Int) -> Data? {
		guard size > 0 else { return Data() }
		var output = Data(count: size)
		let written = payload.withUnsafeBytes { source -> Int in
			guard let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
			return output.withUnsafeMutableBytes { destination -> Int in
				guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
				return compression_decode_buffer(destinationBase, size, sourceBase, source.count, nil, COMPRESSION_ZLIB)
			}
		}
		return written == size ? output : nil
	}
}

/// Exercises every renderer against small IR documents and inspects the
/// packages they produce, read back with `ZipTestReader`.
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

	/// The archive's entries in order, inflated and CRC-checked.
	private func entries(_ archive: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [ZipTestReader.Entry] {
		try ZipTestReader.entries(archive, file: file, line: line)
	}

	/// Capture groups of every match of `pattern` in `text`.
	private func matches(_ pattern: String, in text: String) throws -> [[String]] {
		let regex = try NSRegularExpression(pattern: pattern)
		let whole = NSRange(text.startIndex..., in: text)
		return regex.matches(in: text, range: whole).map { match in
			(1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
		}
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

	func testDeflateRoundTripsAndNeverGrowsAnEntry() throws {
		let xml = String(repeating: "<w:p><w:r><w:t xml:space=\"preserve\">Minutes of the meeting.</w:t></w:r></w:p>", count: 200)
		let deflated = try XCTUnwrap(ZipArchive.deflate(Data(xml.utf8)))
		XCTAssertLessThan(deflated.count, xml.utf8.count / 10, "repetitive XML shrinks by far more than ten times")
		XCTAssertEqual(ZipTestReader.inflate(deflated, size: xml.utf8.count), Data(xml.utf8), "Apple's decoder reads the raw stream back")
		XCTAssertEqual(ZipArchive.inflate(deflated, size: xml.utf8.count), Data(xml.utf8))
		XCTAssertNil(ZipArchive.deflate(Data("abc".utf8)), "three bytes can't shrink")
		XCTAssertNil(ZipArchive.deflate(Data()), "nothing to compress")
		XCTAssertNil(ZipArchive.inflate(Data([0xFF, 0xFF, 0xFF]), size: 10), "garbage doesn't inflate")
	}

	func testZipDeflatesWhatShrinksAndStoresTheRest() throws {
		let xml = String(repeating: "<w:p><w:r><w:t>Agenda item</w:t></w:r></w:p>", count: 100)
		var archive = ZipArchive(modified: Date(timeIntervalSince1970: 1_700_000_000))
		try archive.add(ZipArchive.contentTypesPath, text: "<Types/>")
		try archive.add("word/document.xml", text: xml)
		// A JPEG's entropy-coded body is as good as random: deflating it only adds a block header.
		var state: UInt32 = 0x9E37_79B9
		let noise = Data((0..<256).map { _ -> UInt8 in
			state ^= state << 13; state ^= state >> 17; state ^= state << 5
			return UInt8(truncatingIfNeeded: state)
		})
		try archive.add("word/media/image1.jpeg", data: noise)
		try archive.add("tiny.txt", text: "abc")
		XCTAssertEqual(archive.method(for: "word/document.xml"), .deflate)
		XCTAssertEqual(archive.method(for: "word/media/image1.jpeg"), .stored, "noise can't shrink")
		XCTAssertEqual(archive.method(for: "tiny.txt"), .stored)
		XCTAssertNil(archive.method(for: "missing.xml"))

		let data = try archive.archiveData()
		XCTAssertLessThan(data.count, xml.utf8.count / 2, "the package is far smaller than its biggest part")
		let read = try entries(data)
		XCTAssertEqual(read.map(\.name), ["[Content_Types].xml", "word/document.xml", "word/media/image1.jpeg", "tiny.txt"])
		XCTAssertEqual(read.map(\.method), [0, 8, 0, 0])
		XCTAssertEqual(read[1].data, Data(xml.utf8), "the deflated part reads back whole")
		XCTAssertLessThan(read[1].compressedSize, xml.utf8.count / 10)
		XCTAssertEqual(read[2].data, noise)
		XCTAssertEqual(read[2].compressedSize, noise.count)
		XCTAssertEqual(read[3].data, Data("abc".utf8))
		XCTAssertEqual(read[3].compressedSize, 3)
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

	/// Commands that take an argument recurse through `parseAtom` without a
	/// brace group, so a long chain of them must hit the depth cap, not the stack.
	func testLaTeXDeepCommandNestingFailsCleanly() throws {
		XCTAssertNil(LaTeXToOMML.convert(String(repeating: "\\hat", count: 900) + "{x}"), "under the length cap, over the depth cap")
		XCTAssertNil(LaTeXToOMML.convert(String(repeating: "\\hat", count: 2000) + "{x}"), "over the length cap")
		XCTAssertNil(LaTeXToOMML.convert(String(repeating: "\\sqrt", count: 700) + "{x}"))
		XCTAssertNil(LaTeXToOMML.convert(String(repeating: "\\frac{1}", count: 400) + "{2}"))
		// Real nesting still converts.
		let nested = try XCTUnwrap(LaTeXToOMML.convert("\\hat{\\hat{\\hat{\\hat{x}}}} + \\frac{1}{\\frac{2}{\\frac{3}{\\frac{4}{\\sqrt{\\sqrt{5}}}}}}"))
		XCTAssertEqual(nested.components(separatedBy: "<m:acc>").count - 1, 4)
		XCTAssertEqual(nested.components(separatedBy: "<m:f>").count - 1, 4)
	}

	// MARK: Equation pictures

	func testEquationPicturesAreKeyedAwayFromFiguresAndSizedByPoints() {
		let key = EquationPictures.assetKey(for: "  a & b\n")
		XCTAssertEqual(key, "equation:a & b")
		XCTAssertTrue(key.hasPrefix(EquationPictures.keyPrefix))
		XCTAssertNil(UUID(uuidString: key), "never mistaken for a figure's asset id")
		XCTAssertTrue(EquationPictures.needsPicture("a & b"))
		XCTAssertFalse(EquationPictures.needsPicture("\\frac{a}{b}"))

		// 300 × 60 px at 3 px/pt is 100 × 20 pt.
		let info = RescrivaImageInfo(format: .png, pixelWidth: 300, pixelHeight: 60)
		let natural = EquationPictures.extent(of: info, maxWidthInches: 6)
		XCTAssertEqual(natural.cx, OOXML.emu(points: 100))
		XCTAssertEqual(natural.cy, OOXML.emu(points: 20))
		let narrow = EquationPictures.extent(of: info, maxWidthInches: 1)
		XCTAssertEqual(narrow.cx, OOXML.emu(inches: 1))
		XCTAssertEqual(narrow.cy, OOXML.emu(inches: 0.2))
	}

	@MainActor
	func testEquationPicturesCoverOnlyWhatOMMLCannotTypeset() throws {
		let unconvertible = "a & b"
		let document = RescrivaDocument(title: "E", pages: [RescrivaPage(blocks: [
			RescrivaBlock(content: .equation(latex: "v = \\frac{a}{b}", linear: "v = a / b", display: true)),
			RescrivaBlock(content: .equation(latex: unconvertible, linear: "a & b", display: false)),
			RescrivaBlock(content: .equation(latex: unconvertible, linear: "a & b", display: true)),
			RescrivaBlock(content: .equation(latex: "\\mathbb{R}", linear: "R", display: false)),
		])])
		let pictures = EquationPictures.pictures(for: document)
		XCTAssertEqual(pictures.keys.sorted(), [EquationPictures.assetKey(for: unconvertible)], "one picture, for the one equation OMML can't do and the preview can")
		let data = try XCTUnwrap(pictures[EquationPictures.assetKey(for: unconvertible)])
		let info = try XCTUnwrap(RescrivaImageInfo(data: data))
		XCTAssertEqual(info.format, .png)
		XCTAssertGreaterThan(info.pixelWidth, 20)
		XCTAssertGreaterThan(info.pixelHeight, 20)
		XCTAssertNil(EquationView.pngData(latex: "\\mathbb{R}", scale: 3), "what the preview can't typeset gets no picture")
		XCTAssertNil(EquationView.pngData(latex: "", scale: 3))

		// The picture then rides into Word with the LaTeX as its alt text.
		let body = try XCTUnwrap(try parts(try DOCXRenderer.render(document, options: RenderOptions(assets: pictures)))["word/document.xml"])
		XCTAssertEqual(body.components(separatedBy: "<pic:pic>").count - 1, 2)
		XCTAssertTrue(body.contains("descr=\"a &amp; b\""))
	}

	func testDOCXEquationWithoutOMMLEmbedsItsPictureWithTheLaTeXAsAltText() throws {
		let latex = "\\begin{pmatrix} a & b \\end{pmatrix}"
		let document = RescrivaDocument(title: "E", pages: [RescrivaPage(blocks: [
			RescrivaBlock(content: .equation(latex: latex, linear: "(a b)", display: true)),
		])])
		let archive = try DOCXRenderer.render(document, options: RenderOptions(assets: [EquationPictures.assetKey(for: latex): onePixelPNG]))
		let names = try entries(archive).map(\.name)
		XCTAssertTrue(names.contains("word/media/image1.png"))
		let xml = try parts(archive)
		assertWellFormed(xml)
		let body = try XCTUnwrap(xml["word/document.xml"])
		XCTAssertFalse(body.contains("<m:oMath"))
		XCTAssertFalse(body.contains("<w:i/>"), "no italic fallback when the picture is there")
		XCTAssertTrue(body.contains("<w:jc w:val=\"center\"/>"), "a display equation is centred")
		XCTAssertTrue(body.contains("<pic:pic>"))
		XCTAssertTrue(body.contains("descr=\"\\begin{pmatrix} a &amp; b \\end{pmatrix}\""))
		// One pixel at 3 px/pt is a third of a point.
		XCTAssertTrue(body.contains("<wp:extent cx=\"\(OOXML.emu(inches: 1.0 / 216))\" cy=\"\(OOXML.emu(inches: 1.0 / 216))\"/>"))
		XCTAssertTrue(xml["word/_rels/document.xml.rels"]?.contains("media/image1.png") ?? false)
	}

	func testPPTXEquationWithoutOMMLEmbedsItsPictureWithTheLaTeXAsAltText() throws {
		let latex = "\\begin{pmatrix} a & b \\end{pmatrix}"
		let document = RescrivaDocument(title: "E", pages: [RescrivaPage(blocks: [
			RescrivaBlock(content: .heading(level: 1, runs: [RescrivaRun(text: "Matrices")])),
			RescrivaBlock(content: .equation(latex: latex, linear: "(a b)", display: true)),
			RescrivaBlock(content: .equation(latex: "x^2", linear: "x^2", display: false)),
		])])
		let archive = try PPTXRenderer.render(document, options: RenderOptions(assets: [EquationPictures.assetKey(for: latex): onePixelPNG]))
		let names = try entries(archive).map(\.name)
		XCTAssertTrue(names.contains("ppt/media/image1.png"))
		let xml = try parts(archive)
		assertWellFormed(xml)
		let slide = try XCTUnwrap(xml["ppt/slides/slide1.xml"])
		XCTAssertTrue(slide.contains("<p:pic><p:nvPicPr><p:cNvPr id=\"3\" name=\"Equation 3\" descr=\"\\begin{pmatrix} a &amp; b \\end{pmatrix}\"/>"))
		XCTAssertFalse(slide.contains("<a:t>(a b)</a:t>"), "the linear text isn't printed as well")
		XCTAssertTrue(slide.contains("<a:t>x^2</a:t>"), "an equation without a picture still prints its text")
		XCTAssertTrue(xml["ppt/slides/_rels/slide1.xml.rels"]?.contains("../media/image1.png") ?? false)
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
		XCTAssertTrue(body.contains("<a:stCxn id="))
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

	/// Every arrow is a `straightConnector1` whose `a:stCxn`/`a:endCxn` name a
	/// shape of the same group by its `wps:cNvPr` id and a site that shape has,
	/// so Word keeps it attached when a shape is dragged.
	func testDOCXConnectorsAttachToTheirShapes() throws {
		let (document, _) = sampleDocument()
		let body = try XCTUnwrap(try parts(try DOCXRenderer.render(document, options: options))["word/document.xml"])
		let shapes = try matches("<wps:cNvPr id=\"(\\d+)\" name=\"Shape \\d+\"/><wps:cNvSpPr/><wps:spPr><a:xfrm><a:off[^>]*/><a:ext[^>]*/></a:xfrm><a:prstGeom prst=\"(\\w+)\"", in: body)
		XCTAssertEqual(shapes.count, 4)
		var sitesByID: [String: Int] = [:]
		for shape in shapes {
			sitesByID[shape[0]] = shape[1] == "ellipse" ? 8 : 4
		}
		let connectors = try matches("<wps:cNvCnPr><a:stCxn id=\"(\\d+)\" idx=\"(\\d+)\"/><a:endCxn id=\"(\\d+)\" idx=\"(\\d+)\"/></wps:cNvCnPr><wps:spPr><a:xfrm[^>]*><a:off[^>]*/><a:ext[^>]*/></a:xfrm><a:prstGeom prst=\"(\\w+)\"", in: body)
		XCTAssertEqual(connectors.count, 4, "one per edge")
		for connector in connectors {
			let startSites = try XCTUnwrap(sitesByID[connector[0]], "start attached to a shape of the group")
			let endSites = try XCTUnwrap(sitesByID[connector[2]], "end attached to a shape of the group")
			XCTAssertLessThan(try XCTUnwrap(Int(connector[1])), startSites)
			XCTAssertLessThan(try XCTUnwrap(Int(connector[3])), endSites)
			XCTAssertNotEqual(connector[0], connector[2])
			XCTAssertEqual(connector[4], "straightConnector1")
		}
		XCTAssertFalse(body.contains("<wps:cNvCnPr/>"), "no loose arrows")
		// The ellipse's start site is one of its eight.
		let fromEnzyme = try XCTUnwrap(connectors.first { sitesByID[$0[0]] == 8 })
		XCTAssertLessThan(try XCTUnwrap(Int(fromEnzyme[1])), 8)
		// Ids are unique across the group's shapes and connectors.
		let ids = try matches("<wps:cNvPr id=\"(\\d+)\"", in: body).map { $0[0] }
		XCTAssertEqual(Set(ids).count, ids.count)
	}

	func testSharedConnectionSitesMatchThePresetOrder() {
		typealias Geometry = RescrivaDiagramGeometry
		let rect = Geometry.Frame(x: 0, y: 0, width: 100, height: 50, shape: .rectangle)
		let rectSites = Geometry.connectionSites(of: rect)
		XCTAssertEqual(rectSites.count, 4)
		XCTAssertEqual(rectSites[0].x, 50, "top first")
		XCTAssertEqual(rectSites[0].y, 0)
		XCTAssertEqual(rectSites[1].x, 0, "then left")
		XCTAssertEqual(rectSites[1].y, 25)
		XCTAssertEqual(rectSites[2].y, 50, "then bottom")
		XCTAssertEqual(rectSites[3].x, 100, "right last")
		let ellipse = Geometry.Frame(x: 200, y: 0, width: 100, height: 50, shape: .ellipse)
		XCTAssertEqual(Geometry.connectionSites(of: ellipse).count, 8)
		let connection = Geometry.connection(from: rect, to: ellipse)
		XCTAssertEqual(connection.startSite, 3, "the rectangle's right side")
		XCTAssertEqual(connection.endSite, 2, "the ellipse's left point")
		XCTAssertEqual(connection.segment, Geometry.Segment(x1: 100, y1: 25, x2: 200, y2: 25))
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

	func testMarkdownIsAnExportFormatThatNeedsARebuild() {
		XCTAssertEqual(ExportFormat.allCases, [.docx, .pptx, .pdf, .md, .txt])
		XCTAssertEqual(ExportFormat.md.fileExtension, ".md")
		XCTAssertEqual(ExportFormat.md.rawValue, "md")
		XCTAssertTrue(ExportFormat.md.needsRebuild, "like Word, it comes from the rebuilt document")
		XCTAssertFalse(ExportFormat.txt.needsRebuild)
		XCTAssertFalse(ExportFormat.pdf.needsRebuild)
	}

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
