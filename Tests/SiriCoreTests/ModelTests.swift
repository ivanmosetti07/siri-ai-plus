import Foundation
import Testing
@testable import SiriCore

/// Modelli, versioni e ragionamento; l'agente di coding con i modelli sul Mac.
@Suite struct ModelTests {
    @Test func chatGPTModelsFromCodexCache() {
        let cache = #"""
        {"models":[
          {"slug":"gpt-6-sol","display_name":"GPT-6-Sol","visibility":"list","priority":2,"default_reasoning_level":"medium",
           "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]},
          {"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide","priority":43},
          {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","visibility":"list","priority":1,"default_reasoning_level":"medium",
           "supported_reasoning_levels":[{"effort":"low"},{"effort":"max"}]}
        ]}
        """#
        let models = ModelCatalog.chatGPT(from: Data(cache.utf8))
        #expect(models.map(\.id) == ["gpt-6-astra", "gpt-6-sol"])
        #expect(models[1].label == "GPT-6-Sol" && models[1].efforts == ["low", "medium", "high", "xhigh"] && models[1].defaultEffort == "medium")
        #expect(ModelCatalog.chatGPT(from: Data("non json".utf8)).isEmpty)
    }

    @Test func codexDefaultsOnlyAtTop() {
        let config = """
        model = "gpt-6-sol"
        model_reasoning_effort = "xhigh" # commento
        [profiles.veloce]
        model = "gpt-6-luna"
        """
        let defaults = ModelCatalog.codexDefaults(from: config)
        #expect(defaults.model == "gpt-6-sol" && defaults.effort == "xhigh")
    }

    @Test func effortFallsBackToWhatTheModelAccepts() {
        let sol = ModelOption(id: "gpt-6-sol", label: "GPT-6-Sol", efforts: ["low", "medium", "high"], defaultEffort: "medium")
        #expect(ModelCatalog.effort("high", for: sol) == "high")
        #expect(ModelCatalog.effort("ultra", for: sol) == "medium")
        #expect(ModelCatalog.effort("high", for: ModelOption(id: "haiku", label: "Haiku")) == nil)
        #expect(ModelCatalog.effortLabel("xhigh") == "Molto alto" && ModelCatalog.effortLabel("on") == "Acceso")
        #expect(ModelCatalog.claude.map(\.id) == ["fable", "opus", "sonnet", "haiku"])
        #expect(ModelCatalog.claude.last?.efforts.isEmpty == true)
    }

    @Test func selectionsSurviveAndGeminiIsGone() throws {
        let saved = try JSONEncoder().encode(ModelSelection(.claude, model: "opus", effort: "max"))
        #expect(try JSONDecoder().decode(ModelSelection.self, from: saved) == ModelSelection(.claude, model: "opus", effort: "max"))
        // Le chat salvate con Gemini tornano al modello dello spazio.
        #expect((try? JSONDecoder().decode(ModelSelection.self, from: Data(#"{"provider":"gemini"}"#.utf8))) == nil)
        #expect(ResponseProvider(rawValue: "gemini") == nil)
        #expect(!ResponseProvider.claude.isLocal && ResponseProvider.claude.company == "Anthropic")
    }

    @Test func cliArgumentsAreQuoted() {
        #expect(ExternalAgent.codexModelArguments(model: "gpt-6-sol", effort: "low") == #" -m 'gpt-6-sol' -c 'model_reasoning_effort="low"'"#)
        #expect(ExternalAgent.claudeModelArguments(model: "opus", effort: nil) == " --model 'opus'")
        #expect(ExternalAgent.codexModelArguments(model: nil, effort: nil).isEmpty)
    }

    // MARK: Agente di coding sul Mac

    private func project() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "siriai-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "node_modules/pacchetto"), withIntermediateDirectories: true)
        try "<h1>Ciao</h1>\n<p>Benvenuto</p>\n".write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try "let saluto = \"ciao\"\nlet saluto2 = \"ciao\"\n".write(to: folder.appending(path: "src/app.js"), atomically: true, encoding: .utf8)
        try "dipendenza".write(to: folder.appending(path: "node_modules/pacchetto/index.js"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func toolboxStaysInsideTheProject() throws {
        let folder = try project()
        let toolbox = CodeToolbox(folder: folder, mode: .edit, compact: false) { _ in }
        #expect(toolbox.resolve("../fuori.txt") == nil)
        #expect(toolbox.resolve("/etc/hosts") == nil)
        #expect(toolbox.resolve(".git/config") == nil)
        #expect(toolbox.resolve("src/app.js")?.lastPathComponent == "app.js")
        #expect(toolbox.resolve(folder.appending(path: "index.html").path) != nil)
    }

    @Test func toolboxReadsSearchesAndEdits() async throws {
        let folder = try project()
        let events = EventLog()
        let toolbox = CodeToolbox(folder: folder, mode: .edit, compact: false) { events.add($0) }
        let list = await toolbox.run("elenca_file", [:])
        #expect(list.contains("index.html") && list.contains("src/app.js") && !list.contains("node_modules"))
        let read = await toolbox.run("leggi_file", ["percorso": "index.html"])
        #expect(read.contains("1| <h1>Ciao</h1>") && read.contains("2| <p>Benvenuto</p>"))
        let found = await toolbox.run("cerca", ["testo": "BENVENUTO"])
        #expect(found.contains("index.html:2:"))
        // Il testo da sostituire deve essere unico.
        let twice = await toolbox.run("modifica_file", ["percorso": "src/app.js", "vecchio_testo": "\"ciao\"", "nuovo_testo": "\"salve\""])
        #expect(twice.contains("compare 2 volte"))
        let missing = await toolbox.run("modifica_file", ["percorso": "index.html", "vecchio_testo": "Arrivederci", "nuovo_testo": "x"])
        #expect(missing.contains("non si trova"))
        let edited = await toolbox.run("modifica_file", ["percorso": "index.html", "vecchio_testo": "<h1>Ciao</h1>", "nuovo_testo": "<h1>Salve</h1>"])
        #expect(edited.hasPrefix("Fatto"))
        #expect(try String(contentsOf: folder.appending(path: "index.html"), encoding: .utf8).contains("<h1>Salve</h1>"))
        // I «\n» letterali dei modelli piccoli diventano a capo.
        _ = await toolbox.run("scrivi_file", ["percorso": "css/stile.css", "contenuto": #"body {\n  margin: 0;\n}\n"#])
        #expect(try String(contentsOf: folder.appending(path: "css/stile.css"), encoding: .utf8) == "body {\n  margin: 0;\n}\n")
        #expect(events.all.contains { $0.kind == .file && $0.path == "css/stile.css" && $0.text == "Crea" })
        #expect(toolbox.journal(limit: 500).contains("modificato index.html"))
    }

    @Test func planModeChangesNothing() async throws {
        let folder = try project()
        let toolbox = CodeToolbox(folder: folder, mode: .plan, compact: true) { _ in }
        #expect(!toolbox.specs.map(\.name).contains("scrivi_file"))
        let refused = await toolbox.run("scrivi_file", ["percorso": "nuovo.txt", "contenuto": "x"])
        #expect(refused.contains("chiedi prima"))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "nuovo.txt").path))
    }

    @Test func commandsRunInTheSandbox() async throws {
        let folder = try project()
        let outside = URL(fileURLWithPath: "/Users/Shared/siriai-recinto-\(UUID().uuidString).txt")
        let toolbox = CodeToolbox(folder: folder, mode: .edit, compact: false) { _ in }
        let inside = await toolbox.run("esegui_comando", ["comando": "echo ok > dentro.txt && cat dentro.txt"])
        #expect(inside.contains("Codice di uscita 0") && inside.contains("ok"))
        let blocked = await toolbox.run("esegui_comando", ["comando": "echo no > \(Shell.quote(outside.path))"])
        #expect(!blocked.contains("Codice di uscita 0"))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        if FileManager.default.fileExists(atPath: outside.path) { try? FileManager.default.trashItem(at: outside, resultingItemURL: nil) }
    }

    @Test func conversationShrinksOldToolResults() {
        var messages: [JSONValue] = [.object(["role": .string("system"), "content": .string("istruzioni")])]
        for index in 0..<8 {
            messages.append(.object(["role": .string("tool"), "content": .string(String(repeating: "\(index)", count: 2000))]))
        }
        LocalCodeAgent.compact(&messages, characters: 6000)
        #expect(messages[1]["content"]?.string?.hasPrefix("[risultato già letto") == true)
        #expect(messages.last?["content"]?.string?.count == 2000)
        #expect(messages.count == 9)
    }

    @Test func agentInstructionsIncludeProjectRules() throws {
        let folder = try project()
        try "Usa sempre Tailwind.".write(to: folder.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        let edit = LocalCodeAgent.instructions(folder: folder, mode: .edit, compact: false)
        #expect(edit.contains("Usa sempre Tailwind.") && edit.contains("modifica_file"))
        #expect(LocalCodeAgent.instructions(folder: folder, mode: .plan, compact: true).contains("chiedi prima"))
    }
}

/// Eventi raccolti dagli strumenti (arrivano da thread diversi).
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CodeEvent] = []
    func add(_ event: CodeEvent) { lock.withLock { events.append(event) } }
    var all: [CodeEvent] { lock.withLock { events } }
}
