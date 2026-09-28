import Foundation

// MARK: - Banco degli strumenti per modello
//
// Gli stessi casi per Apple Intelligence, Gemma, ChatGPT, Claude e Auto, sulla stessa strada dell'app: quali strumenti e
// connettori usa ogni modello, con quali argomenti, se prepara le schede invece di dire «fatto» e se resta zitto quando
// non servono. Tutto su dati inventati (`FixtureWorld`, `Support/eval/mondo-prova.json`), in una cartella dati temporanea.
//
//   bin/siriai --banco-strumenti [file] --provider apple|gemma|chatgpt|claude|auto [--model m] [--effort e]
//              [--auto-cloud chatgpt|claude|nessuno] [--etichetta prima|dopo] [--solo id|categoria] [--solo-smistamento]
//              [--ferma-dopo-errori N] [--web-reale] [--out cartella]
//   bin/siriai --banco-confronto [strumenti-modelli] [--etichetta prima|dopo] [--out cartella]

/// Un caso del banco: le domande e le attese di `EvalCase` più quelle sugli strumenti.
public struct ToolCase: Decodable, Sendable {
    public var base: EvalCase
    /// Strumenti da chiamare: «a|b» vuol dire uno dei due; i connettori si scrivono «mcp:etichetta» («mcp:list_tasks»,
    /// «mcp:execute_read_tool:invoices_list»).
    public var tools: [String]
    /// Gli strumenti di `tools` nell'ordine dato.
    public var inOrder: Bool
    /// Strumenti che non si devono chiamare («mcp:*» = nessun connettore, «*» = nessuno strumento).
    public var forbiddenTools: [String]
    /// Nessuno strumento: la risposta viene dalle conoscenze del modello o dal testo della richiesta.
    public var noTools: Bool
    public var maxCalls: Int?
    /// Espressioni regolari sui campi degli strumenti chiamati: {"crea_evento": {"inizio": "^{{giorno:giovedì}} 15:00"}}.
    public var arguments: [String: [String: String]]
    /// Schede da preparare («evento», «promemoria», «email», «risposta-email», «messaggio», «connettore», «foglio»…).
    public var cards: [String]
    /// true: la richiesta la decidono le regole dell'app, con qualunque modello.
    public var rules: Bool?

    enum Keys: String, CodingKey {
        case tools = "strumenti", inOrder = "in_ordine", forbiddenTools = "vieta_strumenti", noTools = "nessuno_strumento"
        case maxCalls = "massimo_chiamate", arguments = "argomenti", cards = "schede", rules = "regole"
    }

    public init(from decoder: Decoder) throws {
        base = try EvalCase(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        inOrder = try c.decodeIfPresent(Bool.self, forKey: .inOrder) ?? false
        forbiddenTools = try c.decodeIfPresent([String].self, forKey: .forbiddenTools) ?? []
        noTools = try c.decodeIfPresent(Bool.self, forKey: .noTools) ?? false
        maxCalls = try c.decodeIfPresent(Int.self, forKey: .maxCalls)
        arguments = try c.decodeIfPresent([String: [String: String]].self, forKey: .arguments) ?? [:]
        cards = try c.decodeIfPresent([String].self, forKey: .cards) ?? []
        rules = try c.decodeIfPresent(Bool.self, forKey: .rules)
    }
}

/// L'esito di un caso, con la traccia degli strumenti.
public struct ToolCaseResult: Codable, Sendable {
    public var id: String
    public var category: String
    public var prompt: String
    /// «apple», «regole» (decide l'app), «strumenti» (il modello con gli strumenti), «piano», «smistamento».
    public var path: String
    /// Il modello che ha risposto (con Auto: quello scelto).
    public var model: String
    /// Gli strumenti offerti al modello (strada esterna).
    public var offered: [String]
    public var calls: [FixtureWorld.Call]
    public var answer: String
    public var seconds: Double
    public var failures: [String]
    /// Accessi ai dati veri bloccati.
    public var blocked: [String]
    /// Le chiamate arrivate ai connettori finti (server · strumento).
    public var connectorLog: [String]
    /// Richieste a ChatGPT o Claude (quota dell'abbonamento). Facoltativo: i resoconti di prima non ce l'hanno.
    public var cloudCalls: Int?
    public var passed: Bool { failures.isEmpty }
}

@MainActor
public enum ToolBench {
    /// Strumenti dei connettori finti che scrivono: non devono mai arrivare al server (restano schede).
    static let connectorWrites: Set<String> = ["create_task", "execute_write_tool", "quote_create"]

