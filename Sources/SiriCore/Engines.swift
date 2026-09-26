import Foundation

/// Caratteristiche del Mac: decidono quanti sub-agent far lavorare insieme e quali modelli proporre.
public enum DeviceProfile {
    public static var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
    public static var cores: Int { ProcessInfo.processInfo.activeProcessorCount }

    public static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Sub-agent in parallelo consigliati: ognuno ha la sua finestra di contesto.
    public static var recommendedSubAgents: Int {
        let byMemory = memoryGB < 12 ? 1 : memoryGB < 20 ? 2 : memoryGB < 40 ? 3 : 4
        return max(1, min(byMemory, cores / 2))
    }

    /// Versione di Gemma 4 adatta alla memoria del Mac.
    public static var recommendedGemma: GemmaVariant {
        GemmaVariant.all.last { $0.minMemoryGB <= memoryGB } ?? GemmaVariant.all[0]
    }

    /// Finestra da dare al server locale di Gemma: più memoria, più contesto (Gemma 4 regge fino a 128.000 token).
    public static var gemmaContext: Int {
        switch memoryGB {
        case ..<12: 8_192
        case ..<24: 16_384
        case ..<48: 32_768
        default: 65_536
        }
    }

    /// ds4 richiede almeno 96 GB di memoria unificata su Apple Silicon.
    public static var supportsDS4: Bool { memoryGB >= 96 }
}

/// Modello che scrive le risposte in chat. La pianificazione e le azioni restano sempre su Apple Intelligence.
public enum ResponseProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case apple, gemma, ds4, chatgpt, claude

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .gemma: "Gemma 4 (locale)"
        case .ds4: "ds4 (locale)"
        case .chatgpt: "ChatGPT (abbonamento)"
        case .claude: "Claude (abbonamento)"
        }
    }

    /// Nome breve per menu e messaggi («Claude sta scrivendo…»).
    public var name: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .gemma: "Gemma 4"
        case .ds4: "ds4"
        case .chatgpt: "ChatGPT"
        case .claude: "Claude"
        }
    }

    /// ChatGPT e Claude inviano i dati fuori dal Mac.
    public var isLocal: Bool { self != .chatgpt && self != .claude }

    /// Azienda a cui vanno i dati, per gli avvisi sulla privacy.
    public var company: String { self == .claude ? "Anthropic" : "OpenAI" }
}

/// Finestra di contesto del modello che scrive le risposte: decide quanti dati, pagine, file e scambi precedenti passargli.
public struct ContextBudget: Sendable, Equatable {
    /// Token della finestra del modello.
    public var tokens: Int

    public init(tokens: Int) { self.tokens = tokens }

    /// Il modello locale resta il ripiego; Private Cloud Compute offre una finestra più ampia.
    public static var apple: ContextBudget { apple(.onDevice) }
    public static func apple(_ model: AppleResponseModel) -> ContextBudget {
        ContextBudget(tokens: max(2048, model.contextSize))
    }

    /// Quanto più spazio c'è rispetto ad Apple Intelligence (1 = uguale). Limitato a 8: oltre, più dati rallentano senza migliorare.
    public var scale: Int { max(1, min(8, tokens / 4096)) }

    /// Caratteri italiani che stanno nella finestra (≈ 3 per token).
    public var characters: Int { tokens * 3 }

    /// Spazio per la conversazione precedente: circa un terzo della finestra (limitato a 60.000 caratteri).
    public var historyCharacters: Int { min(60_000, characters / 3) }

    /// Budget scalato di un valore pensato per Apple Intelligence.
    public func scaled(_ base: Int) -> Int { base * scale }

    public var label: String {
        tokens >= 1_000_000 ? (tokens / 1_000_000 == 1 ? "1 milione di token" : "\(tokens / 1_000_000) milioni di token") : "\(tokens.formatted(.number.locale(Locale(identifier: "it_IT")))) token"
    }

