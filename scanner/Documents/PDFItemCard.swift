//
//  PDFItemCard.swift
//  Rescriva (fork of Open Scanner)
//
//  A PDF in the Library list, beside the scans: its first pages, title, meta,
//  a "PDF file" chip (plus the standard it claims, if any) and the favorite star.
//

import SwiftUI

struct PDFItemCard: View {
	let item: PDFItem
	let onOpen: () -> Void
	let onToggleFave: () -> Void

	@State private var pages: [UIImage] = []

	var body: some View {
		Button(action: onOpen) {
			VStack(alignment: .leading, spacing: 12) {
				thumbnails
				footer
			}
			.padding(.top, 14)
			.padding(.horizontal, 14)
			.padding(.bottom, 12)
			.paperCard()
		}
		.buttonStyle(PressScaleStyle(scale: 0.97))
		.accessibilityElement(children: .combine)
		.accessibilityLabel("\(item.title), PDF file, \(item.libraryMeta)\(item.fave ? ", favorite" : "")")
		.task(id: item.editedAt) { await loadPages() }
	}

	private var thumbnails: some View {
		HStack(alignment: .bottom, spacing: 10) {
			if pages.isEmpty {
				PaperThumbnail(image: nil, width: 46, height: 60, ink: .carbon)
			}
			ForEach(Array(pages.enumerated()), id: \.offset) { _, image in
				let wide = image.size.width > image.size.height
				PaperThumbnail(image: image, width: wide ? 84 : 46, height: wide ? 52 : 60, ink: .carbon)
			}
			Spacer(minLength: 0)
			if item.pageCount > 3 {
				VStack(spacing: 0) {
					Text("+\(item.pageCount - 3)")
						.font(RescrivaFont.ui(13, weight: .medium))
						.foregroundStyle(.carbon)
					Text("more")
						.font(RescrivaFont.ui(10))
						.foregroundStyle(.ink)
				}
				.frame(width: 40, height: 40)
				.background(Color.wash, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.frame(maxHeight: .infinity)
			}
		}
		.frame(minHeight: 62, alignment: .bottomLeading)
	}

	private var footer: some View {
		HStack(spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text(item.title)
					.font(RescrivaFont.header(18))
					.foregroundStyle(.carbon)
					.lineLimit(1)
				Text(item.libraryMeta)
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
			}
			Spacer(minLength: 4)
			Text("PDF file")
				.font(RescrivaFont.ui(11, weight: .medium))
				.foregroundStyle(.carbon)
				.padding(.vertical, 4)
				.padding(.horizontal, 9)
				.background(Color.carbon.opacity(0.08), in: RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous))
			Button(action: onToggleFave) {
				Glyph(item.fave ? "star.fill" : "star", size: 17, weight: .light)
					.foregroundStyle(item.fave ? Color.highlighter : Color.carbon.opacity(0.3))
					.frame(width: 32, height: 32)
					.contentShape(Rectangle())
			}
			.buttonStyle(PressScaleStyle())
			.accessibilityLabel(item.fave ? "Remove from favorites" : "Add to favorites")
		}
	}

	private func loadPages() async {
		var loaded: [UIImage] = []
		for index in 0..<min(item.pageCount, 3) {
			if let image = await PDFLibrary.shared.thumbnail(for: item, page: index, width: 84) {
				loaded.append(image)
			}
		}
		pages = loaded
	}
}
