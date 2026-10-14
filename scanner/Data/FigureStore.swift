//
//  FigureStore.swift
//  Rescriva (fork of Open Scanner)
//
//  Where the pictures of a rebuilt document's figures live: JPEG files in
//  Application Support/Figures/<scan id>/<asset id>.jpg, on this iPhone only.
//  They are a cache, never the only copy: the rebuilt document (which syncs)
//  keeps each figure's box, and a missing picture is cut again from its page
//  (FigureCrop), from the original photo when this iPhone has it. So they
//  stay out of Core Data, CloudKit and device backups.
//
//  A picture goes when nothing needs it any more: its scan is deleted, its
//  figure is removed in Review, or its page is re-made or rebuilt (a rebuilt
//  page's figures get fresh asset ids). A page waiting to be rebuilt has no
//  pictures, so none is ever cut from pixels its boxes don't match. Folders
//  of scans deleted on other devices go at launch.
//
//  App-target only.
//

import CoreData
import Foundation
import UIKit

struct FigureStore: Sendable {
	/// The app's figure pictures.
	static let shared = FigureStore(directory: defaultDirectory)
	static let fileExtension = "jpg"

	/// Where the files live, one folder per scan.
	let directory: URL

	static var defaultDirectory: URL {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		return support.appendingPathComponent("Figures", isDirectory: true)
	}

	// MARK: Files

	func folder(for scanID: UUID) -> URL {
		directory.appendingPathComponent(scanID.uuidString, isDirectory: true)
	}

	/// The file for `assetID`, or nil when the id isn't a UUID. Asset ids come from synced documents,
	/// so one is never trusted as a path.
	func fileURL(for assetID: String, scanID: UUID) -> URL? {
		guard let id = UUID(uuidString: assetID) else { return nil }
		return folder(for: scanID).appendingPathComponent("\(id.uuidString).\(Self.fileExtension)")
	}

	/// The stored picture for `assetID`, if there is one.
	func data(for assetID: String, scanID: UUID) -> Data? {
		guard let url = fileURL(for: assetID, scanID: scanID), FileManager.default.fileExists(atPath: url.path) else { return nil }
		do {
			return try Data(contentsOf: url)
		} catch {
			Log.library.error("Couldn't read a figure: \(error)")
			return nil
		}
	}

	/// Stores `data` as the picture for `assetID`, replacing any earlier one.
	func save(_ data: Data, for assetID: String, scanID: UUID) throws {
		guard let url = fileURL(for: assetID, scanID: scanID), !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
		try prepareDirectory()
		try FileManager.default.createDirectory(at: folder(for: scanID), withIntermediateDirectories: true)
		try data.write(to: url, options: .atomic)
	}

	/// The picture for `source`: the stored one, else one cut now (FigureCrop) and stored. The
	/// original is decoded only when a cut needs it.
	func imageData(for source: FigureSource, scanID: UUID, originals: OriginalStore) -> Data? {
		imageData(for: source, scanID: scanID) { source.original(in: originals) }
	}

	/// The picture for `source`, as above, with `original` giving its page's original (called only
	/// when a cut needs it, so a caller cutting several figures of one page can decode it once).
	func imageData(for source: FigureSource, scanID: UUID, original: () -> CGImage?) -> Data? {
		if let stored = data(for: source.assetID, scanID: scanID) { return stored }
		let photo = source.recipe == nil ? nil : original()
		guard let made = FigureCrop.jpeg(pageData: source.pageData, box: source.box, recipe: source.recipe, original: photo) else {
			return nil
		}
		do {
			try save(made, for: source.assetID, scanID: scanID)
		} catch {
			Log.library.error("Couldn't store a figure: \(error)")
		}
		return made
	}

	/// Deletes every picture of the scan.
	func removeAll(for scanID: UUID) {
		let url = folder(for: scanID)
		guard FileManager.default.fileExists(atPath: url.path) else { return }
		do {
			try FileManager.default.removeItem(at: url)
		} catch {
			Log.library.error("Couldn't remove a scan's figures: \(error)")
		}
	}

