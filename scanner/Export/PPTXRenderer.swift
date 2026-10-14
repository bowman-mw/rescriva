//
//  PPTXRenderer.swift
//  Rescriva (fork of Open Scanner)
//
//  Renders a RescrivaDocument as a PowerPoint package, one slide per page.
//  Slides are positioned, so blocks with a box are placed at that box scaled
//  onto the slide; blocks without one are stacked in the content area. The
//  first heading on a slide goes into the layout's title placeholder so
//  outline view and accessibility work, the page palette becomes the theme's
//  accent colours, diagrams become native shapes joined by connectors that
//  follow them, an equation the OMML converter can't handle becomes its
//  typeset picture (`EquationPictures`) with the LaTeX as alt text, and notes
//  become speaker notes.
//

import Foundation

/// Renders a `RescrivaDocument` to `.pptx` bytes.
///
/// Slide size is 16:9 (12 192 000 × 6 858 000 EMU) unless the first page is
/// landscape and nearer 4:3, then 9 144 000 × 6 858 000.
enum PPTXRenderer {
	static func render(_ document: RescrivaDocument, options: RenderOptions = RenderOptions()) throws -> Data {
		var writer = PPTXWriter(document: document, options: options)
		return try writer.package()
	}

	/// The calm default palette used when a page has no sampled colours —
	/// Rescriva's inks on paper: indigo, blue pencil, vermilion, highlighter,
	/// graphite, ink wash.
	static let defaultAccents = ["2B3B8C", "5A7BD0", "CF4326", "F6C823", "676C7A", "E3E7F4"]
}

/// A rectangle in EMU.
private struct SlideRect {
	var x: Double
	var y: Double
	var width: Double
	var height: Double

	var maxY: Double { y + height }
	var midX: Double { x + width / 2 }
	var midY: Double { y + height / 2 }

	/// `a:off` + `a:ext` children.
	var offsetAndExtent: String {
		"<a:off x=\"\(Int(x.rounded()))\" y=\"\(Int(y.rounded()))\"/>"
			+ "<a:ext cx=\"\(Int(max(width, 0).rounded()))\" cy=\"\(Int(max(height, 0).rounded()))\"/>"
	}

	/// The largest rect of `aspect` (width / height) centred inside this one.
	func fitting(aspect: Double) -> SlideRect {
		guard aspect > 0, aspect.isFinite, width > 0, height > 0 else { return self }
		if width / height > aspect {
			let fitted = height * aspect
			return SlideRect(x: x + (width - fitted) / 2, y: y, width: fitted, height: height)
		}
		let fitted = width / aspect
		return SlideRect(x: x, y: y + (height - fitted) / 2, width: width, height: fitted)
	}
}

/// Rough text measurement for sizing text boxes without a layout engine:
/// average glyph width ≈ 0.5 em, line height 1.2 em.
private enum TextMetrics {
	static func lineCount(_ text: String, widthPoints: Double, size: Double) -> Int {
		guard widthPoints > 0, size > 0 else { return 1 }
		let perLine = max(Int(widthPoints / (size * 0.5)), 1)
		return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).reduce(0) { total, line in
			total + max((line.count + perLine - 1) / perLine, 1)
		}
	}

	/// Text height in EMU, including the default top/bottom insets.
	static func height(_ text: String, widthEMU: Double, size: Double) -> Double {
		let lines = lineCount(text, widthPoints: (widthEMU - 182_880) / OOXML.emuPerPoint, size: size)
		return Double(lines) * size * 1.2 * OOXML.emuPerPoint + 91_440
	}

	/// The largest size ≤ `preferred` (and ≥ `minimum`) whose text fits `rect`.
	static func fittedSize(_ text: String, in rect: SlideRect, preferred: Double, minimum: Double = 8) -> Double {
		var size = preferred
		// At most (preferred - minimum) / 1 + 1 iterations.
		while size > minimum, height(text, widthEMU: rect.width, size: size) > rect.height {
			size -= 1
		}
		return max(size, minimum)
	}
}

/// One slide's shapes and relationships while it is being built.
private struct SlideBuilder {
	var shapes = ""
	var relationships = OOXML.Relationships()
	var imageRelationships: [String: String] = [:]
	private var nextShapeID = 2

	/// A fresh shape id (1 is the shape tree itself).
	mutating func shapeID() -> Int {
		defer { nextShapeID += 1 }
		return nextShapeID
	}
}

/// Accumulates the parts of one PowerPoint package.
private struct PPTXWriter {
	let document: RescrivaDocument
	let options: RenderOptions
	let slideWidth: Double
	let slideHeight: Double
	let accents: [String]

	private var contentTypes = OOXML.ContentTypes()
	private var media: [(path: String, data: Data)] = []
	private var mediaByAsset: [String: (name: String, info: RescrivaImageInfo)] = [:]

	static let ink = "1D2233"
	static let tableStyleID = "{5940675A-B579-460E-94D1-54222C63F5DA}"
	static let margin = 0.06875
	static let titleTop = 365_125.0
	static let titleHeight = 1_325_563.0
	static let bodyTop = 1_825_625.0
	static let bottomMargin = 457_200.0
	static let blockGap = 109_728.0

	init(document: RescrivaDocument, options: RenderOptions) {
		self.document = document
		self.options = options
		slideHeight = 6_858_000
		if let first = document.pages.first?.size, first.isLandscape, first.height > 0 {
			let aspect = first.width / first.height
			slideWidth = abs(aspect - 4.0 / 3.0) < abs(aspect - 16.0 / 9.0) ? 9_144_000 : 12_192_000
		} else {
			slideWidth = 12_192_000
		}
		let sampled = document.pages.first { !$0.palette.isEmpty }?.palette.map(\.hex) ?? []
		accents = Array(sampled.prefix(6)) + PPTXRenderer.defaultAccents.dropFirst(min(sampled.count, 6))
	}

	// MARK: Package

