import Foundation
import NaturalLanguage

/// Lingua della richiesta: Siri AI+ risponde nella lingua in cui gli si scrive (italiano o inglese).
/// Vale per tutto ciò che il motore fa durante la richiesta: parole chiave, date, numeri, istruzioni ai modelli, messaggi.
/// Con l'italiano il comportamento resta quello di sempre; l'inglese aggiunge le sue regole.
public enum Language: String, Sendable, Codable, CaseIterable {
    case it, en

    /// Lingua della richiesta in corso, scelta da chi la avvia (app, valutazioni, CLI); i sub-agent la ereditano.
    @TaskLocal public static var scoped: Language?

    /// Lingua in uso: quella della richiesta in corso, fuori da una richiesta quella del Mac.
    public static var current: Language { scoped ?? system }

    /// Lingua del Mac: italiano se è la prima lingua preferita, altrimenti inglese.
    public static var system: Language {
        let first = Locale.preferredLanguages.first ?? Locale.current.identifier
        return first.lowercased().hasPrefix("it") ? .it : .en
    }

    public static var isEnglish: Bool { current == .en }

    /// Il testo nella lingua della richiesta.
    public static func t(_ italian: String, _ english: String) -> String { current == .en ? english : italian }

    /// Formati di date e numeri per le risposte in questa lingua (in inglese quelli del Mac, se è in inglese).
    public var locale: Locale {
        switch self {
        case .it: Locale(identifier: "it_IT")
        case .en: Locale.current.language.languageCode?.identifier == "en" ? Locale.current : Locale(identifier: "en_US")
        }
    }

    /// Nome della lingua per le istruzioni ai modelli.
    public var name: String { self == .it ? "italiano" : "English" }

    /// Riconosce la lingua di una richiesta. Testi tra virgolette, nomi di file, indirizzi e sigle non contano
    /// («riassumi TASKS.md» è italiano, «Translate: "Scrivi a Marco"» è inglese); nei testi corti o incerti vale `fallback`.
    public static func detect(_ text: String, fallback: Language) -> Language {
        var plain = Assistant.withoutQuotes(text)
        for pattern in [#"https?://\S+|www\.\S+"#, #"\S+@\S+"#, #"\b[\w\-/]+\.[A-Za-z0-9]{1,5}\b"#, #"\b[A-Z0-9_]{2,}\b"#, #"[0-9]+"#] {
            plain = plain.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let words = plain.split { !$0.isLetter }.map { $0.lowercased() }
        guard !words.isEmpty else { return fallback }
        // Lettere accentate e forme tipiche decidono anche nei testi brevissimi.
        if plain.range(of: #"[àèéìòù]"#, options: .regularExpression) != nil { return .it }
        if plain.range(of: #"\b\w+'(?:s|t|re|ve|ll|d|m)\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
           !plain.lowercased().contains("l'"), !plain.lowercased().contains("un'") { return .en }
        if words.count <= 2 {
            let italian: Set = ["ciao", "grazie", "sì", "si", "perfetto", "bene", "va", "certo", "esatto", "giusto", "salve", "buongiorno", "buonasera", "dai", "vai", "continua", "ancora", "altro", "basta", "fatto", "fatta"]
            let english: Set = ["hi", "hello", "hey", "thanks", "thank", "you", "yes", "yeah", "yep", "sure", "great", "perfect", "nice", "cool", "fine", "good", "morning", "evening", "please", "go", "on", "more", "done", "right", "exactly"]
            let it = words.filter(italian.contains).count, en = words.filter(english.contains).count
            if it > en { return .it }
            if en > it { return .en }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.italian, .english]
        recognizer.processString(plain)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let it = hypotheses[.italian] ?? 0, en = hypotheses[.english] ?? 0
        if max(it, en) < 0.75 { return fallback }
        return en > it ? .en : .it
    }
}
