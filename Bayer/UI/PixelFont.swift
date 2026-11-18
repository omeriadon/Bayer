import SwiftUI

/// A 5×7 bitmap font. Each glyph is seven rows of five; `#` is a lit cell.
/// Lowercase letters sit on the same baseline, with a five-row x-height and
/// two extra rows below the baseline for descenders (g, j, p, q, y).
enum PixelFont {
	static let width = 5
	static let height = 7
	/// Rows below the baseline, used only by lowercase descenders.
	static let descent = 2

	static func glyph(for character: Character) -> [Bool]? {
		guard let rows = glyphs[character] ?? glyphs[Character(character.uppercased())] else {
			return nil
		}
		return rows.flatMap { $0.map { $0 == "#" } }
	}

	/// A glyph `height + descent` rows tall, keeping case. Uppercase and symbols get blank descender rows.
	static func glyphWithDescent(for character: Character) -> [Bool]? {
		let blank = String(repeating: ".", count: width)
		let rows: [String]
		if let lower = lowercase[character] {
			rows = lower + Array(repeating: blank, count: height + descent - lower.count)
		} else if let upper = glyphs[character] ?? glyphs[Character(character.uppercased())] {
			rows = upper + Array(repeating: blank, count: descent)
		} else {
			return nil
		}
		return rows.flatMap { $0.map { $0 == "#" } }
	}

