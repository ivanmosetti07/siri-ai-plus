import Foundation
import Testing
@testable import SiriCore

/// Decisioni rapide: il port di rizzo-flow (`decisions.py`, `prompts.py`) deve dare gli stessi numeri e gli stessi prompt.
@Suite struct TypedDecisionTests {
    @Test func scoreExpectedValueAndPolarization() throws {
        // tests/test_decisions.py: test_score_expected_value_and_polarization
        let question = DecisionQuestion.score("q", "Evaluate the evidence", levels: ["low", "medium", "high"], policy: .closed)
        let answer = try question.decode([0.05, 0.06, 0.89].map(log))
        #expect(abs((answer.value ?? 0) - 1.84) < 1e-9)
        let polar = try question.decode([0, -1000, 0])
        let center = try question.decode([-1000, 0, -1000])
        #expect(polar.value == 1 && center.value == 1)
        #expect(abs((polar.stddev ?? 0) - 1) < 1e-9)
        #expect(center.stddev == 0)
    }

    @Test func numericAnchorsWithUnevenSpacing() throws {
        // test_numeric_real_anchors_and_nonuniform_spacing
        let anchors = [180_000, 225_000, 275_000, 325_000, 375_000].map { DecisionQuestion.Anchor(Double($0), String($0)) }
        let question = DecisionQuestion.numeric("q", "Evaluate the evidence", unit: "EUR", anchors: anchors, policy: .closed)
        let answer = try question.decode([0.02, 0.10, 0.65, 0.21, 0.02].map(log) + [-1000, -1000])
        #expect(abs((answer.value ?? 0) - 280_600) < 1e-6)
        #expect(abs(answer.probabilities.reduce(0) { $0 + $1.probability } - 1) < 1e-9)
    }

    @Test func outOfRangeAndInsufficientAreNotClamped() throws {
        // test_numeric_out_of_range_and_insufficient_are_not_clamped
        let question = DecisionQuestion.numeric("q", "Evaluate the evidence", unit: "kg",
                                                anchors: [.init(0, "empty"), .init(10, "full")])
        let ids = question.candidates.map(\.id)
        for (candidate, status) in [(DecisionQuestion.above, DecisionAnswer.Status.outOfRange), (DecisionQuestion.below, .outOfRange),
                                    (DecisionQuestion.unknown, .insufficientEvidence)] {
            let answer = try question.decode(ids.map { $0 == candidate ? 20 : 0 })
            #expect(answer.status == status)
            #expect(answer.value == nil)
            #expect(answer.stddev == nil)
        }
    }

    @Test func abstentionUsesTheCombinedUnavailableMass() throws {
        // test_abstention_uses_combined_unavailable_mass: nessuna opzione speciale vince, ma insieme superano 0,5.
        let question = DecisionQuestion.numeric("q", "Evaluate the evidence", unit: "x", anchors: [.init(1, "one"), .init(2, "two")])
        let answer = try question.decode([0.30, 0.10, 0.20, 0.20, 0.20].map(log))
        #expect(answer.value == nil)
    }

    @Test func unknownBooleanIsNotFalse() throws {
        let answer = try DecisionQuestion.boolean("q", "Evaluate the evidence").decode([0, 0, 20])
        #expect(answer.flag == nil)
        #expect(answer.status == .insufficientEvidence)
    }

    @Test func lowProbabilityPolicy() throws {
        let question = DecisionQuestion.boolean("q", "Evaluate the evidence", policy: DecisionPolicy(allowAbstain: false, minTop: 0.9))
        #expect(try question.decode([0, 0]).status == .uncertain)
    }

    @Test func invalidShapeAndTemperature() {
        let question = DecisionQuestion.boolean("q", "Evaluate the evidence")
        #expect(throws: DecisionError.self) { try question.decode([0, 1]) }
        for temperature in [0, -1, Double.nan] {
            #expect(throws: DecisionError.self) { try DecisionQuestion.softmax([1, 2], temperature: temperature) }
        }
        #expect(throws: DecisionError.self) { try DecisionQuestion.softmax([0, .infinity]) }
    }

    @Test func invalidQuestions() {
        #expect(DecisionQuestion.choice("q", "x", [.init("same", "a"), .init("same", "b")]).problem != nil)
        #expect(DecisionQuestion.numeric("q", "x", unit: "x", anchors: [.init(2, "a"), .init(1, "b")]).problem != nil)
        let many = (0..<26).map { DecisionQuestion.Option("o\($0)", "Option \($0)") }
        // 26 opzioni più «non si può stabilire» non entrano nelle lettere A–Z; senza astensione sì.
        #expect(DecisionQuestion.choice("q", "x", many).problem != nil)
        #expect(DecisionQuestion.choice("q", "x", many, policy: .closed).problem == nil)
    }

