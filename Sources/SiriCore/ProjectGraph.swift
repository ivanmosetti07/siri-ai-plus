import Foundation

// MARK: - Grafo delle note di un progetto
//
// Come il grafo di Obsidian: ogni nota Markdown è un neurone, ogni collegamento (`[[Nota]]`, `[testo](nota.md)`) una sinapsi.
// La disposizione riempie la sagoma di un cervello visto di lato: ogni cartella principale occupa un'area, le note più
// collegate diventano i centri, le altre si raccolgono intorno.

public struct ProjectGraph: Sendable {
    public struct Node: Sendable, Identifiable {
        public let id: Int
        public let path: String
        public let title: String
        /// Cartella principale («2_Aree», «3_Risorse»…; vuota per le note della radice).
        public let group: String
        public var degree: Int
        /// Posizione nella sagoma del cervello (x da -1,15 a 1,15; y da -0,9 a 1).
        public var x: Double = 0
        public var y: Double = 0
    }

    public struct Edge: Sendable, Hashable {
        public let a: Int
        public let b: Int
    }

    public var nodes: [Node] = []
    public var edges: [Edge] = []
    /// Cartelle principali, dalla più grande.
    public var groups: [String] = []
    /// Note in tutto (prima di tenere le più collegate).
    public var totalNotes = 0
    public var totalLinks = 0
    public var truncated: Bool { nodes.count < totalNotes }

    public init() {}

    /// I vicini di ogni nodo.
    public func neighbors() -> [[Int]] {
        var list = Array(repeating: [Int](), count: nodes.count)
        for edge in edges {
            list[edge.a].append(edge.b)
            list[edge.b].append(edge.a)
        }
        return list
    }
}

extension ProjectGuide {
    /// Il grafo dei collegamenti fra le note Markdown (le più collegate, al massimo `limit`), già disposto nel cervello.
    /// `folder`: solo le note di una cartella principale.
    /// Tornando sul grafo con lo stesso albero non si rilegge niente.
    public func graph(limit: Int = 1400, folder: String? = nil) async -> ProjectGraph {
        let tree = await currentTree()
        let key = "\(folder ?? "")|\(limit)"
        if let cached = cachedGraph(key, tree: tree.built) { return cached }
        let root = self.root
        let graph = await Task.detached(priority: .userInitiated) {
            var graph = Self.buildGraph(tree: tree, root: root, folder: folder, limit: limit)
            GraphLayout.brain(&graph)
            return graph
        }.value
        storeGraph(graph, key: key, tree: tree.built)
        return graph
    }

