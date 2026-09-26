import Foundation

// MARK: - Note (app Note dentro Siri AI+)

public struct NotesFolder: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let account: String
    public let accountID: String
    public var count: Int
    /// «Eliminate di recente»: si mostra in fondo e non si modifica.
    public var isTrash: Bool { ["recently deleted", "eliminate di recente", "eliminati di recente"].contains(name.lowercased()) }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct NoteSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var modified: Date
    public var preview: String
    public var folderID: String
}

public enum NotesStore {
    /// Account e cartelle, con il numero di note.
    public static func folders() async throws -> [NotesFolder] {
        let script = """
        set sep to character id 31
        set rs to character id 30
        set out to ""
        tell application "Notes"
            repeat with acc in accounts
                set accName to name of acc
                set accID to id of acc
                set folderIDs to id of every folder of acc
                set folderNames to name of every folder of acc
                repeat with i from 1 to count of folderIDs
                    set fid to item i of folderIDs
                    set n to 0
                    try
                        set n to count of notes of folder id fid
                    end try
                    set out to out & accName & sep & accID & sep & fid & sep & (item i of folderNames) & sep & n & rs
                end repeat
            end repeat
        end tell
        return out
        """
        return AppleScript.records(try await AppleScript.run(script, app: "Note")).compactMap { f in
            guard f.count >= 5 else { return nil }
            return NotesFolder(id: f[2], name: f[3], account: f[0], accountID: f[1], count: Int(f[4]) ?? 0)
        }
    }

    /// Note di una cartella (nil = tutte), dalla modificata più di recente.
    public static func notes(in folderID: String?) async throws -> [NoteSummary] {
        let container = folderID.map { "notes of folder id \(AppleScript.quote($0))" } ?? "notes"
        let script = """
        set sep to character id 31
        set rs to character id 30
        tell application "Notes"
            set theIDs to id of \(container)
            set theNames to name of \(container)
            set theDates to modification date of \(container)
            set theTexts to plaintext of \(container)
        end tell
        set now to current date
        set out to ""
        repeat with i from 1 to count of theIDs
            set age to 0
            try
                set age to (now - (item i of theDates)) as integer
            end try
            set t to item i of theTexts
            if t is missing value then set t to ""
            if length of t > 240 then set t to text 1 thru 240 of t
            set out to out & (item i of theIDs) & sep & (item i of theNames) & sep & age & sep & t & rs
        end repeat
        return out
        """
        return parseNotes(try await AppleScript.run(script, app: "Note"), folderID: folderID ?? "")
    }

    static func parseNotes(_ output: String, folderID: String, now: Date = .now) -> [NoteSummary] {
        AppleScript.records(output).compactMap { f -> NoteSummary? in
            guard f.count >= 4, !f[0].isEmpty else { return nil }
            // L'anteprima è il testo dopo il titolo, su una riga.
            var body = f[3].components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if body.first == f[1] { body.removeFirst() }
            return NoteSummary(id: f[0], title: f[1].isEmpty ? Language.t("Nuova nota", "New Note") : f[1], modified: now.addingTimeInterval(-Double(Int(f[2]) ?? 0)),
                               preview: body.joined(separator: " "), folderID: folderID)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// Nuova nota nella cartella; restituisce l'identificativo.
    @discardableResult
    public static func create(title: String, body: String, in folderID: String?) async throws -> String {
        let html = html(title: title, body: body)
        let location = folderID.map { " at folder id \(AppleScript.quote($0))" } ?? ""
        return try await AppleScript.run("""
        tell application "Notes"
            set nt to make new note\(location) with properties {body:\(AppleScript.quote(html))}
            return id of nt
        end tell
        """, app: "Note").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nuova nota già formattata (HTML di Note); restituisce l'identificativo.
    @discardableResult
    public static func create(html: String, in folderID: String?) async throws -> String {
        let location = folderID.map { " at folder id \(AppleScript.quote($0))" } ?? ""
        return try await AppleScript.run("""
        tell application "Notes"
            set nt to make new note\(location) with properties {body:\(AppleScript.quote(html))}
            return id of nt
        end tell
        """, app: "Note").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Identificativi delle note di una cartella (per togliere quelle eliminate da «Tutte le note»).
    public static func ids(in folderID: String) async throws -> Set<String> {
        let output = try await AppleScript.run("""
        set rs to character id 30
        tell application "Notes" to set theIDs to id of notes of folder id \(AppleScript.quote(folderID))
        set AppleScript's text item delimiters to rs
        return theIDs as string
        """, app: "Note")
        return Set(output.components(separatedBy: AppleScript.record).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    /// Salva il nuovo HTML se la nota non è cambiata nel frattempo (altrimenti errore: meglio non sovrascrivere).
    public static func save(id: String, html: String, expectedHTML: String) async throws -> String {
        try await NotesService.replaceBody(id: id, html: html, expectedHTML: expectedHTML).html
    }

    /// HTML di Note per un titolo e un testo semplice.
    static func html(title: String, body: String) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let paragraphs = body.components(separatedBy: "\n").map { $0.isEmpty ? "<div><br></div>" : "<div>\(escape($0))</div>" }.joined()
        return "<div><h1>\(escape(title.isEmpty ? Language.t("Nuova nota", "New Note") : title))</h1></div>" + paragraphs
    }

    /// Nel Cestino di Note («Eliminate di recente»): si recupera da lì per 30 giorni.
    public static func delete(_ id: String) async throws {
        _ = try await AppleScript.run("tell application \"Notes\" to delete note id \(AppleScript.quote(id))", app: "Note")
    }

    public static func move(_ id: String, to folderID: String) async throws {
        _ = try await AppleScript.run("tell application \"Notes\" to move note id \(AppleScript.quote(id)) to folder id \(AppleScript.quote(folderID))", app: "Note")
    }

    @discardableResult
    public static func createFolder(_ name: String, accountID: String) async throws -> String {
        try await AppleScript.run("""
        tell application "Notes"
            set f to make new folder at account id \(AppleScript.quote(accountID)) with properties {name:\(AppleScript.quote(name))}
            return id of f
        end tell
        """, app: "Note").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func renameFolder(_ id: String, to name: String) async throws {
        _ = try await AppleScript.run("tell application \"Notes\" to set name of folder id \(AppleScript.quote(id)) to \(AppleScript.quote(name))", app: "Note")
    }

    /// Le note della cartella finiscono in «Eliminate di recente».
    public static func deleteFolder(_ id: String) async throws {
        _ = try await AppleScript.run("tell application \"Notes\" to delete folder id \(AppleScript.quote(id))", app: "Note")
    }

    /// Si può riscrivere da fuori senza perdere nulla? Liste (forse con caselle), tabelle, allegati e disegni no.
    public static func canRewrite(_ html: String) -> Bool {
        NotesService.canAppendSafely(html)
    }
}
