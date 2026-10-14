//
//  NearbyShareSession+Rules.swift
//  Rescriva (fork of Open Scanner)
//
//  Small types a Share Nearby session leans on (not an extension of it, despite the name:
//  renaming the file means touching the project file). NearbySharePINLock counts wrong PINs on
//  one document and says when tries are refused (Docs/Rescriva-Share-Protocol.md §1.3);
//  NearbyShareInput checks the text pages send, sorts what they send by kind and names the
//  pages. Pure Foundation, driven by the dates passed in, so tests can run them with any clock.
//

import Foundation

/// What a received file is, by the type its page gave it. That says where it's saved.
enum NearbyShareUploadKind: Equatable {
	/// Saved in PDF Files.
	case pdf
	/// A picture Photos takes: saved in Photos.
	case picture
	/// A video Photos takes: saved in Photos.
	case video
	/// Anything else: saved in Files.
	case file
}

/// Wrong PINs for one shared document, counted per connection ("link") so that one page can't lock
/// everyone out. Five wrong tries from a link refuse that link for `linkCooldown`. Only when wrong
/// tries across every link reach `triesBeforeReplacing`, or `lockedLinksBeforeReplacing` different
/// links have each been refused, is the PIN replaced and every link refused for a cooldown that
/// doubles each time that happens again, up to `maxDoublings`.
struct NearbySharePINLock: Equatable {
	static let triesPerLink = 5
	static let triesBeforeReplacing = 15
	static let lockedLinksBeforeReplacing = 3
	static let linkCooldown: TimeInterval = 30
	static let firstCooldown: TimeInterval = 30
	/// The doubling stops here (30 s × 2⁶ is 32 minutes).
	static let maxDoublings = 6

	/// What one wrong try did.
	struct Outcome: Equatable {
		/// Tries this link has left on the current PIN; 0 means it's refused for now.
		let left: Int
		/// Seconds before this link's tries are taken again, when it has none left.
		let retryIn: Int?
		/// The PIN has to be replaced now, and every link waits.
		let replacesPIN: Bool
	}

	/// One link's wrong tries on the current PIN, and the cooldown they earned it.
	private struct LinkTries: Equatable {
		var wrong = 0
		var refusedUntil: Date?
	}

	private var links: [UUID: LinkTries] = [:]
	/// Wrong tries on the current PIN, from every link.
	private(set) var wrongTries = 0
	/// Links refused on the current PIN.
	private(set) var lockedLinks: Set<UUID> = []
	/// How many times the PIN has been replaced for wrong tries.
	private(set) var lockouts = 0
	/// Every link waits until then.
	private(set) var lockedUntil: Date?

	/// Whole seconds until `link`'s tries are taken again, or nil when they're taken now: the
	/// later of its own cooldown and everyone's.
	func secondsLeft(for link: UUID, at now: Date) -> Int? {
		let ends = [lockedUntil, links[link]?.refusedUntil].compactMap { $0 }.filter { $0 > now }
		guard let latest = ends.max() else { return nil }
		return max(1, Int(latest.timeIntervalSince(now).rounded(.up)))
	}

	/// Wrong tries `link` has left before it's refused.
	func triesLeft(for link: UUID) -> Int {
		Self.triesPerLink - (links[link]?.wrong ?? 0)
	}

	/// Counts a wrong try from `link` at `now`. Ask `secondsLeft` first: a try while the link is
	/// refused only repeats the refusal.
	mutating func recordWrong(from link: UUID, at now: Date) -> Outcome {
		if let wait = secondsLeft(for: link, at: now) {
			return Outcome(left: 0, retryIn: wait, replacesPIN: false)
		}
		var tries = links[link] ?? LinkTries()
		if tries.refusedUntil != nil {
			// Its cooldown is over: it starts a fresh count.
			tries = LinkTries()
		}
		tries.wrong += 1
		wrongTries += 1
		let refused = tries.wrong >= Self.triesPerLink
		if refused {
			tries.refusedUntil = now.addingTimeInterval(Self.linkCooldown)
			lockedLinks.insert(link)
		}
		links[link] = tries
		if wrongTries >= Self.triesBeforeReplacing || lockedLinks.count >= Self.lockedLinksBeforeReplacing {
			return replacePIN(at: now)
		}
		if refused {
			return Outcome(left: 0, retryIn: Int(Self.linkCooldown), replacesPIN: false)
		}
		return Outcome(left: Self.triesPerLink - tries.wrong, retryIn: nil, replacesPIN: false)
	}

