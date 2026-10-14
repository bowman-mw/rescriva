//
//  TimelineEntry.swift
//  Rescriva widget
//
//  The launcher's one timeline entry. It shows nothing that changes, so the entry carries only
//  the date WidgetKit asks for.
//

import Foundation
import WidgetKit

struct ScanLauncherEntry: TimelineEntry {
	let date: Date
}
