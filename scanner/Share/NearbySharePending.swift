//
//  NearbySharePending.swift
//  Rescriva (fork of Open Scanner)
//
//  An openscanner://share?p=… link (the web page's pairing code, scanned with the
//  Camera app or opened with "Open in Rescriva" on a Mac) waits here until the
//  Share Nearby screen is up to take it.
//

import CoreData
import Foundation

@MainActor
@Observable
final class NearbySharePending {
	static let shared = NearbySharePending()

	/// The longest link kept: a pairing link with eight candidates is well under this.
	static let maxLinkLength = 4_096

	/// The whole link, as it arrived. Untrusted: `SharePairingOffer(link:)` checks it.
	var link: String?

	/// True when `url` is a Share Nearby link (openscanner://share…), which is then kept in `link`
	/// for the screen. A link too long to be a pairing code is dropped, but still counts as handled.
	func receive(_ url: URL) -> Bool {
		guard url.scheme?.lowercased() == "openscanner", url.host()?.lowercased() == "share" else { return false }
		let text = url.absoluteString
		guard text.utf8.count <= Self.maxLinkLength else {
			print("Rescriva: ignored a Share Nearby link of \(text.utf8.count) bytes")
			return true
		}
		link = text
		return true
	}

	/// Hands over the waiting link once, clearing it.
	func take() -> String? {
		let waiting = link
		link = nil
		return waiting
	}

	#if DEBUG
	/// What `-shareNearbyDemo YES` shares at launch: the newest two documents in the library,
	/// PDFs first, then scans.
	static func demoItems(in context: NSManagedObjectContext) -> [NearbyShareItem] {
		var items: [NearbyShareItem] = PDFLibrary.shared.items.prefix(2).map { NearbyShareItem.pdf($0.id) }
		guard items.count < 2 else { return items }
		let request = NSFetchRequest<Scan>(entityName: "Scan")
		request.predicate = LibraryScope.livePredicate
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Scan.timestamp, ascending: false)]
		request.fetchLimit = 2 - items.count
		do {
			items += try context.fetch(request).map { NearbyShareItem.scan($0) }
		} catch {
			print("Rescriva: couldn't fetch scans for the Share Nearby demo: \(error)")
		}
		return items
	}
	#endif
}
