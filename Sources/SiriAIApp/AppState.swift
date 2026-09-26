import AppKit
import Contacts
import CryptoKit
import EventKit
import Foundation
import FoundationModels
import Observation
import PDFKit
import SiriCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor @Observable
final class AppState {
    @MainActor final class IndependentResponse {
        let conversation: Conversation
        let assistant: Assistant
        var selection: ModelSelection
        var appleOnly = false

        init(conversation: Conversation, assistant: Assistant, selection: ModelSelection) {
            self.conversation = conversation
            self.assistant = assistant
            self.selection = selection
        }
    }
    @TaskLocal private static var independentResponse: IndependentResponse?

    enum Phase { case onboarding, permissions, app }
    enum Section: Hashable { case home, app(SourceKind), browser, appLauncher, documents(ArtifactKind), project(UUID), artifact(UUID), activity, automations, connectors, settings, agents, agent(UUID), schedule
        /// Un file aperto in una scheda (Markdown da leggere, testo o codice da modificare).
        case file(URL)
        /// Una scheda con una o più chat affiancate.
        case chats(UUID) }

    struct Attachment: Identifiable {
        let id = UUID()
        let name: String
        let text: String
        /// Foto, screenshot o pagina di un PDF scansionato: copia tra i dati dell'app, guardata da Apple Intelligence.
        var imageURL: URL? = nil
    }

    // MARK: Navigazione

    var phase: Phase
    var section: Section = .home {
        didSet {
            if let focus = appFocus, section != .app(focus.source) { appFocus = nil }
            updateCodeContext()
            updateAppTabs(from: oldValue)
            // Tra la Home e le altre sezioni la conversazione si sposta (stessa lastra) invece di sparire e riapparire.
            if (oldValue == .home) != (section == .home) { chatMovesFromHome = !(current?.messages.isEmpty ?? true) }
            // Diagnostica: chi chiude il documento aperto al centro.
            if case .artifact = oldValue, section != oldValue {
                Agent.log("SEZIONE: da documento a \(section) · " + Thread.callStackSymbols.dropFirst().prefix(10).map { $0.replacingOccurrences(of: "  ", with: " ") }.joined(separator: " | "))
            }
        }
    }
    var sourcesSheet: SourceKind?
    var showSourcesSheet = false

    /// Elemento da mostrare in un'app (una nota, un'email, un file, una conversazione), aperto da una scheda della chat.
    struct AppFocus: Equatable {
        let id = UUID()
        let source: SourceKind
        let reference: String
    }
    /// Resta finché si è nell'app: ogni vista lo applica una volta sola (anche se viene ricreata).
    var appFocus: AppFocus?

    /// Le app aperte di ogni chat (e di ogni sessione di coding), come le schede di Safari: restano con la loro chat
    /// finché non le chiudi, e ogni chat ha le sue.
    var tabsByOwner: [UUID: [AppTab]] = AppState.savedTabsByOwner() {
        didSet { saveTabsByOwner() }
    }
    /// Ultima scheda guardata in ogni chat: il pulsante «App» riapre da lì.
    var lastTabByOwner: [UUID: AppTab] = [:]
    /// Le schede della chat aperta.
    var appTabs: [AppTab] {
        get { tabOwner.flatMap { tabsByOwner[$0] } ?? [] }
        set {
            guard let owner = tabOwner else { return }
            tabsByOwner[owner] = newValue.isEmpty ? nil : newValue
        }
    }
    var lastAppTab: AppTab? {
        get { tabOwner.flatMap { lastTabByOwner[$0] } }
        set { if let owner = tabOwner { lastTabByOwner[owner] = newValue } }
    }
    /// Dove tornare chiudendo le app (la chat, un progetto…).
    var sectionBeforeApps: Section = .home
    /// Memo Vocali sta registrando: la sua scheda lo mostra anche quando è dietro.
    var recordingVoiceMemo = false
    /// Aumenta per mettere il cursore nel campo di scrittura di Siri AI+ (es. «Crea con Siri AI+» nelle app dei documenti).
    var composerFocusRequest = 0
    /// Ciò che ogni scheda mostra (elemento selezionato o riassunto): lo legge l'assistente, lo usano i suggerimenti della chat.
    var screenItems: [AppTab: ScreenItem] = [:]

    /// Apre l'app dentro Siri AI+ sull'elemento indicato.
    func openInApp(_ source: SourceKind, reference: String?) {
        section = .app(source)
        appFocus = reference.map { AppFocus(source: source, reference: $0) }
    }
    var showChildSheet = false
    var showCommandPalette = false
    /// Scheda delle Impostazioni da aprire (es. "spazi").
    var settingsTab: String?
    /// Aumenta per chiedere alla finestra principale di aprire le Impostazioni.
    var settingsRequest = 0

    /// Apre la finestra delle Impostazioni, eventualmente su una scheda.
    func openSettings(_ tab: String? = nil) {
        settingsTab = tab
        settingsRequest += 1
    }

