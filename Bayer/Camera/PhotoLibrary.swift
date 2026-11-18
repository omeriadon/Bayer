import CoreGraphics
import ImageIO
import Photos
import Synchronization
import UniformTypeIdentifiers

/// A value set inside a Photos change block and read after it, which Photos runs on its own queue.
nonisolated final class ChangeResult<Value: Sendable>: Sendable {
	private let storage: Mutex<Value?>

	init() {
		storage = Mutex(nil)
	}

	var value: Value? {
		get { storage.withLock { $0 } }
		set { storage.withLock { $0 = newValue } }
	}
}

/// Bayer's photos in the library: the dithered render on top, and, when PRO keeps originals, the real
/// photo underneath with the recipe as Photos edit data. Photos shows the dither; Revert there gets the
/// real photo back; Bayer can open it again and change the dither.
enum PhotoLibrary {
	/// An original kept under a render
	struct Original: Sendable {
		let data: Data
		let type: UTType
	}

	/// A picture opened for editing
	struct Opened: Sendable {
		let image: CGImage
		/// Bayer's recipe, when the photo is one of Bayer's
		let edit: EditData?
		/// The library photo to save edits back into, when it's one of Bayer's
		let assetID: String?
		/// The picture's own bytes, kept as the original when it's saved as a new photo
		let original: Original?
	}

	enum Failure: LocalizedError {
		case notAllowed
		case notFound
		case unreadable

		var errorDescription: String? {
			switch self {
				case .notAllowed: "Photos access is off"
				case .notFound: "Photo not found"
				case .unreadable: "Couldn't read the photo"
			}
		}
	}

	static func requestAddAccess() async -> Bool {
		let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
		return status == .authorized || status == .limited
	}

	/// Editing a saved photo means reading the library, which is a separate permission from adding to it
	static func requestReadWriteAccess() async -> Bool {
		let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
		return status == .authorized || status == .limited
	}

	// MARK: Saving

	/// Saves a new photo and returns its library id. With an original and a recipe, the original is the
	/// photo and the render an edit on top; if Photos won't take that, the render is saved on its own.
	static func save(_ rendered: CGImage, original: Original?, edit: EditData?) async throws -> String? {
		guard await requestAddAccess() else {
			throw Failure.notAllowed
		}
		if let original, let edit, let recipe = try? edit.encoded() {
			do {
				return try await saveWithEdit(rendered, original: original, recipe: recipe)
			} catch {
				// Fall through to a plain photo; the dither is what matters
			}
		}
		guard let png = PhotoExporter.pngData(rendered) else {
			throw Failure.unreadable
		}
		let identifier = ChangeResult<String>()
		try await PHPhotoLibrary.shared().performChanges {
			let request = PHAssetCreationRequest.forAsset()
			request.addResource(with: .photo, data: png, options: nil)
			identifier.value = request.placeholderForCreatedAsset?.localIdentifier
		}
		return identifier.value
	}

	private static func saveWithEdit(_ rendered: CGImage, original: Original, recipe: Data) async throws -> String? {
		let identifier = ChangeResult<String>()
		let writeError = ChangeResult<String>()
		try await PHPhotoLibrary.shared().performChanges {
			let request = PHAssetCreationRequest.forAsset()
			let options = PHAssetResourceCreationOptions()
			options.uniformTypeIdentifier = original.type.identifier
			request.addResource(with: .photo, data: original.data, options: options)
			guard let placeholder = request.placeholderForCreatedAsset else {
				return
			}
			let output = PHContentEditingOutput(placeholderForCreatedAsset: placeholder)
			do {
				try write(rendered, to: output)
				output.adjustmentData = PHAdjustmentData(
					formatIdentifier: EditData.formatIdentifier,
					formatVersion: EditData.formatVersion,
					data: recipe
				)
				request.contentEditingOutput = output
				identifier.value = placeholder.localIdentifier
			} catch {
				writeError.value = error.localizedDescription
			}
		}
		if writeError.value != nil {
			throw Failure.unreadable
		}
		return identifier.value
	}

