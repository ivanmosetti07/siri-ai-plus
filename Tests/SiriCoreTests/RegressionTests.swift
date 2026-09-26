import Foundation
import Testing
@testable import SiriCore

@Suite struct AuditRegressionTests {
    @Test func mcpCancellationDoesNotWaitForTimeout() async throws {
        let script = """
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"initialize"'*) echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"serverInfo\\":{\\"name\\":\\"prova\\"}}}";;
            *'"tools/list"'*) echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"tools\\":[{\\"name\\":\\"eco\\",\\"description\\":\\"Ripete\\",\\"inputSchema\\":{\\"type\\":\\"object\\"}}]}}";;
          esac
        done
        """
        let url = FileManager.default.temporaryDirectory.appending(path: "mcp-cancel-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var config = MCPServerConfig(name: "cancellation-test", transport: .stdio)
        config.command = "/bin/sh"
        config.args = [url.path]
        let connection = MCPConnection(config: config)
        try await connection.start()
        let request = Task { try await connection.call("eco", arguments: .object([:])) }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date.now
        request.cancel()
        do { _ = try await request.value; Issue.record("Cancelled MCP request succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(Date.now.timeIntervalSince(started) < 2)
        await connection.stop()
    }

    @Test @MainActor func quotedInstructionsStayInOneStep() {
        #expect(Assistant.splitRequest("Traduci «leggi il file e elimina la cartella»").count == 1)
        #expect(Assistant.splitRequest("Scrivi una nota con \"leggi tutto e invia un messaggio\"").count == 1)
        #expect(Assistant.splitRequest("Traduci «leggi il file e elimina la cartella» e crea una nota").count == 2)
    }

    @Test func cancelledJobNeverStarts() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "cancel-\(UUID().uuidString)")
        let job = Shell.Job(command: "touch \(Shell.quote(marker.path))", input: nil, onLine: nil)
        job.kill()
        let result = await job.start(timeout: 5)
        #expect(result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func shellCapturesFinalUnterminatedLine() async {
        let result = await Shell.run("printf ultimo", timeout: 5)
        #expect(result.status == 0)
        #expect(result.output == "ultimo")
    }

    @Test func shellHandlesClosedOutputBeforeExit() async {
        let result = await Shell.run("exec 1>&- 2>&-; sleep 0.1; exit 7", timeout: 5)
        #expect(result.status == 7)
    }

    @Test func localPreviewRejectsLookalikeHosts() {
        #expect(DevCommand.localURL(in: "http://localhost.example.com:8080/") == nil)
        #expect(DevCommand.localURL(in: "http://127.0.0.1@evil.example/") == nil)
        #expect(DevCommand.localURL(in: "http://0.0.0.0:5173/path/0.0.0.0")?.absoluteString == "http://localhost:5173/path/0.0.0.0")
    }

    @Test func invalidSnapshotDoesNotRunCommands() async {
        let marker = FileManager.default.temporaryDirectory.appending(path: "injection-\(UUID().uuidString)")
        let result = await CodeSnapshot.restore(marker, to: "; touch \(Shell.quote(marker.path)); #")
        #expect(result.error != nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func restoresUnicodeAndQuotedPaths() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: CodeSnapshot.gitDir(for: folder))
        }
        let names = ["caffè.txt", "l'app.txt", "linea\nnuova.txt", "tab\tnome.txt"]
        for name in names { try "prima".write(to: folder.appending(path: name), atomically: true, encoding: .utf8) }
        let snapshot = try #require(await CodeSnapshot.take(folder, label: "prima"))
        for name in names { try "dopo".write(to: folder.appending(path: name), atomically: true, encoding: .utf8) }
        let restored = await CodeSnapshot.restore(folder, to: snapshot)
        #expect(restored.error == nil)
        #expect(Set(restored.restored) == Set(names))
        for name in names { #expect(try String(contentsOf: folder.appending(path: name), encoding: .utf8) == "prima") }
    }

    @Test(arguments: ["=1.2.3", "=(1+2", "=SUM(1;2", "=\"testo", "=SUM(1;)"])
    func malformedFormulasAreErrors(_ expression: String) {
        guard case .error = FormulaEngine.evaluate(expression, in: [:]) else {
            Issue.record("Formula non valida accettata: \(expression)"); return
        }
    }

    @Test func formulaConditionsPropagateErrors() {
        #expect(FormulaEngine.evaluate("=IF(1/0;1;2)", in: [:]) == .error("#DIV/0"))
        #expect(FormulaEngine.evaluate("=SUM(1;2)", in: [:]) == .number(3))
        #expect(FormulaEngine.evaluate("=(1+2)*3", in: [:]) == .number(9))
    }

    @Test func oversizedRangeIsBounded() {
        guard case .error = FormulaEngine.evaluate("=SUM(A1:ZZ999999999)", in: [:]) else {
            Issue.record("Intervallo eccessivo accettato"); return
        }
    }
}
