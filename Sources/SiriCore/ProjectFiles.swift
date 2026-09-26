import AppKit
import Foundation
import PDFKit

/// Accesso ai file di un progetto, confinato alla sua cartella.
public struct ProjectFiles: Sendable {
    public struct Entry: Sendable, Identifiable, Equatable {
        public var id: String { path }
        public let path: String
        public let isDirectory: Bool
        public let size: Int
    }

    public struct Match: Sendable {
        public let path: String
        public let snippet: String
    }

    public enum FileError: LocalizedError {
        case outsideProject(String)
        case notFound(String)
        case unreadable(String)
        case readOnly(String)
        case virtualRoot(String)

        public var errorDescription: String? {
            switch self {
            case .outsideProject(let p): Language.t("«\(p)» è fuori dalla cartella del progetto.", "“\(p)” is outside the project folder.")
            case .notFound(let p): Language.t("«\(p)» non esiste nel progetto.", "“\(p)” doesn't exist in the project.")
            case .unreadable(let p): Language.t("Non riesco a leggere il testo di «\(p)».", "I can't read the text of “\(p)”.")
            case .readOnly(let p): Language.t("La cartella «\(p)» è collegata in sola lettura.", "The folder “\(p)” is linked as read-only.")
            case .virtualRoot(let p): Language.t("«\(p)» va messo dentro una delle cartelle collegate (es. «Cartella/\(p)»).",
                                                 "“\(p)” must go inside one of the linked folders (e.g. “Folder/\(p)”).")
            }
        }
    }

