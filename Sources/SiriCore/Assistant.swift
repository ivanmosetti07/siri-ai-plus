import Foundation
import FoundationModels

/// Cosa l'app deve mostrare in risposta a una richiesta.
public enum Outcome: Sendable {
    /// Risposta testuale: inviare `prompt` alla sessione di chat.
    case reply(prompt: String)
    /// Dati letti (mostrati subito in una scheda) più un riepilogo testuale.
    case agenda(Agenda, prompt: String)
    case eventDraft(EventDraft)
    case reminderDrafts([ReminderDraft], list: String)
    case confirm(PendingAction)
    /// Modifica di un evento o di un promemoria che esistono già, da confermare.
    case eventEdit(EventEditDraft)
    case reminderEdit(ReminderEditDraft)
    /// Testo da aggiungere in fondo a una nota esistente.
    case noteAppend(NoteAppendDraft)
    /// Risposta o inoltro di un'email ricevuta: si apre in Mail, l'utente la invia da lì.
    case mailReply(MailReplyDraft)
    case mailForward(MailForwardDraft)
    case mailDraft(MailDraft)
    case document(DocumentDraft)
    case sheet(SheetDraft)
    case deck(DeckDraft)
    case plan(PlanDraft)
    case unavailable(SourceKind, UnavailableReason)
    /// Messaggio fisso (es. manca un'informazione).
    case message(String)
    case image(prompt: String, style: String?)
    case remembered(String, inProject: Bool)
    case files([ProjectFiles.Entry], prompt: String)
    case fileWrite(FileWriteDraft)
    case fileOp(FileOpDraft)
    case mcpCall(MCPCallDraft)
    /// Modifica precisa di ciò che è aperto al centro (paragrafi, slide, celle), da applicare nell'app.
    case artifactEdit(ArtifactEdit)
    /// Documento nuovo da scrivere su un argomento: l'app lo apre subito e lo riempie mentre viene scritto.
    case writeDocument(topic: String)
    /// Risultati dal web (ricerca o pagina letta) più il prompt per la risposta con le fonti.
    case web(WebAnswer, prompt: String)
    /// Comando per il browser integrato.
    case browse(BrowseCommand)
    /// Note, email, file o messaggi letti dall'app, più il prompt per la risposta.
    case items(AppItems, prompt: String)
    case noteDraft(NoteDraft)
    case messageDraft(MessageDraft)
    /// Compito complesso: ragionamento e passi visibili, eseguiti dai sub-agent.
    case taskPlan(TaskPlan)
    /// Nuova chat chiesta chattando (figlia di quella attuale o indipendente, anche in un progetto).
    case newChat(ChatRequest)
    /// Nuovo agente descritto in chat, da confermare.
    case agentDraft(AgentSpec)
    /// Pagina web (HTML + CSS) da salvare e aprire nel browser integrato.
    case website(WebsiteDraft)
    /// Più esiti in ordine (ciclo a più passaggi): le schede lette e poi il risultato finale.
    indirect case combined([Outcome])
}

/// Modifica di un documento, di una presentazione o di un foglio aperti.
public enum ArtifactEdit: Sendable, Equatable {
    case document(DocumentEditPlan)
    case deck(DeckEditPlan)
    case sheet(SheetEditPlan, index: Int)
    /// Nessuna struttura disponibile: solo la richiesta.
    case instruction(String)

    public var summary: String {
        switch self {
        case .document(let plan): plan.summary
        case .deck(let plan): plan.summary
        case .sheet(let plan, _): plan.summary
        case .instruction: ""
        }
    }

    public var isEmpty: Bool {
        switch self {
        case .document(let plan): plan.operations.isEmpty
        case .deck(let plan): plan.operations.isEmpty
        case .sheet(let plan, _): plan.operations.isEmpty
        case .instruction: false
        }
    }
}

public struct ChatRequest: Sendable, Equatable {
    public var title: String
    public var project: String?
    public var firstMessage: String?
    /// Chat figlia: al termine il riepilogo torna alla chat da cui è partita.
    public var child: Bool

    public init(title: String, project: String?, firstMessage: String?, child: Bool) {
        self.title = title; self.project = project; self.firstMessage = firstMessage; self.child = child
    }
}

public enum BrowseCommand: Sendable, Equatable {
    case open(URL), search(String), follow(String), back
}

/// Contesto di lavoro passato dall'app: progetto, istruzioni, memoria, artefatto aperto, strumenti esterni.
public struct WorkContext: Sendable {
    public var projectName: String?
    public var projectRoot: URL?
    public var agents: String?
    public var projectMemory: [String] = []
    /// MEMORY.md del progetto (o la sua sintesi se lungo).
    public var memoryDigest: String?
    /// Progetti collegati (per "apri una chat nel progetto X").
    public var projectNames: [String] = []
    /// La chat attuale ha già dei messaggi: una chat creata chattando diventa sua figlia.
    public var hasConversation = false
    /// Cartelle collegate a un agente (nome → cartella) e quelle in sola lettura.
    public var linkedFolders: [String: URL] = [:]
    public var readOnlyFolders: Set<String> = []
    /// Anima dell'agente (soul.md) che sta lavorando.
    public var soul: String?
    /// Spazio in uso (Personale, Lavoro, Programmazioni) e le sue indicazioni.
    public var spaceName: String?
    public var spaceInstructions: String?
    public var artifactKind: String?
    public var artifactTitle: String?
    public var artifactSummary: String?
    /// Testo completo di ciò che è aperto (per le domande: "riassumi questo documento").
    public var artifactText: String?
    /// Documento aperto a paragrafi, con la selezione dell'editor (per le modifiche precise).
    public var openDocument: DocumentOutline?
    /// Presentazione aperta e slide selezionata.
    public var openDeck: Deck?
    public var openDeckSlide: Int?
    /// Foglio visibile dello spreadsheet aperto e sua posizione.
    public var openSheet: Sheet?
    public var openSheetIndex = 0
    public var mcpTools: [MCPToolInfo] = []
    /// Istruzioni dei server MCP, per nome del server.
    public var mcpInstructions: [String: String] = [:]
    public var allowFileWrite = true
    /// Pagina aperta nel browser integrato (se è al centro).
    public var browserTitle: String?
    public var browserURL: String?
    public var browserText: String?
    public var browserLinks: [String] = []
    /// Ricerca sul web consentita.
    public var webEnabled = true
    /// Dati che cambiano a ogni turno (es. prossime esecuzioni degli agenti): vanno nella richiesta, non nelle istruzioni.
    public var turnNotes: String?
    /// Testo degli allegati: entra nella risposta, non nella scelta dell'azione.
    public var attachments: String?
    /// Immagini allegate alla richiesta (file locali): Apple Intelligence le guarda mentre scrive la risposta.
    public var images: [URL] = []
    /// Conversazione in corso (esclusa dalla ricerca nelle conversazioni passate).
    public var conversationID: String?
    /// Ciò che l'utente vede nella scheda davanti (email, nota, evento, contatto…): «rispondi», «riassumi questa nota».
    public var screen: ScreenItem?
    /// Le altre schede aperte, una riga ciascuna («Note: nota «Spesa»»).
    public var openTabs: [String] = []

    public init() {}

    /// Istruzioni, mappa e albero dei file del progetto (una guida per cartella, condivisa).
    public var guide: ProjectGuide? { projectRoot.map { ProjectGuide.shared(for: $0) } }

    var files: ProjectFiles? {
        projectRoot.map { root in
            var files = ProjectFiles(root: root)
            files.links = linkedFolders
            files.readOnly = readOnlyFolders
            return files
        }
    }
}

public struct FileWriteDraft: Sendable, Equatable, Codable {
    public var path: String
    public var content: String
    public var exists: Bool
    public var previous: String?
    /// Cosa cambia, in breve (es. "Aggiunge in fondo: …"), per i file esistenti.
    public var change: String?

    public init(path: String, content: String, exists: Bool, previous: String?, change: String? = nil) {
        self.path = path; self.content = content; self.exists = exists; self.previous = previous; self.change = change
    }
}

/// Spostamento, rinomina, nuova cartella o cestino nel progetto, dopo conferma.
public struct FileOpDraft: Sendable, Equatable, Codable {
    public enum Kind: String, Codable, Sendable { case move, folder, trash }
    public var kind: Kind
    public var from: String
    public var to: String

    public init(kind: Kind, from: String, to: String = "") { self.kind = kind; self.from = from; self.to = to }

    public var title: String {
        switch kind {
        case .move: (from as NSString).deletingLastPathComponent == (to as NSString).deletingLastPathComponent ? "Rinomina" : "Sposta"
        case .folder: "Nuova cartella"
        case .trash: "Sposta nel Cestino"
        }
    }
}

public struct MCPCallDraft: Sendable, Equatable, Codable {
    public var tool: MCPToolInfo
    public var arguments: JSONValue
    /// Richiesta originale dell'utente e chiamate già fatte (i server "a catalogo" richiedono più passaggi).
    public var request: String?
    public var steps: [MCPStep]?

    public init(tool: MCPToolInfo, arguments: JSONValue, request: String? = nil, steps: [MCPStep]? = nil) {
        self.tool = tool; self.arguments = arguments; self.request = request; self.steps = steps
    }
}

public struct MCPStep: Sendable, Equatable, Codable {
    public var tool: String
    public var arguments: String
    public var result: String

    public init(tool: String, arguments: String, result: String) { self.tool = tool; self.arguments = arguments; self.result = result }
}

/// Orchestrazione pensata per il modello on-device da ~3B parametri:
/// 1. **Pianificazione** con generazione guidata → una sola azione con i suoi parametri.
/// 2. **Esecuzione** in Swift: letture EventKit, bozze, contenuti generati con schemi.
/// 3. **Risposta**: la chat riceve i dati reali e risponde basandosi solo su quelli.
///
/// Il tool-calling nativo non è affidabile con questo modello: spesso risponde "a memoria",
/// e con `toolCallingMode: .required` va in loop chiamando strumenti a caso.
@MainActor
public final class Assistant {
    public internal(set) var chat: LanguageModelSession
    public private(set) var appleResponseModel: AppleResponseModel = .onDevice
    /// Ultimi dati mostrati: servono al pianificatore per i riferimenti ("cancella il primo").
    var context = ""
    /// Progetto, memoria, artefatto aperto e strumenti: aggiornato dall'app prima di ogni richiesta.
    public var work = WorkContext() {
        didSet {
            if work.projectName != oldValue.projectName || work.agents != oldValue.agents || work.memoryDigest != oldValue.memoryDigest
                || work.spaceName != oldValue.spaceName || work.spaceInstructions != oldValue.spaceInstructions { chat = makeChat() }
        }
    }
    /// Riassunto della conversazione dopo una compattazione.
    var summary: String?
    /// Chat figlia: ciò che si stava dicendo nella chat madre (entra nelle istruzioni, con qualunque modello).
    public var inherited: String? {
        didSet { if inherited != oldValue { chat = makeChat() } }
    }
    /// Quota della finestra di contesto occupata dalla chat (0…1).
    public internal(set) var contextUsage: Double = 0
    /// L'ultima risposta è venuta solo dalle conoscenze del modello (senza dati o strumenti).
    public internal(set) var answeredFromMemory = false
    /// Ultima azione eseguita: serve per le domande di seguito ("e dopodomani?").
    var lastAction: Action?
    /// Scambi recenti (richiesta e risposta mostrata): coerenza con quanto detto prima, anche dopo un riavvio.
    /// Sono la cronologia che riceve ogni modello (vedi `ConversationMemory`).
    public internal(set) var turns: [ChatTurn] = []
    /// Turni già raccolti nel riassunto (`summary`): non si rimandano al modello, ma restano per i richiami.
    var summarizedCount = 0
    /// Finestra del modello che scriverà la risposta: i dati passati si adattano (Apple = 1×, modelli più grandi di più).
    public var budget = ContextBudget.apple
    /// I sub-agent eseguono un passo: niente piani annidati né riformulazioni.
    public var isSubAgent = false
    /// Scelto dall'utente per questa richiesta (menu «+» › Piano con sub-agent): catena di pensieri e sub-agent anche se sembra semplice.
    public var forcePlan = false
    /// Il sub-agent smistatore sceglie gli strumenti a ogni richiesta (`SIRIAI_NO_ROUTER=1` per le prove di confronto).
    public var routesTools = ProcessInfo.processInfo.environment["SIRIAI_NO_ROUTER"] != "1"
    /// Lo smistatore della prossima richiesta, con il catalogo già letto.
    var preparedRouter: (instructions: String, session: LanguageModelSession)?

