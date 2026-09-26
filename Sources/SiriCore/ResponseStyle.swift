import Foundation
import FoundationModels

/// Che tipo di risposta serve: decide la temperatura e, per confronti, procedure e pro/contro, uno schema che ne fissa
/// la forma (tabella, passi numerati, due elenchi). Il modello piccolo con testo libero sbaglia spesso il formato.
public enum ResponseStyle: String, Sendable {
    /// Saluti, chiacchiere, consigli.
    case conversation
    /// Fatti, definizioni, conti, spiegazioni tecniche: poca fantasia.
    case factual
    /// Poesie, storie, slogan, idee, nomi.
    case creative
    /// Confronto tra opzioni → tabella.
    case comparison
    /// Procedura → passi numerati.
    case steps
    /// Pro e contro → due elenchi.
    case prosCons

    public static func detect(_ prompt: String) -> ResponseStyle {
        let lower = " " + prompt.lowercased() + " "
        let creative = ["poesia", "poesie", "racconto", "raccontami una storia", "una storia su", "una storia per", "favola", "filastrocca",
                        "canzone", "slogan", "battuta", "barzelletta", "rima", "haiku", "idee per", "idee di", "nomi per", "un nome per",
                        "inventa", "immagina", "augurio", "auguri", "brainstorming", "motto", "titoli per", "frase ad effetto", "dedica"]
        if creative.contains(where: lower.contains) { return .creative }
        if ["pro e contro", "vantaggi e svantaggi", "pregi e difetti", "punti di forza e di debolezza"].contains(where: lower.contains) { return .prosCons }
        let comparison = ["confronta", "confronto tra", "confronto fra", "paragona", "differenza tra", "differenze tra", "differenza fra",
                          "differenze fra", "meglio tra", "meglio fra", " vs ", " vs. ", " versus ", "tabella comparativa", "mettere a confronto"]
        if comparison.contains(where: lower.contains) { return .comparison }
        let steps = ["passaggi per", "i passaggi", "passi per", "come si fa a", "come faccio a", "come si fa per", "procedura per",
                     "istruzioni per", "guida per", "passo passo", "step by step", "come si rinnova", "come rinnovare", "come richiedere",
                     "come si richiede", "come attivare", "come installare", "come configurare", "come si prepara", "la ricetta",
                     "ricetta per", "ricetta di", "ricetta del", "ricetta della", "ricetta dei", "ricetta delle"]
        if steps.contains(where: lower.contains) { return .steps }
        let questions = [" chi ", " cosa ", " che cos", " cos'è", " quando ", " dove ", " quale ", " quali ", " quanto ", " quanti ",
                         " quante ", " in che anno", " perché ", " come funziona", " spiegami", " spiega ", " qual è", " quant'è"]
        if questions.contains(where: { lower.hasPrefix($0) || lower.contains($0) }) || lower.range(of: #"\d"#, options: .regularExpression) != nil {
            return .factual
        }
        return .conversation
    }

    /// Temperatura: bassa dove conta l'esattezza, alta solo per i testi creativi.
    public var temperature: Double {
        switch self {
        case .factual: 0.2
        case .comparison, .steps, .prosCons: 0.3
        case .conversation: 0.6
        case .creative: 0.9
        }
    }

    /// Indicazione di formato per i modelli che scrivono testo libero (Gemma, ChatGPT, Claude).
    public var hint: String? {
        switch self {
        case .comparison: "Rispondi con una tabella Markdown (una colonna per ogni opzione, una riga per ogni aspetto) e una conclusione breve."
        case .steps: "Rispondi con un elenco numerato di passi brevi e concreti."
        case .prosCons: "Rispondi con due elenchi puntati, «Pro» e «Contro», e una conclusione breve."
        default: nil
        }
    }

    /// Schema della generazione guidata con Apple Intelligence (nil = testo libero).
    var schema: GenerationSchema? {
        switch self {
        case .comparison: Self.comparisonSchema
        case .steps: Self.stepsSchema
        case .prosCons: Self.prosConsSchema
        default: nil
        }
    }

    private static let comparisonSchema = makeSchema("Confronto", [
        .required("introduzione", .string, "Una frase che introduce il confronto"),
        .required("opzioni", .array(.string, min: 2, max: 4), "Le cose confrontate, con nomi brevi"),
        .required("aspetti", .array(.object("Aspetto", [
            .required("aspetto", .string, "Aspetto confrontato, per esempio «Tempi» o «Costi»"),
            .required("valori", .array(.string, min: 2, max: 4), "Un valore breve per ogni opzione, nello stesso ordine delle opzioni"),
        ]), min: 3, max: 7), "Aspetti confrontati, uno per riga della tabella"),
        .required("conclusione", .string, "Quando conviene l'una o l'altra opzione, in una o due frasi"),
    ])

