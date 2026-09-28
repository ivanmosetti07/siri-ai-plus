import CryptoKit
import Darwin
import Foundation

/// Decisioni rapide: il modello di rizzo-flow in un llama-server tutto suo (porta 8092, Gemma usa la 8091).
/// Una richiesta alla volta, prima quelle della chat e poi quelle in background. Se il modello non c'è, è spento
/// o il server dorme, la chat riceve `nil` subito e decide come prima (parole chiave e Apple Intelligence).
public actor DecisionEngine {
    public static let shared = DecisionEngine()

    public enum Priority: Int, Sendable, Comparable {
        case background, interactive
        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Status: Sendable, Equatable {
        case notInstalled, off, stopped, starting, ready, sleeping
        case unavailable(String)
    }

    // MARK: Modello (rizzo-flow 4B Q4_K_M, revisione e sha256 fissati)

    public static let modelFile = "spark-x2.5-4b-rizzo-flow-lora-q4_k_m.gguf"
    public static let modelRepository = "rizzoaiacademy/rizzo-flow"
    public static let modelRevision = "55633c8cbd2b826bd3eefdeb05310450996649df"
    public static let modelSHA256 = "79de5cb8dbfd1a1f5cb3037252251594352841fe5e3dc1ae8cead053010fcd54"
    public static let modelBytes: Int64 = 2_600_224_416
    public static var downloadURL: URL {
        URL(string: "https://huggingface.co/\(modelRepository)/resolve/\(modelRevision)/\(modelFile)")!
    }
    public static var folder: URL { AppPaths.models.appending(path: "rizzo-flow") }
    public static var modelURL: URL { folder.appending(path: modelFile) }
    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    /// Impostazioni › Modelli › «Usa le decisioni rapide» (acceso di serie). `SIRIAI_NO_DECISIONS=1` spegne tutto per i confronti.
    public static let enabledKey = "fastDecisions"
    public static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["SIRIAI_NO_DECISIONS"] == "1" { return false }
        return UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // MARK: Server

    public static let port = 8092
    public static let baseURL = URL(string: "http://127.0.0.1:8092")!
    /// Dopo 15 minuti senza domande llama.cpp toglie il modello dalla memoria; alla prima domanda lo ricarica.
    static let idleSleep = 900
    private static var pidFile: URL { AppPaths.support("rizzo-flow-server.pid") }

    static var arguments: [String] {
        ["-m", modelURL.path, "--host", "127.0.0.1", "--port", String(port),
         // Uno slot per tipo di domanda (vedi `slot(for:)`), con la cache condivisa: la parte fissa di ogni domanda
         // resta calcolata da un turno all'altro. `--swa-full` tiene riusabile il prefisso anche per i layer a finestra
         // scorrevole (senza, llama.cpp ricalcolerebbe tutto a ogni domanda).
         "-c", "8192", "--kv-unified", "-np", String(slots), "--swa-full", "--no-webui",
         // Niente cache dei prompt nella RAM: ogni richiesta ha già il suo prefisso nello slot.
         "-cram", "0", "--sleep-idle-seconds", String(idleSleep),
         "--chat-template-kwargs", #"{"enable_thinking":false}"#]
    }

    /// Slot 0: domande con lo stato prima (lo stato si riusa tra le domande della stessa richiesta).
    /// Gli altri: una domanda con la domanda prima ciascuno, così la sua parte fissa resta in cache.
    static let slots = 8
    static let questionSlots: [String: Int] = ["area": 1, "action": 2, "refers_back": 3, "kind": 4, "difficulty": 5, "private": 6]

    static func slot(for question: DecisionQuestion, available: Int) -> Int {
        guard question.questionFirst, available > 1 else { return 0 }
        return min(questionSlots[question.id] ?? slots - 1, available - 1)
    }

    private var llamaPath: String?
    /// Slot del server acceso (un server avviato con meno slot li usa fino a dove può).
    private var serverSlots = 1
    private var process: Process?
    private var starting: Task<Bool, Never>?
    /// Id dei token «A»…«Z» del server acceso (nil = da leggere).
    private var letters: [Int]?
    private var lastUse = Date.distantPast
    private var state: Status = .stopped
    /// Ultimo tempo di una richiesta della chat (per Impostazioni).
    public private(set) var lastMilliseconds: Int?

    private var cache: [String: [Double]] = [:]
    private var cacheOrder: [String] = []
    private static let cacheLimit = 512

    private var busy = false
    private var waiting: [(priority: Priority, continuation: CheckedContinuation<Void, Never>)] = []

    // MARK: Stato e avvio

    /// Stato per Impostazioni, senza svegliare il server.
    public func status() async -> Status {
        guard Self.isInstalled else { return .notInstalled }
        guard Self.isEnabled else { return .off }
        if starting != nil { return .starting }
        if let props = await props(), props.model == Self.modelURL.path { return props.sleeping ? .sleeping : .ready }
        if case .unavailable = state { return state }
        return .stopped
    }

    /// Accende il server se serve e aspetta che risponda (fino a `timeout` secondi).
    @discardableResult
    public func prepare(timeout: Double = 90) async -> Bool {
        guard Self.isEnabled, Self.isInstalled else { return false }
        if let starting { return await starting.value }
        let task = Task { await self.start(timeout: timeout) }
        starting = task
        let ok = await task.value
        starting = nil
        return ok
    }

    /// Ferma il server avviato da questa app (mai un llama-server di altri).
    public func stop() {
        stopOwnServer()
        letters = nil
        state = .stopped
    }

    private func start(timeout: Double) async -> Bool {
        MemoryPressure.start()
        if let props = await props(), props.model == Self.modelURL.path {
            // Già acceso (da un avvio precedente, dall'app di prova o dalla CLI): si riusa.
            return await loadLetters()
        }
        guard !MemoryPressure.isCritical else {
            state = .unavailable(Language.t("memoria del Mac quasi piena", "the Mac is almost out of memory"))
            return false
        }
        if llamaPath == nil { llamaPath = await Self.findLlama() }
        guard let llamaPath else {
            state = .unavailable(Language.t("manca llama.cpp (brew install llama.cpp)", "llama.cpp is missing (brew install llama.cpp)"))
            return false
        }
        state = .starting
        stopOwnServer()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: llamaPath)
        process.arguments = Self.arguments
        let log = FileManager.default.temporaryDirectory.appending(path: "rizzo-flow-server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) { process.standardOutput = handle; process.standardError = handle }
        do {
            try process.run()
        } catch {
            state = .unavailable(error.localizedDescription)
            return false
        }
        self.process = process
        try? String(process.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)
        Agent.log("DECISIONI: avvio llama-server con \(Self.modelFile) sulla porta \(Self.port)")
        let started = Date.now
        while Date.now.timeIntervalSince(started) < timeout {
            guard process.isRunning else {
                state = .unavailable(Language.t("llama-server si è fermato (vedi \(log.path))", "llama-server stopped (see \(log.path))"))
                return false
            }
            if let props = await props(), props.model == Self.modelURL.path {
                Agent.log(String(format: "DECISIONI: modello pronto in %.1f s", Date.now.timeIntervalSince(started)))
                return await loadLetters()
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        state = .unavailable(Language.t("il server non è partito in tempo", "the server did not start in time"))
        return false
    }

    private func stopOwnServer() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        if let text = try? String(contentsOf: Self.pidFile, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            // Solo se quel PID è ancora un llama-server.
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
               String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("llama-server") {
                kill(pid, SIGTERM)
            }
        }
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    private static func findLlama() async -> String? {
        let result = await Shell.run("command -v llama-server", timeout: 10)
        guard result.status == 0 else { return nil }
        return result.output.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Lettere di risposta del server acceso: ognuna un token solo, anche subito dopo il prompt.
    private func loadLetters() async -> Bool {
        if letters != nil { state = .ready; return true }
        var ids: [Int] = []
        for letter in DecisionPrompt.letters {
            guard let tokens = try? await tokenize(letter), tokens.count == 1 else {
                state = .unavailable(Language.t("il tokenizer non ha la lettera \(letter) come token singolo",
                                                "the tokenizer has no single token for \(letter)"))
                return false
            }
            ids.append(tokens[0])
        }
        let probe = DecisionPrompt.prompt(DecisionState(text: "Probe."), .boolean("probe", "Is this a probe?", policy: .closed))
        guard Set(ids).count == ids.count, let base = try? await tokenize(probe), let joined = try? await tokenize(probe + "A"),
              joined == base + [ids[0]] else {
            state = .unavailable(Language.t("la lettera di risposta non resta un token a sé", "the answer letter does not stay a separate token"))
            return false
        }
        letters = ids
        state = .ready
        return true
    }

    // MARK: Domande

    public struct Decisions: Sendable {
        public var answers: [String: DecisionAnswer] = [:]
        /// Ordine in cui sono state fatte le domande.
        public var order: [String] = []
        public var milliseconds = 0
        /// Token calcolati davvero (il resto veniva dalla cache di llama.cpp).
        public var newTokens = 0
        public subscript(id: String) -> DecisionAnswer? { answers[id] }

        /// «area calendario 0.94 · azione agenda 0.91» per il registro e «Come ho lavorato».
        public var summary: String {
            order.compactMap { id in answers[id].map { "\(id) \($0.summary)" } }.joined(separator: " · ")
        }
    }

    /// Domande sullo stesso stato, in ordine. `then` aggiunge domande che dipendono dalle prime risposte e che partono
    /// nello stesso turno di coda, così lo stato resta nella cache del server.
    /// - Parameter budget: secondi oltre i quali le domande restanti si saltano.
    /// - Returns: nil se il motore non c'è, è spento, dorme (per la chat) o non risponde.
    public func decide(_ state: DecisionState, _ questions: [DecisionQuestion], priority: Priority = .interactive,
                       budget: Double? = nil, label: String = "",
                       then followUp: (@Sendable ([String: DecisionAnswer]) -> [DecisionQuestion])? = nil) async -> Decisions? {
        guard Self.isEnabled, Self.isInstalled, !questions.isEmpty else { return nil }
        guard await ready(for: priority) else { return nil }
        await acquire(priority)
        defer { release() }
        let started = Date.now
        var result = Decisions()
        var pending = questions
        var followed = false
        ask: while !pending.isEmpty {
            for question in pending {
                if Task.isCancelled { break ask }
                if let budget, Date.now.timeIntervalSince(started) > budget {
                    Agent.log("DECISIONE: tempo scaduto prima di «\(question.id)»")
                    break ask
                }
                if let problem = question.problem {
                    Agent.log("DECISIONE NON VALIDA: \(problem)")
                    continue
                }
                do {
                    let (answer, tokens) = try await ask(state, question)
                    result.answers[question.id] = answer
                    result.order.append(question.id)
                    result.newTokens += tokens
                } catch {
                    Agent.log("DECISIONE ERRORE: \(question.id) · \(error.localizedDescription)")
                    letters = nil
                    self.state = .stopped
                    break ask
                }
            }
            if followed { break }
            followed = true
            pending = followUp?(result.answers) ?? []
        }
        guard !result.answers.isEmpty else { return nil }
        result.milliseconds = Int(Date.now.timeIntervalSince(started) * 1000)
        lastUse = .now
        if priority == .interactive { lastMilliseconds = result.milliseconds }
        Agent.log("DECISIONE\(label.isEmpty ? "" : " (\(label))"): \(result.summary) · \(result.milliseconds) ms, \(result.newTokens) token nuovi")
        return result
    }

    /// Una domanda sola (comodità).
    public func decide(_ state: DecisionState, _ question: DecisionQuestion, priority: Priority = .interactive,
                       budget: Double? = nil, label: String = "") async -> DecisionAnswer? {
        await decide(state, [question], priority: priority, budget: budget, label: label)?[question.id]
    }

    /// Calcola lo stato senza domande (mentre si scrive): la prima domanda vera troverà il prefisso già pronto.
    public func prefill(_ state: DecisionState) async {
        guard Self.isEnabled, Self.isInstalled, letters != nil, !busy else { return }
        let prompt = DecisionPrompt.chat(system: DecisionPrompt.system, user: state.evidence)
        _ = try? await post("completion", ["prompt": prompt, "n_predict": 0, "cache_prompt": true, "id_slot": 0], timeout: 20)
        lastUse = .now
    }

    private func ready(for priority: Priority) async -> Bool {
        if letters != nil, Date.now.timeIntervalSince(lastUse) < Double(Self.idleSleep - 60) { return true }
        guard let props = await props(), props.model == Self.modelURL.path else {
            // Server spento: la chat non aspetta, si accende per il turno dopo.
            if priority == .interactive {
                if starting == nil { Task { await self.prepare() } }
                return false
            }
            return await prepare()
        }
        if props.sleeping, priority == .interactive {
            // Il modello si ricarica da solo alla prima richiesta: la sveglia la manda un'attività a parte.
            Task { await self.wake() }
            return false
        }
        return await loadLetters()
    }

    /// Mentre si scrive: se il server dorme o è spento lo si prepara adesso, così la richiesta trova le decisioni pronte.
    public func wakeIfNeeded() async {
        guard Self.isEnabled, Self.isInstalled, starting == nil else { return }
        if letters != nil, Date.now.timeIntervalSince(lastUse) < Double(Self.idleSleep - 60) { return }
        guard let props = await props(), props.model == Self.modelURL.path else {
            _ = await prepare()
            return
        }
        if props.sleeping { await wake() }
        _ = await loadLetters()
    }

    private func wake() async {
        _ = try? await post("completion", ["prompt": "A", "n_predict": 0, "cache_prompt": false], timeout: 60)
        lastUse = .now
    }

    private func ask(_ state: DecisionState, _ question: DecisionQuestion) async throws -> (DecisionAnswer, Int) {
        let prompt = DecisionPrompt.prompt(state, question)
        let key = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        let started = Date.now
        var tokens = 0
        let logprobs: [Double]
        if let cached = cache[key] {
            logprobs = cached
        } else {
            guard let letters else { throw DecisionError.unavailable("lettere non lette") }
            let json = try await post("completion", ["prompt": prompt, "n_predict": 1, "n_probs": 64, "temperature": -1, "cache_prompt": true,
                                                     "id_slot": Self.slot(for: question, available: serverSlots), "stream": false], timeout: 30)
            let first = (json["completion_probabilities"] as? [[String: Any]])?.first
            let top = (first?["top_logprobs"] as? [[String: Any]]) ?? []
            var byID: [Int: Double] = [:]
            for item in top {
                if let id = item["id"] as? Int, let logprob = item["logprob"] as? Double { byID[id] = logprob }
            }
            guard !byID.isEmpty else { throw DecisionError.unavailable("risposta senza probabilità") }
            // Una lettera fuori dalle 64 più probabili vale poco: la si mette sotto l'ultima vista.
            let floor = (byID.values.min() ?? -30) - 10
            logprobs = letters.prefix(question.candidates.count).map { byID[$0] ?? floor }
            tokens = ((json["timings"] as? [String: Any])?["prompt_n"] as? Int) ?? 0
            remember(key, logprobs)
        }
        var answer = try question.decode(logprobs)
        answer.milliseconds = Int(Date.now.timeIntervalSince(started) * 1000)
        return (answer, tokens)
    }

    private func remember(_ key: String, _ value: [Double]) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = value
        if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }

    // MARK: Coda: una richiesta alla volta, prima la chat

    private func acquire(_ priority: Priority) async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { continuation in waiting.append((priority, continuation)) }
    }

    private func release() {
        guard let highest = waiting.map(\.priority).max(), let index = waiting.firstIndex(where: { $0.priority == highest }) else {
            busy = false
            return
        }
        waiting.remove(at: index).continuation.resume()
    }

    // MARK: HTTP

    private struct Props { let model: String; let sleeping: Bool; let slots: Int }

    private func props() async -> Props? {
        guard let json = try? await get("props", timeout: 2) else { return nil }
        let props = Props(model: json["model_path"] as? String ?? "", sleeping: json["is_sleeping"] as? Bool ?? false,
                          slots: json["total_slots"] as? Int ?? 1)
        serverSlots = max(1, props.slots)
        return props
    }

    private func tokenize(_ text: String) async throws -> [Int] {
        let json = try await post("tokenize", ["content": text, "add_special": false, "parse_special": true], timeout: 10)
        return (json["tokens"] as? [Int]) ?? []
    }

    private func get(_ path: String, timeout: Double) async throws -> [String: Any] {
        try await send(URLRequest(url: Self.baseURL.appending(path: path), timeoutInterval: timeout))
    }

    private func post(_ path: String, _ body: [String: Any], timeout: Double) async throws -> [String: Any] {
        var request = URLRequest(url: Self.baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DecisionError.unavailable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) da \(request.url?.path ?? "")")
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// Pressione di memoria del sistema: con la memoria quasi piena il server delle decisioni non parte
/// (il 25/9 la memoria esaurita ha fatto fallire Apple Intelligence su tutto il Mac).
enum MemoryPressure {
    private final class Monitor: @unchecked Sendable {
        let lock = NSLock()
        var critical = false
        var source: DispatchSourceMemoryPressure?
    }

    private static let monitor = Monitor()

    static var isCritical: Bool {
        monitor.lock.lock(); defer { monitor.lock.unlock() }
        return monitor.critical
    }

    static func start() {
        monitor.lock.lock(); defer { monitor.lock.unlock() }
        guard monitor.source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [monitor] in
            monitor.lock.lock()
            if let event = monitor.source?.data { monitor.critical = event.contains(.critical) }
            monitor.lock.unlock()
        }
        source.resume()
        monitor.source = source
    }
}
