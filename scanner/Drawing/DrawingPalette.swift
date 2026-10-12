//
//  DrawingPalette.swift
//  Rescriva (fork of Open Scanner)
//
//  The colours and shape names the drawing editor offers: border inks and
//  pale washes from Rescriva's paper-and-ink palette, so a recreated
//  whiteboard keeps its colours without clashing with the rest of Rescriva.
//

import SwiftUI

/// The border and fill swatches the drawing editor offers. These are colours
/// on paper: they go into exported files, so they don't change in the dark.
enum DrawingPalette {
	/// One swatch; a nil colour means "none" (fills only).
	struct Swatch: Identifiable, Hashable {
		let id: String
		let name: String
		let color: RGBColor?
	}

	static let borders: [Swatch] = [
		Swatch(id: "carbon", name: String(localized: "Carbon"), color: RGBColor(hex: 0x1D2233)),
		Swatch(id: "indigo", name: String(localized: "Indigo"), color: RGBColor(hex: 0x2B3B8C)),
		Swatch(id: "vermilion", name: String(localized: "Vermilion"), color: RGBColor(hex: 0xCF4326)),
		Swatch(id: "blue-pencil", name: String(localized: "Blue Pencil"), color: RGBColor(hex: 0x5A7BD0)),
		Swatch(id: "sepia", name: String(localized: "Sepia"), color: RGBColor(hex: 0x80562F)),
		Swatch(id: "graphite", name: String(localized: "Graphite"), color: RGBColor(hex: 0x676C7A)),
	]

	static let fills: [Swatch] = [
		Swatch(id: "none", name: String(localized: "No fill"), color: nil),
		Swatch(id: "paper", name: String(localized: "Paper"), color: RGBColor(hex: 0xFFFDF8)),
		Swatch(id: "wash", name: String(localized: "Ink Wash"), color: RGBColor(hex: 0xE3E7F4)),
		Swatch(id: "blush", name: String(localized: "Blush"), color: RGBColor(hex: 0xF8E1DA)),
		Swatch(id: "highlight", name: String(localized: "Highlight"), color: RGBColor(hex: 0xFBEFB8)),
		Swatch(id: "mist", name: String(localized: "Mist"), color: RGBColor(hex: 0xE4E6EA)),
	]

	/// The border a new shape starts with.
	static var defaultBorder: RGBColor { borders[0].color ?? RGBColor(hex: 0x1D2233) }
	/// The fill a new shape starts with.
	static var defaultFill: RGBColor? { fills[1].color }
}

extension RGBColor {
	/// The colour for SwiftUI.
	var swiftUI: Color { Color(red: red, green: green, blue: blue) }
}

extension Diagram.Shape {
	/// Every shape, in the order the editor's palette shows them.
	static let paletteOrder: [Diagram.Shape] = [.rectangle, .roundedRectangle, .ellipse, .diamond, .parallelogram]

	/// The shape's name on screen (the raw value is a stored token).
	var displayName: String {
		switch self {
		case .rectangle: return String(localized: "Rectangle")
		case .roundedRectangle: return String(localized: "Rounded rectangle")
		case .ellipse: return String(localized: "Ellipse")
		case .diamond: return String(localized: "Diamond")
		case .parallelogram: return String(localized: "Parallelogram")
		}
	}
}

extension Diagram.Direction {
	/// The connector kind's name on screen.
	var displayName: String {
		switch self {
		case .forward: return String(localized: "Arrow")
		case .none: return String(localized: "Line")
		case .both: return String(localized: "Double arrow")
		}
	}
}
