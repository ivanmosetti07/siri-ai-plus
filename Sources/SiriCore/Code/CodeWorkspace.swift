import CryptoKit
import Foundation

/// Punti di ripristino del progetto con un repository git "ombra" in Application Support:
/// non tocca la cartella `.git` del progetto e rispetta i suoi `.gitignore`.
public enum CodeSnapshot {
    static func gitDir(for project: URL) -> URL {
        let hash = SHA256.hash(data: Data(project.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return AppPaths.support("Punti di ripristino").appending(path: "\(project.lastPathComponent)-\(hash).git")
    }

    static func git(_ project: URL, _ arguments: String) -> String {
        "git --git-dir=\(Shell.quote(gitDir(for: project).path)) --work-tree=\(Shell.quote(project.path)) -c user.name=Ripristino -c user.email=ripristino@locale -c core.autocrlf=false \(arguments)"
    }

    /// Fotografia dello stato attuale; restituisce l'id del punto di ripristino.
    public static func take(_ project: URL, label: String) async -> String? {
        let dir = gitDir(for: project)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = await Shell.run("git init -q --bare \(Shell.quote(dir.path))", timeout: 60)
            // Cartelle pesanti o generate: mai nei punti di ripristino.
            let exclude = ["node_modules/", ".build/", "build/", "dist/", "DerivedData/", ".next/", ".DS_Store", "*.xcuserstate", ".git", ".git/", "Pods/", ".venv/", "venv/"]
            try? FileManager.default.createDirectory(at: dir.appending(path: "info"), withIntermediateDirectories: true)
            try? exclude.joined(separator: "\n").write(to: dir.appending(path: "info/exclude"), atomically: true, encoding: .utf8)
        }
        let command = "cd \(Shell.quote(project.path)) && \(git(project, "add -A")) && \(git(project, "commit -q --allow-empty -m \(Shell.quote(label))")) && \(git(project, "rev-parse HEAD"))"
        let result = await Shell.run(command, timeout: 300)
        let sha = result.output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return result.status == 0 && sha.count >= 40 ? sha : nil
    }

    public struct Restore: Sendable {
        public var restored: [String] = []
        public var trashed: [String] = []
        public var error: String?
    }

    /// Riporta i file com'erano al punto di ripristino: i modificati e i cancellati tornano, i file nuovi vanno nel Cestino.
    public static func restore(_ project: URL, to snapshot: String) async -> Restore {
        var outcome = Restore()
        guard validSnapshot(snapshot) else {
            outcome.error = Language.t("Identificatore del punto di ripristino non valido.", "Invalid restore point identifier.")
            return outcome
        }
        // Prima una fotografia dello stato attuale (così anche il ripristino si può annullare).
        guard await take(project, label: "prima del ripristino") != nil else {
            outcome.error = Language.t("Non riesco a leggere lo stato attuale del progetto.", "Couldn't read the current state of the project.")
            return outcome
        }
        let diff = await Shell.run("cd \(Shell.quote(project.path)) && \(git(project, "diff --name-status -z --no-renames \(Shell.quote(snapshot)) HEAD"))", timeout: 120)
        guard diff.status == 0 else { outcome.error = String(diff.output.prefix(300)); return outcome }
        for (status, path) in parseChanges(diff.output) {
            if status.hasPrefix("A") {
                let url = project.appending(path: path)
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    outcome.trashed.append(path)
                } catch {
                    outcome.error = Language.t("Ripristino parziale: impossibile spostare nel Cestino «\(path)»: \(error.localizedDescription)",
                                               "Partial restore: couldn't move “\(path)” to the Trash: \(error.localizedDescription)")
                }
            } else {
                let result = await Shell.run("cd \(Shell.quote(project.path)) && \(git(project, "checkout \(Shell.quote(snapshot)) -- \(Shell.quote(path))"))", timeout: 60)
                if result.status == 0 { outcome.restored.append(path) }
                else {
                    outcome.error = Language.t("Ripristino parziale: impossibile ripristinare «\(path)». \(result.output.prefix(200))",
                                               "Partial restore: couldn't restore “\(path)”. \(result.output.prefix(200))")
                }
            }
        }
        return outcome
    }

