import AppKit
import Foundation
import Observation
import SiriCore
import SwiftUI
import UserNotifications

/// Una sessione di coding su un progetto, con il modello scelto (Codex, Claude Code o un modello sul Mac).
@MainActor @Observable final class CodeSession: Identifiable {
    let id: UUID
    let projectID: UUID
    var title: String
    /// Chi lavora sul progetto, con versione e ragionamento.
    var selection: ModelSelection
    var mode: CodeMode
    var isolation: CodeIsolation
    var workingFolder: URL?
    var baseRevision: String?
    var applied = false
    /// Id della sessione nel motore (Codex o Claude Code), per continuare la stessa conversazione.
    var externalID: String?
    /// Motore a cui appartiene `externalID`: cambiando modello si riparte con il riassunto della sessione.
    var externalEngine: String?
    var events: [CodeEvent]
    var running = false
    let created: Date

    var engine: CodeAgent.Engine { CodeAgent.Engine(selection.provider) }

    init(id: UUID = UUID(), projectID: UUID, title: String = String(localized: "Nuova sessione"), selection: ModelSelection, mode: CodeMode = .edit,
         isolation: CodeIsolation = .project, workingFolder: URL? = nil, baseRevision: String? = nil, applied: Bool = false,
         externalID: String? = nil, externalEngine: String? = nil, events: [CodeEvent] = [], created: Date = .now) {
        self.id = id; self.projectID = projectID; self.title = title; self.selection = selection; self.mode = mode
        self.isolation = isolation; self.workingFolder = workingFolder; self.baseRevision = baseRevision; self.applied = applied
        self.externalID = externalID; self.externalEngine = externalEngine; self.events = events; self.created = created
    }

    var stored: StoredCodeSession {
        StoredCodeSession(id: id, projectID: projectID, title: title, engine: engine.rawValue, model: selection, externalEngine: externalEngine,
                          mode: mode, isolation: isolation, workingFolder: workingFolder?.path, baseRevision: baseRevision, applied: applied,
                          externalID: externalID, events: events, created: created)
    }
}

struct StoredCodeSession: Codable {
    var id: UUID
    var projectID: UUID
    var title: String
    /// Motore («codex», «claude», «local»): le sessioni salvate prima della scelta del modello sono tutte di Codex.
    var engine: String
    var model: ModelSelection?
    var externalEngine: String?
    var mode: CodeMode
    var isolation: CodeIsolation?
    var workingFolder: String?
    var baseRevision: String?
    var applied: Bool?
    var externalID: String?
    var events: [CodeEvent]
    var created: Date
}

/// Server di sviluppo o programma avviato dallo spazio di coding.
@MainActor @Observable final class DevRun {
    let command: DevCommand
    var lines: [String] = []
    var url: URL?
    var running = true
    @ObservationIgnored var process: Shell.Background?

    init(command: DevCommand) { self.command = command }
}

extension AppState {
    // MARK: Modelli

    var codexAvailable: Bool { models.codexInstalled && models.codexLoggedIn }
    var claudeAvailable: Bool { models.claudeInstalled && models.claudeLoggedIn }

    /// Modello delle sessioni nuove: l'ultimo scelto, altrimenti Codex (o Claude Code, se c'è solo lui).
    var codeDefault: ModelSelection {
        resolved(codeModel ?? ModelSelection(!codexAvailable && claudeAvailable ? .claude : .chatgpt))
    }

    /// Sceglie il modello di una sessione (e delle prossime).
    func chooseCodeModel(_ choice: ModelSelection, for session: CodeSession?) {
        let choice = resolved(choice)
        session?.selection = choice
        codeModel = choice
        saveCodeSessions()
    }

    /// Nome di chi lavora: «Codex · GPT-6-Sol · Alto», «Claude Code · Opus · Alto», «Gemma 4 E4B · Ragionamento».
    func codeEngineLabel(_ selection: ModelSelection) -> String {
        let model = label(for: selection)
        switch CodeAgent.Engine(selection.provider) {
        case .codex: return String(localized: "Codex · ") + model
        case .claude: return String(localized: "Claude Code · ") + (model.hasPrefix("Claude ") ? String(model.dropFirst(7)) : model)
        case .local: return model
        }
    }

