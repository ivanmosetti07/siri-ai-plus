import Foundation

// MARK: - Mondo inventato dei banchi di prova
//
// Con `FixtureWorld.active` impostato (solo dai banchi della CLI) i servizi dei dati — calendario, promemoria, email, note,
// messaggi, file, contatti, conversazioni passate, web — rispondono con dati inventati (`Support/eval/mondo-prova.json`,
// date relative a oggi). Così Apple Intelligence e i modelli esterni fanno girare il vero codice dell'app su dati finti,
// e ogni accesso ai dati veri rimasto (AppleScript, EventKit, Spotlight, database di Messaggi, Contatti) va a vuoto e
// viene contato. Il mondo registra anche gli strumenti chiamati e le schede preparate, per confrontare i modelli.

public final class FixtureWorld: @unchecked Sendable {
    /// Il mondo del banco in corso (nil nell'app).
    nonisolated(unsafe) public static var active: FixtureWorld?

    // MARK: Dati

    /// Un giorno relativo a oggi: un numero (0 oggi, 1 domani, -3 tre giorni fa) o un giorno della settimana («venerdì»,
    /// il prossimo; oggi se è oggi).
    enum Day: Decodable {
        case offset(Int)
        case weekday(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let offset = try? container.decode(Int.self) { self = .offset(offset) } else { self = .weekday(try container.decode(String.self)) }
        }

        func date(from today: Date) -> Date {
            let calendar = Calendar.current
            switch self {
            case .offset(let days):
                return calendar.date(byAdding: .day, value: days, to: today) ?? today
            case .weekday(let name):
                let names = ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"]
                guard let index = names.firstIndex(of: name.lowercased()) else { return today }
                let current = calendar.component(.weekday, from: today) - 1
                return calendar.date(byAdding: .day, value: (index - current + 7) % 7, to: today) ?? today
            }
        }
    }

    struct Event: Decodable {
        var titolo: String
        var giorno: Day
        var inizio: String?
        var fine: String?
        var calendario: String?
        var luogo: String?
    }

    struct Reminder: Decodable {
        var titolo: String
        var giorno: Day?
        var ora: String?
        var lista: String?
        var importante: Bool?
    }

    struct Mail: Decodable {
        var id: String
        var oggetto: String
        var mittente: String
        var giorni_fa: Int
        var testo: String
        var non_letta: Bool?
    }

    struct Note: Decodable {
        var id: String
        var titolo: String
        var cartella: String?
        var testo: String
    }

    struct Chat: Decodable {
        var persona: String
        var recapito: String
        var testo: String
        var minuti_fa: Int
        var mio: Bool?
    }

    struct File: Decodable {
        var percorso: String
        var testo: String
    }

    struct Contact: Decodable {
        var nome: String
        var email: String?
        var telefono: String?
    }

    struct PastChat: Decodable {
        var titolo: String
        var giorni_fa: Int
        var testo: String
    }

    struct Page: Decodable {
        var parole: [String]
        var titolo: String
        var url: String
        var testo: String
    }

    struct Contents: Decodable {
        var utente: String
        var calendari: [String]
        var liste: [String]
        var eventi: [Event]
        var promemoria: [Reminder]
        var email: [Mail]
        var note: [Note]
        var messaggi: [Chat]
        var file: [File]
        var contatti: [Contact]
        var conversazioni: [PastChat]
        var web: [Page]
    }

    let data: Contents
    /// Oggi all'avvio del banco (tutte le date sono relative a questo giorno).
    let today: Date
    /// true: il web vero (`--web-reale`), altrimenti le pagine inventate.
    public var realWeb = false

    public var userName: String { data.utente }

    public init(file: URL, now: Date = .now) throws {
        data = try JSONDecoder().decode(Contents.self, from: Foundation.Data(contentsOf: file))
        today = Calendar.current.startOfDay(for: now)
    }

    // MARK: Registro del caso in corso

