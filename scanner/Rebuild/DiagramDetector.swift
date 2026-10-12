//
//  DiagramDetector.swift
//  Rescriva (fork of Open Scanner)
//
//  The classical baseline for the plan's "whiteboard diagram to doc diagram"
//  pipeline (steps 2–7), with no ML model and no third-party code:
//
//  1. Ink mask: luminance against an integral-image local mean (plus a
//     chroma test for faded marker), so glare and paper shadow aren't ink.
//  2. Text vs drawing: ink components that sit inside an (inflated) OCR line
//     box are text, unless they frame other ink; what is left is drawing.
//  3. Shapes: Vision's contour detection on the gap-closed drawing ink. A hole
//     in the ink (a child contour) is a closed shape, classified from Vision's
//     polygon approximation of it: fill of its bounding box, corner gaps and
//     solidity. Table cells, the space a cycle of connectors encloses and
//     frames around other shapes are not nodes. Vision's rectangle detection
//     cross-checks, rescuing boxes whose outline gap is too wide to close.
//  4. Lines and arrows: drawing ink outside the shapes splits into strokes;
//     each stroke's ends are its farthest pair, and an end whose ink spreads
//     to both sides behind it carries an arrowhead (filled or a "V"). Arrows
//     Vision read as text ("→") between two shapes count too.
//  5–7. Labels by OCR word position, ends attached to the nearest shape, and
//     each shape's median stroke colour with a light tint as its fill.
//
//  A trained Core ML detector can later replace steps 3–4 without changing
//  `DetectedDiagram`. Foundation, CoreGraphics and Vision only; everything
//  is a pure function of its inputs, so it runs on a background task and in
//  a macOS harness.
//

import CoreGraphics
import Foundation
import Vision

/// What the detector found on one page.
struct DetectedDiagram: Sendable {
	/// The rebuilt graph. Node boxes are normalized to `frame` (0–1, top-left
	/// origin), `aspect` is the frame's width / height in pixels, the layout is
	/// `.faithful` and there is no caption.
	var diagram: Diagram
	/// Where the diagram sits on the page (page-normalized, top-left origin).
	var frame: NormalizedBox
	/// Indices into the `lines` passed to `detect` used as node or edge labels.
	var consumedLines: IndexSet
}

/// Finds a hand-drawn or whiteboard diagram on a cleaned, perspective-corrected
/// page and rebuilds it as a `Diagram` graph (see the file header for the
/// pipeline). Stateless; safe to call from any thread.
enum DiagramDetector {
	/// nil when the page has no diagram worth rebuilding (most text pages).
	static func detect(in image: CGImage, lines: [RecognizedLine]) -> DetectedDiagram? {
		guard image.width >= Tuning.minImageSide, image.height >= Tuning.minImageSide else { return nil }
		guard let page = Raster(image: image, maxSide: Tuning.workingMaxSide),
			  let layer = StrokeLayer(page: page, lines: lines) else { return nil }
		let search = findShapes(in: layer)
		let labelled = labelNodes(search.nodes, lines: lines, layer: layer)
		guard labelled.shapes.count >= Tuning.minNodesWithEdge else { return nil }
		let segments = findSegments(in: layer, nodes: labelled.shapes, others: search.others)
		let drawn = link(segments, shapes: labelled.shapes, layer: layer)
		let glyphs = glyphLinks(lines: lines, shapes: labelled.shapes, existing: drawn, layer: layer)
		let links = drawn + glyphs.links
		let taken = labelled.consumed.union(glyphs.consumed)
		let edgeText = labelEdges(links, lines: lines, taken: taken, shapes: labelled.shapes, layer: layer)
		let findings = Findings(shapes: labelled.shapes, nodeLabels: labelled.labels, links: links,
								edgeLabels: edgeText.labels, consumed: taken.union(edgeText.consumed))
		return assemble(findings, layer: layer)
	}
}

// MARK: - Tuning

extension DiagramDetector {
	/// Every named bound and threshold. Pixel values are in the working raster
	/// (the page scaled so its longer side is at most `workingMaxSide`).
	enum Tuning {
		// Bounds: every loop and every kept collection is capped by one of these.
		static let workingMaxSide = 1000
		static let minImageSide = 48
		static let maxComponents = 60_000
		static let maxContours = 4_000
		static let maxHoles = 80
		static let maxOutlinePoints = 160
		static let maxShapes = 40
		static let maxSegments = 64
		static let maxEdges = 64
		static let maxVisionRectangles = 16
		static let maxRunLength = 48
		static let maxColourSamples = 96
		static let maxSideSamples = 200
		static let maxWords = 64

		// Ink mask.
		static let inkWindowFraction = 1.0 / 24
		static let minInkContrast = 45.0
		static let relativeInkContrast = 0.18
		static let minColourContrast = 25.0
		static let minInkChroma = 60.0

		// Text separation.
		static let textInflation = 0.35
		static let minSpeckPixels = 6
		static let minDrawingFraction = 0.0008

		// Strokes.
		static let minGapRadius = 2
		static let maxGapRadius = 6
		static let bandStrokes = 1.5
		static let bandPixels = 2.0

		// Shapes.
		static let minShapePixels = 14.0
		static let minShapeFraction = 0.03
		static let maxShapeAreaFraction = 0.45
		static let maxShapeAspect = 12.0
		static let pageMarginPixels = 3.0
		static let outlineEpsilonPixels = 1.0
		static let minSolidity = 0.85
		static let rectangleFill = 0.86
		static let sharpCornerGap = 0.25
		static let roundedFill = 0.8
		static let roundedCornerGap = 0.5
		static let ellipseFill = 0.66..<0.86
		static let ellipseCornerGap = 0.25
		static let polygonFill = 0.38..<0.66
		static let diamondCornerGap = 0.45
		/// A parallelogram has two opposite corners sharp (gap below this) …
		static let parallelogramSharpGap = 0.2
		/// … and the other two cut off by the slant (gap at least this).
		static let parallelogramCutGap = 0.35
		static let parallelogramFill = 0.55..<0.95
		static let triangleCornerGap = 0.2
		static let triangleFarGap = 0.6
		static let containerAreaRatio = 0.8
		static let gridOverlap = 0.5

		// Vision rectangle cross-check.
		static let rectangleQuadratureTolerance: Float = 20
		static let rectangleConfidence: Float = 0.5
		static let rescueOverlap = 0.3
		static let rescueCoverage = 0.75
		static let rescueInnerShare = 0.5
		static let rescueInteriorInk = 0.15

		// Segments and arrowheads.
		static let minSegmentPixels = 12.0
		static let minSegmentFraction = 0.025
		static let maxThicknessStrokes = 3.5
		static let headReachStrokes = 7.0
		static let minHeadReach = 8.0
		static let headReachOfLength = 0.4
		static let headBackStart = 0.15
		static let headSpreadStrokes = 1.4
		static let headSpreadPixels = 2.0
		static let headMinSideShare = 0.6
		static let axisBaselineReaches = 2.5
		static let smallComponentReach = 2.5

		// Attachment.
		static let attachNearFraction = 0.035
		static let attachFarFraction = 0.075
		static let attachReachOfLength = 0.45
		static let rayFanRadians = 0.17

		// Labels.
		static let maxLabelLines = 4
		static let maxLabelCharacters = 80
		static let edgeLabelSpan = 0.1...0.9
		static let edgeLabelHeights = 1.5
		static let outlineMisreadCharacters = 2
		static let outlineMisreadHeight = 0.75
		static let edgeLabelStrokes = 3.0
		static let edgeLabelWidthOfLength = 1.5
		static let edgeLabelWidthOfPage = 0.25

		// Colour, frame and the quality gate.
		static let fillTint = 0.17
		static let defaultStroke = RGBColor(red: 0.2, green: 0.2, blue: 0.2)
		static let framePadFraction = 0.012
		static let minNodesWithEdge = 2
		static let minNodesAlone = 3
	}
}

// MARK: - Raster and bitmaps

extension DiagramDetector {
	/// The page scaled to working size: packed RGBA bytes and luminance, top row first.
	struct Raster {
		let width: Int
		let height: Int
		/// Pixel size of the image the raster was made from.
		let sourceSize: CGSize
		let rgba: [UInt8]
		let luma: [UInt8]

		init?(image: CGImage, maxSide: Int) {
			guard image.width > 0, image.height > 0, maxSide > 0 else { return nil }
			let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
			let w = max(1, Int((Double(image.width) * scale).rounded()))
			let h = max(1, Int((Double(image.height) * scale).rounded()))
			guard let bytes = Raster.draw(image, width: w, height: h) else { return nil }
			var luma = [UInt8](repeating: 0, count: w * h)
			for index in 0..<(w * h) {
				let base = index * 4
				let value = 0.2126 * Double(bytes[base]) + 0.7152 * Double(bytes[base + 1]) + 0.0722 * Double(bytes[base + 2])
				luma[index] = UInt8(max(0, min(255, value.rounded())))
			}
			width = w
			height = h
			sourceSize = CGSize(width: image.width, height: image.height)
			rgba = bytes
			self.luma = luma
		}

		/// Draws `image` over white into an sRGB context, then copies the rows
		/// into a packed buffer this raster owns.
		private static func draw(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
			guard let space = CGColorSpace(name: CGColorSpace.sRGB),
				  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
										  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
			let rect = CGRect(x: 0, y: 0, width: width, height: height)
			context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
			context.fill(rect)
			context.interpolationQuality = .high
			context.draw(image, in: rect)
			guard let drawn = context.makeImage(), let data = drawn.dataProvider?.data as Data? else { return nil }
			let rowBytes = drawn.bytesPerRow
			guard rowBytes >= width * 4, data.count >= rowBytes * height else { return nil }
			let source = [UInt8](data)
			var packed = [UInt8](repeating: 0, count: width * height * 4)
			for y in 0..<height {
				let from = y * rowBytes
				packed.replaceSubrange((y * width * 4)..<((y + 1) * width * 4), with: source[from..<(from + width * 4)])
			}
			return packed
		}

