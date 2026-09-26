import Foundation
import FoundationModels

extension Assistant {
    // MARK: - Coerenza con la conversazione

    /// Registra lo scambio appena mostrato (la risposta vera, non il prompt con i dati) e i dati letti per rispondere.
    public func record(user: String, reply: String) {
        let data = lastObservation.map { String($0.prefix(1500)) }
        turns.append(ChatTurn(role: .user, text: String(user.prefix(1500)), data: data))
        turns.append(ChatTurn(role: .assistant, text: String(reply.prefix(12_000))))
        if turns.count > 80 {
            let removed = turns.count - 80
            turns.removeFirst(removed)
            summarizedCount = max(0, summarizedCount - removed)
        }
    }

    /// Riprende una conversazione salvata: gli scambi tornano la cronologia della chat, come se non fosse mai stata chiusa.
    public func restore(_ previous: [ChatTurn]) {
        turns = Array(previous.suffix(80))
        summarizedCount = 0
        chat = makeChat()
    }

    /// Scambi non ancora riassunti: la cronologia per i modelli esterni (il resto è nel riassunto delle istruzioni).
    public var historyTurns: [ChatTurn] { Array(turns[min(summarizedCount, turns.count)...]) }

    /// Gli ultimi scambi, accorciati, per chi deve capire i riferimenti (riformulazioni, ragionamento).
    func recentConversation(exchanges count: Int = 3, user: Int = 300, reply: Int = 500) -> String? {
        let recent = ConversationMemory.exchanges(turns).suffix(count).map { exchange in
            ConversationMemory.Exchange(user: ConversationMemory.excerpt(exchange.user, limit: user),
                                        reply: ConversationMemory.excerpt(exchange.reply, limit: reply), index: exchange.index)
        }
        return recent.isEmpty ? nil : ConversationMemory.lines(Array(recent))
    }

    private static let standaloneSchema = makeSchema("Riformulazione", [
        .required("richiesta", .string, "La richiesta dell'ultimo messaggio resa autonoma e completa, con i riferimenti risolti. Se è già chiara da sola, ricopiala identica"),
    ])

    /// Rende autonoma una richiesta che dipende da ciò che si è detto prima ("e lui?", "rendilo più corto", "e domani?").
    func standalone(_ prompt: String) async -> String {
        guard !turns.isEmpty, Self.dependsOnConversation(prompt) else { return prompt }
        let session = LanguageModelSession(model: Agent.model, instructions: """
        Riscrivi l'ultimo messaggio dell'utente in modo che si capisca da solo, sostituendo pronomi e riferimenti con ciò a cui si riferiscono nella conversazione \
        e riportando i nomi e i numeri che servono. Non rispondere alla domanda e non metterci le risposte dell'assistente: prendi \
        dalla conversazione solo ciò a cui il messaggio si riferisce. Mantieni la lingua italiana e la stessa forma (domanda o richiesta).
        Esempi:
        - Conversazione: «Ivan: chi è il presidente della Francia? / Siri AI+: Emmanuel Macron.» Ultimo messaggio: «e quanti anni ha?» → «Quanti anni ha Emmanuel Macron?»
        - Conversazione: «Ivan: qual è la capitale del Portogallo? / Siri AI+: Lisbona.» Ultimo messaggio: «e quella della Spagna?» → «Qual è la capitale della Spagna?»
        - Conversazione: «Ivan: scrivimi un'email per Marco sul preventivo / Siri AI+: Ecco la bozza…» Ultimo messaggio: «rendila più corta» → «Rendi più corta l'email per Marco sul preventivo»
        - Conversazione: «Ivan: che tempo fa a Milano domani?» Ultimo messaggio: «e a Roma?» → «Che tempo fa a Roma domani?»
        - Conversazione: «Ivan: elencami i tre laghi più grandi d'Italia / Siri AI+: 1. Garda 2. Maggiore 3. Como» Ultimo messaggio: «quanto è profondo il secondo?» → «Quanto è profondo il Lago Maggiore?»
        - Conversazione: «Ivan: ho comprato 3 libri da 12 euro.» Ultimo messaggio: «quanto ho speso in tutto?» → «Quanto ho speso in tutto per 3 libri da 12 euro?»
        """)
        let conversation = recentConversation() ?? ""
        guard let rewritten = try? await session.respond(to: "Conversazione:\n\(conversation)\n\nUltimo messaggio: \(prompt)", schema: Self.standaloneSchema,
                                                          options: GenerationOptions(samplingMode: .greedy)).content.string("richiesta"),
              !rewritten.isEmpty, rewritten.count < prompt.count * 6 + 200 else { return prompt }
        // I numeri possono venire da ciò che ha detto Ivan, non dai risultati delle risposte («con un incremento di 3.500»):
        // rimessi nella domanda, i conti li conterebbero due volte.
        let ivan = prompt + " " + ConversationMemory.exchanges(turns).suffix(4).map(\.user).joined(separator: " ")
        let spelled = ivan.lowercased().split { !$0.isLetter }.compactMap { Calculations.smallNumbers[String($0)] }.map(Double.init)
        let said = Set(Calculations.numbers(in: ivan) + spelled)
        if Calculations.numbers(in: rewritten).contains(where: { value in !said.contains { abs($0 - value) < 1e-9 } }) {
            Agent.log("RIFORMULAZIONE SCARTATA (numeri presi dalle risposte): \(rewritten)")
            return prompt
        }
        // Deve conservare le parole importanti del messaggio originale.
        let original = MemoryStore.keywords(prompt)
        let kept = original.intersection(MemoryStore.keywords(rewritten)).count
        // Senza parole importanti ("e lui?") la riscrittura deve restare una domanda breve, non una risposta.
        if original.isEmpty { return rewritten.count <= 160 ? rewritten : prompt }
        guard Double(kept) / Double(original.count) >= 0.5 else { return prompt }
        return rewritten
    }

