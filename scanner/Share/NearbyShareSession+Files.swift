//
//  NearbyShareSession+Files.swift
//  Rescriva (fork of Open Scanner)
//
//  The files behind a Share Nearby session. What's shared is copied into its own folder first,
//  so a page always downloads a fixed file:
//
//      tmp/NearbyShare/<session>/<document id>/<name>   deleted when the session stops
//      tmp/NearbyShareReceived/<uuid>/<name>             one upload, deleted once it's imported
//
//  Received files live outside the session's folder, so an import that finishes after the
//  session stops (the app went to the background) still has its file.
//

import CoreData
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A shared document's file, ready to send.
struct NearbySharePreparedFile: Equatable {
	let url: URL
	let name: String
	let size: Int64
	/// Its MIME type, for the page.
	let type: String
}

enum NearbyShareFileError: LocalizedError {
	case missing
	case unreadable

	var errorDescription: String? {
		switch self {
		case .missing: return String(localized: "It isn't in the Library any more.")
		case .unreadable: return String(localized: "Rescriva couldn't read it.")
		}
	}
}

@MainActor
enum NearbyShareFiles {
	static func sessionFolder(_ session: String) -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("NearbyShare", isDirectory: true)
			.appendingPathComponent(session, isDirectory: true)
	}

	/// A fresh folder for one upload.
	static func receivedFolder() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("NearbyShareReceived", isDirectory: true)
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
	}

	/// Deletes `url` if it's there.
	static func remove(_ url: URL?) {
		guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
		do {
			try FileManager.default.removeItem(at: url)
		} catch {
			print("Rescriva: Share Nearby couldn't delete \(url.lastPathComponent): \(error)")
		}
	}

	/// The folder `ExportService.makeFile` made for `url` (tmp/Exports/<uuid>/), or nil when `url`
	/// isn't one of its files.
	nonisolated static func exportFolder(of url: URL, temporaryDirectory: URL) -> URL? {
		guard url.isFileURL else { return nil }
		let exports = temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
			.standardizedFileURL.resolvingSymlinksInPath()
		let folder = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
		guard UUID(uuidString: folder.lastPathComponent) != nil,
			  folder.deletingLastPathComponent().path == exports.path else { return nil }
		return folder
	}

	/// Deletes the export folders behind `items`' files, once the Share Nearby screen they were
	/// handed to has closed. A session only shares its own copy, so nothing else needs them.
	static func removeExports(of items: [NearbyShareItem]) {
		let temporary = FileManager.default.temporaryDirectory
		for case .file(let url, _) in items {
			remove(exportFolder(of: url, temporaryDirectory: temporary))
		}
	}

	/// The name to show while the file is being made.
	static func provisionalName(for item: NearbyShareItem, library: PDFLibrary) -> String {
		switch item {
		case .scan(let scan):
			return ExportService.fileName(for: scan, format: .pdf)
		case .pdf(let id):
			let title = library.item(id)?.title ?? String(localized: "PDF")
			return NearbyShareInput.fileName(title, fallback: "PDF") + ".pdf"
		case .file(let url, let name):
			return NearbyShareInput.fileName(name, fallback: url.lastPathComponent)
		}
	}

	/// The message a document shows when it couldn't be made.
	static func problem(_ error: Error) -> String {
		if let error = error as? NearbyShareFileError, let text = error.errorDescription { return text }
		return String(localized: "Rescriva couldn't get it ready to share.")
	}

	// MARK: Preparing

	/// Makes `item`'s file inside `folder` (created here, and removed again if this fails).
	static func prepare(_ item: NearbyShareItem, into folder: URL,
						library: PDFLibrary) async -> Result<NearbySharePreparedFile, Error> {
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			let url: URL
			switch item {
			case .scan(let scan): url = try await exportScan(scan, into: folder)
			case .pdf(let id): url = try await copyPDF(id, into: folder, library: library)
			case .file(let source, let name): url = try await copyFile(source, named: name, into: folder)
			}
			return .success(try describe(url))
		} catch {
			remove(folder)
			return .failure(error)
		}
	}

	/// A scan as a searchable PDF, with its notes.
	private static func exportScan(_ scan: Scan, into folder: URL) async throws -> URL {
		guard !scan.isDeleted, scan.managedObjectContext != nil else { throw NearbyShareFileError.missing }
		let exported = try await ExportService.makeFile(for: scan, format: .pdf, includeNotes: true)
		defer { remove(exported.deletingLastPathComponent()) }
		let destination = folder.appendingPathComponent(exported.lastPathComponent)
		try FileManager.default.moveItem(at: exported, to: destination)
		return destination
	}

	/// A PDF Files item as it is now, once any save under way has finished.
	private static func copyPDF(_ id: UUID, into folder: URL, library: PDFLibrary) async throws -> URL {
		await library.waitForSave(of: id)
		guard let item = library.item(id) else { throw NearbyShareFileError.missing }
		let name = NearbyShareInput.fileName(item.title, fallback: "PDF") + ".pdf"
		let destination = folder.appendingPathComponent(name)
		try await copyOffMain(library.currentURL(for: item), to: destination)
		return destination
	}

	private static func copyFile(_ source: URL, named name: String, into folder: URL) async throws -> URL {
		let destination = folder.appendingPathComponent(NearbyShareInput.fileName(name, fallback: source.lastPathComponent))
		let scoped = source.startAccessingSecurityScopedResource()
		defer { if scoped { source.stopAccessingSecurityScopedResource() } }
		try await copyOffMain(source, to: destination)
		return destination
	}

	private static func copyOffMain(_ source: URL, to destination: URL) async throws {
		try await Task.detached(priority: .userInitiated) {
			try FileManager.default.copyItem(at: source, to: destination)
		}.value
	}

	private static func describe(_ url: URL) throws -> NearbySharePreparedFile {
		guard let size = size(of: url) else { throw NearbyShareFileError.unreadable }
		return NearbySharePreparedFile(url: url, name: url.lastPathComponent, size: size, type: mimeType(of: url))
	}

	static func size(of url: URL) -> Int64? {
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
			  let size = attributes[.size] as? NSNumber else { return nil }
		return size.int64Value
	}

	static func mimeType(of url: URL) -> String {
		UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
	}

	// MARK: Receiving

	/// Brings a received file into the Library: a PDF into PDF Files (titled with its name), an
	/// image as a new scan. False when it won't open.
	static func importReceived(_ url: URL, name: String, type: String, library: PDFLibrary,
							   context: NSManagedObjectContext) async -> Bool {
		if type == "application/pdf" {
			do {
				_ = try await library.importPDF(at: url, title: NearbyShareInput.title(fromFileName: name))
				return true
			} catch {
				print("Rescriva: Share Nearby couldn't import a received PDF: \(error)")
				return false
			}
		}
		let maxSide = maxImageSide
		let decoded = await Task.detached(priority: .userInitiated) {
			NearbyShareFiles.image(at: url, maxSide: maxSide)
		}.value
		guard let image = decoded else {
			print("Rescriva: Share Nearby received an image that won't open")
			return false
		}
		return await PhotoImport.scan(from: [image], in: context) != nil
	}

	/// A received picture's longest side once it's scaled down: a phone camera's full size.
	static let maxImageSide = 4_096
	/// Pictures with more pixels than this aren't decoded at all.
	nonisolated static let maxImagePixels = 200_000_000

	/// The picture at `url`, upright and scaled down to at most `maxSide` pixels on its longest
	/// side, read straight from the file without holding all of it in memory. Nil when it won't
	/// open or is absurdly large. Runs on any thread.
	nonisolated static func image(at url: URL, maxSide: Int) -> UIImage? {
		let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
		guard maxSide > 0, let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
			  CGImageSourceGetCount(source) > 0 else { return nil }
		guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
			  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
			  width > 0, height > 0, width <= maxImagePixels / height else { return nil }
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,
			kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(width, height)),
		]
		guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
		return UIImage(cgImage: image)
	}
}

