import Charts
import SiriCore
import SwiftUI

// MARK: - Apertura

/// L'apertura della Home, come iPhone Duo e il suo «Mac Duo»: la vista si solleva dalla cerniera in basso,
/// da piegata e sfocata a dritta e nitida, mentre il cielo dietro si mette a fuoco.
struct OpeningEffect: ViewModifier, Animatable {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let closed = 1 - min(1, max(0, progress))
        content
            .rotation3DEffect(.degrees(closed * 62), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.42)
            .scaleEffect(1 - closed * 0.08, anchor: .bottom)
            .offset(y: closed * 46)
            .blur(radius: closed * 18)
            .opacity(min(1, progress * 1.8))
    }
}

// MARK: - Contenitori

/// Pannello in Liquid Glass con angoli ampi, come le schede di iOS 27.
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 20
    var radius: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: radius))
    }
}

/// Intestazione piccola in maiuscolo, come le schede di Meteo.
struct PanelLabel: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text.uppercased(), systemImage: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(.secondary)
    }
}

/// Scheda della sezione «La tua giornata»: titolo colorato con freccia (come «Passi ›» in Salute) e contenuto.
struct DashCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var trailing: String?
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { action?() } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if action != nil { Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .bold)).opacity(0.8) }
                    Spacer(minLength: 8)
                    if let trailing { Text(trailing).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary) }
                }
                .foregroundStyle(tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(action == nil)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}

// MARK: - Metriche

struct DashMetric: Identifiable {
    let label: String
    let value: String
    var note: String?
    let tint: Color
    var action: (() -> Void)?
    var id: String { label }
}

/// Le metriche sotto il grafico: etichetta colorata, valore grande, nota piccola.
struct MetricsGrid: View {
    let metrics: [DashMetric]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 14, alignment: .topLeading)], alignment: .leading, spacing: 16) {
            ForEach(metrics) { metric in
                Button { metric.action?() } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 3) {
                            Text(metric.label).font(.system(size: 13, weight: .semibold))
                            if metric.action != nil { Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold)) }
                        }
                        .foregroundStyle(metric.tint)
                        Text(metric.value)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let note = metric.note {
                            Text(note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(metric.action == nil)
            }
        }
    }
}

// MARK: - Meteo

/// Il meteo come in cima all'app Meteo: luogo, temperatura grande e sottile, condizione, massima e minima.
struct WeatherHero: View {
    let weather: WeatherModel
    @State private var choosingCity = false

    var body: some View {
        VStack(spacing: 0) {
            Button { choosingCity = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: weather.usesLocation ? "location.fill" : "mappin.and.ellipse").font(.system(size: 13, weight: .semibold))
                    Text(weather.snapshot?.place ?? weather.city).font(.system(size: 24, weight: .medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cambia la città del meteo")
            .popover(isPresented: $choosingCity, arrowEdge: .bottom) { CityPicker(weather: weather) }
            if let error = weather.lastError, weather.snapshot != nil {
                Text(error).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange).padding(.top, 2)
            }
            if let snapshot = weather.snapshot {
                Text(" \(Int(snapshot.temperature.rounded()))°")
                    .font(.system(size: 112, weight: .thin))
                    .contentTransition(.numericText(value: snapshot.temperature))
                    .padding(.vertical, -12)
                HStack(spacing: 8) {
                    Image(systemName: snapshot.symbol)
                        .symbolRenderingMode(.multicolor)
                        .symbolEffect(.bounce, value: snapshot.code)
                    Text(snapshot.condition.label)
                }
                .font(.system(size: 21, weight: .semibold))
                if let today = snapshot.today {
                    Text("Max \(WeatherSnapshot.degrees(today.high))   Min \(WeatherSnapshot.degrees(today.low))")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.top, 3)
                }
            } else if case .failed(let message) = weather.status {
                Text("--°").font(.system(size: 112, weight: .thin)).padding(.vertical, -12)
                Text(message).font(.system(size: 15)).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                Button("Riprova") { Task { await weather.refresh(force: true) } }.buttonStyle(.glass).padding(.top, 8)
            } else {
                Text("--°").font(.system(size: 112, weight: .thin)).padding(.vertical, -12).redacted(reason: .placeholder)
                ProgressView().controlSize(.small).padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 2)
        .accessibilityElement(children: .combine)
    }
}

/// Città del meteo: nome o posizione del Mac.
struct CityPicker: View {
    let weather: WeatherModel
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meteo della Home").font(.headline)
            TextField("Città", text: $draft, prompt: Text("Roma"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(apply)
            Toggle("Usa la posizione del Mac", isOn: Binding(get: { weather.usesLocation }, set: { weather.usesLocation = $0 }))
                .toggleStyle(.switch)
            Text("Le previsioni arrivano da Open-Meteo, che riceve solo il nome della città o la posizione arrotondata a circa 1 km.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                Button("Usa") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 310)
        .onAppear { draft = weather.city }
    }

    private func apply() {
        let city = draft.trimmingCharacters(in: .whitespaces)
        guard !city.isEmpty else { return }
        weather.city = city
        dismiss()
    }
}

/// Le prossime ore, come nella scheda oraria di Meteo.
struct HourlyStrip: View {
    let hours: [WeatherHour]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                    VStack(spacing: 7) {
                        Text(index == 0 ? String(localized: "time.now", defaultValue: "Ora") : String(format: "%02d", Calendar.current.component(.hour, from: hour.date)))
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: hour.condition.symbol(isDay: hour.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 20))
                            .frame(height: 24)
                        Text(hour.precipitationChance >= 20 ? "\(hour.precipitationChance)%" : " ")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(red: 0.45, green: 0.8, blue: 1))
                        Text(WeatherSnapshot.degrees(hour.temperature)).font(.system(size: 16, weight: .semibold))
                    }
                    .frame(width: 56)
                }
            }
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Oggi