    /// Tipo della risposta in corso (fatti, confronto, procedura, testo creativo…): temperatura e formato.
    public internal(set) var responseStyle = ResponseStyle.conversation
    /// La risposta si basa su dati letti (web, calendario, file, calcoli): la fantasia va tenuta bassa.
    var groundedAnswer = false
    /// Opzioni di generazione per la risposta della richiesta in corso.
    public var responseOptions: GenerationOptions {
        GenerationOptions(temperature: groundedAnswer || !turnFacts.isEmpty ? min(responseStyle.temperature, 0.3) : responseStyle.temperature)
    }
    /// ID brevi (E1, R2) di questa chat: non valgono in altre conversazioni o negli agenti.
    let ids = IDRegistry()
    /// Passaggi dell'ultima richiesta (strumenti usati, tempi, esiti).
    public internal(set) var trace: RequestTrace?
    /// Errore dell'ultima azione eseguita (per ripiegare su un'altra).
    var lastError: String?
    /// Dati letti dall'ultima azione (per il giro successivo del ciclo).
    var lastObservation: String?
    /// Ricerche web e chiamate ai connettori della richiesta in corso.
    var webSearches = 0
    var mcpCalls = 0
    /// Ultima richiesta resa autonoma (per le ricerche di ripiego sul web).
    public internal(set) var lastRequest = ""
    /// Calcoli esatti della richiesta in corso (orari, date, conti): entrano nel prompt della risposta.
    public internal(set) var turnFacts: [String] = []
    /// Catena di pensieri fatta prima di rispondere alla richiesta in corso (Apple Intelligence sul Mac).
    public internal(set) var turnReasoning: ReasoningNotes?
    /// Token delle istruzioni della chat, contati una volta finché non cambiano.
    var instructionTokenCache: (text: String, tokens: Int)?
    /// File del progetto già aperti nella richiesta in corso: niente doppioni fra contesto e letture.
    var projectReads: Set<String> = []
    /// Contesto del progetto già preparato per la richiesta in corso.
    var projectContextCache: (prompt: String, text: String?)?
    /// Cartelle di cui un modello esterno ha già ricevuto le istruzioni in questa richiesta.
    var folderInstructionsSent: Set<String> = []
    /// Una lettura chiesta da un modello esterno: i dati tornano a lui, niente contesto del progetto aggiunto.
    var readingForTool = false
    /// Immagini entrate in questa sessione: con loro il sistema non sa contare i token e serve una stima.
    var imagesInSession = 0
    /// Più elementi corrispondono alla richiesta: la prossima risposta ("la seconda") sceglie.
    var pendingChoice: PendingChoice?
    /// Email a cui rispondere con il prossimo messaggio ("Cosa vuoi rispondere a Mario?").
    var pendingReply: MailMessage?
    /// Ultimi elementi mostrati o toccati: servono per "spostala", "il primo", "rispondigli".
    var recentEvents: [EventItem] = []
    var recentEvent: EventItem?
    var recentReminders: [ReminderItem] = []
    var recentReminder: ReminderItem?
    var recentMails: [MailMessage] = []
    var recentMail: MailMessage?
    /// Elemento sullo schermo indicato dalla richiesta in corso («questa email», «riassumila» dopo averla selezionata).
    var screenFocus: ScreenItem?
    /// Ultimo elemento sullo schermo visto da una richiesta: se cambia, l'utente l'ha appena selezionato.
    var previousScreen: String?
    /// L'elemento sullo schermo è cambiato dalla richiesta precedente: l'utente l'ha appena selezionato.
    var screenFresh = false
    /// La richiesta lo indica esplicitamente («questa email», «qui», «riassumila» appena selezionata): le regole agiscono su quello.
    /// Senza indicazione ma con parole in comune («quanto pago di affitto?» con il contratto aperto) il testo entra solo nel contesto.
    var screenPointed = false
    /// Il modello scelto dall'utente, se non è Apple Intelligence: scrive i testi dentro le azioni (con ripiego su Apple).
    public var textWriter: TextWriter?
    public var textWriterName: String?

    public init() {
        chat = LanguageModelSession(model: Agent.model)
        chat = makeChat()
    }

    /// La scelta si aggiorna prima di ogni richiesta; il cambio conserva gli scambi visibili.
    public func selectAppleResponseModel(_ model: AppleResponseModel) {
        guard model != appleResponseModel else { return }
        appleResponseModel = model
        budget = .apple(model)
        chat = makeChat()
        contextUsage = 0
    }

    public func reset(clearMemory: Bool = true) {
        summary = nil
        if clearMemory { inherited = nil }
        if clearMemory { turns = []; summarizedCount = 0 }
        chat = makeChat()
        contextUsage = 0
        if clearMemory {
            context = ""
            ids.reset()
            pendingChoice = nil
            pendingReply = nil
            recentEvents = []; recentEvent = nil
            recentReminders = []; recentReminder = nil
            recentMails = []; recentMail = nil
        }
    }

    public func remember(_ text: String) {
        context = String(text.prefix(1500))
    }

    // MARK: - Ingresso principale

