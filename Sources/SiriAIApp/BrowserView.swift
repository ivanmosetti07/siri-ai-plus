import AppKit
import SiriCore
import SwiftUI
import WebKit

/// Browser integrato (motore di Safari): Siri AI+ legge la pagina aperta, apre siti e segue i link.
@MainActor @Observable
final class BrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var url: URL?
    var title = ""
    var address = ""
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var progress = 0.0
    var error: String?
    /// Pagina da aprire quando la scheda viene davanti (salvata con la chat).
    var pendingURL: URL?
    /// Errori della console della pagina (JavaScript, file che mancano): l'anteprima del coding li mostra e li fa correggere.
    var consoleErrors: [String] = []
    /// Larghezza simulata dell'anteprima (nil = tutta la scheda): computer, tablet o telefono.
    var deviceWidth: CGFloat?
    /// La pagina è cambiata (la chat se la ricorda).
    @ObservationIgnored var onNavigate: ((URL?) -> Void)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: Self.consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = scripts
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()
        scripts.add(ConsoleRelay { [weak self] text in self?.noteConsole(text) }, name: "siriaiConsole")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.url = view.url
                    self?.address = view.url?.absoluteString ?? ""
                    self?.onNavigate?(view.url)
                }
            },
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
        ]
    }

    // MARK: Console

    /// Errori della pagina verso l'app: `console.error`, eccezioni non gestite, promesse rifiutate, file che non si caricano.
    static let consoleScript = """
    (function(){
      if (window.__siriaiConsole) return; window.__siriaiConsole = true;
      const post = (text) => { try { window.webkit.messageHandlers.siriaiConsole.postMessage(String(text).slice(0, 600)); } catch (e) {} };
      const original = console.error;
      console.error = function() {
        post(Array.from(arguments).map(a => (a && a.stack) ? String(a.stack).split('\\n')[0] : String(a)).join(' '));
        return original.apply(console, arguments);
      };
      window.addEventListener('error', function(event) {
        const target = event.target;
        if (target && target !== window && (target.src || target.href)) { post('File non trovato: ' + String(target.src || target.href).split('/').pop()); return; }
        const where = event.filename ? ' (' + String(event.filename).split('/').pop() + ':' + event.lineno + ')' : '';
        post((event.message || 'Errore') + where);
      }, true);
      window.addEventListener('unhandledrejection', function(event) {
        const reason = event.reason;
        post('Promise rifiutata: ' + (reason && reason.message ? reason.message : String(reason)));
      });
    })();
    """

    func noteConsole(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !consoleErrors.contains(clean), consoleErrors.count < 30 else { return }
        consoleErrors.append(clean)
    }

    /// Pagina del Mac o di un server di sviluppo: è l'anteprima di un progetto.
    var isLocalPreview: Bool {
        guard let url else { return false }
        return url.isFileURL || ["localhost", "127.0.0.1", "0.0.0.0"].contains(url.host?.lowercased() ?? "")
    }

    /// La pagina salvata con la chat si carica quando la sua scheda viene davanti.
    func loadPendingIfNeeded() {
        guard url == nil, let pending = pendingURL else { return }
        pendingURL = nil
        load(pending)
    }

    // MARK: Navigazione

    /// Indirizzo o parole da cercare, come nella barra di Safari.
    func go(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            load(URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath))
        } else if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" || url.scheme == "file" {
            load(url)
        } else if !trimmed.contains(" "), trimmed.contains("."), let url = URL(string: "https://\(trimmed)") {
            load(url)
        } else {
            search(trimmed)
        }
    }

    func search(_ query: String) {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: Language.system == .it ? "it-it" : "us-en")]
        load(components.url!)
    }

    /// - Parameter readAccess: per i file del Mac, la cartella che la pagina può leggere (il progetto, se è in un progetto).
    func load(_ url: URL, readAccess: URL? = nil) {
        error = nil
        pendingURL = nil
        address = url.absoluteString
        // File del Mac (pagine create da Siri AI+): accesso alla loro cartella per CSS, immagini e script.
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: readAccess ?? url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Dopo aver salvato un file della pagina aperta, la ricarica.
    func reloadIfShowing(_ file: URL?) {
        guard let file, let current = url, current.isFileURL,
              current.deletingLastPathComponent().standardizedFileURL == file.deletingLastPathComponent().standardizedFileURL else { return }
        webView.reloadFromOrigin()
    }

    /// L'anteprima di un progetto si ricarica quando cambiano i suoi file (le pagine dei server di sviluppo si aggiornano da sole).
    func reloadPreview(inside folder: URL) {
        guard let current = url, current.isFileURL,
              current.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.resolvingSymlinksInPath().path + "/")
                || current.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return }
        webView.reloadFromOrigin()
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

    func openInSafari() {
        guard let url else { return }
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Clicca il link della pagina con quel testo. Restituisce il testo del link trovato.
    func follow(_ text: String) async -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = try? JSONEncoder().encode(text.lowercased()),
              let needle = String(data: data, encoding: .utf8) else { return nil }
        let script = """
        (function(){
          const needle = \(needle);
          const links = Array.from(document.querySelectorAll('a, button, [role=button]'));
          const label = el => (el.innerText || el.getAttribute('aria-label') || el.title || '').trim();
          let target = links.find(el => label(el).toLowerCase() === needle) || links.find(el => label(el).toLowerCase().includes(needle));
          if (!target) return '';
          target.scrollIntoView({block: 'center'});
          if (target.tagName === 'A' && target.href) { window.location.href = target.href; } else { target.click(); }
          return label(target);
        })()
        """
        let result = try? await webView.evaluateJavaScript(script) as? String
        return (result?.isEmpty ?? true) ? nil : result
    }

    struct Snapshot {
        let url: String
        let title: String
        let text: String
        let links: [String]
    }

    /// Testo visibile e link della pagina, per dare contesto a Siri AI+.
    func snapshot() async -> Snapshot? {
        guard let url else { return nil }
        let script = """
        (function(){
          const seen = new Set();
          const links = [];
          for (const a of document.querySelectorAll('a')) {
            const t = (a.innerText || '').trim().replace(/\\s+/g, ' ');
            if (t.length > 2 && t.length < 60 && !seen.has(t.toLowerCase()) && a.offsetParent !== null) { seen.add(t.toLowerCase()); links.push(t); }
            if (links.length >= 40) break;
          }
          const main = document.querySelector('article') || document.querySelector('main') || document.body;
          return JSON.stringify({text: (main ? main.innerText : '').slice(0, 30000), links: links});
        })()
        """
        guard let json = try? await webView.evaluateJavaScript(script) as? String,
              let value = try? JSONValue.parse(Data(json.utf8)) else { return nil }
        return Snapshot(url: url.absoluteString, title: title, text: value["text"]?.string ?? "",
                        links: (value["links"]?.array ?? []).compactMap(\.string))
    }

    // MARK: Delegati

    /// Pagina nuova o ricaricata: gli errori ricominciano da zero.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { consoleErrors = [] }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }

    private func report(_ error: Error) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled, code != 102 else { return }
        self.error = error.localizedDescription
    }

    /// I link che aprono una nuova finestra si aprono nella stessa vista.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

