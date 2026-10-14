# Share Nearby: app design

The Swift side of Share Nearby. The wire format is `Docs/Rescriva-Share-Protocol.md`; the background and
decisions are in `Docs/Nearby-Share-Handoff.md`. Everything new lives in `scanner/Share/`. Tests
go in `scannerTests/NearbyShareTests.swift`.

House rules for this code:
- Match the surrounding code: tabs, `///` doc comments in plain prose, `Log.share.error("…")`
  (os.Logger, `scanner/Rescriva/Log.swift`) for failures and `.notice` for refusals, never a PIN,
  secret or anything the user typed in a message, Swift 5 language mode, iOS 17 minimum. Mac Catalyst must compile, so guard iOS-only
  APIs with `#if !targetEnvironment(macCatalyst)`.
- "Power of 10" style: short functions, check every return value, no recursion, bounded loops, no
  force unwraps on anything that comes from outside.
- Everything that arrives from the page or a QR code is untrusted. Validate lengths and
  characters before using it, and **never put an unvalidated string into SDP text**.
- UI uses the paper-and-ink design system (`scanner/Design/`): `GrainBackground`, `BackPill`,
  `RescrivaFont`, the `.carbon/.graphite/.ink/.wash/.vellum/.stock/.highlighter/.vermilion`
  colours, `rescrivaCard`, `rescrivaSectionLabel`, `PrimaryButton`, `Glyph`, `StatusBarScrim`.
  `SettingsView` is a good model for an inner screen.

## Files and interfaces

### Core: pure Foundation/CryptoKit, unit-tested

`NearbyShareConfig.swift`
```swift
enum NearbyShareConfig {
	/// wss://relay.rescriva.com/ws. UserDefaults "shareRelayURL" overrides it (launch argument
	/// `-shareRelayURL ws://127.0.0.1:8787/ws`), and "off" means no relay.
	static var relayURL: URL? { get }
	/// https://share.rescriva.com/. UserDefaults "shareSiteURL" overrides it.
	static var siteURL: URL { get }
	static let chunkSize = 64 * 1024
	static let highWater = 1 << 20
	static let maxIncomingBytes: Int64 = 1 << 30
	/// How long no-relay pairing tries before showing the connection code.
	static let codeDelay: Duration = .seconds(4)
	/// How long a connection code stays up without connecting.
	static let codeLifetime: Duration = .seconds(180)
}
```

`ShareDevice.swift` (UIKit)
```swift
enum ShareDevice {
	/// "Michael's iPhone", or the Mac's computer name; at most 64 characters.
	@MainActor static var name: String { get }
	/// "iphone", "ipad" or "mac", as the relay and the page expect.
	@MainActor static var kind: String { get }
}
```

`ShareCodes.swift`
```swift
enum ShareCodes {
	static func base64URL(_ data: Data) -> String          // no padding
	static func base64NoPadding(_ data: Data) -> String
	static func data(base64URL text: String) -> Data?
	static func newSecret() -> Data                       // 16 random bytes (SecRandomCopyBytes)
	static func newSessionID() -> String                  // base64url of 8 random bytes
	static func roomID(secret: Data) -> String
	static func iceCredentials(secret: Data) -> (ufrag: String, pwd: String)
	static func proof(secret: Data, role: String, offerFingerprint: String, answerFingerprint: String) -> String
	/// Nine digits an untrusted page and the app both show for one connection (see "Check number").
	static func checkNumber(offerFingerprint: String, answerFingerprint: String) -> String
	static func connectionCode(ipv4: String, port: UInt16) -> String?      // nil if not IPv4
	/// Only the tests call this (the page decodes codes); it checks the encoder against the page's rules.
	static func decodeConnectionCode(_ text: String) -> (ipv4: String, port: UInt16)?
	static func grouped(_ code: String) -> String         // "80JBN1HG" → "80JB-N1HG"
	static func newPIN(avoiding used: Set<String>) -> String   // 6 digits
	static func displayPIN(_ pin: String) -> String       // "482913" → "482 913"
	static func displayCheckNumber(_ number: String) -> String  // "424561948" → "424 561 948"
}
```

**Check number** (interim answer to the audit's H1, until a PAKE keyed on the PIN replaces `unlock`).
A page from the `auto` room holds no secret, so neither end can prove anything to the other; the
check number only lets a person see that the page's device card and the phone's connected-computer
row describe the same connection before a PIN is typed. Both ends compute, from the fingerprints
exactly as `proof()` uses them (upper-case hex pairs joined by `:`, the offer's then the answer's,
as applied):

```
text   = "rescriva-share/check/v1|" + fpOffer + "|" + fpAnswer
digest = SHA-256(UTF-8(text))
n      = big-endian uint64 of digest[0..7], then n mod 1000000000
```

shown as nine digits, zero-padded, in three groups of three ("424 561 948"). Vectors:
`fpOffer = "AA:"×31+"AA"`, `fpAnswer = "BB:"×31+"BB"` → `424561948`; swapped → `576993692`. It is
shown only for untrusted connections; trusted ones (QR, `#k=` link, pairing) have the proof. It is
not an authentication: a relay in the middle sees both fingerprints and can show the same number,
and whoever answers an offer picks its certificate after seeing `fpOffer`, so it can try
certificates until the number matches one it wants; nine digits (a billion tries) rather than six
(a million, seconds on a laptop) put that outside a connection's window. The screen's wording is
"matching numbers mean the card and this row are the same connection", never "this proves it's
your device". The same derivation and vectors belong in PROTOCOL.md §1.1.

