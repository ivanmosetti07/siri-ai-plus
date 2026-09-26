import AppKit
import SiriCore
import SwiftUI

// MARK: - Schede delle app
//
// La sezione App funziona come Safari: ogni app (o Safari stesso) è una scheda, si aprono dalla chat con «App»,
// dalla barra laterale o da «Nuova scheda», e restano aperte con il punto in cui eri finché non le chiudi.
// Siri AI+ resta nella colonna destra e vede la scheda davanti.

/// Una scheda della sezione App: un'app di Apple, Safari, Pages/Numbers/Keynote (i documenti di Siri AI+),
/// un documento aperto o la pagina per sceglierne una nuova.
enum AppTab: Hashable {
    case app(SourceKind), browser, docs(ArtifactKind), document(UUID), launcher
    /// Un file (Markdown, testo, codice) da leggere e modificare.
    case file(URL)
    /// Una o più chat affiancate.
    case chats(UUID)

    var section: AppState.Section {
        switch self {
        case .app(let source): .app(source)
        case .browser: .browser
        case .docs(let kind): .documents(kind)
        case .document(let id): .artifact(id)
        case .launcher: .appLauncher
        case .file(let url): .file(url)
        case .chats(let group): .chats(group)
        }
    }

    /// Nome salvato tra un avvio e l'altro.
    var key: String {
        switch self {
        case .app(let source): String(localized: "app:\(source.rawValue)")
        case .browser: "browser"
        case .docs(let kind): String(localized: "docs:\(kind.rawValue)")
        case .document(let id): String(localized: "doc:\(id.uuidString)")
        case .launcher: "launcher"
        case .file(let url): String(localized: "file:\(url.path)")
        case .chats(let group): String(localized: "chats:\(group.uuidString)")
        }
    }

    init?(key: String) {
        switch key {
        case "browser": self = .browser
        case "launcher": self = .launcher
        default:
            if key.hasPrefix("app:"), let source = SourceKind(rawValue: String(key.dropFirst(4))) {
                self = .app(source)
            } else if key.hasPrefix("docs:"), let kind = ArtifactKind(rawValue: String(key.dropFirst(5))) {
                self = .docs(kind)
            } else if key.hasPrefix("doc:"), let id = UUID(uuidString: String(key.dropFirst(4))) {
                self = .document(id)
            } else if key.hasPrefix("file:") {
                self = .file(URL(fileURLWithPath: String(key.dropFirst(5))))
            } else if key.hasPrefix("chats:"), let group = UUID(uuidString: String(key.dropFirst(6))) {
                self = .chats(group)
            } else {
                return nil
            }
        }
    }
}

extension AppState.Section {
    /// La scheda che questa sezione mostra, se è una delle app.
    var appTab: AppTab? {
        switch self {
        case .app(let source): .app(source)
        case .browser: .browser
        case .documents(let kind): .docs(kind)
        case .artifact(let id): .document(id)
        case .appLauncher: .launcher
        case .file(let url): .file(url)
        case .chats(let group): .chats(group)
        default: nil
        }
    }
}

extension AppState {
    // MARK: Le app di ogni chat

    /// Di chi sono le app aperte: della sessione di coding nella colonna destra, altrimenti della chat aperta.
    var tabOwner: UUID? {
        if let project = openCodingProject { return currentCodeSession?.id ?? project.id }
        return currentID
    }

    /// È cambiata la chat (o la sessione di coding): cambiano le app. Se si stava guardando un'app, si passa all'ultima
    /// app della chat nuova; se non ne ha, si torna alla chat.
    func tabOwnerDidChange() {
        let owner = tabOwner
        guard owner != shownTabOwner else { return }
        shownTabOwner = owner
        screenItems = [:]
        guard showsApps else { return }
        if let tab = lastAppTab.flatMap({ appTabs.contains($0) ? $0 : nil }) ?? appTabs.first {
            section = tab.section
        } else {
            section = sectionBeforeApps.appTab == nil ? sectionBeforeApps : .home
        }
    }

