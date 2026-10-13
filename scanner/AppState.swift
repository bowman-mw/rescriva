//
//  AppState.swift
//  Open Scanner
//
//  Created by Slaven Radic on 2024-09-01.
//

import Foundation
import AppIntents
import CoreData
import SwiftUI

enum ViewState: String {
	case Home, Page, About
}

extension ViewState: AppEnum {
	static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scanner mode"

	static let caseDisplayRepresentations: [ViewState: DisplayRepresentation] = [
		.Home: "Scan List",
		.Page: "Scan Now",
		.About: "Rescriva settings",
	]
}

class AppState: ObservableObject {
	
	public static let shared = AppState()
	
	@Published var viewState = ViewState.Home
	
	@Published var openScan: Scan?
	@Published var openRecognizedItem: ScanRecognizedItem?
	
	var lastScanIndex: Int {
		
		let request = Scan.fetchRequest()
		do {
			let scans = try PersistenceController.shared.container.viewContext.fetch(request)
			return scans.count - 1
		} catch {
			print("Fetch failed")
		}
		
		return 0
	}
}
