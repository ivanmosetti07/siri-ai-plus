import Contacts
import Foundation
import SQLite3

/// Elementi letti da un'app (note, email, file, messaggi), mostrati in una scheda e passati al modello.
public struct AppItems: Codable, Sendable, Equatable {
    public struct Row: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var subtitle: String
        public var detail: String
        /// Percorso di un file o identificativo nell'app, per aprirlo.
        public var reference: String?

        public init(id: String, title: String, subtitle: String, detail: String = "", reference: String? = nil) {
            self.id = id; self.title = title; self.subtitle = subtitle; self.detail = detail; self.reference = reference
        }
    }

    public var source: SourceKind
    public var title: String
    public var rows: [Row]

    public init(source: SourceKind, title: String, rows: [Row]) {
        self.source = source; self.title = title; self.rows = rows
    }

    /// Testo per il modello, con numeri brevi per i riferimenti successivi.
    public var digest: String {
        rows.isEmpty ? Language.t("\(title): nessun risultato", "\(title): no results") : "\(title):\n" + rows.enumerated().map { index, row in
            "\(index + 1). \(row.title) — \(row.subtitle)" + (row.detail.isEmpty ? "" : "\n   \(row.detail.prefix(360))")
        }.joined(separator: "\n")
    }
}

public struct NoteDraft: Codable, Sendable, Equatable {
    public var title: String
    public var body: String
    public init(title: String, body: String) { self.title = title; self.body = body }
}

public struct MessageDraft: Codable, Sendable, Equatable {
    public var recipient: String
    /// Numero o email risolti dai Contatti (vuoto = da completare).
    public var handle: String
    public var text: String
    public init(recipient: String, handle: String, text: String) { self.recipient = recipient; self.handle = handle; self.text = text }
}

/// Testo da aggiungere in fondo a una nota esistente.
public struct NoteAppendDraft: Codable, Sendable, Equatable {
    public var noteID: String
    public var title: String
    public var lines: [String]
    /// La nota ha liste (forse con caselle), tabelle o allegati: Note non permette di aggiungere senza perderli.
    public var manual: Bool
    /// Ultime righe della nota, per vedere dove finisce.
    public var tail: [String]

    public init(noteID: String, title: String, lines: [String], manual: Bool, tail: [String]) {
        self.noteID = noteID; self.title = title; self.lines = lines; self.manual = manual; self.tail = tail
    }
}

/// Email ricevuta, con il testo completo.
public struct MailMessage: Codable, Sendable, Equatable {
    public var id: String
    public var subject: String
    /// "Mario Rossi <mario@esempio.it>"
    public var sender: String
    /// Data come la scrive Mail.
    public var date: String
    public var content: String
    /// Secondi da quando è arrivata (per ordinare).
    public var age: Int

    public init(id: String, subject: String, sender: String, date: String, content: String = "", age: Int = 0) {
        self.id = id; self.subject = subject; self.sender = sender; self.date = date; self.content = content; self.age = age
    }

    public var senderName: String { MailReader.senderName(sender) }
    /// Notifiche automatiche ("noreply@…"): non ricevono risposte.
    public var isAutomatic: Bool {
        let address = senderAddress.lowercased()
        return ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "mailer-daemon", "notifications@", "notification@", "postmaster@"]
            .contains(where: address.contains)
    }
    public var senderAddress: String {
        if let open = sender.lastIndex(of: "<"), let close = sender.lastIndex(of: ">"), open < close {
            return String(sender[sender.index(after: open)..<close])
        }
        return sender.contains("@") ? sender.trimmingCharacters(in: .whitespaces) : ""
    }
    /// "21 settembre 2026 alle 10:15"
    public var shortDate: String {
        if let g = Calculations.matches(#"(\d{1,2} \S+ \d{4})(?:,)? (?:alle ore |alle |ore )?(\d{1,2}[:.]\d{2})"#, in: date).first { return "\(g[1]) alle \(g[2])" }
        return date
    }
}

/// Risposta a un'email: si apre in Mail nella stessa conversazione, l'utente la invia da lì.
public struct MailReplyDraft: Codable, Sendable, Equatable {
    public var messageID: String
    public var to: String
    public var subject: String
    public var body: String
    /// "Il giorno …, Mario ha scritto:" e il messaggio originale citato.
    public var quote: String
    public var replyAll: Bool

    public init(messageID: String, to: String, subject: String, body: String, quote: String, replyAll: Bool = false) {
        self.messageID = messageID; self.to = to; self.subject = subject; self.body = body; self.quote = quote; self.replyAll = replyAll
    }
}

/// Inoltro di un'email (con gli allegati): si apre in Mail con il destinatario, l'utente la invia da lì.
public struct MailForwardDraft: Codable, Sendable, Equatable {
    public var messageID: String
    public var subject: String
    public var from: String
    public var date: String
    public var recipientName: String
    public var recipientAddress: String