    // MARK: Controlli

    /// La chiamata registrata corrisponde all'attesa («agenda», «mcp:list_tasks», «mcp:execute_read_tool:invoices_list»).
    nonisolated static func call(_ call: FixtureWorld.Call, matches expected: String) -> Bool {
        if expected == "*" { return true }
        if expected == "mcp:*" { return call.tool.hasPrefix("mcp:") }
        return call.tool == expected || call.tool.hasPrefix(expected + ":")
    }

    nonisolated static func alternatives(_ expected: String) -> [String] {
        expected.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Le chiamate decise dal modello (senza le letture di riserva fatte dall'app, segnate «ripiego»).
    nonisolated static func modelCalls(_ calls: [FixtureWorld.Call]) -> [FixtureWorld.Call] { calls.filter { $0.fields["ripiego"] != "sì" } }

    /// Frasi che danno per fatto ciò che è solo una scheda da confermare.
    static func claimsDone(_ answer: String) -> Bool {
        let text = Evaluation.normalize(answer)
        let done = #"\b(ho (gia )?(creato|inviato|mandato|aggiunto|spostato|eliminato|cancellato|fissato|salvato|programmato|impostato)|e stat[oa] (creat|inviat|aggiunt|spostat|eliminat|salvat)|i('ve| have) (created|sent|added|moved|deleted|scheduled|saved)|(has|have) been (created|sent|added|moved|deleted|scheduled|saved))"#
        let pending = #"(conferm|confirm|scheda|card|bozza|draft|pront[oaie]\b|ready|anteprima|preview|controlla|review)"#
        return Evaluation.matches(text, done) && !Evaluation.matches(text, pending)
    }

    /// Motivi per cui il caso non va bene (vuoto = superato).
    static func failures(_ test: ToolCase, calls: [FixtureWorld.Call], path: String, answer: String, blocked: [String],
                                     connectorLog: [String], external: Bool, now: Date = .now) -> [String] {
        Language.$scoped.withValue(Language.detect(test.base.turns.joined(separator: "\n"), fallback: .it)) {
            var failures: [String] = []
            let names = calls.map(\.tool)
            if test.noTools, !calls.isEmpty { failures.append("strumenti non necessari: \(names.joined(separator: ", "))") }
            var positions: [Int] = []
            for expected in test.tools {
                let options = alternatives(expected)
                if let index = calls.firstIndex(where: { call in options.contains { self.call(call, matches: $0) } }) {
                    positions.append(index)
                } else {
                    failures.append("non ha usato \(expected)")
                }
            }
            if test.inOrder, positions.count == test.tools.count, positions != positions.sorted() { failures.append("ordine sbagliato: \(names.joined(separator: " → "))") }
            for forbidden in test.forbiddenTools {
                let used = calls.filter { self.call($0, matches: forbidden) }
                if !used.isEmpty { failures.append("ha usato \(used.map(\.tool).joined(separator: ", ")) (vietato)") }
            }
            // Le letture di riserva fatte dall'app (web dopo una risposta incerta, posta dopo Messaggi vuoti) valgono come
            // letture, ma non sono chiamate del modello.
            let modelCalls = Self.modelCalls(calls)
            if let max = test.maxCalls, modelCalls.count > max { failures.append("\(modelCalls.count) chiamate (al massimo \(max))") }
            for (tool, fields) in test.arguments.sorted(by: { $0.key < $1.key }) {
                let candidates = calls.filter { call in alternatives(tool).contains { self.call(call, matches: $0) } }
                guard !candidates.isEmpty else { continue }
                for (field, pattern) in fields.sorted(by: { $0.key < $1.key }) {
                    let regex = Evaluation.expand(pattern, now: now)
                    if !candidates.contains(where: { Evaluation.matches(Evaluation.normalize($0.fields[field] ?? ""), regex) }) {
                        let seen = candidates.compactMap { $0.fields[field] }.map { "«\($0.prefix(60))»" }.joined(separator: ", ")
                        failures.append("\(tool).\(field) non corrisponde a /\(pattern)/" + (seen.isEmpty ? " (manca)" : " (\(seen))"))
                    }
                }
            }
            let cards = Set(calls.compactMap(\.card))
            for card in test.cards where !alternatives(card).contains(where: cards.contains) { failures.append("manca la scheda «\(card)»") }
            // Sulla strada di Apple le regole valgono comunque per prime: conta solo un modello esterno che fa da sé.
            if external, test.rules == true, path == "strumenti" { failures.append("doveva decidere l'app (regole), invece \(path)") }
            if path == "piano" { failures.append("ha scelto un piano con sub-agent (non eseguito nel banco)") }
            // Le attese sul testo della risposta (deve, vieta) valgono come negli altri banchi.
            let text = Evaluation.normalize(answer)
            for pattern in test.base.expected where !Evaluation.matches(text, Evaluation.expand(pattern, now: now)) { failures.append("manca /\(pattern)/") }
            for pattern in test.base.forbidden where Evaluation.matches(text, Evaluation.expand(pattern, now: now)) { failures.append("contiene /\(pattern)/") }
            if answer.hasPrefix("Errore:") || answer.hasPrefix("Error:") { failures.append(String(answer.prefix(160))) }
            if answer.contains("<<<") || answer.contains(">>>") { failures.append("ricopia i delimitatori dei dati") }
            if !cards.isEmpty, claimsDone(answer) { failures.append("dice «fatto» con una scheda da confermare") }
            if !blocked.isEmpty { failures.append("accessi ai dati veri bloccati: \(blocked.joined(separator: ", "))") }
            let writes = connectorLog.filter { entry in connectorWrites.contains { entry.hasSuffix(" · " + $0) } }
            if !writes.isEmpty { failures.append("scrittura arrivata al connettore: \(writes.joined(separator: ", "))") }
            return failures
        }
    }

    // MARK: Esecuzione

    public struct Options: Sendable {
        public var provider: ResponseProvider = .apple
        public var auto = false
        public var model: String?
        public var effort: String?
        public var autoCloud: ResponseProvider? = .chatgpt
        public var label = "prima"
        public var only: String?
        public var routingOnly = false
        public var stopAfterErrors = 0
        public var realWeb = false
        public var out = URL(fileURLWithPath: "output/valutazioni")
        public var file = URL(fileURLWithPath: "Support/eval/strumenti-modelli.json")
    }

    /// Testo scritto dal modello esterno nel caso in corso.
    final class Box {
        var text = ""
    }

    /// Il modello per questo caso: quello scelto, o per Auto quello che sceglie la sua regola (con la versione data,
    /// per non consumare la quota del cloud con le versioni più capaci).
    static func selection(for prompt: String, assistant: Assistant, options: Options) async -> ModelSelection {
        let fixed = ModelSelection(options.provider, model: options.model, effort: options.effort)
        guard options.auto else { return fixed }
        let signals = await assistant.autoSignals(for: prompt)
        let cloud = options.autoCloud.map { ModelSelection($0, model: options.model, effort: options.effort) }
        let situation = AutoModel.Situation(gemma: await ExternalEngine.gemmaRunning(), cloud: cloud)
        let decision = AutoModel.choose(signals, situation)
        var chosen = decision.0
        if !chosen.provider.isLocal, let cloud { chosen = cloud }
        Agent.log("BANCO AUTO: \(chosen.provider.rawValue) · \(decision.1)")
        return chosen
    }

    /// Esegue un caso con la strada dell'app per quel modello.
    static func run(_ test: ToolCase, options: Options, world: FixtureWorld, folder: URL?, connectorLog: URL,
                    shieldFor: (ResponseProvider) -> PrivacyShield?) async -> ToolCaseResult {
        let started = Date.now
        let assistant = await Evaluation.prepare(test.base, provider: options.auto ? .apple : options.provider, web: true, folder: folder,
                                                 connectors: ["crm", "catalogo"])
        let sources: Set<SourceKind> = [.calendar, .reminders, .mail, .notes, .files, .messages]
        var path = "apple"
        var model = options.provider.label
        var offered: [String] = []
        var answer = ""
        var blocked: [String] = []
        var cloudCalls = 0
        let turns = test.base.turns
        for (index, turn) in turns.enumerated() {
            // Le attese valgono per l'ultimo turno: le chiamate si contano da lì.
            if index == turns.count - 1 {
                blocked += world.blocked
                world.reset()
                try? Data().write(to: connectorLog)
            }
            await Language.$scoped.withValue(assistant.language(for: turn)) {
                let chosen = await selection(for: turn, assistant: assistant, options: options)
                model = chosen.provider == .apple ? chosen.provider.label
                    : [chosen.provider.label, chosen.model, chosen.effort].compactMap { $0 }.joined(separator: " · ")
                assistant.budget = chosen.provider == .apple ? ContextBudget.apple : ContextBudget.of(chosen.provider)
                assistant.textWriter = ExternalEngine.writer(for: chosen.provider)
                assistant.textWriterName = chosen.provider == .apple ? nil : chosen.provider.label
                let shield = shieldFor(chosen.provider)
                await PrivacyShield.$current.withValue(shield) {
                    let handledByApp = assistant.decidedByRules(turn)
                    if chosen.provider == .apple || handledByApp {
                        // Anche con Auto che sceglie Apple: se decide l'app, la strada è quella delle regole.
                        path = handledByApp ? "regole" : "apple"
                        guard !options.routingOnly else { return }
                        let outcome = await assistant.handle(turn, enabled: sources, picked: []) { _ in }
                        answer = await assistant.headlessAnswer(for: outcome, request: turn, enabled: sources, provider: chosen.provider).text
                    } else {
                        let route = await assistant.routeForExternal(turn, enabled: sources) { _ in }
                        let wantsPlan = !assistant.pointsAtScreen && (Assistant.isComplex(turn) || route?.multiStep == true)
                        if options.routingOnly {
                            path = "smistamento"
                            offered = assistant.externalToolList(for: turn, route: route, enabled: sources).map(\.name)
                            return
                        }
                        if wantsPlan { path = "piano"; return }
                        path = "strumenti"
                        let box = Box()
                        let caller = assistant.connectorCaller
                        let hooks = ExternalHooks(
                            status: { _ in }, text: { text in if let text { box.text = text } },
                            show: { _, _ in nil },
                            callConnector: { draft in
                                guard let caller else { throw MCPError.notRunning }
                                return try await caller(draft.tool, draft.arguments)
                            },
                            runsFreely: { $0.isReadOnly }, enabled: sources, bridgeHelper: Bundle.main.executablePath)
                        let history = fitting(assistant.historyTurns, characters: assistant.budget.historyCharacters)
                        if chosen.provider == .chatgpt || chosen.provider == .claude { cloudCalls += 1 }
                        do {
                            let turnResult = try await assistant.respondExternally(turn, selection: chosen, label: model, route: route,
                                                                                   history: history, hooks: hooks)
                            offered = turnResult?.tools ?? []
                            answer = turnResult?.text ?? ""
                            if answer.isEmpty { answer = box.text }
                            // Come nell'app: se il modello ammette di non sapere senza aver cercato, si cerca sul web.
                            if let web = await assistant.unsureWebFallback(answer, request: turn), case .web(let found, let grounded) = web {
                                world.record(FixtureWorld.Call(tool: "cerca_web", fields: ["cerca": found.query, "ripiego": "sì"], card: nil, ok: true))
                                answer = (try? await assistant.headlessText(grounded, provider: chosen.provider)) ?? answer
                            }
                        } catch {
                            answer = "Errore: \(error.localizedDescription)"
                        }
                    }
                }
                assistant.record(user: turn, reply: answer)
            }
        }
        blocked += world.blocked
        let log = ((try? String(contentsOf: connectorLog, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line -> String? in
            guard let json = try? JSONValue.parse(Data(line.utf8)) else { return nil }
            return "\(json["server"]?.string ?? "?") · \(json["tool"]?.string ?? "?")"
        }
        let calls = world.recorded
        var failures = options.routingOnly
            ? offeredFailures(test, offered: offered, path: path)
            : failures(test, calls: calls, path: path, answer: answer, blocked: blocked, connectorLog: log, external: options.provider != .apple || options.auto)
        if options.routingOnly, !blocked.isEmpty { failures.append("accessi ai dati veri bloccati: \(blocked.joined(separator: ", "))") }
        return ToolCaseResult(id: test.base.id, category: test.base.category, prompt: turns.joined(separator: " ⟶ "), path: path, model: model,
                              offered: offered, calls: calls, answer: answer, seconds: Date.now.timeIntervalSince(started), failures: failures,
                              blocked: blocked, connectorLog: log, cloudCalls: cloudCalls)
    }

    /// Solo smistamento: gli strumenti attesi devono essere tra quelli offerti; nei casi senza strumenti conta quanti se ne offrono.
    nonisolated static func offeredFailures(_ test: ToolCase, offered: [String], path: String) -> [String] {
        guard path == "smistamento" else { return [] }
        var failures: [String] = []
        for expected in test.tools {
            let found = alternatives(expected).contains { option in
                option.hasPrefix("mcp:") ? offered.contains { $0.hasPrefix("mcp__") } : offered.contains(option)
            }
            if !found { failures.append("non offerto: \(expected)") }
        }
        if test.noTools, !offered.isEmpty { failures.append("offerti \(offered.count) strumenti a una domanda che non ne ha bisogno") }
        return failures
    }

    // MARK: Resoconti

    struct Metrics {
        var passed = 0, total = 0
        var rightTool = 0, toolCases = 0
        var silence = 0, silenceCases = 0
        var unneeded = 0
        var connectorHits = 0, connectorCases = 0
        var argumentHits = 0, argumentChecks = 0
        var claimedDone = 0
        var calls = 0
        var median = 0.0, p90 = 0.0

        init(_ results: [ToolCaseResult], cases: [String: ToolCase]) {
            total = results.count
            passed = results.filter(\.passed).count
            for result in results {
                guard let test = cases[result.id] else { continue }
                let made = ToolBench.modelCalls(result.calls)
                calls += made.count
                if !test.tools.isEmpty {
                    toolCases += 1
                    if !result.failures.contains(where: { $0.hasPrefix("non ha usato") || $0.hasSuffix("(vietato)") }) { rightTool += 1 }
                    let expected = test.tools.flatMap(ToolBench.alternatives)
                    unneeded += made.filter { call in !expected.contains { ToolBench.call(call, matches: $0) } }.count
                }
                if test.noTools {
                    silenceCases += 1
                    if result.calls.isEmpty { silence += 1 }
                    unneeded += result.calls.count
                }
                if test.tools.contains(where: { $0.hasPrefix("mcp:") }) {
                    connectorCases += 1
                    if result.calls.contains(where: { $0.tool.hasPrefix("mcp:") }) { connectorHits += 1 }
                }
                let checks = test.arguments.values.reduce(0) { $0 + $1.count }
                argumentChecks += checks
                argumentHits += checks - result.failures.filter { $0.contains(" non corrisponde a /") }.count
                if result.failures.contains(where: { $0.hasPrefix("dice «fatto»") }) { claimedDone += 1 }
            }
            let seconds = results.map(\.seconds).sorted()
            if !seconds.isEmpty {
                median = seconds[seconds.count / 2]
                p90 = seconds[min(seconds.count - 1, Int(Double(seconds.count) * 0.9))]
            }
        }

        static func percent(_ part: Int, _ whole: Int) -> String { whole == 0 ? "—" : "\(part)/\(whole) (\(part * 100 / whole)%)" }

        var rows: [(String, String)] {
            [("Casi superati", Self.percent(passed, total)),
             ("Strumento giusto", Self.percent(rightTool, toolCases)),
             ("Silenzio giusto (nessuno strumento)", Self.percent(silence, silenceCases)),
             ("Connettore usato quando serve", Self.percent(connectorHits, connectorCases)),
             ("Argomenti corretti", Self.percent(argumentHits, argumentChecks)),
             ("Chiamate inutili", "\(unneeded)"),
             ("«Fatto» con una scheda da confermare", "\(claimedDone)"),
             ("Chiamate per caso", total == 0 ? "—" : String(format: "%.1f", Double(calls) / Double(total))),
             ("Tempo mediano / al 90%", String(format: "%.1f s / %.1f s", median, p90))]
        }
    }

    static func report(_ results: [ToolCaseResult], cases: [ToolCase], name: String, options: Options, header: String) -> String {
        let byID = Dictionary(cases.map { ($0.base.id, $0) }, uniquingKeysWith: { a, _ in a })
        let metrics = Metrics(results, cases: byID)
        var lines = ["# Banco degli strumenti · \(name)", "", "\(Dates.format(.now)) · \(header)", "", "| Misura | Valore |", "| --- | --- |"]
        lines += metrics.rows.map { "| \($0.0) | \($0.1) |" }
        lines += ["", "| Caso | Esito | Strada | Strumenti | Secondi |", "| --- | --- | --- | --- | --- |"]
        for result in results {
            let tools = result.calls.map { call in call.card.map { "\(call.tool) [\($0)]" } ?? call.tool }
            lines.append("| \(result.id) | \(result.passed ? "✅" : "❌") | \(result.path) | \(tools.isEmpty ? "—" : tools.joined(separator: ", ")) | \(String(format: "%.1f", result.seconds)) |")
        }
        let failed = results.filter { !$0.passed }
        if !failed.isEmpty {
            lines += ["", "## Non superati", ""]
            for result in failed {
                lines += ["### \(result.id) · \(result.category)", "", "**Domanda:** \(result.prompt)", "",
                          "**Strada:** \(result.path) · \(result.model)" + (result.offered.isEmpty ? "" : " · offerti: \(result.offered.joined(separator: ", "))"), "",
                          "**Problemi:** \(result.failures.joined(separator: "; "))", ""]
                for call in result.calls {
                    let fields = call.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.prefix(80).replacingOccurrences(of: "\n", with: " "))" }
                    lines.append("- `\(call.tool)`\(call.card.map { " → scheda \($0)" } ?? "") \(fields.joined(separator: " · "))")
                }
                lines += ["", result.answer.prefix(700).split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n"), ""]
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Nome del resoconto: modello, versione, ragionamento ed etichetta.
    static func runName(_ options: Options) -> String {
        ([options.auto ? "auto" : options.provider.rawValue, options.model, options.effort].compactMap { $0 } + [options.label]).joined(separator: "-")
    }

    // MARK: Riga di comando

    public static func main(_ arguments: [String]) async -> Int32 {
        var args = arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            let value = args[index + 1]
            args.removeSubrange(index...(index + 1))
            return value
        }
        func flag(_ name: String) -> Bool {
            let found = args.contains(name)
            args.removeAll { $0 == name }
            return found
        }
        var options = Options()
        let provider = value("--provider") ?? "apple"
        if provider == "auto" {
            options.auto = true
        } else if let known = ResponseProvider(rawValue: provider) {
            options.provider = known
        } else {
            print("❌ Modello sconosciuto: \(provider) (apple, gemma, ds4, chatgpt, claude, auto)")
            return 1
        }
        options.model = value("--model")
        options.effort = value("--effort")
        if let cloud = value("--auto-cloud") { options.autoCloud = cloud == "nessuno" ? nil : ResponseProvider(rawValue: cloud) }
        options.label = value("--etichetta") ?? "prima"
        options.only = value("--solo")
        options.stopAfterErrors = Int(value("--ferma-dopo-errori") ?? "0") ?? 0
        if let out = value("--out") { options.out = URL(fileURLWithPath: out) }
        options.routingOnly = flag("--solo-smistamento")
        options.realWeb = flag("--web-reale")
        if let file = args.first { options.file = URL(fileURLWithPath: file) }

        // Dati isolati prima di ogni altro accesso: cartella temporanea, modelli veri, utente inventato.
        let root = BenchIsolation.start(label: "strumenti")
        guard var cases = try? JSONDecoder().decode([ToolCase].self, from: Data(contentsOf: options.file)) else {
            print("❌ Non riesco a leggere \(options.file.path)")
            return 1
        }
        if let only = options.only { cases = cases.filter { $0.base.id.contains(only) || $0.base.category == only } }
        let folder = options.file.deletingLastPathComponent()
        let world: FixtureWorld
        do { world = try FixtureWorld(file: folder.appending(path: "mondo-prova.json")) } catch {
            print("❌ Mondo di prova illeggibile: \(error)")
            return 1
        }
        world.realWeb = options.realWeb
        FixtureWorld.active = world
        Assistant.userNameOverride = world.userName

        // Controlli prima di partire: nessun modello avviato o spento dal banco.
        let providers: Set<ResponseProvider> = options.auto ? Set([.apple, .gemma] + (options.autoCloud.map { [$0] } ?? [])) : [options.provider]
        if let problem = Agent.availabilityProblem {
            print("❌ Apple Intelligence non è disponibile (serve anche per smistamento e regole): \(problem)")
            return 1
        }
        if providers.contains(.gemma), !options.routingOnly, !(await ExternalEngine.gemmaRunning()) {
            if options.auto { print("⚠️ Gemma non è accesa: Auto sceglierà senza Gemma.") } else {
                print("❌ Gemma non è in esecuzione: avviala dall'app (Impostazioni › Modelli).")
                return 1
            }
        }
        let cloud = providers.contains(.chatgpt) || providers.contains(.claude)
        if cloud, !options.routingOnly, !PIIEngine.isInstalled {
            print("❌ Per ChatGPT e Claude serve rizzo-pii (lo scudo della privacy), come nell'app.")
            return 1
        }
        let decisions = DecisionEngine.isEnabled && DecisionEngine.isInstalled ? await DecisionEngine.shared.prepare() : false
        let connectorLog = root.appending(path: "connettori.log")
        Evaluation.connectorLog = connectorLog
        let name = runName(options)
        let header = "\(cases.count) casi · \(options.auto ? "Auto" : options.provider.label)"
            + (options.model.map { " · \($0)" } ?? "") + (options.effort.map { " · ragionamento \($0)" } ?? "")
            + " · \(options.label)" + (options.routingOnly ? " · solo smistamento" : "")
            + (decisions ? " · decisioni rapide accese" : " · decisioni rapide spente")
            + (options.realWeb ? " · web vero" : " · web inventato")
        print("Banco degli strumenti: \(header)\nDati di prova in \(root.path) (registro: \(AppPaths.logFile.path))")

        var results: [ToolCaseResult] = []
        var cloudCalls = 0
        var errorsInARow = 0
        for (index, test) in cases.enumerated() {
            let result = await run(test, options: options, world: world, folder: folder, connectorLog: connectorLog) { provider in
                guard provider == .chatgpt || provider == .claude else { return nil }
                return PrivacyShield(vault: PIIVault(), destination: provider.name, chat: UUID())
            }
            results.append(result)
            cloudCalls += result.cloudCalls ?? 0
            let tools = result.calls.map { $0.tool + ($0.card.map { "[\($0)]" } ?? "") }
            print("\(result.passed ? "✅" : "❌") [\(index + 1)/\(cases.count)] \(test.base.id) · \(result.path)"
                  + (options.auto ? " · \(result.model)" : "") + " · \(tools.isEmpty ? "nessuno strumento" : tools.joined(separator: ", "))"
                  + " · \(String(format: "%.1f", result.seconds)) s" + (result.passed ? "" : " · " + result.failures.joined(separator: "; ")))
            // Accesso o ponte che non funzionano: inutile continuare a consumare tempo (e quota).
            let infrastructure = result.answer.hasPrefix("Errore:") || result.answer.hasPrefix("Error:")
            errorsInARow = infrastructure ? errorsInARow + 1 : 0
            if options.stopAfterErrors > 0, errorsInARow >= options.stopAfterErrors {
                print("⛔️ \(errorsInARow) errori di fila: mi fermo (rilancia i casi mancanti con --solo).")
                break
            }
        }
        FixtureWorld.active = nil

        try? FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
        let stamp = { () -> String in
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmm"
            return formatter.string(from: .now)
        }()
        let stem = options.file.deletingPathExtension().lastPathComponent
        let file = "\(stamp)-\(stem)-\(name)\(options.routingOnly ? "-smistamento" : "")\(options.only.map { "-\($0)" } ?? "")"
        let markdown = report(results, cases: cases, name: name, options: options, header: header)
        try? markdown.write(to: options.out.appending(path: "\(file).md"), atomically: true, encoding: .utf8)
        if options.only == nil, let data = try? JSONEncoder().encode(results) { try? data.write(to: options.out.appending(path: "\(file).json")) }
        let passed = results.filter(\.passed).count
        print("\nSuperati \(passed)/\(results.count)" + (cloudCalls > 0 ? " · chiamate al cloud: \(cloudCalls)" : "")
              + " · resoconto: \(options.out.appending(path: "\(file).md").path)")
        return 0
    }

    // MARK: Confronto fra modelli

    /// Tabella casi × modelli dall'ultimo resoconto completo di ogni modello (per l'etichetta data, o per tutte).
    /// Data e ora del giro dal nome del resoconto («2026-09-28-1554-…»): i segnaposto delle date valgono per quel giorno.
    nonisolated static func runDate(_ file: URL) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.date(from: String(file.lastPathComponent.prefix(15)))
    }

    public static func compare(_ arguments: [String]) -> Int32 {
        var args = arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            let value = args[index + 1]
            args.removeSubrange(index...(index + 1))
            return value
        }
        let out = URL(fileURLWithPath: value("--out") ?? "output/valutazioni")
        let label = value("--etichetta")
        let stem = args.first ?? "strumenti-modelli"
        let casesFile = URL(fileURLWithPath: "Support/eval/\(stem).json")
        let cases = (try? JSONDecoder().decode([ToolCase].self, from: Data(contentsOf: casesFile))) ?? []
        let files = ((try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.contains("-\(stem)-") && !$0.lastPathComponent.contains("-smistamento") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // Il più recente per ogni modello ed etichetta.
        var latest: [String: URL] = [:]
        for file in files {
            let base = file.deletingPathExtension().lastPathComponent
            guard let range = base.range(of: "-\(stem)-") else { continue }
            let run = String(base[range.upperBound...])
            if let label, !run.hasSuffix("-" + label) { continue }
            latest[run] = file
        }
        // Per ogni modello prima il giro «prima», poi il «dopo».
        func order(_ run: String) -> String { run.replacingOccurrences(of: "-prima", with: "-0").replacingOccurrences(of: "-dopo", with: "-1") }
        let runs = latest.keys.sorted { order($0) < order($1) }
        guard !runs.isEmpty else {
            print("❌ Nessun resoconto di \(stem) in \(out.path)")
            return 1
        }
        let byID = Dictionary(cases.map { ($0.base.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Esiti ricalcolati dai dati salvati (chiamate, strada, risposta) con le regole di oggi del banco: prima e dopo si
        // giudicano allo stesso modo, con le date del giorno del giro.
        let results = runs.map { run -> (String, [ToolCaseResult]) in
            let file = latest[run]!
            let saved = (try? JSONDecoder().decode([ToolCaseResult].self, from: Data(contentsOf: file))) ?? []
            let when = runDate(file) ?? .now
            return (run, saved.map { result in
                guard let test = byID[result.id], result.path != "smistamento" else { return result }
                var judged = result
                judged.failures = failures(test, calls: result.calls, path: result.path, answer: result.answer, blocked: result.blocked,
                                           connectorLog: result.connectorLog, external: !run.hasPrefix("apple-"), now: when)
                return judged
            })
        }
        var lines = ["# Confronto fra modelli · \(stem)", "", Dates.format(.now) + " · esiti ricalcolati con le regole attuali del banco", "",
                     "| Misura | " + runs.joined(separator: " | ") + " |", "| --- |" + String(repeating: " --- |", count: runs.count)]
        let metrics = results.map { Metrics($0.1, cases: byID) }
        for (index, row) in (metrics.first?.rows ?? []).enumerated() {
            lines.append("| \(row.0) | " + metrics.map { $0.rows[index].1 }.joined(separator: " | ") + " |")
        }
        lines.append("| Chiamate al cloud | " + results.map { _, list in
            list.contains { $0.cloudCalls != nil } ? "\(list.compactMap(\.cloudCalls).reduce(0, +))" : "—"
        }.joined(separator: " | ") + " |")
        lines += ["", "| Caso | " + runs.joined(separator: " | ") + " |", "| --- |" + String(repeating: " --- |", count: runs.count)]
        let ids = cases.isEmpty ? results.first?.1.map(\.id) ?? [] : cases.map(\.base.id)
        for id in ids {
            let cells = results.map { _, list -> String in
                guard let result = list.first(where: { $0.id == id }) else { return "—" }
                let tools = result.calls.map(\.tool)
                return (result.passed ? "✅" : "❌") + " " + (tools.isEmpty ? "·" : tools.joined(separator: ", "))
            }
            lines.append("| \(id) | " + cells.joined(separator: " | ") + " |")
        }
        let markdown = lines.joined(separator: "\n")
        let file = out.appending(path: "confronto-\(stem)\(label.map { "-\($0)" } ?? "").md")
        try? markdown.write(to: file, atomically: true, encoding: .utf8)
        print(markdown)
        print("\nConfronto: \(file.path)")
        return 0
    }
}

// MARK: - Isolamento dei banchi

public enum BenchIsolation {
    /// Parole del nome vero dell'account (solo in memoria, mai su disco): nessun testo che le contiene parte verso ChatGPT o Claude.
    nonisolated(unsafe) public static var canary: [String] = []

    /// Cartella dati temporanea, modelli veri (rizzo-flow, rizzo-pii) e utente inventato, prima di ogni altro accesso ai dati.
    /// Impostazioni del banco nel dominio volatile (non si salvano).
    @discardableResult
    public static func start(label: String) -> URL {
        let models = AppPaths.models
        canary = NSFullUserName().split(separator: " ").map(String.init).filter { $0.count >= 3 }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = FileManager.default.temporaryDirectory.appending(path: "siriai-banco/\(label)-\(formatter.string(from: .now))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppPaths.rootOverride = root
        AppPaths.modelsOverride = models
        Assistant.userNameOverride = "Mario Rossi"
        UserDefaults.standard.setVolatileDomain([DecisionEngine.enabledKey: true, PrivacyGate.enabledKey: true, "memoryEnabled": true,
                                                 "preferPrivateCloudCompute": false], forName: UserDefaults.argumentDomain)
        return root
    }

    /// true se il testo contiene il nome vero dell'account (solo durante un banco).
    public static func leaks(_ text: String) -> Bool {
        guard !canary.isEmpty else { return false }
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return canary.contains { words.contains($0.lowercased()) }
    }
}
