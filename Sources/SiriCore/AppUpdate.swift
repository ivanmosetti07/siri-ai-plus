import Foundation

/// Una versione più recente pubblicata su GitHub.
public struct AppUpdate: Sendable, Equatable {
    /// «2.1» (senza la «v» del tag).
    public let version: String
    /// Pagina della release, con le novità.
    public let pageURL: URL
    /// Lo ZIP dell'app da scaricare (la pagina della release se non ce n'è uno).
    public let downloadURL: URL
    /// Le prime righe delle novità.
    public let notes: String

    public init(version: String, pageURL: URL, downloadURL: URL, notes: String) {
        self.version = version; self.pageURL = pageURL; self.downloadURL = downloadURL; self.notes = notes
    }
}

/// Controllo degli aggiornamenti: l'ultima release del repository confrontata con la versione installata.
/// Solo una lettura pubblica (nessun dato inviato oltre alla richiesta); senza rete non succede nulla.
public enum UpdateChecker {
    public static let repository = "ivanmosetti07/siri-ai-plus"

    public enum Outcome: Sendable, Equatable {
        case available(AppUpdate)
        case upToDate(latest: String)
        /// Niente rete, GitHub non risponde o risposta illeggibile: si riprova più tardi.
        case failed
    }

    /// La versione dell'app in uso (CFBundleShortVersionString).
    public static var installedVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// «v2.10.1» → [2, 10, 1]. Le parti non numeriche («2.1-beta») contano per la cifra iniziale.
    public static func components(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        let plain = trimmed.lowercased().hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        return plain.split(separator: ".").map { part in Int(part.prefix { $0.isNumber }) ?? 0 }
    }

    /// Più recente parte per parte («2.10» è dopo «2.9», «2.1» è uguale a «2.1.0»). Una versione installata più nuova
    /// di quella su GitHub (chi compila l'app da sé) non propone di tornare indietro.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = components(remote), b = components(local)
        guard !a.isEmpty else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Legge l'ultima release pubblicata (non le bozze né le anteprime).
    public static func check(installed: String?, session: URLSession = .shared) async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return .failed }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Siri-AI-Plus/\(installed ?? "0")", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
        return outcome(from: data, installed: installed)
    }

    /// La risposta di GitHub (`releases/latest`) confrontata con la versione installata.
    public static func outcome(from data: Data, installed: String?) -> Outcome {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String, !components(tag).isEmpty,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return .failed }
        let version = tag.lowercased().hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let installed, isNewer(version, than: installed) else { return .upToDate(latest: version) }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
        let download = (zip?["browser_download_url"] as? String).flatMap(URL.init(string:)) ?? page
        let body = (json["body"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        // Testo semplice per la finestrella: niente titoli Markdown né grassetti.
        let notes = body.split(separator: "\n", omittingEmptySubsequences: true).prefix(6)
            .map { $0.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression).replacingOccurrences(of: "**", with: "") }
            .joined(separator: "\n")
        return .available(AppUpdate(version: version, pageURL: page, downloadURL: download, notes: String(notes.prefix(600))))
    }
}
