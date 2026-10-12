//
//  ReviewCompareView.swift
//  Rescriva (fork of Open Scanner)
//
//  Review's "Side by side": one page at a time, the original over its
//  rebuilt version (left and right in landscape). Tapping a block on
//  either half selects it on both: its box lights up on the original,
//  which zooms in on it, and the rebuilt half scrolls to it. Blocks with
//  something to check are outlined in highlighter on the original. A grabber
//  between the halves sets how much room each one gets.
//

import SwiftUI

struct ReviewCompareView: View {
	let scan: Scan
	let document: RescrivaDocument
	let output: OutputKind
	@Binding var selectedBlock: UUID?
	let activeFlag: UUID?
	let onOpenFlag: (UUID) -> Void
	let onToggleItem: (UUID, UUID) -> Void
	let blockActions: (RescrivaBlock) -> [BlockAction]

	@State private var pageIndex = 0
	/// The original's share of the height in portrait.
	@State private var split: CGFloat = 0.45
	@State private var dragStartSplit: CGFloat?
	@State private var zoomsToSelection = true
	/// The block the original is zoomed on: set when a block is picked, not
	/// when Review opens with its first block selected.
	@State private var focusedBlock: UUID?

	var body: some View {
		VStack(spacing: 10) {
			pageBar
			GeometryReader { proxy in
				if proxy.size.width > proxy.size.height {
					HStack(spacing: 12) {
						originalPane
						rebuiltPane
					}
				} else {
					VStack(spacing: 0) {
						originalPane.frame(height: max(proxy.size.height * split - 14, 80))
						grabber(height: proxy.size.height)
						rebuiltPane
					}
				}
			}
		}
		.padding(.horizontal, 16)
		.onChange(of: selectedBlock) { _, id in
			followSelection(id)
			focusedBlock = zoomsToSelection ? id : nil
		}
		.onAppear { followSelection(selectedBlock) }
	}

	// MARK: Pieces

	private var page: RescrivaPage? {
		document.pages.indices.contains(pageIndex) ? document.pages[pageIndex] : document.pages.first
	}

	private var pageBar: some View {
		HStack(spacing: 12) {
			CircleIconButton(systemName: "chevron.left", label: "Previous page") { turn(by: -1) }
				.disabled(pageIndex == 0)
				.opacity(pageIndex == 0 ? 0.35 : 1)
			Spacer()
			Text("Page \(pageIndex + 1) of \(max(document.pages.count, 1))")
				.font(RescrivaFont.ui(13, weight: .medium))
				.foregroundStyle(.carbon)
				.monospacedDigit()
			Spacer()
			CircleIconButton(systemName: "chevron.right", label: "Next page") { turn(by: 1) }
				.disabled(pageIndex >= document.pages.count - 1)
				.opacity(pageIndex >= document.pages.count - 1 ? 0.35 : 1)
		}
	}

