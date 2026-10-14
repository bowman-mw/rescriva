//
//  AnnotationSession.swift
//  Rescriva (fork of Open Scanner)
//
//  The annotate screen's state: the tools, their colors and sizes, the marks
//  on every page being edited, and undo/redo. Nothing is written until Done.
//

import Foundation
import Observation
import SwiftUI
import UIKit

/// The annotate toolbar.
enum AnnotationTool: String, CaseIterable, Identifiable {
	case pen, highlighter, eraser, line, arrow, rectangle, ellipse

	var id: String { rawValue }

	var label: LocalizedStringKey {
		switch self {
		case .pen: return "Pen"
		case .highlighter: return "Highlighter"
		case .eraser: return "Eraser"
		case .line: return "Line"
		case .arrow: return "Arrow"
		case .rectangle: return "Rectangle"
		case .ellipse: return "Circle"
		}
	}

	var systemImage: String {
		switch self {
		case .pen: return "pencil"
		case .highlighter: return "highlighter"
		case .eraser: return "eraser"
		case .line: return "line.diagonal"
		case .arrow: return "arrow.up.right"
		case .rectangle: return "rectangle"
		case .ellipse: return "circle"
		}
	}

	/// The kind of mark the tool draws (nil for the eraser).
	var markKind: PageMark.Kind? {
		switch self {
		case .pen: return .pen
		case .highlighter: return .highlighter
		case .eraser: return nil
		case .line: return .line
		case .arrow: return .arrow
		case .rectangle: return .rectangle
		case .ellipse: return .ellipse
		}
	}

	/// Which remembered color and size the tool uses. Shapes share one.
	var styleGroup: MarkStyleGroup? {
		switch self {
		case .pen: return .pen
		case .highlighter: return .highlighter
		case .eraser: return nil
		case .line, .arrow, .rectangle, .ellipse: return .shape
		}
	}
}

/// Tools that share a color and size.
enum MarkStyleGroup: String, CaseIterable {
	case pen, highlighter, shape
}

/// A named color in the annotate palette.
struct MarkSwatch: Identifiable, Hashable {
	let rgb: UInt32
	let name: LocalizedStringResource

	var id: UInt32 { rgb }

	static func == (lhs: MarkSwatch, rhs: MarkSwatch) -> Bool { lhs.rgb == rhs.rgb }
	func hash(into hasher: inout Hasher) { hasher.combine(rgb) }
}

/// The colors and sizes on offer, and each group's starting choice.
enum MarkPalette {
	static let ink: [MarkSwatch] = [
		MarkSwatch(rgb: 0x1F1B16, name: "Black"),
		MarkSwatch(rgb: 0xD0392B, name: "Red"),
		MarkSwatch(rgb: 0x2463C9, name: "Blue"),
		MarkSwatch(rgb: 0x2E8B4E, name: "Green"),
		MarkSwatch(rgb: 0xE07B12, name: "Orange"),
		MarkSwatch(rgb: 0x7B4BC2, name: "Purple"),
	]

	static let highlighter: [MarkSwatch] = [
		MarkSwatch(rgb: 0xFFE14D, name: "Yellow"),
		MarkSwatch(rgb: 0x9DE882, name: "Green"),
		MarkSwatch(rgb: 0x8CD3FF, name: "Blue"),
		MarkSwatch(rgb: 0xFFA0CC, name: "Pink"),
		MarkSwatch(rgb: 0xFFBF73, name: "Orange"),
	]

	static let sizeNames: [LocalizedStringResource] = ["Fine", "Medium", "Bold"]

	static func swatches(for group: MarkStyleGroup) -> [MarkSwatch] {
		group == .highlighter ? highlighter : ink
	}

	/// Stroke widths as fractions of the page width (on a 612 pt PDF page:
	/// pens 1.5–4.9 pt, highlighters 8.6–19.6 pt).
	static func widths(for group: MarkStyleGroup) -> [Double] {
		group == .highlighter ? [0.014, 0.022, 0.032] : [0.0025, 0.0045, 0.008]
	}

	/// Pens start black, shapes red, the highlighter yellow; all medium.
	static func defaultStyle(for group: MarkStyleGroup) -> MarkStyle {
		MarkStyle(colorIndex: group == .shape ? 1 : 0, sizeIndex: 1)
	}
}

/// A tool group's chosen color and size (indexes into `MarkPalette`).
struct MarkStyle: Equatable {
	var colorIndex: Int
	var sizeIndex: Int
}

/// Undo and redo for one page: snapshots of its marks before each change.
struct MarkHistory: Equatable {
	static let limit = 200

	private(set) var undoStack: [[PageMark]] = []
	private(set) var redoStack: [[PageMark]] = []

	var canUndo: Bool { !undoStack.isEmpty }
	var canRedo: Bool { !redoStack.isEmpty }

	/// Remembers `before` as the state to undo back to; clears redo.
	mutating func record(_ before: [PageMark]) {
		undoStack.append(before)
		if undoStack.count > Self.limit {
			undoStack.removeFirst(undoStack.count - Self.limit)
		}
		redoStack.removeAll()
		assert(undoStack.count <= Self.limit, "Undo history stays bounded")
	}