		/// A normalized, top-left-origin page box in raster pixels.
		func pixelRect(_ box: CGRect) -> CGRect {
			CGRect(x: box.minX * Double(width), y: box.minY * Double(height),
				   width: box.width * Double(width), height: box.height * Double(height))
		}

		/// Ink is clearly darker than the local mean (an integral-image box
		/// mean), or a little darker and clearly coloured (a faded marker), so
		/// whiteboard glare, paper shadow and ruled lines don't count.
		func inkMask() -> Bitmap {
			guard width > 0, height > 0 else { return Bitmap(width: 0, height: 0, bits: []) }
			let integral = integralImage()
			let half = max(4, Int(Double(max(width, height)) * Tuning.inkWindowFraction))
			let stride = width + 1
			var bits = [Bool](repeating: false, count: width * height)
			for y in 0..<height {
				let y0 = max(0, y - half), y1 = min(height, y + half + 1)
				for x in 0..<width {
					let x0 = max(0, x - half), x1 = min(width, x + half + 1)
					let sum = integral[y1 * stride + x1] - integral[y0 * stride + x1]
						- integral[y1 * stride + x0] + integral[y0 * stride + x0]
					let mean = Double(sum) / Double((x1 - x0) * (y1 - y0))
					bits[y * width + x] = isInk(at: y * width + x, localMean: mean)
				}
			}
			return Bitmap(width: width, height: height, bits: bits)
		}

		private func isInk(at index: Int, localMean mean: Double) -> Bool {
			let contrast = mean - Double(luma[index])
			guard contrast >= Tuning.minColourContrast else { return false }
			guard contrast < max(Tuning.minInkContrast, Tuning.relativeInkContrast * mean) else { return true }
			let base = index * 4
			let high = max(rgba[base], rgba[base + 1], rgba[base + 2])
			let low = min(rgba[base], rgba[base + 1], rgba[base + 2])
			return Double(high) - Double(low) >= Tuning.minInkChroma
		}

		/// Summed-area table of `luma`, (width + 1) × (height + 1).
		private func integralImage() -> [Int] {
			let stride = width + 1
			var integral = [Int](repeating: 0, count: stride * (height + 1))
			guard width > 0, height > 0 else { return integral }
			for y in 0..<height {
				var row = 0
				for x in 0..<width {
					row += Int(luma[y * width + x])
					integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row
				}
			}
			return integral
		}
	}

	/// A binary image in working-raster pixels, row-major, top row first.
	struct Bitmap {
		let width: Int
		let height: Int
		var bits: [Bool]

		init(width: Int, height: Int, bits: [Bool]) {
			let count = max(0, width) * max(0, height)
			self.width = max(0, width)
			self.height = max(0, height)
			self.bits = bits.count == count ? bits : [Bool](repeating: false, count: count)
		}

		/// Reads an 8-bit gray image: `true` where the gray value is at least `threshold`.
		init?(gray image: CGImage, threshold: UInt8) {
			guard image.bitsPerPixel == 8, let data = image.dataProvider?.data as Data? else { return nil }
			let w = image.width, h = image.height, rowBytes = image.bytesPerRow
			guard rowBytes >= w, data.count >= rowBytes * h else { return nil }
			let bytes = [UInt8](data)
			var bits = [Bool](repeating: false, count: w * h)
			for y in 0..<h {
				for x in 0..<w where bytes[y * rowBytes + x] >= threshold {
					bits[y * w + x] = true
				}
			}
			self.init(width: w, height: h, bits: bits)
		}

		var count: Int { bits.reduce(0) { $0 + ($1 ? 1 : 0) } }

		subscript(x: Int, y: Int) -> Bool {
			guard x >= 0, y >= 0, x < width, y < height else { return false }
			return bits[y * width + x]
		}

		/// Square dilation by `radius`: a running-window max along rows, then columns.
		func dilated(by radius: Int) -> Bitmap {
			guard radius > 0, width > 0, height > 0 else { return self }
			let rows = Bitmap.spread(bits, lines: height, length: width, lineStep: width, step: 1, radius: radius)
			let both = Bitmap.spread(rows, lines: width, length: height, lineStep: 1, step: width, radius: radius)
			return Bitmap(width: width, height: height, bits: both)
		}

		/// One pass of a window max: `lines` runs of `length` cells, cell `i` of
		/// line `l` at `l * lineStep + i * step`.
		private static func spread(_ source: [Bool], lines: Int, length: Int, lineStep: Int, step: Int, radius: Int) -> [Bool] {
			var out = [Bool](repeating: false, count: source.count)
			guard lines > 0, length > 0, source.count >= lines * length else { return out }
			for line in 0..<lines {
				let base = line * lineStep
				var inWindow = 0
				for i in 0..<min(radius, length) where source[base + i * step] {
					inWindow += 1
				}
				for i in 0..<length {
					let enter = i + radius
					if enter < length, source[base + enter * step] { inWindow += 1 }
					let leave = i - radius - 1
					if leave >= 0, source[base + leave * step] { inWindow -= 1 }
					out[base + i * step] = inWindow > 0
				}
			}
			return out
		}

		/// Black ink on white, 8-bit gray, for Vision.
		func grayImage() -> CGImage? {
			guard width > 0, height > 0 else { return nil }
			let bytes = bits.map { $0 ? UInt8(0) : UInt8(255) }
			guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
			return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
						   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
						   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
		}
	}

	/// Bounding box and pixel count of one 8-connected ink component.
	struct Component {
		var minX: Int
		var minY: Int
		var maxX: Int
		var maxY: Int
		var count: Int

		var width: Int { maxX - minX + 1 }
		var height: Int { maxY - minY + 1 }
		var rect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
	}

	/// 8-connected component labels of a bitmap, by flood fill over an explicit
	/// stack (no recursion). Label 0 is background; label k is `components[k - 1]`.
	struct ComponentMap {
		let labels: [Int32]
		let components: [Component]

		/// nil when the bitmap has more than `limit` components (too busy to be a diagram).
		init?(_ mask: Bitmap, limit: Int) {
			guard mask.width > 0, mask.height > 0, limit > 0 else { return nil }
			var labels = [Int32](repeating: 0, count: mask.bits.count)
			var components: [Component] = []
			var stack: [Int] = []
			for start in 0..<mask.bits.count where mask.bits[start] && labels[start] == 0 {
				guard components.count < limit else { return nil }
				let label = Int32(components.count + 1)
				components.append(ComponentMap.flood(from: start, label: label, mask: mask, labels: &labels, stack: &stack))
			}
			self.labels = labels
			self.components = components
		}

		/// Labels every pixel 8-connected to `start`. Each pixel is pushed at
		/// most once, so the loop is bounded by the bitmap's pixel count.
		private static func flood(from start: Int, label: Int32, mask: Bitmap, labels: inout [Int32], stack: inout [Int]) -> Component {
			let w = mask.width, h = mask.height
			var component = Component(minX: start % w, minY: start / w, maxX: start % w, maxY: start / w, count: 0)
			labels[start] = label
			stack.removeAll(keepingCapacity: true)
			stack.append(start)
			let maxSteps = mask.bits.count
			var steps = 0
			while steps < maxSteps, let index = stack.popLast() {
				steps += 1
				let x = index % w, y = index / w
				component.count += 1
				component.minX = min(component.minX, x)
				component.maxX = max(component.maxX, x)
				component.minY = min(component.minY, y)
				component.maxY = max(component.maxY, y)
				for ny in max(0, y - 1)...min(h - 1, y + 1) {
					for nx in max(0, x - 1)...min(w - 1, x + 1) {
						let neighbour = ny * w + nx
						guard mask.bits[neighbour], labels[neighbour] == 0 else { continue }
						labels[neighbour] = label
						stack.append(neighbour)
					}
				}
			}
			return component
		}

		/// The label at a pixel, 0 off the bitmap.
		func label(x: Int, y: Int, width: Int) -> Int32 {
			guard x >= 0, y >= 0, x < width, y * width + x < labels.count else { return 0 }
			return labels[y * width + x]
		}
	}
}

// MARK: - Text vs drawing

extension DiagramDetector {
	/// The page's ink split into drawing strokes (text removed), plus the
	/// measurements every later step scales by.
	struct StrokeLayer {
		let page: Raster
		/// Drawing ink: text glyphs, specks and anything touching the page edge removed.
		let drawing: Bitmap
		/// `drawing` dilated by `gapRadius`, so small gaps in hand-drawn outlines close.
		let closed: Bitmap
		/// Typical stroke thickness in pixels.
		let stroke: Double
		let gapRadius: Int

		var pageMin: Double { Double(min(page.width, page.height)) }
		/// A hole's bounds grown by this reach the stroke's centre line.
		var grow: Double { Double(gapRadius) + stroke / 2 }
		/// Ink within this distance of a hole's outline belongs to the shape.
		var band: Double { Double(gapRadius) + Tuning.bandStrokes * stroke + Tuning.bandPixels }
		var minShapeSide: Double { max(Tuning.minShapePixels, Tuning.minShapeFraction * pageMin) }
		var minSegmentLength: Double { max(Tuning.minSegmentPixels, Tuning.minSegmentFraction * pageMin) }
		var attachNear: Double { max(band + 2 * stroke, Tuning.attachNearFraction * pageMin) }
		var attachFar: Double { Tuning.attachFarFraction * pageMin }

		init?(page: Raster, lines: [RecognizedLine]) {
			guard page.width > 2, page.height > 2 else { return nil }
			let ink = page.inkMask()
			guard let map = ComponentMap(ink, limit: Tuning.maxComponents) else { return nil }
			let minFrameSide = max(Tuning.minShapePixels, Tuning.minShapeFraction * Double(min(page.width, page.height)))
			let drawing = StrokeLayer.separate(ink, map: map, textRects: lines.map { page.pixelRect($0.box) }, minFrameSide: minFrameSide)
			let minimum = Tuning.minDrawingFraction * Double(page.width * page.height)
			guard Double(drawing.count) >= minimum, let stroke = StrokeLayer.strokeWidth(of: drawing) else { return nil }
			self.page = page
			self.drawing = drawing
			self.stroke = stroke
			gapRadius = max(Tuning.minGapRadius, min(Tuning.maxGapRadius, Int(stroke.rounded())))
			closed = drawing.dilated(by: gapRadius)
		}