	mutating func package() throws -> Data {
		var slides: [(xml: String, rels: String, notes: String?)] = []
		// An empty document still gets one blank slide: a zero-slide deck is
		// valid, but Quick Look (and so the share sheet preview) hangs on it.
		let pages = document.pages.isEmpty ? [RescrivaPage()] : document.pages
		for (index, page) in pages.enumerated() {
			slides.append(renderSlide(page, index: index))
		}
		let notesCount = slides.filter { $0.notes != nil }.count
		let hasNotes = notesCount > 0

		var presentationRels = OOXML.Relationships()
		presentationRels.add(type: OOXML.Rel.slideMaster, target: "slideMasters/slideMaster1.xml")
		var slideIDs = ""
		for index in slides.indices {
			let relID = presentationRels.add(type: OOXML.Rel.slide, target: "slides/slide\(index + 1).xml")
			slideIDs += "<p:sldId id=\"\(256 + index)\" r:id=\"\(relID)\"/>"
		}
		let notesMasterRel = hasNotes ? presentationRels.add(type: OOXML.Rel.notesMaster, target: "notesMasters/notesMaster1.xml") : nil
		presentationRels.add(type: OOXML.Rel.presProps, target: "presProps.xml")
		presentationRels.add(type: OOXML.Rel.viewProps, target: "viewProps.xml")
		presentationRels.add(type: OOXML.Rel.theme, target: "theme/theme1.xml")
		presentationRels.add(type: OOXML.Rel.tableStyles, target: "tableStyles.xml")

		registerContentTypes(slideCount: slides.count, notesSlides: slides.indices.filter { slides[$0].notes != nil })

		var archive = ZipArchive()
		try archive.add(ZipArchive.contentTypesPath, text: contentTypes.xml)
		try archive.add("_rels/.rels", text: OOXML.packageRelationships(mainPart: "ppt/presentation.xml"))
		try archive.add("docProps/core.xml", text: OOXML.coreProperties(title: document.title, author: options.author, date: Date()))
		try archive.add("docProps/app.xml", text: OOXML.appProperties(extra: "<Slides>\(slides.count)</Slides><Notes>\(notesCount)</Notes>"))
		try archive.add("ppt/presentation.xml", text: presentationXML(slideIDs: slideIDs, notesMasterRel: notesMasterRel))
		try archive.add("ppt/_rels/presentation.xml.rels", text: presentationRels.xml)
		try archive.add("ppt/presProps.xml", text: PPTXParts.presProps)
		try archive.add("ppt/viewProps.xml", text: PPTXParts.viewProps)
		try archive.add("ppt/tableStyles.xml", text: PPTXParts.tableStyles(defaultStyle: Self.tableStyleID))
		try archive.add("ppt/theme/theme1.xml", text: PPTXParts.theme(name: "Rescriva", accents: accents))
		try archive.add("ppt/slideMasters/slideMaster1.xml", text: PPTXParts.slideMaster(width: slideWidth))
		try archive.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", text: PPTXParts.masterRelationships)
		try archive.add("ppt/slideLayouts/slideLayout1.xml", text: PPTXParts.titleAndContentLayout)
		try archive.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", text: PPTXParts.layoutRelationships)
		try archive.add("ppt/slideLayouts/slideLayout2.xml", text: PPTXParts.blankLayout)
		try archive.add("ppt/slideLayouts/_rels/slideLayout2.xml.rels", text: PPTXParts.layoutRelationships)
		if hasNotes {
			try archive.add("ppt/notesMasters/notesMaster1.xml", text: PPTXParts.notesMaster)
			try archive.add("ppt/notesMasters/_rels/notesMaster1.xml.rels", text: PPTXParts.notesMasterRelationships)
			try archive.add("ppt/theme/theme2.xml", text: PPTXParts.theme(name: "Rescriva Notes", accents: accents))
		}
		for (index, slide) in slides.enumerated() {
			try archive.add("ppt/slides/slide\(index + 1).xml", text: slide.xml)
			try archive.add("ppt/slides/_rels/slide\(index + 1).xml.rels", text: slide.rels)
			if let notes = slide.notes {
				try archive.add("ppt/notesSlides/notesSlide\(index + 1).xml", text: notes)
				var rels = OOXML.Relationships()
				rels.add(type: OOXML.Rel.notesMaster, target: "../notesMasters/notesMaster1.xml")
				rels.add(type: OOXML.Rel.slide, target: "../slides/slide\(index + 1).xml")
				try archive.add("ppt/notesSlides/_rels/notesSlide\(index + 1).xml.rels", text: rels.xml)
			}
		}
		for item in media {
			try archive.add(item.path, data: item.data)
		}
		return try archive.archiveData()
	}

	private mutating func registerContentTypes(slideCount: Int, notesSlides: [Int]) {
		contentTypes.addOverride("ppt/presentation.xml", contentType: OOXML.ContentType.presentation)
		contentTypes.addOverride("ppt/presProps.xml", contentType: OOXML.ContentType.presProps)
		contentTypes.addOverride("ppt/viewProps.xml", contentType: OOXML.ContentType.viewProps)
		contentTypes.addOverride("ppt/tableStyles.xml", contentType: OOXML.ContentType.tableStyles)
		contentTypes.addOverride("ppt/theme/theme1.xml", contentType: OOXML.ContentType.theme)
		contentTypes.addOverride("ppt/slideMasters/slideMaster1.xml", contentType: OOXML.ContentType.slideMaster)
		contentTypes.addOverride("ppt/slideLayouts/slideLayout1.xml", contentType: OOXML.ContentType.slideLayout)
		contentTypes.addOverride("ppt/slideLayouts/slideLayout2.xml", contentType: OOXML.ContentType.slideLayout)
		for index in 0..<slideCount {
			contentTypes.addOverride("ppt/slides/slide\(index + 1).xml", contentType: OOXML.ContentType.slide)
		}
		if !notesSlides.isEmpty {
			contentTypes.addOverride("ppt/notesMasters/notesMaster1.xml", contentType: OOXML.ContentType.notesMaster)
			contentTypes.addOverride("ppt/theme/theme2.xml", contentType: OOXML.ContentType.theme)
		}
		for index in notesSlides {
			contentTypes.addOverride("ppt/notesSlides/notesSlide\(index + 1).xml", contentType: OOXML.ContentType.notesSlide)
		}
		contentTypes.addOverride("docProps/core.xml", contentType: OOXML.ContentType.coreProperties)
		contentTypes.addOverride("docProps/app.xml", contentType: OOXML.ContentType.extendedProperties)
	}

	private func presentationXML(slideIDs: String, notesMasterRel: String?) -> String {
		var out = OOXML.declaration + "<p:presentation \(PPTXParts.namespaces) saveSubsetFonts=\"1\">"
			+ "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
		if let notesMasterRel {
			out += "<p:notesMasterIdLst><p:notesMasterId r:id=\"\(notesMasterRel)\"/></p:notesMasterIdLst>"
		}
		if !slideIDs.isEmpty { out += "<p:sldIdLst>\(slideIDs)</p:sldIdLst>" }
		let sizeType = slideWidth < 10_000_000 ? " type=\"screen4x3\"" : ""
		out += "<p:sldSz cx=\"\(Int(slideWidth))\" cy=\"\(Int(slideHeight))\"\(sizeType)/>"
			+ "<p:notesSz cx=\"6858000\" cy=\"9144000\"/>"
			+ "<p:defaultTextStyle><a:defPPr><a:defRPr lang=\"en-US\"/></a:defPPr>\(PPTXParts.textLevels)</p:defaultTextStyle>"
			+ "</p:presentation>"
		return out
	}

	// MARK: Slides

