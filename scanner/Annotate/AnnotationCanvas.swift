//
//  AnnotationCanvas.swift
//  Rescriva (fork of Open Scanner)
//
//  The annotate canvas: the page fitted to the screen, drawn on with one
//  finger (or Apple Pencil) and zoomed or panned with two. The page and its
//  saved marks redraw only when they change; the mark in progress lives in
//  its own thin layer so drawing stays smooth on large scans.
//

import SwiftUI
import UIKit

/// What the canvas draws with right now.
struct CanvasBrush: Equatable {
	var tool: AnnotationTool
	var color: UInt32
	var width: Double
}

struct AnnotationCanvas: UIViewRepresentable {
	let pageID: UUID
	let image: UIImage?
	let marks: [PageMark]
	let brush: CanvasBrush
	let onCommit: (PageMark) -> Void
	let onErase: (Set<UUID>) -> Void

	func makeUIView(context: Context) -> AnnotationCanvasView {
		AnnotationCanvasView()
	}

	func updateUIView(_ view: AnnotationCanvasView, context: Context) {
		view.surface.brush = brush
		view.surface.onCommit = onCommit
		view.surface.onErase = onErase
		view.show(pageID: pageID, image: image, marks: marks)
	}
}

/// Hosts the zoomable page.
final class AnnotationCanvasView: UIView, UIScrollViewDelegate {
	let surface = DrawingSurface()
	private let scrollView = UIScrollView()
	private var pageID: UUID?
	/// The page's shape; US Letter until an image arrives.
	private var imageSize = CGSize(width: 612, height: 792)

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = .clear
		scrollView.delegate = self
		scrollView.minimumZoomScale = 1
		scrollView.maximumZoomScale = 5
		scrollView.delaysContentTouches = false
		scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
		scrollView.showsHorizontalScrollIndicator = false
		scrollView.showsVerticalScrollIndicator = false
		scrollView.contentInsetAdjustmentBehavior = .never
		addSubview(scrollView)
		scrollView.addSubview(surface)
	}

	required init?(coder: NSCoder) {
		return nil
	}

	/// Shows `pageID`'s image and marks, zooming back out when the page changes.
	func show(pageID: UUID, image: UIImage?, marks: [PageMark]) {
		if pageID != self.pageID {
			self.pageID = pageID
			surface.cancelGesture()
			scrollView.setZoomScale(1, animated: false)
			surface.zoomScale = 1
		}
		if let image, image.size.width > 0, image.size.height > 0, image.size != imageSize {
			imageSize = image.size
			setNeedsLayout()
		}
		surface.pageView.image = image
		surface.pageView.marks = marks
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		scrollView.frame = bounds
		let available = bounds.insetBy(dx: 16, dy: 12).size
		guard available.width > 0, available.height > 0, imageSize.width > 0, imageSize.height > 0 else { return }
		let scale = min(available.width / imageSize.width, available.height / imageSize.height)
		let fitted = CGSize(width: (imageSize.width * scale).rounded(), height: (imageSize.height * scale).rounded())
		if surface.bounds.size != fitted {
			// Resize at zoom 1 so the surface's transform doesn't distort its frame.
			scrollView.setZoomScale(1, animated: false)
			surface.zoomScale = 1
			surface.frame = CGRect(origin: .zero, size: fitted)
			scrollView.contentSize = fitted
		}
		centerContent()
	}

	/// Keeps the page centered while it's smaller than the screen.
	private func centerContent() {
		let content = scrollView.contentSize
		let x = max((scrollView.bounds.width - content.width) / 2, 0)
		let y = max((scrollView.bounds.height - content.height) / 2, 0)
		scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
	}

	func viewForZooming(in scrollView: UIScrollView) -> UIView? {
		surface
	}

	func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
		surface.cancelGesture()
	}

	func scrollViewDidZoom(_ scrollView: UIScrollView) {
		centerContent()
	}

	func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
		surface.zoomScale = scale
	}
}

/// The zoomed content: the page with its marks, the mark in progress and the
/// one-finger touch handling. Two-finger gestures belong to the scroll view,
/// which cancels any stroke they interrupt.
final class DrawingSurface: UIView {
	/// On-screen distances, divided by the zoom so they feel the same at any zoom.
	private static let sampleSpacing: CGFloat = 0.8
	private static let simplifyTolerance: CGFloat = 0.3
	private static let smallestShape: CGFloat = 4
	private static let eraserRadius: CGFloat = 12
	/// Caps the backing store when zoomed in, so a big page can't exhaust memory.
	private static let maxBackingPixels: CGFloat = 3200

