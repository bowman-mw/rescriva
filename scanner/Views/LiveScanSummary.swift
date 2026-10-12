//
//  LiveScanSummary.swift
//  Open Scanner → Rescriva
//
//  Created by Slaven Radic on 2024-09-01.
//  Rescriva: "Scan & pages" — title, what to make it into, the pages (reorder,
//  remove, add more), the look, and the primary action.
//

import SwiftUI
import CoreData
import QuickLook

struct LiveScanSummary: View {
	@Environment(\.managedObjectContext) private var viewContext
	@Environment(RescrivaRouter.self) private var router

	@ObservedObject var scan: Scan

	@AppStorage(RescrivaPreference.companionTips) private var companionTips = true
	@State private var titleValue = ""
	@State private var reordering = false
	@State private var exportRequest: ExportRequest?
	/// The PDF this scan was imported from, when this iPhone kept it.
	@State private var originalPDF: URL?
	@State private var previewedOriginal: URL?
	@FocusState private var titleFocused: Bool

	private let tier = DeviceTier.current

	var body: some View {
		ZStack(alignment: .bottom) {
			GrainBackground()

			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					topBar
					titleSection
					ReadingStatus(scan: scan)
					if companionTips && tier.canRebuild {
						MarginNote(text: scan.companionTip)
							.padding(.horizontal, 20)
							.padding(.top, 14)
					}
					outputSection
					pagesSection
					lookSection
				}
				.padding(.bottom, 150)
			}
			.overlay(alignment: .top) { StatusBarScrim() }
			.scrollDismissesKeyboard(.immediately)

			FrostedBottomBar {
				PrimaryButton(title: primaryLabel, action: primaryAction)
			}
		}
		.onAppear {
			titleValue = scan.title ?? ""
			originalPDF = PDFImport.original(for: scan)
		}
		.onChange(of: scan.title) { _, newTitle in
			// OCR may suggest a title after the screen opened.
			if !titleFocused { titleValue = newTitle ?? "" }
		}
		.onDisappear { commitTitle() }
		.sheet(item: $exportRequest) { request in
			ExportSheet(scan: scan, initialFormat: request.format) { message in router.showToast(message, style: .exported) }
		}
		.quickLookPreview($previewedOriginal)
	}

	// MARK: Sections

	private var topBar: some View {
		HStack {
			BackPill(title: backTitle) {
				commitTitle()
				router.pop()
			}
			Spacer()
			Button {
				withAnimation(RescrivaMotion.ui) { reordering.toggle() }
			} label: {
				Text(reordering ? "Done" : "Edit")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(reordering ? Color.vellum : Color.carbon)
					.frame(height: 40)
					.padding(.horizontal, 14)
					.background(reordering ? Color.ink : Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
					.rescrivaShadow(.small)
			}
			.buttonStyle(PressScaleStyle(scale: 0.94))
			.accessibilityLabel(reordering ? "Done editing pages" : "Edit pages")
			CircleIconButton(systemName: "square.and.arrow.up", label: "Share") {
				commitTitle()
				exportRequest = ExportRequest(format: .pdf)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	private var titleSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			TextField("Scan title", text: $titleValue)
				.font(RescrivaFont.header(26))
				.foregroundStyle(.carbon)
				.focused($titleFocused)
				.submitLabel(.done)
				.onSubmit(commitTitle)
				.padding(.top, 6)
				.padding(.bottom, 8)
				.overlay(alignment: .bottom) {
					Rectangle().fill(Color.carbon.opacity(0.15)).frame(height: 1)
				}
			HStack(alignment: .firstTextBaseline) {
				Text(scan.detailMeta)
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
				Spacer(minLength: 8)
				if let originalPDF {
					Button("View original") { previewedOriginal = originalPDF }
						.font(RescrivaFont.ui(13, weight: .medium))
						.foregroundStyle(.ink)
						.accessibilityHint("Opens the PDF this scan was imported from")
				}
			}
		}
		.padding(.horizontal, 20)
		.padding(.top, 10)
		.padding(.bottom, 4)
	}

	private var outputSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Make it into").rescrivaSectionLabel()
			HStack(spacing: 8) {
				ForEach(OutputKind.allCases) { kind in
					OutputCard(kind: kind, tier: tier, isSelected: scan.output == kind) {
						withAnimation(RescrivaMotion.ui) { scan.output = kind }
						viewContext.saveQuietly()
					}
				}
			}
			if !tier.canRebuild {
				Text("Rebuilding needs a newer iPhone. Searchable PDFs work everywhere.")
					.font(RescrivaFont.ui(12))
					.lineSpacing(2)
					.foregroundStyle(.graphite)
			}
		}
		.padding(.horizontal, 20)
		.padding(.top, 12)
	}

	private var pagesSection: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(alignment: .firstTextBaseline) {
				Text("Pages").rescrivaSectionLabel()
				Spacer()
				Button("Add pages") {
					commitTitle()
					router.push(.camera(scan.pageSource == .whiteboard ? .whiteboard : .document, appendingTo: scan))
				}
				.font(RescrivaFont.ui(13, weight: .medium))
				.foregroundStyle(.ink)
			}
			.padding(.horizontal, 20)
			.padding(.top, 20)
			.padding(.bottom, 6)

			// Lazy, so a long imported PDF renders the looks of the rows on screen, not of every page at once.
			LazyVStack(spacing: 8) {
				let captures = scan.capturesArray
				ForEach(Array(captures.enumerated()), id: \.element.objectID) { index, capture in
					PageRow(capture: capture, number: index + 1, look: scan.lookFilter, reordering: reordering,
							canMoveUp: index > 0, canRemove: captures.count > 1,
							onOpen: { router.push(.page(scan, capture)) },
							onMoveUp: { moveUp(index) },
							onRemove: { remove(capture) })
				}
			}
			.padding(.horizontal, 16)
		}
	}

	private var lookSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Look").rescrivaSectionLabel()
			HStack(spacing: 8) {
				ForEach(LookFilter.allCases) { look in
					ChoiceChip(label: look.label, isSelected: scan.lookFilter == look, fillsWidth: true) {
						scan.lookFilter = look
						viewContext.saveQuietly()
					}
				}
			}
		}
		.padding(.horizontal, 20)
		.padding(.top, 18)
	}

	// MARK: Copy

	/// "Preview" when Edit opened this screen, "Scans" after a new capture or import.
	private var backTitle: LocalizedStringKey {
		if case .preview = router.routeBelow(.scan(scan)) { return "Preview" }
		return "Scans"
	}

	private var primaryLabel: LocalizedStringKey {
		switch scan.output {
		case .pdf: return "Save searchable PDF"
		case .docx: return "Rebuild as Word"
		case .pptx: return "Rebuild as Slides"
		}
	}

	// MARK: Actions

	private func primaryAction() {
		commitTitle()
		if scan.output == .pdf {
			exportRequest = ExportRequest(format: .pdf)
		} else {
			router.push(.processing(scan))
		}
	}

	private func commitTitle() {
		let trimmed = titleValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != scan.title else { return }
		scan.title = trimmed
		scan.lastUpdate = Date()
		viewContext.saveQuietly()
	}

	private func moveUp(_ index: Int) {
		var pages = scan.capturesArray
		guard index > 0, index < pages.count else { return }
		withAnimation(RescrivaMotion.ui) {
			pages.swapAt(index - 1, index)
			for (order, capture) in pages.enumerated() {
				capture.order = Int32(order)
			}
			scan.lastUpdate = Date()
		}
		viewContext.saveQuietly()
	}

	private func remove(_ capture: ScanCapture) {
		guard scan.capturesArray.count > 1 else { return }
		var files = DeletedFiles()
		withAnimation(RescrivaMotion.ui) {
			files = capture.deleteWithOriginal()
			viewContext.processPendingChanges()
			scan.renumberPages()
		}
		// The page's original and marks go only once its deletion is saved.
		viewContext.saveDeletion(removing: files)
	}
}

