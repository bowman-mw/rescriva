//
//  OriginalStore.swift
//  Rescriva (fork of Open Scanner)
//
//  The original photo behind each page, kept so its crop, rotation and
//  cleanup can be redone later (see PageReprocessor). Originals are files in
//  Application Support/Originals named by the capture's id, on this iPhone
//  only: they stay out of Core Data so CloudKit never syncs them (that would
//  roughly double what a library costs in iCloud), and out of device backups
//  for the same reason. A page synced from another device simply has no
//  original here; it can still be rotated.
//
//  An original is written to Originals/Staging as soon as it's encoded, so
//  a long camera session or a big import holds file names, not megabytes.
//  Saving the page moves the file into place under the capture's id (a
//  rename); pages never saved have theirs deleted, and whatever an earlier
//  run left in Staging goes at launch.
//
//  App-target only.
//

import CoreData
import CoreImage
import Foundation
import ImageIO

struct OriginalStore {
	/// An original encoded for storage: HEIC where the device can write it, JPEG otherwise.
	struct Encoded {
		let data: Data
		/// "heic" or "jpg".
		let fileExtension: String
	}

	/// An original waiting in the staging folder for its page to be saved (see `stage(_:)`).
	struct Staged: Hashable, Sendable {
		let url: URL
	}

	/// What the originals on this iPhone add up to.
	struct Usage: Equatable {
		var count: Int
		var bytes: Int64
	}

	/// The app's originals.
	static let shared = OriginalStore(directory: defaultDirectory)
	/// Originals are capped at this long side (12 MP on current iPhones), ample for a 2400 px page.
	static let maxLongSide: CGFloat = 4032
	static let compressionQuality: CGFloat = 0.9
	/// Extensions an original can have, in lookup order.
	static let fileExtensions = ["heic", "jpg"]
	/// Thread-safe, so encoders on any queue may share it.
	private static let encodingContext = CIContext(options: [.cacheIntermediates: false])

	/// Where the files live.
	let directory: URL

	/// Where originals wait for their pages to be saved: inside `directory`, so keeping one is a
	/// rename on the same volume. The originals' own listing skips it (it isn't `<uuid>.<ext>`).
	var stagingDirectory: URL {
		directory.appendingPathComponent("Staging", isDirectory: true)
	}

	static var defaultDirectory: URL {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		return support.appendingPathComponent("Originals", isDirectory: true)
	}

	// MARK: Encoding

	/// Encodes an upright still for storage, scaled down (never up) to `maxLongSide`.
	static func encode(_ image: CIImage, context: CIContext? = nil) -> Encoded? {
		let limited = PageCleanup.limitLongSide(image, to: maxLongSide)
		let origin = limited.extent.origin
		let upright = limited.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
		guard !upright.extent.isInfinite, upright.extent.width >= 1, upright.extent.height >= 1,
			  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
		let renderer = context ?? encodingContext
		let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
		let options: [CIImageRepresentationOption: Any] = [quality: compressionQuality]
		if let heic = renderer.heifRepresentation(of: upright, format: .RGBA8, colorSpace: colorSpace, options: options) {
			return Encoded(data: heic, fileExtension: "heic")
		}
		guard let jpeg = renderer.jpegRepresentation(of: upright, colorSpace: colorSpace, options: options) else { return nil }
		return Encoded(data: jpeg, fileExtension: "jpg")
	}

	// MARK: Staging (any thread)

	/// Encodes an upright still (as `encode(_:context:)` does) straight into the staging folder; the
	/// encoded bytes are released on return. Nil, logged, when it can't be encoded or written: the
	/// page is then kept without its original.
	func stage(_ image: CIImage, context: CIContext? = nil) -> Staged? {
		guard let encoded = Self.encode(image, context: context) else { return nil }
		do {
			return try stage(encoded)
		} catch {
			Log.library.error("Couldn't stage an original: \(error)")
			return nil
		}
	}

	/// Writes `encoded` to the staging folder under a fresh name.
	func stage(_ encoded: Encoded) throws -> Staged {
		guard Self.fileExtensions.contains(encoded.fileExtension), !encoded.data.isEmpty else {
			throw CocoaError(.fileWriteUnknown)
		}
		try prepareStagingDirectory()
		let url = stagingDirectory.appendingPathComponent("\(UUID().uuidString).\(encoded.fileExtension)")
		try encoded.data.write(to: url, options: .atomic)
		return Staged(url: url)
	}

