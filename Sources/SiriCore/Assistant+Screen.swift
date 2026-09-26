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
        guard let item = work.screen, item.kind != .overview else { return nil }
        let text = CommandText.clean(prompt).lowercased().replacingOccurrences(of: "’", with: "'")
        func starts(_ pattern: String) -> Bool { text.range(of: "^(?:" + pattern + #")\b"#, options: .regularExpression) != nil }
        let pointed = screenPointed
        let mailWords = text.range(of: #"\b(?:e-?mail|mail|posta)\b"#, options: .regularExpression) != nil
        let name = item.recipientName ?? item.title
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

    /// La richiesta nomina ciò che si vede: una parola del titolo, o almeno due del testo.
    static func mentions(_ prompt: String, _ item: ScreenItem) -> Bool {
        let words = significant(MemoryStore.keywords(prompt))
        guard !words.isEmpty else { return false }
        if !words.isDisjoint(with: significant(MemoryStore.keywords(item.title))) { return true }
        return words.intersection(significant(MemoryStore.keywords(String(item.text.prefix(4000))))).count >= 2
    }

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
                lines.append("Sullo schermo, nella scheda davanti: \(focus.headline).\n\(material)")
            } else if screenPointed {
                lines.append("Sullo schermo, nella scheda davanti: \(item.headline).")
            } else {
                lines.append("Sullo schermo, nella scheda davanti (usalo solo se la richiesta ne parla): \(item.headline).")
            }
        }
        if !work.openTabs.isEmpty {
            lines.append("Altre schede aperte in Siri AI+ (solo se servono): " + work.openTabs.prefix(6).joined(separator: "; ") + ".")
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
        let hint = ScreenItem.isQuestion(lastRequest) ? " Se la domanda riguarda questo contenuto, l'azione è rispondi." : ""
        return "Sullo schermo (l'utente ne parla): \(focus.headline)\(material)\(hint)"
    }

    /// Contatto (o mittente dell'email) sullo schermo: l'indirizzo dell'email è già noto.
    func screenEmailAddress(for recipients: String?) -> String? {
        guard let item = work.screen, [.contact, .email].contains(item.kind), let address = item.email else { return nil }
        let name = (item.recipientName ?? item.title).lowercased()
        let lower = (recipients ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if lower.isEmpty { return screenPointed ? address : nil }
        guard lower == address.lowercased() || lower == name || name.hasPrefix(lower) || ["lui", "lei", "gli", "le"].contains(lower) else { return nil }
        return address
    }

    /// Contatto o conversazione sullo schermo: il recapito del messaggio è già noto.
    func screenHandle(for recipient: String) -> (name: String, handle: String)? {
        guard let item = work.screen, [.contact, .chat].contains(item.kind), let handle = item.phone ?? item.email else { return nil }
        let name = item.recipientName ?? item.title
        let lower = recipient.lowercased().trimmingCharacters(in: .whitespaces)
        guard lower.isEmpty || ["lui", "lei", "loro", "gli", "le"].contains(lower) || lower == name.lowercased()
                || name.lowercased().hasPrefix(lower) || screenPointed else { return nil }
        return (name, handle)
    }
}
