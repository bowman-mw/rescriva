//
//  WorkspaceDetail.swift
//  Rescriva (fork of Open Scanner)
//
//  The chosen scan in the wide-screen Library (Workspace): its title and pages in the middle, and
//  "Make it into" — PDF, Word or Slides, the companion's read on the pages, Compare and the rebuild
//  button — beside them in landscape, in a sheet below in portrait, or as just the two buttons on
//  the unfolded Duo.
//

import SwiftUI

/// The chosen scan's title, Add pages, and its pages in a grid.
struct WorkspaceScanDetail: View {
	@ObservedObject var scan: Scan
	let titleSize: CGFloat

	@Environment(RescrivaRouter.self) private var router
	@State private var zoomedPage: ScanCapture?
	@State private var annotateRequest: AnnotateRequest?
	@State private var adjustingPage: ScanCapture?
	@State private var exportRequest: ExportRequest?
	@State private var addingFiles = false

	/// Pages per row.
	static let columns = 3
	/// How far each page in a row leans, in degrees: paper laid out by hand.
	static let leans: [Double] = [-1, 0.8, -0.5]

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			header
			ScrollView { pages.padding(.bottom, 24) }
		}
		.padding(EdgeInsets(top: 24, leading: 28, bottom: 0, trailing: 28))
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.fullScreenCover(item: $zoomedPage) { capture in QuickLookView(scanCapture: capture) }
		.fullScreenCover(item: $annotateRequest) { request in AnnotateView(request: request) }
		.fullScreenCover(item: $adjustingPage) { capture in
			PageEditorView(capture: capture) { message in router.showToast(message) }
		}
		.sheet(item: $exportRequest) { request in
			ExportSheet(scan: scan, initialFormat: request.format) { message in router.showToast(message, style: .exported) }
		}
		.fileImporter(isPresented: $addingFiles, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in
			if case .success(let urls) = result { addPages(from: urls) }
		}
	}

	/// The title with Add pages and More beside it, or below it when the column is too narrow
	/// for both (half of the unfolded Duo).
	private var header: some View {
		ViewThatFits(in: .horizontal) {
			HStack(alignment: .bottom, spacing: 10) {
				titleBlock
				Spacer(minLength: 0)
				actions
			}
			VStack(alignment: .leading, spacing: 12) {
				titleBlock
				actions
			}
		}
	}

	private var titleBlock: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(scan.displayTitle)
				.font(RescrivaFont.header(titleSize))
				.foregroundStyle(.carbon)
				.lineLimit(2)
				.accessibilityAddTraits(.isHeader)
			Text(scan.detailMeta)
				.font(RescrivaFont.ui(13))
				.foregroundStyle(.graphite)
				.lineLimit(1)
		}
	}

	private var actions: some View {
		HStack(spacing: 10) {
			Button(action: addPages) {
				Text("Add pages")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.carbon)
					.padding(.horizontal, 14)
					.frame(height: 36)
					.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
					.rescrivaShadow(.small)
			}
			.buttonStyle(PressScaleStyle(scale: 0.94))
			menu
		}
		.fixedSize()
	}

	private var menu: some View {
		Menu {
			Button { router.push(.preview(scan)) } label: { Label("Open", systemImage: "doc.text.magnifyingglass") }
			Button { router.push(.scan(scan)) } label: { Label("Edit pages and look", systemImage: "square.and.pencil") }
			if !scan.capturesArray.isEmpty {
				Button { annotate(startingAt: 0) } label: { Label("Annotate", systemImage: "pencil.tip.crop.circle") }
			}
			Button { exportRequest = ExportRequest(format: .pdf) } label: { Label("Share", systemImage: "square.and.arrow.up") }
		} label: {
			Glyph("ellipsis", size: 17, weight: .regular)
				.foregroundStyle(.carbon)
				.frame(width: 36, height: 36)
				.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.rescrivaShadow(.small)
		}
		.accessibilityLabel("More")
	}

	@ViewBuilder
	private var pages: some View {
		let captures = scan.capturesArray
		if captures.isEmpty {
			Text("No pages yet. Tap Add pages to scan some.")
				.font(RescrivaFont.note(16))
				.foregroundStyle(.graphite)
				.frame(maxWidth: .infinity)
				.padding(.vertical, 40)
		} else {
			LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: Self.columns), spacing: 22) {
				ForEach(Array(captures.enumerated()), id: \.element.objectID) { index, capture in
					WorkspacePageTile(capture: capture, number: index + 1, look: scan.lookFilter,
									  lean: Self.leans[index % Self.leans.count]) {
						zoomedPage = capture
					} onAnnotate: {
						annotate(startingAt: index)
					} onAdjust: {
						adjustingPage = capture
					}
				}
			}
			.padding(.top, 4)
		}
	}

	private func annotate(startingAt index: Int) {
		let pages = scan.annotationPages()
		guard !pages.isEmpty else { return }
		annotateRequest = AnnotateRequest(pages: pages, startIndex: index)
	}

	/// Scans more pages with the camera; on a Mac, which has none, adds them from files.
	private func addPages() {
		guard ProcessInfo.processInfo.isMacCatalystApp else {
			router.push(.camera(.document, appendingTo: scan))
			return
		}
		addingFiles = true
	}

	/// Adds the images, and each PDF's pages, to the end of the scan.
	private func addPages(from urls: [URL]) {
		Task {
			let pages = await FileImport.pages(from: urls)
			guard !pages.isEmpty, let context = scan.managedObjectContext else {
				router.showToast(String(localized: "Those files couldn't be opened."))
				return
			}
			scan.append(pages, in: context)
		}
	}
}

