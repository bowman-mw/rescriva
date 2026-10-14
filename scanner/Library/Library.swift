//
//  Library.swift
//  Rescriva (fork of Open Scanner)
//
//  The library's edits, the Apple Notes way: folders that nest (with a
//  colour and a symbol), tags that cut across folders, smart folders that
//  fill themselves from a rule, pinned scans, and Recently Deleted, where a
//  deleted scan waits 30 days before it's purged. Every change saves the
//  context. Walks over folders are iterative and bounded.
//

import CoreData
import Foundation

/// One folder in the home screen's tree, with its depth for indenting.
struct FolderRow: Identifiable {
	let folder: ScanFolder
	let depth: Int
	let hasChildren: Bool

	var id: NSManagedObjectID { folder.objectID }
}

/// Library edits and queries. Main-actor: they run on the view context.
@MainActor
enum Library {
	/// Deepest a folder can sit (a top-level folder is depth 0).
	static let maxFolderDepth = 5
	/// Days a scan waits in Recently Deleted.
	static let recentlyDeletedDays = 30
	/// Bounds every fetch and walk over folders, tags and smart folders.
	static let maxItems = 1000
	/// Longest folder, tag or smart folder name.
	static let maxNameLength = 60

	// MARK: Lookup

	static func folder(_ id: UUID, in context: NSManagedObjectContext) -> ScanFolder? {
		first(ScanFolder.fetchRequest(), id: id, in: context)
	}

	static func tag(_ id: UUID, in context: NSManagedObjectContext) -> ScanTag? {
		first(ScanTag.fetchRequest(), id: id, in: context)
	}

	static func smartFolder(_ id: UUID, in context: NSManagedObjectContext) -> SmartFolder? {
		first(SmartFolder.fetchRequest(), id: id, in: context)
	}

	private static func first<Entity: NSManagedObject>(_ request: NSFetchRequest<Entity>, id: UUID, in context: NSManagedObjectContext) -> Entity? {
		request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
		request.fetchLimit = 1
		return fetch(request, in: context).first
	}

	static func allFolders(in context: NSManagedObjectContext) -> [ScanFolder] {
		fetch(byName(ScanFolder.fetchRequest()), in: context)
	}

	static func allTags(in context: NSManagedObjectContext) -> [ScanTag] {
		fetch(byName(ScanTag.fetchRequest()), in: context)
	}

	static func allSmartFolders(in context: NSManagedObjectContext) -> [SmartFolder] {
		fetch(byName(SmartFolder.fetchRequest()), in: context)
	}

