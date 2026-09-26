import Foundation
import Testing
@testable import SiriCore

/// Modifiche precise a documenti, presentazioni e fogli aperti: i comandi comuni non passano dal modello.
@Suite @MainActor struct ArtifactEditingTests {
    let document = DocumentOutline(plain: """
    # Piano marketing 2027
    ## Introduzione
    Questo piano descrive come aumentare la notorietà del marchio.
    ## Obiettivi
    Aumentare del 20% i contatti qualificati.
    ## Rischi
    Il rischio principale è l'aumento dei costi pubblicitari.
    Un secondo rischio è la dipendenza da un solo canale.
    ## Conclusioni
    Il piano è sostenibile.
    """)

    func result(_ instruction: String) -> String? {
        Assistant.quickDocumentEdit(instruction, outline: document).map { document.applying($0.operations).rendered() }
    }

    @Test func clearAllAndWrite() {
        #expect(result("cancella tutto e scrivi hello world") == "hello world")
        #expect(result("Svuota il documento") == "")
        #expect(result("sostituisci tutto con «Ciao a tutti»") == "Ciao a tutti")
    }

    @Test func keepOnlyTheTitle() {
        #expect(result("modifica il file tenendo solo titolo con scritto Hello Ivan") == "# Hello Ivan")
        #expect(result("cancella il corpo") == "# Piano marketing 2027")
        #expect(result("cancella il corpo del documento") == "# Piano marketing 2027")
        #expect(result("tieni solo il titolo") == "# Piano marketing 2027")
    }

    @Test func titleAndSections() {
        #expect(result("cambia il titolo in «Piano di comunicazione 2027»")?.hasPrefix("# Piano di comunicazione 2027\n## Introduzione") == true)
        let withoutRisks = result("elimina la sezione Rischi") ?? ""
        #expect(!withoutRisks.contains("Rischi") && !withoutRisks.contains("secondo rischio") && withoutRisks.contains("## Conclusioni"))
        #expect(result("elimina l'ultimo paragrafo")?.hasSuffix("## Conclusioni") == true)
        // "Il titolo della sezione Budget" non è il titolo del documento: va al modello.
        #expect(Assistant.quickDocumentEdit("cambia il titolo della sezione Budget in Costi", outline: document) == nil)
    }

    @Test func formattingAndLiteralText() {
        let bold = result("metti in grassetto i titoli delle sezioni") ?? ""
        #expect(bold.contains("## **Introduzione**") && bold.contains("## **Conclusioni**") && bold.contains("# Piano marketing 2027"))
        #expect(result("scrivi hello world")?.hasSuffix("Il piano è sostenibile.\nhello world") == true)
        #expect(result("aggiungi «Grazie a tutti» all'inizio")?.hasPrefix("# Piano marketing 2027\nGrazie a tutti") == true)
        // Contenuti da scrivere ("una sezione su…") vanno al modello, non si copiano.
        #expect(Assistant.quickDocumentEdit("aggiungi una sezione sui canali social dopo gli obiettivi", outline: document) == nil)
        #expect(Assistant.quickDocumentEdit("elimina il testo selezionato", outline: document) == nil)
    }

    @Test func sectionsFollowHeadings() {
        #expect(document.sectionEnd(after: 5) == 8)
        #expect(document.heading(matching: "sui rischi") == 5)
        let inserted = document.applying([.insert(after: 4, [.init("Canali", .intestazione), .init("Newsletter e social.")])]).rendered()
        #expect(inserted.contains("Aumentare del 20% i contatti qualificati.\n## Canali\nNewsletter e social.\n## Rischi"))
    }

    @Test func routingWithAnOpenDocument() {
        #expect(Assistant.isArtifactCommand("cancella tutto e scrivi hello world"))
        #expect(Assistant.isArtifactCommand("cancella il corpo"))
        #expect(Assistant.isArtifactCommand("elimina la riga del cibo"))
        #expect(!Assistant.isArtifactCommand("cancella l'evento di domani"))
        #expect(!Assistant.isArtifactCommand("manda questo documento a Marco per email"))
        #expect(!Assistant.isArtifactCommand("crea un nuovo documento sul lancio"))
        #expect(!Assistant.isArtifactCommand("cosa dice la sezione budget?"))
        #expect(Assistant.isArtifactQuestion("riassumi questo documento in tre punti"))
        #expect(Assistant.isCommand("scrivi hello world"))
        #expect(!Assistant.isCommand("chi ha scritto I promessi sposi?"))

        let assistant = Assistant()
        var work = WorkContext()
        work.artifactKind = "documento"
        work.artifactTitle = "Piano"
        assistant.work = work
        var plan = Assistant.Plan(action: .elimina_evento, fields: [:])
        assistant.applyRules(to: &plan, prompt: "cancella il corpo")
        #expect(plan.action == .modifica_artefatto)
        plan = Assistant.Plan(action: .crea_documento, fields: [:])
        assistant.applyRules(to: &plan, prompt: "riassumi questo documento in tre punti")
        #expect(plan.action == .rispondi)
        // Senza documento aperto "cancella" resta al calendario.
        assistant.work = WorkContext()
        plan = Assistant.Plan(action: .elimina_evento, fields: [:])
        assistant.applyRules(to: &plan, prompt: "cancella l'evento di domani")
        #expect(plan.action == .elimina_evento)
    }

