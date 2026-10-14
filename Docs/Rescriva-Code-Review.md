# Rescriva code review

*2026-10-12, main at c342b85 (OpenScanner) and rescriva-share at 6a94bdc. Builds, tests and every cited line were checked on this Mac with Xcode 26.5. Companion document: `Docs/Nearby-Share-Security-Audit.md`.*

**Method.** Clean Debug builds for the iOS Simulator and Mac Catalyst, the Archive log from 23:16 tonight, the full unit test suite on an iPhone 17 Pro simulator, and four reading passes (architecture and plan compliance, Share Nearby correctness, a security audit of the relay and P2P code, and random spot checks of the rest). Each pass's main claims were re-read by hand before going in here.

## Verdict in brief

- **The code compiles clean.** Clean Simulator and Catalyst Debug builds: 408 and 346 Swift compiles, **zero compiler warnings**. The Release archive: zero warnings. The suite: **482 tests, 0 failures**. The "new errors every build" come from three non-compiler sources (section 1), not from drift in the Swift.
- **Architecture is sound where it matters** (one Codable IR between extraction and three renderers; strict input checking everywhere untrusted data enters), but **three generations of state management** and the **unfinished Open Scanner clean-up** (`Docs/OpenScanner-Code-Review.md`) are still there.
- **Plan compliance:** the PDF scanner, capture, tier 1 understanding, review flags, DOCX/PPTX writers and the Acrobat areas 1–4 match the plan. The biggest departures: tier 3 detectors run only on Apple Intelligence phones (the plan put them on every iOS 26 phone), the Markdown/Mermaid export exists but has no UI, DOCX diagram arrows don't attach to shapes, and the equation fallback drops the plan's image route.
- **Share Nearby:** the protocol and its three implementations agree; the real weaknesses are design-level in the same-network room (see the audit) plus a page that never re-dials a dropped device.

---

## 1. Why every build shows something new

### 1.1 "Operation not permitted" at Archive (the dSYM script)

`openscanner.xcodeproj/project.pbxproj`, phase `Make WebRTC dSYM` (`FAD702818EB0D6B76A776B7C`), runs only when archiving (`buildActionMask = 8`, `runOnlyForDeploymentPostprocessing = 1`). Tonight's archive log (`740B2079…xcactivitylog`) shows exactly two errors, both from it:

```
error: Operation not permitted
Command PhaseScriptExecution emitted errors but did not return a nonzero exit code to indicate failure
```

**Root cause, reproduced.** `ENABLE_USER_SCRIPT_SANDBOXING = YES`, so the phase runs under `sandbox-exec` and may only write its declared outputs. The script declares two:

```
$(DWARF_DSYM_FOLDER_PATH)/WebRTC.framework.dSYM/Contents/Resources/DWARF/WebRTC
$(DWARF_DSYM_FOLDER_PATH)/WebRTC.framework.dSYM/Contents/Info.plist
```

Running the same `dsymutil` against the built `WebRTC` binary writes four files:

```
WebRTC.framework.dSYM/Contents/Info.plist
WebRTC.framework.dSYM/Contents/Resources/DWARF/WebRTC
WebRTC.framework.dSYM/Contents/Resources/Relocations/aarch64/WebRTC.yml   ← undeclared
WebRTC.framework.dSYM/Contents/Resources/Relocations/x86_64/WebRTC.yml    ← undeclared
```

The `Relocations/*.yml` writes are denied, dsymutil prints the error, and the trailing `| grep -v "no debug symbols" || true` hides the exit code, which is the second message.

**Fix (pick one).**

1. **Delete the phase.** The dSYM it makes has no symbols (dsymutil says so), so it only silences App Store Connect's "no dSYM for WebRTC" warning, which is cosmetic. This is the simplest and what I'd do.
2. **Keep it and declare the extra output**, and stop swallowing failures:
   ```sh
   set -e
   out="${DWARF_DSYM_FOLDER_PATH}/WebRTC.framework.dSYM"
   xcrun dsymutil "${SCRIPT_INPUT_FILE_0}" -o "$out" 2> >(grep -v "no debug symbols" >&2)
   ```
   with a third output path `$(DWARF_DSYM_FOLDER_PATH)/WebRTC.framework.dSYM/Contents/Resources/Relocations/aarch64/WebRTC.yml`. (The sandbox accepts any declared path; the x86_64 file is only written for simulator slices.)
3. Set `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the `scanner` target. Works, but loses the protection for every future script.

### 1.2 "Metadata extraction skipped. No AppIntents.framework dependency found."

One warning per build, from the `RescrivaSafariExtension` target (`ExtractAppIntentsMetadata` step). The extension has no App Intents, so the tool has nothing to do. Harmless. Silence it with `LM_SKIP_METADATA_EXTRACTION = YES` on that target (and on `ScannerWidgetExtension` if it ever appears there).

### 1.3 Runtime console noise mistaken for build problems

From the recent session transcripts (the glare bug session and the rename session):

| Message | Source | Status |
|---|---|---|
| Thread Performance Checker, "hang risk" at `AppState.swift:78` (Catalyst) | First `AVSpeechSynthesizer.isSpeaking`, then `CLLocationManager.location` read on the main thread | Both removed (`speech-reader` merge, then 7821feb) |
| `CoreData: error … File unexpectedly appeared during sanity check` | A stray `Scanner.sqlite` from the sibling template project (same bundle id) in the simulator container | Environment, not code; delete the simulator's app container or reset the simulator |
| `CoreData: error: (26) … file is not a database` during tests | `LibraryTests.swift:280` deliberately opens a corrupt store | Expected test output |
| `Rescriva: couldn't read a smart folder rule: … not valid JSON` during tests | `LibraryTests` feeds bad JSON on purpose | Expected test output |
| `Failed to connect to linkd to request update AppShortcut parameters` | `AppIntents.updateAppShortcutParameters()` in the simulator | Simulator-only; no phrase has a parameter, so the call does nothing anyway |

### 1.4 Project hygiene that feeds the churn

