import Foundation
import FoundationModels

// MARK: - Agente di coding con un modello sul Mac
//
// Per provare la Programmazione con Apple Intelligence, Gemma o ds4: l'app dà al modello gli strumenti per esplorare
// e cambiare il progetto (elenca, leggi, cerca, scrivi, modifica, esegui) e fa girare il ciclo chiamata → risultato.
// I comandi girano in un recinto: scrittura solo nella cartella del progetto (e nelle cartelle temporanee), niente rete.

public enum LocalCodeAgent {
    /// Il modello sul Mac: Apple Intelligence (FoundationModels) o un server compatibile OpenAI (Gemma con llama.cpp, ds4).
    public enum Model: Sendable {
        case apple
        /// `thinking`: Gemma 4 ragiona prima di ogni passo (il ragionamento compare a parte nella chat).
        case openAI(base: URL, name: String, label: String, contextTokens: Int, thinking: Bool)

        var label: String {
            switch self {
            case .apple: "Apple Intelligence"
            case .openAI(_, _, let label, _, _): label
            }
        }
    }

    /// - Parameter checkPage: apre una pagina del progetto in un browser nascosto e restituisce gli errori della console
    ///   (lo dà l'app: senza, l'agente non ha lo strumento `controlla_pagina`).
    public static func run(model: Model, mode: CodeMode, folder: URL, prompt: String, history: [ChatTurn],
                           checkPage: CodeAgent.PageChecker? = nil,
                           onEvent: @escaping @Sendable (CodeEvent) -> Void) async -> CodeAgent.Outcome {
        let compact: Bool = if case .apple = model { true } else { false }
        let toolbox = CodeToolbox(folder: folder, mode: mode, compact: compact, checkPage: checkPage, onEvent: onEvent)
        let system = instructions(folder: folder, mode: mode, compact: compact, checksPages: toolbox.checksPages)
        switch model {
        case .apple:
            return await appleLoop(system: system, history: history, prompt: prompt, toolbox: toolbox, onEvent: onEvent)
        case .openAI(let base, let name, let label, let contextTokens, let thinking):
            return await openAILoop(base: base, name: name, label: label, contextTokens: contextTokens, thinking: thinking, system: system,
                                    history: history, prompt: prompt, toolbox: toolbox, onEvent: onEvent)
        }
    }

    /// Istruzioni dell'agente, con le regole del progetto (AGENTS.md) se ci sono.
    static func instructions(folder: URL, mode: CodeMode, compact: Bool, checksPages: Bool = false) -> String {
        var text = """
        Sei l'agente di programmazione di Siri AI+ e lavori nel progetto «\(folder.lastPathComponent)». Adesso è \(Dates.format(.now)).
        Usa gli strumenti per capire il codice: elenca_file, leggi_file e cerca. I percorsi sono relativi alla cartella del progetto.
        """
        if mode == .edit {
            text += """

            Per cambiare un file esistente usa modifica_file (sostituisce un pezzo di testo esatto, copiato da leggi_file); \
            per i file nuovi, o da riscrivere del tutto, usa scrivi_file. Con esegui_comando lanci build, test e comandi del progetto \
            (scrivono solo nella cartella del progetto e non hanno internet).
            Leggi un file prima di modificarlo, fai modifiche piccole e precise, e se c'è un comando di verifica eseguilo dopo le modifiche.
            I file si creano e si cambiano solo chiamando gli strumenti: scrivere il codice nella risposta non cambia nulla.
            Lavora da solo fino alla fine: non chiedere il permesso di leggere o cambiare i file del progetto, fallo. \
            Se ti dicono che qualcosa non funziona, leggi i file coinvolti, trova la causa, correggila e verifica.
            """
            if checksPages {
                text += "\nPer i siti: dopo le modifiche apri la pagina con controlla_pagina (di solito index.html) e correggi gli errori che trova, finché non ce ne sono più."
            }
        } else {
            text += "\nModalità «chiedi prima»: non modificare nulla. Studia il progetto e proponi un piano chiaro, a punti, con i file da toccare."
        }
        text += "\nNon inventare file, codice o risultati che gli strumenti non hanno restituito. Alla fine rispondi in italiano con un breve riepilogo di cosa hai fatto."
        let agents = folder.appending(path: "AGENTS.md")
        if let rules = try? String(contentsOf: agents, encoding: .utf8), !rules.isEmpty {
            text += "\n\nRegole del progetto (AGENTS.md):\n" + String(rules.prefix(compact ? 700 : 5000))
        }
        return text
    }

