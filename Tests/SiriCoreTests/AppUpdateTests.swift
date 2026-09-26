import Foundation
import Testing
@testable import SiriCore

/// Aggiornamenti: confronto tra versioni e lettura della risposta di GitHub (senza rete).
@Suite struct AppUpdateTests {
    @Test func comparesVersionsPartByPart() {
        #expect(UpdateChecker.isNewer("2.1", than: "2.0"))
        #expect(UpdateChecker.isNewer("v2.1", than: "2.0"))
        #expect(UpdateChecker.isNewer("2.10", than: "2.9"))
        #expect(UpdateChecker.isNewer("3", than: "2.9.9"))
        #expect(UpdateChecker.isNewer("2.0.1", than: "2.0"))
        #expect(!UpdateChecker.isNewer("2.0", than: "2.0"))
        #expect(!UpdateChecker.isNewer("2.0", than: "2.0.0"))
        // Chi compila una versione più nuova di quella pubblicata non deve vedere l'invito a tornare indietro.
        #expect(!UpdateChecker.isNewer("2.0", than: "2.1"))
        #expect(!UpdateChecker.isNewer("", than: "2.0"))
    }

    private func release(tag: String, assets: [[String: String]] = [], body: String = "") -> Data {
        let object: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/ivanmosetti07/siri-ai-plus/releases/tag/\(tag)",
            "body": body,
            "assets": assets,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func newerReleaseOffersTheZip() {
        let data = release(tag: "v2.1", assets: [
            ["name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"],
            ["name": "Siri-AI-Plus-macOS.zip", "browser_download_url": "https://github.com/ivanmosetti07/siri-ai-plus/releases/download/v2.1/Siri-AI-Plus-macOS.zip"],
        ], body: "## Novità\r\n\r\n- Versione in inglese\r\n- Aggiornamenti")
        guard case .available(let update) = UpdateChecker.outcome(from: data, installed: "2.0") else {
            Issue.record("attesa una versione nuova")
            return
        }
        #expect(update.version == "2.1")
        #expect(update.downloadURL.lastPathComponent == "Siri-AI-Plus-macOS.zip")
        #expect(update.pageURL.absoluteString.hasSuffix("/tag/v2.1"))
        #expect(update.notes == "Novità\n- Versione in inglese\n- Aggiornamenti")
    }

    @Test func withoutZipTheReleasePageIsTheDownload() {
        guard case .available(let update) = UpdateChecker.outcome(from: release(tag: "v2.2"), installed: "2.1") else {
            Issue.record("attesa una versione nuova")
            return
        }
        #expect(update.downloadURL == update.pageURL)
    }

    @Test func sameOrOlderReleaseIsUpToDate() {
        #expect(UpdateChecker.outcome(from: release(tag: "v2.0"), installed: "2.0") == .upToDate(latest: "2.0"))
        #expect(UpdateChecker.outcome(from: release(tag: "v2.0"), installed: "2.1") == .upToDate(latest: "2.0"))
    }

    @Test func unreadableAnswersFail() {
        #expect(UpdateChecker.outcome(from: Data("{\"message\":\"Not Found\"}".utf8), installed: "2.0") == .failed)
        #expect(UpdateChecker.outcome(from: Data("non è json".utf8), installed: "2.0") == .failed)
    }
}
