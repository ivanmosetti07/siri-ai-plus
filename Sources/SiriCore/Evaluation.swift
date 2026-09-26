import Foundation
import FoundationModels

// MARK: - Banco di prova della qualità delle risposte

/// Una domanda con esito verificabile: espressioni che la risposta deve (o non deve) contenere, tipo di esito, uso del web.
public struct EvalCase: Codable, Sendable {
    public var id: String
    public var category: String
    /// Messaggi dell'utente in ordine: con più di uno si valuta l'ultima risposta (coerenza tra i turni).
    public var turns: [String]
    /// Espressioni regolari che devono comparire tutte (maiuscole, accenti e grassetti ignorati).
    public var expected: [String]
    /// Espressioni che non devono comparire.
    public var forbidden: [String]
    /// Esiti ammessi (risposta, web, agenda, piano, scheda:…): vuoto = qualsiasi.
    public var outcomes: [String]
    /// true: la risposta deve basarsi su una ricerca sul web; false: non deve (domande a cui si risponde senza); nil: indifferente.
    public var needsWeb: Bool?
    /// Righe minime della risposta (testi creativi).
    public var minLines: Int?
    /// Immagine allegata (percorso relativo al file delle domande).
    public var image: String?
    /// La domanda si fa dentro un progetto di prova (file e cartelle come in `selftest.sh`).
    public var inProject: Bool
    /// Documento aperto al centro durante la domanda: tipo (documento, foglio, presentazione), titolo e contenuto.
    public var artifact: [String: String]?
    /// Ciò che l'utente vede nella scheda davanti: app, tipo (email, nota, evento, promemoria, contatto, conversazione, file,
    /// registrazione), titolo, dettagli, testo, riferimento, nome, telefono, email, inizio/fine (eventi, ISO 8601).
    public var screen: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, category = "categoria", prompt = "domanda", turns = "turni", expected = "deve", forbidden = "vieta"
        case outcomes = "esiti", needsWeb = "web", minLines = "righe", image = "immagine", inProject = "progetto", artifact = "artefatto"
        case screen = "schermo"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "varie"
        if let turns = try c.decodeIfPresent([String].self, forKey: .turns) {
            self.turns = turns
        } else {
            turns = [try c.decode(String.self, forKey: .prompt)]
        }
        expected = try c.decodeIfPresent([String].self, forKey: .expected) ?? []
        forbidden = try c.decodeIfPresent([String].self, forKey: .forbidden) ?? []
        outcomes = try c.decodeIfPresent([String].self, forKey: .outcomes) ?? []
        needsWeb = try c.decodeIfPresent(Bool.self, forKey: .needsWeb)
        minLines = try c.decodeIfPresent(Int.self, forKey: .minLines)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        inProject = try c.decodeIfPresent(Bool.self, forKey: .inProject) ?? false
        artifact = try c.decodeIfPresent([String: String].self, forKey: .artifact)
        screen = try c.decodeIfPresent([String: String].self, forKey: .screen)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(category, forKey: .category)
        try c.encode(turns, forKey: .turns)
        try c.encode(expected, forKey: .expected)
        try c.encode(forbidden, forKey: .forbidden)
        try c.encode(outcomes, forKey: .outcomes)
        try c.encodeIfPresent(needsWeb, forKey: .needsWeb)
        try c.encodeIfPresent(minLines, forKey: .minLines)
        try c.encodeIfPresent(image, forKey: .image)
        if inProject { try c.encode(inProject, forKey: .inProject) }
        try c.encodeIfPresent(artifact, forKey: .artifact)
        try c.encodeIfPresent(screen, forKey: .screen)
    }
}

public struct EvalResult: Codable, Sendable {
    public var id: String
    public var category: String
    public var prompt: String
    public var answer: String
    public var outcome: String
    public var action: String
    public var usedWeb: Bool
    public var seconds: Double
    public var failures: [String]
    public var passed: Bool { failures.isEmpty }
}

/// Risposta finale di un esito, prodotta senza interfaccia con la stessa strada dell'app.
public struct HeadlessAnswer: Sendable {
    public var text: String
    public var outcome: String
    public var usedWeb: Bool
}

