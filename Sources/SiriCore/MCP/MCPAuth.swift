import CryptoKit
import Foundation
import Network

/// Token OAuth di un server MCP remoto.
public struct MCPTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var clientID: String
    public var tokenEndpoint: String
    public var resource: String

    public var isExpired: Bool { expiresAt.map { $0 < Date.now.addingTimeInterval(60) } ?? false }
}

/// Token salvati in `Application Support/<app>/mcp-tokens.json`, leggibile solo dall'utente (0600 fin dalla creazione).
public enum MCPTokenStore {
    private static var url: URL { AppPaths.support("mcp-tokens.json") }
    private static let account = "mcp-tokens"

    /// Token nei segreti dell'app (`Keychain`); il vecchio file viene spostato lì alla prima lettura e poi eliminato.
    private static func all() -> [String: MCPTokens] {
        if let text = Keychain.get(account), let map = try? JSONDecoder().decode([String: MCPTokens].self, from: Data(text.utf8)) { return map }
        guard let data = try? Data(contentsOf: url), let map = try? JSONDecoder().decode([String: MCPTokens].self, from: data) else { return [:] }
        if Keychain.set(String(decoding: data, as: UTF8.self), for: account) { try? FileManager.default.removeItem(at: url) }
        return map
    }

    public static func tokens(for id: UUID) -> MCPTokens? { all()[id.uuidString] }