		/// Keeps the ink components that are drawing: big enough, clear of the
		/// page edge, and either outside every inflated OCR line box or framing
		/// other ink (a box drawn tight round its label that Vision read into the line).
		static func separate(_ ink: Bitmap, map: ComponentMap, textRects: [CGRect], minFrameSide: Double) -> Bitmap {
			guard ink.width > 0, ink.height > 0 else { return ink }
			let inflated = textRects.map { rect -> CGRect in
				let margin = Tuning.textInflation * rect.height + 1
				return rect.insetBy(dx: -margin, dy: -margin)
			}
			let keep = map.components.indices.map { index -> Bool in
				let component = map.components[index]
				guard component.count >= Tuning.minSpeckPixels, component.minX > 1, component.minY > 1,
					  component.maxX < ink.width - 2, component.maxY < ink.height - 2 else { return false }
				let rect = component.rect
				guard inflated.contains(where: { $0.contains(rect) }) else { return true }
				return frames(index, map: map, width: ink.width, minSide: minFrameSide)
			}
			var bits = ink.bits
			for index in 0..<bits.count where bits[index] {
				let label = Int(map.labels[index])
				bits[index] = label > 0 && label <= keep.count && keep[label - 1]
			}
			return Bitmap(width: ink.width, height: ink.height, bits: bits)
		}

		/// The component has ink on all four sides of another component's centre.
		private static func frames(_ index: Int, map: ComponentMap, width: Int, minSide: Double) -> Bool {
			let frame = map.components[index]
			guard Double(min(frame.width, frame.height)) >= minSide else { return false }
			let label = Int32(index + 1)
			for other in map.components where other.count >= Tuning.minSpeckPixels
				&& other.minX > frame.minX && other.maxX < frame.maxX && other.minY > frame.minY && other.maxY < frame.maxY {
				let x = (other.minX + other.maxX) / 2, y = (other.minY + other.maxY) / 2
				let left = hits(label, map: map, from: x, y, step: (-1, 0), count: x - frame.minX, width: width)
				let right = hits(label, map: map, from: x, y, step: (1, 0), count: frame.maxX - x, width: width)
				let up = hits(label, map: map, from: x, y, step: (0, -1), count: y - frame.minY, width: width)
				let down = hits(label, map: map, from: x, y, step: (0, 1), count: frame.maxY - y, width: width)
				if left && right && up && down { return true }
			}
			return false
		}

		/// Whether walking `count` pixels from (x, y) by `step` meets a pixel labelled `label`.
		private static func hits(_ label: Int32, map: ComponentMap, from x: Int, _ y: Int, step: (Int, Int), count: Int, width: Int) -> Bool {
			guard count > 0 else { return false }
			for k in 1...count where map.label(x: x + step.0 * k, y: y + step.1 * k, width: width) == label {
				return true
			}
			return false
		}

		/// Typical stroke thickness: the median length of short ink runs along
		/// rows and columns (a stroke crossed at right angles gives its width).
		static func strokeWidth(of mask: Bitmap) -> Double? {
			guard mask.width > 0, mask.height > 0 else { return nil }
			var histogram = [Int](repeating: 0, count: Tuning.maxRunLength + 1)
			addRuns(of: mask, horizontal: true, to: &histogram)
			addRuns(of: mask, horizontal: false, to: &histogram)
			let total = histogram.reduce(0, +)
			guard total > 0 else { return nil }
			var seen = 0
			for length in 1...Tuning.maxRunLength {
				seen += histogram[length]
				if seen * 2 >= total { return Double(length) }
			}
			return Double(Tuning.maxRunLength)
		}

		private static func addRuns(of mask: Bitmap, horizontal: Bool, to histogram: inout [Int]) {
			let lines = horizontal ? mask.height : mask.width
			let length = horizontal ? mask.width : mask.height
			guard lines > 0, length > 0, histogram.count > Tuning.maxRunLength else { return }
			for line in 0..<lines {
				var run = 0
				for i in 0...length {
					let on = i < length && (horizontal ? mask.bits[line * mask.width + i] : mask.bits[i * mask.width + line])
					if on {
						run += 1
						continue
					}
					if run > 0 && run <= Tuning.maxRunLength { histogram[run] += 1 }
					run = 0
				}
			}
		}
	}
}

// MARK: - Shapes

extension DiagramDetector {
	/// A hole in the gap-closed drawing ink, from Vision, in working pixels.
	struct Hole {
		/// The hole's boundary, simplified (at most `maxOutlinePoints` points).
		var outline: [CGPoint]
		var bounds: CGRect
		var area: Double
		/// Area over convex-hull area: 1 for a convex outline, low for a star
		/// or a cloud; glyphs touching the stroke only dent it a little.
		var solidity: Double
	}

	/// One closed shape that can be a diagram node.
	struct Shape {
		var kind: Diagram.Shape
		/// The hole's outline: just inside the drawn stroke.
		var outline: [CGPoint]
		/// The drawn shape's box: the hole's bounds grown to the stroke's centre line.
		var box: CGRect
	}

	/// The closed regions on the page.
	struct ShapeSearch {
		/// Shapes that can be diagram nodes.
		var nodes: [Shape]
		/// Outlines of other closed regions (containers, table cells, shapes that
		/// fit no IR kind): their ink is neither node nor connector.
		var others: [[CGPoint]]
	}

	static func findShapes(in layer: StrokeLayer) -> ShapeSearch {
		guard let image = layer.closed.grayImage(), let found = holes(in: image, layer: layer) else {
			return ShapeSearch(nodes: [], others: [])
		}
		let plausible = Array(found.filter { isPlausibleShapeBox(grownBox($0, layer), layer: layer) }.prefix(Tuning.maxHoles))
		let holeBoxes = plausible.map { grownBox($0, layer) }
		let rescued = rescuedRectangles(in: image, layer: layer, known: holeBoxes)
		let grid = gridMembers(holeBoxes + rescued.map(\.box), layer: layer)
		let region = regionMembers(plausible, grid: Array(grid.prefix(plausible.count)), layer: layer)
		var nodes: [Shape] = []
		var others: [[CGPoint]] = []
		for (index, hole) in plausible.enumerated() where !region[index] {
			guard !grid[index], let kind = classify(hole) else {
				others.append(hole.outline)
				continue
			}
			let sharp = kind == .diamond && !isTriangleCornerPattern(cornerGaps(hole.outline, in: hole.bounds))
			nodes.append(Shape(kind: kind, outline: hole.outline, box: sharp ? diamondBox(hole, layer) : holeBoxes[index]))
		}
		for (offset, shape) in rescued.enumerated() where !grid[plausible.count + offset] {
			nodes.append(shape)
		}
		return withoutContainers(ShapeSearch(nodes: nodes, others: others))
	}

