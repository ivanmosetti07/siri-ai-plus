import AppKit
import QuickLookThumbnailing
import QuickLookUI
import SiriCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File
//
// Un piccolo Finder, come l'app File: posizioni a sinistra, percorso, elenco o icone con le anteprime, Quick Look nel
// pannello dei dettagli, e i documenti di testo (Markdown, note, codice) si aprono sul posto per leggerli e modificarli.
// La stessa vista è la sezione File di un progetto: lì si naviga solo dentro la sua cartella.

/// Formati che si aprono nell'editor di Siri AI+ (Markdown con anteprima, pagine web con anteprima live, testo e codice).
enum EditableFiles {
    static let extensions: Set<String> = ["md", "markdown", "txt", "html", "htm", "css", "scss", "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte",
                                          "json", "yaml", "yml", "csv", "xml", "plist", "swift", "py", "rb", "go", "rs", "kt", "java", "c", "h", "m",
                                          "cpp", "php", "sql", "sh", "toml", "env", "gitignore", "xcconfig", "entitlements"]
}

struct FilesAppView: View {
    @Environment(AppState.self) private var state
    @Environment(\.appTabActive) private var tabActive

    enum Place: Hashable {
        case recents, folder(URL)
    }

    enum Layout: String { case list, icons }

    /// La sezione File di un progetto: solo la sua cartella, con le sue posizioni (nil: l'app File, tutto il Mac).
    let project: ProjectModel?

    @State private var place: Place
    @State private var back = [Place]()
    @State private var forward = [Place]()
    @State private var entries = [FileEntry]()
    @State private var selection = Set<FileEntry.ID>()
    @State private var sortOrder = [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]
    @State private var search = ""
    @State private var searching = false
    @State private var showHidden = false
    @State private var loading = false
    @State private var error: String?
    @State private var renaming: URL?
    @State private var newName = ""
    @State private var trashing: [FileEntry] = []
    /// Documento aperto sul posto: si legge e si modifica qui, con «‹» si torna ai file (come l'app File su iPhone).
    @State private var opened: FileEntry?
    @State private var openedProject: ProjectModel?
    @AppStorage("filesLayout") private var storedLayout = Layout.list
    /// Diagnostica (`--files-layout icons`): la vista scelta solo per questa prova, senza salvarla.
    @State private var layoutOverride = AppTesting.value(after: "--files-layout").flatMap(Layout.init(rawValue:))
    @State private var searchVisible = false
    /// Le cartelle principali del progetto, nella colonna delle posizioni.
    @State private var folders: [URL] = []
    /// File da selezionare dopo aver aperto la sua cartella (aperto da una scheda della chat).
    @State private var pendingFocus: String?
    @State private var handledFocus: UUID?

