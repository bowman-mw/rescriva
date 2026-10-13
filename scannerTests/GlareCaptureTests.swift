//
//  GlareCaptureTests.swift
//  Rescriva (fork of Open Scanner)
//
//  The camera's second look at a glary page: the debounced live check
//  (one bright frame doesn't count), the cells a live map clears, the
//  trigger that takes the next still only once the phone has moved and
//  settled (sooner where the pending glare looks clean), firing once per
//  still and reporting a lost page, and auto-capture that, after a second
//  look, waits for the page to leave instead of re-taking it. The fusion
//  itself is checked by Tools/GlareFusionHarness.
//

import CoreGraphics
import XCTest
@testable import scanner

final class GlareCaptureTests: XCTestCase {

	// MARK: Fixtures

	/// A 6 × 8 map with the listed cells glary (share 0.5) and the rest clean.
	private func map(glary: Set<Int>) -> GlareMap {
		let cells = (0..<48).map { glary.contains($0) ? Float(0.5) : 0 }
		return GlareMap(columns: 6, rows: 8, cells: cells)!
	}

	private func quad(shiftedBy dx: CGFloat) -> PageQuad {
		PageQuad(unordered: [
			CGPoint(x: 0.2 + dx, y: 0.15), CGPoint(x: 0.8 + dx, y: 0.15),
			CGPoint(x: 0.8 + dx, y: 0.85), CGPoint(x: 0.2 + dx, y: 0.85),
		])!
	}

	/// Feeds `frames` at 10 fps from `start` and returns every signal.
	private func feed(_ trigger: inout SecondLookTrigger, _ frames: [(PageQuad?, GlareMap?)], from start: TimeInterval = 0) -> [SecondLookTrigger.Signal] {
		frames.enumerated().map { index, frame in
			trigger.update(quad: frame.0, glare: frame.1, at: start + Double(index) * 0.1)
		}
	}

	// MARK: Debouncer

	func testOneBrightFrameDoesNotCountAsGlare() {
		var debouncer = GlareDebouncer()
		let glary = map(glary: [10])
		let clean = map(glary: [])
		XCTAssertFalse(debouncer.update(glary))
		XCTAssertFalse(debouncer.update(clean))
		XCTAssertFalse(debouncer.update(clean))
		XCTAssertFalse(debouncer.update(glary))
		XCTAssertTrue(debouncer.update(glary), "3 of the last 5 frames glary")
		debouncer.reset()
		XCTAssertFalse(debouncer.isGlary)
	}

	func testGlareFadesOnceFewerThanThreeOfFiveFramesShowIt() {
		var debouncer = GlareDebouncer()
		let glary = map(glary: [3])
		let clean = map(glary: [])
		for _ in 0..<5 { _ = debouncer.update(glary) }
		XCTAssertTrue(debouncer.isGlary)
		XCTAssertTrue(debouncer.update(clean))
		XCTAssertTrue(debouncer.update(clean))
		XCTAssertFalse(debouncer.update(clean), "only 2 of the last 5 glary")
	}

	// MARK: Coverage

	func testClearedCountCountsPendingCellsSeenClean() {
		let coverage = GlareCoverage(first: map(glary: [4, 5, 10]))
		XCTAssertEqual(coverage.clearedCount(in: map(glary: [4])), 2)
		XCTAssertEqual(coverage.clearedCount(in: map(glary: [4, 5, 10, 20])), 0)
		XCTAssertEqual(coverage.clearedCount(in: GlareMap(columns: 3, rows: 4, cells: Array(repeating: 0, count: 12))!), 0,
					   "a map of another grid clears nothing")
	}

	// MARK: Trigger

