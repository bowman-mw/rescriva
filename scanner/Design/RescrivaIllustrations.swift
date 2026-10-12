//
//  RescrivaIllustrations.swift
//  Rescriva (fork of Open Scanner)
//
//  Rescriva's illustrations are its own work in miniature: something drawn
//  by hand — a whiteboard flowchart, a page of notes — beside the clean,
//  typeset version Rescriva makes of it. The sketch draws itself in, a
//  highlighter arrow follows, and the clean version settles into place.
//

import SwiftUI

// MARK: - Drawing by hand

/// Strokes that look drawn by hand: lines that bow a little and overshoot
/// their corners, loops that don't quite close, handwriting that comes in
/// words. Seeded, so a sketch is the same every time it's drawn.
struct HandDrawn {
	private var generator: SeededGenerator

	init(seed: UInt64) {
		generator = SeededGenerator(seed: seed)
	}

	private mutating func random(_ range: ClosedRange<CGFloat>) -> CGFloat {
		CGFloat.random(in: range, using: &generator)
	}

	/// A line from `a` to `b` that bows by up to `wobble` and starts and ends a
	/// little past its points, the way a quick pen overshoots.
	mutating func line(_ path: inout Path, from a: CGPoint, to b: CGPoint, wobble: CGFloat = 1.6, overshoot: ClosedRange<CGFloat> = 0.5...2.5) {
		let dx = b.x - a.x, dy = b.y - a.y
		let length = max(hypot(dx, dy), 0.001)
		let ux = dx / length, uy = dy / length
		let nx = -uy, ny = ux
		let before = random(overshoot), after = random(overshoot)
		let start = CGPoint(x: a.x - ux * before + nx * random(-0.6...0.6), y: a.y - uy * before + ny * random(-0.6...0.6))
		let end = CGPoint(x: b.x + ux * after + nx * random(-0.6...0.6), y: b.y + uy * after + ny * random(-0.6...0.6))
		let bow1 = random(-wobble...wobble), bow2 = random(-wobble...wobble)
		path.move(to: start)
		path.addCurve(to: end,
					  control1: CGPoint(x: a.x + dx / 3 + nx * bow1, y: a.y + dy / 3 + ny * bow1),
					  control2: CGPoint(x: a.x + dx * 2 / 3 + nx * bow2, y: a.y + dy * 2 / 3 + ny * bow2))
	}

	/// A box of four strokes, each overshooting its corners.
	mutating func box(_ path: inout Path, _ rect: CGRect) {
		let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
					   CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
		for index in corners.indices {
			line(&path, from: corners[index], to: corners[(index + 1) % 4])
		}
	}

	/// An oval drawn in one go: a slightly uneven loop whose end runs past its start.
	mutating func loop(_ path: inout Path, in rect: CGRect) {
		let start = random(0...(2 * .pi))
		let turn = 2 * CGFloat.pi + random(0.25...0.5)
		let warp = random(-0.05...0.05), phase = random(0...(2 * .pi))
		let steps = 14
		let points = (0...steps).map { step -> CGPoint in
			let t = start + turn * CGFloat(step) / CGFloat(steps)
			let r = 1 + warp * sin(2 * t + phase) + 0.04 * CGFloat(step) / CGFloat(steps)
			return CGPoint(x: rect.midX + rect.width / 2 * r * cos(t), y: rect.midY + rect.height / 2 * r * sin(t))
		}
		smooth(&path, through: points)
	}

	/// An arrow: a bowed shaft and two quick strokes for the head.
	mutating func arrow(_ path: inout Path, from a: CGPoint, to b: CGPoint, head: CGFloat = 5) {
		line(&path, from: a, to: b, wobble: 1.8, overshoot: -1.5...0)
		let dx = b.x - a.x, dy = b.y - a.y
		let length = max(hypot(dx, dy), 0.001)
		let ux = dx / length, uy = dy / length
		for side in [CGFloat(1), -1] {
			let angle = (150 * side + random(-8...8)) * .pi / 180
			let hx = ux * cos(angle) - uy * sin(angle), hy = ux * sin(angle) + uy * cos(angle)
			line(&path, from: b, to: CGPoint(x: b.x + hx * head, y: b.y + hy * head), wobble: 0.4, overshoot: 0...0.6)
		}
	}

	/// A line of handwriting about `length` long on the baseline through
	/// `start`: words of humps and the odd tall letter, with gaps between.
	mutating func handwriting(_ path: inout Path, from start: CGPoint, length: CGFloat) {
		var x = start.x
		while x < start.x + length - 6 {
			var points = [CGPoint(x: x, y: start.y)]
			let letters = Int(random(4...9))
			var rising = true
			for _ in 0..<letters {
				x += random(2.6...5.4)
				let tall = random(0...1) > 0.8
				let height = rising ? random(2.2...4.4) * (tall ? 2.1 : 1) : random(-0.8...0.9)
				points.append(CGPoint(x: x, y: start.y - height))
				rising.toggle()
				if x > start.x + length { break }
			}
			smooth(&path, through: points)
			x += random(4...7)
		}
	}

