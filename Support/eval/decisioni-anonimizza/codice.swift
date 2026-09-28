import Foundation

/// Calcola la distanza di Levenshtein tra due stringhe con la programmazione dinamica.
public func levenshtein(_ a: String, _ b: String) -> Int {
    let left = Array(a), right = Array(b)
    guard !left.isEmpty else { return right.count }
    guard !right.isEmpty else { return left.count }
    var previous = Array(0...right.count)
    var current = [Int](repeating: 0, count: right.count + 1)
    for i in 1...left.count {
        current[0] = i
        for j in 1...right.count {
            let cost = left[i - 1] == right[j - 1] ? 0 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        }
        swap(&previous, &current)
    }
    return previous[right.count]
}

struct Cache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    let limit: Int

    mutating func insert(_ value: Value, for key: Key) {
        if storage[key] == nil { order.append(key) }
        storage[key] = value
        if order.count > limit { storage[order.removeFirst()] = nil }
    }

    func value(for key: Key) -> Value? { storage[key] }
}
