import Foundation
import FoundationModels

/// Cosa succede durante un giro sui connettori: le schede dell'app e il banco di prova lo seguono passo per passo.
public enum ConnectorEvent: Sendable {
    case calling(MCPCallDraft)
    case finished(MCPCallDraft, result: String)
    case failed(MCPCallDraft, error: String)
}

/// Esito di un giro sui connettori: il prompt per la risposta con i risultati, oppure una chiamata che scrive da confermare.
public struct ConnectorRun: Sendable {
    public var steps: [MCPStep]
    public var pending: MCPCallDraft?
    public var answerPrompt: String?
}

extension Assistant {
    // MARK: - Connettori MCP

    /// Nome del server collegato citato nella richiesta ("agency os", "@notion"), anche con una sola parola distintiva
    /// del nome («nel CRM» per «Demo CRM», «su Agency» per «Agency OS»).
    func namedServer(_ lower: String) -> String? {
        let servers = Set(work.mcpTools.map(\.serverName))
        let sorted = servers.sorted { $0.count > $1.count }
        if let full = sorted.first(where: { name in
            let key = name.lowercased()
            let compact = key.replacingOccurrences(of: " ", with: "")
            return lower.contains(key) || lower.contains("@" + compact) || (compact.count >= 5 && lower.replacingOccurrences(of: " ", with: "").contains(compact))
        }) { return full }
        let requestWords = Set(MemoryStore.normalize(lower).split(separator: " ").map(String.init))
        let generic: Set<String> = ["demo", "app", "apps", "server", "mcp", "the", "my", "your", "tool", "tools", "api", "online", "web", "cloud", "plus", "pro", "hub"]
        let matches = sorted.filter { name in
            MemoryStore.normalize(name).split(separator: " ").map(String.init).contains { word in
                word.count >= 3 && !generic.contains(word) && requestWords.contains(word)
            }
        }
        // Una parola che indica un solo servizio: con due servizi che la condividono si lascia decidere al pianificatore.
        return matches.count == 1 ? matches[0] : nil
    }

    /// La lingua in cui il servizio descrive i suoi strumenti: le parole chiave delle ricerche vanno scritte in quella.
    func serviceLanguage(_ server: String) -> Language {
        let text = work.mcpTools.filter { $0.serverName == server }.prefix(12).map(\.description).joined(separator: " ")
        return text.count < 40 ? Language.current : Language.detect(text, fallback: .en)
    }

    /// Parole troppo comuni per indicare un servizio ("come", "quali", "tool"…); in inglese anche quelle inglesi.
    static var stopwords: Set<String> { Language.isEnglish ? englishStopwords : italianStopwords }

    private static let englishStopwords: Set<String> = italianStopwords.union([
        "how", "are", "you", "can", "could", "would", "please", "like", "want", "show", "tell", "give", "all", "my", "mine", "our",
        "their", "today", "tomorrow", "after", "before", "every", "only", "always", "never", "where", "when", "why", "who", "does",
        "use", "using", "field", "optional", "defined", "meaning", "data", "some", "any", "there", "here", "into", "over", "just",
    ])

    private static let italianStopwords: Set<String> = [
        "come", "stai", "sono", "cosa", "quale", "quali", "questo", "questa", "quello", "quella", "della", "delle", "degli", "dello",
        "nella", "nelle", "negli", "sulla", "sulle", "alla", "alle", "dalla", "dalle", "anche", "tutto", "tutti", "tutte", "molto",
        "ciao", "grazie", "essere", "avere", "fare", "dove", "quando", "perché", "perche", "oggi", "domani", "dopo", "prima", "ogni",
        "solo", "sempre", "mai", "tuoi", "miei", "mio", "suoi", "loro", "nostri", "vostri", "puoi", "vorrei", "voglio", "dimmi",
        "usa", "questo", "strumento", "strumenti", "tool", "tools", "quando", "devi", "usare", "dati", "nome", "with", "from",
        "this", "that", "the", "your", "have", "what", "which", "about", "campo", "significato", "definito", "contratto", "opzionale",
    ]

    static func meaningful(_ text: String) -> Set<String> {
        MemoryStore.keywords(text).subtracting(stopwords)
    }

    /// Server i cui strumenti condividono almeno due parole significative con la richiesta. Le parole si confrontano sulla
    /// radice («task»/«tasks», «progetto»/«progetti») e anche tradotte: una richiesta in italiano trova gli strumenti
    /// descritti in inglese («fatture scadute» → invoices, overdue) e viceversa.
    func strongServerMatch(_ lower: String) -> String? {
        let words = Self.meaningful(lower)
        let expanded = words.union(words.flatMap { Self.domainTranslations($0) })
        var found: [String: Set<String>] = [:]
        for tool in work.mcpTools {
            let text = MCPToolInfo.nameWords(tool.name).joined(separator: " ") + " " + tool.description.prefix(200)
            for word in Self.meaningful(text) {
                // Una parola della richiesta conta una volta sola, anche se la trovano più strumenti.
                if let match = expanded.first(where: { Self.sameStem($0, word) }) {
                    let source = words.first { $0 == match || Self.domainTranslations($0).contains(match) } ?? match
                    found[tool.serverName, default: []].insert(source)
                }
            }
        }
        // Solo nomi e descrizioni degli strumenti: le istruzioni scritte dal server non possono farlo scegliere.
        return found.filter { $0.value.count >= 2 }.max { $0.value.count < $1.value.count }?.key
    }

    /// Stessa parola a meno della desinenza: «task»/«tasks», «cliente»/«clienti», «project»/«projects».
    static func sameStem(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let common = zip(a, b).prefix { $0 == $1 }.count
        return common >= max(4, min(a.count, b.count) - 1)
    }

    /// Le parole del lavoro d'ufficio nell'altra lingua (le descrizioni degli strumenti sono quasi sempre in inglese).
    static let domainWords: [[String]] = [
        ["cliente", "clienti", "client", "clients", "customer", "customers"],
        ["task", "tasks", "compito", "compiti", "attivita", "todo", "todos"],
        ["progetto", "progetti", "project", "projects"],
        ["fattura", "fatture", "invoice", "invoices", "billing"],
        ["preventivo", "preventivi", "quote", "quotes", "estimate", "estimates"],
        ["riunione", "riunioni", "incontro", "incontri", "meeting", "meetings"],
        ["contatto", "contatti", "referente", "referenti", "contact", "contacts"],
        ["trattativa", "trattative", "deal", "deals", "opportunita", "opportunity", "opportunities"],
        ["ordine", "ordini", "order", "orders"],
        ["prodotto", "prodotti", "product", "products"],
        ["campagna", "campagne", "campaign", "campaigns"],
        ["scadenza", "scadenze", "scadute", "scaduti", "scaduta", "scaduto", "deadline", "deadlines", "overdue"],
        ["agenzia", "agenzie", "agency", "agencies"],
        ["pagamento", "pagamenti", "payment", "payments"],
        ["dipendente", "dipendenti", "employee", "employees", "persone"],
        ["editoriale", "editorial"],
        ["documento", "documenti", "document", "documents"],
        ["pagina", "pagine", "page", "pages"],
        ["segnalazione", "segnalazioni", "ticket", "tickets", "issue", "issues"],
        ["fornitore", "fornitori", "supplier", "suppliers", "vendor", "vendors"],
        ["magazzino", "inventario", "inventory", "stock"],
        ["candidato", "candidati", "candidate", "candidates"],
        ["listino", "prezzi", "pricing", "price", "prices"],
    ]