    /// - Parameters:
    ///   - enabled: fonti collegate e autorizzate.
    ///   - picked: fonti scelte dall'utente per questa richiesta (vuoto = automatico).
    ///   - status: aggiornamenti per l'interfaccia ("Scrivo il documento…").
    public func handle(_ rawPrompt: String, enabled: Set<SourceKind>, picked: Set<SourceKind>,
                       status: @escaping @MainActor (String) -> Void) async -> Outcome {
        status("Capisco la richiesta…")
        answeredFromMemory = false
        beginRequest(rawPrompt)
        // Risposta a una domanda di prima: "la seconda" (quale evento, promemoria o nota) o il testo della risposta a un'email.
        if let resumed = resumePending(rawPrompt) {
            Agent.log("RIPRESA: \(resumed.plan)")
            lastAction = resumed.plan.action
            if ProcessInfo.processInfo.environment["SIRIAI_PLAN_ONLY"] == "1" { return .message("PIANO \(resumed.plan)") }
            return await runLoop(first: resumed.plan, prompt: resumed.prompt, rawPrompt: resumed.prompt, candidates: [resumed.plan.action],
                                 parts: [resumed.prompt], enabled: enabled, picked: picked, status: status)
        }
        // Chat di un progetto: la cartella è pronta prima di scegliere (la prima volta l'albero si legge da disco).
        await prepareProject(status: status)
        // Ciò che l'utente ha davanti nelle app («questa email», «riassumila» dopo averla selezionata).
        prepareScreen(for: rawPrompt)
        // «Rendilo più formale», «fanne una versione in inglese»: si rielabora il testo della risposta di prima, in chat.
        if !isSubAgent, work.artifactKind == nil, screenFocus == nil, Self.reworksPreviousReply(rawPrompt), let previous = previousReplyText {
            Agent.log("RIELABORO LA RISPOSTA PRECEDENTE: \(rawPrompt)")
            lastAction = .rispondi
            lastRequest = rawPrompt
            if ProcessInfo.processInfo.environment["SIRIAI_PLAN_ONLY"] == "1" { return .message("PIANO rispondi") }
            responseStyle = ResponseStyle.detect(rawPrompt) == .creative ? .creative : .conversation
            return .reply(prompt: Self.reworkPrompt(previous: previous, request: rawPrompt))
        }
        // "E lui?", "fallo più corto", "e a Roma?": la richiesta viene resa autonoma usando la conversazione recente
        // (non quando parla di ciò che è sullo schermo: lì il riferimento è già chiaro).
        // «Scelgo il secondo»: prima l'app risolve i riferimenti a un elenco appena scritto, poi il modello il resto.
        let listed = isSubAgent || screenFocus != nil || work.artifactKind != nil ? rawPrompt : resolvingOrdinals(rawPrompt)
        let prompt = isSubAgent || screenFocus != nil ? listed : await standalone(listed)
        lastRequest = prompt
        // Tipo di risposta: i sub-agent raccolgono dati (niente fantasia); i testi da elaborare restano fedeli all'originale.
        let style = ResponseStyle.detect(prompt)
        responseStyle = isSubAgent || (Self.isTextTask(prompt) && style != .creative) ? .factual : style
        if prompt != rawPrompt {
            Agent.log("RIFORMULATA: \(prompt)")
            trace?.rewritten = prompt
        }
        // Strumenti solo quando servono: se nessuna parola della richiesta rimanda a un'azione,
        // si risponde subito senza pianificatore; altrimenti il pianificatore sceglie solo fra le azioni plausibili.
        // Più azioni nella stessa frase ("cosa ho domani e scrivi un'email a Marco…"): una parte per giro del ciclo.
        // "Cancella tutto e scrivi hello world" con un documento aperto è una modifica sola, non due comandi.
        let editingOpen = work.artifactKind != nil && Self.isArtifactCommand(prompt)
        // Il sub-agent smistatore legge la richiesta e sceglie gli strumenti, e dice se il lavoro va a passi; non serve quando
        // l'app sa già cosa fare (comandi su ciò che è sullo schermo o che esiste già, testi da elaborare, saluti).
        let route: ToolRoute? = shouldRoute(prompt, editingOpen: editingOpen)
            ? await { status("Scelgo gli strumenti…"); return await routeTools(for: Self.withoutQuotes(prompt), catalog: familyCatalog(), hints: familyHints(for: prompt)) }()
            : nil
        // Il piano con i sub-agent parte da solo per i compiti complessi: secondo le regole dell'app o secondo lo smistatore.
        // Una richiesta che l'app sa già dividere in comandi («cosa ho domani e scrivi a Marco…») resta divisa: ogni parte ha la sua scheda.
        let routedPlan = route.map { Self.gathersFromRoutedSources(prompt, areas: $0.tools) } == true && Self.splitRequest(prompt).count == 1
        let complex = !isSubAgent && (forcePlan || Self.isComplex(prompt) || routedPlan)
        var parts = isSubAgent || editingOpen || complex || Self.isTextTask(prompt) ? [prompt] : Self.splitRequest(prompt)
        let firstPart = parts[0]
        if parts.count > 1 { Agent.log("PARTI: \(parts)") }
        // Orari, date ed espressioni scritte nella richiesta: i conti li fa l'app, non il modello.
        turnFacts = Self.ruleFacts(for: Self.withoutQuotes(prompt))
        if !turnFacts.isEmpty {
            Agent.log("CALCOLI: \(turnFacts)")
            traceCalculations(turnFacts)
        }
        if !work.images.isEmpty {
            // Le copie degli allegati hanno un prefisso tecnico ("E9B4A2AF-scontrino.png"): si mostra il nome originale.
            let names = work.images.map { $0.lastPathComponent.replacingOccurrences(of: #"^[0-9A-Fa-f]{8}-"#, with: "", options: .regularExpression) }
            trace?.steps.append(TraceStep(action: "immagine", detail: names.joined(separator: " · "),
                                          result: "guardata da Apple Intelligence", milliseconds: 0, ok: true))
        }
        // "Riassumi / traduci questo testo: «…»": il testo citato è materiale da elaborare, niente strumenti.
        // Le parole chiave trovano le azioni ovvie; lo smistatore aggiunge quelle che la richiesta chiede senza nominarle.
        let cueCandidates = Self.isTextTask(firstPart) ? [] : candidateActions(for: Self.withoutQuotes(firstPart))
        var candidates = cueCandidates
        // Aree che le parole chiave non avevano visto (la richiesta non le nomina: «mi è arrivato qualcosa da Amazon?»).
        var rescued: [String] = []
        if let route, route.decided, parts.count == 1 {
            let routed = actions(inFamilies: route.tools)
            // Le aree con azioni che le parole chiave non avevano trovato: lì lo smistatore ha capito qualcosa in più.
            rescued = route.tools.filter { name in !actions(inFamilies: [name]).subtracting(cueCandidates).isEmpty }
            candidates.formUnion(routed)
            traceRoute(route, chosen: candidates.map(\.rawValue).sorted())
        }
        // Comandi sull'elemento sullo schermo ("rispondi che va bene", "spostalo alle 16", "aggiungi il latte qui").
        let screenPlan = screenAction(firstPart).flatMap { availableActions.contains($0.action) ? $0 : nil }
        // Comandi chiari su ciò che esiste già ("sposta la riunione…", "inoltra a Giulia…"): le regole bastano, niente pianificatore.
        let decided = screenPlan != nil || Self.isTextTask(firstPart) || (work.artifactKind != nil && Self.isArtifactCommand(firstPart)) ? nil
            : Self.changeAction(firstPart).flatMap { availableActions.contains($0) ? $0 : nil }
        // Domande su ciò che è sullo schermo ("riassumi questa email", "chi l'ha mandata?"): si risponde leggendolo,
        // senza pianificatore e senza cercare nella posta o sul web.
        let screenQuestion = screenPlan == nil && decided == nil && screenPointed && ScreenItem.isQuestion(firstPart)
        var plan = if let screenPlan { screenPlan }
            else if let decided { Plan(action: decided, fields: [:]) }
            else if candidates.isEmpty || screenQuestion { Plan(action: .rispondi, fields: [:]) }
            else { await makePlan(for: firstPart, allowed: candidates) }
        if screenPlan == nil, !screenQuestion { applyRules(to: &plan, prompt: firstPart, candidates: candidates) }
        // Con un'immagine allegata "cosa c'è in questa foto?" è una domanda sull'immagine, non una richiesta di disegnarne una,
        // e "quanto costava la spremuta?" si legge nello scontrino, non sul web.
        if !work.images.isEmpty, plan.action == .genera_immagine,
           !["disegna", "genera", "crea un'immagine", "crea una immagine", "illustrazione", "fammi un'immagine"].contains(where: firstPart.lowercased().contains) {
            plan.action = .rispondi
        }
        if !work.images.isEmpty, plan.action == .cerca_web,
           !["cerca", "internet", "online", "sul web", "google"].contains(where: firstPart.lowercased().contains) {
            plan.action = .rispondi
        }
        // Connettore scelto dal pianificatore senza che la richiesta lo riguardi: si ripianifica senza.
        if plan.action == .strumento_esterno, plan["server"] == nil, namedServer(firstPart.lowercased()) == nil,
           strongServerMatch(firstPart.lowercased()) == nil {
            var others = candidates
            others.remove(.strumento_esterno)
            plan = others.isEmpty ? Plan(action: .rispondi, fields: [:]) : await makePlan(for: firstPart, allowed: others)
            applyRules(to: &plan, prompt: firstPart, candidates: others)
        }
        // Domande di attualità ("chi è il sindaco…", "quanto costa…"): se l'unica azione plausibile è il web, si cerca.
        // Non per i conti e le date che l'app sa calcolare con i dati della domanda.
        if plan.action == .rispondi, cueCandidates == [.cerca_web], work.webEnabled, turnFacts.isEmpty, work.images.isEmpty, screenFocus == nil,
           !(Calculations.looksArithmetic(prompt) && Calculations.numbers(in: prompt).count >= 2),
           prompt.hasSuffix("?") || ["chi ", "quanto ", "quanti ", "quando ", "dove ", "qual ", "quale ", "cosa succede", "come sta"].contains(where: prompt.lowercased().hasPrefix) {
            plan.action = .cerca_web
            plan.fields["cerca"] = prompt
        }
        // Salute, leggi, soldi: si risponde con le fonti invece che a memoria (non per i conti con tutti i dati nella domanda).
        if !isSubAgent, plan.action == .rispondi, work.webEnabled, turnFacts.isEmpty, !Self.isTextTask(prompt), responseStyle != .creative, screenFocus == nil,
           RiskyDomain.detect(prompt) != nil, !(Calculations.looksArithmetic(prompt) && Calculations.numbers(in: prompt).count >= 2) {
            plan.action = .cerca_web
            plan.fields["cerca"] = prompt
        }
        // Chat di un progetto: se le istruzioni indicano i file per questa richiesta (o la richiesta li nomina), rispondono loro,
        // non il web o la ricerca sul Mac, anche con altre app aperte. Chi chiede esplicitamente il web lo ottiene.
        if work.guide != nil, screenPlan == nil, [.cerca_web, .file].contains(plan.action),
           !["cerca su", "sul web", "internet", "online", "google", "in rete", "sul mac", "nel mac", "finder", "spotlight"].contains(where: firstPart.lowercased().contains),
           projectAnswers(firstPart) {
            Agent.log("PROGETTO: \(plan.action.rawValue) → rispondi con i file del progetto")
            plan = Plan(action: .rispondi, fields: [:])
        }
        // «Parliamo del lancio…», «ti dico che…»: l'utente racconta, non chiede di cercare sul web.
        if plan.action == .cerca_web,
           firstPart.lowercased().range(of: #"^(?:allora\s+|ok\s+|dunque\s+)?(?:parliamo|parlo|discutiamo|ragioniamo|ti dico|ti racconto|sappi|tieni presente|considera)\b"#, options: .regularExpression) != nil,
           !["cerca su", "sul web", "internet", "online", "google", "in rete"].contains(where: firstPart.lowercased().contains) {
            plan = Plan(action: .rispondi, fields: [:])
        }
        // Chat figlia: «quando esce il sito?» parla di ciò che si diceva nella madre, non di qualcosa da cercare sul web.
        if plan.action == .cerca_web, let inherited, !inherited.isEmpty,
           !["cerca su", "sul web", "internet", "online", "google", "in rete", "notizie"].contains(where: firstPart.lowercased().contains),
           Self.significant(MemoryStore.keywords(firstPart)).intersection(Self.significant(MemoryStore.keywords(inherited))).count >= 2 {
            Agent.log("CHAT FIGLIA: cerca_web → rispondi con il contesto della madre")
            plan = Plan(action: .rispondi, fields: [:])
        }
        // Un sub-agent con un passo di ricerca non deve rispondere a memoria.
        if isSubAgent, plan.action == .rispondi, work.webEnabled,
           ["cerca", "trova", "ricerca", "raccogli", "recupera", "verifica"].contains(where: { prompt.lowercased().hasPrefix($0) }) {
            plan.action = .cerca_web
        }
        // «Scrivi una frase di benvenuto per il sito»: un testo per il sito, non un sito da creare.
        if plan.action == .crea_sito, Self.isTextForSite(firstPart) {
            Agent.log("TESTO PER IL SITO: crea_sito → rispondi")
            plan = Plan(action: .rispondi, fields: [:])
        }
        if screenPlan == nil { dropUnaskedCreation(&plan, prompt: firstPart) }
        // Il pianificatore piccolo ripiega su «rispondi» quando la richiesta non nomina l'app (provato: anche con il suggerimento
        // dello smistatore): se lo smistatore ha trovato un'area delle cose di Ivan, si usa l'azione ovvia di quell'area,
        // con i campi che il pianificatore ha già estratto (titolo, scadenza, cerca, destinatari).
        // Anche il web scelto solo perché lo smistatore l'aveva messo fra le aree («dove avevo messo il contratto?» è un file).
        let routerOnlyWeb = plan.action == .cerca_web && !cueCandidates.contains(.cerca_web) && !rescued.isEmpty && rescued.first != "web"
        if plan.action == .rispondi || routerOnlyWeb, screenPlan == nil, decided == nil, !screenQuestion, work.images.isEmpty,
           let action = rescueAction(areas: rescued.filter { $0 != "web" }, prompt: firstPart, withCalculations: !turnFacts.isEmpty) {
            Agent.log("SMISTATORE: rispondi → \(action.rawValue) (area \(rescued.joined(separator: ", ")))")
            plan.action = action
        }
        Agent.log("CANDIDATE: \(candidates.map(\.rawValue).sorted().joined(separator: ",")) PIANO: \(plan)")
        trace?.candidates = candidates.map(\.rawValue).sorted()
        lastAction = plan.action
        if ProcessInfo.processInfo.environment["SIRIAI_PLAN_ONLY"] == "1" { return .message("PIANO \(plan)") }
        // Compiti complessi (ricerca, analisi, più passaggi): piano visibile eseguito dai sub-agent.
        let plannable: Set<Action> = [.rispondi, .cerca_web, .leggi_pagina, .crea_documento, .file_leggi, .file_cerca, .file_elenca,
                                      .strumento_esterno, .note, .mail_leggi, .file]
        if complex, forcePlan || (screenFocus == nil && plannable.contains(plan.action)) {
            status("Ragiono sul compito…")
            if let taskPlan = try? await makeTaskPlan(for: prompt), taskPlan.steps.count >= 2 {
                Agent.log("PIANO DI LAVORO: \(taskPlan.steps.map(\.title))")
                return .taskPlan(taskPlan)
            }
        }

        // «Fai un documento da questa nota», «scrivi a Marco il riassunto di questa email»: il testo sullo schermo è il materiale.
        if plan.action != .rispondi, Self.generative.contains(plan.action), let material = screenMaterial(limit: budget.scaled(2000)) {
            plan.fields["argomento"] = (plan["argomento"] ?? firstPart) + "\n\n" + material
            parts[0] += "\n\n" + material
        }
        return await runLoop(first: plan, prompt: prompt, rawPrompt: rawPrompt, candidates: candidates, parts: parts,
                             enabled: enabled, picked: picked, status: status)
    }

    /// Esegue una sola azione del piano e restituisce cosa mostrare. Gli errori degli strumenti diventano un messaggio
    /// e restano in `lastError`, così il ciclo può correggersi.
    func execute(_ plan: Plan, prompt: String, rawPrompt: String, enabled: Set<SourceKind>, picked: Set<SourceKind>,
                 status: @escaping @MainActor (String) -> Void) async -> Outcome {
        func check(_ source: SourceKind) -> Outcome? {
            if source.support == .comingSoon { return .unavailable(source, .comingSoon) }
            if !enabled.contains(source) { return .unavailable(source, .notConnected) }
            if !picked.isEmpty && !picked.contains(source) { return .unavailable(source, .notSelected) }
            return nil
        }

        do {
            switch plan.action {
            case .rispondi:
                // Problemi, logica e scelte con vincoli: prima la catena di pensieri (sessione a parte), poi la risposta che la segue.
                // Se i conti li hanno già fatti le regole dell'app (orari, date, giorni) il risultato è quello: un ragionamento
                // in più rischia solo di ricalcolarlo male.
                let solvedByRules = !turnFacts.isEmpty && ["che giorno", "che data", "a che ora", "che ore", "quando", "quanti giorni", "quante settimane",
                                                             "quanti mesi", "entro", "quanto manca", "mancano"].contains(where: prompt.lowercased().contains)
                if reasonsBeforeAnswering, !solvedByRules, !Self.isTextTask(prompt), responseStyle != .creative, Self.needsReasoning(prompt) {
                    status("Ragiono passo per passo…")
                    let started = Date.now
                    let conversation = prompt != rawPrompt ? recentConversation(exchanges: 2) : nil
                    if let notes = await reason(about: prompt, conversation: conversation) {
                        turnReasoning = notes
                        // Il conto dell'app diventa il risultato da riportare, se è coerente con la conclusione.
                        if let exact = notes.exact, Self.agrees(notes) || Self.hasArithmeticSlip(notes.steps) { turnFacts.append(exact) }
                        Agent.log("RAGIONAMENTO: \(notes.steps.joined(separator: " | ")) ⟶ \(notes.conclusion)\(notes.exact.map { " [conto: \($0)]" } ?? "")")
                        trace?.reasoning = notes.steps + (notes.conclusion.isEmpty ? [] : ["Conclusione: \(notes.conclusion)"])
                        let used = notes.exact.flatMap { Self.agrees(notes) || Self.hasArithmeticSlip(notes.steps) ? $0 : nil }
                        trace?.steps.append(TraceStep(action: "ragionamento", detail: "\(notes.steps.count) passaggi" + (used.map { " · conto dell'app: \($0)" } ?? ""),
                                                      result: notes.conclusion.isEmpty ? "fatto" : String(notes.conclusion.prefix(140)),
                                                      milliseconds: Int(Date.now.timeIntervalSince(started) * 1000), ok: true))
                    }
                }
                if turnFacts.isEmpty, turnReasoning == nil, !Self.isTextTask(prompt) {
                    let started = Date.now
                    turnFacts = await arithmeticFacts(for: prompt)
                    if !turnFacts.isEmpty {
                        Agent.log("CONTI: \(turnFacts)")
                        traceCalculations(turnFacts, milliseconds: Int(Date.now.timeIntervalSince(started) * 1000))
                    }
                }
                // Con i calcoli dell'app, un ragionamento o un testo da elaborare la risposta non viene "a memoria": niente ripiego sul web.
                answeredFromMemory = turnFacts.isEmpty && turnReasoning == nil && !Self.isTextTask(prompt) && !Self.isCommand(prompt)
                // Lavoro su un testo incollato: niente ricordi né suggerimenti, solo il testo e il compito.
                if Self.isTextTask(rawPrompt) { return .reply(prompt: Self.textTaskPrompt(rawPrompt)) }
                return .reply(prompt: withContext(rawPrompt))

            case .cerca_web, .leggi_pagina, .naviga, .segui_link:
                return try await handleWeb(plan, prompt: prompt, status: status)

            case .nuova_chat:
                return .newChat(chatRequest(from: plan, prompt: prompt))

            case .cerca_conversazioni:
                status("Cerco nelle conversazioni passate…")
                let query = plan["cerca"] ?? prompt
                let hits = ConversationIndex.shared.search(query, limit: budget.scale >= 2 ? 10 : 6, excluding: work.conversationID)
                guard !hits.isEmpty else { return .message("Non trovo conversazioni passate su «\(query)».") }
                let data = hits.map { "- «\($0.title)» (\(Dates.format($0.date, time: false))): \($0.snippet)" }.joined(separator: "\n")
                return .reply(prompt: grounded(prompt, data, label: "conversazioni passate"))

            case .crea_sito:
                status("Scrivo la pagina web…")
                return .website(try await generateWebsite(topic: prompt))

            case .crea_agente:
                status("Configuro l'agente…")
                return .agentDraft(try await draftAgent(from: prompt))

            case .ricorda, .genera_immagine, .file_elenca, .file_leggi, .file_cerca, .file_scrivi, .file_sposta, .file_cartella, .file_elimina,
                 .strumento_esterno, .modifica_artefatto:
                return try await handleWork(plan, prompt: prompt, status: status)

            case .mail_leggi, .note, .file, .messaggi, .crea_nota, .invia_messaggio:
                let source: SourceKind = switch plan.action {
                case .mail_leggi: .mail
                case .note, .crea_nota: .notes
                case .file: .files
                default: .messages
                }
                if let blocked = check(source) { return blocked }
                return try await handleApps(plan, prompt: prompt, status: status)

            case .agenda, .eventi, .promemoria:
                let wantsEvents = plan.action != .promemoria
                let wantsReminders = plan.action != .eventi
                let canEvents = wantsEvents && check(.calendar) == nil
                let canReminders = wantsReminders && check(.reminders) == nil
                guard canEvents || canReminders else {
                    return check(wantsEvents ? .calendar : .reminders) ?? .unavailable(.calendar, .notConnected)
                }
                status(canEvents ? "Consulto il Calendario…" : "Consulto i Promemoria…")
                let agenda = await buildAgenda(plan, events: canEvents, reminders: canReminders)
                var data = describe(agenda)
                if let analysis = Self.dayAnalysis(agenda.events, prompt: prompt) { data += "\n\n" + analysis }
                remember(data)
                return .agenda(agenda, prompt: grounded(prompt, data))

            case .calendari:
                if let blocked = check(.calendar) { return blocked }
                let data = "Calendari: \(EventKitService.writableCalendars().joined(separator: ", "))\nListe promemoria: \(EventKitService.reminderLists().joined(separator: ", "))"
                return .reply(prompt: grounded(prompt, data))

            case .crea_evento:
                if let blocked = check(.calendar) { return blocked }
                guard let title = plan["titolo"] else {
                    remember("Stavo creando un evento ma manca il titolo.")
                    return .message("Come vuoi chiamare l'evento?")
                }
                // Il modello a volte mette l'orario in dal/al invece che in inizio/fine.
                guard let start = Dates.parse(plan["inizio"]) ?? Dates.parse(plan["dal"]) ?? Dates.parse(plan["scadenza"]) else {
                    remember("Stavo creando l'evento «\(title)»: mancano data e ora.")
                    return .message("Per quando vuoi fissare «\(title)»?")
                }
                let begin = start.hasTime ? start.date : Calendar.current.startOfDay(for: start.date)
                let endHint = Dates.parse(plan["fine"]) ?? Dates.parse(plan["al"]).flatMap { $0.hasTime ? $0 : nil }
                var end = endHint?.date ?? begin.addingTimeInterval(start.hasTime ? 3600 : 86_399)
                if end <= begin { end = begin.addingTimeInterval(3600) }
                let calendar = plan["lista"].flatMap { name in
                    EventKitService.writableCalendars().first { $0.localizedCaseInsensitiveContains(name) }
                } ?? EventKitService.defaultCalendar
                return .eventDraft(EventDraft(title: title, start: begin, end: end, isAllDay: !start.hasTime,
                                              calendar: calendar, location: plan["luogo"] ?? ""))

            case .crea_promemoria:
                if let blocked = check(.reminders) { return blocked }
                guard let title = plan["titolo"] else { return .message("Cosa vuoi che ti ricordi?") }
                let due = Dates.parse(plan["scadenza"]) ?? Dates.parse(plan["al"]) ?? Dates.parse(plan["inizio"])
                return .reminderDrafts([ReminderDraft(title: title, due: due?.date, dueHasTime: due?.hasTime ?? false)],
                                       list: reminderList(plan["lista"]))

            case .crea_lista_promemoria:
                if let blocked = check(.reminders) { return blocked }
                status("Preparo i promemoria…")
                let drafts = try await generateReminders(topic: plan["argomento"] ?? prompt)
                return .reminderDrafts(drafts, list: reminderList(plan["lista"]))

            case .elimina_evento, .modifica_evento:
                if let blocked = check(.calendar) { return blocked }
                return try await handleChanges(plan, prompt: prompt, status: status)

            case .completa_promemoria, .elimina_promemoria, .modifica_promemoria:
                if let blocked = check(.reminders) { return blocked }
                return try await handleChanges(plan, prompt: prompt, status: status)

            case .modifica_nota:
                if let blocked = check(.notes) { return blocked }
                return try await handleChanges(plan, prompt: prompt, status: status)

            case .rispondi_email, .inoltra_email:
                if let blocked = check(.mail) { return blocked }
                return try await handleChanges(plan, prompt: prompt, status: status)

            case .scrivi_email:
                if let blocked = check(.mail) { return blocked }
                status("Scrivo l'email…")
                // Contatto o email sullo schermo: l'indirizzo è già noto.
                let recipients = screenEmailAddress(for: plan["destinatari"]) ?? plan["destinatari"]
                return .mailDraft(try await generateMail(topic: plan["argomento"] ?? prompt, recipients: recipients))

            case .crea_documento:
                // "Un documento dove c'è scritto hello world": esattamente quel testo, niente contenuti inventati.
                if let text = Self.literalDocumentText(rawPrompt) ?? Self.literalDocumentText(prompt) {
                    return .document(DocumentDraft(literal: text))
                }
                // I sub-agent consegnano il documento finito; nella chat si apre subito e si riempie mentre viene scritto.
                if isSubAgent {
                    status("Scrivo il documento…")
                    return .document(try await generateDocument(topic: plan["argomento"] ?? prompt))
                }
                return .writeDocument(topic: plan["argomento"] ?? prompt)

            case .crea_foglio:
                status("Preparo il foglio…")
                return .sheet(try await generateSheet(topic: plan["argomento"] ?? prompt))

            case .crea_presentazione:
                status("Preparo le slide…")
                return .deck(try await generateDeck(topic: plan["argomento"] ?? prompt))

            case .piano:
                status("Preparo il piano…")
                return .plan(try await generatePlan(goal: prompt))
            }
        } catch let error as WebError {
            lastError = error.localizedDescription
            return .message(error.localizedDescription)
        } catch let error as AppleAppError {
            lastError = error.localizedDescription
            return .message(error.localizedDescription)
        } catch let error as FileEditError {
            lastError = error.localizedDescription
            return .message(error.localizedDescription)
        } catch let error as ProjectFiles.FileError {
            lastError = error.localizedDescription
            return .message(error.localizedDescription)
        } catch is CancellationError {
            return .message("Risposta interrotta.")
        } catch {
            Agent.log("ERRORE GENERAZIONE: \(error)")
            lastError = error.localizedDescription
            return .message("Non sono riuscito a completare la richiesta con il modello locale. Prova a riformularla in modo più semplice.")
        }
    }

    /// Regole deterministiche dove il modello piccolo sbaglia spesso.
    func applyRules(to plan: inout Plan, prompt rawPrompt: String, candidates: Set<Action> = Set(Action.allCases)) {
        // Stessa stringa per la ricerca e il taglio: con spazi iniziali gli indici non corrispondevano.
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = prompt.lowercased()
        // "Ricordati che…" è memoria; "ricordami di…" resta un promemoria.
        if let range = lower.range(of: #"^(ricordati( che| di)?|ricorda che|tieni a mente( che)?|memorizza( che)?|(segnati|annotati|appuntati)( che| questa cosa)?( per dopo)?:?)\s*"#, options: .regularExpression),
           !lower.hasPrefix("ricordati di ") {
            plan.action = .ricorda
            let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
            plan.fields["argomento"] = prompt.count == lower.count ? String(prompt.dropFirst(offset)) : String(lower[range.upperBound...])
            return
        }
        // Testo da riassumere, tradurre o correggere: le parole citate non sono comandi (mai messaggi o email da lì).
        if Self.isTextTask(prompt) {
            plan.action = .rispondi
            return
        }
        // «Dove devo salvare un appunto?», «come chiamo il report?»: domande, non richieste di creare qualcosa.
        let creations: Set<Action> = [.crea_nota, .crea_documento, .crea_foglio, .crea_presentazione, .crea_sito, .crea_lista_promemoria, .file_scrivi]
        if creations.contains(plan.action), lower.hasSuffix("?"),
           lower.range(of: #"^(?:e\s+)?(?:dove|come|quale|quali|perch[eé]|cosa|che cosa|cos'|chi|quando|quanto|quanti)\b"#, options: .regularExpression) != nil {
            plan.action = .rispondi
            plan.fields = [:]
            return
        }
        // «Cosa ho fatto oggi?», «che cosa è stato fatto?»: una domanda, non «segna come fatto».
        if plan.action == .completa_promemoria,
           lower.hasSuffix("?") || lower.range(of: #"^(?:e\s+)?(?:cosa|che cosa|cos'|quali|quanto|quanti|chi|come|quando|dove)\b"#, options: .regularExpression) != nil {
            plan.action = candidates.contains(.agenda) ? .agenda : .rispondi
            plan.fields = [:]
            return
        }
        // Documento, foglio o presentazione aperti: le domande si rispondono in chat, i comandi di modifica riguardano quello
        // (mai il calendario: "cancella il corpo" non è "elimina evento").
        if work.artifactKind != nil {
            if Self.isArtifactQuestion(prompt) {
                plan.action = .rispondi
                return
            }
            if Self.isArtifactCommand(prompt) {
                plan.action = .modifica_artefatto
                return
            }
        }
        // Eventi, promemoria, note ed email che esistono già: "sposta la riunione…", "inoltra a Giulia…".
        if let action = Self.changeAction(prompt), availableActions.contains(action) {
            plan.action = action
            return
        }
        // "Crea una nota…": una nota nuova, anche se il testo parla di liste o promemoria.
        if lower.range(of: #"^(?:per favore |puoi )?(?:crea|creami|fai|fammi|scrivi|scrivimi|prepara|preparami|apri|aggiungi)\s+(?:una|la)\s+(?:nuova\s+)?nota\b"#, options: .regularExpression) != nil {
            plan.action = .crea_nota
            return
        }
        // Domande su orari o date scritti nella richiesta ("ho riunioni 9-10:30 e 10-11: quanto tempo libero ho?",
        // "che giorno sarà il 25 dicembre?"): rispondono i calcoli dell'app, senza calendario né web.
        if [.agenda, .eventi, .promemoria, .cerca_web, .crea_evento].contains(plan.action), Self.asksComputation(prompt) {
            plan.action = .rispondi
            return
        }
        // Conti con tutti i dati nella domanda ("89,90 € IVA inclusa al 22%: quanto senza IVA?"): niente ricerca sul web.
        if plan.action == .cerca_web, Calculations.looksArithmetic(prompt), Calculations.numbers(in: prompt).count >= 2,
           !["cerca", "internet", "online", "sul web", "oggi", "attual", "aggiornat", "adesso"].contains(where: lower.contains) {
            plan.action = .rispondi
            return
        }
        if chatRules(to: &plan, prompt: prompt, lower: lower) { return }
        if fileRules(to: &plan, prompt: prompt, lower: lower) { return }
        // Un nome di file con estensione + verbo di scrittura, dentro un progetto → scrivere il file.
        if work.projectRoot != nil,
           let match = lower.range(of: #"[\w\-./]+\.(md|txt|json|csv|ya?ml|html|css|js|ts|swift|py|sh|toml)\b"#, options: .regularExpression),
           ["crea", "scrivi", "modifica", "aggiorna", "aggiungi", "salva"].contains(where: lower.contains) {
            plan.action = .file_scrivi
            plan.fields["percorso"] = String(lower[match])
            plan.fields["argomento"] = prompt
            return
        }
        // «Scrivi una poesia…» in un progetto non è un file da scrivere: la richiesta deve parlare di file, cartelle o del progetto,
        // o di qualcosa che la guida del progetto trova (il registro di oggi, un cliente, un file indicato dalle istruzioni).
        if plan.action == .file_scrivi,
           lower.range(of: #"\b(?:file|cartell[ae]|progetto|second brain|vault|inbox|registro|log)\b|\.[a-z]{2,4}\b"#, options: .regularExpression) == nil,
           !projectAnswers(prompt) {
            plan.action = .rispondi
            plan.fields = [:]
        }
        if webRules(to: &plan, prompt: prompt, lower: lower) { return }
        // "Mi ha scritto…", "email non lette": leggere, non scrivere.
        let incoming = #"(mi ha (scritto|mandato|risposto|inviato)|mi hanno scritto|ho ricevuto|(email|mail|messaggi) (di|da) |non lett|da leggere|in arrivo|arrivat)"#
        if lower.range(of: incoming, options: .regularExpression) != nil {
            let mail = ["mail", "email", "posta"].contains(where: lower.contains)
            let texts = ["messaggi", "messaggio", "imessage", "sms"].contains(where: lower.contains)
            if mail && availableActions.contains(.mail_leggi) { plan.action = .mail_leggi; return }
            if texts && !mail { plan.action = .messaggi; return }
        }
        // "Ricorda" solo con un'intenzione esplicita: "cosa ricordi di…" è una domanda.
        if plan.action == .ricorda { plan.action = .rispondi }
        // Azioni che creano o cercano qualcosa valgono solo se la richiesta contiene parole coerenti.
        if let words = Self.cues[plan.action], !words.contains(where: { " \(lower) ".contains($0) }),
           !(plan.action == lastAction && isFollowUp(lower)) { plan.action = .rispondi }

        // Servizio collegato nominato ("su Agency OS…", "@notion") → si usano i suoi strumenti.
        if let server = namedServer(lower) {
            plan.action = .strumento_esterno
            plan.fields["server"] = server
            return
        }
        // Il pianificatore tende a rispondere a memoria: se la richiesta combacia bene con un connettore, si usa quello.
        if plan.action == .rispondi, candidates.contains(.strumento_esterno), let server = strongServerMatch(lower) {
            plan.action = .strumento_esterno
            plan.fields["server"] = server
            return
        }
        // Strumento esterno nominato o scelto dal pianificatore → usarlo, qualunque azione abbia indicato.
        if !work.mcpTools.isEmpty, candidates.contains(.strumento_esterno) {
            let named = work.mcpTools.first { lower.contains($0.name.lowercased()) }
            let chosen = plan["strumento"].flatMap { name in work.mcpTools.first { $0.name == name } }
            // Lo strumento scelto conta solo se il pianificatore ha davvero scelto di usarne uno (o un'app non disponibile).
            let generic: Set<Action> = [.strumento_esterno]
            if let tool = named ?? (generic.contains(plan.action) ? chosen : nil) {
                plan.action = .strumento_esterno
                plan.fields["strumento"] = tool.name
                return
            }
        }
        if plan.action == .strumento_esterno { plan.action = .rispondi }
        let creating: Set<Action> = [.crea_evento, .crea_promemoria, .crea_lista_promemoria, .scrivi_email, .crea_documento, .crea_foglio, .crea_presentazione]
        if creating.contains(plan.action), Self.mentionsSeveralActions(prompt), work.artifactKind == nil { plan.action = .piano }
        // "Un promemoria per ogni obiettivo", "i promemoria per le scadenze": più promemoria da generare, non uno solo.
        if plan.action == .crea_promemoria,
           ["per ogni", "per ciascun", "uno per", "per tutti", "per tutte", "i promemoria", "dei promemoria", "più promemoria"].contains(where: lower.contains) {
            plan.action = .crea_lista_promemoria
            plan.fields["argomento"] = prompt
        }
    }

    /// Parole che rendono plausibile ciascuna azione.
    static let cues: [Action: [String]] = [
        .crea_evento: ["evento", "riunion", "call", "appuntament", "fissa", "calendario", "incontro", "meeting", " alle ", "domani", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica"],
        .crea_promemoria: ["ricordami", "promemoria", "da fare", "todo", "to-do", "non dimenticare"],
        .crea_lista_promemoria: ["promemoria", "da fare", "todo", "attività", "checklist", "lista"],
        .scrivi_email: ["mail", "email", "e-mail", "messaggio a", "scrivi a", "rispondi a"],
        .crea_documento: ["documento", "relazione", "report", "testo", "lettera", "articolo", "verbale", "pages", "scrivimi un", "redigi"],
        .crea_foglio: ["foglio", "tabella", "budget", "calcolo", "numbers", "stime", "grafico", "spreadsheet"],
        .crea_presentazione: ["presentazione", "slide", "keynote", "deck"],
        .genera_immagine: ["immagine", "disegna", "illustrazione", "foto di", "genera un'", "logo", "icona", "sfondo", "ritratto", "schizzo"],
        .agenda: ["oggi", "domani", "settimana", "giornata", "agenda", "impegni", "programma", "cosa ho", "cosa devo", "libero", "calendario", "mese", "weekend", "pomeriggio", "mattina", "stasera", "dopodomani", "prossim"],
        .elimina_evento: ["elimina", "cancella", "rimuovi", "togli"],
        .completa_promemoria: ["fatto", "completa", "segna", "spunta", "finito"],
        .piano: ["organizza", "pianifica", "prepara tutto", "piano"],
        .eventi: ["evento", "eventi", "riunion", "appuntament", "calendario", "meeting", "call", "incontr"],
        .promemoria: ["promemoria", "da fare", "todo", "to-do", "scadenz", "attività"],
        .calendari: ["calendari", "liste", "quali liste"],
        .mail_leggi: ["mail", "posta", "inbox", "mi ha scritto", "email di", "email da", "ricevut"],
        .note: [" note", "nota", "appunt"], .crea_nota: ["nota", " note", "appunt", "annota"],
        .messaggi: ["messaggi", "messaggio", "imessage", "sms", "mi ha scritto", "chat con"],
        .invia_messaggio: ["messaggio", "manda", "invia", "scrivi a", "imessage", "sms"],
        .file: ["file", "cartella", "pdf", "documenti", "documento", "trova", "finder", "sul mac", "dove ho messo", "cerca"],
        .cerca_web: webCues, .leggi_pagina: ["pagina", "sito", "articolo", "link", "safari", "http", "www."],
        .naviga: ["apri", "vai su", "vai a", "naviga", "torna indietro", "indietro", "cerca", "sito"],
        .segui_link: ["clicca", "apri", "link", "vai su", "segui", "sezione", "pulsante"],
        .nuova_chat: ["chat", "conversazione", "sotto-chat", "sottochat"],
        .crea_sito: ["sito", "pagina web", "landing", "html", "css", "pagina internet"],
        .cerca_conversazioni: ["abbiamo parlato", "avevamo deciso", "avevamo detto", "ne abbiamo parlato", "conversazione precedente",
                               "chat precedente", "ti avevo detto", "ti ho detto", "ricordi quando", "l'altra volta", "cosa avevamo",
                               "di cosa abbiamo", "abbiamo deciso", "mi avevi detto", "mi hai detto"],
        .crea_agente: ["agente", "agenti", "ogni mattina", "ogni giorno", "ogni settimana", "ogni lunedì", "ogni sera", "automaticamente", "di continuo"],
    ]

    /// Rete di sicurezza: il modello piccolo tende a scegliere una sola azione anche quando la richiesta ne elenca diverse.
    static func mentionsSeveralActions(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        let groups = [["evento", "eventi", "riunion", "appuntament"], ["promemoria"], ["email", "e-mail", "mail"],
                      ["documento"], ["foglio", "tabella", "budget"], ["presentazione", "slide"]]
        let count = groups.filter { words in words.contains { text.contains($0) } }.count
        // "Scrivi un'email a Luca per spostare la riunione" è una sola azione: servono un elenco o più verbi.
        let listed = text.contains(",") || text.contains(":") || text.contains(";")
            || [" e poi ", " poi ", " e crea", " e fissa", " e prepara", " e scrivi", " e manda", " e aggiungi"].contains(where: text.contains)
        return count >= 3 || (count >= 2 && listed)
    }

    private func reminderList(_ name: String?) -> String {
        name.flatMap { n in EventKitService.reminderLists().first { $0.localizedCaseInsensitiveContains(n) } }
            ?? EventKitService.defaultReminderList
    }

    public func grounded(_ prompt: String, _ data: String, label: String = "calendario, promemoria, file o strumenti") -> String {
        observe(data)
        let context = preamble(for: prompt)
        // In una chat di progetto i file aperti per la richiesta valgono quanto i dati (es. agenda di oggi e registro di oggi).
        let withProject = projectContextCache?.prompt == prompt && projectContextCache?.text != nil
        return """
        \(context)Richiesta dell'utente: \(prompt)

        Dati reali:
        \(Self.untrusted(data, label: label))

        Rispondi in modo utile e conciso usando SOLO questi dati\(withProject ? " e i file del progetto riportati sopra" : ""). Se sono già mostrati in una scheda non ripetere l'elenco completo: evidenzia ciò che conta. Riporta titoli e nomi esattamente come sono. Non mostrare gli ID tra parentesi quadre. Scrivi le date in forma leggibile.\(formatHint)
        """
    }

    // MARK: - Sessione di chat

    /// Sessione del modello Apple con le istruzioni e gli scambi scelti (vedi `fitPrompt`): la cronologia la decide l'app,
    /// così non si perde quando cambiano le istruzioni e non si riempie dei dati letti per le risposte passate.
    func makeChat(history: [ConversationMemory.Exchange] = []) -> LanguageModelSession {
        let instructions = chatInstructions()
        var entries: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: [Self.segment(instructions)], toolDefinitions: []))]
        for exchange in history {
            var asked = exchange.user.isEmpty ? "Riprendiamo la conversazione." : exchange.user
            if let data = exchange.data { asked += "\n\n" + Self.untrusted(data, label: "dati letti per questa risposta") }
            entries.append(.prompt(Transcript.Prompt(segments: [Self.segment(asked)])))
            if !exchange.reply.isEmpty {
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [Self.segment(exchange.reply)])))
            }
        }
        let session = appleResponseModel.session(transcript: Transcript(entries: entries))
        session.prewarm()
        imagesInSession = 0
        // Misura vera (asincrona) per la diagnostica: le istruzioni devono lasciare spazio alla conversazione.
        if history.isEmpty {
            Task { [budget, appleResponseModel] in
                if appleResponseModel == .onDevice,
                   let tokens = try? await Agent.model.tokenCount(for: Instructions(instructions)) {
                    Agent.log("ISTRUZIONI CHAT: \(tokens) token su \(budget.tokens) (\(tokens * 100 / max(1, budget.tokens))%)")
                }
            }
        }
        return session
    }

    static func segment(_ text: String) -> Transcript.Segment { .text(Transcript.TextSegment(content: text)) }

    /// Istruzioni della chat: le stesse per Apple Intelligence e per i modelli alternativi.
    /// Con la finestra di Apple Intelligence (4096 token) restano sotto un terzo: base breve, blocchi opzionali dosati.
    public func chatInstructions() -> String {
        let base = """
        Sei Siri AI+, l'assistente di Ivan sul Mac. Adesso è \(Dates.format(.now)). Rispondi in italiano, chiaro e cordiale.
        Rispondi volentieri alle domande di cultura generale, storia, scienza, consigli, idee e codice con le tue conoscenze, in modo completo quando serve. Sai anche cercare sul web, usare Calendario, Promemoria, Mail, Note, Messaggi e i file dei progetti, creare documenti, fogli, presentazioni e immagini.
        Quando ricevi dati (web, file, strumenti, calcoli già fatti) basati solo su quelli e non inventare. Cita le fonti con [1], [2] solo se ricevi risultati web numerati; altrimenti non scrivere mai numeri tra parentesi quadre.
        \(Self.untrustedRule)
        Resta coerente con quanto già detto nella conversazione e non ripetere ciò che hai già spiegato.
        """
        // Blocchi opzionali: prima con i limiti normali, poi più stretti se la stima supera il tetto.
        for tight in [false, true] {
            var blocks: [String] = []
            let limit = { (normal: Int, strict: Int) in self.budget.scaled(tight ? strict : normal) }
            if let project = work.projectName {
                blocks.append(Self.projectRule(project))
                // I modelli con una finestra grande ricevono le istruzioni complete (AGENTS.md, CLAUDE.md…); Apple Intelligence la sintesi.
                if budget.scale >= 2, let guide = work.guide {
                    let share = Self.instructionShare(of: budget) * 28 / 10
                    let full = guide.instructions(limit: tight ? min(6000, share / 2) : min(30_000, max(2000, share - 3000)))
                    if !full.isEmpty { blocks.append("Istruzioni del progetto, da seguire:\n\(full)") }
                } else if let agents = work.agents, !agents.isEmpty {
                    blocks.append("Istruzioni del progetto (sintesi):\n\(agents.prefix(limit(1000, 600)))")
                }
            }
            if let space = work.spaceName {
                var line = "Spazio attuale: \(space): usa solo calendari, liste, posta e servizi di questo spazio."
                if let extra = work.spaceInstructions, !extra.isEmpty { line += " Indicazioni: \(extra.prefix(limit(600, 300)))" }
                blocks.append(line)
            }
            if let soul = work.soul, !soul.isEmpty { blocks.append("Sei un agente con questa anima (soul.md): seguila.\n\(soul.prefix(limit(800, 450)))") }
            if let inherited, !inherited.isEmpty {
                blocks.append("Questa è una chat figlia: ecco di cosa si parlava nella chat madre (usalo per capire le richieste, senza ripeterlo):\n\(inherited.prefix(limit(900, 500)))")
            }
            if let summary { blocks.append("Riassunto della parte meno recente della conversazione:\n\(summary.prefix(limit(1100, 600)))") }
            let text = ([base] + blocks).joined(separator: "\n")
            if Self.estimatedTokens(text) <= Self.instructionShare(of: budget) { return text }
        }
        // Su Mac dove il modello non è pronto la finestra può risultare minima: tieni prima le regole del progetto.
        if let project = work.projectName, let agents = work.agents, !agents.isEmpty {
            let heading = "\n" + Self.projectRule(project) + "\nIstruzioni del progetto (sintesi):\n"
            let available = max(120, (Self.instructionShare(of: budget) - Self.estimatedTokens(base + heading)) * 2)
            return base + heading + String(agents.prefix(available))
        }
        return base
    }

    /// Stima dei token di un testo italiano (misurata: circa 2,8 caratteri per token, più ~50 di struttura).
    public static func estimatedTokens(_ text: String) -> Int { 50 + text.count * 10 / 28 }

    /// Tetto delle istruzioni: un terzo della finestra (resta spazio per conversazione, dati e risposta).
    static func instructionShare(of budget: ContextBudget) -> Int { budget.tokens / 3 }

    // MARK: - 1. Pianificazione

    enum Action: String, CaseIterable {
        case rispondi, agenda, eventi, promemoria, calendari
        case crea_evento, crea_promemoria, crea_lista_promemoria, elimina_evento, completa_promemoria
        case modifica_evento, modifica_promemoria, elimina_promemoria
        case scrivi_email, crea_documento, crea_foglio, crea_presentazione, piano
        case mail_leggi, note, file, messaggi, crea_nota, invia_messaggio
        case modifica_nota, rispondi_email, inoltra_email
        case genera_immagine, ricorda
        case file_elenca, file_leggi, file_cerca, file_scrivi, file_sposta, file_cartella, file_elimina
        case strumento_esterno, modifica_artefatto
        case cerca_web, leggi_pagina, naviga, segui_link
        case nuova_chat, crea_agente, crea_sito
        case cerca_conversazioni
    }

    struct Plan: CustomStringConvertible {
        var action: Action
        var fields: [String: String]
        subscript(_ key: String) -> String? { fields[key] }
        var description: String { "\(action.rawValue) \(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))" }
    }

    private static let planFields = ["dal", "al", "cerca", "titolo", "inizio", "fine", "scadenza", "luogo", "lista", "id", "argomento",
                                     "destinatari", "percorso", "destinazione", "stile", "strumento", "link"]
    /// Campi impostati solo dalle regole (mai dal modello): `rinomina` distingue la rinomina dallo spostamento.
    static let ruleFields = ["rinomina"]

    /// Azioni disponibili nel contesto attuale: meno opzioni = scelte più affidabili e meno token.
    var availableActions: [Action] {
        Action.allCases.filter { action in
            switch action {
            case .file_elenca, .file_leggi, .file_cerca, .file_scrivi, .file_sposta, .file_cartella, .file_elimina: work.projectRoot != nil
            case .file: work.projectRoot == nil
            case .strumento_esterno: !work.mcpTools.isEmpty
            case .modifica_artefatto: work.artifactKind != nil
            case .cerca_web: work.webEnabled
            case .naviga, .segui_link: work.browserURL != nil
            default: true
            }
        }
    }

    private func planSchema(_ actions: [Action]) -> GenerationSchema {
        var fields: [Field] = [.required("azione", .choice(actions.map(\.rawValue)), "Azione da eseguire")]
        fields += Self.baseFields
        if actions.contains(where: { [.file_leggi, .file_elenca, .file_scrivi, .file_sposta, .file_cartella, .file_elimina].contains($0) }) {
            fields.append(.optional("percorso", .string, "Percorso del file o della cartella nel progetto, es. docs/note.md"))
        }
        if actions.contains(.file_sposta) {
            fields.append(.optional("destinazione", .string, "Cartella di destinazione o nuovo nome del file"))
        }
        if actions.contains(.genera_immagine) {
            fields.append(.optional("stile", .choice(["animazione", "illustrazione", "schizzo"]), "Stile dell'immagine"))
        }
        if actions.contains(.strumento_esterno) {
            fields.append(.optional("strumento", .choice(work.mcpTools.map(\.name)), "Strumento esterno da usare"))
        }
        if actions.contains(.segui_link), !work.browserLinks.isEmpty {
            fields.append(.optional("link", .choice(work.browserLinks), "Link della pagina da aprire"))
        }
        return makeSchema("Piano", fields)
    }

    private static let baseFields: [Field] = [
        .optional("dal", .string, "Inizio del periodo, yyyy-MM-dd"),
        .optional("al", .string, "Fine del periodo, yyyy-MM-dd"),
        .optional("cerca", .string, "Parola da cercare nei titoli"),
        .optional("titolo", .string, "Titolo dell'evento o testo del promemoria, SENZA data, ora o parole come domani"),
        .optional("inizio", .string, "Inizio evento, yyyy-MM-dd HH:mm"),
        .optional("fine", .string, "Fine evento, yyyy-MM-dd HH:mm"),
        .optional("scadenza", .string, "Scadenza promemoria, yyyy-MM-dd HH:mm o yyyy-MM-dd"),
        .optional("luogo", .string, "Luogo dell'evento"),
        .optional("lista", .string, "Nome del calendario o della lista, solo se l'utente lo nomina"),
        .optional("id", .string, "ID come E3 o R2 preso dal contesto precedente"),
        .optional("argomento", .string, "Argomento di email, documento, foglio, presentazione o lista"),
        .optional("destinatari", .string, "Destinatari dell'email citati dall'utente, separati da virgola"),
    ]

    /// Una riga di spiegazione per ogni azione: nel prompt vanno solo quelle ammesse.
    private static let actionHelp: [Action: String] = [
        .rispondi: "rispondi: conversazione, saluti, spiegazioni, consigli e domande di cultura generale che non richiedono dati personali né notizie recenti.",
        .agenda: "agenda: cosa ha da fare in un periodo, eventi e promemoria insieme (\"cosa ho domani\", \"organizza la mia giornata\"). Usa dal e al.",
        .eventi: "eventi: solo eventi del calendario. Usa dal, al, cerca.",
        .promemoria: "promemoria: solo promemoria esistenti. Usa lista e al.",
        .calendari: "calendari: elenco di calendari e liste.",
        .crea_evento: "crea_evento: un nuovo evento. Usa titolo, inizio, fine, luogo, lista.",
        .crea_promemoria: "crea_promemoria: UN promemoria (\"ricordami di…\"). Usa titolo, scadenza, lista.",
        .crea_lista_promemoria: "crea_lista_promemoria: più promemoria su un tema. Usa argomento, lista.",
        .elimina_evento: "elimina_evento: cancellare un evento esistente. Usa id (E…) se è nel contesto.",
        .completa_promemoria: "completa_promemoria: segnare come fatto un promemoria. Usa id (R…) se è nel contesto.",
        .modifica_evento: "modifica_evento: spostare, anticipare, rimandare, rinominare o cambiare luogo o durata di un evento che esiste già (\"sposta la riunione con Marco alle 16\").",
        .modifica_promemoria: "modifica_promemoria: cambiare scadenza, testo, lista o priorità di un promemoria che esiste già.",
        .elimina_promemoria: "elimina_promemoria: cancellare un promemoria che esiste già.",
        .modifica_nota: "modifica_nota: aggiungere testo a una nota che esiste già nell'app Note (\"aggiungi il latte alla nota della spesa\").",
        .rispondi_email: "rispondi_email: rispondere a un'email ricevuta. Usa destinatari con il mittente e argomento con cosa rispondere.",
        .inoltra_email: "inoltra_email: inoltrare un'email ricevuta a un'altra persona. Usa destinatari con chi la riceve.",
        .scrivi_email: "scrivi_email: scrivere o preparare un'email. Usa argomento, destinatari.",
        .crea_documento: "crea_documento: documento, testo, relazione, piano scritto. Usa argomento.",
        .crea_foglio: "crea_foglio: foglio di calcolo, tabella, budget, stime, grafico. Usa argomento.",
        .crea_presentazione: "crea_presentazione: presentazione o slide. Usa argomento.",
        .piano: "piano: richiesta complessa con più azioni insieme (\"organizza il lancio: eventi, email e documento\").",
        .mail_leggi: "mail_leggi: leggere, cercare o riassumere le email ricevute. Usa cerca con mittente o argomento se indicati.",
        .note: "note: leggere o cercare nelle note dell'app Note. Usa cerca con la parola chiave.",
        .crea_nota: "crea_nota: scrivere una nuova nota nell'app Note. Usa titolo e argomento.",
        .messaggi: "messaggi: leggere i messaggi (iMessage/SMS) ricevuti o inviati. Usa destinatari con la persona o cerca.",
        .invia_messaggio: "invia_messaggio: mandare un iMessage o SMS a una persona. Usa destinatari e argomento con il testo.",
        .file: "file: trovare o leggere documenti e file sul Mac. Usa cerca con nome o argomento del file.",
        .genera_immagine: "genera_immagine: disegnare o creare un'immagine. Usa argomento (cosa disegnare) e stile.",
        .ricorda: "ricorda: l'utente chiede di ricordare un'informazione (\"ricordati che…\"). Usa argomento.",
        .cerca_web: "cerca_web: cercare su internet notizie, fatti recenti, prezzi, meteo, risultati, orari, informazioni su aziende, prodotti o persone. Usa cerca con le parole da cercare.",
        .leggi_pagina: "leggi_pagina: leggere o riassumere una pagina web (indirizzo nella richiesta o pagina aperta nel browser o in Safari). Usa argomento con l'indirizzo se c'è.",
        .naviga: "naviga: aprire un sito o fare una ricerca nel browser integrato. Usa argomento con l'indirizzo o le parole da cercare.",
        .segui_link: "segui_link: aprire un link della pagina aperta nel browser. Usa link.",
        .crea_sito: "crea_sito: creare una pagina web, un sito o una landing page (HTML e CSS). Usa argomento.",
        .crea_agente: "crea_agente: creare un agente che lavora da solo su un obiettivo, anche a orari fissi (\"ogni mattina fammi la rassegna stampa\").",
        .cerca_conversazioni: "cerca_conversazioni: cercare nelle conversazioni passate cosa si era detto o deciso. Usa cerca con le parole chiave.",
        .nuova_chat: "nuova_chat: aprire una nuova chat o conversazione su un argomento, anche in un progetto. Usa argomento e lista con il nome del progetto.",
    ]

    private func plannerInstructions(_ actions: [Action], compact: Bool = false) -> String {
        let help = actions.compactMap { Self.actionHelp[$0] }.map { "- \($0)" }.joined(separator: "\n")
        return """
        Trasforma la richiesta dell'utente in UNA azione. Scegli rispondi se nessuna azione serve davvero.
        Adesso è \(Dates.format(.now)). Prossimi giorni:
        \(Dates.upcomingDays(14))

        Azioni:
        \(help)
        \(workInstructions(actions, compact: compact))
        Date come yyyy-MM-dd o yyyy-MM-dd HH:mm usando la lista dei prossimi giorni. "Questa settimana" va da oggi a domenica.
        Compila solo i campi pertinenti.
        """
    }

    /// Caratteri oltre i quali il prompt del pianificatore rischia di superare la finestra (schema e risposta compresi):
    /// 8.500 con 4096 token, in proporzione con finestre diverse.
    static var plannerCharacterBudget: Int { 8_500 * max(2048, Agent.model.contextSize) / 4096 }

    func makePlan(for prompt: String, allowed: Set<Action>, compact: Bool = false) async -> Plan {
        let actions = availableActions.filter { allowed.contains($0) || $0 == .rispondi }
        var instructions = plannerInstructions(actions, compact: compact)
        var request = "Richiesta: \(prompt)"
        let contextLimit = compact ? 500 : 1500
        if !context.isEmpty {
            request = "Contesto precedente:\n\(context.prefix(contextLimit))\n\n\(request)"
        }
        if !compact, let recent = recentConversation(exchanges: 2, user: 260, reply: 260) { request = "Conversazione recente:\n\(recent)\n\n\(request)" }

        if let screen = screenPlannerNote(compact: compact) { request = "\(screen)\n\n\(request)" }
        // Troppo lungo per la finestra del modello: si riparte subito con la versione compatta.
        if !compact, instructions.count + request.count > Self.plannerCharacterBudget {
            Agent.log("PIANIFICATORE: prompt di \(instructions.count + request.count) caratteri, uso la versione compatta")
            return await makePlan(for: prompt, allowed: allowed, compact: true)
        }
        if compact, instructions.count + request.count > Self.plannerCharacterBudget {
            instructions = String(instructions.prefix(max(2000, Self.plannerCharacterBudget - request.count)))
        }
        let planner = LanguageModelSession(model: Agent.model, instructions: instructions)
        do {
            // Un piano è breve: il tetto evita che il modello continui a scrivere fino a riempire la finestra (visto: 60 secondi persi).
            let response = try await planner.respond(to: request, schema: planSchema(actions),
                                                     options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 320))
            let content = response.content
            let action = content.string("azione").flatMap(Action.init(rawValue:)) ?? .rispondi
            var fields: [String: String] = [:]
            for key in Self.planFields { if let value = content.string(key) { fields[key] = value } }
            return Plan(action: action, fields: fields)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize where !compact {
            Agent.log("PIANIFICATORE: contesto pieno, riprovo in versione compatta")
            return await makePlan(for: prompt, allowed: allowed, compact: true)
        } catch {
            Agent.log("ERRORE PIANIFICATORE: \(error)")
            return Plan(action: .rispondi, fields: [:])
        }
    }

    // MARK: - 2. Letture

    private func buildAgenda(_ plan: Plan, events: Bool, reminders: Bool) async -> Agenda {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let from = Dates.parse(plan["dal"]).map { cal.startOfDay(for: $0.date) } ?? today
        var to = Dates.parse(plan["al"]).map { cal.startOfDay(for: $0.date) } ?? from
        if to < from { to = from }
        let endExclusive = cal.date(byAdding: .day, value: 1, to: to)!

        var eventItems = events ? Overview.events(from: from, to: endExclusive) : []
        if let query = plan["cerca"] { eventItems = eventItems.filter { $0.title.localizedCaseInsensitiveContains(query) } }

        let allReminders = plan.action == .promemoria && plan["al"] == nil
        var inRange: [ReminderItem] = []
        var overdue: [ReminderItem] = []
        if reminders {
            let open = await Overview.openReminders(limit: 300, list: plan["lista"])
            if allReminders {
                inRange = open
            } else {
                inRange = open.filter { guard let due = $0.due else { return false }; return due >= from && due < endExclusive }
                if from <= today { overdue = open.filter { ($0.due ?? .distantFuture) < today } }
            }
        }

        let dayFormat = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).locale(Dates.locale)
        var title: String
        if allReminders {
            title = plan["lista"].map { "Promemoria · \($0)" } ?? "Promemoria da fare"
        } else if from == to {
            title = from.formatted(dayFormat).capitalized
            if from == today { title = "Oggi · " + title } else if from == cal.date(byAdding: .day, value: 1, to: today) { title = "Domani · " + title }
        } else {
            title = "\(from.formatted(dayFormat).capitalized) – \(to.formatted(dayFormat))"
        }
        return Agenda(title: title, showsEvents: events, showsReminders: reminders,
                      events: eventItems, reminders: Array(inRange.prefix(30)), overdue: Array(overdue.prefix(15)))
    }

