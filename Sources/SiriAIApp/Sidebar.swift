import AppKit
import SiriCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Barra laterale

struct SidebarView: View {
    @Environment(AppState.self) private var state
    /// La cronologia sta in alto: di default mostra solo le conversazioni più recenti.
    @State private var showAllHistory = false
    private let historyLimit = 8
    @State private var visibleGeniusCount = 8
    private let geniusBatchSize = 8
    /// Progetti aperti nella barra laterale (quello fissato o aperto si apre da solo).
    @State private var expanded = Set<UUID>()
    @State private var collapsed = Set<UUID>()
    @State private var expandedGenius = Set<UUID>()
    @State private var collapsedGenius = Set<UUID>()
    /// Cosa si sta per eliminare (serve una conferma).
    enum Deletion: Identifiable {
        case conversation(Conversation), project(ProjectModel), agent(AgentSpec)
        var id: String {
            switch self {
            case .conversation(let c): "c" + c.id.uuidString
            case .project(let p): "p" + p.id.uuidString
            case .agent(let a): "a" + a.id.uuidString
            }
        }
        var title: String {
            switch self {
            case .conversation(let c): String(localized: "Eliminare la conversazione «\(c.title)»?")
            case .project(let p): String(localized: "Rimuovere il progetto «\(p.name)»?")
            case .agent(let a): String(localized: "Eliminare il Genius «\(a.displayName)»?")
            }
        }
        var message: String {
            switch self {
            case .conversation: String(localized: "La conversazione e le sue schede verranno cancellate.")
            case .project(let p) where p.managed: String(localized: "Le chat del progetto verranno cancellate; la sua memoria e i suoi file finiscono nel Cestino.")
            case .project: String(localized: "Le chat del progetto verranno cancellate. La cartella e i suoi file restano sul Mac.")
            case .agent: String(localized: "Chat, registro, anima, skill dedicate e programmazioni del Genius verranno cancellati.")
            }
        }
    }
    @State private var deletion = Deletion?.none
    @AppStorage("sidebarShowApps") private var showApps = true

