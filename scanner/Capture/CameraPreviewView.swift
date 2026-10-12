//
//  CameraPreviewView.swift
//  Rescriva (fork of Open Scanner)
//
//  The live camera preview with the detected-page overlay drawn on top.
//

import AVFoundation
import SwiftUI
import UIKit

// MARK: - CameraPreviewView

/// SwiftUI wrapper around an aspect-fill `AVCaptureVideoPreviewLayer` (portrait) that draws the
/// detected page itself.
///
/// The overlay is the highlighter marking the page: a 2.5 pt outline in yellow chalk (#F2D660), full
/// opacity while the page is steady and 70% otherwise, filled with it at 10%, plus 13 pt chalk-white
/// (#F1EEE6) square corner marks ringed in the same yellow, like a printer's crop marks. Quad changes
/// animate over 0.15 s (ease-out). The overlay fades in when a page appears and out when it
/// disappears.
///
/// `quad` is in the upright video frame (see `PageQuad`). The view converts each corner to
/// AVFoundation's unrotated capture-device space and maps it with
/// `layerPointConverted(fromCaptureDevicePoint:)`, which accounts for the aspect-fill crop and the
/// layer's rotation.
struct CameraPreviewView: UIViewRepresentable {
	let session: AVCaptureSession
	var quad: PageQuad?
	var isSteady: Bool

	func makeUIView(context: Context) -> PreviewLayerView {
		let view = PreviewLayerView()
		view.attach(session)
		return view
	}

	func updateUIView(_ view: PreviewLayerView, context: Context) {
		view.attach(session)
		view.show(quad: quad, isSteady: isSteady)
	}
}

// MARK: - PreviewLayerView

extension CameraPreviewView {

	/// The UIKit view behind `CameraPreviewView`: the preview layer plus the quad overlay layers.
	final class PreviewLayerView: UIView {

		/// Overlay colours and metrics from the Capture screen design.
		private enum Style {
			static let marker = UIColor(red: 0xF2 / 255, green: 0xD6 / 255, blue: 0x60 / 255, alpha: 1)
			static let chalk = UIColor(red: 0xF1 / 255, green: 0xEE / 255, blue: 0xE6 / 255, alpha: 1)
			static let strokeWidth: CGFloat = 2.5
			static let steadyStrokeAlpha: CGFloat = 1
			static let searchingStrokeAlpha: CGFloat = 0.7
			static let fillAlpha: CGFloat = 0.1
			static let dotDiameter: CGFloat = 13
			static let ringWidth: CGFloat = 2.5
			static let animationDuration: CFTimeInterval = 0.15
		}

		private let previewLayer = AVCaptureVideoPreviewLayer()
		private let overlayLayer = CALayer()
		private let quadLayer = CAShapeLayer()
		private let cornerLayers: [CAShapeLayer] = (0..<4).map { _ in CAShapeLayer() }
		private var quad: PageQuad?
		private var isSteady = false
		private var isOverlayVisible = false

		override init(frame: CGRect) {
			super.init(frame: frame)
			setUp()
		}

		required init?(coder: NSCoder) {
			super.init(coder: coder)
			setUp()
		}

		/// Points the preview at `session` (no-op when it already is).
		func attach(_ session: AVCaptureSession) {
			guard previewLayer.session !== session else { return }
			previewLayer.session = session
			NotificationCenter.default.removeObserver(self, name: AVCaptureSession.didStartRunningNotification, object: nil)
			NotificationCenter.default.addObserver(
				self,
				selector: #selector(sessionDidStartRunning),
				name: AVCaptureSession.didStartRunningNotification,
				object: session
			)
			applyPortraitRotation()
		}

		/// Updates the overlay, animating from wherever it currently is. Unchanged input (SwiftUI
		/// re-rendering the parent) is a no-op.
		func show(quad: PageQuad?, isSteady: Bool) {
			applyPortraitRotation()
			guard quad != self.quad || isSteady != self.isSteady else { return }
			self.quad = quad
			self.isSteady = isSteady
			render(animated: true)
		}

		override func layoutSubviews() {
			super.layoutSubviews()
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			previewLayer.frame = bounds
			overlayLayer.frame = bounds
			quadLayer.frame = overlayLayer.bounds
			CATransaction.commit()
			applyPortraitRotation()
			render(animated: false)
		}

		// MARK: Setup

