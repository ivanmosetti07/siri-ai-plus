import AVFoundation
import Foundation
import SQLite3

/// Diagnostica (`--index-probe`): con l'accesso completo al disco legge la struttura dell'indice di Mail
/// e del database di Messaggi (tabelle, colonne, quantità). Solo letture.
public enum IndexProbe {
    public static func run() async -> [String] {
        var lines = ["ACCESSO DISCO: \(SystemAccess.fullDiskAccess)"]
        guard SystemAccess.fullDiskAccess else { return lines }
        if let url = MailIndex.databaseURL {
            lines.append("INDICE MAIL: \(url.path)")
            lines += describe(url, tables: ["messages", "subjects", "addresses", "mailboxes", "summaries", "recipients", "labels", "attachments", "message_global_data"])
            var db: OpaquePointer?
            if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db {
                defer { sqlite3_close(db) }
                lines.append("CASELLE: " + rows(db, "SELECT ROWID, url, total_count, unread_count FROM mailboxes ORDER BY ROWID LIMIT 90").joined(separator: " | "))
                lines.append("ESEMPIO: " + rows(db, "SELECT m.ROWID, m.mailbox, m.date_received, m.read, m.flagged, m.deleted FROM messages m ORDER BY m.date_received DESC LIMIT 5").joined(separator: " | "))
            }
        } else {
            lines.append("INDICE MAIL: non trovato in ~/Library/Mail")
        }
        let start = Date.now
        do {
            let page = try MailIndex.messages(in: .unifiedInbox, limit: 60)
            lines.append("MAIL VELOCE in arrivo: \(page.items.count) di \(page.total) · \(Int(Date.now.timeIntervalSince(start) * 1000)) ms")
            let boxes = try MailIndex.mailboxes()
            lines.append("MAIL VELOCE caselle: \(boxes.count): " + boxes.prefix(30).map { "\($0.account ?? "*")/\($0.name)=\($0.kind.rawValue)[\($0.unread)]" }.joined(separator: " "))
        } catch {
            lines.append("MAIL VELOCE: ERRORE \(error.localizedDescription)")
        }
        if ProcessInfo.processInfo.environment["SIRIAI_PROBE_MAIL"] != nil { lines += await mailboxPaths() }
        // Memo Vocali: dove sono le registrazioni e com'è fatto il loro database.
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in ["Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", "Library/Application Support/com.apple.voicememos/Recordings"] {
            let url = home.appending(path: folder)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            lines.append("MEMO \(folder): \(files.count) file · \(files.filter { $0.hasSuffix(".m4a") || $0.hasSuffix(".qta") }.count) audio · \(files.filter { !$0.hasSuffix(".m4a") && !$0.hasSuffix(".qta") }.prefix(12).joined(separator: ", "))")
            let db = url.appending(path: "CloudRecordings.db")
            if FileManager.default.fileExists(atPath: db.path) {
                var handle: OpaquePointer?
                if sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle {
                    lines.append("MEMO TABELLE: " + rows(handle, "SELECT name FROM sqlite_master WHERE type = 'table'").joined(separator: ", "))
                    for table in ["ZCLOUDRECORDING", "ZFOLDER"] {
                        lines.append("MEMO \(table): " + rows(handle, "PRAGMA table_info(\(table))", column: 1).joined(separator: ", "))
                    }
                    lines.append("MEMO ESEMPIO: " + rows(handle, "SELECT Z_PK, ZDATE, ZDURATION, substr(IFNULL(ZCUSTOMLABEL,''),1,30), ZPATH, IFNULL(ZFOLDER,''), IFNULL(ZEVICTIONDATE,''), length(ZENCRYPTEDTITLE) FROM ZCLOUDRECORDING ORDER BY ZDATE DESC LIMIT 4").joined(separator: " | "))
                    lines.append("MEMO ETICHETTE: " + rows(handle, "SELECT substr(IFNULL(ZCUSTOMLABEL,''),1,40) FROM ZCLOUDRECORDING ORDER BY ZDATE DESC LIMIT 34").joined(separator: " | "))
                    for path in rows(handle, "SELECT ZPATH FROM ZCLOUDRECORDING WHERE ZEVICTIONDATE IS NULL ORDER BY ZDATE DESC LIMIT 3") {
                        let file = url.appending(path: path)
                        let asset = AVURLAsset(url: file)
                        let metadata = (try? await asset.load(.metadata)) ?? []
                        var described: [String] = []
                        for item in metadata {
                            let value = (try? await item.load(.stringValue)) ?? ""
                            described.append("\(item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "?")=\(value.prefix(40))")
                        }
                        let data = (try? Data(contentsOf: file, options: .mappedIfSafe)) ?? Data()
                        let transcript = data.range(of: Data("tsrp".utf8)).map { range -> String in
                            let bytes = [UInt8](data[max(0, range.lowerBound - 4)..<range.lowerBound])
                            let size = bytes.reduce(0) { $0 << 8 | Int($1) }
                            let payload = data[range.upperBound..<min(data.count, range.upperBound + 260)]
                            return "tsrp a \(range.lowerBound) di \(data.count), atomo \(size) byte: " + String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
                        } ?? "niente tsrp"
                        lines.append("MEMO FILE \(path): \(described.joined(separator: ", ")) · \(transcript)")
                    }
                    sqlite3_close(handle)
                }
            }
        }
        lines += describe(MessagesService.database, tables: ["chat", "message", "handle", "chat_message_join", "chat_handle_join"])
        let chatStart = Date.now
        do {
            let chats = try MessagesStore.chats()
            lines.append("MESSAGGI: \(chats.count) conversazioni, senza testo \(chats.filter { $0.lastText == "Allegato" }.count) · \(Int(Date.now.timeIntervalSince(chatStart) * 1000)) ms")
            if let first = chats.first {
                let items = try MessagesStore.messages(chat: first.id)
                lines.append("MESSAGGI STORICO: \(items.count), vuoti \(items.filter { $0.text.isEmpty && !$0.hasAttachment }.count)")
            }
        } catch {
            lines.append("MESSAGGI: ERRORE \(error.localizedDescription)")
        }
        return lines
    }

