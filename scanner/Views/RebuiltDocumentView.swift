//
//  RebuiltDocumentView.swift
//  Rescriva (fork of Open Scanner)
//
//  Draws a RescrivaDocument the way it will come out in Word: headings,
//  paragraphs, checklists, tables, the equation, the diagram and the
//  figures' pictures. Uncertain words are highlighted and open their
//  flag when tapped; tapping a block selects it for the format buttons, and
//  a figure or diagram also opens its menu (Recreate, Remove figure).
//

import SwiftUI

struct RebuiltDocumentView: View {
	@Environment(\.documentIsInteractive) private var interactive
	let document: RescrivaDocument
	let output: OutputKind
	let selectedBlock: UUID?
	let activeFlag: UUID?
	let onSelectBlock: (UUID) -> Void
	let onOpenFlag: (UUID) -> Void
	let onToggleItem: (UUID, UUID) -> Void
	/// What a tapped figure or diagram offers (e.g. Recreate); nil or empty shows no menu.
	var blockActions: ((RescrivaBlock) -> [BlockAction])? = nil

	@State private var menuBlock: UUID?

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			ForEach(Array(document.pages.enumerated()), id: \.element.id) { pageIndex, page in
				if pageIndex > 0 {
					PageDivider(number: pageIndex + 1)
						.environment(\.colorScheme, .light)
				}
				ForEach(page.blocks) { block in
					// The document is printed on paper: its type keeps its paper colours in the dark.
					BlockView(block: block, output: output, activeFlag: activeFlag,
							  onOpenFlag: onOpenFlag, onToggleItem: { onToggleItem(block.id, $0) })
						.environment(\.colorScheme, .light)
						.padding(.vertical, 2)
						.padding(.horizontal, 4)
						.background {
							RoundedRectangle(cornerRadius: 8, style: .continuous)
								.strokeBorder(Color.ink.opacity(interactive && selectedBlock == block.id ? 0.55 : 0), lineWidth: 1.5)
								.padding(-4)
						}
						.contentShape(Rectangle())
						.onTapGesture { tapped(block) }
						.popover(isPresented: menuShown(for: block.id), attachmentAnchor: .point(.center)) {
							BlockActionMenu(actions: blockActions?(block) ?? [])
						}
						.accessibilityAddTraits(selectedBlock == block.id ? .isSelected : [])
						.id(block.id)
				}
			}
		}
		.environment(\.openURL, OpenURLAction { url in
			guard url.scheme == "rescriva-flag", let host = url.host(), let id = UUID(uuidString: host) else {
				return .systemAction
			}
			onOpenFlag(id)
			return .handled
		})
		.tint(.carbon)
	}

	/// Selects the block and, for a figure or diagram with actions, opens its menu.
	private func tapped(_ block: RescrivaBlock) {
		guard interactive else { return }
		onSelectBlock(block.id)
		if !(blockActions?(block) ?? []).isEmpty { menuBlock = block.id }
	}

	private func menuShown(for id: UUID) -> Binding<Bool> {
		Binding(get: { menuBlock == id }, set: { if !$0, menuBlock == id { menuBlock = nil } })
	}
}

private struct PageDivider: View {
	let number: Int

	var body: some View {
		HStack(spacing: 8) {
			Rectangle().fill(Color.carbon.opacity(0.12)).frame(height: 1)
			Text("Page \(number)")
				.font(RescrivaFont.ui(11))
				.foregroundStyle(.graphite)
			Rectangle().fill(Color.carbon.opacity(0.12)).frame(height: 1)
		}
		.accessibilityHidden(true)
	}
}