    static func domainTranslations(_ word: String) -> [String] {
        domainWords.filter { group in group.contains { sameStem($0, word) } }.flatMap { $0 }
    }

    /// I servizi collegati e di cosa si occupano, dai nomi dei loro strumenti: «Agency Os (client, portfolio, project, quote, task)».
    /// Serve allo smistatore per capire che «i task in scadenza» riguardano il connettore anche se non viene nominato.
    func connectorSummary() -> String {
        let generic: Set<String> = [
            "get", "list", "search", "find", "read", "fetch", "query", "describe", "show", "execute", "tool", "tools", "toolsets",
            "schema", "render", "builder", "workspace", "create", "update", "delete", "info", "whoami", "switch", "write",
            "critical", "workbench", "cockpit", "items", "item", "data", "details", "detail", "by", "id", "all", "my",
        ]
        var byServer: [String: [String]] = [:]
        for tool in work.mcpTools {
            for word in MCPToolInfo.nameWords(tool.name) where word.count >= 4 && !generic.contains(word) {
                if !(byServer[tool.serverName] ?? []).contains(word) { byServer[tool.serverName, default: []].append(word) }
            }
            if byServer[tool.serverName] == nil { byServer[tool.serverName] = [] }
        }
        return byServer.sorted { $0.key < $1.key }
            .map { server, words in words.isEmpty ? server : "\(server) (\(words.prefix(10).joined(separator: ", ")))" }
            .joined(separator: "; ")
    }

    /// La richiesta chiede di creare, cambiare, eliminare o inviare qualcosa (su un servizio «a catalogo» serve lo strumento che scrive).
    /// Solo verbi come parole intere: «i task completati», «i clienti creati ieri» sono letture.
    static func asksToWrite(_ lower: String) -> Bool {
        lower.range(of: #"\b(?:crea|creami|aggiungi|aggiungimi|inserisci|modifica|aggiorna|cambia|elimina|cancella|rimuovi|invia|inviami|manda|mandami|sposta|archivia|assegna|completa|segna|chiudi|registra|prepara un|prepara una|apri un|apri una|create|add|insert|edit|update|change|delete|remove|send|move|archive|assign|complete|mark|close|log|register|open an?|draft an?|set up)\b"#,
                    options: .regularExpression) != nil
    }

    /// Le parole con cui cercare uno strumento interno quando la prima ricerca non trova niente: gli oggetti della richiesta
    /// nella lingua del servizio, con «create» se chiede di scrivere («crea un preventivo» → «create quote»).
    static func catalogQuery(_ lower: String, language: Language) -> String? {
        let words = MemoryStore.keywords(lower)
        var terms: [String] = []
        for word in words.sorted() {
            guard let group = domainWords.first(where: { group in group.contains { sameStem($0, word) } }) else { continue }
            // Il primo termine del gruppo nella lingua del servizio: «quote», «invoice», «client» (o «preventivo»…).
            let pick = group.first { language == .en ? englishDomain.contains($0) : !englishDomain.contains($0) }
            if let pick, !terms.contains(pick) { terms.append(pick) }
        }
        guard !terms.isEmpty else { return nil }
        if asksToWrite(lower) { terms.insert(language == .en ? "create" : "crea", at: 0) }
        return terms.prefix(4).joined(separator: " ")
    }

    /// Le parole inglesi del lessico (la prima di ogni gruppo che non è italiana).
    static let englishDomain: Set<String> = [
        "client", "clients", "customer", "customers", "task", "tasks", "todo", "todos", "project", "projects", "invoice", "invoices",
        "billing", "quote", "quotes", "estimate", "estimates", "meeting", "meetings", "contact", "contacts", "deal", "deals",
        "opportunity", "opportunities", "order", "orders", "product", "products", "campaign", "campaigns", "deadline", "deadlines",
        "overdue", "agency", "agencies", "payment", "payments", "employee", "employees", "editorial", "document", "documents",
        "page", "pages", "ticket", "tickets", "issue", "issues", "supplier", "suppliers", "vendor", "vendors", "inventory", "stock",
        "candidate", "candidates", "pricing", "price", "prices",
    ]

    /// Lo strumento il cui nome parla di ciò che si chiede: per scrivere uno che crea o cambia («create_task» per «crea un task»),
    /// per elencare uno «list_…/get_…» («list_tasks» per «i task in scadenza»). Nil se nessuno combacia con sicurezza.
    static func bestTool(for lower: String, among tools: [MCPToolInfo], writing: Bool) -> MCPToolInfo? {
        let words = MemoryStore.keywords(lower)
        let expanded = words.union(words.flatMap { domainTranslations($0) })
        var best: (tool: MCPToolInfo, score: Int)?
        for tool in tools where writing ? !tool.isReadOnly : tool.isReadOnly {
            let name = MCPToolInfo.nameWords(tool.name)
            guard let verb = name.first, writing ? MCPToolInfo.writingWords.contains(verb) || MCPToolInfo.actionWords.contains(verb)
                                                  : ["list", "get", "elenca"].contains(verb) else { continue }
            let score = name.dropFirst().filter { part in part.count >= 4 && expanded.contains { sameStem($0, part) } }.count
            if score > (best?.score ?? 0) { best = (tool, score) }
        }
        return best?.tool
    }

    /// Una ricerca su qualcosa o qualcuno («cerca…», «chi è…», «trova…»): se il pianificatore ha indicato lo strumento
    /// di un connettore, lo si usa invece di rispondere a memoria.
    static func isLookup(_ lower: String) -> Bool {
        ["cerca", "trova", "ricerca", "chi è", "chi e ", "informazioni su", "info su", "dimmi di", "dettagli di", "scheda di",
         "search", "find ", "look up", "lookup", "who is", "information about", "details of", "details about"].contains(where: lower.contains)
    }