extension Assistant {
    /// Tipo di esito in una parola, per tracce e valutazioni.
    public static func kind(of outcome: Outcome) -> String {
        switch outcome {
        case .reply: "risposta"
        case .web: "web"
        case .agenda: "agenda"
        case .items: "elementi"
        case .files: "file"
        case .message: "messaggio"
        case .taskPlan: "piano"
        case .combined(let items): items.last.map(kind(of:)) ?? "risposta"
        case .eventDraft: "scheda:evento"
        case .reminderDrafts: "scheda:promemoria"
        case .confirm: "scheda:conferma"
        case .eventEdit: "scheda:modifica-evento"
        case .reminderEdit: "scheda:modifica-promemoria"
        case .noteAppend: "scheda:aggiunta-nota"
        case .mailReply: "scheda:risposta-email"
        case .mailForward: "scheda:inoltro-email"
        case .mailDraft: "scheda:email"
        case .messageDraft: "scheda:messaggio"
        case .noteDraft: "scheda:nota"
        case .document: "scheda:documento"
        case .sheet: "scheda:foglio"
        case .deck: "scheda:presentazione"
        case .plan: "scheda:piano"
        case .fileWrite, .fileOp: "scheda:file"
        case .mcpCall: "scheda:connettore"
        case .image: "scheda:immagine"
        case .website: "scheda:sito"
        case .agentDraft: "scheda:agente"
        case .newChat: "scheda:chat"
        case .remembered: "ricordo"
        case .artifactEdit: "modifica"
        case .writeDocument: "scheda:documento"
        case .browse: "browser"
        case .unavailable: "non disponibile"
        }
    }

    /// Il documento, la presentazione o il foglio di prova dopo la modifica, in forma di testo.
    func applied(_ edit: ArtifactEdit) -> String {
        switch edit {
        case .document(let plan):
            return (work.openDocument?.applying(plan.operations).rendered() ?? "") + "\n---\n" + plan.summary
        case .deck(let plan):
            guard var deck = work.openDeck else { return plan.summary }
            deck.apply(plan.operations)
            return deck.slides.enumerated().map { "\($0.offset + 1). \($0.element.title)" + ($0.element.bodyText.isEmpty ? "" : " — " + $0.element.bodyText.replacingOccurrences(of: "\n", with: "; ")) }
                .joined(separator: "\n") + "\n---\n" + plan.summary
        case .sheet(let plan, _):
            guard var sheet = work.openSheet else { return plan.summary }
            sheet.apply(plan.operations)
            return sheet.described() + "\nGrafici: \(sheet.charts.map { "\($0.kind.rawValue) \($0.range)" }.joined(separator: ", "))\n---\n" + plan.summary
        case .instruction(let text):
            return "[istruzione] " + text
        }
    }

    /// Scrive il testo di una risposta con il modello scelto (Apple Intelligence o Gemma locale).
    func headlessText(_ prompt: String, provider: ResponseProvider) async throws -> String {
        guard provider == .gemma || provider == .ds4 else {
            let fitted = await fitPrompt(prompt)
            return try await answer(fitted.prompt)
        }
        let history = fitting(historyTurns, characters: budget.historyCharacters)
        let base = provider == .gemma ? ExternalEngine.gemmaURL : ExternalEngine.ds4URL
        var final = ""
        for try await text in ExternalEngine.streamOpenAICompatible(base: base, model: provider.rawValue, system: chatInstructions(),
                                                                    history: history, prompt: prompt) { final = text }
        return final
    }

