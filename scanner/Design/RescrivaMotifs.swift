//
//  RescrivaMotifs.swift
//  Rescriva (fork of Open Scanner)
//
//  Rescriva's page motifs: a sheet with its corner folded over, a hand-inked
//  underline, dot-grid and ruled paper under empty states, and the margin
//  note. Then the motion signatures: a scan line passing down the page, ink
//  writing itself in, and a page settling into place.
//

import SwiftUI

// MARK: - Folded sheet

/// A sheet of paper with its top-right corner folded over: a rounded
/// rectangle with that corner cut on the diagonal.
struct FoldedSheet: InsettableShape {
	var radius: CGFloat = RescrivaRadius.medium
	var fold: CGFloat = 14
	var inset: CGFloat = 0

	func path(in rect: CGRect) -> Path {
		let rect = rect.insetBy(dx: inset, dy: inset)
		guard rect.width > 0, rect.height > 0 else { return Path() }
		let r = max(0, min(radius, rect.width / 2, rect.height / 2))
		let f = max(0, min(fold, rect.width / 2, rect.height / 2))
		var path = Path()
		path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
		path.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY))
		path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f))
		path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
		path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
		path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
		path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
		path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
		path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
		path.closeSubpath()
		return path
	}

	func inset(by amount: CGFloat) -> FoldedSheet {
		var sheet = self
		sheet.inset += amount
		return sheet
	}
}

/// The back of a folded corner, lying on the sheet just under the fold.
struct FoldFlap: Shape {
	var fold: CGFloat = 14

	func path(in rect: CGRect) -> Path {
		let f = max(0, min(fold, rect.width / 2, rect.height / 2))
		let soft = min(2.5, f * 0.2)
		var path = Path()
		path.move(to: CGPoint(x: rect.maxX - f, y: rect.minY))
		path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f))
		path.addLine(to: CGPoint(x: rect.maxX - f + soft, y: rect.minY + f))
		path.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.minY + f - soft), control: CGPoint(x: rect.maxX - f, y: rect.minY + f))
		path.closeSubpath()
		return path
	}
}

/// The crease along a folded corner's diagonal.
private struct FoldCrease: Shape {
	var fold: CGFloat

	func path(in rect: CGRect) -> Path {
		let f = max(0, min(fold, rect.width / 2, rect.height / 2))
		var path = Path()
		path.move(to: CGPoint(x: rect.maxX - f, y: rect.minY))
		path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f))
		return path
	}
}

/// A folded corner, drawn over a `FoldedSheet` of the same size: the flap with
/// the small shadow it casts, a touch of tone, and the crease.
struct FoldedCorner: View {
	var fold: CGFloat = 14
	var fill: Color = .vellum

	var body: some View {
		ZStack {
			FoldFlap(fold: fold)
				.fill(fill)
				.shadow(color: Color.shade.opacity(0.18), radius: 0.9, x: -0.6, y: 1)
			FoldFlap(fold: fold)
				.fill(Color.carbon.opacity(0.08))
			FoldCrease(fold: fold)
				.stroke(Color.carbon.opacity(0.14), lineWidth: 0.75)
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}

extension View {
	/// Lays the view on a sheet with its top corner folded over, a hairline
	/// edge and the card shadow: Rescriva's card.
	func paperCard(radius: CGFloat = RescrivaRadius.medium, fold: CGFloat = 14, fill: Color = .vellum) -> some View {
		self.background {
			ZStack {
				FoldedSheet(radius: radius, fold: fold)
					.fill(fill)
					.rescrivaShadow(.card)
				FoldedSheet(radius: radius, fold: fold)
					.strokeBorder(Color.carbon.opacity(0.07), lineWidth: 1)
				FoldedCorner(fold: fold, fill: fill)
			}
		}
	}

	/// Cuts a page (a thumbnail, a scan) to a sheet with its corner folded over.
	/// Pages are paper, so the fold keeps its paper colours in the dark.
	func foldedPage(radius: CGFloat = 4, fold: CGFloat = 10) -> some View {
		self.clipShape(FoldedSheet(radius: radius, fold: fold))
			.overlay {
				FoldedCorner(fold: fold, fill: .paper)
					.environment(\.colorScheme, .light)
			}
	}
}

// MARK: - Ink

/// A hand-inked underline: a stroke that swells through the middle and thins
/// to square-cut ends, lifting a little to the right like a pen's flick.
/// Fill it; its height is the stroke's widest point.
struct InkStroke: Shape {
	func path(in rect: CGRect) -> Path {
		func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
			CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
		}
		var path = Path()
		path.move(to: point(0, 0.55))
		path.addCurve(to: point(1, 0.10), control1: point(0.28, 0.10), control2: point(0.66, -0.02))
		path.addLine(to: point(1, 0.50))
		path.addCurve(to: point(0.004, 0.95), control1: point(0.70, 0.78), control2: point(0.32, 1.05))
		path.closeSubpath()
		return path
	}
}

extension View {
	/// Shows the view only as far as `progress` (0–1) along, left to right, so
	/// animating `progress` writes it in like a line of ink.
	func inked(_ progress: CGFloat) -> some View {
		mask {
			Rectangle()
				.scaleEffect(x: max(min(progress, 1), 0.001), y: 1, anchor: .leading)
		}
	}
}

// MARK: - Ruled paper

/// Faint dot-grid or ruled paper: the ground of empty states.
struct PaperRuling: View {
	enum Style {
		/// A dot grid, like a bullet-journal page.
		case dots
		/// Blue rules with a red margin, like a notebook page.
		case lines
	}

