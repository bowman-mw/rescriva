//
//  RescrivaDocument.swift
//  Rescriva (fork of Open Scanner)
//
//  The intermediate representation (IR) from the Scan-to-Doc plan: every
//  understanding tier and every review edit writes into one RescrivaDocument, and
//  every renderer (Word, PowerPoint, plain text, Markdown) only reads it.
//
//  Foundation-only on purpose, so the renderers stay testable off-device.
//  Persisted as JSON on `Scan.rebuiltData`; the raw values below are stored
//  tokens and must never be renamed or localized.
//

import Foundation

/// A rebuilt document: an ordered list of pages, each an ordered list of blocks.
struct RescrivaDocument: Codable, Hashable, Sendable {
	/// The schema version this build writes, and the newest it reads (`decodeStored`). Bump it
	/// with any change an older build couldn't decode or would misread.
	static let currentVersion = 1

	/// Schema version of the JSON encoding.
	var version: Int = RescrivaDocument.currentVersion
	var title: String
	var pages: [RescrivaPage]
	/// The scan pages (Open Scanner capture IDs, in order) this document was
	/// rebuilt from; a mismatch means the pages changed and it needs rebuilding.
	var sourceCaptureIDs: [UUID]? = nil
	/// Capture IDs of pages re-made since the rebuild (PageReprocessor). Rebuilder rebuilds just
	/// those pages and splices them in (`PageSplice`); nil when every page is current.
	var staleCaptureIDs: [UUID]? = nil

	/// True while a re-made page waits to be rebuilt.
	var hasStalePages: Bool {
		!(staleCaptureIDs ?? []).isEmpty
	}

	/// Every unresolved flag in reading order (word flags first within a block,
	/// then diagram edge flags), as `(pageIndex, blockID, flag)`.
	var openFlags: [(page: Int, block: UUID, flag: RescrivaFlag)] {
		var result: [(page: Int, block: UUID, flag: RescrivaFlag)] = []
		for (pageIndex, page) in pages.enumerated() {
			for block in page.blocks {
				for flag in block.content.flags where flag.resolution == nil {
					result.append((pageIndex, block.id, flag))
				}
			}
		}
		return result
	}
}

/// What a scan's stored document (`Scan.rebuiltData`) holds, as this build reads it.
enum RebuiltDocumentState: Equatable, Sendable {
	/// No rebuilt document.
	case missing
	/// The document, decoded.
	case document(RescrivaDocument)
	/// A document written by a newer Rescriva (schema `version`, above `currentVersion`). It is
	/// kept as it is for that version and never rebuilt over; this build has no document to show.
	case needsNewerApp(version: Int)
	/// JSON this build should read but couldn't; a rebuild replaces it.
	case unreadable

	/// The document, when there is one this build can read.
	var document: RescrivaDocument? {
		if case .document(let document) = self { return document }
		return nil
	}

	/// True for a document only a newer Rescriva can read.
	var needsNewerApp: Bool {
		if case .needsNewerApp = self { return true }
		return false
	}
}

extension RescrivaDocument {
	/// Decodes a stored document. One a newer Rescriva wrote (its `version` above
	/// `currentVersion`) is reported as such whether or not the rest of it still decodes, so the
	/// caller keeps it for that version. Anything else that fails to decode is logged and reported
	/// unreadable. Never returns `.missing`.
	static func decodeStored(_ data: Data) -> RebuiltDocumentState {
		do {
			let document = try JSONDecoder.rescriva.decode(RescrivaDocument.self, from: data)
			guard document.version <= currentVersion else { return .needsNewerApp(version: document.version) }
			return .document(document)
		} catch {
			if let version = storedVersion(of: data), version > currentVersion {
				return .needsNewerApp(version: version)
			}
			Log.rebuild.error("Couldn't decode a stored document (\(data.count) bytes): \(error)")
			return .unreadable
		}
	}

	/// The `version` stamped on stored JSON, read on its own when the whole document won't decode.
	private static func storedVersion(of data: Data) -> Int? {
		struct Stamp: Decodable {
			var version: Int?
		}
		return (try? JSONDecoder.rescriva.decode(Stamp.self, from: data))?.version
	}
}

