//
//  CaptureCamera.swift
//  Rescriva (fork of Open Scanner)
//
//  The AVFoundation camera behind the Capture screen: live page detection, steadiness and
//  auto-capture, and full-resolution stills that come back perspective-corrected and cleaned.
//

import AVFoundation
import CoreImage
import Observation
import QuartzCore
import UIKit
import Vision

// MARK: - CaptureCamera

/// The custom document camera behind Rescriva's Capture screen.
///
/// Main-actor, `@Observable` state for SwiftUI: the camera's `status`, the latest detected page
/// `quad`, and whether that page is being held steady. Every AVFoundation and Vision call runs off
/// the main actor inside a private `CapturePipeline`; results hop back to the main queue only when
/// something visible changed.
///
/// Typical use:
/// ```swift
/// @State private var camera = CaptureCamera()
/// …
/// CameraPreviewView(session: camera.session, quad: camera.quad, isSteady: camera.isSteady)
///     .task { await camera.start() }
///     .onDisappear { camera.stop() }
/// camera.onAutoCapture = { Task { let page = try await camera.capturePage() … } }
/// ```
///
/// On a device without a back camera (including the iOS Simulator) `start()` sets `.unavailable`
/// and touches no capture hardware.
@MainActor @Observable
final class CaptureCamera {

	/// The kind of surface being captured. Raw values are stored tokens: never rename them.
	typealias Mode = CaptureMode

	/// Lifecycle of the camera as the Capture screen should present it.
	enum Status: Equatable {
		/// Not started, or stopped.
		case idle
		/// No usable back camera (e.g. the iOS Simulator).
		case unavailable
		/// The user denied (or a policy restricts) camera access.
		case denied
		/// Frames are flowing and pages are being detected.
		case running
		/// The session failed to start or hit a runtime error; the message is for display.
		case failed(String)
	}

	/// Errors thrown by `capturePage()` and used internally by `start()`.
	enum CaptureError: LocalizedError {
		/// `capturePage()` was called while the camera was not running.
		case notRunning
		/// No back camera, or the session would not accept it.
		case unavailable
		/// AVFoundation reported a capture failure.
		case captureFailed(String)
		/// The still could not be decoded or rendered.
		case processingFailed

		var errorDescription: String? {
			switch self {
			case .notRunning:
				return "The camera isn't running."
			case .unavailable:
				return "No camera is available."
			case .captureFailed(let message):
				return message
			case .processingFailed:
				return "The photo couldn't be processed."
			}
		}
	}

	/// A second look under way: after a still that shows glare, the camera waits for the phone to
	/// slide somewhere that sees the glary part clean, takes another still there, and fuses them.
	struct SecondLook: Equatable {
		/// Which way to slide the phone, as seen on screen.
		var direction: PageDirection
		/// Stills of this page taken so far.
		var shots: Int
	}

	/// Where the camera is in its lifecycle.
	private(set) var status: Status = .idle
	/// True when the last page `capturePage()` returned was fused from a second look's stills.
	private(set) var lastPageWasFused = false
	/// The latest detected page in the upright video frame (see `PageQuad`), or nil when none.
	private(set) var quad: PageQuad?
	/// True while the page's corners have moved less than ~2% of the frame over the last ~0.6 s.
	private(set) var isSteady = false
	/// True while auto-capture would take the page in view once it is steady: false from a capture
	/// until the page moves away or leaves the frame.
	private(set) var awaitsCapture = true
	/// True while the live view shows glare on the page (debounced; only when `reducesGlare`).
	private(set) var showsGlare = false
	/// Set while `capturePage()` is waiting for the phone to move for another look at the page.
	private(set) var secondLook: SecondLook?

	/// Selects the cleanup recipe and the focus range (near for documents, unrestricted for boards).
	var mode: Mode = .document {
		didSet {
			guard mode != oldValue else { return }
			pipeline.setMode(mode)
		}
	}

	/// When true, `onAutoCapture` fires once each time a page is held steady.
	var autoCapture = true {
		didSet {
			guard autoCapture != oldValue else { return }
			pipeline.setAutoCapture(autoCapture)
		}
	}

	/// Document-mode cleanup: flatten uneven lighting and shadows.
	var removeShadows = true
	/// Whiteboard-mode cleanup: keep marker colours (false gives high-contrast grayscale).
	var keepMarkerColors = true
	/// Keep each page's original photo (Settings › Keep originals) so its crop can be fixed later.
	var keepsOriginal = true
	/// Settings › Reduce glare: watch the live view for glare and, when a still shows it, take a
	/// second look (see `SecondLook`) and fuse the stills with `GlareFusion`.
	var reducesGlare = true {
		didSet {
			guard reducesGlare != oldValue else { return }
			pipeline.setGlareCheck(reducesGlare)
			if !reducesGlare { showsGlare = false }
		}
	}

	/// Called on the main actor when auto-capture decides to take the page. The handler is
	/// expected to call `capturePage()`.
	@ObservationIgnored var onAutoCapture: (() -> Void)?

	/// The capture session, for `CameraPreviewView`. Configure it only through this class.
	let session: AVCaptureSession

	/// Extra stills a second look takes at most (so at most three stills per page).
	nonisolated static let maxExtraStills = 2
	/// How long a second look waits for the phone to move before keeping what it has.
	static let secondLookTimeout: Duration = .seconds(6)

	private let pipeline: CapturePipeline
	/// Width ÷ height of the upright video frame the published `quad` was measured in.
	@ObservationIgnored private var previewFrameAspect: CGFloat?
	@ObservationIgnored private var isStarting = false
	@ObservationIgnored private var wantsRunning = false
	/// The latest live glare map published (for a still whose own map shows nothing).
	@ObservationIgnored private var liveGlare: GlareMap?
	/// Counts second looks, so a signal from an earlier one is ignored.
	@ObservationIgnored private var lookGeneration = 0
	/// The suspended second look, resumed exactly once by `resumeLook(_:)`.
	@ObservationIgnored private var lookWaiter: CheckedContinuation<LookOutcome, Never>?
	@ObservationIgnored private var lookTimeout: Task<Void, Never>?