    /// Come si chiamano in AppleScript le caselle dell'indice (percorso intero o solo l'ultimo nome)?
    static func mailboxPaths() async -> [String] {
        guard SystemAccess.automation("com.apple.mail") == .granted, let url = MailIndex.databaseURL else { return ["PERCORSI: Mail non autorizzata"] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        let candidates = rows(db, """
        SELECT b.url, (SELECT MAX(m.ROWID) FROM messages m WHERE m.mailbox = b.ROWID) FROM mailboxes b
        WHERE b.total_count > 0 AND (b.url LIKE '%/INBOX/%' OR b.url LIKE '%5BGmail%5D%' OR b.url LIKE '%/INBOX') ORDER BY b.total_count DESC LIMIT 6
        """)
        sqlite3_close(db)
        var lines: [String] = []
        for candidate in candidates {
            let parts = candidate.components(separatedBy: ",")
            guard parts.count >= 2, let parsed = MailIndex.parse(url: parts[0]), let id = Int(parts[1]) else { continue }
            let leaf = parsed.name.components(separatedBy: "/").last ?? parsed.name
            let stripped = parsed.name.hasPrefix("INBOX/") ? String(parsed.name.dropFirst(6)) : parsed.name
            for name in Array(Set([parsed.name, leaf, stripped])) {
                let start = Date.now
                let script = "tell application \"Mail\"\nset theBox to mailbox \(AppleScript.quote(name)) of account id \(AppleScript.quote(parsed.accountID))\nreturn (count of messages of theBox) & \" · \" & (subject of (first message of theBox whose id is \(id)))\nend tell"
                do {
                    let output = try await AppleScript.run(script, app: "Mail")
                    lines.append("PERCORSO «\(name)» di \(parsed.accountID.prefix(8)): OK \(output.prefix(50)) · \(Int(Date.now.timeIntervalSince(start) * 1000)) ms")
                } catch {
                    lines.append("PERCORSO «\(name)» di \(parsed.accountID.prefix(8)): ERRORE \(error.localizedDescription.prefix(90)) · \(Int(Date.now.timeIntervalSince(start) * 1000)) ms")
                }
            }
        }
        // Contenuto dalla posta unificata: quanto costa aprire un'email.
        if let first = try? MailIndex.messages(in: .unifiedInbox, limit: 1).items.first {
            let start = Date.now
            do {
                let content = try await MailStore.content(of: first.id, in: .unifiedInbox)
                lines.append("CONTENUTO: \(content.content.count) caratteri · \(Int(Date.now.timeIntervalSince(start) * 1000)) ms")
            } catch {
                lines.append("CONTENUTO: ERRORE \(error.localizedDescription.prefix(120)) · \(Int(Date.now.timeIntervalSince(start) * 1000)) ms")
            }
        }
        return lines
    }

    static func describe(_ url: URL, tables: [String]) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return ["\(url.lastPathComponent): non apribile"] }
        defer { sqlite3_close(db) }
        return tables.map { table in
            let columns = rows(db, "PRAGMA table_info(\(table))", column: 1)
            let count = rows(db, "SELECT COUNT(*) FROM \(table)").first ?? "?"
            return "TABELLA \(table) [\(count)]: " + (columns.isEmpty ? "assente" : columns.joined(separator: ", "))
        }
    }

    static func rows(_ db: OpaquePointer, _ sql: String, column: Int32? = nil) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return ["ERRORE \(String(cString: sqlite3_errmsg(db)))"] }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            let indexes = column.map { [$0] } ?? Array(0..<count)
            result.append(indexes.map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "∅"
            }.joined(separator: ","))
        }
        return result
    }
}
