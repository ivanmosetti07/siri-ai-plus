import Foundation
import Testing
@testable import SiriCore

/// La cronologia che riceve il modello: scambi recenti dentro la finestra, richiami dei più vecchi, frasi che dipendono
/// dalla conversazione, ragionamento prima della risposta e lettura a pezzi.
@Suite struct ConversationMemoryTests {
    private func turns(_ pairs: [(String, String)]) -> [ChatTurn] {
        pairs.flatMap { [ChatTurn(role: .user, text: $0.0), ChatTurn(role: .assistant, text: $0.1)] }
    }

    @Test func exchangesPairQuestionsAndReplies() {
        var list = turns([("Ciao", "Ciao Ivan!"), ("Che tempo fa?", "Sole.")])
        list.insert(ChatTurn(role: .assistant, text: "Riepilogo della chat «Viaggio»: …"), at: 0)
        list.append(ChatTurn(role: .user, text: "Crea un evento domani alle 10"))
        let exchanges = ConversationMemory.exchanges(list)
        #expect(exchanges.map(\.user) == ["", "Ciao", "Che tempo fa?", "Crea un evento domani alle 10"])
        #expect(exchanges.map(\.reply) == ["Riepilogo della chat «Viaggio»: …", "Ciao Ivan!", "Sole.", ""])
        #expect(exchanges.map(\.index) == [0, 1, 3, 5])
    }

    @Test func windowKeepsTheNewestAndShortensTheOlder() {
        let long = String(repeating: "Una frase lunga della risposta con dettagli. ", count: 60)
        let exchanges = ConversationMemory.exchanges(turns((1...8).map { ("Domanda numero \($0)", long) }))
        let window = ConversationMemory.window(exchanges, characters: 4000)
        #expect(window.last?.user == "Domanda numero 8")
        #expect(window.count >= 3 && window.count < 8)
        // L'ultimo scambio è il più lungo, i precedenti via via più corti; il totale sta nel budget.
        #expect(window.last!.reply.count > window.first!.reply.count)
        #expect(window.reduce(0) { $0 + $1.user.count + $1.reply.count } <= 4000)
        // Dall'inizio della risposta (la risposta vera) e dalla fine (la conclusione).
        #expect(window.last!.reply.hasPrefix("Una frase lunga") && window.last!.reply.contains(" […] "))
    }

    @Test func dataOfTheLastAnswerGoesWithItWhenThereIsRoom() {
        var list = turns([("Cerca le notizie su Aurora", "Ecco tre notizie.")])
        list[0].data = "[1] Aurora parte il 3 marzo. [2] Budget 45.000 euro. [3] Fornitore a Bologna."
        let window = ConversationMemory.window(ConversationMemory.exchanges(list), characters: 3000)
        #expect(window.first?.data?.contains("Bologna") == true)
        #expect(ConversationMemory.window(ConversationMemory.exchanges(list), characters: 700).first?.data == nil)
    }

    @Test func recallFindsOlderExchangesThatMatter() {
        let exchanges = ConversationMemory.exchanges(turns([
            ("Segnati che il codice del mio armadietto in palestra è 4721.", "Fatto, me lo ricordo."),
            ("Riassumi la storia del Colosseo", "Il Colosseo fu costruito tra il 72 e l'80 d.C."),
            ("Come funziona la fotosintesi?", "Le piante trasformano la luce in energia chimica."),
        ]))
        let hits = ConversationMemory.recall(exchanges, request: "Qual è il codice del mio armadietto?")
        #expect(hits.map(\.index) == [0])
        #expect(ConversationMemory.recall(exchanges, request: "Che tempo fa domani a Roma?").isEmpty)
    }

    @Test func excerptKeepsHeadAndTail() {
        let text = (1...40).map { "Parola\($0)" }.joined(separator: " ")
        let short = ConversationMemory.excerpt(text, limit: 150)
        #expect(short.count <= 150 && short.hasPrefix("Parola1 ") && short.hasSuffix("Parola40") && short.contains(" […] "))
        #expect(ConversationMemory.excerpt("breve", limit: 150) == "breve")
    }

    @Test func messagesThatNeedTheConversation() {
        for prompt in ["In che anno è nato?", "E quella della Spagna?", "Ora in spagnolo", "Quanto è lungo il primo?", "Quanti anni hanno in tutto?",
                       "Quante once sono?", "Di quanto aumenta?", "Entro quando?", "Dove è nata lei?", "Adesso fanne una versione in inglese.",
                       "Rendilo più formale."] {
            #expect(Assistant.dependsOnConversation(prompt), "\(prompt)")
        }
        for prompt in ["Ciao!", "Grazie", "Chi ha scritto I promessi sposi?", "Qual è la formula chimica dell'acqua?",
                       "Scrivi una frase di benvenuto per il sito del mio ristorante di pesce a Gaeta.",
                       "Quanto costa un biglietto del treno da Roma a Milano?"] {
            #expect(!Assistant.dependsOnConversation(prompt), "\(prompt)")
        }
    }

