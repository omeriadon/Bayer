import SwiftUI

struct CameraScreen: View {
	@Bindable var model: AppModel

	@State private var previewSize = CGSize.zero
	@State private var detent = Self.third
	/// The zoom when a pinch began
	@State private var pinchStart: Double?

	@Environment(\.displayScale) private var displayScale
	@Environment(\.scenePhase) private var scenePhase
	@Environment(\.openURL) private var openURL
	#if os(iOS)
		@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	#endif

	/// On iPhone the debug sheet stops at a third or a half, with the controls just above it.
	static let third = PresentationDetent.fraction(1 / 3)
	static let half = PresentationDetent.fraction(1 / 2)

	/// iPad and Mac have room for debug as a side inspector instead of a sheet
	private var usesInspector: Bool {
		#if os(iOS)
			horizontalSizeClass == .regular
		#else
			true
		#endif
	}

	var body: some View {
		let theme = PixelTheme(palette: model.configuration.palette)
		GeometryReader { proxy in
			let landscape = proxy.size.width > proxy.size.height
			let column = landscape || usesInspector
			let fullHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
			let fraction: CGFloat = detent == Self.half ? 1 / 2 : 1 / 3
			let lift = model.debugOpen && !column ? fullHeight * fraction - proxy.safeAreaInsets.bottom + 8 : 0
			ZStack {
				theme.paper.ignoresSafeArea()

				DitherCameraView(
					configuration: model.configuration,
					camera: model.camera,
					frames: model.controller.frames,
					clock: model.waveClock
				)
				.ignoresSafeArea()
				.onGeometryChange(for: CGSize.self) { $0.size } action: { previewSize = $0 }

				// Pinch anywhere on the picture to zoom
				Color.clear
					.contentShape(Rectangle())
					.ignoresSafeArea()
					.gesture(pinch, isEnabled: model.camera.usesCamera && model.zoomRange.maximum > model.zoomRange.minimum)

				if model.status == .denied, model.camera.usesCamera {
					deniedView
				}

				if let toast = model.toast {
					PixelText(toast, cell: 3.5, color: theme.ink)
						.pixelPanel(padding: 12)
						.transition(.pixelDissolve)
				}

				if column {
					HStack(spacing: 0) {
						Spacer(minLength: 0)
						VStack(spacing: 8) {
							topBar
							Spacer(minLength: 0)
							controls(spacing: 8)
						}
						.frame(width: 350)
					}
					.padding(.horizontal, 10)
					.padding(.vertical, 4)
				} else {
					VStack(spacing: 0) {
						topBar
						Spacer()
						controls(spacing: 10)
							.padding(.bottom, lift)
					}
					.padding(.horizontal, 14)
				}
			}
			.animation(.snappy, value: model.debugOpen)
			.animation(.snappy, value: detent)
			.animation(.easeInOut(duration: 0.3), value: model.toast)
			.onChange(of: landscape, initial: true) { _, landscape in
				model.controller.setInterfaceIsPortrait(!landscape)
			}
		}
		.environment(\.pixelTheme, theme)
		.preferredColorScheme(.dark)
		.hidesSystemChrome()
		.modifier(DebugPresentation(model: model, detent: $detent, asInspector: usesInspector, theme: theme))
		.fullScreen(isPresented: $model.viewingPhoto) {
			if let photo = model.lastPhoto {
				PhotoViewer(image: photo)
					.environment(\.pixelTheme, theme)
			}
		}
		.task {
			model.announce()
			await model.startCamera()
		}
		.onChange(of: scenePhase) { _, phase in
			if phase == .active {
				Task { await model.startCamera() }
			} else if phase == .background {
				model.stopCamera()
			}
		}
		.sensoryFeedback(trigger: model.photoNote) { _, note in
			switch note {
				case .saved: .success
				case .failed: .error
				case nil: nil
			}
		}
	}

	private var pinch: some Gesture {
		MagnifyGesture()
			.onChanged { value in
				let start = pinchStart ?? model.camera.zoom
				pinchStart = start
				model.setZoom(start * value.magnification, ramp: false)
			}
			.onEnded { _ in
				pinchStart = nil
			}
	}

	// MARK: Top

	private var topBar: some View {
		HStack(spacing: 10) {
			Spacer()
			PixelIconButton(
				icon: .camera,
				lit: model.camera.usesCamera,
				label: model.camera.usesCamera ? "Turn camera off" : "Turn camera on"
			) {
				model.camera.usesCamera.toggle()
			}
			PixelIconButton(icon: .bug, lit: model.debugOpen, label: model.debugOpen ? "Hide debug" : "Show debug") {
				model.debugOpen.toggle()
			}
		}
		.padding(.top, 6)
	}

	// MARK: Bottom

