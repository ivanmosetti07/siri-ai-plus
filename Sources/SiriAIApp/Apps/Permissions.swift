import AppKit
import AVFoundation
import Contacts
import CoreLocation
import EventKit
import Speech
import SiriCore
import SwiftUI

// MARK: - Permessi di macOS
//
// macOS ricorda ogni risposta per l'app firmata con lo stesso certificato: Siri AI+ legge lo stato senza chiedere
// e mostra una richiesta solo quando manca qualcosa e lo chiedi tu.

enum PermissionKind: String, CaseIterable, Identifiable {
    case calendar, reminders, contacts, mail, notes, messages, fullDisk, microphone, speech, location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: String(localized: "Calendario")
        case .reminders: String(localized: "Promemoria")
        case .contacts: String(localized: "Contatti")
        case .mail: String(localized: "Controllo di Mail")
        case .notes: String(localized: "Controllo di Note")
        case .messages: String(localized: "Controllo di Messaggi")
        case .fullDisk: String(localized: "Accesso completo al disco")
        case .microphone: String(localized: "Microfono")
        case .speech: String(localized: "Riconoscimento vocale")
        case .location: String(localized: "Posizione")
        }
    }

    var purpose: String {
        switch self {
        case .calendar: String(localized: "Vedere, creare e modificare gli eventi.")
        case .reminders: String(localized: "Vedere, creare, completare e modificare i promemoria e le liste.")
        case .contacts: String(localized: "Trovare numeri ed email di chi vuoi contattare e mostrare i nomi nei messaggi.")
        case .mail: String(localized: "Leggere il testo delle email, rispondere, inoltrare, spostare ed eliminare.")
        case .notes: String(localized: "Vedere, creare, modificare e spostare le note.")
        case .messages: String(localized: "Inviare messaggi dall'app Messaggi.")
        case .fullDisk: String(localized: "Aprire Mail all'istante e leggere le conversazioni di Messaggi.")
        case .microphone: String(localized: "Dettare le richieste e usare la modalità vocale.")
        case .speech: String(localized: "Trascrivere la voce sul Mac.")
        case .location: String(localized: "Il meteo della Home dove ti trovi (facoltativo).")
        }
    }

    /// App a cui si riferisce il permesso: la riga mostra la sua icona vera, come Impostazioni di Sistema.
    var source: SourceKind? {
        switch self {
        case .calendar: .calendar
        case .reminders: .reminders
        case .contacts: .contacts
        case .mail: .mail
        case .notes: .notes
        case .messages: .messages
        case .fullDisk, .microphone, .speech, .location: nil
        }
    }

    /// Icona dei permessi di sistema: i colori di Privacy e sicurezza.
    @MainActor func tile(size: CGFloat) -> Tile {
        if let source { return Tile(source, size: size) }
        let (symbol, colors): (String, [Color]) = switch self {
        case .microphone: ("mic.fill", Hue.orange)
        case .location: ("location.fill", Hue.blue)
        case .speech: ("waveform", Hue.gray)
        default: ("internaldrive.fill", Hue.gray)
        }
        return Tile(symbol: symbol, fill: AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)), size: size)
    }

    var bundleID: String? {
        switch self {
        case .mail: "com.apple.mail"
        case .notes: "com.apple.Notes"
        case .messages: "com.apple.MobileSMS"
        default: nil
        }
    }

    /// Pagina di Impostazioni di Sistema › Privacy e sicurezza.
    var pane: PermissionCenter.Pane {
        switch self {
        case .calendar: .calendars
        case .reminders: .reminders
        case .contacts: .contacts
        case .mail, .notes, .messages: .automation
        case .fullDisk: .fullDisk
        case .microphone: .microphone
        case .speech: .speech
        case .location: .location
        }
    }

    /// Si può chiedere da qui (per l'accesso al disco serve aggiungere l'app a mano nelle Impostazioni).
    var askable: Bool { self != .fullDisk && self != .location }
}

@MainActor @Observable
final class PermissionCenter {
    enum Pane: String {
        case calendars = "Privacy_Calendars", reminders = "Privacy_Reminders", contacts = "Privacy_Contacts",
             automation = "Privacy_Automation", fullDisk = "Privacy_AllFiles", microphone = "Privacy_Microphone",
             speech = "Privacy_SpeechRecognition", location = "Privacy_LocationServices"
    }

    static let shared = PermissionCenter()
    var statuses: [PermissionKind: SystemAccess.Status] = [:]
    var asking: PermissionKind?

    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") { NSWorkspace.shared.open(url) }
        // Per l'accesso al disco si trascina l'app nell'elenco: la si mostra nel Finder.
        if pane == .fullDisk { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    }

