import simd
import SwiftUI

// MARK: Theme

/// The UI takes its colours from the current palette, so the chrome always matches the picture.
struct PixelTheme: Equatable {
	var ink: Color
	var mid: Color
	var shade: Color
	var paper: Color

	init(palette: [SIMD3<Float>]) {
		func color(_ value: SIMD3<Float>) -> Color {
			Color(.sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z))
		}
		let sorted = palette.sorted { luminance($0) < luminance($1) }
		let darkest = sorted.first ?? .zero
		let lightest = sorted.last ?? SIMD3<Float>(repeating: 1)
		let middle = sorted.count > 2 ? sorted[sorted.count / 2] : (darkest + lightest) / 2
		ink = color(lightest)
		mid = color(middle)
		// Panels sit a touch darker than the darkest palette colour so they read over the picture
		shade = color(darkest * 0.55)
		paper = color(darkest)
	}

	static let fallback = PixelTheme(palette: DitherPalette.all[0].colors)
}

private func luminance(_ value: SIMD3<Float>) -> Float {
	simd_dot(value, SIMD3<Float>(0.2126, 0.7152, 0.0722))
}

extension EnvironmentValues {
	@Entry var pixelTheme = PixelTheme.fallback
}

// MARK: Icons

/// 9×9 pixel icons.
enum PixelIcon: String {
	case flip, bug, close, minus, plus, grid, pattern, camera, check, photo, tune, levels, contrast, drop, wave, more, lidar, expand, load

	var rows: [String] {
		switch self {
			case .flip: [
					"..#......",
					".##......",
					"#########",
					".##......",
					"..#......",
					"......#..",
					"......##.",
					"#########",
					"......##.",
				]
			case .bug: [
					"#.......#",
					".#.###.#.",
					"..#####..",
					"#.##.##.#",
					".#######.",
					"#.##.##.#",
					".#######.",
					"#.#####.#",
					"...###...",
				]
			case .close: [
					"##.....##",
					"###...###",
					".###.###.",
					"..#####..",
					"...###...",
					"..#####..",
					".###.###.",
					"###...###",
					"##.....##",
				]
			case .minus: [
					".........",
					".........",
					".........",
					".........",
					"#########",
					".........",
					".........",
					".........",
					".........",
				]
			case .plus: [
					"....#....",
					"....#....",
					"....#....",
					"....#....",
					"#########",
					"....#....",
					"....#....",
					"....#....",
					"....#....",
				]
			case .grid: [
					"##.##.##.",
					"##.##.##.",
					".........",
					"##.##.##.",
					"##.##.##.",
					".........",
					"##.##.##.",
					"##.##.##.",
					".........",
				]
			case .pattern: [
					"#########",
					"##.#.#.#.",
					"#.#.#.#..",
					"##.#.#...",
					"#.#.#....",
					"##.#.....",
					"#.#......",
					"##.......",
					"#........",
				]
			case .camera: [
					"..###....",
					"#########",
					"#...#...#",
					"#..###..#",
					"#.##.##.#",
					"#..###..#",
					"#...#...#",
					"#########",
					".........",
				]
			case .check: [
					".........",
					"........#",
					".......##",
					"......##.",
					"#....##..",
					"##..##...",
					".####....",
					"..##.....",
					".........",
				]
			case .tune: [
					".#..#..#.",
					".#..#..#.",
					"###.#..#.",
					".#..#..#.",
					".#.###.#.",
					".#..#..#.",
					".#..#.###",
					".#..#..#.",
					".#..#..#.",
				]
			case .levels: [
					".........",
					"......###",
					"......###",
					"...######",
					"...######",
					"#########",
					"#########",
					"#########",
					".........",
				]
			case .contrast: [
					"..#####..",
					".#..####.",
					"#...#####",
					"#...#####",
					"#...#####",
					"#...#####",
					"#...#####",
					".#..####.",
					"..#####..",
				]
			case .drop: [
					"....#....",
					"...###...",
					"...###...",
					"..#####..",
					".#######.",
					".######.#",
					".#####.##",
					"..#####..",
					"...###...",
				]
			case .wave: [
					".........",
					".##...##.",
					"#..#.#..#",
					"....#....",
					".........",
					".##...##.",
					"#..#.#..#",
					"....#....",
					".........",
				]
			// A tray with an arrow coming in: bring a photo in
			case .load: [
					"....#....",
					"....#....",
					"..#.#.#..",
					"...###...",
					"....#....",
					"#.......#",
					"#.......#",
					"#########",
					".........",
				]
			// Four corners pointing out: full screen
			case .expand: [
					"###...###",
					"##.....##",
					"#.#...#.#",
					".........",
					".........",
					".........",
					"#.#...#.#",
					"##.....##",
					"###...###",
				]
			// The scanner's dot grid, thinning towards the edges like a projected pattern
			case .lidar: [
					"#...#...#",
					".........",
					"..#.#.#..",
					".........",
					"#.#.#.#.#",
					".........",
					"..#.#.#..",
					".........",
					"#...#...#",
				]
			case .more: [
					".........",
					".........",
					".........",
					"##.##.##.",
					"##.##.##.",
					".........",
					".........",
					".........",
					".........",
				]
			case .photo: [
					"#########",
					"#.......#",
					"#.##....#",
					"#.##....#",
					"#.....#.#",
					"#....###.",
					"#.#.#####",
					"#########",
					".........",
				]
		}
	}
}