    /// Il progetto di codice resta nella colonna destra finché si guardano le sue app; si lascia andando altrove.
    func updateCodeContext() {
        if case .project(let id) = section {
            let wanted: UUID? = projects.first { $0.id == id }?.space == Space.codice.rawValue ? id : nil
            if codeContextProjectID != wanted { codeContextProjectID = wanted }
        } else if section.appTab == nil, codeContextProjectID != nil {
            codeContextProjectID = nil
        }
    }

    static func savedTabsByOwner() -> [UUID: [AppTab]] {
        guard !CommandLine.arguments.contains("--ephemeral"),
              let saved = UserDefaults.standard.dictionary(forKey: "tabsByChat") as? [String: [String]] else { return [:] }
        var result: [UUID: [AppTab]] = [:]
        for (key, tabs) in saved {
            guard let owner = UUID(uuidString: key) else { continue }
            result[owner] = tabs.compactMap(AppTab.init(key:))
        }
        return result
    }

    /// Le chat vuote non si salvano: le schede della chat vuota aperta passano alla chat nuova del prossimo avvio.
    func saveTabsByOwner() {
        guard persists else { return }
        var saved: [String: [String]] = [:]
        var fresh: [String]?
        for (owner, tabs) in tabsByOwner {
            let keys = tabs.filter { $0 != .launcher }.map(\.key)
            guard !keys.isEmpty else { continue }
            if let chat = conversations.first(where: { $0.id == owner }), chat.messages.isEmpty {
                if owner == currentID { fresh = keys }
                continue
            }
            saved[owner.uuidString] = keys
        }
        UserDefaults.standard.set(saved, forKey: "tabsByChat")
        UserDefaults.standard.set(fresh, forKey: "tabsOfFreshChat")
    }

    /// All'avvio: solo le schede di chat, sessioni e progetti che esistono ancora (niente documenti eliminati né gruppi
    /// di chat spariti). Le schede della chat vuota dell'ultima volta, e quelle uniche delle versioni precedenti,
    /// vanno alla chat nuova.
    func restoreTabs(freshChat: UUID) {
        let defaults = UserDefaults.standard
        var restored = tabsByOwner
        if persists {
            let fresh = defaults.stringArray(forKey: "tabsOfFreshChat") ?? defaults.stringArray(forKey: "appTabs") ?? []
            defaults.removeObject(forKey: "appTabs")
            if !fresh.isEmpty { restored[freshChat] = fresh.compactMap(AppTab.init(key:)) }
        }
        let alive = Set(conversations.map(\.id)).union(codeSessions.map(\.id)).union(projects.map(\.id))
        for (owner, tabs) in restored {
            guard alive.contains(owner) else { restored[owner] = nil; continue }
            let kept = tabs.filter { tab in
                switch tab {
                case .document(let id): artifact(id) != nil
                case .chats(let group): chatTabs[group] != nil
                case .launcher: false
                default: true
                }
            }
            restored[owner] = kept.isEmpty ? nil : kept
        }
        tabsByOwner = restored
        shownTabOwner = tabOwner
        browserPages = browserPages.filter { UUID(uuidString: $0.key).map(alive.contains) ?? false }
    }

    /// Una chat o una sessione eliminata porta via le sue app.
    func forgetTabs(of owner: UUID) {
        tabsByOwner[owner] = nil
        lastTabByOwner[owner] = nil
        browsers[owner] = nil
        browserUse[owner] = nil
        browserPages[owner.uuidString] = nil
    }

    /// Toglie una scheda da tutte le chat (un documento eliminato): quella aperta si chiude come al solito.
    func closeTabEverywhere(_ tab: AppTab) {
        if appTabs.contains(tab) { closeTab(tab) }
        for (owner, tabs) in tabsByOwner where tabs.contains(tab) {
            let kept = tabs.filter { $0 != tab }
            tabsByOwner[owner] = kept.isEmpty ? nil : kept
        }
    }

    // MARK: Safari di ogni chat

