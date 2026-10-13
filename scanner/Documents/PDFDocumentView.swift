//
//  PDFDocumentView.swift
//  Rescriva (fork of Open Scanner)
//
//  A PDF opened from Files: read it, find in it, fill its form, mark it up and
//  organize its pages, all as a real PDF (nothing is turned into pictures).
//  Marking up keeps the header to one short row (no title on a phone), with
//  the note margin and, on an iPad, Apple Pencil's setting beside Done.
//  Changes save to Rescriva's copy in the background as you make them (a moment
//  after each edit; edits made while a save is writing go in the next one),
//  and again as you leave the PDF or the app; the imported original stays as
//  it was. The badges say what the file claims to be (PDF/A, PDF/UA…), and
//  a banner explains anything Rescriva can't do with it.
//

import PDFKit
import SwiftUI
import UIKit

struct PDFDocumentView: View {
	@Environment(RescrivaRouter.self) private var router
	@Environment(\.managedObjectContext) private var viewContext
	@Environment(\.scenePhase) private var scenePhase

	private let library = PDFLibrary.shared
	private let itemID: UUID
	private let findQuery: String?

	@State private var session: PDFEditSession?
	/// Opening happens once, in `.task`: a SwiftUI view's init runs on every redraw of its parent.
	@State private var didLoad = false
	@State private var request: PDFViewerRequest?
	/// Spreads pair pages 1–2, 3–4…; a reader can set the first page apart like a book's cover.
	@State private var coverPage = false
	@State private var dismissedBanner = false
	@State private var showsOrganizer = false
	@State private var showsInfo = false
	@State private var showsComparePicker = false
	@State private var textEntry: MarkupTextEntry?
	@State private var confirmingRevert = false
	@State private var isMakingScan = false
	@State private var password = ""
	@State private var passwordFailed = false
	@State private var isFinding = false
	/// Pages sit side by side (a wide window: iPad, the unfolded iPhone Duo).
	@State private var isSpread = false
	/// The screen's width, which decides where the title goes (`titleBesideBack`).
	@State private var screenWidth: CGFloat = 0
	@State private var findText = ""
	@FocusState private var findFocused: Bool
	/// A note-margin change that would delete marks written in the margin, awaiting a yes.
	@State private var confirmingMargin: MarginChoice?

	init(itemID: UUID, findQuery: String? = nil) {
		self.itemID = itemID
		self.findQuery = findQuery
	}

	private var item: PDFItem? { library.item(itemID) }

	/// A wide window (iPad, the unfolded iPhone Duo, a Mac) has room for the title beside the back
	/// button, which keeps the header to one row. Rescriva runs there as an iPhone app, whose size class
	/// stays compact however wide the window is, so the width decides, as it does for spreads.
	private var titleBesideBack: Bool { screenWidth >= Self.titleBesideBackWidth }

	/// Narrowest screen, in points, that puts the title beside the back button.
	private static let titleBesideBackWidth: CGFloat = 600

	/// "PDF Files" when opened from that list, else the Library's name.
	private var backTitle: LocalizedStringKey {
		router.routeBelow(.pdf(itemID, query: findQuery)) == .pdfFiles ? "PDF Files" : "Rescriva"
	}

	var body: some View {
		screen
		.task {
			guard !didLoad else { return }
			// A save of this PDF still being written (you left and came straight back) goes first.
			await library.waitForSave(of: itemID)
			session = library.item(itemID).flatMap { PDFEditSession.open($0, in: library) }
			didLoad = true
		}
		.task(id: session?.changeCount) { await autosave() }
		.fullScreenCover(isPresented: $showsOrganizer) {
			if let session {
				PDFPageOrganizer(session: session) { index in
					request = PDFViewerRequest(page: index)
				} onExtract: { data, count in
					extract(data, pageCount: count)
				}
			}
		}
		.sheet(isPresented: $showsComparePicker) {
			PDFComparePicker(current: .pdf(itemID)) { side in
				showsComparePicker = false
				compare(.pdf(itemID), with: side)
			}
			.presentationDetents([.medium, .large])
		}
		.sheet(isPresented: $showsInfo) {
			if let session, let item {
				PDFInfoSheet(item: item, session: session)
					.presentationDetents([.medium, .large])
			}
		}
		.sheet(item: $textEntry) { entry in
			MarkupTextSheet(entry: entry, isEditable: session?.canMarkUp ?? false) { text in
				finishTextEntry(entry, text: text)
			}
			.presentationDetents([.medium])
		}
		.confirmationDialog("Change the note margin?", isPresented: Binding(get: { confirmingMargin != nil }, set: { if !$0 { confirmingMargin = nil } }),
							titleVisibility: .visible, presenting: confirmingMargin) { choice in
			Button(choice.side == nil ? "Remove the margin" : "Move the margin", role: .destructive) {
				session?.setNoteMargin(choice.side)
			}
		} message: { _ in
			Text("Marks written in the margin are removed with it. You can undo this.")
		}
		.confirmationDialog("Revert to the original?", isPresented: $confirmingRevert, titleVisibility: .visible) {
			Button("Revert to original", role: .destructive) { revert() }
		} message: {
			Text("Your marks, page changes and form entries in Rescriva's copy are thrown away.")
		}
		.onChange(of: scenePhase) { _, phase in
			if phase == .background { save() }
		}
		.onDisappear { save() }
	}