    private func tools(of server: String?) -> [MCPToolInfo] {
        guard let server else { return work.mcpTools }
        let filtered = work.mcpTools.filter { $0.serverName == server }
        return filtered.isEmpty ? work.mcpTools : filtered
    }

    private func toolCatalog(_ tools: [MCPToolInfo]) -> String {
        tools.prefix(30).map { "- \($0.name): \($0.description.replacingOccurrences(of: "\n", with: " ").prefix(120))" }.joined(separator: "\n")
    }

    private func serverGuide(_ server: String?) -> String {
        guard let server, let text = work.mcpInstructions[server], !text.isEmpty else { return "" }
        // Guida scritta dal servizio: aiuta a scegliere lo strumento, ma resta un dato (niente ordini).
        return Self.untrusted(String(text.prefix(700)), label: Language.t("guida del servizio ", "guide of the service ") + server) + "\n"
    }

    /// Prima chiamata: lo strumento viene scelto con una generazione dedicata, solo fra quelli del servizio.
    func firstMCPCall(_ plan: Plan, prompt: String, status: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        let server = plan["server"] ?? work.mcpTools.first { $0.name == plan["strumento"] }?.serverName
        let candidates = tools(of: server)
        let english = Language.isEnglish
        let serverName = server ?? (english ? "the connector" : "connettore")
        guard !candidates.isEmpty else { return .message(Language.t("Nessun connettore attivo: controlla in Connettori.", "No active connector: check Connectors.")) }
        status(english ? "Choosing the \(serverName) tool…" : "Scelgo lo strumento di \(serverName)…")
        let lower = prompt.lowercased()
        var tool = candidates.first { lower.contains($0.name.lowercased()) }
        // Servizi "a catalogo": per elenchi e dati strutturati si parte cercando lo strumento interno giusto.
        let listing = (["quali", "quanti", "elenca", "lista", "elenco", "tutti", "tutte", "miei", "mie", "ultim", "recent", "in scadenza",
                        "aperti", "aperte", "di oggi", "della settimana", "stato", "riepilogo", "panoramica"]
                       + (english ? ["which", "how many", "list", "all ", "my ", "latest", "last ", "due", "open ", "today's", "this week",
                                     "status", "summary", "overview"] : [])).contains(where: lower.contains)
        if tool == nil, listing || Self.asksToWrite(lower), let catalog = candidates.first(where: { $0.name == "search_tools" }),
           candidates.contains(where: { ["execute_read_tool", "execute_write_tool"].contains($0.name) }) {
            tool = catalog
        }
        // Scrivere: se lo strumento vuole un id (client_id…) e c'è una ricerca, prima si trova l'elemento; altrimenti si scrive subito.
        // Elencare o filtrare: lo strumento «list_…» che parla di ciò che si chiede (list_tasks per «i task in scadenza»).
        let writing = Self.asksToWrite(lower)
        var lookupBeforeWriting = false
        if tool == nil, let best = Self.bestTool(for: lower, among: candidates, writing: writing) {
            let needsID = (best.inputSchema["properties"]?.object ?? [:]).keys.contains { $0.hasSuffix("_id") || $0 == "id" }
            if writing, needsID, let finder = candidates.first(where: { $0.isReadOnly && MCPToolInfo.nameWords($0.name).first == "search" }) {
                tool = finder
                lookupBeforeWriting = Self.properName(prompt, excluding: finder.serverName) != nil
            } else {
                tool = best
            }
        }
        if tool == nil { tool = await chooseTool(prompt: prompt, among: candidates, server: server, steps: []) }
        if tool == nil { tool = candidates.first { $0.name == plan["strumento"] } }
        guard let tool else {
            return .message(english ? "I couldn't tell which \(serverName) tool to use." : "Non ho capito quale strumento di \(serverName) usare.")
        }
        status(english ? "Preparing \(tool.name)…" : "Preparo \(tool.name)…")
        let arguments: JSONValue
        if lookupBeforeWriting, let direct = Self.fallbackArguments(for: tool, prompt: prompt) {
            // Per trovare l'id del cliente basta il suo nome («Verde Bio»), non tutta la frase con la data.
            arguments = direct
        } else { do {
            arguments = try await self.arguments(for: tool, prompt: prompt, steps: [])
        } catch {
            // Filtro di sicurezza o generazione non riuscita: per una ricerca bastano le parole chiave della richiesta.
            guard let fallback = Self.fallbackArguments(for: tool, prompt: prompt) else { throw error }
            Agent.log("CONNETTORE: argomenti dalla richiesta per \(tool.name) (\(error.localizedDescription.prefix(80)))")
            arguments = fallback
        } }
        return .mcpCall(MCPCallDraft(tool: tool, arguments: arguments, request: prompt, steps: []))
    }

    private static func toolChoiceSchema(_ names: [String], allowStop: Bool) -> GenerationSchema {
        var fields: [Field] = []
        if allowStop {
            fields.append(.required("azione", .choice(["rispondi", "chiama"]),
                                    Language.t("rispondi se i risultati bastano per rispondere, chiama se serve un altro strumento",
                                               "rispondi if the results are enough to answer, chiama if another tool is needed")))
        }
        fields.append(.required("strumento", .choice(names), Language.t("Strumento da usare", "Tool to use")))
        return makeSchema("SceltaStrumento", fields)
    }

    func chooseTool(prompt: String, among tools: [MCPToolInfo], server: String?, steps: [MCPStep]) async -> MCPToolInfo? {
        if tools.count == 1 { return tools[0] }
        if let quick = await quickTool(prompt: prompt, among: tools, steps: steps) { return quick }
        let session = LanguageModelSession(model: Agent.model, instructions: Language.isEnglish ? """
        Choose the most suitable tool to fulfill the user's request.
        \(serverGuide(server))Available tools:
        \(toolCatalog(tools))
        Prefer search or read tools; for "catalog" services first use the tool that searches the internal tools, then the one that runs them.
        """ : """
        Scegli lo strumento più adatto per soddisfare la richiesta dell'utente.
        \(serverGuide(server))Strumenti disponibili:
        \(toolCatalog(tools))
        Preferisci strumenti di ricerca o lettura; per i servizi "a catalogo" usa prima lo strumento che cerca gli strumenti interni e poi quello che li esegue.
        """)
        let request = Language.t("Richiesta: ", "Request: ") + prompt + Self.describe(steps)
        guard let content = try? await session.respond(to: request, schema: Self.toolChoiceSchema(tools.map(\.name), allowStop: false),
                                                       options: GenerationOptions(samplingMode: .greedy)).content,
              let name = content.string("strumento") else { return nil }
        return tools.first { $0.name == name }
    }

