import Foundation
import Testing
@testable import SiriCore

@Suite struct FormulaTests {
    let cells = ["A1": "10", "A2": "20", "A3": "=A1+A2", "B1": "=SOMMA(A1:A3)", "B2": "=MEDIA(A1:A2)",
                 "B3": "=SE(A1>5;\"alto\";\"basso\")", "C1": "=C2", "C2": "=C1", "C3": "=A1/0", "D1": "1.234,5", "D2": "12%"]

    @Test func arithmeticAndReferences() {
        #expect(FormulaEngine.value(of: CellRef("A3")!, in: cells) == .number(30))
        #expect(FormulaEngine.evaluate("=2+3*4", in: [:]) == .number(14))
        #expect(FormulaEngine.evaluate("=(2+3)*4", in: [:]) == .number(20))
        #expect(FormulaEngine.evaluate("=2^3", in: [:]) == .number(8))
    }

    @Test func functions() {
        #expect(FormulaEngine.value(of: CellRef("B1")!, in: cells) == .number(60))
        #expect(FormulaEngine.value(of: CellRef("B2")!, in: cells) == .number(15))
        #expect(FormulaEngine.value(of: CellRef("B3")!, in: cells) == .text("alto"))
        #expect(FormulaEngine.evaluate("=MAX(A1:A3)", in: cells) == .number(30))
        #expect(FormulaEngine.evaluate("=sum(A1:A2)", in: cells) == .number(30))
        #expect(FormulaEngine.evaluate("=ARROTONDA(2,345;2)", in: [:]) != .error("#NOME?"))
    }

    @Test func errorsAndLiterals() {
        #expect(FormulaEngine.value(of: CellRef("C1")!, in: cells) == .error("#CICLO"))
        #expect(FormulaEngine.value(of: CellRef("C3")!, in: cells) == .error("#DIV/0"))
        #expect(FormulaEngine.value(of: CellRef("D1")!, in: cells) == .number(1234.5))
        #expect(FormulaEngine.value(of: CellRef("D2")!, in: cells) == .number(0.12))
        #expect(FormulaEngine.evaluate("=FOO(1)", in: [:]) == .error("#NOME?"))
    }

    @Test func cellNames() {
        #expect(CellRef("AA10")?.col == 26)
        #expect(CellRef(col: 27, row: 0).name == "AB1")
        #expect(CellRef("1A") == nil)
    }

    @Test func spreadsheetFromDraft() {
        let draft = SheetDraft(title: "Budget", columns: ["Q1", "Q2"], rows: [.init(label: "Marketing", values: [10, 20]), .init(label: "Eventi", values: [5, 5])])
        let sheet = Spreadsheet(from: draft).sheets[0]
        #expect(sheet.value(CellRef("D2")!) == .number(30))
        #expect(sheet.value(CellRef("D4")!) == .number(40))
        let series = sheet.series(for: "A1:C3")
        #expect(series.labels == ["Marketing", "Eventi"])
        #expect(series.series.map(\.name) == ["Q1", "Q2"])
    }
}

@Suite struct MCPTests {
    @Test func parseClaudeDesktopConfig() throws {
        let json = #"{"mcpServers":{"fs":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"],"env":{"A":"1"}},"remoto":{"url":"https://example.com/mcp"}}}"#
        let servers = try MCPServerConfig.parseClaudeDesktop(json)
        #expect(servers.count == 2)
        #expect(servers[0].name == "fs" && servers[0].transport == .stdio && servers[0].args.count == 3 && servers[0].env["A"] == "1")
        #expect(servers[1].transport == .http && servers[1].url == "https://example.com/mcp")
    }

    @Test func sseParsing() {
        let data = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n\n".utf8)
        let messages = MCPConnection.parseSSE(data)
        #expect(messages.first?["id"]?.number == 1)
    }

