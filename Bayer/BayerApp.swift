import SwiftUI

@main
struct BayerApp: App {
	@State private var model = AppModel()

	var body: some Scene {
		WindowGroup {
			CameraScreen(model: model)
				#if os(macOS)
					.frame(minWidth: 720, minHeight: 560)
				#endif
		}
		#if os(macOS)
			.defaultSize(width: 1180, height: 780)
			.windowStyle(.hiddenTitleBar)
		#endif
	}
}
