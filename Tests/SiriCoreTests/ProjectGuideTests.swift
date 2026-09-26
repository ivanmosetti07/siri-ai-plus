import Foundation
import Testing
@testable import SiriCore

/// Le chat di un progetto usano la cartella come contesto: istruzioni, mappa dei file, registri del giorno, clienti.
@MainActor @Suite struct ProjectGuideTests {
    /// Il «second brain» di prova delle valutazioni (CLAUDE.md con la mappa, registro di oggi, un cliente, le persone).
    private func project() async throws -> (URL, ProjectGuide) {
        let root = try #require(Evaluation.testProject())
        let guide = ProjectGuide.shared(for: root)
        await guide.prepare()
        return (root, guide)
    }

    @Test func routesFromTheInstructions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "guida-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "3_Risorse/sistema"), withIntermediateDirectories: true)
        for name in ["STATE.md", "OBJECTIVES.md", "3_Risorse/sistema/people-index.md"] {
            try "# \(name)".write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }
        let text = """
        | obiettivo, KR, target di trimestre | [OBJECTIVES.md](OBJECTIVES.md) |
        | lavorare dentro un'area | `2_Aree/<area>/CLAUDE.md`, poi il suo `STATE.md` |
        **Se 2 righe matchano**: stato di oggi → `STATE.md` · chi è una persona → `3_Risorse/sistema/people-index.md`
        - [Web](https://esempio.it) non è un file del progetto
        """
        let routes = ProjectGuide.routes(in: text, root: root)
        #expect(routes.contains { $0.paths == ["OBJECTIVES.md"] && $0.stems.contains(Keywords.stem("trimestre")) })
        // Un nome senza cartella in una riga con segnaposto è di un'altra cartella: niente STATE.md della radice lì.
        #expect(!routes.contains { $0.trigger.contains("area") && $0.paths.contains("STATE.md") })
        // Coppie separate da «·»: ogni file con la sua descrizione.
        #expect(routes.contains { $0.paths == ["3_Risorse/sistema/people-index.md"] && $0.stems.contains(Keywords.stem("persona")) })
        #expect(!routes.contains { $0.paths.contains { $0.contains("esempio") } })
    }

    @Test func picksTheFilesTheInstructionsPointTo() async throws {
        let (_, guide) = try await project()
        let today = Date.now.localDay
        #expect(guide.relevant(to: "quali sono i miei obiettivi di questo trimestre?").first?.path == "OBJECTIVES.md")
        #expect(guide.relevant(to: "cosa ho fatto oggi?").first?.path == "3_Risorse/log/\(today.prefix(7))/\(today).md")
        let client = guide.relevant(to: "come va il cliente Rossi Moto?").map(\.path)
        #expect(client.contains("2_Aree/agenzia/1_Progetti/_clienti/rossi-moto/INDEX.md"))
        #expect(client.contains("2_Aree/agenzia/1_Progetti/_clienti/rossi-moto/STATE.md"))
        #expect(guide.relevant(to: "chi è Martina Verdi?").first?.path == "3_Risorse/persone.md")
        #expect(guide.relevant(to: "riassumi TASKS.md").first?.reason == "nominato")
        #expect(guide.relevant(to: "dove salvo un appunto grezzo da smistare?").first?.path == "_Inbox/CLAUDE.md")
        // Una domanda che non riguarda il progetto non apre niente.
        #expect(guide.relevant(to: "che tempo fa domani a Roma?").isEmpty)
        #expect(guide.relevant(to: "scrivi una poesia sul mutuo della casa").isEmpty)
        #expect(guide.namesSomething(in: "riassumi TASKS.md") && !guide.namesSomething(in: "riassumi questa nota"))
    }

    @Test func instructionsAreCompleteAndFolderRulesFollowThePath() async throws {
        let (root, guide) = try await project()
        let all = guide.instructions(limit: 20_000)
        #expect(all.contains("--- CLAUDE.md ---") && all.contains("--- AGENTS.md ---") && all.contains("_Inbox/"))
        let rules = guide.folderInstructions(for: "2_Aree/agenzia/1_Progetti/_clienti/rossi-moto/STATE.md")
        #expect(rules.map(\.folder) == ["2_Aree/agenzia"] && rules.first?.text.contains("report-") == true)
        #expect(guide.folderInstructions(for: "STATE.md").isEmpty)
        // I percorsi dell'albero sono relativi anche quando la cartella sta dietro un collegamento (/var → /private/var).
        let tree = await guide.currentTree()
        #expect(tree.files.contains("STATE.md") && !tree.files.contains { $0.hasPrefix("/") || $0.hasPrefix("to ") })
        _ = root
    }

    @Test func tasksAreSpelledOutForTheModel() {
        let text = Assistant.spelledTasks("# Task\n- [ ] Chiamare il commercialista\n  * [x] Aggiornare il sito\n- [link](x.md) resta\n")
        #expect(text == "# Task\n- (da fare) Chiamare il commercialista\n  * (fatto) Aggiornare il sito\n- [link](x.md) resta\n")
    }

    /// I registri del giorno hanno la data locale: a mezzanotte e mezza del 24 è già il 24 (in UTC sarebbe ancora il 23).
    @Test func todayIsTheLocalDay() throws {
        let late = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 0, minute: 30)))
        #expect(late.localDay == "2026-09-24")
    }

    @Test func ignoredFilesStayOutOfTheTree() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ignora-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "privato"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "note"), withIntermediateDirectories: true)
        try "segreto".write(to: root.appending(path: "privato/dati.md"), atomically: true, encoding: .utf8)
        try "video".write(to: root.appending(path: "note/clip.mp4"), atomically: true, encoding: .utf8)
        try "ciao".write(to: root.appending(path: "note/idea.md"), atomically: true, encoding: .utf8)
        try "# dieta contesto\nprivato/\n*.mp4\n".write(to: root.appending(path: ".claudeignore"), atomically: true, encoding: .utf8)
        let guide = ProjectGuide.shared(for: root)
        let tree = await guide.currentTree()
        #expect(tree.files == ["note/idea.md"] || tree.files.sorted() == ["note/idea.md"])
        #expect(!tree.folders.contains("privato"))
    }

    @Test func longFilesKeepTheirOutline() throws {
        var text = "# Obiettivi\n\nIntroduzione lunga.\n" + String(repeating: "Riga di contesto senza parole chiave.\n", count: 80)
        for index in 1...6 { text += "\n## Obiettivo \(index)\nKR del punto \(index).\n" + String(repeating: "dettaglio\n", count: 40) }
        let root = FileManager.default.temporaryDirectory.appending(path: "schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appending(path: "OBJECTIVES.md"), atomically: true, encoding: .utf8)
        let excerpt = try #require(ProjectGuide.shared(for: root).excerpt(of: "OBJECTIVES.md", for: "obiettivi", limit: 1500))
        #expect(excerpt.count < 1900)
        #expect(excerpt.contains("## Obiettivo 6") && excerpt.contains("KR del punto 6"))
    }

    @Test func theProjectIsInTheContextEvenWithAnAppOpen() async throws {
        let (root, _) = try await project()
        let assistant = Assistant()
        var work = WorkContext()
        work.projectName = "Progetto test"
        work.projectRoot = root
        work.screen = ScreenItem(app: "Note", kind: .note, title: "Spesa", text: "latte, uova", reference: "x-coredata://nota/1")
        assistant.work = work
        assistant.updateScreen()
        await assistant.prepareProject()
        // «Riassumi TASKS.md» con una nota appena aperta parla del file, non della nota.
        assistant.prepareScreen(for: "riassumi TASKS.md")
        #expect(!assistant.screenPointed)
        assistant.prepareScreen(for: "riassumi questa nota")
        #expect(assistant.screenPointed)
        // La domanda sugli obiettivi riceve il file indicato dalle istruzioni, e non è più «a memoria».
        let request = assistant.withContext("quali sono gli obiettivi del trimestre?")
        #expect(request.contains("OBJECTIVES.md") && request.contains("12.000"))
        #expect(assistant.chatInstructions().contains("la sua cartella è il contesto principale"))
    }

    @Test func questionsAreNotCommands() async throws {
        let (root, _) = try await project()
        let assistant = Assistant()
        var work = WorkContext()
        work.projectName = "Progetto test"
        work.projectRoot = root
        assistant.work = work
        await assistant.prepareProject()
        var plan = Assistant.Plan(action: .crea_nota, fields: ["titolo": "Appunti"])
        assistant.applyRules(to: &plan, prompt: "dove devo salvare un appunto grezzo nuovo?")
        #expect(plan.action == .rispondi)
        plan = Assistant.Plan(action: .completa_promemoria, fields: ["titolo": "SOCIAL HUB"])
        assistant.applyRules(to: &plan, prompt: "cosa ho fatto oggi?")
        #expect(plan.action != .completa_promemoria)
        plan = Assistant.Plan(action: .file_scrivi, fields: ["percorso": "_Inbox/CLAUDE.md"])
        assistant.applyRules(to: &plan, prompt: "Scrivi una poesia sul mutuo della casa")
        #expect(plan.action == .rispondi)
        plan = Assistant.Plan(action: .file_scrivi, fields: ["percorso": "TASKS.md"])
        assistant.applyRules(to: &plan, prompt: "aggiungi a TASKS.md il task: chiamare il commercialista")
        #expect(plan.action == .file_scrivi)
    }
}
