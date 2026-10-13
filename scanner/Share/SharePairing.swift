//
//  SharePairing.swift
//  Rescriva (fork of Open Scanner)
//
//  The page's no-relay pairing code (ShareSite/PROTOCOL.md §3): what the app reads from the QR code
//  a computer's Share page shows, or from that link pasted in. Every field is checked here, because
//  ShareSDP writes them into SDP text.
//

import Foundation

/// The page's QR code: `openscanner://share?p=<base64url payload>` (PROTOCOL.md §3).
struct SharePairingOffer: Equatable {
	/// Where the page can be reached: dotted IPv4, IPv6 text, or "<uuid>.local".
	struct Candidate: Equatable {
		let host: String
		let port: UInt16
	}

	let secret: Data
	/// ice-chars only: [A-Za-z0-9+/], 4…255.
	let ufrag: String
	/// ice-chars only, 22…255.
	let pwd: String
	/// "AB:CD:…", 32 bytes, upper case.
	let fingerprint: String
	/// [A-Za-z0-9_-], 1…16.
	let mid: String
	let candidates: [Candidate]

	/// Reads the binary payload; nil for any other version, or anything out of shape.
	init?(payload: Data) {
		guard payload.count <= Self.maxPayload else { return nil }
		var reader = PayloadReader(bytes: [UInt8](payload))
		guard reader.byte() == 1, let secret = reader.bytes(16) else { return nil }
		guard let ufrag = reader.text(allowed: Self.isICEByte), (4...255).contains(ufrag.utf8.count) else { return nil }
		guard let pwd = reader.text(allowed: Self.isICEByte), (22...255).contains(pwd.utf8.count) else { return nil }
		guard let fingerprint = reader.bytes(32) else { return nil }
		guard let mid = reader.text(allowed: Self.isMidByte), (1...16).contains(mid.utf8.count) else { return nil }
		guard let count = reader.byte(), count <= 8 else { return nil }
		var candidates: [Candidate] = []
		for _ in 0..<count {
			guard let candidate = reader.candidate() else { return nil }
			candidates.append(candidate)
		}
		guard reader.isAtEnd else { return nil }
		self.secret = Data(secret)
		self.ufrag = ufrag
		self.pwd = pwd
		self.fingerprint = fingerprint.map { Self.hexPair($0) }.joined(separator: ":")
		self.mid = mid
		self.candidates = candidates
	}

	/// Accepts the whole link, or just the base64url payload.
	init?(link: String) {
		let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, text.utf8.count <= Self.maxLink else { return nil }
		let encoded: String
		if text.contains(":") {
			guard let components = URLComponents(string: text),
				  components.scheme?.lowercased() == "openscanner", components.host?.lowercased() == "share",
				  let value = components.queryItems?.first(where: { $0.name == "p" })?.value else { return nil }
			encoded = value
		} else {
			encoded = text
		}
		guard let payload = ShareCodes.data(base64URL: encoded) else { return nil }
		self.init(payload: payload)
	}

	// MARK: Private

	/// Version, secret, two 1+255 strings, fingerprint, 1+16 mid, count, eight 19-byte candidates.
	private static let maxPayload = 1 + 16 + 256 * 2 + 32 + 17 + 1 + 8 * 19
	private static let maxLink = 4096

	/// RFC 8839 ice-char: ALPHA / DIGIT / "+" / "/".
	private static func isICEByte(_ byte: UInt8) -> Bool {
		isAlphanumeric(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/")
	}

	private static func isMidByte(_ byte: UInt8) -> Bool {
		isAlphanumeric(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
	}

	private static func isAlphanumeric(_ byte: UInt8) -> Bool {
		(48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
	}

	private static func hexPair(_ byte: UInt8) -> String {
		let digits = Array("0123456789ABCDEF")
		return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
	}
}

/// Reads the payload front to back; every read returns nil once it would run past the end.
private struct PayloadReader {
	private let buffer: [UInt8]
	private var offset = 0

	init(bytes: [UInt8]) {
		buffer = bytes
	}

	var isAtEnd: Bool { offset == buffer.count }

	mutating func byte() -> UInt8? {
		guard offset < buffer.count else { return nil }
		offset += 1
		return buffer[offset - 1]
	}

	mutating func bytes(_ count: Int) -> [UInt8]? {
		guard count >= 0, buffer.count - offset >= count else { return nil }
		offset += count
		return Array(buffer[(offset - count)..<offset])
	}

	/// A length byte, then that many ASCII bytes that all pass `allowed`.
	mutating func text(allowed: (UInt8) -> Bool) -> String? {
		guard let length = byte(), let raw = bytes(Int(length)), raw.allSatisfy(allowed) else { return nil }
		return String(decoding: raw, as: UTF8.self)
	}

	/// Kind, address, big-endian port. Port 0 and unknown kinds are malformed.
	mutating func candidate() -> SharePairingOffer.Candidate? {
		guard let kind = byte() else { return nil }
		let host: String
		switch kind {
		case 4:
			guard let address = bytes(4) else { return nil }
			host = address.map { String($0) }.joined(separator: ".")
		case 6:
			guard let address = bytes(16), let text = Self.ipv6Text(address) else { return nil }
			host = text
		case 109:
			guard let raw = bytes(16) else { return nil }
			host = Self.uuidText(raw) + ".local"
		default:
			return nil
		}
		guard let port = bytes(2) else { return nil }
		let value = UInt16(port[0]) << 8 | UInt16(port[1])
		guard value != 0 else { return nil }
		return SharePairingOffer.Candidate(host: host, port: value)
	}

	/// RFC 5952 text for 16 address bytes.
	private static func ipv6Text(_ address: [UInt8]) -> String? {
		guard address.count == 16 else { return nil }
		var storage = in6_addr()
		withUnsafeMutableBytes(of: &storage) { buffer in
			for index in 0..<16 { buffer[index] = address[index] }
		}
		var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
		guard inet_ntop(AF_INET6, &storage, &text, socklen_t(text.count)) != nil else {
			print("Rescriva: couldn't write an IPv6 pairing candidate as text")
			return nil
		}
		return String(cString: text)
	}

	/// 8-4-4-4-12 lower-case hex, the way browsers name mDNS candidates.
	private static func uuidText(_ raw: [UInt8]) -> String {
		var text = ""
		for (index, byte) in raw.enumerated() {
			if [4, 6, 8, 10].contains(index) { text += "-" }
			text += String(byte, radix: 16).leftPadded(to: 2)
		}
		return text
	}
}

private extension String {
	func leftPadded(to width: Int) -> String {
		String(repeating: "0", count: max(0, width - count)) + self
	}
}
