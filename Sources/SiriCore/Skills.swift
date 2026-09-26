import Foundation

/// Una skill: una procedura scritta in Markdown (`Skills/<nome>/SKILL.md`) che l'assistente segue quando la richiesta la riguarda.
/// Formato compatibile con le skill di Claude e di Hermes: frontmatter con `name`, `description` e (facoltative) `cues`.
public struct Skill: Identifiable, Sendable, Equatable {
    public var id: String { url.path }
    public var name: String
    public var description: String
    /// Parole che la attivano (oltre al nome).
    public var cues: [String]
    public var body: String
    public var url: URL
    /// Skill del progetto aperto (cartella `.skills` del progetto) o generale.
    public var inProject: Bool

    public var text: String {
        """
        ---
        name: \(name)
        description: \(description.replacingOccurrences(of: "\n", with: " "))
        cues: \(cues.joined(separator: ", "))
        ---

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }
}

public enum SkillStore {
    public static var folder: URL {
        let url = AppPaths.support("Skills")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func projectFolder(_ root: URL) -> URL { root.appending(path: ".skills") }

    /// Tutte le skill: generali e, se c'è, del progetto.
    public static func all(project: URL? = nil) -> [Skill] {
        var result = load(from: folder, inProject: false)
        if let project { result += load(from: projectFolder(project), inProject: true) }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func load(from folder: URL, inProject: Bool) -> [Skill] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { item in
            let file = item.hasDirectoryPath ? item.appending(path: "SKILL.md") : item
            guard file.pathExtension.lowercased() == "md", let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return parse(text, url: file, inProject: inProject)
        }
    }

    public static func parse(_ text: String, url: URL, inProject: Bool = false) -> Skill {
        var name = url.deletingLastPathComponent().lastPathComponent
        var description = ""
        var cues: [String] = []
        var body = text
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            let header = text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound]
            for line in header.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                switch key {
                case "name": name = value
                case "description": description = value
                case "cues", "triggers", "keywords":
                    cues = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased() }
                        .filter { !$0.isEmpty }
                default: break
                }
            }
            body = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Skill(name: name, description: description, cues: cues, body: body, url: url, inProject: inProject)
    }

    /// Skill pertinenti: una delle sue parole chiave o il nome compaiono nella richiesta.
    public static func matching(_ prompt: String, project: URL? = nil, limit: Int = 2) -> [Skill] {
        let lower = " " + MemoryStore.normalize(prompt) + " "
        let scored = all(project: project).compactMap { skill -> (Skill, Int)? in
            let cueHits = skill.cues.filter { lower.contains(" " + MemoryStore.normalize($0)) }.count
            let nameHit = lower.contains(" " + MemoryStore.normalize(skill.name) + " ") ? 2 : 0
            let score = cueHits * 2 + nameHit
            return score > 0 ? (skill, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Salva (o aggiorna) una skill: una cartella con SKILL.md.
    @discardableResult
    public static func save(name: String, description: String, cues: [String], body: String, project: URL? = nil, replacing: Skill? = nil) throws -> Skill {
        let base = project.map(projectFolder) ?? folder
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url: URL
        if let replacing { url = replacing.url } else {
            var slug = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
            if slug.isEmpty { slug = "skill" }
            var candidate = base.appending(path: slug)
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) { candidate = base.appending(path: "\(slug)-\(counter)"); counter += 1 }
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            url = candidate.appending(path: "SKILL.md")
        }
        let skill = Skill(name: name, description: description, cues: cues, body: body, url: url, inProject: project != nil)
        try skill.text.write(to: url, atomically: true, encoding: .utf8)
        return skill
    }

    public static func delete(_ skill: Skill) throws {
        let folder = skill.url.deletingLastPathComponent()
        // Nel Cestino, mai cancellazione definitiva.
        try FileManager.default.trashItem(at: folder.lastPathComponent == "Skills" || folder.lastPathComponent == ".skills" ? skill.url : folder, resultingItemURL: nil)
    }

    /// Skill ricavata da un piano di lavoro riuscito: obiettivo, passi e consegna diventano una procedura riusabile.
    public static func draft(from plan: TaskPlan) -> (name: String, description: String, cues: [String], body: String) {
        let words = plan.goal.split(separator: " ").prefix(6).joined(separator: " ")
        let name = words.prefix(1).uppercased() + words.dropFirst()
        let cues = Array(MemoryStore.keywords(plan.goal).sorted { $0.count > $1.count }.prefix(4))
        let steps = plan.steps.enumerated().map { "\($0.offset + 1). **\($0.element.title)** — \($0.element.instruction)" }.joined(separator: "\n")
        let body = """
        ## Obiettivo
        \(plan.goal)

        ## Procedura
        \(steps)

        ## Consegna
        \(plan.delivery == .documento ? "Un documento con il risultato." : "Una risposta chiara in chat, con i dati trovati.")
        """
        return (name, "Procedura per: \(plan.goal)", cues, body)
    }
}

extension Assistant {
    /// Procedure delle skill pertinenti, per il preambolo della risposta.
    func skillGuide(for prompt: String) -> String? {
        let skills = SkillStore.matching(prompt, project: work.projectRoot)
        guard !skills.isEmpty else { return nil }
        for skill in skills where !(trace?.steps.contains { $0.action == "skill" && $0.detail == skill.name } ?? true) {
            trace?.steps.append(TraceStep(action: "skill", detail: skill.name, result: "procedura seguita", milliseconds: 0, ok: true))
        }
        return skills.map { "Procedura «\($0.name)» (segui questi passi):\n\($0.body.prefix(budget.scaled(900)))" }.joined(separator: "\n\n")
    }
}
