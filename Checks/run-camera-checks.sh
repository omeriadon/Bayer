#!/bin/sh
# Renders a photo through Bayer's camera kernel on the Mac. Doesn't touch the app.
# Usage: Checks/run-camera-checks.sh <photo> <output directory>
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d /tmp/bayer-checks.XXXXXX)"
xcrun -sdk macosx metal -c "$root/Bayer/Dither/OptimizedDither.metal" -o "$build/shader.air"
xcrun -sdk macosx metallib "$build/shader.air" -o "$build/default.metallib"
xcrun swiftc -O -parse-as-library \
	"$root/Bayer/Dither/DitherRenderer.swift" \
	"$root/Bayer/Dither/CameraInput.swift" \
	"$root/Bayer/Dither/Palettes.swift" \
	"$root/Checks/CameraRenderingChecks.swift" \
	-o "$build/check"
"$build/check" "$build/default.metallib" "$1" "$2"