    /// La richiesta chiede di cambiare il progetto (non solo di spiegarlo).
    static func asksForChanges(_ prompt: String) -> Bool {
        prompt.lowercased().range(of: #"\b(?:crea|creare|aggiungi|modifica|cambia|sistema|correggi|scrivi|rendi|metti|togli|rimuovi|elimina|implementa|costruisci|fai|sostituisci|traduci|aggiorna|sposta|rinomina)\b"#,
                                  options: .regularExpression) != nil
    }

    /// Il modello ha risposto senza toccare nessun file, ma la richiesta chiedeva di cambiarli: glielo si chiede di nuovo.
    static let nudge = "Non hai ancora creato né modificato nessun file: descrivere il lavoro non basta. Fallo adesso con gli strumenti, un file alla volta (scrivi_file per i file nuovi, modifica_file per quelli esistenti), poi rispondi con il riepilogo."

    // MARK: Gemma e ds4 (tool calling OpenAI)

    static func openAILoop(base: URL, name: String, label: String, contextTokens: Int, thinking: Bool = false, system: String, history: [ChatTurn],
                           prompt: String, toolbox: CodeToolbox, onEvent: @escaping @Sendable (CodeEvent) -> Void) async -> CodeAgent.Outcome {
        // Circa 3 caratteri per token; si lascia spazio alla risposta.
        let budget = contextTokens * 3 * 6 / 10
        let past = fitting(history, characters: budget / 4)
        var messages = ExternalEngine.messages(system: system, history: past, prompt: prompt).array ?? []
        let tools = toolbox.specs.map(\.openAI)
        let maxRounds = 40
        let wantsChanges = toolbox.mode == .edit && asksForChanges(prompt)
        var nudges = 0
        for round in 0..<maxRounds {
            if Task.isCancelled { return CodeAgent.Outcome(ok: false, error: "Richiesta interrotta.") }
            compact(&messages, characters: budget)
            var body: [String: JSONValue] = ["model": .string(name), "stream": .bool(true), "messages": .array(messages), "temperature": .number(0.2)]
            if round < maxRounds - 1 { body["tools"] = .array(tools) }
            if thinking { body["chat_template_kwargs"] = ExternalEngine.thinkingOption }
            var request = URLRequest(url: base.appending(path: "v1/chat/completions"), timeoutInterval: 900)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var text = ""
            var reasoning = ""
            var calls: [Int: (id: String, name: String, arguments: String)] = [:]
            let key = "testo-\(UUID().uuidString)"
            let thought = "ragionamento-\(UUID().uuidString)"
            do {
                request.httpBody = try JSONValue.object(body).data()
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    var detail = ""
                    for try await line in bytes.lines { detail += line; if detail.count > 400 { break } }
                    // Finestra piena: si accorcia la cronologia e si riprova una volta.
                    if detail.lowercased().contains("context"), round < maxRounds - 1 {
                        compact(&messages, characters: budget / 2)
                        continue
                    }
                    return CodeAgent.Outcome(ok: false, error: "\(label) non risponde: \(detail.prefix(200))")
                }
                var lastSent = 0
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let json = try? JSONValue.parse(Data(payload.utf8)), let delta = json["choices"]?.array?.first?["delta"] else { continue }
                    if let piece = delta["reasoning_content"]?.string, !piece.isEmpty {
                        if reasoning.isEmpty { onEvent(CodeEvent(key: thought, kind: .thinking, text: "…")) }
                        reasoning += piece
                    }
                    if let piece = delta["content"]?.string, !piece.isEmpty {
                        text += piece
                        // Il testo compare mentre arriva, senza aggiornare la chat a ogni lettera.
                        if text.count - lastSent > 80 {
                            lastSent = text.count
                            onEvent(CodeEvent(key: key, kind: .text, text: text))
                        }
                    }
                    for item in delta["tool_calls"]?.array ?? [] {
                        let index = Int(item["index"]?.number ?? Double(calls.count))
                        var current = calls[index] ?? (id: "", name: "", arguments: "")
                        if let id = item["id"]?.string { current.id = id }
                        if let name = item["function"]?["name"]?.string { current.name += name }
                        if let arguments = item["function"]?["arguments"]?.string { current.arguments += arguments }
                        calls[index] = current
                    }
                }
            } catch {
                if Task.isCancelled { return CodeAgent.Outcome(ok: false, error: "Richiesta interrotta.") }
                return CodeAgent.Outcome(ok: false, error: (error as? URLError) != nil
                                         ? "\(label) non è in esecuzione: avvialo in Impostazioni › Modelli." : error.localizedDescription)
            }
            // Modelli piccoli: a volte scrivono la chiamata come testo.
            if calls.isEmpty, let parsed = ExternalAgent.textualToolCalls(in: text, known: Set(toolbox.specs.map(\.name))), !parsed.calls.isEmpty {
                text = parsed.before
                for (index, call) in parsed.calls.enumerated() { calls[index] = (id: "", name: call.name, arguments: call.arguments) }
            }
            if !reasoning.isEmpty { onEvent(CodeEvent(key: thought, kind: .thinking, text: reasoning.trimmingCharacters(in: .whitespacesAndNewlines))) }
            let visible = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if calls.isEmpty, wantsChanges, toolbox.changes == 0, nudges < 2 {
                nudges += 1
                onEvent(CodeEvent(key: key, kind: .thinking, text: visible.isEmpty ? "Nessun file cambiato: chiedo di fare il lavoro con gli strumenti." : visible))
                messages.append(.object(["role": .string("assistant"), "content": .string(text)]))
                messages.append(.object(["role": .string("user"), "content": .string(nudge)]))
                continue
            }
            if !visible.isEmpty { onEvent(CodeEvent(key: key, kind: .text, text: visible)) }
            guard !calls.isEmpty else { return CodeAgent.Outcome(ok: true) }
            let ordered = calls.sorted { $0.key < $1.key }.map(\.value)
            messages.append(.object([
                "role": .string("assistant"), "content": text.isEmpty ? .null : .string(text),
                "tool_calls": .array(ordered.enumerated().map { index, call in
                    .object(["id": .string(call.id.isEmpty ? "call_\(round)_\(index)" : call.id), "type": .string("function"),
                             "function": .object(["name": .string(call.name), "arguments": .string(call.arguments.isEmpty ? "{}" : call.arguments)])])
                }),
            ]))
            for (index, call) in ordered.enumerated() {
                let arguments = CodeToolbox.arguments(from: (try? JSONValue.parse(Data(call.arguments.utf8))) ?? .object([:]))
                let result = await toolbox.run(call.name, arguments)
                messages.append(.object(["role": .string("tool"), "tool_call_id": .string(call.id.isEmpty ? "call_\(round)_\(index)" : call.id),
                                         "content": .string(result)]))
            }
        }
        onEvent(CodeEvent(kind: .text, text: "Mi sono fermato dopo \(maxRounds) passaggi: scrivimi se devo continuare."))
        return CodeAgent.Outcome(ok: true)
    }

    /// Tiene la conversazione nella finestra: i risultati più vecchi degli strumenti lasciano il posto a una nota.
    static func compact(_ messages: inout [JSONValue], characters: Int) {
        func size(_ list: [JSONValue]) -> Int { list.reduce(0) { $0 + ($1["content"]?.string?.count ?? 0) + ($1["tool_calls"].map { $0.compactString.count } ?? 0) } }
        var total = size(messages)
        guard total > characters else { return }
        // Istruzioni e ultimi scambi restano interi.
        for index in messages.indices.dropFirst().dropLast(4) where total > characters {
            guard let content = messages[index]["content"]?.string, content.count > 300, var object = messages[index].object else { continue }
            let note = messages[index]["role"]?.string == "tool" ? "[risultato già letto, tolto per fare spazio: se serve, richiama lo strumento]" : String(content.prefix(300)) + "…"
            object["content"] = .string(note)
            messages[index] = .object(object)
            total -= content.count - note.count
        }
    }

    // MARK: Apple Intelligence (FoundationModels)

    static func appleLoop(system: String, history: [ChatTurn], prompt: String, toolbox: CodeToolbox,
                          onEvent: @escaping @Sendable (CodeEvent) -> Void) async -> CodeAgent.Outcome {
        let tools: [any Tool] = toolbox.specs.map { spec in
            AppleCodeTool(name: spec.name, description: spec.description, parameters: CodeToolbox.appleSchema(for: spec)) { content in
                await toolbox.run(spec.name, CodeToolbox.arguments(from: content, fields: CodeToolbox.fields(of: spec)))
            }
        }
        // La finestra di Apple Intelligence è piccola: dell'ultimo scambio solo l'essenziale.
        var request = prompt
        if let last = history.last(where: { $0.role == .assistant }) {
            request = "Prima hai risposto: «\(last.text.prefix(500))»\n\nNuova richiesta: \(prompt)"
        }
        let wantsChanges = toolbox.mode == .edit && asksForChanges(prompt)
        var session = LanguageModelSession(model: Agent.model, tools: tools, instructions: system)
        var restarts = 0
        var nudges = 0
        while !Task.isCancelled {
            do {
                let response = try await session.respond(to: request, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 1500))
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if wantsChanges, toolbox.changes == 0, nudges < 2 {
                    // Ha descritto il lavoro senza farlo: si continua nella stessa sessione, con la richiesta di usare gli strumenti.
                    nudges += 1
                    onEvent(CodeEvent(kind: .thinking, text: text.isEmpty ? "Nessun file cambiato: chiedo di fare il lavoro con gli strumenti." : text))
                    request = nudge
                    continue
                }
                onEvent(CodeEvent(kind: .text, text: text.isEmpty ? "Fatto." : text))
                return CodeAgent.Outcome(ok: true)
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize where restarts < 3 {
                // Finestra piena: si riparte con il riassunto di ciò che è già stato fatto.
                restarts += 1
                onEvent(CodeEvent(kind: .thinking, text: "La finestra di contesto di Apple Intelligence è piena: riparto dal riassunto del lavoro fatto."))
                session = LanguageModelSession(model: Agent.model, tools: tools, instructions: system)
                request = """
                Richiesta: \(prompt.prefix(900))

                Lavoro già fatto:
                \(toolbox.journal(limit: 900))

                Continua da qui senza ripetere il lavoro già fatto; se è tutto fatto, scrivi il riepilogo finale.
                """
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                return CodeAgent.Outcome(ok: false, error: "Apple Intelligence ha una finestra di contesto piccola e non è riuscito a finire: prova una richiesta più piccola o un modello più grande.")
            } catch {
                if Task.isCancelled { break }
                return CodeAgent.Outcome(ok: false, error: "Apple Intelligence si è fermato: \(error.localizedDescription)")
            }
        }
        return CodeAgent.Outcome(ok: false, error: "Richiesta interrotta.")
    }
}

