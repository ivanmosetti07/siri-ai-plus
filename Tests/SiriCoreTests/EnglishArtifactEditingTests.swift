import Foundation
import Testing
@testable import SiriCore

/// Comandi in inglese su documenti, fogli e presentazioni aperti: le stesse modifiche dei comandi italiani
/// (documenti di prova del banco inglese, Support/eval/tools-en.json).
@Suite @MainActor struct EnglishArtifactEditingTests {
    /// Il documento «Marketing plan 2027» come lo legge la valutazione.
    let document = DocumentOutline(plain: """
    Marketing plan 2027
    Introduction
    This plan describes how to increase brand awareness in 2027 with a limited budget.
    Goals
    Increase qualified leads by 20% and launch two seasonal campaigns.
    Budget
    The total budget is 45,000 euros, of which 30,000 for online advertising.
    Risks
    The main risk is rising advertising costs.
    Conclusions
    The plan is sustainable if results are measured every month.
    """)

    let italianDocument = DocumentOutline(plain: """
    # Piano marketing 2027
    ## Introduzione
    Questo piano descrive come aumentare la notorietà del marchio.
    ## Rischi
    Il rischio principale è l'aumento dei costi pubblicitari.
    ## Conclusioni
    Il piano è sostenibile.
    """)

    /// Richiesta in inglese, come nell'app dopo il riconoscimento della lingua.
    func english<T>(_ body: () throws -> T) rethrows -> T { try Language.$scoped.withValue(.en) { try body() } }
    func italian<T>(_ body: () throws -> T) rethrows -> T { try Language.$scoped.withValue(.it) { try body() } }

    func result(_ instruction: String, on outline: DocumentOutline? = nil) -> String? {
        let outline = outline ?? document
        return Assistant.quickDocumentEdit(instruction, outline: outline).map { outline.applying($0.operations).rendered() }
    }

    @Test func routingOfTheEnglishBench() {
        english {
            let edits = ["fix the typos", "add a section about social channels after the goals", "translate the budget paragraph into Italian",
                         "make the introduction more formal", "delete the Risks section", "change the title to \"Communication plan 2027\"",
                         "make the section titles bold", "delete everything and write hello world", "keep only the title",
                         "add a row for insurance, 45 euros in October", "create a pie chart of the expenses", "delete the food row",
                         "double the hotel cost", "delete slide 3", "change the title of slide 2 to \"Why now\"",
                         "add a slide about costs after the market one", "can you delete slide 3?", "please make it shorter"]
            for prompt in edits {
                #expect(Assistant.isArtifactCommand(prompt), "\(prompt)")
                #expect(!Assistant.isArtifactQuestion(prompt), "\(prompt)")
            }
            let questions = ["what does the budget section say?", "summarize this document in three points", "what's the November total?",
                             "what is the presentation about?", "could you summarize this document?", "is there a section about risks?"]
            for prompt in questions {
                #expect(Assistant.isArtifactQuestion(prompt), "\(prompt)")
                #expect(!Assistant.isArtifactCommand(prompt), "\(prompt)")
            }
            // Documenti nuovi, email, calendario, note e memoria: non sono modifiche a ciò che è aperto.
            for prompt in ["create a new document about the product launch", "send this document to Mark by email", "delete tomorrow's meeting",
                           "move the dinner to Saturday", "add milk to the shopping note", "keep in mind that I prefer short slides",
                           "make a reservation for two"] {
                #expect(!Assistant.isArtifactCommand(prompt), "\(prompt)")
            }
            #expect(Assistant.isCommand("delete slide 3") && Assistant.isCommand("create a presentation about Lisbon") && Assistant.isCommand("please fix the typos"))
            #expect(!Assistant.isCommand("who wrote Pride and Prejudice?") && !Assistant.isCommand("sum up the news"))
        }
    }

