//
//  AutoTags.swift
//  Rescriva (fork of Open Scanner)
//
//  Tags Rescriva adds by itself: what kind of document a scan is — a
//  receipt, an invoice, a contract, a recipe, a whiteboard — read from its
//  words once its pages have been read. Everything else (#todo, #exam)
//  people tag by hand. An automatic tag is an ordinary tag once it's there:
//  it can be renamed or removed, and Rescriva only reads a scan's new pages
//  for tags, so a removed tag isn't put back by an older page.
//

import CoreData
import Foundation

/// A kind of document Rescriva recognises and tags by itself. The raw value
/// is the tag's name.
enum AutoTag: String, CaseIterable {
	case receipt, invoice, contract, recipe, whiteboard

	/// The kinds a scan's recognised lines (and where its pages came from)
	/// look like. On-device and word-based: a few telling words, and for
	/// receipts and invoices some amounts of money.
	static func matching(lines: [String], source: PageSource?) -> [AutoTag] {
		var found: [AutoTag] = []
		if source == .whiteboard { found.append(.whiteboard) }
		let text = lines.joined(separator: "\n").lowercased()
		guard !text.isEmpty else { return found }
		let amounts = lines.filter { $0.range(of: Self.amount, options: .regularExpression) != nil }.count

		let invoiceWords = hits(["invoice", "amount due", "balance due", "due date", "bill to", "payment terms", "remit"], in: text)
		let isInvoice = text.contains("invoice") && (invoiceWords >= 2 || amounts >= 2)
		if isInvoice {
			found.append(.invoice)
		} else {
			// Receipts: a total among several amounts, or the word itself.
			let receiptWords = hits(["subtotal", "sub total", "tax", "change", "cash", "visa", "mastercard", "amex", "debit",
									 "credit", "card #", "receipt", "thank you", "qty", "tip", "balance"], in: text)
			let hasTotal = text.range(of: #"\btotal\b"#, options: .regularExpression) != nil
			if (hasTotal && amounts >= 3) || (text.contains("receipt") && amounts >= 2) || (receiptWords >= 3 && amounts >= 3) {
				found.append(.receipt)
			}
		}
		let contractWords = hits(["agreement", "contract", "lease", "landlord", "tenant", "hereby", "terms and conditions",
								  "the parties", "party", "signature", "signed", "shall", "witness", "effective date"], in: text)
		if contractWords >= 3 { found.append(.contract) }
		let recipeWords = hits(["ingredients", "directions", "method", "preheat", "oven", "tbsp", "tsp", "tablespoon",
								"teaspoon", "cup", "cups", "bake", "simmer", "whisk", "serves", "prep time", "cook time"], in: text)
		if recipeWords >= 3 { found.append(.recipe) }
		return found
	}

	/// An amount of money on a line: 12.99, $4.50, 1,299.00 or 3,50 €.
	private static let amount = #"(?:[$€£¥]\s?\d|\d)[\d,.]*[.,]\d{2}\b"#

	/// How many of `words` appear in `text` as whole words or phrases.
	private static func hits(_ words: [String], in text: String) -> Int {
		words.filter { word in
			text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"(?![a-z])"#, options: .regularExpression) != nil
		}.count
	}
}

@MainActor
enum AutoTags {
	/// Adds the automatic tags that `pages` (pages just added to `scan` and
	/// read) earn. Only those pages are looked at, and a scan's source only
	/// counts when they're the whole scan (`isNewScan`), so pages added later
	/// don't bring back a tag someone removed. Tags are only ever added here,
	/// never taken away. The words are weighed off the main thread.
	static func apply(to scan: Scan, pages: [ScanCapture], isNewScan: Bool, in context: NSManagedObjectContext) async {
		let lines = pages.filter { !$0.isDeleted && $0.managedObjectContext != nil }
			.flatMap { $0.recognizedItemsArray.compactMap(\.transcript) }
		let source = isNewScan ? scan.pageSource : nil
		let kinds = await Task.detached(priority: .utility) { AutoTag.matching(lines: lines, source: source) }.value
		// The scan may have been deleted while its words were weighed.
		guard !kinds.isEmpty, scan.deletedAt == nil, !scan.isDeleted, scan.managedObjectContext != nil else { return }
		let present = Set(scan.tagList.compactMap { $0.name?.lowercased() })
		for kind in kinds where !present.contains(kind.rawValue) {
			if let tag = Library.tag(named: kind.rawValue, creating: true, in: context) {
				scan.addToTags(tag)
			}
		}
		context.saveQuietly()
	}

	/// True for the tags Rescriva adds by itself.
	static func isAutomatic(_ tag: ScanTag) -> Bool {
		guard let name = tag.name?.lowercased() else { return false }
		return AutoTag(rawValue: name) != nil
	}
}
