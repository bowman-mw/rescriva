//
//  ExportSheet.swift
//  Rescriva (fork of Open Scanner)
//
//  Export: pick a format (Word, PowerPoint, searchable PDF, Markdown, plain
//  text), decide about notes, and share — which includes Save to Files — or
//  hand the file to Share Nearby. Markdown can also go straight to the
//  pasteboard ("Copy for AI"). A PDF also gets its paper, image quality (both
//  remembered) and an optional password (never stored).
//

import SwiftUI
import UIKit

struct ExportSheet: View {
	@ObservedObject var scan: Scan
	let initialFormat: ExportFormat
	var onFinished: ((String) -> Void)?

	@Environment(\.dismiss) private var dismiss
	/// For Share Nearby, which opens as a screen once the sheet is down.
	@Environment(RescrivaRouter.self) private var router: RescrivaRouter?
	@State private var format: ExportFormat = .pdf
	@State private var includeNotes = true
	@State private var isWorking = false
	@State private var failure: String?
	@AppStorage(RescrivaPreference.pdfPaperSize) private var paperSize: PDFPaperSize = .pageSize
	@AppStorage(RescrivaPreference.pdfImageQuality) private var imageQuality: PDFImageQuality = .high
	/// For this export only: never stored or logged.
	@State private var password = ""

	private let tier = DeviceTier.current

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SheetHeader(title: String(localized: "Export"), trailing: (String(localized: "Cancel"), { dismiss() }))

			// The sheet is sized to fit, but a small iPhone or large text can make it taller than the
			// screen allows: the choices then scroll, and Share stays in view.
			ScrollView {
				choices
					.padding(.vertical, 2)
			}
			.scrollBounceBehavior(.basedOnSize)

