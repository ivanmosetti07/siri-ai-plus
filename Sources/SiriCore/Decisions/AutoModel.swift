import Foundation

// MARK: - Modello Auto
//
// Con «Auto» la chat non ha un modello fisso. A ogni richiesta rizzo-flow risponde a due domande chiuse — quanto è
// difficile, se tocca dati privati di persone reali — e una regola scelta da Ivan (27/9/2026) decide chi risponde:
// Apple Intelligence per le cose semplici, Gemma per quelle private, medie o lunghe, il modello cloud di Auto (ChatGPT di
// serie, sempre anonimizzato) per ragionamenti difficili e codice, con la versione adatta alla difficoltà.
// Senza rizzo-flow decidono gli stessi segnali di oggi (parole chiave).

public enum AutoModel {
    /// Cosa c'è e cosa serve, misurato dall'app.
    public struct Situation: Sendable {
        /// Gemma scaricato e llama.cpp installato.
        public var gemma: Bool
        /// Il modello cloud di Auto, se si può usare (accesso fatto e consenso dato). nil = solo modelli sul Mac.
        public var cloud: ModelSelection?
        public var offline: Bool
        /// Allegati o testi più lunghi di quanto Apple Intelligence può leggere.
        public var longInput: Bool
        /// Chi ha risposto al turno prima in questa chat.
        public var previous: ModelSelection?
        /// La richiesta continua il discorso («e domani?», «rendilo più corto»).
        public var continues: Bool

        public init(gemma: Bool, cloud: ModelSelection?, offline: Bool = false, longInput: Bool = false,
                    previous: ModelSelection? = nil, continues: Bool = false) {
            self.gemma = gemma; self.cloud = cloud; self.offline = offline; self.longInput = longInput
            self.previous = previous; self.continues = continues
        }
    }

    public struct Signals: Sendable, Equatable {
        /// 0 banale · 1 semplice · 2 media · 3 difficile (livello medio atteso).
        public var difficulty: Double
        public var isPrivate: Bool
        public var code: Bool
        /// Da rizzo-flow (altrimenti dalle parole chiave).
        public var decided: Bool

        public init(difficulty: Double, isPrivate: Bool, code: Bool, decided: Bool) {
            self.difficulty = difficulty; self.isPrivate = isPrivate; self.code = code; self.decided = decided
        }
    }

    public struct Choice: Sendable {
        public var selection: ModelSelection
        /// Il perché, per «Come ho lavorato» e il registro («difficile 2,7 · codice»).
        public var reason: String
        public var signals: Signals
        public var milliseconds: Int
    }

    // MARK: Regola

    static func strength(_ provider: ResponseProvider) -> Int {
        switch provider {
        case .apple: 0
        case .gemma, .ds4: 1
        case .chatgpt, .claude: 2
        }
    }

    /// Chi risponde. Privato e difficile insieme va al cloud (anonimizzato): la qualità del ragionamento conta di più,
    /// e i dati personali partono comunque con i segnaposto.
    public static func choose(_ signals: Signals, _ situation: Situation) -> (ModelSelection, String) {
        let t = Language.t
        // Soglie dal banco `decisioni-auto.json`: «difficile» da 2,3 (analisi e progetti stavano fra 2,3 e 2,5),
        // «medio» da 1,5 (lettere e confronti fra 1,5 e 2,1).
        let hard = signals.difficulty >= 2.3 || signals.code
        let medium = signals.difficulty >= 1.5
        var reasons: [String] = []
        if signals.code { reasons.append(t("codice", "code")) }
        reasons.append(t("difficoltà ", "difficulty ") + String(format: "%.1f", signals.difficulty))
        if signals.isPrivate { reasons.append(t("dati privati", "private data")) }
        if situation.longInput { reasons.append(t("testo lungo", "long text")) }

        var selection = ModelSelection(.apple)
        if hard, let cloud = situation.cloud, !situation.offline {
            selection = SubAgentRouting.selection(for: signals.difficulty >= 2.75 || signals.code ? .difficile : .media, chat: cloud)
        } else if signals.isPrivate || situation.longInput || medium || hard {
            if situation.gemma {
                selection = ModelSelection(.gemma)
            } else if situation.longInput, let cloud = situation.cloud, !situation.offline {
                selection = SubAgentRouting.selection(for: .media, chat: cloud)
            }
        }
        // Una domanda che continua il discorso resta almeno al modello di prima (non si perde il filo con uno più debole).
        if situation.continues, let previous = situation.previous, strength(previous.provider) > strength(selection.provider),
           previous.provider != .gemma || situation.gemma, previous.provider.isLocal || (situation.cloud != nil && !situation.offline) {
            selection = previous
            reasons.append(t("continua il discorso", "continues the conversation"))
        }
        return (selection, reasons.joined(separator: " · "))
    }

