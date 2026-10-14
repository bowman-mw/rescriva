//
//  QuickLookController.swift
//  Open Scanner
//
//  Created by Slaven Radic on 2024-09-01.
//

import SwiftUI
import UIKit
import QuickLook

struct QuickLookView: View {
	@Environment(\.dismiss) private var dismiss
	@State var scanCapture: ScanCapture
	
	var body: some View {
		ZStack(alignment: .top) {
			if ProcessInfo.processInfo.isMacCatalystApp {
				// QuickLook's preview stays blank inside a Mac Catalyst window.
				MacPageView(capture: scanCapture)
			} else {
				QuickLookController(scanCapture: scanCapture)
					.ignoresSafeArea(edges: .all)
			}
			
			HStack {

				buttonBack
				Spacer()
			}
			// Inside the safe area (only the preview runs edge to edge), where
			// the back pill sits on every other screen.
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
		}
	}
	
	var buttonBack: some View {
		BackPill(title: "Page") {
			dismiss()
		}
	}
	
}

/// A page on the Mac, fitted to the window; pinch to zoom, then scroll around it.
struct MacPageView: View {
	@ObservedObject var capture: ScanCapture
	@State private var zoom: CGFloat = 1
	@GestureState private var pinch: CGFloat = 1

	/// Most a page is magnified.
	static let maxZoom: CGFloat = 6

	var body: some View {
		GeometryReader { proxy in
			let scale = min(max(zoom * pinch, 1), Self.maxZoom)
			ScrollView([.horizontal, .vertical]) {
				page
					.frame(width: proxy.size.width * scale, height: proxy.size.height * scale)
			}
			.gesture(
				MagnifyGesture()
					.updating($pinch) { value, state, _ in state = value.magnification }
					.onEnded { value in zoom = min(max(zoom * value.magnification, 1), Self.maxZoom) }
			)
		}
		.padding(.top, 52)
		.background(Color.scanBackdrop.ignoresSafeArea())
	}

	@ViewBuilder
	private var page: some View {
		if let image = capture.image {
			Image(uiImage: image)
				.resizable()
				.scaledToFit()
				.overlay { MarksOverlay(marks: capture.pageMarks) }
				.padding(24)
		} else {
			Text("This page couldn't be opened.")
				.font(RescrivaFont.note(16))
				.foregroundStyle(.graphite)
		}
	}
}

struct QuickLookController: UIViewControllerRepresentable {
	
	var scanCapture: ScanCapture
	
	func makeUIViewController(context: Context) -> UINavigationController {
		let controller = QLPreviewController()
		controller.dataSource = context.coordinator
		controller.delegate = context.coordinator
		controller.setEditing(true, animated: true)
		let navigationController = UINavigationController(rootViewController: controller)
		return navigationController
	}
	
	func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
	
	func makeCoordinator() -> Coordinator {
		return Coordinator(parent: self)
	}
	
	/// On the main actor, like its data source protocol. The delegate protocol isn't marked, but
	/// Quick Look calls it on the main thread too, so that conformance is main-actor as well.
	class Coordinator: NSObject, @MainActor QLPreviewControllerDelegate, QLPreviewControllerDataSource {
		
		let parent: QuickLookController
		
		init(parent: QuickLookController) {
			self.parent = parent
		}
		
		func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
		
		func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
			// Markup here rewrites the scan itself; an annotated page is shown with its
			// marks drawn in, so editing it would bake them into the image.
			marks.isEmpty ? .updateContents : .disabled
		}
		
		func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
			
			let url = imageUrl
			var data: Data = self.parent.scanCapture.imageData ?? Data()
			let pageMarks = marks
			if !pageMarks.isEmpty, let image = parent.scanCapture.image,
			   let annotated = MarkRenderer.flattened(image, marks: pageMarks).jpegData(compressionQuality: 0.85) {
				data = annotated
			}
			do {
				try QuickLookCopy.prepareDirectory()
				try data.write(to: url)
			} catch {
				Log.library.error("Couldn't load the image for Quick Look")
			}
			