    public init(messageID: String, subject: String, from: String, date: String, recipientName: String, recipientAddress: String) {
        self.messageID = messageID; self.subject = subject; self.from = from; self.date = date
        self.recipientName = recipientName; self.recipientAddress = recipientAddress
    }
}

public enum AppleAppError: LocalizedError {
    case script(String), notAllowed(String), fullDiskAccess, noRecipient

    public var errorDescription: String? {
        switch self {
        case .script(let message): message
        case .notAllowed(let app): Language.t("Siri AI+ non ha il permesso di usare \(app): Impostazioni di Sistema › Privacy e sicurezza › Automazione.",
                                              "Siri AI+ doesn't have permission to use \(Self.appName(app)): System Settings › Privacy & Security › Automation.")
        case .fullDiskAccess: Language.t("Per leggere i Messaggi serve l'accesso completo al disco per Siri AI+: Impostazioni di Sistema › Privacy e sicurezza › Accesso completo al disco.",
                                         "To read Messages, Siri AI+ needs Full Disk Access: System Settings › Privacy & Security › Full Disk Access.")
        case .noRecipient: Language.t("Non trovo il destinatario tra i Contatti: indica numero o email.",
                                      "I can't find the recipient in Contacts: give a number or an email address.")
        }
    }

    /// Nome dell'app nei messaggi: chi usa AppleScript passa i nomi italiani («Note», «Messaggi»), in inglese diventano quelli di macOS.
    static func appName(_ app: String, _ language: Language = Language.current) -> String {
        guard language == .en else { return app }
        return ["Note": "Notes", "Messaggi": "Messages", "Promemoria": "Reminders", "Calendario": "Calendar", "Contatti": "Contacts"][app] ?? app
    }
}

/// Esegue AppleScript con `osascript` fuori dal thread principale (Mail e Note possono metterci qualche secondo).
public enum AppleScript {
    static let field = "\u{1F}"
    static let record = "\u{1E}"

    /// Il processo di `osascript`, da fermare se chi l'ha chiesto non aspetta più.
    private final class Running: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var stopped = false

        var wasStopped: Bool { lock.withLock { stopped } }

        func stop() {
            lock.withLock { stopped = true }
            if process.isRunning { process.terminate() }
        }
    }

    /// Esegue lo script. Se il compito viene annullato (per esempio si esce dalla sezione) o passa `timeout`,
    /// `osascript` si ferma: niente richieste lente che continuano in sottofondo.
    static func run(_ source: String, app: String, timeout: TimeInterval = 120) async throws -> String {
        // Banco di prova: Mail, Note e Messaggi veri non si toccano mai.
        if let refused = FixtureWorld.refuse("AppleScript verso \(app)") { throw refused }
        let running = Running()
        // I messaggi d'errore nascono su una coda di GCD, fuori dal compito: la lingua della richiesta si prende qui.
        let language = Language.current
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = running.process
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", source]
                    let output = Pipe(), errors = Pipe()
                    process.standardOutput = output
                    process.standardError = errors
                    do { try process.run() } catch {
                        continuation.resume(throwing: AppleAppError.script(error.localizedDescription))
                        return
                    }
                    if running.wasStopped { process.terminate() }
                    let deadline = DispatchWorkItem { running.stop() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    process.waitUntilExit()
                    deadline.cancel()
                    if running.wasStopped {
                        let message = language == .en ? "\(AppleAppError.appName(app, language)) didn't respond in time." : "\(app) non ha risposto in tempo."
                        continuation.resume(throwing: AppleAppError.script(message))
                        return
                    }
                    if process.terminationStatus != 0 {
                        // -1743: l'utente non ha autorizzato l'automazione.
                        if errorText.contains("-1743") || errorText.contains("Not authorized") {
                            continuation.resume(throwing: AppleAppError.notAllowed(app))
                        } else {
                            continuation.resume(throwing: AppleAppError.script("\(AppleAppError.appName(app, language)): \(errorText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))"))
                        }
                        return
                    }
                    continuation.resume(returning: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
                }
            }
        } onCancel: {
            running.stop()
        }
    }

    /// Espressione AppleScript sicura per un testo qualsiasi: virgolette e barre escapate, a capo e tabulazioni
    /// come `linefeed`/`return`/`tab` (un letterale AppleScript non può contenerli), altri caratteri di controllo tolti.
    /// Così un testo scritto dal modello o letto dal web non può uscire dalla stringa.
    public static func quote(_ text: String) -> String {
        var parts: [String] = []
        var literal = ""
        func flush() {
            parts.append("\"" + literal.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"")
            literal = ""
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": flush(); parts.append("linefeed")
            case "\r": flush(); parts.append("return")
            case "\t": flush(); parts.append("tab")
            case _ where scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029: continue
            default: literal.unicodeScalars.append(scalar)
            }
        }
        flush()
        let joined = parts.filter { $0 != "\"\"" || parts.count == 1 }.joined(separator: " & ")
        return parts.count == 1 ? joined : "(" + joined + ")"
    }

    static func records(_ output: String) -> [[String]] {
        output.components(separatedBy: record).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.components(separatedBy: field).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    }
}

