//
//  RescrivaComponents.swift
//  Rescriva (fork of Open Scanner)
//
//  Small reusable pieces of Rescriva's paper-and-ink look: tabs of card
//  stock for buttons, chips, the paper-tab switch, ink-stroke tabs, the
//  toast, banners, page thumbnails, the wordmark and the frosted bottom bar.
//

import SwiftUI

/// "‹ Scans" — the vellum tab at the top-left of every inner screen.
struct BackPill: View {
	let title: LocalizedStringKey
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 2) {
				Glyph("chevron.left", size: 15)
				Text(title)
					.font(RescrivaFont.ui(14, weight: .medium))
			}
			.foregroundStyle(.carbon)
			.frame(height: 40)
			.padding(.leading, 6)
			.padding(.trailing, 14)
			.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
			.rescrivaShadow(.small)
		}
		.buttonStyle(PressScaleStyle(scale: 0.94))
		.accessibilityLabel(Text("Back to \(Text(title))"))
	}
}

/// A 40 pt vellum tab holding one icon.
struct CircleIconButton: View {
	let systemName: String
	let label: LocalizedStringKey
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Glyph(systemName, size: 17)
				.foregroundStyle(.carbon)
				.frame(width: 40, height: 40)
				.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.rescrivaShadow(.small)
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(Text(label))
	}
}

/// A selectable chip: carbon when chosen, vellum otherwise.
struct ChoiceChip: View {
	let label: LocalizedStringKey
	let isSelected: Bool
	var fillsWidth = false
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Text(label)
				.font(RescrivaFont.ui(13, weight: .medium))
				.foregroundStyle(isSelected ? Color.vellum : Color.carbon)
				.lineLimit(1)
				.fixedSize(horizontal: !fillsWidth, vertical: false)
				.padding(.vertical, fillsWidth ? 9 : 7)
				.padding(.horizontal, fillsWidth ? 0 : 14)
				.frame(maxWidth: fillsWidth ? .infinity : nil)
				.background(isSelected ? Color.carbon : Color.vellum,
							in: RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous))
				.overlay {
					// A faint edge keeps an unselected chip visible on a vellum sheet.
					RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous)
						.strokeBorder(Color.carbon.opacity(isSelected ? 0 : 0.14))
				}
				.animation(RescrivaMotion.ui, value: isSelected)
		}
		.buttonStyle(PressScaleStyle(scale: 0.95))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

/// Rescriva's switch: a paper tab sliding in a slot, inked when on.
struct RescrivaToggleStyle: ToggleStyle {
	func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: 12) {
			configuration.label
			Spacer(minLength: 0)
			ZStack(alignment: configuration.isOn ? .trailing : .leading) {
				RoundedRectangle(cornerRadius: 9, style: .continuous)
					.fill(configuration.isOn ? Color.ink : Color.carbon.opacity(0.16))
					.frame(width: 51, height: 31)
				RoundedRectangle(cornerRadius: 7, style: .continuous)
					.fill(Color.vellum)
					.frame(width: 27, height: 27)
					.shadow(color: Color.shade.opacity(0.25), radius: 1.5, x: 0, y: 1)
					.padding(2)
			}
			.animation(RescrivaMotion.spring, value: configuration.isOn)
			.onTapGesture { configuration.isOn.toggle() }
		}
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isButton)
		.accessibilityValue(Text(configuration.isOn ? "On" : "Off"))
		.accessibilityAction { configuration.isOn.toggle() }
	}
}

/// A transient confirmation at the top of the screen: a slip of ink-dark
/// paper. An export's toast shows the page settling onto its stack.
struct ToastView: View {
	let message: String
	var style: RescrivaToast.Style = .done
	var actionLabel: String?
	var action: (() -> Void)?
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		HStack(spacing: 10) {
			switch style {
			case .done:
				Glyph("checkmark", size: 11)
					.foregroundStyle(.printInk)
					.frame(width: 22, height: 22)
					.background(Color.highlighter, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
			case .exported:
				SettlingPage(width: 17)
					.frame(width: 22, height: 26)
			}
			Text(message)
				.font(RescrivaFont.ui(14))
				.foregroundStyle(.vellum)
				.frame(maxWidth: .infinity, alignment: .leading)
			if let actionLabel, let action {
				// The slip is dark ink on paper and chalk white on the chalkboard: the action is
				// highlighted on the first and inked in indigo on the second.
				Button(actionLabel, action: action)
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(colorScheme == .dark ? Color(uiColor: RescrivaPalette.ink.onPaper) : Color.highlighter)
			}
		}
		.padding(.vertical, 12)
		.padding(.horizontal, 16)
		.background(Color.carbon, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
		.rescrivaShadow(.float)
		.padding(.horizontal, 24)
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isStaticText)
	}
}

