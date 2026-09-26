import AppKit
import Foundation
import FoundationModels

// MARK: - Documento aperto visto dal motore

/// Il documento aperto al centro: paragrafi con il loro stile. Il testo con gli attributi (font, immagini, link) resta
/// nell'app, che applica le operazioni senza toccare i paragrafi che non cambiano.
public struct DocumentOutline: Sendable, Equatable {
    public enum Style: String, Sendable, CaseIterable {
        case titolo, sottotitolo, intestazione, sottointestazione, testo, didascalia

        public var isHeading: Bool { self == .intestazione || self == .sottointestazione }
        public var isTitle: Bool { self == .titolo || self == .sottotitolo }
        /// Livello per le sezioni: il titolo chiude tutto, l'intestazione le sotto-intestazioni.
        var level: Int {
            switch self {
            case .titolo, .sottotitolo: 0
            case .intestazione: 1
            case .sottointestazione: 2
            case .testo, .didascalia: 3
            }
        }
    }

    public struct Paragraph: Sendable, Equatable {
        public var text: String
        public var style: Style
        public var format: TextFormat?

        public init(_ text: String, _ style: Style = .testo, format: TextFormat? = nil) {
            self.text = text; self.style = style; self.format = format
        }
    }

    public var paragraphs: [Paragraph]
    /// Paragrafi toccati dalla selezione nell'editor e testo selezionato (vuoti se non c'è selezione).
    public var selected: [Int]
    public var selectedText: String?
    /// Paragrafo in cui sta il cursore.
    public var cursor: Int?

    public init(paragraphs: [Paragraph], selected: [Int] = [], selectedText: String? = nil, cursor: Int? = nil) {
        self.paragraphs = paragraphs; self.selected = selected; self.selectedText = selectedText; self.cursor = cursor
    }

    /// Da testo semplice: "# " titolo, "## " intestazione; senza segni, prima riga titolo e righe brevi senza punto finale intestazioni.
    public init(plain: String) {
        let lines = plain.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let marked = lines.contains { $0.hasPrefix("#") }
        paragraphs = lines.enumerated().map { index, line in
            if line.hasPrefix("## ") { return Paragraph(String(line.dropFirst(3)), .intestazione) }
            if line.hasPrefix("# ") { return Paragraph(String(line.dropFirst(2)), .titolo) }
            if marked { return Paragraph(line, .testo) }
            if index == 0 { return Paragraph(line, .titolo) }
            let short = line.count < 60 && !line.hasSuffix(".") && !line.hasSuffix(":")
            return Paragraph(line, short ? .intestazione : .testo)
        }
        selected = []
        selectedText = nil
        cursor = nil
    }

    public var plainText: String { paragraphs.map(\.text).joined(separator: "\n") }

    /// Testo con i segni dello stile ("# titolo", "## intestazione", "**grassetto**"): per valutazioni e confronti.
    public func rendered() -> String {
        paragraphs.map { paragraph in
            var text = paragraph.text
            switch paragraph.format {
            case .grassetto?: text = "**\(text)**"
            case .corsivo?: text = "_\(text)_"
            case .sottolineato?: text = "<u>\(text)</u>"
            default: break
            }
            switch paragraph.style {
            case .titolo: return "# " + text
            case .intestazione: return "## " + text
            case .sottointestazione: return "### " + text
            default: return text
            }
        }.joined(separator: "\n")
    }

    public var titleIndex: Int? { paragraphs.firstIndex { $0.style == .titolo } }
    public var headingIndices: [Int] { paragraphs.indices.filter { paragraphs[$0].style.isHeading } }
    public var bodyIndices: [Int] { paragraphs.indices.filter { !paragraphs[$0].style.isHeading && !paragraphs[$0].style.isTitle } }

    /// Fine (esclusa) della sezione che comincia con l'intestazione `heading`: fino alla prossima intestazione di pari livello o superiore.
    public func sectionEnd(after heading: Int) -> Int {
        guard paragraphs.indices.contains(heading) else { return heading + 1 }
        let level = paragraphs[heading].style.level
        var index = heading + 1
        while index < paragraphs.count, paragraphs[index].style.level > level { index += 1 }
        return index
    }

    /// Intestazione che corrisponde meglio a un nome ("rischi", "la sezione sul budget").
    public func heading(matching name: String) -> Int? {
        let wanted = DocumentOutline.words(name)
        guard !wanted.isEmpty else { return nil }
        let scored = headingIndices.map { index -> (Int, Int) in
            let words = DocumentOutline.words(paragraphs[index].text)
            let key = paragraphs[index].text.lowercased()
            let contains = key.contains(name.lowercased()) || name.lowercased().contains(key) ? 3 : 0
            return (index, words.intersection(wanted).count * 2 + contains)
        }
        return scored.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
            .map { $0.count > 5 ? String($0.prefix(5)) : $0 })
    }

    /// Paragrafi numerati per il modello, entro un numero di caratteri: quelli lunghi sono accorciati con "…".
    func numbered(characters: Int) -> (text: String, truncated: Set<Int>) {
        let share = max(80, characters / max(1, paragraphs.count))
        var truncated = Set<Int>()
        let lines = paragraphs.enumerated().map { index, paragraph -> String in
            var text = paragraph.text
            if text.count > max(share, 160) {
                text = String(text.prefix(max(share, 160))) + "…"
                truncated.insert(index)
            }
            let marks = (selected.contains(index) ? " [selezionato]" : "") + (cursor == index && selected.isEmpty ? " [cursore]" : "")
            return "[P\(index + 1)] (\(paragraph.style.rawValue))\(marks) \(text)"
        }
        return (lines.joined(separator: "\n"), truncated)
    }
}

public enum TextFormat: String, Sendable, CaseIterable {
    case grassetto, corsivo, sottolineato, normale
}

/// Una modifica al documento. Gli indici si riferiscono ai paragrafi del documento prima della modifica.
public enum DocumentOperation: Sendable, Equatable {
    /// Nuovo testo del paragrafo, stesso stile.
    case replace(Int, String)
    /// Paragrafi nuovi dopo il paragrafo indicato (-1 = all'inizio).
    case insert(after: Int, [DocumentOutline.Paragraph])
    case delete([Int])
    case restyle([Int], DocumentOutline.Style)
    case format([Int], TextFormat)
    /// Tutto il contenuto sostituito (vuoto = documento svuotato).
    case replaceAll([DocumentOutline.Paragraph])
    /// Operazioni sulla selezione dell'editor (anche parti di un paragrafo).
    case replaceSelection(String)
    case deleteSelection
    case formatSelection(TextFormat)
}

