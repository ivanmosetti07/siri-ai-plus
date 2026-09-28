import Foundation

// MARK: - Prima occhiata (rizzo-flow)
//
// Prima dello smistatore e del pianificatore di Apple Intelligence, il modello di rizzo-flow risponde a domande chiuse
// sulla richiesta: in quale area guardare e quale azione fare. Se è sicuro si salta lo smistatore (~1,3 s) e, per le
// azioni che non hanno campi da riempire, anche il pianificatore (~1,5–2 s). Se non è sicuro, o se il modello non c'è,
// decide Apple come prima. Le domande sono in inglese (rizzo-flow è più preciso), la richiesta resta nella sua lingua;
// ogni token costa ~2,5 ms sul Mac, quindi descrizioni corte.

extension Assistant {
    /// Cosa ha deciso la prima occhiata.
    struct FirstLook {
        var route: ToolRoute
        /// Azione sicura (nil = la sceglie il pianificatore tra le candidate).
        var action: Action?
        var decisions: DecisionEngine.Decisions
    }

    /// Soglie delle decisioni rapide, scelte sui banchi etichettati (smistatore, smistatore-verifica, router-en,
    /// pianificatore, planner-en, strumenti, tools-en): mai vicino a 0,5.
    enum Quick {
        /// Sui banchi dello smistatore gli errori sicuri stavano fra 0,87 e 0,91 («chi mi ha cercato oggi?» → calendario 0,90):
        /// sotto 0,92 decide lo smistatore di Apple.
        static let area = 0.92
        /// «Nessuna area» salta anche il pianificatore.
        static let none = 0.90
        static let action = 0.85
        /// Aree in più: ogni altra area con almeno questa probabilità entra fra le candidate (una scelta fa da scelta multipla).
        static let extraArea = 0.15
        static let refersBack = 0.90
    }

    /// La richiesta con il contesto minimo per capirla, sempre nello stesso formato: le domande dello stesso turno
    /// (riscrittura, area, azione, modello) trovano lo stato già calcolato nella cache di llama.cpp.
    func decisionState(for prompt: String, attachments names: [String] = []) -> DecisionState {
        var attachments: [DecisionJSON] = names.map { .string($0) }
        if names.isEmpty, !work.images.isEmpty { attachments.append(.string(work.images.count == 1 ? "an image" : "\(work.images.count) images")) }
        if names.isEmpty, let text = work.attachments, let first = text.split(separator: "\n").first {
            attachments.append(.string(String(first.prefix(120))))
        }
        return DecisionState(DecisionJSON.fields([
            ("request", .string(String(prompt.prefix(1500)))),
            ("previous_exchange", recentConversation(exchanges: 1, user: 160, reply: 220).map { .string($0) }),
            ("project_chat", work.projectName.map { .string($0) }),
            ("open_in_apps", work.screen.map { .string("\($0.app): \($0.title)") }),
            ("open_document", work.artifactKind.map { .string("\($0): \(work.artifactTitle ?? "")") }),
            ("attachments", attachments.isEmpty ? nil : .array(attachments)),
        ]))
    }

    // MARK: Domande

    /// Le aree dello smistatore in inglese. Provate sui banchi dello smistatore (smistatore, smistatore-verifica, router-en):
    /// con gli esempi di posta ricevuta («chi ha mandato», «novità da qualcuno») 40/44 al primo posto, contro 32/44 senza.
    nonisolated static let areaDescriptions: [String: String] = [
        "calendario": "Calendar: events, meetings, appointments, availability, what the user has on a day.",
        "promemoria": "Reminders: to-dos, deadlines, payments or things not to forget.",
        "email": "Email: mail received (orders, parcels, invoices, replies, who sent something, news from someone) or mail to write.",
        "messaggi": "Messages and calls: texts and chats with people, who wrote to or called the user.",
        "note": "The Notes app: reading, searching or writing notes.",
        "file": "Files and documents saved on the Mac or in the project.",
        "web": "The internet: news, prices, weather, schedules, recent public facts, web pages.",
        "documenti": "Creating or changing a document, spreadsheet, presentation or website.",
        "immagini": "Drawing or generating an image.",
        "memoria": "Remembering something the user tells (a fact, a code, a preference), or finding what was said in past chats.",
        "agenti": "Creating an automatic agent (Genius) that works on its own, or opening a new chat.",
    ]