	/// Moves frames and groups (shapes holding another node's centre) from the
	/// nodes to the other outlines, and keeps the largest `maxShapes` nodes.
	static func withoutContainers(_ search: ShapeSearch) -> ShapeSearch {
		let nodes = search.nodes
		guard !nodes.isEmpty else { return search }
		let container = nodes.map { isContainer($0, among: nodes) }
		var kept: [Shape] = []
		var others = search.others
		for (index, shape) in nodes.enumerated() {
			if container[index] { others.append(shape.outline) } else { kept.append(shape) }
		}
		kept.sort { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
		return ShapeSearch(nodes: Array(kept.prefix(Tuning.maxShapes)), others: others)
	}

	static func grownBox(_ hole: Hole, _ layer: StrokeLayer) -> CGRect {
		hole.bounds.insetBy(dx: -layer.grow, dy: -layer.grow)
	}

	/// A diamond's sharp vertices sit further out than the stroke offset: by
	/// offset / sin(half the vertex angle), i.e. offset × diagonal / side.
	static func diamondBox(_ hole: Hole, _ layer: StrokeLayer) -> CGRect {
		let w = hole.bounds.width, h = hole.bounds.height
		guard w > 0, h > 0 else { return grownBox(hole, layer) }
		let diagonal = hypot(w, h)
		return hole.bounds.insetBy(dx: -layer.grow * diagonal / h, dy: -layer.grow * diagonal / w)
	}

	/// Child contours (holes) from `VNDetectContoursRequest`; nil if Vision fails.
	static func holes(in image: CGImage, layer: StrokeLayer) -> [Hole]? {
		guard image.width > 0, image.height > 0 else { return nil }
		let request = VNDetectContoursRequest()
		request.detectsDarkOnLight = true
		request.contrastAdjustment = 1
		request.maximumImageDimension = max(image.width, image.height)
		do {
			try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
		} catch {
			return nil
		}
		guard let observation = request.results?.first else { return [] }
		var found: [Hole] = []
		for index in 0..<min(observation.contourCount, Tuning.maxContours) {
			guard let hole = hole(at: index, in: observation, layer: layer) else { continue }
			found.append(hole)
		}
		return found
	}

	private static func hole(at index: Int, in observation: VNContoursObservation, layer: StrokeLayer) -> Hole? {
		let contour: VNContour
		do {
			contour = try observation.contour(at: index)
		} catch {
			return nil
		}
		// Even index-path lengths are holes: the ink's outer boundary is depth 0.
		guard contour.indexPath.count % 2 == 0, contour.pointCount >= 8 else { return nil }
		let size = CGSize(width: layer.page.width, height: layer.page.height)
		let points = contour.normalizedPoints.map { CGPoint(x: Double($0.x) * size.width, y: (1 - Double($0.y)) * size.height) }
		let bounds = Geometry.bounds(points)
		let minSide = layer.minShapeSide - 2 * layer.grow
		guard bounds.width >= minSide, bounds.height >= minSide,
			  let outline = approximate(contour, epsilon: Tuning.outlineEpsilonPixels, size: size) else { return nil }
		let area = Geometry.area(points)
		let hullArea = Geometry.area(Geometry.convexHull(outline))
		return Hole(outline: outline, bounds: bounds, area: area, solidity: hullArea > 0 ? min(1, area / hullArea) : 0)
	}

	/// Vision's polygon approximation at `epsilon` pixels, as working pixels
	/// (closing point dropped, decimated to `maxOutlinePoints`).
	private static func approximate(_ contour: VNContour, epsilon: Double, size: CGSize) -> [CGPoint]? {
		guard epsilon > 0, size.width > 0, size.height > 0 else { return nil }
		let simplified: VNContour
		do {
			simplified = try contour.polygonApproximation(epsilon: Float(epsilon / Double(max(size.width, size.height))))
		} catch {
			return nil
		}
		var points = simplified.normalizedPoints.map { CGPoint(x: Double($0.x) * size.width, y: (1 - Double($0.y)) * size.height) }
		if points.count > 3, let first = points.first, let last = points.last, Geometry.distance(first, last) < 1 {
			points.removeLast()
		}
		guard points.count >= 3 else { return nil }
		let stride = max(1, Int((Double(points.count) / Double(Tuning.maxOutlinePoints)).rounded(.up)))
		return stride == 1 ? points : Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
	}

	static func isPlausibleShapeBox(_ box: CGRect, layer: StrokeLayer) -> Bool {
		let w = Double(layer.page.width), h = Double(layer.page.height)
		guard box.width >= layer.minShapeSide, box.height >= layer.minShapeSide else { return false }
		guard box.width * box.height <= Tuning.maxShapeAreaFraction * w * h else { return false }
		guard max(box.width / box.height, box.height / box.width) <= Tuning.maxShapeAspect else { return false }
		let margin = Tuning.pageMarginPixels
		return box.minX > margin && box.minY > margin && box.maxX < w - margin && box.maxY < h - margin
	}

	/// Shape kind from the hole's polygon approximation: how it fills its
	/// bounding box (rectangularity), how far it stays from the box's corners
	/// (corner rounding: a circle or capsule stays 0.41 of the half side away,
	/// a diamond 0.7) and its solidity.
	static func classify(_ hole: Hole) -> Diagram.Shape? {
		let b = hole.bounds
		guard b.width > 0, b.height > 0, hole.outline.count >= 3, hole.solidity >= Tuning.minSolidity else { return nil }
		let fill = hole.area / (b.width * b.height)
		let gaps = cornerGaps(hole.outline, in: b)
		guard gaps.count == 4, let nearest = gaps.min() else { return nil }
		let mean = gaps.reduce(0, +) / 4
		let capsuleFill = 1 - (1 - Double.pi / 4) * min(b.width, b.height) / max(b.width, b.height)
		if fill >= Tuning.rectangleFill && mean < Tuning.sharpCornerGap { return .rectangle }
		if Tuning.parallelogramFill.contains(fill) && isParallelogramCornerPattern(gaps) { return .parallelogram }
		if fill >= max(Tuning.roundedFill, (capsuleFill + Double.pi / 4) / 2) && mean < Tuning.roundedCornerGap {
			return .roundedRectangle
		}
		if Tuning.ellipseFill.contains(fill) && nearest >= Tuning.ellipseCornerGap { return .ellipse }
		guard Tuning.polygonFill.contains(fill) else { return nil }
		if nearest >= Tuning.diamondCornerGap { return .diamond }
		// A triangle: the IR has no triangle, and a diamond is its nearest node shape.
		return isTriangleCornerPattern(gaps) ? .diamond : nil
	}

	/// Distance from each corner of `b` (clockwise from top-left) to the outline,
	/// as a fraction of half the shorter side: 0 for a sharp rectangle, about
	/// 0.41 for a capsule or circle, 0.7 and more for a diamond.
	static func cornerGaps(_ outline: [CGPoint], in b: CGRect) -> [Double] {
		let half = min(b.width, b.height) / 2
		guard half > 0, outline.count >= 3 else { return [] }
		let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
					   CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
		return corners.map { Geometry.polygonDistance(from: $0, outline) / half }
	}

	/// Two opposite corners sharp and the other two cut off by the slant.
	private static func isParallelogramCornerPattern(_ gaps: [Double]) -> Bool {
		guard gaps.count == 4 else { return false }
		let sharp = gaps.map { $0 < Tuning.parallelogramSharpGap }
		let cut = gaps.map { $0 >= Tuning.parallelogramCutGap }
		return (sharp[0] && sharp[2] && cut[1] && cut[3]) || (sharp[1] && sharp[3] && cut[0] && cut[2])
	}

	/// Exactly two adjacent box corners sit on the outline and the other two
	/// are far from it: a triangle with one side along the box.
	private static func isTriangleCornerPattern(_ gaps: [Double]) -> Bool {
		let tight = gaps.indices.filter { gaps[$0] < Tuning.triangleCornerGap }
		guard tight.count == 2, gaps.filter({ $0 >= Tuning.triangleFarGap }).count == 2 else { return false }
		let apart = tight[1] - tight[0]
		return apart == 1 || apart == 3
	}

	/// Boxes that share a side with a neighbour, as table cells do.
	static func gridMembers(_ boxes: [CGRect], layer: StrokeLayer) -> [Bool] {
		var member = [Bool](repeating: false, count: boxes.count)
		guard boxes.count >= 2 else { return member }
		let tolerance = 2 * layer.grow + layer.stroke + 2
		for i in boxes.indices {
			for j in boxes.indices where j > i && sharesSide(boxes[i], boxes[j], tolerance: tolerance) {
				member[i] = true
				member[j] = true
			}
		}
		return member
	}

	private static func sharesSide(_ a: CGRect, _ b: CGRect, tolerance: Double) -> Bool {
		let gapX = max(a.minX, b.minX) - min(a.maxX, b.maxX)
		let gapY = max(a.minY, b.minY) - min(a.maxY, b.maxY)
		let sideBySide = abs(gapX) <= tolerance && -gapY >= Tuning.gridOverlap * min(a.height, b.height)
		let stacked = abs(gapY) <= tolerance && -gapX >= Tuning.gridOverlap * min(a.width, b.width)
		return sideBySide || stacked
	}

	/// Holes walled in partly by another, smaller hole's ink: the space a cycle
	/// of touching connectors encloses between nodes, not a node itself.
	static func regionMembers(_ holes: [Hole], grid: [Bool], layer: StrokeLayer) -> [Bool] {
		var region = [Bool](repeating: false, count: holes.count)
		guard holes.count >= 2, grid.count == holes.count else { return region }
		let wall = 2 * layer.grow + layer.stroke + 2
		for i in holes.indices where !grid[i] {
			let reach = holes[i].bounds.insetBy(dx: -wall, dy: -wall)
			for j in holes.indices where j != i && holes[j].area < holes[i].area && reach.intersects(holes[j].bounds) {
				// A smaller hole that only sits inside (a node in a frame) doesn't wall this one in.
				guard touches(holes[i], holes[j], within: wall) else { continue }
				region[i] = true
				break
			}
		}
		return region
	}

	private static func touches(_ a: Hole, _ b: Hole, within distance: Double) -> Bool {
		guard !a.outline.isEmpty, !b.outline.isEmpty else { return false }
		return b.outline.contains { Geometry.polygonDistance(from: $0, a.outline) <= distance }
	}

	/// A shape whose box holds another node's centre is a frame or group, not a node.
	static func isContainer(_ shape: Shape, among shapes: [Shape]) -> Bool {
		let area = shape.box.width * shape.box.height
		guard area > 0 else { return false }
		return shapes.contains { other in
			other.box.width * other.box.height < Tuning.containerAreaRatio * area
				&& shape.box.contains(Geometry.centre(other.box))
		}
	}

	/// Vision's rectangle detection as a cross-check: a box it finds that no
	/// hole explains (an outline gap too wide to close) is kept when the drawn
	/// ink really runs along all four sides.
	static func rescuedRectangles(in image: CGImage, layer: StrokeLayer, known: [CGRect]) -> [Shape] {
		let request = VNDetectRectanglesRequest()
		request.maximumObservations = Tuning.maxVisionRectangles
		request.minimumSize = Float(Tuning.minShapeFraction)
		request.minimumAspectRatio = Float(1 / Tuning.maxShapeAspect)
		request.quadratureTolerance = Tuning.rectangleQuadratureTolerance
		request.minimumConfidence = Tuning.rectangleConfidence
		do {
			try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
		} catch {
			return []
		}
		var rescued: [Shape] = []
		for observation in (request.results ?? []).prefix(Tuning.maxVisionRectangles) {
			let normalized = observation.boundingBox
			let box = layer.page.pixelRect(CGRect(x: normalized.minX, y: 1 - normalized.maxY,
												   width: normalized.width, height: normalized.height))
			let inner = box.insetBy(dx: layer.grow, dy: layer.grow)
			guard inner.width > 0, inner.height > 0, isPlausibleShapeBox(box, layer: layer),
				  !(known + rescued.map(\.box)).contains(where: { Geometry.overlapOfSmaller($0, box) > Tuning.rescueOverlap }),
				  outlineCoverage(of: box, layer: layer) >= Tuning.rescueCoverage,
				  isHollow(box, layer: layer) else { continue }
			let outline = [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
						   CGPoint(x: inner.maxX, y: inner.maxY), CGPoint(x: inner.minX, y: inner.maxY)]
			rescued.append(Shape(kind: .rectangle, outline: outline, box: box))
		}
		return rescued
	}

	/// The smallest, over the four sides of `box`, of the fraction of points
	/// along the side with gap-closed ink nearby.
	private static func outlineCoverage(of box: CGRect, layer: StrokeLayer) -> Double {
		guard box.width > 0, box.height > 0 else { return 0 }
		let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
					   CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
		let reach = Int((layer.grow + layer.stroke).rounded(.up))
		var worst = 1.0
		for side in 0..<4 {
			let a = corners[side], b = corners[(side + 1) % 4]
			let samples = max(2, min(Tuning.maxSideSamples, Int(Geometry.distance(a, b))))
			var hits = 0
			for k in 0..<samples {
				let t = (Double(k) + 0.5) / Double(samples)
				let x = Int((a.x + (b.x - a.x) * t).rounded()), y = Int((a.y + (b.y - a.y) * t).rounded())
				if hasInk(near: x, y, reach: reach, in: layer.closed) { hits += 1 }
			}
			worst = min(worst, Double(hits) / Double(samples))
		}
		return worst
	}

	/// An outline, not a filled bar: room inside, and almost no drawing ink there.
	private static func isHollow(_ box: CGRect, layer: StrokeLayer) -> Bool {
		let inner = box.insetBy(dx: layer.grow + layer.stroke + 1, dy: layer.grow + layer.stroke + 1)
		let minInner = Tuning.rescueInnerShare * layer.minShapeSide
		guard inner.width >= minInner, inner.height >= minInner else { return false }
		let columns = max(2, min(Tuning.maxSideSamples / 4, Int(inner.width)))
		let rows = max(2, min(Tuning.maxSideSamples / 4, Int(inner.height)))
		var inked = 0
		for row in 0..<rows {
			for column in 0..<columns {
				let x = Int(inner.minX + inner.width * (Double(column) + 0.5) / Double(columns))
				let y = Int(inner.minY + inner.height * (Double(row) + 0.5) / Double(rows))
				if layer.drawing[x, y] { inked += 1 }
			}
		}
		return Double(inked) <= Tuning.rescueInteriorInk * Double(rows * columns)
	}

	private static func hasInk(near x: Int, _ y: Int, reach: Int, in mask: Bitmap) -> Bool {
		guard reach >= 0 else { return false }
		for dy in -reach...reach {
			for dx in -reach...reach where mask[x + dx, y + dy] {
				return true
			}
		}
		return false
	}
}

// MARK: - Lines and arrows

extension DiagramDetector {
	/// One open stroke between two ends, with arrowhead evidence at each.
	struct Segment {
		var start: CGPoint
		var end: CGPoint
		/// Unit directions pointing out of the stroke at each end.
		var startOutward: CGVector
		var endOutward: CGVector
		var startHead: Bool
		var endHead: Bool

