//
//  PDFLibrary.swift
//  Rescriva (fork of Open Scanner)
//
//  PDFs opened in Rescriva stay PDFs. Each one lives in its own folder:
//
//      Application Support/PDFs/<id>/original.pdf   the file as imported, never changed
//                                     edited.pdf    Rescriva's saves, once there are any
//                                     info.json     title, dates, favorite, page count
//                                     text.txt      the text, for Library search
//
//  The file you picked in Files (or Dropbox, Drive, OneDrive) is copied in and
//  left untouched; "Revert to original" throws edited.pdf away. These files are
//  on this iPhone only for now (not in the iCloud-synced store).
//

import Foundation
import Observation
import PDFKit
import UIKit

/// A PDF in the Library.
struct PDFItem: Identifiable, Hashable, Codable {
	let id: UUID
	var title: String
	/// The name the file had when it was imported, e.g. "Lease 2026.pdf".
	var sourceName: String
	var importedAt: Date
	/// When Rescriva last saved changes; nil until the first edit.
	var editedAt: Date?
	var fave = false
	var pageCount: Int
	var byteCount: Int64

	var isEdited: Bool { editedAt != nil }

	/// "12 pages · 2 hours ago".
	var libraryMeta: String {
		let pages = pageCount == 1 ? String(localized: "1 page") : String(localized: "\(pageCount) pages")
		return "\(pages) · \(RescrivaDates.relative(editedAt ?? importedAt))"
	}
}

enum PDFLibraryError: LocalizedError {
	case unreadable
	case locked
	case writeFailed

	var errorDescription: String? {
		switch self {
		case .unreadable: return String(localized: "That file isn't a PDF Rescriva can open.")
		case .locked: return String(localized: "That PDF needs its password.")
		case .writeFailed: return String(localized: "Rescriva couldn't save the PDF.")
		}
	}
}

@MainActor
@Observable
final class PDFLibrary {
	static let shared = PDFLibrary()

	/// Newest first.
	private(set) var items: [PDFItem] = []

	@ObservationIgnored private let root: URL
	@ObservationIgnored private var texts: [UUID: String] = [:]
	@ObservationIgnored private let thumbnails = NSCache<NSString, UIImage>()
	/// Saves being written, by item.
	@ObservationIgnored private var saving: [UUID: Task<(pageCount: Int, report: PDFFormatReport?), Error>] = [:]
	/// Saves an editor has started, from the moment it asks (before its snapshot reaches `save`).
	@ObservationIgnored private var announced: [UUID: Task<Void, Never>] = [:]

	init(root: URL? = nil) {
		self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("PDFs", isDirectory: true)
		do {
			try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
		} catch {
			Log.library.error("Couldn't create the PDF library folder: \(error)")
		}
		reload()
	}

	// MARK: Files

