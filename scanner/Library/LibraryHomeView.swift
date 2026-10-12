//
//  LibraryHomeView.swift
//  Rescriva (fork of Open Scanner)
//
//  The Library's home, laid out like Apple Notes' folder list: All Scans and
//  Favorites; smart folders; the folder tree (folders nest, and collapse with
//  their chevron); then PDF Files and Recently Deleted when there are any.
//  Pinned scans lead All Scans. Tags live in search (`TagFilterBar`). Each
//  row shows how many scans it holds. Long-press a folder or smart folder for
//  its own actions.
//

import CoreData
import SwiftUI

struct LibraryHomeView: View {
	@Environment(\.managedObjectContext) private var context
	@Environment(RescrivaRouter.self) private var router
	/// Fetched only so counts and rows refresh whenever the library changes.
	@FetchRequest(sortDescriptors: []) private var scans: FetchedResults<Scan>
	@FetchRequest(sortDescriptors: []) private var folders: FetchedResults<ScanFolder>

	@FetchRequest(sortDescriptors: [SortDescriptor(\SmartFolder.name)]) private var smartFolders: FetchedResults<SmartFolder>
	@State private var controller = LibraryController()
	@State private var collapsed: Set<UUID> = []

	var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			LibrarySection(title: nil) { libraryRows }
			if !smartFolders.isEmpty {
				LibrarySection(title: String(localized: "Smart Folders")) {
					ForEach(smartFolders, id: \.objectID) { smart in smartRow(smart) }
				}
			}
			LibrarySection(title: String(localized: "Folders"), trailing: AnyView(addMenu)) { folderRows }
			fileRows
		}
		.padding(.top, 14)
		.libraryPresentations(controller)
	}

	// MARK: Rows

	/// All Scans and Favorites. (Pinned scans lead All Scans, so they need no row of their own.)
	@ViewBuilder
	private var libraryRows: some View {
		let counts = liveCounts
		scopeRow(.all, count: counts.all)
		scopeRow(.favorites, count: counts.favorites)
	}

	/// Below the folders, when there are any: PDFs opened in Rescriva, which live as files beside the
	/// scans, and Recently Deleted.
	@ViewBuilder
	private var fileRows: some View {
		let pdfCount = PDFLibrary.shared.items.count
		let deleted = liveCounts.deleted
		if pdfCount > 0 || deleted > 0 {
			LibrarySection(title: nil) {
				if pdfCount > 0 {
					LibraryRowButton(symbol: PDFOpening.symbol, tint: PDFOpening.tint, title: String(localized: "PDF Files"), count: pdfCount) {
						router.push(.pdfFiles)
					}
				}
				if deleted > 0 { scopeRow(.recentlyDeleted, count: deleted) }
			}
		}
	}

	private func scopeRow(_ scope: LibraryScope, count: Int) -> some View {
		let look = ScopeAppearance.of(scope, in: context)
		return LibraryRowButton(symbol: look.symbol, tint: look.tint, title: look.title, count: count) {
			router.push(.collection(scope))
		}
	}

	private func smartRow(_ smart: SmartFolder) -> some View {
		LibraryRowButton(symbol: smart.symbolName, tint: smart.tint, title: smart.displayName,
						 count: smart.id.map { Library.count(for: .smart($0), in: context) } ?? 0) {
			if let id = smart.id { router.push(.collection(.smart(id))) }
		}
		.contextMenu {
			Button { controller.sheet = .editSmartFolder(smart) } label: { Label("Edit Smart Folder", systemImage: "slider.horizontal.3") }
			Button(role: .destructive) { withAnimation(RescrivaMotion.ui) { Library.delete(smart, in: context) } } label: {
				Label("Delete Smart Folder", systemImage: "trash")
			}
		}
	}

	@ViewBuilder
	private var folderRows: some View {
		let rows = Library.tree(in: context, collapsed: collapsed)
		if rows.isEmpty {
			Button {
				controller.sheet = .newFolder(parent: nil)
			} label: {
				FolderPickerRow(title: String(localized: "New Folder"), symbol: "folder.badge.plus", tint: .ink)
			}
			.buttonStyle(.plain)
		}
		ForEach(rows) { row in folderRow(row) }
	}

	private func folderRow(_ row: FolderRow) -> some View {
		let id = row.folder.id
		let isCollapsed = id.map { collapsed.contains($0) } ?? false
		return LibraryRowButton(symbol: row.folder.symbolName, tint: row.folder.tint, title: row.folder.displayName,
								count: folderCounts[row.folder.objectID] ?? 0, depth: row.depth,
								disclosure: row.hasChildren ? !isCollapsed : nil, onDisclosure: { toggleCollapse(id) }) {
			if let id { router.push(.collection(.folder(id))) }
		}
		.contextMenu { folderMenu(row.folder) }
	}

	@ViewBuilder
	private func folderMenu(_ folder: ScanFolder) -> some View {
		Button { controller.sheet = .newFolder(parent: folder) } label: { Label("New Folder Inside", systemImage: "folder.badge.plus") }
		Button { controller.sheet = .editFolder(folder) } label: { Label("Edit Folder", systemImage: "paintpalette") }
		Button { controller.sheet = .moveFolder(folder) } label: { Label("Move Folder…", systemImage: "arrow.turn.down.right") }
		Divider()
		Button(role: .destructive) { controller.folderToDelete = folder } label: { Label("Delete Folder", systemImage: "trash") }
	}

	private var addMenu: some View {
		Menu {
			Button { controller.sheet = .newFolder(parent: nil) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
			Button { controller.sheet = .newSmartFolder } label: { Label("New Smart Folder", systemImage: "gearshape") }
		} label: {
			Glyph("plus", size: 13, weight: .semibold)
				.foregroundStyle(.ink)
				.frame(width: 32, height: 32)
				.background(Color.vellum, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
				.rescrivaShadow(.small)
		}
		.accessibilityLabel(Text("New folder or smart folder"))
	}

	// MARK: Counts

	private var liveCounts: (all: Int, favorites: Int, deleted: Int) {
		let live = scans.filter { $0.deletedAt == nil }
		return (live.count, live.filter(\.fave).count, scans.count - live.count)
	}

	private var folderCounts: [NSManagedObjectID: Int] {
		var counts: [NSManagedObjectID: Int] = [:]
		for scan in scans where scan.deletedAt == nil {
			if let folder = scan.folder { counts[folder.objectID, default: 0] += 1 }
		}
		return counts
	}

	private func toggleCollapse(_ id: UUID?) {
		guard let id else { return }
		withAnimation(RescrivaMotion.ui) {
			if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
		}
	}
}

/// A titled group of rows on a flat vellum sheet, like an inset grouped list.
struct LibrarySection<Rows: View>: View {
	let title: String?
	var trailing: AnyView?
	@ViewBuilder let rows: Rows

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if title != nil || trailing != nil {
				HStack {
					if let title { Text(title).rescrivaSectionLabel().accessibilityAddTraits(.isHeader) }
					Spacer()
					trailing
				}
				.padding(.horizontal, 24)
			}
			VStack(spacing: 0) {
				rows
			}
			.paperCard(fold: 0)
			.padding(.horizontal, 16)
		}
	}
}