    /// Chiave delle app quando non c'è una chat (non succede quasi mai: all'avvio ce n'è sempre una).
    private static let noOwner = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Il Safari di una chat: creato la prima volta che serve; la pagina salvata si carica quando la scheda viene davanti.
    func browser(for owner: UUID?) -> BrowserModel {
        let key = owner ?? Self.noOwner
        browserUse[key] = .now
        if let model = browsers[key] { return model }
        let model = BrowserModel()
        model.pendingURL = browserPages[key.uuidString].flatMap(URL.init(string:))
        model.onNavigate = { [weak self] url in self?.rememberPage(url, for: key) }
        browsers[key] = model
        // Al massimo sei pagine vive: le altre si ricaricano quando la loro chat torna davanti.
        if browsers.count > 6, let oldest = browserUse.filter({ $0.key != key && browsers[$0.key] != nil }).min(by: { $0.value < $1.value })?.key {
            browsers[oldest] = nil
        }
        return model
    }

    private func rememberPage(_ url: URL?, for owner: UUID) {
        guard let url, ["http", "https", "file"].contains(url.scheme ?? "") else { return }
        browserPages[owner.uuidString] = url.absoluteString
    }

    /// La sezione App è davanti.
    var showsApps: Bool { section.appTab != nil }

    /// Tiene le schede allineate alla sezione aperta (chiamata a ogni cambio di sezione).
    func updateAppTabs(from old: Section) {
        let tab = section.appTab
        // «Nuova scheda» diventa l'app scelta; se esci senza scegliere, si chiude.
        if old == .appLauncher, section != .appLauncher, let index = appTabs.firstIndex(of: .launcher) {
            if let tab, !appTabs.contains(tab) { appTabs[index] = tab } else { appTabs.remove(at: index) }
        }
        guard let tab else { return }
        if !appTabs.contains(tab) { appTabs.append(tab) }
        lastAppTab = tab
        // Il documento davanti è quello su cui lavora Siri AI+ («aggiungi una sezione», «elimina la slide 3»).
        if case .document(let id) = tab, openArtifact?.id != id { openArtifact = artifact(id) }
        if old.appTab == nil { sectionBeforeApps = old }
    }

    /// Porta davanti una scheda (se l'app non è ancora aperta, apre una scheda nuova).
    func selectTab(_ tab: AppTab) {
        // La scheda lasciata non tiene la tastiera: quello che scrivi va in quella davanti.
        if showsApps, section.appTab != tab { NSApp.keyWindow?.makeFirstResponder(nil) }
        openTab(tab)
    }

    func openTab(_ tab: AppTab) {
        section = tab.section
    }

    func closeTab(_ tab: AppTab) {
        guard let index = appTabs.firstIndex(of: tab) else { return }
        let wasFront = section.appTab == tab
        if case .document(let id) = tab, openArtifact?.id == id { openArtifact = nil }
        appTabs.remove(at: index)
        screenItems[tab] = nil
        if lastAppTab == tab { lastAppTab = nil }
        guard wasFront else { return }
        if appTabs.isEmpty { leaveApps() } else { section = appTabs[min(index, appTabs.count - 1)].section }
    }

    func closeOtherTabs(than tab: AppTab) {
        appTabs = [tab]
        screenItems = screenItems.filter { $0.key == tab }
        section = tab.section
    }

    /// Scheda successiva (1) o precedente (-1), come ⌃⇥ in Safari.
    func cycleTab(_ step: Int) {
        guard let current = section.appTab, let index = appTabs.firstIndex(of: current), appTabs.count > 1 else { return }
        selectTab(appTabs[(index + step + appTabs.count) % appTabs.count])
    }

    /// Il pulsante «App»: apre le schede (dall'ultima guardata) o torna da dove eri.
    func toggleApps() {
        if showsApps { leaveApps(); return }
        if let lastAppTab, appTabs.contains(lastAppTab) {
            openTab(lastAppTab)
        } else {
            openTab(appTabs.first ?? .launcher)
        }
    }

