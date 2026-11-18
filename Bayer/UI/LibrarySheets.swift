import SwiftUI

/// PALETTES, LOOKS and SETTINGS: sheets over the camera, drawn in the same pixels as everything else.
struct LibrarySheetView: View {
	let sheet: LibrarySheet
	@Bindable var model: AppModel

	@Environment(\.pixelTheme) private var theme
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(spacing: 12) {
			HStack {
				PixelIconView(icon: sheet.icon, cell: 2.5, color: theme.ink)
				PixelText(sheet.title, cell: 3, color: theme.ink)
				Spacer()
				PixelIconButton(icon: .close, label: "Close") {
					dismiss()
				}
			}
			ScrollView {
				VStack(spacing: 8) {
					switch sheet {
						case .palettes: PalettesPage(model: model)
						case .looks: LooksPage(model: model)
						case .settings: SettingsPage(model: model)
					}
				}
				.padding(.bottom, 16)
			}
			.scrollIndicators(.hidden)
			// Scrolls on under the home indicator instead of stopping above a band of background
			.ignoresSafeArea(.container, edges: .bottom)
		}
		.padding([.horizontal, .top], 16)
		.background(theme.paper.ignoresSafeArea())
		.buttonStyle(PixelButtonStyle())
	}
}

extension LibrarySheet {
	var title: String {
		switch self {
			case .palettes: "PALETTES"
			case .looks: "LOOKS"
			case .settings: "SETTINGS"
		}
	}

	var icon: PixelIcon {
		switch self {
			case .palettes: .drop
			case .looks: .pattern
			case .settings: .tune
		}
	}
}

// MARK: Palettes

/// Built-ins can be hidden from the strip; yours can be added, renamed and deleted.
private struct PalettesPage: View {
	@Bindable var model: AppModel

	@State private var renaming: DitherPalette?
	@State private var name = ""
	@State private var sceneFailed = false

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		HStack(spacing: 8) {
			SheetButton(title: "SAVE INK", icon: .plus) {
				model.saveCurrentInk()
			}
			SheetButton(title: sceneFailed ? "NO PICTURE" : "FROM SCENE", icon: .camera, lit: sceneFailed) {
				if model.paletteFromScene() == nil {
					sceneFailed = true
					Task {
						try? await Task.sleep(for: .seconds(1.5))
						sceneFailed = false
					}
				}
			}
			.disabled(!model.camera.usesCamera)
			.opacity(model.camera.usesCamera ? 1 : 0.4)
		}

		SheetHeading(text: "YOURS")
		if model.customPalettes.isEmpty {
			PixelNote(text: "NONE YET")
		}
		ForEach(model.customPalettes) { palette in
			PaletteRow(palette: palette, selected: palette == model.palette, stacked: true) {
				model.select(palette)
			} trailing: {
				SmallChip(title: model.hiddenPalettes.contains(palette.id) ? "HIDDEN" : "SHOWN", lit: !model.hiddenPalettes.contains(palette.id)) {
					model.setHidden(palette, !model.hiddenPalettes.contains(palette.id))
				}
				SmallChip(title: "NAME") {
					name = palette.name
					renaming = palette
				}
				ConfirmChip(title: "DELETE") {
					model.delete(palette)
				}
			}
		}

		SheetHeading(text: "BUILT IN")
		ForEach(DitherPalette.all) { palette in
			let hidden = model.hiddenPalettes.contains(palette.id)
			PaletteRow(palette: palette, selected: palette == model.palette) {
				model.select(palette)
			} trailing: {
				SmallChip(title: hidden ? "HIDDEN" : "SHOWN", lit: !hidden) {
					model.setHidden(palette, !hidden)
				}
			}
		}
		Color.clear
			.frame(height: 0)
			.alert("Rename palette", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
			TextField("Name", text: $name)
			Button("Save") {
				if let renaming {
					model.rename(renaming, to: name)
				}
				renaming = nil
			}
			Button("Cancel", role: .cancel) {
				renaming = nil
			}
		} message: {
			Text("Capitals, digits and a few symbols, up to \(PixelName.maximumLength) characters.")
		}
	}
}

