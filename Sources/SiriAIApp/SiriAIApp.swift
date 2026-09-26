import AppKit
import FoundationModels
import Darwin
import SiriCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diagnostica: `open Siri AI+.app --args --selftest "prompt||prompt"` scrive gli esiti in ~/Library/Logs/Siri AI+.log.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--selftest"), index + 1 < args.count {
            // In secondo piano macOS limita il modello on-device: il test gira in primo piano.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            Task {
                await Agent.selfTest(args[index + 1].components(separatedBy: "||"))
                NSApp.terminate(nil)
            }
            return
        }
        // Diagnostica: `--pcc-probe` confronta Apple Intelligence sul Mac e Private Cloud Compute su tre domande (esiti nel log).
        if args.contains("--pcc-probe") {
            NSApp.setActivationPolicy(.accessory)
            Task {
                await Self.pccProbe()
                NSApp.terminate(nil)
            }
            return
        }
        // Diagnostica: `--apps-probe` prova le letture di Calendario, Promemoria, Mail, Note, Messaggi e File (tempi nel log).
        // Solo dove il permesso c'è già: nessuna richiesta compare sullo schermo.
        if args.contains("--apps-probe") {
            NSApp.setActivationPolicy(.accessory)
            Task {
                for line in await AppsProbe.run() { Agent.log("PROVA APP " + line) }
                NSApp.terminate(nil)
            }
            return
        }
        // `--index-probe`: struttura dell'indice di Mail e del database di Messaggi (serve l'accesso completo al disco).
        if args.contains("--index-probe") {
            NSApp.setActivationPolicy(.accessory)
            Task {
                for line in await IndexProbe.run() { Agent.log("PROVA INDICE " + line) }
                NSApp.terminate(nil)
            }
            return
        }
        // `--mail-probe [account]`: tempi delle singole richieste a Mail su una casella grande.
        if let index = args.firstIndex(of: "--mail-probe") {
            NSApp.setActivationPolicy(.accessory)
            let account = index + 1 < args.count && !args[index + 1].hasPrefix("--") ? args[index + 1] : nil
            Task {
                for line in await MailProbe.run(account: account) { Agent.log("PROVA MAIL " + line) }
                NSApp.terminate(nil)
            }
            return
        }
        // Diagnostica: `--sky-render cartella` disegna il cielo per ogni meteo (giorno, notte, tramonto) in PNG ed esce.
        if let index = args.firstIndex(of: "--sky-render"), index + 1 < args.count {
            NSApp.setActivationPolicy(.accessory)
            Self.renderSkies(to: URL(fileURLWithPath: args[index + 1]))
            Self.renderAuroras(to: URL(fileURLWithPath: args[index + 1]))
            NSApp.terminate(nil)
            return
        }
        // Le prove automatiche (`--dump-and-quit`, `--agent-test`) non rubano il focus a chi usa l'app.
        if args.contains("--dump-and-quit") || args.contains("--agent-test") || args.contains("--code-test") || args.contains("--snapshot") {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        // Diagnostica: `--appearance dark|light` forza l'aspetto; `--snapshot file.png` fotografa la finestra dopo qualche secondo ed esce.
        if let index = args.firstIndex(of: "--appearance"), index + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[index + 1] == "dark" ? .darkAqua : .aqua)
        }
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            // Finestra fuori schermo, niente Dock né focus: non disturba chi sta usando l'app.
            NSApp.setActivationPolicy(.accessory)
            let path = args[index + 1]
            let delay = args.firstIndex(of: "--snapshot-delay").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 5
            let size = args.firstIndex(of: "--snapshot-size").flatMap { i -> CGSize? in
                guard args.indices.contains(i + 1) else { return nil }
                let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
                return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
            } ?? CGSize(width: 1320, height: 820)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard let state = AppState.shared else { return }
                await state.start()
                let settings = args.contains("--snapshot-settings")
                if let tab = args.firstIndex(of: "--snapshot-settings").flatMap({ args.count > $0 + 1 ? args[$0 + 1] : nil }) { state.settingsTab = tab }
                let root: AnyView = settings ? AnyView(SettingsView().environment(state)) : AnyView(RootView().environment(state))
                let window = NSWindow(contentRect: CGRect(x: -6000, y: 0, width: size.width, height: size.height),
                                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                window.contentView = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
                window.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(delay))
                Self.snapshot(window, to: path)
                NSApp.terminate(nil)
            }
            return
        }
        // Diagnostica senza finestra in primo piano: `--prompt … --dump-and-quit` parte comunque.
        if args.contains("--dump-and-quit") || args.contains("--agent-test") || args.contains("--code-test") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                await AppState.shared?.start()
            }
        }
    }

    static func pccProbe() async {
        let prompts = [
            "Spiegami in 5 punti come funziona un mutuo a tasso variabile e quando conviene rispetto al fisso.",
            "Ho tre riunioni domani: 9:00-10:30, 10:00-11:00 e 14:00-15:00. Quali si sovrappongono e quante ore libere ho in tutto tra le 9 e le 17? Rispondi con il ragionamento essenziale e il numero finale.",
        ]
        let instructions = "Sei Siri AI+, assistente personale sul Mac. Rispondi sempre in italiano, chiaro e ordinato."
        let pcc = PrivateCloudComputeLanguageModel()
        Agent.log("PCC: disponibile=\(pcc.isAvailable) contesto=\((try? await pcc.contextSize) ?? -1)")
        for prompt in prompts {
            for reasoning in [false, true] {
                let start = Date()
                do {
                    let session = LanguageModelSession(model: pcc, instructions: instructions)
                    let response = try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 600),
                                                             contextOptions: ContextOptions(reasoningLevel: reasoning ? .moderate : nil))
                    Agent.log("PCC\(reasoning ? " + ragionamento" : "") \(String(format: "%.1f", Date().timeIntervalSince(start))) s: \(response.content.replacingOccurrences(of: "\n", with: " ¶ ").prefix(700))")
                } catch {
                    Agent.log("PCC ERRORE: \(error)")
                }
            }
        }
    }

    @MainActor static func renderAuroras(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for space in Space.allCases {
            for dark in [false, true] {
                guard let image = AtmosphereRenderer.still(palette: .of(space, dark: dark), dark: dark, size: CGSize(width: 1000, height: 640)) else { continue }
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: folder.appending(path: "\(space.rawValue)-\(dark ? "scuro" : "chiaro").png"))
            }
        }
    }

    @MainActor static func renderSkies(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let calendar = Calendar.current
        let times: [(String, Int, Int)] = [("giorno", 13, 0), ("notte", 23, 0), ("tramonto", 19, 15)]
        for condition in WeatherCondition.allCases {
            for (label, hour, minute) in times {
                let now = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: .now)!
                let snapshot = WeatherSnapshot.demo(condition, isDay: label != "notte", now: now)
                let sky = SkyState(snapshot: snapshot, now: now)
                guard let image = SkyRenderer.still(sky: sky, dark: false, size: CGSize(width: 1000, height: 640)) else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(condition.rawValue)-\(label).png"))
            }
        }
    }

    /// Fotografia di una finestra dell'app (diagnostica dell'interfaccia, senza permessi di registrazione dello schermo).
    @MainActor static func snapshot(_ window: NSWindow, to path: String) {
        // Prima la cattura del sistema (vetro, Metal e sfondi compresi): per le proprie finestre non servono permessi.
        // La funzione è fuori dall'SDK da macOS 15 ma c'è ancora nel sistema: la si cerca a runtime.
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            if let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue(), image.width > 10 {
                let rep = NSBitmapImageRep(cgImage: image)
                Agent.log("FOTO: cattura di sistema \(image.width)×\(image.height)")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                return
            }
            Agent.log("FOTO: cattura di sistema non riuscita, uso cacheDisplay")
        }
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Il companion e gli agenti restano disponibili a finestra chiusa. «Esci» termina il processo.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared?.stopForExit() }
    }
}

