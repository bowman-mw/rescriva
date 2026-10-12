//
//  RescrivaTheme.swift
//  Rescriva (fork of Open Scanner)
//
//  Rescriva's design tokens: paper and ink. Screens are warm paper stock,
//  type is carbon, actions are indigo ink, and one marker — a highlighter —
//  picks out whatever needs a look. In the dark the paper becomes a
//  chalkboard: charcoal slate, chalk-white type, blue and yellow chalk.
//
//  Headings are New York, the serif built into iOS, so screens read like a
//  document; controls stay sans. Flags are highlighted, never red: vermilion
//  is for delete alone. Pages settle into place; nothing shakes or flashes.
//

import SwiftUI
import UIKit

// MARK: - Palette

/// Every palette colour with its two appearances: on paper (light) and on the
/// chalkboard (dark). The `Color` tokens below are made from these. UIKit
/// views use them as they are, and anything saved into a document or drawn
/// onto a page takes `onPaper`, so it never follows the screen into the dark.
enum RescrivaPalette {
	static let stock = UIColor(paper: 0xF5F2EA, chalkboard: 0x222625)
	static let vellum = UIColor(paper: 0xFDFBF6, chalkboard: 0x2C302F)
	static let carbon = UIColor(paper: 0x1D2233, chalkboard: 0xECE9E1)
	static let graphite = UIColor(paper: 0x676C7A, chalkboard: 0xA3A79F)
	static let ink = UIColor(paper: 0x2B3B8C, chalkboard: 0xA9BAF2)
	static let bluePencil = UIColor(paper: 0x5A7BD0, chalkboard: 0x87A1EA)
	static let wash = UIColor(paper: 0xE3E7F4, chalkboard: 0x343A4C)
	static let vermilion = UIColor(paper: 0xCF4326, chalkboard: 0xF0866B)
	static let highlighter = UIColor(paper: 0xF6C823, chalkboard: 0xF2D660)
	static let markerInk = UIColor(paper: 0xB88A00, chalkboard: 0xF2D660)
	static let shade = UIColor(paper: 0x1D2233, chalkboard: 0x000000)
	static let scanBackdrop = UIColor(paper: 0xE7E3D9, chalkboard: 0x1A1D1C)
	static let rim = UIColor(paper: 0x1D2233, paperAlpha: 0.18, chalkboard: 0xECE9E1, chalkboardAlpha: 0.45)
	/// Folder inks beyond the tokens.
	static let plum = UIColor(paper: 0x7D4C76, chalkboard: 0xD3A6CC)
	static let sepia = UIColor(paper: 0x80562F, chalkboard: 0xD2AB82)
}

extension Color {
	/// Primary background: warm paper stock. Charcoal slate on the chalkboard.
	static let stock = Color(uiColor: RescrivaPalette.stock)
	/// Raised surfaces — cards, sheets, pills: a brighter sheet laid on the stock.
	static let vellum = Color(uiColor: RescrivaPalette.vellum)
	/// Primary text: carbon black with a little blue in it. Chalk white in the dark.
	static let carbon = Color(uiColor: RescrivaPalette.carbon)
	/// Secondary text and disabled states: graphite pencil.
	static let graphite = Color(uiColor: RescrivaPalette.graphite)
	/// The brand colour and primary actions: deep indigo ink. Blue chalk in the dark.
	static let ink = Color(uiColor: RescrivaPalette.ink)
	/// Secondary accent — progress, the camera's page outline: the editor's blue pencil.
	static let bluePencil = Color(uiColor: RescrivaPalette.bluePencil)
	/// A pale wash of ink for muted fills and the chosen row.
	static let wash = Color(uiColor: RescrivaPalette.wash)
	/// Destructive actions only (delete): a proofreader's red. Never errors, never flags.
	static let vermilion = Color(uiColor: RescrivaPalette.vermilion)
	/// The one marker: flags, highlights, pins. Type laid on it is `printInk`.
	static let highlighter = Color(uiColor: RescrivaPalette.highlighter)
	/// The highlighter as a line or an icon: a deeper marker yellow on paper, so it
	/// reads at hairline weight; the highlighter itself on the chalkboard.
	static let markerInk = Color(uiColor: RescrivaPalette.markerInk)
	/// Shadows and scrims: ink-tinted on paper, plain black on the chalkboard.
	static let shade = Color(uiColor: RescrivaPalette.shade)
	/// The desk behind original scans in review.
	static let scanBackdrop = Color(uiColor: RescrivaPalette.scanBackdrop)
	/// The hairline round a colour swatch: faint on paper, firmer on the
	/// chalkboard so a black swatch still shows.
	static let rim = Color(uiColor: RescrivaPalette.rim)