    /// Testo per il modello, con ID brevi registrati per le azioni successive.
    private func describe(_ agenda: Agenda) -> String {
        if agenda.showsEvents { recentEvents = agenda.events }
        if agenda.showsReminders { recentReminders = agenda.reminders + agenda.overdue }
        var parts: [String] = []
        if agenda.showsEvents {
            let lines = agenda.events.map { e -> String in
                let id = ids.register(event: e.identifier, start: e.start)
                let when = e.isAllDay ? "\(Dates.format(e.start, time: false)), tutto il giorno"
                                      : "\(Dates.format(e.start))–\(Dates.format(e.end).suffix(5))"
                return "[\(id)] «\(e.title)» (\(when), calendario \(e.calendar))"
            }
            parts.append("EVENTI:\n" + (lines.isEmpty ? "nessuno" : lines.joined(separator: "\n")))
        }
        if agenda.showsReminders {
            func line(_ r: ReminderItem) -> String {
                let id = ids.register(reminder: r.id)
                let due = r.due.map { ", scade \(Dates.format($0, time: r.dueHasTime))" } ?? ""
                return "[\(id)] «\(r.title)» (lista \(r.list)\(due))"
            }
            parts.append("PROMEMORIA:\n" + (agenda.reminders.isEmpty ? "nessuno" : agenda.reminders.map(line).joined(separator: "\n")))
            if !agenda.overdue.isEmpty {
                parts.append("ARRETRATI (scaduti prima di oggi):\n" + agenda.overdue.map(line).joined(separator: "\n"))
            }
        }
        return "\(agenda.title)\n" + parts.joined(separator: "\n\n")
    }