	/// Moves a staged original into the store as the original for `id`, replacing any earlier one.
	/// The file is touched as it lands, so the orphan cleanup (which spares new files) sees a page
	/// being saved now rather than a photo taken a while ago.
	func keep(_ staged: Staged, for id: UUID) throws {
		let fileExtension = staged.url.pathExtension.lowercased()
		guard Self.fileExtensions.contains(fileExtension) else { throw CocoaError(.fileWriteUnknown) }
		try prepareDirectory()
		remove(id)
		let destination = fileURL(for: id, fileExtension: fileExtension)
		try FileManager.default.moveItem(at: staged.url, to: destination)
		do {
			try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
		} catch {
			Log.library.error("Couldn't touch a kept original: \(error)")
		}
	}

	/// Deletes staged originals whose pages weren't saved. Ones already gone are skipped.
	func discard(_ staged: [Staged]) {
		for file in staged where FileManager.default.fileExists(atPath: file.url.path) {
			do {
				try FileManager.default.removeItem(at: file.url)
			} catch {
				Log.library.error("Couldn't remove a staged original: \(error)")
			}
		}
	}

	/// `discard(_:)` on a background task, for the main thread. The task is on purpose not tied
	/// to the screen that gave the pages up: a staged file whose page is gone must go whether or
	/// not the camera is still showing. It's returned (nil when there was nothing to discard) so a
	/// caller that needs to can wait for it or cancel it.
	@discardableResult
	func discardLater(_ staged: [Staged]) -> Task<Void, Never>? {
		guard !staged.isEmpty else { return nil }
		let store = self
		return Task.detached(priority: .utility) {
			store.discard(staged)
		}
	}

	/// Deletes staged originals last written before `cutoff` (at launch: everything an earlier run
	/// left, its pages never saved). Returns how many files went.
	@discardableResult
	func sweepStaging(before cutoff: Date) -> Int {
		guard FileManager.default.fileExists(atPath: stagingDirectory.path) else { return 0 }
		let urls: [URL]
		do {
			urls = try FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
		} catch {
			Log.library.error("Couldn't list staged originals: \(error)")
			return 0
		}
		var removed = 0
		for url in urls {
			let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
			guard (values?.contentModificationDate ?? .distantPast) < cutoff else { continue }
			do {
				try FileManager.default.removeItem(at: url)
				removed += 1
			} catch {
				Log.library.error("Couldn't remove a staged original: \(error)")
			}
		}
		return removed
	}

	// MARK: Files

	/// The file an original with `fileExtension` would have.
	func fileURL(for id: UUID, fileExtension: String) -> URL {
		directory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
	}

	/// The stored original for `id`, if this iPhone has one.
	func url(for id: UUID) -> URL? {
		Self.fileExtensions.lazy
			.map { fileURL(for: id, fileExtension: $0) }
			.first { FileManager.default.fileExists(atPath: $0.path) }
	}

	func contains(_ id: UUID) -> Bool {
		url(for: id) != nil
	}

	/// Writes `encoded` as the original for `id`, replacing any earlier one.
	func save(_ encoded: Encoded, for id: UUID) throws {
		guard Self.fileExtensions.contains(encoded.fileExtension), !encoded.data.isEmpty else {
			throw CocoaError(.fileWriteUnknown)
		}
		try prepareDirectory()
		remove(id)
		try encoded.data.write(to: fileURL(for: id, fileExtension: encoded.fileExtension), options: .atomic)
	}

	/// Gives `newID` its own copy of the original for `id`, replacing any it had. Two pages made from
	/// one photo (a spread split in two) each keep a file under their own id, so deleting either page
	/// deletes only its own. On APFS the copy is a clone, which takes no more space until one of them
	/// changes, and originals never do. The copy is touched as it lands, as `keep` does.
	func copy(_ id: UUID, to newID: UUID) throws {
		guard id != newID, let source = url(for: id) else { throw CocoaError(.fileNoSuchFile) }
		let destination = fileURL(for: newID, fileExtension: source.pathExtension.lowercased())
		remove(newID)
		try FileManager.default.copyItem(at: source, to: destination)
		do {
			try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
		} catch {
			Log.library.error("Couldn't touch a copied original: \(error)")
		}
	}

	/// Decodes the original for `id` (upright, as stored), or nil when there is none.
	func loadImage(for id: UUID) -> CGImage? {
		guard let url = url(for: id), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
		let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
		return CGImageSourceCreateImageAtIndex(source, 0, options)
	}

