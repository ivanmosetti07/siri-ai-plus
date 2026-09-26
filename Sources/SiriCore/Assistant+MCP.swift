import Foundation
import FoundationModels

extension Assistant {
    // MARK: - Connettori MCP

    /// Nome del server collegato citato nella richiesta ("agency os", "@notion").
    func namedServer(_ lower: String) -> String? {
        let servers = Set(work.mcpTools.map(\.serverName))
        return servers.sorted { $0.count > $1.count }.first { name in
            let key = name.lowercased()
            let compact = key.replacingOccurrences(of: " ", with: "")
            return lower.contains(key) || lower.contains("@" + compact) || (compact.count >= 5 && lower.replacingOccurrences(of: " ", with: "").contains(compact))
        }
    }

    /// Parole troppo comuni per indicare un servizio ("come", "quali", "tool"…).
    static let stopwords: Set<String> = [
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

    /// Server i cui strumenti condividono almeno due parole significative con la richiesta.
    func strongServerMatch(_ lower: String) -> String? {
        let words = Self.meaningful(lower)
        var scores: [String: Int] = [:]
        for tool in work.mcpTools {
            let text = tool.name.replacingOccurrences(of: "_", with: " ") + " " + tool.description.prefix(200)
            scores[tool.serverName, default: 0] += words.intersection(Self.meaningful(text)).count
        }
        // Solo nomi e descrizioni degli strumenti: le istruzioni scritte dal server non possono farlo scegliere.
        return scores.filter { $0.value >= 2 }.max { $0.value < $1.value }?.key
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
        return Self.untrusted(String(text.prefix(700)), label: "guida del servizio \(server)") + "\n"
    }

    /// Prima chiamata: lo strumento viene scelto con una generazione dedicata, solo fra quelli del servizio.
    func firstMCPCall(_ plan: Plan, prompt: String, status: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        let server = plan["server"] ?? work.mcpTools.first { $0.name == plan["strumento"] }?.serverName
        let candidates = tools(of: server)
        guard !candidates.isEmpty else { return .message("Nessun connettore attivo: controlla in Connettori.") }
        status("Scelgo lo strumento di \(server ?? "connettore")…")
        let lower = prompt.lowercased()
        var tool = candidates.first { lower.contains($0.name.lowercased()) }
        // Servizi "a catalogo": per elenchi e dati strutturati si parte cercando lo strumento interno giusto.
        let listing = ["quali", "quanti", "elenca", "lista", "elenco", "tutti", "tutte", "miei", "mie", "ultim", "recent", "in scadenza",
                       "aperti", "aperte", "di oggi", "della settimana", "stato", "riepilogo", "panoramica"].contains(where: lower.contains)
        if tool == nil, listing, let catalog = candidates.first(where: { $0.name == "search_tools" }),
           candidates.contains(where: { $0.name == "execute_read_tool" }) {
            tool = catalog
        }
        if tool == nil { tool = await chooseTool(prompt: prompt, among: candidates, server: server, steps: []) }
        if tool == nil { tool = candidates.first { $0.name == plan["strumento"] } }
        guard let tool else { return .message("Non ho capito quale strumento di \(server ?? "connettore") usare.") }
        status("Preparo \(tool.name)…")
        let arguments = try await arguments(for: tool, prompt: prompt, steps: [])
        return .mcpCall(MCPCallDraft(tool: tool, arguments: arguments, request: prompt, steps: []))
    }

    private static func toolChoiceSchema(_ names: [String], allowStop: Bool) -> GenerationSchema {
        var fields: [Field] = []
        if allowStop {
            fields.append(.required("azione", .choice(["rispondi", "chiama"]), "rispondi se i risultati bastano per rispondere, chiama se serve un altro strumento"))
        }
        fields.append(.required("strumento", .choice(names), "Strumento da usare"))
        return makeSchema("SceltaStrumento", fields)
    }

    func chooseTool(prompt: String, among tools: [MCPToolInfo], server: String?, steps: [MCPStep]) async -> MCPToolInfo? {
        if tools.count == 1 { return tools[0] }
        let session = LanguageModelSession(model: Agent.model, instructions: """
        Scegli lo strumento più adatto per soddisfare la richiesta dell'utente.
        \(serverGuide(server))Strumenti disponibili:
        \(toolCatalog(tools))
        Preferisci strumenti di ricerca o lettura; per i servizi "a catalogo" usa prima lo strumento che cerca gli strumenti interni e poi quello che li esegue.
        """)
        let request = "Richiesta: \(prompt)" + Self.describe(steps)
        guard let content = try? await session.respond(to: request, schema: Self.toolChoiceSchema(tools.map(\.name), allowStop: false),
                                                       options: GenerationOptions(samplingMode: .greedy)).content,
              let name = content.string("strumento") else { return nil }
        return tools.first { $0.name == name }
    }

    /// Dopo un risultato: serve un'altra chiamata (es. cercare lo strumento interno e poi eseguirlo) o si può rispondere?
    public func nextMCPStep(after draft: MCPCallDraft, result: String) async -> MCPCallDraft? {
        let steps = (draft.steps ?? []) + [MCPStep(tool: draft.tool.name, arguments: draft.arguments.compactString, result: String(result.prefix(1500)))]
        mcpCalls += 1
        guard steps.count < 4, !result.isEmpty, mcpCalls < RequestLimits.mcpCalls else { return nil }
        let request = draft.request ?? ""
        let server = draft.tool.serverName
        let candidates = tools(of: server)
        // Dopo aver trovato gli strumenti interni si esegue quello di lettura.
        if draft.tool.name == "search_tools", let executor = candidates.first(where: { $0.name == "execute_read_tool" }),
           result.count > 20, !result.contains("\"results\":[]"), !result.contains("\"tools\":[]") {
            guard let arguments = try? await arguments(for: executor, prompt: request, steps: steps) else { return nil }
            return MCPCallDraft(tool: executor, arguments: arguments, request: request, steps: steps)
        }
        let session = LanguageModelSession(model: Agent.model, instructions: """
        Stai usando gli strumenti del servizio \(server) per soddisfare una richiesta. Decidi se i risultati ottenuti bastano (rispondi) \
        o se serve chiamare un altro strumento (chiama), per esempio per eseguire uno strumento trovato con una ricerca o leggere il dettaglio di un elemento.
        \(serverGuide(server))Strumenti:
        \(toolCatalog(candidates))
        """)
        guard let content = try? await session.respond(to: "Richiesta: \(request)" + Self.describe(steps),
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
            blocks.append("Risultato di \(step.tool) \(step.arguments.prefix(160)):\n\(step.result.prefix(share))")
        }
        remember("Risultati dei connettori per «\(request)»:\n" + (steps.last.map { String($0.result.prefix(700)) } ?? ""))
        return grounded(request, blocks.joined(separator: "\n\n"), label: "risultati dei connettori")
    }

    static func describe(_ steps: [MCPStep]) -> String {
        guard !steps.isEmpty else { return "" }
        return "\n\nChiamate già fatte:\n" + untrusted(steps.enumerated().map { index, step in
            "\(index + 1). \(step.tool) \(step.arguments.prefix(200)) → \(step.result.prefix(index == steps.count - 1 ? 1200 : 400))"
        }.joined(separator: "\n"), label: "risultati dei connettori")
    }

    /// Argomenti con generazione guidata sullo schema JSON dello strumento, usando anche i risultati precedenti.
    func arguments(for tool: MCPToolInfo, prompt: String, steps: [MCPStep]) async throws -> JSONValue {
        let properties = tool.inputSchema["properties"]?.object ?? [:]
        guard !properties.isEmpty else { return .object([:]) }
        let schema = try JSONSchemaBridge.generationSchema(for: tool)
        let session = LanguageModelSession(model: Agent.model, instructions: """
        Compila gli argomenti dello strumento «\(tool.name)»: \(tool.description.prefix(400))
        \(serverGuide(tool.serverName))Usa le informazioni della richiesta e dei risultati precedenti (nomi, id). \
        Nei campi di ricerca (query) metti solo 1-3 parole chiave essenziali, per esempio il nome da cercare («Mainstream») o l'argomento («clienti»), mai una frase. \
        I campi di tipo oggetto libero vanno scritti come JSON valido, per esempio {"limit": 20}. Lascia vuoti i campi facoltativi che non servono.
        """)
        let content = try await session.respond(to: "Richiesta: \(withContext(prompt))" + Self.describe(steps), schema: schema).content
        let value = JSONSchemaBridge.json(from: content, schema: tool.inputSchema)
        return Self.dropInvented(value, schema: tool.inputSchema, evidence: prompt + " " + steps.map { $0.arguments + " " + $0.result }.joined(separator: " "))
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