    /// Dopo un risultato: serve un'altra chiamata (es. cercare lo strumento interno e poi eseguirlo) o si può rispondere?
    /// `result` è il testo che legge il modello, `raw` la risposta originale del servizio (con gli schemi in JSON).
    public func nextMCPStep(after draft: MCPCallDraft, result: String, raw: String? = nil) async -> MCPCallDraft? {
        let raw = raw ?? result
        let steps = (draft.steps ?? []) + [MCPStep(tool: draft.tool.name, arguments: draft.arguments.compactString, result: String(result.prefix(1800)))]
        mcpCalls += 1
        guard steps.count < 5, !result.isEmpty, mcpCalls < RequestLimits.mcpCalls else { return nil }
        let request = draft.request ?? ""
        let server = draft.tool.serverName
        let candidates = tools(of: server)
        // Servizi «a catalogo»: trovato lo strumento interno se ne legge lo schema (se la ricerca non lo dà già),
        // poi lo si esegue con quello che legge o, se la richiesta cambia qualcosa, con quello che scrive (da confermare).
        let executorName = Self.asksToWrite(request.lowercased()) ? "execute_write_tool" : "execute_read_tool"
        let executor = candidates.first { $0.name == executorName } ?? candidates.first { $0.name == "execute_read_tool" }
        let found = result.count > 20 && !result.contains("\"results\":[]") && !result.contains("\"tools\":[]")
            && !result.hasPrefix(Language.t("0 elementi", "0 items"))
        if draft.tool.name == "search_tools", !found, steps.filter({ $0.tool == "search_tools" }).count == 1,
           let retry = Self.catalogQuery(request.lowercased(), language: serviceLanguage(server)),
           retry != draft.arguments["query"]?.string {
            var arguments = draft.arguments.object ?? [:]
            arguments["query"] = .string(retry)
            return MCPCallDraft(tool: draft.tool, arguments: .object(arguments), request: request, steps: steps)
        }
        if draft.tool.name == "search_tools", found, let executor {
            if !Self.containsSchema(raw), let describer = candidates.first(where: { ["get_tool_schema", "describe_tool"].contains($0.name) }),
               let arguments = try? await arguments(for: describer, prompt: request, steps: steps) {
                return MCPCallDraft(tool: describer, arguments: arguments, request: request, steps: steps)
            }
            return try? await executorCall(executor, request: request, steps: steps, raw: raw)
        }
        if ["get_tool_schema", "describe_tool"].contains(draft.tool.name), steps.contains(where: { $0.tool == "search_tools" }), let executor {
            return try? await executorCall(executor, request: request, steps: steps, raw: raw)
        }
        // L'utente chiede di creare o cambiare qualcosa e finora si è solo letto (per esempio l'id del cliente): si prepara
        // la scrittura, che resta da confermare nella sua scheda.
        let wrote = steps.contains { step in candidates.first { $0.name == step.tool }.map { !$0.isReadOnly } ?? false }
        if Self.asksToWrite(request.lowercased()), !wrote, let writer = Self.bestTool(for: request.lowercased(), among: candidates, writing: true) {
            guard let arguments = try? await arguments(for: writer, prompt: request, steps: steps) else { return nil }
            return MCPCallDraft(tool: writer, arguments: arguments, request: request, steps: steps)
        }
        // rizzo-flow: i risultati bastano? Se sì si risponde; se serve altro sceglie lo strumento. Apple solo se non è sicuro.
        if let enough = await quickEnough(request: request, steps: steps) {
            if enough { return nil }
            if let tool = await quickTool(prompt: request, among: candidates, steps: steps) {
                guard let arguments = try? await arguments(for: tool, prompt: request, steps: steps) else { return nil }
                if steps.contains(where: { $0.tool == tool.name && $0.arguments == arguments.compactString }) { return nil }
                return MCPCallDraft(tool: tool, arguments: arguments, request: request, steps: steps)
            }
        }
        let session = LanguageModelSession(model: Agent.model, instructions: Language.isEnglish ? """
        You are using the tools of the \(server) service to fulfill a request. Decide whether the results obtained are enough (rispondi) \
        or whether another tool must be called (chiama), for example to run a tool found with a search or to read the details of an item.
        \(serverGuide(server))Tools:
        \(toolCatalog(candidates))
        """ : """
        Stai usando gli strumenti del servizio \(server) per soddisfare una richiesta. Decidi se i risultati ottenuti bastano (rispondi) \
        o se serve chiamare un altro strumento (chiama), per esempio per eseguire uno strumento trovato con una ricerca o leggere il dettaglio di un elemento.
        \(serverGuide(server))Strumenti:
        \(toolCatalog(candidates))
        """)
        guard let content = try? await session.respond(to: Language.t("Richiesta: ", "Request: ") + request + Self.describe(steps),
                                                       schema: Self.toolChoiceSchema(candidates.map(\.name), allowStop: true),
                                                       options: GenerationOptions(samplingMode: .greedy)).content,
              content.string("azione") == "chiama",
              let tool = candidates.first(where: { $0.name == content.string("strumento") }) else { return nil }
        guard let arguments = try? await arguments(for: tool, prompt: request, steps: steps) else { return nil }
        // Stessa chiamata di prima: non si va in loop.
        if steps.contains(where: { $0.tool == tool.name && $0.arguments == arguments.compactString }) { return nil }
        return MCPCallDraft(tool: tool, arguments: arguments, request: request, steps: steps)
    }

    /// Prompt per la risposta finale con tutti i risultati delle chiamate.
    public func mcpAnswerPrompt(request: String, steps: [MCPStep]) -> String {
        let budget = self.budget.scaled(2600)
        var blocks: [String] = []
        for (index, step) in steps.enumerated() {
            let share = index == steps.count - 1 ? budget / 2 : budget / (2 * max(1, steps.count - 1))
            blocks.append(Language.t("Risultato di ", "Result of ") + "\(step.tool) \(step.arguments.prefix(160)):\n\(step.result.prefix(share))")
        }
        remember(Language.t("Risultati dei connettori per «\(request)»:\n", "Connector results for «\(request)»:\n") + (steps.last.map { String($0.result.prefix(700)) } ?? ""))
        // Chiesta una modifica ma eseguite solo letture: nessuna risposta deve far credere che sia fatta.
        let wrote = steps.contains { step in work.mcpTools.first { $0.name == step.tool }.map { !$0.isReadOnly } ?? false }
        if Self.asksToWrite(request.lowercased()), !wrote {
            blocks.append(Language.t("Nota: sul servizio non è stato creato né modificato niente. Non dire che è fatto: spiega cosa hai trovato e cosa manca.",
                                     "Note: nothing was created or changed in the service. Don't say it's done: explain what you found and what's missing."))
        }
        return grounded(request, blocks.joined(separator: "\n\n"), label: Language.t("risultati dei connettori", "connector results"))
    }

