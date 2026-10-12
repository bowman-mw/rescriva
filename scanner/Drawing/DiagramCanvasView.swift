//
//  DiagramCanvasView.swift
//  Rescriva (fork of Open Scanner)
//
//  The drawing editor's canvas: paper with the original translucent behind,
//  the connectors, the shapes, and an overlay for the selection handles,
//  connection points, smart guides and whatever is being dragged out. One
//  drag gesture and one pinch drive the model. Every layer is drawn in
//  screen points from the model's canvas geometry, so text stays sharp at
//  any zoom.
//

import SwiftUI

struct DiagramCanvasView: View {
	let model: DiagramEditorModel
	let backdrop: UIImage?
	let backdropOpacity: Double
	/// Shape fills are see-through while the original shows, so its text stays readable.
	let fillOpacity: Double

	var body: some View {
		GeometryReader { proxy in
			ZStack(alignment: .topLeading) {
				paper
				CanvasEdges(model: model)
				nodes
				CanvasOverlay(model: model)
				CanvasAccessibility(model: model)
			}
			.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
			.contentShape(Rectangle())
			.gesture(touches.simultaneously(with: pinch))
			.onAppear { model.layout(in: proxy.size) }
			.onChange(of: proxy.size) { _, size in model.layout(in: size) }
		}
		.clipped()
		// The drawing is on paper, so it keeps its paper colours in the dark.
		.environment(\.colorScheme, .light)
	}

	private var paper: some View {
		let frame = model.toView(CGRect(origin: .zero, size: model.canvasSize))
		return ZStack {
			Color.paper
			if let backdrop {
				Image(uiImage: backdrop)
					.resizable()
					.interpolation(.high)
					.opacity(backdropOpacity)
			} else {
				DotGrid(spacing: 16 * model.zoom)
			}
		}
		.frame(width: frame.width, height: frame.height)
		.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
		.rescrivaShadow(.card)
		.offset(x: frame.minX, y: frame.minY)
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}

	private var nodes: some View {
		ForEach(model.diagram.nodes) { node in
			let frame = model.toView(model.rect(of: node))
			CanvasNode(node: node, zoom: model.zoom, width: frame.width, fillOpacity: fillOpacity)
				.frame(width: frame.width, height: frame.height)
				.position(x: frame.midX, y: frame.midY)
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}

	private var touches: some Gesture {
		DragGesture(minimumDistance: 0)
			.onChanged { value in model.touchChanged(start: value.startLocation, location: value.location) }
			.onEnded { value in model.touchEnded(start: value.startLocation, location: value.location) }
	}

	private var pinch: some Gesture {
		MagnifyGesture()
			.onChanged { value in model.pinchChanged(scale: value.magnification, anchor: value.startLocation) }
			.onEnded { _ in model.pinchEnded() }
	}
}

/// One shape, drawn at its on-screen size.
private struct CanvasNode: View {
	let node: Diagram.Node
	let zoom: CGFloat
	let width: CGFloat
	let fillOpacity: Double

	var body: some View {
		let outline = DiagramNodeOutline(shape: node.shape)
		ZStack {
			outline.fill((node.fill?.swiftUI ?? Color.clear).opacity(fillOpacity))
			outline.stroke(node.stroke.swiftUI, lineWidth: 1.5 * zoom)
			Text(node.label)
				.font(RescrivaFont.ui(13 * zoom, weight: .medium))
				.foregroundStyle(.carbon)
				.multilineTextAlignment(.center)
				.lineLimit(4)
				.minimumScaleFactor(0.5)
				.padding(.horizontal, textInset)
				.padding(.vertical, 2 * zoom)
		}
	}

	/// Keeps the label inside the slanted or curved sides.
	private var textInset: CGFloat {
		max(width * DiagramGeometry.labelInsetFraction(node.shape), 4 * zoom)
	}
}

/// The connectors, under the shapes.
private struct CanvasEdges: View {
	let model: DiagramEditorModel