    /// Nome breve per «… sta lavorando».
    func codeWorkerName(_ selection: ModelSelection) -> String {
        switch CodeAgent.Engine(selection.provider) {
        case .codex: String(localized: "Codex")
        case .claude: String(localized: "Claude")
        case .local: selection.provider == .gemma ? (GemmaVariant.variant(resolved(selection).model ?? "")?.label ?? String(localized: "Gemma")) : selection.provider.name
        }
    }

    /// Perché un modello non può ancora lavorare sul codice (nil se è pronto).
    func codeModelProblem(_ selection: ModelSelection) -> String? {
        switch selection.provider {
        case .chatgpt:
            if !models.codexInstalled { return String(localized: "Codex non è installato: installalo in Impostazioni › Modelli.") }
            if !models.codexLoggedIn { return String(localized: "Accedi con il tuo account ChatGPT in Impostazioni › Modelli.") }
        case .claude:
            if !models.claudeInstalled { return String(localized: "Claude Code non è installato: installalo in Impostazioni › Modelli.") }
            if !models.claudeLoggedIn { return String(localized: "Accedi con il tuo account Claude in Impostazioni › Modelli.") }
        case .apple:
            return availabilityProblem
        case .gemma:
            guard let variant = GemmaVariant.variant(resolved(selection).model ?? ""), variant.isDownloaded else {
                return String(localized: "Gemma non è ancora scaricata: scaricala in Impostazioni › Modelli.")
            }
        case .ds4:
            if !models.ds4Installed { return String(localized: "ds4 non è installato: installalo in Impostazioni › Modelli.") }
        }
        return nil
    }

    /// Il modello sul Mac pronto per l'agente dell'app (Gemma viene avviata se serve).
    private func localCodeModel(_ selection: ModelSelection) async -> (model: LocalCodeAgent.Model?, problem: String?) {
        switch selection.provider {
        case .apple:
            return (.apple, availabilityProblem)
        case .gemma:
            guard let variant = GemmaVariant.variant(selection.model ?? gemmaModel), variant.isDownloaded else {
                return (nil, String(localized: "Gemma non è ancora scaricata: scaricala in Impostazioni › Modelli."))
            }
            guard await models.ensureGemma(variant) else {
                return (nil, models.errors["gemma-start"] ?? String(localized: "Per usare Gemma serve llama.cpp: installalo in Impostazioni › Modelli."))
            }
            return (.openAI(base: ExternalEngine.gemmaURL, name: "gemma", label: variant.label, contextTokens: DeviceProfile.gemmaContext,
                            thinking: selection.effort == "on"), nil)
        case .ds4:
            return (.openAI(base: ExternalEngine.ds4URL, name: "ds4", label: "ds4", contextTokens: 32_768, thinking: false), nil)
        case .chatgpt, .claude:
            return (nil, nil)
        }
    }

