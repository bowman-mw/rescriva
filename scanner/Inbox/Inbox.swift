//
//  Inbox.swift
//  Rescriva (fork of Open Scanner)
//
//  Importing what Rescriva's extensions hand over (see InboxManifest.swift). On launch, on coming to
//  the foreground and on an openscanner://inbox link, everything waiting goes into PDF Files:
//  a PDF as it is, a web page saved as a PDF first, a link downloaded first (to the same size cap
//  as a hand-off, `InboxDrop.maxBytes`). Each hand-off's folder is deleted once it's been
//  through, imported or not. App-target only.
//

import SwiftUI

/// What one import did.
struct InboxReport: Equatable {
	/// PDFs added to PDF Files.
	var added = 0
	/// Hand-offs that couldn't be opened (and were removed).
	var failed = 0
	/// Why, when exactly one hand-off failed for a reason the Inbox can put into words (a link
	/// too large, a page that timed out). Nil otherwise; system errors stay in the log.
	var reason: String?

	/// The toast for what went wrong, or nil when everything opened (PDFOpening reports that).
	var problem: String? {
		guard failed > 0 else { return nil }
		var missed = failed == 1 ? String(localized: "1 item sent to Rescriva couldn't be opened.")
			: String(localized: "\(failed) items sent to Rescriva couldn't be opened.")
		if failed == 1, let reason {
			missed += " " + reason
		}
		guard added > 1 else { return missed }
		return String(localized: "Added \(added) PDFs.") + " " + missed
	}
}

/// How the Inbox reaches the web: the live one, or a stand-in in tests.
@MainActor
protocol InboxWeb {
	/// Saves the HTML Safari showed as a PDF.
	func pdf(html: String, baseURL: URL?) async throws -> Data
	/// Loads the page at `url` and saves it as a PDF.
	func pdf(loading url: URL) async throws -> Data
	/// Downloads `url` to a temporary file.
	func download(_ url: URL) async throws -> URL
}

@MainActor
enum Inbox {
	static let scheme = "openscanner"
	static let host = "inbox"
	/// Posted when an openscanner://inbox link arrives; every window's `inboxImports` hears it.
	static let importRequested = Notification.Name("com.rescriva.Inbox.importRequested")

	/// Claims an openscanner://inbox link and asks for an import. False for any other link.
	static func handle(_ url: URL) -> Bool {
		guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == host else { return false }
		NotificationCenter.default.post(name: importRequested, object: nil)
		return true
	}

	/// Imports everything ready in `store` into `library` through PDFOpening (one PDF opens
	/// straight away; more are counted in a toast), then removes every hand-off it looked at.
	@discardableResult
	static func importPending(from store: InboxStore?, into library: PDFLibrary, router: RescrivaRouter,
							  web: InboxWeb) async -> InboxReport {
		guard let store else { return InboxReport() }
		let contents = store.contents()
		for folder in contents.unusable + contents.abandoned {
			store.remove(folder)
		}
		var report = InboxReport(failed: contents.unusable.count)
		guard !contents.ready.isEmpty || report.failed > 0 else { return report }
		if contents.ready.contains(where: { $0.manifest.kind != .pdf }) {
			router.showToast(String(localized: "Opening what you sent to Rescriva…"))
		}
		var files: [URL] = []
		for item in contents.ready {
			do {
				files.append(try await pdfFile(for: item, web: web))
			} catch {
				Log.inbox.error("Couldn't import \(item.manifest.kind.rawValue) from the Inbox: \(error)")
				report.failed += 1
				report.reason = report.failed == 1 ? sentence(for: error) : nil
			}
		}
		let before = Set(library.items.map(\.id))
		await PDFOpening.open(files, in: library, router: router)
		report.added = library.items.filter { !before.contains($0.id) }.count
		report.failed += files.count - report.added
		if report.failed != 1 { report.reason = nil }
		for item in contents.ready {
			store.remove(item.folder)
		}
		if let problem = report.problem {
			router.showToast(problem)
		}
		return report
	}

	/// The hand-off as a PDF file in its folder, named for its title (PDFOpening titles it so).
	private static func pdfFile(for item: InboxStore.Item, web: InboxWeb) async throws -> URL {
		let manifest = item.manifest
		let destination = item.folder.appendingPathComponent(InboxDrop.fileName(for: manifest.title, kind: .pdf))
		switch manifest.kind {
		case .pdf:
			guard let file = item.fileURL else { throw InboxDropError.unknownHandOff }
			return file
		case .webPage:
			guard let file = item.fileURL else { throw InboxDropError.unknownHandOff }
			let html = try String(contentsOf: file, encoding: .utf8)
			try await web.pdf(html: html, baseURL: manifest.sourceURL).write(to: destination, options: .atomic)
			return destination
		case .link:
			guard let url = manifest.sourceURL else { throw InboxDropError.notAWebAddress }
			let downloaded = try await web.download(url)
			defer { FileManager.default.removeIfPresent(downloaded, log: Log.inbox) }
			if try InboxDrop.startsLikePDF(downloaded) {
				// A run cut short may have left one here already.
				FileManager.default.removeIfPresent(destination, log: Log.inbox)
				try FileManager.default.moveItem(at: downloaded, to: destination)
			} else {
				try await web.pdf(loading: url).write(to: destination, options: .atomic)
			}
			return destination
		}
	}

	/// The sentence for the toast when `error` is one of the Inbox's own; nil for a system error,
	/// whose wording wouldn't tell the user anything.
	private static func sentence(for error: Error) -> String? {
		switch error {
		case let known as InboxDropError: return known.errorDescription
		case let known as InboxDownloadError: return known.errorDescription
		case let known as WebPagePDFError: return known.errorDescription
		default: return nil
		}
	}
}