/// Uno strumento del progetto per Apple Intelligence.
struct AppleCodeTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let perform: @Sendable (GeneratedContent) async -> String

    @concurrent func call(arguments: GeneratedContent) async throws -> String { await perform(arguments) }
}

// MARK: - Strumenti del progetto

/// Elenca, legge, cerca, scrive, modifica ed esegue comandi nella cartella del progetto, e racconta alla chat cosa fa.
public final class CodeToolbox: @unchecked Sendable {
    let root: URL
    let mode: CodeMode
    /// Apple Intelligence: risultati brevi, perché la finestra di contesto è piccola.
    let compact: Bool
    let onEvent: @Sendable (CodeEvent) -> Void
    /// Apre una pagina del progetto come in un browser e restituisce gli errori della console (dall'app).
    let pageChecker: CodeAgent.PageChecker?
    private let lock = NSLock()
    private var done: [String] = []
    private var changed = 0

    /// File creati o modificati finora.
    var changes: Int { lock.withLock { changed } }

    /// Cartelle che non servono a capire il progetto (dipendenze, build, cache).
    static let skipped: Set<String> = [".git", "node_modules", ".build", "build", "dist", "DerivedData", ".next", ".nuxt", ".svelte-kit",
                                       "Pods", ".venv", "venv", "__pycache__", ".cache", ".turbo", "vendor", ".swiftpm", ".claude"]

