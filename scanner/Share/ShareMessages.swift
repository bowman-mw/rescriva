//
//  ShareMessages.swift
//  Rescriva (fork of Open Scanner)
//
//  The JSON that crosses Share Nearby's data channel (Docs/Rescriva-Share-Protocol.md §4) and the relay's
//  `signal` payloads (§2). Everything inbound comes from a web page, so it's read field by field:
//  unknown or malformed messages are dropped, ids must be short base64url-ish tokens, and names
//  lose control characters and are clipped.
//
//      page → app   hello, unlock, get, send, end, cancel, bye
//      app → page   hello, docs, unlocked, denied, file, end, accept, decline, saved, cancel, bye
//

import Foundation

/// What the page sends over the data channel (PROTOCOL.md §4).
enum ShareInbound: Equatable {
	/// `device` is "phone", "tablet" or "computer" (anything else reads as "computer"). `proof` is
	/// present when the page holds the connection's secret.
	case hello(name: String, device: String, proof: String?)
	case unlock(id: String, pin: String)
	case get(id: String)
	case send(xfer: String, name: String, size: Int64, type: String)
	case end(xfer: String)
	case cancel(xfer: String)
	case bye

	/// Nil for anything unknown or malformed; names clipped to 255.
	init?(json: Data) {
		guard json.count <= ShareJSON.maxMessage,
			  let object = try? JSONSerialization.jsonObject(with: json),
			  let message = object as? [String: Any], let type = message["t"] as? String else { return nil }
		switch type {
		case "hello": self.init(hello: message)
		case "unlock": self.init(unlock: message)
		case "get":
			guard let id = ShareJSON.token(message["id"]) else { return nil }
			self = .get(id: id)
		case "send": self.init(send: message)
		case "end":
			guard let xfer = ShareJSON.token(message["xfer"]) else { return nil }
			self = .end(xfer: xfer)
		case "cancel":
			guard let xfer = ShareJSON.token(message["xfer"]) else { return nil }
			self = .cancel(xfer: xfer)
		case "bye": self = .bye
		default: return nil
		}
	}

	private init?(hello message: [String: Any]) {
		if let role = message["role"], (role as? String) != "web" { return nil }
		guard let name = message["name"] as? String else { return nil }
		let device = message["device"] as? String
		var proof: String?
		if let value = message["proof"], !(value is NSNull) {
			guard let text = value as? String, (1...ShareJSON.maxProof).contains(text.utf8.count) else { return nil }
			proof = text
		}
		let kind = device.flatMap { ShareJSON.pageDevices.contains($0) ? $0 : nil } ?? "computer"
		self = .hello(name: ShareJSON.cleanName(name, limit: ShareJSON.maxHelloName), device: kind, proof: proof)
	}

	private init?(unlock message: [String: Any]) {
		guard let id = ShareJSON.token(message["id"]), let pin = message["pin"] as? String,
			  pin.utf8.count <= ShareJSON.maxPIN else { return nil }
		self = .unlock(id: id, pin: pin)
	}

	private init?(send message: [String: Any]) {
		guard let xfer = ShareJSON.token(message["xfer"]), let name = message["name"] as? String,
			  let size = ShareJSON.int64(message["size"]), size >= 0 else { return nil }
		let type = (message["type"] as? String) ?? ""
		self = .send(xfer: xfer, name: ShareJSON.cleanName(name, limit: ShareJSON.maxName),
					 size: size, type: ShareJSON.cleanName(type, limit: ShareJSON.maxName).lowercased())
	}
}

/// One shared document as the page lists it.
struct ShareDocSummary: Equatable {
	let id: String
	let name: String
	let size: Int64
	let type: String
	let unlocked: Bool
}

/// What the app sends.
enum ShareOutbound: Equatable {
	case hello(name: String, device: String, session: String, proof: String?)
	case docs([ShareDocSummary])
	case unlocked(id: String)
	/// `reason` is "wrong", "cooldown", "locked" or "gone".
	case denied(id: String, reason: String, retryIn: Int?, left: Int?)
	case file(id: String, xfer: String, name: String, size: Int64, type: String)
	case end(xfer: String)
	case accept(xfer: String)
	case decline(xfer: String, reason: String?)
	case saved(xfer: String, ok: Bool)
	case cancel(xfer: String)
	case bye

