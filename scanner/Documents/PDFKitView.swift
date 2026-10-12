//
//  PDFKitView.swift
//  Rescriva (fork of Open Scanner)
//
//  PDFKit's PDFView for SwiftUI. Reading: scroll, zoom, select text, fill form
//  fields, follow links, and find's matches. Markup: one finger draws (or drags
//  across text, or taps to place a note) and two scroll; a stroke the second
//  finger interrupts is dropped, so starting a scroll never leaves a mark. With
//  Apple Pencil on an iPad, only the pencil marks up and fingers scroll. The
//  pointer picks a mark to move, resize or restyle, and one finger scrolls
//  wherever there's no mark. On wide screens (iPad, the unfolded iPhone Duo)
//  pages sit side by side like a book.
//

import PDFKit
import SwiftUI
import UIKit

/// A page to jump to once: a new token means "do it again".
struct PDFViewerRequest: Equatable {
	let page: Int
	let token = UUID()
}

struct PDFKitView: UIViewRepresentable {
	let session: PDFEditSession
	/// Two pages side by side.
	var spread: Bool
	/// In a spread, the first page sits alone on the right like a cover.
	var coverPage: Bool
	var request: PDFViewerRequest?
	/// A tap with the text box or note tool: where (page space) and on which page.
	var onPlace: (PDFMarkupTool, CGPoint, PDFPage) -> Void
	/// A tap on a note or text box while reading, to open it.
	var onOpenAnnotation: (PDFAnnotation) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeUIView(context: Context) -> PDFView {
		let view = PDFView()
		view.document = session.document
		view.displayDirection = .vertical
		view.displayMode = spread ? .twoUpContinuous : .singlePageContinuous
		view.displaysAsBook = coverPage
		view.autoScales = true
		view.pageShadowsEnabled = true
		view.backgroundColor = RescrivaPalette.scanBackdrop
		context.coordinator.attach(to: view)
		return view
	}

	func updateUIView(_ view: PDFView, context: Context) {
		let coordinator = context.coordinator
		coordinator.parent = self
		coordinator.setMarkup(session.mode == .markup && session.canMarkUp, tool: session.tool, pencilOnly: session.pencilOnly)
		if coordinator.lastRevision != session.revision {
			coordinator.lastRevision = session.revision
			view.layoutDocumentView()
			// Rotated, inserted or widened pages change the widest page; fit the width again.
			DispatchQueue.main.async {
				view.autoScales = false
				view.autoScales = true
			}
		}
		let mode: PDFDisplayMode = spread ? .twoUpContinuous : .singlePageContinuous
		if view.displayMode != mode || view.displaysAsBook != coverPage {
			// Keep the reader's place across the change (folding, rotating).
			let page = view.currentPage
			view.displayMode = mode
			view.displaysAsBook = coverPage
			view.autoScales = true
			if let page {
				DispatchQueue.main.async { view.go(to: page) }
			}
		}
		if let request, request.token != coordinator.handledRequest {
			coordinator.handledRequest = request.token
			if let page = session.document.page(at: request.page) { view.go(to: page) }
		}
		coordinator.showFindResults(session.findResults, current: session.findIndex)
		coordinator.refreshSelection()
	}

