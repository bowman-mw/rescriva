//
//  GlareFusion.swift
//  Rescriva (fork of Open Scanner)
//
//  Multi-frame glare removal. Two to four photos of one page, taken from slightly different
//  positions, are warped into page space, aligned to the first, matched in exposure and blended
//  so every part of the page comes from the photos that see it without glare.
//  Core Image, Vision and plain Swift only (no AVFoundation or UIKit), so the whole file builds
//  and runs on macOS.
//

import Accelerate
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import simd

// MARK: - GlareFrame

/// One photo of the page for `GlareFusion`: the upright still and the page outline found in it.
struct GlareFrame {
	/// The upright photo. Any extent; it is moved to the origin.
	var image: CIImage
	/// The page outline, normalized with a top-left origin in `image`'s own space (see `PageQuad`).
	var quad: PageQuad
}

// MARK: - GlareFusion

/// Fuses several photos of one page into one page without glare.
///
/// Model: a photo of a page is `albedo × light + glare`. The light is the same in every photo, but
/// specular glare is additive and sits where the light source mirrors into the lens, so it moves
/// over the page when the camera moves while the ink stays put. With every photo in page space:
/// 1. Geometry: each frame's quad gives a homography onto the reference's (the first frame's)
///    page; Vision's homographic registration then refines it on images whose glare is clamped
///    to paper white, so the moving highlight carries no features. A refinement is kept only if
///    it lowers the mean difference to the reference.
/// 2. Exposure: each frame gets a per-channel gain, the median ratio to the reference over
///    well-exposed pixels, so auto-exposure and white-balance changes between shots cancel.
/// 3. Glare: at a small analysis size each frame's luminance is regressed locally on the per-pixel
///    minimum of the stack (`frame ≈ a · minimum + b`). Glare is additive, so it lands in the
///    offset `b`; a shadow cast by the phone is multiplicative and goes into the slope `a`.
///    Clipped pixels add a penalty of their own.
/// 4. Blend: weights are a soft minimum of the glare scores (`exp(−glare / glareScale)`, with the
///    reference preferred by `referenceWeight`), masked to each frame's coverage, smoothed and
///    normalized; the full-size page is the weighted sum. Where every frame is clean the result is
///    mostly the reference with a little multi-frame denoising; where the reference has glare it
///    comes from the others; where all of them have glare, from the least glary.
///
/// The result is linear light at the origin in the reference's page geometry, ready for
/// `PageCleanup.clean`. It is a lazy `CIImage` over each frame's page (rendered once, see
/// `materializesPages`): render it once before cleanup. Everything here is synchronous; call it on
/// a processing queue.
enum GlareFusion {

	/// Tunables. Sizes are in pixels; glare scores are fractions of the paper's brightness.
	struct Options {
		/// Widest page produced (Open Scanner stores pages 2400 px wide).
		var maxWidth: CGFloat = 2400
		/// Frames after this many are ignored.
		var maxFrames = 4
		/// Refine each frame's quad alignment with Vision's homographic registration.
		var refinesAlignment = true
		/// Keep a frame whose refinement failed or was rejected, placed by its quad alone. Quads
		/// alone are several pixels off and ghost the text, so the camera turns this off: such a
		/// frame (another page, or a shot registration could not match) is dropped instead. Only
		/// applies when `refinesAlignment` is on.
		var keepsUnrefinedFrames = true
		/// Long side of the page images registration runs on.
		var registrationSize: CGFloat = 1024
		/// After registration, correct what a homography can't: a page that isn't flat (a laminated
		/// sheet bowed by its binder) is off by a few pixels here and there. Each frame's shift is
		/// measured tile by tile, smoothed into a displacement field and the frame resampled along
		/// it. Needs `materializesPages`.
		var refinesLocally = false
		/// Largest local shift trusted, as a fraction of the page's long side.
		var maxLocalShift: CGFloat = 0.012
		/// Registration passes per frame. A second pass, starting from the first's result, tightens
		/// the fit when the outlines disagreed by several percent; it is kept only if it improves on
		/// the first.
		var refinementPasses = 1
		/// A refinement that moves a page corner further than this fraction of the page's long side
		/// is rejected as a mismatch. Vision's outlines of the same page can disagree by several
		/// percent between real shots (a laminate's pouch edge in one, the paper's in the next), so
		/// the camera allows more.
		var maxRefinementShift: CGFloat = 0.03
		/// A refinement is also rejected unless its mean difference to the reference is at most this
		/// share of the difference before it (a real match on the same page roughly halves it).
		var maxRefinedDifferenceRatio: Float = 1
		/// Check each frame's outline against the reference's shape and repair one stray corner
		/// (Vision sometimes runs a corner onto a neighbouring sheet); a frame whose outline can't
		/// be made consistent is dropped.
		var repairsOutlines = false
		/// Other frames fill in only where the reference has glare; elsewhere the page is the
		/// reference alone. A real page is never quite flat, so blending clean regions as well (for
		/// a little denoising) doubles the text wherever registration is off.
		var fillsOnlyGlare = false
		/// With `fillsOnlyGlare`: the reference's glare score where filling starts, and where the other
		/// frames take over fully.
		var fillStart: Float = 0.10
		var fillFull: Float = 0.12
		/// With `fillsOnlyGlare`, the glare scale used in place of `glareScale`: small, so where the
		/// reference needs filling the least glary frame wins outright instead of a soft mix (which
		/// doubles text wherever registration is off).
		var fillGlareScale: Float = 0.01
		/// Long side of the page images the gains, glare scores and weights are computed on.
		var analysisSize: CGFloat = 384
		/// Weight of the reference relative to each other frame where they are equally clean.
		var referenceWeight: Float = 2
		/// A frame's weight is also scaled by its sharpness relative to the reference raised to this
		/// power, so a shot blurred by movement only fills in where the sharper ones have glare.
		var sharpnessExponent: Float = 4
		/// Render each aligned page once (8-bit sRGB) before analysis and blending, so those read
		/// compact page images instead of every full-resolution photo at once.
		var materializesPages = true
		/// Glare score at which a frame's weight falls by a factor of e.
		var glareScale: Float = 0.04
		/// Glare score above which a pixel counts as glare in the reports and the residual map.
		var glareThreshold: Float = 0.12
		/// Linear level at or above which a channel counts as clipped.
		var clipLevel: Float = 0.92

		/// The settings `CaptureCamera` fuses a second look with, tuned on real stills of laminated
		/// sheets: outlines that disagree by several percent, pages bowed by their binder.
		static var camera: Options {
			var options = Options()
			options.maxFrames = 3
			options.keepsUnrefinedFrames = false
			options.maxRefinementShift = 0.08
			options.maxRefinedDifferenceRatio = 0.85
			options.repairsOutlines = true
			options.refinesLocally = true
			options.fillsOnlyGlare = true
			return options
		}
	}

	/// How a frame was placed in page space.
	enum Alignment: Equatable {
		/// The reference frame: its quad defines the page.
		case reference
		/// Placed by its quad alone; the reason refinement was skipped or rejected, if it was tried.
		case quad(String?)
		/// Placed by its quad, then refined by registration; `shift` is the largest page-corner move,
		/// in page pixels.
		case refined(shift: CGFloat)
	}

	/// What happened to one input frame.
	struct FrameReport {
		/// Position in the input array.
		var index: Int
		var alignment: Alignment
		/// Mean absolute difference to the reference (paper = 1) at registration size, before and
		/// after refinement; nil when refinement was not attempted.
		var differenceBefore: Float?
		var differenceAfter: Float?
		/// Edge steepness at registration size relative to the reference (below 1: blurrier); nil
		/// when not measured (refinement off or failed to render).
		var sharpness: Float?
		/// Mean local correction applied after registration (`refinesLocally`), in page pixels; nil
		/// when none was applied.
		var localShift: Float?
		/// Per-channel gain that matched the frame to the reference's exposure and white balance.
		var gain = SIMD3<Float>(repeating: 1)
		/// Share of the page this frame covers.
		var coverage: Float = 0
		/// Share of the covered page this frame sees with glare (score above `glareThreshold`).
		var glareFraction: Float = 0
	}

	/// The fused page and what went into it.
	struct Result {
		/// The fused page: linear light, at the origin, the reference's page size.
		var page: CIImage
		/// The reference frame alone in the same geometry (for comparison or fallback).
		var reference: CIImage
		/// One report per frame that was used, reference first.
		var frames: [FrameReport]
		/// Input indices dropped for unusable geometry, or for failed refinement when
		/// `keepsUnrefinedFrames` is off.
		var droppedFrames: [Int]
		/// Reports of the frames dropped for failed refinement (their alignment says why).
		var unrefinedFrames: [FrameReport]
		/// Share of the page that shows glare in every frame (what fusion could not recover).
		var residualGlareFraction: Float
		/// Where that residual glare is.
		var residualMap: GlareMap
		/// The blend weight of each used frame at analysis size (gray, for diagnostics).
		var weights: [CIImage]
	}

	/// Reasons `fuse` gives up; the caller falls back to the single-photo pipeline.
	enum FusionError: Error, Equatable {
		/// No frames were given.
		case noFrames
		/// The reference's quad does not define a usable page.
		case degenerateReference
		/// Core Image could not render an analysis image.
		case renderFailed
	}

	/// Frames placed in the reference's page space, before exposure matching and blending.
	struct AlignedStack {
		/// The page size in pixels.
		var pageSize: CGSize
		/// The usable frames, reference first.
		var layers: [Layer]
		/// Input indices dropped for unusable geometry, or for failed refinement when
		/// `keepsUnrefinedFrames` is off.
		var droppedFrames: [Int]
		/// Reports of the frames dropped for failed refinement.
		var unrefinedFrames: [FrameReport] = []
	}

	/// One frame placed in page space.
	struct Layer {
		/// The photo, moved to the origin.
		var source: CIImage
		/// Source pixels → page pixels, both with Core Image's bottom-left origin.
		var homography: Homography
		var report: FrameReport

		/// The frame in page space at `targetSize`, transparent where the photo does not reach.
		func page(pageSize: CGSize, targetSize: CGSize) -> CIImage? {
			GlareFusion.pageImage(source, homography: homography, pageSize: pageSize, targetSize: targetSize)
		}
	}

	/// Fuses `frames` (reference first) into one page with the glare taken out.
	///
	/// One frame returns that frame perspective-corrected. Frames whose quad is unusable are
	/// dropped and listed in `droppedFrames`; a failed refinement keeps the quad alignment and says
	/// why in the frame's report. Throws only when no page can be made at all.
	static func fuse(_ frames: [GlareFrame], context: CIContext, options: Options = Options()) throws -> Result {
		var stack = try align(frames, context: context, options: options)
		if options.materializesPages {
			try materialize(&stack, context: context)
			if options.refinesLocally {
				refineLocally(&stack, context: context, options: options)
			}
		}
		let analysis = try analyse(&stack, context: context, options: options)
		let size = stack.pageSize
		guard let reference = stack.layers.first?.page(pageSize: size, targetSize: size) else {
			throw FusionError.degenerateReference
		}
		let page = try blend(stack, analysis: analysis)
		let residualMap = GlareMap(plane: analysis.residual, columns: GlareMap.defaultColumns, rows: GlareMap.defaultRows) {
			$0 > options.glareThreshold
		}
		return Result(
			page: page,
			reference: opaque(reference, in: CGRect(origin: .zero, size: size)),
			frames: stack.layers.map(\.report),
			droppedFrames: stack.droppedFrames,
			unrefinedFrames: stack.unrefinedFrames,
			residualGlareFraction: analysis.residual.indicator(atLeast: options.glareThreshold).mean,
			residualMap: residualMap,
			weights: analysis.weights.map { $0.ciImage() }
		)
	}