    @Test func literalDocuments() {
        #expect(Assistant.literalDocumentText("mi crei un documento dove c'è scritto hello world") == "hello world")
        #expect(Assistant.literalDocumentText("crea documento con scritto ciao sara") == "ciao sara")
        #expect(Assistant.literalDocumentText("crea un documento con il testo: «Riunione alle 10»") == "Riunione alle 10")
        #expect(Assistant.literalDocumentText("crea un documento vuoto") == "")
        #expect(Assistant.literalDocumentText("crea un documento sul lancio del prodotto") == nil)
        let draft = DocumentDraft(literal: "hello world")
        #expect(draft.body == "hello world" && draft.sections.isEmpty && draft.title == "hello world")
    }

    let deck = Deck(title: "Lancio", slides: ["Lancio prodotto", "Il problema", "La soluzione", "Mercato", "Prossimi passi"].map { Slide.make(.titoloElenco, title: $0, bullets: ["a", "b"]) })

    func titles(_ instruction: String, selected: Int? = nil) -> [String]? {
        guard let plan = Assistant.quickDeckEdit(instruction, deck: deck, selected: selected) else { return nil }
        var copy = deck
        copy.apply(plan.operations)
        return copy.slides.map(\.title)
    }

    @Test func slides() {
        #expect(titles("elimina la slide 3") == ["Lancio prodotto", "Il problema", "Mercato", "Prossimi passi"])
        #expect(titles("cancella l'ultima slide") == ["Lancio prodotto", "Il problema", "La soluzione", "Mercato"])
        #expect(titles("togli questa slide", selected: 1) == ["Lancio prodotto", "La soluzione", "Mercato", "Prossimi passi"])
        #expect(titles("elimina la slide sul mercato") == ["Lancio prodotto", "Il problema", "La soluzione", "Prossimi passi"])
        #expect(titles("sposta la slide 2 dopo la 4") == ["Lancio prodotto", "La soluzione", "Mercato", "Il problema", "Prossimi passi"])
        #expect(titles("sposta la slide 5 all'inizio") == ["Prossimi passi", "Lancio prodotto", "Il problema", "La soluzione", "Mercato"])
        #expect(titles("cambia il titolo della slide 2 in «Perché ora»")?[1] == "Perché ora")
        var copy = deck
        copy.apply([.insert(after: 3, [DeckDraft.Slide(title: "Costi", bullets: ["x"])])])
        #expect(copy.slides.map(\.title) == ["Lancio prodotto", "Il problema", "La soluzione", "Mercato", "Costi", "Prossimi passi"])
    }

    func sheet() -> Sheet {
        Evaluation.testSheet("""
        Voce | Ottobre | Novembre | Totale
        Volo | 180 | 0 | 0
        Hotel | 420 | 0 | 0
        Cibo | 150 | 60 | 0
        Totale | 0 | 0 | 0
        """)
    }

    @Test func sheets() {
        var table = sheet()
        #expect(table.display(CellRef("B5")!) == "750")
        // Riga nuova sopra il totale: la somma la comprende e riceve la formula del totale di riga.
        table.apply([.insertRow(at: 4, values: [0: "Assicurazione", 1: "45"])])
        #expect(table.display(CellRef("A5")!) == "Assicurazione")
        #expect(table.display(CellRef("B6")!) == "795")
        #expect(table.display(CellRef("D5")!) == "45")
        // Eliminare una riga aggiorna i totali.
        let plan = Assistant.quickSheetEdit("elimina la riga del cibo", sheet: sheet())
        var without = sheet()
        without.apply(plan?.operations ?? [])
        #expect(without.display(CellRef("A4")!) == "Totale" && without.display(CellRef("B4")!) == "600")
        // Raddoppiare una voce cambia solo i numeri scritti, non le formule.
        var doubled = sheet()
        doubled.apply(Assistant.quickSheetEdit("raddoppia la spesa dell'hotel", sheet: sheet())?.operations ?? [])
        #expect(doubled.display(CellRef("B3")!) == "840" && doubled.display(CellRef("B5")!) == "1170")
        let chart = Assistant.quickSheetEdit("crea un grafico a torta delle spese", sheet: sheet())
        #expect(chart?.operations == [.addChart(.pie, range: "A1:B4")])
    }
}
