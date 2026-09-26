import Foundation

/// «Chiedi prima»: l'agente propone un piano senza toccare i file. «Modifica»: lavora nella cartella del progetto.
public enum CodeMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case plan, edit
    public var id: String { rawValue }
    public var label: String { self == .plan ? Language.t("Chiedi prima", "Ask first") : Language.t("Modifica", "Edit") }
}

public struct CodeTodo: Codable, Sendable, Equatable {
    public var text: String
    public var done: Bool
    public init(text: String, done: Bool) { self.text = text; self.done = done }
}

/// Un evento della sessione di coding, come lo mostra la chat.
public struct CodeEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case user, text, thinking, command, file, todo, tool, error, result }
    public enum Status: String, Codable, Sendable { case running, ok, failed }

    public var id = UUID()
    /// Id dell'elemento nel motore: gli aggiornamenti successivi (uscita del comando) si fondono qui.
    public var key: String?
    public var kind: Kind
    public var text: String
    public var detail: String = ""
    public var status: Status = .ok
    public var path: String?
    public var todos: [CodeTodo] = []
    /// Punto di ripristino preso prima di questo messaggio dell'utente.
    public var snapshot: String?
    public var date = Date.now

    public init(key: String? = nil, kind: Kind, text: String, detail: String = "", status: Status = .ok, path: String? = nil, todos: [CodeTodo] = []) {
        self.key = key; self.kind = kind; self.text = text; self.detail = detail; self.status = status; self.path = path; self.todos = todos
    }
}

public enum CodeAgent {
    /// Apre una pagina del progetto in un browser nascosto e restituisce gli errori della console.
    public typealias PageChecker = @Sendable (URL) async -> [String]

    /// La richiesta dice che qualcosa non va («non funziona», «c'è un errore», «sistema»…).
    public static func mentionsProblem(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        if text.range(of: #"non (?:funziona|va\b|parte|si (?:apre|vede|muove|carica|avvia))|errore|errori|\bbug|rott[oa]\b|\bsistema\b|correggi|si blocca|crash|(?:schermata|pagina) bianca|problema"#,
                      options: .regularExpression) != nil { return true }
        // In inglese anche le frasi inglesi («doesn't work», «there's an error», «blank page», «it freezes»…).
        return Language.isEnglish && text.range(of: englishProblem, options: .regularExpression) != nil
    }

    private static let englishProblem = #"\b(?:doesn|don|isn|aren|won|can|didn)[’']?t\s+(?:seem\s+to\s+|really\s+|even\s+)?(?:work|load|start|open|run|show|display|appear|respond|move|build|compile)"#
        + #"|\b(?:does|do|is|are|will|can|did)\s+not\s+(?:work|load|start|open|run|show|display|appear|respond|move|build|compile)"#
        + #"|\bnot\s+(?:working|loading|showing|starting|opening|responding|displaying)|\bstopped\s+working|\berrors?\b|\bbugs?\b|\bbuggy\b|\bbroken\b"#
        + #"|\bfix\b|\bcrash|\bfail(?:s|ed|ing)?\b|(?:blank|white|empty)\s+(?:page|screen)|\bproblems?\b|\bissues?\b|\bwrong\b"#
        + #"|\bfreez(?:e|es|ing)\b|\bfrozen\b|\bstuck\b|\bhangs?\b|\bnothing\s+(?:happens|shows|appears)"#

    /// Preambolo della modalità «chiedi prima» per Codex e Claude Code.
    static var planPreamble: String {
        Language.t("Modalità «chiedi prima»: non modificare nessun file e non eseguire comandi che cambiano qualcosa. Studia il progetto e proponi un piano chiaro, a punti, di cosa faresti e quali file toccheresti. Rispondi in italiano.\n\n",
                   "“Ask first” mode: don't change any file and don't run commands that change anything. Study the project and propose a clear plan, in bullet points, of what you would do and which files you would touch. Answer in English.\n\n")
    }

    /// La richiesta fermata da chi l'ha avviata.
    static var interrupted: String { Language.t("Richiesta interrotta.", "Request cancelled.") }

    /// Chi lavora sul progetto: la CLI di ChatGPT (Codex), quella di Claude (Claude Code), oppure l'agente dell'app
    /// con un modello sul Mac (Apple Intelligence, Gemma, ds4).
    public enum Engine: String, Sendable {
        case codex, claude, local

        public init(_ provider: ResponseProvider) {
            switch provider {
            case .chatgpt: self = .codex
            case .claude: self = .claude
            case .apple, .gemma, .ds4: self = .local
            }
        }