	/// Renders every layer's page once and makes that its source (with an identity homography), so
	/// later steps never decode more than one photo at a time.
	private static func materialize(_ stack: inout AlignedStack, context: CIContext) throws {
		let rect = CGRect(origin: .zero, size: stack.pageSize)
		guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw FusionError.renderFailed }
		for index in stack.layers.indices {
			let rendered = autoreleasepool {
				stack.layers[index].page(pageSize: stack.pageSize, targetSize: stack.pageSize).flatMap {
					context.createCGImage($0, from: rect, format: .RGBA8, colorSpace: space)
				}
			}
			guard let rendered else { throw FusionError.renderFailed }
			stack.layers[index].source = CIImage(cgImage: rendered)
			stack.layers[index].homography = .identity
		}
	}

	/// Places every usable frame in the reference's page space (step 1 of the overview).
	static func align(_ frames: [GlareFrame], context: CIContext, options: Options) throws -> AlignedStack {
		let usable = Array(frames.prefix(max(1, options.maxFrames)))
		guard let first = usable.first else { throw FusionError.noFrames }
		let referenceSource = atOrigin(first.image)
		guard let pageSize = pageSize(for: first.quad, imageSize: referenceSource.extent.size, maxWidth: options.maxWidth),
			  let referenceMap = quadHomography(first.quad, imageSize: referenceSource.extent.size, pageSize: pageSize) else {
			throw FusionError.degenerateReference
		}
		let reference = Layer(source: referenceSource, homography: referenceMap, report: FrameReport(index: 0, alignment: .reference))
		var stack = AlignedStack(pageSize: pageSize, layers: [reference], droppedFrames: [])
		let registrar = options.refinesAlignment && usable.count > 1
			? Registrar(reference: reference, pageSize: pageSize, context: context, options: options)
			: nil
		for (index, frame) in usable.enumerated().dropFirst() {
			let source = atOrigin(frame.image)
			var quad = frame.quad
			if options.repairsOutlines {
				guard let consistent = consistentOutline(frame.quad, imageSize: source.extent.size,
														  reference: first.quad, referenceSize: referenceSource.extent.size) else {
					stack.droppedFrames.append(index)
					stack.unrefinedFrames.append(FrameReport(index: index, alignment: .quad("Its outline doesn't match the reference page's shape.")))
					continue
				}
				quad = consistent
			}
			guard let initial = quadHomography(quad, imageSize: source.extent.size, pageSize: pageSize) else {
				stack.droppedFrames.append(index)
				continue
			}
			var layer = Layer(source: source, homography: initial, report: FrameReport(index: index, alignment: .quad(nil)))
			if let registrar {
				// Drain Core Image's and Vision's autoreleased buffers frame by frame.
				autoreleasepool {
					registrar.refine(&layer)
				}
				for _ in 1..<max(1, options.refinementPasses) {
					guard case .refined(let firstShift) = layer.report.alignment else { break }
					var again = layer
					autoreleasepool {
						registrar.refine(&again)
					}
					guard case .refined(let shift) = again.report.alignment,
						  let after = again.report.differenceAfter, let previous = layer.report.differenceAfter, after < previous else { break }
					again.report.alignment = .refined(shift: firstShift + shift)
					again.report.differenceBefore = layer.report.differenceBefore
					layer = again
				}
			} else if options.refinesAlignment {
				layer.report.alignment = .quad("The reference could not be prepared for registration.")
			}
			if options.refinesAlignment, !options.keepsUnrefinedFrames, case .quad = layer.report.alignment {
				stack.droppedFrames.append(index)
				stack.unrefinedFrames.append(layer.report)
				continue
			}
			stack.layers.append(layer)
		}
		return stack
	}
}

// MARK: - Geometry

extension GlareFusion {

	/// The page size for the reference quad: the page's real aspect ratio (see
	/// `PageCleanup.estimatedAspectRatio`) at the pixel count the quad covers, at most `maxWidth`
	/// wide. Nil for a degenerate quad.
	static func pageSize(for quad: PageQuad, imageSize: CGSize, maxWidth: CGFloat) -> CGSize? {
		guard quad.isConvex, quad.area >= 0.01, imageSize.width >= 2, imageSize.height >= 2, maxWidth >= 16 else { return nil }
		func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
			hypot((a.x - b.x) * imageSize.width, (a.y - b.y) * imageSize.height)
		}
		let naturalWidth = (length(quad.topLeft, quad.topRight) + length(quad.bottomLeft, quad.bottomRight)) / 2
		let naturalHeight = (length(quad.topLeft, quad.bottomLeft) + length(quad.topRight, quad.bottomRight)) / 2
		guard naturalWidth >= 8, naturalHeight >= 8 else { return nil }
		var aspect = naturalWidth / naturalHeight
		if let estimate = PageCleanup.estimatedAspectRatio(of: quad, imageSize: imageSize),
		   estimate / aspect < 1.6, aspect / estimate < 1.6 {
			aspect = estimate
		}
		let width = min(maxWidth, (naturalWidth * naturalHeight * aspect).squareRoot()).rounded()
		return CGSize(width: max(8, width), height: max(8, (width / aspect).rounded()))
	}

	/// Source pixels → page pixels for a quad (normalized, top-left origin) in an image of
	/// `imageSize`. Nil for a non-convex or degenerate quad.
	static func quadHomography(_ quad: PageQuad, imageSize: CGSize, pageSize: CGSize) -> Homography? {
		guard quad.isConvex else { return nil }
		let source = quad.corners.map { CGPoint(x: $0.x * imageSize.width, y: (1 - $0.y) * imageSize.height) }
		let page = [
			CGPoint(x: 0, y: pageSize.height),
			CGPoint(x: pageSize.width, y: pageSize.height),
			CGPoint(x: pageSize.width, y: 0),
			CGPoint.zero,
		]
		return Homography(from: source, to: page)
	}

	/// `source` warped by `homography` (source pixels → page pixels) into a page of `pageSize`,
	/// resampled to `targetSize`, transparent where the photo does not reach.
	///
	/// Large reductions are prefiltered with a Lanczos downscale so small text does not alias.
	/// Nil when the warp would send part of the photo to infinity.
	static func pageImage(_ source: CIImage, homography: Homography, pageSize: CGSize, targetSize: CGSize) -> CIImage? {
		let image = atOrigin(source)
		let target = CGRect(origin: .zero, size: targetSize)
		guard pageSize.width > 0, pageSize.height > 0, target.width >= 1, target.height >= 1,
			  !image.extent.isInfinite, image.extent.width >= 1, image.extent.height >= 1 else { return nil }
		var map = homography.followed(by: .scaling(x: target.width / pageSize.width, y: target.height / pageSize.height))
		var input = image
		if let reduction = map.localScale(at: CGPoint(x: target.midX, y: target.midY)), reduction < 0.5 {
			let longSide = max(image.extent.width, image.extent.height)
			let reduced = PageCleanup.limitLongSide(image, to: (longSide * reduction * 2).rounded(.up))
			let scaleX = reduced.extent.width / image.extent.width
			let scaleY = reduced.extent.height / image.extent.height
			guard scaleX > 0, scaleY > 0 else { return nil }
			map = Homography.scaling(x: 1 / scaleX, y: 1 / scaleY).followed(by: map)
			input = reduced
		}
		return warp(input, by: map, to: target)
	}

	/// The whole of `image` (extent at the origin) mapped by `map`, cropped to `target`.
	private static func warp(_ image: CIImage, by map: Homography, to target: CGRect) -> CIImage? {
		let extent = image.extent
		let limit = 64 * max(target.width, target.height)
		guard let bottomLeft = map.apply(CGPoint(x: extent.minX, y: extent.minY)),
			  let bottomRight = map.apply(CGPoint(x: extent.maxX, y: extent.minY)),
			  let topRight = map.apply(CGPoint(x: extent.maxX, y: extent.maxY)),
			  let topLeft = map.apply(CGPoint(x: extent.minX, y: extent.maxY)),
			  [bottomLeft, bottomRight, topRight, topLeft].allSatisfy({ abs($0.x) < limit && abs($0.y) < limit }) else {
			return nil
		}
		let filter = CIFilter.perspectiveTransform()
		filter.inputImage = image
		filter.bottomLeft = bottomLeft
		filter.bottomRight = bottomRight
		filter.topRight = topRight
		filter.topLeft = topLeft
		return filter.outputImage?.cropped(to: target)
	}

	/// `quad` (normalized, in an image of `imageSize`) checked against the reference page's outline
	/// (in `referenceSize`), for a photo of the same page from a little to one side.
	///
	/// - Consistent: after one common scale, every side and diagonal is within `tolerance` of the
	///   reference's. The quad is returned as it is.
	/// - One stray corner: three corners fit the reference's by a near-similarity (an affine map
	///   with nearly equal stretch both ways). The fourth is replaced by where that map puts it.
	/// - Otherwise nil.
	static func consistentOutline(_ quad: PageQuad, imageSize: CGSize, reference: PageQuad, referenceSize: CGSize,
								  tolerance: CGFloat = 0.12) -> PageQuad? {
		let own = quad.corners.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) }
		let ref = reference.corners.map { CGPoint(x: $0.x * referenceSize.width, y: $0.y * referenceSize.height) }
		if outlinesMatch(own, ref, tolerance: tolerance) {
			return quad
		}
		var best: (corners: [CGPoint], stretch: CGFloat)?
		for stray in 0..<4 {
			let kept = (0..<4).filter { $0 != stray }
			guard let map = affine(from: kept.map { ref[$0] }, to: kept.map { own[$0] }) else { continue }
			let stretch = map.stretchRatio
			guard stretch <= 1 + tolerance, (0.7...1.4).contains(map.scale) else { continue }
			var repaired = own
			repaired[stray] = map.apply(ref[stray])
			guard outlinesMatch(repaired, ref, tolerance: tolerance), stretch < (best?.stretch ?? .greatestFiniteMagnitude) else { continue }
			best = (repaired, stretch)
		}
		guard let corners = best?.corners else { return nil }
		let normalized = corners.map { CGPoint(x: $0.x / imageSize.width, y: $0.y / imageSize.height) }
		let repaired = PageQuad(topLeft: normalized[0], topRight: normalized[1], bottomRight: normalized[2], bottomLeft: normalized[3])
		return repaired.isConvex ? repaired : nil
	}

	/// True when the outlines' sides and diagonals agree within `tolerance` after one common scale,
	/// and that scale is plausible for the phone moving a little (0.7–1.4).
	private static func outlinesMatch(_ a: [CGPoint], _ b: [CGPoint], tolerance: CGFloat) -> Bool {
		let pairs = [(0, 1), (1, 2), (2, 3), (3, 0), (0, 2), (1, 3)]
		let lengthsA = pairs.map { hypot(a[$0.0].x - a[$0.1].x, a[$0.0].y - a[$0.1].y) }
		let lengthsB = pairs.map { hypot(b[$0.0].x - b[$0.1].x, b[$0.0].y - b[$0.1].y) }
		let totalB = lengthsB.reduce(0, +)
		guard totalB > 0, lengthsB.allSatisfy({ $0 > 0 }) else { return false }
		let scale = lengthsA.reduce(0, +) / totalB
		guard (0.7...1.4).contains(scale) else { return false }
		return zip(lengthsA, lengthsB).allSatisfy { abs($0 / ($1 * scale) - 1) <= tolerance }
	}

	/// A 2-D affine map: `p′ = linear · p + offset`.
	private struct Affine {
		var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat
		var tx: CGFloat, ty: CGFloat

		func apply(_ p: CGPoint) -> CGPoint {
			CGPoint(x: a * p.x + b * p.y + tx, y: c * p.x + d * p.y + ty)
		}

		/// The linear part's singular values, largest first.
		private var singularValues: (CGFloat, CGFloat) {
			let e = (a + d) / 2, f = (a - d) / 2, g = (c + b) / 2, h = (c - b) / 2
			let q = hypot(e, h), r = hypot(f, g)
			return (q + r, abs(q - r))
		}

		/// Largest over smallest stretch: 1 for a similarity (rotation and uniform scale).
		var stretchRatio: CGFloat {
			let (large, small) = singularValues
			return small > 1e-9 ? large / small : .greatestFiniteMagnitude
		}

		/// The geometric-mean scale.
		var scale: CGFloat {
			let (large, small) = singularValues
			return (large * small).squareRoot()
		}
	}

	/// The affine map taking three points exactly onto three others; nil when they are collinear.
	private static func affine(from source: [CGPoint], to target: [CGPoint]) -> Affine? {
		guard source.count == 3, target.count == 3 else { return nil }
		let (p0, p1, p2) = (source[0], source[1], source[2])
		let u = CGVector(dx: p1.x - p0.x, dy: p1.y - p0.y)
		let v = CGVector(dx: p2.x - p0.x, dy: p2.y - p0.y)
		let det = u.dx * v.dy - u.dy * v.dx
		guard abs(det) > 1e-9 else { return nil }
		let su = CGVector(dx: target[1].x - target[0].x, dy: target[1].y - target[0].y)
		let sv = CGVector(dx: target[2].x - target[0].x, dy: target[2].y - target[0].y)
		// linear · [u v] = [su sv]  ⇒  linear = [su sv] · [u v]⁻¹
		let a = (su.dx * v.dy - sv.dx * u.dy) / det
		let b = (sv.dx * u.dx - su.dx * v.dx) / det
		let c = (su.dy * v.dy - sv.dy * u.dy) / det
		let d = (sv.dy * u.dx - su.dy * v.dx) / det
		return Affine(a: a, b: b, c: c, d: d, tx: target[0].x - (a * p0.x + b * p0.y), ty: target[0].y - (c * p0.x + d * p0.y))
	}

	static func atOrigin(_ image: CIImage) -> CIImage {
		let origin = image.extent.origin
		guard !image.extent.isInfinite, origin != .zero else { return image }
		return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
	}

	/// `image` over mid-grey, so pixels the photo does not reach are opaque.
	static func opaque(_ image: CIImage, in rect: CGRect) -> CIImage {
		image.composited(over: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: rect))
	}
}

