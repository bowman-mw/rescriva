//
//  SettingsView.swift
//  Rescriva (fork of Open Scanner)
//
//  Settings — what this iPhone can do, scanning preferences, the originals
//  kept for fixing crops later, and About
//  (Open Scanner's AboutView, which this replaces, lives on as the
//  acknowledgement and its MIT licence notice).
//

import SwiftUI

struct SettingsView: View {
	@Environment(RescrivaRouter.self) private var router

	@AppStorage(RescrivaPreference.autoCapture) private var autoCapture = true
	@AppStorage(RescrivaPreference.removeShadows) private var removeShadows = true
	@AppStorage(RescrivaPreference.keepMarkerColors) private var keepMarkerColors = true
	@AppStorage(RescrivaPreference.companionTips) private var companionTips = true
	@AppStorage(RescrivaPreference.keepOriginals) private var keepOriginals = true
	@State private var sheet: InfoSheet?
	@State private var originalsUsage: OriginalStore.Usage?
	/// Imported PDFs kept for "View original" (`PDFImport`), counted and removed with the page originals.
	@State private var pdfOriginalsUsage: OriginalStore.Usage?
	@State private var confirmingRemoveOriginals = false

	private let tier = DeviceTier.current

	var body: some View {
		ZStack {
			GrainBackground()
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					HStack {
						BackPill(title: "Scans") { router.pop() }
						Spacer()
					}
					.padding(.horizontal, 12)
					.padding(.vertical, 6)

					Text("Settings")
						.font(RescrivaFont.header(30))
						.foregroundStyle(.carbon)
						.padding(.horizontal, 20)
						.padding(.top, 12)
						.padding(.bottom, 16)
						.accessibilityAddTraits(.isHeader)

					tierCard
					sectionLabel("Scanning")
					toggles
					sectionLabel("Originals")
					originalsCard
					sectionLabel("About")
					about
				}
				.padding(.bottom, 60)
			}
			.overlay(alignment: .top) { StatusBarScrim() }
		}
		.sheet(item: $sheet) { sheet in
			InfoSheetView(sheet: sheet)
		}
		.task { await refreshOriginalsUsage() }
		.confirmationDialog("Remove all originals?", isPresented: $confirmingRemoveOriginals, titleVisibility: .visible) {
			Button("Remove originals", role: .destructive) {
				Task { await removeOriginals() }
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text(removeOriginalsMessage)
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

	private var tierCard: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Text("This iPhone").rescrivaSectionLabel()
				Spacer()
				Text(tier.displayName)
					.font(RescrivaFont.ui(12, weight: .medium))
					.foregroundStyle(.carbon)
					.padding(.vertical, 4)
					.padding(.horizontal, 10)
					.background(tierChipColor, in: RoundedRectangle(cornerRadius: RescrivaRadius.small, style: .continuous))
			}
			Text(tier.summary)
				.font(RescrivaFont.body(17))
				.lineSpacing(4)
				.foregroundStyle(.carbon)
			VStack(alignment: .leading, spacing: 6) {
				capability("Searchable PDF", on: true)
				capability("Word and Slides from typed pages", on: tier.canRebuild)
				capability("Handwriting, equations and diagrams", on: tier == .smart)
			}
			.padding(.top, 4)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.rescrivaCard(padding: 18)
		.padding(.horizontal, 16)
	}

	private var tierChipColor: Color {
		switch tier {
		case .smart: return .wash
		case .basic: return Color.highlighter.opacity(0.25)
		case .pdf: return Color.carbon.opacity(0.08)
		}
	}

	private func capability(_ label: LocalizedStringKey, on: Bool) -> some View {
		HStack(spacing: 10) {
			Glyph("checkmark", size: 9, weight: .bold)
				.foregroundStyle(.vellum)
				.frame(width: 18, height: 18)
				.background(on ? Color.bluePencil : Color.carbon.opacity(0.25), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
			Text(label)
				.font(RescrivaFont.ui(14))
				.foregroundStyle(.carbon)
		}
		.opacity(on ? 1 : 0.45)
		.accessibilityElement(children: .combine)
		.accessibilityValue(on ? Text("Available") : Text("Not on this iPhone"))
	}

	private var toggles: some View {
		VStack(spacing: 0) {
			settingRow("Auto-capture", detail: "Takes the shot once the page is steady", isOn: $autoCapture)
			Divider().overlay(Color.carbon.opacity(0.06))
			settingRow("Remove shadows", detail: "Evens out lighting on paper", isOn: $removeShadows)
			Divider().overlay(Color.carbon.opacity(0.06))
			settingRow("Keep marker colors", detail: "Whiteboard diagrams keep their ink", isOn: $keepMarkerColors)
			Divider().overlay(Color.carbon.opacity(0.06))
			settingRow("Margin notes", detail: "Little notes about what I see on the page", isOn: $companionTips)
		}
		.paperCard()
		.padding(.horizontal, 16)
	}

	private func settingRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
		Toggle(isOn: isOn) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(RescrivaFont.ui(15, weight: .medium))
					.foregroundStyle(.carbon)
				Text(detail)
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
			}
		}
		.toggleStyle(RescrivaToggleStyle())
		.padding(.vertical, 14)
		.padding(.horizontal, 16)
	}

	// MARK: Originals

	private var originalsCard: some View {
		VStack(spacing: 0) {
			settingRow("Keep originals", detail: "So you can fix a page's crop later. They stay on this iPhone.", isOn: $keepOriginals)
			Divider().overlay(Color.carbon.opacity(0.06))
			HStack(spacing: 12) {
				VStack(alignment: .leading, spacing: 2) {
					Text("Space used")
						.font(RescrivaFont.ui(15, weight: .medium))
						.foregroundStyle(.carbon)
					Text(originalsSummary)
						.font(RescrivaFont.ui(12))
						.foregroundStyle(.graphite)
				}
				Spacer(minLength: 0)
				Button("Remove") { confirmingRemoveOriginals = true }
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.vermilion)
					.disabled(keptOriginals == 0)
					.opacity(keptOriginals == 0 ? 0.4 : 1)
					.accessibilityLabel("Remove originals")
			}
			.padding(.vertical, 14)
			.padding(.horizontal, 16)
			.accessibilityElement(children: .contain)
		}
		.paperCard()
		.padding(.horizontal, 16)
	}

	/// Page originals plus kept PDFs.
	private var keptOriginals: Int {
		(originalsUsage?.count ?? 0) + (pdfOriginalsUsage?.count ?? 0)
	}

	/// "34.2 MB for 12 pages and 2 PDFs", "None kept", or "Measuring…".
	private var originalsSummary: String {
		guard let pages = originalsUsage, let pdfs = pdfOriginalsUsage else { return String(localized: "Measuring…") }
		guard pages.count + pdfs.count > 0 else { return String(localized: "None kept") }
		let size = ByteCountFormatter.string(fromByteCount: pages.bytes + pdfs.bytes, countStyle: .file)
		let pageCount = pages.count == 1 ? String(localized: "1 page") : String(localized: "\(pages.count) pages")
		let pdfCount = pdfs.count == 1 ? String(localized: "1 PDF") : String(localized: "\(pdfs.count) PDFs")
		if pdfs.count == 0 { return String(localized: "\(size) for \(pageCount)") }
		if pages.count == 0 { return String(localized: "\(size) for \(pdfCount)") }
		return String(localized: "\(size) for \(pageCount) and \(pdfCount)")
	}

	/// Says what goes: page originals, kept PDFs, or both.
	private var removeOriginalsMessage: String {
		let pages = String(localized: "Your pages stay as they are, but you won't be able to fix their crop or cleanup later. Rotating still works.")
		let pdfs = String(localized: "Imported PDFs lose View original.")
		guard (pdfOriginalsUsage?.count ?? 0) > 0 else { return pages }
		guard (originalsUsage?.count ?? 0) > 0 else { return pdfs }
		return pages + " " + pdfs
	}

	private func refreshOriginalsUsage() async {
		let usage = await Task.detached(priority: .utility) { (OriginalStore.shared.usage(), PDFImport.originalsUsage()) }.value
		originalsUsage = usage.0
		pdfOriginalsUsage = usage.1
	}

	private func removeOriginals() async {
		let removed = await Task.detached(priority: .userInitiated) {
			OriginalStore.shared.removeAll() + PDFImport.removeAllOriginals()
		}.value
		await refreshOriginalsUsage()
		guard removed > 0 else { return }
		router.showToast(String(localized: "Originals removed"))
	}

	private var about: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Everything you scan is read and rebuilt on this iPhone. No accounts, no uploads, no per-page fees.")
				.font(RescrivaFont.body(16))
				.lineSpacing(4)
				.foregroundStyle(.carbon)
			Text("Built on Open Scanner by Pencil Research (MIT).")
				.font(RescrivaFont.ui(13))
				.lineSpacing(3)
				.foregroundStyle(.graphite)
			HStack(spacing: 16) {
				Button("Need help?") { sheet = .help }
				Button("Acknowledgements") { sheet = .acknowledgements }
				Button("Privacy") { sheet = .privacy }
			}
			.font(RescrivaFont.ui(14, weight: .medium))
			.foregroundStyle(.ink)
			Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "•.•") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "•"))")
				.font(RescrivaFont.ui(12))
				.foregroundStyle(.graphite)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.rescrivaCard()
		.padding(.horizontal, 16)
	}
}