	/// A curve through `points`, rounding each one off.
	private func smooth(_ path: inout Path, through points: [CGPoint]) {
		guard let first = points.first, points.count > 1 else { return }
		path.move(to: first)
		for index in 1..<(points.count - 1) {
			let point = points[index], next = points[index + 1]
			path.addQuadCurve(to: CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2), control: point)
		}
		path.addLine(to: points[points.count - 1])
	}
}

// MARK: - Subjects

/// Where an illustration's parts sit, on a 120 × 90 board.
private enum Board {
	static let size = CGSize(width: 120, height: 90)

	/// Scales the board to fit `rect`, centred.
	static func fit(in rect: CGRect) -> CGAffineTransform {
		let scale = min(rect.width / size.width, rect.height / size.height)
		return CGAffineTransform(translationX: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2)
			.scaledBy(x: scale, y: scale)
	}

	// The flowchart.
	static let first = CGRect(x: 4, y: 8, width: 42, height: 26)
	static let second = CGRect(x: 74, y: 8, width: 42, height: 26)
	static let third = CGRect(x: 39, y: 58, width: 42, height: 26)
}

/// The parts of a cleaned-up drawing, filled or stroked separately.
enum CleanPart {
	/// The shapes' outlines (a flowchart's boxes; a page's heading).
	case shapes
	/// Connectors between shapes.
	case connectors
	/// Solid marks: arrowheads, lines of type.
	case marks
}

/// A flowchart drawn by hand on a whiteboard: two boxes, an oval and arrows.
struct SketchedFlowchart: Shape {
	var seed: UInt64 = 11

	func path(in rect: CGRect) -> Path {
		var hand = HandDrawn(seed: seed)
		var path = Path()
		hand.box(&path, Board.first)
		hand.loop(&path, in: Board.second)
		hand.box(&path, Board.third)
		hand.arrow(&path, from: CGPoint(x: Board.first.maxX + 3, y: Board.first.midY), to: CGPoint(x: Board.second.minX - 3, y: Board.second.midY))
		hand.arrow(&path, from: CGPoint(x: 95, y: Board.second.maxY + 3), to: CGPoint(x: Board.third.maxX - 6, y: Board.third.minY - 3))
		return path.applying(Board.fit(in: rect))
	}
}

/// The same flowchart as Rescriva rebuilds it: clean boxes and straight arrows.
struct CleanFlowchart: Shape {
	let part: CleanPart

	func path(in rect: CGRect) -> Path {
		var path = Path()
		let diagonalStart = CGPoint(x: 95, y: Board.second.maxY)
		let diagonalEnd = CGPoint(x: Board.third.maxX - 6, y: Board.third.minY)
		switch part {
		case .shapes:
			path.addRoundedRect(in: Board.first, cornerSize: CGSize(width: 3, height: 3))
			path.addEllipse(in: Board.second)
			path.addRoundedRect(in: Board.third, cornerSize: CGSize(width: 3, height: 3))
		case .connectors:
			path.move(to: CGPoint(x: Board.first.maxX, y: Board.first.midY))
			path.addLine(to: CGPoint(x: Board.second.minX - 4, y: Board.second.midY))
			path.move(to: diagonalStart)
			path.addLine(to: Self.point(diagonalEnd, back: 4, from: diagonalStart))
		case .marks:
			path.addLines([CGPoint(x: Board.second.minX, y: Board.second.midY), CGPoint(x: Board.second.minX - 5, y: Board.second.midY - 3),
						   CGPoint(x: Board.second.minX - 5, y: Board.second.midY + 3)])
			path.closeSubpath()
			path.addPath(Self.arrowhead(at: diagonalEnd, from: diagonalStart))
		}
		return path.applying(Board.fit(in: rect))
	}

	/// `point` moved `back` units toward `from`.
	private static func point(_ point: CGPoint, back: CGFloat, from: CGPoint) -> CGPoint {
		let dx = point.x - from.x, dy = point.y - from.y
		let length = max(hypot(dx, dy), 0.001)
		return CGPoint(x: point.x - dx / length * back, y: point.y - dy / length * back)
	}

	private static func arrowhead(at tip: CGPoint, from start: CGPoint) -> Path {
		let dx = tip.x - start.x, dy = tip.y - start.y
		let length = max(hypot(dx, dy), 0.001)
		let ux = dx / length, uy = dy / length
		var path = Path()
		path.addLines([tip, CGPoint(x: tip.x - ux * 5 - uy * 3, y: tip.y - uy * 5 + ux * 3),
					   CGPoint(x: tip.x - ux * 5 + uy * 3, y: tip.y - uy * 5 - ux * 3)])
		path.closeSubpath()
		return path
	}
}

/// A page of handwritten notes: an underlined heading and four lines.
struct SketchedNotes: Shape {
	var seed: UInt64 = 5

