//
//  DOCXRenderer.swift
//  Rescriva (fork of Open Scanner)
//
//  Renders a RescrivaDocument as a Word package. Word is a flowing format, so
//  the document is rebuilt by structure, not position: blocks follow one
//  another in IR order with no page breaks between scanned pages. Every IR
//  block maps to a native construct — heading styles, real numbering,
//  checkbox content controls, tables with merged cells, OMML equations,
//  inline pictures, a DrawingML shape group for diagrams and Word comments
//  for notes.
//

import Foundation

/// Renders a `RescrivaDocument` to `.docx` bytes.
///
/// Parts written: `[Content_Types].xml`, `_rels/.rels`, `docProps/core.xml`,
/// `docProps/app.xml`, `word/document.xml`, `word/styles.xml`,
/// `word/numbering.xml`, `word/settings.xml`, `word/fontTable.xml`,
/// `word/_rels/document.xml.rels`, `word/media/*` for figures and
/// `word/comments.xml` when notes are included and present.
enum DOCXRenderer {
	static func render(_ document: RescrivaDocument, options: RenderOptions = RenderOptions()) throws -> Data {
		var writer = DOCXWriter(document: document, options: options)
		let body = writer.renderBody()
		return try writer.package(body: body)
	}

	/// Word font name for a recovered font class (by name only; nothing embedded).
	static func fontName(_ fontClass: FontClass?) -> String? {
		switch fontClass {
		case .serif?: return "Georgia"
		case .sans?: return "Helvetica Neue"
		case .mono?: return "Courier New"
		case nil: return nil
		}
	}
}

/// Diagram geometry shared by the Word and PowerPoint renderers: clipping an
/// edge to its node outlines and placing an edge label beside its arrow.
/// Units are whatever the caller uses (EMU in both renderers).
enum RescrivaDiagramGeometry {
	/// A node's frame with the outline shape that clipping follows.
	struct Frame: Equatable {
		var x: Double
		var y: Double
		var width: Double
		var height: Double
		var shape: Diagram.Shape

		var midX: Double { x + width / 2 }
		var midY: Double { y + height / 2 }
	}

	/// A straight segment from (`x1`, `y1`) to (`x2`, `y2`).
	struct Segment: Equatable {
		var x1: Double
		var y1: Double
		var x2: Double
		var y2: Double

		var length: Double { ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)).squareRoot() }
	}

	/// The centre-to-centre segment clipped to both node outlines; nil when the
	/// nodes overlap so much that no visible arrow (longer than
	/// `minimumLength`) remains.
	static func clippedSegment(from: Frame, to: Frame, minimumLength: Double) -> Segment? {
		let start = boundaryPoint(of: from, toward: (to.midX, to.midY))
		let end = boundaryPoint(of: to, toward: (from.midX, from.midY))
		let segment = Segment(x1: start.x, y1: start.y, x2: end.x, y2: end.y)
		let forward = (end.x - start.x) * (to.midX - from.midX) + (end.y - start.y) * (to.midY - from.midY)
		guard forward > 0, segment.length > minimumLength else { return nil }
		return segment
	}

	/// Where the ray from the frame's centre toward `target` leaves its outline
	/// (rectangle, ellipse or diamond; rounded rectangles and parallelograms clip as rectangles).
	static func boundaryPoint(of frame: Frame, toward target: (x: Double, y: Double)) -> (x: Double, y: Double) {
		let dx = target.x - frame.midX
		let dy = target.y - frame.midY
		let a = frame.width / 2
		let b = frame.height / 2
		guard a > 0, b > 0, dx != 0 || dy != 0 else { return (frame.midX, frame.midY) }
		var t: Double
		switch frame.shape {
		case .ellipse:
			t = 1 / ((dx / a) * (dx / a) + (dy / b) * (dy / b)).squareRoot()
		case .diamond:
			t = 1 / (abs(dx) / a + abs(dy) / b)
		case .rectangle, .roundedRectangle, .parallelogram:
			let tx = dx == 0 ? Double.infinity : a / abs(dx)
			let ty = dy == 0 ? Double.infinity : b / abs(dy)
			t = min(tx, ty)
		}
		t = min(t, 1)
		return (frame.midX + dx * t, frame.midY + dy * t)
	}

	/// Centre for a `width` × `height` label beside the segment's midpoint:
	/// above it (or to the right of a near-vertical one), `gap` clear of the line.
	static func labelCenter(for segment: Segment, width: Double, height: Double, gap: Double) -> (x: Double, y: Double) {
		let midX = (segment.x1 + segment.x2) / 2
		let midY = (segment.y1 + segment.y2) / 2
		let length = segment.length
		guard length > 0 else { return (midX, midY - height / 2 - gap) }
		var normalX = -(segment.y2 - segment.y1) / length
		var normalY = (segment.x2 - segment.x1) / length
		if normalY > 0.2 || (abs(normalY) <= 0.2 && normalX < 0) {
			normalX = -normalX
			normalY = -normalY
		}
		let offset = abs(normalX) * width / 2 + abs(normalY) * height / 2 + gap
		return (midX + normalX * offset, midY + normalY * offset)
	}
}

/// Accumulates the parts of one Word package while the body renders.
private struct DOCXWriter {
	/// A paragraph before comment anchors are injected: `w:pPr` children and content.
	typealias Paragraph = (properties: String, content: String)
	typealias Frame = RescrivaDiagramGeometry.Frame

