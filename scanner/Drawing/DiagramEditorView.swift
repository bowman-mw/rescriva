//
//  DiagramEditorView.swift
//  Rescriva (fork of Open Scanner)
//
//  "Recreate": a Google Drawings–style editor for a diagram, opened from a
//  figure or diagram in Review & fix. The original sits translucent behind
//  the canvas so its boxes and arrows can be traced, and a traced shape
//  picks up the page's text under it as its label. The toolbar holds the
//  tools; a format bar for whatever is selected appears above it.
//

import SwiftUI

struct DiagramEditorView: View {
	@Environment(\.dismiss) private var dismiss
	@State private var model: DiagramEditorModel
	@State private var showsBackdrop: Bool
	@State private var backdropOpacity = 0.4
	@State private var editingLabel = false
	@State private var labelTarget: DrawingSelection?
	@State private var confirmingDiscard = false
	@State private var popover: EditorPopover?
	@State private var lastShape: Diagram.Shape?
	@State private var lastDirection: Diagram.Direction?
	@FocusState private var labelFocused: Bool

	private let backdrop: UIImage?
	private let onDone: (Diagram) -> Void

	/// Which of the editor's popovers is open.
	private enum EditorPopover: Hashable {
		case shapes, connectors, backdrop, nodeShape, colours
	}

	init(request: RecreateRequest, onDone: @escaping (Diagram) -> Void) {
		_model = State(initialValue: DiagramEditorModel(diagram: request.diagram, traceLines: request.traceLines))
		_showsBackdrop = State(initialValue: request.backdrop != nil)
		backdrop = request.backdrop
		self.onDone = onDone
	}

	var body: some View {
		VStack(spacing: 0) {
			topBar
			ZStack(alignment: .top) {
				DiagramCanvasView(model: model, backdrop: showsBackdrop ? backdrop : nil, backdropOpacity: backdropOpacity,
								  fillOpacity: showsBackdrop && backdrop != nil ? 0.55 : 1)
				canvasChrome
			}
			FrostedBottomBar {
				if editingLabel {
					labelBar
				} else if let node = model.selectedNode {
					nodeFormatBar(node)
				} else if let edge = model.selectedEdge {
					edgeFormatBar(edge)
				}
				toolBar
			}
		}
		.background(Color.stock.ignoresSafeArea())
		.onChange(of: model.labelRequest) { _, _ in openLabelEditor() }
		.onChange(of: model.selection) { _, selection in
			if editingLabel && selection != labelTarget { closeLabelEditor() }
		}
		.confirmationDialog("Discard this drawing?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
			Button("Discard", role: .destructive) { dismiss() }
			Button("Keep drawing", role: .cancel) {}
		}
	}

	// MARK: Top bar and canvas chrome