		var length: Double { Geometry.distance(start, end) }
	}

	/// The ink of one connector candidate.
	struct Stroke {
		var label: Int32
		var pixels: [CGPoint]
	}

	/// What an arrowhead test reads: the connector ink and its components.
	struct HeadProbe {
		let mask: Bitmap
		let map: ComponentMap
		let label: Int32
		let stroke: Double

		/// Ink of this stroke, or of a small separate piece (a "V" drawn apart from its shaft).
		func counts(x: Int, y: Int, reach: Double) -> Bool {
			let found = map.label(x: x, y: y, width: mask.width)
			guard found != 0 else { return false }
			guard found != label else { return true }
			let index = Int(found) - 1
			guard index >= 0, index < map.components.count else { return false }
			let piece = map.components[index]
			return Double(max(piece.width, piece.height)) <= Tuning.smallComponentReach * reach
		}
	}

	static func findSegments(in layer: StrokeLayer, nodes: [Shape], others: [[CGPoint]]) -> [Segment] {
		guard !nodes.isEmpty, let removal = shapeMask(nodes: nodes, others: others, layer: layer),
			  removal.bits.count == layer.drawing.bits.count else { return [] }
		var bits = layer.drawing.bits
		for index in 0..<bits.count where removal.bits[index] {
			bits[index] = false
		}
		let mask = Bitmap(width: layer.drawing.width, height: layer.drawing.height, bits: bits)
		guard let map = ComponentMap(mask, limit: Tuning.maxComponents) else { return [] }
		return gatherStrokes(map: map, layer: layer).compactMap { stroke in
			segment(from: stroke, probe: HeadProbe(mask: mask, map: map, label: stroke.label, stroke: layer.stroke), layer: layer)
		}
	}

	/// Pixels to clear before tracing connectors: each node filled and its
	/// outline band, and the outline band of every other closed region.
	static func shapeMask(nodes: [Shape], others: [[CGPoint]], layer: StrokeLayer) -> Bitmap? {
		let w = layer.page.width, h = layer.page.height
		guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
													space: CGColorSpaceCreateDeviceGray(),
													bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
		context.setFillColor(gray: 0, alpha: 1)
		context.fill(CGRect(x: 0, y: 0, width: w, height: h))
		context.setFillColor(gray: 1, alpha: 1)
		context.setStrokeColor(gray: 1, alpha: 1)
		context.setLineWidth(2 * layer.band)
		context.setLineJoin(.round)
		let outlines = nodes.map { ($0.outline, true) } + others.map { ($0, false) }
		for (outline, filled) in outlines {
			guard let first = outline.first else { continue }
			context.beginPath()
			context.move(to: CGPoint(x: first.x, y: Double(h) - first.y))
			for point in outline.dropFirst() {
				context.addLine(to: CGPoint(x: point.x, y: Double(h) - point.y))
			}
			context.closePath()
			context.drawPath(using: filled ? .fillStroke : .stroke)
		}
		guard let image = context.makeImage() else { return nil }
		return Bitmap(gray: image, threshold: 128)
	}

	/// The connector components long enough to matter, longest first, with their pixels.
	static func gatherStrokes(map: ComponentMap, layer: StrokeLayer) -> [Stroke] {
		let minLength = layer.minSegmentLength
		let candidates = map.components.indices.filter { index in
			let c = map.components[index]
			return Double(max(c.width, c.height)) >= minLength * 0.7 && c.count >= Tuning.minSpeckPixels
		}
		let chosen = candidates.sorted {
			max(map.components[$0].width, map.components[$0].height) > max(map.components[$1].width, map.components[$1].height)
		}.prefix(Tuning.maxSegments)
		guard !chosen.isEmpty else { return [] }
		var slot = [Int](repeating: -1, count: map.components.count + 1)
		var strokes: [Stroke] = []
		for index in chosen {
			slot[index + 1] = strokes.count
			strokes.append(Stroke(label: Int32(index + 1), pixels: []))
		}
		let w = layer.page.width
		for index in 0..<map.labels.count where map.labels[index] != 0 {
			let target = slot[Int(map.labels[index])]
			guard target >= 0 else { continue }
			strokes[target].pixels.append(CGPoint(x: index % w, y: index / w))
		}
		return strokes
	}

	/// A stroke's two ends (its farthest pair), checked for thinness, with an
	/// arrowhead test at each end.
	static func segment(from stroke: Stroke, probe: HeadProbe, layer: StrokeLayer) -> Segment? {
		guard let ends = Geometry.farthestPair(stroke.pixels) else { return nil }
		let length = Geometry.distance(ends.0, ends.1)
		guard length >= layer.minSegmentLength else { return nil }
		let thickness = Double(stroke.pixels.count) / length
		guard thickness <= Tuning.maxThicknessStrokes * layer.stroke + 3 else { return nil }
		let reach = min(max(Tuning.headReachStrokes * layer.stroke, Tuning.minHeadReach), Tuning.headReachOfLength * length)
		let startIn = localAxis(at: ends.0, other: ends.1, pixels: stroke.pixels, reach: reach)
		let endIn = localAxis(at: ends.1, other: ends.0, pixels: stroke.pixels, reach: reach)
		return Segment(start: ends.0, end: ends.1,
					   startOutward: CGVector(dx: -startIn.dx, dy: -startIn.dy),
					   endOutward: CGVector(dx: -endIn.dx, dy: -endIn.dy),
					   startHead: hasHead(at: ends.0, inward: startIn, reach: reach, probe: probe),
					   endHead: hasHead(at: ends.1, inward: endIn, reach: reach, probe: probe))
	}

	/// Unit direction into the stroke from `tip`: toward the centroid of the
	/// stroke's pixels one to 2.5 head-lengths in, or toward the other end.
	static func localAxis(at tip: CGPoint, other: CGPoint, pixels: [CGPoint], reach: Double) -> CGVector {
		let fallback = Geometry.unit(CGVector(dx: other.x - tip.x, dy: other.y - tip.y)) ?? CGVector(dx: 1, dy: 0)
		guard reach > 0, !pixels.isEmpty else { return fallback }
		var sumX = 0.0, sumY = 0.0, count = 0
		for point in pixels {
			let d = Geometry.distance(point, tip)
			guard d >= reach, d <= Tuning.axisBaselineReaches * reach else { continue }
			sumX += point.x
			sumY += point.y
			count += 1
		}
		guard count > 0 else { return fallback }
		let centroid = CGVector(dx: sumX / Double(count) - tip.x, dy: sumY / Double(count) - tip.y)
		return Geometry.unit(centroid) ?? fallback
	}

	/// An arrowhead (filled triangle or "V") spreads ink to both sides of the
	/// shaft just behind the tip; a plain end, a bend or a hook does not.
	static func hasHead(at tip: CGPoint, inward: CGVector, reach: Double, probe: HeadProbe) -> Bool {
		guard reach >= 2, probe.stroke > 0 else { return false }
		let radius = Int(reach.rounded(.up))
		let cx = Int(tip.x.rounded()), cy = Int(tip.y.rounded())
		var left = 0.0, right = 0.0
		for y in (cy - radius)...(cy + radius) {
			for x in (cx - radius)...(cx + radius) where probe.mask[x, y] {
				guard probe.counts(x: x, y: y, reach: reach) else { continue }
				let vx = Double(x) - tip.x, vy = Double(y) - tip.y
				let along = vx * inward.dx + vy * inward.dy
				guard along >= Tuning.headBackStart * reach, along <= reach else { continue }
				let across = vy * inward.dx - vx * inward.dy
				left = max(left, across)
				right = max(right, -across)
			}
		}
		// A head is symmetric about its shaft, so the two sides are judged
		// together (a slightly tilted axis moves spread from one to the other).
		let need = max(Tuning.headSpreadStrokes * probe.stroke, probe.stroke + Tuning.headSpreadPixels)
		return left + right >= 2 * need && min(left, right) >= Tuning.headMinSideShare * need
	}
}

// MARK: - Graph

extension DiagramDetector {
	/// An edge between two shapes (indices), before labels and flags.
	struct Link {
		var from: Int
		var to: Int
		/// False when no arrowhead, or one at each end, was found.
		var directed: Bool
		/// The stroke's end at `from` and at `to`.
		var start: CGPoint
		var end: CGPoint
		/// An arrowhead was found at both ends (a double-headed arrow).
		var bothHeads = false

