import Charts
import SiriCore
import SwiftUI

/// Replica semplificata di Numbers: griglia con formule, formati, più fogli e grafici collegati.
struct NumbersEditor: View {
    @Environment(AppState.self) private var state
    @Bindable var artifact: ArtifactModel
    @State private var sheetIndex = 0
    @State private var anchor = CellRef(col: 0, row: 0)
    @State private var focus = CellRef(col: 0, row: 0)
    @State private var editing = CellRef?.none
    @State private var editText = ""
    @State private var formulaText = ""
    @State private var renaming = Int?.none
    @FocusState private var gridFocused: Bool
    @FocusState private var cellFocused: Bool

    private static let columnWidth: CGFloat = 112
    private static let rowHeight: CGFloat = 26
    private static let headerWidth: CGFloat = 44

    private var spreadsheet: Spreadsheet { artifact.spreadsheet ?? Spreadsheet(title: "", sheets: [Sheet(name: "Foglio 1")]) }
    private var index: Int { min(sheetIndex, spreadsheet.sheets.count - 1) }
    private var sheet: Sheet { spreadsheet.sheets[index] }

    private var selection: (top: Int, left: Int, bottom: Int, right: Int) {
        let a = anchor, f = focus
        return (min(a.row, f.row), min(a.col, f.col), max(a.row, f.row), max(a.col, f.col))
    }

