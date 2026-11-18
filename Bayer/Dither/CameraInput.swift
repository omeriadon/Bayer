import Foundation
import Metal
import simd

/// Settings that only exist because the field comes from a camera. Everything else is `DitherConfiguration`.
nonisolated struct CameraSettings: Equatable, Sendable, Codable {
	enum Mapping: Int, CaseIterable, Codable, Sendable {
		/// Brightness picks the palette colour and how strongly it shows over the gap colour
		case blend = 0
		/// Every cell is exactly one palette colour, darkest first
		case exact = 1
		/// The camera's own colours, each channel dithered to `colorNum` levels
		case source = 2

		var title: String {
			switch self {
				case .blend: "Blend"
				case .exact: "Exact"
				case .source: "Source"
			}
		}
	}

	/// What the picture is made from. The top-left button steps through these.
	enum Source: Int, CaseIterable, Codable, Sendable {
		/// The camera's colour image
		case camera = 0
		/// No camera at all: Ergo's wave field, for wallpapers
		case wave = 1
		/// The LiDAR scanner's depth, near bright and far dark. Only on devices that have one.
		case depth = 2

		var title: String {
			switch self {
				case .camera: "CAM"
				case .wave: "DITHER"
				case .depth: "LIDAR"
			}
		}
	}

	var mapping = Mapping.exact
	var invert = false
	var usesFrontCamera = false
	var source = Source.camera
	/// As people say it: 0.5×, 1×, 2×. The lens does it on iPhone and iPad, the shader on the Mac.
	var zoom = 1.0
	/// Camera pixels along one side of a cell: 1 is 1:1, 2 is 1:4, 3 is 1:9.
	/// Every cell is the exact average of its own block, so cells always land on camera pixels.
	var texelsPerCell = 10
	/// The same for LiDAR, kept apart because its depth map is only a few hundred pixels across
	var depthTexelsPerCell = 2
	/// LiDAR's tone range in metres: `depthNear` and closer is the brightest colour, `depthFar` and beyond the darkest
	var depthNear: Float = 0.25
	var depthFar: Float = 5

	static let depthNearSteps: [Float] = [0.1, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1, 1.5, 2, 3]
	/// The scanner reads to about 5 m
	static let depthFarSteps: [Float] = [0.5, 0.75, 1, 1.5, 2, 2.5, 3, 4, 5]

	/// Near and far, kept apart so the tones never collapse into one colour
	var depthRange: ClosedRange<Float> {
		let near = min(max(depthNear.isFinite ? depthNear : 0.25, 0.05), 4)
		let far = min(max(depthFar.isFinite ? depthFar : 5, near * 1.5), 8)
		return near ... far
	}

	/// The cell size for whatever's showing now
	var cellTexels: Int {
		get { source == .depth ? depthTexelsPerCell : texelsPerCell }
		set {
			if source == .depth {
				depthTexelsPerCell = newValue
			} else {
				texelsPerCell = newValue
			}
		}
	}

	/// A capture session is feeding frames: the camera, or the LiDAR scanner. False for the wave,
	/// which fully disconnects the camera.
	var usesCamera: Bool {
		source != .wave
	}

	init() {}
	static let texelRange = 1 ... 32
	/// Every size up close, then fewer as cells get big
	static let texelSteps = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 32]
	/// LiDAR's map is small, so past 8 there'd only be a handful of cells
	static let depthTexelSteps = [1, 2, 3, 4, 5, 6, 8]

	static func texelSteps(for source: Source) -> [Int] {
		source == .depth ? depthTexelSteps : texelSteps
	}

	/// The next snap point up or down from the current size.
	func texels(stepping step: Int) -> Int {
		let steps = Self.texelSteps(for: source)
		let index = steps.firstIndex { $0 >= cellTexels } ?? steps.count - 1
		let current = steps[index] == cellTexels ? index : (step > 0 ? index - 1 : index)
		return steps[min(steps.count - 1, max(0, current + step))]
	}

	func bounded() -> Self {
		var value = self
		value.zoom = min(max(zoom.isFinite ? zoom : 1, 0.5), 10)
		value.texelsPerCell = min(max(texelsPerCell, Self.texelRange.lowerBound), Self.texelRange.upperBound)
		value.depthTexelsPerCell = min(max(depthTexelsPerCell, 1), Self.depthTexelSteps.last ?? 8)
		return value
	}

	/// "1:4" for two camera pixels a side
	var ratioTitle: String {
		"1:\(cellTexels * cellTexels)"
	}

	// MARK: Saved settings

	private enum CodingKeys: String, CodingKey {
		case mapping, invert, usesFrontCamera, source, zoom, texelsPerCell, depthTexelsPerCell, depthNear, depthFar
		/// Before LiDAR, the camera was just on or off
		case usesCamera
	}

	/// Every field is optional, so settings saved by an older Bayer still load instead of resetting
	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let defaults = CameraSettings()
		mapping = try container.decodeIfPresent(Mapping.self, forKey: .mapping) ?? defaults.mapping
		invert = try container.decodeIfPresent(Bool.self, forKey: .invert) ?? defaults.invert
		usesFrontCamera = try container.decodeIfPresent(Bool.self, forKey: .usesFrontCamera) ?? defaults.usesFrontCamera
		zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? defaults.zoom
		texelsPerCell = try container.decodeIfPresent(Int.self, forKey: .texelsPerCell) ?? defaults.texelsPerCell
		depthTexelsPerCell = try container.decodeIfPresent(Int.self, forKey: .depthTexelsPerCell) ?? defaults.depthTexelsPerCell
		depthNear = try container.decodeIfPresent(Float.self, forKey: .depthNear) ?? defaults.depthNear
		depthFar = try container.decodeIfPresent(Float.self, forKey: .depthFar) ?? defaults.depthFar
		if let source = try container.decodeIfPresent(Source.self, forKey: .source) {
			self.source = source
		} else if let usesCamera = try container.decodeIfPresent(Bool.self, forKey: .usesCamera) {
			source = usesCamera ? .camera : .wave
		}
	}

	func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(mapping, forKey: .mapping)
		try container.encode(invert, forKey: .invert)
		try container.encode(usesFrontCamera, forKey: .usesFrontCamera)
		try container.encode(source, forKey: .source)
		try container.encode(zoom, forKey: .zoom)
		try container.encode(texelsPerCell, forKey: .texelsPerCell)
		try container.encode(depthTexelsPerCell, forKey: .depthTexelsPerCell)
		try container.encode(depthNear, forKey: .depthNear)
		try container.encode(depthFar, forKey: .depthFar)
	}
}

