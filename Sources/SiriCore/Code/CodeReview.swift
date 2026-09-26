import Foundation

public enum CodeIsolation: String, Codable, CaseIterable, Sendable {
    case project, worktree

    public var label: String { self == .project ? "Cartella originale" : "Copia isolata" }
}

public struct CodeReviewFile: Identifiable, Sendable {
    public let status: String
    public let path: String
    public let patch: String
    public let added: Int
    public let removed: Int
    public var id: String { path }
}

public struct CodeReviewResult: Sendable {
    public var files: [CodeReviewFile] = []
    public var error: String?
    public var truncated = false
    public var revision: String?
    public init(files: [CodeReviewFile] = [], error: String? = nil, truncated: Bool = false, revision: String? = nil) {
        self.files = files; self.error = error; self.truncated = truncated; self.revision = revision
    }
    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

/// Revisione dei file dopo una richiesta. Nella cartella originale usa il Git ombra dei punti
/// di ripristino; nella copia isolata confronta tutti i file con il commit di partenza.
public enum CodeReview {
    public static func inspect(project: URL, workingFolder: URL, isolation: CodeIsolation,
                               base: String) async -> CodeReviewResult {
        var review = CodeReviewResult()
        guard CodeSnapshot.validSnapshot(base) else { review.error = "Punto di partenza non valido."; return review }
        let git: String
        let folder: URL
        if isolation == .worktree {
            folder = workingFolder
            guard FileManager.default.fileExists(atPath: folder.path) else {
                review.error = "La copia isolata non esiste più."; return review
            }
            let staged = await Shell.run("git -C \(Shell.quote(folder.path)) add -A", timeout: 120)
            guard staged.status == 0 else { review.error = String(staged.output.prefix(300)); return review }
            git = "git -C \(Shell.quote(folder.path))"
            let tree = await Shell.run("\(git) write-tree", timeout: 30)
            let revision = tree.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard tree.status == 0, CodeSnapshot.validSnapshot(revision) else {
                review.error = "Non riesco a fissare la versione da rivedere."; return review
            }
            review.revision = revision
        } else {
            folder = project
            guard await CodeSnapshot.take(project, label: "Revisione delle modifiche") != nil else {
                review.error = "Non riesco a fotografare le modifiche."; return review
            }
            git = CodeSnapshot.git(project, "")
        }
        let diffArgs = isolation == .worktree ? "diff --cached" : "diff"
        let result = isolation == .worktree
            ? await Shell.run("\(git) diff --cached --name-status -z --no-renames \(Shell.quote(base))", timeout: 120)
            : await Shell.run("\(git) \(diffArgs) --name-status -z --no-renames \(Shell.quote(base)) HEAD", timeout: 120)
        guard result.status == 0 else { review.error = String(result.output.prefix(300)); return review }
        let entries = CodeSnapshot.parseChanges(result.output)
        // Shell retains up to 4 MiB; never present a partial change list as complete.
        if result.output.utf8.count >= 4_000_000 { review.error = "Troppi file per una revisione completa."; return review }
        for (status, path) in entries {
            let args = isolation == .worktree
                ? "diff --cached --no-ext-diff --no-renames --unified=3 \(Shell.quote(base)) -- \(Shell.quote(path))"
                : "diff --no-ext-diff --no-renames --unified=3 \(Shell.quote(base)) HEAD -- \(Shell.quote(path))"
            let patch = await Shell.run("\(git) \(args)", timeout: 60)
            guard patch.status == 0 else { review.error = "Diff non disponibile per \(path)."; return review }
            let isTruncated = patch.output.utf8.count >= 4_000_000
            let text = isTruncated ? "Diff troppo grande da mostrare. Apri il file nel progetto." : patch.output
            if isTruncated { review.truncated = true }
            let lines = text.split(separator: "\n")
            let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
            review.files.append(CodeReviewFile(status: status, path: path, patch: text, added: added, removed: removed))
        }
        return review
    }
}

public enum CodeWorktree {
    public struct Copy: Sendable {
        public let folder: URL
        public let base: String
    }

    public enum Failure: LocalizedError, Sendable {
        case message(String)
        public var errorDescription: String? {
            if case .message(let text) = self { text } else { nil }
        }
    }

    private static func git(_ folder: URL, _ args: String) -> String {
        "git -C \(Shell.quote(folder.path)) \(args)"
    }

