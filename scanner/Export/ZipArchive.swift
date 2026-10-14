//
//  ZipArchive.swift
//  Rescriva (fork of Open Scanner)
//
//  A minimal ZIP writer (DEFLATE through Apple's Compression framework, STORED
//  when that doesn't shrink an entry) plus the Open Packaging Conventions
//  helpers the Word and PowerPoint renderers share: XML escaping,
//  `[Content_Types].xml`, relationship parts, document properties, image
//  header sniffing and the DrawingML tokens both diagram writers use.
//  Foundation-only so it builds for the app and for macOS test harnesses alike.
//

import Compression
import Foundation

/// Errors thrown while packaging an export.
enum RescrivaExportError: Error, Equatable {
	/// The same path was added to an archive twice.
	case duplicateEntry(String)
	/// An entry path was empty, absolute or too long for a ZIP header.
	case invalidPath(String)
	/// An entry or the archive passed the 4 GiB limit of classic (non-ZIP64) ZIP.
	case archiveTooLarge
	/// More than 65 535 entries, the classic ZIP limit.
	case tooManyEntries
}

/// A minimal ZIP writer: DEFLATE (method 8) or STORED entries with CRC-32,
/// local file headers, a central directory and an end-of-central-directory
/// record.
///
/// Entries are written in the order they were added, except that
/// `[Content_Types].xml` is always written first, which some Office readers
/// expect. Each entry is deflated with the Compression framework and kept
/// STORED when that would not make it smaller (pictures, tiny parts). No
/// ZIP64 and no encryption.
struct ZipArchive {
	/// ZIP compression methods written.
	enum Method: UInt16 {
		case stored = 0
		case deflate = 8
	}

	/// One file waiting to be written.
	private struct Entry {
		let path: String
		let nameBytes: Data
		/// The bytes written after the local header: deflated, or the file as given.
		let payload: Data
		let method: Method
		/// Uncompressed size.
		let size: UInt32
		let crc: UInt32
		let isASCII: Bool
	}

	/// The OPC content-types part, always written first.
	static let contentTypesPath = "[Content_Types].xml"

	private var entries: [Entry] = []
	private var names: Set<String> = []
	/// Modification time written on every entry (DOS format, local time).
	let modified: Date

	init(modified: Date = Date()) {
		self.modified = modified
	}

	/// Entry paths in the order they will be written.
	var paths: [String] { orderedEntries.map(\.path) }

	/// The compression method chosen for `path`; nil when no such entry was added.
	func method(for path: String) -> Method? {
		entries.first { $0.path == path }?.method
	}

	/// Adds a file. Paths use `/` separators and must be relative.
	mutating func add(_ path: String, data: Data) throws {
		guard !path.isEmpty, !path.hasPrefix("/") else { throw RescrivaExportError.invalidPath(path) }
		guard !names.contains(path) else { throw RescrivaExportError.duplicateEntry(path) }
		guard entries.count < 0xFFFF else { throw RescrivaExportError.tooManyEntries }
		guard UInt64(data.count) < UInt64(UInt32.max) else { throw RescrivaExportError.archiveTooLarge }
		let nameBytes = Data(path.utf8)
		guard nameBytes.count <= 0xFFFF else { throw RescrivaExportError.invalidPath(path) }
		let isASCII = path.unicodeScalars.allSatisfy(\.isASCII)
		let deflated = Self.deflate(data)
		entries.append(Entry(path: path, nameBytes: nameBytes, payload: deflated ?? data,
							 method: deflated == nil ? .stored : .deflate, size: UInt32(data.count),
							 crc: Self.crc32(data), isASCII: isASCII))
		names.insert(path)
	}

	/// Adds a UTF-8 text file.
	mutating func add(_ path: String, text: String) throws {
		try add(path, data: Data(text.utf8))
	}

