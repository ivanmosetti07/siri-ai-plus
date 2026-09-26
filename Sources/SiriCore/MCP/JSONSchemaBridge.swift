import Foundation
import FoundationModels

/// Traduce lo schema JSON degli argomenti di uno strumento MCP in uno schema per la generazione guidata,
/// e il contenuto generato di nuovo in JSON.
public enum JSONSchemaBridge {
    public static func generationSchema(for tool: MCPToolInfo) throws -> GenerationSchema {
        let root = dynamic(tool.inputSchema, name: sanitize(tool.name), depth: 0)
        return try GenerationSchema(root: root, dependencies: [])
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "Args_" + String(cleaned)
    }

    static func dynamic(_ schema: JSONValue, name: String, depth: Int) -> DynamicGenerationSchema {
        if let options = schema["enum"]?.array?.compactMap(\.string), !options.isEmpty {
            return DynamicGenerationSchema(name: name, anyOf: options)
        }
        var type = schema["type"]?.string
        if type == nil, let types = schema["type"]?.array?.compactMap(\.string) { type = types.first { $0 != "null" } }
        switch type {
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case "array":
            let items = schema["items"] ?? .object(["type": .string("string")])
            return DynamicGenerationSchema(arrayOf: dynamic(items, name: name + "Item", depth: depth + 1),
                                           minimumElements: nil, maximumElements: 20)
        case "object" where depth < 3:
            let properties = schema["properties"]?.object ?? [:]
            let required = Set((schema["required"]?.array ?? []).compactMap(\.string))
            // Oggetto libero (es. "arguments" degli strumenti a catalogo): si genera come testo JSON.
            guard !properties.isEmpty else { return DynamicGenerationSchema(type: String.self) }
            return DynamicGenerationSchema(name: name, properties: properties.sorted { $0.key < $1.key }.map { key, value in
                .init(name: key, description: value["description"]?.string.map { String($0.prefix(160)) },
                      schema: dynamic(value, name: "\(name)_\(sanitize(key))", depth: depth + 1),
                      isOptional: !required.contains(key))
            })
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    /// Contenuto generato → JSON per `tools/call`, riconvertendo in oggetti gli oggetti liberi generati come testo.
    public static func json(from content: GeneratedContent, schema: JSONValue) -> JSONValue {
        let value = json(from: content)
        return conform(value, to: schema)
    }

    static func conform(_ value: JSONValue, to schema: JSONValue) -> JSONValue {
        let type = schema["type"]?.string ?? schema["type"]?.array?.compactMap(\.string).first { $0 != "null" }
        switch (type, value) {
        case ("object", .string(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = try? JSONValue.parse(Data(trimmed.utf8)), parsed.object != nil { return parsed }
            return .object([:])
        case ("object", .object(let properties)):
            let schemas = schema["properties"]?.object ?? [:]
            return .object(Dictionary(uniqueKeysWithValues: properties.map { key, item in
                (key, schemas[key].map { conform(item, to: $0) } ?? item)
            }))
        case ("array", .array(let items)):
            let itemSchema = schema["items"] ?? .object([:])
            return .array(items.map { conform($0, to: itemSchema) })
        default:
            return value
        }
    }

    /// Contenuto generato → JSON per `tools/call`.
    public static func json(from content: GeneratedContent) -> JSONValue {
        switch content.kind {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let items): return .array(items.map(json(from:)))
        case .structure(let properties, _): return .object(properties.mapValues(json(from:)))
        @unknown default: return .null
        }
    }
}