    @Test func schemaBridge() throws {
        let tool = MCPToolInfo(serverID: UUID(), serverName: "x", name: "read_file", description: "Legge",
                               inputSchema: try JSONValue.parse(Data(#"{"type":"object","properties":{"path":{"type":"string"},"lines":{"type":"integer"},"mode":{"enum":["a","b"]}},"required":["path"]}"#.utf8)))
        _ = try JSONSchemaBridge.generationSchema(for: tool)
    }

    @Test func stdioRoundTrip() async throws {
        // Server MCP minimo in shell: risponde a initialize, tools/list e tools/call.
        let script = """
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"initialize"'*) echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"serverInfo\\":{\\"name\\":\\"prova\\"}}}";;
            *'"tools/list"'*) echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"tools\\":[{\\"name\\":\\"eco\\",\\"description\\":\\"Ripete\\",\\"inputSchema\\":{\\"type\\":\\"object\\"}}]}}";;
            *'"tools/call"'*) echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"content\\":[{\\"type\\":\\"text\\",\\"text\\":\\"ciao\\"}]}}";;
          esac
        done
        """
        let url = FileManager.default.temporaryDirectory.appending(path: "mcp-test-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        var config = MCPServerConfig(name: "prova", transport: .stdio)
        config.command = "/bin/sh"
        config.args = [url.path]
        let connection = MCPConnection(config: config)
        try await connection.start()
        #expect(await connection.tools.map(\.name) == ["eco"])
        #expect(try await connection.call("eco", arguments: .object([:])) == "ciao")
        await connection.stop()
    }
}

@Suite struct ProjectTests {
    @Test func confinementAndMemory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "progetto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Regole".write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        let files = ProjectFiles(root: root)
        #expect(throws: ProjectFiles.FileError.self) { try files.resolve("../fuori.txt") }
        try files.write("docs/nota.md", content: "Ciao mondo")
        #expect(try files.read("docs/nota.md") == "Ciao mondo")
        #expect(files.search("mondo").first?.path == "docs/nota.md")
        #expect(files.agentsURL != nil)
        #expect(try files.remember("Il cliente preferisce il blu"))
        #expect(try !files.remember("il cliente preferisce il blu"))
        #expect(files.memoryFacts().count == 1)
        #expect(!files.list().contains { $0.path.hasPrefix(".siriai") })
    }
}

@Suite @MainActor struct MemoryTests {
    @Test func dedupeAndRelevance() {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "mem-\(UUID().uuidString).json"))
        #expect(store.add("Preferisco le riunioni al mattino", source: "utente"))
        #expect(!store.add("preferisco le riunioni al mattino!", source: "utente"))
        store.add("Il mio colore preferito è il verde", source: "utente")
        #expect(store.relevant(to: "quando fisso le riunioni?", limit: 1).first?.text.contains("riunioni") == true)
    }
}

@Suite @MainActor struct WebTests {
    @Test func parsesDuckDuckGoResults() {
        let html = """
        <div class="result results_links"><h2><a rel="nofollow" class="result__a" href="https://www.ilpost.it/articolo/">Il PSG ha vinto &amp; festeggia</a></h2>
        <a class="result__snippet" href="https://www.ilpost.it/articolo/">La <b>finale</b> di Budapest</a></div>
        <div class="result result--ad"><a class="result__a" href="https://duckduckgo.com/y.js?ad=1">Annuncio</a></div>
        <div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fit.wikipedia.org%2Fwiki%2FPSG&amp;rut=x">PSG - Wikipedia</a></div>
        """
        let results = Web.parseDuckDuckGo(html)
        #expect(results.count == 2)
        #expect(results[0].title == "Il PSG ha vinto & festeggia")
        #expect(results[0].snippet == "La finale di Budapest", "\(results[0].snippet.debugDescription)")
        #expect(results[1].url == "https://it.wikipedia.org/wiki/PSG")
        #expect(results[1].domain == "it.wikipedia.org")
    }

    @Test func extractsReadableText() {
        let html = """
        <html><head><title>Titolo &egrave; qui</title><script>var x = 1;</script></head><body>
        <nav><a href="/">Home</a> Menu lunghissimo del sito</nav>
        <article><h1>Il Paris Saint-Germain ha vinto la Champions</h1>
        <p>La finale si è giocata a Budapest il 30 maggio e si è decisa ai rigori contro l'Arsenal.</p>
        <p>Vitinha è stato nominato miglior giocatore della partita dalla UEFA.</p></article>
        <footer>Copyright e cookie</footer></body></html>
        """
        let text = Web.readableText(html)
        #expect(text.contains("Budapest"))
        #expect(!text.contains("var x"))
        #expect(!text.contains("Copyright"))
        #expect(Web.title(of: html) == "Titolo è qui")
        #expect(Web.firstURL(in: "riassumi https://example.com/a?b=1 grazie")?.host() == "example.com")
    }

    @Test func picksRelevantPassages() {
        let text = (1...40).map { "Paragrafo numero \($0) che parla di argomenti vari e generici." }.joined(separator: "\n")
            + "\nIl prezzo del biglietto per la finale era di 180 euro."
        let passages = Web.relevantPassages(text, query: "prezzo biglietto finale", budget: 300)
        #expect(passages.contains("180 euro"))
        #expect(passages.count <= 300)
    }