	let document: RescrivaDocument
	let options: RenderOptions
	/// Text column width in twips (page width minus 1in margins).
	let textWidthTwips: Int
	let pageSizeXML: String

	private var relationships = OOXML.Relationships()
	private var contentTypes = OOXML.ContentTypes()
	private var media: [(path: String, data: Data)] = []
	private var mediaByAsset: [String: String] = [:]
	private var comments: [RescrivaNote] = []
	private var orderedListCount = 0
	private var nextDrawingID = 1
	private var nextControlID = 1

	/// Dark ink used for diagram text and arrows (the palette's dk1).
	static let ink = "1D2233"
	static let maxFigureWidthInches = 6.0
	static let maxFigureHeightInches = 8.0

	init(document: RescrivaDocument, options: RenderOptions) {
		self.document = document
		self.options = options
		let first = document.pages.first?.size ?? .letter
		let isA4 = abs(first.width - PageSize.a4.width) < 12 && abs(first.height - PageSize.a4.height) < 12
		textWidthTwips = isA4 ? 11_906 - 2_880 : 12_240 - 2_880
		let size = isA4 ? "<w:pgSz w:w=\"11906\" w:h=\"16838\"/>" : "<w:pgSz w:w=\"12240\" w:h=\"15840\"/>"
		pageSizeXML = size
		relationships.add(type: OOXML.Rel.styles, target: "styles.xml")
		relationships.add(type: OOXML.Rel.numbering, target: "numbering.xml")
		relationships.add(type: OOXML.Rel.settings, target: "settings.xml")
		relationships.add(type: OOXML.Rel.fontTable, target: "fontTable.xml")
	}

	// MARK: Package

	mutating func package(body: String) throws -> Data {
		let hasComments = options.includeNotes && !comments.isEmpty
		if hasComments {
			relationships.add(type: OOXML.Rel.comments, target: "comments.xml")
		}
		contentTypes.addOverride("word/document.xml", contentType: OOXML.ContentType.wordDocument)
		contentTypes.addOverride("word/styles.xml", contentType: OOXML.ContentType.wordStyles)
		contentTypes.addOverride("word/numbering.xml", contentType: OOXML.ContentType.wordNumbering)
		contentTypes.addOverride("word/settings.xml", contentType: OOXML.ContentType.wordSettings)
		contentTypes.addOverride("word/fontTable.xml", contentType: OOXML.ContentType.wordFontTable)
		if hasComments {
			contentTypes.addOverride("word/comments.xml", contentType: OOXML.ContentType.wordComments)
		}
		contentTypes.addOverride("docProps/core.xml", contentType: OOXML.ContentType.coreProperties)
		contentTypes.addOverride("docProps/app.xml", contentType: OOXML.ContentType.extendedProperties)

		var archive = ZipArchive()
		try archive.add(ZipArchive.contentTypesPath, text: contentTypes.xml)
		try archive.add("_rels/.rels", text: OOXML.packageRelationships(mainPart: "word/document.xml"))
		try archive.add("docProps/core.xml", text: OOXML.coreProperties(title: document.title, author: options.author, date: Date()))
		try archive.add("docProps/app.xml", text: OOXML.appProperties())
		try archive.add("word/document.xml", text: documentXML(body: body))
		try archive.add("word/styles.xml", text: DOCXParts.styles)
		try archive.add("word/numbering.xml", text: DOCXParts.numbering(orderedLists: orderedListCount))
		try archive.add("word/settings.xml", text: DOCXParts.settings)
		try archive.add("word/fontTable.xml", text: DOCXParts.fontTable)
		if hasComments {
			try archive.add("word/comments.xml", text: commentsXML())
		}
		try archive.add("word/_rels/document.xml.rels", text: relationships.xml)
		for item in media {
			try archive.add(item.path, data: item.data)
		}
		return try archive.archiveData()
	}

	private func documentXML(body: String) -> String {
		OOXML.declaration
			+ "<w:document xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\""
			+ " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
			+ " xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\""
			+ " xmlns:wp14=\"http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing\""
			+ " xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\""
			+ " xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
			+ " xmlns:w14=\"http://schemas.microsoft.com/office/word/2010/wordml\""
			+ " xmlns:wpg=\"http://schemas.microsoft.com/office/word/2010/wordprocessingGroup\""
			+ " xmlns:wps=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\""
			+ " xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
			+ " xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""
			+ " mc:Ignorable=\"w14 wp14\"><w:body>"
			+ body
			+ "<w:sectPr>\(pageSizeXML)<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\""
			+ " w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/><w:cols w:space=\"720\"/></w:sectPr>"
			+ "</w:body></w:document>"
	}

	private func commentsXML() -> String {
		let initials = String(options.author.split(separator: " ").compactMap(\.first).prefix(3))
		var out = OOXML.declaration
			+ "<w:comments xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
			+ " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
		for (id, note) in comments.enumerated() {
			out += "<w:comment w:id=\"\(id)\" w:author=\"\(OOXML.escape(options.author))\""
				+ " w:date=\"\(OOXML.timestamp(note.created))\" w:initials=\"\(OOXML.escape(initials))\">"
				+ "<w:p><w:pPr><w:pStyle w:val=\"CommentText\"/></w:pPr>"
				+ "<w:r><w:rPr><w:rStyle w:val=\"CommentReference\"/></w:rPr><w:annotationRef/></w:r>"
				+ "<w:r>\(Self.textContent(note.text))</w:r></w:p></w:comment>"
		}
		return out + "</w:comments>"
	}

