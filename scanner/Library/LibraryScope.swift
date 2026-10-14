//
//  LibraryScope.swift
//  Rescriva (fork of Open Scanner)
//
//  What one library screen shows — All Scans, Pinned, Favorites, Recently
//  Deleted, a folder, a tag or a smart folder — and the fetch predicate for
//  each. A smart folder keeps its rule as JSON in `SmartFolder.ruleData`;
//  the JSON keys and the raw values inside are stored tokens.
//

import CoreData
import Foundation

/// One collection of scans in the library.
enum LibraryScope: Hashable {
	case all, pinned, favorites, recentlyDeleted
	case folder(UUID)
	case tag(UUID)
	case smart(UUID)
}

/// A smart folder's rule: scans matching every (or any) criterion it sets.
/// An empty rule matches every scan.
struct SmartRule: Codable, Hashable, Sendable {
	/// Stored token: whether every criterion must match, or any one.
	enum Match: String, Codable, Sendable {
		case all, any
	}

	var match: Match = .all
	/// Tags, by id: every one of them (`.all`) or any (`.any`).
	var tagIDs: [UUID] = []
	/// `OutputKind` raw values.
	var outputs: [String] = []
	/// `PageSource` raw values (`Scan.source`).
	var sources: [String] = []
	var favoritesOnly = false
	/// Scanned within this many days; nil for any time.
	var withinDays: Int?

	init(match: Match = .all, tagIDs: [UUID] = [], outputs: [String] = [], sources: [String] = [],
		 favoritesOnly: Bool = false, withinDays: Int? = nil) {
		self.match = match
		self.tagIDs = tagIDs
		self.outputs = outputs
		self.sources = sources
		self.favoritesOnly = favoritesOnly
		self.withinDays = withinDays
	}

	/// Tolerant decoding: a key this version doesn't know is ignored, and a missing one keeps its default.
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		match = try container.decodeIfPresent(Match.self, forKey: .match) ?? .all
		tagIDs = try container.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
		outputs = try container.decodeIfPresent([String].self, forKey: .outputs) ?? []
		sources = try container.decodeIfPresent([String].self, forKey: .sources) ?? []
		favoritesOnly = try container.decodeIfPresent(Bool.self, forKey: .favoritesOnly) ?? false
		withinDays = try container.decodeIfPresent(Int.self, forKey: .withinDays)
	}

	private enum CodingKeys: String, CodingKey {
		case match, tagIDs, outputs, sources, favoritesOnly, withinDays
	}

	/// Whether the rule sets any criterion.
	var isEmpty: Bool {
		tagIDs.isEmpty && outputs.isEmpty && sources.isEmpty && !favoritesOnly && withinDays == nil
	}

	/// The rule as a predicate on `Scan` (deleted scans are excluded by the caller).
	func predicate(now: Date) -> NSPredicate {
		var parts: [NSPredicate] = []
		if !tagIDs.isEmpty {
			switch match {
			case .all: parts.append(NSCompoundPredicate(andPredicateWithSubpredicates: tagIDs.map { NSPredicate(format: "ANY tags.id == %@", $0 as CVarArg) }))
			case .any: parts.append(NSPredicate(format: "ANY tags.id IN %@", tagIDs))
			}
		}
		if !outputs.isEmpty { parts.append(NSPredicate(format: "outputKind IN %@", outputs)) }
		if !sources.isEmpty { parts.append(NSPredicate(format: "source IN %@", sources)) }
		if favoritesOnly { parts.append(NSPredicate(format: "fave == YES")) }
		if let withinDays, withinDays > 0 {
			let start = now.addingTimeInterval(-Double(withinDays) * 86_400)
			parts.append(NSPredicate(format: "timestamp >= %@", start as NSDate))
		}
		guard !parts.isEmpty else { return NSPredicate(value: true) }
		return match == .all ? NSCompoundPredicate(andPredicateWithSubpredicates: parts)
			: NSCompoundPredicate(orPredicateWithSubpredicates: parts)
	}

	/// The rule as stored in `SmartFolder.ruleData`.
	var json: String {
		do {
			return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
		} catch {
			Log.library.error("Couldn't encode a smart folder rule: \(error)")
			return "{}"
		}
	}

	/// A stored rule, or an empty rule when there's none or it can't be read.
	static func decoded(_ json: String?) -> SmartRule {
		guard let json, !json.isEmpty else { return SmartRule() }
		do {
			return try JSONDecoder().decode(SmartRule.self, from: Data(json.utf8))
		} catch {
			Log.library.error("Couldn't read a smart folder rule: \(error)")
			return SmartRule()
		}
	}
}

