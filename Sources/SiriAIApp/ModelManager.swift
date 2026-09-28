import AppKit
import CryptoKit
import Foundation
import Observation
import SiriCore

/// Installazione e stato dei modelli alternativi: Gemma 4 (file di Hugging Face con llama.cpp), ds4 (antirez),
/// ChatGPT (CLI Codex con l'abbonamento) e Claude (CLI Claude Code con l'abbonamento).
@MainActor @Observable
final class ModelManager {
    var llamaInstalled = false
    /// Percorso di llama-server (trovato con la shell di login).
    @ObservationIgnored private var llamaPath: String?
    /// Server di Gemma avviato dall'app: si ferma solo lui, mai altri llama-server dell'utente.
    @ObservationIgnored private var gemmaProcess: Process?
    private static var gemmaPIDFile: URL { AppPaths.support("gemma-server.pid") }
    var gemmaRunning = false
    /// Versione di Gemma caricata nel server locale.
    var gemmaLoaded: String?
    /// Download in corso: id della versione → avanzamento 0…1.
    var downloads: [String: Double] = [:]
    /// Aumenta quando cambia l'elenco dei modelli scaricati.
    var revision = 0
    @ObservationIgnored private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    var codexInstalled = false
    var codexLoggedIn = false
    /// Modelli di ChatGPT per l'account (dall'elenco della CLI Codex) e quelli scelti nella sua configurazione.
    var codexModels: [ModelOption] = []
    var codexDefaults: (model: String?, effort: String?) = (nil, nil)
    var claude = ClaudeCLI.Status()
    var claudeDefaults: (model: String?, effort: String?) = (nil, nil)
    var claudeInstalled: Bool { claude.installed }
    var claudeLoggedIn: Bool { claude.loggedIn }
    var ds4Installed = false
    var ds4Running = false
    var brewAvailable = false
    /// Operazioni in corso (chiave → ultime righe di output).
    var jobs: [String: String] = [:]
    var errors: [String: String] = [:]

    static var ds4Folder: URL {
        AppPaths.support("ds4")
    }