	/// Saves a new render over one of Bayer's photos, keeping its original underneath.
	static func saveEdit(_ rendered: CGImage, edit: EditData, to assetID: String) async throws {
		guard await requestReadWriteAccess() else {
			throw Failure.notAllowed
		}
		guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
			throw Failure.notFound
		}
		let input = try await contentEditingInput(for: asset)
		let output = PHContentEditingOutput(contentEditingInput: input)
		try write(rendered, to: output)
		output.adjustmentData = PHAdjustmentData(
			formatIdentifier: EditData.formatIdentifier,
			formatVersion: EditData.formatVersion,
			data: try edit.encoded()
		)
		try await PHPhotoLibrary.shared().performChanges {
			PHAssetChangeRequest(for: asset).contentEditingOutput = output
		}
	}

	/// PNG where Photos takes it, so the dither stays crisp. Otherwise HEIC at full quality, then JPEG.
	private nonisolated static func write(_ image: CGImage, to output: PHContentEditingOutput) throws {
		let supported = output.supportedRenderedContentTypes
		if supported.contains(.png), let data = PhotoExporter.pngData(image) {
			try data.write(to: output.renderedContentURL(for: .png))
		} else if supported.contains(.heic), let data = PhotoExporter.heicData(image, quality: 1) {
			try data.write(to: output.renderedContentURL(for: .heic))
		} else if let data = jpegData(image) {
			try data.write(to: output.renderedContentURL)
		} else {
			throw Failure.unreadable
		}
	}

	private nonisolated static func jpegData(_ image: CGImage) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
			return nil
		}
		CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
		return CGImageDestinationFinalize(destination) ? data as Data : nil
	}

	// MARK: Opening

	/// Opens a library photo. One of Bayer's comes back as its original plus the recipe; anything else
	/// comes back as it looks now, to be dithered as a new photo.
	static func open(assetID: String) async throws -> Opened {
		guard await requestReadWriteAccess() else {
			throw Failure.notAllowed
		}
		guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
			throw Failure.notFound
		}
		let input = try await contentEditingInput(for: asset)
		guard let url = input.fullSizeImageURL, let data = try? Data(contentsOf: url) else {
			throw Failure.unreadable
		}
		let edit = input.adjustmentData.flatMap { adjustment in
			isBayer(adjustment) ? EditData.decoded(adjustment.data) : nil
		}
		guard let image = orientedImage(data) else {
			throw Failure.unreadable
		}
		let type = UTType(input.uniformTypeIdentifier ?? "") ?? .jpeg
		return Opened(
			image: image,
			edit: edit,
			assetID: edit == nil ? nil : assetID,
			original: Original(data: data, type: type)
		)
	}

	/// A picture handed over without library access, from the photo picker
	nonisolated static func open(data: Data) -> Opened? {
		guard let image = orientedImage(data) else {
			return nil
		}
		let type = CGImageSourceCreateWithData(data as CFData, nil)
			.flatMap { CGImageSourceGetType($0) as String? }
			.flatMap(UTType.init) ?? .jpeg
		return Opened(image: image, edit: nil, assetID: nil, original: Original(data: data, type: type))
	}

	private nonisolated static func isBayer(_ adjustment: PHAdjustmentData) -> Bool {
		adjustment.formatIdentifier == EditData.formatIdentifier
	}

	private static func contentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
		let options = PHContentEditingInputRequestOptions()
		options.isNetworkAccessAllowed = true
		// Saying yes to Bayer's own recipe makes Photos hand over the original, not the render
		options.canHandleAdjustmentData = { adjustment in
			adjustment.formatIdentifier == EditData.formatIdentifier
		}
		let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SendableBox<PHContentEditingInput>, any Error>) in
			asset.requestContentEditingInput(with: options) { input, _ in
				if let input {
					continuation.resume(returning: SendableBox(input))
				} else {
					continuation.resume(throwing: Failure.unreadable)
				}
			}
		}
		return box.value
	}

	/// Decodes with the photo's orientation applied, at most 4096 pixels a side
	nonisolated static func orientedImage(_ data: Data, maximumSide: Int = 4096) -> CGImage? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
			return nil
		}
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: maximumSide,
			kCGImageSourceShouldCacheImmediately: true,
		]
		return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
	}
}
