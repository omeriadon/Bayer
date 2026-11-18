import Foundation

/// Everything needed to dither a photo's original again, saved with it as Photos edit data.
///
/// Photos keeps the original (the camera's own frame, or an imported picture) and shows Bayer's render
/// on top. This is the recipe for that render. Photos only hands it back to Bayer, which recognises it by
/// `formatIdentifier`. Versioned and decoded leniently, so photos saved today still open after Bayer gains
/// settings: anything missing falls back to its default.
nonisolated struct EditData: Equatable, Sendable, Codable {
	static let formatIdentifier = "com.adonis.Bayer.edit"
	static let formatVersion = "1"
	static let version = 1

	/// What the original is. Only pictures are edited; the wave is simply shot again.
	enum Original: String, Codable, Sendable {
		/// The camera's frame, upright and mirrored as it was shown
		case camera
		/// LiDAR's grey depth picture, with NEAR and FAR already applied
		case depth
		/// A photo brought in from the library
		case imported
	}

	var version = Self.version
	var original: Original
	var configuration: DitherConfiguration
	var camera: CameraSettings
	/// The render's size in pixels before PRO's photo size. For camera photos, the screen when it was taken;
	/// for imports, the picture itself. Keeps the same crop and cell grid when it's edited again.
	var outputWidth: Int
	var outputHeight: Int
	var exportSize: ProSettings.ExportSize

	init(
		original: Original,
		configuration: DitherConfiguration,
		camera: CameraSettings,
		outputWidth: Int,
		outputHeight: Int,
		exportSize: ProSettings.ExportSize
	) {
		self.original = original
		self.configuration = configuration
		self.camera = camera
		self.outputWidth = outputWidth
		self.outputHeight = outputHeight
		self.exportSize = exportSize
	}

	private enum CodingKeys: String, CodingKey {
		case version, original, configuration, camera, outputWidth, outputHeight, exportSize
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.version
		original = (try? container.decodeIfPresent(Original.self, forKey: .original)) ?? .camera
		configuration = (try? container.decodeIfPresent(LenientConfiguration.self, forKey: .configuration))?.value ?? .bayerDefault
		camera = (try? container.decodeIfPresent(CameraSettings.self, forKey: .camera)) ?? CameraSettings()
		outputWidth = try container.decodeIfPresent(Int.self, forKey: .outputWidth) ?? 0
		outputHeight = try container.decodeIfPresent(Int.self, forKey: .outputHeight) ?? 0
		exportSize = (try? container.decodeIfPresent(ProSettings.ExportSize.self, forKey: .exportSize)) ?? .screen
	}

	func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		return try encoder.encode(self)
	}

	static func decoded(_ data: Data) -> EditData? {
		try? JSONDecoder().decode(EditData.self, from: data)
	}
}

/// How big a saved photo is, in pixels, for PRO's photo sizes.
nonisolated enum ExportSizing {
	/// Keeps the saved photo inside what the renderer and memory allow: 16384 a side, about 40 million pixels
	static let maximumSide = 16384
	static let maximumPixels = 40_000_000

	/// `base` is the render at screen size (or the picture's own size) and `cell` its cell in pixels there.
	/// Returns the size that gives each cell `pixelsPerCell` pixels, shrunk if it would be too big.
	static func size(base: (width: Int, height: Int), cell: Double, pixelsPerCell: Int?) -> (width: Int, height: Int) {
		guard let pixelsPerCell, cell > 0, base.width > 0, base.height > 0 else {
			return base
		}
		var factor = Double(pixelsPerCell) / cell
		let width = Double(base.width) * factor
		let height = Double(base.height) * factor
		let side = max(width, height)
		if side > Double(maximumSide) {
			factor *= Double(maximumSide) / side
		}
		let area = Double(base.width) * Double(base.height) * factor * factor
		if area > Double(maximumPixels) {
			factor *= (Double(maximumPixels) / area).squareRoot()
		}
		return (max(1, Int((Double(base.width) * factor).rounded())), max(1, Int((Double(base.height) * factor).rounded())))
	}
}