    /// Il messaggio si capisce solo con quelli di prima: pronomi e dimostrativi («lui», «quella»), verbi con il pronome
    /// attaccato («rendilo», «fanne»), riferimenti a un elenco («il secondo», «in tutto») o frammenti brevi senza soggetto
    /// («In che anno è nato?», «Quante once sono?», «Ora in spagnolo»). Saluti e ringraziamenti no.
    nonisolated static func dependsOnConversation(_ prompt: String) -> Bool {
        let lower = " \(prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) "
        let words = lower.split(separator: " ").count
        guard words <= 14 else { return false }
        if lower.range(of: #"^ (ciao|grazie|ok|okay|perfetto|va bene|buongiorno|buonasera|buonanotte|salve|sì|si|no|bene|ottimo)\b[\s!.,]*$"#,
                       options: .regularExpression) != nil { return false }
        let strong = [" lui ", " lei ", " loro ", " esso ", " essa ", " questo ", " questa ", " quello ", " quella ", " quelli ", " quelle ",
                      " stesso ", " stessa ", "fallo", "falla", "rendilo", "rendila", "rifallo", "rifalla", "riscrivilo", "riscrivila",
                      "traducilo", "traducila", "spiegalo", "spiegala", "mandalo", "mandala", "approfondisci", "continua",
                      "e se ", "e per ", "e a ", "e poi", "di più", "più corto", "più corta", "più lungo", "più lunga",
                      " il primo", " la prima", " il secondo", " la seconda", " il terzo", " la terza", " l'ultimo", " l'ultima",
                      "quest'ultim", "suddett", "di prima", "in tutto", "in totale", " entrambi", " entrambe", " tutti e ", " tutte e ",
                      "fanne", "dammene", "dimmene", "parlamene", "fammene", "spiegamelo", "spiegamela", "scrivimelo", "scrivimela",
                      "accorcialo", "accorciala", "allungalo", "allungala", "correggilo", "correggila", "semplificalo", "semplificala",
                      "riassumilo", "riassumila", "ripetilo", "ripetila"]
        if strong.contains(where: lower.contains) { return true }
        let trimmed = lower.trimmingCharacters(in: .whitespaces)
        if words <= 5, ["e ", "ma ", "ora ", "adesso ", "invece "].contains(where: trimmed.hasPrefix) { return true }
        // Messaggi brevi senza un argomento proprio (nessun nome, numero o parola che non sia generica): parole ambigue
        // («la», «ne», «anche») o domande di poche parole («In che anno è nato?», «Entro quando?»).
        guard words <= 6 else { return false }
        let hasName = prompt.split(separator: " ").dropFirst().contains { $0.first?.isUppercase == true }
        let hasNumber = prompt.contains { $0.isNumber }
        let topic = significant(MemoryStore.keywords(prompt)).filter { !Self.genericQuestionWords.contains($0) }
        guard !hasName, !hasNumber, topic.count <= 1 else { return false }
        let weak = [" lo ", " la ", " li ", " gli ", " ne ", " ci ", " sopra ", " prima ", " anche ", " invece ", " allora ", " altro ", " altri "]
        return weak.contains(where: lower.contains) || trimmed.hasSuffix("?") || words <= 3
    }