/// One block of the rebuilt document.
private struct BlockView: View {
	@Environment(\.documentIsInteractive) private var interactive
	let block: RescrivaBlock
	let output: OutputKind
	let activeFlag: UUID?
	let onOpenFlag: (UUID) -> Void
	let onToggleItem: (UUID) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			content
			ForEach(block.notes) { note in
				NoteView(note: note, output: output)
			}
		}
	}

	@ViewBuilder
	private var content: some View {
		switch block.content {
		case .heading(let level, let runs):
			Text(styled(runs, font: headingFont(level), activeFlag: activeFlag, showsFlags: interactive))
				.lineSpacing(2)
				.accessibilityAddTraits(.isHeader)
		case .paragraph(let runs, let alignment):
			Text(styled(runs, font: RescrivaFont.body(16), activeFlag: activeFlag, showsFlags: interactive))
				.lineSpacing(6)
				.multilineTextAlignment(alignment.swiftUI)
				.frame(maxWidth: .infinity, alignment: alignment.frame)
		case .list(let style, let items):
			VStack(alignment: .leading, spacing: 8) {
				ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
					HStack(alignment: .firstTextBaseline, spacing: 10) {
						marker(style: style, index: index, item: item)
						Text(styled(item.runs, font: RescrivaFont.body(16), activeFlag: activeFlag, showsFlags: interactive))
							.lineSpacing(4)
					}
					.padding(.leading, CGFloat(item.level) * 18)
				}
			}
		case .table(let rows):
			TableBlock(rows: rows, activeFlag: activeFlag)
		case .equation(let latex, let linear, _):
			VStack(spacing: 6) {
				EquationView(latex: latex, fallback: linear)
				Text(output == .docx ? "Equation · editable in Word" : "Equation")
					.font(RescrivaFont.ui(11, weight: .medium))
					.foregroundStyle(.ink)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 10)
			.background(Color.wash.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(Text("Equation: \(linear)"))
		case .figure(let assetID, let caption, let altText):
			FigureBlockView(assetID: assetID, caption: caption, altText: altText)
		case .diagram(let diagram):
			VStack(alignment: .leading, spacing: 6) {
				if let caption = diagram.caption {
					Text(caption).rescrivaSectionLabel()
				}
				DiagramView(diagram: diagram, onOpenFlag: onOpenFlag)
					.frame(maxWidth: .infinity)
			}
		}
	}

	@ViewBuilder
	private func marker(style: ListStyle, index: Int, item: ListItem) -> some View {
		switch style {
		case .checkbox:
			Button {
				onToggleItem(item.id)
			} label: {
				ZStack {
					if item.checked == true {
						RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.ink)
						Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.vellum)
					} else {
						RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.carbon, lineWidth: 1.5)
					}
				}
				.frame(width: 18, height: 18)
				.alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
			}
			.buttonStyle(PressScaleStyle())
			.disabled(!interactive)
			.accessibilityLabel(item.checked == true ? "Checked" : "Not checked")
		case .bullet:
			Text("•").font(RescrivaFont.body(16)).foregroundStyle(.carbon)
		case .ordered:
			Text("\(index + 1).").font(RescrivaFont.body(16)).foregroundStyle(.carbon)
		}
	}

	private func headingFont(_ level: Int) -> Font {
		switch level {
		case 1: return RescrivaFont.header(24)
		case 2: return RescrivaFont.header(20)
		default: return RescrivaFont.header(18)
		}
	}
}

/// A figure: its picture once loaded (see the `figureImages` environment value), a placeholder
/// until then or when this iPhone can't make it, and its caption.
private struct FigureBlockView: View {
	@Environment(\.figureImages) private var figureImages
	let assetID: String?
	let caption: String?
	let altText: String?

	@State private var image: UIImage?

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			if let image {
				Image(uiImage: image)
					.resizable()
					.scaledToFit()
					.frame(maxWidth: .infinity, maxHeight: 320)
					.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
			} else {
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(Color.scanBackdrop)
					.frame(height: 120)
					.overlay { Image(systemName: "photo").font(.system(size: 24, weight: .light)).foregroundStyle(.graphite) }
			}
			if let caption {
				Text(caption).font(RescrivaFont.ui(12)).foregroundStyle(.graphite)
			}
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(caption ?? altText ?? String(localized: "Figure")))
		.accessibilityAddTraits(.isImage)
		.task(id: assetID) {
			guard let assetID, let figureImages else { return }
			image = await figureImages.load(assetID)
		}
	}
}