    /// Porta un esito fino alla risposta finale come fa l'app: streaming del prompt, ripiego sul web se il modello non sa,
    /// piani di lavoro con i sub-agent. Le schede da confermare restano bozze (nessuna modifica ai dati).
    public func headlessAnswer(for outcome: Outcome, request: String, enabled: Set<SourceKind>,
                               provider: ResponseProvider = .apple) async -> HeadlessAnswer {
        let kind = Self.kind(of: outcome)
        do {
            switch outcome {
            case .combined(let items):
                guard let last = items.last else { return HeadlessAnswer(text: "", outcome: kind, usedWeb: false) }
                let used = items.contains { if case .web = $0 { true } else { false } }
                var answer = await headlessAnswer(for: last, request: request, enabled: enabled, provider: provider)
                answer.usedWeb = answer.usedWeb || used
                return answer
            case .reply(let prompt):
                let fromMemory = answeredFromMemory
                let text = try await headlessText(prompt, provider: provider)
                // Come nell'app: se il modello ammette di non sapere, si cerca sul web e si risponde con le fonti.
                if fromMemory, work.webEnabled, Self.soundsUnsure(text) {
                    let query = lastRequest.isEmpty ? request : lastRequest
                    if case .web(_, let grounded) = try await searchWeb(query, prompt: query, status: { _ in }) {
                        return HeadlessAnswer(text: try await headlessText(grounded, provider: provider), outcome: "web", usedWeb: true)
                    }
                }
                return HeadlessAnswer(text: text, outcome: kind, usedWeb: false)
            case .agenda(_, let prompt), .items(_, let prompt), .files(_, let prompt):
                return HeadlessAnswer(text: try await headlessText(prompt, provider: provider), outcome: kind, usedWeb: false)
            case .web(_, let prompt):
                return HeadlessAnswer(text: try await headlessText(prompt, provider: provider), outcome: kind, usedWeb: true)
            case .message(let text):
                return HeadlessAnswer(text: text, outcome: kind, usedWeb: false)
            case .artifactEdit(let edit):
                // Modifica applicata al documento di prova: la risposta è il risultato, da controllare con le espressioni attese.
                return HeadlessAnswer(text: applied(edit), outcome: kind, usedWeb: false)
            case .document(let draft) where draft.body != nil:
                return HeadlessAnswer(text: draft.body ?? "", outcome: "scheda:documento", usedWeb: false)
            case .taskPlan(let plan):
                let done = await runHeadless(plan, enabled: enabled) { Agent.log($0) }
                let text = try await headlessText(taskSynthesisPrompt(done), provider: provider)
                let searched = done.steps.contains { Self.stepNeedsTools($0.instruction) && $0.instruction.lowercased().contains("web") }
                return HeadlessAnswer(text: text, outcome: kind, usedWeb: searched)
            default:
                return HeadlessAnswer(text: "[\(kind)]", outcome: kind, usedWeb: false)
            }
        } catch {
            return HeadlessAnswer(text: "Errore: \(error)", outcome: "errore", usedWeb: false)
        }
    }
}

