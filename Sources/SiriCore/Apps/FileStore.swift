import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - File (un piccolo Finder dentro Siri AI+)

public struct FileEntry: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isFolder: Bool
    public let isPackage: Bool
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    public let kind: String

    public var ext: String { url.pathExtension.lowercased() }

    public func hash(into hasher: inout Hasher) { hasher.combine(url) }

    /// Simbolo SF per il tipo di file.
    public var symbol: String {
        if isFolder { return "folder.fill" }
        if isPackage { return ext == "app" ? "app.dashed" : "shippingbox" }
        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if ["md", "txt", "rtf"].contains(ext) { return "doc.text" }
        if type?.conforms(to: .sourceCode) == true || ["swift", "js", "ts", "py", "json", "html", "css", "sh"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        if ["pages", "docx", "doc"].contains(ext) { return "doc.richtext" }
        if ["numbers", "xlsx", "xls", "csv"].contains(ext) { return "tablecells" }
        if ["key", "pptx", "ppt"].contains(ext) { return "rectangle.on.rectangle" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        return "doc"
    }
}

public enum FileStore {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                         .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey, .isHiddenKey]

    public static func entry(_ url: URL) -> FileEntry? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let isFolder = values.isDirectory == true && values.isPackage != true
        return FileEntry(url: url, name: FileManager.default.displayName(atPath: url.path), isFolder: isFolder,
                         isPackage: values.isPackage == true, size: isFolder ? nil : Int64(values.fileSize ?? 0),
                         modified: values.contentModificationDate, created: values.creationDate,
                         kind: values.localizedTypeDescription ?? (isFolder ? "Cartella" : "Documento"))
    }

    /// Contenuto della cartella: prima le cartelle, poi i file, in ordine alfabetico.
    public static func list(_ folder: URL, showHidden: Bool = false) throws -> [FileEntry] {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.compactMap(entry).sortedByFolderThenName()
    }

    /// Nome libero nella cartella: «Nuova cartella», «Nuova cartella 2»…
    public static func freeName(_ base: String, ext: String = "", in folder: URL) -> URL {
        let suffix = ext.isEmpty ? "" : "." + ext
        var candidate = folder.appending(path: base + suffix)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base) \(number)\(suffix)")
            number += 1
        }
        return candidate
    }

    @discardableResult
    public static func newFolder(in folder: URL, name: String = "Nuova cartella") throws -> URL {
        let url = freeName(name, in: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @discardableResult
    public static func newTextFile(in folder: URL, name: String = "Senza titolo", ext: String = "md", content: String = "") throws -> URL {
        let url = freeName(name, ext: ext, in: folder)
        try Data(content.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Rinomina tenendo l'estensione se non è stata scritta.
    @discardableResult
    public static func rename(_ url: URL, to newName: String) throws -> URL {
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty else { return url }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if !isFolder, !url.pathExtension.isEmpty, (name as NSString).pathExtension.isEmpty { name += "." + url.pathExtension }
        let target = url.deletingLastPathComponent().appending(path: name)
        guard target.path != url.path else { return url }
        guard !FileManager.default.fileExists(atPath: target.path) || target.path.lowercased() == url.path.lowercased() else {
            throw NSError(domain: AppInfo.name, code: 20, userInfo: [NSLocalizedDescriptionKey: "Esiste già un elemento chiamato «\(name)»."])
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Copia accanto all'originale: «nome copia.ext».
    @discardableResult
    public static func duplicate(_ url: URL) throws -> URL {
        let base = url.deletingPathExtension().lastPathComponent + " copia"
        let target = freeName(base, ext: url.pathExtension, in: url.deletingLastPathComponent())
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    /// Nel Cestino (si recupera dal Finder). Restituisce dove è finito.
    @discardableResult
    public static func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Sposta nella cartella (senza sovrascrivere).
    @discardableResult
    public static func move(_ url: URL, into folder: URL) throws -> URL {
        let target = freeName(url.deletingPathExtension().lastPathComponent, ext: url.pathExtension, in: folder)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Cerca con Spotlight nella cartella (nome e contenuto).
    public static func search(_ query: String, in folder: URL, limit: Int = 200) async -> [FileEntry] {
        let output: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                process.arguments = ["-onlyin", folder.path, query]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                guard (try? process.run()) != nil else { continuation.resume(returning: ""); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
        return output.split(separator: "\n").lazy
            .map(String.init)
            .filter { !$0.contains("/.") && !$0.contains("/node_modules/") && !$0.contains("/Library/Caches/") }
            .prefix(limit)
            .compactMap { entry(URL(fileURLWithPath: $0)) }
    }

    /// Cartelle che non servono a chi guarda i file di un progetto (dipendenze, build, cache).
    static let heavyFolders: Set<String> = [".git", "node_modules", ".build", "build", "dist", "DerivedData", ".next", ".nuxt", ".svelte-kit",
                                            "Pods", ".venv", "venv", "__pycache__", ".cache", ".turbo", "vendor", ".swiftpm", ".obsidian", ".trash"]

    /// I file di una cartella e delle sottocartelle, senza nascosti, dipendenze e build (al massimo `maxItems` visitati).
    static func walk(_ folder: URL, maxItems: Int = 30_000) -> [URL] {
        var files: [URL] = []
        var visited = 0
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL, visited < maxItems {
            visited += 1
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true {
                if heavyFolders.contains(url.lastPathComponent) { enumerator?.skipDescendants() }
                continue
            }
            files.append(url)
        }
        return files
    }

    /// I file cambiati più di recente in una cartella (un progetto), dal più recente.
    public static func recentlyModified(in folder: URL, limit: Int = 60) async -> [FileEntry] {
        await Task.detached(priority: .userInitiated) {
            let dated = walk(folder).compactMap { url -> (URL, Date)? in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) }
            }
            return dated.sorted { $0.1 > $1.1 }.prefix(limit).compactMap { entry($0.0) }
        }.value
    }

    /// Cerca per nome nella cartella: prima Spotlight (nome e contenuto), poi i nomi dei file se Spotlight non trova nulla
    /// (cartelle non indicizzate).
    public static func find(_ query: String, in folder: URL, limit: Int = 200) async -> [FileEntry] {
        let found = await search(query, in: folder, limit: limit)
        guard found.isEmpty else { return found }
        let needle = query.lowercased()
        return await Task.detached(priority: .userInitiated) {
            Array(walk(folder).filter { $0.lastPathComponent.lowercased().contains(needle) }.prefix(limit).compactMap { entry($0) })
        }.value
    }

    /// File usati di recente (Spotlight), dal più recente.
    public static func recents(limit: Int = 80) async -> [FileEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let found = await search("kMDItemLastUsedDate >= $time.today(-14) && kMDItemContentTypeTree != public.folder", in: home, limit: 400)
        return Array(found.filter { !$0.isFolder && !$0.url.path.contains("/Library/") }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            .prefix(limit))
    }
}

extension Array where Element == FileEntry {
    func sortedByFolderThenName() -> [FileEntry] {
        sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
