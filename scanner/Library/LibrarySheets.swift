//
//  LibrarySheets.swift
//  Rescriva (fork of Open Scanner)
//
//  The library's sheets: move scans to a folder, tag them, create or edit
//  a folder (name, colour, symbol), and move a folder under another.
//

import CoreData
import SwiftUI

/// Shows the sheet a `LibrarySheet` names.
struct LibrarySheetView: View {
	let sheet: LibrarySheet
	let onFinished: () -> Void

	var body: some View {
		Group {
			switch sheet {
			case .move(let scans): MoveScansSheet(scans: scans, onFinished: onFinished)
			case .tags(let scans): TagScansSheet(scans: scans)
			case .newFolder(let parent): FolderEditorSheet(folder: nil, parent: parent)
			case .editFolder(let folder): FolderEditorSheet(folder: folder, parent: folder.parent)
			case .moveFolder(let folder): MoveFolderSheet(folder: folder)
			case .newSmartFolder: SmartFolderEditorSheet(smart: nil)
			case .editSmartFolder(let smart): SmartFolderEditorSheet(smart: smart)
			}
		}
		.presentationDragIndicator(.visible)
		.presentationCornerRadius(RescrivaRadius.large)
		.presentationBackground(Color.vellum)
	}
}

/// A folder in a picker list, indented by depth.
struct FolderPickerRow: View {
	let title: String
	let symbol: String
	let tint: Color
	var depth = 0
	var isCurrent = false
	var isEnabled = true

	var body: some View {
		HStack(spacing: 12) {
			Glyph(symbol, size: 17)
				.foregroundStyle(tint)
				.frame(width: 26)
			Text(title)
				.font(RescrivaFont.ui(16))
				.foregroundStyle(.carbon)
				.lineLimit(1)
			Spacer(minLength: 0)
			if isCurrent {
				Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(.ink)
			}
		}
		.padding(.leading, CGFloat(depth) * 18)
		.padding(.vertical, 11)
		.padding(.horizontal, 14)
		.contentShape(Rectangle())
		.opacity(isEnabled ? 1 : 0.35)
	}
}

/// "Move to…": the folder tree, plus the top level and a new folder.
struct MoveScansSheet: View {
	@Environment(\.managedObjectContext) private var context
	@Environment(\.dismiss) private var dismiss
	let scans: [Scan]
	let onFinished: () -> Void
	@State private var creatingFolder = false
	@State private var newName = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SheetHeader(title: scans.count == 1 ? String(localized: "Move to Folder") : String(localized: "Move \(scans.count) Scans"),
						subtitle: scans.count == 1 ? scans.first?.displayTitle : nil,
						trailing: (String(localized: "Cancel"), { dismiss() }))
			ScrollView {
				VStack(spacing: 0) {
					pickerButton(folder: nil) {
						FolderPickerRow(title: String(localized: "No Folder"), symbol: "tray.full", tint: .graphite,
										isCurrent: scans.allSatisfy { $0.folder == nil })
					}
					ForEach(Library.tree(in: context)) { row in
						pickerButton(folder: row.folder) {
							FolderPickerRow(title: row.folder.displayName, symbol: row.folder.symbolName, tint: row.folder.tint,
											depth: row.depth, isCurrent: scans.allSatisfy { $0.folder == row.folder })
						}
					}
				}
				.background(Color.stock, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
			}
			Button {
				creatingFolder = true
			} label: {
				Label("New Folder", systemImage: "folder.badge.plus")
					.font(RescrivaFont.ui(15, weight: .medium))
					.foregroundStyle(.ink)
			}
		}
		.padding(20)
		.presentationDetents([.medium, .large])
		.alert("New folder", isPresented: $creatingFolder) {
			TextField("Name", text: $newName)
			Button("Create and Move") { createAndMove() }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("The scans move into it.")
		}
	}

	private func pickerButton<Label: View>(folder: ScanFolder?, @ViewBuilder label: () -> Label) -> some View {
		Button {
			withAnimation(RescrivaMotion.ui) { Library.move(scans, to: folder, in: context) }
			onFinished()
			dismiss()
		} label: {
			label()
		}
		.buttonStyle(.plain)
	}

	private func createAndMove() {
		let folder = Library.createFolder(named: newName, symbol: "folder", color: .ink, parent: nil, in: context)
		Library.move(scans, to: folder, in: context)
		onFinished()
		dismiss()
	}
}

