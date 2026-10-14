//
//  ScannerWidget.swift
//  Rescriva widget
//
//  A launcher and nothing more: tapping it opens Rescriva ready to scan. It reads no data, so
//  it needs no store, no App Group, no CloudKit and no data model; the app's data files aren't
//  part of this target. Only WidgetKit and SwiftUI are used here.
//

import SwiftUI
import WidgetKit

@main
struct ScannerWidgetBundle: WidgetBundle {
	var body: some Widget {
		ClassicScanWidget()
	}
}

/// The "Scan" launcher on the home screen (small) and the lock screen (circular).
struct ClassicScanWidget: Widget {
	/// The kind the app knows this widget by; unchanged from Open Scanner.
	static let kind = "ClassicScannerWidget"
	/// The link the app opens on a tap: straight into the scanner.
	static let scanURL = URL(string: "openscanner://scan/classic")

	var body: some WidgetConfiguration {
		StaticConfiguration(kind: Self.kind, provider: ScanLauncherProvider()) { entry in
			ScannerWidgetEntryView(entry: entry)
				.widgetURL(Self.scanURL)
		}
		.configurationDisplayName(String(localized: "Scan"))
		.description(String(localized: "Scan a document with Rescriva"))
		.supportedFamilies([.systemSmall, .accessoryCircular])
	}
}