	/// Starts over with a new PIN: every count is cleared and every link waits out a cooldown that
	/// doubles with each replacement.
	private mutating func replacePIN(at now: Date) -> Outcome {
		let cooldown = Self.firstCooldown * Double(1 << min(lockouts, Self.maxDoublings))
		lockouts += 1
		lockedUntil = now.addingTimeInterval(cooldown)
		links = [:]
		wrongTries = 0
		lockedLinks = []
		return Outcome(left: 0, retryIn: Int(cooldown), replacesPIN: true)
	}
}

/// Checks on what pages send, on top of ShareInbound's own.
enum NearbyShareInput {
	static let pinLength = 6
	/// What `String.safeFileName` cuts a name to; the same limit as every other file the app names.
	static var maxFileNameBytes: Int { String.maxFileNameBytes }

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

	/// What an upload's type reads as when the page gave none, or one that isn't a plain type.
	static let unknownType = "application/octet-stream"
	/// The longest media type kept; a longer one reads as `unknownType`.
	static let maxTypeBytes = 127
	/// The picture types Photos takes. Anything else that calls itself a picture (SVG, Photoshop)
	/// is saved in Files.
	static let photoTypes: Set<String> = [
		"image/jpeg", "image/jpg", "image/png", "image/heic", "image/heif", "image/gif", "image/tiff", "image/webp",
		"image/bmp", "image/x-adobe-dng",
	]
	/// The video types Photos takes. Anything else that calls itself a video (WebM, Matroska) is
	/// saved in Files.
	static let videoTypes: Set<String> = ["video/mp4", "video/quicktime", "video/x-m4v", "video/3gpp"]

	/// The media type a page gave an upload, ready to compare: lower case and without parameters
	/// ("image/PNG; x=y" is "image/png"). The app takes a file of any type (PROTOCOL.md §4), so
	/// anything that isn't a plain type/subtype of [a-z0-9+.-], up to `maxTypeBytes`, isn't
	/// refused; it reads as `unknownType` and the file is saved in Files.
	static func uploadType(_ type: String) -> String {
		let bare = (type.components(separatedBy: ";").first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
		let parts = bare.split(separator: "/", omittingEmptySubsequences: false)
		guard bare.utf8.count <= maxTypeBytes, parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
			  bare.utf8.allSatisfy(isTypeByte) else { return unknownType }
		return bare
	}

	private static func isTypeByte(_ byte: UInt8) -> Bool {
		(48...57).contains(byte) || (97...122).contains(byte) || byte == UInt8(ascii: "/")
			|| byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
	}

	/// What an upload of `type` (as `uploadType` gives it) is, which says where it's saved.
	static func uploadKind(type: String) -> NearbyShareUploadKind {
		if type == "application/pdf" { return .pdf }
		if photoTypes.contains(type) { return .picture }
		if videoTypes.contains(type) { return .video }
		return .file
	}

	/// Whether a page that isn't paired downloads a file of `type` and `size` from this device:
	/// the page refuses other types, and anything over its caps (PROTOCOL.md §4).
	static func unpairedPageTakes(type: String, size: Int64) -> Bool {
		guard ShareLimits.unpairedPageTypes.contains(type) else { return false }
		let cap = type == "application/pdf" ? ShareLimits.unpairedPageMaxPDFBytes : ShareLimits.unpairedPageMaxBytes
		return size <= cap
	}

	/// `text` made safe as one file name (`String.safeFileName`); `fallback`, made safe the same
	/// way, when nothing is left of it.
	static func fileName(_ text: String, fallback: String) -> String {
		let name = text.safeFileName()
		return name.isEmpty ? fallback.safeFileName() : name
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
}
