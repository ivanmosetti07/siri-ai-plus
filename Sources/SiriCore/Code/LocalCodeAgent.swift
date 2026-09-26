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
        var text = Language.isEnglish ? englishInstructions(folder: folder, mode: mode, checksPages: checksPages)
                                      : italianInstructions(folder: folder, mode: mode, checksPages: checksPages)
        let agents = folder.appending(path: "AGENTS.md")
        if let rules = try? String(contentsOf: agents, encoding: .utf8), !rules.isEmpty {
            text += Language.t("\n\nRegole del progetto (AGENTS.md):\n", "\n\nProject rules (AGENTS.md):\n") + String(rules.prefix(compact ? 700 : 5000))
        }
        return text
    }

    private static func italianInstructions(folder: URL, mode: CodeMode, checksPages: Bool) -> String {
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
        return text
    }

    /// Le stesse istruzioni in inglese: gli strumenti mantengono i loro nomi.
    private static func englishInstructions(folder: URL, mode: CodeMode, checksPages: Bool) -> String {
        var text = """
        You are the Siri AI+ coding agent and you work in the project “\(folder.lastPathComponent)”. It is now \(Dates.format(.now)).
        Use the tools to understand the code: elenca_file (list the files), leggi_file (read a file) and cerca (search). Paths are relative to the project folder.
        """
        if mode == .edit {
            text += """

            To change an existing file use modifica_file (it replaces an exact piece of text, copied from leggi_file); \
            for new files, or files to rewrite completely, use scrivi_file. With esegui_comando you run builds, tests and project commands \
            (they can only write inside the project folder and have no internet access).
            Read a file before changing it, make small and precise changes, and if there is a verification command, run it after your changes.
            Files are created and changed only by calling the tools: writing code in your reply changes nothing.
            Work on your own until the end: don't ask for permission to read or change the project files, just do it. \
            If you're told that something doesn't work, read the files involved, find the cause, fix it and verify.
            """
            if checksPages {
                text += "\nFor websites: after your changes open the page with controlla_pagina (usually index.html) and fix the errors it finds, until there are none left."
            }
        } else {
            text += "\n“Ask first” mode: don't change anything. Study the project and propose a clear plan, in bullet points, with the files to touch."
        }
        text += "\nDon't make up files, code or results that the tools didn't return. At the end, reply in English with a short summary of what you did."
        return text
    }

    /// La richiesta chiede di cambiare il progetto (non solo di spiegarlo).
    static func asksForChanges(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        if text.range(of: #"\b(?:crea|creare|aggiungi|modifica|cambia|sistema|correggi|scrivi|rendi|metti|togli|rimuovi|elimina|implementa|costruisci|fai|sostituisci|traduci|aggiorna|sposta|rinomina)\b"#,
                      options: .regularExpression) != nil { return true }
        // In inglese contano anche i verbi inglesi.
        return Language.isEnglish
            && text.range(of: #"\b(?:create|add|edit|modify|change|fix|write|rewrite|make|put|remove|delete|implement|build|replace|translate|update|move|rename|insert|refactor|convert|generate|set\s+up)\b"#,
                          options: .regularExpression) != nil
    }

    /// Il modello ha risposto senza toccare nessun file, ma la richiesta chiedeva di cambiarli: glielo si chiede di nuovo.
    static var nudge: String {
        Language.t("Non hai ancora creato né modificato nessun file: descrivere il lavoro non basta. Fallo adesso con gli strumenti, un file alla volta (scrivi_file per i file nuovi, modifica_file per quelli esistenti), poi rispondi con il riepilogo.",
                   "You haven't created or changed any file yet: describing the work isn't enough. Do it now with the tools, one file at a time (scrivi_file for new files, modifica_file for existing ones), then reply with the summary.")
    }

    /// Cosa vede la chat quando si chiede al modello di fare davvero il lavoro.
    static var nudgeNotice: String {
        Language.t("Nessun file cambiato: chiedo di fare il lavoro con gli strumenti.", "No files changed: asking the model to do the work with the tools.")
    }

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
            if Task.isCancelled { return CodeAgent.Outcome(ok: false, error: CodeAgent.interrupted) }
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
                    return CodeAgent.Outcome(ok: false, error: Language.t("\(label) non risponde: \(detail.prefix(200))", "\(label) isn't responding: \(detail.prefix(200))"))
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
                if Task.isCancelled { return CodeAgent.Outcome(ok: false, error: CodeAgent.interrupted) }
                return CodeAgent.Outcome(ok: false, error: (error as? URLError) != nil
                                         ? Language.t("\(label) non è in esecuzione: avvialo in Impostazioni › Modelli.", "\(label) isn't running: start it in Settings › Models.")
                                         : error.localizedDescription)
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
                onEvent(CodeEvent(key: key, kind: .thinking, text: visible.isEmpty ? nudgeNotice : visible))
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
        onEvent(CodeEvent(kind: .text, text: Language.t("Mi sono fermato dopo \(maxRounds) passaggi: scrivimi se devo continuare.",
                                                        "I stopped after \(maxRounds) steps: tell me if I should continue.")))
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
            let note = messages[index]["role"]?.string == "tool"
                ? Language.t("[risultato già letto, tolto per fare spazio: se serve, richiama lo strumento]",
                             "[result already read, removed to make room: call the tool again if you need it]")
                : String(content.prefix(300)) + "…"
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
            request = Language.t("Prima hai risposto: «\(last.text.prefix(500))»\n\nNuova richiesta: \(prompt)",
                                 "Earlier you replied: “\(last.text.prefix(500))”\n\nNew request: \(prompt)")
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
                    onEvent(CodeEvent(kind: .thinking, text: text.isEmpty ? nudgeNotice : text))
                    request = nudge
                    continue
                }
                onEvent(CodeEvent(kind: .text, text: text.isEmpty ? Language.t("Fatto.", "Done.") : text))
                return CodeAgent.Outcome(ok: true)
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize where restarts < 3 {
                // Finestra piena: si riparte con il riassunto di ciò che è già stato fatto.
                restarts += 1
                onEvent(CodeEvent(kind: .thinking, text: Language.t("La finestra di contesto di Apple Intelligence è piena: riparto dal riassunto del lavoro fatto.",
                                                                    "Apple Intelligence's context window is full: starting again from a summary of the work done.")))
                session = LanguageModelSession(model: Agent.model, tools: tools, instructions: system)
                if Language.isEnglish {
                    request = """
                    Request: \(prompt.prefix(900))

                    Work already done:
                    \(toolbox.journal(limit: 900))

                    Continue from here without repeating the work already done; if everything is done, write the final summary.
                    """
                } else {
                    request = """
                    Richiesta: \(prompt.prefix(900))

                    Lavoro già fatto:
                    \(toolbox.journal(limit: 900))

                    Continua da qui senza ripetere il lavoro già fatto; se è tutto fatto, scrivi il riepilogo finale.
                    """
                }
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                return CodeAgent.Outcome(ok: false, error: Language.t(
                    "Apple Intelligence ha una finestra di contesto piccola e non è riuscito a finire: prova una richiesta più piccola o un modello più grande.",
                    "Apple Intelligence has a small context window and couldn't finish: try a smaller request or a bigger model."))
            } catch {
                if Task.isCancelled { break }
                return CodeAgent.Outcome(ok: false, error: Language.t("Apple Intelligence si è fermato: \(error.localizedDescription)",
                                                                      "Apple Intelligence stopped: \(error.localizedDescription)"))
            }
        }
        return CodeAgent.Outcome(ok: false, error: CodeAgent.interrupted)
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
    /// Lingua della richiesta che usa gli strumenti: Apple Intelligence può chiamarli fuori dal suo ambito.
    let language: Language
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
        language = Language.current
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

    /// Gli strumenti per il modello: i nomi (e quelli dei parametri) restano in italiano, le descrizioni seguono la lingua.
    var specs: [ToolSpec] {
        let path = Language.t("Percorso del file, relativo al progetto", "File path, relative to the project")
        var list = [
            spec("elenca_file", Language.t("Elenca i file del progetto (senza dipendenze e cartelle di build).",
                                           "Lists the project files (without dependencies and build folders)."), [
                Parameter(name: "cartella", type: "string", description: Language.t("Sottocartella da elencare (vuoto: tutto il progetto)",
                                                                                     "Subfolder to list (empty: the whole project)"), required: false),
                Parameter(name: "filtro", type: "string", description: Language.t("Parte del nome o schema come *.swift",
                                                                                   "Part of the name, or a pattern like *.swift"), required: false),
            ]),
            spec("leggi_file", Language.t("Legge un file di testo del progetto, con i numeri di riga.",
                                          "Reads a text file of the project, with line numbers."), [
                Parameter(name: "percorso", type: "string", description: path, required: true),
                Parameter(name: "da_riga", type: "integer", description: Language.t("Prima riga da leggere (per i file lunghi)",
                                                                                     "First line to read (for long files)"), required: false),
                Parameter(name: "a_riga", type: "integer", description: Language.t("Ultima riga da leggere", "Last line to read"), required: false),
            ]),
            spec("cerca", Language.t("Cerca un testo in tutti i file del progetto: restituisce file, riga e contenuto.",
                                     "Searches for a text in all the project files: returns file, line and content."), [
                Parameter(name: "testo", type: "string", description: Language.t("Testo da cercare (maiuscole e minuscole indifferenti)",
                                                                                  "Text to search for (case-insensitive)"), required: true),
                Parameter(name: "cartella", type: "string", description: Language.t("Sottocartella in cui cercare", "Subfolder to search in"), required: false),
            ]),
        ]
        if checksPages {
            list.append(spec("controlla_pagina", Language.t(
                "Apre una pagina HTML del progetto come in un browser e restituisce gli errori della console (JavaScript, file che mancano). Usalo dopo aver modificato un sito.",
                "Opens an HTML page of the project as in a browser and returns the console errors (JavaScript, missing files). Use it after changing a website."), [
                Parameter(name: "percorso", type: "string", description: Language.t("Pagina HTML, relativa al progetto (vuoto: index.html)",
                                                                                     "HTML page, relative to the project (empty: index.html)"), required: false),
            ]))
        }
        guard mode == .edit else { return list }
        list += [
            spec("modifica_file", Language.t("Modifica un file esistente sostituendo un pezzo di testo esatto con quello nuovo.",
                                             "Edits an existing file by replacing an exact piece of text with the new one."), [
                Parameter(name: "percorso", type: "string", description: path, required: true),
                Parameter(name: "vecchio_testo", type: "string", description: Language.t("Testo da sostituire, copiato esattamente dal file (unico nel file)",
                                                                                          "Text to replace, copied exactly from the file (unique in the file)"), required: true),
                Parameter(name: "nuovo_testo", type: "string", description: Language.t("Testo che prende il suo posto", "Text that takes its place"), required: true),
            ]),
            spec("scrivi_file", Language.t("Crea un file nuovo o lo riscrive tutto con il contenuto indicato.",
                                           "Creates a new file, or rewrites it completely, with the given content."), [
                Parameter(name: "percorso", type: "string", description: path, required: true),
                Parameter(name: "contenuto", type: "string", description: Language.t("Contenuto completo del file", "Full content of the file"), required: true),
            ]),
            spec("esegui_comando", Language.t("Esegue un comando della shell nella cartella del progetto (build, test, npm…). Scrive solo nel progetto, senza internet.",
                                              "Runs a shell command in the project folder (build, test, npm…). It can only write inside the project, with no internet access."), [
                Parameter(name: "comando", type: "string", description: Language.t("Comando da eseguire, per esempio «npm run build»",
                                                                                    "Command to run, for example “npm run build”"), required: true),
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

    /// Esegue uno strumento: risultati ed eventi nella lingua della richiesta, anche se la chiamata arriva da fuori.
    func run(_ name: String, _ arguments: [String: String]) async -> String {
        await Language.$scoped.withValue(language) { await perform(name, arguments) }
    }

    private func perform(_ name: String, _ arguments: [String: String]) async -> String {
        if Task.isCancelled { return CodeAgent.interrupted }
        switch name {
        case "elenca_file": return list(folder: arguments["cartella"], filter: arguments["filtro"])
        case "leggi_file": return read(arguments["percorso"], from: arguments["da_riga"].flatMap { Int($0) }, to: arguments["a_riga"].flatMap { Int($0) })
        case "cerca": return search(arguments["testo"], folder: arguments["cartella"])
        case "controlla_pagina": return await checkPage(arguments["percorso"])
        case "modifica_file" where mode == .edit: return edit(arguments["percorso"], old: arguments["vecchio_testo"], new: arguments["nuovo_testo"])
        case "scrivi_file" where mode == .edit: return write(arguments["percorso"], content: arguments["contenuto"])
        case "esegui_comando" where mode == .edit: return await command(arguments["comando"])
        case "modifica_file", "scrivi_file", "esegui_comando":
            return Language.t("Errore: in modalità «chiedi prima» non si modifica nulla. Proponi il piano.",
                              "Error: in “ask first” mode nothing gets changed. Propose the plan.")
        default:
            let tools = specs.map(\.name).joined(separator: ", ")
            return Language.t("Errore: lo strumento «\(name)» non esiste. Strumenti: \(tools).", "Error: the tool “\(name)” doesn't exist. Tools: \(tools).")
        }
    }

    /// Ciò che è stato fatto finora, per ripartire quando la finestra di contesto si riempie.
    func journal(limit: Int) -> String {
        let lines = lock.withLock { done }
        let text = lines.suffix(30).map { "- " + $0 }.joined(separator: "\n")
        return text.isEmpty ? Language.t("- ancora niente", "- nothing yet") : String(text.suffix(limit))
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

    private var folderOutside: String { Language.t("Errore: la cartella è fuori dal progetto.", "Error: the folder is outside the project.") }
    private var pathOutside: String { Language.t("Errore: il percorso è fuori dal progetto.", "Error: the path is outside the project.") }

    private func list(folder: String?, filter: String?) -> String {
        guard let start = resolve(folder) else { return folderOutside }
        onEvent(CodeEvent(kind: .tool, text: Language.t("Elenca i file", "List files") + (folder.map { $0.isEmpty ? "" : Language.t(" di \($0)", " in \($0)") } ?? "")))
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
        note(Language.t("elencati i file (\(total))", "listed the files (\(total))"))
        guard !files.isEmpty else { return Language.t("Nessun file trovato.", "No files found.") }
        let more = total - files.count
        return files.sorted().joined(separator: "\n")
            + (more > 0 ? Language.t("\n… e altri \(more) file (usa filtro o cartella).", "\n… and \(more) more files (use filtro or cartella).") : "")
    }

    private func read(_ path: String?, from: Int?, to: Int?) -> String {
        guard let url = resolve(path) else { return pathOutside }
        guard let data = try? Data(contentsOf: url) else {
            return Language.t("Errore: il file «\(path ?? "")» non esiste. Usa elenca_file per vedere i file.",
                              "Error: the file “\(path ?? "")” doesn't exist. Use elenca_file to see the files.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return Language.t("Il file «\(relative(url))» non è di testo (\(data.count) byte).", "The file “\(relative(url))” isn't a text file (\(data.count) bytes).")
        }
        onEvent(CodeEvent(kind: .tool, text: Language.t("Legge \(relative(url))", "Read \(relative(url))")))
        let lines = text.components(separatedBy: "\n")
        let first = max(1, from ?? 1)
        let last = min(lines.count, max(first, to ?? lines.count))
        guard first <= lines.count else { return Language.t("Il file ha solo \(lines.count) righe.", "The file only has \(lines.count) lines.") }
        var output = ""
        var shown = first - 1
        for number in first...last {
            let line = "\(number)| \(lines[number - 1])\n"
            if output.count + line.count > readLimit { break }
            output += line
            shown = number
        }
        note(Language.t("letto \(relative(url)) (righe \(first)-\(shown))", "read \(relative(url)) (lines \(first)-\(shown))"))
        if shown < last {
            output += Language.t("… (il file ha \(lines.count) righe: continua con da_riga=\(shown + 1))",
                                 "… (the file has \(lines.count) lines: continue with da_riga=\(shown + 1))")
        }
        return output.isEmpty ? Language.t("(file vuoto)", "(empty file)") : output
    }

    private func search(_ query: String?, folder: String?) -> String {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return Language.t("Errore: manca il testo da cercare.", "Error: the text to search for is missing.")
        }
        guard let start = resolve(folder) else { return folderOutside }
        onEvent(CodeEvent(kind: .tool, text: Language.t("Cerca «\(query)»", "Search “\(query)”")))
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
        note(Language.t("cercato «\(query)» (\(total) risultati)", "searched “\(query)” (\(total) results)"))
        guard !results.isEmpty else { return Language.t("Nessun risultato per «\(query)».", "No results for “\(query)”.") }
        let more = total - results.count
        return results.joined(separator: "\n") + (more > 0 ? Language.t("\n… e altri \(more) risultati.", "\n… and \(more) more results.") : "")
    }

    private func checkPage(_ path: String?) async -> String {
        guard let pageChecker else { return Language.t("Errore: il controllo delle pagine non è disponibile.", "Error: page checking isn't available.") }
        let target = path.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "index.html"
        guard let url = resolve(target), FileManager.default.fileExists(atPath: url.path) else {
            return Language.t("Errore: la pagina «\(target)» non esiste. Usa elenca_file per vedere le pagine del progetto.",
                              "Error: the page “\(target)” doesn't exist. Use elenca_file to see the project's pages.")
        }
        let key = "pagina-\(UUID().uuidString)"
        let page = relative(url)
        onEvent(CodeEvent(key: key, kind: .tool, text: Language.t("Apre \(page) nel browser", "Open \(page) in the browser"), status: .running))
        let errors = await pageChecker(url)
        let count = errors.count == 1 ? "1 error" : "\(errors.count) errors"
        let found = Language.t("\(page): \(errors.count) errori nella console", "\(page): \(count) in the console")
        onEvent(CodeEvent(key: key, kind: .tool, text: errors.isEmpty ? Language.t("\(page): nessun errore", "\(page): no errors") : found,
                          status: errors.isEmpty ? .ok : .failed))
        note(Language.t("controllata \(page) (\(errors.count) errori)", "checked \(page) (\(count))"))
        guard !errors.isEmpty else { return Language.t("Nessun errore nella console di \(page).", "No errors in the console of \(page).") }
        return Language.t("Errori nella console di \(page):\n", "Errors in the console of \(page):\n") + errors.prefix(15).map { "- " + $0 }.joined(separator: "\n")
    }

    /// I modelli piccoli a volte scrivono «\n» letterali al posto degli a capo.
    static func unescaped(_ text: String) -> String {
        guard !text.contains("\n"), text.components(separatedBy: "\\n").count > 2 else { return text }
        return text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\\"", with: "\"")
    }

    private func edit(_ path: String?, old: String?, new: String?) -> String {
        guard let url = resolve(path), url != root else { return pathOutside }
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            return Language.t("Errore: il file «\(path ?? "")» non esiste. Per un file nuovo usa scrivi_file.",
                              "Error: the file “\(path ?? "")” doesn't exist. For a new file use scrivi_file.")
        }
        guard var old, !old.isEmpty else { return Language.t("Errore: manca vecchio_testo (il pezzo da sostituire).", "Error: vecchio_testo is missing (the piece to replace).") }
        var new = new ?? ""
        if !original.contains(old), original.contains(Self.unescaped(old)) {
            old = Self.unescaped(old)
            new = Self.unescaped(new)
        }
        let count = original.components(separatedBy: old).count - 1
        guard count > 0 else {
            return Language.t("Errore: vecchio_testo non si trova in \(relative(url)). Rileggi il file con leggi_file e copia il pezzo esatto.",
                              "Error: vecchio_testo isn't in \(relative(url)). Read the file again with leggi_file and copy the exact piece.")
        }
        guard count == 1 else {
            return Language.t("Errore: vecchio_testo compare \(count) volte in \(relative(url)): aggiungi qualche riga intorno per renderlo unico.",
                              "Error: vecchio_testo appears \(count) times in \(relative(url)): add a few lines around it to make it unique.")
        }
        let updated = original.replacingOccurrences(of: old, with: new)
        do { try updated.write(to: url, atomically: true, encoding: .utf8) } catch { return Language.t("Errore: ", "Error: ") + error.localizedDescription }
        onEvent(CodeEvent(kind: .file, text: Language.t("Modifica", "Edit"), path: relative(url)))
        note(Language.t("modificato \(relative(url))", "edited \(relative(url))"))
        lock.withLock { changed += 1 }
        return Language.t("Fatto: \(relative(url)) modificato.", "Done: \(relative(url)) edited.")
    }

    private func write(_ path: String?, content: String?) -> String {
        guard let url = resolve(path), url != root else { return pathOutside }
        let existed = FileManager.default.fileExists(atPath: url.path)
        let text = Self.unescaped(content ?? "")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return Language.t("Errore: ", "Error: ") + error.localizedDescription
        }
        onEvent(CodeEvent(kind: .file, text: existed ? Language.t("Modifica", "Edit") : Language.t("Crea", "Create"), path: relative(url)))
        note(existed ? Language.t("riscritto \(relative(url))", "rewrote \(relative(url))") : Language.t("creato \(relative(url))", "created \(relative(url))"))
        lock.withLock { changed += 1 }
        let lines = text.components(separatedBy: "\n").count
        return existed ? Language.t("Fatto: \(relative(url)) riscritto (\(lines) righe).", "Done: \(relative(url)) rewritten (\(lines) lines).")
                       : Language.t("Fatto: \(relative(url)) creato (\(lines) righe).", "Done: \(relative(url)) created (\(lines) lines).")
    }

    /// Recinto dei comandi: si scrive solo nel progetto, nelle cartelle temporanee e nelle cache; la rete solo in locale.
    static let sandboxProfile = """
    (version 1)(allow default)(deny file-write*)\
    (allow file-write* (subpath (param "PROJECT")) (subpath "/private/tmp") (subpath "/private/var/folders") (subpath "/dev") \
    (subpath (param "CACHES")) (subpath (param "NPM")))\
    (deny network-outbound)(allow network-outbound (remote ip "localhost:*"))(allow network-outbound (remote unix-socket))
    """

    private func command(_ command: String?) async -> String {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return Language.t("Errore: manca il comando.", "Error: the command is missing.")
        }
        let key = "comando-\(UUID().uuidString)"
        onEvent(CodeEvent(key: key, kind: .command, text: command, status: .running))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let line = "cd \(Shell.quote(root.path)) && /usr/bin/sandbox-exec -D PROJECT=\(Shell.quote(root.path)) -D CACHES=\(Shell.quote(home + "/Library/Caches"))"
            + " -D NPM=\(Shell.quote(home + "/.npm")) -p \(Shell.quote(Self.sandboxProfile)) /bin/zsh -lc \(Shell.quote(command))"
        let result = await Shell.run(line, timeout: 180)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        onEvent(CodeEvent(key: key, kind: .command, text: command, detail: String(output.suffix(4000)), status: result.status == 0 ? .ok : .failed))
        note(Language.t("eseguito `\(command.prefix(80))` (\(result.status == 0 ? "riuscito" : "errore \(result.status)"))",
                        "ran `\(command.prefix(80))` (\(result.status == 0 ? "succeeded" : "error \(result.status)"))"))
        let tail = output.count > outputLimit ? "…" + output.suffix(outputLimit) : output
        return Language.t("Codice di uscita \(result.status).\n", "Exit code \(result.status).\n") + (tail.isEmpty ? Language.t("(nessuna uscita)", "(no output)") : tail)
    }
}
