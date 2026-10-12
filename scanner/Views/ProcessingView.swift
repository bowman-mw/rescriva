//
//  ProcessingView.swift
//  Rescriva (fork of Open Scanner)
//
//  "Rebuilding your notes": a calm, step-by-step view of the on-device
//  rebuild. A scan line sweeps the page while the work runs, and the page's
//  lines ink themselves in as the steps complete; once it's done the page
//  settles flat. Each step lingers at least ~¾ s so it reads as care, not a
//  flash; the step in progress spins and counts its pages or words, so a
//  long PDF never looks stuck. Review opens only once the document is there.
//

import SwiftUI

struct ProcessingView: View {
	@Environment(RescrivaRouter.self) private var router
	@ObservedObject var scan: Scan

	@State private var stages: [RebuildStage] = []
	@State private var current = 0
	@State private var finished = false
	/// The rebuild's latest count, shown under the step in progress.
	@State private var latest: RebuildProgress?
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private let tier = DeviceTier.current

	/// From this many pages, the screen says a rebuild takes a few minutes.
	private static let longDocumentPages = 10

	var body: some View {
		ZStack {
			Color.stock.ignoresSafeArea()
			VStack(spacing: 28) {
				paperStack
				VStack(spacing: 6) {
					Text(finished ? "Ready to look over" : "Rebuilding your notes")
						.font(RescrivaFont.display(28))
						.foregroundStyle(.carbon)
						.contentTransition(.opacity)
					Text("Everything stays on this iPhone.")
						.font(RescrivaFont.note(15))
						.foregroundStyle(Color.carbon.opacity(0.7))
					if !finished, scan.capturesArray.count >= Self.longDocumentPages {
						Text("Long documents take a few minutes.")
							.font(RescrivaFont.note(15))
							.foregroundStyle(Color.carbon.opacity(0.7))
					}
				}
				.multilineTextAlignment(.center)
				.accessibilityElement(children: .combine)

				VStack(alignment: .leading, spacing: 10) {
					ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
						let done = index < current || finished
						let active = index == current && !finished
						let count = active && latest?.stage == stage ? latest : nil
						HStack(alignment: .top, spacing: 12) {
							marker(done: done, active: active)
							VStack(alignment: .leading, spacing: 6) {
								Text(stage.label(for: scan.rebuiltDocument))
									.font(RescrivaFont.ui(14))
									.foregroundStyle(.carbon)
								if let count, let detail = count.detail {
									Text(detail)
										.font(RescrivaFont.ui(12, weight: .medium))
										.foregroundStyle(Color.carbon.opacity(0.7))
										.monospacedDigit()
									ProgressView(value: Double(min(count.done, count.total)), total: Double(max(count.total, 1)))
										.tint(.bluePencil)
										.animation(RescrivaMotion.ui, value: count.done)
								}
							}
							.padding(.top, 2)
						}
						.opacity(done || active ? 1 : 0.4)
						.animation(.easeOut(duration: 0.4), value: current)
						.accessibilityElement(children: .combine)
						.accessibilityValue(done ? Text("Done") : active ? Text("In progress") : Text("Waiting"))
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.padding(.horizontal, 40)
		}
		.task { await run() }
	}

	/// A ticked box once a step is done, a spinner while it runs, an empty box before.
	private func marker(done: Bool, active: Bool) -> some View {
		ZStack {
			if active {
				ProgressView()
					.controlSize(.small)
					.tint(.bluePencil)
			} else {
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.strokeBorder(Color.bluePencil, lineWidth: 1.5)
					.background { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(done ? Color.bluePencil : Color.clear) }
				if done {
					Glyph("checkmark", size: 11, weight: .bold)
						.foregroundStyle(.vellum)
				}
			}
		}
		.frame(width: 22, height: 22)
	}

	/// How far the rebuild has got, in steps: the steps done plus the counted part of the one in
	/// progress, so the page keeps writing itself in through a long document.
	private var sweepPosition: Double {
		guard !finished else { return Double(stages.count) }
		guard let latest, latest.total > 0, stages.indices.contains(current), latest.stage == stages[current] else {
			return Double(current)
		}
		return Double(current) + Double(min(latest.done, latest.total)) / Double(latest.total)
	}

	/// How much of the page is written (0–1): the steps done plus the counted part of the one in
	/// progress, out of all the steps.
	private var written: Double {
		guard !finished else { return 1 }
		return min(max(sweepPosition / Double(max(stages.count, 1)), 0), 1)
	}

	/// The page being rebuilt on a page already done: a scan line sweeps it while the work runs
	/// and its lines ink themselves in step by step. Once it's done the page settles flat.
	private var paperStack: some View {
		ZStack {
			FoldedSheet(radius: 3, fold: 16)
				.fill(Color.paper)
				.rotationEffect(.degrees(-5))
				.rescrivaShadow(.card)
			ZStack(alignment: .top) {
				Color.paper
				PageBeingWritten(written: written)
					.padding(.vertical, 18)
					.padding(.horizontal, 16)
				if !finished {
					ScanLineLoop(color: .highlighter)
						.transition(.opacity)
				}
			}
			.foldedPage(radius: 3, fold: 16)
			.rotationEffect(.degrees(finished || reduceMotion ? 0 : 2))
			.rescrivaShadow(.float)
			.animation(reduceMotion ? nil : RescrivaMotion.settle, value: finished)
		}
		.frame(width: 150, height: 190)
		.environment(\.colorScheme, .light)
		.accessibilityHidden(true)
	}

	private func run() async {
		stages = RebuildStage.stages(for: tier, document: scan.rebuiltDocument)
		let tracker = RebuildTracker()
		let rebuilder = Rebuilder(tier: tier)
		let stageList = stages
		let work = Task { @MainActor in
			_ = await rebuilder.document(for: scan) { step in
				tracker.latest = step
				if let index = stageList.firstIndex(of: step.stage) {
					tracker.started = max(tracker.started, index)
				}
			}
			tracker.done = true
		}
		guard await revealSteps(tracker: tracker, work: work) else { return }
		finished = true
		do {
			try await Task.sleep(for: .milliseconds(500))
		} catch {
			return
		}
		guard router.top == .processing(scan) else { return }
		router.replaceTop(with: .review(scan))
	}

	/// Upper bound on 100 ms animation ticks (an hour) for one rebuild. Past it the steps stop
	/// moving, but Review still waits for the document.
	private static let maxTicks = 36_000

	/// Completes each step once the work has moved past it, and no sooner than
	/// ~750 ms after the previous one, showing the latest count as it goes. Returns
	/// once the work is done, or false if cancelled (which cancels the work).
	private func revealSteps(tracker: RebuildTracker, work: Task<Void, Never>) async -> Bool {
		var lastStep = ContinuousClock.now
		for _ in 0..<Self.maxTicks where !(tracker.done && current >= stages.count) {
			do {
				try await Task.sleep(for: .milliseconds(100))
			} catch {
				work.cancel()
				return false
			}
			if latest != tracker.latest {
				latest = tracker.latest
			}
			let completed = tracker.done ? stages.count : tracker.started
			if current < completed, ContinuousClock.now - lastStep >= .milliseconds(750) {
				current += 1
				lastStep = ContinuousClock.now
			}
		}
		// Review shows the scan's document, so never leave before it's there.
		await withTaskCancellationHandler {
			await work.value
		} onCancel: {
			work.cancel()
		}
		return !Task.isCancelled
	}
}

/// The page in the processing illustration: a heading, three lines and a small diagram, each
/// written in, left to right, as the rebuild reaches it.
private struct PageBeingWritten: View {
	let written: Double
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			RoundedRectangle(cornerRadius: 1).fill(Color.ink).frame(width: 72, height: 7)
				.inked(share(0))
			ForEach(Array([0.92, 0.84, 0.88].enumerated()), id: \.offset) { index, fraction in
				RoundedRectangle(cornerRadius: 0.5).fill(Color.carbon.opacity(0.22)).frame(width: 116 * fraction, height: 3)
					.inked(share(index + 1))
			}
			HStack(spacing: 0) {
				RoundedRectangle(cornerRadius: 3).strokeBorder(Color.ink, lineWidth: 1.5).frame(width: 40, height: 22)
				Rectangle().fill(Color.ink).frame(width: 18, height: 1.5)
				RoundedRectangle(cornerRadius: 3).strokeBorder(Color.ink, lineWidth: 1.5).frame(width: 40, height: 22)
			}
			.inked(share(4))
			.padding(.top, 8)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		// With Reduce Motion each line appears whole instead of being written in.
		.animation(reduceMotion ? nil : RescrivaMotion.load, value: written)
	}

	/// How much of row `index` (of five, top to bottom) is written.
	private func share(_ index: Int) -> CGFloat {
		let share = min(max(written * 5 - Double(index), 0), 1)
		return CGFloat(reduceMotion ? share.rounded(.up) : share)
	}
}

/// Shared between the rebuild task and the step animation.
@MainActor
private final class RebuildTracker {
	var started = 0
	var latest: RebuildProgress?
	var done = false
}
