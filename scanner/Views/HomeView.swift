//
//  HomeView.swift
//  Open Scanner → Rescriva
//
//  Created by Slaven Radic on 2024-09-01.
//  Rescriva: the Library — search every word you've scanned, the folder list
//  (LibraryHomeView: All Scans, Favorites, smart folders, folders), and the
//  Scan button with its picker. While searching, the tags show as chips under
//  the field to filter by. A search shows matching scans as a gallery, and
//  matching PDFs (PDFLibrary) below them.
//

import SwiftUI
import CoreData
import PhotosUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers

struct HomeView: View {
	@Environment(\.managedObjectContext) private var viewContext
	@Environment(RescrivaRouter.self) private var router

	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \Scan.order, ascending: false)],
		predicate: LibraryScope.livePredicate,
		animation: .default)
	private var scans: FetchedResults<Scan>

	@State private var searchText = ""
	/// Tags chosen under the search field: only scans with all of them show.
	@State private var tagFilter: Set<NSManagedObjectID> = []
	@FocusState private var searchFocused: Bool
	@State private var searchController = LibraryController()
	@State private var pickerOpen = false
	@State private var importingPhotos = false
	@State private var importingPDF = false
	@State private var photoSelection: [PhotosPickerItem] = []
	@State private var isImporting = false
	@State private var importProgress: String?
	private let pdfLibrary = PDFLibrary.shared

	var body: some View {
		ZStack(alignment: .bottomTrailing) {
			GrainBackground()

			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					header
					searchField
					if searchFocused || isSearching {
						TagFilterBar(selection: $tagFilter, controller: searchController)
							.padding(.top, 8)
					}
					content
				}
				.padding(.bottom, 140)
			}
			.overlay(alignment: .top) { StatusBarScrim() }
			.scrollDismissesKeyboard(.immediately)

			if pickerOpen {
				Color.shade.opacity(0.22)
					.background(.ultraThinMaterial.opacity(0.25))
					.ignoresSafeArea()
					.onTapGesture { withAnimation(RescrivaMotion.ui) { pickerOpen = false } }
					.transition(.opacity)
					.accessibilityLabel("Close scan options")
			}

			ScanStartPicker(isOpen: $pickerOpen, isBusy: isImporting, busyTitle: importProgress) { start in
				withAnimation(RescrivaMotion.ui) { pickerOpen = false }
				switch start {
				case .document: router.push(.camera(.document, appendingTo: nil))
				case .whiteboard: router.push(.camera(.whiteboard, appendingTo: nil))
				case .photos: importingPhotos = true
				case .pdf: importingPDF = true
				}
			}
			.padding(.trailing, 20)
			.padding(.bottom, 10)
		}
		.photosPicker(isPresented: $importingPhotos, selection: $photoSelection, maxSelectionCount: 30, matching: .images)
		.fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
			if case .success(let urls) = result {
				openPDFs(urls)
			}
		}
		.task { await PDFImport.pruneOriginals(in: viewContext) }
		.onChange(of: photoSelection) { _, items in
			guard !items.isEmpty else { return }
			importPhotos(items)
		}
		.libraryPresentations(searchController)
		.task { Library.purgeExpired(in: viewContext) }
	}

	// MARK: Header

	private var header: some View {
		HStack {
			RescrivaWordmark(size: 34)
			Spacer()
			CircleIconButton(systemName: "dot.radiowaves.left.and.right", label: "Share Nearby") {
				router.push(.shareNearby([]))
			}
			CircleIconButton(systemName: "slider.vertical.3", label: "Settings") {
				router.push(.settings)
			}
		}
		.padding(.horizontal, 20)
		.padding(.top, 8)
		.padding(.bottom, 4)
	}

	private var searchField: some View {
		HStack(spacing: 8) {
			Glyph("magnifyingglass", size: 15)
				.foregroundStyle(.graphite)
			TextField("Search every word you've scanned", text: $searchText)
				.font(RescrivaFont.ui(15))
				.foregroundStyle(.carbon)
				.submitLabel(.search)
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
				.focused($searchFocused)
			if isSearching {
				Button {
					withAnimation(RescrivaMotion.ui) {
						searchText = ""
						tagFilter = []
					}
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(Color.graphite.opacity(0.6))
				}
				.accessibilityLabel("Clear search")
			}
		}
		.padding(.horizontal, 14)
		.frame(height: 44)
		.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
		.overlay { RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous).strokeBorder(Color.carbon.opacity(0.08)) }
		.padding(.horizontal, 20)
		.padding(.top, 10)
	}

	// MARK: Content

	/// Searching by words, by tags or both.
	private var isSearching: Bool {
		!searchText.trimmingCharacters(in: .whitespaces).isEmpty || !tagFilter.isEmpty
	}

	/// Scans whose words, title or tags match the search, with every chosen tag.
	private var matchingScans: [Scan] {
		LibrarySearch.matching(Array(scans), query: searchText, tags: tagFilter)
	}

	/// PDFs whose title or text match the search. PDFs have no tags, so none match a tag filter.
	private var matchingPDFs: [PDFItem] {
		let query = searchText.trimmingCharacters(in: .whitespaces)
		guard !query.hasPrefix("#"), tagFilter.isEmpty else { return [] }
		return pdfLibrary.items.filter { pdfLibrary.matches($0, query: query) }
	}

	@ViewBuilder
	private var content: some View {
		if !isSearching {
			if scans.isEmpty && pdfLibrary.items.isEmpty {
				EmptyState(text: String(localized: "Nothing scanned yet. Tap Scan whenever you're ready.")) {
					SketchToCleanIllustration(subject: .flowchart)
				}
				.padding(.horizontal, 16)
				.padding(.top, 16)
			}
			LibraryHomeView()
		} else {
			searchResults
		}
	}

	@ViewBuilder
	private var searchResults: some View {
		let found = matchingScans
		let foundPDFs = matchingPDFs
		if found.isEmpty && foundPDFs.isEmpty {
			EmptyState(text: searchText.trimmingCharacters(in: .whitespaces).isEmpty
					   ? String(localized: "No scans have all of these tags.") : String(localized: "Nothing here mentions that yet."),
					   ruling: .lines)
				.padding(.horizontal, 16)
				.padding(.top, 24)
		} else {
			if !found.isEmpty {
				Text(found.count == 1 ? "1 scan" : "\(found.count) scans")
					.rescrivaSectionLabel()
					.padding(.horizontal, 24)
					.padding(.top, 18)
					.padding(.bottom, 10)
				ScanGallery(sections: [LibraryGrouping.Section(id: "results", title: "", scans: found)], inRecentlyDeleted: false,
							selecting: false, selection: .constant([])) { action, scans in
					searchController.perform(action, on: scans, context: viewContext, router: router)
				}
			}
			if !foundPDFs.isEmpty {
				Text(foundPDFs.count == 1 ? "1 PDF" : "\(foundPDFs.count) PDFs")
					.rescrivaSectionLabel()
					.padding(.horizontal, 24)
					.padding(.top, 18)
					.padding(.bottom, 10)
				LazyVStack(spacing: 12) {
					ForEach(foundPDFs) { item in
						PDFItemCard(item: item) {
							router.push(.pdf(item.id, query: searchText.trimmingCharacters(in: .whitespaces)))
						} onToggleFave: {
							pdfLibrary.toggleFave(item)
						}
					}
				}
				.padding(.horizontal, 16)
			}
		}
	}

	// MARK: Actions

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
			router.push(.scan(scan))
		}
	}

	/// Opens the chosen PDFs as PDFs (PDFDocumentView); one opens straight away.
	private func openPDFs(_ urls: [URL]) {
		isImporting = true
		Task {
			await PDFOpening.open(urls, in: pdfLibrary, router: router)
			isImporting = false
		}
	}
}