- **`Package.resolved` is not in git.** `.gitignore` has `*.xcworkspace`, which also ignores `openscanner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. The pin is `exactVersion 153.0.0`, so the practical risk is small, but every fresh worktree re-resolves. Un-ignore that one file.
- **Two merged worktrees still exist**: `.worktrees/glare-capture` (7821feb) and `.worktrees/nearby-share` (8d6ffdc). Both branches are merged into main (`git branch --merged main`). Remove them with `git worktree remove`.
- **`Website/` is untracked** (the rescriva.com landing page). Decide where it lives.
- `scannerUITests` builds in the scheme but is not in the Test action, and `scannerTests/scannerTests.swift` is the Xcode template.
- No `SWIFT_STRICT_CONCURRENCY` or Swift 6 language mode; see §2.2.

---

## 2. Architecture

### 2.1 What holds up

- **The IR boundary.** `Rebuild/RescrivaDocument.swift:17-47` is Foundation-only Codable. Renderers read only the IR plus figure assets (`Export/ExportService.swift:87-92`, `DOCXRenderer.swift:23`, `PPTXRenderer.swift:21`, `TextRenderers.swift:239,325`). Review edits write back into the IR (`Rebuild/DocumentEditing.swift`). This is the plan's central promise and it is kept.
- **Input validation.** QR payloads, relay JSON, data-channel JSON, SDP, candidates and file names are all length- and character-checked before use (details in the audit). `OOXML.escape` covers every user-text node and attribute traced in both renderers; zip entry names are constants.
- **Persistence.** Model versions 1→{2,3}→4 use inferred mapping; every v4 attribute is optional, so the inference is safe. The container name, iCloud id, history tracking and merge policy are unchanged from Open Scanner, as the earlier review required.
- **Hot spots are long, not tangled.** `GlareFusion.swift` (1,863 lines) is a namespace enum in six MARK'd extensions, longest function 92 lines; `NearbyShareSession.swift` (1,057) has a longest function of 27 lines. `DiagramDetector.detect` (~166 lines at `:52`) is the one function worth splitting.
- **No retain cycles found** in the long-lived objects (`CaptureCamera.swift:205,763` weak captures and `deinit` at 581-585; every session→relay/peer closure in Share is `[weak self]`).

### 2.2 Findings, ranked

1. **Rendering DOCX/PPTX blocks the main actor.** `ExportService` is `@MainActor`; the PDF path renders in `Task.detached` (`ExportService.swift:75`) but `.docx`/`.pptx` call `DOCXRenderer.render`/`PPTXRenderer.render` inline (`:90-92`). Both renderers are pure; move them behind the same detached task. `ZipArchive` is also STORED-only (`Export/ZipArchive.swift:26-31`), so exports are larger than needed.
2. **Rebuilder is welded to Core Data and the main actor.** `Rebuild/Rebuilder.swift:76-77,123-125,213-215` read and write `Scan` directly from a `@MainActor struct`, so extraction can't run without a managed object. `recognizeMissingText` polls `Task.sleep(150 ms)` up to 200 times (`:80-81,267-274`) instead of awaiting the in-flight task. `buildPages` (`:136-159`) runs seven passes per page and `UIImage(data:)` is decoded again in `buildPage` (`:296`), `detectDiagrams` (`:391`) and inside the detectors.
3. **Three generations of state and five inbound-request paths.** Per-window `@Observable RescrivaRouter` (`Rescriva/RescrivaRouter.swift:71-73`) coexists with `ObservableObject` singletons (`ContentView.swift:17-18`) and 16 `static let shared` singletons. `ContentView` drains external requests via `appState.openScan` (`:36-42`), `appState.viewState` used as a command (`:44-51`), `navigationManager.requestedClassicScan` (`:52-58`), the Inbox notification (`Inbox/Inbox.swift:46-51`) and `NearbySharePending` (`:88-91`). The earlier review prescribed one pending-request queue; it isn't done, so its bug 9 (Siri cold-launch race) stays plausible.
4. **Swift 5 mode with Swift 6 discipline only by convention.** 123 `@MainActor`, 52 `Sendable`, 15 `MainActor.assumeIsolated`, 6 `@unchecked Sendable` with written confinement arguments (`CaptureCamera.swift:447-453`). What Swift 6 would flag: `AppState`/`NavigationManager` are un-isolated singletons mutated from intents and SwiftUI (`AppState.swift:27-34`, `NavigationManager.swift:10-23`); `AppState.lastScanIndex` runs a synchronous Core Data fetch from a non-isolated property (`AppState.swift:36-47`, still used at `DataExtensions.swift:21`); `LoadResult` is mutated from Core Data's load callback (`Persistence.swift:82-95`); 32 `Task.detached` sites, some fire-and-forget without cancellation (`Data/OriginalStore.swift:148,346`, `Data/FigureStore.swift:281`). Turning on `SWIFT_STRICT_CONCURRENCY = complete` in Debug would make the next migration a list instead of a surprise.
5. **Error handling is print-only.** 0 empty `catch {}` (good), but 70 of 121 catch bodies only `print`, 129 `print("Rescriva:` and no `os.Logger` in the app target (the Safari handler uses one). The `try?`s that matter: `Rebuilder.swift:297` turns a Vision document-reader failure into a silent heuristic fallback; `PDFLibrary.swift:103-106` makes a PDF with a corrupt `info.json` vanish from the library; `ScanModel.swift:93-101` decodes `rebuiltDocument` with `try?` while `RescrivaDocument.version` (`RescrivaDocument.swift:19`) is never read, so a future schema change silently throws away review edits and forces a rebuild.
6. **Duplicated paths.** Three markup stacks: Annotate over scans (`Annotate/AnnotationSession.swift:14`), PDF annotations (`Documents/PDFEditSession.swift:22`), and Quick Look's destructive markup (`UIKit/QuickLookController.swift:117-120`), with two overlapping tool enums. Two equation parsers that can drift: `LaTeXToOMML` for export and `MathParser` for preview (`Views/RebuiltDocumentView.swift:341-378`). Two library homes embedding `LibraryHomeView` (`ContentView.swift:127`, `Views/HomeView.swift:177`, `Library/Workspace.swift:412`). Smaller: `removeQuietly`/`removeIfPresent` ×3, two file-name sanitizers, `presetGeometry` and `isDark` in both renderers.
7. **The Open Scanner clean-up is mostly undone.** Still present with zero callers: `DataExtensions.swift` `createDefaults`(15), `reversedCaptures`(36), `totalRecognizedItems`(41), `firstThumbnail`/`lastThumbnail`(49,61), `pdfDocumentFile`(129), `textDocument`(162,278), `titleSuggestion`(270,309), `textUrl`(315), `CreateOperation`/`UpdateOperation`(409,424); `Extensions/StringMetrics.swift`; `AppState.lastScanIndex`/`openRecognizedItem`; `NavigationManager.requestedLiveScan` and the empty `openApp()` (`NavigationManager.swift:16-18`), which is what `OpenAppIntent` calls (`AppIntents.swift:31`). `MarkdownRenderer` has no caller outside tests.

---

## 3. Spot checks (outside Share Nearby)

### High

1. **Stale Spotlight result crashes the app.** `scannerApp.swift:39-49` → `Persistence.swift:59-65,97-103` resolve the activity identifier with `object(with:)`, which returns a fault for any well-formed URI; `recognizedItem.parent?.parent` fires it and `ContentView.swift:36-42` pushes `.preview(scan)`. A scan deleted here or on another device stays indexed; tapping it raises `NSObjectInaccessibleException`. Use `existingObject(with:)` and skip deleted scans. (Earlier review bug 2, still open.)

### Medium

2. **The widget reads an empty database.** `ScannerWidget/ScannerWidget.swift:24,28` uses `PersistenceController.shared`, which opens `Application Support/scanner.sqlite` in the widget's own container. The widget target has no `CODE_SIGN_ENTITLEMENTS` (only the app and the Safari extension do), no App Group, and the app's store isn't in the group anyway. It also spins up `NSPersistentCloudKitContainer` and Spotlight indexing inside a 30 MB extension. Make it a static launcher (the earlier review's recommendation).
3. **Inbox "send the link" download is unbounded.** `Inbox/Inbox.swift:142-152` uses `URLSession.shared.download(for:)` with no size cap, where extension-sent files are capped at 150 MB (`InboxDrop.swift:42`). Check `Content-Length` or stream with the same `maxBytes`.
4. **`NSDataDetector` ranges mix UTF-16 and Character offsets.** `DataExtensions.swift:376-380` passes `NSRange(0, text.count)` and converts with `index(offsetBy:)`. Emoji or CJK text shifts the detected phone/email/URL strings that `RecognizedItemView.swift:78-87` acts on. Use `utf16.count` and `Range(match.range, in: text)`. (Earlier review bug 3.)
5. **Library grid faults full page JPEGs for thumbnails.** `ScanGallery.swift:144` and `Workspace.swift:519` call `scan.capturesArray.first?.thumbnail`; `capturesArray` (`DataExtensions.swift:29-34`) sorts every capture, and `imageData` is an inline Binary, so each card load pulls whole pages into the row cache. (Earlier review §3.)
6. **`rebuiltDocument` is JSON-decoded on every read.** `ScanModel.swift:93-101`, 25 call sites, several in view bodies. Cache the decoded document.

