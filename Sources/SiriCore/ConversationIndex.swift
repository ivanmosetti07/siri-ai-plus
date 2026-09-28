import Foundation
import SQLite3

/// Indice full-text (SQLite FTS5) delle conversazioni: "cosa avevamo deciso sul preventivo?".
public final class ConversationIndex: @unchecked Sendable {
    public struct Hit: Sendable, Equatable {
        public let id: String
        public let title: String
        public let snippet: String
        public let date: Date
    }

    public static let shared = ConversationIndex(url: AppPaths.support("search.sqlite"))

    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { db = nil; return }
        exec("PRAGMA journal_mode=WAL")
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS chats USING fts5(id UNINDEXED, title, body, date UNINDEXED, tokenize='unicode61 remove_diacritics 2')")
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    public func update(id: String, title: String, body: String, date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return }
        remove(id: id, locked: true)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO chats(id, title, body, date) VALUES (?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, Self.transient)
        sqlite3_bind_text(statement, 2, title, -1, Self.transient)
        sqlite3_bind_text(statement, 3, body, -1, Self.transient)
        sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    public func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        remove(id: id, locked: true)
    }

    private func remove(id: String, locked: Bool) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM chats WHERE id = ?", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, Self.transient)
        sqlite3_step(statement)
    }

    /// Parole della domanda (anche con desinenze diverse), più pertinenti per prime.
    public func search(_ query: String, limit: Int = 6, excluding: String? = nil) -> [Hit] {
        if let world = FixtureWorld.active { return world.conversations(query, limit: limit) }
        let skipped = Language.isEnglish ? Self.englishStopwords : Self.stopwords
        let words = MemoryStore.normalize(query).split(separator: " ").filter { $0.count >= 3 && !skipped.contains(String($0)) }
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0.prefix(max(3, $0.count - 2)))\"*" }.joined(separator: " OR ")
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return [] }
        var statement: OpaquePointer?
        let sql = "SELECT id, title, snippet(chats, 2, '«', '»', '…', 24), date FROM chats WHERE chats MATCH ? ORDER BY rank LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, match, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit + 1))
        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            guard id != excluding else { continue }
            hits.append(Hit(id: id, title: String(cString: sqlite3_column_text(statement, 1)),
                            snippet: String(cString: sqlite3_column_text(statement, 2)),
                            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
        }
        return Array(hits.prefix(limit))
    }

    static let stopwords: Set<String> = ["che", "cosa", "come", "per", "con", "del", "della", "dei", "delle", "una", "uno", "gli", "le", "abbiamo",
                                          "avevamo", "parlato", "detto", "deciso", "quando", "sulla", "sul", "nella", "nel", "alla", "allo", "questo",
                                          "questa", "quella", "quello", "anche", "ancora", "ricordi", "chat", "conversazione", "volta"]

    /// In inglese si tolgono anche le parole inglesi che non dicono di cosa si parlava.
    static let englishStopwords: Set<String> = stopwords.union([
        "the", "and", "what", "when", "did", "you", "about", "talked", "talk", "discussed", "decided", "said", "told", "tell", "remember",
        "conversation", "time", "last", "that", "this", "with", "for", "from", "was", "were", "have", "had", "our", "previous", "earlier",
        "again", "which", "where", "how", "there",
    ])
}
