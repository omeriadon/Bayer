import simd
import SwiftUI

/// Every setting that changes the picture. Ranges come from `bounded()`.
struct DebugPanel: View {
	@Bindable var model: AppModel

	@Environment(\.pixelTheme) private var theme
	@State private var copied = false

	var body: some View {
		NavigationStack {
			Form {
				if !model.camera.usesCamera {
					waveSection
				}
				mappingSection
				cellsSection
				ditherSection
				paletteSection
				actionsSection
			}
			.formStyle(.grouped)
			.scrollContentBackground(.hidden)
			.font(.system(.footnote, design: .monospaced))
			.toolbar {
				ToolbarItem(placement: .principal) {
					PixelText("DEBUG", cell: 2.2, color: theme.ink)
				}
			}
			#if os(iOS)
				.navigationBarTitleDisplayMode(.inline)
			#endif
		}
		.presentationBackground(theme.shade.opacity(0.94))
		.tint(theme.ink)
		// Every toggle, picker, stepper and button hits; continuous sliders stay quiet
		.sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: model.camera)
		.sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: Discrete(model.configuration))
		.sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: copied)
	}

	/// The settings that change in steps, not continuously
	private struct Discrete: Equatable {
		let mode: Int
		let join: Bool
		let animate: Bool
		let direction: Float
		let framesPerSecond: Int
		let paletteCount: Int
		let pixelSize: Float

		init(_ c: DitherConfiguration) {
			mode = c.ditherMode
			join = c.joinAdjacentSquares
			animate = !c.disableAnimation
			direction = c.waveDirection
			framesPerSecond = c.framesPerSecond
			paletteCount = c.palette.count
			pixelSize = c.pixelSize
		}
	}

	// MARK: Sections

	private var waveSection: some View {
		Section {
			Toggle("Animate", isOn: Binding {
				!model.configuration.disableAnimation
			} set: {
				model.configuration.disableAnimation = !$0
			})
			SliderRow("Speed", value: $model.configuration.waveSpeed, in: 0 ... 1)
			Picker("Direction", selection: $model.configuration.waveDirection) {
				ForEach(0 ..< 8) { index in
					let degrees = Float(index * 45)
					Text("\(DitherConfiguration.compassDirection(for: degrees)) · \(index * 45)°").tag(degrees)
				}
			}
			SliderRow("Frequency", value: $model.configuration.waveFrequency, in: 0.01 ... 12)
			SliderRow("Amplitude", value: $model.configuration.waveAmplitude, in: 0 ... 1)
			LogSliderRow("Scale", value: $model.configuration.scale, in: 0.05 ... 32)
			StepperRow("Frames per second", value: $model.configuration.framesPerSecond, in: 1 ... 60, label: "\(model.configuration.framesPerSecond)")
		} header: {
			Text("Wave")
		} footer: {
			Text("The camera is off, so the picture is a generated wave field. Good for wallpapers.")
		}
	}

	private var mappingSection: some View {
		Section {
			Picker("Mapping", selection: $model.camera.mapping) {
				ForEach(CameraSettings.Mapping.allCases, id: \.self) { mapping in
					Text(mapping.title).tag(mapping)
				}
			}
			.pickerStyle(.segmented)
			Toggle("Invert", isOn: $model.camera.invert)
		} header: {
			Text("Mapping")
		} footer: {
			switch model.camera.mapping {
				case .exact: Text("Every cell is exactly one palette colour, darkest first.")
				case .blend: Text("Brightness picks a palette colour and how strongly it shows over the gap colour. Shadows fall away.")
				case .source: Text("The picture's own colours, each channel dithered to the colour levels below.")
			}
		}
	}

	private var cellsSection: some View {
		Section {
			SliderRow("Gap", value: $model.configuration.gap, in: 0 ... 0.45)
			SliderRow("Corner radius", value: $model.configuration.cornerRadius, in: 0 ... 0.5)
			Toggle("Join adjacent squares", isOn: $model.configuration.joinAdjacentSquares)
		} header: {
			Text("Cells")
		} footer: {
			Text("Joining needs no gap and some corner radius.")
		}
	}

	private var ditherSection: some View {
		Section {
			SliderRow("Colour levels", value: $model.configuration.colorNum, in: 2 ... 16, step: 1, format: .integer)
				.disabled(model.camera.mapping == .exact)
			SliderRow("Contrast", value: $model.configuration.contrast, in: 0.1 ... 4)
			SliderRow("Brightness", value: $model.configuration.brightness, in: -1 ... 1)
		} header: {
			Text("Dither")
		} footer: {
			Text("Colour levels apply to Blend and Source. Exact uses the palette's own colours.")
		}
	}

	private var paletteSection: some View {
		Section {
			ForEach(model.configuration.palette.indices, id: \.self) { index in
				ColorRow("Colour \(index + 1)", value: paletteBinding(index))
			}
			.onDelete { offsets in
				// Two colours at least, or there's nothing to dither between
				guard model.configuration.palette.count - offsets.count >= 2 else {
					return
				}
				model.configuration.palette.remove(atOffsets: offsets)
			}
			if model.configuration.palette.count < DitherConfiguration.supportedPaletteCount {
				Button("Add colour") {
					model.configuration.palette.append(model.configuration.palette.last ?? SIMD3<Float>(repeating: 1))
				}
			}
			ColorRow("Gap colour", value: $model.configuration.backgroundColor)
		} header: {
			Text("Palette")
		} footer: {
			Text("Darkest first. Swipe a colour to remove it; two to eight. The gap colour shows between cells.")
		}
	}

	private var actionsSection: some View {
		Section {
			Button(copied ? "Copied" : "Copy configuration as Swift") {
				Platform.copy(SwiftExport.code(for: model.configuration.pinned(usesCamera: model.camera.usesCamera)))
				copied = true
				Task {
					try? await Task.sleep(for: .seconds(1.5))
					copied = false
				}
			}
			Button("Reset everything", role: .destructive) {
				model.reset()
			}
		} footer: {
			Text("The copied code is a DitherConfiguration you can paste into another project.")
		}
	}

	private func paletteBinding(_ index: Int) -> Binding<SIMD3<Float>> {
		Binding {
			index < model.configuration.palette.count ? model.configuration.palette[index] : .zero
		} set: { value in
			if index < model.configuration.palette.count {
				model.configuration.palette[index] = value
			}
		}
	}
}

