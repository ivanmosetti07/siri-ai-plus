import Foundation
import Testing
@testable import SiriCore

/// Il grafo dei progetti: collegamenti come in Obsidian, note disposte dentro la sagoma di un cervello.
@Suite struct ProjectGraphTests {
    /// Cartella di prova con note collegate in tutti i modi che Obsidian riconosce.
    private func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "grafo-\(UUID().uuidString)")
        let fm = FileManager.default
        for folder in ["2_Aree/agenzia", "2_Aree/salute", "3_Risorse/persone", "1_Progetti/rossi-moto"] {
            try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        let notes: [String: String] = [
            "CLAUDE.md": "# Mappa\n- [[STATE]]\n- [Obiettivi](OBJECTIVES.md)\n- [[2_Aree/agenzia/INDEX|Agenzia]]\n- [Sito](https://esempio.it)",
            "STATE.md": "# Stato\nVedi [[OBJECTIVES#Q3]] e [[Martina Verdi]].",
            "OBJECTIVES.md": "# Obiettivi\n",
            "2_Aree/agenzia/INDEX.md": "# Agenzia\n[[rossi-moto/INDEX]] · [[../salute/INDEX.md]]",
            "2_Aree/salute/INDEX.md": "# Salute\n",
            "1_Progetti/rossi-moto/INDEX.md": "# Rossi Moto\n[Referente](../../3_Risorse/persone/Martina%20Verdi.md)",
            "3_Risorse/persone/Martina Verdi.md": "# Martina\n",
            "3_Risorse/persone/sola.md": "# Nessun collegamento\n",
        ]
        for (path, text) in notes { try text.write(to: root.appending(path: path), atomically: true, encoding: .utf8) }
        return root
    }

    private func edges(_ graph: ProjectGraph) -> Set<String> {
        Set(graph.edges.map { [graph.nodes[$0.a].path, graph.nodes[$0.b].path].sorted().joined(separator: " — ") })
    }

    @Test func linksLikeObsidian() async throws {
        let root = try vault()
        let graph = await ProjectGuide.shared(for: root).graph()
        let links = edges(graph)
        #expect(links.contains("CLAUDE.md — STATE.md"))
        #expect(links.contains("CLAUDE.md — OBJECTIVES.md"))
        // Alias (`|`), sezioni (`#`), percorsi relativi, nomi con spazi codificati e ricerca per nome in altre cartelle.
        #expect(links.contains("2_Aree/agenzia/INDEX.md — CLAUDE.md"))
        #expect(links.contains("OBJECTIVES.md — STATE.md"))
        #expect(links.contains("3_Risorse/persone/Martina Verdi.md — STATE.md"))
        #expect(links.contains("1_Progetti/rossi-moto/INDEX.md — 2_Aree/agenzia/INDEX.md"))
        #expect(links.contains("2_Aree/agenzia/INDEX.md — 2_Aree/salute/INDEX.md"))
        #expect(links.contains("1_Progetti/rossi-moto/INDEX.md — 3_Risorse/persone/Martina Verdi.md"))
        #expect(graph.edges.count == 8 && graph.totalNotes == 8)
        // Con poche note restano anche quelle senza collegamenti; i nomi ripetuti portano la cartella.
        #expect(graph.nodes.contains { $0.path == "3_Risorse/persone/sola.md" && $0.degree == 0 })
        #expect(Set(graph.nodes.filter { $0.path.hasSuffix("INDEX.md") }.map(\.title)) == ["agenzia/INDEX", "salute/INDEX", "rossi-moto/INDEX"])
        #expect(graph.nodes.first { $0.path == "CLAUDE.md" }?.title == "CLAUDE")
        #expect(graph.groups.first == "" || graph.groups.contains("2_Aree"))
        // Solo una cartella: le aree diventano le sue sottocartelle.
        let areas = await ProjectGuide.shared(for: root).graph(folder: "2_Aree")
        #expect(Set(areas.nodes.map(\.path)) == ["2_Aree/agenzia/INDEX.md", "2_Aree/salute/INDEX.md"])
        #expect(Set(areas.groups) == ["agenzia", "salute"])
    }

    @Test func manyNotesFillTheBrain() {
        // 600 note in 6 cartelle, collegate soprattutto dentro la loro cartella, con qualche centro molto collegato.
        var graph = ProjectGraph()
        var generator = SeededGenerator(seed: 42)
        let groups = ["2_Aree", "3_Risorse", "1_Progetti", "4_Archivio", "0_Inbox", ""]
        for index in 0..<600 {
            graph.nodes.append(ProjectGraph.Node(id: index, path: "n\(index).md", title: "n\(index)", group: groups[index % groups.count], degree: 0))
        }
        var edges = Set<ProjectGraph.Edge>()
        for index in 0..<600 {
            for _ in 0..<2 {
                let other = Int.random(in: 0..<100, using: &generator) < 70
                    ? (index + 6 * Int.random(in: 1...20, using: &generator)) % 600
                    : Int.random(in: 0..<12, using: &generator)
                if other != index { edges.insert(ProjectGraph.Edge(a: min(index, other), b: max(index, other))) }
            }
        }
        graph.edges = Array(edges)
        for edge in graph.edges { graph.nodes[edge.a].degree += 1; graph.nodes[edge.b].degree += 1 }
        graph.groups = groups
        GraphLayout.brain(&graph)
        let points = graph.nodes.map { ($0.x, $0.y) }
        // Tutte dentro la sagoma, nessuna nei solchi, nessuna sovrapposta.
        #expect(points.allSatisfy { GraphLayout.inside($0.0, $0.1, margin: 0.02) })
        #expect(!points.contains { GraphLayout.nearSulcus($0.0, $0.1, gap: 0.02) })
        #expect(Set(points.map { "\(($0.0 * 1000).rounded()),\(($0.1 * 1000).rounded())" }).count == 600)
        // Riempiono il cervello: dalla fronte alla nuca e dall'alto al cervelletto.
        let xs = points.map(\.0), ys = points.map(\.1)
        #expect(xs.min()! < -0.85 && xs.max()! > 0.85 && ys.min()! < -0.65 && ys.max()! > 0.6)
        // I collegamenti restano corti: le note collegate stanno vicine.
        let average = graph.edges.map { edge -> Double in
            let a = graph.nodes[edge.a], b = graph.nodes[edge.b]
            return ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }.reduce(0, +) / Double(graph.edges.count)
        #expect(average < 0.6)
        // Stesso progetto, stessa disposizione.
        var again = graph
        GraphLayout.brain(&again)
        #expect(again.nodes.map(\.x) == graph.nodes.map(\.x))
    }

    @Test func aFewNotesStillSitInTheBrain() {
        var graph = ProjectGraph()
        for index in 0..<3 { graph.nodes.append(ProjectGraph.Node(id: index, path: "\(index).md", title: "\(index)", group: "", degree: 1)) }
        graph.edges = [ProjectGraph.Edge(a: 0, b: 1), ProjectGraph.Edge(a: 1, b: 2)]
        graph.groups = [""]
        GraphLayout.brain(&graph)
        #expect(graph.nodes.allSatisfy { GraphLayout.inside($0.x, $0.y, margin: 0.02) })
    }
}
