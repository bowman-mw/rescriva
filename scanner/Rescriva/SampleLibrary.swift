//
//  SampleLibrary.swift
//  Rescriva (fork of Open Scanner)
//
//  The design's sample library — lab notes, a whiteboard, a slide deck, a
//  lease and a receipt — rendered as real page images so OCR, search,
//  rebuild and export all run on them. Seeded only on request: launch with
//  `-seedSampleLibrary YES` (and in SwiftUI previews). The camera also uses
//  these pages where there is no camera (the Simulator).
//

import SwiftUI
import CoreData

@MainActor
enum SampleLibrary {
	/// Adds the five sample scans when the library is empty.
	static func seedIfEmpty(in context: NSManagedObjectContext) {
		let request = Scan.fetchRequest()
		request.fetchLimit = 1
		guard (try? context.count(for: request)) == 0 else { return }
		let now = Date()

		let receipt = Scan.create(from: [render(ReceiptPage(), width: 360, height: 720)], title: "Hardware store receipt", source: .typed, in: context, output: .pdf, suggestsTitle: false)
		receipt.timestamp = now.addingTimeInterval(-19 * 86_400)

		let lease = Scan.create(from: (1...7).map { render(LeasePage(number: $0)) }, title: "Lease agreement", source: .typed, in: context, output: .pdf, suggestsTitle: false)
		lease.timestamp = now.addingTimeInterval(-12 * 86_400)

		let deck = Scan.create(from: SlidePage.titles.indices.map { render(SlidePage(index: $0), width: 960, height: 540) }, title: "Q3 product review", source: .typed, in: context, output: .pptx, suggestsTitle: false)
		deck.timestamp = now.addingTimeInterval(-4 * 86_400)
		deck.fave = true

		let board = Scan.create(from: [render(WhiteboardPage(), width: 900, height: 640)], title: "Systems design whiteboard", source: .whiteboard, in: context, output: .docx, suggestsTitle: false)
		board.timestamp = now.addingTimeInterval(-26 * 3_600)

		let notes = Scan.create(from: [render(LabNotesPage()), render(LabFigurePage()), render(LabTodoPage()), render(LabDerivationPage())],
								title: "Lab notes — week 6", source: .handwritten, in: context, output: .docx, suggestsTitle: false)
		notes.timestamp = now.addingTimeInterval(-2 * 3_600)
		notes.fave = true
		var document = labNotesDocument
		document.sourceCaptureIDs = notes.capturesArray.compactMap(\.id)
		notes.rebuiltDocument = document
		organize(notes: notes, board: board, deck: deck, lease: lease, receipt: receipt, in: context)

		context.saveQuietly()
	}

	/// Folders, tags and a smart folder for the sample scans.
	private static func organize(notes: Scan, board: Scan, deck: Scan, lease: Scan, receipt: Scan, in context: NSManagedObjectContext) {
		let biology = Library.createFolder(named: "Biology 201", symbol: "flask", color: .ink, parent: nil, in: context)
		let labs = Library.createFolder(named: "Lab notes", symbol: "book.closed", color: .bluePencil, parent: biology, in: context)
		let work = Library.createFolder(named: "Work", symbol: "briefcase", color: .graphite, parent: nil, in: context)
		let home = Library.createFolder(named: "Home", symbol: "house", color: .vermilion, parent: nil, in: context)
		Library.move([notes], to: labs, in: context)
		Library.move([board, deck], to: work, in: context)
		Library.move([lease, receipt], to: home, in: context)
		Library.setPinned([notes], to: true, in: context)
		for (name, scans) in [("exam", [notes]), ("todo", [notes, board]), ("whiteboard", [board])] {
			if let tag = Library.tag(named: name, creating: true, in: context) { Library.setTag(tag, on: scans, to: true, in: context) }
		}
		Library.createSmartFolder(named: "Rebuilt as Word", symbol: "doc.text", color: .ink,
								  rule: SmartRule(outputs: [OutputKind.docx.rawValue]), in: context)
		// Samples were "edited" when they were scanned, so the library's date sections read naturally.
		for scan in [notes, board, deck, lease, receipt] { scan.lastUpdate = scan.timestamp }
	}

