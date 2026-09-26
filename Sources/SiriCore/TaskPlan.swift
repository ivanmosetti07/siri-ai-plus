import Foundation
import FoundationModels

/// Compito complesso: ragionamento visibile, passi in ordine, eseguiti da sub-agent con finestre di contesto separate.
public struct TaskPlan: Codable, Sendable, Equatable {
    public enum Delivery: String, Codable, Sendable { case risposta, documento }

    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public var id = UUID()
        public var title: String
        public var instruction: String
        /// Può partire insieme al passo precedente (nessuna dipendenza).
        public var parallel: Bool
        public var status: String = "attesa"   // attesa, corso, fatto, errore, conferma
        public var result: String = ""
        /// Con ChatGPT e Claude: quanto è impegnativo il passo (lo valuta Apple Intelligence) e la versione che lo svolge.
        public var difficulty: StepDifficulty?
        public var subAgent: ModelSelection?

        public init(title: String, instruction: String, parallel: Bool) {
            self.title = title; self.instruction = instruction; self.parallel = parallel
        }
    }

    public var goal: String
    public var thoughts: [String]
    public var steps: [Step]
    public var delivery: Delivery

    public init(goal: String, thoughts: [String], steps: [Step], delivery: Delivery) {
        self.goal = goal; self.thoughts = thoughts; self.steps = steps; self.delivery = delivery
    }

    /// Gruppi di passi da eseguire insieme: un passo "in parallelo" si unisce al gruppo precedente.
    public func batches(maxParallel: Int) -> [[Int]] {
        var groups: [[Int]] = []
        for index in steps.indices {
            if steps[index].parallel, let last = groups.last, last.count < maxParallel {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups
    }
}

extension Assistant {
    /// Richieste con più parti o lavori di ricerca e analisi: meritano un piano di passi visibile.
    nonisolated public static func isComplex(_ prompt: String) -> Bool {
        // Il testo incollato tra virgolette è materiale da leggere: non rende complessa la richiesta.
        let lower = withoutQuotes(prompt).lowercased()
        let words = lower.split(separator: " ").count
        let explicit = ["ricerca approfondita", "analisi approfondita", "passo passo", "step by step", "fai un piano", "pianifica il lavoro",
                        "confronta", "analizza", "studia", "prepara un report", "prepara una relazione", "fai il punto"].contains(where: lower.contains)
        // Elenchi numerati veri ("1. ", "1) ") e trattini a inizio riga, non numeri come "1.500" o parole con il trattino.
        let listed = lower.range(of: #"(^|\n)\s*(1[.)]\s|[-•]\s)"#, options: .regularExpression) != nil
        let chained = [" e poi ", " poi ", " dopo ", " infine ", " quindi "].filter { lower.contains($0) }.count + (listed ? 1 : 0)
        let verbs = ["cerca", "leggi", "riassumi", "confronta", "scrivi", "prepara", "analizza", "trova", "crea", "elenca", "verifica", "calcola"]
            .filter { lower.contains($0) }.count
        return wantsPlan(prompt) || explicit && words >= 6 || (verbs >= 3 && words >= 12) || (chained >= 1 && verbs >= 2 && words >= 10)
            || words >= 45 || gathersFromSources(lower, words: words)
    }

    /// «Usa i sub-agent», «lavora a passi»: l'utente chiede esplicitamente di lavorare così.
    /// Non basta nominarli («perché i sub-agent non partono?» è una domanda) e «fammi un piano di allenamento» è un testo da scrivere.
    nonisolated public static func wantsPlan(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let asks = [#"\b(?:usa|usando|usare|con|attiva|lancia|fai lavorare|metti al lavoro)\s+(?:i\s+|dei\s+|più\s+|\d+\s+)?(?:sub[- ]?agent|sotto[- ]?agent)"#,
                    #"\b(?:lavora|procedi)\s+(?:a|per)\s+passi\b"#, #"\bdividi\s+il\s+(?:lavoro|compito)\b"#]
        return asks.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    /// Un quadro che mette insieme più fonti («prepara la settimana guardando calendario, task ed email»):
    /// ogni fonte è un passo, poi la sintesi. Non le azioni verso altri («scrivi a Marco…»), che hanno le loro schede.
    nonisolated static func gathersFromSources(_ lower: String, words: Int, areas: [String] = []) -> Bool {
        guard words >= 7 else { return false }
        let groups: [[String]] = [["calendario", "agenda", "impegni", "riunion", "appuntament"], ["email", "mail", "posta"], ["note ", "nota ", "appunti"],
                                  ["promemoria", "task", "attività", "cose da fare"], ["file", "progetto", "vault", "cartella", "documenti"],
                                  ["web", "internet", "notizie", "online", "in rete"], ["messaggi", "whatsapp", "sms", "chat con"],
                                  ["agency", "connettore", "crm"]]
        let named = groups.filter { $0.contains(where: (lower + " ").contains) }.count
        // Le fonti possono venire anche dallo smistatore, che le capisce senza che la richiesta le nomini.
        let routed = Set(areas).intersection(["calendario", "promemoria", "email", "messaggi", "note", "file", "web"]).count
        let synthesis = ["prepara", "analizza", "riassumi", "confronta", "fai il punto", "organizza", "pianifica", "incrocia", "metti insieme",
                         "valuta", "report", "resoconto", "sintesi", "panoramica", "quadro"].contains(where: lower.contains)
        let acting = ["scrivi a ", "scrivi un'email a", "scrivi una mail a", "manda ", "invia ", "rispondi a ", "sposta ", "crea un evento",
                      "ricordami", "aggiungi "].contains(where: lower.contains)
        return max(named, routed) >= 2 && synthesis && !acting
    }

    /// Il compito mette insieme più fonti secondo lo smistatore (per esempio «prepara la settimana»: calendario, promemoria, posta).
    nonisolated public static func gathersFromRoutedSources(_ prompt: String, areas: [String]) -> Bool {
        let lower = withoutQuotes(prompt).lowercased()
        return gathersFromSources(lower, words: lower.split(separator: " ").count, areas: areas)
    }

    private static let taskPlanSchema = makeSchema("PianoDiLavoro", [
        .required("ragionamento", .array(.string, min: 2, max: 5), "Catena di pensieri breve: come affronti il compito, una frase per punto"),
        .required("passi", .array(.object("Passo", [
            .required("titolo", .string, "Titolo breve del passo"),
            .required("istruzione", .string, "Istruzione completa e autonoma per chi eseguirà il passo, per esempio «Cerca sul web le ultime notizie su X» o «Leggi il file Y e riassumi Z»"),
            .required("in_parallelo", .bool, "true se il passo non ha bisogno del risultato del passo precedente"),
        ]), min: 2, max: 6), "Passi in ordine di esecuzione"),
        .required("consegna", .choice(["risposta", "documento"]), "documento se l'utente vuole un testo lungo da conservare (relazione, report), altrimenti risposta"),
    ])

    /// Catena di pensieri e lista dei passi, in ordine.
    public func makeTaskPlan(for prompt: String) async throws -> TaskPlan {
        var context = "Richiesta: \(prompt)"
        if work.projectRoot != nil { context += "\nSi lavora nel progetto «\(work.projectName ?? "")»: i passi possono leggere, cercare e modificare i suoi file." }
        if !work.mcpTools.isEmpty { context += "\nServizi collegati: \(Set(work.mcpTools.map(\.serverName)).sorted().joined(separator: ", "))." }
        let content = try await writer("""
        Sei un pianificatore: scomponi compiti complessi in pochi passi concreti che un assistente sa fare da solo: cercare sul web, leggere pagine, \
        leggere o cercare file, note, email, calendario, usare servizi collegati, analizzare e scrivere. L'ultimo passo prepara la risposta o il documento finale.
        """).respond(to: context, schema: Self.taskPlanSchema).content
        let steps = content.objects("passi").map {
            TaskPlan.Step(title: $0.string("titolo") ?? "Passo", instruction: $0.string("istruzione") ?? $0.string("titolo") ?? "",
                          parallel: $0.bool("in_parallelo") ?? false)
        }
        return Self.arranged(TaskPlan(goal: prompt, thoughts: content.strings("ragionamento"), steps: steps,
                                      delivery: TaskPlan.Delivery(rawValue: content.string("consegna") ?? "") ?? .risposta))
    }

    /// Ricerche e letture una dopo l'altra non dipendono tra loro: partono insieme. Il primo passo apre sempre il lavoro.
    nonisolated static func arranged(_ plan: TaskPlan) -> TaskPlan {
        var plan = plan
        for index in plan.steps.indices.dropFirst() where stepNeedsTools(plan.steps[index].instruction)
            && stepNeedsTools(plan.steps[index - 1].instruction) && gathers(plan.steps[index].instruction) {
            plan.steps[index].parallel = true
        }
        // Analisi e sintesi lavorano sui risultati dei passi prima: mai in parallelo con loro (anche se il modello lo scrive).
        for index in plan.steps.indices where !stepNeedsTools(plan.steps[index].instruction) { plan.steps[index].parallel = false }
        if let first = plan.steps.indices.first { plan.steps[first].parallel = false }
        return plan
    }

    /// Lo stesso pianificatore per i modelli esterni (Gemma, ChatGPT, Claude): istruzioni e richiesta, risposta in JSON.
    public func taskPlanRequest(for prompt: String) -> (system: String, prompt: String) {
        var context = "Richiesta: \(prompt)"
        if let project = work.projectName, work.projectRoot != nil {
            context += "\nSi lavora nel progetto «\(project)»: i passi possono leggere, cercare e modificare i suoi file seguendo le sue istruzioni."
        }
        if let screen = work.screen { context += "\nAperto nelle app: \(screen.app) · \(screen.title)." }
        if !work.mcpTools.isEmpty { context += "\nServizi collegati: \(Set(work.mcpTools.map(\.serverName)).sorted().joined(separator: ", "))." }
        context += "\nOggi è \(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Locale(identifier: "it_IT"))))."
        let system = """
        Sei il pianificatore di Siri AI+: scomponi un compito in 2–6 passi concreti che un sub-agent sa svolgere da solo con gli strumenti \
        (web, pagine, file del progetto, note, email, calendario, promemoria, messaggi, servizi collegati) o ragionando sui risultati. \
        Ogni istruzione deve bastare da sola, senza rimandi («come sopra»). I passi che non dipendono dal precedente hanno in_parallelo true. \
        L'ultimo passo prepara la risposta o il documento finale. Prima scrivi il ragionamento: 2–5 frasi brevi su come affronti il compito. \
        Il piano serve sempre, anche se il compito ti sembra semplice: almeno 2 passi, mai una risposta diretta al posto del piano. \
        Dati che cambiano (prezzi, orari, notizie, disponibilità) e fatti dell'utente (file, email, calendario) vanno cercati o letti, non ricordati.
        Rispondi solo con un oggetto JSON, senza altro testo:
        {"ragionamento": ["…", "…"], "passi": [{"titolo": "…", "istruzione": "…", "in_parallelo": false}], "consegna": "risposta"}
        («consegna»: "documento" se l'utente vuole un testo lungo da conservare, come una relazione o un report; altrimenti "risposta".)
        """
        return (system, context)
    }

    /// Il piano scritto da un modello esterno: il primo oggetto JSON della risposta (anche dentro un blocco di codice).
    nonisolated public static func parseTaskPlan(_ text: String, goal: String) -> TaskPlan? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else { return nil }
        let thoughts = (object["ragionamento"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        let steps = (object["passi"] as? [[String: Any]] ?? []).compactMap { item -> TaskPlan.Step? in
            let title = (item["titolo"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let instruction = (item["istruzione"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? title
            guard !instruction.isEmpty else { return nil }
            return TaskPlan.Step(title: title.isEmpty ? String(instruction.prefix(40)) : title, instruction: instruction,
                                 parallel: item["in_parallelo"] as? Bool ?? false)
        }
        guard steps.count >= 2 else { return nil }
        return arranged(TaskPlan(goal: goal, thoughts: thoughts, steps: Array(steps.prefix(6)),
                                 delivery: TaskPlan.Delivery(rawValue: object["consegna"] as? String ?? "") ?? .risposta))
    }

    /// Istruzioni per un sub-agent con un modello esterno: un passo solo, risultati completi, nessuna domanda.
    public static let subAgentRule = """
    Sei un sub-agent: svolgi solo il passo che ricevi, parte di un compito più grande, usando gli strumenti che servono. \
    Dati che cambiano (prezzi, orari, notizie, disponibilità) e fatti dell'utente (file, email, calendario, note) si cercano o si leggono \
    con gli strumenti, mai a memoria: se uno strumento non trova niente, dillo. \
    Riporta i risultati in modo completo e fedele (dati, nomi, date, cifre, fonti con i link): li userà chi scrive la risposta finale. \
    Non fare domande e non chiedere conferme; le azioni verso altri restano schede da confermare.
    """

    nonisolated private static func gathers(_ instruction: String) -> Bool {
        let lower = instruction.lowercased()
        return ["cerca", "trova", "leggi", "raccogli", "recupera", "ricerca", "controlla"].contains { lower.hasPrefix($0) || lower.contains(" \($0)") }
    }

    /// Il passo deve usare strumenti (web, file, app, connettori) o basta ragionare sui risultati precedenti?
    nonisolated public static func stepNeedsTools(_ instruction: String) -> Bool {
        let lower = instruction.lowercased()
        let sources = ["web", "internet", "sito", "pagina", "online", "file", "cartella", "documento", "nota", "note", "email", "mail", "posta",
                       "calendario", "promemoria", "messagg", "cerca", "trova", "notizie", "fonti", "connettore", "agency", "progetto", "http"]
        let thinking = ["analizza", "confronta", "riassumi i", "sintetizza", "valuta", "identifica", "organizza", "prepara un report", "prepara la risposta",
                        "scrivi il report", "scrivi la risposta", "redigi", "elabora", "calcola", "riassumi i dati", "riassumi i risultati"]
        if thinking.contains(where: lower.hasPrefix) { return ["cerca", "sul web", "file ", "http"].contains(where: lower.contains) }
        return sources.contains(where: lower.contains)
    }

    /// Ultimo passo di sola scrittura: lo svolge la risposta finale (in streaming) invece di un sub-agent.
    nonisolated public static func isFinalWriting(_ step: TaskPlan.Step) -> Bool {
        // «Prepara la risposta finale con i dati trovati»: il titolo basta, anche se l'istruzione nomina i dati raccolti.
        let title = step.title.lowercased()
        if ["risposta finale", "prepara la risposta", "scrivi la risposta", "report finale", "sintesi finale", "relazione finale", "risposta all'utente"]
            .contains(where: title.contains) { return true }
        let lower = step.instruction.lowercased() + " " + step.title.lowercased()
        return !stepNeedsTools(step.instruction) && ["report", "risposta", "riassum", "sintes", "scrivi", "prepara", "redigi", "relazione"].contains(where: lower.contains)
    }

    /// Esegue un piano senza interfaccia (prove e valutazioni): gruppi di sub-agent come nell'app; la sintesi resta a chi chiama.
    public func runHeadless(_ plan: TaskPlan, enabled: Set<SourceKind>, log: (String) -> Void = { _ in }) async -> TaskPlan {
        var plan = plan
        let finalIndex = plan.steps.count >= 2 && Self.isFinalWriting(plan.steps[plan.steps.count - 1]) ? plan.steps.count - 1 : nil
        for group in plan.batches(maxParallel: DeviceProfile.recommendedSubAgents) {
            let batch = group.filter { $0 != finalIndex }
            guard !batch.isEmpty, !Task.isCancelled else { continue }
            let previous = plan.steps.filter { !$0.result.isEmpty }.map { "\($0.title): \($0.result.prefix(600))" }.joined(separator: "\n")
            let base = work
            let workers = batch.map { index in
                let step = plan.steps[index]
                return Task { @MainActor () -> (Int, String) in
                    (index, await Self.runSubAgent(step, previous: previous, work: base, enabled: enabled))
                }
            }
            for worker in workers {
                let (index, text) = await worker.value
                plan.steps[index].result = text
                log("PASSO \(index + 1) \(plan.steps[index].title): \(text.prefix(140).replacingOccurrences(of: "\n", with: " "))")
            }
        }
        return plan
    }

    /// Un passo svolto da un sub-agent con una sessione nuova (le schede da confermare restano bozze).
    static func runSubAgent(_ step: TaskPlan.Step, previous: String, work: WorkContext, enabled: Set<SourceKind>) async -> String {
        let agent = Assistant()
        agent.isSubAgent = true
        agent.work = work
        do {
            guard stepNeedsTools(step.instruction) else {
                let request = step.instruction + (previous.isEmpty ? "" : "\n\nRisultati dei passi precedenti:\n\(previous.prefix(2400))")
                return try await agent.chat.respond(to: request, options: agent.responseOptions).content
            }
            let request = step.instruction + (previous.isEmpty ? "" : "\n\nContesto: \(previous.prefix(400))")
            switch await agent.handle(request, enabled: enabled, picked: [], status: { _ in }) {
            case .reply(let prompt), .agenda(_, let prompt), .items(_, let prompt), .files(_, let prompt), .web(_, let prompt):
                return try await agent.chat.respond(to: prompt, options: agent.responseOptions).content
            case .message(let text): return text
            case .unavailable(let source, _): return "Errore: \(source.label) non è disponibile."
            case let other: return "Scheda da confermare: \(String(describing: other).prefix(80))"
            }
        } catch {
            return "Errore: \(error.localizedDescription)"
        }
    }

    /// Prompt per la sintesi finale con i risultati di tutti i passi (entro il budget della finestra di contesto).
    public func taskSynthesisPrompt(_ plan: TaskPlan) -> String {
        let done = plan.steps.filter { !$0.result.isEmpty }
        let share = max(300, budget.scaled(2800) / max(1, done.count))
        let results = done.enumerated().map { "Passo \($0.offset + 1) — \($0.element.title):\n\($0.element.result.prefix(share))" }.joined(separator: "\n\n")
        remember("Compito «\(plan.goal.prefix(120))»: " + done.map(\.title).joined(separator: "; "))
        groundedAnswer = true
        return """
        \(preamble(for: plan.goal))Richiesta dell'utente: \(plan.goal)

        Risultati del lavoro svolto dai sub-agent:
        \(results)

        Scrivi la risposta finale completa e ben organizzata basandoti su questi risultati: comincia subito dal contenuto, senza saluti, \
        presentazioni o premesse sul lavoro fatto (il piano è già visibile). Non inventare dati che non ci sono; se qualcosa manca, dillo.\(formatHint)
        """
    }
}
