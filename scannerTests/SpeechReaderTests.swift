//
//  SpeechReaderTests.swift
//  Rescriva (fork of Open Scanner)
//
//  The page screen's Speak button: which language a line is read in. The
//  voices themselves, and the audio session, need a device.
//

import XCTest
@testable import scanner

final class SpeechReaderTests: XCTestCase {
	private let english = "The quick brown fox jumps over the lazy dog near the river bank."
	private let french = "Le renard brun rapide saute par-dessus le chien paresseux près de la rivière."
	private let german = "Der schnelle braune Fuchs springt über den faulen Hund am Flussufer."

	func testEnglishIsReadInEnglish() {
		XCTAssertEqual(SpeechReader.language(for: english, preferred: "fr-FR"), "en")
	}

	func testFrenchIsReadInFrench() {
		XCTAssertEqual(SpeechReader.language(for: french, preferred: "en-US"), "fr")
	}

	func testGermanIsReadInGerman() {
		XCTAssertEqual(SpeechReader.language(for: german, preferred: "en-US"), "de")
	}

	func testTheDevicesRegionIsKeptForItsOwnLanguage() {
		XCTAssertEqual(SpeechReader.language(for: english, preferred: "en-GB"), "en-GB")
		XCTAssertEqual(SpeechReader.language(for: french, preferred: "fr-CA"), "fr-CA")
	}

	func testTextWithNoLanguageFallsBackToTheDevicesLanguage() {
		XCTAssertEqual(SpeechReader.language(for: "", preferred: "en-US"), "en-US")
		XCTAssertEqual(SpeechReader.language(for: "   \n", preferred: "de-DE"), "de-DE")
		XCTAssertEqual(SpeechReader.language(for: "12.50", preferred: "fr-FR"), "fr-FR")
	}
}