	// MARK: Body

	mutating func renderBody() -> String {
		var parts: [String] = []
		var previousWasTable = false
		for page in document.pages {
			let pageNotes = options.includeNotes ? page.notes : []
			if page.blocks.isEmpty, !pageNotes.isEmpty {
				let ids = pageNotes.map { registerComment($0) }
				parts.append("<w:p>" + ids.map(Self.commentStart).joined() + ids.map(Self.commentEnd).joined() + "</w:p>")
				previousWasTable = false
			}
			for (index, block) in page.blocks.enumerated() {
				var notes = options.includeNotes ? block.notes : []
				if index == 0 { notes = pageNotes + notes }
				let isTable: Bool
				if case .table = block.content { isTable = true } else { isTable = false }
				if isTable && previousWasTable { parts.append("<w:p/>") }
				let xml = renderBlock(block, page: page, notes: notes)
				guard !xml.isEmpty else { continue }
				parts.append(xml)
				previousWasTable = isTable
			}
		}
		if previousWasTable || parts.isEmpty { parts.append("<w:p/>") }
		return parts.joined()
	}

	private mutating func registerComment(_ note: RescrivaNote) -> Int {
		comments.append(note)
		return comments.count - 1
	}

	private static func commentStart(_ id: Int) -> String {
		"<w:commentRangeStart w:id=\"\(id)\"/>"
	}

	private static func commentEnd(_ id: Int) -> String {
		"<w:commentRangeEnd w:id=\"\(id)\"/><w:r><w:rPr><w:rStyle w:val=\"CommentReference\"/></w:rPr>"
			+ "<w:commentReference w:id=\"\(id)\"/></w:r>"
	}

	private mutating func renderBlock(_ block: RescrivaBlock, page: RescrivaPage, notes: [RescrivaNote]) -> String {
		let runIDs = Set(RescrivaRunLookup.allRuns(in: block.content).map(\.id))
		var anchors: [UUID: [Int]] = [:]
		var blockComments: [Int] = []
		for note in notes {
			let id = registerComment(note)
			if let runID = note.runID, runIDs.contains(runID) {
				anchors[runID, default: []].append(id)
			} else {
				blockComments.append(id)
			}
		}
		let lead = blockComments.map(Self.commentStart).joined()
		let trail = blockComments.map(Self.commentEnd).joined()
		let font = block.fontClass

		switch block.content {
		case .heading(let level, let runs):
			let style = "<w:pStyle w:val=\"Heading\(min(max(level, 1), 4))\"/>"
			return assemble([(style, runXML(runs, font: font, anchors: anchors))], lead: lead, trail: trail)
		case .paragraph(let runs, let alignment):
			return assemble([(Self.justification(alignment), runXML(runs, font: font, anchors: anchors))], lead: lead, trail: trail)
		case .list(let style, let items):
			return assemble(listParagraphs(style: style, items: items, font: font, anchors: anchors), lead: lead, trail: trail)
		case .table(let rows):
			return table(rows, font: font, anchors: anchors, lead: lead, trail: trail)
		case .equation(let latex, let linear, let display):
			return assemble([equationParagraph(latex: latex, linear: linear, display: display)], lead: lead, trail: trail)
		case .figure(let assetID, let caption, let altText):
			let paragraphs = figureParagraphs(assetID: assetID, caption: caption, altText: altText, box: block.box, page: page)
			return assemble(paragraphs, lead: lead, trail: trail)
		case .diagram(let diagram):
			var paragraphs: [Paragraph] = [("<w:jc w:val=\"center\"/>", diagramRun(diagram, font: font))]
			if let caption = diagram.caption, !caption.isEmpty {
				paragraphs.append(Self.captionParagraph(caption))
			}
			return assemble(paragraphs, lead: lead, trail: trail)
		}
	}

	/// Joins paragraphs, putting whole-block comment starts in the first and
	/// comment ends (with their reference runs) in the last.
	private func assemble(_ paragraphs: [Paragraph], lead: String, trail: String) -> String {
		guard !paragraphs.isEmpty else {
			return lead.isEmpty && trail.isEmpty ? "" : "<w:p>\(lead)\(trail)</w:p>"
		}
		var out = ""
		for (index, paragraph) in paragraphs.enumerated() {
			let content = (index == 0 ? lead : "") + paragraph.content + (index == paragraphs.count - 1 ? trail : "")
			let properties = paragraph.properties.isEmpty ? "" : "<w:pPr>\(paragraph.properties)</w:pPr>"
			out += "<w:p>\(properties)\(content)</w:p>"
		}
		return out
	}

	private static func justification(_ alignment: TextAlignment) -> String {
		switch alignment {
		case .leading: return ""
		case .center: return "<w:jc w:val=\"center\"/>"
		case .trailing: return "<w:jc w:val=\"right\"/>"
		case .justified: return "<w:jc w:val=\"both\"/>"
		}
	}

	private static func captionParagraph(_ caption: String) -> Paragraph {
		("<w:pStyle w:val=\"Caption\"/>", "<w:r>\(textContent(caption))</w:r>")
	}

	// MARK: Runs

