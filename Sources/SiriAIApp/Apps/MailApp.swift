import AppKit
import SiriCore
import SwiftUI

// MARK: - Mail

struct MailAppView: View {
    @Environment(AppState.self) private var state
    @Environment(\.appTabActive) private var tabActive
    @State private var accounts = [MailAccountInfo]()
    @State private var mailboxes = [MailboxInfo]()
    @State private var box = MailboxInfo.unifiedInbox
    @State private var messages = [MailSummary]()
    @State private var total = 0
    @State private var selectedID: String?
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var composing: ComposeItem?
    @State private var fast = MailIndex.available
    @State private var pageSize = 150
    /// Email da aprire appena l'elenco è pronto (aperta da una scheda della chat).
    @State private var pendingFocus: String?
    @State private var handledFocus: UUID?

    private var selected: MailSummary? { selectedID.flatMap { id in messages.first { $0.id == id } } }
    private var senders: [String] { accounts.flatMap(\.senders) }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(source: .mail, title: "Mail", subtitle: subtitle, search: $search, searchPrompt: "Cerca mittente, oggetto…",
                      onSearch: { Task { await loadMessages() } }, onRefresh: { Task { await reloadAll() } }) {
                AppIconButton(symbol: "square.and.pencil", help: "Nuova email", prominent: true) {
                    composing = ComposeItem(composition: MailComposition(from: defaultSender))
                }
                .disabled(!state.canWrite(.mail))
            }
            Divider()
            if !fast {
                InlineBanner(symbol: "bolt.horizontal.circle", tint: .orange,
                             text: "Mail è lenta senza l'accesso completo al disco: con la tua posta servono anche minuti. Concedilo una volta e Siri AI+ legge l'indice di Mail all'istante.") {
                    Button("Apri Impostazioni") { PermissionCenter.openSettings(.fullDisk) }
                }
                .padding(10)
            }
            if let error, messages.isEmpty {
                AccessNotice(symbol: "envelope.badge.shield.half.filled", title: "Mail non risponde", message: error,
                             primary: ("Riprova", { Task { await reloadAll() } }),
                             secondary: ("Permessi", { PermissionCenter.openSettings(.automation) }))
            } else {
                AppColumns(sourcesWidth: 226, itemsWidth: 340) {
                    MailboxList(mailboxes: mailboxes, selection: $box)
                } items: {
                    messageList
                } detail: {
                    if let message = selected {
                        MailReader(summary: message, box: message.location ?? box, mailboxes: mailboxes, canWrite: state.canWrite(.mail),
                                   onReply: { content, all in composing = ComposeItem(composition: MailStore.replyDraft(to: content, box: message.location ?? box, all: all, from: sender(for: message))) },
                                   onForward: { content in composing = ComposeItem(composition: MailStore.forwardDraft(of: content, box: message.location ?? box, from: sender(for: message))) },
                                   onAction: { perform($0, on: message) })
                            .id(message.id)
                    } else {
                        AppPlaceholder(symbol: "envelope.open", title: messages.isEmpty ? "Nessuna email" : "Nessuna email selezionata",
                                       message: messages.isEmpty ? nil : "Scegli un'email da leggere. Da qui rispondi, inoltri, sposti o elimini.")
                    }
                }
            }
        }
        .task { await reloadAll() }
        .task(id: box) { selectedID = nil; await loadMessages() }
        .task(id: tabActive) {
            // Con l'indice aggiornarsi costa poco: la posta nuova compare da sola (solo con la scheda davanti).
            guard tabActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Task.isCancelled { break }
                if fast { await refreshQuietly() }
            }
        }
        .onChange(of: tabActive) { _, active in
            if active, fast { Task { await refreshQuietly() } }
        }
        // Senza email selezionata Siri AI+ vede l'elenco della casella (l'email aperta la descrive il lettore).
        .onChange(of: selectedID, initial: true) { _, id in
            if id == nil { state.publish(.mailbox(box, messages: messages), for: .app(.mail)) }
        }
        .onChange(of: messages) { _, list in
            if selectedID == nil { state.publish(.mailbox(box, messages: list), for: .app(.mail)) }
        }
        .onChange(of: state.appFocus, initial: true) { _, focus in
            guard let focus, focus.source == .mail, focus.id != handledFocus else { return }
            handledFocus = focus.id
            // Dalla scheda di un contatto: email nuova già indirizzata.
            if focus.reference.hasPrefix("mailto:") {
                if state.canWrite(.mail) {
                    composing = ComposeItem(composition: MailComposition(from: defaultSender, to: String(focus.reference.dropFirst("mailto:".count))))
                }
                return
            }
            pendingFocus = focus.reference
            if box.id != MailboxInfo.unifiedInbox.id {
                box = mailboxes.first { $0.account == nil && $0.kind == .inbox } ?? .unifiedInbox
            } else {
                applyFocus()
            }
        }
        .sheet(item: $composing) { item in
            MailComposeView(composition: item.composition, senders: senders) { composing = nil }
        }
    }

    private struct ComposeItem: Identifiable {
        let id = UUID()
        let composition: MailComposition
    }

    private var subtitle: String {
        let unread = mailboxes.first { $0.account == nil && $0.kind == .inbox }?.unread ?? 0
        return unread == 0 ? "Nessuna email da leggere" : unread == 1 ? "1 email da leggere" : "\(unread) email da leggere"
    }

    private var defaultSender: String {
        if let account = SpaceScope.current.mailAccount, let match = accounts.first(where: { $0.name == account }) { return match.senders.first ?? "" }
        return senders.first ?? ""
    }

    /// Si risponde dall'account che ha ricevuto l'email.
    private func sender(for message: MailSummary) -> String {
        if let accountID = message.location?.accountID, let account = accounts.first(where: { $0.id == accountID }) { return account.senders.first ?? defaultSender }
        return defaultSender
    }

    // MARK: Elenco

    private var messageList: some View {
        VStack(spacing: 0) {
            ListHeading(title: box.title, tint: .primary, count: total > 0 ? "\(total)" : nil) {
                MailboxMenu(mailboxes: mailboxes, selection: $box)
            }
            if let account = box.account {
                Text(account).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 4)
            }
            if loading && messages.isEmpty {
                ProgressView(fast ? "Carico…" : "Leggo la posta da Mail…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                AppPlaceholder(symbol: search.isEmpty ? "tray" : "magnifyingglass", title: search.isEmpty ? "Nessuna email" : "Nessun risultato")
            } else {
                List(selection: $selectedID) {
                    ForEach(messages) { message in
                        MailRow(message: message, showsRecipient: box.kind == .sent || box.kind == .drafts)
                            .tag(message.id)
                            .contextMenu { rowMenu(message) }
                    }
                    if messages.count < total {
                        Button("Carica altre email (\(total - messages.count))") {
                            pageSize += 150
                            Task { await loadMessages() }
                        }
                        .buttonStyle(.link)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onDeleteCommand { if let message = selected { perform(.delete, on: message) } }
            }
        }
    }

    @ViewBuilder private func rowMenu(_ message: MailSummary) -> some View {
        Button(message.read ? "Segna come non letta" : "Segna come letta") { perform(.read(!message.read), on: message) }
        Button(message.flagged ? "Togli contrassegno" : "Contrassegna") { perform(.flag(!message.flagged), on: message) }
        MoveMenu(message: message, box: message.location ?? box, mailboxes: mailboxes) { perform(.move($0), on: message) }
        Divider()
        Button("Apri in Mail") { perform(.open, on: message) }
        Button("Elimina", role: .destructive) { perform(.delete, on: message) }
    }

    // MARK: Dati

    private func reloadAll() async {
        loading = true
        fast = MailIndex.available
        if accounts.isEmpty, SystemAccess.automation("com.apple.mail") != .denied {
            accounts = (try? await MailStore.accounts()) ?? []
            if !accounts.isEmpty { MailIndex.configure(accounts: accounts) }
        }
        do {
            mailboxes = fast ? try MailIndex.mailboxes() : try await MailStore.mailboxes()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await loadMessages()
    }

    private func loadMessages() async {
        loading = true
        defer { loading = false }
        do {
            if fast {
                let page = try MailIndex.messages(in: box, limit: pageSize, search: search)
                messages = page.items
                total = page.total
                if AppTesting.selectFirst, selectedID == nil { selectedID = messages.first?.id }
            } else {
                let page = try await MailStore.messages(in: box, count: min(pageSize, 60))
                let query = search.trimmingCharacters(in: .whitespaces)
                messages = query.isEmpty ? page.items : page.items.filter {
                    $0.subject.localizedCaseInsensitiveContains(query) || $0.sender.localizedCaseInsensitiveContains(query)
                }
                total = query.isEmpty ? page.total : messages.count
            }
            error = nil
            applyFocus()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyFocus() {
        guard let pendingFocus, messages.contains(where: { $0.id == pendingFocus }) else { return }
        selectedID = pendingFocus
        self.pendingFocus = nil
    }

    private func refreshQuietly() async {
        guard let page = try? MailIndex.messages(in: box, limit: pageSize, search: search) else { return }
        if page.items != messages { messages = page.items; total = page.total }
        if let boxes = try? MailIndex.mailboxes(), boxes != mailboxes { mailboxes = boxes }
    }

    private func perform(_ action: MailStore.Action, on message: MailSummary) {
        guard state.canWrite(.mail) || action == .open else { return }
        let target = message.location ?? box
        // Subito nell'elenco, poi in Mail.
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            switch action {
            case .read(let value): messages[index].read = value
            case .flag(let value): messages[index].flagged = value
            case .delete, .move:
                messages.remove(at: index)
                total = max(0, total - 1)
                if selectedID == message.id { selectedID = nil }
            case .open: break
            }
        }
        Task {
            do {
                try await MailStore.perform(action, on: message.id, in: target)
                switch action {
                case .delete: state.appDone(.mail, "Email spostata nel Cestino", detail: message.subject)
                case .move(let destination): state.appDone(.mail, "Email spostata in «\(destination.displayName)»", detail: message.subject)
                case .flag(true): state.showToast("Email contrassegnata", symbol: "flag.fill")
                default: break
                }
                try? await Task.sleep(for: .seconds(1))
                await refreshQuietly()
            } catch {
                state.appFailed(.mail, "Azione non riuscita", error)
                await loadMessages()
            }
        }
    }
}

// MARK: - Caselle

private struct MailboxList: View {
    let mailboxes: [MailboxInfo]
    @Binding var selection: MailboxInfo

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let value = $0 { selection = value } })) {
            Section("Tutte le caselle") {
                ForEach(mailboxes.filter { $0.account == nil }) { box in
                    SourceRowLabel(title: box.title, symbol: box.kind.symbol, tint: box.kind == .flagged ? .orange : .accentColor,
                                   count: box.unread).tag(box)
                }
            }
            ForEach(accountNames, id: \.self) { account in
                Section(account) {
                    ForEach(mailboxes.filter { $0.account == account }) { box in
                        SourceRowLabel(title: box.displayName, symbol: box.kind.symbol, tint: box.kind == .other ? .secondary : .accentColor,
                                       count: box.kind == .junk || box.kind == .trash ? nil : box.unread, indent: box.depth)
                            .tag(box)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var accountNames: [String] {
        var seen = Set<String>()
        return mailboxes.compactMap(\.account).filter { seen.insert($0).inserted }
    }
}

/// Le caselle in un menu, quando la colonna è nascosta.
private struct MailboxMenu: View {
    @Environment(\.appSourcesVisible) private var sourcesVisible
    let mailboxes: [MailboxInfo]
    @Binding var selection: MailboxInfo

    var body: some View {
        if !sourcesVisible {
            Menu {
                ForEach(mailboxes.filter { $0.account == nil }) { box in Button(box.title) { selection = box } }
                ForEach(Array(Set(mailboxes.compactMap(\.account))).sorted(), id: \.self) { account in
                    Menu(account) {
                        ForEach(mailboxes.filter { $0.account == account }) { box in Button(box.displayName) { selection = box } }
                    }
                }
            } label: { Image(systemName: "sidebar.left") }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
            .iconHelp("Caselle")
        }
    }
}

/// «Sposta in»: le caselle dello stesso account.
private struct MoveMenu: View {
    let message: MailSummary
    let box: MailboxInfo
    let mailboxes: [MailboxInfo]
    let onMove: (MailboxInfo) -> Void

    var body: some View {
        let targets = mailboxes.filter { $0.account != nil && ($0.accountID == box.accountID || $0.account == box.account) && $0.id != box.id && $0.kind != .flagged }
        if !targets.isEmpty {
            Menu("Sposta in") {
                ForEach(targets) { target in
                    Button(String(repeating: "   ", count: target.depth) + target.displayName) { onMove(target) }
                }
            }
        }
    }
}

// MARK: - Riga

private struct MailRow: View {
    let message: MailSummary
    let showsRecipient: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(message.read ? Color.clear : Color.accentColor).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(showsRecipient && !message.recipient.isEmpty ? "A: \(message.recipient)" : message.senderName)
                        .font(.system(size: 13.5, weight: message.read ? .medium : .bold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.flagged { Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(.orange) }
                    Text(message.date.listStamp).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Text(message.subject.isEmpty ? "(senza oggetto)" : message.subject)
                    .font(.system(size: 12.5, weight: message.read ? .regular : .semibold))
                    .lineLimit(1)
                if !message.preview.isEmpty {
                    Text(message.preview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Lettura

private struct MailReader: View {
    @Environment(AppState.self) private var state
    let summary: MailSummary
    let box: MailboxInfo
    let mailboxes: [MailboxInfo]
    let canWrite: Bool
    let onReply: (MailContent, Bool) -> Void
    let onForward: (MailContent) -> Void
    let onAction: (MailStore.Action) -> Void
    @State private var content: MailContent?
    @State private var header: (to: [String], cc: [String], attachments: [String])?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        InitialsAvatar(name: summary.senderName, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(summary.senderName).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text(summary.date.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Dates.locale)))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            if !summary.senderAddress.isEmpty, summary.senderAddress != summary.senderName {
                                Text(summary.senderAddress).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if let to = header?.to ?? content?.to, !to.isEmpty {
                                Text("A: " + to.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                            }
                            if let cc = header?.cc ?? content?.cc, !cc.isEmpty {
                                Text("Cc: " + cc.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                    Text(summary.subject.isEmpty ? "(senza oggetto)" : summary.subject)
                        .font(.system(size: 20, weight: .bold))
                        .textSelection(.enabled)
                    if let attachments = header?.attachments ?? content?.attachments, !attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(attachments, id: \.self) { name in
                                    Label(name, systemImage: "paperclip")
                                        .font(.system(size: 12))
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                    Divider()
                    if let content {
                        Text(linked(content.content))
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: 760, alignment: .leading)
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            if !summary.preview.isEmpty { Text(summary.preview).font(.system(size: 14)).foregroundStyle(.secondary) }
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            header = MailIndex.available ? MailIndex.header(of: summary.id) : nil
            do {
                if header != nil {
                    let body = try await MailStore.body(of: summary.id, in: box)
                    content = MailContent(id: summary.id, subject: summary.subject, sender: summary.sender, to: header?.to ?? [], cc: header?.cc ?? [],
                                          attachments: header?.attachments ?? [], date: summary.date,
                                          dateText: summary.date.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Dates.locale)),
                                          content: body, read: summary.read, flagged: summary.flagged)
                } else {
                    content = try await MailStore.content(of: summary.id, in: box)
                }
            } catch {
                self.error = error.localizedDescription
            }
            // Come in Mail: aperta, diventa letta (non nelle prove automatiche).
            if !summary.read, canWrite, !CommandLine.arguments.contains("--ephemeral") {
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { onAction(.read(true)) }
            }
        }
        // Siri AI+ vede l'email aperta: «rispondi che va bene», «riassumila», «crea un evento da questa email».
        .onChange(of: content, initial: true) { _, content in
            state.publish(.mail(summary, content: content), for: .app(.mail))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            AppIconButton(symbol: "arrowshape.turn.up.left", help: "Rispondi") { if let content { onReply(content, false) } }
            AppIconButton(symbol: "arrowshape.turn.up.left.2", help: "Rispondi a tutti") { if let content { onReply(content, true) } }
            AppIconButton(symbol: "arrowshape.turn.up.right", help: "Inoltra") { if let content { onForward(content) } }
            Divider().frame(height: 18).padding(.horizontal, 4)
            AppIconButton(symbol: summary.flagged ? "flag.slash" : "flag", help: summary.flagged ? "Togli contrassegno" : "Contrassegna") {
                onAction(.flag(!summary.flagged))
            }
            AppIconButton(symbol: summary.read ? "envelope.badge" : "envelope.open", help: summary.read ? "Segna come non letta" : "Segna come letta") {
                onAction(.read(!summary.read))
            }
            Menu {
                MoveMenuItems(box: box, mailboxes: mailboxes) { onAction(.move($0)) }
            } label: { Image(systemName: "folder") }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
            .iconHelp("Sposta in")
            AppIconButton(symbol: "trash", help: "Elimina", role: .destructive) { onAction(.delete) }
            Spacer()
            AppIconButton(symbol: "sparkle", help: "Chiedi a Siri AI+ di questa email") {
                state.send("Riassumi l'email «\(summary.subject)» di \(summary.senderName) e dimmi se devo rispondere")
            }
            AppIconButton(symbol: "arrow.up.forward.app", help: "Apri in Mail") { onAction(.open) }
        }
        .disabled(!canWrite)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Testo con i link cliccabili.
    private func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text), let attributed = Range(range, in: result) else { continue }
            result[attributed].link = url
        }
        return result
    }
}

private struct MoveMenuItems: View {
    let box: MailboxInfo
    let mailboxes: [MailboxInfo]
    let onMove: (MailboxInfo) -> Void

    var body: some View {
        let targets = mailboxes.filter { $0.account != nil && ($0.accountID == box.accountID || $0.account == box.account) && $0.id != box.id && $0.kind != .flagged }
        if targets.isEmpty {
            Text("Nessuna altra casella")
        }
        ForEach(targets) { target in
            Button(String(repeating: "   ", count: target.depth) + target.displayName) { onMove(target) }
        }
    }
}

// MARK: - Scrivi

struct MailComposeView: View {
    @Environment(AppState.self) private var state
    @State var composition: MailComposition
    let senders: [String]
    let onClose: () -> Void
    @State private var showCc = false
    @State private var sending = false
    @State private var suggestions = [(name: String, address: String)]()
    @State private var showQuote = false

    private var title: String {
        switch composition.mode {
        case .new: "Nuova email"
        case .reply(_, _, let all): all ? "Rispondi a tutti" : "Rispondi"
        case .forward: "Inoltra"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Tile(.mail, size: 24)
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Annulla", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            VStack(spacing: 0) {
                if !senders.isEmpty {
                    field("Da") {
                        Picker("", selection: $composition.from) {
                            ForEach(senders, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                field("A") {
                    TextField("Nome o indirizzo", text: $composition.to)
                        .textFieldStyle(.plain)
                        .onChange(of: composition.to) { _, value in updateSuggestions(value) }
                    Button { showCc.toggle() } label: { Text("Cc").font(.system(size: 12)) }.buttonStyle(.borderless)
                }
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                            Button { choose(suggestion) } label: {
                                HStack {
                                    Text(suggestion.name).font(.system(size: 13, weight: .medium))
                                    Text(suggestion.address).font(.system(size: 12)).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 64).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Color.accentColor.opacity(0.06))
                }
                if showCc || !composition.cc.isEmpty || !composition.bcc.isEmpty {
                    field("Cc") { TextField("", text: $composition.cc).textFieldStyle(.plain) }
                    field("Ccn") { TextField("", text: $composition.bcc).textFieldStyle(.plain) }
                }
                field("Oggetto") { TextField("", text: $composition.subject).textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)) }
            }
            TextEditor(text: $composition.body)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 220)
            if !composition.quote.isEmpty {
                DisclosureGroup(isExpanded: $showQuote) {
                    ScrollView { Text(composition.quote).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 160)
                } label: {
                    Text("Messaggio originale").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
            if case .forward = composition.mode {
                Label("Il messaggio originale e i suoi allegati vengono inoltrati così come sono.", systemImage: "arrowshape.turn.up.right")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8)
            }
            if !composition.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(composition.attachments, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                Text(url.lastPathComponent).lineLimit(1)
                                Button { composition.attachments.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 8)
            }
            Divider()
            HStack {
                Button { attach() } label: { Label("Allega…", systemImage: "paperclip") }
                Spacer()
                Button("Apri in Mail") { deliver(send: false) }
                    .help("Apre l'email già scritta in Mail, per finirla e inviarla da lì")
                Button { deliver(send: true) } label: {
                    if sending { ProgressView().controlSize(.small) } else { Label("Invia", systemImage: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending || MailComposition.addresses(composition.to).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 640, height: 600)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider().padding(.leading, 78)
        }
    }

    private func updateSuggestions(_ text: String) {
        let last = text.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard last.count >= 2, !last.contains("@") else { suggestions = []; return }
        suggestions = Array(Contacts.emails(for: last).prefix(5))
    }

    private func choose(_ suggestion: (name: String, address: String)) {
        var parts = composition.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(suggestion.name.isEmpty ? suggestion.address : "\(suggestion.name) <\(suggestion.address)>")
        composition.to = parts.joined(separator: ", ") + ", "
        suggestions = []
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Allega"
        if panel.runModal() == .OK { composition.attachments += panel.urls }
    }

    private func deliver(send: Bool) {
        sending = true
        Task {
            do {
                try await MailStore.deliver(composition, send: send)
                state.appDone(.mail, send ? "Email inviata" : "Email aperta in Mail", detail: composition.subject)
                onClose()
            } catch {
                state.appFailed(.mail, send ? "Email non inviata" : "Email non aperta", error)
            }
            sending = false
        }
    }
}
