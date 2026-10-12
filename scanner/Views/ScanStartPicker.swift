//
//  ScanStartPicker.swift
//  Open Scanner → Rescriva
//
//  Created by Slaven Radic on 2024-09-01.
//  Rescriva: the indigo Scan button and the menu of ways to start a scan.
//

import SwiftUI

/// Ways to start a scan from the Library.
enum ScanStart: CaseIterable {
	case document, whiteboard, photos, pdf

	var label: LocalizedStringKey {
		switch self {
		case .document: return "Scan a document"
		case .whiteboard: return "Whiteboard"
		case .photos: return "Import photos"
		case .pdf: return "Open a PDF"
		}
	}

	var detail: LocalizedStringKey {
		switch self {
		case .document: return "Pages, receipts, books"
		case .whiteboard: return "Flattens glare, keeps marker colors"
		case .photos: return "From your library"
		case .pdf: return "Read, mark up, fill and organize"
		}
	}

	var systemImage: String {
		switch self {
		case .document: return "doc.viewfinder"
		case .whiteboard: return "rectangle.and.pencil.and.ellipsis"
		case .photos: return "photo"
		case .pdf: return "doc.badge.plus"
		}
	}
}

struct ScanStartPicker: View {
	@Binding var isOpen: Bool
	var isBusy = false
	/// What the button says while busy, e.g. "Opening page 3 of 12".
	var busyTitle: String?
	let onChoose: (ScanStart) -> Void

	var body: some View {
		VStack(alignment: .trailing, spacing: 10) {
			if isOpen {
				menu
					.transition(.settle)
			}
			Button {
				withAnimation(RescrivaMotion.ui) { isOpen.toggle() }
			} label: {
				HStack(spacing: 10) {
					if isBusy {
						ProgressView().tint(.vellum)
					} else {
						Glyph(isOpen ? "xmark" : "plus.viewfinder", size: isOpen ? 15 : 20, weight: .light)
							.frame(width: 26, height: 26)
					}
					Group {
						if isBusy, let busyTitle {
							Text(busyTitle).monospacedDigit()
						} else {
							Text(isOpen ? "Close" : "Scan")
						}
					}
					.font(RescrivaFont.ui(16, weight: .medium))
				}
				.foregroundStyle(.vellum)
				.frame(height: 60)
				.padding(.leading, 18)
				.padding(.trailing, 24)
				.background(Color.ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
				.shadow(color: Color.shade.opacity(0.22), radius: 12, x: 0, y: 8)
			}
			.buttonStyle(PressScaleStyle(scale: 0.93))
			.disabled(isBusy)
			.accessibilityLabel(buttonLabel)
		}
	}

	private var buttonLabel: Text {
		if isBusy, let busyTitle { return Text(busyTitle) }
		return Text(isOpen ? "Close scan options" : "Start a scan")
	}

	private var menu: some View {
		VStack(spacing: 0) {
			ForEach(ScanStart.allCases, id: \.self) { start in
				Button {
					onChoose(start)
				} label: {
					HStack(spacing: 12) {
						Glyph(start.systemImage, size: 18, weight: .light)
							.foregroundStyle(.ink)
							.frame(width: 36, height: 36)
							.background(Color.wash, in: RoundedRectangle(cornerRadius: RescrivaRadius.small + 2, style: .continuous))
						VStack(alignment: .leading, spacing: 1) {
							Text(start.label)
								.font(RescrivaFont.ui(14, weight: .medium))
								.foregroundStyle(.carbon)
							Text(start.detail)
								.font(RescrivaFont.ui(12))
								.foregroundStyle(.graphite)
						}
						Spacer(minLength: 0)
					}
					.padding(.vertical, 11)
					.padding(.horizontal, 12)
					.contentShape(Rectangle())
				}
				.buttonStyle(PickerRowStyle())
			}
		}
		.padding(8)
		.frame(minWidth: 236, maxWidth: 280)
		.paperCard(radius: RescrivaRadius.large, fold: 18)
		.rescrivaShadow(.small)
	}
}

/// Picker rows take a wash of ink while pressed.
private struct PickerRowStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.background(Color.ink.opacity(configuration.isPressed ? 0.08 : 0), in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
			.animation(RescrivaMotion.fast, value: configuration.isPressed)
	}
}

struct ScanStartPicker_Previews: PreviewProvider {
	static var previews: some View {
		ScanStartPicker(isOpen: .constant(true)) { _ in }
			.padding()
			.background(Color.stock)
	}
}
