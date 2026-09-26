import AppKit
import ApplicationServices
import Carbon
import Observation
import ScreenCaptureKit
import SiriCore
import SwiftUI

/// La cattura avviene solo quando si apre il pannello, prima che Helen prenda il focus.
@MainActor @Observable
final class ExternalAppAccess {
    struct Selection {
        let processID: pid_t
        let bundleID: String
        let appName: String
        let element: AXUIElement
        let text: String
    }

    enum ApplyResult: Equatable {
        case verified, uncertain, copied, stale
    }

    var appName: String?
    var bundleID: String?
    var selectedText: String?
    var selectionToken: UUID?
    var detail: String?
    var includeSelection = true
    @ObservationIgnored private var element: AXUIElement?
    @ObservationIgnored private var processID: pid_t = 0
    @ObservationIgnored private var selection: Selection?
    @ObservationIgnored private var allowed: Set<String> = AppPaths.isTestEnvironment
        ? [] : Set(UserDefaults.standard.stringArray(forKey: "externalAllowedBundleIDs") ?? [])

    var isAllowed: Bool { bundleID.map(allowed.contains) ?? false }
    var hasSelection: Bool { includeSelection && selectedText?.isEmpty == false }
    var trusted: Bool { AXIsProcessTrusted() }

    func captureForeground() {
        appName = nil; bundleID = nil; selectedText = nil; selectionToken = nil; detail = nil; element = nil; selection = nil
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let bundle = app.bundleIdentifier else { return }
        appName = app.localizedName ?? bundle
        bundleID = bundle
        processID = app.processIdentifier
        guard isAllowed else { detail = "Autorizza questa app per leggere il testo selezionato."; return }
        readSelection()
    }

    func authorizeCurrent() {
        guard let bundleID else { return }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            detail = "Abilita Siri AI+ in Impostazioni di Sistema › Privacy e sicurezza › Accessibilità."
            return
        }
        allowed.insert(bundleID)
        if !AppPaths.isTestEnvironment { UserDefaults.standard.set(allowed.sorted(), forKey: "externalAllowedBundleIDs") }
        readSelection()
    }

    func revokeCurrent() {
        guard let bundleID else { return }
        allowed.remove(bundleID)
        if !AppPaths.isTestEnvironment { UserDefaults.standard.set(allowed.sorted(), forKey: "externalAllowedBundleIDs") }
        selectedText = nil; selectionToken = nil; selection = nil; element = nil
        detail = "Accesso rimosso per \(appName ?? bundleID)."
    }

    func discardSelection() { includeSelection = false; selectionToken = nil }

    private func value(_ attribute: String, of target: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(target, attribute as CFString, &result) == .success ? result : nil
    }

    private func readSelection() {
        selectedText = nil; selectionToken = nil; selection = nil; element = nil; includeSelection = true
        guard trusted else { detail = "Serve il permesso Accessibilità di macOS."; return }
        let application = AXUIElementCreateApplication(processID)
        guard let focused = value(kAXFocusedUIElementAttribute as String, of: application),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            detail = "Questa app non espone il campo selezionato."; return
        }
        let target = focused as! AXUIElement
        let role = value(kAXRoleAttribute as String, of: target) as? String ?? ""
        let subrole = value(kAXSubroleAttribute as String, of: target) as? String ?? ""
        guard !role.localizedCaseInsensitiveContains("secure"), !subrole.localizedCaseInsensitiveContains("secure"),
              !role.localizedCaseInsensitiveContains("password"), !subrole.localizedCaseInsensitiveContains("password") else {
            detail = "I campi protetti non vengono letti."; return
        }
        guard let text = value(kAXSelectedTextAttribute as String, of: target) as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            detail = "Nessun testo selezionato."; return
        }
        let bounded = String(text.prefix(24_000))
        element = target
        selectedText = bounded
        selectionToken = UUID()
        if text.count > bounded.count { detail = "Selezione lunga: inclusi i primi 24.000 caratteri." }
        selection = Selection(processID: processID, bundleID: bundleID ?? "", appName: appName ?? "App", element: target, text: bounded)
    }

    /// Non usa pressione di tasti o incolla simulato: modifica soltanto un attributo AX scrivibile e ancora identico.
    func apply(_ replacement: String, expectedToken: UUID) -> ApplyResult {
        guard let selection, selectionToken == expectedToken, isAllowed, includeSelection, !replacement.isEmpty,
              NSRunningApplication(processIdentifier: selection.processID)?.bundleIdentifier == selection.bundleID else { return .stale }
        let application = AXUIElementCreateApplication(selection.processID)
        guard let focused = value(kAXFocusedUIElementAttribute as String, of: application),
              CFGetTypeID(focused) == AXUIElementGetTypeID(),
              CFEqual(focused, selection.element),
              let current = value(kAXSelectedTextAttribute as String, of: selection.element) as? String,
              current == selection.text else { return .stale }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(selection.element, kAXSelectedTextAttribute as CFString, &writable) == .success,
              writable.boolValue else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(replacement, forType: .string)
            return .copied
        }
        guard AXUIElementSetAttributeValue(selection.element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) == .success else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(replacement, forType: .string)
            return .copied
        }
        let changed = value(kAXSelectedTextAttribute as String, of: selection.element) as? String
        self.selection = nil
        selectedText = nil
        selectionToken = nil
        return changed == replacement ? .verified : .uncertain
    }
}

