import CoreTransferable
import PhotosUI
import SwiftUI

extension AppModel {
	/// A photo opens for editing, one of Bayer's with its original underneath. A video is dithered whole,
	/// with the current settings, and saved as a new video.
	func importItem(_ item: PhotosPickerItem) {
		let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
		if isVideo {
			importVideo {
				guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
					throw MovieMaker.Failure.cantRead
				}
				return movie.url
			}
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

	/// A picture or movie chosen in Files, on the Mac
	func importFile(_ url: URL) {
		let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
		if let type, type.conforms(to: .movie) || type.conforms(to: .video) {
			importVideo {
				// A copy of our own, since the file is only lent while it's open and dithering takes a while
				try await Self.copyOut(url)
			}
			return
		}
		open {
			let data = try await Self.read(url)
			guard let opened = PhotoLibrary.open(data: data) else {
				throw PhotoLibrary.Failure.unreadable
			}
			return opened
		}
	}

	@concurrent private static func read(_ url: URL) async throws -> Data {
		let scoped = url.startAccessingSecurityScopedResource()
		defer {
			if scoped {
				url.stopAccessingSecurityScopedResource()
			}
		}
		return try Data(contentsOf: url)
	}

	@concurrent private static func copyOut(_ url: URL) async throws -> URL {
		let scoped = url.startAccessingSecurityScopedResource()
		defer {
			if scoped {
				url.stopAccessingSecurityScopedResource()
			}
		}
		let copy = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
		try FileManager.default.copyItem(at: url, to: copy)
		return copy
	}

	/// `load` gives a movie file that's Bayer's to delete
	private func importVideo(_ load: @escaping () async throws -> URL) {
		guard videoProgress == nil else {
			return
		}
		videoProgress = 0
		let configuration = configuration
		let camera = camera
		videoTask = Task {
			do {
				let source = try await load()
				defer {
					try? FileManager.default.removeItem(at: source)
				}
				let dithered = try await MovieMaker.ditherVideo(at: source, configuration: configuration, camera: camera) { fraction in
					self.videoProgress = fraction
				}
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
