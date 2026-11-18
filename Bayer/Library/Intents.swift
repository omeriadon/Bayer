import AppIntents
import Defaults

// MARK: Take a photo

/// Opens Bayer and takes a photo as soon as the camera has a frame, with whatever look is set.
struct TakeDitheredPhotoIntent: AppIntent {
	static let title: LocalizedStringResource = "Take Dithered Photo"
	static let description = IntentDescription("Opens Bayer and takes a photo with the current palette and style.")
	static let supportedModes: IntentModes = .foreground(.immediate)

	@MainActor
	func perform() async throws -> some IntentResult {
		await AppModel.shared.captureWhenReady()
		return .result()
	}
}

// MARK: Looks

struct LookEntity: AppEntity, Identifiable {
	static let typeDisplayRepresentation: TypeDisplayRepresentation = "Look"
	static let defaultQuery = LookQuery()

	let id: String
	let name: String

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name.capitalized)")
	}

	init(_ look: Look) {
		id = look.id
		name = look.name
	}
}

struct LookQuery: EntityQuery {
	func entities(for identifiers: [LookEntity.ID]) async throws -> [LookEntity] {
		Defaults[.looks].filter { identifiers.contains($0.id) }.map(LookEntity.init)
	}

	func suggestedEntities() async throws -> [LookEntity] {
		Defaults[.looks].map(LookEntity.init)
	}
}

struct ApplyLookIntent: AppIntent {
	static let title: LocalizedStringResource = "Apply Look"
	static let description = IntentDescription("Switches Bayer to one of your saved looks.")

	@Parameter(title: "Look")
	var look: LookEntity

	static var parameterSummary: some ParameterSummary {
		Summary("Apply \(\.$look)")
	}

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		let model = AppModel.shared
		guard let saved = model.looks.first(where: { $0.id == look.id }) else {
			return .result(dialog: "That look isn't saved any more.")
		}
		model.apply(saved)
		return .result(dialog: "Bayer is using \(saved.name.capitalized).")
	}
}

// MARK: Palettes

struct PaletteEntity: AppEntity, Identifiable {
	static let typeDisplayRepresentation: TypeDisplayRepresentation = "Palette"
	static let defaultQuery = PaletteQuery()

	let id: String
	let name: String

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name.capitalized)")
	}

	init(_ palette: DitherPalette) {
		id = palette.id
		name = palette.name
	}
}

struct PaletteQuery: EntityQuery {
	private var palettes: [DitherPalette] {
		DitherPalette.all + Defaults[.customPalettes]
	}

	func entities(for identifiers: [PaletteEntity.ID]) async throws -> [PaletteEntity] {
		palettes.filter { identifiers.contains($0.id) }.map(PaletteEntity.init)
	}

	func suggestedEntities() async throws -> [PaletteEntity] {
		palettes.map(PaletteEntity.init)
	}
}

struct UsePaletteIntent: AppIntent {
	static let title: LocalizedStringResource = "Use Palette"
	static let description = IntentDescription("Switches Bayer to a palette.")

	@Parameter(title: "Palette")
	var palette: PaletteEntity

	static var parameterSummary: some ParameterSummary {
		Summary("Use \(\.$palette)")
	}

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		let model = AppModel.shared
		guard let found = model.allPalettes.first(where: { $0.id == palette.id }) else {
			return .result(dialog: "That palette isn't there any more.")
		}
		model.select(found)
		return .result(dialog: "Bayer is using \(found.name.capitalized).")
	}
}

// MARK: Shortcuts

struct BayerShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: TakeDitheredPhotoIntent(),
			phrases: ["Take a dithered photo with \(.applicationName)", "Take a \(.applicationName) photo"],
			shortTitle: "Take Photo",
			systemImageName: "camera"
		)
		AppShortcut(
			intent: ApplyLookIntent(),
			phrases: ["Apply a look in \(.applicationName)", "Switch \(.applicationName) to \(\.$look)"],
			shortTitle: "Apply Look",
			systemImageName: "square.grid.3x3"
		)
		AppShortcut(
			intent: UsePaletteIntent(),
			phrases: ["Change the \(.applicationName) palette", "Use \(\.$palette) in \(.applicationName)"],
			shortTitle: "Use Palette",
			systemImageName: "paintpalette"
		)
	}
}