    /// Una chiamata a uno strumento (modelli esterni) o un'azione eseguita (Apple Intelligence), con i campi normalizzati.
    public struct Call: Codable, Sendable, Equatable {
        /// Nome dello strumento come lo vedono i modelli esterni («agenda», «crea_evento», «mcp:list_tasks»).
        public var tool: String
        /// Argomenti (letture) o campi della bozza preparata (scritture), in testo.
        public var fields: [String: String]
        /// La scheda preparata («evento», «promemoria», «email», «connettore»…), nil per le letture.
        public var card: String?
        public var ok: Bool
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var blockedAccesses: [String] = []

    public func reset() { lock.withLock { calls = []; blockedAccesses = [] } }
    public var recorded: [Call] { lock.withLock { calls } }
    public var blocked: [String] { lock.withLock { blockedAccesses } }

    func record(_ call: Call) { lock.withLock { calls.append(call) } }

    /// Un accesso ai dati veri durante il banco: non parte, e il caso lo segnala.
    func block(_ what: String) {
        lock.withLock { blockedAccesses.append(what) }
        Agent.log("BANCO BLOCCATO: \(what)")
    }

    /// Accesso ai dati veri nel banco: errore da lanciare (il chiamante non deve leggere né scrivere niente di vero).
    static func refuse(_ what: String) -> Error? {
        guard let world = active else { return nil }
        world.block(what)
        return AppleAppError.script("BLOCCATO: \(what) (banco di prova)")
    }

    // MARK: Registrazione dagli strumenti e dalle azioni

    /// Uno strumento chiamato da un modello esterno (fine di `runTool`).
    @MainActor
    func recordTool(_ name: String, arguments: JSONValue, result: ToolCallResult) {
        // I connettori si registrano con la loro etichetta quando partono o diventano una scheda (`recordConnector`).
        guard !name.hasPrefix("mcp__") else { return }
        var fields: [String: String] = [:]
        for (key, value) in arguments.object ?? [:] { fields[key] = value.string ?? value.compactString }
        var card: String?
        if let outcome = result.outcome, !Assistant.isObservation(outcome) {
            let normalized = Self.normalize(outcome)
            card = normalized.card
            fields.merge(normalized.fields) { _, draft in draft }
        }
        record(Call(tool: name, fields: fields, card: card, ok: result.ok))
    }

    /// Un'azione eseguita dalla strada di Apple Intelligence (dopo `execute` nel ciclo della richiesta).
    @MainActor
    func recordAction(_ plan: Assistant.Plan, outcome: Outcome) {
        guard let tool = ToolRegistry.toolName(forAction: plan.action) else { return }
        // I connettori si registrano chiamata per chiamata (`Assistant.connectorCalls`), non qui.
        if plan.action == .strumento_esterno { return }
        var fields = plan.fields
        var card: String?
        var ok = true
        switch outcome {
        case .message, .unavailable: ok = false
        default: break
        }
        if !Assistant.isObservation(outcome), ok {
            let normalized = Self.normalize(outcome)
            card = normalized.card
            fields.merge(normalized.fields) { _, draft in draft }
        }
        record(Call(tool: tool, fields: fields, card: card, ok: ok))
    }

    /// Una lettura fatta dall'app al posto di quella chiesta (Messaggi vuoti → la posta): nel banco conta come quella lettura.
    func recordRead(_ tool: String, search: String) {
        record(Call(tool: tool, fields: ["cerca": search, "ripiego": "sì"], card: nil, ok: true))
    }

    /// Una chiamata a un connettore (strada di Apple e connettori finti del banco).
    @MainActor
    func recordConnector(_ draft: MCPCallDraft, held: Bool) {
        record(Call(tool: "mcp:" + Assistant.callLabel(draft), fields: ["argomenti": draft.arguments.compactString],
                    card: held ? "connettore" : nil, ok: true))
    }