	private mutating func renderSlide(_ page: RescrivaPage, index: Int) -> (xml: String, rels: String, notes: String?) {
		var slide = SlideBuilder()
		let titleIndex = page.blocks.firstIndex { block in
			if case .heading = block.content { return true }
			return false
		}
		slide.relationships.add(type: OOXML.Rel.slideLayout, target: titleIndex == nil
			? "../slideLayouts/slideLayout2.xml" : "../slideLayouts/slideLayout1.xml")
		let textColor = page.background.map { $0.isDark ? "FFFFFF" : nil } ?? nil
		let frame = pageFrame(page)
		var context = BlockContext(defaultColor: textColor)

		if let titleIndex {
			addTitle(page.blocks[titleIndex], frame: frame, slide: &slide, context: context)
		}
		let titleHasBox = titleIndex.map { page.blocks[$0].box != nil } ?? true
		var boxedBottom: Double = 0
		for (blockIndex, block) in page.blocks.enumerated() where blockIndex != titleIndex {
			guard let box = block.box else { continue }
			let rect = Self.place(box, in: frame)
			boxedBottom = max(boxedBottom, rect.maxY)
			context.fit = true
			addBlock(block, rect: rect, scale: 1, slide: &slide, context: context)
		}
		let stacked = page.blocks.enumerated().filter { $0.offset != titleIndex && $0.element.box == nil }.map(\.element)
		if !stacked.isEmpty {
			var top = titleHasBox ? Self.titleTop : Self.bodyTop
			let bottom = slideHeight - Self.bottomMargin
			if boxedBottom > 0, bottom - boxedBottom >= slideHeight * 0.25 {
				top = max(top, boxedBottom + Self.blockGap)
			}
			let area = SlideRect(x: slideWidth * Self.margin, y: top, width: slideWidth * (1 - 2 * Self.margin), height: bottom - top)
			context.fit = false
			stack(stacked, in: area, slide: &slide, context: context)
		}

		let background = page.background.map {
			"<p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"\($0.hex)\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>"
		} ?? ""
		let xml = OOXML.declaration + "<p:sld \(PPTXParts.namespaces)><p:cSld>\(background)<p:spTree>"
			+ PPTXParts.groupProperties + slide.shapes
			+ "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"

		var notesXML: String?
		if options.includeNotes, let text = speakerNotes(pageIndex: index) {
			slide.relationships.add(type: OOXML.Rel.notesSlide, target: "../notesSlides/notesSlide\(index + 1).xml")
			notesXML = PPTXParts.notesSlide(paragraphs: text)
		}
		return (xml, slide.relationships.xml, notesXML)
	}

	/// Page notes then block notes for one page, one paragraph each.
	private func speakerNotes(pageIndex: Int) -> [String]? {
		let entries = RescrivaNoteEntry.all(in: document).filter { $0.pageIndex == pageIndex }
		guard !entries.isEmpty else { return nil }
		return entries.map { entry in
			guard let anchor = entry.anchorText?.trimmingCharacters(in: .whitespacesAndNewlines), !anchor.isEmpty else {
				return entry.note.text
			}
			return "On \u{201C}\(anchor)\u{201D}: \(entry.note.text)"
		}
	}

	/// Where the page lands on the slide: fitted (aspect kept) and centred, so
	/// a portrait page is scaled to the slide's height.
	private func pageFrame(_ page: RescrivaPage) -> SlideRect {
		let slide = SlideRect(x: 0, y: 0, width: slideWidth, height: slideHeight)
		guard page.size.width > 0, page.size.height > 0 else { return slide }
		return slide.fitting(aspect: page.size.width / page.size.height)
	}

	private static func place(_ box: NormalizedBox, in frame: SlideRect) -> SlideRect {
		let x = min(max(box.x, 0), 1)
		let y = min(max(box.y, 0), 1)
		let width = min(max(box.width, 0.01), 1 - min(x, 0.99))
		let height = min(max(box.height, 0.01), 1 - min(y, 0.99))
		return SlideRect(x: frame.x + x * frame.width, y: frame.y + y * frame.height,
						 width: width * frame.width, height: height * frame.height)
	}

	/// Shared per-slide rendering inputs.
	private struct BlockContext {
		/// Text colour for runs without their own (white on dark backgrounds).
		let defaultColor: String?
		/// Fit text to its box (boxed blocks) rather than use scaled defaults.
		var fit = false
	}

	// MARK: Title and stacking

	private func addTitle(_ block: RescrivaBlock, frame: SlideRect, slide: inout SlideBuilder, context: BlockContext) {
		guard case .heading(_, let runs) = block.content else { return }
		let id = slide.shapeID()
		var properties = "<p:spPr/>"
		var size: Double?
		if let box = block.box {
			let rect = Self.place(box, in: frame)
			properties = "<p:spPr><a:xfrm>\(rect.offsetAndExtent)</a:xfrm></p:spPr>"
			size = TextMetrics.fittedSize(runs.plainText, in: rect, preferred: 40, minimum: 12)
		}
		let paragraph = Self.paragraph(runs, properties: "", size: size, font: block.fontClass, color: context.defaultColor)
		slide.shapes += "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Title \(id)\"/>"
			+ "<p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr>"
			+ properties + "<p:txBody><a:bodyPr/><a:lstStyle/>\(paragraph)</p:txBody></p:sp>"
	}

	/// Stacks blocks top to bottom in `area`, shrinking everything evenly when
	/// the estimated total would overflow.
	private mutating func stack(_ blocks: [RescrivaBlock], in area: SlideRect, slide: inout SlideBuilder, context: BlockContext) {
		let heights = blocks.map { estimatedHeight($0, width: area.width, available: area.height) }
		let total = heights.reduce(0, +) + Self.blockGap * Double(max(blocks.count - 1, 0))
		let scale = total > area.height && total > 0 ? max(area.height / total, 0.35) : 1
		var y = area.y
		for (block, height) in zip(blocks, heights) {
			let rect = SlideRect(x: area.x, y: y, width: area.width, height: height * scale)
			addBlock(block, rect: rect, scale: scale, slide: &slide, context: context)
			y += rect.height + Self.blockGap * scale
		}
	}

	private static func preferredSize(_ content: BlockContent) -> Double {
		switch content {
		case .heading(let level, _): return [32, 28, 24, 20][min(max(level, 1), 4) - 1]
		case .equation(_, _, let display): return display ? 24 : 20
		case .table: return 14
		case .paragraph, .list, .figure, .diagram: return 18
		}
	}