/// The three About pages.
enum InfoSheet: String, Identifiable {
	case help, acknowledgements, privacy

	var id: String { rawValue }
}

private struct InfoSheetView: View {
	let sheet: InfoSheet
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SheetHeader(title: title, trailing: (String(localized: "Done"), { dismiss() }))
			ScrollView {
				Text(text)
					.font(sheet == .acknowledgements ? RescrivaFont.ui(13) : RescrivaFont.body(16))
					.lineSpacing(4)
					.foregroundStyle(.carbon)
					.frame(maxWidth: .infinity, alignment: .leading)
					.textSelection(.enabled)
			}
		}
		.padding(20)
		.presentationDetents([.medium, .large])
		.presentationDragIndicator(.visible)
		.presentationCornerRadius(RescrivaRadius.large)
		.presentationBackground(Color.vellum)
	}

	private var title: String {
		switch sheet {
		case .help: return String(localized: "Need help?")
		case .acknowledgements: return String(localized: "Acknowledgements")
		case .privacy: return String(localized: "Privacy")
		}
	}

	private var text: String {
		switch sheet {
		case .help:
			return String(localized: """
				Scan: tap Scan, hold the page in the frame, and Rescriva takes the shot once it's steady (or tap the shutter). Keep adding pages, then tap Save.

				Whiteboards: choose Whiteboard so glare is flattened and marker colors are kept.

				Rebuild: on a scan, pick Word or Slides under "Make it into", then rebuild. Dotted words are ones Rescriva wasn't sure about — tap them to fix.

				Search: the Library searches every word in every scan.
				""")
		case .privacy:
			return String(localized: """
				Rescriva reads, rebuilds and exports your scans on this iPhone. It has no account, no analytics and no advertising, and it never uploads your pages to us or anyone else.

				If iCloud is on for this app, your scans sync through your own private iCloud database so they appear on your other devices — Apple stores them, we can't see them.

				Camera access is used only while you're scanning.
				""")
		case .acknowledgements:
			return """
				Rescriva began as a fork of Open Scanner by Pencil Research and still includes some of its code, used under this license.

				MIT License

				Copyright (c) 2024 Pencil Research

				Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

				The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

				THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
				"""
		}
	}
}
