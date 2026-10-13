//
//  NearbyShareTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Share Nearby's pure core against ShareSite/PROTOCOL.md: the shared test vectors (room id, ICE
//  credentials, hello proofs, connection codes), the page's pairing payload byte for byte as
//  ShareSite/tests/index.html builds it, what a bad payload looks like, the SDP the app rebuilds
//  and edits, which local address goes in a connection code, the data channel's messages both
//  ways, relay signals, PINs, the built-in certificate, which leftover folders get swept, and
//  the numbers that tell pages with the same name apart.
//

import CryptoKit
import UIKit
import XCTest
@testable import scanner

final class NearbyShareTests: XCTestCase {
	/// PROTOCOL.md's secret: the bytes 01 02 … 10.
	private let secret = Data(1...16)
	private let fingerprintAA = Array(repeating: "AA", count: 32).joined(separator: ":")
	private let fingerprintBB = Array(repeating: "BB", count: 32).joined(separator: ":")
	/// The page's fingerprint in ShareSite/tests/index.html, as the page's SDP wrote it.
	private let pageFingerprint = "3a:51:72:C4:3C:B4:7E:C5:B5:FE:F5:74:0D:3E:98:E5:4C:C9:8E:4B:FA:66:C9:1A:A9:EC:8E:6C:E8:B9:F1:D9"

	// MARK: Base64 and secrets

	func testBase64FlavoursHaveNoPaddingAndRoundTrip() {
		XCTAssertEqual(ShareCodes.base64URL(secret), "AQIDBAUGBwgJCgsMDQ4PEA")
		XCTAssertEqual(ShareCodes.data(base64URL: "AQIDBAUGBwgJCgsMDQ4PEA"), secret)
		XCTAssertEqual(ShareCodes.base64NoPadding(Data([0xFB, 0xFF])), "+/8")
		XCTAssertEqual(ShareCodes.base64URL(Data([0xFB, 0xFF])), "-_8")
		XCTAssertEqual(ShareCodes.data(base64URL: "-_8"), Data([0xFB, 0xFF]))
		XCTAssertEqual(ShareCodes.data(base64URL: ""), Data())
	}

	func testBase64URLDecodingRefusesOtherText() {
		XCTAssertNil(ShareCodes.data(base64URL: "+/8"))
		XCTAssertNil(ShareCodes.data(base64URL: "AQID="))
		XCTAssertNil(ShareCodes.data(base64URL: "AQ ID"))
		XCTAssertNil(ShareCodes.data(base64URL: "AQIDB"), "a length of 4n + 1 can't be base64")
		XCTAssertNil(ShareCodes.data(base64URL: "é"))
	}

	func testSecretsAndSessionIDsAreFreshRandomBytes() {
		let first = ShareCodes.newSecret()
		XCTAssertEqual(first.count, 16)
		XCTAssertNotEqual(first, ShareCodes.newSecret())
		let session = ShareCodes.newSessionID()
		XCTAssertEqual(session.count, 11)
		XCTAssertEqual(ShareCodes.data(base64URL: session)?.count, 8)
		XCTAssertNotEqual(session, ShareCodes.newSessionID())
	}

	// MARK: Derivations (PROTOCOL.md §1.1)

	func testRoomIDMatchesTheProtocolVector() {
		XCTAssertEqual(ShareCodes.roomID(secret: secret), "8o2MFZXsZ_-zenK5lVG13R")
	}

	func testICECredentialsMatchTheProtocolVector() {
		let credentials = ShareCodes.iceCredentials(secret: secret)
		XCTAssertEqual(credentials.ufrag, "JtdLkDQk")
		XCTAssertEqual(credentials.pwd, "ZQTXo83Ch4FIONXev/7A54ci")
	}

	func testProofsMatchTheProtocolVectors() {
		XCTAssertEqual(ShareCodes.proof(secret: secret, role: "web", offerFingerprint: fingerprintAA, answerFingerprint: fingerprintBB),
					   "EpXFwY-xYQ-Pv7kuSqaHTPV91p-Nb4n2AtMQU9ZLUGk")
		XCTAssertEqual(ShareCodes.proof(secret: secret, role: "app", offerFingerprint: fingerprintAA, answerFingerprint: fingerprintBB),
					   "NuogRNgcibvc8iD5AZFpJUq_MdvVGuhpw622Z3WAd3M")
		XCTAssertNotEqual(ShareCodes.proof(secret: secret, role: "app", offerFingerprint: fingerprintBB, answerFingerprint: fingerprintAA),
						  "NuogRNgcibvc8iD5AZFpJUq_MdvVGuhpw622Z3WAd3M", "swapped fingerprints must not prove anything")
	}

	// MARK: Connection code (PROTOCOL.md §3.1)

	private let codeVectors: [(ip: String, port: UInt16, code: String)] = [
		("172.20.10.1", 52453, "1K75G"),
		("192.168.1.37", 54321, "80JBN1HG"),
		("10.0.12.200", 61000, "G006CHVJ8Z"),
		("172.16.5.9", 50000, "XC202GKGTGM"),
	]

	func testConnectionCodesMatchTheProtocolVectors() {
		for vector in codeVectors {
			XCTAssertEqual(ShareCodes.connectionCode(ipv4: vector.ip, port: vector.port), vector.code, vector.ip)
			let decoded = ShareCodes.decodeConnectionCode(vector.code)
			XCTAssertEqual(decoded?.ipv4, vector.ip, vector.code)
			XCTAssertEqual(decoded?.port, vector.port, vector.code)
		}
	}

	func testConnectionCodeDecodingForgivesDashesCaseAndLookalikes() {
		for text in ["8ojb-n1hg", "80JB-N1HG", " 80jb n1hg ", "8OJBN1HG"] {
			let decoded = ShareCodes.decodeConnectionCode(text)
			XCTAssertEqual(decoded?.ipv4, "192.168.1.37", text)
			XCTAssertEqual(decoded?.port, 54321, text)
		}
		for text in ["lK75G", "IK75-G", "ik75g"] {
			let decoded = ShareCodes.decodeConnectionCode(text)
			XCTAssertEqual(decoded?.ipv4, "172.20.10.1", text)
			XCTAssertEqual(decoded?.port, 52453, text)
		}
	}

	func testConnectionCodeRejectsTyposAndJunk() {
		XCTAssertNil(ShareCodes.decodeConnectionCode("80JBN1HH"), "a typo fails the check digit")
		XCTAssertNil(ShareCodes.decodeConnectionCode("80JBN1H"), "wrong length")
		XCTAssertNil(ShareCodes.decodeConnectionCode("80JBN1HGG"), "wrong length")
		XCTAssertNil(ShareCodes.decodeConnectionCode("hello!"))
		XCTAssertNil(ShareCodes.decodeConnectionCode(""))
		XCTAssertNil(ShareCodes.decodeConnectionCode("80JBN1HU"), "U isn't a Crockford digit")
		XCTAssertNil(ShareCodes.decodeConnectionCode("ß0JBN1HG"))
		// Every single-digit change in a position with an odd weight changes the check digit.
		let code = Array("G006CHVJ8Z")
		for position in stride(from: 0, to: code.count - 1, by: 2) {
			for replacement in "0123456789ABCDEFGHJKMNPQRSTVWXYZ" where replacement != code[position] {
				var typo = code
				typo[position] = replacement
				XCTAssertNil(ShareCodes.decodeConnectionCode(String(typo)), String(typo))
			}
		}
	}

