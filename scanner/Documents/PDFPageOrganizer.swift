//
//  PDFPageOrganizer.swift
//  Rescriva (fork of Open Scanner)
//
//  Every page of the open PDF as a thumbnail: tap one to jump to it, drag to
//  reorder, or choose pages to rotate, delete or save as a new PDF. Add blank
//  pages, photos or another PDF's pages (merging two PDFs). "With marks" narrows
//  the grid to the pages you've marked up. Every change can be undone, and
//  nothing is written until the PDF is saved. Thumbnails are drawn off the main
//  thread and kept, so long PDFs scroll smoothly.
//

import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PDFPageOrganizer: View {
	@Environment(\.dismiss) private var dismiss
	@Bindable var session: PDFEditSession
	let onGoToPage: (Int) -> Void
	/// The chosen pages as a new PDF, and how many there are.
	let onExtract: (Data, Int) -> Void

	@State private var selecting = false
	@State private var selection = Set<Int>()
	@State private var importingPDF = false
	@State private var importingPhotos = false
	@State private var photoItems: [PhotosPickerItem] = []
	@State private var problem: String?
	@State private var confirmingDelete = false
	/// Only the pages with marks on them.
	@State private var onlyMarked = false

	private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)]

	var body: some View {
		ZStack(alignment: .bottom) {
			GrainBackground()
			VStack(spacing: 0) {
				topBar
				filterRow
				ScrollView {
					LazyVGrid(columns: columns, spacing: 18) {
						ForEach(shownIndexes, id: \.self) { index in
							if let page = session.document.page(at: index) {
								cell(page, index: index)
							}
						}
					}
					.padding(.horizontal, 16)
					.padding(.top, 8)
					.padding(.bottom, 140)
					if onlyMarked && shownIndexes.isEmpty {
						Text("No pages have marks yet.")
							.font(RescrivaFont.note(16))
							.foregroundStyle(.graphite)
							.padding(.top, 40)
					}
				}
			}
			if selecting {
				selectionBar
					.transition(.move(edge: .bottom).combined(with: .opacity))
			}
		}
		.fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
			if case .success(let url) = result { insertPDF(url) }
		}
		.photosPicker(isPresented: $importingPhotos, selection: $photoItems, maxSelectionCount: 30, matching: .images)
		.onChange(of: photoItems) { _, items in
			guard !items.isEmpty else { return }
			insertPhotos(items)
		}
		.alert("Couldn't add those pages", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(problem ?? "")
		}
		.confirmationDialog(selection.count == 1 ? "Delete this page?" : "Delete \(selection.count) pages?",
							isPresented: $confirmingDelete, titleVisibility: .visible) {
			Button("Delete", role: .destructive) { deleteSelection() }
		} message: {
			Text("You can undo this until you leave the PDF.")
		}
	}

	/// Every page, or only those with marks.
	private var shownIndexes: [Int] {
		onlyMarked ? session.markedPageIndexes : Array(0..<session.pageCount)
	}

	// MARK: Top

	/// All pages, or only the marked-up ones (with how many there are).
	private var filterRow: some View {
		let marked = session.markedPageIndexes.count
		return HStack(spacing: 8) {
			ChoiceChip(label: "All pages", isSelected: !onlyMarked) { setOnlyMarked(false) }
			ChoiceChip(label: "With marks (\(marked))", isSelected: onlyMarked) { setOnlyMarked(true) }
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 16)
		.padding(.bottom, 4)
	}

	private func setOnlyMarked(_ on: Bool) {
		withAnimation(RescrivaMotion.ui) {
			onlyMarked = on
			// Pages the filter hides can't stay chosen.
			if on { selection.formIntersection(session.markedPageIndexes) }
		}
	}

	private var topBar: some View {
		HStack(spacing: 8) {
			Button { dismiss() } label: {
				Text("Done")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.vellum)
					.frame(height: 40)
					.padding(.horizontal, 18)
					.background(Color.ink, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
					.rescrivaShadow(.small)
			}
			.buttonStyle(PressScaleStyle(scale: 0.94))
			Text("Pages")
				.font(RescrivaFont.header(22))
				.foregroundStyle(.carbon)
				.accessibilityAddTraits(.isHeader)
			Spacer(minLength: 4)
			if session.canOrganize {
				CircleIconButton(systemName: "arrow.uturn.backward", label: "Undo") { session.undo() }
					.disabled(!session.canUndo)
					.opacity(session.canUndo ? 1 : 0.4)
				addMenu
				Button {
					withAnimation(RescrivaMotion.ui) {
						selecting.toggle()
						selection.removeAll()
					}
				} label: {
					Text(selecting ? "Cancel" : "Select")
						.font(RescrivaFont.ui(14, weight: .medium))
						.foregroundStyle(.carbon)
						.frame(height: 40)
						.padding(.horizontal, 14)
						.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
						.rescrivaShadow(.small)
				}
				.buttonStyle(PressScaleStyle(scale: 0.94))
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	private var addMenu: some View {
		Menu {
			Button { session.insertBlankPage(at: insertionIndex) } label: { Label("Blank page", systemImage: "doc") }
			Button { importingPhotos = true } label: { Label("Photos", systemImage: "photo") }
			Button { importingPDF = true } label: { Label("Pages from another PDF", systemImage: "doc.on.doc") }
		} label: {
			Glyph("plus", size: 17, weight: .regular)
				.foregroundStyle(.carbon)
				.frame(width: 40, height: 40)
				.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.rescrivaShadow(.small)
		}
		.accessibilityLabel("Add pages")
	}

	/// New pages go after the last chosen page, or at the end.
	private var insertionIndex: Int {
		(selection.max().map { $0 + 1 }) ?? session.document.pageCount
	}

	// MARK: Pages

	private func cell(_ page: PDFPage, index: Int) -> some View {
		let isSelected = selection.contains(index)
		return VStack(spacing: 6) {
			PDFPageThumbnail(page: page, session: session)
				.overlay(alignment: .topTrailing) {
					if selecting {
						Glyph(isSelected ? "checkmark.circle.fill" : "circle", size: 22)
							.foregroundStyle(isSelected ? Color.ink : Color.carbon.opacity(0.35))
							.background(Circle().fill(Color.vellum).padding(2))
							.padding(6)
					}
				}
				.overlay {
					RoundedRectangle(cornerRadius: 6, style: .continuous)
						.strokeBorder(isSelected ? Color.ink : Color.clear, lineWidth: 3)
				}
			Text("\(index + 1)")
				.font(RescrivaFont.ui(12, weight: .medium))
				.foregroundStyle(index == session.currentPageIndex ? Color.ink : Color.graphite)
				.monospacedDigit()
		}
		.contentShape(Rectangle())
		.onTapGesture {
			if selecting {
				if isSelected { selection.remove(index) } else { selection.insert(index) }
			} else {
				onGoToPage(index)
				dismiss()
			}
		}
		.draggable(String(index)) {
			PDFPageThumbnail(page: page, session: session)
				.frame(width: 80)
		}
		.dropDestination(for: String.self) { items, _ in
			guard session.canOrganize, let from = items.first.flatMap(Int.init), from != index else { return false }
			withAnimation(RescrivaMotion.ui) { session.movePage(from: from, to: index) }
			selection.removeAll()
			return true
		}
		.accessibilityElement(children: .combine)
		.accessibilityLabel(Text("Page \(index + 1)"))
		.accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
		.accessibilityActions {
			if session.canOrganize {
				if index > 0 {
					Button("Move earlier") { session.movePage(from: index, to: index - 1) }
				}
				if index < session.document.pageCount - 1 {
					Button("Move later") { session.movePage(from: index, to: index + 1) }
				}
			}
		}
	}

	private var selectionBar: some View {
		FrostedBottomBar {
			HStack(spacing: 0) {
				barButton("rotate.left", label: "Rotate left") { session.rotate(Array(selection), degrees: -90) }
				barButton("rotate.right", label: "Rotate right") { session.rotate(Array(selection), degrees: 90) }
				barButton("square.and.arrow.up.on.square", label: "Save as new PDF") { extractSelection() }
				barButton("trash", label: "Delete", tint: .vermilion) { confirmingDelete = true }
					.disabled(selection.count >= session.document.pageCount)
			}
			.disabled(selection.isEmpty)
			.opacity(selection.isEmpty ? 0.4 : 1)
			Text(selection.isEmpty ? "Choose pages, or drag one to move it" :
					(selection.count == 1 ? "1 page chosen" : "\(selection.count) pages chosen"))
				.font(RescrivaFont.note(14))
				.foregroundStyle(.graphite)
		}
	}

	private func barButton(_ systemName: String, label: LocalizedStringKey, tint: Color = .carbon, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(spacing: 4) {
				Glyph(systemName, size: 19)
				Text(label)
					.font(RescrivaFont.ui(11, weight: .medium))
			}
			.foregroundStyle(tint)
			.frame(maxWidth: .infinity)
			.contentShape(Rectangle())
		}
		.buttonStyle(PressScaleStyle())
	}

	// MARK: Actions

	private func deleteSelection() {
		session.deletePages(Array(selection))
		selection.removeAll()
	}

	private func extractSelection() {
		guard let data = session.extractedPDF(Array(selection)) else { return }
		onExtract(data, selection.count)
		selection.removeAll()
	}

	private func insertPDF(_ url: URL) {
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		var coordinationError: NSError?
		var other: PDFDocument?
		NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
			other = PDFDocument(url: readable)
		}
		guard let other else {
			problem = String(localized: "That file isn't a PDF Rescriva can open.")
			return
		}
		guard !other.isLocked else {
			problem = String(localized: "That PDF is locked with a password. Open it in Rescriva first, then save its pages as a new PDF.")
			return
		}
		withAnimation(RescrivaMotion.ui) { session.insertPages(of: other, at: insertionIndex) }
	}

	private func insertPhotos(_ items: [PhotosPickerItem]) {
		let index = insertionIndex
		Task {
			var images: [UIImage] = []
			for item in items {
				if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
					images.append(image.normalizedUp())
				}
			}
			photoItems = []
			guard !images.isEmpty else {
				problem = String(localized: "Those photos couldn't be opened.")
				return
			}
			withAnimation(RescrivaMotion.ui) { session.insertImages(images, at: index) }
		}
	}
}

