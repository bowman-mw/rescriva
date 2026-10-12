//
//  BlockActionMenu.swift
//  Rescriva (fork of Open Scanner)
//
//  The small menu a figure or diagram shows when it's tapped in Review &
//  fix, e.g. "Recreate". The screen hosting the document decides which
//  actions a block gets; the document view only shows them.
//

import SwiftUI

/// One choice in a tapped block's menu.
struct BlockAction: Identifiable {
	/// Stable identity, e.g. "recreate".
	let id: String
	let title: LocalizedStringKey
	let systemImage: String
	var detail: LocalizedStringKey?
	let perform: () -> Void
}

/// The menu itself, shown in a popover beside the block. A chosen action
/// runs once the popover has gone, so it can present a screen of its own.
struct BlockActionMenu: View {
	@Environment(\.dismiss) private var dismiss
	@State private var chosen: BlockAction?
	let actions: [BlockAction]

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			ForEach(actions) { action in
				Button {
					chosen = action
					dismiss()
				} label: {
					HStack(spacing: 12) {
						Glyph(action.systemImage, size: 17)
							.foregroundStyle(.ink)
							.frame(width: 26)
						VStack(alignment: .leading, spacing: 2) {
							Text(action.title)
								.font(RescrivaFont.ui(15, weight: .medium))
								.foregroundStyle(.carbon)
							if let detail = action.detail {
								Text(detail)
									.font(RescrivaFont.ui(12))
									.foregroundStyle(.graphite)
									.fixedSize(horizontal: false, vertical: true)
							}
						}
						Spacer(minLength: 0)
					}
					.padding(.vertical, 10)
					.padding(.horizontal, 12)
					.contentShape(Rectangle())
				}
				.buttonStyle(PressScaleStyle(scale: 0.97))
			}
		}
		.padding(8)
		.frame(width: 280)
		.presentationCompactAdaptation(.popover)
		.presentationBackground(Color.vellum)
		.onDisappear { chosen?.perform() }
	}
}
