import Foundation
import FoundationModels

/// Cambiamenti a ciò che esiste già: spostare o rinominare un evento, modificare o eliminare un promemoria,
/// aggiungere a una nota, rispondere o inoltrare un'email. L'elemento si trova dalla frase (o dall'elenco appena mostrato);
/// ogni cambiamento diventa una scheda che l'utente conferma.
extension Assistant {
    /// Più elementi corrispondono: la risposta successiva ("la seconda", "quella delle 10") sceglie.
    struct PendingChoice {
        struct Option {
            let identifier: String
            let title: String
            let date: Date?
        }
        let action: Action
        let prompt: String
        let options: [Option]
    }

    enum Lookup<Item> {
        case found(Item), several([Item]), missing
    }

    /// C'è una domanda in sospeso ("quale riunione?", "cosa rispondo?"): la prossima richiesta va a questo motore, qualunque sia il modello.
    public var awaitsAnswer: Bool { pendingChoice != nil || pendingReply != nil }

    /// Comando chiaro su un evento, un promemoria, una nota o un'email che esistono già: lo esegue l'app con le sue regole.
    public func isChangeCommand(_ prompt: String) -> Bool {
        if work.artifactKind != nil, Self.isArtifactCommand(prompt) { return false }
        return Self.changeAction(prompt).map(availableActions.contains) ?? false
    }

    /// Richieste che decidono le regole dell'app, qualunque sia il modello scelto: risposte a una domanda di prima,
    /// comandi sul documento aperto, documenti con il testo dettato, cambiamenti a eventi, promemoria, note ed email.
    /// Il modello scelto scrive poi le risposte; le regole si ottimizzano su Apple Intelligence, il modello più debole.
    public func decidedByRules(_ prompt: String) -> Bool {
        if awaitsAnswer { return true }
        // Comandi su ciò che è sullo schermo («rispondi che va bene», «spostalo alle 16»): li esegue l'app.
        prepareScreen(for: prompt)
        if screenAction(prompt) != nil { return true }
        if work.artifactKind != nil, !Self.isArtifactQuestion(prompt), Self.isArtifactCommand(prompt) { return true }
        if Self.literalDocumentText(prompt) != nil { return true }
        // «Ricordati che…» lo salva l'app con tutti i modelli (prima con ChatGPT e Claude dipendeva dal modello e dallo strumento).
        if Self.explicitlyRemembers(prompt) { return true }
        return isChangeCommand(prompt)
    }