	private var originalPane: some View {
		ZStack(alignment: .topTrailing) {
			OriginalPageView(image: originalImage, blocks: page?.blocks ?? [], selectedBlock: selectedBlock,
							 flaggedBlocks: flaggedBlocks, focusedBlock: focusedBlock) { id in
				withAnimation(RescrivaMotion.fast) { selectedBlock = id }
			}
			Button {
				withAnimation(RescrivaMotion.ui) {
					zoomsToSelection = focusedBlock == nil
					focusedBlock = zoomsToSelection ? selectedBlock : nil
				}
			} label: {
				Glyph(focusedBlock == nil ? "plus.magnifyingglass" : "arrow.down.right.and.arrow.up.left", size: 14, weight: .medium)
					.foregroundStyle(.carbon)
					.frame(width: 34, height: 34)
					.background(Color.vellum.opacity(0.94), in: RoundedRectangle(cornerRadius: RescrivaRadius.control, style: .continuous))
					.rescrivaShadow(.small)
			}
			.buttonStyle(PressScaleStyle())
			.padding(8)
			.accessibilityLabel(focusedBlock == nil ? Text("Zoom to the selected block") : Text("Show the whole page"))
		}
		.background(Color.scanBackdrop, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
		.clipShape(RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
	}

	private var rebuiltPane: some View {
		ScrollViewReader { reader in
			ScrollView {
				if let page {
					RebuiltDocumentView(
						document: RescrivaDocument(title: document.title, pages: [page]), output: output,
						selectedBlock: selectedBlock, activeFlag: activeFlag,
						onSelectBlock: { id in withAnimation(RescrivaMotion.fast) { selectedBlock = id } },
						onOpenFlag: onOpenFlag, onToggleItem: onToggleItem, blockActions: blockActions
					)
					.padding(.vertical, 18)
					.padding(.horizontal, 16)
				}
			}
			.background(Color.paper, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
			.rescrivaShadow(.card)
			.onChange(of: selectedBlock) { _, id in
				guard let id else { return }
				withAnimation(RescrivaMotion.ui) { reader.scrollTo(id, anchor: .center) }
			}
		}
	}

	/// The handle between the halves: drag it to give one more room.
	private func grabber(height: CGFloat) -> some View {
		Capsule()
			.fill(Color.carbon.opacity(0.25))
			.frame(width: 44, height: 5)
			.frame(maxWidth: .infinity)
			.frame(height: 28)
			.contentShape(Rectangle())
			.gesture(
				DragGesture()
					.onChanged { value in
						let start = dragStartSplit ?? split
						dragStartSplit = start
						split = min(max(start + value.translation.height / max(height, 1), 0.25), 0.75)
					}
					.onEnded { _ in dragStartSplit = nil }
			)
			.accessibilityElement()
			.accessibilityLabel(Text("Divider"))
			.accessibilityValue(Text("Original takes \(Int((split * 100).rounded())) percent"))
			.accessibilityAdjustableAction { direction in
				switch direction {
				case .increment: split = min(split + 0.1, 0.75)
				case .decrement: split = max(split - 0.1, 0.25)
				@unknown default: break
				}
			}
	}

	// MARK: State

	private var originalImage: UIImage? {
		RecreateSource.capture(forPage: pageIndex, of: document, in: scan).flatMap { $0.image ?? $0.thumbnail }
	}

	/// Blocks on this page with a flag still open.
	private var flaggedBlocks: Set<UUID> {
		Set((page?.blocks ?? []).filter { block in block.content.flags.contains { $0.resolution == nil } }.map(\.id))
	}

	private func turn(by step: Int) {
		let next = min(max(pageIndex + step, 0), max(document.pages.count - 1, 0))
		guard next != pageIndex else { return }
		withAnimation(RescrivaMotion.ui) { pageIndex = next }
	}

	/// Shows the page a selected block (e.g. the next flag to check) lives on.
	private func followSelection(_ id: UUID?) {
		guard let id, let (index, _) = RecreateSource.locate(id, in: document), index != pageIndex else { return }
		withAnimation(RescrivaMotion.ui) { pageIndex = index }
	}
}

/// The scanned page with its blocks' boxes: the selected one lit in ink,
/// ones with something to check outlined in highlighter. Tapping inside a box
/// selects that block; the page zooms in on `focusedBlock` when there is one.
struct OriginalPageView: View {
	let image: UIImage?
	let blocks: [RescrivaBlock]
	let selectedBlock: UUID?
	let flaggedBlocks: Set<UUID>
	let focusedBlock: UUID?
	let onSelect: (UUID) -> Void

	var body: some View {
		GeometryReader { proxy in
			let fitted = fittedRect(in: proxy.size)
			let zoom = zoomTransform(for: fitted, in: proxy.size)
			ZStack(alignment: .topLeading) {
				if let image {
					Image(uiImage: image)
						.resizable()
						.frame(width: fitted.width, height: fitted.height)
						.offset(x: fitted.minX, y: fitted.minY)
				}
				Canvas { context, _ in drawBoxes(in: context, fitted: fitted, scale: zoom.scale) }
					.allowsHitTesting(false)
			}
			.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
			.scaleEffect(zoom.scale, anchor: .topLeading)
			.offset(zoom.offset)
			.contentShape(Rectangle())
			.onTapGesture { location in
				let unzoomed = CGPoint(x: (location.x - zoom.offset.width) / zoom.scale, y: (location.y - zoom.offset.height) / zoom.scale)
				if let id = block(at: unzoomed, fitted: fitted) { onSelect(id) }
			}
			.animation(RescrivaMotion.ui, value: focusedBlock)
		}
		.clipped()
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text("Original page"))
		.accessibilityHint(Text("The selected block is highlighted"))
	}

	/// Where the page image sits, fitted and centred, with a small margin.
	private func fittedRect(in size: CGSize) -> CGRect {
		guard let image, image.size.width > 0, image.size.height > 0 else { return CGRect(origin: .zero, size: size) }
		let available = CGSize(width: max(size.width - 16, 1), height: max(size.height - 16, 1))
		let scale = min(available.width / image.size.width, available.height / image.size.height)
		let width = image.size.width * scale, height = image.size.height * scale
		return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
	}

	/// The scale and offset that frame the focused block, or none.
	private func zoomTransform(for fitted: CGRect, in size: CGSize) -> (scale: CGFloat, offset: CGSize) {
		guard let box = focusedBox, size.width > 0, size.height > 0 else { return (1, .zero) }
		let target = rect(box, in: fitted).insetBy(dx: -16, dy: -16)
		guard target.width > 0, target.height > 0 else { return (1, .zero) }
		let scale = min(max(min(size.width / target.width, size.height / target.height), 1), 4)
		let offset = CGSize(width: size.width / 2 - target.midX * scale, height: size.height / 2 - target.midY * scale)
		let minimum = CGSize(width: size.width - size.width * scale, height: size.height - size.height * scale)
		return (scale, CGSize(width: min(max(offset.width, minimum.width), 0), height: min(max(offset.height, minimum.height), 0)))
	}

	private var focusedBox: NormalizedBox? {
		guard let focusedBlock else { return nil }
		return blocks.first { $0.id == focusedBlock }?.box
	}

	private func rect(_ box: NormalizedBox, in fitted: CGRect) -> CGRect {
		CGRect(x: fitted.minX + box.x * fitted.width, y: fitted.minY + box.y * fitted.height,
			   width: box.width * fitted.width, height: box.height * fitted.height)
	}

	/// Box outlines, thinned by `scale` so they look the same at any zoom.
	private func drawBoxes(in context: GraphicsContext, fitted: CGRect, scale: CGFloat) {
		let unit = 1 / max(scale, 1)
		for block in blocks {
			guard let box = block.box else { continue }
			let frame = Path(roundedRect: rect(box, in: fitted).insetBy(dx: -3 * unit, dy: -3 * unit), cornerRadius: 4 * unit)
			if block.id == selectedBlock {
				context.fill(frame, with: .color(Color.ink.opacity(0.14)))
				context.stroke(frame, with: .color(.ink), lineWidth: 2 * unit)
			} else if flaggedBlocks.contains(block.id) {
				context.stroke(frame, with: .color(.highlighter), style: StrokeStyle(lineWidth: 1.5 * unit, dash: [4 * unit, 3 * unit]))
			}
		}
	}

	/// The smallest block whose box holds `point`.
	private func block(at point: CGPoint, fitted: CGRect) -> UUID? {
		let hits = blocks.compactMap { block -> (UUID, CGFloat)? in
			guard let box = block.box else { return nil }
			let frame = rect(box, in: fitted).insetBy(dx: -6, dy: -6)
			return frame.contains(point) ? (block.id, frame.width * frame.height) : nil
		}
		return hits.min { $0.1 < $1.1 }?.0
	}
}
