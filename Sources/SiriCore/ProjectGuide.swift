import Foundation

// MARK: - Come muoversi in un progetto
//
// Una chat collegata a un progetto usa la sua cartella come contesto principale. Le istruzioni della cartella (AGENTS.md,
// CLAUDE.md, GEMINI.md e quelle delle sottocartelle) dicono come comportarsi e dove stanno le cose; spesso contengono una
// mappa «per questa richiesta apri questo file» (anche negli INDEX.md). La guida legge istruzioni e mappa, conosce l'albero
// dei file (senza ciò che .claudeignore esclude) e, per ogni richiesta, sceglie i file da aprire prima di rispondere.
// Vale per tutti i modelli: Apple Intelligence riceve i file già aperti, gli altri anche le istruzioni complete.

public final class ProjectGuide: @unchecked Sendable {
    /// File di istruzioni per gli agenti, alla radice e nelle sottocartelle.
    static let instructionNames = ["CLAUDE.md", "AGENTS.md", "GEMINI.md"]
    /// Mappe di navigazione alla radice.
    static let indexNames = ["INDEX.md"]
    /// File d'ingresso di una cartella, in ordine di preferenza.
    static let entryNames = ["INDEX.md", "README.md", "STATE.md", "CLAUDE.md", "AGENTS.md"]
    /// Cartelle che non si esplorano (dipendenze, build, sistema).
    static let skipped: Set<String> = ["node_modules", ".build", "build", "DerivedData", "Pods", "venv", ".venv", "__pycache__", "dist",
                                       ".next", ".swiftpm", ".git", ".obsidian", ".trash", ".claude", ".codex", ".agents", ".siriai"]
    static let textExtensions: Set<String> = ["md", "markdown", "txt", "csv", "json", "yaml", "yml", "html", "css", "js", "ts", "swift", "py", "toml"]

    /// Una riga delle istruzioni o degli indici che indica quali file aprire per un tipo di richiesta.
    public struct Route: Sendable, Equatable {
        public let trigger: String
        public let paths: [String]
        let stems: Set<String>
    }

    /// Un file scelto per una richiesta, con il motivo.
    public struct Pick: Sendable, Equatable {
        public let path: String
        public let reason: String
        public let score: Int
    }

