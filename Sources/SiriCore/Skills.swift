import Foundation

/// Una skill: una procedura scritta in Markdown (`Skills/<nome>/SKILL.md`) che l'assistente segue quando la richiesta la riguarda.
/// Formato compatibile con le skill di Claude e di Hermes: frontmatter con `name`, `description` e (facoltative) `cues`.
public struct Skill: Identifiable, Sendable, Equatable {
    public var id: String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    public var name: String
    public var description: String
    /// Parole che la attivano (oltre al nome).
    public var cues: [String]
    public var body: String
    public var url: URL
    /// Skill del progetto aperto (cartella `.skills` del progetto) o generale.
    public var inProject: Bool
    /// Skill privata di un Genius: non compare nelle chat degli altri Genius.
    public var agentID: UUID? = nil

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

    /// Le skill di un Genius vivono accanto alla sua anima e vengono rimosse con lui.
    public static func agentFolder(_ id: UUID) -> URL {
        AppPaths.support("Agents").appending(path: id.uuidString).appending(path: "Skills")
    }

    public static func forAgent(_ id: UUID) -> [Skill] {
        load(from: agentFolder(id), inProject: false, agent: id)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Skill disponibili nel contesto: generali, del progetto e del Genius selezionato.
    public static func all(project: URL? = nil, agent: UUID? = nil) -> [Skill] {
        var result = load(from: folder, inProject: false)
        if let project { result += load(from: projectFolder(project), inProject: true) }
        if let agent { result += forAgent(agent) }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func load(from folder: URL, inProject: Bool, agent: UUID? = nil) -> [Skill] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { item in
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let file = isDirectory ? item.appending(path: "SKILL.md") : item
            guard file.pathExtension.lowercased() == "md", let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return parse(text, url: file, inProject: inProject, agent: agent)
        }
    }

    public static func parse(_ text: String, url: URL, inProject: Bool = false, agent: UUID? = nil) -> Skill {
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
        return Skill(name: name, description: description, cues: cues, body: body, url: url, inProject: inProject, agentID: agent)
    }

    /// Skill pertinenti: una delle sue parole chiave o il nome compaiono nella richiesta.
    public static func matching(_ prompt: String, project: URL? = nil, agent: UUID? = nil, limit: Int = 2) -> [Skill] {
        let lower = " " + MemoryStore.normalize(prompt) + " "
        // Una skill privata con lo stesso nome prende il posto di quella generale o del progetto.
        let ordered = all(project: project, agent: agent).sorted { lhs, rhs in
            let left = lhs.agentID != nil ? 2 : lhs.inProject ? 1 : 0
            let right = rhs.agentID != nil ? 2 : rhs.inProject ? 1 : 0
            return left == right ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : left > right
        }
        var names = Set<String>()
        let available = ordered.filter { names.insert(MemoryStore.normalize($0.name)).inserted }
        let scored = available.compactMap { skill -> (Skill, Int)? in
            let cueHits = skill.cues.filter { lower.contains(" " + MemoryStore.normalize($0)) }.count
            let nameHit = lower.contains(" " + MemoryStore.normalize(skill.name) + " ") ? 2 : 0
            let score = cueHits * 2 + nameHit
            return score > 0 ? (skill, score) : nil
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if (lhs.0.agentID != nil) != (rhs.0.agentID != nil) { return lhs.0.agentID != nil }
            return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
        }.prefix(limit).map(\.0)
    }

    /// Salva (o aggiorna) una skill: una cartella con SKILL.md.
    @discardableResult
    public static func save(name: String, description: String, cues: [String], body: String,
                            project: URL? = nil, agent: UUID? = nil, replacing: Skill? = nil) throws -> Skill {
        let base = agent.map(agentFolder) ?? project.map(projectFolder) ?? folder
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url: URL
        if let replacing { url = replacing.url } else {
            let candidate = availableFolder(named: name, in: base)
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            url = candidate.appending(path: "SKILL.md")
        }
        let skill = Skill(name: name, description: description, cues: cues, body: body, url: url,
                          inProject: project != nil && agent == nil, agentID: agent)
        try skill.text.write(to: url, atomically: true, encoding: .utf8)
        return skill
    }

    /// Duplica una skill esistente con eventuali file di supporto, rendendola privata di un Genius.
    @discardableResult
    public static func copy(_ source: Skill, toAgent id: UUID) throws -> Skill {
        let base = agentFolder(id)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = availableFolder(named: source.name, in: base)
        let sourceFolder = source.url.deletingLastPathComponent()
        let bundled = source.url.lastPathComponent == "SKILL.md"
            && sourceFolder.lastPathComponent != "Skills" && sourceFolder.lastPathComponent != ".skills"
        if bundled {
            try FileManager.default.copyItem(at: sourceFolder, to: destination)
        } else {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.url, to: destination.appending(path: "SKILL.md"))
        }
        let file = destination.appending(path: "SKILL.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        return parse(text, url: file, agent: id)
    }

    private static func availableFolder(named name: String, in base: URL) -> URL {
        var slug = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        if slug.isEmpty { slug = "skill" }
        var candidate = base.appending(path: slug)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appending(path: "\(slug)-\(counter)")
            counter += 1
        }
        return candidate
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
        if Language.isEnglish {
            let body = """
            ## Goal
            \(plan.goal)

            ## Procedure
            \(steps)

            ## Delivery
            \(plan.delivery == .documento ? "A document with the result." : "A clear answer in the chat, with the data found.")
            """
            return (name, "Procedure for: \(plan.goal)", cues, body)
        }
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
        let skills = SkillStore.matching(work.skillTask ?? prompt,
                                         project: work.skillProjectRoot ?? work.projectRoot, agent: work.agentID)
        guard !skills.isEmpty else { return nil }
        for skill in skills where !(trace?.steps.contains { $0.action == "skill" && $0.detail == skill.name } ?? true) {
            trace?.steps.append(TraceStep(action: "skill", detail: skill.name, result: Language.t("procedura seguita", "procedure followed"), milliseconds: 0, ok: true))
        }
        return skills.map { skill in
            let resources = skill.agentID == work.agentID && work.linkedFolders["Skill"] != nil
                ? "\n" + Language.t("File di supporto nella cartella", "Supporting files in the folder")
                    + " Skill/\(skill.url.deletingLastPathComponent().lastPathComponent)/."
                : ""
            let body = skill.body.prefix(budget.scaled(900))
            return Language.t("Procedura «\(skill.name)» (segui questi passi):\n\(body)\(resources)",
                              "Procedure “\(skill.name)” (follow these steps):\n\(body)\(resources)")
        }.joined(separator: "\n\n")
    }
}