/// One library row: symbol, title, count and chevron, optionally indented
/// with a disclosure chevron for a folder that holds folders.
struct LibraryRowButton: View {
	let symbol: String
	let tint: Color
	let title: String
	let count: Int
	var depth = 0
	/// Expanded (true), collapsed (false), or no children (nil).
	var disclosure: Bool?
	var onDisclosure: () -> Void = {}
	let action: () -> Void

	var body: some View {
		HStack(spacing: 0) {
			disclosureButton
			Button(action: action) {
				HStack(spacing: 12) {
					Glyph(symbol, size: 18)
						.foregroundStyle(tint)
						.frame(width: 26)
					Text(title)
						.font(RescrivaFont.ui(16))
						.foregroundStyle(.carbon)
						.lineLimit(1)
					Spacer(minLength: 8)
					Text("\(count)")
						.font(RescrivaFont.ui(14))
						.foregroundStyle(.graphite)
						.monospacedDigit()
					Glyph("chevron.right", size: 11, weight: .semibold)
						.foregroundStyle(Color.carbon.opacity(0.3))
				}
				.padding(.vertical, 13)
				.padding(.trailing, 14)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel(Text("\(title), \(count)"))
		}
		.padding(.leading, 6 + CGFloat(depth) * 18)
	}

	@ViewBuilder
	private var disclosureButton: some View {
		if let disclosure {
			Button(action: onDisclosure) {
				Glyph("chevron.right", size: 10, weight: .semibold)
					.foregroundStyle(.graphite)
					.rotationEffect(.degrees(disclosure ? 90 : 0))
					.frame(width: 24, height: 44)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel(disclosure ? Text("Collapse \(title)") : Text("Expand \(title)"))
		} else {
			Color.clear.frame(width: 24, height: 1)
		}
	}
}

/// The tags, as chips under a search field while searching: tap one to show only the scans with
/// it (more than one narrows further), hold one to rename or delete it. Tags Rescriva adds by
/// itself (`AutoTags`) carry a small sparkle. Tags no scan carries any more come last, faded,
/// so they can still be renamed or deleted here.
struct TagFilterBar: View {
	@Environment(\.managedObjectContext) private var context
	@FetchRequest(sortDescriptors: [SortDescriptor(\ScanTag.name)]) private var tags: FetchedResults<ScanTag>
	@Binding var selection: Set<NSManagedObjectID>
	let controller: LibraryController
	var inset: CGFloat = 20

	var body: some View {
		let shown = tags.filter { liveCount($0) > 0 } + tags.filter { liveCount($0) == 0 }
		if !shown.isEmpty {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					ForEach(shown, id: \.objectID) { tag in chip(tag) }
				}
				.padding(.horizontal, inset)
				.padding(.vertical, 4)
			}
			// Scrolling the chips keeps the search field (and so this bar) up.
			.scrollDismissesKeyboard(.never)
			.transition(.opacity)
		}
	}

