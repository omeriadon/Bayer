import MetalKit
import QuartzCore
import SwiftUI
#if os(iOS)
	import UIKit
#else
	import AppKit
#endif

/// Where the wave is right now, so a photo of it freezes exactly what's on screen.
@MainActor
final class WaveClock {
	var time: Float = 0
}

/// The live dithered camera: Ergo's renderer, fed every camera frame, or its wave with the camera off.
struct DitherCameraView: View {
	let configuration: DitherConfiguration
	let camera: CameraSettings
	let frames: LatestCameraFrame
	let clock: WaveClock

	@State private var isVisible = false

	@Environment(\.scenePhase) private var scenePhase

	var body: some View {
		DitherCameraPlatformView(
			configuration: configuration.pinned(usesCamera: camera.usesCamera).bounded(),
			camera: camera.bounded(),
			frames: frames,
			clock: clock,
			active: scenePhase == .active && isVisible
		)
		.onAppear { isVisible = true }
		.onDisappear { isVisible = false }
		.allowsHitTesting(false)
		.accessibilityLabel("Dithered camera preview")
	}
}

private struct DitherCameraPlatformView {
	let configuration: DitherConfiguration
	let camera: CameraSettings
	let frames: LatestCameraFrame
	let clock: WaveClock
	let active: Bool

	func makeHost() -> DitherCameraHostView {
		let view = DitherCameraHostView(frame: .zero, device: MTLCreateSystemDefaultDevice())
		update(view)
		return view
	}

	func update(_ view: DitherCameraHostView) {
		view.update(configuration: configuration, camera: camera, frames: frames, clock: clock, active: active)
	}

	static func dismantle(_ view: DitherCameraHostView) {
		view.isPaused = true
		view.delegate = nil
	}
}

#if os(iOS)
	extension DitherCameraPlatformView: UIViewRepresentable {
		func makeUIView(context _: Context) -> DitherCameraHostView {
			makeHost()
		}

		func updateUIView(_ uiView: DitherCameraHostView, context _: Context) {
			update(uiView)
		}

		static func dismantleUIView(_ uiView: DitherCameraHostView, coordinator _: ()) {
			dismantle(uiView)
		}
	}
#else
	extension DitherCameraPlatformView: NSViewRepresentable {
		func makeNSView(context _: Context) -> DitherCameraHostView {
			makeHost()
		}

		func updateNSView(_ nsView: DitherCameraHostView, context _: Context) {
			update(nsView)
		}

		static func dismantleNSView(_ nsView: DitherCameraHostView, coordinator _: ()) {
			dismantle(nsView)
		}
	}
#endif

@MainActor
private final class DitherCameraHostView: MTKView, MTKViewDelegate {
	private var configuration = DitherConfiguration()
	private var camera = CameraSettings()
	private var frames: LatestCameraFrame?
	private var clock: WaveClock?
	private var active = false
	private var renderer: DitherMetalRenderer?
	private var failed = false
	private var frameScheduler = DitherFrameScheduler()

	override init(frame: CGRect, device: (any MTLDevice)?) {
		super.init(frame: frame, device: device)
		colorPixelFormat = .bgra8Unorm
		framebufferOnly = true
		depthStencilPixelFormat = .invalid
		autoResizeDrawable = true
		isPaused = true
		enableSetNeedsDisplay = true
		#if os(iOS)
			isOpaque = true
			backgroundColor = .black
		#else
			wantsLayer = true
		#endif
		if let metalLayer = layer as? CAMetalLayer {
			metalLayer.isOpaque = true
			metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
		}
		delegate = self
	}

	@available(*, unavailable)
	required init(coder _: NSCoder) {
		fatalError("Use DitherCameraView()")
	}

	func update(configuration: DitherConfiguration, camera: CameraSettings, frames: LatestCameraFrame, clock: WaveClock, active: Bool) {
		if self.camera.usesCamera != camera.usesCamera {
			renderer?.seedAnimationTiming()
		}
		self.configuration = configuration
		self.camera = camera
		self.frames = frames
		self.clock = clock
		self.active = active
		failed = false
		updateScheduling()
		// A paused wave still redraws once when a setting changes
		requestFrame()
	}

	private func requestFrame() {
		frameScheduler.requestFrame()
		#if os(iOS)
			setNeedsDisplay()
		#else
			needsDisplay = true
		#endif
	}

	/// The camera always moves. The wave only moves while animating.
	private var isMoving: Bool {
		camera.usesCamera || !configuration.disableAnimation
	}

	#if os(iOS)
		override func didMoveToWindow() {
			super.didMoveToWindow()
			updateScheduling()
		}
	#else
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			updateScheduling()
		}
	#endif

	private var canRender: Bool {
		#if os(macOS)
			// AppKit's window reference is unowned(unsafe); only its presence is read here
			let inWindow = unsafe window != nil
		#else
			let inWindow = window != nil
		#endif
		return inWindow && active && !isHidden
	}

	private func updateScheduling() {
		preferredFramesPerSecond = configuration.framesPerSecond
		let paused = !canRender || failed || !isMoving
		if isPaused != paused {
			renderer?.seedAnimationTiming()
		}
		isPaused = paused
		enableSetNeedsDisplay = paused
		if !canRender {
			releaseDrawables()
		}
	}

	func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {
		frameScheduler.requestFrame()
	}

	func draw(in _: MTKView) {
		let now = CACurrentMediaTime()
		guard canRender,
		      bounds.width > 0, bounds.height > 0,
		      frameScheduler.shouldRender(now: now, isAnimating: !isPaused, framesPerSecond: configuration.framesPerSecond)
		else {
			return
		}
		do {
			if renderer == nil {
				let created = try DitherMetalRenderer(usesTopBlur: false)
				renderer = created
				device = created.device
				created.seedAnimationTiming()
			}
			guard let renderer else {
				return
			}
			let input: CameraFrameInput? = if camera.usesCamera {
				frames?.current.map { CameraFrameInput(texture: $0.texture, retained: $0.owner, settings: camera) }
			} else {
				CameraFrameInput.wave(device: renderer.device, settings: camera)
			}
			// Before the first camera frame there's nothing to show yet
			guard let input, let drawable = currentDrawable else {
				return
			}
			frameScheduler.didRender(now: now)
			renderer.camera = input
			try renderer.render(to: drawable, size: bounds.size, configuration: configuration, advance: !camera.usesCamera && !configuration.disableAnimation)
			clock?.time = renderer.animationTime
		} catch {
			failed = true
			updateScheduling()
			NSLog("DitherCameraView render failed: %@", error.localizedDescription)
		}
	}
}