	/// The camera's dark surround, in either appearance.
	static let darkroom = Color(hex: 0x15171C)
	/// Type and controls on the camera's dark surround, in either appearance.
	static let chalk = Color(hex: 0xF1EEE6)
	/// Paper white for scanned pages and thumbnails, in either appearance.
	static let paper = Color(hex: 0xFFFDF8)
	/// Printed type, in either appearance: for words on paper and on the highlighter.
	static let printInk = Color(hex: 0x1D2233)
	/// Blue ballpoint, for handwriting renderings.
	static let ballpoint = Color(hex: 0x23367E)
}

extension ShapeStyle where Self == Color {
	static var stock: Color { Color.stock }
	static var vellum: Color { Color.vellum }
	static var carbon: Color { Color.carbon }
	static var graphite: Color { Color.graphite }
	static var ink: Color { Color.ink }
	static var bluePencil: Color { Color.bluePencil }
	static var wash: Color { Color.wash }
	static var vermilion: Color { Color.vermilion }
	static var highlighter: Color { Color.highlighter }
	static var markerInk: Color { Color.markerInk }
	static var chalk: Color { Color.chalk }
	static var printInk: Color { Color.printInk }
	static var ballpoint: Color { Color.ballpoint }
}

extension UIColor {
	/// The colour as it looks on paper (its light appearance), for marks saved
	/// into a document or drawn onto a page.
	var onPaper: UIColor {
		resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
	}
}

private extension UIColor {
	/// A colour that reads `paper` in the light and `chalkboard` in the dark.
	convenience init(paper: UInt, paperAlpha: CGFloat = 1, chalkboard: UInt, chalkboardAlpha: CGFloat = 1) {
		self.init(dynamicProvider: { traits in
			traits.userInterfaceStyle == .dark ? UIColor(hex: chalkboard, alpha: chalkboardAlpha) : UIColor(hex: paper, alpha: paperAlpha)
		})
	}

	convenience init(hex: UInt, alpha: CGFloat = 1) {
		self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
				  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
	}
}

// MARK: - Type

/// Rescriva's type roles. Headings and the document's own voice are New York,
/// the serif built into iOS (no licence, no bundled font); the interface keeps
/// its sans. Sizes follow Dynamic Type, capped so the layouts stay calm.
enum RescrivaFont {
	/// The wordmark: New York semibold.
	static func wordmark(_ size: CGFloat) -> Font {
		serif(size, weight: .semibold, style: .largeTitle)
	}

	/// Hero and state titles.
	static func display(_ size: CGFloat) -> Font {
		serif(size, weight: .semibold, style: .title1)
	}

	/// Section, sheet and document headers.
	static func header(_ size: CGFloat) -> Font {
		serif(size, weight: .medium, style: .title2)
	}

	/// Document body.
	static func body(_ size: CGFloat, italic: Bool = false) -> Font {
		serif(size, weight: .regular, italic: italic, style: .body)
	}

	/// A note in the margin: hints, tips and gentle empty states, in New York italic.
	static func note(_ size: CGFloat) -> Font {
		body(size, italic: true)
	}

