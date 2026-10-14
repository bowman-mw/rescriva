//
//  RescrivaCoreTests.swift
//  Rescriva (fork of Open Scanner)
//
//  The review edits, uncertain-word flags, layout heuristics and the equation
//  parser — the logic behind Review & fix that doesn't need a device.
//

import XCTest
@testable import scanner

@MainActor
final class RescrivaCoreTests: XCTestCase {

	// MARK: Review edits

	func testResolvingAWordFlagReplacesTheTextAndClosesTheFlag() throws {
		var document = SampleLibrary.labNotesDocument
		XCTAssertEqual(document.openFlags.count, 3)
		let flag = try XCTUnwrap(document.openFlags.first { $0.flag.read == "saturuted" }?.flag)

		document.resolveFlag(flag.id, option: flag.options[0])

		XCTAssertEqual(document.openFlags.count, 2)
		let paragraph = try XCTUnwrap(document.pages[0].blocks.first { if case .paragraph = $0.content { return true }; return false })
		XCTAssertTrue(paragraph.content.plainText.contains("enzyme is saturated."))
		XCTAssertEqual(document.flag(flag.id)?.resolution, "saturated")
	}

	func testTypedCorrectionWins() throws {
		var document = SampleLibrary.labNotesDocument
		let flag = try XCTUnwrap(document.openFlags.first { $0.flag.read == "Lineweaver–Bunk" }?.flag)
		document.resolveFlag(flag.id, typed: "Lineweaver-Burk plot")
		XCTAssertTrue(document.pages[0].blocks.contains { $0.content.plainText.contains("Plot Lineweaver-Burk plot") })
	}

	func testEdgeFlagCanReverseOrRemoveTheArrow() throws {
		var reversed = SampleLibrary.labNotesDocument
		let flag = try XCTUnwrap(reversed.openFlags.first { $0.flag.kind == .edge }?.flag)
		let reverse = try XCTUnwrap(flag.options.first { $0.edgeAction == .reverse })
		reversed.resolveFlag(flag.id, option: reverse)
		guard case .diagram(let diagram) = reversed.pages.flatMap(\.blocks).first(where: { if case .diagram = $0.content { return true }; return false })?.content else {
			return XCTFail("no diagram")
		}
		let edge = try XCTUnwrap(diagram.edges.first { $0.id == "e4" })
		XCTAssertEqual(edge.from, "enzyme")
		XCTAssertEqual(edge.to, "product")

		var removed = SampleLibrary.labNotesDocument
		let removedFlag = try XCTUnwrap(removed.openFlags.first { $0.flag.kind == .edge }?.flag)
		let remove = try XCTUnwrap(removedFlag.options.first { $0.edgeAction == .remove })
		removed.resolveFlag(removedFlag.id, option: remove)
		guard case .diagram(let pruned) = removed.pages.flatMap(\.blocks).first(where: { if case .diagram = $0.content { return true }; return false })?.content else {
			return XCTFail("no diagram")
		}
		XCTAssertFalse(pruned.edges.contains { $0.id == "e4" })
		XCTAssertEqual(removed.openFlags.count, 2)
	}

	func testEdgeFlagCanMakeAPlainLineOrATwoWayArrow() throws {
		func resolved(_ action: RescrivaFlag.EdgeAction, from direction: Diagram.Direction) throws -> Diagram.Edge {
			let flag = direction == .both ? DiagramDetector.bothWaysFlag(from: "API", to: "queue")
				: DiagramDetector.plainLineFlag(from: "API", to: "queue")
			let diagram = Diagram(nodes: [
				.init(id: "a", label: "API", shape: .rectangle, box: NormalizedBox(x: 0, y: 0, width: 0.3, height: 0.3), stroke: RGBColor(hex: 0x222222)),
				.init(id: "b", label: "queue", shape: .parallelogram, box: NormalizedBox(x: 0.6, y: 0, width: 0.3, height: 0.3), stroke: RGBColor(hex: 0x222222)),
			], edges: [.init(id: "e", from: "a", to: "b", flag: flag, direction: direction)])
			var content = BlockContent.diagram(diagram)
			let option = try XCTUnwrap(flag.options.first { $0.edgeAction == action })
			content.resolveFlag(flag.id, option: option, typed: nil)
			guard case .diagram(let after) = content, let edge = after.edges.first else {
				XCTFail("the edge is gone")
				return Diagram.Edge(id: "", from: "", to: "")
			}
			return edge
		}
		let plain = try resolved(.plain, from: .none)
		XCTAssertEqual(plain.direction, Diagram.Direction.none)
		XCTAssertEqual(plain.flag?.resolution, "Plain line")
		XCTAssertEqual(try resolved(.both, from: .both).direction, .both)
		XCTAssertEqual(try resolved(.keep, from: .none).direction, .forward, "choosing an arrow adds its head")
		let reversed = try resolved(.reverse, from: .both)
		XCTAssertEqual([reversed.from, reversed.to], ["b", "a"])
		XCTAssertEqual(reversed.direction, .forward)
	}

