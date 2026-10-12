//
//  SmartFolderEditor.swift
//  Rescriva (fork of Open Scanner)
//
//  New or edit smart folder: a name, a look, and the rule that fills it —
//  tags, what the scan was made into, where it came from, favorites, how
//  recent — matching all of them or any one. A live count shows how many
//  scans match as the rule changes.
//

import CoreData
import SwiftUI

struct SmartFolderEditorSheet: View {
	@Environment(\.managedObjectContext) private var context
	@Environment(\.dismiss) private var dismiss
	@FetchRequest(sortDescriptors: [SortDescriptor(\ScanTag.name)]) private var tags: FetchedResults<ScanTag>
	let smart: SmartFolder?
	@State private var name: String
	@State private var color: FolderColor
	@State private var symbol: String
	@State private var rule: SmartRule
	@State private var showsStyle = false

	/// "Scanned within" choices, in days (nil: any time).
	private static let recencyChoices: [Int?] = [nil, 7, 30, 90]

	init(smart: SmartFolder?) {
		self.smart = smart
		_name = State(initialValue: smart?.name ?? "")
		_color = State(initialValue: FolderColor.token(smart?.colorToken))
		_symbol = State(initialValue: smart?.symbolName ?? FolderSymbol.smartDefault)
		_rule = State(initialValue: SmartRule.decoded(smart?.ruleData))
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SheetHeader(title: smart == nil ? String(localized: "New Smart Folder") : String(localized: "Edit Smart Folder"),
						subtitle: matchSummary, trailing: (String(localized: "Cancel"), { dismiss() }))
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					nameRow
					if showsStyle { FolderStylePicker(color: $color, symbol: $symbol) }
					RescrivaSegmentedPicker(options: [SmartRule.Match.all, .any], selection: $rule.match) { match in
						match == .all ? "Match all" : "Match any"
					}
					criteria
				}
				.padding(.bottom, 8)
			}
			PrimaryButton(title: smart == nil ? "Create Smart Folder" : "Save", height: 50) { save() }
		}
		.padding(20)
		.presentationDetents([.large])
	}

	private var nameRow: some View {
		HStack(spacing: 12) {
			Button {
				withAnimation(RescrivaMotion.ui) { showsStyle.toggle() }
			} label: {
				Glyph(symbol, size: 22)
					.foregroundStyle(color.color)
					.frame(width: 44, height: 44)
					.background(color.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			}
			.buttonStyle(PressScaleStyle())
			.accessibilityLabel(Text("Colour and symbol"))
			TextField("Smart folder name", text: $name)
				.font(RescrivaFont.ui(17))
		}
		.padding(12)
		.background(Color.stock, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
	}

	private var criteria: some View {
		VStack(alignment: .leading, spacing: 14) {
			if !tags.isEmpty {
				Text("Tags").rescrivaSectionLabel()
				ChipFlow(spacing: 8) {
					ForEach(tags, id: \.objectID) { tag in
						if let id = tag.id {
							ChoiceChip(label: LocalizedStringKey(tag.displayName), isSelected: rule.tagIDs.contains(id)) { toggle(&rule.tagIDs, id) }
						}
					}
				}
			}
			Text("Made into").rescrivaSectionLabel()
			ChipFlow(spacing: 8) {
				ForEach(OutputKind.allCases) { kind in
					ChoiceChip(label: LocalizedStringKey(kind.chipLabel), isSelected: rule.outputs.contains(kind.rawValue)) { toggle(&rule.outputs, kind.rawValue) }
				}
			}
			Text("Scanned from").rescrivaSectionLabel()
			ChipFlow(spacing: 8) {
				ForEach([PageSource.typed, .handwritten, .whiteboard], id: \.self) { source in
					ChoiceChip(label: LocalizedStringKey(source.displayName), isSelected: rule.sources.contains(source.rawValue)) { toggle(&rule.sources, source.rawValue) }
				}
			}
			Text("Scanned").rescrivaSectionLabel()
			ChipFlow(spacing: 8) {
				ForEach(Self.recencyChoices, id: \.self) { days in
					ChoiceChip(label: recencyLabel(days), isSelected: rule.withinDays == days) { rule.withinDays = days }
				}
			}
			Toggle(isOn: $rule.favoritesOnly) {
				Text("Favorites only").font(RescrivaFont.ui(15, weight: .medium)).foregroundStyle(.carbon)
			}
			.toggleStyle(RescrivaToggleStyle())
		}
	}

	private func recencyLabel(_ days: Int?) -> LocalizedStringKey {
		guard let days else { return "Any time" }
		return "Last \(days) days"
	}

	private func toggle<Value: Equatable>(_ list: inout [Value], _ value: Value) {
		if let index = list.firstIndex(of: value) { list.remove(at: index) } else { list.append(value) }
	}

	/// "12 scans match" — counted live from the rule being edited.
	private var matchSummary: String {
		let request = Scan.fetchRequest()
		request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [LibraryScope.livePredicate, rule.predicate(now: Date())])
		let count: Int
		do {
			count = try context.count(for: request)
		} catch {
			print("Rescriva: smart folder preview count failed: \(error)")
			count = 0
		}
		return count == 1 ? String(localized: "1 scan matches") : String(localized: "\(count) scans match")
	}

	private func save() {
		if let smart {
			Library.update(smart, name: name, symbol: symbol, color: color, rule: rule, in: context)
		} else {
			Library.createSmartFolder(named: name, symbol: symbol, color: color, rule: rule, in: context)
		}
		dismiss()
	}
}

/// Lays chips out in rows, wrapping to the next row when one is full.
struct ChipFlow: Layout {
	var spacing: CGFloat = 8

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? .infinity
		let rows = arrange(subviews, width: width)
		let height = rows.last.map { $0.y + $0.height } ?? 0
		return CGSize(width: width.isFinite ? width : rows.map(\.width).max() ?? 0, height: height)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		let rows = arrange(subviews, width: bounds.width)
		for row in rows {
			var x = bounds.minX
			for index in row.indices {
				let size = subviews[index].sizeThatFits(.unspecified)
				subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
				x += size.width + spacing
			}
		}
	}

	/// Rows of subview indices with their top, height and width.
	private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], y: CGFloat, height: CGFloat, width: CGFloat)] {
		var rows: [(indices: [Int], y: CGFloat, height: CGFloat, width: CGFloat)] = []
		var current: [Int] = []
		var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
		for index in subviews.indices {
			let size = subviews[index].sizeThatFits(.unspecified)
			if !current.isEmpty, x + size.width > width {
				rows.append((current, y, rowHeight, x - spacing))
				y += rowHeight + spacing
				current = []
				x = 0
				rowHeight = 0
			}
			current.append(index)
			x += size.width + spacing
			rowHeight = max(rowHeight, size.height)
		}
		if !current.isEmpty { rows.append((current, y, rowHeight, x - spacing)) }
		return rows
	}
}
