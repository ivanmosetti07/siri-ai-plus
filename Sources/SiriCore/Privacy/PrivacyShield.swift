import Foundation

// MARK: - Lo scudo della conversazione: niente dati veri a ChatGPT e Claude
//
// Tutto ciò che va ai modelli esterni (istruzioni, memoria, cronologia, richiesta, file, email, risultati degli strumenti)
// passa da `protect` e arriva con i segnaposto; ciò che torna passa da `reveal` e torna leggibile. Il dizionario è della
// conversazione e resta sul Mac. `current` accompagna la richiesta (anche i sub-agent e chi scrive i testi):
// `ExternalAgent.codex` e `ExternalAgent.claude` lo applicano da soli.

/// Quanto è stato anonimizzato per una richiesta: per l'avviso in chat.
public struct PrivacyReport: Codable, Sendable, Equatable {
    public var destination: String
    /// Segnaposto usati nei testi inviati, per categoria.
    public var counts: [String: Int]
    public var placeholders: [String]
    /// Segnaposto → valore vero, solo per mostrarli sul Mac (nella scheda della chat).
    public var values: [String: String] = [:]

    public var total: Int { counts.values.reduce(0, +) }

    /// «3 nomi, 2 codici fiscali, 1 IBAN».
    public var summary: String {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.value) \(PIICategory.name($0.key, count: $0.value))" }.joined(separator: ", ")
    }
}

public final class PrivacyShield: @unchecked Sendable {
    /// Lo scudo della richiesta in corso.
    @TaskLocal public static var current: PrivacyShield?

    /// Detto al modello esterno prima delle istruzioni: i segnaposto sono dati veri, da usare così.
    public static var modelRule: String { Language.isEnglish ? englishModelRule : italianModelRule }

    static let englishModelRule = """
    Privacy: some personal data reach you as placeholders in square brackets, for example [FULLNAME_1], [EMAIL_1], [IBAN_1], \
    [CF_1]. They are real data that the app hid for privacy and puts back in place in your answer and in the tools: use them \
    exactly as you receive them, as if they were the real values (also inside tools and in texts to write). Don't ask for the real \
    data, don't treat them as fields to fill in, don't explain that they are placeholders and don't change their form.
    """

    static let italianModelRule = """
    Privacy: alcuni dati personali ti arrivano come segnaposto tra parentesi quadre, per esempio [FULLNAME_1], [EMAIL_1], [IBAN_1], \
    [CF_1]. Sono dati veri che l'app ha nascosto per privacy e che rimette al loro posto nella tua risposta e negli strumenti: usali \
    esattamente come li ricevi, come se fossero i valori veri (anche dentro gli strumenti e nei testi da scrivere). Non chiedere i dati \
    reali, non trattarli come campi da compilare, non spiegare che sono segnaposto e non cambiarne la forma.
    """

    /// «Claude», «ChatGPT»: a chi si sta per inviare (per l'avviso).
    public let destination: String
    private let lock = NSLock()
    private var vault: PIIVault
    /// Testo originale → testo anonimizzato (istruzioni e cronologia non si rianalizzano a ogni richiesta).
    private var cache: [String: String] = [:]
    private var used: Set<String> = []
    /// Il dizionario è cambiato: la chat lo salva.
    public var onVaultChange: (@Sendable (PIIVault) -> Void)?
    /// Cosa sta facendo, per la riga di stato («Anonimizzo prima di inviare a Claude…»).
    public var onStatus: (@Sendable (String) -> Void)?

    /// Categorie che diventano segnaposto: di serie solo i dati personali (`PIICategory.sensitive`). Importi, date, orari,
    /// luoghi e aziende restano in chiaro, altrimenti l'AI non può fare conti, confronti e ricerche.
    public let labels: Set<String>

    /// La chat dei testi: con lei la cache dei paragrafi vale per tutta la conversazione, non solo per una richiesta
    /// (istruzioni, cronologia, memoria e file non si rianalizzano a ogni messaggio).
    private let memoryKey: String?

    public init(vault: PIIVault, destination: String, labels: Set<String> = Set(PIICategory.sensitive), chat: UUID? = nil) {
        self.vault = vault
        self.destination = destination
        self.labels = labels
        memoryKey = chat.map { $0.uuidString + "|" + labels.sorted().joined(separator: ",") + "|" }
    }