    nonisolated static func areaQuestion(_ catalog: [ToolCatalogEntry]) -> DecisionQuestion {
        var options = catalog.map { entry -> DecisionQuestion.Option in
            if let description = areaDescriptions[entry.name] { return .init(entry.name, description) }
            // Connettori: «connettori» (Apple) o uno per servizio (modelli esterni).
            let server = entry.name.hasPrefix("connettore_") ? String(entry.name.dropFirst("connettore_".count)).replacingOccurrences(of: "_", with: " ") : nil
            return .init(entry.name, (server.map { "The connected service \($0): " } ?? "The user's connected services: ")
                         + shortened(entry.summary, to: 100))
        }
        options.append(.init("none", "None: general knowledge (authors, history, science, definitions), advice, ideas, explanations, math, "
                             + "or a text to write in the chat."))
        var question = DecisionQuestion.choice("area", "Where should the assistant look, or what should it use, to handle the request? "
            + "The user's own things (mail, messages, appointments, reminders, notes, files) are in their apps even when the request "
            + "does not name the app.", options, policy: .closed)
        question.questionFirst = true
        return question
    }

    /// Le azioni del pianificatore in inglese, per la seconda domanda.
    nonisolated static let actionDescriptions: [Action: String] = [
        .rispondi: "Just answer in the chat, without using any app or data.",
        .agenda: "Show the schedule of a period: events and reminders together.",
        .eventi: "Search calendar events by name or topic.",
        .promemoria: "Show existing reminders or lists.",
        .calendari: "List the calendars and reminder lists.",
        .crea_evento: "Create a new calendar event (not change an existing one).",
        .crea_promemoria: "Create one reminder.",
        .crea_lista_promemoria: "Create several reminders or a whole list.",
        .modifica_evento: "Change an existing event: move, postpone, bring forward, extend, rename.",
        .elimina_evento: "Delete an existing event.",
        .completa_promemoria: "Mark a reminder as done.",
        .modifica_promemoria: "Change an existing reminder.",
        .elimina_promemoria: "Delete a reminder.",
        .mail_leggi: "Read or search emails already received.",
        .scrivi_email: "Write a new email.",
        .rispondi_email: "Reply to an email.",
        .inoltra_email: "Forward an email.",
        .messaggi: "Read or search messages already received.",
        .invia_messaggio: "Send or reply with a message to someone.",
        .note: "Read or search notes.",
        .crea_nota: "Create a new note.",
        .modifica_nota: "Add something to an existing note.",
        .file: "Find files on the Mac.",
        .file_elenca: "List the files of the project or of a folder.",
        .file_leggi: "Read a file of the project.",
        .file_cerca: "Search text inside the project files.",
        .file_scrivi: "Create or rewrite a file of the project.",
        .file_sposta: "Move or rename a file.",
        .file_cartella: "Create a folder.",
        .file_elimina: "Delete a file.",
        .cerca_web: "Search the internet.",
        .leggi_pagina: "Read a specific web page or link.",
        .naviga: "Open a website in the browser.",
        .segui_link: "Follow a link on the open page.",
        .crea_documento: "Create a text document.",
        .crea_foglio: "Create a spreadsheet.",
        .crea_presentazione: "Create a presentation.",
        .crea_sito: "Create a website.",
        .modifica_artefatto: "Change the document that is open.",
        .genera_immagine: "Generate an image.",
        .ricorda: "Save a fact to remember.",
        .cerca_conversazioni: "Find something said in past chats.",
        .crea_agente: "Create an automatic agent (Genius).",
        .nuova_chat: "Open a new chat.",
        .strumento_esterno: "Use a connected service.",
    ]

    nonisolated static func actionQuestion(_ actions: [Action]) -> DecisionQuestion? {
        let options = actions.compactMap { action in actionDescriptions[action].map { DecisionQuestion.Option(action.rawValue, $0) } }
        guard options.count >= 2, options.count <= DecisionPrompt.letters.count else { return nil }
        var question = DecisionQuestion.choice("action", "Which single action handles the request?", options, policy: .closed)
        question.questionFirst = true
        return question
    }

