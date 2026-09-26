// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiriAI",
    platforms: [.macOS("27.0")],
    targets: [
        // Logica condivisa: strumenti EventKit, sessione del modello, dati del pannello "Oggi".
        .target(
            name: "SiriCore",
            path: "Sources/SiriCore",
            linkerSettings: [
                .linkedFramework("FoundationModels"),
                .linkedFramework("EventKit"),
            ]
        ),
        // Harness a riga di comando.
        .executableTarget(name: "SiriAI", dependencies: ["SiriCore"], path: "Sources/SiriAI"),
        // App desktop SwiftUI (impacchettata in SiriAI.app da build.sh).
        .executableTarget(
            name: "SiriAIApp",
            dependencies: ["SiriCore"],
            path: "Sources/SiriAIApp",
            linkerSettings: [.linkedFramework("ImagePlayground")]
        ),
        .testTarget(name: "SiriCoreTests", dependencies: ["SiriCore"], path: "Tests/SiriCoreTests"),
    ]
)
