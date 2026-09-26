import AppKit
import SiriCore
import SwiftUI

// MARK: - Grafo del progetto
//
// Le note della cartella come neuroni dentro la sagoma di un cervello: ogni cartella principale ha il suo colore e la sua area,
// i collegamenti fra le note sono sinapsi percorse da piccoli impulsi. Passando sopra una nota si accendono i suoi collegamenti;
// cliccandola si vede di cosa parla e la si apre.

struct ProjectGraphView: View {
    @Environment(AppState.self) private var state
    let project: ProjectModel

    @State private var graph: ProjectGraph?
    @State private var neighbors: [[Int]] = []
    @State private var loading = true
    @State private var folder: String?
    @State private var hovered: Int?
    @State private var selected: Int?
    @State private var query = ""
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var animated = true
    /// Grandezza della vista del grafo (per centrare una nota cercata).
    @State private var canvasSize: CGSize = .zero

    /// Colori di sistema, uno per cartella (le note della radice sono bianche).
    static let palette: [Color] = [
        Color(red: 0.04, green: 0.52, blue: 1.0), Color(red: 0.75, green: 0.35, blue: 0.95), Color(red: 1.0, green: 0.27, blue: 0.47),
        Color(red: 0.19, green: 0.78, blue: 0.84), Color(red: 1.0, green: 0.62, blue: 0.04), Color(red: 0.2, green: 0.84, blue: 0.62),
        Color(red: 0.45, green: 0.45, blue: 1.0), Color(red: 1.0, green: 0.84, blue: 0.1), Color(red: 0.4, green: 0.86, blue: 0.3),
        Color(red: 0.95, green: 0.45, blue: 0.75),
    ]

