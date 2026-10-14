//
//  Persistence.swift
//  Open Scanner → Rescriva
//
//  Created by Slaven Radic on 2024-09-01.
//  Rescriva: the library's Core Data stack, and what Spotlight sees of it (one item per live scan:
//  `SpotlightIndexer`). Spotlight results name objects by URI; `objectID(forSpotlightIdentifier:)`
//  and `liveScan(for:in:)` turn one back into a scan without ever faulting a missing row.
//

import CoreData
import CoreSpotlight
import UniformTypeIdentifiers

struct PersistenceController {
	static let shared = PersistenceController()
	
	/// Indexes the library for Spotlight; nil on a temporary store, which has nothing worth finding.
	private(set) var spotlightIndexer: SpotlightIndexer?
	/// The index version this build makes (bumped when what's indexed changes), and where the
	/// version last built on this device is kept. An older index is cleared and built again once.
	static let spotlightIndexVersion = 2
	static let spotlightIndexVersionKey = "spotlightIndexVersion"
	
	let container: NSPersistentCloudKitContainer
	/// Why the library on this device couldn't be opened, when the app is running on a temporary
	/// in-memory one instead (nothing made now is kept). The app warns about it (ContentView).
	private(set) var loadFailure: Error?
	
	init(inMemory: Bool = false) {
		container = NSPersistentCloudKitContainer(name: "scanner")
		
		guard let description = container.persistentStoreDescriptions.first else {
			// NSPersistentContainer always creates a default description; without one there is nothing to load.
			Log.library.error("No persistent store description")
			return
		}
		
		description.type = NSSQLiteStoreType
		description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
		description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
		// New model versions (scanner.xcdatamodeld) only add optional attributes, relationships
		// and entities, so the existing store upgrades in place with an inferred mapping: version 4
		// is the library (3) plus the page recipe (2), and stores on 1, 2 or 3 all reach it.
		description.shouldMigrateStoreAutomatically = true
		description.shouldInferMappingModelAutomatically = true
		
		if inMemory {
			// Preview and in memory experiments
			description.url = URL(fileURLWithPath: "/dev/null")
			description.cloudKitContainerOptions = nil
		}
		
		loadFailure = Self.loadFallingBackToMemory(container)
		
		// A preview store or the in-memory fallback is never indexed: its scans are gone with the
		// process, and they'd land in the device's index beside the real library's.
		if !inMemory, loadFailure == nil {
			let indexer = SpotlightIndexer(forStoreWith: description, coordinator: container.persistentStoreCoordinator)
			spotlightIndexer = indexer
			Self.startSpotlightIndexing(indexer)
		}
		
		if !inMemory {
			// Permanent store options
			container.viewContext.automaticallyMergesChangesFromParent = true
			container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
		}
	}
	
	/// Loads the container's store. If it can't be opened, the app runs on a temporary in-memory
	/// store instead of crashing, and this returns why. The file on disk is left as it was.
	static func loadFallingBackToMemory(_ container: NSPersistentContainer) -> Error? {
		guard let error = loadStores(of: container) else { return nil }
		Log.library.error("The library store failed to load (\(error)); using a temporary in-memory store")
		guard let description = container.persistentStoreDescriptions.first else { return error }
		description.url = URL(fileURLWithPath: "/dev/null")
		description.cloudKitContainerOptions = nil
		if let second = loadStores(of: container) {
			Log.library.error("The in-memory store failed too: \(second)")
		}
		return error
	}

	/// Loads the container's stores and returns the first error. The descriptions load
	/// synchronously (their default), so the callback has run, on this thread, before this returns.
	private static func loadStores(of container: NSPersistentContainer) -> Error? {
		var firstError: Error?
		container.loadPersistentStores { _, error in
			if let error, firstError == nil {
				firstError = error
			}
		}
		return firstError
	}

	// MARK: Spotlight

	/// Starts indexing. The first time this version of the index runs on a device, the old index
	/// (one item per recognized line, Recently Deleted scans included) is cleared and the scans
	/// are indexed afresh. The version is recorded only once the reindex has been acknowledged,
	/// and only when the clear succeeded: recorded any earlier, an app killed mid-rebuild (or a
	/// clear that failed) would leave the old entries gone and every older scan out of Spotlight
	/// until it was next changed. Clearing and reindexing again on the next launch is harmless.
	private static func startSpotlightIndexing(_ indexer: SpotlightIndexer) {
		guard UserDefaults.standard.integer(forKey: spotlightIndexVersionKey) < spotlightIndexVersion else {
			indexer.startSpotlightIndexing()
			return
		}
		indexer.deleteSpotlightIndex { error in
			if let error {
				Log.library.error("Couldn't clear the old Spotlight index: \(error)")
			}
			indexer.startSpotlightIndexing()
			indexer.searchableIndex(CSSearchableIndex.default(), reindexAllSearchableItemsWithAcknowledgementHandler: {
				guard error == nil else {
					Log.library.notice("Spotlight reindexed, but the old index wasn't cleared; both run again next launch")
					return
				}
				UserDefaults.standard.set(spotlightIndexVersion, forKey: spotlightIndexVersionKey)
				Log.library.notice("Spotlight index rebuilt, one item per scan")
			})
		}
	}

