//
//  NearbyShareSession.swift
//  Rescriva (fork of Open Scanner)
//
//  One Share Nearby session: the documents on offer with their PINs, the web pages connected to
//  them, downloads to those pages and uploads from them. Pages arrive two ways:
//
//      relay      a page in the "auto" room (same network: names visible, a PIN per document)
//                 or in roomId(share key) (opened from this screen's QR code: trusted)
//      pairing    this device scanned a page's code: a direct connection with the built-in
//                 certificate, and roomId(secret) on the relay too; the first to open wins
//
//  The wire protocol is ShareSite/PROTOCOL.md, and ShareSite/assets/peer.js is the page's side of
//  every exchange. Docs/Nearby-Share-App-Design.md has the rules this follows.
//

import CoreData
import Foundation
import Observation
import UIKit

/// Something to share nearby.
enum NearbyShareItem: Hashable {
	/// Exported as a searchable PDF.
	case scan(Scan)
	/// A PDF Files item, in its current version.
	case pdf(UUID)
	/// A file that's already made, such as an export.
	case file(URL, name: String)
}

@MainActor
@Observable
final class NearbyShareSession {
	struct SharedDocument: Identifiable {
		enum State: Equatable { case preparing, ready, failed(String) }
		let id: String
		let source: NearbyShareItem
		var name: String
		var size: Int64
		var pin: String
		var state: State
	}

	struct Device: Identifiable {
		let id: UUID
		var name: String
		var kind: String
		var trusted: Bool
	}

	struct IncomingOffer: Identifiable {
		let id: String
		let deviceName: String
		let name: String
		let size: Int64
		let type: String
	}

	struct Transfer: Identifiable {
		enum Direction { case sending, receiving }
		enum State: Equatable { case moving, done, failed(String) }
		let id: UUID
		let direction: Direction
		let name: String
		let deviceName: String
		var done: Int64
		let total: Int64
		var state: State
	}

	enum RelayState: Equatable { case off, connecting, open, unavailable }
	enum PairingState: Equatable { case idle, connecting, showCode(String), connected(String), failed(String) }

	private(set) var documents: [SharedDocument] = []
	private(set) var devices: [Device] = []
	private(set) var incoming: [IncomingOffer] = []
	private(set) var transfers: [Transfer] = []
	private(set) var relayState: RelayState = .off
	private(set) var pairing: PairingState = .idle
	private(set) var isRunning = false
	/// share.rescriva.com/#k=…, for the QR code; nil until started.
	private(set) var openLink: URL?
	/// Something received and saved: for a toast.
	var onSaved: ((String) -> Void)?

	// MARK: Limits

	private static let maxLinks = 48
	private static let maxDocuments = 200
	private static let maxTransfersKept = 100
	private static let maxSDPBytes = 64 * 1024
	private static let maxCandidateBytes = 1024
	private static let maxRelayPeerID = 64
	private static let maxDownloadsPerRun = 256
	private static let progressStep: Int64 = 256 * 1024
	/// A relay connection that hasn't opened by now isn't going to (peer.js gives up at 25 s).
	private static let connectTimeout: Duration = .seconds(30)
	private static let helloTimeout: Duration = .seconds(10)
	/// Time for a last message to leave before its connection closes.
	private static let closeDelay: Duration = .milliseconds(300)
	/// How long a won pairing keeps its relay room, so the page sees the hello first.
	private static let pairingRoomLinger: Duration = .seconds(2)
	private static let codeRetry: Duration = .seconds(2)
	private static let codeRetries = 2
	private static let deviceKinds: Set<String> = ["phone", "tablet", "computer", "iphone", "ipad", "mac"]

	// MARK: State behind the scenes

	private struct RelayRoom {
		let relay: ShareRelay
		/// The secret pages in this room hold, or nil for "auto".
		let secret: Data?
		var status: ShareRelay.Status
	}

	/// A scanned page code that hasn't connected yet.
	private struct PairingAttempt {
		/// Tells this attempt from a later one with the same code, for its timeout.
		let id = UUID()
		let secret: Data
		let room: String
		var direct: UUID?
	}

	private let library: PDFLibrary
	private let context: NSManagedObjectContext
	/// What's shared. It outlives stop(); each start() makes fresh documents (new ids and PINs) from it.
	@ObservationIgnored private var sources: [NearbyShareItem]
	@ObservationIgnored private var sessionID = ""
	/// Bumped by start() and stop(), so work from an earlier session finds it's stale.
	@ObservationIgnored private var generation = 0
	@ObservationIgnored private var folder: URL?
	@ObservationIgnored private var files: [String: NearbySharePreparedFile] = [:]
	@ObservationIgnored private var locks: [String: NearbySharePINLock] = [:]
	/// Every PIN given out this session, so none comes back.
	@ObservationIgnored private var usedPINs: Set<String> = []
	@ObservationIgnored private var links: [UUID: NearbyShareLink] = [:]
	@ObservationIgnored private var relays: [String: RelayRoom] = [:]
	@ObservationIgnored private var attempt: PairingAttempt?
	/// The connection a pairing made, while `pairing` is `.connected`.
	@ObservationIgnored private var paired: UUID?
	/// A pairing asked for before start().
	@ObservationIgnored private var pendingOffer: SharePairingOffer?