/// La giornata come un quadrante di 24 ore: gli impegni sono archi colorati, il punto bianco è adesso.
struct DayRing: View {
    let events: [EventItem]
    let now: Date
    var size: CGFloat = 220
    @State private var drawn = false
    private let line: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.13), lineWidth: line)
            ForEach(0..<24, id: \.self) { hour in
                Capsule()
                    .fill(.white.opacity(hour % 6 == 0 ? 0.55 : 0.2))
                    .frame(width: 2, height: hour % 6 == 0 ? 9 : 4)
                    .offset(y: -size / 2 - line / 2 - 10)
                    .rotationEffect(.degrees(Double(hour) * 15))
            }
            // Le ore sulla ghiera, fuori dall'anello: dentro c'è il prossimo impegno.
            ForEach([0, 6, 12, 18], id: \.self) { hour in
                let angle = Double(hour) / 24 * 2 * .pi
                let radius = size / 2 + line / 2 + 26
                Text("\(hour)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .offset(x: sin(angle) * radius, y: -cos(angle) * radius)
            }
            ForEach(events) { event in
                let range = fraction(event)
                Circle()
                    .trim(from: range.lowerBound, to: drawn ? range.upperBound : range.lowerBound)
                    .stroke(Color(event.color).gradient, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Color(event.color).opacity(0.55), radius: 8)
            }
            Circle()
                .fill(.white)
                .frame(width: 11, height: 11)
                .shadow(color: .white.opacity(0.9), radius: 6)
                .offset(y: -size / 2)
                .rotationEffect(.degrees(minutes(now) / 1440 * 360))
            center
                .frame(width: size - line * 2 - 44)
        }
        .frame(width: size, height: size)
        .padding(line / 2 + 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onAppear {
            withAnimation(.spring(duration: 1.4, bounce: 0.1).delay(0.35)) { drawn = true }
        }
    }

    private var accessibilityText: String {
        if let current = events.first(where: { $0.start <= now && $0.end > now }) { return String(localized: "Adesso: \(current.title), fino alle \(clock(current.end))") }
        if let next = events.first(where: { $0.start > now }) { return String(localized: "Prossimo impegno alle \(clock(next.start)): \(next.title)") }
        return events.isEmpty ? String(localized: "Oggi nessun impegno") : String(localized: "Impegni di oggi conclusi")
    }

    @ViewBuilder
    private var center: some View {
        let current = events.first { $0.start <= now && $0.end > now }
        let next = events.first { $0.start > now }
        VStack(spacing: 2) {
            if let current {
                Text("ADESSO").font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(.white.opacity(0.7))
                Text("fino alle \(clock(current.end))").font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(current.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            } else if let next {
                Text("PROSSIMO").font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(.white.opacity(0.7))
                Text(clock(next.start)).font(.system(size: 42, weight: .bold, design: .rounded)).contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.55)
                Text(next.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            } else {
                Text("OGGI").font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(.white.opacity(0.7))
                Text(events.isEmpty ? String(localized: "Libera") : String(localized: "Finito")).font(.system(size: 36, weight: .bold, design: .rounded))
                Text(events.isEmpty ? String(localized: "nessun impegno") : "\(events.count) \(events.count == 1 ? String(localized: "impegno concluso") : String(localized: "impegni conclusi"))")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
    }

    private func minutes(_ date: Date) -> Double {
        let start = Calendar.current.startOfDay(for: now)
        return min(1440, max(0, date.timeIntervalSince(start) / 60))
    }

    private func fraction(_ event: EventItem) -> ClosedRange<Double> {
        let start = minutes(event.start) / 1440
        let end = max(start + 0.004, minutes(event.end) / 1440)
        return start...min(1, end)
    }

    private func clock(_ date: Date) -> String { date.formatted(.dateTime.hour().minute().locale(Dates.locale)) }
}

/// Minuti occupati per ora, dalle 7 alle 22: barre sottili come nei grafici di Salute.
struct BusyChart: View {
    let events: [EventItem]
    let now: Date

    var body: some View {
        let hours = Array(7...22)
        let current = Calendar.current.component(.hour, from: now)
        Chart {
            ForEach(hours, id: \.self) { hour in
                BarMark(x: .value(String(localized: "Ora"), hour), yStart: .value(String(localized: "Base"), 0), yEnd: .value(String(localized: "Pieno"), 60), width: .fixed(9))
                    .foregroundStyle(.white.opacity(0.08))
                    .clipShape(Capsule())
                BarMark(x: .value(String(localized: "Ora"), hour), yStart: .value(String(localized: "Base"), 0), yEnd: .value(String(localized: "Occupato"), max(busy(hour), 0)), width: .fixed(9))
                    .foregroundStyle(hour < current ? AnyShapeStyle(Color.red.opacity(0.5)) : AnyShapeStyle(Color.red.gradient))
                    .clipShape(Capsule())
            }
        }
        .chartYScale(domain: 0...60)
        .chartXScale(domain: 6.5...22.5)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [8, 12, 16, 20]) { value in
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            }
        }
        .frame(height: 92)
    }

    /// Minuti coperti da almeno un impegno nell'ora data.
    private func busy(_ hour: Int) -> Double {
        let calendar = Calendar.current
        guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) else { return 0 }
        let end = start.addingTimeInterval(3600)
        var covered = Set<Int>()
        for event in events where event.end > start && event.start < end {
            let from = Int(max(0, event.start.timeIntervalSince(start)) / 60)
            let to = Int(min(3600, event.end.timeIntervalSince(start)) / 60)
            if to > from { covered.formUnion(from..<to) }
        }
        return Double(covered.count)
    }
}

