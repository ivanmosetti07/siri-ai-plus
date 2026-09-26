import Foundation
import SQLite3

/// Lettura veloce di Mail dal suo indice («Envelope Index»), con l'accesso completo al disco:
/// elenco dei messaggi, caselle e non letti in pochi millisecondi. Le azioni (leggi, sposta, rispondi) restano in AppleScript.
public enum MailIndex {
    /// `~/Library/Mail/V*/MailData/Envelope Index` (la versione più recente).
    public static var databaseURL: URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mail")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .compactMap { name -> (Int, String)? in name.hasPrefix("V") ? Int(name.dropFirst()).map { ($0, name) } : nil }
            .sorted { $0.0 > $1.0 }
        for (_, name) in versions {
            let url = root.appending(path: name).appending(path: "MailData/Envelope Index")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public static var available: Bool { SystemAccess.fullDiskAccess && databaseURL != nil }

    /// Nomi degli account attivi in Mail per identificativo (dalla URL delle caselle), letti una volta con AppleScript.
    /// Vuoto: si mostrano tutti gli account dell'indice con il loro identificativo.
    nonisolated(unsafe) public static var accountNames: [String: String] = [:]

    public static func configure(accounts: [MailAccountInfo]) {
        accountNames = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    static func open() throws -> OpaquePointer {
        guard let url = databaseURL else { throw AppleAppError.fullDiskAccess }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw AppleAppError.fullDiskAccess
        }
        sqlite3_busy_timeout(db, 2000)
        return db
    }

    struct Box {
        let rowID: Int64
        let accountID: String
        let account: String
        let name: String
        let total: Int
        let unread: Int

        var info: MailboxInfo {
            let probe = MailboxInfo(account: account, accountID: accountID, name: name, kind: .other)
            return MailboxInfo(account: account, accountID: accountID, name: name, kind: MailboxInfo.kind(of: probe.name == "INBOX" ? "inbox" : probe.displayPath.joined(separator: "/")),
                               unread: unread, total: total)
        }
    }

    /// "imap://UUID/%5BGmail%5D/Tutti%20i%20messaggi" → account e nome della casella.
    static func parse(url: String) -> (accountID: String, name: String)? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let account = String(rest[..<slash])
        let path = String(rest[rest.index(after: slash)...])
        return (account, path.removingPercentEncoding ?? path)
    }

