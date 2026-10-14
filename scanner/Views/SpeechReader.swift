//
//  SpeechReader.swift
//  Rescriva (fork of Open Scanner)
//
//  Reads a line aloud for the page screen's Speak button, in a voice for the
//  line's own language, with other audio ducked while it speaks. Replaces
//  AppState's shared synthesizer, whose `isSpeaking` was read on the main
//  thread: that waited on the synthesizer's lower-priority queue (Xcode's
//  hang-risk warning), and SwiftUI never saw it change.
//

import AVFoundation
import NaturalLanguage
import Observation

/// Speaks one piece of text at a time. The page screen owns one and stops it when you leave.
///
/// `isSpeaking` follows the synthesizer's start, finish and cancel callbacks, so a view reading it
/// redraws when speech ends. The synthesizer's own `isSpeaking` is never read: that waits on its
/// lower-priority queue.
@MainActor
@Observable
final class SpeechReader {
	/// True from when speech starts until it finishes or is stopped.
	private(set) var isSpeaking = false

	/// Made the first time something is spoken, so a page screen that never speaks doesn't start
	/// the speech service.
	@ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
	@ObservationIgnored private let callbacks = SpeechCallbacks()
	/// The utterance being spoken; callbacks for any other are stale.
	@ObservationIgnored private var current: AVSpeechUtterance?
	/// True while this reader has the audio session active.
	@ObservationIgnored private var holdsAudio = false

	/// Stops what's playing and speaks `text`. Blank text just stops.
	func speak(_ text: String) {
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			stop()
			return
		}
		let synthesizer = preparedSynthesizer()
		// False only when nothing was playing. The cut utterance's cancel callback is stale.
		_ = synthesizer.stopSpeaking(at: .immediate)
		let utterance = AVSpeechUtterance(string: text)
		utterance.voice = Self.voice(for: text)
		current = utterance
		claimAudio()
		synthesizer.speak(utterance)
	}

	/// Stops at once and gives the audio session back. Does nothing when nothing is playing.
	func stop() {
		// False only when nothing was playing.
		_ = synthesizer?.stopSpeaking(at: .immediate)
		current = nil
		isSpeaking = false
		releaseAudio()
	}

	/// The language to read `text` in, as a BCP-47 code: its dominant language, in `preferred`'s
	/// regional form when that's the same language ("en-US" rather than "en"), or `preferred`
	/// itself when no language can be told, as for empty text or a number.
	nonisolated static func language(for text: String, preferred: String) -> String {
		guard let detected = NLLanguageRecognizer.dominantLanguage(for: text), detected != .undetermined else {
			return preferred
		}
		let code = detected.rawValue
		let sameLanguage = Locale.Language(identifier: code).languageCode == Locale.Language(identifier: preferred).languageCode
		return sameLanguage ? preferred : code
	}

	/// A voice for `text`'s language, else one for the device's language, else nil (the system's
	/// default voice).
	private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
		let preferred = AVSpeechSynthesisVoice.currentLanguageCode()
		return AVSpeechSynthesisVoice(language: language(for: text, preferred: preferred))
			?? AVSpeechSynthesisVoice(language: preferred)
	}

	private func preparedSynthesizer() -> AVSpeechSynthesizer {
		if let synthesizer { return synthesizer }
		let made = AVSpeechSynthesizer()
		callbacks.reader = self
		made.delegate = callbacks
		synthesizer = made
		return made
	}

	// MARK: Callbacks

	fileprivate func started(_ utterance: AVSpeechUtterance) {
		guard utterance === current else { return }
		isSpeaking = true
	}

	fileprivate func ended(_ utterance: AVSpeechUtterance) {
		guard utterance === current else { return }
		current = nil
		isSpeaking = false
		releaseAudio()
	}

	// MARK: Audio session

	/// Activates the audio session for speech: it plays with the ringer off, and other audio ducks
	/// under it.
	private func claimAudio() {
		guard !holdsAudio else { return }
		let session = AVAudioSession.sharedInstance()
		do {
			try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
			try session.setActive(true)
			holdsAudio = true
		} catch {
			Log.app.error("Couldn't set up audio for speech: \(error)")
		}
	}

	/// Deactivates the audio session, so ducked audio comes back up.
	private func releaseAudio() {
		guard holdsAudio else { return }
		holdsAudio = false
		do {
			try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
		} catch {
			Log.app.error("Couldn't release audio after speech: \(error)")
		}
	}
}

/// Hands the synthesizer's callbacks, which arrive on its own queue, to its reader on the main
/// queue. The utterance goes along only to be compared by identity there (`===`), never read, so
/// passing it across is safe although AVSpeechUtterance isn't Sendable.
@MainActor
private final class SpeechCallbacks: NSObject, AVSpeechSynthesizerDelegate {
	weak var reader: SpeechReader?

	nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
		nonisolated(unsafe) let utterance = utterance
		DispatchQueue.main.async { [weak self] in self?.reader?.started(utterance) }
	}

	nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
		nonisolated(unsafe) let utterance = utterance
		DispatchQueue.main.async { [weak self] in self?.reader?.ended(utterance) }
	}

	nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
		nonisolated(unsafe) let utterance = utterance
		DispatchQueue.main.async { [weak self] in self?.reader?.ended(utterance) }
	}
}
