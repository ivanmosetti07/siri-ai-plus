import Foundation
import Testing
@testable import SiriCore

/// La Programmazione in inglese: stesse regole, con istruzioni, strumenti e messaggi in inglese
/// (i nomi degli strumenti e dei parametri restano quelli italiani). In italiano tutto resta com'era, parola per parola.
@Suite struct EnglishCodeAgentTests {
    private func folder(_ name: String = "bakery") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "siriai-en-\(UUID().uuidString)").appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Parole italiane che nei testi inglesi non devono comparire (i nomi degli strumenti, come leggi_file, non contano).
    private let italianWords = ["Rispondi", "rispondi", "italiano", "Modalità", "progetto", "Sei ", "Usa ", "Leggi ", "Lavora ",
                                "Non ", "strumenti", "Regole", "Come lavorare", "Progetto", "chiedi prima"]

    // MARK: Inglese

    @Test func englishRequestsAskForChanges() {
        Language.$scoped.withValue(.en) {
            for prompt in ["Create a landing page for my bakery", "please add a contact form", "Fix the header on mobile",
                           "rename script.js to main.js", "Make the buttons bigger", "update the README", "set up Tailwind"] {
                #expect(LocalCodeAgent.asksForChanges(prompt), "\(prompt)")
            }
            for prompt in ["How does the routing work?", "Explain this project to me", "What changed in the last version?"] {
                #expect(!LocalCodeAgent.asksForChanges(prompt), "\(prompt)")
            }
        }
        // In italiano contano solo i verbi italiani, come prima.
        Language.$scoped.withValue(.it) {
            #expect(!LocalCodeAgent.asksForChanges("please add a contact form"))
            #expect(LocalCodeAgent.asksForChanges("aggiungi un modulo di contatto"))
            #expect(!LocalCodeAgent.asksForChanges("spiegami il progetto"))
        }
    }

    /// «It doesn't work», «blank page»…: gli errori dell'anteprima vanno all'agente anche quando si scrive in inglese.
    @Test func englishProblemReports() {
        Language.$scoped.withValue(.en) {
            for prompt in ["it doesn't work, fix it", "The game won’t start", "the page isn't loading", "there's an error in the console",
                           "I only see a blank page", "the app crashes on launch", "the menu is broken", "it freezes after a second",
                           "nothing happens when I click the button", "the build fails"] {
                #expect(CodeAgent.mentionsProblem(prompt), "\(prompt)")
            }
            for prompt in ["add a contact page", "make the site more elegant", "How does the routing work?"] {
                #expect(!CodeAgent.mentionsProblem(prompt), "\(prompt)")
            }
        }
        Language.$scoped.withValue(.it) {
            #expect(!CodeAgent.mentionsProblem("it doesn't work"))
            #expect(!CodeAgent.mentionsProblem("I only see a blank page"))
            #expect(CodeAgent.mentionsProblem("non funziona, sistema"))
            #expect(CodeAgent.mentionsProblem("vedo una pagina bianca"))
        }
    }

    @Test func englishInstructionsAreInEnglish() throws {
        let folder = try folder()
        try Language.$scoped.withValue(.en) {
            try CodeTemplate.sito.agentsFile(name: "Bakery").write(to: folder.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        }
        let texts = Language.$scoped.withValue(.en) {
            [LocalCodeAgent.instructions(folder: folder, mode: .edit, compact: false, checksPages: true),
             LocalCodeAgent.instructions(folder: folder, mode: .plan, compact: true),
             CodeAgent.planPreamble, LocalCodeAgent.nudge, LocalCodeAgent.nudgeNotice]
        }
        for text in texts {
            for word in italianWords { #expect(!text.contains(word), "«\(word)» in: \(text)") }
        }
        #expect(texts[0].hasPrefix("You are the Siri AI+ coding agent and you work in the project “bakery”."))
        #expect(texts[0].contains("reply in English") && texts[0].contains("modifica_file") && texts[0].contains("controlla_pagina"))
        #expect(texts[0].contains("\n\nProject rules (AGENTS.md):\n# Bakery\n\n## How to work\n- Reply and write comments in English"))
        #expect(texts[1].contains("“Ask first” mode") && !texts[1].contains("To change an existing file"))
        #expect(texts[2].hasSuffix("Answer in English.\n\n"))
    }

    @Test func englishAgentsFiles() {
        for template in CodeTemplate.allCases {
            let text = Language.$scoped.withValue(.en) { template.agentsFile(name: "Bakery") }
            #expect(text.hasPrefix("# Bakery\n\n## How to work\n- Reply and write comments in English; code and file names in English too.\n"))
            #expect(text.contains("- At the end, summarize what you changed and how to try it."))
            #expect(template == .vuoto || text.contains("\n\n## Project\n"))
            for word in italianWords { #expect(!text.contains(word), "«\(word)» in \(template): \(text)") }
            let (label, summary, first) = Language.$scoped.withValue(.en) { (template.label, template.summary, template.bootstrap("")) }
            for word in italianWords + ["Crea ", "Usa ", "sito"] {
                #expect(!label.contains(word) && !summary.contains(word) && !first.contains(word), "«\(word)» in \(template)")
            }
        }
        #expect(Language.$scoped.withValue(.en) { CodeTemplate.sito.bootstrap("a site for my bakery") }
                == "Create the website: a site for my bakery. Use index.html, style.css and script.js.")
    }

    @Test func englishToolsKeepTheirNames() async throws {
        let folder = try folder()
        try "<h1>Hello</h1>\n".write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let events = EventLog()
        let toolbox = Language.$scoped.withValue(.en) { CodeToolbox(folder: folder, mode: .edit, compact: false) { events.add($0) } }
        let specs = Language.$scoped.withValue(.en) { toolbox.specs }
        #expect(specs.map(\.name) == ["elenca_file", "leggi_file", "cerca", "modifica_file", "scrivi_file", "esegui_comando"])
        #expect(specs[0].description == "Lists the project files (without dependencies and build folders).")
        let fields = CodeToolbox.fields(of: specs[3])
        #expect(fields.map(\.name) == ["nuovo_testo", "percorso", "vecchio_testo"])
        #expect(fields.last?.description == "Text to replace, copied exactly from the file (unique in the file)")
        // Chiamati fuori dall'ambito della richiesta (come può fare Apple Intelligence), gli strumenti restano in inglese.
        #expect(await toolbox.run("leggi_file", ["percorso": "missing.txt"]) == "Error: the file “missing.txt” doesn't exist. Use elenca_file to see the files.")
        #expect(await toolbox.run("modifica_file", ["percorso": "index.html", "vecchio_testo": "Hello", "nuovo_testo": "Hi"]) == "Done: index.html edited.")
        #expect(await toolbox.run("scrivi_file", ["percorso": "style.css", "contenuto": "body {}\n"]) == "Done: style.css created (2 lines).")
        #expect(await toolbox.run("cerca", ["testo": "nowhere"]) == "No results for “nowhere”.")
        #expect(await toolbox.run("sconosciuto", [:]).hasPrefix("Error: the tool “sconosciuto” doesn't exist. Tools: elenca_file, "))
        #expect(events.all.map(\.text) == ["Edit", "Create", "Search “nowhere”"])
        #expect(toolbox.journal(limit: 500) == "- edited index.html\n- created style.css\n- searched “nowhere” (0 results)")
        let plan = Language.$scoped.withValue(.en) { CodeToolbox(folder: folder, mode: .plan, compact: true) { _ in } }
        #expect(await plan.run("scrivi_file", ["percorso": "x.txt", "contenuto": "x"]) == "Error: in “ask first” mode nothing gets changed. Propose the plan.")
    }

    /// Le righe di Codex e Claude Code arrivano dalla shell, fuori dall'ambito: vale la lingua con cui è partita la richiesta.
    @Test func englishStreamEvents() {
        let parser = Language.$scoped.withValue(.en) { CodeStreamParser(engine: .claude) }
        _ = parser.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/tmp/site/index.html"}}]}}"#)
        let written = parser.parse(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"File created successfully at: /tmp/site/index.html"}]}}"#)
        #expect(written.first?.text == "Create")
        let read = parser.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/tmp/site/style.css"}}]}}"#)
        #expect(read.first?.text == "Read style.css")
        let result = parser.parse(#"{"type":"result","subtype":"success","is_error":false,"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"curl https://example.com"}}]}"#)
        #expect(result.first?.text == "Not allowed without your permission: curl https://example.com")
        // La fine del lavoro è un segnale che la chat nasconde: resta uguale in ogni lingua.
        #expect(result.last?.kind == .result && result.last?.text == "Fatto")
        let codex = Language.$scoped.withValue(.en) { CodeStreamParser() }
        let files = codex.parse(#"{"type":"item.completed","item":{"id":"i1","type":"file_change","changes":[{"path":"a.js","kind":"update"},{"path":"b.js","kind":"add"},{"path":"c.js","kind":"delete"}],"status":"completed"}}"#)
        #expect(files.map(\.text) == ["Edit", "Create", "Delete"])
    }

    /// Senza una lingua scelta da chi la avvia, la richiesta di programmazione usa quella in cui è scritta.
    @Test func codingRequestsFollowTheirLanguage() async throws {
        let folder = try folder()
        let prompt = "Please create a landing page for my bakery with a contact form"
        let english = await CodeAgent.run(selection: ModelSelection(.apple), mode: .edit, folder: folder, prompt: prompt, resume: nil) { _ in }
        #expect(english.error == "Apple Intelligence isn't ready.")
        let chosen = await Language.$scoped.withValue(.it) {
            await CodeAgent.run(selection: ModelSelection(.apple), mode: .edit, folder: folder, prompt: prompt, resume: nil) { _ in }
        }
        #expect(chosen.error == "Apple Intelligence non è pronto.")
    }

    // MARK: Italiano, come prima

    @Test func italianTextsAreUnchanged() throws {
        let folder = try folder("forno")
        Language.$scoped.withValue(.it) {
            #expect(CodeAgent.planPreamble == "Modalità «chiedi prima»: non modificare nessun file e non eseguire comandi che cambiano qualcosa. Studia il progetto e proponi un piano chiaro, a punti, di cosa faresti e quali file toccheresti. Rispondi in italiano.\n\n")
            #expect(LocalCodeAgent.nudge == "Non hai ancora creato né modificato nessun file: descrivere il lavoro non basta. Fallo adesso con gli strumenti, un file alla volta (scrivi_file per i file nuovi, modifica_file per quelli esistenti), poi rispondi con il riepilogo.")
            let lines = LocalCodeAgent.instructions(folder: folder, mode: .edit, compact: false, checksPages: true).components(separatedBy: "\n")
            #expect(lines.first?.hasPrefix("Sei l'agente di programmazione di Siri AI+ e lavori nel progetto «forno». Adesso è ") == true)
            #expect(lines.dropFirst().joined(separator: "\n") == """
            Usa gli strumenti per capire il codice: elenca_file, leggi_file e cerca. I percorsi sono relativi alla cartella del progetto.
            Per cambiare un file esistente usa modifica_file (sostituisce un pezzo di testo esatto, copiato da leggi_file); per i file nuovi, o da riscrivere del tutto, usa scrivi_file. Con esegui_comando lanci build, test e comandi del progetto (scrivono solo nella cartella del progetto e non hanno internet).
            Leggi un file prima di modificarlo, fai modifiche piccole e precise, e se c'è un comando di verifica eseguilo dopo le modifiche.
            I file si creano e si cambiano solo chiamando gli strumenti: scrivere il codice nella risposta non cambia nulla.
            Lavora da solo fino alla fine: non chiedere il permesso di leggere o cambiare i file del progetto, fallo. Se ti dicono che qualcosa non funziona, leggi i file coinvolti, trova la causa, correggila e verifica.
            Per i siti: dopo le modifiche apri la pagina con controlla_pagina (di solito index.html) e correggi gli errori che trova, finché non ce ne sono più.
            Non inventare file, codice o risultati che gli strumenti non hanno restituito. Alla fine rispondi in italiano con un breve riepilogo di cosa hai fatto.
            """)
            #expect(LocalCodeAgent.instructions(folder: folder, mode: .plan, compact: true).hasSuffix("""

            Modalità «chiedi prima»: non modificare nulla. Studia il progetto e proponi un piano chiaro, a punti, con i file da toccare.
            Non inventare file, codice o risultati che gli strumenti non hanno restituito. Alla fine rispondi in italiano con un breve riepilogo di cosa hai fatto.
            """))
            #expect(CodeMode.plan.label == "Chiedi prima" && CodeMode.edit.label == "Modifica")
            #expect(CodeAgent.Engine.local.label == "Assistente di Siri AI+")
            #expect(CodeIsolation.project.label == "Cartella originale" && CodeIsolation.worktree.label == "Copia isolata")
            #expect(CodeTemplate.sito.label == "Sito web" && CodeTemplate.vuoto.label == "Progetto vuoto")
            #expect(CodeTemplate.webapp.summary == "Applicazione interattiva con React, TypeScript e Vite, avviata con npm run dev.")
            #expect(CodeTemplate.sito.bootstrap("") == "Crea il sito: una pagina di presentazione elegante. Usa index.html, style.css e script.js.")
            #expect(CodeTemplate.sito.agentsFile(name: "Forno") == """
            # Forno

            ## Come lavorare
            - Rispondi e commenta in italiano; il codice e i nomi dei file in inglese.
            - Fai modifiche piccole e verificabili; dopo ogni modifica importante controlla che il progetto si avvii.
            - Non cancellare file senza chiederlo. Non aggiungere dipendenze inutili.
            - Alla fine riassumi cosa hai cambiato e come provarlo.

            ## Progetto
            Sito statico: `index.html`, `style.css`, `script.js` (niente framework). Responsive, accessibile (contrasto, testo alternativo), tema chiaro e scuro con `prefers-color-scheme`, immagini leggere. Si prova aprendo `index.html`.
            """)
        }
    }

    @Test func italianToolsAndEventsAreUnchanged() async throws {
        let folder = try folder("forno")
        try "<h1>Ciao</h1>\n".write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let events = EventLog()
        let toolbox = Language.$scoped.withValue(.it) { CodeToolbox(folder: folder, mode: .edit, compact: false) { events.add($0) } }
        #expect(Language.$scoped.withValue(.it) { toolbox.specs[0].description } == "Elenca i file del progetto (senza dipendenze e cartelle di build).")
        #expect(await toolbox.run("leggi_file", ["percorso": "manca.txt"]) == "Errore: il file «manca.txt» non esiste. Usa elenca_file per vedere i file.")
        #expect(await toolbox.run("modifica_file", ["percorso": "index.html", "vecchio_testo": "Ciao", "nuovo_testo": "Salve"]) == "Fatto: index.html modificato.")
        #expect(await toolbox.run("scrivi_file", ["percorso": "style.css", "contenuto": "body {}\n"]) == "Fatto: style.css creato (2 righe).")
        #expect(await toolbox.run("cerca", ["testo": "introvabile"]) == "Nessun risultato per «introvabile».")
        #expect(events.all.map(\.text) == ["Modifica", "Crea", "Cerca «introvabile»"])
        #expect(toolbox.journal(limit: 500) == "- modificato index.html\n- creato style.css\n- cercato «introvabile» (0 risultati)")
        let parser = Language.$scoped.withValue(.it) { CodeStreamParser() }
        let files = parser.parse(#"{"type":"item.completed","item":{"id":"i1","type":"file_change","changes":[{"path":"a.js","kind":"update"},{"path":"b.js","kind":"add"},{"path":"c.js","kind":"delete"}],"status":"completed"}}"#)
        #expect(files.map(\.text) == ["Modifica", "Crea", "Elimina"])
    }
}
