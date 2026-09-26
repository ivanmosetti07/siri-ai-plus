import Foundation

// MARK: - Ciò che l'utente vede
//
// Le app di Siri AI+ (Mail, Note, Calendario…) dicono all'assistente cosa c'è nella scheda davanti: l'elemento selezionato
// con il suo testo, o il riassunto di ciò che l'app mostra. Così «rispondi», «riassumi questa nota», «spostalo alle 16»
// o «mandagli un messaggio» valgono per ciò che l'utente ha sotto gli occhi.

public struct ScreenItem: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case email, note, event, reminder, contact, chat, file, memo
        /// Nessun elemento selezionato: ciò che l'app mostra (le email della casella, le note della cartella…).
        case overview
    }

    /// Quanto chiaramente la richiesta indica l'elemento sullo schermo.
    public enum Reference: Int, Sendable, Comparable {
        case none, weak, strong
        public static func < (a: Reference, b: Reference) -> Bool { a.rawValue < b.rawValue }
    }

    /// App che lo mostra («Mail», «Note», «Calendario»…).
    public var app: String
    public var kind: Kind
    /// Titolo breve: l'oggetto dell'email, il titolo della nota, il nome del contatto.
    public var title: String
    /// Dettagli in una riga: mittente e data, orario e luogo, lista e scadenza.
    public var details: String
    /// Testo dell'elemento (corpo dell'email, testo della nota, trascrizione, ultimi messaggi): dati di terzi.
    public var text: String
    /// Identificativo per le azioni (id dell'email, della nota, del promemoria, della conversazione, percorso del file).
    public var reference: String?
    /// Parole con cui l'utente indica ciò che vede quando non c'è una selezione («queste email», «questi eventi»).
    public var nouns: [String]
    /// Destinatario pronto per messaggi ed email (contatto o conversazione).
    public var recipientName: String?
    public var phone: String?
    public var email: String?
    /// Elemento già pronto per le azioni dell'assistente.
    public var mail: MailMessage?
    public var event: EventItem?
    public var reminder: ReminderItem?

    public init(app: String, kind: Kind, title: String, details: String = "", text: String = "", reference: String? = nil, nouns: [String] = []) {
        self.app = app; self.kind = kind; self.title = title; self.details = details; self.text = text
        self.reference = reference; self.nouns = nouns
    }

    /// Identità dell'elemento: cambia quando l'utente seleziona qualcos'altro.
    public var identity: String { "\(app)|\(reference ?? title)" }

    /// Una riga per il modello e per le altre schede: «Mail: email «Fattura di marzo» (da Mario Rossi, 23 set)».
    public var headline: String {
        let main = kind == .overview ? title : "\(kind.noun) «\(title)»"
        return "\(app): \(main)" + (details.isEmpty ? "" : " (\(details))")
    }

    /// Quanto la richiesta parla di ciò che è sullo schermo: «questa email», «qui», «che vedo» (forte);
    /// «riassumilo», «il suo numero», «riassumi» da solo (debole: vale se l'utente l'ha appena selezionato).
    public func reference(in prompt: String) -> Reference {
        let lower = " " + prompt.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        let words = (kind == .overview ? nouns : kind.words).map { NSRegularExpression.escapedPattern(for: $0) }
        if !words.isEmpty {
            let noun = "(?:" + words.joined(separator: "|") + ")"
            // «questa email», «quest'email», «queste note», «l'email aperta», «la nota selezionata», «i file che vedo».
            if has(#"\bquest(?:[oaie]\s+|')"# + noun + #"\b"#) { return .strong }
            if has(#"\b"# + noun + #"\s+(?:apert[oaie]|selezionat[oaie]|che (?:vedo|sto guardando|ho davanti))\b"#) { return .strong }
        }
        if has(#"\b(?:qui|qua)\b"#) || has(#"\b(?:sullo schermo|a schermo|che (?:vedo|sto guardando|ho davanti))\b"#) { return .strong }
        guard kind != .overview else { return .none }
        // Dimostrativo senza nome, non di tempo («questa settimana», «questo mese» parlano di date).
        let times = #"(?:settimana|mese|anno|sera|mattina|pomeriggio|notte|weekend|fine|volta|momento|periodo|giorno|lunedì|martedì|mercoledì|giovedì|venerdì|sabato|domenica|estate|inverno|autunno|primavera)"#
        if has(#"\bquest[oaie]\b(?!\s+"# + times + ")") { return .weak }
        // Verbi con il pronome attaccato: «riassumila», «rispondigli», «spostalo», «chiamalo».
        if has(#"\b(?:riassumil[aoie]|traducil[aoie]|leggil[aoie]|spiegal[aoie]|correggil[aoie]|analizzal[aoie]|sintetizzal[aoie]|rispondigli|rispondile|inoltral[aoie]|spostal[aoie]|rimandal[aoie]|anticipal[aoie]|posticipal[aoie]|rinominal[aoie]|eliminal[aoie]|cancellal[aoie]|completal[aoie]|spuntal[aoie]|chiamal[aoie]|scrivigli|scrivile|mandagli|mandale|digli|dille|aprila|aprilo)\b"#) {
            return .weak
        }
        if kind == .contact, has(#"\b(?:suo|sua|suoi|sue|gli|le)\b"#) { return .weak }
        // «Riassumi», «traduci in inglese», «di cosa parla?» da soli.
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = trimmed.split(separator: " ").count <= 4
        if short, trimmed.range(of: #"^(?:riassumi|riassunto|traduci|spiega|correggi|analizza|sintetizza|di cosa parla|cosa dice|cosa c'è scritto|chi l'ha|chi lo|chi la)"#,
                                options: .regularExpression) != nil {
            return .weak
        }
        return .none
    }

    /// Una domanda o un'elaborazione di ciò che si vede («riassumi», «chi l'ha mandata?», «traduci»),
    /// non un'azione (creare, spostare, mandare, rispondere…): si risponde leggendo l'elemento.
    public static func isQuestion(_ prompt: String) -> Bool {
        let lower = prompt.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = #"\b(?:crea|creare|aggiungi|aggiungere|aggiungici|metti|mettici|inserisci|sposta|spostal[aoie]|anticipa|posticipa|rimanda|rimandal[aoie]|elimina|eliminal[aoie]|cancella|cancellal[aoie]|manda|mandagli|mandale|invia|inviagli|scrivi|scrivigli|scrivile|rispondi|rispondigli|rispondile|inoltra|inoltral[aoie]|segna|completa|completal[aoie]|apri|cerca|trova|fissa|prenota|ricordami|programma|genera|chiama|chiamal[aoie]|salva|condividi|registra|trascrivi)\b"#
        if lower.range(of: actions, options: .regularExpression) != nil { return false }
        if lower.hasSuffix("?") { return true }
        return lower.range(of: #"^(?:riassumi|riassumil[aoie]|riassunto|traduci|traducil[aoie]|spiega|spiegal[aoie]|correggi|analizza|sintetizza|leggi|leggil[aoie]|elenca|dimmi|di cosa|cosa|chi|quando|dove|quanto|quanti|quante|qual|quali|perch|come|c'è|ci sono|ha |hanno )"#,
                           options: .regularExpression) != nil
    }

    /// Testo da aggiungere alla nota aperta: «aggiungi il latte qui», «scrivi in questa nota che domani c'è sciopero».
    public static func noteLines(from prompt: String) -> [String] {
        var text = prompt.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)^(?:aggiungi|aggiungici|aggiungere|metti|mettici|inserisci|scrivi|scrivici|annota|appunta|segna)\s+"#,
            #"(?i)\s*\b(?:qui|qua|in fondo|in questa nota|a questa nota|su questa nota|nella nota(?: aperta)?|alla nota(?: aperta)?|sulla nota(?: aperta)?)\b\s*[:,]?\s*"#,
            #"(?i)^che\s+"#,
        ]
        for pattern in patterns { text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":,.")))
        text = text.replacingOccurrences(of: #"(?i)^che\s+"#, with: "", options: .regularExpression)
        return text.isEmpty ? [] : NoteAddition.items(text)
    }
}

extension ScreenItem.Kind {
    /// Come si chiama nella frase.
    public var noun: String {
        switch self {
        case .email: "email"
        case .note: "nota"
        case .event: "evento"
        case .reminder: "promemoria"
        case .contact: "contatto"
        case .chat: "conversazione"
        case .file: "file"
        case .memo: "registrazione"
        case .overview: "vista"
        }
    }

    /// Parole con cui l'utente indica l'elemento («questa email», «questa riunione»…).
    var words: [String] {
        switch self {
        case .email: ["email", "e-mail", "mail", "posta"]
        case .note: ["nota", "note", "appunto", "appunti"]
        case .event: ["evento", "riunione", "appuntamento", "impegno", "incontro", "call", "meeting", "cena", "pranzo"]
        case .reminder: ["promemoria", "attività", "cosa da fare"]
        case .contact: ["contatto", "persona", "scheda", "numero"]
        case .chat: ["conversazione", "chat", "messaggi", "messaggio"]
        case .file: ["file", "documento", "pdf", "foglio", "immagine", "foto", "testo"]
        case .memo: ["registrazione", "memo", "audio", "vocale", "trascrizione"]
        case .overview: []
        }
    }
}