    nonisolated static let refersBackQuestion: DecisionQuestion = {
        var question = DecisionQuestion.boolean(
            "refers_back", "Does the request need the previous exchange to be understood (it refers to something said before)?",
            yes: "Yes. Without the previous exchange the request is unclear.",
            no: "No. The request is clear on its own.", policy: .closed)
        question.questionFirst = true
        return question
    }()

    // MARK: Prima occhiata

    /// Area (e, se `askAction`, azione) decise da rizzo-flow. nil se il motore non c'è o non è sicuro dell'area:
    /// allora decide lo smistatore di Apple.
    func firstLook(_ prompt: String, catalog: [ToolCatalogEntry], askAction: Bool) async -> FirstLook? {
        guard DecisionEngine.isEnabled, DecisionEngine.isInstalled, !catalog.isEmpty else { return nil }
        let byArea: [String: [Action]] = askAction
            ? Dictionary(catalog.map { ($0.name, Array(actions(inFamilies: [$0.name]))) }, uniquingKeysWith: { first, _ in first }) : [:]
        let cues = askAction ? candidateActions(for: Self.withoutQuotes(prompt)) : []
        let available = Set(availableActions)
        let followUp: @Sendable ([String: DecisionAnswer]) -> [DecisionQuestion] = { answers in
            guard askAction, let area = answers["area"], area.confident(Quick.area) else { return [] }
            let areas = Self.chosenAreas(area)
            guard !areas.isEmpty else { return [] }
            // Niente «rispondi» fra le opzioni: l'area è già una scelta sicura di usare qualcosa (con «rispondi» il modello
            // si divideva tra le due e il pianificatore partiva comunque).
            var allowed = Set(areas.flatMap { byArea[$0] ?? [] }).union(cues)
            allowed.remove(.rispondi)
            allowed.remove(.piano)
            let ordered = Action.allCases.filter { allowed.contains($0) && available.contains($0) }
            return Self.actionQuestion(ordered).map { [$0] } ?? []
        }
        guard let result = await DecisionEngine.shared.decide(decisionState(for: prompt), [Self.areaQuestion(catalog)],
                                                              budget: 3, label: "prima occhiata", then: followUp),
              let area = result["area"], area.confident(area.choice == "none" ? Quick.none : Quick.area) else { return nil }
        let areas = Self.chosenAreas(area)
        // Consigli e spiegazioni («come posso organizzarmi con troppe riunioni?») parlano di un'area senza chiedere di usarla:
        // lì rizzo-flow sceglieva il calendario con 0,97. Decide lo smistatore di Apple.
        if !areas.isEmpty, Self.asksAdvice(prompt) { return nil }
        // Una domanda che non parla di chi scrive non riguarda le sue app: «chi ha scritto I promessi sposi?» andava su
        // Messaggi con 0,91 («chi mi ha scritto?» sì). Decide lo smistatore di Apple.
        if let first = areas.first, Self.personalAreas.contains(first), Self.asksAboutOthers(prompt) { return nil }
        var route = ToolRoute(tools: areas, multiStep: Self.gathersFromRoutedSources(prompt, areas: areas),
                              note: "rizzo-flow · " + result.summary, decided: true, milliseconds: result.milliseconds)
        route.areas = areas
        var action: Action?
        if askAction {
            if areas.isEmpty { action = .rispondi }
            else if let chosen = result["action"], chosen.confident(Quick.action), let id = chosen.choice { action = Action(rawValue: id) }
        }
        return FirstLook(route: route, action: action, decisions: result)
    }

    /// Le aree delle cose di chi scrive.
    nonisolated static let personalAreas: Set<String> = ["email", "messaggi", "calendario", "promemoria", "note", "file", "memoria"]

