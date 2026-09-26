import AppKit
import SiriCore
import SwiftUI
import WebKit

// MARK: - Editor di testo con strumenti per Markdown

/// Collegamento tra la barra degli strumenti e la vista di testo (selezione, inserimenti).
@MainActor
final class TextEditingController {
    weak var textView: NSTextView?

    /// Avvolge la selezione (grassetto, corsivo, codice…) o inserisce i marcatori al cursore.
    func wrap(_ prefix: String, _ suffix: String, placeholder: String = "testo") {
        guard let view = textView else { return }
        let range = view.selectedRange()
        let selected = (view.string as NSString).substring(with: range)
        let body = selected.isEmpty ? placeholder : selected
        view.insertText(prefix + body + suffix, replacementRange: range)
        view.setSelectedRange(NSRange(location: range.location + (prefix as NSString).length, length: (body as NSString).length))
        view.window?.makeFirstResponder(view)
    }

    /// Mette un prefisso all'inizio delle righe selezionate (titoli, elenchi, citazioni, caselle).
    func prefixLines(_ prefix: String) {
        guard let view = textView else { return }
        let text = view.string as NSString
        let range = text.lineRange(for: view.selectedRange())
        let lines = text.substring(with: range).components(separatedBy: "\n")
        let updated = lines.enumerated().map { index, line in
            line.isEmpty && index == lines.count - 1 ? line : prefix + line.replacingOccurrences(of: #"^(#{1,6} |[-*] \[[ x]\] |[-*] |> |\d+\. )"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
        view.insertText(updated, replacementRange: range)
        view.window?.makeFirstResponder(view)
    }

    func insert(_ text: String) {
        guard let view = textView else { return }
        view.insertText(text, replacementRange: view.selectedRange())
        view.window?.makeFirstResponder(view)
    }
}

struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    let controller: TextEditingController
    var monospaced = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = !monospaced
        view.font = monospaced ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 14)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.drawsBackground = false
        scroll.drawsBackground = false
        view.string = text
        controller.textView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        controller.textView = view
        if view.string != text { view.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { text.wrappedValue = view.string }
        }
    }
}

