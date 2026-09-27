import Foundation
import FoundationModels
import Security

/// Il modello che scrive le risposte Apple. Il pianificatore resta sul Mac.
public enum AppleResponseModel: Sendable, Equatable {
    case onDevice
    case privateCloud

    public var label: String {
        switch self {
        case .onDevice: Language.t("Apple Intelligence sul Mac", "Apple Intelligence on your Mac")
        case .privateCloud: "Apple Intelligence · Private Cloud Compute"
        }
    }

    public var contextSize: Int {
        switch self {
        case .onDevice: Agent.model.contextSize
        case .privateCloud: 32_768
        }
    }

    /// Il modello sul Mac come lo riporta il sistema («AFM 3 Core · 4.096 token»). La variante la sceglie macOS
    /// (AFM 3 Core Advanced solo sui Mac più potenti): le app non possono chiederne un'altra.
    public static var onDeviceSummary: String {
        Language.isEnglish
            ? "\(Agent.model.variant.displayName) · \(Agent.model.contextSize.formatted(.number.locale(Language.en.locale))) tokens"
            : "\(Agent.model.variant.displayName) · \(Agent.model.contextSize.formatted(.number.locale(Locale(identifier: "it_IT")))) token"
    }

    /// Selezione separata dai controlli di sistema, per poter verificare anche il ripiego.
    public static func preferred(entitled: Bool, available: Bool, quotaReached: Bool) -> Self {
        entitled && available && !quotaReached ? .privateCloud : .onDevice
    }

    public static var hasPrivateCloudEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.private-cloud-compute" as CFString, nil) as? Bool == true
    }

    public static var preferred: Self {
        guard UserDefaults.standard.bool(forKey: "preferPrivateCloudCompute"), hasPrivateCloudEntitlement else { return .onDevice }
        let cloud = PrivateCloudComputeLanguageModel()
        return preferred(entitled: true, available: cloud.isAvailable, quotaReached: cloud.quotaUsage.isLimitReached)
    }

    public func session(instructions: String) -> LanguageModelSession {
        switch self {
        case .onDevice: LanguageModelSession(model: Agent.model, instructions: instructions)
        case .privateCloud: LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: instructions)
        }
    }

    /// Sessione che riparte da una conversazione già scritta (istruzioni come prima voce).
    public func session(transcript: Transcript) -> LanguageModelSession {
        switch self {
        case .onDevice: LanguageModelSession(model: Agent.model, transcript: transcript)
        case .privateCloud: LanguageModelSession(model: PrivateCloudComputeLanguageModel(), transcript: transcript)
        }
    }
}