    /// Sovrapposizioni e tempo libero di una giornata, calcolati dall'app: il modello riporta, non fa i conti.
    static func dayAnalysis(_ events: [EventItem], prompt: String) -> String? {
        let calendar = Calendar.current
        let timed = events.filter { !$0.isAllDay }.sorted { $0.start < $1.start }
        guard let first = timed.first, timed.allSatisfy({ calendar.isDate($0.start, inSameDayAs: first.start) }) else { return nil }
        let day = calendar.startOfDay(for: first.start)
        func minute(_ date: Date) -> Int { min(1440, max(0, Int(date.timeIntervalSince(day) / 60))) }
        // Giornata lavorativa 9–18, oppure la finestra chiesta ("tra le 8 e le 14").
        let window = Calculations.window(in: prompt.lowercased()) ?? Calculations.Span(start: 9 * 60, end: 18 * 60)
        let analysis = Calculations.analyze(timed.map { Calculations.Span(start: minute($0.start), end: minute($0.end)) }, window: window)
        var lines = ["ANALISI DELLA GIORNATA (calcolata dall'app, fascia \(window.label)):"]
        for i in timed.indices {
            for j in timed.indices where j > i && timed[j].start < timed[i].end {
                let end = min(timed[i].end, timed[j].end)
                lines.append("- «\(timed[i].title)» e «\(timed[j].title)» si sovrappongono (\(Calculations.clock(minute(timed[j].start)))–\(Calculations.clock(minute(end)))).")
            }
        }
        let busy = analysis.busy.map(\.minutes).reduce(0, +)
        let free = analysis.free.map(\.minutes).reduce(0, +)
        lines.append("- Occupato: \(Calculations.duration(busy)) in tutto.")
        lines.append("- Libero nella fascia \(window.label): " + (analysis.free.isEmpty ? "niente." :
            "\(Calculations.duration(free)) (" + analysis.free.map { "\($0.label), \(Calculations.duration($0.minutes))" }.joined(separator: "; ") + ")."))
        return lines.joined(separator: "\n")
    }