	private func runXML(_ runs: [RescrivaRun], font: FontClass?, anchors: [UUID: [Int]]) -> String {
		var out = ""
		for run in runs {
			let ids = anchors[run.id] ?? []
			out += ids.map(Self.commentStart).joined()
			if !run.text.isEmpty {
				out += "<w:r>\(Self.runProperties(run, font: font))\(Self.textContent(run.text))</w:r>"
			}
			out += ids.map(Self.commentEnd).joined()
		}
		return out
	}

	/// `w:rPr` for a run, children in schema order. Open flags add nothing:
	/// the run renders as read.
	private static func runProperties(_ run: RescrivaRun, font: FontClass?) -> String {
		var props = ""
		if let name = DOCXRenderer.fontName(font) {
			props += "<w:rFonts w:ascii=\"\(name)\" w:hAnsi=\"\(name)\" w:cs=\"\(name)\"/>"
		}
		if run.bold { props += "<w:b/><w:bCs/>" }
		if run.italic { props += "<w:i/><w:iCs/>" }
		if run.strikethrough { props += "<w:strike/>" }
		if let color = run.color { props += "<w:color w:val=\"\(color.hex)\"/>" }
		if run.underline { props += "<w:u w:val=\"single\"/>" }
		if let highlight = run.highlight {
			props += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(highlight.hex)\"/>"
		}
		return props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
	}

	/// Run content: `w:t` for text, `w:br` for line breaks, `w:tab` for tabs.
	static func textContent(_ text: String) -> String {
		var out = ""
		var pending = ""
		func flush() {
			guard !pending.isEmpty else { return }
			out += "<w:t xml:space=\"preserve\">\(OOXML.escape(pending))</w:t>"
			pending = ""
		}
		for character in text {
			if character.isNewline {
				flush()
				out += "<w:br/>"
			} else if character == "\t" {
				flush()
				out += "<w:tab/>"
			} else {
				pending.append(character)
			}
		}
		flush()
		return out
	}

	// MARK: Lists

	private mutating func listParagraphs(style: ListStyle, items: [ListItem], font: FontClass?, anchors: [UUID: [Int]]) -> [Paragraph] {
		let numID: Int
		switch style {
		case .bullet:
			numID = 1
		case .ordered:
			orderedListCount += 1
			numID = 1 + orderedListCount
		case .checkbox:
			numID = 0
		}
		return items.map { item -> Paragraph in
			let level = RescrivaListCounter.clamp(item.level)
			let content = runXML(item.runs, font: font, anchors: anchors)
			guard style == .checkbox else {
				let numbering = "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numID)\"/></w:numPr>"
				return ("<w:pStyle w:val=\"ListParagraph\"/>" + numbering, content)
			}
			let indent = "<w:ind w:left=\"\(720 + 360 * level)\" w:hanging=\"360\"/>"
			return ("<w:pStyle w:val=\"ListParagraph\"/>" + indent, checkbox(checked: item.checked == true) + "<w:r><w:tab/></w:r>" + content)
		}
	}

	/// A Word 2010 checkbox content control. Readers without w14 support (it is
	/// mc:Ignorable) show the ☐/☒ glyph run inside `w:sdtContent`.
	private mutating func checkbox(checked: Bool) -> String {
		let id = nextControlID
		nextControlID += 1
		let glyph = checked ? "\u{2612}" : "\u{2610}"
		return "<w:sdt><w:sdtPr><w:id w:val=\"\(id)\"/><w14:checkbox>"
			+ "<w14:checked w14:val=\"\(checked ? 1 : 0)\"/>"
			+ "<w14:checkedState w14:val=\"2612\" w14:font=\"MS Gothic\"/>"
			+ "<w14:uncheckedState w14:val=\"2610\" w14:font=\"MS Gothic\"/>"
			+ "</w14:checkbox></w:sdtPr><w:sdtContent><w:r><w:rPr>"
			+ "<w:rFonts w:ascii=\"MS Gothic\" w:eastAsia=\"MS Gothic\" w:hAnsi=\"MS Gothic\" w:hint=\"eastAsia\"/>"
			+ "</w:rPr><w:t>\(glyph)</w:t></w:r></w:sdtContent></w:sdt>"
	}

	// MARK: Tables

	private func table(_ rows: [[TableCell]], font: FontClass?, anchors: [UUID: [Int]], lead: String, trail: String) -> String {
		let grid = RescrivaTableGrid(rows: rows)
		guard grid.columnCount > 0 else { return assemble([], lead: lead, trail: trail) }
		let columnWidth = textWidthTwips / grid.columnCount
		var cells: [[(properties: String, content: String)]] = []
		for (rowIndex, row) in grid.rows.enumerated() {
			var rowCells: [(properties: String, content: String)] = []
			var column = 0
			// Each pass advances `column` by at least one slot.
			while column < grid.columnCount {
				switch row[column] {
				case .origin(let cell, let rowSpan, let columnSpan):
					let merge = rowSpan > 1 ? "<w:vMerge w:val=\"restart\"/>" : ""
					rowCells.append((Self.cellProperties(columnWidth * columnSpan, columnSpan, merge), runXML(cell.runs, font: font, anchors: anchors)))
					column += columnSpan
				case .covered(let originRow, let originColumn) where originColumn == column && originRow < rowIndex:
					var span = 1
					if case .origin(_, _, let columnSpan) = grid.rows[originRow][originColumn] { span = columnSpan }
					rowCells.append((Self.cellProperties(columnWidth * span, span, "<w:vMerge/>"), ""))
					column += max(span, 1)
				case .covered:
					column += 1
				case .empty:
					rowCells.append((Self.cellProperties(columnWidth, 1, ""), ""))
					column += 1
				}
			}
			cells.append(rowCells)
		}
		if !cells.isEmpty, !cells[0].isEmpty { cells[0][0].content = lead + cells[0][0].content }
		if let lastRow = cells.indices.last, let lastCell = cells[lastRow].indices.last {
			cells[lastRow][lastCell].content += trail
		}
		let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\""
		var out = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(columnWidth * grid.columnCount)\" w:type=\"dxa\"/>"
			+ "<w:tblBorders><w:top \(border)/><w:left \(border)/><w:bottom \(border)/><w:right \(border)/>"
			+ "<w:insideH \(border)/><w:insideV \(border)/></w:tblBorders><w:tblLayout w:type=\"fixed\"/>"
			+ "<w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"1\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/>"
			+ "</w:tblPr><w:tblGrid>"
		out += String(repeating: "<w:gridCol w:w=\"\(columnWidth)\"/>", count: grid.columnCount) + "</w:tblGrid>"
		for row in cells {
			out += "<w:tr>"
			for cell in row {
				out += "<w:tc><w:tcPr>\(cell.properties)</w:tcPr><w:p>\(cell.content)</w:p></w:tc>"
			}
			out += "</w:tr>"
		}
		return out + "</w:tbl>"
	}

