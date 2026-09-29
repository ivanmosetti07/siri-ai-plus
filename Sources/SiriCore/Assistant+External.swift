import Foundation

// MARK: - Modelli esterni con gli strumenti (Gemma, ds4, ChatGPT, Claude)
//
// Lo stesso giro per l'app e per i banchi di prova: lo smistatore sceglie gli strumenti, il modello li chiama, le letture
// tornano al modello e ciò che scrive diventa una scheda da confermare. L'interfaccia (schede, testo in arrivo, stato)
// passa dai ganci `ExternalHooks`: l'app mostra, il banco registra.

/// Ciò che il giro esterno chiede a chi lo mostra.
public struct ExternalHooks: Sendable {
    public var status: ExternalAgent.StatusUpdate
    public var text: ExternalAgent.TextUpdate
    /// Mostra l'esito di uno strumento (dati letti, schede, documenti, memoria). Restituisce il testo da dare al modello
    /// al posto di quello dello strumento (per esempio «l'utente non ha dato il permesso di scrivere»), o nil.
    public var show: @MainActor @Sendable (_ tool: String, _ outcome: Outcome) async -> String?
    /// Esegue una chiamata a un connettore che parte da sola (lettura o strumento consentito dall'utente), con la sua scheda.
    public var callConnector: @MainActor @Sendable (MCPCallDraft) async throws -> String
    /// Gli strumenti dei connettori che partono senza conferma.
    public var runsFreely: @MainActor @Sendable (MCPToolInfo) -> Bool
    /// Le fonti dell'app collegate per questa risposta.
    public var enabled: Set<SourceKind>
    /// La CLI dell'app come ponte MCP per ChatGPT e Claude (nil: per loro niente strumenti).
    public var bridgeHelper: String?

    public init(status: @escaping ExternalAgent.StatusUpdate, text: @escaping ExternalAgent.TextUpdate,
                show: @escaping @MainActor @Sendable (String, Outcome) async -> String?,
                callConnector: @escaping @MainActor @Sendable (MCPCallDraft) async throws -> String,
                runsFreely: @escaping @MainActor @Sendable (MCPToolInfo) -> Bool, enabled: Set<SourceKind>, bridgeHelper: String?) {
        self.status = status; self.text = text; self.show = show; self.callConnector = callConnector
        self.runsFreely = runsFreely; self.enabled = enabled; self.bridgeHelper = bridgeHelper
    }
}

/// Una risposta di un modello esterno con gli strumenti.
public struct ExternalTurn: Sendable {
    /// Il testo finale del modello.
    public var text: String
    /// La richiesta con il contesto (preambolo), com'è partita.
    public var request: String
    /// Gli strumenti offerti al modello.
    public var tools: [String]
    /// Avviso dell'app da mostrare dopo la risposta: il modello dà per fatto ciò che aspetta ancora la conferma nella scheda.
    public var note: String? = nil
}

extension Assistant {
    /// Il modello esterno ammette di non sapere senza aver cercato: si cerca sul web, come sulla strada di Apple Intelligence.
    /// Restituisce l'esito `.web` da mostrare (fonti e richiesta con i dati), o nil.
    public func unsureWebFallback(_ answer: String, request: String) async -> Outcome? {
        guard work.webEnabled, work.attachments?.isEmpty != false, Self.soundsUnsure(answer),
              trace?.steps.contains(where: { $0.action == "cerca_web" }) != true else { return nil }
        let query = lastRequest.isEmpty ? request : lastRequest
        guard let outcome = try? await searchWeb(query, prompt: query, status: { _ in }), case .web = outcome else { return nil }
        Agent.log("RIPIEGO WEB: il modello non sapeva, cerco «\(query.prefix(80))»")
        return outcome
    }

