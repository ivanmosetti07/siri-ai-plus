import Foundation

/// Riferimento a una cella, es. "B3" (colonna e riga partono da 0).
public struct CellRef: Hashable, Codable, Sendable, Comparable {
    public var col: Int
    public var row: Int

    public init(col: Int, row: Int) { self.col = col; self.row = row }

    public init?(_ name: String) {
        let upper = name.uppercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        let letters = upper.prefix { $0.isLetter }
        let digits = upper.dropFirst(letters.count)
        guard !letters.isEmpty, letters.count <= 2, let number = Int(digits), number >= 1,
              letters.allSatisfy({ $0.isASCII }) else { return nil }
        var col = 0
        for ch in letters { col = col * 26 + Int(ch.asciiValue! - 64) }
        self.col = col - 1
        row = number - 1
    }

    public static func columnName(_ col: Int) -> String {
        var n = col + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }

    public var name: String { Self.columnName(col) + String(row + 1) }

    public static func < (a: CellRef, b: CellRef) -> Bool { (a.row, a.col) < (b.row, b.col) }
}

public enum CellValue: Equatable, Sendable {
    case empty
    case number(Double)
    case text(String)
    case bool(Bool)
    case error(String)

    public var number: Double? {
        switch self {
        case .number(let n): n
        case .bool(let b): b ? 1 : 0
        case .empty: 0
        default: nil
        }
    }

    public var display: String {
        switch self {
        case .empty: ""
        case .number(let n): FormulaEngine.format(n)
        case .text(let t): t
        case .bool(let b): b ? Language.t("VERO", "TRUE") : Language.t("FALSO", "FALSE")
        case .error(let e): Language.isEnglish ? FormulaEngine.englishErrors[e] ?? e : e
        }
    }
}

/// Valutatore di formule stile Numbers/Excel in italiano e inglese:
/// SOMMA/SUM, MEDIA/AVERAGE, MIN, MAX, CONTA/COUNT, SE/IF, ARROTONDA/ROUND, ABS, operatori + - * / ^ & e confronti.
public enum FormulaEngine {
    /// Codici d'errore come li mostra Excel in inglese (dentro il motore restano quelli italiani).
    static let englishErrors = ["#VALORE": "#VALUE!", "#NOME?": "#NAME?", "#ERRORE": "#ERROR!", "#CICLO": "#CYCLE!", "#LIMITE": "#LIMIT!",
                                "#DIV/0": "#DIV/0!", "#NUM": "#NUM!"]

    /// Valore di una cella, date le formule/valori grezzi di tutte le celle (chiave "A1").
    public static func value(of ref: CellRef, in cells: [String: String]) -> CellValue {
        var visiting: Set<CellRef> = []
        return value(of: ref, cells: cells, visiting: &visiting)
    }

    public static func evaluate(_ raw: String, in cells: [String: String]) -> CellValue {
        var visiting: Set<CellRef> = []
        return evaluate(raw, cells: cells, visiting: &visiting)
    }

    static func value(of ref: CellRef, cells: [String: String], visiting: inout Set<CellRef>) -> CellValue {
        guard let raw = cells[ref.name], !raw.isEmpty else { return .empty }
        guard !visiting.contains(ref) else { return .error("#CICLO") }
        guard visiting.count < 256 else { return .error("#LIMITE") }
        visiting.insert(ref)
        defer { visiting.remove(ref) }
        return evaluate(raw, cells: cells, visiting: &visiting)
    }

