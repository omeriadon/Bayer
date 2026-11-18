import simd
import SwiftUI

/// The settings that used to live in a sheet, now pages that swap in for the main controls.
enum SettingsSection: String, CaseIterable, Identifiable {
	case map, cells, tone, ink, wave, depth, more

	var id: Self { self }

	var title: String {
		switch self {
			case .map: "MAP"
			case .cells: "CELLS"
			case .tone: "TONE"
			case .ink: "INK"
			case .wave: "WAVE"
			case .depth: "DEPTH"
			case .more: "MORE"
		}
	}

	var icon: PixelIcon {
		switch self {
			case .map: .levels
			case .cells: .grid
			case .tone: .contrast
			case .ink: .drop
			case .wave: .wave
			case .depth: .lidar
			case .more: .more
		}
	}

	/// The wave's page only with DITHER, the depth range only with LIDAR
	static func available(source: CameraSettings.Source) -> [SettingsSection] {
		allCases.filter { section in
			switch section {
				case .wave: source == .wave
				case .depth: source == .depth
				default: true
			}
		}
	}
}

/// One button per section, fixed in a row. Tap one to open it; tap it again to go back to the main controls.
struct SectionBar: View {
	let sections: [SettingsSection]
	@Binding var selection: SettingsSection?

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		HStack(spacing: 6) {
			ForEach(sections) { section in
				let selected = section == selection
				Button {
					selection = selected ? nil : section
				} label: {
					VStack(spacing: 4) {
						PixelIconView(icon: section.icon, cell: 2, color: selected ? theme.paper : theme.ink)
						PixelText(section.title, cell: 1.3, color: selected ? theme.paper : theme.mid)
					}
					.frame(maxWidth: .infinity)
					.pixelPanel(lit: selected, padding: 6)
				}
				.buttonStyle(PixelButtonStyle())
				.accessibilityLabel(section.title.capitalized)
				.accessibilityAddTraits(selected ? .isSelected : [])
			}
		}
	}
}

/// The page for one section.
struct SectionPage: View {
	let section: SettingsSection
	@Bindable var model: AppModel

	var body: some View {
		VStack(spacing: 8) {
			switch section {
				case .map: map
				case .cells: cells
				case .tone: tone
				case .ink: InkPage(configuration: $model.configuration)
				case .wave: wave
				case .depth: depth
				case .more: MorePage(model: model)
			}
		}
	}

	private var map: some View {
		Group {
			ChoiceRow(
				options: [.exact, .blend, .source],
				selection: $model.camera.mapping,
				title: { $0.title.uppercased() }
			)
			PixelNote(text: note(for: model.camera.mapping))
			ToggleChip(title: "INVERT", isOn: $model.camera.invert)
		}
	}

	private func note(for mapping: CameraSettings.Mapping) -> String {
		switch mapping {
			case .exact: "EACH CELL IS ONE PALETTE COLOUR"
			case .blend: "PALETTE COLOURS FADE INTO THE GAP"
			case .source: "THE PICTURE'S OWN COLOURS"
		}
	}

	private var cells: some View {
		Group {
			ValueTrack(title: "GAP", values: Steps.from(0, through: 0.45, by: 0.05), value: $model.configuration.gap, format: Steps.percent)
			ValueTrack(title: "ROUND", values: Steps.from(0, through: 0.5, by: 0.05), value: $model.configuration.cornerRadius, format: Steps.percent)
			ToggleChip(title: "JOIN NEIGHBOURS", isOn: $model.configuration.joinAdjacentSquares)
				.disabled(model.configuration.gap > 0 || model.configuration.cornerRadius == 0)
				.opacity(model.configuration.gap > 0 || model.configuration.cornerRadius == 0 ? 0.4 : 1)
		}
	}

	private var tone: some View {
		Group {
			ValueTrack(title: "CONTRAST", values: [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4], value: $model.configuration.contrast, format: Steps.times)
			ValueTrack(title: "BRIGHT", values: Steps.from(-0.5, through: 0.5, by: 0.05), value: $model.configuration.brightness, format: Steps.signed)
			ValueTrack(title: "LEVELS", values: Steps.from(2, through: 16, by: 1), value: $model.configuration.colorNum, format: { "\(Int($0))" })
				.disabled(model.camera.mapping == .exact)
				.opacity(model.camera.mapping == .exact ? 0.4 : 1)
		}
	}

