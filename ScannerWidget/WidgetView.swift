//
//  WidgetView.swift
//  Rescriva widget
//
//  The launcher's face: the viewfinder in Rescriva's accent (indigo ink, this target's
//  AccentColor) on paper (its WidgetBackground), captioned "Scan" in a serif like the app's
//  New York headings. On the lock screen it's the viewfinder alone, in the system's colour.
//

import SwiftUI
import WidgetKit

struct ScannerWidgetEntryView: View {
	@Environment(\.widgetFamily) private var widgetFamily

	let entry: ScanLauncherEntry

	var body: some View {
		content
			.containerBackground(for: .widget) {
				background
			}
	}

	@ViewBuilder
	private var content: some View {
		switch widgetFamily {
		case .systemSmall:
			launcher(scaleBy: 2.5)
		case .accessoryCircular:
			launcher()
		default:
			EmptyView()
		}
	}

	@ViewBuilder
	private var background: some View {
		if widgetFamily == .systemSmall {
			Color("WidgetBackground")
		} else {
			Color.clear
		}
	}

	private var caption: String {
		String(localized: "Scan")
	}

	/// The caption inside the viewfinder; a longer translation is set smaller to stay inside.
	private func launcher(scaleBy scale: Double = 1) -> some View {
		ZStack {
			Text(caption)
				.font(.system(size: (caption.count > 4 ? 10 : 15) * scale, weight: .semibold, design: .serif))
			Image(systemName: "viewfinder")
				.font(.system(size: 42 * scale, weight: .light))
				.foregroundStyle(widgetFamily == .systemSmall ? Color.accentColor : Color.primary)
		}
	}
}
