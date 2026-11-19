import AVFoundation
import CoreImage
import CoreTransferable
import ImageIO
import Metal
import Photos
import UniformTypeIdentifiers
import VideoToolbox

/// A video picked from the library, copied somewhere Bayer can read it.
nonisolated struct PickedMovie: Transferable {
	let url: URL

	static var transferRepresentation: some TransferRepresentation {
		FileRepresentation(contentType: .movie) { movie in
			SentTransferredFile(movie.url)
		} importing: { received in
			let copy = FileManager.default.temporaryDirectory
				.appendingPathComponent(UUID().uuidString)
				.appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
			try FileManager.default.copyItem(at: received.file, to: copy)
			return PickedMovie(url: copy)
		}
	}
}

/// Writes dithered frames to a movie. Shared by video import and Live Photos, which add a still's identifier
/// and the moment the still was taken from.
final class DitherMovieWriter {
	enum Failure: Error {
		case cantWrite
	}

	let url: URL
	let width: Int
	let height: Int
	private let writer: AVAssetWriter
	private let input: AVAssetWriterInput
	private let adaptor: AVAssetWriterInputPixelBufferAdaptor
	/// The Live Photo's metadata tracks, which the Lock Screen needs before the wallpaper moves
	private let live: Live?
	private let frameDuration: CMTime

	private struct Live {
		let info: AVAssetWriterInput
		let infoFormat: CMFormatDescription
		let still: AVAssetWriterInput
		let stillFormat: CMFormatDescription
	}
	/// Copied audio, when a video had sound
	let audioInput: AVAssetWriterInput?

	/// `liveIdentifier` makes it the moving half of a Live Photo.
	init(width: Int, height: Int, frameRate: Double, liveIdentifier: String? = nil, audioFormat: CMFormatDescription? = nil) throws {
		// Even sizes keep every encoder happy
		self.width = max(2, width & ~1)
		self.height = max(2, height & ~1)
		url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
		writer = try AVAssetWriter(outputURL: url, fileType: .mov)
		// Dither is all edges, so it needs far more bits than camera footage to stay crisp
		let bitsPerSecond = Double(self.width * self.height) * frameRate * 0.9
		frameDuration = CMTime(seconds: 1 / max(1, frameRate), preferredTimescale: 600)
		var compression: [String: Any] = [
			AVVideoAverageBitRateKey: min(bitsPerSecond, 120_000_000),
			AVVideoExpectedSourceFrameRateKey: frameRate,
		]
		var settings: [String: Any] = [
			AVVideoCodecKey: AVVideoCodecType.hevc,
			AVVideoWidthKey: self.width,
			AVVideoHeightKey: self.height,
		]
		if liveIdentifier != nil {
			// What the Lock Screen takes: 8-bit HEVC Main in plain SDR, no reordered frames, a key frame every second
			compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
			compression[AVVideoMaxKeyFrameIntervalKey] = Int(frameRate.rounded())
			compression[AVVideoAllowFrameReorderingKey] = false
			settings[AVVideoColorPropertiesKey] = [
				AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
				AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
				AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
			]
		}
		settings[AVVideoCompressionPropertiesKey] = compression
		input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
		input.expectsMediaDataInRealTime = false
		adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
			kCVPixelBufferWidthKey as String: self.width,
			kCVPixelBufferHeightKey as String: self.height,
		])
		guard writer.canAdd(input) else {
			throw Failure.cantWrite
		}
		writer.add(input)

		if let audioFormat {
			let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
			audio.expectsMediaDataInRealTime = false
			if writer.canAdd(audio) {
				writer.add(audio)
				audioInput = audio
			} else {
				audioInput = nil
			}
		} else {
			audioInput = nil
		}

		if let liveIdentifier {
			// The two halves of a Live Photo find each other by this identifier
			let item = AVMutableMetadataItem()
			item.keySpace = .quickTimeMetadata
			item.key = "com.apple.quicktime.content.identifier" as NSString
			item.value = liveIdentifier as NSString
			item.dataType = kCMMetadataBaseDataType_UTF8 as String
			writer.metadata = [item]

			let infoFormat = try LivePhotoMetadata.infoFormatDescription()
			let stillFormat = try LivePhotoMetadata.stillFormatDescription()
			let info = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: infoFormat)
			let still = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: stillFormat)
			for metadata in [info, still] {
				metadata.expectsMediaDataInRealTime = false
				guard writer.canAdd(metadata) else {
					throw Failure.cantWrite
				}
				writer.add(metadata)
				// Both describe the video, as the camera's do
				let referent = AVAssetTrack.AssociationType.metadataReferent.rawValue
				if metadata.canAddTrackAssociation(withTrackOf: input, type: referent) {
					metadata.addTrackAssociation(withTrackOf: input, type: referent)
				}
			}
			live = Live(info: info, infoFormat: infoFormat, still: still, stillFormat: stillFormat)
		} else {
			live = nil
		}

		guard writer.startWriting() else {
			throw writer.error ?? Failure.cantWrite
		}
		writer.startSession(atSourceTime: .zero)
	}

	/// Marks the frame the Live Photo's still is taken from. Call before the first frame; the Lock Screen
	/// wants it at least half a second in.
	func markStill(at time: CMTime) throws {
		guard let live else {
			return
		}
		let time = CMTimeConvertScale(time, timescale: LivePhotoMetadata.timescale, method: .roundHalfAwayFromZero)
		guard live.still.append(try LivePhotoMetadata.stillSample(format: live.stillFormat, at: time)) else {
			throw writer.error ?? Failure.cantWrite
		}
		live.still.markAsFinished()
	}

	/// Appends one rendered frame. `texture` must be BGRA and CPU-readable, the writer's size.
	func append(_ texture: any MTLTexture, at time: CMTime) async throws {
		while !input.isReadyForMoreMediaData {
			if writer.status == .failed {
				throw writer.error ?? Failure.cantWrite
			}
			try await Task.sleep(for: .milliseconds(4))
		}
		guard let pool = adaptor.pixelBufferPool else {
			throw writer.error ?? Failure.cantWrite
		}
		var buffer: CVPixelBuffer?
		unsafe CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
		guard let buffer else {
			throw Failure.cantWrite
		}
		CVPixelBufferLockBaseAddress(buffer, [])
		if let base = unsafe CVPixelBufferGetBaseAddress(buffer) {
			unsafe texture.getBytes(
				base,
				bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
				from: MTLRegionMake2D(0, 0, min(width, texture.width), min(height, texture.height)),
				mipmapLevel: 0
			)
		}
		CVPixelBufferUnlockBaseAddress(buffer, [])
		guard adaptor.append(buffer, withPresentationTime: time) else {
			throw writer.error ?? Failure.cantWrite
		}
		if let live {
			// The camera's record, once a frame
			while !live.info.isReadyForMoreMediaData {
				if writer.status == .failed {
					throw writer.error ?? Failure.cantWrite
				}
				try await Task.sleep(for: .milliseconds(4))
			}
			let time = CMTimeConvertScale(time, timescale: LivePhotoMetadata.timescale, method: .roundHalfAwayFromZero)
			guard live.info.append(try LivePhotoMetadata.infoSample(format: live.infoFormat, at: time, duration: frameDuration)) else {
				throw writer.error ?? Failure.cantWrite
			}
		}
	}

	func finish() async throws -> URL {
		input.markAsFinished()
		live?.info.markAsFinished()
		await writer.finishWriting()
		guard writer.status == .completed else {
			throw writer.error ?? Failure.cantWrite
		}
		return url
	}
}

