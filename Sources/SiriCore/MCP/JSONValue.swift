import Foundation

/// Valore JSON generico, usato per messaggi MCP e schemi degli strumenti.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n):
            if n.rounded() == n && abs(n) < 1e15 { try container.encode(Int(n)) } else { try container.encode(n) }
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }

    public static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public var compactString: String { (try? data()).map { String(decoding: $0, as: UTF8.self) } ?? "null" }
}
