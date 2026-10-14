//
//  InboxTests.swift
//  Rescriva (fork of Open Scanner)
//
//  The Inbox the Safari extension hands files through: manifests and what makes one usable,
//  files arriving in pieces, the extension's native messages, sorting the folder into ready,
//  unusable, abandoned and arriving, and the import into PDF Files that clears it, bad files
//  skipped. Web pages render through a stand-in web, plus one real WebKit render. Also the
//  download cap's arithmetic and what the toast says when a link is too large, and the PDF
//  library keeping a PDF whose record is broken.
//

import PDFKit
import UIKit
import XCTest
@testable import scanner

@MainActor
final class InboxTests: XCTestCase {
	private var folder: URL!
	private var inbox: URL { folder.appendingPathComponent("Inbox", isDirectory: true) }
	private var drop: InboxDrop { InboxDrop(root: inbox) }
	private var store: InboxStore { InboxStore(root: inbox) }

	override func setUpWithError() throws {
		folder = FileManager.default.temporaryDirectory.appendingPathComponent("InboxTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: folder)
	}

	// MARK: Files

	func testRemoveIfPresentIsQuietAboutWhatIsntThere() throws {
		let file = folder.appendingPathComponent("gone.txt")
		try Data("x".utf8).write(to: file)
		FileManager.default.removeIfPresent(file, log: Log.inbox)
		XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
		FileManager.default.removeIfPresent(file, log: Log.inbox)
		XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a second call is a no-op, not an error")

		let nested = folder.appendingPathComponent("nested", isDirectory: true)
		try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
		try Data("y".utf8).write(to: nested.appendingPathComponent("inner.txt"))
		FileManager.default.removeIfPresent(nested)
		XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path), "a folder goes with its contents")
	}

	// MARK: Manifest

	func testManifestRoundTripsThroughJSON() throws {
		let manifest = InboxManifest(kind: .webPage, file: "Recipe.html", title: "Recipe",
									 sourceURL: URL(string: "https://example.com/recipe"), createdAt: Date(timeIntervalSince1970: 1_760_000_000))
		let decoded = try InboxManifest.decode(manifest.encoded())
		XCTAssertEqual(decoded, manifest)
		XCTAssertTrue(decoded.isValid)

		let json = #"{"version":1,"kind":"link","title":"Lease","sourceURL":"https://example.com/lease.pdf","createdAt":"2026-10-11T12:00:00Z"}"#
		let link = try InboxManifest.decode(Data(json.utf8))
		XCTAssertEqual(link.kind, .link)
		XCTAssertNil(link.file)
		XCTAssertTrue(link.isValid)
	}

	func testManifestMissingFieldsOrUnknownKindDoesNotDecode() {
		let noVersion = #"{"kind":"pdf","file":"a.pdf","title":"A","createdAt":"2026-10-11T12:00:00Z"}"#
		let unknownKind = #"{"version":1,"kind":"video","file":"a.mov","title":"A","createdAt":"2026-10-11T12:00:00Z"}"#
		XCTAssertThrowsError(try InboxManifest.decode(Data(noVersion.utf8)))
		XCTAssertThrowsError(try InboxManifest.decode(Data(unknownKind.utf8)))
		XCTAssertThrowsError(try InboxManifest.decode(Data("not json".utf8)))
	}

	func testManifestRejectsFilesOutsideItsFolderAndLinksThatArentWebAddresses() {
		let now = Date()
		func pdf(_ file: String?) -> InboxManifest { InboxManifest(kind: .pdf, file: file, title: "A", createdAt: now) }
		XCTAssertTrue(pdf("Lease 2026.pdf").isValid)
		XCTAssertFalse(pdf("../Lease.pdf").isValid)
		XCTAssertFalse(pdf("nested/Lease.pdf").isValid)
		XCTAssertFalse(pdf(".hidden.pdf").isValid)
		XCTAssertFalse(pdf("").isValid)
		XCTAssertFalse(pdf(nil).isValid, "a PDF needs its file")

		var link = InboxManifest(kind: .link, title: "A", sourceURL: URL(string: "file:///etc/hosts"), createdAt: now)
		XCTAssertFalse(link.isValid, "a link must be a web address")
		link.sourceURL = URL(string: "https://example.com/a.pdf")
		XCTAssertTrue(link.isValid)
		link.file = "a.pdf"
		XCTAssertFalse(link.isValid, "a link has no file")

		var newer = pdf("a.pdf")
		newer.version = InboxManifest.currentVersion + 1
		XCTAssertFalse(newer.isValid, "a format this build doesn't know is skipped")
	}

	func testTitlesBecomeSafeFileNames() {
		XCTAssertEqual(InboxDrop.fileName(for: "Lease 2026.pdf", kind: .pdf), "Lease 2026.pdf")
		XCTAssertEqual(InboxDrop.fileName(for: "../../etc/passwd", kind: .pdf), "etc passwd.pdf")
		XCTAssertEqual(InboxDrop.fileName(for: "Q3: plan / budget?", kind: .webPage), "Q3 plan budget.html")
		XCTAssertEqual(InboxDrop.fileName(for: "  \n ", kind: .pdf), "Document.pdf")
		XCTAssertEqual(InboxDrop.fileName(for: "", kind: .webPage), "Web page.html")
		XCTAssertEqual(InboxDrop.cleanTitle(String(repeating: "a", count: 200), kind: .pdf).utf8.count, InboxDrop.maxNameBytes)
	}

	func testFileNamesAreCappedByBytesKeepingWholeCharacters() throws {
		XCTAssertEqual(InboxDrop.truncated("héllo", toUTF8Bytes: 2), "h", "a character is kept whole or left off")
		XCTAssertEqual(InboxDrop.truncated("héllo", toUTF8Bytes: 3), "hé")
		XCTAssertEqual(InboxDrop.truncated("héllo", toUTF8Bytes: 100), "héllo")
		XCTAssertEqual(InboxDrop.truncated("", toUTF8Bytes: 10), "")

		// A flag is one character of eight bytes: 80 of them used to make a 640-byte name.
		let flags = String(repeating: "🇨🇦", count: 80)
		let name = InboxDrop.cleanTitle(flags, kind: .pdf)
		XCTAssertEqual(name, String(repeating: "🇨🇦", count: InboxDrop.maxNameBytes / 8))
		XCTAssertLessThanOrEqual(name.utf8.count, InboxDrop.maxNameBytes)

		// createFile failed on such a name; now the hand-off begins.
		let id = try drop.begin(.pdf, title: String(repeating: "📄", count: 100), sourceURL: nil)
		let files = try FileManager.default.contentsOfDirectory(atPath: drop.folder(for: id).path)
		let pdf = try XCTUnwrap(files.first { $0.hasSuffix(".pdf") })
		XCTAssertLessThanOrEqual(pdf.utf8.count, InboxDrop.maxNameBytes + ".pdf".utf8.count)
		XCTAssertEqual(InboxDrop.fileName(for: "Lease 2026", kind: .pdf), "Lease 2026.pdf", "short names are untouched")
	}

	func testLinksMustBeHTTPS() throws {
		XCTAssertTrue(InboxManifest.isWebAddress(try XCTUnwrap(URL(string: "https://example.com/a.pdf"))))
		XCTAssertTrue(InboxManifest.isWebAddress(try XCTUnwrap(URL(string: "HTTPS://Example.com"))))
		XCTAssertFalse(InboxManifest.isWebAddress(try XCTUnwrap(URL(string: "http://example.com/a.pdf"))), "ATS refuses plain http")
		XCTAssertFalse(InboxManifest.isWebAddress(try XCTUnwrap(URL(string: "ftp://example.com/a.pdf"))))
		XCTAssertFalse(InboxManifest.isWebAddress(try XCTUnwrap(URL(string: "mailto:someone@example.com"))))

		var manifest = InboxManifest(kind: .link, title: "A", sourceURL: URL(string: "http://example.com/a.pdf"), createdAt: Date())
		XCTAssertFalse(manifest.isValid)
		manifest.sourceURL = URL(string: "https://example.com/a.pdf")
		XCTAssertTrue(manifest.isValid)

		let plain = try XCTUnwrap(URL(string: "http://example.com/a.pdf"))
		XCTAssertThrowsError(try drop.dropLink(plain, title: "Plain")) { XCTAssertEqual($0 as? InboxDropError, .notAWebAddress) }
		XCTAssertThrowsError(try drop.begin(.pdf, title: "Plain", sourceURL: plain)) { XCTAssertEqual($0 as? InboxDropError, .notAWebAddress) }
		let reply = InboxMessage.respond(to: ["action": "link", "title": "Plain", "sourceURL": "http://example.com"], drop: drop)
		XCTAssertEqual(reply["ok"] as? Bool, false)
		XCTAssertEqual(reply["error"] as? String, InboxDropError.notAWebAddress.errorDescription)
		XCTAssertTrue(store.contents().ready.isEmpty)
	}

	// MARK: Arriving in pieces

	func testPiecesArriveAndCommitHandsTheFileOver() throws {
		let pdf = Self.pdfData(text: "Pieces")
		let half = pdf.count / 2
		let id = try drop.begin(.pdf, title: "Lease", sourceURL: URL(string: "https://example.com/lease.pdf"))
		XCTAssertEqual(store.contents().arriving, 1, "not ready until it's committed")
		XCTAssertEqual(try drop.append(pdf.prefix(half), to: id), Int64(half))
		XCTAssertEqual(try drop.append(pdf.suffix(from: half), to: id), Int64(pdf.count))
		try drop.commit(id)

		let contents = store.contents()
		XCTAssertEqual(contents.ready.count, 1)
		XCTAssertEqual(contents.arriving, 0)
		let item = try XCTUnwrap(contents.ready.first)
		XCTAssertEqual(item.manifest.kind, .pdf)
		XCTAssertEqual(item.manifest.title, "Lease")
		XCTAssertEqual(item.fileURL?.lastPathComponent, "Lease.pdf")
		XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(item.fileURL)), pdf)
		XCTAssertFalse(FileManager.default.fileExists(atPath: drop.folder(for: id).appendingPathComponent(InboxManifest.pendingFileName).path))
	}

	func testCommitRefusesAFileThatIsntAPDFOrIsEmpty() throws {
		let notPDF = try drop.begin(.pdf, title: "Fake", sourceURL: nil)
		_ = try drop.append(Data("<html>Sign in</html>".utf8), to: notPDF)
		XCTAssertThrowsError(try drop.commit(notPDF)) { XCTAssertEqual($0 as? InboxDropError, .notAPDF) }

		let empty = try drop.begin(.webPage, title: "Blank", sourceURL: nil)
		XCTAssertThrowsError(try drop.commit(empty)) { XCTAssertEqual($0 as? InboxDropError, .empty) }

		XCTAssertTrue(store.contents().ready.isEmpty)
		drop.cancel(notPDF)
		drop.cancel(empty)
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [], "cancel removes what was still arriving")
	}

	func testAppendRefusesToGrowPastTheLimitAndUnknownHandOffs() throws {
		let id = try drop.begin(.pdf, title: "Huge", sourceURL: nil)
		let file = drop.folder(for: id).appendingPathComponent("Huge.pdf")
		let handle = try FileHandle(forWritingTo: file)
		try handle.truncate(atOffset: UInt64(InboxDrop.maxBytes))  // sparse: no real disk used
		try handle.close()
		XCTAssertThrowsError(try drop.append(Data([0]), to: id)) { XCTAssertEqual($0 as? InboxDropError, .tooLarge) }
		XCTAssertThrowsError(try drop.append(Data([0]), to: UUID())) { XCTAssertEqual($0 as? InboxDropError, .unknownHandOff) }
		XCTAssertThrowsError(try drop.begin(.pdf, title: "Local", sourceURL: URL(string: "file:///etc/hosts")))
	}

	func testCancelLeavesAHandOffThatWasAlreadyCommitted() throws {
		let id = try drop.dropLink(try XCTUnwrap(URL(string: "https://example.com/a.pdf")), title: "A")
		drop.cancel(id)
		XCTAssertEqual(store.contents().ready.count, 1)
	}

	// MARK: Native messages

	func testNativeMessagesWriteAHandOff() throws {
		let pdf = Self.pdfData(text: "Native")
		let begin = InboxMessage.respond(to: ["action": "begin", "kind": "pdf", "title": "Statement.pdf",
											  "sourceURL": "https://bank.example/statement.pdf"], drop: drop)
		XCTAssertEqual(begin["ok"] as? Bool, true)
		let id = try XCTUnwrap(begin["id"] as? String)
		let append = InboxMessage.respond(to: ["action": "append", "id": id, "data": pdf.base64EncodedString()], drop: drop)
		XCTAssertEqual(append["ok"] as? Bool, true)
		XCTAssertEqual((append["bytes"] as? NSNumber)?.intValue, pdf.count)
		XCTAssertEqual(InboxMessage.respond(to: ["action": "commit", "id": id], drop: drop)["ok"] as? Bool, true)

		let link = InboxMessage.respond(to: ["action": "link", "title": "Docs", "sourceURL": "https://example.com/docs"], drop: drop)
		XCTAssertEqual(link["ok"] as? Bool, true)

		let ready = store.contents().ready
		XCTAssertEqual(Set(ready.map(\.manifest.kind.rawValue)), ["pdf", "link"])
		XCTAssertEqual(Set(ready.map(\.manifest.title)), ["Statement", "Docs"])
		XCTAssertEqual(ready.first { $0.manifest.kind == .pdf }?.manifest.sourceURL?.host(), "bank.example")
	}

	func testNativeMessagesReportFailuresAsSentences() {
		let noGroup = InboxMessage.respond(to: ["action": "link", "sourceURL": "https://example.com"], drop: nil)
		XCTAssertEqual(noGroup["ok"] as? Bool, false)
		XCTAssertEqual(noGroup["error"] as? String, InboxDropError.unavailable.errorDescription)

		let cases: [Any?] = [
			nil,
			"begin",
			["action": "explode"],
			["action": "begin", "kind": "video"],
			["action": "append", "id": "not-a-uuid", "data": ""],
			["action": "append", "id": UUID().uuidString, "data": "%%%not base64"],
			["action": "commit", "id": UUID().uuidString],
			["action": "link", "sourceURL": "javascript:alert(1)"],
		]
		for message in cases {
			let reply = InboxMessage.respond(to: message, drop: drop)
			XCTAssertEqual(reply["ok"] as? Bool, false, "\(String(describing: message))")
			XCTAssertFalse((reply["error"] as? String ?? "").isEmpty, "\(String(describing: message))")
		}
		XCTAssertTrue(store.contents().ready.isEmpty)
	}

	// MARK: Store

	func testStoreSortsReadyUnusableAbandonedAndArriving() throws {
		let older = try drop.dropLink(try XCTUnwrap(URL(string: "https://example.com/older")), title: "Older",
									  now: Date(timeIntervalSince1970: 1_000))
		let newer = try drop.dropLink(try XCTUnwrap(URL(string: "https://example.com/newer")), title: "Newer",
									  now: Date(timeIntervalSince1970: 2_000))

		let garbled = inbox.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: garbled, withIntermediateDirectories: true)
		try Data("{ not json".utf8).write(to: garbled.appendingPathComponent(InboxManifest.fileName))

		let missingFile = try drop.begin(.pdf, title: "Gone", sourceURL: nil)
		_ = try drop.append(Self.pdfData(text: "Gone"), to: missingFile)
		try drop.commit(missingFile)
		try FileManager.default.removeItem(at: drop.folder(for: missingFile).appendingPathComponent("Gone.pdf"))

		_ = try drop.begin(.webPage, title: "Still coming", sourceURL: nil)
		let stale = try drop.begin(.webPage, title: "Popup closed", sourceURL: nil)
		let longAgo = Date().addingTimeInterval(-2 * InboxStore.abandonedAfter)
		let staleFolder = drop.folder(for: stale)
		for url in [staleFolder] + (try FileManager.default.contentsOfDirectory(at: staleFolder, includingPropertiesForKeys: nil)) {
			try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)
		}
		try Data("stray".utf8).write(to: inbox.appendingPathComponent("stray.txt"))

		let contents = store.contents()
		XCTAssertEqual(contents.ready.map(\.folder.lastPathComponent), [older.uuidString, newer.uuidString], "oldest first")
		XCTAssertEqual(Set(contents.unusable.map(\.lastPathComponent)), [garbled.lastPathComponent, missingFile.uuidString])
		XCTAssertEqual(contents.abandoned.map(\.lastPathComponent), [stale.uuidString])
		XCTAssertEqual(contents.arriving, 1)
	}

	func testStoreRemovesOnlyItsOwnFolders() throws {
		let outside = folder.appendingPathComponent("Keep", isDirectory: true)
		try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
		store.remove(outside)
		XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
	}

	func testStoreRefusesAPDFThatNoLongerLooksLikeOne() async throws {
		try handOff(Self.pdfData(text: "Swapped"), title: "Swapped")
		let file = try XCTUnwrap(store.contents().ready.first?.fileURL)
		// On a Mac any process can write the App Group folder: the file was swapped after commit.
		try Data("<html>Sign in</html>".utf8).write(to: file)

		let contents = store.contents()
		XCTAssertTrue(contents.ready.isEmpty)
		XCTAssertEqual(contents.unusable.map(\.lastPathComponent), [file.deletingLastPathComponent().lastPathComponent])

		let library = PDFLibrary(root: folder.appendingPathComponent("PDFs"))
		let router = RescrivaRouter()
		let report = await Inbox.importPending(from: store, into: library, router: router, web: FakeWeb())
		XCTAssertEqual(report, InboxReport(added: 0, failed: 1))
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [], "refused and removed")
		XCTAssertTrue(library.items.isEmpty)
		XCTAssertEqual(router.toast?.message, "1 item sent to Rescriva couldn't be opened.")
	}

	// MARK: Import

	func testImportOpensAPDFAndClearsTheInbox() async throws {
		try handOff(Self.pdfData(text: "Lease"), title: "Lease 2026")
		let library = PDFLibrary(root: folder.appendingPathComponent("PDFs"))
		let router = RescrivaRouter()

		let report = await Inbox.importPending(from: store, into: library, router: router, web: FakeWeb())

		XCTAssertEqual(report, InboxReport(added: 1, failed: 0))
		XCTAssertEqual(library.items.map(\.title), ["Lease 2026"])
		let item = try XCTUnwrap(library.items.first)
		XCTAssertEqual(router.top, .pdf(item.id, query: nil), "one PDF opens straight away")
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
		XCTAssertTrue(FileManager.default.fileExists(atPath: library.originalURL(for: item).path), "the library keeps its own copy")
	}

	func testImportSkipsBadFilesRemovesThemAndSaysSo() async throws {
		try handOff(Self.pdfData(text: "Good"), title: "Good")
		try handOff(Data("%PDF-1.7 but nothing else".utf8), title: "Broken")
		let garbled = inbox.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: garbled, withIntermediateDirectories: true)
		try Data("{}".utf8).write(to: garbled.appendingPathComponent(InboxManifest.fileName))
		_ = try drop.begin(.webPage, title: "Still coming", sourceURL: nil)
		let library = PDFLibrary(root: folder.appendingPathComponent("PDFs"))
		let router = RescrivaRouter()

		let report = await Inbox.importPending(from: store, into: library, router: router, web: FakeWeb())

		XCTAssertEqual(report, InboxReport(added: 1, failed: 2))
		XCTAssertEqual(library.items.map(\.title), ["Good"])
		XCTAssertEqual(router.toast?.message, report.problem)
		XCTAssertEqual(store.contents().arriving, 1, "a transfer still arriving is left alone")
		XCTAssertTrue(store.contents().ready.isEmpty)
		XCTAssertTrue(store.contents().unusable.isEmpty)
	}

	func testImportSavesPagesAndLinksAsPDFs() async throws {
		let page = try drop.begin(.webPage, title: "Recipe", sourceURL: URL(string: "https://example.com/recipe"))
		_ = try drop.append(Data("<h1>Soup</h1>".utf8), to: page)
		try drop.commit(page)
		let pdfLink = try XCTUnwrap(URL(string: "https://example.com/manual.pdf"))
		let pageLink = try XCTUnwrap(URL(string: "https://example.com/about"))
		let missingLink = try XCTUnwrap(URL(string: "https://example.com/404"))
		_ = try drop.dropLink(pdfLink, title: "Manual")
		_ = try drop.dropLink(pageLink, title: "About")
		_ = try drop.dropLink(missingLink, title: "Missing")
		let web = FakeWeb()
		web.downloads = [pdfLink: Self.pdfData(text: "Manual"), pageLink: Data("<html>About</html>".utf8)]
		let library = PDFLibrary(root: folder.appendingPathComponent("PDFs"))
		let router = RescrivaRouter()

		let report = await Inbox.importPending(from: store, into: library, router: router, web: web)

		XCTAssertEqual(report, InboxReport(added: 3, failed: 1))
		XCTAssertEqual(Set(library.items.map(\.title)), ["Recipe", "Manual", "About"])
		XCTAssertEqual(web.renderedHTML, ["<h1>Soup</h1>"])
		XCTAssertEqual(web.renderedBase, [URL(string: "https://example.com/recipe")])
		XCTAssertEqual(web.loaded, [pageLink], "only the link that wasn't a PDF is rendered")
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
		XCTAssertEqual(router.toast?.message, "Added 3 PDFs. 1 item sent to Rescriva couldn't be opened.")
	}

	func testImportWithoutAnAppGroupOrAnythingWaitingDoesNothing() async {
		let library = PDFLibrary(root: folder.appendingPathComponent("PDFs"))
		let router = RescrivaRouter()
		let none = await Inbox.importPending(from: nil, into: library, router: router, web: FakeWeb())
		let empty = await Inbox.importPending(from: store, into: library, router: router, web: FakeWeb())
		XCTAssertEqual(none, InboxReport())
		XCTAssertEqual(empty, InboxReport())
		XCTAssertNil(router.toast)
		XCTAssertTrue(router.stack.isEmpty)
	}

	func testReportWording() {
		XCTAssertNil(InboxReport(added: 2, failed: 0).problem)
		XCTAssertEqual(InboxReport(added: 0, failed: 1).problem, "1 item sent to Rescriva couldn't be opened.")
		XCTAssertEqual(InboxReport(added: 1, failed: 2).problem, "2 items sent to Rescriva couldn't be opened.")
		XCTAssertEqual(InboxReport(added: 2, failed: 1).problem, "Added 2 PDFs. 1 item sent to Rescriva couldn't be opened.")
		XCTAssertEqual(InboxReport(added: 0, failed: 1, reason: "It was too big.").problem,
					   "1 item sent to Rescriva couldn't be opened. It was too big.")
		XCTAssertEqual(InboxReport(added: 0, failed: 2, reason: "It was too big.").problem,
					   "2 items sent to Rescriva couldn't be opened.", "a reason only explains a single failure")
	}

	// MARK: Download cap

	func testDownloadLimitIsTheHandOffCap() {
		let limit = InboxDownloadLimit()
		XCTAssertEqual(limit.maxBytes, InboxDrop.maxBytes)
		XCTAssertNoThrow(try limit.check(bytes: -1), "a server that doesn't say how much is coming")
		XCTAssertNoThrow(try limit.check(bytes: 0))
		XCTAssertNoThrow(try limit.check(bytes: InboxDrop.maxBytes))
		XCTAssertThrowsError(try limit.check(bytes: InboxDrop.maxBytes + 1)) { XCTAssertEqual($0 as? InboxDownloadError, .tooLarge) }

		let small = InboxDownloadLimit(maxBytes: 10)
		XCTAssertNoThrow(try small.check(bytes: 10))
		XCTAssertThrowsError(try small.check(bytes: 11))
		XCTAssertTrue(InboxDownloadError.tooLarge.errorDescription?.contains("150") == true, "the toast names the cap")
	}

	func testImportSaysWhyALinkWasTooLarge() async throws {
		let huge = try XCTUnwrap(URL(string: "https://example.com/huge.pdf"))
		_ = try drop.dropLink(huge, title: "Huge")
		let web = FakeWeb()
		web.failures = [huge: InboxDownloadError.tooLarge]
		let library = PDFLibrary(root: folder.appendingPathComponent("PDFs"))
		let router = RescrivaRouter()

		let report = await Inbox.importPending(from: store, into: library, router: router, web: web)

		let reason = try XCTUnwrap(InboxDownloadError.tooLarge.errorDescription)
		XCTAssertEqual(report, InboxReport(added: 0, failed: 1, reason: reason))
		XCTAssertEqual(router.toast?.message, "1 item sent to Rescriva couldn't be opened. " + reason)
		XCTAssertTrue(web.loaded.isEmpty, "a file too large isn't tried again as a page")
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
	}

	func testImportKeepsSystemErrorsOutOfTheToast() async throws {
		let gone = try XCTUnwrap(URL(string: "https://example.com/gone.pdf"))
		_ = try drop.dropLink(gone, title: "Gone")
		let web = FakeWeb()
		web.failures = [gone: URLError(.cannotConnectToHost)]
		let library = PDFLibrary(root: folder.appendingPathComponent("PDFs"))
		let router = RescrivaRouter()

		let report = await Inbox.importPending(from: store, into: library, router: router, web: web)

		XCTAssertEqual(report, InboxReport(added: 0, failed: 1))
		XCTAssertEqual(router.toast?.message, "1 item sent to Rescriva couldn't be opened.")
	}

	// MARK: Links

	func testOnlyTheInboxLinkIsClaimed() throws {
		let posted = expectation(forNotification: Inbox.importRequested, object: nil)
		XCTAssertTrue(Inbox.handle(try XCTUnwrap(URL(string: "openscanner://inbox"))))
		wait(for: [posted], timeout: 1)
		XCTAssertTrue(Inbox.handle(try XCTUnwrap(URL(string: "OpenScanner://INBOX"))))
		XCTAssertFalse(Inbox.handle(try XCTUnwrap(URL(string: "openscanner://scan"))))
		XCTAssertFalse(Inbox.handle(try XCTUnwrap(URL(string: "https://inbox.example.com"))))
		XCTAssertFalse(Inbox.handle(URL(fileURLWithPath: "/tmp/inbox")))
	}

	// MARK: PDF library

	func testLibraryKeepsAPDFWhoseRecordIsBrokenOrMissing() throws {
		let root = folder.appendingPathComponent("PDFs")
		let library = PDFLibrary(root: root)
		let kept = try library.add(Self.pdfData(text: "Kept"), title: "Kept")
		let broken = try library.add(Self.pdfData(text: "Broken", title: "Lease from its metadata"), title: "Broken")
		let brokenInfo = root.appendingPathComponent(broken.id.uuidString).appendingPathComponent("info.json")
		try Data("{ not json".utf8).write(to: brokenInfo)
		// The app quit between copying the PDF in and writing its record.
		let orphan = UUID()
		let orphanFolder = root.appendingPathComponent(orphan.uuidString)
		try FileManager.default.createDirectory(at: orphanFolder, withIntermediateDirectories: true)
		try Self.pdfData(text: "Orphan").write(to: orphanFolder.appendingPathComponent("original.pdf"))
		// Neither of these is an item: no PDF, and not one of the library's folders.
		try FileManager.default.createDirectory(at: root.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
		try Data("stray".utf8).write(to: root.appendingPathComponent(".DS_Store"))

		let reloaded = PDFLibrary(root: root)

		XCTAssertEqual(Set(reloaded.items.map(\.id)), [kept.id, broken.id, orphan])
		XCTAssertEqual(reloaded.item(kept.id)?.title, "Kept")
		let standIn = try XCTUnwrap(reloaded.item(broken.id))
		XCTAssertEqual(standIn.title, "Lease from its metadata", "the title the PDF carries")
		XCTAssertEqual(standIn.pageCount, 1)
		XCTAssertGreaterThan(standIn.byteCount, 0)
		XCTAssertNil(standIn.editedAt)
		XCTAssertEqual(try Data(contentsOf: brokenInfo), Data("{ not json".utf8), "an unreadable record is left for recovery")
		let recovered = try XCTUnwrap(reloaded.item(orphan))
		XCTAssertEqual(recovered.title, "Untitled PDF")
		XCTAssertTrue(FileManager.default.fileExists(atPath: orphanFolder.appendingPathComponent("info.json").path), "a missing record is written back")
		let readBack = try XCTUnwrap(PDFLibrary(root: root).item(orphan), "and reads back")
		XCTAssertEqual(readBack.title, recovered.title)
		XCTAssertEqual(readBack.pageCount, recovered.pageCount)
	}

	// MARK: WebKit

	func testWebPageRendersToAPaginatedPDF() async throws {
		let paragraphs = (1...80).map { "<p>Paragraph \($0) of the Rescriva test page, long enough to wrap onto a second line.</p>" }
		let html = "<html><head><title>Rescriva test page</title></head><body><h1>Hello Rescriva</h1>\(paragraphs.joined())</body></html>"
		let data = try await WebPagePDF.pdf(html: html, baseURL: URL(string: "https://example.com/"), paper: CGSize(width: 612, height: 792))
		let document = try XCTUnwrap(PDFDocument(data: data))
		XCTAssertGreaterThan(document.pageCount, 1, "a long page is cut into sheets")
		let firstPage = try XCTUnwrap(document.page(at: 0))
		XCTAssertEqual(firstPage.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
		XCTAssertTrue(document.string?.contains("Hello Rescriva") == true, "the text stays text")
		XCTAssertTrue(document.string?.contains("Paragraph 80") == true, "nothing is cut off the end")
	}

	func testViewportUnitsMeasureTheSheet() async throws {
		// A hero block 90% of the window tall, as many sites open with, then a line under it.
		// Printed, the window is the sheet: it all fits on one, with no blank sheet after.
		let html = """
		<!DOCTYPE html><html><head><title>Hero</title><style>body{margin:0;font:16px system-ui}\
		.hero{height:90vh;background:#ddd}</style></head><body><div class="hero">Welcome</div><p>Under the hero</p></body></html>
		"""
		let data = try await WebPagePDF.pdf(html: html, baseURL: URL(string: "https://example.com/"), paper: CGSize(width: 612, height: 792))
		let document = try XCTUnwrap(PDFDocument(data: data))
		XCTAssertEqual(document.pageCount, 1)
		XCTAssertTrue(document.string?.contains("Under the hero") == true)
	}

	// MARK: Helpers

	/// Commits a PDF hand-off the way the extension does.
	private func handOff(_ data: Data, title: String) throws {
		let id = try drop.begin(.pdf, title: title, sourceURL: nil)
		_ = try drop.append(data, to: id)
		try drop.commit(id)
	}

	/// A one-page PDF showing `text`, with `title` in its metadata when given.
	static func pdfData(text: String, title: String? = nil) -> Data {
		let format = UIGraphicsPDFRendererFormat()
		if let title {
			format.documentInfo = [kCGPDFContextTitle as String: title]
		}
		return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 300), format: format).pdfData { context in
			context.beginPage()
			(text as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
		}
	}
}

/// The web, standing in: pages render to a one-page PDF; downloads come from a table, or fail
/// with the error in `failures`.
@MainActor
private final class FakeWeb: InboxWeb {
	var downloads: [URL: Data] = [:]
	var failures: [URL: Error] = [:]
	private(set) var renderedHTML: [String] = []
	private(set) var renderedBase: [URL?] = []
	private(set) var loaded: [URL] = []

	func pdf(html: String, baseURL: URL?) async throws -> Data {
		renderedHTML.append(html)
		renderedBase.append(baseURL)
		return InboxTests.pdfData(text: "Rendered page")
	}

	func pdf(loading url: URL) async throws -> Data {
		loaded.append(url)
		return InboxTests.pdfData(text: "Loaded page")
	}

	func download(_ url: URL) async throws -> URL {
		if let failure = failures[url] { throw failure }
		guard let data = downloads[url] else { throw URLError(.fileDoesNotExist) }
		let file = FileManager.default.temporaryDirectory.appendingPathComponent("InboxTests-download-\(UUID().uuidString)")
		try data.write(to: file)
		return file
	}
}
