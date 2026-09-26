import Testing
@testable import SiriCore

@Suite struct AppleResponseModelTests {
    @Test func cloudRequiresEveryGate() {
        #expect(AppleResponseModel.preferred(entitled: true, available: true, quotaReached: false) == .privateCloud)
        #expect(AppleResponseModel.preferred(entitled: false, available: true, quotaReached: false) == .onDevice)
        #expect(AppleResponseModel.preferred(entitled: true, available: false, quotaReached: false) == .onDevice)
        #expect(AppleResponseModel.preferred(entitled: true, available: true, quotaReached: true) == .onDevice)
    }
}