	/// A sample page for the camera where there is no camera.
	static func demoCapture(whiteboard: Bool, index: Int) -> UIImage {
		if whiteboard {
			return render(WhiteboardPage(), width: 900, height: 640)
		}
		switch index % 3 {
		case 0: return render(LabNotesPage())
		case 1: return render(LabTodoPage())
		default: return render(LeasePage(number: 1))
		}
	}

	private static func render<Content: View>(_ view: Content, width: CGFloat = 612, height: CGFloat = 792) -> UIImage {
		// Pages are paper: their inks are drawn as they look on paper, whatever the screen's appearance.
		let renderer = ImageRenderer(content: view.frame(width: width, height: height).environment(\.colorScheme, .light))
		renderer.scale = 2
		return renderer.uiImage ?? UIImage()
	}

	// MARK: The rebuilt lab notes (as a Smart rebuild would produce them)

	/// The lab notes' enzyme diagram (page 2's figure), with one uncertain arrow.
	/// Node boxes follow `LabFigurePage`'s 440 × 250 drawing, so the original
	/// lines up behind the shapes when the diagram is recreated.
	static var labNotesDiagram: Diagram {
		let indigo = RGBColor(hex: 0x2B3B8C)
		let vermilion = RGBColor(hex: 0xCF4326)
		let wash = RGBColor(hex: 0xE3E7F4)
		let blush = RGBColor(hex: 0xF8E1DA)
		func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedBox {
			NormalizedBox(x: x / 440, y: y / 250, width: w / 440, height: h / 250)
		}
		return Diagram(
			nodes: [
				.init(id: "substrate", label: "Substrate", shape: .rectangle, box: box(14, 11, 112, 48), stroke: indigo, fill: wash),
				.init(id: "enzyme", label: "Enzyme", shape: .ellipse, box: box(282, 11, 96, 48), stroke: vermilion, fill: blush),
				.init(id: "es", label: "ES complex", shape: .rectangle, box: box(22, 181, 126, 48), stroke: indigo, fill: wash),
				.init(id: "product", label: "Product", shape: .rectangle, box: box(274, 181, 92, 48), stroke: indigo, fill: wash),
			],
			edges: [
				.init(id: "e1", from: "substrate", to: "es"),
				.init(id: "e2", from: "enzyme", to: "es"),
				.init(id: "e3", from: "es", to: "product"),
				.init(id: "e4", from: "product", to: "enzyme", flag: RescrivaFlag(
					kind: .edge, title: String(localized: "Which way does this arrow go?"), detail: String(localized: "The arrowhead was hard to see"),
					read: "product ↕ enzyme",
					options: [.init(label: "Product → Enzyme", note: String(localized: "enzyme is released"), edgeAction: .keep),
							  .init(label: "Enzyme → Product", edgeAction: .reverse),
							  .init(label: String(localized: "No arrow"), note: String(localized: "remove it"), edgeAction: .remove)])),
			],
			layout: .faithful,
			caption: String(localized: "Figure 1 · redrawn from the page"),
			aspect: 440.0 / 250.0)
	}

