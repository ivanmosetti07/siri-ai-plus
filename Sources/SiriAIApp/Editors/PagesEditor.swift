import AppKit
import SiriCore
import SwiftUI
import UniformTypeIdentifiers

/// Stato dell'editor condiviso tra la toolbar SwiftUI e l'NSTextView.
@MainActor @Observable
final class PagesController {
    weak var textView: NSTextView?
    var style: PagesStyle = .body
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var fontSize: CGFloat = 14
    var alignment: NSTextAlignment = .natural
    var wordCount = 0
    var hasSelection = false

    var selectedText: String {
        guard let view = textView else { return "" }
        return (view.string as NSString).substring(with: view.selectedRange())
    }

    func refresh() {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        hasSelection = range.length > 0
        let location = min(max(0, range.location == storage.length ? range.location - 1 : range.location), max(0, storage.length - 1))
        let attributes = storage.length > 0 ? storage.attributes(at: location, effectiveRange: nil) : view.typingAttributes
        let font = attributes[.font] as? NSFont
        style = PagesStyle.detect(font)
        isBold = font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        isItalic = font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
        isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
        fontSize = font?.pointSize ?? 14
        alignment = (attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .natural
        wordCount = view.string.split(whereSeparator: \.isWhitespace).count
    }

    /// Modifica con supporto ad Annulla.
    private func edit(_ range: NSRange, _ change: (NSTextStorage) -> Void) {
        guard let view = textView, let storage = view.textStorage, view.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        change(storage)
        storage.endEditing()
        view.didChangeText()
        refresh()
    }

    private var paragraphRange: NSRange {
        guard let view = textView else { return NSRange() }
        return (view.string as NSString).paragraphRange(for: view.selectedRange())
    }

    func apply(_ style: PagesStyle) {
        let range = paragraphRange
        edit(range) { storage in storage.setAttributes(style.attributes, range: range) }
        textView?.typingAttributes = style.attributes
    }

    func toggle(_ trait: NSFontTraitMask) {
        guard let view = textView else { return }
        let range = view.selectedRange()
        let manager = NSFontManager.shared
        let enable = trait == .boldFontMask ? !isBold : !isItalic
        if range.length == 0 {
            if let font = view.typingAttributes[.font] as? NSFont {
                view.typingAttributes[.font] = enable ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait)
            }
            refresh()
            return
        }
        edit(range) { storage in
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                guard let font = value as? NSFont else { return }
                storage.addAttribute(.font, value: enable ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait), range: subrange)
            }
        }
    }

    func toggleUnderline() {
        guard let view = textView else { return }
        let range = view.selectedRange()
        let value = isUnderlined ? 0 : NSUnderlineStyle.single.rawValue
        if range.length == 0 { view.typingAttributes[.underlineStyle] = value; refresh(); return }
        edit(range) { storage in storage.addAttribute(.underlineStyle, value: value, range: range) }
    }

    func setSize(_ size: CGFloat) {
        guard let view = textView else { return }
        let range = view.selectedRange().length > 0 ? view.selectedRange() : paragraphRange
        edit(range) { storage in
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? NSFont) ?? .systemFont(ofSize: size)
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: size), range: subrange)
            }
        }
    }

    func setColor(_ color: NSColor) {
        guard let view = textView, view.selectedRange().length > 0 else { return }
        let range = view.selectedRange()
        edit(range) { storage in storage.addAttribute(.foregroundColor, value: color, range: range) }
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        let range = paragraphRange
        edit(range) { storage in
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
                let style = ((value as? NSParagraphStyle) ?? PagesStyle.body.paragraph).mutableCopy() as! NSMutableParagraphStyle
                style.alignment = alignment
                storage.addAttribute(.paragraphStyle, value: style, range: subrange)
            }
        }
    }

    /// Elenco puntato: aggiunge o toglie "• " all'inizio dei paragrafi selezionati.
    func toggleBullets() {
        guard let view = textView else { return }
        let range = paragraphRange
        let text = (view.string as NSString).substring(with: range)
        let lines = text.components(separatedBy: "\n")
        let bulleted = lines.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix("• ") }
        let newText = lines.map { line in
            guard !line.isEmpty else { return line }
            return bulleted ? String(line.dropFirst(2)) : "• " + line
        }.joined(separator: "\n")
        let attributes = view.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? PagesStyle.body.attributes
        if view.shouldChangeText(in: range, replacementString: newText) {
            view.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: newText, attributes: attributes))
            view.didChangeText()
        }
    }

    func insertImage(_ url: URL) {
        guard let view = textView, let image = ArtifactFactory.imageAttachment(url) else { return }
        view.insertText(image, replacementRange: view.selectedRange())
    }

    /// Sostituisce la selezione (o tutto il testo) mantenendo gli attributi del primo carattere.
    func replaceSelection(with text: String) {
        guard let view = textView, let storage = view.textStorage else { return }
        var range = view.selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: storage.length) }
        let attributes = storage.length > 0 ? storage.attributes(at: range.location, effectiveRange: nil) : PagesStyle.body.attributes
        if view.shouldChangeText(in: range, replacementString: text) {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
            view.didChangeText()
        }
    }
}