	var style: Style = .dots
	var spacing: CGFloat = 18

	var body: some View {
		Canvas { context, size in
			guard spacing >= 4 else { return }
			switch style {
			case .dots:
				let dot = Color.carbon.opacity(0.14)
				var y = spacing
				while y < size.height {
					var x = spacing
					while x < size.width {
						context.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)), with: .color(dot))
						x += spacing
					}
					y += spacing
				}
			case .lines:
				let rule = Color.bluePencil.opacity(0.22)
				var y = spacing + 6
				while y < size.height {
					context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.75)), with: .color(rule))
					y += spacing
				}
				context.fill(Path(CGRect(x: 30, y: 0, width: 0.75, height: size.height)), with: .color(Color.vermilion.opacity(0.28)))
			}
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}

/// An empty state on a folded sheet of dot-grid or ruled paper: a sketch, and
/// a line in the margin-note voice.
struct EmptyState<Art: View>: View {
	let text: String
	var ruling: PaperRuling.Style = .dots
	@ViewBuilder var art: Art

	var body: some View {
		VStack(spacing: 14) {
			art
			Text(text)
				.font(RescrivaFont.note(16))
				.foregroundStyle(.graphite)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(.vertical, 26)
		.padding(.horizontal, 24)
		.frame(maxWidth: .infinity)
		.background {
			PaperRuling(style: ruling)
				.clipShape(FoldedSheet(fold: 16))
		}
		.paperCard(fold: 16)
		.accessibilityElement(children: .combine)
		.transition(.settle)
	}
}

extension EmptyState where Art == EmptyView {
	init(text: String, ruling: PaperRuling.Style = .dots) {
		self.init(text: text, ruling: ruling) { EmptyView() }
	}
}

// MARK: - Margin note

/// The companion's voice: a note written in the margin — italic New York on a
/// slip with its corner folded, marked down its edge with the highlighter.
struct MarginNote: View {
	let text: String

	var body: some View {
		Text(text)
			.font(RescrivaFont.note(15))
			.lineSpacing(3)
			.foregroundStyle(.carbon)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, 12)
			.padding(.leading, 26)
			.padding(.trailing, 22)
			.background(alignment: .leading) {
				RoundedRectangle(cornerRadius: 1.5)
					.fill(Color.highlighter)
					.frame(width: 3)
					.padding(.vertical, 11)
					.padding(.leading, 12)
			}
			.paperCard(fold: 12)
			.transition(.settle)
	}
}

// MARK: - Motion signatures

/// The scan line: a crisp rule with a soft glow trailing above it.
struct ScanLine: View {
	/// Height of the glow above the rule.
	static let trail: CGFloat = 60

	var color: Color = .highlighter