/// One scanned page (one slide when rendered to PowerPoint).
struct RescrivaPage: Codable, Hashable, Sendable, Identifiable {
	var id: UUID = UUID()
	/// Where the page came from; drives heuristics and the review copy.
	var source: PageSource = .typed
	/// Physical page size in points (width × height). Landscape near 16:9 or
	/// 4:3 suggests slides.
	var size: PageSize = .letter
	/// Paper or slide colour sampled from the page edge (the slide fill in
	/// PowerPoint); nil when unsampled or no colour clearly owns the edge.
	var background: RGBColor?
	/// Up to 5 sampled accent colours, used as theme colours in PowerPoint;
	/// empty for black-on-white pages (the renderer falls back to defaults).
	var palette: [RGBColor] = []
	var blocks: [RescrivaBlock] = []
	/// Notes attached to the whole page (speaker notes in PowerPoint).
	var notes: [RescrivaNote] = []
	/// Fingerprint of the OCR lines the page was rebuilt from (`TextLayerReconciler.digest`). The
	/// PDF's text layer takes the rebuilt words only while the lines still match it; nil in
	/// documents rebuilt before it was kept.
	var sourceTextDigest: String?
}

/// Stored token: where a page came from.
enum PageSource: String, Codable, Hashable, Sendable {
	case typed, handwritten, whiteboard
}

/// Page size in points.
struct PageSize: Codable, Hashable, Sendable {
	var width: Double
	var height: Double

	static let letter = PageSize(width: 612, height: 792)
	static let a4 = PageSize(width: 595, height: 842)
	static let widescreen = PageSize(width: 960, height: 540)

	var isLandscape: Bool { width > height }
}

/// A rectangle in normalized page coordinates (0–1), origin at the top-left.
struct NormalizedBox: Codable, Hashable, Sendable {
	var x: Double
	var y: Double
	var width: Double
	var height: Double
}

/// An sRGB colour, components 0–1.
struct RGBColor: Codable, Hashable, Sendable {
	var red: Double
	var green: Double
	var blue: Double

	/// `RRGGBB`, upper case, no `#` — the form OOXML wants.
	var hex: String {
		func byte(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
		return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
	}

	init(red: Double, green: Double, blue: Double) {
		self.red = red
		self.green = green
		self.blue = blue
	}

	/// `0xRRGGBB`.
	init(hex: UInt32) {
		self.red = Double((hex >> 16) & 0xff) / 255
		self.green = Double((hex >> 8) & 0xff) / 255
		self.blue = Double(hex & 0xff) / 255
	}
}

/// Stored token: the three font classes the plan recovers (no font names).
enum FontClass: String, Codable, Hashable, Sendable {
	case serif, sans, mono
}

/// Which engine produced a block, how sure it was, and what else it considered.
struct Provenance: Codable, Hashable, Sendable {
	/// Stored token, e.g. `vision`, `heuristics`, `foundationModels`, `user`.
	var engine: String
	var confidence: Double
}

/// One block on a page.
struct RescrivaBlock: Codable, Hashable, Sendable, Identifiable {
	var id: UUID = UUID()
	var content: BlockContent
	/// Where the block sits on the scanned page; nil for blocks the user added.
	var box: NormalizedBox?
	var fontClass: FontClass?
	var provenance: Provenance?
	/// Notes anchored to this block (Word comments / PowerPoint comments).
	var notes: [RescrivaNote] = []
}

/// What a block is. Every case maps to a native construct in each renderer
/// (see the plan's IR table).
enum BlockContent: Codable, Hashable, Sendable {
	/// Level 1–4.
	case heading(level: Int, runs: [RescrivaRun])
	case paragraph(runs: [RescrivaRun], alignment: TextAlignment)
	case list(style: ListStyle, items: [ListItem])
	/// Rows of cells; spans let a cell cover more than one grid slot.
	case table(rows: [[TableCell]])
	/// `latex` is the source of truth; `linear` is a plain-text fallback such as
	/// `v = Vmax[S] / (Km + [S])`.
	case equation(latex: String, linear: String, display: Bool)
	/// `assetID` keys into the renderer's asset dictionary (JPEG/PNG data). For a detected figure
	/// (FigurePlacement), `caption` is the caption line from the page and `altText` the words read
	/// inside the picture; both were page text.
	case figure(assetID: String?, caption: String?, altText: String?)
	case diagram(Diagram)

