import Foundation
import Testing
@testable import SiriCore

/// Il sub-agent smistatore: catalogo corto, scelta degli strumenti per i modelli esterni, saluti senza strumenti.
@Suite struct ToolRoutingTests {
    private func spec(_ name: String, _ description: String = "descrizione") -> ToolSpec {
        ToolSpec(name: name, description: description, parameters: .object([:]), kind: .read)
    }

    @Test func smallTalkNeedsNoTools() {
        for text in ["ciao", "Ciao, come stai?", "grazie!", "ok", "Perfetto.", "buongiorno", "chi sei?"] {
            #expect(Assistant.isSmallTalk(text), "\(text)")
        }
        for text in ["cosa ho domani?", "no, intendevo domani", "come va il progetto drone24hours?", "ciao, mi prepari l'agenda di domani con le riunioni?"] {
            #expect(!Assistant.isSmallTalk(text), "\(text)")
        }
    }

    /// I connettori entrano nel catalogo uno per servizio (con i nomi dei loro strumenti): il catalogo resta corto.
    @Test func catalogGroupsConnectors() {
        let tools = [spec("agenda", "Legge eventi e promemoria"), spec("cerca_web", "Cerca sul web"),
                     spec("mcp__Agency_OS__list_clients"), spec("mcp__Agency_OS__get_project"), spec("mcp__Notion__search")]
        let catalog = ToolRegistry.catalog(tools)
        #expect(catalog.map(\.name) == ["agenda", "cerca_web", "connettore_Agency_OS", "connettore_Notion"])
        #expect(catalog[2].summary.contains("list_clients") && catalog[2].summary.contains("get_project"))
    }

    /// Al modello esterno arrivano solo gli strumenti scelti (e quelli che le parole nominano); un connettore scelto porta
    /// tutti i suoi strumenti. Se lo smistatore non ha risposto restano tutti.
    @Test func selectingKeepsOnlyChosenTools() {
        let tools = [spec("agenda"), spec("cerca_web"), spec("scrivi_email"), spec("mcp__Agency_OS__list_clients"), spec("mcp__Agency_OS__get_project"),
                     spec("mcp__Notion__search")]
        let route = ToolRoute(tools: ["cerca_web", "connettore_Agency_OS"], decided: true)
        #expect(ToolRegistry.selecting(tools, route: route).map(\.name) == ["cerca_web", "mcp__Agency_OS__list_clients", "mcp__Agency_OS__get_project"])
        #expect(ToolRegistry.selecting(tools, route: route, hints: ["agenda"]).map(\.name).first == "agenda")
        #expect(ToolRegistry.selecting(tools, route: ToolRoute(decided: true)).isEmpty)
        #expect(ToolRegistry.selecting(tools, route: ToolRoute()).count == tools.count)
    }