    /// «Quanto fa 89,90 € più IVA al 22%?», «calcola il 15% di 80», «what's 15% of 80?»: un conto con tutti i numeri nella
    /// richiesta (il risultato lo calcola l'app). Non «quanto costa un iPhone 17?», che è un prezzo da cercare.
    nonisolated static func isSelfContainedCalculation(_ prompt: String) -> Bool {
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard Calculations.matches(#"\d+(?:[.,]\d+)?"#, in: lower).count >= 2 else { return false }
        let italian = #"^(?:e\s+)?(?:quanto\s+(?:fa|fanno|viene|vengono|è)|quant'è|calcola|calcolami)\b"#
        let english = #"^(?:and\s+)?(?:what(?:'s|\s+is)\s+\d|how\s+much\s+is\s+\d|calculate|compute|work\s+out)"#
        return lower.range(of: italian, options: .regularExpression) != nil
            || (Language.isEnglish && lower.range(of: english, options: .regularExpression) != nil)
    }

    /// Una domanda che non chiede di creare niente («qual è il budget totale?»; non «puoi crearmi un foglio?»).
    nonisolated static func asksWithoutCreating(_ prompt: String) -> Bool {
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.hasSuffix("?") else { return false }
        let creates = #"\b(?:cre[ao]\w*|fa[imr]\w*|prepar\w*|gener\w*|scriv\w*|nuov[oaie]|make|new|creat\w*|generat\w*|write|draft)\b"#
        return lower.range(of: creates, options: .regularExpression) == nil
    }
}

extension ExternalAgent {
    /// I testi degli strumenti che segnalano un errore (per il ponte MCP).
    public static func isErrorText(_ text: String) -> Bool { text.hasPrefix("Errore") || text.hasPrefix("Error") }
}

extension Assistant {
    /// Il sub-agent smistatore per i modelli esterni: sceglie dal catalogo degli strumenti dell'app solo quelli che servono.
    /// Prima rizzo-flow (anche senza Apple Intelligence), poi lo smistatore di Apple; nil solo con lo smistatore spento.
    public func routeForExternal(_ prompt: String, enabled: Set<SourceKind>, status: @escaping @MainActor (String) -> Void) async -> ToolRoute? {
        guard routesTools else { return nil }
        if Self.isSmallTalk(prompt) { return ToolRoute(decided: true) }
        status(Language.t("Scelgo gli strumenti…", "Choosing the tools…"))
        return await routeExternalTools(for: prompt, tools: ToolRegistry.tools(for: work, enabled: enabled))
    }

    /// Gli strumenti per un modello esterno: quelli dello smistatore più quelli che le parole della richiesta nominano
    /// (rete di sicurezza), il servizio collegato nominato o riconosciuto, il web quando serve; nessuno per saluti e testi
    /// da elaborare. Le finestre piccole (Gemma, ds4) ne ricevono meno, con descrizioni più corte.
    public func externalToolList(for prompt: String, route: ToolRoute?, enabled: Set<SourceKind>, picked: Set<SourceKind> = []) -> [ToolSpec] {
        let all = ToolRegistry.tools(for: work, enabled: enabled)
        // Saluti, testi da elaborare e «rispondi solo…»: niente strumenti (e nessun ponte MCP da avviare).
        if Self.isSmallTalk(prompt) || Self.isTextTask(prompt) || Self.isAnswerOnlyInstruction(prompt) {
            Agent.log("STRUMENTI AL MODELLO: nessuno (saluto o testo da elaborare)")
            return []
        }
        let hints = toolHints(for: prompt)
        var names: Set<String>
        if let route, route.decided {
            // «Nessuna area» per un consiglio o una domanda generale: le parole chiave non bastano a dare strumenti.
            let quiet = route.tools.isEmpty && Self.asksAdvice(prompt)
            names = Set(ToolRegistry.selecting(all, route: route, hints: quiet ? [] : hints).map(\.name))
        } else {
            names = Set(all.map(\.name))
        }
        // Fonti scelte dall'utente per questa richiesta (menu «+»): i loro strumenti ci sono sempre.
        if !picked.isEmpty {
            let base = Set(ToolRegistry.tools(for: work, enabled: []).map(\.name))
            names.formUnion(Set(ToolRegistry.tools(for: work, enabled: picked.intersection(enabled)).map(\.name)).subtracting(base))
        }
        // Connettori: il servizio nominato («su Demo CRM») o riconosciuto dalle parole del suo dominio dà sempre i suoi strumenti.
        let lower = prompt.lowercased()
        if let server = namedServer(lower) ?? strongServerMatch(lower) {
            for tool in work.mcpTools where tool.serverName == server { names.insert(ToolRegistry.mcpName(tool)) }
        }
        // Documento aperto: modifica_aperto solo per i comandi (alle domande si risponde dal suo testo), e a una domanda
        // («qual è il budget totale?») niente documenti nuovi.
        if work.artifactKind != nil {
            if Self.isArtifactCommand(prompt), !Self.isArtifactQuestion(prompt) { names.insert("modifica_aperto") } else { names.remove("modifica_aperto") }
            if Self.asksWithoutCreating(prompt) { names.subtract(["crea_documento", "crea_foglio", "crea_presentazione"]) }
        }
        // «Any news from my accountant?»: notizie da una persona, cioè la posta e i messaggi dell'utente, non il web.
        let fromSomeone = Self.newsFromSomeone(lower) != nil && Self.explicitWebQuery(prompt) == nil
        if fromSomeone { names.formUnion(["leggi_email", "leggi_messaggi"]) }
        // Il web: quando lo sceglie lo smistatore, per i fatti che cambiano, quando la richiesta lo chiede o lo smistatore non ha deciso.
        let wantsWeb = !fromSomeone && (Self.isTimeSensitive(prompt) || Self.explicitWebQuery(prompt) != nil)
        if wantsWeb || route?.decided != true { names.insert("cerca_web") }
        if fromSomeone { names.subtract(["cerca_web", "leggi_pagina"]) }
        // «Quanto fa 89,90 € più IVA al 22%?»: i numeri sono tutti nella richiesta e il conto lo fa l'app, il web non serve.
        if !wantsWeb, Self.isSelfContainedCalculation(prompt) { names.subtract(["cerca_web", "leggi_pagina"]) }
        var tools = all.filter { names.contains($0.name) }
        // Tetto per la finestra del modello: prima gli strumenti scelti dallo smistatore e dalle parole, poi le letture.
        let small = budget.tokens <= 32_768
        let limit = small ? 12 : 60
        if tools.count > limit {
            let preferred = Set(route?.tools ?? []).union(hints).union(["cerca_web"])
            func rank(_ tool: ToolSpec) -> Int { preferred.contains(tool.name) ? 0 : tool.kind == .read ? 1 : 2 }
            tools = Array(tools.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element).prefix(limit))
        }
        if small {
            tools = tools.map { tool in
                guard tool.name.hasPrefix("mcp__"), tool.description.count > 160 else { return tool }
                return ToolSpec(name: tool.name, description: String(tool.description.prefix(157)) + "…", parameters: tool.parameters, kind: tool.kind)
            }
        }
        Agent.log("STRUMENTI AL MODELLO: \(tools.count) su \(all.count) · \(tools.map(\.name).joined(separator: ", "))")
        return tools
    }

