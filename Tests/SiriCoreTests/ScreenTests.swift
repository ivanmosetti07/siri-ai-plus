import Foundation
import Testing
@testable import SiriCore

/// Ciò che l'utente vede nelle app: «questa email», «qui», «riassumila», «spostalo», «mandagli un messaggio».
@Suite struct ScreenTests {
    private func email() -> ScreenItem {
        var item = ScreenItem(app: "Mail", kind: .email, title: "Fattura di marzo", details: "da Mario Rossi",
                              text: "Ciao Ivan, ci vediamo giovedì alle 15 in via Roma 3 per la fattura.", reference: "4242")
        item.recipientName = "Mario Rossi"
        item.email = "mario@esempio.it"
        item.mail = MailMessage(id: "4242", subject: "Fattura di marzo", sender: "Mario Rossi <mario@esempio.it>", date: "23 set",
                                content: "Ciao Ivan, ci vediamo giovedì alle 15 in via Roma 3 per la fattura.")
        return item
    }

    @Test func references() {
        let mail = email()
        #expect(mail.reference(in: "riassumi questa email") == .strong)
        #expect(mail.reference(in: "rispondi a quest'email che va bene") == .strong)
        #expect(mail.reference(in: "cosa c'è scritto qui?") == .strong)
        #expect(mail.reference(in: "l'email aperta di cosa parla?") == .strong)
        #expect(mail.reference(in: "riassumila") == .weak)
        #expect(mail.reference(in: "riassumi") == .weak)
        #expect(mail.reference(in: "traduci questo in inglese") == .weak)
        #expect(mail.reference(in: "cosa ho questa settimana?") == .none)
        #expect(mail.reference(in: "che tempo fa domani a Roma?") == .none)
        let contact = ScreenItem(app: "Contatti", kind: .contact, title: "Mario Rossi")
        #expect(contact.reference(in: "qual è il suo numero?") == .weak)
        let overview = ScreenItem(app: "Mail", kind: .overview, title: "casella «In arrivo»", nouns: ["email", "mail", "posta"])
        #expect(overview.reference(in: "quali di queste email sono importanti?") == .strong)
        #expect(overview.reference(in: "riassumi") == .none)
    }

    @Test func questions() {
        #expect(ScreenItem.isQuestion("riassumi questa email"))
        #expect(ScreenItem.isQuestion("chi l'ha mandata?"))
        #expect(ScreenItem.isQuestion("traduci in inglese"))
        #expect(ScreenItem.isQuestion("qual è il suo numero?"))
        #expect(!ScreenItem.isQuestion("crea un promemoria da questa email"))
        #expect(!ScreenItem.isQuestion("rispondi che va bene"))
        #expect(!ScreenItem.isQuestion("aggiungi il latte qui"))
    }

    @Test func noteLines() {
        #expect(ScreenItem.noteLines(from: "aggiungi il latte e le uova qui") == ["latte", "uova"])
        #expect(ScreenItem.noteLines(from: "aggiungi a questa nota: latte") == ["latte"])
        #expect(ScreenItem.noteLines(from: "scrivi qui che domani c'è sciopero") == ["domani c'è sciopero"])
        #expect(ScreenItem.noteLines(from: "aggiungi qui").isEmpty)
    }

