import Foundation

// MARK: - Memoria di fine turno (rizzo-flow)
//
// Dopo la risposta, senza bloccare la chat: rizzo-flow decide se la frase di Ivan dice qualcosa di duraturo da
// ricordare (prima bastava una parola spia come «preferisco» per chiamare Apple Intelligence, e senza parole spia non si
// ricordava nulla). Solo allora Apple estrae il fatto, e rizzo-flow lo confronta con i ricordi vicini: nuovo, già
// ricordato, o un aggiornamento di un ricordo vecchio («preferisco il caffè» dopo «preferisco il tè»).
// Ivan (27/9): si salva da solo e si avvisa, con «Annulla».

/// Un ricordo salvato in una chat: l'avviso «Ricordato: …» con Annulla.
public struct MemoryNote: Codable, Sendable, Equatable {
    public var text: String
    /// Il ricordo nella memoria generale (per Annulla).
    public var factID: UUID?
    /// Il testo di prima, se il ricordo ne ha aggiornato uno.
    public var replaced: String?
    public var undone = false

    public init(text: String, factID: UUID?, replaced: String? = nil) {
        self.text = text
        self.factID = factID
        self.replaced = replaced
    }
}

extension Assistant {
    /// Soglie dal banco `decisioni-memoria.json` (frasi inventate).
    enum MemoryThreshold {
        /// Si ricorda da 0,80 in su; sotto 0,45 no, anche se ci sono parole spia (lì erano falsi allarmi: «mi piace questa
        /// risposta», «di solito cosa si mangia a Natale?»); in mezzo decidono le parole spia.
        static let remember = 0.80
        static let forget = 0.45
        static let relation = 0.70
    }

    /// Vale la pena ricordare? `probability`: la probabilità di «sì» di rizzo-flow (nil = motore assente).
    nonisolated static func worthRemembering(probability: Double?, prompt: String) -> Bool {
        guard let probability else { return mayContainMemory(prompt) }
        if probability >= MemoryThreshold.remember { return true }
        if probability < MemoryThreshold.forget { return false }
        return mayContainMemory(prompt)
    }

    /// Formulazione scelta sul banco `decisioni-memoria.json`: con gli esempi (un nome, un codice, una data, un luogo) 18/20 e
    /// nessun errore sicuro; le due incerte le decidono le parole spia di prima.
    nonisolated static let rememberQuestion: DecisionQuestion = {
        var question = DecisionQuestion.boolean(
            "remember", "Does the user tell something lasting worth remembering for future conversations: a fact about themselves, the people "
                + "in their life or their work (a name, a code, a date, a place), a preference, a habit or a decision? A one-off request or a question is not.",
            yes: "Yes. Something lasting worth remembering.",
            no: "No. Nothing lasting to remember.", policy: .closed)
        question.questionFirst = true
        return question
    }()

    /// Come si lega un fatto nuovo a quelli già ricordati. I fatti noti stanno nell'evidenza (rizzo-flow giudica solo quella)
    /// e anche nelle opzioni, con il numero: con il solo numero il modello scambiava il fatto 1 con il 2.
    nonisolated static func relationState(new fact: String, known: [String]) -> DecisionState {
        DecisionState([("new_fact", .string(fact)),
                       ("known_facts", .array(known.enumerated().map { .string("\($0.offset + 1). \($0.element)") }))])
    }

    nonisolated static func relationQuestion(known: [String]) -> DecisionQuestion {
        var options = [DecisionQuestion.Option("new", "New information: none of the known facts says it.")]
        for (index, fact) in known.enumerated() {
            let short = shortened(fact, to: 90)
            options.append(.init("same_\(index)", "The same information as known fact \(index + 1) («\(short)»)."))
            options.append(.init("update_\(index)", "Updates or contradicts known fact \(index + 1) («\(short)»)."))
        }
        return .choice("relation", "How does the new fact relate to the known facts?", options, policy: .closed)
    }

    /// Cosa ricordare di un turno. `known`: i ricordi vicini (testo). Restituisce i fatti da salvare e, per ognuno,
    /// l'indice del ricordo che aggiorna (nil = nuovo); i doppioni non ci sono.
    public func memoryFromTurn(_ prompt: String, previousReply: String? = nil, known: [String]) async -> [(fact: String, replaces: Int?)] {
        // 1. Vale la pena? rizzo-flow se c'è, altrimenti le parole spia di prima.
        var state: [(String, DecisionJSON)] = [("user_said", .string(String(prompt.prefix(600))))]
        if let previousReply, previousReply.contains("?") { state.append(("assistant_asked", .string(String(previousReply.suffix(200))))) }
        let decision = await DecisionEngine.shared.decide(DecisionState(state), Self.rememberQuestion, priority: .background, label: "memoria")
        guard Self.worthRemembering(probability: decision?.probability(of: "true"), prompt: prompt) else { return [] }
        // 2. Il testo del ricordo lo scrive Apple Intelligence, in terza persona.
        let facts = await extractMemory(prompt)
        guard !facts.isEmpty else { return [] }
        // 3. Nuovo, già ricordato o aggiornamento: solo se ci sono ricordi con parole in comune.
        var result: [(String, Int?)] = []
        for fact in facts {
            // Doppioni esatti: basta il testo normalizzato.
            if known.contains(where: { MemoryStore.normalize($0) == MemoryStore.normalize(fact) }) { continue }
            let related = known.enumerated().filter { !MemoryStore.keywords($0.element).isDisjoint(with: MemoryStore.keywords(fact)) }
            guard !related.isEmpty else { result.append((fact, nil)); continue }
            let texts = Array(related.prefix(5).map(\.element))
            guard let answer = await DecisionEngine.shared.decide(Self.relationState(new: fact, known: texts), Self.relationQuestion(known: texts),
                                                                  priority: .background, label: "memoria"),
                  answer.confident(MemoryThreshold.relation), let choice = answer.choice else {
                result.append((fact, nil))
                continue
            }
            if choice.hasPrefix("same_") { Agent.log("MEMORIA: già ricordato («\(fact)»)"); continue }
            if choice.hasPrefix("update_"), let index = Int(choice.dropFirst("update_".count)), index < related.count {
                result.append((fact, related[index].offset))
            } else {
                result.append((fact, nil))
            }
        }
        return result
    }
}
