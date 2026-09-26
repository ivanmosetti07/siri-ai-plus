import Foundation

extension Assistant {
    // MARK: - Il progetto come contesto principale
    //
    // Una chat collegata a un progetto tiene la cartella come contesto anche con altre app aperte: prima di ogni risposta
    // la guida del progetto apre i file indicati dalle istruzioni (o nominati, o del giorno richiesto) e li passa al modello.
    // Apple Intelligence riceve i file già aperti; i modelli con gli strumenti anche le istruzioni complete e quelle delle
    // sottocartelle quando le toccano.

    /// Regola comune a tutti i modelli per le chat di un progetto.
    static func projectRule(_ project: String) -> String {
        if Language.isEnglish {
            return """
            This chat is linked to the project «\(project)»: its folder is the main context, even when other apps are open. \
            For questions about the work, the status, the goals, the clients, the tasks or what happened, use the project files \
            (the ones you receive or open following the project instructions), not the calendar, notes or the web, and don't answer from memory: \
            if a file you would need is missing, say so. Follow the project instructions to know where things are, where to save and how to behave.
            """
        }
        return """
        Questa chat è collegata al progetto «\(project)»: la sua cartella è il contesto principale, anche quando sono aperte altre app. \
        Per domande sul lavoro, sullo stato, sugli obiettivi, sui clienti, sulle attività o su cosa è successo usa i file del progetto \
        (quelli che ricevi o che apri seguendo le istruzioni del progetto), non calendario, note o web, e non rispondere a memoria: \
        se un file che servirebbe non c'è, dillo. Segui le istruzioni del progetto per sapere dove stanno le cose, dove salvare e come comportarti.
        """
    }

    /// Caselle Markdown in parole, solo per leggere: «- [ ] …» → «- (da fare) …», «- [x] …» → «- (fatto) …».
    /// Anche i modelli piccoli capiscono così cosa resta da fare (con le caselle Apple riassumeva solo le attività fatte).
    nonisolated static func spelledTasks(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^(\s*[-*+]\s+)\[ \]\s*"#, with: "$1(da fare) ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^(\s*[-*+]\s+)\[[xX]\]\s*"#, with: "$1(fatto) ", options: .regularExpression)
    }

    /// La prima volta legge l'albero della cartella (per cartelle grandi 1–2 secondi); poi è già pronto.
    func prepareProject(status: @escaping @MainActor (String) -> Void) async {
        guard let guide = work.guide else { return }
        if guide.readyTree == nil { status("Leggo la cartella del progetto…") }
        await guide.prepare()
    }

    /// Per i modelli esterni (stessa preparazione, senza stato da mostrare).
    public func prepareProject() async {
        await work.guide?.prepare()
    }

