import Foundation
import Testing
@testable import SiriCore

@Suite struct AgentHistoryTests {
    @Test func rebuildsRunsFromLog() {
        let log: [AgentEvent] = [
            AgentEvent(kind: .nota, text: "Agente creato"),
            AgentEvent(kind: .avvio, text: "Inizio dell'esecuzione n. 1 · Ogni giorno alle 18:00: controlla la posta"),
            AgentEvent(kind: .piano, text: "Leggi → Riassumi"),
            AgentEvent(kind: .passo, text: "Leggi: fatto"),
            AgentEvent(kind: .approvazione, text: "Da approvare: Rispondi a Marco"),
            AgentEvent(kind: .risultato, text: "Tre email lette"),
            AgentEvent(kind: .avvio, text: "Inizio dell'esecuzione n. 2"),
            AgentEvent(kind: .errore, text: "Modello non disponibile"),
            AgentEvent(kind: .avvio, text: "Inizio dell'esecuzione n. 3"),
        ]
        let runs = AgentSpec.history(fromLog: log)
        #expect(runs.count == 3)
        #expect(runs[0].trigger == .programmata)
        #expect(runs[0].routineLabel == "Ogni giorno alle 18:00")
        #expect(runs[0].task == "controlla la posta")
        #expect(runs[0].steps == 1 && runs[0].approvals == 1)
        #expect(runs[0].outcome == .daApprovare)
        #expect(runs[0].summary == "Tre email lette")
        #expect(runs[1].trigger == .manuale && runs[1].outcome == .errore)
        #expect(runs[2].outcome == .interrotta)
    }

    @Test func historyIsSavedAndCapped() throws {
        var agent = AgentSpec(name: "Prova", goal: "x")
        var last = UUID()
        for _ in 0..<205 { last = agent.beginRun(.manuale, routine: nil) }
        agent.updateRun(last) { $0.outcome = .completata; $0.summary = "ok" }
        #expect(agent.history.count == 200)
        let decoded = try JSONDecoder().decode(AgentSpec.self, from: JSONEncoder().encode(agent))
        #expect(decoded.history.count == 200)
        #expect(decoded.history.last?.summary == "ok")
    }

    @Test func scheduledOccurrenceSurvivesRestart() throws {
        var agent = AgentSpec(name: "Agenda", goal: "Controlla gli impegni")
        let occurrence = "\(agent.id.uuidString)|routine|1780000000"
        let id = agent.beginRun(.programmata, routine: nil, occurrenceID: occurrence)
        let data = try JSONEncoder().encode(agent)
        let restored = try JSONDecoder().decode(AgentSpec.self, from: data)
        #expect(restored.history.contains { $0.id == id && $0.occurrenceID == occurrence && $0.outcome == .inCorso })
        #expect(restored.history.filter { $0.occurrenceID == occurrence }.count == 1)
    }

    @Test func oldRunWithoutOccurrenceStillDecodes() throws {
        let run = AgentRun(trigger: .manuale)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        json.removeValue(forKey: "occurrenceID")
        let restored = try JSONDecoder().decode(AgentRun.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.occurrenceID == nil)
    }

    @Test func failedClaimWriteIsReported() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agent-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "agents.json")
        #expect(SafeJSON.write(Data("claimed".utf8), to: destination))
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        #expect(!SafeJSON.write(Data("claimed".utf8), to: destination))
    }
}
