import Foundation
import Testing
@testable import SiriCore

@Suite struct ActionIdentityTests {
    @Test func actionSnapshotPersists() throws {
        let action = PendingAction(kind: .deleteReminder(identifier: "reminder-42"),
                                   title: "Eliminare il promemoria «Dentista»?", detail: "Lista Personale",
                                   expectedTitle: "Dentista", expectedContainer: "Personale")
        let restored = try JSONDecoder().decode(PendingAction.self, from: JSONEncoder().encode(action))
        #expect(restored.expectedTitle == "Dentista")
        #expect(restored.expectedContainer == "Personale")
    }

    @Test func oldActionCannotExecuteWithoutTargetSnapshot() throws {
        let old = PendingAction(kind: .deleteReminder(identifier: "reminder-42"),
                                title: "Eliminare il promemoria «Dentista»?", detail: "Lista Personale")
        #expect(throws: Error.self) { try EventKitService.perform(old) }
    }
}