    /// Una domanda senza riferimenti a chi scrive («mi», «mio», «ho», «my», «I»…): chiede del mondo, non delle sue cose.
    nonisolated static func asksAboutOthers(_ prompt: String) -> Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let question = text.hasSuffix("?")
            || lower.range(of: #"^(chi|cosa|che|quando|dove|qual|quali|quanto|quanti|come|perch)"#, options: .regularExpression) != nil
            || lower.range(of: #"^(who|what|when|where|which|how|why)\b"#, options: .regularExpression) != nil
        guard question else { return false }
        // Nella lingua della richiesta: in italiano «I» è un articolo («I promessi sposi»), non «io».
        let firstPerson = Language.isEnglish ? #"\b(i|me|my|mine|we|us|our|ours|i'm|i've|i'll|i'd)\b"#
            : #"\b(mi|me|mio|mia|miei|mie|ho|ci|noi|nostr[oaie]|abbiamo|devo|dobbiamo|sono)\b"#
        return lower.range(of: firstPerson, options: .regularExpression) == nil
    }

    /// L'area più probabile più le altre sopra la soglia (nessuna se vince «none»).
    nonisolated static func chosenAreas(_ answer: DecisionAnswer) -> [String] {
        guard let top = answer.choice, top != "none" else { return [] }
        return [top] + answer.probabilities
            .filter { $0.id != top && $0.id != "none" && $0.probability >= Quick.extraArea }
            .sorted { $0.probability > $1.probability }.map(\.id)
    }

    /// Il piano deciso dalla prima occhiata: senza pianificatore se l'azione non ha campi da riempire (o li danno le
    /// regole), altrimenti il pianificatore riempie i campi della sola azione scelta. nil = decide il pianificatore.
    func quickPlan(_ look: FirstLook?, candidates: Set<Action>, parts: Int, prompt: String) async -> Plan? {
        guard let look, let action = look.action, parts == 1, action == .rispondi || candidates.contains(action) else { return nil }
        if let fields = Self.plannerFreeFields(action, prompt: prompt) {
            Agent.log("PIANO RAPIDO (rizzo-flow): \(action.rawValue) \(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
            return Plan(action: action, fields: fields)
        }
        return await makePlan(for: prompt, allowed: [action])
    }

    /// Campi di un'azione che si possono decidere senza il pianificatore (nil = serve il pianificatore).
    nonisolated static func plannerFreeFields(_ action: Action, prompt: String) -> [String: String]? {
        switch action {
        case .rispondi, .cerca_web, .calendari:
            return [:]
        case .agenda, .promemoria:
            // Un giorno solo (o nessuno: oggi). Settimane, mesi e intervalli li capisce il pianificatore.
            guard !mentionsPeriod(prompt) else { return nil }
            let days = DateExpressions.days(in: prompt)
            guard days.count <= 1 else { return nil }
            guard let day = days.first?.date.localDay else { return [:] }
            return action == .agenda ? ["dal": day, "al": day] : ["al": day]
        default:
            return nil
        }
    }

    /// La richiesta parla di un periodo più lungo di un giorno.
    nonisolated static func mentionsPeriod(_ prompt: String) -> Bool {
        let lower = " " + prompt.lowercased() + " "
        let italian = ["settiman", " mese", " mesi", "weekend", "fine settimana", "prossimi", "fino a", "entro", " dal ", " tra ", " fra ",
                       "quest'anno", " anno ", "giorni"]
        let english = ["week", "month", "weekend", "next few", "coming days", "until", "through", "between", " from ", "this year",
                       " year ", "days"]
        return (italian + (Language.isEnglish ? english : [])).contains(where: lower.contains)
    }
}

extension Assistant {
    /// All'avvio, a server pronto: le domande fisse (riscrittura, Auto, memoria) calcolano la loro parte fissa nella cache del
    /// server, così la prima richiesta vera non paga 1–2 secondi in più (misurato: 1,9 s a freddo, 0,5 s dopo).
    public static func warmDecisions() async {
        let state = DecisionState(text: "Ciao")
        for question in [refersBackQuestion, AutoModel.difficultyQuestion, AutoModel.privateQuestion, rememberQuestion] {
            _ = await DecisionEngine.shared.decide(state, question, priority: .background, label: "riscaldamento")
        }
    }
}
