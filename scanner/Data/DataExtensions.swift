//
//  DataExtensions.swift
//  Open Scanner → Rescriva
//
//  Created by Slaven Radic on 2024-09-01.
//  Rescriva: what the app reads from a scan's pages and lines — pages and lines in order, text
//  previews and search, page images and thumbnails, what the data detector finds in a line — and
//  the library grid's reads that leave page rows (each holding a full page image) in the store.
//

import Foundation
import CoreData
import UIKit

extension Scan {
	
	public var capturesArray: [ScanCapture] {
	  let set = captures as? Set<ScanCapture> ?? []
	  return set.sorted {
		$0.order < $1.order
	  }
	}

	/// The first page's thumbnail (the first by `order`, as `capturesArray` sorts, that has one),
	/// for the library grid and sidebar. Read and decoded once per change to the scan
	/// (`CoverThumbnailCache`): a tile's body runs again on every change to its scan and as the
	/// grid scrolls, and `coverThumbnailData` is a store fetch each time.
	var coverThumbnail: UIImage? {
		CoverThumbnailCache.image(for: self)
	}

	/// The thumbnail bytes of the first page with a thumbnail, read straight from the store with
	/// nothing else of the page: a page's row holds its full image, so faulting pages in for their
	/// thumbnails (`capturesArray.first?.thumbnail`) pulled whole pages into memory for every card
	/// in the grid. A scan not yet saved has no rows to read; its pages are looked at directly.
	var coverThumbnailData: Data? {
		guard let context = managedObjectContext, !objectID.isTemporaryID else {
			return capturesArray.first { $0.thumbnailData != nil }?.thumbnailData
		}
		let request = NSFetchRequest<NSDictionary>(entityName: "ScanCapture")
		request.predicate = NSPredicate(format: "parent == %@ AND thumbnailData != nil", self)
		request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true),
								   NSSortDescriptor(key: "timestamp", ascending: true)]
		request.resultType = .dictionaryResultType
		request.propertiesToFetch = ["thumbnailData"]
		request.fetchLimit = 1
		do {
			return try context.fetch(request).first?["thumbnailData"] as? Data
		} catch {
			Log.library.error("Couldn't read a scan's first thumbnail: \(error)")
			return nil
		}
	}

	/// How many pages the scan has. Counting the relationship fetches the pages' ids, not their rows.
	var pageCount: Int {
		captures?.count ?? 0
	}
}

/// The decoded covers of recently shown scans, by object id, each good while the scan's
/// `lastUpdate` is what it was when the cover was read: every change to a scan's pages (added,
/// re-made, moved, removed, read) moves `lastUpdate`. Bounded, and emptied under memory pressure,
/// which only costs a read. A scan with no cover yet isn't cached, so its first thumbnail shows
/// as soon as it exists.
enum CoverThumbnailCache {
	private final class Entry {
		let lastUpdate: Date?
		let image: UIImage

		init(lastUpdate: Date?, image: UIImage) {
			self.lastUpdate = lastUpdate
			self.image = image
		}
	}

	/// NSCache is thread-safe, which is what `nonisolated(unsafe)` says here.
	nonisolated(unsafe) private static let entries: NSCache<NSManagedObjectID, Entry> = {
		let cache = NSCache<NSManagedObjectID, Entry>()
		cache.countLimit = 400
		return cache
	}()

	static func image(for scan: Scan) -> UIImage? {
		let id = scan.objectID
		guard !id.isTemporaryID else { return decode(scan) }
		if let entry = entries.object(forKey: id), entry.lastUpdate == scan.lastUpdate {
			return entry.image
		}
		guard let image = decode(scan) else { return nil }
		entries.setObject(Entry(lastUpdate: scan.lastUpdate, image: image), forKey: id)
		return image
	}

	private static func decode(_ scan: Scan) -> UIImage? {
		scan.coverThumbnailData.flatMap { UIImage(data: $0) }
	}
}

extension Scan {
	public var textPreview: String {
		var result = ""
		for capture in capturesArray {
			result = result.trimmingCharacters(in: .whitespaces) + " " + capture.textPreview
			if result.count > 200 {
				return result
			}
		}
		return result
	}
	
	public func containsText(_ text: String, testTitleOnly: Bool = false) -> Bool {

		if text == "" {
			return true
		}
		
		if let title = title {
			if title.localizedCaseInsensitiveContains(text) {
				return true
			}
		}

		if !testTitleOnly {
			for capture in capturesArray {
				if capture.containsText(text) {
					return true
				}
			}
		}
		return false
		
	}
}

