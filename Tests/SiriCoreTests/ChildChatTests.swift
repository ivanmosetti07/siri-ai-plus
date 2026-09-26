import Foundation
import Testing
@testable import SiriCore

/// Chat madre e figlia: cosa eredita la figlia e quando chiede di tornare. Anteprima dei file con i collegamenti di Obsidian.
@Suite struct ChildChatTests {
    @Test func theChildInheritsWhatIvanSaid() {
        let turns = [
            ChatTurn(role: .user, text: "Il sito di Rossi Moto va lanciato il 15 ottobre"),
            ChatTurn(role: .assistant, text: "Perfetto, segno il 15 ottobre."),
            ChatTurn(role: .user, text: "Il referente è Martina\nVerdi"),
            ChatTurn(role: .assistant, text: "Non ho informazioni su questo cliente."),
        ]
        let text = ChildChat.handoff(title: "Lancio Rossi Moto", turns: turns)
        #expect(text.hasPrefix("Chat madre «Lancio Rossi Moto». Ivan ha detto:"))
        #expect(text.contains("- Il sito di Rossi Moto va lanciato il 15 ottobre") && text.contains("- Il referente è Martina Verdi"))
        // Una risposta incerta non passa alla figlia; una che dice qualcosa sì.
        #expect(!text.contains("Ultima risposta"))
        let sure = ChildChat.handoff(title: "Lancio", turns: Array(turns.prefix(2)))
        #expect(sure.contains("Ultima risposta: Perfetto, segno il 15 ottobre."))
    }

    @Test func returningToTheParent() {
        for prompt in ["concludi", "Ok, concludi.", "abbiamo finito", "torna alla chat madre", "riporta tutto alla madre",
                       "concludi questa chat figlia e riporta il riepilogo", "mandalo nella chat madre"] {
            #expect(ChildChat.asksToReturn(prompt), "«\(prompt)» dovrebbe tornare alla madre")
        }
        for prompt in ["concludi il preventivo per Rossi Moto entro venerdì", "manda un messaggio a mia madre",
                       "come sta mia madre?", "chiudi la finestra del browser e apri la mail", "torna indietro di una pagina"] {
            #expect(!ChildChat.asksToReturn(prompt), "«\(prompt)» non riguarda la chat madre")
        }
    }

    @Test func obsidianLinksOpenInsideTheApp() {
        let html = Markdown.html(from: "---\ntags: cliente\n---\nVedi [[Rossi Moto|il cliente]], [[STATE]] e [[OBJECTIVES#Q3]].")
        #expect(html.contains(#"<a class="wikilink" href="siriai-wiki:Rossi%20Moto">il cliente</a>"#))
        #expect(html.contains(#"href="siriai-wiki:STATE">STATE</a>"#))
        #expect(html.contains(#"href="siriai-wiki:OBJECTIVES%23Q3""#))
        #expect(html.contains(#"<table class="frontmatter">"#) && !html.contains("---"))
    }
}
