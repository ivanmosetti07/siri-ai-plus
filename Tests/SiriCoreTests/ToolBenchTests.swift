import Foundation
import Testing
@testable import SiriCore

/// Banco degli strumenti per modello: casi, controlli sulle chiamate, mondo inventato e blocco dei dati veri.
@Suite(.serialized) @MainActor struct ToolBenchTests {
    func decode(_ json: String) throws -> ToolCase {
        try JSONDecoder().decode(ToolCase.self, from: Data(json.utf8))
    }

    func call(_ tool: String, _ fields: [String: String] = [:], card: String? = nil) -> FixtureWorld.Call {
        FixtureWorld.Call(tool: tool, fields: fields, card: card, ok: true)
    }

    func failures(_ test: ToolCase, _ calls: [FixtureWorld.Call], path: String = "strumenti", answer: String = "Ecco.",
                  log: [String] = [], blocked: [String] = []) -> [String] {
        ToolBench.failures(test, calls: calls, path: path, answer: answer, blocked: blocked, connectorLog: log, external: true)
    }

    @Test func casesDecodeWithTheirExpectations() throws {
        let test = try decode(#"{"id":"x","domanda":"Leggi e ricordami","strumenti":["leggi_email","crea_promemoria"],"in_ordine":true,"schede":["promemoria"],"massimo_chiamate":3,"argomenti":{"crea_promemoria":{"scadenza":"^2026"}},"vieta_strumenti":["mcp:*"],"regole":true}"#)
        #expect(test.base.turns == ["Leggi e ricordami"] && test.tools == ["leggi_email", "crea_promemoria"] && test.inOrder)
        #expect(test.cards == ["promemoria"] && test.maxCalls == 3 && test.arguments["crea_promemoria"]?["scadenza"] == "^2026")
        #expect(test.forbiddenTools == ["mcp:*"] && test.rules == true && !test.noTools)
        // I casi degli altri banchi restano validi (i campi nuovi sono facoltativi).
        let old = try decode(#"{"id":"crm","connettori":["crm"],"domanda":"Quali task?","chiamate":["list_tasks"],"deve":["preventivo"]}"#)
        #expect(old.tools.isEmpty && old.base.calls == ["list_tasks"] && old.base.connectors == ["crm"])
    }

    @Test func expectedToolsAlternativesOrderAndForbidden() throws {
        let test = try decode(#"{"id":"x","domanda":"q","strumenti":["leggi_email|leggi_messaggi","crea_promemoria"],"in_ordine":true,"vieta_strumenti":["invia_messaggio"]}"#)
        #expect(failures(test, [call("leggi_messaggi"), call("crea_promemoria", card: "promemoria")]).isEmpty)
        #expect(failures(test, [call("crea_promemoria"), call("leggi_email")]).contains { $0.hasPrefix("ordine sbagliato") })
        #expect(failures(test, [call("leggi_email")]).contains("non ha usato crea_promemoria"))
        #expect(failures(test, [call("leggi_email"), call("crea_promemoria"), call("invia_messaggio")]).contains { $0.hasSuffix("(vietato)") })
    }

    @Test func connectorLabelsAndWildcards() throws {
        let catalog = try decode(#"{"id":"x","domanda":"q","strumenti":["mcp:execute_read_tool:invoices_list"]}"#)
        #expect(failures(catalog, [call("mcp:search_tools"), call("mcp:execute_read_tool:invoices_list")]).isEmpty)
        let any = try decode(#"{"id":"x","domanda":"q","strumenti":["mcp:search|mcp:get_client"],"vieta_strumenti":["cerca_web"]}"#)
        #expect(failures(any, [call("mcp:get_client")]).isEmpty)
        let none = try decode(#"{"id":"x","domanda":"Che tempo fa?","vieta_strumenti":["mcp:*"]}"#)
        #expect(failures(none, [call("mcp:list_tasks")]).contains { $0.hasSuffix("(vietato)") })
        #expect(failures(none, [call("cerca_web")]).isEmpty)
    }

    @Test func silenceAndCallLimits() throws {
        let silent = try decode(#"{"id":"x","domanda":"Chi ha scritto I promessi sposi?","nessuno_strumento":true}"#)
        #expect(failures(silent, []).isEmpty)
        #expect(failures(silent, [call("cerca_web")]).contains { $0.hasPrefix("strumenti non necessari") })
        let limited = try decode(#"{"id":"x","domanda":"q","strumenti":["agenda"],"massimo_chiamate":1}"#)
        #expect(failures(limited, [call("agenda"), call("agenda")]).contains { $0.hasPrefix("2 chiamate") })
        // Le letture di riserva dell'app valgono come letture ma non come chiamate del modello.
        let mail = try decode(#"{"id":"x","domanda":"q","strumenti":["leggi_email"],"massimo_chiamate":1}"#)
        #expect(failures(mail, [call("leggi_email", ["cerca": "Paolo", "ripiego": "sì"]), call("leggi_messaggi")]).isEmpty)
    }

    @Test func argumentsOnNormalizedDraftsWithRelativeDays() throws {
        let test = try decode(#"{"id":"x","domanda":"q","strumenti":["crea_evento"],"schede":["evento"],"argomenti":{"crea_evento":{"inizio":"^{{giorno:giovedì}} 15:00","titolo":"commercialista"}}}"#)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let thursday = try #require(Language.$scoped.withValue(.it) { DateExpressions.days(in: "giovedì").first?.date })
        let good = call("crea_evento", ["titolo": "Commercialista", "inizio": formatter.string(from: thursday) + " 15:00"], card: "evento")
        #expect(failures(test, [good]).isEmpty)
        let wrong = call("crea_evento", ["titolo": "Commercialista", "inizio": formatter.string(from: thursday) + " 16:00"], card: "evento")
        #expect(failures(test, [wrong]).contains { $0.hasPrefix("crea_evento.inizio non corrisponde") })
        #expect(failures(test, [call("crea_evento", ["titolo": "Commercialista", "inizio": formatter.string(from: thursday) + " 15:00"])])
            .contains("manca la scheda «evento»"))
    }

    @Test func cardsClaimedDoneAndRealWrites() throws {
        let test = try decode(#"{"id":"x","domanda":"q","strumenti":["mcp:create_task"],"schede":["connettore|email"]}"#)
        let held = call("mcp:create_task", card: "connettore")
        #expect(failures(test, [held], answer: "Ti ho preparato il task: confermalo nella scheda.").isEmpty)
        #expect(failures(test, [held], answer: "Ho creato il task su Demo CRM.").contains { $0.hasPrefix("dice «fatto»") })
        #expect(failures(test, [held], log: ["Demo CRM · create_task"]).contains { $0.hasPrefix("scrittura arrivata al connettore") })
        #expect(failures(test, [held], blocked: ["AppleScript verso Mail"]).contains { $0.hasPrefix("accessi ai dati veri bloccati") })
    }

    @Test func rulesAndPlansArePaths() throws {
        let test = try decode(#"{"id":"x","domanda":"Sposta la riunione","regole":true,"strumenti":["modifica_evento"]}"#)
        #expect(failures(test, [call("modifica_evento")], path: "strumenti").contains { $0.hasPrefix("doveva decidere l'app") })
        #expect(failures(test, [call("modifica_evento")], path: "regole").isEmpty)
        // Sulla strada di Apple (anche con Auto) le regole valgono comunque per prime.
        #expect(failures(test, [call("modifica_evento")], path: "apple").isEmpty)
        let file = URL(fileURLWithPath: "/tmp/2026-09-28-1554-strumenti-modelli-claude-sonnet-low-prima.json")
        #expect(ToolBench.runDate(file).map { Calendar.current.component(.hour, from: $0) } == 15)
        #expect(failures(test, [call("modifica_evento")], path: "piano").contains { $0.hasPrefix("ha scelto un piano") })
    }

    @Test func routingOnlyChecksWhatIsOffered() throws {
        let test = try decode(#"{"id":"x","domanda":"q","strumenti":["agenda","mcp:list_tasks"]}"#)
        #expect(ToolBench.offeredFailures(test, offered: ["agenda", "mcp__Demo_CRM__list_tasks"], path: "smistamento").isEmpty)
        #expect(ToolBench.offeredFailures(test, offered: ["cerca_web"], path: "smistamento") == ["non offerto: agenda", "non offerto: mcp:list_tasks"])
        let silent = try decode(#"{"id":"x","domanda":"Ciao","nessuno_strumento":true}"#)
        #expect(!ToolBench.offeredFailures(silent, offered: ["cerca_web"], path: "smistamento").isEmpty)
    }

    @Test func appleActionsMapToToolNames() {
        #expect(ToolRegistry.toolName(forAction: .rispondi) == nil)
        #expect(ToolRegistry.toolName(forAction: .eventi) == "agenda")
        #expect(ToolRegistry.toolName(forAction: .mail_leggi) == "leggi_email")
        #expect(ToolRegistry.toolName(forAction: .modifica_nota) == "aggiungi_a_nota")
        #expect(ToolRegistry.toolName(forAction: .file) == "cerca_file_mac")
        #expect(ToolRegistry.toolName(forAction: .modifica_artefatto) == "modifica_aperto")
        #expect(ToolRegistry.toolName(forAction: .crea_evento) == "crea_evento")
        #expect(ToolRegistry.toolName(forAction: .crea_foglio) == "crea_foglio")
    }

    // MARK: Mondo inventato

    static let world = #"""
    {"utente": "Mario Rossi", "calendari": ["Lavoro"], "liste": ["Promemoria", "Spesa"],
     "eventi": [{"titolo": "Riunione con Marco", "giorno": 1, "inizio": "10:00", "fine": "11:00"}, {"titolo": "Dentista", "giorno": 6, "inizio": "17:30"}],
     "promemoria": [{"titolo": "Bolletta", "giorno": 2}, {"titolo": "Latte", "lista": "Spesa"}],
     "email": [{"id": "1", "oggetto": "Preventivo cucina", "mittente": "Paolo Verdi <paolo@example.com>", "giorni_fa": 1, "testo": "12.400 €", "non_letta": true},
               {"id": "2", "oggetto": "Pacco", "mittente": "Amazon <a@example.com>", "giorni_fa": 0, "testo": "Arriva oggi"},
               {"id": "3", "oggetto": "Dichiarazione", "mittente": "Studio Neri Commercialisti <neri@example.com>", "giorni_fa": 3, "testo": "Servono le ricevute mediche"}],
     "note": [{"id": "N1", "titolo": "Lista della spesa", "testo": "- pane"}],
     "messaggi": [{"persona": "Giulia", "recapito": "+39 333 000 1111", "testo": "Cinema alle 8?", "minuti_fa": 5}],
     "file": [{"percorso": "/Demo/Contratto affitto.pdf", "testo": "Canone 850 €"}],
     "contatti": [{"nome": "Giulia Russo", "email": "giulia@example.com", "telefono": "+39 333 000 1111"}],
     "conversazioni": [{"titolo": "Viaggio a Lisbona", "giorni_fa": 20, "testo": "Volo TAP e hotel in Alfama"}],
     "web": [{"parole": ["benzina"], "titolo": "Prezzi", "url": "https://example.com/p", "testo": "1,79 € al litro"}]}
    """#

    func makeWorld() throws -> FixtureWorld {
        let file = FileManager.default.temporaryDirectory.appending(path: "mondo-\(UUID().uuidString).json")
        try Self.world.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        return try FixtureWorld(file: file)
    }

    @Test func worldAnswersLikeTheApps() throws {
        let world = try makeWorld()
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        let events = world.events(from: tomorrow, to: calendar.date(byAdding: .day, value: 1, to: tomorrow)!)
        #expect(events.map(\.title) == ["Riunione con Marco"] && calendar.component(.hour, from: events[0].start) == 10)
        #expect(world.openReminders(limit: 10, list: "Spesa").map(\.title) == ["Latte"])
        #expect(world.mailInbox(query: "Paolo", unreadOnly: false, limit: 5).rows.count == 1)
        #expect(world.mailInbox(query: nil, unreadOnly: true, limit: 5).rows.map(\.title) == ["● Preventivo cucina"])
        #expect(world.mailFind(person: "Paolo Verdi", subject: nil, limit: 3).first?.content == "12.400 €")
        #expect(world.notesSearch("spesa", limit: 5).rows.first?.title == "Lista della spesa")
        #expect(world.messages(matching: "Giulia", limit: 5).rows.first?.detail == "Cinema alle 8?")
        #expect(world.fileSearch("contratto", limit: 5).rows.first?.title == "Contratto affitto.pdf")
        #expect(world.contactHandles("Giulia").contains("+39 333 000 1111"))
        #expect(world.conversations("Lisbona", limit: 3).first?.title == "Viaggio a Lisbona")
        #expect(world.webSearch("prezzo benzina oggi", limit: 3).first?.title == "Prezzi")
        #expect(world.webSearch("qualcosa di nuovo", limit: 3).count == 1)
    }

    @Test func servicesUseTheWorldAndBlockRealAccess() async throws {
        let world = try makeWorld()
        FixtureWorld.active = world
        defer { FixtureWorld.active = nil }
        #expect(EventKitService.writableCalendars() == ["Lavoro"] && EventKitService.defaultCalendar == "Lavoro")
        #expect(try await MailReader.inbox(query: "Amazon").rows.count == 1)
        #expect(try await NotesService.search("spesa").rows.count == 1)
        #expect(try MessagesService.recent(matching: "Giulia").rows.count == 1)
        #expect(Contacts.resolve("Giulia") == "+39 333 000 1111")
        // Ciò che resterebbe vero (AppleScript verso Mail, un evento salvato) non parte e si conta.
        await #expect(throws: (any Error).self) { try await AppleScript.run("return 1", app: "Mail") }
        #expect(throws: (any Error).self) { try EventKitService.save(EventDraft(title: "x", start: .now, end: .now.addingTimeInterval(3600), isAllDay: false, calendar: "Lavoro", location: "")) }
        #expect(world.blocked.count == 2)
    }

    @Test func emptyReadsLookElsewhere() async throws {
        let world = try makeWorld()
        FixtureWorld.active = world
        defer { FixtureWorld.active = nil }
        let assistant = Assistant()
        // «Mi ha scritto Paolo Verdi?» cercato nei Messaggi: nessun messaggio, ma c'è la sua email (e conta come lettura della posta).
        let texts = await assistant.runTool("leggi_messaggi", arguments: .object(["cerca": .string("Paolo Verdi")]), enabled: [.mail, .messages]) { _ in }
        #expect(texts.text.contains("Preventivo cucina"))
        #expect(world.recorded.map(\.tool) == ["leggi_email", "leggi_messaggi"])
        // Senza la posta fra le fonti non si guarda altrove.
        world.reset()
        let only = await assistant.runTool("leggi_messaggi", arguments: .object(["cerca": .string("Paolo Verdi")]), enabled: [.messages]) { _ in }
        #expect(!only.text.contains("Preventivo cucina"))
        // Nessuna email con quelle parole: le ultime ricevute, dette per quello che sono.
        let mail = await assistant.runTool("leggi_email", arguments: .object(["cerca": .string("bolletta della luce")]), enabled: [.mail]) { _ in }
        #expect(mail.text.contains("Nessuna email con «bolletta della luce»") && mail.text.contains("Pacco"))
        // Chi scrive si cerca anche nell'altra lingua, e al plurale: «accountant» e «commercialista» trovano «Commercialisti».
        for role in ["accountant", "commercialista"] {
            let found = await assistant.runTool("leggi_email", arguments: .object(["cerca": .string(role)]), enabled: [.mail]) { _ in }
            #expect(found.text.contains("Dichiarazione") && !found.text.contains("Pacco"), "\(role)")
        }
    }

    @Test func recordsDraftsWithComparableFields() throws {
        let world = try makeWorld()
        FixtureWorld.active = world
        defer { FixtureWorld.active = nil }
        let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: .now)!
        let draft = EventDraft(title: "Commercialista", start: start, end: start.addingTimeInterval(3600), isAllDay: false, calendar: "Lavoro", location: "")
        world.recordTool("crea_evento", arguments: .object(["titolo": .string("Commercialista")]),
                         result: ToolCallResult(text: "Bozza pronta", outcome: .eventDraft(draft)))
        let recorded = try #require(world.recorded.first)
        #expect(recorded.tool == "crea_evento" && recorded.card == "evento" && recorded.fields["inizio"]?.hasSuffix(" 15:00") == true)
        // I connettori si registrano con la loro etichetta (letture libere o schede trattenute).
        world.recordTool("mcp__Demo_CRM__list_tasks", arguments: .object([:]), result: ToolCallResult(text: ""))
        #expect(world.recorded.count == 1)
    }

    @Test func canaryStopsTheRealNameOnlyDuringBenches() {
        BenchIsolation.canary = []
        #expect(!BenchIsolation.leaks("Ciao Ivan"))
        BenchIsolation.canary = ["Ivan"]
        defer { BenchIsolation.canary = [] }
        #expect(BenchIsolation.leaks("Firma: Ivan."))
        #expect(!BenchIsolation.leaks("Ivanka e Mario"))
    }
}
