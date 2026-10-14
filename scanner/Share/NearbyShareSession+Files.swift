//
//  NearbyShareSession+Files.swift
//  Rescriva (fork of Open Scanner)
//
//  The files behind a Share Nearby session, in types of their own rather than an extension of the
//  session (the file keeps its name because renaming it means touching the project file):
//  NearbyShareFiles makes, saves and sweeps them, NearbyShareChunkFile reads or writes one a chunk
//  at a time off the main actor, NearbyShareUpload is one file arriving from a page, and
//  NearbySharePhotos puts received pictures and videos in the Photos library. What's shared is
//  copied into its own folder first, so a page always downloads a fixed file:
//
//      tmp/NearbyShare/<session>/<document id>/<name>   deleted when the session stops
//      tmp/NearbySharePicked/<uuid>/<name>               a picked photo, on its way to the above
//      tmp/NearbyShareReceived/<uuid>/<name>             one upload, deleted once it's saved
//
//  A received file is saved by its kind: a PDF in PDF Files, a picture or video in Photos, and
//  anything else in Documents/Received, which the Files app shows as On My iPhone › Rescriva ›
//  Received (Downloads, on a Mac). Until then it lives outside the session's folder, so a save
//  that finishes after the session stops (the app went to the background) still has its file.
//  Folders left behind in tmp/ when the app was killed mid-share go when the next run's first
//  session starts.
//

