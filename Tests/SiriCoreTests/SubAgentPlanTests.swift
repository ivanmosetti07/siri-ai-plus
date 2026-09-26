import Foundation
import Testing
@testable import SiriCore

/// Compiti a passi (catena di pensieri e sub-agent): quando partono e come si legge il piano scritto da un modello esterno.
@Suite struct SubAgentPlanTests {
    @Test func complexRequestsFromManySources() {
        #expect(Assistant.isComplex("prepara il piano della settimana guardando calendario, task e email"))
        #expect(Assistant.isComplex("fai il punto su email e calendario di oggi e dimmi le priorità"))
        // Azioni verso altri e richieste semplici restano come sono (parti separate, schede da confermare, risposta diretta).
        #expect(!Assistant.isComplex("cosa ho domani e scrivi un'email a Marco per spostare la riunione"))
        #expect(!Assistant.isComplex("riassumi le email di oggi"))
        #expect(!Assistant.isComplex("leggi la nota spesa e aggiungi il latte ai promemoria"))
        #expect(!Assistant.isComplex("perché i sub agenti e la catena di pensieri non avviene nelle chat normali?"))
    }

    @Test func askingForSubAgents() {
        #expect(Assistant.wantsPlan("usa i sub-agent per confrontare i tre preventivi"))
        #expect(Assistant.wantsPlan("con 3 subagent cerca voli e hotel per Lisbona"))
        #expect(Assistant.wantsPlan("lavora a passi: prima leggi il brief, poi scrivi la bozza"))
        #expect(Assistant.isComplex("usa i sub-agent per il meteo"))
        // Nominarli in una domanda non basta; un piano da scrivere è un testo, non un modo di lavorare.
        #expect(!Assistant.wantsPlan("perché i sub agenti non partono?"))
        #expect(!Assistant.wantsPlan("fammi un piano di allenamento per la settimana"))
    }

    @Test func plansWrittenByOtherModels() throws {
        let text = """
        Ecco il piano:
        ```json
        {"ragionamento": ["Servono dati aggiornati", "Poi si confronta"], "passi": [
          {"titolo": "Treni", "istruzione": "Cerca sul web tempi e prezzi dei treni Roma-Milano", "in_parallelo": false},
          {"titolo": "Voli", "istruzione": "Cerca sul web tempi e prezzi dei voli Roma-Milano", "in_parallelo": false},
          {"titolo": "Confronto", "istruzione": "Confronta i risultati e prepara la risposta", "in_parallelo": true}],
         "consegna": "risposta"}
        ```
        """
        let plan = try #require(Assistant.parseTaskPlan(text, goal: "treno o aereo?"))
        #expect(plan.goal == "treno o aereo?" && plan.thoughts.count == 2 && plan.delivery == .risposta)
        #expect(plan.steps.map(\.title) == ["Treni", "Voli", "Confronto"])
        // Le due ricerche partono insieme; il confronto aspetta i loro risultati.
        #expect(plan.steps.map(\.parallel) == [false, true, false])
        #expect(Assistant.isFinalWriting(TaskPlan.Step(title: "Prepara la risposta finale", instruction: "Usa i dati trovati sui treni e sui voli", parallel: false)))
        #expect(!Assistant.isFinalWriting(TaskPlan.Step(title: "Treni", instruction: "Cerca sul web i treni", parallel: false)))
        #expect(Assistant.parseTaskPlan("Non so fare un piano.", goal: "x") == nil)
        #expect(Assistant.parseTaskPlan(#"{"passi": [{"titolo": "Uno", "istruzione": "Cerca X"}]}"#, goal: "x") == nil)
        let document = try #require(Assistant.parseTaskPlan(#"{"passi": [{"istruzione": "Leggi il file brief.md"}, {"titolo": "Relazione", "istruzione": "Scrivi la relazione"}], "consegna": "documento"}"#, goal: "x"))
        #expect(document.delivery == .documento && document.steps[0].title == "Leggi il file brief.md" && document.thoughts.isEmpty)
    }
}