	func testConnectionCodeEncodingRoundTripsAndRefusesNonIPv4() {
		let addresses: [(String, UInt16)] = [("192.168.0.1", 1), ("10.255.255.255", 65535), ("172.31.0.7", 40000),
											  ("8.8.8.8", 443), ("172.20.10.1", 9)]
		for (ip, port) in addresses {
			guard let code = ShareCodes.connectionCode(ipv4: ip, port: port) else { return XCTFail(ip) }
			let decoded = ShareCodes.decodeConnectionCode(ShareCodes.grouped(code))
			XCTAssertEqual(decoded?.ipv4, ip)
			XCTAssertEqual(decoded?.port, port)
		}
		for ip in ["fe80::1", "192.168.1", "192.168.1.256", "1.2.3.4.5", "a.b.c.d", "", "192.168.01.0001"] {
			XCTAssertNil(ShareCodes.connectionCode(ipv4: ip, port: 5000), ip)
		}
		XCTAssertNil(ShareCodes.connectionCode(ipv4: "192.168.1.37", port: 0))
	}

	func testCodesAreShownInGroupsOfFour() {
		XCTAssertEqual(ShareCodes.grouped("80JBN1HG"), "80JB-N1HG")
		XCTAssertEqual(ShareCodes.grouped("1K75G"), "1K75-G")
		XCTAssertEqual(ShareCodes.grouped("XC202GKGTGM"), "XC20-2GKG-TGM")
		XCTAssertEqual(ShareCodes.grouped("ABCD"), "ABCD")
	}

	// MARK: Pairing payload (PROTOCOL.md §3)

	/// ShareSite/tests/index.html's "payload hex": one mDNS, one IPv4 and one IPv6 candidate.
	private var webTestsPayload: Data {
		let text = "01" + "0102030405060708090a0b0c0d0e0f10" + "04" + asciiHex("pEeG") + "18" + asciiHex("UVxTphq7VLoWl7IGtQnsIRyq")
			+ "3a5172c43cb47ec5b5fef5740d3e98e54cc98e4bfa66c91aa9ec8e6ce8b9f1d9" + "01" + asciiHex("0") + "03"
			+ "6d" + "40dae37193f3444588ecb805a2838109" + "d295"
			+ "04" + "c0a80105" + "fb9b"
			+ "06" + "fe800000000000000000000000000001" + "fb9a"
		return hexData(text)
	}

	func testPairingPayloadFromTheWebTestsDecodes() throws {
		let offer = try XCTUnwrap(SharePairingOffer(payload: webTestsPayload))
		XCTAssertEqual(offer.secret, secret)
		XCTAssertEqual(offer.ufrag, "pEeG")
		XCTAssertEqual(offer.pwd, "UVxTphq7VLoWl7IGtQnsIRyq")
		XCTAssertEqual(offer.fingerprint, pageFingerprint.uppercased())
		XCTAssertEqual(offer.mid, "0")
		XCTAssertEqual(offer.candidates, [
			.init(host: "40dae371-93f3-4445-88ec-b805a2838109.local", port: 53909),
			.init(host: "192.168.1.5", port: 64411),
			.init(host: "fe80::1", port: 64410),
		])
		XCTAssertEqual(payload(), hexData("01" + "0102030405060708090a0b0c0d0e0f10" + "04" + asciiHex("pEeG") + "18"
										  + asciiHex("UVxTphq7VLoWl7IGtQnsIRyq") + "3a5172c43cb47ec5b5fef5740d3e98e54cc98e4bfa66c91aa9ec8e6ce8b9f1d9"
										  + "01" + asciiHex("0") + "01" + "04c0a80105fb9b"), "the builder below lays bytes out the same way")
	}

	func testPairingLinkAcceptsTheWholeLinkOrJustThePayload() throws {
		let encoded = ShareCodes.base64URL(webTestsPayload)
		let offer = try XCTUnwrap(SharePairingOffer(payload: webTestsPayload))
		XCTAssertEqual(SharePairingOffer(link: "openscanner://share?p=\(encoded)"), offer)
		XCTAssertEqual(SharePairingOffer(link: "  OpenScanner://share?p=\(encoded)\n"), offer)
		XCTAssertEqual(SharePairingOffer(link: encoded), offer)
		XCTAssertNil(SharePairingOffer(link: "openscanner://inbox?p=\(encoded)"))
		XCTAssertNil(SharePairingOffer(link: "https://share?p=\(encoded)"))
		XCTAssertNil(SharePairingOffer(link: "openscanner://share?q=\(encoded)"))
		XCTAssertNil(SharePairingOffer(link: "openscanner://share?p=\(encoded)="))
		XCTAssertNil(SharePairingOffer(link: ""))
		XCTAssertNil(SharePairingOffer(link: String(repeating: "A", count: 5000)))
	}

	func testPairingPayloadRejectsOtherVersionsAndTruncation() {
		XCTAssertNotNil(SharePairingOffer(payload: payload()))
		XCTAssertNil(SharePairingOffer(payload: payload(version: 2)))
		XCTAssertNil(SharePairingOffer(payload: payload(version: 0)))
		let whole = webTestsPayload
		for length in 0..<whole.count {
			XCTAssertNil(SharePairingOffer(payload: whole.prefix(length)), "truncated to \(length) bytes")
		}
		XCTAssertNil(SharePairingOffer(payload: whole + Data([0])), "trailing bytes")
	}

	func testPairingPayloadRejectsICEValuesThatCouldBreakSDP() {
		XCTAssertNil(SharePairingOffer(payload: payload(ufrag: "pE\neG")))
		XCTAssertNil(SharePairingOffer(payload: payload(ufrag: "pE eG")))
		XCTAssertNil(SharePairingOffer(payload: payload(ufrag: "pEeG\r\na=candidate:x")))
		XCTAssertNil(SharePairingOffer(payload: payload(ufrag: "pEe")), "under 4 characters")
		XCTAssertNil(SharePairingOffer(payload: payload(pwd: "UVxTphq7VLoWl7IGtQnsI\n")))
		XCTAssertNil(SharePairingOffer(payload: payload(pwd: "UVxTphq7VLoWl7IGtQnsI")), "under 22 characters")
		XCTAssertNil(SharePairingOffer(payload: payload(mid: "")))
		XCTAssertNil(SharePairingOffer(payload: payload(mid: "0 1")))
		XCTAssertNil(SharePairingOffer(payload: payload(mid: String(repeating: "m", count: 17))))
		XCTAssertNotNil(SharePairingOffer(payload: payload(ufrag: "ab+/", mid: "data_1-a")))
	}

	func testPairingPayloadRejectsBadCandidates() {
		let ipv4: [UInt8] = [4, 192, 168, 1, 5, 0xFB, 0x9B]
		XCTAssertEqual(SharePairingOffer(payload: payload(candidates: Array(repeating: ipv4, count: 8)))?.candidates.count, 8)
		XCTAssertNil(SharePairingOffer(payload: payload(candidates: Array(repeating: ipv4, count: 9))), "too many candidates")
		XCTAssertNil(SharePairingOffer(payload: payload(candidates: [ipv4], count: 2)), "count says more than there are")
		XCTAssertNil(SharePairingOffer(payload: payload(candidates: [[5, 1, 2, 3, 4, 0x13, 0x88]])), "unknown kind")
		XCTAssertNil(SharePairingOffer(payload: payload(candidates: [[4, 192, 168, 1, 5, 0, 0]])), "port 0")
		XCTAssertEqual(SharePairingOffer(payload: payload(candidates: []))?.candidates, [])
	}

