import Foundation

// MARK: - Mail (app Mail dentro Siri AI+)
//
// Tutto passa da AppleScript, ma le proprietà si leggono in blocco (una richiesta per proprietà, non una per email):
// così anche una casella grande si apre in un paio di secondi.

public struct MailAccountInfo: Identifiable, Sendable, Equatable {
    /// Identificativo dell'account in Mail (lo stesso delle URL nell'indice).
    public let id: String
    public let name: String
    public let fullName: String
    public let addresses: [String]

    /// "Mario Rossi <mario@esempio.it>" per il campo Da.
    public var senders: [String] { addresses.map { fullName.isEmpty ? $0 : "\(fullName) <\($0)>" } }
}

public struct MailboxInfo: Identifiable, Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case inbox, flagged, drafts, sent, archive, junk, trash, other

        public var symbol: String {
            switch self {
            case .inbox: "tray"
            case .flagged: "flag"
            case .drafts: "doc"
            case .sent: "paperplane"
            case .archive: "archivebox"
            case .junk: "xmark.bin"
            case .trash: "trash"
            case .other: "folder"
            }
        }

        public var label: String {
            switch self {
            case .inbox: "In arrivo"
            case .flagged: "Contrassegnati"
            case .drafts: "Bozze"
            case .sent: "Inviati"
            case .archive: "Archivio"
            case .junk: "Indesiderata"
            case .trash: "Cestino"
            case .other: "Casella"
            }
        }
    }

    /// Nome dell'account (nil: casella unificata di tutti gli account).
    public let account: String?
    /// Identificativo dell'account in Mail (dall'indice): le caselle annidate si raggiungono solo così.
    public let accountID: String?
    /// Percorso completo come in Mail ("INBOX", "[Gmail]/Tutti i messaggi", "INBOX/Clienti/Rossi").
    public let name: String
    public let kind: Kind
    public var unread: Int
    public var total: Int

    public var id: String { (accountID ?? account ?? "*") + "\u{1F}" + name }

    public init(account: String?, accountID: String? = nil, name: String, kind: Kind, unread: Int = 0, total: Int = 0) {
        self.account = account; self.accountID = accountID; self.name = name; self.kind = kind; self.unread = unread; self.total = total
    }

    /// Parti del percorso da mostrare, senza «INBOX/» e «[Gmail]/» davanti.
    public var displayPath: [String] {
        var path = name
        for prefix in ["INBOX/", "[Gmail]/", "[Google Mail]/"] where path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        return path.components(separatedBy: "/").filter { !$0.isEmpty }
    }

    public var displayName: String { name == "INBOX" ? "In arrivo" : (displayPath.last ?? name) }
    public var depth: Int { max(0, displayPath.count - 1) }
    public var title: String { account == nil ? kind.label : displayName }

    public static let unifiedInbox = MailboxInfo(account: nil, name: "inbox", kind: .inbox)

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Riconosce le caselle speciali dal nome (in italiano, inglese, Gmail).
    public static func kind(of name: String) -> Kind {
        var n = name.lowercased()
        for prefix in ["inbox/", "[gmail]/", "[google mail]/"] where n.hasPrefix(prefix) && n != prefix { n.removeFirst(prefix.count) }
        if ["inbox", "posta in arrivo", "in arrivo"].contains(n) { return .inbox }
        if ["sent", "sent messages", "sent mail", "sent items", "inviati", "posta inviata", "messaggi inviati", "elementi inviati"].contains(n) { return .sent }
        if ["drafts", "draft", "bozze"].contains(n) { return .drafts }
        if ["trash", "deleted messages", "deleted items", "bin", "cestino", "posta eliminata", "elementi eliminati"].contains(n) { return .trash }
        if ["junk", "spam", "junk e-mail", "junk email", "posta indesiderata", "indesiderata"].contains(n) { return .junk }
        if ["archive", "archivio", "all mail", "tutti i messaggi"].contains(n) { return .archive }
        if ["flagged", "starred", "speciali", "contrassegnati"].contains(n) { return .flagged }
        return .other
    }
}