	var body: some View {
		Canvas { context, _ in
			for edge in model.diagram.edges.prefix(Diagram.maxEditableEdges) {
				guard let line = model.segment(of: edge) else { continue }
				draw(edge, from: model.toView(line.start), to: model.toView(line.end), in: context)
			}
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}

	private func draw(_ edge: Diagram.Edge, from start: CGPoint, to end: CGPoint, in context: GraphicsContext) {
		let zoom = model.zoom
		let uncertain = edge.flag != nil && edge.flag?.resolution == nil
		let colour = uncertain ? Color.highlighter : Color.carbon
		var line = Path()
		line.move(to: start)
		line.addLine(to: end)
		if model.selection == .edge(edge.id) {
			context.stroke(line, with: .color(Color.ink.opacity(0.3)), style: StrokeStyle(lineWidth: 10, lineCap: .round))
		}
		context.stroke(line, with: .color(colour),
					   style: StrokeStyle(lineWidth: 1.5 * zoom, lineCap: .round, dash: uncertain ? [5 * zoom, 4 * zoom] : []))
		let head = DiagramGeometry.arrowheadLength * zoom
		if edge.direction != .none {
			context.fill(DiagramGeometry.arrowhead(at: end, from: start, length: head), with: .color(colour))
		}
		if edge.direction == .both {
			context.fill(DiagramGeometry.arrowhead(at: start, from: end, length: head), with: .color(colour))
		}
		if let label = edge.label, !label.isEmpty {
			drawLabel(label, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), zoom: zoom, in: context)
		}
	}

	/// A connector's label on a paper chip at the middle of the line.
	private func drawLabel(_ label: String, at centre: CGPoint, zoom: CGFloat, in context: GraphicsContext) {
		let text = context.resolve(Text(label).font(RescrivaFont.ui(12 * zoom)).foregroundStyle(Color.carbon))
		let size = text.measure(in: CGSize(width: 180 * zoom, height: 60 * zoom))
		let chip = CGRect(x: centre.x - size.width / 2 - 4 * zoom, y: centre.y - size.height / 2 - 2 * zoom,
						  width: size.width + 8 * zoom, height: size.height + 4 * zoom)
		context.fill(Path(roundedRect: chip, cornerRadius: 4 * zoom), with: .color(Color.paper.opacity(0.92)))
		context.draw(text, in: chip.insetBy(dx: 4 * zoom, dy: 2 * zoom))
	}
}

/// Selection handles, connection points, smart guides and in-progress drags.
private struct CanvasOverlay: View {
	let model: DiagramEditorModel

