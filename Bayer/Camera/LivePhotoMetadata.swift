import CoreMedia
import Foundation

/// The two timed-metadata tracks the Lock Screen needs before it plays a Live Photo as a wallpaper.
/// Without them Photos still pairs the still and the movie, but the wallpaper says "Motion Not Available".
///
/// Apple doesn't document these. The camera writes them, and the Lock Screen checks for them:
/// - `live-photo-info`: one sample for each video frame, the camera's own record, repeated as is;
/// - `still-image-time` (-1) with `live-photo-still-image-transform` (an identity 3×3): one sample at
///   the still's frame, in the 600 timescale.
///
/// The layout and the camera's values were measured on an iPhone by LivePaper (Yuyang Zeng, MIT) and
/// written this way by Glitter Live (Buddha Nag, MIT); notice at the end of the file.
nonisolated enum LivePhotoMetadata {
	private static let infoKey = "com.apple.quicktime.live-photo-info"
	/// The doubled prefix is what the camera writes
	private static let infoDataType = "com.apple.quicktime.com.apple.quicktime.live-photo-info"
	private static let stillImageTimeKey = "com.apple.quicktime.still-image-time"
	private static let stillImageTransformKey = "com.apple.quicktime.live-photo-still-image-transform"

	/// The camera's timescale for these samples. At the video's own timescale the writer drops the
	/// empty edit that delays the still's sample, and the still lands at 0 s, which the Lock Screen rejects.
	static let timescale: CMTimeScale = 600

	/// QuickTime's well-known data types
	private static let rawDataType: UInt32 = 0
	private static let int8DataType: UInt32 = 0x41
	private static let float64MatrixDataType: UInt32 = 0x53

	enum Failure: Error {
		case format
		case sample
	}

	/// `live-photo-info`: its key, its type, the camera's setup, and raw samples
	static func infoFormatDescription() throws -> CMFormatDescription {
		var dimensions = Data()
		dimensions.appendBigEndian(cameraDimensions.width)
		dimensions.appendBigEndian(cameraDimensions.height)
		let setup = Atom.make("cfgv", cameraSetupPlist) + Atom.make("dims", dimensions)
		let key = keyDeclaration(infoKey)
			+ Atom.make("dtyp", reverseDNSType(infoDataType))
			+ Atom.make("setu", setup)
			+ Atom.make("ctps", Atom.make("dtyp", wellKnownType(rawDataType)))
		return try formatDescription(keys: Atom.make(keyID: 1, key))
	}

	/// `still-image-time` (int8) and the still's transform (a 3×3 of float64s)
	static func stillFormatDescription() throws -> CMFormatDescription {
		let time = keyDeclaration(stillImageTimeKey) + Atom.make("dtyp", wellKnownType(int8DataType))
		let transform = keyDeclaration(stillImageTransformKey) + Atom.make("dtyp", wellKnownType(float64MatrixDataType))
		return try formatDescription(keys: Atom.make(keyID: 1, time) + Atom.make(keyID: 2, transform))
	}

	static func infoSample(format: CMFormatDescription, at time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
		try sample(Atom.make(keyID: 1, cameraInfoPayload), format: format, time: time, duration: duration)
	}

	/// -1, as the camera writes it, and an identity transform
	static func stillSample(format: CMFormatDescription, at time: CMTime) throws -> CMSampleBuffer {
		var identity = Data()
		for value in [1.0, 0, 0, 0, 1, 0, 0, 0, 1] {
			identity.appendBigEndian(value.bitPattern)
		}
		let payload = Atom.make(keyID: 1, Data([0xFF])) + Atom.make(keyID: 2, identity)
		return try sample(payload, format: format, time: time, duration: CMTime(value: 1, timescale: timescale))
	}

	// MARK: Encoding

	private static func keyDeclaration(_ key: String) -> Data {
		Atom.make("keyd", Data("mdta".utf8) + Data(key.utf8))
	}

	private static func wellKnownType(_ type: UInt32) -> Data {
		var data = Data()
		data.appendBigEndian(UInt32(0))
		data.appendBigEndian(type)
		return data
	}

	private static func reverseDNSType(_ type: String) -> Data {
		var data = Data()
		data.appendBigEndian(UInt32(1))
		data.append(Data(type.utf8))
		return data
	}

	/// A `mebx` sample description: 6 reserved bytes, data reference index 1, then the key table
	private static func formatDescription(keys: Data) throws -> CMFormatDescription {
		var body = Data(count: 6)
		body.appendBigEndian(UInt16(1))
		body.append(Atom.make("keys", keys))
		let data = Atom.make("mebx", body)
		var description: CMFormatDescription?
		let status = unsafe data.withUnsafeBytes { buffer in
			unsafe CMMetadataFormatDescriptionCreateFromBigEndianMetadataDescriptionData(
				allocator: kCFAllocatorDefault,
				bigEndianMetadataDescriptionData: buffer.bindMemory(to: UInt8.self).baseAddress!,
				size: data.count,
				flavor: nil,
				formatDescriptionOut: &description
			)
		}
		guard status == noErr, let description else {
			throw Failure.format
		}
		return description
	}

	private static func sample(_ bytes: Data, format: CMFormatDescription, time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
		var block: CMBlockBuffer?
		var status = unsafe CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault,
			memoryBlock: nil,
			blockLength: bytes.count,
			blockAllocator: kCFAllocatorDefault,
			customBlockSource: nil,
			offsetToData: 0,
			dataLength: bytes.count,
			flags: kCMBlockBufferAssureMemoryNowFlag,
			blockBufferOut: &block
		)
		guard status == noErr, let block else {
			throw Failure.sample
		}
		status = unsafe bytes.withUnsafeBytes {
			unsafe CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
		}
		guard status == noErr else {
			throw Failure.sample
		}
		var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
		var size = bytes.count
		var sample: CMSampleBuffer?
		status = unsafe CMSampleBufferCreateReady(
			allocator: kCFAllocatorDefault,
			dataBuffer: block,
			formatDescription: format,
			sampleCount: 1,
			sampleTimingEntryCount: 1,
			sampleTimingArray: &timing,
			sampleSizeEntryCount: 1,
			sampleSizeArray: &size,
			sampleBufferOut: &sample
		)
		guard status == noErr, let sample else {
			throw Failure.sample
		}
		return sample
	}

	// MARK: The camera's values

	/// The camera's capture size, kept whatever the movie's size
	private static let cameraDimensions = (width: UInt32(1920), height: UInt32(1440))

	/// A binary plist naming iPhone OS 17.0 (21A5277h) and the capture frameworks' versions
	private static let cameraSetupPlist = Data(hex:
		"62706c6973743030d301020304050c5f10214c69766550686f746f4d65746164"
			+ "61746153657475704461746156657273696f6e5d53797374656d56657273696f"
			+ "6e5f10114672616d65776f726b56657273696f6e731001d3060708090a0b5f10"
			+ "1350726f647563744275696c6456657273696f6e5b50726f647563744e616d65"
			+ "5e50726f6475637456657273696f6e583231413532373768596950686f6e6520"
			+ "4f535431372e30d40d0e0f10111213145a436f72654d6f74696f6e5d434d4361"
			+ "7074757265436f72655e483130495350536572766963657359436f72654d6564"
			+ "696158323836382e302e32573434362e352e335432302e325e333034352e3639"
			+ "2e322e31312e340008000f0033004100550057005e00740080008f009800a200"
			+ "a700b000bb00c900d800e200eb00f300f8000000000000020100000000000000"
			+ "1500000000000000000000000000000107")

	/// One camera record, repeated in every frame
	private static let cameraInfoPayload = Data(hex:
		"03000000bdc36d3ce3b5eb6d800000007b80ad425a2d64410a08cb3e7feea6bd"
			+ "79e9f63f000080400400ff000000000000000000000000000000000000000000"
			+ "07000000525e873ee66e52bf1b2a6ac4d37862bf761ed23dde3f8ec313f52f39"
			+ "b2f04439ff309dbf1a17f1ed1b070000206796ed1b0700000000000000000000"
			+ "0000000000000000")
}