	/// How waiting for the next look of a page ended.
	private enum LookOutcome {
		/// The phone settled where the pending glare looks clean: take the next still.
		case ready
		/// The shutter was tapped during the hint: keep the page as it is.
		case done
		case timedOut
		case pageLost
		/// The camera stopped (the screen closed).
		case stopped
	}

	/// False when the device has no back wide-angle camera (e.g. the iOS Simulator).
	nonisolated static var isSupported: Bool {
		CapturePipeline.backCamera() != nil
	}

	init() {
		let session = AVCaptureSession()
		let pipeline = CapturePipeline(session: session)
		self.session = session
		self.pipeline = pipeline
		pipeline.onEvent = { [weak self] event in
			self?.handle(event)
		}
	}

	deinit {
		pipeline.stop()
	}

	/// Requests camera permission if needed, configures the session once, and starts it on a
	/// private serial queue. Sets `status` to `.running`, `.denied`, `.unavailable` or `.failed`.
	func start() async {
		guard !isStarting, status != .running else { return }
		wantsRunning = true
		guard Self.isSupported else {
			status = .unavailable
			return
		}
		isStarting = true
		defer { isStarting = false }
		guard await Self.requestVideoAccess() else {
			status = .denied
			return
		}
		do {
			try await pipeline.start(mode: mode, autoCapture: autoCapture, checksGlare: reducesGlare)
		} catch CaptureError.unavailable {
			status = .unavailable
			return
		} catch {
			status = .failed(error.localizedDescription)
			return
		}
		guard wantsRunning else {
			// stop() was called while the session was starting.
			pipeline.stop()
			return
		}
		status = .running
	}

	/// Stops the session (asynchronously, off the main actor) and clears the detection state.
	func stop() {
		wantsRunning = false
		resumeLook(.stopped)
		pipeline.stop()
		if status == .running {
			status = .idle
		}
		quad = nil
		isSteady = false
		showsGlare = false
		liveGlare = nil
	}

	/// Takes a full-resolution still and returns the cleaned page.
	///
	/// Page detection runs on the still itself; if it finds nothing, the latest preview quad is
	/// mapped onto the still; with neither, the whole frame is kept. The page is then
	/// perspective-corrected, limited to 2400 px wide and cleaned for the current `mode`. The
	/// returned image is upright (`.up`) at scale 1. It comes with the recipe that made it and,
	/// when `keepsOriginal`, the upright still staged for `OriginalStore`, so the page can be
	/// re-made later. Taking a page also re-arms auto-capture's cooldown, so a manual shot is not
	/// immediately followed by an automatic one. Throws `CancellationError` when the camera was
	/// stopped while the still was processed (the screen closed): that page is dropped, with its
	/// staged original.
	///
	/// With `reducesGlare`, when the live view showed glare as the shutter fired, the call stays
	/// open for a second look (placed by the still's own glare map, or the live one's when the
	/// still's shows none): `secondLook` asks the user to slide the phone, one or two more stills
	/// are taken as the glary part comes clear, and all of them are fused into the page. The first
	/// still stays the page's original and sets its crop.
	func capturePage() async throws -> CapturedPage {
		guard status == .running else { throw CaptureError.notRunning }
		lastPageWasFused = false
		let request = pageRequest()
		let glaryAtShutter = reducesGlare && showsGlare
		let shotQuad = quad
		let first = try await pipeline.captureStill(request, measuresGlare: reducesGlare)
		guard wantsRunning else { throw CancellationError() }
		var stills = [first]
		// The still's own map places the glare best; Smart HDR can tone a highlight down below the
		// check, though, and then the live view's map stands in.
		if glaryAtShutter, let map = [first.glare, liveGlare].compactMap({ $0 }).first(where: { !$0.isClear }) {
			stills += await secondLookStills(coverage: GlareCoverage(first: map), shotQuad: shotQuad, request: request)
		}
		guard wantsRunning else { throw CancellationError() }
		let still = try await pipeline.processPage(stills, request: request)
		// Nobody is left to save this page, so its original goes now rather than at the next launch.
		guard wantsRunning else {
			OriginalStore.shared.discardLater([still.original].compactMap { $0 })
			throw CancellationError()
		}
		lastPageWasFused = still.isFused
		let recipe = PageRecipe(quad: still.quad, mode: request.mode, rotation: 0,
								removeShadows: request.removeShadows, keepMarkerColors: request.keepMarkerColors)
		return CapturedPage(image: UIImage(cgImage: still.page, scale: 1, orientation: .up), original: still.original, recipe: recipe)
	}

	/// Ends a second look now and keeps the page with the stills taken so far (the shutter, tapped
	/// while the hint shows). Does nothing when no second look is waiting.
	func finishSecondLook() {
		resumeLook(.done)
	}

	private func pageRequest() -> CapturePipeline.PageRequest {
		CapturePipeline.PageRequest(
			mode: mode,
			removeShadows: removeShadows,
			keepMarkerColors: keepMarkerColors,
			keepsOriginal: keepsOriginal,
			fallbackQuad: quad,
			fallbackFrameAspect: previewFrameAspect
		)
	}

