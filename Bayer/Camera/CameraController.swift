import AVFoundation
import CoreVideo
import Metal
import simd
import Synchronization

/// The newest camera frame, shared between the capture queue and the render loop.
nonisolated final class LatestCameraFrame: Sendable {
	struct Frame: @unchecked Sendable {
		/// Valid only while `owner` is alive
		let texture: any MTLTexture
		let owner: FrameOwner
	}

	/// Keeps a CVMetalTexture (and so its pixel buffer) alive. CF types aren't Sendable, but this one is never mutated.
	final class FrameOwner: @unchecked Sendable {
		let texture: CVMetalTexture

		init(_ texture: CVMetalTexture) {
			self.texture = texture
		}
	}

	private let storage = Mutex<Frame?>(nil)

	var current: Frame? {
		storage.withLock { $0 }
	}

	func publish(_ frame: Frame) {
		storage.withLock { $0 = frame }
	}

	func clear() {
		storage.withLock { $0 = nil }
	}
}

/// What the current camera can zoom to, in the numbers people know: 0.5×, 1×, 2×…
nonisolated struct ZoomRange: Equatable, Sendable {
	var minimum: Double = 1
	var maximum: Double = 1
	/// The lenses' own zooms, plus 2× where there's no tele
	var presets: [Double] = [1]
	/// The Mac has no lens zoom, so there the shader crops instead
	var digital = false
}

/// Something done on Camera Control, for the app to show and apply.
nonisolated enum CameraControlEvent: Sendable {
	/// The system zoom slider already zoomed the lens; this is just the new zoom as people say it
	case zoom(Double)
	/// Camera pixels along a cell's side
	case texels(Int)
	/// 0...1
	case dither(Float)
	case style(Int)
	case palette(Int)
	/// Camera Control's overlay covering the screen, or not
	case overlay(Bool)
}

/// Where Camera Control's own sliders should sit, kept in step with the app's controls.
nonisolated struct CameraControlValues: Equatable, Sendable {
	var texels = 10
	var dither: Float = 1
	var style = 0
	var palette: Int?
}

