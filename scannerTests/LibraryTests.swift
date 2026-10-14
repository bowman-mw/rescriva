//
//  LibraryTests.swift
//  Rescriva (fork of Open Scanner)
//
//  The library on an in-memory store: the folder tree and moves that would
//  loop, deleting a folder into Recently Deleted, tags, the scopes' counts,
//  smart folder rules and their stored JSON, purging after 30 days, the
//  gallery's date sections, and where a new scan is filed. Also the grid's cheap reads of a
//  scan's first thumbnail and page count, the data detector on a line, requests from outside
//  the screens (`AppRequests`) and the scan a Spotlight result opens, and opening the library:
//  a store that can't be opened falls back to a temporary one and says so.
//

import CoreData
import XCTest
@testable import scanner

@MainActor
final class LibraryTests: XCTestCase {

	/// Stores stay alive for the test that made them.
	private var containers: [NSPersistentContainer] = []

	/// A fresh in-memory store on the app's own model (one model instance, so
	/// entity classes resolve uniquely).
	private func makeContext() throws -> NSManagedObjectContext {
		let model = PersistenceController.shared.container.managedObjectModel
		let container = NSPersistentContainer(name: "LibraryTests", managedObjectModel: model)
		let description = NSPersistentStoreDescription()
		description.type = NSInMemoryStoreType
		container.persistentStoreDescriptions = [description]
		var loadError: Error?
		container.loadPersistentStores { _, error in loadError = error }
		if let loadError { throw loadError }
		containers.append(container)
		return container.viewContext
	}

	private func scan(_ title: String, in context: NSManagedObjectContext, output: OutputKind = .docx,
					  source: PageSource = .typed, created: Date = Date()) -> Scan {
		let scan = Scan(context: context)
		scan.id = UUID()
		scan.title = title
		scan.timestamp = created
		scan.lastUpdate = created
		scan.output = output
		scan.pageSource = source
		return scan
	}

	// MARK: Export names

	func testExportFileNamesComeFromTheOneSanitizer() throws {
		let context = try makeContext()
		XCTAssertEqual(ExportService.fileName(for: scan("Q3: plan / budget?", in: context), format: .docx), "Q3 plan budget.docx")
		XCTAssertEqual(ExportService.fileName(for: scan("../Lab notes", in: context), format: .pptx), "Lab notes.pptx")
		XCTAssertEqual(ExportService.fileName(for: scan(" ... ", in: context), format: .pdf), "Scan.pdf", "nothing safe left falls back to Scan")
		let long = ExportService.fileName(for: scan(String(repeating: "é", count: 300), in: context), format: .md)
		XCTAssertLessThanOrEqual(long.utf8.count, String.maxFileNameBytes + ".md".utf8.count)
		XCTAssertTrue(long.hasSuffix(".md"))
	}

	// MARK: Folders