// MARK: - Note

public enum NotesService {
    public struct Snapshot: Sendable {
        public let text: String
        public let html: String
        public let hasAttachments: Bool
    }

    /// Note recenti o che contengono `query` nel titolo o nel testo.
    public static func search(_ query: String?, limit: Int = 12) async throws -> AppItems {
        if let world = FixtureWorld.active { return world.notesSearch(query, limit: limit) }
        let needle = query ?? ""
        let script = """
        set sep to character id 31
        set rs to character id 30
        set out to ""
        set queryText to \(AppleScript.quote(needle))
        set added to 0
        tell application "Notes"
            set found to notes
            set n to count of found
            if n > 500 then set n to 500
            repeat with i from 1 to n
                set nt to item i of found
                set noteName to ""
                try
                    set noteName to name of nt
                end try
                set noteText to ""
                try
                    set noteText to plaintext of nt
                end try
                if queryText is "" or noteName contains queryText or noteText contains queryText then
                    if length of noteText > 500 then set noteText to text 1 thru 500 of noteText
                    set folderName to ""
                    try
                        set folderName to name of container of nt
                    end try
                    set out to out & (id of nt) & sep & noteName & sep & folderName & sep & ((modification date of nt) as string) & sep & noteText & rs
                    set added to added + 1
                    if added >= \(limit) then exit repeat
                end if
            end repeat
        end tell
        return out
        """
        let rows = AppleScript.records(try await AppleScript.run(script, app: "Note")).compactMap { f -> AppItems.Row? in
            guard f.count >= 5 else { return nil }
            let body = f[4].replacingOccurrences(of: "\n", with: " ")
            return AppItems.Row(id: f[0], title: f[1], subtitle: [f[2], shortDate(f[3])].filter { !$0.isEmpty }.joined(separator: " · "),
                                detail: String(body.prefix(400)), reference: f[0])
        }
        return AppItems(source: .notes, title: listTitle(query), rows: rows)
    }

    /// Titolo dell'elenco: le note che contengono un testo, o le recenti.
    static func listTitle(_ query: String?) -> String {
        query.map { Language.t("Note su «\($0)»", "Notes about “\($0)”") } ?? Language.t("Note recenti", "Recent notes")
    }

    /// Testo completo di una nota.
    public static func body(id: String) async throws -> String {
        try await snapshot(id: id).text
    }

    /// Legge testo e HTML originale: l'HTML è la versione usata per evitare di sovrascrivere modifiche esterne.
    public static func snapshot(id: String) async throws -> Snapshot {
        if let world = FixtureWorld.active { return try world.noteSnapshot(id: id) }
        // Nomi delle variabili diversi dalle proprietà di Note: AppleScript non distingue maiuscole e minuscole
        // («plainText» sarebbe la proprietà «plaintext» della nota, e Note proverebbe a cambiarla).
        let script = """
        tell application "Notes"
            set nt to note id \(AppleScript.quote(id))
            set theMarkup to body of nt
            set theWords to ""
            try
                set theWords to plaintext of nt
            end try
            return theWords & (character id 31) & theMarkup
        end tell
        """
        let output = try await AppleScript.run(script, app: "Note")
        let parts = output.split(separator: AppleScript.field.first!, maxSplits: 1, omittingEmptySubsequences: false)
        let html = parts.count == 2 ? String(parts[1]) : output
        let plain = parts.count == 2 ? String(parts[0]) : ""
        let fallback = html.replacingOccurrences(of: "(?i)<br\\s*/?>|</div>|</p>|</h[1-6]>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        let lower = html.lowercased()
        return Snapshot(text: plain.isEmpty ? fallback : plain, html: html,
                        hasAttachments: lower.contains("<object") || lower.contains("<img") || lower.contains("<table"))
    }

    /// Salva una nota testuale solo se il contenuto originale è ancora identico.
    public static func update(id: String, text: String, expectedHTML: String) async throws -> Snapshot {
        guard !expectedHTML.isEmpty else { throw AppleAppError.script(Language.t("Nota vuota o non leggibile: impossibile salvarla in sicurezza.", "Empty or unreadable note: it can't be saved safely.")) }
        let lines = text.components(separatedBy: "\n")
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let title = escape(lines.first ?? "")
        let paragraphs = lines.dropFirst().map { $0.isEmpty ? "<div><br></div>" : "<div>\(escape($0))</div>" }.joined()
        let newHTML = "<h1>\(title)</h1>\(paragraphs)"
        let script = """
        tell application "Notes"
            set nt to note id \(AppleScript.quote(id))
            if (body of nt) is not \(AppleScript.quote(expectedHTML)) then error "\(Language.t("La nota è stata modificata anche in Note. Ricaricala prima di salvare.", "The note was also changed in Notes. Reload it before saving."))" number 4001
            set body of nt to \(AppleScript.quote(newHTML))
            return body of nt
        end tell
        """
        let savedHTML = try await AppleScript.run(script, app: "Note")
        return Snapshot(text: text, html: savedHTML, hasAttachments: false)
    }

    /// Note con il nome nel titolo: prima quelle con il titolo uguale, poi le altre.
    public static func find(named name: String) async throws -> [AppItems.Row] {
        let target = fold(name)
        let rows = try await search(name, limit: 30).rows.filter { fold($0.title).contains(target) }
        return rows.sorted { (fold($0.title) == target ? 0 : 1, $0.title.count) < (fold($1.title) == target ? 0 : 1, $1.title.count) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Dates.locale).trimmingCharacters(in: .whitespaces)
    }

    /// Note riscrive tutto il testo quando lo si cambia da fuori: liste (le caselle spuntate sono solo di Note), tabelle e allegati si perderebbero.
    public static func canAppendSafely(_ html: String) -> Bool {
        let lower = html.lowercased()
        return !["<ul", "<ol", "<li", "<table", "<object", "<img", "<input", "checklist", "<attachment"].contains(where: lower.contains)
    }

    /// Aggiunge righe in fondo a una nota, solo se nel frattempo non è cambiata. Restituisce il testo di prima (per annullare).
    public static func append(id: String, lines: [String], expectedHTML: String) async throws -> Snapshot {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let addition = lines.map { "<div>\(escape($0))</div>" }.joined()
        var html = expectedHTML
        if let range = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            html.insert(contentsOf: addition, at: range.lowerBound)
        } else {
            html += addition
        }
        return try await replaceBody(id: id, html: html, expectedHTML: expectedHTML)
    }

