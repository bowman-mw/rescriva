//
//  AppIntents.swift
//  Open Scanner → Rescriva
//
//  Created by Slaven Radic on 2024-09-01.
//  Rescriva: the two Shortcuts actions. "Scan Document" queues a scan for the window to start
//  (`AppRequests`), so it works on a cold launch too; "Open Rescriva" only opens the app.
//

import Foundation
import AppIntents
import SwiftUI

struct ClassicScanIntent: AppIntent {
	static let title: LocalizedStringResource = "Scan Document"
	static let description = IntentDescription("Scan a document with Rescriva")
	static let openAppWhenRun: Bool = true

	@MainActor
	func perform() async throws -> some IntentResult {
		// A Mac has no document camera, so there's nothing to start there.
		guard !ProcessInfo.processInfo.isMacCatalystApp else {
			return .result(dialog: "A Mac has no document camera. Drop a PDF or a photo on Rescriva's window instead.")
		}
		AppRequests.shared.add(.startScan)
		return .result(dialog: "Okay, starting a scan.")
	}
}

struct OpenAppIntent: AppIntent {
	static let title: LocalizedStringResource = "Open Rescriva"
	static let description = IntentDescription("Run the Rescriva app")
	static let openAppWhenRun: Bool = true

	/// Opening is `openAppWhenRun`'s job: the app comes to the front on whatever it was showing.
	@MainActor
	func perform() async throws -> some IntentResult {
		.result(dialog: "Okay, starting Rescriva.")
	}
}

/// No phrase takes a parameter, so there's nothing for `updateAppShortcutParameters()` to refresh;
/// call it when the parameter values change once one does.
struct ScannerShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		
		AppShortcut(intent: OpenAppIntent(), phrases: ["\(.applicationName)"], shortTitle: "Open Rescriva", systemImageName: "viewfinder")
		AppShortcut(intent: ClassicScanIntent(), phrases: ["Scan a document with \(.applicationName)", "Scan with \(.applicationName)"], shortTitle: "Scan Document", systemImageName: "doc.viewfinder")
	}
}
