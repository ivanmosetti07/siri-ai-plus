import AppKit
import SiriCore
import SwiftUI

// MARK: - Note

struct NotesAppView: View {
    @Environment(AppState.self) private var state
    @Environment(\.appTabActive) private var tabActive

    enum Folder: Hashable { case all, folder(String) }

    @State private var folders = [NotesFolder]()
    @State private var selection = Folder.all
    @State private var notes = [NoteSummary]()
    @State private var selectedID: String?
    /// Nota aperta nell'editor. Una nota nuova non esiste ancora in Note (si crea al primo carattere scritto):
    /// quando nasce, l'editor resta lo stesso (stessa `key`), così chi scrive non perde il cursore.
    @State private var openNote: OpenNote?
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var folderSheet: FolderSheet?
    @State private var deletingFolder: NotesFolder?
    /// Nota da aprire appena l'elenco è pronto (aperta da una scheda della chat).
    @State private var pendingFocus: String?
    @State private var handledFocus: UUID?

    struct OpenNote: Equatable { let key = UUID(); var noteID: String?; let folderID: String? }
    struct FolderSheet: Identifiable { var id: String { folder?.id ?? "nuova" }; var folder: NotesFolder? }

    private var currentFolder: NotesFolder? {
        if case .folder(let id) = selection { return folders.first { $0.id == id } }
        return nil
    }

