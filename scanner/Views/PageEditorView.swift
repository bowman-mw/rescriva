//
//  PageEditorView.swift
//  Rescriva (fork of Open Scanner)
//
//  "Adjust page": fix a page's crop on its original photo, turn it, or clean
//  it again as a document or a whiteboard. A touch grabs whichever is nearest
//  of a corner, an edge midpoint (moves both of its corners) or the middle
//  (moves the whole crop); a loupe shows the original under the point being
//  moved; undo and redo cover the session. Done re-makes the page through
//  PageReprocessor, Cancel leaves it as it was. A page whose original isn't
//  on this iPhone can still be turned. A crop much wider than tall (a book
//  or magazine spread) can be split into two pages along a line set on the
//  fold, which can be dragged (SpreadSplit). The geometry is in
//  PageGeometry.swift.
//

import SwiftUI
import UIKit

// MARK: - Model

/// The editor's state, as one undoable snapshot.
struct PageEditState: Equatable {
	/// The crop on the original (normalized, top-left origin).
	var quad: PageQuad
	/// Absolute clockwise quarter turns, 0...3.
	var rotation: Int
	/// The cleanup recipe; nil keeps the photo's own pixels.
	var mode: CaptureMode?
}

/// What the editor can change on this page.
enum PageEditAvailability: Equatable {
	case loading
	/// The original is on this iPhone: crop, rotation and cleanup.
	case full
	/// No original here: rotation only, with the reason to show.
	case rotateOnly(String)
}

/// One editing session on one page.
@MainActor
@Observable
final class PageEditorModel {
	let capture: ScanCapture
	private(set) var availability: PageEditAvailability = .loading
	/// The upright original (`.full`) or the stored page (`.rotateOnly`).
	private(set) var baseImage: CGImage?
	/// The state the page had when the editor opened.
	let initial: PageEditState
	/// The live state; drags write the quad directly and record history when they end.
	var state: PageEditState
	private(set) var history = EditHistory<PageEditState>()
	/// The page as Vision finds it on the original (with the camera's trim), for Reset.
	private(set) var detectedQuad: PageQuad?
	private(set) var isApplying = false
	private(set) var errorMessage: String?
	/// While a spread is being split: where the line sits across the cropped page as shown (0...1).
	private(set) var splitFraction: CGFloat?
	/// True while the fold is being looked for.
	private(set) var isFindingFold = false
	/// Whether the line was set on a fold that was found (rather than in the middle).
	private(set) var foundFold = false

	private let recipe: PageRecipe?
	private let originals: OriginalStore
	@ObservationIgnored private var displayCache: (turns: Int, image: UIImage)?

	init(capture: ScanCapture, originals: OriginalStore = .shared) {
		self.capture = capture
		self.originals = originals
		let recipe = capture.recipe
		self.recipe = recipe
		let start = PageEditState(
			quad: QuadEditing.clamped(recipe?.quad ?? .fullFrame),
			rotation: QuarterTurns.normalized(Int(capture.rotation)),
			mode: recipe?.mode
		)
		initial = start
		state = start
	}

	var hasChanges: Bool { state != initial }
	var canEditCrop: Bool { availability == .full }

	/// Turns to draw `baseImage` with: the original turns fully, a stored page only by what changed.
	var displayTurns: Int {
		availability == .full ? state.rotation : QuarterTurns.normalized(state.rotation - initial.rotation)
	}

	/// True when the page can be split as a spread: its original is here, and the crop as shown is
	/// much wider than tall. Whiteboards are wide by nature, so they're never offered it.
	var canOfferSplit: Bool {
		guard canEditCrop, state.mode != .whiteboard, let baseImage else { return false }
		let size = CGSize(width: baseImage.width, height: baseImage.height)
		return SpreadSplit.looksLikeSpread(state.quad, imageSize: size, quarterTurns: state.rotation)
	}

	/// True from asking to split until the split is made or called off.
	var isSplitting: Bool { splitFraction != nil || isFindingFold }

	/// The split line's ends on the original (top of the page as shown, then bottom), while splitting.
	var splitLine: (start: CGPoint, end: CGPoint)? {
		splitFraction.flatMap { SpreadSplit.line(in: state.quad, at: $0, quarterTurns: state.rotation) }
	}