	/// The extra stills of a second look: shows the hint, waits for the pipeline to see the
	/// pending glare clean from a new spot, takes a still there, and repeats until the glare is
	/// covered, `maxExtraStills` are taken, or the look ends (timeout, shutter, page lost, stop).
	private func secondLookStills(coverage start: GlareCoverage, shotQuad: PageQuad?, request: CapturePipeline.PageRequest) async -> [CapturePipeline.RawStill] {
		var coverage = start
		var stills: [CapturePipeline.RawStill] = []
		var lastQuad = shotQuad
		let deadline = ContinuousClock.now + Self.secondLookTimeout
		defer {
			secondLook = nil
			pipeline.endSecondLook()
		}
		while stills.count < Self.maxExtraStills, wantsRunning, let move = coverage.suggestedMove {
			// The direction is fixed for each wait, so the hint never changes mid-move.
			let onScreen = (quad ?? lastQuad).map { move.onScreen(for: $0) } ?? move
			secondLook = SecondLook(direction: onScreen, shots: 1 + stills.count)
			lookGeneration += 1
			pipeline.beginSecondLook(SecondLookTrigger(coverage: coverage, lastStillQuad: lastQuad), generation: lookGeneration)
			guard await nextLook(until: deadline) == .ready, wantsRunning else { break }
			lastQuad = quad
			var followUp = request
			followUp.fallbackQuad = quad
			followUp.fallbackFrameAspect = previewFrameAspect
			guard let still = try? await pipeline.captureStill(followUp, measuresGlare: true) else { break }
			stills.append(still)
			if let map = still.glare {
				coverage.add(map)
			}
		}
		return stills
	}

	/// Suspends until the pipeline signals the next look, the shutter ends it, the page is lost,
	/// the camera stops, or `deadline` passes.
	private func nextLook(until deadline: ContinuousClock.Instant) async -> LookOutcome {
		await withCheckedContinuation { continuation in
			resumeLook(.stopped)  // Never strand an earlier waiter.
			lookWaiter = continuation
			lookTimeout = Task { [weak self] in
				try? await Task.sleep(until: deadline, clock: .continuous)
				guard !Task.isCancelled else { return }
				self?.resumeLook(.timedOut)
			}
		}
	}

	private func resumeLook(_ outcome: LookOutcome) {
		guard let waiter = lookWaiter else { return }
		lookWaiter = nil
		lookTimeout?.cancel()
		lookTimeout = nil
		waiter.resume(returning: outcome)
	}

	private func handle(_ event: CapturePipeline.Event) {
		switch event {
		case .detection(let update):
			// Accept frames that arrive while start() is still finishing (the pipeline does not
			// republish an unchanged quad), but drop stale ones queued before a stop().
			guard wantsRunning else { return }
			if quad != update.quad { quad = update.quad }
			if isSteady != update.isSteady { isSteady = update.isSteady }
			if awaitsCapture != update.isArmed { awaitsCapture = update.isArmed }
			let glary = reducesGlare && update.showsGlare
			if showsGlare != glary { showsGlare = glary }
			liveGlare = update.glare
			previewFrameAspect = update.frameAspect
			if let signal = update.secondLook, signal.generation == lookGeneration {
				switch signal.signal {
				case .ready: resumeLook(.ready)
				case .pageLost: resumeLook(.pageLost)
				case .waiting: break
				}
			}
			if update.autoCaptureFired, autoCapture {
				onAutoCapture?()
			}
		case .runtimeError(let message):
			guard wantsRunning else { return }
			status = .failed(message)
			resumeLook(.stopped)
			quad = nil
			isSteady = false
			showsGlare = false
		}
	}

	private nonisolated static func requestVideoAccess() async -> Bool {
		switch AVCaptureDevice.authorizationStatus(for: .video) {
		case .authorized:
			return true
		case .notDetermined:
			return await AVCaptureDevice.requestAccess(for: .video)
		default:
			return false
		}
	}
}

// MARK: - CapturePipeline