`SharePairing.swift`
```swift
/// The page's QR code: `openscanner://share?p=<base64url payload>` (PROTOCOL.md §3).
struct SharePairingOffer: Equatable {
	struct Candidate: Equatable { let host: String; let port: UInt16 }  // dotted IPv4, IPv6 text, or "<uuid>.local"
	let secret: Data
	let ufrag: String          // ice-chars only: [A-Za-z0-9+/], 4…256
	let pwd: String            // ice-chars only, 22…256
	let fingerprint: String    // "AB:CD:…", 32 bytes, upper case
	let mid: String            // [A-Za-z0-9_-], 1…16
	let candidates: [Candidate]
	/// True when there is at least one candidate and every one is RFC 1918 or 169.254/16 IPv4, IPv6
	/// link-local (fe80::/10) or unique-local (fc00::/7), an IPv4-mapped one of those, or a ".local"
	/// name (ShareNetwork.isLocalNetworkHost). A public address beside a decoy local one is not "within".
	var isWithinPrivateNetwork: Bool { get }
	/// The candidates that pass that test: what a local-only pairing dials.
	var localCandidates: [Candidate] { get }
	init?(payload: Data)
	/// Accepts the whole link, or just the base64url payload.
	init?(link: String)
}
```

`ShareSDP.swift`
```swift
enum ShareSDP {
	/// The page's offer, rebuilt from its QR code (the exact lines in Tools/NearbyShareSpike/spike.swift).
	/// With `localOnly`, only `pairing.localCandidates` go in.
	static func offer(for pairing: SharePairingOffer, addresses: [String: String] = [:], localOnly: Bool = false) -> String
	static func replacingICECredentials(in sdp: String, ufrag: String, pwd: String) -> String
	/// The first `a=fingerprint:sha-256`, upper case.
	static func fingerprint(in sdp: String) -> String?
	/// A UDP host candidate's address and port, from a candidate line, with or without "a=".
	static func hostCandidate(_ line: String) -> (address: String, port: UInt16)?
}
```

`ShareNetwork.swift`
```swift
enum ShareNetwork {
	/// IPv4 address → interface name ("en0", "bridge100", "pdp_ip0"), from getifaddrs.
	static func interfaceNames() -> [String: String]
	/// Whether a pairing-code host is only reachable on a local network (see SharePairingOffer.isWithinPrivateNetwork).
	static func isLocalNetworkHost(_ host: String) -> Bool
	/// Which local candidate goes in the connection code: 172.20.10.1 (Personal Hotspot) first, then
	/// en0, then other en*/bridge*; only private IPv4; never pdp_ip*, utun*, ipsec*, awdl*, llw*, lo*, anpi*.
	static func codeCandidate(from candidates: [(address: String, port: UInt16)],
	                          interfaces: [String: String]) -> (address: String, port: UInt16)?
}
```

`ShareCertificate.swift`: `enum ShareCertificate { static let privateKeyPEM, certificatePEM: String; static let fingerprint: String }`.
Copy the PEMs from `Tools/NearbyShareSpike/key.pem` and `cert.pem`. The fingerprint is
`C8:7F:82:09:B8:EF:F6:FB:92:37:13:91:BD:28:85:F1:50:E7:03:8D:3E:BB:DA:99:2A:78:3C:9F:DB:E1:95:CB`.

`ShareMessages.swift`
```swift
/// The sizes and counts every part agrees on, written once (the relay's and the page's copies are in
/// rescriva-share). Everything else references these; nothing redefines them.
enum ShareLimits {
	static let maxMessageBytes = 64 * 1024      // a relay message or a data-channel text frame
	static let maxSDPBytes = 60 * 1024          // an SDP inside a relay message
	static let maxCandidateBytes = 1024
	static let maxPeers = 32                    // the relay's cap per room
	static let maxDeviceName = 64
	static let maxFileName = 255
	static let maxProof = 128
	static let maxPIN = 16
	static let maxToken = 64                    // ids, transfer ids, relay peer ids
	static let maxDocuments = 200
	static let stallSeconds: TimeInterval = 30  // a transfer with no bytes for this long is given up on
	static let pageDevices: Set<String>         // "phone", "tablet", "computer"
	static let appDevices: Set<String>          // "iphone", "ipad", "mac"
	static let relayDevices: Set<String>        // both
}