	init(items: [NearbyShareItem], library: PDFLibrary, context: NSManagedObjectContext) {
		self.library = library
		self.context = context
		self.sources = Self.unique(items, limit: Self.maxDocuments)
	}

	/// With `PDFLibrary.shared`. (A default argument can't name it: it belongs to the main actor.)
	convenience init(items: [NearbyShareItem], context: NSManagedObjectContext) {
		self.init(items: items, library: .shared, context: context)
	}

	// MARK: Lifecycle

	/// A new session: session id, share key, PINs. Joins the relay rooms (auto + roomId(key)) and
	/// prepares the files. Does nothing while it's running.
	func start() {
		guard !isRunning else { return }
		isRunning = true
		generation += 1
		sessionID = ShareCodes.newSessionID()
		let key = ShareCodes.newSecret()
		openLink = Self.openLink(for: key)
		folder = NearbyShareFiles.sessionFolder(sessionID)
		usedPINs = []
		transfers = []
		for item in sources { addDocument(for: item) }
		joinRelays(key: key)
		if let offer = pendingOffer {
			pendingOffer = nil
			pair(with: offer)
		}
	}

	/// Sends docs [] and bye, closes every peer and relay, deletes temp files. Idempotent.
	func stop() {
		guard isRunning else { return }
		isRunning = false
		generation += 1
		sayGoodbye()
		for room in relays.values { room.relay.stop() }
		relays = [:]
		attempt = nil
		paired = nil
		pendingOffer = nil
		NearbyShareFiles.remove(folder)
		folder = nil
		files = [:]
		locks = [:]
		clearPublishedState()
	}

	private func clearPublishedState() {
		documents = []
		devices = []
		incoming = []
		for index in transfers.indices where transfers[index].state == .moving {
			transfers[index].state = .failed(String(localized: "Sharing stopped."))
		}
		relayState = .off
		pairing = .idle
		openLink = nil
	}

	/// Every page hears that sharing ended; the connections close a moment later.
	private func sayGoodbye() {
		let closing = Array(links.values)
		links = [:]
		for link in closing {
			link.isClosed = true
			link.abortUpload()
			if link.ready { link.peer.send(.docs([])) }
			link.peer.send(.bye)
		}
		closeLater(closing.map(\.peer))
	}

	// MARK: Documents

	func add(_ items: [NearbyShareItem]) {
		for item in Self.unique(items, limit: Self.maxDocuments) where !sources.contains(item) {
			guard sources.count < Self.maxDocuments else {
				print("Rescriva: Share Nearby shares at most \(Self.maxDocuments) documents")
				return
			}
			sources.append(item)
			if isRunning { addDocument(for: item) }
		}
	}

	func remove(_ document: SharedDocument) {
		sources.removeAll { $0 == document.source }
		guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
		documents.remove(at: index)
		locks[document.id] = nil
		if let file = files.removeValue(forKey: document.id) {
			NearbyShareFiles.remove(file.url.deletingLastPathComponent())
		}
		for link in links.values { link.forget(document.id) }
		broadcastDocs()
	}

	/// A new document for `item`, with its own id and PIN, and its file being made.
	private func addDocument(for item: NearbyShareItem) {
		let id = newDocumentID()
		let name = NearbyShareFiles.provisionalName(for: item, library: library)
		documents.append(SharedDocument(id: id, source: item, name: name, size: 0, pin: newPIN(), state: .preparing))
		locks[id] = NearbySharePINLock()
		guard let folder else {
			print("Rescriva: Share Nearby has no folder for its files")
			return
		}
		let generation = generation
		let library = library
		Task { [weak self] in
			let result = await NearbyShareFiles.prepare(item, into: folder.appendingPathComponent(id, isDirectory: true),
														library: library)
			guard let self else {
				NearbyShareFiles.remove(folder)
				return
			}
			self.prepared(id, result, generation: generation, sessionFolder: folder)
		}
	}

	private func prepared(_ id: String, _ result: Result<NearbySharePreparedFile, Error>, generation: Int,
						  sessionFolder: URL) {
		guard generation == self.generation, let index = documents.firstIndex(where: { $0.id == id }) else {
			// The session stopped, or the document was removed, while its file was being made.
			let stale = generation == self.generation ? sessionFolder.appendingPathComponent(id) : sessionFolder
			NearbyShareFiles.remove(stale)
			return
		}
		switch result {
		case .success(let file):
			files[id] = file
			documents[index].name = file.name
			documents[index].size = file.size
			documents[index].state = .ready
			broadcastDocs()
		case .failure(let error):
			print("Rescriva: Share Nearby couldn't prepare “\(documents[index].name)”: \(error)")
			documents[index].state = .failed(NearbyShareFiles.problem(error))
		}
	}