/// Owns the capture session's configuration, live frame analysis and still processing for
/// `CaptureCamera`.
///
/// Concurrency: all state is confined to one of three private serial queues, documented per
/// property. Session configuration and start/stop run on `sessionQueue` (`startRunning()` blocks);
/// video frames, Vision detection and the stability tracker run on `videoQueue`; still decoding,
/// detection and Core Image rendering run on `processingQueue`. `onEvent` is set once before the
/// session starts and is only ever invoked on the main queue. That confinement is what makes the
/// `@unchecked Sendable` conformance sound.
fileprivate final class CapturePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

	/// What `CaptureCamera` hands the pipeline for one still: the cleanup options and the preview
	/// state to fall back on.
	struct PageRequest {
		var mode: CaptureMode
		var removeShadows: Bool
		var keepMarkerColors: Bool
		/// Stage the upright still too, for `OriginalStore`.
		var keepsOriginal: Bool
		/// The latest preview quad (upright video-frame space), used if the still shows no page.
		var fallbackQuad: PageQuad?
		/// Width ÷ height of the video frame `fallbackQuad` was measured in.
		var fallbackFrameAspect: CGFloat?
	}

	/// One still as taken, before it is made into a page: the upright photo (a lazy image over the
	/// encoded data), the page found in it and, when asked for, where it shows glare.
	struct RawStill {
		var still: CIImage
		/// The page on the upright still (normalized, top-left origin), before the inset: detected,
		/// else the preview's mapped onto it; nil when neither found one.
		var quad: PageQuad?
		var glare: GlareMap?
	}

	/// One processed still: the cleaned page, the crop it was made with and, when asked for, the
	/// original, already written to the staging folder.
	struct ProcessedStill {
		var page: CGImage
		/// The crop on the upright still (normalized, top-left origin, inset already applied);
		/// `.fullFrame` when no page was found and the whole frame was kept.
		var quad: PageQuad
		var original: OriginalStore.Staged?
		/// True when the page was fused from several stills.
		var isFused = false
	}

	/// A second look's trigger signal, tagged with the look it belongs to.
	struct SecondLookSignal: Equatable {
		var generation: Int
		var signal: SecondLookTrigger.Signal
	}

	/// One detection result published to the main actor.
	struct DetectionUpdate: Equatable {
		var quad: PageQuad?
		var isSteady: Bool
		var autoCaptureFired: Bool
		/// Width ÷ height of the upright video frame `quad` was measured in.
		var frameAspect: CGFloat
		/// Auto-capture is armed for the page in view (see `QuadStabilityTracker.isArmed`).
		var isArmed = true
		/// The live glare check, debounced (false while it is off).
		var showsGlare = false
		/// This frame's glare map, when the check is on and found the page.
		var glare: GlareMap?
		/// Set during a second look when its trigger fires or the page is lost.
		var secondLook: SecondLookSignal?
	}

	/// Messages to `CaptureCamera`, delivered on the main queue.
	enum Event {
		case detection(DetectionUpdate)
		case runtimeError(String)
	}

	/// Seconds between Vision passes on live frames (~10 fps).
	static let analysisInterval: CFTimeInterval = 0.1
	/// Smallest corner move (normalized) worth republishing the quad for.
	static let publishThreshold: CGFloat = 0.004
	/// Open Scanner stores pages 2400 px wide.
	static let maxOutputWidth: CGFloat = 2400
	/// Stills are taken at the largest supported size whose long side is at most this (12 MP on
	/// current iPhones), which is ample for a 2400 px page and keeps Core Image's memory modest.
	static let maxPhotoLongSide: Int32 = 4032
	/// Long side of the downscaled still that Vision analyses.
	static let stillDetectionSize: CGFloat = 1024
	/// Detected outlines are pulled this fraction toward their centre before correction, which
	/// trims the sliver of table Vision's edge often includes.
	static let detectedQuadInset: CGFloat = 0.01
	/// Long side a live frame is reduced to (in one render) before the glare check samples it.
	static let glareCheckSize: CGFloat = 480

	let session: AVCaptureSession
	/// Receives detection updates and runtime errors on the main queue. Set once, before start.
	var onEvent: (@MainActor @Sendable (Event) -> Void)?

	private let sessionQueue = DispatchQueue(label: "com.rescriva.capture.session")
	private let videoQueue = DispatchQueue(label: "com.rescriva.capture.video", qos: .userInitiated)
	private let processingQueue = DispatchQueue(label: "com.rescriva.capture.processing", qos: .userInitiated)

	// sessionQueue
	private let photoOutput = AVCapturePhotoOutput()
	private let videoOutput = AVCaptureVideoDataOutput()
	private var device: AVCaptureDevice?
	private var isConfigured = false
	private var shouldRun = false
	private var inFlightCaptures: [Int64: PhotoCaptureDelegate] = [:]
	private var runtimeErrorObserver: NSObjectProtocol?

	// videoQueue
	private let frameDetector = PageDetector()
	private var tracker = QuadStabilityTracker()
	private var lastAnalysisTime: CFTimeInterval = 0
	private var autoCaptureEnabled = true
	private var lastPublished: DetectionUpdate?
	private var glareCheckEnabled = false
	private var glareDebouncer = GlareDebouncer()
	private var secondLookTrigger: SecondLookTrigger?
	private var secondLookGeneration = 0

	// processingQueue (CIContext itself is thread-safe; the live glare check shares it)
	private let stillDetector = PageDetector()
	private let ciContext = CIContext(options: [.cacheIntermediates: false])
	private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

	init(session: AVCaptureSession) {
		self.session = session
		super.init()
	}

	deinit {
		if let runtimeErrorObserver {
			NotificationCenter.default.removeObserver(runtimeErrorObserver)
		}
	}

	/// The back wide-angle camera, or nil (e.g. on the iOS Simulator).
	static func backCamera() -> AVCaptureDevice? {
		AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
	}

	// MARK: Control

	/// Configures the session on first use, applies the focus range for `mode`, and starts it.
	func start(mode: CaptureMode, autoCapture: Bool, checksGlare: Bool) async throws {
		setAutoCapture(autoCapture)
		setGlareCheck(checksGlare)
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			sessionQueue.async {
				do {
					try self.configureIfNeeded()
					self.applyFocusRange(for: mode)
					self.shouldRun = true
					if !self.session.isRunning {
						self.session.startRunning()
					}
					guard self.session.isRunning else {
						throw CaptureCamera.CaptureError.captureFailed("The camera couldn't start.")
					}
					continuation.resume()
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}

	/// Stops the session and forgets all detection state.
	func stop() {
		sessionQueue.async {
			self.shouldRun = false
			if self.session.isRunning {
				self.session.stopRunning()
			}
		}
		videoQueue.async {
			self.tracker.reset()
			self.lastPublished = nil
			self.lastAnalysisTime = 0
			self.glareDebouncer.reset()
			self.secondLookTrigger = nil
		}
	}

	func setMode(_ mode: CaptureMode) {
		sessionQueue.async {
			self.applyFocusRange(for: mode)
		}
	}

	func setAutoCapture(_ enabled: Bool) {
		videoQueue.async {
			self.autoCaptureEnabled = enabled
		}
	}

	/// Turns the live glare check (a 96 px map of each analysed frame's page) on or off.
	func setGlareCheck(_ enabled: Bool) {
		videoQueue.async {
			self.glareCheckEnabled = enabled
			self.glareDebouncer.reset()
		}
	}

	/// Starts feeding live frames to `trigger`; its signals come back tagged with `generation`.
	func beginSecondLook(_ trigger: SecondLookTrigger, generation: Int) {
		videoQueue.async {
			self.secondLookTrigger = trigger
			self.secondLookGeneration = generation
		}
	}

	/// Stops the second look's trigger. The phone moved during it, which would re-arm
	/// auto-capture over the same page, so this also counts as a capture of the page now in view.
	func endSecondLook() {
		videoQueue.async {
			self.secondLookTrigger = nil
			self.tracker.noteCapture(at: CACurrentMediaTime())
		}
	}

	// MARK: Configuration (sessionQueue)

	private func configureIfNeeded() throws {
		guard !isConfigured else { return }
		guard let camera = Self.backCamera() else { throw CaptureCamera.CaptureError.unavailable }
		let input = try AVCaptureDeviceInput(device: camera)

		session.beginConfiguration()
		defer { session.commitConfiguration() }
		if session.canSetSessionPreset(.photo) {
			session.sessionPreset = .photo
		}
		guard session.canAddInput(input) else { throw CaptureCamera.CaptureError.unavailable }
		session.addInput(input)
		guard session.canAddOutput(photoOutput) else {
			session.removeInput(input)
			throw CaptureCamera.CaptureError.unavailable
		}
		session.addOutput(photoOutput)
		videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
		videoOutput.alwaysDiscardsLateVideoFrames = true
		videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
		guard session.canAddOutput(videoOutput) else {
			session.removeOutput(photoOutput)
			session.removeInput(input)
			throw CaptureCamera.CaptureError.unavailable
		}
		session.addOutput(videoOutput)

		photoOutput.maxPhotoQualityPrioritization = .balanced
		if let dimensions = Self.preferredPhotoDimensions(for: camera) {
			photoOutput.maxPhotoDimensions = dimensions
		}
		for output in [photoOutput, videoOutput] as [AVCaptureOutput] {
			if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
				connection.videoRotationAngle = 90
			}
		}
		configureDevice(camera)
		device = camera
		isConfigured = true
		observeRuntimeErrors()
	}

	/// The largest supported photo size whose long side fits `maxPhotoLongSide`, else the smallest.
	private static func preferredPhotoDimensions(for camera: AVCaptureDevice) -> CMVideoDimensions? {
		let supported = camera.activeFormat.supportedMaxPhotoDimensions
		func pixels(_ dimensions: CMVideoDimensions) -> Int { Int(dimensions.width) * Int(dimensions.height) }
		let fitting = supported.filter { max($0.width, $0.height) <= maxPhotoLongSide }
		return fitting.max { pixels($0) < pixels($1) } ?? supported.min { pixels($0) < pixels($1) }
	}

	private func configureDevice(_ camera: AVCaptureDevice) {
		do {
			try camera.lockForConfiguration()
		} catch {
			return  // The device keeps its defaults, which still work for scanning.
		}
		defer { camera.unlockForConfiguration() }
		if camera.isFocusModeSupported(.continuousAutoFocus) {
			camera.focusMode = .continuousAutoFocus
		}
		if camera.isExposureModeSupported(.continuousAutoExposure) {
			camera.exposureMode = .continuousAutoExposure
		}
		if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
			camera.whiteBalanceMode = .continuousAutoWhiteBalance
		}
	}

	/// Documents are close, so restrict autofocus to near range; whiteboards can be metres away.
	private func applyFocusRange(for mode: CaptureMode) {
		guard let device, device.isAutoFocusRangeRestrictionSupported else { return }
		let range: AVCaptureDevice.AutoFocusRangeRestriction = mode == .document ? .near : .none
		guard device.autoFocusRangeRestriction != range else { return }
		do {
			try device.lockForConfiguration()
		} catch {
			return
		}
		device.autoFocusRangeRestriction = range
		device.unlockForConfiguration()
	}

	private func observeRuntimeErrors() {
		runtimeErrorObserver = NotificationCenter.default.addObserver(
			forName: AVCaptureSession.runtimeErrorNotification,
			object: session,
			queue: nil
		) { [weak self] notification in
			guard let pipeline = self else { return }
			let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
			pipeline.sessionQueue.async {
				pipeline.handleRuntimeError(error)
			}
		}
	}

	private func handleRuntimeError(_ error: AVError?) {
		// After a media-services reset the session can simply be restarted.
		if error?.code == .mediaServicesWereReset, shouldRun {
			session.startRunning()
			if session.isRunning { return }
		}
		deliver(.runtimeError(error?.localizedDescription ?? "The camera stopped unexpectedly."))
	}

	// MARK: Live frames (videoQueue)

	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		let now = CACurrentMediaTime()
		guard now - lastAnalysisTime >= Self.analysisInterval else { return }
		lastAnalysisTime = now
		guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

		// With the connection rotated to portrait the buffer is already upright; otherwise it is in
		// sensor (landscape) orientation and Vision is told to read it rotated.
		let isUpright = abs(connection.videoRotationAngle - 90) < 0.5
		let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
		let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
		guard width > 0, height > 0 else { return }
		let frameAspect = isUpright ? width / height : height / width

		let detected = frameDetector.detect(pixelBuffer: pixelBuffer, orientation: isUpright ? .up : .right)
		let result = tracker.update(quad: detected, at: now, autoCaptureEnabled: autoCaptureEnabled)
		var glare: GlareMap?
		if glareCheckEnabled, let quad = result.quad {
			glare = liveGlareMap(pixelBuffer, isUpright: isUpright, quad: quad)
		}
		if result.quad == nil {
			glareDebouncer.reset()
		} else if let glare {
			_ = glareDebouncer.update(glare)
		}
		var lookSignal: SecondLookSignal?
		if var trigger = secondLookTrigger {
			let signal = trigger.update(quad: result.quad, glare: glare, at: now)
			secondLookTrigger = trigger
			if signal != .waiting {
				lookSignal = SecondLookSignal(generation: secondLookGeneration, signal: signal)
			}
		}
		publishIfNeeded(DetectionUpdate(
			quad: result.quad,
			isSteady: result.isSteady,
			autoCaptureFired: result.shouldAutoCapture,
			frameAspect: frameAspect,
			isArmed: tracker.isArmed,
			showsGlare: glareCheckEnabled && glareDebouncer.isGlary,
			glare: glare,
			secondLook: lookSignal
		))
	}

	/// The glare map of the page in one live frame: the frame is reduced once to
	/// `glareCheckSize`, so the map's per-channel reads don't each resample the whole buffer.
	private func liveGlareMap(_ pixelBuffer: CVPixelBuffer, isUpright: Bool, quad: PageQuad) -> GlareMap? {
		var frame = CIImage(cvPixelBuffer: pixelBuffer)
		if !isUpright {
			frame = frame.oriented(.right)
		}
		let small = PageCleanup.limitLongSide(GlareFusion.atOrigin(frame), to: Self.glareCheckSize)
		guard let colorSpace = outputColorSpace,
			  let image = ciContext.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: colorSpace) else {
			return nil
		}
		return GlareMap.estimate(GlareFrame(image: CIImage(cgImage: image), quad: quad), context: ciContext)
	}

	private func publishIfNeeded(_ update: DetectionUpdate) {
		if !update.autoCaptureFired, update.secondLook == nil, let last = lastPublished, last.isSteady == update.isSteady,
		   last.isArmed == update.isArmed, last.showsGlare == update.showsGlare, last.glare?.glaryCells == update.glare?.glaryCells {
			switch (last.quad, update.quad) {
			case (nil, nil):
				return
			case let (old?, new?) where old.maxCornerDistance(to: new) < Self.publishThreshold:
				return
			default:
				break
			}
		}
		lastPublished = update
		deliver(.detection(update))
	}

	private func deliver(_ event: Event) {
		guard let handler = onEvent else { return }
		DispatchQueue.main.async {
			MainActor.assumeIsolated {
				handler(event)
			}
		}
	}

	// MARK: Stills

	/// Takes a still, decodes it upright and finds the page in it (and, with `measuresGlare`, the
	/// page's glare map).
	func captureStill(_ request: PageRequest, measuresGlare: Bool) async throws -> RawStill {
		videoQueue.async {
			self.tracker.noteCapture(at: CACurrentMediaTime())
		}
		let data = try await capturePhotoData()
		return try await onProcessingQueue {
			try self.prepareStill(data, request: request, measuresGlare: measuresGlare)
		}
	}

	/// Makes the cleaned, upright page from one still, or from several of the same page (a second
	/// look), fused with `GlareFusion`. The first still sets the crop and is the original.
	func processPage(_ stills: [RawStill], request: PageRequest) async throws -> ProcessedStill {
		try await onProcessingQueue {
			try self.makePage(stills, request: request)
		}
	}

	private func onProcessingQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
			processingQueue.async {
				do {
					continuation.resume(returning: try work())
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}

	private func capturePhotoData() async throws -> Data {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
			sessionQueue.async {
				guard self.session.isRunning, self.photoOutput.connection(with: .video) != nil else {
					continuation.resume(throwing: CaptureCamera.CaptureError.notRunning)
					return
				}
				let settings = self.makePhotoSettings()
				let id = settings.uniqueID
				let delegate = PhotoCaptureDelegate { result in
					self.sessionQueue.async {
						self.inFlightCaptures[id] = nil
					}
					continuation.resume(with: result)
				}
				// The photo output does not retain its delegate; keep it alive until it finishes.
				self.inFlightCaptures[id] = delegate
				self.photoOutput.capturePhoto(with: settings, delegate: delegate)
			}
		}
	}

	private func makePhotoSettings() -> AVCapturePhotoSettings {
		let settings: AVCapturePhotoSettings
		if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
			settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
		} else {
			settings = AVCapturePhotoSettings()
		}
		settings.photoQualityPrioritization = .balanced
		settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
		if photoOutput.supportedFlashModes.contains(.off) {
			settings.flashMode = .off
		}
		return settings
	}

	/// processingQueue: decode upright → detect (or fall back on the preview's quad) → glare map.
	private func prepareStill(_ data: Data, request: PageRequest, measuresGlare: Bool) throws -> RawStill {
		guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]),
			  !decoded.extent.isInfinite, decoded.extent.width >= 1, decoded.extent.height >= 1 else {
			throw CaptureCamera.CaptureError.processingFailed
		}
		let still = decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.minX, y: -decoded.extent.minY))
		let stillAspect = still.extent.width / still.extent.height

		var quad = detectPage(inStill: still)
		if quad == nil, let fallback = request.fallbackQuad {
			quad = request.fallbackFrameAspect.map {
				fallback.mappedFromCenterCrop(cropAspect: $0, intoFrameAspect: stillAspect)
			} ?? fallback
		}
		let glare = measuresGlare
			? quad.flatMap { GlareMap.estimate(GlareFrame(image: still, quad: $0.inset(by: Self.detectedQuadInset)), context: ciContext) }
			: nil
		return RawStill(still: still, quad: quad, glare: glare)
	}

	/// processingQueue: inset → correct (or fuse the stills) → limit width → clean → render, then
	/// encode the first still as the original when asked, straight to a staging file so its bytes
	/// don't wait in memory for Save.
	private func makePage(_ stills: [RawStill], request: PageRequest) throws -> ProcessedStill {
		guard let reference = stills.first else { throw CaptureCamera.CaptureError.processingFailed }
		let still = reference.still
		let crop = reference.quad?.inset(by: Self.detectedQuadInset)
		var page: CIImage
		var isFused = false
		if stills.count > 1, let fused = fusedPage(stills) {
			page = fused
			isFused = true
		} else {
			page = crop.map { PageCleanup.correctPerspective(still, quad: $0) } ?? still
			page = PageCleanup.limitWidth(page, to: Self.maxOutputWidth)
		}
		page = PageCleanup.clean(
			page,
			mode: request.mode,
			removeShadows: request.removeShadows,
			keepMarkerColors: request.keepMarkerColors
		)
		let bounds = page.extent.integral
		guard !bounds.isInfinite, bounds.width >= 1, bounds.height >= 1, let colorSpace = outputColorSpace,
			  let rendered = ciContext.createCGImage(page, from: bounds, format: .RGBA8, colorSpace: colorSpace) else {
			throw CaptureCamera.CaptureError.processingFailed
		}
		let original = request.keepsOriginal ? OriginalStore.shared.stage(still, context: ciContext) : nil
		return ProcessedStill(page: rendered, quad: crop ?? .fullFrame, original: original, isFused: isFused)
	}

	/// processingQueue: the stills of one page fused in the first one's page geometry, rendered
	/// once so cleanup reads one page instead of the blend over every still. Nil when fusion fails
	/// or no follow-up still registered against the first (another page, or too far off to match):
	/// the first still alone is used then, as without a second look.
	private func fusedPage(_ stills: [RawStill]) -> CIImage? {
		let frames = stills.map { GlareFrame(image: $0.still, quad: $0.quad?.inset(by: Self.detectedQuadInset) ?? .fullFrame) }
		var options = GlareFusion.Options()
		options.maxWidth = Self.maxOutputWidth
		options.maxFrames = 1 + CaptureCamera.maxExtraStills
		options.keepsUnrefinedFrames = false
		#if DEBUG
		let started = CACurrentMediaTime()
		#endif
		let result: GlareFusion.Result
		do {
			result = try GlareFusion.fuse(frames, context: ciContext, options: options)
		} catch {
			print("Rescriva: glare fusion failed, keeping the first photo: \(error)")
			return nil
		}
		#if DEBUG
		let used = result.frames.map { "#\($0.index) \($0.alignment) glare \(Int(($0.glareFraction * 100).rounded()))%" }
		let dropped = result.unrefinedFrames.map { "#\($0.index) \($0.alignment)" }
		print(String(format: "Rescriva: glare fusion %.0f ms; used %@; dropped %@; glare left %.0f%%",
					 (CACurrentMediaTime() - started) * 1000, used.joined(separator: ", "),
					 dropped.isEmpty ? "none" : dropped.joined(separator: ", "), result.residualGlareFraction * 100))
		#endif
		guard result.frames.count > 1 else { return nil }
		let bounds = result.page.extent.integral
		guard !bounds.isInfinite, let colorSpace = outputColorSpace,
			  let rendered = ciContext.createCGImage(result.page, from: bounds, format: .RGBA8, colorSpace: colorSpace) else {
			return nil
		}
		return CIImage(cgImage: rendered)
	}

	private func detectPage(inStill still: CIImage) -> PageQuad? {
		let small = PageCleanup.limitLongSide(still, to: Self.stillDetectionSize)
		guard let colorSpace = outputColorSpace,
			  let image = ciContext.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: colorSpace) else {
			return nil
		}
		return stillDetector.detect(cgImage: image)
	}
}