    private func footerButton(_ help: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(Color.accentColor.opacity(0.25)).interactive() : .regular.interactive(), in: .circle)
        .iconHelp(help)
    }
    private func expansion(for project: ProjectModel) -> Binding<Bool> {
        Binding(
            get: {
                if collapsed.contains(project.id) { return false }
                if expanded.contains(project.id) { return true }
                if case .project(let id) = state.section, id == project.id { return true }
                return state.current?.projectID == project.id
            },
            set: { open in
                if open { expanded.insert(project.id); collapsed.remove(project.id) }
                else { collapsed.insert(project.id); expanded.remove(project.id) }
            }
        )
    }

    private func expansion(for agent: AgentSpec) -> Binding<Bool> {
        Binding(
            get: {
                if collapsedGenius.contains(agent.id) { return false }
                if expandedGenius.contains(agent.id) { return true }
                if case .agent(let id) = state.section { return id == agent.id }
                return false
            },
            set: { open in
                if open { expandedGenius.insert(agent.id); collapsedGenius.remove(agent.id) }
                else { collapsedGenius.insert(agent.id); expandedGenius.remove(agent.id) }
            }
        )
    }

    private var sortedGenius: [AgentSpec] {
        state.spaceAgents.sorted { lhs, rhs in
            let left = state.pendingApprovals(for: lhs) > 0 ? 0 : state.runningAgents.contains(lhs.id) ? 1 : 2
            let right = state.pendingApprovals(for: rhs) > 0 ? 0 : state.runningAgents.contains(rhs.id) ? 1 : 2
            if left != right { return left < right }
            let leftDate = lhs.lastRun ?? lhs.created, rightDate = rhs.lastRun ?? rhs.created
            if leftDate != rightDate { return leftDate > rightDate }
            let names = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return names == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : names == .orderedAscending
        }
    }

    private var visibleGenius: [AgentSpec] {
        let ordered = sortedGenius
        var visible = Array(ordered.prefix(visibleGeniusCount))
        if case .agent(let id) = state.section,
           !visible.contains(where: { $0.id == id }),
           let selected = ordered.first(where: { $0.id == id }) {
            visible.append(selected)
        }
        return visible
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                switch state.section {
                case .home: .home
                case .project(let id):
                    // Dentro un progetto si evidenzia la chat aperta, se è del progetto.
                    if let current = state.current, current.projectID == id, !current.messages.isEmpty { .conversation(current.id) } else { .project(id) }
                case .app(let source): .app(source)
                case .browser: .browser
                case .documents(let kind): .documents(kind)
                // Con un documento davanti si evidenzia la sua app (Pages, Numbers o Keynote).
                case .artifact: state.openArtifact.map { .documents($0.kind) }
                case .appLauncher, .file, .chats: nil
                case .activity: .activity
                case .automations: .automations
                case .connectors: .connectors
                case .settings: .settings
                case .agents: .agents
                case .agent(let id): .agent(id)
                case .schedule: .schedule
                }
            },
            set: { item in
                switch item {
                case .home: state.section = .home
                case .project(let id): if let project = state.projects.first(where: { $0.id == id }) { state.openProject(project) }
                case .app(let source): state.section = .app(source)
                case .browser: state.section = .browser
                case .documents(let kind): state.section = .documents(kind)
                case .conversation(let id):
                    guard let c = state.conversations.first(where: { $0.id == id }) else { break }
                    if let projectID = c.projectID, state.projects.contains(where: { $0.id == projectID }) {
                        state.section = .project(projectID)
                    } else if case .project = state.section {
                        state.section = .home
                    }
                    state.select(c)
                case .automations: state.section = .automations
                case .activity: state.section = .activity
                case .connectors: state.section = .connectors
                case .settings: state.section = .settings
                case .agents: state.section = .agents
                case .agent(let id): state.openAgent(id)
                case .schedule: state.section = .schedule
                case nil: break
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
        List(selection: selection) {
            HStack(spacing: 8) {
                OrbView(state: .idle, size: 20, animated: false)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Siri AI+").font(.system(size: 14, weight: .semibold))
                    Text(state.space.label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(state.space.tint)
                }
                Spacer(minLength: 4)
                SpaceSwitcher()
            }
            .padding(.vertical, 2)
            .selectionDisabled()

            if state.space == .codice {
                Section {
                    Label("Programmazione", systemImage: "chevron.left.forwardslash.chevron.right").tag(SidebarItem.home)
                    Menu {
                        ForEach(CodeTemplate.allCases) { template in
                            Button { state.newCodeTemplate = template } label: { Label(template.label, systemImage: template.symbol) }
                        }
                        Divider()
                        Button("Apri una cartella esistente…") { ProjectPicker.choose { state.addCodeProject(folder: $0) } }
                    } label: {
                        Label("Nuovo progetto", systemImage: "plus.rectangle.on.folder")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
                Section("Progetti") {
                    if state.sortedProjects.isEmpty {
                        Text("I progetti di codice appariranno qui").font(DS.Fonts.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(state.sortedProjects) { project in
                        DisclosureGroup(isExpanded: expansion(for: project)) {
                            ForEach(state.codeSessions(for: project).prefix(8)) { session in
                                Button { state.selectCodeSession(session) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: session.running ? "circle.dotted" : "text.bubble").foregroundStyle(.secondary)
                                        Text(session.title).lineLimit(1)
                                            .fontWeight(session.id == state.currentCodeSession?.id && state.openCodingProject?.id == project.id ? .semibold : .regular)
                                        Spacer()
                                        if session.running { ProgressView().controlSize(.mini) }
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button("Elimina sessione", role: .destructive) { state.deleteCodeSession(session) } }
                            }
                            Button { state.newCodeSession(in: project); state.section = .project(project.id); state.showAssistant = true } label: {
                                Label("Nuova sessione", systemImage: "plus")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill").foregroundStyle(.purple).frame(width: 18)
                                Text(project.name).lineLimit(1)
                                Spacer()
                                if state.devRun(for: project)?.running == true {
                                    Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel("In esecuzione")
                                }
                            }
                            .tag(SidebarItem.project(project.id))
                            .contextMenu {
                                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.folder]) }
                                Divider()
                                Button("Rimuovi progetto…", role: .destructive) { deletion = .project(project) }
                            }
                        }
                    }
                }
            } else {
            Section {
                Button { state.newConversation(in: nil) } label: {
                    Label("Nuova chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("Nuova chat (⌘N)")
                Button { state.showCommandPalette = true } label: {
                    Label("Cerca", systemImage: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Cerca chat, progetti, Genius e comandi (⌘K)")
                Label("Home", systemImage: "house").tag(SidebarItem.home)
            }

            // Lavoro: progetti collegati a una cartella del Mac. Personale: progetti senza cartella, per tenere separate
            // chat, memoria e file. Programmazione ha i suoi progetti di codice (sopra).
            if state.space != .codice {
            Section {
                ForEach(state.sortedProjects) { project in
                    DisclosureGroup(isExpanded: expansion(for: project)) {
                        let tasks = state.tasks(for: project)
                        ForEach(tasks.prefix(8)) { task in
                            Label {
                                Text(task.title).lineLimit(1)
                            } icon: {
                                Image(systemName: task.pinned ? "pin.fill" : task.parentID != nil ? "arrow.turn.down.right" : "bubble.left")
                                    .foregroundStyle(task.pinned ? .orange : .secondary)
                            }
                            .fontWeight(task.id == state.currentID ? .semibold : .regular)
                            .tag(SidebarItem.conversation(task.id))
                            .contextMenu {
                                Button(task.pinned ? String(localized: "Togli dai fissati") : String(localized: "Fissa in alto")) { state.togglePin(task) }
                                Button("Elimina chat…", role: .destructive) { deletion = .conversation(task) }
                            }
                        }
                        if tasks.count > 8 {
                            Button("Tutte le chat del progetto (\(tasks.count))") { state.openProject(project) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).font(DS.Fonts.caption)
                        }
                        Button {
                            state.newConversation(in: project)
                        } label: {
                            Label("Nuova chat nel progetto", systemImage: "plus.bubble")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: project.pinned ? "pin.fill" : "folder.fill")
                                .foregroundStyle(project.pinned ? Color.orange : Color.accentColor)
                                .frame(width: 18)
                            Text(project.name).lineLimit(1)
                            Spacer()
                            if !project.exists { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Cartella non trovata") }
                        }
                        .tag(SidebarItem.project(project.id))
                        .contextMenu {
                            Button(project.pinned ? String(localized: "Togli dai fissati") : String(localized: "Fissa in alto")) { state.togglePin(project) }
                            Button("Nuova chat nel progetto") { state.newConversation(in: project) }
                            if project.managed {
                                Button("Rinomina…") { state.renamingProject = project }
                            } else {
                                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.folder]) }
                            }
                            Divider()
                            Button("Rimuovi progetto…", role: .destructive) { deletion = .project(project) }
                        }
                    }
                }
                Button {
                    state.requestNewProject()
                } label: {
                    Label("Nuovo progetto…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } header: {
                Text("Progetti")
            }
            }

            Section {
                Label("Tutti i Genius", systemImage: "person.2")
                    .badge(state.spaceAgents.reduce(0) { $0 + state.pendingApprovals(for: $1) })
                    .tag(SidebarItem.agents)
                if sortedGenius.isEmpty {
                    Text("I tuoi Genius appariranno qui").font(DS.Fonts.caption).foregroundStyle(.tertiary)
                }
                ForEach(visibleGenius) { agent in
                    DisclosureGroup(isExpanded: expansion(for: agent)) {
                        Button { state.openAgent(agent.id, tab: 0) } label: { Label("Chat", systemImage: "bubble.left") }
                            .buttonStyle(.plain)
                        Button { state.openAgent(agent.id, tab: 4) } label: { Label("Programmazioni", systemImage: "calendar.badge.clock") }
                            .buttonStyle(.plain)
                        Button { state.openAgent(agent.id, tab: 1) } label: { Label("Cronologia", systemImage: "clock.arrow.circlepath") }
                            .buttonStyle(.plain)
                        Button { state.openAgent(agent.id, tab: 8) } label: { Label("Skill", systemImage: "wand.and.stars") }
                            .buttonStyle(.plain)
                    } label: {
                        HStack(spacing: 8) {
                            AgentAvatar(agent: agent, size: 18)
                            Text(agent.displayName).lineLimit(1)
                            Spacer(minLength: 4)
                            let pending = state.pendingApprovals(for: agent)
                            if pending > 0 {
                                Text("\(pending)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 1).background(Color.orange, in: Capsule())
                                    .accessibilityLabel("\(pending) approvazioni in attesa")
                            } else if state.runningAgents.contains(agent.id) {
                                ProgressView().controlSize(.mini).accessibilityLabel("Al lavoro")
                            } else if !agent.active {
                                Image(systemName: "pause.circle.fill").foregroundStyle(.secondary).accessibilityLabel("In pausa")
                            } else {
                                Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Pronto")
                            }
                        }
                        .tag(SidebarItem.agent(agent.id))
                        .contextMenu {
                            Button("Apri chat") { state.openAgent(agent.id, tab: 0) }
                            Button("Programmazioni") { state.openAgent(agent.id, tab: 4) }
                            Button("Cronologia") { state.openAgent(agent.id, tab: 1) }
                            Button("Skill") { state.openAgent(agent.id, tab: 8) }
                            Divider()
                            Button("Esegui ora") { state.runAgent(agent.id) }
                            Button(agent.active ? String(localized: "Metti in pausa") : String(localized: "Riattiva")) { state.toggleActive(agent.id) }
                            Button("Modifica…") { state.editingAgent = agent }
                            Divider()
                            Button("Elimina Genius…", role: .destructive) { deletion = .agent(agent) }
                        }
                    }
                }
                if visibleGeniusCount < sortedGenius.count {
                    Button("Mostra altri") { visibleGeniusCount += geniusBatchSize }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                if visibleGeniusCount > geniusBatchSize {
                    Button("Mostra meno") { visibleGeniusCount = geniusBatchSize }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Button { state.startGeniusCreation() } label: {
                    Label("Nuovo Genius", systemImage: "plus")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            } header: {
                Text("Genius")
            }

            Section("Chat") {
                if state.history.isEmpty {
                    Text("Le chat appariranno qui").font(DS.Fonts.caption).foregroundStyle(.tertiary)
                } else {
                    let visible = showAllHistory ? state.history : Array(state.history.prefix(historyLimit))
                    ForEach(visible) { conversation in
                        Label {
                            Text(conversation.title).lineLimit(1)
                        } icon: {
                            Image(systemName: conversation.pinned ? "pin.fill" : conversation.parentID != nil ? "arrow.turn.down.right" : "bubble.left")
                                .foregroundStyle(conversation.pinned ? .orange : .secondary)
                        }
                        .fontWeight(conversation.id == state.currentID ? .semibold : .regular)
                        .tag(SidebarItem.conversation(conversation.id))
                        .contextMenu {
                            Button(conversation.pinned ? String(localized: "Togli dai fissati") : String(localized: "Fissa in alto")) { state.togglePin(conversation) }
                            Button("Elimina chat…", role: .destructive) { deletion = .conversation(conversation) }
                        }
                    }
                    if state.history.count > historyLimit {
                        Button {
                            withAnimation { showAllHistory.toggle() }
                        } label: {
                            Label(showAllHistory ? String(localized: "Mostra meno") : String(localized: "Mostra tutte (\(state.history.count))"),
                                  systemImage: showAllHistory ? "chevron.up" : "ellipsis")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            // Le app del Mac in un gruppo che si apre quando servono.
            Section(isExpanded: $showApps) {
                HStack(spacing: 8) {
                    Tile.safari(size: 18)
                    Text("Safari")
                    Spacer()
                    if state.webEnabled {
                        Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel("Ricerca web attiva")
                    }
                }
                .tag(SidebarItem.browser)
                .contextMenu {
                    Button(state.webEnabled ? String(localized: "Disattiva la ricerca sul web") : String(localized: "Attiva la ricerca sul web")) { state.webEnabled.toggle() }
                    Button("Apri Safari") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Safari.app")) }
                }
                ForEach(SourceKind.allCases) { source in
                    HStack(spacing: 8) {
                        Tile(source, size: 18, dimmed: !state.isEnabled(source))
                        Text(source.label)
                        Spacer()
                        if source == .voiceMemos, state.recordingVoiceMemo {
                            // Registrazione in corso anche con la scheda dietro o dalla chat.
                            Circle().fill(.red).frame(width: 8, height: 8).accessibilityLabel("Sta registrando")
                        } else if state.isEnabled(source) {
                            Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel("Collegata")
                        } else if source.support == .comingSoon {
                            Text("In arrivo").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                    .tag(SidebarItem.app(source))
                    .contextMenu {
                        Button("Permessi di \(source.label)…") { state.sourcesSheet = source; state.showSourcesSheet = true }
                        Button("Apri \(source.systemAppName)") { source.openSystemApp() }
                    }
                }
                // Documenti, fogli di calcolo e presentazioni di Siri AI+.
                ForEach(ArtifactKind.allCases, id: \.self) { kind in
                    HStack(spacing: 8) {
                        Tile(kind, size: 18)
                        Text(kind.app)
                        Spacer()
                    }
                    .tag(SidebarItem.documents(kind))
                    .contextMenu {
                        Button(kind.newLabel) { state.newArtifact(kind) }
                    }
                }
            } header: {
                Text("App")
            }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.space) { _, _ in visibleGeniusCount = geniusBatchSize }
        // In fondo, sempre a portata: connettori, attività e impostazioni. Sotto l'elenco (non sopra):
        // così non coprono le ultime righe.
        Divider().opacity(0.5)
        GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    footerButton("Connettori", symbol: "puzzlepiece.extension", selected: state.section == .connectors) { state.section = .connectors }
                    footerButton("Attività e privacy", symbol: "clock.arrow.circlepath", selected: state.section == .activity) { state.section = .activity }
                    // Su GitHub c'è una versione più recente: il simbolo per scaricarla.
                    if let update = state.availableUpdate { UpdateButton(update: update) }
                    Spacer()
                    footerButton("Impostazioni (⌘,)", symbol: "gearshape", selected: false) { state.openSettings() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .confirmationDialog(deletion?.title ?? "", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
                            presenting: deletion) { item in
            Button(item.id.hasPrefix("p") ? String(localized: "Rimuovi") : String(localized: "Elimina"), role: .destructive) {
                switch item {
                case .conversation(let c): state.delete(c)
                case .project(let p): state.removeProject(p)
                case .agent(let a): state.deleteAgent(a.id)
                }
            }
        } message: { item in Text(item.message) }
    }
}

enum ProjectPicker {
    @MainActor static func choose(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Collega")
        panel.message = String(localized: "Scegli la cartella del progetto. Siri AI+ lavorerà solo al suo interno.")
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }
}
