import AppKit
import SiriCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Temi e rendering delle slide

extension DeckTheme {
    var background: AnyShapeStyle {
        switch self {
        case .notte: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x1B1F3B), Color(hex: 0x2B2F77), Color(hex: 0x5B3E9E)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .chiaro: AnyShapeStyle(Color.white)
        case .vivace: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFF8A3D), Color(hex: 0xFF4F7B), Color(hex: 0xB14BF4)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    var text: Color { self == .chiaro ? Color(hex: 0x1B1C20) : .white }
    var secondary: Color { self == .chiaro ? Color(hex: 0x55585F) : .white.opacity(0.8) }
    var accent: Color {
        switch self {
        case .notte: Color(hex: 0xFF6F91)
        case .chiaro: ArtifactKind.keynote.tint
        case .vivace: Color(hex: 0xFFE066)
        }
    }
}

/// Slide 16:9 disegnata in proporzione alla larghezza: miniature, canvas, riproduzione ed export PDF.
struct SlideCanvas: View {
    let slide: Slide
    let theme: DeckTheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(theme.background)
                if slide.layout == .titolo && theme != .chiaro {
                    Circle().fill(theme.accent.opacity(0.35)).frame(width: geo.size.width * 0.5)
                        .blur(radius: geo.size.width * 0.08)
                        .offset(x: geo.size.width * 0.6, y: geo.size.width * 0.05)
                }
                ForEach(slide.elements) { element in
                    SlideElementView(element: element, theme: theme, scale: geo.size.width / 1280)
                        .frame(width: element.width * geo.size.width, height: element.height * geo.size.height)
                        .position(x: (element.x + element.width / 2) * geo.size.width, y: (element.y + element.height / 2) * geo.size.height)
                }
            }
            .clipped()
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }
}

struct SlideElementView: View {
    let element: SlideElement
    let theme: DeckTheme
    let scale: CGFloat

    private var color: Color {
        Color(hexString: element.colorHex) ?? (element.role == .subtitle ? theme.secondary : theme.text)
    }

    private var alignment: (text: TextAlignment, frame: Alignment) {
        switch element.alignment {
        case "center": (.center, .top)
        case "trailing": (.trailing, .topTrailing)
        default: (.leading, .topLeading)
        }
    }

    var body: some View {
        switch element.kind {
        case .text:
            Text(element.text)
                .font(.system(size: max(4, element.fontSize * scale), weight: element.bold ? .bold : .regular))
                .foregroundStyle(color)
                .multilineTextAlignment(alignment.text)
                .lineSpacing(element.fontSize * scale * 0.2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frame)
        case .image:
            if let path = element.imagePath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 8 * scale))
            } else {
                RoundedRectangle(cornerRadius: 8 * scale).fill(theme.text.opacity(0.1))
                    .overlay(Image(systemName: "photo").font(.system(size: 40 * scale)).foregroundStyle(theme.text.opacity(0.4)))
            }
        case .shape:
            let fill = Color(hexString: element.colorHex) ?? theme.accent
            if element.shape == .ellipse { Ellipse().fill(fill) } else { RoundedRectangle(cornerRadius: 10 * scale).fill(fill) }
        }
    }
}

// MARK: - Editor