	func testTheFolderTreeNestsAndCollapses() throws {
		let context = try makeContext()
		let biology = Library.createFolder(named: "Biology", symbol: "flask", color: .ink, parent: nil, in: context)
		let labs = Library.createFolder(named: "Labs", symbol: "book.closed", color: .bluePencil, parent: biology, in: context)
		Library.createFolder(named: "Week 1", symbol: "nonsense.symbol", color: .graphite, parent: labs, in: context)
		Library.createFolder(named: "Art", symbol: "paintpalette", color: .plum, parent: nil, in: context)

		let rows = Library.tree(in: context)
		XCTAssertEqual(rows.map(\.folder.displayName), ["Art", "Biology", "Labs", "Week 1"])
		XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 2])
		XCTAssertEqual(rows.map(\.hasChildren), [false, true, true, false])
		XCTAssertEqual(rows.last?.folder.symbolName, "folder", "an unknown symbol falls back to a folder")

		let collapsed = Library.tree(in: context, collapsed: [try XCTUnwrap(biology.id)])
		XCTAssertEqual(collapsed.map(\.folder.displayName), ["Art", "Biology"])
	}

	func testFoldersCantMoveIntoThemselvesOrTooDeep() throws {
		let context = try makeContext()
		let top = Library.createFolder(named: "Top", symbol: "folder", color: .ink, parent: nil, in: context)
		let child = Library.createFolder(named: "Child", symbol: "folder", color: .ink, parent: top, in: context)
		var deepest = child
		for level in 2...Library.maxFolderDepth {
			deepest = Library.createFolder(named: "Level \(level)", symbol: "folder", color: .ink, parent: deepest, in: context)
		}
		XCTAssertEqual(Library.depth(of: deepest), Library.maxFolderDepth)
		XCTAssertFalse(Library.canMove(top, into: child), "into its own child would loop")
		XCTAssertFalse(Library.canMove(top, into: top))
		let other = Library.createFolder(named: "Other", symbol: "folder", color: .ink, parent: nil, in: context)
		XCTAssertFalse(Library.canMove(top, into: other), "the whole chain would sit one level too deep")
		XCTAssertTrue(Library.move(other, into: child, in: context))
		XCTAssertEqual(other.parent, child)
		XCTAssertTrue(Library.canMove(child, into: nil))
	}

	func testDeletingAFolderSendsItsScansToRecentlyDeleted() throws {
		let context = try makeContext()
		let work = Library.createFolder(named: "Work", symbol: "briefcase", color: .graphite, parent: nil, in: context)
		let notes = Library.createFolder(named: "Notes", symbol: "folder", color: .ink, parent: work, in: context)
		let a = scan("A", in: context), b = scan("B", in: context), loose = scan("Loose", in: context)
		Library.move([a], to: work, in: context)
		Library.move([b], to: notes, in: context)
		Library.setPinned([a], to: true, in: context)

		Library.delete(work, in: context)

		XCTAssertNotNil(a.deletedAt)
		XCTAssertNotNil(b.deletedAt)
		XCTAssertNil(loose.deletedAt)
		XCTAssertFalse(a.pinned, "deleted scans aren't pinned")
		XCTAssertTrue(Library.allFolders(in: context).isEmpty)
		XCTAssertEqual(Library.count(for: .recentlyDeleted, in: context), 2)
		Library.recover([a], in: context)
		XCTAssertNil(a.folder, "a scan whose folder has gone comes back at the top level")
		XCTAssertEqual(Library.count(for: .all, in: context), 2)
	}

	// MARK: Tags and scopes

	func testTagsAreTidiedAndMatchedWhateverTheirCase() throws {
		let context = try makeContext()
		XCTAssertEqual(Library.tagName("  #Lab Report  "), "Lab-Report")
		XCTAssertNil(Library.tagName("  # "))
		let tag = try XCTUnwrap(Library.tag(named: "#Exam", creating: true, in: context))
		XCTAssertEqual(Library.tag(named: "exam", creating: true, in: context), tag, "no duplicate for a different case")
		XCTAssertNil(Library.tag(named: "todo", creating: false, in: context))
		XCTAssertEqual(tag.displayName, "#Exam")

		let a = scan("A", in: context), b = scan("B", in: context)
		Library.setTag(tag, on: [a, b], to: true, in: context)
		XCTAssertEqual(Library.count(for: .tag(try XCTUnwrap(tag.id)), in: context), 2)
		Library.setTag(tag, on: [b], to: false, in: context)
		XCTAssertEqual(Library.scans(for: .tag(try XCTUnwrap(tag.id)), in: context), [a])
	}

	func testEachScopeCountsItsScans() throws {
		let context = try makeContext()
		let folder = Library.createFolder(named: "F", symbol: "folder", color: .ink, parent: nil, in: context)
		let a = scan("A", in: context), b = scan("B", in: context), c = scan("C", in: context)
		Library.setPinned([a], to: true, in: context)
		Library.setFavorite([a, b], to: true, in: context)
		Library.move([b, c], to: folder, in: context)
		Library.moveToRecentlyDeleted([c], in: context)

		XCTAssertEqual(Library.count(for: .all, in: context), 2)
		XCTAssertEqual(Library.count(for: .pinned, in: context), 1)
		XCTAssertEqual(Library.count(for: .favorites, in: context), 2)
		XCTAssertEqual(Library.count(for: .folder(try XCTUnwrap(folder.id)), in: context), 1, "deleted scans leave their folder's count")
		XCTAssertEqual(Library.scans(for: .recentlyDeleted, in: context), [c])
	}

	// MARK: Smart folders

	func testSmartRulesMatchAllOrAny() throws {
		let context = try makeContext()
		let now = Date()
		let exam = try XCTUnwrap(Library.tag(named: "exam", creating: true, in: context))
		let wordFromBoard = scan("Board", in: context, output: .docx, source: .whiteboard, created: now)
		let oldPDF = scan("Old", in: context, output: .pdf, source: .typed, created: now.addingTimeInterval(-40 * 86_400))
		let slides = scan("Deck", in: context, output: .pptx, source: .typed, created: now)
		Library.setTag(exam, on: [oldPDF], to: true, in: context)

		func matches(_ rule: SmartRule) throws -> Set<String> {
			let smart = Library.createSmartFolder(named: "S", symbol: "gearshape", color: .ink, rule: rule, in: context)
			return Set(Library.scans(for: .smart(try XCTUnwrap(smart.id)), in: context, now: now).compactMap(\.title))
		}
		XCTAssertEqual(try matches(SmartRule(outputs: ["docx", "pptx"])), ["Board", "Deck"])
		XCTAssertEqual(try matches(SmartRule(match: .all, outputs: ["docx"], sources: ["typed"])), [])
		XCTAssertEqual(try matches(SmartRule(match: .any, outputs: ["docx"], sources: ["typed"])), ["Board", "Old", "Deck"])
		XCTAssertEqual(try matches(SmartRule(tagIDs: [try XCTUnwrap(exam.id)])), ["Old"])
		XCTAssertEqual(try matches(SmartRule(withinDays: 30)), ["Board", "Deck"])
		XCTAssertEqual(try matches(SmartRule()), ["Board", "Old", "Deck"], "an empty rule matches everything")
		Library.moveToRecentlyDeleted([wordFromBoard, slides], in: context)
		XCTAssertEqual(try matches(SmartRule(outputs: ["docx", "pptx"])), [], "deleted scans never match")
	}

	func testSmartRulesSurviveTheirStoredJSON() {
		let rule = SmartRule(match: .any, tagIDs: [UUID()], outputs: ["docx"], sources: ["whiteboard"], favoritesOnly: true, withinDays: 7)
		XCTAssertEqual(SmartRule.decoded(rule.json), rule)
		let future = #"{"match":"any","outputs":["pdf"],"someNewKey":[1,2]}"#
		XCTAssertEqual(SmartRule.decoded(future), SmartRule(match: .any, outputs: ["pdf"]), "unknown keys are ignored")
		XCTAssertEqual(SmartRule.decoded("not json"), SmartRule())
		XCTAssertTrue(SmartRule.decoded(nil).isEmpty)
	}

	// MARK: Recently Deleted

	func testPurgingTakesOnlyScansPastThirtyDaysWithTheirPages() throws {
		let context = try makeContext()
		let now = Date()
		let expired = scan("Expired", in: context), recent = scan("Recent", in: context)
		let page = ScanCapture(context: context)
		page.id = UUID()
		let line = ScanRecognizedItem(context: context)
		line.transcript = "hello"
		page.addToRecognizedItems(line)
		expired.addToCaptures(page)
		Library.moveToRecentlyDeleted([expired], in: context, now: now.addingTimeInterval(-31 * 86_400))
		Library.moveToRecentlyDeleted([recent], in: context, now: now.addingTimeInterval(-29.5 * 86_400))

		XCTAssertEqual(Library.daysLeft(for: recent, now: now), 1)
		XCTAssertEqual(Library.daysLeft(for: expired, now: now), 0)
		XCTAssertEqual(Library.purgeExpired(in: context, now: now), 1)

		XCTAssertEqual(Library.scans(for: .recentlyDeleted, in: context), [recent])
		XCTAssertEqual(try context.count(for: ScanCapture.fetchRequest()), 0, "the purged scan's pages go too")
		XCTAssertEqual(try context.count(for: ScanRecognizedItem.fetchRequest()), 0)
	}

	// MARK: Gallery sections and placement

	func testGallerySectionsPutPinnedFirstThenDates() throws {
		let context = try makeContext()
		let calendar = Calendar(identifier: .gregorian)
		let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15)))
		let today = scan("Today", in: context, created: now.addingTimeInterval(-3_600))
		let yesterday = scan("Yesterday", in: context, created: now.addingTimeInterval(-86_400))
		let week = scan("Week", in: context, created: now.addingTimeInterval(-4 * 86_400))
		let old = scan("Old", in: context, created: now.addingTimeInterval(-200 * 86_400))
		let pinned = scan("Pinned", in: context, created: now.addingTimeInterval(-50 * 86_400))
		pinned.pinned = true

		let sections = LibraryGrouping.sections([old, week, pinned, today, yesterday], sort: .created, pinnedFirst: true, now: now, calendar: calendar)
		XCTAssertEqual(sections.map(\.title), ["Pinned", "Today", "Yesterday", "Previous 7 Days", "March"])
		XCTAssertEqual(sections.first?.scans, [pinned])
		XCTAssertEqual(LibraryGrouping.bucket(for: now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar).suffix(4), "2025")

		let byTitle = LibraryGrouping.sections([week, old, today], sort: .title, pinnedFirst: true, now: now, calendar: calendar)
		XCTAssertEqual(byTitle.count, 1)
		XCTAssertEqual(byTitle.first?.scans.compactMap(\.title), ["Old", "Today", "Week"])
		_ = yesterday
	}

	func testNewScansAreFiledInTheFolderOnScreen() throws {
		let context = try makeContext()
		let folder = Library.createFolder(named: "Inbox", symbol: "tray", color: .ink, parent: nil, in: context)
		let router = RescrivaRouter()
		router.push(.settings)
		XCTAssertNil(router.placementFolderID)
		router.push(.collection(.folder(try XCTUnwrap(folder.id))))
		router.push(.settings)
		XCTAssertEqual(router.placementFolderID, folder.id, "the topmost folder screen under the camera or anything else")

		let placement = LibraryPlacement()
		placement.folderID = folder.id
		let new = scan("New", in: context)
		placement.place(new, in: context)
		XCTAssertEqual(new.folder, folder)
		router.popToRoot()
		XCTAssertNil(router.placementFolderID)
	}

	// MARK: Wide screens

	func testEachWindowGetsTheLibraryLayoutItsDesignShows() {
		XCTAssertEqual(WorkspaceLayout(CGSize(width: 1194, height: 834)), .columns, "iPad in landscape")
		XCTAssertEqual(WorkspaceLayout(CGSize(width: 1133, height: 744)), .columns, "iPad mini in landscape")
		XCTAssertEqual(WorkspaceLayout(CGSize(width: 834, height: 1194)), .portrait, "iPad in portrait")
		XCTAssertEqual(WorkspaceLayout(CGSize(width: 744, height: 1133)), .portrait, "iPad mini in portrait")
		XCTAssertEqual(WorkspaceLayout(CGSize(width: 860, height: 740)), .halves, "the unfolded Duo")
		XCTAssertNil(WorkspaceLayout(CGSize(width: 402, height: 874)), "a phone keeps its Library")
		XCTAssertNil(WorkspaceLayout(CGSize(width: 507, height: 1133)), "an iPad split in thirds keeps the phone's Library")
	}

	func testOnlyTheCameraPDFsAndComparisonsFillAWideScreen() {
		XCTAssertTrue(ContentView.fillsWideScreen(.pdf(UUID(), query: nil)))
		XCTAssertTrue(ContentView.fillsWideScreen(.pdfCompare(.pdf(UUID()), .pdf(UUID(), original: true))))
		XCTAssertTrue(ContentView.fillsWideScreen(.camera(.document, appendingTo: nil)))
		XCTAssertFalse(ContentView.fillsWideScreen(.settings))
		XCTAssertFalse(ContentView.fillsWideScreen(.pdfFiles))
	}

	// MARK: The grid's reads

	/// A page with `order`, a thumbnail and (standing in for the page image) some bytes to fault in.
	private func page(order: Int32, thumbnail: String?, in context: NSManagedObjectContext) -> ScanCapture {
		let page = ScanCapture(context: context)
		page.id = UUID()
		page.timestamp = Date()
		page.order = order
		page.thumbnailData = thumbnail.map { Data($0.utf8) }
		page.imageData = Data("a whole page image".utf8)
		return page
	}

	func testTheGridReadsTheFirstThumbnailWithoutFaultingPagesIn() throws {
		let context = try makeContext()
		let scan = scan("Pages", in: context)
		XCTAssertNil(scan.coverThumbnailData, "nothing to show yet")
		XCTAssertEqual(scan.pageCount, 0)

		let second = page(order: 1, thumbnail: "second", in: context)
		let first = page(order: 0, thumbnail: "first", in: context)
		let third = page(order: 2, thumbnail: "third", in: context)
		scan.addToCaptures(second)
		scan.addToCaptures(first)
		scan.addToCaptures(third)
		XCTAssertEqual(scan.coverThumbnailData, Data("first".utf8), "before a save, read from the pages themselves")
		try context.save()

		for page in [first, second, third] { context.refresh(page, mergeChanges: false) }
		XCTAssertEqual(scan.coverThumbnailData, Data("first".utf8), "the first page by order, as capturesArray sorts")
		XCTAssertEqual(scan.pageCount, 3)
		XCTAssertTrue(first.isFault && second.isFault && third.isFault, "neither read pulled a page's row (and its image) in")

		first.thumbnailData = nil
		try context.save()
		XCTAssertEqual(scan.coverThumbnailData, Data("second".utf8), "the first page that has a thumbnail")
	}

	// MARK: The data detector

	func testDetectedItemsKeepTheirCharactersAfterEmojiAndCJKText() {
		// Emoji take two UTF-16 units and one Character, so counting Characters put every later
		// match off by one per emoji; Range(_:in:) doesn't.
		let text = "📞 電話 +1 (415) 555-2671 ✉️ 連絡先 mail@example.com 🌐 https://example.com/docs ありがとう"
		XCTAssertEqual(ScanRecognizedItem.detect(.phoneNumber, in: text)?.filter(\.isNumber), "14155552671")
		XCTAssertEqual(ScanRecognizedItem.detect(.link, in: text, email: true), "mail@example.com")
		XCTAssertEqual(ScanRecognizedItem.detect(.link, in: text), "https://example.com/docs")
		XCTAssertNil(ScanRecognizedItem.detect(.address, in: text))
		XCTAssertNil(ScanRecognizedItem.detect(.phoneNumber, in: nil))
		XCTAssertNil(ScanRecognizedItem.detect(.link, in: "nothing to find here"))
	}

	func testALineOffersWhatItsTextHolds() throws {
		let context = try makeContext()
		let line = ScanRecognizedItem(context: context)
		line.transcript = "Call 📱 (415) 555-2671 or write to hello@example.com, see www.example.com"
		XCTAssertEqual(line.phoneNumber?.filter(\.isNumber), "4155552671")
		XCTAssertEqual(line.emailAddress, "hello@example.com")
		XCTAssertEqual(line.urlAddress, "www.example.com", "an address isn't offered as a web link too")
		XCTAssertNil(line.mailingAddress)
		line.transcript = nil
		XCTAssertNil(line.phoneNumber)
	}

	// MARK: Requests from outside

	func testRequestsFromOutsideWaitUntilTheWindowTakesThem() {
		let requests = AppRequests()
		XCTAssertTrue(requests.takeAll().isEmpty)
		requests.add(.startScan)
		requests.add(.shareNearby)
		XCTAssertEqual(requests.pending, [.startScan, .shareNearby], "kept until a window looks")
		XCTAssertEqual(requests.takeAll(), [.startScan, .shareNearby], "handed over in the order they came")
		XCTAssertTrue(requests.pending.isEmpty, "and only once")
	}

	func testSpotlightResultsOpenOnlyScansStillInTheLibrary() throws {
		let context = try makeContext()
		let live = scan("Live", in: context)
		let page = ScanCapture(context: context)
		page.id = UUID()
		let line = ScanRecognizedItem(context: context)
		line.transcript = "hello"
		page.addToRecognizedItems(line)
		live.addToCaptures(page)
		let trashed = scan("Trashed", in: context)
		let purged = scan("Purged", in: context)
		try context.save()

		func resolve(_ object: NSManagedObject) -> Scan? {
			let identifier = object.objectID.uriRepresentation().absoluteString
			guard let id = PersistenceController.objectID(forSpotlightIdentifier: identifier, in: context) else { return nil }
			return PersistenceController.liveScan(for: id, in: context)
		}
		XCTAssertEqual(resolve(live), live)
		XCTAssertEqual(resolve(line), live, "an entry from the old index, one per line, opens the line's scan")
		XCTAssertNil(resolve(page), "a page isn't a scan")

		Library.moveToRecentlyDeleted([trashed], in: context)
		XCTAssertNil(resolve(trashed), "Recently Deleted scans open nothing")
		Library.recover([trashed], in: context)
		XCTAssertEqual(resolve(trashed), trashed)

		let purgedID = purged.objectID
		context.delete(purged)
		try context.save()
		XCTAssertNil(PersistenceController.liveScan(for: purgedID, in: context), "a purged scan is never faulted in")

		XCTAssertNil(PersistenceController.objectID(forSpotlightIdentifier: "not a uri", in: context))
		XCTAssertNil(PersistenceController.objectID(forSpotlightIdentifier: "x-coredata://0000-0000/Scan/p1", in: context),
					 "another store's URI")
	}

	// MARK: Opening the library

	/// A store at `url` on the app's model, not yet loaded.
	private func unloadedContainer(at url: URL) -> NSPersistentContainer {
		let container = NSPersistentContainer(name: "scanner", managedObjectModel: PersistenceController.shared.container.managedObjectModel)
		container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
		containers.append(container)
		return container
	}

	/// Closes the container's stores, before their folder is removed.
	private func close(_ container: NSPersistentContainer) throws {
		let coordinator = container.persistentStoreCoordinator
		for store in coordinator.persistentStores { try coordinator.remove(store) }
	}

	private func temporaryFolder() throws -> URL {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryOpening-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
		return folder
	}

	func testALibraryThatOpensReportsNoFailure() throws {
		let container = unloadedContainer(at: try temporaryFolder().appendingPathComponent("scanner.sqlite"))
		XCTAssertNil(PersistenceController.loadFallingBackToMemory(container))
		XCTAssertNotEqual(container.persistentStoreCoordinator.persistentStores.first?.url, URL(fileURLWithPath: "/dev/null"))
		try close(container)
	}

	func testALibraryThatCantBeOpenedFallsBackToATemporaryOneAndLeavesTheFileAlone() throws {
		let url = try temporaryFolder().appendingPathComponent("scanner.sqlite")
		let unreadable = Data("not a library".utf8)
		try unreadable.write(to: url)
		let container = unloadedContainer(at: url)

		XCTAssertNotNil(PersistenceController.loadFallingBackToMemory(container), "the failure is reported, so the app can warn")
		XCTAssertEqual(container.persistentStoreCoordinator.persistentStores.first?.url, URL(fileURLWithPath: "/dev/null"))
		_ = scan("Made while temporary", in: container.viewContext)
		XCTAssertNoThrow(try container.viewContext.save(), "the app still works on the temporary library")
		XCTAssertEqual(try Data(contentsOf: url), unreadable, "the file on disk isn't touched")
		try close(container)
	}
}
