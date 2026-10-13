//
//  Scenarios.swift
//  GlareFusion harness (macOS only)
//
//  The pipelines under comparison and the scenarios that exercise them.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import QuartzCore

// MARK: - Pipelines

extension Harness {

	/// The quad the app would use for a shot: Vision's detection on a 1024 px copy (as
	/// `CapturePipeline.detectPage`), else the true outline; inset 1% as `processStill` does.
	func frame(for shot: Shot, detect: Bool = true) throws -> (frame: GlareFrame, detected: Bool) {
		var quad = shot.quad
		var detected = false
		if detect {
			let small = PageCleanup.limitLongSide(shot.image, to: 1024)
			if let found = PageDetector().detect(cgImage: try lab.cgImage(small)) {
				quad = found
				detected = true
			}
		}
		return (GlareFrame(image: shot.image, quad: quad.inset(by: 0.01)), detected)
	}

	/// Today's single-photo path (`CapturePipeline.processStill` after detection).
	func singlePhoto(_ frame: GlareFrame, mode: CaptureMode) -> CIImage {
		var page = PageCleanup.correctPerspective(frame.image, quad: frame.quad)
		page = PageCleanup.limitWidth(page, to: 2400)
		return PageCleanup.clean(page, mode: mode, removeShadows: true, keepMarkerColors: true)
	}

	/// The single-photo page before cleanup (for glare-zone masks).
	func singlePhotoUncleaned(_ frame: GlareFrame) -> CIImage {
		PageCleanup.limitWidth(PageCleanup.correctPerspective(frame.image, quad: frame.quad), to: 2400)
	}

	/// GlareFusion, rendered once, then document cleanup; with the time each step took.
	func fused(_ frames: [GlareFrame], options: GlareFusion.Options = GlareFusion.Options())
		throws -> (cleaned: CIImage, result: GlareFusion.Result, seconds: (fuse: Double, render: Double, clean: Double)) {
		let start = CACurrentMediaTime()
		let result = try GlareFusion.fuse(frames, context: context, options: options)
		let fusedAt = CACurrentMediaTime()
		let page = try lab.materialized(result.page)
		let renderedAt = CACurrentMediaTime()
		let cleaned = try lab.materialized(PageCleanup.clean(page, mode: .document, removeShadows: true, keepMarkerColors: true))
		let cleanedAt = CACurrentMediaTime()
		return (cleaned, result, (fusedAt - start, renderedAt - fusedAt, cleanedAt - renderedAt))
	}

	/// The plain per-pixel stack blends the design note compares against, on the same aligned,
	/// exposure-matched frames as GlareFusion, then document cleanup.
	func stackBlend(_ frames: [GlareFrame], gains: [SIMD3<Float>], kind: String) throws -> CIImage {
		let stack = try GlareFusion.align(frames, context: context, options: GlareFusion.Options())
		let rect = CGRect(origin: .zero, size: stack.pageSize)
		guard let referencePage = stack.layers.first?.page(pageSize: stack.pageSize, targetSize: stack.pageSize) else {
			throw HarnessError("No reference page.")
		}
		let pages = try zip(stack.layers, gains).map { layer, gain -> CIImage in
			guard let page = layer.page(pageSize: stack.pageSize, targetSize: stack.pageSize) else { throw HarnessError("Warp failed.") }
			let matched = channelGains(page, SIMD3(Double(gain.x), Double(gain.y), Double(gain.z)))
			return matched.composited(over: referencePage).cropped(to: rect)
		}
		let blended: CIImage
		switch kind {
		case "mean":
			blended = pages.dropFirst().reduce(scaled(pages[0], by: 1 / Double(pages.count))) { add($0, scaled($1, by: 1 / Double(pages.count))) }
		case "median" where pages.count == 3:
			blended = maximum(minimum(pages[0], pages[1]), minimum(maximum(pages[0], pages[1]), pages[2]))
		default:
			blended = pages.dropFirst().reduce(pages[0]) { minimum($0, $1) }
		}
		let page = try lab.materialized(blended.cropped(to: rect))
		return try lab.materialized(PageCleanup.clean(page, mode: .document, removeShadows: true, keepMarkerColors: true))
	}

	private func minimum(_ a: CIImage, _ b: CIImage) -> CIImage {
		let filter = CIFilter.minimumCompositing()
		filter.inputImage = a
		filter.backgroundImage = b
		return filter.outputImage?.cropped(to: a.extent) ?? a
	}

	private func maximum(_ a: CIImage, _ b: CIImage) -> CIImage {
		let filter = CIFilter.maximumCompositing()
		filter.inputImage = a
		filter.backgroundImage = b
		return filter.outputImage?.cropped(to: a.extent) ?? a
	}

