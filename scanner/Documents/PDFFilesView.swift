//
//  PDFFilesView.swift
//  Rescriva (fork of Open Scanner)
//
//  "PDF Files": every PDF opened in Rescriva, newest first, as cards. Tap one to
//  read, find, mark up or organize it; long-press to favorite or delete it.
//  PDFs live as files (PDFLibrary), not in the scan store, so they don't go in
//  folders, tags or smart folders yet.
//

import SwiftUI
import UniformTypeIdentifiers

struct PDFFilesView: View {
	@Environment(RescrivaRouter.self) private var router
	private let library = PDFLibrary.shared
	@State private var importing = false
	@State private var isOpening = false
	@State private var toDelete: PDFItem?

	var body: some View {
		ZStack(alignment: .bottom) {
			GrainBackground()
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					topBar
					header
					LazyVStack(spacing: 12) {
						ForEach(library.items) { item in
							PDFItemCard(item: item) {
								router.push(.pdf(item.id, query: nil))
							} onToggleFave: {
								library.toggleFave(item)
							}
							.contextMenu { menu(item) }
						}
					}
					.padding(.horizontal, 16)
				}
				.padding(.bottom, 140)
			}
			.overlay(alignment: .top) { StatusBarScrim() }
			PrimaryButton(title: "Open a PDF", systemImage: "doc.badge.plus", isBusy: isOpening) { importing = true }
				.padding(.horizontal, 20)
				.padding(.bottom, 10)
		}
		.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
			if case .success(let urls) = result {
				isOpening = true
				Task {
					await PDFOpening.open(urls, in: library, router: router)
					isOpening = false
				}
			}
		}
		.confirmationDialog("Delete this PDF?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
							presenting: toDelete) { item in
			Button("Delete “\(item.title)”", role: .destructive) {
				router.forget(pdf: item.id)
				withAnimation(RescrivaMotion.ui) { library.delete(item) }
			}
		} message: { _ in
			Text("Rescriva's copy and your changes are removed from this iPhone. The file you opened it from isn't touched.")
		}
	}

	private var topBar: some View {
		HStack {
			BackPill(title: "Rescriva") { router.pop() }
			Spacer()
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 10) {
				Glyph(PDFOpening.symbol, size: 22)
					.foregroundStyle(PDFOpening.tint)
				Text("PDF Files")
					.font(RescrivaFont.header(28))
					.foregroundStyle(.carbon)
					.accessibilityAddTraits(.isHeader)
			}
			Text(library.items.count == 1 ? String(localized: "1 PDF") : String(localized: "\(library.items.count) PDFs"))
				.font(RescrivaFont.ui(12))
				.foregroundStyle(.graphite)
		}
		.padding(.horizontal, 20)
		.padding(.top, 8)
		.padding(.bottom, 14)
	}

	@ViewBuilder
	private func menu(_ item: PDFItem) -> some View {
		Button {
			library.toggleFave(item)
		} label: {
			Label(item.fave ? "Remove from favorites" : "Add to favorites", systemImage: item.fave ? "star.slash" : "star")
		}
		Button(role: .destructive) {
			toDelete = item
		} label: {
			Label("Delete", systemImage: "trash")
		}
	}
}

/// Opening PDFs from Files (or Dropbox, Drive, OneDrive): shared by the Scan
/// button's "Open a PDF" and the PDF Files screen.
@MainActor
enum PDFOpening {
	/// The PDF Files row's symbol and tint, here and in the Library.
	static let symbol = "doc.text"
	static let tint = Color.vermilion

	/// Copies each PDF into the Library; opens it when it's the only one, else says how many were added.
	static func open(_ urls: [URL], in library: PDFLibrary, router: RescrivaRouter) async {
		guard !urls.isEmpty else { return }
		var opened: [PDFItem] = []
		var failures = 0
		for url in urls {
			do {
				opened.append(try await library.importPDF(at: url))
			} catch {
				Log.library.error("Couldn't open a PDF: \(error)")
				failures += 1
			}
		}
		if opened.count == 1, failures == 0, let item = opened.first {
			router.push(.pdf(item.id, query: nil))
		} else if !opened.isEmpty {
			router.showToast(opened.count == 1 ? String(localized: "Added 1 PDF") : String(localized: "Added \(opened.count) PDFs"))
		} else {
			router.showToast(urls.count == 1 ? String(localized: "That PDF couldn't be opened.") : String(localized: "Those PDFs couldn't be opened."))
		}
	}
}
