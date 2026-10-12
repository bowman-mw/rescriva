//
//  AutoTagTests.swift
//  Rescriva (fork of Open Scanner)
//
//  Which automatic tags a scan's words earn: receipts, invoices, contracts,
//  recipes and whiteboards — and ordinary notes earn none.
//

import XCTest
@testable import scanner

final class AutoTagTests: XCTestCase {
	func testReceipt() {
		let lines = ["CEDAR HARDWARE", "412 Alder St", "Brass hinges x4 11.96", "Wood screws 4.49", "Wood glue 6.29",
					 "Sandpaper pack 5.99", "TOTAL 28.73", "VISA ****1234", "Thank you!"]
		XCTAssertEqual(AutoTag.matching(lines: lines, source: .typed), [.receipt])
	}

	func testInvoiceIsNotAlsoAReceipt() {
		let lines = ["INVOICE #2041", "Bill to: Northwind Ltd", "Design work 1,200.00", "Hosting 49.00",
					 "Total 1,249.00", "Amount due 1,249.00", "Due date: Nov 30"]
		XCTAssertEqual(AutoTag.matching(lines: lines, source: .typed), [.invoice])
	}

	func testLeaseIsAContract() {
		let lines = ["Residential Lease Agreement", "This agreement is made between the landlord and the tenant.",
					 "The tenant shall pay rent monthly in advance.", "Signatures"]
		XCTAssertEqual(AutoTag.matching(lines: lines, source: .typed), [.contract])
	}

	func testRecipe() {
		let lines = ["Banana bread", "Ingredients", "2 cups flour", "1 tsp baking soda", "Preheat the oven to 350°F.",
					 "Bake for 60 minutes."]
		XCTAssertEqual(AutoTag.matching(lines: lines, source: .handwritten), [.recipe])
	}

	func testWhiteboardFromItsSource() {
		XCTAssertEqual(AutoTag.matching(lines: ["API", "queue", "worker"], source: .whiteboard), [.whiteboard])
	}

	func testNotesEarnNoTags() {
		let lines = ["Week 6 — Enzyme kinetics", "Reaction rate rises with substrate concentration until the enzyme is saturated.",
					 "v = Vmax[S] / (Km + [S])", "Repeat trial 3 at 37°C"]
		XCTAssertEqual(AutoTag.matching(lines: lines, source: .handwritten), [])
		XCTAssertEqual(AutoTag.matching(lines: [], source: nil), [])
	}

	func testWordsMatchWholeWords() {
		// "Totally" and "taxonomy" aren't "total" and "tax".
		let lines = ["Totally 12.00", "Taxonomy 3.50", "Notes 4.25", "More 1.00"]
		XCTAssertEqual(AutoTag.matching(lines: lines, source: .typed), [])
	}
}
