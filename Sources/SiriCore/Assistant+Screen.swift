import Foundation

extension Assistant {
    // MARK: - Ciò che l'utente vede
    //
    // L'elemento della scheda davanti (work.screen) diventa «quello di cui si parla» quando l'utente lo indica
    // («questa email», «qui», «riassumila») o lo ha appena selezionato: le azioni lo usano come destinatario o bersaglio,
    // le risposte lo leggono. Vale per Apple Intelligence e per i modelli esterni (stesso preambolo, stesse regole).

    /// Da chiamare quando l'interfaccia aggiorna il contesto per una nuova richiesta: la selezione è nuova se è cambiata
    /// dalla richiesta precedente (o se la chat è appena cominciata).
    public func updateScreen() {
        guard let item = work.screen else {
            previousScreen = nil
            screenFresh = false
            return
        }
        screenFresh = item.identity != previousScreen || turns.isEmpty
        previousScreen = item.identity
    }

    /// Quale elemento indica la richiesta, e quali elementi diventano quelli di cui si parla (idempotente: lo chiedono
    /// sia le regole sia il motore).
    /// La richiesta parla di ciò che è aperto nelle app («riassumi questa email»): dopo `decidedByRules`.
    public var pointsAtScreen: Bool { screenPointed }

    func prepareScreen(for prompt: String) {
        screenFocus = nil
        screenPointed = false
        guard let item = work.screen else { return }
        let reference = item.reference(in: prompt)
        // In una chat di progetto un file o una cartella nominati vincono sui riferimenti vaghi a ciò che è aperto nelle app
        // («riassumi TASKS.md» con una nota aperta parla del file).
        let projectNamed = work.guide?.namesSomething(in: prompt) ?? false
        screenPointed = reference == .strong || (reference == .weak && screenFresh && !projectNamed)
        // Una domanda che parla di ciò che si vede senza indicarlo («quanto pago di affitto?» con il contratto aperto,
        // «cosa devo fare per il lancio?» con la nota «Lancio sito»): il testo entra nel contesto, decide il pianificatore.
        if screenPointed || (!projectNamed && item.kind != .overview && ScreenItem.isQuestion(prompt) && Self.mentions(prompt, item)) { screenFocus = item }
        // Appena selezionato, o indicato: «inoltrala a Giulia», «spostalo alle 16», «completalo».
        guard screenFresh || screenFocus != nil else { return }
        if let mail = item.mail { recentMail = mail; pendingReply = nil }
        if let event = item.event { recentEvent = event }
        if let reminder = item.reminder { recentReminder = reminder }
        if let focus = screenFocus { Agent.log("SCHERMO: \(focus.headline)") }
    }