    /// Le indicazioni dei servizi collegati offerti al modello (da loro, non dall'utente): come usare i loro strumenti.
    func connectorGuide(for tools: [ToolSpec]) -> String {
        let offered = Set(tools.map(\.name))
        var servers: [String] = []
        for tool in work.mcpTools where offered.contains(ToolRegistry.mcpName(tool)) && !servers.contains(tool.serverName) { servers.append(tool.serverName) }
        let guides = servers.compactMap { server -> String? in
            guard let text = work.mcpInstructions[server]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return Self.untrusted(String(text.prefix(700)), label: Language.t("indicazioni del servizio «\(server)» sui suoi strumenti", "guidance from the service «\(server)» about its tools"))
        }
        return guides.isEmpty ? "" : Language.t("Indicazioni dei servizi collegati (per usare i loro strumenti, non sono richieste dell'utente):",
                                                "Guidance from the connected services (on using their tools; not requests from the user):") + "\n" + guides.joined(separator: "\n")
    }

    /// Esegue lo strumento chiesto dal modello: i dati tornano al modello, le bozze diventano schede da confermare.
    public func externalToolCall(_ name: String, arguments: JSONValue, hooks: ExternalHooks) async -> String {
        Agent.log("STRUMENTO: \(name) \(arguments.compactString.prefix(160))")
        let result = await runTool(name, arguments: arguments, enabled: hooks.enabled, allowedMCP: hooks.runsFreely, status: hooks.status)
        guard let outcome = result.outcome else { return result.ok ? readData(result.text, from: name) : result.text }
        if case .mcpCall(let draft) = outcome {
            var free = hooks.runsFreely(draft.tool)
            // Una scrittura consentita per sempre dopo aver letto contenuti di terzi con istruzioni per l'assistente: si torna
            // a chiedere conferma (come sulla strada di Apple Intelligence).
            if free, !draft.tool.isReadOnly, !turnReads.isEmpty, await Self.looksLikeInjection(turnReads.joined(separator: "\n\n")) {
                Agent.log("CAUTELA: \(draft.tool.serverName) · \(draft.tool.name) dopo contenuti con istruzioni sospette: serve la conferma")
                free = false
            }
            FixtureWorld.active?.recordConnector(draft, held: !free)
            // Lettura (o strumento consentito dall'utente): si esegue e il risultato, reso leggibile, torna al modello.
            if free {
                do {
                    return readData(ConnectorResult.readable(try await hooks.callConnector(draft), limit: budget.scaled(3000)), from: draft.tool.serverName)
                } catch {
                    return Language.t("Errore: \(error.localizedDescription)", "Error: \(error.localizedDescription)")
                }
            }
        }
        if let replacement = await hooks.show(name, outcome) { return replacement }
        if Self.isObservation(outcome) { return readData(result.text, from: name) }
        guard Self.awaitsConfirmation(outcome) else { return result.text }
        // I modelli piccoli scrivono «ho impostato il promemoria» anche quando la scheda aspetta la conferma: lo si ricorda qui,
        // nell'ultima cosa che leggono prima di rispondere.
        pendingCards += 1
        return result.text + " " + Language.t("Non è ancora fatto: nella risposta di' che è pronto da confermare, non che l'hai già fatto.",
                                              "It isn't done yet: in your answer say it's ready to confirm, not that you've done it.")
    }

