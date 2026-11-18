// The renderer from Ergo's DitherView, with a camera input added.
// Platform neutral so Checks/ can run it on the Mac.
import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import QuartzCore
import simd
import SwiftUI
#if os(iOS)
	import UIKit
#elseif os(macOS)
	import AppKit
#endif

public nonisolated struct DitherConfiguration: Equatable, Sendable, Codable {
	static let defaultWaveDirection: Float = 135
	static let supportedPaletteCount = 8

	public var waveSpeed: Float = 0.05
	public var waveDirection: Float = Self.defaultWaveDirection
	public var waveFrequency: Float = 3
	public var waveAmplitude: Float = 0.3
	public var waveColor = SIMD3<Float>(0.12, 0.85, 1)
	public var backgroundColor = SIMD3<Float>(0.02, 0.01, 0.08)
	public var colorNum: Float = 4
	public var pixelSize: Float = 5
	public var disableAnimation = false
	public var framesPerSecond = 5
	public var ditherMode = 0
	public var ditherStrength: Float = 1
	public var palette: [SIMD3<Float>] = [
		SIMD3<Float>(0.12, 0.85, 1),
		SIMD3<Float>(0.55, 0.18, 1),
		SIMD3<Float>(1, 0.2, 0.55),
		SIMD3<Float>(1, 0.72, 0.18),
	]
	public var scale: Float = 1
	public var contrast: Float = 1
	public var brightness: Float = 0
	public var intro = true
	public var transparent = false
	public var gap: Float = 0
	public var cornerRadius: Float = 0
	public var joinAdjacentSquares = false
	public var backgroundStyle = "custom"
	public var colorPlacement = "squares"
	public var squareStyle = "white"
	public var useThemeColors = false
	public var opacity: Float = 1
	public var topBlur = false
	public var clipsToDeviceCorners = true

	public var cursorInteractionEnabled = false
	public var cursorRadius: Double = 0.5
	public var cursorStrength: Double = 1
	public var cursorResponse: Double = 0.28
	public var cursorTrailDuration: Double = 0.7
	public var cursorFadeDuration: Double = 0.8
	public var cursorWarp: Double = 0.15

	public init() {}

	static func normalizedWaveDirection(_ degrees: Float) -> Float? {
		guard degrees.isFinite else { return nil }
		let normalized = degrees.truncatingRemainder(dividingBy: 360)
		let positive = normalized >= 0 ? normalized : normalized + 360
		let snapped = (positive / 45).rounded() * 45
		return snapped >= 360 ? 0 : snapped
	}

	static func waveDirectionVector(for degrees: Float) -> SIMD2<Float> {
		let normalized = normalizedWaveDirection(degrees) ?? defaultWaveDirection
		let radians = normalized * .pi / 180
		return SIMD2<Float>(sin(radians), -cos(radians)) * sqrt(2)
	}

	static func compassDirection(for degrees: Float) -> String {
		let normalized = normalizedWaveDirection(degrees) ?? defaultWaveDirection
		return ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((normalized / 45).rounded()) % 8]
	}

	func bounded() -> Self {
		var value = self
		value.waveSpeed = finite(waveSpeed, 0.05, 0 ... 1)
		value.framesPerSecond = min(max(framesPerSecond, 1), 120)
		value.waveDirection = Self.normalizedWaveDirection(waveDirection) ?? Self.defaultWaveDirection
		value.waveFrequency = finite(waveFrequency, 3, 0.01 ... 12)
		value.waveAmplitude = finite(waveAmplitude, 0.3, 0 ... 1)
		value.colorNum = finite(colorNum, 4, 2 ... 16)
		value.pixelSize = finite(pixelSize, 2, 1 ... 4096)
		value.ditherStrength = finite(ditherStrength, 1, 0 ... 1)
		value.scale = finite(scale, 1, 0.05 ... 32)
		value.contrast = finite(contrast, 1, 0.01 ... 8)
		value.brightness = finite(brightness, 0, -1 ... 1)
		value.gap = finite(gap, 0, 0 ... 0.45)
		value.cornerRadius = finite(cornerRadius, 0, 0 ... 0.5)
		value.opacity = finite(opacity, 1, 0 ... 1)
		value.waveColor = finiteColor(waveColor, .init(repeating: 0.5))
		value.backgroundColor = finiteColor(backgroundColor, .zero)
		value.palette = palette.prefix(Self.supportedPaletteCount).map { finiteColor($0, .init(repeating: 0.5)) }
		value.ditherMode = min(max(ditherMode, 0), 7)
		value.backgroundStyle = Self.validBackgroundStyle(backgroundStyle)
		value.colorPlacement = Self.validColorPlacement(colorPlacement)
		value.squareStyle = Self.validSquareStyle(squareStyle)
		value.cursorRadius = safe(cursorRadius, 0.05 ... 2, fallback: 0.5)
		value.cursorStrength = safe(cursorStrength, -2 ... 2, fallback: 1)
		value.cursorResponse = safe(cursorResponse, 0.05 ... 1, fallback: 0.28)
		value.cursorTrailDuration = safe(cursorTrailDuration, 0 ... 2, fallback: 0.7)
		value.cursorFadeDuration = safe(cursorFadeDuration, 0.1 ... 3, fallback: 0.8)
		value.cursorWarp = safe(cursorWarp, 0 ... 1, fallback: 0.15)
		return value
	}

	static func validBackgroundStyle(_ value: String?) -> String {
		switch value {
			case "custom", "black", "white", "dim": value!
			default: "custom"
		}
	}

	static func validColorPlacement(_ value: String?) -> String {
		value == "background" ? "background" : "squares"
	}

	static func validSquareStyle(_ value: String?) -> String {
		value == "black" ? "black" : "white"
	}

	func safe(_ value: Double, _ range: ClosedRange<Double>, fallback: Double = 0) -> Double {
		min(max(value.isFinite ? value : fallback, range.lowerBound), range.upperBound)
	}

	private func finite(_ value: Float, _ fallback: Float, _ range: ClosedRange<Float>) -> Float {
		min(max(value.isFinite ? value : fallback, range.lowerBound), range.upperBound)
	}

	private func finiteColor(_ value: SIMD3<Float>, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
		SIMD3<Float>(finite(value.x, fallback.x, 0 ... 1), finite(value.y, fallback.y, 0 ... 1), finite(value.z, fallback.z, 0 ... 1))
	}
}

struct DitherAnimationTiming {
	private var lastTime: TimeInterval?

	mutating func advance(now: TimeInterval, isAdvancing: Bool) -> TimeInterval {
		guard let previous = lastTime else {
			lastTime = now
			return 0
		}

		guard isAdvancing else {
			return 0
		}

		lastTime = now
		return max(0, now - previous)
	}

	mutating func seed(now: TimeInterval) {
		lastTime = now
	}

	mutating func reset() {
		lastTime = nil
	}
}

struct DitherFrameScheduler {
	private(set) var lastRenderTime: TimeInterval?
	private var frameRequested = true

	mutating func requestFrame() {
		frameRequested = true
	}

	func shouldRender(now: TimeInterval, isAnimating: Bool, framesPerSecond: Int = 5) -> Bool {
		guard isAnimating || frameRequested else {
			return false
		}

		guard isAnimating else {
			return true
		}

		let interval = 1.0 / Double(max(1, framesPerSecond))
		guard let lastRenderTime else {
			return true
		}
		return now - lastRenderTime >= interval
	}

	mutating func didRender(now: TimeInterval) {
		lastRenderTime = now
		frameRequested = false
	}
}

struct DitherRenderInputs: Equatable, Sendable {
	var themePositions: [SIMD2<Float>] = []
	var themeColors: [SIMD3<Float>] = []
	var cursorTrail: [SIMD3<Float>] = []
	var cursorTouch: SIMD2<Float> = .zero
	var cursorPresence: Float = 0
	var screenOrigin: SIMD2<Float> = .zero
	var screenSize: SIMD2<Float> = .zero
	var screenCornerRadius: Float = 0

