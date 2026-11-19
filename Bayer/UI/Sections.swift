import simd
import SwiftUI
#if os(iOS)
	import UIKit
#endif

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
			// Shown as plus or minus, like brightness. The shader's multiplier is 2^(1.5 × that): about 0.35× to 2.8×.
			ValueTrack(title: "CONTRAST", values: Steps.from(-1, through: 1, by: 0.1), value: Binding {
				log2(max(model.configuration.contrast, 0.01)) / 1.5
			} set: { offset in
				model.configuration.contrast = abs(offset) < 0.001 ? 1 : pow(2, offset * 1.5)
			}, format: Steps.signed)
			ValueTrack(title: "BRIGHT", values: Steps.from(-0.5, through: 0.5, by: 0.05), value: $model.configuration.brightness, format: Steps.signed)
			// Exact always uses one level per palette colour, so levels only exist for Blend and Source
			if model.camera.mapping != .exact {
				ValueTrack(title: "LEVELS", values: Steps.from(2, through: 16, by: 1), value: $model.configuration.colorNum, format: { "\(Int($0))" })
			}
		}
	}

	private var depth: some View {
		PixelRangeTrack(
			title: "RANGE",
			values: CameraSettings.depthSteps,
			lower: $model.camera.depthNear,
			upper: $model.camera.depthFar,
			lowerName: "Near",
			upperName: "Far",
			minimumRatio: CameraSettings.depthMinimumRatio,
			format: Steps.decimal,
			unit: " M"
		)
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

/// The palette's colours, editable, plus the colour between cells. Tap a swatch, then set it with three tracks.
private struct InkPage: View {
	@Binding var configuration: DitherConfiguration

	/// The swatch being set: a palette index, or `gapIndex` for the gap colour
	@State private var editing: Int?
	private static let gapIndex = -1

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		VStack(spacing: 8) {
			HStack(spacing: 6) {
				ForEach(configuration.palette.indices, id: \.self) { index in
					Swatch(color: colour(index), selected: editing == index, label: "Colour \(index + 1)") {
						editing = editing == index ? nil : index
					}
				}
				Spacer(minLength: 4)
				PixelText("GAP", cell: 1.5, color: theme.mid)
				Swatch(color: colour(Self.gapIndex), selected: editing == Self.gapIndex, label: "Gap colour") {
					editing = editing == Self.gapIndex ? nil : Self.gapIndex
				}
			}
			.pixelPanel(padding: 8)

			if let editing, editing == Self.gapIndex || configuration.palette.indices.contains(editing) {
				let binding = colourBinding(editing)
				VStack(spacing: 6) {
					ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, row in
						HStack(spacing: 6) {
							ForEach(row, id: \.self) { hex in
								let preset = Self.colour(hex)
								Swatch(color: preset, selected: binding.wrappedValue == preset, label: "Preset colour") {
									binding.wrappedValue = preset
								}
							}
						}
					}
				}
				.frame(maxWidth: .infinity)
				.pixelPanel(padding: 8)
				HStack(spacing: 8) {
					Button {
						pickingSystemColour = true
					} label: {
						label("ANY COLOUR", icon: .drop)
					}
					if editing != Self.gapIndex {
						Button {
							delete(editing)
						} label: {
							label("DELETE", icon: .close)
						}
						.disabled(configuration.palette.count <= 2)
						.opacity(configuration.palette.count <= 2 ? 0.4 : 1)
					}
				}
				.buttonStyle(PixelButtonStyle())
				.sheet(isPresented: $pickingSystemColour) {
					SystemColourPicker(colour: binding)
						.presentationDetents([.medium, .large])
				}
			} else {
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
			}
		}
		.animation(.snappy(duration: 0.15), value: editing)
	}

	@State private var pickingSystemColour = false

	/// Neon, then blacks to white, then dim
	private static let presets: [[UInt32]] = [
		[0xFF2BD6, 0xFF3131, 0xFF8A00, 0xFFF01F, 0x39FF14, 0x00F0FF, 0x2D6BFF, 0xB026FF],
		[0x000000, 0x141414, 0x2B2B2B, 0x4A4A4A, 0x767676, 0xA6A6A6, 0xD4D4D4, 0xFFFFFF],
		[0x5A1E4C, 0x5C1F1F, 0x5E3A14, 0x55501A, 0x24501E, 0x174F55, 0x1D2F5E, 0x3B1F5E],
	]

	private static func colour(_ hex: UInt32) -> SIMD3<Float> {
		SIMD3<Float>(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255)
	}

	private func delete(_ index: Int) {
		guard configuration.palette.count > 2, configuration.palette.indices.contains(index) else {
			return
		}
		configuration.palette.remove(at: index)
		editing = nil
	}

	private func colour(_ index: Int) -> SIMD3<Float> {
		if index == Self.gapIndex {
			return configuration.backgroundColor
		}
		return index < configuration.palette.count ? configuration.palette[index] : .zero
	}

	private func colourBinding(_ index: Int) -> Binding<SIMD3<Float>> {
		Binding {
			colour(index)
		} set: { value in
			if index == Self.gapIndex {
				configuration.backgroundColor = value
			} else if index < configuration.palette.count {
				configuration.palette[index] = value
			}
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
}

/// The system's own colour picker, for anything the presets don't have
private struct SystemColourPicker: View {
	@Binding var colour: SIMD3<Float>

	var body: some View {
		#if os(iOS)
			SystemColourPickerController(colour: $colour)
				.ignoresSafeArea()
		#else
			ColorPicker("Colour", selection: Binding {
				Color(.sRGB, red: Double(colour.x), green: Double(colour.y), blue: Double(colour.z))
			} set: { picked in
				if let value = SystemColourPicker.components(of: picked) {
					colour = value
				}
			}, supportsOpacity: false)
				.padding(40)
		#endif
	}

	static func components(of colour: Color) -> SIMD3<Float>? {
		guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
		      let components = colour.resolve(in: EnvironmentValues()).cgColor.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
		      components.count >= 3
		else {
			return nil
		}
		let channel = { (value: CGFloat) in Float(min(max(value, 0), 1)) }
		return SIMD3<Float>(channel(components[0]), channel(components[1]), channel(components[2]))
	}
}

#if os(iOS)
	private struct SystemColourPickerController: UIViewControllerRepresentable {
		@Binding var colour: SIMD3<Float>

		func makeUIViewController(context: Context) -> UIColorPickerViewController {
			let picker = UIColorPickerViewController()
			picker.supportsAlpha = false
			picker.selectedColor = UIColor(red: CGFloat(colour.x), green: CGFloat(colour.y), blue: CGFloat(colour.z), alpha: 1)
			picker.delegate = context.coordinator
			return picker
		}

		func updateUIViewController(_: UIColorPickerViewController, context: Context) {
			context.coordinator.colour = $colour
		}

		func makeCoordinator() -> Coordinator {
			Coordinator(colour: $colour)
		}

		final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
			var colour: Binding<SIMD3<Float>>

			init(colour: Binding<SIMD3<Float>>) {
				self.colour = colour
			}

			func colorPickerViewController(_: UIColorPickerViewController, didSelect color: UIColor, continuously _: Bool) {
				if let value = SystemColourPicker.components(of: Color(uiColor: color)) {
					colour.wrappedValue = value
				}
			}
		}
	}
