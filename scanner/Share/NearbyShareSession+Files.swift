//
//  NearbyShareSession+Files.swift
//  Rescriva (fork of Open Scanner)
//
//  The files behind a Share Nearby session, in three types rather than an extension of the session
//  (the file keeps its name because renaming it means touching the project file): NearbyShareFiles
//  makes, imports and sweeps them, NearbyShareChunkFile reads or writes one a chunk at a time off
//  the main actor, and NearbyShareUpload is one file arriving from a page. What's shared is copied
//  into its own folder first, so a page always downloads a fixed file:
//
//      tmp/NearbyShare/<session>/<document id>/<name>   deleted when the session stops
//      tmp/NearbyShareReceived/<uuid>/<name>             one upload, deleted once it's imported
//
//  Received files live outside the session's folder, so an import that finishes after the
//  session stops (the app went to the background) still has its file. Folders left behind in
//  either place when the app was killed mid-share go when the next run's first session starts.
//

import CoreData
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A shared document's file, ready to send.
struct NearbySharePreparedFile: Equatable {
	let url: URL
	let name: String
	let size: Int64
	/// Its MIME type, for the page.
	let type: String
}

enum NearbyShareFileError: LocalizedError {
	case missing
	case unreadable

	var errorDescription: String? {
		switch self {
		case .missing: return String(localized: "It isn't in the Library any more.")
		case .unreadable: return String(localized: "Rescriva couldn't read it.")
		}
	}
}

@MainActor
enum NearbyShareFiles {
	/// Whether this process has cleared out what earlier runs left in tmp/NearbyShare/.
	private static var sweptLeftovers = false