// MARK: - Local refinement

extension GlareFusion {

	/// Target tile side, in registration pixels, for measuring local shifts.
	private static let localTileSide: CGFloat = 110

	/// Resamples every non-reference layer along its measured displacement field (see
	/// `Options.refinesLocally`). Layers must already be materialized. A layer whose field can't be
	/// measured, or is negligible, is left as it is.
	fileprivate static func refineLocally(_ stack: inout AlignedStack, context: CIContext, options: Options) {
		guard stack.layers.count > 1, let referenceLayer = stack.layers.first else { return }
		let pageSize = stack.pageSize
		let scale = min(1, options.registrationSize / max(pageSize.width, pageSize.height))
		let targetSize = CGSize(width: (pageSize.width * scale).rounded(), height: (pageSize.height * scale).rounded())
		guard targetSize.width >= 64, targetSize.height >= 64,
			  let reference = registrationPlane(referenceLayer, pageSize: pageSize, targetSize: targetSize, context: context) else { return }
		let limit = options.maxLocalShift * max(targetSize.width, targetSize.height)
		for index in stack.layers.indices.dropFirst() {
			autoreleasepool {
				guard let plane = registrationPlane(stack.layers[index], pageSize: pageSize, targetSize: targetSize, context: context),
					  let field = DisplacementField.measure(reference: reference, frame: plane, limit: limit),
					  field.meanMagnitude >= 0.3,
					  let image = stack.layers[index].source.cgImage,
					  let resampled = field.resample(image, pageScale: pageSize.width / targetSize.width) else { return }
				stack.layers[index].source = CIImage(cgImage: resampled)
				stack.layers[index].report.localShift = Float(field.meanMagnitude * pageSize.width / targetSize.width)
			}
		}
	}

	/// Local shifts on a grid of tiles over the page: for each tile centre in the reference, where
	/// the frame shows the same paper, as an offset in registration pixels (rows top to bottom).
	struct DisplacementField {
		let columns: Int
		let rows: Int
		/// Tile size in registration pixels.
		let tileWidth: CGFloat
		let tileHeight: CGFloat
		/// Offsets, row-major from the top-left tile.
		var offsets: [CGVector]

		var meanMagnitude: CGFloat {
			offsets.reduce(0) { $0 + hypot($1.dx, $1.dy) } / CGFloat(max(1, offsets.count))
		}

		/// Measures the field with Vision's translational registration tile by tile (tiles with too
		/// little ink in either image, or a shift beyond `limit`, are filled from their neighbours),
		/// then replaces outliers by their neighbours' median and smooths it. Nil when no tile could
		/// be measured.
		static func measure(reference: Plane, frame: Plane, limit: CGFloat) -> DisplacementField? {
			guard reference.width == frame.width, reference.height == frame.height else { return nil }
			let columns = max(3, Int((CGFloat(reference.width) / localTileSide).rounded()))
			let rows = max(3, Int((CGFloat(reference.height) / localTileSide).rounded()))
			let tileWidth = CGFloat(reference.width) / CGFloat(columns)
			let tileHeight = CGFloat(reference.height) / CGFloat(rows)
			var measured = [CGVector?](repeating: nil, count: columns * rows)
			for row in 0..<rows {
				for column in 0..<columns {
					let margin = tileWidth / 3
					let x0 = max(0, Int(CGFloat(column) * tileWidth - margin))
					let y0 = max(0, Int(CGFloat(row) * tileHeight - margin))
					let x1 = min(reference.width, Int(CGFloat(column + 1) * tileWidth + margin))
					let y1 = min(reference.height, Int(CGFloat(row + 1) * tileHeight + margin))
					measured[row * columns + column] = tileShift(reference, frame, x0: x0, y0: y0, x1: x1, y1: y1, limit: limit)
				}
			}
			guard measured.contains(where: { $0 != nil }) else { return nil }
			var field = DisplacementField(columns: columns, rows: rows, tileWidth: tileWidth, tileHeight: tileHeight,
										  offsets: fillGaps(measured, columns: columns, rows: rows))
			field.rejectOutliers()
			field.smooth()
			return field
		}