// MARK: - Da fare

/// Anello dei promemoria di oggi: si chiude man mano che li completi.
struct TodoRing: View {
    let done: Int
    let open: Int
    let overdue: Int
    var size: CGFloat = 214
    @State private var drawn = false
    private let line: CGFloat = 26

    private var progress: Double {
        let total = done + open
        return total == 0 ? 1 : Double(done) / Double(total)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.orange.opacity(0.2), lineWidth: line)
            Circle()
                .trim(from: 0, to: drawn ? max(0.002, progress) : 0)
                .stroke(AngularGradient(colors: [Color(hex: 0xFF9F0A), Color(hex: 0xFFD60A), Color(hex: 0xFF9F0A)], center: .center),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .orange.opacity(0.55), radius: 10)
            VStack(spacing: 1) {
                if open == 0 {
                    Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).symbolEffect(.drawOn, isActive: !drawn)
                    Text(done == 1 ? String(localized: "1 fatto oggi") : done > 1 ? String(localized: "\(done) fatti oggi") : String(localized: "niente in scadenza"))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                } else {
                    Text("\(open)").font(.system(size: 58, weight: .bold, design: .rounded)).contentTransition(.numericText())
                    Text(open == 1 ? String(localized: "da fare") : String(localized: "da fare")).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    if done > 0 { Text(done == 1 ? String(localized: "1 fatto") : String(localized: "\(done) fatti")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)) }
                }
                if overdue > 0 {
                    Text(overdue == 1 ? String(localized: "1 scaduto") : String(localized: "\(overdue) scaduti"))
                        .font(.system(size: 11.5, weight: .bold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.red.gradient, in: Capsule())
                        .padding(.top, 6)
                }
            }
            .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .padding(line / 2 + 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(open) promemoria da fare oggi, \(done) completati\(overdue > 0 ? String(localized: ", \(overdue) scaduti") : "")")
        .onAppear {
            withAnimation(.spring(duration: 1.3, bounce: 0.12).delay(0.3)) { drawn = true }
        }
    }
}

/// Promemoria in scadenza nei prossimi sette giorni.
struct WeekBars: View {
    let days: [(date: Date, count: Int)]

    var body: some View {
        let top = max(3, days.map(\.count).max() ?? 0)
        Chart {
            ForEach(days, id: \.date) { day in
                BarMark(x: .value(String(localized: "Giorno"), day.date, unit: .day), yStart: .value(String(localized: "Base"), 0), yEnd: .value(String(localized: "Max"), top), width: .fixed(16))
                    .foregroundStyle(.white.opacity(0.08))
                    .clipShape(Capsule())
                BarMark(x: .value(String(localized: "Giorno"), day.date, unit: .day), yStart: .value(String(localized: "Base"), 0), yEnd: .value(String(localized: "Promemoria"), day.count), width: .fixed(16))
                    .foregroundStyle(Color.orange.gradient)
                    .clipShape(Capsule())
            }
        }
        .chartYScale(domain: 0...top)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Calendar.current.isDateInToday(date) ? String(localized: "Oggi") : date.formatted(.dateTime.weekday(.abbreviated).locale(Dates.locale)).capitalized)
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 92)
    }
}