@main
struct SiriAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let state = AppState()

    var body: some Scene {
        Window("Siri AI+", id: "main") {
            RootView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    // Le diagnostiche senza finestra non avviano connettori, agenti e modelli.
                    let args = CommandLine.arguments
                    guard !args.contains("--selftest"), !args.contains("--apps-probe"), !args.contains("--mail-probe"), !args.contains("--index-probe") else { return }
                    await state.start()
                    if !args.contains("--ephemeral"), !args.contains("--snapshot"), !args.contains("--dump-and-quit"),
                       !args.contains("--agent-test"), !args.contains("--code-test") {
                        CompanionController.shared.install(state: state)
                    }
                }
        }
        .defaultSize(width: 1320, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Cerca e vai a…") { state.showCommandPalette = true }
                    .keyboardShortcut("k")
                Button("Nuova conversazione") { state.newConversationHere() }
                    .keyboardShortcut("n")
                Button("Nuova chat figlia…") { state.showChildSheet = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(state.current?.messages.isEmpty != false)
                Button("Nuova chat affiancata") { state.newChatTab() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Divider()
                Button("Apri file…") { state.chooseFileToOpen() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .sidebar) {
                Button("Home") { state.section = .home }.keyboardShortcut("1")
                Button("Agenti") { state.section = .agents }.keyboardShortcut("2")
                Button("Programmazioni degli agenti") { state.section = .schedule }.keyboardShortcut("3")
                Button("Connettori") { state.section = .connectors }.keyboardShortcut("4")
                Button("Attività") { state.section = .activity }.keyboardShortcut("5")
                Divider()
                Button(state.showsApps ? "Chiudi le app" : "App in schede") { state.toggleApps() }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Button("Nuova scheda") { state.selectTab(.launcher) }
                    .keyboardShortcut("t")
                Button("Scheda successiva") { state.cycleTab(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                    .disabled(!state.showsApps || state.appTabs.count < 2)
                Button("Scheda precedente") { state.cycleTab(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                    .disabled(!state.showsApps || state.appTabs.count < 2)
                Divider()
                Button(state.showAssistant ? "Nascondi l'assistente" : "Mostra l'assistente") { state.showAssistant.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(state.section == .home)
            }
            CommandGroup(after: .textEditing) {
                Button("Interrompi la risposta") { state.stop() }
                    .keyboardShortcut(".")
                    .disabled(!state.currentIsResponding)
            }
            CommandMenu("Siri AI+") {
                Button("Nuovo progetto…") { ProjectPicker.choose { state.addProject(folder: $0) } }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Home") { state.section = .home }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("Modalità vocale") { state.voice.active ? state.voice.close() : state.voice.start(with: state) }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                Divider()
                Button("Fonti collegate…") { state.sourcesSheet = nil; state.showSourcesSheet = true }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
                Button("Attività") { state.section = .activity }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
                Button("Connettori") { state.section = .connectors }
            }
        }

        Settings {
            SettingsView().environment(state)
        }

        Window("Presentazione", id: "presenter") {
            PresenterView().environment(state)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
    }
}