    private var selectionRange: String {
        let s = selection
        return "\(CellRef(col: s.left, row: s.top).name):\(CellRef(col: s.right, row: s.bottom).name)"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            formulaBar
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 18) {
                    grid
                    ForEach(sheet.charts) { chart in
                        ChartBlock(spec: chart, sheet: sheet) { removeChart(chart.id) } onKind: { kind in updateChart(chart.id, kind: kind) }
                    }
                }
                .padding(16)
            }
            .background(Color.surface)
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down, action: handleKey)
            tabs
        }
        .onAppear { gridFocused = true; syncFormula(); EditorBridge.sheetIndex[artifact.id] = index }
        // La chat modifica il foglio visibile.
        .onChange(of: sheetIndex) { _, _ in EditorBridge.sheetIndex[artifact.id] = index }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        EditorToolbar {
            Menu {
                Button("Riga sopra") { insertRow(at: selection.top) }
                Button("Riga sotto") { insertRow(at: selection.bottom + 1) }
                Divider()
                Button("Colonna a sinistra") { insertColumn(at: selection.left) }
                Button("Colonna a destra") { insertColumn(at: selection.right + 1) }
            } label: { Label("Inserisci", systemImage: "plus.square") }
            .fixedSize()
            Menu {
                Button("Righe selezionate") { deleteRows() }
                Button("Colonne selezionate") { deleteColumns() }
                Button("Contenuto celle") { clearSelection() }
            } label: { Label("Elimina", systemImage: "minus.square") }
            .fixedSize()
            ToolbarDivider()
            Picker("Formato", selection: Binding(get: { sheet.formats[focus.name] ?? .automatic }, set: { setFormat($0) })) {
                ForEach(CellFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            .help("Formato numerico delle celle selezionate")
            Menu {
                Button("Somma") { insertFunction("SOMMA") }
                Button("Media") { insertFunction("MEDIA") }
                Button("Minimo") { insertFunction("MIN") }
                Button("Massimo") { insertFunction("MAX") }
                Button("Conteggio") { insertFunction("CONTA") }
            } label: { Label("Formula", systemImage: "function") }
            .fixedSize()
            .help("Inserisce sotto la selezione una formula sull'intervallo selezionato")
            ToolbarDivider()
            Menu {
                Button("Barre") { addChart(.bar) }
                Button("Linee") { addChart(.line) }
                Button("Torta") { addChart(.pie) }
            } label: { Label("Grafico", systemImage: "chart.bar.xaxis") }
            .fixedSize()
            .help("Crea un grafico dall'intervallo selezionato (prima colonna etichette, prima riga nomi)")
            Spacer()
            Button {
                state.send("Analizza i dati del foglio «\(sheet.name)» e dimmi cosa emerge")
            } label: { Label("Analizza con Siri AI+", systemImage: "sparkles") }
        }
    }

    private var formulaBar: some View {
        HStack(spacing: 8) {
            Text(selection.top == selection.bottom && selection.left == selection.right ? focus.name : selectionRange)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 80, alignment: .leading)
            Image(systemName: "function").foregroundStyle(.secondary)
            TextField("Valore o formula (es. =SOMMA(B2:B6))", text: $formulaText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit { commit(focus, formulaText); gridFocused = true }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.surfaceSubtle)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Griglia

    private var grid: some View {
        let s = selection
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.headerWidth, height: Self.rowHeight)
                ForEach(0..<sheet.columns, id: \.self) { col in
                    Text(CellRef.columnName(col))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(col >= s.left && col <= s.right ? Color.accentColor : .secondary)
                        .frame(width: Self.columnWidth, height: Self.rowHeight)
                        .background(Color.surfaceSubtle)
                        .overlay(alignment: .trailing) { Rectangle().fill(Color.hairline).frame(width: 0.5) }
                        .onTapGesture { anchor = CellRef(col: col, row: 0); focus = CellRef(col: col, row: sheet.rows - 1); syncFormula() }
                }
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<sheet.rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        Text("\(row + 1)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(row >= s.top && row <= s.bottom ? Color.accentColor : .secondary)
                            .frame(width: Self.headerWidth, height: Self.rowHeight)
                            .background(Color.surfaceSubtle)
                            .onTapGesture { anchor = CellRef(col: 0, row: row); focus = CellRef(col: sheet.columns - 1, row: row); syncFormula() }
                        ForEach(0..<sheet.columns, id: \.self) { col in
                            cell(CellRef(col: col, row: row), selected: row >= s.top && row <= s.bottom && col >= s.left && col <= s.right)
                        }
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.hairline))
        .fixedSize()
    }

    @ViewBuilder private func cell(_ ref: CellRef, selected: Bool) -> some View {
        let isFocus = ref == focus
        let value = sheet.value(ref)
        let isHeader = ref.row == 0
        ZStack(alignment: value.number != nil && !isText(value) ? .trailing : .leading) {
            if editing == ref {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .focused($cellFocused)
                    .onSubmit { commit(ref, editText); move(dRow: 1, dCol: 0, extend: false) }
                    .onExitCommand { editing = nil; gridFocused = true }
                    .padding(.horizontal, 6)
            } else {
                Text(sheet.display(ref))
                    .font(.system(size: 12.5, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(isError(value) ? .red : .primary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
        }
        .frame(width: Self.columnWidth, height: Self.rowHeight)
        .background(selected ? Color.accentColor.opacity(isFocus ? 0.06 : 0.14) : (isHeader ? Color.primary.opacity(0.03) : Color.clear))
        .overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 0.5) }
        .overlay { if isFocus { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) } }
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { beginEditing(ref, text: sheet.raw(ref)) })
        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded { focus = ref; syncFormula() })
        .simultaneousGesture(TapGesture().onEnded {
            if NSEvent.modifierFlags.contains(.shift) { return }
            if let current = editing, current != ref { commit(current, editText) }
            anchor = ref
            focus = ref
            syncFormula()
            gridFocused = true
        })
    }

    private func isText(_ value: CellValue) -> Bool { if case .text = value { return true }; return false }
    private func isError(_ value: CellValue) -> Bool { if case .error = value { return true }; return false }

    // MARK: Fogli

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Array(spreadsheet.sheets.enumerated()), id: \.element.id) { i, item in
                Group {
                    if renaming == i {
                        TextField("Nome", text: Binding(get: { item.name }, set: { name in mutate { $0.sheets[i].name = name } }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onSubmit { renaming = nil }
                    } else {
                        Text(item.name)
                            .font(DS.Fonts.caption)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(i == index ? Color.surface : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { sheetIndex = i; syncFormula() }
                            .onTapGesture(count: 2) { renaming = i }
                            .contextMenu {
                                Button("Rinomina") { renaming = i }
                                Button("Duplica") { mutate { var copy = $0.sheets[i]; copy.id = UUID(); copy.name += " copia"; $0.sheets.insert(copy, at: i + 1) } }
                                if spreadsheet.sheets.count > 1 {
                                    Button("Elimina foglio", role: .destructive) {
                                        mutate { $0.sheets.remove(at: i) }
                                        sheetIndex = max(0, i - 1)
                                    }
                                }
                            }
                    }
                }
            }
            Button {
                mutate { $0.sheets.append(Sheet(name: "Foglio \($0.sheets.count + 1)", columns: 8, rows: 30)) }
                sheetIndex = spreadsheet.sheets.count - 1
            } label: { Image(systemName: "plus") }
            .buttonStyle(.borderless)
            .iconHelp("Nuovo foglio")
            Spacer()
            let numbers = selectedNumbers
            if numbers.count > 1 {
                Text("Somma \(FormulaEngine.format(numbers.reduce(0, +)))  ·  Media \(FormulaEngine.format(numbers.reduce(0, +) / Double(numbers.count)))  ·  Conteggio \(numbers.count)")
                    .font(DS.Fonts.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.surfaceSubtle)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectedNumbers: [Double] {
        let s = selection
        return (s.top...s.bottom).flatMap { row in (s.left...s.right).compactMap { col -> Double? in
            if case .number(let n) = sheet.value(CellRef(col: col, row: row)) { n } else { nil }
        } }
    }

    // MARK: Modifiche

    private func mutate(_ change: (inout Spreadsheet) -> Void) {
        var copy = spreadsheet
        change(&copy)
        artifact.content = .sheet(copy)
    }

    private func mutateSheet(_ change: (inout Sheet) -> Void) {
        let i = index
        mutate { change(&$0.sheets[i]) }
    }

    private func syncFormula() { formulaText = sheet.raw(focus) }

    private func beginEditing(_ ref: CellRef, text: String) {
        anchor = ref
        focus = ref
        editText = text
        editing = ref
        cellFocused = true
    }

    private func commit(_ ref: CellRef, _ raw: String) {
        mutateSheet { $0.set(ref, raw.trimmingCharacters(in: .whitespaces)) }
        editing = nil
        syncFormula()
    }

    private func move(dRow: Int, dCol: Int, extend: Bool) {
        let f = focus
        let next = CellRef(col: min(max(0, f.col + dCol), sheet.columns - 1), row: min(max(0, f.row + dRow), sheet.rows - 1))
        focus = next
        if !extend { anchor = next }
        syncFormula()
        gridFocused = true
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard editing == nil else { return .ignored }
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .upArrow: move(dRow: -1, dCol: 0, extend: shift); return .handled
        case .downArrow: move(dRow: 1, dCol: 0, extend: shift); return .handled
        case .leftArrow: move(dRow: 0, dCol: -1, extend: shift); return .handled
        case .rightArrow: move(dRow: 0, dCol: 1, extend: shift); return .handled
        case .tab: move(dRow: 0, dCol: shift ? -1 : 1, extend: false); return .handled
        case .return: beginEditing(focus, text: sheet.raw(focus)); return .handled
        case .delete, .deleteForward: clearSelection(); return .handled
        default:
            guard press.modifiers.isDisjoint(with: [.command, .control]), let ch = press.characters.first, !ch.isNewline,
                  ch.isLetter || ch.isNumber || "=-+.,€%(\"".contains(ch) else { return .ignored }
            beginEditing(focus, text: press.characters)
            return .handled
        }
    }

    private func clearSelection() {
        let s = selection
        mutateSheet { sheet in
            for row in s.top...s.bottom { for col in s.left...s.right { sheet.set(CellRef(col: col, row: row), "") } }
        }
        syncFormula()
    }

    private func setFormat(_ format: CellFormat) {
        let s = selection
        mutateSheet { sheet in
            for row in s.top...s.bottom { for col in s.left...s.right { sheet.formats[CellRef(col: col, row: row).name] = format } }
        }
    }

    private func insertFunction(_ name: String) {
        let s = selection
        let target = CellRef(col: s.left, row: s.bottom + 1)
        mutateSheet { $0.set(target, "=\(name)(\(selectionRange))") }
        anchor = target
        focus = target
        syncFormula()
    }

    /// Sposta le celle e riscrive i riferimenti nelle formule (stessa logica delle modifiche fatte dalla chat).
    private func shift(rows fromRow: Int? = nil, cols fromCol: Int? = nil, by delta: Int) {
        mutateSheet { $0.shift(rows: fromRow, cols: fromCol, by: delta) }
    }

    private func insertRow(at row: Int) { shift(rows: row, by: 1) }
    private func insertColumn(at col: Int) { shift(cols: col, by: 1) }
    private func deleteRows() { let s = selection; shift(rows: s.top, by: -(s.bottom - s.top + 1)) }
    private func deleteColumns() { let s = selection; shift(cols: s.left, by: -(s.right - s.left + 1)) }

    private func addChart(_ kind: ChartSpec.Kind) {
        let s = selection
        let range = s.top == s.bottom && s.left == s.right ? usedRange : selectionRange
        mutateSheet { $0.charts.append(ChartSpec(kind: kind, range: range, title: $0.name)) }
    }

    private var usedRange: String {
        let rows = (sheet.cells.keys.compactMap { CellRef($0)?.row }.max() ?? 1)
        let cols = (sheet.cells.keys.compactMap { CellRef($0)?.col }.max() ?? 1)
        return "A1:\(CellRef(col: cols, row: rows).name)"
    }

    private func removeChart(_ id: UUID) { mutateSheet { $0.charts.removeAll { $0.id == id } } }

    private func updateChart(_ id: UUID, kind: ChartSpec.Kind) {
        mutateSheet { sheet in if let i = sheet.charts.firstIndex(where: { $0.id == id }) { sheet.charts[i].kind = kind } }
    }
}

/// Grafico collegato a un intervallo del foglio: si aggiorna quando cambiano i dati.
struct ChartBlock: View {
    let spec: ChartSpec
    let sheet: Sheet
    let onRemove: () -> Void
    let onKind: (ChartSpec.Kind) -> Void

    private struct Point: Identifiable {
        let id = UUID()
        let label: String
        let series: String
        let value: Double
    }

    var body: some View {
        let data = sheet.series(for: spec.range)
        let points = data.series.flatMap { series in zip(data.labels, series.values).map { Point(label: $0, series: series.name, value: $1) } }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(spec.title).font(DS.Fonts.bodyStrong)
                Text(spec.range).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Picker("Tipo", selection: Binding(get: { spec.kind }, set: onKind)) {
                    Image(systemName: "chart.bar").tag(ChartSpec.Kind.bar)
                    Image(systemName: "chart.xyaxis.line").tag(ChartSpec.Kind.line)
                    Image(systemName: "chart.pie").tag(ChartSpec.Kind.pie)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            Chart(points) { point in
                switch spec.kind {
                case .bar:
                    BarMark(x: .value("Voce", point.label), y: .value("Valore", point.value))
                        .foregroundStyle(by: .value("Serie", point.series))
                        .position(by: .value("Serie", point.series))
                        .cornerRadius(3)
                case .line:
                    LineMark(x: .value("Voce", point.label), y: .value("Valore", point.value))
                        .foregroundStyle(by: .value("Serie", point.series))
                        .symbol(by: .value("Serie", point.series))
                        .interpolationMethod(.monotone)
                case .pie:
                    if point.series == data.series.first?.name {
                        SectorMark(angle: .value("Valore", max(0, point.value)), innerRadius: .ratio(0.5), angularInset: 1.5)
                            .foregroundStyle(by: .value("Voce", point.label))
                            .cornerRadius(3)
                    }
                }
            }
            .chartForegroundStyleScale(range: [ArtifactKind.numbers.tint, Color(hex: 0x2F6BF0), Color(hex: 0xF5A524), Color(hex: 0xE5484D), Color(hex: 0x8E4EC6), Color(hex: 0x8FD9AE)])
            .chartLegend(position: .top, alignment: .leading)
            .frame(width: 560, height: 260)
        }
        .padding(14)
        .background(Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
    }
}