    static func boxes(_ db: OpaquePointer) -> [Box] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ROWID, url, IFNULL(total_count, 0), IFNULL(unread_count, 0) FROM mailboxes", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [Box] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let url = MessagesStore.text(statement, 1)
            guard url.hasPrefix("imap://") || url.hasPrefix("ews://") || url.hasPrefix("local://") || url.hasPrefix("pop://"),
                  let parsed = parse(url: url), !parsed.name.isEmpty else { continue }
            // Solo gli account attivi in Mail (l'indice conserva anche quelli tolti).
            if !accountNames.isEmpty, accountNames[parsed.accountID] == nil { continue }
            result.append(Box(rowID: sqlite3_column_int64(statement, 0), accountID: parsed.accountID,
                              account: accountNames[parsed.accountID] ?? parsed.accountID,
                              name: parsed.name, total: Int(sqlite3_column_int(statement, 2)), unread: Int(sqlite3_column_int(statement, 3))))
        }
        return result
    }

    public static func mailboxes() throws -> [MailboxInfo] {
        let db = try open()
        defer { sqlite3_close(db) }
        let all = boxes(db).map(\.info)
        func unread(_ kind: MailboxInfo.Kind) -> Int { all.filter { $0.kind == kind }.reduce(0) { $0 + $1.unread } }
        let unified: [MailboxInfo] = [.inbox, .flagged, .drafts, .sent, .junk, .trash].map { kind in
            MailboxInfo(account: nil, name: kind == .inbox ? "inbox" : kind.rawValue, kind: kind,
                        unread: kind == .inbox || kind == .junk ? unread(kind) : 0)
        }
        // In ogni account: prima le caselle speciali nell'ordine di Mail, poi le altre per percorso.
        let order: [MailboxInfo.Kind] = [.inbox, .flagged, .drafts, .sent, .archive, .junk, .trash, .other]
        let accounts = accountNames.isEmpty ? Array(Set(all.compactMap(\.account))).sorted()
            : accountNames.values.sorted().filter { name in all.contains { $0.account == name } }
        return unified + accounts.flatMap { account in
            all.filter { $0.account == account }.sorted {
                (order.firstIndex(of: $0.kind) ?? 9, $0.displayPath.joined(separator: "/").lowercased())
                    < (order.firstIndex(of: $1.kind) ?? 9, $1.displayPath.joined(separator: "/").lowercased())
            }
        }
    }

    /// Righe della casella dalla più recente (le caselle unificate raccolgono quelle dello stesso tipo di ogni account).
    public static func messages(in mailbox: MailboxInfo, limit: Int = 200, offset: Int = 0, search: String = "") throws -> (items: [MailSummary], total: Int) {
        let db = try open()
        defer { sqlite3_close(db) }
        let all = boxes(db)
        let byRow = Dictionary(all.map { ($0.rowID, $0.info) }, uniquingKeysWith: { a, _ in a })
        let ids: [Int64]
        if mailbox.account != nil || mailbox.accountID != nil {
            ids = all.filter { ($0.accountID == mailbox.accountID || $0.account == mailbox.account) && $0.name == mailbox.name }.map(\.rowID)
        } else if mailbox.kind == .flagged {
            ids = all.map(\.rowID)
        } else {
            ids = all.filter { $0.info.kind == mailbox.kind }.map(\.rowID)
        }
        guard !ids.isEmpty else { return ([], 0) }
        let list = ids.map(String.init).joined(separator: ",")
        var conditions = ["IFNULL(m.deleted, 0) = 0"]
        if mailbox.account == nil && mailbox.accountID == nil && mailbox.kind == .flagged {
            conditions.append("m.flagged = 1 AND m.mailbox IN (\(list))")
        } else {
            // Gmail tiene i messaggi in «Tutti i messaggi» e li mette nelle altre caselle con le etichette.
            conditions.append(tableExists(db, "labels") ? "(m.mailbox IN (\(list)) OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(list))))"
                                                         : "m.mailbox IN (\(list))")
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            conditions.append("(s.subject LIKE ?1 OR a.address LIKE ?1 OR a.comment LIKE ?1 OR m.ROWID IN (SELECT r.message FROM recipients r JOIN addresses ra ON ra.ROWID = r.address WHERE ra.address LIKE ?1 OR ra.comment LIKE ?1))")
        }
        let joins = """
        FROM messages m
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        WHERE \(conditions.joined(separator: " AND "))
        """
        func bind(_ statement: OpaquePointer?) {
            if !query.isEmpty { sqlite3_bind_text(statement, 1, "%\(query)%", -1, MessagesStore.transient) }
        }
        var total = 0
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) " + joins, -1, &statement, nil) == SQLITE_OK {
            bind(statement)
            if sqlite3_step(statement) == SQLITE_ROW { total = Int(sqlite3_column_int(statement, 0)) }
        }
        sqlite3_finalize(statement)
        statement = nil
        let sql = """
        SELECT m.ROWID, IFNULL(m.subject_prefix, ''), IFNULL(s.subject, ''), IFNULL(a.address, ''), IFNULL(a.comment, ''),
               CASE WHEN m.date_received > 0 THEN m.date_received ELSE m.date_sent END AS sort_date,
               IFNULL(m.read, 0), IFNULL(m.flagged, 0), IFNULL(su.summary, ''), m.mailbox,
               (SELECT CASE WHEN IFNULL(ra.comment, '') = '' THEN ra.address ELSE ra.comment END
                  FROM recipients r JOIN addresses ra ON ra.ROWID = r.address WHERE r.message = m.ROWID AND r.type = 0 ORDER BY r.position LIMIT 1)
        \(joins.replacingOccurrences(of: "LEFT JOIN addresses a ON a.ROWID = m.sender", with: "LEFT JOIN addresses a ON a.ROWID = m.sender\nLEFT JOIN summaries su ON su.ROWID = m.summary"))
        ORDER BY sort_date DESC
        LIMIT \(limit) OFFSET \(offset)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AppleAppError.script("Indice di Mail non leggibile: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        var items: [MailSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let prefix = MessagesStore.text(statement, 1)
            let subject = MessagesStore.text(statement, 2)
            let address = MessagesStore.text(statement, 3)
            let name = MessagesStore.text(statement, 4)
            var item = MailSummary(id: String(sqlite3_column_int64(statement, 0)), subject: prefix + subject,
                                   sender: name.isEmpty ? address : "\(name) <\(address)>",
                                   date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 5))),
                                   read: sqlite3_column_int(statement, 6) != 0, flagged: sqlite3_column_int(statement, 7) != 0)
            item.preview = MessagesStore.text(statement, 8).split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            item.location = byRow[sqlite3_column_int64(statement, 9)]
            item.recipient = MessagesStore.text(statement, 10)
            items.append(item)
        }
        return (items, total)
    }

    /// Intestazione di un'email dall'indice (destinatari e allegati), senza il testo: si mostra subito.
    public static func header(of id: String) -> (to: [String], cc: [String], attachments: [String])? {
        guard let db = try? open(), let rowID = Int64(id) else { return nil }
        defer { sqlite3_close(db) }
        var to: [String] = [], cc: [String] = [], attachments: [String] = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT r.type, IFNULL(a.comment, ''), IFNULL(a.address, '') FROM recipients r JOIN addresses a ON a.ROWID = r.address WHERE r.message = ?1 ORDER BY r.type, r.position", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, rowID)
            while sqlite3_step(statement) == SQLITE_ROW {
                let name = MessagesStore.text(statement, 1), address = MessagesStore.text(statement, 2)
                let entry = name.isEmpty ? address : "\(name) <\(address)>"
                if sqlite3_column_int(statement, 0) == 0 { to.append(entry) } else if sqlite3_column_int(statement, 0) == 1 { cc.append(entry) }
            }
        }
        sqlite3_finalize(statement)
        statement = nil
        if sqlite3_prepare_v2(db, "SELECT IFNULL(name, '') FROM attachments WHERE message = ?1", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, rowID)
            while sqlite3_step(statement) == SQLITE_ROW {
                let name = MessagesStore.text(statement, 0)
                if !name.isEmpty { attachments.append(name) }
            }
        }
        sqlite3_finalize(statement)
        return (to, cc, attachments)
    }

    static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, MessagesStore.transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }
}