		/// Where the frame shows the paper of one reference tile, or nil when the tile has too little
		/// ink to tell. Vision's `alignmentTransform` maps the floating (frame) image onto the
		/// reference with a bottom-left origin, so the frame shows a reference point at (−tx, +ty)
		/// from it in rows top to bottom.
		private static func tileShift(_ reference: Plane, _ frame: Plane, x0: Int, y0: Int, x1: Int, y1: Int, limit: CGFloat) -> CGVector? {
			let width = x1 - x0
			let height = y1 - y0
			guard width >= 16, height >= 16 else { return nil }
			let referenceTile = crop(reference, x0: x0, y0: y0, width: width, height: height)
			let frameTile = crop(frame, x0: x0, y0: y0, width: width, height: height)
			let enough = Float(width * height) / 50
			guard referenceTile.indicator(atLeast: 0.6).complement().sum > enough,
				  frameTile.indicator(atLeast: 0.6).complement().sum > enough,
				  let referenceImage = referenceTile.grayImage(), let frameImage = frameTile.grayImage() else { return nil }
			let request = VNTranslationalImageRegistrationRequest(targetedCGImage: frameImage, options: [:])
			guard (try? VNImageRequestHandler(cgImage: referenceImage, options: [:]).perform([request])) != nil,
				  let transform = (request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform else { return nil }
			let offset = CGVector(dx: -transform.tx, dy: transform.ty)
			return hypot(offset.dx, offset.dy) <= limit ? offset : nil
		}

		private static func crop(_ plane: Plane, x0: Int, y0: Int, width: Int, height: Int) -> Plane {
			var tile = Plane(width: width, height: height)
			for row in 0..<height {
				let source = (y0 + row) * plane.width + x0
				tile.values.replaceSubrange(row * width..<(row + 1) * width, with: plane.values[source..<source + width])
			}
			return tile
		}

		/// Unmeasured tiles take the mean of their measured neighbours, ring by ring outward.
		private static func fillGaps(_ measured: [CGVector?], columns: Int, rows: Int) -> [CGVector] {
			var values = measured
			for _ in 0..<(columns + rows) {
				guard values.contains(where: { $0 == nil }) else { break }
				let previous = values
				for index in values.indices where previous[index] == nil {
					let known = neighbours(of: index, columns: columns, rows: rows).compactMap { previous[$0] }
					guard !known.isEmpty else { continue }
					values[index] = CGVector(dx: known.reduce(0) { $0 + $1.dx } / CGFloat(known.count),
											 dy: known.reduce(0) { $0 + $1.dy } / CGFloat(known.count))
				}
			}
			return values.map { $0 ?? CGVector(dx: 0, dy: 0) }
		}

		private static func neighbours(of index: Int, columns: Int, rows: Int) -> [Int] {
			let row = index / columns
			let column = index % columns
			var result: [Int] = []
			for dy in -1...1 {
				for dx in -1...1 where dx != 0 || dy != 0 {
					let r = row + dy
					let c = column + dx
					if r >= 0, r < rows, c >= 0, c < columns { result.append(r * columns + c) }
				}
			}
			return result
		}

		/// A tile more than 2 px from its neighbours' median takes that median (a blank tile's
		/// registration can latch onto anything).
		private mutating func rejectOutliers() {
			let previous = offsets
			for index in offsets.indices {
				let around = Self.neighbours(of: index, columns: columns, rows: rows).map { previous[$0] }
				guard around.count >= 3 else { continue }
				let median = CGVector(dx: around.map(\.dx).sorted()[around.count / 2], dy: around.map(\.dy).sorted()[around.count / 2])
				if hypot(previous[index].dx - median.dx, previous[index].dy - median.dy) > 2 {
					offsets[index] = median
				}
			}
		}

		/// One pass of a 3 × 3 mean, so neighbouring tiles' shifts change gradually.
		private mutating func smooth() {
			let previous = offsets
			for index in offsets.indices {
				let around = Self.neighbours(of: index, columns: columns, rows: rows).map { previous[$0] } + [previous[index], previous[index]]
				offsets[index] = CGVector(dx: around.reduce(0) { $0 + $1.dx } / CGFloat(around.count),
										  dy: around.reduce(0) { $0 + $1.dy } / CGFloat(around.count))
			}
		}

		/// The offset at a point in registration pixels: bilinear between tile centres, held at the
		/// border tiles beyond them.
		func offset(atX x: CGFloat, y: CGFloat) -> CGVector {
			let fx = min(max(x / tileWidth - 0.5, 0), CGFloat(columns - 1))
			let fy = min(max(y / tileHeight - 0.5, 0), CGFloat(rows - 1))
			let c0 = min(Int(fx), columns - 1)
			let r0 = min(Int(fy), rows - 1)
			let c1 = min(c0 + 1, columns - 1)
			let r1 = min(r0 + 1, rows - 1)
			let tx = fx - CGFloat(c0)
			let ty = fy - CGFloat(r0)
			func at(_ r: Int, _ c: Int) -> CGVector { offsets[r * columns + c] }
			let top = CGVector(dx: at(r0, c0).dx * (1 - tx) + at(r0, c1).dx * tx, dy: at(r0, c0).dy * (1 - tx) + at(r0, c1).dy * tx)
			let bottom = CGVector(dx: at(r1, c0).dx * (1 - tx) + at(r1, c1).dx * tx, dy: at(r1, c0).dy * (1 - tx) + at(r1, c1).dy * tx)
			return CGVector(dx: top.dx * (1 - ty) + bottom.dx * ty, dy: top.dy * (1 - ty) + bottom.dy * ty)
		}

		/// `image` (the frame's page, 8-bit RGBA) resampled so each pixel shows what the frame shows
		/// at that point plus the field's offset; `pageScale` is page pixels per registration pixel.
		/// Bilinear, premultiplied; pixels that land outside the frame are transparent.
		func resample(_ image: CGImage, pageScale: CGFloat) -> CGImage? {
			let width = image.width
			let height = image.height
			let rowBytes = width * 4
			guard width > 1, height > 1, pageScale > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
			let info = CGImageAlphaInfo.premultipliedLast.rawValue
			var source = [UInt8](repeating: 0, count: rowBytes * height)
			let drawn = source.withUnsafeMutableBytes { buffer -> Bool in
				guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
											  bytesPerRow: rowBytes, space: space, bitmapInfo: info) else { return false }
				context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
				return true
			}
			guard drawn else { return nil }
			var output = [UInt8](repeating: 0, count: rowBytes * height)
			// The field changes slowly, so it is evaluated every `step` pixels and held between.
			let step = 8
			source.withUnsafeBufferPointer { src in
				output.withUnsafeMutableBufferPointer { dst in
					for y in 0..<height {
						var offset = CGVector(dx: 0, dy: 0)
						for x in 0..<width {
							if x % step == 0 {
								offset = self.offset(atX: CGFloat(x) / pageScale, y: CGFloat(y) / pageScale)
							}
							let sx = CGFloat(x) + offset.dx * pageScale
							let sy = CGFloat(y) + offset.dy * pageScale
							guard sx >= 0, sy >= 0, sx < CGFloat(width - 1), sy < CGFloat(height - 1) else { continue }
							let x0 = Int(sx)
							let y0 = Int(sy)
							let fx = Float(sx - CGFloat(x0))
							let fy = Float(sy - CGFloat(y0))
							let i00 = y0 * rowBytes + x0 * 4
							let i10 = i00 + 4
							let i01 = i00 + rowBytes
							let i11 = i01 + 4
							let out = y * rowBytes + x * 4
							for channel in 0..<4 {
								let top = Float(src[i00 + channel]) * (1 - fx) + Float(src[i10 + channel]) * fx
								let bottom = Float(src[i01 + channel]) * (1 - fx) + Float(src[i11 + channel]) * fx
								dst[out + channel] = UInt8(min(255, max(0, (top * (1 - fy) + bottom * fy).rounded())))
							}
						}
					}
				}
			}
			guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
			return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space,
						   bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false,
						   intent: .defaultIntent)
		}
	}
}

// MARK: - Registration

extension GlareFusion {

	/// Refines frames' placement against the reference with Vision's homographic registration.
	///
	/// Registration runs on luminance divided by the frame's paper level and clamped at 1, so glare
	/// (and the paper around it) is flat white and only ink can pull the frames together.
	/// `VNImageHomographicAlignmentObservation.warpTransform` maps the floating (frame) image's
	/// pixels onto the reference's, both with a bottom-left origin.
	private struct Registrar {
		let context: CIContext
		let pageSize: CGSize
		let targetSize: CGSize
		let referencePlane: Plane
		let referenceImage: CGImage
		let referenceSteepness: Float?
		let maxShift: CGFloat
		let maxDifferenceRatio: Float

		init?(reference: Layer, pageSize: CGSize, context: CIContext, options: Options) {
			let scale = min(1, options.registrationSize / max(pageSize.width, pageSize.height))
			let targetSize = CGSize(width: (pageSize.width * scale).rounded(), height: (pageSize.height * scale).rounded())
			guard targetSize.width >= 32, targetSize.height >= 32,
				  let plane = GlareFusion.registrationPlane(reference, pageSize: pageSize, targetSize: targetSize, context: context),
				  let image = plane.grayImage() else { return nil }
			self.context = context
			self.pageSize = pageSize
			self.targetSize = targetSize
			referencePlane = plane
			referenceImage = image
			referenceSteepness = plane.edgeSteepness()
			maxShift = options.maxRefinementShift * max(targetSize.width, targetSize.height)
			maxDifferenceRatio = options.maxRefinedDifferenceRatio
		}

		/// Replaces `layer`'s homography with the refined one when registration succeeds and
		/// lowers the difference to the reference; otherwise records why not.
		func refine(_ layer: inout Layer) {
			guard let plane = GlareFusion.registrationPlane(layer, pageSize: pageSize, targetSize: targetSize, context: context),
				  let image = plane.grayImage() else {
				layer.report.alignment = .quad("The frame could not be rendered for registration.")
				return
			}
			if let steepness = plane.edgeSteepness(), let reference = referenceSteepness, reference > 0 {
				layer.report.sharpness = steepness / reference
			}
			let warp: Homography
			switch register(image) {
			case .success(let found):
				warp = found
			case .failure(let failure):
				layer.report.alignment = .quad(failure.reason)
				return
			}
			let shift = cornerShift(of: warp)
			guard shift <= maxShift else {
				layer.report.alignment = .quad("Registration moved the page too far to trust.")
				return
			}
			guard let moved = GlareFusion.warped(plane, by: warp, context: context) else {
				layer.report.alignment = .quad("The registered frame could not be rendered.")
				return
			}
			// Compare before and after over the same pixels: those the moved frame still covers.
			let mask = moved.coverage.indicator(atLeast: 0.99)
			let before = Plane.meanAbsoluteDifference(referencePlane, plane, mask: mask)
			let after = Plane.meanAbsoluteDifference(referencePlane, moved.values, mask: mask)
			layer.report.differenceBefore = before
			layer.report.differenceAfter = after
			guard let after, let before, after < before else {
				layer.report.alignment = .quad("Registration did not improve the alignment.")
				return
			}
			guard after <= before * maxDifferenceRatio else {
				layer.report.alignment = .quad("Registration improved the alignment too little to trust.")
				return
			}
			let toTarget = Homography.scaling(x: targetSize.width / pageSize.width, y: targetSize.height / pageSize.height)
			let toPage = Homography.scaling(x: pageSize.width / targetSize.width, y: pageSize.height / targetSize.height)
			layer.homography = layer.homography.followed(by: toTarget).followed(by: warp).followed(by: toPage)
			layer.report.alignment = .refined(shift: shift * pageSize.width / targetSize.width)
		}

		/// Vision's floating → reference homography for `image`, or why there is none.
		private func register(_ image: CGImage) -> Swift.Result<Homography, RegistrationFailure> {
			let request = VNHomographicImageRegistrationRequest(targetedCGImage: image, options: [:])
			let handler = VNImageRequestHandler(cgImage: referenceImage, options: [:])
			do {
				try handler.perform([request])
			} catch {
				return .failure(RegistrationFailure("Registration failed: \(error.localizedDescription)"))
			}
			guard let observation = request.results?.first as? VNImageHomographicAlignmentObservation else {
				return .failure(RegistrationFailure("Registration found no alignment."))
			}
			return .success(Homography(observation.warpTransform))
		}

		/// The largest distance a corner of the registration image moves under `warp`.
		private func cornerShift(of warp: Homography) -> CGFloat {
			let corners = [
				CGPoint.zero,
				CGPoint(x: targetSize.width, y: 0),
				CGPoint(x: targetSize.width, y: targetSize.height),
				CGPoint(x: 0, y: targetSize.height),
			]
			return corners.reduce(CGFloat(0)) { result, corner in
				guard let moved = warp.apply(corner) else { return .greatestFiniteMagnitude }
				return max(result, hypot(moved.x - corner.x, moved.y - corner.y))
			}
		}
	}

	/// Why a registration attempt produced nothing, for the frame report.
	private struct RegistrationFailure: Error {
		let reason: String
		init(_ reason: String) { self.reason = reason }
	}

	/// The layer at registration size: luminance over the frame's paper level, clamped at 1, with
	/// uncovered pixels white.
	private static func registrationPlane(_ layer: Layer, pageSize: CGSize, targetSize: CGSize, context: CIContext) -> Plane? {
		let target = CGRect(origin: .zero, size: targetSize)
		guard let page = layer.page(pageSize: pageSize, targetSize: targetSize) else { return nil }
		let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: target)
		guard let luminance = renderGray(page.composited(over: white), weights: luminanceWeights, bounds: target, context: context),
			  let paper = luminance.percentile(0.6), paper > 0.01 else { return nil }
		return luminance.scaled(by: 1 / paper).clipped(to: 0...1)
	}

	/// `plane` moved by `warp` (in its own Core Image points) at the same size, and how much of each
	/// pixel the moved plane covers.
	private static func warped(_ plane: Plane, by warp: Homography, context: CIContext) -> (values: Plane, coverage: Plane)? {
		let bounds = CGRect(x: 0, y: 0, width: plane.width, height: plane.height)
		guard let moved = GlareFusion.warp(plane.ciImage(), by: warp, to: bounds),
			  let values = renderGray(moved, weights: CIVector(x: 1, y: 0, z: 0, w: 0), bounds: bounds, context: context),
			  let coverage = renderGray(moved, weights: CIVector(x: 0, y: 0, z: 0, w: 1), bounds: bounds, context: context) else {
			return nil
		}
		return (values, coverage)
	}
}

// MARK: - Analysis

extension GlareFusion {