	private var depth: some View {
		Group {
			ValueTrack(title: "NEAR", values: CameraSettings.depthNearSteps, value: Binding {
				model.camera.depthNear
			} set: { near in
				// Far moves out of the way when near passes it
				var camera = model.camera
				camera.depthNear = near
				if camera.depthFar < near * 1.5 {
					camera.depthFar = CameraSettings.depthFarSteps.first { $0 >= near * 1.5 } ?? CameraSettings.depthFarSteps.last ?? 5
				}
				model.camera = camera
			}, format: Steps.metres)
			ValueTrack(
				title: "FAR",
				// Always past near, so the tones have room
				values: CameraSettings.depthFarSteps.filter { $0 >= model.camera.depthNear * 1.5 },
				value: $model.camera.depthFar,
				format: Steps.metres
			)
			PixelNote(text: "NEAR IS BRIGHT, FAR IS DARK")
		}
	}

	private var wave: some View {
		Group {
			ValueTrack(title: "SPEED", values: [0, 0.01, 0.02, 0.03, 0.05, 0.08, 0.1, 0.15, 0.2, 0.3, 0.5, 1], value: $model.configuration.waveSpeed, format: Steps.decimal)
			ValueTrack(title: "FREQ", values: [0.5, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 12], value: $model.configuration.waveFrequency, format: Steps.decimal)
			ValueTrack(title: "AMP", values: Steps.from(0, through: 1, by: 0.1), value: $model.configuration.waveAmplitude, format: Steps.percent)
			ValueTrack(title: "SCALE", values: [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8], value: $model.configuration.scale, format: Steps.times)
			ValueTrack(
				title: "HEADING",
				values: Steps.from(0, through: 315, by: 45),
				value: $model.configuration.waveDirection,
				format: { DitherConfiguration.compassDirection(for: $0) },
				fills: false
			)
			HStack(spacing: 8) {
				ToggleChip(title: "ANIMATE", isOn: Binding {
					!model.configuration.disableAnimation
				} set: {
					model.configuration.disableAnimation = !$0
				})
				ValueTrack(
					title: "FPS",
					values: [1, 2, 5, 8, 10, 12, 15, 20, 24, 30, 60],
					value: Binding {
						Float(model.configuration.framesPerSecond)
					} set: {
						model.configuration.framesPerSecond = Int($0)
					},
					format: { "\(Int($0))" },
					compact: true
				)
			}
		}
	}
}

// MARK: Pages with their own state

/// The palette's colours, editable, plus the colour between cells.
private struct InkPage: View {
	@Binding var configuration: DitherConfiguration

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		VStack(spacing: 8) {
			HStack(spacing: 6) {
				ForEach(configuration.palette.indices, id: \.self) { index in
					ColorSwatch(color: paletteBinding(index), label: "Colour \(index + 1)")
				}
				Spacer(minLength: 0)
			}
			.pixelPanel(padding: 8)
			HStack(spacing: 8) {
				Button {
					if configuration.palette.count > 2 {
						configuration.palette.removeLast()
					}
				} label: {
					label("LESS", icon: .minus)
				}
				.disabled(configuration.palette.count <= 2)
				.opacity(configuration.palette.count <= 2 ? 0.4 : 1)
				Button {
					if configuration.palette.count < DitherConfiguration.supportedPaletteCount {
						configuration.palette.append(configuration.palette.last ?? SIMD3<Float>(repeating: 1))
					}
				} label: {
					label("MORE", icon: .plus)
				}
				.disabled(configuration.palette.count >= DitherConfiguration.supportedPaletteCount)
				.opacity(configuration.palette.count >= DitherConfiguration.supportedPaletteCount ? 0.4 : 1)
			}
			.buttonStyle(PixelButtonStyle())
			HStack(spacing: 10) {
				PixelText("GAP COLOUR", cell: 2, color: theme.mid)
				Spacer()
				ColorSwatch(color: $configuration.backgroundColor, label: "Gap colour")
			}
			.pixelPanel(padding: 8)
			PixelNote(text: "DARKEST FIRST. TAP A COLOUR TO CHANGE IT")
		}
	}

	private func label(_ title: String, icon: PixelIcon) -> some View {
		HStack(spacing: 8) {
			PixelIconView(icon: icon, cell: 1.6, color: theme.ink)
			PixelText(title, cell: 2, color: theme.ink)
		}
		.frame(maxWidth: .infinity)
		.pixelPanel(padding: 10)
	}

	private func paletteBinding(_ index: Int) -> Binding<SIMD3<Float>> {
		Binding {
			index < configuration.palette.count ? configuration.palette[index] : .zero
		} set: { value in
			if index < configuration.palette.count {
				configuration.palette[index] = value
			}
		}
	}
}

private struct MorePage: View {
	@Bindable var model: AppModel