// MARK: - Search and photo import

/// The Library's search, shared by the phone's Library and the iPad workspace.
@MainActor
enum LibrarySearch {
	/// `scans` whose words, title or tags match `query` ("#name" matches tags only) and that carry
	/// every tag in `tags`.
	static func matching(_ scans: [Scan], query: String, tags: Set<NSManagedObjectID> = []) -> [Scan] {
		let scans = tags.isEmpty ? scans : scans.filter { tags.isSubset(of: Set($0.tagList.map(\.objectID))) }
		let query = query.trimmingCharacters(in: .whitespaces)
		guard !query.isEmpty else { return scans }
		let tagQuery = query.hasPrefix("#") ? Library.tagName(query)?.lowercased() : nil
		return scans.filter { scan in
			if let tagQuery { return scan.tagList.contains { ($0.name ?? "").lowercased().hasPrefix(tagQuery) } }
			return scan.containsText(query) || scan.tagList.contains { ($0.name ?? "").localizedCaseInsensitiveContains(query) }
		}
	}
}

/// Photos from the photo library made into a new scan, cleaned up the way captures are.
enum PhotoImport {
	/// A new scan of `items`, or nil when none of them would open.
	@MainActor
	static func scan(from items: [PhotosPickerItem], in context: NSManagedObjectContext) async -> Scan? {
		var images: [UIImage] = []
		for item in items {
			if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
				images.append(image)
			}
		}
		return await scan(from: images, in: context)
	}

	/// A new scan of `images` (photos, or images dropped or picked from files), or nil for none.
	@MainActor
	static func scan(from images: [UIImage], in context: NSManagedObjectContext) async -> Scan? {
		var pages: [CapturedPage] = []
		let removeShadows = UserDefaults.standard.bool(forKey: RescrivaPreference.removeShadows)
		let keepsOriginal = UserDefaults.standard.bool(forKey: RescrivaPreference.keepOriginals)
		for image in images {
			pages.append(await ImportCleanup.prepare(image.normalizedUp(), removeShadows: removeShadows, keepsOriginal: keepsOriginal))
		}
		guard !pages.isEmpty else { return nil }
		let day = Date().formatted(.dateTime.month(.abbreviated).day())
		let title = pages.count == 1 ? String(localized: "Photo, \(day)") : String(localized: "Photos, \(day)")
		return Scan.create(from: pages, title: title, source: nil, in: context)
	}
}