	/// The per-frame numbers the blend needs, at analysis size.
	private struct Analysis {
		var gains: [SIMD3<Float>]
		/// Normalized blend weights, one per layer.
		var weights: [Plane]
		/// Per-pixel minimum glare score over the frames that cover it.
		var residual: Plane
	}

	/// One layer rendered at analysis size: colour (un-premultiplied, linear) and coverage.
	private struct Sample {
		var channels: [Plane]
		var coverage: Plane
	}

	/// Rec. 709 luminance weights for `renderGray`.
	private static var luminanceWeights: CIVector {
		CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
	}

	/// Steps 2–4 of the overview at analysis size; fills in the layers' reports.
	private static func analyse(_ stack: inout AlignedStack, context: CIContext, options: Options) throws -> Analysis {
		let pageSize = stack.pageSize
		let scale = min(1, options.analysisSize / max(pageSize.width, pageSize.height))
		let targetSize = CGSize(width: max(8, (pageSize.width * scale).rounded()), height: max(8, (pageSize.height * scale).rounded()))
		var samples: [Sample] = []
		for layer in stack.layers {
			guard let sample = analysisSample(layer, pageSize: pageSize, targetSize: targetSize, context: context) else {
				throw FusionError.renderFailed
			}
			samples.append(sample)
		}
		guard let referenceSample = samples.first else { throw FusionError.renderFailed }
		let gains = samples.map { exposureGain(reference: referenceSample.channels, frame: $0, clipLevel: options.clipLevel) }
		let radius = max(2, Int((max(targetSize.width, targetSize.height) * 0.02).rounded()))
		let scores = glareScores(samples, gains: gains, radius: radius, options: options)
		let priors = stack.layers.indices.map { prior(for: stack.layers[$0].report, isReference: $0 == 0, options: options) }
		let weights = blendWeights(scores, coverage: samples.map(\.coverage), priors: priors, radius: max(1, radius / 2), options: options)
		let residual = residualGlare(scores, coverage: samples.map(\.coverage))
		for index in stack.layers.indices {
			let coverage = samples[index].coverage
			let covered = coverage.sum
			let glary = scores[index].indicator(atLeast: options.glareThreshold).multiplied(by: coverage).sum
			stack.layers[index].report.gain = gains[index]
			stack.layers[index].report.coverage = coverage.mean
			stack.layers[index].report.glareFraction = covered > 0 ? glary / covered : 0
		}
		return Analysis(gains: gains, weights: weights, residual: residual)
	}

	/// Renders a layer at analysis size and derives its coverage from the rendered alpha: 1 well
	/// inside the photo, ramping to 0 over the last couple of pixels before its edge.
	private static func analysisSample(_ layer: Layer, pageSize: CGSize, targetSize: CGSize, context: CIContext) -> Sample? {
		let target = CGRect(origin: .zero, size: targetSize)
		guard let page = layer.page(pageSize: pageSize, targetSize: targetSize),
			  let channels = renderPlanes(page, bounds: target, context: context), channels.count == 4 else { return nil }
		let coverage = channels[3].indicator(atLeast: 0.99).boxBlurred(radius: 2).scaled(by: 5, plus: -4).clipped(to: 0...1)
		return Sample(channels: Array(channels.prefix(3)), coverage: coverage)
	}

	/// Per-channel gain matching `frame` to the reference: the median ratio over pixels both see
	/// well exposed (neither dark ink nor near clipping). 1 when too few pixels qualify.
	private static func exposureGain(reference: [Plane], frame: Sample, clipLevel: Float) -> SIMD3<Float> {
		var gain = SIMD3<Float>(repeating: 1)
		let ceiling = clipLevel * 0.9
		let covered = frame.coverage.indicator(atLeast: 0.99)
		for channel in 0..<3 {
			let mine = frame.channels[channel]
			let theirs = reference[channel]
			let usable = covered
				.multiplied(by: mine.indicator(atLeast: 0.08)).multiplied(by: theirs.indicator(atLeast: 0.08))
				.multiplied(by: mine.indicator(atLeast: ceiling).complement()).multiplied(by: theirs.indicator(atLeast: ceiling).complement())
			let count = Int(usable.sum.rounded())
			guard count >= 64 else { continue }
			// Unusable pixels get a huge ratio, so they sort after every real one.
			let ratio = theirs.divided(by: mine.clipped(to: 1e-3...Float.greatestFiniteMagnitude))
			var keyed = ratio.multiplied(by: usable).adding(usable.complement().scaled(by: 1e9)).values
			if let median = Plane.percentile(of: &keyed, count: count, 0.5) {
				gain[channel] = median
			}
		}
		return gain
	}

	/// Each frame's glare score: the additive offset of its luminance over the stack minimum (as a
	/// fraction of paper), from a local linear fit, plus the share of nearby clipped pixels.
	private static func glareScores(_ samples: [Sample], gains: [SIMD3<Float>], radius: Int, options: Options) -> [Plane] {
		let lumas = zip(samples, gains).map { Plane.luminance($0.0.channels, gain: $0.1) }
		guard let first = lumas.first else { return [] }
		var minimum = first
		for (luma, sample) in zip(lumas, samples).dropFirst() {
			// Pixels a frame does not cover are pushed out of the minimum.
			minimum = minimum.minimum(luma.adding(sample.coverage.indicator(atLeast: 0.5).complement().scaled(by: 1e3)))
		}
		let paper = max(minimum.percentile(0.75) ?? 1, 0.02)
		let lambda = (0.03 * paper) * (0.03 * paper)
		let meanMinimum = minimum.boxBlurred(radius: radius)
		let variance = minimum.multiplied(by: minimum).boxBlurred(radius: radius)
			.subtracting(meanMinimum.multiplied(by: meanMinimum)).clipped(to: 0...Float.greatestFiniteMagnitude)
		return zip(lumas, samples).map { luma, sample in
			let meanLuma = luma.boxBlurred(radius: radius)
			let covariance = luma.multiplied(by: minimum).boxBlurred(radius: radius).subtracting(meanLuma.multiplied(by: meanMinimum))
			let slope = covariance.adding(lambda).divided(by: variance.adding(lambda)).clipped(to: 1...1.8)
			let offset = meanLuma.subtracting(slope.multiplied(by: meanMinimum))
			let clipped = Plane.clippedIndicator(sample.channels, level: options.clipLevel).boxBlurred(radius: radius)
			return offset.clipped(to: 0...Float.greatestFiniteMagnitude).scaled(by: 1 / paper).adding(clipped)
		}
	}

	/// A frame's log prior weight: the reference's preference plus its sharpness term.
	private static func prior(for report: FrameReport, isReference: Bool, options: Options) -> Float {
		let preference = isReference ? log(max(options.referenceWeight, 1e-3)) : 0
		guard let sharpness = report.sharpness else { return preference }
		return preference + options.sharpnessExponent * log(min(max(sharpness, 0.05), 1.5))
	}

	/// Soft-minimum blend weights: `exp(prior) · coverage · exp(−score / glareScale)`, smoothed so
	/// transitions have no seams, then normalized to sum to 1 at every pixel.
	private static func blendWeights(_ scores: [Plane], coverage: [Plane], priors: [Float], radius: Int, options: Options) -> [Plane] {
		guard !scores.isEmpty, priors.count == scores.count, coverage.count == scores.count else { return [] }
		let scale = max(options.fillsOnlyGlare ? options.fillGlareScale : options.glareScale, 1e-4)
		// Log weights, with pixels a frame does not cover pushed far down so they never win.
		let logWeights = scores.indices.map { frame in
			scores[frame].scaled(by: -1 / scale, plus: priors[frame])
				.subtracting(coverage[frame].indicator(atLeast: 1e-3).complement().scaled(by: 1e4))
		}
		let best = logWeights.dropFirst().reduce(logWeights[0]) { $0.maximum($1) }
		var smoothed = logWeights.indices.map { frame in
			logWeights[frame].subtracting(best).clipped(to: -60...0).exponential().multiplied(by: coverage[frame]).boxBlurred(radius: radius)
		}
		if options.fillsOnlyGlare, smoothed.count > 1 {
			// Where the reference needs filling: its glare score ramped from fillStart to fillFull,
			// grown a little past the glare's edge so its washed-out rim is filled too, and feathered.
			let span = max(options.fillFull - options.fillStart, 1e-4)
			let need = scores[0].scaled(by: 1 / span, plus: -options.fillStart / span).clipped(to: 0...1)
				.boxBlurred(radius: radius * 2).scaled(by: 3).clipped(to: 0...1)
				.boxBlurred(radius: max(1, radius / 2))
			for frame in smoothed.indices.dropFirst() {
				smoothed[frame] = smoothed[frame].multiplied(by: need)
			}
		}
		let total = smoothed.dropFirst().reduce(smoothed[0]) { $0.adding($1) }
		let safeTotal = total.clipped(to: 1e-6...Float.greatestFiniteMagnitude)
		var weights = smoothed.map { $0.divided(by: safeTotal) }
		// Where no frame has weight (it cannot happen inside the reference), keep the reference.
		weights[0] = weights[0].adding(total.indicator(atLeast: 1e-6).complement())
		return weights
	}

	/// The smallest glare score any covering frame has at each pixel (0 where none covers it).
	private static func residualGlare(_ scores: [Plane], coverage: [Plane]) -> Plane {
		guard let first = scores.first else { return Plane(width: 1, height: 1) }
		var residual = Plane(width: first.width, height: first.height, repeating: 1e3)
		for (score, covered) in zip(scores, coverage) {
			residual = residual.minimum(score.adding(covered.indicator(atLeast: 0.5).complement().scaled(by: 1e3)))
		}
		return residual.multiplied(by: residual.indicator(atLeast: 999).complement())
	}

	/// Red, green, blue and alpha of `image` over `bounds` (colour un-premultiplied, linear), rows
	/// top to bottom. Nil when Core Image cannot render.
	static func renderPlanes(_ image: CIImage, bounds: CGRect, context: CIContext) -> [Plane]? {
		let picks = [
			CIVector(x: 1, y: 0, z: 0, w: 0),
			CIVector(x: 0, y: 1, z: 0, w: 0),
			CIVector(x: 0, y: 0, z: 1, w: 0),
			CIVector(x: 0, y: 0, z: 0, w: 1),
		]
		var planes: [Plane] = []
		for pick in picks {
			guard let plane = renderGray(image, weights: pick, bounds: bounds, context: context) else { return nil }
			planes.append(plane)
		}
		return planes
	}

	/// `weights · (r, g, b, a)` of `image` (colour un-premultiplied, linear) over `bounds`, rendered
	/// through an 8-bit gamma-2.2 grey image and decoded back to linear light, rows top to bottom.
	static func renderGray(_ image: CIImage, weights: CIVector, bounds: CGRect, context: CIContext) -> Plane? {
		let width = Int(bounds.width)
		let height = Int(bounds.height)
		guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else { return nil }
		let mix = CIFilter.colorMatrix()
		mix.inputImage = image
		mix.rVector = weights
		mix.gVector = weights
		mix.bVector = weights
		mix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
		mix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
		guard let output = mix.outputImage,
			  let rendered = context.createCGImage(output, from: bounds, format: .L8, colorSpace: space),
			  rendered.width == width, rendered.height == height, rendered.bitsPerPixel == 8,
			  let data = rendered.dataProvider?.data as Data? else { return nil }
		return Plane(grayBytes: [UInt8](data), width: width, height: height, rowBytes: rendered.bytesPerRow)
	}
}

