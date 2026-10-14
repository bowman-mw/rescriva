//
//  AnnotateView.swift
//  Rescriva (fork of Open Scanner)
//
//  Annotate: mark up a scan's pages the way you would a PDF in a browser —
//  pen, highlighter and eraser, plus lines, arrows, rectangles and circles —
//  with colors, sizes, undo and redo. Marks sit over the scan without
//  changing it, show in the preview and go out with the searchable PDF.
//

import SwiftUI

/// Opens Annotate on a scan's pages.
struct AnnotateRequest: Identifiable {
	let id = UUID()
	let pages: [AnnotationSession.Page]
	let startIndex: Int
}

struct AnnotateView: View {
	@Environment(\.dismiss) private var dismiss
	@State private var session: AnnotationSession
	@State private var isConfirmingDiscard = false
	@State private var saveFailed = false
	private let onSave: () -> Void

	init(request: AnnotateRequest, onSave: @escaping () -> Void = {}) {
		_session = State(initialValue: AnnotationSession(pages: request.pages, startingAt: request.startIndex))
		self.onSave = onSave
	}

	var body: some View {
		VStack(spacing: 0) {
			topBar
			AnnotationCanvas(pageID: session.currentPage.id, image: session.currentImage, marks: session.currentMarks,
							 brush: session.brush, onCommit: { session.add($0) }, onErase: { session.erase($0) })
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				// The page with its look, rendered off the main thread; the stored page shows until then.
				.task(id: session.currentPage.id) { await session.renderLook() }
			if session.pages.count > 1 {
				pageSwitcher
			}
			FrostedBottomBar {
				toolRow
				optionsRow
			}
		}
		.background(GrainBackground(base: .scanBackdrop))
		.confirmationDialog("Discard your changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
			Button("Discard changes", role: .destructive) { dismiss() }
			Button("Keep editing", role: .cancel) {}
		} message: {
			Text("The marks you've made since opening Annotate will be lost.")
		}
		.alert("Couldn't save your annotations", isPresented: $saveFailed) {
			Button("OK", role: .cancel) {}
		} message: {
			Text("Your marks are still here. Try Done again in a moment.")
		}
	}

	// MARK: Top bar

