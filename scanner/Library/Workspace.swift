//
//  Workspace.swift
//  Rescriva (fork of Open Scanner)
//
//  The Library on a wide screen, from the iPad and Duo designs. In landscape the scans run down a
//  sidebar, the chosen scan's pages fill the middle and "Make it into" stands beside them; in
//  portrait the scans become chips across the top and "Make it into" a sheet below the pages; on
//  the unfolded Duo the scans take one half and the chosen scan the other. A phone keeps HomeView.
//  Every other screen still floats in above, as on the phone (RescrivaRouter).
//

import CoreData
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// How the Library is laid out on a wide screen.
enum WorkspaceLayout: Equatable {
	/// Sidebar, pages and "Make it into" side by side (iPad in landscape, Mac).
	case columns
	/// Chips over the pages, "Make it into" in a sheet below (iPad in portrait).
	case portrait
	/// The scans in one half, the chosen scan in the other (the unfolded Duo).
	case halves

	/// The layout for a window of `size`, or nil for a phone-sized one, which keeps HomeView.
	init?(_ size: CGSize) {
		guard size.width >= Self.minimumWidth else { return nil }
		if size.width >= Self.columnsWidth, size.width >= size.height {
			self = .columns
		} else {
			self = size.height >= Self.portraitHeight ? .portrait : .halves
		}
	}

	/// Narrowest window, in points, that gets a workspace instead of the phone's Library.
	static let minimumWidth: CGFloat = 700
	/// Narrowest window with room for all three columns.
	static let columnsWidth: CGFloat = 1_000
	/// Shortest window that stacks the pages over a sheet rather than splitting in halves.
	static let portraitHeight: CGFloat = 900
	/// Width of the sidebar of scans.
	static let sidebarWidth: CGFloat = 300
	/// Width of the "Make it into" column.
	static let inspectorWidth: CGFloat = 260
}

struct WorkspaceView: View {
	let layout: WorkspaceLayout

	@Environment(\.managedObjectContext) private var viewContext
	@Environment(RescrivaRouter.self) private var router