	/// OCR score of a cleaned page; "glare lines" are the printed lines within 1.2 core radii of
	/// the reference's glare centre.
	func ocr(_ cleaned: CIImage, glareCenter: CGPoint) throws -> OCRScore {
		let recognized = try OCR.recognize(try lab.cgImage(cleaned))
		let radius = CGFloat(studio.glareRadius / Double(page.metres.width)) * page.size.width * 1.2
		let scores = page.lines.map { line -> (Double, Bool) in
			let nearestX = min(max(glareCenter.x, line.rect.minX), line.rect.maxX)
			let nearestY = min(max(glareCenter.y, line.rect.minY), line.rect.maxY)
			let underGlare = hypot(nearestX - glareCenter.x, nearestY - glareCenter.y) <= radius
			return (OCR.accuracy(of: line.text, among: recognized), underGlare)
		}
		let all = scores.map(\.0).reduce(0, +) / Double(max(1, scores.count))
		let glare = scores.filter(\.1).map(\.0)
		return OCRScore(all: all, glareLines: glare.reduce(0, +) / Double(max(1, glare.count)),
						glareLinesRead: glare.filter { $0 >= 0.98 }.count, glareLineCount: glare.count)
	}
}

// MARK: - Scenarios

extension Harness {

	/// Homography and plane round trips (coordinate conventions the fusion relies on).
	func runSelfChecks() throws {
		log("== self-checks")
		let from = [CGPoint(x: 10, y: 20), CGPoint(x: 3000, y: 80), CGPoint(x: 2900, y: 3900), CGPoint(x: 40, y: 4000)]
		let to = [CGPoint(x: 0, y: 0), CGPoint(x: 2400, y: 0), CGPoint(x: 2400, y: 3100), CGPoint(x: 0, y: 3100)]
		let map = Homography(from: from, to: to)
		let worst = zip(from, to).reduce(0.0) { result, pair in
			guard let mapped = map?.apply(pair.0) else { return .infinity }
			return max(result, Double(hypot(mapped.x - pair.1.x, mapped.y - pair.1.y)))
		}
		check(worst < 1e-6, String(format: "four-point homography reproduces its corners (worst %.2e px)", worst))
		var plane = Plane(width: 40, height: 30)
		for row in 0..<30 { for column in 0..<40 { plane.values[row * 40 + column] = Float(row) / 29 * 0.8 + 0.1 } }
		guard let back = GlareFusion.renderPlanes(plane.ciImage(), bounds: CGRect(x: 0, y: 0, width: 40, height: 30), context: context) else {
			throw HarnessError("Plane round trip failed.")
		}
		let top = back[1].values[0]
		let bottom = back[1].values[29 * 40]
		check(abs(top - 0.1) < 0.01 && abs(bottom - 0.9) < 0.02,
			  String(format: "plane → CIImage → plane keeps row 0 on top (top %.3f, bottom %.3f)", top, bottom))
		try checkPlaneArithmetic()
		try checkUnpremultiplied()
	}

	/// The vDSP-backed plane operations against plain loops.
	private func checkPlaneArithmetic() throws {
		var plane = Plane(width: 37, height: 23)
		for index in plane.values.indices { plane.values[index] = Float((index * 7919) % 101) / 100 }
		let other = plane.scaled(by: 0.5, plus: 0.2)
		let difference = plane.subtracting(other)
		check(abs(difference.values[5] - (plane.values[5] - other.values[5])) < 1e-6, "subtracting is self − other")
		let ones = plane.indicator(atLeast: 0.5)
		let expected = plane.values.map { $0 >= 0.5 ? Float(1) : 0 }
		check(ones.values == expected, "indicator(atLeast:) is 1 at or above the threshold, else 0")
		let blurred = plane.boxBlurred(radius: 3, passes: 1)
		var worst: Float = 0
		for row in 0..<23 {
			for column in 0..<37 {
				var sum: Float = 0
				var count: Float = 0
				for y in max(0, row - 3)...min(22, row + 3) {
					for x in max(0, column - 3)...min(36, column + 3) {
						sum += plane.values[y * 37 + x]
						count += 1
					}
				}
				worst = max(worst, abs(blurred.values[row * 37 + column] - sum / count))
			}
		}
		check(worst < 1e-4, String(format: "box blur matches a direct window mean (worst %.2e)", worst))
	}