	var body: some View {
		Canvas { context, _ in
			drawGuides(in: context)
			drawDraft(in: context)
			drawConnectionTargets(in: context)
			drawSelection(in: context)
			drawPendingConnector(in: context)
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}

	private func drawGuides(in context: GraphicsContext) {
		for guide in model.guides {
			var path = Path()
			switch guide.axis {
			case .vertical:
				path.move(to: model.toView(CGPoint(x: guide.position, y: guide.from)))
				path.addLine(to: model.toView(CGPoint(x: guide.position, y: guide.to)))
			case .horizontal:
				path.move(to: model.toView(CGPoint(x: guide.from, y: guide.position)))
				path.addLine(to: model.toView(CGPoint(x: guide.to, y: guide.position)))
			}
			context.stroke(path, with: .color(.vermilion), lineWidth: 1)
		}
	}

	private func drawDraft(in context: GraphicsContext) {
		guard let draft = model.draft, case .shape(let shape) = model.tool else { return }
		let outline = DiagramGeometry.outline(shape, in: model.toView(draft))
		context.fill(outline, with: .color(Color.ink.opacity(0.12)))
		context.stroke(outline, with: .color(.ink), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
	}

	/// With the line tool, every shape shows where a connector can start.
	private func drawConnectionTargets(in context: GraphicsContext) {
		guard case .connector = model.tool else { return }
		for node in model.diagram.nodes {
			let box = model.rect(of: node)
			let sides = [CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.maxX, y: box.midY),
						 CGPoint(x: box.midX, y: box.maxY), CGPoint(x: box.minX, y: box.midY)]
			for side in sides {
				let point = model.toView(side)
				context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)), with: .color(.graphite))
			}
		}
	}

	private func drawSelection(in context: GraphicsContext) {
		if let edge = model.selectedEdge, let line = model.segment(of: edge) {
			for end in [line.start, line.end] { dot(at: model.toView(end), radius: 4.5, in: context) }
		}
		guard model.tool == .select, let node = model.selectedNode else { return }
		let box = model.rect(of: node)
		context.stroke(Path(model.toView(box)), with: .color(.ink), lineWidth: 1)
		for point in model.connectionPoints(around: box) {
			let centre = model.toView(point)
			context.fill(Path(ellipseIn: CGRect(x: centre.x - 6, y: centre.y - 6, width: 12, height: 12)), with: .color(.ink))
			context.stroke(Path(ellipseIn: CGRect(x: centre.x - 6, y: centre.y - 6, width: 12, height: 12)), with: .color(.paper), lineWidth: 2)
		}
		for handle in ResizeHandle.allCases {
			dot(at: model.toView(handle.point(in: box)), radius: 5.5, in: context)
		}
	}

	private func dot(at centre: CGPoint, radius: CGFloat, in context: GraphicsContext) {
		let circle = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
		context.fill(circle, with: .color(.paper))
		context.stroke(circle, with: .color(.ink), lineWidth: 1.5)
	}

	private func drawPendingConnector(in context: GraphicsContext) {
		guard let pending = model.pendingConnector, let source = model.diagram.node(pending.from) else { return }
		let from = model.rect(of: source)
		let target = pending.target.flatMap { model.diagram.node($0) }.map(model.rect(of:))
		let end = target.map { CGPoint(x: $0.midX, y: $0.midY) } ?? pending.end
		let centre = CGPoint(x: from.midX, y: from.midY)
		let delta = CGVector(dx: end.x - centre.x, dy: end.y - centre.y)
		let exit = DiagramGeometry.exitFraction(source.shape, in: from, toward: delta)
		let start = model.toView(CGPoint(x: centre.x + delta.dx * exit, y: centre.y + delta.dy * exit))
		let finish = model.toView(end)
		if let target {
			context.stroke(Path(model.toView(target).insetBy(dx: -3, dy: -3)), with: .color(.ink), lineWidth: 2.5)
		}
		var line = Path()
		line.move(to: start)
		line.addLine(to: finish)
		context.stroke(line, with: .color(.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
		if pending.direction != .none {
			context.fill(DiagramGeometry.arrowhead(at: finish, from: start), with: .color(.ink))
		}
	}
}

/// VoiceOver's view of the canvas: each shape and connector is an element
/// with actions, since dragging isn't available there.
private struct CanvasAccessibility: View {
	let model: DiagramEditorModel

	var body: some View {
		ZStack(alignment: .topLeading) {
			ForEach(model.diagram.nodes) { node in
				let frame = model.toView(model.rect(of: node))
				Color.clear
					.frame(width: frame.width, height: frame.height)
					.position(x: frame.midX, y: frame.midY)
					.accessibilityElement()
					.accessibilityLabel(Text(node.label.isEmpty ? node.shape.displayName : "\(node.label), \(node.shape.displayName)"))
					.accessibilityAddTraits(model.selection == .node(node.id) ? [.isButton, .isSelected] : .isButton)
					.accessibilityAction { model.selection = .node(node.id) }
					.accessibilityAction(named: "Move left") { nudge(node.id, dx: -0.04, dy: 0) }
					.accessibilityAction(named: "Move right") { nudge(node.id, dx: 0.04, dy: 0) }
					.accessibilityAction(named: "Move up") { nudge(node.id, dx: 0, dy: -0.04) }
					.accessibilityAction(named: "Move down") { nudge(node.id, dx: 0, dy: 0.04) }
			}
			ForEach(model.diagram.edges) { edge in
				if let line = model.segment(of: edge) {
					let centre = model.toView(CGPoint(x: (line.start.x + line.end.x) / 2, y: (line.start.y + line.end.y) / 2))
					Color.clear
						.frame(width: 28, height: 28)
						.position(centre)
						.accessibilityElement()
						.accessibilityLabel(Text(description(of: edge)))
						.accessibilityAddTraits(model.selection == .edge(edge.id) ? [.isButton, .isSelected] : .isButton)
						.accessibilityAction { model.selection = .edge(edge.id) }
				}
			}
		}
		.allowsHitTesting(false)
	}

	private func nudge(_ id: String, dx: Double, dy: Double) {
		model.selection = .node(id)
		model.nudgeSelection(dx: dx, dy: dy)
	}

	private func description(of edge: Diagram.Edge) -> String {
		let from = model.diagram.node(edge.from)?.label ?? "", to = model.diagram.node(edge.to)?.label ?? ""
		return "\(from) \(edge.direction.textConnector) \(to), \(edge.direction.displayName)"
	}
}

/// Faint dots that help line shapes up on a blank canvas.
private struct DotGrid: View {
	let spacing: CGFloat

	var body: some View {
		Canvas { context, size in
			guard spacing >= 4 else { return }
			let columns = min(Int(size.width / spacing), 400), rows = min(Int(size.height / spacing), 400)
			guard columns > 0, rows > 0 else { return }
			for column in 1...columns {
				for row in 1...rows {
					let point = CGPoint(x: CGFloat(column) * spacing, y: CGFloat(row) * spacing)
					context.fill(Path(ellipseIn: CGRect(x: point.x - 0.75, y: point.y - 0.75, width: 1.5, height: 1.5)),
								 with: .color(Color.carbon.opacity(0.12)))
				}
			}
		}
	}
}
