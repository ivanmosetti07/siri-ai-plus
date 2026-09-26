import AppKit
import SiriCore
import SwiftUI

/// Progetto al centro: task, file della cartella, istruzioni AGENTS.md, memoria.
struct ProjectView: View {
    @Environment(AppState.self) private var state
    let project: ProjectModel
    /// Diagnostica (solo prove): `--project-tab 5` apre il progetto su una scheda.
    @State private var tab = AppTesting.value(after: "--project-tab").flatMap(Int.init) ?? 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 14)
                .padding(.bottom, 16)
            if !project.exists {
                GlassEmptyState(symbol: "exclamationmark.triangle.fill", title: "Cartella non trovata",
                                message: "«\(project.folder.path)» non esiste più. Ricollegala o rimuovi il progetto: le chat restano finché non lo rimuovi.",
                                colors: Hue.orange, actionTitle: "Rimuovi progetto") { state.removeProject(project) }
                    .padding(.horizontal, 32)
                Spacer()
            } else {
                Group {
                    switch tab {
                    case 0: ProjectTasks(project: project)
                    // Come l'app File, ma solo dentro la cartella del progetto.
                    case 1:
                        FilesAppView(project: project)
                            .clipShape(.rect(cornerRadius: 24))
                            .glassCard(radius: 24)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                    case 2: AgentsEditor(project: project)
                    case 3: ProjectMemoryView(project: project)
                    case 5: ProjectGraphView(project: project)
                    default: ProjectSettingsView(project: project)
                    }
                }
                .id(tab)
                .transition(.blurReplace)
            }
        }
        .onChange(of: state.projectFileToOpen, initial: true) { _, path in
            if path != nil { tab = 1 }
        }
    }

    /// Intestazione grande con il percorso della cartella, poi le pillole delle sezioni.
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: "Progetto", title: project.name) {
                Button {
                    state.togglePin(project)
                } label: {
                    Image(systemName: project.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.glass)
                .iconHelp(project.pinned ? "Togli dai fissati" : "Fissa in alto")
                Button {
                    state.newConversation(in: project)
                } label: {
                    Label("Nuova chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(.glassProminent)
                .fixedSize()
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([project.folder])
            } label: {
                Label(project.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .help("Mostra nel Finder")
            .padding(.top, -6)
            GlassPills(items: [
                GlassPill(id: "0", title: "Chat", symbol: "bubble.left.and.bubble.right.fill", colors: Hue.blue),
                GlassPill(id: "1", title: "File", symbol: "doc.on.doc.fill", colors: Hue.teal),
                GlassPill(id: "5", title: "Grafo", symbol: "brain", colors: Hue.purple),
                GlassPill(id: "2", title: "Istruzioni", symbol: "text.book.closed.fill", colors: Hue.orange),
                GlassPill(id: "3", title: "Memoria", symbol: "brain.head.profile", colors: Hue.purple),
                GlassPill(id: "4", title: "Impostazioni", symbol: "slider.horizontal.3", colors: Hue.gray),
            ], selection: Binding(get: { String(tab) }, set: { tab = Int($0) ?? 0 }))
        }
    }
}

struct ProjectTasks: View {
    @Environment(AppState.self) private var state
    let project: ProjectModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let tasks = state.tasks(for: project)
                if tasks.allSatisfy({ $0.messages.isEmpty }) {
                    GlassEmptyState(symbol: "bubble.left.and.bubble.right.fill", title: "Le chat del progetto",
                                    message: "Ogni chat è dedicata a questo progetto: Siri AI+ usa AGENTS.md, la sua memoria e i suoi file. Scrivi a destra per iniziare.",
                                    colors: Hue.blue, actionTitle: "Nuova chat") { state.newConversation(in: project) }
                }
                ForEach(tasks) { task in
                    Button { state.select(task) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: task.pinned ? "pin.fill" : "text.bubble")
                                .foregroundStyle(task.pinned ? .orange : .secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).font(DS.Fonts.bodyStrong).lineLimit(1)
                                Text("\(task.messages.filter { if case .user = $0.content { true } else { false } }.count) richieste · \(task.created.formatted(.relative(presentation: .named).locale(Dates.locale)))")
                                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if task.id == state.currentID { Text("Aperta").font(DS.Fonts.captionStrong).foregroundStyle(Color.accentColor) }
                        }
                        .padding(14)
                        .glassCard(radius: 20)
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(task.id == state.currentID ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(task.pinned ? "Togli dai fissati" : "Fissa in alto") { state.togglePin(task) }
                        Button("Elimina task", role: .destructive) { state.delete(task) }
                    }
                }
                let artifacts = state.allArtifacts.filter { $0.projectID == project.id }
                if !artifacts.isEmpty {
                    GroupTitle(text: "Documenti del progetto").padding(.top, 8)
                    ForEach(artifacts) { ArtifactChip(artifact: $0) }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// I file di un progetto di codice, come in un editor: l'albero delle cartelle (si chiudono e si aprono con un clic)
/// e il file aperto accanto, con l'anteprima delle pagine web.
struct CodeFilesView: View {
    @Environment(AppState.self) private var state
    let project: ProjectModel
    @State private var entries = [ProjectFiles.Entry]()
    @State private var selected = String?.none
    @State private var preview = ""
    @State private var filter = ""
    /// Cartelle chiuse nell'albero.
    @State private var collapsed = Set<String>()

    private var visible: [ProjectFiles.Entry] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.isEmpty else { return entries.filter { $0.path.lowercased().contains(query) } }
        return entries.filter { entry in
            // Nascosti i file dentro una cartella chiusa.
            var parent = (entry.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if collapsed.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    var body: some View {
        HSplitLayout {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                    TextField("Filtra i file", text: $filter).textFieldStyle(.plain)
                    Menu {
                        Button("Nuova nota Markdown") { create("Nuova nota", ext: "md", content: "# Nuova nota\n\n") }
                        Button("Nuova pagina HTML") {
                            create("pagina", ext: "html", content: "<!doctype html>\n<html lang=\"it\">\n<head>\n    <meta charset=\"utf-8\">\n    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n    <title>Pagina</title>\n</head>\n<body>\n    <h1>Ciao!</h1>\n</body>\n</html>\n")
                        }
                    } label: { Image(systemName: "plus") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(!project.allowWrite)
                    .iconHelp("Nuovo file")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                List(selection: Binding(get: { selected }, set: { select($0) })) {
                    ForEach(visible) { entry in
                        row(entry)
                            .tag(entry.path)
                            .contextMenu {
                                Button("Mostra nel Finder") {
                                    if let url = try? project.files.resolve(entry.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                                if ["html", "htm"].contains((entry.path as NSString).pathExtension.lowercased()), let url = try? project.files.resolve(entry.path) {
                                    Button("Anteprima (Safari della sessione)") { state.openInBrowser(url) }
                                }
                                if !entry.isDirectory {
                                    Button("Chiedi a Siri AI+ di riassumerlo") { state.send("Riassumi il file \(entry.path)") }
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .glassCard(radius: 22)
            .padding(.leading, 20)
            .padding(.bottom, 16)
        } detail: {
            if let path = selected {
                if EditableFiles.extensions.contains((path as NSString).pathExtension.lowercased()) {
                    FileEditorView(project: project, path: path).id(path)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(path).font(DS.Fonts.bodyStrong).lineLimit(1)
                            Spacer()
                            Button("Apri") { if let url = try? project.files.resolve(path) { NSWorkspace.shared.open(url) } }
                            Button("Riassumi con Siri AI+") { state.send("Riassumi il file \(path)") }
                        }
                        ScrollView {
                            Text(preview)
                                .font(.system(size: 12.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView("Scegli un file", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Lo vedi e lo modifichi qui; l'agente a destra lavora sugli stessi file."))
            }
        }
        .task(id: state.projectRevision) {
            entries = project.files.list(depth: 4, limit: 1500)
            if let path = state.projectFileToOpen {
                state.projectFileToOpen = nil
                select(path)
            }
        }
    }

    private func row(_ entry: ProjectFiles.Entry) -> some View {
        let depth = filter.isEmpty ? entry.path.split(separator: "/").count - 1 : 0
        return HStack(spacing: 6) {
            if entry.isDirectory && filter.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed.contains(entry.path) ? 0 : 90))
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(entry.path) }
            } else {
                Color.clear.frame(width: 10)
            }
            if let url = try? project.files.resolve(entry.path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
            }
            Text(filter.isEmpty ? (entry.path as NSString).lastPathComponent : entry.path).lineLimit(1)
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    private func toggle(_ folder: String) {
        withAnimation(DS.Motion.quick) {
            if collapsed.contains(folder) { collapsed.remove(folder) } else { collapsed.insert(folder) }
        }
    }

    private func select(_ path: String?) {
        // Una cartella si apre e si chiude invece di essere «aperta» nell'editor.
        if let path, project.files.isDirectory(path) {
            toggle(path)
            return
        }
        selected = path
        guard let path else {
            preview = ""
            return
        }
        if !EditableFiles.extensions.contains((path as NSString).pathExtension.lowercased()) {
            preview = (try? project.files.read(path, maxChars: 20_000)) ?? "Anteprima non disponibile per questo tipo di file."
        }
    }

    private func create(_ base: String, ext: String, content: String) {
        var name = "\(base).\(ext)"
        var counter = 2
        while project.files.exists(name) { name = "\(base) \(counter).\(ext)"; counter += 1 }
        try? project.files.write(name, content: content)
        state.projectRevision += 1
        state.projectFileToOpen = name
    }
}

/// Impostazioni del progetto: scrittura dei file e connettori da usare.
struct ProjectSettingsView: View {
    @Environment(AppState.self) private var state
    let project: ProjectModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("File").font(DS.Fonts.section)
                    Toggle("Siri AI+ può creare, modificare e spostare file in questa cartella (sempre dopo la tua conferma)", isOn: Binding(
                        get: { project.allowWrite }, set: { project.allowWrite = $0; state.saveProjects() }))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connettori").font(DS.Fonts.section)
                    Text("Scegli quali servizi collegati usare nelle chat e negli agenti di questo progetto. Gli altri restano disponibili fuori dal progetto.")
                        .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if state.mcp.servers.isEmpty {
                        HStack {
                            Text("Nessun connettore configurato.").font(DS.Fonts.body).foregroundStyle(.secondary)
                            Button("Apri Connettori") { state.section = .connectors }
                        }
                    } else {
                        Toggle("Usa tutti i connettori attivi", isOn: Binding(
                            get: { project.connectorIDs == nil },
                            set: { all in
                                project.connectorIDs = all ? nil : Set(state.mcp.servers.map(\.id))
                                state.saveProjects()
                            }))
                        .toggleStyle(.switch)
                        VStack(spacing: 0) {
                            ForEach(state.mcp.servers) { server in
                                HStack(spacing: 10) {
                                    Image(systemName: server.transport == .stdio ? "terminal" : "network")
                                        .frame(width: 26, height: 26)
                                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(server.name).font(DS.Fonts.bodyStrong)
                                        Text((state.mcp.status[server.id] ?? .off).label).font(DS.Fonts.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { project.uses(server.id) },
                                        set: { use in
                                            var ids = project.connectorIDs ?? Set(state.mcp.servers.map(\.id))
                                            if use { ids.insert(server.id) } else { ids.remove(server.id) }
                                            project.connectorIDs = ids
                                            state.saveProjects()
                                        }))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .disabled(project.connectorIDs == nil)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                if server.id != state.mcp.servers.last?.id { Divider().padding(.leading, 50) }
                            }
                        }
                        .glassCard(radius: 24)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Due colonne affiancate senza NSSplitView (evita altri cicli di layout).
struct HSplitLayout<Sidebar: View, Detail: View>: View {
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 300)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AgentsEditor: View {
    @Environment(AppState.self) private var state
    let project: ProjectModel
    @State private var text = ""
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AGENTS.md").font(DS.Fonts.section)
                    Text("Istruzioni che Siri AI+ segue in ogni task di questo progetto. Se sono lunghe ne usa una sintesi.")
                        .font(DS.Fonts.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if project.files.agentsURL == nil && text.isEmpty {
                    Button("Usa un modello di partenza") { text = AppState.agentsTemplate(for: project.name) }
                }
                Button("Salva") { state.saveAgents(text, for: project) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")
            }
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .glassCard(radius: 18)
            if let digest = project.agentsDigest, digest.count < state.agentsText(for: project).count {
                DisclosureGroup("Sintesi usata dal modello") {
                    Text(digest).font(DS.Fonts.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(DS.Fonts.caption)
            }
        }
        .padding(24)
        .onAppear {
            guard !loaded else { return }
            text = state.agentsText(for: project)
            loaded = true
        }
    }
}

struct ProjectMemoryView: View {
    @Environment(AppState.self) private var state
    let project: ProjectModel
    @State private var text = ""
    @State private var newFact = ""
    @State private var saved = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MEMORY.md").font(DS.Fonts.section)
                    Text("La memoria del progetto, nella cartella come AGENTS.md: Siri AI+ la legge in ogni task (se è lunga ne usa una sintesi) e aggiunge sotto «Ricordi di Siri AI+» ciò che le chiedi di ricordare.")
                        .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Salva") {
                    try? project.files.saveMemoryText(text)
                    saved = true
                    state.projectRevision += 1
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
                .disabled(saved)
            }
            HStack {
                TextField("Aggiungi un fatto da ricordare", text: $newFact)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Aggiungi", action: add).disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextEditor(text: Binding(get: { text }, set: { text = $0; saved = false }))
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .glassCard(radius: 18)
            if let digest = project.memoryDigest, digest.count < text.count {
                DisclosureGroup("Sintesi usata dal modello") {
                    Text(digest).font(DS.Fonts.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(DS.Fonts.caption)
            }
        }
        .padding(24)
        .task(id: state.projectRevision) {
            guard saved else { return }
            project.files.ensureMemoryFile()
            text = project.files.memoryText()
        }
    }

    private func add() {
        let fact = newFact.trimmingCharacters(in: .whitespaces)
        guard !fact.isEmpty else { return }
        if !saved { try? project.files.saveMemoryText(text); saved = true }
        try? project.files.remember(fact)
        newFact = ""
        state.projectRevision += 1
    }
}