// MARK: - PDF import

/// Turns a PDF into page images without holding every page as a bitmap: pages
/// render one at a time off the main thread and stay JPEG until something
/// draws or reads them. (Fifty-odd full-size bitmaps at once crashed the app.)
enum PDFImport {
	static let maxPages = 200
	/// Rendered width in pixels: the width a page is stored at.
	static let pageWidth: CGFloat = 2400
	/// Keeps very tall pages (receipts, posters) to a sane size.
	static let maxPageHeight: CGFloat = 4000

	/// Up to `maxPages` pages of the PDF at `url`, or none if it can't be opened
	/// (or is locked and `password` doesn't open it). `progress` hears (pages done,
	/// pages to do) after each page.
	static func pages(of url: URL, password: String? = nil, progress: @escaping @MainActor (Int, Int) -> Void) async -> [UIImage] {
		let encoded = await Task.detached(priority: .userInitiated) { () -> [Data] in
			guard let document = PDFDocument(url: url) else { return [] }
			if document.isLocked {
				guard let password, document.unlock(withPassword: password) else { return [] }
			}
			let count = min(document.pageCount, maxPages)
			var pages: [Data] = []
			for index in 0..<count {
				autoreleasepool {
					if let page = document.page(at: index), let data = jpeg(of: page) {
						pages.append(data)
					}
				}
				await progress(index + 1, count)
			}
			return pages
		}.value
		return encoded.compactMap(lazyImage)
	}

