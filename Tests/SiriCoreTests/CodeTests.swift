import Foundation
import Testing
@testable import SiriCore

@Suite struct CodeAgentTests {
    @Test func everyModelHasAnEngine() {
        #expect(CodeAgent.Engine(.chatgpt) == .codex)
        #expect(CodeAgent.Engine(.claude) == .claude)
        #expect([ResponseProvider.apple, .gemma, .ds4].allSatisfy { CodeAgent.Engine($0) == .local })
    }

    @Test func parsesCodexStream() {
        let parser = CodeStreamParser()
        _ = parser.parse(#"{"type":"thread.started","thread_id":"th-9"}"#)
        #expect(parser.sessionID == "th-9")
        let start = parser.parse(#"{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"npm run build","status":"in_progress"}}"#)
        #expect(start.first?.status == .running)
        let end = parser.parse(#"{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"npm run build","aggregated_output":"ok","exit_code":0,"status":"completed"}}"#)
        #expect(end.first?.key == "i1" && end.first?.status == .ok && end.first?.detail == "ok")
        let files = parser.parse(#"{"type":"item.completed","item":{"id":"i2","type":"file_change","changes":[{"path":"src/App.tsx","kind":"update"},{"path":"src/new.ts","kind":"add"}],"status":"completed"}}"#)
        #expect(files.count == 2 && files[1].text == "Crea")
        let todo = parser.parse(#"{"type":"item.completed","item":{"id":"i3","type":"todo_list","items":[{"text":"a","completed":true},{"text":"b","completed":false}]}}"#)
        #expect(todo.first?.todos.map(\.done) == [true, false])
    }

    @Test func hidesEngineNoise() {
        let parser = CodeStreamParser()
        #expect(parser.parse(#"{"type":"item.completed","item":{"id":"e","type":"error","message":"Under-development features enabled: chronicle."}}"#).isEmpty)
        #expect(CodeStreamParser.unwrapShell(#"/bin/zsh -lc "npm run build""#) == "npm run build")
    }

    @Test func commandsQuotePaths() {
        let folder = URL(fileURLWithPath: "/Users/x/Progetti/l'app")
        let edit = CodeAgent.command(selection: ModelSelection(.chatgpt), mode: .edit, folder: folder, resume: "s1")
        #expect(edit.contains("resume 's1'") && edit.contains("-s workspace-write") && edit.contains(#"'/Users/x/Progetti/l'\''app'"#))
        #expect(!edit.contains(" -m "))
        #expect(CodeAgent.command(selection: ModelSelection(.chatgpt), mode: .plan, folder: folder, resume: nil).contains("-s read-only"))
    }

    @Test func commandsCarryModelAndEffort() {
        let folder = URL(fileURLWithPath: "/tmp/sito")
        let codex = CodeAgent.command(selection: ModelSelection(.chatgpt, model: "gpt-6-sol", effort: "high"), mode: .edit, folder: folder, resume: nil)
        #expect(codex.contains("-m 'gpt-6-sol'") && codex.contains(#"model_reasoning_effort="high""#) && codex.contains("--ignore-user-config"))
        let claude = CodeAgent.command(selection: ModelSelection(.claude, model: "opus", effort: "max"), mode: .edit, folder: folder, resume: "abc")
        #expect(claude.contains("--model 'opus'") && claude.contains("--effort 'max'") && claude.contains("--resume 'abc'"))
        #expect(claude.contains("--permission-mode acceptEdits") && claude.contains("autoAllowBashIfSandboxed") && claude.contains("--setting-sources project,local"))
        let plan = CodeAgent.command(selection: ModelSelection(.claude), mode: .plan, folder: folder, resume: nil)
        #expect(plan.contains("--permission-mode plan") && !plan.contains("sandbox") && !plan.contains("--model"))
    }

    @Test func parsesClaudeCodeStream() {
        let parser = CodeStreamParser(engine: .claude)
        _ = parser.parse(#"{"type":"system","subtype":"init","session_id":"s-42","model":"claude-opus-5-5"}"#)
        #expect(parser.sessionID == "s-42")
        let started = parser.parse(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm run build"}}]}}"#)
        #expect(started.first?.kind == .command && started.first?.status == .running && started.first?.key == "t1")
        let finished = parser.parse(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"compilato","is_error":false}]}}"#)
        #expect(finished.first?.key == "t1" && finished.first?.status == .ok && finished.first?.detail == "compilato")
        _ = parser.parse(#"{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/tmp/sito/index.html","content":"x"}}]}}"#)
        let written = parser.parse(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"File created successfully at: /tmp/sito/index.html"}]}]}}"#)
        #expect(written.first?.text == "Crea" && written.first?.path == "/tmp/sito/index.html")
        // Lista delle cose da fare: TaskCreate, poi TaskUpdate con il numero restituito.
        let created = parser.parse(#"{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"t3","name":"TaskCreate","input":{"subject":"Pagina contatti"}}]}}"#)
        #expect(created.first?.todos.map(\.text) == ["Pagina contatti"])
        _ = parser.parse(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"Task #7 created successfully"}]}}"#)
        let updated = parser.parse(#"{"type":"assistant","message":{"id":"m4","content":[{"type":"tool_use","id":"t4","name":"TaskUpdate","input":{"taskId":"7","status":"completed"}}]}}"#)
        #expect(updated.first?.todos.first?.done == true)
        let text = parser.parse(#"{"type":"assistant","message":{"id":"m5","content":[{"type":"thinking","thinking":""},{"type":"text","text":"Fatto il sito."}]}}"#)
        #expect(text.count == 1 && text.first?.kind == .text)
        let result = parser.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"Fatto il sito.","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"curl https://x.it"}}]}"#)
        #expect(result.contains { $0.kind == .error && $0.text.contains("curl https://x.it") } && result.last?.kind == .result)
        #expect(parser.sawResult && !parser.failed)
    }

    @Test func claudeErrorsBecomeMessages() {
        let parser = CodeStreamParser(engine: .claude)
        let events = parser.parse(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in · Please run /login"}"#)
        #expect(events.first?.kind == .error && parser.failed)
        #expect(ClaudeCLI.problem(in: "Not logged in · Please run /login").localizedDescription.contains("Accedi"))
        #expect(ClaudeCLI.problem(in: "zsh: command not found: claude").localizedDescription.contains("non è installato"))
    }

    @Test func detectsProjectKind() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "<html></html>".write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
        #expect(DevCommand.detect(in: folder)?.kind == .staticPage)
        try #"{"scripts":{"dev":"vite"}}"#.write(to: folder.appending(path: "package.json"), atomically: true, encoding: .utf8)
        #expect(DevCommand.detect(in: folder)?.command == "npm install && npm run dev")
        #expect(DevCommand.localURL(in: "  ➜  Local:   \u{1B}[36mhttp://localhost:5173/\u{1B}[39m")?.absoluteString == "http://localhost:5173/")
    }

    /// «Non funziona», «c'è un errore», «sistema»: gli errori dell'anteprima vanno all'agente con la richiesta.
    @Test func recognizesProblemReports() {
        #expect(CodeAgent.mentionsProblem("non funziona, sistema"))
        #expect(CodeAgent.mentionsProblem("Il gioco non parte"))
        #expect(CodeAgent.mentionsProblem("c'è un errore nella pagina"))
        #expect(CodeAgent.mentionsProblem("vedo una pagina bianca"))
        #expect(!CodeAgent.mentionsProblem("aggiungi una pagina di contatti"))
        #expect(!CodeAgent.mentionsProblem("rendi il sito più elegante"))
    }

    /// L'agente sul Mac ha `controlla_pagina` solo se l'app sa aprire le pagine e il progetto è un sito (o è ancora vuoto).
    @Test func pageCheckIsOfferedForWebsites() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sito-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let checker: CodeAgent.PageChecker = { url in url.lastPathComponent == "index.html" ? ["ReferenceError: nonEsiste is not defined (script.js:3)"] : [] }
        let empty = CodeToolbox(folder: folder, mode: .edit, compact: false, checkPage: checker) { _ in }
        #expect(empty.specs.contains { $0.name == "controlla_pagina" })
        try "<html></html>".write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let site = CodeToolbox(folder: folder, mode: .plan, compact: false, checkPage: checker) { _ in }
        #expect(site.specs.contains { $0.name == "controlla_pagina" })
        let report = await site.run("controlla_pagina", [:])
        #expect(report.contains("ReferenceError") && report.contains("index.html"))
        #expect(await site.run("controlla_pagina", ["percorso": "manca.html"]).hasPrefix("Errore"))
        // Senza chi apre le pagine (la CLI) o in un progetto Swift, niente strumento.
        #expect(!CodeToolbox(folder: folder, mode: .edit, compact: false) { _ in }.specs.contains { $0.name == "controlla_pagina" })
        let swift = FileManager.default.temporaryDirectory.appending(path: "app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: swift, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(to: swift.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        #expect(!CodeToolbox(folder: swift, mode: .edit, compact: false, checkPage: checker) { _ in }.specs.contains { $0.name == "controlla_pagina" })
        #expect(LocalCodeAgent.instructions(folder: folder, mode: .edit, compact: false, checksPages: true).contains("controlla_pagina"))
    }

    /// La sezione File dei progetti: i file cambiati di recente e la ricerca per nome, senza dipendenze né file nascosti.
    @Test func projectFilesRecentsAndSearch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "progetto-\(UUID().uuidString)")
        for sub in ["docs", "node_modules/pkg", ".git"] {
            try FileManager.default.createDirectory(at: folder.appending(path: sub), withIntermediateDirectories: true)
        }
        let files = ["vecchio.md", "docs/nuovo.md", "node_modules/pkg/index.js", ".git/config"]
        for (index, file) in files.enumerated() {
            let url = folder.appending(path: file)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index) * 60 - 3600)], ofItemAtPath: url.path)
        }
        let recents = await FileStore.recentlyModified(in: folder)
        #expect(recents.map(\.name) == ["nuovo.md", "vecchio.md"])
        #expect(await FileStore.find("nuov", in: folder).map(\.name) == ["nuovo.md"])
    }

    @Test func snapshotsRestoreFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "uno".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let snap = try #require(await CodeSnapshot.take(folder, label: "prima"))
        try "due".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "nuovo".write(to: folder.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        let changes = await CodeSnapshot.changes(folder, since: snap)
        #expect(changes.count == 2)
        let restore = await CodeSnapshot.restore(folder, to: snap)
        #expect(restore.error == nil)
        #expect(try String(contentsOf: folder.appending(path: "a.txt"), encoding: .utf8) == "uno")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "b.txt").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: ".git").path))
    }
}