	/// Flags carried by this block (word flags in runs, then edge flags).
	var flags: [RescrivaFlag] {
		switch self {
		case .heading(_, let runs), .paragraph(let runs, _):
			return runs.compactMap(\.flag)
		case .list(_, let items):
			return items.flatMap { $0.runs.compactMap(\.flag) }
		case .table(let rows):
			return rows.flatMap { $0.flatMap { $0.runs.compactMap(\.flag) } }
		case .diagram(let diagram):
			return diagram.edges.compactMap(\.flag)
		case .equation, .figure:
			return []
		}
	}

	/// Plain text of the block, for search, previews and the text renderer.
	var plainText: String {
		switch self {
		case .heading(_, let runs), .paragraph(let runs, _):
			return runs.plainText
		case .list(let style, let items):
			return items.enumerated().map { index, item in
				style.marker(index: index, checked: item.checked) + item.runs.plainText
			}.joined(separator: "\n")
		case .table(let rows):
			return rows.map { $0.map(\.runs.plainText).joined(separator: "\t") }.joined(separator: "\n")
		case .equation(_, let linear, _):
			return linear
		case .figure(_, let caption, let altText):
			return caption ?? altText ?? ""
		case .diagram(let diagram):
			return diagram.edges.compactMap { edge -> String? in
				guard let from = diagram.node(edge.from), let to = diagram.node(edge.to) else { return nil }
				return "\(from.label) \(edge.direction.textConnector) \(to.label)"
			}.joined(separator: "\n")
		}
	}
}

/// Stored token.
enum TextAlignment: String, Codable, Hashable, Sendable {
	case leading, center, trailing, justified
}

/// Stored token.
enum ListStyle: String, Codable, Hashable, Sendable {
	case bullet, ordered, checkbox

	/// Plain-text marker for an item.
	func marker(index: Int, checked: Bool?) -> String {
		switch self {
		case .bullet: return "• "
		case .ordered: return "\(index + 1). "
		case .checkbox: return checked == true ? "☑ " : "☐ "
		}
	}
}

struct ListItem: Codable, Hashable, Sendable, Identifiable {
	var id: UUID = UUID()
	var runs: [RescrivaRun]
	/// Only meaningful for `.checkbox` lists.
	var checked: Bool?
	/// Nesting depth, 0 for top level.
	var level: Int = 0
}

struct TableCell: Codable, Hashable, Sendable {
	var runs: [RescrivaRun]
	var rowSpan: Int = 1
	var columnSpan: Int = 1
}

/// A styled stretch of text. Styling survives every edit and export.
struct RescrivaRun: Codable, Hashable, Sendable, Identifiable {
	var id: UUID = UUID()
	var text: String
	var bold: Bool = false
	var italic: Bool = false
	var underline: Bool = false
	var strikethrough: Bool = false
	var color: RGBColor?
	var highlight: RGBColor?
	/// Set when recognition wasn't sure about this run; the run's `text` is
	/// what was read until the flag is resolved.
	var flag: RescrivaFlag?
}

extension Array where Element == RescrivaRun {
	var plainText: String { map(\.text).joined() }
}

/// A spot the review screen asks the user to confirm.
struct RescrivaFlag: Codable, Hashable, Sendable, Identifiable {
	var id: UUID = UUID()
	var kind: Kind
	/// Sheet title, e.g. "Did you mean…".
	var title: String
	/// Sheet subtitle, e.g. "Vision wasn't sure about this word".
	var detail: String
	/// What was read, shown large in the sheet's crop.
	var read: String
	/// Choices, most likely first. The last word-flag option is conventionally
	/// "keep as read".
	var options: [Option]
	/// The chosen option label once resolved; nil while open. Resolving a word
	/// flag also writes the chosen text into the run's `text`, which is what
	/// every renderer prints.
	var resolution: String?