		func sameConnection(as other: Link) -> Bool {
			let samePair = (from == other.from && to == other.to) || (from == other.to && to == other.from)
			guard samePair else { return false }
			return !directed || !other.directed || from == other.from
		}
	}

	static func link(_ segments: [Segment], shapes: [Shape], layer: StrokeLayer) -> [Link] {
		guard !segments.isEmpty, shapes.count >= 2 else { return [] }
		var links: [Link] = []
		for segment in segments.prefix(Tuning.maxSegments) {
			guard links.count < Tuning.maxEdges,
				  let a = attach(segment.start, outward: segment.startOutward, length: segment.length, shapes: shapes, layer: layer),
				  let b = attach(segment.end, outward: segment.endOutward, length: segment.length, shapes: shapes, layer: layer),
				  a != b else { continue }
			let candidate = orient(segment, a, b, shapes: shapes)
			guard !links.contains(where: { $0.sameConnection(as: candidate) }) else { continue }
			links.append(candidate)
		}
		return links
	}

	/// One arrowhead sets the direction; with none or two, the edge runs in
	/// reading order (left to right, or top to bottom), remembers whether both
	/// ends had a head, and is flagged later.
	static func orient(_ segment: Segment, _ a: Int, _ b: Int, shapes: [Shape]) -> Link {
		if segment.endHead && !segment.startHead {
			return Link(from: a, to: b, directed: true, start: segment.start, end: segment.end)
		}
		if segment.startHead && !segment.endHead {
			return Link(from: b, to: a, directed: true, start: segment.end, end: segment.start)
		}
		let pa = Geometry.centre(shapes[a].box), pb = Geometry.centre(shapes[b].box)
		let aFirst = abs(pb.x - pa.x) >= abs(pb.y - pa.y) ? pa.x <= pb.x : pa.y <= pb.y
		let both = segment.startHead && segment.endHead
		return aFirst ? Link(from: a, to: b, directed: false, start: segment.start, end: segment.end, bothHeads: both)
			: Link(from: b, to: a, directed: false, start: segment.end, end: segment.start, bothHeads: both)
	}

	/// Arrows Vision read as text ("→", "->", "↓", "↔"…) sitting between two
	/// shapes on one row or column; a line of nothing but such arrows is consumed.
	static func glyphLinks(lines: [RecognizedLine], shapes: [Shape], existing: [Link], layer: StrokeLayer)
		-> (links: [Link], consumed: IndexSet) {
		var links: [Link] = []
		var consumed = IndexSet()
		guard shapes.count >= 2 else { return (links, consumed) }
		for (index, line) in lines.enumerated() {
			let rect = layer.page.pixelRect(line.box)
			let spans = wordSpans(line.text, in: rect)
			var linked = false
			for span in spans {
				guard existing.count + links.count < Tuning.maxEdges, let arrow = arrowGlyph(span.word),
					  let candidate = glyphLink(at: CGPoint(x: span.x, y: rect.midY), arrow: arrow, reach: rect.height, shapes: shapes, layer: layer),
					  !(existing + links).contains(where: { $0.sameConnection(as: candidate) }) else { continue }
				links.append(candidate)
				linked = true
			}
			if linked && spans.allSatisfy({ arrowGlyph($0.word) != nil }) { consumed.insert(index) }
		}
		return (links, consumed)
	}

	/// Direction of an arrow written as text: (dx, dy, one-way).
	static func arrowGlyph(_ word: String) -> (dx: Double, dy: Double, oneWay: Bool)? {
		switch word {
		case "→", "->", "-->", "⟶", "=>", "➔", "➜", "⇒": return (1, 0, true)
		case "←", "<-", "<--", "⟵", "<=", "⇐": return (-1, 0, true)
		case "↓", "⇓": return (0, 1, true)
		case "↑", "⇑": return (0, -1, true)
		case "↔", "<->", "⟷", "⇔": return (1, 0, false)
		case "↕", "⇕": return (0, 1, false)
		default: return nil
		}
	}

	/// The nearest shape ahead of and behind an arrow glyph, both level with it.
	private static func glyphLink(at point: CGPoint, arrow: (dx: Double, dy: Double, oneWay: Bool), reach: Double,
								  shapes: [Shape], layer: StrokeLayer) -> Link? {
		guard reach > 0, !shapes.isEmpty else { return nil }
		let limit = layer.attachFar + reach
		func gap(_ shape: Shape, sign: Double) -> Double? {
			let box = shape.box
			let level = arrow.dx != 0 ? (box.minY <= point.y && point.y <= box.maxY) : (box.minX <= point.x && point.x <= box.maxX)
			guard level else { return nil }
			let ahead = arrow.dx != 0 ? (sign * arrow.dx > 0 ? box.minX - point.x : point.x - box.maxX)
				: (sign * arrow.dy > 0 ? box.minY - point.y : point.y - box.maxY)
			return ahead >= -layer.stroke && ahead <= limit ? ahead : nil
		}
		let forward = shapes.indices.compactMap { index in gap(shapes[index], sign: 1).map { (index, $0) } }.min { $0.1 < $1.1 }
		let backward = shapes.indices.compactMap { index in gap(shapes[index], sign: -1).map { (index, $0) } }.min { $0.1 < $1.1 }
		guard let to = forward?.0, let from = backward?.0, to != from else { return nil }
		let segment = Segment(start: point, end: point, startOutward: CGVector(dx: -arrow.dx, dy: -arrow.dy),
							  endOutward: CGVector(dx: arrow.dx, dy: arrow.dy), startHead: !arrow.oneWay, endHead: true)
		return orient(segment, from, to, shapes: shapes)
	}

	/// The shape a stroke end belongs to: one whose outline is close, or one
	/// that the stroke points at (a small fan of rays) within reach.
	static func attach(_ point: CGPoint, outward: CGVector, length: Double, shapes: [Shape], layer: StrokeLayer) -> Int? {
		guard length > 0, !shapes.isEmpty else { return nil }
		let near = layer.attachNear
		let reach = max(near, min(Tuning.attachReachOfLength * length, layer.attachFar))
		let rays = [-Tuning.rayFanRadians, 0, Tuning.rayFanRadians].map { Geometry.rotate(outward, by: $0) }
		var best: (index: Int, distance: Double)?
		for (index, shape) in shapes.enumerated() {
			let gap = max(0, Geometry.polygonDistance(from: point, shape.outline) - layer.grow)
			var score = gap <= near ? gap : Double.infinity
			for ray in rays {
				guard let t = Geometry.rayHit(from: point, direction: ray, polygon: shape.outline) else { continue }
				let along = max(0, t - layer.grow)
				if along <= reach { score = min(score, along) }
			}
			guard score.isFinite else { continue }
			if best.map({ score < $0.distance }) ?? true { best = (index, score) }
		}
		return best?.index
	}
}

// MARK: - Labels

extension DiagramDetector {
	/// Node labels, with the shapes that survived the text-frame check.
	struct NodeLabels {
		var shapes: [Shape]
		var labels: [String]
		var consumed: IndexSet
	}

	/// Labels every shape; a shape holding more text than a node label (a
	/// framed paragraph or callout) is not a node and is dropped.
	static func labelNodes(_ shapes: [Shape], lines: [RecognizedLine], layer: StrokeLayer) -> NodeLabels {
		let first = collectLabels(shapes, lines: lines, page: layer.page)
		let kept = shapes.indices.filter {
			first.lineCounts[$0] <= Tuning.maxLabelLines && first.labels[$0].count <= Tuning.maxLabelCharacters
		}
		guard kept.count < shapes.count else {
			return NodeLabels(shapes: shapes, labels: first.labels, consumed: first.consumed)
		}
		let remaining = kept.map { shapes[$0] }
		let second = collectLabels(remaining, lines: lines, page: layer.page)
		return NodeLabels(shapes: remaining, labels: second.labels, consumed: second.consumed)
	}

	/// Each line whose box sits inside a shape labels it (lines joined in
	/// reading order); a line spanning a row of shapes is split by word position.
	static func collectLabels(_ shapes: [Shape], lines: [RecognizedLine], page: Raster)
		-> (labels: [String], lineCounts: [Int], consumed: IndexSet) {
		var pieces = [[(y: Double, x: Double, text: String)]](repeating: [], count: shapes.count)
		var consumed = IndexSet()
		guard !shapes.isEmpty else { return ([], [], consumed) }
		for (index, line) in lines.enumerated() {
			let rect = page.pixelRect(line.box)
			let assigned = assign(line.text, rect: rect, shapes: shapes)
			guard !assigned.isEmpty else { continue }
			consumed.insert(index)
			for (shape, text) in assigned {
				pieces[shape].append((rect.midY, rect.minX, text))
			}
		}
		let labels = pieces.map { list in
			list.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
		}
		return (labels, pieces.map(\.count), consumed)
	}