	/// The marks to show after undoing from `current`, or nil when there's nothing to undo.
	mutating func undo(from current: [PageMark]) -> [PageMark]? {
		guard let previous = undoStack.popLast() else { return nil }
		redoStack.append(current)
		return previous
	}

	/// The marks to show after redoing from `current`, or nil when there's nothing to redo.
	mutating func redo(from current: [PageMark]) -> [PageMark]? {
		guard let next = redoStack.popLast() else { return nil }
		undoStack.append(current)
		return next
	}
}

/// The pages being annotated and everything done to them so far.
@MainActor
@Observable
final class AnnotationSession {
	/// A page to annotate: its id, a way to load its image as stored, and (for a scan with a look)
	/// a way to render it with the look off the main thread, shown once it's ready.
	struct Page: Identifiable {
		let id: UUID
		let loadImage: @MainActor () -> UIImage?
		var loadLooked: (@MainActor () async -> UIImage?)? = nil
	}

	let pages: [Page]
	private(set) var pageIndex: Int
	private(set) var marksByPage: [UUID: [PageMark]]
	private(set) var tool: AnnotationTool
	private(set) var styles: [MarkStyleGroup: MarkStyle]
	private var histories: [UUID: MarkHistory] = [:]

	@ObservationIgnored private let saved: [UUID: [PageMark]]
	@ObservationIgnored private let store: AnnotationStore
	@ObservationIgnored private let defaults: UserDefaults
	@ObservationIgnored private var imageCache: (id: UUID, image: UIImage?)?
	/// The current page with its scan's look, once rendered (`renderLook`).
	private var lookedImage: (id: UUID, image: UIImage)?

	/// `store` defaults to the shared one.
	init(pages: [Page], startingAt index: Int = 0, store: AnnotationStore? = nil, defaults: UserDefaults = .standard) {
		precondition(!pages.isEmpty, "Annotate needs at least one page")
		let store = store ?? .shared
		self.pages = pages
		self.store = store
		self.defaults = defaults
		pageIndex = min(max(index, 0), pages.count - 1)
		var loaded: [UUID: [PageMark]] = [:]
		for page in pages {
			loaded[page.id] = store.marks(for: page.id)
		}
		marksByPage = loaded
		saved = loaded
		tool = defaults.string(forKey: Keys.tool).flatMap(AnnotationTool.init(rawValue:)) ?? .pen
		var styles: [MarkStyleGroup: MarkStyle] = [:]
		for group in MarkStyleGroup.allCases {
			styles[group] = Self.loadStyle(for: group, from: defaults)
		}
		self.styles = styles
	}

	// MARK: Pages

	var currentPage: Page { pages[pageIndex] }

	var currentMarks: [PageMark] { marksByPage[currentPage.id] ?? [] }

	/// The current page's image: with its look once `renderLook` has made it, and as stored until
	/// then, decoded once per page visit.
	var currentImage: UIImage? {
		let page = currentPage
		if let lookedImage, lookedImage.id == page.id {
			return lookedImage.image
		}
		if let imageCache, imageCache.id == page.id {
			return imageCache.image
		}
		let image = page.loadImage()
		imageCache = (page.id, image)
		return image
	}

	/// Renders the current page with its scan's look, off the main thread, to show in place of the
	/// page as stored. Does nothing for a page without a look or one already rendered, and drops a
	/// render the user has paged away from.
	func renderLook() async {
		let page = currentPage
		guard lookedImage?.id != page.id, let load = page.loadLooked else { return }
		let image = await load()
		guard !Task.isCancelled, let image, currentPage.id == page.id else { return }
		lookedImage = (page.id, image)
		// The stored page is no longer shown; let its pixels go.
		imageCache = nil
	}

	var canGoBack: Bool { pageIndex > 0 }
	var canGoForward: Bool { pageIndex < pages.count - 1 }

	func showPage(_ index: Int) {
		guard pages.indices.contains(index), index != pageIndex else { return }
		pageIndex = index
	}

	// MARK: Editing

	var canUndo: Bool { histories[currentPage.id]?.canUndo ?? false }
	var canRedo: Bool { histories[currentPage.id]?.canRedo ?? false }

	/// Adds a finished mark to the current page.
	func add(_ mark: PageMark) {
		guard !mark.points.isEmpty else { return }
		change { $0.append(mark) }
	}

	/// Removes marks (one eraser stroke) from the current page as one undo step.
	func erase(_ ids: Set<UUID>) {
		guard !ids.isEmpty, currentMarks.contains(where: { ids.contains($0.id) }) else { return }
		change { $0.removeAll { ids.contains($0.id) } }
	}

	/// Removes every mark on the current page (undoable).
	func clearPage() {
		guard !currentMarks.isEmpty else { return }
		change { $0.removeAll() }
	}

	func undo() {
		let id = currentPage.id
		var history = histories[id] ?? MarkHistory()
		guard let marks = history.undo(from: currentMarks) else { return }
		histories[id] = history
		marksByPage[id] = marks
	}