/// Dithers videos from the library, and turns the wave into Live Photos.
enum MovieMaker {
	enum Failure: LocalizedError {
		case noVideo
		case cantRead
		case cantRender

		var errorDescription: String? {
			switch self {
				case .noVideo: "No video in that file"
				case .cantRead: "Couldn't read the video"
				case .cantRender: "Couldn't render the video"
			}
		}
	}

	/// The longest side of a dithered video. Past this, files get huge and the cells don't need it.
	static let maximumSide = 1920

	/// Dithers every frame of `url` with these settings and saves the result as a new video, sound and all.
	/// Rendering happens a frame at a time on the main actor, with the reading and writing awaited in between,
	/// so the app keeps responding. `progress` goes from 0 to 1.
	static func ditherVideo(
		at url: URL,
		configuration: DitherConfiguration,
		camera: CameraSettings,
		progress: @escaping (Double) -> Void
	) async throws -> URL {
		let asset = AVURLAsset(url: url)
		guard let track = try await asset.loadTracks(withMediaType: .video).first else {
			throw Failure.noVideo
		}
		let duration = try await asset.load(.duration)
		let frameRate = Double(try await track.load(.nominalFrameRate))
		// Applies the video's rotation, so portrait clips come out portrait
		let compositionSetup = try await AVVideoComposition.Configuration(for: asset)
		let composition = AVVideoComposition(configuration: compositionSetup)
		let renderSize = compositionSetup.renderSize
		let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
		let audioFormat = try await audioTrack?.load(.formatDescriptions).first

		let reader = try AVAssetReader(asset: asset)
		let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
			kCVPixelBufferMetalCompatibilityKey as String: true,
			kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
		])
		videoOutput.videoComposition = composition
		videoOutput.alwaysCopiesSampleData = false
		guard reader.canAdd(videoOutput) else {
			throw Failure.cantRead
		}
		reader.add(videoOutput)
		var audioOutput: AVAssetReaderTrackOutput?
		if let audioTrack {
			let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
			if reader.canAdd(output) {
				reader.add(output)
				audioOutput = output
			}
		}
		guard reader.startReading() else {
			throw reader.error ?? Failure.cantRead
		}

		let longest = max(renderSize.width, renderSize.height)
		let shrink = longest > CGFloat(maximumSide) ? CGFloat(maximumSide) / longest : 1
		let width = Int((renderSize.width * shrink).rounded())
		let height = Int((renderSize.height * shrink).rounded())
		let writer = try DitherMovieWriter(
			width: width,
			height: height,
			frameRate: frameRate > 0 ? frameRate : 30,
			audioFormat: audioOutput == nil ? nil : audioFormat
		)

		// Sound is copied as it is, alongside, on its own queue
		let audioDone: Task<Void, Never>? = if let audioOutput, let audioInput = writer.audioInput {
			{
				let reading = SendableBox(audioOutput)
				let writing = SendableBox(audioInput)
				return Task.detached {
					await copyAudio(from: reading, to: writing)
				}
			}()
		} else {
			nil
		}

		let renderer = try DitherMetalRenderer(usesTopBlur: false)
		var textureCache: CVMetalTextureCache?
		unsafe CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, renderer.device, nil, &textureCache)
		guard let textureCache else {
			throw Failure.cantRender
		}
		let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: writer.width, height: writer.height, mipmapped: false)
		descriptor.usage = [.renderTarget, .shaderRead]
		descriptor.storageMode = .shared
		guard let target = renderer.device.makeTexture(descriptor: descriptor) else {
			throw Failure.cantRender
		}
		var settings = camera.bounded()
		// The video is the picture now, whatever the camera was doing
		settings.source = settings.source == .depth ? .depth : .camera
		let pinned = configuration.pinned(usesCamera: true).bounded()
		let total = max(duration.seconds, 0.001)
		let reading = SendableBox<AVAssetReaderOutput>(videoOutput)

		while let sample = await nextSample(reading) {
			try Task.checkCancellation()
			guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample.value) else {
				continue
			}
			let time = CMSampleBufferGetPresentationTimeStamp(sample.value)
			var cvTexture: CVMetalTexture?
			unsafe CVMetalTextureCacheCreateTextureFromImage(
				kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
				CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture
			)
			guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
				continue
			}
			renderer.camera = CameraFrameInput(texture: texture, retained: LatestCameraFrame.FrameOwner(cvTexture), settings: settings)
			try renderer.render(to: target, width: writer.width, height: writer.height, cell: 1, configuration: pinned, advance: false)
			try await writer.append(target, at: time)
			progress(min(1, time.seconds / total))
		}
		if reader.status == .failed {
			throw reader.error ?? Failure.cantRead
		}
		await audioDone?.value
		let movie = try await writer.finish()
		return movie
	}

	/// A three-second Live Photo of the wave, looping where it was when the shutter was pressed.
	/// The still is the middle frame, as a full-quality HEIC.
	static func liveWave(
		configuration: DitherConfiguration,
		camera: CameraSettings,
		startTime: Float,
		pixelSize: CGSize,
		scale: CGFloat
	) async throws -> LivePhoto {
		let identifier = UUID().uuidString
		let frameRate = 30.0
		let seconds = 3.0
		let frameCount = Int(frameRate * seconds)
		let stillFrame = frameCount / 2
		// The still is the screen's own pixels, cells exactly as shown, since it's what the wallpaper
		// shows almost all the time. The Lock Screen takes a still bigger than its movie.
		let stillCell = max(1, Int((CGFloat(configuration.bounded().pixelSize) * scale).rounded()))
		let stillWidth = Int(pixelSize.width) & ~1
		let stillHeight = Int(pixelSize.height) & ~1
		// The movie's long side can't pass 1920. It keeps the still's grid of cells, each a whole, smaller
		// number of pixels, so it's just as crisp, only coarser; never a blurry scale of the still.
		let limit = min(1, 1080 / max(1, min(pixelSize.width, pixelSize.height)), 1920 / max(1, max(pixelSize.width, pixelSize.height)))
		let movieCell = max(1, Int((CGFloat(stillCell) * limit).rounded(.down)))
		// Only 1-pixel cells, which can't get smaller, fall back to plain scaling
		let fit = min(limit, CGFloat(movieCell) / CGFloat(stillCell))
		let writer = try DitherMovieWriter(
			width: Int((pixelSize.width * fit).rounded()),
			height: Int((pixelSize.height * fit).rounded()),
			frameRate: frameRate,
			liveIdentifier: identifier
		)
		var settings = camera.bounded()
		settings.source = .wave
		var pinned = configuration.pinned(usesCamera: false).bounded()
		pinned.disableAnimation = false
		let renderer = try DitherMetalRenderer(usesTopBlur: false)
		guard let input = CameraFrameInput.wave(device: renderer.device, settings: settings) else {
			throw Failure.cantRender
		}
		renderer.camera = input
		func texture(width: Int, height: Int) -> (any MTLTexture)? {
			let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
			descriptor.usage = [.renderTarget, .shaderRead]
			descriptor.storageMode = .shared
			return renderer.device.makeTexture(descriptor: descriptor)
		}
		guard let target = texture(width: writer.width, height: writer.height),
		      let stillTarget = texture(width: stillWidth, height: stillHeight)
		else {
			throw Failure.cantRender
		}
		let cell = movieCell
		try writer.markStill(at: CMTime(value: CMTimeValue(stillFrame), timescale: CMTimeScale(frameRate)))
		// The wave only moves at its own frame rate; between its steps, frames repeat
		let waveStep = 1 / Double(max(1, pinned.framesPerSecond))
		var still: CGImage?
		for frame in 0 ..< frameCount {
			let elapsed = Double(frame) / frameRate
			let stepped = (elapsed / waveStep).rounded(.down) * waveStep
			// Centred on the moment of the shutter, so the still is what was on screen
			let time = startTime + Float(stepped - seconds / 2)
			try renderer.render(to: target, width: writer.width, height: writer.height, cell: cell, configuration: pinned, advance: false, atTime: time)
			let presentation = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate))
			if frame == stillFrame {
				try renderer.render(to: stillTarget, width: stillWidth, height: stillHeight, cell: stillCell, configuration: pinned, advance: false, atTime: time)
				still = image(of: stillTarget)
			}
			try await writer.append(target, at: presentation)
			await Task.yield()
		}
		let movie = try await writer.finish()
		guard let still, let stillData = liveStillData(still, identifier: identifier) else {
			throw Failure.cantRender
		}
		return LivePhoto(still: still, stillData: stillData, movie: movie)
	}

	/// The two halves of a Live Photo, ready to save together
	struct LivePhoto {
		let still: CGImage
		let stillData: Data
		let movie: URL
	}

	static func save(_ live: LivePhoto) async throws {
		guard await PhotoLibrary.requestAddAccess() else {
			throw PhotoLibrary.Failure.notAllowed
		}
		let stillData = live.stillData
		let movie = live.movie
		try await PHPhotoLibrary.shared().performChanges {
			let request = PHAssetCreationRequest.forAsset()
			request.addResource(with: .photo, data: stillData, options: nil)
			let options = PHAssetResourceCreationOptions()
			options.shouldMoveFile = true
			request.addResource(with: .pairedVideo, fileURL: movie, options: options)
		}
	}

	// MARK: Pieces

	static func saveVideo(_ url: URL) async throws {
		guard await PhotoLibrary.requestAddAccess() else {
			throw PhotoLibrary.Failure.notAllowed
		}
		try await PHPhotoLibrary.shared().performChanges {
			let options = PHAssetResourceCreationOptions()
			options.shouldMoveFile = true
			PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
		}
	}

	/// The Live Photo's still: HEIC at full quality, tagged with the identifier its video carries
	private nonisolated static func liveStillData(_ image: CGImage, identifier: String) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
			return nil
		}
		let properties: [CFString: Any] = [
			kCGImageDestinationLossyCompressionQuality: 1.0,
			kCGImagePropertyMakerAppleDictionary: ["17": identifier],
		]
		CGImageDestinationAddImage(destination, image, properties as CFDictionary)
		return CGImageDestinationFinalize(destination) ? data as Data : nil
	}

	private static func image(of texture: any MTLTexture) -> CGImage? {
		PhotoExporter.image(of: texture)
	}

	/// Reads the next frame off the main actor; decoding can block for a moment
	@concurrent
	private nonisolated static func nextSample(_ output: SendableBox<AVAssetReaderOutput>) async -> SendableBox<CMSampleBuffer>? {
		output.value.copyNextSampleBuffer().map(SendableBox.init)
	}

	@concurrent
	private nonisolated static func copyAudio(from output: SendableBox<AVAssetReaderTrackOutput>, to input: SendableBox<AVAssetWriterInput>) async {
		while let sample = output.value.copyNextSampleBuffer() {
			while !input.value.isReadyForMoreMediaData {
				try? await Task.sleep(for: .milliseconds(4))
			}
			if !input.value.append(sample) {
				break
			}
		}
		input.value.markAsFinished()
	}
}

/// AVFoundation's readers, writers and buffers aren't Sendable, but each here is only used by one task at a time.
nonisolated final class SendableBox<Value>: @unchecked Sendable {
	let value: Value

	init(_ value: Value) {
		self.value = value
	}
}
