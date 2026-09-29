import Foundation
import Testing
@testable import SiriCore

/// La strada dei modelli esterni (Gemma, ds4, ChatGPT, Claude): quali strumenti ricevono, con quali descrizioni e istruzioni,
/// e come si leggono le loro chiamate.
@Suite(.serialized) @MainActor struct ExternalHarnessTests {
    func connector(_ name: String, server: String = "Demo CRM", readOnly: Bool? = nil, description: String = "") -> MCPToolInfo {
        MCPToolInfo(serverID: UUID(), serverName: server, name: name, description: description, inputSchema: .object(["type": .string("object")]),
                    readOnlyHint: readOnly)
    }

    func assistant(budget: ContextBudget = .of(.claude), artifact: String? = nil) -> Assistant {
        let assistant = Assistant()
        var work = WorkContext()
        work.webEnabled = true
        work.mcpTools = [connector("list_clients", description: "List the CRM clients"), connector("list_tasks", description: "List tasks with due dates"),
                         connector("create_task", readOnly: false, description: "Create a task for a client")]
        if let artifact {
            work.artifactKind = "documento"
            work.artifactTitle = "Budget evento"
            work.artifactText = artifact
        }
        assistant.work = work
        assistant.budget = budget
        return assistant
    }

    let sources: Set<SourceKind> = [.calendar, .reminders, .mail, .notes, .files, .messages]

    func names(_ tools: [ToolSpec]) -> [String] { tools.map(\.name) }

    @Test func greetingsAndTextTasksGetNoTools() {
        let assistant = assistant()
        #expect(assistant.externalToolList(for: "Ciao! Come va?", route: ToolRoute(decided: true), enabled: sources).isEmpty)
        #expect(assistant.externalToolList(for: "Traduci in inglese: «ci vediamo domani»", route: ToolRoute(decided: true), enabled: sources).isEmpty)
    }