/// Anteprima HTML (Markdown convertito o pagina web del progetto).
struct HTMLPreview: NSViewRepresentable {
    enum Source: Equatable { case html(String), file(URL, revision: Int) }
    let source: Source
    /// Le anteprime generate (Markdown, schede) non eseguono script; le pagine del progetto sì.
    var allowsScripts: Bool? = nil
    /// Cartella del file Markdown: i collegamenti relativi («note/idea.md») si risolvono da lì.
    var baseURL: URL? = nil
    /// Collegamenti ad altri file (`[[Nome]]`, «note/idea.md»): li apre l'app, in un'altra scheda.
    var onOpenLink: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let scripts: Bool = allowsScripts ?? { if case .file = source { true } else { false } }()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = scripts
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        load(view)
        context.coordinator.last = source
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.baseURL = baseURL
        guard context.coordinator.last != source else { return }
        context.coordinator.last = source
        load(view)
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onOpenLink = onOpenLink
        coordinator.baseURL = baseURL
        return coordinator
    }

    /// I link cliccati nell'anteprima si aprono nel browser (solo web ed email), non dentro l'anteprima.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var last: Source?
        var onOpenLink: ((String) -> Void)?
        var baseURL: URL?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // `[[Nome]]` e collegamenti a file di testo: si aprono nelle schede dell'app, non dentro l'anteprima.
            if let onOpenLink {
                if url.scheme == "siriai-wiki" {
                    decisionHandler(.cancel)
                    onOpenLink(String(url.absoluteString.dropFirst("siriai-wiki:".count)))
                    return
                }
                if url.isFileURL, EditableFiles.extensions.contains(url.pathExtension.lowercased()) {
                    decisionHandler(.cancel)
                    let base = baseURL?.standardizedFileURL.path ?? ""
                    let path = url.standardizedFileURL.path
                    onOpenLink(path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path)
                    return
                }
            }
            // Pagine locali del progetto e ancore restano nell'anteprima.
            if url.isFileURL || url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        }
    }

    private func load(_ view: WKWebView) {
        switch source {
        case .html(let html): view.loadHTMLString(html, baseURL: baseURL)
        case .file(let url, _): view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}

/// Visualizza e modifica un file di testo del progetto: Markdown con anteprima formattata, HTML/CSS con anteprima live.
struct FileEditorView: View {
    @Environment(AppState.self) private var state
    let project: ProjectModel
    let path: String
    /// In una scheda il Markdown si apre da leggere (con «Modifica» e «Affiancata» a un clic).
    var startsInReading = false
    /// Collegamenti ad altri file cliccati nell'anteprima (nelle schede si aprono in un'altra scheda).
    var onOpenLink: ((String) -> Void)? = nil

    enum Mode: String { case preview = "Anteprima", edit = "Modifica", split = "Affiancata" }

    @State private var text = ""
    @State private var saved = ""
    @State private var snapshot: LiveTextFile.Snapshot?
    @State private var mode = Mode.preview
    @State private var revision = 0
    @State private var error = String?.none
    @State private var conflicted = false
    @State private var autosaveTask: Task<Void, Never>?
    private let controller = TextEditingController()

    private var ext: String { (path as NSString).pathExtension.lowercased() }
    private var isMarkdown: Bool { ["md", "markdown"].contains(ext) }
    private var isWeb: Bool { ["html", "htm", "css", "js"].contains(ext) }
    private var hasPreview: Bool { isMarkdown || isWeb }
    private var dirty: Bool { text != saved }
    private var url: URL? { try? project.files.resolve(path) }

    /// Per CSS e JS l'anteprima mostra la pagina index.html della stessa cartella.
    private var previewURL: URL? {
        guard let url else { return nil }
        if ext == "html" || ext == "htm" { return url }
        let index = url.deletingLastPathComponent().appending(path: "index.html")
        return FileManager.default.fileExists(atPath: index.path) ? index : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isMarkdown && mode != .preview { markdownToolbar; Divider() }
            content
            if let message = error {
                Text(message).font(DS.Fonts.caption).foregroundStyle(.red).padding(8)
            }
        }
        .task(id: path) {
            load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                refreshFromDisk()
            }
        }
        .onChange(of: text) { _, _ in
            autosaveTask?.cancel()
            guard dirty, project.allowWrite, !conflicted else { return }
            autosaveTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                if !Task.isCancelled { save() }
            }
        }
        .onDisappear {
            autosaveTask?.cancel()
            if dirty && !conflicted { save() }
        }
        .background(Color.canvas)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isMarkdown ? "text.document" : isWeb ? "chevron.left.forwardslash.chevron.right" : "doc.text")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent + (dirty ? " •" : "")).font(DS.Fonts.bodyStrong).lineLimit(1)
                Text(path).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if conflicted {
                Button("Copia il tuo testo") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                Button("Ricarica versione esterna") { load() }
                    .help("Sostituisce le modifiche non salvate con quelle presenti sul disco")
            } else if project.allowWrite {
                Text(dirty ? String(localized: "Salvataggio…") : String(localized: "Salvato · Live"))
                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
            }
            if hasPreview {
                Picker("Vista", selection: $mode) {
                    Text("Anteprima").tag(Mode.preview)
                    Text("Modifica").tag(Mode.edit)
                    Text("Affiancata").tag(Mode.split)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if isWeb, let previewURL {
                Button { state.openInBrowser(previewURL) } label: { Label("Apri nel browser", systemImage: "safari") }
            }
            Menu {
                Button("Riassumi con Siri AI+") { state.send(String(localized: "Riassumi il file \(path)")) }
                Button("Migliora il testo con Siri AI+") { state.send(String(localized: "Migliora la scrittura del file \(path) mantenendo il contenuto")) }
                Divider()
                if !startsInReading, let url { Button("Apri in una scheda") { state.openFile(url) } }
                Button("Apri con l'app predefinita") { if let url { NSWorkspace.shared.open(url) } }
                Button("Mostra nel Finder") { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuIndicator(.hidden)
            .fixedSize()
            Button("Salva", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
                .disabled(!dirty || !project.allowWrite || conflicted || snapshot == nil)
                .help(project.allowWrite ? String(localized: "Salva (⌘S)") : String(localized: "La scrittura è disattivata per questo progetto"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var markdownToolbar: some View {
        HStack(spacing: 2) {
            toolbarButton("bold", String(localized: "Grassetto (⌘B)")) { controller.wrap("**", "**") }.keyboardShortcut("b")
            toolbarButton("italic", String(localized: "Corsivo (⌘I)")) { controller.wrap("*", "*") }.keyboardShortcut("i")
            toolbarButton("strikethrough", String(localized: "Barrato")) { controller.wrap("~~", "~~") }
            toolbarButton("highlighter", String(localized: "Evidenzia")) { controller.wrap("==", "==") }
            Divider().frame(height: 16).padding(.horizontal, 4)
            Menu {
                Button("Titolo 1") { controller.prefixLines("# ") }
                Button("Titolo 2") { controller.prefixLines("## ") }
                Button("Titolo 3") { controller.prefixLines("### ") }
            } label: { Image(systemName: "textformat.size") }
            .menuIndicator(.hidden).fixedSize().iconHelp(String(localized: "Titolo"))
            toolbarButton("list.bullet", String(localized: "Elenco")) { controller.prefixLines("- ") }
            toolbarButton("list.number", String(localized: "Elenco numerato")) { controller.prefixLines("1. ") }
            toolbarButton("checklist", String(localized: "Casella da spuntare")) { controller.prefixLines("- [ ] ") }
            toolbarButton("text.quote", String(localized: "Citazione")) { controller.prefixLines("> ") }
            Divider().frame(height: 16).padding(.horizontal, 4)
            toolbarButton("link", String(localized: "Link")) { controller.wrap("[", "](https://)", placeholder: String(localized: "testo del link")) }
            toolbarButton("chevron.left.forwardslash.chevron.right", String(localized: "Codice")) { controller.wrap("`", "`", placeholder: "codice") }
            toolbarButton("tablecells", String(localized: "Tabella")) { controller.insert(String(localized: "\n| Colonna | Colonna |\n| --- | --- |\n| Valore | Valore |\n")) }
            toolbarButton("minus", String(localized: "Linea")) { controller.insert("\n---\n") }
            Spacer()
            Text("\(text.split(whereSeparator: \.isWhitespace).count) parole").font(DS.Fonts.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.surface)
    }

    private func toolbarButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 22) }.help(help)
    }

    @ViewBuilder
    private var content: some View {
        let editor = CodeTextView(text: $text, controller: controller, monospaced: !isMarkdown)
            .background(Color.surface)
            .disabled(!project.allowWrite)
        if hasPreview {
            switch mode {
            case .edit: editor
            case .preview: preview
            case .split:
                HStack(spacing: 0) {
                    editor.frame(maxWidth: .infinity)
                    Divider()
                    preview.frame(maxWidth: .infinity)
                }
            }
        } else {
            editor
        }
    }

    @ViewBuilder
    private var preview: some View {
        if isMarkdown {
            HTMLPreview(source: .html(Markdown.page(text, title: path)), baseURL: url?.deletingLastPathComponent(),
                        onOpenLink: onOpenLink ?? { target in if let url { state.openLinkedFile(target, from: url) } })
        } else if let previewURL {
            HTMLPreview(source: .file(previewURL, revision: revision))
                .overlay(alignment: .top) {
                    if dirty {
                        Text("L'anteprima si aggiorna dopo il salvataggio automatico").font(DS.Fonts.caption)
                            .padding(.horizontal, 10).padding(.vertical, 4).background(.regularMaterial, in: Capsule()).padding(8)
                    }
                }
        } else {
            Text("Nessuna pagina index.html in questa cartella da mostrare.").font(DS.Fonts.body).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() {
        do {
            let file = try project.files.resolve(path)
            let current = try LiveTextFile.read(file)
            snapshot = current
            text = current.text
            saved = current.text
            mode = hasPreview ? (startsInReading && isMarkdown ? .preview : .split) : .edit
            conflicted = false
            error = nil
            revision += 1
        } catch {
            snapshot = nil
            self.error = error.localizedDescription
        }
    }

    private func refreshFromDisk() {
        guard let snapshot, let url else { return }
        do {
            let current = try LiveTextFile.read(url)
            guard current.data != snapshot.data else { return }
            if dirty {
                conflicted = true
                error = LiveTextFile.EditError.changed.localizedDescription
            } else {
                self.snapshot = current
                text = current.text
                saved = current.text
                revision += 1
                state.browser.reloadIfShowing(url)
                error = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard project.allowWrite, !conflicted, dirty, let snapshot, let url else { return }
        do {
            try project.files.ensureWritable(path)
            let updated = try LiveTextFile.save(text, to: url, expected: snapshot)
            self.snapshot = updated
            project.files.invalidateCache()
            saved = text
            revision += 1
            state.projectRevision += 1
            state.browser.reloadIfShowing(url)
            error = nil
        } catch {
            self.error = error.localizedDescription
            if let editError = error as? LiveTextFile.EditError, case .changed = editError { conflicted = true }
        }
    }
}

// MARK: - Sito generato

struct WebsiteCard: View {
    @Environment(AppState.self) private var state
    let model: WebsiteCardModel

    var body: some View {
        Card(title: model.draft.title, subtitle: model.savedFolder.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? String(localized: "\(model.draft.folder)/ · index.html, style.css"),
             status: model.status) {
            Image(systemName: "globe").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor).frame(width: 26)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HTMLPreview(source: .html(inlinePreview))
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
                if let error = model.error { Text(error).font(DS.Fonts.caption).foregroundStyle(.red) }
                HStack {
                    if model.status == .awaiting {
                        Text("Verrà creata la cartella «\(model.draft.folder)» nel progetto.").font(DS.Fonts.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Annulla") { model.status = .cancelled }
                        Button("Crea i file") { state.saveWebsite(model) }.buttonStyle(.borderedProminent)
                    } else if let folder = model.savedFolder {
                        Spacer()
                        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
                        if let projectID = model.projectID, let project = state.projects.first(where: { $0.id == projectID }) {
                            Button("Modifica i file") { state.openProjectFile(project, path: "\(model.draft.folder)/index.html") }
                        }
                        Button { state.openInBrowser(URL(fileURLWithPath: folder).appending(path: "index.html")) } label: {
                            Label("Apri nel browser", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    /// Anteprima nella scheda: il CSS viene messo dentro la pagina.
    private var inlinePreview: String {
        let html = model.draft.files["index.html"] ?? ""
        let css = model.draft.files["style.css"] ?? ""
        return html.replacingOccurrences(of: "<link rel=\"stylesheet\" href=\"style.css\">", with: "<style>\(css)</style>")
    }
}