    @Test func applyRulesRouteEnglishRequests() {
        english {
            let assistant = Assistant()
            var work = WorkContext()
            work.artifactKind = "documento"
            work.artifactTitle = "Marketing plan 2027"
            assistant.work = work
            for prompt in ["delete the Risks section", "keep only the title", "fix the typos", "delete everything and write hello world"] {
                var plan = Assistant.Plan(action: .elimina_evento, fields: [:])
                assistant.applyRules(to: &plan, prompt: prompt)
                #expect(plan.action == .modifica_artefatto, "\(prompt)")
            }
            for prompt in ["summarize this document in three points", "what does the budget section say?"] {
                var plan = Assistant.Plan(action: .crea_documento, fields: [:])
                assistant.applyRules(to: &plan, prompt: prompt)
                #expect(plan.action == .rispondi, "\(prompt)")
            }
        }
    }

    @Test func documentCommands() {
        english {
            #expect(result("delete everything and write hello world") == "hello world")
            #expect(result("Clear the document") == "")
            #expect(result("replace everything with “Hi all”") == "Hi all")
            #expect(result("keep only the title") == "# Marketing plan 2027")
            #expect(result("keep only the title and change it to Hello Ivan") == "# Hello Ivan")
            #expect(result("delete the body") == "# Marketing plan 2027")
            #expect(result("change the title to \"Communication plan 2027\"")?.hasPrefix("# Communication plan 2027\n## Introduction") == true)
            let withoutRisks = result("delete the Risks section") ?? ""
            #expect(!withoutRisks.contains("Risks") && !withoutRisks.contains("rising advertising") && withoutRisks.contains("## Conclusions"))
            #expect(result("remove the section about risks") == withoutRisks)
            #expect(result("delete the last paragraph")?.hasSuffix("## Conclusions") == true)
            let bold = result("make the section titles bold") ?? ""
            #expect(bold.contains("## **Introduction**") && bold.contains("## **Conclusions**") && bold.contains("# Marketing plan 2027\n"))
            #expect(result("bold the headings") == bold)
            #expect(result("make the title italic")?.hasPrefix("# _Marketing plan 2027_") == true)
            #expect(result("write hello world")?.hasSuffix("measured every month.\nhello world") == true)
            #expect(result("add “Thanks everyone” at the beginning")?.hasPrefix("# Marketing plan 2027\nThanks everyone\n## Introduction") == true)
            // Contenuti da scrivere, parti precise e titoli di sezione vanno al modello.
            for prompt in ["add a section about social channels after the goals", "translate the budget paragraph into Italian",
                           "make the introduction more formal", "fix the typos", "change the title of the Budget section to Costs",
                           "delete everything and write a short introduction", "add Marketing to the title"] {
                #expect(Assistant.quickDocumentEdit(prompt, outline: document) == nil, "\(prompt)")
            }
            // Le frasi per la chat sono in inglese.
            #expect(Assistant.quickDocumentEdit("delete the Risks section", outline: document)?.summary == "I deleted the section “Risks” (2 paragraphs).")
            #expect(Assistant.quickDocumentEdit("keep only the title", outline: document)?.summary == "I kept only the title (10 paragraphs removed).")
            #expect(Assistant.quickDocumentEdit("make the section titles bold", outline: document)?.summary == "I made 5 headings bold.")
            #expect(Assistant.quickDocumentEdit("change the title to “Plan B”", outline: document)?.summary == "I changed the title to “Plan B”.")
        }
    }