    @Test func reworkOfThePreviousReply() {
        for prompt in ["Rendilo più formale.", "Adesso fanne una versione in inglese.", "Ora in spagnolo", "più corto", "Traducilo in francese"] {
            #expect(Assistant.reworksPreviousReply(prompt), "\(prompt)")
        }
        for prompt in ["Rendi più efficiente il mio lavoro con tre consigli pratici per organizzare meglio la settimana e le riunioni", "Scrivi una poesia",
                       "In inglese come si dice gatto?x"] {
            #expect(!Assistant.reworksPreviousReply(prompt), "\(prompt)")
        }
    }

    @Test @MainActor func questionsAndStoriesDoNotCreate() {
        #expect(Assistant.isQuestion("Ho una riunione alle 9:00 che dura 90 minuti. A che ora finisco?"))
        #expect(!Assistant.asksToCreate("Ho una riunione alle 9:00 che dura 90 minuti. A che ora finisco?"))
        #expect(Assistant.asksToCreate("Mi fissi una riunione con Marco domani alle 15?"))
        #expect(Assistant.asksToCreate("prepara un foglio con il budget del viaggio a Lisbona"))
        #expect(!Assistant.asksToCreate("Il budget per il marketing passa da 8.000 a 11.500 euro."))
        #expect(!Assistant.namesArtifact("Il budget per il marketing passa da 8.000 a 11.500 euro."))
        #expect(Assistant.namesArtifact("Budget del viaggio in una tabella"))
        #expect(Assistant.isQuestion("Leggi questo documento e dimmi chi fornisce le sedie: «…»"))
        #expect(Assistant.isTextTask("Leggi questo documento e dimmi chi fornisce le sedie: «La sala è pronta e le sedie arrivano da Treviso.»"))
        #expect(!Assistant.isTextTask("Dimmi le ultime notizie su: intelligenza artificiale generativa e modelli linguistici"))
        // Un testo lungo incollato non rende complessa la richiesta.
        #expect(!Assistant.isComplex("Riassumi questo documento: «" + String(repeating: "Il fornitore prepara e organizza tutto. ", count: 40) + "»"))
    }

    @Test func whichQuestionsGetAChainOfThought() {
        for prompt in ["Luca ha il doppio degli anni di Marco. Tra 5 anni la somma delle loro età sarà 40. Quanti anni ha Marco oggi?",
                       "Un mattone pesa 1 kg più mezzo mattone. Quanto pesa un mattone?",
                       "Anna è più alta di Bea, Bea è più alta di Carla e Dora è più bassa di Carla. Chi è la seconda più bassa?",
                       "Posso andare in palestra lunedì, mercoledì o venerdì. Lunedì ho una cena, venerdì piove. Quale giorno mi conviene?",
                       "Ho 20 euro. Compro 3 quaderni da 2,50 € e 2 penne da 1,20 €. Quanto mi resta?",
                       "Ragiona bene: è meglio affittare o comprare casa a Roma?"] {
            #expect(Assistant.needsReasoning(prompt), "\(prompt)")
        }
        for prompt in ["Perché il cielo è blu?", "Chi ha vinto i mondiali del 2006?", "Scrivi una poesia sul mare d'autunno per mia moglie",
                       "Che tempo fa domani a Roma?", "Qual è la capitale del Portogallo?", "Qual è la media tra 18, 24, 27 e 30?"] {
            #expect(!Assistant.needsReasoning(prompt), "\(prompt)")
        }
    }

