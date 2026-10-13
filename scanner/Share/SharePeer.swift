//
//  SharePeer.swift
//  Rescriva (fork of Open Scanner)
//
//  One WebRTC connection to a Share Nearby web page (ShareSite/PROTOCOL.md §2–§4): a peer
//  connection with no ICE servers and one negotiated data channel. Through the relay, the page's
//  offer arrives and the app answers. With no relay, the offer is rebuilt from the page's QR code,
//  the app's answer uses the certificate built into the app, and the answer's ICE credentials are
//  swapped for the ones derived from the pairing secret. WebRTC calls back on its own threads;
//  every callback goes to the main queue in the order it came, so frames keep their order.
//

import Foundation
import WebRTC

/// Why a peer couldn't get a connection going.
enum SharePeerError: LocalizedError, Equatable {
	/// WebRTC couldn't make the peer connection or its data channel.
	case unavailable
	/// `close()` was called, or the connection ended, before set-up finished.
	case closed
	/// `answer(offer:)` or `connect(to:)` was already called on this peer.
	case alreadyStarted
	/// The page's offer isn't something to hand to WebRTC.
	case badOffer
	/// The no-relay answer's fingerprint isn't the built-in certificate's, so the page would refuse it.
	case wrongCertificate
	/// WebRTC refused a description.
	case negotiation(String)

	var errorDescription: String? {
		switch self {
		case .unavailable: return "WebRTC couldn't start a connection."
		case .closed: return "The connection closed while it was being set up."
		case .alreadyStarted: return "This connection was already set up."
		case .badOffer: return "The other device's connection offer wasn't usable."
		case .wrongCertificate: return "The app's built-in certificate didn't load."
		case .negotiation(let detail): return "The connection couldn't be set up: \(detail)"
		}
	}
}

@MainActor
final class SharePeer {
	enum Event {
		/// A candidate WebRTC gathered, for the relay. The line has no "a=".
		case localCandidate(String, sdpMid: String?, sdpMLineIndex: Int32)
		/// The data channel opened; send `hello` now.
		case open
		/// A text frame (JSON), at most 64 KiB.
		case text(Data)
		/// A binary frame (file bytes).
		case binary(Data)
		/// The connection ended on its own: the page closed it, or ICE failed. Sent at most once,
		/// and never after `close()`.
		case closed
	}

	let id: UUID
	/// The connection's trust secret, when it has one (§1.2).
	let secret: Data?
	/// The page's DTLS fingerprint, from the offer this peer applied.
	private(set) var offerFingerprint: String?
	/// The app's DTLS fingerprint, from the answer this peer applied.
	private(set) var answerFingerprint: String?
	/// Candidate lines gathered so far, for the connection code. No "a=".
	private(set) var localCandidates: [String] = []
	/// True from the `open` event until the connection closes.
	var isOpen: Bool { channelIsOpen && !isClosed }

	private static let label = "rescriva"
	/// The page's text frames are small JSON messages; anything bigger is dropped.
	private static let maxTextBytes = 64 * 1024
	/// Relay messages are at most 64 KB, so a real offer is smaller than this.
	private static let maxOfferBytes = 64 * 1024
	private static let maxCandidateBytes = 1024
	private static let maxPendingCandidates = 64
	private static let maxLocalCandidates = 32
	/// The page has one m= section, its data channel; `answer(offer:)` refuses any other offer.
	private static let maxMLineIndex: Int32 = 0
	/// `waitForRoom()` looks again this often even without a buffer callback, for at most
	/// `roomChecks` times (five minutes) before giving up on that wait.
	private static let roomCheckInterval: TimeInterval = 0.5
	private static let roomChecks = 600
	/// How long `close()` gives a final `bye` to leave before the transport is torn down.
	private static let closeGrace: TimeInterval = 0.5
	/// The page's mDNS candidates this side looks up itself (see `ShareNetwork.ipv4(forMDNSName:)`),
	/// at most; the candidates made from them are numbered from `resolvedFoundation` up.
	private static let maxLookups = 8
	private static let resolvedFoundation = 100