    @MainActor @Test func actionsOnWhatIsSelected() {
        let assistant = Assistant()
        var work = WorkContext()

        // Email aperta: «rispondi che va bene» risponde a quella; «rispondi a Luca…» cerca l'email di Luca.
        work.screen = email()
        assistant.work = work
        assistant.updateScreen()
        assistant.prepareScreen(for: "rispondi che va bene")
        #expect(assistant.screenAction("rispondi che va bene")?.action == .rispondi_email)
        #expect(assistant.screenAction("rispondi che va bene e che porto i documenti")?["testo"] == "va bene e che porto i documenti")
        assistant.prepareScreen(for: "rispondi a questa email che arrivo")
        #expect(assistant.screenAction("rispondi a questa email che arrivo")?["testo"] == "arrivo")
        #expect(assistant.recentMail?.id == "4242")
        #expect(assistant.recentMail?.content.contains("giovedì") == true)
        #expect(assistant.screenAction("inoltrala a Giulia")?.action == .inoltra_email)
        assistant.prepareScreen(for: "rispondi a Luca che arrivo")
        #expect(assistant.screenAction("rispondi a Luca che arrivo") == nil)

        // Evento appena selezionato: «spostalo alle 16» va a quello, con l'occorrenza esatta.
        var event = ScreenItem(app: "Calendario", kind: .event, title: "Riunione con Marco", reference: "E1")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        event.event = EventItem(id: "E1", identifier: "ID1", title: "Riunione con Marco", start: start, end: start.addingTimeInterval(3600),
                                isAllDay: false, calendar: "Lavoro", color: RGB(red: 0, green: 0, blue: 1), location: nil)
        work.screen = event
        assistant.work = work
        assistant.updateScreen()
        assistant.prepareScreen(for: "spostalo alle 16")
        let move = assistant.screenAction("spostalo alle 16")
        #expect(move?.action == .modifica_evento)
        #expect(move?["scelta"] == "ID1|\(start.timeIntervalSince1970)")
        #expect(assistant.recentEvent?.identifier == "ID1")

        // Nota aperta: «aggiungi il latte qui»; con il nome di un'altra nota decide la regola generale.
        work.screen = ScreenItem(app: "Note", kind: .note, title: "Spesa", reference: "x-coredata://nota/1")
        assistant.work = work
        assistant.updateScreen()
        assistant.prepareScreen(for: "aggiungi il latte qui")
        #expect(assistant.screenAction("aggiungi il latte qui")?["scelta"] == "x-coredata://nota/1")
        assistant.prepareScreen(for: "aggiungi il latte alla nota della spesa")
        #expect(assistant.screenAction("aggiungi il latte alla nota della spesa") == nil)

        // Contatto aperto: «mandagli un messaggio» usa il suo numero; «scrivi a Luca» no.
        var contact = ScreenItem(app: "Contatti", kind: .contact, title: "Mario Rossi", reference: "C1")
        contact.recipientName = "Mario Rossi"
        contact.phone = "+39 333 1234567"
        contact.email = "mario@esempio.it"
        work.screen = contact
        assistant.work = work
        assistant.updateScreen()
        assistant.prepareScreen(for: "mandagli un messaggio: arrivo alle 5")
        let message = assistant.screenAction("mandagli un messaggio: arrivo alle 5")
        #expect(message?.action == .invia_messaggio && message?["destinatari"] == "Mario Rossi")
        #expect(assistant.screenHandle(for: "lui")?.handle == "+39 333 1234567")
        #expect(assistant.screenAction("scrivigli un'email per il preventivo")?["destinatari"] == "mario@esempio.it")
        #expect(assistant.screenEmailAddress(for: "Mario") == "mario@esempio.it")
        #expect(assistant.screenEmailAddress(for: "Luca") == nil)
        assistant.prepareScreen(for: "scrivi a Luca che arrivo")
        #expect(assistant.screenAction("scrivi a Luca che arrivo") == nil)
        #expect(assistant.screenHandle(for: "Luca") == nil)
    }

    @MainActor @Test func questionsAboutWhatIsOpen() {
        let assistant = Assistant()
        var work = WorkContext()
        work.screen = ScreenItem(app: "File", kind: .file, title: "Contratto affitto.pdf",
                                 text: "Contratto di locazione. Canone mensile: 850 euro, entro il giorno 5 di ogni mese.", reference: "/tmp/c.pdf")
        assistant.work = work
        assistant.updateScreen()
        // Senza «questo», ma parla del contratto aperto: il testo entra nel contesto (decide il pianificatore).
        assistant.prepareScreen(for: "quanto pago di affitto al mese?")
        #expect(assistant.screenFocus != nil && !assistant.screenPointed)
        #expect(assistant.withContext("quanto pago di affitto al mese?").contains("850 euro"))
        // Non c'entra: niente testo.
        assistant.prepareScreen(for: "che tempo fa domani a Roma?")
        #expect(assistant.screenFocus == nil)
    }

    @MainActor @Test func preambleShowsWhatMatters() {
        let assistant = Assistant()
        var work = WorkContext()
        work.screen = email()
        work.openTabs = ["Note: nota «Spesa»"]
        assistant.work = work
        assistant.updateScreen()
        assistant.prepareScreen(for: "riassumi questa email")
        let about = assistant.withContext("riassumi questa email")
        #expect(about.contains("Fattura di marzo") && about.contains("giovedì alle 15") && about.contains("Note: nota «Spesa»"))
        // Una domanda che non c'entra: solo una riga, senza il testo dell'email.
        assistant.prepareScreen(for: "che tempo fa domani?")
        let unrelated = assistant.withContext("che tempo fa domani?")
        #expect(unrelated.contains("usalo solo se la richiesta ne parla") && !unrelated.contains("giovedì alle 15"))
    }
}