/// What the page sends over the data channel (PROTOCOL.md §4).
enum ShareInbound: Equatable {
	case hello(name: String, device: String, proof: String?)
	case unlock(id: String, pin: String)
	case get(id: String)
	case send(xfer: String, name: String, size: Int64, type: String)
	case end(xfer: String)
	case cancel(xfer: String)
	case bye
	init?(json: Data)            // nil for anything unknown or malformed; names clipped to 255
}
```
`ShareJSON.cleanName` drops control and format characters and, by name, the bidi overrides and
isolates U+202A–U+202E and U+2066–U+2069, as the relay does.
```swift

struct ShareDocSummary: Equatable { let id: String; let name: String; let size: Int64; let type: String; let unlocked: Bool }

/// What the app sends.
enum ShareOutbound: Equatable {
	case hello(name: String, device: String, session: String, proof: String?)
	case docs([ShareDocSummary])
	case unlocked(id: String)
	case denied(id: String, reason: String, retryIn: Int?, left: Int?)
	case file(id: String, xfer: String, name: String, size: Int64, type: String)
	case end(xfer: String)
	case accept(xfer: String)
	case decline(xfer: String, reason: String?)
	case saved(xfer: String, ok: Bool)
	case cancel(xfer: String)
	case bye
	var json: Data { get }
}

/// A relay `signal` payload (PROTOCOL.md §2).
enum ShareSignal: Equatable {
	case offer(String)
	case answer(String)
	case candidate(String, sdpMid: String?, sdpMLineIndex: Int32)
	init?(data: [String: Any])
	var data: [String: Any] { get }
}
```

### Transport: WebRTC and the relay

The package is `https://github.com/stasel/WebRTC`, exact version 153.0.0 (`import WebRTC`).

