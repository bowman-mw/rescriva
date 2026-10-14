//
//  NearbyShareView.swift
//  Rescriva (fork of Open Scanner)
//
//  Share Nearby: documents shared with computers and phones close by, through
//  share.rescriva.com. Each document has its own PIN, set large so it reads
//  across a desk; a phone that scans this screen's QR code (or a computer
//  paired with the page's code) needs none. Requests to send files here wait
//  for Accept, and transfers show their progress. A page found through the relay
//  on the same network proves nothing, so its row shows a six-digit check number
//  the page shows too, and the screen warns when more than one such page is
//  about. Sharing runs only while this screen is the one showing and the app is
//  in front: closing it, covering it with another screen or leaving the app ends
//  the sharing, and coming back starts again with new PINs.
//

import SwiftUI
import UIKit

struct NearbyShareView: View {
	/// What the screen was opened with (also how the route is found on the stack).
	let items: [NearbyShareItem]

	@Environment(RescrivaRouter.self) private var router
	@Environment(\.managedObjectContext) private var context
	@Environment(\.scenePhase) private var scenePhase

	/// Made on first appearance (it needs the environment's context), and kept by
	/// `NearbyShareSessionStore` while this screen is on the stack, so rebuilding the view doesn't
	/// end it. Stopping and starting it again keeps its documents and gives them new PINs.
	@State private var session: NearbyShareSession?
	/// This screen's entry on the route stack.
	@State private var entryID: UUID?
	@State private var inBackground = false
	/// A pairing link that came from outside the app, waiting for the user to say yes.
	@State private var confirmingPairing: SharePairingOffer?
	@State private var picking = false
	@State private var scanning = false
	@State private var showsPasteField = false
	@State private var pastedLink = ""
	@State private var pasteProblem: String?

	/// "share.rescriva.com" (or the test site's host and port).
	static var siteName: String {
		let url = NearbyShareConfig.siteURL
		guard let host = url.host(), !host.isEmpty else { return "share.rescriva.com" }
		guard let port = url.port else { return host }
		return "\(host):\(port)"
	}

	private var isMac: Bool { ProcessInfo.processInfo.isMacCatalystApp }