/// Styled runs as an attributed string. Unresolved flags are highlighted (more
/// strongly while their sheet is open) and are links that open the flag sheet.
func styled(_ runs: [RescrivaRun], font: Font, activeFlag: UUID?, showsFlags: Bool = true) -> AttributedString {
	var result = AttributedString()
	for run in runs {
		var piece = AttributedString(run.text)
		var runFont = font
		if run.bold { runFont = runFont.bold() }
		if run.italic { runFont = runFont.italic() }
		piece.font = runFont
		piece.foregroundColor = .carbon
		if run.underline {
			piece.underlineStyle = Text.LineStyle(pattern: .solid, color: .carbon)
		}
		if run.strikethrough {
			piece.strikethroughStyle = Text.LineStyle(pattern: .solid, color: .carbon)
		}
		if showsFlags, let flag = run.flag, flag.resolution == nil {
			piece.backgroundColor = Color.highlighter.opacity(activeFlag == flag.id ? 0.75 : 0.4)
			piece.underlineStyle = Text.LineStyle(pattern: .dot, color: Color.carbon.opacity(0.45))
			piece.link = URL(string: "rescriva-flag://\(flag.id.uuidString)")
		}
		result.append(piece)
	}
	return result
}

/// A block note, with where it will end up in the export.
private struct NoteView: View {
	let note: RescrivaNote
	let output: OutputKind

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Glyph("text.bubble", size: 14, weight: .light)
				.foregroundStyle(.carbon)
				.padding(.top, 1)
			(Text(note.text).foregroundStyle(Color.carbon)
			 + Text(" · \(destination)").foregroundStyle(Color.graphite))
				.font(RescrivaFont.ui(13))
				.lineSpacing(3)
		}
		.padding(.vertical, 10)
		.padding(.horizontal, 12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.highlighter.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
	}

	private var destination: String {
		switch output {
		case .docx: return String(localized: "becomes a Word comment")
		case .pptx: return String(localized: "becomes a speaker note")
		case .pdf: return String(localized: "becomes a PDF note")
		}
	}
}

/// A simple bordered table; spanning cells stretch across columns.
private struct TableBlock: View {
	@Environment(\.documentIsInteractive) private var interactive
	let rows: [[TableCell]]
	let activeFlag: UUID?

	var body: some View {
		VStack(spacing: 0) {
			ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
				HStack(spacing: 0) {
					ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
						Text(styled(cell.runs, font: rowIndex == 0 ? RescrivaFont.ui(13, weight: .medium) : RescrivaFont.ui(13), activeFlag: activeFlag, showsFlags: interactive))
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(8)
							.layoutPriority(Double(cell.columnSpan))
							.overlay { Rectangle().strokeBorder(Color.carbon.opacity(0.18), lineWidth: 0.5) }
					}
				}
			}
		}
		.background(Color.paper)
		.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
		.overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.carbon.opacity(0.25), lineWidth: 1) }
	}
}

private extension TextAlignment {
	var swiftUI: SwiftUI.TextAlignment {
		switch self {
		case .center: return .center
		case .trailing: return .trailing
		case .leading, .justified: return .leading
		}
	}

	var frame: Alignment {
		switch self {
		case .center: return .center
		case .trailing: return .trailing
		case .leading, .justified: return .leading
		}
	}
}

// MARK: - Equation

/// Typesets a small LaTeX subset — fractions, sub/superscripts, Greek and a
/// few operators — and falls back to the linear form for anything else.
struct EquationView: View {
	let latex: String
	let fallback: String

	private var parsed: MathNode? {
		var parser = MathParser(latex)
		return parser.parse()
	}

	var body: some View {
		if let node = parsed {
			MathNodeView(node: node, size: 19)
				.foregroundStyle(.carbon)
		} else {
			Text(fallback)
				.font(RescrivaFont.body(19, italic: true))
				.foregroundStyle(.carbon)
		}
	}
}

