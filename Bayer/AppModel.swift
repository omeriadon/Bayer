import CoreGraphics
import Defaults
import Metal
import Observation
import SwiftUI

nonisolated extension DitherConfiguration: Defaults.Serializable {}
nonisolated extension CameraSettings: Defaults.Serializable {}

nonisolated extension Defaults.Keys {
	static let configuration = Key<DitherConfiguration>("configuration", default: .bayerDefault)
	static let camera = Key<CameraSettings>("camera", default: CameraSettings())
	/// The TUNE section bar, left open or closed
	static let settingsOpen = Key<Bool>("settingsOpen", default: false)
	/// The welcome has been seen; the camera is only asked for after it
	static let hasOnboarded = Key<Bool>("hasOnboarded", default: false)
}

@Observable
final class AppModel {
	enum CameraStatus {
		case unknown, running, denied
	}

	var configuration = Defaults[.configuration] {
		didSet {
			Defaults[.configuration] = configuration
			syncCameraControl()
		}
	}

	var camera = AppModel.savedCamera() {
		didSet {
			Defaults[.camera] = camera
			syncCameraControl()
			if camera.depthRange != oldValue.depthRange {
				controller.setDepthRange(camera.depthRange)
			}
			if camera.source != oldValue.source {
				// WAVE and DEPTH pages belong to their own sources
				if let section, !SettingsSection.available(source: camera.source).contains(section) {
					self.section = nil
				}
				if camera.usesCamera {
					// Camera to LiDAR or back swaps the session's input; from the wave it starts it
					Task { await startCamera() }
				} else {
					// Fully disconnected: the session stops and its last frame goes
					stopCamera()
					controller.frames.clear()
				}
			} else if camera.usesFrontCamera != oldValue.usesFrontCamera, camera.source == .camera, status == .running {
				controller.start(front: camera.usesFrontCamera, depth: false, zoom: camera.zoom)
			}
		}
	}

	var zoomRange = ZoomRange()
	/// The section bar is showing. Remembered between launches.
	var settingsOpen = Defaults[.settingsOpen] {
		didSet {
			Defaults[.settingsOpen] = settingsOpen
			if !settingsOpen {
				section = nil
			}
		}
	}

	/// Full screen: every control hidden, just the picture. A tap anywhere brings them back.
	var controlsHidden = false

	/// The open section, which takes the main controls' place
	var section: SettingsSection?
	var viewingPhoto = false
	var status = CameraStatus.unknown
	var lastPhoto: CGImage?
	var toast: String?
	/// What happened to the last photo, shown by its thumbnail
	var photoNote: PhotoNote?
	var captureCount = 0
	var isCapturing = false
	/// Camera Control's overlay is covering the screen, so the app's controls step aside
	var cameraControlOverlay = false
	/// False until the welcome is done. Until then the picture is the wave and the camera isn't asked for.
	var hasOnboarded = Defaults[.hasOnboarded] {
		didSet { Defaults[.hasOnboarded] = hasOnboarded }
	}

	let controller = CameraController(
		device: MTLCreateSystemDefaultDevice(),
		styleTitles: DitherMode.allCases.map(\.title.capitalized)
	)
	let waveClock = WaveClock()

	/// Settings restored onto a device without a scanner fall back to the camera
	private static func savedCamera() -> CameraSettings {
		var camera = Defaults[.camera]
		if !sources.contains(camera.source) {
			camera.source = .camera
		}
		return camera
	}

	/// The top-left button's stops, in order. LiDAR only where there's a scanner.
	static let sources: [CameraSettings.Source] = CameraSettings.Source.allCases.filter {
		$0 != .depth || CameraController.supportsLiDAR
	}

	init() {
		controller.setDepthRange(camera.depthRange)
		let ranges = controller.zoomRanges
		Task { [weak self] in
			for await range in ranges {
				self?.zoomRange = range
			}
		}
		let events = controller.controlEvents
		Task { [weak self] in
			for await event in events {
				self?.apply(event)
			}
		}
		syncCameraControl()
	}

	// MARK: Camera Control

	/// Applies what was done on Camera Control. Zoom only updates the number shown: the system
	/// slider has already moved the lens.
	private func apply(_ event: CameraControlEvent) {
		switch event {
			case let .zoom(zoom): camera.zoom = zoom
			case let .texels(texels): camera.cellTexels = texels
			case let .dither(dither): configuration.ditherStrength = dither
			case let .style(index): patternIndex = index
			case let .palette(index):
				if DitherPalette.all.indices.contains(index) {
					select(DitherPalette.all[index])
				}
			case let .overlay(covering): cameraControlOverlay = covering
		}
	}

	/// Keeps Camera Control's sliders where the app's are
	private func syncCameraControl() {
		controller.syncControls(CameraControlValues(
			texels: camera.cellTexels,
			dither: configuration.ditherStrength,
			style: patternIndex,
			palette: palette.flatMap { current in DitherPalette.all.firstIndex(of: current) }
		))
	}

	// MARK: Camera

	func startCamera() async {
		guard camera.usesCamera, hasOnboarded else {
			return
		}
		if await CameraController.requestAccess() {
			status = .running
			controller.start(front: camera.usesFrontCamera, depth: camera.source == .depth, zoom: camera.zoom)
		} else {
			status = .denied
		}
	}

