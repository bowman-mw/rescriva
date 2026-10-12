//
//  ScanModel.swift
//  Rescriva (fork of Open Scanner)
//
//  Rescriva's view of Open Scanner's Core Data entities: the output a scan is
//  headed for, its look, where it came from and its rebuilt document, plus
//  helpers to create scans from captured or imported images.
//
//  App-target only (the widget shares DataExtensions.swift, not this file).
//

import Foundation
import CoreData
import SwiftUI
import UIKit

/// What a scan becomes. Stored token on `Scan.outputKind`.
enum OutputKind: String, CaseIterable, Identifiable {
	case pdf, docx, pptx

	var id: String { rawValue }

	/// Library chip label.
	var chipLabel: String {
		switch self {
		case .pdf: return "PDF"
		case .docx: return String(localized: "Word")
		case .pptx: return String(localized: "Slides")
		}
	}

	var chipColor: Color {
		switch self {
		case .pdf: return Color.carbon.opacity(0.08)
		case .docx: return .wash
		case .pptx: return Color.highlighter.opacity(0.25)
		}
	}

	/// Placeholder ink for thumbnails without an image.
	var ink: Color {
		switch self {
		case .pdf: return .carbon
		case .docx: return .ink
		case .pptx: return .highlighter
		}
	}
}

/// The page filter chosen under "Look". Stored token on `Scan.look`: never rename the raw
/// values. B&W is a true black and white (Sauvola) and Ink the whiteboard filter (`PageLooks`).
enum LookFilter: String, CaseIterable, Identifiable {
	case color, gray, blackAndWhite = "bw", ink, original

	var id: String { rawValue }

	var label: LocalizedStringKey {
		switch self {
		case .color: return "Color"
		case .gray: return "Gray"
		case .blackAndWhite: return "B&W"
		case .ink: return "Ink"
		case .original: return "Original"
		}
	}
}

extension Scan {
	/// The chosen output; new scans default from their page shape.
	var output: OutputKind {
		get { OutputKind(rawValue: outputKind ?? "") ?? .pdf }
		set { outputKind = newValue.rawValue }
	}

	var lookFilter: LookFilter {
		get { LookFilter(rawValue: look ?? "") ?? .color }
		set { look = newValue.rawValue }
	}

	var pageSource: PageSource? {
		get { PageSource(rawValue: source ?? "") }
		set { source = newValue?.rawValue }
	}