    // MARK: - 3. Contenuti generati

    func writer(_ role: String) -> LanguageModelSession {
        LanguageModelSession(model: Agent.model, instructions: """
        \(role) Scrivi in italiano, con contenuti concreti e plausibili, senza segnaposto tra parentesi.
        Adesso è \(Dates.format(.now)). Prossimi giorni:
        \(Dates.upcomingDays(14))
        """)
    }

    /// Scrive un documento su un argomento passando le parti già pronte a `onUpdate` (titolo, poi sezione per sezione).
    public func streamDocument(topic: String, onUpdate: (DocumentDraft) -> Void) async throws -> DocumentDraft {
        // Con il modello scelto: Markdown in streaming, il documento si riempie mentre scrive.
        if textWriter != nil, let written = await withoutActuallyEscaping(onUpdate, do: { update in
            await writtenDocument(topic: topic) { update($0) }
        }) { return written }
        var draft = DocumentDraft(title: "", subtitle: "", sections: [])
        let session = writer("Sei un redattore esperto di documenti di lavoro.")
        for try await snapshot in session.streamResponse(to: "Scrivi un documento su: \(topic)", schema: Self.documentSchema) {
            let content = snapshot.content
            let sections = content.objects("sezioni").map { DocumentDraft.Section(title: $0.string("titolo") ?? "", body: $0.string("testo") ?? "") }
            draft = DocumentDraft(title: content.string("titolo") ?? "", subtitle: content.string("sottotitolo") ?? "", sections: sections)
            onUpdate(draft)
        }
        return draft
    }

