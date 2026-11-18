import CoreGraphics
import Defaults
import Metal
import Observation
import SwiftUI
import UniformTypeIdentifiers

nonisolated extension DitherConfiguration: Defaults.Serializable {}
nonisolated extension CameraSettings: Defaults.Serializable {}
nonisolated extension DitherPalette: Defaults.Serializable {}
nonisolated extension Look: Defaults.Serializable {}
nonisolated extension ProSettings: Defaults.Serializable {}

nonisolated extension Defaults.Keys {
	static let configuration = Key<DitherConfiguration>("configuration", default: .bayerDefault)
	static let camera = Key<CameraSettings>("camera", default: CameraSettings())
	/// The TUNE section bar, left open or closed
	static let settingsOpen = Key<Bool>("settingsOpen", default: false)
	/// The welcome has been seen; the camera is only asked for after it
	static let hasOnboarded = Key<Bool>("hasOnboarded", default: false)
	/// Palettes you've made, after the built-in ones
	static let customPalettes = Key<[DitherPalette]>("customPalettes", default: [])
	/// Built-in palettes switched off in the strip, by id
	static let hiddenPalettes = Key<Set<String>>("hiddenPalettes", default: [])
	static let looks = Key<[Look]>("looks", default: [])
	static let pro = Key<ProSettings>("pro", default: ProSettings())
}

/// The sheets over the camera screen
enum LibrarySheet: String, Identifiable {
	case palettes, looks, settings

	var id: Self { self }
}

@Observable
final class AppModel {
	/// One model for the app and its Shortcuts actions
	static let shared = AppModel()

	enum CameraStatus {
		case unknown, running, denied
	}

	var configuration = Defaults[.configuration] {
		didSet {
			Defaults[.configuration] = configuration
			syncCameraControl()
		}
	}

	var camera = AppModel.savedCamera() {
		didSet {
			Defaults[.camera] = camera
			syncCameraControl()
			if camera.depthRange != oldValue.depthRange {
				controller.setDepthRange(camera.depthRange)
			}
			if camera.source != oldValue.source {
				// WAVE and DEPTH pages belong to their own sources
				if let section, !SettingsSection.available(source: camera.source).contains(section) {
					self.section = nil
				}
				if editing != nil {
					// A still is showing; the camera stays off until editing ends
				} else if camera.usesCamera {
					// Camera to LiDAR or back swaps the session's input; from the wave it starts it
					Task { await startCamera() }
				} else {
					// Fully disconnected: the session stops and its last frame goes
					stopCamera()
					controller.frames.clear()
				}
			} else if camera.usesFrontCamera != oldValue.usesFrontCamera, camera.source == .camera, status == .running, editing == nil {
				controller.start(front: camera.usesFrontCamera, depth: false, zoom: camera.zoom)
			}
		}
	}

	var zoomRange = ZoomRange()
	/// The section bar is showing. Remembered between launches.
	var settingsOpen = Defaults[.settingsOpen] {
		didSet {
			Defaults[.settingsOpen] = settingsOpen
			if !settingsOpen {
				section = nil
			}
		}
	}

	/// Full screen: every control hidden, just the picture. A tap anywhere brings them back.
	var controlsHidden = false
	var sheet: LibrarySheet?

	// MARK: Library

	var customPalettes = Defaults[.customPalettes] {
		didSet {
			Defaults[.customPalettes] = customPalettes
			paletteListChanged()
		}
	}

	var hiddenPalettes = Defaults[.hiddenPalettes] {
		didSet {
			Defaults[.hiddenPalettes] = hiddenPalettes
			paletteListChanged()
		}
	}

	var looks = Defaults[.looks] {
		didSet { Defaults[.looks] = looks }
	}

	var pro = Defaults[.pro] {
		didSet {
			Defaults[.pro] = pro
			ChipSounds.shared.isEnabled = pro.sounds
		}
	}