	/// The cleanup choices; "As is" only for a page that was never cleaned.
	var modeOptions: [CaptureMode?] {
		initial.mode == nil ? [nil, .document, .whiteboard] : [.document, .whiteboard]
	}

	/// `baseImage` turned for display. Cached per rotation so a drag never swaps the image.
	func displayImage() -> UIImage? {
		guard let baseImage else { return nil }
		let turns = displayTurns
		if let cached = displayCache, cached.turns == turns {
			return cached.image
		}
		let image = UIImage(cgImage: baseImage, scale: 1, orientation: QuarterTurns.imageOrientation(turns))
		displayCache = (turns, image)
		return image
	}

	/// Loads the original and finds the page on it (off the main thread); falls back to the stored
	/// page, rotation only, when the original isn't here.
	func load() async {
		guard availability == .loading else { return }
		if recipe != nil, let id = capture.id, originals.contains(id) {
			let store = originals
			let loaded = await Task.detached(priority: .userInitiated) { () -> (image: CGImage, detected: PageQuad?)? in
				guard let original = store.loadImage(for: id) else { return nil }
				let detected = PageReprocessor.detectPage(in: original)?.inset(by: PageReprocessor.detectedQuadInset)
				return (original, detected)
			}.value
			if let loaded {
				baseImage = loaded.image
				detectedQuad = loaded.detected.map(QuadEditing.clamped)
				availability = .full
				return
			}
		}
		let data = capture.imageData
		baseImage = await Task.detached(priority: .userInitiated) { data.flatMap { UIImage(data: $0)?.cgImage } }.value
		availability = .rotateOnly(recipe == nil
			? String(localized: "This page has no original photo, so it can only be turned.")
			: String(localized: "The original photo isn't on this iPhone (originals don't sync, and can be removed in Settings), so this page can only be turned."))
	}

	// MARK: Edits

	/// Moves to `next`, recording the current state for undo.
	func commit(_ next: PageEditState) {
		guard next != state else { return }
		history.record(state)
		state = next
		errorMessage = nil
	}

	/// Records a finished drag that began at `start` (the drag itself moved `state.quad` live).
	func finishDrag(from start: PageQuad) {
		guard start != state.quad else { return }
		var before = state
		before.quad = start
		history.record(before)
		errorMessage = nil
	}

	func undo() {
		guard let previous = history.undo(from: state) else { return }
		state = previous
	}

	func redo() {
		guard let next = history.redo(from: state) else { return }
		state = next
	}

	/// Back to the page Vision finds on the original, or the crop the page opened with.
	func resetCrop() {
		guard canEditCrop else { return }
		var next = state
		next.quad = detectedQuad ?? initial.quad
		commit(next)
	}

	func useFullImage() {
		guard canEditCrop else { return }
		var next = state
		next.quad = .fullFrame
		commit(next)
	}

	func rotate(by turns: Int) {
		guard availability != .loading else { return }
		var next = state
		next.rotation = QuarterTurns.normalized(state.rotation + turns)
		commit(next)
	}

	func setMode(_ mode: CaptureMode?) {
		guard canEditCrop else { return }
		var next = state
		next.mode = mode
		commit(next)
	}

	/// Moves `handle` by `delta` (normalized) as one undoable step. Returns false when refused.
	func nudge(_ handle: QuadHandle, by delta: CGVector) -> Bool {
		guard canEditCrop, let moved = QuadEditing.moved(state.quad, handle: handle, by: delta) else { return false }
		var next = state
		next.quad = moved
		commit(next)
		return true
	}

	// MARK: Splitting a spread

	/// Looks for the fold on the crop as it stands (off the main thread) and sets the line on it, or
	/// in the middle when there's no clear fold.
	func beginSplit() async {
		guard canOfferSplit, !isSplitting, let image = baseImage else { return }
		isFindingFold = true
		errorMessage = nil
		let quad = state.quad
		let turns = state.rotation
		let fold = await Task.detached(priority: .userInitiated) {
			SpreadSplit.findFold(on: image, quad: quad, quarterTurns: turns)
		}.value
		// Called off while the fold was being looked for.
		guard isFindingFold else { return }
		isFindingFold = false
		foundFold = fold != nil
		splitFraction = CGFloat(fold ?? 0.5)
	}

