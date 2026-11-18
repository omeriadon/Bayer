import AVFoundation
import Synchronization

/// Bayer's sounds: a tiny square-wave and noise synth, like an old handheld, generated as it plays.
/// Ambient audio, so the ring switch silences it and music keeps playing underneath.
final class ChipSounds {
	static let shared = ChipSounds()

	enum Sound {
		/// Any button going down
		case click
		/// A track moving a step: 0 at its left end, 1 at its right, rising in pitch all the way
		case tick(Double)
		case toggleOn
		case toggleOff
		case shutter
		case saved
		case failed
	}

	var isEnabled = true

	private let voices = Voices()
	private var engine: AVAudioEngine?
	private var stopTask: Task<Void, Never>?
	private nonisolated static let sampleRate = 44100.0

	private init() {
		// Once, off the main thread: setting the category can block while audio is active
		#if os(iOS)
			Task.detached {
				try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
			}
		#endif
	}

	func play(_ sound: Sound) {
		guard isEnabled else {
			return
		}
		guard startIfNeeded() else {
			return
		}
		voices.add(Self.notes(for: sound))
		// The engine pauses a little after the last sound, so it isn't running for nothing,
		// and is kept so the next sound starts without rebuilding it
		stopTask?.cancel()
		stopTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(2))
			guard !Task.isCancelled else {
				return
			}
			self?.engine?.pause()
		}
	}

	private func startIfNeeded() -> Bool {
		if let engine {
			if engine.isRunning {
				return true
			}
			return (try? engine.start()) != nil
		}
		let engine = AVAudioEngine()
		guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else {
			return false
		}
		let source = Self.makeSource(format: format, voices: voices)
		engine.attach(source)
		engine.connect(source, to: engine.mainMixerNode, format: format)
		engine.mainMixerNode.outputVolume = 0.35
		do {
			try engine.start()
		} catch {
			return false
		}
		self.engine = engine
		return true
	}

	/// Built outside the main actor: the render block runs on the audio thread
	private nonisolated static func makeSource(format: AVAudioFormat, voices: Voices) -> AVAudioSourceNode {
		unsafe AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
			let buffers = unsafe UnsafeMutableAudioBufferListPointer(bufferList)
			guard let data = unsafe buffers.first?.mData?.assumingMemoryBound(to: Float.self) else {
				return noErr
			}
			unsafe voices.render(into: data, count: Int(frameCount))
			return noErr
		}
	}

	// MARK: Tunes

	private nonisolated struct Note {
		/// Hz; 0 is noise
		var frequency: Double
		var start: Double
		var length: Double
		var duty: Double = 0.5
		var volume: Double = 0.6
	}

	private static func notes(for sound: Sound) -> [Note] {
		func pitch(_ semitones: Double) -> Double {
			// From C5
			523.25 * pow(2, semitones / 12)
		}
		switch sound {
			case .click:
				return [Note(frequency: pitch(19), start: 0, length: 0.012, duty: 0.25, volume: 0.35)]
			case let .tick(fraction):
				// Two and a half octaves from one end of the track to the other, so every step has its own pitch
				let semitones = -12 + min(max(fraction, 0), 1) * 30
				return [Note(frequency: pitch(semitones), start: 0, length: 0.03, duty: 0.25, volume: 0.256)]
			case .toggleOn:
				return [
					Note(frequency: pitch(0), start: 0, length: 0.04, volume: 0.336),
					Note(frequency: pitch(7), start: 0.045, length: 0.06, volume: 0.336),
				]
			case .toggleOff:
				return [
					Note(frequency: pitch(7), start: 0, length: 0.04, volume: 0.336),
					Note(frequency: pitch(0), start: 0.045, length: 0.06, volume: 0.336),
				]
			case .shutter:
				return [
					Note(frequency: 0, start: 0, length: 0.07, volume: 0.5),
					Note(frequency: pitch(-12), start: 0.02, length: 0.05, duty: 0.125),
					Note(frequency: pitch(12), start: 0.075, length: 0.05, duty: 0.25),
				]
			case .saved:
				return [0.0, 4, 7, 12].enumerated().map { index, semitones in
					Note(frequency: pitch(semitones), start: Double(index) * 0.06, length: 0.07, duty: 0.5, volume: 0.45)
				}
			case .failed:
				return [
					Note(frequency: pitch(-5), start: 0, length: 0.09, duty: 0.125),
					Note(frequency: pitch(-11), start: 0.1, length: 0.16, duty: 0.125),
				]
		}
	}

	/// The notes playing, shared with the audio thread, which only ever tries the lock so it never waits
	private nonisolated final class Voices: Sendable {
		private struct Voice {
			var frequency: Double
			var startSample: Int
			var lengthSamples: Int
			var duty: Double
			var volume: Double
			var phase = 0.0
			var noise: UInt16 = 0x7FFF
		}

		private struct State {
			var clock = 0
			var voices: [Voice] = []
		}

		private let state = Mutex(State())

		func add(_ notes: [Note]) {
			state.withLock { state in
				for note in notes {
					state.voices.append(Voice(
						frequency: note.frequency,
						startSample: state.clock + Int(note.start * ChipSounds.sampleRate),
						lengthSamples: max(1, Int(note.length * ChipSounds.sampleRate)),
						duty: note.duty,
						volume: note.volume
					))
				}
			}
		}

		func render(into output: UnsafeMutablePointer<Float>, count: Int) {
			let rendered = state.withLockIfAvailable { state -> Bool in
				for frame in 0 ..< count {
					let now = state.clock + frame
					var sample = 0.0
					for index in state.voices.indices {
						var voice = state.voices[index]
						let age = now - voice.startSample
						guard age >= 0, age < voice.lengthSamples else {
							continue
						}
						// A quick attack, then a straight fall to nothing
						let progress = Double(age) / Double(voice.lengthSamples)
						let envelope = min(1, Double(age) / 40) * (1 - progress)
						if voice.frequency > 0 {
							voice.phase += voice.frequency / ChipSounds.sampleRate
							voice.phase -= voice.phase.rounded(.down)
							sample += (voice.phase < voice.duty ? 1 : -1) * voice.volume * envelope
						} else {
							// The handheld's noise channel: a 15-bit shift register
							if age % 4 == 0 {
								let bit = (voice.noise ^ (voice.noise >> 1)) & 1
								voice.noise = (voice.noise >> 1) | (bit << 14)
							}
							sample += (voice.noise & 1 == 0 ? 1 : -1) * voice.volume * envelope
						}
						state.voices[index] = voice
					}
					unsafe output[frame] = Float(max(-1, min(1, sample * 0.5)))
				}
				state.clock += count
				state.voices.removeAll { state.clock - $0.startSample >= $0.lengthSamples }
				return true
			}
			if rendered == nil {
				for frame in 0 ..< count {
					unsafe output[frame] = 0
				}
			}
		}
	}
}