struct PixelIconView: View {
	let icon: PixelIcon
	var cell: CGFloat = 2.5
	var color: Color = .white

	var body: some View {
		PixelCells(
			columns: 9,
			rows: 9,
			lit: icon.rows.flatMap { $0.map { $0 == "#" } },
			cell: cell,
			gap: 0.1,
			color: color
		)
		.accessibilityHidden(true)
	}
}

// MARK: Frames

/// A rectangle with stepped corners, like a window border in an old game.
nonisolated struct PixelFrame: InsettableShape {
	var step: CGFloat = 3
	var inset: CGFloat = 0

	func path(in rect: CGRect) -> Path {
		let r = rect.insetBy(dx: inset, dy: inset)
		let s = min(step, r.width / 4, r.height / 4)
		var path = Path()
		path.move(to: CGPoint(x: r.minX + s * 2, y: r.minY))
		path.addLine(to: CGPoint(x: r.maxX - s * 2, y: r.minY))
		path.addLine(to: CGPoint(x: r.maxX - s * 2, y: r.minY + s))
		path.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
		path.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s * 2))
		path.addLine(to: CGPoint(x: r.maxX, y: r.minY + s * 2))
		path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - s * 2))
		path.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - s * 2))
		path.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - s))
		path.addLine(to: CGPoint(x: r.maxX - s * 2, y: r.maxY - s))
		path.addLine(to: CGPoint(x: r.maxX - s * 2, y: r.maxY))
		path.addLine(to: CGPoint(x: r.minX + s * 2, y: r.maxY))
		path.addLine(to: CGPoint(x: r.minX + s * 2, y: r.maxY - s))
		path.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - s))
		path.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - s * 2))
		path.addLine(to: CGPoint(x: r.minX, y: r.maxY - s * 2))
		path.addLine(to: CGPoint(x: r.minX, y: r.minY + s * 2))
		path.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s * 2))
		path.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s))
		path.addLine(to: CGPoint(x: r.minX + s * 2, y: r.minY + s))
		path.closeSubpath()
		return path
	}

	func inset(by amount: CGFloat) -> PixelFrame {
		var copy = self
		copy.inset += amount
		return copy
	}
}

/// A panel: a stepped frame filled with the theme's shade and outlined in its ink.
struct PixelPanel: ViewModifier {
	var lit = false
	var padding: CGFloat = 8

	@Environment(\.pixelTheme) private var theme

	func body(content: Content) -> some View {
		content
			.padding(padding)
			.background {
				PixelFrame()
					.fill(lit ? theme.ink : theme.shade.opacity(0.92))
					.overlay {
						PixelFrame().strokeBorder(lit ? theme.ink : theme.mid, lineWidth: 2.5)
					}
			}
			.contentShape(PixelFrame())
	}
}

extension View {
	func pixelPanel(lit: Bool = false, padding: CGFloat = 8) -> some View {
		modifier(PixelPanel(lit: lit, padding: padding))
	}
}