	/// The open section, which takes the main controls' place
	var section: SettingsSection?
	var viewingPhoto = false
	var status = CameraStatus.unknown
	var lastPhoto: CGImage?
	var toast: String?
	/// What happened to the last photo, shown by its thumbnail
	var photoNote: PhotoNote?
	var captureCount = 0
	var isCapturing = false
	/// Camera Control's overlay is covering the screen, so the app's controls step aside
	var cameraControlOverlay = false
	/// False until the welcome is done. Until then the picture is the wave and the camera isn't asked for.
	var hasOnboarded = Defaults[.hasOnboarded] {
		didSet {
			Defaults[.hasOnboarded] = hasOnboarded
			// Back to the welcome: the camera rests until it's finished again
			if !hasOnboarded, oldValue {
				stopCamera()
			}
		}
	}

	let controller = CameraController(
		device: MTLCreateSystemDefaultDevice(),
		styleTitles: DitherMode.allCases.map(\.title.capitalized)
	)
	let waveClock = WaveClock()

	/// Settings restored onto a device without a scanner fall back to the camera
	private static func savedCamera() -> CameraSettings {
		var camera = Defaults[.camera]
		if !sources.contains(camera.source) {
			camera.source = .camera
		}
		return camera
	}

	/// The top-left button's stops, in order. LiDAR only where there's a scanner.
	static let sources: [CameraSettings.Source] = CameraSettings.Source.allCases.filter {
		$0 != .depth || CameraController.supportsLiDAR
	}

	init() {
		ChipSounds.shared.isEnabled = pro.sounds
		controller.setDepthRange(camera.depthRange)
		let ranges = controller.zoomRanges
		Task { [weak self] in
			for await range in ranges {
				self?.zoomRange = range
			}
		}
		let events = controller.controlEvents
		Task { [weak self] in
			for await event in events {
				self?.apply(event)
			}
		}
		syncCameraControl()
		paletteListChanged()
	}

	// MARK: Palettes and looks

	var allPalettes: [DitherPalette] {
		DitherPalette.all + customPalettes
	}

	/// The palettes in the strip and on Camera Control: built-ins you haven't hidden, then yours. Never empty.
	var shownPalettes: [DitherPalette] {
		let shown = allPalettes.filter { !hiddenPalettes.contains($0.id) }
		return shown.isEmpty ? [DitherPalette.all[0]] : shown
	}

	func setHidden(_ palette: DitherPalette, _ hidden: Bool) {
		if hidden {
			// The strip always keeps at least one
			guard shownPalettes.count > 1 || !shownPalettes.contains(palette) else {
				return
			}
			hiddenPalettes.insert(palette.id)
		} else {
			hiddenPalettes.remove(palette.id)
		}
	}

	/// Saves the current INK colours as one of yours, and returns it
	@discardableResult
	func saveCurrentInk() -> DitherPalette {
		let palette = DitherPalette.custom(named: nextName("INK", among: customPalettes.map(\.name)), colors: configuration.palette)
		customPalettes.append(palette)
		select(palette)
		return palette
	}

	func rename(_ palette: DitherPalette, to name: String) {
		guard let index = customPalettes.firstIndex(where: { $0.id == palette.id }) else {
			return
		}
		customPalettes[index].name = PixelName.clean(name, fallback: palette.name)
	}

	func delete(_ palette: DitherPalette) {
		customPalettes.removeAll { $0.id == palette.id }
	}

	/// The scene's main colours as a new palette, as many as the current one has. Nil without a frame to read.
	@discardableResult
	func paletteFromScene() -> DitherPalette? {
		guard let frame = controller.frames.current else {
			return nil
		}
		let count = min(max(configuration.palette.count, 2), DitherConfiguration.supportedPaletteCount)
		let colors = unsafe FramePixels.withBGRA(frame.texture) { pixels, width, height, bytesPerRow in
			unsafe PaletteExtractor.palette(bgra: pixels, width: width, height: height, bytesPerRow: bytesPerRow, count: count)
		}
		guard let colors, colors.count >= 2 else {
			return nil
		}
		let palette = DitherPalette.custom(named: nextName("SCENE", among: customPalettes.map(\.name)), colors: colors)
		customPalettes.append(palette)
		select(palette)
		return palette
	}

