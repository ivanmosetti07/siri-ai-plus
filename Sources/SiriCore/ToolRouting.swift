import Foundation
import FoundationModels

// MARK: - Il sub-agent smistatore: quali strumenti servono e se il lavoro va a passi
//
// A ogni richiesta, prima del modello che risponde, un sub-agent (Apple Intelligence sul Mac: gratis, privato, circa un
// secondo) legge la richiesta e un catalogo breve (nome e una riga per strumento) e sceglie solo gli strumenti che servono.
// Al modello che risponde arrivano quelli: con Apple Intelligence il pianificatore sceglie fra poche azioni, con Gemma,
// ChatGPT e Claude le descrizioni degli strumenti non riempiono la finestra di contesto. Lo smistatore dice anche se il
// compito merita un piano a passi con i sub-agent. Le parole chiave restano la rete di sicurezza: se il sub-agent non
// risponde, o dimentica uno strumento che la richiesta nomina, ci sono loro.

/// Cosa ha deciso lo smistatore per una richiesta.
public struct ToolRoute: Sendable, Codable, Equatable {
    /// Strumenti scelti (nomi del catalogo, o degli strumenti del modello esterno), nell'ordine in cui li ha scelti.
    public var tools: [String]
    /// Le aree scelte dallo smistatore (calendario, email, web…), per la traccia.
    public var areas: [String]?
    /// Il lavoro va diviso in passi (più fonti, confronti, ricerche, analisi, più azioni).
    public var multiStep: Bool
    /// In una frase: cosa serve per rispondere (la sua catena di pensieri).
    public var note: String
    /// Il sub-agent ha risposto; false = strumenti dalle sole parole chiave.
    public var decided: Bool
    public var milliseconds: Int

    public init(tools: [String] = [], multiStep: Bool = false, note: String = "", decided: Bool = false, milliseconds: Int = 0) {
        self.tools = tools; self.multiStep = multiStep; self.note = note; self.decided = decided; self.milliseconds = milliseconds
    }
}

/// Una voce del catalogo che legge lo smistatore: il nome e cosa fa, in una riga.
public struct ToolCatalogEntry: Sendable, Equatable {
    public let name: String
    public let summary: String

    public init(name: String, summary: String) { self.name = name; self.summary = summary }
}