/// A page drawn small. Drawing happens off the main thread (`PDFThumbnailRenderer`) and the
/// result is kept in the session until that page changes, so scrolling back is instant and a long
/// PDF scrolls without stalls.
struct PDFPageThumbnail: View {
	let page: PDFPage
	let session: PDFEditSession
	@Environment(\.displayScale) private var displayScale
	@State private var image: UIImage?

	/// The widest a grid cell gets, in points; thumbnails are drawn for it.
	static let width: CGFloat = 160

	var body: some View {
		let bounds = page.bounds(for: .cropBox)
		let quarterTurned = (page.rotation / 90) % 2 != 0
		let aspect = quarterTurned ? bounds.height / max(bounds.width, 1) : bounds.width / max(bounds.height, 1)
		let key = "\(ObjectIdentifier(page).hashValue)-\(session.version(of: page))-\(page.rotation)-\(Int(bounds.width))x\(Int(bounds.height))"
		ZStack {
			Color.paper
			if let image {
				Image(uiImage: image)
					.resizable()
					.scaledToFit()
			}
		}
		.aspectRatio(max(aspect, 0.2), contentMode: .fit)
		.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
		.shadow(color: Color.shade.opacity(0.18), radius: 2, x: 0, y: 1)
		.task(id: key) { await load(key: key, aspect: aspect) }
	}

	/// The kept thumbnail, or one drawn from a copy of the page (a copy, so the main thread's
	/// document is never read off it). A cell scrolled away cancels before drawing.
	private func load(key: String, aspect: CGFloat) async {
		if let kept = session.thumbnails.object(forKey: key as NSString) {
			image = kept
			return
		}
		guard let copy = page.copy() as? PDFPage else { return }
		let pixels = Self.width * max(displayScale, 2)
		let size = CGSize(width: pixels, height: pixels / max(aspect, 0.2))
		guard let drawn = await PDFThumbnailRenderer.shared.render(copy, size: size), !Task.isCancelled else { return }
		session.thumbnails.setObject(drawn, forKey: key as NSString)
		image = drawn
	}
}