        /// Nome del motore per la chat del coding.
        public var label: String {
            switch self {
            case .codex: "Codex"
            case .claude: "Claude Code"
            case .local: Language.t("Agente di Siri AI+", "Siri AI+ agent")
            }
        }
    }

    /// Strumenti di Claude Code che non servono a lavorare sul codice (promemoria, notifiche, lavori pianificati…).
    static let claudeExcludedTools = "CronCreate,CronDelete,CronList,PushNotification,RemoteTrigger,ScheduleWakeup,Workflow,DesignSync,EnterWorktree,ExitWorktree,SendMessage,Monitor,ListAgents,ReportFindings"

    /// Comando da eseguire nella cartella del progetto (la richiesta arriva da stdin). Solo per Codex e Claude Code.
    public static func command(selection: ModelSelection, mode: CodeMode, folder: URL, resume: String?) -> String {
        if Engine(selection.provider) == .claude {
            // Configurazione personale esclusa (hook, plugin, permessi automatici); i comandi girano nel recinto di Claude Code
            // (scrittura solo nella cartella, rete solo con il permesso) e sono approvati da soli, come in Codex.
            var command = "cd \(Shell.quote(folder.path)) && \(ClaudeCLI.command) -p --output-format stream-json --verbose --permission-prompts none"
            command += " --setting-sources project,local --strict-mcp-config --disallowedTools \(Shell.quote(claudeExcludedTools))"
            command += " --permission-mode \(mode == .plan ? "plan" : "acceptEdits")"
            if mode == .edit { command += " --settings " + Shell.quote(#"{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}"#) }
            command += ExternalAgent.claudeModelArguments(model: selection.model, effort: selection.effort)
            if let resume { command += " --resume \(Shell.quote(resume))" }
            return command
        }
        // Configurazione dell'utente esclusa: niente plugin (es. controllo del computer) né skill estranee al progetto; l'accesso resta.
        var command = "cd \(Shell.quote(folder.path)) && codex exec --json --skip-git-repo-check --ignore-user-config --color never -s \(mode == .plan ? "read-only" : "workspace-write")"
        command += ExternalAgent.codexModelArguments(model: selection.model, effort: selection.effort)
        if let resume { command += " resume \(Shell.quote(resume))" }
        command += " -"
        return command
    }

    public struct Outcome: Sendable {
        public var sessionID: String?
        public var ok: Bool
        public var error: String?

        public init(sessionID: String? = nil, ok: Bool, error: String? = nil) { self.sessionID = sessionID; self.ok = ok; self.error = error }
    }

    /// Esegue una richiesta e manda gli eventi man mano (anche aggiornamenti dello stesso evento, con la stessa `key`).
    /// - Parameters:
    ///   - local: il modello sul Mac, per Apple Intelligence, Gemma e ds4 (per le CLI: nil).
    ///   - history: scambi precedenti della sessione, per l'agente dell'app (le CLI riprendono la loro sessione con `resume`).
    public static func run(selection: ModelSelection, mode: CodeMode, folder: URL, prompt: String, resume: String?,
                           local: LocalCodeAgent.Model? = nil, history: [ChatTurn] = [], checkPage: PageChecker? = nil,
                           onEvent: @escaping @Sendable (CodeEvent) -> Void) async -> Outcome {
        // La chat di programmazione risponde nella lingua in cui si scrive, se chi la avvia non l'ha già scelta.
        guard Language.scoped == nil else {
            return await perform(selection: selection, mode: mode, folder: folder, prompt: prompt, resume: resume,
                                 local: local, history: history, checkPage: checkPage, onEvent: onEvent)
        }
        return await Language.$scoped.withValue(Language.detect(prompt, fallback: .system)) {
            await perform(selection: selection, mode: mode, folder: folder, prompt: prompt, resume: resume,
                          local: local, history: history, checkPage: checkPage, onEvent: onEvent)
        }
    }

    private static func perform(selection: ModelSelection, mode: CodeMode, folder: URL, prompt: String, resume: String?,
                                local: LocalCodeAgent.Model?, history: [ChatTurn], checkPage: PageChecker?,
                                onEvent: @escaping @Sendable (CodeEvent) -> Void) async -> Outcome {
        let engine = Engine(selection.provider)
        if engine == .local {
            guard let local else { return Outcome(ok: false, error: Language.t("\(selection.provider.name) non è pronto.", "\(selection.provider.name) isn't ready.")) }
            return await LocalCodeAgent.run(model: local, mode: mode, folder: folder, prompt: prompt, history: history,
                                            checkPage: checkPage, onEvent: onEvent)
        }
        let input = FileManager.default.temporaryDirectory.appending(path: "code-\(UUID().uuidString).txt")
        let text = (mode == .plan ? planPreamble : "") + prompt
        do { try text.write(to: input, atomically: true, encoding: .utf8) } catch { return Outcome(ok: false, error: error.localizedDescription) }
        defer { try? FileManager.default.removeItem(at: input) }
        let parser = CodeStreamParser(engine: engine)
        let result = await Shell.run(command(selection: selection, mode: mode, folder: folder, resume: resume), timeout: 3600, input: input) { line in
            for event in parser.parse(line) { onEvent(event) }
        }
        let session = parser.sessionID
        if Task.isCancelled { return Outcome(sessionID: session, ok: false, error: interrupted) }
        if result.status == 0, parser.sawResult || engine == .codex { return Outcome(sessionID: session, ok: !parser.failed, error: parser.errorText) }
        if engine == .claude {
            let problem = ClaudeCLI.problem(in: (parser.errorText.map { $0 + "\n" } ?? "") + result.output.suffix(400))
            return Outcome(sessionID: session, ok: false, error: problem.localizedDescription)
        }
        var message = parser.errorText ?? String(result.output.suffix(400))
        if result.output.contains("command not found") {
            message = Language.t("Codex non è installato: installalo in Impostazioni › Modelli.", "Codex isn't installed: install it in Settings › Models.")
        } else if result.output.lowercased().contains("login") || result.output.contains("401") {
            message = Language.t("Serve l'accesso a ChatGPT: accedi in Impostazioni › Modelli.", "You need to sign in to ChatGPT: sign in from Settings › Models.")
        }
        return Outcome(sessionID: session, ok: false, error: message)
    }
}

/// Traduce le righe JSON di Codex o di Claude Code in eventi della chat.
public final class CodeStreamParser: @unchecked Sendable {
    private let lock = NSLock()
    private let engine: CodeAgent.Engine
    /// Lingua della richiesta: le righe arrivano dalla shell, fuori dal suo ambito.
    private let language: Language
    private var _session: String?
    private var _sawResult = false
    private var _failed = false
    private var _error: String?
    /// Claude Code: strumenti in corso (id → evento), per aggiornarli quando arriva il risultato.
    private var pending: [String: CodeEvent] = [:]
    /// Claude Code: la lista delle cose da fare (TaskCreate/TaskUpdate) e il numero di ogni attività.
    private var todos: [CodeTodo] = []
    private var todoNumbers: [String: Int] = [:]

    public init(engine: CodeAgent.Engine = .codex, language: Language = .current) { self.engine = engine; self.language = language }

    public var sessionID: String? { lock.withLock { _session } }
    var sawResult: Bool { lock.withLock { _sawResult } }
    var failed: Bool { lock.withLock { _failed } }
    var errorText: String? { lock.withLock { _error } }

    public func parse(_ line: String) -> [CodeEvent] {
        guard let json = try? JSONValue.parse(Data(line.utf8)) else { return [] }
        return Language.$scoped.withValue(language) { lock.withLock { engine == .claude ? claude(json) : codex(json) } }
    }

    /// Fine del lavoro: la chat lo nasconde (lo sostituisce il riepilogo dei file), per questo resta uguale in ogni lingua.
    static let done = "Fatto"
    static var todoTitle: String { Language.t("Lista delle cose da fare", "To-do list") }
    static var created: String { Language.t("Crea", "Create") }
    static var edited: String { Language.t("Modifica", "Edit") }
    /// Claude Code sta scrivendo un file: quando finisce si sa se l'ha creato o modificato.
    static var writing: String { Language.t("Scrive", "Write") }
    static var webSearch: String { Language.t("Cerca sul web: ", "Web search: ") }

    // MARK: Codex

    private func codex(_ json: JSONValue) -> [CodeEvent] {
        let type = json["type"]?.string ?? ""
        if type == "thread.started", let id = json["thread_id"]?.string { _session = id; return [] }
        if type == "turn.completed" { _sawResult = true; return [CodeEvent(kind: .result, text: Self.done)] }
        if type == "turn.failed" || type == "error" {
            _sawResult = type == "turn.failed"
            _failed = true
            let message = json["error"]?["message"]?.string ?? json["message"]?.string ?? Language.t("Errore", "Error")
            _error = message
            return [CodeEvent(kind: .error, text: message, status: .failed)]
        }
        guard type.hasPrefix("item."), let item = json["item"] else { return [] }
        let key = item["id"]?.string
        let done = type == "item.completed"
        let status: CodeEvent.Status = item["status"]?.string == "failed" ? .failed : (done ? .ok : .running)
        switch item["type"]?.string {
        case "agent_message":
            guard done, let text = item["text"]?.string else { return [] }
            return [CodeEvent(key: key, kind: .text, text: text)]
        case "reasoning":
            guard done, let text = item["text"]?.string, !text.isEmpty else { return [] }
            return [CodeEvent(key: key, kind: .thinking, text: text)]
        case "command_execution":
            var event = CodeEvent(key: key, kind: .command, text: Self.unwrapShell(item["command"]?.string ?? ""), detail: String((item["aggregated_output"]?.string ?? "").suffix(4000)), status: status)
            if let code = item["exit_code"]?.number, code != 0, done { event.status = .failed }
            return [event]
        case "file_change":
            return (item["changes"]?.array ?? []).enumerated().map { index, change in
                let kind = change["kind"]?.string ?? "update"
                return CodeEvent(key: (key ?? "") + "-\(index)", kind: .file,
                                 text: kind == "add" ? Self.created : kind == "delete" ? Language.t("Elimina", "Delete") : Self.edited,
                                 status: status, path: change["path"]?.string)
            }
        case "todo_list":
            let todos = (item["items"]?.array ?? []).map { CodeTodo(text: $0["text"]?.string ?? "", done: $0["completed"] == .bool(true)) }
            return [CodeEvent(key: key, kind: .todo, text: Self.todoTitle, todos: todos)]
        case "mcp_tool_call":
            return [CodeEvent(key: key, kind: .tool, text: "\(item["server"]?.string ?? "") · \(item["tool"]?.string ?? "")", status: status)]
        case "web_search":
            return [CodeEvent(key: key, kind: .tool, text: Self.webSearch + (item["query"]?.string ?? ""), status: status)]
        case "error":
            // Avvisi di configurazione del motore: non sono errori del lavoro.
            let message = item["message"]?.string ?? Language.t("Errore", "Error")
            if ["Under-development features", "Skill descriptions were shortened", "suppress_unstable_features_warning"].contains(where: message.contains) { return [] }
            return [CodeEvent(key: key, kind: .error, text: message, status: .failed)]
        default:
            return []
        }
    }

    // MARK: Claude Code

    private func claude(_ json: JSONValue) -> [CodeEvent] {
        switch json["type"]?.string {
        case "system":
            if json["subtype"]?.string == "init", let id = json["session_id"]?.string { _session = id }
            return []
        case "assistant":
            var events: [CodeEvent] = []
            for block in json["message"]?["content"]?.array ?? [] {
                switch block["type"]?.string {
                case "text":
                    if let text = block["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        events.append(CodeEvent(kind: .text, text: text))
                    }
                case "thinking":
                    if let text = block["thinking"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        events.append(CodeEvent(kind: .thinking, text: text))
                    }
                case "tool_use":
                    events += claudeToolStarted(block)
                default:
                    break
                }
            }
            return events
        case "user":
            return (json["message"]?["content"]?.array ?? []).compactMap(claudeToolFinished)
        case "result":
            _sawResult = true
            if json["is_error"] == .bool(true) || json["subtype"]?.string != "success" {
                _failed = true
                let message = json["result"]?.string ?? json["subtype"]?.string ?? Language.t("Errore", "Error")
                _error = message
                return [CodeEvent(kind: .error, text: message, status: .failed)]
            }
            // Comandi che richiedevano un permesso (fuori dal recinto, rete…): negati, e l'utente deve saperlo.
            let denied = (json["permission_denials"]?.array ?? []).map { denial -> String in
                let input = denial["tool_input"]
                return input?["command"]?.string ?? input?["file_path"]?.string ?? denial["tool_name"]?.string ?? Language.t("azione", "action")
            }
            var events = denied.isEmpty ? [] : [CodeEvent(kind: .error, text: Language.t("Non consentito senza il tuo permesso: ", "Not allowed without your permission: ")
                                                          + denied.prefix(4).joined(separator: " · "), status: .failed)]
            events.append(CodeEvent(kind: .result, text: Self.done))
            return events
        default:
            return []
        }
    }

    private func claudeToolStarted(_ block: JSONValue) -> [CodeEvent] {
        let id = block["id"]?.string ?? UUID().uuidString
        let name = block["name"]?.string ?? ""
        let input = block["input"] ?? .object([:])
        var event: CodeEvent
        switch name {
        case "Bash":
            event = CodeEvent(key: id, kind: .command, text: input["command"]?.string ?? "", status: .running)
        case "Write":
            event = CodeEvent(key: id, kind: .file, text: Self.writing, status: .running, path: input["file_path"]?.string)
        case "Edit", "MultiEdit":
            event = CodeEvent(key: id, kind: .file, text: Self.edited, status: .running, path: input["file_path"]?.string)
        case "NotebookEdit":
            event = CodeEvent(key: id, kind: .file, text: Self.edited, status: .running, path: input["notebook_path"]?.string)
        case "Read":
            event = CodeEvent(key: id, kind: .tool, text: Language.t("Legge ", "Read ")
                              + ((input["file_path"]?.string).map { URL(fileURLWithPath: $0).lastPathComponent } ?? Language.t("un file", "a file")), status: .running)
        case "Glob", "Grep":
            event = CodeEvent(key: id, kind: .tool, text: Language.t("Cerca: ", "Search: ") + (input["pattern"]?.string ?? ""), status: .running)
        case "WebSearch":
            event = CodeEvent(key: id, kind: .tool, text: Self.webSearch + (input["query"]?.string ?? ""), status: .running)
        case "WebFetch":
            event = CodeEvent(key: id, kind: .tool, text: Language.t("Apre ", "Open ") + (input["url"]?.string ?? Language.t("una pagina", "a page")), status: .running)
        case "Task", "Agent":
            event = CodeEvent(key: id, kind: .tool, text: Language.t("Sub-agente: ", "Sub-agent: ")
                              + (input["description"]?.string ?? Language.t("lavoro in parallelo", "parallel work")), status: .running)
        case "TodoWrite":
            todos = (input["todos"]?.array ?? []).map { CodeTodo(text: $0["content"]?.string ?? "", done: $0["status"]?.string == "completed") }
            return [CodeEvent(kind: .todo, text: Self.todoTitle, todos: todos)]
        case "TaskCreate":
            todos.append(CodeTodo(text: input["subject"]?.string ?? input["description"]?.string ?? Language.t("Attività", "Task"), done: false))
            pending[id] = CodeEvent(kind: .todo, text: "\(todos.count - 1)")
            return [CodeEvent(kind: .todo, text: Self.todoTitle, todos: todos)]
        case "TaskUpdate":
            if let number = input["taskId"]?.string ?? input["taskId"]?.number.map({ String(Int($0)) }), let index = todoNumbers[number], todos.indices.contains(index) {
                if let status = input["status"]?.string { todos[index].done = status == "completed" }
                if let subject = input["subject"]?.string { todos[index].text = subject }
                return [CodeEvent(kind: .todo, text: Self.todoTitle, todos: todos)]
            }
            return []
        case "ToolSearch", "Skill", "TaskGet", "TaskList", "TaskStop", "TaskOutput":
            return []
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                event = CodeEvent(key: id, kind: .tool, text: parts.joined(separator: " · "), status: .running)
            } else {
                event = CodeEvent(key: id, kind: .tool, text: name, status: .running)
            }
        }
        pending[id] = event
        return [event]
    }

    private func claudeToolFinished(_ block: JSONValue) -> CodeEvent? {
        guard block["type"]?.string == "tool_result", let id = block["tool_use_id"]?.string, var event = pending.removeValue(forKey: id) else { return nil }
        let output = Self.text(of: block["content"])
        if event.kind == .todo {
            // Risultato di TaskCreate: «Task #3 created…» dà il numero dell'attività.
            if let index = Int(event.text), let range = output.range(of: #"#(\d+)"#, options: .regularExpression) {
                todoNumbers[String(output[range].dropFirst())] = index
            }
            return nil
        }
        event.status = block["is_error"] == .bool(true) ? .failed : .ok
        switch event.kind {
        case .command: event.detail = String(output.suffix(4000))
        case .file where event.text == Self.writing: event.text = output.lowercased().contains("created") ? Self.created : Self.edited
        default: break
        }
        return event
    }

    /// Testo del risultato di uno strumento: stringa o elenco di blocchi di testo.
    static func text(of content: JSONValue?) -> String {
        if let text = content?.string { return text }
        return (content?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
    }

    /// `/bin/zsh -lc "npm run build"` → `npm run build`.
    static func unwrapShell(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where command.hasPrefix(prefix) {
            var inner = String(command.dropFirst(prefix.count))
            if inner.count >= 2, let first = inner.first, first == inner.last, first == "\"" || first == "'" { inner = String(inner.dropFirst().dropLast()) }
            return inner
        }
        return command
    }
}