/// A line of explanation above a screen's content, on a slip with its corner
/// folded, with a close button when `onDismiss` is set.
struct BannerView: View {
	enum Tone { case info, warning }

	let text: String
	let tone: Tone
	var onDismiss: (() -> Void)?

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			Glyph(tone == .warning ? "exclamationmark.triangle" : "info.circle", size: 15)
				.foregroundStyle(tone == .warning ? Color.vermilion : Color.ink)
				.padding(.top, -1)
			Text(text)
				.font(RescrivaFont.ui(13))
				.foregroundStyle(.carbon)
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
			if let onDismiss {
				Button(action: onDismiss) {
					Glyph("xmark", size: 11)
						.foregroundStyle(.graphite)
						.frame(width: 24, height: 24)
				}
				.accessibilityLabel("Dismiss")
			}
		}
		.padding(12)
		.paperCard(radius: 10, fold: 10)
	}
}

/// A soft fade of paper behind the status bar, so scrolled content doesn't
/// collide with the clock.
struct StatusBarScrim: View {
	var body: some View {
		LinearGradient(stops: [.init(color: .stock, location: 0), .init(color: .stock.opacity(0.92), location: 0.55), .init(color: .stock.opacity(0), location: 1)],
					   startPoint: .top, endPoint: .bottom)
			.frame(height: 14)
			.ignoresSafeArea(edges: .top)
			.allowsHitTesting(false)
			.accessibilityHidden(true)
	}
}

/// A choice of a few views, set like tabs in a document: the options on a
/// faint rule, the chosen one in ink with a hand-inked stroke under it that
/// moves across when the choice changes.
struct RescrivaSegmentedPicker<Option: Hashable>: View {
	let options: [Option]
	@Binding var selection: Option
	let label: (Option) -> LocalizedStringKey
	/// The stroke under the chosen tab.
	var stroke: Color = .ink
	/// The chosen tab's label.
	var chosenText: Color = .carbon
	/// The other tabs' labels.
	var otherText: Color = .graphite

	@Namespace private var underline

	var body: some View {
		HStack(spacing: 0) {
			ForEach(options, id: \.self) { option in
				let chosen = selection == option
				Button {
					withAnimation(RescrivaMotion.ui) { selection = option }
				} label: {
					Text(label(option))
						.font(RescrivaFont.ui(13, weight: chosen ? .semibold : .medium))
						.foregroundStyle(chosen ? chosenText : otherText)
						.lineLimit(1)
						.minimumScaleFactor(0.8)
						.padding(.top, 7)
						.padding(.bottom, 10)
						.background(alignment: .bottom) {
							if chosen {
								InkStroke()
									.fill(stroke)
									.frame(height: 4)
									.padding(.horizontal, -5)
									.matchedGeometryEffect(id: "underline", in: underline)
							}
						}
						.frame(maxWidth: .infinity)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityAddTraits(chosen ? .isSelected : [])
			}
		}
		.background(alignment: .bottom) {
			Rectangle()
				.fill(otherText.opacity(0.25))
				.frame(height: 0.75)
				.offset(y: -1.5)
		}
	}
}

/// The indigo primary action.
struct PrimaryButton: View {
	let title: LocalizedStringKey
	var systemImage: String?
	var height: CGFloat = 54
	var isBusy = false
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 8) {
				if isBusy {
					ProgressView().tint(.vellum)
				} else if let systemImage {
					Glyph(systemImage, size: 17)
				}
				Text(title)
					.font(RescrivaFont.ui(16, weight: .medium))
			}
			.foregroundStyle(.vellum)
			.frame(maxWidth: .infinity)
			.frame(height: height)
			.background(Color.ink, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
		}
		.buttonStyle(PressScaleStyle(scale: 0.96))
		.disabled(isBusy)
	}
}

