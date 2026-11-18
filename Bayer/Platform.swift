import SwiftUI
#if os(iOS)
	import UIKit
#else
	import AppKit
#endif

/// The few places iOS and macOS differ.
enum Platform {
	static var isMac: Bool {
		#if os(macOS)
			true
		#else
			false
		#endif
	}

	static func copy(_ text: String) {
		#if os(iOS)
			UIPasteboard.general.string = text
		#else
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(text, forType: .string)
		#endif
	}

	/// Where to turn the camera back on
	static var cameraSettingsURL: URL? {
		#if os(iOS)
			URL(string: UIApplication.openSettingsURLString)
		#else
			URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
		#endif
	}

	static var photosURL: URL? {
		#if os(iOS)
			URL(string: "photos-redirect://")
		#else
			URL(fileURLWithPath: "/System/Applications/Photos.app")
		#endif
	}
}

extension View {
	/// Hides the status bar and home indicator on iPhone and iPad. Nothing to hide on the Mac.
	func hidesSystemChrome() -> some View {
		#if os(iOS)
			statusBarHidden().persistentSystemOverlays(.hidden)
		#else
			self
		#endif
	}

	/// Full screen on iPhone and iPad, a sheet on the Mac, which has no full-screen cover.
	func fullScreen<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
		#if os(iOS)
			fullScreenCover(isPresented: isPresented, content: content)
		#else
			sheet(isPresented: isPresented) {
				content().frame(minWidth: 640, minHeight: 640)
			}
		#endif
	}
}
