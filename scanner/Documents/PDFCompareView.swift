//
//  PDFCompareView.swift
//  Rescriva (fork of Open Scanner)
//
//  Two PDFs side by side. When they're versions of one document (`PDFCompare`), each change is
//  marked the way the Compare Doc design shows it: a few words read differently in highlighter on
//  both sides, added words in wash on the right, removed words struck out on the left, and the
//  change you're on ringed in ink. A wide screen (iPad in landscape, Mac) lists the changes beside
//  the two; an iPad in portrait puts the two one above the other under a strip of the changes; a
//  half-and-half screen (the unfolded Duo) or a phone steps through them from a bar below.
//  Rescriva runs on iPad and Mac as an iPhone app, which gets one window, so the two share a screen.
//

import CoreData
import PDFKit
import SwiftUI

/// One side of a comparison.
enum PDFCompareSide: Hashable {
	/// A PDF in the Library, as it is now or (`original`) as it was imported, before Rescriva's edits.
	case pdf(UUID, original: Bool = false)
	/// A scan, compared as the searchable PDF it exports.
	case scan(Scan)
}

struct PDFCompareView: View {
	@Environment(RescrivaRouter.self) private var router
	let left: PDFCompareSide
	let right: PDFCompareSide

	private let library = PDFLibrary.shared

	@State private var leftDocument: PDFDocument?
	@State private var rightDocument: PDFDocument?
	/// The files compared, kept for comparing again.
	@State private var urls: (left: URL, right: URL)?
	@State private var comparison: PDFComparison?
	/// Opening happens once, in `.task`.
	@State private var didLoad = false
	/// Differences between two documents that aren't versions of one, asked for anyway.
	@State private var comparesAnyway = false
	@State private var showsDifferences = true
	@State private var marks: [ChangeMarks] = []
	@State private var current: Int?
	/// Bumped whenever what the panes draw changes, so they hand it to PDFKit only then.
	@State private var marksVersion = 0
	/// Bumped to send both panes to the current change.
	@State private var focusToken = 0

	/// How the screen is laid out, from its size.
	enum Layout {
		/// The two side by side and the list of changes beside them (iPad in landscape, Mac).
		case panel
		/// The two one above the other, at full width, under a strip of the changes (iPad in portrait).
		case portrait
		/// One per half, stepping through changes from a bar below (the unfolded Duo).
		case halves
		/// One above the other, with the bar below (a phone).
		case stacked

		init(_ size: CGSize) {
			if size.width < Self.sideBySideWidth {
				self = .stacked
			} else if size.width >= Self.panelWidth, size.width >= size.height {
				self = .panel
			} else {
				self = size.height >= Self.portraitHeight ? .portrait : .halves
			}
		}

		/// Narrowest screen, in points, that puts the two side by side.
		static let sideBySideWidth: CGFloat = 700
		/// Narrowest screen with room for the list of changes beside the two.
		static let panelWidth: CGFloat = 1_000
		/// Shortest screen with room for the two one above the other under the strip of changes.
		static let portraitHeight: CGFloat = 900
	}

	/// One change: how it's described, its marks on each side, and where each side shows it (for
	/// an addition, the word on the left it would go before).
	struct ChangeMarks {
		var kind: PDFCompare.Kind
		var page: Int
		var summary: String
		/// A few words of it, for its chip.
		var short: String
		var left: [PDFSelection]
		var right: [PDFSelection]
		var leftFocus: PDFSelection?
		var rightFocus: PDFSelection?
	}

	var body: some View {
		GeometryReader { proxy in
			let layout = Layout(proxy.size)
			ZStack {
				GrainBackground(base: .scanBackdrop)
				VStack(spacing: 0) {
					header(layout)
					content(layout)
				}
			}
		}
		.task { await load() }
	}

	// MARK: Header