extension LibraryScope {
	/// Scans that aren't in Recently Deleted. Made fresh each time: NSPredicate isn't Sendable, so
	/// it can't be one shared constant.
	static var livePredicate: NSPredicate { NSPredicate(format: "deletedAt == nil") }

	/// The predicate for every scope that doesn't need to look up a smart folder's rule.
	func basePredicate() -> NSPredicate {
		switch self {
		case .all, .smart:
			return Self.livePredicate
		case .pinned:
			return NSCompoundPredicate(andPredicateWithSubpredicates: [Self.livePredicate, NSPredicate(format: "pinned == YES")])
		case .favorites:
			return NSCompoundPredicate(andPredicateWithSubpredicates: [Self.livePredicate, NSPredicate(format: "fave == YES")])
		case .recentlyDeleted:
			return NSPredicate(format: "deletedAt != nil")
		case .folder(let id):
			return NSCompoundPredicate(andPredicateWithSubpredicates: [Self.livePredicate, NSPredicate(format: "folder.id == %@", id as CVarArg)])
		case .tag(let id):
			return NSCompoundPredicate(andPredicateWithSubpredicates: [Self.livePredicate, NSPredicate(format: "ANY tags.id == %@", id as CVarArg)])
		}
	}

	/// Whether a scan here lists its pinned scans in their own section first.
	var showsPinnedFirst: Bool {
		switch self {
		case .all, .favorites, .folder, .tag, .smart: return true
		case .pinned, .recentlyDeleted: return false
		}
	}
}

/// How a library screen orders its scans. Stored token (`@AppStorage`).
enum LibrarySort: String, CaseIterable {
	case edited, created, title

	var label: String {
		switch self {
		case .edited: return String(localized: "Date edited")
		case .created: return String(localized: "Date created")
		case .title: return String(localized: "Title")
		}
	}
}

/// Gallery sections: pinned scans first, then by date (Today, Yesterday,
/// Previous 7 Days, Previous 30 Days, then by month), or one section when
/// sorted by title.
enum LibraryGrouping {
	struct Section: Identifiable {
		let id: String
		let title: String
		let scans: [Scan]
	}

	@MainActor
	static func sections(_ scans: [Scan], sort: LibrarySort, pinnedFirst: Bool, now: Date, calendar: Calendar = .current) -> [Section] {
		let ordered = sorted(scans, by: sort)
		let pinned = pinnedFirst ? ordered.filter(\.pinned) : []
		let rest = pinnedFirst ? ordered.filter { !$0.pinned } : ordered
		var result: [Section] = pinned.isEmpty ? [] : [Section(id: "pinned", title: String(localized: "Pinned"), scans: pinned)]
		guard sort != .title else {
			if !rest.isEmpty { result.append(Section(id: "all", title: pinned.isEmpty ? "" : String(localized: "Scans"), scans: rest)) }
			return result
		}
		var buckets: [(key: String, scans: [Scan])] = []
		for scan in rest {
			let key = bucket(for: date(of: scan, sort: sort), now: now, calendar: calendar)
			if buckets.last?.key == key { buckets[buckets.count - 1].scans.append(scan) } else { buckets.append((key, [scan])) }
		}
		result += buckets.map { Section(id: $0.key, title: $0.key, scans: $0.scans) }
		return result
	}

	@MainActor
	static func sorted(_ scans: [Scan], by sort: LibrarySort) -> [Scan] {
		switch sort {
		case .title:
			return scans.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
		case .edited, .created:
			return scans.sorted { date(of: $0, sort: sort) > date(of: $1, sort: sort) }
		}
	}

	@MainActor
	static func date(of scan: Scan, sort: LibrarySort) -> Date {
		let created = scan.timestamp ?? .distantPast
		return sort == .edited ? (scan.lastUpdate ?? created) : created
	}

	/// The section title for a date.
	static func bucket(for date: Date, now: Date, calendar: Calendar) -> String {
		if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
		let startOfToday = calendar.startOfDay(for: now)
		let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
		if days == 1 { return String(localized: "Yesterday") }
		if days >= 0, days <= 7 { return String(localized: "Previous 7 Days") }
		if days >= 0, days <= 30 { return String(localized: "Previous 30 Days") }
		let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
		return date.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
	}
}