private struct PaletteRow<Trailing: View>: View {
	let palette: DitherPalette
	let selected: Bool
	/// Buttons on their own row underneath, for rows with several
	var stacked = false
	let use: () -> Void
	@ViewBuilder let trailing: () -> Trailing

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		if stacked {
			VStack(alignment: .trailing, spacing: 6) {
				face
				HStack(spacing: 6) {
					trailing()
				}
			}
		} else {
			HStack(spacing: 10) {
				face
				trailing()
			}
		}
	}

	private var face: some View {
		Button(action: use) {
			VStack(alignment: .leading, spacing: 6) {
				HStack(spacing: 2) {
					ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, color in
						Rectangle()
							.fill(Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
							.frame(width: 12, height: 12)
					}
				}
				PixelText(palette.name, cell: 1.8, color: selected ? theme.paper : theme.ink)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.pixelPanel(lit: selected, padding: 8)
		}
		.accessibilityLabel("Use \(palette.name.capitalized)")
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}

// MARK: Looks

/// The whole picture setup, saved by name and put back in one tap.
private struct LooksPage: View {
	@Bindable var model: AppModel

	@State private var renaming: Look?
	@State private var name = ""

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		SheetButton(title: "SAVE THIS LOOK", icon: .plus) {
			model.saveLook()
		}
		PixelNote(text: "SAVES COLOURS, STYLE, SIZE, DITHER AND ALL OF TUNE")
		if model.looks.isEmpty {
			PixelNote(text: "NO LOOKS YET")
		}
		ForEach(model.looks) { look in
			VStack(alignment: .trailing, spacing: 6) {
				Button {
					model.apply(look)
				} label: {
					VStack(alignment: .leading, spacing: 6) {
						HStack(spacing: 2) {
							ForEach(Array(look.configuration.palette.enumerated()), id: \.offset) { _, color in
								Rectangle()
									.fill(Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
									.frame(width: 12, height: 12)
							}
						}
						PixelText(look.name, cell: 1.8, color: theme.ink)
						PixelText(summary(look), cell: 1.3, color: theme.mid)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.pixelPanel(padding: 8)
				}
				.accessibilityLabel("Apply \(look.name.capitalized)")
				HStack(spacing: 6) {
					SmallChip(title: "NAME") {
						name = look.name
						renaming = look
					}
					ConfirmChip(title: "DELETE") {
						model.delete(look)
					}
				}
			}
		}
		.alert("Rename look", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
			TextField("Name", text: $name)
			Button("Save") {
				if let renaming {
					model.rename(renaming, to: name)
				}
				renaming = nil
			}
			Button("Cancel", role: .cancel) {
				renaming = nil
			}
		}
	}

	private func summary(_ look: Look) -> String {
		let style = DitherMode(shaderMode: look.configuration.ditherMode).title
		let size = look.texelsPerCell
		return "\(style)  1:\(size * size)  \(look.mapping.title.uppercased())"
	}
}

// MARK: Settings

private struct SettingsPage: View {
	@Bindable var model: AppModel

	var body: some View {
		SheetHeading(text: "PHOTO SIZE")
		ChoiceRow(
			options: ProSettings.ExportSize.allCases,
			selection: $model.pro.exportSize,
			title: \.title
		)
		PixelNote(text: note(for: model.pro.exportSize))

		ToggleChip(title: "SOUNDS", isOn: $model.pro.sounds)
	}

	private func note(for size: ProSettings.ExportSize) -> String {
		switch size {
			case .screen: "EXACTLY YOUR SCREEN'S PIXELS. SOME CELLS COME OUT A PIXEL WIDER THAN OTHERS"
			case .crisp: "EVERY CELL THE SAME WHOLE NUMBER OF PIXELS, ROUGHLY YOUR SCREEN'S SIZE"
		}
	}

}

// MARK: Pieces

private struct SheetHeading: View {
	let text: String

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		PixelText(text, cell: 2, color: theme.mid)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.top, 10)
	}
}

private struct SheetButton: View {
	let title: String
	let icon: PixelIcon
	var lit = false
	let action: () -> Void

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		Button(action: action) {
			HStack(spacing: 8) {
				PixelIconView(icon: icon, cell: 1.6, color: lit ? theme.paper : theme.ink)
				PixelText(title, cell: 2, color: lit ? theme.paper : theme.ink)
			}
			.frame(maxWidth: .infinity)
			.pixelPanel(lit: lit, padding: 12)
		}
		.accessibilityLabel(title.capitalized)
	}
}

private struct SmallChip: View {
	let title: String
	var lit = false
	let action: () -> Void

	@Environment(\.pixelTheme) private var theme

	var body: some View {
		Button(action: action) {
			PixelText(title, cell: 1.5, color: lit ? theme.paper : theme.ink)
				.fixedSize()
				.pixelPanel(lit: lit, padding: 8)
		}
		.accessibilityLabel(title.capitalized)
	}
}

/// Needs a second tap within a couple of seconds
private struct ConfirmChip: View {
	let title: String
	let action: () -> Void

	@State private var armed = false

	var body: some View {
		SmallChip(title: armed ? "SURE?" : title, lit: armed) {
			if armed {
				armed = false
				action()
			} else {
				armed = true
				Task {
					try? await Task.sleep(for: .seconds(2.5))
					armed = false
				}
			}
		}
	}
}
