import Foundation

/// Nome dell'app e cartelle su disco: un solo punto da cambiare.
public enum AppInfo {
    public static let name = "Siri AI+"
    /// Nome della cartella dati, del log e dei documenti.
    public static let folderName = "Siri AI+"
    /// Nome e identificatore della versione precedente (per la migrazione dei dati).
    public static let legacyName = "Siri" + "AI"
    public static let legacyBundleID = "com.ivanmosetti.siriai"
}

public enum AppPaths {
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `~/Library/Application Support/<app>/`
    public static var support: URL {
        ensure(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: AppInfo.folderName))
    }

    public static func support(_ name: String) -> URL { support.appending(path: name) }

    /// `~/Documents/<app>/`
    public static var documents: URL {
        ensure(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: AppInfo.folderName))
    }

    public static var logFile: URL {
        ensure(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs")).appending(path: "\(AppInfo.folderName).log")
    }

    public static var models: URL { ensure(support("Models")) }
    public static var backups: URL { ensure(support("Backup")) }
}

/// Registro su file: una riga alla volta, anche da più thread.
public enum LogFile {
    private static let queue = DispatchQueue(label: "app.log")

    public static func append(_ text: String) {
        let line = "[\(Date.now.formatted(.iso8601))] \(text)\n"
        let url = AppPaths.logFile
        queue.async {
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let data = Data(line.utf8)
            data.withUnsafeBytes { buffer in _ = write(fd, buffer.baseAddress, buffer.count) }
        }
    }
}

/// Elemento decodificato senza far fallire l'intero elenco: se è illeggibile vale `nil`.
public struct Lossy<T: Decodable>: Decodable {
    public let value: T?
    public init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

public enum SafeJSON {
    /// Decodifica un elenco scartando solo gli elementi illeggibili (e lo segnala nel log).
    public static func decodeArray<T: Decodable>(_ type: T.Type, from data: Data, label: String) -> [T]? {
        guard let items = try? JSONDecoder().decode([Lossy<T>].self, from: data) else {
            LogFile.append("DATI ILLEGGIBILI: \(label) non decodificabile")
            return nil
        }
        let values = items.compactMap(\.value)
        if values.count < items.count { LogFile.append("DATI: \(label) — \(items.count - values.count) elementi illeggibili scartati") }
        return values
    }

    /// Scrittura atomica; se il file esiste già lo copia prima in `.bak`.
    public static func write(_ data: Data, to url: URL, keepBackup: Bool = false) {
        if keepBackup, FileManager.default.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: url, to: bak)
        }
        try? data.write(to: url, options: .atomic)
    }
}

/// Copia giornaliera dei dati (se ne tengono 5).
public enum DataBackup {
    public static let files = ["conversations.json", "projects.json", "agents.json", "memory.json", "mcp.json", "spaces.json", "activity.json"]

    public static func runDaily(keep: Int = 5) {
        let day = Date.now.localDay
        let folder = AppPaths.backups.appending(path: day)
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files where FileManager.default.fileExists(atPath: AppPaths.support(name).path) {
            try? FileManager.default.copyItem(at: AppPaths.support(name), to: folder.appending(path: name))
        }
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: AppPaths.backups.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for old in all.dropLast(keep) { try? FileManager.default.removeItem(at: AppPaths.backups.appending(path: old)) }
        LogFile.append("BACKUP: \(folder.lastPathComponent)")
    }
}
