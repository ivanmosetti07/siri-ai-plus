import Foundation

/// Configurazione di un server MCP esterno (compatibile con il formato `mcpServers` di Claude Desktop).
public struct MCPServerConfig: Codable, Sendable, Identifiable, Equatable {
    public enum Transport: String, Codable, Sendable, CaseIterable { case stdio, http }

    public var id = UUID()
    public var name: String
    public var transport: Transport
    public var command: String = ""
    public var args: [String] = []
    public var env: [String: String] = [:]
    public var url: String = ""
    public var headers: [String: String] = [:]
    public var enabled = true
    /// Strumenti che l'utente ha scelto di eseguire senza conferma.
    public var alwaysAllow: Set<String> = []

    public init(name: String, transport: Transport) {
        self.name = name; self.transport = transport
    }

    /// Legge `{"mcpServers": {"nome": {"command": …, "args": […], "env": {…}}}}` o `{"url": …}`.
    public static func parseClaudeDesktop(_ json: String) throws -> [MCPServerConfig] {
        let value = try JSONValue.parse(Data(json.utf8))
        let servers = value["mcpServers"]?.object ?? value.object ?? [:]
        return servers.sorted { $0.key < $1.key }.compactMap { name, spec in
            if let url = spec["url"]?.string ?? spec["serverUrl"]?.string {
                var config = MCPServerConfig(name: name, transport: .http)
                config.url = url
                config.headers = (spec["headers"]?.object ?? [:]).compactMapValues(\.string)
                return config
            }
            guard let command = spec["command"]?.string else { return nil }
            var config = MCPServerConfig(name: name, transport: .stdio)
            config.command = command
            config.args = (spec["args"]?.array ?? []).compactMap(\.string)
            config.env = (spec["env"]?.object ?? [:]).compactMapValues(\.string)
            return config
        }
    }
}

public struct MCPToolInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(serverID.uuidString)/\(name)" }
    public let serverID: UUID
    public let serverName: String
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(serverID: UUID, serverName: String, name: String, description: String, inputSchema: JSONValue) {
        self.serverID = serverID; self.serverName = serverName; self.name = name
        self.description = description; self.inputSchema = inputSchema
    }
}

public enum MCPError: LocalizedError {
    case notRunning, timeout, server(String), badResponse, launch(String)
    /// HTTP 401: serve il login OAuth. Contiene l'header `WWW-Authenticate`.
    case unauthorized(String?)

    public var errorDescription: String? {
        switch self {
        case .notRunning: Language.t("Il server MCP non è avviato.", "The MCP server isn't running.")
        case .timeout: Language.t("Il server MCP non ha risposto in tempo.", "The MCP server didn't respond in time.")
        case .server(let m): Language.t("Errore del server MCP: \(m)", "MCP server error: \(m)")
        case .badResponse: Language.t("Risposta del server MCP non valida.", "Invalid response from the MCP server.")
        case .launch(let m): Language.t("Non riesco ad avviare il server MCP: \(m)", "I can't start the MCP server: \(m)")
        case .unauthorized: Language.t("Accesso richiesto", "Sign-in required")
        }
    }
}