	/// One page upright on white, `pageWidth` pixels across, as JPEG.
	private static func jpeg(of page: PDFPage) -> Data? {
		let box = page.bounds(for: .cropBox)
		let quarterTurned = (page.rotation / 90) % 2 != 0
		let size = quarterTurned ? CGSize(width: box.height, height: box.width) : box.size
		guard size.width >= 1, size.height >= 1 else { return nil }
		let scale = min(pageWidth / size.width, maxPageHeight / size.height)
		let width = Int((size.width * scale).rounded())
		let height = Int((size.height * scale).rounded())
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
			  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
									  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
		context.setFillColor(gray: 1, alpha: 1)
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		context.interpolationQuality = .high
		context.scaleBy(x: scale, y: scale)
		// draw(with:to:) applies the page's rotation and crop origin itself.
		page.draw(with: .cropBox, to: context)
		guard let image = context.makeImage() else { return nil }
		return UIImage(cgImage: image).jpegData(compressionQuality: 0.9)
	}

	/// A page that stays compressed in memory and is decoded only while used.
	private static func lazyImage(_ data: Data) -> UIImage? {
		let options = [kCGImageSourceShouldCache: false] as CFDictionary
		guard let source = CGImageSourceCreateWithData(data as CFData, nil),
			  let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
		return UIImage(cgImage: image)
	}
}

// MARK: - Original PDFs

/// The PDF a scan was imported from, kept under its own name as Application
/// Support/Originals/PDF/<scan id>/<name>.pdf for "View original" (and, later,
/// a rebuild that reads the PDF's own text and drawings). Like page originals it
/// lives on this iPhone only: out of Core Data, so CloudKit never syncs it, and
/// out of device backups. A scan synced from another device just has no
/// original here.
extension PDFImport {
	static var originalsDirectory: URL {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		return support.appendingPathComponent("Originals", isDirectory: true).appendingPathComponent("PDF", isDirectory: true)
	}

	/// The kept PDF for `scan`, if this iPhone has one.
	static func original(for scan: Scan) -> URL? {
		guard let id = scan.id,
			  let files = try? FileManager.default.contentsOfDirectory(at: folder(for: id), includingPropertiesForKeys: nil) else { return nil }
		return files.first { $0.pathExtension.lowercased() == "pdf" }
	}

	/// Copies the picked PDF to a temporary file off the main thread. Call while
	/// its security scope is open. Nil, logged, when it can't be copied: the scan
	/// is then kept without its original.
	static func stageOriginal(_ url: URL) async -> URL? {
		await Task.detached(priority: .userInitiated) { () -> URL? in
			let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
			do {
				try FileManager.default.copyItem(at: url, to: staged)
				return staged
			} catch {
				print("Rescriva: couldn't copy the original PDF: \(error)")
				return nil
			}
		}.value
	}

	/// Moves a staged PDF into place as `name`, the original for scan `id` (a
	/// rename on the same volume). Its folder is new, so the prune spares it.
	static func keepOriginal(_ staged: URL, named name: String, for id: UUID) {
		let folder = folder(for: id)
		let fileName = name.lowercased().hasSuffix(".pdf") ? name : "\(name).pdf"
		do {
			try prepareOriginalsDirectory()
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try FileManager.default.moveItem(at: staged, to: folder.appendingPathComponent(fileName))
		} catch {
			print("Rescriva: couldn't keep the original PDF: \(error)")
		}
	}

	/// Deletes the kept PDF for scan `id`, if there is one.
	static func removeOriginal(for id: UUID) {
		let folder = folder(for: id)
		guard FileManager.default.fileExists(atPath: folder.path) else { return }
		do {
			try FileManager.default.removeItem(at: folder)
		} catch {
			print("Rescriva: couldn't remove an original PDF: \(error)")
		}
	}

