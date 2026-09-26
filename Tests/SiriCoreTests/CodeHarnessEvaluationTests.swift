import Foundation
import Testing
@testable import SiriCore

/// Scenari riproducibili del ciclo completo: creare, modificare, rivedere, applicare.
/// Non invocano un modello: misurano l'infrastruttura che deve proteggere una task reale.
@Suite struct CodeHarnessEvaluationTests {
    private func repository() async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "siriai-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "prima\n".write(to: folder.appending(path: "pagina.txt"), atomically: true, encoding: .utf8)
        try "elimina\n".write(to: folder.appending(path: "vecchio.txt"), atomically: true, encoding: .utf8)
        let q = Shell.quote(folder.path)
        let initResult = await Shell.run("git init -q \(q)")
        #expect(initResult.status == 0)
        let add = await Shell.run("git -C \(q) add -A")
        #expect(add.status == 0)
        let commit = await Shell.run("git -C \(q) -c user.name=Test -c user.email=test@locale commit -q -m base")
        #expect(commit.status == 0)
        return folder
    }

    @Test func isolatedTaskReviewAndApply() async throws {
        let project = try await repository()
        let parent = project.deletingLastPathComponent().appending(path: "copies-\(UUID().uuidString)")
        let copy = try await CodeWorktree.create(project: project, id: UUID(), parent: parent)
        let checkpoint = try #require(await CodeSnapshot.take(copy.folder, label: "prima della task isolata"))
        try "dopo\n".write(to: copy.folder.appending(path: "pagina.txt"), atomically: true, encoding: .utf8)
        try "nuovo\n".write(to: copy.folder.appending(path: "città nuova.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: copy.folder.appending(path: "vecchio.txt"))

        #expect(try String(contentsOf: project.appending(path: "pagina.txt"), encoding: .utf8) == "prima\n")
        let checkpointChanges = await CodeSnapshot.changes(copy.folder, since: checkpoint)
        #expect(checkpointChanges.count == 3)
        #expect(!checkpointChanges.contains { $0.contains(".git") })
        let review = await CodeReview.inspect(project: project, workingFolder: copy.folder, isolation: .worktree, base: copy.base)
        #expect(review.error == nil)
        #expect(Set(review.files.map(\.path)) == Set(["pagina.txt", "città nuova.txt", "vecchio.txt"]))
        #expect(review.files.first(where: { $0.path == "pagina.txt" })?.patch.contains("+dopo") == true)
        #expect(review.added == 2 && review.removed == 2)

        let reviewed = try #require(review.revision)
        let later = copy.folder.appending(path: "dopo-la-revisione.txt")
        try "cambiato\n".write(to: later, atomically: true, encoding: .utf8)
        do {
            _ = try await CodeWorktree.apply(project: project, copy: copy.folder, base: copy.base, reviewedRevision: reviewed)
            Issue.record("Una modifica successiva alla revisione avrebbe dovuto bloccare l'applicazione")
        } catch { #expect(error is CodeWorktree.Failure) }
        try FileManager.default.removeItem(at: later)
        let applied = try await CodeWorktree.apply(project: project, copy: copy.folder, base: copy.base, reviewedRevision: reviewed)
        #expect(applied == 3)
        #expect(try String(contentsOf: project.appending(path: "pagina.txt"), encoding: .utf8) == "dopo\n")
        #expect(FileManager.default.fileExists(atPath: project.appending(path: "città nuova.txt").path))
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: "vecchio.txt").path))
        // La seconda applicazione non deve sovrascrivere il lavoro già presente.
        do {
            _ = try await CodeWorktree.apply(project: project, copy: copy.folder, base: copy.base, reviewedRevision: reviewed)
            Issue.record("La seconda applicazione avrebbe dovuto fallire")
        } catch { #expect(error is CodeWorktree.Failure) }
    }

    @Test func parallelCopiesStayIndependent() async throws {
        let project = try await repository()
        let parent = project.deletingLastPathComponent().appending(path: "copies-\(UUID().uuidString)")
        let first = try await CodeWorktree.create(project: project, id: UUID(), parent: parent)
        let second = try await CodeWorktree.create(project: project, id: UUID(), parent: parent)
        try "uno\n".write(to: first.folder.appending(path: "pagina.txt"), atomically: true, encoding: .utf8)
        try "due\n".write(to: second.folder.appending(path: "pagina.txt"), atomically: true, encoding: .utf8)
        let firstReview = await CodeReview.inspect(project: project, workingFolder: first.folder, isolation: .worktree, base: first.base)
        let secondReview = await CodeReview.inspect(project: project, workingFolder: second.folder, isolation: .worktree, base: second.base)
        #expect(firstReview.files.first?.patch.contains("+uno") == true)
        #expect(secondReview.files.first?.patch.contains("+due") == true)
        #expect(try String(contentsOf: project.appending(path: "pagina.txt"), encoding: .utf8) == "prima\n")
    }

    @Test func dirtyOrAdvancedProjectBlocksApply() async throws {
        let project = try await repository()
        let parent = project.deletingLastPathComponent().appending(path: "copies-\(UUID().uuidString)")
        let copy = try await CodeWorktree.create(project: project, id: UUID(), parent: parent)
        try "copia\n".write(to: copy.folder.appending(path: "pagina.txt"), atomically: true, encoding: .utf8)
        let review = await CodeReview.inspect(project: project, workingFolder: copy.folder, isolation: .worktree, base: copy.base)
        let reviewed = try #require(review.revision)
        try "locale\n".write(to: project.appending(path: "pagina.txt"), atomically: true, encoding: .utf8)
        do {
            _ = try await CodeWorktree.apply(project: project, copy: copy.folder, base: copy.base, reviewedRevision: reviewed)
            Issue.record("Il progetto con modifiche locali avrebbe dovuto bloccare l'applicazione")
        } catch { #expect(error is CodeWorktree.Failure) }
        do {
            _ = try await CodeWorktree.create(project: project, id: UUID(), parent: parent)
            Issue.record("Il progetto con modifiche locali avrebbe dovuto bloccare una nuova copia")
        } catch { #expect(error is CodeWorktree.Failure) }
        #expect(try String(contentsOf: project.appending(path: "pagina.txt"), encoding: .utf8) == "locale\n")
        let q = Shell.quote(project.path)
        let added = await Shell.run("git -C \(q) add -A")
        #expect(added.status == 0)
        let committed = await Shell.run("git -C \(q) -c user.name=Test -c user.email=test@locale commit -q -m avanzato")
        #expect(committed.status == 0)
        do {
            _ = try await CodeWorktree.apply(project: project, copy: copy.folder, base: copy.base, reviewedRevision: reviewed)
            Issue.record("Il commit avanzato avrebbe dovuto bloccare l'applicazione")
        } catch { #expect(error is CodeWorktree.Failure) }
    }

    @Test func directTaskReviewUsesRestorePoint() async throws {
        let project = try await repository()
        let base = try #require(await CodeSnapshot.take(project, label: "prima della task"))
        try "dopo\n".write(to: project.appending(path: "pagina.txt"), atomically: true, encoding: .utf8)
        let review = await CodeReview.inspect(project: project, workingFolder: project, isolation: .project, base: base)
        #expect(review.error == nil)
        #expect(review.files.map(\.path) == ["pagina.txt"])
        #expect(review.files.first?.patch.contains("+dopo") == true)
    }
}