	private func controls(spacing: CGFloat) -> some View {
		VStack(spacing: spacing) {
			if model.camera.usesCamera, model.zoomRange.presets.count > 1 || model.zoomRange.maximum > model.zoomRange.minimum {
				ZoomChips(range: model.zoomRange, zoom: model.camera.zoom) {
					model.setZoom($0, ramp: true)
				}
			}
			PixelTrack(
				title: "STYLE",
				value: DitherMode(shaderMode: model.configuration.ditherMode).title,
				count: DitherMode.allCases.count,
				index: $model.patternIndex,
				fills: false
			)
			PixelTrack(
				title: "SIZE",
				value: sizeTitle,
				count: CameraSettings.texelSteps.count,
				index: $model.sizeIndex
			)
			PixelTrack(
				title: "DITHER",
				value: "\(Int((model.configuration.ditherStrength * 100).rounded()))%",
				count: AppModel.strengthSteps + 1,
				index: $model.strengthIndex
			)
			PaletteStrip(selected: model.palette) { model.select($0) }
			HStack {
				thumbnail
				Spacer()
				PixelShutter(capturing: model.isCapturing) {
					model.capture(viewSize: previewSize, scale: displayScale)
				}
				Spacer()
				PixelIconButton(icon: .flip, label: "Switch camera") {
					model.flipCamera()
				}
				.opacity(model.camera.usesCamera ? 1 : 0.35)
				.disabled(!model.camera.usesCamera)
				.frame(width: 64)
			}
		}
	}

	private var sizeTitle: String {
		let step = CameraSettings.texelSteps[model.sizeIndex]
		return model.camera.usesCamera ? "1:\(step * step)" : "\(step) PT"
	}

	private var thumbnail: some View {
		Button {
			if model.lastPhoto != nil {
				model.viewingPhoto = true
			}
		} label: {
			Thumbnail(photo: model.lastPhoto, photoID: model.captureCount, note: model.photoNote)
		}
		.buttonStyle(PixelButtonStyle())
		.frame(width: 64)
		.disabled(model.lastPhoto == nil)
		.accessibilityLabel("Last photo")
		.accessibilityValue(model.photoNote?.title.capitalized ?? "")
	}

	// MARK: Denied

	private var deniedView: some View {
		let theme = PixelTheme(palette: model.configuration.palette)
		return VStack(spacing: 16) {
			PixelIconView(icon: .camera, cell: 6, color: theme.ink)
			PixelText("CAMERA IS OFF", cell: 3.5, color: theme.ink)
			PixelText("ALLOW IT IN SETTINGS", cell: 2, color: theme.mid)
			Button {
				if let url = Platform.cameraSettingsURL {
					openURL(url)
				}
			} label: {
				PixelText("OPEN SETTINGS", cell: 2.5, color: theme.paper)
					.pixelPanel(lit: true, padding: 10)
			}
			.buttonStyle(PixelButtonStyle())
		}
	}
}

/// The last photo. A new one dissolves in, the frame lights up, and a tag above says what happened.
private struct Thumbnail: View {
	let photo: CGImage?
	/// Changes with each new photo
	let photoID: Int
	let note: PhotoNote?

	@State private var reveal = 1.0
	@Environment(\.pixelTheme) private var theme

	var body: some View {
		Group {
			if let photo {
				Image(decorative: photo, scale: 1)
					.resizable()
					.interpolation(.none)
					.scaledToFill()
					.modifier(PixelDissolve(amount: reveal, cell: 3))
			} else {
				PixelIconView(icon: .photo, cell: 3, color: theme.mid)
			}
		}
		.frame(width: 44, height: 44)
		.clipShape(PixelFrame(step: 2))
		.pixelPanel(lit: note != nil, padding: 4)
		.overlay(alignment: .top) {
			if let note {
				HStack(spacing: 5) {
					if note == .saved {
						PixelIconView(icon: .check, cell: 1.6, color: theme.paper)
					}
					PixelText(note.title, cell: 1.6, color: theme.paper)
				}
				.fixedSize()
				.pixelPanel(lit: true, padding: 6)
				.offset(y: -38)
				.transition(.pixelDissolve)
			}
		}
		.animation(.easeOut(duration: 0.25), value: note)
		.onChange(of: photoID) {
			reveal = 0
			withAnimation(.linear(duration: 0.4)) {
				reveal = 1
			}
		}
	}
}

private struct PaletteStrip: View {
	let selected: DitherPalette?
	let select: (DitherPalette) -> Void

	/// How wide each edge fade is: it grows with the content past that edge, up to `maximumFade`
	@State private var fades = Fades()
	private static let maximumFade: CGFloat = 34

	private struct Fades: Equatable {
		var width: CGFloat = 0
		var leading: CGFloat = 0
		var trailing: CGFloat = 0
	}