	private let onEvent: (SharePeer, Event) -> Void
	private let usesBuiltInCertificate: Bool
	private let observer = SharePeerObserver()
	private var connection: RTCPeerConnection?
	private var channel: RTCDataChannel?
	private var channelIsOpen = false
	private var isClosed = false
	private var hasStarted = false
	private var hasRemoteDescription = false
	private var pendingCandidates: [RTCIceCandidate] = []
	private var lookups = 0
	private var roomWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

	/// `builtInCertificate` is for no-relay pairing. Events arrive on the main queue, in order.
	init(secret: Data?, builtInCertificate: Bool, onEvent: @escaping (SharePeer, Event) -> Void) {
		self.id = UUID()
		self.secret = secret
		self.usesBuiltInCertificate = builtInCertificate
		self.onEvent = onEvent
		observer.peer = self
		makeConnection()
	}

	// MARK: Setting up

	/// Relay mode: applies the page's offer and returns the answer SDP for the relay.
	func answer(offer sdp: String) async throws -> String {
		let connection = try begin()
		// One data channel and one fingerprint, or nothing: the proof covers that fingerprint, so it
		// has to be the one DTLS checks (ShareSDP.soleFingerprint).
		guard Self.isPlausibleOffer(sdp), ShareSDP.isDataChannelOnly(sdp),
			  let pageFingerprint = ShareSDP.soleFingerprint(in: sdp) else {
			print("Rescriva: Share Nearby got an offer it can't use")
			throw SharePeerError.badOffer
		}
		try await apply(sdp, type: .offer, remote: true, on: connection)
		offerFingerprint = pageFingerprint
		await addPendingCandidates()
		let answer = try await makeAnswer(on: connection)
		try await apply(answer, type: .answer, remote: false, on: connection)
		guard let appFingerprint = ShareSDP.fingerprint(in: answer) else {
			print("Rescriva: Share Nearby's answer has no fingerprint")
			throw SharePeerError.negotiation("no fingerprint")
		}
		answerFingerprint = appFingerprint
		return answer
	}

	/// No-relay mode: rebuilt offer, an answer with ICE credentials swapped in from the secret.
	func connect(to pairing: SharePairingOffer) async throws {
		let connection = try begin()
		if secret != pairing.secret {
			print("Rescriva: Share Nearby is pairing with a secret that isn't this peer's")
		}
		let addresses = await Self.ipv4Addresses(of: pairing.candidates.prefix(Self.maxLookups).map(\.host))
		guard !isClosed else { throw SharePeerError.closed }
		let offer = ShareSDP.offer(for: pairing, addresses: addresses)
		try await apply(offer, type: .offer, remote: true, on: connection)
		offerFingerprint = ShareSDP.fingerprint(in: offer) ?? pairing.fingerprint
		await addPendingCandidates()
		let answer = try await makeAnswer(on: connection)
		let credentials = ShareCodes.iceCredentials(secret: pairing.secret)
		let swapped = ShareSDP.replacingICECredentials(in: answer, ufrag: credentials.ufrag, pwd: credentials.pwd)
		// The page made up the app's answer with the built-in fingerprint; anything else can't connect.
		guard let appFingerprint = ShareSDP.fingerprint(in: swapped),
			  appFingerprint.uppercased() == ShareCertificate.fingerprint.uppercased() else {
			print("Rescriva: Share Nearby's no-relay answer doesn't use the built-in certificate")
			throw SharePeerError.wrongCertificate
		}
		try await apply(swapped, type: .answer, remote: false, on: connection)
		answerFingerprint = appFingerprint
	}

