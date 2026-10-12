# Rescriva

[rescriva.com](https://rescriva.com)

Rescriva scans pages and whiteboards on iPhone, iPad and Mac and turns them into searchable PDFs or editable Word (.docx) and PowerPoint (.pptx) files — on the device, with no server. It also opens, marks up and compares the PDFs you already have, and keeps everything in a library that syncs through iCloud.

## Features

- **Capture** — Rescriva's own camera (AVFoundation + Vision) with live page outlining, auto-capture when steady, perspective correction, shadow removal and a whiteboard mode; imported photos get the same cleanup. A photo of a book spread splits into two pages along its fold.
- **Searchable PDF** — page images with an invisible OCR text layer; notes become PDF annotations. Pages keep their own shape or sit on A4 or Letter, at three image qualities, with an optional password.
- **Looks** — Color, Gray, a true black and white (Sauvola's local threshold, after Leptonica) and Ink for whiteboards and handwriting (the whitepaper filter from OSS Document Scanner, sized to the page's strokes). The preview is drawn by the same code as the export.
- **Rebuild** — Vision's document reader (iOS 26) plus layout heuristics build one intermediate document (`scanner/Rebuild/RescrivaDocument.swift`) that every exporter reads; pages with columns read down each column in turn (a recursive XY-cut); Apple Intelligence re-ranks uncertain words on capable iPhones.
- **Review & fix** — uncertain words and arrows are flagged for one-tap fixes; bold/italic/underline, heading and notes edit the document before export.
- **Export** — Word, PowerPoint, searchable PDF and plain text, written by Rescriva's own OOXML writer.
- **PDFs** — open existing PDFs to read, search, fill in forms, mark up (with Apple Pencil, plus a note margin), reorder pages and compare two versions.
- **Library** — folders, tags, smart folders and Recently Deleted, synced through iCloud, with Spotlight and Shortcuts.
- **iPad, Mac and Safari** — a workspace layout on iPad and Mac (Mac Catalyst), and a Safari extension that sends web pages and PDFs to the app.

Requires iOS 17 (rebuilding needs iOS 26). For a sample library in the Simulator, launch with `-seedSampleLibrary YES`; `-deviceTier smart|basic|pdf` previews each device tier.

## Credits

Rescriva began as a fork of [Open Scanner](https://github.com/pencilresearch/OpenScanner) by [Pencil Research](https://pencilresearch.com) and still includes some of its code, used under the MIT License. Open Scanner's copyright and license notice is in [LICENSE](LICENSE) and in the app's Acknowledgements.