/// Riga dell'elenco dei messaggi.
public struct MailSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public var subject: String
    public let sender: String
    public let date: Date
    public var read: Bool
    public var flagged: Bool
    /// Prime righe del testo (dall'indice di Mail).
    public var preview: String = ""
    /// Primo destinatario (per Inviati e Bozze).
    public var recipient: String = ""
    /// Casella in cui si trova davvero (dall'indice): le azioni partono da lì.
    public var location: MailboxInfo?

    public var senderName: String { MailReader.senderName(sender) }
    public var senderAddress: String { MailMessage(id: id, subject: subject, sender: sender, date: "").senderAddress }
}

/// Un'email aperta, con destinatari, allegati e testo.
public struct MailContent: Sendable, Equatable {
    public let id: String
    public let subject: String
    public let sender: String
    public let to: [String]
    public let cc: [String]
    public let attachments: [String]
    public let date: Date
    public let dateText: String
    public let content: String
    public var read: Bool
    public var flagged: Bool

    public init(id: String, subject: String, sender: String, to: [String], cc: [String], attachments: [String], date: Date, dateText: String,
                content: String, read: Bool, flagged: Bool) {
        self.id = id; self.subject = subject; self.sender = sender; self.to = to; self.cc = cc; self.attachments = attachments
        self.date = date; self.dateText = dateText; self.content = content; self.read = read; self.flagged = flagged
    }

    public var message: MailMessage { MailMessage(id: id, subject: subject, sender: sender, date: dateText, content: content) }
}