    /// I file del progetto aperti per la richiesta, pronti per il modello (nil se la richiesta non riguarda il progetto).
    func projectContext(for prompt: String) -> String? {
        guard !readingForTool, let guide = work.guide, let project = work.projectName else { return nil }
        if let cached = projectContextCache, cached.prompt == prompt { return cached.text }
        let started = Date.now
        let picks = guide.relevant(to: prompt, limit: budget.scale >= 4 ? 4 : 2).filter { !projectReads.contains($0.path) }
        guard !picks.isEmpty else {
            projectContextCache = (prompt, nil)
            return nil
        }
        // Spazio per i file: con Apple Intelligence circa 2.400 caratteri in tutto, di più con le finestre grandi.
        let total = budget.scaled(2400)
        let each = max(800, total / picks.count)
        var blocks: [String] = []
        var opened: [ProjectGuide.Pick] = []
        for pick in picks {
            guard let text = guide.excerpt(of: pick.path, for: prompt, limit: each), !text.isEmpty else { continue }
            blocks.append(Self.untrusted(Self.spelledTasks(text), label: pick.path))
            opened.append(pick)
            projectReads.insert(pick.path)
        }
        guard !opened.isEmpty else {
            projectContextCache = (prompt, nil)
            return nil
        }
        // Con le finestre grandi anche le regole delle sottocartelle dei file aperti (come e dove scrivere lì).
        if budget.scale >= 2 {
            for pick in opened {
                guard let rules = newFolderInstructions(for: pick.path, limit: budget.scale >= 4 ? 2500 : 1200) else { continue }
                blocks.append(rules)
            }
        }
        let text = "Dal progetto «\(project)»: file aperti per questa richiesta seguendo le istruzioni del progetto ("
            + opened.map { "\($0.path): \($0.reason)" }.joined(separator: "; ")
            + "). Rispondi direttamente basandoti su questi file, senza premesse sui file aperti e senza percorsi tra parentesi quadre; "
            + "se manca qualcosa, dillo in una frase.\n" + blocks.joined(separator: "\n")
        trace?.steps.append(TraceStep(action: "file del progetto", detail: opened.map(\.path).joined(separator: " · "),
                                      result: "aperti per rispondere", milliseconds: Int(Date.now.timeIntervalSince(started) * 1000), ok: true))
        Agent.log("PROGETTO: \(opened.map { "\($0.path) (\($0.reason))" }.joined(separator: ", "))")
        // La risposta viene dai file: niente ripiego sul web, fantasia bassa.
        answeredFromMemory = false
        groundedAnswer = true
        projectContextCache = (prompt, text)
        return text
    }

    /// Le istruzioni della guida indicano (o la richiesta nomina) file per questa richiesta: rispondono loro, non il web.
    func projectAnswers(_ prompt: String) -> Bool {
        guard let guide = work.guide else { return false }
        return !guide.relevant(to: prompt, limit: 1).isEmpty
    }

    /// Istruzioni (CLAUDE.md, AGENTS.md) delle cartelle di un percorso non ancora date al modello in questa richiesta.
    func newFolderInstructions(for path: String, limit: Int) -> String? {
        guard let guide = work.guide else { return nil }
        let fresh = guide.folderInstructions(for: path, limit: limit).filter { !folderInstructionsSent.contains($0.folder) }
        guard !fresh.isEmpty else { return nil }
        for item in fresh { folderInstructionsSent.insert(item.folder) }
        return fresh.map { "Istruzioni della cartella «\($0.folder)», da seguire lavorando lì:\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// Regole per chi scrive un file del progetto: quelle della sua cartella (formato, nomi, dove va cosa).
    func writingRules(for path: String?) -> String {
        guard let path, !path.isEmpty, let guide = work.guide else { return "" }
        let rules = guide.folderInstructions(for: path, limit: textWriter == nil ? 700 : 3000).map(\.text).joined(separator: "\n")
        return rules.isEmpty ? "" : "\nRegole della cartella in cui si scrive (rispettale):\n\(rules)"
    }

    /// La risposta non bastava: si cerca nei file del progetto prima che sul web. nil se il progetto non ha niente.
    public func projectSearchAnswer(_ prompt: String) async -> String? {
        guard let guide = work.guide, let project = work.projectName else { return nil }
        let hits = await guide.search(prompt, limit: budget.scale >= 4 ? 6 : 3).filter { !projectReads.contains($0.path) }
        guard !hits.isEmpty else { return nil }
        var blocks: [String] = []
        let each = max(700, budget.scaled(2200) / hits.count)
        for hit in hits {
            let text = guide.excerpt(of: hit.path, for: prompt, limit: each) ?? hit.snippet
            blocks.append(Self.untrusted(Self.spelledTasks(text), label: hit.path))
            projectReads.insert(hit.path)
        }
        trace?.steps.append(TraceStep(action: "cerca nel progetto", detail: hits.map(\.path).joined(separator: " · "),
                                      result: "\(hits.count) file", milliseconds: 0, ok: true))
        Agent.log("PROGETTO, RICERCA: \(hits.map(\.path))")
        return grounded(prompt, "File del progetto «\(project)» che contengono le parole della richiesta:\n" + blocks.joined(separator: "\n"),
                        label: "file del progetto")
    }
}