	private func chip(_ tag: ScanTag) -> some View {
		let isOn = selection.contains(tag.objectID)
		let automatic = AutoTags.isAutomatic(tag)
		let unused = liveCount(tag) == 0
		return Button {
			withAnimation(RescrivaMotion.fast) {
				if isOn { selection.remove(tag.objectID) } else { selection.insert(tag.objectID) }
			}
		} label: {
			HStack(spacing: 4) {
				if automatic {
					Image(systemName: "sparkle")
						.font(.system(size: 9, weight: .semibold))
						.accessibilityHidden(true)
				}
				Text(tag.displayName)
					.font(RescrivaFont.ui(13, weight: .medium))
				Text("\(liveCount(tag))")
					.font(RescrivaFont.ui(11))
					.foregroundStyle(isOn ? Color.vellum.opacity(0.75) : Color.graphite)
			}
			.foregroundStyle(isOn ? Color.vellum : Color.carbon)
			.padding(.vertical, 7)
			.padding(.horizontal, 11)
			.background(isOn ? Color.carbon : Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous)
					.strokeBorder(Color.carbon.opacity(isOn ? 0 : 0.14))
			}
			.opacity(unused && !isOn ? 0.55 : 1)
			.animation(RescrivaMotion.ui, value: isOn)
		}
		.buttonStyle(PressScaleStyle(scale: 0.95))
		.accessibilityAddTraits(isOn ? .isSelected : [])
		.accessibilityHint(hint(automatic: automatic, unused: unused))
		.contextMenu {
			Button { controller.beginRename(tag) } label: { Label("Rename Tag", systemImage: "pencil") }
			Button(role: .destructive) {
				selection.remove(tag.objectID)
				withAnimation(RescrivaMotion.ui) { Library.delete(tag, in: context) }
			} label: {
				Label("Delete Tag", systemImage: "trash")
			}
		}
	}

	private func hint(automatic: Bool, unused: Bool) -> Text {
		let what = unused ? Text("No scans have this tag.") : Text("Shows only scans with this tag.")
		return automatic ? Text("Added by Rescriva. ") + what : what
	}

	/// How many scans outside Recently Deleted carry `tag`.
	private func liveCount(_ tag: ScanTag) -> Int {
		(tag.scans as? Set<Scan>)?.filter { $0.deletedAt == nil }.count ?? 0
	}
}
