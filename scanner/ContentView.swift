//
//  ContentView.swift
//  Open Scanner → Rescriva
//
//  Created by Slaven Radic on 2024-09-01.
//  Rescriva: the Library is the root; every other screen floats in above it. On a wide screen the
//  Library is the workspace (WorkspaceView), and screens laid out for a phone stand in a column.
//

import SwiftUI
import CoreData
import UIKit

struct ContentView: View {
	@Environment(\.managedObjectContext) private var viewContext
	@State private var router = RescrivaRouter()
	@ObservedObject private var appState = AppState.shared
	@ObservedObject private var navigationManager = NavigationManager.shared
	/// The library on this device couldn't be opened, so the app is on a temporary one
	/// (`PersistenceController.loadFailure`): an alert at launch, then a banner over the Library.
	var libraryIsTemporary = false
	@State private var showsTemporaryLibraryAlert = false
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		GeometryReader { proxy in
			stack(workspace: WorkspaceLayout(proxy.size))
		}
		.overlay(alignment: .leading) { edgeSwipeBack }
		.environment(router)
		// System controls (menus, alerts, the text cursor) take indigo ink, not system blue.
		.tint(.ink)
		// The app follows the system's appearance; the camera is always in the dark.
		.background(WindowAppearance(style: router.isCameraVisible ? .dark : .unspecified))
		.inboxImports(router: router)
		.onChange(of: appState.openScan) { _, scan in
			// Spotlight result or widget link.
			guard let scan else { return }
			router.popToRoot()
			router.push(.preview(scan))
			appState.openScan = nil
		}
		.onOpenURL { url in open(url) }
		.onChange(of: appState.viewState) { _, state in
			// "Scan Now" / "Rescriva settings" from a URL or shortcut. A Mac has no document camera.
			guard state != .Home else { return }
			appState.viewState = .Home
			guard state != .Page || !ProcessInfo.processInfo.isMacCatalystApp else { return }
			router.popToRoot()
			router.push(state == .Page ? .camera(.document, appendingTo: nil) : .settings)
		}
		.onChange(of: navigationManager.requestedClassicScan) { _, requested in
			guard requested else { return }
			navigationManager.requestedClassicScan = false
			guard !ProcessInfo.processInfo.isMacCatalystApp else { return }
			router.popToRoot()
			router.push(.camera(.document, appendingTo: nil))
		}
		.alert("Your library couldn't be opened", isPresented: $showsTemporaryLibraryAlert) {
			Button("OK", role: .cancel) {}
		} message: {
			Text("Rescriva is using a temporary library for now, so anything you scan or change is lost when the app closes. Nothing already saved on this device has been changed. Close Rescriva and reopen it to try again.")
		}
		.task {
			showsTemporaryLibraryAlert = libraryIsTemporary
			MacWindow.applyMinimumSize()
			ScannerShortcuts.updateAppShortcutParameters()
			if UserDefaults.standard.bool(forKey: RescrivaPreference.seedSampleLibrary) {
				SampleLibrary.seedIfEmpty(in: viewContext)
			}
			#if DEBUG
			if UserDefaults.standard.bool(forKey: "shareNearbyDemo") {
				router.push(.shareNearby(NearbySharePending.demoItems(in: viewContext)))
			}
			#endif
			await OriginalStore.pruneOrphans(in: viewContext)
			await FigureAssets.pruneOrphans(in: viewContext)
		}
	}

	/// A file handed to Rescriva (Open With on a Mac, "Open in Rescriva" from Files) opens inside the
	/// app: a PDF as a PDF, an image as a new scan. An openscanner://scan link starts a scan;
	/// openscanner://inbox brings in what Rescriva's Safari extension sent (Inbox);
	/// openscanner://share pairs Share Nearby with the web page that showed it.
	private func open(_ url: URL) {
		guard url.isFileURL else {
			if Inbox.handle(url) { return }
			if NearbySharePending.shared.receive(url) {
				showShareNearby()
				return
			}
			if url.host() == "scan" { appState.viewState = .Page }
			return
		}
		Task {
			if FileImport.isPDF(url) {
				await PDFOpening.open([url], in: PDFLibrary.shared, router: router)
			} else if let scan = await PhotoImport.scan(from: FileImport.images(at: [url]), in: viewContext) {
				router.popToRoot()
				router.push(.scan(scan))
			} else {
				router.showToast(String(localized: "That file couldn't be opened."))
			}
		}
	}

	/// Brings Share Nearby to the front for a pairing link: the one already on the stack (closing
	/// the screens above it), or a new one. Never a second one, which would share alongside the
	/// first while that one, hidden, took the link.
	private func showShareNearby() {
		let index = router.stack.lastIndex { entry in
			if case .shareNearby = entry.route { return true }
			return false
		}
		guard let index else {
			router.push(.shareNearby([]))
			return
		}
		for _ in (index + 1)..<router.stack.count { router.pop() }
	}

	/// The Library with the route stack floating above it, and the toast on top.
	private func stack(workspace: WorkspaceLayout?) -> some View {
		ZStack {
			let covered = !router.stack.isEmpty
			Group {
				if let workspace { WorkspaceView(layout: workspace) } else { HomeView() }
			}
			.safeAreaInset(edge: .top, spacing: 0) { temporaryLibraryBanner }
			.opacity(covered ? 0 : 1)
			.allowsHitTesting(!covered)
			.accessibilityHidden(covered)

			ForEach(Array(router.stack.enumerated()), id: \.element.id) { index, entry in
				let isTop = index == router.stack.count - 1
				framed(entry.route, wide: workspace != nil)
					.opacity(isTop ? 1 : 0)
					.allowsHitTesting(isTop)
					.accessibilityHidden(!isTop)
					.zIndex(Double(index + 1))
					.transition(reduceMotion ? AnyTransition.opacity : AnyTransition.settle)
			}

			if let toast = router.toast {
				VStack {
					ToastView(message: toast.message, style: toast.style, actionLabel: toast.actionLabel, action: toast.action.map { action in
						{
							action()
							router.dismissToast()
						}
					})
					.padding(.top, 8)
					.onTapGesture { router.dismissToast() }
					Spacer()
				}
				.zIndex(100)
				.transition(reduceMotion ? AnyTransition.opacity : AnyTransition.settle)
			}
		}
	}

	/// Stays above the Library while the app is on a temporary library, so nothing gets scanned
	/// into it unawares.
	@ViewBuilder
	private var temporaryLibraryBanner: some View {
		if libraryIsTemporary {
			BannerView(text: String(localized: "Rescriva couldn't open your library, so it's using a temporary one. Scans made now won't be kept. Close and reopen the app to try again."),
					   tone: .warning)
				.padding(.horizontal, 16)
				.padding(.vertical, 6)
		}
	}

	/// A screen laid out for a phone stands in a column on a wide screen; the camera, PDFs and
	/// comparisons use the whole width.
	@ViewBuilder
	private func framed(_ route: RescrivaRoute, wide: Bool) -> some View {
		if wide && !Self.fillsWideScreen(route) {
			ZStack {
				GrainBackground()
				screen(for: route)
					.frame(maxWidth: Self.phoneColumnWidth)
			}
		} else {
			screen(for: route)
		}
	}

	/// Widest a screen laid out for a phone grows on a wide screen, in points.
	static let phoneColumnWidth: CGFloat = 760

	static func fillsWideScreen(_ route: RescrivaRoute) -> Bool {
		switch route {
		case .camera, .pdf, .pdfCompare: return true
		default: return false
		}
	}

	@ViewBuilder
	private func screen(for route: RescrivaRoute) -> some View {
		switch route {
		case .camera(let kind, let scan):
			CaptureView(kind: kind, appendingTo: scan)
		case .preview(let scan):
			ScanPreviewView(scan: scan)
		case .scan(let scan):
			LiveScanSummary(scan: scan)
		case .page(let scan, let capture):
			LiveCaptureSummary(scan: scan, capture: capture)
		case .processing(let scan):
			ProcessingView(scan: scan)
		case .review(let scan):
			ReviewView(scan: scan)
		case .pdf(let id, let query):
			PDFDocumentView(itemID: id, findQuery: query)
		case .pdfFiles:
			PDFFilesView()
		case .pdfCompare(let left, let right):
			PDFCompareView(left: left, right: right)
		case .settings:
			SettingsView()
		case .collection(let scope):
			ScanCollectionView(scope: scope)
		case .shareNearby(let items):
			NearbyShareView(items: items)
		}
	}

	/// A thin leading strip that pops the screen on a rightward swipe, standing
	/// in for the system back gesture the custom stack doesn't get for free.
	@ViewBuilder
	private var edgeSwipeBack: some View {
		if canSwipeBack {
			Color.clear
				.frame(width: 18)
				.contentShape(Rectangle())
				.gesture(
					DragGesture(minimumDistance: 16)
						.onEnded { value in
							if value.translation.width > 70, abs(value.translation.height) < 80 {
								router.pop()
							}
						}
				)
				.accessibilityHidden(true)
		}
	}

	private var canSwipeBack: Bool {
		switch router.top {
		case .none, .camera, .processing: return false
		default: return true
		}
	}
}

/// Sets the appearance of the window it's in: dark while the camera shows, the system's otherwise.
/// (`preferredColorScheme(nil)` doesn't reliably hand a window back to the system once it has
/// been `.dark`; the window's own override does.)
private struct WindowAppearance: UIViewRepresentable {
	let style: UIUserInterfaceStyle

	func makeUIView(context: Context) -> WindowAppearanceView {
		WindowAppearanceView()
	}

	func updateUIView(_ view: WindowAppearanceView, context: Context) {
		view.style = style
	}
}

private final class WindowAppearanceView: UIView {
	var style: UIUserInterfaceStyle = .unspecified {
		didSet { apply() }
	}

	override func didMoveToWindow() {
		super.didMoveToWindow()
		apply()
	}

	private func apply() {
		guard let window, window.overrideUserInterfaceStyle != style else { return }
		window.overrideUserInterfaceStyle = style
	}
}

struct ContentView_Previews: PreviewProvider {
	static var previews: some View {
		ContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
	}
}
