//
//  NearbyShareConfig.swift
//  Rescriva (fork of Open Scanner)
//
//  Where Share Nearby's relay and web page live, and the sizes its transfers use
//  (Docs/Rescriva-Share-Protocol.md). The addresses can be pointed at a local relay and site for testing
//  with launch arguments, which land in UserDefaults:
//
//      -shareRelayURL ws://127.0.0.1:8787/ws   (or "off" for no relay)
//      -shareSiteURL http://127.0.0.1:8770/
//

import Foundation

enum NearbyShareConfig {
	/// wss://relay.rescriva.com/ws. UserDefaults "shareRelayURL" overrides it (launch argument
	/// `-shareRelayURL ws://127.0.0.1:8787/ws`), and "off" means no relay.
	static var relayURL: URL? {
		let standard = URL(string: "wss://relay.rescriva.com/ws")
		guard let override = UserDefaults.standard.string(forKey: "shareRelayURL") else { return standard }
		let text = override.trimmingCharacters(in: .whitespacesAndNewlines)
		if text.lowercased() == "off" { return nil }
		guard let url = checkedURL(text, schemes: ["ws", "wss"]) else {
			print("Rescriva: ignoring shareRelayURL \"\(text)\", which isn't a ws:// or wss:// address")
			return standard
		}
		return url
	}

	/// https://share.rescriva.com/. UserDefaults "shareSiteURL" overrides it.
	static var siteURL: URL {
		let standard = URL(string: "https://share.rescriva.com/") ?? URL(fileURLWithPath: "/")
		guard let override = UserDefaults.standard.string(forKey: "shareSiteURL") else { return standard }
		let text = override.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let url = checkedURL(text, schemes: ["http", "https"]) else {
			print("Rescriva: ignoring shareSiteURL \"\(text)\", which isn't an http:// or https:// address")
			return standard
		}
		return url
	}

	/// The most a binary frame carries.
	static let chunkSize = 64 * 1024
	/// Senders wait while the data channel has more than this buffered.
	static let highWater = 1 << 20
	/// The largest file a page may send to the app.
	static let maxIncomingBytes: Int64 = 1 << 30
	/// The largest picture a page may send: far more than any photo, far less than a PDF may be.
	static let maxIncomingImageBytes: Int64 = 128 << 20
	/// How long no-relay pairing tries before showing the connection code.
	static let codeDelay: Duration = .seconds(4)
	/// How long a connection code stays up without connecting. After a code fails, the page throws
	/// its attempt away and shows a fresh QR code, so by then this code can't connect.
	static let codeLifetime: Duration = .seconds(180)

	/// `text` as a URL, when it has one of `schemes` and a host.
	private static func checkedURL(_ text: String, schemes: Set<String>) -> URL? {
		guard text.count <= 512, let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
		guard schemes.contains(scheme), let host = url.host, !host.isEmpty else { return nil }
		return url
	}
}
