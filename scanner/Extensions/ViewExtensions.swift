//
//  ViewExtensions.swift
//  Open Scanner
//
//  Created by Slaven Radic on 2024-09-01.
//

import Foundation
import SwiftUI
import UIKit
import ImageIO
import os

public extension Color {
	
	static let background = Color("background")
	static let foreground = Color("foreground")
	static let accent = Color("accent")
	
	
	init(hex: UInt, alpha: Double = 1) {
		self.init(
			.sRGB,
			red: Double((hex >> 16) & 0xff) / 255,
			green: Double((hex >> 08) & 0xff) / 255,
			blue: Double((hex >> 00) & 0xff) / 255,
			opacity: alpha
		)
	}
}

let DefaultBackgroundGradient = LinearGradient(
		colors: [
			Color("gradientMainTop"),
			Color("gradientMainBottom")],
		startPoint: .topLeading,
		endPoint: .bottomTrailing)

func getDocumentsDirectory() -> URL {
	let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
	return paths[0]
}

func getTemporaryDirectory() -> URL {
	let previewURL = FileManager.default.temporaryDirectory.appendingPathComponent("Document")
	return previewURL
}

extension Animation {
	func `repeat`(while expression: Bool, autoreverses: Bool = true) -> Animation {
		if expression {
			return self.repeatForever(autoreverses: autoreverses)
		} else {
			return self
		}
	}
}

extension UIImage {
	
	var aspectRatio: CGFloat {
		size.width / size.height
	}
	
	func resizeToWidth(_ width: CGFloat) -> UIImage {
		
		// Determine the scale factor that preserves aspect ratio
		let ratio = size.width / size.height
		let height = width / ratio
		
		// Compute the new image size that preserves aspect ratio
		let scaledImageSize = CGSize(
			width: width,
			height: height
		)
		
		// Draw and return the resized UIImage
		
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		
		let renderer = UIGraphicsImageRenderer(size: scaledImageSize, format: format)
		
		let scaledImage = renderer.image { _ in
			self.draw(in: CGRect(
				origin: .zero,
				size: scaledImageSize
			))
		}
		
		return scaledImage
	}
	
	func resize(newSize: CGSize) -> UIImage? {
		let renderer = UIGraphicsImageRenderer(size: newSize)
		return renderer.image { (context) in
			self.draw(in: CGRect(origin: .zero, size: newSize))
		}
	}
	
}

struct FlippedUpsideDown: ViewModifier {
	func body(content: Content) -> some View {
		content
			.rotationEffect(.radians(CGFloat.pi))
			.scaleEffect(x: -1, y: 1, anchor: .center)
	}
}
extension View {
	func flippedUpsideDown() -> some View{
		self.modifier(FlippedUpsideDown())
	}
}

extension String {
	func truncate(to limit: Int) -> String {
		if count > limit {
			let truncated = String(prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
			return truncated + "\u{2026}"
		} else {
			return self
		}
	}
	
	/// Room for a long name in UTF-8 with an extension, under the file system's 255 bytes.
	static let maxFileNameBytes = 200
	/// The longest extension a clipped name keeps; anything longer is cut with the rest.
	static let maxExtensionLength = 16
	/// Characters file systems or paths don't allow in a name.
	private static let notInFileNames = CharacterSet(charactersIn: "/\\:*?\"<>|")

	/// The receiver made safe as one file name: path separators, the characters file systems
	/// refuse and control characters become spaces, runs of whitespace collapse to one, leading
	/// dots and spaces go, and the result is cut to `maxBytes` of UTF-8 with a short extension
	/// kept. Empty when nothing is left, so the caller chooses the fallback.
	func safeFileName(maxBytes: Int = String.maxFileNameBytes) -> String {
		var scalars = String.UnicodeScalarView()
		for scalar in unicodeScalars.prefix(1024) {
			let unsafe = CharacterSet.controlCharacters.contains(scalar) || String.notInFileNames.contains(scalar)
			scalars.append(unsafe ? " " : scalar)
		}
		let words = String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
		let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
		return trimmed.clippedFileName(to: maxBytes)
	}

	/// The receiver cut to `maxBytes` of UTF-8 at a character boundary, keeping an extension of
	/// up to `maxExtensionLength` characters when it has one.
	private func clippedFileName(to maxBytes: Int) -> String {
		guard utf8.count > maxBytes else { return self }
		let ext = (self as NSString).pathExtension
		let keepsExtension = !ext.isEmpty && ext.count <= String.maxExtensionLength
		let suffix = keepsExtension ? "." + ext : ""
		let stem = keepsExtension ? (self as NSString).deletingPathExtension : self
		var out = ""
		var used = suffix.utf8.count
		for character in stem {
			let size = String(character).utf8.count
			if used + size > maxBytes { break }
			out.append(character)
			used += size
		}
		return out + suffix
	}
	
	func whitespaceCondensed() -> String {
		return self.components(separatedBy: .whitespacesAndNewlines)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}
	
	mutating func condenseWhitespace() -> Void {
		self = self.whitespaceCondensed()
	}
}

extension FileManager {
	/// Removes `url` when it's there, logging to `log` rather than throwing when it can't: for
	/// staging copies, downloads and leftovers, whose loss nothing depends on. Any thread.
	func removeIfPresent(_ url: URL, log: Logger = Log.app) {
		guard fileExists(atPath: url.path) else { return }
		do {
			try removeItem(at: url)
		} catch {
			log.error("Couldn't remove \(url.lastPathComponent, privacy: .private): \(error)")
		}
	}
}

extension View {
	/// Applies the given transform if the given condition evaluates to `true`.
	/// - Parameters:
	///   - condition: The condition to evaluate.
	///   - transform: The transform to apply to the source `View`.
	/// - Returns: Either the original `View` or the modified `View` if the condition is `true`.
	@ViewBuilder func `if`<Content: View>(_ condition: @autoclosure () -> Bool, transform: (Self) -> Content) -> some View {
		if condition() {
			transform(self)
		} else {
			self
		}
	}
}