	private static func cellProperties(_ width: Int, _ span: Int, _ merge: String) -> String {
		"<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>" + (span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : "") + merge
	}

	// MARK: Equations

	private func equationParagraph(latex: String, linear: String, display: Bool) -> Paragraph {
		if let math = LaTeXToOMML.convert(latex) {
			return ("", display ? "<m:oMathPara>\(math)</m:oMathPara>" : math)
		}
		let text = linear.isEmpty ? latex : linear
		return (display ? "<w:jc w:val=\"center\"/>" : "", "<w:r><w:rPr><w:i/><w:iCs/></w:rPr>\(Self.textContent(text))</w:r>")
	}

	// MARK: Figures

	private mutating func figureParagraphs(assetID: String?, caption: String?, altText: String?, box: NormalizedBox?, page: RescrivaPage) -> [Paragraph] {
		var paragraphs: [Paragraph] = []
		let description = [altText, caption].compactMap { $0 }.first { !$0.isEmpty } ?? ""
		if let assetID, let data = options.assets[assetID], let info = RescrivaImageInfo(data: data) {
			let relID = mediaRelationship(assetID: assetID, data: data, info: info)
			let size = figureExtent(info, box: box, page: page)
			paragraphs.append(("<w:jc w:val=\"center\"/>", pictureRun(relID: relID, cx: size.cx, cy: size.cy, description: description)))
		} else {
			let label = description.isEmpty ? "[Figure]" : "[Figure: \(description)]"
			paragraphs.append(("<w:jc w:val=\"center\"/>", "<w:r><w:rPr><w:i/><w:iCs/></w:rPr>\(Self.textContent(label))</w:r>"))
		}
		if let caption, !caption.isEmpty {
			paragraphs.append(Self.captionParagraph(caption))
		}
		return paragraphs
	}

	private mutating func mediaRelationship(assetID: String, data: Data, info: RescrivaImageInfo) -> String {
		if let existing = mediaByAsset[assetID] { return existing }
		let name = "image\(media.count + 1).\(info.format.fileExtension)"
		media.append(("word/media/" + name, data))
		contentTypes.addDefault(extension: info.format.fileExtension, contentType: info.format.contentType)
		let relID = relationships.add(type: OOXML.Rel.image, target: "media/" + name)
		mediaByAsset[assetID] = relID
		return relID
	}

	/// Natural size: the figure's width on the scanned page when it has a box,
	/// else its pixel width at 96 dpi; fitted to 6in wide and 8in tall.
	private func figureExtent(_ info: RescrivaImageInfo, box: NormalizedBox?, page: RescrivaPage) -> (cx: Int, cy: Int) {
		let maxWidth = min(Self.maxFigureWidthInches, Double(textWidthTwips) / 1440)
		var width: Double
		if let box, box.width > 0, page.size.width > 0 {
			width = box.width * page.size.width / 72
		} else {
			width = Double(info.pixelWidth) / 96
		}
		width = min(max(width, 0.5), maxWidth)
		var height = width / info.aspect
		if height > Self.maxFigureHeightInches {
			height = Self.maxFigureHeightInches
			width = height * info.aspect
		}
		return (OOXML.emu(inches: width), OOXML.emu(inches: height))
	}

	private mutating func pictureRun(relID: String, cx: Int, cy: Int, description: String) -> String {
		let id = nextDrawingID
		nextDrawingID += 1
		let descr = OOXML.escape(description)
		return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
			+ "<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
			+ "<wp:docPr id=\"\(id)\" name=\"Picture \(id)\" descr=\"\(descr)\"/>"
			+ "<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
			+ "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
			+ "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(id)\" name=\"Picture \(id)\" descr=\"\(descr)\"/><pic:cNvPicPr/></pic:nvPicPr>"
			+ "<pic:blipFill><a:blip r:embed=\"\(relID)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
			+ "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
			+ "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>"
			+ "</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
	}

	// MARK: Diagrams

