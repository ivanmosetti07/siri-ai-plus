import Foundation
import FoundationModels

// MARK: - Presentazione aperta: operazioni sulle slide

/// Una modifica alla presentazione. Gli indici (da 0) si riferiscono alle slide prima della modifica.
public enum DeckOperation: Sendable, Equatable {
    case delete([Int])
    /// Sposta una slide dopo un'altra (-1 = all'inizio).
    case move(Int, after: Int)
    case setTitle(Int, String)
    case setBullets(Int, [String])
    /// Slide nuove dopo quella indicata (-1 = all'inizio).
    case insert(after: Int, [DeckDraft.Slide])
}

public struct DeckEditPlan: Sendable, Equatable {
    public var operations: [DeckOperation]
    public var summary: String

    public init(operations: [DeckOperation], summary: String) { self.operations = operations; self.summary = summary }
}

extension Deck {
    /// Applica le operazioni e restituisce la slide da mostrare (quella cambiata o aggiunta).
    @discardableResult
    public mutating func apply(_ operations: [DeckOperation]) -> Int? {
        // Gli indici valgono per la presentazione di partenza: si lavora sugli identificatori, che non cambiano.
        let original = slides.map(\.id)
        func position(_ index: Int) -> Int? {
            guard original.indices.contains(index) else { return nil }
            return slides.firstIndex { $0.id == original[index] }
        }
        var focus: UUID?
        for operation in operations {
            switch operation {
            case .setTitle(let index, let title):
                guard let at = position(index) else { continue }
                if let element = slides[at].elements.firstIndex(where: { $0.role == .title }) {
                    slides[at].elements[element].text = title
                } else {
                    slides[at].elements.insert(SlideElement(kind: .text, role: .title, x: 0.07, y: 0.08, width: 0.86, height: 0.16, text: title, fontSize: 58, bold: true), at: 0)
                }
                focus = slides[at].id
            case .setBullets(let index, let bullets):
                guard let at = position(index) else { continue }
                let text = bullets.map { "• \($0)" }.joined(separator: "\n")
                if let element = slides[at].elements.firstIndex(where: { $0.role == .body }) {
                    slides[at].elements[element].text = text
                } else if let element = slides[at].elements.firstIndex(where: { $0.role == .subtitle }) {
                    slides[at].elements[element].text = bullets.joined(separator: " · ")
                } else {
                    slides[at].elements.append(SlideElement(kind: .text, role: .body, x: 0.07, y: 0.28, width: 0.86, height: 0.62, text: text, fontSize: 34))
                }
                focus = slides[at].id
            case .insert(let after, let drafts):
                let made = drafts.map { Slide.make(.titoloElenco, title: $0.title, bullets: $0.bullets) }
                let at = after < 0 ? 0 : (position(after).map { $0 + 1 } ?? slides.count)
                slides.insert(contentsOf: made, at: min(at, slides.count))
                focus = made.first?.id
            case .move(let index, let after):
                guard let from = position(index) else { continue }
                let slide = slides.remove(at: from)
                let at = after < 0 ? 0 : (position(after).map { $0 + 1 } ?? slides.count)
                slides.insert(slide, at: min(at, slides.count))
                focus = slide.id
            case .delete(let indices):
                let ids = Set(indices.compactMap { original.indices.contains($0) ? original[$0] : nil })
                // Una presentazione non resta mai senza slide.
                guard ids.count < slides.count else { continue }
                slides.removeAll { ids.contains($0.id) }
            }
        }
        return focus.flatMap { id in slides.firstIndex { $0.id == id } }
    }

    /// Titoli e punti di tutte le slide, per riconoscere la lingua della presentazione.
    var plainText: String { slides.map { $0.title + ". " + $0.bodyText }.joined(separator: "\n") }

    /// Slide numerate per il modello: titolo e punti.
    func numbered(selected: Int?) -> String {
        slides.enumerated().map { index, slide in
            let body = slide.bodyText.replacingOccurrences(of: "\n", with: "; ").prefix(160)
            return "\(index + 1). \(slide.title)\(index == selected ? Language.t(" [selezionata]", " [selected]") : "")\(body.isEmpty ? "" : " — \(body)")"
        }.joined(separator: "\n")
    }
}

