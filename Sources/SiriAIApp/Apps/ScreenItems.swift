import AppKit
import SiriCore
import SwiftUI

// MARK: - Cosa vede Siri AI+ in ogni app
//
// Ogni app descrive la sua scheda all'assistente: l'elemento selezionato con il testo utile (corpo dell'email, testo della nota,
// recapiti del contatto, ultimi messaggi, trascrizione), o ciò che mostra quando non c'è una selezione.

extension AppState {
    /// Aggiorna ciò che una scheda mostra (per l'assistente e per i suggerimenti della chat).
    func publish(_ item: ScreenItem?, for tab: AppTab) {
        guard screenItems[tab] != item else { return }
        screenItems[tab] = item
    }

    /// L'elemento della scheda davanti, se le app sono in vista.
    var screenItem: ScreenItem? {
        guard showsApps, let tab = section.appTab else { return nil }
        return screenItems[tab]
    }

    /// Una riga per ogni altra scheda aperta: l'elemento selezionato, la pagina o il documento.
    func tabSummary(_ tab: AppTab) -> String? {
        if let item = screenItems[tab] { return item.headline }
        switch tab {
        case .browser: return browser.url == nil ? nil : String(localized: "Safari: pagina «\(title(of: .browser))»")
        case .document(let id): return artifact(id).map { "\($0.kind.app): \($0.kind.noun.lowercased()) «\($0.title)»" }
        case .docs(let kind): return kind.app
        case .app(let source): return source.label
        case .launcher: return nil
        case .file(let url): return String(localized: "File: «\(url.lastPathComponent)»")
        case .chats: return String(localized: "Chat affiancate: \(title(of: tab))")
        }
    }
}