import CoreData
import Foundation
import Photos
import PhotosUI
import SwiftUI
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

	/// tmp/NearbySharePicked/, which holds a folder for each photo the picker hands over.
	nonisolated static var pickedFolderRoot: URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("NearbySharePicked", isDirectory: true)
	}

	/// The folder for a session that's starting. The first session in this process also deletes
	/// every other folder in tmp/NearbyShare/ and every folder in tmp/NearbyShareReceived/ and
	/// tmp/NearbySharePicked/: none of them are this process's (nothing is received or picked
	/// before a session starts), so they're what earlier runs left when the app was killed
	/// mid-share.
	static func startingSessionFolder(_ session: String) -> URL {
		if !sweptLeftovers {
			sweptLeftovers = true
			removeInBackground(leftoverFolders(in: sessionsFolder, keeping: [session])
				+ leftoverFolders(in: receivedFolderRoot, keeping: [])
				+ leftoverFolders(in: pickedFolderRoot, keeping: []))
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
		case .photo:
			return String(localized: "Photo")
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
			case .photo(let item): url = try await loadPhoto(item, into: folder)
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

	/// A file that's already made, or one picked in Files. It's read through a file coordinator, so
	/// a file in iCloud Drive that isn't on the device yet is downloaded first.
	private static func copyFile(_ source: URL, named name: String, into folder: URL) async throws -> URL {
		let destination = folder.appendingPathComponent(NearbyShareInput.fileName(name, fallback: source.lastPathComponent))
		try await Task.detached(priority: .userInitiated) {
			let scoped = source.startAccessingSecurityScopedResource()
			defer { if scoped { source.stopAccessingSecurityScopedResource() } }
			try NearbyShareFiles.coordinatedCopy(source, to: destination)
		}.value
		return destination
	}

	/// Copies `source` to `destination` under a file coordinator. A folder or a package isn't one
	/// file a page can download, so it's refused.
	nonisolated private static func coordinatedCopy(_ source: URL, to destination: URL) throws {
		var coordinationError: NSError?
		var copyError: Error?
		NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
			do {
				guard try readable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
					throw NearbyShareFileError.unreadable
				}
				try FileManager.default.copyItem(at: readable, to: destination)
			} catch {
				copyError = error
			}
		}
		if let error = coordinationError ?? copyError { throw error }
	}

	/// A photo or video picked from the Photos library, moved into `folder`. The picker is asked
	/// for the `.compatible` encoding, so a HEIC picture comes as a JPEG and an HEVC video as
	/// H.264, which any computer opens.
	private static func loadPhoto(_ item: PhotosPickerItem, into folder: URL) async throws -> URL {
		guard let picked = try await item.loadTransferable(type: NearbySharePickedFile.self) else {
			throw NearbyShareFileError.missing
		}
		defer { remove(picked.url.deletingLastPathComponent()) }
		let destination = folder.appendingPathComponent(picked.url.lastPathComponent)
		try FileManager.default.moveItem(at: picked.url, to: destination)
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

	/// Documents/Received, which the Files app shows as On My iPhone › Rescriva › Received; on a
	/// Mac, Downloads. Not the top of Documents: earlier versions wrote Quick Look's copies there,
	/// and the sweep at launch deletes whatever is named like one ("scan.jpg").
	nonisolated static var receivedFilesFolder: URL {
		#if targetEnvironment(macCatalyst)
		return URL.downloadsDirectory
		#else
		return URL.documentsDirectory.appendingPathComponent("Received", isDirectory: true)
		#endif
	}

	/// Saves a received file where its kind belongs: a PDF in PDF Files (titled with its name), a
	/// picture or a video in Photos, anything else in `filesFolder`. What won't go where it
	/// belongs (a PDF that won't open, a picture Photos refuses or may not have) goes in
	/// `filesFolder` too, so nothing accepted is lost. Where it went, or nil when it couldn't be
	/// saved anywhere. Leaves `url` behind only when it wasn't moved into `filesFolder`.
	static func saveReceived(_ url: URL, name: String, type: String, library: PDFLibrary,
							 photos: any NearbySharePhotoSaving, filesFolder: URL) async -> NearbyShareSavedFile? {
		let kind = NearbyShareInput.uploadKind(type: type)
		var photosAccessOff = false
		switch kind {
		case .pdf:
			if await importPDF(url, name: name, library: library) { return NearbyShareSavedFile(destination: .pdfFiles, name: name) }
		case .picture, .video:
			let result = await photos.add(url, name: name, type: type, isVideo: kind == .video)
			if result == .saved { return NearbyShareSavedFile(destination: .photos, name: name) }
			photosAccessOff = result == .noAccess
		case .file:
			break
		}
		let filesName = nameForFiles(name, type: type)
		let moved = await Task.detached(priority: .userInitiated) {
			NearbyShareFiles.move(url, into: filesFolder, named: filesName)
		}.value
		guard let moved else { return nil }
		return NearbyShareSavedFile(destination: .files(photosAccessOff: photosAccessOff), name: moved.lastPathComponent)
	}

	/// `name` with the extension its type calls for when it has none ("Clip" sent as video/mp4
	/// is "Clip.mp4"), so Files knows what opens it. A name with an extension, or a file of no
	/// known type, keeps its name.
	nonisolated static func nameForFiles(_ name: String, type: String) -> String {
		guard (name as NSString).pathExtension.isEmpty, type != NearbyShareInput.unknownType,
			  let ext = UTType(mimeType: type)?.preferredFilenameExtension, !ext.isEmpty else { return name }
		return name + "." + ext
	}

	/// Copies a received PDF into PDF Files. False when it won't open there.
	private static func importPDF(_ url: URL, name: String, library: PDFLibrary) async -> Bool {
		do {
			_ = try await library.importPDF(at: url, title: NearbyShareInput.title(fromFileName: name))
			return true
		} catch {
			Log.share.error("Share Nearby couldn't import a received PDF, so it goes in Files: \(error)")
			return false
		}
	}

	/// How far "name 2", "name 3"… go looking for a free name.
	nonisolated static let maxNameNumber = 999

	/// Moves `url` into `folder` (made if need be) as `name`, or "name 2", "name 3"… when that's
	/// taken, so nothing already there is replaced. Its new place, or nil. Runs on any thread.
	nonisolated static func move(_ url: URL, into folder: URL, named name: String) -> URL? {
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		} catch {
			Log.share.error("Share Nearby couldn't make the folder for received files: \(error)")
			return nil
		}
		for number in 1...maxNameNumber {
			let destination = folder.appendingPathComponent(numberedName(name, number))
			do {
				try FileManager.default.moveItem(at: url, to: destination)
				return destination
			} catch let error as CocoaError where error.code == .fileWriteFileExists {
				continue
			} catch {
				Log.share.error("Share Nearby couldn't save a received file: \(error)")
				return nil
			}
		}
		Log.share.error("Share Nearby found no free name for a received file")
		return nil
	}

	/// `name` for the first, then "name 2", "name 3"… with the extension kept at the end
	/// ("Notes 2.zip").
	nonisolated static func numberedName(_ name: String, _ number: Int) -> String {
		guard number > 1 else { return name }
		let ext = (name as NSString).pathExtension
		let stem = (name as NSString).deletingPathExtension
		return ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
	}
}