    /// Scambi precedenti della sessione (richieste e risposte finali), per l'agente dell'app e per il passaggio da un modello all'altro.
    static func codeHistory(_ events: some Sequence<CodeEvent>) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var reply = ""
        for event in events {
            switch event.kind {
            case .user:
                if !reply.isEmpty { turns.append(ChatTurn(role: .assistant, text: reply)); reply = "" }
                turns.append(ChatTurn(role: .user, text: event.text))
            case .text:
                reply = event.text
            default:
                break
            }
        }
        if !reply.isEmpty { turns.append(ChatTurn(role: .assistant, text: reply)) }
        return turns
    }

    // MARK: Sessioni

    func codeSessions(for project: ProjectModel) -> [CodeSession] {
        codeSessions.filter { $0.projectID == project.id }.sorted { $0.created > $1.created }
    }

    var currentCodeSession: CodeSession? {
        guard let project = openCodingProject else { return nil }
        if let id = currentCodeSessionID, let session = codeSessions.first(where: { $0.id == id && $0.projectID == project.id }) { return session }
        return codeSessions(for: project).first
    }

    @discardableResult
    func newCodeSession(in project: ProjectModel) -> CodeSession {
        let session = CodeSession(projectID: project.id, selection: codeDefault)
        // Le app aperte prima della prima sessione (Safari con l'anteprima) passano a lei.
        let adopted = codeSessions(for: project).isEmpty ? tabsByOwner.removeValue(forKey: project.id) : nil
        let page = codeSessions(for: project).isEmpty ? browsers.removeValue(forKey: project.id) : nil
        codeSessions.append(session)
        if let adopted { tabsByOwner[session.id] = adopted }
        if let page { browsers[session.id] = page }
        currentCodeSessionID = session.id
        saveCodeSessions()
        return session
    }

    func selectCodeSession(_ session: CodeSession) {
        currentCodeSessionID = session.id
        if let project = projects.first(where: { $0.id == session.projectID }) {
            section = .project(project.id)
            project.lastOpened = .now
        }
        showAssistant = true
    }

    func deleteCodeSession(_ session: CodeSession) {
        cancelCode(session)
        if let folder = session.workingFolder, FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            showToast(String(localized: "Copia isolata conservata nel Finder"), symbol: "folder")
        }
        codeSessions.removeAll { $0.id == session.id }
        forgetTabs(of: session.id)
        if currentCodeSessionID == session.id { currentCodeSessionID = nil }
        saveCodeSessions()
    }

    func workingCodeProject(_ project: ProjectModel) -> ProjectModel {
        guard let session = currentCodeSession, session.isolation == .worktree, let folder = session.workingFolder else { return project }
        return ProjectModel(id: project.id, name: project.name, folder: folder, allowWrite: project.allowWrite)
    }

    // MARK: Richieste all'agente di coding

    /// Invia una richiesta: prima un punto di ripristino, poi il motore lavora nella cartella del progetto.
    func sendCode(_ text: String, in session: CodeSession) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !session.running, !session.applied, let project = projects.first(where: { $0.id == session.projectID }), project.exists else { return }
        if session.events.isEmpty { session.title = String(prompt.prefix(48)) }
        var user = CodeEvent(kind: .user, text: prompt)
        // Scambi precedenti: all'agente dell'app servono sempre, alle CLI solo se si cambia modello a metà sessione.
        let history = Self.codeHistory(session.events)
        session.running = true
        session.events.append(user)
        let userIndex = session.events.count - 1
        let selection = resolved(session.selection)
        let engine = CodeAgent.Engine(selection.provider)
        let mode = session.mode
        let resume = session.externalEngine == engine.rawValue ? session.externalID : nil
        var request = prompt
        if engine != .local, resume == nil, !history.isEmpty {
            let recap = history.suffix(8).map { "\($0.role == .user ? String(localized: "Utente") : String(localized: "Assistente")): \($0.text.prefix(700))" }.joined(separator: "\n\n")
            request = String(localized: "Conversazione precedente in questa sessione (con un altro modello):\n\(recap)\n\nNuova richiesta:\n\(prompt)")
        }
        // «Non funziona»: gli errori che l'anteprima vede ora vanno all'agente con la richiesta.
        // La lingua è quella in cui scrive l'utente (anche se l'interfaccia è in un'altra).
        let language = Language.detect(prompt, fallback: .system)
        if Language.$scoped.withValue(language, operation: { CodeAgent.mentionsProblem(prompt) }),
           let errors = browsers[session.id]?.consoleErrors, !errors.isEmpty {
            request += String(localized: "\n\nErrori letti ora da Siri AI+ nella console dell'anteprima della pagina:\n") + errors.prefix(12).map { "- " + $0 }.joined(separator: "\n")
        }
        codeTasks[session.id] = Task {
            let folder: URL
            if session.isolation == .worktree {
                if let existing = session.workingFolder {
                    guard FileManager.default.fileExists(atPath: existing.path) else {
                        session.events.append(CodeEvent(kind: .error, text: String(localized: "La copia isolata non esiste più."), status: .failed))
                        session.running = false; codeTasks[session.id] = nil; saveCodeSessions(); return
                    }
                    folder = existing
                } else {
                    do {
                        let copy = try await CodeWorktree.create(project: project.folder, id: session.id)
                        session.workingFolder = copy.folder
                        session.baseRevision = copy.base
                        folder = copy.folder
                        saveCodeSessions()
                    } catch {
                        session.events.append(CodeEvent(kind: .error, text: error.localizedDescription, status: .failed))
                        session.running = false; codeTasks[session.id] = nil; saveCodeSessions(); return
                    }
                }
            } else {
                folder = project.folder
            }
            let snapshot = await CodeSnapshot.take(folder, label: String(localized: "Prima di: \(prompt.prefix(60))"))
            user.snapshot = snapshot
            if session.events.indices.contains(userIndex) { session.events[userIndex].snapshot = snapshot }
            guard !Task.isCancelled else {
                session.events.append(CodeEvent(kind: .error, text: String(localized: "Interrotto prima dell'avvio."), status: .failed))
                session.running = false
                codeTasks[session.id] = nil
                saveCodeSessions()
                return
            }
            let started = Date.now
            var outcome: CodeAgent.Outcome
            if let problem = codeModelProblem(selection) {
                outcome = CodeAgent.Outcome(ok: false, error: problem)
            } else {
                var local: (model: LocalCodeAgent.Model?, problem: String?) = (nil, nil)
                if engine == .local { local = await localCodeModel(selection) }
                if let problem = local.problem {
                    outcome = CodeAgent.Outcome(ok: false, error: problem)
                } else {
                    outcome = await Language.$scoped.withValue(language) {
                        await CodeAgent.run(selection: selection, mode: mode, folder: folder, prompt: request, resume: resume,
                                            local: local.model, history: history,
                                            checkPage: { page in await PageCheck.errors(in: page, readAccess: folder) }) { event in
                            Task { @MainActor in
                                Self.merge(event, into: session)
                                // Un file cambiato: l'anteprima aperta si ricarica.
                                if event.kind == .file, event.status == .ok { self.codeFilesRevision += 1 }
                            }
                        }
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
            if let id = outcome.sessionID {
                session.externalID = id
                session.externalEngine = engine.rawValue
            } else if engine == .local {
                // Il lavoro fatto sul Mac non è nella sessione di Codex o di Claude Code: tornando a loro si riparte dal riassunto.
                session.externalID = nil
                session.externalEngine = nil
            }
            if Task.isCancelled {
                session.events.append(CodeEvent(kind: .error, text: String(localized: "Interrotto."), status: .failed))
            } else if !outcome.ok {
                session.events.append(CodeEvent(kind: .error, text: outcome.error ?? String(localized: "\(codeWorkerName(selection)) non ha completato la richiesta."), status: .failed))
            }
            // Riepilogo dei file cambiati (dal punto di ripristino).
            if let snapshot {
                let changes = await CodeSnapshot.changes(folder, since: snapshot)
                if !changes.isEmpty {
                    let list = changes.prefix(30).map { line -> String in
                        let parts = line.split(separator: "\t", maxSplits: 1)
                        let symbol = parts.first == "A" ? "+" : parts.first == "D" ? "−" : "•"
                        return "\(symbol) \(parts.count > 1 ? String(parts[1]) : line)"
                    }.joined(separator: "\n")
                    session.events.append(CodeEvent(kind: .result, text: String(localized: "\(changes.count) file cambiati in \(Int(Date.now.timeIntervalSince(started))) s"), detail: list))
                }
            }
            for index in session.events.indices where session.events[index].status == .running {
                session.events[index].status = outcome.ok && !Task.isCancelled ? .ok : .failed
            }
            session.running = false
            codeTasks[session.id] = nil
            projectRevision += 1
            saveCodeSessions()
            log(icon: "chevron.left.forwardslash.chevron.right", title: "\(codeWorkerName(selection)): \(project.name)", detail: String(prompt.prefix(80)),
                status: outcome.ok ? .done : .failed)
            if !NSApp.isActive { notifyCode(project: project.name, ok: outcome.ok) }
        }
        saveCodeSessions()
    }

    /// Un evento con la stessa chiave aggiorna quello esistente (uscita di un comando, esito di una modifica).
    @MainActor static func merge(_ event: CodeEvent, into session: CodeSession) {
        if let key = event.key, let index = session.events.lastIndex(where: { $0.key == key }) {
            var current = session.events[index]
            if !event.text.isEmpty { current.text = event.text }
            if !event.detail.isEmpty { current.detail = event.detail }
            if event.path != nil { current.path = event.path }
            if !event.todos.isEmpty { current.todos = event.todos }
            current.status = event.status
            session.events[index] = current
        } else if event.kind == .todo, let index = session.events.lastIndex(where: { $0.kind == .todo }) {
            session.events[index].todos = event.todos
        } else {
            session.events.append(event)
        }
    }

    func cancelCode(_ session: CodeSession) {
        codeTasks[session.id]?.cancel()
    }

    /// Riporta il progetto a prima di un messaggio (i file nuovi vanno nel Cestino).
    func restoreCode(_ session: CodeSession, to event: CodeEvent) {
        guard !session.running, let snapshot = event.snapshot, let project = projects.first(where: { $0.id == session.projectID }) else { return }
        session.running = true
        Task {
            defer { session.running = false }
            let folder = session.isolation == .worktree ? (session.workingFolder ?? project.folder) : project.folder
            let result = await CodeSnapshot.restore(folder, to: snapshot)
            if let error = result.error {
                session.events.append(CodeEvent(kind: .error, text: String(localized: "Ripristino non riuscito: \(error)"), status: .failed))
            } else {
                session.events.append(CodeEvent(kind: .result, text: String(localized: "Ripristinato a prima di «\(event.text.prefix(40))»: \(result.restored.count) file ripristinati, \(result.trashed.count) nel Cestino")))
                showToast(String(localized: "Progetto ripristinato"), symbol: "arrow.uturn.backward.circle.fill")
            }
            projectRevision += 1
            saveCodeSessions()
        }
    }

    func applyCodeWorktree(_ session: CodeSession, reviewedRevision: String) {
        guard !session.running, let project = projects.first(where: { $0.id == session.projectID }),
              let folder = session.workingFolder, let base = session.baseRevision else { return }
        session.running = true
        Task {
            defer { session.running = false; saveCodeSessions() }
            do {
                let count = try await CodeWorktree.apply(project: project.folder, copy: folder, base: base, reviewedRevision: reviewedRevision)
                if count > 0 { session.applied = true }
                session.events.append(CodeEvent(kind: .result, text: count == 0 ? String(localized: "Nessuna modifica da applicare.") : String(localized: "\(count) file applicati alla cartella originale.")))
                projectRevision += 1
                showToast(String(localized: "Modifiche applicate al progetto"), symbol: "checkmark.circle.fill")
            } catch {
                session.events.append(CodeEvent(kind: .error, text: error.localizedDescription, status: .failed))
            }
        }
    }

    private func notifyCode(project: String, ok: Bool) {
        let content = UNMutableNotificationContent()
        content.title = project
        content.body = ok ? String(localized: "Il lavoro sul codice è finito: controlla le modifiche.") : String(localized: "Il lavoro sul codice si è fermato con un errore.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Nuovi progetti

    static var codeProjectsFolder: URL {
        let url = AppPaths.documents.appending(path: "Progetti")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Crea la cartella dal modello, scrive le regole per l'agente e avvia la prima richiesta.
    func createCodeProject(template: CodeTemplate, name: String, description: String, parent: URL) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? template.label : name.trimmingCharacters(in: .whitespacesAndNewlines)
        var folder = parent.appending(path: cleanName)
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.path) { folder = parent.appending(path: "\(cleanName) \(counter)"); counter += 1 }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try template.agentsFile(name: cleanName).write(to: folder.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
            try "node_modules/\ndist/\n.build/\nDerivedData/\n.DS_Store\n".write(to: folder.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        } catch {
            showToast(String(localized: "Non riesco a creare la cartella: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill")
            return
        }
        let project = ProjectModel(name: folder.lastPathComponent, folder: folder)
        project.space = Space.codice.rawValue
        projects.append(project)
        saveProjects()
        let session = CodeSession(projectID: project.id, title: cleanName, selection: codeDefault)
        codeSessions.append(session)
        currentCodeSessionID = session.id
        section = .project(project.id)
        showAssistant = true
        log(icon: "folder.badge.plus", title: String(localized: "Progetto di codice creato"), detail: folder.path, status: .done)
        let first = template.bootstrap(description)
        if !first.isEmpty { sendCode(first, in: session) } else { saveCodeSessions() }
    }

    /// Collega una cartella esistente come progetto di codice.
    func addCodeProject(folder: URL) {
        if let existing = projects.first(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) {
            existing.space = Space.codice.rawValue
            saveProjects()
            section = .project(existing.id)
            return
        }
        let project = ProjectModel(name: folder.lastPathComponent, folder: folder)
        project.space = Space.codice.rawValue
        projects.append(project)
        saveProjects()
        newCodeSession(in: project)
        section = .project(project.id)
        showAssistant = true
    }

    // MARK: Avvio del progetto

    func devRun(for project: ProjectModel) -> DevRun? { devRuns[project.id] }

    /// Avvia il progetto: pagina statica nel browser, Xcode, oppure server di sviluppo con console.
    func runProject(_ project: ProjectModel) {
        let folder = workingCodeProject(project).folder
        guard let command = DevCommand.detect(in: folder) else {
            showToast(String(localized: "Non so ancora come avviare questo progetto: chiedilo all'assistente"), symbol: "questionmark.circle")
            return
        }
        switch command.kind {
        case .staticPage:
            if let page = command.page { openInBrowser(page) }
        case .xcode:
            Task { _ = await Shell.run(command.command, timeout: 30) }
            showToast(String(localized: "Apro il progetto in Xcode"), symbol: "hammer")
        case .server, .run:
            stopProject(project)
            let run = DevRun(command: command)
            devRuns[project.id] = run
            // L'indirizzo arriva dopo qualche secondo: la pagina va nel Safari della sessione che ha avviato il server,
            // anche se nel frattempo si è passati a un'altra chat.
            if currentCodeSession == nil, openCodingProject?.id == project.id { newCodeSession(in: project) }
            let owner = tabOwner
            run.process = Shell.Background(String(localized: "cd \(Shell.quote(folder.path)) && \(command.command)")) { line in
                Task { @MainActor in
                    run.lines.append(line)
                    if run.lines.count > 800 { run.lines.removeFirst(run.lines.count - 800) }
                    if run.url == nil, command.kind == .server, let url = DevCommand.localURL(in: line) {
                        run.url = url
                        if self.tabOwner == owner {
                            self.openInBrowser(url)
                        } else {
                            self.browser(for: owner).load(url)
                        }
                    }
                }
            }
            Task {
                let result = await run.process?.finished.value
                run.running = false
                run.lines.append(String(localized: "— terminato (codice \(result?.status ?? 0)) —"))
            }
        }
    }

    /// «Anteprima»: il sito nel Safari della sessione di coding, con la chat del coding sempre a destra. Un server di sviluppo
    /// si avvia (e la pagina si apre appena scrive il suo indirizzo); le app Swift si aprono in Xcode.
    func openPreview(_ project: ProjectModel) {
        if currentCodeSession == nil, openCodingProject?.id == project.id { newCodeSession(in: project) }
        if let run = devRun(for: project), run.running, let url = run.url {
            openInBrowser(url)
            return
        }
        runProject(project)
    }

    /// Gli errori della console dell'anteprima: all'agente del progetto (nel coding) o a Siri AI+ (nelle altre chat).
    func fixPreviewErrors(_ errors: [String]) {
        guard !errors.isEmpty else { return }
        let list = errors.prefix(12).map { "- " + $0 }.joined(separator: "\n")
        if let project = openCodingProject {
            let session = currentCodeSession ?? newCodeSession(in: project)
            guard !session.running else { showToast(String(localized: "L'assistente sta ancora lavorando"), symbol: "hourglass"); return }
            sendCode(String(localized: "Nell'anteprima della pagina ci sono questi errori:\n\(list)\nTrova la causa nel codice e correggili."), in: session)
        } else {
            send(String(localized: "Nella pagina aperta in Safari ci sono questi errori della console:\n\(list)\nCosa significano e come si correggono?"))
        }
    }

    func stopProject(_ project: ProjectModel) {
        devRuns[project.id]?.process?.stop()
        devRuns[project.id]?.running = false
    }

    // MARK: Salvataggio

    static func loadCodeSessions() -> [CodeSession] {
        guard let data = try? Data(contentsOf: AppPaths.support("code-sessions.json")),
              let stored = SafeJSON.decodeArray(StoredCodeSession.self, from: data, label: "code-sessions.json") else { return [] }
        return stored.map {
            // Prima della scelta del modello tutte le sessioni erano di Codex (le più vecchie, di Claude Code, erano già ripartite).
            let selection = $0.model ?? ModelSelection(.chatgpt)
            let events = $0.events.map { var e = $0; if e.status == .running { e.status = .failed }; return e }
            return CodeSession(id: $0.id, projectID: $0.projectID, title: $0.title, selection: selection, mode: $0.mode,
                        isolation: $0.isolation ?? .project, workingFolder: $0.workingFolder.map { URL(fileURLWithPath: $0) }, baseRevision: $0.baseRevision, applied: $0.applied ?? false,
                        externalID: $0.externalID, externalEngine: $0.externalEngine ?? ($0.engine == "codex" ? "codex" : nil),
                        events: events, created: $0.created)
        }
    }

    func saveCodeSessions() {
        guard persists, let data = try? JSONEncoder().encode(codeSessions.map(\.stored)) else { return }
        SafeJSON.write(data, to: AppPaths.support("code-sessions.json"), keepBackup: true)
    }

    /// Progetto di codice della colonna destra: aperto al centro, oppure con le sue app davanti (Safari con l'anteprima).
    var openCodingProject: ProjectModel? {
        guard let id = codeContextProjectID, let project = projects.first(where: { $0.id == id }), project.space == Space.codice.rawValue else { return nil }
        return project
    }
}