	/// Moves the line to run through `point` (normalized on the original).
	func moveSplit(toward point: CGPoint) {
		guard splitFraction != nil, let fraction = SpreadSplit.fraction(of: point, in: state.quad, quarterTurns: state.rotation) else { return }
		splitFraction = fraction
	}

	/// Moves the line by `step` across the page as shown (VoiceOver), within its range.
	func nudgeSplit(by step: CGFloat) {
		guard let current = splitFraction else { return }
		let range = SpreadSplit.Tuning.lineRange
		splitFraction = min(max(current + step, range.lowerBound), range.upperBound)
	}

	/// Leaves the page as one, even while the fold is still being looked for.
	func cancelSplit() {
		guard !isApplying else { return }
		splitFraction = nil
		isFindingFold = false
		foundFold = false
	}

	/// The recipes of the two pages the split makes: each half of the crop, with the mode and the
	/// rotation as they stand. Nil while not splitting, or with the line too near an edge.
	var splitRecipes: (first: PageRecipe, second: PageRecipe)? {
		guard let fraction = splitFraction, var base = recipe,
			  let halves = SpreadSplit.halves(of: state.quad, at: fraction, quarterTurns: state.rotation) else { return nil }
		base.rotation = state.rotation
		base.mode = state.mode
		var first = base
		first.quad = halves.first
		var second = base
		second.quad = halves.second
		return (first, second)
	}

	/// Splits the page in two along the line (`splitRecipes`). Returns false (with `errorMessage`) on
	/// failure.
	func applySplit() async -> Bool {
		guard splitFraction != nil, !isApplying else { return false }
		guard let recipes = splitRecipes else {
			errorMessage = String(localized: "The line is too close to the edge to make two pages.")
			return false
		}
		isApplying = true
		defer { isApplying = false }
		do {
			// The editor already holds the decoded original; don't decode a second copy.
			try await PageReprocessor.split(capture, first: recipes.first, second: recipes.second, original: baseImage, originals: originals)
			return true
		} catch {
			errorMessage = error.localizedDescription
			return false
		}
	}

	/// Re-makes the page with the edited state. Returns false (with `errorMessage`) on failure.
	func apply() async -> Bool {
		guard hasChanges else { return true }
		guard !isApplying else { return false }
		isApplying = true
		defer { isApplying = false }
		do {
			if availability == .full, var next = recipe {
				next.quad = state.quad
				next.rotation = state.rotation
				next.mode = state.mode
				// The editor already holds the decoded original; don't decode a second copy.
				try await PageReprocessor.apply(next, to: capture, original: baseImage, originals: originals)
			} else {
				try await PageReprocessor.rotateStoredPage(capture, to: state.rotation)
			}
			return true
		} catch {
			errorMessage = error.localizedDescription
			return false
		}
	}
}

/// VoiceOver names, by where things appear on screen once the page is turned.
enum PageEditorLabels {
	static func handle(_ handle: QuadHandle, quarterTurns: Int) -> String {
		switch handle {
		case .corner(let index):
			let names = [String(localized: "Top-left corner"), String(localized: "Top-right corner"),
						 String(localized: "Bottom-right corner"), String(localized: "Bottom-left corner")]
			return names[QuadEditing.visualIndex(index, quarterTurns: quarterTurns)]
		case .edge(let index):
			let names = [String(localized: "Top edge"), String(localized: "Right edge"),
						 String(localized: "Bottom edge"), String(localized: "Left edge")]
			return names[QuadEditing.visualIndex(index, quarterTurns: quarterTurns)]
		case .body:
			return String(localized: "Crop area")
		}
	}

	static func mode(_ mode: CaptureMode?) -> LocalizedStringKey {
		switch mode {
		case .document?: return "Document"
		case .whiteboard?: return "Whiteboard"
		case nil: return "As is"
		}
	}
}

// MARK: - Editor

struct PageEditorView: View {
	@Environment(\.dismiss) private var dismiss
	@State private var model: PageEditorModel
	@State private var confirmingRebuild = false
	/// What the confirmation warns about: only this page's Review work, or the whole document's.
	@State private var redoesOnlyThisPage = true
	/// True when the confirmation is for splitting the page, not updating it.
	@State private var confirmingSplit = false
	/// Called with a confirmation to show once the page has been updated.
	let onUpdated: (String) -> Void

	init(capture: ScanCapture, onUpdated: @escaping (String) -> Void) {
		_model = State(initialValue: PageEditorModel(capture: capture))
		self.onUpdated = onUpdated
	}

