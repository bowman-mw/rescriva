//
//  NearbyShareSession+Rules.swift
//  Rescriva (fork of Open Scanner)
//
//  The small rules a Share Nearby session applies to what pages send: wrong-PIN counting and its
//  cooldown (ShareSite/PROTOCOL.md §1.3), checks on the text that arrives, and the label each
//  page goes by. Pure Foundation, so tests can drive them with any clock.
//

import Foundation

/// Wrong PINs for one shared document, counted across every page that tries it. Five wrong tries
/// replace the PIN and refuse tries for 30 s, doubling each time that happens again.
struct NearbySharePINLock: Equatable {
	static let triesPerPIN = 5
	static let firstCooldown: TimeInterval = 30
	/// The doubling stops here (30 s × 2¹⁰ is about eight and a half hours).
	static let maxDoublings = 10

	/// What one wrong try did.
	struct Outcome: Equatable {
		/// Tries left on the current PIN; 0 means the PIN has to be replaced now.
		let left: Int
		/// Seconds before tries are taken again, once the PIN has been replaced.
		let retryIn: Int?

		var replacesPIN: Bool { left == 0 }
	}

	private(set) var wrongTries = 0
	/// How many times the PIN has been replaced for wrong tries.
	private(set) var lockouts = 0
	private(set) var lockedUntil: Date?

	/// Whole seconds until tries are taken again, or nil when they're taken now.
	func secondsLeft(at now: Date) -> Int? {
		guard let lockedUntil, lockedUntil > now else { return nil }
		return max(1, Int(lockedUntil.timeIntervalSince(now).rounded(.up)))
	}

	/// Counts a wrong try made at `now`. The fifth starts a cooldown.
	mutating func recordWrong(at now: Date) -> Outcome {
		wrongTries += 1
		guard wrongTries >= Self.triesPerPIN else {
			return Outcome(left: Self.triesPerPIN - wrongTries, retryIn: nil)
		}
		wrongTries = 0
		let cooldown = Self.firstCooldown * Double(1 << min(lockouts, Self.maxDoublings))
		lockouts += 1
		lockedUntil = now.addingTimeInterval(cooldown)
		return Outcome(left: 0, retryIn: Int(cooldown))
	}
}

/// Checks on what pages send, on top of ShareInbound's own.
enum NearbyShareInput {
	static let pinLength = 6
	/// Room for a long name in UTF-8 with an extension, under the file system's 255 bytes.
	static let maxFileNameBytes = 200
	static let maxExtensionLength = 16
	/// Characters file systems or paths don't allow in a name.
	private static let notInFileNames = CharacterSet(charactersIn: "/\\:*?\"<>|")

	/// Exactly six ASCII digits.
	static func isPIN(_ text: String) -> Bool {
		text.utf8.count == pinLength && text.utf8.allSatisfy { (48...57).contains($0) }
	}

	/// Compares two secrets without stopping at the first difference.
	static func same(_ a: String, _ b: String) -> Bool {
		let left = Array(a.utf8)
		let right = Array(b.utf8)
		guard left.count == right.count else { return false }
		var difference: UInt8 = 0
		for index in 0..<left.count {
			difference |= left[index] ^ right[index]
		}
		return difference == 0
	}

	/// What the app takes: a PDF or an image (PROTOCOL.md §4).
	static func acceptsUpload(type: String) -> Bool {
		if type == "application/pdf" { return true }
		guard type.hasPrefix("image/"), type.utf8.count <= 64 else { return false }
		return type.utf8.allSatisfy { byte in
			(48...57).contains(byte) || (97...122).contains(byte) || byte == UInt8(ascii: "/")
				|| byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
		}
	}

	/// `text` made safe as one file name: no path or control characters, no leading dots,
	/// clipped to `maxFileNameBytes` with its extension kept. `fallback` when nothing is left.
	static func fileName(_ text: String, fallback: String) -> String {
		var scalars = String.UnicodeScalarView()
		for scalar in text.unicodeScalars.prefix(1024) {
			let unsafe = CharacterSet.controlCharacters.contains(scalar) || notInFileNames.contains(scalar)
			scalars.append(unsafe ? " " : scalar)
		}
		let words = String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
		let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
		return clipped(trimmed.isEmpty ? fallback : trimmed)
	}

	/// What to call a page named `name` that just connected, when `taken` are the labels of the
	/// devices connected already: its name, or its name with the lowest number no other device
	/// has ("Chrome on Mac 2"), so pages that go by the same name can be told apart.
	static func deviceLabel(_ name: String, taken: Set<String>) -> String {
		guard taken.contains(name) else { return name }
		var number = 2
		while taken.contains("\(name) \(number)") { number += 1 }
		return "\(name) \(number)"
	}

	/// The name without its extension, for a PDF's title.
	static func title(fromFileName name: String) -> String {
		let stem = (name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
		return stem.isEmpty ? String(localized: "Received PDF") : stem
	}

	/// `name` cut to `maxFileNameBytes` of UTF-8, keeping a short extension.
	private static func clipped(_ name: String) -> String {
		guard name.utf8.count > maxFileNameBytes else { return name }
		let ext = (name as NSString).pathExtension
		let keepsExtension = !ext.isEmpty && ext.count <= maxExtensionLength
		let suffix = keepsExtension ? "." + ext : ""
		let stem = keepsExtension ? (name as NSString).deletingPathExtension : name
		var out = ""
		var used = suffix.utf8.count
		for character in stem {
			let size = String(character).utf8.count
			if used + size > maxFileNameBytes { break }
			out.append(character)
			used += size
		}
		return out + suffix
	}
}