extension ScanCapture {
	
	public var recognizedItemsArray: [ScanRecognizedItem] {
	  let set = recognizedItems as? Set<ScanRecognizedItem> ?? []
	  return set.sorted {
		($0.order, $0.timestamp ?? .distantPast) < ($1.order, $1.timestamp ?? .distantPast)
	  }
	}
	
	public var image: UIImage? {
		if let data = imageData {
			if let image = UIImage(data: data) {
				return image
			}
		}
		return nil
	}
	
	public var thumbnail: UIImage? {
		if let data = thumbnailData {
			if let image = UIImage(data: data) {
				return image
			}
		}
		return nil
	}
	
	public func createImage(fullSizedImage: UIImage) {
		imageData = Self.encodedPageImage(fullSizedImage)
	}
	
	public func createThumbnail(fullSizedImage: UIImage? = nil) {
		if let fullSizedImage = fullSizedImage {
			thumbnailData = Self.encodedThumbnail(fullSizedImage)
		} else if let image = image {
			thumbnailData = Self.encodedThumbnail(image)
		}
	}
	
	/// The stored page: a JPEG at most `maxWidth` px wide, 2400 unless a caller has reason to keep
	/// more (small images are never upsampled). Safe off the main thread, so re-processing can
	/// encode before touching Core Data.
	static func encodedPageImage(_ fullSizedImage: UIImage, maxWidth: CGFloat = 2400.0) -> Data? {
		let newWidth = min(maxWidth, fullSizedImage.size.width * fullSizedImage.scale)
		return fullSizedImage.resizeToWidth(newWidth).jpegData(compressionQuality: 0.75)
	}
	
	/// The stored thumbnail: a JPEG 360 px wide. Safe off the main thread.
	static func encodedThumbnail(_ fullSizedImage: UIImage) -> Data? {
		fullSizedImage.resizeToWidth(360.0).jpegData(compressionQuality: 0.75)
	}
	
	public var textPreview: String {
		var result = ""
		for item in recognizedItemsArray {
			if let text = item.transcript {
				result = result.trimmingCharacters(in: .whitespaces) + " " + text.replacingOccurrences(of: "\n", with: " ")
				if result.count > 200 {
					return result
				}
			}
		}
		return result
	}
	
	public func containsText(_ text: String) -> Bool {

		if text == "" {
			return true
		}
		for item in recognizedItemsArray {
			if let transcript = item.transcript {
				if transcript.localizedCaseInsensitiveContains(text) {
					return true
				}
			}
		}
		return false
	}
}

extension ScanRecognizedItem {
	
	var mailingAddress: String? {
		Self.detect(.address, in: transcript)
	}
	
	var phoneNumber: String? {
		Self.detect(.phoneNumber, in: transcript)
	}
	
	var urlAddress: String? {
		Self.detect(.link, in: transcript)
	}
	
	var emailAddress: String? {
		Self.detect(.link, in: transcript, email: true)
	}

	/// One detector for every line: it's immutable once made (an `NSRegularExpression`), so it can
	/// be shared. Nil only if the type mask were invalid, which a constant can't be.
	private static let detector: NSDataDetector? = {
		do {
			return try NSDataDetector(types: NSTextCheckingAllTypes)
		} catch {
			Log.app.error("Couldn't make the data detector: \(error)")
			return nil
		}
	}()

	/// The first thing of `checkingType` the data detector finds in `text`, as the exact characters
	/// it matched. The detector works in UTF-16 units, so its range is converted back with
	/// `Range(_:in:)`; counting Characters instead shifted a match that came after emoji or CJK
	/// text. For `.link`, `email` asks for an address (one with "@") or for a web link (without).
	static func detect(_ checkingType: NSTextCheckingResult.CheckingType, in text: String?, email: Bool = false) -> String? {
		guard let text, let detector else { return nil }
		let whole = NSRange(location: 0, length: text.utf16.count)
		for match in detector.matches(in: text, options: [], range: whole) where match.resultType == checkingType {
			guard let range = Range(match.range, in: text) else { continue }
			let matched = String(text[range])
			if checkingType == .link, matched.contains("@") != email { continue }
			return matched
		}
		return nil
	}
}