`SharePeer.swift`
```swift
@MainActor
final class SharePeer {
	enum Event {
		case localCandidate(String, sdpMid: String?, sdpMLineIndex: Int32)
		case open
		case text(Data)
		case binary(Data)
		case closed
	}
	let id: UUID
	/// The connection's trust secret, when it has one (§1.2).
	let secret: Data?
	private(set) var offerFingerprint: String?
	private(set) var answerFingerprint: String?
	/// Candidate lines gathered so far, for the connection code.
	private(set) var localCandidates: [String]
	var isOpen: Bool { get }

	/// `builtInCertificate` is for no-relay pairing. Events arrive on the main queue, in order.
	init(secret: Data?, builtInCertificate: Bool, onEvent: @escaping (SharePeer, Event) -> Void)
	/// Relay mode: applies the page's offer and returns the answer SDP for the relay.
	func answer(offer sdp: String) async throws -> String
	/// No-relay mode: rebuilt offer, an answer with ICE credentials swapped in from the secret.
	/// With `localOnly`, only the code's local-network candidates are dialed.
	func connect(to pairing: SharePairingOffer, localOnly: Bool = false) async throws
	func addRemoteCandidate(_ line: String, sdpMid: String?, sdpMLineIndex: Int32) async
	@discardableResult func send(_ message: ShareOutbound) -> Bool
	@discardableResult func sendBinary(_ data: Data) -> Bool
	/// True once the send buffer is under `NearbyShareConfig.highWater`; false when the channel closed
	/// or the buffer hasn't drained after `ShareLimits.stallSeconds` (the page stopped reading).
	func waitForRoom() async -> Bool
	func close()

	#if DEBUG   // a peer with no WebRTC behind it, for NearbyShareSessionTests
	init(stubSecret: Data?, offerFingerprint: String?, answerFingerprint: String?, onEvent: …)
	private(set) var recordedForTesting: [Recorded]   // .message(ShareOutbound) | .bytes(Int)
	func deliverForTesting(_ event: Event)
	#endif
}
```
- Configuration: unified plan, no ICE servers, `candidateNetworkPolicy = .lowCost`, one
  negotiated data channel (`isNegotiated = true`, `channelId = 0`, label `rescriva`), created
  right after the peer connection.
- Before the one factory is made, `RTCAudioSession.sharedInstance()` gets `useManualAudio = true`
  and `isAudioEnabled = false`, so a data-only share never touches `AVAudioSession` (music keeps
  playing).
- Delegate callbacks arrive on WebRTC's own thread. Forward them through
  `DispatchQueue.main.async`, never unstructured `Task`s, so frames keep their order.
- Fingerprints: the offer is always the page's (the remote description); the answer is always
  the app's (the local description).
- Wrap the completion-handler APIs in checked continuations yourself; don't rely on the
  imported async variants.

`ShareRelay.swift`
```swift
@MainActor
final class ShareRelay {
	struct Peer: Equatable { let id: String; let role: String; let name: String; let device: String }
	enum Status: Equatable { case connecting, open, unavailable }
	enum Event { case status(Status), peers([Peer]), join(Peer), leave(String), signal(from: String, ShareSignal) }
	/// One message from the relay, as `parse` reads it (welcome lists are deduplicated and capped at ShareLimits.maxPeers).
	enum Message: Equatable { case welcome([Peer]), join(Peer), leave(id: String), signal(from: String, ShareSignal), error(String), other }
	let room: String
	private(set) var status: Status
	init(url: URL, room: String, onEvent: @escaping (Event) -> Void)
	func start()
	func stop()
	func signal(to peerID: String, _ signal: ShareSignal)
	/// Pure: needs no socket, so tests feed it text. Whether a signal's sender is in the room is checked when it's handled.
	static func parse(_ text: String) -> Message?
}
```
- Uses `URLSessionWebSocketTask`, with query `room`, `role=app`, `name` (`ShareDevice.name`) and
  `device` (`ShareDevice.kind`).
- Sends `{"t":"ping"}` every 25 s; the relay drops peers that are silent for 120 s.
- Reconnects with backoff (1, 2, 4 … 30 s). Two misses in a row means `.unavailable`, but it keeps
  retrying.