	var body: some View {
		VStack(spacing: 0) {
			LinearGradient(colors: [color.opacity(0), color.opacity(0.32)], startPoint: .top, endPoint: .bottom)
			Rectangle()
				.fill(color)
				.frame(height: 2)
				.shadow(color: color.opacity(0.9), radius: 3)
		}
		.frame(height: Self.trail)
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}

/// Where a scan line is in its pass: how far down (0–1) and how visible.
struct ScanPass {
	var position: CGFloat = 0
	var opacity: Double = 0
}

/// One pass of the scan line down whatever it overlays each time `trigger`
/// changes: the shutter's signature. With Reduce Motion, a soft flash instead.
struct ScanLinePass<Trigger: Equatable>: View {
	let trigger: Trigger
	var color: Color = .highlighter
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		KeyframeAnimator(initialValue: ScanPass(), trigger: trigger) { pass in
			GeometryReader { proxy in
				if reduceMotion {
					color.opacity(pass.opacity * 0.22)
				} else {
					ScanLine(color: color)
						.offset(y: pass.position * (proxy.size.height + ScanLine.trail) - ScanLine.trail)
						.opacity(pass.opacity)
				}
			}
		} keyframes: { _ in
			KeyframeTrack(\.position) {
				MoveKeyframe(0)
				CubicKeyframe(1, duration: 0.62)
			}
			KeyframeTrack(\.opacity) {
				MoveKeyframe(1)
				LinearKeyframe(1, duration: 0.47)
				LinearKeyframe(0, duration: 0.15)
			}
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}

/// The scan line sweeping down whatever it overlays, again and again, for work
/// that's under way. Nothing moves with Reduce Motion.
struct ScanLineLoop: View {
	var color: Color = .highlighter
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		if reduceMotion {
			Color.clear
		} else {
			KeyframeAnimator(initialValue: ScanPass(), repeating: true) { pass in
				GeometryReader { proxy in
					ScanLine(color: color)
						.offset(y: pass.position * (proxy.size.height + ScanLine.trail) - ScanLine.trail)
						.opacity(pass.opacity)
				}
			} keyframes: { _ in
				KeyframeTrack(\.position) {
					MoveKeyframe(0)
					CubicKeyframe(1, duration: 1.7)
					LinearKeyframe(1, duration: 0.5)
				}
				KeyframeTrack(\.opacity) {
					MoveKeyframe(0)
					LinearKeyframe(1, duration: 0.2)
					LinearKeyframe(1, duration: 1.3)
					LinearKeyframe(0, duration: 0.2)
					LinearKeyframe(0, duration: 0.5)
				}
			}
			.allowsHitTesting(false)
			.accessibilityHidden(true)
		}
	}
}

/// A small page that drops onto its stack and settles into place as it
/// appears: the export's signature.
struct SettlingPage: View {
	var width: CGFloat = 18
	@State private var settled = false
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		let height = width * 1.28
		ZStack {
			// The page already on the stack.
			FoldedSheet(radius: 2, fold: width * 0.28)
				.fill(Color.paper.opacity(0.6))
				.rotationEffect(.degrees(-7))
				.offset(x: -2, y: 1.5)
			// The new page, settling onto it.
			FoldedSheet(radius: 2, fold: width * 0.28)
				.fill(Color.paper)
				.overlay(alignment: .topLeading) {
					VStack(alignment: .leading, spacing: height * 0.1) {
						RoundedRectangle(cornerRadius: 0.5).fill(Color.ink).frame(width: width * 0.42, height: 1.6)
						ForEach([0.62, 0.55, 0.6], id: \.self) { fraction in
							RoundedRectangle(cornerRadius: 0.5).fill(Color.carbon.opacity(0.3)).frame(width: width * fraction, height: 1)
						}
					}
					.padding(.top, height * 0.22)
					.padding(.leading, width * 0.16)
				}
				.overlay { FoldedCorner(fold: width * 0.28, fill: .paper) }
				.shadow(color: Color.black.opacity(settled ? 0.2 : 0.1), radius: settled ? 1 : 4, x: 0, y: settled ? 1 : 5)
				.rotationEffect(.degrees(settled ? 0 : -16))
				.offset(y: settled ? 0 : -12)
				.opacity(settled ? 1 : 0)
		}
		.frame(width: width, height: height)
		.environment(\.colorScheme, .light)
		.accessibilityHidden(true)
		.onAppear {
			if reduceMotion {
				settled = true
			} else {
				withAnimation(RescrivaMotion.settle.delay(0.12)) { settled = true }
			}
		}
	}
}