	var body: some View {
		ScrollView(.horizontal) {
			HStack(spacing: 8) {
				ForEach(DitherPalette.all) { palette in
					Button {
						select(palette)
					} label: {
						PaletteChip(palette: palette, selected: palette == selected)
					}
					.buttonStyle(PixelButtonStyle())
					// Each chip thins out in cells, per pixel, as it slides into an edge
					.visualEffect { [fades] content, proxy in
						content.colorEffect(ShaderLibrary.pixelEdgeFade(
							.float(proxy.frame(in: .scrollView(axis: .horizontal)).minX),
							.float(fades.width),
							.float(fades.leading),
							.float(fades.trailing),
							.float(2.5)
						))
					}
					.accessibilityLabel(palette.name.capitalized)
					.accessibilityAddTraits(palette == selected ? .isSelected : [])
				}
			}
			.padding(.horizontal, 2)
			.padding(.vertical, 3)
		}
		.scrollIndicators(.hidden)
		.scrollEdgeEffectHidden()
		.onScrollGeometryChange(for: Fades.self) { geometry in
			let past = geometry.contentSize.width - geometry.contentOffset.x - geometry.containerSize.width
			return Fades(
				width: geometry.containerSize.width,
				leading: min(Self.maximumFade, max(0, geometry.contentOffset.x)),
				trailing: min(Self.maximumFade, max(0, past))
			)
		} action: { _, new in
			fades = new
		}
	}
}

private struct PaletteChip: View {
	let palette: DitherPalette
	let selected: Bool

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		let own = PixelTheme(palette: palette.colors)
		VStack(spacing: 5) {
			HStack(spacing: 2) {
				ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, color in
					Rectangle()
						.fill(Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
						.frame(width: 9, height: 9)
				}
			}
			PixelText(palette.name, cell: 1.6, color: selected ? theme.paper : own.ink)
		}
		.pixelPanel(lit: selected, padding: 7)
	}
}

/// The last photo, full screen and unsmoothed, with share and a way to Photos.
private struct PhotoViewer: View {
	let image: CGImage

	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL
	@Environment(\.pixelTheme) private var theme

	var body: some View {
		ZStack {
			theme.paper.ignoresSafeArea()
			Image(decorative: image, scale: 1)
				.resizable()
				.interpolation(.none)
				.scaledToFit()
				.ignoresSafeArea()
				.accessibilityLabel("Your last photo")
			VStack {
				HStack {
					Spacer()
					PixelIconButton(icon: .close, label: "Close") {
						dismiss()
					}
				}
				Spacer()
				HStack(spacing: 10) {
					ShareLink(
						item: Image(decorative: image, scale: 1),
						preview: SharePreview("Bayer photo", image: Image(decorative: image, scale: 1))
					) {
						PixelText("SHARE", cell: 2.5, color: theme.paper)
							.frame(maxWidth: .infinity)
							.pixelPanel(lit: true, padding: 12)
					}
					Button {
						if let url = Platform.photosURL {
							openURL(url)
						}
					} label: {
						PixelText("PHOTOS", cell: 2.5, color: theme.ink)
							.frame(maxWidth: .infinity)
							.pixelPanel(padding: 12)
					}
				}
				.buttonStyle(PixelButtonStyle())
				.frame(maxWidth: 420)
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 6)
		}
		.hidesSystemChrome()
	}
}

/// Debug as a sheet on iPhone, sitting at a third or a half, and as a side inspector on iPad and Mac.
private struct DebugPresentation: ViewModifier {
	@Bindable var model: AppModel
	@Binding var detent: PresentationDetent
	let asInspector: Bool
	let theme: PixelTheme

	func body(content: Content) -> some View {
		if asInspector {
			content.inspector(isPresented: $model.debugOpen) {
				DebugPanel(model: model)
					.environment(\.pixelTheme, theme)
					.inspectorColumnWidth(min: 300, ideal: 340, max: 440)
			}
		} else {
			content.sheet(isPresented: $model.debugOpen) {
				DebugPanel(model: model)
					.environment(\.pixelTheme, theme)
					.presentationDetents([CameraScreen.third, CameraScreen.half], selection: $detent)
					.presentationBackgroundInteraction(.enabled)
					.presentationDragIndicator(.visible)
					.presentationContentInteraction(.scrolls)
			}
		}
	}
}

/// The lenses' zooms as chips. The nearest one lights and shows the exact zoom while you pinch.
private struct ZoomChips: View {
	let range: ZoomRange
	let zoom: Double
	let select: (Double) -> Void

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		let nearest = range.presets.min { abs($0 - zoom) < abs($1 - zoom) } ?? 1
		HStack(spacing: 6) {
			ForEach(range.presets, id: \.self) { preset in
				let current = preset == nearest
				Button {
					select(preset)
				} label: {
					PixelText(Self.title(current ? zoom : preset), cell: 1.8, color: current ? theme.paper : theme.ink)
						.frame(minWidth: 34)
						.pixelPanel(lit: current, padding: 7)
				}
				.buttonStyle(PixelButtonStyle())
				.accessibilityLabel("Zoom \(Self.title(preset).replacingOccurrences(of: "×", with: " times"))")
				.accessibilityAddTraits(current ? .isSelected : [])
			}
		}
		.sensoryFeedback(.pixelStep, trigger: nearest)
	}

	/// 1×, 0.5×, 2.4×
	static func title(_ zoom: Double) -> String {
		let rounded = (zoom * 10).rounded() / 10
		return rounded == rounded.rounded() ? "\(Int(rounded))×" : "\(rounded)×"
	}
}
