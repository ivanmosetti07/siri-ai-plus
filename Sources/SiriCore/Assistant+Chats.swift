import Foundation

extension Assistant {
    // MARK: - Chat create chattando

    /// "Apri una chat sul lancio nel progetto X", "crea una chat figlia per la ricerca: cerca i concorrenti".
    func chatRules(to plan: inout Plan, prompt: String, lower: String) -> Bool {
        let site = #"^(?:per favore |puoi |ora )?(?:crea|creami|fai|fammi|genera|prepara|realizza|costruisci|progetta|disegna)\s+(?:una\s+|un\s+|la\s+|il\s+)?(?:nuova\s+|nuovo\s+|semplice\s+|bella\s+)?(?:pagina web|pagina html|sito(?:\s+web)?|landing(?:\s+page)?|pagina internet|homepage)\b"#
        if lower.range(of: site, options: .regularExpression) != nil {
            plan.action = .crea_sito
            return true
        }
        let agent = #"^(?:per favore |puoi |ora |adesso )?(?:crea|crei|creami|fai|fammi|configura|imposta|prepara|voglio|attiva|aggiungi)\s+(?:un|uno|un nuovo|l'|il)?\s*(?:nuovo\s+)?agente\b"#
        if lower.range(of: agent, options: .regularExpression) != nil {
            plan.action = .crea_agente
            return true
        }
        let pattern = #"^(?:per favore |puoi |ora |adesso )?(?:apri|apriamo|crea|creami|avvia|inizia|iniziamo|fai partire|fammi|comincia|facciamo|voglio|nuova)\s+(?:una\s+|un'?\s*|la\s+)?(?:nuova\s+)?(?:chat|conversazione|sotto-?chat|discussione)\b"#
        guard lower.range(of: pattern, options: .regularExpression) != nil else { return false }
        plan.action = .nuova_chat
        return true
    }

    func chatRequest(from plan: Plan, prompt: String) -> ChatRequest {
        let lower = prompt.lowercased()
        var rest = prompt
        // Via il comando iniziale ("apri una nuova chat figlia").
        rest = rest.replacingOccurrences(of: #"(?i)^(?:per favore |puoi |ora |adesso )?\S+\s+(?:una\s+|un'?\s*|la\s+)?(?:nuova\s+)?(?:chat|conversazione|sotto-?chat|discussione)\s*(?:figlia|separata|a parte|indipendente|nuova)?\s*"#,
                                         with: "", options: .regularExpression)
        // Primo messaggio: dopo i due punti, o dopo "e chiedi / e cerca / e scrivi…".
        var firstMessage: String?
        if let colon = rest.firstIndex(of: ":") {
            firstMessage = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<colon])
        } else if let range = rest.range(of: #"(?i)\s+(?:e|dove|in cui)\s+(?=(?:chiedi|cerca|scrivi|prepara|fai|analizza|trova|leggi|riassumi|crea|studia|confronta|pianifica|organizza)\b)"#, options: .regularExpression) {
            firstMessage = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<range.lowerBound])
        }
        // Progetto: nominato esplicitamente o uno di quelli collegati citato nella frase.
        var project = plan["lista"].flatMap { name in work.projectNames.first { $0.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0) } }
        if let name = work.projectNames.sorted(by: { $0.count > $1.count }).first(where: { lower.contains($0.lowercased()) }) { project = name }
        if let project {
            rest = rest.replacingOccurrences(of: "(?i)\\s*(?:nel|nella|dentro il|dentro al|per il|in)?\\s*(?:progetto\\s+)?" + NSRegularExpression.escapedPattern(for: project), with: "", options: .regularExpression)
        }
        rest = rest.replacingOccurrences(of: #"(?i)\b(?:nel|in|dentro il)\s+progetto\b"#, with: "", options: .regularExpression)
        // Argomento: "su X", "per X", "sul/sulla X", "dedicata a X".
        var title = rest.replacingOccurrences(of: #"(?i)^\s*(?:su|sul|sulla|sullo|sugli|sulle|per|per il|per la|riguardo|riguardo a|dedicata a|chiamata|di nome|intitolata)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;«»\"'")))
        title = title.replacingOccurrences(of: #"(?i)^(?:il|lo|la|i|gli|le|l')\s*"#, with: "", options: .regularExpression)
        if title.isEmpty { title = plan["argomento"] ?? plan["titolo"] ?? firstMessage.map { String($0.prefix(40)) } ?? "Nuova chat" }
        title = title.prefix(1).uppercased() + title.dropFirst()
        firstMessage = firstMessage?.replacingOccurrences(of: #"(?i)^(?:chiedi|chiedile|chiedigli|domanda)\s+(?:di\s+|se\s+)?"#, with: "", options: .regularExpression)
        if let text = firstMessage, !text.isEmpty { firstMessage = text.prefix(1).uppercased() + text.dropFirst() }
        let independent = ["indipendente", "separata", "nuova conversazione", "non figlia", "da zero"].contains(where: lower.contains)
        let child = !independent && (hasChildWords(lower) || work.hasConversation)
        return ChatRequest(title: String(title.prefix(60)), project: project, firstMessage: firstMessage?.isEmpty == true ? nil : firstMessage, child: child)
    }

    private func hasChildWords(_ lower: String) -> Bool {
        ["figlia", "sotto-chat", "sottochat", "riportami", "riporta", "poi torna", "a parte"].contains(where: lower.contains)
    }
}