/// Frosted paper bar pinned to the bottom with the sheet radius and a ruled
/// top edge.
struct FrostedBottomBar<Content: View>: View {
	@ViewBuilder var content: Content

	var body: some View {
		VStack(spacing: 12) {
			content
		}
		.padding(.horizontal, 20)
		.padding(.top, 14)
		.padding(.bottom, 12)
		.frame(maxWidth: .infinity)
		.background {
			UnevenRoundedRectangle(topLeadingRadius: RescrivaRadius.large, topTrailingRadius: RescrivaRadius.large, style: .continuous)
				.fill(.ultraThinMaterial)
				.overlay {
					UnevenRoundedRectangle(topLeadingRadius: RescrivaRadius.large, topTrailingRadius: RescrivaRadius.large, style: .continuous)
						.fill(Color.stock.opacity(0.78))
				}
				.overlay {
					UnevenRoundedRectangle(topLeadingRadius: RescrivaRadius.large, topTrailingRadius: RescrivaRadius.large, style: .continuous)
						.strokeBorder(Color.carbon.opacity(0.07), lineWidth: 0.75)
				}
				.rescrivaShadow(.sheet)
				.ignoresSafeArea(edges: .bottom)
		}
	}
}

/// A page thumbnail on paper with its corner folded: the scanned image when
/// there is one, otherwise a few ink lines standing in for text.
struct PaperThumbnail: View {
	var image: UIImage?
	var width: CGFloat
	var height: CGFloat
	var ink: Color = .ink
	var grayscale = 0.0
	var contrast = 1.0
	var saturation = 1.0

	var body: some View {
		ZStack {
			Color.paper
			if let image {
				Image(uiImage: image)
					.resizable()
					.scaledToFill()
					.frame(width: width, height: height)
					.clipped()
					.grayscale(grayscale)
					.contrast(contrast)
					.saturation(saturation)
			} else {
				PlaceholderLines(ink: ink)
					.padding(.vertical, height * 0.12)
					.padding(.horizontal, width * 0.13)
			}
		}
		.frame(width: width, height: height)
		.foldedPage(radius: 3, fold: max(6, min(width, height) * 0.16))
		.environment(\.colorScheme, .light)
		.shadow(color: Color.shade.opacity(0.16), radius: 1.5, x: 0, y: 1)
		.accessibilityHidden(true)
	}
}

/// Ink lines on a page: a heading and four lines of text, square-ended like
/// a pen's strokes.
struct PlaceholderLines: View {
	var ink: Color = .ink

	var body: some View {
		GeometryReader { proxy in
			let w = proxy.size.width
			VStack(alignment: .leading, spacing: max(2, proxy.size.height * 0.08)) {
				RoundedRectangle(cornerRadius: 1).fill(ink).frame(width: w * 0.6, height: max(3, proxy.size.height * 0.08))
				ForEach([0.9, 0.8, 0.86, 0.5], id: \.self) { fraction in
					RoundedRectangle(cornerRadius: 0.5).fill(Color.carbon.opacity(0.2)).frame(width: w * fraction, height: 2)
				}
			}
		}
	}
}

/// Sheet title row used by the export and flag sheets.
struct SheetHeader: View {
	let title: String
	var subtitle: String?
	var trailing: (label: String, action: () -> Void)?

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(RescrivaFont.header(22))
					.foregroundStyle(.carbon)
				if let subtitle {
					Text(subtitle)
						.font(RescrivaFont.ui(13))
						.foregroundStyle(.graphite)
				}
			}
			Spacer()
			if let trailing {
				Button(trailing.label, action: trailing.action)
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.ink)
			}
		}
	}
}

/// "Rescriva" set in New York with a swipe of highlighter under it.
struct RescrivaWordmark: View {
	var size: CGFloat = 34
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		Text("Rescriva")
			.font(RescrivaFont.wordmark(size))
			.tracking(-0.3)
			.foregroundStyle(.carbon)
			.background(alignment: .bottomLeading) {
				InkStroke()
					.fill(Color.highlighter.opacity(colorScheme == .dark ? 0.45 : 0.7))
					.frame(height: size * 0.3)
					.padding(.leading, -size * 0.06)
					.padding(.trailing, -size * 0.14)
					.offset(y: -size * 0.1)
			}
			.accessibilityLabel(Text(verbatim: "Rescriva"))
			.accessibilityAddTraits(.isHeader)
	}
}