// MARK: - PhotoCaptureDelegate

/// The delegate for one still capture: collects the encoded photo and reports exactly once, from
/// the final `didFinishCaptureFor` callback.
///
/// AVFoundation calls both delegate methods serially on one internal queue, which is what makes
/// the `@unchecked Sendable` conformance sound.
fileprivate final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
	private let completion: (Result<Data, Error>) -> Void
	private var result: Result<Data, Error>?

	init(completion: @escaping (Result<Data, Error>) -> Void) {
		self.completion = completion
	}

	func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
		if let error {
			result = .failure(error)
		} else if let data = photo.fileDataRepresentation() {
			result = .success(data)
		} else {
			result = .failure(CaptureCamera.CaptureError.captureFailed("The camera returned no photo data."))
		}
	}

	func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
		let fallback = CaptureCamera.CaptureError.captureFailed(error?.localizedDescription ?? "The photo wasn't captured.")
		completion(result ?? .failure(fallback))
	}
}

// MARK: - PageDetector

/// Finds the page in an image with Vision: document segmentation first, then rectangle detection
/// as the fallback. Returns quads in top-left-origin normalized coordinates of the oriented image.
///
/// Vision requests are not thread-safe, so confine each instance to one serial queue.
final class PageDetector {
	/// Below this confidence a segmentation result is ignored.
	static let minimumSegmentationConfidence: VNConfidence = 0.5
	/// Quads smaller than this fraction of the frame are ignored.
	static let minimumArea: CGFloat = 0.04