    init(project: ProjectModel? = nil) {
        self.project = project
        _place = State(initialValue: .folder(project?.folder.standardizedFileURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents")))
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var root: URL? { project?.folder.standardizedFileURL }
    private var layout: Layout {
        get { layoutOverride ?? storedLayout }
        nonmutating set { if layoutOverride != nil { layoutOverride = newValue } else { storedLayout = newValue } }
    }
    private var folder: URL? { if case .folder(let url) = place { url } else { nil } }
    private var selected: [FileEntry] { entries.filter { selection.contains($0.id) } }
    private var canWrite: Bool { project?.allowWrite ?? state.canWrite(.files) }

    var body: some View {
        VStack(spacing: 0) {
            if project == nil {
                AppHeader(source: .files, title: String(localized: "File"), subtitle: subtitle, search: $search, searchPrompt: searchPrompt,
                          onSearch: runSearch, onRefresh: reload) {
                    newMenu
                }
                Divider()
            }
            AppSplit(sourcesWidth: 200, inspectorWidth: 300, minimumMain: 420, showInspector: selected.count == 1 && opened == nil) {
                placesList
            } main: {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    if let opened { document(opened) } else { content }
                }
            } inspector: {
                if let entry = selected.first {
                    FileInspector(entry: entry, canWrite: canWrite,
                                  onOpenFolder: { go(.folder(entry.url)) }, onRename: { startRename(entry) },
                                  onDuplicate: { duplicate(entry) }, onTrash: { trashing = [entry] }, onEdit: { openInPlace(entry) })
                        .id(entry.id)
                }
            }
        }
        .task(id: place) { reload() }
        .task(id: state.projectRevision) {
            guard project != nil else { return }
            loadFolders()
            reload()
        }
        .onChange(of: tabActive) { _, active in if active { reload() } }
        // Siri AI+ vede il file selezionato (con l'inizio del testo) o la cartella aperta.
        .task(id: "\(selection.sorted())|\(entries.count)|\(place)") { if project == nil { await publishScreen() } }
        .onChange(of: state.appFocus, initial: true) { _, focus in
            guard project == nil, let focus, focus.source == .files, focus.id != handledFocus else { return }
            handledFocus = focus.id
            reveal(URL(fileURLWithPath: focus.reference))
        }
        // «Apri AGENTS.md» e simili dalla chat del progetto: il file si apre qui.
        .onChange(of: state.projectFileToOpen, initial: true) { _, path in
            guard let project, let path, let url = try? project.files.resolve(path) else { return }
            state.projectFileToOpen = nil
            if let entry = FileStore.entry(url), !entry.isFolder {
                if place != .folder(url.deletingLastPathComponent().standardizedFileURL) { go(.folder(url.deletingLastPathComponent().standardizedFileURL)) }
                openInPlace(entry)
            } else {
                reveal(url)
            }
        }
        .onChange(of: showHidden) { _, _ in reload() }
        .onChange(of: search) { _, value in if value.isEmpty { searching = false; reload() } }
        .confirmationDialog(trashing.count == 1 ? String(localized: "Spostare «\(trashing.first?.name ?? "")» nel Cestino?") : String(localized: "Spostare \(trashing.count) elementi nel Cestino?"),
                            isPresented: Binding(get: { !trashing.isEmpty }, set: { if !$0 { trashing = [] } })) {
            Button("Sposta nel Cestino", role: .destructive) { trash(trashing) }
        } message: {
            Text("Si recuperano dal Cestino del Finder finché non lo svuoti.")
        }
    }

    private var subtitle: String {
        switch place {
        case .recents: project == nil ? String(localized: "Usati di recente") : String(localized: "Modificati di recente")
        case .folder(let url): url.path.replacingOccurrences(of: home.path, with: "~")
        }
    }

    private var searchPrompt: String {
        folder.map { String(localized: "Cerca in «\($0.lastPathComponent)»") } ?? (project.map { String(localized: "Cerca in «\($0.name)»") } ?? String(localized: "Cerca"))
    }

    private var newMenu: some View {
        Menu {
            Button("Nuova cartella") { newFolder() }
            Button("Nuovo documento Markdown") { newFile(ext: "md") }
            Button("Nuovo documento di testo") { newFile(ext: "txt") }
            if project != nil { Button("Nuova pagina HTML") { newFile(ext: "html") } }
        } label: { Image(systemName: "plus") }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
        .iconHelp(String(localized: "Nuovo"))
        .disabled(folder == nil || !canWrite)
    }

    // MARK: Posizioni

    private var favorites: [(String, String, URL)] {
        var items: [(String, String, URL)] = [
            (String(localized: "Scrivania"), "menubar.dock.rectangle", home.appending(path: "Desktop")),
            (String(localized: "Documenti"), "doc", home.appending(path: "Documents")),
            (String(localized: "Download"), "arrow.down.circle", home.appending(path: "Downloads")),
            // «Inizio» qui è la cartella Inizio del Finder (in inglese «Home»), non l'inizio di un evento.
            (String(localized: "files.home", defaultValue: "Inizio"), "house", home),
        ]
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) { items.append((String(localized: "iCloud Drive"), "icloud", iCloud)) }
        items.append((String(localized: "Applicazioni"), "square.grid.3x3", URL(fileURLWithPath: "/Applications")))
        return items
    }

    private var volumes: [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path != "/" }
    }

