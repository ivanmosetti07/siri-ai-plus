import CoreServices
import Foundation

/// Permessi di macOS letti senza far comparire richieste (salvo quando si chiede esplicitamente).
/// macOS ricorda ogni risposta: con la firma stabile di Siri AI+ valgono anche dopo gli aggiornamenti.
public enum SystemAccess {
    public enum Status: String, Sendable, Equatable {
        case granted, denied, notDetermined, appNotRunning, unknown
    }

    /// Automazione: Siri AI+ può comandare l'app (Mail, Note, Messaggi…)? Con `ask` macOS chiede una sola volta.
    /// Da chiamare fuori dal thread principale: con `ask` aspetta la risposta dell'utente.
    public static func automation(_ bundleID: String, ask: Bool = false) -> Status {
        var target = AEAddressDesc()
        let created = bundleID.withCString { pointer in
            AECreateDesc(DescType(typeApplicationBundleID), pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask) {
        case noErr: return .granted
        case -1743: return .denied
        case -1744: return .notDetermined
        case -600: return .appNotRunning
        default: return .unknown
        }
    }

    /// Accesso completo al disco (serve per leggere Messaggi): si prova ad aprire un file protetto.
    public static var fullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = ["Library/Messages/chat.db", "Library/Safari/Bookmarks.plist",
                      "Library/Application Support/com.apple.TCC/TCC.db"].map { home.appending(path: $0).path }
        for path in probes where FileManager.default.fileExists(atPath: path) {
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 { close(descriptor); return true }
            return false
        }
        return false
    }
}