    @Test func explicitWebQueries() {
        #expect(Assistant.explicitWebQuery("cerca su internet i migliori ristoranti a Brera") == "i migliori ristoranti a Brera")
        #expect(Assistant.explicitWebQuery("orari del Louvre online") == "orari del Louvre")
        #expect(Assistant.explicitWebQuery("cerca la riunione con Marco") == nil)
        #expect(Assistant.domainURL("apri repubblica.it")?.absoluteString == "https://repubblica.it")
        #expect(Assistant.soundsUnsure("Mi dispiace, ma non ho informazioni aggiornate su questo evento."))
        #expect(!Assistant.soundsUnsure("La fotosintesi trasforma la luce in energia chimica."))
    }
}

@Suite struct MCPAuthTests {
    @Test func parsesChallenge() {
        let header = #"Bearer realm="mcp", error="invalid_token", resource_metadata="https://agency-os.it/.well-known/oauth-protected-resource", scope="read write""#
        #expect(MCPAuth.parameter("resource_metadata", in: header) == "https://agency-os.it/.well-known/oauth-protected-resource")
        #expect(MCPAuth.parameter("scope", in: header) == "read write")
        #expect(MCPAuth.parameter("realm", in: header) == "mcp")
        #expect(MCPAuth.resource(for: URL(string: "https://agency-os.it/mcp#x")!) == "https://agency-os.it/mcp")
    }

    /// Scoperta reale su un server pubblico (solo con SIRIAI_LIVE=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIRIAI_LIVE"] == "1")) func discoversAgencyOS() async throws {
        let challenge = #"Bearer realm="mcp", resource_metadata="https://agency-os.it/.well-known/oauth-protected-resource""#
        let metadata = try await MCPAuth.discover(serverURL: URL(string: "https://agency-os.it/mcp")!, challenge: challenge)
        #expect(metadata.authorizationEndpoint.absoluteString == "https://agency-os.it/mcp/authorize")
        #expect(metadata.tokenEndpoint.absoluteString == "https://agency-os.it/mcp/token")
        #expect(metadata.registrationEndpoint?.absoluteString == "https://agency-os.it/mcp/register")
    }

    @Test func loopbackReceivesCallback() async throws {
        let listener = try LoopbackListener()
        let port = try await listener.start()
        #expect(port > 0)
        async let values = listener.waitForCallback(timeout: 10)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=xyz")!)
        #expect(String(decoding: data, as: UTF8.self).contains("Accesso completato"))
        let received = try await values
        #expect(received["code"] == "abc")
        #expect(received["state"] == "xyz")
        listener.stop()
    }
}

@Suite struct BingTests {
    @Test func parsesBingResults() {
        let html = #"<ol><li class="b_algo" data-id=""><h2 class=""><a target="_blank" href="https://www.bing.com/ck/a?!&amp;&amp;p=abc&amp;u=a1aHR0cHM6Ly9pdC53aWtpcGVkaWEub3JnL3dpa2kvU2FucmVtbw&amp;ntb=1" h="ID=SERP">Sanremo - <strong>Wikipedia</strong></a></h2><div class="b_caption"><p class="b_lineclamp2">Ogni anno Sanremo &#232; la sede</p></div></li></ol>"#
        let results = Web.parseBing(html)
        #expect(results.count == 1)
        #expect(results.first?.url == "https://it.wikipedia.org/wiki/Sanremo")
        #expect(results.first?.title == "Sanremo - Wikipedia")
        #expect(results.first?.snippet == "Ogni anno Sanremo è la sede")
    }
}

