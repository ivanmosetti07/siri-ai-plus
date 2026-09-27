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
    /// Skill private del Genius che sta chattando o eseguendo una programmazione.
    public var agentID: UUID?
    /// Progetto reale per cercare le skill, quando `projectRoot` è un'area virtuale del Genius.
    public var skillProjectRoot: URL?
    /// Compito stabile di una singola esecuzione: la stessa skill guida piano, passi e sintesi.
    public var skillTask: String?
    /// Spazio in uso (Personale, Lavoro, Programmazioni) e le sue indicazioni.
    public var spaceName: String?
    public var spaceInstructions: String?
    public var artifactKind: String?
    public var artifactTitle: String?
    public var artifactSummary: String?
    /// Testo completo di ciò che è aperto (per le domande: "riassumi questo documento").
    public var artifactText: String?
    /// Solo Apple Intelligence può ricevere l'intero documento senza un'anteprima di invio esterno.
    public var fullArtifactContextOnApple = false
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
        case .move: (from as NSString).deletingLastPathComponent == (to as NSString).deletingLastPathComponent
            ? Language.t("Rinomina", "Rename") : Language.t("Sposta", "Move")
        case .folder: Language.t("Nuova cartella", "New folder")
        case .trash: Language.t("Sposta nel Cestino", "Move to Trash")
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
    /// Lingua della conversazione: vale per i messaggi brevi o incerti («ok», «il secondo»).
    public var language: Language = .system

    /// Lingua di una nuova richiesta, riconosciuta dal testo (con quella della conversazione come riserva).
    public func language(for prompt: String) -> Language {
        language = Language.detect(prompt, fallback: language)
        return language
    }

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
        // Chi avvia la richiesta (app, valutazioni) ha già scelto la lingua; i sub-agent ereditano quella della richiesta.
        if Language.scoped != nil { return await handleRequest(rawPrompt, enabled: enabled, picked: picked, status: status) }
        return await Language.$scoped.withValue(language(for: rawPrompt)) {
            await handleRequest(rawPrompt, enabled: enabled, picked: picked, status: status)
        }
    }

    private func handleRequest(_ rawPrompt: String, enabled: Set<SourceKind>, picked: Set<SourceKind>,
                               status: @escaping @MainActor (String) -> Void) async -> Outcome {
        status(Language.t("Capisco la richiesta…", "Understanding your request…"))
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
        if let exact = Self.literalAnswer(rawPrompt) {
            lastAction = .rispondi
            lastRequest = rawPrompt
            return .message(exact)
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
            ? await { status(Language.t("Scelgo gli strumenti…", "Choosing the tools…")); return await routeTools(for: Self.withoutQuotes(prompt), catalog: familyCatalog(), hints: familyHints(for: prompt)) }()
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
        let english = Language.isEnglish
        let explicitWeb = ["cerca", "internet", "online", "sul web", "google"] + (english ? ["search", "on the web", "look up"] : [])
        if !work.images.isEmpty, plan.action == .genera_immagine,
           !(["disegna", "genera", "crea un'immagine", "crea una immagine", "illustrazione", "fammi un'immagine"]
             + (english ? ["draw", "generate", "create an image", "make an image", "illustration", "make me a picture"] : [])).contains(where: firstPart.lowercased().contains) {
            plan.action = .rispondi
        }
        if !work.images.isEmpty, plan.action == .cerca_web, !explicitWeb.contains(where: firstPart.lowercased().contains) {
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
           prompt.hasSuffix("?") || (["chi ", "quanto ", "quanti ", "quando ", "dove ", "qual ", "quale ", "cosa succede", "come sta"]
            + (english ? ["who ", "how much", "how many", "when ", "where ", "which ", "what is the", "what's the", "what happened", "how is"] : []))
            .contains(where: prompt.lowercased().hasPrefix) {
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
           !(["cerca su", "sul web", "internet", "online", "google", "in rete", "sul mac", "nel mac", "finder", "spotlight"]
             + (english ? ["search the", "on the web", "on my mac", "on the mac"] : [])).contains(where: firstPart.lowercased().contains),
           projectAnswers(firstPart) {
            Agent.log("PROGETTO: \(plan.action.rawValue) → rispondi con i file del progetto")
            plan = Plan(action: .rispondi, fields: [:])
        }
        // «Parliamo del lancio…», «ti dico che…»: l'utente racconta, non chiede di cercare sul web.
        if plan.action == .cerca_web,
           firstPart.lowercased().range(of: #"^(?:allora\s+|ok\s+|dunque\s+)?(?:parliamo|parlo|discutiamo|ragioniamo|ti dico|ti racconto|sappi|tieni presente|considera)\b"#, options: .regularExpression) != nil
            || (english && firstPart.lowercased().range(of: #"^(?:so\s+|ok\s+|okay\s+)?(?:let's talk|let me tell you|i'm telling you|let's discuss|let's think|keep in mind|consider)\b"#, options: .regularExpression) != nil),
           !(["cerca su", "sul web", "internet", "online", "google", "in rete"] + (english ? ["search the", "on the web"] : [])).contains(where: firstPart.lowercased().contains) {
            plan = Plan(action: .rispondi, fields: [:])
        }
        // Chat figlia: «quando esce il sito?» parla di ciò che si diceva nella madre, non di qualcosa da cercare sul web.
        if plan.action == .cerca_web, let inherited, !inherited.isEmpty,
           !(["cerca su", "sul web", "internet", "online", "google", "in rete", "notizie"] + (english ? ["search the", "on the web", "news"] : []))
            .contains(where: firstPart.lowercased().contains),
           Self.significant(MemoryStore.keywords(firstPart)).intersection(Self.significant(MemoryStore.keywords(inherited))).count >= 2 {
            Agent.log("CHAT FIGLIA: cerca_web → rispondi con il contesto della madre")
            plan = Plan(action: .rispondi, fields: [:])
        }
        // Un sub-agent con un passo di ricerca non deve rispondere a memoria.
        if isSubAgent, plan.action == .rispondi, work.webEnabled,
           (["cerca", "trova", "ricerca", "raccogli", "recupera", "verifica"]
            + (english ? ["search", "find", "research", "collect", "gather", "look up", "check", "verify", "retrieve"] : []))
            .contains(where: { prompt.lowercased().hasPrefix($0) }) {
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
            status(Language.t("Ragiono sul compito…", "Thinking about the task…"))
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
                // Gli orari espliciti sono già stati calcolati in `turnFacts`. Per una domanda sul
                // tempo libero mostra il risultato dell'app: il modello piccolo può alterare il
                // totale anche quando riceve il conto esatto nel contesto.
                let lower = prompt.lowercased()
                let asksFreeTime = lower.contains("ore libere") || lower.contains("tempo libero")
                    || (Language.isEnglish && ["free time", "free hours", "hours free", "time free", "time off"].contains(where: lower.contains))
                if Calculations.hasExplicitSchedule(prompt), asksFreeTime,
                   turnFacts.contains(where: { $0.hasPrefix("Tempo libero tra ") || $0.hasPrefix("Free time between ") }) {
                    return .message(turnFacts.joined(separator: "\n"))
                }
                // Problemi, logica e scelte con vincoli: prima la catena di pensieri (sessione a parte), poi la risposta che la segue.
                // Se i conti li hanno già fatti le regole dell'app (orari, date, giorni) il risultato è quello: un ragionamento
                // in più rischia solo di ricalcolarlo male.
                let solvedByRules = !turnFacts.isEmpty && (["che giorno", "che data", "a che ora", "che ore", "quando", "quanti giorni", "quante settimane",
                                                              "quanti mesi", "entro", "quanto manca", "mancano"]
                                                             + (Language.isEnglish ? ["what day", "what date", "what time", "when", "how many days", "how many weeks",
                                                                                      "how many months", "by when", "how long until", "until", "how long ago"] : []))
                    .contains(where: prompt.lowercased().contains)
                if reasonsBeforeAnswering, !solvedByRules, !Self.isTextTask(prompt), responseStyle != .creative, Self.needsReasoning(prompt) {
                    status(Language.t("Ragiono passo per passo…", "Reasoning step by step…"))
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
                status(Language.t("Cerco nelle conversazioni passate…", "Searching past conversations…"))
                let query = plan["cerca"] ?? prompt
                let hits = ConversationIndex.shared.search(query, limit: budget.scale >= 2 ? 10 : 6, excluding: work.conversationID)
                guard !hits.isEmpty else { return .message(Language.t("Non trovo conversazioni passate su «\(query)».", "I can't find past conversations about «\(query)».")) }
                let data = hits.map { "- «\($0.title)» (\(Dates.format($0.date, time: false))): \($0.snippet)" }.joined(separator: "\n")
                return .reply(prompt: grounded(prompt, data, label: "conversazioni passate"))

            case .crea_sito:
                status(Language.t("Scrivo la pagina web…", "Writing the web page…"))
                return .website(try await generateWebsite(topic: prompt))

            case .crea_agente:
                status(Language.t("Configuro il Genius…", "Setting up the Genius…"))
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
                    return .message(Language.t("Come vuoi chiamare l'evento?", "What do you want to call the event?"))
                }
                // Il modello a volte mette l'orario in dal/al invece che in inizio/fine.
                guard let start = Dates.parse(plan["inizio"]) ?? Dates.parse(plan["dal"]) ?? Dates.parse(plan["scadenza"]) else {
                    remember("Stavo creando l'evento «\(title)»: mancano data e ora.")
                    return .message(Language.t("Per quando vuoi fissare «\(title)»?", "When do you want to schedule «\(title)»?"))
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
                guard let title = plan["titolo"] else { return .message(Language.t("Cosa vuoi che ti ricordi?", "What do you want me to remind you about?")) }
                let due = Dates.parse(plan["scadenza"]) ?? Dates.parse(plan["al"]) ?? Dates.parse(plan["inizio"])
                return .reminderDrafts([ReminderDraft(title: title, due: due?.date, dueHasTime: due?.hasTime ?? false)],
                                       list: reminderList(plan["lista"]))

            case .crea_lista_promemoria:
                if let blocked = check(.reminders) { return blocked }
                status(Language.t("Preparo i promemoria…", "Preparing the reminders…"))
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
                status(Language.t("Scrivo l'email…", "Writing the email…"))
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
                    status(Language.t("Scrivo il documento…", "Writing the document…"))
                    return .document(try await generateDocument(topic: plan["argomento"] ?? prompt))
                }
                return .writeDocument(topic: plan["argomento"] ?? prompt)

            case .crea_foglio:
                status(Language.t("Preparo il foglio…", "Preparing the spreadsheet…"))
                return .sheet(try await generateSheet(topic: plan["argomento"] ?? prompt))

            case .crea_presentazione:
                status(Language.t("Preparo le slide…", "Preparing the slides…"))
                return .deck(try await generateDeck(topic: plan["argomento"] ?? prompt))

            case .piano:
                status(Language.t("Preparo il piano…", "Preparing the plan…"))
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
            return .message(Language.t("Risposta interrotta.", "Answer interrupted."))
        } catch {
            Agent.log("ERRORE GENERAZIONE: \(error)")
            lastError = error.localizedDescription
            return .message(Language.t("Non sono riuscito a completare la richiesta con il modello locale. Prova a riformularla in modo più semplice.", "I couldn't complete the request with the local model. Try rephrasing it more simply."))
        }
    }

    /// Regole deterministiche dove il modello piccolo sbaglia spesso.
    func applyRules(to plan: inout Plan, prompt rawPrompt: String, candidates: Set<Action> = Set(Action.allCases)) {
        // Stessa stringa per la ricerca e il taglio: con spazi iniziali gli indici non corrispondevano.
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = prompt.lowercased()
        let english = Language.isEnglish
        let questionStart = #"^(?:and\s+)?(?:where|how|which|why|what|what's|who|when|whose)\b"#
        // "Ricordati che…" è memoria; "ricordami di…" resta un promemoria.
        if let range = lower.range(of: #"^(ricordati( che| di)?|ricorda che|tieni a mente( che)?|memorizza( che)?|(segnati|annotati|appuntati)( che| questa cosa)?( per dopo)?:?)\s*"#, options: .regularExpression),
           !lower.hasPrefix("ricordati di ") {
            plan.action = .ricorda
            let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
            plan.fields["argomento"] = prompt.count == lower.count ? String(prompt.dropFirst(offset)) : String(lower[range.upperBound...])
            return
        }
        // "Remember that…" è memoria; "remember to…" resta un promemoria.
        if english, let range = lower.range(of: #"^(please\s+)?(remember( that)?|keep in mind( that)?|note that|make a note( that)?|memori[sz]e( that)?|don't forget that|for future reference)\s*:?\s*"#, options: .regularExpression),
           !lower.hasPrefix("remember to "), !lower.hasPrefix("please remember to ") {
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
        if Self.isAnswerOnlyInstruction(prompt) {
            plan.action = .rispondi
            plan.fields = [:]
            return
        }
        // «Dove devo salvare un appunto?», «come chiamo il report?»: domande, non richieste di creare qualcosa.
        let creations: Set<Action> = [.crea_nota, .crea_documento, .crea_foglio, .crea_presentazione, .crea_sito, .crea_lista_promemoria, .file_scrivi]
        if creations.contains(plan.action), lower.hasSuffix("?"),
           lower.range(of: #"^(?:e\s+)?(?:dove|come|quale|quali|perch[eé]|cosa|che cosa|cos'|chi|quando|quanto|quanti)\b"#, options: .regularExpression) != nil
            || (english && lower.range(of: questionStart, options: .regularExpression) != nil) {
            plan.action = .rispondi
            plan.fields = [:]
            return
        }
        // «Cosa ho fatto oggi?», «che cosa è stato fatto?»: una domanda, non «segna come fatto».
        if plan.action == .completa_promemoria,
           lower.hasSuffix("?") || lower.range(of: #"^(?:e\s+)?(?:cosa|che cosa|cos'|quali|quanto|quanti|chi|come|quando|dove)\b"#, options: .regularExpression) != nil
            || (english && lower.range(of: questionStart, options: .regularExpression) != nil) {
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
        if lower.range(of: #"^(?:per favore |puoi )?(?:crea|creami|fai|fammi|scrivi|scrivimi|prepara|preparami|apri|aggiungi)\s+(?:una|la)\s+(?:nuova\s+)?nota\b"#, options: .regularExpression) != nil
            || (english && lower.range(of: #"^(?:please\s+|can you\s+|could you\s+)?(?:create|make|write|add|start|open|take)\s+(?:me\s+)?(?:a|the)\s+(?:new\s+)?note\b"#, options: .regularExpression) != nil) {
            plan.action = .crea_nota
            return
        }
        // Domande su orari o date scritti nella richiesta ("ho riunioni 9-10:30 e 10-11: quanto tempo libero ho?",
        // "che giorno sarà il 25 dicembre?"): rispondono i calcoli dell'app, senza calendario né web.
        if [.agenda, .eventi, .promemoria, .cerca_web, .crea_evento].contains(plan.action), Self.asksComputation(prompt) {
            plan.action = .rispondi
            return
        }
        // Conti con tutti i dati nella domanda ("89,90 € IVA inclusa al 22%: quanto senza IVA?"): niente ricerca sul web né nei file.
        let fileSearch: Set<Action> = [.file_cerca, .file]
        if plan.action == .cerca_web || (fileSearch.contains(plan.action)
                                         && !["file", "document", "cartell", "progett", "folder", "project", ".pdf", ".md", ".txt"].contains(where: lower.contains)),
           Calculations.looksArithmetic(prompt), Calculations.numbers(in: prompt).count >= 2,
           !["cerca", "internet", "online", "sul web", "oggi", "attual", "aggiornat", "adesso"].contains(where: lower.contains),
           !(english && ["search", "on the web", "today", "current", "latest", "updated", "right now"].contains(where: lower.contains)) {
            plan.action = .rispondi
            return
        }
        // «Jot down a couple of lines for Luke… and send them to him»: il testo si scrive per mandarlo, non per le Note.
        if english, plan.action == .crea_nota,
           lower.range(of: #"\b(?:and )?(?:send|text|email|forward) (?:it|them|this|that|these)(?: over)? to\b|\band (?:send|text|email) (?:it|them)\b"#, options: .regularExpression) != nil {
            let mail = ["email", "e-mail", " mail"].contains(where: lower.contains)
            let action: Action = mail ? .scrivi_email : .invia_messaggio
            if availableActions.contains(action) {
                plan.action = action
                plan.fields = [:]
                return
            }
        }
        // «Ci sono novità dal commercialista?», «any news from the accountant?»: notizie da una persona si leggono nella posta, non sul web.
        if availableActions.contains(.mail_leggi), Self.asksNewsFromSomeone(lower) {
            plan.action = .mail_leggi
            plan.fields = [:]
            return
        }
        if chatRules(to: &plan, prompt: prompt, lower: lower) { return }
        if fileRules(to: &plan, prompt: prompt, lower: lower) { return }
        // Un nome di file con estensione + verbo di scrittura, dentro un progetto → scrivere il file.
        if work.projectRoot != nil,
           let match = lower.range(of: #"[\w\-./]+\.(md|txt|json|csv|ya?ml|html|css|js|ts|swift|py|sh|toml)\b"#, options: .regularExpression),
           (["crea", "scrivi", "modifica", "aggiorna", "aggiungi", "salva"]
            + (english ? ["create", "write", "edit", "update", "add ", "save", "append"] : [])).contains(where: lower.contains) {
            plan.action = .file_scrivi
            plan.fields["percorso"] = String(lower[match])
            plan.fields["argomento"] = prompt
            return
        }
        // «Scrivi una poesia…» in un progetto non è un file da scrivere: la richiesta deve parlare di file, cartelle o del progetto,
        // o di qualcosa che la guida del progetto trova (il registro di oggi, un cliente, un file indicato dalle istruzioni).
        if plan.action == .file_scrivi,
           lower.range(of: #"\b(?:file|cartell[ae]|progetto|second brain|vault|inbox|registro|log|folders?|project)\b|\.[a-z]{2,4}\b"#, options: .regularExpression) == nil,
           !projectAnswers(prompt) {
            plan.action = .rispondi
            plan.fields = [:]
        }
        if webRules(to: &plan, prompt: prompt, lower: lower) { return }
        // "Mi ha scritto…", "email non lette": leggere, non scrivere.
        let incoming = #"(mi ha (scritto|mandato|risposto|inviato)|mi hanno scritto|ho ricevuto|(email|mail|messaggi) (di|da) |non lett|da leggere|in arrivo|arrivat)"#
        let englishIncoming = #"(sent me|wrote to me|emailed me|texted me|messaged me|did i (get|receive)|i (got|received)|(emails?|mails?|messages?|texts?) from |unread|in my inbox|arrived|came in)"#
        if lower.range(of: incoming, options: .regularExpression) != nil || (english && lower.range(of: englishIncoming, options: .regularExpression) != nil) {
            let mail = ["mail", "email", "posta"].contains(where: lower.contains) || (english && lower.contains("inbox"))
            let texts = ["messaggi", "messaggio", "imessage", "sms"].contains(where: lower.contains)
                || (english && ["message", "texted", "text from", "texts from"].contains(where: lower.contains))
            if mail && availableActions.contains(.mail_leggi) { plan.action = .mail_leggi; return }
            if texts && !mail { plan.action = .messaggi; return }
        }
        // «Which city does my colleague work in?» dopo «my colleague works in Turin»: la risposta è nella conversazione, non sul web.
        if english, plan.action == .cerca_web, lower.range(of: #"\b(?:my|our)\b"#, options: .regularExpression) != nil,
           conversationCovers(prompt), !Self.isTimeSensitive(prompt) {
            plan.action = .rispondi
            plan.fields = [:]
            return
        }
        // "Ricorda" solo con un'intenzione esplicita: "cosa ricordi di…" è una domanda.
        if plan.action == .ricorda { plan.action = .rispondi }
        // Azioni che creano o cercano qualcosa valgono solo se la richiesta contiene parole coerenti.
        if let words = Self.activeCues[plan.action], !words.contains(where: { " \(lower) ".contains($0) }),
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
           ["per ogni", "per ciascun", "uno per", "per tutti", "per tutte", "i promemoria", "dei promemoria", "più promemoria"].contains(where: lower.contains)
            || (english && ["for each", "for every", "one for each", "one per", "for all the", "several reminders", "reminders for"].contains(where: lower.contains)) {
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
        .crea_agente: ["agente", "agenti", "genius", "ogni mattina", "ogni giorno", "ogni settimana", "ogni lunedì", "ogni sera", "automaticamente", "di continuo"],
    ]

    /// Le stesse parole per le richieste in inglese (si aggiungono a quelle italiane, vedi `activeCues`).
    static let englishCues: [Action: [String]] = [
        .crea_evento: ["event", "meeting", "appointment", "schedule", "calendar", "set up", "book ", " at 1", " at 2", " at 3", " at 4",
                       " at 5", " at 6", " at 7", " at 8", " at 9", " at noon", " at midnight", "tomorrow", "monday",
                       "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "lunch with", "dinner with", "catch up with"],
        .crea_promemoria: ["remind me", "reminder", "to-do", "to do", "don't forget", "do not forget", "don't let me forget", "make sure i"],
        .crea_lista_promemoria: ["reminders", "to-dos", "tasks", "checklist", "list"],
        .scrivi_email: ["message to", "write to", "reply to", "draft"],
        .crea_documento: ["document", "text", "letter", "article", "minutes", "essay", "write me a", "draft a", "write up"],
        .crea_foglio: ["spreadsheet", "sheet", "table", "calculation", "estimates", "chart"],
        .crea_presentazione: ["presentation", "slides"],
        .genera_immagine: ["image", "draw", "illustration", "picture of", "photo of", "generate a", "wallpaper", "portrait", "sketch", "icon"],
        .agenda: ["today", "tomorrow", "week", "day", "schedule", "plans", "what do i have", "what have i got", "what's on", "busy",
                  "free", "calendar", "month", "weekend", "afternoon", "morning", "tonight", "this evening", "next ", "appointments"],
        .elimina_evento: ["delete", "cancel", "remove", "clear"],
        .completa_promemoria: ["done", "complete", "mark", "check off", "finished", "tick"],
        .piano: ["organize", "organise", "plan", "prepare everything", "set everything up"],
        .eventi: ["event", "events", "meeting", "appointment", "calendar"],
        .promemoria: ["reminder", "to-do", "to do", "due", "tasks", "deadline"],
        .calendari: ["calendars", "lists", "which lists"],
        .mail_leggi: ["inbox", "wrote to me", "email from", "emails from", "mail from", "received", "sent me", "got anything", "get anything"],
        .note: [" notes", " my note"], .crea_nota: ["note", "jot down", "write down"],
        .messaggi: ["messages", "message", "texted", "text from", "chat with", "tried to reach", "reached out"],
        .invia_messaggio: ["message", "send", "text ", "write to", "tell "],
        .file: ["folder", "documents", "document", "find", "on my mac", "where did i put", "where's my", "where is my", "search"],
        .cerca_web: englishWebCues, .leggi_pagina: ["page", "site", "article"],
        .naviga: ["open", "go to", "navigate", "go back", "back", "search", "website", "site"],
        .segui_link: ["click", "open", "go to", "follow", "section", "button"],
        .nuova_chat: ["conversation", "sub-chat", "thread"],
        .crea_sito: ["website", "web page", "webpage", "site"],
        .cerca_conversazioni: ["we talked", "we discussed", "we decided", "had decided", "we said", "previous conversation", "previous chat",
                               "i told you", "you told me", "remember when", "last time", "what did we"],
        .crea_agente: ["agent", "genius", "every morning", "every day", "every week", "every monday", "every evening", "automatically", "continuously"],
    ]

    /// «Novità dal commercialista?», «heard back from the lawyer?»: notizie attese da una persona o da un ufficio (non da un'azienda o un tema).
    static func asksNewsFromSomeone(_ lower: String) -> Bool {
        let italianRoles = #"(?:commercialista|avvocat[oa]|notaio|medico|dottor\w*|dentista|banca|client[ei]|fornitor\w*|capo|ufficio|agenzia delle entrate|assicurazion\w*|amministrator\w*|condominio|scuola|professor\w*|idraulico|elettricista|architett[oa]|geometra|consulente)"#
        let italian = #"\b(?:novit[aà]|notizie|aggiornamenti|risposte?)\s+(?:da|dal|dalla|dallo|dall'|dai|dagli|dalle)\s*(?:mi[aoei]\s+|nostr[aoei]\s+)?"# + italianRoles + #"\b"#
        if lower.range(of: italian, options: .regularExpression) != nil { return true }
        guard Language.isEnglish else { return false }
        let englishRoles = #"(?:accountant|lawyer|attorney|notary|doctor|dentist|bank|client|customer|supplier|vendor|boss|manager|office|tax office|insurance|insurer|landlord|school|teacher|plumber|electrician|architect|consultant)"#
        let english = #"\b(?:any )?(?:news|word|updates?|reply|response|answer)\s+from\s+(?:the |my |our )?"# + englishRoles + #"\b|\bheard (?:back )?from\s+(?:the |my |our )?"# + englishRoles + #"\b"#
        return lower.range(of: english, options: .regularExpression) != nil
    }

    /// Rete di sicurezza: il modello piccolo tende a scegliere una sola azione anche quando la richiesta ne elenca diverse.
    static func mentionsSeveralActions(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        let english = Language.isEnglish
        var groups = [["evento", "eventi", "riunion", "appuntament"], ["promemoria"], ["email", "e-mail", "mail"],
                      ["documento"], ["foglio", "tabella", "budget"], ["presentazione", "slide"]]
        if english {
            groups = [["event", "meeting", "appointment"], ["reminder"], ["email", "e-mail", "mail"],
                      ["document"], ["spreadsheet", "sheet", "table", "budget"], ["presentation", "slide"]]
        }
        let count = groups.filter { words in words.contains { text.contains($0) } }.count
        // "Scrivi un'email a Luca per spostare la riunione" è una sola azione: servono un elenco o più verbi.
        let listed = text.contains(",") || text.contains(":") || text.contains(";")
            || [" e poi ", " poi ", " e crea", " e fissa", " e prepara", " e scrivi", " e manda", " e aggiungi"].contains(where: text.contains)
            || (english && [" and then ", " then ", " and create", " and set up", " and prepare", " and write", " and send", " and add"].contains(where: text.contains))
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
        if Language.isEnglish {
            return """
            \(context)User request: \(prompt)

            Real data:
            \(Self.untrusted(data, label: label))

            Answer usefully and concisely in English using ONLY this data\(withProject ? " and the project files shown above" : ""). If it is already shown in a card, don't repeat the full list: highlight what matters. Report titles and names exactly as they are. Don't show the IDs in square brackets. Write dates in a readable form.\(formatHint)
            """
        }
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
        let base = Language.isEnglish ? """
        You are Siri AI+, \(Self.userFirstName.map { "\($0)'s" } ?? "the user's") assistant on the Mac. It is now \(Dates.format(.now)). Always answer in English, clearly and warmly.
        Gladly answer general knowledge, history, science, advice, ideas and code questions from your own knowledge, thoroughly when needed. You can also search the web, use Calendar, Reminders, Mail, Notes, Messages and project files, and create documents, spreadsheets, presentations and images.
        When you receive data (web, files, tools, calculations already done) rely only on it and don't make things up. Cite sources with [1], [2] only if you receive numbered web results; otherwise never write numbers in square brackets.
        \(Self.untrustedRule)
        Stay consistent with what was already said in the conversation and don't repeat what you already explained.
        """ : """
        Sei Siri AI+, l'assistente di \(Self.userFirstName ?? "chi usa questo Mac") sul Mac. Adesso è \(Dates.format(.now)). Rispondi in italiano, chiaro e cordiale.
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
                    if !full.isEmpty { blocks.append(Language.t("Istruzioni del progetto, da seguire:", "Project instructions, to follow:") + "\n\(full)") }
                } else if let agents = work.agents, !agents.isEmpty {
                    blocks.append(Language.t("Istruzioni del progetto (sintesi):", "Project instructions (summary):") + "\n\(agents.prefix(limit(1000, 600)))")
                }
            }
            if let space = work.spaceName {
                var line = Language.t("Spazio attuale: \(space): usa solo calendari, liste, posta e servizi di questo spazio.",
                                      "Current space: \(space): use only the calendars, lists, mail and services of this space.")
                if let extra = work.spaceInstructions, !extra.isEmpty { line += Language.t(" Indicazioni: ", " Guidance: ") + extra.prefix(limit(600, 300)) }
                blocks.append(line)
            }
            if let soul = work.soul, !soul.isEmpty {
                blocks.append(Language.t("Sei un agente con questa anima (soul.md): seguila.", "You are an agent with this soul (soul.md): follow it.") + "\n\(soul.prefix(limit(800, 450)))")
            }
            if let task = work.skillTask, let agentID = work.agentID {
                let skills = SkillStore.matching(task, project: work.skillProjectRoot ?? work.projectRoot, agent: agentID)
                if !skills.isEmpty {
                    blocks.append(Language.t("Skill pertinenti di questo Genius, da seguire durante l'esecuzione:",
                                             "Relevant skills for this Genius, to follow during this run:") + "\n"
                                  + skills.map { "\($0.name):\n\($0.body.prefix(limit(700, 350)))" }.joined(separator: "\n\n"))
                }
            }
            if let inherited, !inherited.isEmpty {
                blocks.append(Language.t("Questa è una chat figlia: ecco di cosa si parlava nella chat madre (usalo per capire le richieste, senza ripeterlo):",
                                         "This is a child chat: here is what the parent chat was about (use it to understand the requests, without repeating it):")
                              + "\n\(inherited.prefix(limit(900, 500)))")
            }
            if let summary {
                blocks.append(Language.t("Riassunto della parte meno recente della conversazione:", "Summary of the older part of the conversation:") + "\n\(summary.prefix(limit(1100, 600)))")
            }
            let text = ([base] + blocks).joined(separator: "\n")
            if Self.estimatedTokens(text) <= Self.instructionShare(of: budget) { return text }
        }
        // Su Mac dove il modello non è pronto la finestra può risultare minima: tieni prima le regole del progetto.
        if let project = work.projectName, let agents = work.agents, !agents.isEmpty {
            let heading = "\n" + Self.projectRule(project) + "\n" + Language.t("Istruzioni del progetto (sintesi):", "Project instructions (summary):") + "\n"
            let available = max(120, (Self.instructionShare(of: budget) - Self.estimatedTokens(base + heading)) * 2)
            return base + heading + String(agents.prefix(available))
        }
        return base
    }

    /// Nome di chi usa il Mac (dal nome dell'account), per rivolgersi a lui nelle istruzioni.
    public nonisolated static var userFirstName: String? {
        NSFullUserName().split(separator: " ").first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Chi usa il Mac nei prompt: il nome dell'account («Ivan»), altrimenti «l'utente» / «the user».
    public nonisolated static var userLabel: String { userFirstName ?? Language.t("l'utente", "the user") }

    /// Come chiudere un'email o un messaggio: con il nome dell'account, se c'è.
    nonisolated static var signatureRule: String {
        if let name = userFirstName { return Language.t("chiusura firmata \(name)", "a closing signed \(name)") }
        return Language.t("chiusura cordiale senza nome", "a warm closing without a name")
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
        let t = Language.t
        var fields: [Field] = [.required("azione", .choice(actions.map(\.rawValue)), t("Azione da eseguire", "Action to perform"))]
        fields += Language.isEnglish ? Self.englishBaseFields : Self.baseFields
        if actions.contains(where: { [.file_leggi, .file_elenca, .file_scrivi, .file_sposta, .file_cartella, .file_elimina].contains($0) }) {
            fields.append(.optional("percorso", .string, t("Percorso del file o della cartella nel progetto, es. docs/note.md",
                                                            "Path of the file or folder in the project, e.g. docs/notes.md")))
        }
        if actions.contains(.file_sposta) {
            fields.append(.optional("destinazione", .string, t("Cartella di destinazione o nuovo nome del file", "Destination folder or new file name")))
        }
        if actions.contains(.genera_immagine) {
            fields.append(.optional("stile", .choice(["animazione", "illustrazione", "schizzo"]), t("Stile dell'immagine", "Image style")))
        }
        if actions.contains(.strumento_esterno) {
            fields.append(.optional("strumento", .choice(work.mcpTools.map(\.name)), t("Strumento esterno da usare", "External tool to use")))
        }
        if actions.contains(.segui_link), !work.browserLinks.isEmpty {
            fields.append(.optional("link", .choice(work.browserLinks), t("Link della pagina da aprire", "Link on the page to open")))
        }
        return makeSchema("Piano", fields)
    }

    /// I campi del piano descritti in inglese (i nomi restano quelli: li legge il codice).
    private static let englishBaseFields: [Field] = [
        .optional("dal", .string, "Start of the period, yyyy-MM-dd"),
        .optional("al", .string, "End of the period, yyyy-MM-dd"),
        .optional("cerca", .string, "Word to search for in titles"),
        .optional("titolo", .string, "Event title or reminder text, WITHOUT date, time or words like tomorrow"),
        .optional("inizio", .string, "Event start, yyyy-MM-dd HH:mm"),
        .optional("fine", .string, "Event end, yyyy-MM-dd HH:mm"),
        .optional("scadenza", .string, "Reminder due date, yyyy-MM-dd HH:mm or yyyy-MM-dd"),
        .optional("luogo", .string, "Event location"),
        .optional("lista", .string, "Name of the calendar or list, only if the user names it"),
        .optional("id", .string, "ID like E3 or R2 taken from the previous context"),
        .optional("argomento", .string, "Topic of the email, document, spreadsheet, presentation or list"),
        .optional("destinatari", .string, "Email recipients named by the user, separated by commas"),
    ]

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

    /// Le stesse spiegazioni per le richieste in inglese.
    private static let englishActionHelp: [Action: String] = [
        .rispondi: "rispondi: conversation, greetings, explanations, advice and general knowledge questions that need no personal data or recent news.",
        .agenda: "agenda: what the user has to do in a period, events and reminders together (\"what do I have tomorrow\", \"plan my day\"). Use dal and al.",
        .eventi: "eventi: calendar events only. Use dal, al, cerca.",
        .promemoria: "promemoria: existing reminders only. Use lista and al.",
        .calendari: "calendari: list of calendars and lists.",
        .crea_evento: "crea_evento: a new event. Use titolo, inizio, fine, luogo, lista.",
        .crea_promemoria: "crea_promemoria: ONE reminder (\"remind me to…\"). Use titolo, scadenza, lista.",
        .crea_lista_promemoria: "crea_lista_promemoria: several reminders on a topic. Use argomento, lista.",
        .elimina_evento: "elimina_evento: delete an existing event. Use id (E…) if it is in the context.",
        .completa_promemoria: "completa_promemoria: mark a reminder as done. Use id (R…) if it is in the context.",
        .modifica_evento: "modifica_evento: move, bring forward, postpone, rename or change the place or length of an existing event (\"move the meeting with Mark to 4 pm\").",
        .modifica_promemoria: "modifica_promemoria: change the due date, text, list or priority of an existing reminder.",
        .elimina_promemoria: "elimina_promemoria: delete an existing reminder.",
        .modifica_nota: "modifica_nota: add text to an existing note in the Notes app (\"add milk to the shopping note\").",
        .rispondi_email: "rispondi_email: reply to a received email. Use destinatari with the sender and argomento with what to reply.",
        .inoltra_email: "inoltra_email: forward a received email to someone else. Use destinatari with the recipient.",
        .scrivi_email: "scrivi_email: write or draft an email. Use argomento, destinatari.",
        .crea_documento: "crea_documento: document, text, report, written plan. Use argomento.",
        .crea_foglio: "crea_foglio: spreadsheet, table, budget, estimates, chart. Use argomento.",
        .crea_presentazione: "crea_presentazione: presentation or slides. Use argomento.",
        .piano: "piano: complex request with several actions together (\"organize the launch: events, emails and a document\").",
        .mail_leggi: "mail_leggi: read, search or summarize received emails. Use cerca with the sender or topic if given.",
        .note: "note: read or search the notes in the Notes app. Use cerca with the keyword.",
        .crea_nota: "crea_nota: write a new note in the Notes app. Use titolo and argomento.",
        .messaggi: "messaggi: read received or sent messages (iMessage/SMS). Use destinatari with the person or cerca.",
        .invia_messaggio: "invia_messaggio: send an iMessage or SMS to someone. Use destinatari and argomento with the text.",
        .file: "file: find or read documents and files on the Mac. Use cerca with the file name or topic.",
        .genera_immagine: "genera_immagine: draw or create an image. Use argomento (what to draw) and stile.",
        .ricorda: "ricorda: the user asks you to remember a piece of information (\"remember that…\"). Use argomento.",
        .cerca_web: "cerca_web: search the internet for news, recent facts, prices, weather, results, schedules, information about companies, products or people. Use cerca with the words to search for.",
        .leggi_pagina: "leggi_pagina: read or summarize a web page (address in the request, or the page open in the browser or in Safari). Use argomento with the address if there is one.",
        .naviga: "naviga: open a website or search in the built-in browser. Use argomento with the address or the words to search for.",
        .segui_link: "segui_link: open a link on the page open in the browser. Use link.",
        .crea_sito: "crea_sito: create a web page, a website or a landing page (HTML and CSS). Use argomento.",
        .crea_agente: "crea_agente: create an agent that works on its own on a goal, even at set times (\"every morning give me a press review\").",
        .cerca_conversazioni: "cerca_conversazioni: search past conversations for what was said or decided. Use cerca with the keywords.",
        .nuova_chat: "nuova_chat: open a new chat or conversation about a topic, also in a project. Use argomento and lista with the project name.",
    ]

    private func plannerInstructions(_ actions: [Action], compact: Bool = false) -> String {
        if Language.isEnglish {
            let help = actions.compactMap { Self.englishActionHelp[$0] }.map { "- \($0)" }.joined(separator: "\n")
            return """
            Turn the user's request into ONE action. Choose rispondi if no action is really needed.
            It is now \(Dates.format(.now)). Next days:
            \(Dates.upcomingDays(14))

            Actions:
            \(help)
            \(workInstructions(actions, compact: compact))
            Dates as yyyy-MM-dd or yyyy-MM-dd HH:mm using the list of next days. "This week" goes from today to Sunday.
            Fill in only the relevant fields.
            """
        }
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
        let t = Language.t
        var request = t("Richiesta: ", "Request: ") + prompt
        let contextLimit = compact ? 500 : 1500
        if !context.isEmpty {
            request = t("Contesto precedente:", "Previous context:") + "\n\(context.prefix(contextLimit))\n\n\(request)"
        }
        if !compact, let recent = recentConversation(exchanges: 2, user: 260, reply: 260) {
            request = t("Conversazione recente:", "Recent conversation:") + "\n\(recent)\n\n\(request)"
        }

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
            title = plan["lista"].map { Language.t("Promemoria · ", "Reminders · ") + $0 } ?? Language.t("Promemoria da fare", "Reminders to do")
        } else if from == to {
            title = from.formatted(dayFormat).capitalized
            if from == today { title = Language.t("Oggi · ", "Today · ") + title }
            else if from == cal.date(byAdding: .day, value: 1, to: today) { title = Language.t("Domani · ", "Tomorrow · ") + title }
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
        let english = Language.isEnglish
        let none = english ? "none" : "nessuno"
        var parts: [String] = []
        if agenda.showsEvents {
            let lines = agenda.events.map { e -> String in
                let id = ids.register(event: e.identifier, start: e.start)
                let when = e.isAllDay ? "\(Dates.format(e.start, time: false)), \(english ? "all day" : "tutto il giorno")"
                                      : "\(Dates.format(e.start))–\(Dates.format(e.end).suffix(5))"
                return "[\(id)] «\(e.title)» (\(when), \(english ? "calendar" : "calendario") \(e.calendar))"
            }
            parts.append((english ? "EVENTS:\n" : "EVENTI:\n") + (lines.isEmpty ? none : lines.joined(separator: "\n")))
        }
        if agenda.showsReminders {
            func line(_ r: ReminderItem) -> String {
                let id = ids.register(reminder: r.id)
                let due = r.due.map { (english ? ", due " : ", scade ") + Dates.format($0, time: r.dueHasTime) } ?? ""
                return "[\(id)] «\(r.title)» (\(english ? "list" : "lista") \(r.list)\(due))"
            }
            parts.append((english ? "REMINDERS:\n" : "PROMEMORIA:\n") + (agenda.reminders.isEmpty ? none : agenda.reminders.map(line).joined(separator: "\n")))
            if !agenda.overdue.isEmpty {
                parts.append((english ? "OVERDUE (due before today):\n" : "ARRETRATI (scaduti prima di oggi):\n") + agenda.overdue.map(line).joined(separator: "\n"))
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
        let english = Language.isEnglish
        var lines = [english ? "ANALYSIS OF THE DAY (calculated by the app, time window \(window.label)):"
                             : "ANALISI DELLA GIORNATA (calcolata dall'app, fascia \(window.label)):"]
        for i in timed.indices {
            for j in timed.indices where j > i && timed[j].start < timed[i].end {
                let end = min(timed[i].end, timed[j].end)
                let span = "\(Calculations.clock(minute(timed[j].start)))–\(Calculations.clock(minute(end)))"
                lines.append(english ? "- «\(timed[i].title)» and «\(timed[j].title)» overlap (\(span))."
                                     : "- «\(timed[i].title)» e «\(timed[j].title)» si sovrappongono (\(span)).")
            }
        }
        let busy = analysis.busy.map(\.minutes).reduce(0, +)
        let free = analysis.free.map(\.minutes).reduce(0, +)
        lines.append(english ? "- Busy: \(Calculations.duration(busy)) in total." : "- Occupato: \(Calculations.duration(busy)) in tutto.")
        lines.append((english ? "- Free in the window \(window.label): " : "- Libero nella fascia \(window.label): ") + (analysis.free.isEmpty ? (english ? "nothing." : "niente.") :
            "\(Calculations.duration(free)) (" + analysis.free.map { "\($0.label), \(Calculations.duration($0.minutes))" }.joined(separator: "; ") + ")."))
        return lines.joined(separator: "\n")
    }

    // MARK: - 3. Contenuti generati

    func writer(_ role: String) -> LanguageModelSession {
        LanguageModelSession(model: Agent.model, instructions: Language.isEnglish ? """
        \(role) Write in English, with concrete and plausible content, without placeholders in brackets.
        It is now \(Dates.format(.now)). Next days:
        \(Dates.upcomingDays(14))
        """ : """
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
        let session = writer(Self.documentRole)
        for try await snapshot in session.streamResponse(to: Language.t("Scrivi un documento su: ", "Write a document about: ") + topic, schema: Self.documentSchema) {
            let content = snapshot.content
            let sections = content.objects("sezioni").map { DocumentDraft.Section(title: $0.string("titolo") ?? "", body: $0.string("testo") ?? "") }
            draft = DocumentDraft(title: content.string("titolo") ?? "", subtitle: content.string("sottotitolo") ?? "", sections: sections)
            onUpdate(draft)
        }
        return draft
    }

    private static var documentRole: String {
        Language.t("Sei un redattore esperto di documenti di lavoro.", "You are an expert writer of work documents.")
    }

    private static var documentSchema: GenerationSchema {
        makeSchema("Documento", [
            .required("titolo", .string, Language.t("Titolo del documento", "Document title")),
            .required("sottotitolo", .string, Language.t("Sottotitolo di una riga", "One-line subtitle")),
            .required("sezioni", .array(.object("Sezione", [
                .required("titolo", .string, Language.t("Titolo della sezione", "Section title")),
                .required("testo", .string, Language.t("Testo della sezione, da 2 a 4 frasi", "Section text, 2 to 4 sentences")),
            ]), min: 3, max: 6), Language.t("Sezioni del documento", "Document sections")),
        ])
    }

    /// Documento scritto dal modello scelto in Markdown (nil con Apple Intelligence o se non risponde).
    func writtenDocument(topic: String, onUpdate: @escaping @MainActor (DocumentDraft) -> Void = { _ in }) async -> DocumentDraft? {
        let request = Language.isEnglish ? """
        Write a document about: \(topic)

        Markdown format: «# Title» on the first line, then a one-line subtitle, then 3 to 6 sections «## Section title» \
        with 2-4 sentences each. No comments before or after.
        """ : """
        Scrivi un documento su: \(topic)

        Formato Markdown: «# Titolo» sulla prima riga, poi un sottotitolo di una riga, poi da 3 a 6 sezioni «## Titolo della sezione» \
        con 2-4 frasi ciascuna. Niente commenti prima o dopo.
        """
        guard let text = await externalText(Self.documentRole, request, partial: { onUpdate(Self.documentDraft(markdown: $0)) }) else { return nil }
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
        let content = try await writer(Self.documentRole)
            .respond(to: Language.t("Scrivi un documento su: ", "Write a document about: ") + topic, schema: Self.documentSchema).content
        return DocumentDraft(
            title: content.string("titolo") ?? Language.t("Documento", "Document"),
            subtitle: content.string("sottotitolo") ?? "",
            sections: content.objects("sezioni").map {
                .init(title: $0.string("titolo") ?? "", body: $0.string("testo") ?? "")
            }
        )
    }

    private static var sheetSchema: GenerationSchema {
        makeSchema("Foglio", [
            .required("titolo", .string, Language.t("Titolo del foglio", "Spreadsheet title")),
            .required("colonne", .array(.string, min: 2, max: 3),
                      Language.t("Periodi o scenari confrontati, per esempio «Ottobre», «Novembre» o «Minimo», «Massimo». Solo colonne numeriche",
                                 "Periods or scenarios compared, for example «October», «November» or «Minimum», «Maximum». Numeric columns only")),
            .required("righe", .array(.object("Riga", [
                .required("voce", .string, Language.t("Nome della voce", "Item name")),
                .required("valori", .array(.double, min: 2, max: 4), Language.t("Un valore numerico per ogni colonna, senza simboli", "One numeric value per column, without symbols")),
            ]), min: 3, max: 8), Language.t("Righe della tabella", "Table rows")),
        ])
    }

    public func generateSheet(topic: String) async throws -> SheetDraft {
        let role = Language.t("Sei un analista che prepara fogli di calcolo chiari e realistici.", "You are an analyst who prepares clear, realistic spreadsheets.")
        let request = Language.t("Prepara una tabella per: ", "Prepare a table for: ") + topic
        let fields = Language.t("\"titolo\": titolo del foglio; \"colonne\": da 2 a 3 periodi o scenari confrontati (solo colonne numeriche); \"righe\": da 3 a 8 oggetti {\"voce\": nome, \"valori\": un numero per colonna, senza simboli}",
                                "\"titolo\": spreadsheet title; \"colonne\": 2 to 3 periods or scenarios compared (numeric columns only); \"righe\": 3 to 8 objects {\"voce\": name, \"valori\": one number per column, without symbols}")
        let untitled = Language.t("Foglio", "Spreadsheet")
        let item = Language.t("Voce", "Item")
        var title: String
        var columns: [String]
        var rawRows: [(label: String, values: [Double])]
        if let json = await composeJSON(role, request, fields: fields),
           !json.objects("righe").isEmpty {
            title = json.text("titolo") ?? untitled
            columns = json.texts("colonne")
            rawRows = json.objects("righe").map { ($0.text("voce") ?? item, $0.numbers("valori")) }
        } else {
            let content = try await writer(role).respond(to: request, schema: Self.sheetSchema).content
            title = content.string("titolo") ?? untitled
            columns = content.strings("colonne")
            rawRows = content.objects("righe").map { ($0.string("voce") ?? item, $0.doubles("valori")) }
        }
        let width = max(columns.count, 2)
        let rows = rawRows.map { row -> SheetDraft.Row in
            var values = row.values
            if values.count < width { values += Array(repeating: 0, count: width - values.count) }
            return .init(label: row.label, values: Array(values.prefix(width)))
        }
        let fallbackColumns = [Language.t("Colonna 1", "Column 1"), Language.t("Colonna 2", "Column 2")]
        var sheet = SheetDraft(title: title, columns: columns.count >= 2 ? Array(columns.prefix(width)) : fallbackColumns, rows: rows)
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

    private static var deckSchema: GenerationSchema {
        makeSchema("Presentazione", [
            .required("titolo", .string, Language.t("Titolo della presentazione", "Presentation title")),
            .required("sottotitolo", .string, Language.t("Sottotitolo della slide iniziale", "Subtitle of the opening slide")),
            .required("slide", .array(.object("Slide", [
                .required("titolo", .string, Language.t("Titolo della slide", "Slide title")),
                .required("punti", .array(.string, min: 2, max: 4), Language.t("Punti elenco brevi", "Short bullet points")),
            ]), min: 3, max: 6), Language.t("Slide dopo quella iniziale", "Slides after the opening one")),
        ])
    }

    private static var deckRole: String {
        Language.t("Sei un esperto di presentazioni aziendali sintetiche.", "You are an expert in concise business presentations.")
    }

    public func generateDeck(topic: String) async throws -> DeckDraft {
        let request = Language.t("Prepara una presentazione su: ", "Prepare a presentation about: ") + topic
        let untitled = Language.t("Presentazione", "Presentation")
        if let json = await composeJSON(Self.deckRole, request,
                                        fields: Language.t("\"titolo\": titolo della presentazione; \"sottotitolo\": sottotitolo della slide iniziale; \"slide\": da 3 a 6 oggetti {\"titolo\": titolo della slide, \"punti\": da 2 a 4 punti elenco brevi}",
                                                           "\"titolo\": presentation title; \"sottotitolo\": subtitle of the opening slide; \"slide\": 3 to 6 objects {\"titolo\": slide title, \"punti\": 2 to 4 short bullet points}")),
           !json.objects("slide").isEmpty {
            return DeckDraft(title: json.text("titolo") ?? untitled, subtitle: json.text("sottotitolo") ?? "",
                             slides: json.objects("slide").map { .init(title: $0.text("titolo") ?? "", bullets: Array($0.texts("punti").prefix(5)).map { $0.hasSuffix("...") ? $0 : $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }) })
        }
        let content = try await writer(Self.deckRole)
            .respond(to: request, schema: Self.deckSchema).content
        return DeckDraft(
            title: content.string("titolo") ?? untitled,
            subtitle: content.string("sottotitolo") ?? "",
            slides: content.objects("slide").map { .init(title: $0.string("titolo") ?? "", bullets: $0.strings("punti")) }
        )
    }

    private static var mailSchema: GenerationSchema {
        makeSchema("Email", [
            .required("destinatari", .array(.string, max: 6), Language.t("Nomi o indirizzi dei destinatari citati dall'utente", "Names or addresses of the recipients mentioned by the user")),
            .required("oggetto", .string, Language.t("Oggetto dell'email", "Email subject")),
            .required("corpo", .string, Language.t("Testo completo dell'email con saluto iniziale e ", "Full text of the email with an opening greeting and ") + signatureRule),
        ])
    }

    public func generateMail(topic: String, recipients: String?) async throws -> MailDraft {
        let english = Language.isEnglish
        let role = english
            ? "You are \(Self.userFirstName.map { "\($0)'s" } ?? "the user's") assistant and write professional, warm emails. Don't make up dates, times, places, numbers or commitments the user didn't give: stay general where details are missing."
            : "Sei l'assistente di \(Self.userLabel) e scrivi email professionali e cordiali. Non inventare date, orari, luoghi, numeri o impegni che l'utente non ha indicato: resta generico dove mancano i dettagli."
        let request = (english ? "Write an email about: " : "Scrivi un'email su: ") + topic + (recipients.map { (english ? "\nRecipients: " : "\nDestinatari: ") + $0 } ?? "")
        let fields = english
            ? "\"destinatari\": names or addresses mentioned by the user; \"oggetto\": email subject; \"corpo\": full text with an opening greeting and \(Self.signatureRule)"
            : "\"destinatari\": nomi o indirizzi citati dall'utente; \"oggetto\": oggetto dell'email; \"corpo\": testo completo con saluto iniziale e \(Self.signatureRule)"
        if let json = await composeJSON(role, request, fields: fields),
           let body = json.text("corpo") {
            var names = json.texts("destinatari")
            if names.isEmpty, let recipients { names = recipients.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            return MailDraft(recipients: names, subject: json.text("oggetto") ?? "", body: body)
        }
        let content = try await writer(role)
            .respond(to: request, schema: Self.mailSchema).content
        var names = content.strings("destinatari")
        if names.isEmpty, let recipients {
            names = recipients.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return MailDraft(recipients: names, subject: content.string("oggetto") ?? "", body: content.string("corpo") ?? "")
    }

    private static var remindersSchema: GenerationSchema {
        makeSchema("Promemoria", [
            .required("elementi", .array(.object("Elemento", [
                .required("titolo", .string, Language.t("Cosa fare, breve", "What to do, short")),
                .optional("scadenza", .string, Language.t("Scadenza, yyyy-MM-dd", "Due date, yyyy-MM-dd")),
            ]), min: 3, max: 8), Language.t("Promemoria da creare, in ordine cronologico", "Reminders to create, in chronological order")),
        ])
    }

    private static var remindersRole: String {
        Language.t("Sei un project manager che scompone gli obiettivi in attività concrete.", "You are a project manager who breaks goals down into concrete tasks.")
    }

    public func generateReminders(topic: String) async throws -> [ReminderDraft] {
        let request = Language.t("Elenca i promemoria per: ", "List the reminders for: ") + topic
        if let json = await composeJSON(Self.remindersRole, request,
                                        fields: Language.t("\"elementi\": da 3 a 8 oggetti in ordine cronologico {\"titolo\": cosa fare, breve; \"scadenza\": yyyy-MM-dd se serve}",
                                                           "\"elementi\": 3 to 8 objects in chronological order {\"titolo\": what to do, short; \"scadenza\": yyyy-MM-dd if needed}")),
           !json.objects("elementi").isEmpty {
            return json.objects("elementi").compactMap { item in
                guard let title = item.text("titolo") else { return nil }
                let due = Dates.parse(item.text("scadenza"))
                return ReminderDraft(title: title, due: due?.date, dueHasTime: due?.hasTime ?? false)
            }
        }
        let content = try await writer(Self.remindersRole)
            .respond(to: request, schema: Self.remindersSchema).content
        return content.objects("elementi").compactMap { item in
            guard let title = item.string("titolo") else { return nil }
            let due = Dates.parse(item.string("scadenza"))
            return ReminderDraft(title: title, due: due?.date, dueHasTime: due?.hasTime ?? false)
        }
    }

    private static var planDraftSchema: GenerationSchema {
        makeSchema("PianoAzioni", [
            .required("riepilogo", .string, Language.t("Una frase che riassume il piano", "One sentence summarizing the plan")),
            .required("passi", .array(.object("Passo", [
                .required("tipo", .choice(PlanDraft.Kind.allCases.map(\.rawValue)), Language.t("Tipo di azione", "Kind of action")),
                .required("titolo", .string, Language.t("Titolo dell'evento, promemoria, email o file", "Title of the event, reminder, email or file")),
                .optional("quando", .string, Language.t("Data e ora, yyyy-MM-dd HH:mm, solo per eventi e promemoria", "Date and time, yyyy-MM-dd HH:mm, only for events and reminders")),
                .required("dettagli", .string, Language.t("Cosa verrà fatto, in una frase", "What will be done, in one sentence")),
            ]), min: 2, max: 6), Language.t("Passi del piano, nell'ordine di esecuzione", "Steps of the plan, in execution order")),
        ])
    }

    public func generatePlan(goal: String) async throws -> PlanDraft {
        let content = try await writer(Language.t("Sei un assistente che trasforma un obiettivo in un piano di azioni su calendario, promemoria, email e documenti.",
                                                  "You are an assistant who turns a goal into a plan of actions across calendar, reminders, email and documents."))
            .respond(to: Language.t("Obiettivo: ", "Goal: ") + goal, schema: Self.planDraftSchema).content
        let steps = content.objects("passi").compactMap { step -> PlanDraft.Step? in
            guard let kind = step.string("tipo").flatMap(PlanDraft.Kind.init(rawValue:)) else { return nil }
            return .init(kind: kind, title: step.string("titolo") ?? kind.rawValue.capitalized,
                         when: step.string("quando"), detail: step.string("dettagli") ?? "")
        }
        return PlanDraft(goal: goal, summary: content.string("riepilogo") ?? Language.t("Ecco il piano.", "Here's the plan."), steps: steps)
    }
}
