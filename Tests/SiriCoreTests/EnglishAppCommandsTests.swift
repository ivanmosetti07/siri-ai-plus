import Foundation
import Testing
@testable import SiriCore

/// Comandi in inglese su ciò che esiste già nelle app e su ciò che è selezionato: stesse azioni delle frasi italiane.
/// Le date scritte in inglese («to 4 pm», «to Friday») le legge `DateExpressions`: qui gli orari sono nel formato che
/// l'app conosce già («16:00»), e si controllano azione, bersaglio e testo nuovo.
@Suite struct EnglishAppCommandsTests {
    /// Mercoledì 23 settembre 2026, ore 10.
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10))!

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func english<T>(_ body: () throws -> T) rethrows -> T { try Language.$scoped.withValue(.en, operation: body) }

    func event(_ title: String, _ start: Date, minutes: Int = 60) -> EventItem {
        EventItem(id: title + "\(start)", identifier: title, title: title, start: start, end: start.addingTimeInterval(Double(minutes) * 60),
                  isAllDay: false, calendar: "Work", color: RGB(red: 0, green: 0, blue: 1), location: nil)
    }

    func reminder(_ id: String, _ title: String) -> ReminderItem {
        ReminderItem(id: id, title: title, list: "Home", due: nil, dueHasTime: false, highPriority: false, color: RGB(red: 0, green: 0, blue: 0))
    }

    /// Il banco di prova inglese (Support/eval/tools-en.json, categoria «apps»): le azioni sono quelle italiane.
    @MainActor @Test func benchPhrasings() {
        let expected: [(String, Assistant.Action?)] = [
            ("move tomorrow's meeting with Mark to 4 pm", .modifica_evento),
            ("rename tomorrow's 10 am event to \"Client call\"", .modifica_evento),
            ("delete the dentist reminder", .elimina_promemoria),
            ("move the due date of the bills reminder to Friday", .modifica_promemoria),
            ("add milk to the shopping note", .modifica_nota),
            ("reply to Mario that Thursday works for me", .rispondi_email),
            ("forward Mario's last email to Julia", .inoltra_email),
            ("move the call with Luke half an hour earlier", .modifica_evento),
            ("postpone the dinner with Sarah to Friday", .modifica_evento),
            ("change the location of tomorrow's meeting to room B", .modifica_evento),
            ("extend the budget meeting by half an hour", .modifica_evento),
            ("cancel tomorrow's meeting with Mark", .elimina_evento),
            ("remove the due date from the bills reminder", .modifica_promemoria),
            ("mark the gym reminder as important", .modifica_promemoria),
            ("delete the pay the rent reminder", .elimina_promemoria),
            ("mark the bills reminder as done", .completa_promemoria),
            ("write in the work note that there's a strike tomorrow", .modifica_nota),
            ("add to the shopping note: eggs, bread and coffee", .modifica_nota),
            ("reply to the email about the invoice saying I'll pay it tomorrow", .rispondi_email),
            ("forward the last email from Mario to Julia", .inoltra_email),
            ("reply to Mark on iMessage that I'll be there in ten minutes", .invia_messaggio),
            // Non sono modifiche a qualcosa che esiste già.
            ("answer this question: what's 12 times 7?", nil),
            ("remind me to pay the bills on Friday", nil),
            ("create a note with the shopping list: milk and eggs", nil),
            ("set up a meeting with Mark tomorrow at 4 pm", nil),
            ("what do I have tomorrow?", nil),
            ("write an email to Julia about the quote", nil),
        ]
        english {
            for (prompt, action) in expected {
                #expect(Assistant.changeAction(prompt) == action, "\(prompt)")
            }
        }
        // In italiano non cambia niente.
        Language.$scoped.withValue(.it) {
            #expect(Assistant.changeAction("sposta la riunione con Marco di domani alle 16") == .modifica_evento)
            #expect(Assistant.changeAction("segna come fatto il promemoria bollette") == .completa_promemoria)
            #expect(Assistant.changeAction("rispondi a questa domanda: quanto fa 2+2?") == nil)
            #expect(Assistant.changeAction("reply to Mario that Thursday works for me") == nil)
        }
    }

    /// Le regole decidono prima del modello, qualunque sia quello scelto: anche in inglese.
    @MainActor @Test func rulesDecideForEveryModel() {
        english {
            let assistant = Assistant()
            #expect(assistant.decidedByRules("move tomorrow's meeting with Mark to 16:00"))
            #expect(assistant.decidedByRules("add milk to the shopping note"))
            #expect(assistant.decidedByRules("forward the last email from Mario to Julia"))
            #expect(!assistant.decidedByRules("who won the championship last year?"))
            #expect(!assistant.decidedByRules("what do I have tomorrow?"))
            // Una domanda con un promemoria selezionato resta una domanda, non «segna come fatto».
            var work = WorkContext()
            var task = ScreenItem(app: "Reminders", kind: .reminder, title: "Pay the bill", reference: "R1")
            task.reminder = reminder("R1", "Pay the bill")
            work.screen = task
            assistant.work = work
            assistant.updateScreen()
            assistant.prepareScreen(for: "what did I do today?")
            #expect(assistant.screenAction("what did I do today?") == nil)
            #expect(assistant.screenAction("which reminders are done?") == nil)
        }
    }

    @MainActor @Test func routing() {
        english {
            #expect(Assistant.changeAction("please move the call with Luke to 16:00") == .modifica_evento)
            #expect(Assistant.changeAction("can you delete the dentist reminder?") == .elimina_promemoria)
            #expect(Assistant.changeAction("push the dinner with Sarah back an hour") == .modifica_evento)
            #expect(Assistant.changeAction("bring the call with Luke forward by 30 minutes") == .modifica_evento)
            #expect(Assistant.changeAction("reschedule the dentist appointment to 16:00") == .modifica_evento)
            #expect(Assistant.changeAction("rename the meeting with Mark to \"Email review\"") == .modifica_evento)
            #expect(Assistant.changeAction("change the title of the call with Luke to Weekly sync") == .modifica_evento)
            #expect(Assistant.changeAction("check off the bills reminder") == .completa_promemoria)
            #expect(Assistant.changeAction("complete the gym reminder") == .completa_promemoria)
            #expect(Assistant.changeAction("flag the gym reminder") == .modifica_promemoria)
            #expect(Assistant.changeAction("rename the bills reminder to Pay utilities") == .modifica_promemoria)
            #expect(Assistant.changeAction("reply to him that it's fine") == .rispondi_email)
            #expect(Assistant.changeAction("reply all to the email from Julia saying ok") == .rispondi_email)
            #expect(Assistant.changeAction("forward it to Julia") == .inoltra_email)
            #expect(Assistant.changeAction("add eggs, bread, and coffee to my shopping list note") == .modifica_nota)
            // Non riguardano eventi, promemoria, note o email che esistono già.
            #expect(Assistant.changeAction("move the file report.md to the archive folder") == nil)
            #expect(Assistant.changeAction("move slide 2 after slide 4") == nil)
            #expect(Assistant.changeAction("set a reminder for the dentist tomorrow") == nil)
            #expect(Assistant.changeAction("what did I do today?") == nil)
            #expect(Assistant.changeAction("which reminders did I complete?") == nil)
            #expect(Assistant.changeAction("reply to this question: what's the capital of France?") == nil)
            #expect(Assistant.changeAction("send an email to Julia") == nil)
            #expect(Assistant.changeAction("send this document to Mark by email") == nil)
            #expect(Assistant.changeAction("reply to Mark on WhatsApp that I'm late") == nil)
        }
    }

    @Test func eventChanges() {
        english {
            let move = EventChange.parse("move tomorrow's meeting with Mark to 16:00", now: now)
            #expect(move.words.contains("mark") && !move.words.contains("move") && !move.words.contains("tomorrow") && !move.words.contains("with"))
            #expect(move.newTime == 16 * 60 && move.targetTime == nil)

            let rename = EventChange.parse("rename tomorrow's 10:00 event to \"Client call\"", now: now)
            #expect(rename.newTitle == "Client call" && rename.targetTime == 10 * 60 && !rename.changesTime)
            let title = EventChange.parse("rename the meeting with Mark to Budget review", now: now)
            #expect(title.newTitle == "Budget review" && title.words.contains("mark"))
            let changeTitle = EventChange.parse("change the title of the call with Luke to Weekly sync", now: now)
            #expect(changeTitle.newTitle == "Weekly sync" && changeTitle.words.contains("luke"))

            let place = EventChange.parse("change the location of tomorrow's meeting to room B", now: now)
            #expect(place.newLocation == "room B" && place.words.contains("meeting") && !place.changesTime)
            let room = EventChange.parse("move the budget meeting to room B", now: now)
            #expect(room.newLocation == "Room B" && room.words.contains("budget"))

            let span = EventChange.parse("move the meeting from 15:00 to 17:00", now: now)
            #expect(span.newTime == 15 * 60 && span.newEndTime == 17 * 60)
            let both = EventChange.parse("move the 10:00 meeting to 16:00", now: now)
            #expect(both.targetTime == 10 * 60 && both.newTime == 16 * 60)
            #expect(EventChange.parse("extend the meeting until 18:00", now: now).newEndTime == 18 * 60)

            #expect(EventChange.parse("make the budget meeting last two hours", now: now).duration == 7200)
            #expect(EventChange.parse("set the call with Luke for an hour and a half", now: now).duration == 5400)
            let extend = EventChange.parse("extend the budget meeting for 30 minutes", now: now)
            #expect(extend.endShift == 1800 && extend.duration == nil)
            let delay = EventChange.parse("delay the standup for 15 minutes", now: now)
            #expect(delay.shift == 900 && delay.duration == nil)
            #expect(EventChange.parse("move it to 16:00", now: now).hasNoTarget)
        }
    }

    @Test func englishRoles() {
        func role(_ phrase: String, in text: String) -> DateExpressions.Role {
            CommandText.englishRole((text as NSString).range(of: phrase), in: text)
        }
        #expect(role("tomorrow", in: "move tomorrow's meeting to 16:00") == .target)
        #expect(role("friday", in: "postpone the dinner with sarah to friday") == .destination)
        #expect(role("10:00", in: "move the 10:00 meeting to friday") == .target)
        #expect(role("10:00", in: "move the meeting at 10:00 to friday") == .target)
        #expect(role("16:00", in: "move the meeting to friday at 16:00") == .destination)
        #expect(role("friday", in: "move the meeting on friday to monday") == .target)
        #expect(role("friday", in: "move the meeting friday") == .bare)
        #expect(role("tomorrow", in: "move the reminder due tomorrow to friday") == .target)
    }

    @Test func findingEvents() {
        english {
            let events = [event("Meeting with Mark", at(24, 10)), event("Call with Luke", at(24, 15)), event("Budget meeting", at(25, 9)),
                          event("Dentist appointment", at(26, 11))]
            func best(_ prompt: String) -> [String] { EventMatcher.best(events, change: EventChange.parse(prompt, now: now), now: now).map(\.title) }
            #expect(best("move the meeting with Mark to 16:00") == ["Meeting with Mark"])
            #expect(best("cancel the call with Luke") == ["Call with Luke"])
            // «Appointment» è generico come «appuntamento»: basta che ci sia nel titolo, non esclude gli altri.
            #expect(best("move the appointment to 16:00") == ["Dentist appointment"])
            #expect(best("move the meeting with Julia to 16:00").isEmpty)
            // Due riunioni diverse: si chiede quale.
            #expect(best("move the meeting to 18:00").count == 2)
        }
    }

    @Test func reminderChanges() {
        english {
            let due = ReminderChange.parse("move the due date of the bills reminder to Friday", now: now)
            #expect(due.words.contains("bills") && !due.words.contains("due") && !due.words.contains("reminder") && !due.words.contains("move"))
            let noDue = ReminderChange.parse("remove the due date from the bills reminder", now: now)
            #expect(noDue.removeDue && noDue.words == ["bills"])
            let important = ReminderChange.parse("mark the gym reminder as important", now: now)
            #expect(important.highPriority == true && important.words == ["gym"])
            #expect(ReminderChange.parse("mark the gym reminder as not important", now: now).highPriority == false)
            #expect(ReminderChange.parse("rename the bills reminder to \"Pay utilities\"", now: now).newTitle == "Pay utilities")
            let renamed = ReminderChange.parse("rename the bills reminder to Pay utilities", now: now)
            #expect(renamed.newTitle == "Pay utilities" && renamed.words == ["bills"])
            let list = ReminderChange.parse("move the bills reminder to the Home list", now: now)
            #expect(list.list == "Home" && list.words == ["bills"])
            #expect(ReminderChange.parse("move the dentist reminder to 9:30", now: now).newTime == 9 * 60 + 30)

            let reminders = [reminder("1", "Pay the bill"), reminder("2", "Dentist"), reminder("3", "Gym"), reminder("4", "Pay the rent")]
            func best(_ prompt: String) -> [String] { ReminderMatcher.best(reminders, words: ReminderChange.parse(prompt, now: now).words).map(\.id) }
            #expect(best("delete the dentist reminder") == ["2"])
            // «bills» trova «Pay the bill»: il plurale conta come il singolare.
            #expect(best("mark the bills reminder as done") == ["1"])
            #expect(best("delete the pay the rent reminder") == ["4"])
            // «Mark» è un nome, non un verbo, quando non è all'inizio.
            #expect(ReminderChange.parse("delete the call Mark reminder", now: now).words.contains("mark"))
        }
    }

    @Test func notes() {
        english {
            #expect(NoteAddition.parse("add milk to the shopping note") == NoteAddition(note: "shopping", lines: ["milk"]))
            #expect(NoteAddition.parse("write in the work note that there's a strike tomorrow") == NoteAddition(note: "work", lines: ["there's a strike tomorrow"]))
            #expect(NoteAddition.parse("add to the shopping note: eggs, bread and coffee") == NoteAddition(note: "shopping", lines: ["eggs", "bread", "coffee"]))
            #expect(NoteAddition.parse("add eggs, bread, and coffee to my shopping list note") == NoteAddition(note: "shopping list", lines: ["eggs", "bread", "coffee"]))
            #expect(NoteAddition.parse("add milk to the note called Shopping") == NoteAddition(note: "Shopping", lines: ["milk"]))
            #expect(NoteAddition.parse("put the milk in the note \"Shopping\"") == NoteAddition(note: "Shopping", lines: ["milk"]))
            #expect(NoteAddition.parse("add call the plumber on Monday to the house note") == NoteAddition(note: "house", lines: ["call the plumber on Monday"]))
            #expect(NoteAddition.parse("create a note with the shopping list: milk and eggs") == nil)
            #expect(NoteAddition.parse("add a section about social channels after the goals") == nil)
            #expect(NoteAddition.parse("write an email to Julia about the quote") == nil)
            #expect(NoteAddition.parse("write in my notes that the meeting moved") == nil)
            #expect(NoteAddition.parse("add this to my notes") == nil)
        }
    }

    @Test func mail() {
        english {
            let reply = MailRequest.parse("reply to Mario that Thursday works for me")
            #expect(reply?.kind == .reply && reply?.person == "Mario" && reply?.message == "Thursday works for me")
            let subject = MailRequest.parse("reply to the email about the invoice saying I'll pay it tomorrow")
            #expect(subject?.subject == "invoice" && subject?.person == nil && subject?.message == "I'll pay it tomorrow")
            let possessive = MailRequest.parse("reply to Mario's email saying that I accept")
            #expect(possessive?.person == "Mario" && possessive?.message == "I accept")
            let last = MailRequest.parse("reply to the last email from Mario: I'll be there")
            #expect(last?.person == "Mario" && last?.message == "I'll be there")
            let all = MailRequest.parse("reply all to the email from Julia saying ok")
            #expect(all?.replyAll == true && all?.person == "Julia" && all?.message == "ok")
            let him = MailRequest.parse("reply to him that it's fine")
            #expect(him?.person == nil && him?.message == "it's fine")
            #expect(MailRequest.parse("reply to Mario")?.person == "Mario")

            let forward = MailRequest.parse("forward Mario's last email to Julia")
            #expect(forward?.kind == .forward && forward?.person == "Mario" && forward?.recipient == "Julia")
            let forwardFrom = MailRequest.parse("forward the last email from Mario to Julia")
            #expect(forwardFrom?.person == "Mario" && forwardFrom?.recipient == "Julia")
            let forwardSubject = MailRequest.parse("forward the email about the invoice to Julia")
            #expect(forwardSubject?.subject == "invoice" && forwardSubject?.recipient == "Julia")
            let forwardFirst = MailRequest.parse("forward to Julia the last email from Mario")
            #expect(forwardFirst?.recipient == "Julia" && forwardFirst?.person == "Mario")
            let forwardIt = MailRequest.parse("forward it to Julia")
            #expect(forwardIt?.recipient == "Julia" && forwardIt?.person == nil && forwardIt?.subject == nil)
            #expect(MailRequest.parse("send an email to Julia") == nil)
            #expect(MailRequest.parse("send this document to Mark by email") == nil)
        }
        // In italiano le frasi inglesi non sono comandi per la posta.
        Language.$scoped.withValue(.it) {
            #expect(MailRequest.parse("forward Mario's last email to Julia") == nil)
            #expect(MailRequest.parse("rispondi a Mario che va bene per giovedì")?.message == "va bene per giovedì")
        }
    }

    @Test func choices() {
        english {
            let options: [(title: String, date: Date?)] = [("Budget meeting", at(24, 10)), ("Meeting with Mark", at(24, 15))]
            #expect(ChoiceMatcher.pick("the second one", options: options, now: now) == 1)
            #expect(ChoiceMatcher.pick("the first", options: options, now: now) == 0)
            #expect(ChoiceMatcher.pick("second", options: options, now: now) == 1)
            #expect(ChoiceMatcher.pick("number 2", options: options, now: now) == 1)
            #expect(ChoiceMatcher.pick("the 2nd one", options: options, now: now) == 1)
            #expect(ChoiceMatcher.pick("the last one", options: options, now: now) == 1)
            #expect(ChoiceMatcher.pick("the one with Mark", options: options, now: now) == 1)
            #expect(ChoiceMatcher.pick("the one at 15:00", options: options, now: now) == 1)
            #expect(ChoiceMatcher.pick("budget", options: options, now: now) == 0)
            #expect(ChoiceMatcher.pick("2", options: options, now: now) == 1)
            #expect(ChoiceMatcher.pick("the third one", options: options, now: now) == nil)
            #expect(ChoiceMatcher.pick("move the meeting to 18:00", options: options, now: now) == nil)
            #expect(ChoiceMatcher.pick("what's the weather?", options: options, now: now) == nil)
            #expect(ChoiceMatcher.pick("dunno", options: options, now: now) == nil)
            #expect(ChoiceMatcher.pick("the one from last friday", options: options, now: now) == nil)

            #expect(ChoiceMatcher.ordinal("move the first one to 16:00", count: 3) == 0)
            #expect(ChoiceMatcher.ordinal("delete the last one", count: 3) == 2)
            #expect(ChoiceMatcher.ordinal("reply to number 2 saying ok", count: 3) == 1)
            #expect(ChoiceMatcher.ordinal("forward the last email from Mario to Julia", count: 3) == nil)
            #expect(ChoiceMatcher.ordinal("move it an hour earlier", count: 3) == nil)
            #expect(ChoiceMatcher.ordinal("what did I do last week?", count: 3) == nil)
        }
    }

    // MARK: - Ciò che è selezionato

    private func email() -> ScreenItem {
        var item = ScreenItem(app: "Mail", kind: .email, title: "March invoice", details: "from Mario Rossi",
                              text: "Hi Ivan, see you on Thursday at 3 pm at 3 Rome Street for the invoice.", reference: "4242")
        item.recipientName = "Mario Rossi"
        item.email = "mario@example.com"
        item.mail = MailMessage(id: "4242", subject: "March invoice", sender: "Mario Rossi <mario@example.com>", date: "Sep 23",
                                content: "Hi Ivan, see you on Thursday at 3 pm at 3 Rome Street for the invoice.")
        return item
    }

    @Test func references() {
        english {
            let mail = email()
            #expect(mail.reference(in: "summarize this email") == .strong)
            #expect(mail.reference(in: "reply to this email that it's fine") == .strong)
            #expect(mail.reference(in: "what's written here?") == .strong)
            #expect(mail.reference(in: "summarize the open email") == .strong)
            #expect(mail.reference(in: "summarize it") == .weak)
            #expect(mail.reference(in: "summarize") == .weak)
            #expect(mail.reference(in: "translate this into Italian") == .weak)
            #expect(mail.reference(in: "who sent it?") == .weak)
            #expect(mail.reference(in: "forward it to Julia") == .weak)
            #expect(mail.reference(in: "what do I have this week?") == .none)
            #expect(mail.reference(in: "what's the weather like in Rome tomorrow?") == .none)
            let contact = ScreenItem(app: "Contacts", kind: .contact, title: "Mario Rossi")
            #expect(contact.reference(in: "what's his number?") == .weak)
            #expect(contact.reference(in: "send him a message") == .weak)
            // Le parole della vista le dà l'app (in italiano): valgono anche tradotte e al plurale.
            let overview = ScreenItem(app: "Mail", kind: .overview, title: "Inbox", nouns: ["email", "mail", "posta"])
            #expect(overview.reference(in: "which of these emails are important?") == .strong)
            #expect(overview.reference(in: "summarize") == .none)
            #expect(mail.headline == "Mail: email “March invoice” (from Mario Rossi)")
            #expect(ScreenItem.Kind.note.noun == "note")
        }
        // In italiano la riga resta com'era.
        Language.$scoped.withValue(.it) {
            #expect(email().headline == "Mail: email «March invoice» (from Mario Rossi)")
            #expect(ScreenItem.Kind.note.noun == "nota")
        }
    }

    @Test func questions() {
        english {
            #expect(ScreenItem.isQuestion("summarize this email"))
            #expect(ScreenItem.isQuestion("who sent it?"))
            #expect(ScreenItem.isQuestion("translate it into Italian"))
            #expect(ScreenItem.isQuestion("what's his number?"))
            #expect(ScreenItem.isQuestion("what did I do today?"))
            #expect(ScreenItem.isQuestion("can you tell me what it says?"))
            #expect(!ScreenItem.isQuestion("create an event from this email"))
            #expect(!ScreenItem.isQuestion("reply that it's fine"))
            #expect(!ScreenItem.isQuestion("add milk here"))
            #expect(!ScreenItem.isQuestion("summarize it and send it to Julia"))
            #expect(!ScreenItem.isQuestion("can you create a reminder from this email?"))
        }
    }

    @Test func noteLines() {
        english {
            #expect(ScreenItem.noteLines(from: "add milk and eggs here") == ["milk", "eggs"])
            #expect(ScreenItem.noteLines(from: "add to this note: milk") == ["milk"])
            #expect(ScreenItem.noteLines(from: "write here that there's a strike tomorrow") == ["there's a strike tomorrow"])
            #expect(ScreenItem.noteLines(from: "add here").isEmpty)
        }
    }

    @MainActor @Test func actionsOnWhatIsSelected() {
        english {
            let assistant = Assistant()
            var work = WorkContext()

            // Email aperta: «reply that it's fine» risponde a quella; «reply to Luke…» cerca l'email di Luke.
            work.screen = email()
            assistant.work = work
            assistant.updateScreen()
            assistant.prepareScreen(for: "reply that it's fine")
            #expect(assistant.screenAction("reply that it's fine")?.action == .rispondi_email)
            #expect(assistant.screenAction("reply that it's fine")?["testo"] == "it's fine")
            #expect(assistant.screenAction("reply that it's fine and that I'll bring the documents")?["testo"] == "it's fine and that I'll bring the documents")
            #expect(assistant.decidedByRules("reply that it's fine"))
            assistant.prepareScreen(for: "reply to this email that I'll be there")
            #expect(assistant.screenAction("reply to this email that I'll be there")?["testo"] == "I'll be there")
            #expect(assistant.recentMail?.id == "4242")
            #expect(assistant.screenAction("forward it to Julia")?.action == .inoltra_email)
            #expect(assistant.screenAction("reply only with yes or no") == nil)
            assistant.prepareScreen(for: "reply to Luke that I'll be there")
            #expect(assistant.screenAction("reply to Luke that I'll be there") == nil)
            // Domande su ciò che si vede: si risponde leggendolo.
            assistant.prepareScreen(for: "summarize it")
            #expect(assistant.screenAction("summarize it") == nil && assistant.screenPointed && ScreenItem.isQuestion("summarize it"))
            assistant.prepareScreen(for: "create an event from this email")
            #expect(assistant.screenAction("create an event from this email") == nil && assistant.screenPointed
                    && !ScreenItem.isQuestion("create an event from this email"))

            // Evento appena selezionato: «move it to 16:00» va a quello, con l'occorrenza esatta.
            var selected = ScreenItem(app: "Calendar", kind: .event, title: "Meeting with Mark", reference: "E1")
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            selected.event = EventItem(id: "E1", identifier: "ID1", title: "Meeting with Mark", start: start, end: start.addingTimeInterval(3600),
                                       isAllDay: false, calendar: "Work", color: RGB(red: 0, green: 0, blue: 1), location: nil)
            work.screen = selected
            assistant.work = work
            assistant.updateScreen()
            assistant.prepareScreen(for: "move it to 16:00")
            let move = assistant.screenAction("move it to 16:00")
            #expect(move?.action == .modifica_evento && move?["scelta"] == "ID1|\(start.timeIntervalSince1970)")
            assistant.prepareScreen(for: "delete this event")
            #expect(assistant.screenAction("delete this event")?.action == .elimina_evento)

            // Nota aperta: «add milk here»; con il nome di un'altra nota decide la regola generale.
            work.screen = ScreenItem(app: "Notes", kind: .note, title: "Shopping", reference: "x-coredata://note/1")
            assistant.work = work
            assistant.updateScreen()
            assistant.prepareScreen(for: "add milk here")
            #expect(assistant.screenAction("add milk here")?["scelta"] == "x-coredata://note/1")
            assistant.prepareScreen(for: "add milk to the shopping note")
            #expect(assistant.screenAction("add milk to the shopping note") == nil)

            // Contatto aperto: «send him a message» usa il suo numero; «write to Luke» no.
            var contact = ScreenItem(app: "Contacts", kind: .contact, title: "Mario Rossi", reference: "C1")
            contact.recipientName = "Mario Rossi"
            contact.phone = "+39 333 1234567"
            contact.email = "mario@example.com"
            work.screen = contact
            assistant.work = work
            assistant.updateScreen()
            assistant.prepareScreen(for: "send him a message: I'll be there at 5")
            let message = assistant.screenAction("send him a message: I'll be there at 5")
            #expect(message?.action == .invia_messaggio && message?["destinatari"] == "Mario Rossi")
            #expect(assistant.screenHandle(for: "him")?.handle == "+39 333 1234567")
            #expect(assistant.screenAction("write him an email about the quote")?["destinatari"] == "mario@example.com")
            #expect(assistant.screenEmailAddress(for: "him") == "mario@example.com")
            assistant.prepareScreen(for: "write to Luke that I'll be there")
            #expect(assistant.screenAction("write to Luke that I'll be there") == nil)

            // Promemoria appena selezionato: «complete it», «mark it as done», «mark it as important».
            var task = ScreenItem(app: "Reminders", kind: .reminder, title: "Pay the electricity bill", reference: "R1")
            task.reminder = reminder("R1", "Pay the electricity bill")
            work.screen = task
            assistant.work = work
            assistant.updateScreen()
            assistant.prepareScreen(for: "complete it")
            #expect(assistant.screenAction("complete it")?.action == .completa_promemoria)
            #expect(assistant.screenAction("mark it as done")?.action == .completa_promemoria)
            #expect(assistant.screenAction("mark it as important")?.action == .modifica_promemoria)

            // Conversazione aperta: «reply that I'll be there in 10 minutes».
            var chat = ScreenItem(app: "Messages", kind: .chat, title: "Julia", reference: "iMessage;-;+393477654321")
            chat.recipientName = "Julia"
            chat.phone = "+39 347 7654321"
            work.screen = chat
            assistant.work = work
            assistant.updateScreen()
            assistant.prepareScreen(for: "reply that I'll be there in 10 minutes")
            let text = assistant.screenAction("reply that I'll be there in 10 minutes")
            #expect(text?.action == .invia_messaggio && text?["destinatari"] == "Julia")
        }
    }

    @MainActor @Test func questionsAboutWhatIsOpen() {
        english {
            let assistant = Assistant()
            var work = WorkContext()
            work.screen = ScreenItem(app: "Files", kind: .file, title: "Rental contract.pdf",
                                     text: "Rental agreement. Monthly rent: 850 euros, due by the 5th of each month.", reference: "/tmp/c.pdf")
            assistant.work = work
            assistant.updateScreen()
            // Senza «this», ma parla del contratto aperto: il testo entra nel contesto (decide il pianificatore).
            assistant.prepareScreen(for: "how much rent do I pay each month?")
            #expect(assistant.screenFocus != nil && !assistant.screenPointed)
            // Parole come «what», «like», «with» non bastano per dire che la domanda parla dell'email aperta.
            var mail = email()
            mail.text = "Let me know what you think, I would like to meet with you."
            #expect(!Assistant.mentions("what's the weather like with this wind?", mail))
            #expect(Assistant.mentions("when do I meet Mario for the invoice?", mail))
        }
    }

    @MainActor @Test func preambleInEnglish() {
        english {
            let assistant = Assistant()
            var work = WorkContext()
            work.screen = email()
            assistant.work = work
            assistant.updateScreen()
            assistant.prepareScreen(for: "summarize this email")
            #expect(assistant.screenPreamble().first?.hasPrefix("On screen, in the front tab: Mail: email “March invoice”") == true)
        }
    }

    /// Le risposte alle domande di prima: «the second one», il testo della risposta a un'email.
    @MainActor @Test func answersToQuestions() {
        english {
            let assistant = Assistant()
            let events = [event("Budget meeting", at(24, 10)), event("Meeting with Mark", at(24, 15))]
            guard case .message(let question) = assistant.askWhich(.elimina_evento, prompt: "cancel the meeting", events: events) else {
                Issue.record("askWhich non ha fatto una domanda")
                return
            }
            #expect(question.hasPrefix("I found 2 events. Which one should I delete?"))
            #expect(question.contains("“Meeting with Mark”") && question.contains("Reply with the number"))
            let resumed = assistant.resumePending("the second one")
            #expect(resumed?.plan.action == .elimina_evento && resumed?.plan["scelta"] == "Meeting with Mark|\(at(24, 15).timeIntervalSince1970)")

            let mail = MailMessage(id: "42", subject: "Dinner", sender: "Mario Rossi <mario@example.com>", date: "Sep 23")
            assistant.pendingReply = mail
            let dictated = assistant.resumePending("tell him I'll be there at 5")
            #expect(dictated?.plan.action == .rispondi_email && dictated?.plan["testo"] == "I'll be there at 5")
            #expect(dictated?.prompt == "reply to Mario Rossi: I'll be there at 5")
            assistant.pendingReply = mail
            #expect(assistant.resumePending("Thursday works for me")?.plan["testo"] == "Thursday works for me")
            // Un comando nuovo o una domanda non sono il testo della risposta.
            assistant.pendingReply = mail
            #expect(assistant.resumePending("create a note about the trip") == nil)
            assistant.pendingReply = mail
            #expect(assistant.resumePending("what's the weather tomorrow?") == nil)
        }
        // In italiano la domanda resta com'era.
        Language.$scoped.withValue(.it) {
            let assistant = Assistant()
            let events = [event("Riunione budget", at(24, 10)), event("Riunione con Marco", at(24, 15))]
            guard case .message(let question) = assistant.askWhich(.elimina_evento, prompt: "cancella la riunione", events: events) else {
                Issue.record("askWhich non ha fatto una domanda")
                return
            }
            #expect(question.hasPrefix("Ho trovato 2 eventi. Quale elimino?\n\n1. «Riunione budget» · "))
            #expect(question.hasSuffix("\n\nRispondi con il numero, l'orario o il titolo (per esempio «la seconda»)."))
        }
    }
}
