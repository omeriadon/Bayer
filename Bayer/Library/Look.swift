import Foundation

/// A saved look: the whole picture setup, everything except which camera and the zoom.
nonisolated struct Look: Identifiable, Equatable, Sendable, Codable {
	var id: String
	var name: String
	var configuration: DitherConfiguration
	var mapping: CameraSettings.Mapping
	var invert: Bool
	var texelsPerCell: Int
	var depthTexelsPerCell: Int
	var depthNear: Float
	var depthFar: Float

	init(name: String, configuration: DitherConfiguration, camera: CameraSettings) {
		id = UUID().uuidString
		self.name = name
		self.configuration = configuration
		mapping = camera.mapping
		invert = camera.invert
		texelsPerCell = camera.texelsPerCell
		depthTexelsPerCell = camera.depthTexelsPerCell
		depthNear = camera.depthNear
		depthFar = camera.depthFar
	}

	func apply(to camera: inout CameraSettings) {
		camera.mapping = mapping
		camera.invert = invert
		camera.texelsPerCell = texelsPerCell
		camera.depthTexelsPerCell = depthTexelsPerCell
		camera.depthNear = depthNear
		camera.depthFar = depthFar
	}

	private enum CodingKeys: String, CodingKey {
		case id, name, configuration, mapping, invert, texelsPerCell, depthTexelsPerCell, depthNear, depthFar
	}

	/// Lenient, so looks saved now still load after the configuration gains settings
	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let defaults = CameraSettings()
		id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
		name = try container.decodeIfPresent(String.self, forKey: .name) ?? "LOOK"
		configuration = try container.decodeIfPresent(LenientConfiguration.self, forKey: .configuration)?.value ?? .bayerDefault
		mapping = try container.decodeIfPresent(CameraSettings.Mapping.self, forKey: .mapping) ?? defaults.mapping
		invert = try container.decodeIfPresent(Bool.self, forKey: .invert) ?? defaults.invert
		texelsPerCell = try container.decodeIfPresent(Int.self, forKey: .texelsPerCell) ?? defaults.texelsPerCell
		depthTexelsPerCell = try container.decodeIfPresent(Int.self, forKey: .depthTexelsPerCell) ?? defaults.depthTexelsPerCell
		depthNear = try container.decodeIfPresent(Float.self, forKey: .depthNear) ?? defaults.depthNear
		depthFar = try container.decodeIfPresent(Float.self, forKey: .depthFar) ?? defaults.depthFar
	}
}

/// Decodes a `DitherConfiguration` over Bayer's defaults: keys missing from older data keep their default
/// instead of failing the whole decode, which is what synthesized Codable would do.
nonisolated struct LenientConfiguration: Decodable {
	let value: DitherConfiguration

	init(from decoder: any Decoder) throws {
		let stored = try decoder.singleValueContainer().decode(JSONValue.self)
		let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DitherConfiguration.bayerDefault))
		guard var merged = base as? [String: Any], case let .object(fields) = stored else {
			value = .bayerDefault
			return
		}
		for (key, field) in fields {
			merged[key] = field.any
		}
		let data = try JSONSerialization.data(withJSONObject: merged)
		value = (try? JSONDecoder().decode(DitherConfiguration.self, from: data)) ?? .bayerDefault
	}
}

/// Any JSON, kept as it was read, so it can be laid over defaults.
nonisolated enum JSONValue: Decodable, Sendable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])

	init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
		} else if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Double.self) {
			self = .number(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([JSONValue].self) {
			self = .array(value)
		} else {
			self = .object(try container.decode([String: JSONValue].self))
		}
	}

	var any: Any {
		switch self {
			case .null: NSNull()
			case let .bool(value): value
			case let .number(value): value
			case let .string(value): value
			case let .array(values): values.map(\.any)
			case let .object(fields): fields.mapValues(\.any)
		}
	}
}
