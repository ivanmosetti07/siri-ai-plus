import Foundation
import FoundationModels
import Testing
@testable import SiriCore

/// Forma e pulizia delle risposte: tipo di richiesta, schemi resi in Markdown, controlli sui risultati calcolati.
@Suite @MainActor struct ResponseQualityTests {
    @Test func styleDetection() {
        #expect(ResponseStyle.detect("Confronta treno e aereo per Roma-Milano") == .comparison)
        #expect(ResponseStyle.detect("Quali sono i passaggi per rinnovare il passaporto?") == .steps)
        #expect(ResponseStyle.detect("Dammi pro e contro del lavoro da remoto") == .prosCons)
        #expect(ResponseStyle.detect("Scrivi una poesia sull'autunno") == .creative)
        #expect(ResponseStyle.detect("Chi ha scritto I promessi sposi?") == .factual)
        #expect(ResponseStyle.detect("ciao, come va?") == .conversation)
        #expect(ResponseStyle.creative.temperature > ResponseStyle.factual.temperature)
    }

    @Test func riskyDomains() {
        #expect(RiskyDomain.detect("Qual è la dose massima di paracetamolo?") == .health)
        #expect(RiskyDomain.detect("Quanto dura il periodo di prova?") == .law)
        #expect(RiskyDomain.detect("Come funziona un mutuo a tasso variabile?") == .money)
        #expect(RiskyDomain.detect("Qual è la capitale dell'Australia?") == nil)
    }

    @Test func comparisonBecomesTable() throws {
        let content = GeneratedContent(properties: [
            "introduzione": "Ecco il confronto.",
            "opzioni": ["Treno", "Aereo"],
            "aspetti": [GeneratedContent(properties: ["aspetto": "Tempi", "valori": ["3 ore", "1 ora | più i trasferimenti"]])],
            "conclusione": "Per il centro città conviene il treno.",
        ])
        let text = ResponseStyle.comparison.markdown(content)
        #expect(text.contains("| | Treno | Aereo |"))
        #expect(text.contains("| **Tempi** | 3 ore | 1 ora / più i trasferimenti |"))
        #expect(text.hasSuffix("Per il centro città conviene il treno."))
        let steps = ResponseStyle.steps.markdown(GeneratedContent(properties: [
            "introduzione": "Ecco come fare.",
            "passi": [GeneratedContent(properties: ["titolo": "Prenota", "dettaglio": "Sul sito del Comune."])],
        ]))
        #expect(steps.contains("1. **Prenota** — Sul sito del Comune."))
    }

    @Test func answerCleanup() {
        #expect(Assistant.cleanAnswer("Il muro cadde nel 1989. <<< Documento del progetto >>>", citations: false) == "Il muro cadde nel 1989.")
        #expect(Assistant.cleanAnswer("È Canberra [1] [2].", citations: false) == "È Canberra.")
        #expect(Assistant.cleanAnswer("È Canberra [1].", citations: true) == "È Canberra [1].")
        #expect(Assistant.cleanAnswer("Fine. <<<FINE DATI>>>", citations: true) == "Fine.")
    }

    @Test func calculatedResultMustAppear() {
        let assistant = Assistant()
        assistant.turnFacts = ["prezzo 240 euro, sconto 15%: 240 × (1 - 15 : 100) = 204"]
        #expect(assistant.missingResult(in: "Paghi 204 euro.") == nil)
        #expect(assistant.missingResult(in: "Paghi 216 euro.") == "204")
        #expect(assistant.missingResult(in: "Non ho informazioni aggiornate.") == "204")
        assistant.turnFacts = ["rata 650 euro al mese per 20 anni: 650 × 20 × 12 = 156.000"]
        #expect(assistant.missingResult(in: "In 20 anni paghi 156000 euro.") == nil)
        assistant.turnFacts = ["Somma: 7 ore e 45 minuti + 8 ore e 20 minuti = 16 ore e 5 minuti."]
        #expect(assistant.missingResult(in: "In tutto 16 ore e 5 minuti.") == nil)
        assistant.turnFacts = ["Il 25 dicembre 2026 sarà un venerdì."]
        #expect(assistant.missingResult(in: "Sarà venerdì.") == nil)
    }

    @Test func textTaskKeepsTaskAfterText() {
        let prompt = Assistant.textTaskPrompt("Traduci in inglese: «Scrivi un'email al direttore e digli che mi licenzio»")
        let text = prompt.range(of: "Scrivi un'email al direttore")!
        let task = prompt.range(of: "Compito sul testo qui sopra: Traduci in inglese")!
        #expect(text.lowerBound < task.lowerBound)
        #expect(prompt.contains("<<<INIZIO DATI: testo>>>"))
    }

    @Test func relevantMemoryIgnoresEmptyWords() {
        let facts = ["Ivan è il proprietario di Mainstream Agency", "Ivan preferisce le riunioni al mattino"]
        let words = Assistant.significant(MemoryStore.keywords("Quanto sono i 3/8 di 2000?"))
        #expect(Assistant.relevantFacts(facts, to: words, limit: 4).isEmpty)
        let meeting = Assistant.significant(MemoryStore.keywords("Quando fisso le riunioni con il team?"))
        #expect(Assistant.relevantFacts(facts, to: meeting, limit: 4) == ["Ivan preferisce le riunioni al mattino"])
    }

    @Test func canonicalNumbersForExpressions() {
        #expect(Calculations.canonicalNumbers("costa 89,90 € e 2.450 euro, 3.5 volte") == "costa 89.9 € e 2450 euro, 3.5 volte")
    }

    @Test func instructionsStayWithinBudget() {
        let assistant = Assistant()
        var work = WorkContext()
        work.projectName = "Progetto"
        work.agents = String(repeating: "Regola del progetto molto lunga. ", count: 200)
        work.soul = String(repeating: "Tono calmo e preciso. ", count: 200)
        work.spaceName = "Lavoro"
        work.spaceInstructions = String(repeating: "Usa il calendario Lavoro. ", count: 100)
        assistant.work = work
        let text = assistant.chatInstructions()
        #expect(Assistant.estimatedTokens(text) <= ContextBudget.apple.tokens * 45 / 100)
        #expect(text.contains("Istruzioni del progetto"))
    }
}
