//
//  MarkRemap.swift
//  Rescriva (fork of Open Scanner)
//
//  Keeps Annotate's marks on the same spot of the paper when the page under
//  them is made again: turned, cropped differently from its original, or
//  split from a spread into two pages. Marks live on the stored page image
//  (0…1 from its top-left), so a point goes back through the old recipe —
//  its turn, then its perspective crop — to the original photo, and forward
//  through the new one. A turn alone is exact. After a new crop, rectangles
//  and ovals keep the box around their four moved corners, and stroke widths
//  follow the page's width on the photo. A mark the new crop leaves partly
//  or wholly off the page stays, out of sight (every view and the PDF clip
//  marks to the page), so a wider crop later brings it back. A split gives
//  each mark, whole, to the half its middle falls on.
//
//  The mapping is pure and unit-tested; PageReprocessor moves the stored
//  marks as it stores a page made again.
//
//  App-target only.
//

import CoreGraphics
import Foundation

/// Moves marks from one version of a page to the next (see the file header).
enum MarkRemap {
	/// Crops closer than this (normalized, per coordinate) are the same crop: a quad is stored to
	/// five decimals, so one read back can differ from the one the editor holds in the last of them.
	static let quadTolerance: CGFloat = 0.000_01

	/// Where a stored page lies on its original photo.
	struct Placement {
		/// The unturned page (the unit square) → the photo, both normalized from the top-left.
		let toOriginal: Homography
		/// The photo → the unturned page.
		let fromOriginal: Homography
		/// Clockwise quarter turns the page was given after its crop, 0...3.
		let quarterTurns: Int
		/// The page's width as stored (after its turn), in the photo's pixels.
		let width: CGFloat

		/// The page `recipe` makes from a photo of `originalSize` pixels; nil for an empty photo.
		init?(recipe: PageRecipe, originalSize: CGSize) {
			guard originalSize.width > 0, originalSize.height > 0 else { return nil }
			// The crop the page was really corrected with (a tiny or folded quad leaves it whole).
			let quad = FigureCrop.correctionQuad(recipe.quad)
			guard let map = Homography(unitSquareTo: quad), let inverse = map.inverse else { return nil }
			let turns = QuarterTurns.normalized(recipe.rotation)
			let width = Self.width(of: quad, quarterTurns: turns, originalSize: originalSize)
			guard width > 0, width.isFinite else { return nil }
			toOriginal = map
			fromOriginal = inverse
			quarterTurns = turns
			self.width = width
		}

		/// A point on the stored page → the same spot on the photo; nil past the crop's horizon.
		func originalPoint(_ point: CGPoint) -> CGPoint? {
			toOriginal.apply(QuadViewMapping.unrotated(point, quarterTurns: quarterTurns))
		}

		/// A spot on the photo → the stored page; nil past the crop's horizon.
		func pagePoint(_ point: CGPoint) -> CGPoint? {
			fromOriginal.apply(point).map { QuadViewMapping.rotated($0, quarterTurns: quarterTurns) }
		}

		/// The page's width as stored, measured on the photo: the mean of the crop's top and bottom
		/// edges, or of its sides once an odd number of turns has stood it on end.
		static func width(of quad: PageQuad, quarterTurns: Int, originalSize: CGSize) -> CGFloat {
			guard originalSize.width > 0, originalSize.height > 0 else { return 0 }
			func length(_ start: CGPoint, _ end: CGPoint) -> CGFloat {
				hypot((end.x - start.x) * originalSize.width, (end.y - start.y) * originalSize.height)
			}
			let across = (length(quad.topLeft, quad.topRight) + length(quad.bottomLeft, quad.bottomRight)) / 2
			let down = (length(quad.topLeft, quad.bottomLeft) + length(quad.topRight, quad.bottomRight)) / 2
			return QuarterTurns.normalized(quarterTurns) % 2 == 0 ? across : down
		}
	}

	// MARK: Turning

