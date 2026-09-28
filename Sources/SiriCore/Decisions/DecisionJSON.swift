import Foundation

/// JSON con le chiavi in ordine, scritto come `json.dumps(x, ensure_ascii=False, indent=1)` di Python:
/// lo stato di una decisione deve essere identico carattere per carattere a quello di rizzo-flow
/// (e da un turno all'altro, perché llama.cpp riusi il prefisso già calcolato).
public indirect enum DecisionJSON: Sendable, Hashable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null
    case array([DecisionJSON])
    case object([Field])

    public struct Field: Sendable, Hashable {
        public let key: String
        public let value: DecisionJSON
        public init(_ key: String, _ value: DecisionJSON) { self.key = key; self.value = value }
    }

    /// Solo i campi con un valore: le parti di contesto assenti non compaiono nello stato.
    public static func fields(_ pairs: [(String, DecisionJSON?)]) -> DecisionJSON {
        .object(pairs.compactMap { key, value in value.map { Field(key, $0) } })
    }

    public func rendered(level: Int = 0) -> String {
        let indent = String(repeating: " ", count: level + 1)
        let closing = String(repeating: " ", count: level)
        switch self {
        case .string(let text): return Self.quoted(text)
        case .integer(let value): return String(value)
        case .number(let value): return Self.python(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { indent + $0.rendered(level: level + 1) }.joined(separator: ",\n") + "\n" + closing + "]"
        case .object(let fields):
            guard !fields.isEmpty else { return "{}" }
            return "{\n" + fields.map { indent + Self.quoted($0.key) + ": " + $0.value.rendered(level: level + 1) }.joined(separator: ",\n")
                + "\n" + closing + "}"
        }
    }

    /// Stringa JSON come la scrive Python con `ensure_ascii=False`: si escapano solo virgolette, barra e caratteri di controllo.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 { result += String(format: "\\u%04x", scalar.value) } else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }

    /// `repr(float)` di Python: la forma più corta che si rilegge uguale, con «.0» per gli interi
    /// (uguale a Swift tranne numeri enormi, che negli stati dell'app non ci sono).
    static func python(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity") }
        return "\(value)"
    }

    /// Formato `:g` di Python (6 cifre significative), usato nelle descrizioni delle ancore numeriche.
    static func general(_ value: Double) -> String { String(format: "%g", value) }

    // MARK: Lettura con l'ordine delle chiavi

    public static func parse(_ text: String) throws -> DecisionJSON {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        parser.skipSpaces()
        let value = try parser.value()
        parser.skipSpaces()
        guard parser.index == parser.scalars.count else { throw DecisionError.invalid("JSON: testo dopo la fine") }
        return value
    }

    public subscript(key: String) -> DecisionJSON? {
        guard case .object(let fields) = self else { return nil }
        return fields.first { $0.key == key }?.value
    }

    public var string: String? { if case .string(let text) = self { text } else { nil } }
    public var double: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var array: [DecisionJSON]? { if case .array(let items) = self { items } else { nil } }
    public var fields: [Field]? { if case .object(let fields) = self { fields } else { nil } }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func skipSpaces() {
            while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        mutating func expect(_ scalar: Unicode.Scalar) throws {
            skipSpaces()
            guard index < scalars.count, scalars[index] == scalar else { throw DecisionError.invalid("JSON: atteso «\(scalar)» alla posizione \(index)") }
            index += 1
        }

        mutating func value() throws -> DecisionJSON {
            skipSpaces()
            guard index < scalars.count else { throw DecisionError.invalid("JSON: fine inattesa") }
            switch scalars[index] {
            case "{":
                index += 1
                var fields: [Field] = []
                skipSpaces()
                if index < scalars.count, scalars[index] == "}" { index += 1; return .object(fields) }
                while true {
                    skipSpaces()
                    let key = try string()
                    try expect(":")
                    fields.append(Field(key, try value()))
                    skipSpaces()
                    guard index < scalars.count else { throw DecisionError.invalid("JSON: oggetto non chiuso") }
                    if scalars[index] == "," { index += 1; continue }
                    if scalars[index] == "}" { index += 1; return .object(fields) }
                    throw DecisionError.invalid("JSON: atteso «,» o «}» alla posizione \(index)")
                }
            case "[":
                index += 1
                var items: [DecisionJSON] = []
                skipSpaces()
                if index < scalars.count, scalars[index] == "]" { index += 1; return .array(items) }
                while true {
                    items.append(try value())
                    skipSpaces()
                    guard index < scalars.count else { throw DecisionError.invalid("JSON: elenco non chiuso") }
                    if scalars[index] == "," { index += 1; continue }
                    if scalars[index] == "]" { index += 1; return .array(items) }
                    throw DecisionError.invalid("JSON: atteso «,» o «]» alla posizione \(index)")
                }
            case "\"":
                return .string(try string())
            case "t":
                try word("true"); return .bool(true)
            case "f":
                try word("false"); return .bool(false)
            case "n":
                try word("null"); return .null
            default:
                return try number()
            }
        }

        mutating func word(_ text: String) throws {
            for scalar in text.unicodeScalars {
                guard index < scalars.count, scalars[index] == scalar else { throw DecisionError.invalid("JSON: parola non valida alla posizione \(index)") }
                index += 1
            }
        }

        mutating func number() throws -> DecisionJSON {
            let start = index
            var isInteger = true
            while index < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) {
                if [".", "e", "E"].contains(scalars[index]) { isInteger = false }
                index += 1
            }
            let text = String(String.UnicodeScalarView(scalars[start..<index]))
            if isInteger, let value = Int(text) { return .integer(value) }
            guard let value = Double(text) else { throw DecisionError.invalid("JSON: numero non valido «\(text)»") }
            return .number(value)
        }

        mutating func string() throws -> String {
            guard index < scalars.count, scalars[index] == "\"" else { throw DecisionError.invalid("JSON: attesa una stringa alla posizione \(index)") }
            index += 1
            var result = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                if scalar == "\"" { return String(result) }
                guard scalar == "\\" else { result.append(scalar); continue }
                guard index < scalars.count else { break }
                let escape = scalars[index]
                index += 1
                switch escape {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "u":
                    var code = try hex()
                    if (0xD800...0xDBFF).contains(code), index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                        index += 2
                        let low = try hex()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    if let decoded = Unicode.Scalar(code) { result.append(decoded) }
                default: result.append(escape)
                }
            }
            throw DecisionError.invalid("JSON: stringa non chiusa")
        }

        mutating func hex() throws -> UInt32 {
            guard index + 4 <= scalars.count, let code = UInt32(String(String.UnicodeScalarView(scalars[index..<index + 4])), radix: 16)
            else { throw DecisionError.invalid("JSON: \\u non valido") }
            index += 4
            return code
        }
    }
}
