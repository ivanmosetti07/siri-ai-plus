import CoreML
import Foundation

// MARK: - Anonimizzazione reversibile (rizzo-pii sul Mac)
//
// Porting di `analyze()` di rizzo-pii: il testo si divide in blocchi di 120 parole (20 in comune fra un blocco e il
// successivo), il modello etichetta ogni blocco, la rete regex + checksum aggiunge i dati a forma fissa, la fusione
// tiene i candidati migliori senza sovrapposizioni e li allinea alle parole; ogni dato diventa un segnaposto
// «[FULLNAME_1]». Il dizionario (`PIIVault`) resta sul Mac: lo stesso dato ha lo stesso segnaposto per tutta la
// conversazione, e al ritorno i segnaposto tornano i valori veri.

/// Segnaposto ↔ valori di una conversazione. Resta sul Mac, non va mai al modello.
public struct PIIVault: Codable, Sendable, Equatable {
    /// «[FULLNAME_1]» → «Mario Rossi».
    public private(set) var values: [String: String] = [:]
    /// Categoria + valore normalizzato → segnaposto (lo stesso dato, lo stesso segnaposto).
    private var seen: [String: String] = [:]
    private var counters: [String: Int] = [:]

    public init() {}

    public var isEmpty: Bool { values.isEmpty }

    /// `_norm` di app.py: spazi compattati, maiuscole e minuscole uguali.
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    /// Il segnaposto di un dato (nuovo se non c'era).
    mutating func placeholder(label: String, value: String) -> (placeholder: String, isNew: Bool) {
        let key = label + "\u{0}" + Self.normalized(value)
        if let existing = seen[key] { return (existing, false) }
        let number = (counters[label] ?? 0) + 1
        counters[label] = number
        let placeholder = "[\(label)_\(number)]"
        seen[key] = placeholder
        values[placeholder] = value
        return (placeholder, true)
    }

    /// Segnaposto e valori in ordine di categoria e numero (per mostrarli).
    public var entries: [(placeholder: String, value: String)] {
        values.sorted { a, b in
            let (la, na) = Self.split(a.key), (lb, nb) = Self.split(b.key)
            return la == lb ? na < nb : la < lb
        }.map { ($0.key, $0.value) }
    }

    static func split(_ placeholder: String) -> (String, Int) {
        let inner = placeholder.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let underscore = inner.lastIndex(of: "_") else { return (inner, 0) }
        return (String(inner[..<underscore]), Int(inner[inner.index(after: underscore)...]) ?? 0)
    }
}

/// Esito di un'anonimizzazione: testo con i segnaposto e dati nuovi per categoria.
public struct PIIResult: Sendable {
    public var text: String
    public var found: [String: Int]
}

enum PIIAnalysis {
    static let maxWords = 120
    static let overlap = 20

    /// `chunk_text`: blocchi di parole intere (spezzati dove c'è spazio), con l'offset di partenza.
    static func chunks(_ text: PIIText, maxWords: Int = maxWords, overlap: Int = overlap) -> [(start: Int, end: Int)] {
        var words: [(start: Int, end: Int)] = []
        var index = 0
        while index < text.count {
            if text[index].pyIsSpace { index += 1; continue }
            let start = index
            while index < text.count, !text[index].pyIsSpace { index += 1 }
            words.append((start, index))
        }
        guard !words.isEmpty else { return [] }
        var chunks: [(Int, Int)] = []
        let step = max(1, maxWords - overlap)
        var i = 0
        while i < words.count {
            let block = words[i..<min(words.count, i + maxWords)]
            chunks.append((block.first!.start, block.last!.end))
            if i + maxWords >= words.count { break }
            i += step
        }
        return chunks
    }