    public var currentVault: PIIVault { lock.withLock { vault } }

    // MARK: Verso il modello

    /// Anonimizza un testo. I testi lunghi si trattano per paragrafi, ognuno con la sua cache: quando cambia solo
    /// una riga (l'ora nelle istruzioni, un messaggio nuovo) si rianalizza solo quella.
    public func protect(_ text: String) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        // Testi lunghi: rizzo-flow decide se serve rizzo-pii (vedi `PrivacyGate`). Se no, restano formati, checksum e nomi noti.
        if text.count >= PrivacyGate.threshold {
            if let memoryKey, let entry = ShieldMemory.shared.entry(memoryKey + "gate|" + text),
               lock.withLock({ entry.values.allSatisfy { vault.values[$0.key] == $0.value } }) {
                note(Self.placeholders(in: entry.output))
                return entry.output
            }
            if await PrivacyGate.canSkipModel(text) {
                let output = formatsOnly(text)
                remember("gate|" + text, output)
                return output
            }
        }
        var output = ""
        for part in Self.paragraphs(text) {
            output += try await protectParagraph(part)
        }
        return output
    }

    /// Senza il modello di rizzo-pii: solo i dati riconoscibili dal formato (email, telefoni, IBAN, codici fiscali, carte, con i
    /// controlli di checksum) e i valori che la chat ha già nascosto.
    private func formatsOnly(_ text: String) -> String {
        let source = PIIText(text)
        let (output, changed) = substitute(Self.masked(PIIDetectors.detect(source), in: source, labels: labels), in: source)
        if changed { onVaultChange?(currentVault) }
        return mask(output)
    }

    /// I segnaposto al posto delle entità, con il dizionario della chat (sotto lock: due passi in parallelo non danno lo stesso
    /// segnaposto a due dati diversi).
    private func substitute(_ entities: [PIIEntity], in source: PIIText) -> (String, Bool) {
        lock.withLock { () -> (String, Bool) in
            var result = ""
            var position = 0
            var changed = false
            for entity in entities {
                result += source.slice(position, entity.start)
                let (placeholder, isNew) = vault.placeholder(label: entity.label, value: source.slice(entity.start, entity.end))
                changed = changed || isNew
                used.insert(placeholder)
                result += placeholder
                position = entity.end
            }
            result += source.slice(position, source.count)
            return (result, changed)
        }
    }

    /// Istruzioni, cronologia e richiesta insieme.
    public func protect(system: String, history: [ChatTurn], prompt: String) async throws -> (String, [ChatTurn], String) {
        let safeSystem = try await protect(system)
        var safeHistory: [ChatTurn] = []
        for turn in history { safeHistory.append(ChatTurn(role: turn.role, text: try await protect(turn.text))) }
        return (safeSystem, safeHistory, try await protect(prompt))
    }

    private func protectParagraph(_ text: String) async throws -> String {
        // L'ora e il mini-calendario cambiano a ogni minuto: restano in chiaro e fuori dalla cache, il resto del paragrafo
        // (le istruzioni intorno) si riusa. Prima l'ora nel primo paragrafo faceva rianalizzare tutto a ogni messaggio.
        let pieces = Self.changingLines(text)
        guard pieces.count > 1 else { return try await protectPiece(text) }
        var output = ""
        for piece in pieces { output += piece.changing ? piece.text : try await protectPiece(piece.text) }
        return output
    }

    private func protectPiece(_ text: String) async throws -> String {
        if let cached = lock.withLock({ cache[text] }) {
            note(Self.placeholders(in: cached))
            return cached
        }
        // Già anonimizzato in una richiesta precedente della stessa chat, con segnaposto che il dizionario ha ancora.
        if let memoryKey, let entry = ShieldMemory.shared.entry(memoryKey + text),
           lock.withLock({ entry.values.allSatisfy { vault.values[$0.key] == $0.value } }) {
            lock.withLock { cache[text] = entry.output }
            note(Self.placeholders(in: entry.output))
            return entry.output
        }
        guard text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else { return text }
        onStatus?(Language.t("Anonimizzo prima di inviare a \(destination)…", "Anonymizing before sending to \(destination)…"))
        let source = PIIText(text)
        // La data e l'ora di adesso, scritte dall'app, non sono dati personali: senza, il modello non sa cos'è «domani».
        let kept = Self.scaffolding.flatMap { source.matches($0) }
        let found = try await PIIEngine.shared.entities(in: text).filter { entity in
            !kept.contains { $0.start < entity.end && entity.start < $0.end }
        }
        let entities = Self.masked(found, in: source, labels: labels)
        let (output, changed) = substitute(entities, in: source)
        lock.withLock { cache[text] = output }
        remember(text, output)
        if changed { onVaultChange?(currentVault) }
        return output
    }

    /// Nella cache della chat, con i valori dei segnaposto usati: se il dizionario cambia, la voce non vale più.
    private func remember(_ original: String, _ output: String) {
        guard let memoryKey else { return }
        let values = lock.withLock { () -> [String: String] in
            Dictionary(Self.placeholders(in: output).compactMap { key in vault.values[key].map { (key, $0) } }, uniquingKeysWith: { first, _ in first })
        }
        ShieldMemory.shared.store(memoryKey + original, .init(output: output, values: values))
    }

    /// Righe che cambiano da sola a sola (ora, mini-calendario) separate dal resto; riunite danno il testo di partenza.
    static func changingLines(_ text: String) -> [(text: String, changing: Bool)] {
        let ns = text as NSString
        let ranges = scaffolding.prefix(2).flatMap { $0.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range) }
            .sorted { $0.location < $1.location }
        guard !ranges.isEmpty else { return [(text, false)] }
        var pieces: [(text: String, changing: Bool)] = []
        var position = 0
        for range in ranges where range.location >= position {
            if range.location > position { pieces.append((ns.substring(with: NSRange(location: position, length: range.location - position)), false)) }
            pieces.append((ns.substring(with: range), true))
            position = range.location + range.length
        }
        if position < ns.length { pieces.append((ns.substring(from: position), false)) }
        return pieces
    }

    /// Righe di contesto scritte dall'app che restano in chiaro: «Adesso è gio 2026-09-25 13:05», «Oggi è giovedì 25 settembre 2026»,
    /// il mini-calendario dei prossimi giorni («- venerdì 2026-09-26 (domani)»).
    static let scaffolding: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?:(?:Adesso|Oggi) è|It is now|It's now|Today is) [^\n]{0,40}?\d{4}(?:-\d{2}-\d{2})?(?:,? (?:ore |at )?\d{1,2}[:.]\d{2})?"#),
        try! NSRegularExpression(pattern: #"(?m)^- \p{L}+ \d{4}-\d{2}-\d{2}(?: \((?:oggi|domani|today|tomorrow)\))?$"#),
        // Il nome dell'assistente nelle istruzioni («You are Siri AI+…»): il modello inglese lo prendeva per una persona.
        try! NSRegularExpression(pattern: #"\bSiri(?: AI\+)?"#),
    ]

    /// Le entità da nascondere: solo quelle delle categorie scelte. Restano in chiaro gli indirizzi IP del Mac e della rete
    /// di casa (127.0.0.1, 192.168…, servono a chi programma) e i numeri che il modello prende per civici senza una via
    /// davanti; dentro un indirizzo web lasciato in chiaro l'email si nasconde lo stesso.
    static func masked(_ entities: [PIIEntity], in text: PIIText, labels: Set<String>) -> [PIIEntity] {
        var result: [PIIEntity] = []
        for (index, entity) in entities.enumerated() {
            let value = text.slice(entity.start, entity.end)
            guard labels.contains(entity.label) else {
                if entity.label == "URL", labels.contains("EMAIL") {
                    result += PIIText(value).matches(emailRegex).map {
                        PIIEntity(label: "EMAIL", start: entity.start + $0.start, end: entity.start + $0.end, score: 1, validated: false, source: .regex)
                    }
                }
                continue
            }
            if entity.label == "IPADDR", isLocalAddress(value) { continue }
            if entity.label == "BUILDINGNUM" {
                let previous = index > 0 ? entities[index - 1] : nil
                guard let previous, previous.label == "STREET", entity.start - previous.end <= 6 else { continue }
            }
            result.append(entity)
        }
        return result
    }

    private static let emailRegex = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)

    /// Indirizzi del Mac stesso e delle reti private (anche intervalli e reti «192.168.1.0/24»).
    static func isLocalAddress(_ value: String) -> Bool {
        let first = value.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map(String.init) ?? value
        let octets = first.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (0, _), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Divide ai paragrafi (righe vuote), tenendo i separatori: riuniti danno il testo di partenza.
    static func paragraphs(_ text: String) -> [String] {
        guard text.count > 400, let regex = try? NSRegularExpression(pattern: #"\n[ \t]*\n+"#) else { return [text] }
        let ns = text as NSString
        var parts: [String] = []
        var position = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let end = match.range.location + match.range.length
            parts.append(ns.substring(with: NSRange(location: position, length: end - position)))
            position = end
        }
        if position < ns.length { parts.append(ns.substring(from: position)) }
        return parts
    }

    /// Solo i dati già noti (per pagine web e testi pubblici): nomi, aziende, recapiti e codici della chat diventano i
    /// loro segnaposto, così una pagina non rivela chi c'è dietro «[ORG_1]». Il resto della pagina resta com'è.
    public func mask(_ text: String) -> String {
        // Solo le categorie che la chat nasconde: un'azienda lasciata in chiaro nella conversazione resta in chiaro anche qui.
        let identifying = labels.intersection(["FULLNAME", "ORG", "EMAIL", "TELEPHONENUM", "CF", "PIVA", "ID_DOC", "IBAN", "CREDITCARDNUMBER",
                                               "TARGA", "IPADDR", "DOCID", "URL"])
        let known = currentVault.values.filter { placeholder, value in
            let (label, _) = PIIVault.split(placeholder)
            guard identifying.contains(label), value.count >= 4 else { return false }
            // Un nome solo («Marco») è troppo comune per toglierlo da una pagina.
            return label != "FULLNAME" || value.split(separator: " ").count >= 2
        }
        guard !known.isEmpty else { return text }
        // Le aziende anche senza la forma societaria: le pagine scrivono «Ferrero», non «Ferrero S.p.A.».
        var aliases: [(value: String, placeholder: String)] = known.map { ($0.value, $0.key) }
        for (placeholder, value) in known where PIIVault.split(placeholder).0 == "ORG" {
            let core = value.replacingOccurrences(of: #"[\s,]*(?:S\.?\s?r\.?\s?l\.?|S\.?\s?p\.?\s?A\.?|S\.?\s?a\.?\s?s\.?|S\.?\s?n\.?\s?c\.?|S\.?\s?s\.?|&\s*C\.?|Srl|SpA|Sas|Snc)\s*$"#,
                                                  with: "", options: [.regularExpression, .caseInsensitive])
            if core != value, core.count >= 4 { aliases.append((core, placeholder)) }
        }
        let byValue = Dictionary(aliases.map { (PIIVault.normalized($0.value), $0.placeholder) }, uniquingKeysWith: { a, _ in a })
        let pattern = aliases.map(\.value).sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
            .joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])(?:"# + pattern + #")(?![\p{L}\p{N}_])"#, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var output = ""
        var position = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: position, length: match.range.location - position))
            let found = ns.substring(with: match.range)
            if let placeholder = byValue[PIIVault.normalized(found)] {
                output += placeholder
                note([placeholder])
            } else {
                output += found
            }
            position = match.range.location + match.range.length
        }
        return output + ns.substring(from: position)
    }

    // MARK: Dal modello

    /// I segnaposto tornano i valori veri, anche scritti in grassetto o senza parentesi («FULLNAME_1»).
    /// Un segnaposto che la chat non conosce (inventato dal modello) resta com'è.
    public func reveal(_ text: String) -> String { Self.reveal(text, vault: currentVault) }

    public static func reveal(_ text: String, vault: PIIVault) -> String {
        guard !vault.isEmpty, text.contains("_") else { return text }
        let ns = text as NSString
        var output = ""
        var position = 0
        for match in revealRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let inner = [1, 2].compactMap { match.range(at: $0).location == NSNotFound ? nil : ns.substring(with: match.range(at: $0)) }.first ?? ""
            output += ns.substring(with: NSRange(location: position, length: match.range.location - position))
            output += vault.values["[\(inner)]"] ?? ns.substring(with: match.range)
            position = match.range.location + match.range.length
        }
        return output + ns.substring(from: position)
    }

    /// Parentesi tutto-o-niente; senza parentesi con un confine di parola Unicode (come `reverse()` di rizzo-pii).
    private static let revealRegex = try! NSRegularExpression(
        pattern: #"\[\s*([A-Z][A-Z_]*_\d+)\s*\]|(?<![\p{L}\p{N}_])([A-Z][A-Z_]*_\d+)(?![\p{L}\p{N}_])"#)

    /// Durante lo streaming: come `reveal`, ma un segnaposto ancora a metà in fondo («[FULLNA») non si mostra.
    public func revealStreaming(_ text: String) -> String {
        var text = text
        if let range = text.range(of: #"\[\s*[A-Z_]*\d*\s*$"#, options: .regularExpression) { text.removeSubrange(range) }
        return reveal(text)
    }

    /// Gli argomenti di uno strumento chiesto dal modello: i valori veri, perché lo strumento gira sul Mac.
    public func reveal(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): .string(reveal(text))
        case .array(let items): .array(items.map { reveal($0) })
        case .object(let fields): .object(fields.mapValues { reveal($0) })
        default: value
        }
    }

    /// La risposta del modello (con i segnaposto) diventa leggibile; quando tornerà nella cronologia non si rianalizza.
    public func learn(anonymized: String) -> String {
        let revealed = reveal(anonymized)
        lock.withLock { cache[revealed] = anonymized }
        remember(revealed, anonymized)
        return revealed
    }

    // MARK: Resoconto

    private func note(_ placeholders: [String]) {
        guard !placeholders.isEmpty else { return }
        lock.withLock { used.formUnion(placeholders) }
    }

    /// I segnaposto usati dall'ultima volta (e si riparte da zero).
    public func takeReport() -> PrivacyReport? {
        let placeholders = lock.withLock { () -> [String] in
            let list = Array(used)
            used.removeAll()
            return list
        }
        guard !placeholders.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for placeholder in placeholders { counts[PIIVault.split(placeholder).0, default: 0] += 1 }
        let vault = currentVault
        let sorted = placeholders.sorted { a, b in
            let (la, na) = PIIVault.split(a), (lb, nb) = PIIVault.split(b)
            return la == lb ? na < nb : la < lb
        }
        return PrivacyReport(destination: destination, counts: counts, placeholders: sorted,
                             values: Dictionary(uniqueKeysWithValues: sorted.compactMap { key in vault.values[key].map { (key, $0) } }))
    }

    static func placeholders(in text: String) -> [String] {
        guard text.contains("[") else { return [] }
        let ns = text as NSString
        return PIIAnalysis.placeholderRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).replacingOccurrences(of: " ", with: "")
        }
    }
}

extension PIIEngine {
    /// Entità di un testo, senza quelle sopra a segnaposto già presenti (niente segnaposto dentro un segnaposto).
    public func entities(in text: String) throws -> [PIIEntity] {
        let source = PIIText(text)
        guard source.count > 0 else { return [] }
        let existing = source.matches(PIIAnalysis.placeholderRegex)
        return try analyze(source).filter { entity in !existing.contains { $0.start < entity.end && entity.start < $0.end } }
    }
}

/// Paragrafi già anonimizzati di ogni chat, per tutta la vita dell'app. Solo in memoria (dentro ci sono i testi veri),
/// con un tetto: le voci più vecchie escono per prime.
final class ShieldMemory: @unchecked Sendable {
    static let shared = ShieldMemory()
    static let limit = 4000

    struct Entry {
        let output: String
        /// Segnaposto → valore al momento dell'anonimizzazione.
        let values: [String: String]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    func entry(_ key: String) -> Entry? { lock.withLock { entries[key] } }

    func store(_ key: String, _ entry: Entry) {
        lock.withLock {
            if entries[key] == nil { order.append(key) }
            entries[key] = entry
            if order.count > Self.limit { entries[order.removeFirst()] = nil }
        }
    }
}