	/// `marks` on a stored page of `pageSize` pixels, once the page is turned `quarterTurns`
	/// clockwise: exact, every point moving with its pixel. Stroke widths, a share of the page's
	/// width, follow it when a quarter turn swaps its sides.
	static func turned(_ marks: [PageMark], quarterTurns: Int, pageSize: CGSize) -> [PageMark] {
		let turns = QuarterTurns.normalized(quarterTurns)
		guard turns != 0, !marks.isEmpty else { return marks }
		let sideways = turns % 2 == 1 && pageSize.width > 0 && pageSize.height > 0
		let widthScale = sideways ? Double(pageSize.width / pageSize.height) : 1
		return marks.map { mark in
			var moved = mark
			moved.points = mark.points.map { PageMark.quantized(QuadViewMapping.rotated($0, quarterTurns: turns)) }
			moved.width = mark.width * widthScale
			return moved
		}
	}

	// MARK: Cropping again

	/// `marks` on the page `old` made from a photo of `originalSize` pixels, moved onto the page
	/// `new` makes from it. Unchanged when the crop and the turn are (a cleanup change moves
	/// nothing), or when either page can't be placed on the photo. A mark the new crop leaves off
	/// the page is kept there, unseen, for a wider crop to bring back; only one that can't be moved
	/// at all (past the crop's horizon) goes.
	static func recropped(_ marks: [PageMark], from old: PageRecipe, to new: PageRecipe, originalSize: CGSize) -> [PageMark] {
		guard !marks.isEmpty, !sameGeometry(old, new),
			  let from = Placement(recipe: old, originalSize: originalSize),
			  let to = Placement(recipe: new, originalSize: originalSize) else { return marks }
		return marks.compactMap { moved($0, from: from, to: to) }
	}

	/// True when `a` and `b` place the page alike on the photo: the same crop (to the precision
	/// it's stored at) and the same turn.
	static func sameGeometry(_ a: PageRecipe, _ b: PageRecipe) -> Bool {
		guard QuarterTurns.normalized(a.rotation) == QuarterTurns.normalized(b.rotation) else { return false }
		let first = FigureCrop.correctionQuad(a.quad).corners
		let second = FigureCrop.correctionQuad(b.quad).corners
		return zip(first, second).allSatisfy { abs($0.x - $1.x) <= quadTolerance && abs($0.y - $1.y) <= quadTolerance }
	}

