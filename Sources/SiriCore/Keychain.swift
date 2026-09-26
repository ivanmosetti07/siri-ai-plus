import Foundation
import Security

/// Segreti (chiavi API, token dei connettori) in un file leggibile solo dall'utente, nella cartella dati dell'app.
///
/// Prima stavano nel Portachiavi, ma senza un certificato Apple macOS lega ogni voce alla singola build
/// («partizione» per impronta del codice): a ogni aggiornamento di Siri AI+ chiedeva di nuovo la password.
/// Alla prima lettura la voce del Portachiavi viene copiata qui una volta sola; poi il Portachiavi non si legge più.
public enum Keychain {
    static var service: String { (Bundle.main.bundleIdentifier ?? "com.ivanmosetti.siriai") + ".secrets" }

    /// Le istanze di prova (`--ephemeral`) non leggono né scrivono segreti (salvo `SIRIAI_TEST_MCP=1`).
    static let disabled = ProcessInfo.processInfo.arguments.contains("--ephemeral")
        && ProcessInfo.processInfo.environment["SIRIAI_TEST_MCP"] == nil

    struct Vault: Codable {
        var values: [String: String] = [:]
        /// Voci già copiate dal Portachiavi (o riscritte qui): il Portachiavi per loro non si apre più.
        var migrated: Set<String> = []
    }

    /// Nei test un file temporaneo al posto di quello vero.
    nonisolated(unsafe) static var fileOverride: URL?
    static var fileURL: URL { fileOverride ?? AppPaths.support("segreti.json") }
    private static let lock = NSLock()

    public static func get(_ account: String) -> String? {
        guard !disabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        var vault = read()
        if let value = vault.values[account] { return value }
        guard !vault.migrated.contains(account) else { return nil }
        // Una sola volta: la voce del Portachiavi (macOS può chiedere la password quest'ultima volta).
        let legacy = legacyGet(account)
        vault.migrated.insert(account)
        if let legacy { vault.values[account] = legacy }
        write(vault)
        return legacy
    }

    @discardableResult
    public static func set(_ value: String?, for account: String) -> Bool {
        guard !disabled else { return false }
        lock.lock(); defer { lock.unlock() }
        var vault = read()
        vault.migrated.insert(account)
        if let value, !value.isEmpty { vault.values[account] = value } else { vault.values.removeValue(forKey: account) }
        return write(vault)
    }

    static func read() -> Vault {
        guard let data = try? Data(contentsOf: fileURL), let vault = try? JSONDecoder().decode(Vault.self, from: data) else { return Vault() }
        return vault
    }

    /// File a 0600 fin dalla creazione, poi sostituzione atomica: il contenuto non è mai leggibile da altri utenti.
    @discardableResult
    static func write(_ vault: Vault) -> Bool {
        guard let data = try? JSONEncoder().encode(vault) else { return false }
        let folder = fileURL.deletingLastPathComponent()
        let temporary = folder.appending(path: ".segreti-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    static func legacyGet(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