extension Assistant {
    /// Saluti, ringraziamenti, conferme: niente strumenti né piani, si risponde e basta.
    nonisolated public static func isSmallTalk(_ prompt: String) -> Bool {
        let text = prompt.lowercased().replacingOccurrences(of: #"[,.!?;:…]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        guard text.split(separator: " ").count <= 5 else { return false }
        let phrases = ["ciao", "salve", "buongiorno", "buonasera", "buonanotte", "grazie", "grazie mille", "ok", "okay", "va bene", "perfetto",
                       "ottimo", "benissimo", "bene", "come stai", "come va", "chi sei", "cosa sai fare", "sì", "si", "no", "d'accordo", "a dopo",
                       "ci sentiamo", "alla prossima", "bravo", "brava", "fantastico", "capito", "tutto chiaro"]
        return phrases.contains { text == $0 || text.hasPrefix($0 + " ") && text.count <= $0.count + 12 }
    }

    /// Serve lo smistatore? No per i saluti, i testi da elaborare e i comandi che l'app decide da sola (sull'elemento sullo
    /// schermo o su ciò che esiste già: «sposta la riunione alle 16», «rispondi che va bene»).
    func shouldRoute(_ prompt: String, editingOpen: Bool) -> Bool {
        guard routesTools, !editingOpen, !Self.isTextTask(prompt), !Self.isSmallTalk(prompt) else { return false }
        if screenAction(prompt) != nil || Self.changeAction(prompt) != nil { return false }
        // Il passo di un piano ha un'istruzione esplicita («Cerca sul web…», «Leggi il file…»): lo smistatore serve solo se
        // le parole chiave non trovano niente (il piano resta veloce).
        if isSubAgent, !candidateActions(for: Self.withoutQuotes(prompt)).isEmpty { return false }
        return !(screenPointed && ScreenItem.isQuestion(prompt))
    }

    /// Gli strumenti dei modelli esterni suggeriti dalle parole della richiesta: la rete di sicurezza dello smistatore.
    public func toolHints(for prompt: String) -> Set<String> {
        Set(candidateActions(for: Self.withoutQuotes(prompt)).flatMap { ToolRegistry.hintsForAction[$0.rawValue] ?? [] })
    }

    /// Le famiglie di strumenti tra cui sceglie lo smistatore. Scegliere una famiglia è facile anche per il modello piccolo
    /// (provato: fra 40 strumenti uno per uno sbagliava, 5 richieste parafrasate su 12 come senza di lui); lo strumento
    /// preciso lo sceglie poi il pianificatore, o il modello esterno fra quelli della famiglia.
    struct ToolFamily: Sendable {
        let name: String
        let summary: String
        let actions: [Action]
        let tools: [String]
    }

    nonisolated static let families: [ToolFamily] = [
        ToolFamily(name: "calendario", summary: "eventi, riunioni, appuntamenti, impegni, disponibilità, spostare o creare un evento",
                   actions: [.agenda, .eventi, .crea_evento, .modifica_evento, .elimina_evento, .calendari],
                   tools: ["agenda", "calendari", "crea_evento", "modifica_evento", "elimina_evento"]),
        ToolFamily(name: "promemoria", summary: "cose da fare, scadenze, pagamenti o impegni da non dimenticare, liste di attività",
                   actions: [.promemoria, .agenda, .crea_promemoria, .crea_lista_promemoria, .completa_promemoria, .modifica_promemoria, .elimina_promemoria],
                   tools: ["agenda", "crea_promemoria", "modifica_promemoria", "elimina_promemoria"]),
        ToolFamily(name: "email", summary: "posta ricevuta (ordini, pacchi, fatture, newsletter, mittenti), scrivere, rispondere o inoltrare un'email",
                   actions: [.mail_leggi, .scrivi_email, .rispondi_email, .inoltra_email],
                   tools: ["leggi_email", "scrivi_email", "rispondi_email", "inoltra_email"]),
        ToolFamily(name: "messaggi", summary: "messaggi e chat con le persone (iMessage, SMS): leggerli o mandarne uno",
                   actions: [.messaggi, .invia_messaggio], tools: ["leggi_messaggi", "invia_messaggio"]),
        ToolFamily(name: "note", summary: "l'app Note: leggere, cercare, creare una nota o aggiungerci qualcosa",
                   actions: [.note, .crea_nota, .modifica_nota], tools: ["leggi_note", "crea_nota", "aggiungi_a_nota"]),
        ToolFamily(name: "file", summary: "file e documenti salvati (sul Mac o nel progetto): trovarli, leggerli, crearli, spostarli, rinominarli",
                   actions: [.file, .file_elenca, .file_leggi, .file_cerca, .file_scrivi, .file_sposta, .file_cartella, .file_elimina],
                   tools: ["cerca_file_mac", "elenca_file", "leggi_file", "cerca_nei_file", "scrivi_file", "modifica_file", "sposta_file", "crea_cartella"]),
        ToolFamily(name: "web", summary: "notizie, prezzi, meteo, orari, risultati, fatti recenti o che cambiano, siti e pagine web",
                   actions: [.cerca_web, .leggi_pagina, .naviga, .segui_link], tools: ["cerca_web", "leggi_pagina"]),
        ToolFamily(name: "documenti", summary: "creare un documento, un foglio di calcolo, una presentazione o una pagina web; cambiare quello aperto",
                   actions: [.crea_documento, .crea_foglio, .crea_presentazione, .crea_sito, .modifica_artefatto],
                   tools: ["crea_documento", "modifica_aperto"]),
        ToolFamily(name: "immagini", summary: "disegnare o generare un'immagine", actions: [.genera_immagine], tools: []),
        ToolFamily(name: "memoria", summary: "ricordare un fatto o una preferenza di Ivan, ritrovare cosa si era detto o deciso in passato",
                   actions: [.ricorda, .cerca_conversazioni], tools: ["ricorda", "cerca_conversazioni"]),
        ToolFamily(name: "agenti", summary: "creare un agente che lavora da solo (anche a orari fissi) o aprire una nuova chat",
                   actions: [.crea_agente, .nuova_chat], tools: []),
    ]

    /// L'azione ovvia di un'area trovata dallo smistatore: leggere se si chiede, preparare se si chiede di fare.
    /// Niente per consigli, spiegazioni e testi creativi, né con un documento o un elemento aperto (la domanda è su quello),
    /// né per il calendario da creare (servono date). `withCalculations`: la richiesta ha date o conti fatti dall'app,
    /// allora si prepara (un promemoria «fra tre giorni») ma non si legge.
    func rescueAction(areas: [String], prompt: String, withCalculations: Bool = false) -> Action? {
        let lower = Self.withoutQuotes(prompt).lowercased()
        // Nemmeno per i problemi di logica e le scelte con i dati nella domanda («quale giorno mi conviene?»): si ragiona, non si legge.
        guard !areas.isEmpty, work.artifactKind == nil, screenFocus == nil, ResponseStyle.detect(prompt) != .creative, !conversationCovers(prompt),
              !Self.needsReasoning(prompt),
              lower.range(of: #"^(?:come (?:posso|potrei|faccio|si |mai)|cosa mi consigli|mi consigli|consigli|perch[eé] |spiegami|che cos)"#,
                          options: .regularExpression) == nil else { return nil }
        // Chiedere di mandare, non raccontare cosa è arrivato («chi mi ha mandato il preventivo?» si legge).
        let received = lower.range(of: #"\b(?:mi|ci|ti) (?:ha|hanno|aveva|avevano) (?:mandat|scritt|inviat|rispost)\w*"#, options: .regularExpression) != nil
        let writes = !received && lower.range(of: #"\b(?:scrivi|scrivere|scrivigli|scrivile|scrivimi|prepara|preparami|bozza|manda|mandagli|mandale|mandare|mandagliel\w*|invia|inviagli|inviale|inviare|butta gi[uù]|dillo|digli|dille|avvisa\w*|comunica\w*|rispondi|rispondigli|rispondile|risposta)\b"#,
                                                     options: .regularExpression) != nil
        let remind = lower.range(of: #"non (?:farmi|fammi|lasciarmi|farmelo|farmela) (?:scordare|dimenticare)|non devo (?:scordar|dimenticar)|ricordamelo|segnamelo|segnatelo|tienimelo presente|tienilo presente|non scordarmelo"#,
                                 options: .regularExpression) != nil
        let available = Set(availableActions)
        for area in areas {
            let action: Action? = switch area {
            case "email": writes ? .scrivi_email : .mail_leggi
            case "messaggi": writes ? .invia_messaggio : .messaggi
            case "note": writes || lower.contains("prendi nota") || lower.contains("annota") ? .crea_nota : .note
            case "file": work.files != nil ? .file_cerca : .file
            // Un promemoria si crea solo se lo chiede («non farmelo scordare»): «sto organizzando una cena sabato» è un racconto.
            case "promemoria": remind ? .crea_promemoria : Self.isQuestion(prompt) ? .promemoria : nil
            case "calendario": Self.isQuestion(prompt) ? .agenda : nil
            default: nil
            }
            guard let action, available.contains(action) else { continue }
            let prepares: Set<Action> = [.scrivi_email, .invia_messaggio, .crea_nota, .crea_promemoria]
            if withCalculations, !prepares.contains(action) { continue }
            return action
        }
        return nil
    }

    /// Ivan ne ha già parlato nella conversazione («il mio medico riceve il martedì» → «che giorno riceve il mio medico?»):
    /// la risposta è lì, non nelle app.
    func conversationCovers(_ prompt: String) -> Bool {
        let asked = Self.significant(MemoryStore.keywords(prompt))
        guard !asked.isEmpty else { return false }
        return ConversationMemory.exchanges(turns).suffix(8).contains { exchange in
            !exchange.user.contains("?") && !asked.isDisjoint(with: Self.significant(MemoryStore.keywords(exchange.user)))
        }
    }

    /// Il catalogo dello smistatore: le famiglie che hanno qualcosa di disponibile adesso, più i connettori.
    public func familyCatalog(tools: [ToolSpec]? = nil) -> [ToolCatalogEntry] {
        let available = Set(availableActions)
        let names = tools.map { Set($0.map(\.name)) }
        var entries = Self.families.filter { family in
            if let names { return family.tools.contains(where: names.contains) }
            return family.actions.contains(where: available.contains)
        }.map { ToolCatalogEntry(name: $0.name, summary: $0.summary) }
        if let tools {
            entries += ToolRegistry.catalog(tools).filter { $0.name.hasPrefix("connettore_") }
        } else if available.contains(.strumento_esterno) {
            entries.append(ToolCatalogEntry(name: "connettori", summary: "servizi collegati: \(Set(work.mcpTools.map(\.serverName)).sorted().joined(separator: ", "))"))
        }
        return entries
    }

    /// Le azioni di Apple Intelligence delle famiglie scelte.
    func actions(inFamilies names: [String]) -> Set<Action> {
        var actions = Set(Self.families.filter { names.contains($0.name) }.flatMap(\.actions))
        if names.contains("connettori") { actions.insert(.strumento_esterno) }
        return actions.intersection(availableActions)
    }

    /// Gli strumenti dei modelli esterni delle famiglie (e dei connettori) scelte.
    nonisolated public static func tools(inFamilies names: [String]) -> [String] {
        families.filter { names.contains($0.name) }.flatMap(\.tools) + names.filter { $0.hasPrefix("connettore_") }
    }

    /// Lo smistatore per un modello esterno: famiglie dal catalogo dei suoi strumenti, poi i nomi degli strumenti.
    public func routeExternalTools(for prompt: String, tools: [ToolSpec]) async -> ToolRoute {
        var route = await routeTools(for: prompt, catalog: familyCatalog(tools: tools), hints: familyHints(for: prompt))
        route.tools = Self.tools(inFamilies: route.tools)
        return route
    }

    /// Le famiglie delle azioni trovate con le parole chiave (indizi per lo smistatore).
    public func familyHints(for prompt: String) -> [String] {
        let found = candidateActions(for: Self.withoutQuotes(prompt))
        var names = Self.families.filter { family in family.actions.contains(where: found.contains) }.map(\.name)
        if found.contains(.strumento_esterno) { names.append("connettori") }
        return names
    }

    /// Ciò che lo smistatore deve sapere oltre alla richiesta: l'ultimo scambio, il progetto, l'app o il documento aperti.
    func routingContext() -> String {
        var lines: [String] = []
        if let recent = recentConversation(exchanges: 1, user: 220, reply: 280) { lines.append("Conversazione recente:\n\(recent)") }
        if let project = work.projectName { lines.append("Chat del progetto «\(project)» (i file sono nella sua cartella).") }
        if let screen = work.screen { lines.append("Aperto nelle app: \(screen.app) · \(screen.title).") }
        if let kind = work.artifactKind { lines.append("Aperto al centro: \(kind) «\(work.artifactTitle ?? "")».") }
        if work.browserURL != nil { lines.append("Aperta in Safari: una pagina web.") }
        return lines.joined(separator: "\n")
    }

    /// Il sub-agent smistatore. `catalog`: gli strumenti tra cui scegliere (le azioni di Apple Intelligence o gli strumenti dei
    /// modelli esterni). Una sessione nuova per ogni richiesta: niente cronologia, niente altro nella sua finestra.
    public func routeTools(for prompt: String, catalog: [ToolCatalogEntry], hints: [String] = []) async -> ToolRoute {
        let started = Date.now
        guard !catalog.isEmpty, Agent.availabilityProblem == nil else { return ToolRoute() }
        let names = catalog.map(\.name)
        // Righe corte: la finestra dello smistatore è quella piccola di Apple Intelligence, e meno testo da leggere è più veloce.
        let width = catalog.count > 40 ? 60 : 90
        let list = catalog.map { "- \($0.name): \(Self.shortened($0.summary, to: width))" }.joined(separator: "\n")
        let instructions = """
        Sei lo smistatore di Siri AI+. Non rispondi alla richiesta: capisci cosa chiede e scegli dove l'assistente deve guardare o cosa deve usare.
        Aree:
        \(list)
        Come scegliere:
        - Nessuna area per saluti, conversazione, spiegazioni, consigli, idee, testi da scrivere in chat, conti con i dati già nella richiesta e domande di cultura generale.
        - Le cose di Ivan (appuntamenti, cose da fare, posta, messaggi, note, file) si guardano nell'area giusta anche se la richiesta non la nomina: «mi è arrivato il pacco?» è email; «cosa mi ha scritto Giulia?» è messaggi ed email; «dove ho messo il contratto?» è file; «non farmi scordare di…» è promemoria.
        - Nel dubbio fra due aree scegli entrambe. Al massimo 3.
        """
        var context = routingContext()
        // Le parole della richiesta che rimandano a uno strumento: un indizio, non un obbligo.
        let clues = hints.filter(names.contains)
        if !clues.isEmpty { context += (context.isEmpty ? "" : "\n") + "Indizi dalle parole della richiesta (non obbligatori): \(clues.joined(separator: ", "))." }
        let request = (context.isEmpty ? "" : context + "\n\n") + "Richiesta: \(prompt.prefix(1500))"
        let schema = makeSchema("Smistamento", [
            .required("intento", .string, "Cosa chiede Ivan, in poche parole"),
            .required("aree", .array(.choice(names), max: 3), "Le aree da usare (anche nessuna)"),
        ])
        let session = routerSession(instructions)
        do {
            let content = try await session.respond(to: request, schema: schema,
                                                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120)).content
            // La prossima richiesta trova lo smistatore con il catalogo già letto.
            prepareRouter(instructions)
            var tools: [String] = []
            for name in content.strings("aree") where names.contains(name) && !tools.contains(name) { tools.append(name) }
            var route = ToolRoute(tools: tools, multiStep: Self.gathersFromRoutedSources(prompt, areas: tools), note: content.string("intento") ?? "",
                                  decided: true, milliseconds: Int(Date.now.timeIntervalSince(started) * 1000))
            route.areas = tools
            Agent.log("SMISTATORE: \(route.tools.joined(separator: ", ").isEmpty ? "nessuna area" : route.tools.joined(separator: ", "))"
                      + " · \(route.multiStep ? "piano" : "risposta") · \(route.milliseconds) ms · «\(route.note.prefix(80))»"
                      + (clues.isEmpty ? "" : " · indizi \(clues.joined(separator: ","))"))
            return route
        } catch {
            Agent.log("SMISTATORE NON RIUSCITO (\(error.localizedDescription)): uso le parole chiave")
            return ToolRoute(milliseconds: Int(Date.now.timeIntervalSince(started) * 1000))
        }
    }

    /// Una sessione nuova dello smistatore, o quella preparata dopo la richiesta precedente con le stesse istruzioni.
    private func routerSession(_ instructions: String) -> LanguageModelSession {
        if let prepared = preparedRouter, prepared.instructions == instructions {
            preparedRouter = nil
            return prepared.session
        }
        return LanguageModelSession(model: Agent.model, instructions: instructions)
    }

    /// Prepara in anticipo la sessione della prossima richiesta: il catalogo si legge adesso, mentre l'utente legge la risposta.
    private func prepareRouter(_ instructions: String) {
        let session = LanguageModelSession(model: Agent.model, instructions: instructions)
        session.prewarm()
        preparedRouter = (instructions, session)
    }

    /// Una riga del catalogo, tagliata a una parola intera.
    nonisolated static func shortened(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        let cut = text.prefix(width)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    /// Lo smistatore nella traccia: il primo passaggio di «Come ho lavorato».
    func traceRoute(_ route: ToolRoute, chosen: [String]) {
        guard route.decided else { return }
        trace?.route = route
        let names = chosen.map(Self.toolLabel)
        trace?.steps.insert(TraceStep(action: "smistatore",
                                      detail: (route.note.isEmpty ? "" : "«\(route.note)» · ") + "aree: " + ((route.areas ?? route.tools).isEmpty ? "nessuna" : (route.areas ?? route.tools).joined(separator: ", ")),
                                      result: (names.isEmpty ? "nessuno strumento: basta rispondere" : "strumenti: " + names.joined(separator: ", "))
                                          + (route.multiStep ? " · piano a passi con i sub-agent" : " · piano di un passo"),
                                      milliseconds: route.milliseconds, ok: true), at: 0)
    }

    /// Lo smistatore di un modello esterno nella traccia della richiesta in corso.
    public func noteRoute(_ route: ToolRoute, chosen: [String]) { traceRoute(route, chosen: chosen) }

    /// Nome leggibile di un'azione o di uno strumento (per la traccia).
    nonisolated static func toolLabel(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            return parts.joined(separator: " · ").replacingOccurrences(of: "_", with: " ")
        }
        return name.replacingOccurrences(of: "_", with: " ")
    }
}

extension ToolRegistry {
    /// Le voci del catalogo per lo smistatore: gli strumenti dell'app uno per uno, i connettori uno per servizio
    /// (con i nomi dei loro strumenti), così il catalogo resta corto anche con molti connettori.
    public static func catalog(_ tools: [ToolSpec]) -> [ToolCatalogEntry] {
        var entries: [ToolCatalogEntry] = []
        var servers: [(name: String, tools: [String])] = []
        for tool in tools {
            if tool.name.hasPrefix("mcp__") {
                let parts = tool.name.dropFirst(5).components(separatedBy: "__")
                let server = parts.first ?? "connettore"
                let short = parts.dropFirst().joined(separator: "_")
                if let index = servers.firstIndex(where: { $0.name == server }) { servers[index].tools.append(short) } else { servers.append((server, [short])) }
            } else {
                entries.append(ToolCatalogEntry(name: tool.name, summary: tool.description))
            }
        }
        for server in servers {
            let names = server.tools.prefix(10).joined(separator: ", ")
            entries.append(ToolCatalogEntry(name: "connettore_\(server.name)",
                                            summary: "servizio collegato \(server.name.replacingOccurrences(of: "_", with: " ")) (\(names)\(server.tools.count > 10 ? "…" : ""))"))
        }
        return entries
    }

