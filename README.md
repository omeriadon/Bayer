# Bayer

A live dithering camera for iPhone, iPad and Mac.

Every frame from the camera is ordered-dithered in Metal into a palette of your choice. Each dither cell is the exact average of an N×N block of camera pixels, so the picture stays clean at every size. Turn the camera off and it dithers a generated wave field instead, for quick wallpapers.

- Palettes: Pocket, 1-Bit, CGA, Newsprint, Amber, Blueprint, Thermal, Sunset, or your own
- Patterns: Bayer, dots, lines, crosshatch, noise and flat
- Mappings: Exact palette colours, Blend, or the camera's own colours
- Photos save as PNG, exactly as the preview looks
- A pixel UI drawn from the same cells as the dither, with a hand-made 5×7 font

Open `Bayer.xcodeproj` in Xcode 27 and run. Runs on iOS 26 and macOS 26 or later.

`Checks/run-camera-checks.sh <photo> <output folder>` renders a still photo through the shader on the Mac.