	/// The finished archive bytes.
	func archiveData() throws -> Data {
		let stamp = Self.dosDateTime(modified)
		var output = Data()
		var central = Data()
		let ordered = orderedEntries
		for entry in ordered {
			guard UInt64(output.count) < UInt64(UInt32.max) else { throw RescrivaExportError.archiveTooLarge }
			let offset = UInt32(output.count)
			let flags: UInt16 = entry.isASCII ? 0 : 0x0800
			let compressedSize = UInt32(entry.payload.count)
			let nameLength = UInt16(entry.nameBytes.count)

			output.appendLittleEndian(UInt32(0x0403_4B50))
			output.appendLittleEndian(UInt16(20))
			output.appendLittleEndian(flags)
			output.appendLittleEndian(entry.method.rawValue)
			output.appendLittleEndian(stamp.time)
			output.appendLittleEndian(stamp.date)
			output.appendLittleEndian(entry.crc)
			output.appendLittleEndian(compressedSize)
			output.appendLittleEndian(entry.size)
			output.appendLittleEndian(nameLength)
			output.appendLittleEndian(UInt16(0))
			output.append(entry.nameBytes)
			output.append(entry.payload)

			central.appendLittleEndian(UInt32(0x0201_4B50))
			central.appendLittleEndian(UInt16(20))
			central.appendLittleEndian(UInt16(20))
			central.appendLittleEndian(flags)
			central.appendLittleEndian(entry.method.rawValue)
			central.appendLittleEndian(stamp.time)
			central.appendLittleEndian(stamp.date)
			central.appendLittleEndian(entry.crc)
			central.appendLittleEndian(compressedSize)
			central.appendLittleEndian(entry.size)
			central.appendLittleEndian(nameLength)
			central.appendLittleEndian(UInt16(0))
			central.appendLittleEndian(UInt16(0))
			central.appendLittleEndian(UInt16(0))
			central.appendLittleEndian(UInt16(0))
			central.appendLittleEndian(UInt32(0))
			central.appendLittleEndian(offset)
			central.append(entry.nameBytes)
		}
		let total = UInt64(output.count) + UInt64(central.count) + 22
		guard total < UInt64(UInt32.max) else { throw RescrivaExportError.archiveTooLarge }
		let centralOffset = UInt32(output.count)
		output.append(central)
		output.appendLittleEndian(UInt32(0x0605_4B50))
		output.appendLittleEndian(UInt16(0))
		output.appendLittleEndian(UInt16(0))
		output.appendLittleEndian(UInt16(ordered.count))
		output.appendLittleEndian(UInt16(ordered.count))
		output.appendLittleEndian(UInt32(central.count))
		output.appendLittleEndian(centralOffset)
		output.appendLittleEndian(UInt16(0))
		return output
	}

	private var orderedEntries: [Entry] {
		entries.filter { $0.path == Self.contentTypesPath } + entries.filter { $0.path != Self.contentTypesPath }
	}

	// MARK: DEFLATE, CRC-32 and DOS time

	/// `data` as a raw DEFLATE stream (RFC 1951, the payload of ZIP method 8),
	/// or nil when compressing fails or would not make it smaller. Compression's
	/// `COMPRESSION_ZLIB` writes the bare stream with no zlib header or trailer,
	/// which is exactly what a ZIP entry holds.
	static func deflate(_ data: Data) -> Data? {
		guard !data.isEmpty else { return nil }
		let capacity = data.count
		var output = Data(count: capacity)
		let written = data.withUnsafeBytes { source -> Int in
			guard let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
			return output.withUnsafeMutableBytes { destination -> Int in
				guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
				return compression_encode_buffer(destinationBase, capacity, sourceBase, source.count, nil, COMPRESSION_ZLIB)
			}
		}
		guard written > 0, written < data.count else { return nil }
		output.count = written
		return output
	}

	/// The bytes a raw DEFLATE stream of known uncompressed `size` decodes to,
	/// or nil when it is malformed or decodes to another length.
	static func inflate(_ payload: Data, size: Int) -> Data? {
		guard size > 0 else { return payload.isEmpty ? Data() : nil }
		var output = Data(count: size)
		let written = payload.withUnsafeBytes { source -> Int in
			guard let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
			return output.withUnsafeMutableBytes { destination -> Int in
				guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
				return compression_decode_buffer(destinationBase, size, sourceBase, source.count, nil, COMPRESSION_ZLIB)
			}
		}
		guard written == size else { return nil }
		return output
	}