    /// `_merge`: senza sovrapposizioni, prima i checksum validi, poi la rete regex (non «soft»), poi punteggio e lunghezza;
    /// niente spazi ai bordi, parole mai tagliate a metà, pezzi contigui della stessa categoria uniti.
    static func merge(_ candidates: [PIIEntity], in text: PIIText) -> [PIIEntity] {
        let order = candidates.enumerated().sorted { a, b in
            func key(_ e: PIIEntity) -> (Int, Int, Double, Int) {
                (e.validated ? 1 : 0, e.source == .regex && !PIIDetectors.softRegexLabels.contains(e.label) ? 1 : 0, e.score, e.end - e.start)
            }
            let ka = key(a.element), kb = key(b.element)
            if ka.0 != kb.0 { return ka.0 > kb.0 }
            if ka.1 != kb.1 { return ka.1 > kb.1 }
            if ka.2 != kb.2 { return ka.2 > kb.2 }
            if ka.3 != kb.3 { return ka.3 > kb.3 }
            return a.offset < b.offset       // stabile come `sorted(..., reverse=True)` di Python
        }.map(\.element)
        var kept: [PIIEntity] = []
        for entity in order {
            // bisect_right sugli inizi: le entità tenute sono ordinate e senza sovrapposizioni.
            var low = 0, high = kept.count
            while low < high {
                let mid = (low + high) / 2
                if entity.start < kept[mid].start { high = mid } else { low = mid + 1 }
            }
            if (low > 0 && kept[low - 1].end > entity.start) || (low < kept.count && kept[low].start < entity.end) { continue }
            kept.insert(entity, at: low)
        }
        for index in kept.indices {
            while kept[index].start < kept[index].end, text[kept[index].start].pyIsSpace { kept[index].start += 1 }
            while kept[index].end > kept[index].start, text[kept[index].end - 1].pyIsSpace { kept[index].end -= 1 }
        }
        kept.removeAll { $0.end <= $0.start }
        for index in kept.indices {
            while kept[index].start > 0, text[kept[index].start - 1].isWordCharacter, text[kept[index].start].isWordCharacter {
                kept[index].start -= 1
            }
            while kept[index].end < text.count, text[kept[index].end].isWordCharacter, text[kept[index].end - 1].isWordCharacter {
                kept[index].end += 1
            }
        }
        kept = kept.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            let la = a.element.end - a.element.start, lb = b.element.end - b.element.start
            return la != lb ? la > lb : a.offset < b.offset
        }.map(\.element)
        var merged: [PIIEntity] = []
        for entity in kept {
            if let last = merged.last, entity.start < last.end {
                merged[merged.count - 1].end = max(last.end, entity.end)
                continue
            }
            if let last = merged.last, entity.start == last.end, entity.label == last.label {
                merged[merged.count - 1].end = entity.end
                continue
            }
            merged.append(entity)
        }
        return merged
    }

    /// Segnaposto già presenti nel testo («[FULLNAME_1]»): non si rianonimizzano.
    static let placeholderRegex = try! NSRegularExpression(pattern: #"\[\s*[A-Z][A-Z_]*_\d+\s*\]"#)
}