	/// Stored token.
	enum Kind: String, Codable, Hashable, Sendable {
		case word, edge
	}

	struct Option: Codable, Hashable, Sendable {
		var label: String
		var note: String = ""
		/// For edge flags: what choosing this option does to the edge.
		var edgeAction: EdgeAction? = nil
	}

	/// Stored token: how an edge-flag option changes its edge.
	enum EdgeAction: String, Codable, Hashable, Sendable {
		/// An arrow from `from` to `to` (sets the direction to `.forward`).
		case keep
		/// An arrow from `to` to `from` (swaps the ends, direction `.forward`).
		case reverse
		/// A plain line with no arrowheads (direction `.none`).
		case plain
		/// An arrow both ways (direction `.both`).
		case both
		/// Not part of the diagram: remove the edge.
		case remove
	}
}

/// A note on a block, a word range or a page. Exports as a Word comment,
/// a PowerPoint comment or speaker note, or a PDF annotation.
struct RescrivaNote: Codable, Hashable, Sendable, Identifiable {
	var id: UUID = UUID()
	var text: String
	var created: Date
	/// Optional run the note is anchored to (word range); nil for the whole block.
	var runID: UUID?
}

/// A diagram as a graph: nodes and edges. Renderers pick native shapes and
/// connectors where the format allows.
struct Diagram: Codable, Hashable, Sendable {
	var nodes: [Node]
	var edges: [Edge]
	var layout: Layout = .cleanedUp
	var caption: String?
	/// Aspect ratio (width / height) of the diagram's frame; node boxes are
	/// normalized within that frame.
	var aspect: Double = 296.0 / 170.0

	func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

	/// Stored token.
	enum Layout: String, Codable, Hashable, Sendable {
		case faithful, cleanedUp, snap
	}

	struct Node: Codable, Hashable, Sendable, Identifiable {
		var id: String
		var label: String
		var shape: Shape
		/// Normalized within the diagram frame (0–1, top-left origin).
		var box: NormalizedBox
		var stroke: RGBColor
		var fill: RGBColor?
	}

	/// Stored token.
	enum Shape: String, Codable, Hashable, Sendable {
		case rectangle, roundedRectangle, ellipse, diamond, parallelogram
	}

	/// Which ends of an edge carry arrowheads. Stored token.
	enum Direction: String, Codable, Hashable, Sendable {
		/// An arrow from `from` to `to`.
		case forward
		/// A plain line.
		case none
		/// A double-headed arrow.
		case both
	}

	struct Edge: Codable, Hashable, Sendable, Identifiable {
		var id: String
		var from: String
		var to: String
		var label: String?
		/// Set while the arrow's direction or existence is uncertain.
		var flag: RescrivaFlag?
		/// Arrowheads. Documents saved before this field existed decode as `.forward`.
		var direction: Direction = .forward

		private enum CodingKeys: String, CodingKey {
			case id, from, to, label, flag, direction
		}
	}
}

extension Diagram.Edge {
	/// Decodes `direction` when present; older documents have only forward arrows.
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		from = try container.decode(String.self, forKey: .from)
		to = try container.decode(String.self, forKey: .to)
		label = try container.decodeIfPresent(String.self, forKey: .label)
		flag = try container.decodeIfPresent(RescrivaFlag.self, forKey: .flag)
		direction = try container.decodeIfPresent(Diagram.Direction.self, forKey: .direction) ?? .forward
	}
}

extension Diagram.Direction {
	/// The connector between two labels in plain text: →, — or ↔.
	var textConnector: String {
		switch self {
		case .forward: return "→"
		case .none: return "—"
		case .both: return "↔"
		}
	}
}

/// Options shared by every renderer.
struct RenderOptions: Sendable {
	/// Include notes (Word comments, PowerPoint comments/speaker notes,
	/// text appendix).
	var includeNotes: Bool = true
	/// Figure image data (JPEG or PNG) keyed by `BlockContent.figure.assetID`.
	var assets: [String: Data] = [:]
	/// Author name written on comments.
	var author: String = "Rescriva"
}