	/// The diagram as one inline `wpg:wgp` group: a `wps:wsp` per node (with its
	/// label in a text box) and a straight arrow per edge, clipped to the node
	/// outlines. Sized 6in wide by `Diagram.aspect` (at most 7in tall).
	private mutating func diagramRun(_ diagram: Diagram, font: FontClass?) -> String {
		let aspect = min(max(diagram.aspect.isFinite ? diagram.aspect : 1.6, 0.25), 6)
		var width = min(6.0, Double(textWidthTwips) / 1440) * OOXML.emuPerInch
		var height = width / aspect
		if height > 7 * OOXML.emuPerInch {
			height = 7 * OOXML.emuPerInch
			width = height * aspect
		}
		let groupWidth = Int(width.rounded())
		let groupHeight = Int(height.rounded())
		let groupID = nextDrawingID
		nextDrawingID += 1

		var frames: [String: Frame] = [:]
		var shapes = ""
		for node in diagram.nodes where frames[node.id] == nil {
			let frame = Self.frame(for: node, width: width, height: height)
			frames[node.id] = frame
			shapes += nodeShape(node, frame: frame, font: font)
		}
		for edge in diagram.edges {
			guard edge.from != edge.to, let from = frames[edge.from], let to = frames[edge.to] else { continue }
			guard let segment = RescrivaDiagramGeometry.clippedSegment(from: from, to: to, minimumLength: 2 * OOXML.emuPerPoint) else { continue }
			shapes += arrowShape(segment, direction: edge.direction)
			if let label = edge.label, !label.isEmpty {
				shapes += edgeLabelShape(label, beside: segment, font: font)
			}
		}
		let description = OOXML.escape([diagram.caption ?? "", BlockContent.diagram(diagram).plainText]
			.filter { !$0.isEmpty }.joined(separator: ": "))
		return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
			+ "<wp:extent cx=\"\(groupWidth)\" cy=\"\(groupHeight)\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
			+ "<wp:docPr id=\"\(groupID)\" name=\"Diagram \(groupID)\" descr=\"\(description)\"/><wp:cNvGraphicFramePr/>"
			+ "<a:graphic><a:graphicData uri=\"http://schemas.microsoft.com/office/word/2010/wordprocessingGroup\">"
			+ "<wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/>"
			+ "<a:ext cx=\"\(groupWidth)\" cy=\"\(groupHeight)\"/><a:chOff x=\"0\" y=\"0\"/>"
			+ "<a:chExt cx=\"\(groupWidth)\" cy=\"\(groupHeight)\"/></a:xfrm></wpg:grpSpPr>"
			+ shapes
			+ "</wpg:wgp></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
	}

	private static func frame(for node: Diagram.Node, width: Double, height: Double) -> Frame {
		let x = min(max(node.box.x, 0), 1)
		let y = min(max(node.box.y, 0), 1)
		let w = min(max(node.box.width, 0.02), 1 - min(x, 0.98))
		let h = min(max(node.box.height, 0.02), 1 - min(y, 0.98))
		return Frame(x: x * width, y: y * height, width: w * width, height: h * height, shape: node.shape)
	}

	private static func presetGeometry(_ shape: Diagram.Shape) -> String {
		switch shape {
		case .rectangle: return "rect"
		case .roundedRectangle: return "roundRect"
		case .ellipse: return "ellipse"
		case .diamond: return "diamond"
		case .parallelogram: return "parallelogram"
		}
	}

	/// A label font size (points) that fits `text` in a frame of `width` × `height` EMU.
	static func labelFontSize(_ text: String, width: Double, height: Double, preferred: Double, minimum: Double) -> Double {
		let longest = Double(max(text.split(whereSeparator: \.isNewline).map(\.count).max() ?? 1, 1))
		let lines = Double(max(text.split(whereSeparator: \.isNewline).count, 1))
		let widthPoints = width / OOXML.emuPerPoint
		let heightPoints = height / OOXML.emuPerPoint
		let byWidth = (widthPoints * 0.85) / (longest * 0.55)
		let byHeight = (heightPoints * 0.8) / (lines * 1.2)
		return min(max(min(preferred, byWidth, byHeight), minimum), preferred)
	}

	/// Black or white text, whichever reads better on `fill`.
	static func textColor(on fill: RGBColor?) -> String {
		guard let fill else { return ink }
		let luminance = 0.2126 * fill.red + 0.7152 * fill.green + 0.0722 * fill.blue
		return luminance < 0.45 ? "FFFFFF" : ink
	}

