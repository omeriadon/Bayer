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

	var mapping = Mapping.exact
	var invert = false
	var usesFrontCamera = false
	/// Off disconnects the camera completely; the picture is Ergo's wave field instead
	var usesCamera = true
	/// As people say it: 0.5×, 1×, 2×. The lens does it on iPhone and iPad, the shader on the Mac.
	var zoom = 1.0
	/// Camera pixels along one side of a cell: 1 is 1:1, 2 is 1:4, 3 is 1:9.
	/// Every cell is the exact average of its own block, so cells always land on camera pixels.
	var texelsPerCell = 10

	static let texelRange = 1 ... 32
	/// Every size up close, then fewer as cells get big
	static let texelSteps = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 32]

	/// The next snap point up or down from the current size.
	func texels(stepping step: Int) -> Int {
		let steps = Self.texelSteps
		let index = steps.firstIndex { $0 >= texelsPerCell } ?? steps.count - 1
		let current = steps[index] == texelsPerCell ? index : (step > 0 ? index - 1 : index)
		return steps[min(steps.count - 1, max(0, current + step))]
	}

	func bounded() -> Self {
		var value = self
		value.zoom = min(max(zoom.isFinite ? zoom : 1, 0.5), 10)
		value.texelsPerCell = min(max(texelsPerCell, Self.texelRange.lowerBound), Self.texelRange.upperBound)
		return value
	}

	/// "1:4" for two camera pixels a side
	var ratioTitle: String {
		"1:\(texelsPerCell * texelsPerCell)"
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
		let texels = waveOnly ? 0 : bounded.texelsPerCell
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
		let fill = max(Float(outputWidth) / Float(max(1, texture.width)), Float(outputHeight) / Float(max(1, texture.height)))
		let bounded = settings.bounded()
		#if os(macOS)
			// No lens zoom on the Mac: bigger cells over the same N×N blocks crop in from the centre
			let zoom = Float(max(1, bounded.zoom))
		#else
			let zoom: Float = 1
		#endif
		return max(1, fill * zoom * Float(bounded.texelsPerCell))
	}
}
