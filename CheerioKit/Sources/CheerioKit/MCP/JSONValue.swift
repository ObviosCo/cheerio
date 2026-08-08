import Foundation

/// A JSON document as a value, for the parts of MCP that are schemaless.
///
/// JSON-RPC's `id` is "a string or a number", `params` is whatever the method says,
/// and a tool's `inputSchema` is arbitrary JSON. `Codable` alone can't express any of
/// those, so the helper needs one type that can hold JSON without knowing its shape.
/// Small enough to read in a sitting, which is the point — see ``CheerioMCPResponder``
/// for why the helper carries its own protocol code rather than a dependency.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    /// Kept apart from ``double(_:)`` so a JSON Schema `"maximum": 100` round-trips as
    /// `100` rather than `100.0`, which some clients' schema validators reject.
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not JSON")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses JSON text, or nil if it isn't JSON.
    public init?(parsing text: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
        self = value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    /// Member of this value, if it is an object and has one by that name.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// The bytes to put on the wire: one line, no stray whitespace, keys in a stable
    /// order so two runs of the same request produce the same output.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
