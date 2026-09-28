import Foundation

/// Diagnostica dalla CLI: `--decidi richiesta.json` (formato nativo di rizzo-flow, `POST /v1/decisions`) e
/// `--decisioni-smoke` (le fixture di rizzo-flow, per controllare che il port dia le stesse risposte).
public enum DecisionDiagnostics {
    /// Stato e domande di una richiesta nel formato di rizzo-flow.
    public static func request(from json: DecisionJSON) throws -> (DecisionState, [DecisionQuestion]) {
        guard let stateJSON = json["state"] else { throw DecisionError.invalid("manca «state»") }
        guard let fields = json["questions"]?.fields, !fields.isEmpty else { throw DecisionError.invalid("mancano le domande") }
        var questions: [DecisionQuestion] = []
        for field in fields {
            let body = field.value
            guard let type = body["type"]?.string, let kind = DecisionKind(rawValue: type) else {
                throw DecisionError.invalid("\(field.key): tipo sconosciuto")
            }
            var question = DecisionQuestion(id: field.key, kind: kind, instructions: body["instructions"]?.string ?? "")
            question.options = (body["options"]?.array ?? []).map { DecisionQuestion.Option($0["id"]?.string ?? "", $0["description"]?.string ?? "") }
            question.levels = (body["levels"]?.array ?? []).compactMap(\.string)
            question.anchors = (body["anchors"]?.array ?? []).map { DecisionQuestion.Anchor($0["value"]?.double ?? 0, $0["description"]?.string ?? "") }
            question.unit = body["unit"]?.string ?? ""
            if let yes = body["true_description"]?.string { question.trueDescription = yes }
            if let no = body["false_description"]?.string { question.falseDescription = no }
            if let policy = body["policy"] {
                question.policy = DecisionPolicy(allowAbstain: policy["allow_abstain"]?.bool ?? true,
                                                 maxUnavailable: policy["max_unavailable_probability"]?.double ?? 0.5,
                                                 minTop: policy["min_top_probability"]?.double ?? 0)
            }
            if let problem = question.problem { throw DecisionError.invalid(problem) }
            questions.append(question)
        }
        return (DecisionState(stateJSON), questions)
    }

    /// `--decidi richiesta.json`: risposte in breve, come `rizzo_client.py`.
    public static func decide(file: URL) async -> String {
        do {
            let json = try DecisionJSON.parse(try String(contentsOf: file, encoding: .utf8))
            let (state, questions) = try request(from: json)
            guard await DecisionEngine.shared.prepare() else { return "Motore non disponibile: \(await DecisionEngine.shared.status())" }
            guard let result = await DecisionEngine.shared.decide(state, questions, priority: .background, label: "prova") else {
                return "Nessuna risposta dal motore."
            }
            var lines = result.order.compactMap { id -> String? in
                guard let answer = result[id] else { return nil }
                let distribution = answer.probabilities.sorted { $0.probability > $1.probability }.prefix(5)
                    .map { "\($0.id) \(String(format: "%.3f", $0.probability))" }.joined(separator: ", ")
                return "\(id): \(answer.status.rawValue) → \(answer.summary) · \(distribution) · \(answer.milliseconds) ms"
            }
            lines.append("Totale \(result.milliseconds) ms, \(result.newTokens) token nuovi")
            return lines.joined(separator: "\n")
        } catch {
            return "Errore: \(error.localizedDescription)"
        }
    }

