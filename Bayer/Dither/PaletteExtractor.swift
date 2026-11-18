import simd

/// Finds a scene's main colours: k-means over a sparse sample of its pixels, darkest first.
/// No UI and no Metal, so the Mac checks can run it on a photo.
nonisolated enum PaletteExtractor {
	/// `pixels` is BGRA, 8 bits a channel. Roughly `samples` pixels are read, evenly spread.
	static func palette(
		bgra pixels: UnsafeRawBufferPointer,
		width: Int,
		height: Int,
		bytesPerRow: Int,
		count: Int = 4,
		samples: Int = 24000
	) -> [SIMD3<Float>] {
		guard width > 0, height > 0, count > 0, pixels.count >= bytesPerRow * (height - 1) + width * 4 else {
			return []
		}
		let step = max(1, Int((Double(width * height) / Double(max(samples, 1))).squareRoot()))
		var points: [SIMD3<Float>] = []
		points.reserveCapacity((width / step + 1) * (height / step + 1))
		var y = step / 2
		while y < height {
			var x = step / 2
			let row = y * bytesPerRow
			while x < width {
				let offset = row + x * 4
				unsafe points.append(SIMD3<Float>(
					Float(pixels[offset + 2]) / 255,
					Float(pixels[offset + 1]) / 255,
					Float(pixels[offset]) / 255
				))
				x += step
			}
			y += step
		}
		return palette(of: points, count: count)
	}

	/// k-means with seeds at even brightness steps, so the result is the same every time for the same picture.
	static func palette(of points: [SIMD3<Float>], count: Int, iterations: Int = 14) -> [SIMD3<Float>] {
		guard !points.isEmpty else {
			return []
		}
		let weights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
		let byBrightness = points.sorted { simd_dot($0, weights) < simd_dot($1, weights) }
		var centres = (0 ..< count).map { index in
			byBrightness[min(byBrightness.count - 1, (index * 2 + 1) * byBrightness.count / (count * 2))]
		}
		var assignment = [Int](repeating: 0, count: points.count)
		for _ in 0 ..< iterations {
			var sums = [SIMD3<Float>](repeating: .zero, count: count)
			var sizes = [Int](repeating: 0, count: count)
			for (index, point) in points.enumerated() {
				var best = 0
				var bestDistance = Float.greatestFiniteMagnitude
				for (centreIndex, centre) in centres.enumerated() {
					let distance = simd_distance_squared(point, centre)
					if distance < bestDistance {
						bestDistance = distance
						best = centreIndex
					}
				}
				assignment[index] = best
				sums[best] += point
				sizes[best] += 1
			}
			var moved = false
			for index in 0 ..< count where sizes[index] > 0 {
				let centre = sums[index] / Float(sizes[index])
				if simd_distance_squared(centre, centres[index]) > 1e-7 {
					moved = true
				}
				centres[index] = centre
			}
			if !moved {
				break
			}
		}
		// Empty clusters keep their seed; nudging duplicates apart keeps every colour distinct
		return centres.sorted { simd_dot($0, weights) < simd_dot($1, weights) }
	}
}
