import AppKit
import Foundation
import Observation
import SiriCore

/// Server MCP configurati, connessioni attive e strumenti disponibili.
@MainActor @Observable
final class MCPRegistry {
    enum Status: Equatable {
        case off, connecting, ready(Int), failed(String)
        /// Il server remoto richiede il login OAuth nel browser.
        case needsLogin, loggingIn

        var label: String {
            switch self {
            case .off: String(localized: "Disattivato")
            case .connecting: String(localized: "Connessione…")
            case .needsLogin: String(localized: "Accesso richiesto")
            case .loggingIn: String(localized: "In attesa del login nel browser…")
            case .ready(let n): n == 1 ? String(localized: "1 strumento") : String(localized: "\(n) strumenti")
            case .failed(let message): message
            }
        }
    }

    private(set) var servers: [MCPServerConfig] = []
    private(set) var status: [UUID: Status] = [:]
    private(set) var tools: [UUID: [MCPToolInfo]] = [:]
    /// Istruzioni inviate dai server all'avvio, per nome del server.
    private(set) var instructions: [String: String] = [:]
    private var connections: [UUID: MCPConnection] = [:]
    /// Ultimo header `WWW-Authenticate` ricevuto: indica dove autorizzarsi.
    private var challenges: [UUID: String] = [:]
    private var logins: [UUID: Task<Void, Never>] = [:]

    private static var url: URL {
        AppPaths.support("mcp.json")
    }

    /// Tentativo di connessione più recente per server: quelli superati vengono chiusi (niente processi orfani).
    private var generation: [UUID: Int] = [:]

    init() {
        if let data = try? Data(contentsOf: Self.url) {
            servers = (try? JSONDecoder().decode([MCPServerConfig].self, from: data)) ?? []
        }
    }

    var allTools: [MCPToolInfo] { servers.filter(\.enabled).flatMap { tools[$0.id] ?? [] } }

    func startAll() {
        for server in servers where server.enabled { connect(server.id) }
    }

    /// - Parameter interactive: se il server chiede l'accesso, apre subito il login nel browser
    ///   (solo quando è l'utente ad aggiungere o riconnettere il server, non all'avvio).
    func connect(_ id: UUID, interactive: Bool = false, attempt: Int = 0) {
        guard let config = servers.first(where: { $0.id == id }) else { return }
        disconnect(id)
        status[id] = .connecting
        let attemptID = (generation[id] ?? 0) + 1
        generation[id] = attemptID
        Task {
            do {
                try await open(config, attempt: attemptID)
                guard generation[id] == attemptID else { return }
                Agent.log("MCP \(config.name): collegato (\(tools[id]?.count ?? 0) strumenti)")
            } catch MCPError.unauthorized(let challenge) {
                guard generation[id] == attemptID else { return }
                Agent.log("MCP \(config.name): accesso richiesto (token \(MCPTokenStore.tokens(for: id) == nil ? "assente" : "presente"))")
                challenges[id] = challenge
                tools[id] = []
                if interactive { login(id) } else { status[id] = .needsLogin }
            } catch {
                guard generation[id] == attemptID else { return }
                Agent.log("MCP \(config.name): errore \(error)")
                status[id] = .failed(error.localizedDescription)
                tools[id] = []
                // All'avvio la rete può non essere ancora pronta: si riprova da soli.
                retry(id, attempt: attempt)
            }
        }
    }