	private func estimatedHeight(_ block: RescrivaBlock, width: Double, available: Double) -> Double {
		let size = Self.preferredSize(block.content)
		switch block.content {
		case .heading, .paragraph, .list:
			return TextMetrics.height(PlainTextRenderer.text(for: block.content), widthEMU: width, size: size)
		case .equation(let latex, _, _):
			if let info = equationPicture(for: latex)?.info {
				let natural = EquationPictures.extent(of: info, maxWidthInches: width / OOXML.emuPerInch)
				return min(Double(natural.cy), available * 0.5) + 91_440
			}
			return TextMetrics.height(PlainTextRenderer.text(for: block.content), widthEMU: width, size: size)
		case .table(let rows):
			return Double(max(rows.count, 1)) * (size * 1.2 * OOXML.emuPerPoint + 91_440)
		case .figure(let assetID, let caption, _):
			let aspect = assetID.flatMap { options.assets[$0] }.flatMap(RescrivaImageInfo.init(data:))?.aspect ?? (4.0 / 3.0)
			let captionHeight = (caption?.isEmpty ?? true) ? 0 : 320_040.0
			return min(width / aspect, available * 0.65) + captionHeight
		case .diagram(let diagram):
			let aspect = min(max(diagram.aspect.isFinite ? diagram.aspect : 1.6, 0.25), 6)
			let captionHeight = (diagram.caption?.isEmpty ?? true) ? 0 : 320_040.0
			return min(width / aspect, available * 0.8) + captionHeight
		}
	}

	// MARK: Blocks

	private mutating func addBlock(_ block: RescrivaBlock, rect: SlideRect, scale: Double, slide: inout SlideBuilder, context: BlockContext) {
		let preferred = Self.preferredSize(block.content)
		func size(for text: String) -> Double {
			context.fit
				? TextMetrics.fittedSize(text, in: rect, preferred: preferred)
				: max(preferred * scale, 9)
		}
		let font = block.fontClass
		let color = context.defaultColor
		switch block.content {
		case .heading(_, let runs):
			let bold = runs.map { run -> RescrivaRun in
				var copy = run
				copy.bold = true
				return copy
			}
			let paragraph = Self.paragraph(bold, properties: "", size: size(for: runs.plainText), font: font, color: color)
			slide.shapes += Self.textBox(id: slide.shapeID(), rect: rect, paragraphs: paragraph)
		case .paragraph(let runs, let alignment):
			let properties = Self.alignment(alignment).map { "<a:pPr algn=\"\($0)\"/>" } ?? ""
			let paragraph = Self.paragraph(runs, properties: properties, size: size(for: runs.plainText), font: font, color: color)
			slide.shapes += Self.textBox(id: slide.shapeID(), rect: rect, paragraphs: paragraph)
		case .list(let style, let items):
			let paragraphs = Self.listParagraphs(style: style, items: items, size: size(for: PlainTextRenderer.text(for: block.content)), font: font, color: color)
			slide.shapes += Self.textBox(id: slide.shapeID(), rect: rect, paragraphs: paragraphs)
		case .table(let rows):
			let rowCount = Double(max(rows.count, 1))
			let cellSize = context.fit ? min(max(rect.height / rowCount / OOXML.emuPerPoint * 0.5, 8), 14) : max(14 * scale, 9)
			slide.shapes += table(rows, rect: rect, size: cellSize, font: font, bodyColor: color, id: slide.shapeID())
		case .equation(let latex, let linear, let display):
			if let picture = equationPicture(for: latex) {
				addEquationPicture(picture, latex: latex, rect: rect, display: display, slide: &slide, context: context)
				return
			}
			let text = linear.isEmpty ? latex : linear
			let run = RescrivaRun(text: text, italic: true)
			let properties = display ? "<a:pPr algn=\"ctr\"/>" : ""
			let paragraph = Self.paragraph([run], properties: properties, size: size(for: text), font: font, color: color)
			slide.shapes += Self.textBox(id: slide.shapeID(), rect: rect, paragraphs: paragraph)
		case .figure(let assetID, let caption, let altText):
			addFigure(assetID: assetID, caption: caption, altText: altText, rect: rect, scale: scale, slide: &slide, context: context)
		case .diagram(let diagram):
			addDiagram(diagram, rect: rect, scale: scale, font: font, slide: &slide, context: context)
		}
	}

	private static func alignment(_ alignment: TextAlignment) -> String? {
		switch alignment {
		case .leading: return nil
		case .center: return "ctr"
		case .trailing: return "r"
		case .justified: return "just"
		}
	}

	private static func textBox(id: Int, rect: SlideRect, paragraphs: String, anchor: String = "t", name: String = "TextBox") -> String {
		"<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name) \(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr>"
			+ "<p:spPr><a:xfrm>\(rect.offsetAndExtent)</a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"
			+ "<p:txBody><a:bodyPr wrap=\"square\" lIns=\"91440\" tIns=\"45720\" rIns=\"91440\" bIns=\"45720\" rtlCol=\"0\" anchor=\"\(anchor)\">"
			+ "<a:normAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>"
	}

	// MARK: Runs and paragraphs

	/// An `a:p`. `properties` is a complete `a:pPr` element or empty; `prefix`
	/// is literal text put before the runs (checkbox glyphs).
	private static func paragraph(_ runs: [RescrivaRun], properties: String, size: Double?, font: FontClass?, color: String?, prefix: String = "") -> String {
		var body = ""
		if !prefix.isEmpty {
			body += run(RescrivaRun(text: prefix), size: size, font: font, color: color)
		}
		for item in runs where !item.text.isEmpty {
			body += run(item, size: size, font: font, color: color)
		}
		return "<a:p>\(properties)\(body)</a:p>"
	}

	/// One or more `a:r` (split at line breaks with `a:br`). Open flags add
	/// nothing: the run renders as read.
	private static func run(_ run: RescrivaRun, size: Double?, font: FontClass?, color: String?) -> String {
		var attributes = "lang=\"en-US\""
		if let size { attributes += " sz=\"\(Int((size * 100).rounded()))\"" }
		if run.bold { attributes += " b=\"1\"" }
		if run.italic { attributes += " i=\"1\"" }
		if run.underline { attributes += " u=\"sng\"" }
		if run.strikethrough { attributes += " strike=\"sngStrike\"" }
		attributes += " dirty=\"0\""
		var children = ""
		if let hex = run.color?.hex ?? color {
			children += "<a:solidFill><a:srgbClr val=\"\(hex)\"/></a:solidFill>"
		}
		if let highlight = run.highlight {
			children += "<a:highlight><a:srgbClr val=\"\(highlight.hex)\"/></a:highlight>"
		}
		if let name = DOCXRenderer.fontName(font) {
			children += "<a:latin typeface=\"\(name)\"/>"
		}
		let properties = "<a:rPr \(attributes)>\(children)</a:rPr>"
		let lines = run.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
		return lines.enumerated().map { index, line -> String in
			let lineBreak = index == 0 ? "" : "<a:br>\(properties)</a:br>"
			return lineBreak + (line.isEmpty ? "" : "<a:r>\(properties)<a:t>\(OOXML.escape(String(line)))</a:t></a:r>")
		}.joined()
	}

