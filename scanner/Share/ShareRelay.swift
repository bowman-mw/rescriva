//
//  ShareRelay.swift
//  Rescriva (fork of Open Scanner)
//
//  The app's side of the Share Nearby relay (Docs/Rescriva-Share-Protocol.md §2): one WebSocket in one room,
//  who else is in it, and the connection set-up messages passed through it. It pings every 25 s so
//  the relay doesn't drop it as stale, and when the socket goes it reconnects with backoff
//  (1, 2, 4 … 30 s). Two misses in a row show as `unavailable`, but it keeps trying. What the
//  relay sends is read by `parse`, which needs no socket, so tests can feed it text.
//

import Foundation

@MainActor
final class ShareRelay {
	struct Peer: Equatable {
		let id: String
		let role: String
		let name: String
		let device: String
	}

	enum Status: Equatable { case connecting, open, unavailable }

	/// One message from the relay, as `parse` reads it.
	enum Message: Equatable {
		/// Everyone already in the room: duplicates and anything past `ShareLimits.maxPeers` left out.
		case welcome([Peer])
		case join(Peer)
		case leave(id: String)
		/// `from` is a token; whether that peer is in the room is checked when it's handled.
		case signal(from: String, ShareSignal)
		case error(String)
		/// A pong, or something newer than this app.
		case other
	}

	enum Event {
		case status(Status)
		/// Everyone already in the room, when the relay welcomes this device.
		case peers([Peer])
		case join(Peer)
		/// A peer's id. Every peer leaves when the socket drops, before it reconnects.
		case leave(String)
		/// A signal from a peer in the room.
		case signal(from: String, ShareSignal)
	}

	let room: String
	private(set) var status: Status = .connecting

	private static let pingText = #"{"t":"ping"}"#
	private static let pingInterval: TimeInterval = 25
	/// A socket the relay hasn't welcomed by now counts as a miss.
	private static let openTimeout: TimeInterval = 8
	private static let maxRetryDelay: TimeInterval = 30
	/// The relay passes messages of up to `ShareLimits.maxMessageBytes`; a welcome or signal wrapped
	/// around one fits easily in twice that.
	private static let maxIncomingBytes = 2 * ShareLimits.maxMessageBytes
	/// Unreserved URL characters (RFC 3986 §2.3); everything else in a query value is escaped,
	/// including "+", which the relay would read as a space.
	private static let queryValueCharacters = CharacterSet(
		charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
	private static let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.waitsForConnectivity = false
		// Longer than the ping interval, so a quiet but healthy socket never times out.
		configuration.timeoutIntervalForRequest = 120
		return URLSession(configuration: configuration)
	}()

	private let url: URL
	private let onEvent: (Event) -> Void
	private var socket: URLSessionWebSocketTask?
	private var peers: [Peer] = []
	private var isRunning = false
	private var isWelcomed = false
	private var failures = 0
	private var retry: DispatchWorkItem?
	private var timeout: DispatchWorkItem?
	private var pinger: DispatchSourceTimer?

	/// `room` is "auto" or a 22-character room id. Nothing happens until `start()`.
	init(url: URL, room: String, onEvent: @escaping (Event) -> Void) {
		self.url = url
		self.room = room
		self.onEvent = onEvent
	}

	/// Joins the room, and keeps rejoining until `stop()`. Calling it again while running does nothing.
	func start() {
		guard !isRunning else { return }
		isRunning = true
		failures = 0
		setStatus(.connecting)
		connect()
	}

	/// Leaves the room. No events follow. Idempotent.
	func stop() {
		guard isRunning else { return }
		isRunning = false
		retry?.cancel()
		retry = nil
		if let socket {
			socket.cancel(with: .normalClosure, reason: nil)
		}
		discardSocket()
		peers = []
	}

	/// Sends `signal` to a peer in the room. Dropped (and logged) while the relay isn't open.
	func signal(to peerID: String, _ signal: ShareSignal) {
		guard let socket, isWelcomed else {
			Log.share.notice("Share Nearby dropped a signal; the relay isn't open")
			return
		}
		guard ShareJSON.token(peerID) != nil else {
			Log.share.notice("Share Nearby won't signal a malformed peer id")
			return
		}
		let message: [String: Any] = ["t": "signal", "to": peerID, "data": signal.data]
		guard JSONSerialization.isValidJSONObject(message),
			  let data = try? JSONSerialization.data(withJSONObject: message),
			  data.count <= ShareLimits.maxMessageBytes,
			  let text = String(data: data, encoding: .utf8) else {
			Log.share.error("Share Nearby couldn't encode a signal for the relay")
			return
		}
		send(text, on: socket)
	}

