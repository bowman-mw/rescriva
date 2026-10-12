//
//  PDFMarkupToolbar.swift
//  Rescriva (fork of Open Scanner)
//
//  The markup bar under a PDF: the tools, then the chosen tool's colors (the palette and any
//  color beyond it) and size. Sizes sit on a notched slider: inline where the bar is wide, in a
//  popover from the size button on an iPhone (tapping the chosen tool again opens it too, as in
//  Notes). With a mark picked, the same controls change that mark, beside Edit and Delete. Two
//  short rows, so the page keeps the screen; the tool's tip floats over the page and fades.
//

import SwiftUI
import UIKit

struct MarkupToolbar: View {
	@Bindable var session: PDFEditSession
	/// Wide enough for the size slider beside the colors.
	var isWide: Bool
	let onEditText: (PDFMarkSelection) -> Void

	@State private var showsSizes = false

	var body: some View {
		VStack(spacing: 8) {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 2) {
					ForEach(PDFMarkupTool.allCases) { tool in
						MarkupToolButton(tool: tool, isSelected: session.tool == tool) { choose(tool) }
					}
				}
			}
			// The pointer with nothing picked, and the eraser, have no colors: the bar stays one row.
			if session.currentStyleGroup != nil || session.selection != nil {
				optionsRow
			}
		}
		.padding(.horizontal, 14)
		.padding(.top, 10)
		.padding(.bottom, 2)
		.frame(maxWidth: .infinity)
		.background {
			UnevenRoundedRectangle(topLeadingRadius: RescrivaRadius.large, topTrailingRadius: RescrivaRadius.large, style: .continuous)
				.fill(.ultraThinMaterial)
				.overlay {
					UnevenRoundedRectangle(topLeadingRadius: RescrivaRadius.large, topTrailingRadius: RescrivaRadius.large, style: .continuous)
						.fill(Color.stock.opacity(0.78))
				}
				.rescrivaShadow(.sheet)
				.ignoresSafeArea(edges: .bottom)
		}
		.overlay(alignment: .top) {
			MarkupHint(session: session)
				.alignmentGuide(.top) { $0[.bottom] + 10 }
		}
	}

	/// Choosing the tool that's already chosen opens its sizes, as in Notes.
	private func choose(_ tool: PDFMarkupTool) {
		if session.tool == tool {
			if tool.hasSizes && !isWide { showsSizes = true }
		} else {
			withAnimation(RescrivaMotion.fast) { session.tool = tool }
		}
	}

	@ViewBuilder
	private var optionsRow: some View {
		HStack(spacing: 0) {
			if let group = session.currentStyleGroup, let style = session.currentStyle {
				colors(group, style: style)
				if session.currentHasSizes {
					divider
					if isWide {
						NotchedSizeSlider(sizes: group.sizes, value: style.size, color: session.currentColor) { session.selectSize($0) }
							.frame(maxWidth: 320)
					} else {
						sizeButton(group, style: style)
					}
				}
			} else {
				Spacer(minLength: 0)
			}
			if let selection = session.selection {
				divider
				selectionActions(selection)
			}
		}
		.frame(height: 36)
	}

	private func colors(_ group: PDFMarkupStyleGroup, style: PDFMarkupStyle) -> some View {
		HStack(spacing: 0) {
			ForEach(Array(group.swatches.enumerated()), id: \.element.id) { index, swatch in
				MarkupSwatchButton(swatch: swatch, isSelected: style.color == .swatch(index)) { session.selectColor(.swatch(index)) }
					.frame(maxWidth: .infinity)
			}
			MarkupColorWell(color: session.currentColor, isSelected: isCustom(style.color)) { session.selectColor(.custom($0.markRGB)) }
				.frame(maxWidth: .infinity)
		}
	}

	private func isCustom(_ color: PDFMarkupColor) -> Bool {
		if case .custom = color { return true }
		return false
	}

	/// The current size as a dot; opens the notched slider.
	private func sizeButton(_ group: PDFMarkupStyleGroup, style: PDFMarkupStyle) -> some View {
		Button { showsSizes = true } label: {
			SizeDot(size: style.size, sizes: group.sizes, color: session.currentColor)
				.frame(width: 36, height: 36)
				.background(Circle().fill(Color.carbon.opacity(showsSizes ? 0.14 : 0.06)))
				.contentShape(Circle())
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel("Size")
		.accessibilityValue(Text(NotchedSizeSlider.label(style.size)))
		.popover(isPresented: $showsSizes, arrowEdge: .bottom) {
			VStack(alignment: .leading, spacing: 10) {
				Text("Size")
					.font(RescrivaFont.ui(13, weight: .medium))
					.foregroundStyle(.graphite)
				NotchedSizeSlider(sizes: group.sizes, value: session.currentStyle?.size ?? style.size, color: session.currentColor) { session.selectSize($0) }
			}
			.padding(16)
			.frame(width: 300)
			.presentationCompactAdaptation(.popover)
			.presentationBackground(Color.vellum)
		}
	}

	private func selectionActions(_ selection: PDFMarkSelection) -> some View {
		HStack(spacing: 2) {
			if selection.hasText {
				MarkupActionButton(systemName: "character.cursor.ibeam", label: "Edit text") { onEditText(selection) }
			}
			MarkupActionButton(systemName: "trash", label: "Delete") {
				withAnimation(RescrivaMotion.fast) { session.deleteSelection() }
			}
		}
	}

	private var divider: some View {
		Rectangle()
			.fill(Color.carbon.opacity(0.14))
			.frame(width: 1, height: 22)
			.padding(.horizontal, 6)
			.accessibilityHidden(true)
	}
}