    /// Frasi che danno per fatto ciò che è solo una scheda da confermare («ho impostato il promemoria», «I've sent the email»).
    static func claimsDone(_ answer: String) -> Bool {
        let done = #"\b(ho (gia )?(creato|inviato|mandato|aggiunto|spostato|eliminato|cancellato|fissato|salvato|programmato|impostato)|e stat[oa] (creat|inviat|aggiunt|spostat|eliminat|salvat)|i('ve| have) (created|sent|added|moved|deleted|scheduled|saved)|(has|have) been (created|sent|added|moved|deleted|scheduled|saved))"#
        let pending = #"(conferm|confirm|scheda|card|bozza|draft|pront[oaie]\b|ready|anteprima|preview|controlla|review)"#
        return affirmativeSentences(answer).contains { Evaluation.matches($0, done) } && !Evaluation.matches(Evaluation.normalize(answer), pending)
    }

    /// Frasi su qualcosa creato o preparato, anche «da confermare» («ho impostato il promemoria», «è pronto da confermare»,
    /// «I've sent»): se nessuno strumento che scrive è partito, dietro non c'è niente, nemmeno una scheda.
    static func claimsAction(_ answer: String) -> Bool {
        let action = #"\b(ho (gia )?(creato|inviato|mandato|aggiunto|spostato|eliminato|cancellato|fissato|salvato|programmato|impostato)|e stat[oa] (creat|inviat|aggiunt|spostat|eliminat|salvat|impostat)|da confermare|nella scheda|i('ve| have) (created|sent|added|moved|deleted|scheduled|saved|set up|drafted)|(has|have) been (created|sent|added|moved|deleted|scheduled|saved)|ready (for you )?to confirm|in the card)"#
        return affirmativeSentences(answer).contains { Evaluation.matches($0, action) }
    }