	/// Planes read colour un-premultiplied: a half-transparent 0.6 grey reads 0.6, alpha 0.5.
	private func checkUnpremultiplied() throws {
		let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
		let grey = CIImage(color: linearColor(0.6, 0.6, 0.6)).cropped(to: rect)
		let half = levels(grey, gain: 1, bias: 0)
		let faded = CIFilter.colorMatrix()
		faded.inputImage = half
		faded.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.5)
		guard let image = faded.outputImage, let planes = GlareFusion.renderPlanes(image, bounds: rect, context: context) else {
			throw HarnessError("Premultiplied check failed to render.")
		}
		check(abs(planes[0].values[0] - 0.6) < 0.02 && abs(planes[3].values[0] - 0.5) < 0.02,
			  String(format: "renderPlanes un-premultiplies (colour %.3f, alpha %.3f)", planes[0].values[0], planes[3].values[0]))
	}

	/// Shoots `shots`, runs every pipeline and checks the glare claims.
	func runGlossy(name: String, shots settings: [ShotSettings], compareStacks: Bool) throws {
		log("\n== \(name): \(settings.count) shots")
		let folder = try self.folder(name)
		let shots = try settings.map { try studio.shoot($0) }
		var idealSettings = settings[0]
		idealSettings.glareStrength = 0
		let ideal = try studio.shoot(idealSettings)
		let framed = try shots.map { try frame(for: $0) }
		let frames = framed.map(\.frame)
		let idealFrame = GlareFrame(image: ideal.image, quad: frames[0].quad)
		for (index, shot) in shots.enumerated() {
			log(String(format: "  shot %d: tilt %.1f°, glare centre (%.0f, %.0f) px, quad %@", index, settings[index].pose.tiltDegrees,
					   shot.glareCenter.x, shot.glareCenter.y, framed[index].detected ? "detected" : "TRUE (detection failed)"))
			try lab.write(shot.image, to: folder.appendingPathComponent("shot-\(index).png"), maxSide: 1344)
		}
		try checkLiveCoverage(frames, shots: shots)
		let fusion = try fused(frames, options: Self.cameraOptions)
		logFusion(fusion.result, seconds: fusion.seconds)
		check(fusion.result.frames.count == frames.count,
			  "with the camera's options every shot registers and is kept (\(fusion.result.unrefinedFrames.count) dropped)")
		let stack = try GlareFusion.align(frames, context: context, options: GlareFusion.Options())
		for error in RegistrationError.measure(stack, shots: shots) {
			log(String(format: "  shot %d registration error: mean %.2f px, max %.2f px", error.index, error.mean, error.max))
			check(error.mean < 1.5, "shot \(error.index) lands within 1.5 px on average")
		}
		try scoreGlossy(name: name, folder: folder, frames: frames, idealFrame: idealFrame, fusion: fusion,
						glareCenter: shots[0].glareCenter, compareStacks: compareStacks)
	}

	private func logFusion(_ result: GlareFusion.Result, seconds: (fuse: Double, render: Double, clean: Double)) {
		for report in result.frames {
			let before = report.differenceBefore.map { String(format: "%.4f", $0) } ?? "–"
			let after = report.differenceAfter.map { String(format: "%.4f", $0) } ?? "–"
			let sharpness = report.sharpness.map { String(format: "%.2f", $0) } ?? "–"
			log(String(format: "  frame %d: %@, diff %@ → %@, sharpness %@, gain (%.3f %.3f %.3f), coverage %.2f, glare %.3f", report.index,
					   String(describing: report.alignment), before, after, sharpness, report.gain.x, report.gain.y, report.gain.z,
					   report.coverage, report.glareFraction))
		}
		log(String(format: "  residual glare %.4f of the page; fuse %.2f s, render %.2f s, cleanup %.2f s (this Mac, -O)",
				   result.residualGlareFraction, seconds.fuse, seconds.render, seconds.clean))
		check(result.residualGlareFraction < 0.01, "fusion leaves under 1% of the page with glare")
	}

	/// The live check: the reference shows glare, and the later shots cover it.
	private func checkLiveCoverage(_ frames: [GlareFrame], shots: [Shot]) throws {
		let maps = frames.map { GlareMap.estimate($0, context: context) }
		guard let first = maps.first ?? nil else { throw HarnessError("No glare map for the reference.") }
		check(!first.isClear, String(format: "live estimate finds the reference's glare (%.0f%% of cells)", first.glaryShare * 100))
		var coverage = GlareCoverage(first: first)
		log("  suggested move after the reference: \(coverage.suggestedMove.map { "\($0)" } ?? "none") (page space)")
		for map in maps.dropFirst() {
			if let map { coverage.add(map) }
		}
		check(coverage.isComplete, "the later shots see every glary cell clean (\(coverage.pendingCount) left)")
	}

	private func scoreGlossy(name: String, folder: URL, frames: [GlareFrame], idealFrame: GlareFrame,
							 fusion: (cleaned: CIImage, result: GlareFusion.Result, seconds: (fuse: Double, render: Double, clean: Double)),
							 glareCenter: CGPoint, compareStacks: Bool) throws {
		let singleZone = try lab.glareZone(glary: singlePhotoUncleaned(frames[0]), clean: singlePhotoUncleaned(idealFrame))
		let singleIdeal = try lab.materialized(singlePhoto(idealFrame, mode: .document))
		let fusedIdeal = try fused([idealFrame])
		let fusedZone = try lab.glareZone(glary: try lab.materialized(fusion.result.reference), clean: try lab.materialized(fusedIdeal.result.page))
		var rows: [(String, CIImage, CIImage, Plane)] = [
			("single photo, document", try lab.materialized(singlePhoto(frames[0], mode: .document)), singleIdeal, singleZone),
			("single photo, whiteboard glare cleanup", try lab.materialized(singlePhoto(frames[0], mode: .whiteboard)),
			 try lab.materialized(singlePhoto(idealFrame, mode: .whiteboard)), singleZone),
		]
		if compareStacks {
			let gains = fusion.result.frames.map(\.gain)
			for kind in ["mean", "median", "minimum"] {
				rows.append(("stack \(kind)", try stackBlend(frames, gains: gains, kind: kind), fusedIdeal.cleaned, fusedZone))
			}
			var unrefined = GlareFusion.Options()
			unrefined.refinesAlignment = false
			rows.append(("GlareFusion, quads only", try fused(frames, options: unrefined).cleaned, fusedIdeal.cleaned, fusedZone))
		}
		rows.append(("GlareFusion", fusion.cleaned, fusedIdeal.cleaned, fusedZone))
		rows.append(("glare-free photo (ideal)", fusedIdeal.cleaned, fusedIdeal.cleaned, fusedZone))
		var scores: [String: (rmse: (page: Double, zone: Double), ocr: OCRScore)] = [:]
		for (label, image, reference, zone) in rows {
			let error = try lab.rmse(image, reference, zone: zone)
			let reading = try ocr(image, glareCenter: glareCenter)
			scores[label] = (error, reading)
			log(String(format: "  %-40@ RMSE page %5.2f, glare zone %6.2f | OCR all %.3f, glare lines %.3f (%d/%d read)",
					   label as NSString, error.page, error.zone, reading.all, reading.glareLines, reading.glareLinesRead, reading.glareLineCount))
			try lab.write(image, to: folder.appendingPathComponent(fileName(label) + ".png"), maxSide: 1600)
		}
		try writeCrops(folder: folder, rows: rows, fusion: fusion.result, glareCenter: glareCenter)
		checkGlossyClaims(scores)
	}

	private func checkGlossyClaims(_ scores: [String: (rmse: (page: Double, zone: Double), ocr: OCRScore)]) {
		guard let single = scores["single photo, document"], let heuristic = scores["single photo, whiteboard glare cleanup"],
			  let fused = scores["GlareFusion"] else { return }
		check(fused.rmse.zone < 0.5 * single.rmse.zone, "fusion at least halves the error under the glare")
		check(fused.rmse.page <= single.rmse.page, "fusion is no worse than one photo over the whole page")
		check(fused.ocr.glareLines >= max(single.ocr.glareLines, heuristic.ocr.glareLines) - 0.005,
			  "fusion reads the glare lines at least as well as either single-photo cleanup")
		check(fused.ocr.glareLines >= 0.95, "fusion reads the glare lines with ≥ 95% character accuracy")
	}

	private func writeCrops(folder: URL, rows: [(String, CIImage, CIImage, Plane)], fusion: GlareFusion.Result, glareCenter: CGPoint) throws {
		let wanted = ["single photo, document", "single photo, whiteboard glare cleanup", "stack median", "stack minimum", "GlareFusion", "glare-free photo (ideal)"]
		let panels = wanted.compactMap { label in rows.first { $0.0 == label }.map { (label: shortLabel(label), image: $0.1) } }
		guard !panels.isEmpty else { return }
		let center = CGPoint(x: glareCenter.x / page.size.width, y: glareCenter.y / page.size.height)
		let crop = CGRect(x: max(0, center.x - 0.21), y: max(0, center.y - 0.115), width: 0.42, height: 0.23)
		try lab.writePNG(try lab.strip(panels, crop: crop, pageAspect: page.size.height / page.size.width, panelWidth: 520), to: folder.appendingPathComponent("crops.png"))
		for (index, weight) in fusion.weights.enumerated() {
			try lab.write(weight, to: folder.appendingPathComponent("weight-\(index).png"), maxSide: 400)
		}
	}

	/// GlareFusion as `CaptureCamera` runs it: up to three stills, and a follow-up that registration
	/// cannot match is dropped rather than placed by its quad alone.
	static var cameraOptions: GlareFusion.Options {
		var options = GlareFusion.Options()
		options.maxFrames = 3
		options.keepsUnrefinedFrames = false
		return options
	}

	/// A follow-up that is not the same page (here the second shot mirrored, as if the user had
	/// turned to another page during the second look) is dropped, so the page is the reference's.
	func runOtherPage() throws {
		log("\n== other page in the second look")
		let shots = try [Poses.reference, Poses.left].map { try studio.shoot($0) }
		let frames = try shots.map { try frame(for: $0).frame }
		let mirrored = frames[1].image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
		guard let quad = PageQuad(unordered: frames[1].quad.corners.map { CGPoint(x: 1 - $0.x, y: $0.y) }) else {
			throw HarnessError("The mirrored quad is degenerate.")
		}
		let other = GlareFrame(image: GlareFusion.atOrigin(mirrored), quad: quad)
		let result = try GlareFusion.fuse([frames[0], other], context: context, options: Self.cameraOptions)
		for report in result.unrefinedFrames {
			log("  dropped frame \(report.index): \(report.alignment)")
		}
		check(result.frames.count == 1 && result.droppedFrames == [1], "a mirrored follow-up is dropped instead of ghosting the page")
	}

	/// A matte page: no glare is found, so the app keeps the one-photo path; fusing anyway changes little.
	func runMatte() throws {
		log("\n== matte page")
		let shots = try [Poses.reference, Poses.left, Poses.upRight].map { try studio.shoot(Poses.matte($0)) }
		let frames = try shots.map { try frame(for: $0).frame }
		let maps = frames.compactMap { GlareMap.estimate($0, context: context) }
		check(maps.count == 3 && maps.allSatisfy(\.isClear), "live estimate finds no glare on any matte shot")
		let one = try fused([frames[0]])
		let three = try fused(frames)
		let noZone = Plane(width: Int(one.cleaned.extent.width), height: Int(one.cleaned.extent.height))
		let error = try lab.rmse(three.cleaned, one.cleaned, zone: noZone)
		log(String(format: "  three matte shots fused vs the reference alone: RMSE %.2f levels; residual glare %.4f", error.page, three.result.residualGlareFraction))
		check(error.page < 4, "fusing matte shots barely changes the page (mostly denoising)")
		check(three.result.residualGlareFraction < 0.002, "no residual glare reported on a matte page")
	}

	/// Registration accuracy as the second shot moves further from the reference (more tilt).
	func runTiltSweep() throws {
		log("\n== tilt sweep: second shot eased left, re-aimed at the page")
		let reference = try studio.shoot(Poses.reference)
		var worstRefined = 0.0
		for offset in [0.02, 0.04, 0.06, 0.08, 0.10, 0.12] {
			let settings = Poses.sideways(offset)
			let shot = try studio.shoot(settings)
			let shots = [reference, shot]
			var line = String(format: "  offset %2.0f cm, tilt %4.1f°:", offset * 100, settings.pose.tiltDegrees)
			for (label, detect, refine) in [("true quads", false, false), ("detected", true, false), ("detected+refined", true, true)] {
				let frames = try shots.map { try frame(for: $0, detect: detect).frame }
				var options = GlareFusion.Options()
				options.refinesAlignment = refine
				let stack = try GlareFusion.align(frames, context: context, options: options)
				let error = RegistrationError.measure(stack, shots: shots).first
				line += String(format: " %@ %.2f/%.2f px", label, error?.mean ?? .infinity, error?.max ?? .infinity)
				if refine, offset <= 0.10 {
					worstRefined = max(worstRefined, error?.mean ?? .infinity)
				}
			}
			log(line)
		}
		check(worstRefined < 1.5, String(format: "refined registration stays within 1.5 px mean up to ~16° of tilt (worst %.2f px)", worstRefined))
	}

	private func fileName(_ label: String) -> String {
		label.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
	}

	private func shortLabel(_ label: String) -> String {
		switch label {
		case "single photo, document": return "One photo"
		case "single photo, whiteboard glare cleanup": return "One photo + glare heuristic"
		case "stack median": return "Median"
		case "stack minimum": return "Minimum"
		case "glare-free photo (ideal)": return "Glare-free"
		default: return label
		}
	}
}