	private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
		var value = UInt32(index)
		for _ in 0..<8 {
			value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
		}
		return value
	}

	/// CRC-32 (IEEE 802.3, the ZIP polynomial) of `data`.
	static func crc32(_ data: Data) -> UInt32 {
		let table = crcTable
		var crc: UInt32 = 0xFFFF_FFFF
		for byte in data {
			crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
		}
		return crc ^ 0xFFFF_FFFF
	}

	/// MS-DOS time and date fields for `date` in the current time zone,
	/// clamped to the representable 1980–2107 range.
	static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone.current
		let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
		let year = min(max(parts.year ?? 1980, 1980), 2107)
		let month = parts.month ?? 1
		let day = parts.day ?? 1
		let time = ((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) / 2)
		let dosDate = ((year - 1980) << 9) | (month << 5) | day
		return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: dosDate))
	}
}

private extension Data {
	mutating func appendLittleEndian<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
		for shift in stride(from: 0, to: T.bitWidth, by: 8) {
			append(UInt8(truncatingIfNeeded: value >> shift))
		}
	}
}

// MARK: - DrawingML tokens shared by the diagram writers

extension Diagram.Direction {
	/// DrawingML line-end decorations: the head end is the line's start, the
	/// tail end its finish.
	var drawingMLLineEnds: String {
		let arrow = "type=\"triangle\" w=\"med\" len=\"med\""
		switch self {
		case .forward: return "<a:tailEnd \(arrow)/>"
		case .none: return ""
		case .both: return "<a:headEnd \(arrow)/><a:tailEnd \(arrow)/>"
		}
	}
}

extension Diagram.Shape {
	/// The DrawingML preset geometry (`a:prstGeom prst`) that draws this shape.
	var presetGeometry: String {
		switch self {
		case .rectangle: return "rect"
		case .roundedRectangle: return "roundRect"
		case .ellipse: return "ellipse"
		case .diamond: return "diamond"
		case .parallelogram: return "parallelogram"
		}
	}
}

extension RGBColor {
	/// Whether text over this colour should be white: its relative luminance
	/// is under 0.45.
	var isDark: Bool {
		0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.45
	}
}

// MARK: - Open Packaging Conventions helpers

/// Helpers shared by the Word and PowerPoint renderers: XML escaping, units,
/// content types, relationships and the document-properties parts.
enum OOXML {
	/// The XML declaration every part starts with.
	static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
	/// English Metric Units per inch.
	static let emuPerInch = 914_400.0
	/// English Metric Units per point.
	static let emuPerPoint = 12_700.0

	/// Escapes `text` for use in XML character data or a quoted attribute, and
	/// drops every character XML 1.0 does not allow (control characters,
	/// U+FFFE, U+FFFF).
	static func escape(_ text: String) -> String {
		var output = String()
		output.reserveCapacity(text.utf8.count)
		for scalar in text.unicodeScalars {
			switch scalar {
			case "&": output += "&amp;"
			case "<": output += "&lt;"
			case ">": output += "&gt;"
			case "\"": output += "&quot;"
			case "'": output += "&apos;"
			default:
				if isLegalXMLScalar(scalar) { output.unicodeScalars.append(scalar) }
			}
		}
		return output
	}

	/// Whether XML 1.0 allows `scalar` in a document.
	static func isLegalXMLScalar(_ scalar: Unicode.Scalar) -> Bool {
		let value = scalar.value
		switch value {
		case 0x9, 0xA, 0xD: return true
		case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
		default: return false
		}
	}