/// QuickTime atoms: `[size: UInt32][type: 4 bytes][payload]`
private nonisolated enum Atom {
	static func make(_ fourCC: String, _ payload: Data) -> Data {
		var atom = Data()
		atom.appendBigEndian(UInt32(8 + payload.count))
		atom.append(Data(fourCC.utf8))
		atom.append(payload)
		return atom
	}

	/// Key tables and metadata samples put the local key ID where the type would be
	static func make(keyID: UInt32, _ payload: Data) -> Data {
		var atom = Data()
		atom.appendBigEndian(UInt32(8 + payload.count))
		atom.appendBigEndian(keyID)
		atom.append(payload)
		return atom
	}
}

private nonisolated extension Data {
	init(hex: String) {
		var bytes: [UInt8] = []
		bytes.reserveCapacity(hex.count / 2)
		var index = hex.startIndex
		while index < hex.endIndex {
			let next = hex.index(index, offsetBy: 2)
			bytes.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
			index = next
		}
		self.init(bytes)
	}

	mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
		Swift.withUnsafeBytes(of: value.bigEndian) { unsafe append(contentsOf: $0) }
	}
}

// The metadata layout and camera values above:
//
// MIT License
//
// Copyright (c) 2026 Yuyang Zeng (LivePaper)
// Copyright (c) 2026 Buddha Nag (Glitter Live)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