	@State private var copied = false
	/// Reset takes a second tap, so it can't happen by accident
	@State private var confirmingReset = false

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		VStack(spacing: 8) {
			Button {
				Platform.copy(SwiftExport.code(for: model.configuration.pinned(usesCamera: model.camera.usesCamera)))
				copied = true
				Task {
					try? await Task.sleep(for: .seconds(1.5))
					copied = false
				}
			} label: {
				HStack(spacing: 8) {
					PixelIconView(icon: copied ? .check : .pattern, cell: 1.6, color: copied ? theme.paper : theme.ink)
					PixelText(copied ? "COPIED" : "COPY AS SWIFT", cell: 2, color: copied ? theme.paper : theme.ink)
				}
				.frame(maxWidth: .infinity)
				.pixelPanel(lit: copied, padding: 12)
			}
			Button {
				if confirmingReset {
					model.reset()
					confirmingReset = false
				} else {
					confirmingReset = true
					Task {
						try? await Task.sleep(for: .seconds(2.5))
						confirmingReset = false
					}
				}
			} label: {
				HStack(spacing: 8) {
					PixelIconView(icon: .close, cell: 1.6, color: confirmingReset ? theme.paper : theme.ink)
					PixelText(confirmingReset ? "TAP AGAIN TO RESET" : "RESET EVERYTHING", cell: 2, color: confirmingReset ? theme.paper : theme.ink)
				}
				.frame(maxWidth: .infinity)
				.pixelPanel(lit: confirmingReset, padding: 12)
			}
			PixelNote(text: "PASTE IT INTO ANOTHER PROJECT")
		}
		.buttonStyle(PixelButtonStyle())
		.animation(.snappy(duration: 0.15), value: copied)
		.animation(.snappy(duration: 0.15), value: confirmingReset)
	}
}

// MARK: Components

/// A track over a fixed list of values. The value snaps to the nearest one.
struct ValueTrack: View {
	let title: String
	let values: [Float]
	@Binding var value: Float
	let format: (Float) -> String
	var fills = true
	/// Narrower title and value, for sharing a row
	var compact = false

	var body: some View {
		PixelTrack(
			title: title,
			value: format(value),
			count: values.count,
			index: Binding {
				values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) } ?? 0
			} set: { index in
				value = values[min(max(index, 0), values.count - 1)]
			},
			fills: fills,
			titleWidth: compact ? 32 : 84,
			valueWidth: compact ? 26 : 70
		)
	}
}

/// On or off, as a lit or unlit panel.
struct ToggleChip: View {
	let title: String
	@Binding var isOn: Bool

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		Button {
			isOn.toggle()
		} label: {
			HStack(spacing: 10) {
				PixelText(title, cell: 2, color: isOn ? theme.paper : theme.ink)
				Spacer(minLength: 4)
				PixelText(isOn ? "ON" : "OFF", cell: 2, color: isOn ? theme.paper : theme.mid)
			}
			.frame(maxWidth: .infinity)
			.pixelPanel(lit: isOn, padding: 11)
		}
		.buttonStyle(PixelButtonStyle())
		.accessibilityLabel(title.capitalized)
		.accessibilityValue(isOn ? "On" : "Off")
		.accessibilityAddTraits(.isToggle)
	}
}

/// One of a few options, side by side.
struct ChoiceRow<Option: Hashable>: View {
	let options: [Option]
	@Binding var selection: Option
	let title: (Option) -> String

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		HStack(spacing: 6) {
			ForEach(options, id: \.self) { option in
				let selected = option == selection
				Button {
					selection = option
				} label: {
					PixelText(title(option), cell: 2, color: selected ? theme.paper : theme.ink)
						.frame(maxWidth: .infinity)
						.pixelPanel(lit: selected, padding: 11)
				}
				.buttonStyle(PixelButtonStyle())
				.accessibilityLabel(title(option).capitalized)
				.accessibilityAddTraits(selected ? .isSelected : [])
			}
		}
	}
}

/// A small line of explanation under a control.
struct PixelNote: View {
	let text: String

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		PixelText(text, cell: 1.3, color: theme.mid)
			.frame(maxWidth: .infinity)
			.pixelPanel(padding: 8)
	}
}

/// A pixel square of colour that opens the system colour picker.
private struct ColorSwatch: View {
	@Binding var color: SIMD3<Float>
	let label: String

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		let swatch = Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z))
		PixelFrame(step: 2)
			.fill(swatch)
			.overlay { PixelFrame(step: 2).strokeBorder(theme.mid, lineWidth: 2) }
			.frame(width: 30, height: 30)
			// The system picker sits invisibly on top, slightly larger, so a tap anywhere on the swatch opens it
			.overlay {
				ColorPicker(label, selection: Binding {
					swatch
				} set: { picked in
					guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
					      let components = picked.resolve(in: EnvironmentValues()).cgColor.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
					      components.count >= 3
					else {
						return
					}
					let channel = { (value: CGFloat) in Float(min(max(value, 0), 1)) }
					color = SIMD3<Float>(channel(components[0]), channel(components[1]), channel(components[2]))
				}, supportsOpacity: false)
					.labelsHidden()
					.scaleEffect(1.4)
					.opacity(0.02)
			}
			.accessibilityElement(children: .contain)
	}
}

