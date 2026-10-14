//
//  ShareQRCode.swift
//  Rescriva (fork of Open Scanner)
//
//  A QR code (error correction M) drawn one pixel a module and scaled up with no
//  smoothing, so its edges stay sharp at any size. It's always black on paper white,
//  in either appearance, with a quiet zone round it, since that's what cameras read.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct ShareQRCode: View {
	let text: String
	/// What VoiceOver says for the code. The link itself is never read out: it carries a key.
	var label: LocalizedStringKey = "QR code"

	@State private var image: CGImage?

	var body: some View {
		ZStack {
			Color.paper
			if let image {
				Image(decorative: image, scale: 1)
					.interpolation(.none)
					.resizable()
					.aspectRatio(1, contentMode: .fit)
					.padding(12)
			} else {
				ProgressView()
					.tint(.printInk)
			}
		}
		.aspectRatio(1, contentMode: .fit)
		.clipShape(RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous)
				.strokeBorder(Color.carbon.opacity(0.1))
		}
		.environment(\.colorScheme, .light)
		.task(id: text) { image = Self.makeImage(text) }
		.accessibilityElement()
		.accessibilityLabel(Text(label))
		.accessibilityAddTraits(.isImage)
	}

	/// Generous enough for any link the app makes; a QR code holds at most about 2,300 bytes at M.
	static let maxBytes = 2_048

	/// The code at one pixel a module, or nil when `text` is empty, too long, or CoreImage fails.
	static func makeImage(_ text: String) -> CGImage? {
		let data = Data(text.utf8)
		guard !data.isEmpty, data.count <= maxBytes else {
			Log.share.error("No QR code for \(data.count) bytes")
			return nil
		}
		let filter = CIFilter.qrCodeGenerator()
		filter.message = data
		filter.correctionLevel = "M"
		guard let output = filter.outputImage else {
			Log.share.error("CoreImage made no QR code")
			return nil
		}
		let context = CIContext(options: [.useSoftwareRenderer: false])
		guard let image = context.createCGImage(output, from: output.extent.integral) else {
			Log.share.error("Couldn't render the QR code")
			return nil
		}
		return image
	}
}
