//
//  DrawingControls.swift
//  Rescriva (fork of Open Scanner)
//
//  The drawing editor's buttons and pickers: the tool and format buttons,
//  the shape, connector and colour palettes, and the controls for the
//  translucent original. Each picker is a small popover, like Google
//  Drawings' toolbar menus.
//

import SwiftUI

/// A tool or format button: an icon over a short caption, carbon when on.
struct DrawingButton<Icon: View>: View {
	let title: LocalizedStringKey
	var isOn = false
	var isDestructive = false
	let action: () -> Void
	@ViewBuilder let icon: Icon

	var body: some View {
		Button(action: action) {
			VStack(spacing: 3) {
				icon
					.font(.system(size: 17, weight: .regular))
					.frame(width: 26, height: 22)
				Text(title)
					.font(RescrivaFont.ui(10.5, weight: .medium))
					.lineLimit(1)
			}
			.foregroundStyle(isOn ? Color.vellum : (isDestructive ? Color.vermilion : Color.carbon))
			.frame(minWidth: 52, minHeight: 50)
			.padding(.horizontal, 4)
			.background(isOn ? Color.carbon : Color.vellum, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.animation(RescrivaMotion.fast, value: isOn)
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(title))
		.accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
	}
}

/// A small outline of a shape, for buttons and palettes.
struct ShapeIcon: View {
	let shape: Diagram.Shape
	var width: CGFloat = 22
	var height: CGFloat = 15

	var body: some View {
		DiagramNodeOutline(shape: shape)
			.stroke(style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
			.frame(width: width, height: height)
	}
}

/// A short diagonal connector with the heads `direction` draws.
struct ConnectorIcon: View {
	let direction: Diagram.Direction

	var body: some View {
		Canvas { context, size in
			let start = CGPoint(x: 6, y: size.height - 6), end = CGPoint(x: size.width - 6, y: 6)
			var line = Path()
			line.move(to: start)
			line.addLine(to: end)
			context.stroke(line, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
			if direction != .none {
				context.fill(DiagramGeometry.arrowhead(at: end, from: start, length: 4), with: .foreground)
			}
			if direction == .both {
				context.fill(DiagramGeometry.arrowhead(at: start, from: end, length: 4), with: .foreground)
			}
		}
		.frame(width: 26, height: 22)
	}
}

/// "Rectangle, rounded, ellipse, diamond, parallelogram."
struct ShapePalette: View {
	let selected: Diagram.Shape?
	let onPick: (Diagram.Shape) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Shapes").rescrivaSectionLabel()
			HStack(spacing: 8) {
				ForEach(Diagram.Shape.paletteOrder, id: \.self) { shape in
					Button {
						onPick(shape)
					} label: {
						ShapeIcon(shape: shape, width: 32, height: 22)
							.foregroundStyle(.carbon)
							.frame(width: 48, height: 42)
							.background(selected == shape ? Color.wash : Color.stock,
										in: RoundedRectangle(cornerRadius: 10, style: .continuous))
					}
					.buttonStyle(PressScaleStyle())
					.accessibilityLabel(Text(shape.displayName))
					.accessibilityAddTraits(selected == shape ? .isSelected : [])
				}
			}
		}
		.padding(14)
		.presentationCompactAdaptation(.popover)
		.presentationBackground(Color.vellum)
	}
}

/// "Arrow, line, double arrow."
struct ConnectorPalette: View {
	let selected: Diagram.Direction?
	let onPick: (Diagram.Direction) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Lines").rescrivaSectionLabel()
			HStack(spacing: 8) {
				ForEach([Diagram.Direction.forward, .none, .both], id: \.self) { direction in
					Button {
						onPick(direction)
					} label: {
						VStack(spacing: 4) {
							ConnectorIcon(direction: direction)
							Text(direction.displayName)
								.font(RescrivaFont.ui(11, weight: .medium))
						}
						.foregroundStyle(.carbon)
						.frame(width: 78, height: 54)
						.background(selected == direction ? Color.wash : Color.stock,
									in: RoundedRectangle(cornerRadius: 10, style: .continuous))
					}
					.buttonStyle(PressScaleStyle())
					.accessibilityElement(children: .combine)
					.accessibilityAddTraits(selected == direction ? .isSelected : [])
				}
			}
		}
		.padding(14)
		.presentationCompactAdaptation(.popover)
		.presentationBackground(Color.vellum)
	}
}

