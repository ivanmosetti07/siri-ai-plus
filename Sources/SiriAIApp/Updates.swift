import AppKit
import SiriCore
import SwiftUI

extension AppState {
    /// Controlla subito e poi ogni 6 ore; senza rete (o se GitHub non risponde) riprova dopo 15 minuti.
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

    /// «Controlla aggiornamenti…» dal menu: dice sempre com'è andata.
    func checkForUpdatesNow() {
        Task {
            switch await UpdateChecker.check(installed: UpdateChecker.installedVersion) {
            case .available(let update):
                availableUpdate = update
                showToast(String(localized: "Siri AI+ \(update.version) è disponibile: scaricala dal simbolo in fondo alla barra laterale"), symbol: "arrow.down.circle.fill")
            case .upToDate(let latest):
                availableUpdate = nil
                showToast(String(localized: "Hai già l'ultima versione (\(UpdateChecker.installedVersion ?? latest))"))
            case .failed:
                showToast(String(localized: "Non riesco a controllare gli aggiornamenti: sei connesso a internet?"), symbol: "wifi.exclamationmark")
            }
        }
    }
}

/// Il simbolo in fondo alla barra laterale quando su GitHub c'è una versione più recente: apre una finestrella con
/// la versione, le novità e il pulsante per scaricarla.
struct UpdateButton: View {
    let update: AppUpdate
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.accentColor.opacity(0.25)).interactive(), in: .circle)
        .iconHelp(String(localized: "Aggiornamento disponibile: Siri AI+ \(update.version)"))
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Siri AI+ \(update.version) è disponibile", systemImage: "arrow.down.circle.fill")
                    .font(DS.Fonts.bodyStrong)
                Text("Hai la versione \(UpdateChecker.installedVersion ?? "?"). Scarica lo ZIP, aprilo e sposta la nuova app in Applicazioni al posto di quella vecchia: chat, progetti e impostazioni restano.")
                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !update.notes.isEmpty {
                    Text(update.notes).font(DS.Fonts.caption).lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Novità") { NSWorkspace.shared.open(update.pageURL) }
                    Spacer()
                    Button("Scarica") {
                        NSWorkspace.shared.open(update.downloadURL)
                        showing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }
}
