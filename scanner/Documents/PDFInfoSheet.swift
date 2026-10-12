//
//  PDFInfoSheet.swift
//  Rescriva (fork of Open Scanner)
//
//  "About this PDF": what the file is and claims to be, what Rescriva can and
//  can't do with it, and where Rescriva's copy differs from the original.
//

import PDFKit
import SwiftUI

struct PDFInfoSheet: View {
	@Environment(\.dismiss) private var dismiss
	let item: PDFItem
	let session: PDFEditSession

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				SheetHeader(title: String(localized: "About this PDF"), subtitle: item.sourceName,
							trailing: (String(localized: "Done"), { dismiss() }))
				section("File") {
					row("Pages", "\(session.document.pageCount)")
					row("PDF version", report.version)
					row("Size", ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
					row("Imported", RescrivaDates.dayAndTime(item.importedAt))
					if let edited = item.editedAt {
						row("Changed in Rescriva", RescrivaDates.dayAndTime(edited))
					}
				}
				section("Standards it claims") {
					if original.claims.isEmpty {
						note("None. It's a regular PDF.")
					}
					ForEach(original.claims, id: \.self) { claim in
						row(claim.label, claim.standard.purpose)
					}
					if item.isEdited && !original.strippableClaims.isEmpty {
						note("Rescriva's copy no longer claims these: its saves can't keep the colour profile and tags the standards need. The original is unchanged; share it from the More menu.")
					}
				}
				section("What's inside") {
					row("Accessibility tags", report.isTagged ? "Yes" : "No")
					row("Form fields", report.formFieldCount == 0 ? "None" : "\(report.formFieldCount)")
					if let xfa = original.xfa { row("XFA form", xfaDescription(xfa)) }
					if report.hasOutputIntent { row("Colour profile", "Yes") }
					if report.hasLayers { row("Layers", "Shown as the file sets them") }
					if report.has3D { row("3D content", "Not shown in Rescriva") }
					row("Password", report.isEncrypted ? "Yes" : "No")
				}
				if session.document.isEncrypted {
					section("Allowed by its owner") {
						row("Mark up", session.document.allowsCommenting ? "Yes" : "No")
						row("Fill in forms", session.document.allowsFormFieldEntry ? "Yes" : "No")
						row("Change pages", session.document.allowsDocumentAssembly ? "Yes" : "No")
						row("Copy text", session.document.allowsCopying ? "Yes" : "No")
						row("Print", session.document.allowsPrinting ? "Yes" : "No")
					}
				}
			}
			.padding(20)
		}
		.background(Color.stock)
	}

	private var report: PDFFormatReport { session.currentReport }
	private var original: PDFFormatReport { session.originalReport }

	private func xfaDescription(_ kind: XFAKind) -> String {
		switch kind {
		case .hybrid: return String(localized: "Also has standard fields, which Rescriva fills")
		case .staticOnly: return String(localized: "Shows as a page; fill it in Adobe's apps")
		case .dynamic: return String(localized: "Needs Adobe's XFA engine to show")
		}
	}

	private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title)
				.rescrivaSectionLabel()
			VStack(alignment: .leading, spacing: 10) {
				content()
			}
			.rescrivaCard(padding: 14)
		}
	}

	private func row(_ label: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
		HStack(alignment: .firstTextBaseline) {
			Text(label)
				.font(RescrivaFont.ui(14))
				.foregroundStyle(.carbon)
			Spacer(minLength: 12)
			Text(value)
				.font(RescrivaFont.ui(14))
				.foregroundStyle(.graphite)
				.multilineTextAlignment(.trailing)
		}
		.accessibilityElement(children: .combine)
	}

	private func row(_ label: String, _ value: String) -> some View {
		row(LocalizedStringKey(label), LocalizedStringKey(value))
	}

	private func note(_ text: LocalizedStringKey) -> some View {
		Text(text)
			.font(RescrivaFont.ui(13))
			.foregroundStyle(.graphite)
			.fixedSize(horizontal: false, vertical: true)
	}
}