    /// Finestra per ciascun modello (Gemma dipende da quanta ne diamo al server locale).
    public static func of(_ provider: ResponseProvider, gemmaContext: Int = DeviceProfile.gemmaContext) -> ContextBudget {
        switch provider {
        case .apple: .apple
        case .gemma: ContextBudget(tokens: gemmaContext)
        case .ds4: ContextBudget(tokens: 32_768)
        case .chatgpt: ContextBudget(tokens: 128_000)
        case .claude: ContextBudget(tokens: 200_000)
        }
    }
}

/// Prende gli scambi più recenti che stanno nel budget (dal più nuovo al più vecchio).
public func fitting(_ history: [ChatTurn], characters: Int) -> [ChatTurn] {
    var total = 0
    var kept: [ChatTurn] = []
    for turn in history.reversed() {
        // Un turno troppo lungo entra accorciato invece di sforare la finestra.
        let room = characters - total
        guard room > 200 else { break }
        var turn = turn
        if turn.text.count > room { turn.text = String(turn.text.suffix(room)) }
        total += turn.text.count
        kept.insert(turn, at: 0)
    }
    // La storia comincia sempre con un messaggio dell'utente.
    while kept.first?.role == .assistant { kept.removeFirst() }
    return kept
}

public struct ChatTurn: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable { case user, assistant }
    public var role: Role
    public var text: String
    /// Solo nei turni di Ivan: i dati letti per rispondere (web, file, calendario…), per le domande che ci tornano sopra.
    public var data: String?
    public init(role: Role, text: String, data: String? = nil) { self.role = role; self.text = text; self.data = data }
}

public enum EngineError: LocalizedError {
    case unavailable(String), failed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let m), .failed(let m): m
        }
    }
}

/// Modelli esterni ad Apple Intelligence: ricevono istruzioni, conversazione recente e richiesta, e restituiscono testo a pezzi.
public enum ExternalEngine {
    // MARK: Gemma (file GGUF di Hugging Face eseguito con llama.cpp)

    public static let gemmaURL = URL(string: "http://127.0.0.1:8091")!

    public static func gemmaRunning() async -> Bool {
        var request = URLRequest(url: gemmaURL.appending(path: "health"), timeoutInterval: 2)
        request.httpMethod = "GET"
        return (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    /// File del modello caricato dal server di Gemma già acceso (nil se il server non risponde).
    public static func gemmaModelPath() async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: gemmaURL.appending(path: "v1/models"), timeoutInterval: 2)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let first = (json["data"] as? [[String: Any]])?.first, let id = first["id"] as? String { return id }
        return ((json["models"] as? [[String: Any]])?.first?["model"] as? String)
    }

    /// La cronologia arriva già tagliata sul budget del modello (vedi `fitting`).
    static func messages(system: String, history: [ChatTurn], prompt: String) -> JSONValue {
        var list: [JSONValue] = [.object(["role": .string("system"), "content": .string(system)])]
        for turn in history {
            list.append(.object(["role": .string(turn.role.rawValue), "content": .string(turn.text)]))
        }
        list.append(.object(["role": .string("user"), "content": .string(prompt)]))
        return .array(list)
    }

    /// Ragionamento di Gemma 4, attivato dal suo modello di chat.
    static let thinkingOption = JSONValue.object(["enable_thinking": .bool(true)])

    // MARK: ds4 (server compatibile OpenAI)

    public static let ds4URL = URL(string: "http://127.0.0.1:8000")!

