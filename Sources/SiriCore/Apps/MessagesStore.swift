import Foundation
import SQLite3

// MARK: - Messaggi (app Messaggi dentro Siri AI+)
//
// Le conversazioni si leggono dal database di Messaggi (serve l'accesso completo al disco);
// l'invio passa dall'app Messaggi, come quando scrivi tu.

public struct ChatSummary: Identifiable, Sendable, Equatable {
    public let id: Int64
    /// Identificativo per l'invio ("iMessage;-;+39…" o "any;-;…").
    public let guid: String
    public let title: String
    public let handles: [String]
    public let lastText: String
    public let lastFromMe: Bool
    public let date: Date
    public let isGroup: Bool
    public let unread: Int
}

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let text: String
    public let fromMe: Bool
    public let date: Date
    /// Chi l'ha scritto (nei gruppi).
    public let sender: String
    public let hasAttachment: Bool
    public let delivered: Bool
    public let read: Bool
}

public enum MessagesStore {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Nomi dei Contatti per numero o email: una ricerca per recapito, poi si ricorda.
    private static let nameLock = NSLock()
    nonisolated(unsafe) private static var names: [String: String] = [:]

    public static func contactName(_ handle: String) -> String {
        guard !handle.isEmpty else { return handle }
        if let known = nameLock.withLock({ names[handle] }) { return known }
        let found = Contacts.name(for: handle).flatMap { $0.isEmpty ? nil : $0 } ?? handle
        nameLock.withLock { names[handle] = found }
        return found
    }

    static func openDatabase() throws -> OpaquePointer {
        guard MessagesService.canRead else { throw AppleAppError.fullDiskAccess }
        var db: OpaquePointer?
        guard sqlite3_open_v2(MessagesService.database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw AppleAppError.fullDiskAccess
        }
        return db
    }

    static func date(_ raw: Int64) -> Date {
        let value = Double(raw)
        return Date(timeIntervalSinceReferenceDate: value > 1e12 ? value / 1e9 : value)
    }

    static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    /// Testo del messaggio: nella colonna `text` o, nei macOS recenti, dentro `attributedBody`.
    static func body(_ statement: OpaquePointer?, textColumn: Int32, bodyColumn: Int32) -> String {
        let plain = text(statement, textColumn)
        if !plain.isEmpty { return plain }
        guard let bytes = sqlite3_column_blob(statement, bodyColumn) else { return "" }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, bodyColumn)))
        return decodeAttributedBody(data) ?? ""
    }

    /// `attributedBody` è un NSAttributedString in formato «typedstream»: il testo segue la classe NSString.
    public static func decodeAttributedBody(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard let start = bytes.firstRange(of: marker)?.upperBound else { return nil }
        // Dopo il nome della classe: 5 byte di intestazione, poi la lunghezza (1 byte, o 0x81 + 2 byte, o 0x82 + 4 byte).
        var index = start + 5
        guard index < bytes.count else { return nil }
        var length = Int(bytes[index])
        index += 1
        if length == 0x81, index + 2 <= bytes.count {
            length = Int(bytes[index]) | Int(bytes[index + 1]) << 8
            index += 2
        } else if length == 0x82, index + 4 <= bytes.count {
            length = Int(bytes[index]) | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2]) << 16 | Int(bytes[index + 3]) << 24
            index += 4
        }
        guard length > 0, index + length <= bytes.count else { return nil }
        return String(decoding: bytes[index..<(index + length)], as: UTF8.self)
    }

    /// Conversazioni dalla più recente, con l'ultimo messaggio e i partecipanti.
    public static func chats(limit: Int = 150) throws -> [ChatSummary] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        SELECT c.ROWID, c.guid, IFNULL(c.display_name, ''), IFNULL(c.chat_identifier, ''), IFNULL(c.style, 0),
               last.date, IFNULL(m.text, ''), m.attributedBody, IFNULL(m.is_from_me, 0),
               (SELECT COUNT(*) FROM chat_message_join j2 JOIN message u ON u.ROWID = j2.message_id
                  WHERE j2.chat_id = c.ROWID AND u.is_read = 0 AND u.is_from_me = 0 AND u.item_type = 0 AND u.date > last.date - 2592000000000000),
               (SELECT GROUP_CONCAT(h.id, char(31)) FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id WHERE chj.chat_id = c.ROWID)
        FROM chat c
        JOIN (SELECT j.chat_id AS chat_id, MAX(j.message_date) AS date, MAX(j.message_id) AS message_id
              FROM chat_message_join j GROUP BY j.chat_id) last ON last.chat_id = c.ROWID
        LEFT JOIN message m ON m.ROWID = last.message_id
        ORDER BY last.date DESC
        LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AppleAppError.script("Database dei Messaggi non leggibile: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        let name = contactName
        var result: [ChatSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let handles = text(statement, 10).components(separatedBy: "\u{1F}").filter { !$0.isEmpty }
            let displayName = text(statement, 2)
            let isGroup = sqlite3_column_int(statement, 4) == 43 || handles.count > 1
            let title = !displayName.isEmpty ? displayName
                : handles.isEmpty ? name(text(statement, 3))
                : handles.prefix(4).map(name).joined(separator: ", ") + (handles.count > 4 ? " e altri \(handles.count - 4)" : "")
            let last = body(statement, textColumn: 6, bodyColumn: 7)
            result.append(ChatSummary(id: sqlite3_column_int64(statement, 0), guid: text(statement, 1), title: title, handles: handles,
                                      lastText: last.isEmpty ? "Allegato" : last, lastFromMe: sqlite3_column_int(statement, 8) == 1,
                                      date: date(sqlite3_column_int64(statement, 5)), isGroup: isGroup,
                                      unread: Int(sqlite3_column_int(statement, 9))))
        }
        return result
    }

    /// Ultimi messaggi della conversazione, dal più vecchio al più recente (senza le reazioni).
    public static func messages(chat: Int64, limit: Int = 300) throws -> [ChatMessage] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        SELECT m.ROWID, IFNULL(m.text, ''), m.attributedBody, m.is_from_me, m.date, IFNULL(h.id, ''), m.cache_has_attachments,
               m.is_delivered, m.is_read
        FROM message m
        JOIN chat_message_join j ON j.message_id = m.ROWID
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE j.chat_id = ?1 AND IFNULL(m.associated_message_type, 0) = 0 AND IFNULL(m.item_type, 0) = 0
        ORDER BY m.date DESC
        LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AppleAppError.script("Database dei Messaggi non leggibile: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, chat)
        var result: [ChatMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let handle = text(statement, 5)
            let sender = contactName(handle)
            let hasAttachment = sqlite3_column_int(statement, 6) == 1
            let message = body(statement, textColumn: 1, bodyColumn: 2).replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachment else { continue }
            result.append(ChatMessage(id: sqlite3_column_int64(statement, 0), text: message.trimmingCharacters(in: .whitespacesAndNewlines),
                                      fromMe: sqlite3_column_int(statement, 3) == 1, date: date(sqlite3_column_int64(statement, 4)),
                                      sender: sender, hasAttachment: hasAttachment,
                                      delivered: sqlite3_column_int(statement, 7) == 1, read: sqlite3_column_int(statement, 8) == 1))
        }
        return result.reversed()
    }

    /// Invia nella conversazione (anche di gruppo) con l'app Messaggi.
    public static func send(_ text: String, toChat guid: String) async throws {
        _ = try await AppleScript.run("""
        tell application "Messages"
            send \(AppleScript.quote(text)) to chat id \(AppleScript.quote(guid))
        end tell
        """, app: "Messaggi")
    }
}