    static func describe(_ steps: [MCPStep]) -> String {
        guard !steps.isEmpty else { return "" }
        return Language.t("\n\nChiamate già fatte:\n", "\n\nCalls already made:\n") + untrusted(steps.enumerated().map { index, step in
            "\(index + 1). \(step.tool) \(step.arguments.prefix(200)) → \(step.result.prefix(index == steps.count - 1 ? 1200 : 400))"
        }.joined(separator: "\n"), label: Language.t("risultati dei connettori", "connector results"))
    }

    /// «Scrivi le parole chiave in inglese»: quando il servizio descrive i suoi strumenti in un'altra lingua (tranne i nomi propri).
    func searchLanguageHint(_ tool: MCPToolInfo) -> String {
        let service = serviceLanguage(tool.serverName)
        guard service != Language.current else { return "" }
        return service == .en
            ? Language.t(" Il servizio è in inglese: scrivi le parole chiave in inglese (per esempio «fatture scadute» → «overdue invoices»), i nomi propri come sono.",
                         " The service is in English: write the keywords in English, proper names as they are.")
            : Language.t(" Il servizio è in italiano: scrivi le parole chiave in italiano, i nomi propri come sono.",
                         " The service is in Italian: write the keywords in Italian (for example «overdue invoices» → «fatture scadute»), proper names as they are.")
    }

    /// Le date della richiesta già calcolate dall'app («venerdì» = 2026-10-02): il modello piccolo sbaglia i giorni della settimana.
    static func connectorDates(_ prompt: String, now: Date = .now) -> String {
        let format = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        func weekday(_ date: Date) -> String { date.formatted(.dateTime.weekday(.wide).locale(Dates.locale)) }
        var parts = [Language.t("oggi", "today") + " = \(now.formatted(format)) (\(weekday(now)))"]
        let normalized = DateExpressions.normalized(prompt) as NSString
        for day in DateExpressions.days(in: prompt, now: now) {
            let text = NSMaxRange(day.range) <= normalized.length ? normalized.substring(with: day.range) : ""
            let date = "\(day.date.formatted(format)) (\(weekday(day.date)))"
            parts.append(text.isEmpty ? date : "«\(text)» = \(date)")
        }
        return Language.t("\n\nDate già calcolate: ", "\n\nDates already computed: ") + parts.joined(separator: "; ")
            + Language.t(". Nei campi di data usa queste, nel formato AAAA-MM-GG.", ". Use these in date fields, formatted YYYY-MM-DD.")
    }

    /// Argomenti senza il modello, per gli strumenti di ricerca: il campo di ricerca (o l'unico testo obbligatorio) con i nomi
    /// propri della richiesta («Bianchi Bike»), altrimenti con le sue parole significative. Nil se lo strumento vuole altro.
    static func fallbackArguments(for tool: MCPToolInfo, prompt: String) -> JSONValue? {
        let properties = tool.inputSchema["properties"]?.object ?? [:]
        let required = Set((tool.inputSchema["required"]?.array ?? []).compactMap(\.string))
        let searchKeys = ["query", "q", "search", "text", "keyword", "keywords", "term", "name"]
        guard let key = searchKeys.first(where: { properties[$0] != nil })
                ?? (required.count == 1 ? required.first.flatMap { properties[$0]?["type"]?.string == "string" ? $0 : nil } : nil),
              required.subtracting([key]).isEmpty else { return nil }
        let terms = keyTerms(prompt, excluding: tool.serverName)
        return terms.isEmpty ? nil : .object([key: .string(terms)])
    }

    /// Le parole con cui cercare: il nome proprio della richiesta, altrimenti le sue parole significative.
    static func keyTerms(_ prompt: String, excluding server: String) -> String {
        if let name = properName(prompt, excluding: server) { return name }
        let serverWords = Set(MemoryStore.normalize(server).split(separator: " ").map(String.init))
        return meaningful(prompt).subtracting(serverWords).sorted().prefix(3).joined(separator: " ")
    }

