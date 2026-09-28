import Foundation

/// Un fatto da ricordare tra una conversazione e l'altra.
public struct MemoryFact: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var text: String
    public var date = Date.now
    /// Da dove viene: "utente", "compattazione", "attività".
    public var source: String

    public init(text: String, source: String) {
        self.text = text
        self.source = source
    }
}

/// Memoria generale, salvata in Markdown leggibile e modificabile (`Application Support/<app>/MEMORY.md`).
/// Ogni ricordo è una riga «- [data] (fonte) testo»; l'id resta in un commento HTML invisibile.
@MainActor
public final class MemoryStore {
    public static let shared = MemoryStore()
    public static let limit = 200

    public private(set) var facts: [MemoryFact] = []

    public var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "memoryEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "memoryEnabled") }
    }

    private let url: URL
    private var loadedDate: Date?

    public var fileURL: URL { url }

    public init(url: URL? = nil) {
        self.url = url ?? AppPaths.support("MEMORY.md")
        // Migrazione dal vecchio memory.json.
        let legacy = self.url.deletingLastPathComponent().appending(path: "memory.json")
        reloadIfChanged()
        // Vecchio memory.json (anche riscritto da una versione precedente ancora aperta): i fatti mancanti si uniscono.
        if let data = try? Data(contentsOf: legacy), let old = try? JSONDecoder().decode([MemoryFact].self, from: data) {
            let known = Set(facts.map { Self.normalize($0.text) })
            let missing = old.filter { !known.contains(Self.normalize($0.text)) }
            if !missing.isEmpty || !FileManager.default.fileExists(atPath: self.url.path) {
                facts = (facts + missing).sorted { $0.date > $1.date }
                save()
            }
            let done = legacy.appendingPathExtension("migrato")
            try? FileManager.default.removeItem(at: done)
            try? FileManager.default.moveItem(at: legacy, to: done)
        }
    }

    /// Rilegge il file se è stato modificato a mano (editor, Finder, altro Mac).
    public func reloadIfChanged() {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified, modified != loadedDate, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        facts = Self.parse(text)
        loadedDate = modified
    }

    static let header = """
    # Memoria

    Fatti e preferenze che l'assistente ricorda tra una conversazione e l'altra. Puoi modificare questo file: \
    ogni riga «- …» è un ricordo (la data e la fonte tra parentesi sono facoltative).

    ## Ricordi

    """

    static func parse(_ text: String) -> [MemoryFact] {
        let regex = try? NSRegularExpression(pattern: #"^[-*]\s+(?:\[(\d{4}-\d{2}-\d{2})\]\s+)?(?:\(([^)]{1,20})\)\s+)?(.*?)\s*(?:<!--\s*id:([0-9A-Fa-f-]{36})\s*-->)?$"#)
        var facts: [MemoryFact] = []
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let match = regex?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func group(_ i: Int) -> String? { match.range(at: i).location == NSNotFound ? nil : ns.substring(with: match.range(at: i)) }
            guard let body = group(3), !body.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var fact = MemoryFact(text: body, source: group(2) ?? "utente")
            if let id = group(4).flatMap(UUID.init(uuidString:)) { fact.id = id }
            if let day = group(1), let date = try? Date(day + "T12:00:00Z", strategy: .iso8601) { fact.date = date }
            facts.append(fact)
        }
        return facts
    }

    static func render(_ facts: [MemoryFact]) -> String {
        header + facts.map { fact in
            "- [\(fact.date.localDay)] (\(fact.source)) \(fact.text.replacingOccurrences(of: "\n", with: " ")) <!-- id:\(fact.id.uuidString) -->"
        }.joined(separator: "\n") + "\n"
    }

    /// Aggiunge un fatto se non è già presente. Restituisce false se era un duplicato.
    @discardableResult
    public func add(_ text: String, source: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let key = Self.normalize(cleaned)
        if facts.contains(where: { Self.normalize($0.text) == key }) { return false }
        facts.insert(MemoryFact(text: cleaned, source: source), at: 0)
        if facts.count > Self.limit { facts.removeLast(facts.count - Self.limit) }
        save()
        return true
    }

    /// Come `add`, ma restituisce il ricordo salvato (nil se era un doppione): serve il suo id per «Annulla».
    @discardableResult
    public func insert(_ text: String, source: String) -> MemoryFact? {
        add(text, source: source) ? facts.first : nil
    }

    public func update(_ id: UUID, text: String) {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[index].text = text
        save()
    }

    public func remove(_ id: UUID) {
        facts.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        facts = []
        save()
    }

    /// Fatti più pertinenti alla richiesta: parole in comune, poi i più recenti.
    public func relevant(to query: String, limit: Int = 6) -> [MemoryFact] {
        reloadIfChanged()
        guard enabled, !facts.isEmpty else { return [] }
        let words = Self.keywords(query)
        let scored = facts.enumerated().map { index, fact -> (MemoryFact, Double) in
            let overlap = Double(Self.keywords(fact.text).intersection(words).count)
            let recency = 1.0 / Double(index + 2)
            return (fact, overlap * 2 + recency + (fact.source == "utente" ? 0.5 : 0))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Istanze di prova e valutazioni: i ricordi valgono per la sessione ma non si scrivono nel file di Ivan.
    nonisolated static let readOnly = ProcessInfo.processInfo.arguments.contains { $0 == "--ephemeral" || $0 == "--eval" }

    private func save() {
        guard !Self.readOnly else { return }
        try? Self.render(facts).write(to: url, atomically: true, encoding: .utf8)
        loadedDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    nonisolated static func normalize(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    nonisolated static func keywords(_ text: String) -> Set<String> {
        Set(normalize(text).split(separator: " ").map(String.init).filter { $0.count >= 4 })
    }
}