    @ViewBuilder private var placesList: some View {
        List(selection: Binding<Place?>(get: { place }, set: { if let value = $0 { go(value) } })) {
            if let project, let root {
                Section("Progetto") {
                    SourceRowLabel(title: project.name, symbol: "folder.fill", tint: .purple).tag(Place.folder(root))
                        .dropDestination(for: URL.self) { urls, _ in copy(urls, into: root); return true }
                    SourceRowLabel(title: String(localized: "Modificati di recente"), symbol: "clock", tint: .accentColor).tag(Place.recents)
                }
                if !folders.isEmpty {
                    Section("Cartelle") {
                        ForEach(folders, id: \.self) { url in
                            SourceRowLabel(title: url.lastPathComponent, symbol: "folder", tint: .accentColor).tag(Place.folder(url))
                                .dropDestination(for: URL.self) { urls, _ in move(urls, into: url); return true }
                        }
                    }
                }
            } else {
                Section("Preferiti") {
                    SourceRowLabel(title: String(localized: "Recenti"), symbol: "clock", tint: .accentColor).tag(Place.recents)
                    ForEach(favorites, id: \.2) { name, symbol, url in
                        SourceRowLabel(title: name, symbol: symbol, tint: .accentColor).tag(Place.folder(url))
                            .dropDestination(for: URL.self) { urls, _ in copy(urls, into: url); return true }
                    }
                }
                if !state.projects.isEmpty {
                    Section("Progetti") {
                        ForEach(state.projects) { project in
                            SourceRowLabel(title: project.name, symbol: "folder.fill", tint: .purple).tag(Place.folder(project.folder))
                        }
                    }
                }
                if !volumes.isEmpty {
                    Section("Posizioni") {
                        ForEach(volumes, id: \.self) { volume in
                            SourceRowLabel(title: FileManager.default.displayName(atPath: volume.path), symbol: "externaldrive", tint: .secondary)
                                .tag(Place.folder(volume))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// Le cartelle principali del progetto (senza dipendenze, build e nascoste).
    private func loadFolders() {
        guard let root else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        folders = urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true && !EditableFiles.hiddenFolders.contains(url.lastPathComponent)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Barra: navigazione, percorso, vista

    /// Una riga sola anche quando lo spazio è poco (progetto con la chat accanto): il percorso prende il posto che resta,
    /// la ricerca si apre al suo posto e le opzioni della vista stanno in un menu, come nell'app File.
    private var toolbar: some View {
        HStack(spacing: 6) {
            ControlGroup {
                Button { goBack() } label: { Image(systemName: "chevron.left") }.disabled(back.isEmpty && opened == nil).iconHelp(String(localized: "Indietro"))
                Button { goForward() } label: { Image(systemName: "chevron.right") }.disabled(forward.isEmpty || opened != nil).iconHelp(String(localized: "Avanti"))
            }
            .fixedSize()
            PlacesMenu(favorites: project == nil ? favorites : [], project: project, folders: folders) { go($0) }
            if searchVisible && opened == nil {
                AppSearchField(text: $search, prompt: searchPrompt, onSubmit: runSearch)
                Button(String(localized: "button.done", defaultValue: "Fine")) {
                    search = ""
                    searchVisible = false
                }
                .buttonStyle(.borderless)
            } else {
                pathBar.layoutPriority(1)
                Spacer(minLength: 4)
            }
            if opened == nil {
                if project != nil && !searchVisible {
                    Button { searchVisible = true } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                        .iconHelp(searchPrompt)
                }
                viewMenu
                if project != nil { newMenu }
            } else if let opened {
                Button { state.openFile(opened.url) } label: { Image(systemName: "macwindow.on.rectangle") }
                    .buttonStyle(.borderless)
                    .iconHelp(String(localized: "Apri in una scheda (resta aperto con questa chat)"))
                Button { NSWorkspace.shared.activateFileViewerSelecting([opened.url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .iconHelp(String(localized: "Mostra nel Finder"))
                Button { state.send(String(localized: "Riassumi il file \(opened.url.path)")) } label: { Image(systemName: "sparkle") }
                    .buttonStyle(.borderless)
                    .iconHelp(String(localized: "Chiedi a Siri AI+ di riassumerlo"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Icone o elenco, ordinamento, file nascosti: il menu della vista, come nell'app File.
    private var viewMenu: some View {
        Menu {
            Picker("Vista", selection: Binding(get: { layout }, set: { layout = $0 })) {
                Label("Icone", systemImage: "square.grid.2x2").tag(Layout.icons)
                Label("Elenco", systemImage: "list.bullet").tag(Layout.list)
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Ordina per", selection: Binding(get: { sortKey }, set: { setSort($0, ascending: sortAscending) })) {
                Text("Nome").tag("nome")
                Text("Data di modifica").tag("data")
                Text("Dimensioni").tag("dimensioni")
                Text(String(localized: "file.kind", defaultValue: "Tipo")).tag("tipo")
            }
            .pickerStyle(.inline)
            Picker("Ordine", selection: Binding(get: { sortAscending }, set: { setSort(sortKey, ascending: $0) })) {
                Text("Crescente").tag(true)
                Text("Decrescente").tag(false)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Mostra i file nascosti", isOn: $showHidden)
        } label: {
            Image(systemName: layout == .icons ? "square.grid.2x2" : "list.bullet")
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
        .iconHelp(String(localized: "Vista: icone o elenco, ordinamento, file nascosti"))
    }

    private var pathBar: some View {
        HStack(spacing: 2) {
            if let folder {
                let parts = ancestors(of: folder)
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { index, url in
                            if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
                            Button { opened = nil; go(.folder(url)) } label: {
                                Label(crumbTitle(url), systemImage: crumbSymbol(url))
                                    .font(.system(size: 12, weight: index == parts.count - 1 && opened == nil ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.borderless)
                            .dropDestination(for: URL.self) { urls, _ in move(urls, into: url); return true }
                        }
                        if let opened {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            HStack(spacing: 4) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: opened.url.path)).resizable().frame(width: 14, height: 14)
                                Text(opened.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            } else {
                Label(project == nil ? String(localized: "Usati di recente") : String(localized: "Modificati di recente"), systemImage: "clock").font(.system(size: 12, weight: .semibold))
            }
        }
    }

    private func crumbTitle(_ url: URL) -> String {
        if let project, url.standardizedFileURL == root { return project.name }
        return url.path == "/" ? String(localized: "Macintosh HD") : FileManager.default.displayName(atPath: url.path)
    }

    private func crumbSymbol(_ url: URL) -> String {
        if project != nil, url.standardizedFileURL == root { return "folder.fill" }
        return url == home ? "house" : "folder"
    }

    private var sortKey: String {
        guard let first = sortOrder.first else { return "nome" }
        func matches(_ comparator: KeyPathComparator<FileEntry>) -> Bool {
            var current = first
            current.order = .forward
            return current == comparator
        }
        if matches(KeyPathComparator(\FileEntry.sortDate)) { return "data" }
        if matches(KeyPathComparator(\FileEntry.sortSize)) { return "dimensioni" }
        if matches(KeyPathComparator(\FileEntry.kind)) { return "tipo" }
        return "nome"
    }

    private var sortAscending: Bool { sortOrder.first?.order != .reverse }

    private func setSort(_ key: String, ascending: Bool) {
        let order: SortOrder = ascending ? .forward : .reverse
        sortOrder = switch key {
        case "data": [KeyPathComparator(\FileEntry.sortDate, order: order)]
        case "dimensioni": [KeyPathComparator(\FileEntry.sortSize, order: order)]
        case "tipo": [KeyPathComparator(\FileEntry.kind, order: order)]
        default: [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard, order: order)]
        }
    }

    private func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        while true {
            result.insert(current, at: 0)
            if current.path == "/" || current == home || current == root { break }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return result
    }

    // MARK: Contenuto

    @ViewBuilder private var content: some View {
        if let error {
            AccessNotice(symbol: "folder.badge.questionmark", title: String(localized: "Cartella non leggibile"), message: error,
                         primary: (String(localized: "Riprova"), reload), secondary: (String(localized: "Permessi"), { PermissionCenter.openSettings(.fullDisk) }))
        } else if loading && entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            AppPlaceholder(symbol: searching ? "magnifyingglass" : "folder", title: searching ? String(localized: "Nessun file trovato") : String(localized: "Cartella vuota"),
                           message: folder != nil && !searching ? String(localized: "Trascina qui i file dal Finder per copiarli.") : nil)
                .dropDestination(for: URL.self) { urls, _ in if let folder { copy(urls, into: folder) }; return folder != nil }
        } else if layout == .icons {
            iconGrid
        } else {
            table
        }
    }

    private var table: some View {
        Table(of: FileEntry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(String(localized: "Nome"), value: \.name, comparator: .localizedStandard) { entry in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 18, height: 18)
                    if renaming == entry.url {
                        TextField("Nome", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitRename(entry) }
                            .onExitCommand { renaming = nil }
                    } else {
                        Text(entry.name).lineLimit(1)
                        // Nella ricerca e nei recenti conta anche dove sta.
                        if searching || place == .recents {
                            Text(location(of: entry)).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
            }
            .width(min: 160, ideal: 280)
            TableColumn(String(localized: "Modificato"), value: \.sortDate) { entry in
                Text(entry.modified.map { $0.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Dates.locale)) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 136)
            TableColumn(String(localized: "Dimensioni"), value: \.sortSize) { entry in
                Text(entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 70)
            TableColumn(String(localized: "file.kind", defaultValue: "Tipo"), value: \.kind) { entry in Text(entry.kind).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 60, ideal: 110)
        } rows: {
            ForEach(entries) { entry in
                TableRow(entry).draggable(entry.url)
            }
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .onChange(of: sortOrder) { _, order in entries.sort(using: order); keepFoldersFirst() }
        .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
            contextMenu(for: entries.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            guard let entry = entries.first(where: { ids.contains($0.id) }) else { return }
            open(entry)
        }
        .onDeleteCommand { if canWrite, !selected.isEmpty { trashing = selected } }
        .dropDestination(for: URL.self) { urls, _ in if let folder { copy(urls, into: folder) }; return folder != nil }
    }

    /// Icone grandi con l'anteprima del contenuto (immagini, PDF, documenti), come nel Finder e nell'app File.
    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 132), spacing: 6)], spacing: 12) {
                ForEach(entries) { entry in
                    FileIconCell(entry: entry, selected: selection.contains(entry.id), renaming: renaming == entry.url, newName: $newName,
                                 commit: { commitRename(entry) }, cancel: { renaming = nil })
                        .onTapGesture(count: 2) { open(entry) }
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) {
                                if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
                            } else {
                                selection = [entry.id]
                            }
                        }
                        .contextMenu { contextMenu(for: selection.contains(entry.id) ? selected : [entry]) }
                        .draggable(entry.url)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard entry.isFolder else { return false }
                            move(urls, into: entry.url)
                            return true
                        }
                }
            }
            .padding(14)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = [] })
        .onDeleteCommand { if canWrite, !selected.isEmpty { trashing = selected } }
        .dropDestination(for: URL.self) { urls, _ in if let folder { copy(urls, into: folder) }; return folder != nil }
    }

    /// Dove sta un file trovato con la ricerca o nei recenti (relativo al progetto, se c'è).
    private func location(of entry: FileEntry) -> String {
        let parent = entry.url.deletingLastPathComponent().standardizedFileURL.path
        if let root, parent.hasPrefix(root.path) {
            let inside = String(parent.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return inside.isEmpty ? (project?.name ?? "") : inside
        }
        return parent.replacingOccurrences(of: home.path, with: "~")
    }

    // MARK: Documento aperto sul posto

    @ViewBuilder
    private func document(_ entry: FileEntry) -> some View {
        if let editor = openedProject, let path = editorPath(for: entry, in: editor) {
            FileEditorView(project: editor, path: path, startsInReading: ["md", "markdown"].contains(entry.ext),
                           onOpenLink: { target in state.openLinkedFile(target, from: entry.url) })
                .id(entry.url)
        } else {
            AppPlaceholder(symbol: "doc.questionmark", title: String(localized: "Non riesco ad aprire «\(entry.name)»"))
        }
    }

    private func editorPath(for entry: FileEntry, in editor: ProjectModel) -> String? {
        let base = editor.folder.standardizedFileURL.path
        let full = entry.url.standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { return nil }
        return String(full.dropFirst(base.count + 1))
    }

    /// Markdown, testo e codice si aprono qui; il resto con l'app del Mac.
    private func openInPlace(_ entry: FileEntry) {
        guard EditableFiles.extensions.contains(entry.ext) || entry.ext.isEmpty else {
            NSWorkspace.shared.open(entry.url)
            return
        }
        if let project, let root, entry.url.standardizedFileURL.path.hasPrefix(root.path + "/") {
            openedProject = project
        } else {
            openedProject = ProjectModel(name: String(localized: "File"), folder: entry.url.deletingLastPathComponent(), allowWrite: canWrite)
        }
        selection = [entry.id]
        withAnimation(DS.Motion.standard) { opened = entry }
    }

    @ViewBuilder private func contextMenu(for items: [FileEntry]) -> some View {
        if let entry = items.first, items.count == 1 {
            if entry.isFolder {
                Button("Apri") { open(entry) }
            } else {
                if EditableFiles.extensions.contains(entry.ext) {
                    Button("Apri qui") { openInPlace(entry) }
                    Button("Apri in una scheda") { state.openFile(entry.url) }
                }
                if ["html", "htm"].contains(entry.ext) {
                    Button("Apri in Safari (in questa chat)") { state.openInBrowser(entry.url) }
                }
                Button("Apri con l'app predefinita") { NSWorkspace.shared.open(entry.url) }
            }
            Button("Chiedi a Siri AI+") { state.send(entry.isFolder ? String(localized: "Cosa c'è nella cartella \(entry.url.path)?") : String(localized: "Riassumi il file \(entry.url.path)")) }
            Divider()
            Button("Rinomina") { startRename(entry) }.disabled(!canWrite)
            Button("Duplica") { duplicate(entry) }.disabled(!canWrite)
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("Copia percorso") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.path, forType: .string)
            }
            Divider()
        }
        if folder != nil {
            Button("Nuova cartella") { newFolder() }.disabled(!canWrite)
        }
        if !items.isEmpty {
            Button(items.count == 1 ? String(localized: "Sposta nel Cestino") : String(localized: "Sposta \(items.count) elementi nel Cestino"), role: .destructive) { trashing = items }
                .disabled(!canWrite)
        }
    }

    // MARK: Navigazione

    /// Nei progetti si resta dentro la loro cartella.
    private func allowed(_ destination: Place) -> Bool {
        guard let root, case .folder(let url) = destination else { return true }
        let path = url.standardizedFileURL.path
        return path == root.path || path.hasPrefix(root.path + "/")
    }

    private func go(_ destination: Place) {
        opened = nil
        guard destination != place, allowed(destination) else { return }
        back.append(place)
        forward.removeAll()
        search = ""
        place = destination
    }

    private func goBack() {
        if opened != nil { withAnimation(DS.Motion.standard) { opened = nil }; return }
        guard let previous = back.popLast() else { return }
        forward.append(place)
        place = previous
    }

    private func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(place)
        place = next
    }

    /// Mostra un file o una cartella (aperti da una scheda della chat): la cartella si apre, il file si seleziona.
    private func reveal(_ url: URL) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
        if isFolder.boolValue {
            go(.folder(url.standardizedFileURL))
        } else if place == .folder(url.deletingLastPathComponent().standardizedFileURL) {
            selection = [url.path]
        } else {
            pendingFocus = url.path
            go(.folder(url.deletingLastPathComponent().standardizedFileURL))
        }
    }

    private func publishScreen() async {
        if selection.count == 1, let entry = entries.first(where: { selection.contains($0.id) }) {
            let item = await ScreenItem.file(entry)
            guard !Task.isCancelled else { return }
            state.publish(item, for: .app(.files))
        } else {
            let url: URL? = if case .folder(let url) = place { url } else { nil }
            state.publish(url.map { ScreenItem.folder($0, entries: entries) }
                          ?? ScreenItem(app: String(localized: "File"), kind: .overview, title: String(localized: "file recenti"), text: entries.prefix(30).map(\.name).joined(separator: "\n"),
                                        nouns: ["file", "documenti"]), for: .app(.files))
        }
    }

    private func reload() {
        selection = selection.filter { id in entries.contains { $0.id == id } }
        error = nil
        switch place {
        case .recents:
            loading = true
            Task {
                entries = if let root { await FileStore.recentlyModified(in: root) } else { await FileStore.recents() }
                loading = false
            }
        case .folder(let url):
            do {
                entries = try FileStore.list(url, showHidden: showHidden)
                if !sortedByName { entries.sort(using: sortOrder); keepFoldersFirst() }
                if let pendingFocus, entries.contains(where: { $0.id == pendingFocus }) { selection = [pendingFocus]; self.pendingFocus = nil }
                if AppTesting.selectFirst, selection.isEmpty, let file = entries.first(where: { !$0.isFolder }) ?? entries.first { selection = [file.id] }
            } catch {
                entries = []
                self.error = (error as NSError).code == 257 || (error as NSError).code == 1
                    ? String(localized: "Siri AI+ non ha il permesso di aprire questa cartella. Concedi l'accesso quando macOS lo chiede, o l'accesso completo al disco.")
                    : error.localizedDescription
            }
        }
    }

    /// Ordinati per nome (come arrivano dal disco): le cartelle restano in cima.
    private var sortedByName: Bool {
        sortOrder.first.map { $0.keyPath == (\FileEntry.name as PartialKeyPath<FileEntry>) } ?? true
    }

    private func keepFoldersFirst() {
        guard sortedByName else { return }
        let ascending = sortOrder.first?.order == .forward
        entries = entries.filter(\.isFolder) + entries.filter { !$0.isFolder }
        if !ascending { entries.reverse() }
    }

    private func runSearch() {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { reload(); return }
        let scope = folder ?? root ?? home
        loading = true
        searching = true
        opened = nil
        Task {
            entries = project == nil ? await FileStore.search(query, in: scope) : await FileStore.find(query, in: scope)
            loading = false
        }
    }

    /// Cartelle: si entra. Nei progetti Markdown, testo e codice si aprono sul posto; nell'app File in una scheda della chat.
    private func open(_ entry: FileEntry) {
        if entry.isFolder { go(.folder(entry.url.standardizedFileURL)) }
        else if project != nil { openInPlace(entry) }
        else { state.openAny(entry.url) }
    }

    // MARK: Azioni

    private func newFolder() {
        guard let folder, canWrite else { return }
        do {
            let url = try FileStore.newFolder(in: folder)
            reload()
            if let entry = entries.first(where: { $0.url == url }) { selection = [entry.id]; startRename(entry) }
            if project != nil { state.projectRevision += 1 }
        } catch { state.appFailed(.files, String(localized: "Cartella non creata"), error) }
    }

    private func newFile(ext: String) {
        guard let folder, canWrite else { return }
        let content = switch ext {
        case "md": "# Senza titolo\n\n"
        case "html": (Language.system == .it
                  ? "<!doctype html>\n<html lang=\"it\">\n<head>\n    <meta charset=\"utf-8\">\n    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n    <title>Pagina</title>\n</head>\n<body>\n    <h1>Ciao!</h1>\n</body>\n</html>\n"
                  : "<!doctype html>\n<html lang=\"en\">\n<head>\n    <meta charset=\"utf-8\">\n    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n    <title>Page</title>\n</head>\n<body>\n    <h1>Hello!</h1>\n</body>\n</html>\n")
        default: ""
        }
        do {
            let url = try FileStore.newTextFile(in: folder, ext: ext, content: content)
            reload()
            if let entry = entries.first(where: { $0.url == url }) { selection = [entry.id]; startRename(entry) }
        } catch { state.appFailed(.files, String(localized: "Documento non creato"), error) }
    }

    private func startRename(_ entry: FileEntry) {
        guard canWrite else { return }
        newName = entry.isFolder || entry.ext.isEmpty ? entry.name : (entry.name as NSString).deletingPathExtension
        renaming = entry.url
    }

    private func commitRename(_ entry: FileEntry) {
        defer { renaming = nil }
        do {
            let url = try FileStore.rename(entry.url, to: newName)
            if url != entry.url { state.appDone(.files, String(localized: "Rinominato"), detail: url.lastPathComponent) }
            reload()
            if let renamed = entries.first(where: { $0.url == url }) { selection = [renamed.id] }
        } catch { state.appFailed(.files, String(localized: "Non rinominato"), error) }
    }

    private func duplicate(_ entry: FileEntry) {
        do {
            let url = try FileStore.duplicate(entry.url)
            state.appDone(.files, String(localized: "Duplicato"), detail: url.lastPathComponent)
            reload()
            if let copy = entries.first(where: { $0.url == url }) { selection = [copy.id] }
        } catch { state.appFailed(.files, String(localized: "Non duplicato"), error) }
    }

    private func trash(_ items: [FileEntry]) {
        var moved = 0
        for item in items {
            do { try FileStore.trash(item.url); moved += 1 } catch { state.appFailed(.files, String(localized: "Non spostato nel Cestino"), error) }
        }
        if moved > 0 { state.appDone(.files, moved == 1 ? String(localized: "Spostato nel Cestino") : String(localized: "\(moved) elementi nel Cestino"), detail: items.map(\.name).joined(separator: ", ")) }
        selection = []
        trashing = []
        if items.contains(where: { $0.id == opened?.id }) { opened = nil }
        reload()
    }

    /// File trascinati dal Finder: si copiano (l'originale resta dov'era).
    private func copy(_ urls: [URL], into destination: URL) {
        guard canWrite else { return }
        var copied = 0
        for url in urls where url.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL {
            let target = FileStore.freeName(url.deletingPathExtension().lastPathComponent, ext: url.pathExtension, in: destination)
            do { try FileManager.default.copyItem(at: url, to: target); copied += 1 } catch { state.appFailed(.files, String(localized: "Non copiato"), error) }
        }
        if copied > 0 { state.appDone(.files, copied == 1 ? String(localized: "File copiato") : String(localized: "\(copied) file copiati"), detail: destination.lastPathComponent) }
        reload()
    }

    /// Trascinati su una cartella del percorso: si spostano (come nel Finder sullo stesso disco).
    private func move(_ urls: [URL], into destination: URL) {
        guard canWrite else { return }
        var moved = 0
        for url in urls where url.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL && url != destination {
            do { try FileStore.move(url, into: destination); moved += 1 } catch { state.appFailed(.files, String(localized: "Non spostato"), error) }
        }
        if moved > 0 { state.appDone(.files, moved == 1 ? String(localized: "Spostato") : String(localized: "\(moved) elementi spostati"), detail: destination.lastPathComponent) }
        reload()
    }
}

extension EditableFiles {
    /// Cartelle che nei progetti non si mostrano tra le posizioni (dipendenze, build, cache).
    static let hiddenFolders: Set<String> = ["node_modules", "build", "dist", "DerivedData", "Pods", "venv", "__pycache__", "vendor"]
}

extension FileEntry {
    var sortDate: Date { modified ?? .distantPast }
    var sortSize: Int64 { size ?? -1 }
}

/// Le posizioni quando la finestra è stretta e la loro colonna non c'è.
private struct PlacesMenu: View {
    @Environment(\.appSourcesVisible) private var sourcesVisible
    let favorites: [(String, String, URL)]
    let project: ProjectModel?
    let folders: [URL]
    let go: (FilesAppView.Place) -> Void

    var body: some View {
        if !sourcesVisible {
            Menu {
                if let project {
                    Button(project.name) { go(.folder(project.folder.standardizedFileURL)) }
                    Button("Modificati di recente") { go(.recents) }
                    if !folders.isEmpty {
                        Divider()
                        ForEach(folders, id: \.self) { url in Button(url.lastPathComponent) { go(.folder(url)) } }
                    }
                } else {
                    Button("Recenti") { go(.recents) }
                    Divider()
                    ForEach(favorites, id: \.2) { name, _, url in Button(name) { go(.folder(url)) } }
                }
            } label: { Image(systemName: "sidebar.left") }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
            .iconHelp(String(localized: "Posizioni"))
        }
    }
}

// MARK: - Icone

/// Un file nella vista a icone: l'anteprima del contenuto e il nome sotto, evidenziati quando è selezionato.
private struct FileIconCell: View {
    let entry: FileEntry
    let selected: Bool
    let renaming: Bool
    @Binding var newName: String
    let commit: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            FileThumbnail(entry: entry, size: 64)
                .padding(6)
                .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if renaming {
                TextField("Nome", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.center)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
            } else {
                Text(entry.name)
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .frame(width: 108)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(entry.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name)\(selected ? String(localized: ", selezionato") : "")")
    }
}

/// Anteprima di un file (Quick Look: immagini, PDF, documenti, testo); per le cartelle e finché non è pronta, l'icona del Mac.
struct FileThumbnail: View {
    let entry: FileEntry
    var size: CGFloat = 64
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: entry.url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(image == nil ? 0 : 0.18), radius: 2, y: 1)
            .task(id: entry.url) { image = await Self.thumbnail(entry, size: size) }
    }

    static func thumbnail(_ entry: FileEntry, size: CGFloat) async -> NSImage? {
        guard !entry.isFolder, !entry.isPackage else { return nil }
        let key = "\(entry.url.path)|\(entry.modified?.timeIntervalSince1970 ?? 0)|\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: CGSize(width: size, height: size), scale: 2,
                                                   representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = representation.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - Dettaglio del file

private struct FileInspector: View {
    @Environment(AppState.self) private var state
    let entry: FileEntry
    let canWrite: Bool
    let onOpenFolder: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onTrash: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    QuickLookPreview(url: entry.url)
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(entry.name).font(.system(size: 16, weight: .bold)).textSelection(.enabled)
                    InspectorGroup {
                        InspectorRow(label: String(localized: "file.kind", defaultValue: "Tipo")) { Text(entry.kind) }
                        if let size = entry.size {
                            InspectorRow(label: String(localized: "Dimensioni")) { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                        }
                        if let created = entry.created {
                            InspectorRow(label: String(localized: "Creato")) { Text(Dates.friendly(created)) }
                        }
                        if let modified = entry.modified {
                            InspectorRow(label: String(localized: "Modificato")) { Text(Dates.friendly(modified)) }
                        }
                        InspectorRow(label: String(localized: "Posizione"), divider: false) {
                            Text(entry.url.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                .font(.system(size: 12)).textSelection(.enabled).lineLimit(3)
                        }
                    }
                    .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 8) {
                        if entry.isFolder {
                            Button { onOpenFolder() } label: { Label("Apri la cartella", systemImage: "folder") }
                        } else {
                            if EditableFiles.extensions.contains(entry.ext) {
                                Button { onEdit() } label: { Label("Apri qui", systemImage: "doc.text") }
                                Button { state.openFile(entry.url) } label: { Label("Apri in una scheda", systemImage: "macwindow.on.rectangle") }
                            }
                            if ["html", "htm"].contains(entry.ext) {
                                Button { state.openInBrowser(entry.url) } label: { Label("Apri in Safari (in questa chat)", systemImage: "safari") }
                            }
                            Button { NSWorkspace.shared.open(entry.url) } label: { Label("Apri con l'app del Mac", systemImage: "arrow.up.forward.app") }
                        }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Label("Mostra nel Finder", systemImage: "magnifyingglass") }
                        Button { state.send(entry.isFolder ? String(localized: "Cosa c'è nella cartella \(entry.url.path)?") : String(localized: "Riassumi il file \(entry.url.path)")) } label: {
                            Label("Chiedi a Siri AI+", systemImage: "sparkle")
                        }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 13))
                }
                .padding(16)
            }
            InspectorFooter {
                Button(role: .destructive) { onTrash() } label: { Image(systemName: "trash") }.iconHelp(String(localized: "Sposta nel Cestino")).disabled(!canWrite)
                Button { onDuplicate() } label: { Image(systemName: "plus.square.on.square") }.iconHelp(String(localized: "Duplica")).disabled(!canWrite)
            } trailing: {
                Button("Rinomina", action: onRename).disabled(!canWrite)
            }
        }
    }
}

/// Anteprima Quick Look (documenti, immagini, PDF, video…).
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
