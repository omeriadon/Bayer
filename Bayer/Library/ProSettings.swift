import Foundation

/// The SETTINGS sheet: how photos are made, rather than how the picture looks.
nonisolated struct ProSettings: Equatable, Sendable, Codable {
	/// How a saved photo is sized
	enum ExportSize: Int, CaseIterable, Codable, Sendable {
		/// Exactly the screen's pixels. Cells are usually a fraction of a pixel wide, so some come out a pixel wider.
		case screen = 0
		/// The screen's cell rounded up to whole pixels: every cell identical, the photo about screen size
		case crisp = 10

		var title: String {
			switch self {
				case .screen: "SCREEN"
				case .crisp: "CRISP"
			}
		}
	}

	var exportSize = ExportSize.screen
	var sounds = true

	init() {}

	private enum CodingKeys: String, CodingKey {
		case exportSize, sounds
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let defaults = ProSettings()
		exportSize = (try? container.decodeIfPresent(ExportSize.self, forKey: .exportSize)) ?? defaults.exportSize
		sounds = try container.decodeIfPresent(Bool.self, forKey: .sounds) ?? defaults.sounds
	}
}