	private var topBar: some View {
		HStack(spacing: 8) {
			Button("Cancel") {
				if model.hasChanges { confirmingDiscard = true } else { dismiss() }
			}
			.font(RescrivaFont.ui(15, weight: .medium))
			.foregroundStyle(.ink)
			.frame(height: 40)
			.padding(.horizontal, 8)
			Spacer()
			CircleIconButton(systemName: "arrow.uturn.backward", label: "Undo") { model.undo() }
				.disabled(!model.canUndo)
				.opacity(model.canUndo ? 1 : 0.4)
			CircleIconButton(systemName: "arrow.uturn.forward", label: "Redo") { model.redo() }
				.disabled(!model.canRedo)
				.opacity(model.canRedo ? 1 : 0.4)
			Button {
				finish()
			} label: {
				Text("Done")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.vellum)
					.frame(height: 40)
					.padding(.horizontal, 18)
					.background(Color.carbon, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
			}
			.buttonStyle(PressScaleStyle(scale: 0.94))
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	private var canvasChrome: some View {
		HStack(alignment: .top) {
			if let hint {
				Text(hint)
					.font(RescrivaFont.ui(12, weight: .medium))
					.foregroundStyle(.carbon)
					.padding(.vertical, 6)
					.padding(.horizontal, 12)
					.background(Color.vellum.opacity(0.94), in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
					.rescrivaShadow(.small)
					.allowsHitTesting(false)
					.transition(.opacity)
			}
			Spacer(minLength: 8)
			if model.zoom > 1.01 {
				Button {
					withAnimation(RescrivaMotion.ui) { model.resetZoom() }
				} label: {
					Text("\(Int((model.zoom * 100).rounded()))%")
						.font(RescrivaFont.ui(12, weight: .medium))
						.foregroundStyle(.carbon)
						.padding(.vertical, 6)
						.padding(.horizontal, 10)
						.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
						.rescrivaShadow(.small)
				}
				.buttonStyle(PressScaleStyle())
				.accessibilityLabel(Text("Zoom \(Int((model.zoom * 100).rounded())) percent"))
				.accessibilityHint(Text("Shows the whole drawing"))
			}
		}
		.padding(12)
		.animation(RescrivaMotion.ui, value: hint)
	}

	private var hint: LocalizedStringKey? {
		switch model.tool {
		case .shape: return "Drag to draw · tap Shape again for others"
		case .connector: return "Drag from one shape to another"
		case .select:
			guard model.diagram.nodes.isEmpty else { return nil }
			return backdrop == nil ? "Pick a shape to start drawing" : "Pick a shape, then trace over the original"
		}
	}

	// MARK: Toolbar

	private var toolBar: some View {
		HStack(spacing: 8) {
			DrawingButton(title: "Select", isOn: model.tool == .select, action: { model.selectTool(.select) }) {
				Image(systemName: "cursorarrow")
			}
			DrawingButton(title: "Shape", isOn: activeShape != nil, action: shapeTapped) {
				ShapeIcon(shape: lastShape ?? .rectangle)
			}
			.popover(isPresented: isOpen(.shapes), arrowEdge: .bottom) {
				ShapePalette(selected: activeShape ?? lastShape) { shape in
					lastShape = shape
					model.selectTool(.shape(shape))
					popover = nil
				}
			}
			DrawingButton(title: "Line", isOn: activeDirection != nil, action: connectorTapped) {
				ConnectorIcon(direction: lastDirection ?? .forward)
			}
			.popover(isPresented: isOpen(.connectors), arrowEdge: .bottom) {
				ConnectorPalette(selected: activeDirection ?? lastDirection) { direction in
					lastDirection = direction
					model.selectTool(.connector(direction))
					popover = nil
				}
			}
			Spacer(minLength: 0)
			if backdrop != nil {
				DrawingButton(title: "Original", isOn: showsBackdrop, action: { popover = .backdrop }) {
					Image(systemName: showsBackdrop ? "eye" : "eye.slash")
				}
				.popover(isPresented: isOpen(.backdrop), arrowEdge: .bottom) {
					BackdropControls(isShown: $showsBackdrop, opacity: $backdropOpacity)
				}
			}
		}
	}

	private var activeShape: Diagram.Shape? {
		guard case .shape(let shape) = model.tool else { return nil }
		return shape
	}

	private var activeDirection: Diagram.Direction? {
		guard case .connector(let direction) = model.tool else { return nil }
		return direction
	}

	/// The first tap arms the last shape used; tapping again (or the first time) shows them all.
	private func shapeTapped() {
		guard activeShape == nil, let lastShape else {
			popover = .shapes
			return
		}
		model.selectTool(.shape(lastShape))
	}

	private func connectorTapped() {
		guard activeDirection == nil, let lastDirection else {
			popover = .connectors
			return
		}
		model.selectTool(.connector(lastDirection))
	}

	private func isOpen(_ which: EditorPopover) -> Binding<Bool> {
		Binding(get: { popover == which }, set: { if !$0, popover == which { popover = nil } })
	}

	// MARK: Format bars

	private func nodeFormatBar(_ node: Diagram.Node) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				DrawingButton(title: "Text", action: { openLabelEditor() }) { Image(systemName: "character.cursor.ibeam") }
				DrawingButton(title: "Change", action: { popover = .nodeShape }) { ShapeIcon(shape: node.shape) }
					.popover(isPresented: isOpen(.nodeShape), arrowEdge: .bottom) {
						ShapePalette(selected: node.shape) { shape in
							model.setShape(shape)
							popover = nil
						}
					}
				DrawingButton(title: "Colour", action: { popover = .colours }) { ColourIcon(stroke: node.stroke, fill: node.fill) }
					.popover(isPresented: isOpen(.colours), arrowEdge: .bottom) {
						ColourPalette(stroke: node.stroke, fill: node.fill,
									  onStroke: { model.setStroke($0) }, onFill: { model.setFill($0) })
					}
				DrawingButton(title: "Copy", action: { model.duplicateSelection() }) { Image(systemName: "plus.square.on.square") }
				DrawingButton(title: "Front", action: { model.reorderSelection(toFront: true) }) { Image(systemName: "square.2.layers.3d.top.filled") }
				DrawingButton(title: "Back", action: { model.reorderSelection(toFront: false) }) { Image(systemName: "square.2.layers.3d.bottom.filled") }
				DrawingButton(title: "Delete", isDestructive: true, action: { model.deleteSelection() }) { Image(systemName: "trash") }
			}
			.padding(.horizontal, 1)
		}
	}

