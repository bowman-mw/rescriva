//
//  ShareNetwork.swift
//  Rescriva (fork of Open Scanner)
//
//  Which of the app's own addresses goes in a connection code (Docs/Rescriva-Share-Protocol.md §3.1). The
//  code holds one private IPv4 address the computer can reach: the Personal Hotspot address when
//  this iPhone is the hotspot, else Wi-Fi, else another local network. Cellular, VPN, AirDrop and
//  loopback interfaces never qualify. Also the IPv4 address behind a page's mDNS candidate name.
//

import Foundation

enum ShareNetwork {
	/// IPv4 address → interface name ("en0", "bridge100", "pdp_ip0"), from getifaddrs.
	static func interfaceNames() -> [String: String] {
		var first: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&first) == 0, let head = first else {
			print("Rescriva: getifaddrs failed (\(errno))")
			return [:]
		}
		defer { freeifaddrs(head) }
		var names: [String: String] = [:]
		var cursor: UnsafeMutablePointer<ifaddrs>? = head
		for _ in 0..<maxInterfaces {
			guard let entry = cursor else { break }
			cursor = entry.pointee.ifa_next
			guard let address = ipv4Text(entry.pointee.ifa_addr), let name = entry.pointee.ifa_name else { continue }
			if names[address] == nil { names[address] = String(cString: name) }
		}
		return names
	}

	/// Which local candidate goes in the connection code: 172.20.10.1 (Personal Hotspot) first, then
	/// en0, then other en*/bridge*; only private IPv4; never pdp_ip*, utun*, ipsec*, awdl*, llw*, lo*, anpi*.
	/// An address on no known interface comes last. Ties keep the candidates' order.
	static func codeCandidate(from candidates: [(address: String, port: UInt16)],
							  interfaces: [String: String]) -> (address: String, port: UInt16)? {
		var best: (address: String, port: UInt16)?
		var bestRank = Int.max
		for candidate in candidates.prefix(maxCandidates) {
			guard let rank = rank(candidate, interface: interfaces[candidate.address]), rank < bestRank else { continue }
			best = candidate
			bestRank = rank
		}
		return best
	}

	// MARK: The page's mDNS names

	/// How long `ipv4(forMDNSName:)` waits. An answer that's coming takes about 1.5 s.
	static let mdnsTimeout: TimeInterval = 3

	/// True for a browser's mDNS candidate name: a UUID (8-4-4-4-12 hex digits), then ".local".
	static func isMDNSName(_ host: String) -> Bool {
		let bytes = Array(host.utf8)
		guard bytes.count == 42, host.hasSuffix(".local") else { return false }
		for (index, byte) in bytes.prefix(36).enumerated() {
			let isDash = [8, 13, 18, 23].contains(index)
			guard isDash ? byte == UInt8(ascii: "-") : isHexDigit(byte) else { return false }
		}
		return true
	}

	/// The IPv4 address a page's mDNS candidate name stands for, asking for A records only; nil when
	/// there's no answer within `timeout`. Asked for A and AAAA at once, which is what WebRTC's own
	/// lookup does, Apple's resolver often hears nothing back from the browser once the name has
	/// left its cache (two minutes after the page made it) and gives up after 5 s; asked for A
	/// alone, it has the answer in about 1.5 s. Without this, this side never checks such a page,
	/// so no-relay pairing falls back to the connection code.
	static func ipv4(forMDNSName name: String, timeout: TimeInterval = mdnsTimeout) async -> String? {
		guard isMDNSName(name) else { return nil }
		return await withCheckedContinuation { continuation in
			let answer = ShareLookupAnswer(continuation)
			DispatchQueue.global(qos: .userInitiated).async { answer.finish(lookUpIPv4(name)) }
			DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { answer.finish(nil) }
		}
	}

	/// A blocking A-record lookup of `name`, as dotted text.
	private static func lookUpIPv4(_ name: String) -> String? {
		var hints = addrinfo()
		hints.ai_family = AF_INET
		hints.ai_socktype = SOCK_DGRAM
		var result: UnsafeMutablePointer<addrinfo>?
		let status = getaddrinfo(name, nil, &hints, &result)
		guard status == 0, let first = result else {
			print("Rescriva: Share Nearby couldn't find a page's mDNS name (\(status))")
			return nil
		}
		defer { freeaddrinfo(first) }
		return ipv4Text(first.pointee.ai_addr)
	}

	private static func isHexDigit(_ byte: UInt8) -> Bool {
		(48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
	}

	// MARK: Private

	private static let maxInterfaces = 1024
	private static let maxCandidates = 256
	private static let hotspotAddress = "172.20.10.1"
	private static let excludedPrefixes = ["pdp_ip", "utun", "ipsec", "awdl", "llw", "lo", "anpi"]

	/// Lower is better; nil when the candidate can't go in a code at all.
	private static func rank(_ candidate: (address: String, port: UInt16), interface: String?) -> Int? {
		guard candidate.port != 0, let octets = ShareCodes.ipv4Octets(candidate.address), isPrivate(octets) else { return nil }
		if let interface, excludedPrefixes.contains(where: { interface.hasPrefix($0) }) { return nil }
		if candidate.address == hotspotAddress { return 0 }
		guard let interface else { return 4 }
		if interface == "en0" { return 1 }
		if interface.hasPrefix("en") || interface.hasPrefix("bridge") { return 2 }
		return 3
	}

	/// 10/8, 172.16/12 and 192.168/16 (RFC 1918).
	private static func isPrivate(_ octets: [UInt8]) -> Bool {
		guard octets.count == 4 else { return false }
		if octets[0] == 10 { return true }
		if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
		return octets[0] == 192 && octets[1] == 168
	}

	/// Dotted text for an AF_INET socket address, or nil for any other family.
	private static func ipv4Text(_ address: UnsafeMutablePointer<sockaddr>?) -> String? {
		guard let address, address.pointee.sa_family == UInt8(AF_INET) else { return nil }
		var storage = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
		var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
		guard inet_ntop(AF_INET, &storage, &text, socklen_t(text.count)) != nil else { return nil }
		return String(cString: text)
	}
}

/// Hands a lookup's answer, or the timeout's nil, to its one waiter: whichever comes first.
private final class ShareLookupAnswer: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<String?, Never>?

	init(_ continuation: CheckedContinuation<String?, Never>) {
		self.continuation = continuation
	}

	func finish(_ value: String?) {
		lock.lock()
		let waiting = continuation
		continuation = nil
		lock.unlock()
		waiting?.resume(returning: value)
	}
}