/// Connessione JSON-RPC 2.0 a un server MCP, via stdio o HTTP "streamable".
public actor MCPConnection {
    public let config: MCPServerConfig
    public private(set) var tools: [MCPToolInfo] = []
    public private(set) var serverName: String?
    /// Istruzioni che il server dà ai client (come usarne gli strumenti).
    public private(set) var instructions: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    /// Timer di scadenza delle richieste: si annullano appena arriva la risposta.
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var sessionID: String?
    private var stderrTail = ""
    /// Access token OAuth per i server HTTP che lo richiedono.
    private var bearer: String?
    static let protocolVersion = "2025-06-18"

    public init(config: MCPServerConfig, bearer: String? = nil) {
        self.config = config
        self.bearer = bearer
    }

    public func setBearer(_ token: String?) { bearer = token }

    // MARK: Ciclo di vita

    public func start() async throws {
        if config.transport == .stdio { try launch() }
        let result = try await request("initialize", params: .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Siri AI+"), "version": .string("1.0")]),
        ]))
        serverName = result["serverInfo"]?["name"]?.string
        instructions = result["instructions"]?.string
        try await notify("notifications/initialized")
        try await refreshTools()
    }

    public func stop() {
        process?.terminate()
        process = nil
        for continuation in pending.values { continuation.resume(throwing: MCPError.notRunning) }
        pending = [:]
        for timer in timeouts.values { timer.cancel() }
        timeouts = [:]
    }

    public func refreshTools() async throws {
        let result = try await request("tools/list", params: .object([:]))
        tools = (result["tools"]?.array ?? []).compactMap { tool in
            guard let name = tool["name"]?.string else { return nil }
            return MCPToolInfo(serverID: config.id, serverName: config.name, name: name,
                               description: tool["description"]?.string ?? "",
                               inputSchema: tool["inputSchema"] ?? .object(["type": .string("object")]))
        }
    }

    /// Esegue uno strumento e restituisce il testo del risultato.
    public func call(_ tool: String, arguments: JSONValue) async throws -> String {
        let result = try await request("tools/call", params: .object(["name": .string(tool), "arguments": arguments]), timeout: 120)
        let parts = (result["content"]?.array ?? []).map { item -> String in
            switch item["type"]?.string {
            case "text": item["text"]?.string ?? ""
            case "image": Language.t("[immagine]", "[image]")
            case "resource": item["resource"]?["text"]?.string ?? Language.t("[risorsa]", "[resource]")
            default: item.compactString
            }
        }
        let text = parts.joined(separator: "\n")
        if case .bool(true) = result["isError"] ?? .null { throw MCPError.server(text) }
        return text.isEmpty ? result.compactString : text
    }

    // MARK: JSON-RPC

    private func request(_ method: String, params: JSONValue, timeout: Double = 30) async throws -> JSONValue {
        try Task.checkCancellation()
        let id = nextID
        nextID += 1
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
        if config.transport == .http { return try await postHTTP(message, expectID: id) }
        guard let stdin else { throw MCPError.notRunning }
        _ = Self.ignoreBrokenPipe
        return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                // API che lancia errori: con il server chiuso non termina l'app (la vecchia `write(_:)` sollevava un'eccezione ObjC).
                try stdin.write(contentsOf: try message.data() + Data("\n".utf8))
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: MCPError.launch(Language.t("il server non risponde: \(error.localizedDescription)",
                                                                         "the server isn't responding: \(error.localizedDescription)")))
                return
            }
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                await self?.expire(id)
            }
        }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    private func cancelRequest(_ id: Int) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Una pipe chiusa non deve terminare il processo con SIGPIPE.
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    private func expire(_ id: Int) {
        timeouts.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: MCPError.timeout)
    }

    private func notify(_ method: String) async throws {
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "method": .string(method)])
        if config.transport == .http { _ = try? await postHTTP(message, expectID: nil); return }
        try stdin?.write(contentsOf: try message.data() + Data("\n".utf8))
    }

    // MARK: stdio

    private func launch() throws {
        let process = Process()
        // Shell di login: i server lanciati con npx/uvx trovano il PATH dell'utente anche quando l'app parte dal Finder.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let commandLine = ([config.command] + config.args).map(Self.shellQuote).joined(separator: " ")
        process.arguments = ["-lc", "exec \(commandLine)"]
        process.environment = ProcessInfo.processInfo.environment.merging(config.env) { $1 }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.appendStderr(data) }
        }
        process.terminationHandler = { [weak self] _ in Task { await self?.terminated() } }
        do { try process.run() } catch { throw MCPError.launch(error.localizedDescription) }
        self.process = process
        stdin = input.fileHandleForWriting
    }

    private func appendStderr(_ data: Data) {
        stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(600))
    }

    private func terminated() {
        let reason = stderrTail.isEmpty ? Language.t("processo terminato", "process terminated") : stderrTail
        for continuation in pending.values { continuation.resume(throwing: MCPError.launch(reason)) }
        pending = [:]
        for timer in timeouts.values { timer.cancel() }
        timeouts = [:]
        process = nil
        stdin = nil
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let message = try? JSONValue.parse(Data(line)) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSONValue) {
        guard let idNumber = message["id"]?.number, message["method"] == nil else { return }
        let id = Int(idNumber)
        timeouts.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            continuation.resume(throwing: MCPError.server(error["message"]?.string ?? error.compactString))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: HTTP

    private func postHTTP(_ message: JSONValue, expectID: Int?) async throws -> JSONValue {
        guard let url = URL(string: config.url) else { throw MCPError.launch(Language.t("URL non valido", "invalid URL")) }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        for (key, value) in config.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try message.data()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.badResponse }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
        if http.statusCode == 401 { throw MCPError.unauthorized(http.value(forHTTPHeaderField: "WWW-Authenticate")) }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.server("HTTP \(http.statusCode) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        guard let expectID else { return .null }
        let messages: [JSONValue]
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            messages = Self.parseSSE(data)
        } else {
            messages = [try JSONValue.parse(data)]
        }
        guard let reply = messages.first(where: { $0["id"]?.number.map(Int.init) == expectID }) else { throw MCPError.badResponse }
        if let error = reply["error"] { throw MCPError.server(error["message"]?.string ?? error.compactString) }
        return reply["result"] ?? .null
    }

    static func parseSSE(_ data: Data) -> [JSONValue] {
        String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\n\n")
            .compactMap { event in
                let payload = event.split(separator: "\n")
                    .filter { $0.hasPrefix("data:") }
                    .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                    .joined()
                return payload.isEmpty ? nil : try? JSONValue.parse(Data(payload.utf8))
            }
    }
}
