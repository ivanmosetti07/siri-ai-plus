import Foundation

extension Assistant {
    // MARK: - Quali strumenti servono

    /// Parole che fanno pensare a informazioni da cercare sul web (fatti recenti o che cambiano).
    static let webCues = [
        "internet", " web", "online", "google", "cerca su", "cercami", "notizi", "news", "ultim", "attual", "recent", "novità",
        "prezzo", "prezzi", "quanto costa", "costo", "quotazion", "borsa", "cambio euro", "meteo", "che tempo", "previsioni",
        "risultat", "classifica", "chi ha vinto", "partita", "campionato", "uscit", "quando esce", "recension", "orari", "orario",
        "indirizzo", "dove si trova", "come arrivare", "sito", "link", "fonte", "fonti", "aggiornat", "oggi", "stasera", "elezioni",
        "2024", "2025", "2026", "2027", "chi è l'attuale", "presidente", "ceo", "lancio", "versione",
        "sindaco", "ministro", "premier", "governatore", "allenatore", "papa ", "segretario", "amministratore delegato", "direttore",
        "quanti anni ha", "è morto", "è ancora", "attualmente", "in questo momento", "adesso",
    ]

    /// Le stesse per le richieste in inglese.
    static let englishWebCues = [
        "internet", " web", "online", "google", "search for", "look up", "news", "latest", "current", "recent", "what's new",
        "price", "prices", "how much does", "how much is", "cost of", "stock", "exchange rate", "weather", "forecast",
        "results", "score", "standings", "who won", "match", "league", "released", "when does", "when is the", "review",
        "opening hours", "open until", "address", "where is", "how to get to", "website", "link", "source", "sources",
        "updated", "today", "tonight", "election", "2024", "2025", "2026", "2027", "who is the current", "president", " ceo",
        "launch", "version", "mayor", "minister", "prime minister", "governor", "coach", "pope ", "secretary", "chief executive",
        "director", "how old is", " died", "is still", "currently", "right now", "at the moment", "these days",
    ]

    /// Parole della lingua della richiesta: `Assistant.cues`, in inglese con quelle inglesi in più (nomi delle app e parole
    /// uguali nelle due lingue restano valide).
    static var activeCues: [Action: [String]] {
        guard Language.isEnglish else { return cues }
        return cues.merging(englishCues) { $0 + $1 }
    }

