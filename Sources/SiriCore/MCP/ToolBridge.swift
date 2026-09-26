import Foundation
import Network

/// Gateway HTTP locale (solo 127.0.0.1, con token) che espone gli strumenti dell'app a un processo esterno.
/// Lo usano ChatGPT (Codex CLI) e Claude (Claude Code) tramite il ponte MCP (`siriai --mcp-bridge`).
public final class ToolGateway: @unchecked Sendable {
    public typealias Handler = @Sendable (String, JSONValue) async -> (text: String, isError: Bool)

    public let token = UUID().uuidString
    private let listener: NWListener
    private let tools: [JSONValue]
    private let handler: Handler
    private let queue = DispatchQueue(label: "tool-gateway")

    public init(tools: [ToolSpec], handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.tools = tools.map(\.mcp)
        self.handler = handler
    }

    /// Avvia il gateway e restituisce il suo indirizzo.
    public func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if once.set() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if once.set() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    public func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                Task { await self.respond(to: request, on: connection) }
            } else if complete || error != nil || buffer.count > 8 << 20 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        var status = 200
        var body: JSONValue
        if request.headers["x-token"] != token {
            status = 401
            body = .object(["error": .string("token non valido")])
        } else if request.method == "GET", request.path == "/tools" {
            body = .object(["tools": .array(tools)])
        } else if request.method == "POST", request.path == "/call", let json = try? JSONValue.parse(request.body), let name = json["name"]?.string {
            let result = await handler(name, json["arguments"] ?? .object([:]))
            body = .object(["text": .string(result.text), "isError": .bool(result.isError)])
        } else {
            status = 404
            body = .object(["error": .string("sconosciuto")])
        }
        let payload = (try? body.data()) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        if status != 200 { head = head.replacingOccurrences(of: "Error", with: "Error") }
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Una sola ripresa della continuation anche se lo stato cambia più volte.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Richiesta HTTP completa (intestazioni + corpo secondo Content-Length), o nil se non è ancora arrivata tutta.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        method = String(requestLine[0])
        path = String(requestLine[1])
        self.headers = headers
        body = data[bodyStart..<(bodyStart + length)]
    }
}

/// Server MCP su stdin/stdout che inoltra `tools/list` e `tools/call` al gateway dell'app.
/// Si avvia con `siriai --mcp-bridge` e le variabili SIRIAI_GATEWAY e SIRIAI_TOKEN.
public enum MCPBridge {
    public static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SIRIAI_GATEWAY"].flatMap(URL.init(string:)), let token = env["SIRIAI_TOKEN"] else {
            FileHandle.standardError.write(Data("SIRIAI_GATEWAY e SIRIAI_TOKEN mancanti\n".utf8))
            return
        }
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let message = try? JSONValue.parse(Data(line.utf8)), let method = message["method"]?.string else { continue }
                let id = message["id"]
                switch method {
                case "initialize":
                    let version = message["params"]?["protocolVersion"]?.string ?? "2025-06-18"
                    reply(id, .object(["protocolVersion": .string(version), "capabilities": .object(["tools": .object([:])]),
                                       "serverInfo": .object(["name": .string(AppInfo.name), "version": .string("1.0")])]))
                case "ping":
                    reply(id, .object([:]))
                case "tools/list":
                    let tools = (try? await gateway(base, token: token, path: "/tools", body: nil))?["tools"] ?? .array([])
                    reply(id, .object(["tools": tools]))
                case "tools/call":
                    let params = message["params"] ?? .object([:])
                    let request = JSONValue.object(["name": params["name"] ?? .string(""), "arguments": params["arguments"] ?? .object([:])])
                    let result = try? await gateway(base, token: token, path: "/call", body: request)
                    let text = result?["text"]?.string ?? "Errore: l'app non ha risposto."
                    let isError: Bool = if case .bool(true) = result?["isError"] ?? .bool(result == nil) { true } else { false }
                    reply(id, .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)]))
                default:
                    if let id, id != .null {
                        write(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32601), "message": .string("metodo non supportato")])]))
                    }
                }
            }
        } catch {}
    }

    private static func gateway(_ base: URL, token: String, path: String, body: JSONValue?) async throws -> JSONValue {
        var request = URLRequest(url: base.appending(path: String(path.dropFirst())), timeoutInterval: 900)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue(token, forHTTPHeaderField: "X-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body?.data()
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONValue.parse(data)
    }

    private static func reply(_ id: JSONValue?, _ result: JSONValue) {
        guard let id else { return }
        write(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private static func write(_ message: JSONValue) {
        guard let data = try? message.data() else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
