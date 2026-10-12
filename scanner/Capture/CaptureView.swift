//
//  CaptureView.swift
//  Rescriva (fork of Open Scanner)
//
//  The Capture screen: a calm darkroom surround, the live camera with the
//  page marked in highlighter, auto-capture once the page is steady,
//  document or whiteboard mode, and a stack of captured pages to Save. Each
//  shot sends a scan line down the viewfinder. The screen is always dark, so
//  it's drawn in chalk. Replaces Open Scanner's VisionKit document camera
//  (PageScan) with Rescriva's own camera.
//

import CoreImage
import SwiftUI
import UIKit

struct CaptureView: View {
	let appendingTo: Scan?

	@Environment(\.managedObjectContext) private var viewContext
	@Environment(RescrivaRouter.self) private var router
	@Environment(\.openURL) private var openURL

	@State private var camera = CaptureCamera()
	@State private var mode: CaptureKind
	@State private var auto: Bool
	@State private var captured: [CapturedPage] = []
	/// Counts shots; each one sends the scan line down the viewfinder.
	@State private var shots = 0
	@State private var isCapturing = false
	/// Set once Save hands the pages (and their staged originals) to a scan.
	@State private var handedOff = false

	init(kind: CaptureKind, appendingTo: Scan?) {
		self.appendingTo = appendingTo
		_mode = State(initialValue: kind)
		_auto = State(initialValue: UserDefaults.standard.bool(forKey: RescrivaPreference.autoCapture))
	}

	/// No camera here (the Simulator): show the illustrated viewfinder and
	/// capture sample pages so the flow can still be tried.
	private var isDemo: Bool {
		#if targetEnvironment(simulator)
		return true
		#else
		return false
		#endif
	}

	var body: some View {
		ZStack {
			Color.darkroom.ignoresSafeArea()
			VStack(spacing: 0) {
				topBar
				viewfinder
				modeChips
				bottomControls
			}
		}
		.task { await startCamera() }
		.onDisappear {
			camera.stop()
			discardUnsaved()
		}
		.onChange(of: mode) { _, newMode in camera.mode = newMode.cameraMode }
		.onChange(of: auto) { _, isOn in
			camera.autoCapture = isOn
			if isOn { scheduleDemoAutoCapture() }
		}
	}

	// MARK: Pieces

