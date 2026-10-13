//
//  ShareSDP.swift
//  Rescriva (fork of Open Scanner)
//
//  The few pieces of SDP text Share Nearby reads and writes (ShareSite/PROTOCOL.md §3): the page's
//  offer rebuilt from its pairing code, the app's answer with the ICE credentials both ends derive
//  from the secret, the DTLS fingerprint the hello proofs cover, and host candidates for the
//  connection code. The lines match Tools/NearbyShareSpike/spike.swift, which connected to Chrome.
//

import Foundation

enum ShareSDP {
	/// The page's offer, rebuilt from its QR code (the exact lines in Tools/NearbyShareSpike/spike.swift).
	/// Every value in it was checked when the payload was read. `addresses` gives an IPv4 address
	/// to use in place of an mDNS candidate name; anything there that isn't dotted IPv4 is ignored.
	static func offer(for pairing: SharePairingOffer, addresses: [String: String] = [:]) -> String {
		var lines = [
			"v=0",
			"o=- 4611731400430051336 2 IN IP4 127.0.0.1",
			"s=-",
			"t=0 0",
			"a=group:BUNDLE \(pairing.mid)",
			"a=msid-semantic: WMS",
			"m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
			"c=IN IP4 0.0.0.0",
		]
		for (index, candidate) in pairing.candidates.prefix(8).enumerated() {
			let resolved = addresses[candidate.host].flatMap { ShareCodes.ipv4Octets($0) == nil ? nil : $0 }
			lines.append("a=candidate:\(index + 1) 1 udp \(hostPriority(index)) \(resolved ?? candidate.host) \(candidate.port) typ host")
		}
		lines += [
			"a=ice-ufrag:\(pairing.ufrag)",
			"a=ice-pwd:\(pairing.pwd)",
			"a=ice-options:trickle",
			"a=fingerprint:sha-256 \(pairing.fingerprint)",
			"a=setup:actpass",
			"a=mid:\(pairing.mid)",
			"a=sctp-port:5000",
			"a=max-message-size:262144",
			"",
		]
		return lines.joined(separator: "\r\n")
	}

	/// `sdp` with every `a=ice-ufrag` and `a=ice-pwd` line's value replaced. Unchanged (and logged)
	/// when either value isn't ice-chars, so nothing else can get into the text.
	static func replacingICECredentials(in sdp: String, ufrag: String, pwd: String) -> String {
		guard isICEText(ufrag, lengths: 4...256), isICEText(pwd, lengths: 22...256) else {
			print("Rescriva: refusing ICE credentials that aren't ice-chars")
			return sdp
		}
		var text = sdp
		text = text.replacingOccurrences(of: "(?m)^a=ice-ufrag:[^\r\n]*", with: "a=ice-ufrag:\(ufrag)", options: .regularExpression)
		text = text.replacingOccurrences(of: "(?m)^a=ice-pwd:[^\r\n]*", with: "a=ice-pwd:\(pwd)", options: .regularExpression)
		return text
	}

	/// The first `a=fingerprint:sha-256`, upper case. Nil when there isn't one, or it isn't 32 hex pairs.
	static func fingerprint(in sdp: String) -> String? {
		// isNewline, because "\r\n" is one Character in Swift.
		for line in sdp.split(whereSeparator: \.isNewline) {
			guard line.hasPrefix("a=fingerprint:") else { continue }
			let fields = line.dropFirst("a=fingerprint:".count).split(separator: " ", omittingEmptySubsequences: true)
			guard fields.count >= 2, fields[0].lowercased() == "sha-256" else { continue }
			let value = fields[1].uppercased()
			return isFingerprint(value) ? value : nil
		}
		return nil
	}

	/// The one DTLS fingerprint in a page's offer, upper case. Nil unless the text has exactly one
	/// `a=fingerprint:` line in all, counting session and media level and every hash, and that
	/// line is a well-formed sha-256. libwebrtc lets a media-level fingerprint override a
	/// session-level one, so with two lines the fingerprint the hello proof covers might not be the
	/// one DTLS checks, and a relay could sit in the middle of the connection unseen.
	static func soleFingerprint(in sdp: String) -> String? {
		var found: Substring?
		for line in lines(of: sdp) where hasPrefix(line, "a=fingerprint:") {
			guard found == nil else { return nil }
			found = line
		}
		guard let found else { return nil }
		return fingerprint(in: String(found))
	}

