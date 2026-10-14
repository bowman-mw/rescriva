//
//  InboxManifest.swift
//  Rescriva (fork of Open Scanner)
//
//  The Inbox: files Rescriva's extensions hand to the app. Each hand-off is a folder in the App
//  Group container the app and its extensions share:
//
//      <group.MBO.Scanner>/Inbox/<id>/manifest.json   what it is; written last, so a folder
//                                                     without one is still arriving
//                                    pending.json    the manifest while the file arrives
//                                    <title>.pdf     the file (<title>.html for a web page)
//
//  The app imports every folder with a manifest on launch, on coming to the foreground and on
//  openscanner://inbox, then deletes it (Inbox.swift). Shared by the app and the Safari extension.
//

import Foundation

/// What a hand-off is, from its manifest.json.
struct InboxManifest: Codable, Equatable {
	enum Kind: String, Codable {
		/// A PDF, opened as a PDF.
		case pdf
		/// A web page's HTML as Safari showed it; the app saves it as a PDF.
		case webPage
		/// Only a link; the app downloads it. A PDF opens as a PDF, a page is saved as one.
		case link
	}

	/// The manifest format this build writes and reads.
	static let currentVersion = 1
	static let fileName = "manifest.json"
	/// The manifest while the file is still arriving.
	static let pendingFileName = "pending.json"

	var version = InboxManifest.currentVersion
	var kind: Kind
	/// The file's name inside the hand-off's folder; nil for a link.
	var file: String?
	var title: String
	/// The page or PDF's address, if it came from the web.
	var sourceURL: URL?
	var createdAt: Date

	/// True when the app can act on it: a format this build knows, a plain file name for a file,
	/// and a web address for a link. Anything else is skipped and removed.
	var isValid: Bool {
		guard version == Self.currentVersion else { return false }
		if let sourceURL, !Self.isWebAddress(sourceURL) { return false }
		switch kind {
		case .link:
			return file == nil && sourceURL != nil
		case .pdf, .webPage:
			guard let file else { return false }
			return Self.isPlainFileName(file)
		}
	}

	/// https, with a host. Plain http is refused: App Transport Security (only local networking
	/// is allowed in Info.plist) would refuse to load it anyway.
	static func isWebAddress(_ url: URL) -> Bool {
		guard url.scheme?.lowercased() == "https" else { return false }
		return url.host() != nil
	}

	/// A name that stays inside its folder: no slashes, not hidden, not "." or "..".
	static func isPlainFileName(_ name: String) -> Bool {
		guard !name.isEmpty, !name.hasPrefix(".") else { return false }
		return !name.contains("/") && !name.contains("\\") && !name.contains(":")
	}

	func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
		encoder.dateEncodingStrategy = .iso8601
		return try encoder.encode(self)
	}

	static func decode(_ data: Data) throws -> InboxManifest {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode(InboxManifest.self, from: data)
	}
}