	private static func listParagraphs(style: ListStyle, items: [ListItem], size: Double, font: FontClass?, color: String?) -> String {
		let numbering = ["arabicPeriod", "alphaLcPeriod", "romanLcPeriod"]
		let bulletColor = color.map { "<a:buClr><a:srgbClr val=\"\($0)\"/></a:buClr>" } ?? ""
		return items.map { item -> String in
			let level = RescrivaListCounter.clamp(item.level)
			let margin = 342_900 * (level + 1)
			switch style {
			case .bullet:
				let properties = "<a:pPr marL=\"\(margin)\" lvl=\"\(level)\" indent=\"-285750\">\(bulletColor)"
					+ "<a:buFont typeface=\"Arial\"/><a:buChar char=\"\u{2022}\"/></a:pPr>"
				return paragraph(item.runs, properties: properties, size: size, font: font, color: color)
			case .ordered:
				let properties = "<a:pPr marL=\"\(margin)\" lvl=\"\(level)\" indent=\"-342900\">\(bulletColor)"
					+ "<a:buAutoNum type=\"\(numbering[level % 3])\"/></a:pPr>"
				return paragraph(item.runs, properties: properties, size: size, font: font, color: color)
			case .checkbox:
				let properties = "<a:pPr marL=\"\(margin - 342_900)\" lvl=\"\(level)\" indent=\"0\"><a:buNone/></a:pPr>"
				let glyph = item.checked == true ? "\u{2611} " : "\u{2610} "
				return paragraph(item.runs, properties: properties, size: size, font: font, color: color, prefix: glyph)
			}
		}.joined()
	}

	// MARK: Tables

	/// A native table. The header row sits on a light tint of accent 1 and keeps
	/// the theme's dark text; body rows use `bodyColor` (white on dark slides).
	private func table(_ rows: [[TableCell]], rect: SlideRect, size: Double, font: FontClass?, bodyColor: String?, id: Int) -> String {
		let grid = RescrivaTableGrid(rows: rows)
		guard grid.columnCount > 0, !grid.rows.isEmpty else { return "" }
		let columnWidth = Int((rect.width / Double(grid.columnCount)).rounded())
		let rowHeight = Int((rect.height / Double(grid.rows.count)).rounded())
		let border = "<a:solidFill><a:srgbClr val=\"676C7A\"/></a:solidFill>"
		let lines = ["lnL", "lnR", "lnT", "lnB"].map { "<a:\($0) w=\"9525\">\(border)</a:\($0)>" }.joined()
		let headerFill = Self.tint(accents.first ?? "2B3B8C", amount: 0.75)
		var out = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"\(id)\" name=\"Table \(id)\"/>"
			+ "<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=\"1\"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>"
			+ "<p:xfrm>\(rect.offsetAndExtent)</p:xfrm><a:graphic>"
			+ "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl>"
			+ "<a:tblPr firstRow=\"1\" bandRow=\"1\"><a:tableStyleId>\(Self.tableStyleID)</a:tableStyleId></a:tblPr><a:tblGrid>"
			+ String(repeating: "<a:gridCol w=\"\(columnWidth)\"/>", count: grid.columnCount) + "</a:tblGrid>"
		for (rowIndex, row) in grid.rows.enumerated() {
			out += "<a:tr h=\"\(rowHeight)\">"
			let fill = rowIndex == 0 ? "<a:solidFill><a:srgbClr val=\"\(headerFill)\"/></a:solidFill>" : ""
			for (columnIndex, slot) in row.enumerated() {
				var attributes = ""
				var paragraph = "<a:p><a:endParaRPr lang=\"en-US\" sz=\"\(Int(size * 100))\" dirty=\"0\"/></a:p>"
				switch slot {
				case .origin(let cell, let rowSpan, let columnSpan):
					if columnSpan > 1 { attributes += " gridSpan=\"\(columnSpan)\"" }
					if rowSpan > 1 { attributes += " rowSpan=\"\(rowSpan)\"" }
					if !cell.runs.isEmpty {
						paragraph = Self.paragraph(cell.runs, properties: "", size: size, font: font, color: rowIndex == 0 ? nil : bodyColor)
					}
				case .covered(let originRow, let originColumn):
					if columnIndex > originColumn { attributes += " hMerge=\"1\"" }
					if rowIndex > originRow { attributes += " vMerge=\"1\"" }
				case .empty:
					break
				}
				out += "<a:tc\(attributes)><a:txBody><a:bodyPr/><a:lstStyle/>\(paragraph)</a:txBody>"
					+ "<a:tcPr marL=\"68580\" marR=\"68580\" marT=\"34290\" marB=\"34290\">\(lines)\(fill)</a:tcPr></a:tc>"
			}
			out += "</a:tr>"
		}
		return out + "</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
	}

	/// Mixes `hex` toward white by `amount` (0–1).
	static func tint(_ hex: String, amount: Double) -> String {
		guard let value = UInt32(hex, radix: 16) else { return hex }
		let color = RGBColor(hex: value)
		func mix(_ component: Double) -> Double { component + (1 - component) * amount }
		return RGBColor(red: mix(color.red), green: mix(color.green), blue: mix(color.blue)).hex
	}

	// MARK: Equations

	/// The typeset picture made for an equation the OMML converter can't
	/// handle (`EquationPictures`), when the export carries one.
	private func equationPicture(for latex: String) -> (key: String, data: Data, info: RescrivaImageInfo)? {
		let key = EquationPictures.assetKey(for: latex)
		guard let data = options.assets[key], let info = RescrivaImageInfo(data: data) else { return nil }
		return (key, data, info)
	}

	/// The equation's picture at its natural size (shrunk to fit the block's
	/// rect), centred across a display equation's rect, with the LaTeX as its
	/// alt text.
	private mutating func addEquationPicture(_ picture: (key: String, data: Data, info: RescrivaImageInfo), latex: String,
											 rect: SlideRect, display: Bool, slide: inout SlideBuilder, context: BlockContext) {
		let natural = EquationPictures.extent(of: picture.info, maxWidthInches: rect.width / OOXML.emuPerInch)
		var width = Double(natural.cx)
		var height = Double(natural.cy)
		if context.fit, height > rect.height, rect.height > 0 {
			width *= rect.height / height
			height = rect.height
		}
		let x = display ? rect.midX - width / 2 : rect.x
		let y = context.fit ? rect.y + max(rect.height - height, 0) / 2 : rect.y
		let placed = SlideRect(x: x, y: y, width: width, height: height)
		let relID = imageRelationship(assetID: picture.key, data: picture.data, info: picture.info, slide: &slide)
		let id = slide.shapeID()
		slide.shapes += "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"Equation \(id)\" descr=\"\(OOXML.escape(latex))\"/>"
			+ "<p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"
			+ "<p:blipFill><a:blip r:embed=\"\(relID)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
			+ "<p:spPr><a:xfrm>\(placed.offsetAndExtent)</a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
	}

	// MARK: Figures