// MARK: Rows

enum ValueFormat {
	case decimal, percent, integer, points, seconds

	func text(_ value: Double) -> String {
		switch self {
			case .decimal: value.formatted(.number.precision(.fractionLength(2)))
			case .percent: value.formatted(.percent.precision(.fractionLength(0)))
			case .integer: "\(Int(value.rounded()))"
			case .points: "\(Int(value.rounded())) pt"
			case .seconds: value.formatted(.number.precision(.fractionLength(2))) + " s"
		}
	}
}

private struct SliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
	let title: String
	@Binding var value: Value
	let range: ClosedRange<Value>
	var step: Value.Stride?
	var format: ValueFormat

	init(_ title: String, value: Binding<Value>, in range: ClosedRange<Value>, step: Value.Stride? = nil, format: ValueFormat = .decimal) {
		self.title = title
		_value = value
		self.range = range
		self.step = step
		self.format = format
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			LabeledContent(title, value: format.text(Double(value)))
			if let step {
				Slider(value: $value, in: range, step: step)
			} else {
				Slider(value: $value, in: range)
			}
		}
		.accessibilityElement(children: .combine)
	}
}

/// For ranges that span orders of magnitude, like scale.
private struct LogSliderRow: View {
	let title: String
	@Binding var value: Float
	let range: ClosedRange<Float>

	init(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>) {
		self.title = title
		_value = value
		self.range = range
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			LabeledContent(title, value: ValueFormat.decimal.text(Double(value)))
			Slider(
				value: Binding(
					get: { log2(min(max(value, range.lowerBound), range.upperBound)) },
					set: { value = exp2($0) }
				),
				in: log2(range.lowerBound) ... log2(range.upperBound)
			)
		}
		.accessibilityElement(children: .combine)
	}
}

private struct StepperRow: View {
	let title: String
	@Binding var value: Int
	let range: ClosedRange<Int>
	var step = 1
	let label: String

	init(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1, label: String) {
		self.title = title
		_value = value
		self.range = range
		self.step = step
		self.label = label
	}

	var body: some View {
		Stepper(value: $value, in: range, step: step) {
			LabeledContent(title, value: label)
		}
	}
}

private struct ColorRow: View {
	let title: String
	@Binding var value: SIMD3<Float>

	init(_ title: String, value: Binding<SIMD3<Float>>) {
		self.title = title
		_value = value
	}

	var body: some View {
		ColorPicker(title, selection: Binding {
			Color(.sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z))
		} set: { color in
			// Picked colours can be extended or P3; the shader wants sRGB clamped to 0...1
			guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
			      let components = color.resolve(in: EnvironmentValues()).cgColor.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
			      components.count >= 3
			else {
				return
			}
			let channel = { (value: CGFloat) in Float(min(max(value, 0), 1)) }
			value = SIMD3<Float>(channel(components[0]), channel(components[1]), channel(components[2]))
		}, supportsOpacity: false)
	}
}

// MARK: Export

/// Writes a configuration in the same shape as Ergo's `detailViewConf`.
enum SwiftExport {
	static func code(for c: DitherConfiguration) -> String {
		func f(_ value: Float) -> String { trim(Double(value)) }
		func d(_ value: Double) -> String { trim(value) }
		func trim(_ value: Double) -> String {
			// POSIX so the decimal point is always a dot, whatever the phone's region
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
