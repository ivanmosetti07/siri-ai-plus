import Foundation

// MARK: - rizzo-pii in Swift: testo, entità e rete regex + checksum
//
// Porting di `src/app/detectors.py` di rizzo-pii (Rizzo AI Academy, licenza MIT). Le posizioni sono in code point,
// come le stringhe di Python: così i risultati coincidono con l'originale (vedi `PIIParityTests`).

/// Testo indicizzato per caratteri Unicode (code point), come una stringa di Python.
struct PIIText {
    let string: String
    let scalars: [Unicode.Scalar]
    /// Da offset UTF-16 (NSRegularExpression) a indice di code point.
    private let fromUTF16: [Int]

    init(_ string: String) {
        self.string = string
        scalars = Array(string.unicodeScalars)
        var map: [Int] = []
        map.reserveCapacity(string.utf16.count + 1)
        for (index, scalar) in scalars.enumerated() {
            map.append(index)
            if scalar.utf16.count == 2 { map.append(index) }
        }
        map.append(scalars.count)
        fromUTF16 = map
    }

    var count: Int { scalars.count }

    subscript(index: Int) -> Unicode.Scalar { scalars[index] }

    func slice(_ start: Int, _ end: Int) -> String {
        guard start < end else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[max(0, start)..<min(end, scalars.count)])
        return String(view)
    }

    /// Match di un'espressione regolare, con le posizioni in code point.
    func matches(_ regex: NSRegularExpression) -> [(start: Int, end: Int)] {
        regex.matches(in: string, range: NSRange(location: 0, length: string.utf16.count)).map {
            (fromUTF16[$0.range.location], fromUTF16[$0.range.location + $0.range.length])
        }
    }
}

extension Unicode.Scalar {
    /// `str.isspace()` di Python.
    var pyIsSpace: Bool { properties.isWhitespace || (0x1C...0x1F).contains(value) }

    /// `str.isalnum()` di Python: lettere (categorie L*) o caratteri numerici.
    var pyIsAlnum: Bool {
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return properties.numericType != nil
        }
    }

    var pyIsDigit: Bool { properties.numericType == .decimal || properties.numericType == .digit }

    /// Carattere interno a una parola (`_is_word` di app.py).
    var isWordCharacter: Bool { pyIsAlnum || self == "_" }

    var isASCIIAlnum: Bool { isASCII && (("0"..."9").contains(self) || ("A"..."Z").contains(self) || ("a"..."z").contains(self)) }
}

/// Un dato personale trovato nel testo (posizioni in code point).
public struct PIIEntity: Sendable, Equatable {
    public enum Source: String, Sendable { case model = "modello", regex }
    public var label: String
    public var start: Int
    public var end: Int
    public var score: Double
    public var validated: Bool
    public var source: Source
}

/// Le 23 categorie di rizzo-pii, con il nome italiano.
public enum PIICategory {
    public static let names: [String: String] = [
        "FULLNAME": "nomi", "AGE": "età", "GENDER": "generi", "DATE": "date", "TIME": "orari", "STREET": "indirizzi", "BUILDINGNUM": "numeri civici",
        "ZIPCODE": "CAP", "CITY": "città", "PROVINCE": "province", "EMAIL": "email", "TELEPHONENUM": "telefoni", "CF": "codici fiscali",
        "PIVA": "partite IVA", "ID_DOC": "documenti", "IBAN": "IBAN", "CREDITCARDNUMBER": "carte", "AMOUNT": "importi", "TARGA": "targhe",
        "ORG": "aziende", "DOCID": "codici di atti", "CATASTO": "dati catastali", "URL": "indirizzi web", "IPADDR": "indirizzi IP",
    ]

    public static func name(_ label: String) -> String { names[label] ?? label.lowercased() }

    /// Dati che dicono chi è una persona o danno accesso a un suo conto: sono questi che si nascondono a ChatGPT e Claude.
    /// All'AI il valore vero non serve, le basta ricopiare il segnaposto dove va.
    public static let sensitive = ["FULLNAME", "EMAIL", "TELEPHONENUM", "CF", "PIVA", "ID_DOC", "IBAN", "CREDITCARDNUMBER",
                                   "STREET", "BUILDINGNUM", "TARGA", "CATASTO", "DOCID", "IPADDR"]
    /// Dati con cui l'AI lavora (conti, scadenze, orari, luoghi, aziende, siti): restano in chiaro, a meno di sceglierli
    /// nelle Impostazioni.
    public static let workingData = ["AMOUNT", "DATE", "TIME", "AGE", "GENDER", "CITY", "PROVINCE", "ZIPCODE", "ORG", "URL"]
}

enum PIIDetectors {
    // MARK: Checksum