/// Border and fill swatches for the selected shape (and the next one drawn).
struct ColourPalette: View {
	let stroke: RGBColor
	let fill: RGBColor?
	let onStroke: (RGBColor) -> Void
	let onFill: (RGBColor?) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Border").rescrivaSectionLabel()
			swatches(DrawingPalette.borders, selected: stroke) { swatch in
				if let color = swatch.color { onStroke(color) }
			}
			Text("Fill").rescrivaSectionLabel()
			swatches(DrawingPalette.fills, selected: fill) { swatch in onFill(swatch.color) }
		}
		.padding(14)
		.presentationCompactAdaptation(.popover)
		.presentationBackground(Color.vellum)
	}

	private func swatches(_ list: [DrawingPalette.Swatch], selected: RGBColor?, pick: @escaping (DrawingPalette.Swatch) -> Void) -> some View {
		HStack(spacing: 10) {
			ForEach(list) { swatch in
				Button {
					pick(swatch)
				} label: {
					SwatchDot(color: swatch.color, isSelected: swatch.color == selected)
				}
				.buttonStyle(PressScaleStyle())
				.accessibilityLabel(Text(swatch.name))
				.accessibilityAddTraits(swatch.color == selected ? .isSelected : [])
			}
		}
	}
}

/// One colour swatch; "none" is a slashed circle.
struct SwatchDot: View {
	let color: RGBColor?
	let isSelected: Bool

	var body: some View {
		ZStack {
			Circle().fill(color?.swiftUI ?? Color.paper)
			Circle().strokeBorder(Color.rim, lineWidth: 1)
			if color == nil {
				Rectangle().fill(Color.vermilion).frame(width: 1.5, height: 30).rotationEffect(.degrees(45))
			}
		}
		.frame(width: 30, height: 30)
		.clipShape(Circle())
		.padding(3)
		.overlay { Circle().strokeBorder(isSelected ? Color.ink : Color.clear, lineWidth: 2) }
	}
}

/// The selected shape's border and fill, as a button icon.
struct ColourIcon: View {
	let stroke: RGBColor
	let fill: RGBColor?

	var body: some View {
		ZStack {
			Circle().fill(fill?.swiftUI ?? Color.paper)
			Circle().strokeBorder(stroke.swiftUI, lineWidth: 3)
		}
		.frame(width: 20, height: 20)
	}
}

/// Show or hide the original behind the canvas, and how see-through it is.
struct BackdropControls: View {
	@Binding var isShown: Bool
	@Binding var opacity: Double

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Toggle(isOn: $isShown) {
				Text("Show the original")
					.font(RescrivaFont.ui(15, weight: .medium))
					.foregroundStyle(.carbon)
			}
			.toggleStyle(RescrivaToggleStyle())
			VStack(alignment: .leading, spacing: 6) {
				HStack {
					Text("See-through").font(RescrivaFont.ui(13)).foregroundStyle(.graphite)
					Spacer()
					Text("\(Int((opacity * 100).rounded()))%").font(RescrivaFont.ui(13, weight: .medium)).foregroundStyle(.carbon)
				}
				Slider(value: $opacity, in: 0.1...0.8)
					.tint(.ink)
					.accessibilityLabel(Text("Original's opacity"))
			}
			.disabled(!isShown)
			.opacity(isShown ? 1 : 0.4)
		}
		.padding(16)
		.frame(width: 270)
		.presentationCompactAdaptation(.popover)
		.presentationBackground(Color.vellum)
	}
}