/// "Reading page 3 of 12" with a spinner while the scan's pages are still
/// being read, so a long PDF doesn't look stuck.
private struct ReadingStatus: View {
	@ObservedObject var scan: Scan

	var body: some View {
		let total = scan.capturesArray.count
		let waiting = scan.capturesArray.filter { RecognitionTracker.shared.isReading($0) }.count
		if waiting > 0 {
			HStack(spacing: 12) {
				ProgressView().tint(.ink)
				VStack(alignment: .leading, spacing: 7) {
					Text(label(done: total - waiting, total: total))
						.font(RescrivaFont.ui(13, weight: .medium))
						.foregroundStyle(.carbon)
						.monospacedDigit()
					ProgressView(value: Double(total - waiting), total: Double(max(total, 1)))
						.tint(.ink)
				}
			}
			.padding(.vertical, 12)
			.padding(.horizontal, 16)
			.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
			.rescrivaShadow(.small)
			.padding(.horizontal, 20)
			.padding(.top, 12)
			.transition(.opacity)
			.accessibilityElement(children: .combine)
		}
	}

	private func label(done: Int, total: Int) -> String {
		total > 1 ? String(localized: "Reading page \(min(done + 1, total)) of \(total)…") : String(localized: "Reading the page…")
	}
}

/// Which export to open, for `.sheet(item:)`.
struct ExportRequest: Identifiable {
	let id = UUID()
	let format: ExportFormat
}

/// One of the three "Make it into" cards.
private struct OutputCard: View {
	let kind: OutputKind
	let tier: DeviceTier
	let isSelected: Bool
	let action: () -> Void

	private var locked: Bool { kind != .pdf && !tier.canRebuild }

