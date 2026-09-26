import Foundation

/// Modelli esterni che usano gli strumenti dell'app: Gemma e ds4 con il tool calling OpenAI,
/// ChatGPT (Codex CLI) e Claude (Claude Code) con il ponte MCP.
public enum ExternalAgent {
    /// Chiamata a uno strumento: nome, argomenti → testo per il modello.
    public typealias ToolCall = @MainActor @Sendable (String, JSONValue) async -> String
    /// Testo scritto finora nel giro in corso (nil quando il giro finisce e si passa agli strumenti).
    public typealias TextUpdate = @MainActor @Sendable (String?) -> Void
    public typealias StatusUpdate = @MainActor @Sendable (String) -> Void

    static let toolGuide = """
    Hai a disposizione gli strumenti dell'app sul Mac dell'utente: usali quando servono dati reali (calendario, promemoria, email, note, \
    file del progetto, web, connettori) invece di rispondere a memoria. Ciò che crea, modifica o invia qualcosa prepara solo una scheda \
    che l'utente conferma: non dire che è già fatto, di' che è pronto da confermare. Non inventare dati che gli strumenti non hanno restituito.
    """

    // MARK: Gemma e ds4 (server compatibile OpenAI, tool calling)

    /// Giri di conversazione con gli strumenti finché il modello risponde senza chiamarne altri (al massimo `maxRounds`).
    public static func openAI(base: URL, model: String, system: String, history: [ChatTurn], prompt: String, tools: [ToolSpec],
                              maxRounds: Int = 6, thinking: Bool = false, call: ToolCall, onText: @escaping TextUpdate,
                              onStatus: @escaping StatusUpdate) async throws -> String {
        var messages = ExternalEngine.messages(system: system + "\n" + toolGuide, history: history, prompt: prompt).array ?? []
        var final = ""
        let name = model == "gemma" ? "Gemma" : "ds4"
        for round in 0..<maxRounds {
            try Task.checkCancellation()
            var body: [String: JSONValue] = ["model": .string(model), "stream": .bool(true), "messages": .array(messages)]
            if !tools.isEmpty, round < maxRounds - 1 { body["tools"] = .array(tools.map(\.openAI)) }
            if thinking { body["chat_template_kwargs"] = ExternalEngine.thinkingOption }
            var request = URLRequest(url: base.appending(path: "v1/chat/completions"), timeoutInterval: 900)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONValue.object(body).data()
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EngineError.unavailable("Il modello locale non risponde.") }
            var text = ""
            var reasoning = false
            var calls: [Int: (id: String, name: String, arguments: String)] = [:]
            for try await line in bytes.lines where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let json = try? JSONValue.parse(Data(payload.utf8)), let delta = json["choices"]?.array?.first?["delta"] else { continue }
                if !reasoning, delta["reasoning_content"]?.string?.isEmpty == false {
                    reasoning = true
                    await onStatus("\(name) sta ragionando…")
                }
                if let piece = delta["content"]?.string, !piece.isEmpty {
                    text += piece
                    await onText(text)
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
            final = text
            // Modelli piccoli: a volte scrivono la chiamata come testo ("[tool_call] agenda(dal=…)"): la si esegue lo stesso.
            if calls.isEmpty, let parsed = textualToolCalls(in: text, known: Set(tools.map(\.name))), !parsed.calls.isEmpty {
                text = parsed.before
                await onText(text.isEmpty ? nil : text)
                for (index, call) in parsed.calls.enumerated() { calls[index] = (id: "", name: call.name, arguments: call.arguments) }
            }
            guard !calls.isEmpty else { return text }
            await onText(nil)
            let ordered = calls.sorted { $0.key < $1.key }.map(\.value)
            messages.append(.object([
                "role": .string("assistant"), "content": text.isEmpty ? .null : .string(text),
                "tool_calls": .array(ordered.enumerated().map { index, call in
                    .object(["id": .string(call.id.isEmpty ? "call_\(round)_\(index)" : call.id), "type": .string("function"),
                             "function": .object(["name": .string(call.name), "arguments": .string(call.arguments.isEmpty ? "{}" : call.arguments)])])
                }),
            ]))
            for (index, toolCall) in ordered.enumerated() {
                await onStatus("\(name) usa «\(toolCall.name)»…")
                let arguments = (try? JSONValue.parse(Data(toolCall.arguments.utf8))) ?? .object([:])
                let result = await call(toolCall.name, arguments)
                messages.append(.object(["role": .string("tool"), "tool_call_id": .string(toolCall.id.isEmpty ? "call_\(round)_\(index)" : toolCall.id),
                                         "content": .string(result)]))
            }
        }
        return final
    }