	/// Deletes the original for `id`, in whichever format it was stored.
	func remove(_ id: UUID) {
		for fileExtension in Self.fileExtensions {
			let url = fileURL(for: id, fileExtension: fileExtension)
			guard FileManager.default.fileExists(atPath: url.path) else { continue }
			do {
				try FileManager.default.removeItem(at: url)
			} catch {
				Log.library.error("Couldn't remove an original: \(error)")
			}
		}
	}

	/// Deletes every original. Returns how many files went.
	@discardableResult
	func removeAll() -> Int {
		var removed = 0
		for file in storedFiles() {
			do {
				try FileManager.default.removeItem(at: file.url)
				removed += 1
			} catch {
				Log.library.error("Couldn't remove an original: \(error)")
			}
		}
		return removed
	}

	/// How many originals there are and the space they take.
	func usage() -> Usage {
		storedFiles().reduce(Usage(count: 0, bytes: 0)) { total, file in
			Usage(count: total.count + 1, bytes: total.bytes + file.bytes)
		}
	}

	/// Deletes originals whose id isn't in `ids`, unless they were written after `cutoff` (a page
	/// being saved right now). Returns how many files went.
	///
	/// Does nothing when more than half the originals would go. Deletions from other devices
	/// arrive a few pages at a time, but signing out of iCloud or switching accounts empties the
	/// local mirror of the library at once; its pages come back under the same ids when the
	/// account does, and their originals can't be made again. Leftovers show in Settings, where
	/// they can be removed.
	func pruneOrphans(keeping ids: Set<UUID>, olderThan cutoff: Date) -> Int {
		let files = storedFiles()
		let orphans = files.filter { !ids.contains($0.id) && $0.modified < cutoff }
		guard orphans.count * 2 <= files.count else {
			Log.library.notice("Kept \(orphans.count) of \(files.count) originals whose pages aren't here (iCloud account change?)")
			return 0
		}
		var removed = 0
		for file in orphans {
			do {
				try FileManager.default.removeItem(at: file.url)
				removed += 1
			} catch {
				Log.library.error("Couldn't remove an orphaned original: \(error)")
			}
		}
		return removed
	}

	/// One original on disk.
	private struct StoredFile {
		let id: UUID
		let url: URL
		let bytes: Int64
		let modified: Date
	}

	/// The originals on disk; files that aren't named `<uuid>.<known extension>` are ignored.
	private func storedFiles() -> [StoredFile] {
		let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
		guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
		let urls: [URL]
		do {
			urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
		} catch {
			Log.library.error("Couldn't list originals: \(error)")
			return []
		}
		return urls.compactMap { url -> StoredFile? in
			guard Self.fileExtensions.contains(url.pathExtension.lowercased()),
				  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
			let values = try? url.resourceValues(forKeys: Set(keys))
			return StoredFile(id: id, url: url, bytes: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate ?? .distantPast)
		}
	}

	/// Creates the folder once, excluded from device backups.
	private func prepareDirectory() throws {
		guard !FileManager.default.fileExists(atPath: directory.path) else { return }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		var folder = directory
		try folder.setResourceValues(values)
	}

	/// Creates the staging folder inside the originals' folder, which is made first so it still
	/// gets its backup exclusion (which covers the staging folder too).
	private func prepareStagingDirectory() throws {
		guard !FileManager.default.fileExists(atPath: stagingDirectory.path) else { return }
		try prepareDirectory()
		try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
	}
}

// MARK: - Staging housekeeping

extension OriginalStore {
	/// Clears staged originals an earlier run left behind (its camera session or import never
	/// saved, or the app quit first), off the main thread. Call once as the app starts: the cutoff
	/// is taken now, so pages this run stages are never swept. The sweep belongs to the app, not
	/// to any window, so the task is unowned; it's returned so a caller (a test) can wait for it.
	@discardableResult
	static func sweepStagingAtLaunch(store: OriginalStore = .shared) -> Task<Void, Never> {
		let launch = Date()
		return Task.detached(priority: .utility) {
			let removed = store.sweepStaging(before: launch)
			if removed > 0 {
				Log.library.notice("Removed \(removed) staged originals left from an earlier run")
			}
		}
	}
}

// MARK: - Library housekeeping