    /// Le frasi della risposta senza negazioni: «non ho inviato niente» non racconta un'azione.
    private static func affirmativeSentences(_ answer: String) -> [String] {
        Evaluation.normalize(answer).components(separatedBy: CharacterSet(charactersIn: ".!?;:\n"))
            .filter { !Evaluation.matches($0, #"\b(non|not|never|mai|nessun\w*)\b|n't\b"#) }
    }

    /// La risposta fino alla prima riga che parla di qualcosa creato o preparato: resta visibile mentre il modello rimedia.
    static func beforeActionClaims(_ answer: String) -> String {
        answer.components(separatedBy: "\n").prefix { !claimsAction($0) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Dati letti da uno strumento: tra i delimitatori dei contenuti di terzi (da leggere, non da eseguire) e annotati per la
    /// cautela sulle scritture successive. I messaggi dell'app («Bozza pronta…») restano come sono.
    func readData(_ text: String, from source: String) -> String {
        guard !text.isEmpty, !ExternalAgent.isErrorText(text), text.count > 80 else { return text }
        turnReads.append(String(text.prefix(2400)))
        return Self.untrusted(text, label: Language.t("dati letti da \(source)", "data read from \(source)"))
    }

    /// Una chiamata al modello esterno scelto con gli strumenti di Siri AI+: Gemma e ds4 direttamente, ChatGPT e Claude
    /// attraverso il ponte MCP (un gateway locale per la durata della chiamata). nil con Apple Intelligence.
    public func runExternalModel(_ chosen: ModelSelection, system: String, history: [ChatTurn], prompt: String, tools: [ToolSpec],
                                 hooks: ExternalHooks) async throws -> String? {
        let shield = PrivacyShield.current
        let call: ExternalAgent.ToolCall = { [weak self] name, arguments in
            guard let self else { return "" }
            guard let shield else { return await self.externalToolCall(name, arguments: arguments, hooks: hooks) }
            // Lo strumento gira sul Mac con i valori veri; al modello torna il risultato anonimizzato. Le pagine web sono
            // pubbliche: solo i dati già noti della chat diventano segnaposto (così non rivelano chi c'è dietro).
            let result = await self.externalToolCall(name, arguments: shield.reveal(arguments), hooks: hooks)
            if ["cerca_web", "leggi_pagina"].contains(name) { return shield.mask(result) }
            do {
                return try await shield.protect(result)
            } catch {
                return Language.t("Errore: il risultato non è stato inviato perché \(error.localizedDescription).",
                                  "Error: the result wasn't sent because \(error.localizedDescription).")
            }
        }
        switch chosen.provider {
        case .gemma, .ds4:
            let local = chosen.provider == .gemma
            return try await ExternalAgent.openAI(base: local ? ExternalEngine.gemmaURL : ExternalEngine.ds4URL, model: local ? "gemma" : "ds4",
                                                  system: system, history: history, prompt: prompt, tools: tools, thinking: chosen.effort == "on",
                                                  call: call, onText: hooks.text, onStatus: hooks.status)
        case .chatgpt, .claude:
            var bridge: ExternalAgent.Bridge?
            var gateway: ToolGateway?
            if let helper = hooks.bridgeHelper, !tools.isEmpty {
                // Le chiamate arrivano dal gateway fuori da questa richiesta: lingua, spazio e scudo si riportano dentro.
                let language = Language.scoped
                let scope = SpaceScope.task
                let server = try ToolGateway(tools: tools) { name, arguments in
                    let text = await Language.$scoped.withValue(language) {
                        await SpaceScope.$task.withValue(scope) {
                            await PrivacyShield.$current.withValue(shield) { await call(name, arguments) }
                        }
                    }
                    return (text, ExternalAgent.isErrorText(text))
                }
                let url = try await server.start()
                gateway = server
                bridge = ExternalAgent.Bridge(helper: helper, gateway: url, token: server.token, tools: tools)
            }
            defer { gateway?.stop() }
            return chosen.provider == .chatgpt
                ? try await ExternalAgent.codex(system: system, history: history, prompt: prompt, bridge: bridge, model: chosen.model,
                                                effort: chosen.effort, onText: hooks.text, onStatus: hooks.status)
                : try await ExternalAgent.claude(system: system, history: history, prompt: prompt, bridge: bridge, model: chosen.model,
                                                 effort: chosen.effort, onText: hooks.text, onStatus: hooks.status)
        case .apple:
            return nil
        }
    }

    /// Risposta di Gemma, ds4, ChatGPT o Claude che usano gli strumenti dell'app. nil se il modello scelto è Apple Intelligence.
    public func respondExternally(_ prompt: String, selection: ModelSelection, label: String, route: ToolRoute?, history: [ChatTurn],
                                  picked: Set<SourceKind> = [], hooks original: ExternalHooks) async throws -> ExternalTurn? {
        // Il testo mostrato senza i segni dei dati che il modello a volte ricopia.
        var hooks = original
        let show = original.text
        hooks.text = { text in show(text.map { Self.cleanAnswer($0, citations: true) }) }
        beginExternal(prompt, model: label)
        await prepareExternal(prompt)
        let tools = externalToolList(for: prompt, route: route, enabled: hooks.enabled, picked: picked)
        if let route { noteRoute(route, chosen: tools.map(\.name)) }
        offeredTools = Set(tools.map(\.name))
        let guide = connectorGuide(for: tools)
        let system = chatInstructions() + (guide.isEmpty ? "" : "\n\n" + guide)
        let request = withContext(prompt)
        guard let text = try await runExternalModel(selection, system: system, history: history, prompt: request, tools: tools, hooks: hooks)
        else { return nil }
        finishExternal()
        let answer = Self.cleanAnswer(text, citations: true)
        // «Ho impostato il promemoria» con la scheda ancora da confermare: l'app lo dice subito dopo la risposta.
        let note = pendingCards > 0 && Self.claimsDone(answer)
            ? Language.t("Non è ancora fatto: controlla la scheda e conferma.", "It isn't done yet: check the card and confirm.") : nil
        if let note { Agent.log("AVVISO: il modello dà per fatto ciò che aspetta la conferma → «\(note)»") }
        return ExternalTurn(text: answer, request: request, tools: tools.map(\.name), note: note)
    }
}