    private static let stepsSchema = makeSchema("Procedura", [
        .required("introduzione", .string, "Una frase introduttiva"),
        .required("passi", .array(.object("Passo", [
            .required("titolo", .string, "L'azione da fare, breve"),
            .required("dettaglio", .string, "Come farla, in una o due frasi"),
        ]), min: 3, max: 10), "Passi nell'ordine in cui vanno fatti"),
        .optional("consiglio", .string, "Un consiglio finale o cosa tenere pronto, se utile"),
    ])

    private static let prosConsSchema = makeSchema("ProContro", [
        .required("introduzione", .string, "Una frase introduttiva"),
        .required("pro", .array(.string, min: 3, max: 6), "Vantaggi, uno per voce, brevi"),
        .required("contro", .array(.string, min: 3, max: 6), "Svantaggi, uno per voce, brevi"),
        .required("conclusione", .string, "Una conclusione equilibrata in una o due frasi"),
    ])

    /// Dal contenuto guidato (anche parziale, durante lo streaming) al Markdown mostrato in chat.
    func markdown(_ content: GeneratedContent) -> String {
        func text(_ key: String, in item: GeneratedContent = content) -> String {
            ((try? item.value(String.self, forProperty: key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func list(_ key: String, in item: GeneratedContent = content) -> [String] {
            ((try? item.value([String].self, forProperty: key)) ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        func objects(_ key: String) -> [GeneratedContent] { (try? content.value([GeneratedContent].self, forProperty: key)) ?? [] }
        func cell(_ value: String) -> String { value.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }
        var parts: [String] = []
        let intro = text("introduzione")
        if !intro.isEmpty { parts.append(intro) }
        switch self {
        case .comparison:
            let options = list("opzioni")
            let rows = objects("aspetti")
            if options.count >= 2 {
                var table = ["| | " + options.map(cell).joined(separator: " | ") + " |", "| --- |" + String(repeating: " --- |", count: options.count)]
                for row in rows {
                    let name = text("aspetto", in: row)
                    guard !name.isEmpty else { continue }
                    var values = list("valori", in: row).map(cell)
                    values += Array(repeating: "", count: max(0, options.count - values.count))
                    table.append("| **\(cell(name))** | " + values.prefix(options.count).joined(separator: " | ") + " |")
                }
                parts.append(table.joined(separator: "\n"))
            }
            let end = text("conclusione")
            if !end.isEmpty { parts.append(end) }
        case .steps:
            let steps = objects("passi").enumerated().compactMap { index, step -> String? in
                let title = text("titolo", in: step), detail = text("dettaglio", in: step)
                guard !title.isEmpty else { return nil }
                return "\(index + 1). **\(title)**" + (detail.isEmpty ? "" : " — \(detail)")
            }
            if !steps.isEmpty { parts.append(steps.joined(separator: "\n")) }
            let tip = text("consiglio")
            if !tip.isEmpty { parts.append("**Consiglio:** \(tip)") }
        case .prosCons:
            let pro = list("pro"), contro = list("contro")
            if !pro.isEmpty { parts.append("**Pro**\n" + pro.map { "- \($0)" }.joined(separator: "\n")) }
            if !contro.isEmpty { parts.append("**Contro**\n" + contro.map { "- \($0)" }.joined(separator: "\n")) }
            let end = text("conclusione")
            if !end.isEmpty { parts.append(end) }
        default:
            break
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Temi in cui una risposta sbagliata fa danni: si risponde con le fonti e si ricorda di sentire un professionista.
public enum RiskyDomain: String, Sendable {
    case health, law, money

    public static func detect(_ prompt: String) -> RiskyDomain? {
        let lower = " " + prompt.lowercased() + " "
        let health = ["farmac", "medicin", " dose", "dosaggio", "sintom", "malatti", "terapia", "diagnos", "pressione alta", "febbre",
                      "antibiotic", "paracetamolo", "ibuprofene", "tachipirina", "aspirina", "vaccin", "gravidanz", "allergi", "mal di ",
                      "infiammazion", "effetti collaterali", "posso prendere", "integratore", "colesterolo", "diabete", "glicemia", "ansia",
                      "insonnia", "pediatra", "ricetta medica"]
        if health.contains(where: lower.contains) { return .health }
        let law = [" legge", "legale", "contratto", "avvocato", " multa", "sanzion", "ricorso", " diritto ", " diritti ", "licenziament",
                   " tfr", "periodo di prova", "eredità", "testamento", "sfratto", "condominio", "codice civile", "codice della strada",
                   "denuncia", "querela", "preavviso", "tribunale", "divorzio", "separazione", "gdpr", "patente", "punti della patente"]
        if law.contains(where: lower.contains) { return .law }
        let money = ["mutuo", "mutui", " tasso", " taeg", " tan ", "prestito", "finanziament", "investire", "investiment", " azioni ",
                     "obbligazion", " etf", " btp", "fondo pensione", "pensione", " tasse", " tassa ", "irpef", " iva ", "imposta", "detrazion",
                     "deduzion", " 730", " isee", "partita iva", "forfettari", "contributi", " inps", " f24", "assicurazion", "spread",
                     "inflazione", "criptovalut", "bitcoin", "estratto conto", "bonifico"]
        if money.contains(where: lower.contains) { return .money }
        return nil
    }

    /// Una frase per la risposta: chi sentire per il proprio caso.
    public var advice: String {
        switch self {
        case .health: "Tema di salute: chiudi con una frase che ricorda di chiedere al medico o al farmacista per il proprio caso."
        case .law: "Tema legale: chiudi con una frase che ricorda di verificare il proprio caso con un professionista (avvocato, consulente del lavoro, CAF)."
        case .money: "Tema di soldi: chiudi con una frase che ricorda di verificare le condizioni del proprio caso con la banca o un consulente."
        }
    }
}

extension Assistant {
    /// La richiesta chiede di fare qualcosa (evento, promemoria, email, file…) oltre a rispondere.
    public func asksForAction(_ prompt: String) -> Bool {
        !candidateActions(for: Self.withoutQuotes(prompt)).subtracting([.genera_immagine, .cerca_web]).isEmpty
    }

    /// Descrizione fedele di un'immagine (testo trascritto, numeri, date, luoghi): la usano il pianificatore, gli strumenti
    /// e i modelli che non vedono le immagini. nil se il modello non sa leggere le immagini o non ci riesce.
    public func describeImage(_ url: URL) async -> String? {
        guard Agent.model.capabilities.contains(.vision) else { return nil }
        let session = LanguageModelSession(model: Agent.model, instructions: """
        Descrivi con precisione il contenuto dell'immagine, in italiano: trascrivi il testo visibile (titoli, cifre, date, orari, indirizzi),         poi le persone, gli oggetti o la scena principali. Non inventare ciò che non si vede. Massimo 10 righe.
        """)
        do {
            let text = try await session.respond(options: GenerationOptions(temperature: 0.1)) {
                "Descrivi questa immagine."
                Attachment(imageURL: url)
            }.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(1500))
        } catch {
            Agent.log("IMMAGINE NON LETTA «\(url.lastPathComponent)»: \(error)")
            return nil
        }
    }

    /// Scrive la risposta (Apple Intelligence) con le opzioni del tipo di richiesta. Confronti, procedure e pro/contro
    /// usano la generazione guidata e arrivano già in Markdown; `onUpdate` riceve il testo man mano che cresce.
    public func answer(_ prompt: String, onUpdate: (String) -> Void = { _ in }) async throws -> String {
        let options = responseOptions
        let reasoning: ContextOptions.ReasoningLevel? = appleResponseModel == .privateCloud && responseStyle != .creative
            ? .moderate : nil
        // Le citazioni [1], [2] hanno senso solo se nella richiesta ci sono fonti numerate.
        let citations = prompt.range(of: #"(?m)^\[\d{1,2}\] "#, options: .regularExpression) != nil
        // Immagini allegate: il modello le guarda insieme al testo (solo se sa leggere le immagini).
        let images = Agent.model.capabilities.contains(.vision) ? Array(work.images.prefix(4)) : []
        imagesInSession += images.count
        let request = Prompt {
            prompt
            for url in images { Attachment(imageURL: url) }
        }
        if let schema = responseStyle.schema {
            do {
                var final = ""
                for try await snapshot in chat.streamResponse(schema: schema, options: options,
                                                              contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: reasoning),
                                                              prompt: { request }) {
                    let text = Self.cleanAnswer(responseStyle.markdown(snapshot.content), citations: citations)
                    guard !text.isEmpty else { continue }
                    final = text
                    onUpdate(text)
                }
                if !final.isEmpty { return final }
            } catch let error as LanguageModelError {
                switch error {
                case .contextSizeExceeded, .refusal: throw error
                default: Agent.log("RISPOSTA GUIDATA NON RIUSCITA (\(responseStyle.rawValue)): \(error)")
                }
            } catch let error as LanguageModelSession.GenerationError {
                // Finestra piena e rifiuti valgono anche per il testo libero: li gestisce chi chiama.
                // Il filtro di sicurezza a volte scatta sulla forma guidata e non sul testo libero: si riprova così
                // (e il testo libero, se scatta ancora, riprova con la sola domanda).
                switch error {
                case .exceededContextWindowSize, .refusal: throw error
                default: Agent.log("RISPOSTA GUIDATA NON RIUSCITA (\(responseStyle.rawValue)): \(error)")
                }
            }
        }
        var final = ""
        do {
            for try await snapshot in chat.streamResponse(options: options,
                                                          contextOptions: ContextOptions(reasoningLevel: reasoning),
                                                          prompt: { request }) {
                let text = Self.cleanAnswer(snapshot.content, citations: citations)
                guard !text.isEmpty else { continue }
                final = text
                onUpdate(text)
            }
        } catch where Self.isGuardrail(error) && appleResponseModel == .onDevice && final.isEmpty {
            // Il filtro di Apple scatta anche su richieste innocue («i passaggi per rinnovare la carta d'identità», degli auguri
            // resi più formali) a seconda di come sono composte istruzioni, cronologia e testo generato: con istruzioni essenziali
            // le stesse richieste passano (provato). Prima la richiesta intera (con i suoi dati), poi la sola domanda.
            // Su macOS 27 l'errore arriva come `LanguageModelError` invece di `GenerationError`.
            Agent.log("FILTRO DI SICUREZZA: riprovo con istruzioni essenziali")
            let question = (lastRequest.isEmpty ? prompt : lastRequest) + formatHint
            var blocked: Error = error
            for text in question == prompt ? [prompt] : [prompt, question] where final.isEmpty {
                chat = LanguageModelSession(model: Agent.model, instructions: Self.plainInstructions)
                do {
                    for try await snapshot in chat.streamResponse(to: text, options: GenerationOptions(temperature: 0.2)) {
                        let clean = Self.cleanAnswer(snapshot.content, citations: citations)
                        guard !clean.isEmpty else { continue }
                        final = clean
                        onUpdate(clean)
                    }
                } catch where Self.isGuardrail(error) {
                    blocked = error
                }
            }
            if final.isEmpty { throw blocked }
        }
        // Il modello piccolo a volte ignora o ricopia male un risultato calcolato: una seconda stesura con il risultato imposto.
        if let missing = missingResult(in: final) {
            Agent.log("RISULTATO NON USATO (\(missing)): riscrivo la risposta")
            var retry = ""
            let fix = "Nella risposta precedente il risultato non era quello esatto. Riscrivi la risposta alla stessa domanda usando esattamente questo risultato: \(missing). Non rifare i conti."
            for try await snapshot in chat.streamResponse(to: fix, options: GenerationOptions(temperature: 0.1)) {
                let text = Self.cleanAnswer(snapshot.content, citations: citations)
                guard !text.isEmpty else { continue }
                retry = text
                onUpdate(text)
            }
            if !retry.isEmpty { final = retry }
        }
        return final
    }

    /// Istruzioni essenziali per il secondo tentativo dopo il filtro di sicurezza.
    static var plainInstructions: String {
        "Sei Siri AI+, l'assistente di Ivan sul Mac. Adesso è \(Dates.format(.now)). Rispondi in italiano, in modo chiaro e utile."
    }

    /// Il filtro di sicurezza di Apple, con il tipo di errore vecchio o con quello di macOS 27.
    nonisolated static func isGuardrail(_ error: Error) -> Bool {
        if case LanguageModelSession.GenerationError.guardrailViolation = error { return true }
        if let error = error as? LanguageModelError, case .guardrailViolation = error { return true }
        return false
    }

    /// Risultato di un conto dell'app ("… = 204", "… = 22 ore e 55 minuti") che la risposta non riporta (o che rifiuta di dare).
    func missingResult(in answer: String) -> String? {
        let results = turnFacts.compactMap { fact -> String? in
            guard let range = fact.range(of: " = ", options: .backwards) else { return nil }
            return String(fact[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }
        guard let result = results.last else { return nil }
        // Si confrontano i numeri (6300 e 6.300 sono lo stesso numero; "22 ore e 55 minuti" → 22 e 55).
        let digits = { (text: String) in text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "") }
        let numbers = Calculations.matches(#"\d+(?:,\d+)?"#, in: digits(result)).map(\.[0])
        let answerDigits = digits(answer)
        if Self.soundsUnsure(answer) || !numbers.allSatisfy({ answerDigits.contains($0) }) { return result }
        return nil
    }
}
