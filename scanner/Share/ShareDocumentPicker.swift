//
//  ShareDocumentPicker.swift
//  Rescriva (fork of Open Scanner)
//
//  "Add documents" on the Share Nearby screen: a sheet listing the scans (newest
//  first, Recently Deleted left out) and the PDFs in the library, to tick any
//  number of and share. Scans go out as searchable PDFs. Anything already shared
//  shows ticked and can't be added twice.
//

import CoreData
import SwiftUI

struct ShareDocumentPicker: View {
	/// Shown ticked and fixed.
	let alreadyShared: [NearbyShareItem]
	let onAdd: ([NearbyShareItem]) -> Void

	@Environment(\.dismiss) private var dismiss
	@FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Scan.timestamp, ascending: false)],
				  predicate: LibraryScope.livePredicate)
	private var scans: FetchedResults<Scan>
	@State private var selection: Set<NearbyShareItem> = []
	private let library = PDFLibrary.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SheetHeader(title: String(localized: "Add documents"),
						subtitle: String(localized: "Scans are shared as searchable PDFs."),
						trailing: (String(localized: "Cancel"), { dismiss() }))
			if scans.isEmpty && library.items.isEmpty {
				Text("Nothing in the library yet. Scan a page or open a PDF, and it can be shared from here.")
					.font(RescrivaFont.note(16))
					.foregroundStyle(.graphite)
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			} else {
				list
			}
			PrimaryButton(title: addTitle, systemImage: "plus") {
				onAdd(chosen)
				dismiss()
			}
			.disabled(selection.isEmpty)
			.opacity(selection.isEmpty ? 0.45 : 1)
		}
		.padding(.horizontal, 20)
		.padding(.top, 16)
		.padding(.bottom, 12)
		.presentationDetents([.medium, .large])
		.presentationDragIndicator(.visible)
		.presentationCornerRadius(RescrivaRadius.large)
		.presentationBackground(Color.vellum)
	}

	private var list: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 6) {
				if !scans.isEmpty {
					sectionLabel("Scans")
					ForEach(scans, id: \.objectID) { scan in
						row(.scan(scan), title: scan.displayTitle, detail: scan.libraryMeta,
							thumbnail: scan.coverThumbnail)
					}
				}
				if !library.items.isEmpty {
					sectionLabel("PDFs")
					ForEach(library.items) { item in
						row(.pdf(item.id), title: item.title.isEmpty ? String(localized: "Untitled") : item.title,
							detail: item.libraryMeta, thumbnail: nil)
					}
				}
			}
			.padding(.vertical, 2)
		}
		.scrollBounceBehavior(.basedOnSize)
	}

	private func sectionLabel(_ title: LocalizedStringKey) -> some View {
		Text(title)
			.rescrivaSectionLabel()
			.padding(.horizontal, 4)
			.padding(.top, 10)
			.padding(.bottom, 2)
			.accessibilityAddTraits(.isHeader)
	}

	/// One document: its first page, title and meta, with a tick when chosen.
	private func row(_ item: NearbyShareItem, title: String, detail: String, thumbnail: UIImage?) -> some View {
		let shared = alreadyShared.contains(item)
		let chosen = shared || selection.contains(item)
		return Button {
			guard !shared else { return }
			withAnimation(RescrivaMotion.fast) {
				if selection.contains(item) { selection.remove(item) } else { selection.insert(item) }
			}
		} label: {
			HStack(spacing: 12) {
				PaperThumbnail(image: thumbnail, width: 34, height: 44, ink: .carbon)
				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.font(RescrivaFont.ui(15, weight: .medium))
						.foregroundStyle(.carbon)
						.lineLimit(2)
					Text(shared ? String(localized: "Already shared") : detail)
						.font(RescrivaFont.ui(12))
						.foregroundStyle(.graphite)
				}
				Spacer(minLength: 8)
				tick(chosen)
			}
			.padding(.vertical, 10)
			.padding(.horizontal, 12)
			.background(chosen ? Color.wash.opacity(0.5) : Color.stock,
						in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			.opacity(shared ? 0.55 : 1)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(shared)
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(chosen ? .isSelected : [])
	}

	private func tick(_ on: Bool) -> some View {
		ZStack {
			RoundedRectangle(cornerRadius: 6, style: .continuous)
				.strokeBorder(on ? Color.ink : Color.carbon.opacity(0.3), lineWidth: 1.5)
			if on {
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.fill(Color.ink)
				Glyph("checkmark", size: 10, weight: .bold)
					.foregroundStyle(.vellum)
			}
		}
		.frame(width: 22, height: 22)
		.accessibilityHidden(true)
	}

	/// The chosen documents in the order they're listed.
	private var chosen: [NearbyShareItem] {
		let scanned = scans.map { NearbyShareItem.scan($0) }
		let pdfs = library.items.map { NearbyShareItem.pdf($0.id) }
		return (scanned + pdfs).filter { selection.contains($0) }
	}

	private var addTitle: LocalizedStringKey {
		switch selection.count {
		case 0: return "Share"
		case 1: return "Share 1 document"
		default: return "Share \(selection.count) documents"
		}
	}
}