    /// Campi confrontabili di una bozza, uguali per Apple e per i modelli esterni.
    @MainActor
    static func normalize(_ outcome: Outcome) -> (card: String?, fields: [String: String]) {
        let kind = Assistant.kind(of: outcome)
        let card = kind.hasPrefix("scheda:") ? String(kind.dropFirst("scheda:".count)) : kind
        func when(_ date: Date?, time: Bool) -> String {
            guard let date else { return "" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = time ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        switch outcome {
        case .eventDraft(let draft):
            return (card, ["titolo": draft.title, "inizio": when(draft.start, time: !draft.isAllDay), "fine": when(draft.end, time: !draft.isAllDay),
                           "luogo": draft.location, "calendario": draft.calendar])
        case .reminderDrafts(let drafts, let list):
            return (card, ["titoli": drafts.map(\.title).joined(separator: " | "),
                           "scadenza": drafts.first.map { when($0.due, time: $0.dueHasTime) } ?? "", "lista": list])
        case .mailDraft(let draft):
            return (card, ["destinatari": draft.recipients.joined(separator: ", "), "oggetto": draft.subject, "testo": draft.body])
        case .messageDraft(let draft):
            return (card, ["destinatario": draft.recipient, "recapito": draft.handle, "testo": draft.text])
        case .noteDraft(let draft):
            return (card, ["titolo": draft.title, "testo": draft.body])
        case .noteAppend(let draft):
            return (card, ["titolo": draft.title, "testo": draft.lines.joined(separator: "\n")])
        case .eventEdit(let edit):
            return (card, ["titolo": edit.after.title, "prima": when(edit.before.start, time: !edit.before.isAllDay),
                           "inizio": when(edit.after.start, time: !edit.after.isAllDay), "fine": when(edit.after.end, time: !edit.after.isAllDay)])
        case .reminderEdit(let edit):
            return (card, ["titolo": edit.after.title, "scadenza": when(edit.after.due, time: edit.after.dueHasTime), "lista": edit.afterList])
        case .mailReply(let draft):
            return (card, ["destinatari": draft.to, "oggetto": draft.subject, "testo": draft.body])
        case .mailForward(let draft):
            return (card, ["destinatari": draft.recipientName + " " + draft.recipientAddress, "oggetto": draft.subject])
        case .confirm(let action):
            return (card, ["azione": String(describing: action).prefix(300).description])
        case .mcpCall(let draft):
            return ("connettore", ["strumento": Assistant.callLabel(draft), "argomenti": draft.arguments.compactString])
        case .sheet(let draft):
            return (card, ["titolo": draft.title, "colonne": draft.columns.joined(separator: " | ")])
        case .deck(let draft):
            return (card, ["titolo": draft.title])
        case .document(let draft):
            return (card, ["titolo": draft.title])
        case .image(let prompt, let style):
            return (card, ["argomento": prompt, "stile": style ?? ""])
        case .fileWrite(let draft):
            return (card, ["percorso": draft.path])
        case .fileOp(let draft):
            return (card, ["da": draft.from, "a": draft.to])
        case .remembered(let fact, _):
            return ("ricordo", ["fatto": fact])
        case .artifactEdit:
            return ("modifica", [:])
        case .combined(let items):
            return items.last.map(normalize) ?? (card, [:])
        default:
            return (card, [:])
        }
    }

    // MARK: Calendario e promemoria

    private func time(_ text: String?, on day: Date) -> Date? {
        guard let text, let hour = Int(text.prefix(2)), let minute = Int(text.suffix(2)) else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private static let colors = [RGB(red: 0.2, green: 0.45, blue: 0.95), RGB(red: 0.95, green: 0.55, blue: 0.1), RGB(red: 0.3, green: 0.7, blue: 0.35)]

    private func color(_ name: String) -> RGB { Self.colors[abs(name.hashValue) % Self.colors.count] }

    var allEvents: [EventItem] {
        data.eventi.enumerated().map { index, event in
            let day = event.giorno.date(from: today)
            let start = time(event.inizio, on: day) ?? day
            let end = time(event.fine, on: day) ?? (event.inizio == nil ? day.addingTimeInterval(86_399) : start.addingTimeInterval(3600))
            let calendar = event.calendario ?? data.calendari.first ?? "Lavoro"
            let identifier = "EVT-\(index + 1)"
            return EventItem(id: identifier + "\(start.timeIntervalSince1970)", identifier: identifier, title: event.titolo, start: start, end: end,
                             isAllDay: event.inizio == nil, calendar: calendar, color: color(calendar), location: event.luogo)
        }
    }

    func events(from start: Date, to end: Date) -> [EventItem] {
        allEvents.filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start }
    }

    func openReminders(limit: Int, list: String?) -> [ReminderItem] {
        let items = data.promemoria.enumerated().map { index, reminder -> ReminderItem in
            let day = reminder.giorno?.date(from: today)
            let due = day.map { time(reminder.ora, on: $0) ?? $0 }
            let listName = reminder.lista ?? data.liste.first ?? "Promemoria"
            return ReminderItem(id: "REM-\(index + 1)", title: reminder.titolo, list: listName, due: due, dueHasTime: reminder.ora != nil,
                                highPriority: reminder.importante ?? false, color: color(listName))
        }
        let filtered = list.map { name in items.filter { $0.list.localizedCaseInsensitiveContains(name) } } ?? items
        return Array(filtered.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(limit))
    }

    var calendars: [String] { data.calendari }
    var reminderLists: [String] { data.liste }

    // MARK: Email

    private func mailDate(_ mail: Mail) -> Date {
        Calendar.current.date(byAdding: .day, value: -mail.giorni_fa, to: Date.now) ?? .now
    }

    private func matches(_ text: String, _ query: String?) -> Bool {
        guard let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else { return true }
        let folded = NotesService.fold(text)
        // Come le app: il testo intero, oppure (per ricerche di più parole) tutte le parole, senza gli articoli apostrofati
        // («contratto d'affitto» trova «Contratto affitto»).
        let words = NotesService.fold(query).split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 2 }
        return folded.contains(NotesService.fold(query)) || (!words.isEmpty && words.allSatisfy { folded.contains($0) })
    }

    func mailInbox(query: String?, unreadOnly: Bool, limit: Int) -> AppItems {
        // Come Mail: con le non lette conta solo lo stato; la ricerca usa lo stesso testo di `MailReader.inbox`.
        let term = unreadOnly ? nil : query.map(MailReader.searchTerm)
        let found = data.email.filter { mail in
            (!unreadOnly || mail.non_letta == true) && matches(mail.oggetto + " " + mail.mittente, term)
        }.sorted { $0.giorni_fa < $1.giorni_fa }
        let rows = found.prefix(limit).map { mail in
            AppItems.Row(id: mail.id, title: (mail.non_letta == true ? "● " : "") + mail.oggetto,
                         subtitle: "\(MailReader.senderName(mail.mittente)) · \(Dates.format(mailDate(mail)))", detail: String(mail.testo.prefix(500)), reference: mail.id)
        }
        return AppItems(source: .mail, title: MailReader.listTitle(query: query, unreadOnly: unreadOnly, account: nil), rows: Array(rows))
    }

    func mailFind(person: String?, subject: String?, limit: Int) -> [MailMessage] {
        let found = data.email.filter { mail in
            if let person, !person.isEmpty { return matches(mail.mittente, person) }
            if let subject, !subject.isEmpty { return matches(mail.oggetto, subject) }
            return true
        }.sorted { $0.giorni_fa < $1.giorni_fa }
        return found.prefix(limit).map(message)
    }

    private func message(_ mail: Mail) -> MailMessage {
        MailMessage(id: mail.id, subject: mail.oggetto, sender: mail.mittente, date: Dates.format(mailDate(mail)), content: mail.testo,
                    age: mail.giorni_fa * 1440)
    }

    func mailMessage(id: String) throws -> MailMessage {
        guard let mail = data.email.first(where: { $0.id == id }) else {
            throw AppleAppError.script(Language.t("Non riesco a leggere l'email.", "I can't read the email."))
        }
        return message(mail)
    }

    // MARK: Note, messaggi, file

    func notesSearch(_ query: String?, limit: Int) -> AppItems {
        let rows = data.note.filter { matches($0.titolo + " " + $0.testo, query) }.prefix(limit).map { note in
            AppItems.Row(id: note.id, title: note.titolo, subtitle: note.cartella ?? "Note", detail: String(note.testo.replacingOccurrences(of: "\n", with: " ").prefix(400)),
                         reference: note.id)
        }
        return AppItems(source: .notes, title: NotesService.listTitle(query), rows: Array(rows))
    }

    func noteSnapshot(id: String) throws -> NotesService.Snapshot {
        guard let note = data.note.first(where: { $0.id == id }) else { throw AppleAppError.script("Nota non trovata.") }
        let html = "<div><h1>\(note.titolo)</h1></div>" + note.testo.split(separator: "\n").map { "<div>\($0)</div>" }.joined()
        return NotesService.Snapshot(text: note.titolo + "\n" + note.testo, html: html, hasAttachments: false)
    }

    func messages(matching query: String?, limit: Int) -> AppItems {
        let rows = data.messaggi.filter { matches($0.persona + " " + $0.testo + " " + $0.recapito, query) }
            .sorted { $0.minuti_fa < $1.minuti_fa }.prefix(limit).enumerated().map { index, chat in
                AppItems.Row(id: "MSG-\(index + 1)", title: chat.mio == true ? Language.t("Tu → \(chat.persona)", "You → \(chat.persona)") : chat.persona,
                             subtitle: Dates.format(Date.now.addingTimeInterval(Double(-chat.minuti_fa * 60))), detail: chat.testo, reference: chat.recapito)
            }
        return AppItems(source: .messages, title: MessagesService.listTitle(query), rows: Array(rows))
    }

    func fileSearch(_ query: String, limit: Int) -> AppItems {
        let rows = data.file.filter { matches(($0.percorso as NSString).lastPathComponent + " " + $0.testo, query) }.prefix(limit).map { file in
            AppItems.Row(id: file.percorso, title: (file.percorso as NSString).lastPathComponent,
                         subtitle: (file.percorso as NSString).deletingLastPathComponent, reference: file.percorso)
        }
        return AppItems(source: .files, title: FileSearch.listTitle(query), rows: Array(rows))
    }

    func fileRead(_ path: String, maxChars: Int) throws -> String {
        guard let file = data.file.first(where: { $0.percorso == path || ($0.percorso as NSString).lastPathComponent == (path as NSString).lastPathComponent }) else {
            throw AppleAppError.script("File non trovato.")
        }
        return String(file.testo.prefix(maxChars))
    }

    // MARK: Contatti

    private func contacts(named name: String) -> [Contact] {
        let folded = NotesService.fold(name)
        guard folded.count >= 2 else { return [] }
        return data.contatti.filter { NotesService.fold($0.nome).contains(folded) || folded.contains(NotesService.fold($0.nome)) }
    }

    func contactHandles(_ name: String) -> [String] {
        contacts(named: name).prefix(3).flatMap { [$0.telefono, $0.email].compactMap { $0 } }
    }

    func contactEmails(_ name: String) -> [(name: String, address: String)] {
        contacts(named: name).prefix(4).compactMap { contact in contact.email.map { (contact.nome, $0) } }
    }

    func contactName(_ handle: String) -> String? {
        data.contatti.first { $0.email == handle || $0.telefono == handle }?.nome
    }

    // MARK: Conversazioni passate e web

    func conversations(_ query: String, limit: Int) -> [ConversationIndex.Hit] {
        data.conversazioni.filter { matches($0.titolo + " " + $0.testo, query) }.prefix(limit).enumerated().map { index, chat in
            ConversationIndex.Hit(id: "CONV-\(index + 1)", title: chat.titolo, snippet: String(chat.testo.prefix(300)),
                                  date: Calendar.current.date(byAdding: .day, value: -chat.giorni_fa, to: .now) ?? .now)
        }
    }

    /// Pagine inventate: quelle con parole in comune con la ricerca, altrimenti una pagina generica sulla ricerca.
    func webSearch(_ query: String, limit: Int) -> [WebSource] {
        let folded = NotesService.fold(query)
        let pages = data.web.filter { page in page.parole.contains { folded.contains(NotesService.fold($0)) } }
        if pages.isEmpty {
            return [WebSource(title: "Risultati per «\(query)»", url: "https://example.com/ricerca?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")",
                              snippet: "Pagina di prova del banco: nessun risultato specifico per questa ricerca.")]
        }
        return pages.prefix(limit).map { WebSource(title: $0.titolo, url: $0.url, snippet: String($0.testo.prefix(240))) }
    }

    func webFetch(_ url: URL) -> Web.Page {
        if let page = data.web.first(where: { $0.url == url.absoluteString }) { return Web.Page(url: page.url, title: page.titolo, text: page.testo) }
        return Web.Page(url: url.absoluteString, title: "Pagina di prova", text: "Pagina di prova del banco: nessun contenuto specifico.")
    }
}
