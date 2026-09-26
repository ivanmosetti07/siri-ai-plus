import AppKit
import SiriCore
import SwiftUI

// MARK: - Contatti

struct ContactsAppView: View {
    @Environment(AppState.self) private var state
    @Environment(\.appTabActive) private var tabActive

    enum Scope: Hashable { case all, group(String) }

    @State private var scope = Scope.all
    @State private var groups = [ContactGroup]()
    @State private var contacts = [ContactSummary]()
    @State private var selectedID: String?
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    /// Contatto nuovo in scrittura (non ancora salvato).
    @State private var creating = false
    @State private var groupSheet: GroupSheet?
    @State private var deletingGroup: ContactGroup?

    struct GroupSheet: Identifiable { var id: String { group?.id ?? "nuovo" }; var group: ContactGroup? }

    private var visible: [ContactSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return contacts }
        return contacts.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.organization.localizedCaseInsensitiveContains(query)
                || $0.detail.filter(\.isNumber).contains(query.filter(\.isNumber).isEmpty ? "\u{0}" : query.filter(\.isNumber))
                || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(source: .contacts, title: "Contatti", subtitle: contacts.count == 1 ? "1 contatto" : "\(contacts.count) contatti",
                      search: $search, searchPrompt: "Cerca nome, azienda, numero", onRefresh: reload) {
                AppIconButton(symbol: "plus", help: "Nuovo contatto", prominent: true) { selectedID = nil; creating = true }
                    .disabled(!state.canWrite(.contacts))
            }
            Divider()
            if let error, contacts.isEmpty {
                AccessNotice(symbol: "person.crop.circle.badge.exclamationmark", title: "Contatti non disponibili", message: error,
                             primary: ("Riprova", reload), secondary: ("Permessi", { PermissionCenter.openSettings(.contacts) }))
            } else {
                AppColumns(sourcesWidth: 200, itemsWidth: 290) {
                    groupList
                } items: {
                    contactList
                } detail: {
                    if creating {
                        ContactDetail(contactID: nil, groups: groups, canWrite: state.canWrite(.contacts),
                                      onSaved: { id in creating = false; reload(); selectedID = id },
                                      onDeleted: { creating = false }, onCancelNew: { creating = false })
                            .id("nuovo")
                    } else if let id = selectedID {
                        ContactDetail(contactID: id, groups: groups, canWrite: state.canWrite(.contacts),
                                      onSaved: { _ in reload() }, onDeleted: { selectedID = nil; reload() }, onCancelNew: {})
                            .id(id)
                    } else {
                        AppPlaceholder(symbol: "person.crop.circle", title: "Nessun contatto selezionato",
                                       message: "Scegli un contatto per chiamare, scrivere o modificarlo, oppure creane uno nuovo.")
                    }
                }
            }
        }
        .task { reload() }
        .onChange(of: tabActive) { _, active in if active { reload() } }
        .onChange(of: scope) { _, _ in selectedID = nil; reload() }
        // Senza contatto selezionato Siri AI+ sa solo quanti sono (la scheda aperta la descrive il dettaglio).
        .onChange(of: selectedID, initial: true) { _, id in
            if id == nil {
                state.publish(ScreenItem(app: "Contatti", kind: .overview, title: "rubrica", details: "\(contacts.count) contatti",
                                         nouns: ["contatti", "rubrica", "persone"]), for: .app(.contacts))
            }
        }
        .onChange(of: selectedID) { _, value in if value != nil { creating = false } }
        .sheet(item: $groupSheet) { sheet in
            GroupEditor(group: sheet.group) { name in saveGroup(sheet.group, name: name) }
        }
        .confirmationDialog("Eliminare il gruppo «\(deletingGroup?.name ?? "")»?", isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
                            presenting: deletingGroup) { group in
            Button("Elimina gruppo", role: .destructive) { deleteGroup(group) }
        } message: { _ in
            Text("I contatti del gruppo restano in Contatti.")
        }
    }

    // MARK: Gruppi

    private var groupList: some View {
        List(selection: Binding(get: { scope }, set: { if let value = $0 { scope = value } })) {
            Section {
                SourceRowLabel(title: "Tutti i contatti", symbol: "person.2", tint: .accentColor).tag(Scope.all)
            }
            if !groups.isEmpty {
                Section("Gruppi") {
                    ForEach(groups) { group in
                        SourceRowLabel(title: group.name, symbol: "person.3", tint: .secondary)
                            .tag(Scope.group(group.id))
                            .contextMenu {
                                Button("Rinomina…") { groupSheet = GroupSheet(group: group) }
                                Button("Elimina gruppo…", role: .destructive) { deletingGroup = group }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button { groupSheet = GroupSheet(group: nil) } label: {
                Label("Nuovo gruppo", systemImage: "person.3.sequence").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .disabled(!state.canWrite(.contacts))
        }
    }

    // MARK: Elenco

    private var sections: [(letter: String, contacts: [ContactSummary])] {
        var order: [String] = []
        var map: [String: [ContactSummary]] = [:]
        for contact in visible {
            let first = contact.sortKey.first.map { String($0).uppercased() } ?? "#"
            let letter = first.first?.isLetter == true ? first : "#"
            if map[letter] == nil { order.append(letter) }
            map[letter, default: []].append(contact)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private var contactList: some View {
        VStack(spacing: 0) {
            ListHeading(title: groupTitle, count: "\(visible.count)") {
                GroupsMenu(groups: groups, scope: $scope)
            }
            if loading && contacts.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty && !creating {
                AppPlaceholder(symbol: search.isEmpty ? "person.crop.circle" : "magnifyingglass", title: search.isEmpty ? "Nessun contatto" : "Nessun risultato")
            } else {
                List(selection: $selectedID) {
                    if creating {
                        HStack(spacing: 10) {
                            InitialsAvatar(name: "?", size: 30)
                            Text("Nuovo contatto").font(.system(size: 13.5, weight: .semibold))
                        }
                        .listRowBackground(Color.accentColor.opacity(0.15))
                    }
                    ForEach(sections, id: \.letter) { section in
                        Section(section.letter) {
                            ForEach(section.contacts) { contact in
                                HStack(spacing: 10) {
                                    InitialsAvatar(name: contact.name, size: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(contact.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                        if !contact.organization.isEmpty {
                                            Text(contact.organization).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                                .tag(contact.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var groupTitle: String {
        if case .group(let id) = scope { return groups.first { $0.id == id }?.name ?? "Gruppo" }
        return "Tutti i contatti"
    }

    // MARK: Dati e azioni

    private func reload() {
        loading = true
        defer { loading = false }
        guard ContactsStore.authorized else {
            error = "Siri AI+ non ha il permesso di vedere i Contatti: concedilo in Impostazioni di Sistema › Privacy e sicurezza › Contatti."
            return
        }
        do {
            groups = ContactsStore.groups()
            if case .group(let id) = scope, !groups.contains(where: { $0.id == id }) { scope = .all }
            let group: String? = if case .group(let id) = scope { id } else { nil }
            contacts = try ContactsStore.all(group: group)
            error = nil
            if AppTesting.selectFirst, selectedID == nil { selectedID = contacts.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveGroup(_ group: ContactGroup?, name: String) {
        do {
            if let group {
                try ContactsStore.renameGroup(group.id, to: name)
                state.appDone(.contacts, "Gruppo rinominato", detail: name)
            } else {
                let id = try ContactsStore.createGroup(name)
                state.appDone(.contacts, "Gruppo creato", detail: name)
                groups = ContactsStore.groups()
                scope = .group(id)
                return
            }
            reload()
        } catch {
            state.appFailed(.contacts, group == nil ? "Gruppo non creato" : "Gruppo non rinominato", error)
        }
    }

    private func deleteGroup(_ group: ContactGroup) {
        do {
            try ContactsStore.deleteGroup(group.id)
            if scope == .group(group.id) { scope = .all }
            state.appDone(.contacts, "Gruppo eliminato", detail: group.name)
            reload()
        } catch {
            state.appFailed(.contacts, "Gruppo non eliminato", error)
        }
    }
}

private struct GroupsMenu: View {
    @Environment(\.appSourcesVisible) private var sourcesVisible
    let groups: [ContactGroup]
    @Binding var scope: ContactsAppView.Scope

    var body: some View {
        if !sourcesVisible, !groups.isEmpty {
            Menu {
                Button("Tutti i contatti") { scope = .all }
                Divider()
                ForEach(groups) { group in Button(group.name) { scope = .group(group.id) } }
            } label: { Image(systemName: "sidebar.left") }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
            .iconHelp("Gruppi")
        }
    }
}

// MARK: - Scheda del contatto

private struct ContactDetail: View {
    @Environment(AppState.self) private var state
    let contactID: String?
    let groups: [ContactGroup]
    let canWrite: Bool
    let onSaved: (String) -> Void
    let onDeleted: () -> Void
    let onCancelNew: () -> Void

    @State private var card: ContactCard?
    @State private var draft = ContactCard()
    @State private var editing = false
    @State private var memberOf = Set<String>()
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            if editing {
                ScrollView { ContactForm(draft: $draft).padding(20) }
                InspectorFooter {
                    if contactID != nil {
                        Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                            .iconHelp("Elimina contatto")
                    }
                } trailing: {
                    Button("Annulla") {
                        if contactID == nil { onCancelNew() } else { editing = false; draft = card ?? ContactCard() }
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(contactID == nil ? "Aggiungi" : "Salva", action: save)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                }
            } else if let card {
                ScrollView { view(card).padding(24) }
                InspectorFooter {
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .iconHelp("Elimina contatto")
                        .disabled(!canWrite)
                    if !groups.isEmpty {
                        Menu {
                            ForEach(groups) { group in
                                Toggle(group.name, isOn: Binding(get: { memberOf.contains(group.id) }, set: { setMember(group, $0) }))
                            }
                        } label: { Label("Gruppi", systemImage: "person.3") }
                        .menuStyle(.button).fixedSize()
                        .disabled(!canWrite)
                    }
                } trailing: {
                    Button { state.send("Cosa sai di \(card.displayName)? Cerca nelle email, nei messaggi e nel calendario gli ultimi contatti che ho avuto") } label: {
                        Image(systemName: "sparkle")
                    }
                    .iconHelp("Chiedi a Siri AI+")
                    Button("Modifica") { draft = card; editing = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canWrite)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: contactID) { load() }
        // Siri AI+ vede il contatto aperto: «mandagli un messaggio», «qual è la sua email?».
        .onChange(of: card, initial: true) { _, card in
            if let card, !card.isNew { state.publish(.contact(card), for: .app(.contacts)) }
        }
        .confirmationDialog("Eliminare «\(card?.displayName ?? draft.displayName)»?", isPresented: $confirmDelete) {
            Button("Elimina contatto", role: .destructive, action: delete)
        } message: {
            Text("Il contatto viene eliminato anche sugli altri dispositivi collegati allo stesso account.")
        }
    }

    private func load() {
        guard let contactID else {
            card = nil
            draft = ContactCard(phones: [LabeledField(label: ContactsStore.phoneLabels[0], value: "")],
                                emails: [LabeledField(label: ContactsStore.emailLabels[0], value: "")])
            editing = true
            return
        }
        card = ContactsStore.card(contactID)
        memberOf = ContactsStore.groups(of: contactID)
        editing = false
    }

    // MARK: Vista

    @ViewBuilder private func view(_ card: ContactCard) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                Group {
                    if let data = card.imageData, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 88, height: 88).clipShape(Circle())
                    } else {
                        InitialsAvatar(name: card.displayName, size: 88)
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                Text(card.displayName).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center).textSelection(.enabled)
                let role = [card.jobTitle, card.displayName == card.organization ? "" : card.organization].filter { !$0.isEmpty }.joined(separator: " · ")
                if !role.isEmpty { Text(role).font(.system(size: 13)).foregroundStyle(.secondary) }
                if !card.nickname.isEmpty { Text("«\(card.nickname)»").font(.system(size: 13)).foregroundStyle(.secondary) }
                HStack(spacing: 14) {
                    quickAction("Messaggio", "message.fill", enabled: !(card.phones.isEmpty && card.emails.isEmpty)) {
                        state.openInApp(.messages, reference: card.phones.first?.value ?? card.emails.first?.value)
                    }
                    quickAction("Chiama", "phone.fill", enabled: !card.phones.isEmpty) { open("tel:", card.phones.first?.value) }
                    quickAction("FaceTime", "video.fill", enabled: !(card.phones.isEmpty && card.emails.isEmpty)) {
                        open("facetime:", card.phones.first?.value ?? card.emails.first?.value)
                    }
                    quickAction("Email", "envelope.fill", enabled: !card.emails.isEmpty) {
                        state.openInApp(.mail, reference: "mailto:" + (card.emails.first?.value ?? ""))
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            if !card.phones.isEmpty {
                InspectorGroup {
                    ForEach(Array(card.phones.enumerated()), id: \.element.id) { index, phone in
                        fieldRow(phone.localizedLabel, phone.value, divider: index < card.phones.count - 1) {
                            Button { state.openInApp(.messages, reference: phone.value) } label: { Image(systemName: "message") }
                                .buttonStyle(.borderless).iconHelp("Messaggio")
                            Button { open("tel:", phone.value) } label: { Image(systemName: "phone") }
                                .buttonStyle(.borderless).iconHelp("Chiama")
                        }
                    }
                }
            }
            if !card.emails.isEmpty {
                InspectorGroup {
                    ForEach(Array(card.emails.enumerated()), id: \.element.id) { index, email in
                        fieldRow(email.localizedLabel, email.value, divider: index < card.emails.count - 1) {
                            Button { state.openInApp(.mail, reference: "mailto:" + email.value) } label: { Image(systemName: "envelope") }
                                .buttonStyle(.borderless).iconHelp("Scrivi un'email")
                        }
                    }
                }
            }
            if !card.addresses.isEmpty {
                InspectorGroup {
                    ForEach(Array(card.addresses.enumerated()), id: \.element.id) { index, address in
                        fieldRow(address.localizedLabel, address.oneLine, divider: index < card.addresses.count - 1) {
                            Button {
                                if let query = address.oneLine.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                                   let url = URL(string: "maps://?q=\(query)") { NSWorkspace.shared.open(url) }
                            } label: { Image(systemName: "map") }
                            .buttonStyle(.borderless).iconHelp("Apri in Mappe")
                        }
                    }
                }
            }
            if card.birthday != nil || !card.urls.isEmpty {
                InspectorGroup {
                    if let birthday = card.birthday, let text = Self.birthdayText(birthday) {
                        fieldRow("compleanno", text, divider: !card.urls.isEmpty) { EmptyView() }
                    }
                    ForEach(Array(card.urls.enumerated()), id: \.element.id) { index, link in
                        fieldRow(link.localizedLabel, link.value, divider: index < card.urls.count - 1) {
                            Button { open("", link.value.contains("://") ? link.value : "https://" + link.value) } label: { Image(systemName: "safari") }
                                .buttonStyle(.borderless).iconHelp("Apri il sito")
                        }
                    }
                }
            }
            if !memberOf.isEmpty {
                Text("Gruppi: " + groups.filter { memberOf.contains($0.id) }.map(\.name).joined(separator: ", "))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private func quickAction(_ title: String, _ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(enabled ? Color.white : Color.secondary)
                    .frame(width: 40, height: 40)
                    .background(enabled ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Circle())
                Text(title).font(.system(size: 11)).foregroundStyle(enabled ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func fieldRow<Actions: View>(_ label: String, _ value: String, divider: Bool, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text(value).font(.system(size: 14)).textSelection(.enabled)
                }
                Spacer()
                HStack(spacing: 10) { actions() }
            }
            .padding(.vertical, 8)
            if divider { Divider().opacity(0.6) }
        }
    }

    static func birthdayText(_ components: DateComponents) -> String? {
        var parts = components
        let hasYear = parts.year != nil
        if !hasYear { parts.year = 2000 }
        guard let date = Calendar.current.date(from: parts) else { return nil }
        return hasYear ? date.formatted(.dateTime.day().month(.wide).year().locale(Dates.locale))
            : date.formatted(.dateTime.day().month(.wide).locale(Dates.locale))
    }

    private func open(_ scheme: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        let target = scheme == "tel:" ? value.filter { $0.isNumber || $0 == "+" } : value
        if let url = URL(string: scheme + target) { NSWorkspace.shared.open(url) }
    }

    // MARK: Azioni

    private func save() {
        do {
            let id = try ContactsStore.save(draft)
            state.appDone(.contacts, draft.isNew ? "Contatto aggiunto" : "Contatto salvato", detail: draft.displayName)
            editing = false
            card = ContactsStore.card(id)
            onSaved(id)
        } catch {
            state.appFailed(.contacts, "Contatto non salvato", error)
        }
    }

    private func delete() {
        guard let contactID else { onCancelNew(); return }
        do {
            try ContactsStore.delete(contactID)
            state.appDone(.contacts, "Contatto eliminato", detail: card?.displayName ?? "")
            onDeleted()
        } catch {
            state.appFailed(.contacts, "Contatto non eliminato", error)
        }
    }

    private func setMember(_ group: ContactGroup, _ member: Bool) {
        guard let contactID else { return }
        do {
            try ContactsStore.setMember(contactID, of: group.id, member)
            if member { memberOf.insert(group.id) } else { memberOf.remove(group.id) }
            state.showToast(member ? "Aggiunto a «\(group.name)»" : "Tolto da «\(group.name)»")
        } catch {
            state.appFailed(.contacts, "Gruppo non aggiornato", error)
        }
    }
}

// MARK: - Modulo di modifica

private struct ContactForm: View {
    @Binding var draft: ContactCard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                InitialsAvatar(name: draft.displayName, size: 64)
                VStack(spacing: 8) {
                    TextField("Nome", text: $draft.givenName).textFieldStyle(.roundedBorder)
                    TextField("Cognome", text: $draft.familyName).textFieldStyle(.roundedBorder)
                }
            }
            InspectorGroup {
                InspectorRow(label: "Azienda") { TextField("", text: $draft.organization).textFieldStyle(.plain) }
                InspectorRow(label: "Ruolo") { TextField("", text: $draft.jobTitle).textFieldStyle(.plain) }
                InspectorRow(label: "Soprannome", divider: false) { TextField("", text: $draft.nickname).textFieldStyle(.plain) }
            }
            fields("Telefono", $draft.phones, labels: ContactsStore.phoneLabels, prompt: "+39 …")
            fields("Email", $draft.emails, labels: ContactsStore.emailLabels, prompt: "nome@esempio.it")
            addressFields
            fields("Sito", $draft.urls, labels: ContactsStore.urlLabels, prompt: "www.esempio.it")
            InspectorGroup(title: "Compleanno") {
                InspectorRow(label: "Compleanno", divider: draft.birthday != nil) {
                    Toggle("", isOn: Binding(get: { draft.birthday != nil }, set: { on in
                        draft.birthday = on ? Calendar.current.dateComponents([.year, .month, .day], from: .now) : nil
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if draft.birthday != nil {
                    InspectorRow(label: "Giorno", divider: false) {
                        DatePicker("", selection: Binding(get: {
                            var parts = draft.birthday ?? DateComponents()
                            if parts.year == nil { parts.year = 2000 }
                            return Calendar.current.date(from: parts) ?? .now
                        }, set: { draft.birthday = Calendar.current.dateComponents([.year, .month, .day], from: $0) }), displayedComponents: [.date])
                        .labelsHidden().datePickerStyle(.field)
                    }
                }
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private func fields(_ title: String, _ items: Binding<[LabeledField]>, labels: [String], prompt: String) -> some View {
        InspectorGroup(title: title) {
            ForEach(items) { $item in
                HStack(spacing: 8) {
                    Picker("", selection: $item.label) {
                        ForEach(Array(Set(labels + [item.label]).filter { !$0.isEmpty }).sorted(), id: \.self) { label in
                            Text(CNLabel.localized(label)).tag(label)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 118)
                    TextField(prompt, text: $item.value).textFieldStyle(.plain)
                    Button { items.wrappedValue.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                        .buttonStyle(.plain).iconHelp("Togli")
                }
                .padding(.vertical, 6)
                Divider().opacity(0.6)
            }
            Button { items.wrappedValue.append(LabeledField(label: labels.first ?? "", value: "")) } label: {
                Label("Aggiungi \(title.lowercased())", systemImage: "plus.circle.fill").foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .padding(.vertical, 8)
        }
    }

    private var addressFields: some View {
        InspectorGroup(title: "Indirizzo") {
            ForEach($draft.addresses) { $address in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: $address.label) {
                            ForEach(Array(Set(ContactsStore.addressLabels + [address.label]).filter { !$0.isEmpty }).sorted(), id: \.self) {
                                Text(CNLabel.localized($0)).tag($0)
                            }
                        }
                        .labelsHidden().frame(width: 118)
                        Spacer()
                        Button { draft.addresses.removeAll { $0.id == address.id } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                            .buttonStyle(.plain).iconHelp("Togli")
                    }
                    TextField("Via e numero", text: $address.street).textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("CAP", text: $address.postalCode).textFieldStyle(.roundedBorder).frame(width: 90)
                        TextField("Città", text: $address.city).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        TextField("Provincia", text: $address.state).textFieldStyle(.roundedBorder)
                        TextField("Paese", text: $address.country).textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.vertical, 8)
                Divider().opacity(0.6)
            }
            Button { draft.addresses.append(PostalField(label: ContactsStore.addressLabels[0], country: "Italia")) } label: {
                Label("Aggiungi indirizzo", systemImage: "plus.circle.fill").foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .padding(.vertical, 8)
        }
    }
}

/// Etichette di Contatti nella lingua del Mac.
enum CNLabel {
    static func localized(_ label: String) -> String { LabeledField(label: label, value: "").localizedLabel }
}

// MARK: - Gruppo nuovo o rinominato

private struct GroupEditor: View {
    let group: ContactGroup?
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group == nil ? "Nuovo gruppo" : "Rinomina gruppo").font(.system(size: 15, weight: .semibold))
            TextField("Nome del gruppo", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(group == nil ? "Crea" : "Rinomina", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { name = group?.name ?? "" }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(name.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