    private func leaveApps() {
        section = sectionBeforeApps.appTab == nil ? sectionBeforeApps : .home
    }

    /// La chat, il progetto o il codice da cui si sono aperte le app (per il pulsante «indietro» della barra delle schede).
    var appsBackTarget: (title: String, symbol: String)? {
        switch sectionBeforeApps {
        case .home: return (current?.messages.isEmpty == false ? current?.title ?? String(localized: "Chat") : String(localized: "Chat"), "bubble.left.fill")
        case .project(let id):
            guard let project = projects.first(where: { $0.id == id }) else { return nil }
            return (project.name, project.space == Space.codice.rawValue ? "chevron.left.forwardslash.chevron.right" : "folder.fill")
        case .agent(let id): return (agent(id)?.displayName ?? String(localized: "Genius"), "person.crop.circle")
        case .agents, .automations: return (String(localized: "Genius"), "person.2.fill")
        case .schedule: return (String(localized: "Programmazioni"), "calendar.badge.clock")
        case .activity: return (String(localized: "Attività"), "list.bullet.rectangle")
        case .connectors: return (String(localized: "Connettori"), "puzzlepiece.extension")
        case .settings: return (String(localized: "Impostazioni"), "gearshape")
        default: return nil
        }
    }

    var appsToggleHelp: String {
        guard showsApps else { return String(localized: "App in schede (⌥⌘A)") }
        return sectionBeforeApps == .home ? String(localized: "Torna alla chat (⌥⌘A)") : String(localized: "Chiudi le app (⌥⌘A)")
    }

    func title(of tab: AppTab) -> String {
        switch tab {
        case .app(let source): source.label
        case .browser: browser.title.isEmpty ? String(localized: "Safari") : browser.title
        case .docs(let kind): kind.app
        case .document(let id): artifact(id).map { $0.title.isEmpty ? String(localized: "Senza titolo") : $0.title } ?? String(localized: "Documento")
        case .launcher: String(localized: "Nuova scheda")
        case .file(let url): url.lastPathComponent
        case .chats(let group):
            chats(in: group).map { $0.messages.isEmpty ? String(localized: "Nuova chat") : $0.title }.prefix(2).joined(separator: " · ").nonEmpty ?? String(localized: "Chat")
        }
    }
}

private struct AppTabActiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// Falso nelle schede nascoste: niente aggiornamenti periodici finché non tornano davanti.
    var appTabActive: Bool {
        get { self[AppTabActiveKey.self] }
        set { self[AppTabActiveKey.self] = newValue }
    }
}

// MARK: - Vista

/// La sezione App: barra delle schede e le app aperte. Quelle dietro restano vive (selezione, bozze, pagina,
/// registrazione in corso) ma non ricevono clic, scorciatoie né aggiornamenti.
/// Un'app si carica la prima volta che la sua scheda viene davanti (le schede salvate non lavorano all'avvio).
struct AppTabsView: View {
    @Environment(AppState.self) private var state
    @State private var loaded: Set<AppTab> = []

    var body: some View {
        VStack(spacing: 0) {
            AppTabBar()
            ZStack {
                ForEach(state.appTabs, id: \.self) { tab in
                    let front = state.section.appTab == tab
                    if front || loaded.contains(tab) {
                        AppTabContent(tab: tab)
                            .environment(\.appTabActive, front)
                            .opacity(front ? 1 : 0)
                            .allowsHitTesting(front)
                            .disabled(!front)
                            .accessibilityHidden(!front)
                            .zIndex(front ? 1 : 0)
                    }
                }
            }
            // Un'app più larga dello spazio non sposta la barra delle schede né finisce sotto le colonne accanto.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
        }
        .onChange(of: state.section, initial: true) { _, section in
            if let tab = section.appTab { loaded.insert(tab) }
        }
        .onChange(of: state.appTabs) { _, tabs in loaded.formIntersection(tabs) }
    }
}

private struct AppTabContent: View {
    let tab: AppTab