	/// Interface labels, buttons, settings — DM Sans where it's bundled, otherwise SF Pro.
	static func ui(_ size: CGFloat, weight: UIFont.Weight = .regular) -> Font {
		let name = weight >= .medium ? "DMSans-Medium" : "DMSans-Regular"
		return font(names: [name], size: size, weight: weight, italic: false, design: .default, style: .subheadline)
	}

	private static func serif(_ size: CGFloat, weight: UIFont.Weight, italic: Bool = false, style: UIFont.TextStyle) -> Font {
		font(names: [], size: size, weight: weight, italic: italic, design: .serif, style: style)
	}

	private static func font(names: [String], size: CGFloat, weight: UIFont.Weight, italic: Bool, design: UIFontDescriptor.SystemDesign, style: UIFont.TextStyle) -> Font {
		let metrics = UIFontMetrics(forTextStyle: style)
		let maximum = size * 1.6
		for name in names {
			if let custom = UIFont(name: name, size: size) {
				return Font(metrics.scaledFont(for: custom, maximumPointSize: maximum))
			}
		}
		var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
		if let serif = descriptor.withDesign(design) {
			descriptor = serif
		}
		if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
			descriptor = slanted
		}
		let base = UIFont(descriptor: descriptor, size: size)
		return Font(metrics.scaledFont(for: base, maximumPointSize: maximum))
	}
}

extension View {
	/// A section label set like a document's running head: small capitals in
	/// graphite, tracked out.
	func rescrivaSectionLabel() -> some View {
		self.font(RescrivaFont.ui(11, weight: .semibold))
			.textCase(.uppercase)
			.tracking(0.9)
			.foregroundStyle(.graphite)
	}
}

// MARK: - Shape & elevation

/// Corner radii: a sheet of paper's softened corner, never a pebble.
enum RescrivaRadius {
	/// Chips and tags.
	static let small: CGFloat = 7
	/// Buttons and pills: a tab cut from card stock.
	static let control: CGFloat = 11
	/// Cards and modals.
	static let medium: CGFloat = 12
	/// Bottom sheets and floating panels.
	static let large: CGFloat = 22
	/// Full-bleed cards.
	static let extraLarge: CGFloat = 28
}

/// Paper-on-a-desk shadows: a close contact shadow plus a soft ambient one,
/// tinted with ink (black on the chalkboard).
enum RescrivaShadow {
	case small, card, float, sheet
}

extension View {
	/// Applies one of Rescriva's shadow tokens.
	@ViewBuilder
	func rescrivaShadow(_ shadow: RescrivaShadow) -> some View {
		switch shadow {
		case .small:
			self.shadow(color: Color.shade.opacity(0.12), radius: 1.5, x: 0, y: 1)
		case .card:
			self.shadow(color: Color.shade.opacity(0.10), radius: 1, x: 0, y: 1)
				.shadow(color: Color.shade.opacity(0.06), radius: 10, x: 0, y: 5)
		case .float:
			self.shadow(color: Color.shade.opacity(0.14), radius: 14, x: 0, y: 8)
				.shadow(color: Color.shade.opacity(0.08), radius: 2, x: 0, y: 1)
		case .sheet:
			self.shadow(color: Color.shade.opacity(0.10), radius: 12, x: 0, y: -4)
		}
	}

	/// A vellum card with a folded top corner, a hairline edge and the card shadow.
	func rescrivaCard(padding: CGFloat = 16, radius: CGFloat = RescrivaRadius.medium) -> some View {
		self.padding(padding)
			.paperCard(radius: radius)
	}
}

// MARK: - Motion

/// Motion tokens: ease-out or spring only, never linear. Rescriva's signatures
/// are a scan line passing over the page, ink drawing itself in as words are
/// read, and a page settling into place.
enum RescrivaMotion {
	/// UI transitions (250 ms).
	static let ui = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.25)
	/// Quick feedback (150 ms).
	static let fast = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.15)
	/// Gentle spring for toggles.
	static let spring = Animation.spring(response: 0.32, dampingFraction: 0.68)
	/// Loading transitions (700 ms).
	static let load = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.7)
	/// A page settling onto the stack: a short drop with the faintest overshoot.
	static let settle = Animation.spring(response: 0.46, dampingFraction: 0.72)
	/// One pass of the scan line down a page.
	static let scan = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 1.6)
	/// A line of ink drawing itself in.
	static let inkStroke = Animation.timingCurve(0.3, 0, 0.2, 1, duration: 0.55)
}