	/// How soon after an edit Rescriva saves.
	static let autosaveDelay: Duration = .seconds(1)

	/// Saves as you go: a moment after each edit, so a stroke and the next one share a save. A
	/// newer edit cancels the wait and starts its own.
	private func autosave() async {
		guard session?.needsSave == true else { return }
		do {
			try await Task.sleep(for: Self.autosaveDelay)
		} catch {
			return
		}
		save()
	}

	/// The screen itself: header, banner, then the viewer (or the password card).
	private var screen: some View {
		ZStack {
			GrainBackground(base: .scanBackdrop)
			if let session, let item {
				VStack(spacing: 0) {
					topBar(session, item: item)
					if isFinding {
						findBar(session)
							.transition(.settle)
					} else if !titleBesideBack && session.mode != .markup {
						// Marking up on a phone, the page needs the room more than the title does.
						titleRow(session, item: item)
					}
					if let banner = banner(session, item: item), !dismissedBanner {
						BannerView(text: banner.text, tone: banner.tone) { withAnimation(RescrivaMotion.ui) { dismissedBanner = true } }
							.padding(.horizontal, 16)
							.padding(.bottom, 8)
							.transition(.settle)
					}
					if session.isLocked {
						passwordCard(session)
						Spacer()
					} else {
						viewer(session)
					}
				}
			} else if didLoad {
				unavailable
			} else {
				ProgressView()
					.tint(.ink)
			}
		}
		.background {
			GeometryReader { proxy in
				Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in screenWidth = width }
			}
		}
	}

	// MARK: Top

	private func topBar(_ session: PDFEditSession, item: PDFItem) -> some View {
		HStack(spacing: 8) {
			if session.mode == .markup {
				CircleIconButton(systemName: "arrow.uturn.backward", label: "Undo") { session.undo() }
					.disabled(!session.canUndo)
					.opacity(session.canUndo ? 1 : 0.4)
				CircleIconButton(systemName: "arrow.uturn.forward", label: "Redo") { session.redo() }
					.disabled(!session.canRedo)
					.opacity(session.canRedo ? 1 : 0.4)
			} else {
				BackPill(title: backTitle) { router.pop() }
			}
			if titleBesideBack {
				// The title takes what the buttons leave, and truncates; the buttons never wrap.
				titleStack(session, item: item, size: 20)
					.padding(.leading, 8)
					.frame(maxWidth: .infinity, alignment: .leading)
					.layoutPriority(-1)
			} else {
				Spacer(minLength: 4)
			}
			if session.mode == .read && !session.isLocked {
				CircleIconButton(systemName: "magnifyingglass", label: "Find in document") { startFind("") }
					.keyboardShortcut("f", modifiers: .command)
				CircleIconButton(systemName: "square.grid.2x2", label: "Pages") { showsOrganizer = true }
				moreMenu(session)
			}
			if session.mode == .markup {
				marginMenu(session)
				if PDFMarkupInput.canChoose { pencilToggle(session) }
			}
			if session.canMarkUp && !session.isLocked {
				Button {
					endFind()
					let finishing = session.mode == .markup
					withAnimation(RescrivaMotion.ui) { session.mode = finishing ? .read : .markup }
					if finishing { save() }
				} label: {
					Text(session.mode == .markup ? "Done" : "Mark up")
						.font(RescrivaFont.ui(14, weight: .medium))
						.foregroundStyle(session.mode == .markup ? Color.vellum : Color.carbon)
						.frame(height: 40)
						.padding(.horizontal, 16)
						.background(session.mode == .markup ? Color.ink : Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
						.rescrivaShadow(.small)
				}
				.buttonStyle(PressScaleStyle(scale: 0.94))
			}
		}
		.padding(.horizontal, 12)
		.padding(.top, 6)
		.padding(.bottom, 4)
	}

	/// A wide margin on every page, to write notes beside the PDF.
	private func marginMenu(_ session: PDFEditSession) -> some View {
		Menu {
			Section("A wide margin on every page, for notes") {
				Picker(selection: Binding(get: { session.currentNoteMargin }, set: { requestMargin($0, in: session) })) {
					Label("No margin", systemImage: "rectangle.portrait").tag(PDFNoteMargin?.none)
					Label("Margin on the left", systemImage: "rectangle.portrait.leftthird.inset.filled").tag(PDFNoteMargin?.some(.left))
					Label("Margin on the right", systemImage: "rectangle.portrait.rightthird.inset.filled").tag(PDFNoteMargin?.some(.right))
				} label: {
					Text("Note margin")
				}
				.pickerStyle(.inline)
			}
		} label: {
			Glyph(session.currentNoteMargin == .left ? "rectangle.portrait.leftthird.inset.filled" : "rectangle.portrait.rightthird.inset.filled", size: 17, weight: .regular)
				.foregroundStyle(session.currentNoteMargin == nil ? Color.carbon : Color.vellum)
				.frame(width: 40, height: 40)
				.background(session.currentNoteMargin == nil ? Color.vellum : Color.carbon, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.rescrivaShadow(.small)
		}
		.accessibilityLabel("Note margin")
	}

	/// Changes the margin, asking first when marks written in it would go.
	private func requestMargin(_ side: PDFNoteMargin?, in session: PDFEditSession) {
		guard side != session.currentNoteMargin else { return }
		if session.marksInNoteMargins > 0 {
			confirmingMargin = MarginChoice(side: side)
		} else {
			session.setNoteMargin(side)
		}
	}

	/// iPad: Apple Pencil marks up and fingers scroll, or fingers mark up too.
	private func pencilToggle(_ session: PDFEditSession) -> some View {
		Button {
			session.setPencilOnly(!session.pencilOnly)
			router.showToast(session.pencilOnly ? String(localized: "Apple Pencil marks up. Fingers scroll.")
								: String(localized: "Fingers mark up. Two fingers scroll."))
		} label: {
			Glyph(session.pencilOnly ? "applepencil" : "hand.draw", size: 17, weight: .regular)
				.foregroundStyle(session.pencilOnly ? Color.vellum : Color.carbon)
				.frame(width: 40, height: 40)
				.background(session.pencilOnly ? Color.carbon : Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.rescrivaShadow(.small)
		}
		.buttonStyle(PressScaleStyle())
		.accessibilityLabel(session.pencilOnly ? "Only Apple Pencil marks up" : "Fingers mark up")
	}

	private func moreMenu(_ session: PDFEditSession) -> some View {
		Menu {
			Button { share(original: false) } label: { Label("Share PDF", systemImage: "square.and.arrow.up") }
			Button { shareNearby() } label: { Label("Share Nearby", systemImage: "dot.radiowaves.left.and.right") }
			if item?.isEdited == true {
				Button { share(original: true) } label: { Label("Share the original", systemImage: "doc") }
			}
			Button { makeScanCopy() } label: {
				Label(DeviceTier.current.canRebuild ? "Rebuild into Word or Slides" : "Make a scan copy", systemImage: "doc.viewfinder")
			}
			.disabled(isMakingScan)
			Divider()
			Button { showsInfo = true } label: { Label("About this PDF", systemImage: "info.circle") }
			Button { showsComparePicker = true } label: { Label("Compare with another PDF", systemImage: "rectangle.split.2x1") }
			if item?.isEdited == true {
				Button { compare(.pdf(itemID, original: true), with: .pdf(itemID)) } label: {
					Label("Compare with the original", systemImage: "doc.on.doc")
				}
			}
			if isSpread {
				Toggle(isOn: $coverPage) { Label("First page alone in spreads", systemImage: "book") }
			}
			if item?.isEdited == true {
				Divider()
				Button(role: .destructive) { confirmingRevert = true } label: { Label("Revert to original", systemImage: "arrow.counterclockwise") }
			}
		} label: {
			Glyph("ellipsis", size: 17, weight: .regular)
				.foregroundStyle(.carbon)
				.frame(width: 40, height: 40)
				.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.rescrivaShadow(.small)
		}
		.accessibilityLabel("More")
	}

	/// The title on a row of its own, under the top bar, where the window is narrow.
	private func titleRow(_ session: PDFEditSession, item: PDFItem) -> some View {
		titleStack(session, item: item, size: 22)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 20)
			.padding(.bottom, 10)
	}

	/// The title over its pages, age and format chips.
	private func titleStack(_ session: PDFEditSession, item: PDFItem, size: CGFloat) -> some View {
		VStack(alignment: .leading, spacing: titleBesideBack ? 2 : 6) {
			Text(item.title)
				.font(RescrivaFont.header(size))
				.foregroundStyle(.carbon)
				.lineLimit(1)
				.accessibilityAddTraits(.isHeader)
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 6) {
					Text(item.libraryMeta)
						.font(RescrivaFont.ui(12))
						.foregroundStyle(.graphite)
					ForEach(badges(session, item: item), id: \.self) { badge in
						FormatBadge(text: badge)
					}
				}
			}
		}
	}

	/// What the file claims and contains, as short chips.
	private func badges(_ session: PDFEditSession, item: PDFItem) -> [String] {
		let report = session.currentReport
		var badges = report.claims.map(\.label)
		if item.isEdited {
			let kept = Set(report.claims.map(\.standard))
			badges += session.originalReport.strippableClaims.filter { !kept.contains($0.standard) }
				.map { String(localized: "Was \($0.label)") }
		}
		if report.isTagged { badges.append(String(localized: "Tagged")) }
		if let xfa = report.xfa {
			badges.append(xfa == .dynamic ? String(localized: "Dynamic XFA form") : String(localized: "XFA form"))
		} else if report.formFieldCount > 0 {
			badges.append(String(localized: "Form"))
		}
		if report.isEncrypted { badges.append(String(localized: "Password")) }
		if report.hasLayers { badges.append(String(localized: "Layers")) }
		if report.has3D { badges.append(String(localized: "3D")) }
		return badges
	}

	/// The one thing worth saying about this file, if any.
	private func banner(_ session: PDFEditSession, item: PDFItem) -> (text: String, tone: BannerView.Tone)? {
		if let reason = session.readOnlyReason { return (reason, .warning) }
		let original = session.originalReport
		switch original.xfa {
		case .hybrid where !item.isEdited:
			return (String(localized: "This form also carries XFA data. Rescriva fills its standard fields, and saving keeps a standard fillable PDF without the XFA part."), .info)
		case .staticOnly:
			return (String(localized: "This XFA form shows as a page, but its fields can only be filled in Adobe's apps."), .info)
		default:
			break
		}
		let claims = original.strippableClaims.map(\.label)
		if !claims.isEmpty && !item.isEdited {
			let list = ListFormatter.localizedString(byJoining: claims)
			return (String(localized: "This file says it's \(list). Your changes go to Rescriva's copy, which won't claim that; the original stays as it was."), .info)
		}
		if original.has3D {
			return (String(localized: "This PDF has 3D content Rescriva can't show. You'll see its still image, if it has one."), .info)
		}
		return nil
	}

	// MARK: Viewer

	private func viewer(_ session: PDFEditSession) -> some View {
		GeometryReader { proxy in
			let spread = proxy.size.width >= 700 && proxy.size.width >= proxy.size.height * 1.2
			ZStack(alignment: .bottom) {
				PDFKitView(session: session, spread: spread, coverPage: coverPage, request: request) { tool, point, page in
					textEntry = MarkupTextEntry(kind: tool == .note ? .newNote : .newTextBox, point: point, page: page, annotation: nil, text: "")
				} onOpenAnnotation: { annotation in
					textEntry = MarkupTextEntry(kind: annotation.type == "Text" ? .note : .textBox, point: .zero, page: annotation.page,
												annotation: annotation, text: annotation.contents ?? "")
				}
				.ignoresSafeArea(edges: session.mode == .markup ? [] : .bottom)
				.onChange(of: spread, initial: true) { _, wide in isSpread = wide }

				if session.mode == .markup {
					MarkupToolbar(session: session, isWide: proxy.size.width >= 600) { selection in
						textEntry = MarkupTextEntry(kind: selection.annotation.type == "Text" ? .note : .textBox, point: .zero, page: selection.page,
													annotation: selection.annotation, text: selection.annotation.contents ?? "")
					}
					.transition(.move(edge: .bottom).combined(with: .opacity))
				} else {
					PageIndicator(current: min(session.currentPageIndex + 1, session.pageCount), total: session.pageCount)
						.padding(.bottom, 14)
				}
			}
		}
		.task {
			if let findQuery, !findQuery.isEmpty, !session.isLocked { startFind(findQuery) }
		}
	}

	// MARK: Find

	private func findBar(_ session: PDFEditSession) -> some View {
		HStack(spacing: 8) {
			HStack(spacing: 8) {
				Glyph("magnifyingglass", size: 15)
					.foregroundStyle(.graphite)
				TextField("Find in this PDF", text: $findText)
					.font(RescrivaFont.ui(15))
					.foregroundStyle(.carbon)
					.submitLabel(.search)
					.autocorrectionDisabled()
					.textInputAutocapitalization(.never)
					.focused($findFocused)
					.onSubmit { session.showNextResult() }
				Text(findStatus(session))
					.font(RescrivaFont.ui(12, weight: .medium))
					.foregroundStyle(.graphite)
					.monospacedDigit()
					.fixedSize()
			}
			.padding(.horizontal, 12)
			.frame(height: 40)
			.background(Color.vellum, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.carbon.opacity(0.08)) }
			findStep("chevron.up", label: "Previous match") { session.showPreviousResult() }
			findStep("chevron.down", label: "Next match") { session.showNextResult() }
			Button("Done") { endFind() }
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(.ink)
		}
		.padding(.horizontal, 16)
		.padding(.bottom, 10)
		.task(id: findText) {
			// Search as you type, once typing pauses (a new keystroke cancels the wait).
			do {
				try await Task.sleep(for: .milliseconds(250))
			} catch {
				return
			}
			session.find(findText)
		}
	}

	private func findStep(_ systemName: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
		let enabled = !(session?.findResults.isEmpty ?? true)
		return Button(action: action) {
			Glyph(systemName, size: 15, weight: .medium)
				.foregroundStyle(.carbon)
				.frame(width: 34, height: 40)
				.contentShape(Rectangle())
		}
		.buttonStyle(PressScaleStyle())
		.disabled(!enabled)
		.opacity(enabled ? 1 : 0.35)
		.accessibilityLabel(Text(label))
	}

	/// "3 of 12", "Searching…", "No matches".
	private func findStatus(_ session: PDFEditSession) -> String {
		let count = session.findResults.count
		if findText.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
		if count == 0 { return session.isFinding ? String(localized: "Searching…") : String(localized: "No matches") }
		let position = (session.findIndex ?? 0) + 1
		return session.isFinding ? String(localized: "\(position) of \(count)+") : String(localized: "\(position) of \(count)")
	}

	private func startFind(_ query: String) {
		findText = query
		withAnimation(RescrivaMotion.ui) { isFinding = true }
		findFocused = query.isEmpty
	}

	private func endFind() {
		session?.endFind()
		findFocused = false
		withAnimation(RescrivaMotion.ui) { isFinding = false }
	}

	private func passwordCard(_ session: PDFEditSession) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("This PDF is locked")
				.font(RescrivaFont.header(20))
				.foregroundStyle(.carbon)
			Text("Enter its password to open it. Rescriva keeps the password on the file when it saves.")
				.font(RescrivaFont.ui(14))
				.foregroundStyle(.graphite)
			SecureField("Password", text: $password)
				.font(RescrivaFont.ui(16))
				.textContentType(.password)
				.submitLabel(.go)
				.padding(.horizontal, 14)
				.frame(height: 44)
				.background(Color.stock, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
				.onSubmit { unlock(session) }
			if passwordFailed {
				Text("That password didn't work.")
					.font(RescrivaFont.ui(13))
					.foregroundStyle(.vermilion)
			}
			PrimaryButton(title: "Unlock", systemImage: "lock.open", height: 48) { unlock(session) }
		}
		.rescrivaCard(padding: 18)
		.padding(.horizontal, 20)
		.padding(.top, 20)
	}

	private var unavailable: some View {
		VStack(spacing: 16) {
			HStack {
				BackPill(title: backTitle) { router.pop() }
				Spacer()
			}
			.padding(.horizontal, 12)
			.padding(.top, 6)
			Spacer()
			Text("This PDF couldn't be opened. It may be damaged, or it was removed.")
				.font(RescrivaFont.note(16))
				.foregroundStyle(.graphite)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 40)
			Spacer()
		}
	}

	// MARK: Actions

	private func unlock(_ session: PDFEditSession) {
		if session.unlock(with: password) {
			passwordFailed = false
			password = ""
		} else {
			passwordFailed = true
		}
	}

	/// Saves in the background, holding on to time from iOS so a save started as you leave the
	/// app still finishes. Safe to call often: it does nothing when there's nothing to save.
	private func save() {
		guard let session, session.needsSave || session.isSaving else { return }
		BackgroundTime.protect("Save PDF") {
			await saved(session)
		}
	}

	/// Saves now and returns once the file on disk is up to date.
	private func saved(_ session: PDFEditSession) async {
		do {
			try await session.save(in: library)
		} catch {
			router.showToast(error.localizedDescription)
		}
	}

	/// Saves this PDF's changes, so the comparison sees them, then shows the two side by side.
	private func compare(_ left: PDFCompareSide, with right: PDFCompareSide) {
		endFind()
		Task {
			if let session { await saved(session) }
			router.push(.pdfCompare(left, right))
		}
	}

	private func finishTextEntry(_ entry: MarkupTextEntry, text: String) {
		guard let session else { return }
		if let annotation = entry.annotation {
			session.setContents(of: annotation, to: text)
			return
		}
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, let page = entry.page else { return }
		let color = session.currentColor
		switch entry.kind {
		case .newNote:
			session.add([PDFMarkupFactory.note(at: entry.point, text: trimmed, color: color)], on: page)
		case .newTextBox:
			session.add([PDFMarkupFactory.textBox(at: entry.point, text: trimmed, color: color, fontSize: session.currentSize,
												  pageBounds: page.bounds(for: .cropBox))], on: page)
		case .note, .textBox:
			break
		}
	}

	private func share(original: Bool) {
		Task {
			if let session { await saved(session) }
			shareFile(original: original)
		}
	}

	/// Saves any changes, then opens Share Nearby with this PDF's current version.
	private func shareNearby() {
		Task {
			if let session { await saved(session) }
			router.push(.shareNearby([.pdf(itemID)]))
		}
	}

	private func shareFile(original: Bool) {
		guard let item else { return }
		let source = original ? library.originalURL(for: item) : library.currentURL(for: item)
		let name = (item.title.isEmpty ? "Document" : item.title) + (original ? String(localized: " (original)") : "") + ".pdf"
		let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
		do {
			if FileManager.default.fileExists(atPath: destination.path) {
				try FileManager.default.removeItem(at: destination)
			}
			try FileManager.default.copyItem(at: source, to: destination)
			SharePresenter.share([destination])
		} catch {
			router.showToast(String(localized: "Rescriva couldn't prepare the PDF to share."))
		}
	}

	private func revert() {
		guard let item else { return }
		Task {
			do {
				try await library.revertToOriginal(item)
				session = library.item(item.id).flatMap { PDFEditSession.open($0, in: library) }
				dismissedBanner = false
				router.showToast(String(localized: "Back to the original"))
			} catch {
				router.showToast(error.localizedDescription)
			}
		}
	}

	private func extract(_ data: Data, pageCount: Int) {
		guard let item else { return }
		do {
			let extracted = try library.add(data, title: String(localized: "\(item.title) (pages)"))
			let message = pageCount == 1 ? String(localized: "Saved 1 page as a new PDF") : String(localized: "Saved \(pageCount) pages as a new PDF")
			router.showToast(message, style: .exported, actionLabel: String(localized: "Open")) {
				router.push(.pdf(extracted.id, query: nil))
			}
		} catch {
			router.showToast(error.localizedDescription)
		}
	}

	private func makeScanCopy() {
		guard let item, !isMakingScan else { return }
		isMakingScan = true
		router.showToast(String(localized: "Making a scan copy…"))
		let password = session?.unlockPassword
		Task {
			if let session { await saved(session) }
			let source = library.currentURL(for: item)
			// The same path as PR #1's import: pages drawn one at a time, the PDF kept as the scan's original.
			let images = await PDFImport.pages(of: source, password: password) { _, _ in }
			let staged = images.isEmpty ? nil : await PDFImport.stageOriginal(source)
			isMakingScan = false
			guard !images.isEmpty else {
				router.showToast(String(localized: "Rescriva couldn't make a scan copy of this PDF."))
				return
			}
			let output: OutputKind = DeviceTier.current.canRebuild ? .docx : .pdf
			let scan = Scan.create(from: images, title: item.title, source: .typed, in: viewContext, output: output, suggestsTitle: false)
			if let staged, let id = scan.id {
				PDFImport.keepOriginal(staged, named: item.sourceName, for: id)
			}
			router.push(.scan(scan))
		}
	}
}

