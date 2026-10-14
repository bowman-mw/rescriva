//
//  ShareCodeScanner.swift
//  Rescriva (fork of Open Scanner)
//
//  "Scan a computer's code": the camera, reading QR codes with VisionKit's data
//  scanner, until it finds the share page's pairing code. Codes that aren't one
//  get a line saying so, and scanning carries on. iPhone and iPad only: a Mac has
//  no scanner, so Share Nearby offers the pasted link there instead.
//

import SwiftUI

#if !targetEnvironment(macCatalyst)
import AVFoundation
import VisionKit
#endif

/// A sheet with the camera that reports the first pairing code it reads, then closes.
struct ShareCodeScanner: View {
	/// The scanned text, already checked to be a pairing code (`SharePairingOffer(link:)`).
	let onCode: (String) -> Void

	@Environment(\.dismiss) private var dismiss

	/// True where this device can read codes with its camera at all (not on a Mac, not in the
	/// Simulator, and not on devices without the Neural Engine). Says nothing about permission.
	@MainActor static var isSupported: Bool {
		#if targetEnvironment(macCatalyst)
		return false
		#else
		return DataScannerViewController.isSupported
		#endif
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SheetHeader(title: String(localized: "Scan a computer's code"),
						subtitle: String(localized: "Open \(NearbyShareView.siteName) on the computer and point the camera at its code."),
						trailing: (String(localized: "Cancel"), { dismiss() }))
			#if targetEnvironment(macCatalyst)
			unavailable(String(localized: "This Mac has no code scanner. Paste the pairing link instead."))
			#else
			ShareCameraGate { text in
				onCode(text)
				dismiss()
			}
			#endif
		}
		.padding(.horizontal, 20)
		.padding(.top, 16)
		.padding(.bottom, 12)
		.presentationDetents([.large])
		.presentationDragIndicator(.visible)
		.presentationCornerRadius(RescrivaRadius.large)
		.presentationBackground(Color.vellum)
	}

	private func unavailable(_ text: String) -> some View {
		Text(text)
			.font(RescrivaFont.note(16))
			.foregroundStyle(.graphite)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}
}

#if !targetEnvironment(macCatalyst)

/// Asks for the camera the first time (with the app's existing camera explanation), then shows
/// the scanner, or says why it can't.
private struct ShareCameraGate: View {
	let onCode: (String) -> Void

	@State private var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
	@State private var rejected = false

	var body: some View {
		Group {
			switch access {
			case .authorized:
				scanner
			case .notDetermined:
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.task { await requestAccess() }
			default:
				message(String(localized: "Rescriva isn't allowed to use the camera. Turn on Camera for Rescriva in Settings, or paste the pairing link instead."))
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	@ViewBuilder
	private var scanner: some View {
		if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
			ZStack(alignment: .bottom) {
				ShareDataScanner(onText: handle)
					.clipShape(RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
					.accessibilityLabel(Text("Camera"))
				if rejected {
					Text("That isn't a Rescriva Share code. Look for the code under “Pair with Rescriva”.")
						.font(RescrivaFont.ui(14))
						.foregroundStyle(.vellum)
						.padding(.vertical, 10)
						.padding(.horizontal, 14)
						.background(Color.carbon, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
						.padding(12)
						.transition(.opacity)
				}
			}
		} else {
			message(String(localized: "The camera can't read codes right now. Paste the pairing link instead."))
		}
	}

	private func message(_ text: String) -> some View {
		Text(text)
			.font(RescrivaFont.note(16))
			.foregroundStyle(.graphite)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	/// Pairing codes finish the scan; anything else gets a line and scanning carries on.
	private func handle(_ text: String) {
		guard SharePairingOffer(link: text) != nil else {
			withAnimation(RescrivaMotion.ui) { rejected = true }
			return
		}
		onCode(text)
	}

	private func requestAccess() async {
		let granted = await AVCaptureDevice.requestAccess(for: .video)
		access = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
	}
}

/// VisionKit's data scanner, reading QR codes only, wrapped for SwiftUI.
private struct ShareDataScanner: UIViewControllerRepresentable {
	let onText: (String) -> Void

	func makeUIViewController(context: Context) -> DataScannerViewController {
		let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
												qualityLevel: .balanced,
												recognizesMultipleItems: false,
												isHighFrameRateTrackingEnabled: false,
												isPinchToZoomEnabled: true,
												isGuidanceEnabled: true,
												isHighlightingEnabled: true)
		scanner.delegate = context.coordinator
		return scanner
	}

	func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
		context.coordinator.onText = onText
		guard !scanner.isScanning else { return }
		do {
			try scanner.startScanning()
		} catch {
			Log.share.error("The code scanner didn't start: \(error)")
		}
	}

	static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
		scanner.stopScanning()
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(onText: onText)
	}

	@MainActor
	final class Coordinator: NSObject, DataScannerViewControllerDelegate {
		var onText: (String) -> Void
		/// The last payload passed on, so a code held in view isn't reported on every frame.
		private var last: String?
		private var finished = false

		init(onText: @escaping (String) -> Void) {
			self.onText = onText
		}

		func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
			report(addedItems)
		}

		func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
			last = nil
			report([item])
		}

		/// Passes on the first QR payload of a sensible length that differs from the last one.
		private func report(_ items: [RecognizedItem]) {
			guard !finished else { return }
			for item in items.prefix(8) {
				guard case .barcode(let code) = item, let text = code.payloadStringValue else { continue }
				guard !text.isEmpty, text.utf8.count <= NearbySharePending.maxLinkLength, text != last else { continue }
				last = text
				finished = SharePairingOffer(link: text) != nil
				onText(text)
				return
			}
		}
	}
}

#endif
