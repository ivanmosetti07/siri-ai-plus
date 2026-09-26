import AppKit
import SiriCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File e chat nelle schede
//
// Accanto alle app, due tipi di scheda: un file (Markdown da leggere comodamente, testo o codice da modificare) e una o più
// chat affiancate, ognuna con il suo modello, mentre Siri AI+ resta nel pannello a destra.

extension AppState {
    // MARK: File

    /// Apre un file in una scheda (se è già aperto, passa alla sua scheda).
    func openFile(_ url: URL) {
        openTab(.file(url.standardizedFileURL))
    }

    /// «Apri file…» (⌘O): Markdown, testo e codice si aprono in una scheda; gli altri con l'app predefinita.
    func chooseFileToOpen() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Scegli i file da aprire in Siri AI+"
        panel.directoryURL = currentProject?.folder
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openAny(url) }
    }

    /// Testo e Markdown in una scheda, il resto con l'app del Mac.
    func openAny(_ url: URL) {
        if EditableFiles.extensions.contains(url.pathExtension.lowercased()) || url.pathExtension.isEmpty {
            openFile(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Il progetto collegato che contiene un file (nil se è fuori dai progetti).
    func project(containing url: URL) -> ProjectModel? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return projects.filter { path.hasPrefix($0.folder.standardizedFileURL.resolvingSymlinksInPath().path + "/") }
            .max { $0.folder.path.count < $1.folder.path.count }
    }

    /// Un collegamento cliccato in un file: `[[Nome]]` come in Obsidian (cercato per nome in tutta la cartella del progetto)
    /// o un percorso relativo al file.
    func openLinkedFile(_ target: String, from url: URL) {
        let root = project(containing: url)?.folder ?? url.deletingLastPathComponent()
        var name = target.removingPercentEncoding ?? target
        if let hash = name.firstIndex(of: "#") { name = String(name[..<hash]) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        for base in [url.deletingLastPathComponent(), root] {
            for candidate in [name, name + ".md"] {
                let file = base.appending(path: candidate).standardizedFileURL
                var isFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue { openFile(file); return }
            }
        }
        Task {
            if let path = await ProjectGuide.shared(for: root).file(named: name) {
                openFile(root.appending(path: path))
            } else {
                showToast("Non trovo «\(name)» nella cartella", symbol: "questionmark.circle")
            }
        }
    }

    // MARK: Chat affiancate

    static func savedChatTabs() -> [UUID: [UUID]] {
        guard !CommandLine.arguments.contains("--ephemeral"),
              let saved = UserDefaults.standard.dictionary(forKey: "chatTabs") as? [String: [String]] else { return [:] }
        var result: [UUID: [UUID]] = [:]
        for (key, ids) in saved {
            guard let group = UUID(uuidString: key) else { continue }
            result[group] = ids.compactMap(UUID.init(uuidString:))
        }
        return result
    }

    func saveChatTabs() {
        guard persists else { return }
        var saved: [String: [String]] = [:]
        for (group, ids) in chatTabs { saved[group.uuidString] = ids.map(\.uuidString) }
        UserDefaults.standard.set(saved, forKey: "chatTabs")
    }

    /// Una chat nuova per una colonna: nello spazio e nel progetto della chat del pannello.
    func sideConversation() -> Conversation {
        let conversation = Conversation(projectID: current?.projectID)
        conversation.space = space.rawValue
        conversations.insert(conversation, at: 0)
        return conversation
    }

    /// Nuova scheda con una chat (nuova o una esistente) accanto a quella del pannello.
    func newChatTab(with conversation: Conversation? = nil) {
        let chat = conversation ?? sideConversation()
        let group = UUID()
        chatTabs[group] = [chat.id]
        openTab(.chats(group))
    }

    /// Un'altra chat affiancata nella stessa scheda (al massimo quattro).
    func addChat(to group: UUID, conversation: Conversation? = nil) {
        guard (chatTabs[group]?.count ?? 0) < 4 else { return }
        let chat = conversation ?? sideConversation()
        if chatTabs[group]?.contains(chat.id) == true { return }
        chatTabs[group, default: []].append(chat.id)
    }

    /// Toglie una chat dalla scheda (la conversazione resta nella cronologia); l'ultima chiude la scheda.
    func removeChat(_ id: UUID, from group: UUID) {
        chatTabs[group]?.removeAll { $0 == id }
        if chatTabs[group]?.isEmpty ?? true {
            closeTab(.chats(group))
            chatTabs[group] = nil
        }
    }

    func chats(in group: UUID) -> [Conversation] {
        (chatTabs[group] ?? []).compactMap { id in conversations.first { $0.id == id } }
    }

    /// Porta una chat affiancata nel pannello di destra.
    func moveToPanel(_ conversation: Conversation, from group: UUID) {
        removeChat(conversation.id, from: group)
        if let projectID = conversation.projectID, !showsApps { section = .project(projectID) }
        select(conversation)
    }
}

// MARK: - Scheda di un file

/// Un file in una scheda: il Markdown si legge formattato (i collegamenti fra file si aprono in altre schede),
/// e con «Modifica» o «Affiancata» si cambia, con il salvataggio automatico.
struct FileTab: View {
    @Environment(AppState.self) private var state
    let url: URL

    var body: some View {
        let project = state.project(containing: url)
        let root = project?.folder ?? url.deletingLastPathComponent()
        // Percorsi risolti da entrambe le parti («/var» e «/private/var» sono la stessa cartella).
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let relative = filePath.hasPrefix(rootPath + "/") ? String(filePath.dropFirst(rootPath.count + 1)) : url.lastPathComponent
        let host = project ?? ProjectModel(name: url.deletingLastPathComponent().lastPathComponent, folder: root, allowWrite: true)
        Group {
            if FileManager.default.fileExists(atPath: url.path) {
                FileEditorView(project: host, path: relative.isEmpty ? url.lastPathComponent : relative, startsInReading: true,
                               onOpenLink: { target in state.openLinkedFile(target, from: url) })
                    .id(url)
            } else {
                ContentUnavailableView("File non trovato", systemImage: "doc.questionmark",
                                       description: Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
            }
        }
        .clipShape(.rect(cornerRadius: 22))
        .glassCard(radius: 22)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .task(id: url) { await publish() }
    }

    /// Siri AI+ vede il file davanti («riassumi questo file», «correggi il secondo paragrafo»).
    private func publish() async {
        let path = url.path
        let text = await Task.detached(priority: .utility) { (try? FileSearch.read(path, maxChars: 6000)) ?? "" }.value
        let item = ScreenItem(app: "File", kind: .file, title: url.lastPathComponent,
                              details: "in \(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))",
                              text: text, reference: path)
        state.publish(item, for: .file(url))
    }
}

/// Icona di un file: quella del Finder.
struct FileTabIcon: View {
    let url: URL
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - Chat affiancate

/// Icona delle schede di chat: due fumetti nei colori di Siri.
struct ChatTabIcon: View {
    var size: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.35, blue: 0.98), Color(red: 0.86, green: 0.33, blue: 0.86)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

/// Una scheda con una o più chat una accanto all'altra.
struct ChatsTab: View {
    @Environment(AppState.self) private var state
    let group: UUID

    var body: some View {
        let chats = state.chats(in: group)
        HStack(spacing: 10) {
            ForEach(chats) { conversation in
                ChatColumn(conversation: conversation, group: group, closable: true)
                    .frame(minWidth: 260, maxWidth: .infinity)
            }
            if chats.count < 4 { addColumn }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .environment(\.compactLayout, true)
        .task(id: chats.map(\.id)) { publish(chats) }
        .onChange(of: chats.map { $0.messages.count }) { publish(chats) }
    }

    private var addColumn: some View {
        Menu {
            Button("Nuova chat") { state.addChat(to: group) }
            let recent = state.conversations.filter { chat in
                !chat.messages.isEmpty && chat.agentID == nil && !(state.chatTabs[group] ?? []).contains(chat.id)
            }.prefix(12)
            if !recent.isEmpty {
                Section("Chat recenti") {
                    ForEach(Array(recent)) { chat in
                        Button(chat.title) { state.addChat(to: group, conversation: chat) }
                    }
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.bubble").font(.system(size: 20, weight: .medium))
                Text("Affianca\nun'altra chat").font(DS.Fonts.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .frame(width: 92)
            .frame(maxHeight: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .help("Aggiungi una chat accanto (nuova o dalla cronologia)")
    }

    /// Siri AI+ nel pannello vede le chat affiancate («confronta con la chat accanto», «riassumi la chat a sinistra»).
    private func publish(_ chats: [Conversation]) {
        let text = chats.map { chat in
            "Chat «\(chat.title)»:\n" + AppState.turns(of: chat).suffix(6).map { "\($0.role == .user ? "Ivan" : "Siri AI+"): \($0.text.prefix(300))" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        state.publish(ScreenItem(app: "Chat", kind: .overview, title: chats.count == 1 ? "chat «\(chats[0].title)»" : "\(chats.count) chat affiancate",
                                 text: text, nouns: ["chat", "conversazione", "conversazioni"]), for: .chats(group))
    }
}

/// Una colonna di chat: la conversazione, il suo modello e il campo per scrivere.
struct ChatColumn: View {
    @Environment(AppState.self) private var state
    let conversation: Conversation
    let group: UUID
    var closable = true
    @State private var input = ""
    @FocusState private var focused: Bool

    private var busy: Bool { state.respondingID == conversation.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if conversation.parentID != nil { ChildChatBanner(conversation: conversation) }
            if conversation.messages.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    ChatTabIcon(size: 40)
                    Text("Nuova chat").font(DS.Fonts.section)
                    Text("Lavora qui su un altro argomento: il pannello a destra resta com'è.")
                        .font(DS.Fonts.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 240)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ConversationThread(conversation: conversation)
            }
            composer
        }
        .clipShape(.rect(cornerRadius: 22))
        .glassCard(radius: 22)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ChatTabIcon(size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.messages.isEmpty ? "Nuova chat" : conversation.title).font(DS.Fonts.bodyStrong).lineLimit(1)
                if let project = conversation.projectID.flatMap({ id in state.projects.first { $0.id == id } }) {
                    Label(project.name, systemImage: "folder.fill").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Porta nel pannello a destra") { state.moveToPanel(conversation, from: group) }
                Button("Affianca una chat nuova") { state.addChat(to: group) }
                if closable {
                    Divider()
                    Button("Togli dalla scheda") { state.removeChat(conversation.id, from: group) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            if closable {
                Button { state.removeChat(conversation.id, from: group) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .iconHelp("Togli la chat dalla scheda (resta nella cronologia)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if busy {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(state.orbLabel).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            TextField("Scrivi in questa chat…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
            HStack(spacing: 6) {
                ModelPicker(current: conversation.model ?? state.defaultSelection(for: state.space(of: conversation)), compact: true) { choice in
                    conversation.model = state.resolved(choice)
                    state.saveConversations()
                }
                Spacer()
                if busy {
                    Button { state.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(Color.primary.opacity(0.75), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .iconHelp("Interrompi")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(canSend ? Color.accentColor : Color.secondary.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .iconHelp(state.isResponding ? "Aspetta la risposta in corso" : "Invia (↩)")
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(10)
    }

    private var canSend: Bool {
        !state.isResponding && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.availabilityProblem == nil
    }

    private func send() {
        guard canSend else { return }
        let text = input
        input = ""
        state.send(text, in: conversation)
    }
}

extension String {
    /// nil per una stringa vuota: comodo con `??`.
    var nonEmpty: String? { isEmpty ? nil : self }
}