	func saveLook() {
		looks.append(Look(name: nextName("LOOK", among: looks.map(\.name)), configuration: configuration, camera: camera))
	}

	func apply(_ look: Look) {
		var camera = camera
		look.apply(to: &camera)
		configuration = look.configuration
		self.camera = camera
	}

	func rename(_ look: Look, to name: String) {
		guard let index = looks.firstIndex(where: { $0.id == look.id }) else {
			return
		}
		looks[index].name = PixelName.clean(name, fallback: look.name)
	}

	func delete(_ look: Look) {
		looks.removeAll { $0.id == look.id }
	}

	/// "INK 3": the first number not already taken
	private func nextName(_ stem: String, among names: [String]) -> String {
		var number = 1
		while names.contains("\(stem) \(number)") {
			number += 1
		}
		return "\(stem) \(number)"
	}

	/// Camera Control's palette picker lists the shown palettes, so it's rebuilt when they change
	private func paletteListChanged() {
		controller.setPaletteNames(shownPalettes.map(\.name))
		syncCameraControl()
	}

	// MARK: Camera Control

	/// Applies what was done on Camera Control. Zoom only updates the number shown: the system
	/// slider has already moved the lens.
	private func apply(_ event: CameraControlEvent) {
		switch event {
			case let .zoom(zoom): camera.zoom = zoom
			case let .texels(texels): camera.cellTexels = texels
			case let .dither(dither): configuration.ditherStrength = dither
			case let .style(index): patternIndex = index
			case let .palette(index):
				let shown = shownPalettes
				if shown.indices.contains(index) {
					select(shown[index])
				}
			case let .overlay(covering): cameraControlOverlay = covering
		}
	}

	/// Keeps Camera Control's sliders where the app's are
	private func syncCameraControl() {
		controller.syncControls(CameraControlValues(
			texels: camera.cellTexels,
			dither: configuration.ditherStrength,
			style: patternIndex,
			palette: palette.flatMap { current in shownPalettes.firstIndex(of: current) }
		))
	}

	// MARK: Camera

	func startCamera() async {
		guard camera.usesCamera, hasOnboarded, editing == nil else {
			return
		}
		if await CameraController.requestAccess() {
			status = .running
			controller.start(front: camera.usesFrontCamera, depth: camera.source == .depth, zoom: camera.zoom)
		} else {
			status = .denied
		}
	}

	func stopCamera() {
		controller.stop()
	}

	/// Camera, then the dither wave, then LiDAR where there is one, then round again
	func nextSource() {
		let sources = Self.sources
		let index = sources.firstIndex(of: camera.source) ?? 0
		camera.source = sources[(index + 1) % sources.count]
	}

	func flipCamera() {
		guard camera.source == .camera else {
			return
		}
		// Each camera starts at its own 1×
		camera.zoom = 1
		camera.usesFrontCamera.toggle()
	}

	/// Sets the zoom, kept inside what this camera can do. A ramp for taps, exact for pinches.
	func setZoom(_ zoom: Double, ramp: Bool) {
		let clamped = min(max(zoom, zoomRange.minimum), zoomRange.maximum)
		camera.zoom = clamped
		controller.setZoom(clamped, ramp: ramp)
	}

	// MARK: Quick controls

	var palette: DitherPalette? {
		DitherPalette.matching(configuration, in: allPalettes)
	}

	func select(_ palette: DitherPalette) {
		palette.apply(to: &configuration)
	}

	// MARK: Tracks

	var patternIndex: Int {
		get { DitherMode.allCases.firstIndex(of: DitherMode(shaderMode: configuration.ditherMode)) ?? 0 }
		set { configuration.ditherMode = DitherMode.allCases[min(max(newValue, 0), DitherMode.allCases.count - 1)].rawValue }
	}