// MARK: - Pieces

/// A note-margin side waiting on the reader's yes (nil takes the margin away).
struct MarginChoice: Identifiable {
	let id = UUID()
	let side: PDFNoteMargin?
}

/// A note or text box being written or edited.
struct MarkupTextEntry: Identifiable {
	enum Kind { case newNote, newTextBox, note, textBox }

	let id = UUID()
	let kind: Kind
	/// Where a new one goes, in page space.
	let point: CGPoint
	let page: PDFPage?
	/// The existing one being edited.
	let annotation: PDFAnnotation?
	let text: String

	var title: LocalizedStringKey {
		switch kind {
		case .newNote: return "New note"
		case .newTextBox: return "New text box"
		case .note: return "Note"
		case .textBox: return "Text box"
		}
	}
}

/// Writes or edits a note's or text box's text.
private struct MarkupTextSheet: View {
	@Environment(\.dismiss) private var dismiss
	let entry: MarkupTextEntry
	let isEditable: Bool
	let onDone: (String) -> Void
	@State private var text: String
	@FocusState private var focused: Bool

	init(entry: MarkupTextEntry, isEditable: Bool, onDone: @escaping (String) -> Void) {
		self.entry = entry
		self.isEditable = isEditable
		self.onDone = onDone
		_text = State(initialValue: entry.text)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack {
				Text(entry.title)
					.font(RescrivaFont.header(22))
					.foregroundStyle(.carbon)
				Spacer()
				Button(isEditable ? "Done" : "Close") {
					if isEditable { onDone(text) }
					dismiss()
				}
				.font(RescrivaFont.ui(15, weight: .medium))
				.foregroundStyle(.ink)
			}
			if isEditable {
				TextEditor(text: $text)
					.font(RescrivaFont.ui(16))
					.scrollContentBackground(.hidden)
					.padding(10)
					.background(Color.stock, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
					.focused($focused)
				if entry.annotation != nil {
					Text("Clear the text to delete it.")
						.font(RescrivaFont.ui(12))
						.foregroundStyle(.graphite)
				}
			} else {
				ScrollView {
					Text(text)
						.font(RescrivaFont.ui(16))
						.foregroundStyle(.carbon)
						.frame(maxWidth: .infinity, alignment: .leading)
						.textSelection(.enabled)
				}
			}
		}
		.padding(20)
		.background(Color.stock)
		.onAppear { focused = isEditable }
	}
}

/// "3 of 12" over the page.
private struct PageIndicator: View {
	let current: Int
	let total: Int

	var body: some View {
		Text("\(current) of \(total)")
			.font(RescrivaFont.ui(13, weight: .medium))
			.foregroundStyle(.carbon)
			.monospacedDigit()
			.padding(.vertical, 7)
			.padding(.horizontal, 14)
			.background(Color.vellum.opacity(0.94), in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
			.rescrivaShadow(.small)
			.accessibilityLabel(Text("Page \(current) of \(total)"))
	}
}

/// A short chip naming a standard or feature: "PDF/A-2b", "Tagged".
struct FormatBadge: View {
	let text: String

	var body: some View {
		Text(text)
			.font(RescrivaFont.ui(11, weight: .medium))
			.foregroundStyle(.carbon)
			.padding(.vertical, 4)
			.padding(.horizontal, 9)
			.background(Color.wash.opacity(0.7), in: RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous))
	}
}
