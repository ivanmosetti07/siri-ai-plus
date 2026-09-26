import AppKit
import SiriCore
import SwiftUI

extension SourceKind {
    /// App di sistema corrispondente, per "Apri in…".
    var systemBundleID: String {
        switch self {
        case .calendar: "com.apple.iCal"
        case .mail: "com.apple.mail"
        case .reminders: "com.apple.reminders"
        case .notes: "com.apple.Notes"
        case .files: "com.apple.finder"
        case .photos: "com.apple.Photos"
        case .messages: "com.apple.MobileSMS"
        case .contacts: "com.apple.AddressBook"
        case .voiceMemos: "com.apple.VoiceMemos"
        }
    }

    var systemAppName: String { self == .files ? "Finder" : label }

    func openSystemApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

// MARK: - Contenitore

/// Area principale quando si apre un'app dalla barra laterale: una lastra di vetro sospesa sull'aurora,
/// con la stessa struttura per tutte le app. Siri AI+ resta a destra.
struct AppContainer: View {
    @Environment(AppState.self) private var state
    let source: SourceKind

    var body: some View {
        Group {
            if source.support == .comingSoon {
                ComingSoonAppView(source: source)
            } else if !state.isEnabled(source) {
                ConnectAppView(source: source)
            } else {
                Group {
                    switch source {
                    case .calendar: CalendarAppView()
                    case .reminders: RemindersAppView()
                    case .mail: MailAppView()
                    case .notes: NotesAppView()
                    case .files: FilesAppView()
                    case .messages: MessagesAppView()
                    case .contacts: ContactsAppView()
                    case .voiceMemos: VoiceMemosAppView()
                    case .photos: ComingSoonAppView(source: source)
                    }
                }
                .scrollContentBackground(.hidden)
                .clipShape(.rect(cornerRadius: 26))
                .glassCard(radius: 26)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Scheda in vetro per le app ancora da collegare o in arrivo.
private struct AppGate<Actions: View>: View {
    let source: SourceKind
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Tile(source, size: 64)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
            Text(title).font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
            Text(message).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { actions }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: 480)
        .glassCard(radius: 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct ConnectAppView: View {
    @Environment(AppState.self) private var state
    let source: SourceKind

    var body: some View {
        AppGate(source: source, title: "Collega \(source.label)",
                message: "Per vedere e gestire \(source.label.lowercased()) da Siri AI+ serve il tuo consenso: \(source.readCapability.lowercased()). macOS lo chiede una volta sola e poi lo ricorda.") {
            if state.systemDenied(source) {
                Button("Apri Impostazioni di Sistema") { state.openPrivacySettings(for: source) }.buttonStyle(.glassProminent)
            } else {
                Button("Collega \(source.label)") { state.setEnabled(source, true) }.buttonStyle(.glassProminent)
            }
        }
    }
}

struct ComingSoonAppView: View {
    let source: SourceKind

    var body: some View {
        AppGate(source: source, title: "\(source.label) arriva presto",
                message: "Qui potrai \(source.readCapability.lowercased()) e chiedere a Siri AI+ di lavorarci. Nel frattempo puoi aprire l'app di sistema.") {
            Button("Apri \(source.systemAppName)") { source.openSystemApp() }.buttonStyle(.glass)
        }
    }
}