    /// `--decisioni-smoke [file.jsonl]`: ogni riga `{id, request, expected: {domanda: {label, status}}}`.
    public static func smoke(file: URL) async -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "File non leggibile: \(file.path)" }
        guard await DecisionEngine.shared.prepare() else { return "Motore non disponibile: \(await DecisionEngine.shared.status())" }
        var lines: [String] = []
        var right = 0, total = 0, statusRight = 0
        var times: [Int] = []
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            do {
                let json = try DecisionJSON.parse(String(line))
                let id = json["id"]?.string ?? "?"
                guard let requestJSON = json["request"] else { continue }
                let (state, questions) = try request(from: requestJSON)
                guard let result = await DecisionEngine.shared.decide(state, questions, priority: .background, label: "smoke") else {
                    lines.append("✗ \(id): nessuna risposta")
                    continue
                }
                times.append(result.milliseconds)
                for field in json["expected"]?.fields ?? [] {
                    total += 1
                    guard let answer = result[field.key] else { lines.append("✗ \(id).\(field.key): manca"); continue }
                    let label = field.value["label"]?.string ?? ""
                    let status = field.value["status"]?.string ?? ""
                    let ok = answer.winner == label
                    if ok { right += 1 }
                    if answer.status.rawValue == status { statusRight += 1 }
                    lines.append("\(ok ? "✓" : "✗") \(id).\(field.key): \(answer.winner) (atteso \(label)) · p \(String(format: "%.3f", answer.top)) · \(answer.status.rawValue)")
                }
            } catch {
                lines.append("✗ riga non valida: \(error.localizedDescription)")
            }
        }
        let median = times.isEmpty ? 0 : times.sorted()[times.count / 2]
        lines.append(String(format: "Accuratezza %d/%d (%.2f) · stato giusto %d/%d · mediana %d ms per richiesta",
                            right, total, total > 0 ? Double(right) / Double(total) : 0, statusRight, total, median))
        return lines.joined(separator: "\n")
    }
}

