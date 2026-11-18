import Foundation
import simd

/// A palette, darkest colour first. Exact mapping depends on that order.
nonisolated struct DitherPalette: Identifiable, Equatable, Sendable {
	let id: String
	let name: String
	let colors: [SIMD3<Float>]

	init(_ name: String, _ hex: [UInt32]) {
		id = name
		self.name = name
		colors = hex.map { value in
			SIMD3<Float>(
				Float((value >> 16) & 0xFF) / 255,
				Float((value >> 8) & 0xFF) / 255,
				Float(value & 0xFF) / 255
			)
		}
	}

	static let all: [DitherPalette] = [
		DitherPalette("POCKET", [0x0F380F, 0x306230, 0x8BAC0F, 0x9BBC0F]),
		DitherPalette("1-BIT", [0x000000, 0xFFFFFF]),
		DitherPalette("CGA", [0x000000, 0xFF55FF, 0x55FFFF, 0xFFFFFF]),
		DitherPalette("NEWSPRINT", [0x1B1A17, 0x6B6358, 0xCFC6B5, 0xF4EFE6]),
		DitherPalette("AMBER", [0x140B00, 0x6B3F00, 0xC27C0E, 0xFFB000]),
		DitherPalette("BLUEPRINT", [0x0B1F4A, 0x1E4C9A, 0x6FA3EF, 0xE6F0FF]),
		DitherPalette("THERMAL", [0x000004, 0x57106E, 0xBC3754, 0xF98E09, 0xFCFFA4]),
		DitherPalette("SUNSET", [0x2B0F3A, 0x8C2155, 0xE8574A, 0xF7B267]),
	]

	/// Writes the palette into a configuration the way every mapping expects it.
	func apply(to configuration: inout DitherConfiguration) {
		configuration.palette = colors
		configuration.backgroundColor = colors.first ?? .zero
		configuration.waveColor = colors.last ?? SIMD3<Float>(repeating: 1)
		configuration.colorNum = Float(max(colors.count, 2))
		configuration.backgroundStyle = "custom"
		configuration.colorPlacement = "squares"
		configuration.useThemeColors = false
	}

	/// The palette whose colours a configuration currently uses, if any.
	static func matching(_ configuration: DitherConfiguration) -> DitherPalette? {
		all.first { $0.colors == configuration.palette }
	}
}

nonisolated extension DitherConfiguration {
	/// Bayer's starting look: the Pocket palette in chunky, slightly rounded cells.
	static var bayerDefault: DitherConfiguration {
		var configuration = DitherConfiguration()
		DitherPalette.all[0].apply(to: &configuration)
		configuration.pixelSize = 6
		configuration.ditherMode = 0
		configuration.ditherStrength = 1
		configuration.gap = 0.06
		configuration.cornerRadius = 0.18
		configuration.waveSpeed = 0.05
		configuration.framesPerSecond = 12
		return configuration
	}

	/// The renderer still has Ergo's touch and compositing settings, and its wave settings, which only
	/// matter with the camera off. Everything that doesn't apply is pinned here and never shown.
	func pinned(usesCamera: Bool) -> DitherConfiguration {
		var value = self
		value.intro = false
		if usesCamera {
			value.disableAnimation = true
			value.framesPerSecond = 30
			value.scale = 1
		}
		value.cursorInteractionEnabled = false
		value.topBlur = false
		value.opacity = 1
		value.transparent = false
		value.clipsToDeviceCorners = false
		value.useThemeColors = false
		value.colorPlacement = "squares"
		value.backgroundStyle = "custom"
		return value
	}
}
