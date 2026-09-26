import Foundation

// MARK: - Numbers

public enum CellFormat: String, Codable, Sendable, CaseIterable {
    case automatic, number, currency, percent

    public var label: String {
        switch self {
        case .automatic: Language.t("Automatico", "Automatic")
        case .number: Language.t("Numero", "Number")
        case .currency: Language.t("Valuta (€)", "Currency (€)")
        case .percent: Language.t("Percentuale", "Percent")
        }
    }

    /// Numeri nel formato della lingua in uso ("1.234,50 €" in italiano, "€1,234.50" in inglese); la valuta resta l'euro.
    public func format(_ value: CellValue) -> String {
        guard case .number(let n) = value else { return value.display }
        let locale = Language.current.locale
        switch self {
        case .automatic: return FormulaEngine.format(n)
        case .number: return n.formatted(.number.precision(.fractionLength(2)).locale(locale))
        case .currency: return n.formatted(.currency(code: "EUR").locale(locale))
        case .percent: return n.formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
        }
    }
}

public struct ChartSpec: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case bar, line, pie }
    public var id = UUID()
    public var kind: Kind
    /// Intervallo dati, es. "A1:C6": prima colonna etichette, prima riga nomi delle serie.
    public var range: String
    public var title: String

    public init(kind: Kind, range: String, title: String) {
        self.kind = kind; self.range = range; self.title = title
    }
}

public struct Sheet: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var columns: Int
    public var rows: Int
    /// Valori grezzi o formule, per nome cella ("B3" → "=SOMMA(B1:B2)").
    public var cells: [String: String]
    public var formats: [String: CellFormat] = [:]
    public var charts: [ChartSpec] = []

    public init(name: String, columns: Int = 6, rows: Int = 20, cells: [String: String] = [:]) {
        self.name = name; self.columns = columns; self.rows = rows; self.cells = cells
    }

    public func raw(_ ref: CellRef) -> String { cells[ref.name] ?? "" }
    public func value(_ ref: CellRef) -> CellValue { FormulaEngine.value(of: ref, in: cells) }
    public func display(_ ref: CellRef) -> String { (formats[ref.name] ?? .automatic).format(value(ref)) }

    public mutating func set(_ ref: CellRef, _ raw: String) {
        if raw.isEmpty { cells.removeValue(forKey: ref.name) } else { cells[ref.name] = raw }
        columns = max(columns, ref.col + 1)
        rows = max(rows, ref.row + 1)
    }

    /// Serie per i grafici: etichette dalla prima colonna, una serie per ogni colonna successiva.
    public func series(for range: String) -> (labels: [String], series: [(name: String, values: [Double])]) {
        let parts = range.split(separator: ":").map(String.init)
        guard parts.count == 2, let from = CellRef(parts[0]), let to = CellRef(parts[1]) else { return ([], []) }
        let top = min(from.row, to.row), bottom = max(from.row, to.row)
        let left = min(from.col, to.col), right = max(from.col, to.col)
        // Nessuna riga di dati sotto l'intestazione: niente serie (prima leggeva una riga fuori dall'intervallo).
        guard bottom > top else { return ([], []) }
        let rows = Array(top + 1...bottom)
        let labels = rows.map { value(CellRef(col: left, row: $0)).display }
        let series = (left + 1...max(left + 1, right)).map { col in
            (name: value(CellRef(col: col, row: top)).display,
             values: rows.map { value(CellRef(col: col, row: $0)).number ?? 0 })
        }
        return (labels, series)
    }

    /// Testo compatto del foglio per il modello (valori calcolati).
    public func summary(maxRows: Int = 15) -> String {
        let usedRows = (cells.keys.compactMap { CellRef($0)?.row }.max() ?? -1) + 1
        let usedCols = (cells.keys.compactMap { CellRef($0)?.col }.max() ?? -1) + 1
        guard usedRows > 0 else { return Language.t("(foglio vuoto)", "(empty sheet)") }
        return (0..<min(usedRows, maxRows)).map { row in
            (0..<usedCols).map { display(CellRef(col: $0, row: row)) }.joined(separator: " | ")
        }.joined(separator: "\n")
    }
}

public struct Spreadsheet: Codable, Sendable, Equatable {
    public var title: String
    public var sheets: [Sheet]

    public init(title: String, sheets: [Sheet]) {
        self.title = title; self.sheets = sheets
    }

    /// Converte la bozza del modello: intestazioni, valori, colonna e riga dei totali con formule vere (nella lingua della richiesta).
    public init(from draft: SheetDraft) {
        let sum = Language.t("SOMMA", "SUM")
        var sheet = Sheet(name: Language.t("Foglio 1", "Sheet 1"), columns: draft.columns.count + 2, rows: max(20, draft.rows.count + 4))
        sheet.set(CellRef(col: 0, row: 0), Language.t("Voce", "Item"))
        for (i, column) in draft.columns.enumerated() { sheet.set(CellRef(col: i + 1, row: 0), column) }
        let totalCol = draft.columns.count + 1
        sheet.set(CellRef(col: totalCol, row: 0), Language.t("Totale", "Total"))
        for (r, row) in draft.rows.enumerated() {
            let rowIndex = r + 1
            sheet.set(CellRef(col: 0, row: rowIndex), row.label)
            for (c, value) in row.values.enumerated() {
                sheet.set(CellRef(col: c + 1, row: rowIndex), value.rounded() == value ? String(Int(value)) : String(value))
            }
            let first = CellRef(col: 1, row: rowIndex).name, last = CellRef(col: draft.columns.count, row: rowIndex).name
            sheet.set(CellRef(col: totalCol, row: rowIndex), "=\(sum)(\(first):\(last))")
        }
        let totalRow = draft.rows.count + 1
        sheet.set(CellRef(col: 0, row: totalRow), Language.t("Totale", "Total"))
        for c in 1...totalCol where !draft.rows.isEmpty {
            let top = CellRef(col: c, row: 1).name, bottom = CellRef(col: c, row: draft.rows.count).name
            sheet.set(CellRef(col: c, row: totalRow), "=\(sum)(\(top):\(bottom))")
        }
        if !draft.rows.isEmpty {
            let end = CellRef(col: draft.columns.count, row: draft.rows.count).name
            sheet.charts = [ChartSpec(kind: .bar, range: "A1:\(end)", title: draft.title)]
        }
        self.init(title: draft.title, sheets: [sheet])
    }
}