	/// How many original PDFs this iPhone keeps and the space they take, for
	/// Settings beside the page originals. Off the main thread.
	static func originalsUsage(in directory: URL = PDFImport.originalsDirectory) -> OriginalStore.Usage {
		let keys: Set<URLResourceKey> = [.fileSizeKey]
		var usage = OriginalStore.Usage(count: 0, bytes: 0)
		for folder in scanFolders(in: directory) {
			guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { continue }
			for file in files where file.pathExtension.lowercased() == "pdf" {
				usage.count += 1
				usage.bytes += Int64((try? file.resourceValues(forKeys: keys))?.fileSize ?? 0)
			}
		}
		return usage
	}

	/// Deletes every original PDF (Settings' "Remove originals"); returns how
	/// many scans lost theirs. Off the main thread.
	@discardableResult
	static func removeAllOriginals(in directory: URL = PDFImport.originalsDirectory) -> Int {
		var removed = 0
		for folder in scanFolders(in: directory) {
			do {
				try FileManager.default.removeItem(at: folder)
				removed += 1
			} catch {
				print("Rescriva: couldn't remove an original PDF: \(error)")
			}
		}
		return removed
	}

	/// The per-scan folders (named by scan id) in `directory`.
	private static func scanFolders(in directory: URL) -> [URL] {
		guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
		return entries.filter { UUID(uuidString: $0.lastPathComponent) != nil }
	}

	/// Deletes kept PDFs whose scans are gone (deleted on another device); a
	/// scan in Recently Deleted is still here. Like page originals, it does
	/// nothing when more than half would go: an iCloud account change empties
	/// the library at once, and its scans come back under the same ids while
	/// their PDFs can't be fetched again. Skipped, as they are, for the
	/// temporary in-memory library. `directory` is for tests.
	@MainActor
	static func pruneOriginals(in context: NSManagedObjectContext, directory: URL = PDFImport.originalsDirectory) async {
		guard context.isLibraryOnDisk else { return }
		let request = NSFetchRequest<NSDictionary>(entityName: "Scan")
		request.resultType = .dictionaryResultType
		request.propertiesToFetch = ["id"]
		let ids: Set<UUID>
		do {
			ids = Set(try context.fetch(request).compactMap { $0["id"] as? UUID })
		} catch {
			print("Rescriva: couldn't list scans to prune original PDFs: \(error)")
			return
		}
		let cutoff = Date()
		await Task.detached(priority: .utility) {
			pruneOriginals(keeping: ids, olderThan: cutoff, in: directory)
		}.value
	}

	private static func pruneOriginals(keeping ids: Set<UUID>, olderThan cutoff: Date, in directory: URL) {
		let keys: [URLResourceKey] = [.contentModificationDateKey]
		guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
		let orphans = folders.filter { folder in
			guard let id = UUID(uuidString: folder.lastPathComponent) else { return false }
			let modified = (try? folder.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
			return !ids.contains(id) && modified < cutoff
		}
		guard !orphans.isEmpty, orphans.count * 2 <= folders.count else { return }
		for folder in orphans {
			do {
				try FileManager.default.removeItem(at: folder)
			} catch {
				print("Rescriva: couldn't remove an orphaned original PDF: \(error)")
			}
		}
	}

	private static func folder(for id: UUID) -> URL {
		originalsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
	}

	/// Creates Originals/PDF, with Originals excluded from device backups.
	private static func prepareOriginalsDirectory() throws {
		guard !FileManager.default.fileExists(atPath: originalsDirectory.path) else { return }
		try FileManager.default.createDirectory(at: originalsDirectory, withIntermediateDirectories: true)
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		var originals = originalsDirectory.deletingLastPathComponent()
		try originals.setResourceValues(values)
	}
}

extension UIImage {
	/// Redraws the image with `.up` orientation so Vision and PDF export see it upright.
	func normalizedUp() -> UIImage {
		guard imageOrientation != .up else { return self }
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		return UIGraphicsImageRenderer(size: size, format: format).image { _ in
			draw(in: CGRect(origin: .zero, size: size))
		}
	}
}

struct HomeView_Previews: PreviewProvider {
	static var previews: some View {
		HomeView()
			.environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
			.environment(RescrivaRouter())
	}
}