/// Replica semplificata di Keynote: navigatore, canvas con elementi liberi, temi, riproduzione.
struct KeynoteEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Bindable var artifact: ArtifactModel
    @State private var selectedSlide = 0
    @State private var selectedElement = UUID?.none
    @State private var editingElement = UUID?.none
    @State private var showImage = false
    @State private var dragOrigin = SlideElement?.none
    private var deck: Deck { artifact.deck ?? Deck(title: "", slides: []) }
    private var index: Int { min(selectedSlide, max(0, deck.slides.count - 1)) }
    private var element: SlideElement? {
        guard deck.slides.indices.contains(index) else { return nil }
        return deck.slides[index].elements.first { $0.id == selectedElement }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                navigator
                Divider()
                VStack(spacing: 12) {
                    canvas
                    if deck.slides.indices.contains(index) {
                        TextField("Note del relatore", text: Binding(get: { deck.slides[index].notes }, set: { notes in mutate { $0.slides[index].notes = notes } }), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                            .frame(maxWidth: 900)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
        .onChange(of: selectedSlide) { _, value in EditorBridge.selectedSlide[artifact.id] = value }
        // Dopo una modifica dalla chat si mostra la slide cambiata o aggiunta.
        .onChange(of: artifact.revision) { _, _ in
            if let focus = EditorBridge.focusSlide.removeValue(forKey: artifact.id) { selectedSlide = focus; selectedElement = nil }
        }
        .onKeyPress(.delete) {
            guard editingElement == nil, selectedElement != nil else { return .ignored }
            deleteElement()
            return .handled
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        EditorToolbar {
            Menu {
                ForEach(SlideLayout.allCases, id: \.self) { layout in
                    Button(layout.label) { addSlide(layout) }
                }
            } label: { Label("Nuova slide", systemImage: "plus.rectangle.on.rectangle") }
            .fixedSize()
            ToolbarDivider()
            Button { addText() } label: { Label("Testo", systemImage: "textbox") }
            Menu {
                Button("Rettangolo") { addShape(.rectangle) }
                Button("Ellisse") { addShape(.ellipse) }
            } label: { Label("Forma", systemImage: "square.on.circle") }
            .fixedSize()
            Menu {
                Button("Da file…") { chooseImage() }
                Button("Genera con Image Playground…") { showImage = true }
            } label: { Label("Immagine", systemImage: "photo") }
            .fixedSize()
            .popover(isPresented: $showImage) {
                GenerateImagePopover { url in addImage(url); showImage = false }
            }
            if let element {
                ToolbarDivider()
                if element.kind == .text {
                    Button { updateElement { $0.fontSize = max(10, $0.fontSize - 4) } } label: { Image(systemName: "textformat.size.smaller") }
                    Text("\(Int(element.fontSize))").font(DS.Fonts.caption).monospacedDigit().frame(width: 26)
                    Button { updateElement { $0.fontSize = min(160, $0.fontSize + 4) } } label: { Image(systemName: "textformat.size.larger") }
                    Toggle(isOn: Binding(get: { element.bold }, set: { value in updateElement { $0.bold = value } })) { Image(systemName: "bold") }
                        .toggleStyle(.button)
                    Picker("Allineamento", selection: Binding(get: { element.alignment }, set: { value in updateElement { $0.alignment = value } })) {
                        Image(systemName: "text.alignleft").tag("leading")
                        Image(systemName: "text.aligncenter").tag("center")
                        Image(systemName: "text.alignright").tag("trailing")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if element.kind != .image {
                    ColorPicker("Colore", selection: Binding(get: { Color(hexString: element.colorHex) ?? deck.theme.text },
                                                             set: { color in updateElement { $0.colorHex = color.hexString } }))
                        .labelsHidden()
                }
                Menu {
                    Button("Porta in primo piano") { reorderElement(toFront: true) }
                    Button("Porta sullo sfondo") { reorderElement(toFront: false) }
                    Button("Duplica") { duplicateElement() }
                    Divider()
                    Button("Elimina", role: .destructive) { deleteElement() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Spacer()
            Picker("Tema", selection: Binding(get: { deck.theme }, set: { theme in mutate { $0.theme = theme } })) {
                ForEach(DeckTheme.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
            Button {
                state.presenting = deck
                openWindow(id: "presenter")
            } label: { Label("Riproduci", systemImage: "play.fill") }
            .buttonStyle(.borderedProminent)
            .tint(ArtifactKind.keynote.tint)
            .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }

    // MARK: Navigatore

    private var navigator: some View {
        List(selection: Binding(get: { index }, set: { selectedSlide = $0 ?? 0; selectedElement = nil })) {
            ForEach(Array(deck.slides.enumerated()), id: \.element.id) { offset, slide in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(offset + 1)").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                    SlideCanvas(slide: slide, theme: deck.theme)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.hairline))
                }
                .padding(.vertical, 3)
                .tag(offset)
                .contextMenu {
                    Button("Duplica") { mutate { var copy = $0.slides[offset]; copy.id = UUID(); $0.slides.insert(copy, at: offset + 1) } }
                    if deck.slides.count > 1 {
                        Button("Elimina", role: .destructive) {
                            mutate { $0.slides.remove(at: offset) }
                            selectedSlide = max(0, offset - 1)
                        }
                    }
                }
            }
            .onMove { from, to in mutate { $0.slides.move(fromOffsets: from, toOffset: to) } }
        }
        .listStyle(.sidebar)
        .frame(width: 180)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let width = min(geo.size.width, geo.size.height * 16 / 9)
            let size = CGSize(width: width, height: width * 9 / 16)
            ZStack(alignment: .topLeading) {
                if deck.slides.indices.contains(index) {
                    let slide = deck.slides[index]
                    Rectangle().fill(deck.theme.background)
                        .onTapGesture { selectedElement = nil; editingElement = nil }
                    ForEach(slide.elements) { element in
                        editableElement(element, size: size)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func editableElement(_ element: SlideElement, size: CGSize) -> some View {
        let isSelected = selectedElement == element.id
        let frame = CGRect(x: element.x * size.width, y: element.y * size.height, width: element.width * size.width, height: element.height * size.height)
        Group {
            if editingElement == element.id {
                TextEditor(text: Binding(get: { element.text }, set: { text in updateElement(element.id) { $0.text = text } }))
                    .font(.system(size: max(6, element.fontSize * size.width / 1280), weight: element.bold ? .bold : .regular))
                    .foregroundStyle(Color(hexString: element.colorHex) ?? deck.theme.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.08))
            } else {
                SlideElementView(element: element, theme: deck.theme, scale: size.width / 1280)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .overlay {
            if isSelected {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(Color.white).overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                            .frame(width: 12, height: 12)
                            .offset(x: 6, y: 6)
                            .gesture(DragGesture(minimumDistance: 1).onChanged { value in resize(element, by: value.translation, in: size) }.onEnded { _ in dragOrigin = nil })
                            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                    }
            }
        }
        .contentShape(Rectangle())
        .position(x: frame.midX, y: frame.midY)
        .onTapGesture(count: 2) {
            if element.kind == .text { selectedElement = element.id; editingElement = element.id }
        }
        .onTapGesture {
            if editingElement != element.id { editingElement = nil }
            selectedElement = element.id
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    guard editingElement != element.id else { return }
                    selectedElement = element.id
                    move(element, by: value.translation, in: size)
                }
                .onEnded { _ in dragOrigin = nil }
        )
    }

    // MARK: Modifiche

    private func mutate(_ change: (inout Deck) -> Void) {
        var copy = deck
        change(&copy)
        artifact.content = .deck(copy)
    }

    private func updateElement(_ id: UUID? = nil, _ change: (inout SlideElement) -> Void) {
        guard let id = id ?? selectedElement else { return }
        let i = index
        mutate { deck in
            guard deck.slides.indices.contains(i), let e = deck.slides[i].elements.firstIndex(where: { $0.id == id }) else { return }
            change(&deck.slides[i].elements[e])
        }
    }

    private func move(_ element: SlideElement, by translation: CGSize, in size: CGSize) {
        let origin = dragOrigin ?? element
        dragOrigin = origin
        updateElement(element.id) {
            $0.x = min(max(-0.2, origin.x + translation.width / size.width), 1 - $0.width * 0.2)
            $0.y = min(max(-0.2, origin.y + translation.height / size.height), 1 - $0.height * 0.2)
        }
    }

    private func resize(_ element: SlideElement, by translation: CGSize, in size: CGSize) {
        let origin = dragOrigin ?? element
        dragOrigin = origin
        updateElement(element.id) {
            $0.width = max(0.04, origin.width + translation.width / size.width)
            $0.height = max(0.04, origin.height + translation.height / size.height)
        }
    }

    private func addSlide(_ layout: SlideLayout) {
        let slide = Slide.make(layout, title: layout == .vuota ? "" : "Titolo", subtitle: "Sottotitolo", bullets: ["Primo punto", "Secondo punto"])
        let insertAt = min(index + 1, deck.slides.count)
        mutate { $0.slides.insert(slide, at: insertAt) }
        selectedSlide = insertAt
    }

    private func addElement(_ element: SlideElement) {
        guard deck.slides.indices.contains(index) else { return }
        let i = index
        mutate { $0.slides[i].elements.append(element) }
        selectedElement = element.id
    }

    private func addText() {
        addElement(SlideElement(kind: .text, x: 0.3, y: 0.4, width: 0.4, height: 0.14, text: "Testo", fontSize: 36))
    }

    private func addShape(_ shape: SlideElement.Shape) {
        var element = SlideElement(kind: .shape, x: 0.4, y: 0.35, width: 0.2, height: 0.3)
        element.shape = shape
        addElement(element)
    }

    private func addImage(_ url: URL) {
        var element = SlideElement(kind: .image, x: 0.3, y: 0.2, width: 0.4, height: 0.6)
        element.imagePath = url.path
        addElement(element)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { addImage(url) }
    }

    private func deleteElement() {
        guard let id = selectedElement else { return }
        let i = index
        mutate { $0.slides[i].elements.removeAll { $0.id == id } }
        selectedElement = nil
    }

    private func duplicateElement() {
        guard var copy = element else { return }
        copy.id = UUID()
        copy.x += 0.03
        copy.y += 0.03
        addElement(copy)
    }

    private func reorderElement(toFront: Bool) {
        guard let id = selectedElement else { return }
        let i = index
        mutate { deck in
            guard let e = deck.slides[i].elements.firstIndex(where: { $0.id == id }) else { return }
            let item = deck.slides[i].elements.remove(at: e)
            if toFront { deck.slides[i].elements.append(item) } else { deck.slides[i].elements.insert(item, at: 0) }
        }
    }
}

// MARK: - Riproduzione

/// Finestra di presentazione a schermo intero: frecce o spazio per avanzare, esc per uscire.
struct PresenterView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var current = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let deck = state.presenting, !deck.slides.isEmpty {
                SlideCanvas(slide: deck.slides[min(current, deck.slides.count - 1)], theme: deck.theme)
                    .id(current)
                    .transition(.opacity)
                VStack {
                    Spacer()
                    Text("\(current + 1) / \(deck.slides.count)")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                        .padding(10)
                }
            } else {
                Text("Nessuna presentazione").foregroundStyle(.white)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.rightArrow, .space, .downArrow, .return]) { _ in step(1); return .handled }
        .onKeyPress(keys: [.leftArrow, .upArrow]) { _ in step(-1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onTapGesture { step(1) }
        .onAppear {
            focused = true
            current = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
        }
    }

    private func step(_ delta: Int) {
        guard let count = state.presenting?.slides.count else { return }
        let next = current + delta
        if next >= count { close(); return }
        withAnimation(.easeInOut(duration: 0.35)) { current = max(0, next) }
    }

    private func close() {
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismissWindow(id: "presenter") }
    }
}