#endif

/// One colour you can tap to edit
private struct Swatch: View {
	let color: SIMD3<Float>
	let selected: Bool
	let label: String
	let action: () -> Void

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		Button(action: action) {
			PixelFrame(step: 2)
				.fill(Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
				.overlay { PixelFrame(step: 2).strokeBorder(selected ? theme.ink : theme.mid, lineWidth: selected ? 3 : 2) }
				.frame(width: 30, height: 30)
				.offset(y: selected ? -3 : 0)
				.contentShape(Rectangle())
		}
		.buttonStyle(PixelButtonStyle())
		.accessibilityLabel(label)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}

private struct MorePage: View {
	@Bindable var model: AppModel

	/// Reset takes a second tap, so it can't happen by accident
	@State private var confirmingReset = false

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		VStack(spacing: 8) {
			HStack(spacing: 8) {
				ForEach([LibrarySheet.palettes, .looks, .settings]) { sheet in
					Button {
						model.sheet = sheet
					} label: {
						VStack(spacing: 6) {
							PixelIconView(icon: sheet.icon, cell: 2, color: theme.ink)
							PixelText(sheet.title, cell: 1.6, color: theme.ink)
						}
						.frame(maxWidth: .infinity)
						.pixelPanel(padding: 10)
					}
					.accessibilityLabel(sheet.title.capitalized)
				}
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
		}
		.buttonStyle(PixelButtonStyle())
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
			ChipSounds.shared.play(isOn ? .toggleOn : .toggleOff)
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
		// Words wrap to the width there is, so a long note never pushes its container wider
		PixelWords(text: text, cell: 1.3, color: theme.mid)
			.frame(maxWidth: .infinity)
			.pixelPanel(padding: 8)
	}
}

/// Pixel text that wraps between words, centred line by line.
struct PixelWords: View {
	let text: String
	var cell: CGFloat = 1.3
	var color: Color = .white

	var body: some View {
		WordFlow(spacing: cell * 4, lineSpacing: cell * 3) {
			ForEach(Array(text.split(separator: " ").enumerated()), id: \.offset) { _, word in
				PixelText(String(word), cell: cell, color: color)
			}
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(text.capitalized)
	}
}

/// Lays words left to right, starting a new line when the next won't fit, each line centred.
struct WordFlow: Layout {
	var spacing: CGFloat
	var lineSpacing: CGFloat

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
		let lines = lines(for: subviews, width: proposal.width ?? .infinity)
		let width = lines.map(\.width).max() ?? 0
		let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
		return CGSize(width: min(width, proposal.width ?? width), height: height)
	}

	func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
		var y = bounds.minY
		for line in lines(for: subviews, width: bounds.width) {
			var x = bounds.midX - line.width / 2
			for index in line.indices {
				let size = subviews[index].sizeThatFits(.unspecified)
				subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
				x += size.width + spacing
			}
			y += line.height + lineSpacing
		}
	}

	private struct Line {
		var indices: [Int] = []
		var width: CGFloat = 0
		var height: CGFloat = 0
	}

	private func lines(for subviews: Subviews, width: CGFloat) -> [Line] {
		var lines: [Line] = []
		var current = Line()
		for index in subviews.indices {
			let size = subviews[index].sizeThatFits(.unspecified)
			let extra = current.indices.isEmpty ? size.width : current.width + spacing + size.width
			if !current.indices.isEmpty, extra > width {
				lines.append(current)
				current = Line()
			}
			current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
			current.height = max(current.height, size.height)
			current.indices.append(index)
		}
		if !current.indices.isEmpty {
			lines.append(current)
		}
		return lines
	}
}

/// A pixel square of colour that opens the system colour picker.

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

