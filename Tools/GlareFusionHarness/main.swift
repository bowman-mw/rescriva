//
//  main.swift
//  GlareFusion harness (macOS only)
//
//  Photographs a synthetic glossy page from several positions, runs the single-photo pipeline,
//  plain stack blends (mean, median, minimum) and GlareFusion, and scores them against a
//  glare-free photo with OCR and pixel error. Writes PNGs and summary.txt to the output folder and
//  exits non-zero when a claim in Docs/Glare-MultiFrame-Capture.md no longer holds.
//
//  Usage: Tools/GlareFusionHarness/run.sh [output-dir]
//

import CoreImage
import Foundation
import QuartzCore

// MARK: - Harness

/// Runs the scenarios and collects the summary and the failed checks.
final class Harness {
	let out: URL
	let context = CIContext(options: [.cacheIntermediates: false])
	let lab: Lab
	let page: FlatPage
	let studio: Studio
	private(set) var failures: [String] = []
	private var summary: [String] = []

	init(out: URL) throws {
		self.out = out
		lab = Lab(context: context)
		page = try PageArt.makePage()
		studio = Studio(page: page, context: context)
	}

	func log(_ line: String) {
		print(line)
		summary.append(line)
	}

	func check(_ condition: Bool, _ message: String) {
		log((condition ? "  PASS " : "  FAIL ") + message)
		if !condition { failures.append(message) }
	}

	func finish() throws {
		let text = summary.joined(separator: "\n") + "\n"
		try text.write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
	}

	func folder(_ name: String) throws -> URL {
		let url = out.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}
}

// MARK: - Poses

/// The shots used by the scenarios: a reference held roughly square, then the phone eased left,
/// then eased up and right, each re-aimed at the page and with its own exposure.
enum Poses {
	static let height = 0.36

	static let reference = ShotSettings(
		pose: CameraPose(position: SIMD3(0.012, 0.02, -height), target: SIMD3(0, 0.005, 0), roll: 0.02),
		noiseSeed: 1
	)
	static let left = ShotSettings(
		pose: CameraPose(position: SIMD3(-0.068, 0.02, -height), target: SIMD3(0, 0, 0), roll: -0.03),
		exposure: SIMD3(0.94, 0.94, 0.92),
		noiseSeed: 2
	)
	static let upRight = ShotSettings(
		pose: CameraPose(position: SIMD3(0.06, -0.06, -height - 0.01), target: SIMD3(0.004, 0, 0), roll: 0.025),
		exposure: SIMD3(1.05, 1.05, 1.06),
		noiseSeed: 3
	)

	/// The second shot `offset` metres to the left of the reference, re-aimed at the page centre.
	static func sideways(_ offset: Double) -> ShotSettings {
		ShotSettings(
			pose: CameraPose(position: SIMD3(0.012 - offset, 0.02, -height), target: SIMD3(0, 0, 0), roll: -0.02),
			exposure: SIMD3(0.96, 0.96, 0.95),
			noiseSeed: 5 + CGFloat(offset * 100)
		)
	}

	static func matte(_ settings: ShotSettings) -> ShotSettings {
		var copy = settings
		copy.glareStrength = 0
		return copy
	}
}

// MARK: - Run

let outputPath = CommandLine.arguments.dropFirst().first ?? "glare-fusion-output"
let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
do {
	try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
	let harness = try Harness(out: outputURL)
	let started = CACurrentMediaTime()
	try harness.runSelfChecks()
	try harness.runGlossy(name: "glossy-3", shots: [Poses.reference, Poses.left, Poses.upRight], compareStacks: true)
	try harness.runGlossy(name: "glossy-2", shots: [Poses.reference, Poses.left], compareStacks: false)
	try harness.runOtherPage()
	var shadowed = Poses.left
	shadowed.shadow = (center: CGPoint(x: 1300, y: 1150), depth: 0.45)
	try harness.runGlossy(name: "phone-shadow", shots: [Poses.reference, shadowed, Poses.upRight], compareStacks: true)
	var moving = Poses.left
	moving.blur = 2.2
	try harness.runGlossy(name: "motion-blur", shots: [Poses.reference, moving, Poses.upRight], compareStacks: true)
	try harness.runMatte()
	try harness.runTiltSweep()
	harness.log(String(format: "\nTotal %.1f s. %d check(s) failed.", CACurrentMediaTime() - started, harness.failures.count))
	try harness.finish()
	exit(harness.failures.isEmpty ? 0 : 1)
} catch {
	print("HARNESS ERROR: \(error)")
	exit(2)
}