@Suite @MainActor struct MCPArgumentTests {
    @Test func dropsInventedArguments() throws {
        let schema = try JSONValue.parse(Data(#"{"type":"object","required":["name"],"properties":{"name":{"type":"string"},"toolset":{"type":"string"},"agency_id":{"type":"string"},"limit":{"type":"integer","default":20},"arguments":{"type":"object"}}}"#.utf8))
        let value = JSONValue.object(["name": .string("list_clients"), "toolset": .string("clienti"), "agency_id": .string("mainstream"),
                                      "limit": .number(20), "arguments": .object(["agency_id": .string("mainstream"), "status": .string("attivo")])])
        let cleaned = Assistant.dropInvented(value, schema: schema, evidence: "quali sono i miei clienti attivo? {\"name\":\"list_clients\"}")
        #expect(cleaned["name"]?.string == "list_clients")
        #expect(cleaned["toolset"] == nil)
        #expect(cleaned["agency_id"] == nil)
        #expect(cleaned["limit"] == nil)
        #expect(cleaned["arguments"]?["agency_id"] == nil)
        #expect(cleaned["arguments"]?["status"]?.string == "attivo")
    }

    @Test func freeFormObjectFromText() throws {
        let schema = try JSONValue.parse(Data(#"{"type":"object","properties":{"arguments":{"type":"object"}}}"#.utf8))
        let value = JSONSchemaBridge.conform(.object(["arguments": .string(#"{"limit": 5}"#)]), to: schema)
        #expect(value["arguments"]?["limit"]?.number == 5)
    }
}

@Suite struct ProjectFileOpsTests {
    @Test func findMoveTrash() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ops-\(UUID().uuidString)")
        let files = ProjectFiles(root: root)
        try files.write("1_Progetti/alpha/note.md", content: "ciao")
        try files.write("OBJECTIVES.md", content: "obiettivi")
        try files.createFolder("4_Archivio")
        #expect(files.find("3_Risorse/OBJECTIVES.md") == "OBJECTIVES.md")
        #expect(files.find("objectives.md") == "OBJECTIVES.md")
        #expect(files.find("note") == "1_Progetti/alpha/note.md")
        #expect(files.find("archivio", directories: true) == "4_Archivio")
        try files.move("OBJECTIVES.md", to: "4_Archivio/OBJECTIVES.md")
        #expect(files.exists("4_Archivio/OBJECTIVES.md"))
        #expect(throws: ProjectFiles.FileError.self) { try files.move("../x", to: "y") }
        try files.trash("1_Progetti/alpha/note.md")
        #expect(!files.exists("1_Progetti/alpha/note.md"))
    }
}

@Suite struct TaskPlanTests {
    @Test func batchesKeepEveryStep() {
        let steps = [TaskPlan.Step(title: "a", instruction: "Cerca a", parallel: false),
                     TaskPlan.Step(title: "b", instruction: "Cerca b", parallel: true),
                     TaskPlan.Step(title: "c", instruction: "Cerca c", parallel: true),
                     TaskPlan.Step(title: "d", instruction: "Analizza", parallel: false)]
        let plan = TaskPlan(goal: "x", thoughts: [], steps: steps, delivery: .risposta)
        #expect(plan.batches(maxParallel: 2) == [[0, 1], [2], [3]])
        #expect(plan.batches(maxParallel: 4) == [[0, 1, 2], [3]])
        #expect(plan.batches(maxParallel: 1).flatMap { $0 } == [0, 1, 2, 3])
    }

    @Test func memoryFileAtRoot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = ProjectFiles(root: root)
        files.ensureMemoryFile()
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "MEMORY.md").path))
        try files.saveMemoryText(files.memoryText() + "\n## Altro\n\n- non toccare\n")
        try files.remember("Il cliente vuole il blu")
        #expect(files.memoryFacts().contains { $0.contains("blu") })
        #expect(files.memoryText().contains("- non toccare"))
        #expect(!files.memoryFacts().contains("non toccare"))
    }
}

@Suite @MainActor struct ChatRequestTests {
    @Test func parsesChatRequests() {
        let assistant = Assistant()
        var work = WorkContext()
        work.projectNames = ["IVAN AI OS", "Sito web"]
        work.hasConversation = true
        assistant.work = work
        func request(_ text: String) -> ChatRequest? {
            var plan = Assistant.Plan(action: .rispondi, fields: [:])
            guard assistant.chatRules(to: &plan, prompt: text, lower: text.lowercased()) else { return nil }
            return assistant.chatRequest(from: plan, prompt: text)
        }
        let a = request("apri una nuova chat nel progetto IVAN AI OS sugli obiettivi del Q4 e chiedi quali sono le priorità")
        #expect(a?.project == "IVAN AI OS")
        #expect(a?.title == "Obiettivi del Q4")
        #expect(a?.firstMessage == "Quali sono le priorità")
        #expect(a?.child == true)
        let b = request("crea una chat figlia per la ricerca concorrenti: cerca i 5 principali concorrenti")
        #expect(b?.title == "Ricerca concorrenti")
        #expect(b?.firstMessage == "Cerca i 5 principali concorrenti")
        let c = request("facciamo una conversazione indipendente sulle vacanze")
        #expect(c?.child == false)
        #expect(c?.title == "Vacanze")
        #expect(request("chatgpt è meglio di claude?") == nil)
    }
}

@Suite struct MarkdownTests {
    @Test func rendersBlocks() {
        let md = """
        ---
        tipo: nota
        ---
        # Titolo
        Testo con **grassetto**, *corsivo*, `codice` e [link](https://apple.com).

        - [x] fatto
        - [ ] da fare
          - annidato
        1. primo

        > [!nota] Attenzione
        > dettaglio

        | A | B |
        | --- | --- |
        | 1 | 2 |

        ```swift
        let x = 1 < 2
        ```
        """
        let html = Markdown.html(from: md)
        #expect(html.contains("<table class=\"frontmatter\">"))
        #expect(html.contains("<h1 id=\"titolo\">Titolo</h1>"))
        #expect(html.contains("<strong>grassetto</strong>"))
        #expect(html.contains("<em>corsivo</em>"))
        #expect(html.contains("<code>codice</code>"))
        #expect(html.contains("<a href=\"https://apple.com\">link</a>"))
        #expect(html.contains("<li class=\"task done\"><input type=\"checkbox\" disabled checked> fatto"))
        #expect(html.contains("<ul><li>annidato</li></ul>"))
        #expect(html.contains("<ol>"))
        #expect(html.contains("blockquote class=\"callout\""))
        #expect(html.contains("<td>2</td>"))
        #expect(html.contains("let x = 1 &lt; 2"))
    }

    @Test func websiteTemplate() {
        let html = WebsiteTemplate.html(title: "Pizzeria <Da Totò>", subtitle: "Vera napoletana", button: "Ordina",
                                        features: [("🍕", "Forno a legna", "Cotta in 90 secondi")], sections: [("Chi siamo", "Dal 1990.", ["Qualità"])], closing: "Vieni a trovarci")
        #expect(html.contains("<link rel=\"stylesheet\" href=\"style.css\">"))
        #expect(html.contains("Pizzeria &lt;Da Totò&gt;"))
        #expect(html.contains("<li>Qualità</li>"))
        let css = WebsiteTemplate.css(dark: true, accent: "verde")
        #expect(css.contains("--accent: #34c77b"))
        #expect(css.contains("@media (max-width: 700px)"))
    }
}

@Suite @MainActor struct AgentFolderTests {
    @Test func linkedFoldersWithPermissions() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "agent-\(UUID().uuidString)")
        let docs = base.appending(path: "Documenti"), notes = base.appending(path: "Appunti"), workspace = base.appending(path: "ws")
        for url in [docs, notes, workspace] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try "ciao".write(to: docs.appending(path: "a.md"), atomically: true, encoding: .utf8)
        var files = ProjectFiles(root: workspace)
        files.links = ["Documenti": docs, "Appunti": notes]
        files.readOnly = ["Documenti"]
        #expect(files.list().map(\.path).contains("Documenti/a.md"))
        #expect(try files.read("Documenti/a.md") == "ciao")
        #expect(files.find("a.md") == "Documenti/a.md")
        #expect(throws: ProjectFiles.FileError.self) { try files.write("Documenti/b.md", content: "no") }
        try files.write("Appunti/b.md", content: "sì")
        #expect(FileManager.default.fileExists(atPath: notes.appending(path: "b.md").path))
        #expect(throws: ProjectFiles.FileError.self) { try files.resolve("Altro/x.md") }
        #expect(throws: ProjectFiles.FileError.self) { try files.resolve("Appunti/../../fuori.txt") }
    }

    @Test func legacyAgentDecodes() throws {
        let json = #"{"id":"6C1F2B8E-9A34-4D7E-8C11-2F4B5A6D7E80","name":"Posta","goal":"Leggi la posta","schedule":{"kind":"giornaliero","hour":18,"minute":0,"weekday":2},"active":true}"#
        let agent = try JSONDecoder().decode(AgentSpec.self, from: Data(json.utf8))
        #expect(agent.routines.count == 1)
        #expect(agent.routines.first?.schedule.hour == 18)
        #expect(agent.dreamsEnabled)
        let soul = Assistant.soul(agent.defaultSoul, adding: ["Rispondere prima alle email dei clienti"])
        #expect(soul.contains("Rispondere prima alle email dei clienti"))
        #expect(soul.contains("## Valori"))
    }
}

@Suite struct SpaceScopeTests {
    @Test func taskScopeOverridesGlobal() async {
        var work = SpaceScope()
        work.name = "Lavoro"
        work.calendars = ["Lavoro"]
        var personal = SpaceScope()
        personal.name = "Personale"
        personal.mailAccount = "iCloud"
        SpaceScope.global = work
        #expect(SpaceScope.current.name == "Lavoro")
        await SpaceScope.$task.withValue(personal) {
            #expect(SpaceScope.current.name == "Personale")
            #expect(SpaceScope.current.mailAccount == "iCloud")
            // Anche i Task figli (sub-agent) vedono lo spazio della richiesta.
            let inner = await Task { SpaceScope.current.name }.value
            #expect(inner == "Personale")
        }
        #expect(SpaceScope.current.calendars == ["Lavoro"])
        SpaceScope.global = SpaceScope()
    }
}