	func testEdgesSavedBeforeDirectionExistedDecodeAsForwardArrows() throws {
		let legacy = Data(#"{"id":"e1","from":"a","to":"b","label":"kcat"}"#.utf8)
		let edge = try JSONDecoder.rescriva.decode(Diagram.Edge.self, from: legacy)
		XCTAssertEqual(edge.direction, .forward)
		XCTAssertEqual(edge.label, "kcat")
		XCTAssertNil(edge.flag)

		for direction in [Diagram.Direction.forward, .none, .both] {
			let saved = Diagram.Edge(id: "e", from: "a", to: "b", direction: direction)
			let data = try JSONEncoder.rescriva.encode(saved)
			XCTAssertEqual(try JSONDecoder.rescriva.decode(Diagram.Edge.self, from: data), saved)
		}
		XCTAssertNil(Diagram.Shape(rawValue: "trapezoid"))
		XCTAssertEqual(Diagram.Shape(rawValue: "parallelogram"), .parallelogram)
	}

	func testFormatButtonsStyleTheWholeBlockAndHeadingToggles() {
		var content = BlockContent.paragraph(runs: [RescrivaRun(text: "Hello "), RescrivaRun(text: "world", italic: true)], alignment: .leading)
		XCTAssertFalse(content.allRuns(.bold))
		content.setStyle(.bold, to: true)
		XCTAssertTrue(content.allRuns(.bold))
		XCTAssertFalse(content.allRuns(.italic))

		content.toggleHeading()
		XCTAssertTrue(content.isHeading)
		content.toggleHeading()
		XCTAssertFalse(content.isHeading)
		XCTAssertEqual(content.plainText, "Hello world")
	}

	func testCheckboxesTick() throws {
		let item = ListItem(runs: [RescrivaRun(text: "Repeat trial 3")], checked: false)
		var content = BlockContent.list(style: .checkbox, items: [item])
		content.toggleChecked(item: item.id)
		guard case .list(_, let items) = content else { return XCTFail("not a list") }
		XCTAssertEqual(items.first?.checked, true)
	}

	func testDocumentRoundTripsThroughJSON() throws {
		let document = SampleLibrary.labNotesDocument
		let data = try JSONEncoder.rescriva.encode(document)
		let decoded = try JSONDecoder.rescriva.decode(RescrivaDocument.self, from: data)
		XCTAssertEqual(decoded, document)
	}

	func testStoredDocumentsDecodeByVersion() throws {
		var document = SampleLibrary.labNotesDocument
		XCTAssertEqual(document.version, RescrivaDocument.currentVersion, "new documents carry the version this build writes")
		XCTAssertEqual(RescrivaDocument.decodeStored(try JSONEncoder.rescriva.encode(document)), .document(document))

		let newer = RescrivaDocument.currentVersion + 1
		document.version = newer
		XCTAssertEqual(RescrivaDocument.decodeStored(try JSONEncoder.rescriva.encode(document)), .needsNewerApp(version: newer),
					   "a document a newer Rescriva wrote, even one this build could read")
		let unreadableNewer = Data(#"{"version": \#(newer), "title": "x", "pages": "a shape this build doesn't know"}"#.utf8)
		XCTAssertEqual(RescrivaDocument.decodeStored(unreadableNewer), .needsNewerApp(version: newer),
					   "the version is read on its own when the rest won't decode")

		XCTAssertEqual(RescrivaDocument.decodeStored(Data("{".utf8)), .unreadable)
		XCTAssertEqual(RescrivaDocument.decodeStored(Data(#"{"title": "x", "pages": 3}"#.utf8)), .unreadable, "this version's JSON gone wrong")
		XCTAssertNil(RebuiltDocumentState.unreadable.document)
		XCTAssertNil(RebuiltDocumentState.needsNewerApp(version: newer).document)
		XCTAssertTrue(RebuiltDocumentState.needsNewerApp(version: newer).needsNewerApp)
		XCTAssertFalse(RebuiltDocumentState.missing.needsNewerApp)
	}

	// MARK: Flags from Vision's alternatives

	func testWordFlagFindsTheOneWordTheReadingsDisagreeOn() throws {
		let line = RecognizedLine(text: "until the enzyme is saturuted", confidence: 0.3,
								  alternatives: ["until the enzyme is saturated", "until the enzyme is situated"], box: .zero)
		let flag = try XCTUnwrap(Rebuilder.wordFlag(for: line))
		XCTAssertEqual(flag.word, "saturuted")
		XCTAssertEqual(flag.options, ["saturated", "situated"])

		let runs = Rebuilder.flaggedRuns(for: line)
		XCTAssertEqual(runs.map(\.text), ["until the enzyme is ", "saturuted"])
		XCTAssertEqual(runs.last?.flag?.options.last?.label, "saturuted")
	}

	func testCorrectlySpelledReadingsWithOnlyMisspelledAlternativesAreNotFlagged() throws {
		let line = RecognizedLine(text: "queue", confidence: 0.3, alternatives: ["queu", "quee"], box: .zero)
		let page = RescrivaPage(blocks: [RescrivaBlock(content: .paragraph(runs: Rebuilder.flaggedRuns(for: line), alignment: .leading))])
		XCTAssertEqual(RescrivaDocument(title: "t", pages: [page]).openFlags.count, 1)
		let refined = Rebuilder.refineWordFlags(RescrivaDocument(title: "t", pages: [page]))
		XCTAssertEqual(refined.openFlags.count, 0)

		let misread = RecognizedLine(text: "the enzyme is saturuted", confidence: 0.3, alternatives: ["the enzyme is saturated", "the enzyme is saturuteb"], box: .zero)
		let misreadPage = RescrivaPage(blocks: [RescrivaBlock(content: .paragraph(runs: Rebuilder.flaggedRuns(for: misread), alignment: .leading))])
		let kept = try XCTUnwrap(Rebuilder.refineWordFlags(RescrivaDocument(title: "t", pages: [misreadPage])).openFlags.first?.flag)
		XCTAssertEqual(kept.options.first?.label, "saturated")
		XCTAssertEqual(kept.options.last?.label, "saturuted")
	}

	func testConfidentLinesAndUnalignedAlternativesAreNotFlagged() {
		let confident = RecognizedLine(text: "Plot the data", confidence: 1, alternatives: ["Plot the dota"], box: .zero)
		XCTAssertEqual(Rebuilder.flaggedRuns(for: confident).count, 1)
		XCTAssertNil(Rebuilder.flaggedRuns(for: confident).first?.flag)

		let unaligned = RecognizedLine(text: "Plot the data", confidence: 0.3, alternatives: ["Plotthe data"], box: .zero)
		XCTAssertNil(Rebuilder.wordFlag(for: unaligned))
	}

	// MARK: Which flags survive (typed pages abstain)

	/// A low-confidence line with Vision's other readings, most likely first.
	private func uncertain(_ text: String, _ alternatives: String...) -> RecognizedLine {
		RecognizedLine(text: text, confidence: 0.5, alternatives: alternatives, box: .zero)
	}

	/// The open word flags on a `source` page holding `line`, once the rebuild has refined them.
	private func refinedFlags(_ line: RecognizedLine, on source: PageSource) -> [RescrivaFlag] {
		let page = RescrivaPage(source: source, blocks: [RescrivaBlock(content: .paragraph(runs: Rebuilder.flaggedRuns(for: line), alignment: .leading))])
		return Rebuilder.refineWordFlags(RescrivaDocument(title: "t", pages: [page])).openFlags.map(\.flag)
	}

	func testVariantsAreTheReadingWithGlyphsDroppedOrPunctuationOrCaseChanged() {
		let variants: [(alternative: String, read: String)] = [
			("39", "3.9"), ("3.", "3.9"), ("3", "30"), ("0", "30"), ("(Ah", "(Ah)"), ("(A)", "(Ah)"),
			("Cel", "Cell"), ("SiCore", "SiCore™"), ("amprus", "amprius"), ("ampris", "amprius"),
			("SOC", "SOC)"), ("SI", "SDI"), ("standar", "Standar"), ("23'C.", "23°C."), ("|", "/"),
		]
		for (alternative, read) in variants {
			XCTAssertTrue(WordFlagRules.isVariant(alternative, of: read), "\(alternative) for \(read)")
		}
		let otherWords: [(alternative: String, read: String)] = [
			("Volt", "Valt"), ("Ratio", "Ratic"), ("Lithium-Ion", "Lithium-lon"), ("control", "contol"),
			("Cores", "Core"), ("42", "12"), ("3.8", "3.9"), ("dear", "clear"),
		]
		for (alternative, read) in otherWords {
			XCTAssertFalse(WordFlagRules.isVariant(alternative, of: read), "\(alternative) for \(read)")
		}
	}

	func testEdgePunctuationIsNotADifferentWord() {
		for (read, alternative) in [("No.", "No"), ("(2)", "2)"), ("SOC)", "SOC"), ("charge),", "charge)."), ("Division.", "Division")] {
			XCTAssertTrue(WordFlagRules.differsOnlyInEdgePunctuation(read, alternative), "\(read) / \(alternative)")
		}
		for (read, alternative) in [("3.9", "39"), ("No", "No"), ("SiCore™", "SiCore"), ("Cell", "Cel")] {
			XCTAssertFalse(WordFlagRules.differsOnlyInEdgePunctuation(read, alternative), "\(read) / \(alternative)")
		}

		XCTAssertNil(Rebuilder.wordFlag(for: uncertain("Spec. No.", "Spec. No", "Spec.No.")))
		XCTAssertNil(Rebuilder.wordFlag(for: uncertain("State of charge (SOC)", "State of charge (SOC")))
		// An edge-punctuation reading no longer claims the flag from the word really in doubt.
		let flag = Rebuilder.wordFlag(for: uncertain("Nominal Valt (V)", "Nominal Valt (V", "Nominal Volt (V)"))
		XCTAssertEqual(flag?.word, "Valt")
		XCTAssertEqual(flag?.options, ["Volt"])
	}

	func testTypedPagesDropNumberAndTruncationFlags() {
		let noise = [
			uncertain("3.9", "39", "3."), uncertain("Capacity 30", "Capacity 3", "Capacity 0"),
			uncertain("Capacity (Ah)", "Capacity (Ah", "Capacity (A)"), uncertain("18650 Cell", "18650 Cel"),
			uncertain("SiCore™ cells", "SiCore cells"), uncertain("amprius", "amprus", "ampris"),
			uncertain("Rate 12", "Rate 42"), uncertain("Room temperature", "Roam temperature"),
			uncertain("Crs", "Cr5"), uncertain("Tentati", "Tenati", "Tentat"),
		]
		for line in noise {
			XCTAssertEqual(Rebuilder.flaggedRuns(for: line).compactMap(\.flag).count, 1, line.text)
			XCTAssertEqual(refinedFlags(line, on: .typed), [], line.text)
		}
	}

	func testTypedPagesKeepAMisreadWordWithARealWordAlternative() throws {
		let flag = try XCTUnwrap(refinedFlags(uncertain("Nominal Valt", "Nominal Volt", "Nominal Vat", "Nominal Vault"), on: .typed).first)
		// "Vat" is a word, but it's "Valt" with a glyph dropped; "Vault" adds one, so it's a question.
		XCTAssertEqual(flag.options.map(\.label), ["Volt", "Vault", "Valt"])
		XCTAssertEqual(flag.options.last?.note, String(localized: "keep as read"))

		let misread = try XCTUnwrap(refinedFlags(uncertain("the enzyme is saturuted", "the enzyme is saturated", "the enzyme is saturuteb"), on: .typed).first)
		XCTAssertEqual(misread.options.map(\.label), ["saturated", "saturuted"])
	}

	func testHandwrittenPagesStillAskAboutGenuinelyAmbiguousReadings() throws {
		let decimal = try XCTUnwrap(refinedFlags(uncertain("Total 3.9", "Total 39"), on: .handwritten).first)
		XCTAssertEqual(decimal.options.map(\.label), ["39", "3.9"])

		let word = try XCTUnwrap(refinedFlags(uncertain("all clear", "all dear"), on: .whiteboard).first)
		XCTAssertEqual(word.options.map(\.label), ["dear", "clear"])
		XCTAssertEqual(refinedFlags(uncertain("all clear", "all dear"), on: .typed), [])

		let misspelled = try XCTUnwrap(refinedFlags(uncertain("saturuted", "saturuteb", "saturated"), on: .handwritten).first)
		XCTAssertEqual(misspelled.options.map(\.label), ["saturated", "saturuteb", "saturuted"])
		// Edge punctuation isn't a question on any page.
		XCTAssertEqual(refinedFlags(uncertain("Division.", "Division"), on: .handwritten), [])
	}

	// MARK: Layout heuristics

	func testHeuristicsFindHeadingParagraphBulletsAndCheckboxes() throws {
		func line(_ text: String, y: Double, height: Double = 0.02, x: Double = 0.1) -> RecognizedLine {
			RecognizedLine(text: text, confidence: 1, alternatives: [], box: CGRect(x: x, y: y, width: 0.6, height: height))
		}
		let blocks = Rebuilder.heuristicBlocks([
			line("Week 6 — Enzyme kinetics", y: 0.05, height: 0.04),
			line("Reaction rate rises with substrate", y: 0.12),
			line("concentration until saturation.", y: 0.145),
			line("- steady state", y: 0.25),
			line("- inhibitors", y: 0.28),
			line("☐ repeat trial 3", y: 0.35),
			line("☑ plot Lineweaver–Burk", y: 0.38),
		])
		XCTAssertEqual(blocks.count, 4)
		XCTAssertTrue(blocks[0].content.isHeading)
		guard case .paragraph = blocks[1].content else { return XCTFail("expected paragraph") }
		XCTAssertEqual(blocks[1].content.plainText, "Reaction rate rises with substrate concentration until saturation.")
		guard case .list(.bullet, let bullets) = blocks[2].content else { return XCTFail("expected bullets") }
		XCTAssertEqual(bullets.map(\.runs.plainText), ["steady state", "inhibitors"])
		guard case .list(.checkbox, let boxes) = blocks[3].content else { return XCTFail("expected checklist") }
		XCTAssertEqual(boxes.map(\.checked), [false, true])
		// A list's box covers every item, not just the first.
		let bulletBox = try XCTUnwrap(blocks[2].box)
		XCTAssertEqual(bulletBox.y, 0.25, accuracy: 1e-9)
		XCTAssertEqual(bulletBox.y + bulletBox.height, 0.30, accuracy: 1e-9)
		let checklistBox = try XCTUnwrap(blocks[3].box)
		XCTAssertEqual(checklistBox.y + checklistBox.height, 0.40, accuracy: 1e-9)
	}

	func testMergedChecklistsCoverEveryItem() throws {
		func item(_ text: String, y: Double) -> RescrivaBlock {
			RescrivaBlock(content: .list(style: .checkbox, items: [ListItem(runs: [RescrivaRun(text: text)], checked: false)]),
					   box: NormalizedBox(x: 0.1, y: y, width: 0.5, height: 0.03))
		}
		let merged = Rebuilder.mergeAdjacentChecklists([item("Renew passport", y: 0.2), item("Book flights", y: 0.25)])
		XCTAssertEqual(merged.count, 1)
		let box = try XCTUnwrap(merged.first?.box)
		XCTAssertEqual(box.y, 0.2, accuracy: 1e-9)
		XCTAssertEqual(box.y + box.height, 0.28, accuracy: 1e-9)
		XCTAssertEqual(Rebuilder.covering(nil, box), box)
		XCTAssertNil(Rebuilder.covering(nil, nil))
	}

	// MARK: Equation typesetting

	func testMathParserHandlesFractionsAndScripts() throws {
		var parser = MathParser("v = \\frac{V_{max}[S]}{K_m + [S]}")
		let node = try XCTUnwrap(parser.parse())
		guard case .row(let parts) = node else { return XCTFail("expected a row") }
		XCTAssertTrue(parts.contains { if case .fraction = $0 { return true }; return false })

		var unsupported = MathParser("\\begin{matrix} a \\end{matrix}")
		XCTAssertNil(unsupported.parse())
	}
}