    /// Sostituisce il contenuto della nota con `html` se è ancora `expectedHTML`.
    public static func replaceBody(id: String, html: String, expectedHTML: String) async throws -> Snapshot {
        guard !expectedHTML.isEmpty else { throw AppleAppError.script(Language.t("Nota vuota o non leggibile: impossibile modificarla in sicurezza.", "Empty or unreadable note: it can't be edited safely.")) }
        let script = """
        tell application "Notes"
            set nt to note id \(AppleScript.quote(id))
            if (body of nt) is not \(AppleScript.quote(expectedHTML)) then error "\(Language.t("La nota è stata modificata nel frattempo. Riprova.", "The note was changed in the meantime. Try again."))" number 4001
            set body of nt to \(AppleScript.quote(html))
            return body of nt
        end tell
        """
        let saved = try await AppleScript.run(script, app: "Note")
        return Snapshot(text: "", html: saved, hasAttachments: false)
    }

    @discardableResult
    public static func create(_ draft: NoteDraft) async throws -> String {
        let paragraphs = draft.body.components(separatedBy: "\n").map { line -> String in
            let escaped = line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            return line.isEmpty ? "<br>" : "<div>\(escaped)</div>"
        }.joined()
        let title = draft.title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = "<h1>\(title)</h1>\(paragraphs)"
        return try await AppleScript.run("tell application \"Notes\"\nset createdNote to make new note with properties {body:\(AppleScript.quote(html))}\nreturn id of createdNote\nend tell", app: "Note")
    }

    public static func open(id: String) async {
        _ = try? await AppleScript.run("tell application \"Notes\"\nshow note id \(AppleScript.quote(id))\nactivate\nend tell", app: "Note")
    }

    /// Chiede il permesso di automazione (la prima volta macOS mostra la richiesta).
    public static func requestAccess() async -> Bool {
        (try? await AppleScript.run("tell application \"Notes\" to return count of folders", app: "Note")) != nil
    }
}

// MARK: - Mail (lettura)

public enum MailReader {
    /// Il testo cercato nell'oggetto e nel mittente: di una parola sola si toglie la vocale finale, così singolare e plurale si
    /// trovano a vicenda («commercialista» trova «Studio Neri Commercialisti», «fattura» trova «Fatture di settembre»).
    public static func searchTerm(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6, !trimmed.contains(" "), let last = trimmed.lowercased().last, "aeiouàèéìòù".contains(last) else { return trimmed }
        return String(trimmed.dropLast())
    }

