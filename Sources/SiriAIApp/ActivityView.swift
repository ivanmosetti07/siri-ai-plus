import SiriCore
import SwiftUI

// MARK: - 12 Attività e privacy

struct ActivityView: View {
    @Environment(AppState.self) private var state
    @State private var tab = 0
    @State private var confirmClear = false
    var body: some View {
        GlassPage(maxWidth: 820) {
            PageHeader(eyebrow: "Tutto sotto controllo", title: "Attività e privacy",
                       subtitle: "Ogni cosa che Siri AI+ ha fatto per te e cosa può vedere: i dati salvati restano sul Mac; le risposte possono usare Private Cloud Compute di Apple.")
            GlassPills(items: [
                GlassPill(id: "0", title: "Attività recenti", value: "\(state.activity.count) azioni", symbol: "clock.arrow.circlepath", colors: Hue.blue),
                GlassPill(id: "1", title: "Privacy e permessi", value: "\(SourceKind.allCases.filter { state.isEnabled($0) }.count) app collegate", symbol: "hand.raised.fill", colors: Hue.indigo),
            ], selection: Binding(get: { String(tab) }, set: { tab = Int($0) ?? 0 }))
            Group {
                switch tab {
                case 0: activity
                default: privacy
                }
            }
            .id(tab)
            .transition(.blurReplace)
        }
        .confirmationDialog("Cancellare il registro delle attività?", isPresented: $confirmClear) {
            Button("Cancella registro", role: .destructive) { state.clearActivity() }
        } message: {
            Text("Le azioni già eseguite in Calendario e Promemoria non vengono annullate.")
        }
    }

