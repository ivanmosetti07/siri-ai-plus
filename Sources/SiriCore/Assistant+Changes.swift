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
            // Un comando nuovo o una domanda non sono il testo della risposta.
            let dictated = lower.range(of: #"^(?:digli|dille|scrivi(?:gli|le)|rispondi(?:gli|le)?|di'|dì)\b"#, options: .regularExpression) != nil
            if !prompt.hasSuffix("?"), dictated || (!Self.isCommand(prompt) && Self.changeAction(prompt) == nil) {
                let text = prompt.replacingOccurrences(of: #"(?i)^(?:digli|dille|scrivi(?:gli|le)|rispondi(?:gli|le)?|di'|dì)\s+(?:che\s+)?"#, with: "", options: .regularExpression)
                recentMail = mail
                return (Plan(action: .rispondi_email, fields: ["scelta": mail.id, "testo": text]), "rispondi a \(mail.senderName): \(text)")
            }
        }
        return nil
    }

    /// Comandi chiari su eventi, promemoria, note ed email che esistono già: l'azione giusta senza chiedere al pianificatore.
    static func changeAction(_ prompt: String) -> Action? {
        let text = CommandText.clean(prompt)
        let lower = " " + DateExpressions.normalized(text) + " "
        let start = lower.trimmingCharacters(in: .whitespaces)
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
                let mailWords = [" email", " e-mail", " mail", " posta"].contains(where: lower.contains)
                let firstWord = request.person?.split(separator: " ").first.map(String.init) ?? ""
                let named = firstWord.first?.isUppercase == true && !["Questa", "Questo", "Quella", "Quello", "Tutti", "Tutte", "Me", "Te"].contains(firstWord)
                if mailWords || named || starts("rispondigli|rispondile") { return .rispondi_email }
            }
        }
        if NoteAddition.parse(text) != nil { return .modifica_nota }
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
        guard lower.range(of: others, options: .regularExpression) == nil else { return nil }
        let nouns = ["riunion", "evento", "appuntament", " call ", "meeting", "incontro", "videochiamat", "cena", "pranzo", "colazione",
                     "aperitivo", "visita", "lezione", "allenamento", "partita", "colloquio", "conferenza", "webinar", "standup", "stand-up"]
        let hasEvent = nouns.contains(where: lower.contains)
        let hasWhen = !DateExpressions.days(in: text).isEmpty || !DateExpressions.times(in: text).isEmpty || !DateExpressions.shifts(in: text).isEmpty
        if starts("sposta|spostare|spostala|spostalo|anticipa|anticipala|anticipalo|posticipa|posticipala|posticipalo|rimanda|rimandala|rimandalo|rinvia|rinviala|rinvialo|ritarda|allunga|accorcia|prolunga"),
           hasEvent || hasWhen {
            return .modifica_evento
        }
        if starts("rinomina|rinominala|rinominalo") && hasEvent { return .modifica_evento }
        if starts("cambia|modifica|aggiorna"), hasEvent,
           lower.range(of: #"\b(?:titolo|nome|luogo|orario|ora|data|durata)\b"#, options: .regularExpression) != nil {
            return .modifica_evento
        }
        if starts("cancella|elimina|rimuovi|togli|annulla|disdici"), hasEvent { return .elimina_evento }
        return nil
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
            let what = Keywords.specific(change.words).joined(separator: " ")
            let when = change.targetDay.map { " " + Dates.friendly($0, time: false) } ?? ""
            let time = change.targetTime.map { " alle \(DateExpressions.clock($0))" } ?? ""
            return .message(what.isEmpty && when.isEmpty && time.isEmpty
                ? "Quale evento? Dimmi il titolo o il giorno, per esempio «sposta la riunione con Marco di domani alle 16»."
                : "Non trovo \(what.isEmpty ? "eventi" : "«\(what)»")\(when)\(time) nel calendario.")
        case .several(let events):
            return askWhich(plan.action, prompt: prompt, events: events)
        case .found(let event):
            recentEvent = event
            if plan.action == .elimina_evento {
                return .confirm(PendingAction(kind: .deleteEvent(identifier: event.identifier, start: event.start),
                                              title: "Eliminare «\(event.title)»?", detail: Dates.friendly(event.start, time: !event.isAllDay)))
            }
            guard !change.isEmpty else {
                return .message("Cosa vuoi cambiare di «\(event.title)» (\(Dates.friendly(event.start, time: !event.isAllDay)))? Per esempio «spostala alle 16», «anticipala di un'ora» o «rinominala in …».")
            }
            let times = change.apply(start: event.start, end: event.end, isAllDay: event.isAllDay)
            let before = EventDraft(title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay,
                                    calendar: event.calendar, location: event.location ?? "")
            var after = before
            (after.start, after.end, after.isAllDay) = (times.start, times.end, times.isAllDay)
            if let title = change.newTitle, !title.isEmpty { after.title = title }
            if let place = change.newLocation, !place.isEmpty { after.location = place }
            guard after != before else {
                return .message("«\(event.title)» è già così (\(Dates.friendly(event.start, time: !event.isAllDay))): non c'è niente da cambiare.")
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
        } else if !Keywords.specific(change.words).isEmpty {
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
        let verb = action == .elimina_evento ? "Quale elimino?" : "Quale intendi?"
        let lines = shown.enumerated().map { "\($0.offset + 1). «\($0.element.title)» · \(Dates.friendly($0.element.start, time: !$0.element.isAllDay))" }
        return .message("Ho trovato \(events.count) eventi. \(verb)\n\n" + lines.joined(separator: "\n") + "\n\nRispondi con il numero, l'orario o il titolo (per esempio «la seconda»).")
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
            else if Keywords.specific(change.words).isEmpty, let recent = recentReminder { found = .found(recent) }
        }
        switch found {
        case .missing:
            let what = Keywords.specific(change.words).joined(separator: " ")
            return .message(what.isEmpty ? "Quale promemoria? Dimmi il titolo, per esempio «cancella il promemoria del dentista»."
                                         : "Non trovo promemoria da fare con «\(what)».")
        case .several(let items):
            let shown = Array(items.prefix(6))
            pendingChoice = PendingChoice(action: plan.action, prompt: prompt, options: shown.map { .init(identifier: $0.id, title: $0.title, date: $0.due) })
            recentReminders = shown
            let lines = shown.enumerated().map { index, item in
                "\(index + 1). «\(item.title)» · lista \(item.list)" + (item.due.map { ", scade \(Dates.friendly($0, time: item.dueHasTime))" } ?? "")
            }
            return .message("Ho trovato \(items.count) promemoria. Quale intendi?\n\n" + lines.joined(separator: "\n") + "\n\nRispondi con il numero o il titolo.")
        case .found(let item):
            recentReminder = item
            let due = item.due.map { " · scade \(Dates.friendly($0, time: item.dueHasTime))" } ?? ""
            switch plan.action {
            case .elimina_promemoria:
                return .confirm(PendingAction(kind: .deleteReminder(identifier: item.id), title: "Eliminare il promemoria «\(item.title)»?", detail: "Lista \(item.list)\(due)"))
            case .completa_promemoria:
                return .confirm(PendingAction(kind: .completeReminder(identifier: item.id), title: "Segnare come completato «\(item.title)»?", detail: "Lista \(item.list)\(due)"))
            default:
                guard !change.isEmpty else {
                    return .message("Cosa vuoi cambiare del promemoria «\(item.title)»? Per esempio «spostalo a venerdì», «rinominalo in …» o «segnalo come importante».")
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
                        return .message("Non trovo la lista «\(wanted)» in Promemoria. Le liste sono: \(EventKitService.reminderLists().joined(separator: ", ")).")
                    }
                    list = existing
                }
                guard after != before || list != item.list else {
                    return .message("Il promemoria «\(item.title)» è già così: non c'è niente da cambiare.")
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

    func addToNote(_ plan: Plan, prompt: String, status: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        // La nota aperta nella scheda davanti: «aggiungi il latte qui», «scrivi in questa nota che domani c'è sciopero».
        if let item = work.screen, item.kind == .note, let id = item.reference, plan["scelta"] == id {
            let lines = NoteAddition.parse(prompt)?.lines ?? ScreenItem.noteLines(from: prompt)
            guard !lines.isEmpty else { return .message("Cosa aggiungo alla nota «\(item.title)»?") }
            status("Preparo l'aggiunta a «\(item.title)»…")
            let snapshot = try await NotesService.snapshot(id: id)
            let tail = snapshot.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3)
            return .noteAppend(NoteAppendDraft(noteID: id, title: item.title, lines: lines,
                                               manual: !NotesService.canAppendSafely(snapshot.html), tail: Array(tail)))
        }
        var addition = NoteAddition.parse(prompt)
        if addition == nil {
            // Frase insolita: il modello indica nota e testo, la ricerca resta dell'app.
            let content = try? await LanguageModelSession(model: Agent.model, instructions: "Estrai dalla richiesta il nome della nota e il testo da aggiungere, senza inventare.")
                .respond(to: "Richiesta: \(prompt)", schema: Self.noteAdditionSchema, options: GenerationOptions(samplingMode: .greedy)).content
            if let note = content?.string("nota"), let text = content?.string("testo"), !note.isEmpty, !text.isEmpty {
                addition = NoteAddition(note: note, lines: NoteAddition.items(text))
            }
        }
        guard let addition else {
            return .message("A quale nota aggiungo, e cosa? Per esempio «aggiungi il latte alla nota della spesa».")
        }
        status("Cerco la nota «\(addition.note)»…")
        var notes = try await NotesService.find(named: addition.note)
        if let choice = plan["scelta"] { notes = notes.filter { $0.id == choice } }
        let exact = notes.filter { NotesService.fold($0.title) == NotesService.fold(addition.note) }
        if exact.count == 1 { notes = exact }
        guard let note = notes.first else {
            let title = addition.note.prefix(1).uppercased() + addition.note.dropFirst()
            return .combined([.message("Non trovo una nota «\(addition.note)»: te ne preparo una nuova."),
                              .noteDraft(NoteDraft(title: title, body: addition.lines.joined(separator: "\n")))])
        }
        if notes.count > 1 {
            let shown = Array(notes.prefix(6))
            pendingChoice = PendingChoice(action: .modifica_nota, prompt: prompt, options: shown.map { .init(identifier: $0.id, title: $0.title, date: nil) })
            let lines = shown.enumerated().map { "\($0.offset + 1). «\($0.element.title)» · \($0.element.subtitle)" }
            return .message("Ho trovato \(notes.count) note. In quale aggiungo?\n\n" + lines.joined(separator: "\n") + "\n\nRispondi con il numero o il titolo.")
        }
        let snapshot = try await NotesService.snapshot(id: note.id)
        let tail = snapshot.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3)
        return .noteAppend(NoteAppendDraft(noteID: note.id, title: note.title, lines: addition.lines,
                                           manual: !NotesService.canAppendSafely(snapshot.html), tail: Array(tail)))
    }

    // MARK: - Email

    private static let replySchema = makeSchema("Risposta", [
        .required("corpo", .string, "Testo completo della risposta: saluto, ciò che Ivan vuole dire, chiusura firmata Ivan"),
    ])

    func answerMail(_ plan: Plan, prompt: String, status: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        var request = MailRequest.parse(prompt) ?? MailRequest(kind: plan.action == .inoltra_email ? .forward : .reply)
        if plan.action == .rispondi_email, request.kind != .reply { request = MailRequest(kind: .reply) }
        if let text = plan["testo"] { request.message = text }
        if request.kind == .forward, request.recipient == nil { request.recipient = plan["destinatari"] }
        if request.kind == .reply, request.person == nil, request.subject == nil, request.message == nil, let topic = plan["argomento"] { request.message = topic }

        status("Cerco l'email…")
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
            let who = request.person.map { " di \($0)" } ?? request.subject.map { " su «\($0)»" } ?? ""
            return .message("Non trovo email\(who) nella posta in arrivo.")
        }
        recentMail = message

        switch request.kind {
        case .reply:
            guard let gist = request.message ?? plan["corpo"], !gist.isEmpty else {
                pendingReply = message
                return .message("Cosa vuoi rispondere a \(message.senderName)? (email «\(message.subject)» del \(message.shortDate))")
            }
            status("Scrivo la risposta…")
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

    /// Risposta con le parole di Ivan: l'email ricevuta è solo da leggere.
    func writeReply(to message: MailMessage, gist: String) async throws -> String {
        let role = "Sei l'assistente di Ivan e scrivi risposte email brevi, cordiali e professionali, nella lingua dell'email ricevuta. Scrivi solo ciò che Ivan vuole dire, senza inventare date, orari, impegni o dettagli che non ha indicato. Formato: saluto con il nome del mittente su una riga, riga vuota, il messaggio, riga vuota, «Ivan» su una riga a parte. \(Self.untrustedRule)"
        let request = """
        Email ricevuta da \(message.senderName), oggetto «\(message.subject)»:
        \(Self.untrusted(String(message.content.prefix(budget.scaled(1500))), label: "email ricevuta"))

        Ivan vuole rispondere: \(gist)
        Scrivi la risposta di Ivan (solo il testo dell'email).
        """
        return try await compose(role, request) {
            let content = try await writer(role).respond(to: request, schema: Self.replySchema, options: GenerationOptions(temperature: 0.3)).content
            return content.string("corpo") ?? gist
        }
    }
}