    private static let documentSchema = makeSchema("Documento", [
        .required("titolo", .string, "Titolo del documento"),
        .required("sottotitolo", .string, "Sottotitolo di una riga"),
        .required("sezioni", .array(.object("Sezione", [
            .required("titolo", .string, "Titolo della sezione"),
            .required("testo", .string, "Testo della sezione, da 2 a 4 frasi"),
        ]), min: 3, max: 6), "Sezioni del documento"),
    ])

    /// Documento scritto dal modello scelto in Markdown (nil con Apple Intelligence o se non risponde).
    func writtenDocument(topic: String, onUpdate: @escaping @MainActor (DocumentDraft) -> Void = { _ in }) async -> DocumentDraft? {
        let request = """
        Scrivi un documento su: \(topic)

        Formato Markdown: «# Titolo» sulla prima riga, poi un sottotitolo di una riga, poi da 3 a 6 sezioni «## Titolo della sezione» \
        con 2-4 frasi ciascuna. Niente commenti prima o dopo.
        """
        guard let text = await externalText("Sei un redattore esperto di documenti di lavoro.", request, partial: { onUpdate(Self.documentDraft(markdown: $0)) }) else { return nil }
        let draft = Self.documentDraft(markdown: Self.cleanWritten(text))
        guard !draft.sections.isEmpty else { return nil }
        onUpdate(draft)
        return draft
    }