	private func header(_ layout: Layout) -> some View {
		HStack(spacing: 12) {
			BackPill(title: backTitle) { router.pop() }
			Text(title)
				.font(RescrivaFont.header(layout == .stacked ? 20 : 24))
				.foregroundStyle(.carbon)
				.lineLimit(1)
				.frame(maxWidth: .infinity, alignment: .leading)
				.layoutPriority(-1)
			if layout == .panel || layout == .halves, showsDifferences, !marks.isEmpty {
				legend
			}
			if layout == .portrait, !marks.isEmpty {
				ShareLink(item: report) {
					Text("Export report")
						.font(RescrivaFont.ui(14, weight: .medium))
						.foregroundStyle(.carbon)
						.padding(.horizontal, 14)
						.frame(height: 36)
						.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
						.rescrivaShadow(.small)
				}
			}
			menu
		}
		.padding(.horizontal, layout == .panel ? 28 : 16)
		.padding(.top, 8)
		.padding(.bottom, 12)
	}

	/// Where Back goes: the scan or the PDF this comparison was opened from.
	private var backTitle: LocalizedStringKey {
		if case .scan = left { return "Scans" }
		return "PDF"
	}

	/// What each colour means.
	private var legend: some View {
		HStack(spacing: 16) {
			ForEach(CompareStyle.legend, id: \.label) { entry in
				HStack(spacing: 6) {
					RoundedRectangle(cornerRadius: 4).fill(entry.color).frame(width: 14, height: 14)
					Text(entry.label).font(RescrivaFont.ui(13)).foregroundStyle(.carbon)
				}
			}
		}
	}

	/// The changes as text to share: what was compared, then each change.
	private var report: String {
		var lines = [String(localized: "Compared \(caption(for: left)) with \(caption(for: right))"), status.title, ""]
		for (index, change) in marks.enumerated() {
			lines.append("\(index + 1). \(CompareStyle.label(change.kind)), p. \(change.page): \(change.summary)")
		}
		return lines.joined(separator: "\n")
	}

	/// The document's title, or both titles when they're two documents.
	private var title: String {
		let names = [left, right].map(title(of:))
		return isOneDocument || names[0] == names[1] ? names[0] : "\(names[0]) ↔ \(names[1])"
	}

	/// Both sides are one PDF in the Library: as imported and as edited.
	private var isOneDocument: Bool {
		guard case .pdf(let leftID, _) = left, case .pdf(let rightID, _) = right else { return false }
		return leftID == rightID
	}

	private func title(of side: PDFCompareSide) -> String {
		switch side {
		case .pdf(let id, _): return library.item(id)?.title ?? ""
		case .scan(let scan): return scan.displayTitle
		}
	}