    public static func create(project: URL, id: UUID, parent: URL = AppPaths.support("Copie isolate")) async throws -> Copy {
        let root = await Shell.run(git(project, "rev-parse --show-toplevel"), timeout: 30)
        guard root.status == 0, URL(fileURLWithPath: root.output.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL == project.standardizedFileURL else {
            throw Failure.message("La copia isolata richiede che la cartella del progetto sia la radice di un repository Git.")
        }
        let status = await Shell.run(git(project, "status --porcelain -z"), timeout: 30)
        guard status.status == 0, status.output.isEmpty else {
            throw Failure.message("Il progetto contiene modifiche non salvate in Git. Crea un commit o usa la cartella originale.")
        }
        let head = await Shell.run(git(project, "rev-parse HEAD"), timeout: 30)
        let base = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.status == 0, CodeSnapshot.validSnapshot(base) else {
            throw Failure.message("Il repository non ha ancora un commit iniziale.")
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = parent.appending(path: id.uuidString)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw Failure.message("Esiste già una copia per questa sessione.")
        }
        let created = await Shell.run(git(project, "worktree add --detach \(Shell.quote(folder.path)) \(Shell.quote(base))"), timeout: 120)
        guard created.status == 0 else { throw Failure.message("Non riesco a creare la copia isolata: \(created.output.prefix(300))") }
        return Copy(folder: folder, base: base)
    }

    /// Applica tutte le modifiche della copia al progetto solo se la base è ancora identica
    /// e il progetto è pulito. La copia viene conservata per un'ulteriore revisione.
    public static func apply(project: URL, copy: URL, base: String, reviewedRevision: String) async throws -> Int {
        guard CodeSnapshot.validSnapshot(base), CodeSnapshot.validSnapshot(reviewedRevision),
              FileManager.default.fileExists(atPath: copy.path) else {
            throw Failure.message("Copia isolata o commit iniziale non valido.")
        }
        let root = await Shell.run(git(copy, "rev-parse --show-toplevel"), timeout: 30)
        guard root.status == 0, URL(fileURLWithPath: root.output.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL == copy.standardizedFileURL else {
            throw Failure.message("La copia isolata non è più un repository Git valido.")
        }
        let current = await Shell.run(git(project, "rev-parse HEAD"), timeout: 30)
        guard current.status == 0, current.output.trimmingCharacters(in: .whitespacesAndNewlines) == base else {
            throw Failure.message("Il progetto è avanzato dopo la creazione della copia. Rivedi le differenze prima di applicarle.")
        }
        let status = await Shell.run(git(project, "status --porcelain -z"), timeout: 30)
        guard status.status == 0, status.output.isEmpty else {
            throw Failure.message("Il progetto ha modifiche locali. Salvale prima di applicare la copia.")
        }
        let staged = await Shell.run(git(copy, "add -A"), timeout: 120)
        guard staged.status == 0 else { throw Failure.message("Non riesco a preparare le modifiche della copia.") }
        let tree = await Shell.run(git(copy, "write-tree"), timeout: 30)
        guard tree.status == 0, tree.output.trimmingCharacters(in: .whitespacesAndNewlines) == reviewedRevision else {
            throw Failure.message("La copia è cambiata dopo la revisione. Riapri il diff prima di applicarla.")
        }
        let count = await Shell.run(git(copy, "diff --cached --name-only -z \(Shell.quote(base))"), timeout: 120)
        guard count.status == 0 else { throw Failure.message("Non riesco a leggere i file modificati.") }
        let files = count.output.split(separator: "\0").count
        guard files > 0 else { return 0 }
        let patchURL = FileManager.default.temporaryDirectory.appending(path: "siriai-\(UUID().uuidString).patch")
        defer { try? FileManager.default.removeItem(at: patchURL) }
        let patch = await Shell.run("\(git(copy, "diff --cached --binary \(Shell.quote(base))")) > \(Shell.quote(patchURL.path))", timeout: 120)
        guard patch.status == 0 else { throw Failure.message("Non riesco a preparare la patch.") }
        let check = await Shell.run(git(project, "apply --check --binary \(Shell.quote(patchURL.path))"), timeout: 120)
        guard check.status == 0 else { throw Failure.message("Le modifiche non si applicano pulitamente: \(check.output.prefix(300))") }
        guard await CodeSnapshot.take(project, label: "Prima di applicare la copia isolata") != nil else {
            throw Failure.message("Non riesco a creare il punto di ripristino prima dell'applicazione.")
        }
        let applied = await Shell.run(git(project, "apply --binary \(Shell.quote(patchURL.path))"), timeout: 120)
        guard applied.status == 0 else { throw Failure.message("Applicazione non riuscita: \(applied.output.prefix(300))") }
        return files
    }
}
