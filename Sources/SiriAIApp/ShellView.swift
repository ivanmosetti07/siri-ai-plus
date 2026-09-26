import AppKit
import SiriCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case home, project(UUID), app(SourceKind), browser, documents(ArtifactKind), conversation(UUID), automations, activity, connectors, settings, agents, agent(UUID), schedule
}

private struct CompactLayoutKey: EnvironmentKey { static let defaultValue = false }
private struct ChatNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }

extension EnvironmentValues {
    /// Spazio condiviso tra la chat della Home e la colonna destra: la conversazione si sposta invece di sparire e riapparire.
    var chatNamespace: Namespace.ID? {
        get { self[ChatNamespaceKey.self] }
        set { self[ChatNamespaceKey.self] = newValue }
    }
}

/// La conversazione della Home e la colonna destra sono la stessa lastra: con un documento aperto scivola a destra.
struct ChatGeometry: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "conversazione", in: namespace)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// Vero nella colonna di Siri AI+: spaziature ridotte.
    var compactLayout: Bool {
        get { self[CompactLayoutKey.self] }
        set { self[CompactLayoutKey.self] = newValue }
    }
}

/// Finestra principale: barra laterale | contesto di lavoro al centro | Siri AI+ sempre a destra.
struct ShellView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @Namespace private var chatSpace

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 320)
        } detail: {
            // Colonna destra fatta a mano: `.inspector` accanto a viste scorrevoli manda AppKit
            // in un ciclo di vincoli su macOS 27 e l'app termina.
            GeometryReader { geometry in
            HStack(spacing: 0) {
                // minWidth 0: se il contenuto del centro è largo non spinge la colonna destra fuori dalla finestra.
                CenterView()
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                // Alla Home la chat occupa il centro: passa nella colonna destra solo quando si apre qualcosa.
                if state.showsSidePanel {
                    SidePanel(maxWidth: max(300, min(600, geometry.size.width - 540))) {
                        if let project = state.openCodingProject { CodePanel(project: project).id(project.id) } else { AssistantPanel() }
                    }
                    // Dalla Home la conversazione si sposta (stessa lastra); altrimenti la colonna entra da destra.
                    .modifier(ChatGeometry(namespace: state.openCodingProject == nil ? chatSpace : nil))
                    .transition(state.chatMovesFromHome ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            }
            .environment(\.chatNamespace, chatSpace)
            .animation(.smooth(duration: 0.45), value: state.showsSidePanel)
            // L'aurora dello spazio dietro a tutto (la Home con il meteo ha il suo cielo).
            .background {
                if !state.homeShowsSky {
                    AtmosphereBackdrop(space: state.space, energetic: state.isResponding)
                        .ignoresSafeArea()
                }
            }
            .toolbar { ShellToolbar() }
            .toolbar(removing: .title)
        }
        .overlay {
            if state.voice.active { VoiceModeView() }
        }
        // Diagnostica (`--model-panel-demo`): il pannello dei modelli sopra la finestra, per fotografarlo.
        .overlay(alignment: .bottomTrailing) {
            if AppTesting.ephemeral, CommandLine.arguments.contains("--model-panel-demo") {
                ModelPickerPanel(current: state.resolved(state.selection), showsTools: true) { choice, _ in state.choose(choice) } close: {}
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.trailing, 40).padding(.bottom, 110)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .onChange(of: state.settingsRequest) { openSettings() }
        .animation(.easeInOut(duration: 0.25), value: state.voice.active)
        .sheet(isPresented: $state.showSourcesSheet) { SourcesSheet() }
        .sheet(isPresented: $state.showCommandPalette) { CommandPalette() }
        .sheet(isPresented: $state.showChildSheet) { NewChildChatSheet() }
        .sheet(item: $state.editingAgent) { agent in AgentEditor(agent: agent) }
        .sheet(item: $state.newCodeTemplate) { template in NewCodeProjectSheet(template: template) }
        .alert("La privacy è a rischio", isPresented: $state.askCloudConsent, presenting: state.pendingCloud) { cloud in
            Button("Usa \(cloud.provider.name)", role: .destructive) { state.apply(cloud) }
            Button("Annulla", role: .cancel) {}
        } message: { cloud in
            Text("Con \(cloud.provider.name) le risposte non sono più generate sul Mac: la richiesta, la conversazione recente e i dati usati per rispondere (calendario, file, pagine, connettori) vengono inviati a \(cloud.provider.company). Continuare?")
        }
    }
}

struct CenterView: View {
    @Environment(AppState.self) private var state

    /// Cambia solo quando cambia la sezione (non a ogni aggiornamento del contenuto): serve per la dissolvenza.
    /// Le schede delle app sono una sezione sola: passando dall'una all'altra non si ricrea nulla.
    private var sectionKey: String { state.showsApps ? "app" : "\(state.section)" }

    var body: some View {
        ZStack {
            // Le schede delle app restano vive anche dietro la chat e le altre sezioni: con «App» ritrovi tutto com'era.
            // Ogni chat ha le sue app: cambiando chat si vedono le sue (le pagine di Safari restano con la loro chat).
            if state.showsApps || !state.appTabs.isEmpty {
                AppTabsView()
                    .id(state.tabOwner)
                    .opacity(state.showsApps ? 1 : 0)
                    .allowsHitTesting(state.showsApps)
                    .disabled(!state.showsApps)
                    .accessibilityHidden(!state.showsApps)
            }
            if !state.showsApps {
                Group {
                    switch state.section {
                    case .home: if state.space == .codice { CodeHomeView() } else { HomeView() }
                    // Le app, Safari, i documenti e la «Nuova scheda» stanno nelle schede qui sopra.
                    case .app, .browser, .appLauncher, .documents, .artifact, .file, .chats: EmptyView()
                    case .project(let id):
                        if let project = state.projects.first(where: { $0.id == id }) {
                            if project.space == Space.codice.rawValue { CodeWorkspaceView(project: project) } else { ProjectView(project: project) }
                        } else { HomeDashboard() }
                    case .activity: ActivityView()
                    case .automations: AgentsGallery()
                    case .connectors: ConnectorsView()
                    case .settings: SettingsView()
                    case .agents: AgentsGallery()
                    case .agent(let id): AgentDetailView(agentID: id).id(id)
                    case .schedule: ScheduleCenterView()
                    }
                }
                .id(sectionKey)
                .transition(.opacity)
            }
        }
        .animation(DS.Motion.standard, value: sectionKey)
    }
}

/// Colonna destra: una lastra di vetro sospesa sull'aurora, ridimensionabile trascinando il bordo sinistro.
struct SidePanel<Content: View>: View {
    var maxWidth: CGFloat = 600
    @ViewBuilder var content: Content
    @AppStorage("sidePanelWidth") private var width = 400.0
    @State private var dragStart = Double?.none
    var body: some View {
        content
            .frame(width: min(max(300, width.isFinite ? width : 400), maxWidth))
            .frame(maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 26))
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .onTapGesture(count: 2) { withAnimation(DS.Motion.standard) { width = 400 } }
                    .accessibilityLabel("Bordo del pannello: trascina per ridimensionare, doppio clic per la larghezza normale")
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? width
                                dragStart = start
                                width = min(maxWidth, max(300, start - value.translation.width))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .offset(x: -5)
            }
            .padding(.top, 6)
            .padding(.bottom, 10)
            .padding(.trailing, 10)
            .padding(.leading, 4)
    }
}