public struct DocumentEditPlan: Sendable, Equatable {
    public var operations: [DocumentOperation]
    /// Cosa è cambiato, in una frase per la chat.
    public var summary: String

    public init(operations: [DocumentOperation], summary: String) { self.operations = operations; self.summary = summary }
}

extension DocumentOutline {
    /// Applica le operazioni (indici del documento di partenza). Serve per le prove; l'app fa lo stesso sul testo con gli attributi.
    public func applying(_ operations: [DocumentOperation]) -> DocumentOutline {
        if let all = operations.last(where: { if case .replaceAll = $0 { true } else { false } }), case .replaceAll(let paragraphs) = all {
            return DocumentOutline(paragraphs: paragraphs)
        }
        var replaced: [Int: String] = [:]
        var deleted = Set<Int>()
        var styles: [Int: Style] = [:]
        var formats: [Int: TextFormat] = [:]
        var inserted: [Int: [Paragraph]] = [:]
        for operation in operations {
            switch operation {
            case .replace(let index, let text): replaced[index] = text
            case .insert(let after, let items): inserted[after, default: []] += items
            case .delete(let indices): deleted.formUnion(indices)
            case .restyle(let indices, let style): for index in indices { styles[index] = style }
            case .format(let indices, let format): for index in indices { formats[index] = format }
            case .replaceSelection(let text):
                if let first = selected.first { replaced[first] = text; deleted.formUnion(selected.dropFirst()) }
            case .deleteSelection: deleted.formUnion(selected)
            case .formatSelection(let format): for index in selected { formats[index] = format }
            case .replaceAll: break
            }
        }
        var result: [Paragraph] = inserted[-1] ?? []
        for (index, paragraph) in paragraphs.enumerated() {
            if !deleted.contains(index) {
                var copy = paragraph
                if let text = replaced[index] { copy.text = text }
                if let style = styles[index] { copy.style = style }
                if let format = formats[index] { copy.format = format == .normale ? nil : format }
                result.append(copy)
            }
            result += inserted[index] ?? []
        }
        return DocumentOutline(paragraphs: result)
    }
}

// MARK: - Riconoscimento dei comandi

extension Assistant {
    /// Verbi che chiedono di cambiare ciò che è aperto al centro.
    static let editVerbs = ["cancella", "elimina", "svuota", "togli", "rimuovi", "pulisci", "scrivi", "scrivici", "aggiungi", "inserisci", "metti",
                            "sostituisci", "rimpiazza", "modifica", "cambia", "correggi", "riscrivi", "traduci", "rendi", "accorcia", "allunga",
                            "espandi", "sposta", "rinomina", "intitola", "formatta", "sottolinea", "evidenzia", "tieni", "lascia", "mantieni",
                            "raddoppia", "dimezza", "aumenta", "diminuisci", "ordina", "somma", "unisci", "dividi", "migliora", "semplifica",
                            "aggiorna", "imposta", "crea un grafico", "fai un grafico", "duplica", "inverti", "abbrevia", "centra", "allinea"]

    /// Parole che indicano un'altra app: con queste il comando non riguarda il documento aperto.
    static let otherTargets = ["evento", "eventi", "riunion", "appuntament", "calendario", "promemoria", "email", "e-mail", " mail", " posta",
                               "messaggio", "messaggi", "imessage", "sms", "contatto", "cartella", "sul mac", "nel progetto", "sito web", "agente",
                               " call ", "meeting", "videochiamat", "alla nota", "nella nota", "sulla nota", "nelle note", "alle note"]

