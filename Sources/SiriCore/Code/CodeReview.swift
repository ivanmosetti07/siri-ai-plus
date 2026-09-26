import Foundation

public enum CodeIsolation: String, Codable, CaseIterable, Sendable {
    case project, worktree

    public var label: String { self == .project ? Language.t("Cartella originale", "Original folder") : Language.t("Copia isolata", "Isolated copy") }
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
        guard CodeSnapshot.validSnapshot(base) else { review.error = Language.t("Punto di partenza non valido.", "Invalid starting point."); return review }
        let git: String
        let folder: URL
        if isolation == .worktree {
            folder = workingFolder
            guard FileManager.default.fileExists(atPath: folder.path) else {
                review.error = Language.t("La copia isolata non esiste più.", "The isolated copy no longer exists."); return review
            }
            let staged = await Shell.run("git -C \(Shell.quote(folder.path)) add -A", timeout: 120)
            guard staged.status == 0 else { review.error = String(staged.output.prefix(300)); return review }
            git = "git -C \(Shell.quote(folder.path))"
            let tree = await Shell.run("\(git) write-tree", timeout: 30)
            let revision = tree.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard tree.status == 0, CodeSnapshot.validSnapshot(revision) else {
                review.error = Language.t("Non riesco a fissare la versione da rivedere.", "Couldn't pin down the version to review."); return review
            }
            review.revision = revision
        } else {
            folder = project
            guard await CodeSnapshot.take(project, label: "Revisione delle modifiche") != nil else {
                review.error = Language.t("Non riesco a fotografare le modifiche.", "Couldn't take a snapshot of the changes."); return review
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
        if result.output.utf8.count >= 4_000_000 { review.error = Language.t("Troppi file per una revisione completa.", "Too many files for a complete review."); return review }
        for (status, path) in entries {
            let args = isolation == .worktree
                ? "diff --cached --no-ext-diff --no-renames --unified=3 \(Shell.quote(base)) -- \(Shell.quote(path))"
                : "diff --no-ext-diff --no-renames --unified=3 \(Shell.quote(base)) HEAD -- \(Shell.quote(path))"
            let patch = await Shell.run("\(git) \(args)", timeout: 60)
            guard patch.status == 0 else { review.error = Language.t("Diff non disponibile per \(path).", "Diff not available for \(path)."); return review }
            let isTruncated = patch.output.utf8.count >= 4_000_000
            let text = isTruncated ? Language.t("Diff troppo grande da mostrare. Apri il file nel progetto.", "Diff too large to show. Open the file in the project.") : patch.output
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
            throw Failure.message(Language.t("La copia isolata richiede che la cartella del progetto sia la radice di un repository Git.",
                                             "The isolated copy needs the project folder to be the root of a Git repository."))
        }
        let status = await Shell.run(git(project, "status --porcelain -z"), timeout: 30)
        guard status.status == 0, status.output.isEmpty else {
            throw Failure.message(Language.t("Il progetto contiene modifiche non salvate in Git. Crea un commit o usa la cartella originale.",
                                             "The project has changes that aren't saved in Git. Make a commit or use the original folder."))
        }
        let head = await Shell.run(git(project, "rev-parse HEAD"), timeout: 30)
        let base = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.status == 0, CodeSnapshot.validSnapshot(base) else {
            throw Failure.message(Language.t("Il repository non ha ancora un commit iniziale.", "The repository doesn't have an initial commit yet."))
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = parent.appending(path: id.uuidString)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw Failure.message(Language.t("Esiste già una copia per questa sessione.", "A copy already exists for this session."))
        }
        let created = await Shell.run(git(project, "worktree add --detach \(Shell.quote(folder.path)) \(Shell.quote(base))"), timeout: 120)
        guard created.status == 0 else {
            throw Failure.message(Language.t("Non riesco a creare la copia isolata: \(created.output.prefix(300))",
                                             "Couldn't create the isolated copy: \(created.output.prefix(300))"))
        }
        return Copy(folder: folder, base: base)
    }

    /// Applica tutte le modifiche della copia al progetto solo se la base è ancora identica
    /// e il progetto è pulito. La copia viene conservata per un'ulteriore revisione.
    public static func apply(project: URL, copy: URL, base: String, reviewedRevision: String) async throws -> Int {
        guard CodeSnapshot.validSnapshot(base), CodeSnapshot.validSnapshot(reviewedRevision),
              FileManager.default.fileExists(atPath: copy.path) else {
            throw Failure.message(Language.t("Copia isolata o commit iniziale non valido.", "Invalid isolated copy or initial commit."))
        }
        let root = await Shell.run(git(copy, "rev-parse --show-toplevel"), timeout: 30)
        guard root.status == 0, URL(fileURLWithPath: root.output.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL == copy.standardizedFileURL else {
            throw Failure.message(Language.t("La copia isolata non è più un repository Git valido.", "The isolated copy is no longer a valid Git repository."))
        }
        let current = await Shell.run(git(project, "rev-parse HEAD"), timeout: 30)
        guard current.status == 0, current.output.trimmingCharacters(in: .whitespacesAndNewlines) == base else {
            throw Failure.message(Language.t("Il progetto è avanzato dopo la creazione della copia. Rivedi le differenze prima di applicarle.",
                                             "The project has moved on since the copy was created. Review the differences before applying them."))
        }
        let status = await Shell.run(git(project, "status --porcelain -z"), timeout: 30)
        guard status.status == 0, status.output.isEmpty else {
            throw Failure.message(Language.t("Il progetto ha modifiche locali. Salvale prima di applicare la copia.",
                                             "The project has local changes. Save them before applying the copy."))
        }
        let staged = await Shell.run(git(copy, "add -A"), timeout: 120)
        guard staged.status == 0 else { throw Failure.message(Language.t("Non riesco a preparare le modifiche della copia.", "Couldn't prepare the changes of the copy.")) }
        let tree = await Shell.run(git(copy, "write-tree"), timeout: 30)
        guard tree.status == 0, tree.output.trimmingCharacters(in: .whitespacesAndNewlines) == reviewedRevision else {
            throw Failure.message(Language.t("La copia è cambiata dopo la revisione. Riapri il diff prima di applicarla.",
                                             "The copy changed after the review. Open the diff again before applying it."))
        }
        let count = await Shell.run(git(copy, "diff --cached --name-only -z \(Shell.quote(base))"), timeout: 120)
        guard count.status == 0 else { throw Failure.message(Language.t("Non riesco a leggere i file modificati.", "Couldn't read the changed files.")) }
        let files = count.output.split(separator: "\0").count
        guard files > 0 else { return 0 }
        let patchURL = FileManager.default.temporaryDirectory.appending(path: "siriai-\(UUID().uuidString).patch")
        defer { try? FileManager.default.removeItem(at: patchURL) }
        let patch = await Shell.run("\(git(copy, "diff --cached --binary \(Shell.quote(base))")) > \(Shell.quote(patchURL.path))", timeout: 120)
        guard patch.status == 0 else { throw Failure.message(Language.t("Non riesco a preparare la patch.", "Couldn't prepare the patch.")) }
        let check = await Shell.run(git(project, "apply --check --binary \(Shell.quote(patchURL.path))"), timeout: 120)
        guard check.status == 0 else {
            throw Failure.message(Language.t("Le modifiche non si applicano pulitamente: \(check.output.prefix(300))",
                                             "The changes don't apply cleanly: \(check.output.prefix(300))"))
        }
        guard await CodeSnapshot.take(project, label: "Prima di applicare la copia isolata") != nil else {
            throw Failure.message(Language.t("Non riesco a creare il punto di ripristino prima dell'applicazione.", "Couldn't create the restore point before applying."))
        }
        let applied = await Shell.run(git(project, "apply --binary \(Shell.quote(patchURL.path))"), timeout: 120)
        guard applied.status == 0 else { throw Failure.message(Language.t("Applicazione non riuscita: \(applied.output.prefix(300))", "Applying failed: \(applied.output.prefix(300))")) }
        return files
    }
}
