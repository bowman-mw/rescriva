//
//  ShareNetwork.swift
//  Rescriva (fork of Open Scanner)
//
//  Which of the app's own addresses goes in a connection code (ShareSite/PROTOCOL.md §3.1). The
//  code holds one private IPv4 address the computer can reach: the Personal Hotspot address when
//  this iPhone is the hotspot, else Wi-Fi, else another local network. Cellular, VPN, AirDrop and
//  loopback interfaces never qualify.
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