    /// Solo gli strumenti scelti: quelli nominati dallo smistatore o suggeriti dalle parole chiave (`hints`), i connettori
    /// scelti con tutti i loro strumenti. Se lo smistatore non ha risposto restano tutti.
    public static func selecting(_ tools: [ToolSpec], route: ToolRoute, hints: Set<String> = []) -> [ToolSpec] {
        guard route.decided else { return tools }
        let wanted = Set(route.tools).union(hints)
        return tools.filter { tool in
            if tool.name.hasPrefix("mcp__") {
                let server = tool.name.dropFirst(5).components(separatedBy: "__").first ?? ""
                return wanted.contains("connettore_\(server)")
            }
            return wanted.contains(tool.name)
        }
    }

    /// Le azioni di Apple Intelligence trovate con le parole chiave, come nomi degli strumenti dei modelli esterni.
    public static let hintsForAction: [String: [String]] = [
        "agenda": ["agenda"], "eventi": ["agenda"], "promemoria": ["agenda"], "calendari": ["calendari"],
        "crea_evento": ["crea_evento"], "crea_promemoria": ["crea_promemoria"], "crea_lista_promemoria": ["crea_promemoria"],
        "modifica_evento": ["modifica_evento"], "elimina_evento": ["elimina_evento"], "modifica_promemoria": ["modifica_promemoria"],
        "elimina_promemoria": ["elimina_promemoria"], "completa_promemoria": ["modifica_promemoria"],
        "scrivi_email": ["scrivi_email"], "rispondi_email": ["rispondi_email"], "inoltra_email": ["inoltra_email"], "mail_leggi": ["leggi_email"],
        "note": ["leggi_note"], "crea_nota": ["crea_nota"], "modifica_nota": ["aggiungi_a_nota"],
        "messaggi": ["leggi_messaggi"], "invia_messaggio": ["invia_messaggio"], "file": ["cerca_file_mac"],
        "file_elenca": ["elenca_file"], "file_leggi": ["leggi_file"], "file_cerca": ["cerca_nei_file"], "file_scrivi": ["scrivi_file", "modifica_file"],
        "file_sposta": ["sposta_file"], "file_cartella": ["crea_cartella"], "cerca_web": ["cerca_web"], "leggi_pagina": ["leggi_pagina"],
        "crea_documento": ["crea_documento"], "ricorda": ["ricorda"], "cerca_conversazioni": ["cerca_conversazioni"],
        "modifica_artefatto": ["modifica_aperto"],
    ]
}
