//
//  WidgetView.swift
//  ScannerWidgetExtension
//
//  Created by Slaven Radic on 2024-09-01.
//

import SwiftUI
import WidgetKit

struct ScannerWidgetEntryView: View {
	
	@Environment(\.widgetFamily) var widgetFamily

	var entry: Provider.Entry
	var viewState: ViewState
	
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
			// Small home screen widget
			buttonText(scaleBy: 2.5)
		case .accessoryCircular:
			// Small circular lock screen widget
			buttonText()
		default:
			EmptyView()
		}
	}
	
	@ViewBuilder
	private var background: some View {
		if widgetFamily == .systemSmall {
			DefaultBackgroundGradient
		} else {
			Color.clear
		}
	}
	
	/// Rescriva's look: the viewfinder in indigo ink on paper (chalk on the
	/// chalkboard), with the caption set in New York.
	func buttonText(scaleBy: Double = 1) -> some View {
		ZStack {
			Text(caption)
				.font(.system(size: caption.count > 4 ? 10 * scaleBy : 15 * scaleBy, weight: .semibold, design: .serif))
			Image(systemName: "viewfinder")
				.font(.system(size: 42 * scaleBy, weight: .light))
				.foregroundStyle(widgetFamily == .systemSmall ? Color.accent : Color.primary)
		}
	}

	var caption: String {
		"Scan"
	}
	
}
