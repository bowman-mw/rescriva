# Swift 6 migration: the strict-concurrency list

`SWIFT_STRICT_CONCURRENCY = complete` is on for the `scanner` target's **Debug** configuration
(`openscanner.xcodeproj`, 2026-10-13), so every concurrency-sensitive change is diagnosed as it lands
instead of turning up as a surprise when the project moves to the Swift 6 language mode. In the
Swift 5 mode these are warnings, never errors. Release builds don't carry the setting.

Two Swift 6 upcoming features are on for the `scanner` target in both configurations (2026-10-13):
`SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES` (SE-0418) and
`SWIFT_UPCOMING_FEATURE_GLOBAL_ACTOR_ISOLATED_TYPES_USABILITY` (SE-0434). The Swift 6 language mode
turns both on by itself. Without them, Swift 5's complete checking flags code that Swift 6 accepts:
key-path literals aren't inferred Sendable (the `SortDescriptor` and `AttributedString` warnings),
and `@MainActor` callbacks aren't treated as Sendable (the progress closures). They change type
inference only, nothing at run time.

**Status, 2026-10-13: the `scanner` target builds with no warnings.** Every item in its section
below is fixed, and so are the module-level ones; each file says how. The test targets' 28 are
still open.

This is the backlog the probe found (`xcodebuild … SWIFT_STRICT_CONCURRENCY=complete` over every
target, same day), one line per distinct warning, grouped by target and file. Tick them off as
they're fixed; the test and UI-test targets are listed because the setting will go on them too.

**71 distinct warnings in 32 files**, plus the module-level key-path warnings at the end.

## scanner (43)

### `scanner/Documents/PDFEditSession.swift` (8)

Fixed: `PDFFinder` is `@MainActor`; PDFKit's search callbacks are `nonisolated` and hand each match to the main queue as a `nonisolated(unsafe)` constant. The per-search generation counter is an `OSAllocatedUnfairLock`: the search thread used to read a plain `var` the main thread wrote. `snapshot(of:)` returns its copy `sending`, for `PDFLibrary.save`. No `@preconcurrency import`.

- [x] line 15: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'PDFKit'
- [x] line 782: capture of 'self' with non-Sendable type 'PDFFinder?' in a '@Sendable' closure
- [x] line 782: sending 'self' risks causing data races; this is an error in the Swift 6 language mode
- [x] line 783: capture of 'instance' with non-Sendable type 'PDFSelection' in a '@Sendable' closure
- [x] line 783: capture of 'instance' with non-Sendable type 'PDFSelection' in an isolated closure; this is an error in the Swift 6 language mode
- [x] line 783: sending 'instance' risks causing data races; this is an error in the Swift 6 language mode
- [x] line 790: capture of 'self' with non-Sendable type 'PDFFinder?' in a '@Sendable' closure
- [x] line 790: sending 'self' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/Views/SpeechReader.swift` (7)

Fixed: `SpeechCallbacks` is `@MainActor` with `nonisolated` synthesizer callbacks. The utterance crosses to the main queue as a `nonisolated(unsafe)` constant: it's only compared by identity there.

- [x] line 134: stored property 'reader' of 'Sendable'-conforming class 'SpeechCallbacks' is mutable
- [x] line 137: capture of 'utterance' with non-Sendable type 'AVSpeechUtterance' in a '@Sendable' closure
- [x] line 137: sending 'utterance' risks causing data races; this is an error in the Swift 6 language mode
- [x] line 141: capture of 'utterance' with non-Sendable type 'AVSpeechUtterance' in a '@Sendable' closure
- [x] line 141: sending 'utterance' risks causing data races; this is an error in the Swift 6 language mode
- [x] line 145: capture of 'utterance' with non-Sendable type 'AVSpeechUtterance' in a '@Sendable' closure
- [x] line 145: sending 'utterance' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/Data/Persistence.swift` (6)