	/// The same snap points for camera pixels per cell and, with the camera off, points per cell
	var sizeIndex: Int {
		get {
			let current = camera.usesCamera ? camera.cellTexels : Int(configuration.pixelSize.rounded())
			let steps = sizeSteps
			return steps.indices.min { abs(steps[$0] - current) < abs(steps[$1] - current) } ?? 0
		}
		set {
			let steps = sizeSteps
			let value = steps[min(max(newValue, 0), steps.count - 1)]
			if camera.usesCamera {
				camera.cellTexels = value
			} else {
				configuration.pixelSize = Float(value)
			}
		}
	}

	/// LiDAR has its own shorter list; the camera and the wave share the full one
	var sizeSteps: [Int] {
		CameraSettings.texelSteps(for: camera.source)
	}

	static let strengthSteps = 20

	var strengthIndex: Int {
		get { Int((configuration.ditherStrength * Float(Self.strengthSteps)).rounded()) }
		set { configuration.ditherStrength = Float(min(max(newValue, 0), Self.strengthSteps)) / Float(Self.strengthSteps) }
	}

	func reset() {
		configuration = .bayerDefault
		camera = CameraSettings()
	}

	/// The name shows once at launch, then gets out of the way. The welcome says it instead the first time.
	func announce() {
		if hasOnboarded {
			show("BAYER")
		}
	}

	/// Ends the welcome and asks for the camera, now that it's been explained
	func finishOnboarding() async {
		hasOnboarded = true
		await startCamera()
	}

	// MARK: Capture

	/// `live` makes a Live Photo of the wave, for wallpapers; it's what holding the shutter does with DITHER.
	func capture(viewSize: CGSize, scale: CGFloat, live: Bool = false) {
		guard !isCapturing else {
			return
		}
		if editing != nil {
			saveEditing()
			return
		}
		let frame = controller.frames.current
		if camera.usesCamera, frame == nil {
			note(.failed("NO CAMERA"))
			return
		}
		isCapturing = true
		captureCount += 1
		ChipSounds.shared.play(.shutter)
		let pixels = CGSize(width: (viewSize.width * scale).rounded(), height: (viewSize.height * scale).rounded())
		if camera.source == .wave, live {
			captureLiveWave(pixels: pixels, scale: scale)
			return
		}
		do {
			let image = try PhotoExporter.render(
				frame: frame,
				configuration: configuration,
				camera: camera,
				waveTime: waveClock.time,
				pixelSize: pixels,
				scale: scale,
				crisp: pro.exportSize == .crisp
			)
			lastPhoto = image
			// The real photo goes underneath, with the recipe, so the dither can be changed later
			// Always, for camera and LiDAR photos: the wave is simply shot again
			let keeps = camera.usesCamera
			let edit = EditData(
				original: camera.source == .depth ? .depth : .camera,
				configuration: configuration,
				camera: camera,
				outputWidth: Int(pixels.width),
				outputHeight: Int(pixels.height),
				exportSize: pro.exportSize
			)
			// Copied now, before the camera reuses the frame's buffer; encoded off the main actor
			let originalImage = keeps ? frame.flatMap { PhotoExporter.image(of: $0.texture) } : nil
			Task {
				do {
					let original = await Self.encodeOriginal(originalImage)
					lastAssetID = try await PhotoLibrary.save(image, original: original, edit: keeps ? edit : nil)
					note(.saved)
				} catch {
					note(.failed(error is PhotoLibrary.Failure ? "NO ACCESS" : "NOT SAVED"))
				}
				isCapturing = false
			}
		} catch {
			isCapturing = false
			note(.failed("FAILED"))
		}
	}