	/// True when the offer has exactly one media section, and it's a data channel:
	/// `m=application <port> UDP/DTLS/SCTP webrtc-datachannel`. An audio or video section would
	/// have WebRTC take media from whoever made the offer, which Share Nearby never uses.
	static func isDataChannelOnly(_ sdp: String) -> Bool {
		var media: Substring?
		for line in lines(of: sdp) where hasPrefix(line, "m=") {
			guard media == nil else { return false }
			media = line
		}
		guard let media else { return false }
		let fields = media.split(separator: " ", omittingEmptySubsequences: false)
		guard fields.count == 4, fields[0] == "m=application", fields[2] == "UDP/DTLS/SCTP",
			  fields[3] == "webrtc-datachannel" else { return false }
		return (1...5).contains(fields[1].utf8.count) && fields[1].utf8.allSatisfy { (48...57).contains($0) }
			&& (Int(fields[1]) ?? Int.max) <= Int(UInt16.max)
	}

	/// A UDP host candidate's address and port, from a candidate line, with or without "a=".
	/// Nil for TCP, other component ids, server-reflexive or relayed candidates, and anything malformed.
	static func hostCandidate(_ line: String) -> (address: String, port: UInt16)? {
		var text = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
		guard text.utf8.count <= 1024 else { return nil }
		if text.hasPrefix("a=") { text = text.dropFirst(2) }
		guard text.hasPrefix("candidate:") else { return nil }
		let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
		guard fields.count >= 8, fields[1] == "1", fields[2].lowercased() == "udp" else { return nil }
		guard fields[6] == "typ", fields[7] == "host" else { return nil }
		guard let port = UInt16(fields[5]), port != 0 else { return nil }
		let address = String(fields[4])
		guard (1...64).contains(address.utf8.count), address.utf8.allSatisfy(isAddressByte) else { return nil }
		return (address, port)
	}

	/// A UDP host candidate line (no "a=") at a dotted IPv4 address, for the page's mDNS candidates
	/// once their address is known. Nil unless `address` is dotted IPv4, `port` isn't 0 and
	/// `foundation` is 1…999, so nothing else can get into the text.
	static func ipv4HostCandidate(foundation: Int, address: String, port: UInt16) -> String? {
		guard (1...999).contains(foundation), port != 0, ShareCodes.ipv4Octets(address) != nil else { return nil }
		return "candidate:\(foundation) 1 udp \(hostPriority(min(foundation, 255))) \(address) \(port) typ host"
	}

	// MARK: Private

	/// The text's lines, split at every kind of line break: libwebrtc splits only at "\n", so
	/// this never sees fewer lines than it does.
	private static func lines(of sdp: String) -> [Substring] {
		sdp.split(whereSeparator: \.isNewline)
	}

	/// True when `line`, ignoring leading spaces and tabs and letter case, starts with `prefix`.
	/// Looser than libwebrtc's own check, so a line it reads as `prefix` is always counted.
	private static func hasPrefix(_ line: Substring, _ prefix: String) -> Bool {
		let text = line.drop { $0 == " " || $0 == "\t" }
		return text.prefix(prefix.count).lowercased() == prefix
	}

	/// Host type preference 126, falling local preference, component 1 (RFC 8445 §5.1.2).
	private static func hostPriority(_ index: Int) -> UInt32 {
		UInt32(126) << 24 | UInt32(65_535 - index) << 8 | 255
	}

	private static func isICEText(_ text: String, lengths: ClosedRange<Int>) -> Bool {
		guard lengths.contains(text.utf8.count) else { return false }
		return text.utf8.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "/") }
	}

	/// "AB:CD:…" with exactly 32 upper-case hex pairs.
	private static func isFingerprint(_ text: String) -> Bool {
		let pairs = text.split(separator: ":", omittingEmptySubsequences: false)
		guard pairs.count == 32 else { return false }
		return pairs.allSatisfy { pair in
			pair.utf8.count == 2 && pair.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
		}
	}

	/// IPv4, IPv6 or an mDNS name: letters, digits, ".", ":" and "-".
	private static func isAddressByte(_ byte: UInt8) -> Bool {
		isAlphanumeric(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: ":") || byte == UInt8(ascii: "-")
	}

	private static func isAlphanumeric(_ byte: UInt8) -> Bool {
		(48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
	}
}