// MARK: - Tip

/// The tool's tip, floating over the page above the bar: shown when the tool or the picked mark
/// changes, gone after a moment, so it costs the bar no height.
private struct MarkupHint: View {
	let session: PDFEditSession
	@State private var isShown = false

	private var text: LocalizedStringKey {
		session.selection != nil ? "Drag to move it, or change its color" : session.tool.hint(pencilOnly: session.pencilOnly)
	}

	var body: some View {
		Text(text)
			.font(RescrivaFont.ui(13, weight: .medium))
			.foregroundStyle(.carbon)
			.padding(.vertical, 7)
			.padding(.horizontal, 14)
			.background(Color.vellum.opacity(0.96), in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
			.rescrivaShadow(.small)
			.opacity(isShown ? 1 : 0)
			.allowsHitTesting(false)
			.task(id: "\(session.tool.rawValue)-\(session.selection != nil)-\(session.pencilOnly)") {
				withAnimation(RescrivaMotion.ui) { isShown = true }
				do {
					try await Task.sleep(for: .seconds(2.6))
				} catch {
					return
				}
				withAnimation(RescrivaMotion.load) { isShown = false }
			}
	}
}

// MARK: - Size slider

/// Sizes on a notched track: the thumb snaps to each notch with a tick of haptics, a dot beside it
/// shows the stroke, and the value reads in points.
struct NotchedSizeSlider: View {
	let sizes: [CGFloat]
	let value: CGFloat
	let color: UIColor
	let onChange: (CGFloat) -> Void

	private var index: Int {
		sizes.indices.min { abs(sizes[$0] - value) < abs(sizes[$1] - value) } ?? 0
	}

	/// "3 pt", "0.5 pt".
	static func label(_ size: CGFloat) -> String {
		"\(Double(size).formatted(.number.precision(.fractionLength(0...1)))) pt"
	}

	var body: some View {
		HStack(spacing: 10) {
			SizeDot(size: value, sizes: sizes, color: color)
				.frame(width: 28, height: 28)
			track
				.frame(height: 28)
			Text(Self.label(value))
				.font(RescrivaFont.ui(12, weight: .medium))
				.foregroundStyle(.graphite)
				.monospacedDigit()
				.frame(width: 44, alignment: .trailing)
		}
		.sensoryFeedback(.selection, trigger: index)
		.accessibilityElement()
		.accessibilityLabel("Size")
		.accessibilityValue(Text(Self.label(value)))
		.accessibilityAdjustableAction { direction in
			switch direction {
			case .increment: step(by: 1)
			case .decrement: step(by: -1)
			@unknown default: break
			}
		}
	}