    init(folder: URL, mode: CodeMode, compact: Bool, checkPage: CodeAgent.PageChecker? = nil, onEvent: @escaping @Sendable (CodeEvent) -> Void) {
        root = folder.standardizedFileURL.resolvingSymlinksInPath()
        self.mode = mode
        self.compact = compact
        self.pageChecker = checkPage
        self.onEvent = onEvent
    }

    /// Lo strumento `controlla_pagina` c'è solo se l'app sa aprire le pagine e il progetto ha una pagina HTML (o è ancora vuoto).
    var checksPages: Bool {
        guard pageChecker != nil else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let web = names.contains { $0.lowercased().hasSuffix(".html") } || ["public", "src", "docs"].contains { names.contains($0) }
        return web || names.filter { !$0.hasPrefix(".") && !["AGENTS.md", "MEMORY.md", "README.md"].contains($0) }.isEmpty
    }

    var readLimit: Int { compact ? 1_400 : 14_000 }
    var listLimit: Int { compact ? 60 : 400 }
    var searchLimit: Int { compact ? 14 : 80 }
    var outputLimit: Int { compact ? 600 : 6_000 }

    // MARK: Descrizione per i modelli

    struct Parameter { let name: String; let type: String; let description: String; let required: Bool }

    var specs: [ToolSpec] {
        var list = [
            spec("elenca_file", "Elenca i file del progetto (senza dipendenze e cartelle di build).", [
                Parameter(name: "cartella", type: "string", description: "Sottocartella da elencare (vuoto: tutto il progetto)", required: false),
                Parameter(name: "filtro", type: "string", description: "Parte del nome o schema come *.swift", required: false),
            ]),
            spec("leggi_file", "Legge un file di testo del progetto, con i numeri di riga.", [
                Parameter(name: "percorso", type: "string", description: "Percorso del file, relativo al progetto", required: true),
                Parameter(name: "da_riga", type: "integer", description: "Prima riga da leggere (per i file lunghi)", required: false),
                Parameter(name: "a_riga", type: "integer", description: "Ultima riga da leggere", required: false),
            ]),
            spec("cerca", "Cerca un testo in tutti i file del progetto: restituisce file, riga e contenuto.", [
                Parameter(name: "testo", type: "string", description: "Testo da cercare (maiuscole e minuscole indifferenti)", required: true),
                Parameter(name: "cartella", type: "string", description: "Sottocartella in cui cercare", required: false),
            ]),
        ]
        if checksPages {
            list.append(spec("controlla_pagina", "Apre una pagina HTML del progetto come in un browser e restituisce gli errori della console (JavaScript, file che mancano). Usalo dopo aver modificato un sito.", [
                Parameter(name: "percorso", type: "string", description: "Pagina HTML, relativa al progetto (vuoto: index.html)", required: false),
            ]))
        }
        guard mode == .edit else { return list }
        list += [
            spec("modifica_file", "Modifica un file esistente sostituendo un pezzo di testo esatto con quello nuovo.", [
                Parameter(name: "percorso", type: "string", description: "Percorso del file, relativo al progetto", required: true),
                Parameter(name: "vecchio_testo", type: "string", description: "Testo da sostituire, copiato esattamente dal file (unico nel file)", required: true),
                Parameter(name: "nuovo_testo", type: "string", description: "Testo che prende il suo posto", required: true),
            ]),
            spec("scrivi_file", "Crea un file nuovo o lo riscrive tutto con il contenuto indicato.", [
                Parameter(name: "percorso", type: "string", description: "Percorso del file, relativo al progetto", required: true),
                Parameter(name: "contenuto", type: "string", description: "Contenuto completo del file", required: true),
            ]),
            spec("esegui_comando", "Esegue un comando della shell nella cartella del progetto (build, test, npm…). Scrive solo nel progetto, senza internet.", [
                Parameter(name: "comando", type: "string", description: "Comando da eseguire, per esempio «npm run build»", required: true),
            ]),
        ]
        return list
    }

