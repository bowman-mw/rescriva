# Swift 6 migration: the strict-concurrency list

`SWIFT_STRICT_CONCURRENCY = complete` is on for the `scanner` target's **Debug** configuration
(`openscanner.xcodeproj`, 2026-10-13), so every concurrency-sensitive change is diagnosed as it lands
instead of turning up as a surprise when the project moves to the Swift 6 language mode. In the
Swift 5 mode these are warnings, never errors. Release builds don't carry the setting.

This is the backlog the probe found (`xcodebuild … SWIFT_STRICT_CONCURRENCY=complete` over every
target, same day), one line per distinct warning, grouped by target and file. Tick them off as
they're fixed; the test and UI-test targets are listed because the setting will go on them too.

**71 distinct warnings in 32 files**, plus the module-level key-path warnings at the end.

## scanner (43)

### `scanner/Documents/PDFEditSession.swift` (8)

- [ ] line 15: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'PDFKit'
- [ ] line 782: capture of 'self' with non-Sendable type 'PDFFinder?' in a '@Sendable' closure
- [ ] line 782: sending 'self' risks causing data races; this is an error in the Swift 6 language mode
- [ ] line 783: capture of 'instance' with non-Sendable type 'PDFSelection' in a '@Sendable' closure
- [ ] line 783: capture of 'instance' with non-Sendable type 'PDFSelection' in an isolated closure; this is an error in the Swift 6 language mode
- [ ] line 783: sending 'instance' risks causing data races; this is an error in the Swift 6 language mode
- [ ] line 790: capture of 'self' with non-Sendable type 'PDFFinder?' in a '@Sendable' closure
- [ ] line 790: sending 'self' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/Views/SpeechReader.swift` (7)

- [ ] line 134: stored property 'reader' of 'Sendable'-conforming class 'SpeechCallbacks' is mutable
- [ ] line 137: capture of 'utterance' with non-Sendable type 'AVSpeechUtterance' in a '@Sendable' closure
- [ ] line 137: sending 'utterance' risks causing data races; this is an error in the Swift 6 language mode
- [ ] line 141: capture of 'utterance' with non-Sendable type 'AVSpeechUtterance' in a '@Sendable' closure
- [ ] line 141: sending 'utterance' risks causing data races; this is an error in the Swift 6 language mode
- [ ] line 145: capture of 'utterance' with non-Sendable type 'AVSpeechUtterance' in a '@Sendable' closure
- [ ] line 145: sending 'utterance' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/Data/Persistence.swift` (6)

- [ ] line 11: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'CoreData'
- [ ] line 16: static property 'shared' is not concurrency-safe because non-'Sendable' type 'PersistenceController' may have shared mutable state; this is an error in the Swift 6 language mode
- [ ] line 67: reference to var 'NSMergeByPropertyObjectTrumpMergePolicy' is not concurrency-safe because it involves shared mutable state; this is an error in the Swift 6 language mode
- [ ] line 112: capture of 'defaults' with non-Sendable type 'UserDefaults' in a '@Sendable' closure
- [ ] line 113: capture of 'indexer' with non-Sendable type 'NSCoreDataCoreSpotlightDelegate' in a '@Sendable' closure
- [ ] line 153: static property 'preview' is not concurrency-safe because non-'Sendable' type 'PersistenceController' may have shared mutable state; this is an error in the Swift 6 language mode

### `scanner/Documents/PDFKitView.swift` (3)

- [ ] line 156: sending 'annotation' risks causing data races; this is an error in the Swift 6 language mode
- [ ] line 226: reference to captured var 'self' in concurrently-executing code
- [ ] line 229: reference to captured var 'self' in concurrently-executing code

### `scanner/Annotate/AnnotationSession.swift` (3)

- [ ] line 86: static property 'ink' is not concurrency-safe because non-'Sendable' type '[MarkSwatch]' may have shared mutable state; this is an error in the Swift 6 language mode
- [ ] line 95: static property 'highlighter' is not concurrency-safe because non-'Sendable' type '[MarkSwatch]' may have shared mutable state; this is an error in the Swift 6 language mode
- [ ] line 103: static property 'sizeNames' is not concurrency-safe because non-'Sendable' type '[LocalizedStringKey]' may have shared mutable state; this is an error in the Swift 6 language mode

### `scanner/Library/LibraryHomeView.swift` (2)