### Low

7. `LaTeXToOMML.swift:415-451` → `parseArgument` → `parseAtom` → `parseCommand` recurses without `enter()`; only `parseSequence` counts depth (`:278-287`, `maxDepth` 32). `\hat\hat\hat…` up to `maxLength` 4000 nests ~1,000 frames. Input is the on-device detector, so low risk; add `enter()` in `parseAtom`.
8. **Mac Catalyst: the Inbox trusts any local writer.** The App Group folder is writable by any non-sandboxed Mac process; `InboxStore.swift:90-100` validates structure only and `startsLikePDF` runs only in the extension's `commit`. Re-check the magic bytes on import.
9. Hand-off file names are capped at 80 Characters, not bytes (`InboxDrop.swift:149-157`); 80 emoji exceed 255 bytes and `createFile` fails with a generic error.
10. `InboxManifest.swift:60-63` accepts plain `http` links, but ATS (only `NSAllowsLocalNetworking` is set) will refuse them; require `https`.
11. `transcript` is Spotlight-indexed (model line 48), so scanned text is system-searchable. A privacy choice worth documenting.
12. Open-With images are decoded on the main actor (`ContentView.swift:98` → `Workspace.swift:318-325`).

### Checked and OK

`openscanner://` handling (`ContentView.swift:85-105`) parses no query parameters or paths; file URLs come only from the system. Security-scoped `start/stop` pairs are balanced (`PDFLibrary.swift:125-126`, `Workspace.swift:320-338`, `PDFPageOrganizer.swift:281-282`). Inbox manifests are written last via atomic rename; names pass `isPlainFileName`; ids are UUID-validated; the extension's manifest has no `externally_connectable` and only `activeTab/scripting/nativeMessaging/contextMenus`; `WebPagePDF` uses a non-persistent store with JavaScript off. PDF passwords live only in memory (`PDFEditSession.swift:324-363`), never in `info.json`. No `try!`, `as!`, `fatalError`, force-unwrapped `URL(…)!`, deprecated UIKit APIs or TODO/FIXME markers outside Share. Localization is consistently `String(localized:)` except the widget's stale "Document Scanner" strings and a few exported-file literals.

---

## 4. Plan compliance

Against `Scan-to-Doc Slides App — Plan.md` and `Docs/Acrobat-Parity-Plan.md`.