    var body: some View {
        ZStack {
            Self.background
            if let graph, !graph.nodes.isEmpty {
                GeometryReader { geometry in
                    let frame = Frame(size: geometry.size, zoom: zoom, offset: offset)
                    ZStack {
                        staticLayer(graph, frame: frame)
                        if animated { activityLayer(graph, frame: frame) }
                        labels(graph, frame: frame)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = nearest(to: location, in: graph, frame: frame)
                        case .ended: hovered = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        withAnimation(DS.Motion.quick) { selected = nearest(to: value.location, in: graph, frame: frame) }
                    })
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            let start = dragStart ?? offset
                            dragStart = start
                            offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                        }
                        .onEnded { _ in dragStart = nil })
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { value in
                            let start = zoomStart ?? zoom
                            zoomStart = start
                            zoom = min(8, max(0.5, start * value.magnification))
                        }
                        .onEnded { _ in zoomStart = nil })
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
            } else if loading {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Leggo i collegamenti tra le note…").font(DS.Fonts.body).foregroundStyle(.white.opacity(0.75))
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "brain").font(.system(size: 42, weight: .thin)).foregroundStyle(.white.opacity(0.6))
                    Text("Nessuna nota collegata").font(DS.Fonts.section).foregroundStyle(.white)
                    Text("Il grafo mostra le note Markdown e i loro collegamenti ([[nota]] o [testo](nota.md)).")
                        .font(DS.Fonts.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            VStack(spacing: 0) {
                toolbar
                Spacer()
                HStack(alignment: .bottom) {
                    if let graph { legend(graph) }
                    Spacer()
                    zoomControls
                }
            }
            .padding(14)
            if let graph, let selected, graph.nodes.indices.contains(selected) {
                HStack {
                    Spacer()
                    detail(graph, node: graph.nodes[selected])
                        .frame(width: 290)
                        .padding(.top, 66)
                        .padding(.trailing, 14)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .clipShape(.rect(cornerRadius: 26))
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .task(id: folder) { await load() }
    }

    // MARK: Dati

    private func load() async {
        loading = true
        selected = nil
        hovered = nil
        let result = await ProjectGuide.shared(for: project.folder).graph(folder: folder)
        graph = result
        neighbors = result.neighbors()
        loading = false
        // Diagnostica (solo prove): `--graph-focus nome` mette a fuoco una nota come la ricerca.
        if let name = AppTesting.value(after: "--graph-focus") {
            try? await Task.sleep(for: .milliseconds(500))
            query = name
            find()
        }
    }

    private func color(for group: String, in graph: ProjectGraph) -> Color {
        guard !group.isEmpty, let index = graph.groups.firstIndex(of: group) else { return Color(red: 0.8, green: 0.83, blue: 1) }
        return Self.palette[index % Self.palette.count]
    }

    /// Da coordinate del grafo a punti della vista.
    struct Frame {
        let size: CGSize
        let zoom: CGFloat
        let offset: CGSize
        var scale: CGFloat { min(size.width / 2.6, size.height / 2.1) * zoom }
        var center: CGPoint { CGPoint(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height - 8 * zoom) }
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: center.x + CGFloat(x) * scale, y: center.y + CGFloat(y) * scale) }
    }

    private func radius(_ node: ProjectGraph.Node, frame: Frame) -> CGFloat {
        (1.6 + CGFloat(min(40, node.degree)).squareRoot() * 1.15) * min(2.2, max(0.8, frame.zoom.squareRoot()))
    }

    private func nearest(to location: CGPoint, in graph: ProjectGraph, frame: Frame) -> Int? {
        var best: (Int, CGFloat)?
        for node in graph.nodes {
            let point = frame.point(node.x, node.y)
            let distance = hypot(point.x - location.x, point.y - location.y)
            let reach = max(9, radius(node, frame: frame) + 5)
            if distance <= reach, distance < (best?.1 ?? .infinity) { best = (node.id, distance) }
        }
        return best?.0
    }

    /// Nota evidenziata (sotto il mouse, o scelta) e le sue vicine.
    private var focus: Int? { hovered ?? selected }

    // MARK: Disegno

    static let background = ZStack {
        LinearGradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.09), Color(red: 0.05, green: 0.03, blue: 0.13)], startPoint: .top, endPoint: .bottom)
        RadialGradient(colors: [Color(red: 0.25, green: 0.2, blue: 0.6).opacity(0.35), .clear], center: .center, startRadius: 10, endRadius: 520)
    }

    /// Sagoma del cervello, collegamenti e neuroni: si ridisegna solo quando cambiano vista, zoom o evidenziazione.
    /// Collegamenti e neuroni sono raccolti per colore: poche chiamate di disegno anche con migliaia di note.
    private func staticLayer(_ graph: ProjectGraph, frame: Frame) -> some View {
        let focus = self.focus
        let lit: Set<Int> = focus.map { Set(neighbors.indices.contains($0) ? neighbors[$0] : []).union([$0]) } ?? []
        return Canvas { context, _ in
            Self.drawBrain(in: &context, frame: frame)

            // Sinapsi: curve leggere; intorno alla nota evidenziata si accendono col colore della nota collegata.
            var quiet: [String: Path] = [:]
            var active: [String: Path] = [:]
            for edge in graph.edges {
                let a = graph.nodes[edge.a], b = graph.nodes[edge.b]
                let start = frame.point(a.x, a.y), end = frame.point(b.x, b.y)
                let control = Self.bend(start, end, by: 0.12)
                if let focus, edge.a == focus || edge.b == focus {
                    let group = edge.a == focus ? b.group : a.group
                    active[group, default: Path()].move(to: start)
                    active[group, default: Path()].addQuadCurve(to: end, control: control)
                } else {
                    quiet[a.group, default: Path()].move(to: start)
                    quiet[a.group, default: Path()].addQuadCurve(to: end, control: control)
                }
            }
            let quietOpacity = focus == nil ? 0.17 : 0.035
            for (group, path) in quiet {
                context.stroke(path, with: .color(color(for: group, in: graph).opacity(quietOpacity)), lineWidth: 0.6)
            }
            for (group, path) in active {
                context.stroke(path, with: .color(color(for: group, in: graph).opacity(0.85)), lineWidth: 1.4)
            }

            // Neuroni: alone sfocato, corpo colorato, nucleo luminoso.
            var halos: [String: Path] = [:]
            var bodies: [String: Path] = [:]
            var dimBodies: [String: Path] = [:]
            var cores = Path()
            var dimCores = Path()
            for node in graph.nodes {
                let point = frame.point(node.x, node.y)
                let isLit = lit.contains(node.id)
                let r = radius(node, frame: frame) * (isLit ? 1.35 : 1)
                let core = r * 0.42
                let coreRect = CGRect(x: point.x - core, y: point.y - core, width: core * 2, height: core * 2)
                if focus != nil, !isLit {
                    dimBodies[node.group, default: Path()].addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
                    dimCores.addEllipse(in: coreRect)
                } else {
                    let halo = r * 2.3
                    halos[node.group, default: Path()].addEllipse(in: CGRect(x: point.x - halo, y: point.y - halo, width: halo * 2, height: halo * 2))
                    bodies[node.group, default: Path()].addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
                    cores.addEllipse(in: coreRect)
                }
            }
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 5))
                for (group, path) in halos { glow.fill(path, with: .color(color(for: group, in: graph).opacity(focus == nil ? 0.4 : 0.45))) }
            }
            for (group, path) in dimBodies { context.fill(path, with: .color(color(for: group, in: graph).opacity(0.22))) }
            context.fill(dimCores, with: .color(.white.opacity(0.14)))
            for (group, path) in bodies { context.fill(path, with: .color(color(for: group, in: graph).opacity(0.95))) }
            context.fill(cores, with: .color(.white.opacity(0.9)))
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }

    /// La sagoma: un solo contorno per cervello, cervelletto e tronco, con i solchi appena accennati.
    private static func drawBrain(in context: inout GraphicsContext, frame: Frame) {
        func ellipse(_ lobe: (x: Double, y: Double, rx: Double, ry: Double), scale: Double = 1) -> CGRect {
            let origin = frame.point(lobe.x - lobe.rx * scale, lobe.y - lobe.ry * scale)
            return CGRect(x: origin.x, y: origin.y, width: CGFloat(lobe.rx * 2 * scale) * frame.scale, height: CGFloat(lobe.ry * 2 * scale) * frame.scale)
        }
        let lobes = GraphLayout.lobes
        var outline = Path(ellipseIn: ellipse(lobes[0]))
        for lobe in lobes.dropFirst() { outline = outline.union(Path(ellipseIn: ellipse(lobe))) }
        let center = frame.point(0, -0.1)
        context.fill(outline, with: .radialGradient(Gradient(colors: [Color(red: 0.5, green: 0.45, blue: 1).opacity(0.09), Color(red: 0.3, green: 0.4, blue: 1).opacity(0.025)]),
                                                   center: center, startRadius: 0, endRadius: frame.scale * 1.1))
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 6))
            glow.stroke(outline, with: .color(Color(red: 0.55, green: 0.5, blue: 1).opacity(0.35)), lineWidth: 2)
        }
        context.stroke(outline, with: .color(Color(red: 0.78, green: 0.74, blue: 1).opacity(0.22)), lineWidth: 1)

        // Circonvoluzioni: contorni ondulati concentrici e i due solchi principali, solo dentro il cervello.
        context.drawLayer { folds in
            folds.clip(to: Path(ellipseIn: ellipse(lobes[0], scale: 0.97)))
            let cerebrum = lobes[0]
            var contours = Path()
            for (ring, scale) in [0.84, 0.66, 0.47, 0.28].enumerated() {
                for step in 0...120 {
                    let angle = Double(step) / 120 * 2 * .pi
                    let wobble = 1 + 0.045 * sin(angle * Double(9 + ring * 2) + Double(ring))
                    let point = frame.point(cerebrum.x + cos(angle) * cerebrum.rx * scale * wobble, cerebrum.y + sin(angle) * cerebrum.ry * scale * wobble)
                    if step == 0 { contours.move(to: point) } else { contours.addLine(to: point) }
                }
            }
            folds.stroke(contours, with: .color(.white.opacity(0.035)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
        }
        // I solchi, lasciati liberi dai neuroni: linee luminose che separano i lobi.
        var sulci = Path()
        for line in GraphLayout.sulci {
            for (index, point) in line.enumerated() {
                let position = frame.point(point.x, point.y)
                if index == 0 { sulci.move(to: position) } else { sulci.addLine(to: position) }
            }
        }
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 4))
            glow.stroke(sulci, with: .color(Color(red: 0.55, green: 0.5, blue: 1).opacity(0.4)), lineWidth: 3.5)
        }
        context.stroke(sulci, with: .color(Color(red: 0.8, green: 0.76, blue: 1).opacity(0.22)), lineWidth: 1)
    }

    /// Attività neurale: impulsi che corrono lungo le sinapsi (di più intorno alla nota evidenziata) e i centri che respirano.
    private func activityLayer(_ graph: ProjectGraph, frame: Frame) -> some View {
        let focus = self.focus
        let hubs = graph.nodes.sorted { $0.degree > $1.degree }.prefix(24).map(\.id)
        let focusEdges: [ProjectGraph.Edge] = focus.map { f in graph.edges.filter { $0.a == f || $0.b == f } } ?? []
        return TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, _ in
                guard !graph.edges.isEmpty else { return }
                context.addFilter(.blur(radius: 1.2))
                let pulses = focusEdges.isEmpty ? min(60, graph.edges.count) : min(40, focusEdges.count * 3)
                for index in 0..<pulses {
                    let period = 2.6 + Double(index % 7) * 0.35
                    let cycle = floor((time + Double(index) * 0.37) / period)
                    let progress = ((time + Double(index) * 0.37) / period) - cycle
                    let edge = focusEdges.isEmpty
                        ? graph.edges[Int(UInt64(bitPattern: Int64(cycle * 7919 + Double(index) * 104_729)) % UInt64(graph.edges.count))]
                        : focusEdges[index % focusEdges.count]
                    let forward = focusEdges.isEmpty ? Int(cycle) % 2 == 0 : edge.a == focus
                    let a = graph.nodes[forward ? edge.a : edge.b], b = graph.nodes[forward ? edge.b : edge.a]
                    let start = frame.point(a.x, a.y), end = frame.point(b.x, b.y)
                    // Stessa curva della sinapsi, percorsa nel verso dell'impulso.
                    let mid = Self.bend(start, end, by: forward ? 0.12 : -0.12)
                    let point = Self.along(start, mid, end, at: CGFloat(progress))
                    let fade = sin(Double.pi * progress)
                    let size: CGFloat = focusEdges.isEmpty ? 2.2 : 2.8
                    context.fill(Path(ellipseIn: CGRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2)),
                                 with: .color(color(for: a.group, in: graph).opacity(0.9 * fade)))
                    context.fill(Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)),
                                 with: .color(.white.opacity(fade)))
                }
                for (index, id) in hubs.enumerated() {
                    let node = graph.nodes[id]
                    let point = frame.point(node.x, node.y)
                    let breath = 0.5 + 0.5 * sin(time * 1.4 + Double(index))
                    let r = radius(node, frame: frame) * (2.6 + 1.2 * CGFloat(breath))
                    context.stroke(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                                   with: .color(color(for: node.group, in: graph).opacity(0.18 * (1 - breath) + 0.04)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Punto di controllo di una sinapsi: a metà strada, spostato di lato.
    static func bend(_ start: CGPoint, _ end: CGPoint, by amount: CGFloat) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        return CGPoint(x: (start.x + end.x) / 2 + dy * amount, y: (start.y + end.y) / 2 - dx * amount)
    }

    /// Punto della curva (Bézier quadratica) a `t` fra 0 e 1.
    static func along(_ start: CGPoint, _ control: CGPoint, _ end: CGPoint, at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u, b = 2 * u * t, c = t * t
        let x: CGFloat = a * start.x + b * control.x + c * end.x
        let y: CGFloat = a * start.y + b * control.y + c * end.y
        return CGPoint(x: x, y: y)
    }

    /// I nomi delle note più collegate (di più avvicinandosi), o di quella evidenziata con le vicine; senza sovrapporsi.
    private func labels(_ graph: ProjectGraph, frame: Frame) -> some View {
        let focus = self.focus
        let candidates: [Int]
        if let focus {
            let near = (neighbors.indices.contains(focus) ? neighbors[focus] : []).sorted { graph.nodes[$0].degree > graph.nodes[$1].degree }
            candidates = [focus] + near.prefix(14)
        } else {
            let count = frame.zoom > 3 ? 160 : frame.zoom > 1.7 ? 60 : 22
            candidates = graph.nodes.sorted { $0.degree > $1.degree }.prefix(count).map(\.id)
        }
        return Canvas { context, size in
            context.addFilter(.shadow(color: .black.opacity(0.85), radius: 3))
            var taken: [CGRect] = []
            for id in candidates {
                let node = graph.nodes[id]
                let point = frame.point(node.x, node.y)
                guard point.x > -40, point.y > -20, point.x < size.width + 40, point.y < size.height + 20 else { continue }
                let strong = id == focus
                let text = context.resolve(Text(node.title)
                    .font(.system(size: strong ? 13 : 10.5, weight: strong ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(strong ? 1 : 0.8)))
                let measured = text.measure(in: CGSize(width: 260, height: 40))
                let center = CGPoint(x: point.x, y: point.y - radius(node, frame: frame) - (strong ? 11 : 8))
                let box = CGRect(x: center.x - measured.width / 2 - 3, y: center.y - measured.height / 2, width: measured.width + 6, height: measured.height)
                guard strong || !taken.contains(where: { $0.intersects(box) }) else { continue }
                taken.append(box)
                context.draw(text, at: center, anchor: .center)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Controlli

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            if let graph {
                Text(summary(graph)).font(DS.Fonts.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                TextField("Cerca una nota", text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 170)
                    .onSubmit(find)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            Menu {
                Button("Tutto il progetto", systemImage: "brain") { folder = nil }
                if let folder, folder.contains("/") {
                    Button("Su di un livello", systemImage: "arrow.up") { self.folder = (folder as NSString).deletingLastPathComponent }
                }
                // Le aree del grafo mostrato: scegliendone una si scende nelle sue sottocartelle.
                if let graph, graph.groups.contains(where: { !$0.isEmpty }) {
                    Divider()
                    ForEach(graph.groups.filter { !$0.isEmpty }, id: \.self) { group in
                        Button(group, systemImage: "folder") { folder = (folder.map { $0 + "/" } ?? "") + group }
                    }
                }
            } label: {
                Label(folder.map { ($0 as NSString).lastPathComponent } ?? String(localized: "Tutto il progetto"), systemImage: "folder")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            Button { animated.toggle() } label: {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(animated ? Color(red: 0.4, green: 0.85, blue: 1) : .white.opacity(0.5))
                    .frame(width: 18)
            }
            .buttonStyle(.glass)
            .help(animated ? String(localized: "Ferma gli impulsi sulle sinapsi") : String(localized: "Mostra gli impulsi sulle sinapsi"))
        }
    }

    private func summary(_ graph: ProjectGraph) -> String {
        let notes = graph.truncated ? String(localized: "\(graph.nodes.count.formatted()) note più collegate su \(graph.totalNotes.formatted())") : String(localized: "\(graph.nodes.count.formatted()) note")
        return String(localized: "\(notes) · \(graph.edges.count.formatted()) collegamenti")
    }

    private func legend(_ graph: ProjectGraph) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(graph.groups.prefix(8)), id: \.self) { group in
                HStack(spacing: 7) {
                    Circle().fill(color(for: group, in: graph)).frame(width: 8, height: 8)
                        .shadow(color: color(for: group, in: graph), radius: 4)
                    Text(group.isEmpty ? String(localized: "cartella principale") : group).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { withAnimation(DS.Motion.standard) { zoom = max(0.5, zoom / 1.4) } } label: { Image(systemName: "minus").frame(width: 28, height: 28) }
            Button { withAnimation(DS.Motion.standard) { zoom = 1; offset = .zero } } label: { Image(systemName: "scope").frame(width: 28, height: 28) }
                .help("Adatta alla vista")
            Button { withAnimation(DS.Motion.standard) { zoom = min(8, zoom * 1.4) } } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }

    /// Scheda della nota scelta: dove sta, con quali note è collegata, e le azioni.
    private func detail(_ graph: ProjectGraph, node: ProjectGraph.Node) -> some View {
        let linked = (neighbors.indices.contains(node.id) ? neighbors[node.id] : []).map { graph.nodes[$0] }.sorted { $0.degree > $1.degree }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Circle().fill(color(for: node.group, in: graph)).frame(width: 10, height: 10).padding(.top, 5)
                    .shadow(color: color(for: node.group, in: graph), radius: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    Text(node.path).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(2).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button { withAnimation(DS.Motion.quick) { selected = nil } } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
            }
            Text(node.degree == 1 ? String(localized: "1 collegamento") : String(localized: "\(node.degree) collegamenti")).font(DS.Fonts.caption).foregroundStyle(.white.opacity(0.7))
            if !linked.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(linked.prefix(8)) { other in
                        Button { withAnimation(DS.Motion.quick) { selected = other.id } } label: {
                            HStack(spacing: 6) {
                                Circle().fill(color(for: other.group, in: graph)).frame(width: 6, height: 6)
                                Text(other.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if linked.count > 8 { Text("e altre \(linked.count - 8)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                }
            }
            HStack(spacing: 8) {
                Button { state.openFile(project.folder.appending(path: node.path)) } label: { Label("Apri", systemImage: "doc.text") }
                    .buttonStyle(.glassProminent)
                Button { state.send(String(localized: "Riassumi il file \(node.path) e dimmi con cosa è collegato")) } label: { Label("Chiedi", systemImage: "sparkle") }
                    .buttonStyle(.glass)
                    .help("Chiedi a Siri AI+ di questa nota (nella chat del pannello)")
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    /// Cerca una nota per nome e la porta al centro.
    private func find() {
        guard let graph, !query.isEmpty else { return }
        let lower = query.lowercased()
        let byTitle = graph.nodes.filter { $0.title.lowercased().contains(lower) }
        let matches = byTitle.isEmpty ? graph.nodes.filter { $0.path.lowercased().contains(lower) } : byTitle
        guard let node = matches.max(by: { $0.degree < $1.degree }) else {
            state.showToast(String(localized: "Nessuna nota con «\(query)» nel grafo"), symbol: "magnifyingglass")
            return
        }
        let newZoom = max(zoom, 2.2)
        // La nota va al centro: con lo zoom nuovo si sposta la vista di quanto dista dal centro.
        let scale = Frame(size: canvasSize, zoom: newZoom, offset: .zero).scale
        withAnimation(DS.Motion.standard) {
            selected = node.id
            zoom = newZoom
            offset = CGSize(width: -CGFloat(node.x) * scale, height: -CGFloat(node.y) * scale + 8 * newZoom)
        }
    }
}
