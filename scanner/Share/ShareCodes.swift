//
//  ShareCodes.swift
//  Rescriva (fork of Open Scanner)
//
//  Share Nearby's small encodings and derivations (Docs/Rescriva-Share-Protocol.md §1 and §3.1): the two
//  unpadded base64 flavours, secrets and session ids, the relay room id, ICE credentials and hello
//  proofs derived from a secret, the connection code, and document PINs. rescriva-share's assets/codes.js
//  and crypto.js are the page's side of the same thing, and the test vectors are shared.
//

import CryptoKit
import Foundation
import Security

enum ShareCodes {
	// MARK: Base64

	/// RFC 4648 §5 base64url, with no padding.
	static func base64URL(_ data: Data) -> String {
		var text = base64NoPadding(data)
		text = text.replacingOccurrences(of: "+", with: "-")
		return text.replacingOccurrences(of: "/", with: "_")
	}

	/// Standard base64, with no padding.
	static func base64NoPadding(_ data: Data) -> String {
		var text = data.base64EncodedString()
		while text.hasSuffix("=") { text.removeLast() }
		return text
	}

	/// The bytes in unpadded base64url text, or nil when it isn't that (or is over 64 KiB long).
	static func data(base64URL text: String) -> Data? {
		guard text.utf8.count <= maxBase64Length else { return nil }
		guard text.utf8.allSatisfy({ isBase64URLByte($0) }) else { return nil }
		guard text.utf8.count % 4 != 1 else { return nil }
		var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		let padding = (4 - standard.utf8.count % 4) % 4
		standard += String(repeating: "=", count: padding)
		return Data(base64Encoded: standard)
	}

	// MARK: Secrets

	/// 16 random bytes.
	static func newSecret() -> Data {
		randomBytes(16)
	}

	/// 8 random bytes in base64url: the app's `session` in its hello.
	static func newSessionID() -> String {
		base64URL(randomBytes(8))
	}

	/// The relay room only holders of `secret` know: 22 base64url characters.
	static func roomID(secret: Data) -> String {
		var input = Data("rescriva-share/room/v1".utf8)
		input.append(secret)
		let digest = Data(SHA256.hash(data: input))
		return String(base64URL(digest).prefix(22))
	}

	/// The ICE username fragment (8 characters) and password (24) the two ends of a no-relay
	/// pairing agree on without telling each other.
	static func iceCredentials(secret: Data) -> (ufrag: String, pwd: String) {
		let mac = hmac(secret: secret, text: "rescriva-share/ice/v1")
		return (base64NoPadding(mac.subdata(in: 0..<6)), base64NoPadding(mac.subdata(in: 6..<24)))
	}

	/// What a hello's `proof` is: `role` is the sender's ("web" or "app"), and the fingerprints are
	/// the offer's and the answer's, as applied.
	static func proof(secret: Data, role: String, offerFingerprint: String, answerFingerprint: String) -> String {
		let text = "rescriva-share/proof/v1|" + role + "|" + offerFingerprint + "|" + answerFingerprint
		return base64URL(hmac(secret: secret, text: text))
	}

	// MARK: Connection code

	/// The code the page types to reach `ipv4:port`, with its check digit and no dashes. Nil when
	/// the address isn't dotted IPv4 or the port is 0.
	static func connectionCode(ipv4: String, port: UInt16) -> String? {
		guard port != 0, let octets = ipv4Octets(ipv4) else { return nil }
		let (tag, payload) = codePayload(octets: octets, port: UInt64(port))
		let count = dataDigits[tag]
		let value = (UInt64(tag) << UInt64(5 * count - 2)) | payload
		var digits: [Int] = []
		for index in 0..<count {
			let shift = UInt64(5 * (count - 1 - index))
			digits.append(Int((value >> shift) & 31))
		}
		digits.append(checkDigit(digits))
		return String(digits.map { crockford[$0] })
	}

	/// The address and port in a typed code, or nil when it's mistyped. Dashes, spaces and case
	/// don't matter, and O, I and L read as 0, 1 and 1.
	static func decodeConnectionCode(_ text: String) -> (ipv4: String, port: UInt16)? {
		guard text.utf8.count <= 64, let digits = codeDigits(text), digits.count >= 5 else { return nil }
		let tag = digits[0] >> 3
		let count = dataDigits[tag]
		guard digits.count == count + 1 else { return nil }
		let data = Array(digits[0..<count])
		guard checkDigit(data) == digits[count] else { return nil }
		var value: UInt64 = 0
		for digit in data { value = (value << 5) | UInt64(digit) }
		let bits = UInt64(payloadBits[tag])
		guard value >> bits == UInt64(tag) << (UInt64(5 * count - 2) - bits) else { return nil }
		let payload = value & ((1 << bits) - 1)
		let port = UInt16(payload & 0xFFFF)
		guard port != 0 else { return nil }
		let rest = payload >> 16
		func byte(_ shift: UInt64) -> UInt64 { (rest >> shift) & 0xFF }
		let addresses = [
			"172.20.10.1",
			"192.168.\(byte(8)).\(byte(0))",
			"10.\(byte(16)).\(byte(8)).\(byte(0))",
			"\(byte(24)).\(byte(16)).\(byte(8)).\(byte(0))",
		]
		return (addresses[tag], port)
	}