	/// tmp/NearbyShare/, which holds a folder for each session.
	nonisolated static var sessionsFolder: URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("NearbyShare", isDirectory: true)
	}

	static func sessionFolder(_ session: String) -> URL {
		sessionsFolder.appendingPathComponent(session, isDirectory: true)
	}

	/// tmp/NearbyShareReceived/, which holds a folder for each upload.
	nonisolated static var receivedFolderRoot: URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("NearbyShareReceived", isDirectory: true)
	}

	/// The folder for a session that's starting. The first session in this process also deletes
	/// every other folder in tmp/NearbyShare/ and every folder in tmp/NearbyShareReceived/: none
	/// of them are this process's (nothing is received before a session starts), so they're what
	/// earlier runs left when the app was killed mid-share.
	static func startingSessionFolder(_ session: String) -> URL {
		if !sweptLeftovers {
			sweptLeftovers = true
			removeInBackground(leftoverFolders(in: sessionsFolder, keeping: [session])
				+ leftoverFolders(in: receivedFolderRoot, keeping: []))
		}
		return sessionFolder(session)
	}

	/// The folders in `root` that aren't named in `keeping`. Files are left alone; a missing
	/// `root` has none.
	nonisolated static func leftoverFolders(in root: URL, keeping: Set<String>) -> [URL] {
		guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
			return []
		}
		return contents.filter { url in
			let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
			return isFolder && !keeping.contains(url.lastPathComponent)
		}
	}

	/// Deletes `folders` off the main thread.
	private static func removeInBackground(_ folders: [URL]) {
		guard !folders.isEmpty else { return }
		Task.detached(priority: .utility) {
			for folder in folders {
				FileManager.default.removeIfPresent(folder, log: Log.share)
			}
		}
	}

	/// A fresh folder for one upload.
	static func receivedFolder() -> URL {
		receivedFolderRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
	}

	/// Deletes `url` if it's there. Runs on any thread.
	nonisolated static func remove(_ url: URL?) {
		guard let url else { return }
		FileManager.default.removeIfPresent(url, log: Log.share)
	}

	/// The folder `ExportService.makeFile` made for `url` (tmp/Exports/<uuid>/), or nil when `url`
	/// isn't one of its files.
	nonisolated static func exportFolder(of url: URL, temporaryDirectory: URL) -> URL? {
		guard url.isFileURL else { return nil }
		let exports = temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
			.standardizedFileURL.resolvingSymlinksInPath()
		let folder = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
		guard UUID(uuidString: folder.lastPathComponent) != nil,
			  folder.deletingLastPathComponent().path == exports.path else { return nil }
		return folder
	}

	/// Deletes the export folders behind `items`' files, once the Share Nearby screen they were
	/// handed to has closed. A session only shares its own copy, so nothing else needs them.
	static func removeExports(of items: [NearbyShareItem]) {
		let temporary = FileManager.default.temporaryDirectory
		for case .file(let url, _) in items {
			remove(exportFolder(of: url, temporaryDirectory: temporary))
		}
	}

	/// The name to show while the file is being made.
	static func provisionalName(for item: NearbyShareItem, library: PDFLibrary) -> String {
		switch item {
		case .scan(let scan):
			return ExportService.fileName(for: scan, format: .pdf)
		case .pdf(let id):
			let title = library.item(id)?.title ?? String(localized: "PDF")
			return NearbyShareInput.fileName(title, fallback: "PDF") + ".pdf"
		case .file(let url, let name):
			return NearbyShareInput.fileName(name, fallback: url.lastPathComponent)
		}
	}

	/// The message a document shows when it couldn't be made.
	static func problem(_ error: Error) -> String {
		if let error = error as? NearbyShareFileError, let text = error.errorDescription { return text }
		return String(localized: "Rescriva couldn't get it ready to share.")
	}

	// MARK: Preparing

	/// Makes `item`'s file inside `folder` (created here, and removed again if this fails).
	static func prepare(_ item: NearbyShareItem, into folder: URL,
						library: PDFLibrary) async -> Result<NearbySharePreparedFile, Error> {
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			let url: URL
			switch item {
			case .scan(let scan): url = try await exportScan(scan, into: folder)
			case .pdf(let id): url = try await copyPDF(id, into: folder, library: library)
			case .file(let source, let name): url = try await copyFile(source, named: name, into: folder)
			}
			return .success(try describe(url))
		} catch {
			remove(folder)
			return .failure(error)
		}
	}

	/// A scan as a searchable PDF, with its notes.
	private static func exportScan(_ scan: Scan, into folder: URL) async throws -> URL {
		guard !scan.isDeleted, scan.managedObjectContext != nil else { throw NearbyShareFileError.missing }
		let exported = try await ExportService.makeFile(for: scan, format: .pdf, includeNotes: true)
		defer { remove(exported.deletingLastPathComponent()) }
		let destination = folder.appendingPathComponent(exported.lastPathComponent)
		try FileManager.default.moveItem(at: exported, to: destination)
		return destination
	}

	/// A PDF Files item as it is now, once any save under way has finished.
	private static func copyPDF(_ id: UUID, into folder: URL, library: PDFLibrary) async throws -> URL {
		await library.waitForSave(of: id)
		guard let item = library.item(id) else { throw NearbyShareFileError.missing }
		let name = NearbyShareInput.fileName(item.title, fallback: "PDF") + ".pdf"
		let destination = folder.appendingPathComponent(name)
		try await copyOffMain(library.currentURL(for: item), to: destination)
		return destination
	}

	private static func copyFile(_ source: URL, named name: String, into folder: URL) async throws -> URL {
		let destination = folder.appendingPathComponent(NearbyShareInput.fileName(name, fallback: source.lastPathComponent))
		let scoped = source.startAccessingSecurityScopedResource()
		defer { if scoped { source.stopAccessingSecurityScopedResource() } }
		try await copyOffMain(source, to: destination)
		return destination
	}

	private static func copyOffMain(_ source: URL, to destination: URL) async throws {
		try await Task.detached(priority: .userInitiated) {
			try FileManager.default.copyItem(at: source, to: destination)
		}.value
	}

	private static func describe(_ url: URL) throws -> NearbySharePreparedFile {
		guard let size = size(of: url) else { throw NearbyShareFileError.unreadable }
		return NearbySharePreparedFile(url: url, name: url.lastPathComponent, size: size, type: mimeType(of: url))
	}

	nonisolated static func size(of url: URL) -> Int64? {
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
			  let size = attributes[.size] as? NSNumber else { return nil }
		return size.int64Value
	}

	static func mimeType(of url: URL) -> String {
		UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
	}

	// MARK: Receiving

	/// Brings a received file into the Library: a PDF into PDF Files (titled with its name), an
	/// image as a new scan. False when it won't open.
	static func importReceived(_ url: URL, name: String, type: String, library: PDFLibrary,
							   context: NSManagedObjectContext) async -> Bool {
		if type == "application/pdf" {
			do {
				_ = try await library.importPDF(at: url, title: NearbyShareInput.title(fromFileName: name))
				return true
			} catch {
				Log.share.error("Share Nearby couldn't import a received PDF: \(error)")
				return false
			}
		}
		let maxSide = maxImageSide
		let decoded = await Task.detached(priority: .userInitiated) {
			NearbyShareFiles.image(at: url, maxSide: maxSide)
		}.value
		guard let image = decoded else {
			Log.share.notice("Share Nearby received an image that won't open")
			return false
		}
		return await PhotoImport.scan(from: [image], in: context) != nil
	}

	/// A received picture's longest side once it's scaled down: a phone camera's full size.
	static let maxImageSide = 4_096
	/// Pictures with more pixels than this aren't decoded at all.
	nonisolated static let maxImagePixels = 200_000_000

	/// The picture at `url`, upright and scaled down to at most `maxSide` pixels on its longest
	/// side, read straight from the file without holding all of it in memory. Nil when it won't
	/// open or is absurdly large. Runs on any thread.
	nonisolated static func image(at url: URL, maxSide: Int) -> UIImage? {
		let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
		guard maxSide > 0, let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
			  CGImageSourceGetCount(source) > 0 else { return nil }
		guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
			  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
			  width > 0, height > 0, width <= maxImagePixels / height else { return nil }
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,
			kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(width, height)),
		]
		guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
		return UIImage(cgImage: image)
	}
}

