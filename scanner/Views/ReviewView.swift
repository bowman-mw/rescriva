//
//  ReviewView.swift
//  Rescriva (fork of Open Scanner)
//
//  "Review & fix": the rebuilt page next to the original, every fix one or two
//  taps — confirm uncertain words and arrows, toggle B/I/U, switch headings,
//  add notes, recreate a figure or diagram as shapes, remove a wrong figure —
//  then export. Edits write back into the RescrivaDocument.
//

import SwiftUI

/// The three review views.
enum ReviewMode: String, CaseIterable {
	case original, split, rebuilt

	var label: LocalizedStringKey {
		switch self {
		case .original: return "Original"
		case .split: return "Side by side"
		case .rebuilt: return "Rebuilt"
		}
	}
}

struct ReviewView: View {
	@Environment(\.managedObjectContext) private var viewContext
	@Environment(RescrivaRouter.self) private var router
	@ObservedObject var scan: Scan

	@AppStorage(RescrivaPreference.companionTips) private var companionTips = true
	@State private var document: RescrivaDocument?
	@State private var mode = ReviewMode.rebuilt
	@State private var selectedBlock: UUID?
	@State private var openFlag: FlagSelection?
	@State private var exportRequest: ExportRequest?
	@State private var editingNote = false
	@State private var noteDraft = ""
	@State private var recreating: RecreateRequest?
	@State private var confirmingFigureRemoval = false

	private let tier = DeviceTier.current