	/// A candidate from the page, through the relay. Malformed ones are ignored; ones that come
	/// before the offer wait for it. One at an mDNS name goes to WebRTC at the name's IPv4 address
	/// when this side can find it (`resolved(_:)`).
	func addRemoteCandidate(_ line: String, sdpMid: String?, sdpMLineIndex: Int32) async {
		guard !isClosed else { return }
		guard let candidate = Self.remoteCandidate(line, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex) else { return }
		let resolved = await resolved(line)
		guard !isClosed else { return }
		if let resolved, let replacement = Self.remoteCandidate(resolved, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex) {
			await take(replacement)
			return
		}
		await take(candidate)
	}

	// MARK: Sending

	@discardableResult func send(_ message: ShareOutbound) -> Bool {
		sendFrame(message.json, isBinary: false)
	}

	/// One chunk of file bytes, at most `NearbyShareConfig.chunkSize`.
	@discardableResult func sendBinary(_ data: Data) -> Bool {
		guard data.count <= NearbyShareConfig.chunkSize else {
			print("Rescriva: Share Nearby won't send a \(data.count)-byte chunk")
			return false
		}
		return sendFrame(data, isBinary: true)
	}

	/// Returns once the send buffer is under `NearbyShareConfig.highWater`, or the channel closed.
	/// Also returns if the task is cancelled, or after five minutes with no room.
	func waitForRoom() async {
		for _ in 0..<Self.roomChecks {
			guard isFull, !Task.isCancelled else { return }
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				let token = UUID()
				roomWaiters[token] = continuation
				DispatchQueue.main.asyncAfter(deadline: .now() + Self.roomCheckInterval) { [weak self] in
					MainActor.assumeIsolated { self?.resumeRoomWaiter(token) }
				}
			}
		}
		print("Rescriva: Share Nearby's send buffer didn't drain")
	}

	/// Closes the data channel and the connection. No events follow, not even `closed`. Idempotent.
	func close() {
		guard !isClosed else { return }
		tearDown()
	}

	// MARK: WebRTC's callbacks (on the main queue)

	fileprivate func gathered(_ line: String, sdpMid: String?, sdpMLineIndex: Int32) {
		guard !isClosed, !line.isEmpty else { return }
		if localCandidates.count < Self.maxLocalCandidates {
			localCandidates.append(line)
		}
		onEvent(self, .localCandidate(line, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex))
	}

	fileprivate func channelChanged(_ state: RTCDataChannelState) {
		guard !isClosed else { return }
		switch state {
		case .open:
			guard !channelIsOpen else { return }
			channelIsOpen = true
			onEvent(self, .open)
		case .closing, .closed:
			finish()
		case .connecting:
			break
		@unknown default:
			break
		}
	}

	fileprivate func connectionChanged(_ state: RTCPeerConnectionState) {
		guard !isClosed else { return }
		switch state {
		case .failed:
			print("Rescriva: Share Nearby's connection failed")
			finish()
		case .closed:
			finish()
		case .new, .connecting, .connected, .disconnected:
			break
		@unknown default:
			break
		}
	}

	fileprivate func received(_ data: Data, isBinary: Bool) {
		guard !isClosed else { return }
		if !channelIsOpen {
			// A frame means the channel is open, even if WebRTC hasn't said so yet.
			channelChanged(.open)
			guard !isClosed else { return }
		}
		if isBinary {
			onEvent(self, .binary(data))
			return
		}
		guard data.count <= Self.maxTextBytes else {
			print("Rescriva: Share Nearby dropped a \(data.count)-byte message")
			return
		}
		onEvent(self, .text(data))
	}

	fileprivate func bufferChanged(_ amount: UInt64) {
		guard amount < UInt64(NearbyShareConfig.highWater), !roomWaiters.isEmpty else { return }
		resumeRoomWaiters()
	}

	// MARK: Plumbing

	private func makeConnection() {
		let configuration = RTCConfiguration()
		configuration.sdpSemantics = .unifiedPlan
		configuration.iceServers = []
		configuration.candidateNetworkPolicy = .lowCost
		configuration.continualGatheringPolicy = .gatherOnce
		if usesBuiltInCertificate {
			configuration.certificate = RTCCertificate(privateKey: ShareCertificate.privateKeyPEM,
													   certificate: ShareCertificate.certificatePEM)
		}
		let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
		guard let connection = ShareWebRTC.factory.peerConnection(with: configuration, constraints: constraints,
																  delegate: observer) else {
			print("Rescriva: WebRTC couldn't make a peer connection")
			return
		}
		let channelConfiguration = RTCDataChannelConfiguration()
		channelConfiguration.isNegotiated = true
		channelConfiguration.channelId = 0
		channelConfiguration.isOrdered = true
		guard let channel = connection.dataChannel(forLabel: Self.label, configuration: channelConfiguration) else {
			print("Rescriva: WebRTC couldn't make the data channel")
			connection.close()
			return
		}
		channel.delegate = observer
		self.connection = connection
		self.channel = channel
	}

	/// The connection, for the one call that sets this peer up.
	private func begin() throws -> RTCPeerConnection {
		guard !isClosed else { throw SharePeerError.closed }
		guard !hasStarted else { throw SharePeerError.alreadyStarted }
		guard let connection else { throw SharePeerError.unavailable }
		hasStarted = true
		return connection
	}

	private func apply(_ sdp: String, type: RTCSdpType, remote: Bool, on connection: RTCPeerConnection) async throws {
		let description = RTCSessionDescription(type: type, sdp: sdp)
		let failure: String? = await withCheckedContinuation { continuation in
			if remote {
				ShareWebRTC.setRemote(description, on: connection, continuation)
			} else {
				ShareWebRTC.setLocal(description, on: connection, continuation)
			}
		}
		guard !isClosed else { throw SharePeerError.closed }
		if let failure {
			print("Rescriva: WebRTC refused the \(remote ? "page's" : "app's") description: \(failure)")
			throw SharePeerError.negotiation(failure)
		}
	}

	private func makeAnswer(on connection: RTCPeerConnection) async throws -> String {
		let result: Result<String, SharePeerError> = await withCheckedContinuation { continuation in
			ShareWebRTC.answer(on: connection, continuation)
		}
		guard !isClosed else { throw SharePeerError.closed }
		switch result {
		case .success(let sdp):
			return sdp
		case .failure(let error):
			print("Rescriva: WebRTC couldn't make an answer: \(error.localizedDescription)")
			throw error
		}
	}

	/// A remote candidate goes to WebRTC once the page's offer is applied; until then it waits.
	private func take(_ candidate: RTCIceCandidate) async {
		guard hasRemoteDescription else {
			guard pendingCandidates.count < Self.maxPendingCandidates else {
				print("Rescriva: Share Nearby dropped a candidate; too many arrived before the offer")
				return
			}
			pendingCandidates.append(candidate)
			return
		}
		await add(candidate)
	}

	/// A page candidate at an mDNS name, rewritten to the name's IPv4 address, or nil for any other
	/// candidate or when the name isn't found. This side looks the name up itself, asking for A
	/// records only, rather than leave it to WebRTC: WebRTC asks for A and AAAA at once, which a
	/// browser's responder can leave unanswered, and then this side never checks the page.
	private func resolved(_ line: String) async -> String? {
		guard let host = ShareSDP.hostCandidate(line), ShareNetwork.isMDNSName(host.address),
			  lookups < Self.maxLookups else { return nil }
		lookups += 1
		let foundation = Self.resolvedFoundation + lookups
		guard let address = await ShareNetwork.ipv4(forMDNSName: host.address) else { return nil }
		return ShareSDP.ipv4HostCandidate(foundation: foundation, address: address, port: host.port)
	}

	/// IPv4 addresses for the mDNS names among `hosts`, looked up together; names not found are left out.
	private static func ipv4Addresses(of hosts: [String]) async -> [String: String] {
		let names = Array(Set(hosts.filter(ShareNetwork.isMDNSName)))
		guard !names.isEmpty else { return [:] }
		return await withTaskGroup(of: (String, String?).self) { group in
			for name in names {
				group.addTask { (name, await ShareNetwork.ipv4(forMDNSName: name)) }
			}
			var found: [String: String] = [:]
			for await (name, address) in group {
				if let address { found[name] = address }
			}
			return found
		}
	}

	private func addPendingCandidates() async {
		hasRemoteDescription = true
		let queued = pendingCandidates
		pendingCandidates = []
		for candidate in queued {
			await add(candidate)
		}
	}

	private func add(_ candidate: RTCIceCandidate) async {
		guard !isClosed, let connection else { return }
		let failure: String? = await withCheckedContinuation { continuation in
			ShareWebRTC.add(candidate, on: connection, continuation)
		}
		if let failure, !isClosed {
			print("Rescriva: WebRTC didn't take a remote candidate: \(failure)")
		}
	}

	private func sendFrame(_ data: Data, isBinary: Bool) -> Bool {
		guard isOpen, let channel else { return false }
		let sent = channel.sendData(RTCDataBuffer(data: data, isBinary: isBinary))
		if !sent {
			print("Rescriva: Share Nearby couldn't send a \(isBinary ? "binary" : "text") frame")
		}
		return sent
	}

	/// True while the channel is open and holding `highWater` bytes or more.
	private var isFull: Bool {
		guard isOpen, let channel else { return false }
		return channel.bufferedAmount >= UInt64(NearbyShareConfig.highWater)
	}

	private func resumeRoomWaiter(_ token: UUID) {
		guard let continuation = roomWaiters.removeValue(forKey: token) else { return }
		continuation.resume()
	}

	private func resumeRoomWaiters() {
		let waiters = roomWaiters.values
		roomWaiters = [:]
		for continuation in waiters {
			continuation.resume()
		}
	}

	/// The connection ended on its own.
	private func finish() {
		guard !isClosed else { return }
		tearDown()
		onEvent(self, .closed)
	}

	private func tearDown() {
		let hadOpenChannel = channelIsOpen
		isClosed = true
		channelIsOpen = false
		observer.peer = nil
		pendingCandidates = []
		channel?.delegate = nil
		channel?.close()
		channel = nil
		if let connection {
			self.connection = nil
			if hadOpenChannel {
				// Closing the channel first lets a last `bye` go out before the transport goes.
				DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeGrace) { connection.close() }
			} else {
				connection.close()
			}
		}
		resumeRoomWaiters()
	}

	/// The offer's text: bounded, SDP-shaped, with no NULs.
	private static func isPlausibleOffer(_ sdp: String) -> Bool {
		let bytes = sdp.utf8
		guard !bytes.isEmpty, bytes.count <= maxOfferBytes, sdp.hasPrefix("v=0") else { return false }
		return !bytes.contains(0)
	}

	/// A candidate from the relay as WebRTC takes it, or nil for an empty (end-of-candidates) or
	/// malformed one: printable ASCII only, "candidate:…", a short mid.
	private static func remoteCandidate(_ line: String, sdpMid: String?, sdpMLineIndex: Int32) -> RTCIceCandidate? {
		var text = line
		if text.hasPrefix("a=") {
			text.removeFirst(2)
		}
		guard !text.isEmpty else { return nil }
		let printable = text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
		guard printable, text.utf8.count <= maxCandidateBytes, text.hasPrefix("candidate:"),
			  (0...maxMLineIndex).contains(sdpMLineIndex) else {
			print("Rescriva: Share Nearby ignored a malformed candidate")
			return nil
		}
		if let sdpMid, !isToken(sdpMid) {
			print("Rescriva: Share Nearby ignored a candidate with a malformed mid")
			return nil
		}
		return RTCIceCandidate(sdp: text, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
	}

	/// [A-Za-z0-9_-], 1…16 characters, like the mids PROTOCOL.md §3 allows.
	private static func isToken(_ text: String) -> Bool {
		let scalars = text.unicodeScalars
		guard (1...16).contains(scalars.count) else { return false }
		return scalars.allSatisfy { scalar in
			switch scalar {
			case "A"..."Z", "a"..."z", "0"..."9", "_", "-": return true
			default: return false
			}
		}
	}
}

