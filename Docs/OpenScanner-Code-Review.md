# Open Scanner code still in Rescriva

*Review, 2026-10-12, of main at 7c54fd7.*

**Method.** `git blame -w -M -C` over the Swift, JS, HTML and CSS files found about 1,700 of 53,000 lines (3%) attributed to Open Scanner's 10 upstream commits. Three reviewers covered the data layer, the screens and the system integrations. The main claims were spot-checked by hand.

## Verdict

Some of it should be replaced, but nothing needs a large rewrite.

- **Leftovers.** Most of the 1,700 lines are headers, imports and braces left behind by rewrites.
- **Dead code.** About 360 lines have no callers.
- **Live code with problems.** What is still used carries several real bugs and one scaling problem: opening a scan or searching the library loads every page's full image on the main thread.
- **Integrations.** The widget and the Spotlight setup don't do what they appear to do.

Two things stay as they are and frozen: the Core Data model and the container setup. Users' libraries and iCloud sync depend on them.

## 1. Delete: dead code (no behaviour change)

| Where | What |
|---|---|
| `scanner/Data/DataExtensions.swift` 15–28, 37–83, 108–188, 271–335, 410–441 | `createDefaults`, `reversedCaptures`, `totalRecognizedItems`, first/last thumbnail, `Scan.textPreview`, `pdfDocument`…`firstPageImage`, both `textDocument`, `titleSuggestion`, `textUrl`, `Create/UpdateOperation`. Some hide errors in an empty `catch {}`. Also fix the stale comment at `SearchablePDF.swift:8`. |
| `scanner/Extensions/StringMetrics.swift` | Whole file. `jaroWinkler` has no callers and is wrong anyway: the match window is off, and a character can match twice. |
| `scanner/AppState.swift` | `lastScanIndex` (also wrong: −1 for an empty library), `LocationManager` (no callers, no location usage string; dropping it removes CoreLocation), `openRecognizedItem`, and the `AppEnum` conformance on `ViewState`. |
| `scanner/NavigationManager.swift` | `requestedLiveScan` and the empty `openApp()`. |
| `scanner/Extensions/ViewExtensions.swift` 15–17, 43–56, 93–113, 140–142, 150–167 | `Color.background/foreground/accent` (and their 3 colour assets), `getTemporaryDirectory`, `Animation.repeat`, `resize(newSize:)`, `FlippedUpsideDown`, mutating `sanitize()`/`condenseWhitespace()`, `View.if`. |
| `scannerTests/scannerTests.swift`, `scannerUITests/` | Xcode template tests. The UI test target isn't in the scheme's Test action. If it were run, it would use the real library with CloudKit. |

## 2. Fix: real bugs

1. **Spotlight opens Recently Deleted scans as if they were live.** They stay indexed, and a tap pushes `.preview(scan)` (`ContentView.swift:31–37`), skipping the Library's recover/delete prompt (`LibraryController.swift:64`).
2. **A stale Spotlight result can crash the app.** `scanFromUri` and `recognizedItemFromUri` (`Persistence.swift`) use `object(with:)`, which returns a fault even for a purged row. Example: a scan is purged on one device while another device's index still lists it; tapping the result throws "could not fulfill a fault". Use `existingObject(with:)`, skip deleted scans, and log.
3. **The link detector produces wrong links.** It mixes character and UTF-16 offsets (`DataExtensions.swift` ~377–380): "👉 rescriva.com/help" becomes "escriva.com/help". It also builds 4 `NSDataDetector`s per line on every render. Use one static detector and `Range(_:in:)`.
4. **Pages can swap order.** `capturesArray` sorts by `order` alone. When two devices add pages offline, pages can share an `order`, Set order changes on every launch, and Rebuilder's `sourceCaptureIDs` check then throws away the cached rebuild. Add a timestamp/id tiebreak.
5. **The page screen's action bar can act on a deleted line.** Select a line, open the page image and save a Quick Look markup. `invalidateText` deletes every line, but `selected` stays set, so Copy copies "" and Delete/Undo can bring back a blank line. Clear `selected` when opening the image (`LiveCaptureSummary.swift:126–127`), as `adjustButton` already does.
6. **The page viewer's back pill sits under the status bar.** `LiveCaptureSummary.swift:73` adds `.ignoresSafeArea()` to `QuickLookView`. Remove it.
7. **Quick Look is blank for a page with no image.** `QuickLookController.swift:126` writes a 0-byte file and returns its URL. Show the Mac path's "This page couldn't be opened." instead. Write errors should log with `Rescriva:` and the error.
8. **Speak button problems** (`AppState` 61–81, `LiveCaptureSummary.swift:190–197`):
   - `isSpeaking` isn't observed, so the button can say "Stop" after speech ends.
   - The voice is always en-US, whatever language OCR detected.
   - Speech keeps going after you leave the page.
   - There's no audio session, which probably means silence with the ringer off (unverified).

   Replace with a small `@Observable` reader owned by the page screen.
9. **Siri "Scan Document" on a cold launch may do nothing** until the app is force-quit. This is likely but unconfirmed on a device: the flag is set before `onChange` is attached, and later true→true changes don't fire. **On Mac it says "Okay, starting a scan." and does nothing** (`ContentView.swift:50`).
10. **The Mac menu bar probably says "scanner".** The built app's `CFBundleName` is `scanner`. Set `INFOPLIST_KEY_CFBundleName = Rescriva`.

## 3. Replace: performance