    /// Ultime email in arrivo, o quelle con `query` nell'oggetto o nel mittente.
    public static func inbox(query: String?, unreadOnly: Bool = false, limit: Int = 12, account: String? = SpaceScope.current.mailAccount) async throws -> AppItems {
        if let world = FixtureWorld.active { return world.mailInbox(query: query, unreadOnly: unreadOnly, limit: limit) }
        let selection: String
        if unreadOnly {
            selection = "(messages of theBox whose read status is false)"
        } else if let query, !query.isEmpty {
            let term = AppleScript.quote(searchTerm(query))
            selection = "(messages of theBox whose subject contains \(term) or sender contains \(term))"
        } else {
            selection = "(messages 1 thru \(limit) of theBox)"
        }
        // Con un account scelto dallo spazio si legge solo la sua posta in arrivo.
        let box = account.map { name in
            """
            set theBox to inbox
            try
                set theBox to mailbox "INBOX" of account \(AppleScript.quote(name))
            on error
                try
                    set theBox to mailbox "Inbox" of account \(AppleScript.quote(name))
                end try
            end try
            """
        } ?? "set theBox to inbox"
        let script = """
        set sep to character id 31
        set rs to character id 30
        set out to ""
        tell application "Mail"
            \(box)
            try
                set found to \(selection)
            on error
                set found to messages of theBox
            end try
            set n to count of found
            if n > \(limit) then set n to \(limit)
            repeat with i from 1 to n
                set m to item i of found
                set preview to ""
                if i ≤ 8 then
                    try
                        set preview to content of m
                        if length of preview > 600 then set preview to text 1 thru 600 of preview
                    end try
                end if
                set out to out & (id of m) & sep & (subject of m) & sep & (sender of m) & sep & ((date received of m) as string) & sep & (read status of m) & sep & preview & rs
            end repeat
        end tell
        return out
        """
        let rows = AppleScript.records(try await AppleScript.run(script, app: "Mail")).compactMap { f -> AppItems.Row? in
            guard f.count >= 6 else { return nil }
            let unread = f[4] == "false" ? "● " : ""
            let preview = f[5].replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
            return AppItems.Row(id: f[0], title: unread + (f[1].isEmpty ? Language.t("(senza oggetto)", "(no subject)") : f[1]),
                                subtitle: "\(senderName(f[2])) · \(shortDate(f[3]))", detail: String(preview.prefix(500)), reference: f[0])
        }
        return AppItems(source: .mail, title: listTitle(query: query, unreadOnly: unreadOnly, account: account), rows: rows)
    }

    /// Titolo dell'elenco: le non lette, quelle su un testo o la posta in arrivo, con l'account dello spazio.
    static func listTitle(query: String?, unreadOnly: Bool, account: String?) -> String {
        let title = unreadOnly ? Language.t("Email non lette", "Unread emails")
            : query.map { Language.t("Email su «\($0)»", "Emails about “\($0)”") } ?? Language.t("Posta in arrivo", "Inbox")
        return account.map { "\(title) · \($0)" } ?? title
    }