// MARK: - Blend

extension GlareFusion {

	/// The full-size weighted sum of the gain-matched frames (step 4 of the overview).
	private static func blend(_ stack: AlignedStack, analysis: Analysis) throws -> CIImage {
		let rect = CGRect(origin: .zero, size: stack.pageSize)
		var sum: CIImage?
		for (index, layer) in stack.layers.enumerated() {
			guard let page = layer.page(pageSize: stack.pageSize, targetSize: stack.pageSize) else { continue }
			let matched = scaled(opaque(page, in: rect), by: analysis.gains[index])
			let weight = upscaled(analysis.weights[index].ciImage(), to: rect)
			let term = multiply(matched, weight)
			sum = sum.map { add($0, term) } ?? term
		}
		guard let sum else { throw FusionError.renderFailed }
		return sum.cropped(to: rect)
	}

	/// A small weight image stretched over `rect` with bilinear sampling (edges extended).
	private static func upscaled(_ image: CIImage, to rect: CGRect) -> CIImage {
		let extent = image.extent
		guard extent.width > 0, extent.height > 0 else { return image }
		let stretch = CGAffineTransform(scaleX: rect.width / extent.width, y: rect.height / extent.height)
		return image.clampedToExtent().transformed(by: stretch).cropped(to: rect)
	}

	/// Per-channel gains on RGB; alpha untouched.
	private static func scaled(_ image: CIImage, by gain: SIMD3<Float>) -> CIImage {
		let filter = CIFilter.colorMatrix()
		filter.inputImage = image
		filter.rVector = CIVector(x: CGFloat(gain.x), y: 0, z: 0, w: 0)
		filter.gVector = CIVector(x: 0, y: CGFloat(gain.y), z: 0, w: 0)
		filter.bVector = CIVector(x: 0, y: 0, z: CGFloat(gain.z), w: 0)
		filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
		return filter.outputImage ?? image
	}

	/// `a · b` per channel.
	private static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
		let filter = CIFilter.multiplyCompositing()
		filter.inputImage = b
		filter.backgroundImage = a
		return filter.outputImage?.cropped(to: a.extent) ?? a
	}

	/// `a + b` per channel, alpha composited normally.
	private static func add(_ a: CIImage, _ b: CIImage) -> CIImage {
		let filter = CIFilter.linearDodgeBlendMode()
		filter.inputImage = b
		filter.backgroundImage = a
		return filter.outputImage?.cropped(to: a.extent) ?? a
	}
}

// MARK: - GlareMap

/// Where on a page there is glare, as a coarse grid in page space (row 0 at the top of the page).
///
/// Built from one photo by `estimate` for the live "is there glare worth another look?" check,
/// and from the fused stack for `GlareFusion.Result.residualMap`.
struct GlareMap: Equatable {
	/// Grid used unless a caller asks otherwise (portrait pages: 6 across, 8 down).
	static let defaultColumns = 6
	static let defaultRows = 8
	/// A cell whose glare share is at least this counts as glary.
	static let cellThreshold: Float = 0.03

	let columns: Int
	let rows: Int
	/// Share of each cell's pixels that show glare, row-major from the top-left.
	private(set) var cells: [Float]

	/// A map from explicit cell values; nil unless `cells.count == columns × rows`.
	init?(columns: Int, rows: Int, cells: [Float]) {
		guard columns > 0, rows > 0, cells.count == columns * rows else { return nil }
		self.columns = columns
		self.rows = rows
		self.cells = cells
	}

	/// Pools a per-pixel plane (rows top to bottom) into cells: each cell's share of pixels for
	/// which `isGlare` holds.
	init(plane: Plane, columns: Int, rows: Int, isGlare: (Float) -> Bool) {
		let columns = max(1, columns)
		let rows = max(1, rows)
		var hits = [Float](repeating: 0, count: columns * rows)
		var totals = [Float](repeating: 0, count: columns * rows)
		for row in 0..<plane.height {
			let cellRow = min(rows - 1, row * rows / max(1, plane.height))
			for column in 0..<plane.width {
				let cell = cellRow * columns + min(columns - 1, column * columns / max(1, plane.width))
				totals[cell] += 1
				if isGlare(plane.values[row * plane.width + column]) { hits[cell] += 1 }
			}
		}
		self.columns = columns
		self.rows = rows
		cells = zip(hits, totals).map { $0.1 > 0 ? $0.0 / $0.1 : 0 }
	}

	/// True when no cell reaches `cellThreshold`.
	var isClear: Bool {
		!cells.contains { $0 >= Self.cellThreshold }
	}

	/// Share of cells that are glary.
	var glaryShare: Float {
		Float(cells.filter { $0 >= Self.cellThreshold }.count) / Float(max(1, cells.count))
	}

	/// Which cells are glary, row-major from the top-left.
	var glaryCells: [Bool] {
		cells.map { $0 >= Self.cellThreshold }
	}

	/// A quick single-photo glare estimate for the live check (one video frame or still).
	///
	/// The page is warped to `sampleSize` on its long side; a pixel is glare when any channel is
	/// near clipping or its luminance is well above the page's paper level (its 75th percentile),
	/// which uneven lighting alone does not reach. Nil when the quad is unusable.
	static func estimate(_ frame: GlareFrame, context: CIContext, columns: Int = defaultColumns, rows: Int = defaultRows,
						 sampleSize: CGFloat = 96, clipLevel: Float = 0.92, sheenRatio: Float = 1.3) -> GlareMap? {
		let source = GlareFusion.atOrigin(frame.image)
		guard let pageSize = GlareFusion.pageSize(for: frame.quad, imageSize: source.extent.size, maxWidth: .greatestFiniteMagnitude),
			  let map = GlareFusion.quadHomography(frame.quad, imageSize: source.extent.size, pageSize: pageSize) else { return nil }
		let scale = sampleSize / max(pageSize.width, pageSize.height)
		let target = CGRect(x: 0, y: 0, width: max(4, (pageSize.width * scale).rounded()), height: max(4, (pageSize.height * scale).rounded()))
		guard let page = GlareFusion.pageImage(source, homography: map, pageSize: pageSize, targetSize: target.size),
			  let channels = GlareFusion.renderPlanes(page, bounds: target, context: context), channels.count == 4 else { return nil }
		let luminance = Plane.luminance(channels, gain: SIMD3<Float>(repeating: 1))
		let paper = max(luminance.percentile(0.75) ?? 1, 0.02)
		let glare = Plane.clippedIndicator(channels, level: clipLevel)
			.maximum(luminance.indicator(atLeast: paper * sheenRatio))
			.multiplied(by: channels[3].indicator(atLeast: 0.5))
		return GlareMap(plane: glare, columns: columns, rows: rows) { $0 > 0.5 }
	}
}

// MARK: - GlareCoverage

/// A direction in page space (`up` is toward the page's top edge), or on screen.
enum PageDirection: Equatable {
	case left
	case right
	case up
	case down

	/// This page-space direction as seen on screen, given the page's outline in the upright
	/// preview frame (normalized, top-left origin; see `PageQuad`).
	func onScreen(for quad: PageQuad) -> PageDirection {
		func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
		let right = mid(quad.topRight, quad.bottomRight)
		let left = mid(quad.topLeft, quad.bottomLeft)
		let bottom = mid(quad.bottomLeft, quad.bottomRight)
		let top = mid(quad.topLeft, quad.topRight)
		let xAxis = CGVector(dx: right.x - left.x, dy: right.y - left.y)
		let yAxis = CGVector(dx: bottom.x - top.x, dy: bottom.y - top.y)
		let page: CGVector
		switch self {
		case .left: page = CGVector(dx: -xAxis.dx, dy: -xAxis.dy)
		case .right: page = xAxis
		case .up: page = CGVector(dx: -yAxis.dx, dy: -yAxis.dy)
		case .down: page = yAxis
		}
		if abs(page.dx) >= abs(page.dy) {
			return page.dx < 0 ? .left : .right
		}
		return page.dy < 0 ? .up : .down
	}
}

/// Tracks, over the shots of one page, which glary parts of the first shot have since been seen
/// without glare, and which way to move for the rest.
///
/// The highlight is where the light mirrors into the lens, so it moves when the camera *moves*
/// (in the same direction, by a fraction set by the lamp's height) and not when the phone only
/// rotates about its lens. `suggestedMove` therefore names a direction to slide the phone: toward
/// the page edge nearest the remaining glare, which carries the highlight onto the margin or off
/// the page.
struct GlareCoverage: Equatable {
	let columns: Int
	let rows: Int
	/// Cells glary in the first shot and in every shot since.
	private(set) var pending: [Bool]

	/// Starts from the first (reference) shot's map.
	init(first map: GlareMap) {
		columns = map.columns
		rows = map.rows
		pending = map.cells.map { $0 >= GlareMap.cellThreshold }
	}

	/// Clears every pending cell that `map` sees without glare. Maps of another grid are ignored.
	mutating func add(_ map: GlareMap) {
		guard map.columns == columns, map.rows == rows else { return }
		for index in pending.indices where pending[index] && map.cells[index] < GlareMap.cellThreshold {
			pending[index] = false
		}
	}

	/// True once every glary part of the first shot has a glare-free view.
	var isComplete: Bool {
		!pending.contains(true)
	}

	/// How many cells still need a glare-free view.
	var pendingCount: Int {
		pending.filter { $0 }.count
	}

	/// Which way (in page space) to slide the phone next, or nil when complete.
	var suggestedMove: PageDirection? {
		var sumX: CGFloat = 0
		var sumY: CGFloat = 0
		var count: CGFloat = 0
		for index in pending.indices where pending[index] {
			sumX += (CGFloat(index % columns) + 0.5) / CGFloat(columns)
			sumY += (CGFloat(index / columns) + 0.5) / CGFloat(rows)
			count += 1
		}
		guard count > 0 else { return nil }
		let offsetX = sumX / count - 0.5
		let offsetY = sumY / count - 0.5
		if abs(offsetX) >= abs(offsetY) {
			return offsetX <= 0 ? .left : .right
		}
		return offsetY < 0 ? .up : .down
	}

	/// How many pending cells `map` sees without glare; 0 for a map of another grid.
	func clearedCount(in map: GlareMap) -> Int {
		guard map.columns == columns, map.rows == rows else { return 0 }
		return pending.indices.filter { pending[$0] && map.cells[$0] < GlareMap.cellThreshold }.count
	}
}

// MARK: - Second look

/// Debounces the live glare check: the page counts as glary once `required` of the last `window`
/// analysed frames show glare, so one bright frame (a reflection passing over, exposure settling)
/// does not start a second look.
struct GlareDebouncer {
	var window = 5
	var required = 3
	private var recent: [Bool] = []

	/// True when enough recent frames showed glare.
	var isGlary: Bool {
		recent.filter { $0 }.count >= required
	}