	// MARK: SDP (PROTOCOL.md §3)

	func testOfferIsRebuiltFromThePairingCode() throws {
		let pairing = try XCTUnwrap(SharePairingOffer(payload: webTestsPayload))
		let sdp = ShareSDP.offer(for: pairing)
		XCTAssertTrue(sdp.hasPrefix("v=0\r\no=- "))
		XCTAssertTrue(sdp.hasSuffix("a=max-message-size:262144\r\n"))
		XCTAssertFalse(sdp.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every line ends in CRLF")
		let lines = sdp.components(separatedBy: "\r\n")
		for expected in ["s=-", "t=0 0", "a=group:BUNDLE 0", "a=msid-semantic: WMS", "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
						 "c=IN IP4 0.0.0.0", "a=ice-ufrag:pEeG", "a=ice-pwd:UVxTphq7VLoWl7IGtQnsIRyq", "a=ice-options:trickle",
						 "a=fingerprint:sha-256 \(pageFingerprint.uppercased())", "a=setup:actpass", "a=mid:0",
						 "a=sctp-port:5000", "a=max-message-size:262144"] {
			XCTAssertTrue(lines.contains(expected), expected)
		}
		let candidates = lines.filter { $0.hasPrefix("a=candidate:") }.compactMap { ShareSDP.hostCandidate($0) }
		XCTAssertEqual(candidates.map(\.address), ["40dae371-93f3-4445-88ec-b805a2838109.local", "192.168.1.5", "fe80::1"])
		XCTAssertEqual(candidates.map(\.port), [53909, 64411, 64410])
		XCTAssertEqual(ShareSDP.fingerprint(in: sdp), pageFingerprint.uppercased())
		let mLine = try XCTUnwrap(lines.firstIndex(of: "m=application 9 UDP/DTLS/SCTP webrtc-datachannel"))
		let firstCandidate = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("a=candidate:") })
		XCTAssertLessThan(mLine, firstCandidate, "candidates belong to the media section")
	}

	func testOfferUsesLookedUpAddressesForMDNSCandidates() throws {
		let pairing = try XCTUnwrap(SharePairingOffer(payload: webTestsPayload))
		let name = "40dae371-93f3-4445-88ec-b805a2838109.local"
		func hosts(_ addresses: [String: String]) -> [String] {
			ShareSDP.offer(for: pairing, addresses: addresses).components(separatedBy: "\r\n")
				.filter { $0.hasPrefix("a=candidate:") }.compactMap { ShareSDP.hostCandidate($0)?.address }
		}
		XCTAssertEqual(hosts([name: "192.168.1.9"]), ["192.168.1.9", "192.168.1.5", "fe80::1"])
		XCTAssertEqual(hosts([name: "192.168.1.9 typ host\r\na=x"]), [name, "192.168.1.5", "fe80::1"], "only dotted IPv4 goes in")
		XCTAssertEqual(hosts([name: "fe80::2"]), [name, "192.168.1.5", "fe80::1"])
		XCTAssertEqual(hosts([:]), [name, "192.168.1.5", "fe80::1"])
	}

	func testICECredentialsAreReplacedInTheAnswer() {
		let answer = sampleAnswer
		let credentials = ShareCodes.iceCredentials(secret: secret)
		let replaced = ShareSDP.replacingICECredentials(in: answer, ufrag: credentials.ufrag, pwd: credentials.pwd)
		XCTAssertTrue(replaced.contains("\r\na=ice-ufrag:JtdLkDQk\r\n"))
		XCTAssertTrue(replaced.contains("\r\na=ice-pwd:ZQTXo83Ch4FIONXev/7A54ci\r\n"))
		XCTAssertFalse(replaced.contains("a=ice-ufrag:Xy12"))
		XCTAssertFalse(replaced.contains("aBcDeFgHiJkLmNoPqRsTuVwX"))
		XCTAssertEqual(replaced.components(separatedBy: "\r\n").count, answer.components(separatedBy: "\r\n").count)
		XCTAssertEqual(replaced.replacingOccurrences(of: "JtdLkDQk", with: "Xy12").replacingOccurrences(of: "ZQTXo83Ch4FIONXev/7A54ci", with: "aBcDeFgHiJkLmNoPqRsTuVwX"),
					   answer, "nothing else changes")
		XCTAssertEqual(ShareSDP.replacingICECredentials(in: answer, ufrag: "bad\r\na=x", pwd: credentials.pwd), answer)
		XCTAssertEqual(ShareSDP.replacingICECredentials(in: answer, ufrag: credentials.ufrag, pwd: "$1short"), answer)
	}

	func testFingerprintIsReadUpperCased() {
		let sdp = "v=0\r\na=ice-ufrag:pEeG\r\na=fingerprint:sha-256 \(pageFingerprint)\r\na=mid:0\r\n"
		XCTAssertEqual(ShareSDP.fingerprint(in: sdp), "3A:51:72:C4:3C:B4:7E:C5:B5:FE:F5:74:0D:3E:98:E5:4C:C9:8E:4B:FA:66:C9:1A:A9:EC:8E:6C:E8:B9:F1:D9")
		XCTAssertEqual(ShareSDP.fingerprint(in: sampleAnswer), ShareCertificate.fingerprint)
		XCTAssertEqual(ShareSDP.fingerprint(in: "a=fingerprint:sha-1 AA:BB\na=fingerprint:sha-256 \(fingerprintAA)\n"), fingerprintAA)
		XCTAssertNil(ShareSDP.fingerprint(in: "v=0\r\na=mid:0\r\n"))
		XCTAssertNil(ShareSDP.fingerprint(in: "a=fingerprint:sha-256 AA:BB:CC\r\n"), "not 32 bytes")
		XCTAssertNil(ShareSDP.fingerprint(in: "a=fingerprint:sha-256 \(fingerprintAA.replacingOccurrences(of: "AA", with: "GG"))\r\n"))
	}

	func testRelayOffersMustHaveExactlyOneFingerprint() throws {
		let pairing = try XCTUnwrap(SharePairingOffer(payload: webTestsPayload))
		let offer = ShareSDP.offer(for: pairing)
		XCTAssertEqual(ShareSDP.soleFingerprint(in: offer), pageFingerprint.uppercased())
		// A relay naming the page's fingerprint at session level and its own at media level: libwebrtc
		// would check the media-level one, while the proof would cover the session-level one.
		let sessionLevel = offer.replacingOccurrences(of: "t=0 0\r\n", with: "t=0 0\r\na=fingerprint:sha-256 \(pageFingerprint)\r\n")
		let swapped = sessionLevel.replacingOccurrences(of: "a=fingerprint:sha-256 \(pageFingerprint.uppercased())",
														with: "a=fingerprint:sha-256 \(fingerprintBB)")
		XCTAssertEqual(ShareSDP.fingerprint(in: swapped), pageFingerprint.uppercased(), "the first line alone looks fine")
		XCTAssertNil(ShareSDP.soleFingerprint(in: swapped))
		XCTAssertNil(ShareSDP.soleFingerprint(in: sessionLevel), "two lines, even when they agree")
		for extra in ["a=fingerprint:sha-1 AA:BB", "a=fingerprint:sha-512 \(fingerprintAA)", "A=FINGERPRINT:sha-256 \(fingerprintAA)",
					  " a=fingerprint:sha-256 \(fingerprintAA)"] {
			XCTAssertNil(ShareSDP.soleFingerprint(in: offer + extra + "\r\n"), extra)
		}
		XCTAssertNil(ShareSDP.soleFingerprint(in: offer.replacingOccurrences(of: "a=mid:0\r\n", with: "a=mid:0\ra=fingerprint:sha-256 \(fingerprintAA)\r\n")),
					 "a bare CR still starts a line")
		XCTAssertNil(ShareSDP.soleFingerprint(in: "v=0\r\na=fingerprint:sha-1 \(fingerprintAA)\r\n"), "the one line isn't sha-256")
		XCTAssertNil(ShareSDP.soleFingerprint(in: "v=0\r\na=fingerprint:sha-256 AA:BB\r\n"), "the one line is malformed")
		XCTAssertNil(ShareSDP.soleFingerprint(in: "v=0\r\na=mid:0\r\n"))
		XCTAssertEqual(ShareSDP.soleFingerprint(in: sampleAnswer), ShareCertificate.fingerprint)
	}

	func testRelayOffersMustBeOneDataChannel() throws {
		let pairing = try XCTUnwrap(SharePairingOffer(payload: webTestsPayload))
		let offer = ShareSDP.offer(for: pairing)
		XCTAssertTrue(ShareSDP.isDataChannelOnly(offer))
		XCTAssertTrue(ShareSDP.isDataChannelOnly(sampleAnswer))
		XCTAssertTrue(ShareSDP.isDataChannelOnly(offer.replacingOccurrences(of: "m=application 9 ", with: "m=application 50000 ")))
		let audio = "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=mid:1\r\na=recvonly\r\na=rtpmap:111 opus/48000/2\r\n"
		XCTAssertFalse(ShareSDP.isDataChannelOnly(offer + audio), "a second, audio section")
		XCTAssertFalse(ShareSDP.isDataChannelOnly(offer + "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:1\r\n"))
		XCTAssertFalse(ShareSDP.isDataChannelOnly(offer.replacingOccurrences(of: "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
																			  with: "m=video 9 UDP/TLS/RTP/SAVPF 96")))
		for bad in ["m=application 9 DTLS/SCTP 5000", "m=application x UDP/DTLS/SCTP webrtc-datachannel",
					"m=application 70000 UDP/DTLS/SCTP webrtc-datachannel", "m=application 9 UDP/DTLS/SCTP webrtc-datachannel extra",
					"m=application  9 UDP/DTLS/SCTP webrtc-datachannel"] {
			XCTAssertFalse(ShareSDP.isDataChannelOnly(offer.replacingOccurrences(of: "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", with: bad)), bad)
		}
		XCTAssertFalse(ShareSDP.isDataChannelOnly(offer + " M=audio 9 RTP/AVP 0\r\n"), "counted however it's written")
		XCTAssertFalse(ShareSDP.isDataChannelOnly("v=0\r\ns=-\r\nt=0 0\r\n"), "no media section at all")
	}

	func testHostCandidatesAreUDPHostsOnly() {
		let udp = ShareSDP.hostCandidate("a=candidate:2 1 udp 2113939711 192.168.1.5 64411 typ host generation 0")
		XCTAssertEqual(udp?.address, "192.168.1.5")
		XCTAssertEqual(udp?.port, 64411)
		let bare = ShareSDP.hostCandidate("candidate:3 1 UDP 2122260223 172.20.10.1 52453 typ host")
		XCTAssertEqual(bare?.address, "172.20.10.1")
		XCTAssertEqual(bare?.port, 52453)
		let mdns = ShareSDP.hostCandidate("candidate:2860851947 1 udp 2113937151 40dae371-93f3-4445-88ec-b805a2838109.local 53909 typ host")
		XCTAssertEqual(mdns?.address, "40dae371-93f3-4445-88ec-b805a2838109.local")
		XCTAssertNil(ShareSDP.hostCandidate("a=candidate:3 1 tcp 1518214911 192.168.1.5 9 typ host tcptype active"))
		XCTAssertNil(ShareSDP.hostCandidate("a=candidate:4 1 udp 1677729535 1.2.3.4 50000 typ srflx raddr 0.0.0.0 rport 0"))
		XCTAssertNil(ShareSDP.hostCandidate("a=candidate:5 1 udp 41885439 1.2.3.4 50000 typ relay raddr 0.0.0.0 rport 0"))
		XCTAssertNil(ShareSDP.hostCandidate("a=candidate:2 2 udp 2113939710 192.168.1.5 64412 typ host"), "RTCP component")
		XCTAssertNil(ShareSDP.hostCandidate("a=candidate:2 1 udp 2113939711 192.168.1.5 0 typ host"))
		XCTAssertNil(ShareSDP.hostCandidate("a=candidate:2 1 udp 2113939711 192.168.1.5 70000 typ host"))
		XCTAssertNil(ShareSDP.hostCandidate("a=candidate:2 1 udp 2113939711 192.168.1.5;rm 64411 typ host"))
		XCTAssertNil(ShareSDP.hostCandidate("a=mid:0"))
		XCTAssertNil(ShareSDP.hostCandidate(""))
	}

	// MARK: Connection code candidate

	func testCodeCandidatePrefersHotspotThenWiFiThenOtherLocalNetworks() {
		let interfaces = ["172.20.10.1": "bridge100", "192.168.1.10": "en0", "192.168.2.20": "en8", "10.0.0.5": "utun3",
						  "10.64.0.9": "pdp_ip0", "192.168.64.1": "bridge101", "10.9.9.9": "ipsec0", "169.254.3.4": "awdl0"]
		let everything: [(address: String, port: UInt16)] = [
			("10.0.0.5", 5001), ("10.64.0.9", 5002), ("192.168.2.20", 5003), ("192.168.1.10", 5004), ("172.20.10.1", 5005),
		]
		XCTAssertEqual(ShareNetwork.codeCandidate(from: everything, interfaces: interfaces)?.address, "172.20.10.1")
		XCTAssertEqual(ShareNetwork.codeCandidate(from: everything, interfaces: interfaces)?.port, 5005)
		let noHotspot = everything.filter { $0.address != "172.20.10.1" }
		XCTAssertEqual(ShareNetwork.codeCandidate(from: noHotspot, interfaces: interfaces)?.address, "192.168.1.10")
		let noWiFi = noHotspot.filter { $0.address != "192.168.1.10" }
		XCTAssertEqual(ShareNetwork.codeCandidate(from: noWiFi, interfaces: interfaces)?.address, "192.168.2.20")
		let bridgeFirst: [(address: String, port: UInt16)] = [("192.168.64.1", 6000), ("192.168.2.20", 6001)]
		XCTAssertEqual(ShareNetwork.codeCandidate(from: bridgeFirst, interfaces: interfaces)?.address, "192.168.64.1", "ties keep their order")
		let unknownFirst: [(address: String, port: UInt16)] = [("192.168.9.9", 6000), ("192.168.2.20", 6001)]
		XCTAssertEqual(ShareNetwork.codeCandidate(from: unknownFirst, interfaces: interfaces)?.address, "192.168.2.20")
		XCTAssertEqual(ShareNetwork.codeCandidate(from: [("192.168.9.9", 6000)], interfaces: interfaces)?.address, "192.168.9.9")
	}

	func testCodeCandidateNeverUsesCellularVPNPublicOrIPv6Addresses() {
		let interfaces = ["10.0.0.5": "utun3", "10.64.0.9": "pdp_ip0", "10.9.9.9": "ipsec0", "172.16.0.2": "llw0",
						  "192.168.7.7": "anpi0", "10.1.1.1": "lo0", "17.5.7.8": "en0", "169.254.3.4": "en0"]
		let candidates: [(address: String, port: UInt16)] = [
			("10.0.0.5", 1), ("10.64.0.9", 2), ("10.9.9.9", 3), ("172.16.0.2", 4), ("192.168.7.7", 5), ("10.1.1.1", 6),
			("17.5.7.8", 7), ("169.254.3.4", 8), ("fe80::1", 9), ("40dae371-93f3-4445-88ec-b805a2838109.local", 10),
		]
		XCTAssertNil(ShareNetwork.codeCandidate(from: candidates, interfaces: interfaces))
		XCTAssertNil(ShareNetwork.codeCandidate(from: [("192.168.1.10", 0)], interfaces: ["192.168.1.10": "en0"]), "port 0")
		XCTAssertNil(ShareNetwork.codeCandidate(from: [], interfaces: [:]))
	}

	func testInterfaceNamesIncludeLoopback() {
		XCTAssertEqual(ShareNetwork.interfaceNames()["127.0.0.1"], "lo0")
	}

	// MARK: The page's mDNS candidates

	func testMDNSNamesAreBrowserUUIDsDotLocal() {
		XCTAssertTrue(ShareNetwork.isMDNSName("40dae371-93f3-4445-88ec-b805a2838109.local"))
		XCTAssertTrue(ShareNetwork.isMDNSName("40DAE371-93F3-4445-88EC-B805A2838109.local"))
		XCTAssertFalse(ShareNetwork.isMDNSName("192.168.1.5"))
		XCTAssertFalse(ShareNetwork.isMDNSName("fe80::1"))
		XCTAssertFalse(ShareNetwork.isMDNSName("40dae371-93f3-4445-88ec-b805a2838109.locals"))
		XCTAssertFalse(ShareNetwork.isMDNSName("40dae371-93f3-4445-88ec-b805a283810.local"), "one digit short")
		XCTAssertFalse(ShareNetwork.isMDNSName("40dae371x93f3-4445-88ec-b805a2838109.local"))
		XCTAssertFalse(ShareNetwork.isMDNSName("40dae371-93f3-4445-88ec-b805a283810g.local"))
		XCTAssertFalse(ShareNetwork.isMDNSName("printer.local"))
		XCTAssertFalse(ShareNetwork.isMDNSName(""))
	}

	func testLookedUpCandidateLinesAreIPv4HostCandidates() throws {
		let line = try XCTUnwrap(ShareSDP.ipv4HostCandidate(foundation: 101, address: "192.168.1.5", port: 53909))
		XCTAssertTrue(line.hasPrefix("candidate:101 1 udp "))
		XCTAssertTrue(line.hasSuffix(" 192.168.1.5 53909 typ host"))
		let read = try XCTUnwrap(ShareSDP.hostCandidate(line))
		XCTAssertEqual(read.address, "192.168.1.5")
		XCTAssertEqual(read.port, 53909)
		XCTAssertNil(ShareSDP.ipv4HostCandidate(foundation: 101, address: "fe80::1", port: 53909))
		XCTAssertNil(ShareSDP.ipv4HostCandidate(foundation: 101, address: "40dae371-93f3-4445-88ec-b805a2838109.local", port: 53909))
		XCTAssertNil(ShareSDP.ipv4HostCandidate(foundation: 101, address: "192.168.1.5 typ host\r\na=x", port: 53909))
		XCTAssertNil(ShareSDP.ipv4HostCandidate(foundation: 101, address: "192.168.1.5", port: 0))
		XCTAssertNil(ShareSDP.ipv4HostCandidate(foundation: 0, address: "192.168.1.5", port: 53909))
	}

	func testOnlyMDNSNamesAreLookedUp() async {
		let started = Date.now
		let none = await ShareNetwork.ipv4(forMDNSName: "localhost")
		XCTAssertNil(none, "not a browser's mDNS name, so no lookup")
		XCTAssertLessThan(Date.now.timeIntervalSince(started), 0.5)
	}

	// MARK: Messages from the page (PROTOCOL.md §4)

	func testInboundMessagesDecode() {
		XCTAssertEqual(inbound(#"{"t":"hello","v":1,"role":"web","name":"Chrome on Mac","device":"computer","proof":"EpXFwY-xYQ-Pv7kuSqaHTPV91p-Nb4n2AtMQU9ZLUGk"}"#),
					   .hello(name: "Chrome on Mac", device: "computer", proof: "EpXFwY-xYQ-Pv7kuSqaHTPV91p-Nb4n2AtMQU9ZLUGk"))
		XCTAssertEqual(inbound(#"{"t":"hello","v":1,"role":"web","name":"Safari on iPhone","device":"phone"}"#),
					   .hello(name: "Safari on iPhone", device: "phone", proof: nil))
		XCTAssertEqual(inbound(#"{"t":"hello","name":"Edge","device":"toaster","proof":null}"#),
					   .hello(name: "Edge", device: "computer", proof: nil))
		XCTAssertEqual(inbound(#"{"t":"unlock","id":"aB3_-x","pin":"482913"}"#), .unlock(id: "aB3_-x", pin: "482913"))
		XCTAssertEqual(inbound(#"{"t":"get","id":"aB3_-x"}"#), .get(id: "aB3_-x"))
		XCTAssertEqual(inbound(#"{"t":"send","xfer":"u12","name":"Lease.pdf","size":123456,"type":"application/pdf"}"#),
					   .send(xfer: "u12", name: "Lease.pdf", size: 123_456, type: "application/pdf"))
		XCTAssertEqual(inbound(#"{"t":"send","xfer":"u13","name":"Photo.JPG","size":5000000000,"type":"Image/JPEG"}"#),
					   .send(xfer: "u13", name: "Photo.JPG", size: 5_000_000_000, type: "image/jpeg"))
		XCTAssertEqual(inbound(#"{"t":"send","xfer":"u14","name":"blob","size":0}"#), .send(xfer: "u14", name: "blob", size: 0, type: ""))
		XCTAssertEqual(inbound(#"{"t":"end","xfer":"u12"}"#), .end(xfer: "u12"))
		XCTAssertEqual(inbound(#"{"t":"cancel","xfer":"u12"}"#), .cancel(xfer: "u12"))
		XCTAssertEqual(inbound(#"{"t":"bye"}"#), .bye)
	}

	func testInboundNamesAreCleanedAndClipped() {
		let long = String(repeating: "é", count: 300)
		guard case let .send(_, name, _, _)? = inbound(#"{"t":"send","xfer":"u1","name":"\#(long)","size":1,"type":"image/png"}"#) else {
			return XCTFail("send didn't decode")
		}
		XCTAssertEqual(name.count, 255)
		XCTAssertEqual(inbound(#"{"t":"send","xfer":"u1","name":" Lease\n\u0000‮.pdf ","size":1,"type":"application/pdf"}"#),
					   .send(xfer: "u1", name: "Lease.pdf", size: 1, type: "application/pdf"))
		guard case let .hello(helloName, _, _)? = inbound(#"{"t":"hello","name":"\#(long)","device":"phone"}"#) else {
			return XCTFail("hello didn't decode")
		}
		XCTAssertEqual(helloName.count, 64)
	}

	func testMalformedInboundMessagesAreDropped() {
		let malformed = [
			"not json", "[]", #""hello""#, "{}", #"{"t":5}"#,
			#"{"t":"hello","role":"app","name":"Rescriva","device":"iphone"}"#,
			#"{"t":"hello","device":"computer"}"#,
			#"{"t":"hello","name":"Chrome","device":"computer","proof":42}"#,
			#"{"t":"hello","name":"Chrome","device":"computer","proof":""}"#,
			#"{"t":"unlock","id":"abc"}"#,
			#"{"t":"unlock","id":"abc","pin":482913}"#,
			#"{"t":"unlock","id":"abc","pin":"48291348291348291"}"#,
			#"{"t":"get","id":"../etc"}"#,
			#"{"t":"get","id":""}"#,
			#"{"t":"get","id":"\#(String(repeating: "a", count: 65))"}"#,
			#"{"t":"send","xfer":"u1","name":"a.pdf","size":-1,"type":"application/pdf"}"#,
			#"{"t":"send","xfer":"u1","name":"a.pdf","size":1.5,"type":"application/pdf"}"#,
			#"{"t":"send","xfer":"u1","name":"a.pdf","size":"12","type":"application/pdf"}"#,
			#"{"t":"send","xfer":"u1","name":"a.pdf","size":true,"type":"application/pdf"}"#,
			#"{"t":"send","xfer":"u1","name":"a.pdf","size":1e300,"type":"application/pdf"}"#,
			#"{"t":"send","xfer":"u 1","name":"a.pdf","size":1,"type":"application/pdf"}"#,
			#"{"t":"send","xfer":"u1","size":1,"type":"application/pdf"}"#,
			#"{"t":"end"}"#,
			#"{"t":"cancel","xfer":7}"#,
		]
		for text in malformed {
			XCTAssertNil(inbound(text), text)
		}
		let huge = #"{"t":"bye","pad":""# + String(repeating: "x", count: 70 * 1024) + #""}"#
		XCTAssertNil(inbound(huge), "over 64 KiB")
	}

	func testUnknownInboundMessagesAreDropped() {
		for text in [#"{"t":"docs","docs":[]}"#, #"{"t":"file","id":"a","xfer":"b"}"#, #"{"t":"dance"}"#, #"{"t":"HELLO","name":"x","device":"phone"}"#] {
			XCTAssertNil(inbound(text), text)
		}
	}

	// MARK: Messages from the app

	func testOutboundMessagesRoundTripThroughJSON() throws {
		var hello = try object(.hello(name: "Michael's iPhone", device: "iphone", session: "AAECAwQFBgc", proof: "NuogRNgc"))
		XCTAssertEqual(hello["t"] as? String, "hello")
		XCTAssertEqual(hello["v"] as? Int, 1)
		XCTAssertEqual(hello["role"] as? String, "app")
		XCTAssertEqual(hello["name"] as? String, "Michael's iPhone")
		XCTAssertEqual(hello["device"] as? String, "iphone")
		XCTAssertEqual(hello["session"] as? String, "AAECAwQFBgc")
		XCTAssertEqual(hello["proof"] as? String, "NuogRNgc")
		hello = try object(.hello(name: "iPad", device: "ipad", session: "s", proof: nil))
		XCTAssertNil(hello["proof"])

		let docs = try object(.docs([ShareDocSummary(id: "d1", name: "Lease.pdf", size: 5_000_000_000, type: "application/pdf", unlocked: true),
									 ShareDocSummary(id: "d2", name: "Receipt", size: 12, type: "application/pdf", unlocked: false)]))
		let list = try XCTUnwrap(docs["docs"] as? [[String: Any]])
		XCTAssertEqual(list.count, 2)
		XCTAssertEqual(list[0]["id"] as? String, "d1")
		XCTAssertEqual(list[0]["name"] as? String, "Lease.pdf")
		XCTAssertEqual((list[0]["size"] as? NSNumber)?.int64Value, 5_000_000_000)
		XCTAssertEqual(list[0]["type"] as? String, "application/pdf")
		XCTAssertEqual(list[0]["unlocked"] as? Bool, true)
		XCTAssertEqual(list[1]["unlocked"] as? Bool, false)
		let empty = try object(.docs([]))
		XCTAssertEqual((empty["docs"] as? [Any])?.count, 0, "sharing ended")

		XCTAssertEqual(try object(.unlocked(id: "d1")) as NSDictionary, ["t": "unlocked", "id": "d1"])
		XCTAssertEqual(try object(.denied(id: "d1", reason: "cooldown", retryIn: 30, left: 0)) as NSDictionary,
					   ["t": "denied", "id": "d1", "reason": "cooldown", "retryIn": 30, "left": 0])
		XCTAssertEqual(try object(.denied(id: "d1", reason: "gone", retryIn: nil, left: nil)) as NSDictionary,
					   ["t": "denied", "id": "d1", "reason": "gone"])
		XCTAssertEqual(try object(.file(id: "d1", xfer: "x1", name: "Lease.pdf", size: 77, type: "application/pdf")) as NSDictionary,
					   ["t": "file", "id": "d1", "xfer": "x1", "name": "Lease.pdf", "size": 77, "type": "application/pdf"])
		XCTAssertEqual(try object(.end(xfer: "x1")) as NSDictionary, ["t": "end", "xfer": "x1"])
		XCTAssertEqual(try object(.accept(xfer: "u1")) as NSDictionary, ["t": "accept", "xfer": "u1"])
		XCTAssertEqual(try object(.decline(xfer: "u1", reason: "type")) as NSDictionary, ["t": "decline", "xfer": "u1", "reason": "type"])
		XCTAssertEqual(try object(.decline(xfer: "u1", reason: nil)) as NSDictionary, ["t": "decline", "xfer": "u1"])
		XCTAssertEqual(try object(.saved(xfer: "u1", ok: true)) as NSDictionary, ["t": "saved", "xfer": "u1", "ok": true])
		XCTAssertEqual(try object(.cancel(xfer: "u1")) as NSDictionary, ["t": "cancel", "xfer": "u1"])
		XCTAssertEqual(try object(.bye) as NSDictionary, ["t": "bye"])
	}

	func testOutboundJSONIsCompactWithRealBooleansAndPlainSlashes() {
		XCTAssertEqual(String(decoding: ShareOutbound.saved(xfer: "u1", ok: false).json, as: UTF8.self), #"{"ok":false,"t":"saved","xfer":"u1"}"#)
		XCTAssertEqual(String(decoding: ShareOutbound.bye.json, as: UTF8.self), #"{"t":"bye"}"#)
		let file = String(decoding: ShareOutbound.file(id: "d", xfer: "x", name: "a/b", size: 1, type: "application/pdf").json, as: UTF8.self)
		XCTAssertTrue(file.contains(#""type":"application/pdf""#), file)
	}

	// MARK: Relay signals (PROTOCOL.md §2)

	func testSignalsRoundTripThroughJSON() throws {
		let signals: [ShareSignal] = [
			.offer("v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n"),
			.answer("v=0\r\na=setup:active\r\n"),
			.candidate("candidate:1 1 udp 2122260223 192.168.1.5 64411 typ host", sdpMid: "0", sdpMLineIndex: 0),
			.candidate("candidate:2 1 udp 2122260223 10.0.0.2 5000 typ host", sdpMid: nil, sdpMLineIndex: 1),
		]
		for signal in signals {
			XCTAssertEqual(ShareSignal(data: signal.data), signal)
			let json = try JSONSerialization.data(withJSONObject: signal.data)
			let back = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
			XCTAssertEqual(ShareSignal(data: back), signal)
		}
		let offer = try XCTUnwrap(ShareSignal.offer("sdp text").data["sdp"] as? [String: Any])
		XCTAssertEqual(offer["type"] as? String, "offer")
		XCTAssertEqual(offer["sdp"] as? String, "sdp text")
	}

	func testSignalsReadWhatBrowsersSend() throws {
		let json = #"{"candidate":{"candidate":"candidate:1 1 udp 2122260223 192.168.1.5 64411 typ host","sdpMid":"0","sdpMLineIndex":0,"usernameFragment":"pEeG"}}"#
		let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
		XCTAssertEqual(ShareSignal(data: data), .candidate("candidate:1 1 udp 2122260223 192.168.1.5 64411 typ host", sdpMid: "0", sdpMLineIndex: 0))
		XCTAssertEqual(ShareSignal(data: ["candidate": ["candidate": "candidate:x", "sdpMid": NSNull(), "sdpMLineIndex": NSNull()]]),
					   .candidate("candidate:x", sdpMid: nil, sdpMLineIndex: 0))
		XCTAssertEqual(ShareSignal(data: ["candidate": ["candidate": "candidate:x"]]), .candidate("candidate:x", sdpMid: nil, sdpMLineIndex: 0))
	}

	func testMalformedSignalsAreDropped() {
		let bad: [[String: Any]] = [
			[:],
			["sdp": ["type": "pranswer", "sdp": "v=0"]],
			["sdp": ["type": "offer"]],
			["sdp": ["type": "offer", "sdp": 5]],
			["sdp": ["type": "offer", "sdp": String(repeating: "a", count: 70 * 1024)]],
			["sdp": "v=0"],
			["candidate": "candidate:1 1 udp 1 1.2.3.4 5 typ host"],
			["candidate": ["candidate": "candidate:1\r\na=evil"]],
			["candidate": ["candidate": 5]],
			["candidate": ["candidate": "candidate:x", "sdpMid": 0]],
			["candidate": ["candidate": "candidate:x", "sdpMLineIndex": -1]],
			["candidate": ["candidate": "candidate:x", "sdpMLineIndex": 1.5]],
			["candidate": ["candidate": "candidate:x", "sdpMLineIndex": "0"]],
		]
		for data in bad {
			XCTAssertNil(ShareSignal(data: data), "\(data)")
		}
	}

	// MARK: PINs

	func testPINsAreSixDigitsAndUniqueInASession() {
		var used = Set<String>()
		for _ in 0..<2000 {
			let pin = ShareCodes.newPIN(avoiding: used)
			XCTAssertEqual(pin.count, 6)
			XCTAssertTrue(pin.utf8.allSatisfy { (48...57).contains($0) }, pin)
			XCTAssertFalse(used.contains(pin), pin)
			used.insert(pin)
		}
		XCTAssertEqual(used.count, 2000)
	}

	func testPINsAreShownInTwoGroups() {
		XCTAssertEqual(ShareCodes.displayPIN("482913"), "482 913")
		XCTAssertEqual(ShareCodes.displayPIN("000001"), "000 001")
		XCTAssertEqual(ShareCodes.displayPIN("12"), "12")
	}

	// MARK: Built-in certificate and configuration

	func testBuiltInCertificateMatchesItsFingerprintAndKey() throws {
		XCTAssertEqual(ShareCertificate.fingerprint,
					   "C8:7F:82:09:B8:EF:F6:FB:92:37:13:91:BD:28:85:F1:50:E7:03:8D:3E:BB:DA:99:2A:78:3C:9F:DB:E1:95:CB")
		let der = try XCTUnwrap(pemBody(ShareCertificate.certificatePEM, label: "CERTIFICATE"))
		let digest = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
		XCTAssertEqual(digest, ShareCertificate.fingerprint)
		let key = try P256.Signing.PrivateKey(pemRepresentation: ShareCertificate.privateKeyPEM)
		XCTAssertNotNil(der.range(of: key.publicKey.x963Representation), "the certificate holds this key's public half")
		XCTAssertTrue(ShareCertificate.privateKeyPEM.hasPrefix("-----BEGIN PRIVATE KEY-----\n"), "PKCS#8, as RTCCertificate wants")
	}

	// MARK: Files

	func testOnlyExportServiceFoldersAreDeletedForSharedExports() throws {
		// A made-up path with no symbolic links in it, so it reads the same once they're resolved.
		let temporary = URL(fileURLWithPath: "/RescrivaTest/tmp", isDirectory: true)
		let folder = UUID().uuidString
		let export = temporary.appendingPathComponent("Exports/\(folder)/Lab notes.pdf")
		XCTAssertEqual(NearbyShareFiles.exportFolder(of: export, temporaryDirectory: temporary)?.path,
					   temporary.appendingPathComponent("Exports/\(folder)").path)
		for other in ["Exports/Lab notes.pdf", "Exports/not-a-uuid/Lab notes.pdf", "Exports/\(folder)/inner/Lab notes.pdf",
					  "NearbyShare/\(folder)/Lab notes.pdf", "Exports/\(folder)/../\(UUID().uuidString)/../../Lab notes.pdf"] {
			XCTAssertNil(NearbyShareFiles.exportFolder(of: temporary.appendingPathComponent(other), temporaryDirectory: temporary), other)
		}
		XCTAssertNil(NearbyShareFiles.exportFolder(of: URL(fileURLWithPath: "/Users/someone/Exports/\(folder)/a.pdf"),
												   temporaryDirectory: temporary))
		let web = try XCTUnwrap(URL(string: "https://example.com/RescrivaTest/tmp/Exports/\(folder)/a.pdf"))
		XCTAssertNil(NearbyShareFiles.exportFolder(of: web, temporaryDirectory: temporary))
	}

	func testLeftoverSweepTakesEveryOtherSessionFolderAndNoFiles() throws {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("NearbyShareTests-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: base) }
		let root = base.appendingPathComponent("NearbyShare", isDirectory: true)
		for folder in ["old-run/doc1", "older-run", "current/doc2"] {
			try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
		}
		try Data("%PDF".utf8).write(to: root.appendingPathComponent("old-run/doc1/Lab notes.pdf"))
		try Data("stray".utf8).write(to: root.appendingPathComponent("stray.txt"))
		let chosen = NearbyShareFiles.leftoverFolders(in: root, keeping: ["current"])
		XCTAssertEqual(Set(chosen.map(\.lastPathComponent)), ["old-run", "older-run"], "this process's folder and plain files stay")
		XCTAssertEqual(Set(NearbyShareFiles.leftoverFolders(in: root, keeping: []).map(\.lastPathComponent)),
					   ["old-run", "older-run", "current"])
		XCTAssertEqual(NearbyShareFiles.leftoverFolders(in: base.appendingPathComponent("missing"), keeping: []), [])
		XCTAssertEqual(NearbyShareFiles.sessionsFolder.lastPathComponent, "NearbyShare")
	}

	// MARK: Names

	func testPagesWithTheSameNameAreNumberedInTheOrderTheyConnect() {
		var taken: Set<String> = []
		var labels: [String] = []
		for name in ["Chrome on Mac", "Chrome on Mac", "Safari on iPhone", "Chrome on Mac"] {
			let label = NearbyShareInput.deviceLabel(name, taken: taken)
			taken.insert(label)
			labels.append(label)
		}
		XCTAssertEqual(labels, ["Chrome on Mac", "Chrome on Mac 2", "Safari on iPhone", "Chrome on Mac 3"])
	}

	func testDeviceLabelsFillTheLowestFreeNumberAndNeverRepeat() {
		XCTAssertEqual(NearbyShareInput.deviceLabel("Chrome on Mac", taken: []), "Chrome on Mac")
		XCTAssertEqual(NearbyShareInput.deviceLabel("Chrome on Mac", taken: ["Chrome on Mac 2"]), "Chrome on Mac",
					   "the first one left, so its plain name is free again")
		XCTAssertEqual(NearbyShareInput.deviceLabel("Chrome on Mac", taken: ["Chrome on Mac", "Chrome on Mac 3"]), "Chrome on Mac 2")
		XCTAssertEqual(NearbyShareInput.deviceLabel("Chrome on Mac 2", taken: ["Chrome on Mac", "Chrome on Mac 2"]), "Chrome on Mac 2 2",
					   "a page whose own name ends in a number still gets a label nobody has")
		XCTAssertEqual(NearbyShareInput.deviceLabel("chrome on mac", taken: ["Chrome on Mac"]), "chrome on mac")
	}

	func testReceivedPicturesAreScaledDownAndUpright() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NearbyShareTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		let wide = UIGraphicsImageRenderer(size: CGSize(width: 5000, height: 200), format: format).image { context in
			UIColor.white.setFill()
			context.fill(CGRect(x: 0, y: 0, width: 5000, height: 200))
		}
		let wideURL = folder.appendingPathComponent("wide.png")
		try XCTUnwrap(wide.pngData()).write(to: wideURL)
		let scaled = try XCTUnwrap(NearbyShareFiles.image(at: wideURL, maxSide: 4096))
		XCTAssertEqual(scaled.size.width * scaled.scale, 4096, accuracy: 1)
		XCTAssertEqual(scaled.size.height * scaled.scale, 164, accuracy: 2)
		let small = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image { context in
			UIColor.black.setFill()
			context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
		}
		let smallURL = folder.appendingPathComponent("small.jpg")
		try XCTUnwrap(small.jpegData(compressionQuality: 0.8)).write(to: smallURL)
		let kept = try XCTUnwrap(NearbyShareFiles.image(at: smallURL, maxSide: 4096))
		XCTAssertEqual(kept.size.width * kept.scale, 300, accuracy: 1, "never scaled up")
		XCTAssertEqual(kept.size.height * kept.scale, 400, accuracy: 1)
		let junk = folder.appendingPathComponent("junk.png")
		try Data("not a picture".utf8).write(to: junk)
		XCTAssertNil(NearbyShareFiles.image(at: junk, maxSide: 4096))
		XCTAssertNil(NearbyShareFiles.image(at: folder.appendingPathComponent("missing.png"), maxSide: 4096))
		XCTAssertLessThan(NearbyShareConfig.maxIncomingImageBytes, NearbyShareConfig.maxIncomingBytes)
	}

	func testConfigurationDefaultsAndOverrides() throws {
		let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
		try XCTSkipIf(arguments["shareRelayURL"] != nil || arguments["shareSiteURL"] != nil, "launched with overrides")
		let defaults = UserDefaults.standard
		defer {
			defaults.removeObject(forKey: "shareRelayURL")
			defaults.removeObject(forKey: "shareSiteURL")
		}
		defaults.removeObject(forKey: "shareRelayURL")
		defaults.removeObject(forKey: "shareSiteURL")
		XCTAssertEqual(NearbyShareConfig.relayURL?.absoluteString, "wss://relay.rescriva.com/ws")
		XCTAssertEqual(NearbyShareConfig.siteURL.absoluteString, "https://share.rescriva.com/")
		defaults.set("ws://127.0.0.1:8787/ws", forKey: "shareRelayURL")
		XCTAssertEqual(NearbyShareConfig.relayURL?.absoluteString, "ws://127.0.0.1:8787/ws")
		defaults.set("off", forKey: "shareRelayURL")
		XCTAssertNil(NearbyShareConfig.relayURL)
		defaults.set("ftp://example.com/", forKey: "shareRelayURL")
		XCTAssertEqual(NearbyShareConfig.relayURL?.absoluteString, "wss://relay.rescriva.com/ws")
		defaults.set("http://127.0.0.1:8770/", forKey: "shareSiteURL")
		XCTAssertEqual(NearbyShareConfig.siteURL.absoluteString, "http://127.0.0.1:8770/")
		defaults.set("javascript:alert(1)", forKey: "shareSiteURL")
		XCTAssertEqual(NearbyShareConfig.siteURL.absoluteString, "https://share.rescriva.com/")
		XCTAssertEqual(NearbyShareConfig.chunkSize, 65_536)
		XCTAssertEqual(NearbyShareConfig.highWater, 1_048_576)
		XCTAssertEqual(NearbyShareConfig.codeDelay, .seconds(4))
		XCTAssertEqual(NearbyShareConfig.codeLifetime, .seconds(180))
	}

	// MARK: Helpers

	/// A libwebrtc-style answer with the built-in certificate.
	private var sampleAnswer: String {
		[
			"v=0", "o=- 4611731400430051336 2 IN IP4 127.0.0.1", "s=-", "t=0 0", "a=group:BUNDLE 0",
			"a=msid-semantic: WMS", "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "c=IN IP4 0.0.0.0",
			"a=ice-ufrag:Xy12", "a=ice-pwd:aBcDeFgHiJkLmNoPqRsTuVwX", "a=ice-options:trickle",
			"a=fingerprint:sha-256 \(ShareCertificate.fingerprint)", "a=setup:active", "a=mid:0",
			"a=sctp-port:5000", "a=max-message-size:262144", "",
		].joined(separator: "\r\n")
	}

	/// A pairing payload laid out as PROTOCOL.md §3 (and codes.js `pairingPayload`) does, with
	/// PROTOCOL.md's secret and the web tests' fingerprint. `candidates` are raw kind+address+port bytes.
	private func payload(version: UInt8 = 1, ufrag: String = "pEeG", pwd: String = "UVxTphq7VLoWl7IGtQnsIRyq", mid: String = "0",
						 candidates: [[UInt8]] = [[4, 192, 168, 1, 5, 0xFB, 0x9B]], count: Int? = nil) -> Data {
		var bytes: [UInt8] = [version] + Array(1...16)
		for text in [ufrag, pwd] {
			bytes.append(UInt8(text.utf8.count))
			bytes += Array(text.utf8)
		}
		bytes += Array(hexData("3a5172c43cb47ec5b5fef5740d3e98e54cc98e4bfa66c91aa9ec8e6ce8b9f1d9"))
		bytes.append(UInt8(mid.utf8.count))
		bytes += Array(mid.utf8)
		bytes.append(UInt8(count ?? candidates.count))
		for candidate in candidates { bytes += candidate }
		return Data(bytes)
	}

	private func hexData(_ text: String) -> Data {
		var bytes: [UInt8] = []
		var index = text.startIndex
		while index < text.endIndex {
			let next = text.index(index, offsetBy: 2)
			bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
			index = next
		}
		return Data(bytes)
	}

	private func asciiHex(_ text: String) -> String {
		text.utf8.map { String(format: "%02x", $0) }.joined()
	}

	private func inbound(_ text: String) -> ShareInbound? {
		ShareInbound(json: Data(text.utf8))
	}

	private func object(_ message: ShareOutbound) throws -> [String: Any] {
		try XCTUnwrap(JSONSerialization.jsonObject(with: message.json) as? [String: Any])
	}

	private func pemBody(_ pem: String, label: String) -> Data? {
		let body = pem.replacingOccurrences(of: "-----BEGIN \(label)-----", with: "")
			.replacingOccurrences(of: "-----END \(label)-----", with: "")
			.components(separatedBy: .whitespacesAndNewlines).joined()
		return Data(base64Encoded: body)
	}
}
