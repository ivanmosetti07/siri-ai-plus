import AVFoundation
import Foundation
import Speech
import SQLite3

// MARK: - Memo Vocali (app Memo Vocali dentro Siri AI+)
//
// Le registrazioni di Memo Vocali si leggono dal suo database (serve l'accesso completo al disco): data, durata, file audio.
// Apple cifra titoli e cartelle, ma salva la trascrizione dentro il file (blocco «tsrp»): la si legge da lì.
// Le registrazioni fatte in Siri AI+ stanno in Documenti/Siri AI+/Memo vocali e si possono rinominare ed eliminare.

public struct VoiceMemo: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let url: URL
    public let date: Date
    public let duration: TimeInterval
    /// Nome scelto in Siri AI+ (le registrazioni di Memo Vocali hanno il titolo cifrato: nil).
    public var name: String?
    /// Registrata in Siri AI+: si può rinominare ed eliminare.
    public let isOwn: Bool
    /// Inizio della trascrizione, per riconoscerla nell'elenco.
    public var preview: String?

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var title: String {
        if let name, !name.isEmpty { return name }
        return date.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Dates.locale))
    }

    public var durationText: String { VoiceMemo.format(duration) }

    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

public enum VoiceMemosStore {
    static var recordings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
    }

    static var database: URL { recordings.appending(path: "CloudRecordings.db") }

    /// Registrazioni fatte in Siri AI+.
    public static var ownFolder: URL {
        let url = AppPaths.documents.appending(path: "Memo vocali")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Trascrizioni calcolate da Siri AI+ per le registrazioni di Memo Vocali senza trascrizione di Apple.
    static var transcriptsFolder: URL {
        let url = AppPaths.support("Trascrizioni")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Memo Vocali leggibile (serve l'accesso completo al disco).
    public static var readable: Bool {
        FileManager.default.isReadableFile(atPath: database.path) && SystemAccess.fullDiskAccess
    }

    /// Tutte le registrazioni (Memo Vocali, senza quelle eliminate di recente, e Siri AI+), dalla più recente.
    public static func memos() -> [VoiceMemo] {
        var result = appleMemos() + ownMemos()
        result.sort { $0.date > $1.date }
        return result
    }

    static func appleMemos() -> [VoiceMemo] {
        guard readable else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        var statement: OpaquePointer?
        let sql = "SELECT Z_PK, ZDATE, ZDURATION, ZPATH FROM ZCLOUDRECORDING WHERE ZEVICTIONDATE IS NULL AND ZPATH IS NOT NULL ORDER BY ZDATE DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [VoiceMemo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = MessagesStore.text(statement, 3)
            let url = recordings.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let id = "vm:\(sqlite3_column_int64(statement, 0))"
            result.append(VoiceMemo(id: id, url: url, date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)),
                                    duration: sqlite3_column_double(statement, 2), name: nil, isOwn: false,
                                    preview: transcriptPreview(id: id, url: url)))
        }
        return result
    }

    static func ownMemos() -> [VoiceMemo] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: ownFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "m4a" }.map { url in
            let date = (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? .now
            let duration = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
            let id = "own:" + url.lastPathComponent
            return VoiceMemo(id: id, url: url, date: date, duration: duration, name: url.deletingPathExtension().lastPathComponent,
                             isOwn: true, preview: transcriptPreview(id: id, url: url))
        }
    }

    // MARK: Trascrizioni

    static func transcriptPreview(id: String, url: URL) -> String? {
        guard let text = storedTranscript(id: id, url: url) else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).prefix(14).joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    /// Trascrizione già pronta: quella di Apple dentro il file, o quella salvata da Siri AI+.
    public static func storedTranscript(id: String, url: URL) -> String? {
        if let embedded = embeddedTranscript(url) { return embedded }
        let saved = savedTranscriptURL(id: id, url: url)
        return (try? String(contentsOf: saved, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func savedTranscriptURL(id: String, url: URL) -> URL {
        id.hasPrefix("own:") ? url.deletingPathExtension().appendingPathExtension("txt")
            : transcriptsFolder.appending(path: id.replacingOccurrences(of: ":", with: "-") + ".txt")
    }

    public static func saveTranscript(_ text: String, for memo: VoiceMemo) {
        try? Data(text.utf8).write(to: savedTranscriptURL(id: memo.id, url: memo.url), options: .atomic)
    }

    /// Trascrizione di Memo Vocali: blocco «tsrp» del file (JSON con i pezzi di testo e i tempi).
    public static func embeddedTranscript(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return transcript(inFile: data)
    }

    static func transcript(inFile data: Data) -> String? {
        guard let marker = data.range(of: Data("tsrp".utf8), options: .backwards), marker.lowerBound >= 4 else { return nil }
        let size = data[(marker.lowerBound - 4)..<marker.lowerBound].reduce(0) { $0 << 8 | Int($1) }
        let end = size > 8 ? min(data.count, marker.lowerBound - 4 + size) : data.count
        guard end > marker.upperBound else { return nil }
        return transcript(json: data[marker.upperBound..<end])
    }

    static func transcript(json: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let attributed = object["attributedString"] as? [String: Any],
              let runs = attributed["runs"] as? [Any] else { return nil }
        let text = runs.compactMap { $0 as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Trascrive sul Mac con il riconoscimento vocale di sistema (in italiano; scarica il modello la prima volta).
    public static func transcribe(_ url: URL, locale: Locale = Locale(identifier: "it_IT")) async throws -> String {
        let chosen = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(locale: chosen, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected: String = transcriber.results.reduce(into: "") { text, result in
            text += String(result.text.characters)
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Registrazioni di Siri AI+

    /// File per una registrazione nuova: «Registrazione 23 set 2026 18.05.m4a».
    public static func newRecordingURL(now: Date = .now) -> URL {
        let name = Language.t("Registrazione ", "Recording ") + now.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Dates.locale))
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        return FileStore.freeName(name, ext: "m4a", in: ownFolder)
    }

    /// Rinomina una registrazione fatta in Siri AI+ (con la sua trascrizione).
    public static func rename(_ memo: VoiceMemo, to name: String) throws -> URL {
        guard memo.isOwn else { throw storeError(Language.t("Le registrazioni di Memo Vocali si rinominano in Memo Vocali.", "Rename Voice Memos recordings in the Voice Memos app.")) }
        let transcript = savedTranscriptURL(id: memo.id, url: memo.url)
        let renamed = try FileStore.rename(memo.url, to: name)
        if FileManager.default.fileExists(atPath: transcript.path) {
            try? FileManager.default.moveItem(at: transcript, to: renamed.deletingPathExtension().appendingPathExtension("txt"))
        }
        return renamed
    }

    /// Nel Cestino (si recupera dal Finder), con la trascrizione.
    public static func trash(_ memo: VoiceMemo) throws {
        guard memo.isOwn else { throw storeError(Language.t("Le registrazioni di Memo Vocali si eliminano in Memo Vocali.", "Delete Voice Memos recordings in the Voice Memos app.")) }
        let transcript = savedTranscriptURL(id: memo.id, url: memo.url)
        try FileStore.trash(memo.url)
        if FileManager.default.fileExists(atPath: transcript.path) { try? FileStore.trash(transcript) }
    }

    static func storeError(_ message: String) -> NSError {
        NSError(domain: AppInfo.name, code: 30, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