    @Test func documentsInTheOtherLanguage() {
        // Comando inglese su un documento italiano: la sezione si cerca fra le intestazioni del documento.
        english {
            let plan = Assistant.quickDocumentEdit("delete the Rischi section", outline: italianDocument)
            #expect(italianDocument.applying(plan?.operations ?? []).rendered()
                    == "# Piano marketing 2027\n## Introduzione\nQuesto piano descrive come aumentare la notorietà del marchio.\n## Conclusioni\nIl piano è sostenibile.")
            #expect(plan?.summary == "I deleted the section “Rischi” (2 paragraphs).")
            // Un comando italiano resta valido anche se la conversazione è in inglese (le frasi per la chat restano inglesi).
            #expect(Assistant.isArtifactCommand("elimina la sezione Rischi") && Assistant.isArtifactQuestion("riassumi questo documento in tre punti"))
            #expect(Assistant.quickDocumentEdit("elimina la sezione Rischi", outline: italianDocument)?.summary == "I deleted the section “Rischi” (2 paragraphs).")
        }
        // Comando italiano su un documento inglese: le regole italiane, con le intestazioni inglesi.
        italian {
            #expect(Assistant.quickDocumentEdit("elimina la sezione Risks", outline: document)?.summary == "Ho eliminato la sezione «Risks» (2 paragrafi).")
            #expect(result("cambia il titolo in «Communication plan 2027»")?.hasPrefix("# Communication plan 2027\n## Introduction") == true)
            #expect(Assistant.quickDocumentEdit("metti in grassetto i titoli delle sezioni", outline: document)?.summary == "Ho messo in grassetto 5 intestazioni.")
            #expect(!Assistant.isArtifactCommand("cosa dice la sezione budget?"))
        }
    }

    @Test func positionsAndTransformations() {
        english {
            // "After the goals": in fondo alla sezione Goals, prima di Budget.
            #expect(Assistant.insertionAnchor("add a section about social channels after the goals", outline: document) == 4)
            #expect(Assistant.insertionAnchor("add a paragraph before the conclusions", outline: document) == 8)
            #expect(Assistant.insertionAnchor("add a note at the end", outline: document) == 10)
            #expect(Assistant.insertionAnchor("add a quote at the beginning", outline: document) == 0)
            // Trasformazioni di tutto il testo, o di una parte precisa (allora sceglie il modello).
            #expect(Assistant.globalTargets("make everything more formal", outline: document) == [2, 4, 6, 8, 10])
            #expect(Assistant.globalTargets("translate the document into italian", outline: document)?.count == 11)
            #expect(Assistant.globalTargets("translate the budget paragraph into italian", outline: document) == nil)
            #expect(Assistant.globalTargets("make the introduction more formal", outline: document) == nil)
            #expect(Assistant.globalTargets("make a chart", outline: document) == nil)
            #expect(Assistant.englishSpellingFix("fix the typos") && !Assistant.englishSpellingFix("fix the tone"))
        }
    }

    @Test func spellingFollowsTheText() {
        english {
            #expect(Assistant.spellingLanguage(for: "The main risk is rising advertising costs for the company.") == "en")
            #expect(Assistant.spellingLanguage(for: "Il rischio principale è l'aumento dei costi pubblicitari.") == "it")
            #expect(Assistant.spellingLanguage(for: "Budget") == "en")
            #expect(Assistant.hasSpellingErrors("This plan descrbes the budget for next year."))
            #expect(!Assistant.hasSpellingErrors("This plan describes the budget for next year."))
        }
        italian {
            #expect(Assistant.spellingLanguage(for: "Budget") == "it")
            #expect(Assistant.spellingLanguage(for: "Il rischio principale è l'aumento dei costi pubblicitari.") == "it")
        }
    }

    @Test func modelSeesEnglishLabels() {
        english {
            var outline = document
            outline.selected = [2]
            let text = outline.numbered(characters: 2600).text
            #expect(text.contains("[P1] (title) Marketing plan 2027") && text.contains("[P2] (heading) Introduction") && text.contains("[P3] (body) [selected] This plan"))
            #expect(DocumentOutline.Style(modelName: "heading") == .intestazione && DocumentOutline.Style(modelName: "intestazione") == .intestazione)
            #expect(TextFormat(modelName: "bold") == .grassetto && TextFormat(modelName: "corsivo") == .corsivo)
            #expect(Assistant.documentOperationKind("insert_after") == "inserisci_dopo" && Assistant.documentOperationKind("elimina") == "elimina")
            #expect(Assistant.deckOperationKind("add_after") == "aggiungi_dopo" && Assistant.sheetOperationKind("add_row") == "aggiungi_riga")
            let operations: [DocumentOperation] = [.delete([7, 8]), .insert(after: 4, [.init("Social channels", .intestazione), .init("Newsletter.")])]
            #expect(Assistant.summarize(operations, outline: document) == "I added the section “Social channels” and deleted the section “Risks”.")
            #expect(Assistant.languageName(of: italianDocument.plainText) == "Italian" && Assistant.languageName(of: document.plainText) == "English")
        }
        italian {
            var outline = document
            outline.selected = [2]
            #expect(outline.numbered(characters: 2600).text.contains("[P3] (testo) [selezionato] This plan"))
            let operations: [DocumentOperation] = [.delete([7, 8]), .insert(after: 4, [.init("Social channels", .intestazione), .init("Newsletter.")])]
            #expect(Assistant.summarize(operations, outline: document) == "Ho aggiunto la sezione «Social channels» e eliminato la sezione «Risks».")
        }
    }

    @Test func englishSchemasAreValid() {
        // Gli schemi si costruiscono alla prima modifica in inglese: uno schema sbagliato fermerebbe l'app.
        _ = Assistant.englishDocumentEditSchema
        _ = Assistant.englishParagraphSchema
        _ = Assistant.englishDeckEditSchema
        _ = Assistant.englishSheetEditSchema
        english {
            #expect(Assistant.rewriteSummary(3, of: 5) == "I edited 3 of 5 paragraphs." && Assistant.rewriteSummary(0, of: 5) == "I didn't find anything to change.")
            #expect(Assistant.englishCommandText("Could you please delete slide 3?") == "delete slide 3")
        }
        italian {
            #expect(Assistant.rewriteSummary(3, of: 5) == "Ho modificato 3 paragrafi su 5.")
        }
    }

    @Test func literalDocuments() {
        english {
            #expect(Assistant.literalDocumentText("create a document that says hello world") == "hello world")
            #expect(Assistant.literalDocumentText("make a doc with the text: “Meeting at 10”") == "Meeting at 10")
            #expect(Assistant.literalDocumentText("create a blank document") == "")
            #expect(Assistant.literalDocumentText("create a document about the product launch") == nil)
            #expect(Assistant.literalDocumentText("create a document with the text of the speech") == nil)
            #expect(Assistant.literalDocumentText("crea un documento con scritto ciao sara") == "ciao sara")
        }
    }

    let deck = Deck(title: "Product launch", slides: ["Product launch", "The problem", "The solution", "Market", "Next steps"]
        .map { Slide.make(.titoloElenco, title: $0, bullets: ["a", "b"]) })

    func titles(_ instruction: String, selected: Int? = nil) -> [String]? {
        guard let plan = Assistant.quickDeckEdit(instruction, deck: deck, selected: selected) else { return nil }
        var copy = deck
        copy.apply(plan.operations)
        return copy.slides.map(\.title)
    }

    @Test func slides() {
        english {
            #expect(titles("delete slide 3") == ["Product launch", "The problem", "Market", "Next steps"])
            #expect(titles("remove the last slide") == ["Product launch", "The problem", "The solution", "Market"])
            #expect(titles("delete this slide", selected: 1) == ["Product launch", "The solution", "Market", "Next steps"])
            #expect(titles("delete the slide about the market") == ["Product launch", "The problem", "The solution", "Next steps"])
            #expect(titles("delete the third slide") == ["Product launch", "The problem", "Market", "Next steps"])
            #expect(titles("delete slides 2 and 4") == ["Product launch", "The solution", "Next steps"])
            #expect(titles("move slide 2 after slide 4") == ["Product launch", "The solution", "Market", "The problem", "Next steps"])
            #expect(titles("move slide 5 to the beginning") == ["Next steps", "Product launch", "The problem", "The solution", "Market"])
            #expect(titles("change the title of slide 2 to \"Why now\"")?[1] == "Why now")
            #expect(Assistant.quickDeckEdit("change the title of slide 2 to \"Why now\"", deck: deck, selected: nil)?.summary == "I changed the title of slide 2 to “Why now”.")
            #expect(Assistant.quickDeckEdit("delete slide 3", deck: deck, selected: nil)?.summary == "I deleted slide 3 “The solution”.")
            // La slide nuova la scrive il modello; dove metterla lo dice la richiesta ("after the market one" = dopo la slide 4).
            #expect(Assistant.quickDeckEdit("add a slide about costs after the market one", deck: deck, selected: nil) == nil)
            #expect(Assistant.slideAnchor("add a slide about costs after the market one", deck: deck, selected: nil) == 3)
            #expect(Assistant.slideAnchor("add a slide about costs at the end", deck: deck, selected: nil) == 4)
            #expect(deck.numbered(selected: 1).contains("2. The problem [selected]"))
        }
        // Comando italiano con la presentazione inglese: le slide si cercano con i loro titoli.
        italian {
            #expect(titles("elimina la slide Market") == ["Product launch", "The problem", "The solution", "Next steps"])
            #expect(Assistant.quickDeckEdit("elimina la slide 3", deck: deck, selected: nil)?.summary == "Ho eliminato la slide 3 «The solution».")
        }
    }

    func sheet() -> Sheet {
        Evaluation.testSheet("""
        Item | October | November | Total
        Flight | 180 | 0 | 0
        Hotel | 420 | 0 | 0
        Food | 150 | 60 | 0
        Total | 0 | 0 | 0
        """)
    }

    @Test func sheets() {
        english {
            let table = sheet()
            #expect(table.totalRowIndex == 4 && table.totalColumnIndex == 3)
            #expect(table.display(CellRef("B5")!) == "750" && table.display(CellRef("D5")!) == "810")
            // Riga nuova sopra il totale, nella colonna detta: la somma la comprende.
            var insured = sheet()
            let row = Assistant.quickSheetEdit("add a row for insurance, 45 euros in October", sheet: insured)
            insured.apply(row?.operations ?? [])
            #expect(insured.display(CellRef("A5")!) == "Insurance" && insured.display(CellRef("B5")!) == "45" && insured.display(CellRef("C5")!) == "")
            #expect(insured.display(CellRef("D5")!) == "45" && insured.display(CellRef("B6")!) == "795")
            #expect(row?.summary == "I added the row “Insurance”; the totals have been updated.")
            var two = sheet()
            two.apply(Assistant.quickSheetEdit("add a row for car rental: 120 in October and 80 in November", sheet: two)?.operations ?? [])
            #expect(two.display(CellRef("A5")!) == "Car rental" && two.display(CellRef("C5")!) == "80" && two.display(CellRef("D6")!) == "1,010")
            // Righe che il codice non sa leggere da solo vanno al modello.
            #expect(Assistant.quickSheetEdit("add a row for insurance at the top", sheet: sheet()) == nil)
            // Eliminare una riga aggiorna i totali.
            var without = sheet()
            without.apply(Assistant.quickSheetEdit("delete the food row", sheet: sheet())?.operations ?? [])
            #expect(without.display(CellRef("A4")!) == "Total" && without.display(CellRef("B4")!) == "600")
            // Raddoppiare o aumentare una voce cambia solo i numeri scritti, non le formule.
            var doubled = sheet()
            doubled.apply(Assistant.quickSheetEdit("double the hotel cost", sheet: sheet())?.operations ?? [])
            #expect(doubled.display(CellRef("B3")!) == "840" && doubled.display(CellRef("B5")!) == "1,170")
            var raised = sheet()
            raised.apply(Assistant.quickSheetEdit("increase the flight cost by 10%", sheet: sheet())?.operations ?? [])
            #expect(raised.display(CellRef("B2")!) == "198")
            #expect(Assistant.quickSheetEdit("create a pie chart of the expenses", sheet: sheet())?.operations == [.addChart(.pie, range: "A1:B4")])
            #expect(Assistant.quickSheetEdit("create a pie chart of the expenses", sheet: sheet())?.summary == "I added a pie chart.")
            #expect(Assistant.quickSheetEdit("delete the October column", sheet: sheet())?.operations == [.deleteColumn(1)])
            #expect(table.described().hasPrefix("Columns: A=Item, B=October, C=November, D=Total\nRow 2: Flight | 180 | 0 | =SOMMA(B2:C2) (180)"))
        }
    }

    @Test func numbersAndFormulas() {
        english {
            #expect(FormulaEngine.literal("1,500") == .number(1500))
            #expect(FormulaEngine.literal("1,234.5") == .number(1234.5))
            #expect(FormulaEngine.literal("$30") == .number(30))
            #expect(FormulaEngine.literal("12.5%") == .number(0.125))
            #expect(FormulaEngine.literal("TRUE") == .bool(true))
            #expect(FormulaEngine.format(1234.5) == "1,234.5")
            #expect(CellValue.bool(false).display == "FALSE")
            #expect(FormulaEngine.evaluate("=FOO(1)", in: [:]).display == "#NAME?")
            let cells = ["A1": "10", "A2": "20", "A3": "=SUM(A1:A2)", "A4": "=AVERAGE(A1:A2)", "A5": "=IF(A3>25,\"high\",\"low\")",
                         "A6": "=ROUND(1.26,1)", "A7": "=SOMMA(A1:A2)", "A8": "=A1>5"]
            #expect(FormulaEngine.value(of: CellRef("A3")!, in: cells) == .number(30))
            #expect(FormulaEngine.value(of: CellRef("A4")!, in: cells) == .number(15))
            #expect(FormulaEngine.value(of: CellRef("A5")!, in: cells) == .text("high"))
            #expect(FormulaEngine.value(of: CellRef("A6")!, in: cells) == .number(1.3))
            #expect(FormulaEngine.value(of: CellRef("A7")!, in: cells) == .number(30))
            #expect(FormulaEngine.value(of: CellRef("A8")!, in: cells).display == "TRUE")
            #expect(CellFormat.currency.format(.number(1234.5)) == "€1,234.50")
            #expect(CellFormat.currency.label == "Currency (€)" && DeckTheme.chiaro.label == "Light" && SlideLayout.vuota.label == "Blank")
            // Un foglio nuovo in inglese: intestazioni, totali e formule in inglese.
            let spreadsheet = Spreadsheet(from: SheetDraft(title: "Trip", columns: ["October", "November"], rows: [.init(label: "Flight", values: [180, 20])]))
            let made = spreadsheet.sheets[0]
            #expect(made.name == "Sheet 1" && made.raw(CellRef("A1")!) == "Item" && made.raw(CellRef("D1")!) == "Total" && made.raw(CellRef("A3")!) == "Total")
            #expect(made.raw(CellRef("D2")!) == "=SUM(B2:C2)" && made.display(CellRef("D3")!) == "200" && made.totalRowIndex == 2)
        }
        // In italiano resta tutto com'era.
        italian {
            #expect(FormulaEngine.literal("1,500") == .number(1.5))
            #expect(FormulaEngine.format(1234.5) == "1234,5")
            #expect(CellValue.bool(false).display == "FALSO")
            #expect(FormulaEngine.evaluate("=FOO(1)", in: [:]).display == "#NOME?")
            #expect(CellFormat.currency.label == "Valuta (€)")
            let made = Spreadsheet(from: SheetDraft(title: "Viaggio", columns: ["Ottobre"], rows: [.init(label: "Volo", values: [180])])).sheets[0]
            #expect(made.name == "Foglio 1" && made.raw(CellRef("A1")!) == "Voce" && made.raw(CellRef("C2")!) == "=SOMMA(B2:B2)")
        }
    }
}
