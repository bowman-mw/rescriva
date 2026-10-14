//
//  TimelineProvider.swift
//  Rescriva widget
//
//  A timeline of one entry that never needs refreshing: the launcher looks the same whatever
//  the app holds, so nothing is fetched here.
//

import WidgetKit

struct ScanLauncherProvider: TimelineProvider {
	func placeholder(in context: Context) -> ScanLauncherEntry {
		ScanLauncherEntry(date: Date())
	}

	func getSnapshot(in context: Context, completion: @escaping (ScanLauncherEntry) -> Void) {
		completion(ScanLauncherEntry(date: Date()))
	}

	func getTimeline(in context: Context, completion: @escaping (Timeline<ScanLauncherEntry>) -> Void) {
		completion(Timeline(entries: [ScanLauncherEntry(date: Date())], policy: .never))
	}
}