// MARK: Buttons

/// Pressed buttons drop by a pixel and dim, like a hardware key, with a hard hit going down and a tick coming up.
struct PixelButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.offset(y: configuration.isPressed ? 2 : 0)
			.opacity(configuration.isPressed ? 0.75 : 1)
			.animation(.snappy(duration: 0.08), value: configuration.isPressed)
			.sensoryFeedback(trigger: configuration.isPressed) { _, pressed in
				pressed ? .impact(weight: .heavy, intensity: 1) : .impact(flexibility: .rigid, intensity: 0.55)
			}
			.onChange(of: configuration.isPressed) { _, pressed in
				if pressed {
					ChipSounds.shared.play(.click)
				}
			}
	}
}

extension SensoryFeedback {
	/// The tick for each step of a pixel track
	static let pixelStep = SensoryFeedback.impact(flexibility: .rigid, intensity: 0.85)
}

struct PixelIconButton: View {
	let icon: PixelIcon
	var lit = false
	let label: String
	let action: () -> Void

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		Button(action: action) {
			PixelIconView(icon: icon, cell: 2.5, color: lit ? theme.paper : theme.ink)
				.frame(width: 28, height: 28)
				.pixelPanel(lit: lit, padding: 6)
		}
		.buttonStyle(PixelButtonStyle())
		.accessibilityLabel(label)
	}
}

// MARK: Shutter

/// A pixel-art ring that fills in while pressed.
struct PixelShutter: View {
	var capturing = false
	let action: () -> Void
	/// Pressing and holding: a Live Photo with the wave. Without it, holding just takes a photo.
	var hold: (() -> Void)?

	@State private var pressed = false
	@Environment(\.pixelTheme) private var theme

	var body: some View {
		ShutterFace(capturing: capturing, theme: theme)
			.environment(\.shutterPressed, pressed)
			.contentShape(Rectangle())
			.onTapGesture(perform: action)
			.onLongPressGesture(minimumDuration: 0.5) {
				(hold ?? action)()
			} onPressingChanged: { pressing in
				pressed = pressing
			}
			.sensoryFeedback(trigger: pressed) { _, pressed in
				pressed ? .impact(weight: .heavy, intensity: 1) : .impact(weight: .medium, intensity: 0.8)
			}
			.accessibilityElement()
			.accessibilityLabel("Take photo")
			.accessibilityAddTraits(.isButton)
			.accessibilityAction {
				action()
			}
			.accessibilityActions {
				if let hold {
					Button("Hold the shutter", action: hold)
				}
			}
	}

	private struct ShutterFace: View {
		let capturing: Bool
		let theme: PixelTheme
		@Environment(\.shutterPressed) private var pressed

		var body: some View {
			let size = 15
			let center = Double(size - 1) / 2
			var disc: [Bool] = []
			var ring: [Bool] = []
			var core: [Bool] = []
			for y in 0 ..< size {
				for x in 0 ..< size {
					let distance = hypot(Double(x) - center, Double(y) - center)
					disc.append(distance <= 7.4)
					ring.append(distance <= 7.2 && distance > 5.9)
					core.append(distance <= (pressed ? 4.0 : 4.9))
				}
			}
			return ZStack {
				// A solid backing so the shutter reads over any picture
				PixelCells(columns: size, rows: size, lit: disc, cell: 5, gap: 0, color: theme.shade.opacity(0.92))
				PixelCells(columns: size, rows: size, lit: ring, cell: 5, gap: 0.1, color: theme.ink)
				PixelCells(columns: size, rows: size, lit: core, cell: 5, gap: 0.1, color: capturing ? theme.mid : theme.ink)
			}
			.animation(.snappy(duration: 0.1), value: pressed)
		}
	}
}

extension EnvironmentValues {
	@Entry var shutterPressed = false
}

// MARK: Dissolve

/// Thins a view out in Bayer cells. 1 is fully shown, 0 is gone. Animatable, so it works as a transition.
struct PixelDissolve: ViewModifier, Animatable {
	var amount: Double
	var cell: CGFloat = 2.5

	var animatableData: Double {
		get { amount }
		set { amount = newValue }
	}

