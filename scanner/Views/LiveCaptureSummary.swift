//
//  LiveCaptureSummary.swift
//  Open Scanner → Rescriva
//
//  Created by Slaven Radic on 2024-09-01.
//  Rescriva: "Recognized text" for one page — the page, its lines (tap one for
//  Edit · Copy · Speak · Share · Delete), and detected links and addresses.
//  Adjust opens the page editor (crop, rotation, cleanup).
//

import SwiftUI
import UIKit
import CoreData

struct LiveCaptureSummary: View {
	@Environment(\.managedObjectContext) private var viewContext
	@Environment(RescrivaRouter.self) private var router

	@ObservedObject var scan: Scan
	@ObservedObject var capture: ScanCapture

	@State private var selected: ScanRecognizedItem?
	@State private var editing = false
	@State private var showingImage = false
	@State private var adjusting = false

	var body: some View {
		ZStack(alignment: .bottom) {
			GrainBackground()

			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					topBar
					pageImage
					HStack(alignment: .firstTextBaseline) {
						Text("Recognized text")
							.font(RescrivaFont.header(20))
							.foregroundStyle(.carbon)
							.accessibilityAddTraits(.isHeader)
						Spacer()
						Text("Tap a line")
							.font(RescrivaFont.ui(12))
							.foregroundStyle(.graphite)
					}
					.padding(.horizontal, 20)
					.padding(.top, 16)
					.padding(.bottom, 8)
					lines
					if let timestamp = capture.timestamp {
						Text("Captured \(timestamp.formatted(date: .abbreviated, time: .shortened))")
							.font(RescrivaFont.ui(12))
							.foregroundStyle(.graphite)
							.frame(maxWidth: .infinity, alignment: .trailing)
							.padding(.horizontal, 20)
							.padding(.top, 18)
					}
				}
				.padding(.bottom, 160)
			}
			.overlay(alignment: .top) { StatusBarScrim() }
			.scrollDismissesKeyboard(.interactively)