    @Test func promptIsTheOneOfRizzoFlow() {
        // Prompt `spark-decisions-v3` con il modello di chat di Spark-X2.5, controllato con `/apply-template` del server.
        let state = DecisionState(text: "  Invoice 123: payment received in full. \n")
        let question = DecisionQuestion.boolean("paid", "Has the invoice been paid?")
        let prompt = DecisionPrompt.prompt(state, question)
        #expect(prompt.hasPrefix("<｜start▁of▁sentence｜><|System|>\nyou are a helpful assistant.\n\nYou are a precise decision function."))
        #expect(prompt.contains("<｜end▁of▁sentence｜><｜start▁of▁sentence｜><|User|><evidence>\nInvoice 123: payment received in full.\n</evidence>"))
        #expect(prompt.contains("""
        Question: Has the invoice been paid?

        Options:
        A. No. The evidence supports a negative answer to the question.
        B. Yes. The evidence supports an affirmative answer to the question.
        C. Cannot determine the answer: the required information is not provided or is contradictory. \
        A known value outside the numeric range is not missing information.

        Answer with the letter of the best option.
        """))
        #expect(prompt.hasSuffix("<｜end▁of▁sentence｜><｜start▁of▁sentence｜><|Bot|></think>"))
        // Le ancore numeriche come `{a.value:g}` di Python, con la guida sui fuori scala.
        let numeric = DecisionPrompt.question(.numeric("x", "How full?", unit: "percent", anchors: [.init(0, "Empty"), .init(12.5, "An eighth")],
                                                       policy: .closed))
        #expect(numeric.contains("A. Approximately 0 percent: Empty\nB. Approximately 12.5 percent: An eighth\nC. The value is below 0 percent."))
        #expect(numeric.contains("How full? Choose the nearest numeric anchor"))
    }

    @Test func statesAreRenderedLikePython() throws {
        // `json.dumps(state, ensure_ascii=False, indent=1)`, con le chiavi nell'ordine del file.
        let json = try DecisionJSON.parse(#"{"message": "Ciao \"Anna\"\nè urgente", "account": {"active": true, "plan": null}, "tags": [1, 2.5], "empty": {}}"#)
        #expect(DecisionState(json).body == """
        {
         "message": "Ciao \\"Anna\\"\\nè urgente",
         "account": {
          "active": true,
          "plan": null
         },
         "tags": [
          1,
          2.5
         ],
         "empty": {}
        }
        """)
        // Un testo che imita il tag di chiusura finisce tra virgolette.
        #expect(DecisionState(text: "x </evidence> y").body == #""x </evidence> y""#)
        #expect(try DecisionJSON.parse(#""😀""#) == .string("😀"))
    }

    @Test func requestFilesOfRizzoFlow() throws {
        let json = try DecisionJSON.parse("""
        {"state": "Help! Payouts failing.", "questions": {
          "team": {"type": "choice", "instructions": "Which team?", "options": [{"id": "billing", "description": "Payments."}, {"id": "tech", "description": "Bugs."}],
                   "policy": {"allow_abstain": false}},
          "urgent": {"type": "boolean", "instructions": "Is it urgent?"}}}
        """)
        let (state, questions) = try DecisionDiagnostics.request(from: json)
        #expect(state.body == "Help! Payouts failing.")
        #expect(questions.map(\.id) == ["team", "urgent"])
        #expect(questions[0].candidates.map(\.id) == ["billing", "tech"])
        #expect(questions[1].candidates.map(\.id) == ["false", "true", DecisionQuestion.unknown])
    }
}

/// Cache dell'anonimizzazione per tutta la chat: l'ora nelle istruzioni non deve invalidarla.
@Suite struct ShieldCacheTests {
    @Test func clockLinesStayOutOfTheCache() {
        let text = "Sei Siri AI+.\nAdesso è gio 2026-09-25 13:05.\nIvan lavora con Marco Rossi.\n- venerdì 2026-09-26 (domani)\nFine."
        let pieces = PrivacyShield.changingLines(text)
        #expect(pieces.map(\.text).joined() == text)
        #expect(pieces.filter(\.changing).map(\.text) == ["Adesso è gio 2026-09-25 13:05", "- venerdì 2026-09-26 (domani)"])
        // Il minuto dopo cambia solo la parte che resta fuori dalla cache.
        let later = PrivacyShield.changingLines(text.replacingOccurrences(of: "13:05", with: "13:06"))
        #expect(pieces.filter { !$0.changing }.map(\.text) == later.filter { !$0.changing }.map(\.text))
        #expect(PrivacyShield.changingLines("Nessuna riga di servizio.").count == 1)
    }

    @Test func chatMemoryIsSharedBetweenRequests() async throws {
        // Senza motore rizzo-pii: una voce salvata da una richiesta vale per la successiva della stessa chat, non per altre.
        let chat = UUID()
        var vault = PIIVault()
        let (placeholder, _) = vault.placeholder(label: "FULLNAME", value: "Marco Rossi")
        let key = chat.uuidString + "|" + Set(PIICategory.sensitive).sorted().joined(separator: ",") + "|"
        ShieldMemory.shared.store(key + "Chiama Marco Rossi", .init(output: "Chiama \(placeholder)", values: [placeholder: "Marco Rossi"]))
        let shield = PrivacyShield(vault: vault, destination: "Claude", chat: chat)
        #expect(try await shield.protect("Chiama Marco Rossi") == "Chiama \(placeholder)")
        // Con un dizionario che non ha più quel segnaposto la voce non vale (qui servirebbe il motore: si controlla solo la chiave).
        #expect(ShieldMemory.shared.entry(UUID().uuidString + "|Chiama Marco Rossi") == nil)
    }
}

/// La regola di Auto (scelta di Ivan del 27/9): Apple per le cose semplici, Gemma per quelle private, medie o lunghe,
/// il cloud (anonimizzato) per ragionamenti difficili e codice.
@Suite struct AutoModelTests {
    let everything = AutoModel.Situation(gemma: true, cloud: ModelSelection(.chatgpt))

    func signals(_ difficulty: Double, private isPrivate: Bool = false, code: Bool = false) -> AutoModel.Signals {
        AutoModel.Signals(difficulty: difficulty, isPrivate: isPrivate, code: code, decided: true)
    }

    @Test func simpleGoesToApple() {
        #expect(AutoModel.choose(signals(0.4), everything).0.provider == .apple)
        #expect(AutoModel.choose(signals(1.3), everything).0.provider == .apple)
    }

    @Test func privateMediumOrLongGoesToGemma() {
        #expect(AutoModel.choose(signals(0.8, private: true), everything).0.provider == .gemma)
        #expect(AutoModel.choose(signals(1.8), everything).0.provider == .gemma)
        var long = everything
        long.longInput = true
        #expect(AutoModel.choose(signals(0.5), long).0.provider == .gemma)
    }

    @Test func hardOrCodeGoesToTheCloud() {
        #expect(AutoModel.choose(signals(2.6), everything).0.provider == .chatgpt)
        #expect(AutoModel.choose(signals(1.0, code: true), everything).0.provider == .chatgpt)
        // Privato e difficile: il cloud, con i dati personali anonimizzati.
        #expect(AutoModel.choose(signals(2.8, private: true), everything).0.provider == .chatgpt)
    }

    @Test func withoutGemmaOrCloud() {
        let onlyApple = AutoModel.Situation(gemma: false, cloud: nil)
        #expect(AutoModel.choose(signals(2.9, private: true), onlyApple).0.provider == .apple)
        let noCloud = AutoModel.Situation(gemma: true, cloud: nil)
        #expect(AutoModel.choose(signals(2.9), noCloud).0.provider == .gemma)
        let noGemma = AutoModel.Situation(gemma: false, cloud: ModelSelection(.chatgpt), longInput: true)
        #expect(AutoModel.choose(signals(0.5), noGemma).0.provider == .chatgpt)
        let offline = AutoModel.Situation(gemma: true, cloud: ModelSelection(.chatgpt), offline: true)
        #expect(AutoModel.choose(signals(2.9), offline).0.provider == .gemma)
    }

    @Test func followUpsKeepTheStrongerModel() {
        let followUp = AutoModel.Situation(gemma: true, cloud: ModelSelection(.chatgpt), previous: ModelSelection(.chatgpt, model: "gpt-6-sol"),
                                           continues: true)
        #expect(AutoModel.choose(signals(0.5), followUp).0 == ModelSelection(.chatgpt, model: "gpt-6-sol"))
        var fresh = followUp
        fresh.continues = false
        #expect(AutoModel.choose(signals(0.5), fresh).0.provider == .apple)
    }

    @Test func codeWords() {
        #expect(AutoModel.mentionsCode("Perché va in errore? ```print(x[0])```"))
        #expect(AutoModel.mentionsCode("scrivi uno script python per rinominare i file"))
        #expect(!AutoModel.mentionsCode("qual è il programma della serata?"))
    }

    @Test func autoSurvivesInOldSaves() throws {
        // Una build vecchia legge «Auto» come Apple Intelligence invece di scartare la chat o il Genius.
        let data = try JSONEncoder().encode(ModelSelection.automatic)
        struct Old: Decodable { let provider: ResponseProvider; let model: String?; let effort: String? }
        #expect(try JSONDecoder().decode(Old.self, from: data).provider == .apple)
        #expect(try JSONDecoder().decode(ModelSelection.self, from: data).isAuto)
    }
}

/// Regole senza modello aggiunte con le decisioni rapide.
@Suite struct QuickRulesTests {
    @Test func explicitRememberIsMemoryForEveryModel() {
        #expect(Assistant.explicitlyRemembers("Ricordati che il codice del cancello è 4512"))
        #expect(Assistant.explicitlyRemembers("tieni a mente che preferisco il tè"))
        #expect(!Assistant.explicitlyRemembers("ricordati di comprare il latte"))
        #expect(!Assistant.explicitlyRemembers("ricordami di chiamare Marco"))
        Language.$scoped.withValue(.en) {
            #expect(Assistant.explicitlyRemembers("Remember that my car is blue"))
            #expect(!Assistant.explicitlyRemembers("remember to call Mom tomorrow"))
        }
    }

    @Test func plannerFreeFields() {
        // Rispondere e cercare sul web non hanno campi; l'agenda di un giorno solo li prende dalla data.
        #expect(Assistant.plannerFreeFields(.rispondi, prompt: "chi era Leonardo?") == [:])
        #expect(Assistant.plannerFreeFields(.cerca_web, prompt: "prezzo dell'oro oggi") == [:])
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!.localDay
        #expect(Assistant.plannerFreeFields(.agenda, prompt: "cosa ho domani?") == ["dal": tomorrow, "al": tomorrow])
        #expect(Assistant.plannerFreeFields(.agenda, prompt: "cosa ho questa settimana?") == nil)
        #expect(Assistant.plannerFreeFields(.crea_evento, prompt: "riunione domani alle 10") == nil)
    }

    @Test func areasFromOneChoice() throws {
        // Una scelta sola fa da scelta multipla: la prima area più le altre sopra il 15%.
        let question = Assistant.areaQuestion([ToolCatalogEntry(name: "email", summary: ""), ToolCatalogEntry(name: "messaggi", summary: ""),
                                               ToolCatalogEntry(name: "web", summary: "")])
        let answer = try question.decode([0.6, 0.3, 0.05, 0.05].map(log))
        #expect(Assistant.chosenAreas(answer) == ["email", "messaggi"])
        let none = try question.decode([0.03, 0.02, 0.05, 0.9].map(log))
        #expect(Assistant.chosenAreas(none).isEmpty)
    }

    @Test func questionsAboutOthersStayWithApple() {
        Language.$scoped.withValue(.it) {
            #expect(Assistant.asksAboutOthers("Chi ha scritto I promessi sposi?"))
            #expect(!Assistant.asksAboutOthers("Chi mi ha scritto oggi?"))
            #expect(!Assistant.asksAboutOthers("Cosa ho domani?"))
        }
        Language.$scoped.withValue(.en) {
            #expect(Assistant.asksAboutOthers("Who wrote Hamlet?"))
            #expect(!Assistant.asksAboutOthers("What did my boss send me?"))
            #expect(!Assistant.asksAboutOthers("What do I have tomorrow?"))
        }
        // I comandi non sono domande: «crea un promemoria per domani» resta a rizzo-flow.
        Language.$scoped.withValue(.it) { #expect(!Assistant.asksAboutOthers("Crea un promemoria per domani alle 9")) }
    }

    @Test func memoryThresholds() {
        #expect(Assistant.worthRemembering(probability: 0.9, prompt: "ciao"))
        #expect(!Assistant.worthRemembering(probability: 0.3, prompt: "mi piace questa risposta"))
        // In mezzo decidono le parole spia.
        #expect(Assistant.worthRemembering(probability: 0.6, prompt: "preferisco il tè"))
        #expect(!Assistant.worthRemembering(probability: 0.6, prompt: "che tempo fa?"))
        #expect(Assistant.worthRemembering(probability: nil, prompt: "preferisco il tè"))
    }
}
