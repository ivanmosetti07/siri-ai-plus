import SiriCore
import SwiftUI

// MARK: - Promemoria

struct RemindersAppView: View {
    @Environment(AppState.self) private var state

    enum Smart: String, CaseIterable {
        case today, scheduled, all, priority, completed

        var title: String {
            switch self {
            case .today: String(localized: "Oggi")
            case .scheduled: String(localized: "Programmati")
            case .all: String(localized: "Tutti")
            case .priority: String(localized: "Con priorità")
            case .completed: String(localized: "Completati")
            }
        }

        var symbol: String {
            switch self {
            case .today: "calendar"
            case .scheduled: "calendar.badge.clock"
            case .all: "tray.fill"
            case .priority: "exclamationmark"
            case .completed: "checkmark"
            }
        }

        var colors: [Color] {
            switch self {
            case .today: Hue.blue
            case .scheduled: Hue.red
            case .all: [Color(hex: 0x5B6270), Color(hex: 0x3A3F48)]
            case .priority: Hue.orange
            case .completed: Hue.gray
            }
        }
    }

    enum Selection: Hashable { case smart(Smart), list(String) }

    @State private var selection = Selection.smart(.today)
    @State private var lists = [ReminderListInfo]()
    @State private var open = [ReminderEntry]()
    @State private var done = [ReminderEntry]()
    @State private var showCompleted = false
    @State private var selectedID: String?
    @State private var search = ""
    @State private var newTitle = ""
    @State private var listSheet: ListSheet?
    @State private var deletingList: ReminderListInfo?
    @FocusState private var addFocused: Bool

    struct ListSheet: Identifiable {
        var id: String { list?.id ?? "nuova" }
        var list: ReminderListInfo?
    }

    /// Liste dello spazio in uso (tutte se lo spazio non ne sceglie).
    private var spaceLists: [ReminderListInfo] {
        guard let names = SpaceScope.current.reminderLists else { return lists }
        let filtered = lists.filter { names.contains($0.title) }
        return filtered.isEmpty ? lists : filtered
    }

    private var otherLists: [ReminderListInfo] { lists.filter { list in !spaceLists.contains { $0.id == list.id } } }
    private var spaceIDs: Set<String> { Set(spaceLists.map(\.id)) }

