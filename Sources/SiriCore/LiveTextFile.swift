import Foundation

/// Lettura e salvataggio ottimistico di file testuali aperti nell'editor.
public enum LiveTextFile {
    public struct Snapshot: Sendable, Equatable {
        public let text: String
        public let data: Data
    }

    public enum EditError: LocalizedError {
        case notText, tooLarge, changed, missing

        public var errorDescription: String? {
            switch self {
            case .notText: "Il file non è testo UTF-8 modificabile. Aprilo nell'app originale."
            case .tooLarge: "Il file supera 2 MB: aprilo nell'app originale."
            case .changed: "Il file è stato modificato anche fuori da Siri AI+. Ricaricalo prima di salvare."
            case .missing: "Il file non esiste più nel percorso originale."
            }
        }
    }

    public static func read(_ url: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { throw EditError.missing }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw EditError.tooLarge }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw EditError.notText }
        return Snapshot(text: text, data: data)
    }

    @discardableResult
    public static func save(_ text: String, to url: URL, expected: Snapshot) throws -> Snapshot {
        let current = try read(url)
        guard current.data == expected.data else { throw EditError.changed }
        let data = Data(text.utf8)
        guard data.count <= 2_000_000 else { throw EditError.tooLarge }
        try data.write(to: url, options: .atomic)
        return Snapshot(text: text, data: data)
    }
}