	var body: some View {
		ZStack(alignment: .bottom) {
			GrainBackground()
			if mode == .split, let document {
				VStack(spacing: 0) {
					topBar
					modePicker
					compare(document)
				}
				.padding(.bottom, 156)
			} else {
				scrollingContent
			}
			bottomBar
		}
		.onAppear {
			document = scan.rebuiltDocument
			selectedBlock = selectedBlock ?? document?.pages.first?.blocks.first?.id
		}
		.onChange(of: scan.rebuiltData) {
			// A rebuild that finished after Review opened (an export builds one too).
			guard document == nil else { return }
			document = scan.rebuiltDocument
			selectedBlock = selectedBlock ?? document?.pages.first?.blocks.first?.id
		}
		.sheet(item: $openFlag) { selection in
			if let flag = document?.flag(selection.id) {
				FlagSheet(flag: flag) { option in
					edit { $0.resolveFlag(selection.id, option: option) }
					openFlag = nil
				} onType: { text in
					edit { $0.resolveFlag(selection.id, typed: text) }
					openFlag = nil
				}
			}
		}
		.sheet(item: $exportRequest) { request in
			ExportSheet(scan: scan, initialFormat: request.format) { message in router.showToast(message, style: .exported) }
		}
		.fullScreenCover(item: $recreating) { request in
			DiagramEditorView(request: request) { diagram in
				edit { doc in doc.updateBlock(request.id) { block in RecreateSource.apply(diagram, to: &block) } }
				// A figure redrawn as shapes no longer needs its picture.
				FigureAssets.prune(scan)
			}
		}
		.alert(selectedNote == nil ? "Add a note" : "Edit note", isPresented: $editingNote) {
			TextField("Note", text: $noteDraft, axis: .vertical)
			Button("Save") { saveNote() }
			if selectedNote != nil {
				Button("Remove note", role: .destructive) { removeNote() }
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text(noteMessage)
		}
	}

	// MARK: Pieces

	/// Original or Rebuilt: one scrolling column.
	private var scrollingContent: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				topBar
				modePicker
				if companionTips, mode == .rebuilt, openFlagCount > 0 {
					MarginNote(text: tip)
						.padding(.horizontal, 20)
						.padding(.bottom, 12)
				}
				if mode == .original {
					originalPages
				}
				if mode == .rebuilt {
					if let document {
						rebuiltCard(document)
					} else {
						notRebuiltCard
					}
				}
			}
			.padding(.bottom, 170)
		}
		.overlay(alignment: .top) { StatusBarScrim() }
	}

	/// The rebuilt document on paper, editable.
	private func rebuiltCard(_ document: RescrivaDocument) -> some View {
		RebuiltDocumentView(
			document: document, output: scan.output, selectedBlock: selectedBlock, activeFlag: openFlag?.id,
			onSelectBlock: { id in withAnimation(RescrivaMotion.fast) { selectedBlock = id } },
			onOpenFlag: { id in openFlag = FlagSelection(id: id) },
			onToggleItem: { blockID, itemID in edit { $0.updateBlock(blockID) { $0.content.toggleChecked(item: itemID) } } },
			blockActions: { block in actions(for: block) }
		)
		.environment(\.figureImages, FigureImageSource(scan: scan))
		.padding(.vertical, 22)
		.padding(.horizontal, 20)
		.background(Color.paper, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
		.rescrivaShadow(.card)
		.padding(.horizontal, 16)
	}

	/// In place of the rebuilt document when the scan has none (its rebuild was stopped, or its
	/// pages changed while it ran): a way to run it again rather than a blank page.
	private var notRebuiltCard: some View {
		VStack(spacing: 12) {
			Text("Not rebuilt yet")
				.font(RescrivaFont.display(22))
				.foregroundStyle(.carbon)
			Text("The rebuild didn’t finish. Run it again to see the rebuilt pages here.")
				.font(RescrivaFont.note(15))
				.foregroundStyle(Color.carbon.opacity(0.7))
				.multilineTextAlignment(.center)
			PrimaryButton(title: "Rebuild", systemImage: "arrow.clockwise", height: 48) {
				router.replaceTop(with: .processing(scan))
			}
			.padding(.top, 4)
		}
		.padding(22)
		.frame(maxWidth: .infinity)
		.paperCard()
		.padding(.horizontal, 16)
	}

	/// Side by side: the original over its rebuilt version, a page at a time.
	private func compare(_ document: RescrivaDocument) -> some View {
		ReviewCompareView(
			scan: scan, document: document, output: scan.output, selectedBlock: $selectedBlock, activeFlag: openFlag?.id,
			onOpenFlag: { id in openFlag = FlagSelection(id: id) },
			onToggleItem: { blockID, itemID in edit { $0.updateBlock(blockID) { $0.content.toggleChecked(item: itemID) } } },
			blockActions: { block in actions(for: block) }
		)
		.environment(\.figureImages, FigureImageSource(scan: scan))
	}

	private var topBar: some View {
		HStack {
			BackPill(title: "Pages") { router.pop() }
			Spacer()
			Button {
				if let next = document?.openFlags.first {
					if mode == .original { mode = .rebuilt }
					openFlag = FlagSelection(id: next.flag.id)
				}
			} label: {
				HStack(spacing: 6) {
					Circle()
						.fill(openFlagCount > 0 ? Color.highlighter : Color.ink)
						.frame(width: 8, height: 8)
					Text(openFlagCount > 0 ? "\(openFlagCount) to check" : "All checked")
						.font(RescrivaFont.ui(13, weight: .medium))
						.foregroundStyle(.carbon)
				}
				.frame(height: 34)
				.padding(.horizontal, 12)
				.background(openFlagCount > 0 ? Color.highlighter.opacity(0.25) : Color.wash,
							in: RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous))
				.animation(RescrivaMotion.ui, value: openFlagCount)
			}
			.buttonStyle(PressScaleStyle(scale: 0.95))
			.disabled(openFlagCount == 0)
			.accessibilityHint(openFlagCount > 0 ? Text("Opens the next spot to check") : Text(""))
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	private var modePicker: some View {
		RescrivaSegmentedPicker(options: ReviewMode.allCases, selection: $mode) { $0.label }
			.padding(.horizontal, 16)
			.padding(.top, 10)
			.padding(.bottom, 12)
	}

	private var originalPages: some View {
		VStack(spacing: 18) {
			ForEach(scan.capturesArray, id: \.objectID) { capture in
				if let image = capture.image ?? capture.thumbnail {
					Image(uiImage: image)
						.resizable()
						.scaledToFit()
						.frame(maxWidth: 330, maxHeight: 460)
						.background(Color.paper)
						.clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
						.shadow(color: Color.shade.opacity(0.14), radius: 12, x: 0, y: 10)
						.rotationEffect(.degrees(-1.2))
						.accessibilityLabel("Original page")
				}
			}
		}
		.frame(maxWidth: .infinity)
		.padding(18)
		.background(Color.scanBackdrop, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
		.padding(.horizontal, 16)
		.padding(.bottom, 14)
	}

	private var bottomBar: some View {
		FrostedBottomBar {
			HStack(spacing: 6) {
				formatButtons
				FormatButton(label: "Note", isOn: selectedNote != nil, isEnabled: selectedBlock != nil) {
					noteDraft = selectedNote?.text ?? ""
					editingNote = true
				}
				Spacer(minLength: 0)
			}
			PrimaryButton(title: tier.canRebuild ? "Export" : "Export PDF", height: 52) {
				exportRequest = ExportRequest(format: tier.canRebuild ? (scan.output == .pptx ? .pptx : .docx) : .pdf)
			}
		}
		.confirmationDialog("Remove this figure?", isPresented: $confirmingFigureRemoval, titleVisibility: .visible) {
			Button("Remove figure", role: .destructive) { removeSelectedFigure() }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("The picture won’t be in the exported file. Any words read inside it, and its caption, stay as text.")
		}
	}

	/// B, I, U and Heading, for the selected block's text.
	@ViewBuilder
	private var formatButtons: some View {
		FormatButton(label: "B", isOn: styleIsOn(.bold), isEnabled: selectedHasRuns, weight: .bold) { toggle(.bold) }
			.accessibilityLabel("Bold")
		FormatButton(label: "I", isOn: styleIsOn(.italic), isEnabled: selectedHasRuns, italic: true) { toggle(.italic) }
			.accessibilityLabel("Italic")
		FormatButton(label: "U", isOn: styleIsOn(.underline), isEnabled: selectedHasRuns, underline: true) { toggle(.underline) }
			.accessibilityLabel("Underline")
		FormatButton(label: "Heading", isOn: selectedContent?.isHeading ?? false, isEnabled: canToggleHeading) {
			edit { doc in
				guard let id = selectedBlock else { return }
				doc.updateBlock(id) { $0.content.toggleHeading() }
			}
		}
	}

	// MARK: State

	private var openFlagCount: Int { document?.openFlags.count ?? 0 }

	private var tip: String {
		openFlagCount == 1 ? String(localized: "Just one spot I wasn’t sure about.")
			: String(localized: "\(openFlagCount) spots I wasn’t sure about — tap the highlighted ones.")
	}

	private var selectedContent: BlockContent? {
		selectedBlock.flatMap { document?.block($0)?.content }
	}

	private var selectedNote: RescrivaNote? {
		selectedBlock.flatMap { document?.block($0)?.notes.first }
	}

	private var selectedHasRuns: Bool { selectedContent?.hasRuns ?? false }

	private var canToggleHeading: Bool {
		switch selectedContent {
		case .heading, .paragraph: return true
		default: return false
		}
	}

	private var noteMessage: String {
		switch scan.output {
		case .docx: return String(localized: "Notes become Word comments.")
		case .pptx: return String(localized: "Notes become speaker notes.")
		case .pdf: return String(localized: "Notes become PDF notes.")
		}
	}

	private func styleIsOn(_ style: RunStyle) -> Bool {
		selectedContent?.allRuns(style) ?? false
	}

	// MARK: Edits

	private func edit(_ change: (inout RescrivaDocument) -> Void) {
		guard var updated = document else { return }
		change(&updated)
		withAnimation(RescrivaMotion.ui) { document = updated }
		scan.rebuiltDocument = updated
		scan.lastUpdate = Date()
		viewContext.saveQuietly()
	}

	private func toggle(_ style: RunStyle) {
		guard let id = selectedBlock else { return }
		let on = styleIsOn(style)
		edit { $0.updateBlock(id) { $0.content.setStyle(style, to: !on) } }
	}

	private func saveNote() {
		guard let id = selectedBlock else { return }
		let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else {
			removeNote()
			return
		}
		edit { doc in
			doc.updateBlock(id) { block in
				if block.notes.isEmpty {
					block.notes.append(RescrivaNote(text: text, created: Date()))
				} else {
					block.notes[0].text = text
				}
			}
		}
	}

	private func removeNote() {
		guard let id = selectedBlock else { return }
		edit { $0.updateBlock(id) { $0.notes.removeAll() } }
	}

	// MARK: Figures and diagrams

	/// The menu a tapped figure or diagram shows: Recreate, Remove figure (figures only, after
	/// asking) and its note.
	private func actions(for block: RescrivaBlock) -> [BlockAction] {
		guard RecreateSource.canRecreate(block.content) else { return [] }
		var actions = [
			BlockAction(id: "recreate", title: "Recreate", systemImage: "pencil.and.outline",
						detail: "Redraw it as shapes, over the original") { recreate(block.id) },
		]
		if block.content.isFigure {
			actions.append(BlockAction(id: "remove-figure", title: "Remove figure", systemImage: "minus.circle",
									   detail: "Its words and caption stay as text") {
				selectedBlock = block.id
				confirmingFigureRemoval = true
			})
		}
		actions.append(BlockAction(id: "note", title: block.notes.isEmpty ? "Add a note" : "Edit note", systemImage: "text.bubble") {
			selectedBlock = block.id
			noteDraft = block.notes.first?.text ?? ""
			editingNote = true
		})
		return actions
	}

	private func recreate(_ id: UUID) {
		guard let document, let request = RecreateSource.request(for: id, in: document, scan: scan) else { return }
		recreating = request
	}

	/// Removes the selected figure (its words stay as text) and its picture.
	private func removeSelectedFigure() {
		guard let id = selectedBlock, selectedContent?.isFigure == true else { return }
		edit { $0.removeFigure(id) }
		selectedBlock = nil
		FigureAssets.prune(scan)
	}
}

/// Which flag the sheet shows.
struct FlagSelection: Identifiable {
	let id: UUID
}

/// A format toggle in the review bar.
private struct FormatButton: View {
	let label: String
	let isOn: Bool
	let isEnabled: Bool
	var weight: Font.Weight = .medium
	var italic = false
	var underline = false
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Text(label)
				.font(italic ? RescrivaFont.body(16, italic: true) : RescrivaFont.ui(15, weight: weight == .bold ? .bold : .medium))
				.underline(underline)
				.foregroundStyle(isOn ? Color.vellum : Color.carbon)
				.frame(minWidth: 40, minHeight: 40)
				.padding(.horizontal, label.count > 1 ? 10 : 0)
				.background(isOn ? Color.carbon : Color.vellum, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
				.animation(RescrivaMotion.ui, value: isOn)
		}
		.buttonStyle(PressScaleStyle())
		.disabled(!isEnabled)
		.opacity(isEnabled ? 1 : 0.4)
		.accessibilityAddTraits(isOn ? .isSelected : [])
	}
}

/// "Did you mean…" — confirm an uncertain word or arrow.
struct FlagSheet: View {
	let flag: RescrivaFlag
	let onChoose: (RescrivaFlag.Option) -> Void
	let onType: (String) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var typed = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			SheetHeader(title: flag.title, subtitle: flag.detail)
			readCrop
			options
			footer
		}
		.padding(.horizontal, 20)
		.padding(.top, 8)
		.padding(.bottom, 12)
		.presentationDetents([.height(flag.kind == .word ? 440 : 390)])
		.presentationDragIndicator(.visible)
		.presentationCornerRadius(RescrivaRadius.large)
		.presentationBackground(Color.vellum)
	}

	/// What was read, large, on ruled paper.
	private var readCrop: some View {
		Text(flag.read)
			.font(RescrivaFont.body(30, italic: true))
			.foregroundStyle(Color.ballpoint)
			.rotationEffect(.degrees(-2))
			.lineLimit(1)
			.minimumScaleFactor(0.5)
			.frame(maxWidth: .infinity)
			.frame(height: 76)
			.background { RuledPaper(spacing: 24) }
			.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
			.overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.carbon.opacity(0.08)) }
			.accessibilityLabel(Text("Read as \(flag.read)"))
	}

	/// The choices, most likely first.
	private var options: some View {
		VStack(spacing: 8) {
			ForEach(Array(flag.options.enumerated()), id: \.offset) { index, option in
				Button {
					onChoose(option)
				} label: {
					HStack {
						Text(option.label)
							.font(RescrivaFont.body(18))
							.foregroundStyle(.carbon)
						Spacer()
						Text(option.note)
							.font(RescrivaFont.ui(12))
							.foregroundStyle(.graphite)
					}
					.padding(.vertical, 14)
					.padding(.horizontal, 16)
					.background(index == 0 ? Color.wash.opacity(0.55) : Color.stock,
								in: RoundedRectangle(cornerRadius: 14, style: .continuous))
				}
				.buttonStyle(PressScaleStyle(scale: 0.97))
			}
		}
	}

	/// "Type it instead" (words only) and "Later".
	private var footer: some View {
		HStack(spacing: 10) {
			if flag.kind == .word {
				TextField("Type it instead", text: $typed)
					.font(RescrivaFont.ui(14))
					.foregroundStyle(.carbon)
					.submitLabel(.done)
					.onSubmit {
						let text = typed.trimmingCharacters(in: .whitespaces)
						if !text.isEmpty { onType(text) }
					}
					.padding(.horizontal, 14)
					.frame(height: 46)
					.overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.carbon.opacity(0.18)) }
			} else {
				Spacer()
			}
			Button("Later") { dismiss() }
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(.ink)
				.frame(height: 46)
				.padding(.horizontal, 18)
		}
	}
}

/// Paper with faint blue rules, like a notebook page.
struct RuledPaper: View {
	var spacing: CGFloat = 24

	var body: some View {
		Canvas { context, size in
			context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.paper))
			var y = spacing - 0.5
			while y < size.height {
				context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Color(red: 148 / 255, green: 174 / 255, blue: 191 / 255).opacity(0.3)))
				y += spacing
			}
		}
	}
}