    /// Account configurati in Mail (per scegliere quello di ogni spazio).
    public static func accounts() async -> [String] {
        if FixtureWorld.active != nil { return [] }
        let output = (try? await AppleScript.run("tell application \"Mail\" to return name of every account", app: "Mail")) ?? ""
        return output.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public static func open(id: String) async {
        _ = try? await AppleScript.run("""
        tell application "Mail"
            set m to first message of inbox whose id is \(Int(id) ?? 0)
            open m
            activate
        end tell
        """, app: "Mail")
    }

    /// Email in arrivo di una persona o su un argomento (o le ultime), dalla più recente.
    public static func find(person: String?, subject: String?, limit: Int = 5, account: String? = SpaceScope.current.mailAccount) async throws -> [MailMessage] {
        if let world = FixtureWorld.active { return world.mailFind(person: person, subject: subject, limit: limit) }
        let selection: String
        if let person, !person.isEmpty {
            selection = "(messages of theBox whose sender contains \(AppleScript.quote(person)))"
        } else if let subject, !subject.isEmpty {
            selection = "(messages of theBox whose subject contains \(AppleScript.quote(subject)))"
        } else {
            selection = "(messages 1 thru 15 of theBox)"
        }
        let box = account.map { name in
            """
            set theBox to inbox
            try
                set theBox to mailbox "INBOX" of account \(AppleScript.quote(name))
            on error
                try
                    set theBox to mailbox "Inbox" of account \(AppleScript.quote(name))
                end try
            end try
            """
        } ?? "set theBox to inbox"
        let script = """
        set sep to character id 31
        set rs to character id 30
        set out to ""
        tell application "Mail"
            \(box)
            set found to {}
            try
                set found to \(selection)
            on error
                \(person?.isEmpty == false || subject?.isEmpty == false ? "set found to {}" : "set found to messages of theBox")
            end try
            set n to count of found
            if n > 40 then set n to 40
            repeat with i from 1 to n
                set m to item i of found
                set age to 0
                try
                    set age to ((current date) - (date received of m)) as integer
                end try
                set out to out & (id of m) & sep & (subject of m) & sep & (sender of m) & sep & ((date received of m) as string) & sep & age & rs
            end repeat
        end tell
        return out
        """
        var messages = AppleScript.records(try await AppleScript.run(script, app: "Mail")).compactMap { f -> MailMessage? in
            guard f.count >= 5 else { return nil }
            return MailMessage(id: f[0], subject: f[1], sender: f[2], date: f[3], age: Int(f[4]) ?? 0)
        }
        // Con persona e argomento insieme, prima quelle con l'argomento nell'oggetto.
        if let person, !person.isEmpty, let subject, !subject.isEmpty {
            let matching = messages.filter { $0.subject.localizedCaseInsensitiveContains(subject) }
            if !matching.isEmpty { messages = matching }
        }
        return Array(messages.sorted { $0.age < $1.age }.prefix(limit))
    }

    /// Un'email con il testo completo.
    public static func message(id: String) async throws -> MailMessage {
        if let world = FixtureWorld.active { return try world.mailMessage(id: id) }
        let script = """
        set sep to character id 31
        tell application "Mail"
            set m to first message of inbox whose id is \(Int(id) ?? 0)
            set c to ""
            try
                set c to content of m
                if length of c > 8000 then set c to text 1 thru 8000 of c
            end try
            return (subject of m) & sep & (sender of m) & sep & ((date received of m) as string) & sep & c
        end tell
        """
        let output = try await AppleScript.run(script, app: "Mail")
        let parts = output.components(separatedBy: AppleScript.field)
        guard parts.count >= 4 else { throw AppleAppError.script(Language.t("Non riesco a leggere l'email.", "I can't read the email.")) }
        return MailMessage(id: id, subject: parts[0], sender: parts[1], date: parts[2], content: parts[3...].joined(separator: AppleScript.field))
    }

    public static func senderName(_ sender: String) -> String {
        if let range = sender.range(of: " <") { return String(sender[..<range.lowerBound]).replacingOccurrences(of: "\"", with: "") }
        return sender
    }
}

// MARK: - Mail (risposte e inoltri)

/// Apre in Mail una risposta o un inoltro già pronti: l'invio resta all'utente, dalla finestra di Mail.
public enum MailComposer {
    /// Apre una bozza e rilegge oggetto, corpo e destinatari nella stessa finestra di Mail.
    /// L'invio non viene mai eseguito qui.
    public static func compose(to addresses: [String], subject: String, body: String) async throws -> Bool {
        guard !addresses.isEmpty else { throw AppleAppError.noRecipient }
        let recipients = addresses.map { address in
            "make new to recipient at end of to recipients of draftMessage with properties {address:\(AppleScript.quote(address))}"
        }.joined(separator: "\n")
        let checks = addresses.map { address in
            "if observedAddresses does not contain \(AppleScript.quote(address)) then return \"UNCERTAIN\""
        }.joined(separator: "\n")
        let script = """
        tell application "Mail"
            set draftMessage to make new outgoing message with properties {subject:\(AppleScript.quote(subject)), content:\(AppleScript.quote(body)), visible:true}
            tell draftMessage
                \(recipients)
            end tell
            activate
            set observedAddresses to address of every to recipient of draftMessage
            if (subject of draftMessage) is not \(AppleScript.quote(subject)) then return "UNCERTAIN"
            if (content of draftMessage) does not contain \(AppleScript.quote(body)) then return "UNCERTAIN"
            if (count of observedAddresses) is not \(addresses.count) then return "UNCERTAIN"
            \(checks)
            return "OPENED"
        end tell
        """
        return try await AppleScript.run(script, app: "Mail") == "OPENED"
    }

    /// Risposta nella stessa conversazione. Mail non permette di aggiungere testo alla citazione, quindi il testo è completo.
    public static func reply(to id: String, body: String, replyAll: Bool) async throws {
        _ = try await AppleScript.run("""
        tell application "Mail"
            set m to first message of inbox whose id is \(Int(id) ?? 0)
            set r to reply m with opening window\(replyAll ? " and reply to all" : "")
            delay 0.3
            set content of r to \(AppleScript.quote(body))
            if (content of r) does not contain \(AppleScript.quote(body)) then error "La bozza di risposta non corrisponde al testo previsto." number 4002
            activate
        end tell
        """, app: "Mail")
    }

    /// Inoltro con gli allegati originali; il destinatario si aggiunge se c'è l'indirizzo.
    public static func forward(_ id: String, to address: String, name: String) async throws {
        let recipient = address.isEmpty ? "" : """
            tell f
                make new to recipient at end of to recipients with properties {name:\(AppleScript.quote(name)), address:\(AppleScript.quote(address))}
            end tell
        """
        _ = try await AppleScript.run("""
        tell application "Mail"
            set m to first message of inbox whose id is \(Int(id) ?? 0)
            set f to forward m with opening window
            \(recipient)
            if \(AppleScript.quote(address)) is not "" and (address of every to recipient of f) does not contain \(AppleScript.quote(address)) then error "Il destinatario dell'inoltro non corrisponde." number 4002
            activate
        end tell
        """, app: "Mail")
    }