struct PagesEditor: View {
    @Environment(AppState.self) private var state
    @Bindable var artifact: ArtifactModel
    @State private var controller = PagesController()
    @State private var showImage = false
    @State private var aiWorking = false
    @State private var color = Color.black
    private static let aiActions: [(String, String)] = [
        ("Riscrivi", "Riscrivi il testo in modo più chiaro e scorrevole"),
        ("Abbrevia", "Accorcia il testo mantenendo i concetti chiave"),
        ("Espandi", "Espandi il testo con dettagli utili e concreti"),
        ("Correggi", "Correggi ortografia, grammatica e punteggiatura senza cambiare il contenuto"),
        ("Tono formale", "Riscrivi con un tono professionale e formale"),
        ("Tono amichevole", "Riscrivi con un tono cordiale e diretto"),
        ("Traduci in inglese", "Traduci il testo in inglese"),
        ("Elenco puntato", "Trasforma il testo in un elenco puntato sintetico, una riga per punto, con il simbolo •"),
    ]

    var body: some View {
        let controller = controller
        VStack(spacing: 0) {
            EditorToolbar {
                Picker("Stile", selection: Binding(get: { controller.style }, set: { controller.apply($0) })) {
                    ForEach(PagesStyle.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                ToolbarDivider()
                Toggle(isOn: Binding(get: { controller.isBold }, set: { _ in controller.toggle(.boldFontMask) })) { Image(systemName: "bold") }
                    .toggleStyle(.button).help("Grassetto (⌘B)").keyboardShortcut("b")
                Toggle(isOn: Binding(get: { controller.isItalic }, set: { _ in controller.toggle(.italicFontMask) })) { Image(systemName: "italic") }
                    .toggleStyle(.button).help("Corsivo (⌘I)").keyboardShortcut("i")
                Toggle(isOn: Binding(get: { controller.isUnderlined }, set: { _ in controller.toggleUnderline() })) { Image(systemName: "underline") }
                    .toggleStyle(.button).help("Sottolineato (⌘U)").keyboardShortcut("u")
                ToolbarDivider()
                Button { controller.setSize(max(8, controller.fontSize - 1)) } label: { Image(systemName: "textformat.size.smaller") }.iconHelp("Riduci")
                Text("\(Int(controller.fontSize)) pt").font(DS.Fonts.caption).monospacedDigit().frame(width: 38)
                Button { controller.setSize(min(96, controller.fontSize + 1)) } label: { Image(systemName: "textformat.size.larger") }.iconHelp("Ingrandisci")
                ColorPicker("Colore", selection: Binding(get: { color }, set: { color = $0; controller.setColor(NSColor($0)) }))
                    .labelsHidden()
                    .iconHelp("Colore del testo selezionato")
                ToolbarDivider()
                Picker("Allineamento", selection: Binding(get: { controller.alignment == .natural ? .left : controller.alignment }, set: { controller.setAlignment($0) })) {
                    Image(systemName: "text.alignleft").tag(NSTextAlignment.left)
                    Image(systemName: "text.aligncenter").tag(NSTextAlignment.center)
                    Image(systemName: "text.alignright").tag(NSTextAlignment.right)
                    Image(systemName: "text.justify").tag(NSTextAlignment.justified)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button { controller.toggleBullets() } label: { Image(systemName: "list.bullet") }.iconHelp("Elenco puntato")
                ToolbarDivider()
                Menu {
                    Button("Da file…") { chooseImage(controller) }
                    Button("Genera con Image Playground…") { showImage = true }
                } label: { Image(systemName: "photo.badge.plus") }
                .menuIndicator(.hidden)
                .fixedSize()
                .iconHelp("Inserisci immagine")
                .popover(isPresented: $showImage) {
                    GenerateImagePopover { url in controller.insertImage(url); showImage = false }
                }
                Spacer()
                Menu {
                    Text(controller.hasSelection ? "Sul testo selezionato" : "Su tutto il documento")
                    ForEach(Self.aiActions, id: \.0) { action in
                        Button(action.0) { runAI(action.1, controller) }
                    }
                } label: {
                    if aiWorking { ProgressView().controlSize(.small) } else { Label("Siri AI+", systemImage: "sparkles") }
                }
                .fixedSize()
                .disabled(aiWorking)
                .help("Riscrivi, correggi o traduci con il modello sul dispositivo")
            }
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                PageTextView(artifact: artifact, controller: controller)
                    .frame(maxWidth: 780)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                    .padding(.vertical, 20)
                    .padding(.horizontal, 24)
            }
            HStack {
                Text("\(controller.wordCount) parole").monospacedDigit()
                Spacer()
                Text("Modifica liberamente: Siri AI+ vede sempre la versione aggiornata.")
            }
            .font(DS.Fonts.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.surface)
        }
    }

    private func chooseImage(_ controller: PagesController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { controller.insertImage(url) }
    }

    private func runAI(_ instruction: String, _ controller: PagesController) {
        aiWorking = true
        Task {
            if controller.hasSelection {
                let text = controller.selectedText
                artifact.snapshot("Prima di «\(instruction.prefix(30))»")
                if !text.isEmpty, let result = try? await state.rewrite(text, instruction: instruction) { controller.replaceSelection(with: result) }
            } else {
                // Tutto il documento: un paragrafo alla volta, titoli e formattazione restano (niente si tronca).
                await state.applyDocumentInstruction(instruction, to: artifact)
            }
            aiWorking = false
        }
    }
}

/// NSTextView nella "pagina": sincronizza il testo con l'artefatto in entrambe le direzioni.
struct PageTextView: NSViewRepresentable {
    let artifact: ArtifactModel
    let controller: PagesController

    func makeCoordinator() -> Coordinator { Coordinator(artifact: artifact, controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.insertionPointColor = .black
        textView.textContainerInset = NSSize(width: 56, height: 48)
        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(artifact.document ?? NSAttributedString())
        textView.typingAttributes = PagesStyle.body.attributes
        context.coordinator.knownRevision = artifact.revision
        controller.textView = textView
        EditorBridge.pagesTextView = textView
        EditorBridge.pagesArtifactID = artifact.id
        controller.refresh()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Più documenti aperti in schede: Siri AI+ legge testo e selezione di quello davanti.
        let front = context.environment.appTabActive && context.environment.isEnabled
        if front, EditorBridge.pagesArtifactID != artifact.id {
            EditorBridge.pagesTextView = textView
            EditorBridge.pagesArtifactID = artifact.id
        }
        // Dietro (scheda nascosta o app chiuse) il testo non riceve la tastiera: quello che scrivi non finisce qui per sbaglio.
        textView.isEditable = front
        if !front, textView.window?.firstResponder === textView { DispatchQueue.main.async { textView.window?.makeFirstResponder(nil) } }
        // Modifiche arrivate da fuori (Siri AI+, ripristino versione): ricarica il testo.
        if artifact.revision != context.coordinator.knownRevision, let document = artifact.document {
            textView.textStorage?.setAttributedString(document)
            context.coordinator.knownRevision = artifact.revision
            controller.refresh()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let artifact: ArtifactModel
        let controller: PagesController
        var knownRevision = 0
        private var pending: Task<Void, Never>?

        init(artifact: ArtifactModel, controller: PagesController) {
            self.artifact = artifact
            self.controller = controller
        }

        func textDidChange(_ notification: Notification) {
            controller.refresh()
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled, let storage = self.controller.textView?.textStorage else { return }
                self.artifact.content = .document(NSAttributedString(attributedString: storage))
                self.knownRevision = self.artifact.revision
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.refresh()
        }
    }
}