	static var labNotesDocument: RescrivaDocument {
		let wordDetail = String(localized: "Vision wasn’t sure about this word")
		let diagram = labNotesDiagram
		let page1 = RescrivaPage(source: .handwritten, size: .letter, blocks: [
			RescrivaBlock(content: .heading(level: 1, runs: [RescrivaRun(text: "Week 6 — Enzyme kinetics")]),
					   box: NormalizedBox(x: 0.08, y: 0.06, width: 0.7, height: 0.06), fontClass: .serif),
			RescrivaBlock(content: .paragraph(runs: [
				RescrivaRun(text: "Reaction rate rises with substrate concentration until the enzyme is "),
				RescrivaRun(text: "saturuted", flag: RescrivaFlag(kind: .word, title: String(localized: "Did you mean…"), detail: wordDetail, read: "saturuted",
															options: [.init(label: "saturated", note: String(localized: "most likely")), .init(label: "situated"),
																	  .init(label: "saturuted", note: String(localized: "keep as read"))])),
				RescrivaRun(text: ". Past that point, adding more substrate has little effect."),
			], alignment: .leading), box: NormalizedBox(x: 0.08, y: 0.14, width: 0.84, height: 0.12), fontClass: .serif),
			RescrivaBlock(content: .equation(latex: "v = \\frac{V_{max}[S]}{K_m + [S]}", linear: "v = Vmax[S] / (Km + [S])", display: true),
					   box: NormalizedBox(x: 0.14, y: 0.28, width: 0.5, height: 0.06)),
			RescrivaBlock(content: .list(style: .checkbox, items: [
				ListItem(runs: [RescrivaRun(text: "Repeat trial 3 at 37°C")], checked: false),
				ListItem(runs: [RescrivaRun(text: "Plot "),
								RescrivaRun(text: "Lineweaver–Bunk", flag: RescrivaFlag(kind: .word, title: String(localized: "Did you mean…"), detail: String(localized: "Checklist item, page 1"),
																				 read: "Lineweaver–Bunk",
																				 options: [.init(label: "Lineweaver–Burk", note: String(localized: "most likely")), .init(label: "Lineweaver Burk"),
																						   .init(label: "Lineweaver–Bunk", note: String(localized: "keep as read"))]))],
						 checked: true),
			]), box: NormalizedBox(x: 0.08, y: 0.6, width: 0.6, height: 0.08), fontClass: .serif,
					   notes: [RescrivaNote(text: "Ask Priya whether trial 3 used fresh buffer.", created: Date())]),
		])
		let page2 = RescrivaPage(source: .handwritten, size: .letter, blocks: [
			// Where LabFigurePage draws its 440 × 250 figure on the 612 × 792 page.
			RescrivaBlock(content: .diagram(diagram), box: NormalizedBox(x: 84.0 / 612, y: 108.0 / 792, width: 440.0 / 612, height: 250.0 / 792)),
			RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Substrate binds the enzyme to form the ES complex; the product is released and the enzyme is reused.")], alignment: .leading)),
		])
		let page3 = RescrivaPage(source: .handwritten, size: .letter, blocks: [
			RescrivaBlock(content: .paragraph(runs: [RescrivaRun(text: "Questions → lab@uni.edu")], alignment: .leading)),
		])
		let page4 = RescrivaPage(source: .handwritten, size: .letter, blocks: [
			RescrivaBlock(content: .heading(level: 2, runs: [RescrivaRun(text: "Michaelis–Menten derivation")])),
			RescrivaBlock(content: .list(style: .bullet, items: [
				ListItem(runs: [RescrivaRun(text: "Steady-state assumption")]),
				ListItem(runs: [RescrivaRun(text: "Notes on inhibitors")]),
			])),
		])
		return RescrivaDocument(title: "Lab notes — week 6", pages: [page1, page2, page3, page4])
	}
}

// MARK: - Page renderings

/// Handwriting on ruled paper.
private struct Handwriting: View {
	let text: String
	var size: CGFloat = 22
	var color: Color = .ballpoint

	var body: some View {
		Text(text)
			.font(.custom("Noteworthy-Light", size: size))
			.foregroundStyle(color)
	}
}

private struct LinedPaper<Content: View>: View {
	@ViewBuilder var content: Content

	var body: some View {
		ZStack(alignment: .topLeading) {
			RuledPaper(spacing: 34)
			Rectangle().fill(Color.vermilion.opacity(0.35)).frame(width: 1.5).padding(.leading, 64)
			content
				.padding(.leading, 84)
				.padding(.trailing, 40)
				.padding(.top, 40)
		}
	}
}

private struct LabNotesPage: View {
	var body: some View {
		LinedPaper {
			VStack(alignment: .leading, spacing: 14) {
				Handwriting(text: "Week 6 — Enzyme kinetics", size: 32).underline()
				Handwriting(text: "Reaction rate rises w/ substrate conc. until the enzyme is saturuted. Past that, more substrate = little effect.")
					.lineSpacing(10)
				Handwriting(text: "v = Vmax[S] / (Km + [S])", size: 26).padding(.leading, 30)
				HStack(spacing: 14) {
					Handwriting(text: "substrate", size: 18, color: .ink).padding(8).overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.ink, lineWidth: 2.5) }
					Handwriting(text: "→", size: 22, color: .ink)
					Handwriting(text: "ES", size: 18, color: .vermilion).padding(8).overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.vermilion, lineWidth: 2.5) }
					Handwriting(text: "→", size: 22, color: .ink)
					Handwriting(text: "product", size: 18, color: .ink).padding(8).overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.ink, lineWidth: 2.5) }
				}
				Handwriting(text: "☐ repeat trial 3 at 37°C")
				Handwriting(text: "☑ plot Lineweaver–Bunk")
			}
		}
	}
}

