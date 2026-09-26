import CoreML
import Foundation

// MARK: - Il modello di rizzo-pii in Core ML
//
// ModernBERT (base mmBERT) da 0,3B parametri che etichetta ogni token con 45 classi (B-/I- di 22 categorie e O).
// Convertito una volta con `Support/rizzo-pii/convert.py` (pesi fp16; 64, 128, 256 o 512 token). Qui si riempie
// l'ingresso fino alla forma più vicina e si raggruppano le etichette come la pipeline di Hugging Face con
// `aggregation_strategy="simple"`.

final class PIIModel: @unchecked Sendable {
    private let model: MLModel
    let labels: [String]
    static let shapes = [64, 128, 256, 512]

    init(url: URL, labels: [String], computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
        self.labels = labels
    }

    /// Etichetta e probabilità di ogni token (al massimo 512, compresi «<bos>» e «<eos>»).
    func predict(_ ids: [Int32]) throws -> [(label: Int, score: Double)] {
        guard let size = Self.shapes.first(where: { $0 >= ids.count }) else { throw PrivacyError.failed("blocco troppo lungo per il modello") }
        let input = try MLMultiArray(shape: [1, NSNumber(value: size)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: size)], dataType: .int32)
        input.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for index in 0..<size { buffer[index] = index < ids.count ? ids[index] : 0 }
        }
        mask.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for index in 0..<size { buffer[index] = index < ids.count ? 1 : 0 }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["input_ids": input, "attention_mask": mask])
        guard let logits = try model.prediction(from: features).featureValue(for: "logits")?.multiArrayValue else {
            throw PrivacyError.failed("il modello non ha restituito le etichette")
        }
        let classes = labels.count
        let strides = logits.strides.map(\.intValue)
        var result: [(Int, Double)] = []
        result.reserveCapacity(ids.count)
        func read(_ pointer: (Int) -> Double) {
            for token in 0..<ids.count {
                var best = 0
                var values = [Double](repeating: 0, count: classes)
                for label in 0..<classes {
                    values[label] = pointer(token * strides[1] + label * strides[2])
                    if values[label] > values[best] { best = label }
                }
                // Softmax: la probabilità della classe scelta.
                let top = values[best]
                let sum = values.reduce(0) { $0 + exp($1 - top) }
                result.append((best, 1 / sum))
            }
        }
        switch logits.dataType {
        case .float32:
            logits.withUnsafeBufferPointer(ofType: Float.self) { buffer in read { Double(buffer[$0]) } }
        case .float16:
            logits.withUnsafeBufferPointer(ofType: Float16.self) { buffer in read { Double(buffer[$0]) } }
        default:
            read { logits[$0].doubleValue }
        }
        return result
    }

    /// Entità di un blocco di testo (posizioni in code point del blocco), come `aggregation_strategy="simple"`:
    /// token consecutivi con la stessa categoria (un «B-» ne apre una nuova), punteggio medio, «O» scartati.
    static func entities(tokens: [PIITokenizer.Token], predictions: [(label: Int, score: Double)], labels: [String]) -> [PIIEntity] {
        func tag(_ name: String) -> (begin: Bool, tag: String) {
            if name.hasPrefix("B-") { return (true, String(name.dropFirst(2))) }
            if name.hasPrefix("I-") { return (false, String(name.dropFirst(2))) }
            return (false, name)
        }
        var groups: [(tag: String, scores: [Double], start: Int, end: Int)] = []
        var current: (tag: String, scores: [Double], start: Int, end: Int)?
        for (token, prediction) in zip(tokens, predictions) where !token.special {
            let (begin, name) = tag(labels[prediction.label])
            if let open = current, open.tag == name, !begin {
                current = (name, open.scores + [prediction.score], open.start, token.end)
            } else {
                if let open = current { groups.append(open) }
                current = (name, [prediction.score], token.start, token.end)
            }
        }
        if let open = current { groups.append(open) }
        return groups.filter { $0.tag != "O" }.map {
            PIIEntity(label: $0.tag, start: $0.start, end: $0.end, score: $0.scores.reduce(0, +) / Double($0.scores.count),
                      validated: false, source: .model)
        }
    }
}
