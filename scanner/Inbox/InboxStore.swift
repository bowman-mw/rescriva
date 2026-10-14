//
//  InboxStore.swift
//  Rescriva (fork of Open Scanner)
//
//  The app's side of the Inbox folder (see InboxManifest.swift): what's ready to import, what's
//  still arriving, and what can't be used. App-target only.
//

import Foundation

struct InboxStore {
	/// A hand-off ready to import.
	struct Item: Equatable {
		let folder: URL
		let manifest: InboxManifest

		/// The hand-off's file; nil for a link.
		var fileURL: URL? { manifest.file.map { folder.appendingPathComponent($0) } }
	}

	/// What's in the Inbox right now.
	struct Contents: Equatable {
		/// Oldest first.
		var ready: [Item] = []
		/// Hand-offs that can't be imported: an unreadable manifest, or a missing file. The import
		/// removes them and says so.
		var unusable: [URL] = []
		/// Transfers that stopped long ago (the popup closed mid-way). The import removes them quietly.
		var abandoned: [URL] = []
		/// Transfers still arriving; left alone.
		var arriving = 0
	}

	/// A transfer with no progress for this long was abandoned (the popup closed mid-way).
	static let abandonedAfter: TimeInterval = 60 * 60
	/// The most hand-offs one pass looks at; the rest wait for the next.
	static let maxPerPass = 50

	let root: URL

	/// The Inbox in the App Group container; nil when the build has no app group.
	static var shared: InboxStore? {
		InboxDrop.shared.map { InboxStore(root: $0.root) }
	}

	/// Sorts every folder in the Inbox into ready, unusable, abandoned and still arriving.
	func contents(now: Date = Date()) -> Contents {
		var contents = Contents()
		for folder in folders().prefix(Self.maxPerPass) {
			if let item = item(in: folder) {
				contents.ready.append(item)
			} else if hasManifest(folder) {
				contents.unusable.append(folder)
			} else if isAbandoned(folder, now: now) {
				contents.abandoned.append(folder)
			} else {
				contents.arriving += 1
			}
		}
		contents.ready.sort { $0.manifest.createdAt < $1.manifest.createdAt }
		return contents
	}

	/// Deletes one hand-off's folder.
	func remove(_ folder: URL) {
		let parent = folder.deletingLastPathComponent().resolvingSymlinksInPath().path
		guard parent == root.resolvingSymlinksInPath().path else { return }
		do {
			try FileManager.default.removeItem(at: folder)
		} catch {
			Log.inbox.error("Couldn't remove an Inbox folder: \(error)")
		}
	}

	// MARK: Reading

	private func folders() -> [URL] {
		let keys: [URLResourceKey] = [.isDirectoryKey]
		do {
			let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
			return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
				.sorted { $0.lastPathComponent < $1.lastPathComponent }
		} catch {
			// No Inbox yet: nothing has been sent.
			return []
		}
	}

	/// The hand-off in `folder`, when its manifest reads, makes sense, its file is there, and a
	/// PDF still looks like one.
	private func item(in folder: URL) -> Item? {
		let url = folder.appendingPathComponent(InboxManifest.fileName)
		guard let data = try? Data(contentsOf: url), let manifest = try? InboxManifest.decode(data), manifest.isValid else {
			return nil
		}
		let item = Item(folder: folder, manifest: manifest)
		if let file = item.fileURL {
			guard FileManager.default.fileExists(atPath: file.path) else { return nil }
			if manifest.kind == .pdf, !looksLikePDF(file) { return nil }
		}
		return item
	}

	/// The magic-byte check the extension made at commit, made again here: on a Mac any process
	/// can write the App Group folder, so what's there now isn't necessarily what was committed.
	/// A file that can't be read fails the check too; the import removes it and says so.
	private func looksLikePDF(_ file: URL) -> Bool {
		do {
			return try InboxDrop.startsLikePDF(file)
		} catch {
			Log.inbox.error("Couldn't read an Inbox file to check it: \(error)")
			return false
		}
	}

	private func hasManifest(_ folder: URL) -> Bool {
		FileManager.default.fileExists(atPath: folder.appendingPathComponent(InboxManifest.fileName).path)
	}

	/// True when nothing in `folder` has changed for `abandonedAfter`.
	private func isAbandoned(_ folder: URL, now: Date) -> Bool {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
		let dates = ([folder] + names.map { folder.appendingPathComponent($0) }).compactMap { url in
			(try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
		}
		guard let latest = dates.max() else { return true }
		return now.timeIntervalSince(latest) > Self.abandonedAfter
	}
}