	/// Feeds one analysed frame's map and returns `isGlary`.
	mutating func update(_ map: GlareMap) -> Bool {
		recent.append(!map.isClear)
		let limit = max(1, window)
		if recent.count > limit {
			recent.removeFirst(recent.count - limit)
		}
		return isGlary
	}

	/// Forgets the history, as when the page leaves the frame.
	mutating func reset() {
		recent.removeAll(keepingCapacity: true)
	}
}

/// Decides, from the live frames of a second look, when to take the next still of the page.
///
/// - Ready, once the page has been held within `steadyTolerance` for long enough after moving
///   off the spot of the last still (normalized corner distance, in the upright preview frame):
///   - at least `minimumMove`, with every pending cell clean in the live map: `steadyDuration`;
///   - at least `minimumMove`, with some of them clean: `partialSettleDuration`;
///   - at least `sufficientMove`, whatever the live map shows: `sufficientSettleDuration`. A slide
///     that far carries the reflection off most hotspots, and the preview's highlight blooms wider
///     than the still's, so waiting for the map alone can wait forever.
/// - `phase` says what the user should do: keep moving, or hold where they are.
/// - It fires at most once; `restart` arms it for the next still.
/// - Page lost: no page for `lostDuration`; reported on every frame until the page returns.
///
/// Times are seconds on any monotonic clock.
struct SecondLookTrigger {

	struct Configuration {
		var steadyDuration: TimeInterval = 0.25
		var steadyTolerance: CGFloat = 0.02
		var partialSettleDuration: TimeInterval = 0.6
		var minimumMove: CGFloat = 0.04
		var sufficientMove: CGFloat = 0.10
		var sufficientSettleDuration: TimeInterval = 0.4
		var lostDuration: TimeInterval = 1
		/// Hard cap on remembered samples.
		var maxSamples = 32
	}

	enum Signal: Equatable {
		case waiting
		case ready
		case pageLost
	}

	/// What the user should do now.
	enum Phase: Equatable {
		/// Keep sliding the phone.
		case move
		/// Far enough: hold still for the photo.
		case hold
	}

	private struct Sample {
		var time: TimeInterval
		var quad: PageQuad
	}

	let configuration: Configuration
	private(set) var coverage: GlareCoverage
	private(set) var phase: Phase = .move
	private var lastStillQuad: PageQuad?
	private var samples: [Sample] = []
	private var missingSince: TimeInterval?
	private var hasFired = false

	/// `lastStillQuad` is the live page outline when the last still was taken (nil: no move needed).
	init(coverage: GlareCoverage, lastStillQuad: PageQuad?, configuration: Configuration = Configuration()) {
		self.configuration = configuration
		self.coverage = coverage
		self.lastStillQuad = lastStillQuad
	}

	/// Arms the trigger again after a still, with what is pending now.
	mutating func restart(coverage: GlareCoverage, lastStillQuad: PageQuad?) {
		self.coverage = coverage
		self.lastStillQuad = lastStillQuad
		samples.removeAll(keepingCapacity: true)
		missingSince = nil
		hasFired = false
		phase = .move
	}

	/// Feeds one analysed frame: the live page outline (nil when none) and its glare map (nil
	/// when it could not be measured).
	mutating func update(quad: PageQuad?, glare: GlareMap?, at time: TimeInterval) -> Signal {
		if let last = samples.last, time < last.time {
			samples.removeAll(keepingCapacity: true)
		}
		guard let quad else {
			samples.removeAll(keepingCapacity: true)
			phase = .move
			let since = missingSince ?? time
			missingSince = since
			return time - since >= configuration.lostDuration ? .pageLost : .waiting
		}
		missingSince = nil
		samples.append(Sample(time: time, quad: quad))
		trimSamples()
		guard !hasFired else { return .waiting }
		guard let needed = holdNeeded(quad: quad, glare: glare) else {
			phase = .move
			return .waiting
		}
		phase = .hold
		// A little slack so frame-timing jitter at ~10 fps doesn't add a whole extra frame.
		let slack = min(0.02, needed * 0.1)
		guard heldDuration(latest: quad, now: time) >= needed - slack else { return .waiting }
		hasFired = true
		return .ready
	}

	/// How long the page must be held where it is now, or nil when the phone hasn't moved far enough.
	private func holdNeeded(quad: PageQuad, glare: GlareMap?) -> TimeInterval? {
		let moved = lastStillQuad.map { quad.maxCornerDistance(to: $0) } ?? .greatestFiniteMagnitude
		var needed: TimeInterval?
		if moved >= configuration.minimumMove, let glare {
			let cleared = coverage.clearedCount(in: glare)
			if cleared > 0 {
				needed = cleared >= coverage.pendingCount ? configuration.steadyDuration : configuration.partialSettleDuration
			}
		}
		if moved >= configuration.sufficientMove {
			needed = min(needed ?? .greatestFiniteMagnitude, configuration.sufficientSettleDuration)
		}
		return needed
	}

	/// How long the page has stayed within `steadyTolerance` of where it is now.
	private func heldDuration(latest: PageQuad, now: TimeInterval) -> TimeInterval {
		var start = now
		for sample in samples.reversed() {
			guard sample.quad.maxCornerDistance(to: latest) < configuration.steadyTolerance else { break }
			start = sample.time
		}
		return now - start
	}

	/// Keeps enough history to prove the longest hold, capped at `maxSamples`.
	private mutating func trimSamples() {
		guard let now = samples.last?.time else { return }
		let longest = max(configuration.steadyDuration, configuration.partialSettleDuration, configuration.sufficientSettleDuration)
		let windowStart = now - longest - 0.2
		var dropCount = 0
		while dropCount + 1 < samples.count, samples[dropCount + 1].time <= windowStart {
			dropCount += 1
		}
		dropCount += max(0, samples.count - dropCount - max(1, configuration.maxSamples))
		if dropCount > 0 {
			samples.removeFirst(dropCount)
		}
	}
}

// MARK: - Homography

/// A planar projective transform between two pixel spaces with Core Image's bottom-left origin,
/// acting on column vectors: `p′ ~ matrix · (x, y, 1)`.
struct Homography: Equatable {
	var matrix: simd_double3x3

	static let identity = Homography(matrix: matrix_identity_double3x3)

	init(matrix: simd_double3x3) {
		self.matrix = matrix
	}

	/// Vision's single-precision matrix (`VNImageHomographicAlignmentObservation.warpTransform`).
	init(_ matrix: simd_float3x3) {
		self.matrix = simd_double3x3(columns: (
			SIMD3<Double>(matrix.columns.0),
			SIMD3<Double>(matrix.columns.1),
			SIMD3<Double>(matrix.columns.2)
		))
	}

	/// The transform taking `source[i]` to `destination[i]` for exactly four point pairs; nil when
	/// three points are collinear. Coordinates are normalized before solving for conditioning.
	init?(from source: [CGPoint], to destination: [CGPoint]) {
		guard source.count == 4, destination.count == 4 else { return nil }
		let sourceScale = max(1, source.reduce(0) { max($0, abs(Double($1.x)), abs(Double($1.y))) })
		let destinationScale = max(1, destination.reduce(0) { max($0, abs(Double($1.x)), abs(Double($1.y))) })
		var rows: [[Double]] = []
		var values: [Double] = []
		for (from, to) in zip(source, destination) {
			let x = Double(from.x) / sourceScale
			let y = Double(from.y) / sourceScale
			let u = Double(to.x) / destinationScale
			let v = Double(to.y) / destinationScale
			rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
			values.append(u)
			rows.append([0, 0, 0, x, y, 1, -v * x, -v * y])
			values.append(v)
		}
		guard let h = Self.solve(rows, values) else { return nil }
		let normalized = simd_double3x3(rows: [
			SIMD3(h[0], h[1], h[2]),
			SIMD3(h[3], h[4], h[5]),
			SIMD3(h[6], h[7], 1),
		])
		let denormalize = simd_double3x3(diagonal: SIMD3(destinationScale, destinationScale, 1))
		let normalize = simd_double3x3(diagonal: SIMD3(1 / sourceScale, 1 / sourceScale, 1))
		self.init(matrix: denormalize * normalized * normalize)
	}

	/// Independent scaling of x and y about the origin.
	static func scaling(x: CGFloat, y: CGFloat) -> Homography {
		Homography(matrix: simd_double3x3(diagonal: SIMD3(Double(x), Double(y), 1)))
	}

	/// `self`, then `next`.
	func followed(by next: Homography) -> Homography {
		Homography(matrix: next.matrix * matrix)
	}

	/// The inverse transform, or nil when singular.
	var inverse: Homography? {
		let determinant = matrix.determinant
		guard determinant.isFinite, abs(determinant) > 1e-15 else { return nil }
		return Homography(matrix: matrix.inverse)
	}

	/// The image of `point`, or nil when it maps to (or past) infinity.
	func apply(_ point: CGPoint) -> CGPoint? {
		let mapped = matrix * SIMD3(Double(point.x), Double(point.y), 1)
		guard mapped.z > 1e-12, mapped.x.isFinite, mapped.y.isFinite else { return nil }
		return CGPoint(x: mapped.x / mapped.z, y: mapped.y / mapped.z)
	}

	/// Output pixels per input pixel near the input point that lands on `outputPoint` (the
	/// geometric mean of the two axes), or nil when undefined there.
	func localScale(at outputPoint: CGPoint) -> CGFloat? {
		guard let source = inverse?.apply(outputPoint),
			  let alongX = apply(CGPoint(x: source.x + 1, y: source.y)),
			  let alongY = apply(CGPoint(x: source.x, y: source.y + 1)) else { return nil }
		let scaleX = hypot(alongX.x - outputPoint.x, alongX.y - outputPoint.y)
		let scaleY = hypot(alongY.x - outputPoint.x, alongY.y - outputPoint.y)
		return (scaleX * scaleY).squareRoot()
	}

	/// Solves the square system `a · x = b` by Gaussian elimination with partial pivoting; nil when
	/// singular.
	private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
		let n = b.count
		guard n > 0, a.count == n, a.allSatisfy({ $0.count == n }) else { return nil }
		var m = a
		var v = b
		for column in 0..<n {
			var pivot = column
			for row in column..<n where abs(m[row][column]) > abs(m[pivot][column]) {
				pivot = row
			}
			guard abs(m[pivot][column]) > 1e-12 else { return nil }
			m.swapAt(column, pivot)
			v.swapAt(column, pivot)
			for row in (column + 1)..<n {
				let factor = m[row][column] / m[column][column]
				for k in column..<n {
					m[row][k] -= factor * m[column][k]
				}
				v[row] -= factor * v[column]
			}
		}
		var x = [Double](repeating: 0, count: n)
		for row in stride(from: n - 1, through: 0, by: -1) {
			var sum = v[row]
			for k in (row + 1)..<n {
				sum -= m[row][k] * x[k]
			}
			x[row] = sum / m[row][row]
		}
		return x
	}
}

// MARK: - Plane