// MARK: - Keynote

public enum DeckTheme: String, Codable, Sendable, CaseIterable {
    case notte, chiaro, vivace

    public var label: String {
        switch self {
        case .notte: Language.t("Notte", "Night")
        case .chiaro: Language.t("Chiaro", "Light")
        case .vivace: Language.t("Vivace", "Vivid")
        }
    }
}

public enum SlideLayout: String, Codable, Sendable, CaseIterable {
    case titolo, titoloElenco, immagine, vuota

    public var label: String {
        switch self {
        case .titolo: Language.t("Titolo", "Title")
        case .titoloElenco: Language.t("Titolo ed elenco", "Title and bullets")
        case .immagine: Language.t("Titolo e immagine", "Title and image")
        case .vuota: Language.t("Vuota", "Blank")
        }
    }
}

public struct SlideElement: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case text, image, shape }
    public enum Shape: String, Codable, Sendable { case rectangle, ellipse }
    public enum Role: String, Codable, Sendable { case title, subtitle, body, other }

    public var id = UUID()
    public var kind: Kind
    public var role: Role = .other
    /// Posizione e dimensione normalizzate (0…1) rispetto alla slide.
    public var x: Double, y: Double, width: Double, height: Double
    public var text: String = ""
    /// Dimensione del testo in punti su una slide larga 1280.
    public var fontSize: Double = 32
    public var bold = false
    public var alignment: String = "leading"
    public var colorHex: String?
    public var imagePath: String?
    public var shape: Shape = .rectangle

    public init(kind: Kind, role: Role = .other, x: Double, y: Double, width: Double, height: Double,
                text: String = "", fontSize: Double = 32, bold: Bool = false) {
        self.kind = kind; self.role = role; self.x = x; self.y = y; self.width = width; self.height = height
        self.text = text; self.fontSize = fontSize; self.bold = bold
    }
}

public struct Slide: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var layout: SlideLayout
    public var elements: [SlideElement]
    public var notes: String = ""

    public init(layout: SlideLayout, elements: [SlideElement]) {
        self.layout = layout; self.elements = elements
    }

    public static func make(_ layout: SlideLayout, title: String = "", subtitle: String = "", bullets: [String] = [], imagePath: String? = nil) -> Slide {
        switch layout {
        case .titolo:
            return Slide(layout: layout, elements: [
                SlideElement(kind: .text, role: .title, x: 0.08, y: 0.52, width: 0.84, height: 0.2, text: title, fontSize: 76, bold: true),
                SlideElement(kind: .text, role: .subtitle, x: 0.08, y: 0.73, width: 0.84, height: 0.12, text: subtitle, fontSize: 34),
            ])
        case .titoloElenco:
            return Slide(layout: layout, elements: [
                SlideElement(kind: .text, role: .title, x: 0.07, y: 0.08, width: 0.86, height: 0.16, text: title, fontSize: 58, bold: true),
                SlideElement(kind: .text, role: .body, x: 0.07, y: 0.28, width: 0.86, height: 0.62,
                             text: bullets.map { "• \($0)" }.joined(separator: "\n"), fontSize: 34),
            ])
        case .immagine:
            var image = SlideElement(kind: .image, x: 0.5, y: 0.22, width: 0.43, height: 0.66)
            image.imagePath = imagePath
            return Slide(layout: layout, elements: [
                SlideElement(kind: .text, role: .title, x: 0.07, y: 0.08, width: 0.86, height: 0.14, text: title, fontSize: 54, bold: true),
                SlideElement(kind: .text, role: .body, x: 0.07, y: 0.26, width: 0.4, height: 0.6,
                             text: bullets.map { "• \($0)" }.joined(separator: "\n"), fontSize: 30),
                image,
            ])
        case .vuota:
            return Slide(layout: layout, elements: [])
        }
    }

    public var title: String { elements.first { $0.role == .title }?.text ?? elements.first { $0.kind == .text }?.text ?? "" }

    public var bodyText: String {
        elements.filter { $0.kind == .text && $0.role != .title }.map(\.text).joined(separator: "\n")
    }
}

public struct Deck: Codable, Sendable, Equatable {
    public var title: String
    public var theme: DeckTheme
    public var slides: [Slide]

    public init(title: String, theme: DeckTheme = .notte, slides: [Slide]) {
        self.title = title; self.theme = theme; self.slides = slides
    }

    public init(from draft: DeckDraft) {
        var slides = [Slide.make(.titolo, title: draft.title, subtitle: draft.subtitle)]
        slides += draft.slides.map { Slide.make(.titoloElenco, title: $0.title, bullets: $0.bullets) }
        self.init(title: draft.title, theme: .notte, slides: slides)
    }

    public func summary() -> String {
        slides.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
    }
}