struct ShellToolbar: ToolbarContent {
    @Environment(AppState.self) private var state

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                // Larghezza fissa: se la toolbar cambia dimensione a ogni aggiornamento macOS ricalcola i margini in un ciclo.
                .frame(width: 260, alignment: .leading)
                .padding(.horizontal, 6)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.smooth(duration: 0.4)) { state.toggleApps() }
            } label: {
                Label("App", systemImage: state.showsApps ? "square.grid.2x2.fill" : "square.grid.2x2")
            }
            .iconHelp(state.appsToggleHelp)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { state.showCommandPalette = true } label: { Image(systemName: "magnifyingglass") }
                .iconHelp("Cerca e vai a… (⌘K)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.smooth(duration: 0.3)) { state.showAssistant.toggle() }
            } label: {
                Label("Siri AI+", systemImage: "sidebar.right")
            }
            .disabled(state.section == .home)
            .iconHelp(state.showAssistant ? "Nascondi l'assistente (⌥⌘S)" : "Mostra l'assistente (⌥⌘S)")
        }
    }

    private var title: String {
        switch state.section {
        case .home:
            // Nella Home con una chat aperta il titolo è quello della chat, come in ChatGPT.
            if let current = state.current, !current.messages.isEmpty { current.title } else { state.space == .codice ? "Programmazione" : "Home" }
        case .app(let source): source.label
        case .browser: state.browser.title.isEmpty ? "Safari" : state.browser.title
        case .appLauncher: "App"
        case .file(let url): url.lastPathComponent
        case .chats(let group): state.title(of: .chats(group))
        case .documents(let kind): kind.app
        case .project(let id): state.projects.first { $0.id == id }?.name ?? "Progetto"
        case .artifact: state.openArtifact?.title ?? "Documento"
        case .activity: "Attività e privacy"
        case .automations: "Agenti"
        case .connectors: "Connettori"
        case .settings: "Impostazioni"
        case .agents: "Agenti"
        case .agent(let id): state.agent(id)?.displayName ?? "Agente"
        case .schedule: "Programmazioni"
        }
    }
}
