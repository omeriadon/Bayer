import CoreTransferable
import PhotosUI
import SwiftUI

extension AppModel {
	/// A photo opens for editing, one of Bayer's with its original underneath. A video is dithered whole,
	/// with the current settings, and saved as a new video.
	func importItem(_ item: PhotosPickerItem) {
		let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
		if isVideo {
			importVideo(item)
			return
		}
		open {
			// From the library, so one of Bayer's photos opens with its original and recipe
			if let identifier = item.itemIdentifier, let opened = try? await PhotoLibrary.open(assetID: identifier) {
				return opened
			}
			// Without library access, just the picture
			guard let data = try await item.loadTransferable(type: Data.self), let opened = PhotoLibrary.open(data: data) else {
				throw PhotoLibrary.Failure.unreadable
			}
			return opened
		}
	}

	private func importVideo(_ item: PhotosPickerItem) {
		guard videoProgress == nil else {
			return
		}
		videoProgress = 0
		let configuration = configuration
		let camera = camera
		videoTask = Task {
			do {
				guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
					throw MovieMaker.Failure.cantRead
				}
				let dithered = try await MovieMaker.ditherVideo(at: movie.url, configuration: configuration, camera: camera) { fraction in
					self.videoProgress = fraction
				}
				try? FileManager.default.removeItem(at: movie.url)
				try await MovieMaker.saveVideo(dithered)
				note(.saved)
			} catch is CancellationError {
				show("STOPPED")
			} catch {
				note(.failed((error as? PhotoLibrary.Failure) == .notAllowed ? "NO ACCESS" : "VIDEO FAILED"))
			}
			videoProgress = nil
			videoTask = nil
		}
	}

	func cancelVideo() {
		videoTask?.cancel()
	}
}