    private func retry(_ id: UUID, attempt: Int) {
        guard attempt < 4 else { return }
        let delay = [5.0, 15.0, 45.0, 120.0][attempt]
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard servers.first(where: { $0.id == id })?.enabled == true, case .failed = status[id] ?? .off else { return }
            connect(id, attempt: attempt + 1)
        }
    }

    /// Ricollega i connettori rimasti in errore (per esempio quando l'app torna attiva o la rete riparte).
    func reconnectFailed() {
        for server in servers where server.enabled {
            if case .failed = status[server.id] ?? .off { connect(server.id) }
        }
    }

    /// Avvia la connessione con il token salvato (rinnovandolo se scaduto o rifiutato).
    private func open(_ config: MCPServerConfig, attempt: Int) async throws {
        var tokens = config.transport == .http ? MCPTokenStore.tokens(for: config.id) : nil
        if let current = tokens, current.isExpired, let renewed = try? await MCPAuth.refresh(current) {
            tokens = renewed
            MCPTokenStore.save(renewed, for: config.id); loginCache[config.id] = renewed != nil
        }
        do {
            try await start(config, bearer: tokens?.accessToken, attempt: attempt)
        } catch MCPError.unauthorized(let challenge) {
            // Il token resta salvato: si chiede un nuovo login solo se il server lo rifiuta davvero.
            guard let current = tokens, let renewed = try? await MCPAuth.refresh(current) else {
                throw MCPError.unauthorized(challenge)
            }
            MCPTokenStore.save(renewed, for: config.id); loginCache[config.id] = renewed != nil
            try await start(config, bearer: renewed.accessToken, attempt: attempt)
        }
    }

    private func start(_ config: MCPServerConfig, bearer: String?, attempt: Int) async throws {
        let connection = MCPConnection(config: config, bearer: bearer)
        do {
            try await connection.start()
        } catch {
            await connection.stop()
            throw error
        }
        // Nel frattempo è partita un'altra connessione (o il server è stato scollegato): questa si chiude.
        guard generation[config.id] == attempt else {
            await connection.stop()
            return
        }
        if let old = connections[config.id] { Task { await old.stop() } }
        connections[config.id] = connection
        let found = await connection.tools
        instructions[config.name] = await connection.instructions
        tools[config.id] = found
        status[config.id] = .ready(found.count)
    }

    /// Login OAuth: apre la pagina di accesso del servizio nel browser predefinito e attende il ritorno.
    func login(_ id: UUID) {
        guard let config = servers.first(where: { $0.id == id }), let url = URL(string: config.url) else { return }
        logins[id]?.cancel()
        status[id] = .loggingIn
        let challenge = challenges[id]
        logins[id] = Task {
            do {
                let tokens = try await MCPAuth.login(serverURL: url, challenge: challenge) { page in
                    await MainActor.run { _ = NSWorkspace.shared.open(page) }
                }
                MCPTokenStore.save(tokens, for: id); loginCache[id] = tokens != nil
                NSApp.activate()
                logins[id] = nil
                connect(id)
            } catch {
                logins[id] = nil
                status[id] = .failed(error.localizedDescription)
            }
        }
    }

    func cancelLogin(_ id: UUID) {
        logins.removeValue(forKey: id)?.cancel()
        status[id] = .needsLogin
    }

    /// C'è un accesso salvato? Letto una volta sola dai segreti dell'app (mai durante il disegno di ogni scheda).
    func hasLogin(_ id: UUID) -> Bool {
        if let cached = loginCache[id] { return cached }
        let value = MCPTokenStore.tokens(for: id) != nil
        loginCache[id] = value
        return value
    }

    @ObservationIgnored private var loginCache: [UUID: Bool] = [:]

    /// Dimentica il token: al prossimo collegamento servirà un nuovo login.
    func logout(_ id: UUID) {
        MCPTokenStore.save(nil, for: id); loginCache[id] = false
        disconnect(id)
        status[id] = .needsLogin
    }

    /// Attende che i connettori attivi finiscano di avviarsi (o il timeout).
    func waitUntilReady(timeout: Double = 20) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline, servers.contains(where: { $0.enabled && status[$0.id] == .connecting }) {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    func disconnect(_ id: UUID) {
        generation[id] = (generation[id] ?? 0) + 1
        if let connection = connections.removeValue(forKey: id) { Task { await connection.stop() } }
        tools[id] = []
        status[id] = .off
    }

    func save(_ config: MCPServerConfig) {
        if let index = servers.firstIndex(where: { $0.id == config.id }) { servers[index] = config } else { servers.append(config) }
        persist()
        if config.enabled { connect(config.id, interactive: true) } else { disconnect(config.id) }
    }

    func remove(_ id: UUID) {
        disconnect(id)
        MCPTokenStore.save(nil, for: id); loginCache[id] = false
        servers.removeAll { $0.id == id }
        status.removeValue(forKey: id)
        persist()
    }

    func setAlwaysAllow(_ tool: MCPToolInfo, _ allow: Bool) {
        guard let index = servers.firstIndex(where: { $0.id == tool.serverID }) else { return }
        if allow { servers[index].alwaysAllow.insert(tool.name) } else { servers[index].alwaysAllow.remove(tool.name) }
        persist()
    }

    func isAlwaysAllowed(_ tool: MCPToolInfo) -> Bool {
        servers.first { $0.id == tool.serverID }?.alwaysAllow.contains(tool.name) == true
    }

    /// Importa server dal formato `mcpServers` di Claude Desktop. Restituisce quanti ne ha aggiunti.
    func importClaudeDesktop(_ json: String) throws -> Int {
        let parsed = try MCPServerConfig.parseClaudeDesktop(json)
        let new = parsed.filter { config in !servers.contains(where: { $0.name == config.name }) }
        for config in new { save(config) }
        return new.count
    }

    func call(_ tool: MCPToolInfo, arguments: JSONValue) async throws -> String {
        guard let connection = connections[tool.serverID] else { throw MCPError.notRunning }
        do {
            return try await connection.call(tool.name, arguments: arguments)
        } catch MCPError.unauthorized(let challenge) {
            // Token scaduto durante la sessione: rinnovo e riprovo una volta.
            if let tokens = MCPTokenStore.tokens(for: tool.serverID), let renewed = try? await MCPAuth.refresh(tokens) {
                MCPTokenStore.save(renewed, for: tool.serverID); loginCache[tool.serverID] = renewed != nil
                await connection.setBearer(renewed.accessToken)
                return try await connection.call(tool.name, arguments: arguments)
            }
            challenges[tool.serverID] = challenge
            status[tool.serverID] = .needsLogin
            throw MCPError.server(String(localized: "serve un nuovo accesso a \(tool.serverName): aprilo in Connettori e premi «Accedi»."))
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) { try? data.write(to: Self.url, options: .atomic) }
    }
}