    private func spec(_ name: String, _ description: String, _ fields: [Parameter]) -> ToolSpec {
        var properties: [String: JSONValue] = [:]
        for field in fields {
            properties[field.name] = .object(["type": .string(field.type), "description": .string(field.description)])
        }
        let parameters = JSONValue.object(["type": .string("object"), "properties": .object(properties),
                                           "required": .array(fields.filter(\.required).map { .string($0.name) })])
        return ToolSpec(name: name, description: description, parameters: parameters,
                        kind: ["elenca_file", "leggi_file", "cerca", "controlla_pagina"].contains(name) ? .read : .draft)
    }

    static func fields(of spec: ToolSpec) -> [Parameter] {
        let required = Set((spec.parameters["required"]?.array ?? []).compactMap(\.string))
        return (spec.parameters["properties"]?.object ?? [:]).sorted { $0.key < $1.key }.map { name, value in
            Parameter(name: name, type: value["type"]?.string ?? "string", description: value["description"]?.string ?? "", required: required.contains(name))
        }
    }

    static func appleSchema(for spec: ToolSpec) -> GenerationSchema {
        makeSchema(spec.name.replacingOccurrences(of: "_", with: " ").capitalized.replacingOccurrences(of: " ", with: "") + "Args",
                   fields(of: spec).map { field in
                       let type: FieldType = field.type == "integer" ? .int : .string
                       return field.required ? .required(field.name, type, field.description) : .optional(field.name, type, field.description)
                   })
    }

