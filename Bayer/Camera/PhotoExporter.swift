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

	/// Renders exactly what the preview shows: same cells, same size in pixels, and for the wave, the same moment.
	/// `frame` is the camera's latest frame; with the camera off it's ignored.
	@MainActor
	static func render(
		frame: LatestCameraFrame.Frame?,
		configuration: DitherConfiguration,
		camera: CameraSettings,
		waveTime: Float,
		pixelSize: CGSize,
		scale: CGFloat
	) throws -> CGImage {
		let camera = camera.bounded()
		let configuration = configuration.pinned(usesCamera: camera.usesCamera).bounded()
		let renderer = try DitherMetalRenderer(usesTopBlur: false)
		let input: CameraFrameInput? = if camera.usesCamera {
			frame.map { CameraFrameInput(texture: $0.texture, retained: $0.owner, settings: camera) }
		} else {
			CameraFrameInput.wave(device: renderer.device, settings: camera)
		}
		guard let input else {
			throw Failure.noFrame
		}
		renderer.camera = input

		let width = Int(pixelSize.width)
		let height = Int(pixelSize.height)
		let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
		descriptor.usage = [.renderTarget, .shaderRead]
		descriptor.storageMode = .shared
		guard let target = renderer.device.makeTexture(descriptor: descriptor) else {
			throw Failure.noTexture
		}
		// Ignored with the camera, which sets its own exact cell
		let cell = max(1, Int(configuration.pixelSize * Float(scale)))
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

	/// PNG, because JPEG smears the dither.
	static func save(_ image: CGImage) async throws {
		let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
		guard status == .authorized || status == .limited else {
			throw Failure.notAllowed
		}
		guard let data = pngData(image) else {
			throw Failure.noTexture
		}
		try await PHPhotoLibrary.shared().performChanges {
			PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
		}
	}

	private static func pngData(_ image: CGImage) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
			return nil
		}
		CGImageDestinationAddImage(destination, image, nil)
		return CGImageDestinationFinalize(destination) ? data as Data : nil
	}
}
