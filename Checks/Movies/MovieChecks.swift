// Runs the video importer and the Live Photo maker on the Mac, without touching the Photos library.
// Run with Checks/run-movie-checks.sh <photo> <output directory>.
import AppKit
import AVFoundation
import ImageIO
import Metal

@main
struct MovieChecks {
	static func main() async throws {
		let arguments = CommandLine.arguments
		guard arguments.count == 4 else {
			print("usage: movies <metallib> <photo> <output directory>")
			exit(2)
		}
		DitherShaderLibrary.url = URL(fileURLWithPath: arguments[1])
		let output = URL(fileURLWithPath: arguments[3])
		try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
		guard let device = MTLCreateSystemDefaultDevice(),
		      let photo = NSImage(contentsOf: URL(fileURLWithPath: arguments[2]))?.cgImage(forProposedRect: nil, context: nil, hints: nil),
		      let frame = StillFrame.frame(from: photo, device: device)
		else {
			fatalError("couldn't load the photo")
		}

		// 1. A two-second source clip of the photo
		let source = try DitherMovieWriter(width: photo.width, height: photo.height, frameRate: 30)
		for index in 0 ..< 60 {
			try await source.append(frame.texture, at: CMTime(value: CMTimeValue(index), timescale: 30))
		}
		let sourceURL = try await source.finish()
		print("source clip: \(sourceURL.lastPathComponent)")

		// 2. Dithered through the importer
		var configuration = DitherConfiguration.bayerDefault
		DitherPalette.all[1].apply(to: &configuration)
		configuration.gap = 0
		configuration.cornerRadius = 0
		configuration.ditherMode = 8
		var camera = CameraSettings()
		camera.texelsPerCell = 3
		let started = CFAbsoluteTimeGetCurrent()
		var lastProgress = 0.0
		let dithered = try await MovieMaker.ditherVideo(at: sourceURL, configuration: configuration, camera: camera) { lastProgress = $0 }
		print(String(format: "dithered video in %.2f s, progress reached %.2f", CFAbsoluteTimeGetCurrent() - started, lastProgress))
		let ditheredAsset = AVURLAsset(url: dithered)
		let track = try await ditheredAsset.loadTracks(withMediaType: .video).first!
		print("dithered size: \(try await track.load(.naturalSize)), duration \(try await ditheredAsset.load(.duration).seconds) s")
		let generator = AVAssetImageGenerator(asset: ditheredAsset)
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		let (still, _) = try await generator.image(at: CMTime(value: 1, timescale: 1))
		try write(still, to: output.appendingPathComponent("video-frame.png"))
		try FileManager.default.copyItem(at: dithered, to: output.appendingPathComponent("dithered.mov"))

		// 3. A Live Photo of the wave
		var wave = DitherConfiguration.bayerDefault
		wave.pixelSize = 8
		var waveCamera = CameraSettings()
		waveCamera.source = .wave
		let live = try await MovieMaker.liveWave(configuration: wave, camera: waveCamera, startTime: 4, pixelSize: CGSize(width: 1179, height: 2556), scale: 3)
		try live.stillData.write(to: output.appendingPathComponent("live.heic"))
		try FileManager.default.copyItem(at: live.movie, to: output.appendingPathComponent("live.mov"))

		let stillSource = CGImageSourceCreateWithData(live.stillData as CFData, nil)!
		let properties = CGImageSourceCopyPropertiesAtIndex(stillSource, 0, nil) as? [CFString: Any]
		let maker = properties?[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
		let stillIdentifier = maker?["17"] as? String
		print("live still identifier: \(stillIdentifier ?? "MISSING")")

		let liveAsset = AVURLAsset(url: live.movie)
		let metadata = try await liveAsset.load(.metadata)
		var movieIdentifier: String?
		for item in metadata where (item.key as? String) == "com.apple.quicktime.content.identifier" {
			movieIdentifier = try await item.load(.stringValue)
		}
		print("live movie identifier: \(movieIdentifier ?? "MISSING")")
		let metadataTracks = try await liveAsset.loadTracks(withMediaType: .metadata)
		print("live metadata tracks: \(metadataTracks.count), duration \(try await liveAsset.load(.duration).seconds) s")
		print(stillIdentifier != nil && stillIdentifier == movieIdentifier && !metadataTracks.isEmpty ? "LIVE PHOTO PAIR OK" : "LIVE PHOTO PAIR BROKEN")
	}

	static func write(_ image: CGImage, to url: URL) throws {
		let rep = NSBitmapImageRep(cgImage: image)
		try rep.representation(using: .png, properties: [:])!.write(to: url)
	}
}
