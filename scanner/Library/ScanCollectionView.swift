//
//  ScanCollectionView.swift
//  Rescriva (fork of Open Scanner)
//
//  One library collection — a folder, a tag, a smart folder, Pinned, All
//  Scans, Favorites or Recently Deleted — as a gallery grid. A folder shows
//  its subfolders above the grid. Select picks several scans to move, tag,
//  pin or delete together (recover or delete for good in Recently
//  Deleted). The menu sorts the grid and edits the folder or smart folder.
//  Scanning from inside a folder files the new scan there.
//

import CoreData
import SwiftUI

struct ScanCollectionView: View {
	@Environment(\.managedObjectContext) private var context
	@Environment(RescrivaRouter.self) private var router
	@FetchRequest(sortDescriptors: [SortDescriptor(\Scan.timestamp, order: .reverse)]) private var allScans: FetchedResults<Scan>
	@FetchRequest(sortDescriptors: []) private var folders: FetchedResults<ScanFolder>
	@AppStorage("librarySort") private var sortToken = LibrarySort.edited.rawValue
	@State private var controller = LibraryController()
	@State private var selecting = false
	@State private var selection: Set<NSManagedObjectID> = []
	let scope: LibraryScope

	var body: some View {
		ZStack(alignment: .bottom) {
			GrainBackground()
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					topBar
					header
					if case .folder = scope { subfolders }
					content
				}
				.padding(.bottom, 140)
			}
			.overlay(alignment: .top) { StatusBarScrim() }
			if selecting {
				selectionBar
			} else if case .folder = scope {
				scanButton
			}
		}
		.libraryPresentations(controller)
		.onAppear { controller.onFinished = { endSelecting() } }
	}

	// MARK: Data

	private var scans: [Scan] {
		let predicate = Library.predicate(for: scope, in: context)
		return allScans.filter { predicate.evaluate(with: $0) }
	}

	private var sort: LibrarySort { LibrarySort(rawValue: sortToken) ?? .edited }

	private var look: ScopeAppearance { ScopeAppearance.of(scope, in: context) }

	private var folder: ScanFolder? {
		guard case .folder(let id) = scope else { return nil }
		return Library.folder(id, in: context)
	}

	private var selectedScans: [Scan] { scans.filter { selection.contains($0.objectID) } }

	// MARK: Pieces

	private var topBar: some View {
		HStack(spacing: 10) {
			BackPill(title: backTitle) { router.pop() }
			Spacer()
			if !scans.isEmpty {
				Button(selecting ? "Done" : "Select") {
					if selecting {
						endSelecting()
					} else {
						withAnimation(RescrivaMotion.ui) { selecting = true }
					}
				}
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(.carbon)
				.frame(height: 40)
				.padding(.horizontal, 16)
				.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.rescrivaShadow(.small)
			}
			if !selecting { optionsMenu }
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	private var backTitle: LocalizedStringKey {
		guard let parent = folder?.parent else { return "Rescriva" }
		return LocalizedStringKey(parent.displayName)
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 10) {
				Glyph(look.symbol, size: 22)
					.foregroundStyle(look.tint)
				Text(look.title)
					.font(RescrivaFont.header(28))
					.foregroundStyle(.carbon)
					.lineLimit(2)
					.accessibilityAddTraits(.isHeader)
			}
			Text(subtitle)
				.font(RescrivaFont.ui(12))
				.foregroundStyle(.graphite)
		}
		.padding(.horizontal, 20)
		.padding(.top, 8)
		.padding(.bottom, 14)
	}

	private var subtitle: String {
		if scope == .recentlyDeleted {
			return String(localized: "Scans here are deleted for good after \(Library.recentlyDeletedDays) days.")
		}
		let count = scans.count
		return count == 1 ? String(localized: "1 scan") : String(localized: "\(count) scans")
	}

	@ViewBuilder
	private var subfolders: some View {
		if let folder, !folder.childFolders.isEmpty {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					ForEach(folder.childFolders, id: \.objectID) { child in
						Button {
							if let id = child.id { router.push(.collection(.folder(id))) }
						} label: {
							Label(child.displayName, systemImage: child.symbolName)
								.font(RescrivaFont.ui(13, weight: .medium))
								.foregroundStyle(.carbon)
								.padding(.vertical, 8)
								.padding(.horizontal, 12)
								.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous))
								.overlay { RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous).strokeBorder(child.tint.opacity(0.5)) }
						}
						.buttonStyle(PressScaleStyle())
					}
				}
				.padding(.horizontal, 20)
				.padding(.vertical, 2)
			}
			.padding(.bottom, 16)
		}
	}

	@ViewBuilder
	private var content: some View {
		let visible = scans
		if visible.isEmpty {
			Group {
				switch scope {
				case .all, .folder:
					EmptyState(text: emptyText) { SketchToCleanIllustration(subject: .notes) }
				default:
					EmptyState(text: emptyText)
				}
			}
			.padding(.horizontal, 16)
			.padding(.top, 20)
		} else {
			ScanGallery(sections: LibraryGrouping.sections(visible, sort: sort, pinnedFirst: scope.showsPinnedFirst, now: Date()),
						inRecentlyDeleted: scope == .recentlyDeleted, selecting: selecting, selection: $selection) { action, scans in
				controller.perform(action, on: scans, context: context, router: router)
			}
		}
	}

	private var emptyText: String {
		switch scope {
		case .recentlyDeleted: return String(localized: "Nothing deleted. Deleted scans wait here for 30 days.")
		case .folder: return String(localized: "This folder is empty. Scan something here, or move scans in from another folder.")
		case .smart: return String(localized: "Nothing matches this smart folder yet.")
		case .pinned: return String(localized: "Pin a scan to keep it at the top.")
		case .favorites: return String(localized: "Star a scan to find it here.")
		case .tag: return String(localized: "No scans have this tag.")
		case .all: return String(localized: "Nothing scanned yet.")
		}
	}

	private func endSelecting() {
		withAnimation(RescrivaMotion.ui) {
			selecting = false
			selection = []
		}
	}
}