    /// Avviso temporaneo in basso.
    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let symbol: String
    }
    var toast: Toast?

    func showToast(_ text: String, symbol: String = "checkmark.circle.fill") {
        let toast = Toast(text: text, symbol: symbol)
        withAnimation(DS.Motion.standard) { self.toast = toast }
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if self.toast?.id == toast.id { withAnimation(DS.Motion.standard) { self.toast = nil } }
        }
    }
    /// Agenti: obiettivi su cui Siri AI+ lavora da sola, con orari, registro e approvazioni.
    var agents: [AgentSpec] = []
    var runningAgents: Set<UUID> = []
    @ObservationIgnored private var agentTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    /// File di progetto da aprire nell'editor (scheda File del progetto).
    var projectFileToOpen: String?
    /// Agente da modificare nel foglio dell'editor (nuovo o esistente).
    var editingAgent: AgentSpec?
    /// Sezione del dettaglio agente da aprire (es. 4 = Programmazioni).
    var agentTabRequest: Int?
    /// Chat chiesta chattando, da aprire quando la risposta attuale è finita.
    private var pendingChat: (request: ChatRequest, project: ProjectModel?)?
    /// Colonna destra con Siri AI+ (sempre presente, si può comprimere).
    var showAssistant = true
    /// Aumenta a ogni modifica di Calendario/Promemoria: le viste delle app si ricaricano.
    var storeRevision = 0
    /// Aumenta quando cambiano i file di un progetto o la sua memoria.
    var projectRevision = 0
    /// Aumenta mentre l'agente di coding cambia i file: l'anteprima si ricarica.
    var codeFilesRevision = 0
    /// Aumenta quando cambia la memoria generale.
    var memoryRevision = 0
    /// Aumenta quando cambiano le skill.
    var skillsRevision = 0
    /// Presentazione in riproduzione a schermo intero.
    var presenting: Deck?
    /// Scheda immagine che deve aprire subito il foglio di Image Playground.
    var imageSheetCardID: UUID?

    // MARK: Programmazione (coding)

    /// Conversazione di cui l'assistente ha la sessione (quella del pannello o una chat in una scheda).
    @ObservationIgnored var assistantConversationID: UUID?
    /// Schede con chat affiancate: scheda → conversazioni, da sinistra a destra.
    var chatTabs: [UUID: [UUID]] = AppState.savedChatTabs() {
        didSet { saveChatTabs() }
    }
    var codeSessions: [CodeSession] = []
    var currentCodeSessionID: UUID? {
        didSet { tabOwnerDidChange() }
    }
    /// Progetto di codice la cui sessione sta nella colonna destra: resta anche con le app davanti (Safari con l'anteprima).
    var codeContextProjectID: UUID? {
        didSet { tabOwnerDidChange() }
    }
    /// Ultimo modello scelto nella Programmazione: lo usano le sessioni nuove.
    var codeModel: ModelSelection? = (UserDefaults.standard.data(forKey: "codeModel")).flatMap { try? JSONDecoder().decode(ModelSelection.self, from: $0) } {
        didSet { if persists, let codeModel { UserDefaults.standard.set(try? JSONEncoder().encode(codeModel), forKey: "codeModel") } }
    }
    var devRuns: [UUID: DevRun] = [:]
    @ObservationIgnored var codeTasks: [UUID: Task<Void, Never>] = [:]
    /// Modello scelto per un nuovo progetto di codice (apre il foglio).
    var newCodeTemplate: CodeTemplate?
    /// Sessione di coding di cui aprire la revisione delle modifiche.
    var codeReviewSessionID: UUID?

    // MARK: Fonti

    var access = Access(calendar: false, reminders: false)
    var prefs: [SourceKind: SourcePref]
    var availabilityProblem: String?

    // MARK: Conversazioni e progetti

    var conversations: [Conversation] = []
    var currentID: UUID? {
        didSet { tabOwnerDidChange() }
    }
    var projects: [ProjectModel] = []
    var input = ""
    var picked: Set<SourceKind> = []
    var attachments: [Attachment] = []
    var isResponding = false
    var statusText = ""
    /// Quota della finestra di contesto occupata dalla conversazione corrente.
    var contextUsage: Double = 0

    // MARK: Artefatti, attività, orb, connettori

    var openArtifact: ArtifactModel?
    var activity: [ActivityEntry] = []
    var today: (events: Int, reminders: Int) = (0, 0)
    private var flash: OrbState?
    let dictation = Dictation()
    let mcp = MCPRegistry()
    /// Safari di ogni chat: la pagina aperta resta con la sua chat.
    @ObservationIgnored var browsers: [UUID: BrowserModel] = [:]
    @ObservationIgnored var browserUse: [UUID: Date] = [:]
    /// Pagina aperta nel Safari di ogni chat, per ritrovarla dopo il riavvio.
    @ObservationIgnored var browserPages: [String: String] = CommandLine.arguments.contains("--ephemeral")
        ? [:] : (UserDefaults.standard.dictionary(forKey: "browserPages") as? [String: String] ?? [:]) {
        didSet { if persists { UserDefaults.standard.set(browserPages, forKey: "browserPages") } }
    }
    /// La chat di cui si stanno mostrando le app.
    @ObservationIgnored var shownTabOwner: UUID?
    /// Il Safari della chat aperta.
    var browser: BrowserModel { browser(for: tabOwner) }
    /// Meteo della Home (Roma di serie).
    let weather = WeatherModel()

    /// Modello che scrive le risposte nella chat aperta (pianificazione e azioni restano su Apple Intelligence).
    /// Ogni chat ricorda il suo, con versione e ragionamento; le chat nuove prendono l'ultimo scelto nello spazio
    /// (o quello generale).
    var selection: ModelSelection {
        selectionOverride ?? current?.model ?? defaultSelection(for: space)
    }
    /// Modello della risposta in corso: resta quello della chat da cui è partita, anche se nel frattempo se ne apre un'altra.
    var activeSelection: ModelSelection { responseSelection ?? selection }
    var provider: ResponseProvider { activeSelection.provider }
    private var foregroundResponseSelection: ModelSelection?
    private var responseSelection: ModelSelection? {
        get { Self.independentResponse?.selection ?? foregroundResponseSelection }
        set {
            if let response = Self.independentResponse, let newValue { response.selection = newValue }
            else { foregroundResponseSelection = newValue }
        }
    }
    /// Diagnostica (`--provider gemma`, `--model`, `--effort`): modello usato solo in questa sessione.
    private var selectionOverride: ModelSelection?
    /// Diagnostica (`--ephemeral`): niente salvataggi su disco.
    @ObservationIgnored let persists = !CommandLine.arguments.contains("--ephemeral")
    var defaultProvider: ResponseProvider = ResponseProvider(rawValue: UserDefaults.standard.string(forKey: "responseProvider") ?? "") ?? .apple {
        didSet { UserDefaults.standard.set(defaultProvider.rawValue, forKey: "responseProvider") }
    }
    /// Il modello Apple effettivamente usato per le risposte; può tornare sul Mac se la cloud non è pronta.
    var appleResponseModel: AppleResponseModel = .onDevice

    // MARK: Spazi

    /// Spazio aperto: Personale, Lavoro o Programmazioni.
    var space: Space = AppState.initialSpace {
        didSet { if persists { UserDefaults.standard.set(space.rawValue, forKey: "space") } }
    }

    /// Spazio all'avvio (diagnostica: `--space codice` senza cambiare quello salvato).
    private static var initialSpace: Space {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--space"), index + 1 < args.count {
            let name = args[index + 1]
            return Space.allCases.first { "\($0)" == name || $0.rawValue == name } ?? .lavoro
        }
        return Space(rawValue: UserDefaults.standard.string(forKey: "space") ?? "") ?? .lavoro
    }
    var spaceSettings: [Space: SpaceSettings] = AppState.loadSpaces()

    func settings(for space: Space) -> SpaceSettings { spaceSettings[space] ?? SpaceSettings() }

    func updateSpace(_ space: Space, _ change: (inout SpaceSettings) -> Void) {
        change(&spaceSettings[space, default: SpaceSettings()])
        saveSpaces()
        if space == self.space { SpaceScope.global = scope(for: space) }
        storeRevision += 1
    }

    /// Filtri di calendario, promemoria e posta dello spazio (le Programmazioni usano quelli di Lavoro).
    func scope(for space: Space) -> SpaceScope {
        let settings = settings(for: space == .codice ? .lavoro : space)
        var scope = SpaceScope()
        scope.name = space.label
        scope.calendars = settings.calendars.map(Set.init)
        scope.reminderLists = settings.reminderLists.map(Set.init)
        scope.defaultCalendar = settings.defaultCalendar
        scope.defaultReminderList = settings.defaultReminderList
        scope.mailAccount = settings.mailAccount
        return scope
    }

    /// Il connettore è attivo in questo spazio?
    func spaceUses(_ serverID: UUID, in space: Space) -> Bool {
        settings(for: space).connectorIDs.map { $0.contains(serverID) } ?? true
    }

    /// Passa a un altro spazio: vista, conversazione, filtri e modello cambiano con lui.
    func switchSpace(_ newSpace: Space) {
        guard newSpace != space else { return }
        saveConversations()
        withAnimation(.smooth(duration: 0.3)) {
            space = newSpace
            openArtifact = nil
            section = .home
        }
        SpaceScope.global = scope(for: newSpace)
        // Ultima conversazione generale dello spazio, oppure una nuova.
        if let last = conversations.first(where: { ($0.space ?? Space.lavoro.rawValue) == newSpace.rawValue && $0.projectID == nil && $0.agentID == nil && $0.kind == .standard }) {
            currentID = last.id
            if !isResponding { prepareAssistant(for: last) }
        } else {
            let conversation = Conversation()
            conversation.space = newSpace.rawValue
            conversations.insert(conversation, at: 0)
            currentID = conversation.id
            if !isResponding { prepareAssistant(for: conversation) }
        }
        contextUsage = 0
        storeRevision += 1
        Task { await refreshToday() }
        log(icon: newSpace.symbol, title: "Spazio \(newSpace.label)", detail: "", status: .done)
    }

    private static func loadSpaces() -> [Space: SpaceSettings] {
        guard let data = try? Data(contentsOf: supportURL("spaces.json")),
              let decoded = try? JSONDecoder().decode([String: SpaceSettings].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in Space(rawValue: key).map { ($0, value) } })
    }

    func saveSpaces() {
        guard persists else { return }
        let encoded = Dictionary(uniqueKeysWithValues: spaceSettings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { try? data.write(to: Self.supportURL("spaces.json"), options: .atomic) }
    }
    /// Versione di Gemma 4 usata (id di `GemmaVariant`).
    var gemmaModel: String = GemmaVariant.variant(UserDefaults.standard.string(forKey: "gemmaVariant") ?? "")?.id ?? DeviceProfile.recommendedGemma.id {
        didSet { UserDefaults.standard.set(gemmaModel, forKey: "gemmaVariant") }
    }
    /// Sub-agent in parallelo: 0 = automatico in base al Mac.
    var subAgentSetting: Int = UserDefaults.standard.integer(forKey: "subAgents") {
        didSet { UserDefaults.standard.set(subAgentSetting, forKey: "subAgents") }
    }
    var subAgentLimit: Int { subAgentSetting > 0 ? subAgentSetting : DeviceProfile.recommendedSubAgents }
    var wantsPrivateCloud = UserDefaults.standard.bool(forKey: "preferPrivateCloudCompute") {
        didSet {
            UserDefaults.standard.set(wantsPrivateCloud, forKey: "preferPrivateCloudCompute")
            appleResponseModel = .preferred
            if provider == .apple { assistant.selectAppleResponseModel(appleResponseModel) }
        }
    }
    /// Finestra di contesto del modello che risponde.
    var contextBudget: ContextBudget {
        provider == .apple ? .apple(Self.independentResponse == nil ? appleResponseModel : AppleResponseModel.preferred) : .of(provider)
    }

    /// Modello cloud in attesa di conferma (ChatGPT o Claude: i dati escono dal Mac).
    var pendingCloud: ModelSelection?
    var askCloudConsent: Bool {
        get { pendingCloud != nil }
        set { if !newValue { pendingCloud = nil } }
    }

    // MARK: Modelli, versioni e ragionamento

    /// Una famiglia nel menu dei modelli: Apple Intelligence, Gemma (versioni scaricate), ds4, ChatGPT e Claude (versioni dell'account).
    struct ModelFamily: Identifiable {
        let provider: ResponseProvider
        let options: [ModelOption]
        var id: String { provider.rawValue }
        var symbol: String { AppState.symbol(for: provider) }
    }

    nonisolated static func symbol(for provider: ResponseProvider) -> String {
        switch provider {
        case .apple: "apple.logo"
        case .gemma: "cpu"
        case .ds4: "memorychip"
        case .chatgpt: "cloud"
        case .claude: "asterisk"
        }
    }

    /// Modelli pronti da usare: Apple sempre, gli altri solo se scaricati, installati o con l'accesso fatto.
    var modelFamilies: [ModelFamily] {
        var families = [ModelFamily(provider: .apple, options: [])]
        let gemma = modelOptions(for: .gemma)
        if !gemma.isEmpty { families.append(ModelFamily(provider: .gemma, options: gemma)) }
        if models.ds4Installed { families.append(ModelFamily(provider: .ds4, options: [])) }
        if models.codexInstalled && models.codexLoggedIn { families.append(ModelFamily(provider: .chatgpt, options: models.codexModels)) }
        if models.claudeInstalled && models.claudeLoggedIn { families.append(ModelFamily(provider: .claude, options: ModelCatalog.claude)) }
        return families
    }

    /// Versioni tra cui scegliere per un modello (anche se non è ancora pronto).
    func modelOptions(for provider: ResponseProvider) -> [ModelOption] {
        switch provider {
        case .gemma: models.downloadedVariants.map { ModelOption(id: $0.id, label: $0.label, efforts: ModelCatalog.gemmaEfforts, defaultEffort: "off") }
        case .chatgpt: models.codexModels
        case .claude: ModelCatalog.claude
        case .apple, .ds4: []
        }
    }

    /// Ultimo modello scelto in uno spazio (o quello generale).
    func defaultSelection(for space: Space) -> ModelSelection {
        let settings = spaceSettings[space]
        guard let provider = settings?.provider.flatMap(ResponseProvider.init) else { return ModelSelection(defaultProvider) }
        return ModelSelection(provider, model: settings?.model, effort: settings?.effort)
    }

    /// La scelta completa: versione e ragionamento predefiniti quando mancano (quelli della configurazione di Codex e di Claude Code),
    /// e un ragionamento che la versione accetta.
    func resolved(_ selection: ModelSelection) -> ModelSelection {
        var result = selection
        switch selection.provider {
        case .apple, .ds4:
            result.model = nil
            result.effort = nil
        case .gemma:
            let wanted = selection.model.flatMap(GemmaVariant.variant)
            result.model = (wanted?.isDownloaded == true ? wanted : nil)?.id ?? gemmaModel
            result.effort = ModelCatalog.gemmaEfforts.contains(selection.effort ?? "") ? selection.effort : "off"
        case .chatgpt, .claude:
            let options = modelOptions(for: selection.provider)
            let defaults = selection.provider == .chatgpt ? models.codexDefaults : models.claudeDefaults
            let fallback = selection.provider == .chatgpt ? options.first?.id : "opus"
            let model = selection.model ?? defaults.model ?? fallback
            // L'elenco di ChatGPT arriva da Codex: se non c'è ancora, si passa comunque la versione scelta.
            let option = options.first { $0.id == model }
            result.model = model
            result.effort = option.map { ModelCatalog.effort(selection.effort ?? defaults.effort, for: $0) } ?? selection.effort ?? defaults.effort
        }
        return result
    }

    /// Nome del modello con versione e ragionamento: «GPT-6-Sol · Alto», «Claude Opus · Massimo», «Gemma 4 E4B».
    func label(for selection: ModelSelection) -> String {
        let choice = resolved(selection)
        let option = modelOptions(for: choice.provider).first { $0.id == choice.model }
        let name: String = switch choice.provider {
        case .apple, .ds4: choice.provider.name
        case .gemma: GemmaVariant.variant(choice.model ?? "")?.label ?? choice.provider.name
        case .chatgpt: option?.label ?? choice.model ?? choice.provider.name
        case .claude: "Claude " + (option?.label ?? choice.model?.capitalized ?? "")
        }
        // Gemma: il ragionamento si nomina solo quando è acceso.
        if choice.provider == .gemma { return name + (choice.effort == "on" ? " · Ragionamento" : "") }
        return name + (choice.effort.map { " · " + ModelCatalog.effortLabel($0) } ?? "")
    }

    var activeModelLabel: String { provider == .apple ? appleResponseModel.label : label(for: activeSelection) }

    /// Sceglie il modello della chat aperta (e delle prossime chat dello spazio). Per ChatGPT e Claude chiede prima conferma.
    func choose(_ choice: ModelSelection) {
        let choice = resolved(choice)
        if !choice.provider.isLocal, selection.provider != choice.provider { pendingCloud = choice; return }
        apply(choice)
    }

    /// Usa il modello senza altre domande (dopo la conferma per quelli cloud).
    func apply(_ choice: ModelSelection) {
        let choice = resolved(choice)
        if choice.provider == .gemma, let variant = choice.model { gemmaModel = variant }
        current?.model = choice
        spaceSettings[space, default: SpaceSettings()].provider = choice.provider.rawValue
        spaceSettings[space, default: SpaceSettings()].model = choice.model
        spaceSettings[space, default: SpaceSettings()].effort = choice.effort
        saveSpaces()
        if current?.messages.isEmpty == false { saveConversations() }
        log(icon: Self.symbol(for: choice.provider), title: "Modello per le risposte", detail: label(for: choice), status: .done)
        preparePrivacyEngine()
    }

    /// Passa a un modello con la sua versione predefinita.
    func request(_ provider: ResponseProvider) {
        choose(ModelSelection(provider))
    }
    let models = ModelManager()
    let voice = VoiceMode()

    /// Menu «+» › Piano con sub-agent: la prossima richiesta diventa un compito a passi (catena di pensieri e sub-agent).
    var planNext = false
    /// Prima di inviare a ChatGPT e Claude tutto si anonimizza sul Mac con rizzo-pii (Impostazioni › Modelli). Acceso di serie.
    var cloudPrivacy: Bool = UserDefaults.standard.object(forKey: "cloudPrivacy") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(cloudPrivacy, forKey: "cloudPrivacy")
            preparePrivacyEngine()
        }
    }
    /// Categorie in più da nascondere a ChatGPT e Claude oltre ai dati personali (importi, date, aziende…): di serie nessuna,
    /// perché all'AI servono per lavorare.
    var cloudPrivacyExtra: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "cloudPrivacyExtra") ?? []) {
        didSet { UserDefaults.standard.set(cloudPrivacyExtra.sorted(), forKey: "cloudPrivacyExtra") }
    }
    /// Le categorie che diventano segnaposto.
    var privacyLabels: Set<String> { Set(PIICategory.sensitive).union(cloudPrivacyExtra) }
    /// La richiesta in corso non può andare al modello esterno (anonimizzazione non disponibile): risponde Apple Intelligence.
    @ObservationIgnored private var foregroundAppleOnly = false
    private var appleOnly: Bool {
        get { Self.independentResponse?.appleOnly ?? foregroundAppleOnly }
        set {
            if let response = Self.independentResponse { response.appleOnly = newValue }
            else { foregroundAppleOnly = newValue }
        }
    }
    @ObservationIgnored private var privacyIdle: Task<Void, Never>?
    /// Gemma, ds4, ChatGPT e Claude usano gli strumenti dell'app (altrimenti scrivono solo la risposta).
    var externalTools: Bool = UserDefaults.standard.object(forKey: "externalTools") as? Bool ?? true {
        didSet { UserDefaults.standard.set(externalTools, forKey: "externalTools") }
    }

    /// Ricerca sul web consentita (le domande escono dal Mac solo in questo caso).
    var webEnabled: Bool = UserDefaults.standard.object(forKey: "webSearch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(webEnabled, forKey: "webSearch") }
    }

    var compactionThreshold: Double {
        get { UserDefaults.standard.object(forKey: "compactionThreshold") as? Double ?? 0.75 }
        set { UserDefaults.standard.set(newValue, forKey: "compactionThreshold") }
    }

    private var foregroundAssistant = Assistant()
    private var assistant: Assistant { Self.independentResponse?.assistant ?? foregroundAssistant }
    private var responseTask: Task<Void, Never>?
    @ObservationIgnored private var independentTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var respondingConversationIDs: Set<UUID> = []
    @ObservationIgnored private var queuedIndependentRequests: [UUID: [(String, ModelSelection?, [Attachment])]] = [:]
    /// Conversazione a cui appartiene la risposta in corso: resta quella anche se nel frattempo se ne apre un'altra.
    private var responding: Conversation?
    /// Dove scrive la risposta in corso (o la conversazione aperta).
    private var out: Conversation? { Self.independentResponse?.conversation ?? responding ?? current }
    private var pendingSave: Task<Void, Never>?
    /// Numero di messaggi già indicizzati per conversazione (ricerca nelle conversazioni passate).
    @ObservationIgnored private var indexed: [UUID: Int] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        // Prima di leggere qualunque dato: passaggio dalla versione «SiriAI» (una volta sola).
        // Le prove automatiche (`--ephemeral`, `--selftest`) non toccano i dati.
        if !AppPaths.isTestEnvironment, !CommandLine.arguments.contains("--selftest"), !CommandLine.arguments.contains("--ephemeral") { Migration.runIfNeeded() }
        phase = AppPaths.isTestEnvironment || UserDefaults.standard.bool(forKey: "onboarded") ? .app : .onboarding
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--phase"), index + 1 < args.count {
            phase = args[index + 1] == "onboarding" ? .onboarding : args[index + 1] == "permissions" ? .permissions : .app
        }
        if persists { DataBackup.runDaily() }
        prefs = AppPaths.isTestEnvironment
            ? Dictionary(uniqueKeysWithValues: SourceKind.allCases.map { ($0, SourcePref(enabled: false, allowWrite: false)) })
            : Self.loadPrefs()
        activity = Self.loadActivity()
        projects = Self.loadProjects()
        agents = Self.loadAgents()
        codeSessions = Self.loadCodeSessions()
        Self.keepsRunning = agents.contains(where: \.isScheduled)
        let first = Conversation()
        first.space = space.rawValue
        conversations = [first] + Self.loadConversations()
        if persists { importRecoveredConversations() }
        currentID = first.id
        assistantConversationID = first.id
        // Chat affiancate salvate: solo quelle che esistono ancora (una scheda rimasta vuota riparte con una chat nuova).
        for (group, ids) in chatTabs {
            let alive = ids.filter { id in conversations.contains { $0.id == id } }
            if alive.isEmpty {
                let fresh = Conversation()
                fresh.space = space.rawValue
                conversations.append(fresh)
                chatTabs[group] = [fresh.id]
            } else if alive != ids {
                chatTabs[group] = alive
            }
        }
        restoreTabs(freshChat: first.id)
        SpaceScope.global = scope(for: space)
        Self.shared = self
        if persists {
            _ = quickConversation(for: .personale)
            _ = quickConversation(for: .lavoro)
        }
    }

    // MARK: - Avvio

    /// Istanza attiva (per la diagnostica avviata senza finestra).
    nonisolated(unsafe) static weak var shared: AppState?
    @ObservationIgnored private var started = false

    func start() async {
        guard !started else { return }
        started = true
        availabilityProblem = Agent.availabilityProblem
        if provider == .apple {
            appleResponseModel = .preferred
            assistant.selectAppleResponseModel(appleResponseModel)
        }
        let args = CommandLine.arguments
        if phase == .app { await refreshAccess() }
        // Diagnostica: `--section calendar` apre direttamente un'app.
        if let index = args.firstIndex(of: "--section"), index + 1 < args.count, let source = SourceKind(rawValue: args[index + 1]) {
            section = .app(source)
        }
        if let index = args.firstIndex(of: "--section"), index + 1 < args.count {
            switch args[index + 1] {
            case "browser": section = .browser
            case "agents": section = .agents
            case "agent": if let first = agents.first { section = .agent(first.id) }
            case "agent-schedule": if let first = agents.first { section = .agent(first.id); agentTabRequest = 4 }
            case "schedule": section = .schedule
            case "activity": section = .activity
            case "connectors": section = .connectors
            case "project": if let first = projects.first { section = .project(first.id) }
            default: break
            }
        }
        // Diagnostica (solo con --ephemeral): `--app-tabs calendar,mail,browser` apre delle schede nella sezione App (l'ultima resta davanti).
        if let list = AppTesting.value(after: "--app-tabs") {
            for key in list.split(separator: ",").map(String.init) {
                if let tab = AppTab(key: key) ?? SourceKind(rawValue: key).map(AppTab.app) { openTab(tab) }
            }
        }
        // Diagnostica (solo con --ephemeral): `--tab-sequence notes,home,apps` cambia scheda ogni 3 secondi
        // («home» torna alla chat, «apps» è il pulsante App): nel log ogni scheda deve risultare caricata una volta sola.
        if let list = AppTesting.value(after: "--tab-sequence") {
            Task { @MainActor [weak self] in
                for key in list.split(separator: ",").map(String.init) {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    switch key {
                    case "home": self.section = .home
                    case "apps": self.toggleApps()
                    case let key where key.hasPrefix("new:"):
                        if let kind = ArtifactKind(rawValue: String(key.dropFirst(4))) { self.newArtifact(kind) }
                    // Le app di ogni chat: «newchat» apre una chat nuova, «select:N» la chat N dell'elenco, «url:indirizzo» apre una pagina.
                    case "newchat": self.newConversation(in: nil)
                    case let key where key.hasPrefix("select:"):
                        if let index = Int(key.dropFirst(7)), self.conversations.indices.contains(index) { self.select(self.conversations[index]) }
                    case let key where key.hasPrefix("url:"):
                        if let url = URL(string: String(key.dropFirst(4))) { self.openInBrowser(url) }
                    // «chat»: una scheda con l'ultima chat con messaggi; «chat+»: un'altra chat accanto (le prime della cronologia).
                    case "chat":
                        self.newChatTab(with: self.conversations.first { !$0.messages.isEmpty && $0.agentID == nil && $0.id != self.currentID })
                    // «say:testo»: scrive nella prima chat della scheda davanti e, a risposta finita, la scrive nel log.
                    case let key where key.hasPrefix("say:"):
                        if case .chats(let group) = self.section, let chat = self.chats(in: group).first {
                            self.send(String(key.dropFirst(4)), in: chat)
                            while self.isResponding { try? await Task.sleep(for: .milliseconds(300)) }
                            for message in chat.messages.suffix(4) { Agent.log("DUMP AFFIANCATA " + Self.describe(message.content)) }
                            Agent.log("DUMP PANNELLO: \(self.current?.messages.count ?? 0) messaggi, sessione dell'assistente \(self.assistantConversationID == self.currentID ? "del pannello" : "di un'altra chat")")
                        }
                    case "chat+":
                        if case .chats(let group) = self.section {
                            let used = Set(self.chatTabs[group] ?? [])
                            self.addChat(to: group, conversation: self.conversations.first { !$0.messages.isEmpty && $0.agentID == nil && !used.contains($0.id) && $0.id != self.currentID })
                        }
                    default: if let tab = AppTab(key: key) ?? SourceKind(rawValue: key).map(AppTab.app) { self.selectTab(tab) }
                    }
                    Agent.log("PROVA SCHEDE: \(key) → \(self.section) · chat \(self.tabOwner?.uuidString.prefix(8) ?? "-") · schede \(self.appTabs.map(\.key)) · pagina \(self.browser.url?.absoluteString ?? self.browser.pendingURL?.absoluteString ?? "-")")
                }
            }
        }
        // Diagnostica: `--open-chat` apre l'ultima conversazione con messaggi (per fotografare la chat).
        if args.contains("--open-chat"), let chat = conversations.filter({ !$0.messages.isEmpty && $0.agentID == nil && $0.projectID == nil }).max(by: { $0.created < $1.created }) {
            select(chat)
        }
        // Diagnostica (solo con --ephemeral): storico di esempio per fotografare le schermate.
        if args.contains("--demo-history"), !persists, let first = agents.first {
            updateAgent(first.id) { spec in
                let routine = spec.routines.first
                let samples: [(Double, AgentRun.Trigger, AgentRun.Outcome, Int, Int, String)] = [
                    (-3_600, .programmata, .daApprovare, 3, 2, "Due email chiedono una risposta: ho preparato le bozze per Marco e per lo studio."),
                    (-90_000, .recupero, .completata, 4, 0, "Nessuna email urgente. Tre newsletter archiviate."),
                    (-96_000, .manuale, .errore, 1, 0, "Mail non ha risposto in tempo."),
                    (-180_000, .programmata, .interrotta, 2, 0, ""),
                ]
                for (offset, trigger, outcome, steps, approvals, summary) in samples {
                    let id = spec.beginRun(trigger, routine: trigger == .manuale ? nil : routine)
                    spec.updateRun(id) { run in
                        run.start = Date.now.addingTimeInterval(offset); run.end = run.start.addingTimeInterval(95)
                        run.outcome = outcome; run.steps = steps; run.approvals = approvals; run.summary = summary
                        run.errors = outcome == .errore ? 1 : 0
                    }
                }
            }
        }
        if let index = args.firstIndex(of: "--open-url"), index + 1 < args.count, let url = URL(string: args[index + 1]) {
            section = .browser
            browser.load(url)
        }
        if args.contains("--noassistant") { showAssistant = false }
        // Diagnostica (solo prove): `--app-focus files:/percorso` apre un elemento come farebbe «Apri» in una scheda della chat.
        if let value = AppTesting.value(after: "--app-focus"), let colon = value.firstIndex(of: ":"),
           let source = SourceKind(rawValue: String(value[..<colon])) {
            openInApp(source, reference: String(value[value.index(after: colon)...]))
        }
        // Diagnostica: `--open-project /percorso` collega e apre una cartella come progetto.
        if let index = args.firstIndex(of: "--open-project"), index + 1 < args.count {
            addProject(folder: URL(fileURLWithPath: args[index + 1]))
        }
        // Diagnostica: `--project-file CLAUDE.md` apre un file del progetto (nella sezione File, sul posto).
        if let file = AppTesting.value(after: "--project-file") { projectFileToOpen = file }
        // Diagnostica: `--open-preview` apre l'anteprima del progetto di codice aperto, nel Safari della sua sessione.
        if args.contains("--open-preview"), let project = openCodingProject {
            openPreview(project)
        }
        // A visual diagnostic must not run scheduled agents or connect external services.
        if !AppPaths.isTestEnvironment, !args.contains("--snapshot"), !args.contains("--ui-review") { mcp.startAll() }
        Task { await models.refresh() }
        preparePrivacyEngine()
        if persists, !AppPaths.isTestEnvironment { startAgentScheduler() }
        // Diagnostica: `--agent-test` fa lavorare un agente temporaneo, scrive il registro nel log ed esce.
        if args.contains("--agent-test") {
            var spec = AgentTemplate.all[0].spec
            spec.name = "Test agente"
            spec.routines = []
            if args.contains("--with-folder") {
                // Cartella collegata in sola lettura con un file da leggere.
                let folder = FileManager.default.temporaryDirectory.appending(path: "Appunti riunioni")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? "# Riunione lancio\n\n- Budget approvato: 12.000 €\n- Data di lancio: 15 ottobre\n- Responsabile: Giulia\n- Rischio: fornitore in ritardo\n"
                    .write(to: folder.appending(path: "riunione.md"), atomically: true, encoding: .utf8)
                spec.goal = "Leggi il file riunione.md nella cartella Appunti riunioni e riassumi decisioni e rischi."
                spec.allowWeb = false
                spec.folders = [AgentFolder(path: folder.path, writable: false)]
            }
            agents.append(spec)
            Task {
                let started = Date.now
                await performAgentRun(spec.id)
                if args.contains("--with-folder") {
                    dreamAgent(spec.id)
                    try? await Task.sleep(for: .seconds(1))
                    while runningAgents.contains(spec.id) { try? await Task.sleep(for: .milliseconds(300)) }
                    if let dream = agent(spec.id)?.dreams.last {
                        Agent.log("AGENTE SOGNO lezioni: \(dream.lessons) · istruzioni: \(dream.newInstructions.prefix(200))")
                    }
                    let soulText = (try? String(contentsOf: Self.soulURL(spec.id), encoding: .utf8)) ?? "(nessun file)"
                    Agent.log("AGENTE ANIMA (\(soulText.count) caratteri): \(soulText.suffix(400).replacingOccurrences(of: "\n", with: " ¶ "))")
                }
                for event in agent(spec.id)?.log ?? [] { Agent.log("AGENTE \(event.kind.rawValue): \(event.text.prefix(200))") }
                for run in agent(spec.id)?.history ?? [] {
                    Agent.log("AGENTE STORICO: \(run.trigger.rawValue) · \(run.outcome.rawValue) · \(run.steps) passi · \(run.approvals) da approvare · \(Int(run.duration ?? -1))s · \(run.summary.prefix(80))")
                }
                Agent.log("AGENTE DURATA: \(Int(Date.now.timeIntervalSince(started)))s")
                deleteAgent(spec.id)
                NSApp.terminate(nil)
            }
        }
        // Diagnostica: `--code-test chatgpt|claude|apple|gemma|ds4 "richiesta"` (con `--model` e `--effort`) crea un sito in una cartella
        // temporanea, fa lavorare l'agente e prova il ripristino. `codex` vale come `chatgpt`.
        if let index = args.firstIndex(of: "--code-test"), index + 2 < args.count,
           let chosen = args[index + 1] == "codex" ? .chatgpt : ResponseProvider(rawValue: args[index + 1]) {
            Task {
                await models.refresh()
                let value = { (flag: String) -> String? in args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
                codeModel = resolved(ModelSelection(chosen, model: value("--model"), effort: value("--effort")))
                Agent.log("CODE MODELLO: \(codeEngineLabel(codeDefault))")
                let parent = FileManager.default.temporaryDirectory.appending(path: "code-test-\(UUID().uuidString.prefix(6))")
                try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                createCodeProject(template: .sito, name: "Prova", description: args[index + 2], parent: parent)
                try? await Task.sleep(for: .seconds(1))
                while codeSessions.contains(where: \.running) { try? await Task.sleep(for: .milliseconds(500)) }
                if let session = codeSessions.last {
                    for event in session.events { Agent.log("CODE \(event.kind.rawValue) [\(event.status.rawValue)] \(event.text.prefix(160).replacingOccurrences(of: "\n", with: " ")) \(event.path ?? "") \(event.detail.prefix(160).replacingOccurrences(of: "\n", with: " "))") }
                    let folder = projects.last!.folder
                    Agent.log("CODE FILE: \((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])")
                    Agent.log("CODE AVVIO: \(DevCommand.detect(in: folder)?.label ?? "nessuno")")
                    if let first = session.events.first(where: { $0.kind == .user }) {
                        restoreCode(session, to: first)
                        try? await Task.sleep(for: .seconds(4))
                        Agent.log("CODE DOPO RIPRISTINO: \((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])")
                    }
                }
                NSApp.terminate(nil)
            }
        }
        if persists { digestYesterday() }
        // Diagnostica: `--provider gemma|ds4|chatgpt|claude` (con `--model` e `--effort`) sceglie il modello solo per questa sessione.
        if let index = args.firstIndex(of: "--provider"), index + 1 < args.count, let chosen = ResponseProvider(rawValue: args[index + 1]) {
            await models.refresh()
            let value = { (flag: String) -> String? in args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            selectionOverride = resolved(ModelSelection(chosen, model: value("--model"), effort: value("--effort")))
            Agent.log("MODELLO DI PROVA: \(label(for: selectionOverride!))")
        }
        // Diagnostica: `--prompt "testo"` invia subito una richiesta (con `--attach file` allega documenti o immagini);
        // con `--dump-and-quit` scrive la conversazione nel log ed esce.
        if let index = args.firstIndex(of: "--prompt"), index + 1 < args.count, phase == .app {
            await mcp.waitUntilReady()
            for (position, arg) in args.enumerated() where arg == "--attach" && position + 1 < args.count {
                attach([URL(fileURLWithPath: args[position + 1])])
            }
            // Più richieste separate da "||": una dopo l'altra, come in una conversazione.
            let prompts = args[index + 1].components(separatedBy: "||")
            for (number, prompt) in prompts.enumerated() {
                // `--plan`: come «Piano con sub-agent» dal menu «+» (catena di pensieri e sub-agent anche per richieste semplici).
                if args.contains("--plan") { planNext = true }
                send(prompt)
                if number < prompts.count - 1 { while isResponding { try? await Task.sleep(for: .milliseconds(300)) } }
            }
            if args.contains("--dump-and-quit") {
                while isResponding { try? await Task.sleep(for: .milliseconds(300)) }
                for message in current?.messages ?? [] { Agent.log("DUMP " + Self.describe(message.content)) }
                NSApp.terminate(nil)
            }
        }
        Hooks.didModify = { [weak self] in Task { @MainActor in self?.storeRevision += 1; await self?.refreshToday() } }
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: Store.shared.ek, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.storeRevision += 1; await self?.refreshToday() }
        })
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.saveConversations()
                    self?.saveProjects()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .app else { return }
                await self.refreshAccess()
                self.mcp.reconnectFailed()
                if self.persists { self.schedulerTick() }
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.persists else { return }
                self.schedulerTick()
                self.storeRevision += 1
            }
        })
    }

    func refreshAccess() async {
        if AppPaths.isTestEnvironment {
            access = Access(calendar: false, reminders: false)
            today = (0, 0)
            return
        }
        let calendarStatus = EKEventStore.authorizationStatus(for: .event)
        let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        if persists && (calendarStatus == .notDetermined && prefs[.calendar]?.enabled == true
            || reminderStatus == .notDetermined && prefs[.reminders]?.enabled == true) {
            access = await Agent.requestAccess()
        } else {
            access = Access(calendar: calendarStatus == .fullAccess, reminders: reminderStatus == .fullAccess)
        }
        await refreshToday()
    }

    func refreshToday() async {
        let cal = Calendar.current
        let events = isEnabled(.calendar) ? Overview.events().filter { $0.end > .now }.count : 0
        var reminders = 0
        if isEnabled(.reminders) {
            let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now))!
            reminders = await Overview.openReminders(limit: 300).filter { ($0.due ?? .distantFuture) < tomorrow }.count
        }
        today = (events, reminders)
    }

    /// Una volta al giorno riassume in memoria cosa è stato fatto ieri (senza chiamare il modello).
    private func digestYesterday() {
        let cal = Calendar.current
        let key = "lastDigest"
        let todayStart = cal.startOfDay(for: .now)
        if let last = UserDefaults.standard.object(forKey: key) as? Date, last >= todayStart { return }
        UserDefaults.standard.set(Date.now, forKey: key)
        let yesterday = cal.date(byAdding: .day, value: -1, to: todayStart)!
        let entries = activity.filter { $0.date >= yesterday && $0.date < todayStart && $0.status == .done }
        guard !entries.isEmpty else { return }
        let day = yesterday.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Dates.locale))
        let items = entries.prefix(6).map { "\($0.title.lowercased()) (\($0.detail.prefix(40)))" }.joined(separator: "; ")
        MemoryStore.shared.add("Il \(day) hai fatto: \(items).", source: "attività")
        memoryRevision += 1
    }

    // MARK: - Onboarding e permessi

    func finishOnboarding() {
        withAnimation(.smooth) { phase = .permissions }
    }

    func finishPermissions() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        withAnimation(.smooth) { phase = .app }
        Task { await refreshAccess() }
    }

    func restartOnboarding() {
        UserDefaults.standard.set(false, forKey: "onboarded")
        withAnimation(.smooth) { phase = .onboarding }
    }

    func setEnabled(_ source: SourceKind, _ enabled: Bool) {
        guard !AppPaths.isTestEnvironment else { return }
        guard source.support != .comingSoon else { return }
        prefs[source, default: SourcePref(enabled: false, allowWrite: true)].enabled = enabled
        savePrefs()
        log(icon: "source:\(source.rawValue)", title: enabled ? "\(source.label) collegato" : "\(source.label) scollegato",
            detail: "Permessi", status: .done)
        if enabled && (source == .calendar || source == .reminders) {
            Task {
                access = await Agent.requestAccess()
                await refreshToday()
            }
        } else if enabled && source == .notes {
            Task { _ = await NotesService.requestAccess() }
        } else if enabled && (source == .messages || source == .contacts) {
            Task { _ = await Contacts.requestAccess() }
        } else {
            Task { await refreshToday() }
        }
    }

    func setAllowWrite(_ source: SourceKind, _ allow: Bool) {
        guard !AppPaths.isTestEnvironment else { return }
        prefs[source, default: SourcePref(enabled: true, allowWrite: allow)].allowWrite = allow
        savePrefs()
    }

    func isEnabled(_ source: SourceKind) -> Bool {
        // Le app aggiunte dopo il primo avvio sono attive finché non le scolleghi: macOS chiede il permesso una volta sola.
        guard prefs[source]?.enabled ?? (source.support == .full) else { return false }
        switch source {
        case .calendar: return access.calendar
        case .reminders: return access.reminders
        case .mail, .notes, .files, .messages, .voiceMemos: return true
        case .contacts: return ContactsStore.authorized
        case .photos: return false
        }
    }

    func systemDenied(_ source: SourceKind) -> Bool {
        guard prefs[source]?.enabled ?? (source.support == .full) else { return false }
        if source == .contacts {
            let status = CNContactStore.authorizationStatus(for: .contacts)
            return status == .denied || status == .restricted
        }
        let type: EKEntityType
        switch source {
        case .calendar: type = .event
        case .reminders: type = .reminder
        default: return false
        }
        let status = EKEventStore.authorizationStatus(for: type)
        return status == .denied || status == .restricted
    }

    func canWrite(_ source: SourceKind) -> Bool { isEnabled(source) && prefs[source]?.allowWrite != false }

    var enabledSources: Set<SourceKind> { Set(SourceKind.allCases.filter(isEnabled)) }

    func openPrivacySettings(for source: SourceKind) {
        let pane = switch source {
        case .reminders: "Privacy_Reminders"
        case .contacts: "Privacy_Contacts"
        case .voiceMemos, .messages: "Privacy_AllFiles"
        default: "Privacy_Calendars"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func loadPrefs() -> [SourceKind: SourcePref] {
        if let data = UserDefaults.standard.data(forKey: "sourcePrefs"),
           let decoded = try? JSONDecoder().decode([String: SourcePref].self, from: data) {
            var prefs: [SourceKind: SourcePref] = [:]
            for (key, value) in decoded { if let kind = SourceKind(rawValue: key) { prefs[kind] = value } }
            return prefs
        }
        return [
            .calendar: SourcePref(enabled: true, allowWrite: true),
            .reminders: SourcePref(enabled: true, allowWrite: true),
            .mail: SourcePref(enabled: true, allowWrite: true),
        ]
    }

    private func savePrefs() {
        guard !AppPaths.isTestEnvironment else { return }
        let encoded = Dictionary(uniqueKeysWithValues: prefs.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { UserDefaults.standard.set(data, forKey: "sourcePrefs") }
    }

    // MARK: - Orb

    var orb: OrbState {
        if dictation.isListening { return .listening }
        if currentIsResponding { return .thinking }
        if let flash { return flash }
        if current?.messages.contains(where: \.isPending) == true { return .waiting }
        return .idle
    }

    var orbLabel: String {
        if let current, respondingConversationIDs.contains(current.id) { return "Risposta in corso…" }
        return currentIsResponding && !statusText.isEmpty ? statusText : orb.label
    }

    private func flash(_ state: OrbState) {
        flash = state
        Task {
            try? await Task.sleep(for: .seconds(state == .error ? 3 : 2))
            if flash == state { flash = nil }
        }
    }

    // MARK: - Conversazioni

    var current: Conversation? { conversations.first { $0.id == currentID } }

    /// Cronologia generale: conversazioni fuori dai progetti, le fissate in cima.
    var history: [Conversation] {
        let items = conversations.filter { !$0.messages.isEmpty && $0.projectID == nil && $0.agentID == nil && $0.kind == .standard
            && ($0.space ?? Space.lavoro.rawValue) == space.rawValue }
        return items.filter(\.pinned) + items.filter { !$0.pinned }
    }

    /// Una chat rapida stabile per ciascuno degli Spazi personali. Anche vuota viene salvata.
    func quickConversation(for selectedSpace: Space) -> Conversation {
        let quickSpace = selectedSpace == .codice ? Space.lavoro : selectedSpace
        if let existing = conversations.first(where: { $0.kind == .quick && $0.space == quickSpace.rawValue }) {
            if existing.model?.provider != .apple { existing.model = ModelSelection(.apple); saveConversations() }
            return existing
        }
        let conversation = Conversation(title: "Chat rapida")
        conversation.kind = .quick
        conversation.space = quickSpace.rawValue
        conversation.model = ModelSelection(.apple)
        conversations.append(conversation)
        saveConversations()
        return conversation
    }

    func tasks(for project: ProjectModel) -> [Conversation] {
        let items = conversations.filter { $0.projectID == project.id && (!$0.messages.isEmpty || $0.id == currentID) }
        return items.filter(\.pinned) + items.filter { !$0.pinned }
    }

    /// Nuova conversazione: dentro `project` è una sua task, altrimenti è generale (fuori dai progetti) e torna alla Home.
    func newConversation(in project: ProjectModel?) {
        saveConversations()
        let projectID = project?.id
        if let project {
            project.lastOpened = .now
            section = .project(project.id)
        } else {
            openArtifact = nil
            section = .home
        }
        if let current, current.messages.isEmpty, current.projectID == projectID, current.agentID == nil,
           (current.space ?? Space.lavoro.rawValue) == space.rawValue { return }
        let conversation = Conversation(projectID: projectID)
        conversation.space = space.rawValue
        conversations.insert(conversation, at: 0)
        currentID = conversation.id
        if !isResponding { prepareAssistant(for: conversation) }
        contextUsage = 0
    }

    /// Dal menu della chat: nuova task se si sta lavorando in un progetto, altrimenti conversazione generale.
    /// Nuova chat dal pannello: nello stesso progetto, senza lasciare ciò che è aperto al centro (app, documenti, browser).
    /// Con un'app davanti la chat nuova parte con le stesse app (poi ognuna va per conto suo): al centro non sparisce nulla.
    func newConversationHere() {
        let keep = section
        let tabs = appTabs, last = lastAppTab, page = browser.url ?? browser.pendingURL
        newConversation(in: currentProject)
        if keep.appTab != nil, appTabs.isEmpty {
            appTabs = tabs
            lastAppTab = last
            if let page, tabs.contains(.browser) { browser.pendingURL = page }
        }
        if section != keep { section = keep }
    }

    func delete(_ conversation: Conversation) {
        let removedID = conversation.id.uuidString
        Task.detached(priority: .utility) { ConversationIndex.shared.remove(id: removedID) }
        forgetTabs(of: conversation.id)
        if responding?.id == conversation.id { responseTask?.cancel() }
        independentTasks[conversation.id]?.cancel()
        queuedIndependentRequests[conversation.id] = nil
        if conversation.id == currentID { currentID = nil }
        conversations.removeAll { $0.id == conversation.id }
        if currentID == nil {
            let fresh = Conversation(projectID: conversation.projectID)
            fresh.space = conversation.space ?? space.rawValue
            conversations.insert(fresh, at: 0)
            currentID = fresh.id
            if !isResponding { prepareAssistant(for: fresh) }
            contextUsage = 0
        }
        saveConversations()
    }

    func togglePin(_ conversation: Conversation) {
        conversation.pinned.toggle()
        saveConversations()
    }

    /// La colonna destra con Siri AI+ compare solo quando al centro è aperto qualcosa.
    var showsSidePanel: Bool { showAssistant && section != .home }

    func select(_ conversation: Conversation) {
        // Una conversazione generale scelta mentre si è in un progetto si apre alla Home.
        if conversation.projectID == nil, case .project = section { section = .home }
        guard conversation.id != currentID else { return }
        saveConversations()
        currentID = conversation.id
        if !isResponding { prepareAssistant(for: conversation) }
        contextUsage = 0
        showAssistant = true
    }

    /// L'assistente prende la sessione di una conversazione: i suoi scambi e, per le chat figlie, il contesto della madre.
    func prepareAssistant(for conversation: Conversation?) {
        assistant.reset()
        if let conversation {
            let turns = Self.turns(of: conversation)
            if !turns.isEmpty { assistant.restore(turns) }
            assistant.inherited = conversation.inherited
        }
        assistantConversationID = conversation?.id
    }

    /// Scrive in una chat che non è quella del pannello (una chat affiancata in una scheda): stessa strada, stessi modelli.
    func send(_ text: String, in conversation: Conversation, using oneTimeSelection: ModelSelection? = nil,
              files: [Attachment] = []) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, availabilityProblem == nil else { return }
        if conversation.kind == .quick || conversation.id != currentID || isResponding {
            if isResponding(in: conversation), independentTasks[conversation.id] == nil { return }
            if independentTasks[conversation.id] != nil {
                queuedIndependentRequests[conversation.id, default: []].append((prompt, oneTimeSelection, files))
                conversation.messages.append(Message(content: .notice("Richiesta in coda: verrà eseguita dopo la risposta attuale.")))
                saveConversations()
                return
            }
            let session = Assistant()
            let cloudRetry = conversation.kind == .quick && oneTimeSelection?.provider.isLocal == false
            // Il tentativo cloud della chat rapida invia solo la richiesta mostrata nell'anteprima.
            if !cloudRetry { session.restore(Self.turns(of: conversation)) }
            session.inherited = conversation.inherited
            if conversation.messages.isEmpty, conversation.title == "Nuova conversazione" { conversation.title = Self.title(from: prompt) }
            conversation.messages.append(Message(content: .user(text: prompt, sources: [], attachments: files.map(\.name))))
            saveConversations()
            let chosen = resolved(oneTimeSelection ?? (conversation.kind == .quick
                ? ModelSelection(.apple) : conversation.model ?? defaultSelection(for: space(of: conversation))))
            if conversation.model == nil, oneTimeSelection == nil { conversation.model = chosen }
            runIndependent(prompt, in: conversation, assistant: session, selection: chosen, files: files, cloudRetry: cloudRetry)
            return
        }
        if assistantConversationID != conversation.id { prepareAssistant(for: conversation) }
        // Il titolo viene dalla prima richiesta, ma non sostituisce quello scelto (chat figlie, chat create con un nome).
        if conversation.messages.isEmpty, conversation.title == "Nuova conversazione" { conversation.title = Self.title(from: prompt) }
        conversation.messages.append(Message(content: .user(text: prompt, sources: [], attachments: files.map(\.name))))
        saveConversations()
        run(prompt, sources: [], files: files, in: conversation, oneTimeSelection: oneTimeSelection)
    }

    func isResponding(in conversation: Conversation) -> Bool {
        respondingConversationIDs.contains(conversation.id) || (isResponding && responding?.id == conversation.id)
    }

    var currentIsResponding: Bool { current.map { isResponding(in: $0) } ?? false }
    func isQuickResponding(_ conversation: Conversation) -> Bool { isResponding(in: conversation) }

    private func runIndependent(_ prompt: String, in conversation: Conversation, assistant session: Assistant,
                                selection: ModelSelection, files: [Attachment], sources: Set<SourceKind> = [],
                                plan: Bool = false, cloudRetry: Bool = false) {
        let context = IndependentResponse(conversation: conversation, assistant: session, selection: selection)
        let scope = scope(for: space(of: conversation))
        respondingConversationIDs.insert(conversation.id)
        independentTasks[conversation.id] = Task {
            await Self.$independentResponse.withValue(context) {
                let shield = privacyShield(for: conversation, provider: selection.provider)
                await PrivacyShield.$current.withValue(shield) {
                    if !cloudRetry {
                        await syncWorkContext(files: files, prompt: prompt)
                        assistant.updateScreen()
                        guard !Task.isCancelled else { return }
                        await SpaceScope.$task.withValue(scope) {
                            await respond(to: prompt, sources: sources, files: files, plan: plan)
                        }
                    } else {
                        await respondQuickCloud(prompt, selection: selection)
                    }
                }
                conversation.messages.removeAll { if case .thinking = $0.content { true } else { false } }
                if let report = shield?.takeReport() { conversation.messages.append(Message(content: .privacy(report))) }
                if !Task.isCancelled {
                    recordLastTurn(prompt)
                    if MemoryStore.shared.enabled, Assistant.mayContainMemory(prompt) {
                        for fact in await assistant.memoryWorthy(prompt) where MemoryStore.shared.add(fact, source: "chat") {
                            conversation.messages.append(Message(content: .notice("Ricordato: «\(fact)».")))
                            memoryRevision += 1
                        }
                    }
                    if !cloudRetry {
                        await PrivacyShield.$current.withValue(shield) { await compactIfNeeded() }
                    }
                }
                saveConversations()
            }
            independentTasks[conversation.id] = nil
            respondingConversationIDs.remove(conversation.id)
            if !Task.isCancelled, conversations.contains(where: { $0.id == conversation.id }),
               var queued = queuedIndependentRequests[conversation.id], !queued.isEmpty {
                let next = queued.removeFirst()
                queuedIndependentRequests[conversation.id] = queued.isEmpty ? nil : queued
                send(next.0, in: conversation, using: next.1, files: next.2)
            } else if Task.isCancelled {
                queuedIndependentRequests[conversation.id] = nil
            }
        }
    }

    /// I due testi mostrati nell'anteprima cloud. Non vengono allegati cronologia o strumenti.
    /// Nessuna cronologia, memoria, app, connettore, file o strumento viene passato alla CLI esterna.
    static let quickCloudSystemPrompt = "Sei Siri AI+. Rispondi in italiano alla richiesta dell'utente. Non puoi accedere alle app o ai file del Mac."

    private func respondQuickCloud(_ prompt: String, selection: ModelSelection) async {
        let system = Self.quickCloudSystemPrompt
        let stream: AsyncThrowingStream<String, Error> = selection.provider == .chatgpt
            ? ExternalEngine.streamChatGPT(system: system, history: [], prompt: prompt, model: selection.model, effort: selection.effort)
            : ExternalEngine.streamClaude(system: system, history: [], prompt: prompt, model: selection.model, effort: selection.effort)
        setThinking("\(selection.provider.name) sta rispondendo…")
        var answerID: UUID?
        do {
            for try await text in stream {
                guard !Task.isCancelled else { break }
                if let answerID, let index = out?.messages.firstIndex(where: { $0.id == answerID }) {
                    out?.messages[index].content = .text(text)
                } else {
                    out?.messages.removeAll { if case .thinking = $0.content { true } else { false } }
                    let message = Message(content: .text(text))
                    out?.messages.append(message)
                    answerID = message.id
                }
            }
            if Task.isCancelled { append(.notice("Risposta interrotta.")) }
            else if answerID == nil { append(.notice("Il modello non ha restituito una risposta.")) }
        } catch {
            append(.notice(answerID == nil ? "Risposta non riuscita: \(error.localizedDescription)" : "Risposta parziale: \(error.localizedDescription)"))
        }
    }

    /// La conversazione che sta ricevendo una risposta (per mostrare «sta scrivendo» nella colonna giusta).
    var respondingID: UUID? { isResponding ? (responding ?? current)?.id : nil }

    /// Scambi utente/assistente di una conversazione salvata (per riprenderla in modo coerente).
    static func turns(of conversation: Conversation) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for message in conversation.messages {
            switch message.content {
            case .user(let text, _, _): turns.append(ChatTurn(role: .user, text: text))
            case .text(let text):
                if let last = turns.last, last.role == .assistant { turns[turns.count - 1].text += "\n" + text }
                else { turns.append(ChatTurn(role: .assistant, text: text)) }
            case .chatLink(let link) where link.summary != nil:
                turns.append(ChatTurn(role: .assistant, text: "Riepilogo della chat «\(link.title)»: \(link.summary ?? "")"))
            default: break
            }
        }
        return turns
    }

    private func recordLastTurn(_ prompt: String) {
        guard let messages = out?.messages,
              let userIndex = messages.lastIndex(where: { if case .user = $0.content { true } else { false } }) else { return }
        let reply = messages[(userIndex + 1)...].compactMap { message -> String? in
            if case .text(let text) = message.content { return text }
            return nil
        }.joined(separator: "\n")
        assistant.record(user: prompt, reply: reply.isEmpty ? "(azione mostrata in una scheda)" : reply)
    }

    private func append(_ content: Message.Content) {
        out?.messages.append(Message(content: content))
    }

    // MARK: - Progetti

    /// Progetto della conversazione corrente, oppure quello aperto al centro.
    var currentProject: ProjectModel? {
        if let conversation = Self.independentResponse?.conversation {
            return conversation.projectID.flatMap { id in projects.first { $0.id == id } }
        }
        // Durante una risposta vale la chat che risponde (anche una chat affiancata in una scheda).
        if let responding, responding.id != currentID { return responding.projectID.flatMap { id in projects.first { $0.id == id } } }
        if let id = current?.projectID { return projects.first { $0.id == id } }
        if case .project(let id) = section { return projects.first { $0.id == id } }
        return nil
    }

    /// Progetti dello spazio aperto (nelle Programmazioni si vedono quelli di Lavoro).
    /// La Home mostra la panoramica sul cielo del meteo (niente aurora dietro).
    var homeShowsSky: Bool {
        section == .home && space != .codice && (current?.messages.isEmpty ?? true)
    }

    var sortedProjects: [ProjectModel] {
        let visible = projects.filter { ($0.space ?? Space.lavoro.rawValue) == space.rawValue }
        return visible.filter(\.pinned).sorted { $0.name < $1.name } + visible.filter { !$0.pinned }.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Agenti dello spazio aperto (nelle Programmazioni tutti).
    var spaceAgents: [AgentSpec] {
        space == .codice ? [] : agents.filter { $0.space == space.rawValue }
    }

    func addProject(folder: URL) {
        if let existing = projects.first(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) {
            openProject(existing)
            return
        }
        let project = ProjectModel(name: folder.lastPathComponent, folder: folder)
        project.space = space.rawValue
        projects.append(project)
        saveProjects()
        log(icon: "folder", title: "Progetto collegato", detail: folder.path, status: .done)
        openProject(project)
        newConversation(in: project)
    }

    func openProject(_ project: ProjectModel) {
        project.lastOpened = .now
        if project.exists { project.files.ensureMemoryFile() }
        section = .project(project.id)
        if current?.projectID != project.id {
            if let task = tasks(for: project).first { select(task) } else { newConversation(in: project) }
        }
        saveProjects()
    }

    func removeProject(_ project: ProjectModel) {
        projects.removeAll { $0.id == project.id }
        conversations.removeAll { $0.projectID == project.id }
        if current == nil {
            let fresh = Conversation()
            fresh.space = space.rawValue
            conversations.insert(fresh, at: 0)
            currentID = fresh.id
            prepareAssistant(for: fresh)
            contextUsage = 0
        }
        if case .project(let id) = section, id == project.id { section = .home }
        saveProjects()
        saveConversations()
    }

    func togglePin(_ project: ProjectModel) {
        project.pinned.toggle()
        saveProjects()
    }

    /// Le istruzioni del progetto per la sintesi di Apple Intelligence: AGENTS.md, CLAUDE.md e GEMINI.md insieme (senza ripetizioni).
    func agentsText(for project: ProjectModel) -> String {
        let combined = ProjectGuide.shared(for: project.folder).instructions(limit: 12_000)
        return combined.isEmpty ? (project.files.agentsURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "") : combined
    }

    /// Salvataggio esplicito dall'editor di AGENTS.md.
    func saveAgents(_ text: String, for project: ProjectModel) {
        let url = project.files.agentsURL ?? project.folder.appending(path: "AGENTS.md")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            project.agentsSignature = nil
            log(icon: "doc.text", title: "AGENTS.md aggiornato", detail: project.name, status: .done)
            showToast("AGENTS.md salvato")
            projectRevision += 1
        } catch {
            log(icon: "doc.text", title: "AGENTS.md non salvato", detail: error.localizedDescription, status: .failed)
        }
    }

    static func agentsTemplate(for name: String) -> String {
        """
        # \(name)

        ## Obiettivo
        Descrivi in due righe a cosa serve questo progetto.

        ## Come deve lavorare Siri AI+
        - Rispondi in italiano, in modo sintetico.
        - Prima di modificare un file mostrami cosa cambia.
        - Salva i documenti nella cartella `documenti/`.

        ## Contesto utile
        - Persone coinvolte:
        - Scadenze importanti:
        """
    }

    func saveProjects() {
        guard persists else { return }
        guard let data = try? JSONEncoder().encode(projects.map(\.stored)) else { return }
        try? data.write(to: Self.supportURL("projects.json"), options: .atomic)
    }

    private static func loadProjects() -> [ProjectModel] {
        guard let data = try? Data(contentsOf: supportURL("projects.json")),
              let stored = SafeJSON.decodeArray(StoredProject.self, from: data, label: "projects.json") else { return [] }
        return stored.map(ProjectModel.init)
    }

    // MARK: - Contesto per il modello

    /// Aggiorna progetto, AGENTS.md, memoria, artefatto aperto e strumenti prima di ogni richiesta.
    /// I testi dentro le azioni (risposte email, paragrafi, note, documenti…) li scrive il modello scelto; con Apple Intelligence
    /// (o se l'altro non risponde) li scrive Apple Intelligence.
    func configureWriter() {
        let chosen = resolved(activeSelection)
        guard let base = ExternalEngine.writer(for: chosen) else {
            assistant.textWriter = nil
            assistant.textWriterName = nil
            return
        }
        assistant.textWriterName = label(for: chosen)
        assistant.textWriter = { [weak self] instructions, request, partial in
            // Gemma gira sul Mac: prima di scrivere il server dev'essere avviato.
            if chosen.provider == .gemma, let self {
                guard let variant = GemmaVariant.variant(chosen.model ?? self.gemmaModel), variant.isDownloaded, await self.models.ensureGemma(variant) else {
                    throw AppleAppError.script("Gemma non è pronta")
                }
            }
            return try await base(instructions, request, partial)
        }
    }

    private func syncWorkContext(files: [Attachment] = [], prompt: String = "") async {
        configureWriter()
        let responseSpace = Self.independentResponse.map { space(of: $0.conversation) } ?? space
        let quickResponse = Self.independentResponse?.conversation.kind == .quick
        var work = WorkContext()
        if let project = currentProject, project.exists {
            // L'albero della cartella si legge in secondo piano mentre si prepara il resto (la prima volta 1–2 secondi).
            ProjectGuide.shared(for: project.folder).prefetch()
            work.projectName = project.name
            work.projectRoot = project.folder
            work.allowFileWrite = project.allowWrite
            work.projectMemory = project.files.memoryFacts()
            let agents = agentsText(for: project)
            let signature = Self.signature(agents)
            if project.agentsSignature != signature {
                setThinking("Leggo AGENTS.md…")
                project.agentsDigest = agents.isEmpty ? nil : await assistant.condense(agents: agents)
                project.agentsSignature = signature
                saveProjects()
            }
            work.agents = project.agentsDigest
            // MEMORY.md: creato se manca, sintetizzato se lungo (come AGENTS.md).
            project.files.ensureMemoryFile()
            let memory = project.files.memoryText()
            let memorySignature = Self.signature(memory)
            if project.memorySignature != memorySignature {
                setThinking("Leggo MEMORY.md…")
                project.memoryDigest = memory.isEmpty ? nil : await assistant.condense(agents: memory)
                project.memorySignature = memorySignature
                saveProjects()
            }
            work.memoryDigest = project.memoryDigest
        }
        if !quickResponse, case .artifact = section, let artifact = openArtifact {
            work.fullArtifactContextOnApple = provider == .apple
            work.artifactKind = artifact.kind.noun.lowercased()
            work.artifactTitle = artifact.title
            work.artifactSummary = artifact.contextSummary
            // Struttura e selezione: servono alle modifiche precise ("cancella il corpo", "elimina la slide 3").
            switch artifact.content {
            case .document:
                let (current, live) = liveDocument(of: artifact)
                work.openDocument = DocumentBridge.outline(of: current, selection: live?.selectedRange())
                work.artifactText = current.string
            case .deck(let deck):
                work.openDeck = deck
                work.openDeckSlide = min(EditorBridge.selectedSlide[artifact.id] ?? 0, max(0, deck.slides.count - 1))
                work.artifactText = deck.slides.enumerated().map { "\($0.offset + 1). \($0.element.title)\n\($0.element.bodyText)" }.joined(separator: "\n")
            case .sheet(let spreadsheet):
                let index = min(EditorBridge.sheetIndex[artifact.id] ?? 0, max(0, spreadsheet.sheets.count - 1))
                if spreadsheet.sheets.indices.contains(index) {
                    work.openSheet = spreadsheet.sheets[index]
                    work.openSheetIndex = index
                    work.artifactText = "Foglio «\(spreadsheet.sheets[index].name)»:\n" + spreadsheet.sheets[index].summary(maxRows: 60)
                }
            }
        }
        // Nei progetti solo i connettori scelti per quel progetto.
        let project = currentProject
        work.mcpTools = mcp.allTools.filter { (project?.uses($0.serverID) ?? true) && spaceUses($0.serverID, in: responseSpace) }
        work.projectNames = projects.map(\.name)
        work.spaceName = responseSpace.label
        work.spaceInstructions = settings(for: responseSpace).instructions
        if !quickResponse, section == .schedule || section == .agents {
            // Nella panoramica delle programmazioni la chat conosce agenti, orari e approvazioni.
            let lines = agents.map { agent -> String in
                let routines = agent.routines.filter(\.enabled).map { $0.schedule.label + ($0.task.isEmpty ? "" : " (\($0.task))") }.joined(separator: ", ")
                let next = agent.nextRun.map { "prossima \(Dates.friendly($0))" } ?? "nessuna in programma"
                return "- \(agent.displayName) [\(Space(rawValue: agent.space)?.label ?? "")]\(agent.active ? "" : " in pausa"): \(routines.isEmpty ? "solo manuale" : routines); \(next); sogna alle \(agent.dreamHour):00; da approvare \(pendingApprovals(for: agent))"
            }
            // Dati che cambiano spesso: vanno nella richiesta, non nelle istruzioni (altrimenti la sessione ripartirebbe a ogni turno).
            work.turnNotes = "Agenti e programmazioni:\n" + (lines.isEmpty ? "nessun agente" : lines.joined(separator: "\n"))
        }
        let selectedAppleModel: AppleResponseModel = provider == .apple ? .preferred : .onDevice
        assistant.selectAppleResponseModel(selectedAppleModel)
        if Self.independentResponse == nil { appleResponseModel = selectedAppleModel }
        assistant.budget = contextBudget
        if let agent = currentAgent { rememberInstruction(for: agent) }
        work.hasConversation = (out?.messages.filter { if case .user = $0.content { true } else { false } }.count ?? 0) > 1
        let allowedServers = Set(work.mcpTools.map(\.serverName))
        work.mcpInstructions = mcp.instructions.filter { allowedServers.contains($0.key) }
        work.webEnabled = webEnabled
        work.conversationID = out?.id.uuidString
        if !files.isEmpty {
            var texts = files.filter { $0.imageURL == nil }.map { "Allegato «\($0.name)»:\n\($0.text.prefix(contextBudget.scaled(1200)))" }
            let images = files.compactMap { file in file.imageURL.map { (name: file.name, url: $0) } }.prefix(4)
            // Descrizione delle immagini: serve ai modelli che non le vedono e alle azioni ("crea un evento da questa locandina").
            // Per le sole domande sull'immagine Apple Intelligence la guarda direttamente, senza passaggi in più.
            let acting = assistant.asksForAction(prompt)
            if provider != .apple || acting {
                for image in images {
                    setThinking("Guardo «\(image.name)»…")
                    guard let description = await assistant.describeImage(image.url) else { continue }
                    texts.append("Immagine «\(image.name)» (descritta da Apple Intelligence):\n\(description)")
                    assistant.remember("Immagine allegata «\(image.name)»: \(description)")
                }
            }
            work.attachments = texts.isEmpty ? nil : texts.joined(separator: "\n\n")
            work.images = provider == .apple ? images.map(\.url) : []
        }
        if !quickResponse, case .browser = section, let page = await browser.snapshot() {
            work.browserURL = page.url
            work.browserTitle = page.title
            work.browserText = page.text.isEmpty ? nil : page.text
            work.browserLinks = page.links
        }
        // Ciò che l'utente ha davanti nelle app e le altre schede aperte.
        work.screen = quickResponse ? nil : screenItem
        work.openTabs = quickResponse ? [] : appTabs.filter { $0 != section.appTab && $0 != .launcher }.compactMap(tabSummary)
        assistant.work = work
    }

    // MARK: - Invio

    var canSend: Bool {
        availabilityProblem == nil && current != nil && !currentIsResponding
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(_ text: String? = nil) {
        let prompt = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        if let conversation = current, conversation.kind == .quick, !prompt.isEmpty {
            input = ""
            send(prompt, in: conversation)
            return
        }
        guard !prompt.isEmpty, availabilityProblem == nil, let conversation = current,
              !isResponding(in: conversation) else { return }
        // In una chat figlia «concludi» o «torna alla chat madre» la chiudono e portano il riepilogo nella madre.
        if conversation.parentID != nil, !conversation.returned, parent(of: conversation) != nil, ChildChat.asksToReturn(prompt) {
            input = ""
            returnToParent()
            return
        }
        if dictation.isListening { dictation.stop() }
        showAssistant = true
        input = ""
        let sources = Array(picked).sorted { $0.rawValue < $1.rawValue }
        let files = attachments
        // Il titolo viene dalla prima richiesta, ma non sostituisce quello scelto (chat figlie, chat create con un nome).
        if conversation.messages.isEmpty, conversation.title == "Nuova conversazione" { conversation.title = Self.title(from: prompt) }
        conversation.messages.append(Message(content: .user(text: prompt, sources: sources, attachments: files.map(\.name))))
        saveConversations()
        picked = []
        attachments = []
        let plan = planNext
        planNext = false
        if isResponding {
            let session = Assistant()
            session.restore(Array(Self.turns(of: conversation).dropLast()))
            session.inherited = conversation.inherited
            let chosen = resolved(selectionOverride ?? conversation.model ?? defaultSelection(for: space(of: conversation)))
            if conversation.model == nil, selectionOverride == nil { conversation.model = chosen }
            runIndependent(prompt, in: conversation, assistant: session, selection: chosen,
                           files: files, sources: Set(sources), plan: plan)
        } else {
            run(prompt, sources: Set(sources), files: files, plan: plan)
        }
    }

    private func run(_ prompt: String, sources: Set<SourceKind>, files: [Attachment], in target: Conversation? = nil,
                     plan: Bool = false, oneTimeSelection: ModelSelection? = nil) {
        guard let conversation = target ?? current else { return }
        isResponding = true
        statusText = "Capisco la richiesta…"
        responding = conversation
        // La chat tiene il modello con cui è cominciata (versione e ragionamento compresi); una chat affiancata ha il suo.
        let chosen = oneTimeSelection ?? selectionOverride ?? conversation.model ?? defaultSelection(for: space(of: conversation))
        if conversation.model == nil, selectionOverride == nil, oneTimeSelection == nil { conversation.model = resolved(chosen) }
        responseSelection = resolved(chosen)
        let scope = scope(for: space(of: conversation))
        responseTask = Task {
            await syncWorkContext(files: files, prompt: prompt)
            assistant.updateScreen()
            guard !Task.isCancelled else { finishResponse(); return }
            // Calendari, liste e posta dello spazio valgono per tutta la richiesta (anche per i sub-agent); con ChatGPT e
            // Claude anche lo scudo della chat: tutto si anonimizza sul Mac prima di partire, e le risposte tornano leggibili.
            let shield = privacyShield(for: conversation, provider: responseSelection?.provider ?? .apple)
            await PrivacyShield.$current.withValue(shield) {
                await SpaceScope.$task.withValue(scope) {
                    await respond(to: prompt, sources: sources, files: files, plan: plan)
                }
            }
            conversation.messages.removeAll { if case .thinking = $0.content { true } else { false } }
            if let report = shield?.takeReport() {
                conversation.messages.append(Message(content: .privacy(report)))
                Agent.log("ANONIMIZZAZIONE: \(report.total) dati verso \(report.destination) (\(report.summary))")
            }
            if shield != nil { scheduleEngineRelease() }
            // Se nel frattempo è stata aperta un'altra chat, la sessione del modello non è più di questa conversazione.
            let stillOpen = conversation.id == assistantConversationID && !Task.isCancelled
            if stillOpen { recordLastTurn(prompt) }
            // Preferenze dette in chat ("preferisco…", "d'ora in poi…"): si salvano nella memoria, con un avviso discreto.
            if stillOpen, MemoryStore.shared.enabled, Assistant.mayContainMemory(prompt) {
                for fact in await assistant.memoryWorthy(prompt) where MemoryStore.shared.add(fact, source: "chat") {
                    conversation.messages.append(Message(content: .notice("Ricordato: «\(fact)». Puoi modificarlo in Attività › Memoria.")))
                    memoryRevision += 1
                }
            }
            if stillOpen, let pending = pendingChat {
                pendingChat = nil
                finishResponse()
                openRequestedChat(pending.request, project: pending.project)
                return
            }
            pendingChat = nil
            if stillOpen { await PrivacyShield.$current.withValue(shield) { await compactIfNeeded() } }
            finishResponse()
        }
    }

    private func finishResponse() {
        // Only restore a newly selected chat after the cancelled model operation has unwound.
        if let responding, responding.id != currentID {
            prepareAssistant(for: current)
            contextUsage = 0
        }
        isResponding = false
        statusText = ""
        responseTask = nil
        responding = nil
        responseSelection = nil
        saveConversations()
    }

    /// Compattazione automatica quando la chat supera la soglia della finestra di contesto.
    private func compactIfNeeded() async {
        statusText = "Controllo il contesto…"
        // Con qualunque modello: gli scambi usciti dalla finestra che il modello riceve (la sua, più grande con Gemma, ChatGPT e
        // Claude) li riassume il sub-agent della compattazione; al modello arrivano il riassunto e gli ultimi scambi.
        // Con un modello esterno, se la conversazione arriva comunque alla soglia, restano solo gli ultimi scambi.
        var result = await assistant.compactIfNeeded(threshold: compactionThreshold)
        if result == nil, provider != .apple, contextUsage >= compactionThreshold {
            result = await assistant.compactTurns(usage: contextUsage)
        }
        if let result {
            // Gli scambi usciti dalla finestra entrano nel riassunto senza interrompere la chat: la conversazione continua uguale.
            Agent.log("CHAT: \(result.exchanges) scambi nel riassunto (contesto dal \(Int(result.before * 100))% al \(Int(result.after * 100))%)")
            for fact in result.facts {
                if let project = currentProject { _ = try? project.files.remember(fact) } else { MemoryStore.shared.add(fact, source: "compattazione") }
            }
            if !result.facts.isEmpty { memoryRevision += 1; projectRevision += 1 }
            log(icon: "rectangle.compress.vertical", title: "Riassunto della conversazione aggiornato",
                detail: "\(current?.title ?? "") · \(result.exchanges) \(result.exchanges == 1 ? "scambio" : "scambi") · sub-agent"
                    + (result.pieces > 1 ? " (\(result.pieces) pezzi in parallelo)" : ""), status: .done)
        }
        // Con un modello esterno l'anello misura la sua finestra (aggiornato dopo ogni risposta).
        if provider == .apple { contextUsage = assistant.contextUsage } else if result != nil { updateExternalUsage(prompt: "", reply: "") }
    }

    /// Compattazione manuale dal menu della colonna Siri AI+.
    func compactNow() {
        guard !isResponding else { return }
        isResponding = true
        Task {
            if let result = await assistant.compactIfNeeded(threshold: 0) {
                append(.notice("Conversazione compattata: \(result.exchanges) \(result.exchanges == 1 ? "scambio" : "scambi") nel riassunto, contesto dal \(Int(result.before * 100))% al \(Int(result.after * 100))%."))
            }
            contextUsage = assistant.contextUsage
            isResponding = false
        }
    }

    func stop() {
        if let current { stop(current) }
        if dictation.isListening { dictation.stop() }
    }

    func stop(_ conversation: Conversation) {
        if let task = independentTasks[conversation.id] { task.cancel() }
        else if responding?.id == conversation.id { responseTask?.cancel() }
    }

    /// Spazio a cui appartiene una conversazione (quella di un agente o di un progetto segue il loro).
    func space(of conversation: Conversation) -> Space {
        if let id = conversation.agentID, let agent = agent(id) { return Space(rawValue: agent.space) ?? .lavoro }
        if let id = conversation.projectID, let project = projects.first(where: { $0.id == id }) { return Space(rawValue: project.space ?? "") ?? .lavoro }
        return Space(rawValue: conversation.space ?? "") ?? .lavoro
    }

    /// Conversazione che contiene una scheda.
    func conversation(containing card: AnyObject) -> Conversation? {
        conversations.first { $0.messages.contains { $0.content.card === card } }
    }

    /// Filtri dello spazio della conversazione in cui è nata la scheda: vale anche se nel frattempo si è cambiato spazio.
    func scope(forCard card: AnyObject) -> SpaceScope {
        conversation(containing: card).map { scope(for: space(of: $0)) } ?? scope(for: space)
    }

    /// Firma stabile di un testo (tra un avvio e l'altro, a differenza di `hashValue`).
    static func signature(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func title(from prompt: String) -> String {
        let words = prompt.split(separator: " ").prefix(6).joined(separator: " ")
        return words.count < prompt.count ? words + "…" : words
    }

    private func setThinking(_ text: String) {
        if Self.independentResponse == nil || Self.independentResponse?.conversation.id == currentID { statusText = text }
        if let index = out?.messages.lastIndex(where: { if case .thinking = $0.content { true } else { false } }) {
            out?.messages[index].content = .thinking(text)
        } else {
            append(.thinking(text))
        }
    }

    private func respond(to prompt: String, sources: Set<SourceKind>, files: [Attachment], plan: Bool = false) async {
        // Modelli esterni con gli strumenti: decidono loro cosa leggere o preparare; se non rispondono, si torna ad Apple Intelligence.
        // I comandi che le regole dell'app sanno decidere ("sposta la riunione…", "cancella tutto e scrivi…", "la seconda")
        // li esegue l'app con qualunque modello scelto: è più sicuro e più rapido. Il modello scelto scrive le risposte.
        let handledByApp = assistant.decidedByRules(prompt)
        // Anonimizzazione accesa ma motore mancante: niente parte verso ChatGPT o Claude, risponde Apple Intelligence sul Mac.
        appleOnly = PrivacyShield.current != nil && !PIIEngine.isInstalled
        defer { appleOnly = false }
        if appleOnly {
            append(.notice("Non ho inviato niente a \(provider.name): il motore di anonimizzazione rizzo-pii non è installato (Impostazioni › Modelli › Privacy). Rispondo con Apple Intelligence sul Mac."))
            assistant.textWriter = nil
        }
        // Compiti complessi (o piano chiesto dal menu «+»): catena di pensieri e sub-agent con qualunque modello, non solo con Apple.
        // Con Gemma, ds4, ChatGPT e Claude il sub-agent smistatore (Apple Intelligence sul Mac) sceglie prima gli strumenti da dare
        // al modello e dice se il compito va diviso in passi; con Apple Intelligence lo fa `Assistant.handle`.
        if provider != .apple, externalTools, !appleOnly, !handledByApp || plan {
            let route = await routeExternal(prompt)
            let wantsPlan = plan || (!handledByApp && !assistant.pointsAtScreen && (Assistant.isComplex(prompt) || route?.multiStep == true))
            if wantsPlan, await respondWithPlan(prompt) { return }
            if !handledByApp, await respondWithTools(prompt, route: route) { return }
        }
        // Il pianificatore lavora sulla sola richiesta: il testo degli allegati entra nella risposta (preambolo).
        assistant.forcePlan = plan
        defer { assistant.forcePlan = false }
        let outcome = await assistant.handle(prompt, enabled: enabledSources, picked: sources) { [weak self] status in
            self?.setThinking(status)
        }
        guard !Task.isCancelled else { return append(.notice("Risposta interrotta.")) }
        if var trace = assistant.trace, trace.isInteresting {
            trace.model = provider == .apple ? provider.label : label(for: activeSelection)
            append(.trace(trace))
        }
        await present(outcome, prompt: prompt, files: files)
    }

    /// Mostra un esito del motore: risposta in streaming, schede da confermare, artefatti, piani.
    private func present(_ outcome: Outcome, prompt: String, files: [Attachment] = []) async {
        switch outcome {
        case .combined(let items):
            // Le letture dei passaggi intermedi restano visibili come schede; la risposta arriva con l'ultimo esito.
            for item in items.dropLast() {
                switch item {
                case .agenda(let agenda, _): append(.agenda(agenda))
                case .items(let rows, _): append(.items(rows))
                case .files(let entries, _): append(.files(entries.prefix(40).map { ($0.isDirectory ? "📁 " : "") + $0.path }))
                case .web(let answer, _): append(.web(answer))
                case .message(let text): append(.text(text))
                default: break
                }
            }
            if let last = items.last { await present(last, prompt: prompt, files: files) }

        case .reply(let text):
            let fromMemory = assistant.answeredFromMemory
            let reply = await stream(text)
            // Chat di un progetto: se il modello non sa, si cerca prima nei file del progetto (poi, se non c'è niente, sul web).
            if fromMemory, files.isEmpty, !Task.isCancelled, Assistant.soundsUnsure(reply.text), currentProject != nil {
                setThinking("Cerco nei file del progetto…")
                if let grounded = await assistant.projectSearchAnswer(assistant.lastRequest.isEmpty ? prompt : assistant.lastRequest) {
                    if reply.text.count < 220, let id = reply.id { out?.messages.removeAll { $0.id == id } }
                    await stream(grounded)
                    return
                }
            }
            // Il modello ammette di non sapere (fatti recenti, prezzi, notizie…): si cerca sul web e si risponde con le fonti.
            if fromMemory, webEnabled, files.isEmpty, !Task.isCancelled, Assistant.soundsUnsure(reply.text) {
                // Una risposta breve che dice solo "non lo so" si toglie; una risposta utile resta e la ricerca va sotto.
                let onlyUnsure = reply.text.count < 220
                if onlyUnsure, let id = reply.id { out?.messages.removeAll { $0.id == id } }
                setThinking("Cerco sul web…")
                do {
                    let request = assistant.lastRequest.isEmpty ? prompt : assistant.lastRequest
                    let web = try await assistant.searchWeb(request, prompt: request) { [weak self] status in self?.setThinking(status) }
                    if case .web(let answer, let grounded) = web {
                        append(.web(answer))
                        await stream(grounded)
                        log(icon: "globe", title: "Ricerca sul web", detail: answer.query, status: .done)
                    } else if case .message(let text) = web {
                        if onlyUnsure { append(.text(reply.text)) }
                        append(.notice(text))
                    }
                } catch {
                    if onlyUnsure { append(.text(reply.text)) }
                    append(.notice(error.localizedDescription))
                }
            }

        case .web(let answer, let text):
            append(.web(answer))
            await stream(text)
            log(icon: "globe", title: answer.kind == .search ? "Ricerca sul web" : "Pagina letta", detail: answer.kind == .search ? answer.query : (answer.sources.first?.url ?? ""), status: .done)

        case .browse(let command):
            await browse(command)

        case .items(let items, let text):
            append(.items(items))
            await stream(text)
            log(icon: "source:\(items.source.rawValue)", title: items.title, detail: "\(items.rows.count) risultati", status: .done)

        case .noteDraft(let draft):
            guard canWrite(.notes) else { return readOnly(.notes, prompt) }
            append(.text("Ecco la nota. Controllala e creala quando è pronta."))
            append(.note(NoteCardModel(draft)))

        case .messageDraft(let draft):
            guard canWrite(.messages) else { return readOnly(.messages, prompt) }
            append(.text("Ho preparato il messaggio. Parte solo quando premi «Invia» e confermi."))
            append(.imessage(MessageCardModel(draft)))

        case .website(let draft):
            let card = WebsiteCardModel(draft, projectID: currentProject?.id)
            if let project = currentProject {
                guard project.allowWrite else {
                    append(.text("Nel progetto posso solo leggere i file: attiva la scrittura nelle impostazioni del progetto."))
                    return
                }
                append(.text("Ecco la pagina «\(draft.title)». Controlla l'anteprima e crea i file nel progetto: poi si apre nel browser."))
                append(.website(card))
            } else {
                append(.text("Ecco la pagina «\(draft.title)». Controlla l'anteprima e creala: la salvo in Documenti e si apre nel browser."))
                append(.website(card))
            }

        case .agentDraft(let spec):
            append(.text("Ecco l'agente che ho preparato. Controllalo e crealo: lavorerà da solo e ti chiederà conferma prima delle azioni importanti."))
            append(.agentDraft(AgentDraftCardModel(spec)))

        case .newChat(let request):
            let project = request.project.flatMap { name in projects.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
            let where_ = project.map { " nel progetto «\($0.name)»" } ?? ""
            append(.text(request.child
                ? "Apro la chat figlia «\(request.title)»\(where_). Quando hai finito, premi «Concludi e invia alla chat madre» e il riepilogo torna qui."
                : "Apro la nuova chat «\(request.title)»\(where_)."))
            // Si apre appena finisce questa risposta (la richiesta in corso appartiene alla chat attuale).
            pendingChat = (request, project)

        case .taskPlan(let plan):
            let card = TaskPlanCardModel(plan, parallel: subAgentLimit)
            append(.taskPlan(card))
            await runTaskPlan(card)

        case .agenda(let agenda, let text):
            append(.agenda(agenda))
            await stream(text)

        case .message(let text):
            append(.text(text))

        case .unavailable(let source, let reason):
            let kind: UnavailableKind = switch reason {
            case .comingSoon: .comingSoon
            case .notConnected: .notConnected
            case .notSelected: .notSelected
            }
            append(.unavailable(UnavailableCardModel(source: source, kind: kind, prompt: prompt)))
            flash(.error)

        case .eventDraft(let draft):
            guard canWrite(.calendar) else { return readOnly(.calendar, prompt) }
            append(.text("Ecco l'evento. Controlla i dettagli e salvalo quando è tutto a posto."))
            append(.event(EventCardModel(draft)))

        case .reminderDrafts(let drafts, let list):
            guard canWrite(.reminders) else { return readOnly(.reminders, prompt) }
            append(.text(drafts.count == 1 ? "Ecco il promemoria da aggiungere." : "Ecco \(drafts.count) promemoria. Togli quelli che non ti servono prima di aggiungerli."))
            append(.reminders(RemindersCardModel(drafts, list: list)))

        case .confirm(let action):
            let source: SourceKind = if case .deleteEvent = action.kind { .calendar } else { .reminders }
            guard canWrite(source) else { return readOnly(source, prompt) }
            append(.confirm(ConfirmCardModel(action)))

        case .eventEdit(let edit):
            guard canWrite(.calendar) else { return readOnly(.calendar, prompt) }
            append(.text("Ecco la modifica di «\(edit.before.title)». Controllala e salvala quando è tutto a posto."))
            append(.event(EventCardModel(edit.after, edit: edit)))

        case .reminderEdit(let edit):
            guard canWrite(.reminders) else { return readOnly(.reminders, prompt) }
            append(.text("Ecco il promemoria «\(edit.before.title)» con le modifiche. Salvale quando è tutto a posto."))
            append(.reminders(RemindersCardModel([edit.after], list: edit.afterList, edit: edit)))

        case .noteAppend(let draft):
            guard canWrite(.notes) else { return readOnly(.notes, prompt) }
            append(.text(draft.manual ? "La nota «\(draft.title)» ha liste o allegati che Note perderebbe se la modificassi da qui: ti preparo il testo da incollare."
                                      : "Ecco cosa aggiungo in fondo alla nota «\(draft.title)». Conferma e lo scrivo."))
            append(.noteAppend(NoteAppendCardModel(draft)))

        case .mailReply(let reply):
            append(.text("Ho preparato la risposta. Rivedila: si apre in Mail nella stessa conversazione e parte solo quando premi Invia."))
            append(.mail(MailCardModel(reply: reply)))

        case .mailForward(let draft):
            append(.text("Ecco l'inoltro. Si apre in Mail con gli allegati e parte solo quando premi Invia."))
            append(.forward(MailForwardCardModel(draft)))

        case .mailDraft(let draft):
            append(.text("Ho preparato la bozza. Rivedila: l'invio parte solo da Mail, dopo la tua conferma."))
            append(.mail(MailCardModel(draft)))

        case .document(let draft):
            present(ArtifactModel(kind: .pages, title: draft.title, content: .document(ArtifactFactory.document(from: draft))),
                    intro: "Ho scritto il documento: è aperto al centro, pronto da modificare.")

        case .sheet(let draft):
            present(ArtifactModel(kind: .numbers, title: draft.title, content: .sheet(Spreadsheet(from: draft))),
                    intro: "Ecco il foglio, con formule e grafico collegati ai dati.")

        case .deck(let draft):
            present(ArtifactModel(kind: .keynote, title: draft.title, content: .deck(Deck(from: draft))),
                    intro: "Ho preparato la presentazione: puoi modificare testi, posizioni e ordine delle slide.")

        case .plan(let plan):
            append(.text("Ecco il piano che ho preparato. Controllalo: non faccio nulla finché non confermi."))
            append(.plan(PlanCardModel(plan)))

        case .image(let imagePrompt, let style):
            let card = ImageCardModel(prompt: imagePrompt, style: style ?? "animazione")
            append(.image(card))
            await generate(card)

        case .remembered(let fact, let inProject):
            append(.text(inProject ? "Salvato nella memoria del progetto: «\(fact)»." : "Me lo ricorderò: «\(fact)»."))
            memoryRevision += 1
            projectRevision += 1
            log(icon: "brain", title: "Memoria aggiornata", detail: fact, status: .done)

        case .files(let entries, let text):
            append(.files(entries.prefix(40).map { ($0.isDirectory ? "📁 " : "") + $0.path }))
            await stream(text)

        case .fileWrite(let draft):
            append(.text(draft.exists ? "Ecco le modifiche a «\(draft.path)». Controllale prima di salvarle." : "Ecco il nuovo file «\(draft.path)». Controllalo prima di crearlo."))
            append(.fileWrite(FileWriteCardModel(draft, projectID: currentProject?.id)))

        case .fileOp(let draft):
            append(.fileOp(FileOpCardModel(draft, projectID: currentProject?.id)))

        case .mcpCall(let draft):
            let card = MCPCallCardModel(draft)
            append(.mcp(card))
            if mcp.isAlwaysAllowed(draft.tool) { await runMCP(card) }

        case .artifactEdit(let edit):
            applyArtifactEdit(edit)

        case .writeDocument(let topic):
            await writeDocument(about: topic)
        }
    }

    /// Comandi al browser integrato dalla chat.
    private func browse(_ command: BrowseCommand) async {
        withAnimation(.smooth(duration: 0.3)) { section = .browser }
        switch command {
        case .open(let url):
            browser.load(url)
            append(.text("Ho aperto \(url.host() ?? url.absoluteString) nel browser."))
        case .search(let query):
            if query.isEmpty {
                append(.text("Ecco il browser: dimmi cosa cercare o quale sito aprire."))
            } else {
                browser.search(query)
                append(.text("Ho cercato «\(query)» nel browser."))
            }
        case .back:
            browser.back()
            append(.text("Sono tornato alla pagina precedente."))
        case .follow(let text):
            if let clicked = await browser.follow(text) {
                append(.text("Ho aperto «\(clicked)»."))
            } else {
                append(.text("Non trovo un link «\(text)» in questa pagina."))
            }
        }
        log(icon: "safari", title: "Browser", detail: browser.address, status: .done)
    }

    private func readOnly(_ source: SourceKind, _ prompt: String) {
        append(.unavailable(UnavailableCardModel(source: source, kind: .readOnly, prompt: prompt)))
        flash(.error)
    }

    private func present(_ artifact: ArtifactModel, intro: String) {
        artifact.projectID = currentProject?.id
        append(.text(intro))
        append(.artifact(artifact))
        log(icon: "artifact:\(artifact.kind.rawValue)", title: "\(artifact.kind.noun) creat\(artifact.kind.ending)", detail: artifact.title, status: .done)
        open(artifact)
    }

    /// La colonna destra arriva dalla chat della Home (si sposta) invece di entrare dal bordo.
    var chatMovesFromHome = false

    func open(_ artifact: ArtifactModel) {
        // Dalla Home con una conversazione la chat scivola nella colonna destra (vedi `section`).
        withAnimation(.smooth(duration: 0.45)) {
            openArtifact = artifact
            section = .artifact(artifact.id)
        }
    }

    func closeArtifact() {
        withAnimation(.smooth(duration: 0.45)) {
            // Il documento è una scheda: si chiude come le altre (si passa alla vicina, o si torna da dove eri).
            if let artifact = openArtifact, appTabs.contains(.document(artifact.id)) {
                closeTab(.document(artifact.id))
            } else {
                openArtifact = nil
                section = currentProject.map { .project($0.id) } ?? .home
            }
        }
    }

    /// Crea un artefatto vuoto da modificare a mano.
    func newArtifact(_ kind: ArtifactKind) {
        let artifact: ArtifactModel = switch kind {
        case .pages: ArtifactModel(kind: .pages, title: "Documento senza titolo", content: .document(ArtifactFactory.blankDocument(title: "Documento senza titolo")))
        case .numbers: ArtifactModel(kind: .numbers, title: "Foglio senza titolo", content: .sheet(Spreadsheet(title: "Foglio senza titolo", sheets: [Sheet(name: "Foglio 1", columns: 8, rows: 30)])))
        case .keynote: ArtifactModel(kind: .keynote, title: "Presentazione senza titolo", content: .deck(Deck(title: "Presentazione senza titolo", slides: [.make(.titolo, title: "Titolo della presentazione", subtitle: "Sottotitolo")])))
        }
        artifact.projectID = currentProject?.id
        if let current, current.messages.isEmpty { current.title = artifact.title }
        append(.artifact(artifact))
        open(artifact)
        saveConversations()
    }

    /// Tutti gli artefatti delle conversazioni, dal più recente.
    var allArtifacts: [ArtifactModel] {
        conversations.flatMap { conversation in
            conversation.messages.compactMap { message in
                if case .artifact(let artifact) = message.content { artifact } else { nil }
            }
        }
    }

    @discardableResult
    private func stream(_ prompt: String, allowRetry: Bool = true) async -> (id: UUID?, text: String) {
        var prompt = prompt
        if provider != .apple, !appleOnly {
            if let result = await streamExternal(prompt) {
                updateExternalUsage(prompt: prompt, reply: result.text)
                return result
            }
            append(.notice("\(label(for: activeSelection)) non è disponibile: rispondo con Apple Intelligence."))
            // Il prompt era pensato per una finestra più grande: per Apple Intelligence va accorciato.
            if prompt.count > 9_000 { prompt = String(prompt.prefix(6_000)) + "\n…\n" + String(prompt.suffix(2_500)) }
        }
        var messageID: UUID?
        var final = ""
        do {
            // Spazio per la risposta: se la finestra è quasi piena si compatta prima, invece di fallire a metà.
            let fitted = await assistant.fitPrompt(prompt) { [weak self] status in self?.setThinking(status) }
            if let compaction = fitted.compaction {
                append(.notice("Conversazione compattata per fare spazio alla risposta: contesto dal \(Int(compaction.before * 100))% al \(Int(compaction.after * 100))%."))
            }
            // Temperatura e forma dipendono dalla richiesta: confronti in tabella, procedure in passi, fatti con poca fantasia.
            final = try await assistant.answer(fitted.prompt) { text in
                if let messageID, let index = out?.messages.firstIndex(where: { $0.id == messageID }) {
                    out?.messages[index].content = .text(text)
                } else {
                    out?.messages.removeAll { if case .thinking = $0.content { true } else { false } }
                    let message = Message(content: .text(text))
                    messageID = message.id
                    out?.messages.append(message)
                }
            }
        } catch let error as LanguageModelError {
            switch error {
            case .contextSizeExceeded where allowRetry:
                append(.notice("Contesto pieno: compatto la conversazione e riprovo."))
                _ = await assistant.compactIfNeeded(threshold: 0)
                return await stream(prompt, allowRetry: false)
            case .guardrailViolation:
                append(.notice("Richiesta bloccata dai filtri di sicurezza di Apple."))
            case .refusal:
                append(.notice("Il modello ha rifiutato la richiesta."))
            default:
                if assistant.appleResponseModel == .privateCloud, !Task.isCancelled {
                    return await retryOnDevice(prompt, removing: messageID, because: error)
                }
                append(.notice(error.localizedDescription))
            }
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize where allowRetry:
                append(.notice("Contesto pieno: compatto la conversazione e riprovo."))
                _ = await assistant.compactIfNeeded(threshold: 0)
                return await stream(prompt, allowRetry: false)
            case .guardrailViolation:
                append(.notice("Richiesta bloccata dai filtri di sicurezza di Apple."))
            case .refusal:
                append(.notice("Il modello ha rifiutato la richiesta."))
            default:
                if assistant.appleResponseModel == .privateCloud, !Task.isCancelled {
                    return await retryOnDevice(prompt, removing: messageID, because: error)
                }
                append(.notice(error.localizedDescription))
            }
        } catch {
            if assistant.appleResponseModel == .privateCloud, !Task.isCancelled {
                return await retryOnDevice(prompt, removing: messageID, because: error)
            }
            append(.notice(Task.isCancelled ? "Risposta interrotta." : error.localizedDescription))
        }
        return (messageID, final)
    }

    private func retryOnDevice(_ prompt: String, removing partialID: UUID?, because error: Error) async -> (id: UUID?, text: String) {
        Agent.log("PRIVATE CLOUD COMPUTE: ripiego sul Mac (\(error))")
        if let partialID { out?.messages.removeAll { $0.id == partialID } }
        assistant.selectAppleResponseModel(.onDevice)
        appleResponseModel = .onDevice
        append(.notice("Private Cloud Compute non è disponibile: continuo con il modello Apple sul Mac."))
        return await stream(prompt, allowRetry: false)
    }

    // MARK: - Immagini

    private var imageFolder: URL {
        (currentProject?.folder ?? ArtifactFactory.defaultFolder).appending(path: "Immagini")
    }

    func generate(_ card: ImageCardModel) async {
        card.status = .running
        card.error = nil
        setThinking("Disegno con Image Playground…")
        do {
            let urls = try await ImageService.generate(prompt: card.prompt, style: card.style, count: 2, folder: imageFolder) { [assistant] text in
                await assistant.englishImagePrompt(text)
            }
            card.paths = urls.map(\.path)
            card.status = .done
            log(icon: "photo", title: "Immagine creata", detail: card.prompt, status: .done)
            flash(.done)
            projectRevision += 1
        } catch ImageService.ServiceError.unavailable {
            // macOS 27: niente generazione diretta, si usa il foglio di sistema con la descrizione già pronta.
            card.status = .awaiting
            imageSheetCardID = card.id
        } catch {
            card.status = .failed
            card.error = error.localizedDescription
            Agent.log("ERRORE IMMAGINE: \(error) — \(error.localizedDescription)")
            flash(.error)
        }
    }

    /// Immagine scelta nel foglio di Image Playground: la copia nella cartella giusta e la aggiunge alla scheda.
    func adopt(_ url: URL, into card: ImageCardModel) {
        if let saved = keepImage(url) {
            card.paths.append(saved.path)
            card.status = .done
            log(icon: "photo", title: "Immagine creata", detail: card.prompt, status: .done)
            flash(.done)
            projectRevision += 1
            saveConversations()
        }
    }

    /// Copia un'immagine temporanea di Image Playground nella cartella Immagini (del progetto o di Siri AI+).
    func keepImage(_ url: URL) -> URL? {
        let folder = imageFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "Image Playground \(Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")) \(UUID().uuidString.prefix(4)).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)"
        let destination = folder.appending(path: name)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    func regenerate(_ card: ImageCardModel) {
        Task { await generate(card) }
    }

    /// Per gli editor: genera una sola immagine e ne restituisce il file.
    func quickImage(prompt: String, style: String = "illustrazione") async throws -> URL {
        let urls = try await ImageService.generate(prompt: prompt, style: style, count: 1, folder: imageFolder) { [assistant] text in
            await assistant.englishImagePrompt(text)
        }
        log(icon: "photo", title: "Immagine creata", detail: prompt, status: .done)
        guard let url = urls.first else { throw ImageService.ServiceError.nothing }
        return url
    }

    /// La versione di Gemma scelta, con il server acceso (nil, con un avviso in chat, se non è pronta).
    private func readyGemma(_ chosen: ModelSelection) async -> GemmaVariant? {
        guard let variant = GemmaVariant.variant(chosen.model ?? gemmaModel), variant.isDownloaded else {
            append(.notice("Gemma non è ancora scaricata: scaricala in Impostazioni › Modelli."))
            return nil
        }
        setThinking("Avvio \(variant.label)…")
        guard await models.ensureGemma(variant) else {
            append(.notice(models.errors["gemma-start"] ?? "Per usare Gemma serve llama.cpp: installalo in Impostazioni › Modelli."))
            return nil
        }
        return variant
    }

    /// Risposta scritta da Gemma, ds4, ChatGPT o Claude con le stesse istruzioni e la conversazione recente. Nil se il modello non risponde.
    private func streamExternal(_ prompt: String) async -> (id: UUID?, text: String)? {
        let system = assistant.chatInstructions()
        let chosen = resolved(activeSelection)
        // Tutta la conversazione che sta nella finestra del modello scelto.
        let history = fitting(assistant.historyTurns, characters: contextBudget.historyCharacters)
        if chosen.provider == .gemma {
            guard let variant = await readyGemma(chosen) else { return nil }
            setThinking("\(variant.label) sta scrivendo…")
        }
        let stream: AsyncThrowingStream<String, Error> = switch chosen.provider {
        case .gemma: ExternalEngine.streamOpenAICompatible(base: ExternalEngine.gemmaURL, model: "gemma", system: system, history: history, prompt: prompt,
                                                           thinking: chosen.effort == "on")
        case .ds4: ExternalEngine.streamOpenAICompatible(base: ExternalEngine.ds4URL, model: "ds4", system: system, history: history, prompt: prompt)
        case .chatgpt: ExternalEngine.streamChatGPT(system: system, history: history, prompt: prompt, model: chosen.model, effort: chosen.effort)
        case .claude: ExternalEngine.streamClaude(system: system, history: history, prompt: prompt, model: chosen.model, effort: chosen.effort)
        case .apple: AsyncThrowingStream { $0.finish() }
        }
        if !chosen.provider.isLocal { setThinking("\(chosen.provider.name) sta scrivendo…") }
        var messageID: UUID?
        var final = ""
        do {
            for try await text in stream {
                guard !text.isEmpty else { continue }
                final = text
                if let messageID, let index = out?.messages.firstIndex(where: { $0.id == messageID }) {
                    out?.messages[index].content = .text(text)
                } else {
                    out?.messages.removeAll { if case .thinking = $0.content { true } else { false } }
                    let message = Message(content: .text(text))
                    messageID = message.id
                    out?.messages.append(message)
                }
            }
        } catch {
            if messageID == nil {
                append(.notice(error.localizedDescription))
                return nil
            }
            append(.notice(error.localizedDescription))
        }
        return messageID == nil ? nil : (messageID, final)
    }

    // MARK: - Modelli esterni con gli strumenti

    /// Testo in streaming di un modello esterno: un messaggio per giro, le schede degli strumenti in mezzo.
    private final class ExternalText {
        var messageID: UUID?
        var text = ""
        var all: [String] = []
    }

    /// Percorso della CLI dentro l'app (ponte MCP per ChatGPT e Claude).
    private var bridgeHelper: String? {
        let path = Bundle.main.bundleURL.appending(path: "Contents/Helpers/siriai").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Risposta di Gemma, ds4, ChatGPT o Claude che usano gli strumenti dell'app. `false` se il modello non è disponibile.
    /// Il sub-agent smistatore per i modelli esterni: sceglie dal catalogo degli strumenti dell'app solo quelli che servono.
    /// nil se Apple Intelligence non c'è (allora il modello riceve tutti gli strumenti, come prima).
    private func routeExternal(_ prompt: String) async -> ToolRoute? {
        guard availabilityProblem == nil, assistant.routesTools else { return nil }
        if Assistant.isSmallTalk(prompt) { return ToolRoute(decided: true) }
        setThinking("Scelgo gli strumenti…")
        return await assistant.routeExternalTools(for: prompt, tools: ToolRegistry.tools(for: assistant.work, enabled: enabledSources))
    }

    /// Gli strumenti per un modello esterno: quelli dello smistatore più quelli che le parole della richiesta nominano
    /// (rete di sicurezza); il documento aperto al centro si può sempre modificare e il web si può sempre cercare.
    private func externalTools(for prompt: String, route: ToolRoute?) -> [ToolSpec] {
        let all = ToolRegistry.tools(for: assistant.work, enabled: enabledSources)
        guard let route else { return all }
        var tools = ToolRegistry.selecting(all, route: route, hints: assistant.toolHints(for: prompt))
        if assistant.work.artifactKind != nil, let edit = all.first(where: { $0.name == "modifica_aperto" }), !tools.contains(edit) { tools.append(edit) }
        // La ricerca sul web resta sempre: se il modello si accorge di non sapere (fatti recenti) può cercare da solo.
        if let web = all.first(where: { $0.name == "cerca_web" }), !tools.contains(web) { tools.append(web) }
        Agent.log("STRUMENTI AL MODELLO: \(tools.count) su \(all.count) · \(tools.map(\.name).joined(separator: ", "))")
        return tools
    }

    private func respondWithTools(_ prompt: String, route: ToolRoute? = nil) async -> Bool {
        guard let conversation = out else { return false }
        let chosen = resolved(activeSelection)
        if chosen.provider == .gemma, await readyGemma(chosen) == nil { return false }
        let modelLabel = label(for: chosen)
        assistant.beginExternal(prompt, model: modelLabel)
        await assistant.prepareExternal(prompt)
        // La traccia va subito dopo la domanda, prima delle schede e della risposta.
        let traceIndex = (conversation.messages.lastIndex { if case .user = $0.content { true } else { false } } ?? conversation.messages.count - 1) + 1
        let tools = externalTools(for: prompt, route: route)
        if let route { assistant.noteRoute(route, chosen: tools.map(\.name)) }
        let system = assistant.chatInstructions()
        let history = fitting(assistant.historyTurns, characters: contextBudget.historyCharacters)
        let request = assistant.withContext(prompt)
        let box = ExternalText()
        let onText: ExternalAgent.TextUpdate = { [weak self] text in
            guard let self else { return }
            guard let text else {
                // Il modello passa agli strumenti: il prossimo testo andrà in un messaggio nuovo, dopo le schede.
                if !box.text.isEmpty { box.all.append(box.text) }
                box.messageID = nil
                box.text = ""
                return
            }
            box.text = text
            conversation.messages.removeAll { if case .thinking = $0.content { true } else { false } }
            if let id = box.messageID, let index = conversation.messages.firstIndex(where: { $0.id == id }) {
                conversation.messages[index].content = .text(text)
            } else {
                let message = Message(content: .text(text))
                box.messageID = message.id
                conversation.messages.append(message)
            }
        }
        let onStatus: ExternalAgent.StatusUpdate = { [weak self] status in self?.setThinking(status) }
        setThinking("\(modelLabel) sta lavorando…")
        do {
            guard let text = try await runExternal(chosen, system: system, history: history, prompt: request, tools: tools,
                                                   onText: onText, onStatus: onStatus) else { return false }
            if box.messageID == nil, box.all.isEmpty, !text.isEmpty { onText(text) }
            conversation.messages.removeAll { if case .thinking = $0.content { true } else { false } }
            assistant.finishExternal()
            if var trace = assistant.trace, trace.isInteresting {
                trace.model = modelLabel
                conversation.messages.insert(Message(content: .trace(trace)), at: min(traceIndex, conversation.messages.count))
            }
            updateExternalUsage(prompt: request, reply: (box.all + [box.text]).joined(separator: "\n"))
            return true
        } catch {
            conversation.messages.removeAll { if case .thinking = $0.content { true } else { false } }
            if Task.isCancelled { append(.notice("Risposta interrotta.")); return true }
            // Ha già scritto qualcosa: si tiene quello e si segnala l'errore.
            if box.messageID != nil || !box.all.isEmpty { append(.notice(error.localizedDescription)); return true }
            if error is PrivacyError {
                append(.notice("Non ho inviato niente a \(modelLabel): \(error.localizedDescription). Rispondo con Apple Intelligence sul Mac."))
                appleOnly = true
                assistant.textWriter = nil
                return false
            }
            append(.notice("\(modelLabel) non è disponibile (\(error.localizedDescription)): rispondo con Apple Intelligence."))
            return false
        }
    }

    /// Esegue lo strumento chiesto dal modello: i dati tornano al modello, le bozze diventano schede da confermare.
    private func runExternalTool(_ name: String, arguments: JSONValue) async -> String {
        Agent.log("STRUMENTO: \(name) \(arguments.compactString.prefix(160))")
        let result = await assistant.runTool(name, arguments: arguments, enabled: enabledSources, allowedMCP: { [mcp] in mcp.isAlwaysAllowed($0) }) { [weak self] status in
            self?.setThinking(status)
        }
        guard let outcome = result.outcome else { return result.text }
        switch outcome {
        case .agenda(let agenda, _): append(.agenda(agenda))
        case .items(let items, _): append(.items(items))
        case .web(let answer, _): append(.web(answer))
        case .files(let entries, _): append(.files(entries.prefix(40).map { ($0.isDirectory ? "📁 " : "") + $0.path }))
        case .remembered(let fact, _):
            memoryRevision += 1
            projectRevision += 1
            log(icon: "brain", title: "Memoria aggiornata", detail: fact, status: .done)
        case .mcpCall(let draft) where mcp.isAlwaysAllowed(draft.tool):
            // Strumento già consentito dall'utente: si esegue e il risultato torna al modello.
            let card = MCPCallCardModel(draft)
            append(.mcp(card))
            card.status = .running
            do {
                let text = try await mcp.call(draft.tool, arguments: draft.arguments)
                card.result = String(text.prefix(4000))
                card.status = .done
                return String(text.prefix(contextBudget.scaled(3000)))
            } catch {
                card.status = .failed
                card.error = error.localizedDescription
                return "Errore: \(error.localizedDescription)"
            }
        case .document(let draft):
            present(ArtifactModel(kind: .pages, title: draft.title, content: .document(ArtifactFactory.document(from: draft))),
                    intro: "Ecco il documento, aperto al centro.")
        case .artifactEdit(let edit):
            applyArtifactEdit(edit)
        default:
            let source: SourceKind? = switch outcome {
            case .confirm(let action): action.source
            case .eventDraft, .eventEdit: .calendar
            case .reminderDrafts, .reminderEdit: .reminders
            case .noteDraft, .noteAppend: .notes
            case .messageDraft: .messages
            default: nil
            }
            if let source, !canWrite(source) {
                readOnly(source, name)
                return "L'utente non ha dato a questa app il permesso di scrivere in \(source.label)."
            }
            if let content = cardContent(for: outcome, projectID: currentProject?.id) {
                append(content)
                flash(.waiting)
            }
        }
        return result.text
    }

    /// Con un modello esterno l'anello mostra quanto della sua finestra occupano istruzioni, conversazione e ultima richiesta.
    private func updateExternalUsage(prompt: String, reply: String) {
        let history = fitting(assistant.historyTurns, characters: contextBudget.historyCharacters)
        let used = assistant.chatInstructions().count + history.reduce(0) { $0 + $1.text.count } + prompt.count + reply.count
        contextUsage = min(1, Double(used) / Double(contextBudget.characters))
    }

    // MARK: - Anonimizzazione verso ChatGPT e Claude (rizzo-pii sul Mac)

    /// Lo scudo di una chat che risponde con ChatGPT o Claude: il dizionario è della conversazione e si salva con lei.
    /// nil con i modelli sul Mac (Apple Intelligence, Gemma, ds4) o se l'anonimizzazione è spenta.
    private func privacyShield(for conversation: Conversation, provider: ResponseProvider) -> PrivacyShield? {
        guard cloudPrivacy, provider == .chatgpt || provider == .claude else { return nil }
        let shield = PrivacyShield(vault: conversation.privacyVault ?? PIIVault(), destination: provider.name, labels: privacyLabels)
        let id = conversation.id
        shield.onVaultChange = { [weak self] vault in
            Task { @MainActor in self?.conversations.first { $0.id == id }?.privacyVault = vault }
        }
        shield.onStatus = { [weak self] text in Task { @MainActor in self?.setThinking(text) } }
        return shield
    }

    /// Con ChatGPT o Claude il motore si carica in anticipo (circa 2 secondi): la prima richiesta non aspetta.
    func preparePrivacyEngine() {
        let chosen = resolved(activeSelection)
        guard cloudPrivacy, chosen.provider == .chatgpt || chosen.provider == .claude, PIIEngine.isInstalled else { return }
        Task.detached(priority: .utility) { await PIIEngine.shared.prepare() }
    }

    /// Dopo un quarto d'ora senza richieste il motore lascia la memoria (circa 700 MB).
    private func scheduleEngineRelease() {
        privacyIdle?.cancel()
        privacyIdle = Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(900))
            guard !Task.isCancelled else { return }
            await PIIEngine.shared.releaseIfIdle(after: 840)
        }
    }

    /// Una chiamata al modello esterno scelto con gli strumenti di Siri AI+: Gemma e ds4 direttamente, ChatGPT e Claude
    /// attraverso il ponte MCP (un gateway locale per la durata della chiamata). nil con Apple Intelligence.
    private func runExternal(_ chosen: ModelSelection, system: String, history: [ChatTurn], prompt: String, tools: [ToolSpec],
                             onText: @escaping ExternalAgent.TextUpdate, onStatus: @escaping ExternalAgent.StatusUpdate) async throws -> String? {
        let shield = PrivacyShield.current
        let call: ExternalAgent.ToolCall = { [weak self] name, arguments in
            guard let self else { return "" }
            guard let shield else { return await self.runExternalTool(name, arguments: arguments) }
            // Lo strumento gira sul Mac con i valori veri; al modello torna il risultato anonimizzato. Le pagine web sono
            // pubbliche: solo i dati già noti della chat diventano segnaposto (così non rivelano chi c'è dietro).
            let result = await self.runExternalTool(name, arguments: shield.reveal(arguments))
            if ["cerca_web", "leggi_pagina"].contains(name) { return shield.mask(result) }
            do {
                return try await shield.protect(result)
            } catch {
                return "Errore: il risultato non è stato inviato perché \(error.localizedDescription)."
            }
        }
        switch chosen.provider {
        case .gemma, .ds4:
            let local = chosen.provider == .gemma
            return try await ExternalAgent.openAI(base: local ? ExternalEngine.gemmaURL : ExternalEngine.ds4URL, model: local ? "gemma" : "ds4",
                                                  system: system, history: history, prompt: prompt, tools: tools, thinking: chosen.effort == "on",
                                                  call: call, onText: onText, onStatus: onStatus)
        case .chatgpt, .claude:
            var bridge: ExternalAgent.Bridge?
            var gateway: ToolGateway?
            if let helper = bridgeHelper, !tools.isEmpty {
                let server = try ToolGateway(tools: tools) { name, arguments in
                    let text = await call(name, arguments)
                    return (text, text.hasPrefix("Errore"))
                }
                let url = try await server.start()
                gateway = server
                bridge = ExternalAgent.Bridge(helper: helper, gateway: url, token: server.token)
            }
            defer { gateway?.stop() }
            return chosen.provider == .chatgpt
                ? try await ExternalAgent.codex(system: system, history: history, prompt: prompt, bridge: bridge, model: chosen.model,
                                                effort: chosen.effort, onText: onText, onStatus: onStatus)
                : try await ExternalAgent.claude(system: system, history: history, prompt: prompt, bridge: bridge, model: chosen.model,
                                                 effort: chosen.effort, onText: onText, onStatus: onStatus)
        case .apple:
            return nil
        }
    }

    /// Compito complesso con un modello esterno: il modello scrive la catena di pensieri e i passi, i sub-agent (lo stesso modello,
    /// ognuno con una conversazione nuova e gli strumenti) li svolgono anche in parallelo, poi il modello scrive la risposta finale.
    private func respondWithPlan(_ prompt: String) async -> Bool {
        let chosen = resolved(activeSelection)
        guard chosen.provider != .apple else { return false }
        if chosen.provider == .gemma, await readyGemma(chosen) == nil { return false }
        let modelLabel = label(for: chosen)
        assistant.beginExternal(prompt, model: modelLabel)
        await assistant.prepareExternal(prompt)
        setThinking("\(modelLabel) ragiona sul compito…")
        let request = assistant.taskPlanRequest(for: prompt)
        var plan: TaskPlan?
        do {
            let text = try await runExternal(chosen, system: request.system, history: [], prompt: request.prompt, tools: [],
                                             onText: { _ in }, onStatus: { _ in })
            plan = text.flatMap { Assistant.parseTaskPlan($0, goal: prompt) }
            if plan == nil { Agent.log("PIANO DI LAVORO (\(modelLabel)) ILLEGGIBILE: \((text ?? "").prefix(300))") }
        } catch {
            Agent.log("PIANO DI LAVORO (\(modelLabel)) NON RIUSCITO: \(error.localizedDescription)")
        }
        guard !Task.isCancelled else { return true }
        // Se il modello non restituisce un piano leggibile lo scrive Apple Intelligence; i passi li svolge comunque il modello scelto.
        if plan == nil, availabilityProblem == nil { plan = try? await assistant.makeTaskPlan(for: prompt) }
        guard var plan, plan.steps.count >= 2 else { return false }
        Agent.log("PIANO DI LAVORO (\(modelLabel)): \(plan.steps.map(\.title))")
        // ChatGPT e Claude: Apple Intelligence valuta la difficoltà dei passi e ognuno va alla versione adatta
        // (leggera per cercare e leggere, la più capace per le analisi difficili). Il passo finale lo scrive il modello della chat.
        if SubAgentRouting.routes(chosen.provider) {
            setThinking("Apple Intelligence sceglie il modello per ogni passo…")
            let difficulties = await assistant.stepDifficulties(for: plan)
            let gpt = ModelCatalog.chatGPT()
            let finalIndex = Assistant.isFinalWriting(plan.steps[plan.steps.count - 1]) ? plan.steps.count - 1 : nil
            for (index, difficulty) in zip(plan.steps.indices, difficulties) {
                plan.steps[index].difficulty = difficulty
                plan.steps[index].subAgent = index == finalIndex ? chosen : SubAgentRouting.selection(for: difficulty, chat: chosen, gpt: gpt)
            }
            Agent.log("SUB-AGENT: " + plan.steps.map { "\($0.title) → \(SubAgentRouting.label($0.subAgent ?? chosen, gpt: gpt)) (\($0.difficulty?.rawValue ?? "?"))" }
                .joined(separator: "; "))
        }
        let card = TaskPlanCardModel(plan, parallel: subAgentLimit)
        append(.taskPlan(card))
        await runTaskPlan(card, model: chosen)
        assistant.finishExternal()
        return true
    }

    /// Un passo del piano svolto da un sub-agent con il modello esterno scelto: conversazione nuova, gli stessi strumenti
    /// e le stesse regole della chat (progetto compreso); il testo non va in chat, diventa il risultato del passo.
    private func runExternalStep(_ step: TaskPlan.Step, previous: String, chosen: ModelSelection) async -> (String, Outcome?) {
        // La versione scelta per questo passo (ChatGPT e Claude), altrimenti quella della chat.
        let chosen = step.subAgent ?? chosen
        if chosen.provider == .gemma, await readyGemma(chosen) == nil { return ("Errore: Gemma non è pronta.", nil) }
        // Anche ogni sub-agent riceve solo gli strumenti del suo passo, scelti dallo smistatore.
        let route = availabilityProblem == nil && assistant.routesTools
            ? await assistant.routeExternalTools(for: step.instruction, tools: ToolRegistry.tools(for: assistant.work, enabled: enabledSources))
            : nil
        let tools = externalTools(for: step.instruction, route: route)
        let system = assistant.chatInstructions() + "\n\n" + Assistant.subAgentRule
        let request = step.instruction + (previous.isEmpty ? "" : "\n\nRisultati dei passi precedenti:\n\(previous.prefix(12_000))")
        let box = ExternalText()
        let onText: ExternalAgent.TextUpdate = { text in
            if let text { box.text = text } else if !box.text.isEmpty { box.all.append(box.text); box.text = "" }
        }
        let title = step.title
        let onStatus: ExternalAgent.StatusUpdate = { [weak self] status in self?.setThinking("Sub-agent «\(title)»: \(status)") }
        do {
            let text = try await runExternal(chosen, system: system, history: [], prompt: request, tools: tools, onText: onText, onStatus: onStatus) ?? ""
            let streamed = (box.all + [box.text]).filter { !$0.isEmpty }.joined(separator: "\n")
            let result = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? streamed : text
            return (result.isEmpty ? "Errore: nessun risultato." : result, nil)
        } catch {
            return ("Errore: \(error.localizedDescription)", nil)
        }
    }

    // MARK: - Compiti complessi e sub-agent

    /// Esegue il piano: i passi indipendenti partono insieme (fino a `subAgentLimit`), ognuno con un sub-agent
    /// e la sua finestra di contesto; poi la risposta finale riunisce i risultati.
    /// `model`: i sub-agent usano quel modello esterno (con gli strumenti) invece di Apple Intelligence.
    private func runTaskPlan(_ card: TaskPlanCardModel, model: ModelSelection? = nil) async {
        card.running = true
        defer { card.running = false; saveConversations() }
        let base = assistant.work
        let steps = card.plan.steps
        let finalIndex = steps.count >= 2 && Assistant.isFinalWriting(steps[steps.count - 1]) ? steps.count - 1 : nil
        for batch in card.plan.batches(maxParallel: card.parallel) {
            guard !Task.isCancelled else { break }
            let indices = batch.filter { $0 != finalIndex }
            guard !indices.isEmpty else { continue }
            for index in indices { card.plan.steps[index].status = "corso" }
            setThinking(indices.count > 1 ? "\(indices.count) sub-agent al lavoro in parallelo…" : "Sub-agent: \(card.plan.steps[indices[0]].title)…")
            let previous = card.plan.steps.filter { !$0.result.isEmpty }
                .map { "\($0.title): \($0.result.prefix(700))" }.joined(separator: "\n\n")
            // Un Task per sub-agent: lavorano insieme, ognuno con la sua sessione.
            let workers = indices.map { index in
                let step = card.plan.steps[index]
                return Task { @MainActor () -> (Int, String, Outcome?) in
                    let (text, outcome) = await self.runStepRetrying(step, previous: previous, work: base, model: model)
                    return (index, text, outcome)
                }
            }
            var results: [(Int, String, Outcome?)] = []
            for worker in workers { results.append(await worker.value) }
            for (index, text, outcome) in results {
                card.plan.steps[index].result = text
                if let outcome {
                    card.plan.steps[index].status = "conferma"
                    await present(outcome, prompt: card.plan.steps[index].instruction)
                } else {
                    card.plan.steps[index].status = text.hasPrefix("Errore") ? "errore" : "fatto"
                }
            }
            saveConversations()
        }
        guard !Task.isCancelled else { return append(.notice("Piano interrotto.")) }
        if let finalIndex { card.plan.steps[finalIndex].status = "corso" }
        setThinking("Scrivo la risposta finale…")
        let reply = await stream(assistant.taskSynthesisPrompt(card.plan))
        if let finalIndex {
            card.plan.steps[finalIndex].status = "fatto"
            card.plan.steps[finalIndex].result = "Scritto nella risposta."
        }
        if card.plan.delivery == .documento, !reply.text.isEmpty {
            let title = String(card.plan.goal.split(separator: " ").prefix(8).joined(separator: " "))
            present(ArtifactModel(kind: .pages, title: title.capitalized, content: .document(Self.styled(reply.text))),
                    intro: "Ho messo il risultato anche in un documento, aperto al centro.")
        }
        log(icon: "list.number", title: "Compito completato", detail: card.plan.goal, status: .done)
    }

    /// Un passo che fallisce si ritenta una volta, chiedendo al sub-agent un'altra strada (parole diverse, altra fonte).
    private func runStepRetrying(_ step: TaskPlan.Step, previous: String, work: WorkContext,
                                 enabled: Set<SourceKind>? = nil, into target: Conversation? = nil, model: ModelSelection? = nil) async -> (String, Outcome?) {
        let first = await runStep(step, previous: previous, work: work, enabled: enabled, into: target, model: model)
        guard first.1 == nil, first.0.hasPrefix("Errore") || first.0.trimmingCharacters(in: .whitespacesAndNewlines).count < 3, !Task.isCancelled else { return first }
        var retry = step
        retry.instruction += "\n(Il primo tentativo non è riuscito: \(first.0.prefix(200)). Prova un'altra strada: parole diverse o un'altra fonte.)"
        // Un modello più leggero (o al limite dell'abbonamento) non ce l'ha fatta: il secondo tentativo lo fa il modello della chat.
        retry.subAgent = nil
        Agent.log("SUB-AGENT: ritento «\(step.title)»")
        return await runStep(retry, previous: previous, work: work, enabled: enabled, into: target, model: model)
    }

    /// Un passo del piano, svolto da un sub-agent con una sessione nuova (contesto separato).
    private func runStep(_ step: TaskPlan.Step, previous: String, work: WorkContext,
                         enabled: Set<SourceKind>? = nil, into target: Conversation? = nil, model: ModelSelection? = nil) async -> (String, Outcome?) {
        if let model, model.provider != .apple { return await runExternalStep(step, previous: previous, chosen: model) }
        let agent = Assistant()
        agent.isSubAgent = true
        agent.work = work
        do {
            // Analisi e scrittura: basta ragionare sui risultati dei passi precedenti.
            guard Assistant.stepNeedsTools(step.instruction) else {
                let request = step.instruction + (previous.isEmpty ? "" : "\n\nRisultati dei passi precedenti:\n\(previous.prefix(2400))")
                return (try await agent.chat.respond(to: request, options: agent.responseOptions).content, nil)
            }
            let request = step.instruction + (previous.isEmpty ? "" : "\n\nContesto: \(previous.prefix(400))")
            let outcome = await agent.handle(request, enabled: enabled ?? enabledSources, picked: []) { _ in }
            switch outcome {
            case .reply(let prompt), .files(_, let prompt):
                return (try await agent.chat.respond(to: prompt, options: agent.responseOptions).content, nil)
            // I dati letti dal sub-agent restano visibili come schede, come quando risponde la chat.
            case .agenda(let agenda, let prompt):
                (target ?? current)?.messages.append(Message(content: .agenda(agenda)))
                return (try await agent.chat.respond(to: prompt, options: agent.responseOptions).content, nil)
            case .items(let items, let prompt):
                (target ?? current)?.messages.append(Message(content: .items(items)))
                return (try await agent.chat.respond(to: prompt, options: agent.responseOptions).content, nil)
            case .web(let answer, let prompt):
                (target ?? current)?.messages.append(Message(content: .web(answer)))
                return (try await agent.chat.respond(to: prompt, options: agent.responseOptions).content, nil)
            case .message(let text):
                return (text, nil)
            case .mcpCall(var draft) where mcp.isAlwaysAllowed(draft.tool):
                // Strumenti già consentiti: il sub-agent li concatena da solo.
                var steps: [MCPStep] = []
                for _ in 0..<4 {
                    let result = try await mcp.call(draft.tool, arguments: draft.arguments)
                    steps.append(MCPStep(tool: draft.tool.name, arguments: draft.arguments.compactString, result: String(result.prefix(3000))))
                    guard let next = await agent.nextMCPStep(after: draft, result: result), mcp.isAlwaysAllowed(next.tool) else { break }
                    draft = next
                }
                return (try await agent.chat.respond(to: agent.mcpAnswerPrompt(request: step.instruction, steps: steps), options: agent.responseOptions).content, nil)
            case .unavailable(let source, _):
                return ("Errore: \(source.label) non è disponibile.", nil)
            default:
                return ("Preparato: controlla e conferma la scheda qui sotto.", outcome)
            }
        } catch {
            return ("Errore: \(error.localizedDescription)", nil)
        }
    }

    func stopTask() { stop() }

    // MARK: - Skill

    /// Un piano riuscito diventa una procedura riusabile (SKILL.md), nel progetto se ce n'è uno.
    func saveSkill(from card: TaskPlanCardModel) {
        let draft = SkillStore.draft(from: card.plan)
        do {
            let skill = try SkillStore.save(name: draft.name, description: draft.description, cues: draft.cues, body: draft.body,
                                            project: currentProject?.folder)
            card.savedAsSkill = true
            skillsRevision += 1
            log(icon: "wand.and.stars", title: "Skill salvata", detail: skill.name, status: .done)
            showToast("Skill «\(skill.name)» salvata", symbol: "wand.and.stars")
            append(.notice("Skill «\(skill.name)» salvata: la seguirò quando chiedi qualcosa di simile. La trovi in Impostazioni › Skill."))
        } catch {
            log(icon: "wand.and.stars", title: "Skill non salvata", detail: error.localizedDescription, status: .failed)
        }
        saveConversations()
    }

    // MARK: - Pagine web

    /// Salva index.html e style.css (nel progetto o in Documenti/Siri AI+/Siti) e apre la pagina nel browser integrato.
    func saveWebsite(_ card: WebsiteCardModel) {
        do {
            let folder: URL
            if let projectID = card.projectID, let project = projects.first(where: { $0.id == projectID }) {
                var name = card.draft.folder
                var counter = 2
                while project.files.exists(name) { name = "\(card.draft.folder)-\(counter)"; counter += 1 }
                for (file, content) in card.draft.files { try project.files.write("\(name)/\(file)", content: content) }
                card.draft.folder = name
                folder = try project.files.resolve(name)
                projectRevision += 1
            } else {
                var base = ArtifactFactory.defaultFolder.appending(path: "Siti").appending(path: card.draft.folder)
                var counter = 2
                while FileManager.default.fileExists(atPath: base.path) {
                    base = ArtifactFactory.defaultFolder.appending(path: "Siti").appending(path: "\(card.draft.folder)-\(counter)")
                    counter += 1
                }
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                for (file, content) in card.draft.files { try content.write(to: base.appending(path: file), atomically: true, encoding: .utf8) }
                folder = base
            }
            card.savedFolder = folder.path
            card.status = .done
            log(icon: "globe", title: "Pagina web creata", detail: folder.lastPathComponent, status: .done)
            openInBrowser(folder.appending(path: "index.html"))
        } catch {
            card.status = .failed
            card.error = error.localizedDescription
        }
        saveConversations()
    }

    /// Apre una pagina nel Safari della chat (o della sessione di coding) aperta: la chat resta a destra.
    func openInBrowser(_ url: URL) {
        let root = url.isFileURL ? project(containing: url)?.folder ?? openCodingProject.map { workingCodeProject($0).folder } : nil
        browser.load(url, readAccess: root.flatMap { url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") ? $0 : nil })
        withAnimation(.smooth(duration: 0.3)) { section = .browser }
    }

    /// Apre un file del progetto nell'editor della scheda File.
    func openProjectFile(_ project: ProjectModel, path: String) {
        projectFileToOpen = path
        section = .project(project.id)
    }

    // MARK: - Agenti

    /// Con agenti programmati l'app resta aperta anche chiudendo la finestra.
    nonisolated(unsafe) static var keepsRunning = false

    var currentAgent: AgentSpec? {
        guard let id = out?.agentID else { return nil }
        return agents.first { $0.id == id }
    }

    func agent(_ id: UUID) -> AgentSpec? { agents.first { $0.id == id } }

    /// Chat dell'agente (una sola, creata al primo uso).
    func conversation(for agent: AgentSpec) -> Conversation {
        if let existing = conversations.first(where: { $0.agentID == agent.id }) { return existing }
        let conversation = Conversation(title: agent.displayName)
        conversation.agentID = agent.id
        conversations.append(conversation)
        return conversation
    }

    /// Apre l'agente al centro e la sua chat a destra.
    func openAgent(_ id: UUID) {
        guard let agent = agent(id) else { return }
        section = .agent(id)
        select(conversation(for: agent))
    }

    func pendingApprovals(for agent: AgentSpec) -> Int {
        conversations.first { $0.agentID == agent.id }?.messages.filter(\.isPending).count ?? 0
    }

    /// Cartella dell'agente: soul.md e area di lavoro.
    static func agentFolder(_ id: UUID) -> URL {
        let url = supportURL("Agents").appending(path: id.uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func soulURL(_ id: UUID) -> URL { agentFolder(id).appending(path: "soul.md") }

    func soul(of agent: AgentSpec) -> String {
        if let text = try? String(contentsOf: Self.soulURL(agent.id), encoding: .utf8) { return text }
        try? agent.defaultSoul.write(to: Self.soulURL(agent.id), atomically: true, encoding: .utf8)
        return agent.defaultSoul
    }

    func saveSoul(_ text: String, for agent: AgentSpec) {
        try? text.write(to: Self.soulURL(agent.id), atomically: true, encoding: .utf8)
        updateAgent(agent.id) { $0.record(.nota, "Anima modificata") }
        showToast("Anima di \(agent.personName.isEmpty ? agent.name : agent.personName) salvata")
    }

    func saveAgent(_ spec: AgentSpec) {
        var spec = spec
        if agent(spec.id) == nil { spec.space = space == .codice ? Space.lavoro.rawValue : space.rawValue }
        if spec.personName.trimmingCharacters(in: .whitespaces).isEmpty {
            spec.personName = AgentSpec.suggestedPersonName(for: spec.name, avoiding: agents.filter { $0.id != spec.id }.map(\.personName))
        }
        spec.reschedule()
        _ = soul(of: spec)
        if let index = agents.firstIndex(where: { $0.id == spec.id }) {
            agents[index] = spec
        } else {
            spec.record(.nota, "Agente creato: \(spec.goal)")
            agents.append(spec)
            log(icon: "sparkles", title: "Agente creato", detail: spec.displayName, status: .done)
            requestNotifications()
        }
        conversation(for: spec).title = spec.displayName
        saveAgents()
    }

    /// Configurazione proposta da una descrizione in linguaggio naturale.
    func draftAgent(_ description: String) async -> AgentSpec {
        await syncWorkContext()
        return (try? await assistant.draftAgent(from: description)) ?? AgentSpec(name: "Nuovo agente", goal: description)
    }

    func createAgent(from card: AgentDraftCardModel) {
        saveAgent(card.spec)
        card.created = true
        saveConversations()
    }

    func deleteAgent(_ id: UUID) {
        agents.removeAll { $0.id == id }
        conversations.removeAll { $0.agentID == id }
        try? FileManager.default.removeItem(at: Self.agentFolder(id))
        if case .agent(let open) = section, open == id { section = .agents }
        saveAgents()
        saveConversations()
    }

    func toggleActive(_ id: UUID) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].active.toggle()
        agents[index].reschedule()
        agents[index].record(.nota, agents[index].active ? "Agente riattivato" : "Agente in pausa")
        saveAgents()
    }

    @discardableResult
    func updateAgent(_ id: UUID, _ change: (inout AgentSpec) -> Void) -> Bool {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return false }
        change(&agents[index])
        return saveAgents()
    }

    /// Le indicazioni date chattando con un agente ("d'ora in poi includi anche…") entrano nella sua memoria.
    private func rememberInstruction(for agent: AgentSpec) {
        guard let last = out?.messages.last, case .user(let text, _, _) = last.content else { return }
        let lower = text.lowercased()
        let cues = ["d'ora in poi", "da ora", "da domani", "ricorda", "includi", "aggiungi anche", "non ", "evita", "preferisco", "voglio che", "sempre", "mai "]
        guard cues.contains(where: lower.contains) else { return }
        updateAgent(agent.id) { spec in
            if !spec.memory.contains(text) { spec.memory.append(text); if spec.memory.count > 20 { spec.memory.removeFirst() } }
            spec.record(.nota, "Nuova indicazione: \(text.prefix(160))")
        }
    }

    /// Esegue l'agente: sull'obiettivo principale o sul compito di una sua programmazione.
    /// - Parameters:
    ///   - scheduled: avviato dallo scheduler (piccola attesa casuale, così più agenti non partono nello stesso istante).
    ///   - heartbeat: prima controlla se c'è davvero qualcosa da fare.
    func runAgent(_ id: UUID, routine: UUID? = nil, scheduled: Bool = false, heartbeat: Bool = false,
                  trigger: AgentRun.Trigger? = nil, claimedRunID: UUID? = nil) {
        guard let agent = agent(id), !runningAgents.contains(id) else { return }
        runningAgents.insert(id)
        // L'agente lavora con calendari, posta e connettori del suo spazio, qualunque sia quello aperto.
        let scope = scope(for: Space(rawValue: agent.space) ?? .lavoro)
        agentTasks[id] = Task {
            defer {
                runningAgents.remove(id)
                agentTasks[id] = nil
            }
            if scheduled {
                do { try await Task.sleep(for: .seconds(Double.random(in: 0...12))) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            await SpaceScope.$task.withValue(scope) {
                if heartbeat, !(await heartbeatSaysGo(id, routine: routine)) {
                    if let claimedRunID {
                        updateAgent(id) { $0.updateRun(claimedRunID) { run in
                            run.outcome = .completata; run.end = .now; run.summary = "Nessuna azione necessaria"
                        } }
                    }
                    return
                }
                await performAgentRun(id, routine: routine, trigger: trigger ?? (scheduled ? .programmata : .manuale),
                                      claimedRunID: claimedRunID)
            }
        }
    }

    /// Ferma un agente al lavoro (i passi già fatti restano).
    func cancelAgent(_ id: UUID) {
        guard let task = agentTasks[id] else { return }
        task.cancel()
        updateAgent(id) { spec in
            for index in spec.history.indices where spec.history[index].outcome == .inCorso {
                spec.history[index].outcome = .interrotta
                spec.history[index].end = .now
            }
            spec.record(.nota, "Esecuzione interrotta dall'utente")
        }
        log(icon: "stop.circle", title: "Agente fermato", detail: agent(id)?.displayName ?? "", status: .cancelled)
    }

    /// «Esci» chiude l'esecuzione corrente senza lasciare una scadenza reclamata come ancora attiva.
    func stopForExit() {
        schedulerTask?.cancel()
        for task in agentTasks.values { task.cancel() }
        for index in agents.indices {
            for run in agents[index].history.indices where agents[index].history[run].outcome == .inCorso {
                agents[index].history[run].outcome = .interrotta
                agents[index].history[run].end = .now
            }
        }
        saveAgents()
    }

    /// Heartbeat: fotografia della situazione e decisione del modello. Se non serve lavorare si sposta solo la prossima esecuzione.
    private func heartbeatSaysGo(_ id: UUID, routine: UUID?) async -> Bool {
        guard let agent = agent(id) else { return false }
        var lines: [String] = []
        if agent.allowApps.contains(.calendar), isEnabled(.calendar) {
            let events = Overview.events().filter { $0.end > .now }.prefix(8).map { "- \($0.title) \(Dates.friendly($0.start))" }
            lines.append("Eventi di oggi:\n" + (events.isEmpty ? "nessuno" : events.joined(separator: "\n")))
        }
        if agent.allowApps.contains(.reminders), isEnabled(.reminders) {
            let due = await Overview.openReminders(limit: 60).filter { ($0.due ?? .distantFuture) < Calendar.current.date(byAdding: .day, value: 1, to: .now)! }
            lines.append("Promemoria in scadenza:\n" + (due.isEmpty ? "nessuno" : due.prefix(8).map { "- \($0.title)" }.joined(separator: "\n")))
        }
        if agent.allowApps.contains(.mail), isEnabled(.mail), let unread = try? await MailReader.inbox(query: nil, unreadOnly: true, limit: 8) {
            lines.append("Email non lette:\n" + (unread.rows.isEmpty ? "nessuna" : unread.rows.map { "- \($0.title) — \($0.subtitle)" }.joined(separator: "\n")))
        }
        let worker = Assistant()
        worker.isSubAgent = true
        let decision = await worker.shouldAct(agent, snapshot: lines.joined(separator: "\n\n"))
        if !decision.act {
            updateAgent(id) { spec in
                if let routine, let index = spec.routines.firstIndex(where: { $0.id == routine }) {
                    spec.routines[index].nextRun = spec.routines[index].schedule.next(after: .now)
                }
            }
            Agent.log("HEARTBEAT \(agent.displayName): niente da fare (\(decision.reason))")
            return false
        }
        updateAgent(id) { $0.record(.nota, "Controllo: c'è da fare — \(decision.reason)") }
        return true
    }

    /// Approva insieme le schede in attesa di un agente (eventi, promemoria, note, file). Email e messaggi restano da confermare uno per uno.
    @discardableResult
    func approveAll(for agentID: UUID) -> Int {
        guard let conversation = conversations.first(where: { $0.agentID == agentID }) else { return 0 }
        var count = 0
        for message in conversation.messages where message.isPending {
            if approveAutomatically(message.content) { count += 1 }
        }
        if count > 0 {
            updateAgent(agentID) { $0.record(.nota, "Approvate insieme \(count) azioni") }
            saveConversations()
        }
        return count
    }

    /// Esegue una scheda senza chiedere (solo i tipi sicuri). Restituisce false per email, messaggi e connettori.
    private func approveAutomatically(_ content: Message.Content) -> Bool {
        switch content {
        case .event(let m) where m.status == .draft: save(m)
        case .reminders(let m) where m.status == .draft: add(m)
        case .confirm(let m) where m.status == .awaiting && !m.isDestructive: perform(m)
        case .note(let m) where m.status == .awaiting: create(m)
        case .noteAppend(let m) where m.status == .awaiting && !m.draft.manual: append(m)
        case .fileWrite(let m) where m.status == .awaiting: confirm(m)
        case .fileOp(let m) where m.status == .awaiting && m.draft.kind != .trash: confirm(m)
        default: return false
        }
        return true
    }

    /// Area di lavoro con le cartelle collegate (e la cartella del progetto), con i loro permessi.
    private func agentWorkspace(_ agent: AgentSpec) -> (links: [String: URL], readOnly: Set<String>) {
        var links: [String: URL] = [:]
        var readOnly: Set<String> = []
        func add(_ name: String, _ url: URL, writable: Bool) {
            var unique = name
            var counter = 2
            while links[unique] != nil { unique = "\(name) \(counter)"; counter += 1 }
            links[unique] = url
            if !writable { readOnly.insert(unique) }
        }
        if let name = agent.projectName, let project = projects.first(where: { $0.name == name }), project.exists {
            add(project.name, project.folder, writable: project.allowWrite)
        }
        for folder in agent.folders where folder.exists { add(folder.name, folder.url, writable: folder.writable) }
        return (links, readOnly)
    }

    /// Un'esecuzione: piano sull'obiettivo, passi eseguiti dai sub-agent, schede da approvare, riepilogo e notifica.
    private func performAgentRun(_ id: UUID, routine routineID: UUID? = nil, trigger: AgentRun.Trigger = .manuale,
                                 claimedRunID: UUID? = nil) async {
        guard let agent = agent(id) else { return }
        let routine = routineID.flatMap { rid in agent.routines.first { $0.id == rid } }
        let conversation = conversation(for: agent)
        let project = agent.projectName.flatMap { name in projects.first { $0.name == name } }
        let soul = soul(of: agent)
        var work = WorkContext()
        let workspace = agentWorkspace(agent)
        if !workspace.links.isEmpty {
            // Più cartelle: una radice virtuale con una voce per cartella, ognuna con il suo permesso.
            let root = Self.agentFolder(id).appending(path: "workspace")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            work.projectName = workspace.links.count == 1 ? workspace.links.keys.first : "cartelle di \(agent.displayName)"
            work.projectRoot = root
            work.linkedFolders = workspace.links
            work.readOnlyFolders = workspace.readOnly
            work.allowFileWrite = workspace.readOnly.count < workspace.links.count
            if let project, project.exists {
                work.agents = project.agentsDigest
                work.memoryDigest = project.memoryDigest
            }
        }
        work.soul = soul
        work.webEnabled = webEnabled && agent.allowWeb
        let agentSpace = Space(rawValue: agent.space) ?? .lavoro
        work.spaceName = agentSpace.label
        work.spaceInstructions = settings(for: agentSpace).instructions
        if agent.allowConnectors {
            work.mcpTools = mcp.allTools.filter { (project?.uses($0.serverID) ?? true) && spaceUses($0.serverID, in: agentSpace) }
            let allowedServers = Set(work.mcpTools.map(\.serverName))
            work.mcpInstructions = mcp.instructions.filter { allowedServers.contains($0.key) }
        }
        work.projectNames = projects.map(\.name)
        let enabled = enabledSources.intersection(agent.allowApps)
        let worker = Assistant()
        worker.isSubAgent = true
        worker.work = work
        var runID = claimedRunID ?? UUID()
        if claimedRunID == nil { updateAgent(id) { runID = $0.beginRun(trigger, routine: routine) } }
        /// Aggiorna la voce dello storico di questa esecuzione.
        func track(_ change: (inout AgentRun) -> Void) { updateAgent(id) { $0.updateRun(runID, change) } }
        updateAgent(id) { $0.record(.avvio, "Inizio dell'esecuzione n. \($0.runs + 1)" + (routine.map { " · \($0.schedule.label)" + ($0.task.isEmpty ? "" : ": \($0.task)") } ?? "")) }
        conversation.messages.append(Message(content: .notice("\(agent.displayName) al lavoro — \(Dates.friendly(.now))")))
        do {
            let plan = try await worker.makeTaskPlan(for: Assistant.agentRunPrompt(agent, task: routine?.task, soul: soul))
            updateAgent(id) { $0.record(.piano, plan.steps.map(\.title).joined(separator: " → ")) }
            let card = TaskPlanCardModel(plan, parallel: subAgentLimit)
            conversation.messages.append(Message(content: .taskPlan(card)))
            card.running = true
            // L'ultimo passo di sola scrittura lo fa il riepilogo finale.
            let steps = card.plan.steps
            let finalIndex = steps.count >= 2 && Assistant.isFinalWriting(steps[steps.count - 1]) ? steps.count - 1 : nil
            for fullBatch in card.plan.batches(maxParallel: card.parallel) {
                guard !Task.isCancelled else { break }
                let batch = fullBatch.filter { $0 != finalIndex }
                guard !batch.isEmpty else { continue }
                for index in batch { card.plan.steps[index].status = "corso" }
                let previous = card.plan.steps.filter { !$0.result.isEmpty }.map { "\($0.title): \($0.result.prefix(700))" }.joined(separator: "\n\n")
                let workers = batch.map { index in
                    let step = card.plan.steps[index]
                    return Task { @MainActor () -> (Int, String, Outcome?) in
                        let (text, outcome) = await self.runStepRetrying(step, previous: previous, work: work, enabled: enabled, into: conversation)
                        return (index, text, outcome)
                    }
                }
                for worker in workers {
                    let (index, text, outcome) = await worker.value
                    let title = card.plan.steps[index].title
                    card.plan.steps[index].result = text
                    if let outcome, let content = cardContent(for: outcome, projectID: project?.id), case .artifact = content {
                        // Un documento creato non è un'azione da approvare.
                        card.plan.steps[index].status = "fatto"
                        conversation.messages.append(Message(content: content))
                        updateAgent(id) { $0.record(.passo, "\(title): documento creato") }
                        track { $0.steps += 1 }
                    } else if let outcome, let content = cardContent(for: outcome, projectID: project?.id) {
                        conversation.messages.append(Message(content: content))
                        if agent.autoApprove, approveAutomatically(content) {
                            card.plan.steps[index].status = "fatto"
                            updateAgent(id) { $0.record(.passo, "\(title): approvato automaticamente") }
                            track { $0.steps += 1 }
                        } else {
                            card.plan.steps[index].status = "conferma"
                            updateAgent(id) { $0.record(.approvazione, "Da approvare: \(title)") }
                            track { $0.approvals += 1 }
                            notify(title: "\(agent.displayName) ha bisogno di te", body: "Da approvare: \(title)")
                        }
                    } else {
                        card.plan.steps[index].status = text.hasPrefix("Errore") ? "errore" : "fatto"
                        updateAgent(id) { $0.record(text.hasPrefix("Errore") ? .errore : .passo, "\(title): \(text.prefix(160))") }
                        track { if text.hasPrefix("Errore") { $0.errors += 1 } else { $0.steps += 1 } }
                    }
                }
                saveConversations()
            }
            card.running = false
            try Task.checkCancellation()
            if let finalIndex { card.plan.steps[finalIndex].status = "corso" }
            let summary = try await worker.chat.respond(to: worker.taskSynthesisPrompt(card.plan), options: worker.responseOptions).content
            try Task.checkCancellation()
            if let finalIndex {
                card.plan.steps[finalIndex].status = "fatto"
                card.plan.steps[finalIndex].result = "Scritto nel riepilogo."
            }
            conversation.messages.append(Message(content: .text(summary)))
            updateAgent(id) { spec in
                spec.lastSummary = String(summary.prefix(1500))
                spec.record(.risultato, String(summary.prefix(220)))
            }
            track { run in
                run.outcome = run.approvals > 0 ? .daApprovare : .completata
                run.summary = String(summary.prefix(1500))
            }
            notify(title: agent.displayName, body: String(summary.prefix(180)))
            log(icon: "sparkles", title: "Agente: \(agent.displayName)", detail: "Esecuzione completata", status: .done)
        } catch is CancellationError {
            conversation.messages.append(Message(content: .notice("Esecuzione interrotta.")))
            track { $0.outcome = .interrotta }
        } catch {
            conversation.messages.append(Message(content: .notice("Esecuzione non riuscita: \(error.localizedDescription)")))
            updateAgent(id) { $0.record(.errore, error.localizedDescription) }
            track { $0.outcome = .errore; $0.summary = error.localizedDescription }
        }
        track { run in
            run.end = .now
            if run.outcome == .inCorso { run.outcome = Task.isCancelled ? .interrotta : .completata }
        }
        updateAgent(id) { spec in
            spec.lastRun = .now
            spec.runs += 1
            if let routineID, let index = spec.routines.firstIndex(where: { $0.id == routineID }) {
                spec.routines[index].lastRun = .now
                spec.routines[index].nextRun = spec.active && spec.routines[index].enabled ? spec.routines[index].schedule.next(after: .now) : nil
            }
        }
        saveConversations()
    }

    // MARK: Sogni

    /// Sogna una volta per notte, dopo l'ora scelta, solo se ha lavorato dall'ultimo sogno.
    private func dreamIsDue(_ agent: AgentSpec, now: Date) -> Bool {
        guard agent.dreamsEnabled, !runningAgents.contains(agent.id) else { return false }
        let calendar = Calendar.current
        guard calendar.component(.hour, from: now) >= agent.dreamHour, calendar.component(.hour, from: now) < agent.dreamHour + 6 else { return false }
        if let last = agent.lastDream, calendar.isDate(last, inSameDayAs: now) { return false }
        let since = agent.lastDream ?? .distantPast
        // Solo dopo lavoro vero: una nota (ritratto, pausa) non basta, altrimenti il sogno inventa una giornata.
        return agent.log.contains { $0.date > since && [.risultato, .approvazione].contains($0.kind) }
    }

    /// Il sogno: l'agente rilegge il suo lavoro, trae lezioni, le scrive nell'anima e migliora le istruzioni.
    func dreamAgent(_ id: UUID) {
        guard let agent = agent(id), !runningAgents.contains(id) else { return }
        runningAgents.insert(id)
        Task {
            defer { runningAgents.remove(id) }
            let conversation = conversation(for: agent)
            let cards = conversation.messages.compactMap { message -> ItemStatus? in
                switch message.content {
                case .event(let m): m.status
                case .reminders(let m): m.status
                case .mail(let m): m.status
                case .fileWrite(let m): m.status
                case .fileOp(let m): m.status
                case .note(let m): m.status
                case .noteAppend(let m): m.status
                case .forward(let m): m.status
                case .imessage(let m): m.status
                case .mcp(let m): m.status
                default: nil
                }
            }
            let accepted = cards.filter { $0 == .done }.count
            let rejected = cards.filter { $0 == .cancelled }.count
            let soul = soul(of: agent)
            let worker = Assistant()
            worker.isSubAgent = true
            do {
                let dream = try await worker.dream(for: agent, soul: soul, approvals: (accepted, rejected))
                let updatedSoul = Assistant.soul(soul, adding: dream.lessons)
                try? updatedSoul.write(to: Self.soulURL(id), atomically: true, encoding: .utf8)
                updateAgent(id) { spec in
                    if !dream.newInstructions.trimmingCharacters(in: .whitespaces).isEmpty { spec.instructions = dream.newInstructions }
                    spec.dreams.append(dream)
                    if spec.dreams.count > 30 { spec.dreams.removeFirst(spec.dreams.count - 30) }
                    spec.lastDream = .now
                    spec.record(.sogno, dream.reflection + (dream.lessons.isEmpty ? "" : " Lezioni: " + dream.lessons.joined(separator: "; ")))
                }
                conversation.messages.append(Message(content: .notice("🌙 \(agent.displayName) ha sognato: \(dream.lessons.count) lezioni aggiunte all'anima.")))
                log(icon: "moon.stars", title: "Sogno di \(agent.displayName)", detail: dream.reflection, status: .done)
            } catch {
                updateAgent(id) { spec in
                    spec.lastDream = .now
                    spec.record(.errore, "Sogno non riuscito: \(error.localizedDescription)")
                }
            }
            saveConversations()
        }
    }

    /// Ripristina le istruzioni che l'agente aveva prima di un sogno.
    func undoDream(_ dream: AgentDream, for agentID: UUID) {
        updateAgent(agentID) { spec in
            spec.instructions = dream.previousInstructions
            spec.record(.nota, "Istruzioni ripristinate a prima del sogno del \(Dates.friendly(dream.date))")
        }
    }

    /// Schede da confermare prodotte dai passi di un agente.
    private func cardContent(for outcome: Outcome, projectID: UUID?) -> Message.Content? {
        switch outcome {
        case .eventDraft(let draft): .event(EventCardModel(draft))
        case .reminderDrafts(let drafts, let list): .reminders(RemindersCardModel(drafts, list: list))
        case .confirm(let action): .confirm(ConfirmCardModel(action))
        case .eventEdit(let edit): .event(EventCardModel(edit.after, edit: edit))
        case .reminderEdit(let edit): .reminders(RemindersCardModel([edit.after], list: edit.afterList, edit: edit))
        case .noteAppend(let draft): .noteAppend(NoteAppendCardModel(draft))
        case .mailReply(let reply): .mail(MailCardModel(reply: reply))
        case .mailForward(let draft): .forward(MailForwardCardModel(draft))
        case .mailDraft(let draft): .mail(MailCardModel(draft))
        case .fileWrite(let draft): .fileWrite(FileWriteCardModel(draft, projectID: projectID))
        case .fileOp(let draft): .fileOp(FileOpCardModel(draft, projectID: projectID))
        case .noteDraft(let draft): .note(NoteCardModel(draft))
        case .messageDraft(let draft): .imessage(MessageCardModel(draft))
        case .mcpCall(let draft): .mcp(MCPCallCardModel(draft))
        case .document(let draft): .artifact(ArtifactModel(kind: .pages, title: draft.title, content: .document(ArtifactFactory.document(from: draft))))
        case .sheet(let draft): .artifact(ArtifactModel(kind: .numbers, title: draft.title, content: .sheet(Spreadsheet(from: draft))))
        case .deck(let draft): .artifact(ArtifactModel(kind: .keynote, title: draft.title, content: .deck(Deck(from: draft))))
        default: nil
        }
    }

    /// Controlla ogni 30 secondi gli agenti programmati. Le esecuzioni perse mentre l'app era chiusa si recuperano una volta.
    private func startAgentScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.schedulerTick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func schedulerTick() {
        let now = Date.now
        for agent in agents where agent.active {
            for routine in agent.routines where routine.enabled && routine.schedule.kind != .manuale {
                if routine.nextRun == nil {
                    updateAgent(agent.id) { spec in
                        if let index = spec.routines.firstIndex(where: { $0.id == routine.id }) { spec.routines[index].nextRun = routine.schedule.next(after: now) }
                    }
                } else if let next = routine.nextRun, next <= now, !runningAgents.contains(agent.id) {
                    let occurrenceID = "\(agent.id.uuidString)|\(routine.id.uuidString)|\(Int(next.timeIntervalSince1970))"
                    // La pretesa viene salvata prima del lavoro: dopo un crash non si ripetono invii o modifiche incerti.
                    if agent.history.contains(where: { $0.occurrenceID == occurrenceID }) {
                        updateAgent(agent.id) { spec in
                            if let index = spec.routines.firstIndex(where: { $0.id == routine.id }) {
                                spec.routines[index].nextRun = routine.schedule.next(after: now)
                            }
                        }
                        continue
                    }
                    let late = now.timeIntervalSince(next) > 5 * 60
                    var runID = UUID()
                    let beforeClaim = agents.first { $0.id == agent.id }
                    let claimed = updateAgent(agent.id) { spec in
                        if late { spec.record(.nota, "Recupero una esecuzione dalle \(Dates.friendly(next)); le altre scadenze passate vengono saltate") }
                        let current = spec.routines.first { $0.id == routine.id }
                        runID = spec.beginRun(late ? .recupero : .programmata, routine: current, occurrenceID: occurrenceID)
                        if let index = spec.routines.firstIndex(where: { $0.id == routine.id }) {
                            spec.routines[index].nextRun = routine.schedule.next(after: now)
                        }
                    }
                    guard claimed else {
                        // Una scrittura fallita non deve lasciare una falsa pretesa solo in memoria:
                        // al prossimo tick la stessa scadenza potrà essere registrata e riprovata.
                        if let beforeClaim, let index = agents.firstIndex(where: { $0.id == agent.id }) {
                            agents[index] = beforeClaim
                        }
                        log(icon: "externaldrive.badge.exclamationmark", title: "Agente non avviato",
                            detail: "Impossibile registrare la scadenza di \(agent.displayName). Controlla lo spazio disponibile e riapri l’app.", status: .failed)
                        return
                    }
                    runAgent(agent.id, routine: routine.id, scheduled: true, heartbeat: agent.heartbeat && routine.schedule.kind == .continuo,
                             trigger: late ? .recupero : .programmata, claimedRunID: runID)
                    break
                }
            }
            if dreamIsDue(agent, now: now) { dreamAgent(agent.id) }
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func loadAgents() -> [AgentSpec] {
        guard let data = try? Data(contentsOf: supportURL("agents.json")) else { return [] }
        var agents = SafeJSON.decodeArray(AgentSpec.self, from: data, label: "agents.json") ?? []
        // Gli agenti creati prima dei nomi umani ricevono un nome di persona.
        for index in agents.indices where agents[index].personName.isEmpty {
            agents[index].personName = AgentSpec.suggestedPersonName(for: agents[index].name, avoiding: agents.map(\.personName))
        }
        // Esecuzioni rimaste «in corso» perché l'app si è chiusa a metà.
        for index in agents.indices {
            for run in agents[index].history.indices where agents[index].history[run].outcome == .inCorso {
                agents[index].history[run].outcome = .interrotta
            }
        }
        return agents
    }

    /// Ritratto scelto nel foglio di Image Playground: copiato nella cartella dell'agente.
    func setAvatar(_ url: URL, for agentID: UUID) {
        let destination = Self.agentFolder(agentID).appending(path: "avatar-\(UUID().uuidString.prefix(6)).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            if let old = agent(agentID)?.avatarPath { try? FileManager.default.removeItem(atPath: old) }
            updateAgent(agentID) { spec in
                spec.avatarPath = destination.path
                spec.record(.nota, "Nuovo ritratto creato con Image Playground")
            }
        } catch {
            log(icon: "photo", title: "Ritratto non salvato", detail: error.localizedDescription, status: .failed)
        }
    }

    /// Descrizione per Image Playground (in inglese capisce meglio).
    func portraitConcept(for agent: AgentSpec) async -> String {
        let person = agent.personName.isEmpty ? "una persona" : agent.personName
        let text = "Ritratto amichevole di \(person), assistente esperto di \(agent.name.lowercased()), sfondo semplice, espressione sorridente"
        return await assistant.englishImagePrompt(text)
    }

    @discardableResult
    func saveAgents() -> Bool {
        guard persists else { return false }
        Self.keepsRunning = agents.contains(where: \.isScheduled)
        guard let data = try? JSONEncoder().encode(agents) else { return false }
        return SafeJSON.write(data, to: Self.supportURL("agents.json"), keepBackup: true)
    }

    // MARK: - Chat figlie

    /// Apre una chat figlia (anche dentro un progetto): quando termina, il riepilogo torna alla chat madre.
    func newChildChat(title: String, project: ProjectModel?, firstMessage: String?) {
        guard let parent = current else { return }
        saveConversations()
        let child = Conversation(title: title.isEmpty ? "Chat figlia" : title, projectID: project?.id, parentID: parent.id)
        child.space = parent.space ?? space.rawValue
        // La figlia sa di cosa si parlava nella madre e usa lo stesso modello.
        child.inherited = Self.handoff(from: parent)
        child.model = parent.model
        parent.messages.append(Message(content: .chatLink(ChatLink(childID: child.id, title: child.title, summary: nil, projectName: project?.name))))
        conversations.insert(child, at: 0)
        currentID = child.id
        if !isResponding { prepareAssistant(for: child) }
        contextUsage = 0
        // Resta dov'eri (app, documenti, browser): si passa al progetto solo dalla Home o da un altro progetto.
        if let project, !showsApps, section != .project(project.id), section == .home || { if case .project = section { true } else { false } }() {
            section = .project(project.id)
        }
        saveConversations()
        if let firstMessage, !firstMessage.trimmingCharacters(in: .whitespaces).isEmpty {
            // Se la risposta interrotta sta ancora finendo, il primo messaggio parte appena si libera (prima andava perso).
            Task {
                while isResponding { try? await Task.sleep(for: .milliseconds(150)) }
                if currentID == child.id { send(firstMessage) }
            }
        }
    }

    /// Ciò che la chat figlia deve sapere della madre: il titolo e gli ultimi scambi (le richieste quasi intere, le risposte in breve).
    static func handoff(from parent: Conversation) -> String {
        ChildChat.handoff(title: parent.title, turns: turns(of: parent))
    }

    private func openRequestedChat(_ request: ChatRequest, project: ProjectModel?) {
        if request.child {
            newChildChat(title: request.title, project: project, firstMessage: request.firstMessage)
        } else {
            newConversation(in: project)
            current?.title = request.title
            if let first = request.firstMessage, !first.isEmpty { send(first) }
        }
        log(icon: "plus.bubble", title: "Chat creata", detail: request.title, status: .done)
    }

    func parent(of conversation: Conversation) -> Conversation? {
        conversation.parentID.flatMap { id in conversations.first { $0.id == id } }
    }

    /// Chiude la chat figlia: riassume risultati e decisioni e li riporta alla chat madre.
    func returnToParent() {
        guard let child = current, let parent = parent(of: child), !isResponding else { return }
        isResponding = true
        setThinking("Riassumo la chat per la chat madre…")
        Task {
            let transcript = Self.turns(of: child).map { "\($0.role == .user ? "Ivan" : "Siri AI+"): \($0.text.prefix(600))" }.joined(separator: "\n")
            let summary = (try? await assistant.summarizeForParent(title: child.title, transcript: transcript)) ?? String(transcript.suffix(800))
            child.messages.removeAll { if case .thinking = $0.content { true } else { false } }
            child.returned = true
            child.messages.append(Message(content: .notice("Chat conclusa: riepilogo inviato a «\(parent.title)».")))
            let project = child.projectID.flatMap { id in projects.first { $0.id == id } }
            // Una sola scheda per figlia: quella «aperta» lascia il posto al riepilogo, in fondo alla madre.
            parent.messages.removeAll { message in
                if case .chatLink(let link) = message.content { link.childID == child.id && link.summary == nil } else { false }
            }
            parent.messages.append(Message(content: .chatLink(ChatLink(childID: child.id, title: child.title, summary: summary, projectName: project?.name))))
            isResponding = false
            saveConversations()
            select(parent)
            if case .project = section, parent.projectID == nil { section = .home }
            log(icon: "arrow.uturn.backward", title: "Chat figlia conclusa", detail: child.title, status: .done)
        }
    }

    func open(childID: UUID) {
        if let conversation = conversations.first(where: { $0.id == childID }) {
            if let projectID = conversation.projectID, let project = projects.first(where: { $0.id == projectID }) { section = .project(project.id) }
            select(conversation)
        }
    }

    // MARK: - Note e Messaggi

    func create(_ card: NoteCardModel) {
        card.status = .running
        Task {
            do {
                let id = try await NotesService.create(card.draft)
                card.createdID = id
                let observed = try? await NotesService.snapshot(id: id)
                let expectedLines = [card.draft.title] + card.draft.body.components(separatedBy: "\n").filter { !$0.isEmpty }
                if let observed, expectedLines.allSatisfy({ observed.text.contains($0) }) {
                    card.status = .done
                    log(icon: "source:notes", title: "Nota verificata", detail: card.draft.title, status: .done)
                    flash(.done)
                } else {
                    card.status = .uncertain
                    card.error = "La nota è stata richiesta a Note, ma non sono riuscita a rileggere il contenuto. Controlla Note prima di riprovare."
                    log(icon: "source:notes", title: "Nota da verificare", detail: card.draft.title, status: .failed)
                }
            } catch {
                card.status = .uncertain
                card.error = "Non posso stabilire se Note abbia creato la nota: \(error.localizedDescription). Controlla Note prima di riprovare."
                flash(.error)
            }
            saveConversations()
        }
    }

    /// Invio di un iMessage: arriva qui solo dopo il dialogo di conferma della scheda.
    func send(_ card: MessageCardModel) {
        card.status = .running
        Task {
            do {
                try await MessagesService.send(card.draft)
                var verified = false
                for _ in 0..<3 {
                    if let rows = try? MessagesService.recent(matching: card.draft.text, limit: 30).rows,
                       rows.contains(where: { $0.title.hasPrefix("Tu →") && $0.detail == card.draft.text && $0.reference == card.draft.handle }) {
                        verified = true; break
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                card.status = verified ? .done : .uncertain
                if verified {
                    log(icon: "source:messages", title: "Messaggio verificato", detail: card.draft.recipient, status: .done)
                    flash(.done)
                } else {
                    card.error = "Messaggi ha accettato l'invio, ma non posso confermarlo. Controlla la conversazione prima di riprovare."
                }
            } catch {
                card.status = .uncertain
                card.error = "Non posso stabilire se il messaggio sia partito: \(error.localizedDescription). Controlla Messaggi prima di riprovare."
                flash(.error)
            }
            saveConversations()
        }
    }

    // MARK: - File di progetto e strumenti esterni

    func confirm(_ card: FileWriteCardModel) {
        guard let project = projects.first(where: { $0.id == card.projectID }) else {
            card.status = .failed
            card.error = "Il progetto non è più collegato."
            return
        }
        do {
            // Copia del file com'era: serve per «Annulla».
            if card.draft.exists, let original = try? project.files.resolve(card.draft.path), FileManager.default.fileExists(atPath: original.path) {
                let backup = AppPaths.support("Annulla").appending(path: "\(UUID().uuidString)-\(original.lastPathComponent)")
                try? FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? FileManager.default.copyItem(at: original, to: backup)) != nil { card.backupPath = backup.path }
            }
            try project.files.write(card.draft.path, content: card.draft.content)
            ProjectGuide.invalidate(project.folder)
            card.doneAt = .now
            if (try? project.files.read(card.draft.path, maxChars: max(card.draft.content.count + 1, 3000))) == card.draft.content {
                card.status = .done
                log(icon: "doc.badge.plus", title: card.draft.exists ? "File modificato e verificato" : "File creato e verificato", detail: "\(project.name)/\(card.draft.path)", status: .done)
            } else {
                card.status = .uncertain
                card.error = "Il file è stato scritto, ma la rilettura non coincide. Controlla il contenuto prima di riprovare."
            }
            projectRevision += 1
            flash(card.status == .done ? .done : .error)
        } catch {
            card.status = .uncertain
            card.error = "Non posso stabilire se il file sia stato modificato: \(error.localizedDescription). Controlla prima di riprovare."
            flash(.error)
        }
    }

    func confirm(_ card: FileOpCardModel) {
        guard let project = projects.first(where: { $0.id == card.projectID }) else {
            card.status = .failed
            card.error = "Il progetto non è più collegato."
            return
        }
        do {
            switch card.draft.kind {
            case .move: try project.files.move(card.draft.from, to: card.draft.to)
            case .folder: try project.files.createFolder(card.draft.from)
            case .trash: card.trashedURL = try project.files.trash(card.draft.from)
            }
            ProjectGuide.invalidate(project.folder)
            card.doneAt = .now
            let verified = switch card.draft.kind {
            case .move: !project.files.exists(card.draft.from) && project.files.exists(card.draft.to)
            case .folder: project.files.exists(card.draft.from)
            case .trash: !project.files.exists(card.draft.from) && card.trashedURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
            }
            card.status = verified ? .done : .uncertain
            if verified {
                log(icon: "folder", title: card.draft.title, detail: "\(project.name)/\(card.draft.from)", status: .done)
                assistant.remember("Operazione eseguita: \(card.draft.title) \(card.draft.from) \(card.draft.to)")
            } else {
                card.error = "L'operazione non è stata confermata dalla rilettura dei file. Controlla prima di riprovare."
            }
            projectRevision += 1
            flash(verified ? .done : .error)
        } catch {
            card.status = .uncertain
            card.error = "Non posso stabilire se l'operazione sui file sia riuscita: \(error.localizedDescription). Controlla prima di riprovare."
            flash(.error)
        }
        saveConversations()
    }

    func approve(_ card: MCPCallCardModel, always: Bool) {
        if always { mcp.setAlwaysAllow(card.draft.tool, true) }
        guard !isResponding else { return }
        let conversation = conversation(containing: card) ?? current
        let scope = scope(forCard: card)
        isResponding = true
        responding = conversation
        responseTask = Task {
            await syncWorkContext()
            await SpaceScope.$task.withValue(scope) { await runMCP(card) }
            conversation?.messages.removeAll { if case .thinking = $0.content { true } else { false } }
            finishResponse()
        }
    }

    /// Esegue la chiamata; se serve un altro passaggio prepara la scheda successiva, altrimenti risponde con tutti i risultati.
    private func runMCP(_ card: MCPCallCardModel) async {
        card.status = .running
        setThinking("Chiedo a \(card.draft.tool.serverName)…")
        do {
            let result = try await mcp.call(card.draft.tool, arguments: card.draft.arguments)
            card.result = String(result.prefix(4000))
            card.status = .done
            log(icon: "puzzlepiece.extension", title: "Strumento esterno: \(card.draft.tool.name)", detail: card.draft.tool.serverName, status: .done)
            setThinking("Valuto il risultato…")
            if let next = await assistant.nextMCPStep(after: card.draft, result: result) {
                let nextCard = MCPCallCardModel(next)
                out?.messages.removeAll { if case .thinking = $0.content { true } else { false } }
                append(.mcp(nextCard))
                if mcp.isAlwaysAllowed(next.tool) { await runMCP(nextCard) }
                return
            }
            let steps = (card.draft.steps ?? []) + [MCPStep(tool: card.draft.tool.name, arguments: card.draft.arguments.compactString, result: String(result.prefix(3000)))]
            await stream(assistant.mcpAnswerPrompt(request: card.draft.request ?? "Risultato di \(card.draft.tool.name)", steps: steps))
        } catch {
            card.status = .failed
            card.error = error.localizedDescription
            out?.messages.removeAll { if case .thinking = $0.content { true } else { false } }
            flash(.error)
        }
    }

    // MARK: - Modifiche AI agli artefatti

    /// Testo del documento: quello dell'editor se è aperto (più aggiornato del modello, che si salva dopo 350 ms).
    func liveDocument(of artifact: ArtifactModel) -> (NSAttributedString, NSTextView?) {
        let live = EditorBridge.pagesArtifactID == artifact.id ? EditorBridge.pagesTextView : nil
        if let storage = live?.textStorage { return (NSAttributedString(attributedString: storage), live) }
        return (artifact.document ?? NSAttributedString(), nil)
    }

    /// Modifiche precise decise dal motore su ciò che è aperto al centro: paragrafi, slide, righe e celle.
    /// Quello che non cambia resta identico; si annulla con ⌘Z (documenti) o dalla cronologia delle versioni.
    private func applyArtifactEdit(_ edit: ArtifactEdit) {
        guard let artifact = openArtifact else { return append(.text("Apri prima un documento, un foglio o una presentazione.")) }
        guard !edit.isEmpty else {
            append(.text(edit.summary.isEmpty ? "Non ho capito cosa cambiare: dimmi quale parte." : edit.summary))
            return
        }
        artifact.snapshot("Prima della modifica di Siri AI+")
        switch edit {
        case .document(let plan):
            applyDocument(plan, to: artifact)
        case .deck(let plan):
            guard case .deck(var deck) = artifact.content else { return }
            let focus = deck.apply(plan.operations)
            if let focus { EditorBridge.focusSlide[artifact.id] = focus }
            artifact.content = .deck(deck)
        case .sheet(let plan, let index):
            guard case .sheet(var spreadsheet) = artifact.content, spreadsheet.sheets.indices.contains(index) else { return }
            spreadsheet.sheets[index].apply(plan.operations)
            artifact.content = .sheet(spreadsheet)
        case .instruction(let text):
            append(.text("Non riesco a modificare questo contenuto con «\(text)»: dimmi quale parte cambiare."))
            return
        }
        let undo = if case .document = edit { " Per annullare: ⌘Z o la cronologia delle versioni." } else { " Per annullare: la cronologia delle versioni." }
        append(.text(edit.summary + undo))
        log(icon: "artifact:\(artifact.kind.rawValue)", title: "\(artifact.kind.noun) modificat\(artifact.kind.ending) da Siri AI+", detail: edit.summary, status: .done)
        flash(.done)
    }

    /// Applica le operazioni al documento: attraverso l'editor se è aperto (così ⌘Z le annulla), altrimenti al modello.
    func applyDocument(_ plan: DocumentEditPlan, to artifact: ArtifactModel) {
        let (current, live) = liveDocument(of: artifact)
        let updated = DocumentBridge.applying(plan.operations, to: current, selection: live?.selectedRange())
        if let live, let storage = live.textStorage,
           live.shouldChangeText(in: NSRange(location: 0, length: storage.length), replacementString: updated.string) {
            storage.beginEditing()
            storage.setAttributedString(updated)
            storage.endEditing()
            // Il testo torna al modello con il salvataggio dell'editor (textDidChange).
            live.didChangeText()
        } else {
            artifact.content = .document(updated)
        }
    }

    /// Menu «Siri AI+» dell'editor senza selezione: la richiesta vale per tutto il documento, un paragrafo alla volta
    /// (prima il documento veniva riscritto per intero e i testi lunghi si troncavano).
    func applyDocumentInstruction(_ instruction: String, to artifact: ArtifactModel) async {
        let (current, _) = liveDocument(of: artifact)
        do {
            let plan = try await assistant.planDocumentEdit(instruction, outline: DocumentBridge.outline(of: current))
            guard !plan.operations.isEmpty else { return showToast(plan.summary, symbol: "info.circle") }
            artifact.snapshot("Prima di «\(instruction.prefix(30))»")
            applyDocument(plan, to: artifact)
            showToast(plan.summary, symbol: "sparkles")
        } catch {
            showToast("Non sono riuscito a modificare il documento.", symbol: "exclamationmark.triangle")
        }
    }

    /// Documento nuovo su un argomento: si apre subito al centro (la chat passa a destra) e si riempie mentre viene scritto.
    private func writeDocument(about topic: String) async {
        let artifact = ArtifactModel(kind: .pages, title: "Nuovo documento", content: .document(ArtifactFactory.document(from: DocumentDraft(literal: ""))))
        artifact.projectID = currentProject?.id
        out?.messages.removeAll { if case .thinking = $0.content { true } else { false } }
        let intro = Message(content: .text("Sto scrivendo il documento: lo vedi prendere forma al centro."))
        out?.messages.append(intro)
        append(.artifact(artifact))
        open(artifact)
        do {
            let draft = try await assistant.streamDocument(topic: topic) { partial in
                guard !partial.title.isEmpty || !partial.sections.isEmpty else { return }
                if !partial.title.isEmpty { artifact.title = partial.title }
                artifact.content = .document(ArtifactFactory.document(from: partial))
            }
            artifact.versions = [ArtifactModel.Version(date: .now, label: "Creato da Siri AI+", content: artifact.content)]
            if let index = out?.messages.firstIndex(where: { $0.id == intro.id }) {
                out?.messages[index].content = .text("Ho scritto il documento «\(draft.title)»: è aperto al centro, pronto da modificare.")
            }
            log(icon: "artifact:pages", title: "Documento creato", detail: draft.title, status: .done)
            flash(.done)
        } catch {
            append(.notice(Task.isCancelled ? "Scrittura interrotta: resta quello che era già pronto." : "Non sono riuscito a scrivere il documento: \(error.localizedDescription)"))
            flash(.error)
        }
    }

    /// Testo semplice → documento con stili: prima riga titolo, righe brevi senza punto finale come intestazioni.
    static func styled(_ plain: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraphs = plain.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (index, paragraph) in paragraphs.enumerated() {
            let clean = paragraph.trimmingCharacters(in: CharacterSet(charactersIn: "#* "))
            let style: PagesStyle = index == 0 ? .title
                : (paragraph.hasPrefix("#") || (clean.count < 60 && !clean.hasSuffix(".") && !clean.hasSuffix(":"))) ? .heading1 : .body
            result.append(style.paragraphText(clean))
        }
        return result
    }

    /// Per l'editor Pages: riscrittura della selezione.
    func rewrite(_ text: String, instruction: String) async throws -> String {
        configureWriter()
        return try await assistant.rewrite(text, instruction: instruction)
    }

    /// Salva l'artefatto nel formato principale, nella cartella del progetto se ce n'è uno.
    @discardableResult
    func save(_ artifact: ArtifactModel) -> URL? {
        let format: ArtifactFactory.ExportFormat = switch artifact.kind {
        case .pages: .docx
        case .numbers: .csv
        case .keynote: .pdf
        }
        do {
            let url = try ArtifactFactory.export(artifact, as: format, folder: projectFolder(for: artifact))
            log(icon: "artifact:\(artifact.kind.rawValue)", title: "\(artifact.kind.noun) salvat\(artifact.kind.ending)", detail: url.lastPathComponent, status: .done)
            projectRevision += 1
            saveConversations()
            return url
        } catch {
            log(icon: "artifact:\(artifact.kind.rawValue)", title: "Salvataggio non riuscito", detail: error.localizedDescription, status: .failed)
            return nil
        }
    }

    func projectFolder(for artifact: ArtifactModel) -> URL? {
        artifact.projectID.flatMap { id in projects.first { $0.id == id }?.folder }
    }

    // MARK: - Azioni delle schede

    func save(_ card: EventCardModel) {
        if let edit = card.edit {
            do {
                card.status = .running
                card.savedStart = try SpaceScope.$task.withValue(scope(forCard: card)) {
                    try EventKitService.update(identifier: edit.identifier, start: edit.originalStart, to: card.draft, expected: edit.before)
                }
                card.doneAt = .now
                let actual = card.savedStart.flatMap { CalendarStore.detail(identifier: edit.identifier, start: $0) }
                if actual?.title == card.draft.title, actual?.start == card.draft.start {
                    card.status = .done
                    log(icon: "source:calendar", title: "Evento modificato e verificato", detail: "\(card.draft.title) · \(Dates.friendly(card.draft.start))", status: .done)
                    flash(.done)
                } else {
                    card.status = .uncertain
                    card.error = "Calendario ha accettato la modifica, ma la rilettura non l'ha confermata. Controlla l'evento prima di riprovare."
                }
            } catch {
                card.status = .uncertain
                card.error = "Non posso stabilire se Calendario abbia modificato l'evento: \(error.localizedDescription). Controlla prima di riprovare."
                log(icon: "source:calendar", title: "Evento non modificato", detail: error.localizedDescription, status: .failed)
                flash(.error)
            }
            return
        }
        do {
            card.status = .running
            card.createdID = try SpaceScope.$task.withValue(scope(forCard: card)) { try EventKitService.save(card.draft) }
            card.doneAt = .now
            let actual = card.createdID.flatMap { CalendarStore.detail(identifier: $0, start: card.draft.start) }
            if actual?.title == card.draft.title, actual?.start == card.draft.start {
                card.status = .done
                log(icon: "source:calendar", title: "Evento creato e verificato", detail: "\(card.draft.title) · \(Dates.friendly(card.draft.start))", status: .done)
                flash(.done)
            } else {
                card.status = .uncertain
                card.error = "Calendario ha accettato l'evento, ma la rilettura non l'ha confermato. Controlla prima di riprovare."
            }
        } catch {
            card.status = .uncertain
            card.error = "Non posso stabilire se Calendario abbia creato l'evento: \(error.localizedDescription). Controlla prima di riprovare."
            log(icon: "source:calendar", title: "Evento non creato", detail: error.localizedDescription, status: .failed)
            flash(.error)
        }
    }

    func add(_ card: RemindersCardModel) {
        if let edit = card.edit, let draft = card.drafts.first {
            do {
                card.status = .running
                try SpaceScope.$task.withValue(scope(forCard: card)) {
                    try EventKitService.update(reminder: edit.identifier, to: draft, list: card.list,
                                               expected: edit.before, expectedList: edit.beforeList)
                }
                card.doneAt = .now
                let actual = EventKitService.reminder(identifier: edit.identifier)
                if actual?.draft.title == draft.title, actual?.list == card.list {
                    card.status = .done
                    log(icon: "source:reminders", title: "Promemoria modificato e verificato", detail: draft.title, status: .done)
                    flash(.done)
                } else {
                    card.status = .uncertain
                    card.error = "Promemoria ha accettato la modifica, ma la rilettura non l'ha confermata. Controlla prima di riprovare."
                }
            } catch {
                card.status = .uncertain
                card.error = "Non posso stabilire se Promemoria abbia modificato l'elemento: \(error.localizedDescription). Controlla prima di riprovare."
                flash(.error)
            }
            return
        }
        do {
            card.status = .running
            let count = card.includedCount
            card.createdIDs = try SpaceScope.$task.withValue(scope(forCard: card)) { try EventKitService.save(card.drafts, list: card.list) }
            card.doneAt = .now
            let expected = card.drafts.filter { $0.included && !$0.title.isEmpty }
            let verified = card.createdIDs.count == expected.count && zip(card.createdIDs, expected).allSatisfy { id, draft in
                let actual = EventKitService.reminder(identifier: id)
                return actual?.draft.title == draft.title && actual?.list == card.list
            }
            if verified {
                card.status = .done
                log(icon: "source:reminders", title: count == 1 ? "Promemoria verificato" : "\(count) promemoria verificati", detail: "Lista \(card.list)", status: .done)
                flash(.done)
            } else {
                card.status = .uncertain
                card.error = "Promemoria ha accettato la richiesta, ma la rilettura non l'ha confermata. Controlla prima di riprovare."
            }
        } catch {
            card.status = .uncertain
            card.error = "Non posso stabilire se Promemoria abbia creato gli elementi: \(error.localizedDescription). Controlla prima di riprovare."
            flash(.error)
        }
    }

    func perform(_ card: ConfirmCardModel) {
        do {
            card.status = .running
            let verified = try SpaceScope.$task.withValue(scope(forCard: card)) { try EventKitService.perform(card.action) }
            card.status = verified ? .done : .uncertain
            let title = switch card.action.kind {
            case .deleteEvent: "Evento eliminato"
            case .deleteReminder: "Promemoria eliminato"
            case .completeReminder: "Promemoria completato"
            }
            if verified {
                log(icon: "source:\(card.source.rawValue)", title: title, detail: card.action.title, status: .done)
                flash(.done)
            } else {
                card.error = "L'app ha accettato l'azione, ma la rilettura non l'ha confermata. Controlla prima di riprovare."
                log(icon: "source:\(card.source.rawValue)", title: "Azione da verificare", detail: card.action.title, status: .failed)
            }
        } catch {
            card.status = .uncertain
            card.error = "Non posso stabilire se l'azione sia stata applicata: \(error.localizedDescription). Controlla l'elemento prima di riprovare."
            flash(.error)
        }
    }

    // MARK: - Annulla

    func undo(_ card: EventCardModel) {
        if let edit = card.edit, let saved = card.savedStart {
            do {
                try EventKitService.update(identifier: edit.identifier, start: saved, to: edit.before)
                card.status = .cancelled
                card.savedStart = nil
                log(icon: "arrow.uturn.backward", title: "Modifica annullata", detail: edit.before.title, status: .cancelled)
            } catch { card.error = error.localizedDescription }
            saveConversations()
            return
        }
        guard let id = card.createdID else { return }
        do {
            try EventKitService.remove(identifiers: [id])
            card.status = .cancelled
            card.createdID = nil
            log(icon: "arrow.uturn.backward", title: "Evento annullato", detail: card.draft.title, status: .cancelled)
        } catch { card.error = error.localizedDescription }
        saveConversations()
    }

    func undo(_ card: RemindersCardModel) {
        if let edit = card.edit {
            do {
                try EventKitService.update(reminder: edit.identifier, to: edit.before, list: edit.beforeList)
                card.status = .cancelled
                log(icon: "arrow.uturn.backward", title: "Modifica annullata", detail: edit.before.title, status: .cancelled)
            } catch { card.error = error.localizedDescription }
            saveConversations()
            return
        }
        guard !card.createdIDs.isEmpty else { return }
        do {
            try EventKitService.remove(identifiers: card.createdIDs)
            card.status = .cancelled
            card.createdIDs = []
            log(icon: "arrow.uturn.backward", title: "Promemoria annullati", detail: "Lista \(card.list)", status: .cancelled)
        } catch { card.error = error.localizedDescription }
        saveConversations()
    }

    func undo(_ card: FileWriteCardModel) {
        guard let project = projects.first(where: { $0.id == card.projectID }), let url = try? project.files.resolve(card.draft.path) else { return }
        do {
            if let backup = card.backupPath {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: URL(fileURLWithPath: backup))
            } else {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            project.files.invalidateCache()
            ProjectGuide.invalidate(project.folder)
            card.status = .cancelled
            card.backupPath = nil
            projectRevision += 1
            log(icon: "arrow.uturn.backward", title: card.draft.exists ? "Modifica annullata" : "File tolto", detail: card.draft.path, status: .cancelled)
        } catch { card.error = error.localizedDescription }
        saveConversations()
    }

    func undo(_ card: FileOpCardModel) {
        guard let project = projects.first(where: { $0.id == card.projectID }) else { return }
        do {
            switch card.draft.kind {
            case .move: try project.files.move(card.draft.to, to: card.draft.from)
            case .folder: try project.files.trash(card.draft.from)
            case .trash:
                guard let trashed = card.trashedURL else { return }
                try FileManager.default.moveItem(at: trashed, to: try project.files.resolve(card.draft.from))
                project.files.invalidateCache()
            }
            ProjectGuide.invalidate(project.folder)
            card.status = .cancelled
            projectRevision += 1
            log(icon: "arrow.uturn.backward", title: "\(card.draft.title) annullato", detail: card.draft.from, status: .cancelled)
        } catch { card.error = error.localizedDescription }
        saveConversations()
    }

    /// Apre la finestra di composizione di Mail: l'invio resta nelle mani dell'utente.
    func openInMail(_ card: MailCardModel) {
        card.status = .running
        Task {
            do {
                let verified = try await MailComposer.compose(to: card.recipientList, subject: card.subject, body: card.body)
                card.status = verified ? .opened : .uncertain
                if verified {
                    log(icon: "source:mail", title: "Bozza aperta in Mail", detail: "\(card.subject) · \(card.recipientList.count) destinatari", status: .done)
                    flash(.done)
                } else {
                    card.error = "Mail ha creato la bozza, ma la rilettura non l'ha confermata. Controlla Mail prima di riprovare."
                }
            } catch {
                card.status = .uncertain
                card.error = "Non posso stabilire se Mail abbia aperto la bozza: \(error.localizedDescription). Controlla Mail prima di riprovare."
            }
            saveConversations()
        }
    }

    /// Risposta in Mail nella stessa conversazione, con l'email originale citata. Se Mail non collabora, una bozza nuova con gli stessi testi.
    func openReply(_ card: MailCardModel) {
        guard let reply = card.reply else { return openInMail(card) }
        card.status = .running
        let body = card.body + "\n\n" + reply.quote
        Task {
            do {
                try await MailComposer.reply(to: reply.messageID, body: body, replyAll: reply.replyAll)
                card.status = .opened
                log(icon: "source:mail", title: "Risposta aperta in Mail", detail: card.subject, status: .done)
                flash(.done)
            } catch {
                card.status = .uncertain
                card.error = "Non posso stabilire se Mail abbia aperto la risposta: \(error.localizedDescription). Controlla Mail prima di riprovare."
                flash(.error)
            }
            saveConversations()
        }
    }

    /// Inoltro in Mail con gli allegati: l'utente lo invia da lì.
    func openForward(_ card: MailForwardCardModel) {
        card.status = .running
        Task {
            do {
                try await MailComposer.forward(card.draft.messageID, to: card.draft.recipientAddress.trimmingCharacters(in: .whitespaces),
                                               name: card.draft.recipientName)
                card.status = .opened
                log(icon: "source:mail", title: "Inoltro aperto in Mail", detail: card.draft.subject, status: .done)
                flash(.done)
            } catch {
                card.status = .uncertain
                card.error = "Non posso stabilire se Mail abbia aperto l'inoltro: \(error.localizedDescription). Controlla Mail prima di riprovare."
                flash(.error)
            }
            saveConversations()
        }
    }

    /// Aggiunge le righe in fondo alla nota (solo se nel frattempo non è cambiata e non ha liste o allegati);
    /// altrimenti copia il testo e apre la nota.
    func append(_ card: NoteAppendCardModel) {
        let lines = card.lines
        if card.draft.manual {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            Task { await NotesService.open(id: card.draft.noteID) }
            card.status = .copied
            log(icon: "source:notes", title: "Testo copiato per la nota", detail: card.draft.title, status: .done)
            saveConversations()
            return
        }
        card.status = .running
        Task {
            do {
                let snapshot = try await NotesService.snapshot(id: card.draft.noteID)
                guard NotesService.canAppendSafely(snapshot.html) else {
                    throw AppleAppError.script("La nota ora ha liste o allegati che Note perderebbe: aggiungi il testo dall'app Note.")
                }
                let saved = try await NotesService.append(id: card.draft.noteID, lines: lines, expectedHTML: snapshot.html)
                card.previousHTML = snapshot.html
                card.savedHTML = saved.html
                card.doneAt = .now
                card.status = .done
                log(icon: "source:notes", title: "Nota aggiornata", detail: "\(card.draft.title) · \(lines.count == 1 ? "1 riga" : "\(lines.count) righe")", status: .done)
                flash(.done)
            } catch {
                card.status = .failed
                card.error = error.localizedDescription
                flash(.error)
            }
            saveConversations()
        }
    }

    func undo(_ card: NoteAppendCardModel) {
        guard let previous = card.previousHTML, let saved = card.savedHTML else { return }
        Task {
            do {
                _ = try await NotesService.replaceBody(id: card.draft.noteID, html: previous, expectedHTML: saved)
                card.status = .cancelled
                card.previousHTML = nil
                log(icon: "arrow.uturn.backward", title: "Aggiunta annullata", detail: card.draft.title, status: .cancelled)
            } catch { card.error = error.localizedDescription }
            saveConversations()
        }
    }

    func resolve(_ card: UnavailableCardModel) {
        switch card.kind {
        case .notConnected: setEnabled(card.source, true)
        case .readOnly: setAllowWrite(card.source, true)
        case .notSelected, .comingSoon: break
        }
        card.resolved = true
        if card.kind != .comingSoon {
            Task {
                try? await Task.sleep(for: .milliseconds(card.kind == .notConnected ? 900 : 100))
                run(card.prompt, sources: [], files: [])
            }
        }
    }

    func execute(_ card: PlanCardModel) {
        configureWriter()
        card.status = .running
        let scope = scope(forCard: card)
        Task { await SpaceScope.$task.withValue(scope) {
            var created: [ArtifactModel] = []
            for step in card.plan.steps {
                guard step.included else { card.stepStatus[step.id] = .cancelled; continue }
                card.stepStatus[step.id] = .running
                do {
                    card.stepResult[step.id] = try await perform(step, collecting: &created)
                    card.stepStatus[step.id] = .done
                } catch {
                    card.stepStatus[step.id] = .failed
                    card.stepResult[step.id] = error.localizedDescription
                }
            }
            let failed = card.plan.steps.contains { card.stepStatus[$0.id] == .failed }
            card.status = failed ? .failed : .done
            flash(failed ? .error : .done)
            if let artifact = created.last { open(artifact) }
            saveConversations()
        } }
    }

    private func perform(_ step: PlanDraft.Step, collecting artifacts: inout [ArtifactModel]) async throws -> String {
        struct StepError: LocalizedError { let errorDescription: String? }
        switch step.kind {
        case .evento:
            guard canWrite(.calendar) else { throw StepError(errorDescription: "Serve l'accesso in scrittura al Calendario") }
            guard let when = Dates.parse(step.when) else { throw StepError(errorDescription: "Data mancante: crealo dalla chat") }
            let start = when.hasTime ? when.date : Calendar.current.startOfDay(for: when.date)
            let draft = EventDraft(title: step.title, start: start, end: start.addingTimeInterval(when.hasTime ? 3600 : 86_399),
                                   isAllDay: !when.hasTime, calendar: EventKitService.defaultCalendar, notes: step.detail)
            try EventKitService.save(draft)
            log(icon: "source:calendar", title: "Evento creato", detail: "\(step.title) · \(Dates.friendly(start, time: when.hasTime))", status: .done)
            return "Creato · \(Dates.friendly(start, time: when.hasTime))"
        case .promemoria:
            guard canWrite(.reminders) else { throw StepError(errorDescription: "Serve l'accesso in scrittura ai Promemoria") }
            let due = Dates.parse(step.when)
            try EventKitService.save([ReminderDraft(title: step.title, due: due?.date, dueHasTime: due?.hasTime ?? false)],
                                     list: EventKitService.defaultReminderList)
            log(icon: "source:reminders", title: "Promemoria aggiunto", detail: step.title, status: .done)
            return "Aggiunto a \(EventKitService.defaultReminderList)"
        case .email:
            let draft = try await assistant.generateMail(topic: "\(step.title). \(step.detail)", recipients: nil)
            append(.mail(MailCardModel(draft)))
            return "Bozza pronta: confermi tu l'invio"
        case .documento:
            let draft = try await assistant.generateDocument(topic: "\(step.title). \(step.detail)")
            let artifact = ArtifactModel(kind: .pages, title: draft.title, content: .document(ArtifactFactory.document(from: draft)), projectID: currentProject?.id)
            append(.artifact(artifact)); artifacts.append(artifact)
            log(icon: "artifact:pages", title: "Documento creato", detail: draft.title, status: .done)
            return "Documento pronto"
        case .foglio:
            let draft = try await assistant.generateSheet(topic: "\(step.title). \(step.detail)")
            let artifact = ArtifactModel(kind: .numbers, title: draft.title, content: .sheet(Spreadsheet(from: draft)), projectID: currentProject?.id)
            append(.artifact(artifact)); artifacts.append(artifact)
            log(icon: "artifact:numbers", title: "Foglio creato", detail: draft.title, status: .done)
            return "Foglio pronto"
        case .presentazione:
            let draft = try await assistant.generateDeck(topic: "\(step.title). \(step.detail)")
            let artifact = ArtifactModel(kind: .keynote, title: draft.title, content: .deck(Deck(from: draft)), projectID: currentProject?.id)
            append(.artifact(artifact)); artifacts.append(artifact)
            log(icon: "artifact:keynote", title: "Presentazione creata", detail: draft.title, status: .done)
            return "Presentazione pronta"
        }
    }

    func complete(_ reminder: ReminderItem) {
        do {
            try Overview.setCompleted(reminderID: reminder.id, true)
            log(icon: "source:reminders", title: "Promemoria completato", detail: reminder.title, status: .done)
        } catch {
            append(.notice("Impossibile completare «\(reminder.title)»: \(error.localizedDescription)"))
        }
    }

    // MARK: - Allegati

    func attach(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Foto e screenshot: il modello le guarda direttamente (copiate tra i dati dell'app, così restano leggibili).
            if UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) == true {
                if let copy = Self.keepAttachment(url) {
                    attachments.append(Attachment(name: url.lastPathComponent, text: "", imageURL: copy))
                } else {
                    append(.notice("Non riesco a leggere l'immagine «\(url.lastPathComponent)»."))
                }
                continue
            }
            var text = ""
            if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) {
                text = document.string ?? ""
                // PDF scansionato (senza testo): le prime pagine diventano immagini da leggere.
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                    let pages = Self.renderPages(of: document, limit: 2)
                    for (index, page) in pages.enumerated() {
                        attachments.append(Attachment(name: "\(url.lastPathComponent) · pagina \(index + 1)", text: "", imageURL: page))
                    }
                    if pages.isEmpty { append(.notice("Non riesco a leggere il PDF «\(url.lastPathComponent)».")) }
                    continue
                }
            } else if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                text = attributed.string
            }
            guard !text.isEmpty else {
                append(.notice("Non riesco a leggere il testo di «\(url.lastPathComponent)»."))
                continue
            }
            attachments.append(Attachment(name: url.lastPathComponent, text: text))
        }
    }

    /// Cartella delle immagini allegate: si tengono 7 giorni (servono solo alla richiesta e alle domande successive).
    private static var attachmentFolder: URL {
        let folder = AppPaths.support("Allegati")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date.now.addingTimeInterval(-7 * 86_400)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now) < old {
            try? FileManager.default.removeItem(at: file)
        }
        return folder
    }

    private static func keepAttachment(_ url: URL) -> URL? {
        let copy = attachmentFolder.appending(path: "\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            Agent.log("ALLEGATO NON COPIATO «\(url.lastPathComponent)»: \(error)")
            return nil
        }
    }

    /// Pagine di un PDF senza testo come PNG (per la lettura con la visione del modello).
    private static func renderPages(of document: PDFDocument, limit: Int) -> [URL] {
        (0..<min(limit, document.pageCount)).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let image = page.thumbnail(of: CGSize(width: 1400, height: 1800), for: .mediaBox)
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            let url = attachmentFolder.appending(path: "\(UUID().uuidString.prefix(8))-pagina-\(index + 1).png")
            return (try? png.write(to: url)) != nil ? url : nil
        }
    }

    // MARK: - Cronologia

    private static func supportURL(_ name: String) -> URL { AppPaths.support(name) }

    private static func loadConversations() -> [Conversation] {
        guard let data = try? Data(contentsOf: supportURL("conversations.json")),
              let stored = SafeJSON.decodeArray(StoredConversation.self, from: data, label: "conversations.json") else { return [] }
        return stored.map { item in
            let conversation = Conversation(id: item.id, title: item.title, created: item.created, projectID: item.projectID, parentID: item.parentID)
            conversation.pinned = item.pinned ?? false
            conversation.returned = item.returned ?? false
            conversation.agentID = item.agentID
            conversation.space = item.space
            conversation.kind = item.kind ?? .standard
            conversation.model = item.model
            conversation.inherited = item.inherited
            conversation.privacyVault = item.privacyVault
            conversation.messages = item.messages.compactMap(Message.init)
            return conversation
        }
    }

    /// Riga leggibile di un messaggio (diagnostica).
    static func describe(_ content: Message.Content) -> String {
        switch content {
        case .user(let text, _, _): "UTENTE: \(text)"
        case .text(let text): "TESTO: \(text.prefix(400).replacingOccurrences(of: "\n", with: " ¶ "))"
        case .notice(let text): "AVVISO: \(text)"
        case .privacy(let report): "DATI PROTETTI [\(report.destination)]: \(report.total) (\(report.summary))"
        case .trace(let trace): "TRACCIA [\(trace.model)]: " + trace.steps.map { "\($0.action)(\($0.detail.prefix(80))) → \($0.result.prefix(80))" }.joined(separator: " | ")
        case .agenda(let agenda): "SCHEDA agenda: \(agenda.events.count) eventi, \(agenda.reminders.count) promemoria"
        case .event(let m): "SCHEDA evento: \(m.draft.title) \(Dates.friendly(m.draft.start))"
        case .reminders(let m): "SCHEDA promemoria: \(m.drafts.map(\.title))"
        case .mail(let m): "SCHEDA email: \(m.subject)"
        case .mcp(let m): "SCHEDA connettore: \(m.draft.tool.name) \(m.status)"
        case .fileWrite(let m): "SCHEDA file: \(m.draft.path)"
        case .web(let answer): "SCHEDA web: \(answer.sources.count) fonti"
        case .items(let items): "SCHEDA \(items.title): \(items.rows.count)"
        case .chatLink(let link): "SCHEDA chat figlia «\(link.title)»: " + (link.summary.map { "riepilogo: \($0.prefix(400).replacingOccurrences(of: "\n", with: " ¶ "))" } ?? "aperta")
        default: "ALTRO: \(String(describing: content).prefix(120))"
        }
    }

    /// Chat da reinserire (`recupero-conversazioni.json`, stesso formato di conversations.json): si aggiungono solo quelle che mancano.
    private func importRecoveredConversations() {
        let url = Self.supportURL("recupero-conversazioni.json")
        guard persists, let data = try? Data(contentsOf: url),
              let stored = SafeJSON.decodeArray(StoredConversation.self, from: data, label: "recupero-conversazioni.json") else { return }
        let known = Set(conversations.map(\.id))
        let recovered = stored.filter { !known.contains($0.id) }.map { item in
            let conversation = Conversation(id: item.id, title: item.title, created: item.created, projectID: item.projectID, parentID: item.parentID)
            conversation.pinned = item.pinned ?? false
            conversation.agentID = item.agentID
            conversation.space = item.space
            conversation.kind = item.kind ?? .standard
            conversation.model = item.model
            conversation.inherited = item.inherited
            conversation.privacyVault = item.privacyVault
            conversation.messages = item.messages.compactMap(Message.init)
            return conversation
        }
        conversations += recovered
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if !recovered.isEmpty {
            saveConversations()
            LogFile.append("RECUPERO: \(recovered.count) conversazioni reinserite")
        }
    }

    /// Salva tutte le conversazioni con almeno un messaggio (anche quelle dei progetti).
    func saveConversations() {
        guard persists else { return }
        let stored = conversations.filter { !$0.messages.isEmpty || $0.kind == .quick }.map { conversation in
            StoredConversation(id: conversation.id, title: conversation.title, created: conversation.created,
                               messages: conversation.messages.compactMap(\.stored),
                               projectID: conversation.projectID, pinned: conversation.pinned,
                               parentID: conversation.parentID, returned: conversation.returned, agentID: conversation.agentID,
                               space: conversation.space, kind: conversation.kind, model: conversation.model, inherited: conversation.inherited,
                               privacyVault: conversation.privacyVault)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        SafeJSON.write(data, to: Self.supportURL("conversations.json"), keepBackup: true)
        saveTabsByOwner()
        indexConversations()
    }

    /// Aggiorna l'indice di ricerca solo per le conversazioni cambiate (in secondo piano).
    private func indexConversations() {
        var changes: [(String, String, String, Date)] = []
        for conversation in conversations where !conversation.messages.isEmpty && indexed[conversation.id] != conversation.messages.count {
            indexed[conversation.id] = conversation.messages.count
            let body = conversation.messages.compactMap { message -> String? in
                switch message.content {
                case .user(let text, _, _): "Ivan: " + text
                case .text(let text): text
                case .chatLink(let link): link.summary
                default: nil
                }
            }.joined(separator: "\n")
            changes.append((conversation.id.uuidString, conversation.title, String(body.prefix(40_000)), conversation.created))
        }
        guard !changes.isEmpty else { return }
        Task.detached(priority: .utility) {
            for (id, title, body, date) in changes { ConversationIndex.shared.update(id: id, title: title, body: body, date: date) }
        }
    }

    var mailDrafts: [(conversation: Conversation, card: MailCardModel)] {
        conversations.flatMap { conversation in
            conversation.messages.compactMap { message in
                if case .mail(let card) = message.content { (conversation, card) } else { nil }
            }
        }
    }

    // MARK: - Registro

    func log(icon: String, title: String, detail: String, status: ItemStatus) {
        activity.insert(ActivityEntry(icon: icon, title: title, detail: detail, status: status), at: 0)
        if activity.count > 300 { activity.removeLast(activity.count - 300) }
        scheduleSave()
    }

    /// Salvataggio raggruppato: più eventi ravvicinati producono una sola scrittura.
    func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveConversations()
            saveActivity()
        }
    }

    func clearActivity() {
        activity = []
        saveActivity()
    }

    private static func loadActivity() -> [ActivityEntry] {
        guard let data = try? Data(contentsOf: supportURL("activity.json")) else { return [] }
        return SafeJSON.decodeArray(ActivityEntry.self, from: data, label: "activity.json") ?? []
    }

    private func saveActivity() {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(activity) { SafeJSON.write(data, to: Self.supportURL("activity.json")) }
    }
}