- [ ] line 23: type 'KeyPath<SmartFolder, Optional<String>>' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- [ ] line 253: type 'KeyPath<ScanTag, Optional<String>>' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### `scanner/Library/Workspace.swift` (2)

- [ ] line 102: sending 'providers' risks causing data races; this is an error in the Swift 6 language mode
- [ ] line 340: sending value of non-Sendable type '@MainActor (Int, Int) -> ()' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/Capture/CaptureCamera.swift` (1)

- [ ] line 895: capture of 'work' with non-Sendable type '() throws -> T' in a '@Sendable' closure

### `scanner/Rebuild/Rebuilder.swift` (1)

- [ ] line 186: sending value of non-Sendable type '@MainActor (Int, Int) -> Void' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/Documents/PDFLibrary.swift` (1)

- [ ] line 237: passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure; this is an error in the Swift 6 language mode

### `scanner/Documents/PDFDocumentView.swift` (1)

- [ ] line 684: sending value of non-Sendable type '@MainActor (Int, Int) -> ()' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/Documents/PDFPageOrganizer.swift` (1)

- [ ] line 359: sending 'copy' risks causing data races; this is an error in the Swift 6 language mode

### `scanner/UIKit/QuickLookController.swift` (1)

- [ ] line 107: conformance of 'QuickLookController.Coordinator' to protocol 'QLPreviewControllerDelegate' crosses into main actor-isolated code and can cause data races; this is an error in the Swift 6 language mode

### `scanner/Views/HomeView.swift` (1)

- [ ] line 319: passing closure as a 'sending' parameter risks causing data races between code in the current task and concurrent execution of the closure; this is an error in the Swift 6 language mode

### `scanner/Library/LibraryScope.swift` (1)

- [ ] line 116: static property 'livePredicate' is not concurrency-safe because non-'Sendable' type 'NSPredicate' may have shared mutable state; this is an error in the Swift 6 language mode

### `scanner/Library/LibrarySheets.swift` (1)

- [ ] line 138: type 'KeyPath<ScanTag, Optional<String>>' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### `scanner/Library/SmartFolderEditor.swift` (1)

- [ ] line 17: type 'KeyPath<ScanTag, Optional<String>>' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### `scanner/Rescriva/ScanModel.swift` (1)

- [ ] line 318: static property 'entries' is not concurrency-safe because non-'Sendable' type 'NSCache<NSManagedObjectID, RebuiltDocumentCache.Entry>' may have shared mutable state; this is an error in the Swift 6 language mode

### `scanner/Library/ScanCollectionView.swift` (1)

- [ ] line 19: type 'KeyPath<Scan, Optional<Date>>' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

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

- [ ] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.SwiftUIAttributes, AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute>'; this is an error in the Swift 6 language mode
- [ ] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.SwiftUIAttributes, AttributeScopes.SwiftUIAttributes.FontAttribute>'; this is an error in the Swift 6 language mode
- [ ] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.SwiftUIAttributes, AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute>'; this is an error in the Swift 6 language mode
- [ ] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.SwiftUIAttributes, AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute>'; this is an error in the Swift 6 language mode
- [ ] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.SwiftUIAttributes, AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute>'; this is an error in the Swift 6 language mode
- [ ] cannot form key path that captures non-Sendable type 'KeyPath<AttributeScopes.FoundationAttributes, AttributeScopes.FoundationAttributes.LinkAttribute>'; this is an error in the Swift 6 language mode

## Where to start

- The `static let` globals of non-Sendable type (`Persistence.swift`, `LibraryScope.swift`, `AnnotationSession.swift`,
  `ScanModel.swift`'s `RebuiltDocumentCache.entries`): mark the owning type `@MainActor`, or the value `nonisolated(unsafe)` with a reason.
- `PDFEditSession.swift` / `PDFKitView.swift` / `SpeechReader.swift`: PDFKit and AVSpeechSynthesizer objects crossing into
  `@Sendable` closures; hand over `@MainActor` work with `MainActor.assumeIsolated` or copy the values out first.
- The test targets: `setUp`/`tearDown` mutating `@MainActor` state from a nonisolated context; mark those test classes `@MainActor`.
- The `KeyPath` warnings in the Library views are `SortDescriptor`/`FetchRequest` key paths; they go away in Swift 6.2's
  toolchain or with `nonisolated(unsafe)` descriptors.