	private let segmentation = VNDetectDocumentSegmentationRequest()
	private let rectangles: VNDetectRectanglesRequest = {
		let request = VNDetectRectanglesRequest()
		request.minimumAspectRatio = 0.3
		request.maximumAspectRatio = 1
		request.minimumSize = 0.25
		request.quadratureTolerance = 20
		request.maximumObservations = 1
		request.minimumConfidence = 0.5
		return request
	}()

	func detect(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> PageQuad? {
		detect(with: VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:]))
	}

	func detect(cgImage: CGImage) -> PageQuad? {
		detect(with: VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]))
	}

	private func detect(with handler: VNImageRequestHandler) -> PageQuad? {
		if (try? handler.perform([segmentation])) != nil,
		   let quad = best(segmentation.results, minimumConfidence: Self.minimumSegmentationConfidence) {
			return quad
		}
		guard (try? handler.perform([rectangles])) != nil else { return nil }
		return best(rectangles.results, minimumConfidence: rectangles.minimumConfidence)
	}

	private func best(_ observations: [VNRectangleObservation]?, minimumConfidence: VNConfidence) -> PageQuad? {
		guard let observation = observations?
			.filter({ $0.confidence >= minimumConfidence })
			.max(by: { $0.confidence < $1.confidence }),
			  let quad = PageQuad(vision: observation),
			  quad.isConvex, quad.area >= Self.minimumArea else { return nil }
		return quad
	}
}