	let pageView = PageMarksView()
	private let liveView = LiveMarkView()

	var brush = CanvasBrush(tool: .pen, color: 0, width: 0.0045)
	var onCommit: (PageMark) -> Void = { _ in }
	var onErase: (Set<UUID>) -> Void = { _ in }
	var zoomScale: CGFloat = 1 {
		didSet { updateResolution() }
	}

	private var live: PageMark?
	/// The stroke in progress in this view's coordinates.
	private var viewPoints: [CGPoint] = []
	private var erased: Set<UUID> = []
	private var lastEraserPoint: CGPoint?

	override init(frame: CGRect) {
		super.init(frame: frame)
		isMultipleTouchEnabled = false
		backgroundColor = .clear
		addSubview(pageView)
		addSubview(liveView)
		isAccessibilityElement = true
		accessibilityIdentifier = "annotate.canvas"
		accessibilityLabel = String(localized: "Page")
		accessibilityHint = String(localized: "Draw with one finger. Pinch with two fingers to zoom.")
		accessibilityTraits = .allowsDirectInteraction
	}

	required init?(coder: NSCoder) {
		return nil
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		pageView.frame = bounds
		liveView.frame = bounds
		updateResolution()
	}

	/// Sharpens the drawing after a zoom, within the memory cap.
	private func updateResolution() {
		let longest = max(bounds.width, bounds.height, 1)
		let scale = min(traitCollection.displayScale * max(zoomScale, 1), Self.maxBackingPixels / longest)
		guard scale > 0 else { return }
		for view in [pageView, liveView] as [UIView] where view.contentScaleFactor != scale {
			view.contentScaleFactor = scale
			view.setNeedsDisplay()
		}
	}

	// MARK: Touches

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard let touch = touches.first, bounds.width > 0, bounds.height > 0 else { return }
		cancelGesture()
		let point = touch.location(in: self)
		if brush.tool == .eraser {
			lastEraserPoint = point
			erase(at: point)
		} else if let kind = brush.tool.markKind {
			beginMark(kind, at: point)
		}
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard let touch = touches.first else { return }
		let samples = event?.coalescedTouches(for: touch) ?? [touch]
		for sample in samples {
			let point = sample.location(in: self)
			if lastEraserPoint != nil {
				erase(along: point)
			} else {
				extendMark(to: point)
			}
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard touches.first != nil else { return }
		if lastEraserPoint != nil {
			finishErasing()
		} else if let mark = finishedMark() {
			// Show it straight away; SwiftUI's update with the same marks won't redraw again.
			pageView.marks.append(mark)
			onCommit(mark)
		}
		cancelGesture()
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		cancelGesture()
	}

	/// Drops whatever is in progress (a second finger landed, the page changed…).
	func cancelGesture() {
		live = nil
		viewPoints = []
		erased = []
		lastEraserPoint = nil
		liveView.mark = nil
		liveView.eraser = nil
		pageView.hiddenMarks = []
	}

	// MARK: Drawing

	private func beginMark(_ kind: PageMark.Kind, at point: CGPoint) {
		assert(bounds.width > 0 && bounds.height > 0, "The page is laid out before it can be touched")
		viewPoints = [point]
		let pagePoint = toPage(point)
		let mark = PageMark(kind: kind, points: kind.isFreehand ? [pagePoint] : [pagePoint, pagePoint],
							color: brush.color, width: brush.width)
		live = mark
		liveView.mark = mark
	}

	private func extendMark(to point: CGPoint) {
		guard var mark = live, let start = viewPoints.first, let last = viewPoints.last else { return }
		if mark.kind.isFreehand {
			guard hypot(point.x - last.x, point.y - last.y) >= Self.sampleSpacing / zoomScale else { return }
			viewPoints.append(point)
			mark.points.append(toPage(point))
		} else {
			let end = MarkGeometry.snappedEnd(for: mark.kind, from: start, to: point)
			viewPoints = [start, end]
			mark.points = [toPage(start), toPage(end)]
		}
		live = mark
		liveView.mark = mark
	}

	/// The mark to keep: strokes thinned to the points that shape them,
	/// shapes only when they were dragged far enough to mean it.
	private func finishedMark() -> PageMark? {
		guard var mark = live, let first = viewPoints.first, let last = viewPoints.last else { return nil }
		if mark.kind.isFreehand {
			mark.points = MarkGeometry.simplified(viewPoints, tolerance: Self.simplifyTolerance / zoomScale).map(toPage)
			return mark
		}
		guard hypot(last.x - first.x, last.y - first.y) >= Self.smallestShape / zoomScale else { return nil }
		return mark
	}