	var displayTitle: String {
		guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
			return String(localized: "Untitled")
		}
		return title
	}

	/// The rebuilt document, decoded from `rebuiltData`.
	var rebuiltDocument: RescrivaDocument? {
		get {
			guard let rebuiltData else { return nil }
			return try? JSONDecoder.rescriva.decode(RescrivaDocument.self, from: rebuiltData)
		}
		set {
			rebuiltData = newValue.flatMap { try? JSONEncoder.rescriva.encode($0) }
		}
	}

	/// True once the scan has been rebuilt into Word or Slides.
	var isRebuilt: Bool { rebuiltData != nil && output != .pdf }

	/// The companion's read on the pages: what they look like and which output suits them.
	@MainActor var companionTip: String {
		if output == .pptx || (looksLikeSlides && pageSource != .whiteboard) {
			return String(localized: "These pages are wide — slides will keep the layout.")
		}
		let hasText = capturesArray.contains { !$0.recognizedItemsArray.isEmpty }
		let reading = capturesArray.contains { RecognitionTracker.shared.isReading($0) }
		if !hasText && !reading {
			return String(localized: "I couldn't find any words here — a PDF will keep it just as it looks.")
		}
		let hasDiagram = rebuiltDocument?.pages.flatMap(\.blocks).contains { if case .diagram = $0.content { return true }; return false } ?? false
		switch pageSource {
		case .handwritten:
			return hasDiagram ? String(localized: "Looks like handwritten notes with a little diagram. Word should suit them.")
				: String(localized: "Looks like handwritten notes. Word should suit them.")
		case .whiteboard:
			return String(localized: "A whiteboard — Word can keep the diagram editable and the marker colors.")
		case .typed:
			return String(localized: "Looks like a typed page. Word will keep the headings, lists and tables.")
		case nil:
			return String(localized: "Word will keep the headings, lists and tables — or keep it just as it looks with a PDF.")
		}
	}

	/// True when most pages are landscape, which suggests slides.
	var looksLikeSlides: Bool {
		let ratios = capturesArray.compactMap { $0.thumbnail?.aspectRatio }
		guard !ratios.isEmpty else { return false }
		return ratios.filter { $0 > 1.15 }.count * 2 > ratios.count
	}

	/// "4 pages · 2 hours ago".
	var libraryMeta: String {
		let count = capturesArray.count
		let pages = count == 1 ? String(localized: "1 page") : String(localized: "\(count) pages")
		return "\(pages) · \(RescrivaDates.relative(timestamp ?? Date()))"
	}

	/// "3 pages · Today at 9:14 · Handwritten".
	var detailMeta: String {
		let count = capturesArray.count
		var parts = [count == 1 ? String(localized: "1 page") : String(localized: "\(count) pages"),
					 RescrivaDates.dayAndTime(timestamp ?? Date())]
		if let source = pageSource {
			parts.append(source.displayName)
		}
		return parts.joined(separator: " · ")
	}

	/// Creates a scan from page images that have no original (a PDF, the
	/// sample library). See `create(from:title:source:in:output:suggestsTitle:)`.
	@MainActor
	@discardableResult
	static func create(from images: [UIImage], title: String, source: PageSource?, in context: NSManagedObjectContext, output: OutputKind? = nil, suggestsTitle: Bool = true) -> Scan {
		create(from: images.map { CapturedPage(image: $0) }, title: title, source: source, in: context, output: output, suggestsTitle: suggestsTitle)
	}

	/// Creates a scan from captured pages (camera or Photos) and starts
	/// recognizing their text. When `suggestsTitle`, the first line that reads
	/// like a title replaces `title` (unless the user renamed it meanwhile).
	@MainActor
	@discardableResult
	static func create(from pages: [CapturedPage], title: String, source: PageSource?, in context: NSManagedObjectContext, output: OutputKind? = nil, suggestsTitle: Bool = true) -> Scan {
		let scan = Scan(context: context)
		scan.id = UUID()
		scan.timestamp = Date()
		scan.lastUpdate = Date()
		scan.title = title
		scan.order = Int32(nextOrder(in: context))
		scan.pageSource = source
		LibraryPlacement.shared.place(scan, in: context)
		scan.append(pages, placeholderTitle: suggestsTitle ? title : nil, in: context)
		// The design starts captures on Word (Slides for wide pages) where the
		// phone can rebuild; callers pass `.pdf` for imported PDFs.
		if let output {
			scan.output = output
		} else {
			scan.output = DeviceTier.current.canRebuild ? (scan.looksLikeSlides ? .pptx : .docx) : .pdf
		}
		context.saveQuietly()
		return scan
	}

	/// Adds page images that have no original to the end of the scan.
	@MainActor
	func append(_ images: [UIImage], placeholderTitle: String? = nil, in context: NSManagedObjectContext) {
		append(images.map { CapturedPage(image: $0) }, placeholderTitle: placeholderTitle, in: context)
	}

	/// Adds pages to the end of the scan and recognizes their text. Each page
	/// keeps its recipe, and its staged original moves into `originals` (on
	/// this iPhone only) under the new capture's id before the scan is saved.
	@MainActor
	func append(_ pages: [CapturedPage], placeholderTitle: String? = nil, in context: NSManagedObjectContext,
				originals: OriginalStore = .shared) {
		guard !pages.isEmpty else { return }
		let start = capturesArray.count
		var created: [(ScanCapture, UIImage)] = []
		for (offset, page) in pages.enumerated() {
			// Per page: each page's full-size resize is autoreleased, and a
			// 54-page PDF piled them up to 1.7 GB before the loop ended.
			autoreleasepool {
				let capture = ScanCapture(context: context)
				let id = UUID()
				capture.id = id
				capture.timestamp = Date()
				capture.order = Int32(start + offset)
				capture.createImage(fullSizedImage: page.image)
				capture.createThumbnail(fullSizedImage: page.image)
				capture.recipe = page.recipe
				if let original = page.original {
					Self.keep(original, for: id, in: originals)
				}
				addToCaptures(capture)
				created.append((capture, page.image))
			}
		}
		lastUpdate = Date()
		context.saveQuietly()
		Task { await PageOCR.process(created, placeholderTitle: placeholderTitle) }
	}

	/// Moves a page's staged original into `OriginalStore` now, before the page is saved: a rename
	/// in the same folder tree, well under a millisecond. Left for later, a page saved while its
	/// original was still staged would lose it for good if the app were stopped first, as the
	/// launch sweep can't tell whose a staged file was.
	private static func keep(_ original: OriginalStore.Staged, for id: UUID, in store: OriginalStore) {
		do {
			try store.keep(original, for: id)
		} catch {
			print("Rescriva: couldn't keep a page's original: \(error)")
		}
	}

	/// Renumbers pages after a move or delete.
	func renumberPages() {
		for (index, capture) in capturesArray.enumerated() {
			capture.order = Int32(index)
		}
		lastUpdate = Date()
	}

	private static func nextOrder(in context: NSManagedObjectContext) -> Int {
		let request = Scan.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Scan.order, ascending: false)]
		request.fetchLimit = 1
		let top = (try? context.fetch(request))?.first
		return Int(top?.order ?? -1) + 1
	}
}