	var body: some View {
		ZStack {
			Color.darkroom.ignoresSafeArea()
			VStack(spacing: 0) {
				topBar
				canvas
				controls
			}
			if model.isApplying {
				applyingCard
			}
		}
		.statusBarHidden()
		.task { await model.load() }
		.confirmationDialog(confirmingSplit ? "Split this page?" : "Update this page?", isPresented: $confirmingRebuild, titleVisibility: .visible) {
			if confirmingSplit {
				Button("Split the page") { performSplit() }
			} else {
				Button("Update the page") { apply() }
			}
			Button("Keep editing", role: .cancel) {}
		} message: {
			confirmationMessage
		}
	}

	private var confirmationMessage: Text {
		if !redoesOnlyThisPage {
			return Text("This scan has been rebuilt. Changing a page clears the whole rebuilt document, so the fixes, notes and formatting you added in Review, on every page, will be lost. The next rebuild starts again from the pages.")
		}
		if confirmingSplit {
			return Text("This scan has been rebuilt. Only this page is rebuilt again, as two pages: the fixes and formatting you added to it in Review will be redone, and its notes kept where their words read the same. Every other page keeps its Review changes.")
		}
		return Text("This scan has been rebuilt. Only this page is rebuilt again: the fixes and formatting you added to it in Review will be redone, and its notes kept where their words read the same. Every other page keeps its Review changes.")
	}