/// "Tags": tick tags on or off for every scan given, or make a new one.
struct TagScansSheet: View {
	@Environment(\.managedObjectContext) private var context
	@Environment(\.dismiss) private var dismiss
	@FetchRequest(sortDescriptors: [SortDescriptor(\ScanTag.name)]) private var tags: FetchedResults<ScanTag>
	let scans: [Scan]
	@State private var draft = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SheetHeader(title: String(localized: "Tags"),
						subtitle: scans.count == 1 ? scans.first?.displayTitle : String(localized: "\(scans.count) scans"),
						trailing: (String(localized: "Done"), { dismiss() }))
			HStack(spacing: 8) {
				Text("#").font(RescrivaFont.ui(16, weight: .medium)).foregroundStyle(.ink)
				TextField("New tag", text: $draft)
					.font(RescrivaFont.ui(16))
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.submitLabel(.done)
					.onSubmit { addDraft() }
				Button("Add") { addDraft() }
					.font(RescrivaFont.ui(14, weight: .medium))
					.foregroundStyle(.ink)
					.disabled(Library.tagName(draft) == nil)
			}
			.padding(.horizontal, 14)
			.frame(height: 46)
			.background(Color.stock, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			ScrollView {
				VStack(spacing: 0) {
					ForEach(tags, id: \.objectID) { tag in tagRow(tag) }
				}
				.background(Color.stock, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
			}
			if tags.isEmpty {
				Text("No tags yet. Type one above, like exam or todo.")
					.font(RescrivaFont.note(15))
					.foregroundStyle(.graphite)
			}
		}
		.padding(20)
		.presentationDetents([.medium, .large])
	}

	private func tagRow(_ tag: ScanTag) -> some View {
		let count = scans.filter { $0.tagList.contains(tag) }.count
		return Button {
			Library.setTag(tag, on: scans, to: count < scans.count, in: context)
		} label: {
			HStack {
				Text(tag.displayName).font(RescrivaFont.ui(16)).foregroundStyle(.carbon)
				Spacer()
				Glyph(count == scans.count ? "checkmark.circle.fill" : (count > 0 ? "minus.circle.fill" : "circle"), size: 20)
					.foregroundStyle(count > 0 ? Color.ink : Color.carbon.opacity(0.3))
			}
			.padding(.vertical, 11)
			.padding(.horizontal, 14)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(count == scans.count ? .isSelected : [])
	}

	private func addDraft() {
		guard let tag = Library.tag(named: draft, creating: true, in: context) else { return }
		Library.setTag(tag, on: scans, to: true, in: context)
		draft = ""
	}
}

/// New folder or edit folder: name, colour and symbol.
struct FolderEditorSheet: View {
	@Environment(\.managedObjectContext) private var context
	@Environment(\.dismiss) private var dismiss
	let folder: ScanFolder?
	let parent: ScanFolder?
	@State private var name: String
	@State private var color: FolderColor
	@State private var symbol: String