	/// W3C date-time in UTC without fractional seconds, e.g. `2026-10-10T09:30:00Z`.
	static func timestamp(_ date: Date) -> String {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime]
		formatter.timeZone = TimeZone(identifier: "UTC")
		return formatter.string(from: date)
	}

	/// Inches to EMU, rounded.
	static func emu(inches: Double) -> Int { Int((inches * emuPerInch).rounded()) }

	/// Points to EMU, rounded.
	static func emu(points: Double) -> Int { Int((points * emuPerPoint).rounded()) }

	/// Relationship type URIs.
	enum Rel {
		private static let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
		static let officeDocument = base + "officeDocument"
		static let coreProperties = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
		static let extendedProperties = base + "extended-properties"
		static let styles = base + "styles"
		static let numbering = base + "numbering"
		static let settings = base + "settings"
		static let fontTable = base + "fontTable"
		static let comments = base + "comments"
		static let image = base + "image"
		static let theme = base + "theme"
		static let slideMaster = base + "slideMaster"
		static let slideLayout = base + "slideLayout"
		static let slide = base + "slide"
		static let notesMaster = base + "notesMaster"
		static let notesSlide = base + "notesSlide"
		static let presProps = base + "presProps"
		static let viewProps = base + "viewProps"
		static let tableStyles = base + "tableStyles"
	}

	/// Content types for the parts the renderers write.
	enum ContentType {
		private static let office = "application/vnd.openxmlformats-officedocument."
		static let relationships = "application/vnd.openxmlformats-package.relationships+xml"
		static let xml = "application/xml"
		static let coreProperties = "application/vnd.openxmlformats-package.core-properties+xml"
		static let extendedProperties = office + "extended-properties+xml"
		static let wordDocument = office + "wordprocessingml.document.main+xml"
		static let wordStyles = office + "wordprocessingml.styles+xml"
		static let wordNumbering = office + "wordprocessingml.numbering+xml"
		static let wordSettings = office + "wordprocessingml.settings+xml"
		static let wordFontTable = office + "wordprocessingml.fontTable+xml"
		static let wordComments = office + "wordprocessingml.comments+xml"
		static let presentation = office + "presentationml.presentation.main+xml"
		static let slideMaster = office + "presentationml.slideMaster+xml"
		static let slideLayout = office + "presentationml.slideLayout+xml"
		static let slide = office + "presentationml.slide+xml"
		static let notesMaster = office + "presentationml.notesMaster+xml"
		static let notesSlide = office + "presentationml.notesSlide+xml"
		static let presProps = office + "presentationml.presProps+xml"
		static let viewProps = office + "presentationml.viewProps+xml"
		static let tableStyles = office + "presentationml.tableStyles+xml"
		static let theme = office + "theme+xml"
	}

	/// Builder for the `[Content_Types].xml` part.
	struct ContentTypes {
		private var defaults: [(ext: String, type: String)] = [
			("rels", ContentType.relationships),
			("xml", ContentType.xml),
		]
		private var overrides: [(part: String, type: String)] = []

		/// Registers a default content type for a file extension (once).
		mutating func addDefault(extension ext: String, contentType: String) {
			guard !defaults.contains(where: { $0.ext == ext }) else { return }
			defaults.append((ext, contentType))
		}

		/// Registers an override for one part; `partName` has no leading slash.
		mutating func addOverride(_ partName: String, contentType: String) {
			overrides.append(("/" + partName, contentType))
		}

		/// The finished part.
		var xml: String {
			var out = declaration
			out += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
			for item in defaults {
				out += "<Default Extension=\"\(escape(item.ext))\" ContentType=\"\(escape(item.type))\"/>"
			}
			for item in overrides {
				out += "<Override PartName=\"\(escape(item.part))\" ContentType=\"\(escape(item.type))\"/>"
			}
			return out + "</Types>"
		}
	}

	/// Builder for one `.rels` part. Ids are `rId1`, `rId2`, … in insertion order.
	struct Relationships {
		private var items: [(id: String, type: String, target: String)] = []

		/// Adds a relationship and returns its id.
		@discardableResult
		mutating func add(type: String, target: String) -> String {
			let id = "rId\(items.count + 1)"
			items.append((id, type, target))
			return id
		}

		/// Whether no relationships were added.
		var isEmpty: Bool { items.isEmpty }

		/// The finished part.
		var xml: String {
			var out = declaration
			out += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
			for item in items {
				out += "<Relationship Id=\"\(item.id)\" Type=\"\(escape(item.type))\" Target=\"\(escape(item.target))\"/>"
			}
			return out + "</Relationships>"
		}
	}

	/// `_rels/.rels` pointing at the main part and the two property parts.
	static func packageRelationships(mainPart: String) -> String {
		var rels = Relationships()
		rels.add(type: Rel.officeDocument, target: mainPart)
		rels.add(type: Rel.coreProperties, target: "docProps/core.xml")
		rels.add(type: Rel.extendedProperties, target: "docProps/app.xml")
		return rels.xml
	}

	/// `docProps/core.xml` with title, creator and timestamps.
	static func coreProperties(title: String, author: String, date: Date) -> String {
		let stamp = timestamp(date)
		return declaration
			+ "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\""
			+ " xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\""
			+ " xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
			+ "<dc:title>\(escape(title))</dc:title>"
			+ "<dc:creator>\(escape(author))</dc:creator>"
			+ "<cp:lastModifiedBy>\(escape(author))</cp:lastModifiedBy>"
			+ "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created>"
			+ "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:modified>"
			+ "</cp:coreProperties>"
	}

	/// `docProps/app.xml`; `extra` is appended inside `Properties` (e.g. `<Slides>3</Slides>`).
	static func appProperties(extra: String = "") -> String {
		declaration
			+ "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\""
			+ " xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
			+ "<Application>Rescriva</Application>\(extra)<DocSecurity>0</DocSecurity>"
			+ "<ScaleCrop>false</ScaleCrop><LinksUpToDate>false</LinksUpToDate>"
			+ "<SharedDoc>false</SharedDoc><HyperlinksChanged>false</HyperlinksChanged>"
			+ "</Properties>"
	}
}