/// One page in the grid: the scan on paper with its look, leaning a little, and its number.
struct WorkspacePageTile: View {
	@ObservedObject var capture: ScanCapture
	let number: Int
	let look: LookFilter
	let lean: Double
	let onOpen: () -> Void
	let onAnnotate: () -> Void
	let onAdjust: () -> Void

	var body: some View {
		VStack(spacing: 8) {
			Button(action: onOpen) {
				LookedPage(capture: capture, look: look, maxPixels: LookPreviewRenderer.previewPixels) { image, isFinal in
					if let image {
						Image(uiImage: image).resizable().scaledToFit().lookStandIn(isFinal ? .original : look)
					} else {
						PaperThumbnail(image: nil, width: 180, height: 240)
					}
				}
				.overlay { MarksOverlay(marks: capture.pageMarks) }
				.background(Color.paper)
				.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
				.rescrivaShadow(.card)
				.rotationEffect(.degrees(lean))
			}
			.buttonStyle(PressScaleStyle(scale: 0.98))
			.contextMenu {
				Button("Annotate", systemImage: "pencil.tip.crop.circle", action: onAnnotate)
				Button(action: onAdjust) { Label("Adjust page", systemImage: "crop.rotate") }
			}
			.accessibilityLabel("Page \(number)")
			.accessibilityHint("Opens the full page")
			Text("Page \(number)")
				.font(RescrivaFont.ui(13, weight: .medium))
				.foregroundStyle(.carbon)
		}
	}
}

/// "Make it into": the three outputs, the companion's read, Compare and the rebuild button.
struct WorkspaceInspector: View {
	/// How the inspector sits on the screen.
	enum Style {
		/// A column beside the pages (landscape).
		case column
		/// A sheet below the pages, its cards in a row (portrait).
		case sheet
		/// Just Compare and the rebuild button, below the pages (the unfolded Duo).
		case buttons
	}

	@ObservedObject var scan: Scan
	let style: Style

	@Environment(RescrivaRouter.self) private var router
	@AppStorage(RescrivaPreference.companionTips) private var companionTips = true
	@State private var exportRequest: ExportRequest?
	@State private var choosingComparison = false
	private let tier = DeviceTier.current

	var body: some View {
		content
			.sheet(item: $exportRequest) { request in
				ExportSheet(scan: scan, initialFormat: request.format) { message in router.showToast(message, style: .exported) }
			}
			.sheet(isPresented: $choosingComparison) {
				PDFComparePicker(current: .scan(scan)) { side in
					choosingComparison = false
					router.push(.pdfCompare(.scan(scan), side))
				}
				.presentationDetents([.medium, .large])
			}
	}