| Plan item | Status | Evidence |
|---|---|---|
| PDF scan on every iPhone (iOS 17 floor) | Implemented | `DeviceTier.pdf` `RescrivaRouter.swift:185-200`; deployment target 17.0; `Export/SearchablePDF.swift` |
| Basic rebuild = tier 1 + tier 3 on iOS 26 | **Deviates** | Diagrams and equations run only when `tier == .smart` (`Rebuilder.swift:146-150`); Basic gets tier 1 only |
| Smart rebuild = tiers 1–3 on Apple Intelligence | Partial | `.smart` = `SystemLanguageModel.default.isAvailable` (`RescrivaRouter.swift:198-199`); tier 2 is text-only word re-ranking (`Rebuild/AppleIntelligence.swift:38-61`, 60 words / 45 s cap) plus LaTeX refinement; no role labels, no diagram check |
| Hide modes the device can't run | Deviates (minor) | Shown locked, not hidden (`LiveScanSummary.swift:314`, `ExportSheet.swift:156`) |
| VisionKit document camera | Deviates (documented) | Own AVFoundation + Vision camera (`CaptureCamera.swift:5-6`, README) |
| Camera / photo library / PDF input; cleanup; whiteboard glare; keep original; aspect-ratio default | Implemented | `PageCleanup.swift`, `GlareFusion`, `OriginalStore.swift`, `ScanModel.swift:183` |
| PDF scan features (reorder, rotate, crop, filters, name, compression, share, notes, password) | Implemented | `PageEditorView.swift:168-174`, `PageLooks.swift`, `PDFOptions.swift:46-47`, `SearchablePDF.swift:119-140` |
| Tesseract / OpenCV fallback | Missing (by choice) | No references; `PageColorSampler.swift:6` |
| Tier 1 document reader (tables, lists, boxes, alternatives); heuristics first | Implemented | `Rebuilder.swift:499-568, 584-598, 546-549, 559, 619, 661-667` |
| Tier 3 bundled Core ML (shapes, image→LaTeX, style cues) | **Deviates** | No `.mlmodel`; "not shipped yet" (`Rebuilder.swift:11-12`). Classical Vision contours (`DiagramDetector.swift:5-27`), text-based equations (`EquationDetector.swift:5-6`), pixel style cues (`StyleDetector.swift`) |
| Flags: low confidence, table grid, arrow ends | Partial | Word and edge flags only; no table flag kind (`RescrivaDocument.swift:277-279`) |
| B/I/U/strike detection, conservative | Implemented | `StyleDetector.swift`; typed pages only (`Rebuilder.swift:355`); no tier-2 confirmation |
| Whiteboard pipeline 1–8 | Partial | Steps 2–5 and 7 classical; step 6 missing; layout always faithful (`DiagramDetector.swift:1434`); step 8 pptx yes, docx attached connectors no |
| Handwritten notes rules | Partial | Headings/bullets yes; checkbox only from OCR glyphs (`Rebuilder.swift:823-876`); circled→highlight missing; figures skipped on whiteboards (`:313`) |
| IR block types (9) | Partial | 7 of 9: no `chart`, no `shape` (`RescrivaDocument.swift:149-163`) |
| Runs, page fields, font class, notes | Implemented | `:240-252, 50-69, 141, 305-311` |
| Provenance per block and word | Partial | Block-level engine and confidence only (`:129-133`); no per-word record |
| Diagram layout mode | Partial | `layout` token stored but read by no renderer |
| Review: tap flagged word → alternatives; tap block to jump | Implemented | `ReviewView.swift:503`; `ReviewCompareView.swift:5-10` |
| Hold to compare; lasso re-recognize / retag | Missing | No long-press or lasso code |
| Inline text edit; B/I/U toggle; change block type | Partial | No run editing in Review; heading↔paragraph only (`DocumentEditing.swift:155-165`) |
| Merge/split/reorder/delete blocks; table editing; LaTeX live edit | Missing | Only `removeFigure` (`:59`); `EquationView` display-only (`RebuiltDocumentView.swift:138-141`) |
| Diagram editor incl. auto-layout | Implemented except auto-layout | `Drawing/DiagramEditing.swift:33-99`; `layout(in:)` only fits the canvas (`DiagramEditorModel.swift:117-125`) |
| Undo/redo everywhere; autosave; original kept | Partial | Undo in PageEditor and DiagramEditor only; none in Review |
| DOCX: headings, numbering, checkbox controls, merged tables, run props, fonts by class, comments | Implemented | `DOCXRenderer.swift:293, 185/417, 431-437, 454-493, 363-371, 32-39, 221-272` |
| DOCX: join paragraphs across page breaks | Missing | Header `:7` "no page breaks" |
| DOCX: diagram canvas with **attached** connectors | **Deviates** | One `wpg:wgp` group (`:572,609-613`); arrows are `wps:wsp` with no `stCxn`/`endCxn` (`:676`), so moving a shape in Word orphans them. PPTX does attach (`PPTXRenderer.swift:684`) |
| Equations: LaTeX→MathML (KaTeX/Temml in JSC)→OMML, image+alt fallback | **Deviates** | Direct Swift LaTeX→OMML (`LaTeXToOMML.swift:5-10`), no JavaScriptCore, no matrices (`:95-96`); fallback is italic text (`DOCXRenderer.swift:499-504`, `PPTXRenderer.swift:427-432`), not the image |
| PPTX: positioned boxes, title placeholder, sampled palette, theme | Implemented | `PPTXRenderer.swift:350-352, 282, 135, 762-764` |
| PPTX: decorative shapes; slide-master consistency; block notes as comments | Missing | No `shape` block; static master (`:800`); speaker notes only (`:290-291`) |
| Apple Notes export; Shortcuts intent; Copy as rich text | Missing | Generic file share only; two navigation intents; no `NSAttributedString` export |
| Copy for AI (Markdown + Mermaid) | **Deviates** | Renderer complete and tested (`TextRenderers.swift:324-502`) but `ExportFormat` is `docx, pptx, pdf, txt` (`ExportService.swift:15`); no UI path |
| Figures: detect, crop from original, captions, adjustable handles | Partial | Handles not found |
| Data charts | Missing | No chart block |
| Diagram layout modes (dagre), SmartArt, Mermaid→SVG | **Deviates** | Faithful only; no dagre; no SmartArt; Mermaid text only |
| Licensing: Apple + MIT + own; notices | **Deviates** | WebRTC 153.0.0 is BSD-3 and has no notice; Acknowledgements credit only Open Scanner (`SettingsView.swift:246, 329-343`); OSS Document Scanner's whitepaper filter (`PageLooks.swift:7`) also uncredited. No GPL/EPL code found (good) |
| Acrobat 1–4 (view, find, organize, markup) | Implemented | `PDFKitView.swift:43-44,189-202`; `PDFPageOrganizer`; `PDFMarkEditing` |
| Acrobat 5 export formats | Missing | Still four formats |
| Acrobat 6 cloud via Files | Partial | `fileImporter` + `NSFileCoordinator` (`PDFLibrary.swift:131`); no Save to… |
| Acrobat 7 iPad/Mac/Duo | Partial | `WorkspaceLayout` (`Workspace.swift:16-33`), Catalyst on; PDFs device-only, unsynced (`PDFLibrary.swift:13-14`) |
| Acrobat 8 accessibility checks; PDF/A export | Missing in app | Only `Tools/AccessibilityCheckPrototype` |
| Nearby-Share-App-Design requirements | Implemented | `SharePeer.swift:287-301, 527-528`; `ShareRelay.swift:39,57`; `+Rules.swift:15-17`; `NearbyShareView.swift:131-153`; `ContentView.swift:111-121` |

**README vs code:** every claim checks out, with two caveats. "Shortcuts" includes `OpenAppIntent`, whose action is a no-op. "Spotlight" indexes every OCR line and Recently Deleted scans (`Persistence.swift:46-50`).

### Deviations worth fixing first