	/// `mark` moved from the page `from` places to the one `to` places; nil when it can't be: a
	/// line or shape reaching past the new crop's horizon (far off the page), or a stroke wholly
	/// beyond it. A stroke keeps the samples that can be moved.
	static func moved(_ mark: PageMark, from: Placement, to: Placement) -> PageMark? {
		guard let first = mark.points.first, let last = mark.points.last, to.width > 0 else { return nil }
		func carried(_ point: CGPoint) -> CGPoint? {
			from.originalPoint(point).flatMap(to.pagePoint)
		}
		var result = mark
		switch mark.kind {
		case .pen, .highlighter:
			let points = mark.points.compactMap(carried)
			guard !points.isEmpty else { return nil }
			result.points = points.map(PageMark.quantized)
		case .line, .arrow:
			guard let start = carried(first), let end = carried(last) else { return nil }
			result.points = [PageMark.quantized(start), PageMark.quantized(end)]
		case .rectangle, .ellipse:
			// Opposite corners of a box: move all four and keep the box around them.
			let box = CGRect(corner: first, opposite: last)
			let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
						   CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].compactMap(carried)
			guard corners.count == 4, let bounds = boundingBox(of: corners) else { return nil }
			result.points = [PageMark.quantized(CGPoint(x: bounds.minX, y: bounds.minY)),
							 PageMark.quantized(CGPoint(x: bounds.maxX, y: bounds.maxY))]
		}
		result.width = mark.width * Double(from.width / to.width)
		return result
	}

	// MARK: Splitting a spread

	/// `marks` on the spread `old` made, shared out between the pages `first` and `second` make
	/// from the same photo: each mark goes, whole, to the page its box's middle falls on (the
	/// nearer one when it's on neither), even when it's off that page. All of them stay on the
	/// first page, unmoved, when the pages can't be placed on the photo.
	static func split(_ marks: [PageMark], from old: PageRecipe, into first: PageRecipe, _ second: PageRecipe,
					  originalSize: CGSize) -> (first: [PageMark], second: [PageMark]) {
		guard !marks.isEmpty, let from = Placement(recipe: old, originalSize: originalSize),
			  let left = Placement(recipe: first, originalSize: originalSize),
			  let right = Placement(recipe: second, originalSize: originalSize) else { return (marks, []) }
		var pages: (first: [PageMark], second: [PageMark]) = ([], [])
		for mark in marks {
			let onFirst = moved(mark, from: from, to: left)
			let onSecond = moved(mark, from: from, to: right)
			if belongsOnFirst(onFirst, onSecond) {
				if let onFirst { pages.first.append(onFirst) }
			} else if let onSecond {
				pages.second.append(onSecond)
			}
		}
		return pages
	}

	/// True when a mark from a spread belongs on the first page: its middle is on it, or on neither
	/// page but nearer the first. Either may be nil, a mark that couldn't be moved onto that page.
	static func belongsOnFirst(_ first: PageMark?, _ second: PageMark?) -> Bool {
		guard let second, let secondMiddle = middle(of: second) else { return true }
		guard let first, let firstMiddle = middle(of: first) else { return false }
		return distanceOffPage(firstMiddle) <= distanceOffPage(secondMiddle)
	}

	// MARK: Boxes

	/// The box around `points`; nil when there are none.
	static func boundingBox(of points: [CGPoint]) -> CGRect? {
		guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
			  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
		return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
	}

	/// The middle of the box around the mark's points.
	static func middle(of mark: PageMark) -> CGPoint? {
		boundingBox(of: mark.points).map { CGPoint(x: $0.midX, y: $0.midY) }
	}

	/// How far `point` is from the page (0 on it), in page units.
	static func distanceOffPage(_ point: CGPoint) -> CGFloat {
		hypot(max(0, -point.x, point.x - 1), max(0, -point.y, point.y - 1))
	}
}

// MARK: - Stored marks

extension AnnotationStore {
	/// Replaces the page's marks with `move` of them, when it has any and they moved. Logged when
	/// they can't be saved: the page then keeps its marks where they were.
	func moveMarks(of pageID: UUID, _ move: ([PageMark]) -> [PageMark]) {
		let current = marks(for: pageID)
		guard !current.isEmpty else { return }
		let moved = move(current)
		guard moved != current else { return }
		do {
			try save(moved, for: pageID)
		} catch {
			Log.library.error("Couldn't move the annotations on page \(pageID): \(error)")
		}
	}

	/// After a spread is split, the page `pageID` (now the first half) keeps the marks `split`
	/// gives the first page, and the new page `newID` takes the rest. The new page's are saved
	/// first, so a failure leaves a mark on both pages rather than on neither.
	func splitMarks(of pageID: UUID, adding newID: UUID,
					_ split: ([PageMark]) -> (first: [PageMark], second: [PageMark])) {
		let current = marks(for: pageID)
		guard !current.isEmpty, pageID != newID else { return }
		let pages = split(current)
		do {
			try save(pages.second, for: newID)
			try save(pages.first, for: pageID)
		} catch {
			Log.library.error("Couldn't share out the annotations on page \(pageID): \(error)")
		}
	}

	/// Deletes the page's marks, for a page deleted for good (never one in Recently Deleted, which
	/// comes back with them). Logged when the file can't be removed.
	func removeMarks(for pageID: UUID) {
		do {
			try save([], for: pageID)
		} catch {
			Log.library.error("Couldn't remove the annotations for page \(pageID): \(error)")
		}
	}
}