	/// The shapes a line labels. Each word goes to the shape under its estimated
	/// position (characters assumed even width), so a row of boxes Vision read
	/// as one line splits correctly. A line with real words outside every shape
	/// is a sentence beside the diagram, not a label, and labels nothing.
	static func assign(_ text: String, rect: CGRect, shapes: [Shape]) -> [(Int, String)] {
		guard rect.width > 0, rect.height > 0, !text.isEmpty else { return [] }
		let candidates = shapes.indices.filter { index in
			let box = shapes[index].box
			return box.minY <= rect.midY && rect.midY <= box.maxY && box.intersects(rect)
		}
		guard !candidates.isEmpty else { return [] }
		// A character or two as tall as the shape is its outline read as text
		// (a capsule's end as "C", a side as "|"): consumed, but no label.
		let compact = text.filter { !$0.isWhitespace }
		if compact.count <= Tuning.outlineMisreadCharacters,
		   let outline = candidates.first(where: { rect.height >= Tuning.outlineMisreadHeight * shapes[$0].box.height }) {
			return [(outline, "")]
		}
		var words: [Int: [String]] = [:]
		for span in wordSpans(text, in: rect) {
			let hits = candidates.filter { shapes[$0].box.minX <= span.x && span.x <= shapes[$0].box.maxX }
			guard let hit = hits.min(by: { shapes[$0].box.width < shapes[$1].box.width }) else {
				if span.word.contains(where: { $0.isLetter || $0.isNumber }) { return [] }
				continue
			}
			words[hit, default: []].append(span.word)
		}
		return words.keys.sorted().compactMap { key in
			let label = cleanLabel(words[key, default: []].joined(separator: " "))
			return label.isEmpty ? nil : (key, label)
		}
	}

	/// Each word of a line with the estimated x of its centre (Vision gives
	/// line boxes only, so characters are assumed to be of even width).
	static func wordSpans(_ text: String, in rect: CGRect) -> [(word: String, x: Double)] {
		let total = Double(text.count)
		guard total > 0, rect.width > 0 else { return [] }
		var offset = 0
		var spans: [(word: String, x: Double)] = []
		for word in text.split(separator: " ", omittingEmptySubsequences: false).prefix(Tuning.maxWords) {
			defer { offset += word.count + 1 }
			guard !word.isEmpty else { continue }
			spans.append((String(word), rect.minX + rect.width * (Double(offset) + Double(word.count) / 2) / total))
		}
		return spans
	}

	/// Trims arrows and bullets from the ends, and the box's own sides when
	/// Vision read them as brackets or bars: "(product)" → "product".
	static func cleanLabel(_ raw: String) -> String {
		let edges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "→←↔↕•·|—–_"))
		var label = raw.trimmingCharacters(in: edges)
		guard let first = label.first, let last = label.last else { return label }
		let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
		let closers = Set(pairs.values)
		if let closer = pairs[first], last == closer, label.count >= 2 {
			label = String(label.dropFirst().dropLast())
		} else if let closer = pairs[first], !label.contains(closer) {
			label = String(label.dropFirst())
		} else if closers.contains(last), !label.contains(where: { pairs[$0] != nil }) {
			label = String(label.dropLast())
		}
		return label.trimmingCharacters(in: edges)
	}

	/// The nearest unused line beside the middle of each edge's stroke, clear of every shape.
	static func labelEdges(_ links: [Link], lines: [RecognizedLine], taken: IndexSet, shapes: [Shape], layer: StrokeLayer)
		-> (labels: [String?], consumed: IndexSet) {
		var used = taken
		var labels: [String?] = []
		guard !links.isEmpty else { return ([], IndexSet()) }
		for link in links {
			var best: (index: Int, distance: Double)?
			for (index, line) in lines.enumerated() where !used.contains(index) {
				let rect = layer.page.pixelRect(line.box)
				guard let d = edgeLabelDistance(rect, link: link, shapes: shapes, layer: layer) else { continue }
				if best.map({ d < $0.distance }) ?? true { best = (index, d) }
			}
			guard let chosen = best else {
				labels.append(nil)
				continue
			}
			used.insert(chosen.index)
			labels.append(lines[chosen.index].text)
		}
		return (labels, used.subtracting(taken))
	}

	private static func edgeLabelDistance(_ rect: CGRect, link: Link, shapes: [Shape], layer: StrokeLayer) -> Double? {
		let dx = link.end.x - link.start.x, dy = link.end.y - link.start.y
		let lengthSquared = dx * dx + dy * dy
		guard lengthSquared > 0, rect.height > 0 else { return nil }
		let length = lengthSquared.squareRoot()
		guard rect.width <= max(Tuning.edgeLabelWidthOfLength * length, Tuning.edgeLabelWidthOfPage * Double(layer.page.width)),
			  !shapes.contains(where: { $0.box.intersects(rect) }) else { return nil }
		let c = Geometry.centre(rect)
		let t = ((c.x - link.start.x) * dx + (c.y - link.start.y) * dy) / lengthSquared
		guard Tuning.edgeLabelSpan.contains(t) else { return nil }
		// From the stroke to the nearest point of the text box.
		let foot = CGPoint(x: link.start.x + t * dx, y: link.start.y + t * dy)
		let nearest = CGPoint(x: min(max(foot.x, rect.minX), rect.maxX), y: min(max(foot.y, rect.minY), rect.maxY))
		let distance = Geometry.distance(foot, nearest)
		let limit = max(Tuning.edgeLabelHeights * rect.height, Tuning.edgeLabelStrokes * layer.stroke)
		return distance <= limit ? distance : nil
	}
}

// MARK: - Assembly

extension DiagramDetector {
	/// Everything found on the page, before the quality gate.
	struct Findings {
		var shapes: [Shape]
		var nodeLabels: [String]
		var links: [Link]
		var edgeLabels: [String?]
		var consumed: IndexSet
	}

	/// The diagram's frame on the page, in working pixels.
	struct Frame {
		let pixels: CGRect
		let page: Raster

		var box: NormalizedBox {
			NormalizedBox(x: pixels.minX / Double(page.width), y: pixels.minY / Double(page.height),
						  width: pixels.width / Double(page.width), height: pixels.height / Double(page.height))
		}

		/// Width / height in the source image's pixels.
		var aspect: Double {
			let box = self.box
			guard box.height > 0, page.sourceSize.height > 0 else { return 1 }
			return (box.width * page.sourceSize.width) / (box.height * page.sourceSize.height)
		}

		func normalize(_ rect: CGRect) -> NormalizedBox {
			guard pixels.width > 0, pixels.height > 0 else { return NormalizedBox(x: 0, y: 0, width: 0, height: 0) }
			return NormalizedBox(x: (rect.minX - pixels.minX) / pixels.width, y: (rect.minY - pixels.minY) / pixels.height,
								 width: rect.width / pixels.width, height: rect.height / pixels.height)
		}
	}

	/// Drops shapes with neither a label nor an edge, applies the quality gate
	/// (≥ 2 nodes and ≥ 1 edge, or ≥ 3 nodes) and builds the IR.
	static func assemble(_ f: Findings, layer: StrokeLayer) -> DetectedDiagram? {
		guard f.shapes.count == f.nodeLabels.count, f.links.count == f.edgeLabels.count else { return nil }
		var degree = [Int](repeating: 0, count: f.shapes.count)
		for link in f.links {
			degree[link.from] += 1
			degree[link.to] += 1
		}
		let kept = f.shapes.indices.filter { !f.nodeLabels[$0].isEmpty || degree[$0] > 0 }
		guard kept.count >= Tuning.minNodesAlone || (kept.count >= Tuning.minNodesWithEdge && !f.links.isEmpty) else { return nil }
		let ordered = readingOrder(kept, shapes: f.shapes)
		var rank: [Int: Int] = [:]
		for (position, index) in ordered.enumerated() {
			rank[index] = position
		}
		let frame = frameFor(ordered.map { f.shapes[$0].box }, links: f.links, layer: layer)
		let nodes = ordered.map { index in
			node(f.shapes[index], label: f.nodeLabels[index], id: "n\((rank[index] ?? 0) + 1)", frame: frame, layer: layer)
		}
		let linkOrder = f.links.indices.sorted {
			((rank[f.links[$0].from] ?? 0), (rank[f.links[$0].to] ?? 0)) < ((rank[f.links[$1].from] ?? 0), (rank[f.links[$1].to] ?? 0))
		}
		let edges = linkOrder.enumerated().map { position, index in
			edge(f.links[index], id: "e\(position + 1)", label: f.edgeLabels[index], rank: rank, labels: f.nodeLabels)
		}
		let diagram = Diagram(nodes: nodes, edges: edges, layout: .faithful, caption: nil, aspect: frame.aspect)
		return DetectedDiagram(diagram: diagram, frame: frame.box, consumedLines: f.consumed)
	}

	/// Rows top to bottom (a new row starts half a median node height down), left to right within a row.
	static func readingOrder(_ indices: [Int], shapes: [Shape]) -> [Int] {
		let heights = indices.map { shapes[$0].box.height }.sorted()
		guard !heights.isEmpty else { return indices }
		let band = heights[heights.count / 2] / 2
		let byY = indices.sorted { shapes[$0].box.midY < shapes[$1].box.midY }
		var rows: [[Int]] = []
		var rowTop = -Double.infinity
		for index in byY {
			let y = shapes[index].box.midY
			if rows.isEmpty || y - rowTop > band {
				rows.append([])
				rowTop = y
			}
			rows[rows.count - 1].append(index)
		}
		return rows.flatMap { row in row.sorted { shapes[$0].box.midX < shapes[$1].box.midX } }
	}

	static func frameFor(_ boxes: [CGRect], links: [Link], layer: StrokeLayer) -> Frame {
		let pageRect = CGRect(x: 0, y: 0, width: layer.page.width, height: layer.page.height)
		guard var union = boxes.first else { return Frame(pixels: pageRect, page: layer.page) }
		for box in boxes.dropFirst() {
			union = union.union(box)
		}
		for link in links {
			union = union.union(CGRect(origin: link.start, size: .zero)).union(CGRect(origin: link.end, size: .zero))
		}
		let pad = Tuning.framePadFraction * Double(max(layer.page.width, layer.page.height))
		let framed = union.insetBy(dx: -pad, dy: -pad).intersection(pageRect)
		return Frame(pixels: framed.isNull ? pageRect : framed, page: layer.page)
	}

	static func node(_ shape: Shape, label: String, id: String, frame: Frame, layer: StrokeLayer) -> Diagram.Node {
		let stroke = strokeColour(of: shape, layer: layer)
		return Diagram.Node(id: id, label: label, shape: shape.kind, box: frame.normalize(shape.box), stroke: stroke, fill: tint(stroke))
	}