	/// Gone entirely once fully shown, not just disabled. A shader can't draw a scroll view through it, so
	/// leaving it in place blanked the palette strip, which sits inside the dissolving controls.
	@ViewBuilder
	func body(content: Content) -> some View {
		if amount < 1 {
			content.colorEffect(ShaderLibrary.pixelDissolve(.float(amount), .float(cell)))
		} else {
			content
		}
	}
}

extension AnyTransition {
	/// Appears and disappears cell by cell.
	static var pixelDissolve: AnyTransition {
		.modifier(active: PixelDissolve(amount: 0), identity: PixelDissolve(amount: 1))
	}
}

// MARK: Track

/// A row of cells you drag along: a title, the track, and its value.
/// `fills` lights everything up to the current step; otherwise only the current step lights, for picking one of several.
struct PixelTrack: View {
	let title: String
	let value: String
	let count: Int
	@Binding var index: Int
	var fills = true
	var titleWidth: CGFloat = 84
	var valueWidth: CGFloat = 70

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		HStack(spacing: 10) {
			PixelText(title, cell: 1.7, color: theme.mid)
				.frame(width: titleWidth, alignment: .leading)
			GeometryReader { proxy in
				Canvas { context, size in
					// Cells stay roughly square however many steps there are. A filling track
					// doesn't need a column per step, so long fine-grained lists don't squash it.
					let square = max(1, Int(size.width / (size.height / 2)))
					let target = fills ? square : max(count, square)
					let perStep = max(1, target / max(count, 1))
					let columns = fills ? target : count * perStep
					let width = size.width / CGFloat(columns)
					let height = size.height / 2
					let litColumns = count > 1 ? Int((Double(index) / Double(count - 1) * Double(columns)).rounded()) : columns
					var lit = Path()
					var dim = Path()
					for column in 0 ..< columns {
						let on = fills ? column < litColumns : column / perStep == index
						for row in 0 ..< 2 {
							let rect = CGRect(x: CGFloat(column) * width, y: CGFloat(row) * height, width: width, height: height)
								.insetBy(dx: min(width, height) * 0.16, dy: min(width, height) * 0.16)
							let radius = min(rect.width, rect.height) * 0.22
							if on {
								lit.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
							} else {
								dim.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
							}
						}
					}
					context.fill(dim, with: .color(theme.mid.opacity(0.3)))
					context.fill(lit, with: .color(theme.ink))
				}
				.contentShape(Rectangle())
				.gesture(
					DragGesture(minimumDistance: 0)
						.onChanged { drag in
							let fraction = min(max(drag.location.x / max(proxy.size.width, 1), 0), 1)
							let step = fills
								? Int((fraction * CGFloat(count - 1)).rounded())
								: min(count - 1, Int(fraction * CGFloat(count)))
							if step != index {
								index = step
							}
						}
				)
			}
			.frame(height: 14)
			PixelText(value, cell: 2, color: theme.ink)
				.frame(width: valueWidth, alignment: .trailing)
		}
		.padding(.vertical, 2)
		.pixelPanel(padding: 9)
		.sensoryFeedback(.pixelStep, trigger: index)
		.onChange(of: index) { _, step in
			ChipSounds.shared.play(.tick(count > 1 ? Double(step) / Double(count - 1) : 0))
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(title.capitalized)
		.accessibilityValue(value.capitalized)
		.accessibilityAdjustableAction { direction in
			switch direction {
				case .increment: index = min(count - 1, index + 1)
				case .decrement: index = max(0, index - 1)
				@unknown default: break
			}
		}
	}
}

/// One track with two ends over a fixed list of values. The lit run between the ends is the range;
/// a drag moves whichever end is nearer where it starts.
struct PixelRangeTrack: View {
	let title: String
	let values: [Float]
	@Binding var lower: Float
	@Binding var upper: Float
	/// What VoiceOver calls each end
	var lowerName = "Lower"
	var upperName = "Upper"
	/// The upper end stays at least this many times the lower
	var minimumRatio: Float = 1
	let format: (Float) -> String
	var unit = ""

	@Environment(\.pixelTheme) private var theme
	@State private var grabbed: End?

	private enum End {
		case lower, upper
	}