### Session: the orchestrator

`NearbyShareSession.swift`
```swift
enum NearbyShareItem: Hashable {
	case scan(Scan)          // exported as a searchable PDF
	case pdf(UUID)           // PDFLibrary item, current version
	case file(URL, name: String)
}

@MainActor @Observable
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
	/// `checkNumber` is set for a page that proved nothing (ShareCodes.checkNumber); nil for a trusted one.
	struct Device: Identifiable { let id: UUID; var name: String; var kind: String; var trusted: Bool; var checkNumber: String? }
	struct IncomingOffer: Identifiable { let id: String; let deviceName: String; let name: String; let size: Int64; let type: String }
	struct Transfer: Identifiable {
		enum Direction { case sending, receiving }
		enum State: Equatable { case moving, done, failed(String) }
		let id: UUID; let direction: Direction; let name: String; let deviceName: String
		var done: Int64; let total: Int64; var state: State
	}
	enum RelayState: Equatable { case off, connecting, open, unavailable }
	enum PairingState: Equatable { case idle, connecting, showCode(String), connected(String), failed(String) }

	private(set) var documents: [SharedDocument]
	private(set) var devices: [Device]
	private(set) var incoming: [IncomingOffer]
	private(set) var transfers: [Transfer]
	private(set) var relayState: RelayState
	private(set) var pairing: PairingState
	private(set) var isRunning: Bool
	/// share.rescriva.com/#k=…, for the QR code; nil until started.
	private(set) var openLink: URL?
	/// Pages that proved nothing: the `auto` room's web peers (from the relay's welcome/join/leave) plus any
	/// connected from it that the relay no longer lists. Above one, the screen shows a warning banner.
	private(set) var untrustedPageCount: Int
	/// Something received and saved: for a toast.
	var onSaved: ((String) -> Void)?
	/// `ShareLimits.stallSeconds`; tests shorten it.
	var stallSeconds: TimeInterval

	init(items: [NearbyShareItem], library: PDFLibrary = .shared, context: NSManagedObjectContext)
	/// A new session: session id, share key, PINs. Joins the relay rooms (auto + roomId(key)) and prepares files.
	func start()
	/// Sends docs [] and bye, closes every peer and relay, deletes temp files. Idempotent.
	func stop()
	func add(_ items: [NearbyShareItem])
	func remove(_ document: SharedDocument)
	/// No-relay pairing with a scanned or pasted page code. Also joins roomId(secret) when there's a relay; whichever opens first wins.
	/// With `localOnly` (a link from outside the app that named only local addresses) the relay room is never
	/// joined and only the code's local candidates are dialed; the connection code still works.
	func pair(with offer: SharePairingOffer, localOnly: Bool = false)
	func accept(_ offer: IncomingOffer)
	func decline(_ offer: IncomingOffer)

	#if DEBUG   // a link over a stub SharePeer, owned like any other; tests deliver events to link.peer
	func connectStubForTesting(secret: Data?, origin: NearbyShareLink.Origin, offerFingerprint: String?, answerFingerprint: String?) -> NearbyShareLink?
	func holdsForTesting(_ link: NearbyShareLink) -> Bool
	#endif
}
```
`NearbyShareSession+Link.swift`, `+Rules.swift` and `+Files.swift` hold types of their own, not
extensions of the session (the names stay because renaming a file means touching the project file):
`NearbyShareLink` (one connection; `provesItself`, `canDownload`, `checkNumber`); `NearbySharePINLock`
and `NearbyShareInput` (pure, clock-driven rules); `NearbyShareFiles`, `NearbyShareChunkFile` (a file
read or written a chunk at a time on its own queue, so the main actor never waits on the disk) and
`NearbyShareUpload`.