/// Runs the capture session. Everything here happens on its own queues, never the main actor.
nonisolated final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
	let frames = LatestCameraFrame()
	/// A new range each time the camera changes
	let zoomRanges: AsyncStream<ZoomRange>
	private let zoomContinuation: AsyncStream<ZoomRange>.Continuation
	/// Everything done on Camera Control
	let controlEvents: AsyncStream<CameraControlEvent>
	private let controlContinuation: AsyncStream<CameraControlEvent>.Continuation
	/// The dither patterns' names, for the Style picker on Camera Control
	private let styleTitles: [String]

	private let session = AVCaptureSession()
	private let output = AVCaptureVideoDataOutput()
	private let sessionQueue = DispatchQueue(label: "bayer.camera.session")
	private let videoQueue = DispatchQueue(label: "bayer.camera.video", qos: .userInteractive)
	private let textureCache: CVMetalTextureCache?

	// Session queue only
	private var configured = false
	private var input: AVCaptureDeviceInput?
	private var usesFrontCamera = false
	private var interfaceIsPortrait = true
	private var controlValues = CameraControlValues()
	#if os(iOS)
		private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
		private var rotationObservation: NSKeyValueObservation?
		private var sizeSlider: AVCaptureSlider?
		private var ditherSlider: AVCaptureSlider?
		private var stylePicker: AVCaptureIndexPicker?
		private var palettePicker: AVCaptureIndexPicker?
	#endif

	init(device: (any MTLDevice)?, styleTitles: [String]) {
		var cache: CVMetalTextureCache?
		if let device {
			unsafe CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
		}
		textureCache = cache
		self.styleTitles = styleTitles
		(zoomRanges, zoomContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
		(controlEvents, controlContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
		super.init()
	}

	static func requestAccess() async -> Bool {
		switch AVCaptureDevice.authorizationStatus(for: .video) {
			case .authorized: true
			case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
			default: false
		}
	}

	func start(front: Bool, zoom: Double) {
		sessionQueue.async { [self] in
			if !configured {
				configure()
			}
			if front != usesFrontCamera || input == nil {
				switchCamera(front: front)
				applyZoom(zoom, ramp: false)
			}
			if !session.isRunning {
				session.startRunning()
			}
		}
	}

	func stop() {
		sessionQueue.async { [self] in
			if session.isRunning {
				session.stopRunning()
			}
		}
	}

	/// Frames match the screen: upright portrait while the UI is portrait (rotation lock included),
	/// and level with the horizon once the UI turns landscape.
	func setInterfaceIsPortrait(_ portrait: Bool) {
		sessionQueue.async { [self] in
			interfaceIsPortrait = portrait
			applyRotation()
		}
	}

	/// `zoom` as people say it (0.5×, 1×, 2×). Ramps for a tap on a preset, follows exactly for a pinch.
	func setZoom(_ zoom: Double, ramp: Bool) {
		sessionQueue.async { [self] in
			applyZoom(zoom, ramp: ramp)
		}
	}

	private func applyZoom(_ zoom: Double, ramp: Bool) {
		#if os(iOS)
			guard let device = input?.device else {
				return
			}
			let multiplier = Double(device.displayVideoZoomFactorMultiplier)
			let factor = min(max(zoom / max(multiplier, 0.01), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
			do {
				try device.lockForConfiguration()
				if ramp {
					device.ramp(toVideoZoomFactor: factor, withRate: 10)
				} else {
					device.cancelVideoZoomRamp()
					device.videoZoomFactor = factor
				}
				device.unlockForConfiguration()
			} catch {
				// Someone else has the camera locked; this zoom just doesn't happen
			}
		#endif
	}

	private func applyRotation() {
		#if os(iOS)
			guard let connection = output.connection(with: .video) else {
				return
			}
			// The coordinator knows how each camera is mounted, so the front camera turns the right way too
			let angle: CGFloat = interfaceIsPortrait ? 90 : (rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90)
			if connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle {
				connection.videoRotationAngle = angle
			}
		#endif
	}

	private func configure() {
		session.beginConfiguration()
		if session.canSetSessionPreset(.hd1920x1080) {
			session.sessionPreset = .hd1920x1080
		} else {
			session.sessionPreset = .high
		}
		output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
		output.alwaysDiscardsLateVideoFrames = true
		output.setSampleBufferDelegate(self, queue: videoQueue)
		if session.canAddOutput(output) {
			session.addOutput(output)
		}
		session.commitConfiguration()
		#if os(iOS)
			// Controls only come alive once the session has a controls delegate
			if session.supportsControls {
				session.setControlsDelegate(self, queue: sessionQueue)
			}
		#endif
		configured = true
	}

	/// On iPhone and iPad, the back camera is the multi-lens one where there is one, so zoom crosses
	/// lenses like the Camera app. On the Mac, "front" picks the second camera when there's more than one.
	private static func camera(front: Bool) -> AVCaptureDevice? {
		#if os(iOS)
			if front {
				return AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
					?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
			}
			for type: AVCaptureDevice.DeviceType in [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera] {
				if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
					return device
				}
			}
			return nil
		#else
			let devices = AVCaptureDevice.DiscoverySession(
				deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
				mediaType: .video,
				position: .unspecified
			).devices
			guard !devices.isEmpty else {
				return nil
			}
			return devices[front && devices.count > 1 ? 1 : 0]
		#endif
	}

	private func switchCamera(front: Bool) {
		guard let device = Self.camera(front: front),
		      let newInput = try? AVCaptureDeviceInput(device: device)
		else {
			return
		}
		session.beginConfiguration()
		if let input {
			session.removeInput(input)
		}
		if session.canAddInput(newInput) {
			session.addInput(newInput)
			input = newInput
		}
		#if os(iOS)
			rotationObservation = nil
			let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
			rotationCoordinator = coordinator
			rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
				guard let self else {
					return
				}
				sessionQueue.async {
					self.applyRotation()
				}
			}
			let mirrored = front
		#else
			// The Mac's own camera faces you, like a selfie; external and Continuity cameras don't
			let mirrored = device.deviceType == .builtInWideAngleCamera
		#endif
		if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
			connection.automaticallyAdjustsVideoMirroring = false
			connection.isVideoMirrored = mirrored
		}
		applyRotation()
		session.commitConfiguration()
		usesFrontCamera = front
		zoomContinuation.yield(Self.zoomRange(for: device))
		#if os(iOS)
			installControls(for: device)
		#endif
	}

	/// Moves Camera Control's sliders to match the app, after a change made on screen.
	func syncControls(_ values: CameraControlValues) {
		sessionQueue.async { [self] in
			guard values != controlValues else {
				return
			}
			controlValues = values
			#if os(iOS)
				applyControlValues()
			#endif
		}
	}

	private static func zoomRange(for device: AVCaptureDevice) -> ZoomRange {
		#if os(iOS)
			let multiplier = Double(device.displayVideoZoomFactorMultiplier)
			let minimum = (Double(device.minAvailableVideoZoomFactor) * multiplier * 10).rounded() / 10
			// Past about 10× it's all upscaling, which the dither only makes mushier
			let maximum = min(Double(device.maxAvailableVideoZoomFactor) * multiplier, 10)
			var presets = [minimum, 1] + device.virtualDeviceSwitchOverVideoZoomFactors.map { (Double(truncating: $0) * multiplier * 10).rounded() / 10 }
			if !presets.contains(where: { $0 > 1 }), maximum >= 2 {
				presets.append(2)
			}
			presets = Array(Set(presets.filter { $0 >= minimum && $0 <= maximum })).sorted()
			return ZoomRange(minimum: minimum, maximum: maximum, presets: presets, digital: false)
		#else
			return ZoomRange(minimum: 1, maximum: 4, presets: [1, 2, 4], digital: true)
		#endif
	}

	func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
		guard let textureCache, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
			return
		}
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		var cvTexture: CVMetalTexture?
		unsafe CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
		guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
			return
		}
		frames.publish(.init(texture: texture, owner: .init(cvTexture)))
	}
}