	private var topBar: some View {
		HStack {
			Button("Cancel") { router.pop() }
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(.chalk)
				.frame(height: 36)
				.padding(.horizontal, 16)
				.background(Color.chalk.opacity(0.12), in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
			Spacer()
			Button {
				withAnimation(RescrivaMotion.ui) { auto.toggle() }
			} label: {
				HStack(spacing: 6) {
					Glyph("bolt.fill", size: 11)
					Text(auto ? "Auto" : "Manual")
						.font(RescrivaFont.ui(13, weight: .medium))
				}
				.foregroundStyle(auto ? Color.printInk : Color.chalk)
				.frame(height: 36)
				.padding(.horizontal, 14)
				.background(auto ? Color.highlighter : Color.chalk.opacity(0.12), in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
			}
			.accessibilityLabel(auto ? "Auto-capture on" : "Auto-capture off")
		}
		.padding(.horizontal, 20)
		.padding(.top, 12)
		.padding(.bottom, 12)
	}

	private var viewfinder: some View {
		ZStack(alignment: .bottom) {
			Color(hex: 0x24272D)
			if isDemo {
				DemoViewfinder(whiteboard: mode == .whiteboard)
			} else {
				switch camera.status {
				case .denied:
					cameraMessage(String(localized: "Rescriva needs the camera to scan. You can allow it in Settings."), showsSettings: true)
				case .unavailable:
					cameraMessage(String(localized: "This device has no camera Rescriva can use. Import photos or a PDF instead."), showsSettings: false)
				case .failed(let reason):
					cameraMessage(reason, showsSettings: false)
				default:
					CameraPreviewView(session: camera.session, quad: camera.quad, isSteady: camera.isSteady)
				}
			}
			Text(hint)
				.font(RescrivaFont.note(15))
				.foregroundStyle(.chalk)
				.padding(.vertical, 8)
				.padding(.horizontal, 14)
				.background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.background(Color.darkroom.opacity(0.6), in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.padding(.bottom, 18)
				.animation(RescrivaMotion.ui, value: hint)
				.accessibilityAddTraits(.updatesFrequently)
			ScanLinePass(trigger: shots, color: .highlighter)
		}
		.clipShape(RoundedRectangle(cornerRadius: RescrivaRadius.large, style: .continuous))
		.padding(.horizontal, 14)
	}

	private func cameraMessage(_ text: String, showsSettings: Bool) -> some View {
		VStack(spacing: 14) {
			Text(text)
				.font(RescrivaFont.note(16))
				.foregroundStyle(.chalk)
				.multilineTextAlignment(.center)
			if showsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
				Button("Open Settings") { openURL(url) }
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.printInk)
					.padding(.vertical, 10)
					.padding(.horizontal, 18)
					.background(Color.chalk, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
			}
		}
		.padding(32)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	/// Document or whiteboard, as tabs in chalk with a highlighter stroke under the one chosen.
	private var modeChips: some View {
		RescrivaSegmentedPicker(options: [CaptureKind.document, .whiteboard], selection: $mode,
								label: { $0 == .document ? "Document" : "Whiteboard" },
								stroke: .highlighter, chosenText: .chalk, otherText: Color.chalk.opacity(0.6))
			.frame(width: 240)
			.padding(.top, 12)
			.padding(.bottom, 2)
	}

	private var bottomControls: some View {
		HStack {
			capturedStack
				.frame(width: 64, height: 64)
			Spacer()
			Button(action: { Task { await capture() } }) {
				ZStack {
					Circle().strokeBorder(Color.chalk, lineWidth: 4)
					Circle().fill(Color.chalk).padding(8)
				}
				.frame(width: 78, height: 78)
			}
			.buttonStyle(PressScaleStyle())
			.disabled(isCapturing || !canCapture)
			.accessibilityLabel("Take picture")
			Spacer()
			Button(action: save) {
				Text("Save")
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(captured.isEmpty ? Color.chalk.opacity(0.4) : Color.printInk)
					.frame(width: 64, height: 40)
					.background(captured.isEmpty ? Color.chalk.opacity(0.12) : Color.chalk, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
					.animation(RescrivaMotion.ui, value: captured.isEmpty)
			}
			.disabled(captured.isEmpty)
			.accessibilityLabel(captured.isEmpty ? "Save" : "Save \(captured.count) pages")
		}
		.padding(.horizontal, 28)
		.padding(.top, 14)
		.padding(.bottom, 12)
	}

	@ViewBuilder
	private var capturedStack: some View {
		if let last = captured.last {
			ZStack(alignment: .topTrailing) {
				ZStack {
					FoldedSheet(radius: 3, fold: 8)
						.fill(Color.paper.opacity(0.7))
						.padding(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 10))
						.rotationEffect(.degrees(-6))
					Image(uiImage: last.image)
						.resizable()
						.scaledToFill()
						.frame(width: 48, height: 52)
						.foldedPage(radius: 3, fold: 8)
						.shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
						.rotationEffect(.degrees(3))
				}
				Text("\(captured.count)")
					.font(RescrivaFont.ui(12, weight: .medium))
					.foregroundStyle(.printInk)
					.frame(minWidth: 22, minHeight: 22)
					.background(Color.highlighter, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
					.offset(x: 4, y: -4)
			}
			.transition(.settle)
			.accessibilityElement(children: .ignore)
			.accessibilityLabel("\(captured.count) pages captured")
		}
	}

	private var hint: String {
		if captured.isEmpty {
			if !isDemo, camera.status == .running, camera.quad == nil {
				return String(localized: "Looking for the page…")
			}
			return auto ? String(localized: "Hold still — I’ll take it when it’s steady") : String(localized: "Tap the shutter when ready")
		}
		return String(localized: "Got page \(captured.count). Next one whenever you are.")
	}

	private var canCapture: Bool {
		isDemo || camera.status == .running
	}

	// MARK: Camera

	private func startCamera() async {
		camera.mode = mode.cameraMode
		camera.autoCapture = auto
		camera.removeShadows = UserDefaults.standard.bool(forKey: RescrivaPreference.removeShadows)
		camera.keepMarkerColors = UserDefaults.standard.bool(forKey: RescrivaPreference.keepMarkerColors)
		camera.keepsOriginal = UserDefaults.standard.bool(forKey: RescrivaPreference.keepOriginals)
		camera.onAutoCapture = {
			Task { await capture() }
		}
		if isDemo {
			scheduleDemoAutoCapture()
		} else {
			await camera.start()
		}
	}

	/// Mirrors auto-capture in the Simulator: the first page "steadies" after a moment.
	private func scheduleDemoAutoCapture() {
		guard isDemo, auto, captured.isEmpty else { return }
		Task {
			do {
				try await Task.sleep(for: .milliseconds(1600))
			} catch {
				return
			}
			if auto, captured.isEmpty, router.isCameraVisible {
				await capture()
			}
		}
	}

	private func capture() async {
		guard !isCapturing else { return }
		isCapturing = true
		defer { isCapturing = false }
		shots += 1
		UIImpactFeedbackGenerator(style: .soft).impactOccurred()
		if isDemo {
			let page = await Self.demoPage(SampleLibrary.demoCapture(whiteboard: mode == .whiteboard, index: captured.count))
			// The screen may have closed while the page was made; then nobody will save it.
			guard router.isCameraVisible, !handedOff else {
				OriginalStore.shared.discardLater([page.original].compactMap { $0 })
				return
			}
			withAnimation(RescrivaMotion.ui) { captured.append(page) }
			return
		}
		do {
			let page = try await camera.capturePage()
			withAnimation(RescrivaMotion.ui) { captured.append(page) }
		} catch is CancellationError {
			// The camera stopped while the shot was processed: the screen is closing.
		} catch {
			router.showToast(String(localized: "That shot didn’t take — try again."))
		}
	}

	/// A Simulator page: the sample image is its own original (whole frame, no cleanup), so
	/// "Adjust page" can be tried without a camera.
	private static func demoPage(_ image: UIImage) async -> CapturedPage {
		guard UserDefaults.standard.bool(forKey: RescrivaPreference.keepOriginals), let cgImage = image.cgImage else {
			return CapturedPage(image: image)
		}
		let original = await Task.detached(priority: .userInitiated) {
			OriginalStore.shared.stage(CIImage(cgImage: cgImage))
		}.value
		let recipe = PageRecipe(quad: .fullFrame, mode: nil, rotation: 0, removeShadows: true, keepMarkerColors: true)
		return CapturedPage(image: image, original: original, recipe: recipe)
	}

	private func save() {
		guard !captured.isEmpty else { return }
		camera.stop()
		// The scan moves each page's staged original into place from here on.
		handedOff = true
		if let scan = appendingTo {
			scan.append(captured, in: viewContext)
			router.pop()
		} else {
			let scan = Scan.create(from: captured, title: RescrivaDates.defaultTitle(for: mode),
								   source: mode == .whiteboard ? .whiteboard : nil, in: viewContext)
			router.replaceTop(with: .scan(scan))
		}
	}

	/// Deletes the staged originals of pages that were never saved (Cancel, or the screen closed
	/// some other way), off the main thread. Leftovers a crash strands go at the next launch.
	private func discardUnsaved() {
		guard !handedOff else { return }
		OriginalStore.shared.discardLater(captured.compactMap(\.original))
	}
}

extension CaptureKind {
	var cameraMode: CaptureCamera.Mode {
		switch self {
		case .document: return .document
		case .whiteboard: return .whiteboard
		}
	}
}

/// The illustrated viewfinder, where there's no camera: a page in perspective
/// on a desk (or a whiteboard), marked out in highlighter like the live view.
private struct DemoViewfinder: View {
	let whiteboard: Bool

	var body: some View {
		ZStack {
			if whiteboard {
				Color(hex: 0x8E949C)
			} else {
				RadialGradient(colors: [Color(hex: 0x3B3F46), Color(hex: 0x23262B)], center: UnitPoint(x: 0.4, y: 0.3), startRadius: 10, endRadius: 420)
			}
			page
				.frame(width: whiteboard ? 300 : 220, height: whiteboard ? 210 : 300)
				.rotation3DEffect(.degrees(12), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
				.rotationEffect(.degrees(-4))
		}
		.accessibilityHidden(true)
	}

	private var page: some View {
		ZStack {
			Group {
				RoundedRectangle(cornerRadius: 3)
					.fill(whiteboard ? Color(hex: 0xF4F6F6) : Color.paper)
					.shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 20)
				if whiteboard {
					SketchedFlowchart(seed: 3)
						.stroke(Color.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
						.padding(28)
				} else {
					SketchedNotes(seed: 9)
						.stroke(Color.ballpoint.opacity(0.8), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
						.padding(.horizontal, 18)
						.padding(.vertical, 40)
				}
			}
			// The page is paper (or whiteboard): its ink keeps its paper colours under the dark camera.
			.environment(\.colorScheme, .light)
			RoundedRectangle(cornerRadius: 4)
				.fill(Color.highlighter.opacity(0.10))
				.overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.highlighter, lineWidth: 2.5) }
				.padding(-4)
			GeometryReader { proxy in
				ForEach(0..<4, id: \.self) { corner in
					RoundedRectangle(cornerRadius: 1.5)
						.fill(Color.chalk)
						.overlay { RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.highlighter, lineWidth: 2.5) }
						.frame(width: 13, height: 13)
						.position(x: corner % 2 == 0 ? -2 : proxy.size.width + 2, y: corner < 2 ? -2 : proxy.size.height + 2)
				}
			}
		}
	}
}
