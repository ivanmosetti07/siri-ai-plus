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
        let main = kind == .overview ? title : "\(kind.noun) " + (Language.isEnglish ? "“\(title)”" : "«\(title)»")
        return "\(app): \(main)" + (details.isEmpty ? "" : " (\(details))")
    }

    /// Quanto la richiesta parla di ciò che è sullo schermo: «questa email», «qui», «che vedo» (forte);
    /// «riassumilo», «il suo numero», «riassumi» da solo (debole: vale se l'utente l'ha appena selezionato).
    /// In inglese valgono anche «this email», «here», «summarize it», «who sent it?».
    public func reference(in prompt: String) -> Reference {
        let italian = italianReference(in: prompt)
        guard Language.isEnglish, italian != .strong else { return italian }
        return max(italian, englishReference(in: prompt))
    }

    private func italianReference(in prompt: String) -> Reference {
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

    private func englishReference(in prompt: String) -> Reference {
        let lower = " " + prompt.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        let words = (kind == .overview ? Self.englishNouns(nouns) : kind.englishWords).map { NSRegularExpression.escapedPattern(for: $0) }
        if !words.isEmpty {
            let noun = "(?:" + words.joined(separator: "|") + ")(?:s|es)?"
            // «this email», «these notes», «the open email», «the selected note», «the email I'm looking at».
            if has(#"\b(?:this|these)\s+"# + noun + #"\b"#) { return .strong }
            if has(#"\b(?:open|opened|selected|current|highlighted)\s+"# + noun + #"\b"#) { return .strong }
            if has(#"\b"# + noun + #"\s+(?:(?:that\s+)?i(?:'m|\s+am)\s+(?:looking\s+at|reading|viewing|seeing)|(?:that\s+)?i\s+(?:see|have\s+open)|on\s+(?:the\s+|my\s+)?screen|in\s+front\s+of\s+me)\b"#) { return .strong }
        }
        if has(#"\b(?:here|on\s+(?:the\s+|my\s+)?screen|in\s+front\s+of\s+me|what\s+i(?:'m|\s+am)\s+(?:looking\s+at|seeing|reading)|what\s+i\s+see)\b"#) { return .strong }
        guard kind != .overview else { return .none }
        // Dimostrativo senza nome, non di tempo («this week», «this morning» parlano di date).
        let times = #"(?:week|month|year|evening|morning|afternoon|night|weekend|time|moment|period|day|monday|tuesday|wednesday|thursday|friday|saturday|sunday|summer|winter|autumn|fall|spring|quarter|semester|season)"#
        if has(#"\b(?:this|these)\b(?!\s+"# + times + #"\b)"#) { return .weak }
        // Verbi con il pronome: «summarize it», «reply to him», «move it», «send him».
        if has(#"\b(?:summari[sz]e|translate|read|explain|correct|fix|proofread|analy[sz]e|reply\s+to|respond\s+to|answer|forward|move|postpone|reschedule|push|delay|rename|delete|cancel|remove|complete|finish|call|text|message|email|write(?:\s+to)?|tell|send|open|mark|check|tick)\s+(?:it|him|her|them)\b"#) {
            return .weak
        }
        if kind == .contact, has(#"\b(?:his|her|their)\b"#) { return .weak }
        // «Summarize», «translate into Italian», «what is it about?» da soli.
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = trimmed.split(separator: " ").count <= 4
        if short, trimmed.range(of: #"^(?:summari[sz]e|summary|sum\s+up|translate|explain|correct|proofread|fix|analy[sz]e|what(?:'s|\s+is)\s+it\s+about|what\s+does\s+it\s+say|what's\s+written|what\s+is\s+written|who\s+sent\s+it|who\s+wrote\s+it|who(?:'s|\s+is)\s+it\s+from|tl;?dr)"#,
                                options: .regularExpression) != nil {
            return .weak
        }
        return .none
    }

    /// Parole inglesi per ciò che l'app mostra quando non c'è una selezione: quelle date dall'app e la loro traduzione.
    static func englishNouns(_ nouns: [String]) -> [String] {
        let translations = ["posta": "mail", "messaggi": "messages", "messaggio": "message", "nota": "note", "note": "notes",
                            "evento": "event", "eventi": "events", "promemoria": "reminders", "contatto": "contact", "contatti": "contacts",
                            "conversazione": "conversation", "conversazioni": "conversations", "documento": "document",
                            "documenti": "documents", "registrazione": "recording", "registrazioni": "recordings",
                            "appuntamenti": "appointments", "riunioni": "meetings", "attività": "tasks", "immagini": "images",
                            "cartella": "folder", "cartelle": "folders"]
        return nouns + nouns.compactMap { translations[$0.lowercased()] }
    }

    /// Una domanda o un'elaborazione di ciò che si vede («riassumi», «chi l'ha mandata?», «traduci»),
    /// non un'azione (creare, spostare, mandare, rispondere…): si risponde leggendo l'elemento.
    public static func isQuestion(_ prompt: String) -> Bool {
        let lower = prompt.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = #"\b(?:crea|creare|aggiungi|aggiungere|aggiungici|metti|mettici|inserisci|sposta|spostal[aoie]|anticipa|posticipa|rimanda|rimandal[aoie]|elimina|eliminal[aoie]|cancella|cancellal[aoie]|manda|mandagli|mandale|invia|inviagli|scrivi|scrivigli|scrivile|rispondi|rispondigli|rispondile|inoltra|inoltral[aoie]|segna|completa|completal[aoie]|apri|cerca|trova|fissa|prenota|ricordami|programma|genera|chiama|chiamal[aoie]|salva|condividi|registra|trascrivi)\b"#
        if lower.range(of: actions, options: .regularExpression) != nil { return false }
        // In inglese il comando è all'inizio o dopo «and», «then» («summarize it and send it to Julia»).
        if Language.isEnglish, lower.range(of: englishActions, options: .regularExpression) != nil { return false }
        if lower.hasSuffix("?") { return true }
        return lower.range(of: #"^(?:riassumi|riassumil[aoie]|riassunto|traduci|traducil[aoie]|spiega|spiegal[aoie]|correggi|analizza|sintetizza|leggi|leggil[aoie]|elenca|dimmi|di cosa|cosa|chi|quando|dove|quanto|quanti|quante|qual|quali|perch|come|c'è|ci sono|ha |hanno )"#,
                           options: .regularExpression) != nil
            || (Language.isEnglish && lower.range(of: englishQuestion, options: .regularExpression) != nil)
    }

    static let englishActions = #"(?:^|\b(?:and|then|also)\s+)(?:(?:please|can\s+you|could\s+you|would\s+you|will\s+you)\s+)*(?:create|make|add|put|insert|move|postpone|reschedule|delay|push|delete|cancel|remove|send|text|email|write|reply|respond|answer|forward|mark|complete|check\s+off|tick\s+off|open|search|find|look\s+up|book|schedule|set\s+up|remind|generate|call|save|share|record|transcribe|rename|change|edit|update|draft|prepare|turn|convert|archive|print)\b"#
    static let englishQuestion = #"^(?:summari[sz]e|summary|sum\s+up|translate|explain|correct|proofread|fix|analy[sz]e|read|list|tell\s+me|give\s+me|what|who|whom|whose|when|where|which|why|how|is\s|are\s|was\s|were\s|does\s|do\s|did\s|has\s|have\s|any\s)"#

    /// Testo da aggiungere alla nota aperta: «aggiungi il latte qui», «scrivi in questa nota che domani c'è sciopero».
    public static func noteLines(from prompt: String) -> [String] {
        var text = prompt.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)^(?:aggiungi|aggiungici|aggiungere|metti|mettici|inserisci|scrivi|scrivici|annota|appunta|segna)\s+"#,
            #"(?i)\s*\b(?:qui|qua|in fondo|in questa nota|a questa nota|su questa nota|nella nota(?: aperta)?|alla nota(?: aperta)?|sulla nota(?: aperta)?)\b\s*[:,]?\s*"#,
            #"(?i)^che\s+"#,
        ]
        for pattern in patterns { text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        // In inglese: «add milk here», «add to this note: milk», «write here that there's a strike tomorrow».
        if Language.isEnglish {
            let english = [
                #"(?i)^\s*(?:add|append|put|insert|write|type|jot(?:\s+down)?|note(?:\s+down)?)\s+"#,
                #"(?i)\s*\b(?:here|at\s+the\s+(?:end|bottom)|(?:to|in|into|on|onto)\s+(?:this|the|the\s+open|the\s+current|the\s+selected)\s+note(?:\s+(?:that's|that\s+is)\s+open)?)\b\s*[:,]?\s*"#,
                #"(?i)^\s*that\s+"#,
            ]
            for pattern in english { text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":,.")))
        text = text.replacingOccurrences(of: #"(?i)^che\s+"#, with: "", options: .regularExpression)
        if Language.isEnglish { text = text.replacingOccurrences(of: #"(?i)^that\s+"#, with: "", options: .regularExpression) }
        return text.isEmpty ? [] : NoteAddition.items(text)
    }
}

extension ScreenItem.Kind {
    /// Come si chiama nella frase.
    public var noun: String {
        switch self {
        case .email: "email"
        case .note: Language.t("nota", "note")
        case .event: Language.t("evento", "event")
        case .reminder: Language.t("promemoria", "reminder")
        case .contact: Language.t("contatto", "contact")
        case .chat: Language.t("conversazione", "conversation")
        case .file: "file"
        case .memo: Language.t("registrazione", "recording")
        case .overview: Language.t("vista", "view")
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

    /// Parole inglesi con cui l'utente indica l'elemento («this email», «this meeting»…).
    var englishWords: [String] {
        switch self {
        case .email: ["email", "e-mail", "mail", "message"]
        case .note: ["note"]
        case .event: ["event", "meeting", "appointment", "call", "dinner", "lunch", "commitment"]
        case .reminder: ["reminder", "task", "to-do", "todo"]
        case .contact: ["contact", "person", "card", "number"]
        case .chat: ["conversation", "chat", "thread", "message"]
        case .file: ["file", "document", "pdf", "sheet", "spreadsheet", "image", "photo", "picture", "text"]
        case .memo: ["recording", "memo", "voice memo", "audio", "transcript", "transcription"]
        case .overview: []
        }
    }
}