    static func validSnapshot(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        }
    }

    /// Git -z preserves Unicode, tabs, newlines and quotes in filenames.
    static func parseChanges(_ output: String) -> [(String, String)] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        return stride(from: 0, to: max(0, fields.count - 1), by: 2).compactMap { index in
            guard index + 1 < fields.count, !fields[index + 1].isEmpty else { return nil }
            return (String(fields[index]), String(fields[index + 1]))
        }
    }

    /// File cambiati dal punto di ripristino (riga «stato<TAB>percorso»).
    public static func changes(_ project: URL, since snapshot: String) async -> [String] {
        guard validSnapshot(snapshot), await take(project, label: "dopo la richiesta") != nil else { return [] }
        let diff = await Shell.run("cd \(Shell.quote(project.path)) && \(git(project, "diff --name-status -z --no-renames \(Shell.quote(snapshot)) HEAD"))", timeout: 120)
        return diff.status == 0 ? parseChanges(diff.output).map { "\($0.0)\t\($0.1)" } : []
    }
}

/// Come si avvia un progetto: server di sviluppo, app Swift o pagina statica.
public struct DevCommand: Sendable, Equatable {
    public enum Kind: String, Sendable { case server, run, staticPage, xcode }
    public var kind: Kind
    public var command: String
    public var label: String
    public var page: URL?

