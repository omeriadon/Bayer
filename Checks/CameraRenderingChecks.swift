// Renders a still photo through the camera kernel on the Mac, one PNG per scenario.
// Run with Checks/run-camera-checks.sh <photo> <output directory>.
import AppKit
import CoreGraphics
import Metal
import MetalKit

@main
struct CameraRenderingChecks {
	@MainActor
	static func main() throws {
		let arguments = CommandLine.arguments
		guard arguments.count == 4 else {
			print("usage: check <metallib> <photo> <output directory>")
			exit(2)
		}
		DitherShaderLibrary.url = URL(fileURLWithPath: arguments[1])
		let output = URL(fileURLWithPath: arguments[3])
		try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
		guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal") }
		let photo = try MTKTextureLoader(device: device).newTexture(
			URL: URL(fileURLWithPath: arguments[2]),
			options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue, .textureStorageMode: MTLStorageMode.private.rawValue]
		)

		// Palette from the scene: the photo's four main colours, darkest first
		if let source = NSImage(contentsOf: URL(fileURLWithPath: arguments[2]))?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
			let width = source.width, height = source.height
			var pixels = [UInt8](repeating: 0, count: width * height * 4)
			let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
				space: CGColorSpace(name: CGColorSpace.sRGB)!,
				bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
			context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
			let started = CFAbsoluteTimeGetCurrent()
			let colours = pixels.withUnsafeBytes { unsafe PaletteExtractor.palette(bgra: $0, width: width, height: height, bytesPerRow: width * 4, count: 4) }
			let hex = colours.map { String(format: "#%02X%02X%02X", Int($0.x * 255), Int($0.y * 255), Int($0.z * 255)) }
			print(String(format: "scene palette: %@ in %.1f ms", hex.joined(separator: " "), (CFAbsoluteTimeGetCurrent() - started) * 1000))
		}

		func palette(_ name: String) -> DitherPalette {
			DitherPalette.all.first { $0.name == name }!
		}

		var scenarios: [(String, DitherConfiguration, CameraSettings)] = []
		func add(_ name: String, _ edit: (inout DitherConfiguration, inout CameraSettings) -> Void) {
			var configuration = DitherConfiguration.bayerDefault
			var settings = CameraSettings()
			edit(&configuration, &settings)
			scenarios.append((name, configuration, settings))
		}
		add("01-pocket-exact") { _, _ in }
		add("02-1bit-1to4") { c, s in palette("1-BIT").apply(to: &c); c.gap = 0; c.cornerRadius = 0; s.texelsPerCell = 2 }
		add("03-cga") { c, _ in palette("CGA").apply(to: &c) }
		add("04-newsprint-blend") { c, s in palette("NEWSPRINT").apply(to: &c); s.mapping = .blend }
		add("05-source-colour") { c, s in s.mapping = .source; c.colorNum = 4; c.gap = 0; c.cornerRadius = 0 }
		add("06-thermal-bayer4") { c, _ in palette("THERMAL").apply(to: &c); c.ditherMode = 1 }
		add("07-amber-joined") { c, s in palette("AMBER").apply(to: &c); c.gap = 0; c.cornerRadius = 0.5; c.joinAdjacentSquares = true; s.texelsPerCell = 16 }
		add("08-sunset-invert") { c, s in palette("SUNSET").apply(to: &c); s.invert = true; c.ditherMode = 3 }
		add("09-pocket-half-strength") { c, _ in c.ditherStrength = 0.5 }
		for n in [2, 3, 4, 5, 6, 7] {
			add("fov-n\(n)") { c, s in palette("1-BIT").apply(to: &c); c.gap = 0; c.cornerRadius = 0; s.texelsPerCell = n }
		}
		add("13-atkinson-1bit") { c, s in palette("1-BIT").apply(to: &c); c.gap = 0; c.cornerRadius = 0; c.ditherMode = 8; s.texelsPerCell = 3 }
		add("14-floyd-pocket") { c, s in c.gap = 0; c.cornerRadius = 0; c.ditherMode = 9; s.texelsPerCell = 4 }
		add("15-floyd-source") { c, s in s.mapping = .source; c.colorNum = 2; c.gap = 0; c.cornerRadius = 0; c.ditherMode = 9; s.texelsPerCell = 2 }
		add("16-atkinson-newsprint-blend") { c, s in palette("NEWSPRINT").apply(to: &c); s.mapping = .blend; c.ditherMode = 8 }
		add("17-atkinson-wave") { c, s in palette("1-BIT").apply(to: &c); c.gap = 0; c.cornerRadius = 0; c.ditherMode = 8; c.pixelSize = 3; s.source = .wave }
		add("18-floyd-1to1") { c, s in palette("1-BIT").apply(to: &c); c.gap = 0; c.cornerRadius = 0; c.ditherMode = 9; s.texelsPerCell = 1 }
		add("10-wave-pocket") { _, s in s.source = .wave }
		add("11-wave-blueprint-px10") { c, s in palette("BLUEPRINT").apply(to: &c); c.pixelSize = 10; s.source = .wave }
		add("12-wave-thermal-scale3") { c, s in palette("THERMAL").apply(to: &c); c.scale = 3; c.ditherMode = 1; s.source = .wave }

		// iPhone-ish portrait at 1x points * 3 scale
		let width = 1179, height = 2556
		let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
		descriptor.usage = [.renderTarget, .shaderRead]
		descriptor.storageMode = .shared
		for (name, configuration, settings) in scenarios {
			let renderer = try DitherMetalRenderer(usesTopBlur: false)
			let input = settings.usesCamera
				? CameraFrameInput(texture: photo, retained: nil, settings: settings)
				: CameraFrameInput.wave(device: device, settings: settings)!
			renderer.camera = input
			let target = device.makeTexture(descriptor: descriptor)!
			let cell = max(1, Int(configuration.pixelSize * 3))
			let pinned = configuration.pinned(usesCamera: settings.usesCamera).bounded()
			let started = CFAbsoluteTimeGetCurrent()
			try renderer.render(to: target, width: width, height: height, cell: cell, configuration: pinned, advance: false, atTime: 4)
			// A second render times the steady state, without pipeline compilation
			let warm = CFAbsoluteTimeGetCurrent()
			try renderer.render(to: target, width: width, height: height, cell: cell, configuration: pinned, advance: false, atTime: 4)
			let finished = CFAbsoluteTimeGetCurrent()
			print(String(format: "%@: first %.1f ms, warm %.1f ms", name, (warm - started) * 1000, (finished - warm) * 1000))
			var bytes = [UInt8](repeating: 0, count: width * height * 4)
			bytes.withUnsafeMutableBytes { buffer in
				unsafe target.getBytes(buffer.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
			}
			let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
				space: CGColorSpace(name: CGColorSpace.sRGB)!,
				bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
			let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
			try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
			print("rendered \(name)")
		}
	}
}