	/// Three seconds of the wave as a Live Photo, centred on now
	private func captureLiveWave(pixels: CGSize, scale: CGFloat) {
		let configuration = configuration
		let camera = camera
		let time = waveClock.time
		show("LIVE...")
		Task {
			do {
				let live = try await MovieMaker.liveWave(
					configuration: configuration,
					camera: camera,
					startTime: time,
					pixelSize: pixels,
					scale: scale
				)
				try await MovieMaker.save(live)
				lastPhoto = live.still
				lastAssetID = nil
				note(.saved)
			} catch {
				note(.failed((error as? PhotoLibrary.Failure) == .notAllowed ? "NO ACCESS" : "NOT SAVED"))
			}
			isCapturing = false
		}
	}

	@concurrent
	private nonisolated static func encodeOriginal(_ image: CGImage?) async -> PhotoLibrary.Original? {
		image.flatMap { PhotoExporter.heicData($0, quality: 0.95) }.map { PhotoLibrary.Original(data: $0, type: .heic) }
	}

	/// The preview's size in pixels, kept up to date by the screen, so Shortcuts can take a photo at the right size
	var previewPixels = CGSize.zero
	var displayScale: CGFloat = 1

	/// For Shortcuts: waits for the camera's first frame, up to five seconds, then takes the photo
	func captureWhenReady() async {
		await startCamera()
		for _ in 0 ..< 50 {
			if !camera.usesCamera || controller.frames.current != nil, previewPixels.width > 0 {
				break
			}
			try? await Task.sleep(for: .milliseconds(100))
		}
		guard previewPixels.width > 0 else {
			show("OPEN BAYER FIRST")
			return
		}
		capture(viewSize: CGSize(width: previewPixels.width / displayScale, height: previewPixels.height / displayScale), scale: displayScale)
	}

	// MARK: Editing

	/// A picture being dithered instead of the camera: one of Bayer's photos again, or an import.
	struct EditSession {
		let opened: PhotoLibrary.Opened
		let original: EditData.Original
		/// The render's size before PRO's photo size, which is also the preview's shape
		let width: Int
		let height: Int
		/// What to go back to afterwards
		let previousConfiguration: DitherConfiguration
		let previousCamera: CameraSettings
	}

	var editing: EditSession?
	/// A video being dithered, 0 to 1
	var videoProgress: Double?
	var videoTask: Task<Void, Never>?
	/// The picture being edited, as a frame. The camera's own frames are left alone.
	let stillFrames = LatestCameraFrame()
	/// The last photo saved, in the library, so it can be opened again
	var lastAssetID: String?
	var isOpening = false

	var isEditing: Bool {
		editing != nil
	}

	/// The camera's lens controls: zoom, pinch and flip. Not for LiDAR, the wave or a still.
	var usesLens: Bool {
		camera.source == .camera && editing == nil
	}

	func editLastPhoto() {
		guard let lastAssetID else {
			return
		}
		viewingPhoto = false
		open { try await PhotoLibrary.open(assetID: lastAssetID) }
	}

	func open(_ load: @escaping () async throws -> PhotoLibrary.Opened) {
		guard !isOpening else {
			return
		}
		isOpening = true
		Task {
			do {
				beginEditing(try await load())
			} catch {
				show((error as? PhotoLibrary.Failure) == .notAllowed ? "NO ACCESS" : "CAN'T OPEN")
			}
			isOpening = false
		}
	}

	private func beginEditing(_ opened: PhotoLibrary.Opened) {
		guard let device = MTLCreateSystemDefaultDevice(), let frame = StillFrame.frame(from: opened.image, device: device) else {
			show("CAN'T OPEN")
			return
		}
		let previousConfiguration = editing?.previousConfiguration ?? configuration
		let previousCamera = editing?.previousCamera ?? camera
		stopCamera()
		stillFrames.publish(frame)
		let original = opened.edit?.original ?? .imported
		let width = (opened.edit?.outputWidth ?? 0) > 0 ? opened.edit!.outputWidth : opened.image.width
		let height = (opened.edit?.outputHeight ?? 0) > 0 ? opened.edit!.outputHeight : opened.image.height
		// Set first, so the camera stays off while the settings change below
		editing = EditSession(
			opened: opened,
			original: original,
			width: width,
			height: height,
			previousConfiguration: previousConfiguration,
			previousCamera: previousCamera
		)
		var camera = opened.edit?.camera ?? self.camera
		camera.source = original == .depth ? .depth : .camera
		if let edit = opened.edit {
			configuration = edit.configuration
			pro.exportSize = edit.exportSize
		}
		self.camera = camera
		section = nil
		show(opened.edit == nil ? "NEW PHOTO" : "EDITING")
	}