	private static func byName<Entity: NSManagedObject>(_ request: NSFetchRequest<Entity>) -> NSFetchRequest<Entity> {
		request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))]
		request.fetchLimit = maxItems
		return request
	}

	private static func fetch<Entity: NSManagedObject>(_ request: NSFetchRequest<Entity>, in context: NSManagedObjectContext) -> [Entity] {
		do {
			return try context.fetch(request)
		} catch {
			Log.library.error("Library fetch failed: \(error)")
			return []
		}
	}

	// MARK: Scans in a scope

	static func predicate(for scope: LibraryScope, in context: NSManagedObjectContext, now: Date = Date()) -> NSPredicate {
		guard case .smart(let id) = scope else { return scope.basePredicate() }
		let rule = SmartRule.decoded(smartFolder(id, in: context)?.ruleData)
		return NSCompoundPredicate(andPredicateWithSubpredicates: [LibraryScope.livePredicate, rule.predicate(now: now)])
	}

	static func scans(for scope: LibraryScope, in context: NSManagedObjectContext, now: Date = Date()) -> [Scan] {
		let request = Scan.fetchRequest()
		request.predicate = predicate(for: scope, in: context, now: now)
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Scan.timestamp, ascending: false)]
		return fetch(request, in: context)
	}

	static func count(for scope: LibraryScope, in context: NSManagedObjectContext, now: Date = Date()) -> Int {
		let request = Scan.fetchRequest()
		request.predicate = predicate(for: scope, in: context, now: now)
		do {
			return try context.count(for: request)
		} catch {
			Log.library.error("Library count failed: \(error)")
			return 0
		}
	}

	// MARK: Folders

	/// The folder tree, depth first, siblings by name; children of a folder in `collapsed` are left out.
	static func tree(in context: NSManagedObjectContext, collapsed: Set<UUID> = []) -> [FolderRow] {
		let folders = allFolders(in: context)
		let children = Dictionary(grouping: folders) { $0.parent?.objectID }
		var rows: [FolderRow] = []
		var stack: [(folder: ScanFolder, depth: Int)] = (children[nil] ?? []).reversed().map { ($0, 0) }
		for _ in 0..<maxItems {
			guard let next = stack.popLast() else { break }
			let kids = children[next.folder.objectID] ?? []
			rows.append(FolderRow(folder: next.folder, depth: next.depth, hasChildren: !kids.isEmpty))
			if let id = next.folder.id, collapsed.contains(id) { continue }
			if next.depth < maxFolderDepth { stack += kids.reversed().map { ($0, next.depth + 1) } }
		}
		return rows
	}

	/// How deep `folder` sits: 0 at the top level.
	static func depth(of folder: ScanFolder) -> Int {
		var depth = 0
		var current = folder.parent
		for _ in 0..<maxItems {
			guard let parent = current else { break }
			depth += 1
			current = parent.parent
		}
		return depth
	}

	/// Every folder inside `folder`, at any depth.
	static func descendants(of folder: ScanFolder) -> [ScanFolder] {
		var result: [ScanFolder] = []
		var level = folder.childFolders
		for _ in 0...maxFolderDepth {
			guard !level.isEmpty, result.count < maxItems else { break }
			result += level
			level = level.flatMap(\.childFolders)
		}
		return result
	}

	/// How many levels of folders `folder` holds below itself.
	static func height(of folder: ScanFolder) -> Int {
		var height = 0
		var level = folder.childFolders
		for _ in 0...maxFolderDepth {
			guard !level.isEmpty else { break }
			height += 1
			level = level.flatMap(\.childFolders)
		}
		return height
	}

	/// Whether `folder` may move into `parent` (nil: the top level) without a loop or going too deep.
	static func canMove(_ folder: ScanFolder, into parent: ScanFolder?) -> Bool {
		guard let parent else { return true }
		guard parent != folder, !descendants(of: folder).contains(parent) else { return false }
		return depth(of: parent) + 1 + height(of: folder) <= maxFolderDepth
	}

	/// A trimmed, bounded name, or `fallback` when there's nothing left.
	static func cleanName(_ name: String, fallback: String) -> String {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? fallback : String(trimmed.prefix(maxNameLength))
	}

	@discardableResult
	static func createFolder(named name: String, symbol: String, color: FolderColor, parent: ScanFolder?,
							 in context: NSManagedObjectContext) -> ScanFolder {
		let folder = ScanFolder(context: context)
		folder.id = UUID()
		folder.created = Date()
		folder.name = cleanName(name, fallback: String(localized: "New Folder"))
		folder.symbol = FolderSymbol.valid(symbol)
		folder.colorToken = color.rawValue
		if let parent, depth(of: parent) < maxFolderDepth { folder.parent = parent }
		context.saveQuietly()
		return folder
	}

	static func update(_ folder: ScanFolder, name: String, symbol: String, color: FolderColor, in context: NSManagedObjectContext) {
		folder.name = cleanName(name, fallback: folder.displayName)
		folder.symbol = FolderSymbol.valid(symbol)
		folder.colorToken = color.rawValue
		context.saveQuietly()
	}

	/// Moves a folder (with everything in it) under `parent`; refuses a move that would loop or go too deep.
	@discardableResult
	static func move(_ folder: ScanFolder, into parent: ScanFolder?, in context: NSManagedObjectContext) -> Bool {
		guard canMove(folder, into: parent) else { return false }
		folder.parent = parent
		context.saveQuietly()
		return true
	}

	/// Deletes a folder and the folders inside it; their scans go to Recently Deleted.
	static func delete(_ folder: ScanFolder, in context: NSManagedObjectContext, now: Date = Date()) {
		let doomed = [folder] + descendants(of: folder)
		for scan in doomed.flatMap(\.scanList) where scan.deletedAt == nil {
			scan.deletedAt = now
			scan.pinned = false
		}
		for item in doomed.reversed() { context.delete(item) }
		context.saveQuietly()
	}

	// MARK: Tags

	/// A tag name as stored: no leading "#", inner spaces as hyphens, bounded; nil when empty.
	static func tagName(_ raw: String) -> String? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
		let joined = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: "-")
		return joined.isEmpty ? nil : String(joined.prefix(maxNameLength))
	}

	/// The tag called `raw` (any case), creating it when asked.
	static func tag(named raw: String, creating: Bool, in context: NSManagedObjectContext) -> ScanTag? {
		guard let name = tagName(raw) else { return nil }
		let request = ScanTag.fetchRequest()
		request.predicate = NSPredicate(format: "name ==[c] %@", name)
		request.fetchLimit = 1
		if let existing = fetch(request, in: context).first { return existing }
		guard creating else { return nil }
		let tag = ScanTag(context: context)
		tag.id = UUID()
		tag.created = Date()
		tag.name = name
		context.saveQuietly()
		return tag
	}

	static func setTag(_ tag: ScanTag, on scans: [Scan], to isOn: Bool, in context: NSManagedObjectContext) {
		for scan in scans {
			if isOn { scan.addToTags(tag) } else { scan.removeFromTags(tag) }
		}
		context.saveQuietly()
	}

	static func rename(_ tag: ScanTag, to raw: String, in context: NSManagedObjectContext) {
		guard let name = tagName(raw) else { return }
		tag.name = name
		context.saveQuietly()
	}

	static func delete(_ tag: ScanTag, in context: NSManagedObjectContext) {
		context.delete(tag)
		context.saveQuietly()
	}

	// MARK: Scans

	static func move(_ scans: [Scan], to folder: ScanFolder?, in context: NSManagedObjectContext) {
		for scan in scans { scan.folder = folder }
		context.saveQuietly()
	}

	static func setPinned(_ scans: [Scan], to pinned: Bool, in context: NSManagedObjectContext) {
		for scan in scans { scan.pinned = pinned }
		context.saveQuietly()
	}

	static func setFavorite(_ scans: [Scan], to fave: Bool, in context: NSManagedObjectContext) {
		for scan in scans { scan.fave = fave }
		context.saveQuietly()
	}

	/// Moves scans to Recently Deleted (they keep their folder and tags until purged).
	static func moveToRecentlyDeleted(_ scans: [Scan], in context: NSManagedObjectContext, now: Date = Date()) {
		for scan in scans {
			scan.deletedAt = now
			scan.pinned = false
		}
		context.saveQuietly()
	}

	/// Brings scans back from Recently Deleted; one whose folder has gone returns to the top level.
	static func recover(_ scans: [Scan], in context: NSManagedObjectContext) {
		for scan in scans { scan.deletedAt = nil }
		context.saveQuietly()
	}

	/// Deletes scans for good, with their pages, recognized lines, page
	/// originals, Annotate marks and figure pictures (`Scan.deleteWithPages`),
	/// and any original PDF kept on this iPhone. The only way a scan leaves the
	/// library for good: until then (Recently Deleted too) it keeps every file.
	/// The files go only once the deletion is saved; a failed save undoes it.
	static func purge(_ scans: [Scan], in context: NSManagedObjectContext, originals: OriginalStore = .shared,
					  figures: FigureStore = .shared, annotations: AnnotationStore? = nil) {
		var files = DeletedFiles()
		for scan in scans {
			if let id = scan.id {
				files.add { PDFImport.removeOriginal(for: id) }
			}
			files.add(scan.deleteWithPages(originals: originals, figures: figures, annotations: annotations))
		}
		context.saveDeletion(removing: files)
	}

	/// Purges scans that have waited out their days in Recently Deleted; returns how many went.
	@discardableResult
	static func purgeExpired(in context: NSManagedObjectContext, now: Date = Date()) -> Int {
		let cutoff = now.addingTimeInterval(-Double(recentlyDeletedDays) * 86_400)
		let request = Scan.fetchRequest()
		request.predicate = NSPredicate(format: "deletedAt != nil AND deletedAt < %@", cutoff as NSDate)
		request.fetchLimit = maxItems
		let expired = fetch(request, in: context)
		if !expired.isEmpty { purge(expired, in: context) }
		return expired.count
	}

	/// Whole days left before a deleted scan is purged.
	static func daysLeft(for scan: Scan, now: Date = Date()) -> Int {
		guard let deletedAt = scan.deletedAt else { return recentlyDeletedDays }
		let elapsed = now.timeIntervalSince(deletedAt) / 86_400
		return max(0, recentlyDeletedDays - Int(elapsed.rounded(.down)))
	}

	// MARK: Smart folders

	@discardableResult
	static func createSmartFolder(named name: String, symbol: String, color: FolderColor, rule: SmartRule,
								  in context: NSManagedObjectContext) -> SmartFolder {
		let smart = SmartFolder(context: context)
		smart.id = UUID()
		smart.created = Date()
		update(smart, name: name, symbol: symbol, color: color, rule: rule, in: context)
		return smart
	}

	static func update(_ smart: SmartFolder, name: String, symbol: String, color: FolderColor, rule: SmartRule,
					   in context: NSManagedObjectContext) {
		smart.name = cleanName(name, fallback: String(localized: "Smart Folder"))
		smart.symbol = FolderSymbol.valid(symbol, fallback: FolderSymbol.smartDefault)
		smart.colorToken = color.rawValue
		smart.ruleData = rule.json
		context.saveQuietly()
	}

	static func delete(_ smart: SmartFolder, in context: NSManagedObjectContext) {
		context.delete(smart)
		context.saveQuietly()
	}
}

/// The folder new scans join: the one the library is showing, if any.
/// ContentView keeps `folderID` in step with the route stack.
@MainActor
final class LibraryPlacement {
	static let shared = LibraryPlacement()
	var folderID: UUID?

	/// Files a new scan in the current folder.
	func place(_ scan: Scan, in context: NSManagedObjectContext) {
		guard let folderID, let folder = Library.folder(folderID, in: context) else { return }
		scan.folder = folder
	}
}
