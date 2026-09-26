import AppKit
import Foundation

/// Passaggio da «SiriAI» a «Siri AI+»: sposta dati, log e documenti, aggiorna i percorsi salvati e porta le impostazioni.
/// Gira una sola volta, all'avvio, prima di leggere qualunque dato.
public enum Migration {
    static let marker = "migrato-da-siriai"

    public struct Report: Sendable {
        public var moved: [String] = []
        public var closedOldApp = false
        public var ran = false
    }

    @MainActor @discardableResult
    public static func runIfNeeded() -> Report {
        var report = Report()
        let fm = FileManager.default
        let supportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldSupport = supportRoot.appending(path: AppInfo.legacyName)
        let newSupport = supportRoot.appending(path: AppInfo.folderName)
        guard !fm.fileExists(atPath: newSupport.appending(path: marker).path) else { return report }
        guard fm.fileExists(atPath: oldSupport.path) else {
            try? fm.createDirectory(at: newSupport, withIntermediateDirectories: true)
            fm.createFile(atPath: newSupport.appending(path: marker).path, contents: Data())
            return report
        }
        report.ran = true
        // La vecchia app non deve scrivere mentre si spostano i dati: si chiude (salva prima di uscire).
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.legacyBundleID) {
            app.terminate()
            report.closedOldApp = true
            for _ in 0..<40 where !app.isTerminated { RunLoop.current.run(until: .now.addingTimeInterval(0.25)) }
        }

        var replacements: [(String, String)] = []
        func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        /// Sposta; se la destinazione esiste già (cartelle create da un avvio precedente) unisce il contenuto, voce per voce.
        func merge(_ from: URL, _ to: URL) {
            if !fm.fileExists(atPath: to.path) {
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fm.moveItem(at: from, to: to)) != nil { report.moved.append(to.lastPathComponent) }
            } else if isDirectory(from), isDirectory(to), let items = try? fm.contentsOfDirectory(atPath: from.path) {
                for item in items { merge(from.appending(path: item), to.appending(path: item)) }
            } else if !isDirectory(from), !isDirectory(to) {
                // Prima della migrazione la nuova cartella contiene solo file di prova: valgono i dati della versione precedente.
                try? fm.trashItem(at: to, resultingItemURL: nil)
                if (try? fm.moveItem(at: from, to: to)) != nil { report.moved.append(to.lastPathComponent) }
            }
        }
        func move(_ from: URL, _ to: URL) {
            guard fm.fileExists(atPath: from.path) else { return }
            merge(from, to)
            replacements.append((from.path, to.path))
        }

        move(oldSupport, newSupport)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        move(documents.appending(path: AppInfo.legacyName), documents.appending(path: AppInfo.folderName))
        let logs = fm.homeDirectoryForCurrentUser.appending(path: "Library/Logs")
        let oldLog = logs.appending(path: "\(AppInfo.legacyName).log"), newLog = logs.appending(path: "\(AppInfo.folderName).log")
        if fm.fileExists(atPath: oldLog.path), !fm.fileExists(atPath: newLog.path) { try? fm.moveItem(at: oldLog, to: newLog) }

        // Percorsi assoluti salvati (progetti, immagini, ritratti degli agenti, documenti esportati).
        for name in ["projects.json", "conversations.json", "agents.json", "code-sessions.json", "spaces.json", "mcp.json"] {
            let url = newSupport.appending(path: name)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let original = text
            for (from, to) in replacements {
                text = text.replacingOccurrences(of: from, with: to)
                text = text.replacingOccurrences(of: from.replacingOccurrences(of: "/", with: "\\/"), with: to.replacingOccurrences(of: "/", with: "\\/"))
            }
            if text != original { try? text.write(to: url, atomically: true, encoding: .utf8) }
        }

        // Impostazioni: il nuovo identificatore dell'app parte vuoto, si copiano quelle della versione precedente.
        if let old = UserDefaults.standard.persistentDomain(forName: AppInfo.legacyBundleID) {
            for (key, value) in old where UserDefaults.standard.object(forKey: key) == nil && !key.hasPrefix("NS") && !key.hasPrefix("com.apple") {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        try? fm.createDirectory(at: newSupport, withIntermediateDirectories: true)
        fm.createFile(atPath: newSupport.appending(path: marker).path, contents: Data())
        UserDefaults.standard.set(true, forKey: "migrationNotice")
        LogFile.append("MIGRAZIONE da \(AppInfo.legacyName): \(report.moved) · vecchia app chiusa: \(report.closedOldApp)")
        return report
    }
}