    /// Il nome proprio più lungo della richiesta («Crea un task per Verde Bio: chiamare Sara» → «Verde Bio»), senza il nome
    /// del servizio, i giorni e i mesi (in inglese hanno la maiuscola). Nil se non ce ne sono.
    static func properName(_ prompt: String, excluding server: String) -> String? {
        let serverWords = Set(MemoryStore.normalize(server).split(separator: " ").map(String.init))
        let calendar: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
                                     "march", "april", "may", "june", "july", "august", "september", "october", "november", "december", "i"]
        let words = prompt.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        var names: [[String]] = []
        var current: [String] = []
        for (index, word) in words.enumerated() {
            let key = MemoryStore.normalize(word)
            let proper = index > 0 && word.first?.isUppercase == true && !serverWords.contains(key) && !calendar.contains(key)
            if proper { current.append(word) } else if !current.isEmpty { names.append(current); current = [] }
        }
        if !current.isEmpty { names.append(current) }
        return names.max(by: { $0.count < $1.count })?.joined(separator: " ")
    }

    /// Il campo che porta gli argomenti dello strumento interno in un esecutore a catalogo: l'oggetto libero («arguments»).
    nonisolated public static func freeKey(of executor: MCPToolInfo) -> String? {
        let properties = executor.inputSchema["properties"]?.object ?? [:]
        return properties.keys.sorted().first { key in
            properties[key]?["type"]?.string == "object" && (properties[key]?["properties"]?.object?.isEmpty ?? true)
        }
    }

    /// Lo strumento interno di un servizio «a catalogo» come lo descrive la risposta di get_tool_schema (o di search_tools):
    /// nome, descrizione e schema degli argomenti. Con più strumenti vale quello chiamato `name`; nil se non c'è uno schema.
    static func internalTool(named name: String?, in raw: String, executor: MCPToolInfo) -> MCPToolInfo? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[", let value = try? JSONValue.parse(Data(trimmed.utf8)) else { return nil }
        // Lo schema può arrivare come oggetto o come testo JSON.
        func schema(_ value: JSONValue?) -> JSONValue? {
            guard let value else { return nil }
            if value["properties"]?.object != nil { return value }
            if let text = value.string, let parsed = try? JSONValue.parse(Data(text.utf8)), parsed["properties"]?.object != nil { return parsed }
            return nil
        }
        var found: [MCPToolInfo] = []
        func visit(_ value: JSONValue, depth: Int) {
            guard depth < 6 else { return }
            if let object = value.object {
                if let toolName = (object["name"] ?? object["tool_name"] ?? object["tool"])?.string,
                   let inputs = ["inputSchema", "input_schema", "parameters", "schema", "arguments_schema"].lazy.compactMap({ schema(object[$0]) }).first {
                    found.append(MCPToolInfo(serverID: executor.serverID, serverName: executor.serverName, name: toolName,
                                             description: object["description"]?.string ?? "", inputSchema: inputs))
                    return
                }
                for item in object.values { visit(item, depth: depth + 1) }
            } else if let items = value.array {
                for item in items { visit(item, depth: depth + 1) }
            }
        }
        visit(value, depth: 0)
        if let name, let match = found.first(where: { $0.name == name }) { return match }
        if found.isEmpty, let name, let inputs = schema(value) {
            return MCPToolInfo(serverID: executor.serverID, serverName: executor.serverName, name: name, description: "", inputSchema: inputs)
        }
        return found.count == 1 ? found[0] : nil
    }

    /// La chiamata che esegue lo strumento interno: il nome dallo schema letto (o scelto dal modello fra quelli trovati) e i suoi
    /// argomenti generati campo per campo sul suo schema. Scrivere a mano un oggetto JSON libero riesce male al modello piccolo:
    /// il preventivo arrivava senza cliente né importo.
    func executorCall(_ executor: MCPToolInfo, request: String, steps: [MCPStep], raw: String) async throws -> MCPCallDraft {
        let properties = executor.inputSchema["properties"]?.object ?? [:]
        let nameKey = ["tool_name", "toolName", "tool", "name"].first { properties[$0] != nil }
        let freeKey = Self.freeKey(of: executor)
        var object: [String: JSONValue]
        var inner: MCPToolInfo?
        if let nameKey, let freeKey, Set(properties.keys) == [nameKey, freeKey], let known = Self.internalTool(named: nil, in: raw, executor: executor) {
            // Lo schema letto dice già quale strumento interno usare: il modello compila solo i suoi campi.
            object = [nameKey: .string(known.name)]
            inner = known
        } else {
            let generated = try await arguments(for: executor, prompt: request, steps: steps)
            object = generated.object ?? [:]
            inner = freeKey == nil ? nil : Self.internalTool(named: nameKey.flatMap { object[$0]?.string }, in: raw, executor: executor)
            if let nameKey, let inner { object[nameKey] = .string(inner.name) }
        }
        if let inner, let freeKey {
            let values = (try? await arguments(for: inner, prompt: request, steps: steps))?.object ?? [:]
            if !values.isEmpty || object[freeKey] == nil { object[freeKey] = .object(values) }
        }
        return MCPCallDraft(tool: executor, arguments: .object(object), request: request, steps: steps, inner: inner)
    }

    /// Argomenti corretti dopo il rifiuto del server; per uno strumento interno si ricompilano i suoi campi.
    func correctedArguments(_ draft: MCPCallDraft, error: String) async throws -> JSONValue {
        let request = draft.request ?? "", steps = draft.steps ?? []
        guard let inner = draft.inner, let freeKey = Self.freeKey(of: draft.tool), case .object(var object) = draft.arguments else {
            return try await arguments(for: draft.tool, prompt: request, steps: steps, failure: (draft.arguments, error))
        }
        object[freeKey] = try await arguments(for: inner, prompt: request, steps: steps, failure: (object[freeKey] ?? .object([:]), error))
        return .object(object)
    }

    /// Il risultato di una ricerca di strumenti descrive già i loro argomenti (niente bisogno di chiedere lo schema).
    static func containsSchema(_ result: String) -> Bool {
        ["inputSchema", "input_schema", "\"parameters\"", "parameters:", "inputschema", "\"properties\"", "properties:"].contains(where: result.contains)
    }

    /// Argomenti con generazione guidata sullo schema JSON dello strumento, usando anche i risultati precedenti.
    /// `failure`: la chiamata appena fallita (argomenti e messaggio del server), per correggerla.
    func arguments(for tool: MCPToolInfo, prompt: String, steps: [MCPStep], failure: (arguments: JSONValue, error: String)? = nil) async throws -> JSONValue {
        let properties = tool.inputSchema["properties"]?.object ?? [:]
        guard !properties.isEmpty else { return .object([:]) }
        let schema = try JSONSchemaBridge.generationSchema(for: tool)
        let session = LanguageModelSession(model: Agent.model, instructions: Language.isEnglish ? """
        Fill in the arguments of the «\(tool.name)» tool: \(tool.description.prefix(400))
        \(serverGuide(tool.serverName))Use the information in the request and in the previous results (names, ids). \
        In search fields (query) put only 1-3 essential keywords, for example the name to look for («Mainstream») or the topic («customers»), never a sentence.\(languageHint(tool)) \
        Free-form object fields must be written as valid JSON, for example {"limit": 20}. Leave optional fields you don't need empty.
        """ : """
        Compila gli argomenti dello strumento «\(tool.name)»: \(tool.description.prefix(400))
        \(serverGuide(tool.serverName))Usa le informazioni della richiesta e dei risultati precedenti (nomi, id). \
        Nei campi di ricerca (query) metti solo 1-3 parole chiave essenziali, per esempio il nome da cercare («Mainstream») o l'argomento («clienti»), mai una frase.\(languageHint(tool)) \
        I campi di tipo oggetto libero vanno scritti come JSON valido, per esempio {"limit": 20}. Lascia vuoti i campi facoltativi che non servono.
        """)
        let retry = failure.map { failed in
            Language.t("\n\nLa chiamata con \(failed.arguments.compactString.prefix(300)) è fallita: «\(failed.error.prefix(300))». Correggi gli argomenti seguendo il messaggio.",
                       "\n\nThe call with \(failed.arguments.compactString.prefix(300)) failed: «\(failed.error.prefix(300))». Fix the arguments following the message.")
        } ?? ""
        let dates = Self.wantsDates(tool) ? Self.connectorDates(prompt) : ""
        let content = try await session.respond(to: Language.t("Richiesta: ", "Request: ") + withContext(prompt) + dates + Self.describe(steps) + retry,
                                                schema: schema).content
        let value = JSONSchemaBridge.json(from: content, schema: tool.inputSchema)
        let evidence = prompt + " " + steps.map { $0.arguments + " " + $0.result }.joined(separator: " ") + " " + (failure?.error ?? "")
        let kept = Self.dropInvented(value, schema: tool.inputSchema, evidence: evidence)
        let cleaned = Self.withoutServiceValues(Self.cleanedSearch(kept, server: tool.serverName, prompt: prompt), schema: tool.inputSchema, server: tool.serverName)
        return tool.isReadOnly ? cleaned : Self.cleanedTexts(cleaned, tool: tool)
    }

    /// Il nome del servizio non è un valore da filtrare («client: Demo OS» per «le fatture su Demo OS» non trovava niente):
    /// i campi facoltativi che contengono solo quello si tolgono.
    static func withoutServiceValues(_ value: JSONValue, schema: JSONValue, server: String) -> JSONValue {
        guard case .object(var object) = value else { return value }
        let required = Set((schema["required"]?.array ?? []).compactMap(\.string))
        let serverWords = Set(MemoryStore.normalize(server).split(separator: " ").map(String.init))
        for (key, item) in object where !required.contains(key) {
            guard case .string(let text) = item else { continue }
            let words = Set(MemoryStore.normalize(text).split(separator: " ").map(String.init))
            if !words.isEmpty, words.isSubset(of: serverWords) { object.removeValue(forKey: key) }
        }
        return .object(object)
    }

    /// I testi di ciò che si crea: senza la descrizione dello strumento copiata dal modello, titoli su una riga e senza
    /// il nome del servizio («chiamare Sara venerdì demo crm» → «chiamare Sara venerdì»).
    static func cleanedTexts(_ value: JSONValue, tool: MCPToolInfo) -> JSONValue {
        guard case .object(var object) = value else { return value }
        let titleKeys: Set<String> = ["title", "name", "subject", "summary", "titolo", "nome", "oggetto"]
        let description = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
        for (key, item) in object {
            guard case .string(var text) = item else { continue }
            if description.count >= 20 { text = text.replacingOccurrences(of: description, with: " ") }
            if titleKeys.contains(key.lowercased()) {
                text = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                text = text.replacingOccurrences(of: tool.serverName, with: " ", options: .caseInsensitive)
            }
            text = text.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { object[key] = .string(text) }
        }
        return .object(object)
    }

    /// Lo strumento ha campi di data («due», «start_date», «deadline», formato date): solo allora riceve le date già calcolate,
    /// che altrimenti finiscono nelle parole di ricerca («Bianchi Bike 2026-09-27»).
    static func wantsDates(_ tool: MCPToolInfo) -> Bool {
        let words: Set<String> = ["date", "dates", "due", "deadline", "day", "days", "start", "end", "until", "since", "before", "after",
                                  "when", "time", "datetime", "timestamp", "scadenza", "data", "giorno", "giorni", "inizio", "fine"]
        return (tool.inputSchema["properties"]?.object ?? [:]).contains { key, value in
            MCPToolInfo.nameWords(key).contains(where: words.contains) || (value["format"]?.string ?? "").hasPrefix("date")
        }
    }

    /// La lingua dei campi: le parole di ricerca in quella del servizio; titoli e testi di ciò che si crea in quella della richiesta.
    func languageHint(_ tool: MCPToolInfo) -> String {
        guard !tool.isReadOnly else { return searchLanguageHint(tool) }
        return Language.t(" Nei campi di testo scrivi in italiano solo ciò che l'utente vuole creare, con le sue parole (per esempio il titolo «Inviare il listino»): niente spiegazioni né nome del servizio; date e id vanno nei loro campi.",
                          " In text fields write only what the user wants to create, in their words (for example the title «Send the price list»): no explanations or service name; dates and ids go in their own fields.")
    }

    /// Nelle parole di ricerca non servono il nome del servizio («overdue tasks demo crm» → «overdue tasks») né le date
    /// che l'utente non ha scritto così («Bianchi Bike 2026-09-27» → «Bianchi Bike»).
    static func cleanedSearch(_ value: JSONValue, server: String, prompt: String = "") -> JSONValue {
        guard case .object(var object) = value else { return value }
        let searchKeys: Set<String> = ["query", "q", "search", "text", "keyword", "keywords", "term"]
        for (key, item) in object where searchKeys.contains(key.lowercased()) {
            guard case .string(let text) = item else { continue }
            var cleaned = text.replacingOccurrences(of: server, with: " ", options: .caseInsensitive)
            for word in server.split(separator: " ") where word.count >= 2 {
                cleaned = cleaned.replacingOccurrences(of: #"(?i)\b\#(NSRegularExpression.escapedPattern(for: String(word)))\b"#, with: " ", options: .regularExpression)
            }
            if let regex = try? NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#) {
                for match in regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)).reversed() {
                    guard let range = Range(match.range, in: cleaned), !prompt.contains(cleaned[range]) else { continue }
                    cleaned.replaceSubrange(range, with: " ")
                }
            }
            cleaned = cleaned.split(separator: " ").joined(separator: " ")
            if !cleaned.isEmpty { object[key] = .string(cleaned) }
        }
        return .object(object)
    }

    // MARK: - Giro sui connettori

    /// Esegue la chiamata e quelle che servono dopo: le letture partono da sole (`freely`), una chiamata che scrive si ferma
    /// come scheda da confermare (`confirmed`: la prima l'ha appena confermata l'utente). Se il server rifiuta gli argomenti,
    /// il modello li corregge leggendo il messaggio e si riprova una volta; poi si risponde con quello che si è ottenuto.
    public func runConnector(_ draft: MCPCallDraft, confirmed: Bool,
                             freely: (MCPToolInfo) -> Bool,
                             call: (MCPToolInfo, JSONValue) async throws -> String,
                             onEvent: (ConnectorEvent) async -> Void = { _ in },
                             status: @escaping @MainActor (String) -> Void = { _ in }) async -> ConnectorRun {
        var current = draft
        var approved = confirmed
        var retried = false
        while true {
            if !approved, !freely(current.tool) {
                return ConnectorRun(steps: current.steps ?? [], pending: current, answerPrompt: nil)
            }
            // Una scrittura consentita per sempre, dopo aver letto contenuti di terzi in questo giro: se sembrano contenere
            // istruzioni per un assistente, torna una scheda da confermare (rizzo-flow può solo aggiungere cautela).
            if !approved, !current.tool.isReadOnly, let steps = current.steps, !steps.isEmpty,
               await Self.looksLikeInjection(steps.map(\.result).joined(separator: "\n")) {
                Agent.log("CONNETTORE: istruzioni sospette nei risultati letti, «\(current.tool.name)» torna da confermare")
                return ConnectorRun(steps: steps, pending: current, answerPrompt: nil)
            }
            approved = false
            await onEvent(.calling(current))
            status(Language.t("Chiedo a \(current.tool.serverName)…", "Asking \(current.tool.serverName)…"))
            let started = Date.now
            let detail = String(current.arguments.compactString.prefix(120))
            do {
                let raw = try await call(current.tool, current.arguments)
                let milliseconds = Int(Date.now.timeIntervalSince(started) * 1000)
                Agent.log("CONNETTORE: \(current.tool.serverName) · \(current.tool.name) \(detail) → \(raw.count) caratteri in \(milliseconds) ms")
                trace?.steps.append(TraceStep(action: "mcp: " + current.displayName, detail: detail, result: ConnectorResult.summary(raw),
                                              milliseconds: milliseconds, ok: true))
                await onEvent(.finished(current, result: raw))
                let readable = ConnectorResult.readable(raw, limit: budget.scaled(2400))
                status(Language.t("Valuto il risultato…", "Reviewing the result…"))
                if let next = await nextMCPStep(after: current, result: readable, raw: raw) {
                    current = next
                    retried = false
                    continue
                }
                let steps = (current.steps ?? []) + [MCPStep(tool: current.tool.name, arguments: current.arguments.compactString, result: readable)]
                return ConnectorRun(steps: steps, pending: nil, answerPrompt: mcpAnswerPrompt(request: current.request ?? "", steps: steps))
            } catch {
                let message = error.localizedDescription
                let milliseconds = Int(Date.now.timeIntervalSince(started) * 1000)
                Agent.log("CONNETTORE ERRORE: \(current.tool.serverName) · \(current.tool.name) \(detail) → \(message.prefix(200))")
                trace?.steps.append(TraceStep(action: "mcp: " + current.displayName, detail: detail, result: String(message.prefix(120)),
                                              milliseconds: milliseconds, ok: false))
                await onEvent(.failed(current, error: message))
                if !retried, Self.canRetry(error), let fixed = try? await correctedArguments(current, error: message), fixed != current.arguments {
                    retried = true
                    // Una lettura si riprova subito; una scrittura corretta torna da confermare.
                    current = MCPCallDraft(tool: current.tool, arguments: fixed, request: current.request, steps: current.steps, inner: current.inner)
                    continue
                }
                let steps = (current.steps ?? []) + [MCPStep(tool: current.tool.name, arguments: current.arguments.compactString,
                                                             result: Language.t("Errore: ", "Error: ") + message)]
                return ConnectorRun(steps: steps, pending: nil, answerPrompt: mcpAnswerPrompt(request: current.request ?? "", steps: steps))
            }
        }
    }

    /// Errori del server sugli argomenti (si possono correggere); non rete, tempi scaduti o accesso.
    static func canRetry(_ error: Error) -> Bool {
        guard case MCPError.server(let message) = error else { return false }
        return !message.hasPrefix("HTTP 5") && !message.lowercased().contains("accesso") && !message.lowercased().contains("sign")
    }

    /// I valori ammessi di un campo: l'enum dello schema e le parole tra virgolette nella sua descrizione («'open' or 'done'»).
    static func schemaOptions(_ property: JSONValue?) -> Set<String> {
        guard let property else { return [] }
        var options = Set((property["enum"]?.array ?? []).compactMap { $0.string?.lowercased() })
        if let description = property["description"]?.string,
           let regex = try? NSRegularExpression(pattern: #"['"‘“«]([A-Za-z0-9_\- ]{1,30})['"’”»]"#) {
            for match in regex.matches(in: description, range: NSRange(description.startIndex..., in: description)) {
                if let range = Range(match.range(at: 1), in: description) { options.insert(description[range].lowercased()) }
            }
        }
        return options
    }

    /// Toglie i campi facoltativi di testo il cui valore non compare né nella richiesta né nei risultati (id inventati, filtri a caso).
    static func dropInvented(_ value: JSONValue, schema: JSONValue, evidence: String) -> JSONValue {
        guard case .object(var object) = value else { return value }
        let required = Set((schema["required"]?.array ?? []).compactMap(\.string))
        let properties = schema["properties"]?.object ?? [:]
        let haystack = evidence.lowercased()
        let normalized = MemoryStore.normalize(evidence)
        // Una parola è "presente" anche al plurale o con un'altra desinenza (confronto sulla radice, senza accenti).
        func present(_ word: String) -> Bool { normalized.contains(word.count >= 6 ? String(word.prefix(word.count - 2)) : word) }
        func supports(_ text: String) -> Bool {
            let words = MemoryStore.keywords(text)
            return haystack.contains(text.lowercased()) || normalized.contains(MemoryStore.normalize(text)) || (!words.isEmpty && words.allSatisfy(present))
        }
        for (key, item) in object where !required.contains(key) {
            switch item {
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                // Un valore che lo schema prevede («open» o «done», un enum) non è inventato: è la traduzione della richiesta.
                if !trimmed.isEmpty, schemaOptions(properties[key]).contains(trimmed.lowercased()) { continue }
                // Un id copiato tale e quale dalla richiesta o da un risultato (client_id «C-103» trovato con la ricerca) è vero.
                if trimmed.count >= 2, key.lowercased().hasSuffix("id"), haystack.contains(trimmed.lowercased()) { continue }
                let supported = supports(trimmed)
                // Filtri facoltativi (toolset, agency_id, categoria…) solo se l'utente o un risultato li nomina davvero.
                let searchKey = ["query", "q", "search", "text", "name", "title", "term", "keyword", "keywords", "prompt"].contains(key.lowercased())
                let keyMentioned = haystack.contains(key.lowercased().replacingOccurrences(of: "_", with: " ")) || haystack.contains("\"\(key.lowercased())\"")
                if trimmed.isEmpty || !supported || !(searchKey || keyMentioned) { object.removeValue(forKey: key) }
            case .null:
                object.removeValue(forKey: key)
            case .object(let inner) where inner.isEmpty:
                object.removeValue(forKey: key)
            case .array(let items) where items.isEmpty:
                object.removeValue(forKey: key)
            default:
                // I numeri facoltativi con un valore predefinito nello schema si lasciano al server.
                if properties[key]?["default"] != nil, case .number = item { object.removeValue(forKey: key) }
            }
        }
        // Oggetti liberi (es. "arguments" di execute_read_tool): stessi controlli sui valori di testo.
        for (key, item) in object {
            guard case .object(let inner) = item, properties[key]?["properties"]?.object?.isEmpty ?? true else { continue }
            var cleaned = inner
            for (innerKey, innerValue) in inner {
                guard case .string(let text) = innerValue else { continue }
                let supported = supports(text)
                if text.isEmpty || !supported || (innerKey.hasSuffix("_id") && !haystack.contains(text.lowercased())) {
                    cleaned.removeValue(forKey: innerKey)
                }
            }
            object[key] = .object(cleaned)
        }
        return .object(object)
    }
}