	init(folder: ScanFolder?, parent: ScanFolder?) {
		self.folder = folder
		self.parent = parent
		_name = State(initialValue: folder?.name ?? "")
		_color = State(initialValue: FolderColor.token(folder?.colorToken))
		_symbol = State(initialValue: folder?.symbolName ?? "folder")
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			SheetHeader(title: folder == nil ? String(localized: "New Folder") : String(localized: "Edit Folder"),
						subtitle: parent.map { String(localized: "Inside \($0.displayName)") },
						trailing: (String(localized: "Cancel"), { dismiss() }))
			HStack(spacing: 12) {
				Glyph(symbol, size: 22)
					.foregroundStyle(color.color)
					.frame(width: 44, height: 44)
					.background(color.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
				TextField("Folder name", text: $name)
					.font(RescrivaFont.ui(17))
					.submitLabel(.done)
					.onSubmit { save() }
			}
			.padding(12)
			.background(Color.stock, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
			FolderStylePicker(color: $color, symbol: $symbol)
			PrimaryButton(title: folder == nil ? "Create Folder" : "Save", height: 50) { save() }
		}
		.padding(20)
		.presentationDetents([.large])
	}

	private func save() {
		if let folder {
			Library.update(folder, name: name, symbol: symbol, color: color, in: context)
		} else {
			Library.createFolder(named: name, symbol: symbol, color: color, parent: parent, in: context)
		}
		dismiss()
	}
}

/// Colour swatches and a grid of symbols, shared by folders and smart folders.
struct FolderStylePicker: View {
	@Binding var color: FolderColor
	@Binding var symbol: String

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Colour").rescrivaSectionLabel()
			HStack(spacing: 10) {
				ForEach(FolderColor.allCases) { option in
					Button {
						color = option
					} label: {
						Circle()
							.fill(option.color)
							.frame(width: 30, height: 30)
							.padding(3)
							.overlay { Circle().strokeBorder(color == option ? Color.carbon : Color.clear, lineWidth: 2) }
					}
					.buttonStyle(PressScaleStyle())
					.accessibilityLabel(Text(option.name))
					.accessibilityAddTraits(color == option ? .isSelected : [])
				}
			}
			Text("Symbol").rescrivaSectionLabel()
			LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
				ForEach(FolderSymbol.all, id: \.self) { name in
					Button {
						symbol = name
					} label: {
						Glyph(name, size: 18)
							.foregroundStyle(symbol == name ? Color.vellum : color.color)
							.frame(maxWidth: .infinity)
							.frame(height: 42)
							.background(symbol == name ? color.color : Color.stock,
										in: RoundedRectangle(cornerRadius: 10, style: .continuous))
					}
					.buttonStyle(PressScaleStyle())
					.accessibilityLabel(Text(name.replacingOccurrences(of: ".", with: " ")))
					.accessibilityAddTraits(symbol == name ? .isSelected : [])
				}
			}
		}
	}
}

/// Moves a folder under another (or to the top level); targets that would
/// loop or go too deep are dimmed.
struct MoveFolderSheet: View {
	@Environment(\.managedObjectContext) private var context
	@Environment(\.dismiss) private var dismiss
	let folder: ScanFolder

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SheetHeader(title: String(localized: "Move Folder"), subtitle: folder.displayName,
						trailing: (String(localized: "Cancel"), { dismiss() }))
			ScrollView {
				VStack(spacing: 0) {
					target(nil, title: String(localized: "Top Level"), symbol: "square.stack", tint: .graphite, depth: 0)
					ForEach(Library.tree(in: context)) { row in
						target(row.folder, title: row.folder.displayName, symbol: row.folder.symbolName, tint: row.folder.tint, depth: row.depth)
					}
				}
				.background(Color.stock, in: RoundedRectangle(cornerRadius: RescrivaRadius.medium, style: .continuous))
			}
		}
		.padding(20)
		.presentationDetents([.medium, .large])
	}

	private func target(_ parent: ScanFolder?, title: String, symbol: String, tint: Color, depth: Int) -> some View {
		let allowed = parent != folder && Library.canMove(folder, into: parent)
		return Button {
			withAnimation(RescrivaMotion.ui) { _ = Library.move(folder, into: parent, in: context) }
			dismiss()
		} label: {
			FolderPickerRow(title: title, symbol: symbol, tint: tint, depth: depth, isCurrent: folder.parent == parent, isEnabled: allowed)
		}
		.buttonStyle(.plain)
		.disabled(!allowed)
	}
}