	/// Deletes the scan's pictures whose asset ids aren't in `assetIDs`. Returns how many went.
	@discardableResult
	func prune(scanID: UUID, keeping assetIDs: Set<String>) -> Int {
		guard !assetIDs.isEmpty else {
			let count = files(in: folder(for: scanID)).count
			removeAll(for: scanID)
			return count
		}
		let keep = Set(assetIDs.compactMap { fileURL(for: $0, scanID: scanID)?.lastPathComponent })
		var removed = 0
		for url in files(in: folder(for: scanID)) where !keep.contains(url.lastPathComponent) {
			do {
				try FileManager.default.removeItem(at: url)
				removed += 1
			} catch {
				Log.library.error("Couldn't remove a figure: \(error)")
			}
		}
		return removed
	}

	/// Deletes the folders of scans whose ids aren't in `scanIDs`. Returns how many went. (Every
	/// picture can be cut again, so a library briefly empty after an iCloud change loses nothing.)
	@discardableResult
	func pruneOrphans(keeping scanIDs: Set<UUID>) -> Int {
		var removed = 0
		for url in files(in: directory) {
			guard let id = UUID(uuidString: url.lastPathComponent), !scanIDs.contains(id) else { continue }
			removeAll(for: id)
			removed += 1
		}
		return removed
	}