    static func buildGraph(tree: Tree, root: URL, folder: String?, limit: Int) -> ProjectGraph {
        var notes = tree.files.filter { ["md", "markdown"].contains(($0 as NSString).pathExtension.lowercased()) }
        if let folder, !folder.isEmpty { notes = notes.filter { $0.hasPrefix(folder + "/") } }
        // Oltre 15.000 note si leggono le prime (per livello): il grafo resta leggibile e la lettura rapida.
        notes = Array(notes.prefix(15_000))
        var index: [String: Int] = [:]
        var byName: [String: [Int]] = [:]
        for (position, path) in notes.enumerated() {
            index[path] = position
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            byName[name, default: []].append(position)
        }
        /// «a/b/../c/./d.md» → «a/c/d.md» (standardizingPath risolve «..» solo nei percorsi assoluti).
        func normalized(_ path: String) -> String {
            var parts: [Substring] = []
            for part in path.split(separator: "/") {
                if part == "." { continue }
                if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
                parts.append(part)
            }
            return parts.joined(separator: "/")
        }
        func resolve(_ raw: String, from source: String) -> Int? {
            var target = raw.removingPercentEncoding ?? raw
            if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
            if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
            target = target.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !target.contains("://") else { return nil }
            // Immagini, PDF e allegati non sono note.
            let attachments: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "mp4", "mov", "mp3", "m4a", "wav", "canvas", "excalidraw", "zip"]
            guard !attachments.contains((target as NSString).pathExtension.lowercased()) else { return nil }
            let own = index[source]
            let folderOfSource = (source as NSString).deletingLastPathComponent
            let withExtension = target.lowercased().hasSuffix(".md") ? target : target + ".md"
            // Come Obsidian: percorso relativo alla nota, poi dalla radice del progetto…
            for candidate in [folderOfSource.isEmpty ? withExtension : folderOfSource + "/" + withExtension, withExtension] {
                if let found = index[normalized(candidate)], found != own { return found }
            }
            // …poi un percorso che finisce così («[[rossi-moto/INDEX]]»), poi il nome in qualunque cartella,
            // preferendo le note più vicine a quella che collega.
            let name = ((target as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            let tail = "/" + normalized(withExtension).lowercased()
            var matches = (byName[name] ?? []).filter { $0 != own }
            if target.contains("/") {
                let suffixed = matches.filter { ("/" + notes[$0].lowercased()).hasSuffix(tail) }
                if !suffixed.isEmpty { matches = suffixed }
            }
            func distance(_ candidate: Int) -> Int {
                let a = folderOfSource.split(separator: "/"), b = (notes[candidate] as NSString).deletingLastPathComponent.split(separator: "/")
                let shared = zip(a, b).prefix { $0 == $1 }.count
                return a.count + b.count - 2 * shared
            }
            return matches.min { distance($0) != distance($1) ? distance($0) < distance($1) : notes[$0] < notes[$1] }
        }
        let wiki = try? NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)
        let markdown = try? NSRegularExpression(pattern: #"\]\(([^)\s]+\.md)(?:#[^)]*)?\)"#)
        var edges = Set<ProjectGraph.Edge>()
        for (position, path) in notes.enumerated() {
            guard let handle = FileHandle(forReadingAtPath: root.appending(path: path).path) else { continue }
            let data = (try? handle.read(upToCount: 96_000)) ?? Data()
            try? handle.close()
            let text = String(decoding: data, as: UTF8.self)
            let range = NSRange(text.startIndex..., in: text)
            var targets: [String] = []
            for regex in [wiki, markdown].compactMap({ $0 }) {
                for match in regex.matches(in: text, range: range) {
                    if let r = Range(match.range(at: 1), in: text) { targets.append(String(text[r])) }
                }
            }
            for target in targets {
                guard let other = resolve(target, from: path), other != position else { continue }
                edges.insert(ProjectGraph.Edge(a: min(position, other), b: max(position, other)))
            }
        }
        var degree = Array(repeating: 0, count: notes.count)
        for edge in edges { degree[edge.a] += 1; degree[edge.b] += 1 }
        // Le più collegate; senza collegamenti solo se c'è spazio.
        let kept = notes.indices.sorted { degree[$0] != degree[$1] ? degree[$0] > degree[$1] : notes[$0] < notes[$1] }
            .prefix(limit).filter { degree[$0] > 0 || notes.count <= limit }
        var remap: [Int: Int] = [:]
        var graph = ProjectGraph()
        graph.totalNotes = notes.count
        graph.totalLinks = edges.count
        // Con una cartella scelta, le aree sono le sue sottocartelle.
        let depth = folder.map { $0.split(separator: "/").count } ?? 0
        func stem(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        // Nomi ripetuti (INDEX, STATE, CLAUDE in ogni cartella): con la cartella davanti, «rossi-moto/STATE»;
        // se anche così si confondono, con la cartella dell'area: «mainstream-agency/…/log/log-index».
        var sameName: [String: [Int]] = [:]
        for old in kept { sameName[stem(notes[old]).lowercased(), default: []].append(old) }
        var titles: [Int: String] = [:]
        for olds in sameName.values where olds.count > 1 {
            let short = olds.map { old -> String in
                let parts = notes[old].split(separator: "/")
                return parts.count > 1 ? "\(parts[parts.count - 2])/\(stem(notes[old]))" : stem(notes[old])
            }
            var uses: [String: Int] = [:]
            for label in short { uses[label, default: 0] += 1 }
            for (position, old) in olds.enumerated() {
                let parts = notes[old].split(separator: "/")
                if uses[short[position], default: 0] == 1 {
                    titles[old] = short[position]
                } else if parts.count - 2 > depth + 1 {
                    titles[old] = "\(parts[depth + 1])/…/\(short[position])"
                } else {
                    titles[old] = (notes[old] as NSString).deletingPathExtension
                }
            }
        }
        // Una cartella che contiene quasi tutto (come «2_Aree») si divide nelle sue sottocartelle: colori e aree più utili.
        func groupOf(_ path: String, splitting split: Set<String>) -> String {
            let parts = path.split(separator: "/")
            guard parts.count > depth + 1 else { return "" }
            let top = String(parts[depth])
            return split.contains(top) && parts.count > depth + 2 ? top + "/" + parts[depth + 1] : top
        }
        var topSizes: [String: Int] = [:]
        for old in kept { topSizes[groupOf(notes[old], splitting: []), default: 0] += 1 }
        let split = Set(topSizes.filter { !$0.key.isEmpty && Double($0.value) > Double(kept.count) * 0.45 }.map(\.key))
        for old in kept {
            let path = notes[old]
            let group = groupOf(path, splitting: split)
            remap[old] = graph.nodes.count
            graph.nodes.append(ProjectGraph.Node(id: graph.nodes.count, path: path, title: titles[old] ?? stem(path), group: group, degree: 0))
        }
        for edge in edges {
            guard let a = remap[edge.a], let b = remap[edge.b] else { continue }
            graph.edges.append(ProjectGraph.Edge(a: a, b: b))
            graph.nodes[a].degree += 1
            graph.nodes[b].degree += 1
        }
        var sizes: [String: Int] = [:]
        for node in graph.nodes { sizes[node.group, default: 0] += 1 }
        graph.groups = sizes.keys.sorted { sizes[$0]! != sizes[$1]! ? sizes[$0]! > sizes[$1]! : $0 < $1 }
        return graph
    }
}

// MARK: - Disposizione a forma di cervello

public enum GraphLayout {
    /// Sagoma di un cervello visto di lato (fronte a sinistra): cervello, cervelletto e tronco.
    public static let lobes: [(x: Double, y: Double, rx: Double, ry: Double)] = [
        (0.0, -0.08, 1.0, 0.72),     // cervello
        (0.56, 0.5, 0.34, 0.22),     // cervelletto
        (0.26, 0.74, 0.11, 0.22),    // tronco
    ]

    /// Solchi principali: centrale, scissura laterale, parieto-occipitale e il confine col cervelletto.
    /// I neuroni li lasciano liberi, così i lobi si riconoscono anche solo dai punti.
    public static let sulci: [[(x: Double, y: Double)]] = [
        curve((0.05, -0.79), (0.14, -0.46), (-0.2, -0.2), (-0.1, 0.08)),
        curve((-0.7, 0.3), (-0.32, 0.1), (0.1, 0.2), (0.52, -0.04)),
        curve((0.58, -0.68), (0.66, -0.54), (0.63, -0.4), (0.76, -0.27)),
        (0...24).map { step -> (x: Double, y: Double) in
            let x = 0.2 + Double(step) / 24 * 0.78
            let y: Double = -0.08 + 0.72 * (1 - x * x).squareRoot()
            return (x, y)
        },
    ]

    /// Punti di una curva di Bézier cubica.
    static func curve(_ p0: (Double, Double), _ p1: (Double, Double), _ p2: (Double, Double), _ p3: (Double, Double)) -> [(x: Double, y: Double)] {
        (0...32).map { step -> (x: Double, y: Double) in
            let t = Double(step) / 32, u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            let x: Double = a * p0.0 + b * p1.0 + c * p2.0 + d * p3.0
            let y: Double = a * p0.1 + b * p1.1 + c * p2.1 + d * p3.1
            return (x, y)
        }
    }

    /// Il punto cade in un solco (a meno di `gap` da una delle sue linee).
    public static func nearSulcus(_ x: Double, _ y: Double, gap: Double) -> Bool {
        for line in sulci {
            for (p, q) in zip(line, line.dropFirst()) {
                let dx = q.x - p.x, dy = q.y - p.y
                let length = dx * dx + dy * dy
                let t = length > 0 ? max(0, min(1, ((x - p.x) * dx + (y - p.y) * dy) / length)) : 0
                let ex = p.x + t * dx - x, ey = p.y + t * dy - y
                if ex * ex + ey * ey < gap * gap { return true }
            }
        }
        return false
    }

    /// Aree per le cartelle, dalla più grande: frontale, parietale, occipitale, temporale, cervelletto, poi le zone intermedie.
    static let areas: [(x: Double, y: Double)] = [
        (-0.58, -0.12), (0.08, -0.5), (0.62, -0.12), (-0.02, 0.3), (0.56, 0.5), (-0.3, -0.48), (0.36, 0.14), (-0.5, 0.26), (0.3, -0.3), (-0.2, 0.05),
    ]

    /// Dentro la sagoma (con un margine).
    public static func inside(_ x: Double, _ y: Double, margin: Double = 0) -> Bool {
        lobes.contains { lobe in
            let dx = (x - lobe.x) / max(0.01, lobe.rx - margin), dy = (y - lobe.y) / max(0.01, lobe.ry - margin)
            return dx * dx + dy * dy <= 1
        }
    }

    /// Il punto della sagoma più vicino, per chi esce.
    static func pullInside(_ x: inout Double, _ y: inout Double) {
        guard !inside(x, y, margin: 0.04) else { return }
        var best: (Double, Double, Double) = (x, y, .infinity)
        for lobe in lobes {
            let dx = x - lobe.x, dy = y - lobe.y
            let scale = 1 / max(0.0001, ((dx * dx) / ((lobe.rx - 0.04) * (lobe.rx - 0.04)) + (dy * dy) / ((lobe.ry - 0.04) * (lobe.ry - 0.04))).squareRoot())
            let px = lobe.x + dx * min(1, scale), py = lobe.y + dy * min(1, scale)
            let distance = (px - x) * (px - x) + (py - y) * (py - y)
            if distance < best.2 { best = (px, py, distance) }
        }
        x = best.0
        y = best.1
    }

    /// Forze: repulsione fra vicini (griglia), molle sui collegamenti, richiamo verso l'area della cartella, sagoma come confine.
    public static func brain(_ graph: inout ProjectGraph, iterations: Int = 260) {
        let count = graph.nodes.count
        guard count > 0 else { return }
        var generator = SeededGenerator(seed: 0x5EED_B8A1)
        let areaOf: [String: (Double, Double)] = Dictionary(uniqueKeysWithValues: graph.groups.enumerated().map { index, group in
            let anchor = areas[index % areas.count]
            // Oltre le aree previste, le cartelle piccole si dispongono intorno al centro.
            let ring = Double(index / areas.count) * 0.12
            return (group, (anchor.x * (1 - ring), anchor.y * (1 - ring)))
        })
        var x = [Double](repeating: 0, count: count)
        var y = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let anchor = areaOf[graph.nodes[index].group] ?? (0, 0)
            let angle = Double.random(in: 0..<(2 * .pi), using: &generator)
            let radius = Double.random(in: 0..<0.28, using: &generator)
            x[index] = anchor.0 + cos(angle) * radius
            y[index] = anchor.1 + sin(angle) * radius * 0.8
            pullInside(&x[index], &y[index])
        }
        let area = 3.2  // superficie approssimata della sagoma
        let ideal = (area / Double(count)).squareRoot() * 0.9
        let cell = ideal * 2.5
        var temperature = 0.08
        for step in 0..<iterations {
            var fx = [Double](repeating: 0, count: count)
            var fy = [Double](repeating: 0, count: count)
            // Repulsione solo fra nodi vicini (griglia): lineare anche con migliaia di note.
            var grid: [Int: [Int]] = [:]
            func key(_ i: Int, _ j: Int) -> Int { (i + 4096) * 8192 + (j + 4096) }
            for index in 0..<count { grid[key(Int((x[index] / cell).rounded(.down)), Int((y[index] / cell).rounded(.down))), default: []].append(index) }
            for index in 0..<count {
                let ci = Int((x[index] / cell).rounded(.down)), cj = Int((y[index] / cell).rounded(.down))
                for di in -1...1 {
                    for dj in -1...1 {
                        for other in grid[key(ci + di, cj + dj)] ?? [] where other != index {
                            let dx = x[index] - x[other], dy = y[index] - y[other]
                            let distance = max(0.002, (dx * dx + dy * dy).squareRoot())
                            guard distance < cell else { continue }
                            let force = ideal * ideal / distance
                            fx[index] += dx / distance * force
                            fy[index] += dy / distance * force
                        }
                    }
                }
            }
            // Molle sui collegamenti.
            for edge in graph.edges {
                let dx = x[edge.a] - x[edge.b], dy = y[edge.a] - y[edge.b]
                let distance = max(0.002, (dx * dx + dy * dy).squareRoot())
                let force = distance * distance / ideal * 0.6
                fx[edge.a] -= dx / distance * force; fy[edge.a] -= dy / distance * force
                fx[edge.b] += dx / distance * force; fy[edge.b] += dy / distance * force
            }
            // Ogni cartella resta nella sua area.
            for index in 0..<count {
                let anchor = areaOf[graph.nodes[index].group] ?? (0, 0)
                fx[index] += (anchor.0 - x[index]) * 0.9 * ideal
                fy[index] += (anchor.1 - y[index]) * 0.9 * ideal
            }
            for index in 0..<count {
                let length = max(0.000_001, (fx[index] * fx[index] + fy[index] * fy[index]).squareRoot())
                let move = min(length, temperature)
                x[index] += fx[index] / length * move
                y[index] += fy[index] / length * move
                pullInside(&x[index], &y[index])
            }
            temperature = 0.08 * (1 - Double(step) / Double(iterations)) + 0.002
        }
        spread(&x, &y, neighbors: graph.neighbors(), generator: &generator)
        for index in 0..<count {
            graph.nodes[index].x = x[index]
            graph.nodes[index].y = y[index]
        }
    }

    /// Le forze decidono chi sta vicino a chi, ma ammassano le note al centro: qui ogni nota prende un posto fra quelli
    /// sparsi in modo uniforme nella sagoma (prima le più collegate, il posto libero più vicino), poi le vicine si
    /// scambiano il posto finché i collegamenti si accorciano. Il cervello si riempie tutto, le aree restano.
    static func spread(_ x: inout [Double], _ y: inout [Double], neighbors: [[Int]], generator: inout SeededGenerator) {
        let count = x.count
        let (slots, spacing) = self.slots(for: count, generator: &generator)
        guard slots.count >= count else { return }
        // Stessa distribuzione dei posti su ciascun asse, conservando l'ordine delle note.
        let sortedX = slots.map(\.x).sorted(), sortedY = slots.map(\.y).sorted()
        var targetX = x, targetY = y
        for (rank, index) in (0..<count).sorted(by: { x[$0] < x[$1] }).enumerated() {
            targetX[index] = sortedX[min(sortedX.count - 1, (rank * sortedX.count + sortedX.count / 2) / count)]
        }
        for (rank, index) in (0..<count).sorted(by: { y[$0] < y[$1] }).enumerated() {
            targetY[index] = sortedY[min(sortedY.count - 1, (rank * sortedY.count + sortedY.count / 2) / count)]
        }
        // Posti in una griglia per trovare in fretta i vicini.
        func cell(_ px: Double, _ py: Double) -> (Int, Int) { (Int(((px + 2) / spacing).rounded(.down)), Int(((py + 2) / spacing).rounded(.down))) }
        func key(_ i: Int, _ j: Int) -> Int { i * 10_000 + j }
        var buckets: [Int: [Int]] = [:]
        for (slot, point) in slots.enumerated() {
            let (i, j) = cell(point.x, point.y)
            buckets[key(i, j), default: []].append(slot)
        }
        let maxRing = Int(4 / spacing) + 2
        var occupant = [Int?](repeating: nil, count: slots.count)
        var slotOf = [Int](repeating: 0, count: count)
        for node in (0..<count).sorted(by: { neighbors[$0].count > neighbors[$1].count }) {
            let (ci, cj) = cell(targetX[node], targetY[node])
            var best: (slot: Int, distance: Double)?
            for ring in 0...maxRing {
                var cells: [(Int, Int)] = ring == 0 ? [(ci, cj)] : []
                if ring > 0 {
                    for i in (ci - ring)...(ci + ring) { cells.append((i, cj - ring)); cells.append((i, cj + ring)) }
                    for j in (cj - ring + 1)..<(cj + ring) { cells.append((ci - ring, j)); cells.append((ci + ring, j)) }
                }
                for (i, j) in cells {
                    for slot in buckets[key(i, j)] ?? [] where occupant[slot] == nil {
                        let dx = slots[slot].x - targetX[node], dy = slots[slot].y - targetY[node]
                        let distance = dx * dx + dy * dy
                        if distance < best?.distance ?? .infinity { best = (slot, distance) }
                    }
                }
                // Oltre questo anello i posti sono tutti più lontani.
                if let best, Double(ring) * spacing >= best.distance.squareRoot() { break }
            }
            guard let slot = best?.slot else { continue }
            occupant[slot] = node
            slotOf[node] = slot
            x[node] = slots[slot].x
            y[node] = slots[slot].y
        }
        // Scambi con i posti vicini se i collegamenti si accorciano (la distanza fra le due note scambiate non cambia).
        func cost(_ node: Int, at px: Double, _ py: Double, ignoring other: Int?) -> Double {
            var total = 0.0
            for neighbor in neighbors[node] where neighbor != other {
                let dx = px - x[neighbor], dy = py - y[neighbor]
                total += dx * dx + dy * dy
            }
            return total
        }
        for _ in 0..<3 {
            for node in 0..<count {
                let (ci, cj) = cell(x[node], y[node])
                for i in (ci - 1)...(ci + 1) {
                    for j in (cj - 1)...(cj + 1) {
                        for slot in buckets[key(i, j)] ?? [] where slot != slotOf[node] {
                            let here = slots[slotOf[node]], there = slots[slot]
                            let other = occupant[slot]
                            var before = cost(node, at: here.x, here.y, ignoring: other)
                            var after = cost(node, at: there.x, there.y, ignoring: other)
                            if let other {
                                before += cost(other, at: there.x, there.y, ignoring: node)
                                after += cost(other, at: here.x, here.y, ignoring: node)
                            }
                            guard after < before - 1e-12 else { continue }
                            let old = slotOf[node]
                            occupant[old] = other
                            occupant[slot] = node
                            slotOf[node] = slot
                            x[node] = there.x
                            y[node] = there.y
                            if let other {
                                slotOf[other] = old
                                x[other] = here.x
                                y[other] = here.y
                            }
                        }
                    }
                }
            }
        }
    }

    /// Posti sparsi in modo uniforme nella sagoma (griglia esagonale mossa appena, come cellule): almeno `count`.
    static func slots(for count: Int, generator: inout SeededGenerator) -> (points: [(x: Double, y: Double)], spacing: Double) {
        // Superficie della sagoma circa 2,45: il 12% di posti in più lascia qualche vuoto naturale.
        var spacing = (2 * 2.45 / (Double(count) * 1.12 * 3.0.squareRoot())).squareRoot()
        var points: [(x: Double, y: Double)] = []
        for _ in 0..<12 {
            points = []
            let rowHeight = spacing * 3.0.squareRoot() / 2
            var row = 0
            var py = -1.0
            while py <= 1.05 {
                var px = -1.2 + (row.isMultiple(of: 2) ? 0 : spacing / 2)
                while px <= 1.2 {
                    let jx = Double.random(in: -0.28...0.28, using: &generator) * spacing
                    let jy = Double.random(in: -0.28...0.28, using: &generator) * spacing
                    if inside(px + jx, py + jy, margin: 0.03), !nearSulcus(px + jx, py + jy, gap: 0.045) { points.append((px + jx, py + jy)) }
                    px += spacing
                }
                py += rowHeight
                row += 1
            }
            if points.count >= count { break }
            spacing *= points.isEmpty ? 0.5 : 0.97 * (Double(points.count) / Double(count)).squareRoot()
        }
        return (points, spacing)
    }
}

/// Numeri casuali ripetibili: lo stesso progetto si dispone sempre allo stesso modo.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
