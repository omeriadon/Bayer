import Foundation

/// Names shown in the pixel font, which only has capitals, digits and a few symbols.
nonisolated enum PixelName {
	static let maximumLength = 14

	static func clean(_ name: String, fallback: String) -> String {
		let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .-_:/%+=!?'()")
		let cleaned = String(name.uppercased().filter { allowed.contains($0) }.prefix(maximumLength))
			.trimmingCharacters(in: .whitespaces)
		return cleaned.isEmpty ? fallback : cleaned
	}
}