// MARK: - Agenti

/// Gli agenti attorno a Siri AI+: il bordo che gira è un agente al lavoro, il numero arancione le azioni da approvare.
struct AgentsConstellation: View {
    let agents: [AgentSpec]
    let running: Set<UUID>
    let pending: [UUID: Int]
    let orb: OrbState

    var body: some View {
        let shown = Array(agents.prefix(6))
        ZStack {
            Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1).frame(width: 244, height: 244)
            Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1).frame(width: 164, height: 164)
            OrbView(state: orb, size: 88)
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, agent in
                let angle = Double(index) / Double(max(1, shown.count)) * 2 * .pi - .pi / 2
                AgentBubble(agent: agent, running: running.contains(agent.id), pending: pending[agent.id] ?? 0)
                    .offset(x: cos(angle) * 122, y: sin(angle) * 122)
            }
        }
        .frame(width: 300, height: 300)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agents.isEmpty ? String(localized: "Nessun Genius") : String(localized: "Genius: ") + agents.map(\.displayName).joined(separator: ", "))
    }
}

private struct AgentBubble: View {
    let agent: AgentSpec
    let running: Bool
    let pending: Int
    @State private var spin = false

    var body: some View {
        AgentAvatar(agent: agent, size: 50)
            .padding(4)
            .glassEffect(.regular, in: .circle)
            .overlay {
                if running {
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(AngularGradient(colors: [agent.tint.opacity(0), agent.tint, .white], center: .center),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .padding(-3)
                        .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { spin = true } }
                }
            }
            .overlay(alignment: .topTrailing) {
                if pending > 0 {
                    Text("\(pending)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.orange, in: Circle())
                        .offset(x: 4, y: -4)
                }
            }
            .opacity(agent.active ? 1 : 0.55)
            .help(agent.displayName)
    }
}

/// Esecuzioni degli agenti negli ultimi sette giorni, colorate per esito.
struct RunsChart: View {
    let runs: [(date: Date, outcome: AgentRun.Outcome)]

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        Chart {
            ForEach(days, id: \.self) { day in
                BarMark(x: .value(String(localized: "Giorno"), day, unit: .day), yStart: .value(String(localized: "Base"), 0), yEnd: .value(String(localized: "Max"), top), width: .fixed(16))
                    .foregroundStyle(.white.opacity(0.08))
                    .clipShape(Capsule())
            }
            ForEach(grouped(days), id: \.key) { item in
                BarMark(x: .value(String(localized: "Giorno"), item.day, unit: .day), y: .value(String(localized: "Esecuzioni"), item.count), width: .fixed(16))
                    .foregroundStyle(by: .value(String(localized: "Esito"), item.label))
                    .clipShape(Capsule())
            }
        }
        .chartForegroundStyleScale([String(localized: "Completate"): Color.purple, String(localized: "Da approvare"): Color.orange,
                                    String(localized: "Con problemi"): Color.red])
        .chartLegend(.hidden)
        .chartYScale(domain: 0...top)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Calendar.current.isDateInToday(date) ? String(localized: "Oggi") : date.formatted(.dateTime.weekday(.abbreviated).locale(Dates.locale)).capitalized)
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 92)
    }

    private var top: Int {
        let calendar = Calendar.current
        let counts = Dictionary(grouping: runs) { calendar.startOfDay(for: $0.date) }.mapValues(\.count)
        return max(3, counts.values.max() ?? 0)
    }

    private struct Item { let key: String; let day: Date; let label: String; let count: Int }

    private func grouped(_ days: [Date]) -> [Item] {
        let calendar = Calendar.current
        var items: [Item] = []
        for day in days {
            let today = runs.filter { calendar.isDate($0.date, inSameDayAs: day) }
            let groups: [(String, Int)] = [
                (String(localized: "Completate"), today.filter { $0.outcome == .completata }.count),
                (String(localized: "Da approvare"), today.filter { $0.outcome == .daApprovare }.count),
                (String(localized: "Con problemi"), today.filter { [.errore, .interrotta].contains($0.outcome) }.count),
            ]
            for (label, count) in groups where count > 0 {
                items.append(Item(key: "\(day.timeIntervalSince1970)-\(label)", day: day, label: label, count: count))
            }
        }
        return items
    }
}

// MARK: - Impaginazione a capo

/// Dispone le viste in righe che vanno a capo (i suggerimenti a pillola).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