	/// The object a Spotlight result names (its identifier is the object's URI), without touching
	/// the store: a stale result still gives an id, and `liveScan(for:in:)` says whether it's
	/// worth anything. Nil for anything that isn't one of this store's URIs.
	static func objectID(forSpotlightIdentifier identifier: String, in context: NSManagedObjectContext) -> NSManagedObjectID? {
		// The coordinator raises an Objective-C exception for anything but an `x-coredata://store/Entity/pk` URL.
		guard let uri = URL(string: identifier), uri.scheme == "x-coredata", uri.host != nil,
			  uri.pathComponents.count == 3 else { return nil }
		return context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri)
	}

	/// The scan `objectID` stands for — a scan's own id, or that of one of its recognized lines —
	/// as long as it's still in the library and not in Recently Deleted. Never a fault for a
	/// missing row: an object purged here, or deleted on another device, gives nil.
	static func liveScan(for objectID: NSManagedObjectID, in context: NSManagedObjectContext) -> Scan? {
		let object: NSManagedObject
		do {
			object = try context.existingObject(with: objectID)
		} catch {
			Log.library.error("A Spotlight result's scan is no longer here: \(error)")
			return nil
		}
		let scan: Scan?
		if let found = object as? Scan {
			scan = found
		} else if let line = object as? ScanRecognizedItem {
			scan = line.parent?.parent
		} else {
			scan = nil
		}
		guard let scan, scan.managedObjectContext != nil, !scan.isDeleted, scan.deletedAt == nil else { return nil }
		return scan
	}
	
	static let preview: PersistenceController = {
		let result = PersistenceController(inMemory: true)
		let viewContext = result.container.viewContext
		for _ in 0..<2 {
			let newScan = Scan(context: viewContext)
			newScan.timestamp = Date()
			for _ in 0..<4 {
				let newPage = ScanCapture(context: viewContext)
				newPage.timestamp = Date()
				for index in 0..<3 {
					let newItem = ScanRecognizedItem(context: viewContext)
					newItem.timestamp = Date()
					newItem.transcript = "Transcript \(index)"
				}
			}
		}
		do {
			try viewContext.save()
		} catch {
			Log.library.error("Preview store save failed: \(error)")
		}
		return result
	}()
	
}

// MARK: - Spotlight indexer

/// Indexes one item per live scan: its title, its pages' text and its first page, under the
/// scan's object URI. Recognized lines, which Core Data's default would index one by one (about
/// 800 results for a 20-page scan), and scans in Recently Deleted get nil, which keeps them out of
/// the index and takes an entry out again when a scan is deleted. Only the model's `title` and
/// `transcript` are marked for indexing, so nothing here changes the model.
///
/// Sendable by hand, as Core Data's delegate isn't marked: it keeps no state of its own, and Core
/// Data does the indexing on the indexer's own background context. The app only starts it and,
/// from a completion handler, asks for a reindex.
final class SpotlightIndexer: NSCoreDataCoreSpotlightDelegate, @unchecked Sendable {
	/// Most text one scan puts in the index, in UTF-16 units.
	static let maxTextLength = 32_000
	/// Length of the summary shown under a result.
	static let descriptionLength = 200

	/// Called on the indexer's own background context, with that context's object.
	override func attributeSet(for object: NSManagedObject) -> CSSearchableItemAttributeSet? {
		guard let scan = object as? Scan, scan.managedObjectContext != nil, !scan.isDeleted, scan.deletedAt == nil else {
			return nil
		}
		let attributes = super.attributeSet(for: object) ?? CSSearchableItemAttributeSet(contentType: .text)
		let title = (scan.title ?? "").trimmingCharacters(in: .whitespaces)
		attributes.displayName = title.isEmpty ? String(localized: "Untitled") : title
		let text = Self.text(of: scan)
		attributes.textContent = text.isEmpty ? nil : text
		attributes.contentDescription = text.isEmpty ? nil : String(text.prefix(Self.descriptionLength))
		attributes.thumbnailData = scan.coverThumbnailData
		return attributes
	}

	/// The scan's recognized text, in page then line order, cut at `maxTextLength`. Read as plain
	/// strings: no page is faulted in, so no page image is loaded for it.
	static func text(of scan: Scan) -> String {
		guard let context = scan.managedObjectContext, !scan.objectID.isTemporaryID else { return "" }
		let request = NSFetchRequest<NSDictionary>(entityName: "ScanRecognizedItem")
		request.predicate = NSPredicate(format: "parent.parent == %@ AND transcript != nil", scan)
		request.sortDescriptors = [NSSortDescriptor(key: "parent.order", ascending: true),
								   NSSortDescriptor(key: "order", ascending: true),
								   NSSortDescriptor(key: "timestamp", ascending: true)]
		request.resultType = .dictionaryResultType
		request.propertiesToFetch = ["transcript"]
		let lines: [String]
		do {
			lines = try context.fetch(request).compactMap { $0["transcript"] as? String }
		} catch {
			Log.library.error("Couldn't read a scan's text for Spotlight: \(error)")
			return ""
		}
		var text = ""
		var length = 0
		for line in lines where !line.isEmpty {
			let next = length + line.utf16.count + 1
			guard next <= maxTextLength else { break }
			text += line + "\n"
			length = next
		}
		return text
	}
}