	/// Seven rows on the baseline, plus two more for descenders.
	private static let lowercase: [Character: [String]] = [
		"a": [".....", ".....", ".###.", "....#", ".####", "#...#", ".####"],
		"b": ["#....", "#....", "####.", "#...#", "#...#", "#...#", "####."],
		"c": [".....", ".....", ".####", "#....", "#....", "#....", ".####"],
		"d": ["....#", "....#", ".####", "#...#", "#...#", "#...#", ".####"],
		"e": [".....", ".....", ".###.", "#...#", "#####", "#....", ".####"],
		"f": ["..##.", ".#...", "####.", ".#...", ".#...", ".#...", ".#..."],
		"g": [".....", ".....", ".####", "#...#", "#...#", "#...#", ".####", "....#", ".###."],
		"h": ["#....", "#....", "####.", "#...#", "#...#", "#...#", "#...#"],
		"i": ["..#..", ".....", ".##..", "..#..", "..#..", "..#..", ".###."],
		"j": ["...#.", ".....", "..##.", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
		"k": ["#....", "#....", "#..#.", "#.#..", "##...", "#.#..", "#..#."],
		"l": [".##..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
		"m": [".....", ".....", "##.#.", "#.#.#", "#.#.#", "#.#.#", "#.#.#"],
		"n": [".....", ".....", "####.", "#...#", "#...#", "#...#", "#...#"],
		"o": [".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."],
		"p": [".....", ".....", "####.", "#...#", "#...#", "#...#", "####.", "#....", "#...."],
		"q": [".....", ".....", ".####", "#...#", "#...#", "#...#", ".####", "....#", "....#"],
		"r": [".....", ".....", "#.##.", "##..#", "#....", "#....", "#...."],
		"s": [".....", ".....", ".####", "#....", ".###.", "....#", "####."],
		"t": [".#...", ".#...", "####.", ".#...", ".#...", ".#...", "..##."],
		"u": [".....", ".....", "#...#", "#...#", "#...#", "#...#", ".####"],
		"v": [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
		"w": [".....", ".....", "#...#", "#...#", "#.#.#", "#.#.#", ".#.#."],
		"x": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
		"y": [".....", ".....", "#...#", "#...#", "#...#", "#...#", ".####", "....#", ".###."],
		"z": [".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"],
	]

	private static let glyphs: [Character: [String]] = [
		"A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
		"B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
		"C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
		"D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
		"E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
		"F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
		"G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
		"H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
		"I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
		"J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
		"K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
		"L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
		"M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
		"N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
		"O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
		"P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
		"Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
		"R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
		"S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
		"T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
		"U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
		"V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
		"W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
		"X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
		"Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
		"Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
		"0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
		"1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
		"2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
		"3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
		"4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
		"5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
		"6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
		"7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
		"8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
		"9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
		" ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
		".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
		",": [".....", ".....", ".....", ".....", ".##..", "..#..", ".#..."],
		"-": [".....", ".....", ".....", ".###.", ".....", ".....", "....."],
		"_": [".....", ".....", ".....", ".....", ".....", ".....", "#####"],
		":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
		"/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
		"%": ["##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##"],
		"+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
		"=": [".....", ".....", "#####", ".....", "#####", ".....", "....."],
		"×": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
		"!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
		"?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
		"'": ["..#..", "..#..", ".#...", ".....", ".....", ".....", "....."],
		"(": ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
		")": [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
		"<": ["...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#."],
		">": [".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..."],
		"◂": [".....", "...#.", "..##.", ".###.", "..##.", "...#.", "....."],
		"▸": [".....", ".#...", ".##..", ".###.", ".##..", ".#...", "....."],
	]
}

/// Draws a grid of lit cells as small rounded squares, the same shape the dither uses.
struct PixelCells: View {
	let columns: Int
	let rows: Int
	let lit: [Bool]
	var cell: CGFloat = 3
	var gap: CGFloat = 0.12
	var color: Color = .white

	var body: some View {
		Canvas { context, _ in
			let inset = cell * gap
			let side = cell - inset * 2
			let radius = side * 0.22
			var path = Path()
			for index in lit.indices where lit[index] {
				let x = CGFloat(index % columns) * cell + inset
				let y = CGFloat(index / columns) * cell + inset
				path.addRoundedRect(in: CGRect(x: x, y: y, width: side, height: side), cornerSize: CGSize(width: radius, height: radius))
			}
			context.fill(path, with: .color(color))
		}
		.frame(width: CGFloat(columns) * cell, height: CGFloat(rows) * cell)
	}
}

/// Text set in `PixelFont`; one blank column between letters.
/// Uppercase by default. With `uppercased: false` it keeps case and grows by `PixelFont.descent` rows.
struct PixelText: View {
	let text: String
	var cell: CGFloat = 2.5
	var color: Color = .white
	var uppercased = true

	init(_ text: String, cell: CGFloat = 2.5, color: Color = .white, uppercased: Bool = true) {
		self.text = text
		self.cell = cell
		self.color = color
		self.uppercased = uppercased
	}

	var body: some View {
		let characters = Array(uppercased ? text.uppercased() : text)
		let rows = uppercased ? PixelFont.height : PixelFont.height + PixelFont.descent
		let columns = max(1, characters.count * (PixelFont.width + 1) - 1)
		var lit = [Bool](repeating: false, count: columns * rows)
		for (offset, character) in characters.enumerated() {
			guard let glyph = uppercased ? PixelFont.glyph(for: character) : PixelFont.glyphWithDescent(for: character) else {
				continue
			}
			for row in 0 ..< rows {
				for column in 0 ..< PixelFont.width where glyph[row * PixelFont.width + column] {
					lit[row * columns + offset * (PixelFont.width + 1) + column] = true
				}
			}
		}
		return PixelCells(columns: columns, rows: rows, lit: lit, cell: cell, color: color)
			.accessibilityElement()
			.accessibilityLabel(text.capitalized)
	}
}

#Preview {
	VStack(alignment: .leading, spacing: 12) {
		PixelText("BAYER", cell: 6)
		PixelText("ABCDEFGHIJKLM", cell: 3)
		PixelText("NOPQRSTUVWXYZ", cell: 3)
		PixelText("abcdefghijklm", cell: 3, uppercased: false)
		PixelText("nopqrstuvwxyz", cell: 3, uppercased: false)
		PixelText("Bayer: a live dithering camera", cell: 3, uppercased: false)
		PixelText("0123456789 .,-_:/%+=×!?'()<>◂▸", cell: 3)
	}
	.padding()
	.background(.black)
}