Fixed: `SpotlightIndexer` is `@unchecked Sendable` (no state of its own; Core Data indexes on the indexer's own context), which makes `PersistenceController` Sendable, since Core Data's containers already are in the iOS 26 SDK. `UserDefaults.standard` is read inside the completion handler, and the merge policy is `NSMergePolicy.mergeByPropertyObjectTrump`. No `@preconcurrency import`.

- [x] line 11: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'CoreData'
- [x] line 16: static property 'shared' is not concurrency-safe because non-'Sendable' type 'PersistenceController' may have shared mutable state; this is an error in the Swift 6 language mode
- [x] line 67: reference to var 'NSMergeByPropertyObjectTrumpMergePolicy' is not concurrency-safe because it involves shared mutable state; this is an error in the Swift 6 language mode
- [x] line 112: capture of 'defaults' with non-Sendable type 'UserDefaults' in a '@Sendable' closure
- [x] line 113: capture of 'indexer' with non-Sendable type 'NSCoreDataCoreSpotlightDelegate' in a '@Sendable' closure
- [x] line 153: static property 'preview' is not concurrency-safe because non-'Sendable' type 'PersistenceController' may have shared mutable state; this is an error in the Swift 6 language mode

### `scanner/Documents/PDFKitView.swift` (3)

Fixed: Line 156: the tapped annotation is read into a `nonisolated(unsafe)` constant; the notification is posted and delivered on the main thread. Lines 226 and 229 went with the two upcoming features.

- [x] line 156: sending 'annotation' risks causing data races; this is an error in the Swift 6 language mode
- [x] line 226: reference to captured var 'self' in concurrently-executing code
- [x] line 229: reference to captured var 'self' in concurrently-executing code

### `scanner/Annotate/AnnotationSession.swift` (3)

Fixed: `MarkSwatch.name` and `sizeNames` are `LocalizedStringResource` (Sendable) instead of `LocalizedStringKey`. The strings are still extracted into the catalog.

- [x] line 86: static property 'ink' is not concurrency-safe because non-'Sendable' type '[MarkSwatch]' may have shared mutable state; this is an error in the Swift 6 language mode
- [x] line 95: static property 'highlighter' is not concurrency-safe because non-'Sendable' type '[MarkSwatch]' may have shared mutable state; this is an error in the Swift 6 language mode
- [x] line 103: static property 'sizeNames' is not concurrency-safe because non-'Sendable' type '[LocalizedStringKey]' may have shared mutable state; this is an error in the Swift 6 language mode

### `scanner/Library/LibraryHomeView.swift` (2)

Fixed: `SortDescriptor` key-path literals: `InferSendableFromCaptures`.

- [x] line 23: type 'KeyPath<SmartFolder, Optional<String>>' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- [x] line 253: type 'KeyPath<ScanTag, Optional<String>>' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### `scanner/Library/Workspace.swift` (2)

Fixed: Line 102: `FileImport.files(from:)` and its copy step are `@MainActor`, where the drop's item providers live; each file is still copied in its provider's completion handler. Line 340: `GlobalActorIsolatedTypesUsability`.

- [x] line 102: sending 'providers' risks causing data races; this is an error in the Swift 6 language mode
- [x] line 340: sending value of non-Sendable type '@MainActor (Int, Int) -> ()' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/Capture/CaptureCamera.swift` (1)

Fixed: `CapturePipeline.onProcessingQueue` takes a `@Sendable` closure.

- [x] line 895: capture of 'work' with non-Sendable type '() throws -> T' in a '@Sendable' closure

### `scanner/Rebuild/Rebuilder.swift` (1)

Fixed: `@MainActor` progress callback: `GlobalActorIsolatedTypesUsability`.

- [x] line 186: sending value of non-Sendable type '@MainActor (Int, Int) -> Void' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/Documents/PDFLibrary.swift` (1)

Fixed: `save(_:for:options:)` takes the document `sending` (the caller hands over a snapshot it doesn't keep) and the write options as `[PDFDocumentWriteOption: any Sendable]`.

- [x] line 237: passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure; this is an error in the Swift 6 language mode

### `scanner/Documents/PDFDocumentView.swift` (1)

Fixed: `@MainActor` progress callback: `GlobalActorIsolatedTypesUsability`.

- [x] line 684: sending value of non-Sendable type '@MainActor (Int, Int) -> ()' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/Documents/PDFPageOrganizer.swift` (1)

Fixed: Thumbnails are drawn from `PDFPage.unsharedCopy()` (PDFBackgroundWork.swift), which returns the copy `sending`.

- [x] line 359: sending 'copy' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/UIKit/QuickLookController.swift` (1)

Fixed: The coordinator's delegate conformance is main-actor isolated (`@MainActor QLPreviewControllerDelegate`, SE-0470): Quick Look calls it on the main thread, and the data-source protocol is main-actor already. Not `@preconcurrency`: Release builds without strict checking, where that warns "has no effect".

- [x] line 107: conformance of 'QuickLookController.Coordinator' to protocol 'QLPreviewControllerDelegate' crosses into main actor-isolated code and can cause data races; this is an error in the Swift 6 language mode

### `scanner/Views/HomeView.swift` (1)

Fixed: `@MainActor` progress callback captured by `PDFImport.pages`' detached task: `GlobalActorIsolatedTypesUsability`.

- [x] line 319: passing closure as a 'sending' parameter risks causing data races between code in the current task and concurrent execution of the closure; this is an error in the Swift 6 language mode

### `scanner/Library/LibraryScope.swift` (1)

Fixed: `livePredicate` is a computed property: a fresh predicate each time, equal to the last.

- [x] line 116: static property 'livePredicate' is not concurrency-safe because non-'Sendable' type 'NSPredicate' may have shared mutable state; this is an error in the Swift 6 language mode

### `scanner/Library/LibrarySheets.swift` (1)

Fixed: `SortDescriptor` key-path literal: `InferSendableFromCaptures`.

- [x] line 138: type 'KeyPath<ScanTag, Optional<String>>' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### `scanner/Library/SmartFolderEditor.swift` (1)

Fixed: `SortDescriptor` key-path literal: `InferSendableFromCaptures`.

- [x] line 17: type 'KeyPath<ScanTag, Optional<String>>' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### `scanner/Rescriva/ScanModel.swift` (1)

Fixed: Fixed in 8b3c30b (`nonisolated(unsafe)`; NSCache is thread-safe).

- [x] line 318: static property 'entries' is not concurrency-safe because non-'Sendable' type 'NSCache<NSManagedObjectID, RebuiltDocumentCache.Entry>' may have shared mutable state; this is an error in the Swift 6 language mode

### `scanner/Library/ScanCollectionView.swift` (1)

Fixed: `SortDescriptor` key-path literal: `InferSendableFromCaptures`.

- [x] line 19: type 'KeyPath<Scan, Optional<Date>>' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

## scannerUITests (7)

### `scannerUITests/scannerUITests.swift` (4)

- [ ] line 27: call to main actor-isolated initializer 'init()' in a synchronous nonisolated context
- [ ] line 28: call to main actor-isolated instance method 'launch()' in a synchronous nonisolated context
- [ ] line 37: call to main actor-isolated initializer 'init()' in a synchronous nonisolated context
- [ ] line 37: call to main actor-isolated instance method 'launch()' in a synchronous nonisolated context

### `scannerUITests/scannerUITestsLaunchTests.swift` (3)

- [ ] line 21: call to main actor-isolated initializer 'init()' in a synchronous nonisolated context
- [ ] line 22: call to main actor-isolated instance method 'launch()' in a synchronous nonisolated context
- [ ] line 27: call to main actor-isolated instance method 'screenshot()' in a synchronous nonisolated context

## scannerTests (21)

### `scannerTests/AnnotationTests.swift` (7)

- [ ] line 23: main actor-isolated property 'folder' can not be mutated from a nonisolated context
- [ ] line 24: main actor-isolated property 'suiteName' can not be mutated from a nonisolated context
- [ ] line 25: main actor-isolated property 'defaults' can not be mutated from a nonisolated context
- [ ] line 25: main actor-isolated property 'suiteName' can not be referenced from a nonisolated context
- [ ] line 29: main actor-isolated property 'folder' can not be referenced from a nonisolated context
- [ ] line 30: main actor-isolated property 'defaults' can not be referenced from a nonisolated context
- [ ] line 30: main actor-isolated property 'suiteName' can not be referenced from a nonisolated context

### `scannerTests/PDFDocumentsTests.swift` (3)

- [ ] line 20: main actor-isolated property 'folder' can not be mutated from a nonisolated context
- [ ] line 21: main actor-isolated property 'folder' can not be referenced from a nonisolated context
- [ ] line 25: main actor-isolated property 'folder' can not be referenced from a nonisolated context

### `scannerTests/InboxTests.swift` (3)

- [ ] line 26: main actor-isolated property 'folder' can not be mutated from a nonisolated context
- [ ] line 27: main actor-isolated property 'inbox' can not be referenced from a nonisolated context
- [ ] line 31: main actor-isolated property 'folder' can not be referenced from a nonisolated context

### `scannerTests/PageSpliceTests.swift` (1)

- [ ] line 31: main actor-isolated property 'containers' can not be mutated from a nonisolated context

### `scannerTests/MarkRemapTests.swift` (1)

- [ ] line 26: main actor-isolated property 'containers' can not be mutated from a nonisolated context

### `scannerTests/FigureCropTests.swift` (1)

- [ ] line 29: main actor-isolated property 'containers' can not be mutated from a nonisolated context

### `scannerTests/PageEditingTests.swift` (1)

- [ ] line 32: main actor-isolated property 'containers' can not be mutated from a nonisolated context

### `scannerTests/RebuildProgressTests.swift` (1)

- [ ] line 27: main actor-isolated property 'containers' can not be mutated from a nonisolated context

### `scannerTests/PDFMarkupEditingTests.swift` (1)

- [ ] line 420: sending 'copy' risks causing data races; this is an error in the Swift 6 language mode

### `scannerTests/SpreadSplitTests.swift` (1)

- [ ] line 39: main actor-isolated property 'containers' can not be mutated from a nonisolated context

### `scannerTests/StyleDetectorTests.swift` (1)

- [ ] line 373: mutation of captured var 'results' in concurrently-executing code

## Module-level (no file)

Reported once per compilation of the module, at `<unknown>:0`; they come from `AttributedString`
key paths in SwiftUI text styling (`AttributeScopes.SwiftUIAttributes.*`, `FoundationAttributes.LinkAttribute`):

Fixed: `InferSendableFromCaptures`. All six came from `styled(_:font:activeFlag:showsFlags:)` in
RebuiltDocumentView.swift, which sets those attributes through `AttributedString`'s dynamic-member
key paths. The compiler synthesizes those key paths without a source location, so Xcode repeated
each warning on every file compiled in the same batch (ZipArchive.swift, PageOCR.swift…).

- [x] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.SwiftUIAttributes, AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute>'; this is an error in the Swift 6 language mode
- [x] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.SwiftUIAttributes, AttributeScopes.SwiftUIAttributes.FontAttribute>'; this is an error in the Swift 6 language mode
- [x] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.SwiftUIAttributes, AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute>'; this is an error in the Swift 6 language mode
- [x] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.SwiftUIAttributes, AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute>'; this is an error in the Swift 6 language mode
- [x] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.SwiftUIAttributes, AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute>'; this is an error in the Swift 6 language mode
- [x] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.FoundationAttributes, AttributeScopes.FoundationAttributes.LinkAttribute>'; this is an error in the Swift 6 language mode

## What's left

- The test targets: `setUp`/`tearDown` mutating `@MainActor` state from a nonisolated context; mark those test classes `@MainActor`.
  They only show once the setting goes on those targets, and the two upcoming features should go on with it.
- `PDFMarkupEditingTests.swift` line 420 is the page-copy case `PDFPageOrganizer.swift` had: `page.unsharedCopy()` fixes it.
- Before the Swift 6 language mode itself: it also turns on `DisableOutwardActorInference`, `IsolatedDefaultValues`,
  `GlobalConcurrency` and `DynamicActorIsolation`. The last adds run-time checks, so try each one alone first.

Ways that held up for the `scanner` items, for the next ones:

- An Objective-C object handed to the main queue that its sender never touches again (a match, an utterance, an
  annotation): a `nonisolated(unsafe)` constant made right where it arrives, with the reason in a comment.
- A fresh copy handed to another thread or actor: return it `sending` from the function that makes it, so the compiler
  checks the rest of the hand-over (`PDFEditSession.snapshot(of:)`, `PDFPage.unsharedCopy()`).
- A class whose state lives on the main actor but whose delegate callbacks arrive elsewhere: make it `@MainActor`
  with `nonisolated` callbacks, and lock anything those callbacks read (`PDFFinder`).