	/// The text frame. Keys are sorted, so the same message is always the same bytes.
	var json: Data {
		do {
			return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
		} catch {
			print("Rescriva: couldn't write a Share Nearby message: \(error)")
			return Data(#"{"t":"bye"}"#.utf8)
		}
	}

	private var object: [String: Any] {
		switch self {
		case let .hello(name, device, session, proof):
			var message: [String: Any] = ["t": "hello", "v": 1, "role": "app", "name": name, "device": device, "session": session]
			if let proof { message["proof"] = proof }
			return message
		case let .docs(docs):
			let list: [[String: Any]] = docs.map {
				["id": $0.id, "name": $0.name, "size": NSNumber(value: $0.size), "type": $0.type, "unlocked": $0.unlocked]
			}
			return ["t": "docs", "docs": list]
		case let .unlocked(id):
			return ["t": "unlocked", "id": id]
		case let .denied(id, reason, retryIn, left):
			var message: [String: Any] = ["t": "denied", "id": id, "reason": reason]
			if let retryIn { message["retryIn"] = retryIn }
			if let left { message["left"] = left }
			return message
		case let .file(id, xfer, name, size, type):
			return ["t": "file", "id": id, "xfer": xfer, "name": name, "size": NSNumber(value: size), "type": type]
		case let .end(xfer):
			return ["t": "end", "xfer": xfer]
		case let .accept(xfer):
			return ["t": "accept", "xfer": xfer]
		case let .decline(xfer, reason):
			var message: [String: Any] = ["t": "decline", "xfer": xfer]
			if let reason { message["reason"] = reason }
			return message
		case let .saved(xfer, ok):
			return ["t": "saved", "xfer": xfer, "ok": ok]
		case let .cancel(xfer):
			return ["t": "cancel", "xfer": xfer]
		case .bye:
			return ["t": "bye"]
		}
	}
}

/// A relay `signal` payload (PROTOCOL.md §2).
enum ShareSignal: Equatable {
	case offer(String)
	case answer(String)
	case candidate(String, sdpMid: String?, sdpMLineIndex: Int32)

	/// Nil for anything that isn't an offer, an answer or a candidate, or is too long. A candidate
	/// line may not span lines; a missing `sdpMLineIndex` reads as 0.
	init?(data: [String: Any]) {
		if let description = data["sdp"] as? [String: Any] {
			guard let type = description["type"] as? String, let sdp = description["sdp"] as? String,
				  sdp.utf8.count <= ShareJSON.maxSDP else { return nil }
			switch type {
			case "offer": self = .offer(sdp)
			case "answer": self = .answer(sdp)
			default: return nil
			}
			return
		}
		guard let candidate = data["candidate"] as? [String: Any], let line = candidate["candidate"] as? String,
			  line.utf8.count <= ShareJSON.maxCandidate, !line.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else { return nil }
		var mid: String?
		if let value = candidate["sdpMid"], !(value is NSNull) {
			guard let text = value as? String, text.utf8.count <= 32 else { return nil }
			mid = text
		}
		var index: Int32 = 0
		if let value = candidate["sdpMLineIndex"], !(value is NSNull) {
			guard let number = ShareJSON.int64(value), let small = Int32(exactly: number), small >= 0 else { return nil }
			index = small
		}
		self = .candidate(line, sdpMid: mid, sdpMLineIndex: index)
	}

	var data: [String: Any] {
		switch self {
		case let .offer(sdp):
			return ["sdp": ["type": "offer", "sdp": sdp]]
		case let .answer(sdp):
			return ["sdp": ["type": "answer", "sdp": sdp]]
		case let .candidate(line, mid, index):
			var candidate: [String: Any] = ["candidate": line, "sdpMLineIndex": NSNumber(value: index)]
			if let mid { candidate["sdpMid"] = mid }
			return ["candidate": candidate]
		}
	}
}

/// Reading untrusted JSON values.
enum ShareJSON {
	static let maxMessage = 64 * 1024
	static let maxSDP = 60 * 1024
	static let maxCandidate = 1024
	static let maxName = 255
	static let maxHelloName = 64
	static let maxProof = 128
	static let maxPIN = 16
	static let maxToken = 64
	/// What a page's hello may call its device (rescriva-share's assets/main.js `describeBrowser`).
	static let pageDevices: Set<String> = ["phone", "tablet", "computer"]

	/// An id or transfer id: 1…64 of [A-Za-z0-9_-].
	static func token(_ value: Any?) -> String? {
		guard let text = value as? String, (1...maxToken).contains(text.utf8.count) else { return nil }
		let ok = text.utf8.allSatisfy {
			(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
		}
		return ok ? text : nil
	}

	/// A whole JSON number that fits in Int64 (not a Bool, not a fraction).
	static func int64(_ value: Any?) -> Int64? {
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
		let double = number.doubleValue
		guard double.isFinite, double == double.rounded(), abs(double) <= 9_007_199_254_740_992 else { return nil }
		return Int64(exactly: double)
	}

	/// `text` without control characters, trimmed, and at most `limit` characters.
	static func cleanName(_ text: String, limit: Int) -> String {
		var scalars = String.UnicodeScalarView()
		for scalar in text.unicodeScalars.prefix(limit * 4) where !CharacterSet.controlCharacters.contains(scalar) {
			scalars.append(scalar)
		}
		let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
		return String(trimmed.prefix(limit))
	}
}