	func redo() {
		let id = currentPage.id
		var history = histories[id] ?? MarkHistory()
		guard let marks = history.redo(from: currentMarks) else { return }
		histories[id] = history
		marksByPage[id] = marks
	}

	private func change(_ edit: (inout [PageMark]) -> Void) {
		let id = currentPage.id
		let before = currentMarks
		var after = before
		edit(&after)
		guard after != before else { return }
		var history = histories[id] ?? MarkHistory()
		history.record(before)
		histories[id] = history
		marksByPage[id] = after
	}

	// MARK: Saving

	/// True when any page differs from what's saved.
	var hasChanges: Bool {
		pages.contains { (marksByPage[$0.id] ?? []) != (saved[$0.id] ?? []) }
	}

	/// Writes every changed page.
	func save() throws {
		for page in pages {
			let marks = marksByPage[page.id] ?? []
			guard marks != (saved[page.id] ?? []) else { continue }
			try store.save(marks, for: page.id)
		}
	}
}

// MARK: - Tools and styles

extension AnnotationSession {
	func selectTool(_ newTool: AnnotationTool) {
		guard newTool != tool else { return }
		tool = newTool
		defaults.set(newTool.rawValue, forKey: Keys.tool)
	}

	/// The active tool's color and size choice (nil for the eraser).
	var currentStyle: MarkStyle? {
		guard let group = tool.styleGroup else { return nil }
		return styles[group] ?? MarkPalette.defaultStyle(for: group)
	}

	var currentSwatches: [MarkSwatch] {
		tool.styleGroup.map(MarkPalette.swatches(for:)) ?? []
	}

	func selectColor(_ index: Int) {
		guard let group = tool.styleGroup, MarkPalette.swatches(for: group).indices.contains(index) else { return }
		var style = styles[group] ?? MarkPalette.defaultStyle(for: group)
		style.colorIndex = index
		styles[group] = style
		defaults.set(index, forKey: Keys.color(group))
	}

	func selectSize(_ index: Int) {
		guard let group = tool.styleGroup, MarkPalette.widths(for: group).indices.contains(index) else { return }
		var style = styles[group] ?? MarkPalette.defaultStyle(for: group)
		style.sizeIndex = index
		styles[group] = style
		defaults.set(index, forKey: Keys.size(group))
	}

	/// What the canvas draws with right now.
	var brush: CanvasBrush {
		guard let group = tool.styleGroup, let style = currentStyle else {
			return CanvasBrush(tool: tool, color: 0, width: 0)
		}
		let swatches = MarkPalette.swatches(for: group)
		let widths = MarkPalette.widths(for: group)
		let color = swatches.indices.contains(style.colorIndex) ? swatches[style.colorIndex].rgb : 0
		let width = widths.indices.contains(style.sizeIndex) ? widths[style.sizeIndex] : widths[0]
		return CanvasBrush(tool: tool, color: color, width: width)
	}

	private static func loadStyle(for group: MarkStyleGroup, from defaults: UserDefaults) -> MarkStyle {
		var style = MarkPalette.defaultStyle(for: group)
		if let color = defaults.object(forKey: Keys.color(group)) as? Int,
		   MarkPalette.swatches(for: group).indices.contains(color) {
			style.colorIndex = color
		}
		if let size = defaults.object(forKey: Keys.size(group)) as? Int,
		   MarkPalette.widths(for: group).indices.contains(size) {
			style.sizeIndex = size
		}
		return style
	}

	private enum Keys {
		static let tool = "annotate.tool"
		static func color(_ group: MarkStyleGroup) -> String { "annotate.\(group.rawValue).color" }
		static func size(_ group: MarkStyleGroup) -> String { "annotate.\(group.rawValue).size" }
	}
}

extension Scan {
	/// The scan's pages, ready to annotate, with the scan's look applied as
	/// in the preview: rendered off the main thread (`LookPreviewRenderer`),
	/// the page as stored standing in until it's ready. Pages from before ids
	/// were assigned get one now, since their marks are saved under it.
	@MainActor
	func annotationPages() -> [AnnotationSession.Page] {
		var assigned = false
		let look = lookFilter
		let pages = capturesArray.map { capture -> AnnotationSession.Page in
			if capture.id == nil {
				capture.id = UUID()
				assigned = true
			}
			let id = capture.id ?? UUID()
			return AnnotationSession.Page(id: id, loadImage: { [weak capture] in capture?.image },
										  loadLooked: Scan.lookLoader(for: capture, look: look))
		}
		if assigned {
			managedObjectContext?.saveQuietly()
		}
		return pages
	}

	/// Renders `capture`'s page with `look` off the main thread, at its own size; nil for Original,
	/// which is the page as stored.
	@MainActor
	private static func lookLoader(for capture: ScanCapture, look: LookFilter) -> (@MainActor () async -> UIImage?)? {
		guard look != .original else { return nil }
		return { [weak capture] in
			guard let data = capture?.imageData else { return nil }
			return await LookPreviewRenderer.shared.page(look, of: data)
		}
	}
}
