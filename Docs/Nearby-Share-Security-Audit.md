# Share Nearby (Rescriva Share): security audit

*2026-10-12. Scope: `rescriva-share` at 6a94bdc (PROTOCOL.md, `relay/worker.js`, `wrangler.toml`, `dev_relay.py`, `test_relay.py`, `index.html`, `sw.js`, `assets/*.js`, `tests/index.html`, the vendored QR library's provenance) and `OpenScanner/scanner/Share/*.swift` at c342b85 (all 19 files), plus `ContentView` URL handling, entitlements, `Info.plist`, `NearbyShareTests.swift` and the two design docs. Read-only; every cited line was re-read before it went in here. Paths are relative to `Scanner App/`.*

## 1. Summary

The implementation is careful. Every untrusted input (QR payload, relay JSON, data-channel JSON, SDP, candidates, file names) is length- and character-checked before use; SDP injection is not possible; the HMAC `proof` binds both DTLS fingerprints as applied and both ends verify it before any `docs` or `send`; comparisons are constant-time; RNGs are CSPRNGs; the page never puts peer-supplied strings into `innerHTML`; the spec's test vectors are asserted on both sides. **No critical implementation bug was found.**

What matters is design-level, and all of it lives in the **auto room** (same-public-IP path), where there is no shared secret and so no way for the page to authenticate the *app*:

1. **PIN phishing by device impersonation (High).** Anyone sharing the public IP can register as `role=app` named "iPhone", mirror the victim's document list (visible to every page), and collect the PIN the victim types; the PIN travels in clear over that channel and replays against the real phone.
2. **Relay MITM in the auto room (Medium, accepted by design but overstated in the spec).** No secret, no `proof`; a hostile relay can swap fingerprints and inject candidates. "Nothing else ever sees them" (PROTOCOL.md) is true only for an honest relay.
3. **Relay availability (Medium).** No rate limiting; one script can burn the free-plan quota or fill a room.

## 2. Findings

| ID | Sev | Component | Location | Title |
|---|---|---|---|---|
| H1 | High | Protocol / page / app | `assets/peer.js:202-216`, `assets/main.js:68-76`, `scanner/Share/NearbyShareSession.swift:590-614`, `ShareDevice.swift:16` | Auto-room device impersonation lets an attacker phish and replay PINs |
| M1 | Medium | Protocol | `PROTOCOL.md:4-5,12,97-101`; `NearbyShareSession+Link.swift:86-91`; `peer.js:204-207` | Relay or wss MITM can read and alter auto-room sessions; spec says otherwise |
| M2 | Medium | Page | `assets/main.js:181-190, 167` | An untrusted peer can win the `session` dedupe race and retire the real device |
| M3 | Medium | Relay | `relay/worker.js` (no limiter), `:75-81`, `wrangler.toml` | No rate limiting: quota exhaustion and room-fill denial of service |
| M4 | Medium | Protocol / relay | `worker.js:179-198`; `NearbyShareSession.swift:316-322, 573-574` | Same public IP ⇒ strangers see device and document names |
| M5 | Medium | Page | `assets/peer.js:218-248, 370-375` | Page saves any file type and name an unauthenticated "device" sends |
| L1 | Low | App | `NearbyShareSession+Rules.swift:42-52`; `NearbyShareSession.swift:600-613` | Same-room attacker can keep every PIN in perpetual cooldown |
| L2 | Low | App | `scanner/ContentView.swift:86-90`; `NearbyShareView.swift:84-89, 176-181` | Any website can open `openscanner://share?p=` and prompt a pairing with a remote page |
| L3 | Low | Page | `peer.js:173, 228-233` | Unbounded `docs` list and chunk buffering |
| L4 | Low | Page | `index.html:6` | No `frame-ancestors` (meta CSP can't set it); clickjacking possible |
| L5 | Low | Relay | `worker.js:111-114` | Role not enforced; any 64 KB `data` relayed to any peer in the room |
| L6 | Low | Relay | `worker.js:169-172` | Empty `Origin:` passes the allowlist when `EXTRA_ORIGINS` is unset |
| I1 | Info | App | `ShareCertificate.swift`; `SharePeer.swift:289-292`; `NearbyShareSession.swift:898` | Shipped private key: no gain for an extractor; used only in the no-relay path |
| I2 | Info | App / page | `NearbyShareView.swift:476`; `main.js:53-63` | Session-key exposure surface (QR on screen, clipboard, `#k=` link) |
| I3 | Info | Relay | `wrangler.toml:4`, `worker.js:183` | `workers_dev = true` second hostname; `ROOM_SALT` default |
| I4 | Info | App | `ShareMessages.swift:230-237` vs `worker.js:15` | App doesn't strip bidi overrides from hello names (relay does) |
| I5 | Info | App | `scanner/Info.plist` | `ITSAppUsesNonExemptEncryption=false` with bundled BoringSSL; `NSAllowsLocalNetworking` |

## 3. Details

### H1. Auto-room device impersonation and PIN phishing (design)

In the auto room no secret exists, so `peer.js:202-216` accepts any `hello` from anything that joined the relay as `role=app`, and `main.js:69` dials every such peer. `role`, `name` and `device` are self-declared (`worker.js:42-48`). The app sends `docs` (names, sizes) to every page that connects (`NearbyShareSession.swift:567-574`); `unlock` carries the PIN in clear (`peer.js:98`) and the app accepts a PIN from any page (`NearbyShareSession.swift:605-608`).

**Attack.** An attacker on the same public IP (1) opens the page and reads the victim's device name and document names; most phones are literally named "iPhone" (`UIDevice.name` is generic without the entitlement, `ShareDevice.swift:16`); (2) joins `room=auto&role=app&name=iPhone&device=iphone`, answers the victim page's offer, and sends `hello` + a mirrored `docs` with `unlocked:false`; (3) the victim sees a card indistinguishable from their phone (or the only card, see M2) and types the PIN; (4) the attacker replays `unlock` to the real phone and `get`s the file. The 5-try lock doesn't apply: one correct try.

The PIN authenticates the page to the app, never the app to the page, yet the page's copy ("Type each file's PIN to download", `main.js:313`) implies it protects the user.

**Fix.** Replace `unlock {pin}` with a PAKE (SPAKE2 or CPace) keyed on the PIN and bound to `fpOffer|fpAnswer`, so an impersonator learns at most that one guess was wrong and cannot replay. Interim: derive a short check word from `SHA-256(fpOffer|fpAnswer)`, show it on the app's connected-device row and on the page's device card, and tell the user to compare before typing a PIN; and fix M2. A channel-bound HMAC alone is not enough (10^6 offline guesses).

### M1. Relay MITM in the auto room (design; wording wrong)

`NearbyShareLink.provesItself` returns true with no secret (`+Link.swift:87`); `peer.js:204` skips verification likewise. A hostile relay can rewrite `a=fingerprint` in both directions and inject its own public-IP host candidates; with no ICE servers both LAN devices still perform outbound checks to a public candidate and will pair with it. It then reads document names, the typed PIN and every file. With a secret (`#k=` link or pairing) the proof does block this: fingerprints are the ones each side applied (`SharePeer.swift:127-136`, `peer.js:151-152`), both sides verify before `ready`, and `soleFingerprint`/`fingerprint()` refuse SDP with two fingerprint lines. **Fix:** say in PROTOCOL.md §1.2/§2 that auto-room sessions trust the relay; the H1 fix would also defeat a MITM for file access (not for name disclosure).

### M2. `session` dedupe race (implementation)

`main.js:181-190`: when a new connection becomes ready with the same `app.session` as an existing ready one and neither is trusted, the **new** one closes. `session` is sent in clear to every connecting page, so a same-room attacker learns it within a second and can send a `hello` carrying it over a channel to the victim page. If that lands before the real app's hello (a fresh page load, or the Share screen reopening), the real connection closes as `duplicate` and its relay peer id goes into `retired` (`main.js:167`), never dialed again until reload. The victim sees only the fake card. **Fix:** only a trusted connection may displace an untrusted one; never close an existing connection in favour of a new untrusted one; don't retire untrusted losers; treat `session` as a hint, not an identity.

### M3. Relay denial of service (implementation / operations)

No per-IP connection or message limits anywhere in `worker.js`. Each WebSocket is a Worker request and a Durable Object request; the free plan stops at 100k/day (relay README:55-61), so one script looping on connections takes the relay offline until 00:00 UTC. Separately, `MAX_PEERS = 32` (`worker.js:75`) is per room with no per-IP cap: one LAN attacker opens 32 sockets and the victim's devices get "room full". **Fix:** a Cloudflare WAF rate-limiting rule on `/ws` (e.g. 10 connections/min/IP) or a Workers Rate Limiting binding; cap peers per `CF-Connecting-IP` within a room (e.g. 4); set `workers_dev = false` to remove the second entry point.

### M4. Name disclosure to strangers (design)

`networkRoomKey` groups by IPv4 or IPv6 /64 (`worker.js:179-198`). Behind carrier NAT, a corporate egress or a shared VPN exit, unrelated people share a room and see each other's device names (`welcome`/`join`) and, after the automatic connection, every shared document's name and size (`NearbyShareSession.swift:316-322`). The handoff doc acknowledges this (`Nearby-Share-Handoff.md:275`). **Options:** show only a document count until a PIN is entered; require the page to prove a PIN before `docs` are sent (changes the UX); at minimum warn in the Share screen when the auto room holds more than one unknown page.

### M5. Page accepts arbitrary downloads from unauthenticated devices (implementation)

`#fileStarts` (`peer.js:224-225`) takes `name`, `size` and `type` from the device, and `saveFile` writes a Blob under that name (`peer.js:370-375`). Combined with H1, a fake "iPhone" listing "Scan 2026-10-12.pdf" as `unlocked:true` delivers `Scan.pdf.exe` with one click. **Fix:** for untrusted connections accept only `application/pdf` and `image/*`, force the saved extension to match the type, and ignore `name` changes between `docs` and `file`.

### L1. PIN lockout denial of service (design)

`locks[id]` is global per document, which is right against brute force: at most 35 guesses in the first hour, each against a fresh PIN, about a 3.5×10⁻⁵ chance; counters survive reconnects and new peer ids. But five junk guesses from any page change the owner's PIN and refuse the correct one for 30 s doubling to 8.5 h (`+Rules.swift:48`). An attacker can keep every document locked indefinitely while the owner watches PINs churn. Trusted paths still work. **Mitigation:** count wrong tries per (document, page fingerprint) for the first few lockouts before escalating globally, and cap the doubling lower.

### L2. External `openscanner://share?p=` (design, mitigated)

Any website can trigger the scheme (iOS asks "Open in Rescriva?"); `ContentView.swift:88` pushes the Share screen and `NearbyShareView.swift:176-181` shows the "Pair with this computer?" alert, whose text does warn. If the user taps Pair, the attacker's endpoint need not be on the LAN: a public-IP host candidate in the payload is reachable outbound, and the attacker holds the secret, so the connection is *trusted*. Usually the pushed session has no documents, but if the Share screen was already open with documents it is brought to front and the pairing applies to it. **Fix:** refuse pairing payloads whose candidates are all non-private addresses unless explicitly confirmed; don't auto-open the screen when it isn't already showing.

### L3. Page memory (implementation)

`docs` has no count cap (`peer.js:173`); 100k entries explode the DOM. `#receiveChunk` appends until `end` regardless of the declared `size` (`peer.js:228-233`). **Fix:** cap docs (200, matching the app's `maxDocuments`) and abort a download when `done > size`.

### L4. Clickjacking (implementation)

The meta CSP at `index.html:6` is good (`script-src 'self'`, no inline, `object-src 'none'`) but `frame-ancestors` is ignored in meta and GitHub Pages sets no `X-Frame-Options`. **Fix:** `if (top !== self) document.documentElement.hidden = true` early in `main.js`.

### L5 and L6. Relay nits (implementation)

`worker.js:111-114` relays any object ≤ 64 KB to any peer in the room, web→web included (the handoff doc notes this). `worker.js:169-172`: `"".split(",")` yields `[""]`, so `Origin: ""` passes; browsers can't send an empty Origin and native clients omit it anyway, so no practical impact. Filter empty entries.

### I1. Built-in private key (confirmed safe as designed)

`RTCCertificate(privateKey:…)` is used only when `builtInCertificate` is true (`SharePeer.swift:289-292`), which only `startDirect` passes (`NearbyShareSession.swift:898`); relay-path connections get a fresh libwebrtc certificate. An extractor can complete DTLS with a page that applied the synthetic answer, but ICE requires `icePwd(secret)` and the page then requires `proof(secret, "app", …)` before `ready`/`docs`/`send` (`peer.js:168, 204-207, 285`). Anyone holding the secret (the QR) is already fully trusted, so the key adds nothing. Fingerprint, DER and key consistency are unit-tested (`NearbyShareTests.swift:617-626`).

### I2–I5

The `#k=` link is dropped from the address bar via `replaceState` (`main.js:56`) with `no-referrer`; residual copies live in the camera app's history and the clipboard ("Copy link", `NearbyShareView.swift:476`), and a photographed QR grants full trust for the session with no way to revoke one page short of closing the screen. `workers_dev = true` exposes a second hostname with the same checks. `ShareJSON.cleanName` strips control characters but not U+202A–E / 2066–9, so a page's name can carry bidi overrides into the app UI (cosmetic). `ITSAppUsesNonExemptEncryption=false` with WebRTC's BoringSSL is a legal declaration the handoff already flags. `NSAllowsLocalNetworking` only matters for the `ws://` test override, which comes from UserDefaults and isn't reachable by other apps on iOS.

## 4. Design acceptances (stated plainly)

1. In the auto room the page cannot authenticate the device, and the relay (and Cloudflare) can MITM. The PIN protects the phone's files from passive eavesdroppers and casual same-room users, not from an active impersonator or a hostile relay.
2. Device names and document names are visible to everyone sharing your public IP.
3. Possession of a QR (either side) or the `#k=` link equals full trust for the session.
4. Any same-room party can force PIN changes and cooldowns on all documents.
5. ICE uses host candidates only, so connectivity is LAN-only by design, but a public-IP endpoint is still reachable outbound (L2 and M1 rely on this).

## 5. Checked and found OK

- **Derivations** (`ShareCodes.swift:56-75` vs `crypto.js:26-38`): domain-separated labels, HMAC-SHA256 keyed by the secret, unpadded base64/base64url; all PROTOCOL.md §1.1 vectors asserted in `NearbyShareTests.swift:57-74` and `tests/index.html:20-26`, including swapped-fingerprint rejection. Connection codes and the payload layout match byte for byte.
- **Fingerprint parsing** is strict: 32 upper-case hex pairs after uppercasing (`ShareSDP.swift:154-160`, `sdp.js:14-19`); both sides refuse SDP with ≠1 fingerprint line; the app refuses offers that aren't exactly one `m=application … webrtc-datachannel` section (`ShareSDP.swift:90-102`).
- **QR payload parser** (`SharePairing.swift`): every length byte bounded, `count ≤ 8`, kinds 4/6/109 only, port ≠ 0, trailing bytes rejected, ufrag/pwd/mid restricted to ice-chars/token chars so nothing can inject SDP lines; truncation at every length is unit-tested. `replacingICECredentials` refuses non-ice-chars. Relay candidates: printable ASCII, ≤ 1 KB, `candidate:` prefix, token `sdpMid`, `sdpMLineIndex ≤ 0`.
- **URL handling**: scheme and host checked (`NearbySharePending.swift:27`, `SharePairing.swift:61-63`), length-capped; external links need the confirmation alert; scanned or pasted codes are user-initiated.
- **Uploads to the app**: consent card before `accept` (`NearbyShareView.swift:657-692`); binary frames ignored until accepted; size enforced on every write and at `finish`; type restricted to `application/pdf` / sanitized `image/*`; file name stripped of path and control characters and leading dots, clipped to 200 bytes, written under `tmp/NearbyShareReceived/<uuid>/`; image decode capped at 200 M pixels with a 4096 px thumbnail; temp folders removed after import, on stop, and swept. (PDF content validation inside `PDFLibrary.importPDF` not examined.)
- **Downloads** require `trusted || unlocked` on every `get`, re-checked per chunk; per-page queue cap 32; 48-link cap; connect and hello timeouts.
- **PIN handling**: `Int.random` (SystemRandomNumberGenerator), unique per session, constant-time compare for PIN and proof, no PIN/secret/key in any `print`, all state on the main actor with no suspension between reading and writing lock state.
- **Web page**: all peer strings go through `textContent`/`setAttribute`; the three `innerHTML` uses are constant SVG or locally generated QR path data; no `eval`, `Math.random`, `postMessage` or `window.opener` exposure; `crypto.getRandomValues` for secrets; `?relay=` override only on localhost; the service worker is network-first with same-origin GET scope, so stale JS is served only offline.
- **Relay**: exact-match Origin (evil-suffix variants are in `test_relay.py:402-409`), anchored room regex, role and device allowlists, name cleaning (control and bidi), 64 KB check in both UTF-16 and UTF-8, JSON errors swallowed, `CF-Connecting-IP` (not spoofable through Cloudflare), IPv4-mapped IPv6 handled, 72-bit random peer ids, signals confined to one Durable Object (no cross-room path), stale sweep via hibernation timestamps. `wrangler.toml` holds no account id or secrets; `.wrangler/`, `.dev.vars` and `node_modules/` are gitignored and untracked.
- **Vendor**: `assets/vendor/qrcode.js` is Kazuhiko Arase's qrcode-generator (MIT) with the upstream header intact, loaded same-origin under `script-src 'self'`; only the page's own link reaches it. Provenance against the 1.4.4 npm tarball not verified.

**Unverified:** libwebrtc's acceptance of the mangled ufrag/pwd on a device (spike-tested only), Mac Catalyst sandbox allowing inbound UDP without `network.server`, PDFKit robustness for received PDFs, and `pc.remoteDescription.sdp` fidelity in Safari for the page-side fingerprint read.

## Status (2026-10-13)

What was done about each finding in the fix pass the same day, checked against the uncommitted working trees (rescriva-share: `PROTOCOL.md`, `README.md`, `assets/`, `relay/`, `tests/`; OpenScanner: `scanner/Share/`, `scanner/ContentView.swift`, `scannerTests/NearbyShareTests.swift`, `Docs/`) rather than taken from the fixers' reports. Committed to main the same day; the relay and page are not yet deployed. Not touched, at the user's request: anything about the custom on-device (tier-3 Core ML) model, which this audit doesn't cover anyway.

Still manual: `npx wrangler deploy`, `npx wrangler secret put ROOM_SALT`, the WAF rule in the Cloudflare dashboard, and a real-device run of the check number (both ends changed together, so the simulator-only runs prove only that each side computes the vectors).

| ID | Status | Files changed | What was done, or why not |
|---|---|---|---|
| H1 | Fixed (the interim fix; the PAKE stays the eventual one) | `assets/crypto.js`, `assets/peer.js`, `assets/main.js`, `assets/style.css`, `tests/index.html`, `PROTOCOL.md` §1.1–1.2, `README.md`; `scanner/Share/ShareCodes.swift`, `scanner/Share/NearbyShareSession+Link.swift`, `scanner/Share/NearbyShareSession.swift`, `scanner/Share/NearbyShareView.swift`, `scannerTests/NearbyShareTests.swift`, `Docs/Nearby-Share-App-Design.md` | Both ends derive a check number from the SHA-256 of `rescriva-share/check/v1`, `fpOffer` and `fpAnswer` joined by `\|` (first eight bytes, big-endian, mod 10⁹: nine digits, because the answering side can try certificates until a six-digit one matched) and show it on every untrusted device card and connected-computer row with the instruction to compare before typing a PIN; the vectors are asserted on both sides. The copy says what the PIN does and doesn't prove ("Type each file's PIN to download" is gone). Not done: delaying the number on the app side; the PAKE. |
| M1 | Fixed | `PROTOCOL.md` intro and §1.2 (and the `Docs/` copy) | "Nothing else ever sees them" is gone; §1.2 says a session with no secret trusts the relay, what a hostile relay could do, and that the check number would not match then either. |
| M2 | Fixed | `assets/main.js`, `PROTOCOL.md` §4 | The only dedupe rule left is that a trusted connection replaces an untrusted one with the same `session`; two untrusted connections claiming one `session` are both kept, each with its own check number; `retired` holds only a peer displaced by a trusted connection and is cleared when that connection closes or the relay says the peer left. A phone whose relay socket reconnects while its WebRTC link stays up can briefly show two cards. |
| M3 | Fixed in code; deploy pending | `relay/worker.js`, `relay/wrangler.toml`, `relay/dev_relay.py`, `relay/test_relay.py`, `relay/README.md`, `PROTOCOL.md` §2 | A `[[ratelimits]]` binding budgets 20 new `/ws` connections a minute per address (IPv4, or the IPv6 /64), answering 429 with `Retry-After: 60` and failing open if the limiter throws; four peers per address in a pairing room (the fifth is told `too many connections` and closed 1008); the auto room has no per-address cap because an IPv4 auto room already is one address; `workers_dev = false`; the README has the dashboard WAF rule (10 requests per 10 s on `/ws`) and warns that the full test suite would trip the budget against the live relay. The deploy, the secret and the WAF rule are still to do. |
| M4 | Partly (the audit's minimum) | `scanner/Share/NearbyShareSession.swift`, `scanner/Share/NearbyShareView.swift`, `scannerTests/NearbyShareTests.swift` | The session counts the auto room's web peers (plus any connected from it that the relay no longer lists) and the screen shows a warning banner above one. Names are still visible to everyone in the room; count-only-until-PIN was not taken. |
| M5 | Fixed | `assets/peer.js`, `assets/main.js`, `tests/index.html`, `PROTOCOL.md` §4 | A file is saved under its `docs` name only (cleaned: separators and controls to `_`, bidi dropped, leading dots and spaces gone, 200 characters with the extension); from an unpaired device the page takes only PDF, the plain image types and the app's own export types (docx, pptx, md, txt), with the extension forced to match, and only at the listed size within the app's own caps (1 GiB PDF, 128 MiB otherwise); anything else is refused before `get`, before the Save dialog, or answered with `cancel`. |
| L1 | Fixed | `scanner/Share/NearbyShareSession+Rules.swift`, `scanner/Share/NearbyShareSession.swift`, `scannerTests/NearbyShareTests.swift` | Wrong tries are counted per (document, connection): five from one connection refuse that connection for 30 s while others carry on; 15 across connections, or three refused connections, replace the PIN and refuse everyone for 30 s doubling to at most 32 minutes (was 8.5 h). The trade the audit asked for: one page gets 15 guesses per PIN instead of 5. Keyed by connection id, so a reconnecting page starts a fresh five. |
| L2 | Fixed | `scanner/ContentView.swift`, `scanner/Share/NearbySharePending.swift`, `scanner/Share/SharePairing.swift`, `scanner/Share/ShareNetwork.swift`, `scanner/Share/NearbyShareView.swift`, `scanner/Share/NearbyShareSession.swift`, `scanner/Share/SharePeer.swift`, `scanner/Share/ShareSDP.swift`, `scannerTests/NearbyShareTests.swift` | Both halves. A link from outside no longer opens the screen: it waits in `NearbySharePending` for up to 120 s and a toast offers "Open" (a Share screen already on the stack is brought to the front, as before). The alert then depends on the offer: when every candidate is a local-network address (RFC 1918, 169.254/16, fe80::/10, fc00::/7, their IPv4-mapped forms, `.local`), plain "Pair" dials only those candidates and never joins the pairing relay room, so the secret's holder can't redirect it elsewhere; otherwise the title warns, Cancel is the default, and a destructive "Pair anyway" dials everything. |
| L3 | Fixed | `assets/peer.js`, `PROTOCOL.md` §4 | `docs` is cut to 200; a download is cancelled the moment it would exceed its declared size. |
| L4 | Fixed | `assets/main.js` | `if (top !== self)` hides the page and stops the module before anything else runs. |
| L5 | Fixed | `relay/worker.js`, `relay/dev_relay.py`, `relay/test_relay.py`, `PROTOCOL.md` §2 | A `signal` is delivered only between a `web` and an `app` peer; same-role signals are dropped silently. |
| L6 | Fixed | `relay/worker.js`, `relay/test_relay.py`, `relay/README.md` | Empty entries are filtered after the split, so an unset `EXTRA_ORIGINS` or a trailing comma never admits `Origin: ""`. |
| I1 | Not done | — | No change needed; the audit found it safe as designed. |
| I2 | Not done | — | Design acceptance 3 stands; no change. |
| I3 | Fixed | `relay/wrangler.toml`, `relay/README.md` | `workers_dev = false`; `ROOM_SALT` is documented as required before production (`npx wrangler secret put ROOM_SALT`, never a `[vars]` entry), with the default kept for local runs. Setting the secret is still to do. |
| I4 | Fixed | `scanner/Share/ShareMessages.swift`, `scannerTests/NearbyShareTests.swift` | `cleanName` drops U+202A–202E and U+2066–2069 by name, as the relay does. |
| I5 | Not done | — | The export-compliance declaration is the user's; ATS is unchanged. |

**The design acceptances, re-read.** 1 still holds, with the check number as the interim mitigation PROTOCOL.md §1.2 now describes. 2 holds; the screen warns when more than one unknown page is in the room. 3 holds. 4 no longer reads as written: a same-room party needs 15 wrong guesses, or three connections each refused, to force one PIN change, and the cooldown stops doubling at 32 minutes. 5 holds. The items under **Unverified** are still unverified.