    func refresh() async {
        brewAvailable = await ExternalEngine.shell(String(localized: "command -v brew"), timeout: 10).status == 0
        let llama = await ExternalEngine.shell(String(localized: "command -v llama-server"), timeout: 10)
        llamaInstalled = llama.status == 0
        llamaPath = llamaInstalled ? llama.output.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } : nil
        gemmaRunning = await ExternalEngine.gemmaRunning()
        if !gemmaRunning { gemmaLoaded = nil }
        revision += 1
        codexInstalled = await ExternalEngine.shell(String(localized: "command -v codex"), timeout: 10).status == 0
        if codexInstalled {
            let status = await ExternalEngine.shell(String(localized: "codex login status"), timeout: 20)
            codexLoggedIn = status.status == 0 && !status.output.lowercased().contains("not logged")
        }
        codexModels = ModelCatalog.chatGPT()
        codexDefaults = ModelCatalog.codexDefaults()
        claude = await ClaudeCLI.status()
        claudeDefaults = ModelCatalog.claudeDefaults()
        ds4Installed = FileManager.default.fileExists(atPath: Self.ds4Folder.appending(path: "ds4-server").path)
        var request = URLRequest(url: ExternalEngine.ds4URL.appending(path: "v1/models"), timeoutInterval: 2)
        request.httpMethod = "GET"
        ds4Running = (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    func isBusy(_ key: String) -> Bool { jobs[key] != nil }

    /// Esegue un comando nella shell di login mostrando l'avanzamento.
    private func run(_ key: String, _ command: String) {
        guard jobs[key] == nil else { return }
        jobs[key] = String(localized: "Avvio…")
        errors[key] = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Le barre di avanzamento usano \r: si tiene l'ultima riga leggibile.
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "\n")
            let line = text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { return }
            Task { @MainActor in if self?.jobs[key] != nil { self?.jobs[key] = String(line.prefix(160)) } }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                let last = self.jobs[key] ?? ""
                self.jobs[key] = nil
                if status != 0 { self.errors[key] = String(localized: "Non riuscito (\(status)): \(last)") }
                await self.refresh()
            }
        }
        do { try process.run() } catch {
            jobs[key] = nil
            errors[key] = error.localizedDescription
        }
    }

    // MARK: Gemma 4 (Hugging Face + llama.cpp)

    var downloadedVariants: [GemmaVariant] { _ = revision; return GemmaVariant.all.filter(\.isDownloaded) }

    /// Motore llama.cpp (con Homebrew): esegue i file GGUF sul Mac con la GPU.
    func installLlama() {
        if brewAvailable {
            run("llama", String(localized: "brew install llama.cpp"))
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/ggml-org/llama.cpp/releases")!)
        }
    }

    /// Scarica il file del modello da Hugging Face nella cartella di Siri AI+.
    func download(_ variant: GemmaVariant) {
        guard downloads[variant.id] == nil else { return }
        errors[variant.id] = nil
        try? FileManager.default.createDirectory(at: GemmaVariant.folder, withIntermediateDirectories: true)
        downloads[variant.id] = 0
        let destination = variant.localURL
        let task = URLSession.shared.downloadTask(with: variant.downloadURL) { [weak self] temporary, response, error in
            // Il file temporaneo va spostato subito, prima che il sistema lo cancelli.
            var failure = error?.localizedDescription
            if let temporary, failure == nil {
                if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                    failure = String(localized: "Hugging Face ha risposto con errore \(code).")
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    do { try FileManager.default.moveItem(at: temporary, to: destination) } catch { failure = error.localizedDescription }
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.downloads[variant.id] = nil
                self.downloadTasks[variant.id] = nil
                if let failure, !failure.contains("cancel") { self.errors[variant.id] = failure }
                self.revision += 1
            }
        }
        downloadTasks[variant.id] = task
        task.resume()
        Task {
            while let task = downloadTasks[variant.id], task.state == .running {
                downloads[variant.id] = task.progress.fractionCompleted
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func cancelDownload(_ variant: GemmaVariant) {
        downloadTasks[variant.id]?.cancel()
    }

    // MARK: Decisioni rapide (rizzo-flow)

    static let decisionModelID = "rizzo-flow"
    /// Stato del motore delle decisioni, letto senza svegliare il server.
    var decisionStatus: DecisionEngine.Status = .stopped
    var decisionLatency: Int?

    func refreshDecisions() async {
        decisionStatus = await DecisionEngine.shared.status()
        decisionLatency = await DecisionEngine.shared.lastMilliseconds
    }

    /// Scarica il modello di rizzo-flow dalla revisione fissata e lo tiene solo se lo sha256 è quello pubblicato.
    func downloadDecisionModel() {
        let id = Self.decisionModelID
        guard downloads[id] == nil else { return }
        errors[id] = nil
        try? FileManager.default.createDirectory(at: DecisionEngine.folder, withIntermediateDirectories: true)
        downloads[id] = 0
        let destination = DecisionEngine.modelURL
        let task = URLSession.shared.downloadTask(with: DecisionEngine.downloadURL) { [weak self] temporary, response, error in
            // Il file temporaneo va controllato e spostato subito, prima che il sistema lo cancelli.
            var failure = error?.localizedDescription
            if let temporary, failure == nil {
                if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                    failure = String(localized: "Hugging Face ha risposto con errore \(code).")
                } else if Self.sha256(of: temporary) != DecisionEngine.modelSHA256 {
                    failure = String(localized: "Il file scaricato non è quello pubblicato (sha256 diverso): riprova.")
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    do { try FileManager.default.moveItem(at: temporary, to: destination) } catch { failure = error.localizedDescription }
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.downloads[id] = nil
                self.downloadTasks[id] = nil
                if let failure, !failure.contains("cancel") { self.errors[id] = failure }
                self.revision += 1
                if failure == nil {
                    Agent.log("DECISIONI: modello rizzo-flow scaricato e verificato")
                    _ = await DecisionEngine.shared.prepare()
                }
                await self.refreshDecisions()
            }
        }
        downloadTasks[id] = task
        task.resume()
        Task {
            while let task = downloadTasks[id], task.state == .running {
                downloads[id] = task.progress.fractionCompleted
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func cancelDecisionDownload() { downloadTasks[Self.decisionModelID]?.cancel() }

    /// Ferma il server delle decisioni e mette il modello nel Cestino (si può recuperare).
    func removeDecisionModel() async {
        await DecisionEngine.shared.stop()
        do { try FileManager.default.trashItem(at: DecisionEngine.modelURL, resultingItemURL: nil) }
        catch { errors[Self.decisionModelID] = error.localizedDescription }
        revision += 1
        await refreshDecisions()
    }

    /// SHA-256 di un file grande, a blocchi (2,6 GB in pochi secondi).
    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func delete(_ variant: GemmaVariant) {
        if gemmaLoaded == variant.id { stopGemma() }
        try? FileManager.default.removeItem(at: variant.localURL)
        revision += 1
    }

    func stopGemma() {
        stopOwnGemmaServer()
        gemmaLoaded = nil
        gemmaRunning = false
        Task { await refresh() }
    }

    /// Ferma il server avviato dall'app (anche in una sessione precedente, grazie al file del PID).
    private func stopOwnGemmaServer() {
        if let process = gemmaProcess, process.isRunning { process.terminate() }
        gemmaProcess = nil
        if let text = try? String(contentsOf: Self.gemmaPIDFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            // Solo se quel PID è ancora un llama-server.
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer).hasSuffix("llama-server") { kill(pid, SIGTERM) }
        }
        try? FileManager.default.removeItem(at: Self.gemmaPIDFile)
    }

    /// Avvia (o riavvia con un'altra versione) il server locale di Gemma e attende che sia pronto.
    func ensureGemma(_ variant: GemmaVariant) async -> Bool {
        if gemmaLoaded == variant.id, await ExternalEngine.gemmaRunning() { return true }
        guard variant.isDownloaded else { return false }
        // Server già acceso con lo stesso modello (da un avvio precedente o da un'altra finestra dell'app): si riusa.
        // Spegnerlo per riaccenderlo costava 30 secondi e interrompeva chi lo stava usando.
        if await ExternalEngine.gemmaRunning(), await ExternalEngine.gemmaModelPath() == variant.localURL.path {
            gemmaLoaded = variant.id
            return true
        }
        if !llamaInstalled { await refresh() }
        guard llamaInstalled else { return false }
        guard let llamaPath else { return false }
        jobs["gemma-start"] = String(localized: "Carico \(variant.label)…")
        stopOwnGemmaServer()
        try? await Task.sleep(for: .milliseconds(400))
        // Avvio diretto con gli argomenti separati: nessun problema di spazi o apostrofi nei percorsi.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: llamaPath)
        process.arguments = ["-m", variant.localURL.path, "--port", "8091", "--host", "127.0.0.1", "-c", String(DeviceProfile.gemmaContext), "--jinja"]
        let logURL = FileManager.default.temporaryDirectory.appending(path: "gemma-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) { process.standardOutput = log; process.standardError = log }
        do {
            try process.run()
            gemmaProcess = process
            try? String(process.processIdentifier).write(to: Self.gemmaPIDFile, atomically: true, encoding: .utf8)
        } catch {
            jobs["gemma-start"] = nil
            errors["gemma-start"] = String(localized: "llama-server non si avvia: \(error.localizedDescription)")
            return false
        }
        for _ in 0..<120 {
            if await ExternalEngine.gemmaRunning() {
                gemmaLoaded = variant.id
                gemmaRunning = true
                jobs["gemma-start"] = nil
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        jobs["gemma-start"] = nil
        errors["gemma-start"] = String(localized: "Il server di Gemma non è partito: controlla di avere abbastanza memoria libera.")
        return false
    }

    // MARK: ChatGPT (CLI ufficiale Codex, accesso con l'account ChatGPT)

    func installCodex() {
        run("codex", brewAvailable ? String(localized: "brew install codex || npm install -g @openai/codex") : String(localized: "npm install -g @openai/codex"))
    }

    /// Apre il login di ChatGPT nel browser (gestito dalla CLI Codex).
    func loginCodex() {
        run("codex-login", String(localized: "codex login"))
    }

    func logoutCodex() {
        run("codex-login", String(localized: "codex logout"))
    }

    // MARK: Claude (CLI ufficiale Claude Code, accesso con l'account Claude)

    /// Installazione nativa di Anthropic (in ~/.local/bin, si aggiorna da sola).
    func installClaude() {
        run("claude", String(localized: "curl -fsSL https://claude.ai/install.sh | bash"))
    }

    /// Il login di Claude si apre nel Terminale: il browser chiede di autorizzare l'account e, se serve, si incolla il codice lì.
    func loginClaude() {
        let command = String(localized: "\(ClaudeCLI.command) auth login")
        let script = String(localized: "tell application \"Terminal\"\nactivate\ndo script \(appleScriptString(command))\nend tell")
        Task {
            _ = await ExternalEngine.shell("osascript -e \(Shell.quote(script))", timeout: 20)
            // Il login finisce nel Terminale: lo stato si aggiorna quando si torna all'app.
            for _ in 0..<60 where !claude.loggedIn {
                try? await Task.sleep(for: .seconds(5))
                claude = await ClaudeCLI.status()
            }
        }
    }

    func logoutClaude() {
        run("claude-login", String(localized: "\(ClaudeCLI.command) auth logout"))
    }

    private func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: ds4 (antirez)

    func installDS4() {
        let folder = Shell.quote(Self.ds4Folder.path)
        let parent = Shell.quote(Self.ds4Folder.deletingLastPathComponent().path)
        run("ds4", """
        mkdir -p \(parent) && \
        ( [ -d \(folder)/.git ] || git clone https://github.com/antirez/ds4.git \(folder) ) && \
        cd \(folder) && git pull --ff-only && make && ./download_model.sh ds4f-q2
        """)
    }

    func startDS4() {
        run("ds4-start", String(localized: "cd \(Shell.quote(Self.ds4Folder.path)) && (nohup ./ds4-server --ctx 32768 > \"$TMPDIR/ds4-server.log\" 2>&1 &) ; sleep 5"))
    }
}