/// A received file once it's saved: where, and under what name ("Notes 2.zip" when Files had a
/// "Notes.zip" already).
struct NearbyShareSavedFile: Equatable {
	let destination: NearbyShareDestination
	let name: String
}

/// Where a received file was saved.
enum NearbyShareDestination: Equatable {
	case pdfFiles
	case photos
	/// `NearbyShareFiles.receivedFilesFolder`. `photosAccessOff` when it's a picture or video that
	/// went there because Rescriva may not add to Photos.
	case files(photosAccessOff: Bool)
}

/// What adding a received picture or video to Photos came to.
enum NearbySharePhotoResult: Equatable {
	case saved
	/// Rescriva may not add to Photos: the person said no, or it's restricted.
	case noAccess
	/// Photos wouldn't take the file.
	case failed
}

/// Puts received pictures and videos in the Photos library. Tests stand in their own.
protocol NearbySharePhotoSaving: Sendable {
	/// Asks for permission to add to Photos when it hasn't been asked yet, without waiting for
	/// the answer: called on Accept, so the question comes while the person is looking.
	func askIfUndecided()
	/// True when Rescriva has been told it may not add to Photos (or Photos is restricted), so a
	/// picture would go to Files.
	var isRefused: Bool { get }
	/// Adds the file at `url`, which stays where it is, asking for permission first if need be.
	/// `type` is its MIME type, in case its name has no extension to go by.
	func add(_ url: URL, name: String, type: String, isVideo: Bool) async -> NearbySharePhotoResult
}

/// The Photos library, with add-only access: Rescriva can put pictures in but can't see any.
/// Not on the main actor: Photos runs the change block on a queue of its own.
struct NearbySharePhotos: NearbySharePhotoSaving {
	func askIfUndecided() {
		guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined else { return }
		PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
	}

	var isRefused: Bool {
		let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
		return status == .denied || status == .restricted
	}

	func add(_ url: URL, name: String, type: String, isVideo: Bool) async -> NearbySharePhotoResult {
		let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
		guard status == .authorized || status == .limited else {
			Log.share.notice("Share Nearby may not add to Photos, so a received picture goes in Files")
			return .noAccess
		}
		do {
			try await PHPhotoLibrary.shared().performChanges {
				let options = PHAssetResourceCreationOptions()
				options.originalFilename = name
				options.uniformTypeIdentifier = UTType(mimeType: type)?.identifier
				PHAssetCreationRequest.forAsset().addResource(with: isVideo ? .video : .photo, fileURL: url, options: options)
			}
			return .saved
		} catch {
			Log.share.error("Photos wouldn't take a received file, so it goes in Files: \(error)")
			return .failed
		}
	}
}

/// A picked photo or video as the picker hands it over. The picker deletes its own copy once
/// the import returns, so the file is copied into a fresh folder in tmp/NearbySharePicked/ first.
struct NearbySharePickedFile: Transferable {
	let url: URL

	static var transferRepresentation: some TransferRepresentation {
		FileRepresentation(importedContentType: .image) { received in try Self(copying: received.file) }
		FileRepresentation(importedContentType: .movie) { received in try Self(copying: received.file) }
	}

	private init(copying file: URL) throws {
		let folder = NearbyShareFiles.pickedFolderRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let destination = folder.appendingPathComponent(NearbyShareInput.fileName(file.lastPathComponent, fallback: "Photo"))
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try FileManager.default.copyItem(at: file, to: destination)
		} catch {
			NearbyShareFiles.remove(folder)
			throw error
		}
		url = destination
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