/// Il motore sul Mac: tokenizer e modello caricati la prima volta che servono. Un attore: il lavoro pesante
/// non passa mai dal thread principale, e due richieste non si contendono il modello.
public actor PIIEngine {
    public static let shared = PIIEngine()

    /// `~/Library/Application Support/Siri AI+/Models/rizzo-pii/`
    public static var directory: URL { AppPaths.models.appending(path: "rizzo-pii") }
    static var modelURL: URL { directory.appending(path: "RizzoPII.mlmodelc") }

    /// Il motore è installato (modello compilato, tokenizer ed etichette).
    public static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: modelURL.path) && fm.fileExists(atPath: directory.appending(path: "tokenizer.json").path)
            && fm.fileExists(atPath: directory.appending(path: "config.json").path)
    }

    private var tokenizer: PIITokenizer?
    private var model: PIIModel?
    private var lastUse = Date.distantPast
    /// Solo processore: il più veloce per blocchi così piccoli (35 ms a testo, contro 122 della grafica e 317 del Neural Engine),
    /// con gli stessi risultati della pipeline originale.
    private var computeUnits: MLComputeUnits = .cpuOnly

    /// Per le prove: dove far girare il modello.
    public func use(_ units: MLComputeUnits) {
        computeUnits = units
        model = nil
    }

    private func load() throws -> (PIITokenizer, PIIModel) {
        if let tokenizer, let model { return (tokenizer, model) }
        guard Self.isInstalled else { throw PrivacyError.notInstalled }
        let started = Date.now
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.directory.appending(path: "config.json"))) as? [String: Any]
        guard let map = config?["id2label"] as? [String: String] else { throw PrivacyError.failed("etichette del modello non leggibili") }
        let labels = (0..<map.count).map { map[String($0)] ?? "O" }
        let tokenizer = try self.tokenizer ?? PIITokenizer(url: Self.directory.appending(path: "tokenizer.json"))
        let model = try PIIModel(url: Self.modelURL, labels: labels, computeUnits: computeUnits)
        self.tokenizer = tokenizer
        self.model = model
        Agent.log("ANONIMIZZAZIONE: motore rizzo-pii pronto in \(String(format: "%.1f", Date.now.timeIntervalSince(started))) s")
        return (tokenizer, model)
    }

    func loadForDiagnostics() throws -> (PIITokenizer, PIIModel) { try load() }

    /// Carica il motore in anticipo (all'avvio, se la chat usa ChatGPT o Claude): la prima richiesta non aspetta.
    public func prepare() {
        _ = try? load()
    }

    /// Libera la memoria se il motore non serve da un po' (circa 700 MB).
    public func releaseIfIdle(after seconds: TimeInterval = 600) {
        guard model != nil, Date.now.timeIntervalSince(lastUse) > seconds else { return }
        model = nil
        tokenizer = nil
        Agent.log("ANONIMIZZAZIONE: motore scaricato dalla memoria (inattivo)")
    }

    /// Le entità di un testo: modello sui blocchi, ore completate, rete regex, fusione (`analyze()` di rizzo-pii).
    func analyze(_ text: PIIText) throws -> [PIIEntity] {
        let (tokenizer, model) = try load()
        lastUse = .now
        var found: [PIIEntity] = []
        for chunk in PIIAnalysis.chunks(text) {
            try found.append(contentsOf: detect(in: text, from: chunk.start, to: chunk.end, tokenizer: tokenizer, model: model))
        }
        PIIDetectors.completeTime(&found, in: text)
        return PIIAnalysis.merge(found + PIIDetectors.detect(text), in: text)
    }

    /// Un blocco al modello; oltre i 512 token (parole lunghissime, codici) si divide a metà per parole.
    private func detect(in text: PIIText, from start: Int, to end: Int, tokenizer: PIITokenizer, model: PIIModel) throws -> [PIIEntity] {
        let piece = PIIText(text.slice(start, end))
        let tokens = tokenizer.encode(piece)
        if tokens.count > PIIModel.shapes.last! {
            // Si taglia sullo spazio più vicino alla metà (o a metà, se non ce ne sono).
            let spaces = piece.scalars.indices.filter { piece[$0].pyIsSpace && $0 > 0 }
            let cut = spaces.min { abs($0 - piece.count / 2) < abs($1 - piece.count / 2) } ?? piece.count / 2
            return try detect(in: text, from: start, to: start + cut, tokenizer: tokenizer, model: model)
                + detect(in: text, from: start + cut, to: end, tokenizer: tokenizer, model: model)
        }
        let predictions = try model.predict(tokens.map(\.id))
        return PIIModel.entities(tokens: tokens, predictions: predictions, labels: model.labels).map {
            var entity = $0
            entity.start += start
            entity.end += start
            return entity
        }
    }

    /// Testo con i segnaposto al posto dei dati, con il dizionario della conversazione (restituito aggiornato).
    public func anonymize(_ text: String, vault: PIIVault) throws -> (result: PIIResult, vault: PIIVault) {
        var vault = vault
        let source = PIIText(text)
        guard source.count > 0 else { return (PIIResult(text: text, found: [:]), vault) }
        let entities = try entities(in: text)
        var output = ""
        var found: [String: Int] = [:]
        var position = 0
        for entity in entities {
            output += source.slice(position, entity.start)
            let value = source.slice(entity.start, entity.end)
            let (placeholder, isNew) = vault.placeholder(label: entity.label, value: value)
            if isNew { found[entity.label, default: 0] += 1 }
            output += placeholder
            position = entity.end
        }
        output += source.slice(position, source.count)
        return (PIIResult(text: output, found: found), vault)
    }
}

/// L'anonimizzazione non è riuscita: niente va al modello esterno.
public enum PrivacyError: LocalizedError, Equatable {
    case notInstalled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "il motore di anonimizzazione rizzo-pii non è installato (Impostazioni › Modelli › Privacy)"
        case .failed(let reason):
            "l'anonimizzazione non è riuscita (\(reason))"
        }
    }
}