    private var visible: [NoteSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return notes }
        return notes.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(source: .notes, title: String(localized: "Note"), subtitle: String(localized: "\(notes.count) note"), search: $search, searchPrompt: String(localized: "Cerca nelle note"),
                      onRefresh: { Task { await reload() } }) {
                AppIconButton(symbol: "square.and.pencil", help: String(localized: "Nuova nota"), prominent: true) { newNote() }
                    .disabled(!state.canWrite(.notes) || currentFolder?.isTrash == true)
            }
            Divider()
            if let error, notes.isEmpty, folders.isEmpty {
                AccessNotice(symbol: "note.text", title: String(localized: "Note non risponde"), message: error,
                             primary: (String(localized: "Riprova"), { Task { await reload() } }),
                             secondary: (String(localized: "Permessi"), { PermissionCenter.openSettings(.automation) }))
            } else {
                AppColumns(sourcesWidth: 210, itemsWidth: 300) {
                    folderList
                } items: {
                    noteList
                } detail: {
                    if let open = openNote {
                        NoteEditor(noteID: open.noteID, folderID: open.folderID, folders: folders,
                                   canWrite: state.canWrite(.notes) && currentFolder?.isTrash != true,
                                   onCreated: { id in
                                       openNote?.noteID = id
                                       selectedID = id
                                       Task { await reload(keepSelection: true) }
                                   },
                                   onChanged: { Task { await reload(keepSelection: true) } },
                                   onDeleted: { openNote = nil; selectedID = nil; Task { await reload() } })
                            .id(open.key)
                    } else {
                        AppPlaceholder(symbol: "note.text", title: String(localized: "Nessuna nota selezionata"),
                                       message: String(localized: "Scegli una nota da leggere e modificare, oppure creane una nuova."),
                                       actionTitle: state.canWrite(.notes) ? String(localized: "Nuova nota") : nil, action: newNote)
                    }
                }
            }
        }
        .task { await reload() }
        // Tornando sulla scheda l'elenco si aggiorna (note create dalla chat o in Note), senza chiudere la nota aperta.
        .onChange(of: tabActive) { _, active in if active { Task { await reload(keepSelection: true) } } }
        // Senza nota aperta Siri AI+ vede l'elenco della cartella (la nota aperta la descrive l'editor).
        .onChange(of: selectedID, initial: true) { _, id in if id == nil, openNote == nil { publishOverview(notes) } }
        .onChange(of: notes) { _, list in if selectedID == nil, openNote == nil { publishOverview(list) } }
        .onChange(of: selection) { _, _ in
            selectedID = nil
            openNote = nil
            Task { await loadNotes() }
        }
        .onChange(of: selectedID) { _, value in
            guard let value else { if openNote?.noteID != nil { openNote = nil }; return }
            if openNote?.noteID != value { openNote = OpenNote(noteID: value, folderID: nil) }
        }
        .onChange(of: state.appFocus, initial: true) { _, focus in
            guard let focus, focus.source == .notes, focus.id != handledFocus else { return }
            handledFocus = focus.id
            pendingFocus = focus.reference
            if selection != .all { selection = .all } else { applyFocus() }
        }
        .sheet(item: $folderSheet) { sheet in
            FolderEditor(folder: sheet.folder, accounts: accounts) { name, accountID in saveFolder(sheet.folder, name: name, accountID: accountID) }
        }
        .confirmationDialog("Eliminare la cartella «\(deletingFolder?.name ?? "")»?", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
                            presenting: deletingFolder) { folder in
            Button("Elimina cartella", role: .destructive) { deleteFolder(folder) }
        } message: { folder in
            Text(folder.count == 0 ? String(localized: "La cartella è vuota.") : String(localized: "Le sue \(folder.count) note finiscono in «Eliminate di recente» di Note, da cui si recuperano per 30 giorni."))
        }
    }

    private var accounts: [(id: String, name: String)] {
        var seen = Set<String>()
        return folders.compactMap { seen.insert($0.accountID).inserted ? ($0.accountID, $0.account) : nil }
    }

    // MARK: Cartelle

    private var folderList: some View {
        List(selection: Binding(get: { selection }, set: { if let value = $0 { selection = value } })) {
            Section {
                SourceRowLabel(title: String(localized: "Tutte le note"), symbol: "tray.full", tint: .orange,
                               count: folders.filter { !$0.isTrash }.reduce(0) { $0 + $1.count }).tag(Folder.all)
            }
            ForEach(accounts, id: \.id) { account in
                Section(account.name) {
                    ForEach(folders.filter { $0.accountID == account.id }.sorted { ($0.isTrash ? 1 : 0, $0.name) < ($1.isTrash ? 1 : 0, $1.name) }) { folder in
                        SourceRowLabel(title: folder.isTrash ? String(localized: "Eliminate di recente") : folder.name, symbol: folder.isTrash ? "trash" : "folder",
                                       tint: folder.isTrash ? .secondary : .orange, count: folder.count)
                            .tag(Folder.folder(folder.id))
                            .contextMenu {
                                if !folder.isTrash {
                                    Button("Rinomina…") { folderSheet = FolderSheet(folder: folder) }
                                    Button("Elimina cartella…", role: .destructive) { deletingFolder = folder }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button { folderSheet = FolderSheet(folder: nil) } label: {
                Label("Nuova cartella", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .disabled(!state.canWrite(.notes))
        }
    }

    // MARK: Elenco

    private var noteList: some View {
        VStack(spacing: 0) {
            ListHeading(title: currentFolder.map { $0.isTrash ? String(localized: "Eliminate di recente") : $0.name } ?? String(localized: "Tutte le note"), tint: .orange,
                        count: "\(visible.count)") {
                FoldersMenu(folders: folders, selection: $selection)
            }
            if loading && notes.isEmpty {
                ProgressView("Leggo le note…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty && !writingNewNote {
                AppPlaceholder(symbol: search.isEmpty ? "note.text" : "magnifyingglass", title: search.isEmpty ? String(localized: "Nessuna nota") : String(localized: "Nessun risultato"))
            } else {
                List(selection: $selectedID) {
                    if writingNewNote {
                        NoteRow(title: String(localized: "Nuova nota"), date: .now, preview: String(localized: "Scrivi qualcosa per salvarla in Note"))
                            .listRowBackground(Color.accentColor.opacity(0.15))
                    }
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.notes) { note in
                                NoteRow(title: note.title, date: note.modified, preview: note.preview)
                                    .tag(note.id)
                                    .contextMenu { noteMenu(note) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// Come in Note: Oggi, Ieri, Ultimi 7 giorni, Ultimi 30 giorni, poi per mese.
    private var groups: [(title: String, notes: [NoteSummary])] {
        let cal = Calendar.current
        func bucket(_ date: Date) -> String {
            if cal.isDateInToday(date) { return String(localized: "Oggi") }
            if cal.isDateInYesterday(date) { return String(localized: "Ieri") }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: .now)).day ?? 0
            if days < 7 { return String(localized: "Ultimi 7 giorni") }
            if days < 30 { return String(localized: "Ultimi 30 giorni") }
            return date.formatted(.dateTime.month(.wide).year().locale(Dates.locale)).capitalized
        }
        var order: [String] = []
        var map: [String: [NoteSummary]] = [:]
        for note in visible {
            let key = bucket(note.modified)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(note)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    @ViewBuilder private func noteMenu(_ note: NoteSummary) -> some View {
        Menu("Sposta in") {
            ForEach(folders.filter { !$0.isTrash }) { folder in
                Button("\(folder.name) (\(folder.account))") { move(note, to: folder) }
            }
        }
        .disabled(!state.canWrite(.notes))
        Button("Apri in Note") { Task { await NotesService.open(id: note.id) } }
        Divider()
        Button("Elimina", role: .destructive) { delete(note) }.disabled(!state.canWrite(.notes))
    }

    // MARK: Dati e azioni

    private func publishOverview(_ list: [NoteSummary]) {
        state.publish(.notes(folder: currentFolder.map { String(localized: "cartella «\($0.name)»") } ?? String(localized: "tutte le note"), notes: list), for: .app(.notes))
    }

    private func reload(keepSelection: Bool = false) async {
        loading = true
        do {
            folders = try await NotesStore.folders()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await loadNotes()
        if !keepSelection, let selectedID, !notes.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }

    private func loadNotes() async {
        loading = true
        defer { loading = false }
        do {
            switch selection {
            case .all:
                var all = try await NotesStore.notes(in: nil)
                // Le eliminate di recente non stanno in «Tutte le note».
                for trash in folders where trash.isTrash && trash.count > 0 {
                    let removed = try await NotesStore.ids(in: trash.id)
                    all.removeAll { removed.contains($0.id) }
                }
                notes = all
            case .folder(let id):
                notes = try await NotesStore.notes(in: id)
            }
            error = nil
            applyFocus()
            if AppTesting.selectFirst, selectedID == nil { selectedID = notes.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyFocus() {
        guard let pendingFocus, notes.contains(where: { $0.id == pendingFocus }) else { return }
        selectedID = pendingFocus
        self.pendingFocus = nil
    }

    /// Nota nuova aperta e non ancora salvata in Note.
    private var writingNewNote: Bool { openNote != nil && openNote?.noteID == nil }

    private func newNote() {
        guard state.canWrite(.notes) else { return }
        selectedID = nil
        openNote = OpenNote(noteID: nil, folderID: currentFolder?.isTrash == false ? currentFolder?.id : nil)
    }

    private func move(_ note: NoteSummary, to folder: NotesFolder) {
        Task {
            do {
                try await NotesStore.move(note.id, to: folder.id)
                state.appDone(.notes, String(localized: "Nota spostata in «\(folder.name)»"), detail: note.title)
                await reload(keepSelection: true)
            } catch { state.appFailed(.notes, String(localized: "Nota non spostata"), error) }
        }
    }

    private func delete(_ note: NoteSummary) {
        Task {
            do {
                try await NotesStore.delete(note.id)
                if selectedID == note.id { selectedID = nil }
                state.appDone(.notes, String(localized: "Nota eliminata"), detail: note.title)
                await reload()
            } catch { state.appFailed(.notes, String(localized: "Nota non eliminata"), error) }
        }
    }

    private func saveFolder(_ folder: NotesFolder?, name: String, accountID: String) {
        Task {
            do {
                if let folder {
                    try await NotesStore.renameFolder(folder.id, to: name)
                    state.appDone(.notes, String(localized: "Cartella rinominata"), detail: name)
                } else {
                    let id = try await NotesStore.createFolder(name, accountID: accountID)
                    state.appDone(.notes, String(localized: "Cartella creata"), detail: name)
                    await reload()
                    selection = .folder(id)
                    return
                }
                await reload(keepSelection: true)
            } catch { state.appFailed(.notes, folder == nil ? String(localized: "Cartella non creata") : String(localized: "Cartella non rinominata"), error) }
        }
    }

    private func deleteFolder(_ folder: NotesFolder) {
        Task {
            do {
                try await NotesStore.deleteFolder(folder.id)
                if selection == .folder(folder.id) { selection = .all }
                state.appDone(.notes, String(localized: "Cartella eliminata"), detail: folder.name)
                await reload()
            } catch { state.appFailed(.notes, String(localized: "Cartella non eliminata"), error) }
        }
    }
}

private struct FoldersMenu: View {
    @Environment(\.appSourcesVisible) private var sourcesVisible
    let folders: [NotesFolder]
    @Binding var selection: NotesAppView.Folder

    var body: some View {
        if !sourcesVisible {
            Menu {
                Button("Tutte le note") { selection = .all }
                Divider()
                ForEach(folders) { folder in Button("\(folder.name) · \(folder.account)") { selection = .folder(folder.id) } }
            } label: { Image(systemName: "sidebar.left") }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
            .iconHelp(String(localized: "Cartelle"))
        }
    }
}

private struct NoteRow: View {
    let title: String
    let date: Date
    let preview: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Text(date.listStamp).font(.system(size: 12, weight: .medium))
                Text(preview.isEmpty ? String(localized: "Nessun altro testo") : preview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Editor della nota

/// Modifica con formattazione (titoli, grassetto, corsivo, sottolineato, barrato) e salvataggio automatico.
/// Se la nota ha liste, tabelle, disegni o allegati resta da leggere: si modifica nell'app Note.
private struct NoteEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.appTabActive) private var tabActive
    let noteID: String?
    let folderID: String?
    let folders: [NotesFolder]
    let canWrite: Bool
    let onCreated: (String) -> Void
    let onChanged: () -> Void
    let onDeleted: () -> Void

    @State private var id: String?
    @State private var text = NSAttributedString()
    @State private var html = ""
    @State private var editable = true
    @State private var loading = true
    @State private var status = ""
    @State private var dirty = false
    @State private var conflict = false
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmDelete = false
    @State private var controller = RichTextController()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error {
                InlineBanner(symbol: "exclamationmark.triangle", tint: .orange, text: error) {
                    if conflict {
                        Button("Ricarica la nota") { Task { await load() } }
                    }
                }
                .padding(10)
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !editable {
                    InlineBanner(symbol: "list.bullet.rectangle", tint: .blue,
                                 text: String(localized: "Questa nota ha liste, tabelle o allegati: Note li perderebbe se la riscrivessi da qui. Modificala nell'app Note.")) {
                        Button("Apri in Note") { if let id { Task { await NotesService.open(id: id) } } }
                    }
                    .padding(10)
                }
                RichTextEditor(text: $text, editable: editable && canWrite && !conflict, controller: controller,
                               placeholder: id == nil ? String(localized: "Titolo della nuova nota") : nil) {
                    dirty = true
                    scheduleSave()
                }
            }
        }
        .task {
            id = noteID
            await load()
        }
        // Siri AI+ vede la nota aperta: «riassumila», «aggiungi il latte qui», «fai un documento da questa nota».
        .onChange(of: text, initial: true) { _, text in publish(text) }
        .onChange(of: id) { _, _ in publish(text) }
        .task(id: tabActive) {
            // Se la nota cambia in Note (su un altro dispositivo, o nell'app), qui si aggiorna: solo con la scheda davanti,
            // perché ogni controllo passa da AppleScript.
            guard tabActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                if Task.isCancelled { break }
                await checkExternalChange()
            }
        }
        .onDisappear {
            saveTask?.cancel()
            if dirty, !conflict { Task { await save() } }
        }
        .confirmationDialog("Eliminare questa nota?", isPresented: $confirmDelete) {
            Button("Elimina nota", role: .destructive) { delete() }
        } message: {
            Text("Finisce in «Eliminate di recente» di Note: la recuperi da lì per 30 giorni.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach([NoteHTML.Level.title, .heading, .subheading, .body], id: \.self) { level in
                    Button(level.label) { controller.setLevel(level) }
                }
            } label: { Image(systemName: "textformat.size") }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
            .iconHelp(String(localized: "Stile del paragrafo"))
            .disabled(!editable || !canWrite)
            AppIconButton(symbol: "bold", help: String(localized: "Grassetto (⌘B)")) { controller.toggle(.bold) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!editable || !canWrite)
            AppIconButton(symbol: "italic", help: String(localized: "Corsivo (⌘I)")) { controller.toggle(.italic) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!editable || !canWrite)
            AppIconButton(symbol: "underline", help: String(localized: "Sottolineato (⌘U)")) { controller.toggle(.underline) }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!editable || !canWrite)
            AppIconButton(symbol: "strikethrough", help: String(localized: "Barrato")) { controller.toggle(.strikethrough) }
                .disabled(!editable || !canWrite)
            Spacer()
            Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary)
            if let id {
                Menu {
                    ForEach(folders.filter { !$0.isTrash }) { folder in
                        Button("\(folder.name) (\(folder.account))") { move(id, to: folder) }
                    }
                } label: { Image(systemName: "folder") }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
                .iconHelp(String(localized: "Sposta in un'altra cartella"))
                .disabled(!canWrite)
                AppIconButton(symbol: "trash", help: String(localized: "Elimina nota"), role: .destructive) { confirmDelete = true }
                    .disabled(!canWrite)
                AppIconButton(symbol: "sparkle", help: String(localized: "Chiedi a Siri AI+ di questa nota")) {
                    state.send(String(localized: "Riassumi la nota «\(text.string.components(separatedBy: "\n").first ?? "")» e dimmi cosa c'è da fare"))
                }
                AppIconButton(symbol: "arrow.up.forward.app", help: String(localized: "Apri in Note")) { Task { await NotesService.open(id: id) } }
            }
        }
        .disabled(loading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        conflict = false
        error = nil
        guard let id else {
            text = NSAttributedString(string: "", attributes: NoteHTML.attributes(level: .title))
            html = ""
            editable = true
            status = String(localized: "Nuova nota")
            return
        }
        do {
            let snapshot = try await NotesService.snapshot(id: id)
            html = snapshot.html
            editable = NotesStore.canRewrite(snapshot.html)
            text = editable ? NoteHTML.attributed(from: snapshot.html) : NoteHTML.preview(from: snapshot.html)
            dirty = false
            status = editable ? String(localized: "Salvata") : String(localized: "Solo lettura")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard canWrite, editable, !conflict else { return }
        status = String(localized: "Modifiche…")
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(1100))
            if !Task.isCancelled { await save() }
        }
    }

    private func save() async {
        guard dirty, canWrite, editable, !conflict else { return }
        let newHTML = NoteHTML.html(from: text)
        do {
            if let id {
                html = try await NotesStore.save(id: id, html: newHTML, expectedHTML: html)
                dirty = false
                status = String(localized: "Salvata")
                onChanged()
            } else {
                guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                // Il primo paragrafo diventa il titolo della nota.
                let created = try await NotesStore.create(html: newHTML, in: folderID)
                id = created
                html = (try? await NotesService.snapshot(id: created).html) ?? newHTML
                dirty = false
                status = String(localized: "Salvata")
                state.appDone(.notes, String(localized: "Nota creata"), detail: text.string.components(separatedBy: "\n").first ?? "")
                onCreated(created)
            }
        } catch {
            status = String(localized: "Non salvata")
            self.error = error.localizedDescription
            if error.localizedDescription.contains("modificata") { conflict = true }
        }
    }

    private func publish(_ text: NSAttributedString) {
        state.publish(.note(id: id, text: text.string, folder: folders.first { $0.id == folderID }?.name), for: .app(.notes))
    }

    private func checkExternalChange() async {
        guard let id, !dirty, !loading, let snapshot = try? await NotesService.snapshot(id: id), snapshot.html != html else { return }
        html = snapshot.html
        editable = NotesStore.canRewrite(snapshot.html)
        text = editable ? NoteHTML.attributed(from: snapshot.html) : NoteHTML.preview(from: snapshot.html)
        status = String(localized: "Aggiornata da Note")
    }

    private func move(_ id: String, to folder: NotesFolder) {
        Task {
            do {
                if dirty { await save() }
                try await NotesStore.move(id, to: folder.id)
                state.appDone(.notes, String(localized: "Nota spostata in «\(folder.name)»"))
                onChanged()
            } catch { state.appFailed(.notes, String(localized: "Nota non spostata"), error) }
        }
    }

    private func delete() {
        guard let id else { onDeleted(); return }
        Task {
            do {
                saveTask?.cancel()
                dirty = false
                try await NotesStore.delete(id)
                state.appDone(.notes, String(localized: "Nota eliminata"))
                onDeleted()
            } catch { state.appFailed(.notes, String(localized: "Nota non eliminata"), error) }
        }
    }
}

// MARK: - Cartella nuova o rinominata

private struct FolderEditor: View {
    let folder: NotesFolder?
    let accounts: [(id: String, name: String)]
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var accountID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(folder == nil ? String(localized: "Nuova cartella") : String(localized: "Rinomina cartella")).font(.system(size: 15, weight: .semibold))
            TextField("Nome", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            if folder == nil, accounts.count > 1 {
                Picker("Account", selection: $accountID) {
                    ForEach(accounts, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            HStack {
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(folder == nil ? String(localized: "Crea") : String(localized: "Rinomina"), action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            name = folder?.name ?? ""
            accountID = folder?.accountID ?? accounts.first?.id ?? ""
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(name.trimmingCharacters(in: .whitespaces), accountID)
        dismiss()
    }
}

// MARK: - Testo con formattazione

@MainActor
final class RichTextController {
    enum Trait { case bold, italic, underline, strikethrough }
    weak var textView: NSTextView?

    /// Stile del paragrafo (titolo, intestazione, sottointestazione, corpo) per i paragrafi selezionati.
    func setLevel(_ level: NoteHTML.Level) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = (view.string as NSString).paragraphRange(for: view.selectedRange())
        guard view.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        let base = NoteHTML.attributes(level: level)
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            let italic = (value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true
            var font = NSFont.systemFont(ofSize: level.size, weight: level.weight)
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            storage.addAttribute(.font, value: font, range: run)
        }
        if range.length > 0 { storage.addAttribute(.paragraphStyle, value: base[.paragraphStyle]!, range: range) }
        storage.endEditing()
        view.typingAttributes = base
        view.didChangeText()
    }

    func toggle(_ trait: Trait) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        guard range.length > 0 else {
            // Senza selezione cambia come si scrive da qui in poi.
            var attributes = view.typingAttributes
            apply(trait, to: &attributes, on: !has(trait, attributes))
            view.typingAttributes = attributes
            return
        }
        var all = true
        storage.enumerateAttributes(in: range) { attributes, _, _ in if !has(trait, attributes) { all = false } }
        guard view.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, run, _ in
            var updated = attributes
            apply(trait, to: &updated, on: !all)
            storage.setAttributes(updated, range: run)
        }
        storage.endEditing()
        view.didChangeText()
    }

    private func has(_ trait: Trait, _ attributes: [NSAttributedString.Key: Any]) -> Bool {
        let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        switch trait {
        case .bold: return traits.contains(.bold)
        case .italic: return traits.contains(.italic)
        case .underline: return (attributes[.underlineStyle] as? Int ?? 0) != 0
        case .strikethrough: return (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        }
    }

    private func apply(_ trait: Trait, to attributes: inout [NSAttributedString.Key: Any], on: Bool) {
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: NoteHTML.Level.body.size)
        switch trait {
        case .bold:
            attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: on ? .boldFontMask : .unboldFontMask)
        case .italic:
            attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: on ? .italicFontMask : .unitalicFontMask)
        case .underline:
            attributes[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil
        case .strikethrough:
            attributes[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : nil
        }
    }
}

private struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    let editable: Bool
    let controller: RichTextController
    var placeholder: String?
    let onEdit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = true
        view.allowsUndo = true
        view.importsGraphics = false
        view.usesFontPanel = false
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.textContainerInset = NSSize(width: 24, height: 20)
        view.drawsBackground = false
        scroll.drawsBackground = false
        view.textStorage?.setAttributedString(text)
        view.typingAttributes = NoteHTML.attributes(level: text.length == 0 ? .title : .body)
        view.isEditable = editable && context.environment.isEnabled
        view.setAccessibilityLabel(placeholder ?? String(localized: "Testo della nota"))
        controller.textView = view
        context.coordinator.placeholder(view, show: text.length == 0)
        if editable, text.length == 0 { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        controller.textView = view
        // In una scheda dietro (o con le app nascoste) la nota non si modifica: quello che scrivi non finisce qui per sbaglio.
        let enabled = context.environment.isEnabled
        view.isEditable = editable && enabled
        if !enabled, view.window?.firstResponder === view { DispatchQueue.main.async { view.window?.makeFirstResponder(nil) } }
        if !context.coordinator.editing, view.attributedString() != text {
            view.textStorage?.setAttributedString(text)
        }
        context.coordinator.placeholder(view, show: text.length == 0)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var editing = false
        private var hint: NSTextField?

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            editing = true
            parent.text = view.attributedString()
            editing = false
            // Dopo il titolo si scrive in corpo normale.
            if view.string.count > 0, view.selectedRange().location > 0 {
                let string = view.string as NSString
                let paragraph = string.paragraphRange(for: NSRange(location: max(0, view.selectedRange().location - 1), length: 0))
                if paragraph.location + paragraph.length == view.selectedRange().location, string.substring(with: paragraph).hasSuffix("\n") {
                    view.typingAttributes = NoteHTML.attributes(level: .body)
                }
            }
            placeholder(view, show: view.string.isEmpty)
            parent.onEdit()
        }

        @MainActor func placeholder(_ view: NSTextView, show: Bool) {
            guard let text = parent.placeholder else { hint?.removeFromSuperview(); hint = nil; return }
            if show, hint == nil {
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: NoteHTML.Level.title.size, weight: .bold)
                label.textColor = .tertiaryLabelColor
                label.frame.origin = NSPoint(x: 29, y: 20)
                label.sizeToFit()
                view.addSubview(label)
                hint = label
            } else if !show {
                hint?.removeFromSuperview()
                hint = nil
            }
        }
    }
}