	// MARK: The socket

	private func connect() {
		guard isRunning, socket == nil else { return }
		guard let request = makeRequest() else {
			// A bad address or room never gets better, so don't retry.
			Log.share.error("Share Nearby can't use relay \(self.url.absoluteString) with this room")
			setStatus(.unavailable)
			return
		}
		let socket = Self.session.webSocketTask(with: request)
		socket.maximumMessageSize = Self.maxIncomingBytes
		self.socket = socket
		isWelcomed = false
		socket.resume()
		receive(on: socket)
		scheduleTimeout(for: socket)
	}

	/// The relay address with `room`, `role=app`, this device's name and its kind.
	private func makeRequest() -> URLRequest? {
		guard Self.isRoom(room),
			  var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			  let scheme = components.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else { return nil }
		let kind = ShareDevice.kind
		let fields = [
			("room", room),
			("role", "app"),
			("name", ShareJSON.cleanName(ShareDevice.name, limit: ShareLimits.maxDeviceName)),
			("device", ShareLimits.appDevices.contains(kind) ? kind : "iphone"),
		]
		var parts: [String] = []
		for (key, value) in fields {
			guard let escaped = value.addingPercentEncoding(withAllowedCharacters: Self.queryValueCharacters) else { return nil }
			parts.append("\(key)=\(escaped)")
		}
		components.percentEncodedQuery = parts.joined(separator: "&")
		guard let address = components.url else { return nil }
		return URLRequest(url: address)
	}

	private func receive(on socket: URLSessionWebSocketTask) {
		socket.receive { [weak self] result in
			let relay = self
			DispatchQueue.main.async {
				MainActor.assumeIsolated { relay?.received(result, on: socket) }
			}
		}
	}

	private func received(_ result: Result<URLSessionWebSocketTask.Message, Error>, on socket: URLSessionWebSocketTask) {
		guard socket === self.socket else { return }
		switch result {
		case .failure(let error):
			socketEnded(socket, reason: error.localizedDescription)
		case .success(.string(let text)):
			handle(text)
			// The handler may have stopped or restarted the relay.
			if socket === self.socket {
				receive(on: socket)
			}
		case .success:
			// The relay only sends text.
			receive(on: socket)
		}
	}

	private func send(_ text: String, on socket: URLSessionWebSocketTask) {
		socket.send(.string(text)) { error in
			if let error {
				Log.share.error("Share Nearby couldn't write to the relay: \(error.localizedDescription)")
			}
		}
	}

	/// The socket closed, failed or timed out: everyone in the room is gone, and it tries again later.
	private func socketEnded(_ socket: URLSessionWebSocketTask, reason: String) {
		guard socket === self.socket else { return }
		let code = socket.closeCode.rawValue
		// A refused upgrade (a bad room or device is HTTP 400) says more than the socket error does.
		let httpStatus = (socket.response as? HTTPURLResponse)?.statusCode
		let refusal = httpStatus.flatMap { $0 == 101 ? nil : "HTTP \($0)" }
		let detail = code == 4408 ? "dropped as stale" : refusal ?? reason
		Log.share.notice("Share Nearby's relay connection ended (\(detail))")
		socket.cancel(with: .goingAway, reason: nil)
		discardSocket()
		let gone = peers
		peers = []
		for peer in gone {
			onEvent(.leave(peer.id))
		}
		// A handler may have stopped or restarted the relay meanwhile.
		guard isRunning, self.socket == nil, retry == nil else { return }
		failures += 1
		setStatus(failures >= 2 ? .unavailable : .connecting)
		scheduleRetry()
	}

	private func discardSocket() {
		socket = nil
		isWelcomed = false
		timeout?.cancel()
		timeout = nil
		pinger?.cancel()
		pinger = nil
	}

	// MARK: Timers

