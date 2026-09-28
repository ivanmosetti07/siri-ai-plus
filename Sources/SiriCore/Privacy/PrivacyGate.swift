import CryptoKit
import Foundation

// MARK: - rizzo-flow decide se serve rizzo-pii (scelta di Ivan del 27/9/2026)
//
// Per un testo lungo che sta per partire verso ChatGPT o Claude (istruzioni di progetto, file letti, risultati degli
// strumenti) rizzo-flow legge tre estratti e dice se può contenere dati personali di persone private. Se è sicuro di no,
// il modello di rizzo-pii non gira su quel testo; restano comunque i controlli su formati e checksum (email, telefoni,
// IBAN, codici fiscali, carte) e i nomi già noti della chat. Se non è sicuro, rizzo-pii gira come prima.
// Sui testi corti conviene sempre rizzo-pii: costa meno che chiedere a rizzo-flow. La soglia viene da
// `bin/siriai --anonimizza-tempi`.

public enum PrivacyGate {
    /// Impostazioni › Modelli › Anonimizzazione: «Lascia decidere a rizzo-flow quando serve rizzo-pii».
    public static let enabledKey = "privacyGate"
    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// Sotto questa lunghezza rizzo-pii è più veloce della domanda. Misurato sul Mac di Ivan (M2 Pro, 27/9) con
    /// `--anonimizza-tempi`: rizzo-pii 130 ms ogni 1.000 caratteri, la domanda a rizzo-flow 1,4 s → pareggio a ~10.700.
    public static let threshold = 12_000
    /// Solo con «nessun dato personale» sopra questa probabilità si salta rizzo-pii.
    static let confidence = 0.95
    static let excerpt = 500

    static let question = DecisionQuestion.choice(
        "personal", "What personal data about private people could this text contain?",
        [.init("none", "None: code, configuration, technical or public content, or figures without names of private people."),
         .init("people", "Names, contacts or addresses of private people."),
         .init("sensitive", "Sensitive personal information: health, finances, family, ID or bank details."),
         .init("unclear", "Cannot tell from these excerpts.")],
        policy: .closed)

    /// Inizio, metà e fine del testo: abbastanza per capire che cos'è, poco da leggere.
    static func state(for text: String) -> DecisionState {
        let characters = Array(text)
        func slice(_ start: Int) -> String {
            String(characters[max(0, min(start, characters.count - excerpt))..<min(characters.count, max(0, start) + excerpt)])
        }
        return DecisionState([("length_in_characters", .integer(characters.count)),
                              ("beginning", .string(slice(0))),
                              ("middle", .string(slice(characters.count / 2 - excerpt / 2))),
                              ("end", .string(slice(characters.count - excerpt)))])
    }

    private static let cache = GateCache()

    /// true = rizzo-flow è sicuro che non ci sono dati personali: il modello di rizzo-pii si può saltare.
    public static func canSkipModel(_ text: String) async -> Bool {
        guard isEnabled, text.count >= threshold else { return false }
        let key = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        if let known = cache.value(key) { return known }
        guard let answer = await DecisionEngine.shared.decide(state(for: text), question, priority: .interactive, budget: 4, label: "anonimizzazione")
        else { return false }
        let skip = answer.choice == "none" && answer.top >= confidence
        cache.store(key, skip)
        Agent.log("ANONIMIZZAZIONE: rizzo-flow → \(answer.winner) \(String(format: "%.2f", answer.top)) su \(text.count) caratteri"
                  + (skip ? " · rizzo-pii saltato (restano formati e nomi noti)" : " · rizzo-pii"))
        return skip
    }

    private final class GateCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Bool] = [:]
        func value(_ key: String) -> Bool? { lock.withLock { values[key] } }
        func store(_ key: String, _ value: Bool) { lock.withLock { if values.count > 500 { values.removeAll() }; values[key] = value } }
    }
}