// MARK: Camera Control

#if os(iOS)
	/// Runs on the session queue like the rest of the controller, never the main actor.
	nonisolated extension CameraController: AVCaptureSessionControlsDelegate {
		/// Zoom, size, dither, style and palette, each its own slider or picker on Camera Control. Rebuilt per
		/// camera, since the zoom slider belongs to one device.
		private func installControls(for device: AVCaptureDevice) {
			guard session.supportsControls else {
				return
			}
			for control in session.controls {
				session.removeControl(control)
			}
			let events = controlContinuation
			let multiplier = Double(device.displayVideoZoomFactorMultiplier)

			// The system's own zoom slider moves the lens itself, with the Camera app's lens markers
			let zoom = AVCaptureSystemZoomSlider(device: device) { factor in
				events.yield(.zoom(Double(factor) * multiplier))
			}

			// Size as the ratio people see in the app, 1:1 to 1:1024, so the slider's numbers match
			let ratios = CameraSettings.texelSteps.map { Float($0 * $0) }
			let size = AVCaptureSlider("Cell size", symbolName: "square.grid.2x2", values: ratios)
			size.localizedValueFormat = "1:%.0f"
			size.prominentValues = [1, 16, 100, 400]
			size.setActionQueue(sessionQueue) { ratio in
				events.yield(.texels(Int(ratio.squareRoot().rounded())))
			}

			let dither = AVCaptureSlider("Dither", symbolName: "checkerboard.rectangle", in: 0 ... 100, step: 5)
			dither.localizedValueFormat = "%.0f%%"
			dither.prominentValues = [0, 50, 100]
			dither.setActionQueue(sessionQueue) { value in
				events.yield(.dither(value / 100))
			}

			let style = AVCaptureIndexPicker("Style", symbolName: "circle.grid.3x3", localizedIndexTitles: styleTitles)
			style.setActionQueue(sessionQueue) { index in
				events.yield(.style(index))
			}

			let palette = AVCaptureIndexPicker(
				"Palette",
				symbolName: "paintpalette",
				localizedIndexTitles: DitherPalette.all.map(\.name.capitalized)
			)
			palette.setActionQueue(sessionQueue) { index in
				events.yield(.palette(index))
			}

			session.beginConfiguration()
			for control in [zoom, size, dither, style, palette] as [AVCaptureControl] where session.canAddControl(control) {
				session.addControl(control)
			}
			session.commitConfiguration()
			sizeSlider = size
			ditherSlider = dither
			stylePicker = style
			palettePicker = palette
			applyControlValues()
		}

		private func applyControlValues() {
			sizeSlider?.value = Float(controlValues.texels * controlValues.texels)
			ditherSlider?.value = (controlValues.dither * 100).rounded()
			stylePicker?.selectedIndex = controlValues.style
			if let index = controlValues.palette {
				palettePicker?.selectedIndex = index
			}
		}

		func sessionControlsDidBecomeActive(_: AVCaptureSession) {}

		/// Camera Control's overlay is about to cover the screen; the app's own controls step aside
		func sessionControlsWillEnterFullscreenAppearance(_: AVCaptureSession) {
			controlContinuation.yield(.overlay(true))
		}

		func sessionControlsWillExitFullscreenAppearance(_: AVCaptureSession) {
			controlContinuation.yield(.overlay(false))
		}

		func sessionControlsDidBecomeInactive(_: AVCaptureSession) {
			controlContinuation.yield(.overlay(false))
		}
	}
#endif