/// Value lists and how to show them.
enum Steps {
	static func from(_ start: Float, through end: Float, by step: Float) -> [Float] {
		Array(stride(from: start, through: end + step / 2, by: step))
	}

	static func percent(_ value: Float) -> String {
		"\(Int((value * 100).rounded()))%"
	}

	static func times(_ value: Float) -> String {
		decimal(value) + "×"
	}

	static func signed(_ value: Float) -> String {
		(value > 0.0001 ? "+" : "") + decimal(value)
	}

	static func metres(_ value: Float) -> String {
		decimal(value) + " M"
	}

	/// Two places at most, no trailing zeros
	static func decimal(_ value: Float) -> String {
		let hundredths = Int((value * 100).rounded())
		let whole = abs(hundredths) / 100
		let fraction = abs(hundredths) % 100
		let sign = hundredths < 0 ? "-" : ""
		if fraction == 0 {
			return "\(sign)\(whole)"
		}
		let digits = fraction % 10 == 0 ? "\(fraction / 10)" : (fraction < 10 ? "0\(fraction)" : "\(fraction)")
		return "\(sign)\(whole).\(digits)"
	}
}

/// Writes a configuration in the same shape as Ergo's `detailViewConf`.
enum SwiftExport {
	static func code(for c: DitherConfiguration) -> String {
		func f(_ value: Float) -> String { trim(Double(value)) }
		func d(_ value: Double) -> String { trim(value) }
		func trim(_ value: Double) -> String {
			// POSIX so the decimal point is always a dot, whatever the region
			value.formatted(.number.precision(.fractionLength(0 ... 4)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
		}
		func byte(_ value: Float) -> String {
			let text = String(Int((min(max(value, 0), 1) * 255).rounded()), radix: 16, uppercase: true)
			return text.count == 1 ? "0" + text : text
		}
		func color(_ value: SIMD3<Float>, comma: Bool = false) -> String {
			let hex = "#" + byte(value.x) + byte(value.y) + byte(value.z)
			return "SIMD3<Float>(\(f(value.x)), \(f(value.y)), \(f(value.z)))\(comma ? "," : "") // \(hex)"
		}
		let palette = c.palette.map { "\t\t" + color($0, comma: true) }.joined(separator: "\n")
		return """
		public var bayerConf: DitherConfiguration {
			var c = DitherConfiguration()

			// Wave
			c.waveSpeed = \(f(c.waveSpeed))
			c.waveDirection = \(f(c.waveDirection))
			c.waveFrequency = \(f(c.waveFrequency))
			c.waveAmplitude = \(f(c.waveAmplitude))
			c.scale = \(f(c.scale))
			c.contrast = \(f(c.contrast))
			c.brightness = \(f(c.brightness))

			// Animation
			c.disableAnimation = \(c.disableAnimation)
			c.framesPerSecond = \(c.framesPerSecond)
			c.intro = \(c.intro)

			// Cells and dithering
			c.pixelSize = \(f(c.pixelSize))
			c.colorNum = \(f(c.colorNum))
			c.ditherMode = \(c.ditherMode)
			c.ditherStrength = \(f(c.ditherStrength))
			c.gap = \(f(c.gap))
			c.cornerRadius = \(f(c.cornerRadius))
			c.joinAdjacentSquares = \(c.joinAdjacentSquares)

			// Colors
			c.waveColor = \(color(c.waveColor))
			c.backgroundColor = \(color(c.backgroundColor))

			c.palette = [
		\(palette)
			]

			c.backgroundStyle = "\(c.backgroundStyle)"
			c.colorPlacement = "\(c.colorPlacement)"
			c.squareStyle = "\(c.squareStyle)"
			c.useThemeColors = \(c.useThemeColors)

			// Composition
			c.transparent = \(c.transparent)
			c.opacity = \(f(c.opacity))
			c.topBlur = \(c.topBlur)
			c.clipsToDeviceCorners = \(c.clipsToDeviceCorners)

			c.cursorInteractionEnabled = \(c.cursorInteractionEnabled)
			c.cursorRadius = \(d(c.cursorRadius))
			c.cursorStrength = \(d(c.cursorStrength))
			c.cursorResponse = \(d(c.cursorResponse))
			c.cursorTrailDuration = \(d(c.cursorTrailDuration))
			c.cursorFadeDuration = \(d(c.cursorFadeDuration))
			c.cursorWarp = \(d(c.cursorWarp))

			return c
		}
		"""
	}
}