// MARK: - Downloads

enum InboxDownloadError: LocalizedError, Equatable {
	/// The server announced, or sent, more than `InboxDrop.maxBytes`.
	case tooLarge
	/// The server answered with an error status.
	case badResponse(Int)
	/// The download finished but its file couldn't be kept.
	case notSaved

	var errorDescription: String? {
		switch self {
		case .tooLarge:
			let limit = ByteCountFormatter.string(fromByteCount: InboxDrop.maxBytes, countStyle: .binary)
			return String(localized: "That link leads to a file over \(limit), too large for Rescriva to open.")
		case .badResponse(let status):
			return String(localized: "The site answered with an error (\(status)).")
		case .notSaved:
			return String(localized: "The download couldn't be saved.")
		}
	}
}

/// Keeps a link's download inside `InboxDrop.maxBytes`, the cap a hand-off from the extension has.
struct InboxDownloadLimit: Equatable {
	let maxBytes: Int64

	init(maxBytes: Int64 = InboxDrop.maxBytes) {
		self.maxBytes = maxBytes
	}

	/// Throws once `bytes`, announced (Content-Length) or received so far, is over the limit. A
	/// server that doesn't say how much is coming reports -1, which passes until the bytes show.
	func check(bytes: Int64) throws {
		guard bytes <= maxBytes else { throw InboxDownloadError.tooLarge }
	}
}

/// One download that stops the moment it passes its limit, kept as a file of our own. The
/// session's delegate queue is serial and the continuation is set before the task starts, so
/// the state below is only ever touched by one thread at a time; hence `@unchecked Sendable`.
private final class CappedDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
	private let limit: InboxDownloadLimit
	private let destination: URL
	private var waiting: CheckedContinuation<URL, Error>?
	private var failure: Error?
	private var saved = false

	init(limit: InboxDownloadLimit, destination: URL) {
		self.limit = limit
		self.destination = destination
	}

	/// Downloads `request` to the destination, giving up as soon as the server announces or sends
	/// more than the limit allows.
	func run(_ request: URLRequest) async throws -> URL {
		let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }
		let task = session.downloadTask(with: request)
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				waiting = continuation
				task.resume()
			}
		} onCancel: {
			task.cancel()
		}
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
					totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		do {
			try limit.check(bytes: totalBytesExpectedToWrite)
			try limit.check(bytes: totalBytesWritten)
		} catch {
			failure = error
			downloadTask.cancel()
		}
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		// URLSession deletes the file at `location` when this returns, so it's kept here or not at all.
		if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
			failure = InboxDownloadError.badResponse(http.statusCode)
			return
		}
		do {
			let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
			try limit.check(bytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0)
			try FileManager.default.moveItem(at: location, to: destination)
			saved = true
		} catch {
			failure = error
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard let waiting else { return }
		self.waiting = nil
		if let failure {
			waiting.resume(throwing: failure)
		} else if let error {
			waiting.resume(throwing: error)
		} else if saved {
			waiting.resume(returning: destination)
		} else {
			waiting.resume(throwing: InboxDownloadError.notSaved)
		}
	}
}

// MARK: - Live web

/// The Inbox's real web: WebKit for pages, URLSession for downloads.
struct LiveInboxWeb: InboxWeb {
	func pdf(html: String, baseURL: URL?) async throws -> Data {
		try await WebPagePDF.pdf(html: html, baseURL: baseURL)
	}

	func pdf(loading url: URL) async throws -> Data {
		try await WebPagePDF.pdf(loading: url)
	}

	/// Downloads `url` to a temporary file of our own, at most `InboxDrop.maxBytes`.
	func download(_ url: URL) async throws -> URL {
		let request = URLRequest(url: url, timeoutInterval: WebPagePDF.loadTimeout)
		let kept = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
		return try await CappedDownload(limit: InboxDownloadLimit(), destination: kept).run(request)
	}
}

// MARK: - When to import

/// Runs imports one at a time for the whole app (each window asks; there's one Inbox).
@MainActor
final class InboxImporter {
	static let shared = InboxImporter()
	/// Back-to-back passes one run may make while requests keep arriving.
	private static let maxPasses = 3

	private var isRunning = false
	private var askedAgain = false

	/// Imports now, or once more after the import already running.
	func request(router: RescrivaRouter) {
		guard !isRunning else {
			askedAgain = true
			return
		}
		isRunning = true
		Task {
			for _ in 0..<Self.maxPasses {
				askedAgain = false
				await Inbox.importPending(from: .shared, into: PDFLibrary.shared, router: router, web: LiveInboxWeb())
				guard askedAgain else { break }
			}
			isRunning = false
		}
	}
}

/// Imports the Inbox when the window comes to the foreground (launch included) and when an
/// openscanner://inbox link arrives.
private struct InboxImports: ViewModifier {
	@Environment(\.scenePhase) private var scenePhase
	let router: RescrivaRouter

	func body(content: Content) -> some View {
		content
			.onChange(of: scenePhase, initial: true) { _, phase in
				guard phase == .active else { return }
				InboxImporter.shared.request(router: router)
			}
			.onReceive(NotificationCenter.default.publisher(for: Inbox.importRequested)) { _ in
				InboxImporter.shared.request(router: router)
			}
	}
}

extension View {
	/// Brings in what Rescriva's extensions hand over; see `Inbox`.
	func inboxImports(router: RescrivaRouter) -> some View {
		modifier(InboxImports(router: router))
	}
}
