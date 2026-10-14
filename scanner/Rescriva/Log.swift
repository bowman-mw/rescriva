//
//  Log.swift
//  Rescriva
//
//  The app's loggers, one per area, so Console and a sysdiagnose can be filtered by category.
//  A message is plain prose about what happened: a failure caught in a catch body goes in as
//  `.error`, something worth keeping (a refusal, a sweep's count, a fallback taken) as
//  `.notice`, and chatter for development as `.debug`. Nothing the user wrote or named is
//  logged in the clear: a title or a file name goes in as `\(value, privacy: .private)`, and
//  PINs, secrets, keys, file contents and recognized text never go in at all. The widget and
//  the Safari extension are separate targets and log on their own.
//

import Foundation
import os

enum Log {
	/// The subsystem every category shares: the bundle id, so the extensions stay apart.
	static let subsystem = Bundle.main.bundleIdentifier ?? "Rescriva"

	/// Launch, Spotlight hand-offs, audio and other app-wide plumbing.
	static let app = Logger(subsystem: subsystem, category: "app")
	/// The scan library and the PDF library: Core Data, originals, figures, annotations.
	static let library = Logger(subsystem: subsystem, category: "library")
	/// Share Nearby: the relay, pairing, WebRTC and transfers.
	static let share = Logger(subsystem: subsystem, category: "share")
	/// Exports to Word, PowerPoint, PDF, Markdown and text.
	static let export = Logger(subsystem: subsystem, category: "export")
	/// OCR and the rebuild pipeline.
	static let rebuild = Logger(subsystem: subsystem, category: "rebuild")
	/// The Inbox fed by the Safari extension.
	static let inbox = Logger(subsystem: subsystem, category: "inbox")
	/// The camera, glare capture and page cleanup.
	static let capture = Logger(subsystem: subsystem, category: "capture")
}