@MainActor
final class CompanionController: NSObject {
    static let shared = CompanionController()
    let access = ExternalAppAccess()
    private var state: AppState?
    private var panel: NSPanel?
    private var reopenedWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var hotKeys: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private let screenCapture = ManualScreenCapture()

    func captureScreen(_ result: @escaping @MainActor (Result<URL, Error>) -> Void) {
        screenCapture.choose { [weak self] outcome in
            NSApp.activate()
            self?.panel?.makeKeyAndOrderFront(nil)
            result(outcome)
        }
    }

    func install(state: AppState) {
        guard statusItem == nil else { return }
        self.state = state
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Siri AI+")
        item.button?.toolTip = "Siri AI+ · chat rapida ⌥⌘K"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Chat rapida", action: #selector(openQuick), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Apri Siri AI+", action: #selector(openMain), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Modalità vocale", action: #selector(openVoice), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Esci", action: #selector(quit), keyEquivalent: ""))
        for entry in menu.items { entry.target = self }
        item.menu = menu
        statusItem = item
        registerHotKeys()
    }

    private func registerHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var keyID = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &keyID)
            guard result == noErr else { return result }
            let controller = Unmanaged<CompanionController>.fromOpaque(userData).takeUnretainedValue()
            let pressedID = keyID.id
            Task { @MainActor in
                if pressedID == 1 { controller.showQuick() }
                if pressedID == 2 { controller.showVoice() }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        for (id, code) in [(UInt32(1), UInt32(kVK_ANSI_K)), (UInt32(2), UInt32(kVK_ANSI_V))] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(code, UInt32(optionKey | cmdKey),
                                            EventHotKeyID(signature: OSType(0x53414950), id: id),
                                            GetApplicationEventTarget(), 0, &ref)
            if status == noErr { hotKeys.append(ref) }
            else { Agent.log("SCORCIATOIA GLOBALE: registrazione non riuscita (\(id), \(status))") }
        }
    }

    func showQuick() {
        guard let state else { return }
        access.captureForeground()
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 530, height: 620),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "Siri AI+ · Chat rapida"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView: QuickPanelView().environment(state).environment(access))
            panel.minSize = NSSize(width: 430, height: 430)
            self.panel = panel
        }
        panel?.center()
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func showVoice() {
        guard let state else { return }
        openMain()
        state.voice.start(with: state)
    }

    @objc private func openQuick() { showQuick() }
    @objc private func openVoice() { showVoice() }
    @objc func openMain() {
        if let window = NSApp.windows.first(where: { $0 !== panel && $0.canBecomeMain && $0.title == "Siri AI+" }) {
            window.makeKeyAndOrderFront(nil)
        } else if let state {
            // Una scena SwiftUI chiusa può non figurare più tra le finestre di AppKit.
            // Il menu e la scorciatoia vocale devono comunque poter riaprire la Home.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Siri AI+"
            window.contentView = NSHostingView(rootView: RootView().environment(state))
            window.minSize = NSSize(width: 900, height: 600)
            window.center()
            reopenedWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Il selettore di macOS lascia scegliere esplicitamente schermo o finestra;
/// nessuna immagine viene catturata all'apertura del pannello.
@MainActor
private final class ManualScreenCapture: NSObject, @preconcurrency SCContentSharingPickerObserver {
    private var completion: (@MainActor (Result<URL, Error>) -> Void)?

    func choose(_ completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            do {
                let config = SCStreamConfiguration()
                config.width = min(4096, max(1, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))))
                config.height = min(4096, max(1, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))))
                config.showsCursor = false
                let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let data = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let folder = FileManager.default.temporaryDirectory.appending(path: "SiriAI-Catture")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appending(path: "Schermo-\(UUID().uuidString).png")
                try data.write(to: url, options: .atomic)
                finish(.success(url))
            } catch { finish(.failure(error)) }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        finish(.failure(CocoaError(.userCancelled)))
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, Error>) {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
        let callback = completion
        completion = nil
        callback?(result)
    }
}