/// Parsed math.
indirect enum MathNode: Equatable {
	case symbol(String)
	case row([MathNode])
	case fraction(MathNode, MathNode)
	case scripts(base: MathNode, sub: MathNode?, sup: MathNode?)
}

/// Recursive-descent parser for the supported subset.
struct MathParser {
	private let characters: [Character]
	private var index = 0

	init(_ latex: String) {
		characters = Array(latex)
	}

	/// Brace nesting deeper than this is refused (the linear fallback is shown).
	static let maxDepth = 16

	mutating func parse() -> MathNode? {
		let row = parseRow(until: nil, depth: 0)
		return index == characters.count ? row : nil
	}

	private static let symbols: [String: String] = [
		"alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "theta": "θ", "lambda": "λ",
		"mu": "μ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "omega": "ω",
		"Delta": "Δ", "Sigma": "Σ", "Omega": "Ω", "cdot": "·", "times": "×", "pm": "±", "leq": "≤",
		"geq": "≥", "neq": "≠", "approx": "≈", "infty": "∞", "rightarrow": "→", "to": "→",
		"sum": "∑", "int": "∫", "partial": "∂", "nabla": "∇", "xi": "ξ", "eta": "η", "kappa": "κ", "nu": "ν",
		"chi": "χ", "psi": "ψ", "zeta": "ζ", "Gamma": "Γ", "Lambda": "Λ", "Phi": "Φ", "Psi": "Ψ", "Theta": "Θ", "Pi": "Π",
		"ln": "ln", "log": "log", "sin": "sin", "cos": "cos", "tan": "tan", "exp": "exp", "lim": "lim",
		"min": "min", "max": "max",
	]

	/// Commands whose braced argument is plain upright text.
	private static let textCommands: Set<String> = ["text", "mathrm", "mathbf", "operatorname"]
	/// Longest \text{…} argument read.
	private static let maxTextLength = 200

	private mutating func parseRow(until terminator: Character?, depth: Int) -> MathNode? {
		guard depth < Self.maxDepth else { return nil }
		var nodes: [MathNode] = []
		while index < characters.count {
			let character = characters[index]
			if let terminator, character == terminator {
				break
			}
			switch character {
			case "{":
				index += 1
				guard let group = parseRow(until: "}", depth: depth + 1), consume("}") else { return nil }
				nodes.append(group)
			case "}":
				return nil
			case "_", "^":
				index += 1
				guard let script = parseAtom(depth: depth + 1) else { return nil }
				let base = nodes.popLast() ?? .symbol("")
				if case .scripts(let b, let sub, let sup) = base {
					nodes.append(character == "_" ? .scripts(base: b, sub: script, sup: sup) : .scripts(base: b, sub: sub, sup: script))
				} else {
					nodes.append(character == "_" ? .scripts(base: base, sub: script, sup: nil) : .scripts(base: base, sub: nil, sup: script))
				}
			case "\\":
				index += 1
				let name = readCommand()
				if name == "frac" {
					guard let numerator = parseAtom(depth: depth + 1), let denominator = parseAtom(depth: depth + 1) else { return nil }
					nodes.append(.fraction(numerator, denominator))
				} else if Self.textCommands.contains(name) {
					guard let words = readBracedText() else { return nil }
					nodes.append(.symbol(words))
				} else if name == "sqrt" {
					guard let radicand = parseAtom(depth: depth + 1) else { return nil }
					nodes.append(.row([.symbol("√"), radicand]))
				} else if name == "left" || name == "right" {
					continue
				} else if let symbol = Self.symbols[name] {
					nodes.append(.symbol(symbol))
				} else if name == " " || name == "," {
					nodes.append(.symbol(" "))
				} else {
					return nil
				}
			default:
				index += 1
				nodes.append(.symbol(String(character)))
			}
		}
		return nodes.count == 1 ? nodes[0] : .row(nodes)
	}