extension AnyTransition {
	/// Entry: a sheet settling onto the desk (dropping 8 pt into place as it
	/// fades in). Exit: dissolve. No slides.
	static var settle: AnyTransition {
		.asymmetric(
			insertion: .opacity.combined(with: .offset(y: -8)),
			removal: .opacity
		)
	}
}

/// Physical press feedback: scale to 0.92–0.97 with a quick ease-out.
struct PressScaleStyle: ButtonStyle {
	var scale: CGFloat = 0.92

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? scale : 1)
			.animation(RescrivaMotion.fast, value: configuration.isPressed)
	}
}

// MARK: - Texture

/// Paper grain: a tiled fibre texture over the stock, so no surface is a flat
/// digital rectangle. On paper it settles in like pulp (multiply); on the
/// chalkboard it lifts like chalk dust (screen).
struct GrainBackground: View {
	var base: Color = .stock
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		ZStack {
			base
			Image(uiImage: PaperGrain.tile)
				.resizable(resizingMode: .tile)
				.opacity(colorScheme == .dark ? 0.045 : 0.07)
				.blendMode(colorScheme == .dark ? .screen : .multiply)
		}
		.ignoresSafeArea()
		.accessibilityHidden(true)
	}
}

/// Generates the 192 × 192 grain tile once per launch with a fixed seed, so the
/// grain never shimmers between renders: fine mottling plus short, faint
/// fibres that wrap at the edges so the tile repeats without a seam.
enum PaperGrain {
	static let side = 192

	static let tile: UIImage = {
		let side = Self.side
		var generator = SeededGenerator(seed: 0x9A9E5)
		var values = [Double](repeating: 0, count: side * side)
		// Mottling: noise around mid grey, so the tile darkens (or lightens) evenly on average.
		for index in values.indices {
			values[index] = 128 + Double.random(in: -52...52, using: &generator)
		}
		// Fibres: short, slightly curving strokes, some darker and some lighter than the pulp.
		for _ in 0..<150 {
			var x = Double.random(in: 0..<Double(side), using: &generator)
			var y = Double.random(in: 0..<Double(side), using: &generator)
			var angle = Double.random(in: 0..<(2 * Double.pi), using: &generator)
			let length = Double.random(in: 6...26, using: &generator)
			let shift = Double.random(in: 34...70, using: &generator) * (Bool.random(using: &generator) ? 1 : -1)
			var travelled = 0.0
			while travelled < length {
				let column = (Int(x.rounded(.down)) % side + side) % side
				let row = (Int(y.rounded(.down)) % side + side) % side
				let index = row * side + column
				values[index] = min(255, max(0, values[index] + shift * 0.5))
				angle += Double.random(in: -0.12...0.12, using: &generator)
				x += cos(angle) * 0.6
				y += sin(angle) * 0.6
				travelled += 0.6
			}
		}
		var pixels = [UInt8](repeating: 255, count: side * side * 4)
		for (index, value) in values.enumerated() {
			let byte = UInt8(min(255, max(0, value.rounded())))
			pixels[index * 4] = byte
			pixels[index * 4 + 1] = byte
			pixels[index * 4 + 2] = byte
		}
		guard let provider = CGDataProvider(data: Data(pixels) as CFData),
			  let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
								  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
								  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
		else { return UIImage() }
		return UIImage(cgImage: image)
	}()
}

/// SplitMix64 — deterministic, so textures, sketches and sample content are stable.
struct SeededGenerator: RandomNumberGenerator {
	private var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E3779B97F4A7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
		z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
		return z ^ (z >> 31)
	}
}