    static func ibanOK(_ value: String) -> Bool {
        let compact = value.unicodeScalars.filter { !($0.pyIsSpace || $0 == "." || $0 == "-") }.map(Character.init)
        let s = String(compact).uppercased()
        guard (15...34).contains(s.count) else { return false }
        let rotated = Array(s.dropFirst(4) + s.prefix(4))
        var remainder = 0
        for character in rotated {
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
            if scalar.properties.isAlphabetic {
                // ord(c) - 55: «A» vale 10 (anche per le lettere non latine, come in Python, che poi non passano il conto)
                let number = Int(scalar.value) - 55
                guard number >= 0 else { return false }
                for digit in String(number) { remainder = (remainder * 10 + Int(String(digit))!) % 97 }
            } else if let digit = Int(String(character)), scalar.pyIsDigit {
                remainder = (remainder * 10 + digit) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    static func pivaOK(_ value: String) -> Bool {
        let digits = value.unicodeScalars.filter(\.pyIsDigit).compactMap { Int(String($0)) }
        guard digits.count == 11 else { return false }
        var total = 0
        for (index, digit) in digits.prefix(10).enumerated() {
            if index % 2 == 0 {
                total += digit
            } else {
                let doubled = digit * 2
                total += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return (10 - total % 10) % 10 == digits[10]
    }

    private static let cfOdd: [Character: Int] = [
        "0": 1, "1": 0, "2": 5, "3": 7, "4": 9, "5": 13, "6": 15, "7": 17, "8": 19, "9": 21, "A": 1, "B": 0, "C": 5, "D": 7, "E": 9,
        "F": 13, "G": 15, "H": 17, "I": 19, "J": 21, "K": 2, "L": 4, "M": 18, "N": 20, "O": 11, "P": 3, "Q": 6, "R": 8, "S": 12,
        "T": 14, "U": 16, "V": 10, "W": 22, "X": 25, "Y": 24, "Z": 23,
    ]

    static func cfOK(_ value: String) -> Bool {
        let c = Array(value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        guard c.count == 16, c.allSatisfy({ $0.unicodeScalars.allSatisfy(\.pyIsAlnum) }) else { return false }
        var total = 0
        for (index, character) in c.prefix(15).enumerated() {
            if index % 2 == 0 {
                guard let value = cfOdd[character] else { return false }
                total += value
            } else if let digit = character.wholeNumberValue, character.isASCII {
                total += digit
            } else if let ascii = character.asciiValue {
                total += Int(ascii) - 65
            } else {
                return false
            }
        }
        return Character(Unicode.Scalar(UInt8(65 + (total % 26 + 26) % 26))) == c[15]
    }

    static func luhnOK(_ value: String) -> Bool {
        let digits = value.unicodeScalars.filter(\.pyIsDigit).compactMap { Int(String($0)) }
        guard (13...19).contains(digits.count) else { return false }
        var total = 0
        var alternate = false
        for digit in digits.reversed() {
            var n = digit
            if alternate {
                n *= 2
                if n > 9 { n -= 9 }
            }
            total += n
            alternate.toggle()
        }
        return total % 10 == 0
    }

    // MARK: Rete regex

    private struct Detector: Sendable {
        let label: String
        let regex: NSRegularExpression
        let validator: (@Sendable (String) -> Bool)?
        let strict: Bool
    }

    private static func rx(_ pattern: String, ignoreCase: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    private static let detectors: [Detector] = [
        Detector(label: "EMAIL", regex: rx(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#), validator: nil, strict: true),
        Detector(label: "CF", regex: rx(#"\b[A-Za-z]{6}\d{2}[A-Za-z]\d{2}[A-Za-z]\d{3}[A-Za-z]\b"#), validator: cfOK, strict: false),
        Detector(label: "CF", regex: rx(#"\b[A-Za-z]{6}[\dLMNPQRSTUVlmnpqrstuv]{2}[A-Za-z][\dLMNPQRSTUVlmnpqrstuv]{2}[A-Za-z][\dLMNPQRSTUVlmnpqrstuv]{3}[A-Za-z]\b"#),
                 validator: cfOK, strict: true),
        Detector(label: "IBAN", regex: rx(#"\b[A-Za-z]{2}\d{2}[A-Za-z0-9]{11,30}\b"#), validator: ibanOK, strict: true),
        Detector(label: "CREDITCARDNUMBER", regex: rx(#"(?<!\d)\d(?:[ .\-]?\d){12,18}(?!\d)"#), validator: luhnOK, strict: true),
        Detector(label: "PIVA", regex: rx(#"(?<!\d)\d{11}(?!\d)"#), validator: pivaOK, strict: true),
        Detector(label: "TELEPHONENUM", regex: rx(#"(?<![\w.])(?:\+39[\s.\-]?)?(?:3\d{2}[\s.\-]?\d{3}[\s.\-]?\d{3,4}|0\d{1,3}[\s.\-]?\d{5,8})(?![\w])"#),
                 validator: nil, strict: true),
        Detector(label: "AMOUNT", regex: rx(#"(?:€|EUR|euro)\s?\d{1,3}(?:[.\s]\d{3})*(?:,\d{2})?|\d{1,3}(?:\.\d{3})*,\d{2}\s?(?:€|EUR|euro)"#, ignoreCase: true),
                 validator: nil, strict: true),
        Detector(label: "TARGA", regex: rx(#"\b[A-Za-z]{2}[\s-]?\d{3}[\s-]?[A-Za-z]{2}\b"#), validator: nil, strict: true),
        Detector(label: "URL", regex: rx(#"(?:https?|ftp)://[^\s<>"']+|www\.[A-Za-z0-9\-._~%]+\.[A-Za-z]{2,}(?:/[^\s<>"']*)?|\b(?:[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?\.)+(?:it|com|net|org|eu|info|io|dev|app|gov|edu|cloud|online|site|blog)\b(?:/[^\s<>"']*)?"#, ignoreCase: true),
                 validator: nil, strict: true),
        Detector(label: "IPADDR", regex: rx(#"\b(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}(?:/(?:3[0-2]|[12]?\d))?(?:\s*-\s*(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})?\b"#),
                 validator: nil, strict: true),
        Detector(label: "DOCID", regex: rx(#"\b(?:R\.?G\.?\s*N\.?R\.?|R\.?G\.?|RG|Prot\.?|protocollo|Rep\.?|repertorio)(?:\s*(?:n\.?|num\.?|nro\.?))?\s*\d{1,8}(?:[/\-]\d{2,4})?\b"#, ignoreCase: true),
                 validator: nil, strict: true),
        Detector(label: "DATE", regex: rx(#"(?<!\d)(?:0?[1-9]|[12]\d|3[01])[/.\-](?:0?[1-9]|1[0-2])[/.\-](?:19|20)\d{2}(?:\s+\d{1,2}[.:]\d{2})?(?!\d)"#),
                 validator: nil, strict: true),
    ]

    /// Etichette della rete regex senza un checksum a confermarle: il modello può sovrascriverle.
    static let softRegexLabels: Set<String> = ["DATE"]

    private static let urlTrail: Set<Unicode.Scalar> = Set(".,;:!?)]}»\"'".unicodeScalars)

    // MARK: IBAN a gruppi

    static let ibanLength: [String: Int] = {
        let list = "AD24 AE23 AL28 AT20 AZ28 BA20 BE16 BG22 BH22 BI27 BR29 BY28 CH21 CR22 CY28 CZ24 DE22 DJ27 DK18 DO28 EE20 EG29 ES24 FI18 FK18 FO18 FR27 GB22 GE22 GI23 GL18 GR27 GT28 HN28 HR21 HU28 IE22 IL23 IQ23 IS26 IT27 JO30 KW30 KZ20 LB28 LC32 LI21 LT20 LU20 LV21 LY25 MC27 MD24 ME22 MK19 MN20 MR27 MT31 MU30 NI28 NL18 NO15 OM23 PK24 PL28 PS29 PT25 QA29 RO24 RS22 RU33 SA24 SC31 SD18 SE24 SI19 SK24 SM27 SO23 ST25 SV28 TL23 TN24 TR26 UA29 VA22 VG24 XK20 YE30"
        return Dictionary(uniqueKeysWithValues: list.split(separator: " ").map { (String($0.prefix(2)), Int($0.dropFirst(2))!) })
    }()

    private static let ibanHead = rx(#"(?<![A-Za-z0-9])[A-Za-z]{2}\d{2}"#)
    private static let ibanMaxSeparators = 3
    private static let ibanRun = 5

    /// IBAN stampato a gruppi («IT60 X054 2811 …»): dalla sigla del paese si consumano esattamente i caratteri previsti.
    static func detectIBAN(_ text: PIIText) -> [PIIEntity] {
        var entities: [PIIEntity] = []
        for match in text.matches(ibanHead) {
            let head = text.slice(match.start, match.start + 2).uppercased()
            guard let expected = ibanLength[head] else { continue }
            var i = match.start
            if i > 0, text[i - 1].pyIsAlnum { continue }
            let start = i
            var chars = 0, separators = 0, run = 0, newlines = 0
            var grouped = false
            while i < text.count, chars < expected {
                let c = text[i]
                if c.isASCIIAlnum {
                    chars += 1
                    run += 1
                    separators = 0
                } else if separators < ibanMaxSeparators, run <= ibanRun, c == "." || c == "-" || c.pyIsSpace {
                    separators += 1
                    run = 0
                    grouped = true
                    if c.pyIsSpace, c != " ", c != "\t", c != "\u{a0}" { newlines += 1 }
                    if newlines > 1 { break }
                } else {
                    break
                }
                i += 1
            }
            if chars < expected || (i < text.count && text[i].isASCIIAlnum) { continue }
            let value = text.slice(start, i)
            if grouped {
                let groups = value.unicodeScalars.split { $0.pyIsSpace || $0 == "." || $0 == "-" }.map(\.count)
                guard let first = groups.first, let last = groups.last else { continue }
                if Set(groups.dropLast()).count > 1 || last > first { continue }
            }
            if ibanOK(value) {
                entities.append(PIIEntity(label: "IBAN", start: start, end: i, score: 1, validated: true, source: .regex))
            }
        }
        // Due candidati sovrapposti: si maschera l'unione.
        entities.sort { $0.start < $1.start }
        if entities.count > 1 {
            for index in 0..<(entities.count - 1) where entities[index + 1].start < entities[index].end {
                entities[index + 1].start = entities[index].start
                entities[index + 1].end = max(entities[index].end, entities[index + 1].end)
                entities[index].end = entities[index].start
            }
        }
        return entities.filter { $0.end > $0.start }
    }

    // MARK: Carta con la scadenza attaccata

    private static let cardLengths = [19, 18, 17, 16, 15, 14, 13]

    private static func looksLikeExpiry(_ tail: String) -> Bool {
        guard (2...4).contains(tail.count), let month = Int(tail.prefix(2)) else { return false }
        return (1...12).contains(month)
    }

    /// «4111 1111 1111 1111 12/26»: si riprova tagliando la scadenza, solo su un separatore e con un mese plausibile.
    private static func cardWithoutExpiry(_ text: PIIText, start: Int, end: Int) -> (end: Int, ok: Bool) {
        let s = Array(text.scalars[start..<end])
        let digits = s.indices.filter { s[$0].pyIsDigit }
        for length in cardLengths {
            let extra = digits.count - length
            guard extra > 0, extra <= 4 else { continue }
            let cut = digits[length - 1] + 1
            guard cut < s.count, s[cut] == " " || s[cut] == "." || s[cut] == "-" else { continue }
            var tail = String.UnicodeScalarView()
            tail.append(contentsOf: s[cut...].filter(\.pyIsDigit))
            var head = String.UnicodeScalarView()
            head.append(contentsOf: s[..<cut])
            if looksLikeExpiry(String(tail)), luhnOK(String(head)) { return (start + cut, true) }
        }
        return (end, false)
    }

    /// Entità della rete regex. `validated` solo quando il checksum passa.
    static func detect(_ text: PIIText) -> [PIIEntity] {
        var entities = detectIBAN(text)
        for detector in detectors {
            for match in text.matches(detector.regex) {
                var end = match.end
                if detector.label == "URL" {
                    while end > match.start, urlTrail.contains(text[end - 1]) { end -= 1 }
                    if end <= match.start { continue }
                }
                var ok = detector.validator.map { $0(text.slice(match.start, match.end)) } ?? false
                if !ok, detector.label == "CREDITCARDNUMBER" {
                    (end, ok) = cardWithoutExpiry(text, start: match.start, end: end)
                }
                if detector.validator != nil, detector.strict, !ok { continue }
                entities.append(PIIEntity(label: detector.label, start: match.start, end: end, score: ok ? 1 : 0.9,
                                          validated: ok, source: .regex))
            }
        }
        return entities
    }

    // MARK: Ore

    private static let timeRegex = rx(#"(?<!\d)(?<!\d[.:])(?:[01]?\d|2[0-3])[.:][0-5]\d(?:[.:][0-5]\d)?(?!\d)(?![.:]\d)"#)

    /// Estende le ore trovate dal modello all'ora intera («18[TIME_1]28» → «[TIME_1]»). Solo allargamenti.
    static func completeTime(_ entities: inout [PIIEntity], in text: PIIText) {
        guard entities.contains(where: { $0.label == "TIME" }) else { return }
        let spans = text.matches(timeRegex)
        for index in entities.indices where entities[index].label == "TIME" {
            var j = (spans.lastIndex { $0.start < entities[index].end }) ?? -1
            while j >= 0, spans[j].end > entities[index].start {
                entities[index].start = min(entities[index].start, spans[j].start)
                entities[index].end = max(entities[index].end, spans[j].end)
                j -= 1
            }
        }
    }
}