private struct LabFigurePage: View {
	var body: some View {
		LinedPaper {
			VStack(alignment: .leading, spacing: 24) {
				Handwriting(text: "Figure: how the enzyme cycles", size: 26)
				ZStack {
					Path { path in
						path.move(to: CGPoint(x: 70, y: 60)); path.addLine(to: CGPoint(x: 70, y: 170))
						path.move(to: CGPoint(x: 330, y: 60)); path.addLine(to: CGPoint(x: 160, y: 175))
						path.move(to: CGPoint(x: 160, y: 205)); path.addLine(to: CGPoint(x: 250, y: 205))
						path.move(to: CGPoint(x: 340, y: 180)); path.addLine(to: CGPoint(x: 340, y: 70))
					}
					.stroke(Color.ballpoint, lineWidth: 2.5)
					Handwriting(text: "Substrate", size: 20, color: .ink).padding(10).overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.ink, lineWidth: 2.5) }.position(x: 70, y: 35)
					Handwriting(text: "Enzyme", size: 20, color: .vermilion).padding(10).overlay { Capsule().stroke(Color.vermilion, lineWidth: 2.5) }.position(x: 330, y: 35)
					Handwriting(text: "ES complex", size: 20, color: .ink).padding(10).overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.ink, lineWidth: 2.5) }.position(x: 85, y: 205)
					Handwriting(text: "Product", size: 20, color: .ink).padding(10).overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.ink, lineWidth: 2.5) }.position(x: 320, y: 205)
				}
				.frame(width: 440, height: 250)
				Handwriting(text: "substrate → ES complex → product, enzyme released and reused.")
					.lineSpacing(10)
			}
		}
	}
}

private struct LabTodoPage: View {
	var body: some View {
		LinedPaper {
			VStack(alignment: .leading, spacing: 18) {
				Handwriting(text: "To do", size: 30).underline()
				Handwriting(text: "Repeat trial 3 at 37°C.")
				Handwriting(text: "Plot Lineweaver–Burk.")
				Handwriting(text: "Questions → lab@uni.edu")
			}
		}
	}
}

private struct LabDerivationPage: View {
	var body: some View {
		LinedPaper {
			VStack(alignment: .leading, spacing: 18) {
				Handwriting(text: "Michaelis–Menten derivation", size: 28).underline()
				Handwriting(text: "- steady-state assumption")
				Handwriting(text: "- notes on inhibitors")
				Handwriting(text: "d[ES]/dt = 0", size: 24).padding(.leading, 30)
			}
		}
	}
}

private struct WhiteboardPage: View {
	var body: some View {
		ZStack {
			Color(hex: 0xF4F6F6)
			Path { path in
				path.move(to: CGPoint(x: 250, y: 200)); path.addLine(to: CGPoint(x: 380, y: 200))
				path.move(to: CGPoint(x: 560, y: 200)); path.addLine(to: CGPoint(x: 680, y: 200))
				path.move(to: CGPoint(x: 470, y: 240)); path.addLine(to: CGPoint(x: 470, y: 380))
			}
			.stroke(Color(hex: 0x2B4C7E), lineWidth: 4)
			marker("API", color: Color(hex: 0x2B4C7E)).position(x: 170, y: 200)
			marker("queue", color: .ink).position(x: 470, y: 200)
			marker("worker", color: .vermilion).position(x: 760, y: 200)
			marker("cache", color: .ink).position(x: 470, y: 440)
			Text("Systems design")
				.font(.custom("Noteworthy-Bold", size: 40))
				.foregroundStyle(Color(hex: 0x2B4C7E))
				.position(x: 450, y: 70)
			Text("retry w/ backoff • idempotent jobs")
				.font(.custom("Noteworthy-Light", size: 26))
				.foregroundStyle(Color.vermilion)
				.position(x: 450, y: 570)
		}
	}

	private func marker(_ label: String, color: Color) -> some View {
		Text(label)
			.font(.custom("Noteworthy-Bold", size: 32))
			.foregroundStyle(color)
			.frame(width: 160, height: 84)
			.overlay { RoundedRectangle(cornerRadius: 14).stroke(color, lineWidth: 4) }
	}
}

private struct SlidePage: View {
	let index: Int