    /// "# Titolo", una riga di sottotitolo, "## Sezione" e testo → documento.
    static func documentDraft(markdown: String) -> DocumentDraft {
        var lines = markdown.components(separatedBy: .newlines)
        var title = ""
        if let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ") }) {
            title = lines[first].trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
            lines.remove(at: first)
        }
        var draft = document(title: title, markdown: lines.joined(separator: "\n"))
        draft.title = title.isEmpty ? draft.title : title
        draft.subtitle = draft.subtitle.replacingOccurrences(of: #"^[*_]+|[*_]+$"#, with: "", options: .regularExpression)
        return draft
    }

    public func generateDocument(topic: String) async throws -> DocumentDraft {
        if let written = await writtenDocument(topic: topic) { return written }
        let content = try await writer("Sei un redattore esperto di documenti di lavoro.")
            .respond(to: "Scrivi un documento su: \(topic)", schema: Self.documentSchema).content
        return DocumentDraft(
            title: content.string("titolo") ?? "Documento",
            subtitle: content.string("sottotitolo") ?? "",
            sections: content.objects("sezioni").map {
                .init(title: $0.string("titolo") ?? "", body: $0.string("testo") ?? "")
            }
        )
    }

    private static let sheetSchema = makeSchema("Foglio", [
        .required("titolo", .string, "Titolo del foglio"),
        .required("colonne", .array(.string, min: 2, max: 3), "Periodi o scenari confrontati, per esempio «Ottobre», «Novembre» o «Minimo», «Massimo». Solo colonne numeriche"),
        .required("righe", .array(.object("Riga", [
            .required("voce", .string, "Nome della voce"),
            .required("valori", .array(.double, min: 2, max: 4), "Un valore numerico per ogni colonna, senza simboli"),
        ]), min: 3, max: 8), "Righe della tabella"),
    ])

    public func generateSheet(topic: String) async throws -> SheetDraft {
        let role = "Sei un analista che prepara fogli di calcolo chiari e realistici."
        let request = "Prepara una tabella per: \(topic)"
        var title: String
        var columns: [String]
        var rawRows: [(label: String, values: [Double])]
        if let json = await composeJSON(role, request, fields: "\"titolo\": titolo del foglio; \"colonne\": da 2 a 3 periodi o scenari confrontati (solo colonne numeriche); \"righe\": da 3 a 8 oggetti {\"voce\": nome, \"valori\": un numero per colonna, senza simboli}"),
           !json.objects("righe").isEmpty {
            title = json.text("titolo") ?? "Foglio"
            columns = json.texts("colonne")
            rawRows = json.objects("righe").map { ($0.text("voce") ?? "Voce", $0.numbers("valori")) }
        } else {
            let content = try await writer(role).respond(to: request, schema: Self.sheetSchema).content
            title = content.string("titolo") ?? "Foglio"
            columns = content.strings("colonne")
            rawRows = content.objects("righe").map { ($0.string("voce") ?? "Voce", $0.doubles("valori")) }
        }
        let width = max(columns.count, 2)
        let rows = rawRows.map { row -> SheetDraft.Row in
            var values = row.values
            if values.count < width { values += Array(repeating: 0, count: width - values.count) }
            return .init(label: row.label, values: Array(values.prefix(width)))
        }
        var sheet = SheetDraft(title: title, columns: columns.count >= 2 ? Array(columns.prefix(width)) : ["Colonna 1", "Colonna 2"], rows: rows)
        // Toglie le colonne rimaste tutte a zero (il modello a volte aggiunge colonne non numeriche).
        let empty = sheet.columns.indices.filter { i in sheet.rows.allSatisfy { !$0.values.indices.contains(i) || $0.values[i] == 0 } }
        if sheet.columns.count - empty.count >= 1 {
            for i in empty.reversed() {
                sheet.columns.remove(at: i)
                for r in sheet.rows.indices where sheet.rows[r].values.indices.contains(i) { sheet.rows[r].values.remove(at: i) }
            }
        }
        return sheet
    }

    private static let deckSchema = makeSchema("Presentazione", [
        .required("titolo", .string, "Titolo della presentazione"),
        .required("sottotitolo", .string, "Sottotitolo della slide iniziale"),
        .required("slide", .array(.object("Slide", [
            .required("titolo", .string, "Titolo della slide"),
            .required("punti", .array(.string, min: 2, max: 4), "Punti elenco brevi"),
        ]), min: 3, max: 6), "Slide dopo quella iniziale"),
    ])

    public func generateDeck(topic: String) async throws -> DeckDraft {
        if let json = await composeJSON("Sei un esperto di presentazioni aziendali sintetiche.", "Prepara una presentazione su: \(topic)",
                                        fields: "\"titolo\": titolo della presentazione; \"sottotitolo\": sottotitolo della slide iniziale; \"slide\": da 3 a 6 oggetti {\"titolo\": titolo della slide, \"punti\": da 2 a 4 punti elenco brevi}"),
           !json.objects("slide").isEmpty {
            return DeckDraft(title: json.text("titolo") ?? "Presentazione", subtitle: json.text("sottotitolo") ?? "",
                             slides: json.objects("slide").map { .init(title: $0.text("titolo") ?? "", bullets: Array($0.texts("punti").prefix(5)).map { $0.hasSuffix("...") ? $0 : $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }) })
        }
        let content = try await writer("Sei un esperto di presentazioni aziendali sintetiche.")
            .respond(to: "Prepara una presentazione su: \(topic)", schema: Self.deckSchema).content
        return DeckDraft(
            title: content.string("titolo") ?? "Presentazione",
            subtitle: content.string("sottotitolo") ?? "",
            slides: content.objects("slide").map { .init(title: $0.string("titolo") ?? "", bullets: $0.strings("punti")) }
        )
    }

    private static let mailSchema = makeSchema("Email", [
        .required("destinatari", .array(.string, max: 6), "Nomi o indirizzi dei destinatari citati dall'utente"),
        .required("oggetto", .string, "Oggetto dell'email"),
        .required("corpo", .string, "Testo completo dell'email con saluto iniziale e chiusura firmata Ivan"),
    ])

    public func generateMail(topic: String, recipients: String?) async throws -> MailDraft {
        let role = "Sei l'assistente di Ivan e scrivi email professionali e cordiali. Non inventare date, orari, luoghi, numeri o impegni che l'utente non ha indicato: resta generico dove mancano i dettagli."
        if let json = await composeJSON(role, "Scrivi un'email su: \(topic)" + (recipients.map { "\nDestinatari: \($0)" } ?? ""),
                                        fields: "\"destinatari\": nomi o indirizzi citati dall'utente; \"oggetto\": oggetto dell'email; \"corpo\": testo completo con saluto iniziale e chiusura firmata Ivan"),
           let body = json.text("corpo") {
            var names = json.texts("destinatari")
            if names.isEmpty, let recipients { names = recipients.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            return MailDraft(recipients: names, subject: json.text("oggetto") ?? "", body: body)
        }
        let content = try await writer(role)
            .respond(to: "Scrivi un'email su: \(topic)" + (recipients.map { "\nDestinatari: \($0)" } ?? ""),
                     schema: Self.mailSchema).content
        var names = content.strings("destinatari")
        if names.isEmpty, let recipients {
            names = recipients.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return MailDraft(recipients: names, subject: content.string("oggetto") ?? "", body: content.string("corpo") ?? "")
    }

    private static let remindersSchema = makeSchema("Promemoria", [
        .required("elementi", .array(.object("Elemento", [
            .required("titolo", .string, "Cosa fare, breve"),
            .optional("scadenza", .string, "Scadenza, yyyy-MM-dd"),
        ]), min: 3, max: 8), "Promemoria da creare, in ordine cronologico"),
    ])

    public func generateReminders(topic: String) async throws -> [ReminderDraft] {
        if let json = await composeJSON("Sei un project manager che scompone gli obiettivi in attività concrete.", "Elenca i promemoria per: \(topic)",
                                        fields: "\"elementi\": da 3 a 8 oggetti in ordine cronologico {\"titolo\": cosa fare, breve; \"scadenza\": yyyy-MM-dd se serve}"),
           !json.objects("elementi").isEmpty {
            return json.objects("elementi").compactMap { item in
                guard let title = item.text("titolo") else { return nil }
                let due = Dates.parse(item.text("scadenza"))
                return ReminderDraft(title: title, due: due?.date, dueHasTime: due?.hasTime ?? false)
            }
        }
        let content = try await writer("Sei un project manager che scompone gli obiettivi in attività concrete.")
            .respond(to: "Elenca i promemoria per: \(topic)", schema: Self.remindersSchema).content
        return content.objects("elementi").compactMap { item in
            guard let title = item.string("titolo") else { return nil }
            let due = Dates.parse(item.string("scadenza"))
            return ReminderDraft(title: title, due: due?.date, dueHasTime: due?.hasTime ?? false)
        }
    }

    private static let planDraftSchema = makeSchema("PianoAzioni", [
        .required("riepilogo", .string, "Una frase che riassume il piano"),
        .required("passi", .array(.object("Passo", [
            .required("tipo", .choice(PlanDraft.Kind.allCases.map(\.rawValue)), "Tipo di azione"),
            .required("titolo", .string, "Titolo dell'evento, promemoria, email o file"),
            .optional("quando", .string, "Data e ora, yyyy-MM-dd HH:mm, solo per eventi e promemoria"),
            .required("dettagli", .string, "Cosa verrà fatto, in una frase"),
        ]), min: 2, max: 6), "Passi del piano, nell'ordine di esecuzione"),
    ])

    public func generatePlan(goal: String) async throws -> PlanDraft {
        let content = try await writer("Sei un assistente che trasforma un obiettivo in un piano di azioni su calendario, promemoria, email e documenti.")
            .respond(to: "Obiettivo: \(goal)", schema: Self.planDraftSchema).content
        let steps = content.objects("passi").compactMap { step -> PlanDraft.Step? in
            guard let kind = step.string("tipo").flatMap(PlanDraft.Kind.init(rawValue:)) else { return nil }
            return .init(kind: kind, title: step.string("titolo") ?? kind.rawValue.capitalized,
                         when: step.string("quando"), detail: step.string("dettagli") ?? "")
        }
        return PlanDraft(goal: goal, summary: content.string("riepilogo") ?? "Ecco il piano.", steps: steps)
    }
}