    /// Comando di modifica per il documento, il foglio o la presentazione aperti ("cancella tutto e scrivi…", "elimina la slide 3").
    static func isArtifactCommand(_ prompt: String) -> Bool {
        let lower = " " + prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + " "
        let start = lower.trimmingCharacters(in: .whitespaces)
        // Domande e richieste di un documento nuovo non sono modifiche.
        if start.hasSuffix("?") { return false }
        if ["nuovo documento", "nuova presentazione", "nuovo foglio", "un altro documento", "un'altra presentazione", "un altro foglio"].contains(where: lower.contains) { return false }
        guard editVerbs.contains(where: { start.hasPrefix($0) || lower.contains(" \($0) ") || lower.contains(", \($0) ") }) else { return false }
        // "Sposta la cena a sabato": spostare con un giorno o un orario riguarda il calendario.
        if start.range(of: #"^(?:sposta|anticipa|posticipa|rimanda|rinvia)\b"#, options: .regularExpression) != nil,
           !DateExpressions.days(in: start).isEmpty || !DateExpressions.times(in: start).isEmpty { return false }
        return !otherTargets.contains(where: lower.contains)
    }

    /// Domanda su ciò che è aperto ("riassumi questo documento", "cosa dice la sezione budget?"): si risponde in chat.
    static func isArtifactQuestion(_ prompt: String) -> Bool {
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let asks = ["riassumi", "riassumimi", "spiega", "spiegami", "di cosa parla", "cosa dice", "cosa c'è scritto", "analizza", "valuta",
                    "commenta", "quante parole", "quante slide", "quante righe", "qual è", "quali sono", "trova", "dimmi"]
        let target = ["documento", "testo", "presentazione", "slide", "foglio", "tabella", "sezione", "paragrafo", "questo", "questa", "qui"]
        let changes = ["aggiungi", "scrivi nel", "inserisci", "metti", "nel documento un", "in fondo"]
        return asks.contains(where: lower.hasPrefix) && target.contains(where: lower.contains) && !changes.contains(where: lower.contains)
    }

    /// Imperativo: "scrivi…", "crea…", "cancella…". A un comando non si risponde cercando sul web.
    static func isCommand(_ prompt: String) -> Bool {
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.hasSuffix("?") else { return false }
        return (editVerbs + ["crea", "creami", "fai", "fammi", "prepara", "preparami", "manda", "invia", "apri", "chiudi", "salva", "esporta",
                             "copia", "incolla", "ricordami", "fissa", "disegna", "genera"]).contains { lower.hasPrefix($0 + " ") || lower == $0 }
    }

    /// "Mi crei un documento dove c'è scritto hello world": il testo da mettere così com'è (nil = documento da scrivere su un argomento).
    public static func literalDocumentText(_ prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        let lower = trimmed.lowercased()
        guard ["documento", "pagina", "file di testo", "pages", "foglio di testo"].contains(where: lower.contains) else { return nil }
        if lower.range(of: #"\b(documento|pagina)\s+(vuot[oa]|bianc[oa])\b"#, options: .regularExpression) != nil { return "" }
        let markers = #"(?:dove c'è scritto|dove c’è scritto|in cui c'è scritto|con scritto|con su scritto|con la scritta|con il testo|con testo|che dice|con dentro(?: scritto)?|contenente(?: il testo)?|con questo testo|con la frase|con le parole)"#
        guard let match = Calculations.matches(markers + #"\s*:?\s*(.+)$"#, in: trimmed).first else { return nil }
        let text = unquoted(match[1])
        return text.isEmpty ? nil : text
    }

    /// Testo senza virgolette intorno.
    static func unquoted(_ text: String) -> String {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("«", "»"), ("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]
        for (open, close) in pairs where clean.count >= 2 && clean.first == open && clean.last == close {
            clean = String(clean.dropFirst().dropLast())
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Testo citato nella richiesta («…», "…", “…”), se c'è.
    static func quoted(_ text: String) -> String? {
        Calculations.matches(#"«([^»]+)»|“([^”]+)”|"([^"]+)""#, in: text).first.flatMap { $0.dropFirst().first { !$0.isEmpty } }
    }

    // MARK: Comandi sul documento che non hanno bisogno del modello

    /// I comandi più comuni, riconosciuti con regole: nessun errore di interpretazione e nessuna attesa.
    public static func quickDocumentEdit(_ instruction: String, outline: DocumentOutline) -> DocumentEditPlan? {
        let prompt = instruction.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        let lower = prompt.lowercased()
        let quote = quoted(prompt)
        /// Testo dopo il primo dei segnali indicati (provati in ordine), o tra virgolette.
        func literal(after patterns: String...) -> String? {
            if let quote { return quote }
            for pattern in patterns {
                guard let match = Calculations.matches(pattern + #"\s*:?\s*(.+)$"#, in: prompt).first else { continue }
                let text = unquoted(match[1])
                if !text.isEmpty { return text }
            }
            return nil
        }
        let writeMarkers = #"(?:con scritto|con su scritto|con la scritta|che dice|scrivendo|scrivici|scrivi|metti(?:ci)?|inserisci|lascia(?:ci)?)"#

        // 1. Tenere solo il titolo / cancellare il corpo, eventualmente cambiando il titolo ("tieni solo il titolo con scritto Hello Ivan").
        let keepTitle = lower.range(of: #"(tien|ten|lasci|manten)\w*\s+(solo|soltanto|solamente)\s+(il\s+)?titolo"#, options: .regularExpression) != nil
        let clearBody = lower.range(of: #"^(cancella|elimina|togli|rimuovi|svuota|pulisci)\s+(tutto\s+)?(il\s+|l'\s*)?(corpo|resto|testo sotto|contenuto sotto)"#, options: .regularExpression) != nil
        if keepTitle || clearBody {
            let keep: Set<DocumentOutline.Style> = keepTitle ? [.titolo] : [.titolo, .sottotitolo]
            var operations: [DocumentOperation] = []
            let removed = outline.paragraphs.indices.filter { !keep.contains(outline.paragraphs[$0].style) }
            if !removed.isEmpty { operations.append(.delete(removed)) }
            var summary = keepTitle ? "Ho lasciato solo il titolo" : "Ho cancellato il testo sotto il titolo"
            // "Tenendo solo il titolo con scritto X": X è il titolo. "Cancella il corpo e scrivi X": X è il testo nuovo.
            if keepTitle, let title = literal(after: #"(?:con scritto|con su scritto|con la scritta|che dice|cambiandolo in|chiamandolo|scrivendo)"#,
                                              #"titolo\s+(?:in|a|con|:)"#), !title.lowercased().hasPrefix("titolo") {
                if let index = outline.titleIndex { operations.append(.replace(index, title)) } else { operations.append(.insert(after: -1, [.init(title, .titolo)])) }
                summary += " e l'ho cambiato in «\(title)»"
            } else if clearBody, let text = literal(after: #"(?:,|\be\b|\bpoi\b)\s*"# + writeMarkers) {
                let after = outline.paragraphs.lastIndex { keep.contains($0.style) } ?? -1
                operations.append(.insert(after: after, [.init(text, .testo)]))
                summary += " e ho scritto «\(text)»"
            }
            if outline.titleIndex == nil, keepTitle, operations.isEmpty { return nil }
            let removedText = removed.count == 1 ? "1 paragrafo tolto" : "\(removed.count) paragrafi tolti"
            return DocumentEditPlan(operations: operations, summary: summary + (removed.isEmpty ? "." : " (\(removedText))."))
        }

        // 2. Svuotare tutto, eventualmente scrivendo un testo nuovo ("cancella tutto e scrivi hello world").
        // Solo "tutto" o "il testo" da soli (o seguiti da "e scrivi…"): "cancella il testo del secondo paragrafo" è un'altra cosa.
        let clearAll = lower.range(of: #"^(cancella|svuota|pulisci|elimina|togli|rimuovi)\s+(tutto(\s+quanto)?|tutto il (testo|contenuto|documento)|il (testo|contenuto)|l'intero (testo|documento|contenuto))\s*($|,|\be\b|\bpoi\b)"#, options: .regularExpression) != nil
            || lower.range(of: #"^svuota\s+(il|questo)\s+documento\s*($|,|\be\b)"#, options: .regularExpression) != nil
        if clearAll, !["tranne", "eccetto", "meno il", "selezion"].contains(where: lower.contains) {
            if let text = literal(after: #"(?:,|\be\b|\bpoi\b)\s*"# + writeMarkers + #"(?:\s+solo)?"#) {
                return DocumentEditPlan(operations: [.replaceAll([.init(text, .testo)])], summary: "Ho cancellato tutto e scritto «\(text)».")
            }
            return DocumentEditPlan(operations: [.replaceAll([])], summary: "Ho svuotato il documento.")
        }
        // "Sostituisci tutto con X", "scrivi solo X", "lascia solo X".
        if let match = Calculations.matches(#"^(?:sostituisci|rimpiazza)\s+tutto(?:\s+il\s+(?:testo|contenuto))?\s+con\s+(.+)$"#, in: prompt).first
            ?? Calculations.matches(#"^(?:scrivi|metti|lascia)\s+solo\s+(.+)$"#, in: prompt).first {
            let text = unquoted(match[1])
            guard !text.isEmpty, !text.lowercased().hasPrefix("il titolo") else { return nil }
            return DocumentEditPlan(operations: [.replaceAll([.init(text, .testo)])], summary: "Ho sostituito tutto con «\(text)».")
        }

        // 3. Titolo nuovo ("cambia il titolo in «Piano 2027»", "intitolalo Hello").
        if let match = Calculations.matches(#"^(?:cambia|modifica|metti|imposta|rinomina|aggiorna|sostituisci)\s+(?:il\s+)?titolo(?:\s+del\s+documento)?\s*(?:in|con|a|come|:)?\s+(.+)$"#, in: prompt).first
            ?? Calculations.matches(#"^(?:intitola(?:lo)?|chiamalo|dagli come titolo|metti come titolo)\s*:?\s+(.+)$"#, in: prompt).first {
            let title = unquoted(match[1])
            // "Cambia il titolo della sezione Budget in…": non è il titolo del documento.
            guard !title.isEmpty, title.lowercased().range(of: #"^(della|del|dello|dei|delle|degli|di)\s"#, options: .regularExpression) == nil else { return nil }
            if let index = outline.titleIndex {
                return DocumentEditPlan(operations: [.replace(index, title)], summary: "Ho cambiato il titolo in «\(title)».")
            }
            return DocumentEditPlan(operations: [.insert(after: -1, [.init(title, .titolo)])], summary: "Ho aggiunto il titolo «\(title)».")
        }

        // 4. Via titolo o sottotitolo.
        if let match = Calculations.matches(#"^(?:cancella|elimina|togli|rimuovi)\s+(?:il\s+)?(sottotitolo|titolo)$"#, in: prompt).first {
            let style: DocumentOutline.Style = match[1].lowercased() == "titolo" ? .titolo : .sottotitolo
            let indices = outline.paragraphs.indices.filter { outline.paragraphs[$0].style == style }
            guard !indices.isEmpty else { return nil }
            return DocumentEditPlan(operations: [.delete(indices)], summary: "Ho tolto il \(match[1].lowercased()).")
        }

        // 5. Via una sezione intera ("elimina la sezione Rischi").
        if let match = Calculations.matches(#"^(?:cancella|elimina|togli|rimuovi)\s+(?:tutta\s+)?(?:la\s+)?(?:sezione|parte|capitolo)\s+(?:su\s+|sui\s+|sul\s+|sulla\s+|sugli\s+|dei\s+|del\s+|della\s+|delle\s+|di\s+|intitolata\s+)?(.+)$"#, in: prompt).first,
           let heading = outline.heading(matching: unquoted(match[1])) {
            let end = outline.sectionEnd(after: heading)
            return DocumentEditPlan(operations: [.delete(Array(heading..<end))],
                                    summary: "Ho eliminato la sezione «\(outline.paragraphs[heading].text)» (\(end - heading) paragrafi).")
        }

        // 6. Via un paragrafo per posizione ("elimina il secondo paragrafo", "cancella l'ultimo paragrafo").
        let ordinals = ["primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6, "settimo": 7, "ottavo": 8, "nono": 9, "decimo": 10]
        if let match = Calculations.matches(#"^(?:cancella|elimina|togli|rimuovi)\s+(?:il\s+|l'\s*)?(primo|secondo|terzo|quarto|quinto|sesto|settimo|ottavo|nono|decimo|ultimo|penultimo|\d+)[°º]?\s+paragrafo$"#, in: prompt).first
            ?? Calculations.matches(#"^(?:cancella|elimina|togli|rimuovi)\s+(?:il\s+)?paragrafo\s+(\d+)$"#, in: prompt).first {
            let body = outline.bodyIndices
            let word = match[1].lowercased()
            let position: Int? = word == "ultimo" ? body.count : word == "penultimo" ? body.count - 1 : ordinals[word] ?? Int(word)
            guard let position, position >= 1, position <= body.count else { return nil }
            return DocumentEditPlan(operations: [.delete([body[position - 1]])], summary: "Ho eliminato il paragrafo \(position).")
        }

        // 7. Selezione dell'editor: cancellare o formattare "questo".
        let selectionWords = #"(?:questo|questa|questa parte|questo pezzo|la selezione|il testo selezionato|quello selezionato|ciò che ho selezionato|il selezionato)"#
        if outline.selectedText?.isEmpty == false {
            if lower.range(of: #"^(cancella|elimina|togli|rimuovi)\s+"# + selectionWords + #"$"#, options: .regularExpression) != nil {
                return DocumentEditPlan(operations: [.deleteSelection], summary: "Ho cancellato il testo selezionato.")
            }
        }

        // 8. Formattazione di titoli, intestazioni, tutto o selezione ("metti in grassetto i titoli delle sezioni").
        if let match = Calculations.matches(#"^(?:metti|rendi|fai|scrivi)\s+(?:in\s+)?(grassetto|corsivo)\s+(.+)$"#, in: prompt).first
            ?? Calculations.matches(#"^(sottolinea|evidenzia)\s+(.+)$"#, in: prompt).first {
            let format: TextFormat = match[1].lowercased() == "corsivo" ? .corsivo : match[1].lowercased() == "grassetto" ? .grassetto : .sottolineato
            let target = match[2].lowercased()
            let name = format == .grassetto ? "in grassetto" : format == .corsivo ? "in corsivo" : "sottolineato"
            if target.range(of: #"^(i titoli|le intestazioni|tutti i titoli|tutte le intestazioni|i titoli delle sezioni|le intestazioni delle sezioni|i sottotitoli delle sezioni)"#, options: .regularExpression) != nil {
                let indices = outline.headingIndices
                guard !indices.isEmpty else { return nil }
                return DocumentEditPlan(operations: [.format(indices, format)],
                                        summary: indices.count == 1 ? "Ho messo \(name) l'intestazione." : "Ho messo \(name) \(indices.count) intestazioni.")
            }
            if target.range(of: #"^il titolo( del documento)?$"#, options: .regularExpression) != nil, let index = outline.titleIndex {
                return DocumentEditPlan(operations: [.format([index], format)], summary: "Ho messo \(name) il titolo.")
            }
            if target.range(of: #"^(tutto|tutto il testo|il documento|l'intero documento)$"#, options: .regularExpression) != nil {
                return DocumentEditPlan(operations: [.format(Array(outline.paragraphs.indices), format)], summary: "Ho messo \(name) tutto il testo.")
            }
            if target.range(of: "^" + selectionWords, options: .regularExpression) != nil, outline.selectedText?.isEmpty == false {
                return DocumentEditPlan(operations: [.formatSelection(format)], summary: "Ho messo \(name) il testo selezionato.")
            }
        }

        // 9. Scrivere un testo così com'è ("scrivi hello world", "aggiungi «grazie a tutti» in fondo").
        if let match = Calculations.matches(#"^(?:scrivi|scrivici|aggiungi|inserisci|metti)\s+(?:(in fondo|alla fine|all'inizio|in cima|dopo il titolo|sotto il titolo)\s+)?:?\s*(.+?)(?:\s+(in fondo|alla fine|all'inizio|in cima|dopo il titolo|sotto il titolo))?$"#, in: prompt).first {
            var text = unquoted(match[2])
            let place = (match[1].isEmpty ? match[3] : match[1]).lowercased()
            // "Aggiungi una sezione su…", "scrivi un paragrafo sui rischi": contenuto da scrivere, non testo da copiare.
            let generative = #"^(una?|uno|dei|degli|delle|qualche|altri|altre|due|tre|il|la|lo|le|i|gli|l')\s+"#
            let composing = text.lowercased().range(of: generative, options: .regularExpression) != nil && quote == nil
            guard !composing, !text.isEmpty, quote != nil || text.split(separator: " ").count <= 15 else { return nil }
            if let quote { text = quote }
            let paragraph = DocumentOutline.Paragraph(text, .testo)
            switch place {
            case "all'inizio", "in cima", "dopo il titolo", "sotto il titolo":
                let after = outline.paragraphs.lastIndex { $0.style.isTitle } ?? -1
                return DocumentEditPlan(operations: [.insert(after: after, [paragraph])], summary: "Ho scritto «\(text)» all'inizio.")
            default:
                return DocumentEditPlan(operations: [.insert(after: outline.paragraphs.count - 1, [paragraph])], summary: "Ho scritto «\(text)» in fondo.")
            }
        }
        return nil
    }
}

// MARK: - Modifiche con il modello

extension Assistant {
    private static let documentEditSchema = makeSchema("ModificheDocumento", [
        .required("operazioni", .array(.object("Operazione", [
            .required("tipo", .choice(["sostituisci", "inserisci_dopo", "elimina", "stile", "formato"]),
                      "sostituisci il testo di un paragrafo; inserisci_dopo un paragrafo nuovo; elimina un paragrafo; stile per cambiarne il tipo; formato per grassetto, corsivo, sottolineato"),
            .required("paragrafo", .int, "Numero del paragrafo [P…] su cui agire; 0 per inserire all'inizio"),
            .optional("testo", .string, "Testo nuovo completo, per sostituisci e inserisci_dopo"),
            .optional("stile", .choice(["titolo", "sottotitolo", "intestazione", "testo"]), "Stile del paragrafo nuovo o modificato"),
            .optional("formato", .choice(["grassetto", "corsivo", "sottolineato", "normale"]), "Formato da applicare"),
        ]), min: 1, max: 12), "Operazioni da applicare, solo sui paragrafi da cambiare"),
    ])

    private static let paragraphSchema = makeSchema("Paragrafo", [.required("testo", .string, "Il testo risultante, completo")])

    /// Modifica del documento aperto: prima i comandi riconosciuti con regole, poi le trasformazioni di tutto il testo
    /// (paragrafo per paragrafo, niente viene tagliato), infine le operazioni mirate scelte dal modello sui paragrafi numerati.
    public func planDocumentEdit(_ instruction: String, outline: DocumentOutline,
                                 status: @escaping @MainActor (String) -> Void = { _ in }) async throws -> DocumentEditPlan {
        if let quick = Self.quickDocumentEdit(instruction, outline: outline) {
            Agent.log("MODIFICA DOCUMENTO (regole): \(quick.summary)")
            return quick
        }
        let lower = instruction.lowercased()
        // Selezione nell'editor: "traduci questo", "riscrivi questa parte", "rendi più formale la selezione".
        if let selected = outline.selectedText, !selected.isEmpty,
           [" questo", " questa", "la selezione", "selezionat", "questa parte", "questo pezzo"].contains(where: (" " + lower).contains) {
            status("Riscrivo il testo selezionato…")
            let text = try await rewriteParagraph(selected, instruction: instruction)
            return DocumentEditPlan(operations: [.replaceSelection(text)], summary: "Ho modificato il testo selezionato.")
        }
        // Trasformazioni di tutto il documento: un paragrafo alla volta, così anche i documenti lunghi restano interi.
        if let targets = Self.globalTargets(lower, outline: outline) {
            var operations: [DocumentOperation] = []
            // Refusi: sempre parola per parola con il correttore (sicuro); il resto, con il modello scelto, in una sola richiesta.
            let spellingOnly = (lower.contains("corregg") || lower.contains("refus") || lower.contains("errori")) && !lower.contains("grammatic")
            if !spellingOnly, let rewritten = await rewriteInBatch(targets, outline: outline, instruction: instruction, status: status) {
                for index in targets {
                    guard let text = rewritten[index] else { continue }
                    let original = outline.paragraphs[index].text
                    if text != original, Self.plausibleRewrite(original, text, instruction: lower) { operations.append(.replace(index, text)) }
                }
                let summary = operations.isEmpty ? "Non ho trovato niente da cambiare." : "Ho modificato \(operations.count) paragrafi su \(targets.count)."
                return DocumentEditPlan(operations: operations, summary: summary)
            }
            for (position, index) in targets.enumerated() {
                try Task.checkCancellation()
                status("Modifico il paragrafo \(position + 1) di \(targets.count)…")
                let original = outline.paragraphs[index].text
                let text = try await rewriteParagraph(original, instruction: instruction)
                if text != original, Self.plausibleRewrite(original, text, instruction: lower) { operations.append(.replace(index, text)) }
            }
            let summary = operations.isEmpty ? "Non ho trovato niente da cambiare." : "Ho modificato \(operations.count) paragrafi su \(targets.count)."
            return DocumentEditPlan(operations: operations, summary: summary)
        }
        // Operazioni mirate scelte dal modello sui paragrafi numerati.
        status("Scelgo cosa cambiare nel documento…")
        let (numbered, truncated) = outline.numbered(characters: budget.scaled(2600))
        let session = LanguageModelSession(model: Agent.model, instructions: """
        Modifichi un documento aperto nell'editor. Ricevi i paragrafi numerati [P1], [P2]… con il loro stile e una richiesta.
        Restituisci solo le operazioni necessarie, sui paragrafi da cambiare: tutto il resto del documento resta com'è.
        - Per cambiare un paragrafo usa sostituisci con il testo nuovo completo.
        - Per aggiungere una sezione usa inserisci_dopo: un paragrafo con stile intestazione e poi uno o più paragrafi con stile testo.
        - Per togliere una sezione elimina la sua intestazione e i suoi paragrafi.
        - «Questo» o «qui» indicano i paragrafi segnati [selezionato] o [cursore].
        Scrivi in italiano, salvo che la richiesta chieda un'altra lingua.
        """)
        let content = try await session.respond(to: "Documento:\n\(numbered)\n\nRichiesta: \(instruction)", schema: Self.documentEditSchema,
                                                options: GenerationOptions(temperature: 0.2)).content
        var operations: [DocumentOperation] = []
        var inserts: [Int: [DocumentOutline.Paragraph]] = [:]
        var insertOrder: [Int] = []
        var rewritten = Set<Int>()
        // Trasformazioni ("traduci", "rendi più formale"): il modello indica dove, il testo lo riscrive il codice paragrafo per paragrafo.
        let transforming = ["traduci", "riscrivi", "rendi", "correggi", "accorcia", "abbrevia", "allunga", "espandi", "semplifica", "migliora",
                            "trasforma", "riassumi"].contains(where: lower.hasPrefix)
        let aboutHeadings = ["titolo", "intestazion", "nome della sezione"].contains(where: lower.contains)
        // Posizione scritta nella richiesta ("dopo gli obiettivi", "prima delle conclusioni"): vale più di quella scelta dal modello.
        let anchorFromText = Self.insertionAnchor(lower, outline: outline)
        for item in content.objects("operazioni") {
            guard let kind = item.string("tipo"), let number = item.int("paragrafo") else { continue }
            let index = number - 1
            let style = item.string("stile").flatMap(DocumentOutline.Style.init(rawValue:))
            switch kind {
            case "sostituisci":
                guard outline.paragraphs.indices.contains(index) else { continue }
                // Un'intestazione indicata per una trasformazione del testo vuol dire il testo della sua sezione.
                let targets = transforming && outline.paragraphs[index].style.isHeading && !aboutHeadings
                    ? Array((index + 1)..<outline.sectionEnd(after: index)) : [index]
                for target in targets where !rewritten.contains(target) {
                    rewritten.insert(target)
                    // Con il modello scelto il testo nuovo lo scrive lui (qui Apple Intelligence ha scelto solo dove).
                    var text = transforming || targets != [index] || textWriter != nil ? "" : (item.string("testo") ?? "")
                    // Paragrafo accorciato nel prompt, testo mancante o trasformazione: si riscrive per intero, niente va perso.
                    if text.isEmpty || truncated.contains(target) {
                        status("Riscrivo il paragrafo \(target + 1)…")
                        text = try await rewriteParagraph(outline.paragraphs[target].text, instruction: instruction)
                    }
                    let parts = Self.paragraphs(from: text, style: outline.paragraphs[target].style)
                    guard let first = parts.first else { continue }
                    operations.append(.replace(target, first.text))
                    if parts.count > 1 { operations.append(.insert(after: target, Array(parts.dropFirst()))) }
                    if targets == [index], let style, style != outline.paragraphs[target].style { operations.append(.restyle([target], style)) }
                }
            case "inserisci_dopo":
                guard var text = item.string("testo"), index >= -1, index < outline.paragraphs.count else { continue }
                // Con il modello scelto la parte nuova la scrive lui; Apple Intelligence ha deciso dove metterla.
                if textWriter != nil {
                    status("\(textWriterName ?? "Il modello") scrive la parte nuova…")
                    let apple = text
                    text = (try? await compose("Scrivi il testo da inserire in un documento aperto, coerente con il resto e con lo stesso tono. Restituisci solo il testo nuovo in Markdown: «## Titolo» per il titolo di una sezione nuova, poi i paragrafi; niente commenti.",
                                               "Documento:\n\(numbered)\n\nRichiesta: \(instruction)") { apple }) ?? apple
                }
                // Dopo un'intestazione si intende dopo la sua sezione; senza una posizione nella richiesta si aggiunge in fondo
                // (il modello tende a mettere tutto all'inizio).
                var anchor = anchorFromText ?? index
                if anchorFromText == nil, outline.paragraphs.indices.contains(index), outline.paragraphs[index].style.isHeading {
                    anchor = outline.sectionEnd(after: index) - 1
                }
                if anchorFromText == nil, index == -1, lower.range(of: #"\b(inizio|cima|prima|sopra|apertura)\b"#, options: .regularExpression) == nil {
                    anchor = outline.paragraphs.count - 1
                }
                if inserts[anchor] == nil { insertOrder.append(anchor) }
                // Il modello a volte scrive Markdown ("### Titolo", righe con a capo): diventano paragrafi con il loro stile.
                // Se il documento non ha sotto-sezioni, le intestazioni nuove stanno al livello delle altre sezioni.
                let flat = !outline.paragraphs.contains { $0.style == .sottointestazione }
                inserts[anchor, default: []] += Self.paragraphs(from: text, style: style ?? .testo).map { paragraph in
                    var copy = paragraph
                    if flat, copy.style == .sottointestazione { copy.style = .intestazione }
                    // Una frase lunga o chiusa dal punto non è un'intestazione, anche se il modello la segna così.
                    if copy.style.isHeading || copy.style.isTitle, copy.text.count > 80 || copy.text.hasSuffix(".") { copy.style = .testo }
                    return copy
                }
            case "elimina":
                guard outline.paragraphs.indices.contains(index) else { continue }
                // Eliminare un'intestazione vuol dire eliminare la sua sezione.
                let end = outline.paragraphs[index].style.isHeading ? outline.sectionEnd(after: index) : index + 1
                operations.append(.delete(Array(index..<end)))
            case "stile":
                guard outline.paragraphs.indices.contains(index), let style else { continue }
                operations.append(.restyle([index], style))
            case "formato":
                guard outline.paragraphs.indices.contains(index) else { continue }
                operations.append(.format([index], item.string("formato").flatMap(TextFormat.init(rawValue:)) ?? .grassetto))
            default: continue
            }
        }
        operations += insertOrder.map { .insert(after: $0, inserts[$0] ?? []) }
        guard !operations.isEmpty else { return DocumentEditPlan(operations: [], summary: "Non ho capito cosa cambiare nel documento: prova a dirmi quale parte.") }
        return DocumentEditPlan(operations: operations, summary: Self.summarize(operations, outline: outline))
    }

    /// Riscrive un solo paragrafo secondo la richiesta (il paragrafo intero, mai un estratto).
    func rewriteParagraph(_ text: String, instruction: String) async throws -> String {
        let lower = instruction.lowercased()
        let correcting = lower.contains("corregg") || lower.contains("errori") || lower.contains("refus") || lower.contains("ortografi")
        let grammar = ["grammatic", "sintass", "punteggiatur", "concordanz", "stile", "forma "].contains(where: lower.contains)
        let flagged = correcting ? Self.spellingSuggestions(text) : []
        // Refusi: il modello sceglie solo fra i suggerimenti del correttore del Mac, il resto del paragrafo resta identico
        // (niente parole aggiunte o cambiate per sbaglio).
        if correcting, !grammar, !flagged.isEmpty {
            return await correctSpelling(text, flagged: flagged)
        }
        let role = """
        Applichi una richiesta di modifica a un solo paragrafo di un documento. Restituisci solo il paragrafo risultante, completo, \
        senza commenti. Cambia soltanto ciò che la richiesta chiede. Scrivi in italiano, salvo che la richiesta chieda un'altra lingua.
        """
        // Correzioni: le parole che il correttore del Mac non riconosce, con i suoi suggerimenti (il modello sceglie quello giusto nel contesto).
        let hints = flagged.isEmpty ? "" : "\n\nParole probabilmente sbagliate: " + flagged.map { "«\($0.word)» (forse: \($0.guesses.joined(separator: ", ")))" }.joined(separator: "; ")
        let request = "Richiesta: \(instruction)\n\nParagrafo:\n\(text.prefix(3000))\(hints)"
        // Scrive il modello scelto; se non c'è o non risponde, Apple Intelligence.
        return try await compose(role, request) {
            let options = correcting ? GenerationOptions(samplingMode: .greedy) : GenerationOptions(temperature: 0.2)
            let content = try await LanguageModelSession(model: Agent.model, instructions: role)
                .respond(to: request, schema: Self.paragraphSchema, options: options).content
            return Self.unquoted(content.string("testo") ?? text)
        }
    }

    /// Con il modello scelto (finestra grande): i paragrafi da trasformare in una sola richiesta, a blocchi, invece che uno per volta.
    /// nil se non c'è un modello scelto o la risposta non è valida: allora si procede paragrafo per paragrafo.
    func rewriteInBatch(_ targets: [Int], outline: DocumentOutline, instruction: String,
                        status: @escaping @MainActor (String) -> Void) async -> [Int: String]? {
        guard textWriter != nil else { return nil }
        var chunks: [[Int]] = [[]]
        var size = 0
        for index in targets {
            let length = outline.paragraphs[index].text.count
            if size + length > 6000, !(chunks.last ?? []).isEmpty { chunks.append([]); size = 0 }
            chunks[chunks.count - 1].append(index)
            size += length
        }
        var result: [Int: String] = [:]
        for (number, chunk) in chunks.enumerated() {
            status(chunks.count == 1 ? "\(textWriterName ?? "Il modello") riscrive il documento…" : "\(textWriterName ?? "Il modello") riscrive il documento (\(number + 1) di \(chunks.count))…")
            let paragraphs = chunk.map { "[P\($0 + 1)] \(outline.paragraphs[$0].text)" }.joined(separator: "\n\n")
            guard let json = await composeJSON("Applichi una richiesta di modifica ai paragrafi di un documento: cambi soltanto ciò che la richiesta chiede e non aggiungi commenti. Scrivi in italiano, salvo che la richiesta chieda un'altra lingua.",
                                               "Richiesta: \(instruction)\n\nParagrafi:\n\(paragraphs)",
                                               fields: "\"paragrafi\": elenco di oggetti {\"n\": numero del paragrafo senza la P, \"testo\": paragrafo modificato completo}; ometti quelli che non cambiano") else { return nil }
            for item in json.objects("paragrafi") {
                guard let number = (item["n"] as? NSNumber)?.intValue ?? item.text("n").flatMap({ Int($0.replacingOccurrences(of: "P", with: "")) }),
                      chunk.contains(number - 1), let text = item.text("testo") else { continue }
                result[number - 1] = Self.unquoted(text.replacingOccurrences(of: #"^\[P\d+\]\s*"#, with: "", options: .regularExpression))
            }
        }
        return result
    }

    /// Correzione dei refusi senza riscrivere: per ogni parola sconosciuta si sceglie un suggerimento (o si lascia com'è) e si sostituisce solo quella.
    func correctSpelling(_ text: String, flagged: [(word: String, range: NSRange, guesses: [String])]) async -> String {
        let ns = text as NSString
        let items = flagged.filter { !$0.guesses.isEmpty }
        guard !items.isEmpty else { return text }
        let fields: [Field] = items.enumerated().map { index, item in
            let from = max(0, item.range.location - 45), to = min(ns.length, NSMaxRange(item.range) + 45)
            let context = ns.substring(with: NSRange(location: from, length: to - from)).replacingOccurrences(of: "\n", with: " ")
            var choices = [item.word]
            for guess in item.guesses where !choices.contains(guess) { choices.append(guess) }
            return .required("parola\(index + 1)", .choice(choices), "Forma giusta di «\(item.word)» in: «…\(context)…»")
        }
        let session = LanguageModelSession(model: Agent.model, instructions: """
        Per ogni parola scegli la forma corretta nel contesto della frase. Se la parola è già giusta (un nome, una sigla, una parola straniera), lasciala com'è.
        """)
        guard let content = try? await session.respond(to: "Testo: \(text.prefix(1500))", schema: makeSchema("Correzioni", fields),
                                                        options: GenerationOptions(samplingMode: .greedy)).content else { return text }
        let result = NSMutableString(string: text)
        for (index, item) in items.enumerated().reversed() {
            guard var choice = content.string("parola\(index + 1)"), choice != item.word else { continue }
            // Stessa maiuscola iniziale della parola originale.
            if item.word.first?.isUppercase == true { choice = choice.prefix(1).uppercased() + choice.dropFirst() }
            result.replaceCharacters(in: item.range, with: choice)
        }
        return result as String
    }

    /// Parole sconosciute al correttore del Mac (italiano), con la posizione e i suoi suggerimenti.
    static func spellingSuggestions(_ text: String, limit: Int = 6) -> [(word: String, range: NSRange, guesses: [String])] {
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        var results: [(String, NSRange, [String])] = []
        var start = 0
        while start < ns.length, results.count < limit {
            let range = checker.checkSpelling(of: text, startingAt: start, language: "it", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            let word = ns.substring(with: range)
            let guesses = checker.guesses(forWordRange: range, in: text, language: "it", inSpellDocumentWithTag: 0) ?? []
            results.append((word, range, Array(guesses.prefix(3))))
            start = NSMaxRange(range)
        }
        return results
    }

    /// Testo scritto dal modello in paragrafi: righe separate, "#"/"##" intestazioni, "###" sotto-intestazioni, elenchi con •.
    static func paragraphs(from text: String, style: DocumentOutline.Style) -> [DocumentOutline.Paragraph] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { line in
            var clean = line.replacingOccurrences(of: "**", with: "")
            if let marks = clean.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = clean[marks].filter { $0 == "#" }.count
                clean.removeSubrange(marks)
                return DocumentOutline.Paragraph(clean, level >= 3 ? .sottointestazione : .intestazione)
            }
            if let bullet = clean.range(of: #"^[-*•]\s+"#, options: .regularExpression) { clean.replaceSubrange(bullet, with: "• ") }
            return DocumentOutline.Paragraph(clean, style)
        }
    }

    /// "Dopo gli obiettivi", "prima delle conclusioni", "in fondo", "all'inizio": dove inserire, se la richiesta lo dice.
    static func insertionAnchor(_ lower: String, outline: DocumentOutline) -> Int? {
        if lower.range(of: #"\b(in fondo|alla fine)\b"#, options: .regularExpression) != nil { return outline.paragraphs.count - 1 }
        if lower.range(of: #"\b(all'inizio|in cima)\b"#, options: .regularExpression) != nil { return outline.paragraphs.lastIndex { $0.style.isTitle } ?? -1 }
        if let match = Calculations.matches(#"\bdopo\s+(?:la sezione\s+|il paragrafo\s+|la parte\s+)?(?:su\s+|sul\s+|sulla\s+|sui\s+|sugli\s+)?(?:gli\s+|le\s+|i\s+|il\s+|la\s+|l'|lo\s+)?(.+)$"#, in: lower).first,
           let heading = outline.heading(matching: match[1]) {
            return outline.sectionEnd(after: heading) - 1
        }
        if let match = Calculations.matches(#"\bprima\s+(?:della sezione\s+|del paragrafo\s+|di\s+|della\s+|delle\s+|dei\s+|degli\s+|del\s+|dello\s+)?(?:gli\s+|le\s+|i\s+|il\s+|la\s+|l'|lo\s+)?(.+)$"#, in: lower).first,
           let heading = outline.heading(matching: match[1]) {
            return heading - 1
        }
        return nil
    }

    /// Trasformazioni di tutto il testo ("traduci il documento in inglese", "correggi gli errori", "rendi tutto più formale"):
    /// paragrafi da riscrivere uno per uno. nil se la richiesta riguarda una parte precisa.
    static func globalTargets(_ lower: String, outline: DocumentOutline) -> [Int]? {
        let verbs = ["traduci", "correggi", "riscrivi", "rendi", "semplifica", "migliora", "accorcia", "abbrevia", "allunga", "formalizza", "rivedi",
                     "espandi", "trasforma"]
        guard verbs.contains(where: lower.hasPrefix) else { return nil }
        let specific = ["paragrafo", "sezione", "titolo", "introduzion", "conclusion", "capitolo", "frase", "parola", "prima parte", "seconda parte",
                        "questo", "questa", "selezion", "sul ", "sulla ", "sui ", "sugli ", "riga", "elenco", "punto"]
        let global = ["tutto", "tutti", "intero", "il documento", "il testo", "gli errori", "i refusi", "l'ortografia", "la grammatica"]
        guard !specific.contains(where: lower.contains) || global.contains(where: lower.contains) && !lower.contains("paragrafo") && !lower.contains("sezione") else { return nil }
        let translating = lower.hasPrefix("traduci")
        let correcting = lower.hasPrefix("correggi") || lower.contains("errori") || lower.contains("refusi")
        var targets = outline.paragraphs.indices.filter { index in
            let paragraph = outline.paragraphs[index]
            guard paragraph.text.trimmingCharacters(in: .whitespaces).count > 1 else { return false }
            return translating || correcting || (!paragraph.style.isHeading && !paragraph.style.isTitle)
        }
        // Correzioni: solo i paragrafi in cui il correttore del Mac trova errori (gli altri restano identici).
        if correcting {
            let flagged = targets.filter { hasSpellingErrors(outline.paragraphs[$0].text) }
            if !flagged.isEmpty { targets = flagged }
        }
        return targets.isEmpty ? nil : Array(targets.prefix(40))
    }

    /// Il correttore ortografico del Mac (in italiano) trova parole sbagliate nel testo?
    static func hasSpellingErrors(_ text: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: text, startingAt: 0, language: "it", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location != NSNotFound
    }

    /// Scarta riscritture sospette (vuote o molto più corte senza che la richiesta chieda di accorciare).
    static func plausibleRewrite(_ original: String, _ text: String, instruction: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let shortening = ["accorcia", "abbrevia", "riassumi", "sintetizza", "semplifica"].contains(where: instruction.contains)
        return shortening || text.count * 3 >= original.count
    }

    /// Frase per la chat con ciò che è cambiato.
    static func summarize(_ operations: [DocumentOperation], outline: DocumentOutline) -> String {
        var parts: [String] = []
        let replaced: [Int] = operations.compactMap { operation -> Int? in
            if case .replace(let index, _) = operation { return index }
            return nil
        }
        let deleted: [Int] = operations.flatMap { operation -> [Int] in
            if case .delete(let indices) = operation { return indices }
            return []
        }
        let insertedParagraphs: [DocumentOutline.Paragraph] = operations.flatMap { operation -> [DocumentOutline.Paragraph] in
            if case .insert(_, let items) = operation { return items }
            return []
        }
        let formatted: [Int] = operations.flatMap { operation -> [Int] in
            if case .format(let indices, _) = operation { return indices }
            return []
        }
        let restyled: [Int] = operations.flatMap { operation -> [Int] in
            if case .restyle(let indices, _) = operation { return indices }
            return []
        }
        if replaced.contains(where: { outline.paragraphs.indices.contains($0) && outline.paragraphs[$0].style == .titolo }) { parts.append("cambiato il titolo") }
        let body = replaced.filter { !(outline.paragraphs.indices.contains($0) && outline.paragraphs[$0].style == .titolo) }
        if !body.isEmpty { parts.append(body.count == 1 ? "riscritto il paragrafo \(body[0] + 1)" : "riscritto \(body.count) paragrafi") }
        if let heading = insertedParagraphs.first(where: { $0.style.isHeading }) { parts.append("aggiunto la sezione «\(heading.text)»") }
        else if !insertedParagraphs.isEmpty { parts.append(insertedParagraphs.count == 1 ? "aggiunto un paragrafo" : "aggiunto \(insertedParagraphs.count) paragrafi") }
        let sections = deleted.filter { outline.paragraphs.indices.contains($0) && outline.paragraphs[$0].style.isHeading }.map { "«\(outline.paragraphs[$0].text)»" }
        if !sections.isEmpty { parts.append("eliminato la sezione \(sections.joined(separator: ", "))") }
        else if !deleted.isEmpty { parts.append(deleted.count == 1 ? "eliminato un paragrafo" : "eliminato \(Set(deleted).count) paragrafi") }
        if !formatted.isEmpty { parts.append("formattato \(Set(formatted).count) paragrafi") }
        if !restyled.isEmpty, replaced.isEmpty { parts.append("cambiato lo stile di \(Set(restyled).count) paragrafi") }
        guard !parts.isEmpty else { return "Ho modificato il documento." }
        let text = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " e " + parts.last!
        return "Ho " + text + "."
    }
}
