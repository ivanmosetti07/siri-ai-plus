import AppKit
import Foundation
import ImagePlayground
import SiriCore

/// Generazione di immagini sul dispositivo con Image Playground (stili Animazione, Illustrazione, Schizzo).
@MainActor
enum ImageService {
    static let styles: [(id: String, label: String)] = [("animazione", "Animazione"), ("illustrazione", "Illustrazione"), ("schizzo", "Schizzo")]

    static func style(_ id: String?) -> ImagePlaygroundStyle {
        switch id {
        case "illustrazione": .illustration
        case "schizzo": .sketch
        default: .animation
        }
    }

    static func label(_ id: String) -> String { styles.first { $0.id == id }?.label ?? "Animazione" }

    enum ServiceError: LocalizedError {
        case unavailable, nothing
        var errorDescription: String? {
            switch self {
            case .unavailable: "Image Playground non è disponibile su questo Mac: controlla che Apple Intelligence sia attiva."
            case .nothing: "Non è stata generata nessuna immagine. Prova a descriverla in modo diverso."
            }
        }
    }

    /// Genera le immagini e le salva come PNG nella cartella indicata. `translate` serve quando la lingua non è supportata.
    static func generate(prompt: String, style: String, count: Int = 2, folder: URL,
                         translate: @escaping (String) async -> String) async throws -> [URL] {
        let creator: ImageCreator
        do { creator = try await ImageCreator() } catch {
            Agent.log("ImageCreator non disponibile: \(error)")
            throw ServiceError.unavailable
        }
        Agent.log("ImageCreator stili disponibili: \(creator.availableStyles.map(\.id))")
        let chosen = self.style(style)
        let finalStyle = creator.availableStyles.contains(chosen) ? chosen : (creator.availableStyles.first ?? .animation)

        func run(_ text: String) async throws -> [CGImage] {
            var images: [CGImage] = []
            for try await image in creator.images(for: [.text(text)], style: finalStyle, limit: count) {
                images.append(image.cgImage)
            }
            return images
        }

        var images: [CGImage]
        do {
            images = try await run(prompt)
        } catch let error as ImageCreator.Error where error == .unsupportedLanguage {
            images = try await run(await translate(prompt))
        }
        guard !images.isEmpty else { throw ServiceError.nothing }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = ArtifactFactory.safeName(String(prompt.prefix(40)))
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        return try images.enumerated().map { index, cgImage in
            let url = folder.appending(path: "\(base) \(stamp)-\(index + 1).png")
            let rep = NSBitmapImageRep(cgImage: cgImage)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            return url
        }
    }
}