/// A file read or written a chunk at a time on its own queue, so the main actor never waits on
/// the disk between chunks. The handle is touched only on that queue; what the main actor sees is
/// whether a write has failed. Safe to share across threads for that reason.
final class NearbyShareChunkFile: @unchecked Sendable {
	private let queue = DispatchQueue(label: "com.rescriva.share.chunkfile", qos: .userInitiated)
	private let handle: FileHandle
	private let lock = NSLock()
	private var failure: Error?
	private var isClosed = false

	/// The file at `url`, to be read with `read(upTo:)`.
	init(readingFrom url: URL) throws {
		handle = try FileHandle(forReadingFrom: url)
	}

	/// The file at `url`, to be appended to with `append(_:)`.
	init(writingTo url: URL) throws {
		handle = try FileHandle(forWritingTo: url)
	}

	/// True once a queued write has failed; later writes are refused.
	var hasFailed: Bool {
		lock.lock()
		defer { lock.unlock() }
		return failure != nil
	}

	/// The next `count` bytes, read on the queue. Nil at the end of the file or when the read fails.
	func read(upTo count: Int) async -> Data? {
		guard count > 0 else { return nil }
		return await withCheckedContinuation { continuation in
			queue.async {
				guard !self.isClosed else { return continuation.resume(returning: nil) }
				do {
					let data = try self.handle.read(upToCount: count)
					continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 })
				} catch {
					Log.share.error("Share Nearby couldn't read a shared file: \(error)")
					continuation.resume(returning: nil)
				}
			}
		}
	}

	/// Queues `data` to be written after everything queued before it. False when an earlier write
	/// failed, so the caller stops without queueing more.
	func append(_ data: Data) -> Bool {
		guard !hasFailed else { return false }
		queue.async {
			guard !self.isClosed, !self.hasFailed else { return }
			do {
				try self.handle.write(contentsOf: data)
			} catch {
				Log.share.error("Share Nearby couldn't write an upload: \(error)")
				self.lock.lock()
				self.failure = error
				self.lock.unlock()
			}
		}
		return true
	}

	/// Waits for every queued write, then closes the file. False when a write or the close failed.
	func finish() -> Bool {
		queue.sync { () -> Bool in
			guard !isClosed else { return false }
			isClosed = true
			do {
				try handle.close()
			} catch {
				Log.share.error("Share Nearby couldn't finish a file: \(error)")
				return false
			}
			return !hasFailed
		}
	}

	/// Closes the file once the queue is drained, then deletes `folder` when given. Returns at once.
	func discard(deleting folder: URL? = nil) {
		queue.async {
			if !self.isClosed {
				self.isClosed = true
				try? self.handle.close()
			}
			NearbyShareFiles.remove(folder)
		}
	}
}

/// One upload a page offered: waiting for Accept or Decline, then written chunk by chunk.
@MainActor
final class NearbyShareUpload {
	let offerID: String
	let xfer: String
	let name: String
	let size: Int64
	let type: String
	/// Its row in Activity, once accepted.
	var transferID: UUID?
	private(set) var received: Int64 = 0
	private(set) var url: URL?
	/// When the last chunk arrived (or the file was opened), for the stall timer.
	private(set) var lastChunkAt: Date?
	private var file: NearbyShareChunkFile?

	var isReceiving: Bool { file != nil }

	init(offerID: String, xfer: String, name: String, size: Int64, type: String) {
		self.offerID = offerID
		self.xfer = xfer
		self.name = name
		self.size = size
		self.type = type
	}

	/// True when no chunk has come for `limit` seconds, as of `now`.
	func isStalled(at now: Date, limit: TimeInterval) -> Bool {
		guard let lastChunkAt else { return false }
		return now.timeIntervalSince(lastChunkAt) >= limit
	}

	/// Makes the file the bytes go into. False if it can't.
	func open(at now: Date = .now) -> Bool {
		guard file == nil else { return true }
		let folder = NearbyShareFiles.receivedFolder()
		let path = folder.appendingPathComponent(name)
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			guard FileManager.default.createFile(atPath: path.path, contents: nil) else {
				NearbyShareFiles.remove(folder)
				return false
			}
			file = try NearbyShareChunkFile(writingTo: path)
			url = path
			lastChunkAt = now
			return true
		} catch {
			Log.share.error("Share Nearby couldn't make a file for an upload: \(error)")
			NearbyShareFiles.remove(folder)
			return false
		}
	}

	/// Queues a chunk to be written. False when it would run past the size the page offered, or an
	/// earlier chunk didn't write.
	func write(_ data: Data, at now: Date = .now) -> Bool {
		guard let file, received + Int64(data.count) <= size, file.append(data) else { return false }
		received += Int64(data.count)
		lastChunkAt = now
		return true
	}

	/// Closes the file and returns it when every byte arrived and was written. Otherwise it's
	/// deleted, and nil.
	func finish() -> URL? {
		guard let file, let url else { return nil }
		self.file = nil
		guard file.finish(), received == size else {
			NearbyShareFiles.remove(url.deletingLastPathComponent())
			self.url = nil
			return nil
		}
		return url
	}

	/// Stops writing and deletes what arrived.
	func discard() {
		let folder = url?.deletingLastPathComponent()
		if let file {
			file.discard(deleting: folder)
		} else {
			NearbyShareFiles.remove(folder)
		}
		file = nil
		url = nil
	}
}
