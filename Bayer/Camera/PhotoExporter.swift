import CoreGraphics
import ImageIO
import Metal
import Photos
import UniformTypeIdentifiers

enum PhotoExporter {
	enum Failure: LocalizedError {
		case noFrame
		case noTexture
		case notAllowed

		var errorDescription: String? {
			switch self {
				case .noFrame: "No camera frame yet"
				case .noTexture: "Couldn't make the image"
				case .notAllowed: "Photos access is off"
			}
		}
	}

	/// Renders exactly what the preview shows: same cells, same crop, and for the wave, the same moment.
	/// `frame` is the camera's latest frame (or a still being edited); with the wave it's ignored.
	/// `pixelSize` is the render at screen size. `crisp` rounds each cell up to whole pixels, so every cell is identical.
	@MainActor
	static func render(
		frame: LatestCameraFrame.Frame?,
		configuration: DitherConfiguration,
		camera: CameraSettings,
		waveTime: Float,
		pixelSize: CGSize,
		scale: CGFloat,
		crisp: Bool = false
	) throws -> CGImage {
		let camera = camera.bounded()
		var configuration = configuration.pinned(usesCamera: camera.usesCamera).bounded()
		let renderer = try DitherMetalRenderer(usesTopBlur: false)
		let input: CameraFrameInput? = if camera.usesCamera {
			frame.map { CameraFrameInput(texture: $0.texture, retained: $0.owner, settings: camera) }
		} else {
			CameraFrameInput.wave(device: renderer.device, settings: camera)
		}
		guard var input else {
			throw Failure.noFrame
		}

		let base = (width: Int(pixelSize.width), height: Int(pixelSize.height))
		let screenCell = input.exactCell(outputWidth: base.width, outputHeight: base.height)
			.map(Double.init) ?? Double(max(1, Int(configuration.pixelSize * Float(scale))))
		// CRISP: the next whole number of pixels up, used exactly, so no cell is a pixel wider than another
		let pixelsPerCell: Int? = crisp ? max(1, Int((screenCell - 0.001).rounded(.up))) : nil
		let size = ExportSizing.size(base: base, cell: screenCell, pixelsPerCell: pixelsPerCell)
		if let pixelsPerCell {
			// A huge import with sub-pixel cells can hit the size limit; then the cell shrinks with the photo
			let shrunk = Double(size.width) / Double(max(1, base.width)) * screenCell
			let shrank = shrunk < Double(pixelsPerCell) - 0.5
			input.fixedCell = shrank ? Float(shrunk) : Float(pixelsPerCell)
			if !shrank, pixelsPerCell == 1 {
				// One pixel can't have a gap or rounded corners
				configuration.gap = 0
				configuration.cornerRadius = 0
				configuration.joinAdjacentSquares = false
			}
		}
		renderer.camera = input
		let width = size.width
		let height = size.height
		let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
		descriptor.usage = [.renderTarget, .shaderRead]
		descriptor.storageMode = .shared
		guard let target = renderer.device.makeTexture(descriptor: descriptor) else {
			throw Failure.noTexture
		}
		// The wave's cell; the camera ignores it and sets its own exact cell from the size
		let cell = pixelsPerCell ?? max(1, Int(configuration.pixelSize * Float(scale)))
		try renderer.render(to: target, width: width, height: height, cell: cell, configuration: configuration, advance: false, atTime: waveTime)

		let bytesPerRow = width * 4
		var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
		bytes.withUnsafeMutableBytes { buffer in
			unsafe target.getBytes(buffer.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
		}
		let alpha: CGImageAlphaInfo = configuration.transparent ? .premultipliedFirst : .noneSkipFirst
		guard let provider = CGDataProvider(data: Data(bytes) as CFData),
		      let image = unsafe CGImage(
		      	width: width,
		      	height: height,
		      	bitsPerComponent: 8,
		      	bitsPerPixel: 32,
		      	bytesPerRow: bytesPerRow,
		      	space: CGColorSpace(name: CGColorSpace.sRGB)!,
		      	bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
		      	provider: provider,
		      	decode: nil,
		      	shouldInterpolate: false,
		      	intent: .defaultIntent
		      )
		else {
			throw Failure.noTexture
		}
		return image
	}

	nonisolated static func pngData(_ image: CGImage) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
			return nil
		}
		CGImageDestinationAddImage(destination, image, nil)
		return CGImageDestinationFinalize(destination) ? data as Data : nil
	}

	/// HEIC for originals, which are photos rather than pixels. `quality` 1 is as close to lossless as HEIC goes.
	nonisolated static func heicData(_ image: CGImage, quality: Double) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
			return nil
		}
		CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
		return CGImageDestinationFinalize(destination) ? data as Data : nil
	}

	/// A frame's pixels as an image: the original kept under a photo, upright and cropped as the camera gave it.
	nonisolated static func image(of texture: any MTLTexture) -> CGImage? {
		unsafe FramePixels.withBGRA(texture) { pixels, width, height, bytesPerRow in
			let data = unsafe Data(bytes: pixels.baseAddress!, count: bytesPerRow * height)
			guard let provider = CGDataProvider(data: data as CFData) else {
				return nil as CGImage?
			}
			return unsafe CGImage(
				width: width,
				height: height,
				bitsPerComponent: 8,
				bitsPerPixel: 32,
				bytesPerRow: bytesPerRow,
				space: CGColorSpace(name: CGColorSpace.sRGB)!,
				bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
				provider: provider,
				decode: nil,
				shouldInterpolate: false,
				intent: .defaultIntent
			)
		} ?? nil
	}
}