	@FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Scan.order, ascending: false)],
				  predicate: LibraryScope.livePredicate, animation: .default)
	private var scans: FetchedResults<Scan>

	@State private var selectedID: NSManagedObjectID?
	@State private var searchText = ""
	/// Tags chosen under the search field: only scans with all of them show.
	@State private var tagFilter: Set<NSManagedObjectID> = []
	@State private var showsLibrary = false
	@State private var showsDrawer = false
	@State private var importingPhotos = false
	@State private var importingPDF = false
	@State private var photoSelection: [PhotosPickerItem] = []
	@State private var isImporting = false
	@State private var isDropTargeted = false
	private let pdfLibrary = PDFLibrary.shared

	var body: some View {
		ZStack {
			GrainBackground()
			switch layout {
			case .columns:
				HStack(spacing: 0) {
					sidebar.frame(width: WorkspaceLayout.sidebarWidth)
					center(titleSize: 28)
					if let scan = selected {
						WorkspaceInspector(scan: scan, style: .column)
							.frame(width: WorkspaceLayout.inspectorWidth)
					}
				}
			case .halves:
				HStack(spacing: 0) {
					sidebar.frame(maxWidth: .infinity)
					VStack(spacing: 0) {
						center(titleSize: 24)
						if let scan = selected { WorkspaceInspector(scan: scan, style: .buttons) }
					}
					.frame(maxWidth: .infinity)
				}
			case .portrait:
				portrait
			}
			if isImporting {
				ProgressView().tint(.ink).padding(20).background(Color.vellum, in: RoundedRectangle(cornerRadius: 14))
			}
		}
		.overlay { if isDropTargeted { dropHint } }
		.onDrop(of: [.pdf, .image], isTargeted: $isDropTargeted) { providers in
			Task { importFiles(await FileImport.files(from: providers)) }
			return true
		}
		.photosPicker(isPresented: $importingPhotos, selection: $photoSelection, maxSelectionCount: 30, matching: .images)
		.fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
			if case .success(let urls) = result { importFiles(urls) }
		}
		.onChange(of: photoSelection) { _, items in
			guard !items.isEmpty else { return }
			importPhotos(items)
		}
		.task { Library.purgeExpired(in: viewContext) }
	}

	/// The chosen scan, or the newest when none is chosen or the chosen one is gone.
	private var selected: Scan? {
		if let selectedID, let scan = scans.first(where: { $0.objectID == selectedID }) { return scan }
		return scans.first
	}

	private var sidebar: some View {
		WorkspaceSidebar(scans: LibrarySearch.matching(Array(scans), query: searchText, tags: tagFilter), selected: selected,
						 searchText: $searchText, tagFilter: $tagFilter, showsLibrary: $showsLibrary,
						 onSelect: { scan in
							 withAnimation(RescrivaMotion.ui) {
								 selectedID = scan.objectID
								 showsDrawer = false
							 }
						 },
						 onStart: start)
	}

	@ViewBuilder
	private func center(titleSize: CGFloat) -> some View {
		if let scan = selected {
			WorkspaceScanDetail(scan: scan, titleSize: titleSize)
				.id(scan.objectID)
		} else {
			VStack {
				EmptyState(text: String(localized: "Nothing scanned yet. Tap Scan whenever you're ready.")) {
					SketchToCleanIllustration(subject: .flowchart, maxHeight: 120)
				}
				.frame(maxWidth: 520)
				.padding(28)
				Spacer()
			}
			.frame(maxWidth: .infinity)
		}
	}

	// MARK: Portrait

	private var portrait: some View {
		VStack(spacing: 0) {
			HStack(spacing: 12) {
				CircleIconButton(systemName: "sidebar.left", label: "Show the library") {
					withAnimation(RescrivaMotion.ui) { showsDrawer = true }
				}
				RescrivaWordmark(size: 28)
					.frame(maxWidth: .infinity, alignment: .leading)
				CircleIconButton(systemName: "slider.vertical.3", label: "Settings") { router.push(.settings) }
				WorkspaceScanMenu(height: 40, onStart: start)
			}
			.padding(EdgeInsets(top: 12, leading: 28, bottom: 12, trailing: 28))
			scanChips
			center(titleSize: 30)
			if let scan = selected { WorkspaceInspector(scan: scan, style: .sheet) }
		}
		.overlay { drawer }
	}

	/// The scans as chips, the chosen one dark.
	private var scanChips: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			LazyHStack(spacing: 10) {
				ForEach(scans, id: \.objectID) { scan in
					let isSelected = scan == selected
					Button {
						withAnimation(RescrivaMotion.ui) { selectedID = scan.objectID }
					} label: {
						Text(scan.displayTitle)
							.font(RescrivaFont.ui(13, weight: .medium))
							.foregroundStyle(isSelected ? Color.vellum : Color.carbon)
							.lineLimit(1)
							.frame(maxWidth: 200)
							.padding(.vertical, 8)
							.padding(.horizontal, 14)
							.background(isSelected ? Color.carbon : Color.vellum, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
							.rescrivaShadow(.small)
					}
					.buttonStyle(PressScaleStyle(scale: 0.94))
					.accessibilityAddTraits(isSelected ? .isSelected : [])
				}
			}
			.padding(EdgeInsets(top: 4, leading: 28, bottom: 16, trailing: 28))
		}
		.frame(height: 56)
	}

	/// The sidebar over the portrait screen, for folders, tags and search.
	@ViewBuilder
	private var drawer: some View {
		if showsDrawer {
			HStack(spacing: 0) {
				sidebar
					.frame(width: WorkspaceLayout.sidebarWidth + 20)
					.rescrivaShadow(.card)
				Color.shade.opacity(0.22)
					.onTapGesture { withAnimation(RescrivaMotion.ui) { showsDrawer = false } }
					.accessibilityLabel("Close the library")
			}
			.ignoresSafeArea(edges: .bottom)
			.transition(.settle)
		}
	}

	// MARK: Starting a scan

	private func start(_ start: ScanStart) {
		showsDrawer = false
		switch start {
		case .document: router.push(.camera(.document, appendingTo: nil))
		case .whiteboard: router.push(.camera(.whiteboard, appendingTo: nil))
		case .photos: importingPhotos = true
		case .pdf: importingPDF = true
		}
	}

	private func importPhotos(_ items: [PhotosPickerItem]) {
		isImporting = true
		Task {
			let scan = await PhotoImport.scan(from: items, in: viewContext)
			photoSelection = []
			isImporting = false
			guard let scan else {
				router.showToast(String(localized: "Those photos couldn't be opened."))
				return
			}
			selectedID = scan.objectID
			router.push(.scan(scan))
		}
	}

	/// Opens picked or dropped files: PDFs as PDFs, images together as one new scan.
	private func importFiles(_ urls: [URL]) {
		guard !urls.isEmpty else { return }
		let pdfs = urls.filter(FileImport.isPDF)
		let images = urls.filter { !FileImport.isPDF($0) }
		isImporting = true
		Task {
			if !images.isEmpty, let scan = await PhotoImport.scan(from: FileImport.images(at: images), in: viewContext) {
				selectedID = scan.objectID
			}
			if !pdfs.isEmpty { await PDFOpening.open(pdfs, in: pdfLibrary, router: router) }
			isImporting = false
		}
	}

	/// Shown while files are dragged over the window.
	private var dropHint: some View {
		RoundedRectangle(cornerRadius: 28, style: .continuous)
			.strokeBorder(Color.ink, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
			.background(Color.wash.opacity(0.25), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
			.overlay {
				Text("Drop PDFs or images to import")
					.font(RescrivaFont.header(22))
					.foregroundStyle(.carbon)
			}
			.padding(16)
			.allowsHitTesting(false)
	}
}

/// PDFs and images from files: dropped on the window, or picked in Finder or Files.
enum FileImport {
	/// Copies of the PDFs and images among `providers` (a drop), which outlive the drop.
	static func files(from providers: [NSItemProvider]) async -> [URL] {
		var urls: [URL] = []
		for provider in providers {
			guard let type = [UTType.pdf, UTType.image].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }),
				  let url = await copy(of: provider, as: type) else { continue }
			urls.append(url)
		}
		return urls
	}

	/// A copy of `provider`'s file in a fresh temporary folder, or nil when it won't load.
	private static func copy(of provider: NSItemProvider, as type: UTType) async -> URL? {
		await withCheckedContinuation { continuation in
			_ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
				guard let url else {
					continuation.resume(returning: nil)
					return
				}
				let folder = FileManager.default.temporaryDirectory
					.appendingPathComponent("Dropped", isDirectory: true)
					.appendingPathComponent(UUID().uuidString, isDirectory: true)
				let copy = folder.appendingPathComponent(url.lastPathComponent)
				do {
					try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
					try FileManager.default.copyItem(at: url, to: copy)
					continuation.resume(returning: copy)
				} catch {
					continuation.resume(returning: nil)
				}
			}
		}
	}

	/// True for a PDF file, judged by its extension; anything else imported is an image.
	static func isPDF(_ url: URL) -> Bool {
		UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false
	}

	/// The images among `urls` that open, each read while its security scope is open.
	static func images(at urls: [URL]) -> [UIImage] {
		urls.compactMap { url in
			let scoped = url.startAccessingSecurityScopedResource()
			defer { if scoped { url.stopAccessingSecurityScopedResource() } }
			guard let data = try? Data(contentsOf: url) else { return nil }
			return UIImage(data: data)
		}
	}

	/// Every page in `urls` as an image: each image, and each page of each PDF.
	@MainActor
	static func pages(from urls: [URL]) async -> [UIImage] {
		var pages: [UIImage] = []
		for url in urls {
			guard isPDF(url) else {
				pages += images(at: [url])
				continue
			}
			let scoped = url.startAccessingSecurityScopedResource()
			pages += await PDFImport.pages(of: url) { _, _ in }
			if scoped { url.stopAccessingSecurityScopedResource() }
		}
		return pages
	}
}