	static let empty = DitherRenderInputs()
}

private struct FieldUniforms {
	var resolution: SIMD2<Float>
	var cell: Float
	var time: Float
	var waveSpeed: Float
	var waveDirection: SIMD2<Float>
	var waveFrequency: Float
	var waveAmplitude: Float
	var scale: Float
	var contrast: Float
	var brightness: Float
	var intro: Float
	var reach: Float
	var cursorPosition: SIMD2<Float>
	var cursorRadius: Float
	var cursorStrength: Float
	var cursorWarp: Float
	var cursorPresence: Float
	var cursorTouch: SIMD2<Float>
	var trail0: SIMD3<Float>
	var trail1: SIMD3<Float>
	var trail2: SIMD3<Float>
	var trail3: SIMD3<Float>
	var trail4: SIMD3<Float>
	var trail5: SIMD3<Float>
	var trail6: SIMD3<Float>
	var trail7: SIMD3<Float>
}

private struct DitherUniforms {
	var fieldSize: SIMD2<Int32>
	var cellDevice: Float
	var mode: Int32
	var colorNum: Float
	var ditherStrength: Float
	var wave: SIMD3<Float>
	var background: SIMD3<Float>
	var paletteCount: Int32
	var transparent: Float
	var gap: Float
	var cornerRadius: Float
	var joinAdjacentSquares: Int32
	var viewportSize: SIMD2<Int32>
	var themeCount: Int32
	var useThemeColors: Int32
	var colorPlacement: Int32
	var backgroundStyle: Int32
	var squareStyle: Int32
	var cursorPresence: Float
	var screenOrigin: SIMD2<Float>
	var screenSize: SIMD2<Float>
	var screenCornerRadius: Float
}

private struct TopBlurUniforms {
	var stripHeight: Float
}

private struct CellBlurUniforms {
	var width: Int32
	var cellSize: Int32
	var sourceRows: Int32
	var radius: Int32
	var cellRadius: Int32
	var phaseCount: Int32
	var weightStride: Int32
}

private struct CellBlurCompositeUniforms {
	var stripHeight: Int32
	var cellSize: Int32
	var rowCount: Int32
	var width: Int32
	var transparent: Float
	var scale: Float
	var background: SIMD3<Float>
}

private final class DitherMetalBundleMarker {}

/// Where the shader library comes from. The app uses its own bundle; Checks/ points this at a metallib it built.
@MainActor
enum DitherShaderLibrary {
	static var url: URL?
}

private struct CoverageKey: Hashable {
	let cell: Int
	let gap: Float
	let radius: Float
}

@MainActor
private final class SharedMetalResources {
	let device: any MTLDevice
	let queue: any MTLCommandQueue
	let library: any MTLLibrary
	let vertex: any MTLFunction
	let gradientTexture: any MTLTexture
	private var fieldPipeline: any MTLRenderPipelineState?
	private var cellPipeline: any MTLRenderPipelineState?
	private var fusedCellComputePipeline: any MTLComputePipelineState?
	private var referenceDitherPipeline: any MTLRenderPipelineState?
	private var optimizedDitherPipeline: any MTLRenderPipelineState?
	private var atlasDitherPipeline: any MTLRenderPipelineState?
	private var coverageComputePipeline: any MTLComputePipelineState?
	private var joinMaskComputePipeline: any MTLComputePipelineState?
	private var blurCompositePipeline: any MTLRenderPipelineState?
	private var cellBlurHorizontalPipeline: any MTLComputePipelineState?
	private var cellBlurCompositePipeline: any MTLRenderPipelineState?
	private var coverageTextures: [CoverageKey: any MTLTexture] = [:]

	init() throws {
		guard let device = MTLCreateSystemDefaultDevice() else {
			throw NSError(domain: "DitherMetal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal device is unavailable"])
		}
		self.device = device

		let loaded: (any MTLLibrary)? = if let url = DitherShaderLibrary.url {
			try? device.makeLibrary(URL: url)
		} else {
			try? device.makeDefaultLibrary(bundle: Bundle(for: DitherMetalBundleMarker.self))
		}
		guard let library = loaded else {
			throw NSError(domain: "DitherMetal", code: 3, userInfo: [NSLocalizedDescriptionKey: "default.metallib could not be loaded; include OptimizedDither.metal in this target"])
		}
		guard let vertex = library.makeFunction(name: "ditherVertex"),
		      let gradientFunction = library.makeFunction(name: "ditherGradient"),
		      let queue = device.makeCommandQueue(),
		      let gradients = device.makeTexture(descriptor: {
		      	let descriptor = MTLTextureDescriptor.texture2DDescriptor(
		      		pixelFormat: .rgba32Float,
		      		width: 289,
		      		height: 289,
		      		mipmapped: false
		      	)
		      	descriptor.storageMode = .private
		      	descriptor.usage = [.renderTarget, .shaderRead]
		      	return descriptor
		      }()),
		      let initialization = queue.makeCommandBuffer()
		else {
			throw NSError(domain: "DitherMetal", code: 4, userInfo: [NSLocalizedDescriptionKey: "Dither shader functions are missing"])
		}
		self.queue = queue
		self.library = library
		self.vertex = vertex
		gradientTexture = gradients

		func makePipeline(fragment: any MTLFunction, pixelFormat: MTLPixelFormat) throws -> any MTLRenderPipelineState {
			let descriptor = MTLRenderPipelineDescriptor()
			descriptor.vertexFunction = vertex
			descriptor.fragmentFunction = fragment
			descriptor.colorAttachments[0].pixelFormat = pixelFormat
			return try device.makeRenderPipelineState(descriptor: descriptor)
		}