	private mutating func parseAtom(depth: Int) -> MathNode? {
		guard index < characters.count, depth < Self.maxDepth else { return nil }
		if characters[index] == "{" {
			index += 1
			guard let group = parseRow(until: "}", depth: depth + 1), consume("}") else { return nil }
			return group
		}
		if characters[index] == "\\" {
			index += 1
			let name = readCommand()
			return Self.symbols[name].map { .symbol($0) }
		}
		defer { index += 1 }
		return .symbol(String(characters[index]))
	}

	/// The raw text of a `{…}` group (no nesting), for \text and friends.
	private mutating func readBracedText() -> String? {
		guard consume("{") else { return nil }
		var words = ""
		while index < characters.count, characters[index] != "}", words.count < Self.maxTextLength {
			words.append(characters[index])
			index += 1
		}
		return consume("}") ? words : nil
	}

	private mutating func readCommand() -> String {
		var name = ""
		while index < characters.count, characters[index].isLetter {
			name.append(characters[index])
			index += 1
		}
		if name.isEmpty, index < characters.count {
			name = String(characters[index])
			index += 1
		}
		return name
	}

	private mutating func consume(_ character: Character) -> Bool {
		guard index < characters.count, characters[index] == character else { return false }
		index += 1
		return true
	}
}

/// Lays out a parsed math node: text rows as one Text, fractions stacked.
struct MathNodeView: View {
	let node: MathNode
	let size: CGFloat

	var body: some View {
		if let text = Self.text(node, size: size, depth: 0) {
			text
		} else {
			switch node {
			case .fraction(let numerator, let denominator):
				VStack(spacing: 2) {
					MathNodeView(node: numerator, size: size * 0.9)
						.padding(.horizontal, 6)
					Rectangle().fill(Color.carbon).frame(height: 1.5)
					MathNodeView(node: denominator, size: size * 0.9)
						.padding(.horizontal, 6)
				}
				.fixedSize()
			case .row(let nodes):
				HStack(spacing: 0) {
					ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
						MathNodeView(node: child, size: size)
					}
				}
			default:
				EmptyView()
			}
		}
	}

	/// A single Text for nodes without fractions, using baseline offsets for scripts.
	static func text(_ node: MathNode, size: CGFloat, depth: Int) -> Text? {
		guard depth < MathParser.maxDepth else { return nil }
		switch node {
		case .symbol(let value):
			let spaced = ["=", "+", "−", "-", "×", "·", "≤", "≥", "≠", "≈", "→"].contains(value) ? " \(value) " : value
			let italic = value.count == 1 && value.first?.isLetter == true
			return Text(spaced).font(RescrivaFont.body(size, italic: italic))
		case .row(let nodes):
			var result = Text("")
			for child in nodes {
				guard let piece = text(child, size: size, depth: depth + 1) else { return nil }
				result = result + piece
			}
			return result
		case .scripts(let base, let sub, let sup):
			guard var result = text(base, size: size, depth: depth + 1) else { return nil }
			if let sub {
				guard let piece = text(sub, size: size * 0.62, depth: depth + 1) else { return nil }
				result = result + piece.baselineOffset(-size * 0.22)
			}
			if let sup {
				guard let piece = text(sup, size: size * 0.62, depth: depth + 1) else { return nil }
				result = result + piece.baselineOffset(size * 0.38)
			}
			return result
		case .fraction:
			return nil
		}
	}
}

// MARK: - Diagram

/// A diagram as shapes and arrows. An uncertain arrow is dashed highlighter
/// with a "?" badge that opens its flag.
struct DiagramView: View {
	@Environment(\.documentIsInteractive) private var interactive
	let diagram: Diagram
	let onOpenFlag: (UUID) -> Void

