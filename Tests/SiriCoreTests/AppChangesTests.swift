import Foundation
import Testing
@testable import SiriCore

/// Comandi che cambiano eventi, promemoria, note ed email esistenti: date, orari e bersagli letti dalla frase.
@Suite struct AppChangesTests {
    /// Mercoledì 23 settembre 2026, ore 10.
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10))!

    func day(_ day: Int, month: Int = 9, year: Int = 2026) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test func days() {
        func first(_ text: String) -> Date? { DateExpressions.days(in: text, now: now).first?.date }
        #expect(first("domani") == day(24))
        #expect(first("dopodomani") == day(25))
        #expect(first("venerdì") == day(25))
        #expect(first("venerdi prossimo") == day(25))
        #expect(first("mercoledì") == day(23))
        #expect(first("mercoledì prossimo") == day(30))
        #expect(first("il 5 ottobre") == day(5, month: 10))
        #expect(first("5/10") == day(5, month: 10))
        #expect(first("tra 3 giorni") == day(26))
        #expect(first("il 10 gennaio") == day(10, month: 1, year: 2027))
        #expect(DateExpressions.days(in: "la riunione di domani", now: now).first?.role == .target)
        #expect(DateExpressions.days(in: "spostala a domani", now: now).first?.role == .destination)
        #expect(DateExpressions.days(in: "per il 5 ottobre", now: now).first?.role == .destination)
    }

    @Test func times() {
        func first(_ text: String) -> Int? { DateExpressions.times(in: text).first?.minutes }
        #expect(first("alle 16") == 16 * 60)
        #expect(first("alle 9 e mezza") == 9 * 60 + 30)
        #expect(first("alle 4 del pomeriggio") == 16 * 60)
        #expect(first("alle 7") == 19 * 60)
        #expect(first("alle 8") == 8 * 60)
        #expect(first("la cena alle 8") == 20 * 60)
        #expect(first("alle 16:30") == 16 * 60 + 30)
        #expect(first("alle 10 meno un quarto") == 9 * 60 + 45)
        #expect(first("a mezzogiorno") == 12 * 60)
        #expect(first("all'una") == 13 * 60)
        #expect(first("verso le 18.15") == 18 * 60 + 15)
        #expect(first("elimina la slide 3") == nil)
        #expect(DateExpressions.times(in: "la riunione delle 10").first?.role == .target)
        #expect(DateExpressions.times(in: "spostala alle 16").first?.role == .destination)
    }

    @Test func shifts() {
        #expect(DateExpressions.shifts(in: "anticipa di un'ora").first?.seconds == 3600)
        #expect(DateExpressions.shifts(in: "un'ora prima").first?.direction == -1)
        #expect(DateExpressions.shifts(in: "di 30 minuti").first?.seconds == 1800)
        #expect(DateExpressions.shifts(in: "alla settimana prossima").first?.days == 7)
        #expect(DateExpressions.shifts(in: "per due ore").isEmpty)
    }

    @Test func eventChanges() {
        let move = EventChange.parse("sposta la riunione con Marco di domani alle 16", now: now)
        #expect(move.words.contains("marco") && move.targetDay == day(24) && move.newTime == 16 * 60 && move.newDay == nil && move.targetTime == nil)
        let moved = move.apply(start: at(24, 10), end: at(24, 11), isAllDay: false)
        #expect(moved.start == at(24, 16) && moved.end == at(24, 17))

        let rename = EventChange.parse("rinomina l'evento di domani alle 10 in «Call con il cliente»", now: now)
        #expect(rename.newTitle == "Call con il cliente" && rename.targetDay == day(24) && rename.targetTime == 10 * 60 && !rename.changesTime)

        let toFriday = EventChange.parse("sposta la call con Luca a venerdì", now: now)
        #expect(toFriday.newDay == day(25) && toFriday.words.contains("luca") && toFriday.targetDay == nil)
        #expect(toFriday.apply(start: at(24, 15), end: at(24, 16), isAllDay: false).start == at(25, 15))

        let earlier = EventChange.parse("anticipa di un'ora la riunione di domani", now: now)
        #expect(earlier.shift == -3600 && earlier.targetDay == day(24))
        #expect(EventChange.parse("rimanda la cena alla settimana prossima", now: now).dayShift == 7)

        let times = EventChange.parse("sposta la riunione delle 10 alle 16", now: now)
        #expect(times.targetTime == 10 * 60 && times.newTime == 16 * 60)
        #expect(EventChange.parse("allunga la riunione di mezz'ora", now: now).endShift == 1800)

        let span = EventChange.parse("sposta la riunione a domani dalle 15 alle 17", now: now)
        #expect(span.newDay == day(24) && span.newTime == 15 * 60 && span.newEndTime == 17 * 60)
        #expect(span.apply(start: at(23, 11), end: at(23, 12), isAllDay: false) == (at(24, 15), at(24, 17), false))

        let place = EventChange.parse("cambia il luogo della cena di sabato in Da Mario", now: now)
        #expect(place.newLocation == "Da Mario" && place.targetDay == day(26) && place.words.contains("cena"))
        #expect(EventChange.parse("sposta la riunione budget in sala B", now: now).newLocation == "Sala B")
        let title = EventChange.parse("rinomina la riunione con Marco in Revisione budget", now: now)
        #expect(title.newTitle == "Revisione budget" && title.words.contains("marco"))
    }

    func event(_ title: String, _ start: Date, minutes: Int = 60) -> EventItem {
        EventItem(id: title + "\(start)", identifier: title, title: title, start: start, end: start.addingTimeInterval(Double(minutes) * 60),
                  isAllDay: false, calendar: "Lavoro", color: RGB(red: 0, green: 0, blue: 1), location: nil)
    }

    @Test func findingEvents() {
        let events = [event("Riunione con Marco", at(24, 10)), event("Call con Luca", at(24, 15)), event("Riunione budget", at(25, 9))]
        let marco = EventMatcher.best(events, change: EventChange.parse("sposta la riunione con Marco di domani alle 16", now: now), now: now)
        #expect(marco.map(\.title) == ["Riunione con Marco"])
        let atTen = EventMatcher.best(events, change: EventChange.parse("rinomina l'evento di domani alle 10 in «Call»", now: now), now: now)
        #expect(atTen.map(\.title) == ["Riunione con Marco"])
        #expect(EventMatcher.best(events, change: EventChange.parse("sposta la riunione con Giulia alle 16", now: now), now: now).isEmpty)
        // Due riunioni diverse: si chiede quale.
        #expect(EventMatcher.best(events, change: EventChange.parse("sposta la riunione alle 18", now: now), now: now).count == 2)
        // Evento che si ripete: la prossima volta.
        let standups = [event("Standup", at(23, 9), minutes: 15), event("Standup", at(24, 9), minutes: 15), event("Standup", at(25, 9), minutes: 15)]
        #expect(EventMatcher.best(standups, change: EventChange.parse("sposta lo standup alle 9:30", now: now), now: now).map(\.start) == [at(24, 9)])
    }

    @Test func reminderChanges() {
        let due = ReminderChange.parse("sposta la scadenza del promemoria bollette a venerdì", now: now)
        #expect(due.words == ["bollette"] && due.newDay == day(25))
        #expect(due.apply(due: day(24), hasTime: false, now: now) == (day(25), false))
        let timed = ReminderChange.parse("rimanda il promemoria dentista a domani alle 9", now: now)
        #expect(timed.newDay == day(24) && timed.newTime == 9 * 60)
        #expect(timed.apply(due: nil, hasTime: false, now: now) == (at(24, 9), true))
        #expect(ReminderChange.parse("togli la scadenza al promemoria bollette", now: now).removeDue)
        let important = ReminderChange.parse("segna come importante il promemoria della palestra", now: now)
        #expect(important.highPriority == true && important.words == ["palestra"])
        #expect(ReminderChange.parse("rinomina il promemoria bollette in «Pagare luce e gas»", now: now).newTitle == "Pagare luce e gas")
        let list = ReminderChange.parse("sposta il promemoria bollette nella lista Casa", now: now)
        #expect(list.list == "Casa" && list.words == ["bollette"])

        let reminders = [ReminderItem(id: "1", title: "Pagare le bollette", list: "Casa", due: day(24), dueHasTime: false, highPriority: false, color: RGB(red: 0, green: 0, blue: 0)),
                         ReminderItem(id: "2", title: "Dentista", list: "Personale", due: nil, dueHasTime: false, highPriority: false, color: RGB(red: 0, green: 0, blue: 0))]
        #expect(ReminderMatcher.best(reminders, words: ["bolletta"]).map(\.id) == ["1"])
        #expect(ReminderMatcher.best(reminders, words: ReminderChange.parse("cancella il promemoria del dentista", now: now).words).map(\.id) == ["2"])
    }

    @Test func notes() {
        #expect(NoteAddition.parse("aggiungi il latte alla nota della spesa") == NoteAddition(note: "spesa", lines: ["latte"]))
        #expect(NoteAddition.parse("aggiungi alla nota spesa: latte, uova e pane") == NoteAddition(note: "spesa", lines: ["latte", "uova", "pane"]))
        #expect(NoteAddition.parse("scrivi nella nota lavoro che domani c'è sciopero") == NoteAddition(note: "lavoro", lines: ["domani c'è sciopero"]))
        #expect(NoteAddition.parse("crea una nota sulla spesa") == nil)
        #expect(NoteAddition.parse("aggiungi una sezione al documento") == nil)
    }

    @Test func mail() {
        let reply = MailRequest.parse("rispondi a Mario che va bene per giovedì")
        #expect(reply?.kind == .reply && reply?.person == "Mario" && reply?.message == "va bene per giovedì")
        let dicendo = MailRequest.parse("rispondi all'email di Mario dicendo che accetto")
        #expect(dicendo?.person == "Mario" && dicendo?.message == "accetto")
        let subject = MailRequest.parse("rispondi alla mail sulla fattura: la pago domani")
        #expect(subject?.subject == "fattura" && subject?.message == "la pago domani")
        let forward = MailRequest.parse("inoltra a Giulia l'ultima email di Mario")
        #expect(forward?.kind == .forward && forward?.recipient == "Giulia" && forward?.person == "Mario")
        let forwardSubject = MailRequest.parse("inoltra l'email sulla fattura a Giulia")
        #expect(forwardSubject?.subject == "fattura" && forwardSubject?.recipient == "Giulia")
        #expect(MailRequest.parse("manda una mail a Giulia") == nil)
    }

    @MainActor @Test func routing() {
        #expect(Assistant.changeAction("sposta la riunione con Marco di domani alle 16") == .modifica_evento)
        #expect(Assistant.changeAction("rinomina l'evento di domani alle 10 in «Call con il cliente»") == .modifica_evento)
        #expect(Assistant.changeAction("anticipa di mezz'ora la call con Luca") == .modifica_evento)
        #expect(Assistant.changeAction("cancella la riunione con Marco") == .elimina_evento)
        #expect(Assistant.changeAction("cancella il promemoria del dentista") == .elimina_promemoria)
        #expect(Assistant.changeAction("sposta la scadenza del promemoria bollette a venerdì") == .modifica_promemoria)
        #expect(Assistant.changeAction("togli la scadenza al promemoria bollette") == .modifica_promemoria)
        #expect(Assistant.changeAction("segna come fatto il promemoria bollette") == .completa_promemoria)
        #expect(Assistant.changeAction("aggiungi il latte alla nota della spesa") == .modifica_nota)
        #expect(Assistant.changeAction("rispondi a Mario che va bene per giovedì") == .rispondi_email)
        #expect(Assistant.changeAction("inoltra a Giulia l'ultima email di Mario") == .inoltra_email)
        #expect(Assistant.changeAction("rispondi a Marco su iMessage che arrivo") == .invia_messaggio)
        // Non sono modifiche a qualcosa che esiste già.
        #expect(Assistant.changeAction("rispondi a questa domanda: quanto fa 2+2?") == nil)
        #expect(Assistant.changeAction("sposta il file report.md nella cartella archivio") == nil)
        #expect(Assistant.changeAction("sposta la slide 2 dopo la 4") == nil)
        #expect(Assistant.changeAction("crea un promemoria per domani") == nil)
        #expect(Assistant.changeAction("fissa una riunione con Marco domani alle 16") == nil)
        #expect(Assistant.changeAction("crea una nota sulla spesa") == nil)
        #expect(Assistant.changeAction("scrivi un'email a Giulia") == nil)
    }

    @MainActor @Test func routingWithSomethingOpen() throws {
        let assistant = Assistant()
        // Con un progetto aperto "sposta … a domani" resta al calendario, non diventa lo spostamento di un file.
        var work = WorkContext()
        let folder = FileManager.default.temporaryDirectory.appending(path: "siriai-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        work.projectRoot = folder
        work.projectName = "Prova"
        assistant.work = work
        var plan = Assistant.Plan(action: .file_sposta, fields: [:])
        assistant.applyRules(to: &plan, prompt: "sposta la riunione con Marco a domani alle 16")
        #expect(plan.action == .modifica_evento)
        // Con un documento aperto la nota e la cena non sono il documento.
        work = WorkContext()
        work.artifactKind = "documento"
        work.artifactTitle = "Piano"
        assistant.work = work
        #expect(!Assistant.isArtifactCommand("aggiungi il latte alla nota della spesa"))
        #expect(!Assistant.isArtifactCommand("sposta la cena a sabato"))
        #expect(Assistant.isArtifactCommand("sposta il paragrafo sul budget in fondo"))
        plan = Assistant.Plan(action: .modifica_artefatto, fields: [:])
        assistant.applyRules(to: &plan, prompt: "sposta la cena a sabato")
        #expect(plan.action == .modifica_evento)
    }

    /// Le regole decidono prima del modello, qualunque sia quello scelto (Apple Intelligence, Gemma, ChatGPT…).
    @MainActor @Test func rulesDecideForEveryModel() {
        let assistant = Assistant()
        #expect(assistant.decidedByRules("sposta la riunione con Marco di domani alle 16"))
        #expect(assistant.decidedByRules("crea un documento con scritto hello world"))
        #expect(!assistant.decidedByRules("chi ha vinto il campionato l'anno scorso?"))
        #expect(!assistant.decidedByRules("cancella tutto e scrivi hello world"))
        var work = WorkContext()
        work.artifactKind = "documento"
        work.artifactTitle = "Piano"
        assistant.work = work
        #expect(assistant.decidedByRules("cancella tutto e scrivi hello world"))
        #expect(assistant.decidedByRules("elimina la sezione Rischi"))
        // Le domande su ciò che è aperto le scrive il modello scelto, con il testo del documento nel contesto.
        #expect(!assistant.decidedByRules("riassumi questo documento in tre punti"))
    }

    @Test func choices() {
        let options: [(title: String, date: Date?)] = [("Riunione budget", at(24, 10)), ("Riunione con Marco", at(24, 15))]
        #expect(ChoiceMatcher.pick("la seconda", options: options, now: now) == 1)
        #expect(ChoiceMatcher.pick("quella delle 15", options: options, now: now) == 1)
        #expect(ChoiceMatcher.pick("budget", options: options, now: now) == 0)
        #expect(ChoiceMatcher.pick("2", options: options, now: now) == 1)
        #expect(ChoiceMatcher.pick("sposta la riunione alle 18", options: options, now: now) == nil)
        #expect(ChoiceMatcher.pick("boh", options: options, now: now) == nil)
        #expect(ChoiceMatcher.ordinal("sposta il primo alle 16", count: 3) == 0)
        #expect(ChoiceMatcher.ordinal("anticipa di un'ora prima", count: 3) == nil)
    }
}