Behaviour:
- **Trust.** A peer with a secret (from the share key's room, or a pairing) sees everything once
  its `hello` proof checks out. A wrong proof means `bye`, then close. A peer from the `auto`
  room sees names and needs each document's PIN.
- **PINs.** Unique per session. Wrong tries are counted per (document, connection) by
  `NearbySharePINLock`: five wrong from one page refuse that page for 30 s (`denied` with
  `reason: "wrong"`, `left: 0`, `retryIn: 30`, then `reason: "cooldown"` while it waits); other
  pages carry on. Only when wrong tries across every page reach 15, or three different pages have
  each been refused, is the PIN replaced and every page refused for a cooldown of 30 s that doubles
  each time this happens again, capped at 2⁶ (32 minutes). `left` tells the page how many tries
  it has. A page from the `auto` room never locks a paired page out.
- **Downloads.** Only for documents that are ready. One transfer per peer at a time, in a queue:
  `file`, 64 KiB binary chunks (read off the main actor) with `waitForRoom()`, then `end`. When the
  page stops reading for `stallSeconds` the transfer is cancelled and shown as failed.
- **Uploads.** A PDF or `image/*` up to `maxIncomingBytes` goes in `incoming` for Accept/Decline.
  Anything else is declined with reason `type`. Accepted bytes are queued to a temp file off the
  main actor and checked against the size. `cancel` from the page frees the slot and deletes the
  partial file, and so does a stall: no chunk for `stallSeconds` sends `cancel` and shows the
  transfer as failed, so a page whose upload died without saying so can offer again. A PDF goes
  into the library with `PDFLibrary.importPDF(at:title:)` (title = the name without its extension).
  An image becomes a scan with `PhotoImport.scan(from:in:)`. Reply `saved {ok}` and call `onSaved`.
- **No-relay pairing.** Start the direct peer. If it isn't open after `codeDelay`, set
  `.showCode(grouped code)` from `ShareNetwork.codeCandidate`; with no candidate,
  `.failed("…")`. When a pairing peer opens and proves itself, set `.connected(name)` and close the
  other path. A code that has shown for `codeLifetime` without connecting expires to
  `.failed("… Scan the computer's code again.")`: after a failed code the page starts over with
  a fresh QR code, so the old one can't connect.
- **Names.** A page is called by its `hello` name, numbered when a connected device already has
  that label ("Chrome on Mac", "Chrome on Mac 2"); the label is used in Connected, the
  Accept/Decline cards and Activity alike.
- **Files.** Prepared in `tmp/NearbyShare/<session>/` and deleted by `stop()`. The first session
  to start in a process deletes every other folder there and every folder in
  `tmp/NearbyShareReceived/`, left by a run killed mid-share. A scan
  goes through `ExportService.makeFile(for:format: .pdf, includeNotes: true)`. A PDF item: wait for
  `library.waitForSave(of:)`, then copy `currentURL(for:)` to "<title>.pdf". Document ids are
  random base64url strings, new every session.

### UI and entry points

- `NearbyShareView.swift`: the route's screen. `@State` session; `.task { start }`;
  `.onDisappear { stop }`. On `scenePhase == .background`, stop. On `.active` after that, start
  fresh (new PINs). `UIApplication.shared.isIdleTimerDisabled = true` while showing. Sections:
  - **Shared:** rows with the name, size and a large PIN (`482 913`), a remove button, and
    **Add documents**.
  - **Open on a phone:** the QR code of `openLink`, "Scan with a phone's camera. It opens these
    files with no PIN", and Copy link.
  - **Computer:** **Scan a computer's code** (iOS, when `DataScannerViewController.isSupported`),
    a paste-a-pairing-link field (always on Mac; also offered on iOS), and the pairing state,
    including the connection code shown large.
  - **Connected:** devices, with "Paired" or "PIN for each file". A page that proved nothing also
    shows its check number (`ShareCodes.displayCheckNumber`) with "Compare with the number on the
    page's card before you type a PIN there. Matching numbers mean the card and this row are the
    same connection." The Shared card says that a PIN only lets the page that types it download
    that file.
  - A `BannerView` (tone `.warning`) above the sections when `untrustedPageCount > 1`: "More than
    one computer on this network can see what you're sharing. Check the number on each one."
  - The pairing confirmation for a link from outside the app: the plain "Pair with this computer?"
    alert when `offer.isWithinPrivateNetwork`, whose Pair calls `pair(with:localOnly: true)`;
    otherwise "Pair with a computer outside your network?", whose default action is Cancel and
    whose "Pair anyway" is destructive and dials every candidate. The screen is not opened for
    such a link (see `NearbySharePending` below); one already open is brought to the front.
  - **Waiting for you:** Accept/Decline cards.
  - **Activity:** transfers with progress.
  - The relay state as one line under the title.
- `ShareDocumentPicker.swift`: a sheet listing live scans (Core Data `Scan`, newest first,
  `deletedAt == nil`) and `PDFLibrary.shared.items`, with multi-select → `[NearbyShareItem]`.
- `ShareCodeScanner.swift`: VisionKit `DataScannerViewController` for QR codes, iOS only, wrapped
  for SwiftUI. Returns the payload string.
- `ShareQRCode.swift`: CoreImage QR (level M), crisp scaling.
- `NearbySharePending.swift`: `@MainActor @Observable final class NearbySharePending { static let shared; var link: String? }`,
  so an `openscanner://share?p=…` link reaches the screen. `receive(_:)` keeps the link and `take()`
  hands it over once; a link that waited longer than `maxAge` (120 s) is dropped, because the screen
  isn't opened for a link and a stale one shouldn't turn up as a pairing prompt later.
- Edits:
  - `RescrivaRouter.swift`: `case shareNearby([NearbyShareItem])`, plus `forget(_:)`'s switch.
  - `ContentView.swift`: the `screen(for:)` case, and `open(_:)` handling host `share`
    (`NearbySharePending.shared.receive(url)`, then `.shareNearby` through `AppRequests`). A Share
    screen already on the stack is brought to the front; when there is none, none is opened for
    the link (any website can make one, the audit's L2): a toast, "A computer wants to pair with
    Share Nearby", offers "Open", and the pairing is still confirmed on the screen before
    anything connects.
  - Entry points: the Library home (next to its add/settings controls), `ExportSheet` (a
    "Share Nearby" button that makes the file in the chosen format, dismisses, and pushes
    `.shareNearby([.file(url, name:)])`; the sheet may need the router from the environment), and
    the PDF viewer's share action (`.shareNearby([.pdf(id)])`).
  - DEBUG only: the launch argument `-shareNearbyDemo YES` pushes `.shareNearby` with the newest two
    library items at launch, for automated testing.

### Project wiring (integration)

- `openscanner.xcodeproj/project.pbxproj` (objectVersion 56, no synchronized folders):
  - Add a `Share` group under `scanner`, with every file above in the app target's Sources
    (`A30E5C86288A2FF40099985F`).
  - Add `NearbyShareTests.swift` to the `scannerTests` group (`A30E5CA3288A2FF50099985F`) and
    Sources (`A30E5C9C288A2FF50099985F`).
  - Add an `XCRemoteSwiftPackageReference` for stasel/WebRTC with `exactVersion = 153.0.0`, an
    `XCSwiftPackageProductDependency` "WebRTC", a `PBXBuildFile` in the app's Frameworks phase
    (`A30E5C87288A2FF40099985F`), the product in target `A30E5C89288A2FF40099985F`'s
    `packageProductDependencies`, and the reference in `PBXProject.packageReferences`.
- Build settings, both scanner configurations: `INFOPLIST_KEY_NSLocalNetworkUsageDescription =
  "Rescriva connects directly to computers and phones on your network when you use Share Nearby."`
- `scanner/Info.plist`: `NSAppTransportSecurity` → `NSAllowsLocalNetworking = true`.
- Don't change bundle ids, `ITSAppUsesNonExemptEncryption` or signing settings.