	static let titles = ["Q3 product review", "Agenda", "Highlights", "Revenue", "Roadmap", "Customers",
						 "Hiring", "Risks", "Q4 goals", "Timeline", "Questions", "Thank you"]
	private static let bullets = ["Where we landed this quarter", "What shipped and what slipped", "Revenue up 14% on Q2",
								  "Three bets for Q4", "Two new design partners", "Open roles: 3"]

	var body: some View {
		ZStack(alignment: .topLeading) {
			Color.white
			Rectangle().fill(Color.highlighter).frame(height: 18)
			VStack(alignment: .leading, spacing: 22) {
				Text(Self.titles[index])
					.font(.system(size: index == 0 ? 64 : 48, weight: .bold))
					.foregroundStyle(Color.carbon)
				if index > 0 {
					ForEach(0..<3, id: \.self) { line in
						Text("• " + Self.bullets[(index + line) % Self.bullets.count])
							.font(.system(size: 28))
							.foregroundStyle(Color.carbon.opacity(0.85))
					}
				} else {
					Text("Product team · October")
						.font(.system(size: 30))
						.foregroundStyle(Color.graphite)
				}
			}
			.padding(.horizontal, 64)
			.padding(.top, 70)
			Text("\(index + 1)")
				.font(.system(size: 20))
				.foregroundStyle(Color.graphite)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
				.padding(28)
		}
	}
}

private struct LeasePage: View {
	let number: Int

	private static let sections = [
		("Residential Lease Agreement", "This agreement is made between the landlord and the tenant for the premises described below. The term begins on the first day of the month."),
		("1. Rent", "The tenant shall pay rent monthly in advance. Rent is due on the first day of each month and is late after the fifth."),
		("2. Security deposit", "The tenant has paid a security deposit equal to one month's rent. The landlord shall return the deposit within 30 days of the end of the lease."),
		("3. Utilities", "The tenant is responsible for electricity and internet. The landlord pays water, sewer and trash."),
		("4. Repairs", "The landlord shall keep the premises in good repair. The tenant shall report problems promptly in writing."),
		("5. Entry", "The landlord may enter with 24 hours' notice to inspect or make repairs, or at any time in an emergency."),
		("6. Signatures", "Landlord ____________________    Tenant ____________________    Date __________"),
	]

	var body: some View {
		let section = Self.sections[(number - 1) % Self.sections.count]
		ZStack(alignment: .topLeading) {
			Color.white
			VStack(alignment: .leading, spacing: 18) {
				Text(section.0)
					.font(.system(size: number == 1 ? 30 : 22, weight: .bold, design: .serif))
				Text(section.1)
					.font(.system(size: 15, design: .serif))
					.lineSpacing(6)
				Text("The tenant and landlord agree to the terms above. Any change must be in writing and signed by both parties.")
					.font(.system(size: 15, design: .serif))
					.lineSpacing(6)
			}
			.foregroundStyle(Color.black.opacity(0.85))
			.padding(60)
			Text("Page \(number) of 7")
				.font(.system(size: 11, design: .serif))
				.foregroundStyle(.gray)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
				.padding(.bottom, 30)
		}
	}
}

private struct ReceiptPage: View {
	private let items = [("Brass hinges ×4", "11.96"), ("Wood screws, 1¼\"", "4.49"), ("Wood glue", "6.29"), ("Sandpaper pack", "5.99")]

	var body: some View {
		ZStack(alignment: .top) {
			Color.white
			VStack(spacing: 10) {
				Text("CEDAR HARDWARE").font(.system(size: 22, weight: .bold, design: .monospaced))
				Text("412 Alder St").font(.system(size: 14, design: .monospaced))
				Divider().padding(.vertical, 8)
				ForEach(items, id: \.0) { item in
					HStack {
						Text(item.0)
						Spacer()
						Text(item.1)
					}
					.font(.system(size: 15, design: .monospaced))
				}
				Divider().padding(.vertical, 8)
				HStack {
					Text("TOTAL").bold()
					Spacer()
					Text("28.73").bold()
				}
				.font(.system(size: 17, design: .monospaced))
				Text("Thank you!").font(.system(size: 14, design: .monospaced)).padding(.top, 20)
			}
			.foregroundStyle(Color.black.opacity(0.8))
			.padding(28)
		}
	}
}
