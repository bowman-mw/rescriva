//
//  AnnotationStore.swift
//  Rescriva (fork of Open Scanner)
//
//  Keeps each page's marks in a small JSON file named for the page's id
//  (Application Support/Annotations/<id>.json), next to the library rather
//  than inside it, so annotating never touches the page image or the
//  Core Data model. The files stay on this iPhone; they don't sync through
//  iCloud with the rest of the library.
//

import Foundation
import Observation

@MainActor
@Observable
final class AnnotationStore {
	static let shared = AnnotationStore(folder: AnnotationStore.defaultFolder)

	/// Bumped on every save, so views that read marks redraw.
	private(set) var revision = 0

	@ObservationIgnored private let folder: URL
	@ObservationIgnored private var cache: [UUID: [PageMark]] = [:]

	init(folder: URL) {
		self.folder = folder
	}

	static var defaultFolder: URL {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		return support.appendingPathComponent("Annotations", isDirectory: true)
	}

	/// The page's marks (empty when it has none, or no id yet).
	func marks(for pageID: UUID?) -> [PageMark] {
		// Reading `revision` ties the caller to future saves.
		guard revision >= 0, let pageID else { return [] }
		if let cached = cache[pageID] {
			return cached
		}
		let loaded = load(pageID)
		cache[pageID] = loaded
		return loaded
	}

	/// Replaces the page's marks; an empty list removes its file.
	func save(_ marks: [PageMark], for pageID: UUID) throws {
		let url = fileURL(for: pageID)
		if marks.isEmpty {
			if FileManager.default.fileExists(atPath: url.path) {
				try FileManager.default.removeItem(at: url)
			}
		} else {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			let data = try JSONEncoder.rescriva.encode(PageAnnotations(marks: marks))
			try data.write(to: url, options: .atomic)
		}
		cache[pageID] = marks
		revision += 1
	}

	private func load(_ pageID: UUID) -> [PageMark] {
		let url = fileURL(for: pageID)
		guard FileManager.default.fileExists(atPath: url.path) else { return [] }
		do {
			let data = try Data(contentsOf: url)
			return try JSONDecoder.rescriva.decode(PageAnnotations.self, from: data).marks
		} catch {
			Log.library.error("Couldn't read the annotations for page \(pageID): \(error)")
			return []
		}
	}

	private func fileURL(for pageID: UUID) -> URL {
		folder.appendingPathComponent(pageID.uuidString).appendingPathExtension("json")
	}
}

extension ScanCapture {
	/// This page's annotations.
	@MainActor
	var pageMarks: [PageMark] {
		AnnotationStore.shared.marks(for: id)
	}
}