    /// "Re: oggetto" senza ripetere il prefisso.
    public static func replySubject(_ subject: String) -> String {
        subject.range(of: #"^\s*(re|r|ris)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil ? subject : "Re: \(subject)"
    }

    /// Citazione dell'email originale, come la scrive Mail.
    public static func quote(_ message: MailMessage) -> String {
        let lines = message.content.components(separatedBy: .newlines).prefix(120).map { "> " + $0 }
        return Language.t("Il giorno \(message.shortDate), \(message.sender) ha scritto:", "On \(message.shortDate), \(message.sender) wrote:")
            + "\n\n" + lines.joined(separator: "\n")
    }
}

// MARK: - File (Spotlight)

public enum FileSearch {
    /// Cerca nella cartella Inizio con Spotlight (nome e contenuto), escludendo Libreria e cartelle nascoste.
    public static func search(_ query: String, limit: Int = 15) async throws -> AppItems {
        if let world = FixtureWorld.active { return world.fileSearch(query, limit: limit) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let output = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                process.arguments = ["-onlyin", home, query]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
        let paths = output.split(separator: "\n").map(String.init)
            .filter { !$0.contains("/Library/") && !$0.contains("/.") && !$0.contains("/node_modules/") && !$0.contains(".build/") }
        let fm = FileManager.default
        let rows = paths.prefix(limit * 2).compactMap { path -> (AppItems.Row, Date)? in
            guard let attributes = try? fm.attributesOfItem(atPath: path) else { return nil }
            let date = attributes[.modificationDate] as? Date ?? .distantPast
            let folder = (path as NSString).deletingLastPathComponent.replacingOccurrences(of: home, with: "~")
            let size = (attributes[.size] as? Int).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
            let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
            return (AppItems.Row(id: path, title: (isDirectory ? "📁 " : "") + (path as NSString).lastPathComponent,
                                 subtitle: [folder, Dates.format(date, time: false), isDirectory ? "" : size].filter { !$0.isEmpty }.joined(separator: " · "),
                                 reference: path), date)
        }
        // Prima i file modificati di recente.
        let sorted = rows.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        return AppItems(source: .files, title: listTitle(query), rows: Array(sorted))
    }

    /// Titolo dell'elenco dei file trovati.
    static func listTitle(_ query: String) -> String { Language.t("File per «\(query)»", "Files for “\(query)”") }

    /// Testo di un file (txt, md, pdf, rtf, docx…), riusando il lettore dei progetti.
    public static func read(_ path: String, maxChars: Int = 2400) throws -> String {
        if let world = FixtureWorld.active { return try world.fileRead(path, maxChars: maxChars) }
        let url = URL(fileURLWithPath: path)
        return try ProjectFiles(root: url.deletingLastPathComponent()).read(url.lastPathComponent, maxChars: maxChars)
    }
}

// MARK: - Messaggi

public enum MessagesService {
    static var database: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Messages/chat.db")
    }

    public static var canRead: Bool { FileManager.default.isReadableFile(atPath: database.path) }

    /// Ultimi messaggi (serve l'accesso completo al disco), eventualmente di una persona o con un testo.
    public static func recent(matching query: String?, limit: Int = 25) throws -> AppItems {
        if let world = FixtureWorld.active { return world.messages(matching: query, limit: limit) }
        guard canRead else { throw AppleAppError.fullDiskAccess }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw AppleAppError.fullDiskAccess
        }
        defer { sqlite3_close(db) }
        var sql = """
        SELECT m.ROWID, m.text, m.is_from_me, m.date, IFNULL(h.id, ''), IFNULL(c.display_name, '')
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.text IS NOT NULL AND length(m.text) > 0
        """
        let handles = query.map(Contacts.handles(for:)) ?? []
        if let query, !query.isEmpty {
            let conditions = ["m.text LIKE ?1", "h.id LIKE ?1", "c.display_name LIKE ?1"] + handles.indices.map { "h.id LIKE ?\($0 + 2)" }
            sql += " AND (" + conditions.joined(separator: " OR ") + ")"
        }
        sql += " ORDER BY m.date DESC LIMIT \(limit)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw AppleAppError.script(Language.t("Database dei Messaggi non leggibile.", "The Messages database can't be read.")) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let query, !query.isEmpty {
            sqlite3_bind_text(statement, 1, "%\(query)%", -1, transient)
            for (index, handle) in handles.enumerated() { sqlite3_bind_text(statement, Int32(index + 2), "%\(handle.suffix(9))%", -1, transient) }
        }
        var names: [String: String] = [:]
        var rows: [AppItems.Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = String(cString: sqlite3_column_text(statement, 1))
            let fromMe = sqlite3_column_int(statement, 2) == 1
            // Date in nanosecondi dal 2001 (o secondi nei database più vecchi).
            let raw = Double(sqlite3_column_int64(statement, 3))
            let date = Date(timeIntervalSinceReferenceDate: raw > 1e12 ? raw / 1e9 : raw)
            let handle = String(cString: sqlite3_column_text(statement, 4))
            let chat = String(cString: sqlite3_column_text(statement, 5))
            let person = chat.isEmpty ? (names[handle] ?? Contacts.name(for: handle) ?? handle) : chat
            names[handle] = person
            rows.append(AppItems.Row(id: String(sqlite3_column_int64(statement, 0)), title: fromMe ? Language.t("Tu → \(person)", "You → \(person)") : person,
                                     subtitle: Dates.format(date), detail: text, reference: handle))
        }
        return AppItems(source: .messages, title: listTitle(query), rows: rows)
    }