	private mutating func nodeShape(_ node: Diagram.Node, frame: Frame, font: FontClass?) -> String {
		let id = nextDrawingID
		nextDrawingID += 1
		let fill = node.fill.map { "<a:solidFill><a:srgbClr val=\"\($0.hex)\"/></a:solidFill>" } ?? "<a:noFill/>"
		let size = Self.labelFontSize(node.label, width: frame.width, height: frame.height, preferred: 11, minimum: 6)
		return "<wps:wsp><wps:cNvPr id=\"\(id)\" name=\"Shape \(id)\"/><wps:cNvSpPr/><wps:spPr>"
			+ Self.xfrm(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
			+ "<a:prstGeom prst=\"\(Self.presetGeometry(node.shape))\"><a:avLst/></a:prstGeom>\(fill)"
			+ "<a:ln w=\"19050\"><a:solidFill><a:srgbClr val=\"\(node.stroke.hex)\"/></a:solidFill></a:ln></wps:spPr>"
			+ Self.textBox(node.label, size: size, color: Self.textColor(on: node.fill), font: font)
			+ "<wps:bodyPr rot=\"0\" vert=\"horz\" wrap=\"square\" lIns=\"45720\" tIns=\"18288\" rIns=\"45720\" bIns=\"18288\""
			+ " anchor=\"ctr\" anchorCtr=\"0\"><a:noAutofit/></wps:bodyPr></wps:wsp>"
	}

	private mutating func arrowShape(_ segment: RescrivaDiagramGeometry.Segment, direction: Diagram.Direction) -> String {
		let id = nextDrawingID
		nextDrawingID += 1
		var flips = ""
		if segment.x2 < segment.x1 { flips += " flipH=\"1\"" }
		if segment.y2 < segment.y1 { flips += " flipV=\"1\"" }
		let x = Int(min(segment.x1, segment.x2).rounded())
		let y = Int(min(segment.y1, segment.y2).rounded())
		let cx = Int(abs(segment.x2 - segment.x1).rounded())
		let cy = Int(abs(segment.y2 - segment.y1).rounded())
		return "<wps:wsp><wps:cNvPr id=\"\(id)\" name=\"Arrow \(id)\"/><wps:cNvCnPr/><wps:spPr>"
			+ "<a:xfrm\(flips)><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
			+ "<a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom>"
			+ "<a:ln w=\"15875\"><a:solidFill><a:srgbClr val=\"\(Self.ink)\"/></a:solidFill>"
			+ "\(direction.drawingMLLineEnds)</a:ln></wps:spPr><wps:bodyPr/></wps:wsp>"
	}

	private mutating func edgeLabelShape(_ label: String, beside segment: RescrivaDiagramGeometry.Segment, font: FontClass?) -> String {
		let id = nextDrawingID
		nextDrawingID += 1
		let width = min(1.6, 0.15 + 0.075 * Double(label.count)) * OOXML.emuPerInch
		let height = 0.24 * OOXML.emuPerInch
		let center = RescrivaDiagramGeometry.labelCenter(for: segment, width: width, height: height, gap: 2 * OOXML.emuPerPoint)
		return "<wps:wsp><wps:cNvPr id=\"\(id)\" name=\"Label \(id)\"/><wps:cNvSpPr txBox=\"1\"/><wps:spPr>"
			+ Self.xfrm(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
			+ "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></wps:spPr>"
			+ Self.textBox(label, size: 8, color: Self.ink, font: font)
			+ "<wps:bodyPr rot=\"0\" vert=\"horz\" wrap=\"square\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\""
			+ " anchor=\"ctr\" anchorCtr=\"0\"><a:noAutofit/></wps:bodyPr></wps:wsp>"
	}

	private static func xfrm(x: Double, y: Double, width: Double, height: Double) -> String {
		"<a:xfrm><a:off x=\"\(Int(max(x, 0).rounded()))\" y=\"\(Int(max(y, 0).rounded()))\"/>"
			+ "<a:ext cx=\"\(Int(width.rounded()))\" cy=\"\(Int(height.rounded()))\"/></a:xfrm>"
	}

	private static func textBox(_ text: String, size: Double, color: String, font: FontClass?) -> String {
		let halfPoints = Int((size * 2).rounded())
		let fontXML = DOCXRenderer.fontName(font).map { "<w:rFonts w:ascii=\"\($0)\" w:hAnsi=\"\($0)\" w:cs=\"\($0)\"/>" } ?? ""
		return "<wps:txbx><w:txbxContent><w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>"
			+ "<w:jc w:val=\"center\"/></w:pPr><w:r><w:rPr>\(fontXML)<w:color w:val=\"\(color)\"/>"
			+ "<w:sz w:val=\"\(halfPoints)\"/><w:szCs w:val=\"\(halfPoints)\"/></w:rPr>"
			+ textContent(text) + "</w:r></w:p></w:txbxContent></wps:txbx>"
	}
}

/// The fixed Word parts: styles, settings, font table and the numbering
/// definitions (one bullet and one decimal abstract list).
private enum DOCXParts {
	private static let wordNamespace = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""

	static let styles: String = {
		func heading(_ level: Int, size: Int, italic: Bool) -> String {
			"<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/>"
				+ "<w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/>"
				+ "<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"\(level == 1 ? 360 : 240)\" w:after=\"120\"/>"
				+ "<w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr>"
				+ "<w:rPr><w:b/><w:bCs/>\(italic ? "<w:i/><w:iCs/>" : "")<w:color w:val=\"1D2233\"/>"
				+ "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
		}
		let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\""
		return OOXML.declaration
			+ "<w:styles \(wordNamespace)><w:docDefaults><w:rPrDefault><w:rPr>"
			+ "<w:rFonts w:ascii=\"Calibri\" w:eastAsia=\"Calibri\" w:hAnsi=\"Calibri\" w:cs=\"Calibri\"/>"
			+ "<w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/><w:lang w:val=\"en-US\" w:eastAsia=\"en-US\" w:bidi=\"ar-SA\"/>"
			+ "</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"259\" w:lineRule=\"auto\"/>"
			+ "</w:pPr></w:pPrDefault></w:docDefaults>"
			+ "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
			+ "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\"><w:name w:val=\"Default Paragraph Font\"/>"
			+ "<w:uiPriority w:val=\"1\"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"
			+ "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/>"
			+ "<w:uiPriority w:val=\"99\"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/>"
			+ "<w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/>"
			+ "<w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
			+ "<w:style w:type=\"numbering\" w:default=\"1\" w:styleId=\"NoList\"><w:name w:val=\"No List\"/>"
			+ "<w:uiPriority w:val=\"99\"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"
			+ heading(1, size: 36, italic: false) + heading(2, size: 30, italic: false)
			+ heading(3, size: 26, italic: false) + heading(4, size: 22, italic: true)
			+ "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/>"
			+ "<w:basedOn w:val=\"Normal\"/><w:uiPriority w:val=\"34\"/><w:qFormat/>"
			+ "<w:pPr><w:ind w:left=\"720\"/><w:contextualSpacing/></w:pPr></w:style>"
			+ "<w:style w:type=\"paragraph\" w:styleId=\"Caption\"><w:name w:val=\"caption\"/><w:basedOn w:val=\"Normal\"/>"
			+ "<w:next w:val=\"Normal\"/><w:uiPriority w:val=\"35\"/><w:unhideWhenUsed/><w:qFormat/>"
			+ "<w:pPr><w:spacing w:after=\"200\" w:line=\"240\" w:lineRule=\"auto\"/><w:jc w:val=\"center\"/></w:pPr>"
			+ "<w:rPr><w:i/><w:iCs/><w:color w:val=\"5F6B76\"/><w:sz w:val=\"18\"/><w:szCs w:val=\"18\"/></w:rPr></w:style>"
			+ "<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:basedOn w:val=\"TableNormal\"/>"
			+ "<w:uiPriority w:val=\"39\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr>"
			+ "<w:tblPr><w:tblBorders><w:top \(border)/><w:left \(border)/><w:bottom \(border)/><w:right \(border)/>"
			+ "<w:insideH \(border)/><w:insideV \(border)/></w:tblBorders></w:tblPr></w:style>"
			+ "<w:style w:type=\"paragraph\" w:styleId=\"CommentText\"><w:name w:val=\"annotation text\"/>"
			+ "<w:basedOn w:val=\"Normal\"/><w:uiPriority w:val=\"99\"/><w:unhideWhenUsed/>"
			+ "<w:pPr><w:spacing w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:rPr><w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/></w:rPr></w:style>"
			+ "<w:style w:type=\"character\" w:styleId=\"CommentReference\"><w:name w:val=\"annotation reference\"/>"
			+ "<w:basedOn w:val=\"DefaultParagraphFont\"/><w:uiPriority w:val=\"99\"/><w:semiHidden/><w:unhideWhenUsed/>"
			+ "<w:rPr><w:sz w:val=\"16\"/><w:szCs w:val=\"16\"/></w:rPr></w:style>"
			+ "</w:styles>"
	}()

	static let settings = OOXML.declaration
		+ "<w:settings \(wordNamespace)><w:zoom w:percent=\"100\"/><w:defaultTabStop w:val=\"720\"/>"
		+ "<w:characterSpacingControl w:val=\"doNotCompress\"/><w:compat>"
		+ "<w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/>"
		+ "</w:compat></w:settings>"

	static let fontTable: String = {
		func font(_ name: String, alt: String?, family: String, pitch: String, charset: String = "00") -> String {
			"<w:font w:name=\"\(name)\">" + (alt.map { "<w:altName w:val=\"\($0)\"/>" } ?? "")
				+ "<w:charset w:val=\"\(charset)\"/><w:family w:val=\"\(family)\"/><w:pitch w:val=\"\(pitch)\"/></w:font>"
		}
		return OOXML.declaration + "<w:fonts \(wordNamespace)>"
			+ font("Calibri", alt: nil, family: "swiss", pitch: "variable")
			+ font("Georgia", alt: nil, family: "roman", pitch: "variable")
			+ font("Helvetica Neue", alt: "Arial", family: "swiss", pitch: "variable")
			+ font("Courier New", alt: nil, family: "modern", pitch: "fixed")
			+ font("Cambria Math", alt: nil, family: "roman", pitch: "variable")
			+ font("MS Gothic", alt: "Segoe UI Symbol", family: "modern", pitch: "fixed", charset: "80")
			+ "</w:fonts>"
	}()

	/// Numbering: abstract list 0 is bullets (num 1), abstract list 1 is
	/// decimal → letter → roman; each ordered list gets its own num (2, 3, …)
	/// restarting at 1.
	static func numbering(orderedLists: Int) -> String {
		let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
		let formats = ["decimal", "lowerLetter", "lowerRoman"]
		var out = OOXML.declaration + "<w:numbering \(wordNamespace)>"
		out += "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
		for level in 0...RescrivaListCounter.maxLevel {
			out += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/>"
				+ "<w:lvlText w:val=\"\(bullets[level % 3])\"/><w:lvlJc w:val=\"left\"/>"
				+ "<w:pPr><w:ind w:left=\"\(720 + 360 * level)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
		}
		out += "</w:abstractNum><w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
		for level in 0...RescrivaListCounter.maxLevel {
			out += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(formats[level % 3])\"/>"
				+ "<w:lvlText w:val=\"%\(level + 1).\"/><w:lvlJc w:val=\"left\"/>"
				+ "<w:pPr><w:ind w:left=\"\(720 + 360 * level)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
		}
		out += "</w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
		for index in 0..<max(orderedLists, 0) {
			out += "<w:num w:numId=\"\(index + 2)\"><w:abstractNumId w:val=\"1\"/>"
				+ "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
		}
		return out + "</w:numbering>"
	}
}
