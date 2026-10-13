//
//  RescrivaRouter.swift
//  Rescriva (fork of Open Scanner)
//
//  Navigation for the Rescriva flow. Screens settle into place like a page
//  laid on the desk and dissolve out (Rescriva's motion rules have no sliding
//  pushes), so instead of a
//  NavigationStack the app keeps an explicit stack of routes over the Library.
//

import SwiftUI
import CoreData
import UIKit

/// The design's screen map, below the Library root.
enum RescrivaRoute: Hashable {
	/// The document camera; `appendingTo` adds pages to an existing scan.
	case camera(CaptureKind, appendingTo: Scan?)
	/// Read-only preview of a scan (what opens from the Library).
	case preview(Scan)
	/// Scan & pages — the editor, reached with Edit.
	case scan(Scan)
	/// Recognized text for one page.
	case page(Scan, ScanCapture)
	/// Rebuilding into Word or Slides.
	case processing(Scan)
	/// Review & fix.
	case review(Scan)
	/// A PDF from Files, kept as a PDF; `query` opens the find bar with it.
	case pdf(UUID, query: String?)
	/// Every PDF opened in Rescriva.
	case pdfFiles
	/// Two PDFs side by side, their differences marked when they're versions of one document.
	case pdfCompare(PDFCompareSide, PDFCompareSide)
	case settings
	/// A folder, tag, smart folder, Pinned, All Scans, Favorites or Recently Deleted.
	case collection(LibraryScope)
	/// Share Nearby, sharing these documents to start with (`NearbyShareView`).
	case shareNearby([NearbyShareItem])
}

/// What the camera is pointed at. Stored token.
enum CaptureKind: String, Hashable {
	case document, whiteboard
}

/// One entry on the route stack, with a stable identity for transitions.
struct RouteEntry: Identifiable, Hashable {
	let id = UUID()
	let route: RescrivaRoute
}

/// A transient confirmation shown at the top of the screen.
struct RescrivaToast: Identifiable {
	/// How the toast marks its message.
	enum Style {
		/// A tick.
		case done
		/// A page settling onto its stack: a file was shared or saved.
		case exported
	}

	let id = UUID()
	let message: String
	var style: Style = .done
	var actionLabel: String?
	var action: (() -> Void)?
}

/// Owns the route stack and the toast. One per window.
@MainActor
@Observable
final class RescrivaRouter {
	private(set) var stack: [RouteEntry] = [] {
		didSet { LibraryPlacement.shared.folderID = placementFolderID }
	}
	private(set) var toast: RescrivaToast?

	/// The visible route, or nil when the Library is showing.
	var top: RescrivaRoute? { stack.last?.route }

	/// The route a back pill on `route` returns to (nil = the Library).
	func routeBelow(_ route: RescrivaRoute) -> RescrivaRoute? {
		guard let index = stack.lastIndex(where: { $0.route == route }), index > 0 else { return nil }
		return stack[index - 1].route
	}

	/// The folder the topmost folder screen shows, which new scans join.
	var placementFolderID: UUID? {
		for entry in stack.reversed() {
			if case .collection(.folder(let id)) = entry.route { return id }
		}
		return nil
	}

	/// True while the camera is the visible screen (the status bar turns light).
	var isCameraVisible: Bool {
		if case .camera = top { return true }
		return false
	}

	func push(_ route: RescrivaRoute) {
		withAnimation(RescrivaMotion.ui) {
			stack.append(RouteEntry(route: route))
		}
	}

	func pop() {
		guard !stack.isEmpty else { return }
		withAnimation(RescrivaMotion.ui) {
			_ = stack.removeLast()
		}
	}

	func popToRoot() {
		withAnimation(RescrivaMotion.ui) {
			stack.removeAll()
		}
	}

	/// Swaps the visible screen, e.g. Rebuilding → Review, or Camera → Scan.
	func replaceTop(with route: RescrivaRoute) {
		withAnimation(RescrivaMotion.ui) {
			if !stack.isEmpty { stack.removeLast() }
			stack.append(RouteEntry(route: route))
		}
	}

	/// Drops any screens showing a scan that was deleted.
	func forget(_ scan: Scan) {
		stack.removeAll { entry in
			switch entry.route {
			case .preview(let s), .scan(let s), .processing(let s), .review(let s), .page(let s, _): return s == scan
			case .camera(_, let s): return s == scan
			case .pdfCompare(let left, let right): return [left, right].contains(.scan(scan))
			case .settings, .collection, .pdf, .pdfFiles, .shareNearby: return false
			}
		}
	}

	/// Drops any screens showing a PDF that was deleted.
	func forget(pdf id: UUID) {
		stack.removeAll { entry in
			switch entry.route {
			case .pdf(let shown, _): return shown == id
			case .pdfCompare(let left, let right):
				return [left, right].contains { side in
					if case .pdf(let shown, _) = side { return shown == id }
					return false
				}
			default: return false
			}
		}
	}

	func showToast(_ message: String, style: RescrivaToast.Style = .done, actionLabel: String? = nil, action: (() -> Void)? = nil) {
		let next = RescrivaToast(message: message, style: style, actionLabel: actionLabel, action: action)
		withAnimation(RescrivaMotion.ui) {
			toast = next
		}
		Task { [weak self] in
			do {
				try await Task.sleep(for: .seconds(action == nil ? 2.4 : 4))
			} catch {
				return  // cancelled: leave the toast to the next one
			}
			guard let self, self.toast?.id == next.id else { return }
			withAnimation(RescrivaMotion.ui) {
				self.toast = nil
			}
		}
	}