/// WebRTC's one factory (it owns WebRTC's threads), and its completion-handler calls. The calls
/// are made from outside the main actor on purpose: their handlers run on WebRTC's signaling
/// thread and only resume a continuation.
private enum ShareWebRTC {
	@MainActor static let factory: RTCPeerConnectionFactory = {
		if !RTCInitializeSSL() {
			print("Rescriva: WebRTC couldn't set up SSL")
		}
		keepAwayFromAudio()
		return RTCPeerConnectionFactory()
	}()

	/// Share Nearby only sends data, so WebRTC never needs the microphone or speaker. With manual
	/// audio on and audio off before the factory exists, WebRTC never starts its voice audio unit
	/// or sets up AVAudioSession, and music playing on the device carries on through a share.
	@MainActor private static func keepAwayFromAudio() {
		let audio = RTCAudioSession.sharedInstance()
		audio.useManualAudio = true
		audio.isAudioEnabled = false
	}

	static func setRemote(_ description: RTCSessionDescription, on connection: RTCPeerConnection,
						  _ continuation: CheckedContinuation<String?, Never>) {
		connection.setRemoteDescription(description) { error in
			continuation.resume(returning: error.map(describe))
		}
	}

	static func setLocal(_ description: RTCSessionDescription, on connection: RTCPeerConnection,
						 _ continuation: CheckedContinuation<String?, Never>) {
		connection.setLocalDescription(description) { error in
			continuation.resume(returning: error.map(describe))
		}
	}

