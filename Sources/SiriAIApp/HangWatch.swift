import AppKit
import SiriCore

/// Sorvegliante dell'interfaccia: un thread a parte chiede al thread principale di rispondere ogni secondo e mezzo. Se l'app
/// resta ferma più a lungo (con l'app davanti e il Mac sveglio), `sample` fotografa cosa sta facendo, al massimo una volta ogni
/// 10 minuti, in `~/Library/Logs/Siri AI+ blocchi/`, e il registro segna quanto è durato il blocco. Così un «ogni tanto si
/// blocca» diventa una riga del registro con il punto esatto del codice.
enum HangWatch {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var answered = true
        var active = true
    }

    private static let state = State()
    /// Oltre questa attesa (in secondi) il thread principale è considerato bloccato.
    private static let limit = 1.5

    static func start() {
        // Con l'app dietro le altre macOS la rallenta da solo (App Nap): lì un'attesa non è un blocco.
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            state.lock.withLock { state.active = true }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in
            state.lock.withLock { state.active = false }
        }
        let thread = Thread { watch() }
        thread.name = "Sorvegliante dell'interfaccia"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func watch() {
        var lastSample = -Double.infinity
        while true {
            state.lock.withLock { state.answered = false }
            // `systemUptime` si ferma quando il Mac dorme: il sonno non conta come blocco.
            let sent = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { state.lock.withLock { state.answered = true } }
            Thread.sleep(forTimeInterval: limit)
            let (answered, active) = state.lock.withLock { (state.answered, state.active) }
            guard !answered, active else {
                if !answered { waitForAnswer() }
                continue
            }
            var photo: String?
            if ProcessInfo.processInfo.systemUptime - lastSample > 600 {
                lastSample = ProcessInfo.processInfo.systemUptime
                photo = sample()
            }
            waitForAnswer()
            let seconds = ProcessInfo.processInfo.systemUptime - sent
            LogFile.append(String(format: "BLOCCO DELL'INTERFACCIA: %.1f s", seconds) + (photo.map { " · foto: \($0)" } ?? ""))
        }
    }

    private static func waitForAnswer() {
        while !state.lock.withLock({ state.answered }) { Thread.sleep(forTimeInterval: 0.1) }
    }

    /// Due secondi di `sample` sul processo dell'app (si tengono le ultime 10 foto).
    private static func sample() -> String? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Siri AI+ blocchi")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in old.dropFirst(9) { try? FileManager.default.removeItem(at: file) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let file = folder.appending(path: "blocco-\(formatter.string(from: .now)).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? file.lastPathComponent : nil
    }
}