    /// Azioni plausibili secondo la richiesta. Vuoto = basta una risposta del modello, senza strumenti.
    func candidateActions(for prompt: String) -> Set<Action> {
        let lower = " \(prompt.lowercased()) "
        let english = Language.isEnglish
        let available = Set(availableActions)
        var found = Set<Action>()
        for (action, words) in Self.activeCues where available.contains(action) && words.contains(where: lower.contains) {
            found.insert(action)
        }
        // Domande di seguito ("e dopodomani?", "e a Roma?") continuano l'azione precedente.
        if let last = lastAction, last != .rispondi, isFollowUp(lower) { found.insert(last) }
        // Riferimenti ai dati mostrati prima ("cancella il primo").
        let references = ["il primo", "il secondo", "il terzo", "l'ultimo", "quello", "quella", "cancellalo", "eliminalo", "segnalo", "completalo"]
            + (english ? ["the first", "the second", "the third", "the last", "that one", "this one", "delete it", "remove it", "cancel it", "mark it", "complete it"] : [])
        if !context.isEmpty, references.contains(where: lower.contains) {
            found.formUnion([Action.elimina_evento, .completa_promemoria].filter(available.contains))
        }
        if let files = work.files {
            let names = files.allEntries(limit: 600)
                .map { (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() }
                .filter { $0.count >= 4 }
            let fileWords = ["file", "cartella", "leggi", "riassumi", "cerca", "trova", "contenuto", "progetto", "readme", "agents",
                             ".md", ".txt", "documenti", "scrivi", "crea", "elenca", "apri", "modifica", "aggiorna", "sposta", "muovi",
                             "rinomina", "elimina", "cancella", "cestino", "aggiungi", "sostituisci", "correggi"]
                + (english ? ["folder", "read", "summarize", "summarise", "search", "find", "content", "project", "documents", "write",
                              "create", "list", "open", "edit", "update", "move", "rename", "delete", "trash", "add", "replace", "fix"] : [])
            if fileWords.contains(where: lower.contains) || names.contains(where: lower.contains) {
                found.formUnion([Action.file_elenca, .file_leggi, .file_cerca])
                // Le azioni che modificano i file solo se la frase lo chiede davvero.
                let writes = ["crea", "scrivi", "aggiungi", "modifica", "aggiorna", "salva", "sostituisci", "correggi", "cambia", "togli", "rimuovi"]
                    + (english ? ["create", "write", " add", "edit", "update", "save", "replace", "fix", "change", "remove", "append"] : [])
                if writes.contains(where: lower.contains) { found.insert(.file_scrivi) }
                let moves = ["sposta", "muovi", "rinomina", "trasferisci"] + (english ? [" move", "rename", "transfer"] : [])
                if moves.contains(where: lower.contains) { found.insert(.file_sposta) }
                if lower.contains("cartella"), ["crea", "nuova", "nuovo"].contains(where: lower.contains) { found.insert(.file_cartella) }
                if english, lower.contains("folder"), ["create", "new", "make"].contains(where: lower.contains) { found.insert(.file_cartella) }
                let deletes = ["elimina", "cancella", "cestino", "butta"] + (english ? ["delete", "trash", "throw away", "remove the file"] : [])
                if deletes.contains(where: lower.contains) { found.insert(.file_elimina) }
            }
        }
        let artifactWords = ["aggiungi", "modifica", "riscrivi", "cambia", "togli", "rimuovi", "sezione", "slide", "riga", "righe",
                             "colonna", "correggi", "traduci", "abbrevia", "accorcia", "espandi", "migliora", "formatta", "titolo",
                             "questo", "questa", "documento", "foglio", "presentazione", "tabella", "cancella", "elimina", "svuota",
                             "scrivi", "sostituisci", "tutto", "corpo", "paragrafo", "grassetto", "corsivo", "sottolinea", "sposta",
                             "inserisci", "metti", "tieni", "lascia", "grafico", "cella", "raddoppia", "dimezza", "aumenta",
                             "diminuisci", "ordina"]
            + (english ? ["add", "edit", "rewrite", "change", "remove", "section", "row", "column", "fix", "translate", "shorten",
                          "expand", "improve", "format", "title", "this", "document", "sheet", "presentation", "table", "delete",
                          "clear", "write", "replace", "everything", "body", "paragraph", "bold", "italic", "underline", "move",
                          "insert", "put", "keep", "leave", "chart", "cell", "double", "halve", "increase", "decrease", "sort",
                          "make it", "make the", "typo"] : [])
        if work.artifactKind != nil, artifactWords.contains(where: lower.contains) {
            found.insert(.modifica_artefatto)
        }
        // Cambiamenti a eventi, promemoria, note ed email che esistono già.
        var changes = Set<Action>()
        if let action = Self.changeAction(prompt) { changes.insert(action) }
        if lower.contains("promemoria") || lower.contains("scadenz") {
            if ["cancella", "elimina", "togli", "rimuovi"].contains(where: lower.contains) { changes.insert(.elimina_promemoria) }
            if ["sposta", "rimanda", "posticipa", "anticipa", "cambia", "modifica", "rinomina", "scadenza", "importante"].contains(where: lower.contains) {
                changes.insert(.modifica_promemoria)
            }
        }
        if [" sposta", " anticipa", " posticipa", " rimanda", " rinvia", " rinomina"].contains(where: lower.contains),
           ["riunion", "evento", "appuntament", " call", "meeting", "incontr", "cena", "pranzo"].contains(where: lower.contains) {
            changes.insert(.modifica_evento)
        }
        if [" alla nota", " nella nota", " sulla nota", " nelle note"].contains(where: lower.contains) { changes.insert(.modifica_nota) }
        if [" inoltra", " inoltrala", " inoltralo"].contains(where: lower.contains) { changes.insert(.inoltra_email) }
        if english {
            if lower.contains("reminder") || lower.contains(" due ") || lower.contains("due date") {
                if ["delete", "remove", "cancel", "clear"].contains(where: lower.contains) { changes.insert(.elimina_promemoria) }
                if ["move", "postpone", "reschedule", "push", "bring forward", "change", "edit", "rename", "due date", "important", "priority"]
                    .contains(where: lower.contains) { changes.insert(.modifica_promemoria) }
                if ["mark", "done", "complete", "check off", "tick"].contains(where: lower.contains) { changes.insert(.completa_promemoria) }
            }
            if [" move", " postpone", " reschedule", " push back", " push the", " bring forward", " rename", " delay", " extend", " shorten"]
                .contains(where: lower.contains),
               ["meeting", "event", "appointment", " call", "dinner", "lunch", "breakfast", "session"].contains(where: lower.contains) {
                changes.insert(.modifica_evento)
            }
            if [" cancel", " delete", " remove"].contains(where: lower.contains),
               ["meeting", "event", "appointment", " call", "dinner", "lunch"].contains(where: lower.contains) {
                changes.insert(.elimina_evento)
            }
            if lower.range(of: #"\b(to|in|into|on)\s+(the|my)\s+[\w'\- ]{0,24}\bnote\b"#, options: .regularExpression) != nil {
                changes.insert(.modifica_nota)
            }
            if lower.contains(" forward") { changes.insert(.inoltra_email) }
            if lower.contains(" reply to") || lower.contains(" answer ") { changes.insert(.rispondi_email) }
        }
        found.formUnion(changes.intersection(available))
        if !work.mcpTools.isEmpty, mentionsExternalTool(lower) { found.insert(.strumento_esterno) }
        let pageWords = ["pagina", "sito", "articolo", "riassumi", "leggi", "cosa dice", "spiega", "traduci", "di cosa parla"]
            + (english ? ["page", "site", "article", "summarize", "summarise", "read", "what does it say", "explain", "translate", "what is it about"] : [])
        if work.browserURL != nil, pageWords.contains(where: lower.contains) {
            found.insert(.leggi_pagina)
        }
        if Web.firstURL(in: prompt) != nil { found.insert(.leggi_pagina) }
        return found
    }

    /// La richiesta riguarda un servizio collegato? Nome del server o parole dei suoi strumenti.
    func mentionsExternalTool(_ lower: String) -> Bool {
        let words = Self.meaningful(lower)
        for tool in work.mcpTools {
            if lower.contains(tool.serverName.lowercased()) || lower.contains(tool.name.lowercased()) { return true }
            let toolWords = Self.meaningful(tool.name.replacingOccurrences(of: "_", with: " ") + " " + tool.description.prefix(160))
            if !words.intersection(toolWords).isEmpty { return true }
        }
        return false
    }

    func isFollowUp(_ lower: String) -> Bool {
        let text = lower.trimmingCharacters(in: .whitespaces)
        let count = text.split(separator: " ").count
        let starts = ["e ", "invece", "anche ", "e per", "e se", "e a ", "e il ", "e la ", "e i ", "e le "]
            + (Language.isEnglish ? ["and ", "what about", "how about", "instead", "also ", "and for", "and if", "and in ", "and the "] : [])
        return count <= 6 && starts.contains { text.hasPrefix($0) }
    }

    // MARK: - Regole per web e browser

    /// Indirizzi, "cerca su internet…" e "riassumi questa pagina" non vanno lasciati al pianificatore.
    func webRules(to plan: inout Plan, prompt: String, lower: String) -> Bool {
        let english = Language.isEnglish
        if let url = Web.firstURL(in: prompt) {
            let verbs = ["apri", "vai su", "vai a", "naviga", "mostrami il sito"] + (english ? ["open", "go to", "navigate", "show me the site", "take me to"] : [])
            let browse = verbs.contains { lower.hasPrefix($0) }
            plan.action = browse ? .naviga : .leggi_pagina
            plan.fields["argomento"] = url.absoluteString
            return true
        }
        if work.webEnabled, let query = Self.explicitWebQuery(prompt) {
            plan.action = .cerca_web
            plan.fields["cerca"] = query
            return true
        }
        let pageWords = ["questa pagina", "la pagina", "pagina aperta", "in safari", "di safari", "su safari", "questo articolo", "questo sito"]
            + (english ? ["this page", "the page", "open page", "on safari", "this article", "this website", "this site"] : [])
        if pageWords.contains(where: lower.contains), !lower.hasPrefix("apri"), !(english && lower.hasPrefix("open")) {
            plan.action = .leggi_pagina
            return true
        }
        if lower.range(of: #"^(apri|mostra|vai (su|a|in))\s+(il\s+)?(browser|safari|internet)\b"#, options: .regularExpression) != nil
            || (english && lower.range(of: #"^(open|show|go to)\s+(the\s+)?(browser|safari|internet)\b"#, options: .regularExpression) != nil) {
            plan.action = .naviga
            plan.fields["argomento"] = ""
            return true
        }
        return false
    }

    /// "Cerca su internet X", "X online", "guarda sul web X" → la parte da cercare.
    static func explicitWebQuery(_ prompt: String) -> String? {
        let lower = prompt.lowercased()
        // Solo richieste esplicite: "cerca il file…" o "cerca la riunione…" restano ad altre azioni.
        var markers = [#"\b(su|in|nel|sul)\s+(internet|web|rete|google)\b"#, #"\bonline\b"#, #"^(fai una ricerca|googla)\b"#]
        if Language.isEnglish {
            markers += [#"\b(on|in)\s+(the\s+)?(internet|web|google)\b"#, #"^(search the web|search online|google|do a (web )?search)\b"#]
        }
        guard markers.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) else { return nil }
        var query = prompt
        var patterns = [#"(?i)\b(puoi |potresti |per favore )"#, #"(?i)^(cerca|cercami|trova|trovami|fai una ricerca( su)?|ricerca|guarda|controlla|verifica)\s+"#,
                        #"(?i)\b(su|in|nel|sul)\s+(internet|web|rete|google)\b"#, #"(?i)\bonline\b"#, #"(?i)^(e\s+)?(dimmi|informazioni su|info su)\s+"#]
        if Language.isEnglish {
            patterns = [#"(?i)\b(can you |could you |please )"#, #"(?i)^\s*(search the web|search online)\s+(for\s+)?"#,
                        #"(?i)^\s*(search( for)?|look up|find( me)?|google|do a (web )?search( for| on)?|check|verify)\s+"#,
                        #"(?i)\b(on|in)\s+(the\s+)?(internet|web|google)\b"#, #"(?i)\bonline\b"#, #"(?i)^\s*(and\s+)?(tell me|information about|info about|info on)\s+"#]
        }
        for pattern in patterns {
            query = query.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        query = query.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return query.count >= 2 ? query : nil
    }

    // MARK: - Esecuzione

    func handleWeb(_ plan: Plan, prompt: String, status: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        let lower = prompt.lowercased()
        switch plan.action {
        case .cerca_web:
            // Domande di seguito: il pianificatore ha il contesto per completare la ricerca.
            let query = isFollowUp(" \(lower) ") ? (plan["cerca"] ?? plan["argomento"] ?? prompt) : (plan["cerca"].flatMap { $0.split(separator: " ").count >= 2 ? $0 : nil } ?? Self.explicitWebQuery(prompt) ?? prompt)
            return try await searchWeb(query, prompt: prompt, status: status)

        case .leggi_pagina:
            let page: Web.Page
            if let url = plan["argomento"].flatMap(Web.firstURL) ?? Web.firstURL(in: prompt) {
                status(Language.t("Leggo \(url.host() ?? "la pagina")…", "Reading \(url.host() ?? "the page")…"))
                page = try await Web.fetch(url)
            } else if let text = work.browserText, let url = work.browserURL, !lower.contains("safari") {
                page = Web.Page(url: url, title: work.browserTitle ?? url, text: text)
            } else if let tab = SafariBridge.currentTab(), let url = URL(string: tab.url) {
                status(Language.t("Leggo la pagina aperta in Safari…", "Reading the page open in Safari…"))
                page = try await Web.fetch(url)
            } else {
                return .message(Language.t("Non vedo pagine aperte. Incolla l'indirizzo, oppure apri la pagina nel browser di Siri AI+ (App › Safari) o in Safari.",
                                           "I don't see any open page. Paste the address, or open the page in the Siri AI+ browser (Apps › Safari) or in Safari."))
            }
            let passages = Web.relevantPassages(page.text, query: prompt, budget: budget.scaled(2800))
            guard !passages.isEmpty else {
                return .message(Language.t("Non riesco a leggere il testo di questa pagina (forse richiede l'accesso o è fatta solo di immagini).",
                                           "I can't read the text of this page (it may require a login or be made only of images)."))
            }
            remember("Pagina «\(page.title)» (\(page.url)):\n\(passages.prefix(600))")
            let source = WebSource(title: page.title, url: page.url, snippet: String(passages.prefix(220)))
            observe("Pagina «\(page.title)» (\(page.url)):\n\(passages)")
            return .web(WebAnswer(kind: .page, query: prompt, sources: [source]), prompt: Language.isEnglish ? """
            \(preamble(for: prompt))User request: \(prompt)

            Text of the page «\(page.title)» (\(page.url)):
            \(Self.untrusted(passages, label: "web page"))

            Answer using the text of the page: summarize, explain or extract what is needed, clearly and in order. Don't make up content that isn't there.
            """ : """
            \(preamble(for: prompt))Richiesta dell'utente: \(prompt)

            Testo della pagina «\(page.title)» (\(page.url)):
            \(Self.untrusted(passages, label: "pagina web"))

            Rispondi usando il testo della pagina: riassumi, spiega o estrai quello che serve, in modo chiaro e ordinato. Non inventare contenuti che non ci sono.
            """)

        case .naviga:
            let target = plan["argomento"] ?? ""
            if lower.contains("indietro") || (Language.isEnglish && lower.contains("go back")) { return .browse(.back) }
            if let url = Web.firstURL(in: target) ?? Web.firstURL(in: prompt) ?? Self.domainURL(target) ?? Self.domainURL(prompt) {
                return .browse(.open(url))
            }
            var query = target.isEmpty ? prompt : target
            query = query.replacingOccurrences(of: #"(?i)^(apri|cerca|vai su|vai a|naviga( su)?|mostrami|mostra)\s+(il sito( di)?\s+)?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\b(nel|sul|in)\s+(browser|safari)\b"#, with: "", options: .regularExpression)
            if Language.isEnglish {
                query = query.replacingOccurrences(of: #"(?i)^(open|search( for)?|go to|navigate( to)?|show me)\s+(the\s+)?((web)?site( of)?\s+)?"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)\b(in|on)\s+(the\s+)?(browser|safari)\b"#, with: "", options: .regularExpression)
            }
            query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return .browse(.search(query))

        case .segui_link:
            let link = plan["link"] ?? work.browserLinks.first { lower.contains($0.lowercased()) }
            guard let link else { return .message(Language.t("Quale link vuoi aprire? Dimmi il testo del link.", "Which link do you want to open? Tell me the link text.")) }
            return .browse(.follow(link))

        default:
            return .reply(prompt: withContext(prompt))
        }
    }

    /// Cerca sul web, legge le prime pagine e prepara il prompt per una risposta con le fonti numerate.
    public func searchWeb(_ query: String, prompt: String, status: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        guard work.webEnabled else {
            return .message(Language.t("La ricerca sul web è disattivata: puoi attivarla in Attività e privacy.",
                                       "Web search is turned off: you can turn it on in Activity & Privacy."))
        }
        webSearches += 1
        guard webSearches <= RequestLimits.webSearches else {
            return .message(Language.t("Ho già fatto parecchie ricerche per questa richiesta: dimmi su cosa approfondire.",
                                       "I've already done several searches for this request: tell me what to dig into."))
        }
        status(Language.t("Cerco sul web «\(query.prefix(60))»…", "Searching the web for «\(query.prefix(60))»…"))
        let results = try await Web.search(query, limit: 6)
        status(Language.t("Leggo le fonti…", "Reading the sources…"))
        // Con una finestra più grande si leggono più pagine e più testo per pagina.
        let pagesToRead = budget.scale >= 4 ? 5 : budget.scale >= 2 ? 4 : 3
        let readable = results.filter { !$0.url.lowercased().hasSuffix(".pdf") && !$0.url.contains("youtube.com") }.prefix(pagesToRead)
        let pages = await withTaskGroup(of: (String, Web.Page?).self) { group in
            for source in readable {
                group.addTask { (source.url, try? await Web.fetch(URL(string: source.url)!, maxChars: 30_000)) }
            }
            var map: [String: Web.Page] = [:]
            for await (url, page) in group { if let page { map[url] = page } }
            return map
        }
        var blocks: [String] = []
        for (index, source) in results.prefix(5).enumerated() {
            var body = source.snippet
            if let page = pages[source.url] {
                let passages = Web.relevantPassages(page.text, query: "\(query) \(prompt)", budget: budget.scaled(750))
                if passages.count > body.count { body = passages }
            }
            blocks.append("[\(index + 1)] \(source.title) — \(source.domain)\n\(body.prefix(budget.scaled(900)))")
        }
        remember("Ricerca web «\(query)»: " + results.prefix(4).map(\.title).joined(separator: "; "))
        let answer = WebAnswer(kind: .search, query: query, sources: Array(results.prefix(5)))
        observe("Ricerca web «\(query)»:\n" + blocks.joined(separator: "\n\n"))
        return .web(answer, prompt: Language.isEnglish ? """
        \(preamble(for: prompt))User question: \(prompt)

        Results from the web (search «\(query)», \(Dates.format(.now, time: false))):
        \(Self.untrusted(blocks.joined(separator: "\n\n"), label: "web results"))

        Answer completely, precisely and in a well organized way based on these sources, in English. Mark the sources you use with [1], [2]… \
        If the sources are not enough or disagree, say so. Don't make up data that isn't there. Don't list the sources at the end: they are already shown below the answer.\(formatHint)
        """ : """
        \(preamble(for: prompt))Domanda dell'utente: \(prompt)

        Risultati dal web (ricerca «\(query)», \(Dates.format(.now, time: false))):
        \(Self.untrusted(blocks.joined(separator: "\n\n"), label: "risultati del web"))

        Rispondi in modo completo, preciso e ben organizzato basandoti su queste fonti. Indica le fonti usate con [1], [2]… \
        Se le fonti non bastano o sono in disaccordo, dillo. Non inventare dati che non ci sono. Non elencare le fonti alla fine: sono già mostrate sotto la risposta.\(formatHint)
        """)
    }

    /// "apri repubblica.it" → https://repubblica.it
    static func domainURL(_ text: String) -> URL? {
        guard let match = text.lowercased().range(of: #"\b([a-z0-9-]+\.)+(it|com|org|net|eu|io|dev|app|info|ai|co|uk|de|fr|es|ch|tv|me)\b(/\S*)?"#, options: .regularExpression) else { return nil }
        return URL(string: "https://\(text.lowercased()[match])")
    }

    /// La risposta ammette di non sapere o di non essere aggiornata: conviene cercare sul web.
    nonisolated public static func soundsUnsure(_ reply: String) -> Bool {
        let lower = reply.lowercased().prefix(500)
        // Solo ammissioni esplicite di non sapere: frasi generiche ("ti consiglio di consultare") comparivano anche in risposte utili.
        let phrases = ["non ho informazioni aggiornate", "non ho accesso a internet", "non posso accedere a internet", "non posso navigare",
                       "non ho accesso a informazioni in tempo reale", "non ho accesso a dati in tempo reale", "non dispongo di informazioni",
                       "non ho informazioni su", "non sono in grado di fornire informazioni aggiornate", "le mie conoscenze si fermano",
                       "la mia conoscenza si ferma", "fino al mio ultimo aggiornamento", "non posso fornire informazioni su eventi",
                       "non ho accesso a dati aggiornati", "non posso verificare informazioni recenti", "non conosco i dettagli",
                       "non ho dati aggiornati", "non conosco con certezza", "non ne sono sicur", "non so con certezza",
                       // In inglese.
                       "i don't have up-to-date", "i do not have up-to-date", "i don't have access to the internet", "i can't browse",
                       "i cannot browse", "i don't have real-time", "i do not have real-time", "i don't have access to real-time",
                       "my knowledge cutoff", "as of my last update", "my training data", "i don't have current information",
                       "i do not have current information", "i'm not able to provide current", "i am not able to provide current",
                       "i don't have information about", "i'm not sure about", "i am not sure about", "i don't know for sure"]
        return phrases.contains { lower.contains($0) }
    }
}