	var body: some View {
		VStack(spacing: 10) {
			HStack(spacing: 10) {
				PixelText(title, cell: 1.7, color: theme.mid)
				Spacer(minLength: 8)
				PixelText(format(lower) + "-" + format(upper) + unit, cell: 2, color: theme.ink)
			}
			GeometryReader { proxy in
				Canvas { context, size in
					// Square cells, however many stops there are
					let height = size.height / 2
					let columns = max(2, Int(size.width / height))
					let width = size.width / CGFloat(columns)
					let first = column(for: lowerIndex, of: columns)
					let last = column(for: upperIndex, of: columns)
					var ends = Path()
					var run = Path()
					var dim = Path()
					for column in 0 ..< columns {
						for row in 0 ..< 2 {
							let rect = CGRect(x: CGFloat(column) * width, y: CGFloat(row) * height, width: width, height: height)
								.insetBy(dx: min(width, height) * 0.16, dy: min(width, height) * 0.16)
							let radius = min(rect.width, rect.height) * 0.22
							let corner = CGSize(width: radius, height: radius)
							if column == first || column == last {
								ends.addRoundedRect(in: rect, cornerSize: corner)
							} else if column > first, column < last {
								run.addRoundedRect(in: rect, cornerSize: corner)
							} else {
								dim.addRoundedRect(in: rect, cornerSize: corner)
							}
						}
					}
					context.fill(dim, with: .color(theme.mid.opacity(0.3)))
					context.fill(run, with: .color(theme.ink.opacity(0.55)))
					context.fill(ends, with: .color(theme.ink))
				}
				.contentShape(Rectangle())
				.gesture(
					DragGesture(minimumDistance: 0)
						.onChanged { drag in
							let fraction = min(max(drag.location.x / max(proxy.size.width, 1), 0), 1)
							let step = Int((fraction * CGFloat(values.count - 1)).rounded())
							let end = grabbed ?? (abs(step - lowerIndex) <= abs(step - upperIndex) ? .lower : .upper)
							grabbed = end
							move(end, to: step)
						}
						.onEnded { _ in
							grabbed = nil
						}
				)
			}
			.frame(height: 14)
		}
		.padding(.vertical, 2)
		.pixelPanel(padding: 9)
		.sensoryFeedback(.pixelStep, trigger: lowerIndex * 10000 + upperIndex)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(title.capitalized)
		.accessibilityChildren {
			endElement(.lower, name: lowerName)
			endElement(.upper, name: upperName)
		}
	}

	private func endElement(_ end: End, name: String) -> some View {
		let index = end == .lower ? lowerIndex : upperIndex
		return Rectangle()
			.accessibilityLabel(name)
			.accessibilityValue((format(values[index]) + unit).capitalized)
			.accessibilityAdjustableAction { direction in
				switch direction {
					case .increment: move(end, to: index + 1)
					case .decrement: move(end, to: index - 1)
					@unknown default: break
				}
			}
	}

	private func nearestIndex(to value: Float) -> Int {
		values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) } ?? 0
	}

	private var lowerIndex: Int {
		nearestIndex(to: lower)
	}

	private var upperIndex: Int {
		nearestIndex(to: upper)
	}

	private func column(for index: Int, of columns: Int) -> Int {
		guard values.count > 1 else {
			return 0
		}
		return Int((Double(index) / Double(values.count - 1) * Double(columns - 1)).rounded())
	}

	/// Moves one end, stopping where it would get too close to the other
	private func move(_ end: End, to step: Int) {
		guard !values.isEmpty else {
			return
		}
		let step = min(max(step, 0), values.count - 1)
		let index: Int
		switch end {
			case .lower:
				let highest = values.lastIndex { $0 * minimumRatio <= upper + 0.0001 } ?? 0
				index = min(step, highest)
				guard index != lowerIndex else {
					return
				}
				lower = values[index]
			case .upper:
				let lowest = values.firstIndex { $0 >= lower * minimumRatio - 0.0001 } ?? values.count - 1
				index = max(step, lowest)
				guard index != upperIndex else {
					return
				}
				upper = values[index]
		}
		ChipSounds.shared.play(.tick(values.count > 1 ? Double(index) / Double(values.count - 1) : 0))
	}
}