    @Test func theAppCalculationCountsOnlyIfItAgrees() {
        #expect(Assistant.agrees(ReasoningNotes(steps: ["a"], conclusion: "In tutto hanno 25 anni.", exact: "12 + 9 + 4 = 25")))
        #expect(Assistant.agrees(ReasoningNotes(steps: ["a"], conclusion: "Ti restano circa dieci euro.", exact: "20 − 7,5 − 2,4 = 10,1")))
        #expect(!Assistant.agrees(ReasoningNotes(steps: ["a"], conclusion: "La lumaca arriva in cima in 8 giorni.", exact: "10 : (3 − 2) = 10")))
        #expect(!Assistant.agrees(ReasoningNotes(steps: ["a"], conclusion: "Carla.", exact: nil)))
        // Un conto sbagliato nei passaggi: vale il conto dell'app.
        #expect(Assistant.hasArithmeticSlip(["Si sommano i numeri: 18 + 24 + 27 + 30 = 129."]))
        #expect(!Assistant.hasArithmeticSlip(["Somma: 90 + 20 = 110 minuti", "Prezzo: 3 × 2,50 = 7,50 €", "La differenza netta è 3 - 2 = 1 metro",
                                              "La probabilità finale è 6 ÷ 56 = 3 ÷ 28."]))
    }

    @Test @MainActor func weekdaysFromAGivenDay() {
        #expect(Calculations.weekdayFacts(in: "Se oggi fosse mercoledì, che giorno della settimana sarebbe tra 10 giorni?")
                == ["Contando da oggi (mercoledì), tra 10 giorni è sabato (10 giorni dopo)."])
        #expect(Calculations.weekdayFacts(in: "Una bolletta va pagata 3 giorni lavorativi prima. Se il 5 è un lunedi, entro che giorno pago?")
                == ["3 giorni lavorativi prima del 5 (lunedì): mercoledì (sabato e domenica non contano)."])
        #expect(Calculations.weekdayFacts(in: "Che giorno sarà tra 10 giorni?").isEmpty)
        // Con un giorno dato nella domanda le date vere di oggi restano fuori.
        #expect(!Assistant.ruleFacts(for: "Se oggi fosse mercoledì, che giorno sarebbe tra 10 giorni?").contains { $0.hasPrefix("Oggi è") })
    }

    @Test @MainActor func ordinalsPointAtTheLatestList() {
        let assistant = Assistant()
        assistant.record(user: "Sto valutando tre nomi per il mio cane: Rocco, Pepe e Brio.", reply: "Belli tutti e tre!")
        #expect(assistant.resolvingOrdinals("Ok, scelgo il secondo. Come si chiamerà il cane?") == "Ok, scelgo il secondo (Pepe). Come si chiamerà il cane?")
        #expect(assistant.resolvingOrdinals("Il primo giorno di scuola è lunedì?") == "Il primo giorno di scuola è lunedì?")
        assistant.record(user: "Elencami i tre fiumi più lunghi d'Italia.", reply: "Eccoli:\n1. **Po** – 652 km\n2. Adige: 410 km\n3. Tevere (405 km)")
        #expect(assistant.resolvingOrdinals("Quanto è lungo il primo?") == "Quanto è lungo il primo (Po)?")
        #expect(assistant.resolvingOrdinals("E l'ultimo?") == "E l'ultimo (Tevere)?")
        #expect(Assistant.listItems(in: "Ecco:\n1. Il fiume Po, che è il più lungo.\n2. Il fiume Adige.") == ["Il fiume Po", "Il fiume Adige"])
        #expect(assistant.resolvingOrdinals("Secondo me è troppo lungo") == "Secondo me è troppo lungo")
        #expect(Assistant.inlineItems(in: "I miei figli hanno 12, 9 e 4 anni.") == nil)
    }

    @Test func longTextIsCutBetweenParagraphs() {
        let paragraph = String(repeating: "Una frase del testo. ", count: 40)   // 840 caratteri
        let text = (1...12).map { "Paragrafo \($0). " + paragraph }.joined(separator: "\n\n")
        let pieces = Assistant.chunks(text, size: 3600)
        #expect(pieces.count >= 3 && pieces.allSatisfy { $0.count <= 3600 })
        #expect(pieces.joined(separator: " ").count >= text.count - pieces.count * 2)
        #expect(pieces.dropFirst().allSatisfy { $0.hasPrefix("Paragrafo") })
    }

    @Test @MainActor func theAppleSessionIsRebuiltFromTheChosenExchanges() {
        let assistant = Assistant()
        assistant.record(user: "Il mio medico si chiama dottor Esposito.", reply: "Ne terrò conto.")
        assistant.record(user: "Che verdure ci sono in autunno?", reply: "Zucca, cavoli e funghi.")
        let history = ConversationMemory.window(ConversationMemory.exchanges(assistant.turns), characters: 4000)
        assistant.chat = assistant.makeChat(history: history)
        let kinds = assistant.chat.transcript.map { entry -> String in
            switch entry {
            case .instructions: "istruzioni"
            case .prompt: "domanda"
            case .response: "risposta"
            default: "altro"
            }
        }
        #expect(kinds == ["istruzioni", "domanda", "risposta", "domanda", "risposta"])
        // Dopo il riassunto gli scambi raccolti non si rimandano, ma restano per i richiami.
        assistant.summarizedCount = 2
        #expect(assistant.historyTurns.map(\.text) == ["Che verdure ci sono in autunno?", "Zucca, cavoli e funghi."])
        #expect(assistant.recalledConversation(for: "Come si chiama il mio medico?") != nil)
    }

    @Test @MainActor func rewritesDoNotCarryResultsFromReplies() async {
        let assistant = Assistant()
        assistant.record(user: "Il budget per il marketing passa da 8.000 a 11.500 euro.", reply: "L'aumento è di 3.500 euro.")
        // Solo la guardia sui numeri (senza modello): la riscrittura con 3.500 va scartata.
        let said = Calculations.numbers(in: "Di quanto aumenta? Il budget per il marketing passa da 8.000 a 11.500 euro.")
        #expect(!said.contains(3500) && said.contains(8000) && said.contains(11500))
    }

    @Test @MainActor func recordKeepsTheDataAndTheSummaryMark() {
        let assistant = Assistant()
        assistant.lastObservation = "[1] Pagina letta"
        assistant.record(user: "Cerca Aurora", reply: "Ecco cosa ho trovato.")
        #expect(assistant.turns.first?.data == "[1] Pagina letta")
        assistant.summarizedCount = 2
        for index in 1...45 { assistant.record(user: "Domanda \(index)", reply: "Risposta \(index)") }
        #expect(assistant.turns.count == 80)
        #expect(assistant.summarizedCount == 0 && assistant.historyTurns.count == 80)
    }
}