	func dismissToast() {
		withAnimation(RescrivaMotion.ui) {
			toast = nil
		}
	}
}

// MARK: - Device tier

/// What this iPhone can do, from the plan's "Scan modes and device support".
/// Stored token (also accepted as the `deviceTier` launch argument override).
enum DeviceTier: String, CaseIterable {
	/// Apple Intelligence iPhones: handwriting, equations and diagrams.
	case smart
	/// iOS 26: typed pages and tables via Vision's document reader.
	case basic
	/// Everything else: clean, searchable PDFs.
	case pdf

	static var current: DeviceTier {
		if let override = UserDefaults.standard.string(forKey: RescrivaPreference.deviceTier),
		   let tier = DeviceTier(rawValue: override) {
			return tier
		}
		guard #available(iOS 26.0, *) else { return .pdf }
		return AppleIntelligence.isAvailable ? .smart : .basic
	}

	var canRebuild: Bool { self != .pdf }

	var displayName: String {
		switch self {
		case .smart: return String(localized: "Smart rebuild")
		case .basic: return String(localized: "Basic rebuild")
		case .pdf: return String(localized: "PDF scanner")
		}
	}

	var summary: String {
		switch self {
		case .smart: return String(localized: "This iPhone can rebuild handwriting and whiteboard diagrams into editable files.")
		case .basic: return String(localized: "This iPhone rebuilds typed pages and tables. Diagrams come through as pictures.")
		case .pdf: return String(localized: "This iPhone makes clean, searchable PDFs. Rebuilding needs a newer model.")
		}
	}
}

// MARK: - Preferences

/// UserDefaults keys (stored tokens). Launch arguments override any of them,
/// e.g. `-deviceTier pdf -seedSampleLibrary YES`.
enum RescrivaPreference {
	static let autoCapture = "autoCapture"
	static let removeShadows = "removeShadows"
	static let keepMarkerColors = "keepMarkerColors"
	static let companionTips = "companionTips"
	static let deviceTier = "deviceTier"
	static let seedSampleLibrary = "seedSampleLibrary"
	/// Keep each page's original photo on this iPhone, so its crop can be fixed later.
	static let keepOriginals = "keepOriginals"
	/// When the page shows glare, take a second look from a little to one side and fuse the photos.
	static let multiFrameGlare = "multiFrameGlare"
	/// The searchable PDF's paper and image quality, as last chosen in Export (`PDFPaperSize`,
	/// `PDFImageQuality`). A PDF's password is never stored.
	static let pdfPaperSize = "pdfPaperSize"
	static let pdfImageQuality = "pdfImageQuality"

	static func registerDefaults() {
		UserDefaults.standard.register(defaults: [
			autoCapture: true,
			removeShadows: true,
			keepMarkerColors: true,
			companionTips: true,
			keepOriginals: true,
			multiFrameGlare: true,
		])
	}
}

// MARK: - Sharing

/// Presents the system share sheet from the frontmost view controller.
enum SharePresenter {
	/// Shares `items` from the frontmost screen. On a Mac, files go to the Save panel instead,
	/// which is what sharing a file means there; on iPad and Mac the share sheet floats centred.
	@MainActor
	static func share(_ items: [Any], completion: ((UIActivity.ActivityType?, Bool) -> Void)? = nil) {
		guard let presenter = frontmostViewController() else { return }
		let files = items.compactMap { $0 as? URL }.filter(\.isFileURL)
		if ProcessInfo.processInfo.isMacCatalystApp, !files.isEmpty, files.count == items.count {
			presenter.present(SavePanel(files: files, completion: completion), animated: true)
			return
		}
		let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
		controller.completionWithItemsHandler = { type, completed, _, _ in
			completion?(type, completed)
		}
		if let popover = controller.popoverPresentationController {
			popover.sourceView = presenter.view
			popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
			popover.permittedArrowDirections = []
		}
		presenter.present(controller, animated: true)
	}

	@MainActor
	static func frontmostViewController() -> UIViewController? {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
		var top = window?.rootViewController
		while let presented = top?.presentedViewController {
			top = presented
		}
		return top
	}
}

/// The Mac's Save panel for exported files (Mac Catalyst shows the document picker as one).
final class SavePanel: UIDocumentPickerViewController, UIDocumentPickerDelegate {
	/// Reported as the activity once the files are saved, so callers word it as a save.
	static let savedActivity = UIActivity.ActivityType("com.rescriva.SaveToFiles")
	private var completion: ((UIActivity.ActivityType?, Bool) -> Void)?

	convenience init(files: [URL], completion: ((UIActivity.ActivityType?, Bool) -> Void)?) {
		self.init(forExporting: files, asCopy: true)
		self.completion = completion
		delegate = self
	}

	func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		completion?(Self.savedActivity, true)
	}

	func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
		completion?(nil, false)
	}
}

/// The Mac window's smallest size: room for the workspace's three columns.
enum MacWindow {
	static let minimumSize = CGSize(width: 1_000, height: 640)

	/// Holds every Mac window to `minimumSize`; nothing changes on iPhone or iPad, whose scenes
	/// have no size restrictions.
	@MainActor
	static func applyMinimumSize() {
		guard ProcessInfo.processInfo.isMacCatalystApp else { return }
		for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
			scene.sizeRestrictions?.minimumSize = minimumSize
		}
	}
}
