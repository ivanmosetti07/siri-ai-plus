import AppKit
import SiriCore
import SwiftUI

// MARK: - Messaggi

struct MessagesAppView: View {
    @Environment(AppState.self) private var state
    @Environment(\.appTabActive) private var tabActive
    @State private var chats = [ChatSummary]()
    @State private var selectedID: Int64?
    @State private var search = ""
    @State private var error: String?
    @State private var readable = SystemAccess.fullDiskAccess
    @State private var composing = false
    /// Destinatario già scelto per un messaggio nuovo (dalla scheda di un contatto).
    @State private var newRecipient = ""
    /// Conversazione da aprire (recapito arrivato da una scheda della chat).
    @State private var pendingFocus: String?
    @State private var handledFocus: UUID?

    private var visible: [ChatSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return chats }
        return chats.filter { chat in
            chat.title.localizedCaseInsensitiveContains(query) || chat.lastText.localizedCaseInsensitiveContains(query)
                || chat.handles.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(source: .messages, title: String(localized: "Messaggi"), subtitle: subtitle, search: $search, searchPrompt: String(localized: "Cerca persona o testo"),
                      onRefresh: reload) {
                AppIconButton(symbol: "square.and.pencil", help: String(localized: "Nuovo messaggio"), prominent: true) { composing = true }
                    .disabled(!state.canWrite(.messages))
            }
            Divider()
            if !readable {
                AccessNotice(symbol: "message.badge.filled.fill", title: String(localized: "Serve l'accesso completo al disco"),
                             message: String(localized: "macOS protegge le conversazioni di Messaggi: per mostrarle qui Siri AI+ ha bisogno dell'accesso completo al disco. Lo concedi una volta e resta per sempre. Inviare messaggi funziona anche senza."),
                             primary: (String(localized: "Concedi nelle Impostazioni"), { PermissionCenter.openSettings(.fullDisk) }),
                             secondary: (String(localized: "Nuovo messaggio"), { composing = true }))
            } else {
                HStack(spacing: 0) {
                    conversationList.frame(width: 300)
                    Divider()
                    if let chat = chats.first(where: { $0.id == selectedID }) {
                        ChatThread(chat: chat, canWrite: state.canWrite(.messages)) { reload() }
                            .id(chat.id)
                    } else {
                        AppPlaceholder(symbol: "bubble.left.and.bubble.right", title: chats.isEmpty ? String(localized: "Nessuna conversazione") : String(localized: "Nessuna conversazione selezionata"),
                                       message: error ?? String(localized: "Scegli una conversazione per leggerla e rispondere."))
                    }
                }
            }
        }
        .task { reload() }
        .task(id: tabActive) {
            // Il database di Messaggi si legge in pochi millisecondi: i messaggi nuovi compaiono da soli (con la scheda davanti).
            guard tabActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                refreshQuietly()
            }
        }
        .onChange(of: tabActive) { _, active in if active { refreshQuietly() } }
        // Senza conversazione aperta Siri AI+ vede l'elenco (quella aperta la descrive la conversazione).
        .onChange(of: selectedID, initial: true) { _, id in if id == nil { state.publish(.chats(chats), for: .app(.messages)) } }
        .onChange(of: chats) { _, list in if selectedID == nil { state.publish(.chats(list), for: .app(.messages)) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !readable, SystemAccess.fullDiskAccess { readable = true; reload() }
        }
        .onChange(of: state.appFocus, initial: true) { _, focus in
            guard let focus, focus.source == .messages, focus.id != handledFocus else { return }
            handledFocus = focus.id
            pendingFocus = focus.reference
            applyFocus()
        }
        .sheet(isPresented: $composing) {
            NewMessageSheet(initialRecipient: newRecipient) { composing = false; newRecipient = ""; Task { try? await Task.sleep(for: .seconds(1.5)); reload() } }
        }
    }

    private var subtitle: String {
        let unread = chats.reduce(0) { $0 + $1.unread }
        return unread == 0 ? String(localized: "\(chats.count) conversazioni") : unread == 1 ? String(localized: "1 messaggio da leggere") : String(localized: "\(unread) messaggi da leggere")
    }

    private var conversationList: some View {
        List(selection: $selectedID) {
            ForEach(visible) { chat in
                HStack(spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        InitialsAvatar(name: chat.title, size: 40)
                        if chat.unread > 0 { Circle().fill(Color.accentColor).frame(width: 10, height: 10).offset(x: -4, y: 14) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(chat.title).font(.system(size: 13.5, weight: chat.unread > 0 ? .bold : .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(chat.date.listStamp).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Text((chat.lastFromMe ? String(localized: "Tu: ") : "") + chat.lastText)
                            .font(.system(size: 12.5))
                            .foregroundStyle(chat.unread > 0 ? .primary : .secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
                .tag(chat.id)
                .contextMenu {
                    Button("Apri in Messaggi") {
                        if let handle = chat.handles.first, let url = URL(string: "imessage:\(handle)") { NSWorkspace.shared.open(url) } else { SourceKind.messages.openSystemApp() }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func reload() {
        readable = SystemAccess.fullDiskAccess
        guard readable else { return }
        do {
            chats = try MessagesStore.chats()
            error = nil
            applyFocus()
            if selectedID == nil { selectedID = chats.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// La conversazione con quel numero o email (le ultime 9 cifre bastano: prefissi scritti in modi diversi).
    private func applyFocus() {
        guard let handle = pendingFocus, !chats.isEmpty || !readable else { return }
        let digits = String(handle.filter(\.isNumber).suffix(9))
        if let chat = chats.first(where: { chat in
            chat.handles.contains(handle) || (!digits.isEmpty && chat.handles.contains { $0.filter(\.isNumber).hasSuffix(digits) })
        }) {
            selectedID = chat.id
        } else if state.canWrite(.messages) {
            // Nessuna conversazione con questa persona: messaggio nuovo già indirizzato.
            newRecipient = handle
            composing = true
        }
        pendingFocus = nil
    }

    private func refreshQuietly() {
        guard readable, let fresh = try? MessagesStore.chats(), fresh != chats else { return }
        chats = fresh
    }
}

// MARK: - Conversazione

private struct ChatThread: View {
    @Environment(AppState.self) private var state
    @Environment(\.appTabActive) private var tabActive
    let chat: ChatSummary
    let canWrite: Bool
    let onSent: () -> Void
    @State private var messages = [ChatMessage]()
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                InitialsAvatar(name: chat.title, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(chat.handles.joined(separator: ", ")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { state.send(String(localized: "Riassumi la conversazione con \(chat.title) e proponimi una risposta")) } label: {
                    Label("Chiedi a Siri AI+", systemImage: "sparkle")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || message.date.timeIntervalSince(messages[index - 1].date) > 3600 {
                                Text(Calendar.current.isDate(message.date, equalTo: .now, toGranularity: .year)
                                     ? message.date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute().locale(Dates.locale))
                                     : message.date.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Dates.locale)))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 8)
                            }
                            Bubble(message: message, showsSender: chat.isGroup && !message.fromMe
                                   && (index == 0 || messages[index - 1].sender != message.sender || messages[index - 1].fromMe))
                                .id(message.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: messages.last?.id) { _, last in if let last { proxy.scrollTo(last, anchor: .bottom) } }
                .task { try? await Task.sleep(for: .milliseconds(40)); if let last = messages.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(canWrite ? "iMessage" : String(localized: "Invio disattivato nelle impostazioni"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(!canWrite)
                Button(action: send) {
                    if sending { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
                .disabled(!canWrite || sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .iconHelp(String(localized: "Invia"))
            }
            .padding(12)
        }
        .task(id: tabActive) {
            guard tabActive else { return }
            load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { break }
                load()
            }
        }
        // Siri AI+ vede la conversazione aperta: «rispondi che arrivo», «riassumi la conversazione».
        .onChange(of: messages, initial: true) { _, messages in state.publish(.chat(chat, messages: messages), for: .app(.messages)) }
    }

    private func load() {
        if let fresh = try? MessagesStore.messages(chat: chat.id), fresh != messages { messages = fresh }
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, canWrite, !sending else { return }
        sending = true
        Task {
            do {
                try await MessagesStore.send(body, toChat: chat.guid)
                text = ""
                state.log(icon: "source:messages", title: String(localized: "Messaggio inviato"), detail: "\(chat.title): \(body.prefix(60))", status: .done)
                try? await Task.sleep(for: .seconds(1.2))
                load()
                onSent()
            } catch {
                state.appFailed(.messages, String(localized: "Messaggio non inviato"), error)
            }
            sending = false
            focused = true
        }
    }
}

private struct Bubble: View {
    let message: ChatMessage
    let showsSender: Bool

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 60) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 2) {
                if showsSender { Text(message.sender).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10) }
                VStack(alignment: .leading, spacing: 4) {
                    if message.hasAttachment {
                        Label("Allegato", systemImage: "paperclip").font(.system(size: 12, weight: .medium))
                    }
                    if !message.text.isEmpty {
                        Text(message.text).font(.system(size: 13.5)).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(message.fromMe ? Color.white : Color.primary)
                .background(message.fromMe ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.09)),
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            if !message.fromMe { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Nuovo messaggio

private struct NewMessageSheet: View {
    @Environment(AppState.self) private var state
    var initialRecipient = ""
    let onClose: () -> Void
    @State private var recipient = ""
    @State private var handle = ""
    @State private var text = ""
    @State private var sending = false
    @State private var suggestions = [String]()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Tile(.messages, size: 24)
                Text("Nuovo messaggio").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Annulla", action: onClose).keyboardShortcut(.cancelAction)
            }
            TextField("A: nome, numero o email", text: $recipient)
                .textFieldStyle(.roundedBorder)
                .onChange(of: recipient) { _, value in
                    handle = Contacts.resolve(value) ?? ""
                    suggestions = value.count >= 2 && !value.contains("@") && value.filter(\.isNumber).count < 5 ? Array(Contacts.handles(for: value).prefix(4)) : []
                }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(suggestions, id: \.self) { value in
                        Button { handle = value; suggestions = [] } label: {
                            Label(value, systemImage: value.contains("@") ? "envelope" : "phone").font(.system(size: 12.5))
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            if !handle.isEmpty {
                Label("Invio a \(handle)", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
            } else if !recipient.isEmpty {
                Label("Non trovo il recapito tra i Contatti: scrivi il numero o l'email.", systemImage: "questionmark.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 140)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button { send() } label: {
                    if sending { ProgressView().controlSize(.small) } else { Label("Invia", systemImage: "arrow.up.circle.fill") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending || handle.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { if recipient.isEmpty, !initialRecipient.isEmpty { recipient = initialRecipient } }
    }

    private func send() {
        sending = true
        Task {
            do {
                try await MessagesService.send(MessageDraft(recipient: recipient, handle: handle, text: text))
                state.appDone(.messages, String(localized: "Messaggio inviato"), detail: recipient)
                onClose()
            } catch {
                state.appFailed(.messages, String(localized: "Messaggio non inviato"), error)
            }
            sending = false
        }
    }
}