/// One upload a page offered: waiting for Accept or Decline, then written chunk by chunk.
@MainActor
final class NearbyShareUpload {
	let offerID: String
	let xfer: String
	let name: String
	let size: Int64
	let type: String
	/// Its row in Activity, once accepted.
	var transferID: UUID?
	private(set) var received: Int64 = 0
	private(set) var url: URL?
	private var handle: FileHandle?

	var isReceiving: Bool { handle != nil }

	init(offerID: String, xfer: String, name: String, size: Int64, type: String) {
		self.offerID = offerID
		self.xfer = xfer
		self.name = name
		self.size = size
		self.type = type
	}

	/// Makes the file the bytes go into. False if it can't.
	func open() -> Bool {
		guard handle == nil else { return true }
		let folder = NearbyShareFiles.receivedFolder()
		let file = folder.appendingPathComponent(name)
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
				NearbyShareFiles.remove(folder)
				return false
			}
			handle = try FileHandle(forWritingTo: file)
			url = file
			return true
		} catch {
			print("Rescriva: Share Nearby couldn't make a file for an upload: \(error)")
			NearbyShareFiles.remove(folder)
			return false
		}
	}

	/// Appends a chunk. False when it would run past the size the page offered, or won't write.
	func write(_ data: Data) -> Bool {
		guard let handle, received + Int64(data.count) <= size else { return false }
		do {
			try handle.write(contentsOf: data)
		} catch {
			print("Rescriva: Share Nearby couldn't write an upload: \(error)")
			return false
		}
		received += Int64(data.count)
		return true
	}

	/// Closes the file and returns it when every byte arrived. Otherwise it's deleted, and nil.
	func finish() -> URL? {
		guard let handle, let url else { return nil }
		self.handle = nil
		do {
			try handle.close()
		} catch {
			print("Rescriva: Share Nearby couldn't finish an upload: \(error)")
			discard()
			return nil
		}
		guard received == size else {
			discard()
			return nil
		}
		return url
	}

	/// Stops writing and deletes what arrived.
	func discard() {
		if let handle {
			try? handle.close()
		}
		handle = nil
		NearbyShareFiles.remove(url?.deletingLastPathComponent())
		url = nil
	}
}