	func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
	func originalURL(for item: PDFItem) -> URL { folder(for: item.id).appendingPathComponent("original.pdf") }
	func editedURL(for item: PDFItem) -> URL { folder(for: item.id).appendingPathComponent("edited.pdf") }
	private func infoURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("info.json") }
	private func textURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("text.txt") }

	/// The version to open: Rescriva's edits when there are any, else the original.
	func currentURL(for item: PDFItem) -> URL {
		let edited = editedURL(for: item)
		return FileManager.default.fileExists(atPath: edited.path) ? edited : originalURL(for: item)
	}

	func item(_ id: UUID) -> PDFItem? { items.first { $0.id == id } }

	/// Reads every item's info from disk.
	func reload() {
		let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
		items = folders.compactMap(item(in:)).sorted { $0.importedAt > $1.importedAt }
		// Text extraction can be cut short (the app quits mid-import); finish it now.
		for item in items where !FileManager.default.fileExists(atPath: textURL(for: item.id).path) {
			indexText(of: item)
		}
	}

	/// The item in `folder`: its info.json or, when that's missing or unreadable, a stand-in made
	/// from the PDF itself, so a PDF never vanishes from the Library over a bad record. A record
	/// that's missing is written back; one that's there but unreadable is left for recovery and
	/// logged (a rename or a favorite replaces it). A folder without a PDF isn't an item.
	private func item(in folder: URL) -> PDFItem? {
		let info = folder.appendingPathComponent("info.json")
		do {
			return try JSONDecoder.rescriva.decode(PDFItem.self, from: Data(contentsOf: info))
		} catch {
			guard let id = UUID(uuidString: folder.lastPathComponent),
				  FileManager.default.fileExists(atPath: folder.appendingPathComponent("original.pdf").path) else { return nil }
			Log.library.error("\(folder.lastPathComponent)/info.json couldn't be read (\(error)); showing the PDF with its own details")
			let item = standIn(for: id)
			if !FileManager.default.fileExists(atPath: info.path) {
				do {
					try writeInfo(item)
				} catch {
					Log.library.error("Couldn't write a PDF's details back: \(error)")
				}
			}
			return item
		}
	}

	/// What can be known about a PDF without its record: the title it carries, the files' dates,
	/// its pages and its size.
	private func standIn(for id: UUID) -> PDFItem {
		let original = folder(for: id).appendingPathComponent("original.pdf")
		let edited = folder(for: id).appendingPathComponent("edited.pdf")
		let hasEdits = FileManager.default.fileExists(atPath: edited.path)
		let current = hasEdits ? edited : original
		let document = PDFDocument(url: current)
		let carried = (document?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
			.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let title = carried.isEmpty ? String(localized: "Untitled PDF") : carried
		return PDFItem(id: id, title: title, sourceName: title + ".pdf", importedAt: fileDate(original) ?? Date(),
					   editedAt: hasEdits ? fileDate(edited) : nil, pageCount: document?.pageCount ?? 0, byteCount: fileSize(current))
	}

	/// When the file was made, or failing that last changed.
	private func fileDate(_ url: URL) -> Date? {
		let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
		return (attributes?[.creationDate] ?? attributes?[.modificationDate]) as? Date
	}

	// MARK: Import

	/// Copies the PDF at `url` (a security-scoped URL from Files, or any local file) into
	/// the Library. Reads through a file coordinator so Dropbox, Drive and OneDrive
	/// download the file first. Locked PDFs import fine; they ask for the password on open.
	func importPDF(at url: URL, title: String? = nil) async throws -> PDFItem {
		let id = UUID()
		let folder = folder(for: id)
		let destination = folder.appendingPathComponent("original.pdf")
		let copied: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
			let scoped = url.startAccessingSecurityScopedResource()
			defer { if scoped { url.stopAccessingSecurityScopedResource() } }
			do {
				try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
				var coordinationError: NSError?
				var copyError: Error?
				NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
					do {
						try FileManager.default.copyItem(at: readable, to: destination)
					} catch {
						copyError = error
					}
				}
				if let error = coordinationError ?? copyError { throw error }
				return .success(())
			} catch {
				return .failure(error)
			}
		}.value
		if case .failure(let error) = copied {
			FileManager.default.removeIfPresent(folder, log: Log.library)
			throw error
		}
		guard let document = PDFDocument(url: destination) else {
			FileManager.default.removeIfPresent(folder, log: Log.library)
			throw PDFLibraryError.unreadable
		}
		let name = url.lastPathComponent
		let item = PDFItem(id: id, title: title ?? url.deletingPathExtension().lastPathComponent, sourceName: name,
						   importedAt: Date(), pageCount: document.pageCount, byteCount: fileSize(destination))
		try writeInfo(item)
		items.insert(item, at: 0)
		if !document.isLocked {
			indexText(of: item)
		}
		return item
	}

	/// Adds a PDF made inside Rescriva (extracted pages, a split) as a new item.
	func add(_ data: Data, title: String) throws -> PDFItem {
		let id = UUID()
		let folder = folder(for: id)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let destination = folder.appendingPathComponent("original.pdf")
		try data.write(to: destination, options: .atomic)
		guard let document = PDFDocument(url: destination) else {
			FileManager.default.removeIfPresent(folder, log: Log.library)
			throw PDFLibraryError.unreadable
		}
		let item = PDFItem(id: id, title: title, sourceName: title + ".pdf", importedAt: Date(),
						   pageCount: document.pageCount, byteCount: fileSize(destination))
		try writeInfo(item)
		items.insert(item, at: 0)
		indexText(of: item)
		return item
	}

	// MARK: Saving

	/// Writes `document` as the item's edited copy, off the main thread: the document is handed
	/// over (`sending`), so pass one nothing else holds (PDFEditSession hands over a snapshot). A
	/// long PDF takes seconds to write, so this mustn't run on the main thread, where iOS ends an
	/// app that's busy for too long as it leaves the screen. The file is written next to the old
	/// one and swapped in, so a save that fails or is cut short leaves the last good copy. When the
	/// original made conformance claims (PDF/A, PDF/X, PDF/UA…), they're removed from the copy,
	/// which no longer meets them. Saves of one item run one at a time, in order. Returns the
	/// copy's format report.
	@discardableResult
	func save(_ document: sending PDFDocument, for item: PDFItem, options: [PDFDocumentWriteOption: any Sendable] = [:]) async throws -> PDFFormatReport? {
		await waitForWrites(of: item.id)
		let folder = folder(for: item.id)
		let edited = editedURL(for: item)
		let task = Task.detached(priority: .userInitiated) {
			try Self.write(document, into: folder, replacing: edited, options: options)
		}
		saving[item.id] = task
		defer { saving[item.id] = nil }
		let written = try await task.value
		var updated = self.item(item.id) ?? item
		updated.editedAt = Date()
		updated.pageCount = written.pageCount
		updated.byteCount = fileSize(edited)
		try update(updated)
		thumbnails.removeAllObjects()
		indexText(of: updated)
		return written.report
	}

	/// Returns once the files being written for `id` are on disk. Writes queue behind each other;
	/// an editor's announced save doesn't count here, since it's the one asking.
	private func waitForWrites(of id: UUID) async {
		for _ in 0..<Self.maxQueuedSaves {
			guard let pending = saving[id] else { return }
			_ = await pending.result
		}
	}

	/// Returns once any save of `id` under way has finished, so what's read next is the latest.
	func waitForSave(of id: UUID) async {
		for _ in 0..<Self.maxQueuedSaves {
			if let editor = announced[id] {
				await editor.value
			} else if let pending = saving[id] {
				_ = await pending.result
			} else {
				return
			}
		}
	}

	/// An editor's save of `id`, which `waitForSave` waits for until it's done.
	func announceSave(_ work: Task<Void, Never>, of id: UUID) {
		announced[id] = work
		Task {
			await work.value
			if announced[id] == work { announced[id] = nil }
		}
	}

	/// Saves of one item that may queue behind each other.
	private static let maxQueuedSaves = 8

	/// The write itself, safe off the main thread: staging file, claims removed, swapped in.
	private nonisolated static func write(_ document: PDFDocument, into folder: URL, replacing edited: URL,
										  options: [PDFDocumentWriteOption: any Sendable]) throws -> (pageCount: Int, report: PDFFormatReport?) {
		let staging = folder.appendingPathComponent("saving-\(UUID().uuidString).pdf")
		guard document.write(to: staging, withOptions: options) else {
			FileManager.default.removeIfPresent(staging, log: Log.library)
			throw PDFLibraryError.writeFailed
		}
		do {
			_ = try PDFClaimStripper.stripClaims(inFileAt: staging)
		} catch {
			// The copy is still a good PDF; it just keeps the claim.
			Log.library.error("Removing conformance claims failed: \(error)")
		}
		if FileManager.default.fileExists(atPath: edited.path) {
			_ = try FileManager.default.replaceItemAt(edited, withItemAt: staging)
		} else {
			try FileManager.default.moveItem(at: staging, to: edited)
		}
		return (document.pageCount, PDFFormatInspector.inspect(url: edited))
	}

	/// Throws away Rescriva's edits; the original opens next time. Waits for a save under way, which
	/// would otherwise put the edits back.
	func revertToOriginal(_ item: PDFItem) async throws {
		await waitForSave(of: item.id)
		FileManager.default.removeIfPresent(editedURL(for: item), log: Log.library)
		var updated = item
		updated.editedAt = nil
		updated.pageCount = PDFDocument(url: originalURL(for: item))?.pageCount ?? item.pageCount
		updated.byteCount = fileSize(originalURL(for: item))
		try update(updated)
		thumbnails.removeAllObjects()
		indexText(of: updated)
	}

	// MARK: Library actions

	func rename(_ item: PDFItem, to title: String) {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		var updated = item
		updated.title = trimmed
		save(updated)
	}

	func toggleFave(_ item: PDFItem) {
		var updated = item
		updated.fave.toggle()
		save(updated)
	}

	func delete(_ item: PDFItem) {
		FileManager.default.removeIfPresent(folder(for: item.id), log: Log.library)
		items.removeAll { $0.id == item.id }
		texts[item.id] = nil
	}

	// MARK: Search

	/// True when the title or the PDF's text contains `query` (case and accent insensitive).
	func matches(_ item: PDFItem, query: String) -> Bool {
		if item.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
		if texts[item.id] == nil {
			texts[item.id] = (try? String(contentsOf: textURL(for: item.id), encoding: .utf8)) ?? ""
		}
		return texts[item.id]?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
	}

	/// Extracts the PDF's text off the main thread for Library search.
	private func indexText(of item: PDFItem) {
		let source = currentURL(for: item)
		let destination = textURL(for: item.id)
		texts[item.id] = nil
		Task.detached(priority: .utility) {
			let text = PDFDocument(url: source)?.string ?? ""
			do {
				try text.write(to: destination, atomically: true, encoding: .utf8)
			} catch {
				Log.library.error("Couldn't save a PDF's text for search: \(error)")
			}
		}
	}

	// MARK: Thumbnails

	/// Page `index` of `item`, drawn `width` points wide, cached until the next save.
	func thumbnail(for item: PDFItem, page index: Int = 0, width: CGFloat) async -> UIImage? {
		let key = "\(item.id.uuidString)-\(item.editedAt?.timeIntervalSince1970 ?? 0)-\(index)-\(Int(width))" as NSString
		if let cached = thumbnails.object(forKey: key) { return cached }
		let url = currentURL(for: item)
		let scale = max(UITraitCollection.current.displayScale, 2)
		let image = await Task.detached(priority: .utility) { () -> UIImage? in
			guard let document = PDFDocument(url: url), !document.isLocked, let page = document.page(at: index) else { return nil }
			let bounds = page.bounds(for: .cropBox)
			let quarterTurned = (page.rotation / 90) % 2 != 0
			let aspect = quarterTurned ? bounds.width / max(bounds.height, 1) : bounds.height / max(bounds.width, 1)
			return page.thumbnail(of: CGSize(width: width * scale, height: width * aspect * scale), for: .cropBox)
		}.value
		if let image { thumbnails.setObject(image, forKey: key) }
		return image
	}

	// MARK: Storage

	/// `update`, logging a failure (a favorite or a title that doesn't stick is no reason to stop).
	private func save(_ item: PDFItem) {
		do {
			try update(item)
		} catch {
			Log.library.error("Couldn't save a PDF's details: \(error)")
		}
	}

	private func update(_ item: PDFItem) throws {
		try writeInfo(item)
		if let index = items.firstIndex(where: { $0.id == item.id }) {
			items[index] = item
		}
	}

	private func writeInfo(_ item: PDFItem) throws {
		let data = try JSONEncoder.rescriva.encode(item)
		try data.write(to: infoURL(for: item.id), options: .atomic)
	}

	private func fileSize(_ url: URL) -> Int64 {
		((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
	}
}