	private mutating func addFigure(assetID: String?, caption: String?, altText: String?, rect: SlideRect, scale: Double, slide: inout SlideBuilder, context: BlockContext) {
		let hasCaption = !(caption?.isEmpty ?? true)
		let captionHeight = 320_040.0 * scale
		var imageArea = rect
		if hasCaption, !context.fit {
			imageArea.height = max(rect.height - captionHeight, rect.height * 0.5)
		}
		let description = [altText, caption].compactMap { $0 }.first { !$0.isEmpty } ?? ""
		var pictureBottom = imageArea.maxY
		if let assetID, let data = options.assets[assetID], let info = RescrivaImageInfo(data: data) {
			let relID = imageRelationship(assetID: assetID, data: data, info: info, slide: &slide)
			let placed = imageArea.fitting(aspect: info.aspect)
			pictureBottom = placed.maxY
			let id = slide.shapeID()
			slide.shapes += "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"Picture \(id)\" descr=\"\(OOXML.escape(description))\"/>"
				+ "<p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"
				+ "<p:blipFill><a:blip r:embed=\"\(relID)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
				+ "<p:spPr><a:xfrm>\(placed.offsetAndExtent)</a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
		} else {
			let label = description.isEmpty ? "[Figure]" : "[Figure: \(description)]"
			let paragraph = Self.paragraph([RescrivaRun(text: label, italic: true)], properties: "<a:pPr algn=\"ctr\"/>",
										   size: max(14 * scale, 9), font: nil, color: context.defaultColor)
			slide.shapes += Self.textBox(id: slide.shapeID(), rect: imageArea, paragraphs: paragraph, anchor: "ctr")
		}
		if let caption, hasCaption {
			addCaption(caption, below: pictureBottom, x: rect.x, width: rect.width, scale: scale, slide: &slide, context: context)
		}
	}

	private func addCaption(_ caption: String, below bottom: Double, x: Double, width: Double, scale: Double, slide: inout SlideBuilder, context: BlockContext) {
		let height = 320_040.0 * max(scale, 0.5)
		let y = min(bottom + 18_288, slideHeight - height)
		let rect = SlideRect(x: x, y: y, width: width, height: height)
		let color = context.defaultColor ?? "5F6B76"
		let paragraph = Self.paragraph([RescrivaRun(text: caption, italic: true)], properties: "<a:pPr algn=\"ctr\"/>",
									   size: max(12 * scale, 9), font: nil, color: color)
		slide.shapes += Self.textBox(id: slide.shapeID(), rect: rect, paragraphs: paragraph, name: "Caption")
	}

	private mutating func imageRelationship(assetID: String, data: Data, info: RescrivaImageInfo, slide: inout SlideBuilder) -> String {
		let name: String
		if let existing = mediaByAsset[assetID] {
			name = existing.name
		} else {
			name = "image\(media.count + 1).\(info.format.fileExtension)"
			media.append(("ppt/media/" + name, data))
			mediaByAsset[assetID] = (name, info)
			contentTypes.addDefault(extension: info.format.fileExtension, contentType: info.format.contentType)
		}
		if let relID = slide.imageRelationships[name] { return relID }
		let relID = slide.relationships.add(type: OOXML.Rel.image, target: "../media/" + name)
		slide.imageRelationships[name] = relID
		return relID
	}

	// MARK: Diagrams

	/// Connectors attach at the connection sites `RescrivaDiagramGeometry`
	/// picks (shared with the Word renderer), so they follow their shapes.
	private func addDiagram(_ diagram: Diagram, rect: SlideRect, scale: Double, font: FontClass?, slide: inout SlideBuilder, context: BlockContext) {
		let hasCaption = !(diagram.caption?.isEmpty ?? true)
		var area = rect
		if hasCaption, !context.fit {
			area.height = max(rect.height - 320_040 * scale, rect.height * 0.5)
		}
		let aspect = min(max(diagram.aspect.isFinite ? diagram.aspect : 1.6, 0.25), 6)
		let frame = area.fitting(aspect: aspect)
		var placed: [String: (id: Int, frame: RescrivaDiagramGeometry.Frame)] = [:]
		for node in diagram.nodes where placed[node.id] == nil {
			let nodeRect = Self.place(node.box, in: frame)
			let id = slide.shapeID()
			placed[node.id] = (id, RescrivaDiagramGeometry.Frame(x: nodeRect.x, y: nodeRect.y, width: nodeRect.width,
																  height: nodeRect.height, shape: node.shape))
			slide.shapes += Self.nodeShape(node, id: id, rect: nodeRect, font: font)
		}
		for edge in diagram.edges {
			guard edge.from != edge.to, let from = placed[edge.from], let to = placed[edge.to] else { continue }
			let connection = RescrivaDiagramGeometry.connection(from: from.frame, to: to.frame)
			let segment = connection.segment
			var flips = ""
			if segment.x2 < segment.x1 { flips += " flipH=\"1\"" }
			if segment.y2 < segment.y1 { flips += " flipV=\"1\"" }
			let line = SlideRect(x: min(segment.x1, segment.x2), y: min(segment.y1, segment.y2),
								 width: abs(segment.x2 - segment.x1), height: abs(segment.y2 - segment.y1))
			let id = slide.shapeID()
			slide.shapes += "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"\(id)\" name=\"Connector \(id)\"/><p:cNvCxnSpPr>"
				+ "<a:stCxn id=\"\(from.id)\" idx=\"\(connection.startSite)\"/><a:endCxn id=\"\(to.id)\" idx=\"\(connection.endSite)\"/></p:cNvCxnSpPr>"
				+ "<p:nvPr/></p:nvCxnSpPr><p:spPr><a:xfrm\(flips)>\(line.offsetAndExtent)</a:xfrm>"
				+ "<a:prstGeom prst=\"straightConnector1\"><a:avLst/></a:prstGeom>"
				+ "<a:ln w=\"19050\"><a:solidFill><a:srgbClr val=\"\(context.defaultColor ?? Self.ink)\"/></a:solidFill>"
				+ "\(edge.direction.drawingMLLineEnds)</a:ln></p:spPr></p:cxnSp>"
			if let label = edge.label, !label.isEmpty {
				let width = min(1.8, 0.2 + 0.09 * Double(label.count)) * OOXML.emuPerInch
				let height = 0.3 * OOXML.emuPerInch
				let center = RescrivaDiagramGeometry.labelCenter(for: segment, width: width, height: height, gap: 2 * OOXML.emuPerPoint)
				let labelRect = SlideRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
				let paragraph = Self.paragraph([RescrivaRun(text: label)], properties: "<a:pPr algn=\"ctr\"/>",
											   size: max(11 * scale, 8), font: font, color: context.defaultColor)
				let labelID = slide.shapeID()
				slide.shapes += "<p:sp><p:nvSpPr><p:cNvPr id=\"\(labelID)\" name=\"Label \(labelID)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr>"
					+ "<p:spPr><a:xfrm>\(labelRect.offsetAndExtent)</a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
					+ "<a:noFill/></p:spPr>"
					+ "<p:txBody><a:bodyPr wrap=\"none\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" anchor=\"ctr\"><a:noAutofit/></a:bodyPr>"
					+ "<a:lstStyle/>\(paragraph)</p:txBody></p:sp>"
			}
		}
		if let caption = diagram.caption, hasCaption {
			addCaption(caption, below: frame.maxY, x: rect.x, width: rect.width, scale: scale, slide: &slide, context: context)
		}
	}

