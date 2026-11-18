import CoreGraphics
import CoreVideo
import IOSurface
import Metal

/// CPU access to a frame's pixels, for palette-from-scene. Camera and LiDAR frames are IOSurface-backed;
/// anything else is read with getBytes when its storage allows it.
nonisolated enum FramePixels {
	/// Calls `body` with BGRA bytes, width, height and bytes per row. Nil if the texture can't be read.
	static func withBGRA<Result>(
		_ texture: any MTLTexture,
		_ body: (UnsafeRawBufferPointer, Int, Int, Int) -> Result
	) -> Result? {
		guard texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb else {
			return nil
		}
		if let surface = texture.iosurface {
			IOSurfaceLock(surface, .readOnly, nil)
			defer { IOSurfaceUnlock(surface, .readOnly, nil) }
			let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
			let height = IOSurfaceGetHeight(surface)
			let base = unsafe IOSurfaceGetBaseAddress(surface)
			let buffer = unsafe UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
			return unsafe body(buffer, IOSurfaceGetWidth(surface), height, bytesPerRow)
		}
		guard texture.storageMode == .shared else {
			return nil
		}
		let width = texture.width
		let height = texture.height
		let bytesPerRow = width * 4
		var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
		bytes.withUnsafeMutableBytes { buffer in
			unsafe texture.getBytes(buffer.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
		}
		return bytes.withUnsafeBytes { buffer in
			unsafe body(buffer, width, height, bytesPerRow)
		}
	}
}

/// A still picture as a frame the dither reads like a camera frame: BGRA, upright, CPU-readable.
nonisolated enum StillFrame {
	static func frame(from image: CGImage, device: any MTLDevice) -> LatestCameraFrame.Frame? {
		let width = image.width
		let height = image.height
		let bytesPerRow = width * 4
		var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
		let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
			guard let context = unsafe CGContext(
				data: buffer.baseAddress,
				width: width,
				height: height,
				bitsPerComponent: 8,
				bytesPerRow: bytesPerRow,
				space: CGColorSpace(name: CGColorSpace.sRGB)!,
				bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
			) else {
				return false
			}
			context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
			return true
		}
		guard drawn else {
			return nil
		}
		let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
		descriptor.usage = .shaderRead
		descriptor.storageMode = .shared
		guard let texture = device.makeTexture(descriptor: descriptor) else {
			return nil
		}
		pixels.withUnsafeBytes { buffer in
			unsafe texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: buffer.baseAddress!, bytesPerRow: bytesPerRow)
		}
		return LatestCameraFrame.Frame(texture: texture, owner: .init(still: ()))
	}
}