	static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
		coordinator.detach()
	}

	// MARK: - Coordinator

	@MainActor
	final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
		var parent: PDFKitView
		var lastRevision = -1
		var handledRequest: UUID?
		private var shownFind = ""

		private weak var view: PDFView?
		private weak var foundScrollView: UIScrollView?
		/// The touch types PDFView's own scrolling took before markup narrowed them.
		private var scrollTouchTypes: [NSNumber]?
		private let pan = UIPanGestureRecognizer()
		private let tap = UITapGestureRecognizer()
		private let overlay = CAShapeLayer()
		private let selectionOutline = CAShapeLayer()
		private let selectionHandles = CAShapeLayer()
		private var observers: [NSObjectProtocol] = []
		private var scrollObservations: [NSKeyValueObservation] = []
		private var isMarkingUp = false
		private var pencilOnly = false

		// The stroke in progress.
		private var page: PDFPage?
		private var pagePoints: [CGPoint] = []
		private var viewPoints: [CGPoint] = []
		private var erased: [(annotation: PDFAnnotation, page: PDFPage)] = []
		/// A stroke a scroll interrupted: ignored until the next one starts.
		private var strokeCancelled = false
		/// Where the drawing finger or pencil came down (view space). A pan only begins once it has
		/// moved, so the stroke or the drag starts here, not where the pan began.
		private var touchDown = CGPoint.zero

		// The pointer's drag on a picked mark.
		private var dragHandle: PDFMarkHandle?
		private var dragBefore: PDFMarkSnapshot?
		private var dragStart = CGPoint.zero

		/// How close, in screen points, a touch must come to a handle to take it.
		private static let handleReach: CGFloat = 24

		init(_ parent: PDFKitView) {
			self.parent = parent
		}

		func attach(to view: PDFView) {
			self.view = view
			pan.addTarget(self, action: #selector(handlePan(_:)))
			pan.maximumNumberOfTouches = 1
			pan.delegate = self
			pan.isEnabled = false
			tap.addTarget(self, action: #selector(handleTap(_:)))
			tap.delegate = self
			tap.isEnabled = false
			view.addGestureRecognizer(pan)
			view.addGestureRecognizer(tap)
			let pencil = UIPencilInteraction()
			pencil.delegate = self
			view.addInteraction(pencil)
			styleLayers(in: view)

			let center = NotificationCenter.default
			observers.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.pageChanged() }
			})
			observers.append(center.addObserver(forName: .PDFViewAnnotationHit, object: view, queue: .main) { [weak self] note in
				let annotation = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation
				MainActor.assumeIsolated { self?.annotationHit(annotation) }
			})
			observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.refreshSelection() }
			})
		}

		func detach() {
			observers.forEach(NotificationCenter.default.removeObserver)
			observers.removeAll()
			scrollObservations.removeAll()
		}

		private func styleLayers(in view: PDFView) {
			overlay.fillColor = nil
			overlay.lineCap = .round
			overlay.lineJoin = .round
			selectionOutline.fillColor = nil
			selectionOutline.strokeColor = RescrivaPalette.carbon.onPaper.cgColor
			selectionOutline.lineWidth = 1.5
			selectionOutline.lineDashPattern = [6, 4]
			selectionHandles.fillColor = RescrivaPalette.vellum.onPaper.cgColor
			selectionHandles.strokeColor = RescrivaPalette.carbon.onPaper.cgColor
			selectionHandles.lineWidth = 1.5
			for layer in [overlay, selectionOutline, selectionHandles] {
				view.layer.addSublayer(layer)
			}
		}

		// MARK: Input

		/// Markup's input: one finger marks up and two scroll, or (pencil-only) Apple Pencil marks up
		/// and fingers scroll. The pointer lets one finger scroll wherever there's no mark.
		func setMarkup(_ enabled: Bool, tool: PDFMarkupTool, pencilOnly: Bool) {
			isMarkingUp = enabled
			self.pencilOnly = enabled && pencilOnly
			let markTypes: [UITouch.TouchType] = self.pencilOnly ? [.pencil] : [.direct, .pencil, .indirectPointer]
			pan.allowedTouchTypes = markTypes.map { NSNumber(value: $0.rawValue) }
			tap.allowedTouchTypes = pan.allowedTouchTypes
			pan.isEnabled = enabled && !tool.placesOnTap
			tap.isEnabled = enabled && (tool.placesOnTap || tool == .eraser || tool == .select)
			guard let scroll = scrollView else { return }
			let oneFingerScrolls = !enabled || self.pencilOnly || tool == .select
			scroll.panGestureRecognizer.minimumNumberOfTouches = oneFingerScrolls ? 1 : 2
			if scrollTouchTypes == nil { scrollTouchTypes = scroll.panGestureRecognizer.allowedTouchTypes }
			let fingers = [UITouch.TouchType.direct, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) }
			scroll.panGestureRecognizer.allowedTouchTypes = self.pencilOnly ? fingers : (scrollTouchTypes ?? fingers)
			if !enabled { clearStroke() }
		}

		private var scrollView: UIScrollView? {
			if let foundScrollView { return foundScrollView }
			guard let view else { return nil }
			var queue: [UIView] = view.subviews
			while !queue.isEmpty {
				let next = queue.removeFirst()
				if let scroll = next as? UIScrollView {
					foundScrollView = scroll
					observeScrolling(scroll)
					return scroll
				}
				queue.append(contentsOf: next.subviews)
			}
			return nil
		}

		/// The picked mark's outline follows the page as it scrolls and zooms.
		private func observeScrolling(_ scroll: UIScrollView) {
			scrollObservations = [
				scroll.observe(\.contentOffset) { [weak self] _, _ in
					DispatchQueue.main.async { self?.refreshSelection() }
				},
				scroll.observe(\.zoomScale) { [weak self] _, _ in
					DispatchQueue.main.async { self?.refreshSelection() }
				},
			]
		}

		/// True while PDFView's own scrolling or zooming is under way.
		private var isScrolling: Bool {
			guard let scroll = scrollView else { return false }
			let active: Set<UIGestureRecognizer.State> = [.began, .changed]
			return active.contains(scroll.panGestureRecognizer.state) || active.contains(scroll.pinchGestureRecognizer?.state ?? .possible)
		}

		/// Highlights every match and brings the current one into view.
		func showFindResults(_ results: [PDFSelection], current: Int?) {
			guard let view, parent.session.mode == .read else { return }
			let state = "\(results.count)-\(current ?? -1)"
			guard state != shownFind else { return }
			shownFind = state
			var shown = results
			if let current, results.indices.contains(current), let emphasized = results[current].copy() as? PDFSelection {
				// The match you're on, drawn stronger over the rest.
				emphasized.color = RescrivaPalette.vermilion.onPaper.withAlphaComponent(0.5)
				shown.append(emphasized)
				view.go(to: results[current])
			}
			view.highlightedSelections = shown.isEmpty ? nil : shown
		}

		private func pageChanged() {
			guard let view, let page = view.currentPage else { return }
			let index = parent.session.document.index(for: page)
			if index != NSNotFound { parent.session.currentPageIndex = index }
		}

		private func annotationHit(_ annotation: PDFAnnotation?) {
			guard parent.session.mode == .read, let annotation, annotation.type == "Text" || annotation.type == "FreeText" else { return }
			parent.onOpenAnnotation(annotation)
		}

		// MARK: Gestures

		func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
			if touch.type == .pencil { parent.session.pencilTouched() }
			if gestureRecognizer === pan, let view { touchDown = touch.location(in: view) }
			return true
		}

		/// The pointer's drag starts only on the picked mark's handle or on a mark; anywhere else the
		/// page scrolls.
		func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
			guard gestureRecognizer === pan, parent.session.tool == .select, let view else { return true }
			return dragTarget(at: touchDown, in: view) != nil
		}

		/// Drawing runs alongside PDFView's scrolling so a second finger can take over (the stroke is
		/// dropped); with Apple Pencil, fingers scroll while the pencil draws.
		func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
			guard gestureRecognizer === pan, let scroll = scrollView else { return false }
			guard other === scroll.panGestureRecognizer || other === scroll.pinchGestureRecognizer else { return false }
			return pencilOnly || parent.session.tool != .select
		}

		/// With the pointer, one-finger scrolling waits to see whether the touch took a mark.
		func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
			gestureRecognizer === pan && !pencilOnly && parent.session.tool == .select && other === scrollView?.panGestureRecognizer
		}

		@objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
			guard let view, let (page, point) = pagePoint(recognizer.location(in: view), in: view) else { return }
			let session = parent.session
			switch session.tool {
			case .select:
				withAnimation(RescrivaMotion.fast) { session.select(session.mark(at: point, on: page), on: page) }
			case .eraser:
				session.erase(at: point, on: page)
			case .text, .note:
				parent.onPlace(session.tool, point, page)
			default:
				break
			}
		}

		@objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
			guard let view else { return }
			if parent.session.tool == .select {
				handleDrag(recognizer, in: view)
			} else {
				handleStroke(recognizer, in: view)
			}
		}

		/// The page under `location` and the point on it, in page space.
		private func pagePoint(_ location: CGPoint, in view: PDFView) -> (PDFPage, CGPoint)? {
			guard let page = view.page(for: location, nearest: true) else { return nil }
			return (page, view.convert(location, to: page))
		}

		// MARK: Strokes

		private func handleStroke(_ recognizer: UIPanGestureRecognizer, in view: PDFView) {
			let session = parent.session
			let location = recognizer.location(in: view)
			switch recognizer.state {
			case .began:
				strokeCancelled = false
				guard let (page, start) = pagePoint(touchDown, in: view) else { return }
				if pencilOnly { holdPageStill() }
				self.page = page
				pagePoints = [start, view.convert(location, to: page)]
				viewPoints = [touchDown, location]
				erased = []
				styleOverlay(for: session, scale: view.scaleFactor)
				if session.tool == .eraser { eraseLive(at: pagePoints[1], on: page) }
			case .changed:
				guard !strokeCancelled, let page else { return }
				// Two fingers: the reader meant to scroll. Drop the stroke rather than leave a mark.
				if !pencilOnly && isScrolling { return cancelStroke() }
				extendStroke(to: location, on: page, in: view, session: session)
			case .ended:
				if !strokeCancelled { finishStroke(in: view, session: session) }
				clearStroke()
			default:
				if !erased.isEmpty { session.recordApplied(.removeAnnotations(erased)) }
				clearStroke()
			}
		}

		private func extendStroke(to location: CGPoint, on page: PDFPage, in view: PDFView, session: PDFEditSession) {
			let point = view.convert(location, to: page)
			pagePoints.append(point)
			viewPoints.append(location)
			if session.tool.marksText {
				showSelection(on: page, in: view, session: session)
			} else if session.tool == .eraser {
				eraseLive(at: point, on: page)
			} else {
				drawOverlay(for: session.tool)
			}
		}

		/// Stops a scroll a resting palm started, so the page holds still under Apple Pencil.
		private func holdPageStill() {
			guard let recognizer = scrollView?.panGestureRecognizer, isScrolling else { return }
			recognizer.isEnabled = false
			recognizer.isEnabled = true
		}

		/// Drops the stroke in progress; anything it erased comes back.
		private func cancelStroke() {
			for item in erased { item.page.addAnnotation(item.annotation) }
			erased = []
			strokeCancelled = true
			overlay.path = nil
			view?.highlightedSelections = nil
		}

		private func finishStroke(in view: PDFView, session: PDFEditSession) {
			guard let page, let start = pagePoints.first, let end = pagePoints.last else { return }
			let color = session.currentColor
			let size = session.currentSize
			switch session.tool {
			case .pen:
				if let ink = PDFMarkupFactory.ink(simplified(pagePoints), color: color, width: size) { session.add([ink], on: page) }
			case .highlighter:
				if let ink = PDFMarkupFactory.ink(simplified(pagePoints), color: color, width: size, alpha: PDFMarkupPalette.highlighterAlpha) {
					session.add([ink], on: page)
				}
			case .line, .arrow, .rectangle, .ellipse:
				if let shape = PDFMarkupFactory.shape(session.tool, from: start, to: end, color: color, width: size) { session.add([shape], on: page) }
			case .highlight, .underline, .strikeOut:
				if let selection = page.selection(from: start, to: end) {
					session.add(PDFMarkupFactory.textMarks(session.tool, over: selection, on: page, color: color), on: page)
				}
			case .eraser:
				if !erased.isEmpty { session.recordApplied(.removeAnnotations(erased)) }
			case .text, .note, .select:
				break
			}
		}

		private func eraseLive(at point: CGPoint, on page: PDFPage) {
			guard let annotation = page.annotations.last(where: { PDFMarkupFactory.isErasable($0) && PDFMarkupFactory.hitTest($0, point) }) else { return }
			if let popup = annotation.popup { page.removeAnnotation(popup) }
			page.removeAnnotation(annotation)
			erased.append((annotation, page))
		}

		// MARK: The pointer

		/// What a drag starting at `location` (view space) takes: the picked mark's handle, else the
		/// topmost movable mark there (which becomes the picked one).
		private func dragTarget(at location: CGPoint, in view: PDFView) -> (handle: PDFMarkHandle, annotation: PDFAnnotation, page: PDFPage)? {
			let session = parent.session
			if let selection = session.selection {
				for handle in PDFMarkupFactory.handles(of: selection.annotation) {
					if let center = handleCenter(handle, of: selection, in: view),
					   hypot(center.x - location.x, center.y - location.y) <= Self.handleReach {
						return (handle, selection.annotation, selection.page)
					}
				}
			}
			guard let (page, point) = pagePoint(location, in: view), let mark = session.mark(at: point, on: page),
				  PDFMarkupFactory.isMovable(mark) else { return nil }
			return (.move, mark, page)
		}

		private func handleDrag(_ recognizer: UIPanGestureRecognizer, in view: PDFView) {
			let session = parent.session
			let location = recognizer.location(in: view)
			switch recognizer.state {
			case .began:
				guard let target = dragTarget(at: touchDown, in: view) else { return }
				if session.selection?.annotation !== target.annotation { session.select(target.annotation, on: target.page) }
				dragHandle = target.handle
				dragBefore = PDFMarkSnapshot(of: target.annotation)
				dragStart = view.convert(touchDown, to: target.page)
				drag(to: location, in: view)
			case .changed:
				drag(to: location, in: view)
			case .ended, .cancelled, .failed:
				if let selection = session.selection, let before = dragBefore {
					session.recordReshape(selection.annotation, from: before)
				}
				dragHandle = nil
				dragBefore = nil
			default:
				break
			}
		}

		/// Moves the picked mark, or its corner or line end, to follow the touch.
		private func drag(to location: CGPoint, in view: PDFView) {
			guard let selection = parent.session.selection, let handle = dragHandle, let before = dragBefore else { return }
			let page = selection.page, annotation = selection.annotation
			let crop = page.bounds(for: .cropBox)
			let point = view.convert(location, to: page)
			var after = before
			switch handle {
			case .move:
				after.bounds = PDFMarkupFactory.moved(before.bounds, by: CGVector(dx: point.x - dragStart.x, dy: point.y - dragStart.y), within: crop)
			case .corner:
				// The opposite corner stays put; done in screen space so a rotated page behaves.
				let shown = view.convert(before.bounds, from: page)
				let corner = CGPoint(x: max(location.x, shown.minX + 12), y: max(location.y, shown.minY + 12))
				after.bounds = view.convert(CGRect(x: shown.minX, y: shown.minY, width: corner.x - shown.minX, height: corner.y - shown.minY), to: page)
			case .lineStart, .lineEnd:
				guard let start = before.startPoint, let end = before.endPoint else { return }
				let origin = before.bounds.origin
				let clamped = CGPoint(x: min(max(point.x, crop.minX), crop.maxX), y: min(max(point.y, crop.minY), crop.maxY))
				let fixed = CGPoint(x: origin.x + (handle == .lineStart ? end.x : start.x), y: origin.y + (handle == .lineStart ? end.y : start.y))
				let line = handle == .lineStart
					? PDFMarkupFactory.lineGeometry(from: clamped, to: fixed, width: before.lineWidth ?? 1)
					: PDFMarkupFactory.lineGeometry(from: fixed, to: clamped, width: before.lineWidth ?? 1)
				after.bounds = line.bounds
				after.startPoint = line.start
				after.endPoint = line.end
			}
			after.apply(to: annotation)
			view.annotationsChanged(on: page)
			refreshSelection()
		}

		private func handleCenter(_ handle: PDFMarkHandle, of selection: PDFMarkSelection, in view: PDFView) -> CGPoint? {
			let annotation = selection.annotation
			let origin = annotation.bounds.origin
			switch handle {
			case .move:
				return nil
			case .corner:
				let shown = view.convert(annotation.bounds, from: selection.page)
				return CGPoint(x: shown.maxX, y: shown.maxY)
			case .lineStart:
				return view.convert(CGPoint(x: origin.x + annotation.startPoint.x, y: origin.y + annotation.startPoint.y), from: selection.page)
			case .lineEnd:
				return view.convert(CGPoint(x: origin.x + annotation.endPoint.x, y: origin.y + annotation.endPoint.y), from: selection.page)
			}
		}

		/// Draws the picked mark's dashed outline and handles where the page now shows it.
		func refreshSelection() {
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			defer { CATransaction.commit() }
			guard let view, let selection = parent.session.selection, isMarkingUp else {
				selectionOutline.path = nil
				selectionHandles.path = nil
				return
			}
			selectionOutline.frame = view.bounds
			selectionHandles.frame = view.bounds
			let shown = view.convert(selection.annotation.bounds, from: selection.page).insetBy(dx: -6, dy: -6)
			selectionOutline.path = UIBezierPath(roundedRect: shown, cornerRadius: 6).cgPath
			let handles = UIBezierPath()
			for handle in PDFMarkupFactory.handles(of: selection.annotation) {
				guard let center = handleCenter(handle, of: selection, in: view) else { continue }
				handles.append(UIBezierPath(ovalIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)))
			}
			selectionHandles.path = handles.cgPath
		}

		// MARK: Apple Pencil

		@available(iOS 17.5, *)
		func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
			pencilDoubleTapped()
		}

		func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
			pencilDoubleTapped()
		}

		/// Apple Pencil's double tap does what the system setting says: the eraser, or the last tool.
		private func pencilDoubleTapped() {
			let session = parent.session
			session.pencilTouched()
			guard isMarkingUp else { return }
			switch UIPencilInteraction.preferredTapAction {
			case .switchEraser: session.pencilDoubleTapped(switchesToEraser: true)
			case .switchPrevious: session.pencilDoubleTapped(switchesToEraser: false)
			default: break
			}
		}

		// MARK: Live feedback

		private func styleOverlay(for session: PDFEditSession, scale: CGFloat) {
			let tool = session.tool
			let alpha = tool == .highlighter ? PDFMarkupPalette.highlighterAlpha : 1
			overlay.strokeColor = session.currentColor.withAlphaComponent(alpha).cgColor
			overlay.lineWidth = max(session.currentSize * scale, 1)
			overlay.frame = view?.bounds ?? .zero
		}

		private func drawOverlay(for tool: PDFMarkupTool) {
			guard let start = viewPoints.first, let end = viewPoints.last else { return }
			let path = UIBezierPath()
			switch tool {
			case .pen, .highlighter:
				path.move(to: start)
				for point in viewPoints.dropFirst() { path.addLine(to: point) }
			case .line, .arrow:
				path.move(to: start)
				path.addLine(to: end)
			case .rectangle:
				path.append(UIBezierPath(rect: CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))))
			case .ellipse:
				path.append(UIBezierPath(ovalIn: CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))))
			default:
				break
			}
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			overlay.path = path.cgPath
			CATransaction.commit()
		}

		private func showSelection(on page: PDFPage, in view: PDFView, session: PDFEditSession) {
			guard let start = pagePoints.first, let end = pagePoints.last, let selection = page.selection(from: start, to: end) else { return }
			selection.color = session.currentColor.withAlphaComponent(0.45)
			view.highlightedSelections = [selection]
		}

		private func clearStroke() {
			page = nil
			pagePoints = []
			viewPoints = []
			erased = []
			overlay.path = nil
			view?.highlightedSelections = nil
		}

		/// Drops points closer than half a point to the last kept one, so long strokes stay small.
		private func simplified(_ points: [CGPoint]) -> [CGPoint] {
			var kept: [CGPoint] = []
			for point in points {
				if let last = kept.last, hypot(point.x - last.x, point.y - last.y) < 0.5 { continue }
				kept.append(point)
			}
			if let last = points.last, kept.last != last { kept.append(last) }
			return kept
		}
	}
}