	private static func nodeShape(_ node: Diagram.Node, id: Int, rect: SlideRect, font: FontClass?) -> String {
		let fill = node.fill.map { "<a:solidFill><a:srgbClr val=\"\($0.hex)\"/></a:solidFill>" } ?? "<a:noFill/>"
		let textColor = node.fill.map { $0.isDark ? "FFFFFF" : ink } ?? ink
		let size = TextMetrics.fittedSize(node.label, in: rect, preferred: 16, minimum: 7)
		let paragraph = paragraph([RescrivaRun(text: node.label)], properties: "<a:pPr algn=\"ctr\"/>", size: size, font: font, color: textColor)
		return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(OOXML.escape(node.label))\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>"
			+ "<p:spPr><a:xfrm>\(rect.offsetAndExtent)</a:xfrm><a:prstGeom prst=\"\(node.shape.presetGeometry)\"><a:avLst/></a:prstGeom>\(fill)"
			+ "<a:ln w=\"19050\"><a:solidFill><a:srgbClr val=\"\(node.stroke.hex)\"/></a:solidFill></a:ln></p:spPr>"
			+ "<p:txBody><a:bodyPr rtlCol=\"0\" lIns=\"45720\" tIns=\"22860\" rIns=\"45720\" bIns=\"22860\" anchor=\"ctr\"><a:noAutofit/></a:bodyPr>"
			+ "<a:lstStyle/>\(paragraph)</p:txBody></p:sp>"
	}
}

/// The fixed PresentationML parts: theme, master, layouts, notes master and
/// the small presentation-level property parts.
private enum PPTXParts {
	static let namespaces = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
		+ " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
		+ " xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""

	static let groupProperties = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
		+ "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/>"
		+ "<a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"

	/// `a:lvl1pPr`…`a:lvl9pPr` for the default and "other" text styles: same
	/// minor font, size and colour at every level, indented 0.5in per level.
	static let textLevels: String = (1...9).map { level in
		"<a:lvl\(level)pPr marL=\"\(457_200 * (level - 1))\" algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\">"
			+ "<a:defRPr sz=\"1800\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill>"
			+ "<a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/></a:defRPr></a:lvl\(level)pPr>"
	}.joined()

	static let presProps = OOXML.declaration + "<p:presentationPr \(namespaces)/>"

	static let viewProps = OOXML.declaration + "<p:viewPr \(namespaces)><p:normalViewPr><p:restoredLeft sz=\"15620\"/>"
		+ "<p:restoredTop sz=\"94660\"/></p:normalViewPr><p:gridSpacing cx=\"76200\" cy=\"76200\"/></p:viewPr>"

	static func tableStyles(defaultStyle: String) -> String {
		OOXML.declaration + "<a:tblStyleLst xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" def=\"\(defaultStyle)\"/>"
	}

	static let clrMap = "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\""
		+ " accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"

	static func theme(name: String, accents: [String]) -> String {
		let accentXML = accents.prefix(6).enumerated().map { index, hex in
			"<a:accent\(index + 1)><a:srgbClr val=\"\(hex)\"/></a:accent\(index + 1)>"
		}.joined()
		let line = { (width: Int) in
			"<a:ln w=\"\(width)\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
				+ "<a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/></a:ln>"
		}
		let font = { (latin: String) in "<a:latin typeface=\"\(latin)\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>" }
		return OOXML.declaration
			+ "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"\(OOXML.escape(name))\"><a:themeElements>"
			+ "<a:clrScheme name=\"Rescriva\"><a:dk1><a:srgbClr val=\"1D2233\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1>"
			+ "<a:dk2><a:srgbClr val=\"2F3D2B\"/></a:dk2><a:lt2><a:srgbClr val=\"F4F1EA\"/></a:lt2>"
			+ accentXML
			+ "<a:hlink><a:srgbClr val=\"2B3B8C\"/></a:hlink><a:folHlink><a:srgbClr val=\"676C7A\"/></a:folHlink></a:clrScheme>"
			+ "<a:fontScheme name=\"Rescriva\"><a:majorFont>\(font("Calibri Light"))</a:majorFont>"
			+ "<a:minorFont>\(font("Calibri"))</a:minorFont></a:fontScheme>"
			+ "<a:fmtScheme name=\"Rescriva\"><a:fillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
			+ "<a:solidFill><a:schemeClr val=\"phClr\"><a:tint val=\"50000\"/></a:schemeClr></a:solidFill>"
			+ "<a:solidFill><a:schemeClr val=\"phClr\"><a:shade val=\"80000\"/></a:schemeClr></a:solidFill></a:fillStyleLst>"
			+ "<a:lnStyleLst>\(line(6350))\(line(12700))\(line(19050))</a:lnStyleLst>"
			+ "<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>"
			+ "<a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>"
			+ "<a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
			+ "<a:solidFill><a:schemeClr val=\"phClr\"><a:tint val=\"95000\"/></a:schemeClr></a:solidFill>"
			+ "<a:solidFill><a:schemeClr val=\"phClr\"><a:shade val=\"90000\"/></a:schemeClr></a:solidFill></a:bgFillStyleLst>"
			+ "</a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"
	}

	private static func placeholder(id: Int, name: String, type: String, index: Int?, rect: String, anchor: String, prompt: String) -> String {
		let indexAttribute = index.map { " idx=\"\($0)\"" } ?? ""
		return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>"
			+ "<p:nvPr><p:ph type=\"\(type)\"\(indexAttribute)/></p:nvPr></p:nvSpPr>"
			+ "<p:spPr><a:xfrm>\(rect)</a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>"
			+ "<p:txBody><a:bodyPr vert=\"horz\" lIns=\"91440\" tIns=\"45720\" rIns=\"91440\" bIns=\"45720\" rtlCol=\"0\" anchor=\"\(anchor)\">"
			+ "<a:normAutofit/></a:bodyPr><a:lstStyle/><a:p><a:r><a:rPr lang=\"en-US\"/><a:t>\(prompt)</a:t></a:r></a:p></p:txBody></p:sp>"
	}