- **`capturesArray`** (`DataExtensions.swift:30–35`, 71 uses) faults in every page. `imageData` is stored inline, so each fault reads the full ~2400 px JPEG. `ScanGallery.swift:140` does this per card just for the first thumbnail, so a 200-page PDF scan loads 200 JPEGs on the main thread. Replace it with a fetch that leaves out `imageData`, plus a one-row fetch for card thumbnails. Don't move `imageData` to external storage: that forces a copying migration inside the launch watchdog while stores load synchronously.
- **Library search** (`HomeView.swift:247` → `Scan.containsText`) walks every page and line of every scan on each keystroke, with the same blob loading. Replace it with an `NSPredicate` SUBQUERY fetch that runs in SQLite.
- Smaller items:
  - `RecognizedItemView.swift:36` saves the line and bumps `scan.lastUpdate` on every keystroke, which re-renders the full-size page image. Save when editing ends.
  - `ReviewView.originalPages` decodes every page image in `body`.

## 4. Replace: integrations

- **Widget** (`ScannerWidget/`). It can never show the user's scans:
  - The view ignores the fetched entries.
  - The fetch opens the widget's own empty store, because the store isn't in the App Group and the widget target has no entitlements.
  - Each reload still builds CloudKit, SQLite and a Spotlight indexer inside a process with a ~30 MB memory cap.
  - The gallery text still says "Document Scanner" / "Open Scanner widget", and the caption reads "Classic".

  Replace it with a data-free, Rescriva-styled "Scan" launcher: one entry, `.never` refresh, `AccessoryWidgetBackground` for the circular family. Drop Persistence, AppState, DataExtensions and the model from the widget target. If a recent-scans widget is wanted later, have the app write a small snapshot to the App Group; don't move the store.
- **Spotlight** (`Persistence.swift` indexer; `transcript` is indexed).
  - Today every OCR line is a separate result, about 800 for a 20-page scan.
  - Recently Deleted scans stay indexed, PDFs aren't indexed, and the indexer also runs for temporary/preview stores and inside the widget.

  Replace it with a Rescriva indexer subclass:
  - one item per live scan (title, bounded text, thumbnail);
  - `nil` for lines and deleted scans;
  - no indexer on temporary stores;
  - a one-time `deleteSpotlightIndex` on upgrade.

  Effort M, risk medium. Check that returning `nil` on update removes the old item.
- **Requests from outside the app.** Three separate paths carry them in: `AppState.openScan`, `AppState.viewState` (`.Page`/`.About` used as commands) and `NavigationManager.requestedClassicScan`. Replace them with one queue of pending requests that `ContentView` drains with `onChange(initial: true)`. This fixes bug 9. `ContentView.swift` is also planned for edits by the Share Nearby work, so coordinate and keep `screen(for:)` / `open(_:)` stable.
- **Small tidies:**
  - `AppIntents.updateAppShortcutParameters()` does nothing, because no phrase has a parameter. Hide the scan shortcut on Mac.
  - `handleSpotlight` (`scannerApp.swift:39–49`) should use a guard chain with logging.
  - `Persistence.preview` never attaches pages and lines to its scans.
  - Convert the 3 `PreviewProvider`s to `#Preview` or delete them.

## 5. Keep

- **Core Data model, versions 1–4.** Freeze them byte-identical; any change goes in a new v5. Every entity, attribute and relationship name stays, including unused ones (`latitude`, `longitude`, `isLive`, `isBarcode`): they are CloudKit `CD_` fields that older builds still write, and the production schema can't drop them.
- **The container in `Persistence.swift`.** Keep the name "scanner", `iCloud.MBO.Scanner`, history tracking and the merge policy.
- **The Quick Look wrapper** (`QuickLookController.swift`). SwiftUI's `.quickLookPreview` can't save markup back (`.updateContents`), so there's no drop-in replacement. Tidy what's listed above. Open question: Quick Look markup is a second, destructive markup path next to Annotate.
- **Helpers that are still used:** `Color(hex:)` (the whole palette uses it; move it to `RescrivaTheme.swift`), `aspectRatio`/`resizeToWidth` (add a zero-height guard), `truncate`/`sanitized`/`whitespaceCondensed`, `recognizedItemsArray`, `image`/`thumbnail`. Several are compiled into the widget too; drop that once the widget stops using Core Data.
- **Identifiers people's saved things depend on:**
  - widget kind `ClassicScannerWidget`;
  - intent types `ClassicScanIntent` and `OpenAppIntent` (titles and phrases can change);
  - the `openscanner://` scheme, which the Safari extension, the Inbox and users' shortcuts rely on (a `rescriva://` scheme can be added alongside);
  - bundle ids `MBO.Scanner*`, `group.MBO.Scanner`;
  - Spotlight identifiers, which are object URIs.
- **Target, product and module names** (`scanner`, `ScannerWidgetExtension`, `openscanner.xcodeproj`). Renaming them touches 24 `@testable import scanner` lines and test-host paths for nothing users see.

## Not verified on a device

- Bug 9: the Siri cold-launch race.
- Bug 8: Speak being silent with the ringer off.
- Typing lag when editing a line.
- VoiceOver: `RecognizedItemView.swift:59–61` (Rescriva's own code) merges the editing TextField into one button element, so a double-tap probably ends editing. Apply the merge only when not editing.

## Afterwards

Once the deletions and replacements are done, the Open Scanner code left is mainly the frozen data model and the container setup, plus the Quick Look wrapper and a few helpers. Rescriva still needs to carry Open Scanner's MIT notice, in `LICENSE` and in Acknowledgements.