    private func items(for selection: Selection) -> [ReminderEntry] {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now))!
        let scoped = open.filter { spaceIDs.contains($0.listID) }
        var result: [ReminderEntry]
        switch selection {
        case .smart(.today): result = scoped.filter { ($0.due ?? .distantFuture) < tomorrow }
        case .smart(.scheduled): result = scoped.filter { $0.due != nil }
        case .smart(.all): result = scoped
        case .smart(.priority): result = scoped.filter { $0.priority != .none }
        case .smart(.completed): result = done.filter { spaceIDs.contains($0.listID) }
        case .list(let id): result = open.filter { $0.listID == id } + (showCompleted ? done.filter { $0.listID == id } : [])
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query) }
        }
        if case .smart(.completed) = selection {
            return result.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        }
        return result.sorted { a, b in
            if a.isCompleted != b.isCompleted { return !a.isCompleted }
            return (a.due ?? .distantFuture, a.priority == .none ? 1 : 0, a.created ?? .distantPast)
                < (b.due ?? .distantFuture, b.priority == .none ? 1 : 0, b.created ?? .distantPast)
        }
    }

    private var selectedEntry: ReminderEntry? { selectedID.flatMap { id in (open + done).first { $0.id == id } } }

    private var currentList: ReminderListInfo? {
        if case .list(let id) = selection { return lists.first { $0.id == id } }
        return nil
    }

    private var heading: (String, Color) {
        switch selection {
        case .smart(let smart): (smart.title, smart.colors.last ?? .primary)
        case .list: (currentList?.title ?? String(localized: "Lista"), currentList.map { Color($0.color) } ?? .accentColor)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(source: .reminders, title: String(localized: "Promemoria"), subtitle: subtitle, search: $search, searchPrompt: String(localized: "Cerca promemoria"),
                      onRefresh: { Task { await reload() } }) {
                AppIconButton(symbol: "plus", help: String(localized: "Nuovo promemoria"), prominent: true) { addFocused = true }
                    .disabled(!state.canWrite(.reminders))
            }
            Divider()
            AppSplit(sourcesWidth: 232, showInspector: selectedEntry != nil) {
                sidebar
            } main: {
                listColumn
            } inspector: {
                if let entry = selectedEntry {
                    ReminderInspector(entry: entry, lists: lists.filter(\.writable), canWrite: state.canWrite(.reminders),
                                      onChange: { Task { await reload() } }, onClose: { selectedID = nil })
                        .id(entry.id)
                }
            }
        }
        .task(id: state.storeRevision) { await reload() }
        .onChange(of: selection) { _, value in
            selectedID = nil
            if case .smart(.completed) = value, done.isEmpty { Task { await loadCompleted() } }
        }
        .onChange(of: showCompleted) { _, value in if value { Task { await loadCompleted() } } }
        // Siri AI+ vede il promemoria selezionato («completalo», «rimandalo a domani») o la lista mostrata.
        .onChange(of: selectedID, initial: true) { _, _ in publishScreen() }
        .onChange(of: open) { _, _ in publishScreen() }
        .onChange(of: selection) { _, _ in publishScreen() }
        .sheet(item: $listSheet) { sheet in
            ReminderListEditor(list: sheet.list) { title, color in saveList(sheet.list, title: title, color: color) }
        }
        .confirmationDialog("Eliminare la lista «\(deletingList?.title ?? "")»?", isPresented: Binding(get: { deletingList != nil }, set: { if !$0 { deletingList = nil } }),
                            presenting: deletingList) { list in
            Button("Elimina lista e promemoria", role: .destructive) { deleteList(list) }
        } message: { list in
            let count = open.filter { $0.listID == list.id }.count
            Text("Verranno eliminati anche \(count == 1 ? String(localized: "1 promemoria da fare") : String(localized: "\(count) promemoria da fare")) e quelli completati, su tutti i dispositivi.")
        }
    }

    private var subtitle: String {
        let today = items(for: .smart(.today)).count
        return today == 0 ? String(localized: "Niente in scadenza oggi") : today == 1 ? String(localized: "1 promemoria per oggi") : String(localized: "\(today) promemoria per oggi")
    }

    // MARK: Colonna delle liste

    private var sidebar: some View {
        List(selection: Binding(get: { selection }, set: { if let value = $0 { selection = value } })) {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Smart.allCases, id: \.self) { smart in smartTile(smart) }
                }
                .padding(.vertical, 4)
            }
            .selectionDisabled()
            Section(SpaceScope.current.reminderLists == nil ? String(localized: "Le mie liste") : String(localized: "Liste di \(state.space.label)")) {
                ForEach(spaceLists) { list in listRow(list) }
            }
            if !otherLists.isEmpty {
                Section("Altre liste") {
                    ForEach(otherLists) { list in listRow(list) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button { listSheet = ListSheet(list: nil) } label: {
                Label("Aggiungi lista", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .disabled(!state.canWrite(.reminders))
        }
    }

    private func smartTile(_ smart: Smart) -> some View {
        let selected = selection == .smart(smart)
        return Button { selection = .smart(smart) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    IconBadge(symbol: smart.symbol, colors: smart.colors, size: 26)
                    Spacer()
                    if smart != .completed {
                        Text("\(items(for: .smart(smart)).count)").font(.system(size: 19, weight: .bold)).monospacedDigit()
                    }
                }
                Text(smart.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(selected ? .white : .secondary)
            }
            .foregroundStyle(selected ? .white : .primary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(LinearGradient(colors: smart.colors, startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.primary.opacity(0.06)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func listRow(_ list: ReminderListInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color(list.color), in: Circle())
            Text(list.title).lineLimit(1)
            Spacer()
            Text("\(open.filter { $0.listID == list.id }.count)").foregroundStyle(.secondary).monospacedDigit()
        }
        .tag(Selection.list(list.id))
        .contextMenu {
            Button("Rinomina e colore…") { listSheet = ListSheet(list: list) }.disabled(!list.writable || !state.canWrite(.reminders))
            Divider()
            Button("Elimina lista…", role: .destructive) { deletingList = list }.disabled(!list.writable || !state.canWrite(.reminders))
        }
    }

    // MARK: Elenco

    private var listColumn: some View {
        let entries = items(for: selection)
        return VStack(spacing: 0) {
            ListHeading(title: heading.0, tint: heading.1, count: "\(entries.filter { !$0.isCompleted }.count)") {
                ListsMenu(selection: $selection, lists: lists)
                if case .list = selection {
                    Button { showCompleted.toggle() } label: {
                        Image(systemName: showCompleted ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .iconHelp(showCompleted ? String(localized: "Nascondi i completati") : String(localized: "Mostra i completati"))
                }
            }
            if entries.isEmpty {
                AppPlaceholder(symbol: selection == .smart(.completed) ? "checkmark.circle" : "sparkles",
                               title: search.isEmpty ? (selection == .smart(.completed) ? String(localized: "Nessun promemoria completato") : String(localized: "Tutto fatto")) : String(localized: "Nessun risultato"),
                               message: search.isEmpty && selection != .smart(.completed) ? String(localized: "Scrivi qui sotto per aggiungere un promemoria.") : nil)
            } else {
                List(selection: $selectedID) {
                    ForEach(groups(entries), id: \.title) { group in
                        Section {
                            ForEach(group.items) { entry in
                                ReminderRow(entry: entry, showsList: !isListSelection, canWrite: state.canWrite(.reminders),
                                            onToggle: { toggle(entry) }, onRename: { rename(entry, $0) })
                                    .tag(entry.id)
                                    .contextMenu { rowMenu(entry) }
                            }
                        } header: {
                            if !group.title.isEmpty {
                                Text(group.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(group.tint)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onDeleteCommand { if let id = selectedID, let entry = (open + done).first(where: { $0.id == id }) { delete(entry) } }
            }
            if state.canWrite(.reminders), selection != .smart(.completed) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(heading.1).font(.system(size: 17))
                    TextField("Nuovo promemoria in «\(targetList?.title ?? "")»", text: $newTitle)
                        .textFieldStyle(.plain)
                        .focused($addFocused)
                        .onSubmit(add)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
    }

    private var isListSelection: Bool { if case .list = selection { true } else { false } }

    private struct Group { let title: String; let tint: Color; let items: [ReminderEntry] }

    /// Programmati per giorno, Tutti per lista, Completati per data; nelle liste un solo gruppo.
    private func publishScreen() {
        if let id = selectedID, let entry = (open + done).first(where: { $0.id == id }) {
            state.publish(.reminder(entry), for: .app(.reminders))
        } else {
            state.publish(.reminders(list: heading.0, entries: items(for: selection)), for: .app(.reminders))
        }
    }

    private func groups(_ entries: [ReminderEntry]) -> [Group] {
        let cal = Calendar.current
        switch selection {
        case .smart(.scheduled):
            let overdue = entries.filter(\.isOverdue)
            var result = overdue.isEmpty ? [] : [Group(title: String(localized: "Scaduti"), tint: .red, items: overdue)]
            let upcoming = Dictionary(grouping: entries.filter { !$0.isOverdue }) { cal.startOfDay(for: $0.due ?? .now) }
            for (day, items) in upcoming.sorted(by: { $0.key < $1.key }) {
                let title = cal.isDateInToday(day) ? String(localized: "Oggi") : cal.isDateInTomorrow(day) ? String(localized: "Domani")
                    : day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Dates.locale)).capitalized
                result.append(Group(title: title, tint: .primary, items: items))
            }
            return result
        case .smart(.all), .smart(.priority), .smart(.today):
            guard selection == .smart(.all) else { return [Group(title: "", tint: .primary, items: entries)] }
            return lists.compactMap { list in
                let items = entries.filter { $0.listID == list.id }
                return items.isEmpty ? nil : Group(title: list.title, tint: Color(list.color), items: items)
            }
        case .smart(.completed):
            let byDay = Dictionary(grouping: entries) { cal.startOfDay(for: $0.completedAt ?? .distantPast) }
            return byDay.sorted { $0.key > $1.key }.map { day, items in
                Group(title: cal.isDateInToday(day) ? String(localized: "Oggi") : cal.isDateInYesterday(day) ? String(localized: "Ieri")
                      : day.formatted(.dateTime.day().month(.wide).year().locale(Dates.locale)), tint: .secondary, items: items)
            }
        case .list:
            return [Group(title: "", tint: .primary, items: entries)]
        }
    }

    @ViewBuilder private func rowMenu(_ entry: ReminderEntry) -> some View {
        Button(entry.isCompleted ? String(localized: "Segna come da fare") : String(localized: "Segna come completato")) { toggle(entry) }
        Menu("Priorità") {
            ForEach(ReminderEntry.Priority.allCases, id: \.self) { priority in
                Button(priority.label) { update(entry) { $0.priority = priority } }
            }
        }
        Menu("Scadenza") {
            Button("Oggi") { update(entry) { $0.due = Calendar.current.startOfDay(for: .now); $0.dueHasTime = false } }
            Button("Domani") { update(entry) { $0.due = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)); $0.dueHasTime = false } }
            Button("Il prossimo fine settimana") {
                let saturday = Calendar.current.nextDate(after: .now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime)
                update(entry) { $0.due = saturday.map { Calendar.current.startOfDay(for: $0) }; $0.dueHasTime = false }
            }
            Divider()
            Button("Nessuna scadenza") { update(entry) { $0.due = nil; $0.dueHasTime = false } }
        }
        Menu("Sposta in") {
            ForEach(lists.filter(\.writable)) { list in
                Button(list.title) { update(entry) { $0.listID = list.id } }.disabled(list.id == entry.listID)
            }
        }
        Divider()
        Button("Elimina", role: .destructive) { delete(entry) }
    }

    // MARK: Azioni

    private var targetList: ReminderListInfo? {
        if let currentList, currentList.writable { return currentList }
        let id = ReminderStore.defaultListID
        return lists.first { $0.id == id } ?? spaceLists.first(where: \.writable)
    }

    private func reload() async {
        lists = ReminderStore.lists()
        open = await ReminderStore.fetch(completed: false, listIDs: nil)
        if showCompleted || selection == .smart(.completed) { await loadCompleted() }
        if AppTesting.selectFirst, selectedID == nil { selectedID = items(for: selection).first?.id }
    }

    private func loadCompleted() async {
        done = await ReminderStore.fetch(completed: true, listIDs: nil)
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, let list = targetList else { return }
        var entry = ReminderEntry(title: title, listID: list.id)
        if selection == .smart(.today) || selection == .smart(.scheduled) { entry.due = Calendar.current.startOfDay(for: .now) }
        if selection == .smart(.priority) { entry.priority = .high }
        do {
            let id = try ReminderStore.save(entry)
            newTitle = ""
            state.log(icon: "source:reminders", title: String(localized: "Promemoria aggiunto"), detail: "\(title) · \(list.title)", status: .done)
            Task {
                await reload()
                selectedID = id
                addFocused = true
            }
        } catch {
            state.appFailed(.reminders, String(localized: "Promemoria non aggiunto"), error)
        }
    }

    private func toggle(_ entry: ReminderEntry) {
        do {
            try ReminderStore.setCompleted(entry.id, !entry.isCompleted)
            state.log(icon: "source:reminders", title: entry.isCompleted ? String(localized: "Promemoria riaperto") : String(localized: "Promemoria completato"), detail: entry.title, status: .done)
            Task {
                try? await Task.sleep(for: .milliseconds(entry.isCompleted ? 0 : 450))
                await reload()
            }
        } catch {
            state.appFailed(.reminders, String(localized: "Promemoria non aggiornato"), error)
        }
    }

    private func rename(_ entry: ReminderEntry, _ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != entry.title else { return }
        update(entry) { $0.title = trimmed }
    }

    private func update(_ entry: ReminderEntry, _ change: (inout ReminderEntry) -> Void) {
        var updated = entry
        change(&updated)
        do {
            try ReminderStore.save(updated)
            Task { await reload() }
        } catch {
            state.appFailed(.reminders, String(localized: "Promemoria non aggiornato"), error)
        }
    }

    private func delete(_ entry: ReminderEntry) {
        do {
            try ReminderStore.delete(entry.id)
            if selectedID == entry.id { selectedID = nil }
            state.appDone(.reminders, String(localized: "Promemoria eliminato"), detail: entry.title)
            Task { await reload() }
        } catch {
            state.appFailed(.reminders, String(localized: "Promemoria non eliminato"), error)
        }
    }

    private func saveList(_ list: ReminderListInfo?, title: String, color: RGB) {
        do {
            if let list {
                try ReminderStore.updateList(list.id, title: title, color: color)
                state.appDone(.reminders, String(localized: "Lista aggiornata"), detail: title)
            } else {
                let id = try ReminderStore.createList(title: title, color: color)
                state.appDone(.reminders, String(localized: "Lista creata"), detail: title)
                selection = .list(id)
            }
            Task { await reload() }
        } catch {
            state.appFailed(.reminders, list == nil ? String(localized: "Lista non creata") : String(localized: "Lista non aggiornata"), error)
        }
    }

    private func deleteList(_ list: ReminderListInfo) {
        do {
            try ReminderStore.deleteList(list.id)
            if selection == .list(list.id) { selection = .smart(.today) }
            state.appDone(.reminders, String(localized: "Lista eliminata"), detail: list.title)
            Task { await reload() }
        } catch {
            state.appFailed(.reminders, String(localized: "Lista non eliminata"), error)
        }
    }
}

/// Al posto della colonna delle liste quando la finestra è stretta.
private struct ListsMenu: View {
    @Environment(\.appSourcesVisible) private var sourcesVisible
    @Binding var selection: RemindersAppView.Selection
    let lists: [ReminderListInfo]

    var body: some View {
        if !sourcesVisible {
            Menu {
                ForEach(RemindersAppView.Smart.allCases, id: \.self) { smart in
                    Button(smart.title) { selection = .smart(smart) }
                }
                Divider()
                ForEach(lists) { list in Button(list.title) { selection = .list(list.id) } }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .iconHelp(String(localized: "Liste"))
        }
    }
}

// MARK: - Riga

private struct ReminderRow: View {
    let entry: ReminderEntry
    let showsList: Bool
    let canWrite: Bool
    let onToggle: () -> Void
    let onRename: (String) -> Void
    @State private var title = ""
    @State private var checked = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                withAnimation(DS.Motion.quick) { checked.toggle() }
                onToggle()
            } label: {
                Image(systemName: checked ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(checked ? Color(entry.color) : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canWrite)
            .iconHelp(entry.isCompleted ? String(localized: "Segna come da fare") : String(localized: "Segna come completato"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if entry.priority != .none {
                        Text(entry.priority.marks).font(.system(size: 13, weight: .bold)).foregroundStyle(Color(entry.color))
                    }
                    TextField("Promemoria", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .foregroundStyle(checked ? .secondary : .primary)
                        .focused($editing)
                        .disabled(!canWrite)
                        .onSubmit { onRename(title) }
                        .onChange(of: editing) { _, focused in if !focused { onRename(title) } }
                }
                if !entry.notes.isEmpty {
                    Text(entry.notes).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                let details = [dueText, showsList ? entry.listTitle : nil, entry.isRecurring ? String(localized: "si ripete") : nil].compactMap { $0 }
                if !details.isEmpty || !entry.url.isEmpty {
                    HStack(spacing: 6) {
                        if let dueText {
                            Text(dueText).foregroundStyle(entry.isOverdue ? .red : .secondary)
                        }
                        if showsList { Text(entry.listTitle).foregroundStyle(Color(entry.color)) }
                        if entry.isRecurring { Image(systemName: "repeat").foregroundStyle(.secondary) }
                        if !entry.url.isEmpty { Image(systemName: "link").foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .onAppear { title = entry.title; checked = entry.isCompleted }
        .onChange(of: entry) { _, value in if !editing { title = value.title }; checked = value.isCompleted }
    }

    private var dueText: String? {
        guard let due = entry.due else { return nil }
        if entry.isCompleted, let completed = entry.completedAt { return String(localized: "Completato \(Dates.friendly(completed))") }
        return Dates.friendly(due, time: entry.dueHasTime)
    }
}

// MARK: - Dettaglio del promemoria

private struct ReminderInspector: View {
    @Environment(AppState.self) private var state
    let entry: ReminderEntry
    let lists: [ReminderListInfo]
    let canWrite: Bool
    let onChange: () -> Void
    let onClose: () -> Void
    @State private var draft: ReminderEntry
    @State private var confirmDelete = false

    init(entry: ReminderEntry, lists: [ReminderListInfo], canWrite: Bool, onChange: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.entry = entry; self.lists = lists; self.canWrite = canWrite; self.onChange = onChange; self.onClose = onClose
        _draft = State(initialValue: entry)
    }

    private var dirty: Bool { draft != entry }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Dettagli").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.borderless).iconHelp(String(localized: "Chiudi"))
                    }
                    TextField("Titolo", text: $draft.title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .bold))
                    InspectorGroup(title: String(localized: "Note")) {
                        TextEditor(text: $draft.notes)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 70, maxHeight: 200)
                            .padding(.vertical, 6)
                        Divider().opacity(0.6)
                        TextField("Link", text: $draft.url).textFieldStyle(.plain).font(.system(size: 13)).padding(.vertical, 8)
                    }
                    InspectorGroup(title: String(localized: "Scadenza")) {
                        InspectorRow(label: String(localized: "Data")) {
                            Toggle("", isOn: Binding(get: { draft.due != nil }, set: { on in
                                draft.due = on ? (draft.due ?? Calendar.current.startOfDay(for: .now)) : nil
                                if !on { draft.dueHasTime = false }
                            }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        if draft.due != nil {
                            InspectorRow(label: String(localized: "Giorno")) {
                                DatePicker("", selection: Binding(get: { draft.due ?? .now }, set: { draft.due = $0 }), displayedComponents: [.date])
                                    .labelsHidden().datePickerStyle(.field)
                            }
                            InspectorRow(label: String(localized: "Ora"), divider: draft.dueHasTime) {
                                Toggle("", isOn: Binding(get: { draft.dueHasTime }, set: { on in
                                    draft.dueHasTime = on
                                    if on, let due = draft.due, Calendar.current.component(.hour, from: due) == 0 {
                                        draft.due = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due)
                                    }
                                }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            if draft.dueHasTime {
                                InspectorRow(label: String(localized: "Alle"), divider: false) {
                                    DatePicker("", selection: Binding(get: { draft.due ?? .now }, set: { draft.due = $0 }), displayedComponents: [.hourAndMinute])
                                        .labelsHidden().datePickerStyle(.field)
                                }
                            }
                        }
                    }
                    InspectorGroup {
                        InspectorRow(label: String(localized: "Priorità")) {
                            Picker("", selection: $draft.priority) {
                                ForEach(ReminderEntry.Priority.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        InspectorRow(label: String(localized: "Lista"), divider: false) {
                            Picker("", selection: $draft.listID) {
                                ForEach(lists) { list in
                                    Label { Text(list.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(list.color)) }.tag(list.id)
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                    if let created = entry.created {
                        Text("Creato \(Dates.friendly(created))").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    }
                    Button { state.send(String(localized: "Aiutami con il promemoria «\(entry.title)»: dividilo in passi e dimmi da dove partire")) } label: {
                        Label("Chiedi a Siri AI+", systemImage: "sparkle")
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 13))
                }
                .padding(16)
                .disabled(!canWrite)
            }
            InspectorFooter {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .iconHelp(String(localized: "Elimina promemoria"))
                    .disabled(!canWrite)
            } trailing: {
                if dirty { Button("Annulla modifiche") { draft = entry } }
                Button("Salva", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!canWrite || !dirty)
            }
        }
        .confirmationDialog("Eliminare «\(entry.title)»?", isPresented: $confirmDelete) {
            Button("Elimina promemoria", role: .destructive) {
                do {
                    try ReminderStore.delete(entry.id)
                    state.appDone(.reminders, String(localized: "Promemoria eliminato"), detail: entry.title)
                    onClose()
                    onChange()
                } catch { state.appFailed(.reminders, String(localized: "Promemoria non eliminato"), error) }
            }
        }
    }

    private func save() {
        do {
            try ReminderStore.save(draft)
            state.appDone(.reminders, String(localized: "Promemoria salvato"), detail: draft.title)
            onChange()
        } catch {
            state.appFailed(.reminders, String(localized: "Promemoria non salvato"), error)
        }
    }
}

// MARK: - Nuova lista / modifica lista

private struct ReminderListEditor: View {
    let list: ReminderListInfo?
    let onSave: (String, RGB) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var color = ReminderListEditor.palette[0]

    static let palette: [RGB] = [
        RGB(red: 1, green: 0.23, blue: 0.19), RGB(red: 1, green: 0.58, blue: 0), RGB(red: 1, green: 0.8, blue: 0),
        RGB(red: 0.2, green: 0.78, blue: 0.35), RGB(red: 0.35, green: 0.78, blue: 0.98), RGB(red: 0, green: 0.48, blue: 1),
        RGB(red: 0.35, green: 0.34, blue: 0.84), RGB(red: 1, green: 0.18, blue: 0.33), RGB(red: 0.69, green: 0.32, blue: 0.87),
        RGB(red: 0.64, green: 0.52, blue: 0.37), RGB(red: 0.56, green: 0.56, blue: 0.58),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "list.bullet")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color(color), in: Circle())
                .shadow(color: Color(color).opacity(0.4), radius: 10, y: 4)
            TextField("Nome della lista", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(width: 280)
                .onSubmit(save)
            HStack(spacing: 10) {
                ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, option in
                    Button { color = option } label: {
                        Circle().fill(Color(option)).frame(width: 22, height: 22)
                            .overlay { if option == color { Circle().strokeBorder(.primary.opacity(0.6), lineWidth: 2).padding(-4) } }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(list == nil ? String(localized: "Crea lista") : String(localized: "Salva"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            title = list?.title ?? ""
            color = list?.color ?? Self.palette[5]
        }
    }

    private func save() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(title, color)
        dismiss()
    }
}