extension OriginalStore {
	/// Removes originals whose page no longer exists here: deleted on another device (CloudKit
	/// deletions don't run this app's delete paths) or never saved. Skipped when the library is the
	/// temporary in-memory fallback, which would make every original look orphaned.
	@MainActor
	static func pruneOrphans(in context: NSManagedObjectContext, store: OriginalStore = .shared) async {
		guard context.isLibraryOnDisk else { return }
		let request = NSFetchRequest<NSDictionary>(entityName: "ScanCapture")
		request.resultType = .dictionaryResultType
		request.propertiesToFetch = ["id"]
		let ids: Set<UUID>
		do {
			ids = Set(try context.fetch(request).compactMap { $0["id"] as? UUID })
		} catch {
			Log.library.error("Couldn't list pages for original cleanup: \(error)")
			return
		}
		let cutoff = Date().addingTimeInterval(-3600)
		let removed = await Task.detached(priority: .utility) {
			store.pruneOrphans(keeping: ids, olderThan: cutoff)
		}.value
		if removed > 0 {
			Log.library.notice("Removed \(removed) orphaned originals")
		}
	}
}

extension NSManagedObjectContext {
	/// True when the library is on disk rather than the temporary in-memory fallback, which would
	/// make every file kept beside it look orphaned. Each launch-time cleanup checks it first, and
	/// counts every scan and page still in the library as here, Recently Deleted ones included.
	var isLibraryOnDisk: Bool {
		let stores = persistentStoreCoordinator?.persistentStores ?? []
		return stores.contains { $0.type == NSSQLiteStoreType && $0.url?.path != "/dev/null" }
	}
}

// MARK: - Deleting pages

/// The files kept beside pages and scans being deleted for good (originals, Annotate marks, Quick
/// Look copies, figure pictures, a kept PDF), removed only once the deletion is saved: see
/// `NSManagedObjectContext.saveDeletion(removing:)`. A save that fails then leaves every page it
/// brings back with all of its files.
struct DeletedFiles {
	private var removals: [@MainActor () -> Void] = []

	/// Adds a removal to make once the deletion is saved.
	mutating func add(_ removal: @escaping @MainActor () -> Void) {
		removals.append(removal)
	}

	/// Adds every removal `other` holds.
	mutating func add(_ other: DeletedFiles) {
		removals += other.removals
	}

	/// Makes every removal, in the order they were added.
	@MainActor
	func remove() {
		for removal in removals {
			removal()
		}
	}
}

extension ScanCapture {
	/// Deletes the page for good. Its recognized lines go with it now; its original, its Annotate
	/// marks and its Quick Look copy go once the caller saves the deletion, through
	/// `saveDeletion(removing:)` with what this returns. Use this rather than `context.delete(_:)`,
	/// which would leave the files behind, and (the model's `recognizedItems` rule is Nullify)
	/// strand the lines, still synced and still found by Spotlight. `annotations` defaults to the
	/// shared store.
	@MainActor
	func deleteWithOriginal(originals: OriginalStore = .shared, annotations: AnnotationStore? = nil) -> DeletedFiles {
		var files = DeletedFiles()
		guard let context = managedObjectContext else { return files }
		if let id {
			let marks = annotations ?? .shared
			files.add {
				originals.remove(id)
				marks.removeMarks(for: id)
				QuickLookCopy.remove(for: id)
			}
		}
		for item in recognizedItemsArray {
			context.delete(item)
		}
		context.delete(self)
		return files
	}
}

extension Scan {
	/// Deletes the scan for good with its pages (`deleteWithOriginal`); their files and its figure
	/// pictures go once the caller saves the deletion, through `saveDeletion(removing:)` with what
	/// this returns. (The model's `captures` rule is Nullify, so deleting only the scan would
	/// strand its pages.) Moving a scan to Recently Deleted touches none of this; it comes back whole.
	@MainActor
	func deleteWithPages(originals: OriginalStore = .shared, figures: FigureStore = .shared,
						 annotations: AnnotationStore? = nil) -> DeletedFiles {
		var files = DeletedFiles()
		guard let context = managedObjectContext else { return files }
		if let id {
			files.add { figures.removeAll(for: id) }
		}
		for capture in capturesArray {
			files.add(capture.deleteWithOriginal(originals: originals, annotations: annotations))
		}
		context.delete(self)
		return files
	}
}

extension NSManagedObjectContext {
	/// Saves pages and scans deleted for good (`deleteWithOriginal`, `deleteWithPages`), then
	/// removes their files. When the save fails (a full disk, say) the deletion is rolled back and
	/// every file kept, so nothing comes back from the store without its original, marks or
	/// figures. Returns whether the deletion was saved.
	@MainActor
	@discardableResult
	func saveDeletion(removing files: DeletedFiles) -> Bool {
		do {
			try save()
		} catch {
			Log.library.error("Couldn't save a deletion, so it's undone and its files are kept: \(error)")
			rollback()
			return false
		}
		files.remove()
		return true
	}
}