/// The Scan button: a scan, a whiteboard, photos or a PDF.
struct WorkspaceScanMenu: View {
	var height: CGFloat = 36
	let onStart: (ScanStart) -> Void

	var body: some View {
		Menu {
			ForEach(Self.starts, id: \.self) { start in
				Button { onStart(start) } label: { Label(start.label, systemImage: start.systemImage) }
			}
		} label: {
			HStack(spacing: 6) {
				Glyph("plus", size: 13)
				Text("Scan").font(RescrivaFont.ui(14, weight: .medium))
			}
			.foregroundStyle(Color.vellum)
			.padding(.horizontal, 14)
			.frame(height: height)
			.background(Color.ink, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
			.rescrivaShadow(.small)
		}
		.accessibilityLabel("Scan")
	}

	/// Every way to start on iPhone and iPad; on a Mac, which has no document camera, photos and
	/// files (Finder, or drop them on the window).
	static var starts: [ScanStart] {
		guard ProcessInfo.processInfo.isMacCatalystApp else { return ScanStart.allCases }
		return [.photos, .pdf]
	}
}

/// The sidebar: the wordmark and Scan, search (with the tags to filter by while searching), then
/// the scans, or the Library's folders and smart folders.
struct WorkspaceSidebar: View {
	let scans: [Scan]
	let selected: Scan?
	@Binding var searchText: String
	@Binding var tagFilter: Set<NSManagedObjectID>
	@Binding var showsLibrary: Bool
	let onSelect: (Scan) -> Void
	let onStart: (ScanStart) -> Void

	@Environment(\.managedObjectContext) private var viewContext
	@Environment(RescrivaRouter.self) private var router
	@State private var controller = LibraryController()
	@FocusState private var searchFocused: Bool

