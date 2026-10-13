//
//  GlareCaptureTests.swift
//  Rescriva (fork of Open Scanner)
//
//  The camera's second look at a glary page: the debounced live check
//  (one bright frame doesn't count), the cells a live map clears, and the
//  trigger that takes the next still only once the phone has moved, settled
//  and sees the pending glare clean, firing once per still and reporting a
//  lost page. The fusion itself is checked by Tools/GlareFusionHarness.
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
		// Held for 0.3 s at frame 3 (t = 0.3).
		XCTAssertEqual(signals.firstIndex(of: .ready), 3)
		XCTAssertEqual(signals.filter { $0 == .ready }.count, 1, "fires once until restarted")
	}

	func testDoesNotFireWhileThePhoneIsStillMoving() {
		let coverage = GlareCoverage(first: map(glary: [5]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		let sliding = (0..<10).map { (quad(shiftedBy: 0.05 + CGFloat($0) * 0.02), map(glary: [])) as (PageQuad?, GlareMap?) }
		XCTAssertFalse(feed(&trigger, sliding).contains(.ready))
	}

	func testPartlyClearedGlareWaitsLongerBeforeFiring() {
		let coverage = GlareCoverage(first: map(glary: [5, 11, 17]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		let signals = feed(&trigger, Array(repeating: (quad(shiftedBy: 0.08), map(glary: [17])), count: 14))
		// Two of three cleared: it waits the 0.9 s partial settle (frame 9) rather than 0.3 s.
		XCTAssertEqual(signals.firstIndex(of: .ready), 9)
	}

	func testNothingClearedNeverFires() {
		let coverage = GlareCoverage(first: map(glary: [5, 11]))
		var trigger = SecondLookTrigger(coverage: coverage, lastStillQuad: quad(shiftedBy: 0))
		let signals = feed(&trigger, Array(repeating: (quad(shiftedBy: 0.08), map(glary: [5, 11])), count: 20))
		XCTAssertFalse(signals.contains(.ready))
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
