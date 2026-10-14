//
//  NavigationManager.swift
//  Open Scanner → Rescriva
//
//  Created by Slaven Radic on 2024-09-01.
//  Rescriva: requests raised from outside the app's screens — Siri and Shortcuts (AppIntents.swift),
//  the widget's and the web page's openscanner:// links, Spotlight results — wait in one queue
//  until a window's ContentView takes them. A request raised before any window exists (a cold
//  launch from Siri or from a Spotlight result) is kept, not lost, and each is handled once.
//  (Replaces Open Scanner's NavigationManager flags and AppState's `viewState` commands.)
//

import CoreData
import Foundation
import Observation

/// Something the app was asked to do from outside its screens.
enum AppRequest: Equatable {
	/// Show a scan: the object id of a `Scan`, or of one of its recognized lines (entries from an
	/// older Spotlight index name those). Whether it's still in the library is checked when the
	/// request is handled, never here.
	case openScan(NSManagedObjectID)
	/// Start a document scan: the widget, an openscanner://scan link, or "Scan Document" in Shortcuts.
	case startScan
	/// Bring Share Nearby up for the pairing link waiting in `NearbySharePending`.
	case shareNearby
}

/// The queue every entry point appends to and `ContentView` drains (`onChange(initial: true)`,
/// so whatever arrived before the window did is taken as soon as it appears).
@MainActor
@Observable
final class AppRequests {
	static let shared = AppRequests()

	/// What's waiting, oldest first.
	private(set) var pending: [AppRequest] = []

	init() {}

	func add(_ request: AppRequest) {
		pending.append(request)
	}

	/// Hands over everything waiting, in the order it arrived, and empties the queue.
	func takeAll() -> [AppRequest] {
		let taken = pending
		pending.removeAll()
		return taken
	}
}