    public let root: URL
    /// Cartelle collegate (agenti): nome visibile → cartella reale. Se ci sono, la radice mostra solo queste.
    public var links: [String: URL] = [:]
    /// Cartelle collegate in sola lettura.
    public var readOnly: Set<String> = []
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "json", "csv", "tsv", "yaml", "yml", "xml", "html", "css",
                                              "js", "ts", "swift", "py", "rb", "go", "java", "kt", "c", "h", "m", "sh", "toml", "ini", "log"]

    static let heavyFolders: Set<String> = ["node_modules", ".build", "build", "DerivedData", "Pods", "venv", ".venv", "__pycache__", "dist", ".next", ".swiftpm"]

    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    /// Converte un percorso relativo in URL, rifiutando tutto ciò che esce dalla cartella.
    public func resolve(_ relative: String) throws -> URL {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Percorsi dentro una cartella collegata: «NomeCartella/sotto/file.md».
        if !links.isEmpty, !trimmed.isEmpty {
            let first = String(trimmed.split(separator: "/", maxSplits: 1)[0])
            guard let base = links[first] ?? links.first(where: { $0.key.lowercased() == first.lowercased() })?.value else {
                throw FileError.outsideProject(relative)
            }
            let base_ = base.standardizedFileURL.resolvingSymlinksInPath()
            let rest = trimmed.dropFirst(first.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let url = (rest.isEmpty ? base_ : base_.appending(path: rest)).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path == base_.path || url.path.hasPrefix(base_.path + "/") else { throw FileError.outsideProject(relative) }
            return url
        }
        let url = (trimmed.isEmpty ? root : root.appending(path: trimmed)).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { throw FileError.outsideProject(relative) }
        return url
    }

    public func relativePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        for (name, base) in links {
            let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
            if path == basePath { return name }
            if path.hasPrefix(basePath + "/") { return name + "/" + path.dropFirst(basePath.count + 1) }
        }
        return path == root.path ? "" : String(path.dropFirst(root.path.count + 1))
    }

    /// Elenco dei file (esclusi nascosti e .siriai), fino alla profondità indicata.
    public func list(_ relative: String = "", depth: Int = 2, limit: Int = 300) -> [Entry] {
        guard let base = try? resolve(relative) else { return [] }
        var result: [Entry] = []
        func walk(_ url: URL, level: Int) {
            // Radice virtuale con le cartelle collegate.
            if !links.isEmpty, url.standardizedFileURL.path == root.standardizedFileURL.path {
                for (name, folder) in links.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) where result.count < limit {
                    result.append(Entry(path: name, isDirectory: true, size: 0))
                    walk(folder, level: level + 1)
                }
                return
            }
            guard level <= depth, result.count < limit,
                  let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                                           options: [.skipsHiddenFiles]) else { return }
            for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDir = values?.isDirectory ?? false
                result.append(Entry(path: relativePath(item), isDirectory: isDir, size: values?.fileSize ?? 0))
                // Cartelle generate (dipendenze, build): elencate ma non esplorate.
                if isDir, !Self.heavyFolders.contains(item.lastPathComponent) { walk(item, level: level + 1) }
                if result.count >= limit { return }
            }
        }
        walk(base, level: 1)
        return result
    }

    /// Tutti i file e le cartelle, livello per livello (prima la radice), saltando cartelle pesanti.
    /// Il risultato resta in memoria qualche secondo (ogni richiesta lo chiedeva più volte) e si svuota a ogni modifica.
    public func allEntries(limit: Int = 6000) -> [Entry] {
        let key = cacheKey
        if let cached = EntryCache.shared.get(key, limit: limit) { return cached }
        let entries = scanEntries(limit: limit)
        EntryCache.shared.set(key, entries: entries, limit: limit)
        return entries
    }

    private var cacheKey: String { root.path + "|" + links.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.path)" }.joined(separator: ";") }

    /// Da chiamare dopo ogni modifica ai file.
    public func invalidateCache() { EntryCache.shared.clear() }

    private func scanEntries(limit: Int) -> [Entry] {
        var result: [Entry] = []
        var queue = links.isEmpty ? [root] : links.sorted(by: { $0.key < $1.key }).map(\.value)
        for name in links.keys.sorted() { result.append(Entry(path: name, isDirectory: true, size: 0)) }
        let skipped = Self.heavyFolders
        while !queue.isEmpty, result.count < limit {
            let url = queue.removeFirst()
            guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                                            options: [.skipsHiddenFiles]) else { continue }
            for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDir = values?.isDirectory ?? false
                result.append(Entry(path: relativePath(item), isDirectory: isDir, size: values?.fileSize ?? 0))
                if isDir && !skipped.contains(item.lastPathComponent) { queue.append(item) }
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// Il file o la cartella che corrisponde meglio a un nome approssimativo ("tasks.md", "3_Risorse/OBJECTIVES.md", "obiettivi").
    public func find(_ hint: String, directories: Bool = false, fuzzy: Bool = true) -> String? {
        let cleaned = hint.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/\"'`«»")))
        guard !cleaned.isEmpty else { return nil }
        let lower = cleaned.lowercased()
        // Il disco del Mac ignora maiuscole e minuscole: si restituisce il nome com'è scritto davvero.
        if exists(cleaned), isDirectory(cleaned) == directories,
           let url = try? resolve(cleaned), let real = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            let relative = relativePath(URL(fileURLWithPath: real))
            return relative.lowercased() == lower ? relative : cleaned
        }
        let name = (lower as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let entries = allEntries().filter { directories ? $0.isDirectory : !$0.isDirectory }
        func base(_ e: Entry) -> String { (e.path.lowercased() as NSString).lastPathComponent }
        if let exact = entries.first(where: { $0.path.lowercased() == lower }) { return exact.path }
        if let sameName = entries.first(where: { base($0) == name }) { return sameName.path }
        guard fuzzy else { return nil }
        if stem.count >= 3, let sameStem = entries.first(where: { (base($0) as NSString).deletingPathExtension == stem }) { return sameStem.path }
        if stem.count >= 4, let partial = entries.first(where: { base($0).contains(stem) }) { return partial.path }
        return nil
    }

    /// Sposta o rinomina un file o una cartella dentro il progetto.
    public func move(_ from: String, to destination: String) throws {
        try ensureWritable(from)
        try ensureWritable(destination)
        let source = try resolve(from)
        guard FileManager.default.fileExists(atPath: source.path) else { throw FileError.notFound(from) }
        let target = try resolve(destination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: target)
        invalidateCache()
    }

    public func createFolder(_ relative: String) throws {
        try ensureWritable(relative)
        try FileManager.default.createDirectory(at: try resolve(relative), withIntermediateDirectories: true)
        invalidateCache()
    }

    /// Sposta nel Cestino del Mac (recuperabile), mai cancellazione definitiva. Restituisce dove è finito (per annullare).
    @discardableResult
    public func trash(_ relative: String) throws -> URL? {
        try ensureWritable(relative)
        let url = try resolve(relative)
        guard url.path != root.path else { throw FileError.outsideProject(relative) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileError.notFound(relative) }
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        invalidateCache()
        return resulting as URL?
    }

    public func isDirectory(_ relative: String) -> Bool {
        var isDir: ObjCBool = false
        guard let url = try? resolve(relative) else { return false }
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Testo del file: formati testuali, RTF/Word/Pages via AppKit, PDF via PDFKit.
    public func read(_ relative: String, maxChars: Int = 3000) throws -> String {
        let url = try resolve(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileError.notFound(relative) }
        let text = try Self.text(of: url)
        return text.count > maxChars ? String(text.prefix(maxChars)) + Language.t("\n[…troncato]", "\n[…truncated]") : text
    }

    static func text(of url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) || ext.isEmpty {
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        }
        if ext == "pdf", let s = PDFDocument(url: url)?.string { return s }
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) { return attributed.string }
        throw FileError.unreadable(url.lastPathComponent)
    }

    /// Cerca nei nomi e nel contenuto dei file testuali.
    public func search(_ query: String, limit: Int = 20) -> [Match] {
        let needle = query.lowercased()
        var matches: [Match] = []
        for entry in allEntries() where !entry.isDirectory {
            if matches.count >= limit { break }
            if entry.path.lowercased().contains(needle) {
                matches.append(Match(path: entry.path, snippet: Language.t("nome del file", "file name")))
                continue
            }
            let ext = (entry.path as NSString).pathExtension.lowercased()
            guard Self.textExtensions.contains(ext), entry.size < 1_000_000,
                  let url = try? resolve(entry.path), let text = try? String(contentsOf: url, encoding: .utf8),
                  let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            matches.append(Match(path: entry.path, snippet: text[start..<end].replacingOccurrences(of: "\n", with: " ")))
        }
        return matches
    }

    public func exists(_ relative: String) -> Bool {
        (try? resolve(relative)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Le cartelle collegate in sola lettura non si modificano.
    public func ensureWritable(_ relative: String) throws {
        let first = String(relative.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).split(separator: "/", maxSplits: 1).first ?? "")
        if readOnly.contains(where: { $0.lowercased() == first.lowercased() }) { throw FileError.readOnly(first) }
        if !links.isEmpty, !relative.contains("/") || first.isEmpty { throw FileError.virtualRoot(relative) }
    }

    public func write(_ relative: String, content: String) throws {
        try ensureWritable(relative)
        let url = try resolve(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        invalidateCache()
    }

    // MARK: AGENTS.md e memoria

    /// AGENTS.md alla radice, qualunque sia la capitalizzazione.
    public var agentsURL: URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.first { $0.lowercased() == "agents.md" }.map { root.appending(path: $0) }
    }

    /// MEMORY.md alla radice (qualunque capitalizzazione), come AGENTS.md. Se manca viene creato al primo uso.
    public var memoryURL: URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.first { $0.lowercased() == "memory.md" }.map { root.appending(path: $0) } ?? root.appending(path: "MEMORY.md")
    }

    var legacyMemoryURL: URL { root.appending(path: ".siriai/memory.md") }

    static let memoryHeading = "## Ricordi di \(AppInfo.name)"
    /// Titolo scritto dalla versione precedente: si riconosce e si aggiorna.
    static let legacyMemoryHeading = "## Ricordi di \(AppInfo.legacyName)"

    /// Crea MEMORY.md se manca (portando dentro i fatti della vecchia `.siriai/memory.md`).
    @discardableResult
    public func ensureMemoryFile() -> URL {
        let url = memoryURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        let legacy = (try? String(contentsOf: legacyMemoryURL, encoding: .utf8))?
            .split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }.joined(separator: "\n") ?? ""
        let body = """
        # Memoria del progetto

        Fatti, decisioni e preferenze da ricordare in questo progetto. Siri AI+ la legge a ogni conversazione del progetto \
        e aggiunge qui sotto ciò che le chiedi di ricordare. Puoi modificarla liberamente.

        \(Self.memoryHeading)

        \(legacy)
        """
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Testo completo di MEMORY.md.
    public func memoryText() -> String {
        let text = (try? String(contentsOf: memoryURL, encoding: .utf8)) ?? ""
        return text.replacingOccurrences(of: Self.legacyMemoryHeading + "\n", with: Self.memoryHeading + "\n")
    }

    public func saveMemoryText(_ text: String) throws {
        try text.write(to: memoryURL, atomically: true, encoding: .utf8)
    }

    /// Fatti salvati da Siri AI+ (righe "- …" sotto «Ricordi di Siri AI+»; se la sezione non c'è, tutte le righe di elenco).
    public func memoryFacts() -> [String] {
        let text = memoryText()
        var section = text.range(of: Self.memoryHeading).map { String(text[$0.upperBound...]) } ?? text
        if text.contains(Self.memoryHeading), let next = section.range(of: "\n## ") { section = String(section[..<next.lowerBound]) }
        return section.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return nil }
            return String(trimmed.dropFirst(2))
        }
    }

    /// Sostituisce i fatti della sezione di Siri AI+ lasciando intatto il resto del file.
    public func saveMemory(_ facts: [String]) throws {
        ensureMemoryFile()
        var text = memoryText()
        let list = facts.map { "- \($0)" }.joined(separator: "\n")
        if let range = text.range(of: Self.memoryHeading) {
            // La sezione arriva fino al prossimo titolo "## " o alla fine.
            let after = text[range.upperBound...]
            let end = after.range(of: "\n## ")?.lowerBound ?? text.endIndex
            text.replaceSubrange(range.upperBound..<end, with: "\n\n" + list + "\n")
        } else {
            text += (text.hasSuffix("\n") ? "" : "\n") + "\n\(Self.memoryHeading)\n\n\(list)\n"
        }
        try saveMemoryText(text)
    }

    @discardableResult
    public func remember(_ fact: String) throws -> Bool {
        let cleaned = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        var facts = memoryFacts()
        let dated = "[\(Date.now.localDay)] \(cleaned)"
        guard !cleaned.isEmpty, !facts.contains(where: { MemoryStore.normalize($0).contains(MemoryStore.normalize(cleaned)) }) else { return false }
        facts.append(dated)
        try saveMemory(facts)
        return true
    }
}

/// Elenchi dei file già letti, per pochi secondi.
final class EntryCache: @unchecked Sendable {
    static let shared = EntryCache()
    private let lock = NSLock()
    private var items: [String: (date: Date, limit: Int, entries: [ProjectFiles.Entry])] = [:]
    private let lifetime: TimeInterval = 8

    func get(_ key: String, limit: Int) -> [ProjectFiles.Entry]? {
        lock.lock(); defer { lock.unlock() }
        guard let item = items[key], Date.now.timeIntervalSince(item.date) < lifetime else { return nil }
        // Vale se era stato letto con un limite almeno uguale, oppure se l'elenco era completo.
        guard item.limit >= limit || item.entries.count < item.limit else { return nil }
        return Array(item.entries.prefix(limit))
    }

    func set(_ key: String, entries: [ProjectFiles.Entry], limit: Int) {
        lock.lock(); defer { lock.unlock() }
        items[key] = (.now, limit, entries)
        if items.count > 20 { items.removeAll() }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}