	static func slideMaster(width: Double) -> String {
		let x = Int((width * 0.06875).rounded())
		let w = Int(width) - 2 * x
		let title = "<a:off x=\"\(x)\" y=\"365125\"/><a:ext cx=\"\(w)\" cy=\"1325563\"/>"
		let body = "<a:off x=\"\(x)\" y=\"1825625\"/><a:ext cx=\"\(w)\" cy=\"4351338\"/>"
		let bodyLevel = { (level: Int, margin: Int, size: Int) in
			"<a:lvl\(level)pPr marL=\"\(margin)\" indent=\"-228600\" algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\">"
				+ "<a:lnSpc><a:spcPct val=\"90000\"/></a:lnSpc><a:spcBef><a:spcPts val=\"1000\"/></a:spcBef>"
				+ "<a:buFont typeface=\"Arial\"/><a:buChar char=\"\u{2022}\"/>"
				+ "<a:defRPr sz=\"\(size)\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill>"
				+ "<a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/></a:defRPr></a:lvl\(level)pPr>"
		}
		return OOXML.declaration + "<p:sldMaster \(namespaces)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg>"
			+ "<p:spTree>\(groupProperties)"
			+ placeholder(id: 2, name: "Title Placeholder 1", type: "title", index: nil, rect: title, anchor: "ctr", prompt: "Click to edit Master title style")
			+ placeholder(id: 3, name: "Text Placeholder 2", type: "body", index: 1, rect: body, anchor: "t", prompt: "Click to edit Master text styles")
			+ "</p:spTree></p:cSld>\(clrMap)"
			+ "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/><p:sldLayoutId id=\"2147483650\" r:id=\"rId2\"/></p:sldLayoutIdLst>"
			+ "<p:txStyles><p:titleStyle><a:lvl1pPr algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\">"
			+ "<a:lnSpc><a:spcPct val=\"90000\"/></a:lnSpc><a:spcBef><a:spcPct val=\"0\"/></a:spcBef><a:buNone/>"
			+ "<a:defRPr sz=\"4000\" b=\"1\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill>"
			+ "<a:latin typeface=\"+mj-lt\"/><a:ea typeface=\"+mj-ea\"/><a:cs typeface=\"+mj-cs\"/></a:defRPr></a:lvl1pPr></p:titleStyle>"
			+ "<p:bodyStyle>\(bodyLevel(1, 228600, 2400))\(bodyLevel(2, 685800, 2000))\(bodyLevel(3, 1143000, 1800))</p:bodyStyle>"
			+ "<p:otherStyle><a:defPPr><a:defRPr lang=\"en-US\"/></a:defPPr>\(textLevels)</p:otherStyle></p:txStyles></p:sldMaster>"
	}

	static let masterRelationships: String = {
		var rels = OOXML.Relationships()
		rels.add(type: OOXML.Rel.slideLayout, target: "../slideLayouts/slideLayout1.xml")
		rels.add(type: OOXML.Rel.slideLayout, target: "../slideLayouts/slideLayout2.xml")
		rels.add(type: OOXML.Rel.theme, target: "../theme/theme1.xml")
		return rels.xml
	}()

	static let layoutRelationships: String = {
		var rels = OOXML.Relationships()
		rels.add(type: OOXML.Rel.slideMaster, target: "../slideMasters/slideMaster1.xml")
		return rels.xml
	}()

	static let titleAndContentLayout = OOXML.declaration
		+ "<p:sldLayout \(namespaces) type=\"obj\" preserve=\"1\"><p:cSld name=\"Title and Content\"><p:spTree>\(groupProperties)"
		+ "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Title 1\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>"
		+ "<p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>"
		+ "<a:p><a:r><a:rPr lang=\"en-US\"/><a:t>Click to edit Master title style</a:t></a:r></a:p></p:txBody></p:sp>"
		+ "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Content Placeholder 2\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>"
		+ "<p:nvPr><p:ph idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>"
		+ "<a:p><a:pPr lvl=\"0\"/><a:r><a:rPr lang=\"en-US\"/><a:t>Click to edit Master text styles</a:t></a:r></a:p></p:txBody></p:sp>"
		+ "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"

	static let blankLayout = OOXML.declaration
		+ "<p:sldLayout \(namespaces) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(groupProperties)"
		+ "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"

	static let notesMaster = OOXML.declaration
		+ "<p:notesMaster \(namespaces)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg>"
		+ "<p:spTree>\(groupProperties)"
		+ "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Slide Image Placeholder 1\"/>"
		+ "<p:cNvSpPr><a:spLocks noGrp=\"1\" noRot=\"1\" noChangeAspect=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"sldImg\" idx=\"2\"/></p:nvPr></p:nvSpPr>"
		+ "<p:spPr><a:xfrm><a:off x=\"685800\" y=\"1143000\"/><a:ext cx=\"5486400\" cy=\"3086100\"/></a:xfrm>"
		+ "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/><a:ln w=\"12700\"><a:solidFill><a:prstClr val=\"black\"/></a:solidFill></a:ln></p:spPr></p:sp>"
		+ "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Notes Placeholder 2\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>"
		+ "<p:nvPr><p:ph type=\"body\" sz=\"quarter\" idx=\"3\"/></p:nvPr></p:nvSpPr>"
		+ "<p:spPr><a:xfrm><a:off x=\"685800\" y=\"4400550\"/><a:ext cx=\"5486400\" cy=\"3600450\"/></a:xfrm>"
		+ "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>"
		+ "<p:txBody><a:bodyPr vert=\"horz\" lIns=\"91440\" tIns=\"45720\" rIns=\"91440\" bIns=\"45720\" rtlCol=\"0\"/><a:lstStyle/>"
		+ "<a:p><a:pPr lvl=\"0\"/><a:r><a:rPr lang=\"en-US\"/><a:t>Click to edit Master text styles</a:t></a:r></a:p></p:txBody></p:sp>"
		+ "</p:spTree></p:cSld>\(clrMap)"
		+ "<p:notesStyle><a:lvl1pPr marL=\"0\" algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\">"
		+ "<a:defRPr sz=\"1200\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill>"
		+ "<a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/></a:defRPr></a:lvl1pPr></p:notesStyle>"
		+ "</p:notesMaster>"

	static let notesMasterRelationships: String = {
		var rels = OOXML.Relationships()
		rels.add(type: OOXML.Rel.theme, target: "../theme/theme2.xml")
		return rels.xml
	}()

	static func notesSlide(paragraphs: [String]) -> String {
		let body = paragraphs.map { text -> String in
			let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
			let runs = lines.enumerated().map { index, line -> String in
				(index == 0 ? "" : "<a:br><a:rPr lang=\"en-US\" dirty=\"0\"/></a:br>")
					+ "<a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>\(OOXML.escape(String(line)))</a:t></a:r>"
			}.joined()
			return "<a:p>\(runs)</a:p>"
		}.joined()
		return OOXML.declaration + "<p:notes \(namespaces)><p:cSld><p:spTree>\(groupProperties)"
			+ "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Slide Image Placeholder 1\"/>"
			+ "<p:cNvSpPr><a:spLocks noGrp=\"1\" noRot=\"1\" noChangeAspect=\"1\"/></p:cNvSpPr>"
			+ "<p:nvPr><p:ph type=\"sldImg\"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp>"
			+ "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Notes Placeholder 2\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>"
			+ "<p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr/>"
			+ "<p:txBody><a:bodyPr/><a:lstStyle/>\(body)</p:txBody></p:sp>"
			+ "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"
	}
}