	private func newDocumentID() -> String {
		for _ in 0..<8 {
			let id = ShareCodes.newSessionID()
			if !documents.contains(where: { $0.id == id }) { return id }
		}
		return UUID().uuidString
	}

	private func newPIN() -> String {
		let pin = ShareCodes.newPIN(avoiding: usedPINs)
		usedPINs.insert(pin)
		return pin
	}

	/// The index of a document pages can have now.
	private func readyIndex(of id: String) -> Int? {
		guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].state == .ready,
			  files[id] != nil else { return nil }
		return index
	}

	/// The list `link`'s page sees: ready documents, each marked unlocked or not.
	private func summaries(for link: NearbyShareLink) -> [ShareDocSummary] {
		documents.compactMap { document in
			guard document.state == .ready, let file = files[document.id] else { return nil }
			return ShareDocSummary(id: document.id, name: document.name, size: file.size, type: file.type,
								   unlocked: link.canDownload(document.id))
		}
	}

	private func sendDocs(to link: NearbyShareLink) {
		link.peer.send(.docs(summaries(for: link)))
	}

	private func broadcastDocs() {
		for link in links.values where link.ready && !link.isClosed {
			sendDocs(to: link)
		}
	}

	// MARK: Relay

	private func joinRelays(key: Data) {
		guard let url = NearbyShareConfig.relayURL else {
			relayState = .off
			return
		}
		joinRelay(url, room: "auto", secret: nil)
		joinRelay(url, room: ShareCodes.roomID(secret: key), secret: key)
	}

	private func joinRelay(_ url: URL, room: String, secret: Data?) {
		guard relays[room] == nil else { return }
		let relay = ShareRelay(url: url, room: room) { [weak self] event in
			self?.relayEvent(event, in: room)
		}
		relays[room] = RelayRoom(relay: relay, secret: secret, status: relay.status)
		relay.start()
		updateRelayState()
	}

	private func leaveRelay(_ room: String) {
		guard let entry = relays.removeValue(forKey: room) else { return }
		entry.relay.stop()
		updateRelayState()
	}

	private func relayEvent(_ event: ShareRelay.Event, in room: String) {
		guard isRunning, relays[room] != nil else { return }
		switch event {
		case .status(let status):
			relays[room]?.status = status
			updateRelayState()
			// After the relay has finished with this event, since failing a pairing leaves its room.
			schedule(after: .zero) { [weak self] in self?.recheckRelayPairing() }
		case .peers, .join:
			break // Pages make the offers.
		case .leave(let peerID):
			relayPeerLeft(peerID, room: room)
		case .signal(let from, let signal):
			relaySignal(signal, from: from, room: room)
		}
	}

	private func updateRelayState() {
		let statuses = relays.values.map(\.status)
		if statuses.isEmpty {
			relayState = .off
		} else if statuses.contains(.open) {
			relayState = .open
		} else if statuses.contains(.connecting) {
			relayState = .connecting
		} else {
			relayState = .unavailable
		}
	}

	private func relaySignal(_ signal: ShareSignal, from peerID: String, room: String) {
		switch signal {
		case .offer(let sdp):
			answer(sdp, from: peerID, room: room)
		case .answer:
			print("Rescriva: Share Nearby ignored an answer from the relay; pages make the offers")
		case .candidate(let line, let mid, let index):
			guard line.utf8.count <= Self.maxCandidateBytes, let link = link(relayPeer: peerID, room: room) else { return }
			link.addRemoteCandidate(line, sdpMid: mid, sdpMLineIndex: index)
		}
	}

	/// An open connection carries on without the relay; the page says bye when it's done.
	private func relayPeerLeft(_ peerID: String, room: String) {
		guard let link = link(relayPeer: peerID, room: room), !link.peer.isOpen else { return }
		drop(link)
	}

	private func link(relayPeer peerID: String, room: String) -> NearbyShareLink? {
		let origin = NearbyShareLink.Origin.relay(room: room, peerID: peerID)
		return links.values.first { $0.origin == origin }
	}

	/// A page in `room` offered a connection: answer it through the relay.
	private func answer(_ sdp: String, from peerID: String, room: String) {
		guard sdp.utf8.count <= Self.maxSDPBytes, (1...Self.maxRelayPeerID).contains(peerID.utf8.count),
			  let entry = relays[room] else { return }
		if let old = link(relayPeer: peerID, room: room) { drop(old) } // The page started over.
		let origin = NearbyShareLink.Origin.relay(room: room, peerID: peerID)
		guard let link = makeLink(secret: entry.secret, origin: origin, builtInCertificate: false) else { return }
		let generation = generation
		Task { [weak self] in
			do {
				let answer = try await link.peer.answer(offer: sdp)
				self?.answered(link, with: answer, generation: generation)
			} catch {
				print("Rescriva: Share Nearby couldn't answer a page's offer: \(error)")
				self?.drop(link)
			}
		}
		schedule(after: Self.connectTimeout) { [weak self] in
			guard !link.isClosed, !link.peer.isOpen else { return }
			self?.drop(link)
		}
	}

	private func answered(_ link: NearbyShareLink, with answer: String, generation: Int) {
		guard generation == self.generation, !link.isClosed, case .relay(let room, let peerID) = link.origin,
			  let relay = relays[room]?.relay else { return }
		relay.signal(to: peerID, .answer(answer))
		link.didAnswer()
	}

	// MARK: Connections

	private func makeLink(secret: Data?, origin: NearbyShareLink.Origin, builtInCertificate: Bool) -> NearbyShareLink? {
		guard links.count < Self.maxLinks else {
			print("Rescriva: Share Nearby is at its limit of \(Self.maxLinks) connections")
			return nil
		}
		let peer = SharePeer(secret: secret, builtInCertificate: builtInCertificate) { [weak self] peer, event in
			self?.peerEvent(event, from: peer)
		}
		let link = NearbyShareLink(peer: peer, origin: origin)
		links[link.id] = link
		return link
	}

	private func peerEvent(_ event: SharePeer.Event, from peer: SharePeer) {
		guard let link = links[peer.id] else { return }
		switch event {
		case .localCandidate(let line, let mid, let index):
			sendCandidate(line, sdpMid: mid, sdpMLineIndex: index, for: link)
		case .open:
			opened(link)
		case .text(let data):
			received(data, on: link)
		case .binary(let data):
			receivedChunk(data, on: link)
		case .closed:
			drop(link)
		}
	}

	/// Relay connections trickle their candidates to the page; a direct one keeps them for the code.
	private func sendCandidate(_ line: String, sdpMid: String?, sdpMLineIndex: Int32, for link: NearbyShareLink) {
		guard case .relay(let room, let peerID) = link.origin, let relay = relays[room]?.relay else { return }
		relay.signal(to: peerID, .candidate(line, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex))
	}

	/// Lets go of `link`: its device, its upload and its pairing. With `sayBye`, the page hears so
	/// first. Safe to call more than once.
	private func drop(_ link: NearbyShareLink, sayBye: Bool = false) {
		guard links.removeValue(forKey: link.id) != nil else { return }
		link.isClosed = true
		if sayBye, link.peer.isOpen {
			link.peer.send(.bye)
			closeLater([link.peer])
		} else {
			link.peer.close()
		}
		if let upload = link.abortUpload() {
			forgetUpload(upload, problem: String(localized: "The connection closed."))
		}
		devices.removeAll { $0.id == link.id }
		pairingLinkClosed(link)
	}

	private func closeLater(_ peers: [SharePeer]) {
		guard !peers.isEmpty else { return }
		Task {
			try? await Task.sleep(for: Self.closeDelay)
			for peer in peers { peer.close() }
		}
	}

	/// Runs `work` after `delay`, unless the session stopped or started again meanwhile.
	private func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) {
		let generation = generation
		Task { [weak self] in
			try? await Task.sleep(for: delay)
			guard let self, self.generation == generation else { return }
			work()
		}
	}

	// MARK: Messages

	/// The channel is open: say hello (with a proof when there's a secret), then wait for the page's.
	private func opened(_ link: NearbyShareLink) {
		let proof = link.ownProof()
		guard link.peer.secret == nil || proof != nil else {
			print("Rescriva: Share Nearby had no fingerprints to prove itself with, so it closed the connection")
			drop(link, sayBye: true)
			return
		}
		link.peer.send(.hello(name: ShareDevice.name, device: ShareDevice.kind, session: sessionID, proof: proof))
		schedule(after: Self.helloTimeout) { [weak self] in
			guard !link.ready, !link.isClosed else { return }
			print("Rescriva: Share Nearby closed a connection whose page never said hello")
			self?.drop(link, sayBye: true)
		}
	}

	private func received(_ data: Data, on link: NearbyShareLink) {
		guard let message = ShareInbound(json: data) else { return }
		switch message {
		case .hello(let name, let device, let proof):
			greeted(link, name: name, device: device, proof: proof)
		case .bye:
			drop(link)
		default:
			// The app answers nothing until the page's hello.
			guard link.ready else { return }
			request(message, from: link)
		}
	}

	private func request(_ message: ShareInbound, from link: NearbyShareLink) {
		switch message {
		case .unlock(let id, let pin): unlock(id, pin: pin, for: link)
		case .get(let id): get(id, for: link)
		case .send(let xfer, let name, let size, let type): offered(xfer, name: name, size: size, type: type, by: link)
		case .end(let xfer): uploadEnded(xfer, on: link)
		case .cancel(let xfer): cancelled(xfer, on: link)
		case .hello, .bye: break
		}
	}

	/// The page's hello. With a secret it must prove it holds it, or the connection ends.
	private func greeted(_ link: NearbyShareLink, name: String, device: String, proof: String?) {
		guard !link.ready else { return }
		guard link.provesItself(proof) else {
			badProof(link)
			return
		}
		link.ready = true
		link.trusted = link.peer.secret != nil
		let clipped = String(name.prefix(64))
		link.name = clipped.isEmpty ? String(localized: "Web browser") : clipped
		link.kind = Self.deviceKinds.contains(device) ? device : "computer"
		devices.append(Device(id: link.id, name: link.name, kind: link.kind, trusted: link.trusted))
		sendDocs(to: link)
		if isPairing(link) { pairingConnected(link) }
	}

	private func badProof(_ link: NearbyShareLink) {
		print("Rescriva: Share Nearby closed a connection whose proof didn't match")
		let wasPairing = isPairing(link)
		drop(link, sayBye: true)
		guard wasPairing else { return }
		endPairingAttempt()
		pairing = .failed(String(localized: "The computer couldn't prove it's the one whose code you scanned. Make a new code on it and try again."))
	}

	// MARK: PINs

	/// Five wrong tries on a document, from any pages, replace its PIN and start a cooldown.
	private func unlock(_ id: String, pin: String, for link: NearbyShareLink) {
		guard let index = readyIndex(of: id) else {
			deny(id, "gone", to: link)
			return
		}
		guard !link.canDownload(id) else {
			confirmUnlock(id, for: link)
			return
		}
		let now = Date.now
		var lock = locks[id] ?? NearbySharePINLock()
		if let wait = lock.secondsLeft(at: now) {
			link.peer.send(.denied(id: id, reason: "cooldown", retryIn: wait, left: nil))
			return
		}
		if NearbyShareInput.isPIN(pin), NearbyShareInput.same(pin, documents[index].pin) {
			link.unlocked.insert(id)
			confirmUnlock(id, for: link)
			return
		}
		let outcome = lock.recordWrong(at: now)
		locks[id] = lock
		if outcome.replacesPIN { documents[index].pin = newPIN() }
		link.peer.send(.denied(id: id, reason: "wrong", retryIn: outcome.retryIn, left: outcome.left))
	}

	/// "unlocked", then the list with it unlocked: peer.js waits for the first and shows the second.
	private func confirmUnlock(_ id: String, for link: NearbyShareLink) {
		link.peer.send(.unlocked(id: id))
		sendDocs(to: link)
	}

	private func deny(_ id: String, _ reason: String, to link: NearbyShareLink) {
		link.peer.send(.denied(id: id, reason: reason, retryIn: nil, left: nil))
	}

	// MARK: Downloads

	private func get(_ id: String, for link: NearbyShareLink) {
		guard readyIndex(of: id) != nil else {
			deny(id, "gone", to: link)
			return
		}
		guard link.canDownload(id) else {
			deny(id, "locked", to: link)
			return
		}
		guard link.queue.count < NearbyShareLink.maxQueue else {
			print("Rescriva: Share Nearby ignored a download past a page's queue limit")
			return
		}
		link.queue.append(id)
		pumpDownloads(for: link)
	}

	/// Sends `link`'s queued downloads one at a time.
	private func pumpDownloads(for link: NearbyShareLink) {
		guard !link.isSending, !link.isClosed, !link.queue.isEmpty else { return }
		link.isSending = true
		Task { [weak self] in
			await self?.runDownloads(for: link)
			link.isSending = false
			// A long run stops at its limit; whatever is still queued starts a fresh one.
			self?.pumpDownloads(for: link)
		}
	}

	private func runDownloads(for link: NearbyShareLink) async {
		for _ in 0..<Self.maxDownloadsPerRun {
			guard isRunning, !link.isClosed, !link.queue.isEmpty else { return }
			let id = link.queue.removeFirst()
			await sendDocument(id, over: link)
		}
	}

	/// `file`, the bytes in binary chunks, then `end`; or `cancel` when it stops part way.
	private func sendDocument(_ id: String, over link: NearbyShareLink) async {
		guard let index = readyIndex(of: id), let file = files[id] else {
			deny(id, "gone", to: link)
			return
		}
		guard link.canDownload(id) else {
			deny(id, "locked", to: link)
			return
		}
		let size = NearbyShareFiles.size(of: file.url) ?? file.size
		let xfer = link.nextTransferID()
		let transfer = Transfer(id: UUID(), direction: .sending, name: documents[index].name, deviceName: link.name,
								done: 0, total: size, state: .moving)
		addTransfer(transfer)
		link.outgoing = xfer
		link.outgoingDocument = id
		link.peer.send(.file(id: id, xfer: xfer, name: transfer.name, size: size, type: file.type))
		let problem = await stream(file.url, size: size, xfer: xfer, over: link, transfer: transfer.id)
		link.outgoing = nil
		link.outgoingDocument = nil
		finishSending(xfer, problem: problem, over: link, transfer: transfer.id)
	}

	/// Sends the first `size` bytes of `url`, keeping the channel's buffer under its high-water
	/// mark. Nil when every byte went; otherwise what stopped it.
	private func stream(_ url: URL, size: Int64, xfer: String, over link: NearbyShareLink, transfer: UUID) async -> String? {
		let unreadable = String(localized: "Rescriva couldn't read the file.")
		let handle: FileHandle
		do {
			handle = try FileHandle(forReadingFrom: url)
		} catch {
			print("Rescriva: Share Nearby couldn't open a shared file: \(error)")
			return unreadable
		}
		defer { try? handle.close() }
		let chunk = Int64(NearbyShareConfig.chunkSize)
		var sent: Int64 = 0
		for _ in 0...(size / chunk + 1) {
			if sent >= size { return nil }
			await link.peer.waitForRoom()
			if let problem = interruption(of: link, xfer: xfer) { return problem }
			guard let data = try? handle.read(upToCount: Int(min(chunk, size - sent))), !data.isEmpty else { return unreadable }
			guard link.peer.sendBinary(data) else { return String(localized: "The connection closed.") }
			sent += Int64(data.count)
			showProgress(transfer, done: sent)
		}
		return sent >= size ? nil : unreadable
	}

	/// What stops a download part way, checked before each chunk: the connection ending, the page
	/// cancelling, or the document no longer being shared with this page (removed here).
	private func interruption(of link: NearbyShareLink, xfer: String) -> String? {
		if !isRunning || link.isClosed || !link.peer.isOpen { return String(localized: "The connection closed.") }
		if link.cancelledOutgoing == xfer { return String(localized: "Cancelled on the other device.") }
		if let document = link.outgoingDocument, readyIndex(of: document) == nil || !link.canDownload(document) {
			return String(localized: "You stopped sharing it.")
		}
		return nil
	}

	private func finishSending(_ xfer: String, problem: String?, over link: NearbyShareLink, transfer: UUID) {
		guard let problem else {
			link.peer.send(.end(xfer: xfer))
			updateTransfer(transfer, state: .done)
			return
		}
		if link.cancelledOutgoing != xfer, !link.isClosed { link.peer.send(.cancel(xfer: xfer)) }
		link.cancelledOutgoing = nil
		updateTransfer(transfer, state: .failed(problem))
	}

	// MARK: Uploads

	/// A page asks to send a file. A PDF or an image waits in `incoming` for Accept or Decline.
	private func offered(_ xfer: String, name: String, size: Int64, type: String, by link: NearbyShareLink) {
		guard link.upload == nil else {
			link.peer.send(.decline(xfer: xfer, reason: "busy"))
			return
		}
		let type = type.lowercased()
		guard NearbyShareInput.acceptsUpload(type: type) else {
			link.peer.send(.decline(xfer: xfer, reason: "type"))
			return
		}
		let limit = type == "application/pdf" ? NearbyShareConfig.maxIncomingBytes : NearbyShareConfig.maxIncomingImageBytes
		guard size > 0, size <= limit else {
			link.peer.send(.decline(xfer: xfer, reason: "size"))
			return
		}
		let fileName = NearbyShareInput.fileName(name, fallback: String(localized: "Received file"))
		let offer = IncomingOffer(id: UUID().uuidString, deviceName: link.name, name: fileName, size: size, type: type)
		link.upload = NearbyShareUpload(offerID: offer.id, xfer: xfer, name: fileName, size: size, type: type)
		incoming.append(offer)
	}

	func accept(_ offer: IncomingOffer) {
		incoming.removeAll { $0.id == offer.id }
		guard let link = link(offering: offer.id), let upload = link.upload, !upload.isReceiving else { return }
		guard upload.open() else {
			link.upload = nil
			link.peer.send(.decline(xfer: upload.xfer, reason: nil))
			return
		}
		let transfer = Transfer(id: UUID(), direction: .receiving, name: upload.name, deviceName: link.name,
								done: 0, total: upload.size, state: .moving)
		upload.transferID = transfer.id
		addTransfer(transfer)
		link.peer.send(.accept(xfer: upload.xfer))
	}

	func decline(_ offer: IncomingOffer) {
		incoming.removeAll { $0.id == offer.id }
		guard let link = link(offering: offer.id), let upload = link.upload, !upload.isReceiving else { return }
		link.upload = nil
		link.peer.send(.decline(xfer: upload.xfer, reason: nil))
	}

	private func link(offering offerID: String) -> NearbyShareLink? {
		links.values.first { $0.upload?.offerID == offerID }
	}

	private func receivedChunk(_ data: Data, on link: NearbyShareLink) {
		guard link.ready, let upload = link.upload, upload.isReceiving else { return }
		guard upload.write(data) else {
			failUpload(on: link, problem: String(localized: "The file didn't arrive whole."), reply: .cancel(xfer: upload.xfer))
			return
		}
		if let id = upload.transferID { showProgress(id, done: upload.received) }
	}

	/// The last chunk is in: check the size, then bring the file into the Library.
	private func uploadEnded(_ xfer: String, on link: NearbyShareLink) {
		guard let upload = link.upload, upload.xfer == xfer, upload.isReceiving else { return }
		link.upload = nil
		guard let url = upload.finish() else {
			link.peer.send(.saved(xfer: xfer, ok: false))
			if let id = upload.transferID {
				updateTransfer(id, state: .failed(String(localized: "The file didn't arrive whole.")))
			}
			return
		}
		save(url, upload: upload, from: link)
	}

	/// Imports with background time, so leaving the app mid-import doesn't lose the file.
	private func save(_ url: URL, upload: NearbyShareUpload, from link: NearbyShareLink) {
		let library = library
		let context = context
		BackgroundTime.protect("Share Nearby import") { [weak self] in
			let ok = await NearbyShareFiles.importReceived(url, name: upload.name, type: upload.type,
															library: library, context: context)
			NearbyShareFiles.remove(url.deletingLastPathComponent())
			self?.saved(upload, ok: ok, from: link)
		}
	}

	private func saved(_ upload: NearbyShareUpload, ok: Bool, from link: NearbyShareLink) {
		if !link.isClosed { link.peer.send(.saved(xfer: upload.xfer, ok: ok)) }
		if let id = upload.transferID {
			updateTransfer(id, state: ok ? .done : .failed(String(localized: "Rescriva couldn't open the file.")))
		}
		if ok { onSaved?(upload.name) }
	}

	private func failUpload(on link: NearbyShareLink, problem: String, reply: ShareOutbound?) {
		guard let upload = link.abortUpload() else { return }
		if let reply, !link.isClosed { link.peer.send(reply) }
		forgetUpload(upload, problem: problem)
	}

	private func forgetUpload(_ upload: NearbyShareUpload, problem: String) {
		incoming.removeAll { $0.id == upload.offerID }
		if let id = upload.transferID { updateTransfer(id, state: .failed(problem)) }
	}

	/// The page cancelled a download it asked for, or an upload it offered.
	private func cancelled(_ xfer: String, on link: NearbyShareLink) {
		if link.outgoing == xfer { link.cancelledOutgoing = xfer }
		if link.upload?.xfer == xfer {
			failUpload(on: link, problem: String(localized: "Cancelled on the other device."), reply: nil)
		}
	}

	// MARK: Activity

	private func addTransfer(_ transfer: Transfer) {
		transfers.append(transfer)
		guard transfers.count > Self.maxTransfersKept,
			  let oldest = transfers.firstIndex(where: { $0.state != .moving }) else { return }
		transfers.remove(at: oldest)
	}

	private func updateTransfer(_ id: UUID, state: Transfer.State) {
		guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
		if state == .done { transfers[index].done = transfers[index].total }
		transfers[index].state = state
	}

	/// Progress a step at a time, so the screen isn't redrawn for every chunk.
	private func showProgress(_ id: UUID, done: Int64) {
		guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
		guard done - transfers[index].done >= Self.progressStep || done >= transfers[index].total else { return }
		transfers[index].done = done
	}

	// MARK: Pairing

	/// No-relay pairing with a scanned or pasted page code. Also joins roomId(secret) when there's a
	/// relay; whichever opens first wins.
	func pair(with offer: SharePairingOffer) {
		guard isRunning else {
			pendingOffer = offer
			return
		}
		endPairingAttempt()
		if let link = links.values.first(where: { $0.ready && $0.peer.secret == offer.secret }) {
			paired = link.id // Already paired with this code.
			pairing = .connected(link.name)
			return
		}
		paired = nil
		let room = ShareCodes.roomID(secret: offer.secret)
		attempt = PairingAttempt(secret: offer.secret, room: room)
		pairing = .connecting
		startDirect(offer)
		guard attempt != nil else { return }
		if let url = NearbyShareConfig.relayURL { joinRelay(url, room: room, secret: offer.secret) }
		scheduleCode(for: offer.secret, triesLeft: Self.codeRetries, after: NearbyShareConfig.codeDelay)
	}

	private func startDirect(_ offer: SharePairingOffer) {
		guard let link = makeLink(secret: offer.secret, origin: .direct, builtInCertificate: true) else {
			attempt = nil
			pairing = .failed(String(localized: "Too many connections are open. Close one and try again."))
			return
		}
		attempt?.direct = link.id
		Task { [weak self] in
			do {
				try await link.peer.connect(to: offer)
			} catch {
				print("Rescriva: Share Nearby couldn't start the connection to the computer: \(error)")
				self?.drop(link)
			}
		}
	}

	private func scheduleCode(for secret: Data, triesLeft: Int, after delay: Duration) {
		schedule(after: delay) { [weak self] in
			self?.showCode(for: secret, triesLeft: triesLeft)
		}
	}

	/// The direct connection hasn't opened: show a code for the page to type, so it starts the
	/// checks itself. Candidates still gathering get a couple more looks.
	private func showCode(for secret: Data, triesLeft: Int) {
		guard let attempt, attempt.secret == secret, pairing == .connecting, let id = attempt.direct,
			  let link = links[id], !link.peer.isOpen else { return }
		if let code = Self.connectionCode(for: link.peer) {
			pairing = .showCode(code)
		} else if triesLeft > 0 {
			scheduleCode(for: secret, triesLeft: triesLeft - 1, after: Self.codeRetry)
		} else {
			pairing = .failed(String(localized: "This device has no Wi-Fi or hotspot address the computer can reach. Join the same network and try again."))
		}
	}

	/// "80JB-N1HG" for the best local IPv4 candidate the connection gathered, or nil for none.
	private static func connectionCode(for peer: SharePeer) -> String? {
		let candidates = peer.localCandidates.compactMap { ShareSDP.hostCandidate($0) }
		guard let best = ShareNetwork.codeCandidate(from: candidates, interfaces: ShareNetwork.interfaceNames()),
			  let code = ShareCodes.connectionCode(ipv4: best.address, port: best.port) else { return nil }
		return ShareCodes.grouped(code)
	}

	private func isPairing(_ link: NearbyShareLink) -> Bool {
		guard let attempt, let secret = link.peer.secret else { return false }
		return secret == attempt.secret
	}

	/// One of the pairing's paths opened and proved itself: keep it and close the other.
	private func pairingConnected(_ winner: NearbyShareLink) {
		guard let attempt else { return }
		self.attempt = nil
		paired = winner.id
		pairing = .connected(winner.name)
		closePaths(of: attempt, except: winner)
	}

	/// Abandons a pairing that hasn't connected.
	private func endPairingAttempt() {
		guard let attempt else { return }
		self.attempt = nil
		closePaths(of: attempt, except: nil)
		pairing = .idle
	}

	/// Drops the attempt's connections that haven't said hello, and leaves its relay room (a
	/// moment later when one won, so its hello reaches the page before the relay's "leave").
	private func closePaths(of attempt: PairingAttempt, except winner: NearbyShareLink?) {
		let losers = links.values.filter { $0 !== winner && !$0.ready && $0.peer.secret == attempt.secret }
		for link in losers { drop(link) }
		guard winner != nil else {
			leaveRelay(attempt.room)
			return
		}
		schedule(after: Self.pairingRoomLinger) { [weak self] in
			guard self?.attempt?.room != attempt.room else { return }
			self?.leaveRelay(attempt.room)
		}
	}

	/// Keeps `pairing` right when one of its connections closes.
	private func pairingLinkClosed(_ link: NearbyShareLink) {
		if link.id == paired {
			paired = nil
			pairing = .idle
			return
		}
		guard var current = attempt, link.id == current.direct else { return }
		current.direct = nil
		attempt = current
		guard let room = relays[current.room], room.status != .unavailable else {
			pairingFailed()
			return
		}
		// The relay may still bring it, for a while.
		pairing = .connecting
		let id = current.id
		schedule(after: Self.connectTimeout) { [weak self] in
			guard let self, let attempt = self.attempt, attempt.id == id, attempt.direct == nil,
				  self.pairing == .connecting else { return }
			print("Rescriva: Share Nearby's pairing never came through the relay")
			self.pairingFailed()
		}
	}

	/// A pairing that's down to its relay room fails once the relay can't be reached.
	private func recheckRelayPairing() {
		guard let attempt, attempt.direct == nil, pairing == .connecting else { return }
		if let room = relays[attempt.room], room.status != .unavailable { return }
		pairingFailed()
	}

	/// Gives up on the pairing under way: its paths close, its room is left, and the screen says so.
	private func pairingFailed() {
		guard let attempt else { return }
		self.attempt = nil
		closePaths(of: attempt, except: nil)
		pairing = .failed(String(localized: "Couldn't reach the computer. Make a new code on it and scan that."))
	}

	// MARK: Helpers

	private static func openLink(for key: Data) -> URL? {
		guard var components = URLComponents(url: NearbyShareConfig.siteURL, resolvingAgainstBaseURL: false) else { return nil }
		components.fragment = "k=" + ShareCodes.base64URL(key)
		return components.url
	}

	private static func unique(_ items: [NearbyShareItem], limit: Int) -> [NearbyShareItem] {
		var seen = Set<NearbyShareItem>()
		var out: [NearbyShareItem] = []
		for item in items where seen.insert(item).inserted {
			guard out.count < limit else { break }
			out.append(item)
		}
		return out
	}
}