@MainActor
public enum Evaluation {
    /// Schermo di prova (come lo descrivono le app): «schermo» nei casi del banco.
    static func testScreen(_ fields: [String: String]) -> ScreenItem? {
        guard let kind = ScreenItem.Kind(rawValue: [
            "nota": "note", "evento": "event", "promemoria": "reminder", "contatto": "contact", "conversazione": "chat",
            "registrazione": "memo", "vista": "overview",
        ][fields["tipo"] ?? ""] ?? fields["tipo"] ?? "") else { return nil }
        var item = ScreenItem(app: fields["app"] ?? "Mail", kind: kind, title: fields["titolo"] ?? "", details: fields["dettagli"] ?? "",
                              text: fields["testo"] ?? "", reference: fields["riferimento"],
                              nouns: (fields["parole"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        item.recipientName = fields["nome"]
        item.phone = fields["telefono"]
        item.email = fields["email"]
        switch kind {
        case .email:
            let sender = fields["nome"].map { name in fields["email"].map { "\(name) <\($0)>" } ?? name } ?? ""
            item.mail = MailMessage(id: fields["riferimento"] ?? "1", subject: item.title, sender: sender, date: fields["data"] ?? "", content: item.text)
        case .event:
            let start = fields["inizio"].flatMap { try? Date($0, strategy: .iso8601) } ?? .now.addingTimeInterval(86_400)
            let end = fields["fine"].flatMap { try? Date($0, strategy: .iso8601) } ?? start.addingTimeInterval(3600)
            item.event = EventItem(id: fields["riferimento"] ?? "E1", identifier: fields["riferimento"] ?? "E1", title: item.title, start: start, end: end,
                                   isAllDay: false, calendar: "Lavoro", color: RGB(red: 0, green: 0.4, blue: 1), location: fields["luogo"])
        case .reminder:
            item.reminder = ReminderItem(id: fields["riferimento"] ?? "R1", title: item.title, list: fields["lista"] ?? "Promemoria", due: nil,
                                         dueHasTime: false, highPriority: false, color: RGB(red: 0, green: 0.4, blue: 1))
        default:
            break
        }
        return item
    }

    public static func load(_ url: URL) throws -> [EvalCase] {
        try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: url))
    }

    /// Esegue le domande con la pipeline completa. Ogni caso parte da una conversazione nuova.
    public static func run(_ cases: [EvalCase], provider: ResponseProvider = .apple, web: Bool = true, folder: URL? = nil,
                           progress: (String) -> Void = { print($0) }) async -> [EvalResult] {
        // Nessuna richiesta di permessi: le fonti risultano collegate, ma il test non conferma mai schede.
        let enabled: Set<SourceKind> = [.calendar, .reminders, .mail, .notes, .files, .messages]
        var results: [EvalResult] = []
        for (index, test) in cases.enumerated() {
            let assistant = Assistant()
            var work = WorkContext()
            work.webEnabled = web
            // Come nell'app: tipo, titolo e un estratto di ciò che è aperto al centro.
            if let open = test.artifact {
                let content = open["contenuto"] ?? ""
                work.artifactKind = open["tipo"] ?? "documento"
                work.artifactTitle = open["titolo"] ?? "Senza titolo"
                work.artifactSummary = String(content.prefix(900))
                work.artifactText = content
                work.fullArtifactContextOnApple = provider == .apple
                switch work.artifactKind {
                case "presentazione": work.openDeck = testDeck(content, title: work.artifactTitle ?? "")
                case "foglio": work.openSheet = testSheet(content)
                default: work.openDocument = DocumentOutline(plain: content)
                }
            }
            if test.inProject, let root = testProject() {
                work.projectName = root.lastPathComponent
                work.projectRoot = root
                work.projectMemory = ProjectFiles(root: root).memoryFacts()
                // Come nell'app: la sintesi delle istruzioni (AGENTS.md, CLAUDE.md) per Apple Intelligence.
                if provider == .apple {
                    work.agents = await assistant.condense(agents: ProjectGuide.shared(for: root).instructions(limit: 12_000))
                }
            }
            work.screen = test.screen.flatMap(testScreen)
            assistant.work = work
            assistant.updateScreen()
            assistant.budget = provider == .apple ? ContextBudget.apple : ContextBudget.of(provider)
            // Con un altro modello scelto i testi dentro le azioni li scrive lui, come nell'app.
            assistant.textWriter = ExternalEngine.writer(for: provider)
            assistant.textWriterName = provider == .apple ? nil : provider.label
            let started = Date.now
            var answer = HeadlessAnswer(text: "", outcome: "", usedWeb: false)
            var action = ""
            // Immagine allegata come nell'app: descritta per le azioni e per i modelli esterni, guardata da Apple Intelligence.
            if let path = test.image, let folder {
                let url = folder.appending(path: path)
                if provider != .apple || assistant.asksForAction(test.turns.last ?? ""), let description = await assistant.describeImage(url) {
                    assistant.work.attachments = "Immagine «\(url.lastPathComponent)» (descritta da Apple Intelligence):\n\(description)"
                }
                assistant.work.images = provider == .apple ? [url] : []
            }
            for turn in test.turns {
                // Come nell'app: ogni turno nella lingua in cui è scritto (regole, risposta, compattazione).
                await Language.$scoped.withValue(assistant.language(for: turn)) {
                    let outcome = await assistant.handle(turn, enabled: enabled, picked: []) { _ in }
                    action = assistant.lastAction?.rawValue ?? ""
                    answer = await assistant.headlessAnswer(for: outcome, request: turn, enabled: enabled, provider: provider)
                    assistant.record(user: turn, reply: answer.text)
                    if test.turns.count > 1, turn != test.turns.last {
                        Agent.log("VALUTAZIONE \(test.id) turno: \(turn.prefix(80)) ⟶ \(answer.outcome) · \(answer.text.prefix(160).replacingOccurrences(of: "\n", with: " ¶ "))")
                    }
                    // Come nell'app dopo ogni risposta: con Apple Intelligence la chat si compatta oltre il 75% della finestra.
                    if provider == .apple, let compaction = await assistant.compactIfNeeded() {
                        Agent.log("VALUTAZIONE \(test.id): compattata dal \(Int(compaction.before * 100))% al \(Int(compaction.after * 100))%")
                    }
                }
            }
            let seconds = Date.now.timeIntervalSince(started)
            let failures = check(answer.text, test: test, outcome: answer.outcome, usedWeb: answer.usedWeb)
            let result = EvalResult(id: test.id, category: test.category, prompt: test.turns.joined(separator: " ⟶ "), answer: answer.text,
                                    outcome: answer.outcome, action: action, usedWeb: answer.usedWeb, seconds: seconds, failures: failures)
            results.append(result)
            progress("\(result.passed ? "✅" : "❌") [\(index + 1)/\(cases.count)] \(test.id) · \(answer.outcome) · \(String(format: "%.1f", seconds)) s"
                     + (result.passed ? "" : " · " + failures.joined(separator: "; ")))
            Agent.log("VALUTAZIONE \(test.id): \(result.passed ? "OK" : "NO") \(failures.joined(separator: "; ")) · \(answer.text.prefix(200).replacingOccurrences(of: "\n", with: " ¶ "))")
        }
        return results
    }

    /// Presentazione di prova da righe "1. Titolo — punto; punto".
    static func testDeck(_ text: String, title: String) -> Deck {
        let slides = text.components(separatedBy: "\n").compactMap { line -> Slide? in
            guard let match = Calculations.matches(#"^\s*\d+[.)]\s*(.+?)(?:\s+—\s+(.+))?$"#, in: line).first else { return nil }
            let bullets = match[2].isEmpty ? [] : match[2].components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            return Slide.make(.titoloElenco, title: match[1], bullets: bullets)
        }
        return Deck(title: title, slides: slides)
    }

    /// Foglio di prova da una tabella con le barre ("Voce | Ottobre | Novembre"); i totali diventano formule SOMMA.
    static func testSheet(_ text: String) -> Sheet {
        var sheet = Sheet(name: "Foglio 1", columns: 6, rows: 20)
        let rows = text.components(separatedBy: "\n").filter { $0.contains("|") }
            .map { $0.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
        for (r, cells) in rows.enumerated() {
            for (c, value) in cells.enumerated() { sheet.set(CellRef(col: c, row: r), value) }
        }
        // Colonna e riga "Totale" con formule vere, come nei fogli creati dall'app.
        if let totalRow = sheet.totalRowIndex {
            for c in 1..<sheet.usedSize.columns where totalRow > 1 {
                sheet.set(CellRef(col: c, row: totalRow), "=SOMMA(\(CellRef(col: c, row: 1).name):\(CellRef(col: c, row: totalRow - 1).name))")
            }
        }
        if let totalCol = sheet.totalColumnIndex {
            for r in 1..<(sheet.totalRowIndex ?? sheet.usedSize.rows) where totalCol > 1 {
                sheet.set(CellRef(col: totalCol, row: r), "=SOMMA(\(CellRef(col: 1, row: r).name):\(CellRef(col: totalCol - 1, row: r).name))")
            }
        }
        return sheet
    }

    /// Progetto di prova come quello di `selftest.sh`: qualche file Markdown e due cartelle.
    static func testProject() -> URL? {
        let root = FileManager.default.temporaryDirectory.appending(path: "valutazione-\(UUID().uuidString.prefix(6))/Progetto test")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root.appending(path: "4_Archivio"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appending(path: "2_Aree/linkedin/29-quattro-errori-file-stato"), withIntermediateDirectories: true)
            try "# Stato".write(to: root.appending(path: "STATE.md"), atomically: true, encoding: .utf8)
            try "# Leggimi".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
            try "# Task\n\n- [ ] Chiamare il commercialista per le fatture\n- [ ] Preparare il preventivo per Rossi Moto\n- [x] Aggiornare il sito\n"
                .write(to: root.appending(path: "TASKS.md"), atomically: true, encoding: .utf8)
            try """
            # Obiettivi Q3

            ## Q3-1 · Portare l'MRR dell'agenzia a 12.000 € al mese
            KR: 3 clienti FULL nuovi entro settembre.

            ## Q3-2 · Lanciare il corso «Agente AI» entro ottobre
            KR: 40 iscritti alla prima edizione.
            """.write(to: root.appending(path: "OBJECTIVES.md"), atomically: true, encoding: .utf8)
            // Un piccolo «second brain»: istruzioni con la mappa dei file, registro del giorno, un cliente, le persone.
            let today = Date.now.localDay
            let month = String(today.prefix(7))
            for folder in ["_Inbox", "3_Risorse/log/\(month)", "2_Aree/agenzia/1_Progetti/_clienti/rossi-moto"] {
                try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
            }
            let files: [String: String] = [
                "CLAUDE.md": """
                # Istruzioni del vault

                ## Cosa aprire, e quando

                | Se la richiesta riguarda | Apri prima di rispondere |
                |---|---|
                | cosa faccio oggi · priorità · stato delle aree | [STATE.md](STATE.md) |
                | obiettivi, KR, target del trimestre | [OBJECTIVES.md](OBJECTIVES.md) |
                | chi è una persona citata | [persone](3_Risorse/persone.md) |
                | salvare un contenuto grezzo, appunti nuovi da smistare | [_Inbox/CLAUDE.md](_Inbox/CLAUDE.md) |
                | un cliente dell'agenzia: come va, cosa è aperto | `2_Aree/agenzia/1_Progetti/_clienti/<slug>/INDEX.md` |
                """,
                "AGENTS.md": "# Regole\n\n1. I contenuti grezzi nuovi vanno in `_Inbox/`.\n2. Mai cancellare foto e video.\n3. Sempre in italiano.\n",
                "STATE.md": "# Stato\n\nPriorità di oggi:\n1. Chiudere il preventivo del sito per Rossi Moto.\n2. Registrare il video della lezione 3 del corso.\n",
                "_Inbox/CLAUDE.md": "# _Inbox\n\nQui vanno i contenuti grezzi nuovi (appunti, idee, materiale da smistare). Triage entro 7 giorni.\n",
                "3_Risorse/persone.md": "# Persone\n\n- **Martina Verdi**: marketing manager di Rossi Moto, referente per le campagne.\n- **Luca Bianchi**: commercialista di Ivan.\n",
                "3_Risorse/log/\(month)/\(today).md": "# \(today)\n\n### \(today) — DECISION: hosting del sito agenzia su Aruba\n- Chi: Ivan\n- Cosa: scelto Aruba come fornitore dell'hosting; chiamata con Luca Bianchi sulle fatture.\n- Esito: ✅\n",
                "2_Aree/agenzia/CLAUDE.md": "# Area agenzia\n\nI report ai clienti si scrivono in `3_Risorse/report/` con il nome report-<cliente>-AAAA-MM.md.\n",
                "2_Aree/agenzia/1_Progetti/_clienti/rossi-moto/INDEX.md": "# Rossi Moto\n\nCliente FULL da marzo: campagne Meta per le moto usate. Referente: Martina Verdi.\n",
                "2_Aree/agenzia/1_Progetti/_clienti/rossi-moto/STATE.md": "# Stato Rossi Moto\n\nAds in pausa fino al 30 settembre; aperto il preventivo per il sito nuovo (in attesa di risposta).\n",
            ]
            for (path, text) in files { try text.write(to: root.appending(path: path), atomically: true, encoding: .utf8) }
            return root
        } catch {
            return nil
        }
    }

    /// Motivi per cui la risposta non va bene (vuoto = superata). Minuscole, mesi e giorni dei segnaposto nella lingua della domanda:
    /// un banco in inglese si aspetta «November» e «Friday», non «novembre» e «venerdì».
    public static func check(_ answer: String, test: EvalCase, outcome: String, usedWeb: Bool, now: Date = .now) -> [String] {
        Language.$scoped.withValue(Language.detect(test.turns.joined(separator: "\n"), fallback: .it)) {
            failures(answer, test: test, outcome: outcome, usedWeb: usedWeb, now: now)
        }
    }

    private static func failures(_ answer: String, test: EvalCase, outcome: String, usedWeb: Bool, now: Date) -> [String] {
        let text = normalize(answer)
        var failures: [String] = []
        for pattern in test.expected where !matches(text, expand(pattern, now: now)) { failures.append("manca /\(pattern)/") }
        for pattern in test.forbidden where matches(text, expand(pattern, now: now)) { failures.append("contiene /\(pattern)/") }
        if !test.outcomes.isEmpty, !test.outcomes.contains(outcome) { failures.append("esito \(outcome) invece di \(test.outcomes.joined(separator: "/"))") }
        if test.needsWeb == true, !usedWeb { failures.append("non ha cercato sul web") }
        if test.needsWeb == false, usedWeb { failures.append("ha cercato sul web senza bisogno") }
        if answer.contains("<<<") || answer.contains(">>>") { failures.append("ricopia i delimitatori dei dati") }
        if !usedWeb, answer.range(of: #"\[\d\]"#, options: .regularExpression) != nil { failures.append("citazioni [n] senza fonti") }
        if let lines = test.minLines, answer.split(whereSeparator: \.isNewline).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count < lines {
            failures.append("meno di \(lines) righe")
        }
        if answer.hasPrefix("Errore:") { failures.append(String(answer.prefix(120))) }
        return failures
    }

    /// Minuscole, senza accenti né segni del markdown che spezzano le parole (grassetti, corsivi, codice).
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Dates.locale)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "’", with: "'")
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        let folded = pattern.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Dates.locale)
        guard let regex = try? NSRegularExpression(pattern: folded, options: [.caseInsensitive, .dotMatchesLineSeparators, .anchorsMatchLines]) else {
            return text.contains(folded)
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Segnaposto per le date relative: `{{data:+45:d MMMM}}` (oggi + 45 giorni), `{{giorni:12-25}}` (giorni che mancano).
    /// Mesi e giorni nella lingua in uso; in inglese "d MMMM" vale in tutti e due gli ordini ("7 November", "November 7").
    static func expand(_ pattern: String, now: Date) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{(data|giorni):([^}]*)\}\}"#) else { return pattern }
        var result = pattern
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        for match in regex.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)).reversed() {
            guard let whole = Range(match.range, in: pattern), let kindRange = Range(match.range(at: 1), in: pattern),
                  let argRange = Range(match.range(at: 2), in: pattern) else { continue }
            let arg = String(pattern[argRange])
            var values: [String] = []
            if pattern[kindRange] == "data" {
                let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
                let offset = Int(parts.first ?? "0") ?? 0
                let format = parts.count > 1 ? parts[1] : "d MMMM"
                if let date = calendar.date(byAdding: .day, value: offset, to: today) {
                    let formatter = DateFormatter()
                    formatter.locale = Dates.locale
                    var formats = [format]
                    if Language.isEnglish, format.hasPrefix("d MMMM") { formats.append("MMMM d" + format.dropFirst("d MMMM".count)) }
                    values = formats.map { formatter.dateFormat = $0; return formatter.string(from: date) }
                }
            } else {
                let parts = arg.split(separator: "-").compactMap { Int($0) }
                if parts.count == 2, let next = calendar.nextDate(after: today.addingTimeInterval(-1), matching: DateComponents(month: parts[0], day: parts[1]),
                                                                  matchingPolicy: .nextTime) {
                    values = [String(calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: next)).day ?? 0)]
                }
            }
            let escaped = values.map(NSRegularExpression.escapedPattern(for:))
            result.replaceSubrange(Range(match.range, in: result) ?? whole, with: escaped.count > 1 ? "(?:" + escaped.joined(separator: "|") + ")" : escaped.first ?? "")
        }
        return result
    }

    /// Resoconto in Markdown: totale, categorie, casi non superati con la risposta.
    public static func report(_ results: [EvalResult], provider: ResponseProvider, instructionTokens: Int?, contextSize: Int,
                              previous: [EvalResult]? = nil, date: Date = .now) -> String {
        let passed = results.filter(\.passed).count
        let seconds = results.map(\.seconds).sorted()
        let median = seconds.isEmpty ? 0 : seconds[seconds.count / 2]
        var lines = [
            "# Valutazione delle risposte · \(provider.label)",
            "",
            "\(Dates.format(date)) · **\(passed)/\(results.count) superate (\(results.isEmpty ? 0 : passed * 100 / results.count)%)** · tempo mediano \(String(format: "%.1f", median)) s"
                + (instructionTokens.map { " · istruzioni della chat \($0) token su \(contextSize)" } ?? ""),
            "",
            "| Categoria | Superate |",
            "| --- | --- |",
        ]
        let categories = results.reduce(into: [String]()) { if !$0.contains($1.category) { $0.append($1.category) } }
        for category in categories {
            let group = results.filter { $0.category == category }
            lines.append("| \(category) | \(group.filter(\.passed).count)/\(group.count) |")
        }
        if let previous {
            let before = Dictionary(previous.map { ($0.id, $0.passed) }, uniquingKeysWith: { a, _ in a })
            let better = results.filter { $0.passed && before[$0.id] == false }.map(\.id)
            let worse = results.filter { !$0.passed && before[$0.id] == true }.map(\.id)
            lines += ["", "Rispetto alla valutazione precedente: \(previous.filter(\.passed).count)/\(previous.count) → \(passed)/\(results.count)."]
            if !better.isEmpty { lines.append("- Migliorate: \(better.joined(separator: ", "))") }
            if !worse.isEmpty { lines.append("- Peggiorate: \(worse.joined(separator: ", "))") }
        }
        let failed = results.filter { !$0.passed }
        if !failed.isEmpty {
            lines += ["", "## Non superate", ""]
            for result in failed {
                lines.append("### \(result.id) · \(result.category)")
                lines.append("")
                lines.append("**Domanda:** \(result.prompt)")
                lines.append("")
                lines.append("**Esito:** \(result.outcome) (azione \(result.action.isEmpty ? "—" : result.action)) · \(String(format: "%.1f", result.seconds)) s · \(result.failures.joined(separator: "; "))")
                lines.append("")
                lines.append(result.answer.prefix(900).split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n"))
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `siriai --eval [file.json] [--provider apple|gemma] [--senza-web] [--solo testo] [--out cartella]`
    public static func main(_ arguments: [String]) async -> Int32 {
        var args = arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            let value = args[index + 1]
            args.removeSubrange(index...(index + 1))
            return value
        }
        let provider = value("--provider").flatMap(ResponseProvider.init(rawValue:)) ?? .apple
        let only = value("--solo")
        let out = URL(fileURLWithPath: value("--out") ?? "output/valutazioni")
        let web = !args.contains("--senza-web")
        args.removeAll { $0 == "--senza-web" }
        let file = URL(fileURLWithPath: args.first ?? "Support/eval/qualita.json")
        guard var cases = try? load(file) else {
            print("❌ Non riesco a leggere \(file.path)")
            return 1
        }
        if let only { cases = cases.filter { $0.id.contains(only) || $0.category == only } }
        if let problem = Agent.availabilityProblem, provider == .apple {
            print("❌ \(problem)")
            return 1
        }
        if provider == .gemma, !(await ExternalEngine.gemmaRunning()) {
            print("❌ Gemma non è in esecuzione: avviala dall'app (Impostazioni › Modelli).")
            return 1
        }
        let probe = Assistant()
        let tokens = try? await Agent.model.tokenCount(for: Instructions(probe.chatInstructions()))
        print("Valuto \(cases.count) domande con \(provider.label)" + (tokens.map { " · istruzioni \($0) token su \(Agent.model.contextSize)" } ?? ""))
        let results = await run(cases, provider: provider, web: web, folder: file.deletingLastPathComponent())

        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let stamp = { () -> String in
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmm"
            return f.string(from: .now)
        }()
        // Confronto con l'ultima valutazione completa dello stesso file di domande e dello stesso modello.
        let stem = file.deletingPathExtension().lastPathComponent
        let previousFile = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix("-\(stem)-\(provider.rawValue).json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.last
        let previous = only == nil ? previousFile.flatMap { try? JSONDecoder().decode([EvalResult].self, from: Data(contentsOf: $0)) } : nil
        let markdown = report(results, provider: provider, instructionTokens: tokens, contextSize: Agent.model.contextSize, previous: previous)
        let name = "\(stamp)-\(stem)-\(provider.rawValue)\(only.map { "-\($0)" } ?? "")"
        try? markdown.write(to: out.appending(path: "\(name).md"), atomically: true, encoding: .utf8)
        if only == nil, let data = try? JSONEncoder().encode(results) { try? data.write(to: out.appending(path: "\(name).json")) }
        let passed = results.filter(\.passed).count
        print("\nSuperate \(passed)/\(results.count) · resoconto: \(out.appending(path: "\(name).md").path)")
        return 0
    }
}