	var body: some View {
		GeometryReader { proxy in
			let size = proxy.size
			ZStack(alignment: .topLeading) {
				Canvas { context, _ in
					for edge in diagram.edges {
						guard let segment = segment(for: edge, in: size) else { continue }
						let unconfirmed = edge.flag != nil && edge.flag?.resolution == nil
						let uncertain = interactive && unconfirmed
						let color = uncertain ? Color.highlighter : Color.carbon
						var line = Path()
						line.move(to: segment.start)
						line.addLine(to: segment.end)
						context.stroke(line, with: .color(color),
									   style: StrokeStyle(lineWidth: uncertain ? 2.5 : 1.5, dash: uncertain ? [5, 4] : []))
						// In the read-only preview an unconfirmed direction is shown as a plain line.
						guard interactive || !unconfirmed else { continue }
						if edge.direction != .none {
							context.fill(arrowhead(at: segment.end, from: segment.start), with: .color(color))
						}
						if edge.direction == .both {
							context.fill(arrowhead(at: segment.start, from: segment.end), with: .color(color))
						}
					}
				}
				ForEach(diagram.nodes) { node in
					NodeShapeView(node: node)
						.frame(width: node.box.width * size.width, height: node.box.height * size.height)
						.position(x: (node.box.x + node.box.width / 2) * size.width,
								  y: (node.box.y + node.box.height / 2) * size.height)
				}
				ForEach(diagram.edges) { edge in
					if interactive, let flag = edge.flag, flag.resolution == nil, let segment = segment(for: edge, in: size) {
						Button {
							onOpenFlag(flag.id)
						} label: {
							Text("?")
								.font(RescrivaFont.ui(14, weight: .medium))
								.foregroundStyle(.printInk)
								.frame(width: 26, height: 26)
								.background(Color.highlighter, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
								.rescrivaShadow(.small)
						}
						.buttonStyle(PressScaleStyle())
						.position(badgePosition(for: segment))
						.accessibilityLabel("Check this arrow")
					}
				}
			}
		}
		.aspectRatio(diagram.aspect, contentMode: .fit)
		.frame(maxWidth: 340)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(Text("Diagram"))
	}

	/// Beside the middle of the arrow, perpendicular to it, so the badge never sits on a shape.
	private func badgePosition(for segment: (start: CGPoint, end: CGPoint)) -> CGPoint {
		let dx = segment.end.x - segment.start.x
		let dy = segment.end.y - segment.start.y
		let length = max(hypot(dx, dy), 1)
		let offset: CGFloat = 18
		return CGPoint(x: (segment.start.x + segment.end.x) / 2 - dy / length * offset,
					   y: (segment.start.y + segment.end.y) / 2 + dx / length * offset)
	}

	/// The centre-to-centre line clipped to both outlines, with a small gap.
	private func segment(for edge: Diagram.Edge, in size: CGSize) -> (start: CGPoint, end: CGPoint)? {
		guard let from = diagram.node(edge.from), let to = diagram.node(edge.to) else { return nil }
		return DiagramGeometry.connector(from: from, to: to, direction: edge.direction, in: size)
	}

	private func arrowhead(at tip: CGPoint, from tail: CGPoint) -> Path {
		DiagramGeometry.arrowhead(at: tip, from: tail)
	}
}

/// One diagram node.
private struct NodeShapeView: View {
	let node: Diagram.Node

	var body: some View {
		let stroke = Color(red: node.stroke.red, green: node.stroke.green, blue: node.stroke.blue)
		let fill = node.fill.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? stroke.opacity(0.12)
		ZStack {
			DiagramNodeOutline(shape: node.shape).fill(fill)
			DiagramNodeOutline(shape: node.shape).stroke(stroke, lineWidth: 1.5)
			GeometryReader { proxy in
				Text(node.label)
					.font(RescrivaFont.ui(13, weight: .medium))
					.foregroundStyle(.carbon)
					.lineLimit(2)
					.minimumScaleFactor(0.6)
					.multilineTextAlignment(.center)
					.padding(.horizontal, max(proxy.size.width * DiagramGeometry.labelInsetFraction(node.shape), 4))
					.frame(width: proxy.size.width, height: proxy.size.height)
			}
		}
		.accessibilityElement(children: .combine)
	}
}

extension EnvironmentValues {
	/// False in the read-only preview: no block selection, no flag links,
	/// no "?" badges and no checkbox toggling.
	@Entry var documentIsInteractive = true
	/// Where figures load their pictures from; nil shows placeholders.
	@Entry var figureImages: FigureImageSource? = nil
}
