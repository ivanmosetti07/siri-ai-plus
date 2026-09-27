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
    /// Un'istruzione sul formato della risposta non è un comando per rispondere a una persona o a un'email.
    nonisolated public static func isAnswerOnlyInstruction(_ prompt: String) -> Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.range(of: #"^(?:(?:per favore|puoi)\s+)?(?:rispondi|dimmi)\s+(?:solo|soltanto|semplicemente|brevemente)(?:\s*[:.,]|\s*$|\s+(?:con|in)\b)"#,
                          options: .regularExpression) != nil
            || text.range(of: #"^(?:(?:please|can you)\s+)?(?:answer|reply|respond|tell me)\s+(?:only|just|simply|briefly)(?:\s*[:.,]|\s*$|\s+(?:with|in)\b)"#,
                          options: .regularExpression) != nil
    }

    /// «Rispondi solo: …» chiede una stringa precisa: non serve un modello che possa parafrasarla.
    nonisolated public static func literalAnswer(_ prompt: String) -> String? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\n"),
              let prefix = text.range(of: #"(?i)^(?:rispondi\s+(?:solo|soltanto)|(?:answer|reply)\s+(?:only|just))\s*:\s*"#, options: .regularExpression) else { return nil }
        let answer = text[prefix.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? nil : answer
    }

    /// Saluti, ringraziamenti, conferme: niente strumenti né piani, si risponde e basta.
    nonisolated public static func isSmallTalk(_ prompt: String) -> Bool {
        let text = prompt.lowercased().replacingOccurrences(of: #"[,.!?;:…]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        guard text.split(separator: " ").count <= 5 else { return false }
        let phrases = ["ciao", "salve", "buongiorno", "buonasera", "buonanotte", "grazie", "grazie mille", "ok", "okay", "va bene", "perfetto",
                       "ottimo", "benissimo", "bene", "come stai", "come va", "chi sei", "cosa sai fare", "sì", "si", "no", "d'accordo", "a dopo",
                       "ci sentiamo", "alla prossima", "bravo", "brava", "fantastico", "capito", "tutto chiaro",
                       // In inglese.
                       "hi", "hello", "hey", "good morning", "good evening", "good night", "thanks", "thank you", "thanks a lot",
                       "all right", "alright", "perfect", "great", "fine", "good", "how are you", "how's it going", "who are you",
                       "what can you do", "yes", "sure", "see you", "talk later", "bye", "cool", "awesome", "got it", "understood"]
        return phrases.contains { text == $0 || text.hasPrefix($0 + " ") && text.count <= $0.count + 12 }
    }

    /// Serve lo smistatore? No per i saluti, i testi da elaborare e i comandi che l'app decide da sola (sull'elemento sullo
    /// schermo o su ciò che esiste già: «sposta la riunione alle 16», «rispondi che va bene»).
    func shouldRoute(_ prompt: String, editingOpen: Bool) -> Bool {
        guard routesTools, !editingOpen, !Self.isTextTask(prompt), !Self.isSmallTalk(prompt),
              !Self.isAnswerOnlyInstruction(prompt) else { return false }
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
        ToolFamily(name: "memoria", summary: "ricordare un fatto o una preferenza di \(Assistant.userLabel), ritrovare cosa si era detto o deciso in passato",
                   actions: [.ricorda, .cerca_conversazioni], tools: ["ricorda", "cerca_conversazioni"]),
        ToolFamily(name: "agenti", summary: "creare un Genius che lavora da solo (anche a orari fissi) o aprire una nuova chat",
                   actions: [.crea_agente, .nuova_chat], tools: []),
    ]

    /// Le descrizioni delle famiglie per le richieste in inglese (i nomi restano quelli: li legge il codice).
    nonisolated static let englishFamilySummaries: [String: String] = [
        "calendario": "events, meetings, appointments, plans, availability, moving or creating an event",
        "promemoria": "things to do, deadlines, payments or commitments not to forget, task lists",
        "email": "received mail (orders, parcels, invoices, newsletters, senders), writing, replying to or forwarding an email",
        "messaggi": "messages and chats with people (iMessage, SMS): reading them or sending one",
        "note": "the Notes app: reading, searching, creating a note or adding something to it",
        "file": "saved files and documents (on the Mac or in the project): finding, reading, creating, moving, renaming them",
        "web": "news, prices, weather, schedules, results, recent or changing facts, websites and web pages",
        "documenti": "creating a document, a spreadsheet, a presentation or a web page; changing the open one",
        "immagini": "drawing or generating an image",
        "memoria": "remembering a fact or a preference of the user, finding what was said or decided in the past",
        "agenti": "creating a Genius that works on its own (also at set times) or opening a new chat",
    ]

    /// L'azione ovvia di un'area trovata dallo smistatore: leggere se si chiede, preparare se si chiede di fare.
    /// Niente per consigli, spiegazioni e testi creativi, né con un documento o un elemento aperto (la domanda è su quello),
    /// né per il calendario da creare (servono date). `withCalculations`: la richiesta ha date o conti fatti dall'app,
    /// allora si prepara (un promemoria «fra tre giorni») ma non si legge.
    func rescueAction(areas: [String], prompt: String, withCalculations: Bool = false) -> Action? {
        let lower = Self.withoutQuotes(prompt).lowercased()
        // Nemmeno per i problemi di logica e le scelte con i dati nella domanda («quale giorno mi conviene?»): si ragiona, non si legge.
        let english = Language.isEnglish
        let advice = lower.range(of: #"^(?:come (?:posso|potrei|faccio|si |mai)|cosa mi consigli|mi consigli|consigli|perch[eé] |spiegami|che cos)"#,
                                 options: .regularExpression) != nil
            || (english && lower.range(of: #"^(?:how (?:can|could|do|should|would) (?:i|we)|what do you (?:suggest|recommend)|any (?:advice|tips|ideas)|give me (?:an? |some )?(?:idea|ideas|tips?|advice|suggestions?)|suggest |why |explain|what is a|what's a)"#,
                                       options: .regularExpression) != nil)
        guard !areas.isEmpty, work.artifactKind == nil, screenFocus == nil, ResponseStyle.detect(prompt) != .creative,
              !Self.isAnswerOnlyInstruction(prompt), !conversationCovers(prompt),
              !Self.needsReasoning(prompt), !advice else { return nil }
        // Chiedere di mandare, non raccontare cosa è arrivato («chi mi ha mandato il preventivo?» si legge).
        let received = lower.range(of: #"\b(?:mi|ci|ti) (?:ha|hanno|aveva|avevano) (?:mandat|scritt|inviat|rispost)\w*"#, options: .regularExpression) != nil
            || (english && lower.range(of: #"\b(?:sent|wrote|emailed|texted|replied|written)(?: to)? (?:me|us)\b|\bdid (?:i|we) (?:get|receive)\b|\b(?:got|received) (?:anything|any)\b"#,
                                       options: .regularExpression) != nil)
        let writes = !received && (lower.range(of: #"\b(?:scrivi|scrivere|scrivigli|scrivile|scrivimi|prepara|preparami|bozza|manda|mandagli|mandale|mandare|mandagliel\w*|invia|inviagli|inviale|inviare|butta gi[uù]|dillo|digli|dille|avvisa\w*|comunica\w*)\b"#,
                                                      options: .regularExpression) != nil
            || (english && lower.range(of: #"\b(?:write|draft|prepare|send|jot down|text (?:him|her|them)|tell (?:him|her|them)|let (?:him|her|them) know|notify|inform|email (?:him|her|them))\b"#,
                                       options: .regularExpression) != nil))
        let remind = lower.range(of: #"non (?:farmi|fammi|lasciarmi|farmelo|farmela) (?:scordare|dimenticare)|non devo (?:scordar|dimenticar)|ricordamelo|segnamelo|segnatelo|tienimelo presente|tienilo presente|non scordarmelo"#,
                                 options: .regularExpression) != nil
            || (english && lower.range(of: #"don't let me forget|do not let me forget|make sure i (?:don't|do not) forget|remind me|keep (?:it|this|that) in mind for me|keep in mind for me|i must not forget|don't forget"#,
                                       options: .regularExpression) != nil)
        let noteTaking = lower.contains("prendi nota") || lower.contains("annota")
            || (english && ["make a note", "jot down", "write down", "take note"].contains(where: lower.contains))
        let available = Set(availableActions)
        // Un conto con tutti i dati nella domanda («€89.90 including 22% VAT: how much without VAT?») non si cerca nei file.
        let selfContainedMath = Calculations.looksArithmetic(prompt) && Calculations.numbers(in: prompt).count >= 2
            && !["file", "document", "cartell", "progett", "folder", "project", ".pdf", ".md", ".txt", ".csv"].contains(where: lower.contains)
        for area in areas {
            if area == "file", selfContainedMath { continue }
            let action: Action? = switch area {
            case "email": writes ? .scrivi_email : .mail_leggi
            case "messaggi": writes ? .invia_messaggio : .messaggi
            case "note": writes || noteTaking ? .crea_nota : .note
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
        let english = Language.isEnglish
        var entries = Self.families.filter { family in
            if let names { return family.tools.contains(where: names.contains) }
            return family.actions.contains(where: available.contains)
        }.map { ToolCatalogEntry(name: $0.name, summary: english ? Self.englishFamilySummaries[$0.name] ?? $0.summary : $0.summary) }
        if let tools {
            entries += ToolRegistry.catalog(tools).filter { $0.name.hasPrefix("connettore_") }
        } else if available.contains(.strumento_esterno) {
            let servers = Set(work.mcpTools.map(\.serverName)).sorted().joined(separator: ", ")
            entries.append(ToolCatalogEntry(name: "connettori", summary: Language.t("servizi collegati: ", "connected services: ") + servers))
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
        let t = Language.t
        if let recent = recentConversation(exchanges: 1, user: 220, reply: 280) { lines.append(t("Conversazione recente:", "Recent conversation:") + "\n\(recent)") }
        if let project = work.projectName { lines.append(t("Chat del progetto «\(project)» (i file sono nella sua cartella).", "Chat of the project «\(project)» (the files are in its folder).")) }
        if let screen = work.screen { lines.append(t("Aperto nelle app: ", "Open in the apps: ") + "\(screen.app) · \(screen.title).") }
        if let kind = work.artifactKind { lines.append(t("Aperto al centro: ", "Open in the center: ") + "\(kind) «\(work.artifactTitle ?? "")».") }
        if work.browserURL != nil { lines.append(t("Aperta in Safari: una pagina web.", "Open in Safari: a web page.")) }
        return lines.joined(separator: "\n")
    }

    /// Il sub-agent smistatore. `catalog`: gli strumenti tra cui scegliere (le azioni di Apple Intelligence o gli strumenti dei
    /// modelli esterni). Una sessione nuova per ogni richiesta: niente cronologia, niente altro nella sua finestra.
    public func routeTools(for prompt: String, catalog: [ToolCatalogEntry], hints: [String] = []) async -> ToolRoute {
        let started = Date.now
        guard !catalog.isEmpty, Agent.availabilityProblem == nil else { return ToolRoute() }
        let names = catalog.map(\.name)
        // Domande personali con una sorgente inequivocabile: il modello piccolo può dimenticare la famiglia
        // anche quando gli indizi la indicano. Queste forme si instradano prima di chiamarlo.
        let lower = prompt.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let english = Language.isEnglish
        let appointments = ["impegni", "appuntamenti", "riunioni", "meeting"].contains { lower.contains($0) }
            || (english && ["appointments", "my schedule", "my calendar"].contains { lower.contains($0) })
        let incoming = lower.contains("mi e arrivato") || lower.contains("ho ricevuto") || lower.contains("nella posta")
            || (english && ["did i get", "did i receive", "i received", "in my inbox", "in the mail"].contains { lower.contains($0) })
        let direct: String? = appointments && names.contains("calendario") ? "calendario"
            : incoming && names.contains("email") ? "email" : nil
        if let direct {
            var route = ToolRoute(tools: [direct], note: "Sorgente esplicita nella richiesta", decided: true,
                                  milliseconds: Int(Date.now.timeIntervalSince(started) * 1000))
            route.areas = [direct]
            return route
        }
        // Righe corte: la finestra dello smistatore è quella piccola di Apple Intelligence, e meno testo da leggere è più veloce.
        let width = catalog.count > 40 ? 60 : 90
        let list = catalog.map { "- \($0.name): \(Self.shortened($0.summary, to: width))" }.joined(separator: "\n")
        let user = Self.userFirstName ?? "l'utente"
        let instructions = english ? """
        You are the Siri AI+ router. You don't answer the request: you understand what it asks and choose where the assistant must look or what it must use.
        Areas:
        \(list)
        How to choose:
        - No area for greetings, conversation, explanations, advice, ideas, texts to write in the chat, math with the data already in the request and general knowledge questions.
        - The user's own things (appointments, to-dos, mail, messages, notes, files) are looked up in the right area even if the request doesn't name it: «did my parcel arrive?» is email; «what did Julia write to me?» is messages and email; «where did I put the contract?» is file; «don't let me forget to…» is promemoria.
        - If in doubt between two areas choose both. At most 3.
        """ : """
        Sei lo smistatore di Siri AI+. Non rispondi alla richiesta: capisci cosa chiede e scegli dove l'assistente deve guardare o cosa deve usare.
        Aree:
        \(list)
        Come scegliere:
        - Nessuna area per saluti, conversazione, spiegazioni, consigli, idee, testi da scrivere in chat, conti con i dati già nella richiesta e domande di cultura generale.
        - Le cose di \(user) (appuntamenti, cose da fare, posta, messaggi, note, file) si guardano nell'area giusta anche se la richiesta non la nomina: «mi è arrivato il pacco?» è email; «cosa mi ha scritto Giulia?» è messaggi ed email; «dove ho messo il contratto?» è file; «non farmi scordare di…» è promemoria.
        - Nel dubbio fra due aree scegli entrambe. Al massimo 3.
        """
        var context = routingContext()
        // Le parole della richiesta che rimandano a uno strumento: un indizio, non un obbligo.
        let clues = hints.filter(names.contains)
        if !clues.isEmpty {
            context += (context.isEmpty ? "" : "\n") + Language.t("Indizi dalle parole della richiesta (non obbligatori): ", "Clues from the words of the request (not binding): ")
                + clues.joined(separator: ", ") + "."
        }
        let request = (context.isEmpty ? "" : context + "\n\n") + Language.t("Richiesta: ", "Request: ") + prompt.prefix(1500)
        let schema = makeSchema("Smistamento", [
            .required("intento", .string, english ? "What the user is asking, in a few words" : "Cosa chiede \(user), in poche parole"),
            .required("aree", .array(.choice(names), max: 3), english ? "The areas to use (possibly none)" : "Le aree da usare (anche nessuna)"),
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
        let t = Language.t
        let areas = route.areas ?? route.tools
        trace?.steps.insert(TraceStep(action: "smistatore",
                                      detail: (route.note.isEmpty ? "" : "«\(route.note)» · ") + t("aree: ", "areas: ") + (areas.isEmpty ? t("nessuna", "none") : areas.map(Self.toolLabel).joined(separator: ", ")),
                                      result: (names.isEmpty ? t("nessuno strumento: basta rispondere", "no tools: a reply is enough") : t("strumenti: ", "tools: ") + names.joined(separator: ", "))
                                          + (route.multiStep ? t(" · piano a passi con i sub-agent", " · step-by-step plan with sub-agents") : t(" · piano di un passo", " · one-step plan")),
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
        if Language.isEnglish, let english = englishToolNames[name] { return english }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    /// Gli strumenti, le azioni e le aree nella traccia delle richieste in inglese (gli id restano italiani).
    nonisolated static let englishToolNames: [String: String] = [
        "agenda": "agenda", "aggiungi_a_nota": "append to note", "calendari": "calendars", "cerca_conversazioni": "search conversations",
        "cerca_file_mac": "search Mac files", "cerca_nei_file": "search in files", "cerca_web": "web search", "crea_cartella": "new folder",
        "crea_documento": "create document", "crea_evento": "create event", "crea_nota": "create note", "crea_promemoria": "create reminder",
        "elenca_file": "list files", "elimina_evento": "delete event", "elimina_promemoria": "delete reminder", "inoltra_email": "forward email",
        "invia_messaggio": "send message", "leggi_email": "read email", "leggi_file": "read file", "leggi_messaggi": "read messages",
        "leggi_note": "read notes", "leggi_pagina": "read page", "modifica_aperto": "edit open document", "modifica_evento": "edit event",
        "modifica_file": "edit file", "modifica_promemoria": "edit reminder", "ricorda": "remember", "rispondi_email": "reply to email",
        "scrivi_email": "write email", "scrivi_file": "write file", "sposta_file": "move file",
        "rispondi": "reply", "eventi": "events", "promemoria": "reminders", "crea_lista_promemoria": "new reminder list",
        "completa_promemoria": "complete reminder", "crea_foglio": "create sheet", "crea_presentazione": "create presentation", "piano": "plan",
        "mail_leggi": "read mail", "note": "notes", "file": "files", "messaggi": "messages", "modifica_nota": "edit note",
        "genera_immagine": "generate image", "file_elenca": "list files", "file_leggi": "read file", "file_cerca": "search files",
        "file_scrivi": "write file", "file_sposta": "move file", "file_cartella": "new folder", "file_elimina": "delete file",
        "strumento_esterno": "connector", "modifica_artefatto": "edit document", "naviga": "browse", "segui_link": "follow link",
        "nuova_chat": "new chat", "crea_agente": "create Genius", "crea_sito": "create website",
        "calendario": "calendar", "email": "email", "posta": "mail", "contatti": "contacts", "connettori": "connectors", "memoria": "memory",
        "documenti": "documents", "conversazioni": "conversations", "immagini": "images", "sito": "website",
    ]
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