    static func arguments(from json: JSONValue) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in json.object ?? [:] {
            if let text = value.string { result[key] = text }
            else if let number = value.number { result[key] = number == number.rounded() ? String(Int(number)) : String(number) }
            else if value != .null { result[key] = value.compactString }
        }
        return result
    }

    static func arguments(from content: GeneratedContent, fields: [Parameter]) -> [String: String] {
        var result: [String: String] = [:]
        for field in fields {
            if field.type == "integer" { if let value = content.int(field.name) { result[field.name] = String(value) } }
            else if let value = try? content.value(String?.self, forProperty: field.name) { result[field.name] = value }
        }
        return result
    }

    // MARK: Esecuzione

    func run(_ name: String, _ arguments: [String: String]) async -> String {
        if Task.isCancelled { return "Richiesta interrotta." }
        switch name {
        case "elenca_file": return list(folder: arguments["cartella"], filter: arguments["filtro"])
        case "leggi_file": return read(arguments["percorso"], from: arguments["da_riga"].flatMap { Int($0) }, to: arguments["a_riga"].flatMap { Int($0) })
        case "cerca": return search(arguments["testo"], folder: arguments["cartella"])
        case "controlla_pagina": return await checkPage(arguments["percorso"])
        case "modifica_file" where mode == .edit: return edit(arguments["percorso"], old: arguments["vecchio_testo"], new: arguments["nuovo_testo"])
        case "scrivi_file" where mode == .edit: return write(arguments["percorso"], content: arguments["contenuto"])
        case "esegui_comando" where mode == .edit: return await command(arguments["comando"])
        case "modifica_file", "scrivi_file", "esegui_comando": return "Errore: in modalità «chiedi prima» non si modifica nulla. Proponi il piano."
        default: return "Errore: lo strumento «\(name)» non esiste. Strumenti: \(specs.map(\.name).joined(separator: ", "))."
        }
    }

    /// Ciò che è stato fatto finora, per ripartire quando la finestra di contesto si riempie.
    func journal(limit: Int) -> String {
        let lines = lock.withLock { done }
        let text = lines.suffix(30).map { "- " + $0 }.joined(separator: "\n")
        return text.isEmpty ? "- ancora niente" : String(text.suffix(limit))
    }

    private func note(_ line: String) { lock.withLock { done.append(line) } }

    /// Percorso dentro il progetto (mai fuori, mai nella cartella di Git).
    func resolve(_ path: String?) -> URL? {
        let clean = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        let url = clean.isEmpty || clean == "." ? root
            : (clean.hasPrefix("/") ? URL(fileURLWithPath: clean) : root.appending(path: clean)).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.path
        guard url.path == base || url.path.hasPrefix(base + "/") else { return nil }
        guard !url.path.dropFirst(base.count).split(separator: "/").contains(".git") else { return nil }
        return url
    }

    func relative(_ url: URL) -> String {
        url.path == root.path ? "." : String(url.path.dropFirst(root.path.count + 1))
    }

    private func list(folder: String?, filter: String?) -> String {
        guard let start = resolve(folder) else { return "Errore: la cartella è fuori dal progetto." }
        onEvent(CodeEvent(kind: .tool, text: "Elenca i file" + (folder.map { $0.isEmpty ? "" : " di \($0)" } ?? "")))
        let pattern = filter?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var files: [String] = []
        var total = 0
        let enumerator = FileManager.default.enumerator(at: start, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if Self.skipped.contains(name) { enumerator?.skipDescendants() }
                continue
            }
            if name == ".DS_Store" { continue }
            let path = relative(url)
            if !pattern.isEmpty {
                let matches = pattern.contains("*") ? fnmatch(pattern, name.lowercased(), 0) == 0 : path.lowercased().contains(pattern)
                guard matches else { continue }
            }
            total += 1
            if files.count < listLimit { files.append(path) }
        }
        note("elencati i file (\(total))")
        guard !files.isEmpty else { return "Nessun file trovato." }
        return files.sorted().joined(separator: "\n") + (total > files.count ? "\n… e altri \(total - files.count) file (usa filtro o cartella)." : "")
    }

    private func read(_ path: String?, from: Int?, to: Int?) -> String {
        guard let url = resolve(path) else { return "Errore: il percorso è fuori dal progetto." }
        guard let data = try? Data(contentsOf: url) else { return "Errore: il file «\(path ?? "")» non esiste. Usa elenca_file per vedere i file." }
        guard let text = String(data: data, encoding: .utf8) else { return "Il file «\(relative(url))» non è di testo (\(data.count) byte)." }
        onEvent(CodeEvent(kind: .tool, text: "Legge \(relative(url))"))
        let lines = text.components(separatedBy: "\n")
        let first = max(1, from ?? 1)
        let last = min(lines.count, max(first, to ?? lines.count))
        guard first <= lines.count else { return "Il file ha solo \(lines.count) righe." }
        var output = ""
        var shown = first - 1
        for number in first...last {
            let line = "\(number)| \(lines[number - 1])\n"
            if output.count + line.count > readLimit { break }
            output += line
            shown = number
        }
        note("letto \(relative(url)) (righe \(first)-\(shown))")
        if shown < last { output += "… (il file ha \(lines.count) righe: continua con da_riga=\(shown + 1))" }
        return output.isEmpty ? "(file vuoto)" : output
    }

    private func search(_ query: String?, folder: String?) -> String {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return "Errore: manca il testo da cercare." }
        guard let start = resolve(folder) else { return "Errore: la cartella è fuori dal progetto." }
        onEvent(CodeEvent(kind: .tool, text: "Cerca «\(query)»"))
        var results: [String] = []
        var total = 0
        let enumerator = FileManager.default.enumerator(at: start, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if Self.skipped.contains(url.lastPathComponent) { enumerator?.skipDescendants() }
                continue
            }
            guard (values?.fileSize ?? 0) < 1_000_000, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() where line.localizedCaseInsensitiveContains(query) {
                total += 1
                if results.count < searchLimit {
                    results.append("\(relative(url)):\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(compact ? 120 : 200))")
                }
            }
        }
        note("cercato «\(query)» (\(total) risultati)")
        guard !results.isEmpty else { return "Nessun risultato per «\(query)»." }
        return results.joined(separator: "\n") + (total > results.count ? "\n… e altri \(total - results.count) risultati." : "")
    }

    private func checkPage(_ path: String?) async -> String {
        guard let pageChecker else { return "Errore: il controllo delle pagine non è disponibile." }
        let target = path.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "index.html"
        guard let url = resolve(target), FileManager.default.fileExists(atPath: url.path) else {
            return "Errore: la pagina «\(target)» non esiste. Usa elenca_file per vedere le pagine del progetto."
        }
        let key = "pagina-\(UUID().uuidString)"
        onEvent(CodeEvent(key: key, kind: .tool, text: "Apre \(relative(url)) nel browser", status: .running))
        let errors = await pageChecker(url)
        onEvent(CodeEvent(key: key, kind: .tool, text: errors.isEmpty ? "\(relative(url)): nessun errore" : "\(relative(url)): \(errors.count) errori nella console",
                          status: errors.isEmpty ? .ok : .failed))
        note("controllata \(relative(url)) (\(errors.count) errori)")
        guard !errors.isEmpty else { return "Nessun errore nella console di \(relative(url))." }
        return "Errori nella console di \(relative(url)):\n" + errors.prefix(15).map { "- " + $0 }.joined(separator: "\n")
    }

    /// I modelli piccoli a volte scrivono «\n» letterali al posto degli a capo.
    static func unescaped(_ text: String) -> String {
        guard !text.contains("\n"), text.components(separatedBy: "\\n").count > 2 else { return text }
        return text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\\"", with: "\"")
    }

    private func edit(_ path: String?, old: String?, new: String?) -> String {
        guard let url = resolve(path), url != root else { return "Errore: il percorso è fuori dal progetto." }
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { return "Errore: il file «\(path ?? "")» non esiste. Per un file nuovo usa scrivi_file." }
        guard var old, !old.isEmpty else { return "Errore: manca vecchio_testo (il pezzo da sostituire)." }
        var new = new ?? ""
        if !original.contains(old), original.contains(Self.unescaped(old)) {
            old = Self.unescaped(old)
            new = Self.unescaped(new)
        }
        let count = original.components(separatedBy: old).count - 1
        guard count > 0 else { return "Errore: vecchio_testo non si trova in \(relative(url)). Rileggi il file con leggi_file e copia il pezzo esatto." }
        guard count == 1 else { return "Errore: vecchio_testo compare \(count) volte in \(relative(url)): aggiungi qualche riga intorno per renderlo unico." }
        let updated = original.replacingOccurrences(of: old, with: new)
        do { try updated.write(to: url, atomically: true, encoding: .utf8) } catch { return "Errore: \(error.localizedDescription)" }
        onEvent(CodeEvent(kind: .file, text: "Modifica", path: relative(url)))
        note("modificato \(relative(url))")
        lock.withLock { changed += 1 }
        return "Fatto: \(relative(url)) modificato."
    }

    private func write(_ path: String?, content: String?) -> String {
        guard let url = resolve(path), url != root else { return "Errore: il percorso è fuori dal progetto." }
        let existed = FileManager.default.fileExists(atPath: url.path)
        let text = Self.unescaped(content ?? "")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "Errore: \(error.localizedDescription)"
        }
        onEvent(CodeEvent(kind: .file, text: existed ? "Modifica" : "Crea", path: relative(url)))
        note("\(existed ? "riscritto" : "creato") \(relative(url))")
        lock.withLock { changed += 1 }
        return "Fatto: \(relative(url)) \(existed ? "riscritto" : "creato") (\(text.components(separatedBy: "\n").count) righe)."
    }

    /// Recinto dei comandi: si scrive solo nel progetto, nelle cartelle temporanee e nelle cache; la rete solo in locale.
    static let sandboxProfile = """
    (version 1)(allow default)(deny file-write*)\
    (allow file-write* (subpath (param "PROJECT")) (subpath "/private/tmp") (subpath "/private/var/folders") (subpath "/dev") \
    (subpath (param "CACHES")) (subpath (param "NPM")))\
    (deny network-outbound)(allow network-outbound (remote ip "localhost:*"))(allow network-outbound (remote unix-socket))
    """

    private func command(_ command: String?) async -> String {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return "Errore: manca il comando." }
        let key = "comando-\(UUID().uuidString)"
        onEvent(CodeEvent(key: key, kind: .command, text: command, status: .running))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let line = "cd \(Shell.quote(root.path)) && /usr/bin/sandbox-exec -D PROJECT=\(Shell.quote(root.path)) -D CACHES=\(Shell.quote(home + "/Library/Caches"))"
            + " -D NPM=\(Shell.quote(home + "/.npm")) -p \(Shell.quote(Self.sandboxProfile)) /bin/zsh -lc \(Shell.quote(command))"
        let result = await Shell.run(line, timeout: 180)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        onEvent(CodeEvent(key: key, kind: .command, text: command, detail: String(output.suffix(4000)), status: result.status == 0 ? .ok : .failed))
        note("eseguito `\(command.prefix(80))` (\(result.status == 0 ? "riuscito" : "errore \(result.status)"))")
        let tail = output.count > outputLimit ? "…" + output.suffix(outputLimit) : output
        return "Codice di uscita \(result.status).\n" + (tail.isEmpty ? "(nessuna uscita)" : tail)
    }
}