		private func setUp() {
			backgroundColor = .black
			accessibilityIgnoresInvertColors = true
			previewLayer.videoGravity = .resizeAspectFill
			layer.addSublayer(previewLayer)

			overlayLayer.opacity = 0
			layer.addSublayer(overlayLayer)

			quadLayer.lineWidth = Style.strokeWidth
			quadLayer.lineJoin = .miter
			quadLayer.fillColor = Style.marker.withAlphaComponent(Style.fillAlpha).cgColor
			quadLayer.strokeColor = Style.marker.withAlphaComponent(Style.searchingStrokeAlpha).cgColor
			overlayLayer.addSublayer(quadLayer)

			// Inset by half the ring so the mark's outer edge is exactly `dotDiameter`.
			let side = Style.dotDiameter
			let inset = Style.ringWidth / 2
			let square = CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: inset, dy: inset),
								cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
			for dot in cornerLayers {
				dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
				dot.path = square
				dot.fillColor = Style.chalk.cgColor
				dot.strokeColor = Style.marker.cgColor
				dot.lineWidth = Style.ringWidth
				overlayLayer.addSublayer(dot)
			}
		}

		/// The preview layer's connection only exists once the session has a camera input, so this
		/// runs whenever the view updates and again when the session starts.
		private func applyPortraitRotation() {
			guard let connection = previewLayer.connection,
				  connection.isVideoRotationAngleSupported(90),
				  connection.videoRotationAngle != 90 else { return }
			connection.videoRotationAngle = 90
		}

		@objc private nonisolated func sessionDidStartRunning(_ notification: Notification) {
			// Posted on the session's queue; the layer is main-thread state.
			DispatchQueue.main.async { [weak self] in
				MainActor.assumeIsolated {
					self?.applyPortraitRotation()
					self?.render(animated: false)
				}
			}
		}

		// MARK: Overlay

		private func render(animated: Bool) {
			guard let quad, let points = layerPoints(for: quad) else {
				setOverlayVisible(false, animated: animated)
				return
			}
			let path = Self.outline(through: points)
			let strokeAlpha = isSteady ? Style.steadyStrokeAlpha : Style.searchingStrokeAlpha
			let strokeColor = Style.marker.withAlphaComponent(strokeAlpha).cgColor
			// Slide only while visible; a page that just appeared snaps into place and fades in.
			let slide = animated && isOverlayVisible

			CATransaction.begin()
			CATransaction.setDisableActions(true)
			if slide {
				Self.animate(quadLayer, keyPath: "path", from: quadLayer.presentation()?.path ?? quadLayer.path, to: path)
				Self.animate(quadLayer, keyPath: "strokeColor", from: quadLayer.presentation()?.strokeColor ?? quadLayer.strokeColor, to: strokeColor)
				for (dot, point) in zip(cornerLayers, points) {
					let from = dot.presentation()?.position ?? dot.position
					Self.animate(dot, keyPath: "position", from: NSValue(cgPoint: from), to: NSValue(cgPoint: point))
				}
			}
			quadLayer.path = path
			quadLayer.strokeColor = strokeColor
			for (dot, point) in zip(cornerLayers, points) {
				dot.position = point
			}
			CATransaction.commit()
			setOverlayVisible(true, animated: animated)
		}

		/// Maps the quad's corners into this view's coordinates, or nil before the session has a
		/// format to map against.
		private func layerPoints(for quad: PageQuad) -> [CGPoint]? {
			let points = quad.corners.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: Self.captureDevicePoint($0)) }
			guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
			return points
		}

		/// Converts an upright (portrait) frame point to AVFoundation's capture-device space: the
		/// sensor's native landscape orientation, top-left origin. Portrait is the sensor rotated
		/// 90° clockwise, so device (x, y) = portrait (y, 1 − x).
		private static func captureDevicePoint(_ upright: CGPoint) -> CGPoint {
			CGPoint(x: upright.y, y: 1 - upright.x)
		}

		private static func outline(through points: [CGPoint]) -> CGPath {
			let path = CGMutablePath()
			path.addLines(between: points)
			path.closeSubpath()
			return path
		}

		private func setOverlayVisible(_ visible: Bool, animated: Bool) {
			guard visible != isOverlayVisible else { return }
			isOverlayVisible = visible
			let target: Float = visible ? 1 : 0
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			if animated {
				let from = overlayLayer.presentation()?.opacity ?? overlayLayer.opacity
				Self.animate(overlayLayer, keyPath: "opacity", from: NSNumber(value: from), to: NSNumber(value: target))
			}
			overlayLayer.opacity = target
			CATransaction.commit()
		}

		private static func animate(_ layer: CALayer, keyPath: String, from: Any?, to: Any?) {
			let animation = CABasicAnimation(keyPath: keyPath)
			animation.fromValue = from
			animation.toValue = to
			animation.duration = Style.animationDuration
			animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
			layer.add(animation, forKey: keyPath)
		}
	}
}