	private func toPage(_ point: CGPoint) -> CGPoint {
		PageMark.quantized(CGPoint(x: point.x / max(bounds.width, 1), y: point.y / max(bounds.height, 1)))
	}

	// MARK: Erasing

	/// Tests the eraser at steps along the finger's path so fast swipes don't skip thin strokes.
	private func erase(along point: CGPoint) {
		guard let last = lastEraserPoint else { return }
		let radius = Self.eraserRadius / zoomScale
		let distance = hypot(point.x - last.x, point.y - last.y)
		let steps = min(max(Int((distance / (radius * 0.5)).rounded(.up)), 1), 64)
		for step in 1...steps {
			let t = CGFloat(step) / CGFloat(steps)
			erase(at: CGPoint(x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t))
		}
		lastEraserPoint = point
	}

	private func erase(at point: CGPoint) {
		let radius = Self.eraserRadius / zoomScale
		liveView.eraser = EraserRing(center: point, radius: radius, lineWidth: 1.5 / zoomScale)
		let hits = pageView.marks.filter {
			!erased.contains($0.id) && MarkGeometry.eraser(at: point, radius: radius, hits: $0, in: bounds.size)
		}
		guard !hits.isEmpty else { return }
		erased.formUnion(hits.map(\.id))
		pageView.hiddenMarks = erased
	}

	private func finishErasing() {
		let ids = erased
		guard !ids.isEmpty else { return }
		pageView.marks.removeAll { ids.contains($0.id) }
		onErase(ids)
	}
}

/// The page image and its saved marks. Redraws only when they change.
final class PageMarksView: UIView {
	var image: UIImage? {
		didSet {
			if image !== oldValue { setNeedsDisplay() }
		}
	}

	var marks: [PageMark] = [] {
		didSet {
			if marks != oldValue { setNeedsDisplay() }
		}
	}

	/// Marks the eraser has touched in the stroke in progress.
	var hiddenMarks: Set<UUID> = [] {
		didSet {
			if hiddenMarks != oldValue { setNeedsDisplay() }
		}
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		isOpaque = true
		backgroundColor = UIColor(Color.paper)
		contentMode = .redraw
		isUserInteractionEnabled = false
	}

	required init?(coder: NSCoder) {
		return nil
	}

	override func draw(_ rect: CGRect) {
		guard let context = UIGraphicsGetCurrentContext() else { return }
		UIColor(Color.paper).setFill()
		context.fill(bounds)
		image?.draw(in: bounds)
		let visible = hiddenMarks.isEmpty ? marks : marks.filter { !hiddenMarks.contains($0.id) }
		MarkRenderer.draw(visible, in: bounds, context: context)
	}
}

/// Where the eraser is touching.
struct EraserRing: Equatable {
	var center: CGPoint
	var radius: CGFloat
	var lineWidth: CGFloat
}

/// The mark being drawn and the eraser ring, over the page.
final class LiveMarkView: UIView {
	var mark: PageMark? {
		didSet {
			if mark != oldValue { setNeedsDisplay() }
		}
	}

	var eraser: EraserRing? {
		didSet {
			if eraser != oldValue { setNeedsDisplay() }
		}
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		isOpaque = false
		backgroundColor = .clear
		contentMode = .redraw
		isUserInteractionEnabled = false
	}

	required init?(coder: NSCoder) {
		return nil
	}

	override func draw(_ rect: CGRect) {
		guard let context = UIGraphicsGetCurrentContext() else { return }
		if let mark {
			// This layer can't multiply onto the page, so a highlight in progress is shown translucent.
			MarkRenderer.draw(mark, in: bounds, context: context, alpha: mark.kind == .highlighter ? 0.45 : 1)
		}
		if let eraser {
			let circle = CGRect(x: eraser.center.x - eraser.radius, y: eraser.center.y - eraser.radius,
								width: eraser.radius * 2, height: eraser.radius * 2)
			context.setFillColor(UIColor.white.withAlphaComponent(0.35).cgColor)
			context.fillEllipse(in: circle)
			context.setStrokeColor(RescrivaPalette.carbon.onPaper.withAlphaComponent(0.6).cgColor)
			context.setLineWidth(eraser.lineWidth)
			context.strokeEllipse(in: circle)
		}
	}
}