	var body: some View {
		Button {
			if !locked { action() }
		} label: {
			VStack(alignment: .leading, spacing: 6) {
				Glyph(icon, size: 20, weight: .light)
					.foregroundStyle(isSelected ? Color.vellum : Color.ink)
				Text(title)
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(isSelected ? Color.vellum : Color.carbon)
				Text(detail)
					.font(RescrivaFont.ui(11))
					.lineSpacing(1)
					.foregroundStyle(isSelected ? Color.vellum.opacity(0.8) : Color.graphite)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, 12)
			.padding(.horizontal, 10)
			.background(isSelected ? Color.ink : Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
			.shadow(color: Color.shade.opacity(isSelected ? 0.24 : 0.08), radius: isSelected ? 9 : 4, x: 0, y: isSelected ? 6 : 2)
			.opacity(locked ? 0.4 : 1)
			.animation(RescrivaMotion.ui, value: isSelected)
		}
		.buttonStyle(PressScaleStyle(scale: 0.94))
		.disabled(locked)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
		.accessibilityHint(locked ? Text("Needs a newer iPhone") : Text(""))
	}

	private var icon: String {
		switch kind {
		case .pdf: return "doc"
		case .docx: return "doc.text"
		case .pptx: return "rectangle.on.rectangle"
		}
	}

	private var title: LocalizedStringKey {
		switch kind {
		case .pdf: return "PDF"
		case .docx: return "Word"
		case .pptx: return "Slides"
		}
	}

	private var detail: LocalizedStringKey {
		switch kind {
		case .pdf: return "Searchable, any iPhone"
		case .docx: return tier == .smart ? "Text, tables, diagrams" : "Text and tables"
		case .pptx: return "Layout, colors, shapes"
		}
	}
}

/// A page in the list: thumbnail, number, a peek at its text, and the
/// reorder controls while editing. While its text is being read, a scan bar
/// passes down the thumbnail.
private struct PageRow: View {
	@ObservedObject var capture: ScanCapture
	let number: Int
	let look: LookFilter
	let reordering: Bool
	let canMoveUp: Bool
	let canRemove: Bool
	let onOpen: () -> Void
	let onMoveUp: () -> Void
	let onRemove: () -> Void

	var body: some View {
		HStack(spacing: 14) {
			LookThumbnail(capture: capture, look: look, width: 50, height: 66)
				.overlay {
					if RecognitionTracker.shared.isReading(capture) {
						ScanLineLoop(color: .highlighter, trail: 22)
							.clipShape(FoldedSheet(radius: 3, fold: 8))
							.transition(.opacity)
					}
				}
			VStack(alignment: .leading, spacing: 3) {
				Text("Page \(number)")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.carbon)
				Text(preview)
					.font(RescrivaFont.body(14, italic: true))
					.foregroundStyle(Color.carbon.opacity(0.72))
					.lineLimit(2)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			if reordering {
				VStack(spacing: 2) {
					Button(action: onMoveUp) {
						Glyph("chevron.up", size: 14, weight: .semibold)
							.foregroundStyle(.carbon)
							.frame(width: 32, height: 26)
							.background(Color.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
					}
					.opacity(canMoveUp ? 1 : 0.35)
					.disabled(!canMoveUp)
					.accessibilityLabel("Move page \(number) up")
					Button(action: onRemove) {
						Glyph("xmark", size: 13, weight: .semibold)
							.foregroundStyle(.vermilion)
							.frame(width: 32, height: 26)
							.background(Color.vermilion.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
					}
					.opacity(canRemove ? 1 : 0.35)
					.disabled(!canRemove)
					.accessibilityLabel("Remove page \(number)")
				}
				.transition(.opacity)
			}
		}
		.padding(10)
		.paperCard(fold: 12)
		.contentShape(Rectangle())
		.onTapGesture {
			if !reordering { onOpen() }
		}
		.accessibilityElement(children: reordering ? .contain : .combine)
		.accessibilityAddTraits(reordering ? [] : .isButton)
	}

	private var preview: String {
		let text = capture.textPreview.trimmingCharacters(in: .whitespaces)
		if !text.isEmpty { return text }
		return RecognitionTracker.shared.isReading(capture) ? String(localized: "Reading…") : String(localized: "No words on this page")
	}
}

/// A thumbnail with the scan's look applied as the export applies it (see `LookedPage`), so the
/// choice is visible at once.
struct LookThumbnail: View {
	@ObservedObject var capture: ScanCapture
	let look: LookFilter
	let width: CGFloat
	let height: CGFloat

	var body: some View {
		LookedPage(capture: capture, look: look, maxPixels: LookPreviewRenderer.thumbnailPixels) { image, isFinal in
			thumbnail(image, standingIn: isFinal ? .original : look)
		}
	}

	/// The thumbnail dressed as a likeness of `look` while the real one renders.
	@ViewBuilder
	private func thumbnail(_ image: UIImage?, standingIn look: LookFilter) -> some View {
		switch look {
		case .color:
			PaperThumbnail(image: image, width: width, height: height, contrast: 1.05, saturation: 1.08)
		case .gray:
			PaperThumbnail(image: image, width: width, height: height, grayscale: 1, contrast: 1.05)
		case .blackAndWhite:
			PaperThumbnail(image: image, width: width, height: height, grayscale: 1, contrast: 1.8)
		case .ink, .original:
			PaperThumbnail(image: image, width: width, height: height)
		}
	}
}