	func path(in rect: CGRect) -> Path {
		var hand = HandDrawn(seed: seed)
		var path = Path()
		hand.handwriting(&path, from: CGPoint(x: 8, y: 20), length: 56)
		hand.line(&path, from: CGPoint(x: 7, y: 26), to: CGPoint(x: 68, y: 25), wobble: 1, overshoot: 0...2)
		for (index, length) in [CGFloat(98), 88, 102, 60].enumerated() {
			hand.handwriting(&path, from: CGPoint(x: 8, y: 44 + CGFloat(index) * 12.5), length: length)
		}
		return path.applying(Board.fit(in: rect))
	}
}

/// The same notes, typeset: a heading and lines of text.
struct CleanNotes: Shape {
	let part: CleanPart

	func path(in rect: CGRect) -> Path {
		var path = Path()
		switch part {
		case .shapes:
			path.addRoundedRect(in: CGRect(x: 8, y: 13, width: 58, height: 9), cornerSize: CGSize(width: 1.5, height: 1.5))
		case .connectors:
			break
		case .marks:
			for (index, length) in [CGFloat(104), 96, 104, 62].enumerated() {
				path.addRoundedRect(in: CGRect(x: 8, y: 38 + CGFloat(index) * 12.5, width: length, height: 3), cornerSize: CGSize(width: 0.75, height: 0.75))
			}
		}
		return path.applying(Board.fit(in: rect))
	}
}

/// The highlighter arrow between a sketch and its clean version.
private struct TurnArrow: Shape {
	func path(in rect: CGRect) -> Path {
		var path = Path()
		let w = rect.width, h = rect.height
		path.move(to: CGPoint(x: rect.minX, y: rect.midY + h * 0.08))
		path.addCurve(to: CGPoint(x: rect.maxX - w * 0.06, y: rect.midY + h * 0.08),
					  control1: CGPoint(x: rect.minX + w * 0.28, y: rect.midY - h * 0.2),
					  control2: CGPoint(x: rect.minX + w * 0.62, y: rect.midY - h * 0.2))
		path.move(to: CGPoint(x: rect.maxX - w * 0.3, y: rect.midY - h * 0.38))
		path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + h * 0.1))
		path.addLine(to: CGPoint(x: rect.maxX - w * 0.33, y: rect.midY + h * 0.5))
		return path
	}
}

// MARK: - The illustration

/// Something drawn by hand beside the clean version Rescriva makes of it —
/// which is what Rescriva does. On appearing, the sketch draws itself in, the
/// arrow follows, and the clean version settles into place.
struct SketchToCleanIllustration: View {
	enum Subject {
		/// A whiteboard flowchart becoming clean boxes.
		case flowchart
		/// Handwritten notes becoming typeset lines.
		case notes
	}

	var subject: Subject = .flowchart
	var maxHeight: CGFloat = 92

	@State private var sketched: CGFloat = 0
	@State private var arrowed: CGFloat = 0
	@State private var cleaned = false
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		HStack(spacing: 8) {
			sketch
				.trim(from: 0, to: sketched)
				.stroke(Color.graphite, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
				.aspectRatio(Board.size.width / Board.size.height, contentMode: .fit)
			TurnArrow()
				.stroke(Color.highlighter, style: StrokeStyle(lineWidth: 3.25, lineCap: .butt, lineJoin: .miter))
				.frame(width: 30, height: 16)
				.inked(arrowed)
			clean
				.aspectRatio(Board.size.width / Board.size.height, contentMode: .fit)
				.opacity(cleaned ? 1 : 0)
				.rotationEffect(.degrees(cleaned ? 0 : -3))
				.offset(y: cleaned ? 0 : -6)
		}
		.frame(maxWidth: .infinity, maxHeight: maxHeight)
		.accessibilityHidden(true)
		.onAppear(perform: draw)
	}

	private var sketch: AnyShape {
		switch subject {
		case .flowchart: return AnyShape(SketchedFlowchart())
		case .notes: return AnyShape(SketchedNotes())
		}
	}

	@ViewBuilder
	private var clean: some View {
		switch subject {
		case .flowchart:
			ZStack {
				CleanFlowchart(part: .shapes).fill(Color.wash)
				CleanFlowchart(part: .shapes).stroke(Color.ink, lineWidth: 1.5)
				CleanFlowchart(part: .connectors).stroke(Color.ink, lineWidth: 1.5)
				CleanFlowchart(part: .marks).fill(Color.ink)
			}
		case .notes:
			ZStack {
				CleanNotes(part: .shapes).fill(Color.ink)
				CleanNotes(part: .marks).fill(Color.carbon.opacity(0.28))
			}
		}
	}

	private func draw() {
		guard !reduceMotion else {
			sketched = 1
			arrowed = 1
			cleaned = true
			return
		}
		guard sketched == 0 else { return }
		withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 1.2)) { sketched = 1 }
		withAnimation(RescrivaMotion.inkStroke.delay(0.85)) { arrowed = 1 }
		withAnimation(RescrivaMotion.settle.delay(1.2)) { cleaned = true }
	}
}