    /// Lo smistatore sceglie fra famiglie (facile anche per il modello piccolo); le azioni precise le sceglie il pianificatore.
    @MainActor @Test func familiesCoverTheAvailableActions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "smistatore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let assistant = Assistant()
        var work = WorkContext()
        work.projectRoot = root
        work.projectName = "Prova"
        work.webEnabled = true
        assistant.work = work
        let names = assistant.familyCatalog().map(\.name)
        #expect(["calendario", "email", "messaggi", "file", "web", "promemoria"].allSatisfy(names.contains))
        #expect(!names.contains("connettori"))
        let actions = assistant.actions(inFamilies: ["file", "email"])
        #expect(actions.contains(.file_leggi) && actions.contains(.mail_leggi) && !actions.contains(.file))
        #expect(Assistant.tools(inFamilies: ["email", "connettore_Agency_OS"]) == ["leggi_email", "scrivi_email", "rispondi_email", "inoltra_email", "connettore_Agency_OS"])
        // Per un modello esterno: solo le famiglie che hanno i suoi strumenti, e i connettori uno per servizio.
        let tools = [spec("agenda"), spec("cerca_web"), spec("mcp__Agency_OS__list_clients")]
        #expect(assistant.familyCatalog(tools: tools).map(\.name) == ["calendario", "promemoria", "web", "connettore_Agency_OS"])
    }

    /// Il pianificatore piccolo ripiega su «rispondi» quando la richiesta non nomina l'app: l'area trovata dallo smistatore
    /// dà l'azione ovvia (leggere o preparare), ma non per consigli, testi creativi o con un documento aperto.
    @MainActor @Test func areasRescueTheObviousAction() {
        let assistant = Assistant()
        #expect(assistant.rescueAction(areas: ["email", "web"], prompt: "Mi è arrivato qualcosa da Amazon?") == .mail_leggi)
        #expect(assistant.rescueAction(areas: ["email"], prompt: "Chi mi ha mandato il preventivo della cucina?") == .mail_leggi)
        #expect(assistant.rescueAction(areas: ["messaggi", "email"], prompt: "Fammi vedere cosa mi ha mandato Giulia ieri sera") == .messaggi)
        #expect(assistant.rescueAction(areas: ["email"], prompt: "Prepara una bozza gentile per il cliente arrabbiato") == .scrivi_email)
        #expect(assistant.rescueAction(areas: ["file", "email"], prompt: "Dove avevo messo il contratto dell'affitto?") == .file)
        #expect(assistant.rescueAction(areas: ["promemoria"], prompt: "Fra tre giorni devo pagare la bolletta, non farmelo scordare", withCalculations: true) == .crea_promemoria)
        // Con date o conti nella richiesta si prepara, non si legge.
        #expect(assistant.rescueAction(areas: ["email"], prompt: "Quanto costava il volo del 12 ottobre?", withCalculations: true) == nil)
        #expect(assistant.rescueAction(areas: ["note", "web"], prompt: "Scrivimi una poesia breve sull'autunno") == nil)
        #expect(assistant.rescueAction(areas: ["calendario", "promemoria"], prompt: "Come posso organizzarmi meglio al lavoro quando ho troppe riunioni?") == nil)
        #expect(assistant.rescueAction(areas: ["calendario"], prompt: "Posso andare in palestra lunedì, mercoledì o venerdì. Lunedì ho una cena di lavoro e venerdì è previsto un temporale, ma voglio andarci in bici. Quale giorno mi conviene?") == nil)
        // Un racconto non diventa un promemoria; una risposta già nella conversazione non si cerca nelle app.
        #expect(assistant.rescueAction(areas: ["promemoria", "calendario"], prompt: "Sto organizzando una cena per 8 persone sabato sera.") == nil)
        assistant.restore([ChatTurn(role: .user, text: "Il mio medico si chiama dottor Esposito e riceve il martedì."),
                           ChatTurn(role: .assistant, text: "Bene, me lo ricordo.")])
        #expect(assistant.rescueAction(areas: ["calendario"], prompt: "Che giorno riceve il mio medico?") == nil)
        var work = WorkContext()
        work.artifactKind = "foglio"
        assistant.work = work
        #expect(assistant.rescueAction(areas: ["file"], prompt: "qual è il totale di novembre?") == nil)
    }

    /// Con il modello sul Mac: le richieste che non nominano l'app finiscono nell'area giusta.
    @MainActor @Test(.enabled(if: Agent.availabilityProblem == nil)) func routesParaphrasedRequests() async {
        let assistant = Assistant()
        let calendar = await assistant.routeTools(for: "Che impegni ho domani pomeriggio?", catalog: assistant.familyCatalog(),
                                                  hints: assistant.familyHints(for: "Che impegni ho domani pomeriggio?"))
        #expect(calendar.decided && calendar.tools.contains("calendario"))
        let parcel = await assistant.routeTools(for: "Mi è arrivato qualcosa da Amazon?", catalog: assistant.familyCatalog())
        #expect(parcel.tools.contains("email"))
    }
}

/// La compattazione fatta dal sub-agent: scambi lunghi letti a pezzi in parallelo, poi uniti nel riassunto.
@Suite struct CompactionSubAgentTests {
    @MainActor @Test(.enabled(if: Agent.availabilityProblem == nil)) func longExchangesAreReadInPieces() async {
        let assistant = Assistant()
        let filler = String(repeating: "Il fornitore ha confermato la consegna e il magazzino ha aggiornato le scorte senza problemi. ", count: 20)
        assistant.restore([
            ChatTurn(role: .user, text: "Riassumimi la situazione del preventivo per Arredi Bassi: budget 12.000 euro, consegna il 15 ottobre."),
            ChatTurn(role: .assistant, text: "Il preventivo per Arredi Bassi vale 12.000 euro, consegna il 15 ottobre. " + filler),
            ChatTurn(role: .user, text: "Ho deciso: la riunione con Giulia è spostata a giovedì alle 10."),
            ChatTurn(role: .assistant, text: "Va bene: riunione con Giulia giovedì alle 10. " + filler),
            ChatTurn(role: .user, text: "Preferisco ricevere i report il lunedì mattina."),
            ChatTurn(role: .assistant, text: "D'accordo, i report arriveranno il lunedì mattina. " + filler),
            ChatTurn(role: .user, text: "E il sito?"),
            ChatTurn(role: .assistant, text: "Il sito esce a novembre."),
        ])
        let result = await assistant.compactIfNeeded(threshold: 0)
        #expect(result?.exchanges == 3)
        #expect((result?.pieces ?? 0) >= 2)
        let summary = assistant.summary ?? ""
        #expect(summary.contains("12.000") || summary.contains("12000"))
        #expect(assistant.historyTurns.count == 2)
    }
}
