//
//  ShareDevice.swift
//  Rescriva (fork of Open Scanner)
//
//  How this device introduces itself to the relay and to pages (ShareSite/PROTOCOL.md §2 and §4).
//  Since iOS 16, UIDevice's name is the model ("iPhone") unless the app has Apple's
//  user-assigned-device-name entitlement, which Rescriva doesn't; the page then shows "iPhone".
//  On a Mac it's the computer's name.
//

import UIKit

enum ShareDevice {
	/// "Michael's iPhone", or the Mac's computer name; at most 64 characters.
	@MainActor static var name: String {
		var text = UIDevice.current.name
		if isMac, genericNames.contains(text) || text.isEmpty {
			text = macHostName() ?? "Mac"
		}
		let clean = ShareJSON.cleanName(text, limit: 64)
		return clean.isEmpty ? fallbackName : clean
	}

	/// "iphone", "ipad" or "mac", as the relay and the page expect.
	@MainActor static var kind: String {
		if isMac { return "mac" }
		return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
	}

	// MARK: Private

	private static let genericNames: Set<String> = ["iPhone", "iPad", "Mac", "iPod touch"]

	@MainActor private static var fallbackName: String {
		switch kind {
		case "mac": return "Mac"
		case "ipad": return "iPad"
		default: return "iPhone"
		}
	}

	@MainActor private static var isMac: Bool {
		#if targetEnvironment(macCatalyst)
		return true
		#else
		return ProcessInfo.processInfo.isiOSAppOnMac || UIDevice.current.userInterfaceIdiom == .mac
		#endif
	}

	/// "Michaels-MacBook-Pro.local" → "Michaels MacBook Pro", for when the system name is generic.
	/// gethostname, because ProcessInfo's hostName can wait on DNS.
	private static func macHostName() -> String? {
		var buffer = [CChar](repeating: 0, count: 256)
		guard gethostname(&buffer, buffer.count - 1) == 0 else {
			print("Rescriva: gethostname failed (\(errno))")
			return nil
		}
		var host = String(cString: buffer)
		if host.hasSuffix(".local") { host.removeLast(".local".count) }
		let words = host.split(separator: "-").joined(separator: " ")
		return words.isEmpty || words == "localhost" ? nil : words
	}
}