extension PageQuad {
	/// Converts a Vision observation (lower-left origin) to a top-left-origin quad, clamped to the
	/// frame and ordered clockwise from the top-left.
	init?(vision observation: VNRectangleObservation) {
		func flipped(_ point: CGPoint) -> CGPoint {
			CGPoint(x: min(max(point.x, 0), 1), y: min(max(1 - point.y, 0), 1))
		}
		let points = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
		self.init(unordered: points.map(flipped))
	}
}

// MARK: - QuadStabilityTracker
// (The harness extracts the code between this marker and "END QuadStabilityTracker" verbatim.)

/// Pure steadiness and auto-capture state machine, fed one detection result at a time.
///
/// - Steady: the page has been seen for at least `steadyDuration` and, over that window, no
///   corner has been further than `steadyTolerance` (normalized) from where it is now.
/// - Auto-capture: fires when enabled and steady, at most once per steady period. It re-arms only
///   after the page moves more than `rearmDistance` from where it was captured, or disappears, and
///   never fires within `captureCooldown` of the previous capture (automatic or manual).
/// - Flicker: a page missing for less than `dropoutGrace` is held (same quad, same steadiness), so
///   a single missed Vision frame neither blinks the overlay nor re-arms auto-capture.
///
/// Times are seconds on any monotonic clock. A clock that runs backwards resets the history.
struct QuadStabilityTracker {

