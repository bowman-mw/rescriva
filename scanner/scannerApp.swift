//
//  scannerApp.swift
//  Open Scanner → Rescriva
//
//  Created by Slaven Radic on 2024-09-01.
//

import SwiftUI
import CoreSpotlight

@main
struct scannerApp: App {
	@Environment(\.scenePhase) var scenePhase
	let persistenceController = PersistenceController.shared
	
	init() {
		RescrivaPreference.registerDefaults()
		// Rescriva: originals staged by an earlier run whose pages were never saved. Here rather than
		// in a view's task, which a second window would run again mid-session.
		OriginalStore.sweepStagingAtLaunch()
		// Quick Look's copies of pages, from an earlier run (and Documents, where older versions kept them).
		QuickLookCopy.sweepAtLaunch()
	}
	
	var body: some Scene {
		WindowGroup {
			ContentView(libraryIsTemporary: persistenceController.loadFailure != nil)
				.environment(\.managedObjectContext, persistenceController.container.viewContext)
				.onContinueUserActivity(CSSearchableItemActionType, perform: handleSpotlight)
		}
		.onChange(of: scenePhase) { _, newPhase in
			if newPhase == .inactive || newPhase == .background {
				saveAppState()
			}
		}
	}
	
	/// A Spotlight result names a scan (or, from an older index, one of its lines) by its object
	/// URI. The request waits in `AppRequests` until the window takes it; there, a scan deleted
	/// since — here or on another device — opens nothing but a note. Nothing is faulted in here,
	/// so a stale result can't raise an exception.
	func handleSpotlight(_ userActivity: NSUserActivity) {
		guard let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
			Log.app.error("A Spotlight result arrived without an identifier")
			return
		}
		let context = persistenceController.container.viewContext
		guard let objectID = PersistenceController.objectID(forSpotlightIdentifier: identifier, in: context) else {
			Log.app.notice("A Spotlight result's identifier isn't one of this library's: \(identifier)")
			return
		}
		AppRequests.shared.add(.openScan(objectID))
	}
	
	func saveAppState() {
		persistenceController.container.viewContext.saveQuietly()
	}
}
