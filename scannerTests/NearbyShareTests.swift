//
//  NearbyShareTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Share Nearby's pure core against Docs/Rescriva-Share-Protocol.md: the shared test vectors (room id, ICE
//  credentials, hello proofs, check numbers, connection codes), the page's pairing payload byte for
//  byte as rescriva-share's tests/index.html builds it, what a bad payload looks like and where it
//  points, the SDP the app rebuilds and edits, which local address goes in a connection code, the
//  data channel's messages both ways, relay signals and messages, PINs and their lockout, the
//  built-in certificate, which leftover folders get swept, the numbers that tell pages with the
//  same name apart, where each kind of upload is saved and the free names received files take,
//  and (NearbyShareSessionTests) the session driven over stub connections.
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
	/// The page's fingerprint in rescriva-share's tests/index.html, as the page's SDP wrote it.
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

	func testCheckNumbersMatchTheVectorsAndOrderMatters() {
		XCTAssertEqual(ShareCodes.checkNumber(offerFingerprint: fingerprintAA, answerFingerprint: fingerprintBB), "424561948")
		XCTAssertEqual(ShareCodes.checkNumber(offerFingerprint: fingerprintBB, answerFingerprint: fingerprintAA), "576993692")
		XCTAssertEqual(ShareCodes.displayCheckNumber(ShareCodes.checkNumber(offerFingerprint: fingerprintAA, answerFingerprint: fingerprintBB)), "424 561 948")
		let number = ShareCodes.checkNumber(offerFingerprint: pageFingerprint.uppercased(), answerFingerprint: ShareCertificate.fingerprint)
		XCTAssertEqual(number.count, 9)
		XCTAssertTrue(number.utf8.allSatisfy { (48...57).contains($0) }, number)
	}

	func testCheckNumbersAreShownInThreeGroups() {
		XCTAssertEqual(ShareCodes.displayCheckNumber("000000001"), "000 000 001")
		XCTAssertEqual(ShareCodes.displayCheckNumber("12"), "12", "anything else is left alone")
		XCTAssertEqual(ShareCodes.displayPIN("424561948"), "424561948", "a check number isn't a PIN")
	}

	func testProofRuleNeedsASecretAndBothFingerprints() {
		let offer = fingerprintAA
		let answer = fingerprintBB
		XCTAssertTrue(NearbyShareLink.proves(nil, secret: nil, offerFingerprint: offer, answerFingerprint: answer))
		XCTAssertTrue(NearbyShareLink.proves("anything", secret: nil, offerFingerprint: nil, answerFingerprint: nil))
		let right = ShareCodes.proof(secret: secret, role: "web", offerFingerprint: offer, answerFingerprint: answer)
		XCTAssertTrue(NearbyShareLink.proves(right, secret: secret, offerFingerprint: offer, answerFingerprint: answer))
		XCTAssertFalse(NearbyShareLink.proves(nil, secret: secret, offerFingerprint: offer, answerFingerprint: answer))
		XCTAssertFalse(NearbyShareLink.proves(right, secret: secret, offerFingerprint: nil, answerFingerprint: answer), "no fingerprint yet")
		XCTAssertFalse(NearbyShareLink.proves(right, secret: secret, offerFingerprint: answer, answerFingerprint: offer), "swapped")
		let appProof = ShareCodes.proof(secret: secret, role: "app", offerFingerprint: offer, answerFingerprint: answer)
		XCTAssertFalse(NearbyShareLink.proves(appProof, secret: secret, offerFingerprint: offer, answerFingerprint: answer), "the app's own role")
		XCTAssertFalse(NearbyShareLink.proves(right + "A", secret: secret, offerFingerprint: offer, answerFingerprint: answer))
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

	/// rescriva-share's tests/index.html's "payload hex": one mDNS, one IPv4 and one IPv6 candidate.
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

	func testPairingOfferKnowsWhetherItPointsAtThisNetwork() throws {
		func offer(_ candidates: [[UInt8]]) throws -> SharePairingOffer {
			try XCTUnwrap(SharePairingOffer(payload: payload(candidates: candidates)))
		}
		let privateIPv4: [UInt8] = [4, 192, 168, 1, 5, 0xFB, 0x9B]
		let publicIPv4: [UInt8] = [4, 8, 8, 8, 8, 0x01, 0xBB]
		let linkLocalIPv6: [UInt8] = [6] + [0xFE, 0x80] + Array(repeating: 0, count: 13) + [1] + [0xFB, 0x9A]
		let uniqueLocalIPv6: [UInt8] = [6] + [0xFD, 0x12] + Array(repeating: 0, count: 13) + [1] + [0xFB, 0x9A]
		let publicIPv6: [UInt8] = [6] + [0x20, 0x01, 0x0D, 0xB8] + Array(repeating: 0, count: 11) + [1] + [0xFB, 0x9A]
		let mapped: [UInt8] = [6] + Array(repeating: 0, count: 10) + [0xFF, 0xFF, 10, 0, 0, 1] + [0xFB, 0x9A]
		let mdns: [UInt8] = [109] + Array(hexData("40dae37193f3444588ecb805a2838109")) + [0xD2, 0x95]
		XCTAssertTrue(try offer([privateIPv4]).isWithinPrivateNetwork)
		XCTAssertTrue(try offer([linkLocalIPv6]).isWithinPrivateNetwork)
		XCTAssertTrue(try offer([uniqueLocalIPv6]).isWithinPrivateNetwork)
		XCTAssertTrue(try offer([mapped]).isWithinPrivateNetwork, "IPv4-mapped private address")
		XCTAssertTrue(try offer([mdns]).isWithinPrivateNetwork)
		XCTAssertTrue(try offer([privateIPv4, linkLocalIPv6, mdns]).isWithinPrivateNetwork)
		XCTAssertFalse(try offer([publicIPv4, privateIPv4]).isWithinPrivateNetwork, "a decoy local candidate beside a public one doesn't pass")
		XCTAssertFalse(try offer([privateIPv4, publicIPv6]).isWithinPrivateNetwork, "in either order")
		XCTAssertFalse(try offer([publicIPv4]).isWithinPrivateNetwork)
		XCTAssertFalse(try offer([publicIPv6]).isWithinPrivateNetwork)
		XCTAssertFalse(try offer([publicIPv4, publicIPv6]).isWithinPrivateNetwork)
		XCTAssertFalse(try offer([]).isWithinPrivateNetwork, "nowhere to reach")
		XCTAssertTrue(try XCTUnwrap(SharePairingOffer(payload: webTestsPayload)).isWithinPrivateNetwork)
		XCTAssertEqual(try offer([publicIPv4, privateIPv4, mdns]).localCandidates.map(\.host),
					   ["192.168.1.5", "40dae371-93f3-4445-88ec-b805a2838109.local"], "the local ones, in order")
		XCTAssertEqual(try offer([publicIPv4]).localCandidates, [])
	}

	func testLocalOnlyOfferLeavesPublicCandidatesOut() throws {
		let privateIPv4: [UInt8] = [4, 192, 168, 1, 5, 0xFB, 0x9B]
		let publicIPv4: [UInt8] = [4, 203, 0, 113, 9, 0x01, 0xBB]
		let mdns: [UInt8] = [109] + Array(hexData("40dae37193f3444588ecb805a2838109")) + [0xD2, 0x95]
		let pairing = try XCTUnwrap(SharePairingOffer(payload: payload(candidates: [privateIPv4, publicIPv4, mdns])))
		func hosts(localOnly: Bool) -> [String] {
			ShareSDP.offer(for: pairing, localOnly: localOnly).components(separatedBy: "\r\n")
				.filter { $0.hasPrefix("a=candidate:") }.compactMap { ShareSDP.hostCandidate($0)?.address }
		}
		XCTAssertEqual(hosts(localOnly: false), ["192.168.1.5", "203.0.113.9", "40dae371-93f3-4445-88ec-b805a2838109.local"])
		XCTAssertEqual(hosts(localOnly: true), ["192.168.1.5", "40dae371-93f3-4445-88ec-b805a2838109.local"])
		let lines = ShareSDP.offer(for: pairing, localOnly: true).components(separatedBy: "\r\n").filter { $0.hasPrefix("a=candidate:") }
		XCTAssertEqual(lines.count, 2)
		XCTAssertTrue(lines[1].hasPrefix("a=candidate:2 1 udp "), "numbered without a gap: \(lines[1])")
		XCTAssertTrue(lines[1].hasSuffix(" 40dae371-93f3-4445-88ec-b805a2838109.local 53909 typ host"), lines[1])
	}

	func testLocalNetworkHostsAreRFC1918LinkLocalUniqueLocalOrMDNS() {
		for host in ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.0.1", "169.254.1.1",
					 "fe80::1", "FE80::1", "febf::1", "fc00::1", "fd00::1234", "fdff::1", "::ffff:192.168.1.5", "::ffff:169.254.0.1",
					 "40dae371-93f3-4445-88ec-b805a2838109.local", "printer.local"] {
			XCTAssertTrue(ShareNetwork.isLocalNetworkHost(host), host)
		}
		for host in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "169.255.0.1", "1.1.1.1", "0.0.0.0", "127.0.0.1",
					 "2001:db8::1", "fec0::1", "fbff::1", "fe00::1", "::1", "::", "::ffff:8.8.8.8", "example.com", ".local", "local", "",
					 "192.168.1.5 typ host", "fe80::1%en0"] {
			XCTAssertFalse(ShareNetwork.isLocalNetworkHost(host), host)
		}
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

	func testNamesLoseBidiOverridesAndIsolates() {
		let controls = (0x202A...0x202E).map { $0 } + (0x2066...0x2069).map { $0 }
		for value in controls {
			let scalar = String(UnicodeScalar(UInt32(value)).map { Character($0) } ?? "?")
			XCTAssertNotEqual(scalar, "?", String(value, radix: 16))
			XCTAssertEqual(ShareJSON.cleanName("Lea\(scalar)se.pdf", limit: 64), "Lease.pdf", String(value, radix: 16))
			XCTAssertEqual(inbound(#"{"t":"hello","name":"Chrome\#(scalar) on Mac","device":"computer"}"#),
						   .hello(name: "Chrome on Mac", device: "computer", proof: nil), String(value, radix: 16))
			XCTAssertEqual(inbound(#"{"t":"send","xfer":"u1","name":"\#(scalar)fdp.esaeL","size":1,"type":"application/pdf"}"#),
						   .send(xfer: "u1", name: "fdp.esaeL", size: 1, type: "application/pdf"), String(value, radix: 16))
		}
		XCTAssertEqual(ShareJSON.cleanName("\u{202E}\u{2066}\u{2069}", limit: 64), "")
		XCTAssertEqual(ShareJSON.cleanName("  Chrome\u{0007} on\u{200B} Mac\n", limit: 64), "Chrome on Mac", "controls and format characters go too")
		XCTAssertEqual(ShareJSON.cleanName("Émilie’s MacBook", limit: 64), "Émilie’s MacBook", "ordinary text stays")
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

	// MARK: Limits

	func testLimitsMatchTheRelayAndThePage() {
		XCTAssertEqual(ShareLimits.maxPeers, 32)
		XCTAssertEqual(ShareLimits.maxMessageBytes, 64 * 1024)
		XCTAssertLessThan(ShareLimits.maxSDPBytes, ShareLimits.maxMessageBytes, "an SDP has to fit in a message with its wrapping")
		XCTAssertEqual(ShareLimits.maxCandidateBytes, 1024)
		XCTAssertEqual(ShareLimits.maxDocuments, 200)
		XCTAssertEqual(ShareLimits.maxDeviceName, 64)
		XCTAssertEqual(ShareLimits.stallSeconds, 30)
		XCTAssertEqual(ShareLimits.relayDevices, ["iphone", "ipad", "mac", "phone", "tablet", "computer"])
		XCTAssertTrue(ShareLimits.pageDevices.isDisjoint(with: ShareLimits.appDevices))
	}

	// MARK: Input checks

	func testPINsAreExactlySixASCIIDigits() {
		XCTAssertTrue(NearbyShareInput.isPIN("482913"))
		XCTAssertTrue(NearbyShareInput.isPIN("000000"))
		for text in ["48291", "4829133", "48291a", "482 913", "４８２９１３", "", "48291\n"] {
			XCTAssertFalse(NearbyShareInput.isPIN(text), text)
		}
	}

	func testSecretComparisonIsExact() {
		XCTAssertTrue(NearbyShareInput.same("482913", "482913"))
		XCTAssertTrue(NearbyShareInput.same("", ""))
		XCTAssertFalse(NearbyShareInput.same("482913", "482914"))
		XCTAssertFalse(NearbyShareInput.same("482913", "48291"))
		XCTAssertFalse(NearbyShareInput.same("é", "e\u{301}"), "bytes, not canonical equivalence")
	}

	func testUploadTypesAreReadPlainlyAndAnythingOddIsJustAFile() {
		XCTAssertEqual(NearbyShareInput.uploadType("application/pdf"), "application/pdf")
		XCTAssertEqual(NearbyShareInput.uploadType("image/PNG; charset=binary"), "image/png", "lower case, no parameters")
		XCTAssertEqual(NearbyShareInput.uploadType(" video/mp4 "), "video/mp4")
		XCTAssertEqual(NearbyShareInput.uploadType("application/zip"), "application/zip")
		XCTAssertEqual(NearbyShareInput.uploadType("image/svg+xml"), "image/svg+xml")
		for type in ["", "image/", "/png", "image", "a/b/c", "text/html\n", "imäge/png", "image/" + String(repeating: "a", count: 130)] {
			XCTAssertEqual(NearbyShareInput.uploadType(type), NearbyShareInput.unknownType, type)
		}
	}

	func testUploadsGoToPDFFilesPhotosOrFilesByKind() {
		XCTAssertEqual(NearbyShareInput.uploadKind(type: "application/pdf"), .pdf)
		for type in ["image/jpeg", "image/heic", "image/png", "image/gif", "image/webp"] {
			XCTAssertEqual(NearbyShareInput.uploadKind(type: type), .picture, type)
		}
		for type in ["video/mp4", "video/quicktime"] {
			XCTAssertEqual(NearbyShareInput.uploadKind(type: type), .video, type)
		}
		for type in ["image/svg+xml", "image/vnd.adobe.photoshop", "video/webm", "application/zip", "application/pdf2",
					 NearbyShareInput.unknownType] {
			XCTAssertEqual(NearbyShareInput.uploadKind(type: type), .file, "\(type): Photos wouldn't take it")
		}
	}

	func testUnpairedPagesTakeOnlyTheirTypesAndSizes() {
		XCTAssertTrue(NearbyShareInput.unpairedPageTakes(type: "application/pdf", size: ShareLimits.unpairedPageMaxPDFBytes))
		XCTAssertFalse(NearbyShareInput.unpairedPageTakes(type: "application/pdf", size: ShareLimits.unpairedPageMaxPDFBytes + 1))
		XCTAssertTrue(NearbyShareInput.unpairedPageTakes(type: "image/jpeg", size: 5_000_000))
		XCTAssertTrue(NearbyShareInput.unpairedPageTakes(type: "video/quicktime", size: ShareLimits.unpairedPageMaxBytes))
		XCTAssertFalse(NearbyShareInput.unpairedPageTakes(type: "video/quicktime", size: ShareLimits.unpairedPageMaxBytes + 1))
		XCTAssertTrue(NearbyShareInput.unpairedPageTakes(type: "text/markdown", size: 10))
		for type in ["application/zip", "application/octet-stream", "image/svg+xml", "text/html", ""] {
			XCTAssertFalse(NearbyShareInput.unpairedPageTakes(type: type, size: 10), type)
		}
	}

	func testFileNamesLosePathsControlsAndLeadingDots() {
		XCTAssertEqual(NearbyShareInput.fileName("Lease.pdf", fallback: "x"), "Lease.pdf")
		XCTAssertEqual(NearbyShareInput.fileName("../../etc/passwd", fallback: "x"), "etc passwd")
		XCTAssertEqual(NearbyShareInput.fileName("C:\\Users\\me\\a.pdf", fallback: "x"), "C Users me a.pdf")
		XCTAssertEqual(NearbyShareInput.fileName(".hidden", fallback: "x"), "hidden")
		XCTAssertEqual(NearbyShareInput.fileName("  a\u{0000}b\tc.pdf  ", fallback: "x"), "a b c.pdf")
		XCTAssertEqual(NearbyShareInput.fileName("a  <b>|c?*\"d.pdf", fallback: "x"), "a b c d.pdf")
		XCTAssertEqual(NearbyShareInput.fileName("", fallback: "Received file"), "Received file")
		XCTAssertEqual(NearbyShareInput.fileName(" ... ", fallback: "Received file"), "Received file")
		let long = String(repeating: "é", count: 150) + ".pdf"
		let clipped = NearbyShareInput.fileName(long, fallback: "x")
		XCTAssertLessThanOrEqual(clipped.utf8.count, NearbyShareInput.maxFileNameBytes)
		XCTAssertTrue(clipped.hasSuffix(".pdf"), "a short extension is kept")
		let longExtension = String(repeating: "a", count: 200) + "." + String(repeating: "b", count: 30)
		let clippedExtension = NearbyShareInput.fileName(longExtension, fallback: "x")
		XCTAssertLessThanOrEqual(clippedExtension.utf8.count, NearbyShareInput.maxFileNameBytes)
		XCTAssertFalse(clippedExtension.contains("."), "a long extension is just cut with the rest")
		XCTAssertEqual(NearbyShareInput.fileName(String(repeating: "x", count: 2000), fallback: "x").utf8.count, NearbyShareInput.maxFileNameBytes)
	}

	func testTheOneSanitizerNamesSharedFilesAndExports() {
		// Share Nearby's names come from String.safeFileName, the sanitizer every export uses too.
		XCTAssertEqual("Q3: plan / budget?".safeFileName(), "Q3 plan budget")
		XCTAssertEqual("  ..Lease.pdf".safeFileName(), "Lease.pdf")
		XCTAssertEqual(" ... ".safeFileName(), "", "nothing left means empty, so the caller picks the fallback")
		XCTAssertEqual("\u{0007}\n\t".safeFileName(), "")
		XCTAssertEqual(NearbyShareInput.fileName("Lease.pdf", fallback: "x"), "Lease.pdf".safeFileName())
		XCTAssertEqual(NearbyShareInput.fileName(" ", fallback: "../Received file"), "Received file", "the fallback is made safe too")
		XCTAssertEqual(NearbyShareInput.maxFileNameBytes, String.maxFileNameBytes)

		let flags = String(repeating: "🇨🇦", count: 80) + ".pdf"
		let clipped = flags.safeFileName(maxBytes: 40)
		XCTAssertEqual(clipped, String(repeating: "🇨🇦", count: 4) + ".pdf", "cut at a character boundary, extension kept")
		XCTAssertLessThanOrEqual(clipped.utf8.count, 40)
		XCTAssertEqual(String(repeating: "x", count: 300).safeFileName(maxBytes: 10), String(repeating: "x", count: 10))
	}

	func testPDFTitlesComeFromTheFileNameWithoutItsExtension() {
		XCTAssertEqual(NearbyShareInput.title(fromFileName: "Lease agreement.pdf"), "Lease agreement")
		XCTAssertEqual(NearbyShareInput.title(fromFileName: "Lease"), "Lease")
		XCTAssertEqual(NearbyShareInput.title(fromFileName: " notes .PDF"), "notes")
		XCTAssertEqual(NearbyShareInput.title(fromFileName: "   "), "Received PDF")
		XCTAssertEqual(NearbyShareInput.title(fromFileName: ""), "Received PDF")
	}

	// MARK: PIN lockout (PROTOCOL.md §1.3)

	private let pageA = UUID()
	private let pageB = UUID()
	private let pageC = UUID()
	private let pageD = UUID()

	func testFourWrongTriesFromOnePageOnlyCountDown() {
		var lock = NearbySharePINLock()
		let now = Date(timeIntervalSinceReferenceDate: 1000)
		for expected in [4, 3, 2, 1] {
			XCTAssertEqual(lock.recordWrong(from: pageA, at: now), .init(left: expected, retryIn: nil, replacesPIN: false))
			XCTAssertNil(lock.secondsLeft(for: pageA, at: now))
		}
		XCTAssertEqual(lock.triesLeft(for: pageA), 1)
		XCTAssertEqual(lock.triesLeft(for: pageB), 5)
		XCTAssertEqual(lock.wrongTries, 4)
		XCTAssertEqual(lock.lockouts, 0)
		XCTAssertNil(lock.lockedUntil)
	}

	func testFifthWrongTryRefusesThatPageAloneForThirtySeconds() {
		var lock = NearbySharePINLock()
		let now = Date(timeIntervalSinceReferenceDate: 1000)
		for _ in 0..<4 { _ = lock.recordWrong(from: pageA, at: now) }
		XCTAssertEqual(lock.recordWrong(from: pageA, at: now), .init(left: 0, retryIn: 30, replacesPIN: false))
		XCTAssertEqual(lock.secondsLeft(for: pageA, at: now), 30)
		XCTAssertEqual(lock.secondsLeft(for: pageA, at: now.addingTimeInterval(29.2)), 1)
		XCTAssertNil(lock.secondsLeft(for: pageA, at: now.addingTimeInterval(30)))
		XCTAssertNil(lock.secondsLeft(for: pageB, at: now), "another page isn't refused")
		XCTAssertEqual(lock.recordWrong(from: pageB, at: now), .init(left: 4, retryIn: nil, replacesPIN: false))
		XCTAssertEqual(lock.lockedLinks, [pageA])
		XCTAssertNil(lock.lockedUntil, "nobody else waits")
		XCTAssertEqual(lock.lockouts, 0)
	}

	func testATryWhileRefusedOnlyRepeatsTheRefusal() {
		var lock = NearbySharePINLock()
		let now = Date(timeIntervalSinceReferenceDate: 1000)
		for _ in 0..<5 { _ = lock.recordWrong(from: pageA, at: now) }
		let during = now.addingTimeInterval(10)
		XCTAssertEqual(lock.recordWrong(from: pageA, at: during), .init(left: 0, retryIn: 20, replacesPIN: false))
		XCTAssertEqual(lock.wrongTries, 5, "a refused try isn't counted")
		XCTAssertEqual(lock.secondsLeft(for: pageA, at: during), 20)
	}

	func testARefusedPageStartsAFreshCountAfterItsCooldown() {
		var lock = NearbySharePINLock()
		let now = Date(timeIntervalSinceReferenceDate: 1000)
		for _ in 0..<5 { _ = lock.recordWrong(from: pageA, at: now) }
		let later = now.addingTimeInterval(31)
		XCTAssertEqual(lock.recordWrong(from: pageA, at: later), .init(left: 4, retryIn: nil, replacesPIN: false))
		XCTAssertEqual(lock.triesLeft(for: pageA), 4)
		XCTAssertEqual(lock.wrongTries, 6, "but everyone's total keeps growing")
		XCTAssertEqual(lock.lockedLinks, [pageA], "and it still counts as a page that was refused")
	}

	func testFifteenWrongTriesAcrossPagesReplaceThePINAndRefuseEveryone() {
		var lock = NearbySharePINLock()
		let now = Date(timeIntervalSinceReferenceDate: 1000)
		for _ in 0..<5 { _ = lock.recordWrong(from: pageA, at: now) }
		for _ in 0..<5 { _ = lock.recordWrong(from: pageA, at: now.addingTimeInterval(31)) }
		for _ in 0..<4 { _ = lock.recordWrong(from: pageA, at: now.addingTimeInterval(62)) }
		XCTAssertEqual(lock.wrongTries, 14)
		XCTAssertEqual(lock.lockedLinks.count, 1, "one page alone never trips the three-page rule")
		let last = now.addingTimeInterval(62)
		XCTAssertEqual(lock.recordWrong(from: pageA, at: last), .init(left: 0, retryIn: 30, replacesPIN: true))
		XCTAssertEqual(lock.lockouts, 1)
		XCTAssertEqual(lock.lockedUntil, last.addingTimeInterval(30))
		XCTAssertEqual(lock.secondsLeft(for: pageA, at: last), 30)
		XCTAssertEqual(lock.secondsLeft(for: pageD, at: last), 30, "a page that never tried waits too")
		XCTAssertEqual(lock.wrongTries, 0, "the new PIN starts clean")
		XCTAssertEqual(lock.lockedLinks, [])
		XCTAssertEqual(lock.triesLeft(for: pageA), 5)
		XCTAssertNil(lock.secondsLeft(for: pageD, at: last.addingTimeInterval(30)))
	}

	func testThreeRefusedPagesReplaceThePIN() {
		var lock = NearbySharePINLock()
		let now = Date(timeIntervalSinceReferenceDate: 1000)
		for page in [pageA, pageB] {
			for _ in 0..<5 { _ = lock.recordWrong(from: page, at: now) }
		}
		for _ in 0..<4 { _ = lock.recordWrong(from: pageC, at: now) }
		XCTAssertEqual(lock.wrongTries, 14)
		XCTAssertEqual(lock.recordWrong(from: pageC, at: now), .init(left: 0, retryIn: 30, replacesPIN: true))
		XCTAssertEqual(lock.lockouts, 1)
		XCTAssertEqual(lock.secondsLeft(for: pageD, at: now), 30)
	}

	func testAPageRefusedTwiceCountsAsOnePage() {
		var lock = NearbySharePINLock()
		var now = Date(timeIntervalSinceReferenceDate: 1000)
		for _ in 0..<5 { _ = lock.recordWrong(from: pageA, at: now) }
		now = now.addingTimeInterval(31)
		for _ in 0..<4 { _ = lock.recordWrong(from: pageA, at: now) }
		XCTAssertEqual(lock.recordWrong(from: pageA, at: now), .init(left: 0, retryIn: 30, replacesPIN: false), "refused a second time")
		XCTAssertEqual(lock.wrongTries, 10)
		XCTAssertEqual(lock.lockedLinks, [pageA])
		XCTAssertEqual(lock.lockouts, 0, "one page can't reach the three-page rule on its own")
		for _ in 0..<4 { _ = lock.recordWrong(from: pageB, at: now) }
		XCTAssertEqual(lock.lockouts, 0)
		XCTAssertEqual(lock.recordWrong(from: pageB, at: now), .init(left: 0, retryIn: 30, replacesPIN: true), "the fifteenth try does")
		XCTAssertEqual(lock.lockouts, 1)
	}

	func testGlobalCooldownDoublesUpToThirtyTwoMinutes() {
		var lock = NearbySharePINLock()
		var now = Date(timeIntervalSinceReferenceDate: 1000)
		var waits: [Int] = []
		for _ in 0..<9 {
			var outcome = NearbySharePINLock.Outcome(left: 5, retryIn: nil, replacesPIN: false)
			for _ in 0..<15 where !outcome.replacesPIN {
				if let wait = lock.secondsLeft(for: pageA, at: now) { now = now.addingTimeInterval(TimeInterval(wait)) }
				outcome = lock.recordWrong(from: pageA, at: now)
			}
			XCTAssertTrue(outcome.replacesPIN)
			waits.append(outcome.retryIn ?? -1)
			now = now.addingTimeInterval(TimeInterval(outcome.retryIn ?? 0))
		}
		XCTAssertEqual(waits, [30, 60, 120, 240, 480, 960, 1920, 1920, 1920])
		XCTAssertEqual(lock.lockouts, 9)
		XCTAssertEqual(NearbySharePINLock.maxDoublings, 6)
	}

	func testNothingIsRefusedBeforeAnyWrongTry() {
		let lock = NearbySharePINLock()
		XCTAssertNil(lock.secondsLeft(for: pageA, at: .now))
		XCTAssertEqual(lock.triesLeft(for: pageA), NearbySharePINLock.triesPerLink)
		XCTAssertEqual(lock, NearbySharePINLock())
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
		XCTAssertEqual(NearbyShareFiles.receivedFolderRoot.lastPathComponent, "NearbyShareReceived")
		XCTAssertEqual(NearbyShareFiles.receivedFolderRoot.deletingLastPathComponent().path, NearbyShareFiles.sessionsFolder.deletingLastPathComponent().path,
					   "side by side in tmp, so the same sweep reaches both")
	}

	func testChunkFilesWriteInOrderAndReadBack() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NearbyShareTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let url = folder.appendingPathComponent("chunks.bin")
		XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
		let writer = try NearbyShareChunkFile(writingTo: url)
		let chunks = (0..<5).map { Data(repeating: UInt8($0), count: 1000) }
		for chunk in chunks { XCTAssertTrue(writer.append(chunk)) }
		XCTAssertFalse(writer.hasFailed)
		XCTAssertTrue(writer.finish(), "waits for every write")
		XCTAssertFalse(writer.finish(), "closed once")
		XCTAssertEqual(NearbyShareFiles.size(of: url), 5000)
		let reader = try NearbyShareChunkFile(readingFrom: url)
		var read = Data()
		for _ in 0..<10 {
			guard let data = await reader.read(upTo: 1500) else { break }
			read.append(data)
		}
		XCTAssertEqual(read, chunks.reduce(Data(), +))
		let atEnd = await reader.read(upTo: 10)
		XCTAssertNil(atEnd, "at the end")
		let nothing = await reader.read(upTo: 0)
		XCTAssertNil(nothing)
		reader.discard()
		let afterClosing = await reader.read(upTo: 10)
		XCTAssertNil(afterClosing, "after closing")
		let discarded = try NearbyShareChunkFile(readingFrom: url)
		discarded.discard(deleting: folder.appendingPathComponent("gone", isDirectory: true))
		XCTAssertThrowsError(try NearbyShareChunkFile(readingFrom: folder.appendingPathComponent("missing.bin")))
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

	func testReceivedFilesTakeAFreeNameAndReplaceNothing() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NearbyShareTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		XCTAssertEqual(NearbyShareFiles.numberedName("Notes.zip", 1), "Notes.zip")
		XCTAssertEqual(NearbyShareFiles.numberedName("Notes.zip", 2), "Notes 2.zip")
		XCTAssertEqual(NearbyShareFiles.numberedName("README", 3), "README 3")
		let inbox = folder.appendingPathComponent("Received", isDirectory: true)
		var saved: [URL] = []
		for content in ["one", "two", "three"] {
			let source = folder.appendingPathComponent("incoming-\(content)")
			try Data(content.utf8).write(to: source)
			saved.append(try XCTUnwrap(NearbyShareFiles.move(source, into: inbox, named: "Notes.zip")))
			XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "moved, not copied")
		}
		XCTAssertEqual(saved.map(\.lastPathComponent), ["Notes.zip", "Notes 2.zip", "Notes 3.zip"])
		XCTAssertEqual(try String(contentsOf: saved[0], encoding: .utf8), "one", "the first is never replaced")
		XCTAssertNil(NearbyShareFiles.move(folder.appendingPathComponent("missing"), into: inbox, named: "x"))
		#if !targetEnvironment(macCatalyst)
		XCTAssertEqual(NearbyShareFiles.receivedFilesFolder, URL.documentsDirectory.appendingPathComponent("Received", isDirectory: true),
					   "a folder of its own: the launch sweep deletes Quick Look-like names at the top of Documents")
		#endif
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

/// The session driven over stub connections (`NearbyShareSession.connectStubForTesting`), with no
/// relay (the `shareRelayURL` default is "off" for each test), no WebRTC and a stand-in for Photos:
/// hellos and proofs, the check number, PINs and their per-page lockout, a download chunk by
/// chunk, uploads that are cancelled, stall or end short, uploads saved to Files, Photos or PDF
/// Files, the documents cap, closing and stopping; and what the relay sends, read by
/// `ShareRelay.parse`.
@MainActor
final class NearbyShareSessionTests: XCTestCase {
	private let fingerprintAA = Array(repeating: "AA", count: 32).joined(separator: ":")
	private let fingerprintBB = Array(repeating: "BB", count: 32).joined(separator: ":")
	private var folder = URL(fileURLWithPath: "/")
	private var relayOverride: String?
	/// The library the last session made shares from and saves PDFs to.
	private var library: PDFLibrary?
	private var photos = PhotosStub()

	/// Where the sessions save received files that don't go to PDF Files or Photos.
	private var inbox: URL { folder.appendingPathComponent("Received", isDirectory: true) }

	override func setUp() async throws {
		folder = FileManager.default.temporaryDirectory.appendingPathComponent("NearbyShareSessionTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		relayOverride = UserDefaults.standard.string(forKey: "shareRelayURL")
		UserDefaults.standard.set("off", forKey: "shareRelayURL")
		photos = PhotosStub()
	}

	override func tearDown() async throws {
		if let relayOverride {
			UserDefaults.standard.set(relayOverride, forKey: "shareRelayURL")
		} else {
			UserDefaults.standard.removeObject(forKey: "shareRelayURL")
		}
		try? FileManager.default.removeItem(at: folder)
		library = nil
	}

	// MARK: Documents

	func testDocumentsAreCappedAndNotRepeated() async throws {
		var items: [NearbyShareItem] = []
		for index in 0..<(ShareLimits.maxDocuments + 5) {
			items.append(try makeFile("doc\(index).pdf", size: 10))
		}
		items.append(items[0])
		let session = makeSession(items: items)
		XCTAssertFalse(session.isRunning)
		XCTAssertTrue(session.documents.isEmpty, "nothing until start")
		session.start()
		XCTAssertTrue(session.isRunning)
		XCTAssertEqual(session.documents.count, ShareLimits.maxDocuments)
		XCTAssertEqual(Set(session.documents.map(\.pin)).count, ShareLimits.maxDocuments, "every PIN is different")
		XCTAssertEqual(Set(session.documents.map(\.id)).count, ShareLimits.maxDocuments)
		XCTAssertNotNil(session.openLink)
		XCTAssertEqual(session.relayState, .off)
		session.add([try makeFile("extra.pdf", size: 10)])
		XCTAssertEqual(session.documents.count, ShareLimits.maxDocuments, "the cap holds for add too")
		session.stop()
		XCTAssertFalse(session.isRunning)
		XCTAssertTrue(session.documents.isEmpty)
		XCTAssertNil(session.openLink)
		session.stop()
	}

	func testRemovingADocumentTellsPages() async throws {
		let session = try await startedSession(with: [try makeFile("Lease.pdf"), try makeFile("Notes.pdf")])
		let link = try connectedPage(session)
		let first = try XCTUnwrap(session.documents.first)
		session.remove(first)
		XCTAssertEqual(session.documents.map(\.name), ["Notes.pdf"])
		guard case .docs(let list)? = messages(link).last else { return XCTFail("no docs after a removal") }
		XCTAssertEqual(list.map(\.name), ["Notes.pdf"])
		deliver(["t": "get", "id": first.id], to: link)
		XCTAssertEqual(messages(link).last, .denied(id: first.id, reason: "gone", retryIn: nil, left: nil))
		session.stop()
	}

	// MARK: Hello, trust and the check number

	func testPageWithNoSecretSeesTheListAndItsCheckNumber() async throws {
		let session = try await startedSession(with: [try makeFile("Lease.pdf")])
		let document = try XCTUnwrap(session.documents.first)
		let link = try connectedPage(session)
		guard case .hello(let name, let device, let sessionID, let proof)? = messages(link).first else { return XCTFail("the app says hello first") }
		XCTAssertFalse(name.isEmpty)
		XCTAssertTrue(ShareLimits.appDevices.contains(device), device)
		XCTAssertEqual(sessionID.count, 11)
		XCTAssertNil(proof, "no secret, nothing to prove")
		XCTAssertEqual(session.devices.map(\.name), ["Chrome on Mac"])
		XCTAssertEqual(session.devices.first?.kind, "computer")
		XCTAssertEqual(session.devices.first?.trusted, false)
		XCTAssertEqual(session.devices.first?.checkNumber, "424561948", "the vector for AA…/BB…")
		XCTAssertEqual(session.untrustedPageCount, 1)
		XCTAssertEqual(messages(link).last, .docs([ShareDocSummary(id: document.id, name: "Lease.pdf", size: 10_000, type: "application/pdf", unlocked: false)]))
		XCTAssertTrue(link.ready)
		XCTAssertFalse(link.trusted)
		XCTAssertFalse(link.canDownload(document.id))
		session.stop()
	}

	func testPageWithASecretMustProveItAndShowsNoCheckNumber() async throws {
		let session = try await startedSession(with: [try makeFile("Lease.pdf")])
		let document = try XCTUnwrap(session.documents.first)
		let secret = ShareCodes.newSecret()
		let faker = try XCTUnwrap(session.connectStubForTesting(secret: secret, origin: .relay(room: "room", peerID: "p9"),
																offerFingerprint: fingerprintAA, answerFingerprint: fingerprintBB))
		faker.peer.deliverForTesting(.open)
		guard case .hello(_, _, _, let proof)? = messages(faker).first else { return XCTFail("the app says hello first") }
		XCTAssertEqual(proof, ShareCodes.proof(secret: secret, role: "app", offerFingerprint: fingerprintAA, answerFingerprint: fingerprintBB))
		deliver(["t": "hello", "v": 1, "role": "web", "name": "Chrome on Mac", "device": "computer"], to: faker)
		XCTAssertEqual(messages(faker).last, .bye, "no proof: goodbye")
		XCTAssertFalse(session.holdsForTesting(faker))
		XCTAssertTrue(session.devices.isEmpty)
		deliver(["t": "get", "id": document.id], to: faker)
		XCTAssertEqual(messages(faker).last, .bye, "and nothing more is heard")

		let page = try connectedPage(session, name: "Safari on iPhone", peerID: "p2", secret: secret)
		XCTAssertEqual(session.devices.map(\.name), ["Safari on iPhone"])
		XCTAssertEqual(session.devices.first?.trusted, true)
		XCTAssertNil(session.devices.first?.checkNumber, "a proof already matches the two ends")
		XCTAssertEqual(session.untrustedPageCount, 0)
		XCTAssertTrue(page.trusted)
		XCTAssertTrue(page.canDownload(document.id))
		XCTAssertEqual(messages(page).last, .docs([ShareDocSummary(id: document.id, name: "Lease.pdf", size: 10_000, type: "application/pdf", unlocked: true)]))
		session.stop()
	}

	func testNothingIsAnsweredBeforeThePagesHello() async throws {
		let session = try await startedSession(with: [try makeFile("Lease.pdf")])
		let document = try XCTUnwrap(session.documents.first)
		let link = try XCTUnwrap(session.connectStubForTesting(secret: nil, origin: .relay(room: "auto", peerID: "p1"),
															   offerFingerprint: fingerprintAA, answerFingerprint: fingerprintBB))
		link.peer.deliverForTesting(.open)
		XCTAssertEqual(messages(link).count, 1, "the hello")
		deliver(["t": "get", "id": document.id], to: link)
		deliver(["t": "unlock", "id": document.id, "pin": document.pin], to: link)
		XCTAssertEqual(messages(link).count, 1)
		XCTAssertTrue(session.devices.isEmpty)
		session.stop()
	}

	func testPagesWithTheSameNameAreNumbered() async throws {
		let session = try await startedSession(with: [])
		_ = try connectedPage(session, name: "Chrome on Mac", peerID: "p1")
		_ = try connectedPage(session, name: "Chrome on Mac", peerID: "p2")
		_ = try connectedPage(session, name: "", peerID: "p3")
		XCTAssertEqual(session.devices.map(\.name), ["Chrome on Mac", "Chrome on Mac 2", "Web browser"])
		XCTAssertEqual(session.untrustedPageCount, 3)
		session.stop()
	}

	// MARK: PINs

	func testWrongAndRightPINs() async throws {
		let session = try await startedSession(with: [try makeFile("Lease.pdf")])
		let document = try XCTUnwrap(session.documents.first)
		let link = try connectedPage(session)
		deliver(["t": "get", "id": document.id], to: link)
		XCTAssertEqual(messages(link).last, .denied(id: document.id, reason: "locked", retryIn: nil, left: nil))
		deliver(["t": "unlock", "id": document.id, "pin": wrongPIN(for: document)], to: link)
		XCTAssertEqual(messages(link).last, .denied(id: document.id, reason: "wrong", retryIn: nil, left: 4))
		XCTAssertEqual(session.documents.first?.pin, document.pin, "a wrong try doesn't replace the PIN")
		deliver(["t": "unlock", "id": document.id, "pin": "12345"], to: link)
		XCTAssertEqual(messages(link).last, .denied(id: document.id, reason: "wrong", retryIn: nil, left: 3), "not even six digits")
		deliver(["t": "unlock", "id": document.id, "pin": document.pin], to: link)
		let after = messages(link)
		XCTAssertEqual(after.dropLast().last, .unlocked(id: document.id))
		XCTAssertEqual(after.last, .docs([ShareDocSummary(id: document.id, name: "Lease.pdf", size: 10_000, type: "application/pdf", unlocked: true)]))
		XCTAssertTrue(link.canDownload(document.id))
		deliver(["t": "unlock", "id": document.id, "pin": "000000"], to: link)
		XCTAssertEqual(messages(link).dropLast().last, .unlocked(id: document.id), "once unlocked, any PIN confirms it")
		deliver(["t": "unlock", "id": "nope", "pin": document.pin], to: link)
		XCTAssertEqual(messages(link).last, .denied(id: "nope", reason: "gone", retryIn: nil, left: nil))
		session.stop()
	}

	func testFiveWrongPINsRefuseThatPageAlone() async throws {
		let session = try await startedSession(with: [try makeFile("Lease.pdf")])
		let document = try XCTUnwrap(session.documents.first)
		let first = try connectedPage(session, name: "Chrome on Mac", peerID: "p1")
		let second = try connectedPage(session, name: "Safari on iPad", peerID: "p2")
		XCTAssertEqual(session.untrustedPageCount, 2)
		let wrong = wrongPIN(for: document)
		for left in [4, 3, 2, 1] {
			deliver(["t": "unlock", "id": document.id, "pin": wrong], to: first)
			XCTAssertEqual(messages(first).last, .denied(id: document.id, reason: "wrong", retryIn: nil, left: left))
		}
		deliver(["t": "unlock", "id": document.id, "pin": wrong], to: first)
		XCTAssertEqual(messages(first).last, .denied(id: document.id, reason: "wrong", retryIn: 30, left: 0))
		deliver(["t": "unlock", "id": document.id, "pin": document.pin], to: first)
		guard case .denied(let id, let reason, let retryIn, let left)? = messages(first).last else { return XCTFail("not refused") }
		XCTAssertEqual(id, document.id)
		XCTAssertEqual(reason, "cooldown")
		XCTAssertEqual(retryIn, 30)
		XCTAssertNil(left)
		XCTAssertFalse(first.canDownload(document.id), "even the right PIN waits")
		XCTAssertEqual(session.documents.first?.pin, document.pin, "the PIN stays")
		deliver(["t": "unlock", "id": document.id, "pin": wrong], to: second)
		XCTAssertEqual(messages(second).last, .denied(id: document.id, reason: "wrong", retryIn: nil, left: 4), "the other page isn't refused")
		deliver(["t": "unlock", "id": document.id, "pin": document.pin], to: second)
		XCTAssertEqual(messages(second).dropLast().last, .unlocked(id: document.id))
		session.stop()
	}

	// MARK: Downloads

	func testUnlockedDocumentGoesInChunksThenEnds() async throws {
		let size = 200_000
		let session = try await startedSession(with: [try makeFile("Big.pdf", size: size)])
		let document = try XCTUnwrap(session.documents.first)
		let link = try connectedPage(session)
		deliver(["t": "unlock", "id": document.id, "pin": document.pin], to: link)
		deliver(["t": "get", "id": document.id], to: link)
		let done = await waitUntil { session.transfers.first?.state == .done }
		XCTAssertTrue(done, "\(String(describing: session.transfers.first?.state))")
		let sent = messages(link)
		guard case .file(let id, let xfer, let name, let fileSize, let type)? = sent.first(where: { if case .file = $0 { return true } else { return false } }) else {
			return XCTFail("no file message")
		}
		XCTAssertEqual(id, document.id)
		XCTAssertEqual(xfer, "d1")
		XCTAssertEqual(name, "Big.pdf")
		XCTAssertEqual(fileSize, Int64(size))
		XCTAssertEqual(type, "application/pdf")
		XCTAssertEqual(sent.last, .end(xfer: "d1"))
		let chunks = link.peer.recordedForTesting.compactMap { if case .bytes(let count) = $0 { return count } else { return nil } }
		XCTAssertEqual(chunks.reduce(0, +), size)
		XCTAssertEqual(chunks.count, 4, "three full chunks and the rest")
		XCTAssertTrue(chunks.allSatisfy { $0 <= NearbyShareConfig.chunkSize })
		XCTAssertEqual(session.transfers.first?.direction, .sending)
		XCTAssertEqual(session.transfers.first?.done, Int64(size))
		XCTAssertEqual(session.transfers.first?.deviceName, "Chrome on Mac")
		session.stop()
	}

	// MARK: Uploads

	func testCancelledUploadFreesTheSlotAndDeletesThePartialFile() async throws {
		let session = try await startedSession(with: [])
		let link = try connectedPage(session)
		link.peer.deliverForTesting(.binary(Data(repeating: 1, count: 100)))
		XCTAssertNil(link.upload, "bytes before an offer go nowhere")
		deliver(["t": "send", "xfer": "u1", "name": "Photo.jpg", "size": 5000, "type": "image/jpeg"], to: link)
		XCTAssertEqual(session.incoming.map(\.name), ["Photo.jpg"])
		XCTAssertEqual(session.incoming.first?.deviceName, "Chrome on Mac")
		deliver(["t": "send", "xfer": "u2", "name": "Other.pdf", "size": 10, "type": "application/pdf"], to: link)
		XCTAssertEqual(messages(link).last, .decline(xfer: "u2", reason: "busy"))
		let offer = try XCTUnwrap(session.incoming.first)
		session.accept(offer)
		XCTAssertTrue(session.incoming.isEmpty)
		XCTAssertEqual(messages(link).last, .accept(xfer: "u1"))
		XCTAssertEqual(session.transfers.first?.state, .moving)
		XCTAssertEqual(session.transfers.first?.direction, .receiving)
		link.peer.deliverForTesting(.binary(Data(repeating: 1, count: 2000)))
		XCTAssertEqual(link.upload?.received, 2000)
		let partial = try XCTUnwrap(link.upload?.url)
		deliver(["t": "cancel", "xfer": "u1"], to: link)
		XCTAssertNil(link.upload)
		XCTAssertEqual(session.transfers.first?.state, .failed("Cancelled on the other device."))
		let deleted = await waitUntil { !FileManager.default.fileExists(atPath: partial.deletingLastPathComponent().path) }
		XCTAssertTrue(deleted, "the partial file goes")
		deliver(["t": "send", "xfer": "u3", "name": "Again.pdf", "size": 10, "type": "application/pdf"], to: link)
		XCTAssertEqual(session.incoming.map(\.name), ["Again.pdf"], "the slot is free again")
		session.decline(try XCTUnwrap(session.incoming.first))
		XCTAssertEqual(messages(link).last, .decline(xfer: "u3", reason: nil))
		XCTAssertNil(link.upload)
		session.stop()
	}

	func testStalledUploadIsGivenUpAndTheSlotFreed() async throws {
		let session = try await startedSession(with: [])
		session.stallSeconds = 0.3
		let link = try connectedPage(session)
		deliver(["t": "send", "xfer": "u1", "name": "Photo.jpg", "size": 5000, "type": "image/jpeg"], to: link)
		session.accept(try XCTUnwrap(session.incoming.first))
		link.peer.deliverForTesting(.binary(Data(repeating: 1, count: 1000)))
		let failed = await waitUntil {
			if case .failed? = session.transfers.first?.state { return true } else { return false }
		}
		XCTAssertTrue(failed)
		XCTAssertEqual(session.transfers.first?.state, .failed("The other device stopped sending."))
		XCTAssertEqual(messages(link).last, .cancel(xfer: "u1"))
		XCTAssertNil(link.upload)
		deliver(["t": "send", "xfer": "u2", "name": "Scan.pdf", "size": 10, "type": "application/pdf"], to: link)
		XCTAssertEqual(session.incoming.map(\.name), ["Scan.pdf"], "the slot is free again")
		session.stop()
	}

	func testUploadThatEndsShortOrRunsLongFails() async throws {
		let session = try await startedSession(with: [])
		let link = try connectedPage(session)
		deliver(["t": "send", "xfer": "u1", "name": "Photo.jpg", "size": 5000, "type": "image/jpeg"], to: link)
		session.accept(try XCTUnwrap(session.incoming.first))
		link.peer.deliverForTesting(.binary(Data(repeating: 1, count: 1000)))
		deliver(["t": "end", "xfer": "u1"], to: link)
		XCTAssertEqual(messages(link).last, .saved(xfer: "u1", ok: false))
		XCTAssertEqual(session.transfers.first?.state, .failed("The file didn't arrive whole."))
		XCTAssertNil(link.upload)
		deliver(["t": "send", "xfer": "u2", "name": "Photo.jpg", "size": 5000, "type": "image/jpeg"], to: link)
		session.accept(try XCTUnwrap(session.incoming.first))
		link.peer.deliverForTesting(.binary(Data(repeating: 1, count: 6000)))
		XCTAssertEqual(messages(link).last, .cancel(xfer: "u2"), "more than it offered")
		XCTAssertEqual(session.transfers.last?.state, .failed("The file didn't arrive whole."))
		XCTAssertNil(link.upload)
		session.stop()
	}

	func testUploadsOfAnyTypeWaitForAcceptButTheirSizeIsChecked() async throws {
		let session = try await startedSession(with: [])
		let link = try connectedPage(session)
		deliver(["t": "send", "xfer": "u1", "name": "Empty.pdf", "size": 0, "type": "application/pdf"], to: link)
		XCTAssertEqual(messages(link).last, .decline(xfer: "u1", reason: "size"))
		deliver(["t": "send", "xfer": "u2", "name": "Huge.mov", "size": NearbyShareConfig.maxIncomingBytes + 1, "type": "video/quicktime"], to: link)
		XCTAssertEqual(messages(link).last, .decline(xfer: "u2", reason: "size"))
		XCTAssertTrue(session.incoming.isEmpty)
		XCTAssertNil(link.upload)
		deliver(["t": "send", "xfer": "u3", "name": "Setup.exe", "size": 10, "type": "application/x-msdownload"], to: link)
		XCTAssertEqual(session.incoming.map(\.name), ["Setup.exe"], "any type waits for Accept")
		XCTAssertEqual(session.incoming.first?.kind, .file)
		session.decline(try XCTUnwrap(session.incoming.first))
		deliver(["t": "send", "xfer": "u4", "name": "Clip", "size": 10, "type": "Video/MP4; codecs=avc1"], to: link)
		XCTAssertEqual(session.incoming.first?.type, "video/mp4")
		XCTAssertEqual(session.incoming.first?.kind, .video)
		session.decline(try XCTUnwrap(session.incoming.first))
		deliver(["t": "send", "xfer": "u5", "name": "Mystery", "size": 10], to: link)
		XCTAssertEqual(session.incoming.first?.type, NearbyShareInput.unknownType, "no type is still a file")
		XCTAssertEqual(photos.asks, 0, "nothing accepted, nothing asked")
		session.stop()
	}

	func testReceivedFileIsSavedInFilesUnderAFreeName() async throws {
		let session = try await startedSession(with: [])
		var savedNames: [String] = []
		var savedPlaces: [NearbyShareDestination] = []
		session.onSaved = { name, destination in
			savedNames.append(name)
			savedPlaces.append(destination)
		}
		let link = try connectedPage(session)
		let bytes = Data((0..<150_000).map { UInt8($0 % 251) })
		let first = try await receive("Notes.zip", type: "application/zip", bytes: bytes, xfer: "u1", over: link, in: session)
		XCTAssertEqual(first.state, .done)
		XCTAssertEqual(first.destination, .files(photosAccessOff: false))
		XCTAssertEqual(messages(link).last, .saved(xfer: "u1", ok: true))
		XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("Notes.zip")), bytes)
		let second = try await receive("Notes.zip", type: "application/zip", bytes: Data("again".utf8), xfer: "u2", over: link, in: session)
		XCTAssertEqual(second.destination, .files(photosAccessOff: false))
		XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("Notes 2.zip")), Data("again".utf8), "the first stays as it was")
		XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("Notes.zip")), bytes)
		XCTAssertEqual(savedNames, ["Notes.zip", "Notes.zip"], "the toast names what was sent")
		XCTAssertEqual(savedPlaces, [.files(photosAccessOff: false), .files(photosAccessOff: false)])
		XCTAssertTrue(photos.added.isEmpty, "a file isn't a picture")
		session.stop()
	}

	func testReceivedPicturesAndVideosGoToPhotos() async throws {
		let session = try await startedSession(with: [])
		let link = try connectedPage(session)
		let picture = try await receive("IMG_0042.jpeg", type: "image/jpeg", bytes: Data(repeating: 1, count: 2000), xfer: "u1", over: link, in: session)
		XCTAssertEqual(picture.destination, .photos)
		XCTAssertEqual(messages(link).last, .saved(xfer: "u1", ok: true))
		let video = try await receive("Clip.mov", type: "video/quicktime", bytes: Data(repeating: 2, count: 3000), xfer: "u2", over: link, in: session)
		XCTAssertEqual(video.destination, .photos)
		XCTAssertEqual(photos.added, ["IMG_0042.jpeg", "Clip.mov (video)"], "handed over while the file was still there")
		XCTAssertEqual(photos.asks, 2, "asked for access on each Accept")
		XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path), "nothing went to Files")
		session.stop()
	}

	func testPicturesGoToFilesWhenPhotosIsOffOrRefusesThem() async throws {
		let session = try await startedSession(with: [])
		let link = try connectedPage(session)
		photos.result = .noAccess
		let refused = try await receive("IMG_0042.jpeg", type: "image/jpeg", bytes: Data(repeating: 1, count: 2000), xfer: "u1", over: link, in: session)
		XCTAssertEqual(refused.destination, .files(photosAccessOff: true))
		XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("IMG_0042.jpeg").path))
		photos.result = .failed
		let odd = try await receive("Clip.mp4", type: "video/mp4", bytes: Data(repeating: 2, count: 3000), xfer: "u2", over: link, in: session)
		XCTAssertEqual(odd.destination, .files(photosAccessOff: false))
		XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("Clip.mp4").path))
		XCTAssertEqual(messages(link).last, .saved(xfer: "u2", ok: true), "saved, only somewhere else")
		let svg = try await receive("Logo.svg", type: "image/svg+xml", bytes: Data("<svg/>".utf8), xfer: "u3", over: link, in: session)
		XCTAssertEqual(svg.destination, .files(photosAccessOff: false))
		XCTAssertEqual(photos.added, ["IMG_0042.jpeg", "Clip.mp4 (video)"], "Photos isn't offered an SVG")
		session.stop()
	}

	func testReceivedPDFGoesToPDFFilesOrToFilesWhenItWontOpen() async throws {
		let session = try await startedSession(with: [])
		let link = try connectedPage(session)
		let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { context in context.beginPage() }
		let good = try await receive("Lease.pdf", type: "application/pdf", bytes: pdf, xfer: "u1", over: link, in: session)
		XCTAssertEqual(good.destination, .pdfFiles)
		XCTAssertEqual(library?.items.map(\.title), ["Lease"])
		let broken = try await receive("Broken.pdf", type: "application/pdf", bytes: Data("not a pdf".utf8), xfer: "u2", over: link, in: session)
		XCTAssertEqual(broken.destination, .files(photosAccessOff: false))
		XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("Broken.pdf").path), "kept, in Files")
		XCTAssertEqual(library?.items.count, 1)
		session.stop()
	}

	// MARK: Closing and stopping

	func testConnectionClosingRemovesTheDevice() async throws {
		let session = try await startedSession(with: [])
		let link = try connectedPage(session)
		XCTAssertEqual(session.devices.count, 1)
		let before = messages(link).count
		link.peer.deliverForTesting(.closed)
		XCTAssertTrue(session.devices.isEmpty)
		XCTAssertEqual(session.untrustedPageCount, 0)
		XCTAssertFalse(session.holdsForTesting(link))
		XCTAssertTrue(link.isClosed)
		deliver(["t": "hello", "v": 1, "role": "web", "name": "Chrome on Mac", "device": "computer"], to: link)
		XCTAssertEqual(messages(link).count, before, "a closed connection hears nothing more")
		session.stop()
	}

	func testByeFromThePageDropsIt() async throws {
		let session = try await startedSession(with: [])
		let link = try connectedPage(session)
		deliver(["t": "bye"], to: link)
		XCTAssertTrue(session.devices.isEmpty)
		XCTAssertFalse(session.holdsForTesting(link))
		session.stop()
	}

	func testStopSaysGoodbyeToEveryPage() async throws {
		let session = try await startedSession(with: [try makeFile("Lease.pdf")])
		let link = try connectedPage(session)
		let other = try connectedPage(session, name: "Firefox", peerID: "p2")
		session.stop()
		for page in [link, other] {
			XCTAssertEqual(Array(messages(page).suffix(2)), [.docs([]), .bye])
			XCTAssertTrue(page.isClosed)
		}
		XCTAssertTrue(session.devices.isEmpty)
		XCTAssertTrue(session.documents.isEmpty)
		XCTAssertEqual(session.untrustedPageCount, 0)
		XCTAssertEqual(session.pairing, .idle)
	}

	// MARK: What the relay says (PROTOCOL.md §2)

	func testRelayMessagesAreParsedFieldByField() {
		let peer = ShareRelay.Peer(id: "abc123", role: "web", name: "Chrome on Mac", device: "computer")
		let welcome = #"{"t":"welcome","id":"me","peers":[{"id":"abc123","role":"web","name":"Chrome on Mac","device":"computer"},"#
			+ #"{"id":"abc123","role":"web","name":"again","device":"computer"},{"id":"bad id","role":"web"},{"id":"x","role":"admin"},"#
			+ #"{"id":"y","role":"app","name":"iPhone","device":"iphone"},{"id":"z","role":"web","name":"‮evil","device":"toaster"}]}"#
		XCTAssertEqual(ShareRelay.parse(welcome), .welcome([peer, .init(id: "y", role: "app", name: "iPhone", device: "iphone"),
															.init(id: "z", role: "web", name: "evil", device: "computer")]))
		XCTAssertEqual(ShareRelay.parse(#"{"t":"welcome","peers":[]}"#), .welcome([]))
		XCTAssertNil(ShareRelay.parse(#"{"t":"welcome"}"#))
		XCTAssertNil(ShareRelay.parse(#"{"t":"welcome","peers":"none"}"#))
		XCTAssertEqual(ShareRelay.parse(#"{"t":"join","peer":{"id":"abc123","role":"web","name":"Chrome on Mac","device":"computer"}}"#), .join(peer))
		XCTAssertEqual(ShareRelay.parse(#"{"t":"join","peer":{"id":"abc123","role":"web"}}"#), .join(.init(id: "abc123", role: "web", name: "", device: "computer")))
		XCTAssertNil(ShareRelay.parse(#"{"t":"join"}"#))
		XCTAssertNil(ShareRelay.parse(#"{"t":"join","peer":{"id":"abc123"}}"#))
		XCTAssertNil(ShareRelay.parse(#"{"t":"join","peer":{"role":"web"}}"#))
		XCTAssertEqual(ShareRelay.parse(#"{"t":"leave","id":"abc123"}"#), .leave(id: "abc123"))
		XCTAssertNil(ShareRelay.parse(#"{"t":"leave","id":"has space"}"#))
		XCTAssertNil(ShareRelay.parse(#"{"t":"leave"}"#))
		let line = "candidate:1 1 udp 2122260223 192.168.1.5 64411 typ host"
		XCTAssertEqual(ShareRelay.parse(#"{"t":"signal","from":"abc123","data":{"candidate":{"candidate":"\#(line)","sdpMid":"0","sdpMLineIndex":0}}}"#),
					   .signal(from: "abc123", .candidate(line, sdpMid: "0", sdpMLineIndex: 0)))
		XCTAssertEqual(ShareRelay.parse(#"{"t":"signal","from":"abc123","data":{"sdp":{"type":"offer","sdp":"v=0"}}}"#),
					   .signal(from: "abc123", .offer("v=0")))
		XCTAssertNil(ShareRelay.parse(#"{"t":"signal","data":{"sdp":{"type":"offer","sdp":"v=0"}}}"#))
		XCTAssertNil(ShareRelay.parse(#"{"t":"signal","from":"a b","data":{"sdp":{"type":"offer","sdp":"v=0"}}}"#))
		XCTAssertNil(ShareRelay.parse(#"{"t":"signal","from":"abc123","data":{"sdp":{"type":"pranswer","sdp":"v=0"}}}"#))
		XCTAssertNil(ShareRelay.parse(#"{"t":"signal","from":"abc123","data":"v=0"}"#))
		XCTAssertNil(ShareRelay.parse(#"{"t":"signal","from":"abc123"}"#))
		XCTAssertEqual(ShareRelay.parse(#"{"t":"error","message":"room full"}"#), .error("room full"))
		XCTAssertEqual(ShareRelay.parse(#"{"t":"error","message":"\u0007beep‮"}"#), .error("beep"))
		XCTAssertEqual(ShareRelay.parse(#"{"t":"error"}"#), .error("?"))
		XCTAssertEqual(ShareRelay.parse(#"{"t":"pong"}"#), .other)
		XCTAssertEqual(ShareRelay.parse(#"{"t":"newer","x":1}"#), .other)
		for text in ["", "not json", "[]", "{}", #"{"t":5}"#, #"{"t":"pong"}"# + String(repeating: " ", count: 130 * 1024)] {
			XCTAssertNil(ShareRelay.parse(text), text.prefix(20).description)
		}
	}

	func testRelayWelcomeKeepsAtMostThePeersARoomAllows() {
		let list = (0..<40).map { #"{"id":"p\#($0)","role":"web","name":"n","device":"phone"}"# }.joined(separator: ",")
		guard case .welcome(let peers)? = ShareRelay.parse(#"{"t":"welcome","peers":[\#(list)]}"#) else { return XCTFail("no welcome") }
		XCTAssertEqual(peers.count, ShareLimits.maxPeers)
		XCTAssertEqual(peers.first?.id, "p0")
		XCTAssertEqual(peers.last?.id, "p31")
		XCTAssertEqual(peers.first?.device, "phone")
	}

	// MARK: Helpers

	/// A session with a library of its own, saving received files in `inbox` and pictures to the
	/// stand-in for Photos.
	private func makeSession(items: [NearbyShareItem]) -> NearbyShareSession {
		let made = PDFLibrary(root: folder.appendingPathComponent("Library", isDirectory: true))
		library = made
		let session = NearbyShareSession(items: items, library: made)
		session.receivedFilesFolder = inbox
		session.photos = photos
		return session
	}

	/// The page offers `bytes` as `name`, it's accepted, sent in chunks and ended; returns the
	/// transfer once it's done or failed, with the temporary file already gone.
	private func receive(_ name: String, type: String, bytes: Data, xfer: String, over link: NearbyShareLink,
						 in session: NearbyShareSession) async throws -> NearbyShareSession.Transfer {
		deliver(["t": "send", "xfer": xfer, "name": name, "size": bytes.count, "type": type], to: link)
		let offer = try XCTUnwrap(session.incoming.last)
		XCTAssertEqual(offer.name, name)
		session.accept(offer)
		XCTAssertEqual(messages(link).last, .accept(xfer: xfer))
		let partial = try XCTUnwrap(link.upload?.url)
		var offset = 0
		for _ in 0...(bytes.count / NearbyShareConfig.chunkSize) where offset < bytes.count {
			let end = min(offset + NearbyShareConfig.chunkSize, bytes.count)
			link.peer.deliverForTesting(.binary(bytes.subdata(in: offset..<end)))
			offset = end
		}
		deliver(["t": "end", "xfer": xfer], to: link)
		let finished = await waitUntil { session.transfers.last.map { $0.state != .moving } ?? false }
		XCTAssertTrue(finished, "\(String(describing: session.transfers.last?.state))")
		XCTAssertFalse(FileManager.default.fileExists(atPath: partial.deletingLastPathComponent().path), "the temporary copy goes")
		return try XCTUnwrap(session.transfers.last)
	}

	/// A file of `size` bytes to share as it is.
	private func makeFile(_ name: String, size: Int = 10_000) throws -> NearbyShareItem {
		let url = folder.appendingPathComponent(name)
		try Data(repeating: 0x25, count: size).write(to: url)
		return .file(url, name: name)
	}

	/// A running session whose documents are all ready.
	private func startedSession(with items: [NearbyShareItem]) async throws -> NearbyShareSession {
		let session = makeSession(items: items)
		session.start()
		let ready = await waitUntil { session.documents.allSatisfy { $0.state == .ready } }
		XCTAssertTrue(ready, "\(session.documents.map(\.state))")
		return session
	}

	/// A page that opened a stub connection and said hello (with a proof when it has `secret`).
	private func connectedPage(_ session: NearbyShareSession, name: String = "Chrome on Mac", peerID: String = "p1",
							   secret: Data? = nil) throws -> NearbyShareLink {
		let room = secret == nil ? "auto" : "room"
		let link = try XCTUnwrap(session.connectStubForTesting(secret: secret, origin: .relay(room: room, peerID: peerID),
															   offerFingerprint: fingerprintAA, answerFingerprint: fingerprintBB))
		link.peer.deliverForTesting(.open)
		var hello: [String: Any] = ["t": "hello", "v": 1, "role": "web", "name": name, "device": "computer"]
		if let secret {
			hello["proof"] = ShareCodes.proof(secret: secret, role: "web", offerFingerprint: fingerprintAA, answerFingerprint: fingerprintBB)
		}
		deliver(hello, to: link)
		return link
	}

	private func deliver(_ message: [String: Any], to link: NearbyShareLink) {
		guard let data = try? JSONSerialization.data(withJSONObject: message) else { return XCTFail("not JSON: \(message)") }
		link.peer.deliverForTesting(.text(data))
	}

	/// The text messages the session sent over `link`, in order.
	private func messages(_ link: NearbyShareLink) -> [ShareOutbound] {
		link.peer.recordedForTesting.compactMap { if case .message(let message) = $0 { return message } else { return nil } }
	}

	/// Six digits that aren't `document`'s PIN.
	private func wrongPIN(for document: NearbyShareSession.SharedDocument) -> String {
		document.pin == "000000" ? "000001" : "000000"
	}

	/// Polls `condition` on the main actor for up to `timeout` seconds.
	private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
		let deadline = Date.now.addingTimeInterval(timeout)
		while Date.now < deadline {
			if condition() { return true }
			try? await Task.sleep(for: .milliseconds(10))
		}
		return condition()
	}
}

/// Stands in for the Photos library: answers with `result` and notes what it was asked.
private final class PhotosStub: NearbySharePhotoSaving, @unchecked Sendable {
	private let lock = NSLock()
	private var state = (result: NearbySharePhotoResult.saved, asks: 0, added: [String]())

	var result: NearbySharePhotoResult {
		get { lock.withLock { state.result } }
		set { lock.withLock { state.result = newValue } }
	}

	/// How many times it was asked for access.
	var asks: Int { lock.withLock { state.asks } }

	/// "name", or "name (video)", for each file it was handed that was there to take.
	var added: [String] { lock.withLock { state.added } }

	func askIfUndecided() {
		lock.withLock { state.asks += 1 }
	}

	func add(_ url: URL, name: String, isVideo: Bool) async -> NearbySharePhotoResult {
		let present = FileManager.default.fileExists(atPath: url.path)
		return lock.withLock {
			if present { state.added.append(isVideo ? "\(name) (video)" : name) }
			return state.result
		}
	}
}