private struct QuickPanelView: View {
    private struct CloudPreview: Identifiable {
        let id = UUID()
        let provider: ResponseProvider
        let prompt: String
        let conversationID: UUID
    }

    @Environment(AppState.self) private var state
    @Environment(ExternalAppAccess.self) private var access
    @State private var space = Space.lavoro
    @State private var input = ""
    @State private var showSelection = false
    @State private var showEdit = false
    @State private var proposedReplacement: String?
    @State private var proposedSelectionToken: UUID?
    @State private var lastPromptSelectionToken: UUID?
    @State private var lastPromptConversationID: UUID?
    @State private var applyMessage: String?
    @State private var cloudPreview: CloudPreview?
    @State private var screenshotURL: URL?
    @State private var screenshotError: String?

    private var conversation: Conversation { state.quickConversation(for: space) }
    private var latestReply: String? {
        guard let lastPrompt = conversation.messages.lastIndex(where: { if case .user = $0.content { true } else { false } }) else { return nil }
        return conversation.messages[(lastPrompt + 1)...].reversed().compactMap {
            if case .text(let value) = $0.content { return value }; return nil
        }.first
    }
    private var latestPrompt: String? {
        conversation.messages.reversed().compactMap { if case .user(let value, _, _) = $0.content { return value }; return nil }.first
    }