/// Matches `CameraUniforms` in OptimizedDither.metal. The renderer checks the stride.
nonisolated struct CameraUniforms {
	var uvScale: SIMD2<Float>
	var uvOffset: SIMD2<Float>
	var cropOrigin: SIMD2<Int32>
	var cameraMix: Float
	var mapping: Int32
	var taps: Int32
	var invert: Float
	var texelsPerCell: Int32
	var padding: Float = 0
}

/// One camera frame on its way to the GPU.
nonisolated struct CameraFrameInput {
	let texture: any MTLTexture
	/// Whatever owns `texture`'s memory, held until the frame's command buffer completes
	let retained: (any Sendable)?
	let settings: CameraSettings
	/// The wave field alone. `texture` is a blank stand-in and cells follow `pixelSize`.
	var waveOnly = false
	/// A cell size in output pixels to use as is, for CRISP photos, instead of fitting the frame exactly
	var fixedCell: Float?

	/// A 1×1 stand-in so the wave runs through the same kernel, and the same mappings, as the camera.
	@MainActor
	static func wave(device: any MTLDevice, settings: CameraSettings) -> CameraFrameInput? {
		if blank == nil || blank?.device !== device {
			let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
			descriptor.usage = .shaderRead
			blank = device.makeTexture(descriptor: descriptor)
		}
		guard let blank else {
			return nil
		}
		return CameraFrameInput(texture: blank, retained: nil, settings: settings, waveOnly: true)
	}

	@MainActor private static var blank: (any MTLTexture)?

	/// Aspect-fills the camera image into a grid of `columns` by `rows` cells.
	func uniforms(columns: Int, rows: Int) -> CameraUniforms {
		let gridAspect = Float(columns) / Float(max(rows, 1))
		let cameraAspect = Float(texture.width) / Float(max(texture.height, 1))
		var scale = SIMD2<Float>(1, 1)
		if gridAspect > cameraAspect {
			scale.y = cameraAspect / gridAspect
		} else {
			scale.x = gridAspect / cameraAspect
		}
		let bounded = settings.bounded()
		let texels = waveOnly ? 0 : bounded.cellTexels
		// Centre the grid's block of camera pixels in the frame
		let crop = SIMD2<Int32>(Int32(columns * texels), Int32(rows * texels))
		let size = SIMD2<Int32>(Int32(texture.width), Int32(texture.height))
		return CameraUniforms(
			uvScale: scale,
			uvOffset: (SIMD2<Float>(1, 1) - scale) / 2,
			cropOrigin: (size &- crop) / 2,
			// Either the camera is the whole input or the wave is
			cameraMix: waveOnly ? 0 : 1,
			mapping: Int32(bounded.mapping.rawValue),
			taps: 1,
			invert: bounded.invert ? 1 : 0,
			texelsPerCell: Int32(texels)
		)
	}

	/// The cell, in output pixels: N camera pixels at the scale that makes the frame fill the output.
	/// Usually fractional, which keeps the field of view the same at every N. Nil for the wave, which uses `pixelSize`.
	func exactCell(outputWidth: Int, outputHeight: Int) -> Float? {
		guard !waveOnly else {
			return nil
		}
		if let fixedCell {
			return fixedCell
		}
		let fill = max(Float(outputWidth) / Float(max(1, texture.width)), Float(outputHeight) / Float(max(1, texture.height)))
		let bounded = settings.bounded()
		#if os(macOS)
			// No lens zoom on the Mac: bigger cells over the same N×N blocks crop in from the centre
			let zoom = Float(max(1, bounded.zoom))
		#else
			let zoom: Float = 1
		#endif
		// Below a pixel is allowed: a big photo previewed small at 1:1 still shows whole, rather than
		// clamping to a pixel and cropping in. Each pixel then shows one of the cells it covers.
		return max(0.05, fill * zoom * Float(bounded.cellTexels))
	}
}