1. **Tier 3 gated to Smart** (`Rebuilder.swift:146-150`). The plan's point of Basic rebuild was tier 1 + tier 3 on any iOS 26 phone. The detectors are classical Vision, not Core ML, so nothing stops them running everywhere. If this was a deliberate quality decision, write it down.
2. **Markdown/Mermaid export has no UI.** ~180 tested lines are unreachable. Add `.md` to `ExportFormat` (XS, already on the Acrobat plan at `Acrobat-Parity-Plan.md:98`).
3. **DOCX arrows don't attach** (`DOCXRenderer.swift:676`). Add `a:stCxn`/`a:endCxn` as PPTX does.
4. **Equation fallback** drops the typeset form in both renderers; the plan's image+alt route exists nowhere.
5. **Licence notices** for WebRTC (BSD-3) and OSS Document Scanner (MIT) are required by their licences and missing from Acknowledgements.
6. **`rebuiltDocument` version check** before the first schema bump.
7. **Diagram `layout` token is write-only.** Implement cleaned-up/snap or drop the enum.

---

## 5. Share Nearby: correctness

(Security findings are in the audit.) The three implementations and `PROTOCOL.md` agree on every message, field, ordering rule, chunk size and limit; the spec's test vectors are asserted in both `tests/index.html:18-37` and `NearbyShareTests.swift:28-110`; `dev_relay.py` mirrors `worker.js` and `test_relay.py` covers it. No bundled copy of the site exists in the app; `Docs/Rescriva-Share-Protocol.md` equals `rescriva-share/PROTOCOL.md` plus a banner.

### High

- **The page never re-dials a dropped device.** `assets/main.js:67-95` dials only on relay `peers`/`join`. After `unreachable` (`peer.js:42`), `no-hello` (`:156`), ICE `failed` (`:67-69`) or a transient drop, the card disappears and nothing redials until the page's relay socket reconnects or the app restarts its session. `retired` (`main.js:17-18,167`) makes it worse: after the app's relay socket reconnects with a new peer id, the page dedupes the new connection and retires that id for good. Neither side does an ICE restart. Fix: on `closed` with the peer still in `relay.peers`, schedule a backed-off redial; clear `retired` on `leave`.

### Medium

- **A failed page upload leaves the app's slot stuck.** `peer.js:112-119` catches `#runUpload` errors and marks the row failed but sends no `cancel`; the app keeps `link.upload` receiving (`NearbyShareSession.swift:787-793`) and declines every later `send` as `busy` (`:740-743`) until the connection closes. No stall timer on either side.
- **Downloads are held whole in memory, uncapped, and kept** (`peer.js:228-233, 243-245`); "Save again" keeps the Blob URL until the connection closes; `this.transfers` grows unbounded. A 400 MB scan costs ~800 MB in the tab.
- **The state machine has no tests.** `NearbySharePINLock` (`+Rules.swift:14-53`, written "so tests can drive them with any clock") has zero tests; nor do `NearbyShareInput`, `NearbyShareLink`, `ShareRelay.handle` or any `NearbyShareSession` transition. `tests/index.html` covers codes/crypto/sdp only.
- **Silent failures in the UI.** A device that fails to connect vanishes with no toast (`main.js:163-177` toasts only when `wasReady`); decline reasons `busy` and `size` render as a plain "Declined" (`main.js:364` maps only `type`).

### Low

- Dead `/health` endpoint (`worker.js:28-32`); the CSP `connect-src` doesn't allow it anyway.
- Limits duplicated three times (1024-byte candidate cap, SDP cap 64/64/60 KiB, device sets) across `NearbyShareSession.swift:85-97`, `SharePeer.swift:75-76`, `ShareMessages.swift:202-210`, `ShareRelay.swift:46-48`; `ShareRelay.maxPeers = 64` under a comment saying 32.
- `tmp/NearbyShareReceived/` leftovers are never swept (`+Files.swift:60-66` sweeps only `NearbyShare/`).
- Per-chunk file I/O on the main actor (`NearbyShareSession.swift:707`, `+Files.swift:322`).
- `+Link/+Rules/+Files.swift` define new types, not extensions; `ShareCodes.decodeConnectionCode` is app code used only by tests.
- `pagehide` closes the channel right after `bye` (`peer.js:127-133`), so the app may show the device until ICE fails; the page lacks the app's first-frame-means-open fallback (`SharePeer.swift:260-264`).

---

## 6. Tests

482 tests in 29 files pass. Well covered: renderers (ZIP, OOXML, LaTeX→OMML, DOCX, PPTX, text, Markdown), Rebuilder heuristics and flags, all five detectors, page looks, spread split, PDF documents/markup/options/compare, Annotate, Library, Inbox, Nearby Share encodings.

No tests: `GlareFusion` alignment and blending (`GlareCaptureTests` touches only `GlareDebouncer`, `SecondLookTrigger`, `GlareMap`; the fusion harness is a macOS tool), `CaptureCamera`/`CapturePipeline`, `PageOCR`, `NearbyShareSession`/`SharePeer`/`ShareRelay`, Core Data migration v1/v2/v3→v4, `RescrivaRouter` and `ContentView` URL routing, `AppleIntelligence` beyond the unavailable fallback, the Safari extension JS, the widget. Nothing opens exported files in Word or PowerPoint, which the plan names as the phase gate.

## 7. Not verified

Device behaviour (Siri cold launch, `.smart` on shipping hardware, Share Nearby on a hotspot); DOCX/PPTX fidelity in Office, Google Docs, Pages and Keynote; whether libwebrtc on device accepts the mangled ICE credentials (spike-tested only); Mac Catalyst inbound UDP without `network.server`.

## Status (2026-10-13)

What happened to each item above in the fix pass the same day: fixers per area, an integration build, a logging sweep and a second review-fix pass over the result. Every row was checked against the uncommitted working trees of OpenScanner (81 files) and rescriva-share (12 files), not taken from the fixers' reports. Committed to main the same day. Paths under `scanner/`, `scannerTests/`, `ScannerWidget/`, `SafariExtension/`, `Docs/`, `README.md`, `.gitignore` and the project file are OpenScanner's; `assets/`, `relay/`, `tests/` and `PROTOCOL.md` are rescriva-share's.

Held back on purpose, at the user's request: anything about the custom on-device (tier-3 Core ML) model, including the tier-3 gating deviation (§4, 1). The diagram `layout` token decision and the missing plan features in the §4 table are not issues and are listed as not in scope of this pass.