    /// Chiamate scritte come testo: `[tool_call] nome(a="x", b=2) [/tool_call]`, blocchi ```tool_code```, `nome({...})`.
    static func textualToolCalls(in text: String, known: Set<String>) -> (before: String, calls: [(name: String, arguments: String)])? {
        let pattern = #"(?s)(?:\[tool_call\]|```(?:tool_code|tool_call|python)?)\s*([A-Za-z_][A-Za-z0-9_\-]*)\s*\((.*?)\)\s*(?:\[/tool_call\]|```)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var calls: [(String, String)] = []
        for match in matches {
            let name = ns.substring(with: match.range(at: 1))
            guard known.contains(name) else { continue }
            let raw = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("{") { calls.append((name, raw)); continue }
            // key="valore", key='valore', key=123, key=[…]
            var object: [String: JSONValue] = [:]
            let argument = try? NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|\[[^\]]*\]|[^,\)]+)"#)
            let rawNS = raw as NSString
            for item in argument?.matches(in: raw, range: NSRange(location: 0, length: rawNS.length)) ?? [] {
                let key = rawNS.substring(with: item.range(at: 1))
                if item.range(at: 3).location != NSNotFound { object[key] = .string(rawNS.substring(with: item.range(at: 3))) }
                else if item.range(at: 4).location != NSNotFound { object[key] = .string(rawNS.substring(with: item.range(at: 4))) }
                else {
                    let value = rawNS.substring(with: item.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    if let parsed = try? JSONValue.parse(Data(value.utf8)) { object[key] = parsed } else { object[key] = .string(value) }
                }
            }
            calls.append((name, (try? JSONValue.object(object).data()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"))
        }
        guard let first = matches.first, !calls.isEmpty else { return jsonToolCalls(in: text, known: known) }
        let before = ns.substring(to: first.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        return (before, calls.map { (name: $0.0, arguments: $0.1) })
    }

    /// Chiamate scritte come oggetti JSON (Gemma lo fa spesso, anche dentro ```json): {"tool_name": "scrivi_file",
    /// "params": {…}}, {"name": …, "arguments": …}, {"function": {"name": …, "arguments": "{…}"}}, <tool_call>{…}</tool_call>.
    static func jsonToolCalls(in text: String, known: Set<String>) -> (before: String, calls: [(name: String, arguments: String)])? {
        var calls: [(name: String, arguments: String)] = []
        var firstStart: String.Index?
        for (range, object) in jsonObjects(in: text) {
            let function = object["function"]
            let name = [object["tool_name"], object["name"], object["tool"], function?["name"], function].compactMap { $0?.string }.first
            guard let name, known.contains(name) else { continue }
            let raw = [object["arguments"], object["params"], object["parameters"], object["args"], object["input"], function?["arguments"]]
                .compactMap { $0 }.first ?? .object([:])
            // Gli argomenti possono arrivare come testo JSON.
            let arguments = raw.string.flatMap { try? JSONValue.parse(Data($0.utf8)) } ?? raw
            guard arguments.object != nil else { continue }
            calls.append((name, arguments.compactString))
            if firstStart == nil { firstStart = range.lowerBound }
        }
        guard let firstStart, !calls.isEmpty else { return nil }
        var before = String(text[..<firstStart])
        // Il recinto ```json (o <tool_call>) aperto prima della chiamata non resta a metà nel testo.
        if let fence = before.range(of: #"(?:```[A-Za-z]*|<tool_call>)\s*$"#, options: .regularExpression) { before.removeSubrange(fence) }
        return (before.trimmingCharacters(in: .whitespacesAndNewlines), calls)
    }

    /// A capo e tabulazioni dentro le stringhe JSON diventano `\n` e `\t`.
    static func escapingControlCharacters(_ text: Substring) -> String {
        var result = ""
        var inString = false
        var escaped = false
        for character in text {
            guard inString else {
                if character == "\"" { inString = true }
                result.append(character)
                continue
            }
            if escaped {
                escaped = false
                result.append(character)
                continue
            }
            switch character {
            case "\\": escaped = true; result.append(character)
            case "\"": inString = false; result.append(character)
            case "\n", "\r\n", "\r": result += "\\n"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result
    }

    /// Gli oggetti JSON di primo livello in un testo (parentesi bilanciate, stringhe e caratteri di escape rispettati).
    static func jsonObjects(in text: String) -> [(range: Range<String.Index>, object: JSONValue)] {
        var result: [(Range<String.Index>, JSONValue)] = []
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaped = false
            var cursor = open
            var close: String.Index?
            while cursor < text.endIndex {
                let character = text[cursor]
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { close = cursor; break }
                }
                cursor = text.index(after: cursor)
            }
            guard let close else { break }
            let range = open..<text.index(after: close)
            let candidate = text[range]
            // I modelli piccoli a volte lasciano a capo veri dentro le stringhe (non validi in JSON): si riprova con gli escape.
            if let value = (try? JSONValue.parse(Data(candidate.utf8))) ?? (try? JSONValue.parse(Data(escapingControlCharacters(candidate).utf8))),
               value.object != nil {
                result.append((range, value))
                index = range.upperBound
            } else {
                index = text.index(after: open)
            }
        }
        return result
    }

    // MARK: ChatGPT (Codex CLI) e Claude (Claude Code) con il ponte MCP

    /// Il ponte: la CLI dell'app come server MCP, collegata al gateway locale.
    public struct Bridge: Sendable {
        public let helper: String
        public let gateway: URL
        public let token: String

        public init(helper: String, gateway: URL, token: String) { self.helper = helper; self.gateway = gateway; self.token = token }
    }

    static func transcript(system: String, history: [ChatTurn], prompt: String, tools: Bool) -> String {
        let conversation = history.map { "\($0.role == .user ? "Utente" : "Assistente"): \($0.text)" }.joined(separator: "\n\n")
        return "\(system)\n\n" + (tools ? toolGuide + " Gli strumenti sono quelli del server MCP «siriai»; non usare la shell né modificare file direttamente.\n\n" : "")
            + (conversation.isEmpty ? "" : "Conversazione precedente:\n\(conversation)\n\n") + "Richiesta:\n\(prompt)"
            + (tools ? "" : "\n\nRispondi solo con il testo della risposta, senza usare strumenti né modificare file.")
    }

    /// ChatGPT con l'abbonamento: `codex exec --json`, eventi letti man mano (messaggi e chiamate agli strumenti).
    /// Senza la configurazione personale di Codex (plugin, connettori, notifiche del controllo del computer):
    /// modello e ragionamento arrivano dalla scelta fatta nella chat.
    public static func codex(system: String, history: [ChatTurn], prompt: String, bridge: Bridge?, model: String? = nil, effort: String? = nil,
                             onText: @escaping TextUpdate, onStatus: @escaping StatusUpdate) async throws -> String {
        // Con lo scudo della chat: a ChatGPT arrivano solo i segnaposto, il testo che torna è di nuovo leggibile.
        if let shield = PrivacyShield.current {
            let started = Date.now
            var (system, history, prompt) = try await shield.protect(system: system, history: history, prompt: prompt)
            system = PrivacyShield.modelRule + "\n\n" + system
            // Nel registro solo il testo anonimizzato (è quello che parte): serve a verificare cosa riceve il modello.
            Agent.log("ANONIMIZZATO in \(String(format: "%.1f", Date.now.timeIntervalSince(started))) s → \(shield.destination): "
                + prompt.prefix(240).replacingOccurrences(of: "\n", with: " "))
            let raw = try await PrivacyShield.$current.withValue(nil) {
                try await codex(system: system, history: history, prompt: prompt, bridge: bridge, model: model, effort: effort,
                                onText: { @MainActor text in onText(text.map { shield.revealStreaming($0) }) }, onStatus: onStatus)
            }
            return shield.learn(anonymized: raw)
        }
        let input = FileManager.default.temporaryDirectory.appending(path: "codex-\(UUID().uuidString).txt")
        try transcript(system: system, history: history, prompt: prompt, tools: bridge != nil).write(to: input, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: input) }
        var command = "cd \"$TMPDIR\" && codex exec --skip-git-repo-check --ephemeral --ignore-user-config -s read-only --color never --json"
        command += codexModelArguments(model: model, effort: effort)
        if let bridge {
            let env = "{SIRIAI_GATEWAY=\"\(bridge.gateway.absoluteString)\",SIRIAI_TOKEN=\"\(bridge.token)\"}"
            command += " -c " + Shell.quote("mcp_servers.siriai.command=\"\(bridge.helper)\"")
            command += " -c " + Shell.quote("mcp_servers.siriai.args=[\"--mcp-bridge\"]")
            command += " -c " + Shell.quote("mcp_servers.siriai.env=\(env)")
            command += " -c " + Shell.quote("mcp_servers.siriai.tool_timeout_sec=600")
            command += " -c " + Shell.quote("mcp_servers.siriai.default_tools_approval_mode=\"approve\"")
        }
        command += " -"
        let collector = LineCollector()
        let result = await Shell.run(command, timeout: 900, input: input) { line in
            guard let event = try? JSONValue.parse(Data(line.utf8)), let item = event["item"] else { return }
            let type = item["type"]?.string ?? ""
            if event["type"]?.string == "item.completed", type == "agent_message", let text = item["text"]?.string {
                let all = collector.append(text)
                Task { @MainActor in onText(all) }
            } else if event["type"]?.string == "item.started", type.contains("tool") {
                let tool = item["tool"]?.string ?? item["name"]?.string ?? "uno strumento"
                collector.breakMessage()
                Task { @MainActor in onText(nil); onStatus("ChatGPT usa «\(tool)»…") }
            }
        }
        let text = collector.text
        if !text.isEmpty { return text }
        if result.output.contains("command not found") { throw EngineError.unavailable("La CLI Codex non è installata: installala in Impostazioni › Modelli.") }
        if result.output.lowercased().contains("login") || result.output.contains("401") {
            throw EngineError.unavailable("Accedi con il tuo account ChatGPT in Impostazioni › Modelli.")
        }
        throw EngineError.failed("ChatGPT non ha risposto: \(result.output.suffix(300))")
    }

    /// `-m modello -c model_reasoning_effort=…` (solo se scelti).
    static func codexModelArguments(model: String?, effort: String?) -> String {
        var arguments = ""
        if let model, !model.isEmpty { arguments += " -m " + Shell.quote(model) }
        if let effort, !effort.isEmpty { arguments += " -c " + Shell.quote("model_reasoning_effort=\"\(effort)\"") }
        return arguments
    }

    /// Cartella di lavoro delle chat con Claude: sempre la stessa, vuota (Claude Code tiene le impostazioni per cartella).
    static var claudeFolder: URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "siriai-claude")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Claude con l'abbonamento: `claude -p` in streaming (stream-json), con le istruzioni dell'app al posto di quelle
    /// di Claude Code, senza i suoi strumenti e con quelli dell'app attraverso il ponte MCP.
    public static func claude(system: String, history: [ChatTurn], prompt: String, bridge: Bridge?, model: String? = nil, effort: String? = nil,
                              onText: @escaping TextUpdate, onStatus: @escaping StatusUpdate) async throws -> String {
        // Con lo scudo della chat: a Claude arrivano solo i segnaposto, il testo che torna è di nuovo leggibile.
        if let shield = PrivacyShield.current {
            let started = Date.now
            var (system, history, prompt) = try await shield.protect(system: system, history: history, prompt: prompt)
            system = PrivacyShield.modelRule + "\n\n" + system
            // Nel registro solo il testo anonimizzato (è quello che parte): serve a verificare cosa riceve il modello.
            Agent.log("ANONIMIZZATO in \(String(format: "%.1f", Date.now.timeIntervalSince(started))) s → \(shield.destination): "
                + prompt.prefix(240).replacingOccurrences(of: "\n", with: " "))
            let raw = try await PrivacyShield.$current.withValue(nil) {
                try await claude(system: system, history: history, prompt: prompt, bridge: bridge, model: model, effort: effort,
                                 onText: { @MainActor text in onText(text.map { shield.revealStreaming($0) }) }, onStatus: onStatus)
            }
            return shield.learn(anonymized: raw)
        }
        let folder = claudeFolder
        let id = UUID().uuidString
        let input = folder.appending(path: "richiesta-\(id).txt")
        let instructions = folder.appending(path: "istruzioni-\(id).txt")
        try transcript(system: "", history: history, prompt: prompt, tools: bridge != nil).trimmingCharacters(in: .whitespacesAndNewlines)
            .write(to: input, atomically: true, encoding: .utf8)
        try system.write(to: instructions, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: instructions)
        }
        var command = "cd \(Shell.quote(folder.path)) && MCP_TOOL_TIMEOUT=600000 \(ClaudeCLI.command) -p --output-format stream-json --verbose"
        command += " --include-partial-messages --no-session-persistence --permission-prompts none \(ClaudeCLI.isolation) --tools ''"
        command += claudeModelArguments(model: model, effort: effort)
        command += " --system-prompt \"$(cat \(Shell.quote(instructions.path)))\""
        if let bridge {
            let config = JSONValue.object(["mcpServers": .object(["siriai": .object([
                "type": .string("stdio"), "command": .string(bridge.helper), "args": .array([.string("--mcp-bridge")]),
                "env": .object(["SIRIAI_GATEWAY": .string(bridge.gateway.absoluteString), "SIRIAI_TOKEN": .string(bridge.token)]),
            ])])])
            command += " --mcp-config " + Shell.quote(config.compactString) + " --allowedTools mcp__siriai"
        }
        let collector = LineCollector()
        let failure = LineCollector()
        let result = await Shell.run(command, timeout: 900, input: input) { line in
            guard let event = try? JSONValue.parse(Data(line.utf8)) else { return }
            switch event["type"]?.string {
            case "stream_event":
                let inner = event["event"]
                if inner?["type"]?.string == "content_block_delta", inner?["delta"]?["type"]?.string == "text_delta",
                   let piece = inner?["delta"]?["text"]?.string {
                    let all = collector.appendRaw(piece)
                    Task { @MainActor in onText(all) }
                } else if inner?["type"]?.string == "content_block_start", inner?["content_block"]?["type"]?.string == "tool_use" {
                    let name = inner?["content_block"]?["name"]?.string ?? "uno strumento"
                    let tool = name.hasPrefix("mcp__siriai__") ? String(name.dropFirst("mcp__siriai__".count)) : name
                    collector.breakMessage()
                    Task { @MainActor in onText(nil); onStatus("Claude usa «\(tool)»…") }
                }
            case "result":
                if event["is_error"] == .bool(true) || event["subtype"]?.string != "success" {
                    _ = failure.append(event["result"]?.string ?? event["subtype"]?.string ?? "errore")
                } else if collector.text.isEmpty, let text = event["result"]?.string, !text.isEmpty {
                    let all = collector.append(text)
                    Task { @MainActor in onText(all) }
                }
            default:
                break
            }
        }
        let text = collector.text
        if !text.isEmpty { return text }
        throw ClaudeCLI.problem(in: failure.text.isEmpty ? result.output : failure.text + "\n" + result.output.suffix(300))
    }

    /// `--model alias --effort livello` (solo se scelti).
    static func claudeModelArguments(model: String?, effort: String?) -> String {
        var arguments = ""
        if let model, !model.isEmpty { arguments += " --model " + Shell.quote(model) }
        if let effort, !effort.isEmpty { arguments += " --effort " + Shell.quote(effort) }
        return arguments
    }
}

/// Testo raccolto da più righe di eventi (thread diversi). Ogni chiamata a uno strumento apre un messaggio nuovo.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var done: [String] = []
    private var parts: [String] = []
    private var raw = ""

    /// Un messaggio completo: si aggiunge come paragrafo. Restituisce il testo del messaggio in corso.
    func append(_ text: String) -> String { lock.withLock { parts.append(text); return current } }
    /// Un pezzo di messaggio in streaming.
    func appendRaw(_ piece: String) -> String { lock.withLock { raw += piece; return current } }
    /// Il modello passa a uno strumento: il testo successivo va in un messaggio nuovo.
    func breakMessage() { lock.withLock { if !current.isEmpty { done.append(current) }; parts = []; raw = "" } }
    /// Tutto il testo scritto.
    var text: String { lock.withLock { (done + (current.isEmpty ? [] : [current])).joined(separator: "\n\n") } }
    private var current: String { (parts + (raw.isEmpty ? [] : [raw])).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines) }
}