	var body: some View {
		ZStack {
			GrainBackground()
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					HStack {
						BackPill(title: backTitle) { router.pop() }
						Spacer()
					}
					.padding(.horizontal, 12)
					.padding(.vertical, 6)

					titleBlock
					if let session {
						sections(session)
					} else {
						ProgressView()
							.frame(maxWidth: .infinity)
							.padding(.top, 40)
					}
				}
				.padding(.bottom, 60)
			}
			.scrollDismissesKeyboard(.interactively)
			.overlay(alignment: .top) { StatusBarScrim() }
		}
		.sheet(isPresented: $picking) {
			ShareDocumentPicker(alreadyShared: session?.documents.map(\.source) ?? []) { session?.add($0) }
				.environment(\.managedObjectContext, context)
		}
		.sheet(isPresented: $scanning) {
			ShareCodeScanner { pair(link: $0) }
		}
		.alert(pairingAlertTitle, isPresented: confirmingBinding, presenting: confirmingPairing) { offer in
			if offer.isWithinPrivateNetwork {
				// The link came from outside the app; whoever made it holds its secret. Local only,
				// so it can't reach past this network however it was made.
				Button("Pair") { session?.pair(with: offer, localOnly: true) }
				Button("Cancel", role: .cancel) {}
			} else {
				// Cancel is the default: a link from a website can name a computer anywhere.
				Button("Cancel", role: .cancel) {}
					.keyboardShortcut(.defaultAction)
				Button("Pair anyway", role: .destructive) { session?.pair(with: offer) }
			}
		} message: { offer in
			if offer.isWithinPrivateNetwork {
				Text("Only pair with a page you opened yourself at \(Self.siteName). A paired computer can download everything you share here without PINs.")
			} else {
				Text("This link points to a computer outside your network. Pair only if you expect that. A paired computer can download everything you share here without PINs.")
			}
		}
		.onAppear { appeared() }
		.onDisappear { disappeared() }
		.onChange(of: isShowing) { _, _ in update() }
		.onChange(of: scenePhase) { _, phase in sceneChanged(phase) }
		.onChange(of: NearbySharePending.shared.link) { _, link in
			if link != nil { takePendingLink() }
		}
	}

	// MARK: Lifecycle

	/// True while this screen is the top of the stack, so the one showing. The router keeps
	/// covered screens alive (hidden), so appearing and disappearing don't say this.
	private var isShowing: Bool {
		guard let entryID else { return false }
		return router.stack.last?.id == entryID
	}

	/// Finds this screen's stack entry and its session (made the first time), then shares if it's
	/// showing.
	private func appeared() {
		NearbyShareSessionStore.prune()
		let route = RescrivaRoute.shareNearby(items)
		guard let entry = router.stack.last(where: { $0.route == route }) else { return }
		entryID = entry.id
		session = NearbyShareSessionStore.session(for: entry.id, items: items, router: router, make: makeSession)
		update()
	}

	private func makeSession() -> NearbyShareSession {
		let made = NearbyShareSession(items: items, context: context)
		made.onSaved = { [weak router] name in
			router?.showToast(String(localized: "Received “\(name)”"), style: .exported)
		}
		return made
	}

	/// The view went away. Only when its entry left the stack does the sharing end: a view rebuilt
	/// in place (a window crossing between wide and narrow) hands the session to the new one.
	private func disappeared() {
		guard let entryID, !router.stack.contains(where: { $0.id == entryID }) else { return }
		if session?.isRunning == true { UIApplication.shared.isIdleTimerDisabled = false }
		NearbyShareSessionStore.prune()
	}

	/// Shares while this screen is showing and the app is in front, keeping the screen awake;
	/// otherwise stops. Starting again later makes new PINs.
	private func update() {
		guard let session else { return }
		if isShowing && !inBackground {
			UIApplication.shared.isIdleTimerDisabled = true
			session.start()
			takePendingLink()
		} else if session.isRunning {
			UIApplication.shared.isIdleTimerDisabled = false
			session.stop()
		}
	}

	/// Sharing stops when the app leaves the foreground, and starts again, with new PINs, when it
	/// comes back to this screen.
	private func sceneChanged(_ phase: ScenePhase) {
		switch phase {
		case .background:
			guard !inBackground else { return }
			inBackground = true
			update()
		case .active:
			guard inBackground else { return }
			inBackground = false
			update()
		default:
			break
		}
	}

	private func remove(_ document: NearbyShareSession.SharedDocument) {
		withAnimation(RescrivaMotion.ui) {
			session?.remove(document)
		}
	}

	// MARK: Pairing

	/// A link from the Camera app or "Open in Rescriva", once this screen is showing and sharing.
	/// Anything could have opened it, so it pairs only once the user says yes.
	private func takePendingLink() {
		guard isShowing, !inBackground, session?.isRunning == true,
			  let link = NearbySharePending.shared.take() else { return }
		guard let offer = offer(from: link) else { return }
		confirmingPairing = offer
	}

	private var confirmingBinding: Binding<Bool> {
		Binding(get: { confirmingPairing != nil }, set: { shown in
			if !shown { confirmingPairing = nil }
		})
	}

	/// Plainer for a code that names a computer on this network; a warning for one that doesn't.
	private var pairingAlertTitle: Text {
		guard let confirmingPairing, !confirmingPairing.isWithinPrivateNetwork else {
			return Text("Pair with this computer?")
		}
		return Text("Pair with a computer outside your network?")
	}

	/// Pairs with a page code the user scanned or pasted here.
	private func pair(link: String) {
		guard let session, let offer = offer(from: link) else { return }
		session.pair(with: offer)
	}

	/// The page code in `link`, or nil (with the problem shown) when it isn't one. Untrusted:
	/// `SharePairingOffer` checks every byte.
	private func offer(from link: String) -> SharePairingOffer? {
		let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
		guard text.utf8.count <= NearbySharePending.maxLinkLength, let offer = SharePairingOffer(link: text) else {
			pasteProblem = String(localized: "That isn't a pairing link from \(Self.siteName). Copy it again from “Pair with Rescriva” on the page.")
			showsPasteField = true
			return nil
		}
		pasteProblem = nil
		pastedLink = ""
		return offer
	}

	private func connectPasted() {
		guard !pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		pair(link: pastedLink)
	}

	// MARK: Title

	private var titleBlock: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Share Nearby")
				.font(RescrivaFont.header(30))
				.foregroundStyle(.carbon)
				.accessibilityAddTraits(.isHeader)
			if let session {
				relayLine(session.relayState)
			}
		}
		.padding(.horizontal, 20)
		.padding(.top, 12)
		.padding(.bottom, 4)
	}

	private func relayLine(_ state: NearbyShareSession.RelayState) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Circle()
				.fill(relayColor(state))
				.frame(width: 8, height: 8)
				.alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
				.accessibilityHidden(true)
			Text(relayText(state))
				.font(RescrivaFont.ui(13))
				.foregroundStyle(.graphite)
				.fixedSize(horizontal: false, vertical: true)
		}
		.accessibilityElement(children: .combine)
	}

	private func relayText(_ state: NearbyShareSession.RelayState) -> String {
		switch state {
		case .off: return String(localized: "Relay off. Pair a computer with its code below.")
		case .connecting: return String(localized: "Looking for devices on this network…")
		case .open: return String(localized: "Open \(Self.siteName) on a computer or phone on this network.")
		case .unavailable: return String(localized: "Can't reach the relay. Pair a computer with its code below.")
		}
	}

	private func relayColor(_ state: NearbyShareSession.RelayState) -> Color {
		switch state {
		case .open: return .bluePencil
		case .unavailable: return .markerInk
		case .off, .connecting: return Color.graphite.opacity(0.6)
		}
	}

	/// Names the screen underneath, like the other inner screens' back pills.
	private var backTitle: LocalizedStringKey {
		guard let below = router.routeBelow(.shareNearby(items)) else { return "Scans" }
		switch below {
		case .collection: return "Scans"
		case .pdf: return "PDF"
		case .pdfFiles: return "PDF Files"
		case .preview, .scan, .review, .page: return "Scan"
		case .settings: return "Settings"
		default: return "Back"
		}
	}

	// MARK: Sections

	@ViewBuilder
	private func sections(_ session: NearbyShareSession) -> some View {
		if session.untrustedPageCount > 1 {
			BannerView(text: String(localized: "More than one computer on this network can see what you're sharing. Check the number on each one."),
					   tone: .warning)
				.padding(.horizontal, 16)
				.padding(.top, 12)
				.transition(.settle)
		}
		// Requests to send come first: the page is waiting on them.
		if !session.incoming.isEmpty {
			sectionLabel("Waiting for you")
			VStack(spacing: 12) {
				ForEach(session.incoming) { offer in incomingCard(offer, session: session) }
			}
			.padding(.horizontal, 16)
		}
		sectionLabel("Shared")
		sharedCard(session)
		sectionLabel("Open on a phone")
		phoneCard(session)
		sectionLabel("Computer")
		computerCard(session)
		sectionLabel("Connected")
		devicesCard(session)
		if !session.transfers.isEmpty {
			sectionLabel("Activity")
			activityCard(session)
		}
	}

	private func sectionLabel(_ title: LocalizedStringKey) -> some View {
		Text(title)
			.rescrivaSectionLabel()
			.padding(.horizontal, 20)
			.padding(.top, 22)
			.padding(.bottom, 8)
			.accessibilityAddTraits(.isHeader)
	}

	private var rule: some View {
		Divider().overlay(Color.carbon.opacity(0.06))
	}

	// MARK: Shared

	private func sharedCard(_ session: NearbyShareSession) -> some View {
		VStack(spacing: 0) {
			if session.documents.isEmpty {
				Text("Nothing shared yet. Add scans or PDFs and they show up on the page, each with its own PIN.")
					.font(RescrivaFont.note(15))
					.foregroundStyle(.graphite)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(16)
				rule
			}
			ForEach(session.documents) { document in
				documentRow(document)
				rule
			}
			if !session.documents.isEmpty {
				Text("A PIN only lets the page that types it download that file. On a page that isn't paired, check its number under Connected first.")
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
					.fixedSize(horizontal: false, vertical: true)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 16)
					.padding(.vertical, 10)
				rule
			}
			Button { picking = true } label: {
				HStack(spacing: 10) {
					Glyph("plus", size: 15, weight: .semibold)
					Text("Add documents")
						.font(RescrivaFont.ui(15, weight: .medium))
					Spacer(minLength: 0)
				}
				.foregroundStyle(.ink)
				.padding(.vertical, 14)
				.padding(.horizontal, 16)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
		}
		.paperCard()
		.padding(.horizontal, 16)
	}

	/// The name, size and PIN side by side where they fit, the PIN on its own line where not.
	private func documentRow(_ document: NearbyShareSession.SharedDocument) -> some View {
		ViewThatFits(in: .horizontal) {
			HStack(spacing: 12) {
				documentInfo(document)
					.frame(minWidth: 120, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
				documentPIN(document)
				removeButton(document)
			}
			VStack(alignment: .leading, spacing: 10) {
				HStack(alignment: .top, spacing: 8) {
					documentInfo(document)
					Spacer(minLength: 0)
					removeButton(document)
				}
				documentPIN(document)
			}
		}
		.padding(.vertical, 12)
		.padding(.leading, 16)
		.padding(.trailing, 6)
	}

	private func documentInfo(_ document: NearbyShareSession.SharedDocument) -> some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(document.name)
				.font(RescrivaFont.ui(15, weight: .medium))
				.foregroundStyle(.carbon)
				.lineLimit(3)
			switch document.state {
			case .preparing:
				HStack(spacing: 6) {
					ProgressView()
						.controlSize(.mini)
					Text("Getting it ready…")
				}
				.font(RescrivaFont.ui(12))
				.foregroundStyle(.graphite)
			case .ready:
				Text(document.size > 0 ? Self.byteText(document.size) : String(localized: "Ready"))
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
			case .failed(let reason):
				Text(reason)
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	@ViewBuilder
	private func documentPIN(_ document: NearbyShareSession.SharedDocument) -> some View {
		if case .failed = document.state {
			EmptyView()
		} else {
			VStack(alignment: .leading, spacing: 3) {
				Text("PIN").rescrivaSectionLabel()
				BigCode(text: ShareCodes.displayPIN(document.pin))
					.opacity(document.state == .ready ? 1 : 0.55)
			}
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(Text("PIN \(Self.spelledOut(document.pin))"))
			.animation(RescrivaMotion.ui, value: document.pin)
		}
	}

	private func removeButton(_ document: NearbyShareSession.SharedDocument) -> some View {
		Button { remove(document) } label: {
			Glyph("xmark", size: 12, weight: .semibold)
				.foregroundStyle(.graphite)
				.frame(width: 44, height: 44)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(Text(String(localized: "Stop sharing \(document.name)")))
	}

	// MARK: Open on a phone

	private func phoneCard(_ session: NearbyShareSession) -> some View {
		ViewThatFits(in: .horizontal) {
			HStack(alignment: .center, spacing: 20) {
				phoneCode(session)
					.frame(width: 220)
				phoneText(session)
					.frame(minWidth: 200, idealWidth: 260, maxWidth: .infinity, alignment: .leading)
			}
			VStack(alignment: .leading, spacing: 16) {
				phoneCode(session)
					.frame(maxWidth: 260)
					.frame(maxWidth: .infinity)
				phoneText(session)
			}
		}
		.rescrivaCard(padding: 18)
		.padding(.horizontal, 16)
	}

	@ViewBuilder
	private func phoneCode(_ session: NearbyShareSession) -> some View {
		if let link = session.openLink {
			ShareQRCode(text: link.absoluteString, label: "QR code that opens these files on a phone")
		} else {
			RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous)
				.fill(Color.stock)
				.aspectRatio(1, contentMode: .fit)
				.overlay { ProgressView() }
				.accessibilityLabel(Text("Making the QR code"))
		}
	}

	private func phoneText(_ session: NearbyShareSession) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Scan with a phone's camera. It opens these files with no PIN.")
				.font(RescrivaFont.body(17))
				.lineSpacing(3)
				.foregroundStyle(.carbon)
				.fixedSize(horizontal: false, vertical: true)
			if session.relayState == .unavailable || session.relayState == .off {
				Text("The phone needs the relay to connect, and it can't be reached right now.")
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
					.fixedSize(horizontal: false, vertical: true)
			}
			if let link = session.openLink {
				Button {
					UIPasteboard.general.string = link.absoluteString
					router.showToast(String(localized: "Link copied. It opens these files with no PIN."))
				} label: {
					Label {
						Text("Copy link")
					} icon: {
						Glyph("doc.on.doc", size: 14)
					}
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.ink)
				}
				.buttonStyle(.plain)
				.accessibilityHint(Text("Anyone with the link can open these files"))
			}
		}
	}

	// MARK: Computer

	private func computerCard(_ session: NearbyShareSession) -> some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(computerHelp)
				.font(RescrivaFont.body(16))
				.lineSpacing(3)
				.foregroundStyle(.carbon)
				.fixedSize(horizontal: false, vertical: true)
			if ShareCodeScanner.isSupported {
				PrimaryButton(title: "Scan a computer's code", systemImage: "qrcode.viewfinder", height: 50) {
					scanning = true
				}
			}
			if isMac || !ShareCodeScanner.isSupported || showsPasteField {
				pasteField
			} else {
				Button("Paste a pairing link instead") {
					withAnimation(RescrivaMotion.ui) { showsPasteField = true }
				}
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(.ink)
			}
			pairingStatus(session.pairing)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.rescrivaCard(padding: 18)
		.padding(.horizontal, 16)
	}

	private var computerHelp: String {
		if isMac {
			return String(localized: "Open \(Self.siteName) in a browser. If this Mac doesn't show up there, click “Open in Rescriva” on the page, or copy its pairing link and paste it here.")
		}
		return String(localized: "Open \(Self.siteName) on the computer. If it can't find this device, scan the code the page shows.")
	}

	private var pasteField: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 8) {
				TextField("Pairing link (openscanner://share…)", text: $pastedLink)
					.font(RescrivaFont.ui(14))
					.foregroundStyle(.carbon)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.keyboardType(.URL)
					.submitLabel(.go)
					.onSubmit(connectPasted)
					.padding(.horizontal, 12)
					.frame(minHeight: 44)
					.background(Color.stock, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				PasteButton(payloadType: String.self) { strings in
					Task { @MainActor in
						guard let first = strings.first else { return }
						pastedLink = String(first.prefix(NearbySharePending.maxLinkLength + 1))
						connectPasted()
					}
				}
				.labelStyle(.iconOnly)
				.buttonBorderShape(.roundedRectangle(radius: RescrivaRadius.control))
				.tint(.ink)
			}
			HStack {
				if let pasteProblem {
					Text(pasteProblem)
						.font(RescrivaFont.ui(12))
						.foregroundStyle(.graphite)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 8)
				Button("Connect", action: connectPasted)
					.font(RescrivaFont.ui(15, weight: .medium))
					.foregroundStyle(.ink)
					.disabled(pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			}
		}
	}

	@ViewBuilder
	private func pairingStatus(_ pairing: NearbyShareSession.PairingState) -> some View {
		switch pairing {
		case .idle:
			EmptyView()
		case .connecting:
			HStack(spacing: 10) {
				ProgressView()
				Text("Connecting to the computer…")
					.font(RescrivaFont.ui(14))
					.foregroundStyle(.carbon)
			}
			.accessibilityElement(children: .combine)
		case .showCode(let code):
			VStack(alignment: .leading, spacing: 8) {
				Text("The computer hasn't answered. On the page, type this code under “Rescriva showing a code?”")
					.font(RescrivaFont.ui(14))
					.foregroundStyle(.carbon)
					.fixedSize(horizontal: false, vertical: true)
				BigCode(text: code)
					.accessibilityLabel(Text("Code \(Self.spelledOut(code))"))
					.textSelection(.enabled)
			}
		case .connected(let name):
			HStack(spacing: 10) {
				Glyph("checkmark", size: 11, weight: .bold)
					.foregroundStyle(.printInk)
					.frame(width: 22, height: 22)
					.background(Color.highlighter, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
				Text(String(localized: "Paired with \(name)"))
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.carbon)
			}
			.accessibilityElement(children: .combine)
		case .failed(let reason):
			Text(reason)
				.font(RescrivaFont.ui(13))
				.foregroundStyle(.graphite)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	// MARK: Connected

	private func devicesCard(_ session: NearbyShareSession) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			if session.devices.isEmpty {
				Text("Nothing connected yet.")
					.font(RescrivaFont.note(15))
					.foregroundStyle(.graphite)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(16)
			}
			ForEach(Array(session.devices.enumerated()), id: \.element.id) { index, device in
				if index > 0 { rule }
				deviceRow(device)
			}
		}
		.paperCard()
		.padding(.horizontal, 16)
	}

	/// A paired page says so. One that proved nothing shows the check number the page shows on
	/// this device's card, so the two can be matched before a PIN is typed on it.
	private func deviceRow(_ device: NearbyShareSession.Device) -> some View {
		HStack(alignment: .top, spacing: 12) {
			Glyph(Self.symbol(forDeviceKind: device.kind), size: 18)
				.foregroundStyle(.ink)
				.frame(width: 26)
				.padding(.top, 1)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 2) {
				Text(device.name)
					.font(RescrivaFont.ui(15, weight: .medium))
					.foregroundStyle(.carbon)
					.lineLimit(2)
				Text(device.trusted ? String(localized: "Paired") : String(localized: "PIN for each file"))
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
				if !device.trusted, let number = device.checkNumber {
					checkNumberBlock(number)
				}
			}
			Spacer(minLength: 0)
		}
		.padding(.vertical, 12)
		.padding(.horizontal, 16)
		.accessibilityElement(children: .combine)
	}

	private func checkNumberBlock(_ number: String) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(verbatim: ShareCodes.displayCheckNumber(number))
				.font(.system(.title3, design: .monospaced, weight: .semibold))
				.foregroundStyle(.carbon)
				.accessibilityLabel(Text("Check number \(Self.spelledOut(number))"))
			Text("Compare with the number on the page's card before you type a PIN there. Matching numbers mean the card and this row are the same connection.")
				.font(RescrivaFont.ui(12))
				.foregroundStyle(.graphite)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(.top, 6)
	}

	// MARK: Waiting for you

	private func incomingCard(_ offer: NearbyShareSession.IncomingOffer, session: NearbyShareSession) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			VStack(alignment: .leading, spacing: 4) {
				Text(String(localized: "\(offer.deviceName) wants to send"))
					.font(RescrivaFont.ui(13))
					.foregroundStyle(.graphite)
				Text(offer.name)
					.font(RescrivaFont.header(19))
					.foregroundStyle(.carbon)
					.lineLimit(3)
				Text(verbatim: "\(Self.kindText(offer.type)) · \(Self.byteText(offer.size))")
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
			}
			.accessibilityElement(children: .combine)
			HStack(spacing: 10) {
				Button {
					withAnimation(RescrivaMotion.ui) { session.decline(offer) }
				} label: {
					Text("Decline")
						.font(RescrivaFont.ui(15, weight: .medium))
						.foregroundStyle(.carbon)
						.frame(maxWidth: .infinity)
						.frame(minHeight: 46)
						.background(Color.stock, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
						.overlay {
							RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous)
								.strokeBorder(Color.carbon.opacity(0.14))
						}
				}
				.buttonStyle(PressScaleStyle(scale: 0.96))
				.accessibilityLabel(Text(String(localized: "Decline \(offer.name)")))
				PrimaryButton(title: "Accept", systemImage: "arrow.down", height: 46) {
					withAnimation(RescrivaMotion.ui) { session.accept(offer) }
				}
				.accessibilityLabel(Text(String(localized: "Accept \(offer.name)")))
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.rescrivaCard(padding: 16)
		.transition(.settle)
	}

	// MARK: Activity

	private func activityCard(_ session: NearbyShareSession) -> some View {
		let newestFirst = Array(session.transfers.reversed())
		return VStack(spacing: 0) {
			ForEach(Array(newestFirst.enumerated()), id: \.element.id) { index, transfer in
				if index > 0 { rule }
				transferRow(transfer)
			}
		}
		.paperCard()
		.padding(.horizontal, 16)
	}

	private func transferRow(_ transfer: NearbyShareSession.Transfer) -> some View {
		let sending = transfer.direction == .sending
		return HStack(alignment: .top, spacing: 12) {
			Glyph(sending ? "arrow.up" : "arrow.down", size: 15, weight: .semibold)
				.foregroundStyle(.ink)
				.frame(width: 26, height: 22)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 5) {
				Text(transfer.name)
					.font(RescrivaFont.ui(15, weight: .medium))
					.foregroundStyle(.carbon)
					.lineLimit(2)
				Text(sending ? String(localized: "To \(transfer.deviceName)") : String(localized: "From \(transfer.deviceName)"))
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
				if transfer.state == .moving {
					ProgressView(value: Double(max(0, min(transfer.done, transfer.total))), total: Double(max(1, transfer.total)))
						.tint(.bluePencil)
				}
				Text(Self.transferStatus(transfer))
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 0)
		}
		.padding(.vertical, 12)
		.padding(.horizontal, 16)
		.accessibilityElement(children: .combine)
	}

	// MARK: Text

	private static func byteText(_ bytes: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
	}

	/// "4 8 2 9 1 3", so VoiceOver reads a PIN or code one character at a time.
	private static func spelledOut(_ code: String) -> String {
		code.filter { $0.isLetter || $0.isNumber }.map(String.init).joined(separator: " ")
	}

	private static func kindText(_ type: String) -> String {
		if type.lowercased() == "application/pdf" { return String(localized: "PDF") }
		if type.lowercased().hasPrefix("image/") { return String(localized: "Picture") }
		return String(localized: "File")
	}

	private static func transferStatus(_ transfer: NearbyShareSession.Transfer) -> String {
		switch transfer.state {
		case .moving:
			return String(localized: "\(byteText(transfer.done)) of \(byteText(transfer.total))")
		case .done:
			return transfer.direction == .sending ? String(localized: "Sent") : String(localized: "Saved to your library")
		case .failed(let reason):
			return reason
		}
	}

	/// The page's device kinds ("computer", "phone", "tablet") and the app's own.
	private static func symbol(forDeviceKind kind: String) -> String {
		switch kind.lowercased() {
		case "phone", "iphone": return "iphone"
		case "tablet", "ipad": return "ipad"
		case "mac": return "desktopcomputer"
		default: return "laptopcomputer"
		}
	}
}

