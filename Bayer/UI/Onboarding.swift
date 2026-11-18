import SwiftUI

/// The first launch: a few pages on a pixel card, over the live wave, ending with the camera request.
struct Onboarding: View {
	let finish: () -> Void

	@State private var page = 0

	@Environment(\.pixelTheme) private var theme

	private struct Page {
		let icon: PixelIcon
		let title: String
		let body: String
	}

	private let pages = [
		Page(icon: .camera, title: "BAYER", body: "A CAMERA THAT SEES IN DITHER. EVERY FRAME IS DRAWN IN PIXELS, LIVE."),
		Page(icon: .grid, title: "SIZE", body: "EACH CELL IS THE EXACT AVERAGE OF A SQUARE OF CAMERA PIXELS: 1:1, 1:4, 1:9 AND UP."),
		Page(icon: .pattern, title: "STYLE AND INK", body: "PICK A PATTERN AND A PALETTE. DRAG THE DITHER TRACK TO SOFTEN IT. PINCH TO ZOOM."),
		Page(icon: .tune, title: "TUNE", body: "TOP RIGHT. OPENS EVERYTHING ELSE: MAPPING, CELLS, TONE AND YOUR OWN COLOURS."),
		Page(icon: .wave, title: "NO CAMERA NEEDED", body: "TAP CAM AT TOP LEFT TO SWITCH TO DITHER, A MOVING WAVE WITH NO CAMERA. GOOD FOR WALLPAPERS."),
		Page(icon: .check, title: "READY", body: "BAYER NEEDS YOUR CAMERA TO SEE. PHOTOS SAVE AS CRISP PNGS, EXACTLY AS SHOWN."),
	]

	private var isLast: Bool {
		page == pages.count - 1
	}

	var body: some View {
		VStack(spacing: 18) {
			// Each page dissolves into the next in the same place
			ZStack {
				let current = pages[page]
				VStack(spacing: 16) {
					PixelIconView(icon: current.icon, cell: 6, color: theme.ink)
					PixelText(current.title, cell: 3.5, color: theme.ink)
					PixelParagraph(text: current.body, cell: 2, color: theme.mid, maximumCharacters: 24)
				}
				.frame(maxWidth: .infinity, minHeight: 210)
				.id(page)
				.transition(.pixelDissolve)
			}

			PageDots(count: pages.count, current: page)

			HStack(spacing: 8) {
				if !isLast {
					Button {
						finish()
					} label: {
						PixelText("SKIP", cell: 2, color: theme.mid)
							.frame(maxWidth: .infinity)
							.pixelPanel(padding: 12)
					}
					.accessibilityLabel("Skip the welcome")
				}
				Button {
					if isLast {
						finish()
					} else {
						page += 1
					}
				} label: {
					PixelText(isLast ? "ALLOW CAMERA" : "NEXT", cell: 2, color: theme.paper)
						.frame(maxWidth: .infinity)
						.pixelPanel(lit: true, padding: 12)
				}
				.accessibilityLabel(isLast ? "Allow camera" : "Next")
			}
			.buttonStyle(PixelButtonStyle())
		}
		.padding(18)
		.frame(maxWidth: 380)
		.pixelPanel(padding: 4)
		.padding(20)
		.animation(.easeInOut(duration: 0.28), value: page)
		.sensoryFeedback(.pixelStep, trigger: page)
		// Swipe between pages too
		.gesture(
			DragGesture(minimumDistance: 30)
				.onEnded { drag in
					if drag.translation.width < -40, page < pages.count - 1 {
						page += 1
					} else if drag.translation.width > 40, page > 0 {
						page -= 1
					}
				}
		)
	}
}

/// Pixel text across several lines, broken between words.
struct PixelParagraph: View {
	let text: String
	var cell: CGFloat = 2
	var color: Color = .white
	var maximumCharacters = 24

	var body: some View {
		VStack(spacing: cell * 3) {
			ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
				PixelText(line, cell: cell, color: color)
			}
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(text.capitalized)
	}

	private var lines: [String] {
		var lines: [String] = []
		var current = ""
		for word in text.split(separator: " ") {
			if current.isEmpty {
				current = String(word)
			} else if current.count + 1 + word.count <= maximumCharacters {
				current += " " + word
			} else {
				lines.append(current)
				current = String(word)
			}
		}
		if !current.isEmpty {
			lines.append(current)
		}
		return lines
	}
}

/// Which page, as a row of cells.
private struct PageDots: View {
	let count: Int
	let current: Int

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		HStack(spacing: 6) {
			ForEach(0 ..< count, id: \.self) { index in
				Rectangle()
					.fill(index == current ? theme.ink : theme.mid.opacity(0.35))
					.frame(width: index == current ? 14 : 6, height: 6)
			}
		}
		.animation(.snappy(duration: 0.2), value: current)
		.accessibilityElement()
		.accessibilityLabel("Page \(current + 1) of \(count)")
	}
}
