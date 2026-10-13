# Share Nearby: app design

The Swift side of Share Nearby. The wire format is `ShareSite/PROTOCOL.md`; the background and
decisions are in `Docs/Nearby-Share-Handoff.md`. Everything new lives in `scanner/Share/`. Tests
go in `scannerTests/NearbyShareTests.swift`.

House rules for this code:
- Match the surrounding code: tabs, `///` doc comments in plain prose, `print("Rescriva: …")` for
  failures, Swift 5 language mode, iOS 17 minimum. Mac Catalyst must compile, so guard iOS-only
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
	static func connectionCode(ipv4: String, port: UInt16) -> String?      // nil if not IPv4
	static func decodeConnectionCode(_ text: String) -> (ipv4: String, port: UInt16)?
	static func grouped(_ code: String) -> String         // "80JBN1HG" → "80JB-N1HG"
	static func newPIN(avoiding used: Set<String>) -> String   // 6 digits
	static func displayPIN(_ pin: String) -> String       // "482913" → "482 913"
}
```

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
	init?(payload: Data)
	/// Accepts the whole link, or just the base64url payload.
	init?(link: String)
}
```

`ShareSDP.swift`
```swift
enum ShareSDP {
	/// The page's offer, rebuilt from its QR code (the exact lines in Tools/NearbyShareSpike/spike.swift).
	static func offer(for pairing: SharePairingOffer) -> String
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
	func connect(to pairing: SharePairingOffer) async throws
	func addRemoteCandidate(_ line: String, sdpMid: String?, sdpMLineIndex: Int32) async
	@discardableResult func send(_ message: ShareOutbound) -> Bool
	@discardableResult func sendBinary(_ data: Data) -> Bool
	/// Returns once the send buffer is under `NearbyShareConfig.highWater`, or the channel closed.
	func waitForRoom() async
	func close()
}
```
- Configuration: unified plan, no ICE servers, `candidateNetworkPolicy = .lowCost`, one
  negotiated data channel (`isNegotiated = true`, `channelId = 0`, label `rescriva`), created
  right after the peer connection.
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
	let room: String
	private(set) var status: Status
	init(url: URL, room: String, onEvent: @escaping (Event) -> Void)
	func start()
	func stop()
	func signal(to peerID: String, _ signal: ShareSignal)
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
	struct Device: Identifiable { let id: UUID; var name: String; var kind: String; var trusted: Bool }
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
	/// Something received and saved: for a toast.
	var onSaved: ((String) -> Void)?

	init(items: [NearbyShareItem], library: PDFLibrary = .shared, context: NSManagedObjectContext)
	/// A new session: session id, share key, PINs. Joins the relay rooms (auto + roomId(key)) and prepares files.
	func start()
	/// Sends docs [] and bye, closes every peer and relay, deletes temp files. Idempotent.
	func stop()
	func add(_ items: [NearbyShareItem])
	func remove(_ document: SharedDocument)
	/// No-relay pairing with a scanned or pasted page code. Also joins roomId(secret) when there's a relay; whichever opens first wins.
	func pair(with offer: SharePairingOffer)
	func accept(_ offer: IncomingOffer)
	func decline(_ offer: IncomingOffer)
}
```
Behaviour:
- **Trust.** A peer with a secret (from the share key's room, or a pairing) sees everything once
  its `hello` proof checks out. A wrong proof means `bye`, then close. A peer from the `auto`
  room sees names and needs each document's PIN.
- **PINs.** Unique per session. Five wrong tries on a document, counted across all peers,
  replaces its PIN. Tries on it are then refused for 30 s, doubling each time this happens again
  (`denied` with `reason: "cooldown"`, `retryIn`). `left` tells the page how many tries remain.
- **Downloads.** Only for documents that are ready. One transfer per peer at a time, in a queue:
  `file`, 64 KiB binary chunks with `waitForRoom()`, then `end`.
- **Uploads.** A PDF or `image/*` up to `maxIncomingBytes` goes in `incoming` for Accept/Decline.
  Anything else is declined with reason `type`. Accepted bytes are written to a temp file and
  checked against the size. A PDF goes into the library with `PDFLibrary.importPDF(at:title:)`
  (title = the name without its extension). An image becomes a scan with
  `PhotoImport.scan(from:in:)`. Reply `saved {ok}` and call `onSaved`.
- **No-relay pairing.** Start the direct peer. If it isn't open after `codeDelay`, set
  `.showCode(grouped code)` from `ShareNetwork.codeCandidate`; with no candidate,
  `.failed("…")`. When a pairing peer opens and proves itself, set `.connected(name)` and close the
  other path.
- **Files.** Prepared in `tmp/NearbyShare/<session>/` and deleted by `stop()`. A scan goes through
  `ExportService.makeFile(for:format: .pdf, includeNotes: true)`. A PDF item: wait for
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
  - **Connected:** devices, with "Paired" or "PIN for each file".
  - **Waiting for you:** Accept/Decline cards.
  - **Activity:** transfers with progress.
  - The relay state as one line under the title.
- `ShareDocumentPicker.swift`: a sheet listing live scans (Core Data `Scan`, newest first,
  `deletedAt == nil`) and `PDFLibrary.shared.items`, with multi-select → `[NearbyShareItem]`.
- `ShareCodeScanner.swift`: VisionKit `DataScannerViewController` for QR codes, iOS only, wrapped
  for SwiftUI. Returns the payload string.
- `ShareQRCode.swift`: CoreImage QR (level M), crisp scaling.
- `NearbySharePending.swift`: `@MainActor @Observable final class NearbySharePending { static let shared; var link: String? }`,
  so an `openscanner://share?p=…` link reaches the screen.
- Edits:
  - `RescrivaRouter.swift`: `case shareNearby([NearbyShareItem])`, plus `forget(_:)`'s switch.
  - `ContentView.swift`: the `screen(for:)` case, and `open(_:)` handling host `share` (set
    `NearbySharePending.shared.link`; push `.shareNearby([])` unless it's already on top). Leave
    the rest of ContentView alone; another session is reviewing it.
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