		let gradientPipeline = try makePipeline(fragment: gradientFunction, pixelFormat: .rgba32Float)
		let gradientPass = MTLRenderPassDescriptor()
		gradientPass.colorAttachments[0].texture = gradients
		gradientPass.colorAttachments[0].loadAction = .dontCare
		gradientPass.colorAttachments[0].storeAction = .store
		guard let encoder = initialization.makeRenderCommandEncoder(descriptor: gradientPass) else {
			throw NSError(domain: "DitherMetal", code: 13)
		}
		encoder.setRenderPipelineState(gradientPipeline)
		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
		encoder.endEncoding()
		initialization.commit()
		initialization.waitUntilCompleted()
		if let error = initialization.error {
			throw error
		}
	}

	private func renderPipeline(fragment name: String, pixelFormat: MTLPixelFormat) throws -> any MTLRenderPipelineState {
		guard let function = library.makeFunction(name: name) else {
			throw NSError(domain: "DitherMetal", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing Metal shader function: \(name)"])
		}
		let descriptor = MTLRenderPipelineDescriptor()
		descriptor.vertexFunction = vertex
		descriptor.fragmentFunction = function
		descriptor.colorAttachments[0].pixelFormat = pixelFormat
		do {
			return try device.makeRenderPipelineState(descriptor: descriptor)
		} catch {
			throw NSError(domain: "DitherMetal", code: 5, userInfo: [NSLocalizedDescriptionKey: "Dither pipeline creation failed: \(error)"])
		}
	}

	func fieldPipelineState() throws -> any MTLRenderPipelineState {
		if let fieldPipeline {
			return fieldPipeline
		}
		let pipeline = try renderPipeline(fragment: "ditherField", pixelFormat: .rgba8Unorm)
		fieldPipeline = pipeline
		return pipeline
	}

	func cellPipelineState() throws -> any MTLRenderPipelineState {
		if let cellPipeline {
			return cellPipeline
		}
		let pipeline = try renderPipeline(fragment: "ditherCell", pixelFormat: .rgba16Float)
		cellPipeline = pipeline
		return pipeline
	}

	func fusedCellComputePipelineState() throws -> any MTLComputePipelineState {
		if let fusedCellComputePipeline {
			return fusedCellComputePipeline
		}
		guard let function = library.makeFunction(name: "ditherFusedCellCompute") else {
			throw NSError(domain: "DitherMetal", code: 4)
		}
		let pipeline = try device.makeComputePipelineState(function: function)
		fusedCellComputePipeline = pipeline
		return pipeline
	}

	private var cameraCellComputePipeline: (any MTLComputePipelineState)?

	func cameraCellComputePipelineState() throws -> any MTLComputePipelineState {
		if let cameraCellComputePipeline {
			return cameraCellComputePipeline
		}
		guard let function = library.makeFunction(name: "ditherCameraCellCompute") else {
			throw NSError(domain: "DitherMetal", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing Metal shader function: ditherCameraCellCompute"])
		}
		let pipeline = try device.makeComputePipelineState(function: function)
		cameraCellComputePipeline = pipeline
		return pipeline
	}

	func ditherPipelineState(fused: Bool) throws -> any MTLRenderPipelineState {
		if fused, let optimizedDitherPipeline {
			return optimizedDitherPipeline
		}
		if !fused, let referenceDitherPipeline {
			return referenceDitherPipeline
		}
		let pipeline = try renderPipeline(fragment: fused ? "ditherUpscaleOptimized" : "ditherUpscale", pixelFormat: .bgra8Unorm)
		if fused {
			optimizedDitherPipeline = pipeline
		} else {
			referenceDitherPipeline = pipeline
		}
		return pipeline
	}

	private var fractionalDitherPipeline: (any MTLRenderPipelineState)?

	func fractionalDitherPipelineState() throws -> any MTLRenderPipelineState {
		if let fractionalDitherPipeline {
			return fractionalDitherPipeline
		}
		let pipeline = try renderPipeline(fragment: "ditherUpscaleFractional", pixelFormat: .bgra8Unorm)
		fractionalDitherPipeline = pipeline
		return pipeline
	}

	func atlasDitherPipelineState() throws -> any MTLRenderPipelineState {
		if let atlasDitherPipeline {
			return atlasDitherPipeline
		}
		let pipeline = try renderPipeline(fragment: "ditherUpscaleAtlas", pixelFormat: .bgra8Unorm)
		atlasDitherPipeline = pipeline
		return pipeline
	}

	func coverageComputePipelineState() throws -> any MTLComputePipelineState {
		if let coverageComputePipeline {
			return coverageComputePipeline
		}
		guard let function = library.makeFunction(name: "ditherCoverageCompute") else {
			throw NSError(domain: "DitherMetal", code: 4)
		}
		let pipeline = try device.makeComputePipelineState(function: function)
		coverageComputePipeline = pipeline
		return pipeline
	}

	func joinMaskComputePipelineState() throws -> any MTLComputePipelineState {
		if let joinMaskComputePipeline {
			return joinMaskComputePipeline
		}
		guard let function = library.makeFunction(name: "ditherJoinMaskCompute") else {
			throw NSError(domain: "DitherMetal", code: 4)
		}
		let pipeline = try device.makeComputePipelineState(function: function)
		joinMaskComputePipeline = pipeline
		return pipeline
	}

	func blurCompositePipelineState() throws -> any MTLRenderPipelineState {
		if let blurCompositePipeline {
			return blurCompositePipeline
		}
		let pipeline = try renderPipeline(fragment: "ditherTopBlurComposite", pixelFormat: .bgra8Unorm)
		blurCompositePipeline = pipeline
		return pipeline
	}

	func cellBlurHorizontalPipelineState() throws -> any MTLComputePipelineState {
		if let cellBlurHorizontalPipeline {
			return cellBlurHorizontalPipeline
		}
		guard let function = library.makeFunction(name: "ditherCellBlurHorizontal") else {
			throw NSError(domain: "DitherMetal", code: 4)
		}
		let pipeline = try device.makeComputePipelineState(function: function)
		cellBlurHorizontalPipeline = pipeline
		return pipeline
	}

	func cellBlurCompositePipelineState() throws -> any MTLRenderPipelineState {
		if let cellBlurCompositePipeline {
			return cellBlurCompositePipeline
		}
		let pipeline = try renderPipeline(fragment: "ditherCellBlurComposite", pixelFormat: .bgra8Unorm)
		cellBlurCompositePipeline = pipeline
		return pipeline
	}

	func coverageTexture(for key: CoverageKey) -> any MTLTexture? {
		coverageTextures[key]
	}

	func publishCoverageTexture(_ texture: any MTLTexture, for key: CoverageKey) {
		if coverageTextures.count >= 8 {
			coverageTextures.removeAll(keepingCapacity: true)
		}
		coverageTextures[key] = texture
	}
}

@MainActor
final class DitherMetalRenderer {
	static let topBlurStripPoints: Float = 104
	nonisolated static let topBlurMaximumSigma: Float = 5
	static let topBlurGaussianSigmas: [Float] = [
		topBlurMaximumSigma * 0.1,
		topBlurMaximumSigma * 0.4,
		topBlurMaximumSigma,
	]
	static let topBlurDecayCoefficient: Float = 3

	struct RenderMetrics {
		let cpuElapsed: TimeInterval
		let gpuElapsed: TimeInterval?
		let renderPassCount: Int
		let computeDispatchCount: Int
		let gaussianEncodeCount: Int
	}

	let device: any MTLDevice
	private let queue: any MTLCommandQueue
	private let sharedResources: SharedMetalResources
	private let gradientTexture: any MTLTexture
	private var fieldTexture: any MTLTexture?
	private var cellTexture: any MTLTexture?
	private var joinMaskTexture: any MTLTexture?
	private let finalPassDescriptor = MTLRenderPassDescriptor()
	private let blurSourcePassDescriptor = MTLRenderPassDescriptor()
	private var fieldSize = MTLSize(width: 1, height: 1, depth: 1)
	private var time: Float = 0
	private var reveal: Float = 0
	private var animationTiming = DitherAnimationTiming()
	private var paletteBuffer: any MTLBuffer
	private var themePositions = [SIMD2<Float>](repeating: .zero, count: 8)
	private var themeColors = [SIMD3<Float>](repeating: .zero, count: 8)
	private var lastPalette: [SIMD3<Float>] = []
	private(set) var lastRenderMetrics: RenderMetrics?
	private let usesFusedFieldAndCellPass: Bool
	private let usesTopBlur: Bool
	private let blurScale: Float
	private let usesTwoDimensionalThreadgroups: Bool
	private let usesCellBlurFastPath: Bool
	private var topBlurResources: TopBlurResources?
	private var cellBlurResources: CellBlurResources?

	private struct TopBlurResources {
		let source: any MTLTexture
		let levels: [any MTLTexture]
		let kernels: [MPSImageGaussianBlur]
		let scale: Float
	}

	private struct CellBlurResources {
		let levels: [any MTLTexture]
		let horizontalWeights: [any MTLBuffer]
		let verticalWeights: [any MTLBuffer]
		let profile: any MTLBuffer
		let rowCount: Int
		let scale: Float
		let cell: Int
		let width: Int
		let stripHeight: Int
	}

	/// Swift serializes static initialization. Immutable Metal objects are shared;
	/// failed initialization remains a thrown error rather than terminating the app.
	private static let sharedResources = Result { try SharedMetalResources() }

	private let usesCoverageAtlas: Bool

	/// When set, the next frames dither this texture instead of the wave field.
	var camera: CameraFrameInput?

	init(
		usesFusedFieldAndCellPass: Bool = true,
		usesCoverageAtlas: Bool = true,
		usesTopBlur: Bool = true,
		blurScale: Float = 1,
		usesTwoDimensionalThreadgroups: Bool = true,
		usesCellBlurFastPath: Bool = true
	) throws {
		self.usesCoverageAtlas = usesCoverageAtlas
		self.usesFusedFieldAndCellPass = usesFusedFieldAndCellPass
		self.usesTopBlur = usesTopBlur
		self.blurScale = max(0.01, blurScale)
		self.usesTwoDimensionalThreadgroups = usesTwoDimensionalThreadgroups
		self.usesCellBlurFastPath = usesCellBlurFastPath
		guard MemoryLayout<FieldUniforms>.stride == 224,
		      MemoryLayout<DitherUniforms>.stride == 144,
		      MemoryLayout<CameraUniforms>.stride == 48
		else {
			throw NSError(domain: "DitherMetal", code: 12, userInfo: [NSLocalizedDescriptionKey: "Swift and Metal uniform layouts do not match"])
		}
		let resources = try Self.sharedResources.get()
		sharedResources = resources
		device = resources.device
		queue = resources.queue
		gradientTexture = resources.gradientTexture
		guard let paletteBuffer = device.makeBuffer(length: 8 * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared) else {
			throw NSError(domain: "DitherMetal", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not allocate palette buffer"])
		}
		self.paletteBuffer = paletteBuffer
	}

	func render(to drawable: any CAMetalDrawable, size: CGSize, configuration: DitherConfiguration, advance: Bool) throws {
		try render(to: drawable, size: size, configuration: configuration, inputs: .empty, advance: advance)
	}

	func render(to drawable: any CAMetalDrawable, size: CGSize, configuration: DitherConfiguration, inputs: DitherRenderInputs, advance: Bool) throws {
		let drawableWidth = drawable.texture.width
		let drawableHeight = drawable.texture.height
		let ratio = Float(drawableWidth) / max(Float(size.width), 1)
		let cell = max(1, Int(configuration.pixelSize * ratio))
		try render(to: drawable.texture, width: drawableWidth, height: drawableHeight, cell: cell, configuration: configuration, inputs: inputs, advance: advance, drawable: drawable, waitUntilCompleted: false, scale: ratio)
	}

	func render(to target: any MTLTexture, width: Int, height: Int, cell: Int, configuration: DitherConfiguration, advance: Bool = true, atTime: Float? = nil) throws {
		try render(to: target, width: width, height: height, cell: cell, configuration: configuration, inputs: .empty, advance: advance, atTime: atTime, drawable: nil, waitUntilCompleted: true, scale: blurScale)
	}

	func render(to target: any MTLTexture, width: Int, height: Int, cell: Int, configuration: DitherConfiguration, inputs: DitherRenderInputs, advance: Bool = true, atTime: Float? = nil) throws {
		try render(to: target, width: width, height: height, cell: cell, configuration: configuration, inputs: inputs, advance: advance, atTime: atTime, drawable: nil, waitUntilCompleted: true, scale: blurScale)
	}

	func render(to target: any MTLTexture, width: Int, height: Int, cell: Int, configuration: DitherConfiguration, scale: Float, advance: Bool = true, atTime: Float? = nil) throws {
		try render(to: target, width: width, height: height, cell: cell, configuration: configuration, inputs: .empty, advance: advance, atTime: atTime, drawable: nil, waitUntilCompleted: true, scale: scale)
	}

	func resetAnimationTiming() {
		animationTiming.reset()
	}

	func seedAnimationTiming() {
		animationTiming.seed(now: CACurrentMediaTime())
	}

	/// Where the wave is in its animation, so a photo can freeze the same moment
	var animationTime: Float {
		time
	}

	var isIntroComplete: Bool {
		reveal >= 1
	}

	var sharedGradientResourceIdentifier: ObjectIdentifier {
		ObjectIdentifier(gradientTexture)
	}

	static func topBlurSigma(at fraction: Float, maxSigma: Float = topBlurMaximumSigma) -> Float {
		let t = min(1, max(0, fraction))
		return max(0, maxSigma * exp(-topBlurDecayCoefficient * t) * pow(1 - t, 2))
	}

	static func topBlurStripPixels(scale: Float) -> Int {
		max(1, Int((topBlurStripPoints * max(0.01, scale)).rounded(.up)))
	}

	func restartIntro() {
		reveal = 0
	}

	private func render(to target: any MTLTexture, width: Int, height: Int, cell: Int, configuration: DitherConfiguration, inputs: DitherRenderInputs, advance: Bool, atTime: Float? = nil, drawable: any CAMetalDrawable?, waitUntilCompleted: Bool, scale: Float) throws {
		let cpuStart = CACurrentMediaTime()
		let delta = Float(animationTiming.advance(now: cpuStart, isAdvancing: advance))
		if advance && !configuration.disableAnimation && atTime == nil {
			time += delta
		}
		if let atTime {
			time = atTime
		}
		if configuration.intro {
			reveal = min(1, reveal + delta / 1.8)
		} else {
			reveal = 1
		}
		guard width > 0, height > 0, width <= 16384, height <= 16384 else {
			throw NSError(domain: "DitherMetal", code: 6, userInfo: [NSLocalizedDescriptionKey: "Dither drawable size is outside supported bounds"])
		}
		// The camera sets its own cell, in fractional pixels, so its whole frame always fills the output
		let exactCell = camera?.exactCell(outputWidth: width, outputHeight: height)
		let cell = max(1, min(exactCell.map { Int($0) } ?? cell, width, height))
		let columns = exactCell.map { max(1, Int((Float(width) / $0).rounded(.up))) } ?? max(1, width / cell)
		let rows = exactCell.map { max(1, Int((Float(height) / $0).rounded(.up))) } ?? max(1, height / cell)
		if cellTexture == nil || fieldSize.width != columns || fieldSize.height != rows {
			if !usesFusedFieldAndCellPass {
				let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: columns, height: rows, mipmapped: false)
				descriptor.usage = [.renderTarget, .shaderRead]
				descriptor.storageMode = .private
				fieldTexture = device.makeTexture(descriptor: descriptor)
			}
			let cellDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: columns, height: rows, mipmapped: false)
			cellDescriptor.usage = usesFusedFieldAndCellPass ? [.shaderRead, .shaderWrite] : [.renderTarget, .shaderRead]
			cellDescriptor.storageMode = .private
			cellTexture = device.makeTexture(descriptor: cellDescriptor)
			joinMaskTexture = nil
			fieldSize = MTLSize(width: columns, height: rows, depth: 1)
		}
		guard let cellTexture else {
			throw NSError(domain: "DitherMetal", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not allocate field texture"])
		}
		func trailSample(_ index: Int) -> SIMD3<Float> {
			guard configuration.cursorInteractionEnabled,
			      !configuration.disableAnimation,
			      index < inputs.cursorTrail.count
			else {
				return .zero
			}
			let sample = inputs.cursorTrail[index]
			return SIMD3<Float>(sample.x * scale, sample.y * scale, sample.z)
		}
		var field = FieldUniforms(
			resolution: SIMD2<Float>(Float(columns * cell), Float(rows * cell)),
			cell: Float(cell),
			time: time,
			waveSpeed: max(0, configuration.waveSpeed),
			waveDirection: DitherConfiguration.waveDirectionVector(for: configuration.waveDirection),
			waveFrequency: configuration.waveFrequency,
			waveAmplitude: configuration.waveAmplitude,
			scale: max(0.05, configuration.scale),
			contrast: configuration.contrast,
			brightness: configuration.brightness,
			intro: reveal,
			reach: 1.5,
			cursorPosition: inputs.cursorTrail.first.map { SIMD2<Float>($0.x, $0.y) } ?? .zero,
			cursorRadius: Float(configuration.cursorRadius),
			cursorStrength: Float(configuration.cursorStrength),
			cursorWarp: Float(configuration.cursorWarp),
			cursorPresence: configuration.cursorInteractionEnabled && !configuration.disableAnimation ? inputs.cursorPresence : 0,
			cursorTouch: inputs.cursorTouch * scale,
			trail0: trailSample(0),
			trail1: trailSample(1),
			trail2: trailSample(2),
			trail3: trailSample(3),
			trail4: trailSample(4),
			trail5: trailSample(5),
			trail6: trailSample(6),
			trail7: trailSample(7)
		)
		let effectiveBackground: SIMD3<Float> = switch configuration.backgroundStyle {
			case "black": .zero
			case "white": SIMD3<Float>(repeating: 1)
			case "dim": configuration.waveColor * 0.2
			default: configuration.backgroundColor
		}
		let effectiveWave: SIMD3<Float> = configuration.colorPlacement == "background"
			? (configuration.squareStyle == "black" ? .zero : SIMD3<Float>(repeating: 1))
			: configuration.waveColor
		let backgroundStyle: Int32 = switch configuration.backgroundStyle {
			case "black": 1
			case "white": 2
			case "dim": 3
			default: 0
		}
		var dither = DitherUniforms(
			fieldSize: SIMD2<Int32>(Int32(columns), Int32(rows)),
			cellDevice: exactCell ?? Float(cell),
			mode: Int32(configuration.ditherMode),
			colorNum: max(2, configuration.colorNum),
			ditherStrength: min(1, max(0, configuration.ditherStrength)),
			wave: effectiveWave,
			background: configuration.colorPlacement == "background" ? configuration.waveColor : effectiveBackground,
			paletteCount: configuration.colorPlacement == "background"
				? 0
				: Int32(min(DitherConfiguration.supportedPaletteCount, configuration.useThemeColors ? inputs.themeColors.count : configuration.palette.count)),
			transparent: configuration.transparent ? 1 : 0,
			gap: min(0.45, max(0, configuration.gap)),
			cornerRadius: min(0.5, max(0, configuration.cornerRadius)),
			joinAdjacentSquares: configuration.joinAdjacentSquares ? 1 : 0,
			viewportSize: SIMD2<Int32>(Int32(width), Int32(height)),
			themeCount: Int32(min(DitherConfiguration.supportedPaletteCount, inputs.themeColors.count)),
			useThemeColors: configuration.useThemeColors ? 1 : 0,
			colorPlacement: configuration.colorPlacement == "background" ? 1 : 0,
			backgroundStyle: backgroundStyle,
			squareStyle: configuration.squareStyle == "black" ? 1 : 0,
			cursorPresence: inputs.cursorPresence,
			screenOrigin: inputs.screenOrigin * scale,
			screenSize: inputs.screenSize * scale,
			screenCornerRadius: configuration.clipsToDeviceCorners ? inputs.screenCornerRadius * scale : 0
		)
		for index in 0 ..< 8 {
			themePositions[index] = index < inputs.themePositions.count ? inputs.themePositions[index] : .zero
			themeColors[index] = index < inputs.themeColors.count ? inputs.themeColors[index] : .zero
		}
		let palette = configuration.useThemeColors ? inputs.themeColors : configuration.palette
		if palette != lastPalette {
			var paletteData = [SIMD3<Float>](repeating: SIMD3<Float>(), count: DitherConfiguration.supportedPaletteCount)
			for (index, color) in palette.prefix(DitherConfiguration.supportedPaletteCount).enumerated() {
				paletteData[index] = color
			}
			guard let replacement = paletteData.withUnsafeBytes({ bytes in
				guard let baseAddress = bytes.baseAddress else {
					return nil as any MTLBuffer?
				}
				return unsafe device.makeBuffer(bytes: baseAddress, length: bytes.count, options: .storageModeShared)
			}) else {
				throw NSError(domain: "DitherMetal", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not allocate palette buffer"])
			}
			paletteBuffer = replacement
			lastPalette = palette
		}
		guard let commandBuffer = queue.makeCommandBuffer() else {
			throw NSError(domain: "DitherMetal", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not create Metal command buffer"])
		}
		var renderPassCount = 0
		var computeDispatchCount = 0
		var gaussianEncodeCount = 0
		var fusedComputeEncoder: any MTLComputeCommandEncoder?
		defer {
			fusedComputeEncoder?.endEncoding()
		}
		if usesFusedFieldAndCellPass {
			guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
				throw NSError(domain: "DitherMetal", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not create fused field and cell compute encoder"])
			}
			fusedComputeEncoder = computeEncoder
			let pipeline = try camera == nil
				? sharedResources.fusedCellComputePipelineState()
				: sharedResources.cameraCellComputePipelineState()
			computeEncoder.setComputePipelineState(pipeline)
			computeEncoder.setTexture(cellTexture, index: 0)
			computeEncoder.setTexture(gradientTexture, index: 1)
			if let camera {
				var cameraUniforms = camera.uniforms(columns: columns, rows: rows)
				computeEncoder.setTexture(camera.texture, index: 2)
				unsafe computeEncoder.setBytes(&cameraUniforms, length: MemoryLayout<CameraUniforms>.stride, index: 5)
			}
			unsafe computeEncoder.setBytes(&field, length: MemoryLayout<FieldUniforms>.stride, index: 0)
			unsafe computeEncoder.setBytes(&dither, length: MemoryLayout<DitherUniforms>.stride, index: 1)
			computeEncoder.setBuffer(paletteBuffer, offset: 0, index: 2)
			themePositions.withUnsafeBytes { bytes in
				unsafe computeEncoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 3)
			}
			themeColors.withUnsafeBytes { bytes in
				unsafe computeEncoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 4)
			}
			dispatch(
				computeEncoder,
				width: columns,
				height: rows,
				pipeline: pipeline,
				usesTwoDimensionalThreadgroups: usesTwoDimensionalThreadgroups
			)
			computeDispatchCount += 1
		} else {
			guard let fieldTexture else {
				throw NSError(domain: "DitherMetal", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not allocate field texture"])
			}
			let fieldPass = MTLRenderPassDescriptor()
			fieldPass.colorAttachments[0].texture = fieldTexture
			fieldPass.colorAttachments[0].loadAction = .dontCare
			fieldPass.colorAttachments[0].storeAction = .store
			let fieldPipeline = try sharedResources.fieldPipelineState()
			guard let fieldEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: fieldPass) else {
				throw NSError(domain: "DitherMetal", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not create field encoder"])
			}
			fieldEncoder.setRenderPipelineState(fieldPipeline)
			unsafe fieldEncoder.setFragmentBytes(&field, length: MemoryLayout<FieldUniforms>.stride, index: 0)
			fieldEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
			fieldEncoder.endEncoding()
			renderPassCount += 1
			let cellPass = MTLRenderPassDescriptor()
			cellPass.colorAttachments[0].texture = cellTexture
			cellPass.colorAttachments[0].loadAction = .dontCare
			cellPass.colorAttachments[0].storeAction = .store
			let cellPipeline = try sharedResources.cellPipelineState()
			guard let cellEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: cellPass) else {
				throw NSError(domain: "DitherMetal", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not create cell encoder"])
			}
			cellEncoder.setRenderPipelineState(cellPipeline)
			cellEncoder.setFragmentTexture(fieldTexture, index: 0)
			unsafe cellEncoder.setFragmentBytes(&dither, length: MemoryLayout<DitherUniforms>.stride, index: 0)
			cellEncoder.setFragmentBuffer(paletteBuffer, offset: 0, index: 1)
			themePositions.withUnsafeBytes { bytes in
				unsafe cellEncoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 2)
			}
			themeColors.withUnsafeBytes { bytes in
				unsafe cellEncoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 3)
			}
			cellEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
			cellEncoder.endEncoding()
			renderPassCount += 1
		}
		var coverageTexture: any MTLTexture?
		var newCoverageKey: CoverageKey?
		if exactCell == nil && usesFusedFieldAndCellPass && usesCoverageAtlas && cell <= 128 && (dither.gap > 0 || dither.cornerRadius > 0) {
			let key = CoverageKey(cell: cell, gap: dither.gap, radius: dither.cornerRadius)
			if let cached = sharedResources.coverageTexture(for: key) {
				coverageTexture = cached
			} else {
				let resources = try Self.sharedResources.get()
				let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: cell, height: cell * (dither.gap > 0 ? 1 : 16), mipmapped: false)
				descriptor.storageMode = .private
				descriptor.usage = [.shaderRead, .shaderWrite]
				guard let texture = device.makeTexture(descriptor: descriptor), let computeEncoder = fusedComputeEncoder else {
					throw NSError(domain: "DitherMetal", code: 14)
				}
				let pipeline = try resources.coverageComputePipelineState()
				computeEncoder.setComputePipelineState(pipeline)
				computeEncoder.setTexture(texture, index: 0)
				unsafe computeEncoder.setBytes(&dither, length: MemoryLayout<DitherUniforms>.stride, index: 0)
				dispatch(
					computeEncoder,
					width: cell,
					height: texture.height,
					pipeline: pipeline
				)
				computeDispatchCount += 1
				newCoverageKey = key
				coverageTexture = texture
			}
		}
		if coverageTexture != nil && dither.joinAdjacentSquares > 0 && dither.gap == 0 && dither.cornerRadius > 0 {
			if joinMaskTexture == nil {
				let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(
					pixelFormat: .r8Uint,
					width: columns,
					height: rows,
					mipmapped: false
				)
				maskDescriptor.storageMode = .private
				maskDescriptor.usage = [.shaderRead, .shaderWrite]
				joinMaskTexture = device.makeTexture(descriptor: maskDescriptor)
			}
			guard let joinMaskTexture, let encoder = fusedComputeEncoder else {
				throw NSError(domain: "DitherMetal", code: 15)
			}
			let resources = try Self.sharedResources.get()
			encoder.memoryBarrier(scope: .textures)
			let pipeline = try resources.joinMaskComputePipelineState()
			encoder.setComputePipelineState(pipeline)
			encoder.setTexture(cellTexture, index: 0)
			encoder.setTexture(joinMaskTexture, index: 1)
			unsafe encoder.setBytes(&dither, length: MemoryLayout<DitherUniforms>.stride, index: 0)
			dispatch(
				encoder,
				width: columns,
				height: rows,
				pipeline: pipeline,
				usesTwoDimensionalThreadgroups: usesTwoDimensionalThreadgroups
			)
			computeDispatchCount += 1
		}
		fusedComputeEncoder?.endEncoding()
		fusedComputeEncoder = nil
		let usesCellBlur = usesTopBlur && usesCellBlurFastPath && canUseCellBlurFastPath(
			width: width,
			height: height,
			cell: cell,
			configuration: configuration,
			scale: scale
		)
		if usesTopBlur {
			if usesCellBlur {
				try encodeCellBlur(
					commandBuffer: commandBuffer,
					width: width,
					height: height,
					cell: cell,
					scale: scale,
					dither: dither
				)
			} else {
				try encodeTopBlur(
					commandBuffer: commandBuffer,
					width: width,
					height: height,
					scale: scale,
					dither: dither,
					coverageTexture: coverageTexture,
					joinMaskTexture: joinMaskTexture,
					paletteBuffer: paletteBuffer
				)
			}
			if usesCellBlur {
				computeDispatchCount += Self.topBlurGaussianSigmas.count
			} else {
				renderPassCount += 1
				gaussianEncodeCount = Self.topBlurGaussianSigmas.count
			}
		}
		let finalPass = finalPassDescriptor
		finalPass.colorAttachments[0].texture = target
		defer {
			finalPass.colorAttachments[0].texture = nil
		}
		finalPass.colorAttachments[0].loadAction = usesFusedFieldAndCellPass ? .dontCare : .clear
		finalPass.colorAttachments[0].storeAction = .store
		finalPass.colorAttachments[0].clearColor = MTLClearColor(red: Double(effectiveBackground.x), green: Double(effectiveBackground.y), blue: Double(effectiveBackground.z), alpha: 1)
		guard let finalEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: finalPass) else {
			throw NSError(domain: "DitherMetal", code: 9, userInfo: [NSLocalizedDescriptionKey: "Could not create composite encoder"])
		}
		var finalEncodingEnded = false
		defer {
			if !finalEncodingEnded {
				finalEncoder.endEncoding()
			}
		}
		renderPassCount += 1
		if let coverageTexture {
			try finalEncoder.setRenderPipelineState(sharedResources.atlasDitherPipelineState())
			finalEncoder.setFragmentTexture(coverageTexture, index: 1)
			finalEncoder.setFragmentTexture(joinMaskTexture, index: 2)
		} else {
			try finalEncoder.setRenderPipelineState(exactCell == nil
				? sharedResources.ditherPipelineState(fused: usesFusedFieldAndCellPass)
				: sharedResources.fractionalDitherPipelineState())
		}
		finalEncoder.setFragmentTexture(cellTexture, index: 0)
		unsafe finalEncoder.setFragmentBytes(&dither, length: MemoryLayout<DitherUniforms>.stride, index: 0)
		finalEncoder.setFragmentBuffer(paletteBuffer, offset: 0, index: 1)
		themePositions.withUnsafeBytes { bytes in
			unsafe finalEncoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 2)
		}
		themeColors.withUnsafeBytes { bytes in
			unsafe finalEncoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 3)
		}
		let stripHeight = usesTopBlur ? min(height, Self.topBlurStripPixels(scale: scale)) : 0
		if stripHeight < height {
			finalEncoder.setScissorRect(MTLScissorRect(x: 0, y: stripHeight, width: width, height: height - stripHeight))
			finalEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
		}
		if usesCellBlur {
			try encodeCellBlurComposite(encoder: finalEncoder, width: width, stripHeight: stripHeight, cell: cell, dither: dither)
		} else if usesTopBlur {
			try encodeTopBlurComposite(encoder: finalEncoder, width: width, stripHeight: stripHeight, scale: scale)
		}
		finalEncoder.endEncoding()
		finalEncodingEnded = true
		if let drawable {
			commandBuffer.present(drawable)
		}
		if let retained = camera?.retained {
			// The texture belongs to a CVMetalTexture; it must outlive the GPU work.
			commandBuffer.addCompletedHandler { _ in
				withExtendedLifetime(retained) {}
			}
		}
		commandBuffer.commit()
		// Publish only after submission: a failed encoder must not leave an
		// uninitialized atlas in the cache for the next frame.
		if let newCoverageKey, let coverageTexture {
			sharedResources.publishCoverageTexture(coverageTexture, for: newCoverageKey)
		}
		let submissionElapsed = CACurrentMediaTime() - cpuStart
		if waitUntilCompleted {
			commandBuffer.waitUntilCompleted()
			if let error = commandBuffer.error {
				throw error
			}
			let gpuElapsed = commandBuffer.gpuStartTime > 0 && commandBuffer.gpuEndTime > commandBuffer.gpuStartTime
				? commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
				: nil
			lastRenderMetrics = RenderMetrics(
				cpuElapsed: submissionElapsed,
				gpuElapsed: gpuElapsed,
				renderPassCount: renderPassCount,
				computeDispatchCount: computeDispatchCount,
				gaussianEncodeCount: gaussianEncodeCount
			)
		}
	}

	private func dispatch(
		_ encoder: any MTLComputeCommandEncoder,
		width: Int,
		height: Int,
		pipeline: any MTLComputePipelineState,
		usesTwoDimensionalThreadgroups: Bool = false
	) {
		let threadgroupWidth = min(pipeline.threadExecutionWidth, width)
		let threadgroupHeight: Int = if usesTwoDimensionalThreadgroups {
			min(
				8,
				pipeline.maxTotalThreadsPerThreadgroup / threadgroupWidth,
				height
			)
		} else {
			1
		}

		let threads = MTLSize(
			width: threadgroupWidth,
			height: threadgroupHeight,
			depth: 1
		)
		let groups = MTLSize(
			width: (width + threadgroupWidth - 1) / threadgroupWidth,
			height: (height + threadgroupHeight - 1) / threadgroupHeight,
			depth: 1
		)
		encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
	}

	private func encodeTopBlur(
		commandBuffer: any MTLCommandBuffer,
		width: Int,
		height: Int,
		scale: Float,
		dither: DitherUniforms,
		coverageTexture: any MTLTexture?,
		joinMaskTexture: any MTLTexture?,
		paletteBuffer: any MTLBuffer
	) throws {
		let stripHeight = min(height, Self.topBlurStripPixels(scale: scale))
		let maxSigma = Self.topBlurMaximumSigma * max(0.01, scale)
		let padding = max(1, Int(ceil(maxSigma * 3)))
		let sourceHeight = min(height, stripHeight + padding)
		let scaleChanged = topBlurResources?.scale != scale
		if topBlurResources == nil || topBlurResources?.source.width != width || topBlurResources?.source.height != sourceHeight || scaleChanged {
			let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: sourceHeight, mipmapped: false)
			descriptor.storageMode = .private
			descriptor.usage = [.renderTarget, .shaderRead]
			guard let source = device.makeTexture(descriptor: descriptor) else {
				throw NSError(domain: "DitherMetal", code: 16, userInfo: [NSLocalizedDescriptionKey: "Could not allocate top blur source"])
			}
			// Each level is sampled only while sigma exceeds the previous level.
			// Crop destination height instead of blurring every level across the strip.
			let sigmas = Self.topBlurGaussianSigmas
			descriptor.pixelFormat = .rgba16Float
			var levels: [any MTLTexture] = []
			for index in sigmas.indices {
				let minimumSigma: Float = index == 0 ? 0 : sigmas[index - 1]
				var contributingRows = stripHeight
				while contributingRows > 1, Self.topBlurSigma(at: Float(contributingRows - 1) / Float(Self.topBlurStripPixels(scale: scale))) <= minimumSigma {
					contributingRows -= 1
				}
				// Bilinear sampling needs the row just beyond the last contribution.
				descriptor.height = min(sourceHeight, contributingRows + 1)
				guard let level = device.makeTexture(descriptor: descriptor) else {
					throw NSError(domain: "DitherMetal", code: 16, userInfo: [NSLocalizedDescriptionKey: "Could not allocate top blur level"])
				}
				levels.append(level)
			}
			topBlurResources = TopBlurResources(
				source: source,
				levels: levels,
				kernels: sigmas.map {
					let kernel = MPSImageGaussianBlur(device: device, sigma: $0 * max(0.01, scale))
					kernel.edgeMode = .clamp
					return kernel
				},
				scale: scale
			)
		}
		guard let resources = topBlurResources else {
			return
		}
		var sourceDither = dither
		let sourcePass = blurSourcePassDescriptor
		sourcePass.colorAttachments[0].texture = resources.source
		sourcePass.colorAttachments[0].loadAction = .dontCare
		sourcePass.colorAttachments[0].storeAction = .store
		let sourcePipeline = try coverageTexture == nil
			? sharedResources.ditherPipelineState(fused: usesFusedFieldAndCellPass)
			: sharedResources.atlasDitherPipelineState()
		guard let sourceEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: sourcePass) else {
			throw NSError(domain: "DitherMetal", code: 17, userInfo: [NSLocalizedDescriptionKey: "Could not create top blur source encoder"])
		}
		sourceEncoder.setRenderPipelineState(sourcePipeline)
		sourceEncoder.setFragmentTexture(cellTexture, index: 0)
		if let coverageTexture {
			sourceEncoder.setFragmentTexture(coverageTexture, index: 1)
			sourceEncoder.setFragmentTexture(joinMaskTexture, index: 2)
		}
		unsafe sourceEncoder.setFragmentBytes(&sourceDither, length: MemoryLayout<DitherUniforms>.stride, index: 0)
		sourceEncoder.setFragmentBuffer(paletteBuffer, offset: 0, index: 1)
		themePositions.withUnsafeBytes { bytes in
			unsafe sourceEncoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 2)
		}
		themeColors.withUnsafeBytes { bytes in
			unsafe sourceEncoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 3)
		}
		sourceEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
		sourceEncoder.endEncoding()
		for (kernel, level) in zip(resources.kernels, resources.levels) {
			kernel.encode(commandBuffer: commandBuffer, sourceTexture: resources.source, destinationTexture: level)
		}
	}

	private func canUseCellBlurFastPath(
		width: Int,
		height: Int,
		cell: Int,
		configuration: DitherConfiguration,
		scale: Float
	) -> Bool {
		guard usesFusedFieldAndCellPass,
		      cell >= 4,
		      cell <= 128,
		      scale == 1 || scale == 2,
		      configuration.gap == 0,
		      configuration.cornerRadius == 0,
		      width.isMultiple(of: cell),
		      height.isMultiple(of: cell)
		else {
			return false
		}
		let stripHeight = Self.topBlurStripPixels(scale: scale)
		let halo = Int(ceil(Self.topBlurMaximumSigma * max(0.01, scale) * 3))
		return height >= stripHeight + halo
	}

	private func encodeCellBlur(
		commandBuffer: any MTLCommandBuffer,
		width: Int,
		height: Int,
		cell: Int,
		scale: Float,
		dither: DitherUniforms
	) throws {
		let stripHeight = min(height, Self.topBlurStripPixels(scale: scale))
		let sigmas = Self.topBlurGaussianSigmas.map { $0 * max(0.01, scale) }
		let radii = sigmas.map { Int(ceil($0 * 3)) }
		let rowCount = min(height / cell, Int(ceil(Double(stripHeight + radii[2]) / Double(cell))) + 1)
		let keyChanged = cellBlurResources == nil
			|| cellBlurResources?.width != width
			|| cellBlurResources?.cell != cell
			|| cellBlurResources?.scale != scale
			|| cellBlurResources?.stripHeight != stripHeight
			|| cellBlurResources?.rowCount != rowCount
		if keyChanged {
			var levels: [any MTLTexture] = []
			var horizontalWeights: [any MTLBuffer] = []
			var verticalWeights: [any MTLBuffer] = []
			for level in sigmas.indices {
				let descriptor = MTLTextureDescriptor.texture2DDescriptor(
					pixelFormat: .rgba16Float,
					width: width,
					height: rowCount,
					mipmapped: false
				)
				descriptor.storageMode = .private
				descriptor.usage = [.shaderRead, .shaderWrite]
				guard let texture = device.makeTexture(descriptor: descriptor) else {
					throw NSError(domain: "DitherMetal", code: 18, userInfo: [NSLocalizedDescriptionKey: "Could not allocate cell blur level"])
				}
				levels.append(texture)
				let cellRadius = Int(ceil(Double(radii[level]) / Double(cell))) + 1
				let pixelWeights = try gaussianWeights(sigma: sigmas[level], radius: radii[level])
				let horizontal = cellIntervalWeights(
					sigma: sigmas[level],
					radius: radii[level],
					cell: cell,
					cellRadius: cellRadius,
					pixelWeights: pixelWeights
				)
				guard let horizontalBuffer = horizontal.withUnsafeBytes({ bytes in
					unsafe device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
				}) else {
					throw NSError(domain: "DitherMetal", code: 18, userInfo: [NSLocalizedDescriptionKey: "Could not allocate cell blur weights"])
				}
				horizontalWeights.append(horizontalBuffer)
				var vertical = [Float](repeating: 0, count: stripHeight * rowCount)
				for y in 0 ..< stripHeight {
					var total: Float = 0
					for offset in -radii[level] ... radii[level] {
						let sample = min(height - 1, max(0, y + offset))
						let row = sample / cell
						let weight = pixelWeights[offset + radii[level]]
						vertical[y * rowCount + row] += weight
						total += weight
					}
					if total > 0 {
						for row in 0 ..< rowCount {
							vertical[y * rowCount + row] /= total
						}
					}
				}
				guard let verticalBuffer = vertical.withUnsafeBytes({ bytes in
					unsafe device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
				}) else {
					throw NSError(domain: "DitherMetal", code: 18, userInfo: [NSLocalizedDescriptionKey: "Could not allocate cell blur vertical weights"])
				}
				verticalWeights.append(verticalBuffer)
			}
			let profile = (0 ..< stripHeight).map { y in
				Self.topBlurSigma(at: (Float(y) + 0.5) / Float(Self.topBlurStripPixels(scale: scale)))
			}
			guard let profileBuffer = profile.withUnsafeBytes({ bytes in
				unsafe device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
			}) else {
				throw NSError(domain: "DitherMetal", code: 18, userInfo: [NSLocalizedDescriptionKey: "Could not allocate cell blur profile"])
			}
			cellBlurResources = CellBlurResources(
				levels: levels,
				horizontalWeights: horizontalWeights,
				verticalWeights: verticalWeights,
				profile: profileBuffer,
				rowCount: rowCount,
				scale: scale,
				cell: cell,
				width: width,
				stripHeight: stripHeight
			)
		}
		let horizontalPipeline = try sharedResources.cellBlurHorizontalPipelineState()
		guard let resources = cellBlurResources,
		      let encoder = commandBuffer.makeComputeCommandEncoder()
		else {
			throw NSError(domain: "DitherMetal", code: 18, userInfo: [NSLocalizedDescriptionKey: "Could not create cell blur encoder"])
		}
		var uniforms = CellBlurUniforms(
			width: Int32(width),
			cellSize: Int32(cell),
			sourceRows: Int32(resources.rowCount),
			radius: 0,
			cellRadius: 0,
			phaseCount: Int32(cell),
			weightStride: 0
		)
		var sourceDither = dither
		encoder.setComputePipelineState(horizontalPipeline)
		encoder.setTexture(cellTexture, index: 0)
		unsafe encoder.setBytes(&sourceDither, length: MemoryLayout<DitherUniforms>.stride, index: 0)
		for level in sigmas.indices {
			uniforms.radius = Int32(radii[level])
			uniforms.cellRadius = Int32(ceil(Double(radii[level]) / Double(cell)) + 1)
			uniforms.weightStride = uniforms.cellRadius * 2 + 1
			encoder.setTexture(resources.levels[level], index: 1)
			encoder.setBuffer(resources.horizontalWeights[level], offset: 0, index: 1)
			unsafe encoder.setBytes(&uniforms, length: MemoryLayout<CellBlurUniforms>.stride, index: 2)
			dispatch(
				encoder,
				width: cell == 4 ? width / 4 : width,
				height: resources.rowCount,
				pipeline: horizontalPipeline,
				usesTwoDimensionalThreadgroups: true
			)
		}
		encoder.endEncoding()
	}

	private func encodeCellBlurComposite(encoder: any MTLRenderCommandEncoder, width: Int, stripHeight: Int, cell: Int, dither: DitherUniforms) throws {
		guard let resources = cellBlurResources else {
			return
		}
		var uniforms = CellBlurCompositeUniforms(
			stripHeight: Int32(stripHeight),
			cellSize: Int32(cell),
			rowCount: Int32(resources.rowCount),
			width: Int32(width),
			transparent: 0,
			scale: resources.scale,
			background: dither.background
		)
		uniforms.transparent = dither.transparent
		encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(stripHeight), znear: 0, zfar: 1))
		encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: stripHeight))
		try encoder.setRenderPipelineState(sharedResources.cellBlurCompositePipelineState())
		for index in resources.levels.indices {
			encoder.setFragmentTexture(resources.levels[index], index: index)
			encoder.setFragmentBuffer(resources.verticalWeights[index], offset: 0, index: index)
		}
		encoder.setFragmentTexture(cellTexture, index: 3)
		encoder.setFragmentBuffer(resources.profile, offset: 0, index: 3)
		unsafe encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CellBlurCompositeUniforms>.stride, index: 4)
		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
	}

	private func gaussianWeights(sigma: Float, radius: Int) throws -> [Float] {
		guard sigma > 0 else {
			return [1]
		}
		// MPS uses a different compact kernel for small radii. Recover it once
		// per resource configuration, outside the recurring render path.
		if sigma <= 2 {
			let side = max(65, radius * 2 + 3)
			let center = side / 2
			let descriptor = MTLTextureDescriptor.texture2DDescriptor(
				pixelFormat: .rgba32Float,
				width: side,
				height: 1,
				mipmapped: false
			)
			descriptor.storageMode = .shared
			descriptor.usage = [.shaderRead, .shaderWrite]
			guard let source = device.makeTexture(descriptor: descriptor),
			      let destination = device.makeTexture(descriptor: descriptor),
			      let command = queue.makeCommandBuffer()
			else {
				throw NSError(domain: "DitherMetal", code: 18)
			}
			var pixels = [Float](repeating: 0, count: side * 4)
			for channel in 0 ..< 4 {
				pixels[center * 4 + channel] = 1
			}
			pixels.withUnsafeBytes {
				unsafe source.replace(region: MTLRegionMake2D(0, 0, side, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: side * 16)
			}
			let kernel = MPSImageGaussianBlur(device: device, sigma: sigma)
			kernel.edgeMode = .clamp
			kernel.encode(commandBuffer: command, sourceTexture: source, destinationTexture: destination)
			command.commit()
			command.waitUntilCompleted()
			if let error = command.error {
				throw error
			}
			pixels.withUnsafeMutableBytes {
				unsafe destination.getBytes($0.baseAddress!, bytesPerRow: side * 16, from: MTLRegionMake2D(0, 0, side, 1), mipmapLevel: 0)
			}
			let weights = (-radius ... radius).map { pixels[(center + $0) * 4] }
			let sum = weights.reduce(0, +)
			return weights.map { $0 / sum }
		}
		var weights = (-radius ... radius).map { offset in
			exp(-0.5 * pow(Float(offset) / sigma, 2))
		}
		let sum = weights.reduce(0, +)
		if sum > 0 {
			weights = weights.map { $0 / sum }
		}
		return weights
	}

	private func cellIntervalWeights(sigma _: Float, radius: Int, cell: Int, cellRadius: Int, pixelWeights: [Float]) -> [Float] {
		var result = [Float](repeating: 0, count: cell * (cellRadius * 2 + 1))
		for phase in 0 ..< cell {
			for offset in -radius ... radius {
				let samplePosition = phase + offset
				let cellOffset: Int = if samplePosition >= 0 {
					samplePosition / cell
				} else {
					-(((-samplePosition) + cell - 1) / cell)
				}
				result[phase * (cellRadius * 2 + 1) + cellOffset + cellRadius] += pixelWeights[offset + radius]
			}
		}
		return result
	}

	private func encodeTopBlurComposite(encoder: any MTLRenderCommandEncoder, width: Int, stripHeight: Int, scale: Float) throws {
		guard let resources = topBlurResources else {
			return
		}
		var uniforms = TopBlurUniforms(stripHeight: Float(Self.topBlurStripPixels(scale: scale)))
		encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(stripHeight), znear: 0, zfar: 1))
		encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: stripHeight))
		try encoder.setRenderPipelineState(sharedResources.blurCompositePipelineState())
		encoder.setFragmentTexture(resources.source, index: 0)
		for (index, level) in resources.levels.enumerated() {
			encoder.setFragmentTexture(level, index: index + 1)
		}
		unsafe encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TopBlurUniforms>.stride, index: 0)
		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
	}
}