/// Riceve gli errori della console senza tenere in vita il browser (WebKit trattiene chi riceve i messaggi).
@MainActor private final class ConsoleRelay: NSObject, WKScriptMessageHandler {
    let onMessage: (String) -> Void
    init(_ onMessage: @escaping (String) -> Void) { self.onMessage = onMessage }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        onMessage(text)
    }
}

/// Apre una pagina in un browser nascosto e raccoglie gli errori della console: così l'agente di coding vede se il sito
/// che ha appena cambiato si rompe (JavaScript, file che mancano), come farebbe una persona aprendo l'anteprima.
@MainActor final class PageCheck: NSObject, WKNavigationDelegate {
    private var errors: [String] = []
    private var loaded: CheckedContinuation<Void, Never>?
    private var webView: WKWebView?

    nonisolated static func errors(in page: URL, readAccess: URL? = nil) async -> [String] {
        await PageCheck().check(page, readAccess: readAccess)
    }

    private func check(_ page: URL, readAccess: URL?) async -> [String] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: BrowserModel.consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.add(ConsoleRelay { [weak self] text in self?.note(text) }, name: "siriaiConsole")
        configuration.userContentController = scripts
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        if page.isFileURL {
            view.loadFileURL(page, allowingReadAccessTo: readAccess ?? page.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: page))
        }
        await withCheckedContinuation { continuation in
            loaded = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                self.finish()
            }
        }
        // Gli script che partono dopo il caricamento hanno un momento per fallire.
        try? await Task.sleep(for: .seconds(1.5))
        scripts.removeScriptMessageHandler(forName: "siriaiConsole")
        view.navigationDelegate = nil
        webView = nil
        return errors
    }

    private func note(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty, !errors.contains(clean) { errors.append(clean) }
    }

    private func finish() {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        note(String(localized: "La pagina non si carica: \(error.localizedDescription)"))
        finish()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        note(String(localized: "La pagina non si carica: \(error.localizedDescription)"))
        finish()
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @Environment(AppState.self) private var state
    @FocusState private var addressFocused: Bool

    var body: some View {
        @Bindable var browser = state.browser
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { browser.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack).iconHelp(String(localized: "Indietro"))
                Button { browser.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward).iconHelp(String(localized: "Avanti"))
                HStack(spacing: 6) {
                    Image(systemName: browser.url?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Cerca o inserisci un indirizzo", text: $browser.address)
                        .textFieldStyle(.plain)
                        .focused($addressFocused)
                        .onSubmit { browser.go(browser.address) }
                    if browser.url != nil {
                        Button { browser.reload() } label: { Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise") }
                            .help(browser.isLoading ? String(localized: "Interrompi") : String(localized: "Ricarica"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Button { browser.openInSafari() } label: { Image(systemName: "safari") }
                    .disabled(browser.url == nil).iconHelp(String(localized: "Apri in Safari"))
                Menu {
                    Button("Importa la pagina aperta in Safari") { importFromSafari() }
                    Button("Copia link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(browser.address, forType: .string)
                    }
                    .disabled(browser.url == nil)
                    Divider()
                    Button("Riassumi questa pagina") { state.send(String(localized: "Riassumi questa pagina")) }.disabled(browser.url == nil)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                if browser.isLoading {
                    GeometryReader { geo in
                        Rectangle().fill(Color.accentColor).frame(width: geo.size.width * browser.progress, height: 2)
                    }
                    .frame(height: 2)
                } else {
                    Divider()
                }
            }

            if browser.isLocalPreview { PreviewBar(browser: browser) }

            ZStack {
                if let width = browser.deviceWidth, browser.url != nil {
                    // Telefono o tablet: la pagina alla larghezza del dispositivo, al centro.
                    Color.primary.opacity(0.04)
                    WebViewHost(webView: browser.webView)
                        .frame(maxWidth: width)
                        .clipShape(.rect(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 6))
                        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
                        .padding(.vertical, 14)
                } else {
                    WebViewHost(webView: browser.webView)
                        .opacity(browser.url == nil ? 0 : 1)
                }
                if browser.url == nil { StartPage() }
                if let error = browser.error {
                    InlineError(text: error) { browser.error = nil }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(12)
                }
            }
            .animation(DS.Motion.standard, value: browser.deviceWidth)
        }
        // Come le app: una lastra di vetro sospesa sull'aurora, la pagina web resta nitida al centro.
        .clipShape(.rect(cornerRadius: 26))
        .glassCard(radius: 26)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .onAppear {
            browser.loadPendingIfNeeded()
            if browser.url == nil && browser.pendingURL == nil { addressFocused = true }
        }
        // L'anteprima del progetto di codice si ricarica mentre l'agente cambia i file.
        .onChange(of: state.codeFilesRevision) {
            if let project = state.openCodingProject { browser.reloadPreview(inside: state.workingCodeProject(project).folder) }
        }
    }

    private func importFromSafari() {
        if let tab = SafariBridge.currentTab(), let url = URL(string: tab.url) {
            state.browser.load(url)
        } else {
            state.browser.error = String(localized: "Non trovo pagine aperte in Safari (oppure Siri AI+ non ha il permesso di controllarlo: Impostazioni di Sistema › Privacy e sicurezza › Automazione).")
        }
    }
}

/// Sopra l'anteprima di un sito: larghezza del dispositivo, errori della console e «Correggi».
private struct PreviewBar: View {
    @Environment(AppState.self) private var state
    let browser: BrowserModel
    @State private var showErrors = false

    private static let devices: [(String, String, CGFloat?)] = [(String(localized: "Computer"), "desktopcomputer", nil), (String(localized: "Tablet"), "ipad", 820), (String(localized: "Telefono"), "iphone", 390)]

    var body: some View {
        HStack(spacing: 10) {
            Label(state.openCodingProject.map { String(localized: "Anteprima di \($0.name)") } ?? String(localized: "Anteprima"), systemImage: "eye")
                .font(DS.Fonts.captionStrong)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Picker("Dispositivo", selection: Binding(get: { browser.deviceWidth ?? 0 }, set: { browser.deviceWidth = $0 == 0 ? nil : $0 })) {
                ForEach(Self.devices, id: \.0) { name, symbol, width in
                    Image(systemName: symbol).help(name).tag(width ?? 0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            Spacer(minLength: 6)
            if browser.consoleErrors.isEmpty {
                Label("Nessun errore", systemImage: "checkmark.circle").font(DS.Fonts.caption).foregroundStyle(.green)
            } else {
                Button { showErrors.toggle() } label: {
                    Label("\(browser.consoleErrors.count) \(browser.consoleErrors.count == 1 ? "errore" : "errori")", systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Fonts.captionStrong)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.red.opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Errori della console della pagina")
                .popover(isPresented: $showErrors, arrowEdge: .bottom) { errorList }
                Button("Correggi") { state.fixPreviewErrors(browser.consoleErrors) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .help(state.openCodingProject == nil ? String(localized: "Chiedi a Siri AI+ di spiegarli") : String(localized: "Chiedi all'assistente del progetto di correggerli"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var errorList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Errori nella console").font(DS.Fonts.bodyStrong)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(browser.consoleErrors, id: \.self) { error in
                        Text(error).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(14)
        .frame(width: 420)
    }
}

private struct InlineError: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(DS.Fonts.caption).lineLimit(3)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Pagina iniziale: ricerca e siti rapidi.
private struct StartPage: View {
    @Environment(AppState.self) private var state
    @State private var query = ""
    private let sites: [(String, String)] = [
        (String(localized: "Il Post"), "https://www.ilpost.it"), (String(localized: "Wikipedia"), "https://it.wikipedia.org"), (String(localized: "Meteo"), "https://www.ilmeteo.it"),
        (String(localized: "YouTube"), "https://www.youtube.com"), (String(localized: "GitHub"), "https://github.com"), (String(localized: "Apple"), "https://www.apple.com/it/"),
    ]

    var body: some View {
        VStack(spacing: 22) {
            Tile.safari(size: 64)
            Text("Cerca sul web").font(DS.Fonts.title)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca o inserisci un indirizzo", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit { state.browser.go(query) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .capsule)
            .frame(maxWidth: 540)
            GlassEffectContainer(spacing: 10) {
                FlowLayout(spacing: 10) {
                    ForEach(sites, id: \.1) { site in
                        Button(site.0) { state.browser.load(URL(string: site.1)!) }
                            .buttonStyle(.glass)
                    }
                }
            }
            .frame(maxWidth: 560)
            if let project = state.openCodingProject {
                Button { state.openPreview(project) } label: { Label("Anteprima di \(project.name)", systemImage: "play.fill") }
                    .buttonStyle(.glassProminent)
                    .tint(.purple)
            }
            Text(state.openCodingProject == nil
                 ? String(localized: "Chiedi a Siri AI+ qui a destra di aprire un sito, riassumere la pagina o cliccare un link.")
                 : String(localized: "Questo Safari è della sessione di coding: la chat a destra resta con te mentre provi il sito."))
                .font(DS.Fonts.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Tile {
    static func safari(size: CGFloat = 26) -> Tile {
        Tile(symbol: "safari.fill", fill: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x1AA3FF), Color(hex: 0x0A5FE0)], startPoint: .top, endPoint: .bottom)),
             size: size, bundleID: "com.apple.Safari")
    }
}

/// Fonti di una risposta dal web: si aprono nel browser integrato.
struct WebSourcesCard: View {
    @Environment(AppState.self) private var state
    let answer: WebAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(answer.kind == .search ? String(localized: "Fonti dal web") : String(localized: "Pagina letta"), systemImage: answer.kind == .search ? "globe" : "doc.text")
                .font(DS.Fonts.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(answer.sources.enumerated()), id: \.element.id) { index, source in
                        SourceChip(index: answer.kind == .search ? index + 1 : nil, source: source) { open(source) }
                    }
                }
            }
        }
    }

    private func open(_ source: WebSource) {
        guard let url = URL(string: source.url) else { return }
        state.browser.load(url)
        state.section = .browser
    }
}

private struct SourceChip: View {
    let index: Int?
    let source: WebSource
    let open: () -> Void

    var body: some View {
        Button(action: open) { label }
            .buttonStyle(.plain)
            .help(source.url)
            .contextMenu {
                Button("Apri nel browser di Siri AI+", action: open)
                Button("Apri in Safari") { openInSafari() }
                Button("Copia link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.url, forType: .string)
                }
            }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let index {
                    Text("\(index)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Color.accentColor, in: Circle())
                }
                Text(source.domain).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(source.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(9)
        .frame(width: 180, height: 62, alignment: .topLeading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.hairline))
    }

    private func openInSafari() {
        guard let url = URL(string: source.url) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/Applications/Safari.app"), configuration: NSWorkspace.OpenConfiguration())
    }
}