	func testWaitsUntilThePhoneHasMovedOffTheLastStill() {
		let coverage = GlareCoverage(first: map(glary: [5, 11]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		// Clean, steady, but in the same place as the last still: Smart HDR and the preview disagree there.
		let signals = feed(&trigger, Array(repeating: (quad(shiftedBy: 0.01), map(glary: [])), count: 12))
		XCTAssertFalse(signals.contains(.ready))
	}

	func testFiresOnceSettledWhereEveryPendingCellIsClean() {
		let coverage = GlareCoverage(first: map(glary: [5, 11]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		let moved = quad(shiftedBy: 0.08)
		let signals = feed(&trigger, Array(repeating: (moved, map(glary: [])), count: 8))
		// The 0.25 s hold is first met at frame 3 (t = 0.3).
		XCTAssertEqual(signals.firstIndex(of: .ready), 3)
		XCTAssertEqual(signals.filter { $0 == .ready }.count, 1, "fires once until restarted")
	}

	func testDoesNotFireWhileThePhoneIsStillMoving() {
		let coverage = GlareCoverage(first: map(glary: [5]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		let sliding = (0..<10).map { (quad(shiftedBy: 0.05 + CGFloat($0) * 0.03), map(glary: [])) as (PageQuad?, GlareMap?) }
		XCTAssertFalse(feed(&trigger, sliding).contains(.ready))
	}

	func testPartlyClearedGlareWaitsLongerBeforeFiring() {
		let coverage = GlareCoverage(first: map(glary: [5, 11, 17]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		let signals = feed(&trigger, Array(repeating: (quad(shiftedBy: 0.08), map(glary: [17])), count: 14))
		// Two of three cleared: it waits the 0.6 s partial settle (frame 6) rather than 0.25 s.
		XCTAssertEqual(signals.firstIndex(of: .ready), 6)
	}

	func testAShortSlideWithNothingClearedNeverFires() {
		let coverage = GlareCoverage(first: map(glary: [5, 11]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		let signals = feed(&trigger, Array(repeating: (quad(shiftedBy: 0.08), map(glary: [5, 11])), count: 20))
		XCTAssertFalse(signals.contains(.ready))
		XCTAssertEqual(trigger.phase, .move)
	}

	func testALongEnoughSlideFiresEvenWhileThePreviewStillShowsGlare() {
		let coverage = GlareCoverage(first: map(glary: [5, 11]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		let signals = feed(&trigger, Array(repeating: (quad(shiftedBy: 0.12), map(glary: [5, 11])), count: 8))
		// The preview's highlight blooms wider than the still's; 0.4 s held is enough (frame 4).
		XCTAssertEqual(signals.firstIndex(of: .ready), 4)
	}

	func testPhaseSaysMoveUntilFarEnoughThenHold() {
		let coverage = GlareCoverage(first: map(glary: [5]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		_ = trigger.update(quad: quad(shiftedBy: 0.01), glare: map(glary: []), at: 0)
		XCTAssertEqual(trigger.phase, .move)
		_ = trigger.update(quad: quad(shiftedBy: 0.06), glare: map(glary: []), at: 0.1)
		XCTAssertEqual(trigger.phase, .hold)
		_ = trigger.update(quad: nil, glare: nil, at: 0.2)
		XCTAssertEqual(trigger.phase, .move)
	}

	// MARK: Auto-capture after a second look

	/// Feeds `quad` at 10 fps over `seconds` from `start`; true if auto-capture fired.
	private func hold(_ tracker: inout QuadStabilityTracker, _ quad: PageQuad?, from start: TimeInterval, for seconds: TimeInterval) -> Bool {
		var fired = false
		for step in 0..<Int((seconds * 10).rounded()) {
			fired = tracker.update(quad: quad, at: start + Double(step) * 0.1, autoCaptureEnabled: true).shouldAutoCapture || fired
		}
		return fired
	}

	func testMovingThePageReArmsAutoCaptureAfterAnOrdinaryShot() {
		var tracker = QuadStabilityTracker()
		XCTAssertTrue(hold(&tracker, quad(shiftedBy: 0), from: 0, for: 1))
		XCTAssertTrue(hold(&tracker, quad(shiftedBy: 0.2), from: 1, for: 3), "moved past the re-arm distance")
	}

	func testAfterASecondLookAutoCaptureWaitsForThePageToLeave() {
		var tracker = QuadStabilityTracker()
		XCTAssertTrue(hold(&tracker, quad(shiftedBy: 0), from: 0, for: 1))
		// The second look slid the phone about; it ends here, over the same page.
		tracker.noteCapture(at: 1, untilPageLeaves: true)
		XCTAssertFalse(hold(&tracker, quad(shiftedBy: 0.2), from: 1, for: 3), "sliding back doesn't take the page again")
		XCTAssertFalse(tracker.isArmed)
		XCTAssertFalse(hold(&tracker, nil, from: 4, for: 0.5))
		XCTAssertTrue(hold(&tracker, quad(shiftedBy: 0), from: 4.5, for: 1.5), "the next page, after this one left the frame")
	}

	func testRestartArmsTheTriggerForTheNextStill() {
		var coverage = GlareCoverage(first: map(glary: [5, 30]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		XCTAssertTrue(feed(&trigger, Array(repeating: (quad(shiftedBy: 0.08), map(glary: [30])), count: 12)).contains(.ready))
		coverage.add(map(glary: [30]))
		trigger.restart(coverage: coverage, lastStillQuad: quad(shiftedBy: 0.08))
		let next = feed(&trigger, Array(repeating: (quad(shiftedBy: 0.16), map(glary: [])), count: 6), from: 2)
		XCTAssertEqual(next.firstIndex(of: .ready), 3)
	}

	func testReportsALostPageAfterOneSecond() {
		let coverage = GlareCoverage(first: map(glary: [5]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		let signals = feed(&trigger, Array(repeating: (nil, nil), count: 12))
		XCTAssertEqual(signals.firstIndex(of: .pageLost), 10)
		// The page coming back clears it.
		XCTAssertEqual(trigger.update(quad: quad(shiftedBy: 0), glare: nil, at: 1.3), .waiting)
	}
}