    private var groups: [(day: Date, entries: [ActivityEntry])] {
        let grouped = Dictionary(grouping: state.activity) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { $0.date > $1.date }) }
    }

    @ViewBuilder private var activity: some View {
        if state.activity.isEmpty {
            GlassEmptyState(symbol: "list.bullet.rectangle.fill", title: "Nessuna attività per ora",
                            message: "Qui trovi ogni evento creato, promemoria aggiunto, email preparata e file esportato.", colors: Hue.blue)
        } else {
            ForEach(groups, id: \.day) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(dayTitle(group.day)).font(DS.Fonts.captionStrong).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, 50) }
                            ActivityRow(entry: entry)
                        }
                    }
                    .glassCard(radius: 24)
                }
            }
            Button("Cancella registro…", role: .destructive) { confirmClear = true }
                .buttonStyle(.link)
                .font(DS.Fonts.caption)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Elaborazione Apple Intelligence").font(DS.Fonts.bodyStrong)
                    Text("La scelta delle azioni avviene sul Mac. Se Private Cloud Compute è autorizzato e disponibile, Apple elabora la risposta sui propri server con i dati necessari alla richiesta; altrimenti la risposta viene generata sul Mac. Il registro delle attività resta in Libreria › Application Support › Siri AI+.")
                        .font(DS.Fonts.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Space.lg)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text("Fonti e permessi").font(DS.Fonts.captionStrong).foregroundStyle(.secondary)
                SourcesList()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Regole di sicurezza").font(DS.Fonts.captionStrong).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    Rule(symbol: "eye", text: "Le letture mostrano subito il risultato.")
                    Rule(symbol: "hand.raised", text: "Creazioni, modifiche ed eliminazioni partono solo dopo la tua conferma.")
                    Rule(symbol: "paperplane", text: "Le email si aprono in Mail: l'invio lo fai tu.")
                    Rule(symbol: "person.2", text: "Condividere un file passa sempre dal selettore di sistema.")
                }
                .padding(DS.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(radius: 24)
            }

            Button("Rivedi la presentazione iniziale") { state.restartOnboarding() }
                .buttonStyle(.link)
                .font(DS.Fonts.caption)
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Oggi" }
        if Calendar.current.isDateInYesterday(day) { return "Ieri" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Dates.locale)).capitalized
    }

    struct Rule: View {
        let symbol: String
        let text: String
        var body: some View {
            Label { Text(text).font(DS.Fonts.body) } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
        }
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(DS.Fonts.body)
                Text(entry.detail).font(DS.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(status: entry.status)
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(DS.Fonts.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var icon: some View {
        let parts = entry.icon.split(separator: ":").map(String.init)
        if parts.count == 2, parts[0] == "source", let source = SourceKind(rawValue: parts[1]) {
            Tile(source, size: 24)
        } else if parts.count == 2, parts[0] == "artifact", let kind = ArtifactKind(rawValue: parts[1]) {
            Tile(kind, size: 24)
        } else {
            Image(systemName: entry.icon).frame(width: 24)
        }
    }
}

// MARK: - Automazioni

struct AutomationsView: View {
    private let templates: [(symbol: String, title: String, detail: String)] = [
        ("sun.horizon", "Brief del mattino", "Ogni giorno feriale alle 8:00: agenda della giornata e promemoria in scadenza."),
        ("calendar.badge.clock", "Preparazione riunioni", "10 minuti prima di ogni riunione: riepilogo e documenti collegati."),
        ("checkmark.seal", "Revisione del venerdì", "Venerdì alle 17:00: cosa hai completato e cosa resta per la prossima settimana."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automazioni").font(DS.Fonts.title)
                    Text("Richieste che Siri AI+ eseguirà da sola, a orari o eventi precisi. Anche qui, ogni modifica ai dati chiederà conferma.")
                        .font(DS.Fonts.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(Array(templates.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider().padding(.leading, 52) }
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: item.symbol).font(.system(size: 16)).foregroundStyle(.tint).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(DS.Fonts.bodyStrong)
                                Text(item.detail).font(DS.Fonts.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("In arrivo").font(DS.Fonts.caption).foregroundStyle(.tertiary)
                        }
                        .padding(14)
                    }
                }
                .glassCard(radius: 24)
            }
            .frame(maxWidth: DS.readingWidth, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Memoria generale

struct MemorySettings: View {
    @Environment(AppState.self) private var state
    @State private var newFact = ""
    @State private var facts = [MemoryFact]()
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memoria di Siri AI+").font(DS.Fonts.bodyStrong)
                    Text("Fatti che Siri AI+ usa per rispondere meglio: quelli che le chiedi di ricordare, quelli emersi nelle conversazioni compattate e un riassunto quotidiano delle attività. Restano sul Mac.")
                        .font(DS.Fonts.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Usa la memoria", isOn: Binding(get: { MemoryStore.shared.enabled }, set: { MemoryStore.shared.enabled = $0; state.memoryRevision += 1 }))
                    .toggleStyle(.switch)
            }
            HStack {
                TextField("Aggiungi un fatto da ricordare", text: $newFact).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Aggiungi", action: add).disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if facts.isEmpty {
                Text("Nessun ricordo per ora. Prova: «Ricordati che preferisco le riunioni al mattino».")
                    .font(DS.Fonts.body).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                        if index > 0 { Divider() }
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fact.text).font(DS.Fonts.body).textSelection(.enabled)
                                Text("\(fact.source.capitalized) · \(fact.date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { MemoryStore.shared.remove(fact.id); state.memoryRevision += 1 } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
                .glassCard(radius: 24)
                Button("Cancella tutta la memoria…", role: .destructive) { confirmClear = true }
                    .buttonStyle(.link).font(DS.Fonts.caption)
            }
        }
        .task(id: state.memoryRevision) { facts = MemoryStore.shared.facts }
        .confirmationDialog("Cancellare tutta la memoria di Siri AI+?", isPresented: $confirmClear) {
            Button("Cancella memoria", role: .destructive) { MemoryStore.shared.clear(); state.memoryRevision += 1 }
        }
    }

    private func add() {
        let text = newFact.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        MemoryStore.shared.add(text, source: "utente")
        newFact = ""
        state.memoryRevision += 1
    }
}