	/// A code in groups of four: "80JBN1HG" → "80JB-N1HG".
	static func grouped(_ code: String) -> String {
		var out = ""
		for (index, character) in code.enumerated() {
			if index > 0 && index % 4 == 0 { out.append("-") }
			out.append(character)
		}
		return out
	}

	/// The four numbers in dotted IPv4 text ("192.168.1.37"), or nil when it isn't that.
	static func ipv4Octets(_ text: String) -> [UInt8]? {
		guard text.utf8.count <= 15 else { return nil }
		let parts = text.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 4 else { return nil }
		var octets: [UInt8] = []
		for part in parts {
			guard (1...3).contains(part.utf8.count), part.utf8.allSatisfy({ (48...57).contains($0) }),
				  let value = UInt8(part) else { return nil }
			octets.append(value)
		}
		return octets
	}

	// MARK: PINs

	/// A random 6-digit PIN that isn't in `used`.
	static func newPIN(avoiding used: Set<String>) -> String {
		for _ in 0..<64 {
			let pin = pinText(Int.random(in: 0..<pinSpace))
			if !used.contains(pin) { return pin }
		}
		// Only reachable when nearly every PIN is taken: walk from a random start instead.
		let start = Int.random(in: 0..<pinSpace)
		for step in 0..<pinSpace {
			let pin = pinText((start + step) % pinSpace)
			if !used.contains(pin) { return pin }
		}
		print("Rescriva: every Share Nearby PIN is in use")
		return pinText(start)
	}

	/// "482913" → "482 913". Anything that isn't six characters comes back as it is.
	static func displayPIN(_ pin: String) -> String {
		guard pin.count == 6 else { return pin }
		return String(pin.prefix(3)) + " " + String(pin.suffix(3))
	}

	// MARK: Private

	private static let maxBase64Length = 64 * 1024
	private static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
	/// Data digits and payload bits for each tag (PROTOCOL.md §3.1).
	private static let dataDigits = [4, 7, 9, 10]
	private static let payloadBits = [16, 32, 40, 48]
	private static let pinSpace = 1_000_000

	private static func isBase64URLByte(_ byte: UInt8) -> Bool {
		switch byte {
		case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
			 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
			return true
		default:
			return false
		}
	}

	private static func hmac(secret: Data, text: String) -> Data {
		let code = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: secret))
		return Data(code)
	}

	/// Cryptographically random bytes.
	private static func randomBytes(_ count: Int) -> Data {
		var bytes = [UInt8](repeating: 0, count: count)
		let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
		if status != errSecSuccess {
			// SystemRandomNumberGenerator is also cryptographically secure on Apple platforms.
			print("Rescriva: SecRandomCopyBytes failed (\(status)); using the system generator")
			var generator = SystemRandomNumberGenerator()
			for index in 0..<count { bytes[index] = generator.next() }
		}
		return Data(bytes)
	}

	private static func pinText(_ value: Int) -> String {
		let digits = String(value)
		return String(repeating: "0", count: max(0, 6 - digits.count)) + digits
	}

	/// The tag and payload bits for an address (PROTOCOL.md §3.1's table).
	private static func codePayload(octets: [UInt8], port: UInt64) -> (tag: Int, payload: UInt64) {
		let a = octets.map { UInt64($0) }
		if a == [172, 20, 10, 1] { return (0, port) }
		if a[0] == 192 && a[1] == 168 { return (1, a[2] << 24 | a[3] << 16 | port) }
		if a[0] == 10 { return (2, a[1] << 32 | a[2] << 24 | a[3] << 16 | port) }
		return (3, a[0] << 40 | a[1] << 32 | a[2] << 24 | a[3] << 16 | port)
	}

	private static func checkDigit(_ digits: [Int]) -> Int {
		var sum = 0
		for (index, digit) in digits.enumerated() { sum += (index + 1) * digit }
		return sum % 32
	}

	/// Typed text as base32 digit values, or nil when a character isn't one.
	private static func codeDigits(_ text: String) -> [Int]? {
		var digits: [Int] = []
		for character in text {
			if character == "-" || character.isWhitespace { continue }
			guard character.isASCII else { return nil }
			let upper = Character(character.uppercased())
			let read: Character = upper == "O" ? "0" : (upper == "I" || upper == "L") ? "1" : upper
			guard let value = crockford.firstIndex(of: read) else { return nil }
			digits.append(value)
		}
		return digits
	}
}