    private var panelBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x15458B), Color(hex: 0x2469BD), Color(hex: 0x76AFE4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.cyan.opacity(0.3), .clear], center: .topTrailing,
                           startRadius: 20, endRadius: 430)
        }.ignoresSafeArea()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.md) {
                OrbView(state: state.isQuickResponding(conversation) ? .thinking : .idle, size: 32)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Siri AI+").font(DS.Fonts.section)
                    Text(AppleResponseModel.preferred.label)
                        .font(DS.Fonts.micro).foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                Picker("Spazio", selection: $space) {
                    Text("Personale").tag(Space.personale)
                    Text("Lavoro").tag(Space.lavoro)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
                .padding(.horizontal, DS.Space.xs)
                .background(.white.opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, 34)
            .padding(.bottom, DS.Space.lg)
            Rectangle().fill(.white.opacity(0.16)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.lg) {
                        if conversation.messages.isEmpty {
                            VStack(spacing: DS.Space.md) {
                                OrbView(state: .idle, size: 54, animated: false)
                                Text("Chiedi a Siri AI+").font(DS.Fonts.section)
                                Text("Una chat sempre a portata di mano nello Spazio \(space == .personale ? "Personale" : "Lavoro").")
                                    .font(DS.Fonts.caption).foregroundStyle(.white.opacity(0.72))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 95)
                        }
                        ForEach(conversation.messages) { message in
                            switch message.content {
                            case .user(let text, _, _):
                                HStack {
                                    Spacer(minLength: 48)
                                    Text(text)
                                        .font(DS.Fonts.message)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 15)
                                        .padding(.vertical, 10)
                                        .modifier(UserBubble())
                                }
                            case .text(let text):
                                AssistantRow { RichText(text: text) }
                            case .notice(let text):
                                Text(text).font(DS.Fonts.caption).foregroundStyle(.white.opacity(0.72))
                                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                            case .thinking(let text):
                                HStack(spacing: DS.Space.sm) {
                                    OrbView(state: .thinking, size: 22)
                                    Text(text).font(DS.Fonts.caption).foregroundStyle(.white.opacity(0.75))
                                }
                            default:
                                Button {
                                    state.select(conversation)
                                    CompanionController.shared.openMain()
                                } label: { Label("Apri la scheda nell’app", systemImage: "arrow.up.right.square") }
                                    .buttonStyle(.bordered)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(DS.Space.lg)
                }
                .onChange(of: conversation.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if let appName = access.appName {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: access.hasSelection ? "text.quote" : "app")
                        Text(access.hasSelection ? "Selezione da \(appName)" : appName).lineLimit(1)
                        if access.hasSelection {
                            Button("Mostra") { showSelection = true }
                            Button { access.discardSelection() } label: { Image(systemName: "xmark.circle.fill") }
                                .help("Escludi questa selezione")
                        }
                        if !access.isAllowed {
                            Button("Autorizza") { access.authorizeCurrent() }
                        } else {
                            Button("Revoca") { access.revokeCurrent() }
                        }
                        Spacer(minLength: 0)
                    }
                    if access.hasSelection, let selectedText = access.selectedText {
                        Text(selectedText).font(DS.Fonts.micro).lineLimit(3).textSelection(.enabled)
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    if let detail = access.detail { Text(detail).font(DS.Fonts.micro).foregroundStyle(.white.opacity(0.7)) }
                }
                .font(DS.Fonts.caption)
                .padding(DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.sm)
            }
            if access.hasSelection, lastPromptSelectionToken == access.selectionToken,
               lastPromptConversationID == conversation.id, let latestReply,
               !state.isQuickResponding(conversation) {
                Button("Proponi la sostituzione del testo selezionato") {
                    proposedReplacement = latestReply
                    proposedSelectionToken = access.selectionToken
                    showEdit = true
                }
                    .font(DS.Fonts.caption).buttonStyle(.bordered).padding(.bottom, DS.Space.sm)
            }
            if let screenshotURL {
                HStack {
                    Label("Cattura allegata · \(screenshotURL.lastPathComponent)", systemImage: "photo")
                    Spacer()
                    Button("Rimuovi") {
                        try? FileManager.default.removeItem(at: screenshotURL)
                        self.screenshotURL = nil
                    }
                }
                .font(DS.Fonts.micro)
                .padding(DS.Space.sm)
                .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .padding(.horizontal, DS.Space.lg).padding(.bottom, DS.Space.sm)
            }
            if latestPrompt != nil, latestReply != nil {
                HStack {
                    Spacer()
                    Menu {
                        Button("ChatGPT…") { previewCloud(.chatgpt) }
                        Button("Claude…") { previewCloud(.claude) }
                    } label: {
                        Label("Altro modello", systemImage: "arrow.triangle.2.circlepath")
                            .font(DS.Fonts.microStrong)
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
                    .background(.white.opacity(0.12), in: Capsule())
                }
                .padding(.horizontal, DS.Space.lg).padding(.bottom, DS.Space.sm)
            }
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                TextField("", text: $input, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).font(DS.Fonts.message)
                    .overlay(alignment: .leading) {
                        if input.isEmpty {
                            Text("Chiedi a Siri AI+…")
                                .font(DS.Fonts.message).foregroundStyle(.white.opacity(0.74))
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Chiedi a Siri AI+…")
                    .onSubmit { send() }
                HStack(spacing: DS.Space.sm) {
                    Button {
                        CompanionController.shared.captureScreen { result in
                            switch result {
                            case .success(let url): screenshotURL = url
                            case .failure(let error):
                                if (error as? CocoaError)?.code != .userCancelled { screenshotError = error.localizedDescription }
                            }
                        }
                    } label: { Image(systemName: "camera.viewfinder").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).help("Scegli una finestra o uno schermo da catturare")
                    Label("Apple Intelligence", systemImage: "apple.logo")
                        .font(DS.Fonts.micro).foregroundStyle(.white.opacity(0.76))
                    Spacer()
                    if state.isQuickResponding(conversation) { ProgressView().controlSize(.small) }
                    Button { send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.white.opacity(0.18) : Color.accentColor,
                                        in: Circle())
                    }
                        .buttonStyle(.plain)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isQuickResponding(conversation))
                        .accessibilityLabel("Invia")
                }
            }
            .padding(DS.Space.md)
            .modifier(IntelligenceSurface(active: state.isQuickResponding(conversation), radius: DS.Radius.composer))
            .padding(.horizontal, DS.Space.lg).padding(.bottom, DS.Space.lg)
        }
        .frame(minWidth: 430, minHeight: 430)
        .foregroundStyle(.white)
        .background { panelBackground }
        .environment(\.colorScheme, .dark)
        .onAppear { space = state.space == .codice ? .lavoro : state.space }
        .onChange(of: space) { _, selected in state.switchSpace(selected) }
        .sheet(isPresented: $showSelection) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Testo selezionato · \(access.appName ?? "App")").font(.headline)
                ScrollView { Text(access.selectedText ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Chiudi") { showSelection = false }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding().frame(width: 480, height: 350)
            .foregroundStyle(.white).background { panelBackground }.environment(\.colorScheme, .dark)
        }
        .sheet(isPresented: $showEdit) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sostituisci il testo selezionato?").font(.headline)
                Text("Originale").font(.caption).foregroundStyle(.secondary)
                Text(access.selectedText ?? "").lineLimit(5)
                Text("Nuovo testo").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(proposedReplacement ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Annulla") { proposedReplacement = nil; proposedSelectionToken = nil; showEdit = false }
                    Spacer()
                    Button("Applica") {
                        let result = proposedSelectionToken.map { access.apply(proposedReplacement ?? "", expectedToken: $0) } ?? .stale
                        applyMessage = switch result {
                        case .verified: "Modifica verificata nell’app."
                        case .uncertain: "L’app ha accettato la modifica, ma non ha permesso di verificarla. Controlla il campo prima di riprovare."
                        case .copied: "Il campo non consente una modifica sicura. Testo copiato: incollalo tu."
                        case .stale: "Il campo o la selezione sono cambiati. Seleziona di nuovo il testo."
                        }
                        proposedReplacement = nil
                        proposedSelectionToken = nil
                        showEdit = false
                    }.buttonStyle(.borderedProminent)
                }
            }
            .padding().frame(width: 500, height: 440)
            .foregroundStyle(.white).background { panelBackground }.environment(\.colorScheme, .dark)
        }
        .sheet(item: $cloudPreview) { preview in
            VStack(alignment: .leading, spacing: 12) {
                Text("Inviare la richiesta a \(preview.provider.name)?").font(.headline)
                Text("A \(preview.provider.company) vengono inviati la richiesta e l'istruzione di servizio mostrate qui. Non vengono inviate cronologia, catture, file, memoria o altri contenuti delle app.")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text("Richiesta").font(.caption).foregroundStyle(.white.opacity(0.8))
                ScrollView { Text(preview.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 160)
                    .padding(9).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.md))
                Text("Istruzione di servizio: \(AppState.quickCloudSystemPrompt)")
                    .font(.caption).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                Text(state.cloudPrivacy ? "L'anonimizzazione configurata nelle Impostazioni verrà applicata prima dell'invio; importi, date, luoghi e aziende possono restare leggibili." : "L'anonimizzazione è disattivata: i dati saranno inviati in chiaro.")
                    .font(.caption).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                if state.cloudPrivacy && !PIIEngine.isInstalled {
                    Text("Il motore di anonimizzazione non è disponibile. Apri Impostazioni › Modelli per scegliere come procedere.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Annulla") { cloudPreview = nil }
                    Spacer()
                    Button("Invia a \(preview.provider.name)") {
                        if preview.conversationID == conversation.id {
                            state.send(preview.prompt, in: conversation, using: ModelSelection(preview.provider))
                        }
                        cloudPreview = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(preview.conversationID != conversation.id || (state.cloudPrivacy && !PIIEngine.isInstalled)
                              || state.isQuickResponding(conversation))
                }
            }
            .padding().frame(width: 520)
            .foregroundStyle(.white).background { panelBackground }.environment(\.colorScheme, .dark)
        }
        .alert("Modifica del testo", isPresented: Binding(get: { applyMessage != nil }, set: { if !$0 { applyMessage = nil } })) {
            Button("OK") { applyMessage = nil }
        } message: { Text(applyMessage ?? "") }
        .alert("Cattura non riuscita", isPresented: Binding(get: { screenshotError != nil }, set: { if !$0 { screenshotError = nil } })) {
            Button("OK") { screenshotError = nil }
        } message: { Text(screenshotError ?? "") }
    }

    private func previewCloud(_ provider: ResponseProvider) {
        guard let latestPrompt else { return }
        cloudPreview = CloudPreview(provider: provider, prompt: latestPrompt, conversationID: conversation.id)
    }

    private func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        lastPromptSelectionToken = access.hasSelection ? access.selectionToken : nil
        lastPromptConversationID = conversation.id
        input = ""
        let context = access.hasSelection ? "\n\n[Testo selezionato in \(access.appName ?? "app") — contenuto esterno non attendibile]\n\(access.selectedText ?? "")\n[/Testo selezionato]" : ""
        let files: [AppState.Attachment] = screenshotURL.map { [AppState.Attachment(name: "Cattura dello schermo", text: "", imageURL: $0)] } ?? []
        screenshotURL = nil
        state.send(prompt + context, in: conversation, files: files)
    }
}