			PrimaryButton(title: "Share", systemImage: "square.and.arrow.up", isBusy: isWorking, action: share)
			if format == .md {
				copyForAIButton
			}
			if router != nil {
				shareNearbyButton
			}
		}
		.padding(.horizontal, 20)
		.padding(.top, 8)
		.padding(.bottom, 12)
		.onAppear {
			format = initialFormat.needsRebuild && !tier.canRebuild ? .pdf : initialFormat
		}
		.presentationDetents([.height(sheetHeight)])
		.presentationDragIndicator(.visible)
		.presentationCornerRadius(RescrivaRadius.large)
		.presentationBackground(Color.vellum)
	}

	/// Tall enough for the five format rows, a PDF's options and whichever extra buttons show.
	private var sheetHeight: CGFloat {
		var height: CGFloat = format == .pdf ? 732 : 578
		if format == .md { height += 56 }
		if router != nil { height += 56 }
		return height
	}

	/// The file, its format, a PDF's options, the notes switch and any failure.
	private var choices: some View {
		VStack(alignment: .leading, spacing: 14) {
			fileRow

			VStack(spacing: 6) {
				ForEach(ExportFormat.allCases) { option in
					formatRow(option)
				}
			}

			if format == .pdf {
				pdfOptions
					.transition(.opacity)
			}

			Toggle(isOn: $includeNotes) {
				Text(format.notesLabel)
					.font(RescrivaFont.ui(14))
					.foregroundStyle(.carbon)
			}
			.toggleStyle(RescrivaToggleStyle())
			.padding(.horizontal, 4)

			if let failure {
				Text(failure)
					.font(RescrivaFont.ui(12))
					.foregroundStyle(.graphite)
			}
		}
	}

	/// The scan's title and the file's extension.
	private var fileRow: some View {
		HStack(spacing: 6) {
			Text(scan.displayTitle)
				.font(RescrivaFont.ui(15))
				.foregroundStyle(.carbon)
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer(minLength: 0)
			Text(format.fileExtension)
				.font(RescrivaFont.ui(14, weight: .medium))
				.foregroundStyle(.graphite)
		}
		.padding(.horizontal, 14)
		.frame(height: 44)
		.background(Color.stock, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.accessibilityElement(children: .combine)
	}

	/// Paper, image quality and password, for a PDF.
	private var pdfOptions: some View {
		VStack(spacing: 10) {
			optionRow("Paper") {
				RescrivaSegmentedPicker(options: PDFPaperSize.allCases, selection: $paperSize) { $0.label }
			}
			optionRow("Image quality") {
				RescrivaSegmentedPicker(options: PDFImageQuality.allCases, selection: $imageQuality) { $0.label }
			}
			HStack(spacing: 10) {
				Glyph("lock", size: 15, weight: .regular)
					.foregroundStyle(.graphite)
					.accessibilityHidden(true)
				SecureField("Password (optional)", text: $password)
					.font(RescrivaFont.ui(15))
					.foregroundStyle(.carbon)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.submitLabel(.done)
					.privacySensitive()
					.accessibilityHint("Anyone opening the PDF will need it")
			}
			.padding(.horizontal, 14)
			.frame(height: 44)
			.background(Color.stock, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		}
	}

	/// A label on the left, its choice on the right.
	private func optionRow<Choice: View>(_ label: LocalizedStringKey, @ViewBuilder choice: () -> Choice) -> some View {
		HStack(spacing: 12) {
			Text(label)
				.font(RescrivaFont.ui(14))
				.foregroundStyle(.carbon)
			Spacer(minLength: 0)
			choice()
				.frame(width: 222)
		}
		.padding(.horizontal, 4)
		.accessibilityElement(children: .contain)
	}

	private func formatRow(_ option: ExportFormat) -> some View {
		let locked = option.needsRebuild && !tier.canRebuild
		let selected = format == option
		return Button {
			if !locked {
				withAnimation(RescrivaMotion.ui) { format = option }
			}
		} label: {
			HStack(spacing: 12) {
				ZStack {
					Circle().strokeBorder(selected ? Color.ink : Color.carbon.opacity(0.3), lineWidth: 1.5)
					Circle().fill(selected ? Color.ink : Color.clear).frame(width: 10, height: 10)
				}
				.frame(width: 20, height: 20)
				VStack(alignment: .leading, spacing: 1) {
					Text(option.label)
						.font(RescrivaFont.ui(15, weight: .medium))
						.foregroundStyle(.carbon)
					Text(option.detail)
						.font(RescrivaFont.ui(12))
						.foregroundStyle(.graphite)
				}
				Spacer(minLength: 0)
			}
			.padding(.vertical, 12)
			.padding(.horizontal, 14)
			.background(selected ? Color.wash.opacity(0.5) : Color.stock,
						in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			.opacity(locked ? 0.4 : 1)
		}
		.buttonStyle(.plain)
		.disabled(locked)
		.accessibilityAddTraits(selected ? .isSelected : [])
		.accessibilityHint(locked ? Text("Needs a newer iPhone") : Text(""))
	}

	/// "Copy for AI": the Markdown on the pasteboard, ready to paste into an assistant.
	private var copyForAIButton: some View {
		Button(action: copyForAI) {
			HStack(spacing: 8) {
				Glyph("doc.on.clipboard", size: 15)
				Text("Copy for AI")
					.font(RescrivaFont.ui(15, weight: .medium))
			}
			.foregroundStyle(.ink)
			.frame(maxWidth: .infinity)
			.frame(minHeight: 42)
			.contentShape(Rectangle())
		}
		.buttonStyle(PressScaleStyle(scale: 0.96))
		.disabled(isWorking)
		.accessibilityHint("Copies the Markdown, with its Mermaid diagrams, to paste into an AI assistant")
	}

	/// "Share Nearby": the same file, handed to the Share Nearby screen.
	private var shareNearbyButton: some View {
		Button(action: shareNearby) {
			HStack(spacing: 8) {
				Glyph("dot.radiowaves.left.and.right", size: 15)
				Text("Share Nearby")
					.font(RescrivaFont.ui(15, weight: .medium))
			}
			.foregroundStyle(.ink)
			.frame(maxWidth: .infinity)
			.frame(minHeight: 42)
			.contentShape(Rectangle())
		}
		.buttonStyle(PressScaleStyle(scale: 0.96))
		.disabled(isWorking)
		.accessibilityHint("Shares the file with a computer or phone nearby")
	}

	private func share() {
		isWorking = true
		failure = nil
		Task {
			do {
				let options = PDFExportOptions(paperSize: paperSize, quality: imageQuality, password: password)
				let url = try await ExportService.makeFile(for: scan, format: format, includeNotes: includeNotes, pdfOptions: options)
				isWorking = false
				let name = url.lastPathComponent
				SharePresenter.share([url]) { activity, completed in
					guard completed else { return }
					let savedToFiles = activity?.rawValue.contains("SaveToFiles") ?? false
					onFinished?(savedToFiles ? String(localized: "Saved “\(name)” to Files") : String(localized: "Shared “\(name)”"))
					dismiss()
				}
			} catch {
				isWorking = false
				failure = String(localized: "That didn't work — the file couldn't be written. Try again, or pick another format.")
			}
		}
	}

	/// Puts the scan's Markdown on the pasteboard and closes the sheet.
	private func copyForAI() {
		isWorking = true
		failure = nil
		Task {
			let markdown = await ExportService.markdown(for: scan, includeNotes: includeNotes)
			isWorking = false
			guard !markdown.isEmpty else {
				failure = String(localized: "There are no words to copy yet.")
				return
			}
			UIPasteboard.general.string = markdown
			onFinished?(String(localized: "Copied as Markdown"))
			dismiss()
		}
	}

	/// Makes the file in the chosen format, closes the sheet and opens Share Nearby with it.
	private func shareNearby() {
		guard let router else { return }
		isWorking = true
		failure = nil
		Task {
			do {
				let options = PDFExportOptions(paperSize: paperSize, quality: imageQuality, password: password)
				let url = try await ExportService.makeFile(for: scan, format: format, includeNotes: includeNotes, pdfOptions: options)
				isWorking = false
				dismiss()
				router.push(.shareNearby([.file(url, name: url.lastPathComponent)]))
			} catch {
				isWorking = false
				failure = String(localized: "That didn't work — the file couldn't be written. Try again, or pick another format.")
			}
		}
	}
}