	/// Thresholds; the defaults are the Capture screen's.
	struct Configuration {
		var steadyDuration: TimeInterval = 0.6
		var steadyTolerance: CGFloat = 0.02
		var rearmDistance: CGFloat = 0.08
		var captureCooldown: TimeInterval = 1.5
		var dropoutGrace: TimeInterval = 0.3
		/// Hard cap on remembered samples (bounded memory even at high frame rates).
		var maxSamples = 64
	}

	/// The tracker's verdict after one update.
	struct Output: Equatable {
		/// The page to show: the latest detection, or the held one during a short dropout.
		var quad: PageQuad?
		var isSteady: Bool
		/// True on exactly the update where auto-capture should fire.
		var shouldAutoCapture: Bool
	}

	/// One timestamped detection.
	private struct Sample {
		var time: TimeInterval
		var quad: PageQuad
	}

	let configuration: Configuration
	private var samples: [Sample] = []
	private var missingSince: TimeInterval?
	private(set) var isSteady = false
	/// False from a capture until the page moves more than `rearmDistance` or disappears.
	private(set) var isArmed = true
	private var capturedQuad: PageQuad?
	private var lastCaptureTime: TimeInterval?

	init(configuration: Configuration = Configuration()) {
		self.configuration = configuration
	}

	/// The page currently considered present (latest or held), or nil.
	var presentQuad: PageQuad? {
		samples.last?.quad
	}

	/// Feeds one detection result (nil when no page was found) taken at `time`.
	mutating func update(quad: PageQuad?, at time: TimeInterval, autoCaptureEnabled: Bool) -> Output {
		if let last = samples.last, time < last.time {
			reset()
		}
		guard let quad else {
			return handleMissing(at: time)
		}
		missingSince = nil
		if !isArmed, let captured = capturedQuad, quad.maxCornerDistance(to: captured) > configuration.rearmDistance {
			isArmed = true
			capturedQuad = nil
		}
		samples.append(Sample(time: time, quad: quad))
		trimSamples(now: time)
		isSteady = computeSteadiness(latest: quad, now: time)

		let cooledDown = lastCaptureTime.map { time - $0 >= configuration.captureCooldown } ?? true
		let fire = autoCaptureEnabled && isSteady && isArmed && cooledDown
		if fire {
			noteCapture(at: time)
		}
		return Output(quad: quad, isSteady: isSteady, shouldAutoCapture: fire)
	}

	/// Records a capture (automatic or manual) at `time`: starts the cooldown and disarms
	/// auto-capture until the current page moves away or disappears. With no page present it
	/// only starts the cooldown.
	mutating func noteCapture(at time: TimeInterval) {
		lastCaptureTime = time
		guard let current = presentQuad else { return }
		isArmed = false
		capturedQuad = current
	}

	/// Forgets everything, as when the camera stops.
	mutating func reset() {
		reset(keepingCaptureHistory: false)
	}

	private mutating func reset(keepingCaptureHistory: Bool) {
		samples.removeAll(keepingCapacity: true)
		missingSince = nil
		isSteady = false
		isArmed = true
		capturedQuad = nil
		if !keepingCaptureHistory {
			lastCaptureTime = nil
		}
	}

	private mutating func handleMissing(at time: TimeInterval) -> Output {
		guard let held = samples.last else {
			return Output(quad: nil, isSteady: false, shouldAutoCapture: false)
		}
		let since = missingSince ?? time
		missingSince = since
		if time - since < configuration.dropoutGrace {
			return Output(quad: held.quad, isSteady: isSteady, shouldAutoCapture: false)
		}
		// Gone for real: the page disappeared, which also re-arms auto-capture.
		reset(keepingCaptureHistory: true)
		return Output(quad: nil, isSteady: false, shouldAutoCapture: false)
	}

	/// Keeps the newest sample at or before the window start (so the history can prove it spans the
	/// whole window) plus everything after it, capped at `maxSamples`.
	private mutating func trimSamples(now: TimeInterval) {
		let windowStart = now - configuration.steadyDuration
		var dropCount = 0
		while dropCount + 1 < samples.count, samples[dropCount + 1].time <= windowStart {
			dropCount += 1
		}
		let overflow = samples.count - dropCount - max(1, configuration.maxSamples)
		dropCount += max(0, overflow)
		if dropCount > 0 {
			samples.removeFirst(dropCount)
		}
	}

	private func computeSteadiness(latest: PageQuad, now: TimeInterval) -> Bool {
		// A little slack so frame-timing jitter at ~10 fps doesn't add a whole extra frame.
		let slack = min(0.02, configuration.steadyDuration * 0.1)
		guard let first = samples.first, now - first.time >= configuration.steadyDuration - slack else {
			return false
		}
		return samples.allSatisfy { $0.quad.maxCornerDistance(to: latest) < configuration.steadyTolerance }
	}
}
// END QuadStabilityTracker