	func stopCamera() {
		controller.stop()
	}

	/// Camera, then the dither wave, then LiDAR where there is one, then round again
	func nextSource() {
		let sources = Self.sources
		let index = sources.firstIndex(of: camera.source) ?? 0
		camera.source = sources[(index + 1) % sources.count]
	}

	func flipCamera() {
		guard camera.source == .camera else {
			return
		}
		// Each camera starts at its own 1×
		camera.zoom = 1
		camera.usesFrontCamera.toggle()
	}

	/// Sets the zoom, kept inside what this camera can do. A ramp for taps, exact for pinches.
	func setZoom(_ zoom: Double, ramp: Bool) {
		let clamped = min(max(zoom, zoomRange.minimum), zoomRange.maximum)
		camera.zoom = clamped
		controller.setZoom(clamped, ramp: ramp)
	}

	// MARK: Quick controls

	var palette: DitherPalette? {
		DitherPalette.matching(configuration)
	}

	func select(_ palette: DitherPalette) {
		palette.apply(to: &configuration)
	}

	// MARK: Tracks

	var patternIndex: Int {
		get { DitherMode.allCases.firstIndex(of: DitherMode(shaderMode: configuration.ditherMode)) ?? 0 }
		set { configuration.ditherMode = DitherMode.allCases[min(max(newValue, 0), DitherMode.allCases.count - 1)].rawValue }
	}

	/// The same snap points for camera pixels per cell and, with the camera off, points per cell
	var sizeIndex: Int {
		get {
			let current = camera.usesCamera ? camera.cellTexels : Int(configuration.pixelSize.rounded())
			let steps = sizeSteps
			return steps.indices.min { abs(steps[$0] - current) < abs(steps[$1] - current) } ?? 0
		}
		set {
			let steps = sizeSteps
			let value = steps[min(max(newValue, 0), steps.count - 1)]
			if camera.usesCamera {
				camera.cellTexels = value
			} else {
				configuration.pixelSize = Float(value)
			}
		}
	}

	/// LiDAR has its own shorter list; the camera and the wave share the full one
	var sizeSteps: [Int] {
		CameraSettings.texelSteps(for: camera.source)
	}

	static let strengthSteps = 20

	var strengthIndex: Int {
		get { Int((configuration.ditherStrength * Float(Self.strengthSteps)).rounded()) }
		set { configuration.ditherStrength = Float(min(max(newValue, 0), Self.strengthSteps)) / Float(Self.strengthSteps) }
	}

	func reset() {
		configuration = .bayerDefault
		camera = CameraSettings()
	}

	/// The name shows once at launch, then gets out of the way. The welcome says it instead the first time.
	func announce() {
		if hasOnboarded {
			show("BAYER")
		}
	}

	/// Ends the welcome and asks for the camera, now that it's been explained
	func finishOnboarding() async {
		hasOnboarded = true
		await startCamera()
	}

	// MARK: Capture

	func capture(viewSize: CGSize, scale: CGFloat) {
		guard !isCapturing else {
			return
		}
		let frame = controller.frames.current
		if camera.usesCamera, frame == nil {
			note(.failed("NO CAMERA"))
			return
		}
		isCapturing = true
		captureCount += 1
		let pixels = CGSize(width: (viewSize.width * scale).rounded(), height: (viewSize.height * scale).rounded())
		do {
			let image = try PhotoExporter.render(
				frame: frame,
				configuration: configuration,
				camera: camera,
				waveTime: waveClock.time,
				pixelSize: pixels,
				scale: scale
			)
			lastPhoto = image
			Task {
				do {
					try await PhotoExporter.save(image)
					note(.saved)
				} catch {
					note(.failed(error is PhotoExporter.Failure ? "NO ACCESS" : "NOT SAVED"))
				}
				isCapturing = false
			}
		} catch {
			isCapturing = false
			note(.failed("FAILED"))
		}
	}

	private func note(_ note: PhotoNote) {
		photoNote = note
		Task {
			try? await Task.sleep(for: .seconds(1.8))
			if photoNote == note {
				photoNote = nil
			}
		}
	}

	func show(_ message: String) {
		toast = message
		Task {
			try? await Task.sleep(for: .seconds(1.6))
			if toast == message {
				toast = nil
			}
		}
	}
}

/// The shader's dither patterns, by the names the UI shows. Raw values are the shader's mode numbers;
/// its 4×4 and 2×2 Bayer modes are left out, since 8×8 covers them.
enum DitherMode: Int, CaseIterable, Identifiable {
	case bayer = 0
	case halftone = 3
	case lines = 4
	case crosshatch = 5
	case noise = 6
	case flat = 7

	var id: Int { rawValue }

	var title: String {
		switch self {
			case .bayer: "BAYER"
			case .halftone: "DOTS"
			case .lines: "LINES"
			case .crosshatch: "CROSS"
			case .noise: "NOISE"
			case .flat: "FLAT"
		}
	}

	/// Old saved modes 1 and 2 were the smaller Bayer matrices
	init(shaderMode: Int) {
		self = DitherMode(rawValue: shaderMode) ?? .bayer
	}
}

enum PhotoNote: Equatable {
	case saved
	case failed(String)

	var title: String {
		switch self {
			case .saved: "SAVED"
			case let .failed(reason): reason
		}
	}
}
