import CoreML
import Foundation

// MARK: - Prove del motore di anonimizzazione (dalla CLI)
//
// `bin/siriai --anonimizza "testo"`: testo anonimizzato, dizionario e tempi.
// `bin/siriai --anonimizza-prova riferimento.json [cpu|gpu|ane]`: confronto con la pipeline Python originale
// (token e posizioni, entità, testo anonimizzato), per verificare che il porting dia gli stessi risultati.

extension PIIEngine {
    /// Token e posizioni (per il confronto con il tokenizer di Hugging Face).
    func tokens(of text: String) throws -> [PIITokenizer.Token] {
        let (tokenizer, _) = try loadForDiagnostics()
        return tokenizer.encode(PIIText(text))
    }
}

public enum PIIDiagnostics {
    public static func units(_ name: String?) -> MLComputeUnits {
        switch name {
        case "cpu": .cpuOnly
        case "ane": .all
        default: .cpuAndGPU
        }
    }

    /// Un testo: anonimizzato, con il dizionario e il tempo.
    public static func anonymize(_ text: String) async throws -> String {
        let started = Date.now
        let (result, vault) = try await PIIEngine.shared.anonymize(text, vault: PIIVault())
        var lines = ["Tutte le categorie del motore:", result.text, ""]
        for entry in vault.entries { lines.append("\(entry.placeholder) = \(entry.value)") }
        lines.append(String(format: "\n%.2f s", Date.now.timeIntervalSince(started)))
        // Ciò che parte davvero verso ChatGPT e Claude: solo i dati personali (importi, date, luoghi e aziende in chiaro).
        let shield = PrivacyShield(vault: PIIVault(), destination: "prova")
        lines += ["", "Verso ChatGPT e Claude (solo dati personali):", try await shield.protect(text)]
        return lines.joined(separator: "\n")
    }

    /// Confronto con `reference.json` (prodotto da `Support/rizzo-pii/reference.py`).
    public static func compare(reference url: URL, units name: String?) async throws -> String {
        await PIIEngine.shared.use(units(name))
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PrivacyError.failed("riferimento non leggibile") }
        var report: [String] = []
        // Tokenizer.
        let samples = json["tokens"] as? [[String: Any]] ?? []
        var tokenMismatches = 0
        for sample in samples {
            guard let text = sample["text"] as? String, let ids = sample["ids"] as? [Int], let offsets = sample["offsets"] as? [[Int]] else { continue }
            let tokens = try await PIIEngine.shared.tokens(of: text)
            let same = tokens.map { Int($0.id) } == ids && zip(tokens, offsets).allSatisfy { $0.start == $1[0] && $0.end == $1[1] }
            if !same {
                tokenMismatches += 1
                if tokenMismatches <= 5 {
                    let first = zip(tokens, zip(ids, offsets)).enumerated().first { $0.element.0.id != Int32($0.element.1.0) || $0.element.0.start != $0.element.1.1[0] || $0.element.0.end != $0.element.1.1[1] }
                    report.append("TOKEN diversi in «\(text.prefix(50))»: \(tokens.count) contro \(ids.count); primo alla posizione \(first?.offset ?? -1): "
                        + "\(first.map { "swift \($0.element.0.id) (\($0.element.0.start),\($0.element.0.end)) · python \($0.element.1.0) (\($0.element.1.1[0]),\($0.element.1.1[1]))" } ?? "lunghezza")")
                }
            }
        }
        report.append("Tokenizer: \(samples.count - tokenMismatches)/\(samples.count) uguali")
        // Pipeline completa.
        let analyses = json["analyses"] as? [[String: Any]] ?? []
        var same = 0, entitySame = 0, entityTotal = 0
        var elapsed = 0.0
        for analysis in analyses {
            guard let text = analysis["text"] as? String, let expected = analysis["anonymized"] as? String else { continue }
            let started = Date.now
            let (result, _) = try await PIIEngine.shared.anonymize(text, vault: PIIVault())
            elapsed += Date.now.timeIntervalSince(started)
            let reference = (analysis["entities"] as? [[String: Any]] ?? []).map { "\($0["label"] ?? "")@\($0["start"] ?? 0)-\($0["end"] ?? 0)" }
            let mine = try await PIIEngine.shared.entities(in: text).map { "\($0.label)@\($0.start)-\($0.end)" }
            entityTotal += Set(reference).union(mine).count
            entitySame += Set(reference).intersection(mine).count
            if result.text == expected {
                same += 1
            } else {
                report.append("DIVERSO: «\(text.prefix(60))…»\n  python: \(expected.prefix(300))\n  swift:  \(result.text.prefix(300))\n  solo python: \(Set(reference).subtracting(mine).sorted()) · solo swift: \(Set(mine).subtracting(reference).sorted())")
            }
        }
        report.append("Testi anonimizzati uguali: \(same)/\(analyses.count) · entità uguali \(entitySame)/\(entityTotal) · "
            + String(format: "%.0f ms per testo (%@)", elapsed / Double(max(1, analyses.count)) * 1000, name ?? "gpu"))
        return report.joined(separator: "\n")
    }
}