    static func evaluate(_ raw: String, cells: [String: String], visiting: inout Set<CellRef>) -> CellValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("=") else { return literal(trimmed) }
        var parser = Parser(tokens: tokenize(String(trimmed.dropFirst())), cells: cells, visiting: visiting)
        let result = parser.parseExpression()
        visiting = parser.visiting
        if parser.invalid || parser.index < parser.tokens.count { return .error("#ERRORE") }
        return result
    }

    /// Numeri scritti a mano: "1.234,5", "1234.5", "12%", "€ 30"; in inglese anche "1,234.5", "1,500" (migliaia) e "$30".
    public static func literal(_ text: String) -> CellValue {
        if text.isEmpty { return .empty }
        var s = text.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: " ", with: "")
        let english = Language.isEnglish
        if english { s = s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: "£", with: "") }
        var percent = false
        if s.hasSuffix("%") { percent = true; s.removeLast() }
        if english, s.range(of: #"^[+-]?\d{1,3}(?:,\d{3})+(?:\.\d+)?$"#, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: ",", with: "")
        } else if s.contains(",") { s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
        if let n = Double(s) { return .number(percent ? n / 100 : n) }
        switch text.uppercased() {
        case "VERO", "TRUE": return .bool(true)
        case "FALSO", "FALSE": return .bool(false)
        default: return .text(text)
        }
    }

    /// Numero nel formato della lingua in uso: "1234,5" in italiano, "1,234.5" in inglese.
    public static func format(_ n: Double) -> String {
        if n.isNaN || n.isInfinite { return Language.isEnglish ? "#NUM!" : "#NUM" }
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2)).locale(Language.current.locale)
        return n.formatted(style)
    }

    // MARK: Tokenizzazione

    enum Token: Equatable {
        case number(Double), string(String), name(String), range(String, String)
        case op(String), lparen, rparen, separator
    }

    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                if let number = Double(String(chars[i..<j])), number.isFinite { tokens.append(.number(number)) }
                else { tokens.append(.op("#ERRORE")) }
                i = j
                if i < chars.count, chars[i] == "%" { if case .number(let n) = tokens.removeLast() { tokens.append(.number(n / 100)) }; i += 1 }
                continue
            }
            if c.isLetter || c == "$" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "$" || chars[j] == "." || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                if j < chars.count, chars[j] == ":" {
                    var k = j + 1
                    while k < chars.count, chars[k].isLetter || chars[k].isNumber || chars[k] == "$" { k += 1 }
                    tokens.append(.range(word, String(chars[(j + 1)..<k])))
                    i = k
                } else {
                    tokens.append(.name(word))
                    i = j
                }
                continue
            }
            if c == "\"" {
                var j = i + 1
                while j < chars.count, chars[j] != "\"" { j += 1 }
                if j < chars.count { tokens.append(.string(String(chars[(i + 1)..<j]))) }
                else { tokens.append(.op("#ERRORE")) }
                i = j + 1
                continue
            }
            switch c {
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case ";", ",": tokens.append(.separator)
            case "<", ">":
                if i + 1 < chars.count, chars[i + 1] == "=" || (c == "<" && chars[i + 1] == ">") {
                    tokens.append(.op(String([c, chars[i + 1]]))); i += 1
                } else { tokens.append(.op(String(c))) }
            default: tokens.append(.op(String(c)))
            }
            i += 1
        }
        return tokens
    }

    // MARK: Parser a discesa ricorsiva

    struct Parser {
        let tokens: [Token]
        let cells: [String: String]
        var visiting: Set<CellRef>
        var index = 0
        var invalid = false

        init(tokens: [Token], cells: [String: String], visiting: Set<CellRef>) {
            self.tokens = tokens; self.cells = cells; self.visiting = visiting
        }

        var peek: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func parseExpression() -> CellValue {
            let left = parseConcat()
            if case .op(let o)? = peek, ["=", "<", ">", "<=", ">=", "<>"].contains(o) {
                index += 1
                let right = parseConcat()
                if case .error = left { return left }
                if case .error = right { return right }
                if let a = left.number, let b = right.number, !isText(left), !isText(right) {
                    return .bool(compare(a, b, o))
                }
                let a = left.display.lowercased(), b = right.display.lowercased()
                switch o {
                case "=": return .bool(a == b)
                case "<>": return .bool(a != b)
                case "<": return .bool(a < b)
                case ">": return .bool(a > b)
                case "<=": return .bool(a <= b)
                default: return .bool(a >= b)
                }
            }
            return left
        }

        func isText(_ v: CellValue) -> Bool { if case .text = v { return true }; return false }

        func compare(_ a: Double, _ b: Double, _ o: String) -> Bool {
            switch o {
            case "=": a == b
            case "<>": a != b
            case "<": a < b
            case ">": a > b
            case "<=": a <= b
            default: a >= b
            }
        }

        mutating func parseConcat() -> CellValue {
            var left = parseAdditive()
            while case .op("&")? = peek {
                index += 1
                let right = parseAdditive()
                left = .text(left.display + right.display)
            }
            return left
        }

        mutating func parseAdditive() -> CellValue {
            var left = parseTerm()
            while case .op(let o)? = peek, o == "+" || o == "-" {
                index += 1
                let right = parseTerm()
                guard let a = left.number, let b = right.number else { return firstError(left, right) ?? .error("#VALORE") }
                left = .number(o == "+" ? a + b : a - b)
            }
            return left
        }

        mutating func parseTerm() -> CellValue {
            var left = parsePower()
            while case .op(let o)? = peek, o == "*" || o == "/" {
                index += 1
                let right = parsePower()
                guard let a = left.number, let b = right.number else { return firstError(left, right) ?? .error("#VALORE") }
                if o == "/" && b == 0 { return .error("#DIV/0") }
                left = .number(o == "*" ? a * b : a / b)
            }
            return left
        }

        mutating func parsePower() -> CellValue {
            let base = parseUnary()
            if case .op("^")? = peek {
                index += 1
                let exp = parsePower()
                guard let a = base.number, let b = exp.number else { return .error("#VALORE") }
                return .number(pow(a, b))
            }
            return base
        }

        mutating func parseUnary() -> CellValue {
            if case .op("-")? = peek {
                index += 1
                let v = parseUnary()
                guard let n = v.number else { return .error("#VALORE") }
                return .number(-n)
            }
            if case .op("+")? = peek { index += 1 }
            return parsePrimary()
        }

        func firstError(_ values: CellValue...) -> CellValue? {
            values.first { if case .error = $0 { true } else { false } }
        }

        mutating func parsePrimary() -> CellValue {
            guard let token = peek else { return .error("#ERRORE") }
            index += 1
            switch token {
            case .number(let n): return .number(n)
            case .string(let s): return .text(s)
            case .lparen:
                let v = parseExpression()
                guard case .rparen? = peek else { invalid = true; return .error("#ERRORE") }
                index += 1
                return v
            case .range: return .error("#VALORE")
            case .name(let name):
                if case .lparen? = peek {
                    index += 1
                    return callFunction(name.uppercased())
                }
                if let ref = CellRef(name) { return FormulaEngine.value(of: ref, cells: cells, visiting: &visiting) }
                switch name.uppercased() {
                case "VERO", "TRUE": return .bool(true)
                case "FALSO", "FALSE": return .bool(false)
                default: return .error("#NOME?")
                }
            default: return .error("#ERRORE")
            }
        }

        /// Argomenti come liste di valori (gli intervalli si espandono).
        mutating func arguments() -> [[CellValue]] {
            var args: [[CellValue]] = []
            if case .rparen? = peek { index += 1; return args }
            while index < tokens.count {
                if case .range(let a, let b)? = peek, let from = CellRef(a), let to = CellRef(b) {
                    index += 1
                    let rows = max(from.row, to.row) - min(from.row, to.row) + 1
                    let cols = max(from.col, to.col) - min(from.col, to.col) + 1
                    guard rows <= 100_000 / cols else { invalid = true; return [[.error("#LIMITE")]] }
                    var values: [CellValue] = []
                    for row in min(from.row, to.row)...max(from.row, to.row) {
                        for col in min(from.col, to.col)...max(from.col, to.col) {
                            values.append(FormulaEngine.value(of: CellRef(col: col, row: row), cells: cells, visiting: &visiting))
                        }
                    }
                    args.append(values)
                } else {
                    args.append([parseExpression()])
                }
                if case .separator? = peek { index += 1; continue }
                if case .rparen? = peek { index += 1; return args }
                invalid = true
                break
            }
            invalid = true
            return args
        }

        mutating func callFunction(_ name: String) -> CellValue {
            if name == "SE" || name == "IF" {
                let args = arguments()
                guard let condition = args.first?.first else { return .error("#VALORE") }
                if case .error = condition { return condition }
                let truthy = condition.number.map { $0 != 0 } ?? false
                let pick = truthy ? 1 : 2
                return args.count > pick ? (args[pick].first ?? .empty) : .bool(truthy)
            }
            let args = arguments()
            let flat = args.flatMap { $0 }
            if let error = flat.first(where: { if case .error = $0 { true } else { false } }) { return error }
            let numbers = flat.compactMap { v -> Double? in if case .number(let n) = v { n } else if case .bool(let b) = v { b ? 1 : 0 } else { nil } }
            switch name {
            case "SOMMA", "SUM": return .number(numbers.reduce(0, +))
            case "MEDIA", "AVERAGE": return numbers.isEmpty ? .error("#DIV/0") : .number(numbers.reduce(0, +) / Double(numbers.count))
            case "MIN": return .number(numbers.min() ?? 0)
            case "MAX": return .number(numbers.max() ?? 0)
            case "CONTA", "COUNT", "CONTA.NUMERI": return .number(Double(numbers.count))
            case "CONTA.VALORI", "COUNTA": return .number(Double(flat.filter { $0 != .empty }.count))
            case "ABS": return numbers.first.map { .number(abs($0)) } ?? .error("#VALORE")
            case "ARROTONDA", "ROUND":
                guard let value = numbers.first else { return .error("#VALORE") }
                let digits = numbers.count > 1 ? numbers[1] : 0
                let factor = pow(10, digits)
                return .number((value * factor).rounded() / factor)
            case "PRODOTTO", "PRODUCT": return .number(numbers.reduce(1, *))
            default: return .error("#NOME?")
            }
        }
    }
}