    /// - Parameter thinking: Gemma 4 ragiona prima di rispondere (il ragionamento arriva a parte e non finisce nel testo).
    public static func streamOpenAICompatible(base: URL, model: String, system: String, history: [ChatTurn], prompt: String,
                                              thinking: Bool = false) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: base.appending(path: "v1/chat/completions"), timeoutInterval: 900)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    var body: [String: JSONValue] = [
                        "model": .string(model), "stream": .bool(true),
                        "messages": messages(system: system, history: history, prompt: prompt),
                    ]
                    if thinking { body["chat_template_kwargs"] = thinkingOption }
                    request.httpBody = try JSONValue.object(body).data()
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EngineError.unavailable("Il modello locale non risponde.") }
                    var text = ""
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let json = try? JSONValue.parse(Data(payload.utf8)),
                              let piece = json["choices"]?.array?.first?["delta"]?["content"]?.string else { continue }
                        text += piece
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: (error as? URLError) != nil
                        ? EngineError.unavailable("Il modello locale non è in esecuzione: avvialo in Impostazioni › Modelli.") : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: ChatGPT e Claude (abbonamento, tramite le CLI ufficiali Codex e Claude Code)

    /// Esegue un comando nella shell di login (per trovare i programmi installati con brew o npm).
    public static func shell(_ command: String, timeout: Double = 600) async -> (status: Int32, output: String) {
        let result = await Shell.run(command, timeout: timeout)
        return (result.status, result.output)
    }

    /// ChatGPT senza strumenti: solo il testo della risposta (con il modello e il ragionamento scelti).
    public static func streamChatGPT(system: String, history: [ChatTurn], prompt: String, model: String? = nil, effort: String? = nil) -> AsyncThrowingStream<String, Error> {
        stream { onText in
            try await ExternalAgent.codex(system: system, history: history, prompt: prompt, bridge: nil, model: model, effort: effort,
                                          onText: onText, onStatus: { _ in })
        }
    }

    /// Claude senza strumenti: solo il testo della risposta, scritto man mano.
    public static func streamClaude(system: String, history: [ChatTurn], prompt: String, model: String? = nil, effort: String? = nil) -> AsyncThrowingStream<String, Error> {
        stream { onText in
            try await ExternalAgent.claude(system: system, history: history, prompt: prompt, bridge: nil, model: model, effort: effort,
                                           onText: onText, onStatus: { _ in })
        }
    }

    /// Il testo di un modello con le CLI come flusso: ogni pezzo è tutto il testo scritto finora.
    static func stream(_ run: @escaping @Sendable (@escaping ExternalAgent.TextUpdate) async throws -> String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let final = try await run { text in if let text, !text.isEmpty { continuation.yield(text) } }
                    if !final.isEmpty { continuation.yield(final) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Versioni di Gemma 4 scaricabili da Hugging Face (file GGUF ufficiali di ggml-org, quantizzati a 4 bit).
public struct GemmaVariant: Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let repo: String
    public let file: String
    public let sizeGB: Double
    /// Memoria consigliata per usarla insieme al resto del Mac.
    public let minMemoryGB: Int

    public var downloadURL: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    public var pageURL: URL { URL(string: "https://huggingface.co/\(repo)")! }

    public static let all: [GemmaVariant] = [
        GemmaVariant(id: "e2b", label: "Gemma 4 E2B", repo: "ggml-org/gemma-4-E2B-it-GGUF", file: "gemma-4-E2B-it-Q4_0.gguf", sizeGB: 2.8, minMemoryGB: 0),
        GemmaVariant(id: "e4b", label: "Gemma 4 E4B", repo: "ggml-org/gemma-4-E4B-it-GGUF", file: "gemma-4-E4B-it-Q4_0.gguf", sizeGB: 4.6, minMemoryGB: 12),
        GemmaVariant(id: "12b", label: "Gemma 4 12B", repo: "ggml-org/gemma-4-12B-it-GGUF", file: "gemma-4-12B-it-Q4_0.gguf", sizeGB: 7.2, minMemoryGB: 16),
        GemmaVariant(id: "26b", label: "Gemma 4 26B A4B", repo: "ggml-org/gemma-4-26B-A4B-it-GGUF", file: "gemma-4-26B-A4B-it-Q4_0.gguf", sizeGB: 14.6, minMemoryGB: 32),
        GemmaVariant(id: "31b", label: "Gemma 4 31B", repo: "ggml-org/gemma-4-31B-it-GGUF", file: "gemma-4-31B-it-Q4_0.gguf", sizeGB: 18.0, minMemoryGB: 48),
    ]

    public static func variant(_ id: String) -> GemmaVariant? { all.first { $0.id == id } }

    /// Cartella dei modelli scaricati.
    public static var folder: URL {
        AppPaths.models
    }

    public var localURL: URL { Self.folder.appending(path: file) }
    public var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }
}