extension ScreenItem {
    private static func when(_ date: Date, time: Bool = true) -> String {
        time ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(Dates.locale))
             : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Dates.locale))
    }

    // MARK: Mail

    static func mail(_ summary: MailSummary, content: MailContent?) -> ScreenItem {
        let address = summary.senderAddress
        var details = String(localized: "da \(summary.senderName)") + (address.isEmpty || address == summary.senderName ? "" : " <\(address)>") + ", \(when(summary.date))"
        if let to = content?.to, !to.isEmpty { details += "; a \(to.prefix(3).joined(separator: ", "))" }
        if let attachments = content?.attachments, !attachments.isEmpty { details += String(localized: "; allegati: \(attachments.prefix(4).joined(separator: ", "))") }
        var item = ScreenItem(app: String(localized: "Mail"), kind: .email, title: summary.subject.isEmpty ? String(localized: "(senza oggetto)") : summary.subject,
                              details: details, text: String((content?.content ?? summary.preview).prefix(8000)), reference: summary.id)
        item.recipientName = summary.senderName
        item.email = address.isEmpty ? nil : address
        item.mail = MailMessage(id: summary.id, subject: summary.subject, sender: summary.sender,
                                date: content?.dateText ?? when(summary.date), content: content?.content ?? "")
        return item
    }

    static func mailbox(_ box: MailboxInfo, messages: [MailSummary]) -> ScreenItem {
        let unread = messages.filter { !$0.read }.count
        let lines = messages.prefix(15).map { "\($0.read ? "" : "• ")\($0.senderName) — \($0.subject.isEmpty ? String(localized: "(senza oggetto)") : $0.subject) (\($0.date.listStamp))" }
        return ScreenItem(app: String(localized: "Mail"), kind: .overview, title: String(localized: "casella «\(box.title)»"),
                          details: String(localized: "\(messages.count) email in elenco") + (unread > 0 ? String(localized: ", \(unread) da leggere") : ""),
                          text: lines.joined(separator: "\n"), nouns: ["email", "e-mail", "mail", "posta", "messaggi"])
    }

    // MARK: Note

    static func note(id: String?, text: String, folder: String?) -> ScreenItem {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let title = lines.first { !$0.isEmpty } ?? String(localized: "Nuova nota")
        return ScreenItem(app: String(localized: "Note"), kind: .note, title: String(title.prefix(80)), details: folder.map { String(localized: "cartella \($0)") } ?? "",
                          text: String(text.prefix(8000)), reference: id)
    }

    static func notes(folder: String, notes: [NoteSummary]) -> ScreenItem {
        let lines = notes.prefix(20).map { "\($0.title) (\($0.modified.listStamp))" + ($0.preview.isEmpty ? "" : ": \($0.preview.prefix(80))") }
        return ScreenItem(app: String(localized: "Note"), kind: .overview, title: folder, details: String(localized: "\(notes.count) note"), text: lines.joined(separator: "\n"),
                          nouns: ["note", "nota", "appunti"])
    }

    // MARK: Calendario

    static func event(_ event: CalendarEvent, notes: String?) -> ScreenItem {
        var details = event.isAllDay ? when(event.start, time: false) + String(localized: ", tutto il giorno")
            : String(localized: "\(when(event.start)) – \(event.end.formatted(.dateTime.hour().minute().locale(Dates.locale)))")
        if let location = event.location, !location.isEmpty { details += ", \(location)" }
        details += String(localized: ", calendario \(event.calendarTitle)")
        var item = ScreenItem(app: String(localized: "Calendario"), kind: .event, title: event.title, details: details, text: notes ?? "", reference: event.id)
        item.event = EventItem(id: event.id, identifier: event.identifier, title: event.title, start: event.start, end: event.end,
                               isAllDay: event.isAllDay, calendar: event.calendarTitle, color: event.color, location: event.location)
        return item
    }

    static func calendar(range: String, events: [CalendarEvent]) -> ScreenItem {
        let lines = events.sorted { $0.start < $1.start }.prefix(30).map { event in
            "\(when(event.start, time: !event.isAllDay)) — \(event.title)" + ((event.location ?? "").isEmpty ? "" : " (\(event.location!))")
        }
        return ScreenItem(app: String(localized: "Calendario"), kind: .overview, title: range, details: events.isEmpty ? String(localized: "nessun evento") : String(localized: "\(events.count) eventi"),
                          text: lines.joined(separator: "\n"), nouns: ["eventi", "impegni", "appuntamenti", "riunioni", "agenda", "calendario"])
    }

    // MARK: Promemoria

    static func reminder(_ entry: ReminderEntry) -> ScreenItem {
        var details = String(localized: "lista \(entry.listTitle)")
        if let due = entry.due { details += String(localized: ", scade \(when(due, time: entry.dueHasTime))") }
        if entry.priority != .none { details += String(localized: ", priorità \(entry.priority.label.lowercased())") }
        if entry.isCompleted { details += String(localized: ", completato") }
        var item = ScreenItem(app: String(localized: "Promemoria"), kind: .reminder, title: entry.title, details: details,
                              text: [entry.notes, entry.url].filter { !$0.isEmpty }.joined(separator: "\n"), reference: entry.id)
        item.reminder = ReminderItem(id: entry.id, title: entry.title, list: entry.listTitle, due: entry.due, dueHasTime: entry.dueHasTime,
                                     highPriority: entry.priority == .high, color: entry.color)
        return item
    }

    static func reminders(list: String, entries: [ReminderEntry]) -> ScreenItem {
        let open = entries.filter { !$0.isCompleted }
        let lines = open.prefix(25).map { entry in
            entry.title + (entry.due.map { String(localized: " (scade \(when($0, time: entry.dueHasTime)))") } ?? "")
        }
        return ScreenItem(app: String(localized: "Promemoria"), kind: .overview, title: String(localized: "lista «\(list)»"), details: String(localized: "\(open.count) da fare"),
                          text: lines.joined(separator: "\n"), nouns: ["promemoria", "cose da fare", "attività", "lista"])
    }

    // MARK: Contatti

    static func contact(_ card: ContactCard) -> ScreenItem {
        var lines: [String] = []
        if !card.organization.isEmpty { lines.append(String(localized: "Azienda: \(card.organization)") + (card.jobTitle.isEmpty ? "" : ", \(card.jobTitle)")) }
        lines += card.phones.map { String(localized: "Telefono (\($0.localizedLabel)): \($0.value)") }
        lines += card.emails.map { String(localized: "Email (\($0.localizedLabel)): \($0.value)") }
        lines += card.addresses.filter { !$0.isEmpty }.map { String(localized: "Indirizzo: \($0.oneLine)") }
        lines += card.urls.map { String(localized: "Sito: \($0.value)") }
        if let birthday = card.birthday, let month = birthday.month, let day = birthday.day {
            var parts = DateComponents(year: birthday.year ?? 2000, month: month, day: day)
            parts.calendar = Calendar(identifier: .gregorian)
            if let date = parts.date {
                lines.append(String(localized: "Compleanno: ") + date.formatted(.dateTime.day().month(.wide).locale(Dates.locale)) + (birthday.year.map { " \($0)" } ?? ""))
            }
        }
        var item = ScreenItem(app: String(localized: "Contatti"), kind: .contact, title: card.displayName,
                              details: [card.organization, card.jobTitle].filter { !$0.isEmpty }.joined(separator: ", "),
                              text: lines.joined(separator: "\n"), reference: card.id)
        item.recipientName = card.displayName
        let mobile = card.phones.first { ["cellulare", "mobile", "iphone"].contains(where: $0.localizedLabel.lowercased().contains) } ?? card.phones.first
        item.phone = mobile?.value
        item.email = card.emails.first?.value
        return item
    }

    // MARK: Messaggi

    static func chat(_ chat: ChatSummary, messages: [ChatMessage]) -> ScreenItem {
        let lines = messages.suffix(20).map { message in
            let who = message.fromMe ? String(localized: "Io") : (message.sender.isEmpty ? chat.title : message.sender)
            return "\(who): \(message.text.isEmpty && message.hasAttachment ? String(localized: "[allegato]") : message.text)"
        }
        var item = ScreenItem(app: String(localized: "Messaggi"), kind: .chat, title: chat.title,
                              details: chat.isGroup ? String(localized: "gruppo con \(chat.handles.count) persone") : (chat.handles.first ?? ""),
                              text: lines.joined(separator: "\n"), reference: chat.guid)
        item.recipientName = chat.title
        if !chat.isGroup { item.phone = chat.handles.first }
        return item
    }

    static func chats(_ chats: [ChatSummary]) -> ScreenItem {
        let lines = chats.prefix(15).map { "\($0.unread > 0 ? "• " : "")\($0.title): \($0.lastFromMe ? "Io: " : "")\($0.lastText.prefix(80)) (\($0.date.listStamp))" }
        return ScreenItem(app: String(localized: "Messaggi"), kind: .overview, title: String(localized: "conversazioni"), details: String(localized: "\(chats.count) conversazioni"),
                          text: lines.joined(separator: "\n"), nouns: ["conversazioni", "messaggi", "chat"])
    }

    // MARK: File

    /// Il file selezionato con l'inizio del testo (documenti, PDF, testo), letto fuori dal thread principale.
    static func file(_ entry: FileEntry) async -> ScreenItem {
        let size = entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let details = [entry.kind, size, entry.modified.map { String(localized: "modificato \($0.listStamp)") }].compactMap { $0 }.joined(separator: ", ")
        let path = entry.url.path
        let text = entry.isFolder ? "" : await Task.detached(priority: .utility) { (try? FileSearch.read(path, maxChars: 6000)) ?? "" }.value
        return ScreenItem(app: String(localized: "File"), kind: .file, title: entry.name, details: details + String(localized: ", in \(entry.url.deletingLastPathComponent().path)"),
                          text: text, reference: path)
    }

    static func folder(_ url: URL, entries: [FileEntry]) -> ScreenItem {
        let lines = entries.prefix(40).map { ($0.isFolder ? String(localized: "[cartella] ") : "") + $0.name }
        return ScreenItem(app: String(localized: "File"), kind: .overview, title: String(localized: "cartella «\(url.lastPathComponent)»"), details: url.path,
                          text: lines.joined(separator: "\n"), nouns: ["file", "cartella", "documenti"])
    }

    // MARK: Memo Vocali

    static func memo(_ memo: VoiceMemo, transcript: String?) -> ScreenItem {
        ScreenItem(app: String(localized: "Memo Vocali"), kind: .memo, title: memo.title,
                   details: String(localized: "\(when(memo.date)), durata \(memo.durationText)"),
                   text: transcript ?? String(localized: "(senza trascrizione: si ottiene con «Trascrivi»)"), reference: memo.id)
    }

    static func memos(_ memos: [VoiceMemo]) -> ScreenItem {
        let lines = memos.prefix(15).map { "\($0.title) (\($0.date.listStamp), \($0.durationText))" + ($0.preview.map { ": \($0.prefix(80))" } ?? "") }
        return ScreenItem(app: String(localized: "Memo Vocali"), kind: .overview, title: String(localized: "registrazioni"), details: String(localized: "\(memos.count) registrazioni"),
                          text: lines.joined(separator: "\n"), nouns: ["registrazioni", "memo", "audio"])
    }

    // MARK: Suggerimenti

    /// Richieste pronte su ciò che è selezionato, per la chat a destra.
    var suggestions: [String] {
        let first = (recipientName ?? title).split(separator: " ").first.map(String.init) ?? title
        // «Rispondi ad Anna», «scrivi a Marco».
        // In inglese la preposizione è sempre «to» («Reply to Anna»).
        let to = Language.system == .en ? "to" : first.lowercased().first.map { "aeiouàèéìòù".contains($0) } == true ? "ad" : "a"
        switch kind {
        case .email:
            // Alle notifiche automatiche («noreply@…») non si risponde.
            return (mail?.isAutomatic == true ? [] : [String(localized: "Rispondi \(to) \(first)")])
                + [String(localized: "Riassumi questa email"), String(localized: "Crea un promemoria da questa email"), String(localized: "Aggiungi al calendario l'appuntamento di questa email")]
        case .note: return [String(localized: "Riassumi questa nota"), String(localized: "Crea un documento da questa nota"), String(localized: "Crea i promemoria delle cose da fare di questa nota")]
        case .event: return [String(localized: "Sposta questo evento di un'ora"), String(localized: "Scrivi un'email ai partecipanti di questo evento"), String(localized: "Cosa ho prima di questo evento?")]
        case .reminder: return [String(localized: "Segna questo promemoria come fatto"), String(localized: "Rimanda questo promemoria a domani"), String(localized: "Dividi questo promemoria in passi più piccoli")]
        case .contact:
            // Solo ciò che il contatto permette: messaggio con un numero, email con un indirizzo.
            return (phone == nil ? [] : [String(localized: "Scrivi un messaggio \(to) \(first)")]) + (email == nil ? [] : [String(localized: "Scrivi un'email \(to) \(first)")])
                + [String(localized: "Crea un promemoria per richiamare \(first)")]
        case .chat: return [String(localized: "Riassumi questa conversazione"), String(localized: "Rispondi che arrivo tra 10 minuti"), String(localized: "C'è qualcosa a cui devo rispondere in questa conversazione?")]
        case .file: return [String(localized: "Riassumi questo file"), String(localized: "Quali sono i punti principali di questo file?"), String(localized: "Crea una nota con i punti chiave di questo file")]
        case .memo: return [String(localized: "Riassumi questa registrazione"), String(localized: "Crea una nota da questa registrazione"), String(localized: "Quali cose da fare ci sono in questa registrazione?")]
        case .overview: return []
        }
    }

    // MARK: Pages, Numbers, Keynote

    static func documents(_ kind: ArtifactKind, entries: [AppState.DocumentEntry]) -> ScreenItem {
        let lines = entries.prefix(20).map { "\($0.artifact.title) (\($0.date.listStamp))" }
        return ScreenItem(app: kind.app, kind: .overview, title: kind.countLabel(entries.count), text: lines.joined(separator: "\n"),
                          nouns: ["documenti", "fogli", "presentazioni", "file"])
    }
}