    var body: some View {
        Group {
            switch tab {
            case .app(let source): AppContainer(source: source)
            case .browser: BrowserView()
            case .docs(let kind): DocumentsAppView(kind: kind)
            case .document(let id): DocumentTab(id: id)
            case .launcher: AppLauncher()
            case .file(let url): FileTab(url: url)
            case .chats(let group): ChatsTab(group: group)
            }
        }
        .onAppear { Agent.log("SCHEDA: \(tab.key) caricata") }
    }
}

/// Icona di una scheda: quella vera dell'app.
struct AppTabIcon: View {
    @Environment(AppState.self) private var state
    let tab: AppTab
    var size: CGFloat = 16

    var body: some View {
        switch tab {
        case .app(let source): Tile(source, size: size, dimmed: source.support == .comingSoon)
        case .browser: Tile.safari(size: size)
        case .docs(let kind): Tile(kind, size: size)
        case .document(let id): Tile(state.artifact(id)?.kind ?? .pages, size: size)
        case .launcher:
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: size * 0.72, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        case .file(let url): FileTabIcon(url: url, size: size)
        case .chats: ChatTabIcon(size: size)
        }
    }
}

/// Barra delle schede, in vetro come le pillole di Salute: la scheda davanti è bianca.
struct AppTabBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            // Da dove si è arrivati (la chat, il progetto, il codice): un clic e si torna lì, le app restano aperte.
            if let back = state.appsBackTarget {
                Button { withAnimation(.smooth(duration: 0.4)) { state.toggleApps() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Image(systemName: back.symbol).font(.system(size: 11, weight: .semibold))
                        Text(back.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(maxWidth: 190)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.18)).interactive(), in: .capsule)
                .iconHelp(String(localized: "Torna a \(back.title) (⌥⌘A): le app restano aperte in questa chat"))
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 6) {
                            ForEach(state.appTabs, id: \.self) { tab in
                                AppTabButton(tab: tab).id(tab)
                            }
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 2)
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: state.section) { _, section in
                    guard let tab = section.appTab else { return }
                    withAnimation(DS.Motion.standard) { proxy.scrollTo(tab) }
                }
            }
            Button { state.selectTab(.launcher) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .iconHelp(String(localized: "Nuova scheda (⌘T)"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

private struct AppTabButton: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var scheme
    let tab: AppTab
    @State private var hovering = false

    private var front: Bool { state.section.appTab == tab }
    private var showsClose: Bool { hovering || front }

    var body: some View {
        HStack(spacing: 7) {
            AppTabIcon(tab: tab)
                .overlay(alignment: .topTrailing) {
                    if tab == .app(.voiceMemos), state.recordingVoiceMemo {
                        Circle().fill(.red).frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                            .offset(x: 3, y: -3)
                            .accessibilityLabel("Sta registrando")
                    }
                }
            Text(state.title(of: tab))
                .font(.system(size: 12.5, weight: front ? .semibold : .medium))
                .lineLimit(1)
            Button { withAnimation(DS.Motion.standard) { state.closeTab(tab) } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(hovering ? 0.08 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(showsClose ? 0.75 : 0)
            .allowsHitTesting(showsClose)
            .iconHelp(String(localized: "Chiudi la scheda"))
        }
        .foregroundStyle(front ? Color.black.opacity(0.85) : Color.primary)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: 200)
        .background {
            if front {
                Capsule().fill(.white.opacity(0.95))
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 6, y: 2)
            }
        }
        .contentShape(Capsule())
        .onTapGesture { state.selectTab(tab) }
        .onHover { hovering = $0 }
        .glassEffect(.regular.interactive(), in: .capsule)
        .contextMenu {
            Button("Chiudi la scheda") { state.closeTab(tab) }
            Button("Chiudi le altre schede") { state.closeOtherTabs(than: tab) }
                .disabled(state.appTabs.count < 2)
            switch tab {
            case .app(let source):
                Divider()
                Button("Apri \(source.systemAppName)") { source.openSystemApp() }
            case .browser:
                Divider()
                Button("Apri in Safari") { state.browser.openInSafari() }.disabled(state.browser.url == nil)
            case .document(let id):
                if let artifact = state.artifact(id) {
                    Divider()
                    Button("Mostra la chat del documento") { state.showConversation(of: artifact) }
                }
            case .file(let url):
                Divider()
                Button("Apri con l'app predefinita") { NSWorkspace.shared.open(url) }
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            case .chats(let group):
                Divider()
                Button("Affianca un'altra chat") { state.addChat(to: group) }.disabled(state.chats(in: group).count >= 4)
            case .docs, .launcher:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.title(of: tab))
        .accessibilityAddTraits(front ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { state.selectTab(tab) }
    }
}

// MARK: - Nuova scheda

/// Pagina «Nuova scheda»: tutte le app come nel Launchpad; quelle già aperte hanno il puntino, come nel Dock.
struct AppLauncher: View {
    @Environment(AppState.self) private var state

    private var entries: [AppTab] { [.browser] + SourceKind.allCases.map(AppTab.app) + ArtifactKind.allCases.map(AppTab.docs) }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                VStack(spacing: 6) {
                    Text("Apri un'app").font(.system(size: 26, weight: .bold))
                    Text("Ogni app si apre in una scheda: passi dall'una all'altra senza perdere il punto. Puoi aprire anche file e altre chat, una accanto all'altra. Siri AI+ resta qui a destra e vede la scheda davanti.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 470)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 124), spacing: 12)], spacing: 16) {
                    ForEach(entries, id: \.self) { tab in cell(tab) }
                    // Oltre alle app: una chat accanto a quella del pannello e i file da leggere o modificare.
                    action(String(localized: "Chat accanto"), note: "affiancate", help: String(localized: "Una o più chat accanto al pannello"), icon: AnyView(ChatTabIcon(size: 60))) {
                        state.newChatTab()
                    }
                    action(String(localized: "Apri file…"), note: ".md, testo, codice", help: String(localized: "Leggi e modifica un file (⌘O)"),
                           icon: AnyView(FileTabIcon(url: URL(fileURLWithPath: "/tmp/nota.md"), size: 60))) {
                        state.chooseFileToOpen()
                    }
                }
                .frame(maxWidth: 640)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .clipShape(.rect(cornerRadius: 26))
        .glassCard(radius: 26)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private func cell(_ tab: AppTab) -> some View {
        let open = state.appTabs.contains(tab)
        return Button { state.selectTab(tab) } label: {
            VStack(spacing: 7) {
                AppTabIcon(tab: tab, size: 60)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                Text(label(tab)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(note(tab))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .overlay {
                        // Già aperta: il puntino sotto l'icona, come nel Dock.
                        if open { Circle().fill(Color.primary.opacity(0.6)).frame(width: 5, height: 5) }
                    }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(LauncherCellStyle())
        .help(open ? String(localized: "Già aperta: passa alla sua scheda") : String(localized: "Apri in una scheda"))
        .accessibilityLabel("\(label(tab))\(open ? String(localized: ", già aperta") : "")")
    }

    private func action(_ title: String, note: String, help: String, icon: AnyView, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 7) {
                icon.shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(note).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(LauncherCellStyle())
        .help(help)
    }

    private func label(_ tab: AppTab) -> String { state.title(of: tab) }

    /// Stato sotto il nome (il puntino prende il posto del testo quando l'app è aperta).
    private func note(_ tab: AppTab) -> String {
        guard !state.appTabs.contains(tab), case .app(let source) = tab else { return " " }
        if source.support == .comingSoon { return String(localized: "In arrivo") }
        return state.isEnabled(source) ? " " : String(localized: "Da collegare")
    }
}

/// Riquadro che si illumina al passaggio del mouse e si abbassa al clic.
private struct LauncherCellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LauncherCell(configuration: configuration)
    }

    private struct LauncherCell: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.06 : 0),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(DS.Motion.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}
