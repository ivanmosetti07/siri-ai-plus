// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiriAI",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SiriCore", targets: ["SiriCore"]),
        .executable(name: "SiriAI", targets: ["SiriAI"]),
    ],
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
            // Le traduzioni le compila Xcode (build.sh); la build SwiftPM di prova resta in italiano.
            exclude: ["Localizable.xcstrings", "InfoPlist.xcstrings"],
            linkerSettings: [.linkedFramework("ImagePlayground")]
        ),
        .testTarget(name: "SiriCoreTests", dependencies: ["SiriCore"], path: "Tests/SiriCoreTests"),
    ]
)