    // MARK: Segnali

    /// Senza rizzo-flow: dalle parole della richiesta, come faceva l'app.
    public static func heuristicSignals(for prompt: String) -> Signals {
        let difficulty: Double = Assistant.isSmallTalk(prompt) ? 0
            : Assistant.isComplex(prompt) ? 2.5
            : Assistant.needsReasoning(prompt) ? 2
            : prompt.count > 400 ? 2 : 1
        return Signals(difficulty: difficulty, isPrivate: RiskyDomain.detect(prompt) != nil, code: mentionsCode(prompt), decided: false)
    }

    /// Richieste di programmazione: codice incollato o parole del mestiere.
    public static func mentionsCode(_ prompt: String) -> Bool {
        let lower = " " + prompt.lowercased() + " "
        if prompt.contains("```") { return true }
        let words = ["codice", "script", "debug", "compilazione", "compila ", "stack trace", "regex", " sql", "swift", "python",
                     "javascript", "typescript", "kotlin", " java ", "c++", " html", " css", " json", " yaml", "funzione in ",
                     " code ", "compile", " function ", "refactor", "bug "]
        return words.contains(where: lower.contains)
    }

    nonisolated static let difficultyQuestion: DecisionQuestion = {
        var question = DecisionQuestion.score("difficulty", "How much thinking does the request need?", levels: [
            "Trivial: a greeting, a thanks, or a question answered in one sentence.",
            "Simple: a short fact, a short text, or one direct action on an app.",
            "Medium: combining several facts, a structured text of some length, or a few steps of reasoning.",
            "Hard: long or expert reasoning, math, programming, or the analysis of long documents.",
        ], policy: .closed)
        question.questionFirst = true
        return question
    }()

    nonisolated static let privateQuestion: DecisionQuestion = {
        var question = DecisionQuestion.boolean(
            "private", "Does the request or its attachments contain private information about real people: health, money, family, "
                + "private messages or personal documents?",
            yes: "Yes. It contains private information about real people.",
            no: "No. Nothing private about real people.", policy: .closed)
        question.questionFirst = true
        return question
    }()
}

extension Assistant {
    /// I segnali di Auto per una richiesta: rizzo-flow se c'è (circa mezzo secondo), altrimenti le parole chiave.
    public func autoSignals(for prompt: String, attachments: [String] = []) async -> AutoModel.Signals {
        let fallback = AutoModel.heuristicSignals(for: prompt)
        let state = decisionState(for: prompt, attachments: attachments)
        guard let result = await DecisionEngine.shared.decide(state, [AutoModel.difficultyQuestion, AutoModel.privateQuestion],
                                                              budget: 2, label: "modello auto"),
              let difficulty = result["difficulty"]?.value else { return fallback }
        // Privato se lo dice rizzo-flow o se le parole chiave trovano salute, soldi o leggi: per la privacy meglio abbondare
        // (Gemma resta sul Mac).
        let isPrivate = result["private"]?.flag == true || fallback.isPrivate
        return AutoModel.Signals(difficulty: difficulty, isPrivate: isPrivate, code: fallback.code, decided: true)
    }
}