/// A single-channel float image on the CPU for the small analysis passes. The arithmetic runs on
/// Accelerate (vDSP and vForce), so it stays fast in unoptimized builds too.
///
/// Rows run top to bottom (row 0 is the top of the image, as rendered `CGImage`s store them).
/// Pixel `(column, row)` has its centre at Core Image point `(column + 0.5, height − row − 0.5)`.
/// Binary operations need planes of the same size; given another size they return `self`.
struct Plane: Equatable {
	let width: Int
	let height: Int
	var values: [Float]

	init(width: Int, height: Int, repeating value: Float = 0) {
		self.width = max(0, width)
		self.height = max(0, height)
		values = [Float](repeating: value, count: self.width * self.height)
	}

	/// Decodes 8-bit gamma-2.2 grey levels, rows `rowBytes` apart, to linear values; nil when the
	/// buffer is too short.
	init?(grayBytes bytes: [UInt8], width: Int, height: Int, rowBytes: Int) {
		guard width > 0, height > 0, rowBytes >= width, bytes.count >= rowBytes * (height - 1) + width else { return nil }
		var levels: [Float] = []
		levels.reserveCapacity(width * height)
		var row = [Float](repeating: 0, count: width)
		for index in 0..<height {
			let start = index * rowBytes
			vDSP.convertElements(of: bytes[start..<(start + width)], to: &row)
			levels.append(contentsOf: row)
		}
		let normalized = vDSP.multiply(1 / 255, levels)
		self.width = width
		self.height = height
		values = vForce.pow(bases: normalized, exponents: [Float](repeating: 2.2, count: normalized.count))
	}

	private func with(_ newValues: [Float]) -> Plane {
		var copy = self
		copy.values = newValues
		return copy
	}

	private func combined(with other: Plane, _ operation: ([Float], [Float]) -> [Float]) -> Plane {
		guard other.width == width, other.height == height, other.values.count == values.count else { return self }
		return with(operation(values, other.values))
	}

	func adding(_ other: Plane) -> Plane { combined(with: other) { vDSP.add($0, $1) } }
	func subtracting(_ other: Plane) -> Plane { combined(with: other) { vDSP.subtract($0, $1) } }
	func multiplied(by other: Plane) -> Plane { combined(with: other) { vDSP.multiply($0, $1) } }
	func divided(by other: Plane) -> Plane { combined(with: other) { vDSP.divide($0, $1) } }
	func minimum(_ other: Plane) -> Plane { combined(with: other) { vDSP.minimum($0, $1) } }
	func maximum(_ other: Plane) -> Plane { combined(with: other) { vDSP.maximum($0, $1) } }

	func adding(_ scalar: Float) -> Plane { with(vDSP.add(scalar, values)) }
	/// `value · factor + offset` for every pixel.
	func scaled(by factor: Float, plus offset: Float = 0) -> Plane { with(vDSP.add(offset, vDSP.multiply(factor, values))) }
	func clipped(to range: ClosedRange<Float>) -> Plane { with(vDSP.clip(values, to: range)) }
	/// `1 − value` for every pixel.
	func complement() -> Plane { scaled(by: -1, plus: 1) }
	func exponential() -> Plane { with(vForce.exp(values)) }
	/// 1 where the value is at least `threshold`, else 0.
	func indicator(atLeast threshold: Float) -> Plane {
		with(vDSP.add(0.5, vDSP.threshold(values, to: threshold, with: .signedConstant(0.5))))
	}

	var sum: Float { vDSP.sum(values) }
	var mean: Float { values.isEmpty ? 0 : sum / Float(values.count) }

	/// Rec. 709 luminance of red, green and blue planes after per-channel `gain`.
	static func luminance(_ channels: [Plane], gain: SIMD3<Float>) -> Plane {
		guard channels.count >= 3 else { return channels.first ?? Plane(width: 0, height: 0) }
		let weights = SIMD3<Float>(0.2126, 0.7152, 0.0722) * gain
		return channels[0].scaled(by: weights.x).adding(channels[1].scaled(by: weights.y)).adding(channels[2].scaled(by: weights.z))
	}

	/// 1 where any of the first three planes is at or above `level`, else 0.
	static func clippedIndicator(_ channels: [Plane], level: Float) -> Plane {
		guard let first = channels.first else { return Plane(width: 0, height: 0) }
		return channels.prefix(3).dropFirst().reduce(first) { $0.maximum($1) }.indicator(atLeast: level)
	}

	/// A box blur of the given radius applied `passes` times (two passes approximate a Gaussian);
	/// the window shrinks at the edges, so borders keep their level.
	func boxBlurred(radius: Int, passes: Int = 2) -> Plane {
		guard radius > 0, width > 0, height > 0 else { return self }
		var result = self
		for _ in 0..<max(1, min(passes, 4)) {
			result = result.blurredRows(radius: radius).blurredColumns(radius: radius)
		}
		return result
	}

	/// Each row replaced by its means over `[x − radius, x + radius]`, clamped to the row.
	private func blurredRows(radius: Int) -> Plane {
		let reach = min(radius, width - 1)
		var output: [Float] = []
		output.reserveCapacity(values.count)
		for row in 0..<height {
			let start = row * width
			// prefix[k] is the sum of the row's first k values.
			let prefix = vDSP.integrate([0] + values[start..<(start + width)], using: .runningSum)
			output.append(contentsOf: Self.windowMeans(prefix, count: width, reach: reach))
		}
		return with(output)
	}

	/// Each column replaced by its means over `[y − radius, y + radius]`, clamped to the column.
	private func blurredColumns(radius: Int) -> Plane {
		let reach = min(radius, height - 1)
		// prefixRows[k] holds the sum of the first k rows.
		var prefixRows: [[Float]] = [[Float](repeating: 0, count: width)]
		prefixRows.reserveCapacity(height + 1)
		var running = prefixRows[0]
		for row in 0..<height {
			running = vDSP.add(running, values[(row * width)..<((row + 1) * width)])
			prefixRows.append(running)
		}
		var output: [Float] = []
		output.reserveCapacity(values.count)
		for row in 0..<height {
			let low = max(0, row - reach)
			let high = min(height - 1, row + reach)
			output.append(contentsOf: vDSP.multiply(1 / Float(high - low + 1), vDSP.subtract(prefixRows[high + 1], prefixRows[low])))
		}
		return with(output)
	}

	/// Means of the windows `[i − reach, i + reach]` (clamped to `0..<count`) from exclusive prefix
	/// sums (`prefix[k]` = sum of the first k values).
	private static func windowMeans(_ prefix: [Float], count: Int, reach: Int) -> [Float] {
		var means = [Float](repeating: 0, count: max(0, count))
		guard count > 0, prefix.count == count + 1 else { return means }
		let span = 2 * reach + 1
		var edges = Array(0..<count)
		if count > 2 * reach {
			let sums = vDSP.subtract(prefix[span...count], prefix[0...(count - span)])
			means.replaceSubrange(reach..<(count - reach), with: vDSP.multiply(1 / Float(span), sums))
			edges = Array(0..<reach) + Array((count - reach)..<count)
		}
		for index in edges {
			let low = max(0, index - reach)
			let high = min(count - 1, index + reach)
			means[index] = (prefix[high + 1] - prefix[low]) / Float(high - low + 1)
		}
		return means
	}

	/// The `fraction` quantile of the plane, or nil when empty.
	func percentile(_ fraction: Double) -> Float? {
		var sorted = values
		return Self.percentile(of: &sorted, fraction)
	}

	/// The `fraction` quantile of the `count` smallest of `values` (all of them when `count` is
	/// nil), sorting `values` in place; nil when there are none.
	static func percentile(of values: inout [Float], count: Int? = nil, _ fraction: Double) -> Float? {
		let used = min(count ?? values.count, values.count)
		guard used > 0 else { return nil }
		vDSP.sort(&values, sortOrder: .ascending)
		let position = Int((Double(used - 1) * min(max(fraction, 0), 1)).rounded())
		return values[position]
	}

	/// How steep the plane's edges are: Σ|∇|² ÷ Σ|∇| over pixels whose gradient (central
	/// differences) is at least `threshold`. Blurring an edge keeps Σ|∇| (its contrast) and lowers
	/// Σ|∇|², so the ratio falls with blur whatever the amount of ink. Nil without edges.
	func edgeSteepness(threshold: Float = 0.05) -> Float? {
		let count = values.count
		guard width >= 3, height >= 3 else { return nil }
		// Pixels w ..< count − w; the few that wrap across row ends do not matter at this scale.
		let dx = vDSP.multiply(0.5, vDSP.subtract(values[(width + 1)..<(count - width + 1)], values[(width - 1)..<(count - width - 1)]))
		let dy = vDSP.multiply(0.5, vDSP.subtract(values[(2 * width)..<count], values[0..<(count - 2 * width)]))
		let magnitude = vForce.sqrt(vDSP.add(vDSP.multiply(dx, dx), vDSP.multiply(dy, dy)))
		let edges = vDSP.threshold(magnitude, to: threshold, with: .zeroFill)
		let total = vDSP.sum(edges)
		return total > 0 ? vDSP.sumOfSquares(edges) / total : nil
	}

	/// Mean of `|a − b|` weighted by `mask`, or nil when the sizes differ or the mask is empty.
	static func meanAbsoluteDifference(_ a: Plane, _ b: Plane, mask: Plane) -> Float? {
		guard a.values.count == b.values.count, a.values.count == mask.values.count else { return nil }
		let weight = mask.sum
		guard weight > 0 else { return nil }
		return vDSP.sum(vDSP.multiply(vDSP.absolute(vDSP.subtract(a.values, b.values)), mask.values)) / weight
	}

	/// The plane (clamped to 0–1) as an opaque grey Core Image image: 16-bit levels, no colour
	/// management, so the values reach the working space unchanged.
	func ciImage() -> CIImage {
		var levels = [UInt16](repeating: 0, count: values.count)
		vDSP.convertElements(of: vDSP.multiply(65535, clipped(to: 0...1).values), to: &levels, rounding: .towardNearestInteger)
		var bytes = [UInt8](repeating: 0, count: values.count * 2)
		for index in levels.indices {
			bytes[index * 2] = UInt8(levels[index] & 0xFF)
			bytes[index * 2 + 1] = UInt8(levels[index] >> 8)
		}
		return CIImage(bitmapData: Data(bytes), bytesPerRow: width * 2, size: CGSize(width: width, height: height), format: .L16, colorSpace: nil)
	}

	/// The plane (0–1) as an 8-bit grey `CGImage` with a 2.2 gamma, for Vision.
	func grayImage() -> CGImage? {
		guard width > 0, height > 0 else { return nil }
		let encoded = vForce.pow(bases: clipped(to: 0...1).values, exponents: [Float](repeating: 1 / 2.2, count: values.count))
		var bytes = [UInt8](repeating: 0, count: values.count)
		vDSP.convertElements(of: vDSP.multiply(255, encoded), to: &bytes, rounding: .towardNearestInteger)
		guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
		return CGImage(
			width: width,
			height: height,
			bitsPerComponent: 8,
			bitsPerPixel: 8,
			bytesPerRow: width,
			space: CGColorSpaceCreateDeviceGray(),
			bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
			provider: provider,
			decode: nil,
			shouldInterpolate: false,
			intent: .defaultIntent
		)
	}
}