	static func edge(_ link: Link, id: String, label: String?, rank: [Int: Int], labels: [String]) -> Diagram.Edge {
		let from = "n\((rank[link.from] ?? 0) + 1)", to = "n\((rank[link.to] ?? 0) + 1)"
		guard !link.directed else { return Diagram.Edge(id: id, from: from, to: to, label: label, direction: .forward) }
		let a = displayName(labels[link.from]), b = displayName(labels[link.to])
		if link.bothHeads {
			return Diagram.Edge(id: id, from: from, to: to, label: label, flag: bothWaysFlag(from: a, to: b), direction: .both)
		}
		return Diagram.Edge(id: id, from: from, to: to, label: label, flag: plainLineFlag(from: a, to: b), direction: .none)
	}

	static func displayName(_ label: String) -> String {
		label.isEmpty ? String(localized: "Untitled") : label
	}

	/// The review sheet for a stroke with no arrowhead: most likely a plain line.
	static func plainLineFlag(from a: String, to b: String) -> RescrivaFlag {
		RescrivaFlag(kind: .edge,
				  title: String(localized: "Is this an arrow?"),
				  detail: String(localized: "No arrowhead was drawn"),
				  read: "\(a) — \(b)",
				  options: [
					RescrivaFlag.Option(label: String(localized: "Plain line"), note: String(localized: "most likely"), edgeAction: .plain),
					RescrivaFlag.Option(label: "\(a) → \(b)", edgeAction: .keep),
					RescrivaFlag.Option(label: "\(b) → \(a)", edgeAction: .reverse),
					RescrivaFlag.Option(label: String(localized: "No line"), note: String(localized: "remove it"), edgeAction: .remove),
				  ])
	}

	/// The review sheet for a stroke with a head at each end.
	static func bothWaysFlag(from a: String, to b: String) -> RescrivaFlag {
		RescrivaFlag(kind: .edge,
				  title: String(localized: "Which way does this arrow go?"),
				  detail: String(localized: "There's a head at each end"),
				  read: "\(a) ↔ \(b)",
				  options: [
					RescrivaFlag.Option(label: String(localized: "Both ways"), note: String(localized: "most likely"), edgeAction: .both),
					RescrivaFlag.Option(label: "\(a) → \(b)", edgeAction: .keep),
					RescrivaFlag.Option(label: "\(b) → \(a)", edgeAction: .reverse),
					RescrivaFlag.Option(label: String(localized: "No line"), note: String(localized: "remove it"), edgeAction: .remove),
				  ])
	}
}

// MARK: - Colour

extension DiagramDetector {
	/// The median colour of the darkest drawing pixel found stepping outward
	/// from points on the shape's outline (the marker's core, not its antialiased edge).
	static func strokeColour(of shape: Shape, layer: StrokeLayer) -> RGBColor {
		guard !shape.outline.isEmpty else { return Tuning.defaultStroke }
		let centre = Geometry.centre(shape.box)
		let steps = Int((layer.grow + 2 * layer.stroke + 2).rounded(.up))
		let stride = max(1, shape.outline.count / Tuning.maxColourSamples)
		var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []
		for point in Swift.stride(from: 0, to: shape.outline.count, by: stride).map({ shape.outline[$0] }) {
			guard let out = Geometry.unit(CGVector(dx: point.x - centre.x, dy: point.y - centre.y)),
				  let pixel = darkestInk(from: point, direction: out, steps: steps, layer: layer) else { continue }
			reds.append(layer.page.rgba[pixel * 4])
			greens.append(layer.page.rgba[pixel * 4 + 1])
			blues.append(layer.page.rgba[pixel * 4 + 2])
		}
		guard !reds.isEmpty else { return Tuning.defaultStroke }
		return RGBColor(red: median(reds), green: median(greens), blue: median(blues))
	}

	private static func darkestInk(from point: CGPoint, direction: CGVector, steps: Int, layer: StrokeLayer) -> Int? {
		guard steps >= 0 else { return nil }
		var darkest: Int?
		for step in 0...steps {
			let x = Int((point.x + direction.dx * Double(step)).rounded())
			let y = Int((point.y + direction.dy * Double(step)).rounded())
			guard layer.drawing[x, y] else { continue }
			let pixel = y * layer.page.width + x
			if darkest.map({ layer.page.luma[pixel] < layer.page.luma[$0] }) ?? true { darkest = pixel }
		}
		return darkest
	}

	private static func median(_ values: [UInt8]) -> Double {
		guard !values.isEmpty else { return 0 }
		let sorted = values.sorted()
		return Double(sorted[sorted.count / 2]) / 255
	}

	/// A light tint of the stroke for the fill (ink → wash in the sample).
	static func tint(_ colour: RGBColor) -> RGBColor {
		let t = Tuning.fillTint
		return RGBColor(red: 1 - t * (1 - colour.red), green: 1 - t * (1 - colour.green), blue: 1 - t * (1 - colour.blue))
	}
}

// MARK: - Geometry

extension DiagramDetector {
	/// Plane-geometry helpers in working pixels.
	enum Geometry {
		static func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

		static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

		static func unit(_ v: CGVector) -> CGVector? {
			let length = hypot(v.dx, v.dy)
			guard length > 1e-9 else { return nil }
			return CGVector(dx: v.dx / length, dy: v.dy / length)
		}

		static func rotate(_ v: CGVector, by angle: Double) -> CGVector {
			CGVector(dx: v.dx * cos(angle) - v.dy * sin(angle), dy: v.dx * sin(angle) + v.dy * cos(angle))
		}

		static func segmentDistance(from p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
			let dx = b.x - a.x, dy = b.y - a.y
			let lengthSquared = dx * dx + dy * dy
			guard lengthSquared > 0 else { return distance(p, a) }
			let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
			return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
		}

		/// Distance to the polygon's boundary, 0 inside it.
		static func polygonDistance(from p: CGPoint, _ polygon: [CGPoint]) -> Double {
			guard polygon.count >= 2 else { return .infinity }
			guard !contains(polygon, p) else { return 0 }
			var best = Double.infinity
			for i in polygon.indices {
				best = min(best, segmentDistance(from: p, polygon[i], polygon[(i + 1) % polygon.count]))
			}
			return best
		}

		/// Even-odd point-in-polygon test.
		static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
			guard polygon.count >= 3 else { return false }
			var inside = false
			var j = polygon.count - 1
			for i in polygon.indices {
				let a = polygon[i], b = polygon[j]
				if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
					inside.toggle()
				}
				j = i
			}
			return inside
		}

		/// Distance along the ray to its nearest crossing of the polygon's boundary.
		static func rayHit(from p: CGPoint, direction d: CGVector, polygon: [CGPoint]) -> Double? {
			guard polygon.count >= 3 else { return nil }
			var best: Double?
			for i in polygon.indices {
				let a = polygon[i], b = polygon[(i + 1) % polygon.count]
				let ex = b.x - a.x, ey = b.y - a.y
				let denominator = d.dx * ey - d.dy * ex
				guard abs(denominator) > 1e-9 else { continue }
				let wx = a.x - p.x, wy = a.y - p.y
				let t = (wx * ey - wy * ex) / denominator
				let u = (wx * d.dy - wy * d.dx) / denominator
				guard t > 0, u >= 0, u <= 1 else { continue }
				best = min(best ?? t, t)
			}
			return best
		}

		/// Shoelace area.
		static func area(_ polygon: [CGPoint]) -> Double {
			guard polygon.count >= 3 else { return 0 }
			var twice = 0.0
			for i in polygon.indices {
				let a = polygon[i], b = polygon[(i + 1) % polygon.count]
				twice += a.x * b.y - b.x * a.y
			}
			return abs(twice) / 2
		}

		/// Andrew's monotone chain. Each point is pushed once per chain, so the
		/// pops are bounded by the point count.
		static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
			guard points.count >= 3 else { return points }
			let sorted = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
			let lower = halfHull(sorted)
			let upper = halfHull(sorted.reversed())
			return Array(lower.dropLast()) + Array(upper.dropLast())
		}

		private static func halfHull(_ points: [CGPoint]) -> [CGPoint] {
			var chain: [CGPoint] = []
			guard !points.isEmpty else { return chain }
			let maxPops = points.count
			var pops = 0
			for point in points {
				while pops < maxPops, chain.count >= 2, cross(chain[chain.count - 2], chain[chain.count - 1], point) <= 0 {
					chain.removeLast()
					pops += 1
				}
				chain.append(point)
			}
			return chain
		}

		/// z of (b − a) × (c − a): positive for a counter-clockwise turn.
		static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
			(b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
		}

		static func bounds(_ points: [CGPoint]) -> CGRect {
			guard let first = points.first else { return .null }
			var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
			for point in points {
				minX = min(minX, point.x)
				minY = min(minY, point.y)
				maxX = max(maxX, point.x)
				maxY = max(maxY, point.y)
			}
			return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
		}

		/// Intersection area over the smaller rectangle's area.
		static func overlapOfSmaller(_ a: CGRect, _ b: CGRect) -> Double {
			let overlap = a.intersection(b)
			let smaller = min(a.width * a.height, b.width * b.height)
			guard !overlap.isNull, smaller > 0 else { return 0 }
			return overlap.width * overlap.height / smaller
		}

		/// The two ends of a stroke: the point farthest from the centroid, the
		/// point farthest from that, then the point farthest from the second.
		static func farthestPair(_ points: [CGPoint]) -> (CGPoint, CGPoint)? {
			guard points.count >= 2 else { return nil }
			let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
			let centroid = CGPoint(x: sum.x / Double(points.count), y: sum.y / Double(points.count))
			guard let a = farthest(from: centroid, in: points), let b = farthest(from: a, in: points),
				  let c = farthest(from: b, in: points) else { return nil }
			return (c, b)
		}

		static func farthest(from origin: CGPoint, in points: [CGPoint]) -> CGPoint? {
			guard var best = points.first else { return nil }
			var bestDistance = -1.0
			for point in points {
				let d = (point.x - origin.x) * (point.x - origin.x) + (point.y - origin.y) * (point.y - origin.y)
				if d > bestDistance {
					bestDistance = d
					best = point
				}
			}
			return best
		}
	}
}