	/// The entries of `folder`; empty when it doesn't exist.
	private func files(in folder: URL) -> [URL] {
		guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
		do {
			return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
		} catch {
			Log.library.error("Couldn't list figures: \(error)")
			return []
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
}

/// What it takes to cut one figure's picture, copied off Core Data.
struct FigureSource: Sendable {
	let assetID: String
	/// The figure's box on its page (page-normalized, top-left origin).
	let box: NormalizedBox
	/// The stored page image.
	let pageData: Data
	/// How the page was made from its original; nil for pages made without one.
	let recipe: PageRecipe?
	let captureID: UUID?

	/// The page's original on this iPhone, decoded; nil for a page made without a recipe.
	func original(in originals: OriginalStore) -> CGImage? {
		guard recipe != nil else { return nil }
		return captureID.flatMap { originals.loadImage(for: $0) }
	}
}

// MARK: - The document's figures

extension RescrivaDocument {
	/// Asset ids of the figures on pages that aren't waiting to be rebuilt: the pictures worth
	/// keeping. A stale page's boxes don't match its new pixels.
	var liveFigureAssetIDs: Set<String> {
		let stale = Set(staleCaptureIDs ?? [])
		var result = Set<String>()
		for (index, page) in pages.enumerated() where !(sourceCaptureIDs?[safe: index].map(stale.contains) ?? false) {
			for block in page.blocks {
				guard case .figure(let assetID?, _, _) = block.content else { continue }
				result.insert(assetID)
			}
		}
		return result
	}
}

/// Figure pictures for a scan's rebuilt document: for export, for display, and their cleanup.
@MainActor
enum FigureAssets {
	/// Every figure picture of `document` this iPhone has or can cut, keyed by asset id, for
	/// `RenderOptions.assets`. Figures on a page waiting to be rebuilt are left out (the renderers
	/// show a placeholder).
	static func assets(for document: RescrivaDocument, of scan: Scan, store: FigureStore = .shared,
					   originals: OriginalStore = .shared) async -> [String: Data] {
		guard let scanID = scan.id else { return [:] }
		let wanted = sources(in: document, of: scan)
		guard !wanted.isEmpty else { return [:] }
		return await Task.detached(priority: .userInitiated) { () -> [String: Data] in
			var assets: [String: Data] = [:]
			// A page at a time: its original (about 50 MB decoded) is decoded once at most, for all
			// its figures, and let go before the next page's.
			for page in byPage(wanted) {
				autoreleasepool {
					var decoded: CGImage??
					for source in page where assets[source.assetID] == nil {
						assets[source.assetID] = store.imageData(for: source, scanID: scanID) {
							if let decoded { return decoded }
							let loaded = source.original(in: originals)
							decoded = .some(loaded)
							return loaded
						}
					}
				}
			}
			return assets
		}.value
	}

	/// `sources` in runs from one page each, in order (`sources(in:of:)` lists them page by page).
	nonisolated static func byPage(_ sources: [FigureSource]) -> [[FigureSource]] {
		var pages: [[FigureSource]] = []
		for source in sources {
			if let last = pages.last?.last, let id = source.captureID, last.captureID == id {
				pages[pages.count - 1].append(source)
			} else {
				pages.append([source])
			}
		}
		return pages
	}

	/// The picture for one figure of the scan's rebuilt document, for display.
	static func imageData(for assetID: String, of scan: Scan, store: FigureStore = .shared,
						  originals: OriginalStore = .shared) async -> Data? {
		guard let scanID = scan.id, let document = scan.rebuiltDocument,
			  let source = sources(in: document, of: scan).first(where: { $0.assetID == assetID }) else { return nil }
		return await Task.detached(priority: .userInitiated) {
			store.imageData(for: source, scanID: scanID, originals: originals)
		}.value
	}

	/// What each figure of `document` is cut from: its page, found by capture id (or by position in
	/// documents saved before ids were kept). Pages waiting to be rebuilt are skipped.
	static func sources(in document: RescrivaDocument, of scan: Scan) -> [FigureSource] {
		let captures = scan.capturesArray
		let live = document.liveFigureAssetIDs
		var result: [FigureSource] = []
		for (index, page) in document.pages.enumerated() {
			guard let capture = capture(forPage: index, of: document, in: captures), let data = capture.imageData else { continue }
			for block in page.blocks {
				guard case .figure(let assetID?, _, _) = block.content, live.contains(assetID), let box = block.box else { continue }
				result.append(FigureSource(assetID: assetID, box: box, pageData: data, recipe: capture.recipe, captureID: capture.id))
			}
		}
		return result
	}

	/// The capture page `index` of `document` was rebuilt from.
	static func capture(forPage index: Int, of document: RescrivaDocument, in captures: [ScanCapture]) -> ScanCapture? {
		guard let sourceIDs = document.sourceCaptureIDs else {
			return document.pages.count == captures.count ? captures[safe: index] : nil
		}
		guard let id = sourceIDs[safe: index] else { return nil }
		return captures.first { $0.id == id }
	}

	/// Deletes the scan's pictures that its rebuilt document no longer needs (all of them when it
	/// has none), off the main thread. What to keep is decided here, on the main actor, before the
	/// task starts, and the deletion then owes nothing to the screen that asked: pictures a rebuild
	/// or Review made stale must go even once that screen has closed. The task is returned (nil
	/// for a scan with no id) so a caller that needs to can wait for it or cancel it.
	@discardableResult
	static func prune(_ scan: Scan, store: FigureStore = .shared) -> Task<Void, Never>? {
		guard let scanID = scan.id else { return nil }
		let keep: Set<String> = scan.isDeleted ? [] : (scan.rebuiltDocument?.liveFigureAssetIDs ?? [])
		return Task.detached(priority: .utility) {
			store.prune(scanID: scanID, keeping: keep)
		}
	}

	/// Removes the picture folders of scans no longer in the library: deleted on another device
	/// (CloudKit deletions don't run this app's delete paths). Skipped when the library is the
	/// temporary in-memory fallback, which would make every folder look orphaned.
	static func pruneOrphans(in context: NSManagedObjectContext, store: FigureStore = .shared) async {
		guard context.isLibraryOnDisk else { return }
		let request = NSFetchRequest<NSDictionary>(entityName: "Scan")
		request.resultType = .dictionaryResultType
		request.propertiesToFetch = ["id"]
		let ids: Set<UUID>
		do {
			ids = Set(try context.fetch(request).compactMap { $0["id"] as? UUID })
		} catch {
			Log.library.error("Couldn't list scans for figure cleanup: \(error)")
			return
		}
		let removed = await Task.detached(priority: .utility) {
			store.pruneOrphans(keeping: ids)
		}.value
		if removed > 0 {
			Log.library.notice("Removed the figures of \(removed) deleted scans")
		}
	}
}

/// Loads a scan's figure pictures for `RebuiltDocumentView` (see the `figureImages` environment
/// value); without one, figures show a placeholder.
struct FigureImageSource {
	let load: @MainActor (String) async -> UIImage?

	@MainActor
	init(scan: Scan, store: FigureStore = .shared) {
		load = { assetID in
			guard let data = await FigureAssets.imageData(for: assetID, of: scan, store: store) else { return nil }
			return UIImage(data: data)
		}
	}
}
