import EventKit
import Foundation
import FoundationModels

public struct Access: Sendable, Equatable {
    public var calendar: Bool
    public var reminders: Bool

    public init(calendar: Bool, reminders: Bool) {
        self.calendar = calendar
        self.reminders = reminders
    }
}

/// Punto d'ingresso condiviso da CLI e app: disponibilità del modello, permessi, strumenti e sessione.
public enum Agent {
    public static let model = SystemLanguageModel.default

    /// nil se il modello è disponibile, altrimenti un messaggio da mostrare all'utente.
    public static var availabilityProblem: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "Questo Mac non supporta Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Attiva Apple Intelligence in Impostazioni di Sistema › Apple Intelligence e Siri."
        case .unavailable(.modelNotReady):
            return "Il modello Apple Intelligence non è ancora pronto (download in corso). Riprova tra poco."
        case .unavailable(let reason):
            return "Modello non disponibile: \(reason)"
        }
    }

    public static func requestAccess() async -> Access {
        let result = await Store.shared.requestAccess()
        let access = Access(calendar: result.calendar, reminders: result.reminders)
        log(diagnostics(access))
        return access
    }

    /// Stato di permessi, calendari e strumenti: finisce in ~/Library/Logs/Siri AI+.log.
    public static func diagnostics(_ access: Access) -> String {
        let ek = Store.shared.ek
        func status(_ type: EKEntityType) -> String {
            switch EKEventStore.authorizationStatus(for: type) {
            case .notDetermined: "notDetermined"
            case .restricted: "restricted"
            case .denied: "denied"
            case .fullAccess: "fullAccess"
            case .writeOnly: "writeOnly"
            @unknown default: "unknown"
            }
        }
        return """
        bundle=\(Bundle.main.bundleIdentifier ?? "nessuno") exe=\(ProcessInfo.processInfo.processName)
        calendario: status=\(status(.event)) granted=\(access.calendar) calendari=\(ek.calendars(for: .event).map(\.title))
        promemoria: status=\(status(.reminder)) granted=\(access.reminders) liste=\(ek.calendars(for: .reminder).map(\.title))
        strumenti=\(tools(for: access).map(\.name))
        """
    }

    public static func log(_ text: String) { LogFile.append(text) }

    public static func tools(for access: Access) -> [any Tool] {
        var tools: [any Tool] = []
        if access.calendar || access.reminders { tools.append(ListCalendarsTool()) }
        if access.calendar { tools += [GetEventsTool(), CreateEventTool(), DeleteEventTool()] as [any Tool] }
        if access.reminders { tools += [GetRemindersTool(), CreateReminderTool(), CompleteReminderTool()] as [any Tool] }
        return tools
    }

    /// Esegue i prompt con la pipeline completa e scrive nel log piano ed esito (nessuna modifica ai dati).
    @MainActor
    public static func selfTest(_ prompts: [String]) async {
        let access = await requestAccess()
        var enabled: Set<SourceKind> = [.mail, .notes, .files, .messages]
        if access.calendar { enabled.insert(.calendar) }
        if access.reminders { enabled.insert(.reminders) }
        let assistant = Assistant()
        // `SIRIAI_TEST_PROJECT=/percorso` simula un progetto aperto (file, AGENTS.md, memoria).
        if let path = ProcessInfo.processInfo.environment["SIRIAI_TEST_PROJECT"] {
            var work = WorkContext()
            work.projectName = URL(fileURLWithPath: path).lastPathComponent
            work.projectRoot = URL(fileURLWithPath: path)
            work.projectMemory = ProjectFiles(root: URL(fileURLWithPath: path)).memoryFacts()
            assistant.work = work
        }
        // `SIRIAI_TEST_MCP=1` collega i connettori configurati (con i token salvati) ed esegue solo strumenti di lettura.
        var connections: [String: MCPConnection] = [:]
        if ProcessInfo.processInfo.environment["SIRIAI_TEST_MCP"] == "1" {
            let url = AppPaths.support("mcp.json")
            let configs = (try? JSONDecoder().decode([MCPServerConfig].self, from: Data(contentsOf: url))) ?? []
            var work = assistant.work
            for config in configs where config.enabled {
                var token = MCPTokenStore.tokens(for: config.id)
                if let current = token, current.isExpired, let renewed = try? await MCPAuth.refresh(current) {
                    token = renewed
                    MCPTokenStore.save(renewed, for: config.id)
                }
                let connection = MCPConnection(config: config, bearer: token?.accessToken)
                do {
                    try await connection.start()
                    work.mcpTools += await connection.tools
                    work.mcpInstructions[config.name] = await connection.instructions
                    connections[config.name] = connection
                    log("MCP \(config.name): \(await connection.tools.map(\.name))")
                    if ProcessInfo.processInfo.environment["SIRIAI_TEST_SCHEMAS"] == "1" {
                        for tool in await connection.tools {
                            log("SCHEMA \(tool.name): \(tool.description.prefix(260).replacingOccurrences(of: "\n", with: " ")) || \(tool.inputSchema.compactString.prefix(400))")
                        }
                        log("ISTRUZIONI: \(await connection.instructions?.prefix(1500).replacingOccurrences(of: "\n", with: " ") ?? "")")
                    }
                } catch {
                    log("MCP \(config.name) ERRORE: \(error)")
                }
            }
            assistant.work = work
        }
        for prompt in prompts {
            log("PROMPT: \(prompt)")
            let outcome = await assistant.handle(prompt, enabled: enabled, picked: []) { _ in }
            switch outcome {
            case .reply(let text), .agenda(_, let text), .web(_, let text):
                if case .agenda(let agenda, _) = outcome {
                    log("AGENDA: \(agenda.title) eventi=\(agenda.events.map(\.title)) promemoria=\(agenda.reminders.map(\.title)) arretrati=\(agenda.overdue.count)")
                }
                if case .web(let answer, _) = outcome { log("WEB: \(answer.kind) «\(answer.query)» fonti=\(answer.sources.map(\.domain))") }
                let fromMemory = assistant.answeredFromMemory
                do {
                    let reply = try await assistant.answer(text)
                    log("RISPOSTA: \(reply.prefix(160))")
                    assistant.record(user: prompt, reply: reply)
                    // Come nell'app: se il modello ammette di non sapere, si cerca sul web.
                    if fromMemory, Assistant.soundsUnsure(reply),
                       case .web(let answer, let grounded) = try await assistant.searchWeb(assistant.lastRequest.isEmpty ? prompt : assistant.lastRequest, prompt: assistant.lastRequest.isEmpty ? prompt : assistant.lastRequest, status: { _ in }) {
                        log("RIPIEGO WEB: fonti=\(answer.sources.map(\.domain))")
                        log("RISPOSTA: \(try await assistant.answer(grounded).prefix(160))")
                    }
                } catch { log("ERRORE: \(error)") }
                if let compaction = await assistant.compactIfNeeded(threshold: 0.75) {
                    log("COMPATTAZIONE: \(Int(compaction.before * 100))% → \(Int(compaction.after * 100))% fatti=\(compaction.facts)")
                }
                log("CONTESTO: \(Int(assistant.contextUsage * 100))%")
            case .taskPlan(var plan):
                log("RAGIONAMENTO: \(plan.thoughts.joined(separator: " | "))")
                let started = Date.now
                for batch in plan.batches(maxParallel: DeviceProfile.recommendedSubAgents) {
                    log("GRUPPO: \(batch.map { plan.steps[$0].title })")
                    let previous = plan.steps.filter { !$0.result.isEmpty }.map { "\($0.title): \($0.result.prefix(600))" }.joined(separator: "\n")
                    let workers = batch.map { index in
                        let step = plan.steps[index]
                        let base = assistant.work
                        return Task { @MainActor () -> (Int, String) in
                            let agent = Assistant()
                            agent.isSubAgent = true
                            agent.work = base
                            do {
                                if !Assistant.stepNeedsTools(step.instruction) {
                                    return (index, try await agent.chat.respond(to: step.instruction + "\n\nRisultati precedenti:\n\(previous.prefix(2400))").content)
                                }
                                switch await agent.handle(step.instruction, enabled: enabled, picked: [], status: { _ in }) {
                                case .reply(let p), .agenda(_, let p), .items(_, let p), .files(_, let p), .web(_, let p):
                                    return (index, try await agent.chat.respond(to: p).content)
                                case .message(let text): return (index, text)
                                case let other: return (index, "Scheda da confermare: \(String(describing: other).prefix(80))")
                                }
                            } catch { return (index, "Errore: \(error)") }
                        }
                    }
                    for worker in workers {
                        let (index, text) = await worker.value
                        plan.steps[index].result = text
                        log("PASSO \(index + 1) \(plan.steps[index].title): \(text.prefix(140).replacingOccurrences(of: "\n", with: " "))")
                    }
                }
                do { log("RISPOSTA: \(try await assistant.chat.respond(to: assistant.taskSynthesisPrompt(plan)).content.prefix(240))") } catch { log("ERRORE: \(error)") }
                log("DURATA PIANO: \(Int(Date.now.timeIntervalSince(started)))s")
            case .mcpCall(var draft):
                // Solo letture: gli strumenti che scrivono si fermano alla bozza.
                let readOnly = ["search", "list", "get", "read", "fetch", "describe", "whoami", "find", "query", "schema"]
                for _ in 0..<4 {
                    log("MCP CHIAMATA: \(draft.tool.name) \(draft.arguments.compactString.prefix(200))")
                    guard readOnly.contains(where: { draft.tool.name.lowercased().contains($0) }), !draft.tool.name.contains("write"),
                          !draft.tool.name.contains("critical"), let connection = connections[draft.tool.serverName] else {
                        log("MCP: non eseguo \(draft.tool.name) nel test")
                        break
                    }
                    do {
                        let result = try await connection.call(draft.tool.name, arguments: draft.arguments)
                        log("MCP RISULTATO: \(result.prefix(160).replacingOccurrences(of: "\n", with: " "))")
                        if let next = await assistant.nextMCPStep(after: draft, result: result) {
                            draft = next
                            continue
                        }
                        let steps = (draft.steps ?? []) + [MCPStep(tool: draft.tool.name, arguments: draft.arguments.compactString, result: String(result.prefix(3000)))]
                        log("RISPOSTA: \(try await assistant.chat.respond(to: assistant.mcpAnswerPrompt(request: prompt, steps: steps)).content.prefix(200))")
                    } catch {
                        log("MCP ERRORE: \(error)")
                    }
                    break
                }
            default:
                log("ESITO: \(outcome)")
            }
        }
        log("FINE TEST")
    }
}