	/// Back to the camera, with the settings from before
	func endEditing() {
		guard let editing else {
			return
		}
		self.editing = nil
		configuration = editing.previousConfiguration
		camera = editing.previousCamera
		stillFrames.clear()
		Task { await startCamera() }
	}

	/// Saves back into one of Bayer's photos, or an import as a new photo with its picture underneath
	private func saveEditing() {
		guard let editing, let frame = stillFrames.current else {
			return
		}
		isCapturing = true
		captureCount += 1
		ChipSounds.shared.play(.shutter)
		do {
			let image = try PhotoExporter.render(
				frame: frame,
				configuration: configuration,
				camera: camera,
				waveTime: 0,
				pixelSize: CGSize(width: editing.width, height: editing.height),
				scale: 1,
				crisp: pro.exportSize == .crisp
			)
			lastPhoto = image
			let edit = EditData(
				original: editing.original,
				configuration: configuration,
				camera: camera,
				outputWidth: editing.width,
				outputHeight: editing.height,
				exportSize: pro.exportSize
			)
			Task {
				do {
					if let assetID = editing.opened.assetID {
						try await PhotoLibrary.saveEdit(image, edit: edit, to: assetID)
						lastAssetID = assetID
					} else {
						lastAssetID = try await PhotoLibrary.save(image, original: editing.opened.original, edit: edit)
					}
					note(.saved)
				} catch {
					note(.failed(error is PhotoLibrary.Failure ? "NO ACCESS" : "NOT SAVED"))
				}
				isCapturing = false
			}
		} catch {
			isCapturing = false
			note(.failed("FAILED"))
		}
	}

	func note(_ note: PhotoNote) {
		photoNote = note
		ChipSounds.shared.play(note == .saved ? .saved : .failed)
		Task {
			try? await Task.sleep(for: .seconds(1.8))
			if photoNote == note {
				photoNote = nil
			}
		}
	}

	func show(_ message: String) {
		toast = message
		Task {
			try? await Task.sleep(for: .seconds(1.6))
			if toast == message {
				toast = nil
			}
		}
	}
}

/// The shader's dither patterns, by the names the UI shows. Raw values are the shader's mode numbers;
/// its 4×4 and 2×2 Bayer modes are left out, since 8×8 covers them.
enum DitherMode: Int, CaseIterable, Identifiable {
	/// No dither at all: each cell just takes its nearest colour. First, as the starting point of the track.
	case flat = 7
	case bayer = 0
	case halftone = 3
	case lines = 4
	case crosshatch = 5
	case noise = 6
	/// Error diffusion, like old Mac screenshots
	case atkinson = 8
	/// Error diffusion, smoother and denser
	case floyd = 9

	var id: Int { rawValue }

	var title: String {
		switch self {
			case .bayer: "BAYER"
			case .halftone: "DOTS"
			case .lines: "LINES"
			case .crosshatch: "CROSS"
			case .noise: "NOISE"
			case .flat: "FLAT"
			case .atkinson: "ATKIN"
			case .floyd: "FLOYD"
		}
	}

	/// Old saved modes 1 and 2 were the smaller Bayer matrices
	init(shaderMode: Int) {
		self = DitherMode(rawValue: shaderMode) ?? .bayer
	}
}

enum PhotoNote: Equatable {
	case saved
	case failed(String)

	var title: String {
		switch self {
			case .saved: "SAVED"
			case let .failed(reason): reason
		}
	}
}
