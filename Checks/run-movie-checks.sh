#!/bin/sh
# Runs the video importer and Live Photo maker on the Mac. Writes files only; never touches Photos.
# Usage: Checks/run-movie-checks.sh <photo> <output directory>
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d /tmp/bayer-movies.XXXXXX)"
xcrun -sdk macosx metal -c "$root/Bayer/Dither/OptimizedDither.metal" -o "$build/shader.air"
xcrun -sdk macosx metallib "$build/shader.air" -o "$build/default.metallib"
xcrun swiftc -O -parse-as-library -default-isolation MainActor \
	"$root/Bayer/Dither/DitherRenderer.swift" \
	"$root/Bayer/Dither/CameraInput.swift" \
	"$root/Bayer/Dither/Palettes.swift" \
	"$root/Bayer/Camera/CameraController.swift" \
	"$root/Bayer/Camera/PhotoExporter.swift" \
	"$root/Bayer/Camera/PhotoLibrary.swift" \
	"$root/Bayer/Camera/EditData.swift" \
	"$root/Bayer/Camera/VideoDither.swift" \
	"$root/Bayer/Library/FramePixels.swift" \
	"$root/Bayer/Library/ProSettings.swift" \
	"$root/Bayer/Library/Look.swift" \
	"$root/Checks/Movies/MovieChecks.swift" \
	-o "$build/movies"
"$build/movies" "$build/default.metallib" "$1" "$2"