    /// Comandi sull'elemento sullo schermo che le regole sanno eseguire senza pianificatore.
    func screenAction(_ prompt: String) -> Plan? {
        guard !Self.isAnswerOnlyInstruction(prompt) else { return nil }
        guard let item = work.screen, item.kind != .overview else { return nil }
        let text = CommandText.clean(prompt).lowercased().replacingOccurrences(of: "’", with: "'")
        func starts(_ pattern: String) -> Bool { text.range(of: "^(?:" + pattern + #")\b"#, options: .regularExpression) != nil }
        let pointed = screenPointed
        let mailWords = text.range(of: #"\b(?:e-?mail|mail|posta)\b"#, options: .regularExpression) != nil
        let name = item.recipientName ?? item.title
        if Language.isEnglish, let plan = englishScreenAction(item, text: text, prompt: prompt) { return plan }
        switch item.kind {
        case .email:
            // «Rispondi che va bene»: all'email aperta, non a una persona nominata («rispondi a Marco…» cerca la sua).
            if starts("rispondi|rispondigli|rispondile|rispondere"), pointed || MailRequest.parse(prompt)?.person == nil {
                // «Rispondi che va bene e che porto i documenti»: ciò che segue è il senso della risposta.
                let gist = MailRequest.parse(prompt)?.message ?? CommandText.clean(prompt).replacingOccurrences(
                    of: #"(?i)^(?:rispondi|rispondigli|rispondile|rispondere)(?:\s+a\s+(?:questa|quest'|quella)\s*(?:e-?mail|mail))?\s*(?:[:,]\s*)?(?:dicendo(?:gli|le)?\s+)?(?:che\s+)?"#,
                    with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                return Plan(action: .rispondi_email, fields: gist.isEmpty ? [:] : ["testo": gist])
            }
            if starts("inoltra|inoltral[aoie]|inoltrare") { return Plan(action: .inoltra_email, fields: [:]) }
        case .chat:
            // «Rispondi che arrivo»: nella conversazione aperta.
            if !mailWords, starts("rispondi|rispondigli|rispondile|scrivi|scrivigli|scrivile|digli|dille|manda|mandagli|mandale|invia|inviagli|inviale") {
                return Plan(action: .invia_messaggio, fields: ["destinatari": name])
            }
        case .contact:
            let clitic = starts("scrivigli|scrivile|mandagli|mandale|digli|dille|inviagli|inviale")
            guard pointed || clitic else { return nil }
            if mailWords, starts("scrivi|scrivigli|scrivile|manda|mandagli|mandale|invia|inviagli|inviale|prepara") {
                return Plan(action: .scrivi_email, fields: ["destinatari": item.email ?? name])
            }
            if clitic || (text.contains("messaggio") && starts("scrivi|manda|invia|prepara")) {
                return Plan(action: .invia_messaggio, fields: ["destinatari": name])
            }
        case .note:
            // «Aggiungi il latte qui», «scrivi in questa nota che…», «aggiungi alla nota: …» (senza il nome di un'altra nota).
            let otherNote = text.range(of: #"\b(?:alla|nella|sulla) nota\s+(?:del|della|dello|dei|delle|di|chiamata|intitolata|che si chiama)\b"#,
                                       options: .regularExpression) != nil
            let thisNote = pointed || text.range(of: #"\b(?:alla|nella|sulla) nota\b"#, options: .regularExpression) != nil
            if starts("aggiungi|aggiungici|metti|mettici|inserisci|scrivi|scrivici|annota|appunta"), thisNote, !otherNote, let id = item.reference {
                return Plan(action: .modifica_nota, fields: ["scelta": id])
            }
        case .event:
            guard pointed, let event = item.event else { return nil }
            let choice = "\(event.identifier)|\(event.start.timeIntervalSince1970)"
            if starts("elimina|eliminal[aoie]|cancella|cancellal[aoie]|annulla|annullal[aoie]|togli|rimuovi|disdici") {
                return Plan(action: .elimina_evento, fields: ["scelta": choice])
            }
            if starts("sposta|spostal[aoie]|anticipa|anticipal[aoie]|posticipa|posticipal[aoie]|rimanda|rimandal[aoie]|rinvia|rinvial[aoie]|ritarda|allunga|accorcia|prolunga|rinomina|rinominal[aoie]|cambia|modifica") {
                return Plan(action: .modifica_evento, fields: ["scelta": choice])
            }
        case .reminder:
            guard pointed || screenFresh, let reminder = item.reminder else { return nil }
            if starts("completa|completal[aoie]|spunta|spuntal[aoie]") || (starts("segna|segnal[aoie]") && text.contains("fatt")) {
                return Plan(action: .completa_promemoria, fields: ["scelta": reminder.id])
            }
            if pointed, starts("elimina|eliminal[aoie]|cancella|cancellal[aoie]|togli|rimuovi") {
                return Plan(action: .elimina_promemoria, fields: ["scelta": reminder.id])
            }
            if starts("sposta|spostal[aoie]|rimanda|rimandal[aoie]|rinvia|rinvial[aoie]|posticipa|posticipal[aoie]|anticipa|anticipal[aoie]|rinomina|rinominal[aoie]|cambia|modifica|segna|segnal[aoie]") {
                return Plan(action: .modifica_promemoria, fields: ["scelta": reminder.id])
            }
        default:
            break
        }
        return nil
    }

    /// Gli stessi comandi in inglese: «reply that it's fine», «forward it to Julia», «add milk here», «send him a message»,
    /// «move it to 4 pm», «delete this event», «complete it», «mark it as done».
    private func englishScreenAction(_ item: ScreenItem, text: String, prompt: String) -> Plan? {
        func starts(_ pattern: String) -> Bool { text.range(of: "^(?:" + pattern + #")\b"#, options: .regularExpression) != nil }
        // «Answer only yes or no», «reply briefly»: istruzioni sulla risposta, non una risposta a qualcuno.
        guard !starts(#"(?:reply|answer|respond)\s+(?:only|just|simply|briefly)"#) else { return nil }
        let pointed = screenPointed
        let mailWords = text.range(of: #"\b(?:e-?mails?|mails?)\b"#, options: .regularExpression) != nil
        let name = item.recipientName ?? item.title
        switch item.kind {
        case .email:
            // «Reply that it's fine»: all'email aperta, non a una persona nominata («reply to Mark…» cerca la sua).
            if starts(#"reply|respond|answer|write\s+back"#), pointed || MailRequest.parse(prompt)?.person == nil {
                let gist = MailRequest.parse(prompt)?.message ?? CommandText.clean(prompt).replacingOccurrences(
                    of: #"(?i)^(?:reply|respond|answer|write\s+back)(?:\s+(?:to\s+)?(?:all|everyone|everybody))?(?:\s+to\s+(?:this|that|the)\s+(?:e-?mail|mail|message))?(?:\s+to\s+(?:him|her|them))?\s*(?:[:,]\s*)?(?:(?:saying|telling\s+(?:him|her|them)|and\s+say|and\s+tell\s+(?:him|her|them))\s+)?(?:that\s+)?"#,
                    with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                return Plan(action: .rispondi_email, fields: gist.isEmpty ? [:] : ["testo": gist])
            }
            if starts("forward|fwd") { return Plan(action: .inoltra_email, fields: [:]) }
        case .chat:
            // «Reply that I'll be there»: nella conversazione aperta.
            if !mailWords, starts(#"reply|respond|answer|write\s+back|write\s+(?:to\s+)?(?:him|her|them)|write\s+that|text\s+(?:him|her|them)|tell\s+(?:him|her|them)|send\s+(?:him|her|them)|send\s+(?:a|the)\s+(?:message|text|reply)|message\s+(?:him|her|them)|say"#) {
                return Plan(action: .invia_messaggio, fields: ["destinatari": name])
            }
        case .contact:
            let clitic = starts(#"(?:write|send|text|message|email|e-mail|tell)\s+(?:to\s+)?(?:him|her|them)"#)
            guard pointed || clitic else { return nil }
            if mailWords, starts(#"write|send|email|e-mail|prepare|draft"#) {
                return Plan(action: .scrivi_email, fields: ["destinatari": item.email ?? name])
            }
            if clitic || (text.range(of: #"\b(?:message|text)\b"#, options: .regularExpression) != nil && starts(#"write|send|prepare|draft"#)) {
                return Plan(action: .invia_messaggio, fields: ["destinatari": name])
            }
        case .note:
            // «Add milk here», «write in this note that…», «add to the note: …» (senza il nome di un'altra nota).
            let otherNote = text.range(of: #"\b(?:to|in|into|on)\s+(?:the|my)\s+note\s+(?:called|named|titled|about)\b|\b(?:to|in|into|on)\s+(?:the|my)\s+(?!(?:open|current|selected|same)\b)[\w'-]+(?:\s+[\w'-]+)?\s+note\b"#,
                                       options: .regularExpression) != nil
            let thisNote = pointed || text.range(of: #"\b(?:to|in|into|on)\s+(?:the\s+)?note\b"#, options: .regularExpression) != nil
            if starts(#"add|append|put|insert|write|type|jot|note"#), thisNote, !otherNote, let id = item.reference {
                return Plan(action: .modifica_nota, fields: ["scelta": id])
            }
        case .event:
            guard pointed, let event = item.event else { return nil }
            let choice = "\(event.identifier)|\(event.start.timeIntervalSince1970)"
            if starts(#"delete|cancel|remove|erase|call\s+off|drop|clear"#) {
                return Plan(action: .elimina_evento, fields: ["scelta": choice])
            }
            if starts(#"move|reschedule|postpone|push|delay|bring|shift|put\s+off|extend|lengthen|prolong|shorten|rename|retitle|change|edit|modify|update|make\s+it|set\s+it"#) {
                return Plan(action: .modifica_evento, fields: ["scelta": choice])
            }
        case .reminder:
            guard pointed || screenFresh, let reminder = item.reminder else { return nil }
            if starts(#"complete|finish|check\s+off|tick\s+off|cross\s+off|check\b.*\boff|tick\b.*\boff|cross\b.*\boff"#)
                || (starts("mark|set") && text.range(of: #"(?<!not\s)\b(?:done|complete|completed|finished)\b"#, options: .regularExpression) != nil) {
                return Plan(action: .completa_promemoria, fields: ["scelta": reminder.id])
            }
            if pointed, starts(#"delete|remove|cancel|erase|clear"#) {
                return Plan(action: .elimina_promemoria, fields: ["scelta": reminder.id])
            }
            if starts(#"move|reschedule|postpone|push|delay|bring|shift|rename|retitle|change|edit|modify|update|mark|flag|set\s+it|make\s+it"#) {
                return Plan(action: .modifica_promemoria, fields: ["scelta": reminder.id])
            }
        default:
            break
        }
        return nil
    }

    /// La richiesta nomina ciò che si vede: una parola del titolo, o almeno due del testo.
    static func mentions(_ prompt: String, _ item: ScreenItem) -> Bool {
        let words = significant(MemoryStore.keywords(prompt)).subtracting(Language.isEnglish ? englishEmptyWords : [])
        guard !words.isEmpty else { return false }
        if !words.isDisjoint(with: significant(MemoryStore.keywords(item.title))) { return true }
        return words.intersection(significant(MemoryStore.keywords(String(item.text.prefix(4000))))).count >= 2
    }

    /// Parole inglesi che non dicono di cosa si parla («what», «with», «this»…): non rendono pertinente ciò che si vede.
    nonisolated static let englishEmptyWords: Set<String> = ["what", "with", "this", "that", "these", "those", "have", "does", "from",
        "about", "there", "their", "they", "them", "then", "than", "your", "will", "when", "where", "which", "would", "could", "should",
        "into", "onto", "some", "much", "many", "more", "most", "also", "just", "only", "very", "been", "being", "were", "here", "over",
        "after", "before", "today", "tomorrow", "yesterday", "please", "thanks", "tell", "show", "give", "want", "need", "know", "like",
        "make", "doing", "done", "other", "again", "still", "every", "each", "same", "such", "time", "year", "years", "days",
        "thing", "things", "good", "well", "really", "maybe", "okay", "sure", "going", "come", "said", "says", "wrote", "sent"]

    /// Il testo sullo schermo come materiale per chi scrive («fai un documento da questa nota»), tra i delimitatori dei dati di terzi.
    func screenMaterial(limit: Int) -> String? {
        guard let focus = screenFocus, !focus.text.isEmpty else { return nil }
        return Self.untrusted(String(focus.text.prefix(limit)), label: focus.headline)
    }

    /// Righe per il preambolo: ciò che è davanti (con il testo se la richiesta ne parla) e le altre schede aperte.
    func screenPreamble() -> [String] {
        var lines: [String] = []
        if let item = work.screen {
            if let focus = screenFocus, let material = screenMaterial(limit: budget.scaled(2200)) {
                lines.append(Language.t("Sullo schermo, nella scheda davanti: ", "On screen, in the front tab: ") + "\(focus.headline).\n\(material)")
            } else if screenPointed {
                lines.append(Language.t("Sullo schermo, nella scheda davanti: ", "On screen, in the front tab: ") + "\(item.headline).")
            } else {
                lines.append(Language.t("Sullo schermo, nella scheda davanti (usalo solo se la richiesta ne parla): ",
                                        "On screen, in the front tab (use it only if the request is about it): ") + "\(item.headline).")
            }
        }
        if !work.openTabs.isEmpty {
            lines.append(Language.t("Altre schede aperte in Siri AI+ (solo se servono): ", "Other tabs open in Siri AI+ (only if needed): ")
                         + work.openTabs.prefix(6).joined(separator: "; ") + ".")
        }
        return lines
    }

    /// Una riga per il pianificatore: cosa c'è sullo schermo e, se la richiesta lo indica, l'inizio del suo testo
    /// (per «crea un evento da questa email» servono data e ora scritte lì).
    func screenPlannerNote(compact: Bool) -> String? {
        // Solo se la richiesta ne parla: altrimenti spingerebbe il pianificatore verso l'app aperta.
        guard let focus = screenFocus else { return nil }
        let material = screenMaterial(limit: compact ? 400 : 900).map { "\n\($0)" } ?? ""
        // Una domanda su ciò che si vede si risponde leggendolo: niente agenda, posta o web.
        let hint = ScreenItem.isQuestion(lastRequest)
            ? Language.t(" Se la domanda riguarda questo contenuto, l'azione è rispondi.", " If the question is about this content, the action is rispondi.") : ""
        return Language.t("Sullo schermo (l'utente ne parla): ", "On screen (the user is talking about it): ") + "\(focus.headline)\(material)\(hint)"
    }

    /// Contatto (o mittente dell'email) sullo schermo: l'indirizzo dell'email è già noto.
    func screenEmailAddress(for recipients: String?) -> String? {
        guard let item = work.screen, [.contact, .email].contains(item.kind), let address = item.email else { return nil }
        let name = (item.recipientName ?? item.title).lowercased()
        let lower = (recipients ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if lower.isEmpty { return screenPointed ? address : nil }
        guard lower == address.lowercased() || lower == name || name.hasPrefix(lower) || ["lui", "lei", "gli", "le", "him", "her", "them"].contains(lower) else { return nil }
        return address
    }

    /// Contatto o conversazione sullo schermo: il recapito del messaggio è già noto.
    func screenHandle(for recipient: String) -> (name: String, handle: String)? {
        guard let item = work.screen, [.contact, .chat].contains(item.kind), let handle = item.phone ?? item.email else { return nil }
        let name = item.recipientName ?? item.title
        let lower = recipient.lowercased().trimmingCharacters(in: .whitespaces)
        guard lower.isEmpty || ["lui", "lei", "loro", "gli", "le", "him", "her", "them"].contains(lower) || lower == name.lowercased()
                || name.lowercased().hasPrefix(lower) || screenPointed else { return nil }
        return (name, handle)
    }
}