extension DecisionDiagnostics {
    /// `--decisioni-banco file.json`: per ogni richiesta di un banco le probabilità di area e azione della prima occhiata,
    /// accanto a ciò che il banco si aspetta. Serve a scegliere soglie e descrizioni sui dati, non a occhio.
    @MainActor public static func routing(file: URL) async -> String {
        guard let cases = try? Evaluation.load(file) else { return "File non leggibile: \(file.path)" }
        guard await DecisionEngine.shared.prepare() else { return "Motore non disponibile: \(await DecisionEngine.shared.status())" }
        var lines: [String] = []
        for test in cases where test.turns.count == 1 && !test.inProject && test.screen == nil && test.artifact == nil && test.connectors.isEmpty {
            let prompt = test.turns[0]
            let assistant = Assistant()
            var work = WorkContext()
            work.webEnabled = true
            assistant.work = work
            let line = await Language.$scoped.withValue(assistant.language(for: prompt)) { () -> String in
                let catalog = assistant.familyCatalog()
                let state = assistant.decisionState(for: prompt)
                let area = Assistant.areaQuestion(catalog)
                guard let areaAnswer = await DecisionEngine.shared.decide(state, area, priority: .background, label: "banco") else { return "\(test.id): nessuna risposta" }
                let top = areaAnswer.probabilities.sorted { $0.probability > $1.probability }
                let areaText = top.prefix(3).map { "\($0.id) \(String(format: "%.2f", $0.probability))" }.joined(separator: ", ")
                var actionText = ""
                if let best = top.first?.id, best != "none" {
                    let allowed = Assistant.Action.allCases.filter { assistant.actions(inFamilies: [best]).contains($0) && $0 != .piano }
                    if let question = Assistant.actionQuestion(allowed),
                       let answer = await DecisionEngine.shared.decide(state, question, priority: .background, label: "banco") {
                        actionText = " | azione: " + answer.probabilities.sorted { $0.probability > $1.probability }.prefix(3)
                            .map { "\($0.id) \(String(format: "%.2f", $0.probability))" }.joined(separator: ", ")
                    }
                }
                return "\(test.id) | \(prompt.prefix(60)) | atteso \(test.expected.joined(separator: " ")) | area: \(areaText)\(actionText)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

extension DecisionDiagnostics {
    /// `--decisioni-auto [file.json]`: per ogni richiesta i segnali di Auto (rizzo-flow) e il modello scelto, con Gemma
    /// pronto e ChatGPT come modello cloud. Il campo `modello` del banco è `apple`, `gemma` o `cloud`.
    @MainActor public static func auto(file: URL) async -> String {
        guard let data = try? Data(contentsOf: file),
              let cases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] else { return "File non leggibile: \(file.path)" }
        guard await DecisionEngine.shared.prepare() else { return "Motore non disponibile: \(await DecisionEngine.shared.status())" }
        let situation = AutoModel.Situation(gemma: true, cloud: ModelSelection(.chatgpt))
        var lines: [String] = []
        var right = 0, heuristicRight = 0
        var times: [Int] = []
        for test in cases {
            guard let prompt = test["domanda"], let expected = test["modello"] else { continue }
            let assistant = Assistant()
            let started = Date.now
            let (signals, heuristic) = await Language.$scoped.withValue(assistant.language(for: prompt)) {
                (await assistant.autoSignals(for: prompt), AutoModel.heuristicSignals(for: prompt))
            }
            times.append(Int(Date.now.timeIntervalSince(started) * 1000))
            let (selection, reason) = AutoModel.choose(signals, situation)
            let label = selection.provider.isLocal ? selection.provider.rawValue : "cloud"
            let old = AutoModel.choose(heuristic, situation).0
            let oldLabel = old.provider.isLocal ? old.provider.rawValue : "cloud"
            if label == expected { right += 1 }
            if oldLabel == expected { heuristicRight += 1 }
            lines.append("\(label == expected ? "✓" : "✗") \(test["id"] ?? "") → \(label) (atteso \(expected); parole chiave: \(oldLabel)) · \(reason)")
        }
        let median = times.isEmpty ? 0 : times.sorted()[times.count / 2]
        lines.append("Giuste \(right)/\(cases.count) con rizzo-flow · \(heuristicRight)/\(cases.count) con le parole chiave · mediana \(median) ms")
        return lines.joined(separator: "\n")
    }
}

extension DecisionDiagnostics {
    /// `--decisioni-memoria [file.json]`: se una frase va ricordata (rizzo-flow contro le parole spia di prima) e come un fatto
    /// nuovo si lega a quelli già ricordati. Frasi inventate.
    @MainActor public static func memory(file: URL) async -> String {
        guard let data = try? Data(contentsOf: file), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "File non leggibile: \(file.path)" }
        guard await DecisionEngine.shared.prepare() else { return "Motore non disponibile: \(await DecisionEngine.shared.status())" }
        var lines: [String] = []
        var right = 0, oldRight = 0, total = 0
        for item in json["ricordare"] as? [[String: Any]] ?? [] {
            guard let sentence = item["frase"] as? String, let expected = item["atteso"] as? Bool else { continue }
            total += 1
            let assistant = Assistant()
            let answer = await Language.$scoped.withValue(assistant.language(for: sentence)) {
                await DecisionEngine.shared.decide(DecisionState([("user_said", .string(sentence))]), Assistant.rememberQuestion,
                                                   priority: .background, label: "banco memoria")
            }
            let (old, decided) = await Language.$scoped.withValue(assistant.language(for: sentence)) {
                (Assistant.mayContainMemory(sentence), Assistant.worthRemembering(probability: answer?.probability(of: "true"), prompt: sentence))
            }
            if decided == expected { right += 1 }
            if old == expected { oldRight += 1 }
            lines.append("\(decided == expected ? "✓" : "✗") \(sentence.prefix(60)) → \(decided ? "sì" : "no") (atteso \(expected ? "sì" : "no"); parole spia: \(old ? "sì" : "no")) · p \(answer.map { String(format: "%.2f", $0.probability(of: "true")) } ?? "—")")
        }
        lines.append("Ricordare: \(right)/\(total) con rizzo-flow · \(oldRight)/\(total) con le parole spia")
        var relationRight = 0, relationTotal = 0
        for item in json["confronto"] as? [[String: Any]] ?? [] {
            guard let fact = item["nuovo"] as? String, let known = item["noti"] as? [String], let expected = item["atteso"] as? String else { continue }
            relationTotal += 1
            let answer = await DecisionEngine.shared.decide(Assistant.relationState(new: fact, known: known), Assistant.relationQuestion(known: known),
                                                            priority: .background, label: "banco memoria")
            let choice = answer?.winner ?? "—"
            if choice == expected { relationRight += 1 }
            lines.append("\(choice == expected ? "✓" : "✗") «\(fact)» → \(choice) (atteso \(expected)) · p \(answer.map { String(format: "%.2f", $0.top) } ?? "—")")
        }
        lines.append("Confronto: \(relationRight)/\(relationTotal)")
        return lines.joined(separator: "\n")
    }
}

extension DecisionDiagnostics {
    /// `--decisioni-anonimizza [elenco.json]`: la domanda di `PrivacyGate` su file inventati. Requisito: mai «nessun dato
    /// personale» sicuro su un file che ne contiene.
    public static func privacy(manifest: URL) async -> String {
        guard let data = try? Data(contentsOf: manifest), let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return "File non leggibile: \(manifest.path)" }
        guard await DecisionEngine.shared.prepare() else { return "Motore non disponibile: \(await DecisionEngine.shared.status())" }
        var lines: [String] = []
        var skipped = 0, clean = 0, violations = 0
        for item in items {
            guard let path = item["file"] as? String, let personal = item["personali"] as? Bool,
                  let text = try? String(contentsOf: manifest.deletingLastPathComponent().appending(path: path), encoding: .utf8) else { continue }
            guard let answer = await DecisionEngine.shared.decide(PrivacyGate.state(for: text), PrivacyGate.question, priority: .background,
                                                                  label: "banco anonimizzazione") else { lines.append("— \(path): nessuna risposta"); continue }
            let skip = answer.choice == "none" && answer.top >= PrivacyGate.confidence
            if !personal { clean += 1; if skip { skipped += 1 } }
            if personal && skip { violations += 1 }
            lines.append("\(personal && skip ? "✗" : "✓") \(path) → \(answer.winner) \(String(format: "%.2f", answer.top)) · rizzo-pii \(skip ? "saltato" : "sì")"
                         + " (dati personali: \(personal ? "sì" : "no")) · \(answer.milliseconds) ms")
        }
        lines.append("Saltati \(skipped) file senza dati personali su \(clean) · violazioni \(violations)")
        return lines.joined(separator: "\n")
    }

    /// `--anonimizza-tempi file`: quanto costa rizzo-pii sul testo intero e quanto la domanda a rizzo-flow (per la soglia).
    public static func privacyTiming(file: URL) async -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "File non leggibile: \(file.path)" }
        guard PIIEngine.isInstalled else { return "rizzo-pii non è installato" }
        _ = try? await PIIEngine.shared.entities(in: "Prova di caricamento.")
        var started = Date.now
        let entities = (try? await PIIEngine.shared.entities(in: text))?.count ?? 0
        let pii = Date.now.timeIntervalSince(started) * 1000
        guard await DecisionEngine.shared.prepare() else { return "Motore delle decisioni non disponibile" }
        started = Date.now
        let answer = await DecisionEngine.shared.decide(PrivacyGate.state(for: text), PrivacyGate.question, priority: .background, label: "tempi")
        let flow = Date.now.timeIntervalSince(started) * 1000
        let perThousand = pii / Double(max(text.count, 1)) * 1000
        return String(format: "rizzo-pii: %.0f ms per %d caratteri (%.0f ms ogni 1.000, %d entità) · rizzo-flow: %.0f ms (%@) · pareggio ≈ %.0f caratteri",
                      pii, text.count, perThousand, entities, flow, answer?.summary ?? "—", flow / max(perThousand, 0.001) * 1000)
    }
}
