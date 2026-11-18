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

/// Runs the capture session. Everything here happens on its own queues, never the main actor.
nonisolated final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
	let frames = LatestCameraFrame()
	/// A new range each time the camera changes
	let zoomRanges: AsyncStream<ZoomRange>
	private let zoomContinuation: AsyncStream<ZoomRange>.Continuation

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
	#if os(iOS)
		private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
		private var rotationObservation: NSKeyValueObservation?
	#endif

	init(device: (any MTLDevice)?) {
		var cache: CVMetalTextureCache?
		if let device {
			unsafe CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
		}
		textureCache = cache
		(zoomRanges, zoomContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
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