	private func scheduleTimeout(for socket: URLSessionWebSocketTask) {
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated {
				guard let self, socket === self.socket, !self.isWelcomed else { return }
				self.socketEnded(socket, reason: "no answer in \(Int(Self.openTimeout)) s")
			}
		}
		timeout = work
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.openTimeout, execute: work)
	}

	/// 1, 2, 4, 8, 16, then 30 s.
	private func scheduleRetry() {
		let exponent = min(max(failures, 1), 6) - 1
		let delay = min(Self.maxRetryDelay, TimeInterval(1 << exponent))
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.retry = nil
				self.connect()
			}
		}
		retry = work
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
	}

	private func startPinging() {
		pinger?.cancel()
		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
		timer.setEventHandler { [weak self] in
			MainActor.assumeIsolated {
				guard let self, let socket = self.socket, self.isWelcomed else { return }
				self.send(Self.pingText, on: socket)
			}
		}
		timer.resume()
		pinger = timer
	}

	private func setStatus(_ next: Status) {
		guard status != next else { return }
		status = next
		onEvent(.status(next))
	}

	// MARK: Messages

	private func handle(_ text: String) {
		guard let message = Self.parse(text) else { return }
		switch message {
		case .welcome(let list): welcome(list)
		case .join(let peer): join(peer)
		case .leave(let id): leave(id)
		case .signal(let from, let signal): signalArrived(signal, from: from)
		case .error(let detail): Log.share.notice("Share Nearby's relay said: \(detail)")
		case .other: break
		}
	}

	private func welcome(_ list: [Peer]) {
		guard !isWelcomed else { return }
		isWelcomed = true
		failures = 0
		timeout?.cancel()
		timeout = nil
		startPinging()
		peers = list
		setStatus(.open)
		guard isWelcomed else { return }
		onEvent(.peers(peers))
	}

	private func join(_ peer: Peer) {
		guard isWelcomed else { return }
		if let index = peers.firstIndex(where: { $0.id == peer.id }) {
			peers[index] = peer
		} else {
			guard peers.count < ShareLimits.maxPeers else { return }
			peers.append(peer)
		}
		onEvent(.join(peer))
	}

	private func leave(_ id: String) {
		guard let index = peers.firstIndex(where: { $0.id == id }) else { return }
		peers.remove(at: index)
		onEvent(.leave(id))
	}

	private func signalArrived(_ signal: ShareSignal, from: String) {
		guard isWelcomed, peers.contains(where: { $0.id == from }) else { return }
		onEvent(.signal(from: from, signal))
	}

	// MARK: Checking what the relay says

	/// What one text frame from the relay says (PROTOCOL.md §2), or nil for anything too long,
	/// not JSON, or out of shape: a welcome without a list, a join without a peer, a leave without
	/// an id, a signal with a bad sender or payload. Needs no socket, so tests feed it text.
	static func parse(_ text: String) -> Message? {
		guard text.utf8.count <= maxIncomingBytes,
			  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
			  let message = object as? [String: Any],
			  let type = message["t"] as? String else { return nil }
		switch type {
		case "welcome":
			guard let list = message["peers"] as? [Any] else { return nil }
			return .welcome(peers(from: list))
		case "join":
			guard let peer = peer(from: message["peer"]) else { return nil }
			return .join(peer)
		case "leave":
			guard let id = ShareJSON.token(message["id"]) else { return nil }
			return .leave(id: id)
		case "signal":
			guard let from = ShareJSON.token(message["from"]), let data = message["data"] as? [String: Any],
				  let signal = ShareSignal(data: data) else { return nil }
			return .signal(from: from, signal)
		case "error":
			return .error((message["message"] as? String).map { ShareJSON.cleanName($0, limit: 200) } ?? "?")
		default:
			return .other
		}
	}

	/// The well-formed peers in a welcome's list, each id once, at most `ShareLimits.maxPeers`.
	private static func peers(from list: [Any]) -> [Peer] {
		var peers: [Peer] = []
		for item in list.prefix(ShareLimits.maxPeers) {
			guard let peer = peer(from: item), !peers.contains(where: { $0.id == peer.id }) else { continue }
			peers.append(peer)
		}
		return peers
	}

	/// A peer from a welcome or join: a token id, a known role, a clean name, a known device.
	private static func peer(from value: Any?) -> Peer? {
		guard let object = value as? [String: Any], let id = ShareJSON.token(object["id"]),
			  let role = object["role"] as? String, role == "app" || role == "web" else { return nil }
		let name = (object["name"] as? String).map { ShareJSON.cleanName($0, limit: ShareLimits.maxDeviceName) } ?? ""
		let device = object["device"] as? String ?? ""
		return Peer(id: id, role: role, name: name, device: ShareLimits.relayDevices.contains(device) ? device : "computer")
	}

	/// "auto", or 22 base64url characters.
	private static func isRoom(_ text: String) -> Bool {
		if text == "auto" { return true }
		return text.utf8.count == 22 && ShareJSON.token(text) != nil
	}
}