	private func edgeFormatBar(_ edge: Diagram.Edge) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				ForEach([Diagram.Direction.forward, .none, .both], id: \.self) { direction in
					DrawingButton(title: directionTitle(direction), isOn: edge.direction == direction,
								  action: { model.setDirection(direction) }) {
						ConnectorIcon(direction: direction)
					}
				}
				DrawingButton(title: "Swap", action: { model.reverseSelection() }) { Image(systemName: "arrow.left.arrow.right") }
				DrawingButton(title: "Label", action: { openLabelEditor() }) { Image(systemName: "character.cursor.ibeam") }
				if edge.flag != nil, edge.flag?.resolution == nil {
					DrawingButton(title: "Looks right", action: { model.confirmSelectedEdge() }) { Image(systemName: "checkmark") }
				}
				DrawingButton(title: "Delete", isDestructive: true, action: { model.deleteSelection() }) { Image(systemName: "trash") }
			}
			.padding(.horizontal, 1)
		}
	}

	private func directionTitle(_ direction: Diagram.Direction) -> LocalizedStringKey {
		switch direction {
		case .forward: return "Arrow"
		case .none: return "Line"
		case .both: return "Both ways"
		}
	}

	// MARK: Labels

	private var labelBar: some View {
		HStack(spacing: 10) {
			TextField(model.selectedEdge == nil ? "Label the shape" : "Label the line",
					  text: Binding(get: { model.selectedLabel }, set: { model.setLabel($0) }))
				.font(RescrivaFont.ui(16))
				.foregroundStyle(.carbon)
				.focused($labelFocused)
				.submitLabel(.done)
				.onSubmit { closeLabelEditor() }
				.onAppear { labelFocused = true }
				.padding(.horizontal, 14)
				.frame(height: 46)
				.background(Color.vellum, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			Button("Done") { closeLabelEditor() }
				.font(RescrivaFont.ui(15, weight: .medium))
				.foregroundStyle(.ink)
				.frame(height: 46)
		}
	}

	private func openLabelEditor() {
		guard model.selection != nil else { return }
		model.beginLabelEdit()
		labelTarget = model.selection
		editingLabel = true
		labelFocused = true
	}

	private func closeLabelEditor() {
		model.endLabelEdit()
		editingLabel = false
		labelFocused = false
		labelTarget = nil
	}

	private func finish() {
		closeLabelEditor()
		if model.hasChanges { onDone(model.diagram) }
		dismiss()
	}
}
