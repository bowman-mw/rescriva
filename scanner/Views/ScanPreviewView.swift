//
//  ScanPreviewView.swift
//  Rescriva (fork of Open Scanner)
//
//  What opens when you tap a scan: a calm, read-only look at it — the rebuilt
//  document for Word and Slides scans, the pages for everything — with Edit
//  (Scan & pages), Annotate and Share at the top. Long-press a page to
//  annotate or adjust it.
//

import SwiftUI

/// What the preview shows.
enum PreviewMode: String, CaseIterable {
	case document, pages

	var label: LocalizedStringKey {
		switch self {
		case .document: return "Document"
		case .pages: return "Pages"
		}
	}
}

struct ScanPreviewView: View {
	@Environment(RescrivaRouter.self) private var router
	@ObservedObject var scan: Scan

	@State private var mode: PreviewMode
	@State private var exportRequest: ExportRequest?
	@State private var zoomedPage: ScanCapture?
	@State private var annotateRequest: AnnotateRequest?
	@State private var adjustingPage: ScanCapture?

	init(scan: Scan) {
		self.scan = scan
		_mode = State(initialValue: scan.isRebuilt ? .document : .pages)
	}

	var body: some View {
		ZStack {
			GrainBackground()
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					topBar
					header
					if document != nil {
						RescrivaSegmentedPicker(options: PreviewMode.allCases, selection: $mode) { $0.label }
							.padding(.horizontal, 16)
							.padding(.bottom, 14)
					}
					content
				}
				.padding(.bottom, 48)
			}
			.overlay(alignment: .top) { StatusBarScrim() }
			.fullScreenCover(item: $annotateRequest) { request in
				AnnotateView(request: request) {
					// Annotations sit on the pages, so show them there.
					withAnimation(RescrivaMotion.ui) { mode = .pages }
				}
			}
		}
		.sheet(item: $exportRequest) { request in
			ExportSheet(scan: scan, initialFormat: request.format) { message in router.showToast(message, style: .exported) }
		}
		.fullScreenCover(item: $zoomedPage) { capture in
			QuickLookView(scanCapture: capture)
		}
	}

	/// The rebuilt document, for scans headed to Word or Slides.
	private var document: RescrivaDocument? {
		scan.output == .pdf ? nil : scan.rebuiltDocument
	}

	private var topBar: some View {
		HStack {
			BackPill(title: "Scans") { router.pop() }
			Spacer()
			Button {
				router.push(.scan(scan))
			} label: {
				Text("Edit")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.carbon)
					.frame(height: 40)
					.padding(.horizontal, 16)
					.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
					.rescrivaShadow(.small)
			}
			.buttonStyle(PressScaleStyle(scale: 0.94))
			.accessibilityHint("Opens the pages, rebuild and look settings")
			if !scan.capturesArray.isEmpty {
				CircleIconButton(systemName: "pencil.tip.crop.circle", label: "Annotate") {
					annotate(startingAt: 0)
				}
			}
			CircleIconButton(systemName: "square.and.arrow.up", label: "Share") {
				exportRequest = ExportRequest(format: defaultExportFormat)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .firstTextBaseline, spacing: 10) {
				Text(scan.displayTitle)
					.font(RescrivaFont.header(26))
					.foregroundStyle(.carbon)
					.accessibilityAddTraits(.isHeader)
				Spacer(minLength: 0)
				Text(scan.output.chipLabel)
					.font(RescrivaFont.ui(11, weight: .medium))
					.foregroundStyle(.carbon)
					.padding(.vertical, 4)
					.padding(.horizontal, 9)
					.background(scan.output.chipColor, in: RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous))
			}
			Text(scan.detailMeta)
				.font(RescrivaFont.ui(12))
				.foregroundStyle(.graphite)
		}
		.padding(.horizontal, 20)
		.padding(.top, 10)
		.padding(.bottom, 16)
	}

	@ViewBuilder
	private var content: some View {
		if mode == .document, let document {
			RebuiltDocumentView(document: document, output: scan.output, selectedBlock: nil, activeFlag: nil,
								onSelectBlock: { _ in }, onOpenFlag: { _ in }, onToggleItem: { _, _ in })
				.environment(\.documentIsInteractive, false)
				.environment(\.figureImages, FigureImageSource(scan: scan))
				.padding(.vertical, 22)
				.padding(.horizontal, 20)
				.background(Color.paper, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
				.rescrivaShadow(.card)
				.padding(.horizontal, 16)
				.transition(.opacity)
		} else {
			pages
				.transition(.opacity)
		}
	}

	@ViewBuilder
	private var pages: some View {
		let captures = scan.capturesArray
		if captures.isEmpty {
			Text("No pages yet. Tap Edit to add some.")
				.font(RescrivaFont.note(16))
				.foregroundStyle(.graphite)
				.frame(maxWidth: .infinity)
				.padding(.vertical, 40)
		} else {
			LazyVStack(spacing: 22) {
				ForEach(Array(captures.enumerated()), id: \.element.objectID) { index, capture in
					PreviewPage(capture: capture, number: index + 1, look: scan.lookFilter) {
						zoomedPage = capture
					} onAnnotate: {
						annotate(startingAt: index)
					} onAdjust: {
						adjustingPage = capture
					}
				}
			}
			.padding(.horizontal, 20)
			.fullScreenCover(item: $adjustingPage) { capture in
				PageEditorView(capture: capture) { message in router.showToast(message) }
			}
		}
	}

	private func annotate(startingAt index: Int) {
		let pages = scan.annotationPages()
		guard !pages.isEmpty else { return }
		annotateRequest = AnnotateRequest(pages: pages, startIndex: index)
	}

	private var defaultExportFormat: ExportFormat {
		guard DeviceTier.current.canRebuild, scan.isRebuilt else { return .pdf }
		return scan.output == .pptx ? .pptx : .docx
	}
}

/// One page in the preview: the scan on paper, with its look applied as the export applies it.
private struct PreviewPage: View {
	@ObservedObject var capture: ScanCapture
	let number: Int
	let look: LookFilter
	let onOpen: () -> Void
	let onAnnotate: () -> Void
	let onAdjust: () -> Void

	var body: some View {
		VStack(spacing: 8) {
			Button(action: onOpen) {
				pageImage
					.overlay { MarksOverlay(marks: capture.pageMarks) }
					.background(Color.paper)
					.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
					.shadow(color: Color.shade.opacity(0.10), radius: 4, x: 0, y: 2)
					.shadow(color: Color.shade.opacity(0.10), radius: 14, x: 0, y: 12)
			}
			.buttonStyle(PressScaleStyle(scale: 0.98))
			.contextMenu {
				Button("Annotate", systemImage: "pencil.tip.crop.circle", action: onAnnotate)
				Button(action: onAdjust) {
					Label("Adjust page", systemImage: "crop.rotate")
				}
			}
			.accessibilityLabel("Page \(number)")
			.accessibilityHint("Opens the full page")
			.accessibilityAction(named: "Annotate", onAnnotate)
			.accessibilityAction(named: "Adjust page", onAdjust)
			Text("Page \(number)")
				.font(RescrivaFont.ui(12))
				.foregroundStyle(.graphite)
		}
	}

	/// The page as the PDF will have it (see `LookedPage`).
	private var pageImage: some View {
		LookedPage(capture: capture, look: look, maxPixels: LookPreviewRenderer.previewPixels) { image, isFinal in
			if let image {
				Image(uiImage: image).resizable().scaledToFit()
					.lookStandIn(isFinal ? .original : look)
			} else {
				PaperThumbnail(image: nil, width: 260, height: 340)
			}
		}
	}
}