			if let selected, !editing {
				actionBar(for: selected)
					.padding(.horizontal, 16)
					.padding(.bottom, 8)
					.transition(.settle)
			}
		}
		.animation(RescrivaMotion.ui, value: selected)
		.fullScreenCover(isPresented: $showingImage) {
			QuickLookView(scanCapture: capture)
				.ignoresSafeArea()
		}
	}

	private var pageNumber: Int {
		(scan.capturesArray.firstIndex(of: capture) ?? 0) + 1
	}

	private var topBar: some View {
		HStack {
			BackPill(title: "Pages") {
				finishEditing()
				router.pop()
			}
			Spacer()
			Text("Page \(pageNumber) of \(scan.capturesArray.count)")
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(.carbon)
			Spacer()
			adjustButton
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	private var adjustButton: some View {
		Button {
			finishEditing()
			// Re-making the page deletes its lines, so the action bar mustn't outlive the selected one.
			selected = nil
			adjusting = true
		} label: {
			HStack(spacing: 5) {
				Glyph("crop.rotate", size: 14, weight: .regular)
				Text("Adjust")
					.font(RescrivaFont.ui(14, weight: .medium))
			}
			.foregroundStyle(.carbon)
			.frame(height: 40)
			.padding(.horizontal, 14)
			.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
			.rescrivaShadow(.small)
		}
		.buttonStyle(PressScaleStyle(scale: 0.94))
		.accessibilityLabel("Adjust page")
		.accessibilityHint("Fix the crop, turn the page or change its cleanup")
		.fullScreenCover(isPresented: $adjusting) {
			PageEditorView(capture: capture) { message in router.showToast(message) }
		}
	}

	private var pageImage: some View {
		Button {
			showingImage = true
		} label: {
			Group {
				if let image = capture.thumbnail {
					let aspect = image.aspectRatio
					let width: CGFloat = aspect > 1 ? 300 : 230
					Image(uiImage: capture.image ?? image)
						.resizable()
						.scaledToFill()
						.frame(width: width, height: min(300, width / max(aspect, 0.2)))
						.clipped()
				} else {
					PaperThumbnail(image: nil, width: 230, height: 300)
				}
			}
			.background(Color.paper)
			.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
			.shadow(color: Color.shade.opacity(0.10), radius: 4, x: 0, y: 2)
			.shadow(color: Color.shade.opacity(0.10), radius: 15, x: 0, y: 14)
			.rotationEffect(.degrees(-1))
		}
		.buttonStyle(PressScaleStyle(scale: 0.98))
		.frame(maxWidth: .infinity)
		.padding(.top, 14)
		.padding(.bottom, 6)
		.accessibilityLabel("Page \(pageNumber) image")
		.accessibilityHint("Opens the full page")
	}

	@ViewBuilder
	private var lines: some View {
		let items = capture.recognizedItemsArray
		if items.isEmpty {
			Text(RecognitionTracker.shared.isReading(capture) ? "Reading this page…" : "No words on this page.")
				.font(RescrivaFont.note(16))
				.foregroundStyle(.graphite)
				.frame(maxWidth: .infinity)
				.padding(.vertical, 24)
		} else {
			VStack(alignment: .leading, spacing: 6) {
				ForEach(items, id: \.objectID) { item in
					RecognizedItemView(item: item, isSelected: selected == item, isEditing: editing && selected == item) {
						if editing { finishEditing() }
						selected = selected == item ? nil : item
					} onEndEditing: {
						finishEditing()
					}
				}
			}
			.padding(.horizontal, 16)
		}
	}

	private func actionBar(for item: ScanRecognizedItem) -> some View {
		HStack(spacing: 0) {
			LineAction(title: "Edit", systemImage: "pencil") {
				editing = true
			}
			LineAction(title: "Copy", systemImage: "doc.on.doc") {
				UIPasteboard.general.string = item.transcript ?? ""
				selected = nil
				router.showToast(String(localized: "Copied to clipboard"))
			}
			LineAction(title: AppState.shared.isSpeaking ? "Stop" : "Speak", systemImage: "speaker.wave.2") {
				if AppState.shared.isSpeaking {
					AppState.shared.stopSpeaking()
				} else {
					AppState.shared.speak(text: item.transcript)
					router.showToast(String(localized: "Reading aloud"))
				}
			}
			LineAction(title: "Share", systemImage: "square.and.arrow.up") {
				SharePresenter.share([item.transcript ?? ""])
			}
			LineAction(title: "Delete", systemImage: "trash", tint: .vermilion) {
				delete(item)
			}
		}
		.padding(10)
		.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: RescrivaRadius.large, style: .continuous))
		.background(Color.vellum.opacity(0.9), in: RoundedRectangle(cornerRadius: RescrivaRadius.large, style: .continuous))
		.rescrivaShadow(.float)
	}

	private func finishEditing() {
		editing = false
		viewContext.saveQuietly()
	}

	private func delete(_ item: ScanRecognizedItem) {
		let transcript = item.transcript
		let order = item.order
		let line = item.recognizedLine
		selected = nil
		viewContext.delete(item)
		capture.parent?.lastUpdate = Date()
		viewContext.saveQuietly()
		router.showToast(String(localized: "Line removed"), actionLabel: String(localized: "Undo")) { [capture, viewContext] in
			let restored = ScanRecognizedItem(context: viewContext)
			restored.id = UUID()
			restored.order = order
			restored.timestamp = Date()
			restored.transcript = transcript
			restored.confidence = Double(line.confidence)
			restored.boxX = line.box.minX
			restored.boxY = line.box.minY
			restored.boxW = line.box.width
			restored.boxH = line.box.height
			capture.addToRecognizedItems(restored)
			viewContext.saveQuietly()
		}
	}
}

/// One button in the floating line-action bar.
private struct LineAction: View {
	let title: LocalizedStringKey
	let systemImage: String
	var tint: Color = .carbon
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			VStack(spacing: 4) {
				Glyph(systemImage, size: 18, weight: .light)
					.frame(height: 22)
				Text(title)
					.font(RescrivaFont.ui(11, weight: .medium))
			}
			.foregroundStyle(tint)
			.frame(maxWidth: .infinity)
			.padding(.vertical, 8)
			.contentShape(Rectangle())
		}
		.buttonStyle(PressScaleStyle())
	}
}