extension Assistant {
    static let ordinalWords = ["prima": 1, "primo": 1, "seconda": 2, "secondo": 2, "terza": 3, "terzo": 3, "quarta": 4, "quarto": 4,
                               "quinta": 5, "quinto": 5, "sesta": 6, "sesto": 6, "settima": 7, "settimo": 7, "ottava": 8, "ottavo": 8,
                               "nona": 9, "nono": 9, "decima": 10, "decimo": 10]

    /// Ordinali inglesi ("the third slide").
    static let englishOrdinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
                                  "ninth": 9, "tenth": 10]

    /// "slide 3", "the third slide", "the last slide", "this slide", "the slide about the market", "the market one" → indice (da 0);
    /// nil se non la trova (allora si provano le parole italiane).
    static func englishSlideIndex(_ lower: String, deck: Deck, selected: Int?) -> Int? {
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        let count = deck.slides.count
        if has(#"\b(?:this|current|selected)\b"#) { return selected }
        if has(#"\b(?:second[\s-]to[\s-]last|next[\s-]to[\s-]last|penultimate)\b"#) { return count >= 2 ? count - 2 : nil }
        if has(#"\blast\b"#) { return count > 0 ? count - 1 : nil }
        if let number = Calculations.matches(#"\b(\d+)(?:st|nd|rd|th)?\b"#, in: lower).first.flatMap({ Int($0[1]) }) {
            return number >= 1 && number <= count ? number - 1 : nil
        }
        if let word = englishOrdinals.keys.first(where: { has(#"\b"# + $0 + #"\b"#) }), let number = englishOrdinals[word] {
            return number <= count ? number - 1 : nil
        }
        // Per titolo: "the slide about the market", "the market one".
        let name = lower.replacingOccurrences(of: #"^(?:the\s+|a\s+)?(?:slides?|one)?\s*(?:(?:about|on|of|for|called|titled|entitled|named|with)\s+)?(?:the\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:slide|one)$"#, with: "", options: .regularExpression)
        let wanted = DocumentOutline.words(name)
        guard !wanted.isEmpty else { return nil }
        let scored = deck.slides.indices.map { ($0, DocumentOutline.words(deck.slides[$0].title).intersection(wanted).count) }
        return scored.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    /// "la slide 3", "la terza slide", "l'ultima slide", "questa slide", "la slide sul mercato" → indice (da 0).
    static func slideIndex(_ text: String, deck: Deck, selected: Int?) -> Int? {
        let lower = text.lowercased().trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,")))
        if Language.isEnglish, let index = englishSlideIndex(lower, deck: deck, selected: selected) { return index }
        if lower.range(of: #"\b(questa|quella|corrente|selezionata|attuale)\b"#, options: .regularExpression) != nil { return selected }
        if lower.contains("penultima") { return deck.slides.count >= 2 ? deck.slides.count - 2 : nil }
        if lower.contains("ultima") { return deck.slides.isEmpty ? nil : deck.slides.count - 1 }
        if let number = Calculations.matches(#"\b(\d+)\b"#, in: lower).first.flatMap({ Int($0[1]) }) {
            return number >= 1 && number <= deck.slides.count ? number - 1 : nil
        }
        if let word = ordinalWords.keys.first(where: { lower.range(of: #"\b"# + $0 + #"\b"#, options: .regularExpression) != nil }), let number = ordinalWords[word] {
            return number <= deck.slides.count ? number - 1 : nil
        }
        // Per titolo: "la slide sul mercato", "la slide Mercato".
        let name = lower.replacingOccurrences(of: #"^(la |le )?(slide|diapositiva)\s*(su|sul|sulla|sui|sugli|sulle|di|del|della|dei|intitolata)?\s*"#, with: "", options: .regularExpression)
        let wanted = DocumentOutline.words(name)
        guard !wanted.isEmpty else { return nil }
        let scored = deck.slides.indices.map { ($0, DocumentOutline.words(deck.slides[$0].title).intersection(wanted).count) }
        return scored.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    /// Comandi inglesi sulle slide: "delete slide 3", "move slide 2 after slide 4", "change the title of slide 2 to “Why now”".
    static func quickEnglishDeckEdit(_ prompt: String, deck: Deck, selected: Int?) -> DeckEditPlan? {
        // "Delete slide 3", "remove the last slide", "delete this slide", "delete slides 2 and 4".
        if let match = Calculations.matches(#"^(?:delete|remove|erase|drop|cut|get\s+rid\s+of)\s+(.+)$"#, in: prompt).first,
           match[1].lowercased().range(of: #"\bslides?\b"#, options: .regularExpression) != nil {
            let target = match[1]
            let numbers = Calculations.matches(#"\b(\d+)(?:st|nd|rd|th)?\b"#, in: target).compactMap { Int($0[1]) }.filter { $0 >= 1 && $0 <= deck.slides.count }
            let indices: [Int] = numbers.count >= 2 ? numbers.map { $0 - 1 } : slideIndex(target, deck: deck, selected: selected).map { [$0] } ?? []
            guard !indices.isEmpty else { return nil }
            let names = indices.map { "“\(deck.slides[$0].title)”" }.joined(separator: ", ")
            return DeckEditPlan(operations: [.delete(indices)],
                                summary: indices.count == 1 ? "I deleted slide \(indices[0] + 1) \(names)." : "I deleted \(indices.count) slides: \(names).")
        }
        // "Move slide 2 after slide 4", "move this slide to the end", "move slide 5 to the beginning".
        if let match = Calculations.matches(#"^move\s+(.+?)\s+(after(?:\s+the|\s+slide)?|before(?:\s+the|\s+slide)?|(?:to|at)\s+the\s+(?:end|bottom|beginning|start|top))\s*(.*)$"#, in: prompt).first,
           let from = slideIndex(match[1], deck: deck, selected: selected) {
            let place = match[2].lowercased()
            var after: Int
            if place.hasSuffix("end") || place.hasSuffix("bottom") { after = deck.slides.count - 1 }
            else if place.hasSuffix("beginning") || place.hasSuffix("start") || place.hasSuffix("top") { after = -1 }
            else {
                guard let target = slideIndex(match[3].isEmpty ? "slide" : "slide " + match[3], deck: deck, selected: selected) else { return nil }
                after = place.hasPrefix("before") ? target - 1 : target
            }
            return DeckEditPlan(operations: [.move(from, after: after)], summary: "I moved the slide “\(deck.slides[from].title)”.")
        }
        // "Change the title of slide 2 to “Why now”", "rename slide 2 to Why now".
        if let match = Calculations.matches(#"^(?:change|edit|modify|set|update|replace|rename)\s+(?:the\s+)?title\s+(?:of|on|for|in)\s+(.+?)\s+(?:to|into|as|with|:)\s+(.+)$"#, in: prompt).first
            ?? Calculations.matches(#"^(?:rename|retitle|title)\s+(.*?\bslides?\b.*?)\s+(?:to|as|:)\s+(.+)$"#, in: prompt).first,
           let index = slideIndex(match[1], deck: deck, selected: selected) {
            let title = unquoted(match[2])
            guard !title.isEmpty else { return nil }
            return DeckEditPlan(operations: [.setTitle(index, title)], summary: "I changed the title of slide \(index + 1) to “\(title)”.")
        }
        return nil
    }

    /// Comandi sulle slide riconosciuti con regole: eliminare, spostare, cambiare titolo.
    public static func quickDeckEdit(_ instruction: String, deck: Deck, selected: Int?) -> DeckEditPlan? {
        let prompt = instruction.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        // In inglese prima le regole inglesi; un comando in italiano resta valido.
        if Language.isEnglish, let plan = quickEnglishDeckEdit(prompt, deck: deck, selected: selected) { return plan }
        let slideWord = #"(?:slide|diapositiva|diapositive)"#
        // "Elimina la slide 3", "cancella l'ultima slide", "togli questa slide", "elimina le slide 2 e 4".
        if let match = Calculations.matches(#"^(?:elimina|cancella|togli|rimuovi)\s+(.+)$"#, in: prompt).first,
           match[1].lowercased().range(of: slideWord, options: .regularExpression) != nil {
            let target = match[1]
            let numbers = Calculations.matches(#"\b(\d+)\b"#, in: target).compactMap { Int($0[1]) }.filter { $0 >= 1 && $0 <= deck.slides.count }
            let indices: [Int] = numbers.count >= 2 ? numbers.map { $0 - 1 } : slideIndex(target, deck: deck, selected: selected).map { [$0] } ?? []
            guard !indices.isEmpty else { return nil }
            let names = indices.map { "«\(deck.slides[$0].title)»" }.joined(separator: ", ")
            return DeckEditPlan(operations: [.delete(indices)], summary: indices.count == 1 ? Language.t("Ho eliminato la slide \(indices[0] + 1) \(names).", "I deleted slide \(indices[0] + 1) \(names).")
                                    : Language.t("Ho eliminato \(indices.count) slide: \(names).", "I deleted \(indices.count) slides: \(names)."))
        }
        // "Sposta la slide 2 dopo la 4", "sposta questa slide in fondo", "sposta la slide 5 all'inizio".
        if let match = Calculations.matches(#"^sposta\s+(.+?)\s+(dopo(?: la| il)?|prima(?: della| di| del)?|in fondo|alla fine|all'inizio|in cima)\s*(.*)$"#, in: prompt).first,
           let from = slideIndex(match[1], deck: deck, selected: selected) {
            let where_ = match[2].lowercased()
            var after: Int
            if where_.hasPrefix("in fondo") || where_.hasPrefix("alla fine") { after = deck.slides.count - 1 }
            else if where_.hasPrefix("all'inizio") || where_.hasPrefix("in cima") { after = -1 }
            else {
                guard let target = slideIndex(match[3].isEmpty ? "slide" : "slide " + match[3], deck: deck, selected: selected) else { return nil }
                after = where_.hasPrefix("prima") ? target - 1 : target
            }
            return DeckEditPlan(operations: [.move(from, after: after)], summary: Language.t("Ho spostato la slide «\(deck.slides[from].title)».", "I moved the slide “\(deck.slides[from].title)”."))
        }
        // "Cambia il titolo della slide 2 in «Perché ora»".
        if let match = Calculations.matches(#"^(?:cambia|modifica|metti|imposta|rinomina|sostituisci)\s+(?:il\s+)?titolo\s+(?:della|alla|nella)\s+(.+?)\s+(?:in|con|a|:)\s+(.+)$"#, in: prompt).first,
           let index = slideIndex(match[1], deck: deck, selected: selected) {
            let title = unquoted(match[2])
            guard !title.isEmpty else { return nil }
            return DeckEditPlan(operations: [.setTitle(index, title)], summary: Language.t("Ho cambiato il titolo della slide \(index + 1) in «\(title)».",
                                                                                          "I changed the title of slide \(index + 1) to “\(title)”."))
        }
        return nil
    }

    /// "Dopo quella sul mercato", "prima della slide 5", "in fondo", "all'inizio": dove mettere una slide nuova, se la richiesta lo dice.
    static func slideAnchor(_ instruction: String, deck: Deck, selected: Int?) -> Int? {
        let lower = instruction.lowercased()
        // In inglese: "after the market one", "before slide 5", "at the end", "at the beginning".
        if Language.isEnglish {
            if lower.range(of: #"\b(?:at|to)\s+the\s+(?:end|bottom)\b"#, options: .regularExpression) != nil { return deck.slides.count - 1 }
            if lower.range(of: #"\b(?:at|to)\s+the\s+(?:beginning|start|top)\b"#, options: .regularExpression) != nil { return -1 }
            if let match = Calculations.matches(#"\bafter\s+(?:the\s+one\s+|the\s+slide\s+|slide\s+|the\s+)?(.+)$"#, in: lower).first,
               let index = slideIndex("slide " + match[1], deck: deck, selected: selected) { return index }
            if let match = Calculations.matches(#"\bbefore\s+(?:the\s+one\s+|the\s+slide\s+|slide\s+|the\s+)?(.+)$"#, in: lower).first,
               let index = slideIndex("slide " + match[1], deck: deck, selected: selected) { return index - 1 }
        }
        if lower.range(of: #"\b(in fondo|alla fine)\b"#, options: .regularExpression) != nil { return deck.slides.count - 1 }
        if lower.range(of: #"\b(all'inizio|in cima)\b"#, options: .regularExpression) != nil { return -1 }
        if let match = Calculations.matches(#"\bdopo\s+(?:quella|la slide|la)?\s*(.+)$"#, in: lower).first,
           let index = slideIndex("slide " + match[1], deck: deck, selected: selected) { return index }
        if let match = Calculations.matches(#"\bprima\s+(?:di quella|della slide|della|di)?\s*(.+)$"#, in: lower).first,
           let index = slideIndex("slide " + match[1], deck: deck, selected: selected) { return index - 1 }
        return nil
    }

    private static let deckEditSchema = makeSchema("ModificheSlide", [
        .required("operazioni", .array(.object("Operazione", [
            .required("tipo", .choice(["elimina", "sposta", "titolo", "punti", "aggiungi_dopo"]),
                      "elimina una slide; sposta una slide dopo un'altra; titolo per cambiarlo; punti per riscrivere l'elenco; aggiungi_dopo una slide nuova"),
            .required("slide", .int, "Numero della slide su cui agire; 0 per aggiungere all'inizio"),
            .optional("dopo", .int, "Per sposta: numero della slide dopo cui metterla (0 = all'inizio)"),
            .optional("titolo", .string, "Titolo nuovo (per titolo e aggiungi_dopo)"),
            .optional("punti", .array(.string, max: 5), "Punti elenco brevi (per punti e aggiungi_dopo)"),
        ]), min: 1, max: 8), "Operazioni da applicare, solo sulle slide da cambiare"),
    ])

    /// Lo stesso schema per le richieste in inglese: il codice accetta i valori in tutte e due le lingue.
    static let englishDeckEditSchema = makeSchema("SlideEdits", [
        .required("operations", .array(.object("Operation", [
            .required("type", .choice(["delete", "move", "title", "bullets", "add_after"]),
                      "delete a slide; move a slide after another; title to change it; bullets to rewrite the list; add_after a new slide"),
            .required("slide", .int, "Number of the slide to act on; 0 to add at the beginning"),
            .optional("after", .int, "For move: number of the slide to put it after (0 = at the beginning)"),
            .optional("title", .string, "New title (for title and add_after)"),
            .optional("bullets", .array(.string, max: 5), "Short bullet points (for bullets and add_after)"),
        ]), min: 1, max: 8), "Operations to apply, only on the slides to change"),
    ])

    /// Tipo di operazione scelto dal modello, anche in inglese ("add_after" → "aggiungi_dopo").
    static func deckOperationKind(_ kind: String) -> String {
        ["delete": "elimina", "move": "sposta", "title": "titolo", "bullets": "punti", "add_after": "aggiungi_dopo"][kind.lowercased()] ?? kind
    }

    /// Titolo e punti di una slide scritti dal modello scelto (nil con Apple Intelligence o se non risponde).
    func writtenSlide(deck: Deck, selected: Int?, instruction: String, title: String) async -> (title: String, bullets: [String])? {
        guard textWriter != nil else { return nil }
        // In inglese la slide si scrive nella lingua della presentazione.
        let english = Language.isEnglish
        let role = english
            ? "Write the content of a slide for an open presentation, consistent with the other slides, in \(Self.languageName(of: deck.plainText)) unless the request asks for another language."
            : "Scrivi il contenuto di una slide per una presentazione aperta, coerente con le altre slide."
        let request = english
            ? "Presentation “\(deck.title)”:\n\(deck.numbered(selected: selected))\n\nRequest: \(instruction)\nSlide to write: \(title)"
            : "Presentazione «\(deck.title)»:\n\(deck.numbered(selected: selected))\n\nRichiesta: \(instruction)\nSlide da scrivere: \(title)"
        let fields = english
            ? "\"title\": the slide title; \"bullets\": 2 to 4 short, concrete bullet points"
            : "\"titolo\": titolo della slide; \"punti\": da 2 a 4 punti elenco brevi e concreti"
        guard let json = await composeJSON(role, request, fields: fields) else { return nil }
        // I punti di una slide non finiscono con il punto fermo.
        let written = json.texts("punti").isEmpty ? json.texts("bullets") : json.texts("punti")
        let bullets = written.map { $0.hasSuffix("...") ? $0 : $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        return bullets.isEmpty ? nil : (json.text("titolo") ?? json.text("title") ?? title, Array(bullets.prefix(5)))
    }

    /// Modifica della presentazione aperta: regole per i comandi comuni, altrimenti il modello sulle slide numerate.
    public func planDeckEdit(_ instruction: String, deck: Deck, selected: Int?,
                             status: @escaping @MainActor (String) -> Void = { _ in }) async throws -> DeckEditPlan {
        if let quick = Self.quickDeckEdit(instruction, deck: deck, selected: selected) {
            Agent.log("MODIFICA SLIDE (regole): \(quick.summary)")
            return quick
        }
        status(Language.t("Scelgo cosa cambiare nella presentazione…", "Choosing what to change in the presentation…"))
        let english = Language.isEnglish
        let session = LanguageModelSession(model: Agent.model, instructions: english ? """
        You edit a presentation open in the editor. You receive the numbered slides (title — bullets) and a request.
        Return only the necessary operations: the other slides stay as they are. “This slide” is the one marked [selected].
        To add a slide use add_after with a title and 2 to 4 short, concrete bullet points, consistent with the presentation.
        Write in \(Self.languageName(of: deck.plainText)), unless the request asks for another language.
        """ : """
        Modifichi una presentazione aperta nell'editor. Ricevi le slide numerate (titolo — punti) e una richiesta.
        Restituisci solo le operazioni necessarie: le altre slide restano come sono. «Questa slide» è quella segnata [selezionata].
        Per aggiungere una slide usa aggiungi_dopo con un titolo e da 2 a 4 punti brevi e concreti, coerenti con la presentazione.
        Scrivi in italiano, salvo che la richiesta chieda un'altra lingua.
        """)
        let request = english ? "Presentation “\(deck.title)”:\n\(deck.numbered(selected: selected))\n\nRequest: \(instruction)"
            : "Presentazione «\(deck.title)»:\n\(deck.numbered(selected: selected))\n\nRichiesta: \(instruction)"
        let content = try await session.respond(to: request, schema: english ? Self.englishDeckEditSchema : Self.deckEditSchema,
                                                options: GenerationOptions(temperature: 0.2)).content
        var operations: [DeckOperation] = []
        var parts: [String] = []
        // Campi e valori dello schema in italiano o in inglese.
        for item in content.objects("operazioni") + content.objects("operations") {
            guard let kind = (item.string("tipo") ?? item.string("type")).map(Self.deckOperationKind), let number = item.int("slide") else { continue }
            let index = number - 1
            let newTitle = item.string("titolo") ?? item.string("title")
            let newBullets = item.strings("punti").isEmpty ? item.strings("bullets") : item.strings("punti")
            switch kind {
            case "elimina" where deck.slides.indices.contains(index):
                operations.append(.delete([index]))
                parts.append(Language.t("eliminato la slide \(number)", "deleted slide \(number)"))
            case "sposta" where deck.slides.indices.contains(index):
                operations.append(.move(index, after: (item.int("dopo") ?? item.int("after") ?? deck.slides.count) - 1))
                parts.append(Language.t("spostato la slide \(number)", "moved slide \(number)"))
            case "titolo" where deck.slides.indices.contains(index):
                guard let title = newTitle else { continue }
                operations.append(.setTitle(index, title))
                parts.append(Language.t("cambiato il titolo della slide \(number)", "changed the title of slide \(number)"))
            case "punti" where deck.slides.indices.contains(index):
                var bullets = newBullets
                if let written = await writtenSlide(deck: deck, selected: selected, instruction: instruction, title: deck.slides[index].title) {
                    bullets = written.bullets
                }
                guard !bullets.isEmpty else { continue }
                operations.append(.setBullets(index, bullets))
                parts.append(Language.t("riscritto i punti della slide \(number)", "rewrote the bullets of slide \(number)"))
            case "aggiungi_dopo" where index >= -1 && index < deck.slides.count:
                guard var title = newTitle else { continue }
                var bullets = newBullets
                // Con il modello scelto il contenuto della slide lo scrive lui; Apple Intelligence ha deciso dove metterla.
                if let written = await writtenSlide(deck: deck, selected: selected, instruction: instruction, title: title) {
                    title = written.title
                    bullets = written.bullets
                }
                operations.append(.insert(after: Self.slideAnchor(instruction, deck: deck, selected: selected) ?? index,
                                          [DeckDraft.Slide(title: title, bullets: bullets)]))
                parts.append(Language.t("aggiunto la slide «\(title)»", "added the slide “\(title)”"))
            default: continue
            }
        }
        guard !operations.isEmpty else {
            return DeckEditPlan(operations: [], summary: Language.t("Non ho capito cosa cambiare nella presentazione: dimmi quale slide.",
                                                                    "I didn't understand what to change in the presentation: tell me which slide."))
        }
        return DeckEditPlan(operations: operations, summary: Language.t("Ho ", "I ") + Self.joined(parts) + ".")
    }
}