    public let root: URL
    private let lock = NSLock()
    private var loadedSignature = ""
    private var instructionTexts: [(name: String, text: String)] = []
    private var routeList: [Route] = []
    private var ignore = IgnoreRules()
    private var tree: Tree?
    private var building: Task<Tree, Never>?
    private var folderInstructionCache: [String: String?] = [:]
    /// Grafi già calcolati (per cartella), validi finché l'albero è lo stesso.
    private var graphs: [String: (tree: Date, graph: ProjectGraph)] = [:]

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: ProjectGuide] = [:]

    /// La guida di una cartella (una sola per cartella, con tutto ciò che ha già letto).
    public static func shared(for root: URL) -> ProjectGuide {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        return registryLock.withLock {
            if let guide = registry[key] { return guide }
            let guide = ProjectGuide(root: root)
            registry[key] = guide
            return guide
        }
    }

    /// Dopo una modifica ai file: al prossimo uso l'albero si rilegge.
    public static func invalidate(_ root: URL) {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.withLock { registry[key] }?.invalidateTree()
    }

    public func invalidateTree() {
        lock.withLock {
            tree = nil
            folderInstructionCache = [:]
            graphs = [:]
        }
    }

    func cachedGraph(_ key: String, tree: Date) -> ProjectGraph? {
        lock.withLock { graphs[key].flatMap { $0.tree == tree ? $0.graph : nil } }
    }

    func storeGraph(_ graph: ProjectGraph, key: String, tree: Date) {
        lock.withLock { graphs[key] = (tree, graph) }
    }

    // MARK: Istruzioni

    /// Rilegge istruzioni, mappe e .claudeignore se sono cambiati (bastano le date di modifica).
    private func refreshInstructions() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        func real(_ wanted: String) -> String? { names.first { $0.lowercased() == wanted.lowercased() } }
        let instructionFiles = Self.instructionNames.compactMap(real)
        let indexFiles = Self.indexNames.compactMap(real)
        let ignoreFiles = [".claudeignore", ".siriaiignore"].compactMap(real)
        let signature = (instructionFiles + indexFiles + ignoreFiles).map { name -> String in
            let date = (try? FileManager.default.attributesOfItem(atPath: root.appending(path: name).path)[.modificationDate] as? Date) ?? .distantPast
            return "\(name)@\(date.timeIntervalSince1970)"
        }.joined(separator: "|")
        lock.lock()
        let unchanged = signature == loadedSignature
        lock.unlock()
        guard !unchanged else { return }
        let texts = instructionFiles.compactMap { name in (try? String(contentsOf: root.appending(path: name), encoding: .utf8)).map { (name: name, text: $0) } }
        let indexes = indexFiles.compactMap { name in (try? String(contentsOf: root.appending(path: name), encoding: .utf8)).map { (name: name, text: $0) } }
        var rules = IgnoreRules()
        for name in ignoreFiles {
            if let text = try? String(contentsOf: root.appending(path: name), encoding: .utf8) { rules.add(text) }
        }
        let routes = (texts + indexes).flatMap { Self.routes(in: $0.text, root: root) }
        lock.withLock {
            instructionTexts = texts
            routeList = routes
            ignore = rules
            loadedSignature = signature
        }
    }

    /// Nomi dei file di istruzioni della radice («CLAUDE.md, AGENTS.md»).
    public var instructionFileNames: [String] {
        refreshInstructions()
        return lock.withLock { instructionTexts.map(\.name) }
    }

    /// Le istruzioni della radice, complete fino a `limit` caratteri (le righe già dette in un file non si ripetono nell'altro).
    public func instructions(limit: Int) -> String {
        refreshInstructions()
        let texts = lock.withLock { instructionTexts }
        guard !texts.isEmpty else { return "" }
        var seen = Set<String>()
        var parts: [String] = []
        for file in texts {
            var kept: [String] = []
            for line in Self.withoutFrontMatter(file.text).components(separatedBy: "\n") {
                let key = line.trimmingCharacters(in: .whitespaces)
                if key.count >= 40, !seen.insert(key).inserted { continue }
                kept.append(line)
            }
            parts.append("--- \(file.name) ---\n" + kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let all = parts.joined(separator: "\n\n")
        return all.count <= limit ? all : Self.cut(all, limit: limit)
    }

    /// Istruzioni delle cartelle che contengono `path` (CLAUDE.md, AGENTS.md sotto la radice), dalla più esterna alla più interna.
    public func folderInstructions(for path: String, limit: Int = 3000) -> [(folder: String, text: String)] {
        let components = path.split(separator: "/").map(String.init)
        let isFolder = FileManager.default.directoryExists(root.appending(path: path))
        let folders = isFolder ? components.count : max(0, components.count - 1)
        guard folders > 0 else { return [] }
        var result: [(String, String)] = []
        for depth in 1...folders {
            let folder = components.prefix(depth).joined(separator: "/")
            guard let text = folderInstruction(folder) else { continue }
            result.append((folder, Self.cut(Self.withoutFrontMatter(text), limit: limit)))
        }
        return result
    }

    private func folderInstruction(_ folder: String) -> String? {
        if let cached = lock.withLock({ folderInstructionCache[folder] }) { return cached }
        let url = root.appending(path: folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let file = Self.instructionNames.compactMap { wanted in names.first { $0.lowercased() == wanted.lowercased() } }.first
        let text = file.flatMap { try? String(contentsOf: url.appending(path: $0), encoding: .utf8) }
        lock.withLock { folderInstructionCache[folder] = .some(text) }
        return text
    }

    // MARK: Mappa delle istruzioni

    public var routes: [Route] {
        refreshInstructions()
        return lock.withLock { routeList }
    }

    /// Righe con collegamenti a file del progetto: «| obiettivi del trimestre | [OBJECTIVES.md](OBJECTIVES.md) |».
    static func routes(in text: String, root: URL) -> [Route] {
        var result: [Route] = []
        let linkPattern = #"\[([^\]]*)\]\(([^)\s]+)\)"#
        let codePattern = #"`([^`\s]+\.(?:md|txt|csv|json|yaml|yml)|[^`\s]+/)`"#
        var lines: [String] = []
        for raw in withoutFrontMatter(text).components(separatedBy: "\n") {
            // «stato di oggi → `STATE.md` · chi è una persona → `people-index.md`»: ogni coppia è una riga a sé.
            if raw.components(separatedBy: "→").count > 2 {
                lines += raw.components(separatedBy: " · ").flatMap { $0.components(separatedBy: "; ") }
            } else {
                lines.append(raw)
            }
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 8, !line.hasPrefix("#") else { continue }
            // `Web.matches` restituisce i soli gruppi: [testo, indirizzo] per i collegamenti, [percorso] per il codice.
            var targets: [(text: String, target: String)] = Web.matches(linkPattern, in: line).filter { $0.count > 1 }.map { ($0[0], $0[1]) }
            // Un nome senza cartella in una riga con segnaposto («2_Aree/<area>/CLAUDE.md, poi il suo `STATE.md`») è di un'altra cartella.
            let placeholders = line.contains("<")
            for match in Web.matches(codePattern, in: line) where !match.isEmpty && (!placeholders || match[0].contains("/")) {
                targets.append((match[0], match[0]))
            }
            var resolved: [(text: String, path: String)] = []
            for item in targets {
                if let path = resolveTarget(item.target, root: root), !resolved.contains(where: { $0.path == path }) { resolved.append((item.text, path)) }
            }
            guard !resolved.isEmpty else { continue }
            // Il testo della riga senza gli indirizzi: è ciò che l'utente potrebbe chiedere.
            var trigger = line.replacingOccurrences(of: linkPattern, with: "$1", options: .regularExpression)
            trigger = trigger.replacingOccurrences(of: #"[`*_|>«»"“”]"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if resolved.count >= 3 {
                // Righe-elenco («4 aree: mainstream · maiker · personal brand»): ogni collegamento vale solo per sé.
                for item in resolved {
                    let own = item.text + " " + nameWords((item.path as NSString).lastPathComponent == "INDEX.md"
                        ? (item.path as NSString).deletingLastPathComponent : item.path).joined(separator: " ")
                    let stems = Self.stems(own)
                    if !stems.isEmpty { result.append(Route(trigger: own, paths: [item.path], stems: stems)) }
                }
                continue
            }
            let stems = Self.stems(trigger)
            guard !stems.isEmpty else { continue }
            result.append(Route(trigger: trigger, paths: resolved.map(\.path), stems: stems))
        }
        return result
    }

    /// Indirizzo di un collegamento → percorso relativo esistente (senza «#sezione», «./», segnaposto o indirizzi web).
    static func resolveTarget(_ target: String, root: URL) -> String? {
        var path = target.removingPercentEncoding ?? target
        if path.contains("://") || path.hasPrefix("mailto:") || path.contains("<") || path.contains("*") { return nil }
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        while path.hasPrefix("./") { path.removeFirst(2) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !path.isEmpty, !path.hasPrefix("..") else { return nil }
        let url = root.appending(path: path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return path
    }

    // MARK: Albero dei file

    struct Tree: Sendable {
        var files: [String] = []
        var folders: [String] = []
        /// «2026-09-23» → file con quella data nel nome.
        var dated: [String: [String]] = [:]
        /// Nome della cartella in minuscolo → percorsi.
        var folderNames: [String: [String]] = [:]
        /// Nome del file (con e senza estensione) in minuscolo → percorsi.
        var fileNames: [String: [String]] = [:]
        /// In quante cartelle compare ogni parola dei nomi (le parole rare indicano clienti, aree, progetti).
        var folderWordCount: [String: Int] = [:]
        var built = Date.distantPast
    }

    /// L'albero dei file: si legge la prima volta (per cartelle grandi 1–2 secondi) e si rilegge dopo cinque minuti.
    public func prepare() async {
        _ = await currentTree()
    }

    /// Avvia la lettura dell'albero senza aspettarla (quando si apre una chat del progetto).
    public func prefetch() {
        Task.detached(priority: .utility) { [self] in _ = await self.currentTree() }
    }

    func currentTree() async -> Tree {
        refreshInstructions()
        let (existing, task) = lock.withLock { () -> (Tree?, Task<Tree, Never>?) in
            if let tree, Date.now.timeIntervalSince(tree.built) < 300 { return (tree, nil) }
            if let building { return (tree, building) }
            let rules = ignore
            let root = self.root
            let task = Task.detached(priority: .userInitiated) { Self.scan(root: root, ignore: rules) }
            building = task
            return (tree, task)
        }
        // Un albero un po' vecchio va bene mentre si rilegge.
        if let existing, task == nil || Date.now.timeIntervalSince(existing.built) < 3600 {
            if let task { Task { await self.finish(task) } }
            return existing
        }
        guard let task else { return existing ?? Tree() }
        return await finish(task)
    }

    @discardableResult
    private func finish(_ task: Task<Tree, Never>) async -> Tree {
        let fresh = await task.value
        lock.withLock {
            tree = fresh
            building = nil
        }
        return fresh
    }

    /// L'albero già letto (nil se non ancora pronto): per le parti sincrone.
    var readyTree: Tree? { lock.withLock { tree } }

    static func scan(root: URL, ignore: IgnoreRules, limit: Int = 80_000) -> Tree {
        var tree = Tree()
        // Percorsi relativi direttamente dall'enumeratore: con le cartelle dietro un collegamento («/var» → «/private/var»)
        // togliere il prefisso della radice tagliava i nomi.
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return tree }
        let datePattern = try? NSRegularExpression(pattern: #"(20\d{2})-(\d{2})-(\d{2})"#)
        while let path = enumerator.nextObject() as? String, tree.files.count + tree.folders.count < limit {
            let name = (path as NSString).lastPathComponent
            let isFolder = (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory
            if name.hasPrefix(".") {
                if isFolder { enumerator.skipDescendants() }
                continue
            }
            if isFolder {
                if skipped.contains(name) || ignore.excludes(path, isFolder: true) { enumerator.skipDescendants(); continue }
                tree.folders.append(path)
                tree.folderNames[name.lowercased(), default: []].append(path)
                for word in Set(nameWords(name)) { tree.folderWordCount[word, default: 0] += 1 }
            } else {
                if ignore.excludes(path, isFolder: false) { continue }
                tree.files.append(path)
                let lower = name.lowercased()
                tree.fileNames[lower, default: []].append(path)
                tree.fileNames[(lower as NSString).deletingPathExtension, default: []].append(path)
                let ext = (lower as NSString).pathExtension
                if textExtensions.contains(ext), let regex = datePattern,
                   let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                   let range = Range(match.range, in: name) {
                    tree.dated[String(name[range]), default: []].append(path)
                }
            }
        }
        tree.built = .now
        return tree
    }

    // MARK: File pertinenti a una richiesta

    /// Parole che non dicono di cosa si parla (in inglese si aggiungono quelle inglesi).
    static var stopwords: Set<String> { Language.isEnglish ? englishStopwords : italianStopwords }

    private static let englishStopwords: Set<String> = italianStopwords.union(Keywords.englishStopwords).union([
        "what", "how", "where", "when", "which", "why", "always", "before", "after", "also", "only", "open", "read", "show", "look",
        "tell", "want", "would", "could", "should", "can", "please", "make", "done", "this", "that", "these", "those", "all", "every",
        "request", "answer", "line", "lines", "above", "below", "here", "other", "not", "never", "more", "less", "very", "already",
        "still", "then", "without", "inside", "folder", "folders", "project", "projects", "file", "files",
    ])

    private static let italianStopwords: Set<String> = Set(Keywords.stopwords).union([
        "cosa", "come", "dove", "quando", "quale", "quali", "quanto", "quanti", "perche", "sempre", "prima", "dopo", "anche", "solo",
        "file", "apri", "aprila", "aprilo", "aprire", "leggi", "legge", "vedi", "guarda", "dimmi", "fammi", "voglio", "vorrei", "posso", "devo",
        "puoi", "fare", "fatto", "sono", "essere", "avere", "stai", "sta", "questo", "questa", "questi", "queste", "tutto", "tutti", "ogni",
        "richiesta", "riguarda", "rispondere", "risposta", "riga", "righe", "sopra", "sotto", "qui", "qua", "altro", "altra", "altri",
        "se", "non", "mai", "piu", "meno", "molto", "po", "gia", "ancora", "ecco", "via", "poi", "cui", "tra", "fra", "senza", "dentro",
        "second", "brain", "vault", "cartella", "cartelle", "progetto", "progetti", "md", "the", "and", "for", "vs", "es", "ecc",
    ])

    /// Radici delle parole significative (senza accenti, senza vocali finali).
    static func stems(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Dates.locale)
            .replacingOccurrences(of: "'", with: " ").replacingOccurrences(of: "’", with: " ")
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) && Int($0) == nil }
        return Set(words.map(Keywords.stem))
    }

    /// Parole del nome di una cartella o di un file («denny-store» → denny, store).
    static func nameWords(_ name: String) -> [String] {
        (name as NSString).deletingPathExtension.lowercased()
            .folding(options: [.diacriticInsensitive], locale: Dates.locale)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && Int($0) == nil }
    }

    /// Parole della richiesta che fanno pensare a una cronologia («cosa ho fatto», «cosa è successo», «registro»).
    static let historyCues = ["fatto", "fatta", "fatti", "successo", "success", "registro", "registri", "log", "diario", "cronologia",
                              "lavorato", "combinato", "chiuso", "deciso", "novità", "aggiornament", "cosa è cambiato", "cos'è cambiato"]
    /// Parole che chiedono lo stato di qualcosa.
    static let statusCues = ["come va", "stato", "situazione", "a che punto", "come sta", "aggiornamento", "novità", "cosa manca", "aperto", "aperti"]

    /// I file da aprire per una richiesta, dal più pertinente. Senza albero pronto usa solo mappa e nomi espliciti.
    public func relevant(to prompt: String, now: Date = .now, limit: Int = 4) -> [Pick] {
        refreshInstructions()
        let tree = readyTree
        let lower = " " + DateExpressions.normalized(prompt) + " "
        let folded = lower.folding(options: [.diacriticInsensitive], locale: Dates.locale)
        var picks: [String: Pick] = [:]
        func add(_ path: String, _ reason: String, _ score: Int) {
            if let existing = picks[path], existing.score >= score { return }
            picks[path] = Pick(path: path, reason: reason, score: score)
        }

        // 1. File nominati («TASKS.md», «la dashboard»).
        for token in Web.matches(#"([\w\-./]+\.(?:md|txt|csv|json|ya?ml|html|pdf))"#, in: prompt).compactMap(\.first) {
            let name = (token as NSString).lastPathComponent.lowercased()
            if FileManager.default.fileExists(atPath: root.appending(path: token).path) { add(token, "nominato", 12) }
            else if let path = tree?.fileNames[name]?.min(by: { $0.count < $1.count }) { add(path, "nominato", 11) }
        }
        if let tree {
            for word in Set(Self.nameWords(prompt)) where word.count >= 5 {
                // Solo file della radice o di primo livello: «dashboard», «objectives».
                if let path = tree.fileNames[word]?.filter({ $0.split(separator: "/").count <= 2 }).min(by: { $0.count < $1.count }),
                   (path as NSString).pathExtension.lowercased() == "md" { add(path, "nominato", 9) }
            }
        }

        // 2. Cartelle nominate (clienti, aree, progetti): il loro file d'ingresso.
        var namedFolders: [String] = []
        if let tree {
            for (name, paths) in tree.folderNames where name.count >= 4 {
                let words = Self.nameWords(name)
                guard !words.isEmpty else { continue }
                let phrase = " " + words.joined(separator: " ") + " "
                let compact = words.joined()
                let spaced = folded.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
                let fullMatch = spaced.contains(phrase) || (compact.count >= 6 && spaced.replacingOccurrences(of: " ", with: "").contains(compact) && words.count > 1)
                    || (words.count == 1 && compact.count >= 5 && spaced.contains(" \(compact) "))
                // Una parola rara del nome basta («maiker» per maiker-hub), una comune no («agency», «store»).
                let rare = words.first { $0.count >= 6 && (tree.folderWordCount[$0] ?? 0) <= 3 && spaced.contains(" \($0) ") }
                guard fullMatch || rare != nil, paths.count <= 3 else { continue }
                // Tra più cartelle con lo stesso nome, la meno profonda.
                guard let folder = paths.min(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) else { continue }
                // Le cartelle generiche della struttura (1_Progetti, 3_Risorse, log…) non sono argomenti.
                guard (tree.folderWordCount[words[0]] ?? 0) <= 3 || words.count > 1 else { continue }
                namedFolders.append(folder)
                if let entry = entry(of: folder) { add(entry, "cartella «\(folder.split(separator: "/").last ?? "")»", fullMatch ? 10 : 8) }
                if Self.statusCues.contains(where: lower.contains), let state = file(named: "STATE.md", in: folder), state != entry(of: folder) {
                    add(state, "stato di «\(folder.split(separator: "/").last ?? "")»", 9)
                }
            }
        }

        // 3. Un giorno citato con una domanda sulla cronologia: i file con quella data (registri, diari, note del giorno).
        if let tree, Self.historyCues.contains(where: lower.contains) || lower.contains(" log") {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let days = DateExpressions.days(in: prompt, now: now).map(\.date)
            let promptWords = Self.nameWords(prompt).filter { $0.count >= 5 && !Self.stopwords.contains($0) }
            for day in days.prefix(2) {
                let key = formatter.string(from: day)
                let files = (tree.dated[key] ?? []).filter { ($0 as NSString).pathExtension.lowercased() == "md" }
                // Prima i registri (…/log/…), poi quelli delle cartelle nominate, poi i più vicini alla radice.
                let sorted = files.sorted { a, b in
                    func rank(_ path: String) -> Int {
                        var value = path.split(separator: "/").count
                        if path.lowercased().contains("/log/") || path.lowercased().hasPrefix("log/") { value -= 5 }
                        if namedFolders.contains(where: { path.hasPrefix($0 + "/") }) { value -= 4 }
                        // «ieri in mainstream»: i registri della cartella che la richiesta nomina, anche solo in parte.
                        if promptWords.contains(where: { path.lowercased().contains($0) }) { value -= 4 }
                        return value
                    }
                    return rank(a) < rank(b)
                }
                for path in sorted.prefix(3) {
                    let named = namedFolders.contains { path.hasPrefix($0 + "/") } || promptWords.contains { path.lowercased().contains($0) }
                    let log = path.lowercased().contains("/log/") || path.lowercased().hasPrefix("log/")
                    add(path, "del \(key)", named ? 9 : (log && path.split(separator: "/").count <= 4 ? 7 : 6))
                }
            }
        }

        // 4. La mappa delle istruzioni: le righe che parlano di ciò che si chiede.
        var wanted = Self.stems(prompt)
        // «Chi è Martina?»: si cerca una persona.
        let asksWho = lower.range(of: #"\bchi (?:è|e'|era|sono|sarebbe)\b"#, options: .regularExpression) != nil
        if asksWho { wanted.formUnion([Keywords.stem("persona"), Keywords.stem("persone")]) }
        if !wanted.isEmpty {
            let scored = routes.compactMap { route -> (Route, Int)? in
                let common = route.stems.intersection(wanted)
                guard !common.isEmpty else { return nil }
                // Due parole in comune, o una sola ma lunga e specifica («obiettiv», «trimestr»).
                let strong = common.count >= 2 || common.contains { $0.count >= 7 } || (asksWho && common.contains(Keywords.stem("persona")))
                return strong ? (route, common.count * 3 + common.map(\.count).reduce(0, +) / 4) : nil
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.stems.count < $1.0.stems.count }
            for (route, score) in scored.prefix(3) {
                for path in route.paths.prefix(2) {
                    let target = FileManager.default.directoryExists(root.appending(path: path)) ? entry(of: path) : path
                    // Le istruzioni della radice sono già nel contesto; quelle di una sottocartella no.
                    if let target, (target as NSString).pathExtension.lowercased() != "",
                       target.contains("/") || !Self.instructionNames.contains(where: { $0.lowercased() == target.lowercased() }) {
                        add(target, "indicato dalle istruzioni", min(8, score))
                        // «Come va mainstream?»: con l'indice della cartella anche il suo stato.
                        let folder = (target as NSString).deletingLastPathComponent
                        if !folder.isEmpty, (target as NSString).lastPathComponent.lowercased() == "index.md", Self.statusCues.contains(where: lower.contains),
                           let state = file(named: "STATE.md", in: folder) {
                            add(state, "stato indicato dalle istruzioni", min(8, score) - 1)
                        }
                    }
                }
            }
        }
        let sorted = picks.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path.count < $1.path.count }
        // Solo i file vicini al migliore: gli altri sono rumore per il modello.
        let best = sorted.first?.score ?? 0
        return sorted.filter { $0.score >= best - 2 }.prefix(limit).map { $0 }
    }

    /// Il file con questo nome, come i collegamenti `[[Nome]]` di Obsidian: con o senza estensione, il più vicino alla radice.
    public func file(named name: String) async -> String? {
        let tree = await currentTree()
        let lower = name.lowercased()
        let candidates = (tree.fileNames[lower] ?? []) + (tree.fileNames[lower + ".md"] ?? [])
            + tree.files.filter { $0.lowercased().hasSuffix("/" + lower) || $0.lowercased().hasSuffix("/" + lower + ".md") }
        return candidates.min { $0.split(separator: "/").count != $1.split(separator: "/").count
            ? $0.split(separator: "/").count < $1.split(separator: "/").count : $0 < $1 }
    }

    /// La richiesta nomina un file o una cartella del progetto (vince sui riferimenti vaghi a ciò che è aperto nelle app).
    public func namesSomething(in prompt: String) -> Bool {
        relevant(to: prompt, limit: 6).contains { $0.reason == "nominato" || $0.reason.hasPrefix("cartella") }
    }

    /// File d'ingresso di una cartella (INDEX.md, README.md, STATE.md…).
    func entry(of folder: String) -> String? {
        for name in Self.entryNames { if let path = file(named: name, in: folder) { return path } }
        return nil
    }

    private func file(named name: String, in folder: String) -> String? {
        let url = root.appending(path: folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.first { $0.lowercased() == name.lowercased() }.map { folder.isEmpty ? $0 : folder + "/" + $0 }
    }

    // MARK: Estratti

    /// Il testo di un file per la risposta: tutto se sta nel limite, altrimenti l'inizio e i passaggi con le parole della richiesta.
    public func excerpt(of path: String, for prompt: String, limit: Int) -> String? {
        let url = root.appending(path: path)
        guard let text = try? ProjectFiles.text(of: url) else { return nil }
        let body = Self.withoutFrontMatter(text, keepSummary: true)
        guard body.count > limit else { return body }
        let head = String(body.prefix(limit * 30 / 100))
        // Lo schema del file (titoli con la prima riga di ciascuno): un file lungo si capisce anche senza leggerlo tutto.
        let outline = Self.outline(of: body, after: head.count, limit: limit * 30 / 100)
        var windows: [String] = []
        var used = head.count + outline.count
        let lowerBody = body.lowercased()
        let words = Self.nameWords(prompt).filter { $0.count >= 4 && !Self.stopwords.contains($0) }.sorted { $0.count > $1.count }
        for word in words.prefix(4) where used < limit - 200 {
            var search = lowerBody.index(lowerBody.startIndex, offsetBy: head.count, limitedBy: lowerBody.endIndex) ?? lowerBody.endIndex
            guard let range = lowerBody.range(of: word, range: search..<lowerBody.endIndex) else { continue }
            let start = lowerBody.index(range.lowerBound, offsetBy: -300, limitedBy: lowerBody.startIndex) ?? lowerBody.startIndex
            let end = lowerBody.index(range.upperBound, offsetBy: min(900, limit - used), limitedBy: lowerBody.endIndex) ?? lowerBody.endIndex
            let offsetStart = lowerBody.distance(from: lowerBody.startIndex, to: start)
            let offsetEnd = lowerBody.distance(from: lowerBody.startIndex, to: end)
            let window = String(Array(body)[offsetStart..<min(offsetEnd, body.count)])
            windows.append(window)
            used += window.count
            search = end
        }
        return head + "\n[…]\n" + (outline.isEmpty ? "" : "Schema del resto del file:\n\(outline)\n[…]\n")
            + windows.joined(separator: "\n[…]\n") + (windows.isEmpty ? "" : "\n[…]")
    }

    /// Titoli Markdown dopo `offset`, ognuno con la prima riga di testo che lo segue.
    static func outline(of body: String, after offset: Int, limit: Int) -> String {
        let lines = String(body.dropFirst(offset)).components(separatedBy: "\n")
        var result: [String] = []
        var used = 0
        var index = 0
        while index < lines.count, used < limit {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                var entry = line
                if let next = lines[(index + 1)...].prefix(4).first(where: {
                    let text = $0.trimmingCharacters(in: .whitespaces)
                    return !text.isEmpty && !text.hasPrefix("#") && !text.hasPrefix("---") && !text.hasPrefix("|---")
                }) {
                    entry += "\n  " + String(next.trimmingCharacters(in: .whitespaces).prefix(160))
                }
                result.append(entry)
                used += entry.count + 1
            }
            index += 1
        }
        return result.joined(separator: "\n")
    }

    /// Cerca parole nei file di testo del progetto (quando le istruzioni non indicano niente): i file con più parole trovate.
    public func search(_ prompt: String, limit: Int = 5) async -> [(path: String, snippet: String)] {
        let tree = await currentTree()
        let words = Self.nameWords(prompt).filter { $0.count >= 4 && !Self.stopwords.contains($0) }
        guard !words.isEmpty else { return [] }
        let root = self.root
        return await Task.detached(priority: .userInitiated) { () -> [(path: String, snippet: String)] in
            var scored: [(path: String, score: Int, snippet: String)] = []
            for path in tree.files where ["md", "txt"].contains((path as NSString).pathExtension.lowercased()) {
                if Task.isCancelled { break }
                guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { continue }
                let lower = text.lowercased().folding(options: [.diacriticInsensitive], locale: Dates.locale)
                let found = words.filter { lower.contains($0) }
                guard !found.isEmpty else { continue }
                let nameBonus = words.filter { path.lowercased().contains($0) }.count * 2
                var snippet = ""
                if let range = lower.range(of: found.max(by: { $0.count < $1.count }) ?? found[0]) {
                    let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
                    let chars = Array(text)
                    let from = max(0, start - 120)
                    snippet = String(chars[from..<min(chars.count, start + 260)]).replacingOccurrences(of: "\n", with: " ")
                }
                scored.append((path, found.count * 3 + nameBonus, snippet))
            }
            return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path.count < $1.path.count }
                .prefix(limit).map { (path: $0.path, snippet: $0.snippet) }
        }.value
    }

    // MARK: Testo

    /// Senza l'intestazione YAML (`---` … `---`), tenendo il riassunto (`tldr`) se c'è.
    static func withoutFrontMatter(_ text: String, keepSummary: Bool = false) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        let summary = keepSummary ? lines[1..<end].first { $0.lowercased().hasPrefix("tldr:") } : nil
        let rest = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.map { "(\($0.trimmingCharacters(in: .whitespaces)))\n\n" + rest } ?? rest
    }

    /// Tagliato a un a capo prima del limite.
    static func cut(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit))
        let end = prefix.range(of: "\n", options: .backwards)?.lowerBound ?? prefix.endIndex
        return String(prefix[..<end]) + "\n[…]"
    }
}

// MARK: - File da ignorare (.claudeignore)

/// Regole in stile .gitignore: «cartella/», «*.mp4», «nome», «percorso/sotto/». Tengono fuori dal contesto, non cancellano niente.
struct IgnoreRules: Sendable {
    private var folders: [String] = []
    private var patterns: [String] = []

    mutating func add(_ text: String) {
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            if line.hasSuffix("/") { folders.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()) }
            else { patterns.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()) }
        }
    }

    func excludes(_ path: String, isFolder: Bool) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        if isFolder {
            if folders.contains(where: { $0 == name || $0 == lower || ($0.contains("/") && lower.hasSuffix($0)) }) { return true }
        }
        for pattern in patterns {
            if pattern.contains("/") {
                if fnmatch(pattern, lower, 0) == 0 { return true }
            } else if fnmatch(pattern, name, 0) == 0 {
                return true
            }
        }
        return false
    }
}

extension FileManager {
    func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