On the final tree, as the last integration run reported it (not re-run for this section): the iOS build-for-testing succeeds and 554 unit tests pass (482 above; the strict-concurrency warnings show on purpose now, see §1.4); the page's test page passes 43/43 and `dev_relay.py` passes its 20 default cases. A Mac Catalyst build compiled clean once with code signing off; the signed build blocks on the Safari extension's keychain prompt and was not completed from a script. Still not done anywhere: an Archive (the dSYM phase), the Spotlight reindex on a device, the check-number round trip on a device, `wrangler deploy`, the `ROOM_SALT` secret and the WAF rule.

| Item | Status | Files changed | What was done, or why not |
|---|---|---|---|
| §1.1 dSYM phase under the script sandbox | Fixed | `openscanner.xcodeproj/project.pbxproj` | Option 2: the phase runs `set -e` under `/bin/bash`, filters only the "no debug symbols" note, and declares the `Relocations/aarch64` and `x86_64` `.yml` outputs, so a real dsymutil failure fails the archive. No Archive has been run since. |
| §1.2 metadata-extraction warning | Fixed | `openscanner.xcodeproj/project.pbxproj` | `LM_SKIP_METADATA_EXTRACTION = YES` on RescrivaSafariExtension and ScannerWidgetExtension, Debug and Release. |
| §1.3 runtime console noise | Not done | — | Nothing to fix (the table is a reading aid); the `AppState.swift` hang-risk site is gone with §2.2 4. |
| §1.4 `Package.resolved` ignored | Fixed | `.gitignore` | Each workspace level is ignored by its contents and only the path down to the pin is reopened; the file is untracked now and has to be added at commit time. |
| §1.4 merged worktrees | Fixed | (git only) | `.worktrees/glare-capture` and `.worktrees/nearby-share` removed and both branches deleted; `git worktree list` shows the main checkout only. |
| §1.4 `Website/` untracked | Not done | — | Where the landing page lives is the user's decision; still untracked. |
| §1.4 `scannerUITests` not in the Test action | Not done | — | The scheme was left alone. |
| §1.4 template `scannerTests.swift` | Fixed | `scannerTests/scannerTests.swift` (deleted), `openscanner.xcodeproj/project.pbxproj` | The file and its four project references are gone; the deletion is unstaged. |
| §1.4 / §2.2 4 no strict concurrency | Fixed | `openscanner.xcodeproj/project.pbxproj`, `Docs/Swift6-Migration.md` (new) | `SWIFT_STRICT_CONCURRENCY = complete` on the `scanner` target's Debug configuration (language mode stays Swift 5, so these are warnings); the 71 it surfaces, in 32 files, are the backlog listed in the new doc. |
| §2.2 1 DOCX/PPTX on the main actor; STORED zip | Fixed | `scanner/Export/ExportService.swift`, `scanner/Export/ZipArchive.swift`, `scannerTests/RescrivaRendererTests.swift`, `scannerTests/FigureCropTests.swift` | Word, PowerPoint and Markdown render inside `Task.detached`; the zip deflates (Compression's `COMPRESSION_ZLIB`, method 8) and keeps STORED only when that doesn't shrink an entry; the figure export test reads parts back through a deflate-aware reader. |
| §2.2 2 Rebuilder: polling, re-decoding, the Core Data weld | Fixed | `scanner/Rebuild/Rebuilder.swift`, `scanner/Rebuild/PageOCR.swift`, `scannerTests/RebuildProgressTests.swift`, `scannerTests/StyleDetectorTests.swift`, `scannerTests/FigureDetectorTests.swift` | `RecognitionTracker.waitUntilRead` (a continuation per page, safe to cancel) replaces the 150 ms polling; each page is decoded once (`PageSnapshot.decodingImage`) and handed to the detectors' `CGImage` entry points; extraction is split into `ScanSnapshot` (read), `build(_:progress:)` (pure) and `store` (write). The detectors' `Data` overloads stay for the tests that use them. |
| §2.2 3 five inbound-request paths | Fixed | `scanner/NavigationManager.swift`, `scanner/ContentView.swift`, `scanner/scannerApp.swift`, `scanner/AppIntents.swift`, `scannerTests/LibraryTests.swift` | One queue, `AppRequests` (`openScan`, `startScan`, `shareNearby`), drained by one `onChange(initial: true)`, so a cold Siri or Spotlight launch is handled once; the Inbox keeps its own notification, which already drains on launch. |
| §2.2 4 Swift 6 discipline | Fixed | `scanner/AppState.swift` (deleted), `scanner/NavigationManager.swift`, `scanner/Data/Persistence.swift`, `scanner/Data/OriginalStore.swift`, `scanner/Data/FigureStore.swift`, `openscanner.xcodeproj/project.pbxproj` | `AppState`, `NavigationManager` and `ViewState` are gone (folded into `AppRequests`); `LoadResult` became a local captured by the load callback; the three fire-and-forget `Task.detached` sites return their `Task` and stay unowned on purpose (file deletions whose owners are already gone). Strict concurrency: the §1.4 row. |
| §2.2 5 print-only errors and the `try?`s | Fixed | `scanner/Rescriva/Log.swift` (new, registered in the project), 40-odd app files (141 sites), `scanner/Rebuild/Rebuilder.swift`, `scanner/Documents/PDFLibrary.swift`, `scanner/Rescriva/ScanModel.swift`, `scanner/Rebuild/RescrivaDocument.swift`, `scanner/Inbox/InboxDrop.swift` | `os.Logger` per area (app, library, share, export, rebuild, inbox, capture); no `print(` is left in the app target; names go in as `.private`, PINs and secrets never. The Vision reader failure is logged with the fallback kept; a PDF with a broken or missing `info.json` shows as a stand-in record instead of vanishing; `rebuiltDocument` decodes through a version check (§4 6 row). `InboxDrop` has a Logger of its own because the Safari extension compiles it too. |
| §2.2 6 duplicated paths | Partly | `scanner/Export/ZipArchive.swift`, `scanner/Export/DOCXRenderer.swift`, `scanner/Export/PPTXRenderer.swift`, `scanner/Extensions/ViewExtensions.swift`, `scanner/Inbox/Inbox.swift`, `scanner/Documents/PDFLibrary.swift`, `scanner/Share/NearbyShareSession+Files.swift`, `scanner/Share/NearbyShareSession+Rules.swift`, `scanner/Export/ExportService.swift` | The smaller items: one `presetGeometry`/`isDark`, one set of diagram connection sites, one `FileManager.removeIfPresent`, one `String.safeFileName` (export names are now capped at 200 bytes, were 50 characters). `InboxDrop.cleanTitle` keeps its own sanitizer (Safari extension target). Not done: the three markup stacks, the two equation parsers and the two library homes, each a refactor of its own. |
| §2.2 7 Open Scanner dead code | Fixed | `scanner/Data/DataExtensions.swift`, `scanner/Extensions/StringMetrics.swift` (deleted), `scanner/AppState.swift` (deleted), `scanner/NavigationManager.swift`, `scanner/AppIntents.swift`, `openscanner.xcodeproj/project.pbxproj` | Every listed member is gone (a grep over the app, widget and extension finds none); `OpenAppIntent` is a plain open; `ClassicScanIntent` on Mac Catalyst says there is no document camera; `MarkdownRenderer` has a caller now (§4 2 row). |
| §3 High 1 stale Spotlight result | Fixed | `scanner/Data/Persistence.swift`, `scanner/scannerApp.swift`, `scanner/ContentView.swift`, `scannerTests/LibraryTests.swift` | The identifier becomes an `NSManagedObjectID` (behind a URL-shape guard, since the coordinator throws for anything else) and `liveScan` resolves it with `existingObject(with:)`, skipping deleted and trashed scans and accepting old per-line ids; a stale result shows a toast. `SpotlightIndexer` indexes one item per live scan; a one-time reindex (version 2) is recorded only after the old index was deleted. Device check pending. |
| §3 Medium 2 widget reads an empty database | Fixed | `ScannerWidget/ScannerWidget.swift`, `ScannerWidget/TimelineEntry.swift`, `ScannerWidget/TimelineProvider.swift`, `ScannerWidget/WidgetView.swift`, `openscanner.xcodeproj/project.pbxproj` | A static launcher: SwiftUI and WidgetKit only, one entry, policy `.never`; the app's data files are out of the widget target. |
| §3 Medium 3 unbounded Inbox download | Fixed | `scanner/Inbox/Inbox.swift`, `scanner/Inbox/InboxDrop.swift`, `scannerTests/InboxTests.swift` | A download delegate checks `Content-Length`, the bytes written and the finished size against `InboxDrop.maxBytes` (150 MB) and rejects non-2xx answers; the toast says why. The live URLSession path has no unit test (no network in tests). |
| §3 Medium 4 NSDataDetector ranges | Fixed | `scanner/Data/DataExtensions.swift`, `scannerTests/LibraryTests.swift` | `utf16.count` and `Range(match.range, in:)`; tested with emoji and CJK text around a phone, an email and a URL. |
| §3 Medium 5 grid faults page JPEGs | Fixed | `scanner/Data/DataExtensions.swift`, `scanner/Library/ScanGallery.swift`, `scanner/Library/Workspace.swift`, `scanner/Share/ShareDocumentPicker.swift`, `scannerTests/LibraryTests.swift` | `Scan.coverThumbnail` (a dictionary fetch of the first page's thumbnail, `fetchLimit` 1, cached per object while `lastUpdate` is unchanged) and `pageCount` (`captures?.count`); the test asserts the pages stay faults. |
| §3 Medium 6 `rebuiltDocument` re-decoded | Fixed | `scanner/Rescriva/ScanModel.swift`, `scannerTests/RebuildProgressTests.swift` | `RebuiltDocumentCache`: an `NSCache` keyed by object id that decodes again only when the stored bytes differ. |
| §3 Low 7 LaTeX recursion | Fixed | `scanner/Export/LaTeXToOMML.swift`, `scannerTests/RescrivaRendererTests.swift` | `parseAtom` counts depth too; `maxDepth` is 64 now that atoms count; 900 nested `\hat`s return nil cleanly. |
| §3 Low 8 Catalyst Inbox trusts local writers | Fixed | `scanner/Inbox/InboxStore.swift`, `scannerTests/InboxTests.swift` | `startsLikePDF` runs on every `.pdf` hand-off at import; a failing folder is unusable and removed. |
| §3 Low 9 name cap in Characters | Fixed | `scanner/Inbox/InboxDrop.swift`, `scannerTests/InboxTests.swift` | `maxNameBytes` 80, cut on whole Characters. |
| §3 Low 10 plain http links | Fixed | `scanner/Inbox/InboxManifest.swift`, `scanner/Inbox/InboxDrop.swift`, `SafariExtension/Resources/handoff.js`, `SafariExtension/Resources/_locales/en/messages.json`, `scannerTests/InboxTests.swift` | https with a host, on both sides (the extension's `secureAddress`, the native `isWebAddress`). |
| §3 Low 11 transcript in Spotlight | Fixed | `README.md`, `scanner/Data/Persistence.swift` | Documented in the README; the index is now one item per live scan (title and text), Recently Deleted left out. |
| §3 Low 12 Open-With decode on the main actor | Fixed | `scanner/Library/Workspace.swift`, `scanner/Views/HomeView.swift` | `FileImport.images(at:)` is async and decodes on a detached task; `PhotoImport` uprights there too. |
| §4 Deviation 1 tier-3 gating | Deferred | — | The user's call: nothing about the custom on-device (tier-3 Core ML) model was touched, the `tier == .smart` gate included. |
| §4 Deviation 2 Markdown export has no UI | Fixed | `scanner/Export/ExportService.swift`, `scanner/Views/ExportSheet.swift`, `scannerTests/RescrivaRendererTests.swift`, `scannerTests/PDFOptionsTests.swift` | `ExportFormat.md` ("Markdown") renders off the main actor, with a "Copy for AI" button in the sheet. |
| §4 Deviation 3 DOCX arrows don't attach | Fixed | `scanner/Export/DOCXRenderer.swift`, `scanner/Export/PPTXRenderer.swift`, `scannerTests/RescrivaRendererTests.swift` | Edges are `wps` connectors with `a:stCxn`/`a:endCxn` on `straightConnector1`, from connection sites shared with the PPTX writer. |
| §4 Deviation 4 equation fallback | Partly | `scanner/Export/LaTeXToOMML.swift`, `scanner/Export/ExportService.swift`, `scanner/Views/RebuiltDocumentView.swift`, `scanner/Export/DOCXRenderer.swift`, `scanner/Export/PPTXRenderer.swift`, `scannerTests/RescrivaRendererTests.swift` | When OMML can't typeset an equation but the preview's `MathParser` can, the preview is rendered to a PNG that goes into Word and PowerPoint with the LaTeX as alt text. Matrices and `\begin` fail in both parsers and still fall to italic text; widening `MathParser` (the two-parser item in §2.2 6) is what makes this route pay off. |
| §4 Deviation 5 licence notices | Fixed | `scanner/Views/SettingsView.swift` | The WebRTC BSD-3 and OSS Document Scanner MIT notices, verbatim, after the Open Scanner one; the About line names both. |
| §4 Deviation 6 version check | Fixed | `scanner/Rebuild/RescrivaDocument.swift`, `scanner/Rescriva/ScanModel.swift`, `scanner/Rebuild/Rebuilder.swift`, `scanner/Views/ReviewView.swift`, `scannerTests/RescrivaCoreTests.swift`, `scannerTests/RebuildProgressTests.swift` | `currentVersion` and `decodeStored` give a `RebuiltDocumentState`; a document from a newer Rescriva is never overwritten (`mayCache` is false, the setter refuses, Review refuses edits and says so) and other decode failures are logged instead of swallowed. |
| §4 Deviation 7 diagram `layout` token | Not in scope of this pass | — | The decision (implement the other modes or drop the enum) wasn't taken here. |
| §4 table: missing plan features | Not in scope of this pass | — | Not issues: the Tesseract fallback, table flag, whiteboard step 6, hold-to-compare and lasso, block editing, undo in Review, DOCX page-break joins, PPTX shapes and master, Notes export, charts, dagre and SmartArt, Acrobat 5, 6 and 8 stay as the table records them. |
| §4 README vs code | Fixed | `README.md`, `scanner/AppIntents.swift`, `scanner/Data/Persistence.swift` | The Library bullet names the two Shortcuts actions and says what Spotlight indexes now; the Export bullet lists Markdown and "Copy for AI". |
| §5 High the page never re-dials | Fixed | `assets/main.js`, `assets/peer.js` | A dropped relay peer the relay still lists is re-dialed after 2, 4, 8, 16 and then 30 s, up to ten times, with a toast on the first failure and when giving up; `retired` is cleared when the peer leaves; a connection "disconnected" for 10 s is closed as dropped so the redial starts before ICE's own timeout. The app answers a fresh offer from the same page by dropping its old link. |
| §5 Medium a failed upload leaves the slot stuck; no stall timers | Fixed | `assets/peer.js`, `assets/main.js`, `scanner/Share/NearbyShareSession.swift`, `scanner/Share/NearbyShareSession+Files.swift`, `scanner/Share/SharePeer.swift`, `scannerTests/NearbyShareTests.swift` | The page sends `cancel` on every failed upload (including no `accept` or `saved` within 120 s) and when it stops a download; the app frees the slot and deletes the partial file on `cancel`, and both sides give up after 30 s of nothing moving (`ShareLimits.stallSeconds`; `waitForRoom` waits 30 s, not five minutes). |
| §5 Medium downloads held in memory | Fixed | `assets/peer.js`, `assets/main.js` | Chrome and Edge stream each chunk to a file chosen in a Save dialog (File System Access API); Safari and Firefox keep the Blob path; Blob URLs are revoked when the connection closes and ten minutes after completion; at most the last 20 finished transfers are kept; more bytes than `size` aborts. |
| §5 Medium no tests for the state machine | Fixed | `scannerTests/NearbyShareTests.swift`, `scanner/Share/ShareRelay.swift`, `scanner/Share/SharePeer.swift`, `scanner/Share/NearbyShareSession.swift`, `scanner/Share/NearbyShareSession+Link.swift` | 89 test methods: every `NearbySharePINLock` branch, `NearbyShareInput`, `NearbyShareLink.proves`, `ShareRelay.parse` (pure now) and `NearbyShareSessionTests` driving hello/proof/bye, unlock, downloads, uploads and relay parsing over a DEBUG-only stub peer with no WebRTC. |
| §5 Medium silent failures in the UI | Fixed | `assets/main.js` | Toasts for a failed first attempt, a lost connection, giving up, and "stopped sharing" only on the app's `bye`; decline reasons `busy`, `size` and `type` have their own text, as do the download and upload failure notes. |
| §5 Low dead `/health` | Fixed | `relay/worker.js`, `relay/dev_relay.py`, `relay/test_relay.py`, `relay/README.md`, `PROTOCOL.md` | Removed from both relays (`GET /health` is 404 now, tested); `GET /` is the check. |
| §5 Low limits defined three times; `maxPeers = 64` | Fixed | `scanner/Share/ShareMessages.swift`, `scanner/Share/NearbyShareSession.swift`, `scanner/Share/SharePeer.swift`, `scanner/Share/ShareRelay.swift` | One `ShareLimits` enum (message 64 KiB, SDP 60 KiB, candidate 1 KiB, 32 peers, names, tokens, 200 documents, 30 s stall, the device sets); the old statics are gone. |
| §5 Low `NearbyShareReceived/` never swept | Fixed | `scanner/Share/NearbyShareSession+Files.swift`, `scannerTests/NearbyShareTests.swift` | The first session of a process sweeps every folder there along with `NearbyShare/`. |
| §5 Low per-chunk file I/O on the main actor | Fixed | `scanner/Share/NearbyShareSession+Files.swift`, `scanner/Share/NearbyShareSession.swift` | `NearbyShareChunkFile`: a `FileHandle` used only on its own serial queue; counts and state stay on the main actor. |
| §5 Low `+Link/+Rules/+Files` names; `decodeConnectionCode` | Partly | `scanner/Share/NearbyShareSession+Link.swift`, `scanner/Share/NearbyShareSession+Rules.swift`, `scanner/Share/NearbyShareSession+Files.swift`, `scanner/Share/ShareCodes.swift` | Documented rather than renamed (a rename touches the project file): each header says what the file holds; `decodeConnectionCode` says it exists for the tests. |
| §5 Low `pagehide` closes right after `bye`; no first-frame fallback | Fixed | `assets/peer.js` | `close()` lets `bye` go 300 ms before closing the channel; a frame arriving before `onopen` opens the channel and sends `hello`, as the app does. |

Changed in passing, outside any finding: `NearbyShareInput.acceptsUpload` refuses `image/` with no subtype; `ShareDocumentPicker` reads `coverThumbnail`; `NearbyShareLink.proves` and `NearbyShareFiles.size(of:)` are `nonisolated static` so tests can call them. §6 and §7 are reading notes, not findings: the test count is above, and the device-only items in §7 are still unverified.