	@ViewBuilder
	private var content: some View {
		switch style {
		case .column:
			VStack(alignment: .leading, spacing: 14) {
				label
				ForEach(OutputKind.allCases) { kind in card(kind) }
				tip
				Spacer(minLength: 12)
				compareButton(height: 44)
				primaryButton(height: 44)
			}
			.padding(EdgeInsets(top: 28, leading: 20, bottom: 20, trailing: 20))
			.frame(maxHeight: .infinity, alignment: .top)
			.background(Color.vellum.opacity(0.6).ignoresSafeArea())
			.overlay(alignment: .leading) { Rectangle().fill(Color.carbon.opacity(0.08)).frame(width: 1).ignoresSafeArea() }
		case .sheet:
			VStack(alignment: .leading, spacing: 12) {
				tip.padding(.horizontal, 28)
				sheet
			}
		case .buttons:
			VStack(spacing: 10) {
				HStack(spacing: 8) {
					ForEach(OutputKind.allCases) { kind in card(kind, compact: true) }
				}
				compareButton(height: 48)
				primaryButton(height: 50)
			}
			.padding(EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20))
		}
	}

	/// The cards in a row and the two buttons, in a sheet across the bottom.
	private var sheet: some View {
		VStack(alignment: .leading, spacing: 14) {
			label
			HStack(spacing: 12) {
				ForEach(OutputKind.allCases) { kind in card(kind) }
			}
			HStack(spacing: 12) {
				compareButton(height: 50)
				primaryButton(height: 50)
			}
		}
		.padding(EdgeInsets(top: 20, leading: 28, bottom: 28, trailing: 28))
		.background(.ultraThinMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
		.background(Color.vellum.opacity(0.6), in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
		.rescrivaShadow(.sheet)
		.ignoresSafeArea(edges: .bottom)
	}

	private var label: some View {
		Text("Make it into")
			.font(RescrivaFont.ui(12, weight: .medium))
			.tracking(0.24)
			.foregroundStyle(.graphite)
	}

	@ViewBuilder
	private var tip: some View {
		if companionTips && tier.canRebuild {
			Text(scan.companionTip)
				.font(RescrivaFont.note(style == .sheet ? 16 : 15))
				.foregroundStyle(.carbon)
				.lineSpacing(3)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.vertical, 12)
				.padding(.horizontal, 16)
				.background(Color.vellum, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
				.rescrivaShadow(.card)
		}
	}

	private func card(_ kind: OutputKind, compact: Bool = false) -> some View {
		WorkspaceOutputCard(kind: kind, tier: tier, isSelected: scan.output == kind, compact: compact) {
			withAnimation(RescrivaMotion.ui) { scan.output = kind }
			scan.managedObjectContext?.saveQuietly()
		}
	}

	private func compareButton(height: CGFloat) -> some View {
		Button { choosingComparison = true } label: {
			Text("Compare with another PDF")
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(.carbon)
				.lineLimit(1)
				.minimumScaleFactor(0.85)
				.frame(maxWidth: .infinity)
				.frame(height: height)
				.overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.carbon.opacity(0.18), lineWidth: 1))
				.contentShape(Rectangle())
		}
		.buttonStyle(PressScaleStyle(scale: 0.96))
	}

	private func primaryButton(height: CGFloat) -> some View {
		Button(action: primaryAction) {
			Text(primaryLabel)
				.font(RescrivaFont.ui(15, weight: .medium))
				.foregroundStyle(Color.vellum)
				.lineLimit(1)
				.frame(maxWidth: .infinity)
				.frame(height: height)
				.background(Color.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
				.rescrivaShadow(.small)
		}
		.buttonStyle(PressScaleStyle(scale: 0.96))
	}

	private var primaryLabel: LocalizedStringKey {
		switch scan.output {
		case .pdf: return "Save searchable PDF"
		case .docx: return "Rebuild as Word"
		case .pptx: return "Rebuild as Slides"
		}
	}

	/// A PDF is saved from the export sheet; Word and Slides are rebuilt first.
	private func primaryAction() {
		if scan.output == .pdf {
			exportRequest = ExportRequest(format: .pdf)
		} else {
			router.push(.processing(scan))
		}
	}
}

/// One output in "Make it into": its name and what it keeps, ink when chosen.
struct WorkspaceOutputCard: View {
	let kind: OutputKind
	let tier: DeviceTier
	let isSelected: Bool
	/// Just the name, for the row above the Duo's buttons.
	var compact = false
	let action: () -> Void

	private var locked: Bool { kind != .pdf && !tier.canRebuild }

	var body: some View {
		Button { if !locked { action() } } label: {
			VStack(alignment: .leading, spacing: 2) {
				Text(kind.chipLabel)
					.font(RescrivaFont.ui(15, weight: .medium))
				if !compact {
					Text(detail)
						.font(RescrivaFont.ui(12))
						.opacity(0.8)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.foregroundStyle(isSelected ? Color.vellum : Color.carbon)
			.frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
			.padding(.vertical, compact ? 10 : 12)
			.padding(.horizontal, 14)
			.background(isSelected ? Color.ink : Color.vellum, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			.rescrivaShadow(.card)
			.opacity(locked ? 0.4 : 1)
		}
		.buttonStyle(PressScaleStyle(scale: 0.94))
		.disabled(locked)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
		.accessibilityHint(locked ? Text("Needs a newer iPhone") : Text(""))
	}

	private var detail: LocalizedStringKey {
		switch kind {
		case .pdf: return "Searchable, looks like the scan"
		case .docx: return tier == .smart ? "Text, tables, diagrams" : "Text and tables"
		case .pptx: return "Layout, colors, shapes"
		}
	}
}
