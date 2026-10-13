//
//  NearbyShareSession+Link.swift
//  Rescriva (fork of Open Scanner)
//
//  One connection a Share Nearby session holds with a web page: its SharePeer, where it came
//  from (a relay room, or a scanned pairing code), what the page has proved or unlocked, and its
//  one download and one upload at a time (Docs/Rescriva-Share-Protocol.md §4).
//

import Foundation

@MainActor
final class NearbyShareLink {
	enum Origin: Equatable {
		/// A page that offered through the relay room `room`, as relay peer `peerID`.
		case relay(room: String, peerID: String)
		/// No-relay pairing with a page's QR code.
		case direct
	}

	/// Downloads a page may have waiting.
	static let maxQueue = 32
	/// Candidates kept while the answer is being made.
	static let maxPendingCandidates = 32

	let peer: SharePeer
	let origin: Origin
	/// True once the page's hello arrived (and proved itself when there's a secret).
	var ready = false
	/// It proved it holds the secret: every document is unlocked for it.
	var trusted = false
	/// Set when the session lets go of it; loops and late callbacks check this.
	var isClosed = false
	var name = ""
	var kind = "computer"
	/// Documents this page unlocked with their PINs.
	var unlocked: Set<String> = []
	/// Documents asked for and not yet sent, oldest first.
	var queue: [String] = []
	var isSending = false
	/// The download under way (its transfer id and the document it sends), and whether the page
	/// cancelled it.
	var outgoing: String?
	var outgoingDocument: String?
	var cancelledOutgoing: String?
	/// The page's upload: offered, then being received.
	var upload: NearbyShareUpload?

	private var answered = false
	private var pending: [Candidate] = []
	/// Remote candidates go to the peer one after another.
	private var chain: Task<Void, Never>?
	private var serial = 0

	private struct Candidate {
		let line: String
		let mid: String?
		let index: Int32
	}

	var id: UUID { peer.id }

	init(peer: SharePeer, origin: Origin) {
		self.peer = peer
		self.origin = origin
	}

	func canDownload(_ document: String) -> Bool {
		trusted || unlocked.contains(document)
	}

	/// A document stopped being shared.
	func forget(_ document: String) {
		unlocked.remove(document)
		queue.removeAll { $0 == document }
	}

	/// A transfer id for the next download: "d1", "d2" …
	func nextTransferID() -> String {
		serial += 1
		return "d\(serial)"
	}

	/// True when the page's hello `proof` matches this connection's secret and fingerprints, or
	/// when there's no secret to prove.
	func provesItself(_ proof: String?) -> Bool {
		guard let secret = peer.secret else { return true }
		guard let proof, let offer = peer.offerFingerprint, let answer = peer.answerFingerprint else { return false }
		let expected = ShareCodes.proof(secret: secret, role: "web", offerFingerprint: offer, answerFingerprint: answer)
		return NearbyShareInput.same(proof, expected)
	}

	/// The app's own proof for its hello; nil when there's no secret, or no fingerprints yet.
	func ownProof() -> String? {
		guard let secret = peer.secret, let offer = peer.offerFingerprint, let answer = peer.answerFingerprint else { return nil }
		return ShareCodes.proof(secret: secret, role: "app", offerFingerprint: offer, answerFingerprint: answer)
	}

	// MARK: Remote candidates

	/// A candidate from the page, held until the answer is applied.
	func addRemoteCandidate(_ line: String, sdpMid: String?, sdpMLineIndex: Int32) {
		let candidate = Candidate(line: line, mid: sdpMid, index: sdpMLineIndex)
		guard answered else {
			if pending.count < Self.maxPendingCandidates { pending.append(candidate) }
			return
		}
		apply(candidate)
	}

	/// The answer is applied: candidates can go to the peer now.
	func didAnswer() {
		answered = true
		let waiting = pending
		pending = []
		for candidate in waiting { apply(candidate) }
	}

	private func apply(_ candidate: Candidate) {
		let previous = chain
		let peer = peer
		chain = Task {
			await previous?.value
			await peer.addRemoteCandidate(candidate.line, sdpMid: candidate.mid, sdpMLineIndex: candidate.index)
		}
	}

	/// Ends the upload, deleting what arrived. Returns it, for its transfer row.
	@discardableResult
	func abortUpload() -> NearbyShareUpload? {
		guard let upload else { return nil }
		self.upload = nil
		upload.discard()
		return upload
	}
}