    @Test func webOnlyWhenItServes() {
        let assistant = assistant()
        // Nessuna area e niente di attuale: nessuno strumento (prima il web c'era sempre).
        #expect(assistant.externalToolList(for: "Spiegami la fotosintesi", route: ToolRoute(decided: true), enabled: sources).isEmpty)
        #expect(names(assistant.externalToolList(for: "Quanto costa oggi la benzina?", route: ToolRoute(decided: true), enabled: sources)).contains("cerca_web"))
        // Smistatore senza risposta: il web resta a disposizione.
        #expect(names(assistant.externalToolList(for: "Qualcosa di strano", route: ToolRoute(), enabled: sources)).contains("cerca_web"))
        // Un conto con tutti i numeri nella richiesta lo fa l'app, anche se lo smistatore sceglie il web; un prezzo si cerca.
        let vat = names(assistant.externalToolList(for: "Quanto fa 89,90 € più IVA al 22%?", route: ToolRoute(tools: ["cerca_web", "leggi_pagina"], decided: true), enabled: sources))
        #expect(!vat.contains("cerca_web") && !vat.contains("leggi_pagina"))
        #expect(!Assistant.isSelfContainedCalculation("Quanto costa un iPhone 17?") && Assistant.isSelfContainedCalculation("calcola il 15% di 80"))
        // «Any news from my accountant?»: notizie da una persona, cioè la posta, anche se lo smistatore sceglie pure il web.
        let mailAndWeb = ToolRoute(tools: ["leggi_email", "cerca_web"], decided: true)
        let news = Language.$scoped.withValue(.en) { names(assistant.externalToolList(for: "Any news from my accountant?", route: mailAndWeb, enabled: sources)) }
        #expect(news.contains("leggi_email") && !news.contains("cerca_web"))
        #expect(!names(assistant.externalToolList(for: "Novità dal commercialista?", route: ToolRoute(tools: ["cerca_web"], decided: true), enabled: sources))
            .contains("cerca_web"))
    }

    @Test func doneClaimsWithCardsToConfirm() {
        #expect(Assistant.claimsDone("Ho impostato un promemoria per te: **Rispondi a Paolo Verdi** per venerdì."))
        #expect(Assistant.claimsDone("I've sent the email to Paolo."))
        #expect(!Assistant.claimsDone("Ecco il promemoria: confermalo nella scheda."))
        #expect(!Assistant.claimsDone("It's ready: check the card and confirm."))
        // Senza strumenti che scrivono anche «è pronto da confermare» è inventato; mentre il modello rimedia resta visibile
        // la parte di risposta prima dell'azione raccontata.
        #expect(Assistant.claimsAction("Ho impostato un promemoria per te.\n\nIl promemoria è pronto da confermare."))
        #expect(!Assistant.claimsAction("Paolo ti ha mandato il preventivo della cucina."))
        // Le frasi negative non raccontano azioni (l'email con istruzioni nascoste: «non ho inviato nulla»).
        #expect(!Assistant.claimsAction("L'email chiede di inviare i dati della carta: non ho inviato nulla."))
        #expect(!Assistant.claimsDone("I haven't sent anything."))
        #expect(Assistant.beforeActionClaims("Paolo ti ha mandato il preventivo.\n\nHo impostato un promemoria per te:\n* Venerdì") == "Paolo ti ha mandato il preventivo.")
        // Documenti, fogli, presentazioni e immagini l'app li apre subito; eventi, promemoria e connettori aspettano la conferma.
        #expect(!Assistant.awaitsConfirmation(.sheet(SheetDraft(title: "Spese", columns: ["Importo"], rows: []))))
        #expect(Assistant.awaitsConfirmation(.eventDraft(EventDraft(title: "Commercialista", start: .now, end: .now.addingTimeInterval(3600), calendar: "Lavoro"))))
    }

    @Test func namedConnectorAlwaysBringsItsTools() {
        let assistant = assistant()
        let tools = names(assistant.externalToolList(for: "Quali task ho su Demo CRM?", route: ToolRoute(decided: true), enabled: sources))
        #expect(tools.contains("mcp__Demo_CRM__list_tasks") && tools.contains("mcp__Demo_CRM__create_task"))
        // Una domanda che non riguarda il servizio non lo riceve.
        let other = names(assistant.externalToolList(for: "Mi è arrivato il pacco di Amazon?", route: ToolRoute(tools: ["leggi_email"], decided: true), enabled: sources))
        #expect(!other.contains { $0.hasPrefix("mcp__") })
    }

    @Test func openDocumentEditOnlyForCommands() {
        let assistant = assistant(artifact: "# Budget\n\nTotale: 5.500 €")
        #expect(!names(assistant.externalToolList(for: "Qual è il budget totale?", route: ToolRoute(tools: ["modifica_aperto"], decided: true), enabled: sources))
            .contains("modifica_aperto"))
        #expect(names(assistant.externalToolList(for: "Elimina la sezione Totale", route: ToolRoute(decided: true), enabled: sources)).contains("modifica_aperto"))
        // A una domanda sul documento aperto niente documenti nuovi; se li chiede, sì.
        let documents = ToolRoute(tools: ["crea_documento", "crea_foglio", "crea_presentazione"], decided: true)
        #expect(!names(assistant.externalToolList(for: "Qual è il budget totale?", route: documents, enabled: sources)).contains("crea_foglio"))
        #expect(names(assistant.externalToolList(for: "Puoi crearmi un foglio con queste voci?", route: documents, enabled: sources)).contains("crea_foglio"))
    }

    @Test func smallWindowsGetFewerShorterTools() {
        let small = assistant(budget: .of(.gemma, gemmaContext: 16_384))
        let tools = small.externalToolList(for: "Qualcosa di strano", route: ToolRoute(), enabled: sources)
        #expect(tools.count <= 12 && names(tools).contains("cerca_web"))
        #expect(tools.filter { $0.name.hasPrefix("mcp__") }.allSatisfy { $0.description.count <= 160 })
        let large = assistant().externalToolList(for: "Qualcosa di strano", route: ToolRoute(), enabled: sources)
        #expect(large.count > 12)
    }

    @Test func descriptionsFollowTheLanguageAndTheUser() {
        Assistant.userNameOverride = "Mario Rossi"
        defer { Assistant.userNameOverride = nil }
        let work = assistant().work
        let english = Language.$scoped.withValue(.en) { ToolRegistry.tools(for: work, enabled: sources) }
        #expect(english.first { $0.name == "agenda" }?.description.hasPrefix("Reads calendar events") == true)
        let italian = Language.$scoped.withValue(.it) { ToolRegistry.tools(for: work, enabled: sources) }
        let reply = italian.first { $0.name == "rispondi_email" }?.parameters.compactString ?? ""
        #expect(reply.contains("Mario") && !reply.contains("Ivan"))
        // Gli strumenti che prima avevano solo Apple Intelligence.
        for name in ["completa_promemoria", "crea_foglio", "crea_presentazione", "genera_immagine"] {
            #expect(italian.contains { $0.name == name }, "\(name)")
        }
    }

    @Test func toolGuideOnlyTalksAboutOfferedTools() {
        func spec(_ name: String, _ kind: ToolSpec.Kind = .read) -> ToolSpec { ToolSpec(name: name, description: "", parameters: .object([:]), kind: kind) }
        #expect(ExternalAgent.toolGuide(for: []).isEmpty)
        let web = Language.$scoped.withValue(.it) { ExternalAgent.toolGuide(for: [spec("cerca_web")]) }
        #expect(web.contains("cerca_web") && !web.contains("Le cose dell'utente") && !web.contains("scheda"))
        let writes = Language.$scoped.withValue(.it) { ExternalAgent.toolGuide(for: [spec("agenda"), spec("crea_evento", .draft)]) }
        #expect(writes.contains("pronta da confermare") && writes.contains("Prossimi giorni") && writes.contains("Le cose dell'utente"))
        // «Disegna un gatto»: un'immagine vera, e «disegna» non è «segna come fatto».
        let image = Language.$scoped.withValue(.it) { ExternalAgent.toolGuide(for: [spec("genera_immagine", .draft)]) }
        #expect(image.contains("genera_immagine") && image.contains("caratteri"))
        #expect(!assistant().candidateActions(for: "Disegna un gatto che legge un libro").contains(.completa_promemoria))
        #expect(assistant().candidateActions(for: "Segna come fatto il promemoria della bolletta").contains(.completa_promemoria))
    }

    @Test func codexUsesOnlyTheAppTools() {
        let flags = ExternalAgent.codexIsolation
        for feature in ["shell_tool", "apps", "memories", "computer_use", "browser_use"] { #expect(flags.contains("--disable \(feature)"), "\(feature)") }
        #expect(flags.contains("web_search"))
    }

    @Test func connectorNamesFitClaudeLimit() {
        let long = connector("execute_a_really_long_tool_name_for_reports_and_exports", server: "Agency Operating System Workspace")
        let other = connector("execute_a_really_long_tool_name_for_reports_and_imports", server: "Agency Operating System Workspace")
        #expect(ToolRegistry.mcpName(long).count <= 50 && "mcp__siriai__".count + ToolRegistry.mcpName(long).count <= 64)
        #expect(ToolRegistry.mcpName(long) != ToolRegistry.mcpName(other))
        #expect(ToolRegistry.mcpName(connector("list_tasks")) == "mcp__Demo_CRM__list_tasks")
    }

    @Test func sheetsSlidesAndImagesFromToolArguments() {
        #expect(Assistant.sheetRow("Affitto: 850")?.values == [850])
        #expect(Assistant.sheetRow("Q1: 1.200,50; 980")?.values == [1200.5, 980])
        #expect(Assistant.sheetRow("Solo testo") == nil)
        #expect(Assistant.number("1,200.50 €") == 1200.5 && Assistant.number("12,5") == 12.5)
        let slide = Assistant.slide("Obiettivi: crescere; assumere")
        #expect(slide?.title == "Obiettivi" && slide?.bullets == ["crescere", "assumere"])
        #expect(Assistant.imageStyle("sketch") == "schizzo" && Assistant.imageStyle("Illustration") == "illustrazione")
    }

    @Test func gemmaArgumentsAreReadOrRefused() {
        #expect(ExternalAgent.parsedArguments("")?.object?.isEmpty == true)
        #expect(ExternalAgent.parsedArguments(#"{"cerca": "Paolo"}"#)?["cerca"]?.string == "Paolo")
        #expect(ExternalAgent.parsedArguments("{\"testo\": \"riga uno\nriga due\"}")?["testo"]?.string == "riga uno\nriga due")
        #expect(ExternalAgent.parsedArguments(#""{\"cerca\": \"x\"}""#)?["cerca"]?.string == "x")
        #expect(ExternalAgent.parsedArguments("cerca=Paolo") == nil)
    }

    @Test func daysNamedInTheRequestWin() {
        // Lunedì 28 settembre 2026: «venerdì» è il 2 ottobre, anche se il modello ha scelto il 9.
        let monday = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 9))!
        func day(_ d: Int, hour: Int = 0) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour))! }
        Language.$scoped.withValue(.it) {
            #expect(Assistant.weekCorrection(for: day(9), request: "Ricordami di rispondergli venerdì", now: monday) == -7)
            #expect(Assistant.weekCorrection(for: day(2), request: "Ricordami di rispondergli venerdì", now: monday) == 0)
            #expect(Assistant.weekCorrection(for: day(8, hour: 15), request: "Fissa il commercialista giovedì alle 15", now: monday) == -7)
            // «Venerdì prossimo» è ambiguo, due giorni nella richiesta pure, e un giorno diverso non si tocca.
            #expect(Assistant.weekCorrection(for: day(9), request: "Ricordamelo venerdì prossimo", now: monday) == 0)
            #expect(Assistant.weekCorrection(for: day(9), request: "Sposta da lunedì a venerdì", now: monday) == 0)
            #expect(Assistant.weekCorrection(for: day(3), request: "Ricordami di rispondergli venerdì", now: monday) == 0)
        }
        Language.$scoped.withValue(.en) {
            #expect(Assistant.weekCorrection(for: day(9), request: "Remind me to reply on Friday", now: monday) == -7)
            #expect(Assistant.weekCorrection(for: day(9), request: "Remind me next Friday", now: monday) == 0)
        }
    }

    @Test func mailSearchFindsSingularAndPlural() {
        #expect(MailReader.searchTerm("commercialista") == "commercialist")
        #expect(MailReader.searchTerm("fattura") == "fattur")
        #expect(MailReader.searchTerm("Paolo Verdi") == "Paolo Verdi")
        #expect(MailReader.searchTerm("banca") == "banca" && MailReader.searchTerm("Amazon") == "Amazon")
        #expect(Assistant.newsFromSomeone("ci sono novità dal commercialista?") == "commercialista")
        #expect(Language.$scoped.withValue(.en) { Assistant.newsFromSomeone("any news from my accountant?") } == "accountant")
        #expect(Assistant.newsFromSomeone("novità sul progetto?") == nil)
        #expect(Assistant.roleInOtherLanguage("accountant") == "commercialist" && Assistant.roleInOtherLanguage("commercialista") == "accountant")
        #expect(Assistant.roleInOtherLanguage("lawyers") == "avvocat" && Assistant.roleInOtherLanguage("Paolo Verdi") == nil)
        // «L'ultima email della banca» si legge, non si scrive.
        let assistant = assistant()
        var plan = Assistant.Plan(action: .scrivi_email, fields: ["destinatari": "banca"])
        Language.$scoped.withValue(.it) { assistant.applyRules(to: &plan, prompt: "Riassumi l'ultima email della banca") }
        #expect(plan.action == .mail_leggi)
    }

    @Test func picturesAreMadeByTheApp() {
        #expect(Assistant.imageRequest("Disegna un gatto che legge un libro") == "un gatto che legge un libro")
        #expect(Assistant.imageRequest("Crea un'immagine di un tramonto a Roma") == "un tramonto a roma")
        #expect(Assistant.imageRequest("Disegna una tabella con le spese") == nil && Assistant.imageRequest("Che tempo fa domani?") == nil)
        #expect(Language.$scoped.withValue(.en) { Assistant.imageRequest("Draw a cat reading a book") } == "a cat reading a book")
        // Con qualunque modello la decide l'app: Image Playground sul Mac (un modello cloud a volte dice che non può).
        let assistant = assistant()
        #expect(assistant.decidedByRules("Disegna un gatto che legge un libro"))
        var plan = Assistant.Plan(action: .rispondi, fields: [:])
        Language.$scoped.withValue(.it) { assistant.applyRules(to: &plan, prompt: "Disegna un gatto che legge un libro") }
        #expect(plan.action == .genera_immagine && plan["argomento"] == "un gatto che legge un libro")
    }

    @Test func eventQuestionsAboutWhatWasJustSaid() {
        // Un verbale appena incollato: «quando è la prossima riunione?» si risponde da lì, non dal calendario.
        let assistant = assistant()
        assistant.record(user: "Riassumi questo verbale: «Riunione del 12 settembre. Prossima riunione il 26 settembre alle 15.»", reply: "Riassunto del verbale.")
        var plan = Assistant.Plan(action: .eventi, fields: [:])
        Language.$scoped.withValue(.it) { assistant.applyRules(to: &plan, prompt: "E quando è la prossima riunione?") }
        #expect(plan.action == .rispondi)
        // Senza quel discorso l'evento si cerca per nome nel calendario.
        let fresh = self.assistant()
        var lookup = Assistant.Plan(action: .agenda, fields: [:])
        Language.$scoped.withValue(.it) { fresh.applyRules(to: &lookup, prompt: "Quando ho il dentista?") }
        #expect(lookup.action == .eventi && lookup["cerca"] == "dentista")
    }

    @Test func eventsFoundByName() {
        #expect(Assistant.eventLookup("Quando ho il dentista?") == "dentista")
        #expect(Assistant.eventLookup("When is my dentist appointment?") == "dentist")
        #expect(Assistant.eventLookup("Quando ho tempo libero?") == nil)
        #expect(Assistant.eventLookup("Che impegni ho domani?") == nil)
        #expect(Assistant.titleMatches("Dentista dott. Neri", "dentista"))
        #expect(Assistant.titleMatches("Riunione con Marco Bianchi", "riunione con Marco"))
        #expect(Assistant.titleMatches("Commercialista", "appuntamento con il commercialista"))
        #expect(!Assistant.titleMatches("Palestra", "dentista"))
    }
}