	private var topBar: some View {
		HStack {
			Button {
				dismiss()
			} label: {
				Text("Cancel")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.printInk)
					.frame(height: 40)
					.padding(.horizontal, 16)
					.background(Color.chalk, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
			}
			.buttonStyle(PressScaleStyle(scale: 0.94))
			.accessibilityHint("Leaves the page as it was")
			Spacer()
			Text("Adjust page")
				.font(RescrivaFont.ui(15, weight: .medium))
				.foregroundStyle(.chalk)
				.accessibilityAddTraits(.isHeader)
			Spacer()
			Button(action: done) {
				Text("Done")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.vellum)
					.frame(height: 40)
					.padding(.horizontal, 18)
					.background(Color.ink, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
			}
			.buttonStyle(PressScaleStyle(scale: 0.94))
			.disabled(model.availability == .loading || model.isApplying || model.isSplitting)
			.accessibilityHint(model.hasChanges ? "Re-makes the page with your changes" : "Closes without changes")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}

	@ViewBuilder
	private var canvas: some View {
		if let image = model.displayImage(), let base = model.baseImage {
			CropCanvas(
				image: image,
				pixelSize: CGSize(width: base.width, height: base.height),
				turns: model.displayTurns,
				showsCrop: model.canEditCrop,
				editsCrop: model.canEditCrop && !model.isSplitting,
				quad: $model.state.quad,
				onDragEnded: { model.finishDrag(from: $0) },
				onNudge: { handle, delta in model.nudge(handle, by: delta) },
				split: model.splitLine.map { line in
					SplitLineControl(start: line.start, end: line.end, fraction: model.splitFraction ?? 0.5,
									 onMove: { model.moveSplit(toward: $0) }, onNudge: { model.nudgeSplit(by: $0) })
				}
			)
		} else {
			Group {
				if model.availability == .loading {
					ProgressView().tint(.chalk)
					} else {
						Text("This page has no image to adjust.")
							.font(RescrivaFont.ui(14))
							.foregroundStyle(Color.chalk.opacity(0.8))
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}

	private var controls: some View {
		FrostedBottomBar {
			if model.isSplitting {
				splitControls
			} else {
				editControls
			}
		}
	}

	@ViewBuilder
	private var editControls: some View {
		note
		HStack(spacing: 0) {
			EditorTool(title: "Undo", systemImage: "arrow.uturn.backward", isEnabled: model.history.canUndo) { model.undo() }
			EditorTool(title: "Redo", systemImage: "arrow.uturn.forward", isEnabled: model.history.canRedo) { model.redo() }
			if model.canEditCrop {
				EditorTool(title: "Reset", systemImage: "arrow.counterclockwise", isEnabled: true) { model.resetCrop() }
					.accessibilityHint("Puts the crop back on the page found in the photo")
				EditorTool(title: "Full image", systemImage: "arrow.up.left.and.arrow.down.right", isEnabled: true) { model.useFullImage() }
			}
			if model.canOfferSplit {
				EditorTool(title: "Split", systemImage: "rectangle.split.2x1", isEnabled: true) {
					Task { await model.beginSplit() }
				}
				.accessibilityLabel("Split into two pages")
				.accessibilityHint("For a photo of two facing pages: splits it along the fold")
			}
		}
		modeRow
		errorText
	}

	private var modeRow: some View {
		HStack(spacing: 12) {
			CircleIconButton(systemName: "rotate.left", label: "Rotate left") { model.rotate(by: -1) }
			if model.canEditCrop {
				// Labelled as a group: a label on the picker itself would replace each segment's name.
				RescrivaSegmentedPicker(options: model.modeOptions, selection: modeSelection) { PageEditorLabels.mode($0) }
					.accessibilityElement(children: .contain)
					.accessibilityLabel("Cleanup")
			} else {
				Spacer()
			}
			CircleIconButton(systemName: "rotate.right", label: "Rotate right") { model.rotate(by: 1) }
		}
	}

	@ViewBuilder
	private var errorText: some View {
		if let message = model.errorMessage {
			Text(message)
				.font(RescrivaFont.ui(12))
				.foregroundStyle(.vermilion)
				.multilineTextAlignment(.center)
		}
	}

	/// The bar while a spread is being split: where the line is, then split, or keep the page whole.
	@ViewBuilder
	private var splitControls: some View {
		Text(splitNoteText)
			.font(RescrivaFont.ui(12))
			.lineSpacing(2)
			.foregroundStyle(.graphite)
			.multilineTextAlignment(.center)
			.fixedSize(horizontal: false, vertical: true)
		HStack(spacing: 12) {
			Button {
				model.cancelSplit()
			} label: {
				Text("Keep one page")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.carbon)
					.frame(height: 48)
					.padding(.horizontal, 18)
					.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
			}
			.buttonStyle(PressScaleStyle(scale: 0.94))
			.disabled(model.isApplying)
			PrimaryButton(title: "Split in two", systemImage: "rectangle.split.2x1", height: 48,
						  isBusy: model.isApplying || model.isFindingFold) { split() }
		}
		errorText
	}

	private var splitNoteText: String {
		if model.isFindingFold { return String(localized: "Finding the fold…") }
		return model.foundFold
			? String(localized: "The line is in the gap between the pages. Drag it onto the fold if it's off.")
			: String(localized: "No clear fold was found, so the line starts in the middle. Drag it onto the fold.")
	}

	private var note: some View {
		Text(noteText)
			.font(RescrivaFont.ui(12))
			.lineSpacing(2)
			.foregroundStyle(.graphite)
			.multilineTextAlignment(.center)
			.fixedSize(horizontal: false, vertical: true)
	}

	private var noteText: String {
		switch model.availability {
		case .loading: return String(localized: "Opening the original…")
		case .full: return String(localized: "Drag a corner, an edge or the middle.")
		case .rotateOnly(let reason): return reason
		}
	}

	private var modeSelection: Binding<CaptureMode?> {
		Binding(get: { model.state.mode }, set: { model.setMode($0) })
	}

	private var applyingCard: some View {
		VStack(spacing: 12) {
			ProgressView().tint(.ink)
			Text("Re-making the page…")
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(.carbon)
		}
		.padding(24)
		.paperCard()
		.rescrivaShadow(.small)
		.accessibilityElement(children: .combine)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color.darkroom.opacity(0.35).ignoresSafeArea())
	}

	// MARK: Actions

	private func done() {
		guard model.hasChanges else {
			dismiss()
			return
		}
		if model.capture.parent?.rebuiltData != nil {
			redoesOnlyThisPage = PageReprocessor.splicesRebuiltPage(of: model.capture)
			confirmingSplit = false
			confirmingRebuild = true
		} else {
			apply()
		}
	}

	private func apply() {
		Task {
			guard await model.apply() else { return }
			onUpdated(String(localized: "Page updated"))
			dismiss()
		}
	}

	/// Splits the page, after a warning when the scan has been rebuilt.
	private func split() {
		guard model.splitFraction != nil, !model.isApplying else { return }
		if model.capture.parent?.rebuiltData != nil {
			redoesOnlyThisPage = PageReprocessor.splicesRebuiltPage(of: model.capture)
			confirmingSplit = true
			confirmingRebuild = true
		} else {
			performSplit()
		}
	}

	private func performSplit() {
		Task {
			guard await model.applySplit() else { return }
			onUpdated(String(localized: "Split into two pages"))
			dismiss()
		}
	}
}

// MARK: - Canvas

/// The photo with the crop drawn over it, the drag that edits the crop, and the loupe; or, while a
/// spread is being split, the split line.
private struct CropCanvas: View {
	let image: UIImage
	/// The base image's pixel size, upright and unturned.
	let pixelSize: CGSize
	let turns: Int
	/// Draws the crop over the photo.
	let showsCrop: Bool
	/// Lets the crop be dragged.
	let editsCrop: Bool
	@Binding var quad: PageQuad
	let onDragEnded: (PageQuad) -> Void
	/// Moves a handle by a normalized step (VoiceOver); returns false when refused.
	let onNudge: (QuadHandle, CGVector) -> Bool
	/// The split line, while a spread is being split.
	var split: SplitLineControl?

	@State private var drag: CropDrag?
	/// True while a finger is down. Unlike `drag`, it resets by itself when the system cancels the
	/// gesture (a call, Siri), which skips onEnded.
	@GestureState private var touching = false

	/// Room around the photo so handles on its border stay easy to grab.
	private static let margin: CGFloat = 28
	private static let loupeDiameter: CGFloat = 116
	private static let loupeZoom: CGFloat = 2.5
	private static let loupeGap: CGFloat = 44

	/// A drag in progress: what it grabbed, the crop and the touch it began with, and the finger.
	private struct CropDrag {
		var handle: QuadHandle
		var startQuad: PageQuad
		var startLocation: CGPoint
		var touch: CGPoint
	}

	var body: some View {
		GeometryReader { proxy in
			let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: Self.margin, dy: Self.margin)
			let mapping = QuadViewMapping(imageSize: pixelSize, quarterTurns: turns, fittingIn: bounds)
			let corners = mapping.viewCorners(of: quad)
			ZStack(alignment: .topLeading) {
				CropLayer(image: image, mapping: mapping, corners: showsCrop ? corners : nil)
				if editsCrop {
					CropHandles(corners: corners, turns: turns, active: touching ? drag?.handle : nil) { handle, step in
						onNudge(handle, mapping.normalizedDelta(step))
					}
					if touching, let drag, drag.handle != .body {
						loupe(drag, mapping: mapping, size: proxy.size)
					}
				}
				if let split {
					SplitLineLayer(control: split, mapping: mapping)
				}
			}
			.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
			.contentShape(Rectangle())
			.gesture(dragGesture(mapping), including: editsCrop ? .all : .subviews)
		}
		.onChange(of: touching) { _, isTouching in
			if !isTouching { endDrag() }
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(showsCrop ? Text("Original photo with the crop") : Text("Page"))
	}

	private func dragGesture(_ mapping: QuadViewMapping) -> some Gesture {
		DragGesture(minimumDistance: 0)
			.updating($touching) { _, isTouching, _ in
				isTouching = true
			}
			.onChanged { value in
				var previous = drag
				// A drag the system cancelled never ended: record it before this one starts.
				if let stale = previous, stale.startLocation != value.startLocation {
					onDragEnded(stale.startQuad)
					previous = nil
				}
				let current = previous ?? CropDrag(
					handle: QuadEditing.nearestHandle(to: value.startLocation, corners: mapping.viewCorners(of: quad)),
					startQuad: quad,
					startLocation: value.startLocation,
					touch: value.location
				)
				drag = CropDrag(handle: current.handle, startQuad: current.startQuad, startLocation: current.startLocation, touch: value.location)
				let delta = mapping.normalizedDelta(value.translation)
				if let moved = QuadEditing.moved(current.startQuad, handle: current.handle, by: delta) {
					quad = moved
				}
			}
			.onEnded { _ in
				endDrag()
			}
	}

	/// Records the drag in progress for undo, and forgets it. Runs when the drag ends, or when
	/// `touching` resets after the system cancelled it.
	private func endDrag() {
		guard let finished = drag else { return }
		onDragEnded(finished.startQuad)
		drag = nil
	}

	/// The original magnified around the point being moved, clear of the finger.
	private func loupe(_ drag: CropDrag, mapping: QuadViewMapping, size: CGSize) -> some View {
		let corners = mapping.viewCorners(of: quad)
		let focus = QuadEditing.point(of: drag.handle, corners: corners)
		let diameter = Self.loupeDiameter
		let zoom = Self.loupeZoom
		return CropLayer(image: image, mapping: mapping, corners: corners, lineScale: zoom)
			.frame(width: size.width, height: size.height, alignment: .topLeading)
			.scaleEffect(zoom, anchor: .topLeading)
			.offset(x: diameter / 2 - focus.x * zoom, y: diameter / 2 - focus.y * zoom)
			.frame(width: diameter, height: diameter, alignment: .topLeading)
			.background(Color.darkroom)
			.clipShape(Circle())
			.overlay { LoupeReticle() }
			.rescrivaShadow(.float)
			.position(LoupePlacement.center(touch: drag.touch, diameter: diameter, gap: Self.loupeGap, in: size))
			.allowsHitTesting(false)
			.accessibilityHidden(true)
	}
}

/// The photo, shaded outside the crop, with the crop's outline.
private struct CropLayer: View {
	let image: UIImage
	let mapping: QuadViewMapping
	/// The crop's corners in view space, or nil to show the photo alone.
	let corners: [CGPoint]?
	/// Divides the outline's width, so the loupe's magnified outline stays fine.
	var lineScale: CGFloat = 1

	var body: some View {
		ZStack(alignment: .topLeading) {
			Image(uiImage: image)
				.resizable()
				.frame(width: mapping.frame.width, height: mapping.frame.height)
				.offset(x: mapping.frame.minX, y: mapping.frame.minY)
			if let corners, corners.count == 4 {
				Path { path in
					path.addRect(mapping.frame)
					path.addLines(corners)
					path.closeSubpath()
				}
				.fill(Color.darkroom.opacity(0.55), style: FillStyle(eoFill: true))
				Path { path in
					path.addLines(corners)
					path.closeSubpath()
				}
				.stroke(Color.highlighter, lineWidth: 2 / max(lineScale, 1))
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.accessibilityHidden(true)
	}
}

/// The crop's grab points. Touches go to the canvas's drag (which grabs the nearest handle);
/// VoiceOver moves a handle with its Move actions.
private struct CropHandles: View {
	let corners: [CGPoint]
	let turns: Int
	let active: QuadHandle?
	/// Moves a handle by a step in view space; returns false when the move was refused.
	let onNudge: (QuadHandle, CGSize) -> Bool

	/// VoiceOver's step, in points.
	private static let step: CGFloat = 6

	var body: some View {
		ZStack(alignment: .topLeading) {
			if corners.count == 4 {
				ForEach(QuadHandle.all, id: \.self) { handle in
					marker(for: handle)
						.position(QuadEditing.point(of: handle, corners: corners))
						.accessibilityElement()
						.accessibilityLabel(PageEditorLabels.handle(handle, quarterTurns: turns))
						.accessibilityHint("Use the actions to move it")
						.accessibilityAction(named: "Move up") { nudge(handle, CGSize(width: 0, height: -Self.step)) }
						.accessibilityAction(named: "Move down") { nudge(handle, CGSize(width: 0, height: Self.step)) }
						.accessibilityAction(named: "Move left") { nudge(handle, CGSize(width: -Self.step, height: 0)) }
						.accessibilityAction(named: "Move right") { nudge(handle, CGSize(width: Self.step, height: 0)) }
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.allowsHitTesting(false)
	}

	private func nudge(_ handle: QuadHandle, _ step: CGSize) {
		guard !onNudge(handle, step) else { return }
		UIAccessibility.post(notification: .announcement, argument: String(localized: "Can't move that way"))
	}

	@ViewBuilder
	private func marker(for handle: QuadHandle) -> some View {
		let isActive = active == handle
		switch handle {
		case .corner:
			RoundedRectangle(cornerRadius: 3, style: .continuous)
				.fill(Color.chalk)
				.overlay { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.highlighter, lineWidth: 2.5) }
				.frame(width: isActive ? 28 : 20, height: isActive ? 28 : 20)
				.shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
		case .edge(let index):
			RoundedRectangle(cornerRadius: 2.5, style: .continuous)
				.fill(Color.chalk)
				.overlay { RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Color.highlighter, lineWidth: 2) }
				.frame(width: isActive ? 34 : 26, height: 9)
				.rotationEffect(edgeAngle(index))
				.shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
		case .body:
			Glyph("arrow.up.and.down.and.arrow.left.and.right", size: 14, weight: .semibold)
				.foregroundStyle(Color.chalk.opacity(isActive ? 1 : 0.75))
				.frame(width: 34, height: 34)
				.background(Color.darkroom.opacity(0.4), in: Circle())
		}
	}

	/// The direction of edge `index` on screen, so its grip lies along it.
	private func edgeAngle(_ index: Int) -> Angle {
		guard corners.count == 4 else { return .zero }
		let start = corners[QuarterTurns.normalized(index)]
		let end = corners[QuarterTurns.normalized(index + 1)]
		return .radians(atan2(end.y - start.y, end.x - start.x))
	}
}

/// The split line on the original (its end at the top of the page as shown, then the bottom), and
/// what moving it does.
private struct SplitLineControl {
	let start: CGPoint
	let end: CGPoint
	/// Where the line crosses the page, as a share of its width from the left (VoiceOver reads it).
	let fraction: CGFloat
	/// Moves the line to run through a point (normalized on the original).
	let onMove: (CGPoint) -> Void
	/// Moves the line by a share of the page's width (VoiceOver).
	let onNudge: (CGFloat) -> Void
}

/// The line a spread is split along, with a grip at its middle. A touch anywhere moves the line
/// there; VoiceOver moves it with swipes.
private struct SplitLineLayer: View {
	let control: SplitLineControl
	let mapping: QuadViewMapping

	/// VoiceOver's step, as a share of the page's width.
	private static let step: CGFloat = 0.01

	var body: some View {
		let start = mapping.viewPoint(control.start)
		let end = mapping.viewPoint(control.end)
		ZStack(alignment: .topLeading) {
			Path { path in
				path.move(to: start)
				path.addLine(to: end)
			}
			.stroke(Color.chalk, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
			.shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
			grip
				.position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
				.accessibilityElement()
				.accessibilityLabel("Split line")
				.accessibilityValue(Self.spokenValue(control.fraction))
				.accessibilityHint("Swipe up or down to move it")
				.accessibilityAdjustableAction { direction in
					switch direction {
					case .increment: control.onNudge(Self.step)
					case .decrement: control.onNudge(-Self.step)
					@unknown default: break
					}
				}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.contentShape(Rectangle())
		.gesture(DragGesture(minimumDistance: 0).onChanged { value in
			control.onMove(mapping.normalizedPoint(value.location))
		})
	}

	/// "Left page 48%, right page 52%": where the line sits, as each half's share of the page.
	static func spokenValue(_ fraction: CGFloat) -> String {
		let left = Int((min(max(fraction, 0), 1) * 100).rounded())
		return String(localized: "Left page \(left)%, right page \(100 - left)%")
	}

	private var grip: some View {
		Glyph("arrow.left.and.right", size: 13, weight: .semibold)
			.foregroundStyle(Color.printInk)
			.frame(width: 34, height: 34)
			.background(Color.chalk, in: Circle())
			.overlay { Circle().strokeBorder(Color.highlighter, lineWidth: 2.5) }
			.shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
	}
}

/// The loupe's rim and cross-hair.
private struct LoupeReticle: View {
	var body: some View {
		ZStack {
			Circle().strokeBorder(Color.chalk, lineWidth: 3)
			Rectangle().fill(Color.chalk.opacity(0.9)).frame(width: 14, height: 1.5)
			Rectangle().fill(Color.chalk.opacity(0.9)).frame(width: 1.5, height: 14)
		}
	}
}

/// A small labelled tool in the editor's bar.
private struct EditorTool: View {
	let title: LocalizedStringKey
	let systemImage: String
	var isEnabled = true
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			VStack(spacing: 4) {
				Glyph(systemImage, size: 18, weight: .light)
					.frame(height: 22)
				Text(title)
					.font(RescrivaFont.ui(11, weight: .medium))
			}
			.foregroundStyle(.carbon)
			.frame(maxWidth: .infinity)
			.padding(.vertical, 6)
			.contentShape(Rectangle())
		}
		.buttonStyle(PressScaleStyle())
		.disabled(!isEnabled)
		.opacity(isEnabled ? 1 : 0.35)
	}
}