/// A PIN or connection code, large and in a fixed-width face, on the highlighter so it reads
/// across a desk.
private struct BigCode: View {
	let text: String

	var body: some View {
		Text(verbatim: text)
			.font(.system(.largeTitle, design: .monospaced, weight: .semibold))
			.foregroundStyle(.printInk)
			.lineLimit(1)
			.minimumScaleFactor(0.5)
			.padding(.vertical, 4)
			.padding(.horizontal, 12)
			.background(Color.highlighter, in: RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous))
			.contentTransition(.numericText())
	}
}

/// The session behind each Share Nearby screen, by the screen's entry on the route stack. The
/// screen's view can be rebuilt while it stays on the stack (a window crossing between its wide
/// and narrow layouts does that); the sharing, its PINs and any pairing carry on through that.
/// A session ends when its entry leaves the stack or its window closes, and then the export
/// files the screen was opened with are deleted too.
@MainActor
private enum NearbyShareSessionStore {
	private struct Entry {
		weak var router: RescrivaRouter?
		let items: [NearbyShareItem]
		let session: NearbyShareSession
	}

	private static var entries: [UUID: Entry] = [:]

	/// The session for route entry `id`, made with `make` the first time.
	static func session(for id: UUID, items: [NearbyShareItem], router: RescrivaRouter,
						make: () -> NearbyShareSession) -> NearbyShareSession {
		if let entry = entries[id] { return entry.session }
		let session = make()
		entries[id] = Entry(router: router, items: items, session: session)
		return session
	}

	/// Stops and lets go of every session whose entry left its stack, or whose window is gone.
	static func prune() {
		let gone = entries.filter { id, entry in
			guard let router = entry.router else { return true }
			return !router.stack.contains { $0.id == id }
		}
		for (id, entry) in gone {
			entries[id] = nil
			entry.session.stop()
			NearbyShareFiles.removeExports(of: entry.items)
		}
	}
}