	private var topBar: some View {
		HStack(spacing: 10) {
			CircleIconButton(systemName: "xmark", label: "Close") { close() }
			Text("Annotate")
				.font(RescrivaFont.header(22))
				.foregroundStyle(.carbon)
				.accessibilityAddTraits(.isHeader)
			Spacer(minLength: 4)
			historyButton("arrow.uturn.backward", label: "Undo", isEnabled: session.canUndo) { session.undo() }
			historyButton("arrow.uturn.forward", label: "Redo", isEnabled: session.canRedo) { session.redo() }
			Button(action: done) {
				Text("Done")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.vellum)
					.frame(height: 40)
					.padding(.horizontal, 18)
					.background(Color.ink, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
					.rescrivaShadow(.small)
			}
			.buttonStyle(PressScaleStyle(scale: 0.94))
			.accessibilityHint("Saves your marks")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	private func historyButton(_ systemName: String, label: LocalizedStringKey, isEnabled: Bool, action: @escaping () -> Void) -> some View {
		CircleIconButton(systemName: systemName, label: label, action: action)
			.disabled(!isEnabled)
			.opacity(isEnabled ? 1 : 0.4)
			.animation(RescrivaMotion.fast, value: isEnabled)
	}

	// MARK: Pages

	private var pageSwitcher: some View {
		HStack(spacing: 4) {
			pageButton("chevron.left", label: "Previous page", isEnabled: session.canGoBack) {
				session.showPage(session.pageIndex - 1)
			}
			Text("Page \(session.pageIndex + 1) of \(session.pages.count)")
				.font(RescrivaFont.ui(13, weight: .medium))
				.foregroundStyle(.carbon)
				.monospacedDigit()
				.frame(minWidth: 96)
			pageButton("chevron.right", label: "Next page", isEnabled: session.canGoForward) {
				session.showPage(session.pageIndex + 1)
			}
		}
		.padding(.horizontal, 4)
		.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
		.rescrivaShadow(.small)
		.padding(.bottom, 10)
	}

	private func pageButton(_ systemName: String, label: LocalizedStringKey, isEnabled: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Glyph(systemName, size: 14, weight: .medium)
				.foregroundStyle(.carbon)
				.frame(width: 36, height: 36)
				.contentShape(Rectangle())
		}
		.buttonStyle(PressScaleStyle())
		.disabled(!isEnabled)
		.opacity(isEnabled ? 1 : 0.3)
		.accessibilityLabel(Text(label))
	}

	// MARK: Tools

	private var toolRow: some View {
		HStack(spacing: 0) {
			ForEach(AnnotationTool.allCases) { tool in
				ToolButton(tool: tool, isSelected: session.tool == tool) {
					withAnimation(RescrivaMotion.fast) { session.selectTool(tool) }
				}
				.frame(maxWidth: .infinity)
				if tool == .eraser {
					Rectangle()
						.fill(Color.carbon.opacity(0.14))
						.frame(width: 1, height: 24)
						.accessibilityHidden(true)
				}
			}
		}
	}

	@ViewBuilder
	private var optionsRow: some View {
		if session.tool == .eraser {
			HStack {
				Text("Touch a mark to erase it")
					.font(RescrivaFont.note(15))
					.foregroundStyle(.graphite)
				Spacer()
				Button("Clear page") { session.clearPage() }
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.vermilion)
					.disabled(session.currentMarks.isEmpty)
					.opacity(session.currentMarks.isEmpty ? 0.4 : 1)
			}
			.frame(height: 36)
			.padding(.horizontal, 6)
		} else if let style = session.currentStyle {
			HStack(spacing: 0) {
				ForEach(Array(session.currentSwatches.enumerated()), id: \.element.id) { index, swatch in
					SwatchButton(swatch: swatch, isSelected: style.colorIndex == index) { session.selectColor(index) }
						.frame(maxWidth: .infinity)
				}
				Rectangle()
					.fill(Color.carbon.opacity(0.14))
					.frame(width: 1, height: 24)
					.padding(.horizontal, 6)
					.accessibilityHidden(true)
				ForEach(Array(MarkPalette.sizeNames.enumerated()), id: \.offset) { index, name in
					SizeButton(index: index, name: name, color: session.brush.color, isSelected: style.sizeIndex == index) {
						session.selectSize(index)
					}
				}
			}
			.frame(height: 36)
		}
	}

	// MARK: Actions

	private func close() {
		if session.hasChanges {
			isConfirmingDiscard = true
		} else {
			dismiss()
		}
	}

	private func done() {
		guard session.hasChanges else {
			dismiss()
			return
		}
		do {
			try session.save()
			onSave()
			dismiss()
		} catch {
			Log.library.error("Saving annotations failed: \(error)")
			saveFailed = true
		}
	}
}

/// A tool in the bottom bar: carbon circle when chosen.
private struct ToolButton: View {
	let tool: AnnotationTool
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Glyph(tool.systemImage, size: 18, weight: .regular)
				.foregroundStyle(isSelected ? Color.vellum : Color.carbon)
				.frame(width: 40, height: 40)
				.background {
					if isSelected {
						Circle().fill(Color.carbon)
					}
				}
				.contentShape(Circle())
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(Text(tool.label))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

/// A color choice; the chosen one wears a carbon ring.
private struct SwatchButton: View {
	let swatch: MarkSwatch
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Circle()
				.fill(Color(hex: UInt(swatch.rgb)))
				.overlay(Circle().strokeBorder(Color.rim, lineWidth: 1))
				.frame(width: 24, height: 24)
				.padding(4)
				.overlay {
					if isSelected {
						Circle().strokeBorder(Color.carbon, lineWidth: 2)
					}
				}
				.frame(width: 36, height: 36)
				.contentShape(Circle())
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(Text(swatch.name))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

/// A stroke size, shown as a dot in the current color.
private struct SizeButton: View {
	let index: Int
	let name: LocalizedStringKey
	let color: UInt32
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Circle()
				.fill(Color(hex: UInt(color)))
				.overlay(Circle().strokeBorder(Color.rim, lineWidth: 1))
				.frame(width: CGFloat(6 + index * 5), height: CGFloat(6 + index * 5))
				.frame(width: 34, height: 34)
				.background {
					if isSelected {
						Circle().fill(Color.carbon.opacity(0.1))
					}
				}
				.contentShape(Circle())
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(Text(name))
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}