    public static func save(_ tokens: MCPTokens?, for id: UUID) {
        var map = all()
        map[id.uuidString] = tokens
        guard let data = try? JSONEncoder().encode(map) else { return }
        if Keychain.set(String(decoding: data, as: UTF8.self), for: account) {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Segreti non disponibili (istanze di prova): file temporaneo già a 0600 e poi sostituzione: il contenuto non è mai leggibile da altri.
        let temporary = url.deletingLastPathComponent().appending(path: ".mcp-tokens-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try? FileManager.default.moveItem(at: temporary, to: url)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum MCPAuthError: LocalizedError {
    case discovery, registration(String), cancelled, timeout, denied(String), token(String)

    public var errorDescription: String? {
        switch self {
        case .discovery: "Il server chiede l'accesso ma non indica come autorizzarsi (OAuth)."
        case .registration(let m): "Il server non accetta la registrazione automatica di Siri AI+: \(m)"
        case .cancelled: "Accesso annullato."
        case .timeout: "Accesso non completato: il tempo è scaduto."
        case .denied(let m): "Accesso negato: \(m)"
        case .token(let m): "Non riesco a ottenere il token di accesso: \(m)"
        }
    }
}

/// Autorizzazione OAuth 2.1 dei server MCP remoti (specifica MCP 2025-06-18):
/// metadati della risorsa protetta → server di autorizzazione → registrazione dinamica del client →
/// login nel browser con PKCE e redirect su 127.0.0.1 → scambio del codice e rinnovo dei token.
public enum MCPAuth {
    struct Metadata {
        var authorizationEndpoint: URL
        var tokenEndpoint: URL
        var registrationEndpoint: URL?
        var scopes: [String]
    }

    /// Esegue tutto il flusso. `open` apre la pagina di login nel browser.
    public static func login(serverURL: URL, challenge: String?, clientName: String = "Siri AI+",
                             open: @escaping @Sendable (URL) async -> Void) async throws -> MCPTokens {
        let metadata = try await discover(serverURL: serverURL, challenge: challenge)
        let listener = try LoopbackListener()
        defer { listener.stop() }
        let port = try await listener.start()
        let redirect = "http://127.0.0.1:\(port)/callback"
        let clientID = try await register(metadata, redirect: redirect, name: clientName)

        let verifier = randomString(48)
        let state = randomString(24)
        let challengeCode = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "code_challenge", value: challengeCode),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "resource", value: resource(for: serverURL)),
        ]
        if !metadata.scopes.isEmpty { items.append(.init(name: "scope", value: metadata.scopes.joined(separator: " "))) }
        components.queryItems = items
        await open(components.url!)

        let callback = try await listener.waitForCallback(timeout: 300)
        if let error = callback["error"] { throw MCPAuthError.denied(callback["error_description"] ?? error) }
        guard callback["state"] == state, let code = callback["code"] else { throw MCPAuthError.denied("risposta non valida") }
        return try await requestToken(endpoint: metadata.tokenEndpoint, clientID: clientID, resource: resource(for: serverURL), form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "code_verifier": verifier,
        ])
    }

    /// Rinnova l'access token con il refresh token.
    public static func refresh(_ tokens: MCPTokens) async throws -> MCPTokens {
        guard let refreshToken = tokens.refreshToken, let endpoint = URL(string: tokens.tokenEndpoint) else {
            throw MCPAuthError.token("manca il refresh token")
        }
        var renewed = try await requestToken(endpoint: endpoint, clientID: tokens.clientID, resource: tokens.resource,
                                             form: ["grant_type": "refresh_token", "refresh_token": refreshToken])
        if renewed.refreshToken == nil { renewed.refreshToken = refreshToken }
        return renewed
    }

    // MARK: Scoperta

    static func discover(serverURL: URL, challenge: String?) async throws -> Metadata {
        let origin = URL(string: "\(serverURL.scheme ?? "https")://\(serverURL.host() ?? "")\(serverURL.port.map { ":\($0)" } ?? "")")!
        let path = serverURL.path() == "/" ? "" : serverURL.path()

        var resourceMetadata: JSONValue?
        var candidates: [URL] = []
        if let challenge, let link = parameter("resource_metadata", in: challenge).flatMap(URL.init(string:)) { candidates.append(link) }
        candidates += [URL(string: "/.well-known/oauth-protected-resource\(path)", relativeTo: origin)!.absoluteURL,
                       URL(string: "/.well-known/oauth-protected-resource", relativeTo: origin)!.absoluteURL]
        for url in candidates { if let json = await getJSON(url) { resourceMetadata = json; break } }

        let issuer = resourceMetadata?["authorization_servers"]?.array?.first?.string.flatMap(URL.init(string:)) ?? origin
        let issuerOrigin = URL(string: "\(issuer.scheme ?? "https")://\(issuer.host() ?? "")\(issuer.port.map { ":\($0)" } ?? "")")!
        let issuerPath = issuer.path() == "/" ? "" : issuer.path()
        var server: JSONValue?
        for suffix in ["/.well-known/oauth-authorization-server\(issuerPath)", "/.well-known/openid-configuration\(issuerPath)",
                       "\(issuerPath)/.well-known/openid-configuration"] {
            if let json = await getJSON(URL(string: suffix, relativeTo: issuerOrigin)!.absoluteURL) { server = json; break }
        }

        var scopes: [String] = []
        if let challenge, let scope = parameter("scope", in: challenge) { scopes = scope.split(separator: " ").map(String.init) }
        else if let supported = resourceMetadata?["scopes_supported"]?.array { scopes = supported.compactMap(\.string) }

        if let server, let authorize = server["authorization_endpoint"]?.string.flatMap(URL.init(string:)),
           let token = server["token_endpoint"]?.string.flatMap(URL.init(string:)) {
            return Metadata(authorizationEndpoint: authorize, tokenEndpoint: token,
                            registrationEndpoint: server["registration_endpoint"]?.string.flatMap(URL.init(string:)), scopes: scopes)
        }
        // Server più vecchi (MCP 2025-03-26): percorsi predefiniti sull'origine.
        guard resourceMetadata != nil || challenge != nil else { throw MCPAuthError.discovery }
        return Metadata(authorizationEndpoint: issuerOrigin.appending(path: "authorize"), tokenEndpoint: issuerOrigin.appending(path: "token"),
                        registrationEndpoint: issuerOrigin.appending(path: "register"), scopes: scopes)
    }

    /// Valore di un parametro in un header `WWW-Authenticate: Bearer a="…", b="…"`.
    static func parameter(_ name: String, in header: String) -> String? {
        Web.matches(#"\b"# + name + #"="([^"]*)""#, in: header).first?.first
            ?? Web.matches(#"\b"# + name + #"=([^,\s]+)"#, in: header).first?.first
    }

    static func resource(for serverURL: URL) -> String {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.fragment = nil
        return components.url!.absoluteString
    }

    private static func getJSON(_ url: URL) async -> JSONValue? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MCPConnection.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONValue.parse(data)
    }

    // MARK: Registrazione e token

    private static func register(_ metadata: Metadata, redirect: String, name: String) async throws -> String {
        guard let endpoint = metadata.registrationEndpoint else {
            throw MCPAuthError.registration("manca l'endpoint di registrazione")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONValue.object([
            "client_name": .string(name),
            "redirect_uris": .array([.string(redirect)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
        ]).data()
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), let id = (try? JSONValue.parse(data))?["client_id"]?.string else {
            throw MCPAuthError.registration("HTTP \(code) \(String(decoding: data.prefix(160), as: UTF8.self))")
        }
        return id
    }

    private static func requestToken(endpoint: URL, clientID: String, resource: String, form: [String: String]) async throws -> MCPTokens {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body = URLComponents()
        body.queryItems = (form.merging(["client_id": clientID, "resource": resource]) { a, _ in a })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONValue.parse(data)
        guard (200..<300).contains(code), let access = json?["access_token"]?.string else {
            throw MCPAuthError.token(json?["error_description"]?.string ?? json?["error"]?.string ?? "HTTP \(code)")
        }
        return MCPTokens(accessToken: access, refreshToken: json?["refresh_token"]?.string,
                         expiresAt: json?["expires_in"]?.number.map { Date.now.addingTimeInterval($0) },
                         clientID: clientID, tokenEndpoint: endpoint.absoluteString, resource: resource)
    }

    static func randomString(_ bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Mini server HTTP su 127.0.0.1 che riceve il redirect del login OAuth.
final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Siri AI+.oauth")
    private var callback: CheckedContinuation<[String: String], Error>?
    private var received: [String: String]?
    private var ready: CheckedContinuation<UInt16, Error>?
    private let lock = NSLock()

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            lock.lock()
            ready = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.lock.lock()
                let pending = self.ready
                if case .ready = state { self.ready = nil }
                if case .failed = state { self.ready = nil }
                self.lock.unlock()
                switch state {
                case .ready: pending?.resume(returning: self.listener.port?.rawValue ?? 0)
                case .failed(let error): pending?.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        finish(.failure(MCPAuthError.cancelled))
    }

    func waitForCallback(timeout: Double) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let received {
                lock.unlock()
                continuation.resume(returning: received)
                return
            }
            callback = continuation
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(MCPAuthError.timeout)) }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        let continuation = callback
        callback = nil
        if case .success(let values) = result, continuation == nil { received = values }
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard target.hasPrefix("/callback"), let components = URLComponents(string: "http://127.0.0.1\(target)") else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            var values: [String: String] = [:]
            for item in components.queryItems ?? [] { values[item.name] = item.value ?? "" }
            let ok = values["error"] == nil
            let html = """
            <!doctype html><html lang="it"><meta charset="utf-8"><title>Siri AI+</title>
            <body style="font-family:-apple-system,system-ui;display:flex;align-items:center;justify-content:center;height:90vh;background:#f5f5f7;color:#1d1d1f">
            <div style="text-align:center"><div style="font-size:44px">\(ok ? "✓" : "✕")</div>
            <h2>\(ok ? "Accesso completato" : "Accesso non riuscito")</h2>
            <p>\(ok ? "Puoi chiudere questa pagina e tornare a Siri AI+." : "Torna a Siri AI+ e riprova.")</p></div></body></html>
            """
            let body = Data(html.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            self?.finish(.success(values))
        }
    }
}
