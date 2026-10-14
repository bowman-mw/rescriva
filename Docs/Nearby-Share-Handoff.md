# Share Nearby (Rescriva Share): handoff

> **Status, 2026-10-13:** the app side is built, tested end to end in the simulator, and merged into
> `main`. share.rescriva.com and relay.rescriva.com are live. It still needs a real-device test,
> including Personal Hotspot (§9). Sections 3–8 describe the state at the time of the handoff.

Written 2026-10-12 when the work was paused for a cloud session. Branch `nearby-share` in
**`bowman-mw/rescriva`** (the app's new home; the old fork `bowman-mw/OpenScanner` is frozen, so
don't push there). It's cut from `main` at e9234ee. Read this file first, then
`Docs/Rescriva-Share-Protocol.md`.

**Repo rules** (from the session that moved the repo):
- Push to this branch, not `main`. Merges into `main` happen when the user says so.
- Docs go in `Docs/`; spikes and prototypes go in `Tools/<Name>/`. Bundle ids (`MBO.Scanner*`,
  `group.MBO.Scanner`, `iCloud.MBO.Scanner`) stay unchanged.
- Another session ("Folio to Rescriva domain migration") is reviewing the Open Scanner-derived code:
  DataExtensions, Persistence, AppState, NavigationManager, HomeView, LiveScanSummary,
  QuickLookController, ViewExtensions, the widget, AppIntents and Spotlight. Share Nearby only
  *calls* `PhotoImport.scan` (in HomeView.swift). If you need to *edit* any of those files,
  coordinate first.
- `main` gained a library-load warning since d5531ca (9a4888a): `ContentView(libraryIsTemporary:)`,
  a top `safeAreaInset` banner in ContentView, and `BannerView` moved to
  `Design/RescrivaComponents.swift`. Keep that in mind when you add the route to ContentView.
- **Another cloud session is making UI changes** to the app. Before editing shared screens
  (ContentView, LibraryHomeView, ExportSheet, PDFDocumentView), rebase onto the latest `main`.
  Keep the Share screen in its own files under `scanner/Share/` so it merges cleanly.

**Where the website lives:** the public repo **`bowman-mw/rescriva-share`** (created
2026-10-12 with the user's OK). GitHub Pages is on (from `main`, root) with the custom domain
`share.rescriva.com`. Website and relay changes go there. The protocol spec is copied into this repo as
`Docs/Rescriva-Share-Protocol.md`; change both together.

**There's a second workstream in this handoff:** the Open Scanner code review, in
`Docs/OpenScanner-Code-Review.md`. See §10.

## 1. What the user asked for

- PairDrop-style file sharing between Rescriva and a web page, for devices on the same Wi-Fi.
- PairDrop failed on their work laptop and iPhone because it wasn't served over HTTPS. This
  site goes on **GitHub Pages** (HTTPS).
- It's for work, so each download needs a confirmation between the devices: a **QR code or a PIN**.
- **A one-time PIN for each document.** PINs change when the Share screen is closed and reopened.
- When Rescriva leaves the Share screen, its documents **disappear from the site**.
- **Personal Hotspot:** with the iPhone as the hotspot and the computer joined to it, files go
  both ways through the app and the site.
- **Mac app:** it shows a QR code that someone scans with a phone. The site opens on that phone
  with **no PIN**.

### Decisions the user made (AskUserQuestion, 2026-10-12)

| Question | Answer |
|---|---|
| How devices exchange the connection "hello" | **Our own relay (a Cloudflare Worker) with a no-relay backup** (QR pairing that works offline) |
| What the site shows before a PIN | **Document names are visible**; the PIN is needed to download |
| PIN lifetime | **Until the Share screen closes**: new PINs every time it opens. 5 wrong tries replace that document's PIN and start a cooldown (since the 2026-10-13 audit fix the tries are counted per connection: 5 from one page refuse that page for 30 s; 15 across pages, or three refused pages, replace the PIN; see `Docs/Nearby-Share-App-Design.md`) |
| Hosting | **New public repo `bowman-mw/rescriva-share`, served at `share.rescriva.com`** (the user adds the DNS record) |

## 2. Why it's built this way

- A static HTTPS page can't open a connection to a phone on the local network. `fetch`/`ws` to
  `http://192.168.x.x` is blocked as mixed content. **WebRTC is the only direct path**, and it
  needs an offer/answer swap first.
- **Relay path (normal):** a tiny WebSocket relay passes the swap. Devices behind the same public
  IP land in one "auto" room, PairDrop-style, so documents appear on their own. Files never touch
  the relay.
- **No-relay path (backup):** the page puts its WebRTC offer in a QR code, and Rescriva scans
  it. The app uses a **certificate built into the app** whose fingerprint the page already knows,
  plus ICE credentials derived from a secret in the QR code. That way the page can build the app's
  answer itself, and nothing has to travel back. If the computer refuses incoming connections,
  the app shows a short **connection code** to type on the page.
- **Trust:** a page that holds a secret (it was opened from the app's QR link, or the app scanned
  its QR code) proves it with an HMAC bound to both DTLS fingerprints, and gets every document
  without PINs. Any other page needs each document's PIN.
- **The app side uses Google's WebRTC, natively** (SPM `stasel/WebRTC`), not a WKWebView. Native
  libwebrtc puts real IP addresses in its candidates instead of mDNS names, so laptops that can't
  resolve `.local` names (enterprise GPOs) still connect. It also allows the built-in certificate
  and the ICE credential swap that the no-relay path depends on. Cost: about 12 MB of app size.

## 3. Status

### Done

1. **Feasibility spike: passed.** Files are in `Tools/NearbyShareSpike/`. A native libwebrtc
   M153 peer (macOS slice) and Chrome 152 (the Claude app's browser pane) connected:
   - Chrome accepted the built-in certificate's fingerprint in the made-up answer.
   - libwebrtc accepted replacing `a=ice-ufrag`/`a=ice-pwd` in its own answer before
     `setLocalDescription`. The binary has `WebRTC-NoSdpMangleUfrag` field trials, but they're off by default.
   - The native side resolved Chrome's mDNS candidate and connected in about 50 ms. Data
     channel messages went both ways.
   - The **typed-code path also worked**: the page added a candidate for the native peer's IP
     and port, the native side learned the page's address from the incoming checks, and it
     connected. That held even with the code typed 35 s later. One early attempt failed with
     no candidate pair. The likely cause is the macOS application firewall (it's on) blocking the
     unsigned spike binary; later runs worked. iPhones have no inbound firewall.
   - The Mac running the spike was on the user's iPhone hotspot (172.20.10.3) at the time.
2. **The protocol spec** (`PROTOCOL.md` in rescriva-share, copied to `Docs/Rescriva-Share-Protocol.md`): the full spec, with shared test vectors (secret→room id,
   ICE credentials, proofs, connection codes, payload layout).
3. **The website is written** (bowman-mw/rescriva-share): `index.html`, `assets/*.js`, `style.css`, a
   service worker for offline loads, the vendored QR library (qrcode-generator 1.4.4, MIT),
   `CNAME`, `.nojekyll`, and `tests/index.html`. **The tests page passes 23/23** in Chromium. The
   page renders with no console errors with `?relay=off`. **It has never talked to the app yet.**
4. **The relay**: built and tested, not deployed. See §8.

### Not started

- **Everything on the app side** (§4): no Swift code yet, and the project file and Info.plist
  aren't touched.
- DNS for share.rescriva.com (the user's step) and deploying the relay (§6).
- End-to-end tests (app ↔ page), and device tests on the iPhone and hotspot.

> **A cloud session can't build iOS.** There's no Xcode on Linux. Write the Swift carefully, keep
> the pure logic (codes, derivations, SDP text, PIN rules) in files with unit tests, and plan to
> build and test on the user's Mac. The website and relay can be tested anywhere with Node or a
> headless Chromium.

## 4. App-side plan

New folder `scanner/Share/`. Match the house style: tabs, `///` prose doc comments,
`Log.share.error("…")` (os.Logger, `scanner/Rescriva/Log.swift`), `@MainActor @Observable`, and the design system (`RescrivaFont`,
`Color.cream/.parchment/.bark/.slate/.moss/.lichen/.terracotta`, `PrimaryButton`, `SheetHeader`,
`GrainBackground`).

| File | Contents |
|---|---|
| `NearbyShareConfig.swift` | `relayURL` (`wss://relay.rescriva.com/ws`) and `siteURL` (`https://share.rescriva.com/`). DEBUG overrides come from UserDefaults or launch args: `-shareRelayURL ws://127.0.0.1:8787/ws -shareSiteURL http://127.0.0.1:8770/`. Chunk 64 KiB, high water 1 MiB. |
| `ShareCodes.swift` | base64url/base64, `roomId`, `iceCredentials`, `proof` (CryptoKit HMAC/SHA256), the connection code (encode for the app; decode for tests), the **pairing payload decoder**, 6-digit PIN generation (unique per session). Pure functions with unit tests against PROTOCOL.md's vectors. |
| `ShareCertificate.swift` | The built-in certificate as PEM strings: `Tools/NearbyShareSpike/key.pem` and `cert.pem`, SHA-256 `C8:7F:82:…:95:CB`. **Public on purpose.** The website's `APP_FINGERPRINT` and PROTOCOL.md already use this exact one. If you replace it, update both. |
| `ShareSDP.swift` | Builds the page's offer from a decoded payload (the spike's `spike.swift` shows the exact lines that work), replaces ufrag/pwd in an answer, reads fingerprints. Unit-testable. |
| `ShareMessages.swift` | Codable data channel messages (§4 of the protocol). |
| `RelayClient.swift` | `URLSessionWebSocketTask`: join `auto` and private rooms, ping every 25 s, reconnect with backoff, `signal(to:data:)`. |
| `PeerLink.swift` | Wraps `RTCPeerConnection` and a negotiated data channel (`isNegotiated = true`, `channelId = 0`, label `rescriva`). Two modes: **relay answerer** (the page offers; the app answers and trickles candidates) and **no-relay** (built-in certificate, rebuilt offer, ufrag/pwd swap). Hops delegate callbacks to the main actor. Chunked send with `bufferedAmount` backpressure (`dataChannel(_:didChangeBufferedAmount:)`). Use `candidateNetworkPolicy = .lowCost` (drops cellular) and no ICE servers. |
| `NearbyShareSession.swift` | `@MainActor @Observable`. Shared items with their PINs and prepared files, peers, unlock state per peer, the PIN rules (`NearbySharePINLock`: 5 wrong from one connection → that connection waits 30 s; 15 across connections, or three refused ones → new PIN and a cooldown for everyone of 30 s that doubles, capped at 32 minutes), incoming file offers that wait for Accept/Decline, transfers, the session id, and the session key for the app's QR link. `start()` / `stop()`. `stop()` sends `docs: []` + `bye`, then closes the peer connections and the relay sockets. |
| `NearbyShareView.swift` | The screen: the shared documents with big PINs (`482 913`), Add documents, a QR of `siteURL#k=<base64url key>` ("Scan with a phone camera to open these files, no PIN needed"; prominent on Mac, smaller on iPhone), a Copy link button, **Scan a computer's code** (iPhone/iPad), a **paste-a-pairing-link** field (Mac, and for testing in the simulator), connected devices, Accept/Decline prompts, progress, and the fallback connection code ("Type this on the computer: 80JB-N1HG"), shown when no-relay pairing hasn't opened after 4 s. |
| `ShareDocumentPicker.swift` | A sheet that picks scans (Core Data `Scan`) and PDFs (`PDFLibrary.shared.items`). |
| `CodeScannerView.swift` | `VisionKit.DataScannerViewController` for QR codes, iOS only (`#if !targetEnvironment(macCatalyst)`, check `isSupported`/`isAvailable`). |

**What gets shared.** A scan is exported as a searchable PDF with
`ExportService.makeFile(for:format:.pdf, includeNotes: true)`. A PDF item sends
`PDFLibrary.shared.currentURL(for:)`. Prepare the files when they're added, in a temp folder, and
delete them in `stop()`.

**Receiving.** Write the file to a temp folder. A PDF goes in through
`PDFLibrary.shared.importPDF(at:)`, the way `PDFOpening.open` does. An image becomes a scan through
`PhotoImport.scan(from: [UIImage], in:)` (`scanner/Views/HomeView.swift:268`). Decline other
types with reason `type`. Reply `saved {ok}`.

**Lifetime.** One session each time the screen appears: `.task { start }` / `.onDisappear { stop }`.
When `scenePhase == .background`, stop, and start a fresh session (new PINs and key) when the app
becomes active again. Set `UIApplication.shared.isIdleTimerDisabled = true` while the screen is
showing.

**Routing.**
- Add `case shareNearby([NearbyShareItem])` to `RescrivaRoute` (`scanner/Rescriva/RescrivaRouter.swift`).
  Add it to `forget(_:)`'s switch and to `ContentView.screen(for:)`.
- Entry points:
  - the Library home's `addMenu` (`scanner/Library/LibraryHomeView.swift:143`), or a toolbar
    button beside it, labelled "Share Nearby";
  - a "Share Nearby" button in `ExportSheet` next to Share (`scanner/Views/ExportSheet.swift`);
  - the PDF viewer's share action (`PDFDocumentView.shareFile`, line ~628).
- Add `openscanner://share?p=…` to `ContentView.open(_:)` (`scanner/ContentView.swift:64`),
  next to `Inbox.handle`. Pair with that payload on the Share screen. (As built after the audit's
  L2: the link waits in `NearbySharePending` for up to 120 s and a toast offers to open the
  screen; the screen is not pushed for a link, since any website can make one. Scanning the page's
  QR with the iPhone's Camera app opens Rescriva, then "Open", then the pairing confirmation.)

**Project file** (`openscanner.xcodeproj/project.pbxproj`, objectVersion 56, **no synchronized
folders**, so every new file needs a `PBXFileReference`, a `PBXBuildFile`, group membership and a
Sources entry):
- App target `scanner` = `A30E5C89288A2FF40099985F`; its Sources phase =
  `A30E5C86288A2FF40099985F`; Frameworks phase = `A30E5C87288A2FF40099985F`; its
  `packageProductDependencies` list is empty (line ~856).
- Test target Sources phase = `A30E5C9C288A2FF50099985F`; group `scannerTests` =
  `A30E5CA3288A2FF50099985F`.
- The `scanner` group's children list ends with `5AFE7E000000000000000201 /* Inbox */`. Add a
  `Share` group the same way.
- `PBXProject` `packageReferences` is empty (line ~953). Add an `XCRemoteSwiftPackageReference` for
  `https://github.com/stasel/WebRTC` pinned to **exactVersion 153.0.0**, an
  `XCSwiftPackageProductDependency` `WebRTC`, a `PBXBuildFile` for it in the Frameworks phase,
  and the product in the target's `packageProductDependencies`. The xcframework includes iOS,
  simulator, **Mac Catalyst** and macOS slices. The download zip's SHA-256 was
  `3e3a8946…c2b78f`; SPM checks its own checksum.

**Info.plist / build settings:**
- `INFOPLIST_KEY_NSLocalNetworkUsageDescription` in both scanner configurations (lines
  ~1448–1492, next to `INFOPLIST_KEY_NSCameraUsageDescription`). Suggested text: "Rescriva
  connects directly to computers and phones on your network when you use Share Nearby."
- In `scanner/Info.plist`: `NSAppTransportSecurity` → `NSAllowsLocalNetworking = true`, for
  `ws://127.0.0.1` while testing. (Release talks to `wss://` only.)
- **Ask the user** about `ITSAppUsesNonExemptEncryption` (currently `false`). WebRTC brings its own
  DTLS/BoringSSL. It's very likely still exempt under the mass-market rules, but it's a legal
  declaration, so it's the user's call. Don't change it without asking.

**WebRTC Swift API that compiled in the spike** (`Tools/NearbyShareSpike/spike.swift`):
`RTCInitializeSSL()`, `RTCPeerConnectionFactory()`, `RTCConfiguration` (`sdpSemantics = .unifiedPlan`,
`iceServers = []`, `certificate = RTCCertificate(privateKey:certificate:)` with PKCS#8 PEM),
`factory.peerConnection(with:constraints:delegate:)`, `RTCDataChannelConfiguration`
(`isNegotiated`, `channelId`), `pc.dataChannel(forLabel:configuration:)`,
`pc.setRemoteDescription(_:completionHandler:)`, `pc.answer(for:completionHandler:)`,
`pc.setLocalDescription(_:completionHandler:)`, `RTCDataBuffer(data:isBinary:)`. The delegate
protocol needs all of the spike's methods.

**Tests** (`scannerTests/NearbyShareTests.swift`): PROTOCOL.md's vectors (room id, ICE, both
proofs, the four connection codes, decoding the payload from the hex in rescriva-share's `tests/index.html`),
offer building and the ufrag/pwd swap, PIN uniqueness, lockout and cooldown, and the order the
app picks candidates for the connection code (prefer 172.20.10.1, then en0's private IPv4,
skip `pdp_ip*`/`utun*`; map IP→interface with `getifaddrs`).

## 5. Website (repo `bowman-mw/rescriva-share`)

| File | Role |
|---|---|
| `assets/config.js` | `RELAY_URL`, `APP_FINGERPRINT`. `?relay=ws://…` / `?relay=off` only work on localhost pages. |
| `assets/main.js` | The controller: auto room, the `#k=` link mode (the key is dropped from the address bar), pairing, dedupe by app `session`, the UI (device cards, PIN entry, downloads with "Save again", uploads with drag-and-drop). |
| `assets/peer.js` | `AppConnection`: one connection to an app, implementing the data channel protocol. |
| `assets/pairing.js` | No-relay pairing: the offer, the made-up answer, the payload, `enterCode`. Says so when the browser gathers no candidates (corporate `WebRtcIPHandling`). |
| `assets/relay.js`, `codes.js`, `crypto.js`, `sdp.js`, `qr.js` | As named. |
| `sw.js` | Network-first offline cache, registered only on https. |
| `tests/index.html` | The vector tests. Open it served over http(s). |

To do: check it at phone width (the iPhone opening the Mac's QR link).

## 6. Hosting and deploy steps

1. ✅ The public repo `bowman-mw/rescriva-share` exists, and Pages is on (from `main`, root, custom
   domain `share.rescriva.com`). It was building when this was handed off.
2. **The user** adds DNS: a `CNAME` record from `share` to `bowman-mw.github.io`. **rescriva.com's DNS
   is at Squarespace** (nameservers `nsc1/2/4.squarespacedns.com`), so that's in Squarespace →
   Domains → rescriva.com → DNS. Once GitHub has issued the certificate, turn on **Enforce HTTPS**
   (repo → Settings → Pages).
3. The relay: follow `relay/README.md` in rescriva-share. **The catch:** a Cloudflare Worker can only
   use `relay.rescriva.com` as a custom domain if rescriva.com's DNS moves to Cloudflare. The
   alternative is to keep Squarespace and use the Worker's `*.workers.dev` address. Either way, put the
   final URL in `assets/config.js` (`RELAY_URL`), in the CSP `connect-src` in `index.html`, and in
   `NearbyShareConfig.swift`. Ask the user which they want.
4. Optional later: universal links (`apple-app-site-association` on share.rescriva.com plus the
   Associated Domains entitlement), so the page's QR opens the app even without the custom scheme.

## 7. Testing plan

- **Locally on the Mac:** serve a rescriva-share checkout (`python3 -m http.server 8770 --bind 127.0.0.1`),
  run `python3 relay/dev_relay.py` in it, open
  `http://127.0.0.1:8770/?relay=ws://127.0.0.1:8787/ws`, and run the app in the simulator with
  the launch arguments in §4. The simulator shares the Mac's network.
  - Relay path: the device appears and its documents are listed. PIN unlock → download. Wrong
    PIN ×5 → that page waits 30 s; ×15 (or three pages refused) → new PIN and cooldown. Upload → Accept → it shows up in the library.
  - Link path: open `…/#k=<key>` from the app's QR → no PIN needed.
  - No-relay path: `?relay=off` → paste the page's `openscanner://share?p=…` link into the app's
    paste field (no camera in the simulator) → connected. Then try the typed-code fallback.
  - Leaving the Share screen → the page removes the device (bye), and new PINs appear next time.
- **On the iPhone (user's hardware):** Wi-Fi, then Personal Hotspot with the laptop joined, both
  directions, plus a work laptop if possible. The open questions are below.
- **Mac Catalyst:** the QR is shown, a phone scans it, the site opens unlocked, and uploads go to
  the Mac.

## 8. Relay status

**Built and tested; not deployed.** It's in `relay/` in bowman-mw/rescriva-share (fe2d69b): `worker.js`
(one Durable Object per room, WebSocket Hibernation API, ping→pong answered without waking the object),
`wrangler.toml` (SQLite-backed DO migration, `compatibility_date` 2026-09-20, custom-domain example
commented out), `dev_relay.py` (Python standard library only, `127.0.0.1:8787`), `test_relay.py`, and a
README with the deploy steps.

- `test_relay.py` passed every case against both `dev_relay.py` and the real Worker under
  `wrangler dev` 4.142.0 (Node 24.21.0, local mode). The cases: routes, welcome/join/leave,
  name/device cleanup, signal forwarding, ignored junk, bad room/role/device, Origin allow/deny, ping,
  the 64 KB limit, fragmented frames, the auto room (same /64 → same room, `::ffff:a.b.c.d` = IPv4),
  abrupt disconnects, the 32-peer cap, and stale peers. `wrangler deploy --dry-run` succeeds.
- **What it means for clients:**
  - **Ping every 25 s.** The relay drops a peer that's been silent for 120 s (close code 4408
    "stale"), so a phone that lost signal doesn't linger. Reconnect if the relay closes the socket.
  - **`device` must be one of** `iphone`, `ipad`, `mac`, `phone`, `tablet`, `computer`. Anything else
    gets a 400. A missing one means `computer`.
  - Names are clipped to 64 characters, with control and bidi characters stripped. Messages over
    65,536 bytes are dropped silently.
  - `/health` is gone (removed 2026-10-13; nothing used it): `GET /` answers "Rescriva Share relay".
  - Signals are only delivered between a `web` and an `app` peer (since 2026-10-13); same-role
    signals are dropped. New since then too: 20 new connections a minute per address (429 over
    that), four peers per address in a pairing room, `workers_dev = false`. PROTOCOL.md §2 has them.
- **Shared public IPs** (carrier NAT, offices) put strangers in one `auto` room. That's why PINs exist,
  and a busy network could hit the 32-peer cap. Since 2026-10-13 the app warns when more than one
  unknown page is in the room, and both ends show a check number to compare before a PIN is typed
  (audit H1, M4).

## 9. Risks and open questions

- **Hotspot unknowns:** does libwebrtc gather a candidate on the iPhone's hotspot bridge interface
  (`bridge100`, 172.20.10.1)? Does the iPhone resolve the laptop's `.local` name over the hotspot?
  The typed code covers the second only if the first is true. Test on a device early.
- **Auto room on a hotspot:** the phone and laptop may reach the relay from different public
  addresses (IPv4 vs IPv6), and then they won't see each other on their own. QR pairing still
  works.
- **Managed browsers** may forbid non-proxied UDP (`WebRtcIPHandling`), in which case nothing
  can connect. The page detects that and says so.
- **Downloads after an async unlock** can be blocked as not user-initiated. The row keeps a
  "Save again" link.
- **Export compliance** (§4) needs the user's decision.

## 10. Second workstream: the Open Scanner code review

`Docs/OpenScanner-Code-Review.md` (on `main` since e9234ee) is the "Folio to Rescriva domain migration" session's review of the
Open Scanner code still in Rescriva.
The user wants a cloud session to make these changes. That session's notes:

- **Base:** `bowman-mw/rescriva` `main` at e9234ee. Work on its own feature branch, separate from
  `nearby-share`. Merge to `main` only when the user says so.
- **Already done:** review bugs 5 (the action bar on a deleted line), 6 (the page viewer's back
  pill) and 8 (Speak) are fixed on branch `speech-reader`. Skip them.
- **Order:**
  - **PR 1:** review sections 1 (delete dead code) and 2 (bug fixes), plus the `capturesArray`
    and library-search fixes from section 3. Behaviour stays the same apart from the fixes.
  - **PR 2:** the widget and Spotlight replacements from section 4. Users will see these.
  - The "requests from outside the app" item (one queue in `ContentView`) touches
    `ContentView.swift`, which Share Nearby also edits. Either one session owns both, or they go in
    order. Keep `screen(for:)` and `open(_:)` stable.
- **Verify:**
  - Unit tests: `xcodebuild test -project openscanner.xcodeproj -scheme scanner -destination
    "platform=iOS Simulator,name=<any iPhone>" -only-testing:scannerTests CODE_SIGNING_ALLOWED=NO`.
    All 409 tests passed at 7c54fd7.
  - Mac Catalyst build: `-destination "platform=macOS,variant=Mac Catalyst"`.
  - Add a test for each bug fixed. That needs a Mac; a Linux cloud session has no Xcode.
- **House style:**
  - "Power of 10"-style rules: short functions, every return value checked, no recursion,
    bounded loops, and failures logged with `Log.share.error("…")` (os.Logger, `scanner/Rescriva/Log.swift`).
  - Comment density and naming match the surrounding code.
  - Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Device-only checks:** four items can't be confirmed in the simulator. They're listed under "Not
  verified on a device" at the end of the review.
- **Questions about a finding:** ask the "Folio to Rescriva domain migration" session, if it's still
  running. It isn't changing any of these files on `main`.

### §10 addendum: the review rechecked on 1d2cded (PR #1, "paper and ink")

The review's line numbers were taken at 7c54fd7. PR #1 changed 8 of the files it covers, and Share
Nearby shifts lines further in ContentView and HomeView, so **find things by symbol, not by line
number**. The migration session rechecked every affected finding on 1d2cded, and all of them still
hold, with two exceptions:

- **Keep `Color.accent`.** `ScannerWidget/WidgetView.swift` now uses it. Delete only
  `Color.background` and `Color.foreground`, with their two colour assets. `DefaultBackgroundGradient`
  is still used only by the widget.
- **Widget:** its caption already says "Scan", in Rescriva's look. The rest of the finding stands:
  - the fetched data is unused;
  - it opens the widget's own empty store;
  - the widget target has no entitlements;
  - the gallery text still says "Document Scanner" / "Open Scanner widget" (`ScannerWidget.swift`
    `configurationDisplayName`/`description`).

Bugs 5, 6 and 8 are already done on branch `speech-reader`, so skip them. That's why
`LiveCaptureSummary.swift` is no longer in the list below.

Where the code moved, on 1d2cded:
- `ScanGallery.swift`: `capturesArray.first?.thumbnail` is still at about 144. **A new instance of the
  same problem:** `scan.capturesArray.count` (about 200) faults in every page just to count them. Use
  `captures?.count`.
- `HomeView.swift`: search goes through `scan.containsText` (about 262).
- `RecognizedItemView.swift`: `lastUpdate` is set on every keystroke (about 37).
- `ReviewView.swift`: `originalPages` (about 220).
- `QuickLookController.swift`: "Error loading image" (about 136).
- `ContentView.swift`: the Spotlight `.preview(scan)` push, the Mac guard on the scan request, and
  the `requestedClassicScan` handler. Find them by symbol; Share Nearby's edits move them.
