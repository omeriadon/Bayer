import CoreGraphics
import Metal
import Observation
import SwiftUI

@Observable
final class AppModel {
	enum CameraStatus {
		case unknown, running, denied
	}

	var configuration: DitherConfiguration {
		didSet { save(configuration, key: Keys.configuration) }
	}

	var camera: CameraSettings {
		didSet {
			save(camera, key: Keys.camera)
			if camera.usesCamera != oldValue.usesCamera {
				if camera.usesCamera {
					Task { await startCamera() }
				} else {
					// Fully disconnected: the session stops and its last frame goes
					stopCamera()
					controller.frames.clear()
				}
			} else if camera.usesFrontCamera != oldValue.usesFrontCamera, status == .running {
				controller.start(front: camera.usesFrontCamera, zoom: camera.zoom)
			}
		}
	}

	var zoomRange = ZoomRange()
	var debugOpen = false
	var viewingPhoto = false
	var status = CameraStatus.unknown
	var lastPhoto: CGImage?
	var toast: String?
	/// What happened to the last photo, shown by its thumbnail
	var photoNote: PhotoNote?
	var captureCount = 0
	var isCapturing = false

	let controller = CameraController(device: MTLCreateSystemDefaultDevice())
	let waveClock = WaveClock()

	private enum Keys {
		static let configuration = "bayer.configuration.v1"
		static let camera = "bayer.camera.v1"
	}

	init() {
		configuration = Self.load(Keys.configuration) ?? .bayerDefault
		camera = Self.load(Keys.camera) ?? CameraSettings()
		let ranges = controller.zoomRanges
		Task { [weak self] in
			for await range in ranges {
				self?.zoomRange = range
			}
		}
	}

	// MARK: Camera

	func startCamera() async {
		guard camera.usesCamera else {
			return
		}
		if await CameraController.requestAccess() {
			status = .running
			controller.start(front: camera.usesFrontCamera, zoom: camera.zoom)
		} else {
			status = .denied
		}
	}

	func stopCamera() {
		controller.stop()
	}

	func flipCamera() {
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
			let current = camera.usesCamera ? camera.texelsPerCell : Int(configuration.pixelSize.rounded())
			let steps = CameraSettings.texelSteps
			return steps.indices.min { abs(steps[$0] - current) < abs(steps[$1] - current) } ?? 0
		}
		set {
			let steps = CameraSettings.texelSteps
			let value = steps[min(max(newValue, 0), steps.count - 1)]
			if camera.usesCamera {
				camera.texelsPerCell = value
			} else {
				configuration.pixelSize = Float(value)
			}
		}
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

	/// The name shows once at launch, then gets out of the way.
	func announce() {
		show("BAYER")
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

	// MARK: Persistence

	private func save(_ value: some Encodable, key: String) {
		if let data = try? JSONEncoder().encode(value) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}

	private static func load<T: Decodable>(_ key: String) -> T? {
		guard let data = UserDefaults.standard.data(forKey: key) else {
			return nil
		}
		return try? JSONDecoder().decode(T.self, from: data)
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