/// Il modello di ogni sub-agent con ChatGPT e Claude: leggero per cercare e leggere, il più capace per le analisi difficili.
@Suite struct SubAgentRoutingTests {
    let gpt = [
        ModelOption(id: "gpt-6-astra", label: "GPT-6-Astra", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "medium"),
        ModelOption(id: "gpt-6-sol", label: "GPT-6-Sol", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "medium"),
        ModelOption(id: "gpt-6-luna", label: "GPT-6-Luna", efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium"),
        ModelOption(id: "gpt-5.6-sol", label: "GPT-5.6-Sol", efforts: ["low", "medium", "high"], defaultEffort: "low"),
        ModelOption(id: "gpt-5.6-terra", label: "GPT-5.6-Terra", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
        ModelOption(id: "gpt-5.6-luna", label: "GPT-5.6-Luna", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
        ModelOption(id: "gpt-5.5", label: "GPT-5.5", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
    ]

    @Test func claudeVersionsByDifficulty() {
        let chat = ModelSelection(.claude, model: "sonnet", effort: "medium")
        #expect(SubAgentRouting.selection(for: .facile, chat: chat, gpt: gpt) == ModelSelection(.claude, model: "haiku"))
        #expect(SubAgentRouting.selection(for: .media, chat: chat, gpt: gpt) == ModelSelection(.claude, model: "sonnet", effort: "medium"))
        #expect(SubAgentRouting.selection(for: .difficile, chat: chat, gpt: gpt) == ModelSelection(.claude, model: "opus", effort: "high"))
        // Con Fable o Opus nella chat i passi difficili restano a quel modello, con il suo ragionamento se è più alto.
        #expect(SubAgentRouting.selection(for: .difficile, chat: ModelSelection(.claude, model: "fable", effort: "max"), gpt: gpt)
                == ModelSelection(.claude, model: "fable", effort: "max"))
        #expect(SubAgentRouting.selection(for: .difficile, chat: ModelSelection(.claude, model: "opus", effort: "low"), gpt: gpt)
                == ModelSelection(.claude, model: "opus", effort: "high"))
    }

    @Test func chatGPTVersionsOfTheSameGeneration() {
        let sol = ModelSelection(.chatgpt, model: "gpt-6-sol", effort: "medium")
        #expect(SubAgentRouting.selection(for: .facile, chat: sol, gpt: gpt) == ModelSelection(.chatgpt, model: "gpt-6-luna", effort: "low"))
        #expect(SubAgentRouting.selection(for: .media, chat: sol, gpt: gpt) == ModelSelection(.chatgpt, model: "gpt-6-sol", effort: "medium"))
        #expect(SubAgentRouting.selection(for: .difficile, chat: sol, gpt: gpt) == ModelSelection(.chatgpt, model: "gpt-6-astra", effort: "high"))
        let terra = ModelSelection(.chatgpt, model: "gpt-5.6-terra")
        #expect(SubAgentRouting.selection(for: .facile, chat: terra, gpt: gpt).model == "gpt-5.6-luna")
        #expect(SubAgentRouting.selection(for: .media, chat: terra, gpt: gpt).model == "gpt-5.6-terra")
        #expect(SubAgentRouting.selection(for: .difficile, chat: terra, gpt: gpt).model == "gpt-5.6-sol")
        #expect(SubAgentRouting.generation("gpt-6-sol") == "gpt-6" && SubAgentRouting.generation("gpt-5.5") == "gpt-5.5")
        // Un ragionamento che il modello non ha diventa il suo predefinito.
        let luna = ModelSelection(.chatgpt, model: "gpt-6-luna", effort: "ultra")
        #expect(SubAgentRouting.selection(for: .difficile, chat: luna, gpt: gpt) == ModelSelection(.chatgpt, model: "gpt-6-astra", effort: "ultra"))
        // Gemma e Apple hanno un modello solo: nessuna scelta.
        #expect(SubAgentRouting.selection(for: .facile, chat: ModelSelection(.gemma), gpt: gpt) == ModelSelection(.gemma))
        #expect(!SubAgentRouting.routes(.gemma) && SubAgentRouting.routes(.claude) && SubAgentRouting.routes(.chatgpt))
    }

    @Test func labelsAndFallbackWithoutAppleIntelligence() {
        #expect(SubAgentRouting.label(ModelSelection(.claude, model: "haiku"), gpt: gpt) == "Haiku")
        #expect(SubAgentRouting.label(ModelSelection(.claude, model: "opus", effort: "high"), gpt: gpt) == "Opus · alto")
        #expect(SubAgentRouting.label(ModelSelection(.chatgpt, model: "gpt-6-luna", effort: "low"), gpt: gpt) == "GPT-6-Luna · basso")
        func step(_ text: String) -> TaskPlan.Step { TaskPlan.Step(title: "Passo", instruction: text, parallel: false) }
        #expect(SubAgentRouting.heuristic(step("Cerca sul web i prezzi dei treni Roma-Milano")) == .facile)
        #expect(SubAgentRouting.heuristic(step("Valuta i rischi del contratto e decidi la strategia di negoziazione")) == .difficile)
        #expect(SubAgentRouting.heuristic(step("Scrivi una bozza di messaggio per il cliente")) == .media)
        // Chi cerca e basta non va al modello più capace, anche se Apple Intelligence lo giudica difficile.
        #expect(SubAgentRouting.capped(.difficile, for: step("Cerca sul web le ultime notizie su Rossi Moto")) == .media)
        #expect(SubAgentRouting.capped(.difficile, for: step("Cerca sul web i bilanci e valuta i rischi finanziari")) == .difficile)
        // E chi analizza o confronta non va al modello più leggero.
        #expect(SubAgentRouting.capped(.facile, for: step("Analizza i risultati dei treni")) == .media)
        #expect(SubAgentRouting.capped(.facile, for: step("Leggi il file brief.md")) == .facile)
    }
}
