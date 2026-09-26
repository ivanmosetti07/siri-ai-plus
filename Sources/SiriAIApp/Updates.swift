import AppKit
import SiriCore
import SwiftUI

extension AppState {
    /// Controlla all'apertura e periodicamente. Dopo un errore di rete riprova prima.
    func startUpdateChecks() {
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                let outcome = await UpdateChecker.check(installed: UpdateChecker.installedVersion)
                guard let self else { return }
                switch outcome {
                case .available(let update):
                    if self.availableUpdate != update { Agent.log("AGGIORNAMENTO: su GitHub c'è la versione \(update.version)") }
                    self.availableUpdate = update
                case .upToDate:
                    self.availableUpdate = nil
                case .failed:
                    break
                }
                try? await Task.sleep(for: .seconds(outcome == .failed ? 15 * 60 : 6 * 3600))
            }
        }
    }

    func checkForUpdatesNow() {
        Task {
            switch await UpdateChecker.check(installed: UpdateChecker.installedVersion) {
            case .available(let update):
                availableUpdate = update
                showToast(Language.t("Siri AI+ \(update.version) è disponibile: usa il simbolo nella barra laterale",
                                     "Siri AI+ \(update.version) is available: use the icon in the sidebar"), symbol: "arrow.down.circle.fill")
            case .upToDate(let latest):
                availableUpdate = nil
                showToast(Language.t("Hai già l'ultima versione (\(UpdateChecker.installedVersion ?? latest))",
                                     "You already have the latest version (\(UpdateChecker.installedVersion ?? latest))"))
            case .failed:
                showToast(Language.t("Non riesco a controllare gli aggiornamenti: sei connesso a internet?",
                                     "I couldn't check for updates. Are you connected to the internet?"), symbol: "wifi.exclamationmark")
            }
        }
    }

    /// Scarica, verifica e passa l'installazione a un helper prima di chiudere l'app.
    func downloadAndInstall(_ update: AppUpdate) {
        guard !updateDownloading else { return }
        updateDownloading = true
        updateError = nil
        Task {
            do {
                let staged = try await UpdateInstaller.stage(update)
                try UpdateInstaller.restart(with: staged)
                NSApp.terminate(nil)
            } catch {
                updateError = error.localizedDescription
                showToast(Language.t("Aggiornamento non riuscito: \(error.localizedDescription)",
                                     "Update failed: \(error.localizedDescription)"), symbol: "exclamationmark.triangle.fill")
            }
            updateDownloading = false
        }
    }
}

/// Scarica solo la release del repository e verifica firma, identità e versione.
private enum UpdateInstaller {
    enum Problem: LocalizedError {
        case noArchive, invalidArchive, invalidSignature, differentApp, olderVersion, missingHelper
        var errorDescription: String? {
            switch self {
            case .noArchive: Language.t("Questa release non contiene lo ZIP dell'app.", "This release has no app ZIP.")
            case .invalidArchive: Language.t("Lo ZIP non contiene Siri AI+.", "The ZIP does not contain Siri AI+.")
            case .invalidSignature: Language.t("La firma dell'aggiornamento non è valida.", "The update signature is invalid.")
            case .differentApp: Language.t("L'aggiornamento non appartiene a questa app.", "The update does not belong to this app.")
            case .olderVersion: Language.t("La versione scaricata non corrisponde alla release.", "The downloaded version does not match the release.")
            case .missingHelper: Language.t("Manca il componente per riavviare l'app.", "The app restart component is missing.")
            }
        }
    }

    static func stage(_ update: AppUpdate) async throws -> URL {
        guard update.downloadURL.scheme == "https", update.downloadURL.host == "github.com",
              update.downloadURL.path.hasPrefix("/\(UpdateChecker.repository)/releases/download/"),
              update.downloadURL.pathExtension.lowercased() == "zip" else { throw Problem.noArchive }
        var request = URLRequest(url: update.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("Siri-AI-Plus-Updater", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Problem.invalidArchive }
        let root = FileManager.default.temporaryDirectory.appending(path: "SiriAIUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appending(path: "update.zip")
        try FileManager.default.moveItem(at: temporary, to: archive)
        let extracted = root.appending(path: "extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        return try await Task.detached(priority: .utility) {
            try command("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
            let app = extracted.appending(path: "Siri AI+.app")
            guard FileManager.default.fileExists(atPath: app.path),
                  (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw Problem.invalidArchive }
            try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            let current = Bundle.main
            let candidate = Bundle(url: app)
            guard candidate?.bundleIdentifier == current.bundleIdentifier,
                  candidate?.bundleIdentifier == "com.ivanmosetti.siriaiplus" else { throw Problem.differentApp }
            let version = candidate?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            guard !UpdateChecker.isNewer(update.version, than: version),
                  UpdateChecker.isNewer(version, than: UpdateChecker.installedVersion ?? "0") else { throw Problem.olderVersion }
            let currentTeam = try teamID(current.bundleURL)
            let candidateTeam = try teamID(app)
            guard !currentTeam.isEmpty, currentTeam == candidateTeam else { throw Problem.invalidSignature }
            return app
        }.value
    }

    @MainActor static func restart(with staged: URL) throws {
        let current = Bundle.main.bundleURL
        guard let helper = Bundle.main.resourceURL?.appending(path: "install_update.zsh"),
              FileManager.default.fileExists(atPath: helper.path) else { throw Problem.missingHelper }
        let expectedTeam = try teamID(current)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, current.path, expectedTeam]
        try process.run()
    }

    @discardableResult private static func command(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw Problem.invalidSignature }
        return output
    }

    private static func teamID(_ app: URL) throws -> String {
        let output = try command("/usr/bin/codesign", ["-dv", app.path])
        return output.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) } ?? ""
    }
}

struct UpdateButton: View {
    @Environment(AppState.self) private var state
    let update: AppUpdate
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Group {
                if state.updateDownloading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.down.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor) }
            }
            .frame(width: 34, height: 34).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.accentColor.opacity(0.25)).interactive(), in: .circle)
        .iconHelp(Language.t("Aggiornamento disponibile: Siri AI+ \(update.version)", "Update available: Siri AI+ \(update.version)"))
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Label(Language.t("Siri AI+ \(update.version) è disponibile", "Siri AI+ \(update.version) is available"), systemImage: "arrow.down.circle.fill")
                    .font(DS.Fonts.bodyStrong)
                Text(Language.t("Versione installata: \(UpdateChecker.installedVersion ?? "?"). L'app scaricherà la release, verificherà la firma e si riavvierà. macOS potrebbe chiedere la password di amministratore.",
                                "Installed version: \(UpdateChecker.installedVersion ?? "?"). The app will download the release, verify its signature, and restart. macOS may ask for an administrator password."))
                    .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !update.notes.isEmpty { Text(update.notes).font(DS.Fonts.caption).lineLimit(6).fixedSize(horizontal: false, vertical: true) }
                if let error = state.updateError { Text(error).font(DS.Fonts.caption).foregroundStyle(.orange) }
                HStack {
                    Button(Language.t("Novità", "What's new")) { NSWorkspace.shared.open(update.pageURL) }
                    Spacer()
                    Button(Language.t("Scarica e riavvia", "Download and restart")) { state.downloadAndInstall(update) }
                        .buttonStyle(.borderedProminent).disabled(state.updateDownloading)
                }
            }
            .padding(16).frame(width: 320)
        }
    }
}