/// Email da scrivere (nuova, risposta o inoltro) prima di inviarla.
public struct MailComposition: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case new
        case reply(messageID: String, box: MailboxInfo, all: Bool)
        case forward(messageID: String, box: MailboxInfo)
    }

    public var mode: Mode
    public var from: String
    public var to: String
    public var cc: String
    public var bcc: String
    public var subject: String
    public var body: String
    /// Testo citato sotto la risposta (non modificabile qui).
    public var quote: String
    public var attachments: [URL]

    public init(mode: Mode = .new, from: String = "", to: String = "", cc: String = "", bcc: String = "", subject: String = "",
                body: String = "", quote: String = "", attachments: [URL] = []) {
        self.mode = mode; self.from = from; self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject
        self.body = body; self.quote = quote; self.attachments = attachments
    }

    /// Indirizzi separati da virgola o punto e virgola.
    public static func addresses(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public enum MailStore {
    static let group = "\u{1D}"

    /// Espressione AppleScript della casella.
    static func box(_ mailbox: MailboxInfo) -> String {
        guard let account = mailbox.account else {
            switch mailbox.kind {
            case .sent: return "sent mailbox"
            case .drafts: return "drafts mailbox"
            case .trash: return "trash mailbox"
            case .junk: return "junk mailbox"
            default: return "inbox"
            }
        }
        if let accountID = mailbox.accountID {
            return "mailbox \(AppleScript.quote(mailbox.name)) of account id \(AppleScript.quote(accountID))"
        }
        return "mailbox \(AppleScript.quote(mailbox.name)) of account \(AppleScript.quote(account))"
    }

    public static func accounts() async throws -> [MailAccountInfo] {
        let script = """
        set sep to character id 31
        set rs to character id 30
        set gs to character id 29
        set out to ""
        tell application "Mail"
            repeat with acc in (every account whose enabled is true)
                set addressList to email addresses of acc
                set AppleScript's text item delimiters to gs
                set addressText to addressList as string
                set AppleScript's text item delimiters to ""
                set fullName to ""
                try
                    set fullName to full name of acc
                end try
                set out to out & (name of acc) & sep & fullName & sep & addressText & sep & (id of acc) & rs
            end repeat
        end tell
        return out
        """
        return AppleScript.records(try await AppleScript.run(script, app: "Mail")).compactMap { f in
            guard f.count >= 4 else { return nil }
            return MailAccountInfo(id: f[3], name: f[0], fullName: f[1] == "missing value" ? "" : f[1],
                                   addresses: f[2].components(separatedBy: group).filter { !$0.isEmpty && $0 != "missing value" })
        }
    }

    /// Caselle di ogni account (con i non letti) più quelle unificate in cima.
    public static func mailboxes() async throws -> [MailboxInfo] {
        let script = """
        set sep to character id 31
        set rs to character id 30
        set out to ""
        tell application "Mail"
            set out to out & "*" & sep & "inbox" & sep & (unread count of inbox) & rs
            repeat with acc in (every account whose enabled is true)
                set accName to name of acc
                try
                    set boxNames to name of every mailbox of acc
                    set boxUnread to unread count of every mailbox of acc
                    repeat with i from 1 to count of boxNames
                        set out to out & accName & sep & (item i of boxNames) & sep & (item i of boxUnread) & rs
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
        var result: [MailboxInfo] = []
        for fields in AppleScript.records(try await AppleScript.run(script, app: "Mail")) where fields.count >= 3 {
            let unread = Int(fields[2]) ?? 0
            if fields[0] == "*" {
                result.append(MailboxInfo(account: nil, name: "inbox", kind: .inbox, unread: unread))
            } else {
                result.append(MailboxInfo(account: fields[0], name: fields[1], kind: MailboxInfo.kind(of: fields[1]), unread: unread))
            }
        }
        // Caselle unificate come in Mail: In arrivo, Contrassegnati, Bozze, Inviati, Indesiderata, Cestino.
        let unified: [MailboxInfo.Kind] = [.flagged, .drafts, .sent, .junk, .trash]
        let inbox = result.first { $0.account == nil } ?? .unifiedInbox
        return [inbox] + unified.map { MailboxInfo(account: nil, name: $0.rawValue, kind: $0) }
            + result.filter { $0.account != nil }
    }

    /// Una pagina di email della casella, dalla più recente. `total` è il numero di email nella casella.
    public static func messages(in mailbox: MailboxInfo, from start: Int = 1, count: Int = 120) async throws -> (items: [MailSummary], total: Int) {
        let range = "messages a thru b of theBox"
        let flaggedOnly = mailbox.account == nil && mailbox.kind == .flagged
        let selection = flaggedOnly ? "(messages of theBox whose flagged status is true)" : range
        let script = """
        set sep to character id 31
        set rs to character id 30
        tell application "Mail"
            set theBox to \(box(mailbox))
            \(flaggedOnly ? "set total to count of (messages of theBox whose flagged status is true)" : "set total to count of messages of theBox")
            if total is 0 then return "0"
            set a to \(max(1, start))
            if a > total then return (total as string)
            set b to a + \(max(1, count)) - 1
            if b > total then set b to total
            set theIDs to id of \(selection)
            set theSubjects to subject of \(selection)
            set theSenders to sender of \(selection)
            set theDates to date received of \(selection)
            set theReads to read status of \(selection)
            set theFlags to flagged status of \(selection)
        end tell
        set now to current date
        set out to (total as string) & rs
        repeat with i from 1 to count of theIDs
            set age to 0
            try
                set age to (now - (item i of theDates)) as integer
            end try
            set s to item i of theSubjects
            if s is missing value then set s to ""
            set out to out & (item i of theIDs) & sep & s & sep & (item i of theSenders) & sep & age & sep & (item i of theReads) & sep & (item i of theFlags) & rs
        end repeat
        return out
        """
        return parseMessages(try await AppleScript.run(script, app: "Mail"))
    }

    /// Elenco dall'uscita dello script: la prima riga è il totale.
    static func parseMessages(_ output: String, now: Date = .now) -> (items: [MailSummary], total: Int) {
        let records = output.components(separatedBy: AppleScript.record)
        let total = Int(records.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        let items = records.dropFirst().compactMap { record -> MailSummary? in
            let f = record.components(separatedBy: AppleScript.field).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard f.count >= 6, !f[0].isEmpty else { return nil }
            return MailSummary(id: f[0], subject: f[1] == "missing value" ? "" : f[1], sender: f[2],
                               date: now.addingTimeInterval(-Double(Int(f[3]) ?? 0)), read: f[4] == "true", flagged: f[5] == "true")
        }
        return (items.sorted { $0.date > $1.date }, total)
    }

    /// Il messaggio nella casella: per identificativo diretto, altrimenti cercandolo.
    static func message(_ id: String, in mailbox: MailboxInfo) -> String {
        let number = Int(id) ?? 0
        return """
            set theBox to \(box(mailbox))
            set m to first message of theBox whose id is \(number)
        """
    }

    public static func content(of id: String, in mailbox: MailboxInfo) async throws -> MailContent {
        let script = """
        set sep to character id 31
        set gs to character id 29
        tell application "Mail"
            \(message(id, in: mailbox))
            set c to ""
            try
                set c to content of m
            end try
            if length of c > 60000 then set c to text 1 thru 60000 of c
            set AppleScript's text item delimiters to gs
            set toText to ""
            try
                set toText to (address of every to recipient of m) as string
            end try
            set ccText to ""
            try
                set ccText to (address of every cc recipient of m) as string
            end try
            set attText to ""
            try
                set attText to (name of every mail attachment of m) as string
            end try
            set AppleScript's text item delimiters to ""
            set d to date received of m
            set age to ((current date) - d) as integer
            set s to subject of m
            if s is missing value then set s to ""
            return s & sep & (sender of m) & sep & toText & sep & ccText & sep & attText & sep & age & sep & (read status of m) & sep & (flagged status of m) & sep & (d as string) & sep & c
        end tell
        """
        let output = try await AppleScript.run(script, app: "Mail")
        let parts = output.components(separatedBy: AppleScript.field)
        guard parts.count >= 10 else { throw AppleAppError.script("Non riesco a leggere l'email.") }
        func list(_ text: String) -> [String] { text.components(separatedBy: group).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "missing value" } }
        return MailContent(id: id, subject: parts[0], sender: parts[1], to: list(parts[2]), cc: list(parts[3]), attachments: list(parts[4]),
                           date: Date.now.addingTimeInterval(-Double(Int(parts[5]) ?? 0)), dateText: parts[8],
                           content: parts[9...].joined(separator: AppleScript.field).trimmingCharacters(in: .whitespacesAndNewlines),
                           read: parts[6] == "true", flagged: parts[7] == "true")
    }

    /// Solo il testo dell'email (destinatari e allegati arrivano dall'indice).
    public static func body(of id: String, in mailbox: MailboxInfo) async throws -> String {
        try await AppleScript.run("""
        tell application "Mail"
            \(message(id, in: mailbox))
            set c to ""
            try
                set c to content of m
            end try
            if length of c > 60000 then set c to text 1 thru 60000 of c
            return c
        end tell
        """, app: "Mail").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum Action: Sendable, Equatable {
        case read(Bool), flag(Bool), delete, move(MailboxInfo), open
    }

    /// Letta/non letta, contrassegno, Cestino, spostamento o apertura in Mail.
    public static func perform(_ action: Action, on id: String, in mailbox: MailboxInfo) async throws {
        let command: String
        switch action {
        case .read(let value): command = "set read status of m to \(value)"
        case .flag(let value): command = "set flagged status of m to \(value)"
        case .delete: command = "delete m"
        case .move(let target): command = "move m to \(box(target))"
        case .open: command = "open m\n    activate"
        }
        _ = try await AppleScript.run("""
        tell application "Mail"
            \(message(id, in: mailbox))
            \(command)
        end tell
        """, app: "Mail")
    }

    /// Invia l'email (o la apre in Mail per finirla lì, con `send: false`).
    public static func deliver(_ mail: MailComposition, send: Bool) async throws {
        let recipients: String = [("to recipient", mail.to), ("cc recipient", mail.cc), ("bcc recipient", mail.bcc)].map { kind, text in
            MailComposition.addresses(text).map { address -> String in
                // "Nome <indirizzo>" o solo l'indirizzo.
                if let open = address.lastIndex(of: "<"), let close = address.lastIndex(of: ">"), open < close {
                    let name = address[..<open].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                    let email = String(address[address.index(after: open)..<close])
                    return "make new \(kind) at end of \(kind)s with properties {name:\(AppleScript.quote(name)), address:\(AppleScript.quote(email))}"
                }
                return "make new \(kind) at end of \(kind)s with properties {address:\(AppleScript.quote(address))}"
            }.joined(separator: "\n            ")
        }.filter { !$0.isEmpty }.joined(separator: "\n            ")
        let attachments = mail.attachments.map {
            "make new attachment with properties {file name:(POSIX file \(AppleScript.quote($0.path)))} at after the last paragraph"
        }.joined(separator: "\n                ")
        let sender = mail.from.isEmpty ? "" : "set sender of m to \(AppleScript.quote(mail.from))"
        let body = mail.quote.isEmpty ? mail.body : mail.body + "\n\n" + mail.quote
        let create: String
        switch mail.mode {
        case .new:
            create = "set m to make new outgoing message with properties {subject:\(AppleScript.quote(mail.subject)), content:\(AppleScript.quote(body)), visible:\(!send)}"
        case .reply(let id, let box, let all):
            let options = [send ? nil : "opening window", all ? "reply to all" : nil].compactMap { $0 }
            create = """
            \(message(id, in: box))
                set m to reply m\(options.isEmpty ? "" : " with " + options.joined(separator: " and "))
                delay 0.2
                set content of m to \(AppleScript.quote(body))
                set subject of m to \(AppleScript.quote(mail.subject))
                -- I destinatari sono quelli scelti nella scheda (Mail li aveva già messi: si sostituiscono).
                try
                    delete every to recipient of m
                    delete every cc recipient of m
                end try
            """
        case .forward(let id, let box):
            create = """
            \(message(id, in: box))
                set m to forward m\(send ? "" : " with opening window")
            """
        }
        let script = """
        tell application "Mail"
            \(create)
            \(sender.isEmpty ? "" : "try\n        \(sender)\n    end try")
            tell m
                \(recipients)
            end tell
            \(attachments.isEmpty ? "" : "tell content of m\n                \(attachments)\n            end tell")
            \(send ? "send m" : "activate")
        end tell
        """
        _ = try await AppleScript.run(script, app: "Mail")
    }

    /// "Re: oggetto" e citazione per una risposta scritta in Siri AI+.
    public static func replyDraft(to content: MailContent, box: MailboxInfo, all: Bool, from: String = "") -> MailComposition {
        let others = all ? (content.to + content.cc).filter { address in !from.localizedCaseInsensitiveContains(address) } : []
        return MailComposition(mode: .reply(messageID: content.id, box: box, all: all), from: from,
                               to: ([content.message.senderAddress] + others).filter { !$0.isEmpty }.joined(separator: ", "),
                               subject: MailComposer.replySubject(content.subject), quote: MailComposer.quote(content.message))
    }

    public static func forwardDraft(of content: MailContent, box: MailboxInfo, from: String = "") -> MailComposition {
        let subject = content.subject.range(of: #"^\s*(fwd?|i)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil ? content.subject : "Fwd: \(content.subject)"
        return MailComposition(mode: .forward(messageID: content.id, box: box), from: from, subject: subject)
    }
}
