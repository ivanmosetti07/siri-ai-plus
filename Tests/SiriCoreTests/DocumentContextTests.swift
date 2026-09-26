import Foundation
import Testing
@testable import SiriCore

@Suite struct DocumentContextTests {
    @MainActor @Test func appleReadsBeyondFirstPageOfOpenDocument() {
        let assistant = Assistant()
        var work = WorkContext()
        work.artifactKind = "documento"
        work.artifactTitle = "Verbale"
        work.artifactText = String(repeating: "Contesto della riunione e decisioni precedenti. ", count: 90)
            + "\n\nDecisione finale: approvato il budget di 18.700 euro."
        work.fullArtifactContextOnApple = true
        assistant.work = work
        let request = assistant.withContext("Riassumi questo documento")
        #expect(request.contains("18.700 euro"))
        #expect(request.contains("<<<INIZIO DATI: documento aperto>>>"))

        work.fullArtifactContextOnApple = false
        assistant.work = work
        let externalRequest = assistant.withContext("Riassumi questo documento")
        #expect(!externalRequest.contains("18.700 euro"))
    }
}
