//
//  PDFBackgroundWork.swift
//  Rescriva (fork of Open Scanner)
//
//  What saving a PDF in the background needs: time from iOS to finish once the app leaves the
//  screen, and the bookmarks PDFKit leaves out when it copies a document. Page thumbnails are
//  drawn here too, off the main thread, from page copies the reader can't be changing.
//

import PDFKit
import UIKit

// MARK: - Time to finish

/// Asks iOS for time to finish work that started on screen. Without it, an app that leaves the
/// screen mid-save is suspended, or ended if it's busy, and the save is lost.
@MainActor
enum BackgroundTime {
	/// Runs `work`, holding background time until it's done (or iOS says time is up).
	static func protect(_ name: String, _ work: @escaping @MainActor () async -> Void) {
		let grant = BackgroundGrant()
		grant.begin(name)
		Task {
			await work()
			grant.end()
		}
	}
}

/// One request for background time, ended exactly once.
@MainActor
private final class BackgroundGrant {
	private var identifier = UIBackgroundTaskIdentifier.invalid

	func begin(_ name: String) {
		identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
			// Time's up: the last good copy stays on disk; iOS must hear back or it ends the app.
			MainActor.assumeIsolated { self?.end() }
		}
	}

	func end() {
		guard identifier != .invalid else { return }
		UIApplication.shared.endBackgroundTask(identifier)
		identifier = .invalid
	}
}

// MARK: - Bookmarks

/// Copies a document's outline into a copy of it, pointing each entry at the same page there.
enum PDFOutlineCopy {
	/// Outlines nest; this deep is plenty, and keeps a malformed one from running away.
	static let maxDepth = 32

	static func copy(_ outline: PDFOutline, from source: PDFDocument, to target: PDFDocument, depth: Int) -> PDFOutline {
		let copy = PDFOutline()
		copy.label = outline.label
		copy.isOpen = outline.isOpen
		copy.destination = outline.destination.flatMap { destination($0, from: source, to: target) }
		copy.action = outline.action.flatMap { action($0, from: source, to: target) }
		guard depth < maxDepth else { return copy }
		for index in 0..<outline.numberOfChildren {
			guard let child = outline.child(at: index) else { continue }
			copy.insertChild(Self.copy(child, from: source, to: target, depth: depth + 1), at: copy.numberOfChildren)
		}
		return copy
	}

	private static func destination(_ destination: PDFDestination, from source: PDFDocument, to target: PDFDocument) -> PDFDestination? {
		guard let page = destination.page else { return nil }
		let index = source.index(for: page)
		guard index != NSNotFound, let mapped = target.page(at: index) else { return nil }
		let copy = PDFDestination(page: mapped, at: destination.point)
		copy.zoom = destination.zoom
		return copy
	}

	/// A go-to points at the copy's page; any other action (a web link) copies as it is.
	private static func action(_ action: PDFAction, from source: PDFDocument, to target: PDFDocument) -> PDFAction? {
		if let goTo = action as? PDFActionGoTo {
			return destination(goTo.destination, from: source, to: target).map(PDFActionGoTo.init(destination:))
		}
		return action.copy() as? PDFAction
	}
}

// MARK: - Thumbnails

/// Draws page thumbnails one at a time off the main thread. Each is drawn from a copy of the page,
/// taken on the main thread, so the open document is never touched from here; a request whose
/// cell has scrolled away is dropped before it's drawn.
actor PDFThumbnailRenderer {
	static let shared = PDFThumbnailRenderer()

	/// `page` (a copy no one else holds) drawn `size` pixels at most, keeping its shape.
	func render(_ page: PDFPage, size: CGSize) -> UIImage? {
		guard !Task.isCancelled else { return nil }
		return page.thumbnail(of: size, for: .cropBox)
	}
}

extension PDFPage {
	/// A copy of the page to hand to another thread or actor (`PDFThumbnailRenderer`). It shares
	/// nothing with the page, which the compiler can't tell by itself, so it's handed back `sending`.
	func unsharedCopy() -> sending PDFPage? {
		nonisolated(unsafe) let copy = copy() as? PDFPage
		return copy
	}
}