    /// «Il secondo», «la terza», «l'ultimo» riferiti all'elenco appena scritto (da Ivan o nella risposta): l'app risolve
    /// il riferimento e lo scrive accanto («scelgo il secondo (Pepe)»), così il modello non deve contare.
    func resolvingOrdinals(_ prompt: String) -> String {
        guard let regex = Self.ordinalRegex else { return prompt }
        let ns = prompt as NSString
        let found = regex.matches(in: prompt, range: NSRange(location: 0, length: ns.length))
        guard !found.isEmpty, let items = recentList() else { return prompt }
        var result = prompt as NSString
        for match in found.reversed() {
            let word = ns.substring(with: match.range(at: 1)).lowercased()
            guard let position = Self.ordinalPosition(word, count: items.count), items.indices.contains(position) else { continue }
            result = result.replacingCharacters(in: NSRange(location: NSMaxRange(match.range(at: 1)), length: 0), with: " (\(items[position]))") as NSString
        }
        if result as String != prompt { Agent.log("ELENCO: \(result)") }
        return result as String
    }

    /// Un ordinale usato come pronome («il secondo», «sulla terza»), non come aggettivo («il primo giorno», «secondo me»).
    nonisolated static let ordinalRegex = try? NSRegularExpression(pattern: #"(?i)(?:\b(?:il|la|lo|i|le|gli|al|alla|allo|del|della|dello|sul|sulla|sullo|nel|nella|nello|dal|dalla|dallo|col)\s+|\bl['’]\s*)(prim[oa]|second[oa]|terz[oa]|quart[oa]|quint[oa]|ultim[oa]|penultim[oa])(?=\s*(?:[?.!,;:]|$)|\s+(?:e|è|che|di|del|della|dei|delle|in|per|mi|ti|ci|lo|la|non|ha|era|sarà|costa|dura|mi)\b)"#)

    nonisolated static func ordinalPosition(_ word: String, count: Int) -> Int? {
        switch word.prefix(4) {
        case "prim": 0
        case "seco": 1
        case "terz": 2
        case "quar": 3
        case "quin": 4
        case "ulti": count - 1
        case "penu": count - 2
        default: nil
        }
    }

    /// L'elenco più recente della conversazione: righe numerate o puntate di una risposta, oppure «A, B e C» scritto da Ivan.
    func recentList() -> [String]? {
        for exchange in ConversationMemory.exchanges(turns).suffix(2).reversed() {
            if let items = Self.listItems(in: exchange.reply) ?? Self.inlineItems(in: exchange.user) { return items }
        }
        return nil
    }

    nonisolated static func listItems(in text: String) -> [String]? {
        let items = text.components(separatedBy: "\n").compactMap { line -> String? in
            guard let match = Calculations.matches(#"^\s*(?:\d{1,2}[.)]|[-•*])\s+(.+)$"#, in: line).first else { return nil }
            var item = match[1].replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            // «Po – il fiume più lungo…», «Garda: …»: basta il nome.
            if let cut = item.range(of: #"\s+[–—-]\s+|:\s|\s\(|,\s"#, options: .regularExpression) { item = String(item[..<cut.lowerBound]) }
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: " .;,"))
            return item.isEmpty || item.count > 80 ? nil : item
        }
        return (2...12).contains(items.count) ? items : nil
    }

    /// «tre opzioni: Orvieto, Tivoli e Sperlonga», «i nomi: Rocco, Pepe e Brio» (voci brevi, dopo i due punti se la frase è lunga).
    nonisolated static func inlineItems(in text: String) -> [String]? {
        let tail = text.range(of: ":").map { String(text[$0.upperBound...]) } ?? text
        guard let match = Calculations.matches(#"([^,.;:!?]{1,40}(?:,\s*[^,.;:!?]{1,40})+)\s+(?:e|o|oppure)\s+([^,.;:!?]{1,40})"#, in: tail).first else { return nil }
        let items = (match[1].components(separatedBy: ",") + [match[2]]).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (2...8).contains(items.count), items.allSatisfy({ !$0.isEmpty && $0.split(separator: " ").count <= 3 }) else { return nil }
        return items
    }

    /// Parole che nelle domande brevi non indicano l'argomento («In che anno è nato?», «Quanto costa?», «Entro quando?»).
    nonisolated static let genericQuestionWords: Set<String> = ["anno", "nato", "nata", "nati", "morto", "morta", "costa", "costano", "dura",
        "durano", "lungo", "lunga", "alto", "alta", "grande", "piccolo", "vecchio", "giorno", "entro", "vale", "valgono", "serve", "servono",
        "significa", "funziona", "succede", "chiama", "chiamava", "trova", "abita", "vive", "viveva", "aumenta", "diminuisce", "resta",
        "restano", "manca", "mancano", "totale", "tutto", "tutti", "once", "grammi", "euro", "metri", "chili", "litri", "persone"]

    private static let memorySchema = makeSchema("Ricordi", [
        .required("fatti", .array(.string, max: 2), "Solo preferenze, abitudini o fatti personali che l'utente dichiara esplicitamente in questo messaggio, scritti in terza persona («Ivan preferisce…»). Lista vuota se non ce ne sono: mai richieste, domande o compiti"),
    ])

    /// Frasi che di solito contengono una preferenza o un fatto personale da ricordare.
    public static func mayContainMemory(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let cues = ["preferisco", "non mi piace", "mi piace", "odio ", "d'ora in poi", "da ora in poi", "da oggi in poi", "chiamami",
                    "mi chiamo", "sono allergic", "vivo a ", "abito a ", "lavoro come", "lavoro per", "il mio compleanno", "mia moglie",
                    "mio marito", "mia figlia", "mio figlio", "i miei figli", "la mia compagna", "il mio compagno", "sono vegetarian",
                    "sono vegan", "non bevo", "non mangio", "il mio socio", "la mia socia", "il mio capo", "uso sempre", "di solito"]
        return cues.contains(where: lower.contains) && !lower.hasPrefix("ricordati") && !lower.hasPrefix("ricorda che")
    }

    /// "Nudge" di memoria: estrae dal messaggio le preferenze dichiarate da salvare (al massimo due).
    public func memoryWorthy(_ prompt: String) async -> [String] {
        guard Self.mayContainMemory(prompt) else { return [] }
        let session = LanguageModelSession(model: Agent.model, instructions: "Individui solo preferenze e fatti personali dichiarati esplicitamente. Nel dubbio restituisci una lista vuota.")
        let facts = (try? await session.respond(to: "Messaggio: \(prompt.prefix(600))", schema: Self.memorySchema,
                                                 options: GenerationOptions(samplingMode: .greedy)).content.strings("fatti")) ?? []
        return facts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 8 && $0.count <= 240 }
    }

    private static let parentSummarySchema = makeSchema("Riepilogo", [
        .required("riepilogo", .string, "Cosa è stato fatto e concluso nella chat: risultati, decisioni, dati importanti e cose in sospeso, in 3-8 righe"),
    ])

    /// Riepilogo di una chat figlia da riportare alla chat madre.
    public func summarizeForParent(title: String, transcript: String) async throws -> String {
        try await writer("Riassumi fedelmente il lavoro svolto in una conversazione, per chi non l'ha seguita.")
            .respond(to: "Chat «\(title)»:\n\(transcript.suffix(5000))", schema: Self.parentSummarySchema).content.string("riepilogo") ?? ""
    }
}