	static func answer(on connection: RTCPeerConnection,
					   _ continuation: CheckedContinuation<Result<String, SharePeerError>, Never>) {
		let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
		connection.answer(for: constraints) { description, error in
			if let description {
				continuation.resume(returning: .success(description.sdp))
			} else {
				continuation.resume(returning: .failure(.negotiation(error.map(describe) ?? "no answer")))
			}
		}
	}

	static func add(_ candidate: RTCIceCandidate, on connection: RTCPeerConnection,
					_ continuation: CheckedContinuation<String?, Never>) {
		connection.add(candidate) { error in
			continuation.resume(returning: error.map(describe))
		}
	}

	private static func describe(_ error: Error) -> String {
		String(error.localizedDescription.prefix(200))
	}
}

/// Takes WebRTC's delegate callbacks on its threads, copies out what they carry, and hands that to
/// the peer on the main queue, in the order the callbacks came. Its one property is only touched on
/// the main actor, which is what makes it safe to share with WebRTC's threads.
private final class SharePeerObserver: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
	/// Set and read only on the main actor; nil once the peer has closed.
	@MainActor weak var peer: SharePeer?

	private func forward(_ work: @escaping @MainActor @Sendable (SharePeer) -> Void) {
		DispatchQueue.main.async { [weak self] in
			MainActor.assumeIsolated {
				guard let peer = self?.peer else { return }
				work(peer)
			}
		}
	}

	func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
	func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
	func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
	func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
	func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
	func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
	func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
	func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

	func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
		let line = candidate.sdp
		let mid = candidate.sdpMid
		let index = candidate.sdpMLineIndex
		forward { $0.gathered(line, sdpMid: mid, sdpMLineIndex: index) }
	}

	func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
		forward { $0.connectionChanged(newState) }
	}

	func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
		let state = dataChannel.readyState
		forward { $0.channelChanged(state) }
	}

	func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
		let data = buffer.data
		let isBinary = buffer.isBinary
		forward { $0.received(data, isBinary: isBinary) }
	}

	func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
		// `amount` is what was just sent, not what's left, so read what's left here.
		let buffered = dataChannel.bufferedAmount
		forward { $0.bufferChanged(buffered) }
	}
}