    /// La richiesta risponde a una domanda di prima? Allora riprende quell'azione con l'elemento scelto.
    func resumePending(_ prompt: String) -> (plan: Plan, prompt: String)? {
        if let choice = pendingChoice {
            pendingChoice = nil
            if let index = ChoiceMatcher.pick(prompt, options: choice.options.map { ($0.title, $0.date) }) {
                return (Plan(action: choice.action, fields: ["scelta": choice.options[index].identifier]), choice.prompt)
            }
        }
        if let mail = pendingReply {
            pendingReply = nil
            let lower = prompt.lowercased()
            let english = Language.isEnglish
            // Un comando nuovo o una domanda non sono il testo della risposta.
            let dictated = lower.range(of: #"^(?:digli|dille|scrivi(?:gli|le)|rispondi(?:gli|le)?|di'|dì)\b"#, options: .regularExpression) != nil
                || (english && lower.range(of: Self.englishDictation, options: .regularExpression) != nil)
            let command = Self.isCommand(prompt) || (english && lower.range(of: Self.englishCommand, options: .regularExpression) != nil)
            if !prompt.hasSuffix("?"), dictated || (!command && Self.changeAction(prompt) == nil) {
                var text = prompt.replacingOccurrences(of: #"(?i)^(?:digli|dille|scrivi(?:gli|le)|rispondi(?:gli|le)?|di'|dì)\s+(?:che\s+)?"#, with: "", options: .regularExpression)
                if english {
                    text = text.replacingOccurrences(of: "(?i)" + Self.englishDictation + #"\s*(?:[:,]\s*)?(?:that\s+)?"#, with: "", options: .regularExpression)
                }
                recentMail = mail
                return (Plan(action: .rispondi_email, fields: ["scelta": mail.id, "testo": text]),
                        Language.t("rispondi a \(mail.senderName): \(text)", "reply to \(mail.senderName): \(text)"))
            }
        }
        return nil
    }

    /// In inglese, il testo della risposta dettato dopo la domanda: «tell him I'll be there», «say that it's fine».
    static let englishDictation = #"^(?:tell\s+(?:him|her|them)|say|write\s+(?:(?:to\s+)?(?:him|her|them)|back)|reply(?:\s+to\s+(?:him|her|them))?|respond(?:\s+to\s+(?:him|her|them))?|answer(?:\s+(?:him|her|them))?)\b"#

    /// In inglese, un comando nuovo e non il testo di una risposta («create a note…», «remind me…»).
    static let englishCommand = #"^(?:create|open|search|look\s+up|find|show\s+me|schedule|remind\s+me|set\s+up|delete|cancel|remove|translate|summari[sz]e|move|forward|rename|generate|draw|export|save|make\s+(?:a|an|me)|write\s+(?:a|an)\s+(?:new\s+)?(?:email|e-mail|mail|note|document|message|text)|send\s+(?:a|an)\s+(?:new\s+)?(?:email|e-mail|mail|message|text)\s+to)\b"#

    /// Parole inglesi con la maiuscola che non sono il nome di chi ha scritto («Reply to This…»).
    static let englishNotNames: Set<String> = ["This", "That", "These", "Those", "All", "Everyone", "Everybody", "Me", "You", "Him", "Her",
                                               "Them", "It", "The", "My", "Your", "Our", "I"]

    /// Cose che non sono eventi: con queste parole «move», «delete», «rename» riguardano file, documenti, note o email.
    static let englishOthers = #"\b(?:files?|folders?|slides?|documents?|docs?|sheets?|spreadsheets?|presentations?|decks?|paragraphs?|sections?|rows?|lines?|columns?|cells?|notes?|e-?mails?|mails?|messages?|chats?|conversations?|memory|memories|agents?|projects?|images?|pictures?|photos?|pages?|sites?|websites?|deadlines?|due\s+dates?|alarms?|timers?)\b"#

    /// Nomi inglesi di eventi («the call with Luke», «the dinner with Sarah»).
    static let englishEventNouns = #"\b(?:meetings?|events?|appointments?|calls?|video\s?calls?|catch-?ups?|dinners?|lunch(?:es)?|breakfasts?|brunch(?:es)?|drinks|aperitifs?|visits?|lessons?|class(?:es)?|trainings?|workouts?|match(?:es)?|games?|interviews?|conferences?|webinars?|stand-?ups?|sessions?|part(?:y|ies)|syncs?|check-?ins?)\b"#

    /// Comandi chiari su eventi, promemoria, note ed email che esistono già: l'azione giusta senza chiedere al pianificatore.
    static func changeAction(_ prompt: String) -> Action? {
        let text = CommandText.clean(prompt)
        let lower = " " + DateExpressions.normalized(text) + " "
        let start = lower.trimmingCharacters(in: .whitespaces)
        let english = Language.isEnglish
        func starts(_ pattern: String) -> Bool { start.range(of: "^(?:" + pattern + #")\b"#, options: .regularExpression) != nil }

        if let request = MailRequest.parse(text), MailRequest.meansMessages(lower) {
            // "Rispondi a Marco su iMessage che…": un messaggio, non un'email (WhatsApp e Telegram l'app non li usa).
            return request.kind == .reply && !["whatsapp", "telegram"].contains(where: lower.contains) ? .invia_messaggio : nil
        }
        if let request = MailRequest.parse(text) {
            switch request.kind {
            case .forward: return .inoltra_email
            case .reply:
                // "Rispondi a questa domanda" non riguarda la posta: servono una parola della posta, un nome proprio o "rispondigli".
                let mailWords = [" email", " e-mail", " mail", " posta"].contains(where: lower.contains) || (english && lower.contains(" inbox"))
                let firstWord = request.person?.split(separator: " ").first.map(String.init) ?? ""
                let named = firstWord.first?.isUppercase == true && !["Questa", "Questo", "Quella", "Quello", "Tutti", "Tutte", "Me", "Te"].contains(firstWord)
                    && !(english && Self.englishNotNames.contains(firstWord))
                if mailWords || named || starts("rispondigli|rispondile") { return .rispondi_email }
                // «Reply to him that it's fine»: la persona è quella dell'email appena letta.
                if english, starts(#"(?:reply|respond|write\s+back)\s+to\s+(?:him|her|them)|answer\s+(?:him|her|them)"#) { return .rispondi_email }
            }
        }
        if NoteAddition.parse(text) != nil { return .modifica_nota }
        if english, let decided = Self.englishReminderAction(lower, starts: starts) { return decided }
        if lower.contains("promemoria") || lower.contains("scadenz") {
            if starts("togli|rimuovi|elimina|cancella") && lower.range(of: #"\b(?:scadenz|data|priorit|bandierin)"#, options: .regularExpression) != nil {
                return .modifica_promemoria
            }
            if starts("cancella|cancellare|elimina|eliminare|togli|rimuovi|cestina") { return .elimina_promemoria }
            if starts("segna|spunta|completa"), lower.range(of: #"\b(?:fatt[oa]|completat[oa]|finit[oa])\b"#, options: .regularExpression) != nil || starts("spunta|completa") {
                return .completa_promemoria
            }
            if starts("sposta|spostare|spostalo|rimanda|rimandalo|rinvia|posticipa|anticipa|cambia|modifica|rinomina|rinominalo|metti|imposta|aggiorna|segna|contrassegna") {
                return .modifica_promemoria
            }
            return nil
        }
        // Eventi: verbo di spostamento, rinomina o cancellazione + un evento (nome comune, giorno o ora), senza file, slide o note.
        let others = #"\b(?:file|cartell[ae]|slide|document\w*|fogli|foglio|presentazion\w*|paragraf\w*|sezion[ei]|rig[ah]e?|colonn[ae]|cell[ae]|not[ae]|e-?mail|mail|messaggi\w*|chat|conversazion\w*|memoria|agent[ei]|progett[oi]|immagin[ei]|pagin[ae]|sit[oi]|scadenz\w*|sveglia|timer)\b"#
        // In inglese il nuovo titolo tra virgolette («rename it to "Email review"») non conta.
        let othersText = english ? Self.withoutQuotes(lower) : lower
        guard othersText.range(of: others, options: .regularExpression) == nil else { return nil }
        if english, othersText.range(of: Self.englishOthers, options: .regularExpression) != nil { return nil }
        let nouns = ["riunion", "evento", "appuntament", " call ", "meeting", "incontro", "videochiamat", "cena", "pranzo", "colazione",
                     "aperitivo", "visita", "lezione", "allenamento", "partita", "colloquio", "conferenza", "webinar", "standup", "stand-up"]
        let hasEvent = nouns.contains(where: lower.contains) || (english && lower.range(of: Self.englishEventNouns, options: .regularExpression) != nil)
        let hasWhen = !DateExpressions.days(in: text).isEmpty || !DateExpressions.times(in: text).isEmpty || !DateExpressions.shifts(in: text).isEmpty
        if starts("sposta|spostare|spostala|spostalo|anticipa|anticipala|anticipalo|posticipa|posticipala|posticipalo|rimanda|rimandala|rimandalo|rinvia|rinviala|rinvialo|ritarda|allunga|accorcia|prolunga"),
           hasEvent || hasWhen {
            return .modifica_evento
        }
        // «Move», «reschedule», «postpone», «push back», «bring forward», «extend».
        if english, starts(#"move|reschedule|postpone|push|delay|shift|put\s+off|bring\b.*\b(?:forward|earlier|back)|extend|lengthen|prolong|shorten|make\b.*\b(?:longer|shorter|long)"#),
           hasEvent || hasWhen {
            return .modifica_evento
        }
        if starts("rinomina|rinominala|rinominalo") && hasEvent { return .modifica_evento }
        if english, starts("rename|retitle"), hasEvent { return .modifica_evento }
        if starts("cambia|modifica|aggiorna"), hasEvent,
           lower.range(of: #"\b(?:titolo|nome|luogo|orario|ora|data|durata)\b"#, options: .regularExpression) != nil {
            return .modifica_evento
        }
        if english, starts("change|edit|modify|update"), hasEvent,
           lower.range(of: #"\b(?:title|name|location|place|venue|room|address|time|date|day|duration|length|start|end)\b"#, options: .regularExpression) != nil {
            return .modifica_evento
        }
        if starts("cancella|elimina|rimuovi|togli|annulla|disdici"), hasEvent { return .elimina_evento }
        if english, starts(#"cancel|delete|remove|erase|call\s+off|drop|scrap|clear"#), hasEvent { return .elimina_evento }
        return nil
    }

    /// Promemoria in inglese: «delete the dentist reminder», «remove the due date from the bills reminder»,
    /// «mark the bills reminder as done». nil se la richiesta non parla di promemoria, `.some(nil)` se ne parla ma non ne cambia uno.
    static func englishReminderAction(_ lower: String, starts: (String) -> Bool) -> Action?? {
        guard lower.range(of: #"\b(?:reminders?|due\s+dates?|deadlines?|to-?dos?)\b"#, options: .regularExpression) != nil else { return nil }
        // «Remind me…», «set a reminder…», «add a new reminder»: un promemoria nuovo, non uno da cambiare.
        if lower.range(of: #"\bremind\s+me\b|\b(?:a|an|new|another)\s+(?:\w+\s+)?reminders?\b"#, options: .regularExpression) != nil { return .some(nil) }
        if starts(#"remove|delete|clear|drop|take\s+off|get\s+rid\s+of|unset"#),
           lower.range(of: #"\b(?:due|dates?|deadlines?|priority|flag)\b"#, options: .regularExpression) != nil {
            return .modifica_promemoria
        }
        if starts(#"delete|remove|cancel|erase|trash|clear|drop|get\s+rid\s+of"#) { return .elimina_promemoria }
        if starts(#"complete|finish|check\s+off|tick\s+off|cross\s+off|check\b.*\boff|tick\b.*\boff|cross\b.*\boff"#)
            || (starts("mark|set|check|tick|flag")
                && lower.range(of: #"(?<!not\s)\b(?:done|complete|completed|finished|checked|ticked)\b"#, options: .regularExpression) != nil) {
            return .completa_promemoria
        }
        if starts(#"move|reschedule|postpone|push|delay|bring|shift|change|edit|modify|update|rename|retitle|set|put|mark|flag|make"#) {
            return .modifica_promemoria
        }
        return .some(nil)
    }

    func handleChanges(_ plan: Plan, prompt: String, status: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        switch plan.action {
        case .modifica_evento, .elimina_evento:
            return await changeEvent(plan, prompt: prompt)
        case .modifica_promemoria, .elimina_promemoria, .completa_promemoria:
            return await changeReminder(plan, prompt: prompt)
        case .modifica_nota:
            return try await addToNote(plan, prompt: prompt, status: status)
        case .rispondi_email, .inoltra_email:
            return try await answerMail(plan, prompt: prompt, status: status)
        default:
            return .reply(prompt: withContext(prompt))
        }
    }

    // MARK: - Eventi

    func changeEvent(_ plan: Plan, prompt: String) async -> Outcome {
        // "Sposta il primo alle 18" dopo un elenco con soli promemoria: si parla del primo promemoria.
        if plan["id"] == nil, plan["scelta"] == nil, recentEvents.isEmpty, !recentReminders.isEmpty,
           ChoiceMatcher.ordinal(prompt, count: recentReminders.count) != nil {
            var reminderPlan = plan
            reminderPlan.action = plan.action == .elimina_evento ? .elimina_promemoria : .modifica_promemoria
            return await changeReminder(reminderPlan, prompt: prompt)
        }
        let change = EventChange.parse(prompt)
        switch findEvent(plan, change: change, prompt: prompt) {
        case .missing:
            let what = CommandText.specific(change.words).joined(separator: " ")
            let when = change.targetDay.map { " " + Dates.friendly($0, time: false) } ?? ""
            let time = change.targetTime.map { Language.t(" alle ", " at ") + DateExpressions.clock($0) } ?? ""
            return .message(what.isEmpty && when.isEmpty && time.isEmpty
                ? Language.t("Quale evento? Dimmi il titolo o il giorno, per esempio «sposta la riunione con Marco di domani alle 16».",
                             "Which event? Tell me the title or the day, for example “move tomorrow's meeting with Mark to 4 pm”.")
                : Language.t("Non trovo \(what.isEmpty ? "eventi" : "«\(what)»")\(when)\(time) nel calendario.",
                             "I can't find \(what.isEmpty ? "any events" : "“\(what)”")\(when)\(time) in your calendar."))
        case .several(let events):
            return askWhich(plan.action, prompt: prompt, events: events)
        case .found(let event):
            recentEvent = event
            if plan.action == .elimina_evento {
                return .confirm(PendingAction(kind: .deleteEvent(identifier: event.identifier, start: event.start),
                                              title: Language.t("Eliminare «\(event.title)»?", "Delete “\(event.title)”?"),
                                              detail: Dates.friendly(event.start, time: !event.isAllDay),
                                              expectedTitle: event.title, expectedContainer: event.calendar))
            }
            guard !change.isEmpty else {
                let when = Dates.friendly(event.start, time: !event.isAllDay)
                return .message(Language.t("Cosa vuoi cambiare di «\(event.title)» (\(when))? Per esempio «spostala alle 16», «anticipala di un'ora» o «rinominala in …».",
                                           "What do you want to change about “\(event.title)” (\(when))? For example “move it to 4 pm”, “move it an hour earlier” or “rename it to …”."))
            }
            let times = change.apply(start: event.start, end: event.end, isAllDay: event.isAllDay)
            let before = EventDraft(title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay,
                                    calendar: event.calendar, location: event.location ?? "")
            var after = before
            (after.start, after.end, after.isAllDay) = (times.start, times.end, times.isAllDay)
            if let title = change.newTitle, !title.isEmpty { after.title = title }
            if let place = change.newLocation, !place.isEmpty { after.location = place }
            guard after != before else {
                let when = Dates.friendly(event.start, time: !event.isAllDay)
                return .message(Language.t("«\(event.title)» è già così (\(when)): non c'è niente da cambiare.",
                                           "“\(event.title)” is already like that (\(when)): there's nothing to change."))
            }
            return .eventEdit(EventEditDraft(identifier: event.identifier, originalStart: event.start, before: before, after: after,
                                             attendees: EventKitService.attendeeCount(identifier: event.identifier, start: event.start)))
        }
    }

    /// L'evento di cui parla la richiesta: scelto prima, con un ID mostrato, "il primo" di un elenco, quello appena nominato,
    /// o cercato nel calendario per titolo, giorno e ora.
    func findEvent(_ plan: Plan, change: EventChange, prompt: String) -> Lookup<EventItem> {
        func occurrence(_ identifier: String, _ start: Date) -> EventItem? {
            Overview.events(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(1)).first { $0.identifier == identifier }
        }
        if let choice = plan["scelta"] {
            let parts = choice.split(separator: "|").map(String.init)
            if parts.count == 2, let seconds = Double(parts[1]), let event = occurrence(parts[0], Date(timeIntervalSince1970: seconds)) { return .found(event) }
        }
        if let id = plan["id"], let ref = ids.event(id), let event = occurrence(ref.identifier, ref.start) { return .found(event) }
        if let index = ChoiceMatcher.ordinal(prompt, count: recentEvents.count) { return .found(recentEvents[index]) }
        // "Spostala alle 16": l'evento di cui si è appena parlato, o l'unico dell'elenco mostrato che corrisponde.
        if change.hasNoTarget {
            if let recent = recentEvent, change.words.isEmpty { return .found(recent) }
            if !recentEvents.isEmpty {
                let matches = EventMatcher.best(recentEvents, change: change)
                if matches.count == 1 { return .found(matches[0]) }
            }
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let range: (Date, Date)
        if let day = change.targetDay {
            range = (calendar.startOfDay(for: day), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!)
        } else if !CommandText.specific(change.words).isEmpty {
            range = (calendar.date(byAdding: .day, value: -7, to: today)!, calendar.date(byAdding: .day, value: 120, to: today)!)
        } else {
            // Senza titolo né giorno ("sposta la riunione alle 16"): oggi e i prossimi due giorni.
            range = (today, calendar.date(byAdding: .day, value: 3, to: today)!)
        }
        let matches = EventMatcher.best(Overview.events(from: range.0, to: range.1), change: change)
        switch matches.count {
        case 0: return .missing
        case 1: return .found(matches[0])
        default: return .several(matches)
        }
    }

    func askWhich(_ action: Action, prompt: String, events: [EventItem]) -> Outcome {
        let shown = Array(events.prefix(6))
        pendingChoice = PendingChoice(action: action, prompt: prompt, options: shown.map {
            .init(identifier: "\($0.identifier)|\($0.start.timeIntervalSince1970)", title: $0.title, date: $0.start)
        })
        recentEvents = shown
        let verb = action == .elimina_evento ? Language.t("Quale elimino?", "Which one should I delete?") : Language.t("Quale intendi?", "Which one do you mean?")
        let lines = shown.enumerated().map { "\($0.offset + 1). \(Self.named($0.element.title)) · \(Dates.friendly($0.element.start, time: !$0.element.isAllDay))" }
        return .message(Language.t("Ho trovato \(events.count) eventi. \(verb)", "I found \(events.count) events. \(verb)") + "\n\n" + lines.joined(separator: "\n")
            + Language.t("\n\nRispondi con il numero, l'orario o il titolo (per esempio «la seconda»).",
                         "\n\nReply with the number, the time or the title (for example “the second one”)."))
    }

    /// Un titolo tra virgolette nella lingua della richiesta: «Spesa» in italiano, “Shopping” in inglese.
    static func named(_ title: String) -> String {
        Language.isEnglish ? "“\(title)”" : "«\(title)»"
    }

    // MARK: - Promemoria

    func changeReminder(_ plan: Plan, prompt: String) async -> Outcome {
        let change = ReminderChange.parse(prompt)
        let open = await Overview.openReminders(limit: 500)
        var found: Lookup<ReminderItem> = .missing
        if let choice = plan["scelta"], let item = open.first(where: { $0.id == choice }) {
            found = .found(item)
        } else if let id = plan["id"], let identifier = ids.reminder(id), let item = open.first(where: { $0.id == identifier }) {
            found = .found(item)
        } else if let index = ChoiceMatcher.ordinal(prompt, count: recentReminders.count) {
            found = .found(recentReminders[index])
        } else {
            let matches = ReminderMatcher.best(open, words: change.words, day: change.targetDay)
            if matches.count == 1 { found = .found(matches[0]) }
            else if matches.count > 1 { found = .several(matches) }
            else if CommandText.specific(change.words).isEmpty, let recent = recentReminder { found = .found(recent) }
        }
        switch found {
        case .missing:
            let what = CommandText.specific(change.words).joined(separator: " ")
            return .message(what.isEmpty
                ? Language.t("Quale promemoria? Dimmi il titolo, per esempio «cancella il promemoria del dentista».",
                             "Which reminder? Tell me the title, for example “delete the dentist reminder”.")
                : Language.t("Non trovo promemoria da fare con «\(what)».", "I can't find any open reminders with “\(what)”."))
        case .several(let items):
            let shown = Array(items.prefix(6))
            pendingChoice = PendingChoice(action: plan.action, prompt: prompt, options: shown.map { .init(identifier: $0.id, title: $0.title, date: $0.due) })
            recentReminders = shown
            let lines = shown.enumerated().map { index, item in
                "\(index + 1). \(Self.named(item.title)) · \(Language.t("lista", "list")) \(item.list)"
                    + (item.due.map { Language.t(", scade ", ", due ") + Dates.friendly($0, time: item.dueHasTime) } ?? "")
            }
            return .message(Language.t("Ho trovato \(items.count) promemoria. Quale intendi?", "I found \(items.count) reminders. Which one do you mean?")
                + "\n\n" + lines.joined(separator: "\n")
                + Language.t("\n\nRispondi con il numero o il titolo.", "\n\nReply with the number or the title."))
        case .found(let item):
            recentReminder = item
            let due = item.due.map { Language.t(" · scade ", " · due ") + Dates.friendly($0, time: item.dueHasTime) } ?? ""
            let detail = Language.t("Lista", "List") + " \(item.list)\(due)"
            switch plan.action {
            case .elimina_promemoria:
                return .confirm(PendingAction(kind: .deleteReminder(identifier: item.id),
                                              title: Language.t("Eliminare il promemoria «\(item.title)»?", "Delete the reminder “\(item.title)”?"), detail: detail,
                                              expectedTitle: item.title, expectedContainer: item.list))
            case .completa_promemoria:
                return .confirm(PendingAction(kind: .completeReminder(identifier: item.id),
                                              title: Language.t("Segnare come completato «\(item.title)»?", "Mark “\(item.title)” as completed?"), detail: detail,
                                              expectedTitle: item.title, expectedContainer: item.list))
            default:
                guard !change.isEmpty else {
                    return .message(Language.t("Cosa vuoi cambiare del promemoria «\(item.title)»? Per esempio «spostalo a venerdì», «rinominalo in …» o «segnalo come importante».",
                                               "What do you want to change about the reminder “\(item.title)”? For example “move it to Friday”, “rename it to …” or “mark it as important”."))
                }
                let before = ReminderDraft(title: item.title, due: item.due, dueHasTime: item.dueHasTime, highPriority: item.highPriority)
                var after = before
                (after.due, after.dueHasTime) = change.apply(due: item.due, hasTime: item.dueHasTime)
                if let title = change.newTitle, !title.isEmpty { after.title = title }
                if let priority = change.highPriority { after.highPriority = priority }
                var list = item.list
                if let wanted = change.list {
                    guard let existing = EventKitService.reminderLists().first(where: { $0.localizedCaseInsensitiveCompare(wanted) == .orderedSame })
                            ?? EventKitService.reminderLists().first(where: { $0.localizedCaseInsensitiveContains(wanted) }) else {
                        let lists = EventKitService.reminderLists().joined(separator: ", ")
                        return .message(Language.t("Non trovo la lista «\(wanted)» in Promemoria. Le liste sono: \(lists).",
                                                   "I can't find the list “\(wanted)” in Reminders. The lists are: \(lists)."))
                    }
                    list = existing
                }
                guard after != before || list != item.list else {
                    return .message(Language.t("Il promemoria «\(item.title)» è già così: non c'è niente da cambiare.",
                                               "The reminder “\(item.title)” is already like that: there's nothing to change."))
                }
                return .reminderEdit(ReminderEditDraft(identifier: item.id, before: before, beforeList: item.list, after: after, afterList: list))
            }
        }
    }

    // MARK: - Note

    private static let noteAdditionSchema = makeSchema("AggiuntaNota", [
        .required("nota", .string, "Nome della nota esistente di cui parla l'utente, per esempio «spesa»"),
        .required("testo", .string, "Testo da aggiungere, con le parole dell'utente, una voce per riga"),
    ])
    /// Lo stesso schema per le richieste in inglese (i campi restano quelli).
    private static let englishNoteAdditionSchema = makeSchema("AggiuntaNota", [
        .required("nota", .string, "Name of the existing note the user is talking about, for example “shopping”"),
        .required("testo", .string, "Text to add, in the user's own words, one item per line"),
    ])

    func addToNote(_ plan: Plan, prompt: String, status: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        // La nota aperta nella scheda davanti: «aggiungi il latte qui», «scrivi in questa nota che domani c'è sciopero».
        if let item = work.screen, item.kind == .note, let id = item.reference, plan["scelta"] == id {
            let lines = NoteAddition.parse(prompt)?.lines ?? ScreenItem.noteLines(from: prompt)
            guard !lines.isEmpty else { return .message(Language.t("Cosa aggiungo alla nota «\(item.title)»?", "What should I add to the note “\(item.title)”?")) }
            status(Language.t("Preparo l'aggiunta a «\(item.title)»…", "Preparing the addition to “\(item.title)”…"))
            let snapshot = try await NotesService.snapshot(id: id)
            let tail = snapshot.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3)
            return .noteAppend(NoteAppendDraft(noteID: id, title: item.title, lines: lines,
                                               manual: !NotesService.canAppendSafely(snapshot.html), tail: Array(tail)))
        }
        var addition = NoteAddition.parse(prompt)
        if addition == nil {
            // Frase insolita: il modello indica nota e testo, la ricerca resta dell'app.
            let instructions = Language.t("Estrai dalla richiesta il nome della nota e il testo da aggiungere, senza inventare.",
                                          "Extract from the request the name of the note and the text to add, without inventing anything.")
            let content = try? await LanguageModelSession(model: Agent.model, instructions: instructions)
                .respond(to: Language.t("Richiesta: ", "Request: ") + prompt, schema: Language.isEnglish ? Self.englishNoteAdditionSchema : Self.noteAdditionSchema,
                         options: GenerationOptions(samplingMode: .greedy)).content
            if let note = content?.string("nota"), let text = content?.string("testo"), !note.isEmpty, !text.isEmpty {
                addition = NoteAddition(note: note, lines: NoteAddition.items(text))
            }
        }
        guard let addition else {
            return .message(Language.t("A quale nota aggiungo, e cosa? Per esempio «aggiungi il latte alla nota della spesa».",
                                       "Which note should I add to, and what? For example “add milk to the shopping note”."))
        }
        status(Language.t("Cerco la nota «\(addition.note)»…", "Looking for the note “\(addition.note)”…"))
        var notes = try await NotesService.find(named: addition.note)
        if let choice = plan["scelta"] { notes = notes.filter { $0.id == choice } }
        let exact = notes.filter { NotesService.fold($0.title) == NotesService.fold(addition.note) }
        if exact.count == 1 { notes = exact }
        guard let note = notes.first else {
            let title = addition.note.prefix(1).uppercased() + addition.note.dropFirst()
            return .combined([.message(Language.t("Non trovo una nota «\(addition.note)»: te ne preparo una nuova.",
                                                  "I can't find a note called “\(addition.note)”: I'll prepare a new one.")),
                              .noteDraft(NoteDraft(title: title, body: addition.lines.joined(separator: "\n")))])
        }
        if notes.count > 1 {
            let shown = Array(notes.prefix(6))
            pendingChoice = PendingChoice(action: .modifica_nota, prompt: prompt, options: shown.map { .init(identifier: $0.id, title: $0.title, date: nil) })
            let lines = shown.enumerated().map { "\($0.offset + 1). \(Self.named($0.element.title)) · \($0.element.subtitle)" }
            return .message(Language.t("Ho trovato \(notes.count) note. In quale aggiungo?", "I found \(notes.count) notes. Which one should I add to?")
                + "\n\n" + lines.joined(separator: "\n")
                + Language.t("\n\nRispondi con il numero o il titolo.", "\n\nReply with the number or the title."))
        }
        let snapshot = try await NotesService.snapshot(id: note.id)
        let tail = snapshot.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3)
        return .noteAppend(NoteAppendDraft(noteID: note.id, title: note.title, lines: addition.lines,
                                           manual: !NotesService.canAppendSafely(snapshot.html), tail: Array(tail)))
    }

    // MARK: - Email

    private static var replySchema: GenerationSchema {
        let name = userFirstName
        let description = Language.isEnglish
            ? "Full text of the reply: greeting, what \(name ?? "the user") wants to say, " + (name.map { "a closing signed \($0)" } ?? "a friendly closing")
            : "Testo completo della risposta: saluto, ciò che \(name ?? "l'utente") vuole dire, " + (name.map { "chiusura firmata \($0)" } ?? "chiusura cordiale")
        return makeSchema("Risposta", [.required("corpo", .string, description)])
    }

    func answerMail(_ plan: Plan, prompt: String, status: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        var request = MailRequest.parse(prompt) ?? MailRequest(kind: plan.action == .inoltra_email ? .forward : .reply)
        if plan.action == .rispondi_email, request.kind != .reply { request = MailRequest(kind: .reply) }
        if let text = plan["testo"] { request.message = text }
        if request.kind == .forward, request.recipient == nil { request.recipient = plan["destinatari"] }
        if request.kind == .reply, request.person == nil, request.subject == nil, request.message == nil, let topic = plan["argomento"] { request.message = topic }

        status(Language.t("Cerco l'email…", "Looking for the email…"))
        var message: MailMessage?
        if let choice = plan["scelta"] {
            message = try await MailReader.message(id: choice)
        } else if let index = ChoiceMatcher.ordinal(prompt, count: recentMails.count) {
            message = try await MailReader.message(id: recentMails[index].id)
        } else if request.person == nil, request.subject == nil, let recent = recentMail ?? recentMails.first {
            message = recent.content.isEmpty ? try await MailReader.message(id: recent.id) : recent
        } else {
            let person = request.person ?? (request.subject == nil ? plan["destinatari"] : nil)
            let found = try await MailReader.find(person: person, subject: request.subject, limit: 10)
            // "Rispondi all'ultima email": la più recente di una persona, non una notifica automatica a cui non si può rispondere.
            let chosen = request.kind == .reply ? (found.first { !$0.isAutomatic } ?? found.first) : found.first
            if let chosen { message = try await MailReader.message(id: chosen.id) }
        }
        guard let message else {
            let who = request.person.map { Language.t(" di \($0)", " from \($0)") } ?? request.subject.map { Language.t(" su «\($0)»", " about “\($0)”") } ?? ""
            return .message(Language.t("Non trovo email\(who) nella posta in arrivo.", "I can't find any email\(who) in your inbox."))
        }
        recentMail = message

        switch request.kind {
        case .reply:
            guard let gist = request.message ?? plan["corpo"], !gist.isEmpty else {
                pendingReply = message
                return .message(Language.t("Cosa vuoi rispondere a \(message.senderName)? (email «\(message.subject)» del \(message.shortDate))",
                                           "What do you want to reply to \(message.senderName)? (email “\(message.subject)” from \(message.shortDate))"))
            }
            status(Language.t("Scrivo la risposta…", "Writing the reply…"))
            if message.isAutomatic {
                Agent.log("RISPOSTA: l'email più recente è una notifica automatica (\(message.senderAddress))")
            }
            // Con un modello esterno la risposta può scriverla lui (arriva già completa); altrimenti la scrive Apple Intelligence.
            let body: String
            if let written = plan["corpo"] { body = written } else { body = try await writeReply(to: message, gist: gist) }
            return .mailReply(MailReplyDraft(messageID: message.id, to: message.sender, subject: MailComposer.replySubject(message.subject),
                                             body: body, quote: MailComposer.quote(message), replyAll: request.replyAll))
        case .forward:
            let name = request.recipient ?? ""
            let contact = Contacts.emails(for: name).first
            return .mailForward(MailForwardDraft(messageID: message.id, subject: message.subject, from: message.senderName, date: message.shortDate,
                                                 recipientName: contact?.name ?? name, recipientAddress: contact?.address ?? ""))
        }
    }

    /// Risposta con le parole di chi usa l'app (per Ivan: «Ivan»): l'email ricevuta è solo da leggere.
    func writeReply(to message: MailMessage, gist: String) async throws -> String {
        let name = Self.userFirstName
        let role = Language.isEnglish
            ? "You are \(name.map { "\($0)'s" } ?? "the user's") assistant and you write short, friendly and professional email replies, in the language of the email received. Write only what \(name ?? "the user") wants to say, without inventing dates, times, commitments or details they didn't mention. Format: greeting with the sender's name on one line, blank line, the message, blank line, \(name.map { "“\($0)” on a line of its own" } ?? "a friendly closing on a line of its own"). \(Self.untrustedRule)"
            : "Sei l'assistente \(name.map { "di \($0)" } ?? "dell'utente") e scrivi risposte email brevi, cordiali e professionali, nella lingua dell'email ricevuta. Scrivi solo ciò che \(name ?? "l'utente") vuole dire, senza inventare date, orari, impegni o dettagli che non ha indicato. Formato: saluto con il nome del mittente su una riga, riga vuota, il messaggio, riga vuota, \(name.map { "«\($0)» su una riga a parte" } ?? "una chiusura cordiale su una riga a parte"). \(Self.untrustedRule)"
        let email = Self.untrusted(String(message.content.prefix(budget.scaled(1500))), label: Language.t("email ricevuta", "email received"))
        let request = Language.isEnglish ? """
        Email received from \(message.senderName), subject “\(message.subject)”:
        \(email)

        \(name ?? "The user") wants to reply: \(gist)
        Write \(name.map { "\($0)'s" } ?? "the user's") reply (only the text of the email).
        """ : """
        Email ricevuta da \(message.senderName), oggetto «\(message.subject)»:
        \(email)

        \(name ?? "L'utente") vuole rispondere: \(gist)
        Scrivi la risposta \(name.map { "di \($0)" } ?? "dell'utente") (solo il testo dell'email).
        """
        let schema = Self.replySchema
        return try await compose(role, request) {
            let content = try await writer(role).respond(to: request, schema: schema, options: GenerationOptions(temperature: 0.3)).content
            return content.string("corpo") ?? gist
        }
    }
}