    /// Riconosce il tipo di progetto dai file nella cartella.
    public static func detect(in folder: URL) -> DevCommand? {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: folder.appending(path: name).path) }
        if exists("package.json"), let data = try? Data(contentsOf: folder.appending(path: "package.json")), let json = try? JSONValue.parse(data) {
            let scripts = json["scripts"]?.object ?? [:]
            let install = exists("node_modules") ? "" : "npm install && "
            if scripts["dev"] != nil { return DevCommand(kind: .server, command: install + "npm run dev", label: "npm run dev") }
            if scripts["start"] != nil { return DevCommand(kind: .server, command: install + "npm start", label: "npm start") }
        }
        if let project = (try? fm.contentsOfDirectory(atPath: folder.path))?.first(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return DevCommand(kind: .xcode, command: "open \(Shell.quote(folder.appending(path: project).path))", label: Language.t("Apri in Xcode", "Open in Xcode"))
        }
        if exists("Package.swift") { return DevCommand(kind: .run, command: "swift run", label: "swift run") }
        for page in ["index.html", "public/index.html", "src/index.html", "docs/index.html"] where exists(page) {
            return DevCommand(kind: .staticPage, command: "", label: Language.t("Apri la pagina", "Open the page"), page: folder.appending(path: page))
        }
        if exists("main.py") { return DevCommand(kind: .run, command: "python3 main.py", label: "python3 main.py") }
        return nil
    }

    /// Primo indirizzo locale scritto dal server di sviluppo ("Local: http://localhost:5173/").
    public static func localURL(in text: String) -> URL? {
        let escape = String(UnicodeScalar(27))
        let clean = text.replacingOccurrences(of: escape + #"\[[0-9;]*m"#, with: "", options: .regularExpression)
        guard let range = clean.range(of: #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?[^\s\)"']*"#, options: .regularExpression) else { return nil }
        guard var components = URLComponents(string: String(clean[range])),
              ["localhost", "127.0.0.1", "0.0.0.0"].contains(components.host?.lowercased() ?? ""),
              components.user == nil, components.password == nil else { return nil }
        if components.host == "0.0.0.0" { components.host = "localhost" }
        return components.url
    }
}

/// Modelli per i nuovi progetti di coding: regole per l'agente e prima richiesta.
public enum CodeTemplate: String, CaseIterable, Identifiable, Sendable {
    case sito, webapp, swiftui, vuoto
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sito: Language.t("Sito web", "Website")
        case .webapp: Language.t("App web (React + Vite)", "Web app (React + Vite)")
        case .swiftui: Language.t("App per Mac e iPhone (SwiftUI)", "Mac and iPhone app (SwiftUI)")
        case .vuoto: Language.t("Progetto vuoto", "Empty project")
        }
    }

    public var symbol: String {
        switch self {
        case .sito: "globe"
        case .webapp: "atom"
        case .swiftui: "swift"
        case .vuoto: "folder.badge.plus"
        }
    }

    public var summary: String {
        switch self {
        case .sito: Language.t("HTML, CSS e JavaScript: landing page, portfolio, sito vetrina. Anteprima immediata.",
                               "HTML, CSS and JavaScript: landing page, portfolio, showcase site. Instant preview.")
        case .webapp: Language.t("Applicazione interattiva con React, TypeScript e Vite, avviata con npm run dev.",
                                 "Interactive app with React, TypeScript and Vite, started with npm run dev.")
        case .swiftui: Language.t("App nativa Apple con SwiftUI, da aprire e avviare in Xcode.",
                                  "Native Apple app with SwiftUI, to open and run in Xcode.")
        case .vuoto: Language.t("Una cartella con le regole per l'assistente: decidi tu cosa costruire.",
                                 "A folder with the rules for the assistant: you decide what to build.")
        }
    }

    /// Regole per Codex nel progetto creato dall'app.
    public func agentsFile(name: String) -> String {
        if Language.isEnglish { return englishAgentsFile(name: name) }
        let common = """
        # \(name)

        ## Come lavorare
        - Rispondi e commenta in italiano; il codice e i nomi dei file in inglese.
        - Fai modifiche piccole e verificabili; dopo ogni modifica importante controlla che il progetto si avvii.
        - Non cancellare file senza chiederlo. Non aggiungere dipendenze inutili.
        - Alla fine riassumi cosa hai cambiato e come provarlo.
        """
        switch self {
        case .sito:
            return common + """


            ## Progetto
            Sito statico: `index.html`, `style.css`, `script.js` (niente framework). Responsive, accessibile (contrasto, testo alternativo), \
            tema chiaro e scuro con `prefers-color-scheme`, immagini leggere. Si prova aprendo `index.html`.
            """
        case .webapp:
            return common + """


            ## Progetto
            React + TypeScript con Vite. Avvio: `npm install` e `npm run dev`. Componenti piccoli in `src/components`, \
            stile con CSS moderno (niente librerie UI se non servono). Controlla i tipi con `npx tsc --noEmit`.
            """
        case .swiftui:
            return common + """


            ## Progetto
            App SwiftUI (Swift 6, macOS e iOS). Architettura semplice con `@Observable`. Progetto Xcode (`.xcodeproj`) \
            funzionante. Compila con `xcodebuild` prima di dire che hai finito.
            """
        case .vuoto:
            return common
        }
    }

    /// Le stesse regole in inglese: l'agente risponde e commenta in inglese.
    private func englishAgentsFile(name: String) -> String {
        let common = """
        # \(name)

        ## How to work
        - Reply and write comments in English; code and file names in English too.
        - Make small, verifiable changes; after every important change check that the project still starts.
        - Don't delete files without asking. Don't add unnecessary dependencies.
        - At the end, summarize what you changed and how to try it.
        """
        switch self {
        case .sito:
            return common + """


            ## Project
            Static website: `index.html`, `style.css`, `script.js` (no framework). Responsive, accessible (contrast, alt text), \
            light and dark theme with `prefers-color-scheme`, lightweight images. Try it by opening `index.html`.
            """
        case .webapp:
            return common + """


            ## Project
            React + TypeScript with Vite. Start: `npm install` and `npm run dev`. Small components in `src/components`, \
            styling with modern CSS (no UI libraries unless they're needed). Check the types with `npx tsc --noEmit`.
            """
        case .swiftui:
            return common + """


            ## Project
            SwiftUI app (Swift 6, macOS and iOS). Simple architecture with `@Observable`. Working Xcode project \
            (`.xcodeproj`). Build it with `xcodebuild` before saying you're done.
            """
        case .vuoto:
            return common
        }
    }

    /// Prima richiesta all'agente, dopo la descrizione dell'utente.
    public func bootstrap(_ description: String) -> String {
        let wish = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if Language.isEnglish {
            switch self {
            case .sito: return "Create the website: \(wish.isEmpty ? "an elegant presentation page" : wish). Use index.html, style.css and script.js."
            case .webapp: return "Create the web app from scratch with Vite, React and TypeScript in the current folder (no subfolders): \(wish.isEmpty ? "a small sample app" : wish). Install the dependencies and check that `npm run build` works."
            case .swiftui: return "Create the SwiftUI app in the current folder: \(wish.isEmpty ? "a sample app with a list and a detail view" : wish). Create a working Xcode project (.xcodeproj) and check that it builds with xcodebuild."
            case .vuoto: return wish
            }
        }
        switch self {
        case .sito: return "Crea il sito: \(wish.isEmpty ? "una pagina di presentazione elegante" : wish). Usa index.html, style.css e script.js."
        case .webapp: return "Crea da zero l'app web con Vite, React e TypeScript nella cartella attuale (senza sottocartelle): \(wish.isEmpty ? "una piccola app di esempio" : wish). Installa le dipendenze e verifica che `npm run build` funzioni."
        case .swiftui: return "Crea l'app SwiftUI nella cartella attuale: \(wish.isEmpty ? "un'app di esempio con una lista e un dettaglio" : wish). Crea un progetto Xcode (.xcodeproj) funzionante e verifica che compili con xcodebuild."
        case .vuoto: return wish
        }
    }
}