extension PageSource {
	var displayName: String {
		switch self {
		case .typed: return String(localized: "Typed")
		case .handwritten: return String(localized: "Handwritten")
		case .whiteboard: return String(localized: "Whiteboard")
		}
	}
}

extension JSONEncoder {
	/// Stable encoding for persisted documents (dates as exact reference-date seconds).
	static var rescriva: JSONEncoder {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		return encoder
	}
}

extension JSONDecoder {
	static var rescriva: JSONDecoder {
		JSONDecoder()
	}
}

/// Date phrases in the design's voice.
enum RescrivaDates {
	/// "2 hours ago", "Yesterday", "Tuesday", "Sep 28".
	static func relative(_ date: Date, now: Date = Date()) -> String {
		let calendar = Calendar.current
		if calendar.isDateInToday(date) {
			if now.timeIntervalSince(date) < 60 { return String(localized: "Just now") }
			let formatter = RelativeDateTimeFormatter()
			formatter.unitsStyle = .full
			return formatter.localizedString(for: date, relativeTo: now)
		}
		if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
		if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
			return date.formatted(.dateTime.weekday(.wide))
		}
		return date.formatted(.dateTime.month(.abbreviated).day())
	}

	/// "Today at 9:14", "Sep 28 at 9:14".
	static func dayAndTime(_ date: Date) -> String {
		let calendar = Calendar.current
		let time = date.formatted(date: .omitted, time: .shortened)
		if calendar.isDateInToday(date) { return String(localized: "Today at \(time)") }
		if calendar.isDateInYesterday(date) { return String(localized: "Yesterday at \(time)") }
		return String(localized: "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)")
	}

	/// "Scan, Oct 10" / "Whiteboard, Oct 10".
	static func defaultTitle(for kind: CaptureKind, on date: Date = Date()) -> String {
		let day = date.formatted(.dateTime.month(.abbreviated).day())
		switch kind {
		case .document: return String(localized: "Scan, \(day)")
		case .whiteboard: return String(localized: "Whiteboard, \(day)")
		}
	}
}
