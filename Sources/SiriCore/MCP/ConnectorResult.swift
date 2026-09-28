import Foundation

/// Il risultato di uno strumento di un connettore come lo legge il modello: il JSON diventa righe «chiave: valore»,
/// senza campi vuoti, con gli elenchi lunghi accorciati e il loro conteggio. Nella finestra piccola di Apple Intelligence
/// entrano così molti più dati utili; il testo che non è JSON resta com'è.
public enum ConnectorResult {
    /// Campi che vengono prima degli altri in ogni elemento (poi gli altri in ordine alfabetico).
    static let leadingKeys = [
        "name", "title", "nome", "titolo", "subject", "oggetto", "label", "status", "stato", "state", "due", "due_date", "deadline",
        "scadenza", "date", "data", "start", "end", "amount", "total", "importo", "totale", "client", "cliente", "customer", "company",
        "azienda", "contact", "contatto", "owner", "assignee", "email", "phone", "telefono", "city", "città", "description", "descrizione",
        "summary", "text", "id",
    ]

    public static func readable(_ text: String, limit: Int = 3000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let value = try? JSONValue.parse(Data(trimmed.utf8)) else {
            return String(trimmed.prefix(limit))
        }
        var lines: [String] = []
        render(value, key: nil, indent: "", depth: 0, into: &lines, budget: limit)
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? String(trimmed.prefix(limit)) : String(joined.prefix(limit))
    }

    /// Chiavi in un ordine utile: prima nomi, stati, date e importi.
    static func orderedKeys(_ object: [String: JSONValue]) -> [String] {
        let rank = Dictionary(uniqueKeysWithValues: leadingKeys.enumerated().map { ($1, $0) })
        return object.keys.sorted { a, b in
            let ra = rank[a.lowercased()] ?? Int.max, rb = rank[b.lowercased()] ?? Int.max
            return ra != rb ? ra < rb : a < b
        }
    }

    static func isEmpty(_ value: JSONValue) -> Bool {
        switch value {
        case .null: true
        case .string(let s): s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let a): a.isEmpty
        case .object(let o): o.isEmpty
        default: false
        }
    }

    /// Un valore semplice su una riga («12», «sì», «Rossi Arredamenti»), nil per oggetti ed elenchi di oggetti.
    static func scalar(_ value: JSONValue, maxLength: Int = 240) -> String? {
        switch value {
        case .string(let s):
            let single = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return single.count > maxLength ? String(single.prefix(maxLength)) + "…" : single
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .array(let items) where items.allSatisfy({ scalar($0) != nil && !isObjectLike($0) }):
            let values = items.compactMap { scalar($0, maxLength: 80) }
            return values.prefix(12).joined(separator: ", ") + (values.count > 12 ? " … (+\(values.count - 12))" : "")
        default: return nil
        }
    }

    static func isObjectLike(_ value: JSONValue) -> Bool {
        if case .object = value { return true }
        if case .array = value { return true }
        return false
    }

    /// Un elemento di un elenco su una riga: «Rossi Arredamenti · stato: attivo · città: Milano · id: C-101».
    static func line(_ object: [String: JSONValue], maxFields: Int = 9) -> String {
        var parts: [String] = []
        for key in orderedKeys(object) {
            guard let value = object[key], !isEmpty(value) else { continue }
            if let text = scalar(value, maxLength: 160) {
                parts.append(parts.isEmpty && ["name", "title", "nome", "titolo", "subject", "oggetto", "label"].contains(key.lowercased())
                             ? text : "\(key): \(text)")
            } else if case .object(let inner) = value, let name = ["name", "title", "nome", "titolo"].compactMap({ inner[$0].flatMap { scalar($0) } }).first {
                parts.append("\(key): \(name)")
            } else if case .array(let items) = value {
                parts.append("\(key): \(items.count)")
            }
            if parts.count >= maxFields { break }
        }
        return parts.joined(separator: " · ")
    }

    static func render(_ value: JSONValue, key: String?, indent: String, depth: Int, into lines: inout [String], budget: Int) {
        guard lines.reduce(0, { $0 + $1.count + 1 }) < budget else { return }
        let label = key.map { "\($0): " } ?? ""
        switch value {
        case .object(let object):
            // Risposte che avvolgono i dati in una sola chiave ({"results": […]}, {"data": {…}}): si va dritti ai dati.
            let filled = object.filter { !isEmpty($0.value) }
            if key == nil, filled.count == 1, let only = filled.first, isObjectLike(only.value) {
                render(only.value, key: only.key, indent: indent, depth: depth, into: &lines, budget: budget)
                return
            }
            if let key { lines.append(indent + key + ":") }
            let inner = key == nil ? indent : indent + "  "
            for name in orderedKeys(object) {
                guard let item = object[name], !isEmpty(item) else { continue }
                if let text = scalar(item) {
                    lines.append(inner + "\(name): \(text)")
                } else if depth < 3 {
                    render(item, key: name, indent: inner, depth: depth + 1, into: &lines, budget: budget)
                } else {
                    lines.append(inner + "\(name): " + String(item.compactString.prefix(160)))
                }
            }
        case .array(let items):
            let objects = items.compactMap(\.object)
            if !objects.isEmpty, objects.count == items.count {
                lines.append(indent + label + (Language.isEnglish ? "\(items.count) items" : "\(items.count) elementi"))
                var shown = 0
                for object in objects {
                    let row = line(object)
                    guard lines.reduce(0, { $0 + $1.count + 1 }) + row.count < budget else { break }
                    lines.append(indent + "- " + row)
                    shown += 1
                }
                if shown < objects.count {
                    lines.append(indent + (Language.isEnglish ? "… and \(objects.count - shown) more" : "… e altri \(objects.count - shown)"))
                }
            } else if let text = scalar(value) {
                lines.append(indent + label + text)
            } else {
                if let key { lines.append(indent + key + ":") }
                for item in items.prefix(30) {
                    if let text = scalar(item) { lines.append(indent + "- " + text) }
                    else { render(item, key: nil, indent: indent + "  ", depth: depth + 1, into: &lines, budget: budget) }
                }
            }
        default:
            if let text = scalar(value) { lines.append(indent + label + text) }
        }
    }

    /// Quante voci ha trovato (per la scheda e la traccia): «12 elementi», «ok», «errore».
    public static func summary(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = try? JSONValue.parse(Data(trimmed.utf8)) {
            // {"results": […]}, {"clients": […], "tasks": […]}: gli elementi di tutti gli elenchi.
            let count: Int? = if let items = value.array { items.count }
                else if let object = value.object, object.values.contains(where: { $0.array != nil }) { object.values.compactMap(\.array).reduce(0) { $0 + $1.count } }
                else { nil }
            if let count {
                if Language.isEnglish { return count == 1 ? "1 item" : "\(count) items" }
                return count == 1 ? "1 elemento" : "\(count) elementi"
            }
        }
        return Language.isEnglish ? "\(trimmed.count) characters" : "\(trimmed.count) caratteri"
    }
}