	private var menu: some View {
		Menu {
			if comparison?.hasText == true {
				Toggle(isOn: Binding(get: { showsDifferences }, set: { show in
					showsDifferences = show
					marksVersion += 1
				})) { Label("Mark differences", systemImage: "highlighter") }
			}
			if !marks.isEmpty {
				ShareLink(item: report) { Label("Export report", systemImage: "square.and.arrow.up") }
			}
			Button { router.replaceTop(with: .pdfCompare(right, left)) } label: { Label("Swap sides", systemImage: "arrow.left.arrow.right") }
		} label: {
			Glyph("ellipsis", size: 17, weight: .regular)
				.foregroundStyle(.carbon)
				.frame(width: 40, height: 40)
				.background(Color.vellum, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				.rescrivaShadow(.small)
		}
		.accessibilityLabel("More")
	}

	// MARK: Layouts

	@ViewBuilder
	private func content(_ layout: Layout) -> some View {
		if let leftDocument, let rightDocument {
			switch layout {
			case .panel:
				HStack(spacing: 20) {
					HStack(spacing: 20) {
						pane(left, document: leftDocument, isLeft: true)
						pane(right, document: rightDocument, isLeft: false)
					}
					changesPanel
						.frame(width: 280)
				}
				.padding(EdgeInsets(top: 0, leading: 28, bottom: 20, trailing: 20))
			case .portrait:
				VStack(spacing: 14) {
					changeStrip
					pane(left, document: leftDocument, isLeft: true)
					pane(right, document: rightDocument, isLeft: false)
				}
				.padding(EdgeInsets(top: 0, leading: 24, bottom: 20, trailing: 24))
			case .halves, .stacked:
				let split = layout == .halves ? AnyLayout(HStackLayout(spacing: 24)) : AnyLayout(VStackLayout(spacing: 12))
				ZStack(alignment: .bottom) {
					split {
						pane(left, document: leftDocument, isLeft: true)
						pane(right, document: rightDocument, isLeft: false)
					}
					.padding(.horizontal, 16)
					.padding(.bottom, 104)
					changeBar
						.padding(16)
				}
			}
		} else if didLoad {
			Text("One of these PDFs couldn't be opened. It may be damaged, or it was removed.")
				.font(RescrivaFont.note(16))
				.foregroundStyle(.graphite)
				.multilineTextAlignment(.center)
				.padding(40)
				.frame(maxHeight: .infinity)
		} else {
			ProgressView()
				.tint(.ink)
				.frame(maxHeight: .infinity)
		}
	}

	private func pane(_ side: PDFCompareSide, document: PDFDocument, isLeft: Bool) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(caption(side, document: document))
				.font(RescrivaFont.ui(12, weight: .medium))
				.foregroundStyle(.graphite)
				.lineLimit(1)
				.padding(.leading, 4)
			if document.isLocked {
				Text("This PDF is locked. Open it on its own to unlock it.")
					.font(RescrivaFont.ui(14))
					.foregroundStyle(.graphite)
					.multilineTextAlignment(.center)
					.padding(24)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				let change = current.flatMap { marks[safe: $0] }
				PDFComparePane(document: document, fills: fills(isLeft: isLeft),
							   strikes: isLeft && showsDifferences ? strikes : [],
							   outline: showsDifferences ? (isLeft ? change?.left : change?.right) ?? [] : [],
							   version: marksVersion, focus: isLeft ? change?.leftFocus : change?.rightFocus, focusToken: focusToken) { page, point in
					pick(at: point, on: page, isLeft: isLeft)
				}
				.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
				.rescrivaShadow(.small)
			}
		}
	}

	/// "Field Guide · Original · 6 pages".
	private func caption(_ side: PDFCompareSide, document: PDFDocument) -> String {
		let pages = document.pageCount == 1 ? String(localized: "1 page") : String(localized: "\(document.pageCount) pages")
		return [caption(for: side), pages].joined(separator: " · ")
	}

	/// "Field Guide", or "Field Guide · Original" when both sides are one PDF.
	private func caption(for side: PDFCompareSide) -> String {
		let title = title(of: side)
		guard isOneDocument, case .pdf(_, let original) = side else { return title }
		return "\(title) · " + (original ? String(localized: "Original") : String(localized: "Edited in Rescriva"))
	}

	// MARK: Changes

	/// The list of changes beside the two PDFs, with Previous and Next below it.
	private var changesPanel: some View {
		VStack(alignment: .leading, spacing: 8) {
			if let comparison, comparison.hasText, comparison.isSameDocument || comparesAnyway, !marks.isEmpty {
				HStack(alignment: .firstTextBaseline) {
					Text("\(marks.count) changes").font(RescrivaFont.header(20)).foregroundStyle(.carbon)
					Spacer()
					Text(position).font(RescrivaFont.ui(12)).foregroundStyle(.graphite)
				}
				.padding(.horizontal, 4)
				ScrollViewReader { reader in
					ScrollView {
						LazyVStack(spacing: 4) {
							ForEach(marks.indices, id: \.self) { index in
								changeRow(index).id(index)
							}
						}
						.padding(2)
					}
					.onChange(of: current) { _, index in
						guard let index else { return }
						withAnimation(RescrivaMotion.ui) { reader.scrollTo(index, anchor: .center) }
					}
				}
				HStack(spacing: 8) {
					stepButton("Previous", filled: false) { step(by: -1) }
					stepButton("Next", filled: true) { step(by: 1) }
				}
			} else {
				statusCard
				Spacer()
			}
		}
		.padding(16)
		.frame(maxHeight: .infinity, alignment: .top)
		.background(Color.vellum, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
		.rescrivaShadow(.small)
	}

	private func changeRow(_ index: Int) -> some View {
		let change = marks[index]
		let isCurrent = index == current
		return Button { show(index) } label: {
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 8) {
					RoundedRectangle(cornerRadius: 3).fill(CompareStyle.dot(change.kind)).frame(width: 10, height: 10)
					Text(CompareStyle.label(change.kind)).font(RescrivaFont.ui(14, weight: .medium)).foregroundStyle(.carbon)
					Spacer(minLength: 4)
					Text("p. \(change.page)").font(RescrivaFont.ui(11)).foregroundStyle(.graphite)
				}
				Text(change.summary)
					.font(RescrivaFont.note(14))
					.foregroundStyle(Color.carbon.opacity(0.8))
					.lineLimit(2)
					.multilineTextAlignment(.leading)
			}
			.padding(.vertical, 10)
			.padding(.horizontal, 12)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(isCurrent ? Color.wash.opacity(0.55) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			.overlay {
				if isCurrent { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.ink, lineWidth: 1.5) }
			}
		}
		.buttonStyle(.plain)
	}

	private func stepButton(_ title: LocalizedStringKey, filled: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Text(title)
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(filled ? Color.vellum : Color.carbon)
				.frame(maxWidth: .infinity)
				.frame(height: 42)
				.background(filled ? Color.ink : Color.stock, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		}
		.buttonStyle(PressScaleStyle(scale: 0.94))
	}

	/// The changes in a strip above the two: how many and what the colours mean, a chip for each,
	/// and the one you're on between the arrows.
	private var changeStrip: some View {
		VStack(alignment: .leading, spacing: 12) {
			if !marks.isEmpty, showsDifferences {
				HStack(alignment: .firstTextBaseline, spacing: 16) {
					Text("\(marks.count) changes").font(RescrivaFont.header(20)).foregroundStyle(.carbon)
					legend
					Spacer()
					Text(position).font(RescrivaFont.ui(12)).foregroundStyle(.graphite)
				}
				changeChips
				currentChange(summarySize: 17)
			} else {
				statusCard
			}
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.vellum, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
		.rescrivaShadow(.small)
	}

	/// A chip for each change, in a row that scrolls to keep the current one in view.
	private var changeChips: some View {
		ScrollViewReader { reader in
			ScrollView(.horizontal, showsIndicators: false) {
				LazyHStack(spacing: 8) {
					ForEach(marks.indices, id: \.self) { index in
						let change = marks[index]
						Button { show(index) } label: {
							HStack(spacing: 8) {
								RoundedRectangle(cornerRadius: 3).fill(CompareStyle.dot(change.kind)).frame(width: 10, height: 10)
								Text(change.short).font(RescrivaFont.ui(13, weight: .medium)).foregroundStyle(.carbon).lineLimit(1)
							}
							.padding(.vertical, 8)
							.padding(.horizontal, 12)
							.background(index == current ? Color.wash.opacity(0.55) : Color.stock, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
							.overlay {
								if index == current { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.ink, lineWidth: 1.5) }
							}
						}
						.buttonStyle(PressScaleStyle(scale: 0.94))
						.id(index)
					}
				}
				.padding(2)
			}
			.onChange(of: current) { _, index in
				guard let index else { return }
				withAnimation(RescrivaMotion.ui) { reader.scrollTo(index, anchor: .center) }
			}
		}
		.frame(height: 40)
	}

	/// The change you're on between the arrows: where it is and what it is.
	private func currentChange(summarySize: CGFloat) -> some View {
		HStack(spacing: 14) {
			roundStep("chevron.left", label: "Previous change", filled: false) { step(by: -1) }
			VStack(alignment: .leading, spacing: 2) {
				if let index = current, let change = marks[safe: index] {
					Text("p. \(change.page) · \(CompareStyle.label(change.kind))").font(RescrivaFont.ui(12, weight: .medium)).foregroundStyle(.graphite)
					Text(change.summary).font(RescrivaFont.note(summarySize)).foregroundStyle(.carbon).lineLimit(2)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			roundStep("chevron.right", label: "Next change", filled: true) { step(by: 1) }
		}
	}

	/// The change you're on, with the arrows either side, floating below the two PDFs.
	private var changeBar: some View {
		HStack(spacing: 14) {
			if !marks.isEmpty {
				roundStep("chevron.left", label: "Previous change", filled: false) { step(by: -1) }
			}
			if let index = current, let change = marks[safe: index], showsDifferences {
				VStack(alignment: .leading, spacing: 2) {
					HStack(spacing: 8) {
						RoundedRectangle(cornerRadius: 3).fill(CompareStyle.dot(change.kind)).frame(width: 10, height: 10)
						Text(CompareStyle.label(change.kind)).font(RescrivaFont.ui(15, weight: .medium)).foregroundStyle(.carbon)
						Text("p. \(change.page) · \(position)").font(RescrivaFont.ui(12)).foregroundStyle(.graphite)
					}
					Text(change.summary).font(RescrivaFont.note(15)).foregroundStyle(.carbon).lineLimit(1)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			} else {
				statusCard
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			if !marks.isEmpty {
				roundStep("chevron.right", label: "Next change", filled: true) { step(by: 1) }
			}
		}
		.padding(.vertical, 14)
		.padding(.horizontal, 16)
		.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
		.background(Color.vellum.opacity(0.6), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
		.rescrivaShadow(.small)
	}

	private func roundStep(_ systemName: String, label: LocalizedStringKey, filled: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Glyph(systemName, size: 18, weight: .regular)
				.foregroundStyle(filled ? Color.vellum : Color.carbon)
				.frame(width: 44, height: 44)
				.background(filled ? Color.ink : Color.stock, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
		}
		.buttonStyle(PressScaleStyle(scale: 0.92))
		.accessibilityLabel(Text(label))
	}

	/// What the comparison found when there's no list of changes to show.
	@ViewBuilder
	private var statusCard: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(status.title).font(RescrivaFont.header(18)).foregroundStyle(.carbon)
			if let detail = status.detail {
				Text(detail).font(RescrivaFont.ui(13)).foregroundStyle(.graphite).fixedSize(horizontal: false, vertical: true)
			}
			if let comparison, comparison.hasText, !comparison.isSameDocument, !comparesAnyway {
				Button { Task { await compareAnyway() } } label: {
					Text("Compare anyway")
						.font(RescrivaFont.ui(14, weight: .medium))
						.foregroundStyle(.carbon)
						.padding(.horizontal, 14)
						.frame(height: 36)
						.background(Color.stock, in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
				}
				.buttonStyle(PressScaleStyle(scale: 0.94))
				.padding(.top, 4)
			}
		}
	}

	private var status: (title: String, detail: String?) {
		guard let comparison else { return (String(localized: "Comparing…"), nil) }
		guard comparison.hasText else {
			return (String(localized: "No text to compare"), String(localized: "One of these PDFs has no text layer. A scan needs its text recognized first."))
		}
		guard comparison.isSameDocument || comparesAnyway else {
			return (String(localized: "Different documents"), String(localized: "These don't look like versions of one document, so their differences aren't marked."))
		}
		guard !marks.isEmpty else { return (String(localized: "No differences"), String(localized: "The text of both PDFs is the same.")) }
		return (String(localized: "\(marks.count) changes"), nil)
	}

	/// "2 of 5".
	private var position: String {
		guard let current else { return "" }
		return String(localized: "\(current + 1) of \(marks.count)")
	}

	// MARK: Marks

	/// Every change's fill on one side, coloured by kind.
	private func fills(isLeft: Bool) -> [PDFSelection] {
		guard showsDifferences else { return [] }
		return marks.flatMap { isLeft ? $0.left : $0.right }
	}

	/// The removed words struck out on the left.
	private var strikes: [PDFSelection] {
		marks.filter { $0.kind == .removed || $0.kind == .rewritten }.flatMap(\.left)
	}

	/// The change under a tap on a pane, if any, becomes the current one.
	private func pick(at point: CGPoint, on page: PDFPage, isLeft: Bool) {
		guard showsDifferences else { return }
		let index = marks.firstIndex { change in
			(isLeft ? change.left : change.right).contains { selection in
				selection.selectionsByLine().contains { $0.pages.contains(page) && $0.bounds(for: page).insetBy(dx: -2, dy: -2).contains(point) }
			}
		}
		if let index { show(index) }
	}

	// MARK: Comparing

	private func load() async {
		guard !didLoad else { return }
		defer { didLoad = true }
		guard let leftURL = await url(for: left), let rightURL = await url(for: right),
			  let leftDocument = PDFDocument(url: leftURL), let rightDocument = PDFDocument(url: rightURL) else { return }
		urls = (leftURL, rightURL)
		self.leftDocument = leftDocument
		self.rightDocument = rightDocument
		didLoad = true
		await compare(leftURL, rightURL, always: false)
	}

	private func compareAnyway() async {
		guard let urls else { return }
		comparesAnyway = true
		await compare(urls.left, urls.right, always: true)
	}

	/// Reads both PDFs' text and compares it off the main thread, then marks the changes.
	private func compare(_ leftURL: URL, _ rightURL: URL, always: Bool) async {
		let result = await Task.detached(priority: .userInitiated) {
			PDFCompare.compare(left: PDFCompare.pageTexts(at: leftURL), right: PDFCompare.pageTexts(at: rightURL), always: always)
		}.value
		comparison = result
		marks = Self.marks(for: result, left: leftDocument, right: rightDocument)
		current = nil
		marksVersion += 1
		if !marks.isEmpty { show(0) }
	}

	/// Longest chip text, in characters.
	private static let chipLength = 22

	/// Each change, described and as selections on both PDFs.
	private static func marks(for comparison: PDFComparison, left: PDFDocument?, right: PDFDocument?) -> [ChangeMarks] {
		guard let left, let right else { return [] }
		return comparison.changes.map { change in
			let kind = PDFCompare.kind(of: change)
			let removed = selections(PDFCompare.spans(of: change.removed, in: comparison.left), in: left, color: CompareStyle.fill(kind, isLeft: true))
			let added = selections(PDFCompare.spans(of: change.added, in: comparison.right), in: right, color: CompareStyle.fill(kind, isLeft: false))
			let short = change.added.isEmpty ? PDFCompare.excerpt(change.removed, in: comparison.left, limit: chipLength)
				: PDFCompare.excerpt(change.added, in: comparison.right, limit: chipLength)
			return ChangeMarks(kind: kind, page: PDFCompare.page(of: change, left: comparison.left, right: comparison.right),
							   summary: PDFCompare.summary(of: change, left: comparison.left, right: comparison.right), short: short,
							   left: change.removed.isEmpty ? [] : removed, right: change.added.isEmpty ? [] : added,
							   leftFocus: removed.first, rightFocus: added.first)
		}
	}

	private static func selections(_ spans: [(page: Int, range: NSRange)], in document: PDFDocument, color: UIColor) -> [PDFSelection] {
		spans.compactMap { span in
			guard let selection = document.page(at: span.page)?.selection(for: span.range) else { return nil }
			selection.color = color
			return selection
		}
	}

	/// Moves to the next (`1`) or previous (`-1`) change, wrapping around.
	private func step(by offset: Int) {
		guard !marks.isEmpty else { return }
		show(current.map { ($0 + offset + marks.count) % marks.count } ?? 0)
	}

	/// Makes change `index` the current one and shows it on both sides.
	private func show(_ index: Int) {
		guard marks.indices.contains(index) else { return }
		current = index
		marksVersion += 1
		focusToken += 1
	}

	/// The file a side shows: a PDF as imported or as Rescriva's copy, or a scan written out as a
	/// searchable PDF.
	private func url(for side: PDFCompareSide) async -> URL? {
		switch side {
		case .pdf(let id, let original):
			guard let item = library.item(id) else { return nil }
			return original ? library.originalURL(for: item) : library.currentURL(for: item)
		case .scan(let scan):
			return try? await ExportService.makeFile(for: scan, format: .pdf, includeNotes: false)
		}
	}
}

/// The Compare Doc design's colours and names for each kind of change. The fills are marks on the
/// page, so they're drawn in their paper colours whatever the screen's appearance.
enum CompareStyle {
	static let highlighter = RescrivaPalette.highlighter.onPaper
	static let bluePencil = RescrivaPalette.bluePencil.onPaper
	static let vermilion = RescrivaPalette.vermilion.onPaper

	/// The fill behind a change's words on one side.
	static func fill(_ kind: PDFCompare.Kind, isLeft: Bool) -> UIColor {
		let added = bluePencil.withAlphaComponent(0.24)
		let removed = vermilion.withAlphaComponent(0.12)
		switch kind {
		case .changed: return highlighter.withAlphaComponent(0.36)
		case .added: return added
		case .removed: return removed
		case .rewritten: return isLeft ? removed : added
		}
	}

	/// The little square beside a change in the list.
	static func dot(_ kind: PDFCompare.Kind) -> Color {
		switch kind {
		case .changed: return Color.highlighter
		case .added: return .bluePencil
		case .removed, .rewritten: return .vermilion
		}
	}

	static func label(_ kind: PDFCompare.Kind) -> String {
		switch kind {
		case .changed: return String(localized: "Changed")
		case .added: return String(localized: "Added")
		case .removed: return String(localized: "Removed")
		case .rewritten: return String(localized: "Reworded")
		}
	}

	static let legend: [(label: String, color: Color)] = [
		(String(localized: "Changed"), Color.highlighter.opacity(0.5)),
		(String(localized: "Added"), Color.bluePencil.opacity(0.3)),
		(String(localized: "Removed"), Color.vermilion.opacity(0.25)),
	]
}

/// A read-only PDFView with a comparison's marks: fills behind changed words, removed words struck
/// out, the current change ringed. It goes to a selection when asked and reports taps on pages.
struct PDFComparePane: UIViewRepresentable {
	let document: PDFDocument
	var fills: [PDFSelection]
	var strikes: [PDFSelection]
	var outline: [PDFSelection]
	/// Changes whenever the marks do.
	var version: Int
	var focus: PDFSelection?
	/// A new value goes to `focus`.
	var focusToken: Int
	var onTap: (PDFPage, CGPoint) -> Void

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeUIView(context: Context) -> PDFView {
		let view = PDFView()
		view.document = document
		view.displayDirection = .vertical
		view.displayMode = .singlePageContinuous
		view.autoScales = true
		view.pageShadowsEnabled = false
		view.backgroundColor = UIColor(Color.paper)
		context.coordinator.attach(to: view)
		return view
	}

	func updateUIView(_ view: PDFView, context: Context) {
		let coordinator = context.coordinator
		coordinator.onTap = onTap
		if coordinator.version != version {
			coordinator.version = version
			view.highlightedSelections = fills.isEmpty ? nil : fills
			coordinator.replaceMarks(strikes: strikes, outline: outline)
		}
		if coordinator.focusToken != focusToken {
			coordinator.focusToken = focusToken
			if let focus { view.go(to: focus) }
		}
	}

	@MainActor
	final class Coordinator: NSObject {
		var version = -1
		var focusToken = 0
		var onTap: (PDFPage, CGPoint) -> Void = { _, _ in }
		private weak var view: PDFView?
		/// The strike-outs and rings this pane added, which it takes away before drawing new ones.
		/// They live only in this pane's copy of the PDF, which is never saved.
		private var added: [(annotation: PDFAnnotation, page: PDFPage)] = []

		func attach(to view: PDFView) {
			self.view = view
			view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
		}

		@objc private func tapped(_ recognizer: UITapGestureRecognizer) {
			guard let view else { return }
			let location = recognizer.location(in: view)
			guard let page = view.page(for: location, nearest: false) else { return }
			onTap(page, view.convert(location, to: page))
		}

		func replaceMarks(strikes: [PDFSelection], outline: [PDFSelection]) {
			for (annotation, page) in added { page.removeAnnotation(annotation) }
			added = []
			for selection in strikes {
				for page in selection.pages {
					for mark in PDFMarkupFactory.textMarks(.strikeOut, over: selection, on: page, color: CompareStyle.vermilion) {
						add(mark, to: page)
					}
				}
			}
			for selection in outline {
				for line in selection.selectionsByLine() {
					for page in line.pages { add(Self.ring(around: line.bounds(for: page)), to: page) }
				}
			}
		}

		private func add(_ annotation: PDFAnnotation, to page: PDFPage) {
			page.addAnnotation(annotation)
			added.append((annotation, page))
		}

		/// A ink ring around `bounds` (page space), drawn just outside the words.
		private static func ring(around bounds: CGRect) -> PDFAnnotation {
			let annotation = PDFAnnotation(bounds: bounds.insetBy(dx: -2.5, dy: -2), forType: .square, withProperties: nil)
			annotation.color = RescrivaPalette.ink.onPaper
			let border = PDFBorder()
			border.lineWidth = 1.5
			annotation.border = border
			return annotation
		}
	}
}

/// Picks what to compare with: this PDF as first opened, another PDF in Rescriva, or a scan.
struct PDFComparePicker: View {
	let current: PDFCompareSide
	let onPick: (PDFCompareSide) -> Void

	@Environment(\.dismiss) private var dismiss
	@FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Scan.order, ascending: false)],
				  predicate: LibraryScope.livePredicate) private var scans: FetchedResults<Scan>
	private let library = PDFLibrary.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Text("Compare with")
					.font(RescrivaFont.header(22))
					.foregroundStyle(.carbon)
				Spacer()
				CircleIconButton(systemName: "xmark", label: "Close") { dismiss() }
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 8) {
					if case .pdf(let id, false) = current, let item = library.item(id), item.isEdited {
						row(title: String(localized: "\(item.title), as first opened"), detail: String(localized: "Before Rescriva's changes")) {
							onPick(.pdf(id, original: true))
						}
					}
					if !pdfs.isEmpty { Text("PDFs").rescrivaSectionLabel().padding(.top, 8) }
					ForEach(pdfs) { item in
						row(title: item.title, detail: item.libraryMeta) { onPick(.pdf(item.id)) }
					}
					if !otherScans.isEmpty { Text("Scans").rescrivaSectionLabel().padding(.top, 8) }
					ForEach(otherScans, id: \.objectID) { scan in
						row(title: scan.displayTitle, detail: scan.libraryMeta) { onPick(.scan(scan)) }
					}
					if pdfs.isEmpty && otherScans.isEmpty {
						Text("Open a PDF or scan something to compare it with this.")
							.font(RescrivaFont.ui(14))
							.foregroundStyle(.graphite)
							.padding(.top, 24)
					}
				}
			}
		}
		.padding(20)
		.background(Color.stock)
	}

	/// Every PDF but the one being compared.
	private var pdfs: [PDFItem] {
		guard case .pdf(let id, _) = current else { return library.items }
		return library.items.filter { $0.id != id }
	}

	/// Every scan but the one being compared.
	private var otherScans: [Scan] {
		guard case .scan(let scan) = current else { return Array(scans) }
		return scans.filter { $0 != scan }
	}

	private func row(title: String, detail: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(RescrivaFont.ui(15, weight: .medium))
					.foregroundStyle(.carbon)
					.lineLimit(1)
				Text(detail)
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
					.lineLimit(1)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(14)
			.background(Color.vellum, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		}
		.buttonStyle(PressScaleStyle(scale: 0.98))
	}
}