    /// Titolo dell'elenco: i messaggi con una persona (o un testo), o i recenti.
    static func listTitle(_ query: String?) -> String {
        query.map { Language.t("Messaggi con «\($0)»", "Messages with “\($0)”") } ?? Language.t("Messaggi recenti", "Recent messages")
    }

    /// Invia un iMessage/SMS con l'app Messaggi (dopo la conferma nella scheda).
    public static func send(_ draft: MessageDraft) async throws {
        guard !draft.handle.isEmpty else { throw AppleAppError.noRecipient }
        _ = try await AppleScript.run("""
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant \(AppleScript.quote(draft.handle)) of targetService
            send \(AppleScript.quote(draft.text)) to targetBuddy
        end tell
        """, app: "Messaggi")
    }
}

// MARK: - Contatti

public enum Contacts {
    nonisolated(unsafe) static let store = CNContactStore()
    /// CNContactStore non è sicuro fra thread: una lettura alla volta.
    private static let lock = NSLock()

    public static var authorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    public static func requestAccess() async -> Bool {
        (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// Numeri ed email di chi si chiama così.
    public static func handles(for name: String) -> [String] {
        if let world = FixtureWorld.active { return world.contactHandles(name) }
        guard authorized, name.count >= 2 else { return [] }
        let keys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let contacts = lock.withLock { (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? [] }
        return contacts.prefix(3).flatMap { contact in
            contact.phoneNumbers.map { $0.value.stringValue.filter { $0.isNumber || $0 == "+" } } + contact.emailAddresses.map { $0.value as String }
        }
    }

    /// Indirizzi email di chi si chiama così, con il nome completo (vuoto se non c'è nei Contatti).
    public static func emails(for name: String) -> [(name: String, address: String)] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") { return [(trimmed, trimmed)] }
        if let world = FixtureWorld.active { return world.contactEmails(trimmed) }
        guard authorized, trimmed.count >= 2 else { return [] }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let contacts = lock.withLock { (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: trimmed), keysToFetch: keys)) ?? [] }
        return contacts.prefix(4).flatMap { contact in
            contact.emailAddresses.map { ("\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces), $0.value as String) }
        }
    }

    /// Primo numero o email di un contatto, o il testo stesso se è già un recapito.
    public static func resolve(_ recipient: String) -> String? {
        let trimmed = recipient.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter { $0.isNumber || $0 == "+" }
        if trimmed.contains("@") || digits.count >= 6 && digits.count >= trimmed.filter({ !$0.isWhitespace }).count - 2 { return trimmed.contains("@") ? trimmed : digits }
        return handles(for: trimmed).first
    }

    static func name(for handle: String) -> String? {
        if let world = FixtureWorld.active { return world.contactName(handle) }
        guard authorized, !handle.isEmpty else { return nil }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
        let predicate = handle.contains("@") ? CNContact.predicateForContacts(matchingEmailAddress: handle)
            : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
        guard let contact = lock.withLock({ try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first }) else { return nil }
        return "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
    }
}

/// "lunedì 21 settembre 2026 alle ore 10:15:00" → "21 set 10:15"; su un Mac in inglese
/// "Monday, September 21, 2026 at 10:15:00 AM" → "Sep 21 10:15 AM".
func shortDate(_ appleScriptDate: String) -> String {
    let parts = appleScriptDate.replacingOccurrences(of: " alle ore ", with: " ").split(separator: " ")
    if let g = Calculations.matches(#"^\p{L}+,? (\p{L}+) (\d{1,2}),? \d{4},? (?:at )?(\d{1,2}:\d{2})(?::\d{2})?(?:\s*([AaPp]\.?[Mm]\.?))?"#, in: appleScriptDate).first {
        return "\(g[1].prefix(3)) \(g[2]) \(g[3])" + (g[4].isEmpty ? "" : " \(g[4].uppercased())")
    }
    guard parts.count >= 4 else { return appleScriptDate }
    let time = parts.last.map { String($0.prefix(5)) } ?? ""
    return "\(parts[1]) \(parts[2].prefix(3)) \(time)"
}