// MARK: - Menus and bars

private extension ScanCollectionView {
	var optionsMenu: some View {
		Menu {
			Picker("Sort by", selection: $sortToken) {
				ForEach(LibrarySort.allCases, id: \.self) { option in Text(option.label).tag(option.rawValue) }
			}
			if let folder {
				Divider()
				Button { controller.sheet = .newFolder(parent: folder) } label: { Label("New Folder Inside", systemImage: "folder.badge.plus") }
				Button { controller.sheet = .editFolder(folder) } label: { Label("Edit Folder", systemImage: "paintpalette") }
				Button { controller.sheet = .moveFolder(folder) } label: { Label("Move Folder…", systemImage: "arrow.turn.down.right") }
				Button(role: .destructive) { controller.folderToDelete = folder } label: { Label("Delete Folder", systemImage: "trash") }
			}
			if case .smart(let id) = scope, let smart = Library.smartFolder(id, in: context) {
				Divider()
				Button { controller.sheet = .editSmartFolder(smart) } label: { Label("Edit Smart Folder", systemImage: "slider.horizontal.3") }
			}
		} label: {
			Glyph("ellipsis", size: 17, weight: .medium)
				.foregroundStyle(.carbon)
				.frame(width: 40, height: 40)
				.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.rescrivaShadow(.small)
		}
		.accessibilityLabel(Text("More"))
	}

	var selectionBar: some View {
		FrostedBottomBar {
			HStack(spacing: 8) {
				Button(selection.count == scans.count ? "Deselect All" : "Select All") {
					withAnimation(RescrivaMotion.fast) {
						selection = selection.count == scans.count ? [] : Set(scans.map(\.objectID))
					}
				}
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(.ink)
				Spacer()
				Text(selection.isEmpty ? "Select scans" : "\(selection.count) selected")
					.font(RescrivaFont.ui(13))
					.foregroundStyle(.graphite)
			}
			HStack(spacing: 8) {
				if scope == .recentlyDeleted {
					barButton("Recover", symbol: "arrow.uturn.backward", action: .recover)
					barButton("Delete", symbol: "trash", action: .purge, destructive: true)
				} else {
					barButton("Move", symbol: "folder", action: .move)
					barButton("Tags", symbol: "number", action: .tags)
					barButton("Pin", symbol: "pin", action: .pin(!selectedScans.allSatisfy(\.pinned)))
					barButton("Delete", symbol: "trash", action: .delete, destructive: true)
				}
			}
		}
	}

	func barButton(_ title: LocalizedStringKey, symbol: String, action: GalleryAction, destructive: Bool = false) -> some View {
		Button {
			controller.perform(action, on: selectedScans, context: context, router: router)
		} label: {
			VStack(spacing: 3) {
				Glyph(symbol, size: 18)
				Text(title).font(RescrivaFont.ui(11, weight: .medium))
			}
			.foregroundStyle(destructive ? Color.vermilion : Color.carbon)
			.frame(maxWidth: .infinity, minHeight: 50)
			.background(Color.vellum, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		}
		.buttonStyle(PressScaleStyle())
		.disabled(selection.isEmpty)
		.opacity(selection.isEmpty ? 0.4 : 1)
	}

	/// Scan straight into this folder: tap for a document, hold for a whiteboard.
	var scanButton: some View {
		HStack {
			Spacer()
			Menu {
				Button { router.push(.camera(.document, appendingTo: nil)) } label: { Label("Document", systemImage: "doc.viewfinder") }
				Button { router.push(.camera(.whiteboard, appendingTo: nil)) } label: { Label("Whiteboard", systemImage: "rectangle.and.pencil.and.ellipsis") }
			} label: {
				HStack(spacing: 8) {
					Glyph("viewfinder", size: 18, weight: .medium)
					Text("Scan here")
						.font(RescrivaFont.ui(16, weight: .medium))
				}
				.foregroundStyle(.vellum)
				.frame(height: 54)
				.padding(.horizontal, 22)
				.background(Color.ink, in: RoundedRectangle(cornerRadius: RescrivaRadius.large * 0.75, style: .continuous))
				.rescrivaShadow(.float)
			} primaryAction: {
				router.push(.camera(.document, appendingTo: nil))
			}
			.accessibilityHint(Text("New scans go into this folder. Hold for a whiteboard."))
		}
		.padding(.trailing, 20)
		.padding(.bottom, 10)
	}
}