    var missing: [PermissionKind] { PermissionKind.allCases.filter { $0 != .location && statuses[$0] != nil && statuses[$0] != .granted } }

    /// Legge tutti gli stati senza far comparire richieste.
    func refresh() async {
        var result: [PermissionKind: SystemAccess.Status] = [:]
        result[.calendar] = Self.status(EKEventStore.authorizationStatus(for: .event))
        result[.reminders] = Self.status(EKEventStore.authorizationStatus(for: .reminder))
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: result[.contacts] = .granted
        case .notDetermined: result[.contacts] = .notDetermined
        default: result[.contacts] = .denied
        }
        for kind in [PermissionKind.mail, .notes, .messages] {
            guard let bundleID = kind.bundleID else { continue }
            result[kind] = await Task.detached { SystemAccess.automation(bundleID) }.value
        }
        result[.fullDisk] = await Task.detached { SystemAccess.fullDiskAccess }.value ? .granted : .denied
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: result[.microphone] = .granted
        case .notDetermined: result[.microphone] = .notDetermined
        default: result[.microphone] = .denied
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: result[.speech] = .granted
        case .notDetermined: result[.speech] = .notDetermined
        default: result[.speech] = .denied
        }
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: result[.location] = .granted
        case .notDetermined: result[.location] = .notDetermined
        default: result[.location] = .denied
        }
        statuses = result
    }

    private static func status(_ value: EKAuthorizationStatus) -> SystemAccess.Status {
        switch value {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Chiede il permesso (macOS lo chiede una volta sola e poi lo ricorda); se è già stato negato apre le Impostazioni.
    func request(_ kind: PermissionKind, state: AppState?) async {
        let current = statuses[kind]
        guard current != .granted else { return }
        guard kind.askable, current == .notDetermined || current == .appNotRunning || current == .unknown else {
            Self.openSettings(kind.pane)
            return
        }
        asking = kind
        defer { asking = nil }
        switch kind {
        case .calendar: _ = try? await Store.shared.ek.requestFullAccessToEvents()
        case .reminders: _ = try? await Store.shared.ek.requestFullAccessToReminders()
        case .contacts: _ = await Contacts.requestAccess()
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech: _ = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        case .mail, .notes, .messages:
            guard let bundleID = kind.bundleID else { break }
            // L'app deve essere aperta perché macOS possa chiedere: la si apre nascosta.
            if SystemAccess.automation(bundleID) == .appNotRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.hides = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                try? await Task.sleep(for: .seconds(1.5))
            }
            _ = await Task.detached { SystemAccess.automation(bundleID, ask: true) }.value
        case .fullDisk, .location: break
        }
        await refresh()
        await state?.refreshAccess()
    }
}

/// Pagina «Permessi di macOS» (Impostazioni › App).
struct PermissionsPanel: View {
    @Environment(AppState.self) private var state
    @State private var center = PermissionCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: "lock.shield.fill", colors: Hue.green, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Permessi di macOS").font(.system(size: 15, weight: .semibold))
                    Text("macOS ricorda ogni permesso: Siri AI+ ha una firma stabile, quindi valgono per sempre, anche dopo gli aggiornamenti. Qui vedi cosa manca e lo concedi una volta sola.")
                        .font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { Task { await center.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).iconHelp(String(localized: "Controlla di nuovo"))
            }
            VStack(spacing: 0) {
                ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Divider().padding(.leading, 52) }
                    row(kind)
                }
            }
            .glassCard(radius: 20)
        }
        .task { await center.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await center.refresh() }
        }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let status = center.statuses[kind]
        return HStack(spacing: 12) {
            kind.tile(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(DS.Fonts.bodyStrong)
                Text(kind.purpose).font(DS.Fonts.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if center.asking == kind {
                ProgressView().controlSize(.small)
            } else {
                switch status {
                case .granted:
                    Label("Consentito", systemImage: "checkmark.circle.fill").font(DS.Fonts.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
                case .none:
                    ProgressView().controlSize(.small)
                case .appNotRunning:
                    Button("Consenti") { Task { await center.request(kind, state: state) } }.controlSize(.small)
                        .help("Si verifica quando \(kind == .messages ? String(localized: "Messaggi") : String(localized: "l'app")) è aperta")
                case .notDetermined, .unknown:
                    Button(kind == .location ? String(localized: "Impostazioni") : String(localized: "Consenti")) { Task { await center.request(kind, state: state) } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                case .denied:
                    Button(kind == .fullDisk ? String(localized: "Concedi nelle Impostazioni") : String(localized: "Apri Impostazioni")) { PermissionCenter.openSettings(kind.pane) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