	private var isSearching: Bool {
		!searchText.trimmingCharacters(in: .whitespaces).isEmpty || !tagFilter.isEmpty
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(spacing: 8) {
				RescrivaWordmark(size: 30)
					.frame(maxWidth: .infinity, alignment: .leading)
				CircleIconButton(systemName: "slider.vertical.3", label: "Settings") { router.push(.settings) }
				WorkspaceScanMenu(onStart: onStart)
			}
			.padding(.horizontal, 6)
			searchField
			if searchFocused || isSearching {
				TagFilterBar(selection: $tagFilter, controller: controller, inset: 0)
					.padding(.top, -6)
			}
			RescrivaSegmentedPicker(options: [false, true], selection: $showsLibrary) { $0 ? "Library" : "Scans" }
			if showsLibrary && !isSearching {
				ScrollView { LibraryHomeView().padding(.horizontal, -12) }
			} else {
				scanList
			}
			if ProcessInfo.processInfo.isMacCatalystApp {
				Text("Drop PDFs or images anywhere to import")
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
					.padding(EdgeInsets(top: 4, leading: 6, bottom: 16, trailing: 6))
			}
		}
		.padding(EdgeInsets(top: 20, leading: 16, bottom: 0, trailing: 16))
		.frame(maxHeight: .infinity, alignment: .top)
		.background(Color.vellum.ignoresSafeArea())
		.overlay(alignment: .trailing) { Rectangle().fill(Color.carbon.opacity(0.08)).frame(width: 1).ignoresSafeArea() }
		.libraryPresentations(controller)
	}

	private var searchField: some View {
		HStack(spacing: 8) {
			Glyph("magnifyingglass", size: 14).foregroundStyle(.graphite)
			TextField("Search scans", text: $searchText)
				.font(RescrivaFont.ui(14))
				.foregroundStyle(.carbon)
				.submitLabel(.search)
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
				.focused($searchFocused)
			if isSearching {
				Button {
					searchText = ""
					tagFilter = []
				} label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.graphite) }
					.accessibilityLabel("Clear search")
			}
		}
		.padding(.horizontal, 12)
		.frame(height: 40)
		.background(Color.stock, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
	}

	@ViewBuilder
	private var scanList: some View {
		if scans.isEmpty {
			Text(!isSearching ? "No scans yet." : searchText.isEmpty ? "No scans have all of these tags." : "Nothing here mentions that yet.")
				.font(RescrivaFont.note(15))
				.foregroundStyle(.graphite)
				.padding(.horizontal, 6)
				.padding(.top, 8)
			Spacer()
		} else {
			ScrollView {
				LazyVStack(spacing: 4) {
					ForEach(scans, id: \.objectID) { scan in
						WorkspaceScanRow(scan: scan, isSelected: scan == selected) { onSelect(scan) }
							.contextMenu { rowMenu(scan) }
					}
				}
				.padding(.bottom, 24)
			}
		}
	}

	@ViewBuilder
	private func rowMenu(_ scan: Scan) -> some View {
		Button { router.push(.preview(scan)) } label: { Label("Open", systemImage: "doc.text.magnifyingglass") }
		Button { router.push(.scan(scan)) } label: { Label("Edit pages", systemImage: "square.and.pencil") }
		Button { controller.perform(.favorite(!scan.fave), on: [scan], context: viewContext, router: router) } label: {
			Label(scan.fave ? "Unfavorite" : "Favorite", systemImage: scan.fave ? "star.slash" : "star")
		}
		Button { controller.perform(.move, on: [scan], context: viewContext, router: router) } label: {
			Label("Move to folder", systemImage: "folder")
		}
		Button(role: .destructive) { controller.perform(.delete, on: [scan], context: viewContext, router: router) } label: {
			Label("Delete", systemImage: "trash")
		}
	}
}

/// One scan in the sidebar: a paper thumbnail, its title and when.
struct WorkspaceScanRow: View {
	@ObservedObject var scan: Scan
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 12) {
				PaperThumbnail(image: scan.capturesArray.first?.thumbnail, width: 34, height: 44)
				VStack(alignment: .leading, spacing: 1) {
					Text(scan.displayTitle)
						.font(RescrivaFont.ui(14, weight: .medium))
						.foregroundStyle(.carbon)
						.lineLimit(1)
					Text(scan.libraryMeta)
						.font(RescrivaFont.ui(12))
						.foregroundStyle(.graphite)
						.lineLimit(1)
				}
				Spacer(minLength: 0)
			}
			.padding(10)
			.background(isSelected ? Color.ink.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			.contentShape(Rectangle())
		}
		.buttonStyle(PressScaleStyle(scale: 0.98))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}