			let previewItem = ScanPreview(url: url, title: "Scan")
			return previewItem as QLPreviewItem
		}
		
		func previewController(_ controller: QLPreviewController, didUpdateContentsOf previewItem: QLPreviewItem) {
			
			do {
				let imageData = try Data(contentsOf: imageUrl)
				// Rescriva: through PageReprocessor, so the page is read again, its page of the rebuilt
				// document redone, and figures are never cut from its original with the old recipe.
				let capture = parent.scanCapture
				Task { @MainActor in
					PageReprocessor.storeEdited(imageData, on: capture)
				}
			} catch {
				Log.library.error("Couldn't load the image Quick Look edited")
			}
		}
		
		/// The page's marks from Annotate.
		private var marks: [PageMark] {
			MainActor.assumeIsolated { parent.scanCapture.pageMarks }
		}
		
		/// Rescriva: the page's copy in the temporary folder (`QuickLookCopy`), not Documents, where
		/// it outlived the page and went into device backups.
		var imageUrl: URL {
			QuickLookCopy.url(for: self.parent.scanCapture.id)
		}
	}
}

/// The copy of a page that Quick Look shows and edits (Rescriva). It lives in the temporary folder,
/// never backed up, goes with its page when the page is deleted for good, and is cleared as the
/// app starts, with the copies earlier versions left in Documents.
enum QuickLookCopy {
	/// The folder the copies are written to.
	static var directory: URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("QuickLook", isDirectory: true)
	}

	/// Page `id`'s copy in `folder` ("scan" for a page without an id).
	static func url(for id: UUID?, in folder: URL = QuickLookCopy.directory) -> URL {
		folder.appendingPathComponent((id?.uuidString ?? "scan") + ".jpg")
	}

	/// Creates the folder the copies are written to.
	static func prepareDirectory() throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	/// Removes page `id`'s copy from each of `folders`: the temporary folder and Documents, where
	/// earlier versions wrote it.
	static func remove(for id: UUID, from folders: [URL] = [QuickLookCopy.directory, getDocumentsDirectory()]) {
		for folder in folders {
			let copy = url(for: id, in: folder)
			guard FileManager.default.fileExists(atPath: copy.path) else { continue }
			do {
				try FileManager.default.removeItem(at: copy)
			} catch {
				Log.library.error("Couldn't remove a Quick Look copy: \(error)")
			}
		}
	}

	/// Removes the copies in each of `folders` last written before `cutoff`, so a page being
	/// previewed right now keeps its copy. Only files named as copies (`<page id>.jpg`, `scan.jpg`)
	/// go; Documents holds nothing else of Rescriva's. Returns how many went.
	static func sweep(_ folders: [URL], before cutoff: Date) -> Int {
		var removed = 0
		for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
			let urls: [URL]
			do {
				urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
			} catch {
				Log.library.error("Couldn't list Quick Look copies: \(error)")
				continue
			}
			for url in urls where isCopy(url) && modified(url) < cutoff {
				do {
					try FileManager.default.removeItem(at: url)
					removed += 1
				} catch {
					Log.library.error("Couldn't remove a Quick Look copy: \(error)")
				}
			}
		}
		return removed
	}

	/// Clears the copies an earlier run left, off the main thread. Call once as the app starts:
	/// the cutoff is taken now, so copies this run writes are never swept.
	static func sweepAtLaunch() {
		let launch = Date()
		let folders = [directory, getDocumentsDirectory()]
		Task.detached(priority: .utility) {
			let removed = sweep(folders, before: launch)
			if removed > 0 {
				Log.library.notice("Removed \(removed) Quick Look copies left from an earlier run")
			}
		}
	}

	/// True for a file named as a copy: `<page id>.jpg` or `scan.jpg`.
	static func isCopy(_ url: URL) -> Bool {
		guard url.pathExtension.lowercased() == "jpg" else { return false }
		let name = url.deletingPathExtension().lastPathComponent
		return name == "scan" || UUID(uuidString: name) != nil
	}

	/// When the file was last written; long ago when that can't be read.
	private static func modified(_ url: URL) -> Date {
		do {
			return try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
		} catch {
			return .distantPast
		}
	}
}

class ScanPreview: NSObject, QLPreviewItem {
	
	var previewItemURL: URL?
	var previewItemTitle: String?
	
	init(url: URL?, title: String?) {
		previewItemURL = url
		previewItemTitle = title
	}
}