	private var track: some View {
		GeometryReader { proxy in
			let width = proxy.size.width
			let spacing = sizes.count > 1 ? width / CGFloat(sizes.count - 1) : 0
			ZStack(alignment: .leading) {
				Capsule().fill(Color.carbon.opacity(0.14)).frame(height: 4)
				Capsule().fill(Color.carbon.opacity(0.55)).frame(width: CGFloat(index) * spacing, height: 4)
				ForEach(sizes.indices, id: \.self) { notch in
					Circle()
						.fill(notch <= index ? Color.carbon.opacity(0.7) : Color.carbon.opacity(0.28))
						.frame(width: 5, height: 5)
						.offset(x: CGFloat(notch) * spacing - 2.5)
				}
				Circle()
					.fill(Color.vellum)
					.overlay(Circle().strokeBorder(Color.carbon.opacity(0.2), lineWidth: 1))
					.frame(width: 22, height: 22)
					.rescrivaShadow(.small)
					.offset(x: CGFloat(index) * spacing - 11)
			}
			.frame(maxHeight: .infinity)
			.contentShape(Rectangle())
			.gesture(DragGesture(minimumDistance: 0).onChanged { drag in
				guard spacing > 0 else { return }
				let notch = min(max(Int((drag.location.x / spacing).rounded()), 0), sizes.count - 1)
				if sizes[notch] != value { onChange(sizes[notch]) }
			})
		}
		.padding(.horizontal, 11)
	}

	private func step(by offset: Int) {
		let notch = min(max(index + offset, 0), sizes.count - 1)
		guard sizes.indices.contains(notch) else { return }
		onChange(sizes[notch])
	}
}

/// A dot as thick as the stroke, scaled so the thinnest and thickest both read.
private struct SizeDot: View {
	let size: CGFloat
	let sizes: [CGFloat]
	let color: UIColor

	var body: some View {
		let low = sizes.first ?? 1, high = sizes.last ?? 1
		let share = high > low ? (size - low) / (high - low) : 0.5
		Circle()
			.fill(Color(uiColor: color.withAlphaComponent(1)))
			.overlay(Circle().strokeBorder(Color.carbon.opacity(0.18), lineWidth: 1))
			.frame(width: 5 + share * 19, height: 5 + share * 19)
	}
}

// MARK: - Buttons

private struct MarkupToolButton: View {
	let tool: PDFMarkupTool
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Glyph(tool.systemImage, size: 17, weight: .regular)
				.foregroundStyle(isSelected ? Color.vellum : Color.carbon)
				.frame(width: 40, height: 40)
				.background {
					if isSelected { Circle().fill(Color.carbon) }
				}
				.contentShape(Circle())
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(Text(tool.label))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

private struct MarkupSwatchButton: View {
	let swatch: MarkSwatch
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Circle()
				.fill(Color(uiColor: swatch.uiColor))
				.overlay(Circle().strokeBorder(Color.carbon.opacity(0.18), lineWidth: 1))
				.frame(width: 24, height: 24)
				.padding(4)
				.overlay {
					if isSelected { Circle().strokeBorder(Color.carbon, lineWidth: 2) }
				}
				.frame(width: 36, height: 36)
				.contentShape(Circle())
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(Text(swatch.name))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

/// Any color: the system's color well (grid, spectrum, sliders and eyedropper), ringed when a color
/// from it is the one in use.
private struct MarkupColorWell: View {
	let color: UIColor
	let isSelected: Bool
	let onPick: (UIColor) -> Void

	var body: some View {
		ColorPicker(selection: Binding(get: { Color(uiColor: color.withAlphaComponent(1)) }, set: { onPick(UIColor($0)) }),
					supportsOpacity: false) {
			Text("Any color")
		}
		.labelsHidden()
		.frame(width: 28, height: 28)
		.padding(4)
		.overlay {
			if isSelected { Circle().strokeBorder(Color.carbon, lineWidth: 2) }
		}
		.frame(width: 36, height: 36)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

private struct MarkupActionButton: View {
	let systemName: String
	let label: LocalizedStringKey
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Glyph(systemName, size: 16, weight: .regular)
				.foregroundStyle(.carbon)
				.frame(width: 36, height: 36)
				.background(Circle().fill(Color.carbon.opacity(0.06)))
				.contentShape(Circle())
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(Text(label))
	}
}