// MARK: - Image sniffing

/// The raster formats the Office renderers embed.
enum RescrivaImageFormat: Equatable {
	case png, jpeg

	/// File extension used for the media part.
	var fileExtension: String { self == .png ? "png" : "jpeg" }

	/// MIME type registered in `[Content_Types].xml`.
	var contentType: String { self == .png ? "image/png" : "image/jpeg" }
}

/// Format and pixel size of an image, read from its header bytes (PNG `IHDR`,
/// JPEG `SOFn`) so no image framework is needed. EXIF orientation is ignored.
struct RescrivaImageInfo: Equatable {
	let format: RescrivaImageFormat
	let pixelWidth: Int
	let pixelHeight: Int

	/// Width / height.
	var aspect: Double { Double(pixelWidth) / Double(pixelHeight) }

	init(format: RescrivaImageFormat, pixelWidth: Int, pixelHeight: Int) {
		self.format = format
		self.pixelWidth = pixelWidth
		self.pixelHeight = pixelHeight
	}

	/// Sniffs `data`; nil when it is neither a readable PNG nor a readable JPEG.
	init?(data: Data) {
		let bytes = ByteReader(data: data)
		if let size = Self.pngSize(bytes) {
			self.init(format: .png, pixelWidth: size.width, pixelHeight: size.height)
		} else if let size = Self.jpegSize(bytes) {
			self.init(format: .jpeg, pixelWidth: size.width, pixelHeight: size.height)
		} else {
			return nil
		}
	}

	/// Bounds-checked big-endian reads over `Data` of any start index.
	private struct ByteReader {
		let data: Data

		var count: Int { data.count }

		func byte(_ offset: Int) -> Int? {
			guard offset >= 0, offset < data.count else { return nil }
			return Int(data[data.startIndex + offset])
		}

		func uint16(_ offset: Int) -> Int? {
			guard let high = byte(offset), let low = byte(offset + 1) else { return nil }
			return high << 8 | low
		}

		func uint32(_ offset: Int) -> Int? {
			guard let high = uint16(offset), let low = uint16(offset + 2) else { return nil }
			return high << 16 | low
		}
	}

	private static func pngSize(_ bytes: ByteReader) -> (width: Int, height: Int)? {
		let signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
		for (offset, expected) in signature.enumerated() where bytes.byte(offset) != expected {
			return nil
		}
		// IHDR is always the first chunk: length(4) "IHDR"(4) width(4) height(4).
		guard bytes.uint32(12) == 0x4948_4452,
			  let width = bytes.uint32(16), let height = bytes.uint32(20),
			  width > 0, height > 0 else { return nil }
		return (width, height)
	}

	private static func jpegSize(_ bytes: ByteReader) -> (width: Int, height: Int)? {
		guard bytes.byte(0) == 0xFF, bytes.byte(1) == 0xD8 else { return nil }
		var offset = 2
		// Every iteration advances `offset` by at least one byte, so the loop
		// ends within `count` iterations.
		while offset + 3 < bytes.count {
			guard bytes.byte(offset) == 0xFF, let marker = bytes.byte(offset + 1) else { return nil }
			if marker == 0xFF {
				offset += 1
				continue
			}
			offset += 2
			if marker == 0x01 || (0xD0...0xD8).contains(marker) { continue }
			if marker == 0xD9 || marker == 0xDA { return nil }
			guard let length = bytes.uint16(offset), length >= 2 else { return nil }
			let isStartOfFrame = (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
			if isStartOfFrame {
				guard let height = bytes.uint16(offset + 3), let width = bytes.uint16(offset + 5),
					  width > 0, height > 0 else { return nil }
				return (width, height)
			}
			offset += length
		}
		return nil
	}
}
