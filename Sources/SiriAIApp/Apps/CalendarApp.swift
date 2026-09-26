import AppKit
import SiriCore
import SwiftUI

// MARK: - Calendario

struct CalendarAppView: View {
    @Environment(AppState.self) private var state

    enum Mode: String, CaseIterable, Identifiable {
        case day = "Giorno", week = "Settimana", month = "Mese"
        var id: String { rawValue }
    }

    @AppStorage("calendario.vista") private var savedMode = Mode.week.rawValue
    @State private var modeRaw = AppTesting.value(after: "--calendar-mode") ?? UserDefaults.standard.string(forKey: "calendario.vista") ?? Mode.week.rawValue
    @State private var anchor = AppTesting.value(after: "--calendar-date").flatMap { try? Date($0, strategy: .iso8601.year().month().day()) } ?? Date.now
    @State private var calendars = [CalendarInfo]()
    @State private var hiddenIDs = Set<String>()
    @State private var events = [CalendarEvent]()
    @State private var selectedID: String?
    @State private var editing: EventDetail?
    @State private var search = ""
    @State private var results = [CalendarEvent]()
    @State private var loadedHidden = false

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .week }
    private var cal: Calendar { Calendar.current }
    private var visibleIDs: Set<String> { Set(calendars.map(\.id)).subtracting(hiddenIDs) }
    private var hiddenKey: String { "calendario.nascosti.\(state.space.rawValue)" }

    /// Giorni mostrati: uno, la settimana o le settimane del mese.
    private var range: (start: Date, end: Date) {
        switch mode {
        case .day:
            let start = cal.startOfDay(for: anchor)
            return (start, cal.date(byAdding: .day, value: 1, to: start)!)
        case .week:
            let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? cal.startOfDay(for: anchor)
            return (start, cal.date(byAdding: .day, value: 7, to: start)!)
        case .month:
            let month = cal.dateInterval(of: .month, for: anchor)!
            let start = cal.dateInterval(of: .weekOfYear, for: month.start)?.start ?? month.start
            return (start, cal.date(byAdding: .day, value: 42, to: start)!)
        }
    }

    private var title: String {
        switch mode {
        case .day: anchor.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Dates.locale)).capitalized
        case .week, .month: anchor.formatted(.dateTime.month(.wide).year().locale(Dates.locale)).capitalized
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(source: .calendar, title: String(localized: "Calendario"), subtitle: title, search: $search, searchPrompt: String(localized: "Cerca eventi"),
                      onSearch: runSearch, onRefresh: reload) {
                Picker("Vista", selection: $modeRaw) {
                    ForEach(Mode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("Oggi") { withAnimation(DS.Motion.standard) { anchor = .now } }
                ControlGroup {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }.iconHelp(String(localized: "Precedente"))
                    Button { step(1) } label: { Image(systemName: "chevron.right") }.iconHelp(String(localized: "Successivo"))
                }
                .fixedSize()
                AppIconButton(symbol: "plus", help: String(localized: "Nuovo evento"), prominent: true) { newEvent(at: nil) }
                    .disabled(!state.canWrite(.calendar))
            }
            Divider()
            AppSplit(sourcesWidth: 214, inspectorWidth: 310, minimumMain: 470, showInspector: editing != nil) {
                CalendarSidebar(anchor: $anchor, calendars: calendars, hiddenIDs: $hiddenIDs)
            } main: {
                Group {
                    if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                        CalendarSearchResults(results: results, selectedID: selectedID) { open($0) }
                    } else {
                        switch mode {
                        case .day, .week:
                            TimeGrid(days: days, events: events, selectedID: selectedID, canWrite: state.canWrite(.calendar),
                                     onSelect: open, onCreate: { newEvent(at: $0) }, onMove: move)
                        case .month:
                            MonthGrid(anchor: anchor, start: range.start, events: events, selectedID: selectedID,
                                      onSelect: open, onOpenDay: { day in anchor = day; modeRaw = Mode.day.rawValue },
                                      onCreate: { newEvent(at: cal.date(bySettingHour: 9, minute: 0, second: 0, of: $0)) })
                        }
                    }
                }
            } inspector: {
                EventInspector(detail: $editing, calendars: calendars.filter(\.writable), allCalendars: calendars,
                               canWrite: state.canWrite(.calendar),
                               onSaved: { identifier, start in selectAfterSave(identifier, start) },
                               onDeleted: { editing = nil; selectedID = nil; reload() },
                               onClose: { editing = nil; selectedID = nil })
            }
        }
        .task(id: "\(range.start.timeIntervalSince1970)-\(modeRaw)-\(state.storeRevision)-\(hiddenIDs.sorted().joined())") { reload() }
        .onAppear(perform: loadHidden)
        .onChange(of: hiddenIDs) { _, value in
            if loadedHidden, !AppTesting.ephemeral { UserDefaults.standard.set(Array(value), forKey: hiddenKey) }
        }
        .onChange(of: search) { _, value in if value.isEmpty { results = [] } }
        .onChange(of: modeRaw) { _, value in if !AppTesting.ephemeral { savedMode = value } }
        // Siri AI+ vede l'evento selezionato («spostalo alle 16», «scrivi ai partecipanti») o i giorni mostrati.
        .onChange(of: selectedID, initial: true) { _, _ in publishScreen() }
        .onChange(of: events) { _, _ in publishScreen() }
        .onChange(of: editing) { _, _ in publishScreen() }
    }

    private func publishScreen() {
        if let id = selectedID, let event = events.first(where: { $0.id == id }) {
            let detail = editing.flatMap { $0.identifier == event.identifier ? $0 : nil }
            let extra = [detail?.notes ?? "", detail?.url ?? "",
                         (detail?.attendees ?? []).isEmpty ? "" : String(localized: "Partecipanti: ") + (detail?.attendees ?? []).joined(separator: ", "),
                         detail?.organizer.map { String(localized: "Organizzatore: \($0)") } ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            state.publish(.event(event, notes: extra), for: .app(.calendar))
        } else {
            state.publish(.calendar(range: screenRange, events: events), for: .app(.calendar))
        }
    }

    /// I giorni mostrati, a parole («settimana dal 21 al 27 settembre»).
    private var screenRange: String {
        switch mode {
        case .day: String(localized: "giorno ") + anchor.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Dates.locale))
        case .week:
            String(localized: "settimana dal ") + range.start.formatted(.dateTime.day().month(.wide).locale(Dates.locale)) + String(localized: " al ")
                + range.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.wide).locale(Dates.locale))
        case .month: String(localized: "mese di ") + anchor.formatted(.dateTime.month(.wide).year().locale(Dates.locale))
        }
    }

    private var days: [Date] {
        let count = mode == .day ? 1 : 7
        return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: range.start) }
    }

    private func loadHidden() {
        calendars = CalendarStore.calendars()
        if let saved = UserDefaults.standard.stringArray(forKey: hiddenKey) {
            hiddenIDs = Set(saved)
        } else if let names = SpaceScope.current.calendars {
            // Prima volta in questo spazio: si vedono i suoi calendari.
            hiddenIDs = Set(calendars.filter { !names.contains($0.title) }.map(\.id))
        }
        loadedHidden = true
    }

    private func reload() {
        if calendars.isEmpty { calendars = CalendarStore.calendars() }
        events = CalendarStore.events(from: range.start, to: range.end, calendarIDs: visibleIDs)
        if !search.isEmpty { runSearch() }
        if AppTesting.selectFirst, editing == nil, let first = events.first(where: { !$0.isAllDay }) ?? events.first { open(first) }
        // L'evento aperto può essere stato cambiato altrove (in Calendario o dalla chat).
        if let current = editing, !current.isNew, CalendarStore.detail(identifier: current.identifier, start: current.occurrence) == nil {
            editing = nil
            selectedID = nil
        }
    }

    private func runSearch() {
        results = CalendarStore.search(search, calendarIDs: visibleIDs)
    }

    private func step(_ direction: Int) {
        let component: Calendar.Component = mode == .day ? .day : mode == .week ? .weekOfYear : .month
        withAnimation(DS.Motion.standard) { anchor = cal.date(byAdding: component, value: direction, to: anchor) ?? anchor }
    }

    private func open(_ event: CalendarEvent) {
        selectedID = event.id
        editing = CalendarStore.detail(identifier: event.identifier, start: event.start)
        if !search.isEmpty, !(range.start...range.end).contains(event.start) { anchor = event.start }
    }

    private func newEvent(at start: Date?) {
        guard state.canWrite(.calendar) else { return }
        let base = start ?? {
            let reference = cal.isDate(anchor, inSameDayAs: .now) ? Date.now : cal.date(bySettingHour: 9, minute: 0, second: 0, of: anchor)!
            return cal.nextDate(after: reference, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? reference
        }()
        selectedID = nil
        editing = EventDetail(start: base, end: base.addingTimeInterval(3600), calendarID: CalendarStore.defaultCalendarID)
    }

    private func selectAfterSave(_ identifier: String, _ start: Date) {
        reload()
        if let event = events.first(where: { $0.identifier == identifier && abs($0.start.timeIntervalSince(start)) < 1 }) {
            selectedID = event.id
        }
        editing = CalendarStore.detail(identifier: identifier, start: start)
    }

    private func move(_ event: CalendarEvent, to start: Date, end: Date) {
        do {
            try CalendarStore.move(identifier: event.identifier, start: event.start, to: start, end: end)
            state.appDone(.calendar, String(localized: "Evento spostato"), detail: "\(event.title) · \(Dates.friendly(start))")
            reload()
            if editing?.identifier == event.identifier { editing = CalendarStore.detail(identifier: event.identifier, start: start) }
        } catch {
            state.appFailed(.calendar, String(localized: "Evento non spostato"), error)
            reload()
        }
    }
}

// MARK: - Colonna sinistra: mese e calendari

private struct CalendarSidebar: View {
    @Binding var anchor: Date
    let calendars: [CalendarInfo]
    @Binding var hiddenIDs: Set<String>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MiniMonth(anchor: $anchor)
                let accounts = Array(Set(calendars.map(\.account))).sorted()
                ForEach(accounts, id: \.self) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(account.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(calendars.filter { $0.account == account }) { calendar in
                            Toggle(isOn: Binding(get: { !hiddenIDs.contains(calendar.id) },
                                                 set: { if $0 { hiddenIDs.remove(calendar.id) } else { hiddenIDs.insert(calendar.id) } })) {
                                HStack(spacing: 6) {
                                    Text(calendar.title).lineLimit(1)
                                    if !calendar.writable { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary) }
                                }
                            }
                            .toggleStyle(ColorCheckbox(color: Color(calendar.color)))
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

/// Casella colorata come in Calendario.
private struct ColorCheckbox: ToggleStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isOn ? color : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(color, lineWidth: 1.5))
                    .overlay {
                        if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                    }
                    .frame(width: 15, height: 15)
                configuration.label.font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Mese piccolo per saltare a un giorno.
struct MiniMonth: View {
    @Binding var anchor: Date
    @State private var shown = Date.now
    private var cal: Calendar { Calendar.current }

    var body: some View {
        let month = cal.dateInterval(of: .month, for: shown)!
        let first = cal.dateInterval(of: .weekOfYear, for: month.start)?.start ?? month.start
        let days = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
        VStack(spacing: 6) {
            HStack {
                Text(shown.formatted(.dateTime.month(.wide).year().locale(Dates.locale)).capitalized).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { shown = cal.date(byAdding: .month, value: -1, to: shown)! } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).iconHelp(String(localized: "Mese precedente"))
                Button { shown = cal.date(byAdding: .month, value: 1, to: shown)! } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).iconHelp(String(localized: "Mese successivo"))
            }
            let symbols = (0..<7).map { cal.shortStandaloneWeekdaySymbols[($0 + cal.firstWeekday - 1) % 7].prefix(1).uppercased() }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                ForEach(days, id: \.self) { day in
                    let inMonth = cal.isDate(day, equalTo: shown, toGranularity: .month)
                    let today = cal.isDateInToday(day)
                    let selected = cal.isDate(day, inSameDayAs: anchor)
                    Button { anchor = day } label: {
                        Text(day.formatted(.dateTime.day()))
                            .font(.system(size: 11.5, weight: today || selected ? .bold : .regular))
                            .foregroundStyle(today ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background {
                                if today { Circle().fill(Color.red) } else if selected { Circle().fill(Color.primary.opacity(0.12)) }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { shown = anchor }
        .onChange(of: anchor) { _, value in
            if !cal.isDate(value, equalTo: shown, toGranularity: .month) { shown = value }
        }
    }
}

// MARK: - Giorno e settimana

private struct TimeGrid: View {
    let days: [Date]
    let events: [CalendarEvent]
    let selectedID: String?
    let canWrite: Bool
    let onSelect: (CalendarEvent) -> Void
    let onCreate: (Date) -> Void
    let onMove: (CalendarEvent, Date, Date) -> Void

    static let hourHeight: CGFloat = 50
    static let gutter: CGFloat = 54
    private var cal: Calendar { Calendar.current }

    /// Si apre sulla mattina, o un paio d'ore prima di adesso se oggi è in vista.
    static func startHour(for days: [Date]) -> Int {
        guard days.contains(where: Calendar.current.isDateInToday) else { return 7 }
        return min(max(7, Calendar.current.component(.hour, from: .now) - 2), 15)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            allDayRow
            Divider()
            ScrollView {
                timeline
                    .frame(height: Self.hourHeight * 24)
                    // Si apre sull'orario giusto (mattina, o poco prima di adesso se oggi è in vista).
                    .background(InitialScroll(y: CGFloat(Self.startHour(for: days)) * Self.hourHeight, key: days.first))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let today = cal.isDateInToday(day)
                HStack(spacing: 5) {
                    Text(day.formatted(.dateTime.weekday(days.count == 1 ? .wide : .abbreviated).locale(Dates.locale)).capitalized)
                        .foregroundStyle(.secondary)
                    Text(day.formatted(.dateTime.day()))
                        .fontWeight(.semibold)
                        .foregroundStyle(today ? .white : .primary)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(today ? Color.red : .clear, in: Circle())
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var allDayRow: some View {
        let allDay = events.filter(\.isAllDay)
        if !allDay.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Text("tutto il\ngiorno").font(.system(size: 9.5)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .frame(width: Self.gutter - 6, alignment: .trailing).padding(.trailing, 6)
                ForEach(days, id: \.self) { day in
                    let next = cal.date(byAdding: .day, value: 1, to: day)!
                    VStack(spacing: 2) {
                        ForEach(allDay.filter { $0.start < next && $0.end > day }) { event in
                            EventChip(event: event, selected: event.id == selectedID) { onSelect(event) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.bottom, 4)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var timeline: some View {
        GeometryReader { geo in
            let columnWidth = (geo.size.width - Self.gutter) / CGFloat(days.count)
            ZStack(alignment: .topLeading) {
                ForEach(0..<24, id: \.self) { hour in
                    HStack(alignment: .top, spacing: 6) {
                        Text(hour == 0 ? "" : String(format: "%02d:00", hour))
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: Self.gutter - 6, alignment: .trailing)
                            .offset(y: -6)
                        Rectangle().fill(Color.hairline).frame(height: 0.5)
                    }
                    .offset(y: CGFloat(hour) * Self.hourHeight)
                }
                ForEach(0..<days.count, id: \.self) { index in
                    Rectangle().fill(Color.hairline).frame(width: 0.5)
                        .offset(x: Self.gutter + CGFloat(index) * columnWidth)
                }
                // Doppio clic su uno spazio vuoto: nuovo evento a quell'ora (arrotondata al quarto d'ora).
                Color.clear
                    .contentShape(Rectangle())
                    .padding(.leading, Self.gutter)
                    .gesture(SpatialTapGesture(count: 2).onEnded { value in
                        guard canWrite else { return }
                        let column = min(days.count - 1, max(0, Int(value.location.x / columnWidth)))
                        let minutes = Int((value.location.y / Self.hourHeight * 60 / 15).rounded(.down)) * 15
                        if let start = cal.date(byAdding: .minute, value: minutes, to: cal.startOfDay(for: days[column])) { onCreate(start) }
                    })
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    ForEach(layout(for: day), id: \.event.id) { item in
                        let width = (columnWidth - 4) / CGFloat(item.lanes)
                        TimedEventBlock(event: item.event, selected: item.event.id == selectedID, canDrag: canWrite && item.event.writable,
                                        hourHeight: Self.hourHeight, columnWidth: columnWidth,
                                        onSelect: { onSelect(item.event) },
                                        onMove: { dayShift, minutes, resize in
                                            let start = cal.date(byAdding: .day, value: dayShift, to: item.event.start)!.addingTimeInterval(resize ? 0 : Double(minutes * 60))
                                            let duration = item.event.end.timeIntervalSince(item.event.start)
                                            let end = resize ? max(start.addingTimeInterval(900), item.event.end.addingTimeInterval(Double(minutes * 60))) : start.addingTimeInterval(duration)
                                            onMove(item.event, start, end)
                                        })
                            .frame(width: width - 2, height: max(22, item.height))
                            .offset(x: Self.gutter + CGFloat(index) * columnWidth + 2 + CGFloat(item.lane) * width, y: item.top)
                    }
                }
                if let nowIndex = days.firstIndex(where: cal.isDateInToday) {
                    let minutes = Date.now.timeIntervalSince(cal.startOfDay(for: .now)) / 60
                    HStack(spacing: 0) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Rectangle().fill(.red).frame(width: max(0, columnWidth - 8), height: 1.2)
                    }
                    .offset(x: Self.gutter + CGFloat(nowIndex) * columnWidth - 4, y: CGFloat(minutes) / 60 * Self.hourHeight - 4)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private struct Placed {
        let event: CalendarEvent
        let top: CGFloat
        let height: CGFloat
        var lane: Int
        var lanes: Int
    }

    /// Eventi del giorno affiancati quando si sovrappongono.
    private func layout(for day: Date) -> [Placed] {
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let items = events.filter { !$0.isAllDay && $0.start < dayEnd && $0.end > dayStart }.sorted { $0.start < $1.start }
        var placed: [Placed] = []
        var laneEnds: [Date] = []
        var cluster: [Int] = []
        var clusterEnd = Date.distantPast
        func closeCluster() {
            for index in cluster { placed[index].lanes = laneEnds.count }
            cluster = []; laneEnds = []
        }
        for event in items {
            if event.start >= clusterEnd { closeCluster() }
            let lane = laneEnds.firstIndex { $0 <= event.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(event.end) } else { laneEnds[lane] = event.end }
            let start = max(event.start, dayStart)
            let end = min(event.end, dayEnd)
            placed.append(Placed(event: event, top: CGFloat(start.timeIntervalSince(dayStart) / 3600) * Self.hourHeight,
                                 height: CGFloat(end.timeIntervalSince(start) / 3600) * Self.hourHeight, lane: lane, lanes: 1))
            cluster.append(placed.count - 1)
            clusterEnd = max(clusterEnd, event.end)
        }
        closeCluster()
        return placed
    }
}

/// Evento nella griglia oraria: clic per aprirlo, trascinamento per spostarlo, bordo in basso per cambiarne la durata.
private struct TimedEventBlock: View {
    let event: CalendarEvent
    let selected: Bool
    let canDrag: Bool
    let hourHeight: CGFloat
    let columnWidth: CGFloat
    let onSelect: () -> Void
    /// Giorni, minuti (a quarti d'ora), e se è un cambio di durata.
    let onMove: (Int, Int, Bool) -> Void
    @State private var drag = CGSize.zero
    @State private var resizing = false

    private var snapped: (days: Int, minutes: Int) {
        (Int((drag.width / columnWidth).rounded()), Int((drag.height / hourHeight * 4).rounded()) * 15)
    }

    var body: some View {
        let color = Color(event.color)
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(3)
                Text(drag == .zero ? event.start.formatted(.dateTime.hour().minute().locale(Dates.locale)) : preview)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                if let location = event.location { Text(location).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(selected ? 0.42 : 0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(color, lineWidth: 1.2) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottom) {
            if canDrag {
                Color.clear.frame(height: 6).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 3)
                        .onChanged { value in resizing = true; drag = CGSize(width: 0, height: value.translation.height) }
                        .onEnded { _ in
                            let minutes = snapped.minutes
                            drag = .zero; resizing = false
                            if minutes != 0 { onMove(0, minutes, true) }
                        })
            }
        }
        .offset(resizing ? .zero : drag)
        .zIndex(drag == .zero ? 0 : 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { value in if !resizing { drag = value.translation } }
            .onEnded { _ in
                guard !resizing else { return }
                let (days, minutes) = snapped
                drag = .zero
                if days != 0 || minutes != 0 { onMove(days, minutes, false) }
            }, including: canDrag ? .all : .subviews)
        .help(event.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var preview: String {
        let (days, minutes) = snapped
        if resizing {
            let end = event.end.addingTimeInterval(Double(minutes * 60))
            return String(localized: "fine \(end.formatted(.dateTime.hour().minute().locale(Dates.locale)))")
        }
        let start = Calendar.current.date(byAdding: .day, value: days, to: event.start)!.addingTimeInterval(Double(minutes * 60))
        return start.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Dates.locale))
    }
}

/// Evento compatto (tutto il giorno, mese, risultati).
private struct EventChip: View {
    let event: CalendarEvent
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let color = Color(event.color)
        Button(action: action) {
            HStack(spacing: 5) {
                if !event.isAllDay { Circle().fill(color).frame(width: 6, height: 6) }
                Text(event.isAllDay ? event.title : String(localized: "\(event.start.formatted(.dateTime.hour().minute().locale(Dates.locale))) \(event.title)"))
                    .font(.system(size: 11, weight: event.isAllDay ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(event.isAllDay || selected ? color.opacity(selected ? 0.45 : 0.22) : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(event.title)
    }
}

/// Porta la vista di scorrimento che la contiene a una posizione, una volta per ogni `key` (settimana o giorno mostrati).
private struct InitialScroll: NSViewRepresentable {
    let y: CGFloat
    let key: Date?

    func makeNSView(context: Context) -> Setter { Setter() }
    func updateNSView(_ view: Setter, context: Context) { view.request(y: y, key: key) }

    final class Setter: NSView {
        private var target: CGFloat = 0
        private var wanted: Date?
        private var done: Date??

        func request(y: CGFloat, key: Date?) {
            target = y
            wanted = key
            if done != .some(key) { DispatchQueue.main.async { [weak self] in self?.apply() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard done != .some(wanted), let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            guard clip.bounds.height > 0, document.frame.height > clip.bounds.height else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.apply() }
                return
            }
            let maxY = document.frame.height - clip.bounds.height
            let y = min(target, maxY)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: document.isFlipped ? y : maxY - y))
            scroll.reflectScrolledClipView(clip)
            done = .some(wanted)
        }
    }
}

// MARK: - Mese

private struct MonthGrid: View {
    let anchor: Date
    let start: Date
    let events: [CalendarEvent]
    let selectedID: String?
    let onSelect: (CalendarEvent) -> Void
    let onOpenDay: (Date) -> Void
    let onCreate: (Date) -> Void
    private var cal: Calendar { Calendar.current }

    var body: some View {
        let days = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let symbols = (0..<7).map { cal.shortStandaloneWeekdaySymbols[($0 + cal.firstWeekday - 1) % 7].capitalized }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(symbols, id: \.self) { Text($0).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            .padding(.vertical, 6)
            Divider()
            GeometryReader { geo in
                let height = geo.size.height / 6
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { column in
                                cell(days[row * 7 + column], height: height)
                                if column < 6 { Divider() }
                            }
                        }
                        .frame(height: height)
                        if row < 5 { Divider() }
                    }
                }
            }
        }
    }

    private func cell(_ day: Date, height: CGFloat) -> some View {
        let next = cal.date(byAdding: .day, value: 1, to: day)!
        let items = events.filter { $0.start < next && $0.end > day }
        let capacity = max(1, Int((height - 26) / 17))
        let today = cal.isDateInToday(day)
        let inMonth = cal.isDate(day, equalTo: anchor, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Spacer()
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 12, weight: today ? .bold : .regular))
                    .foregroundStyle(today ? .white : inMonth ? .primary : .secondary)
                    .frame(minWidth: 22, minHeight: 20)
                    .background(today ? Color.red : .clear, in: Capsule())
            }
            ForEach(items.prefix(items.count > capacity ? capacity - 1 : capacity)) { event in
                EventChip(event: event, selected: event.id == selectedID) { onSelect(event) }
            }
            if items.count > capacity {
                Button("altri \(items.count - capacity + 1)…") { onOpenDay(day) }
                    .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 5)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(inMonth ? Color.clear : Color.primary.opacity(0.025))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onCreate(day) }
        .contextMenu {
            Button("Apri il giorno") { onOpenDay(day) }
            Button("Nuovo evento") { onCreate(day) }
        }
    }
}

// MARK: - Risultati della ricerca

private struct CalendarSearchResults: View {
    let results: [CalendarEvent]
    let selectedID: String?
    let onSelect: (CalendarEvent) -> Void

    var body: some View {
        if results.isEmpty {
            AppPlaceholder(symbol: "magnifyingglass", title: String(localized: "Nessun evento trovato"), message: String(localized: "Cerco nel titolo, nel luogo e nelle note, sei mesi prima e dopo oggi."))
        } else {
            List {
                ForEach(Dictionary(grouping: results) { Calendar.current.startOfDay(for: $0.start) }.sorted { $0.key < $1.key }, id: \.key) { day, items in
                    Section(day.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Dates.locale)).capitalized) {
                        ForEach(items) { event in
                            Button { onSelect(event) } label: {
                                HStack(spacing: 10) {
                                    RoundedRectangle(cornerRadius: 2).fill(Color(event.color)).frame(width: 4, height: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.title).font(.system(size: 13, weight: .semibold))
                                        Text(event.isAllDay ? String(localized: "Tutto il giorno · \(event.calendarTitle)")
                                             : String(localized: "\(event.start.formatted(.dateTime.hour().minute().locale(Dates.locale)))–\(event.end.formatted(.dateTime.hour().minute().locale(Dates.locale))) · \(event.calendarTitle)"))
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(event.id == selectedID ? Color.accentColor.opacity(0.15) : Color.clear)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Pannello dell'evento

private struct EventInspector: View {
    @Environment(AppState.self) private var state
    @Binding var detail: EventDetail?
    let calendars: [CalendarInfo]
    let allCalendars: [CalendarInfo]
    let canWrite: Bool
    let onSaved: (String, Date) -> Void
    let onDeleted: () -> Void
    let onClose: () -> Void
    @State private var draft: EventDetail?
    @State private var original: EventDetail?
    @State private var askSpan: SpanRequest?
    @State private var confirmDelete = false

    enum SpanRequest: Identifiable { case save, delete; var id: Int { self == .save ? 0 : 1 } }

    private var editable: Bool { canWrite && (draft?.writable ?? false) }
    private var dirty: Bool { draft != original }

    var body: some View {
        VStack(spacing: 0) {
            if let binding = Binding($draft) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(binding.wrappedValue.isNew ? String(localized: "Nuovo evento") : String(localized: "Evento")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).iconHelp(String(localized: "Chiudi"))
                                .keyboardShortcut(.cancelAction)
                        }
                        TextField("Titolo", text: binding.title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 20, weight: .bold))
                            .disabled(!editable)
                        TextField("Luogo", text: binding.location)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .disabled(!editable)
                        if !editable {
                            Label(canWrite ? String(localized: "Calendario in sola lettura") : String(localized: "Calendario in sola lettura nelle impostazioni di Siri AI+"), systemImage: "lock")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        InspectorGroup {
                            InspectorRow(label: String(localized: "Tutto il giorno")) {
                                Toggle("", isOn: binding.isAllDay).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            InspectorRow(label: String(localized: "Inizio")) {
                                DatePicker("", selection: startBinding(binding), displayedComponents: binding.wrappedValue.isAllDay ? [.date] : [.date, .hourAndMinute])
                                    .labelsHidden().datePickerStyle(.field)
                            }
                            InspectorRow(label: String(localized: "Fine")) {
                                DatePicker("", selection: binding.end, in: binding.wrappedValue.start..., displayedComponents: binding.wrappedValue.isAllDay ? [.date] : [.date, .hourAndMinute])
                                    .labelsHidden().datePickerStyle(.field)
                            }
                            InspectorRow(label: String(localized: "Ripeti")) {
                                Picker("", selection: binding.repeatRule) {
                                    ForEach(EventDetail.Repeat.allCases.filter { $0 != .custom || binding.wrappedValue.repeatRule == .custom }, id: \.self) {
                                        Text($0.label).tag($0)
                                    }
                                }
                                .labelsHidden().fixedSize()
                            }
                            InspectorRow(label: String(localized: "Avviso"), divider: false) {
                                Picker("", selection: binding.alert) {
                                    ForEach(EventDetail.Alert.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                .labelsHidden().fixedSize()
                            }
                        }
                        .disabled(!editable)
                        InspectorGroup {
                            InspectorRow(label: String(localized: "Calendario"), divider: false) {
                                Picker("", selection: binding.calendarID) {
                                    ForEach(editable ? calendars : allCalendars) { calendar in
                                        Label { Text(calendar.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(calendar.color)) }
                                            .tag(calendar.id)
                                    }
                                }
                                .labelsHidden().fixedSize()
                            }
                        }
                        .disabled(!editable)
                        InspectorGroup(title: String(localized: "Note e link")) {
                            TextField("Link", text: binding.url)
                                .textFieldStyle(.plain).font(.system(size: 13)).padding(.vertical, 8)
                            Divider().opacity(0.6)
                            TextEditor(text: binding.notes)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 70, maxHeight: 180)
                                .padding(.vertical, 6)
                        }
                        .disabled(!editable)
                        if !binding.wrappedValue.attendees.isEmpty {
                            InspectorGroup(title: String(localized: "Invitati")) {
                                if let organizer = binding.wrappedValue.organizer {
                                    Label("Organizza \(organizer)", systemImage: "person.crop.circle.badge.checkmark").font(.system(size: 13)).padding(.vertical, 6)
                                }
                                ForEach(binding.wrappedValue.attendees, id: \.self) { name in
                                    Label(name, systemImage: "person").font(.system(size: 13)).padding(.vertical, 4)
                                }
                            }
                        }
                        if !binding.wrappedValue.isNew {
                            Button { state.send(String(localized: "Parlami dell'evento «\(binding.wrappedValue.title)» di \(Dates.friendly(binding.wrappedValue.start)) e dimmi cosa preparare")) } label: {
                                Label("Chiedi a Siri AI+", systemImage: "sparkle")
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 13))
                        }
                    }
                    .padding(16)
                }
                InspectorFooter {
                    if !binding.wrappedValue.isNew, editable {
                        Button(role: .destructive) { binding.wrappedValue.isRecurring ? (askSpan = .delete) : (confirmDelete = true) } label: {
                            Image(systemName: "trash")
                        }
                        .iconHelp(String(localized: "Elimina evento"))
                        Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }.iconHelp(String(localized: "Duplica"))
                    }
                } trailing: {
                    if binding.wrappedValue.isNew {
                        Button("Annulla") { onClose() }
                    } else if dirty {
                        Button("Annulla modifiche") { draft = original }
                    }
                    Button(binding.wrappedValue.isNew ? String(localized: "Aggiungi") : String(localized: "Salva")) {
                        binding.wrappedValue.isRecurring && !binding.wrappedValue.isNew ? (askSpan = .save) : save(future: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!editable || (!dirty && !binding.wrappedValue.isNew))
                }
            }
        }
        .onAppear { draft = detail; original = detail }
        .onChange(of: detail) { _, value in
            // Nuovo evento o evento diverso: si ricomincia; lo stesso evento aggiornato: si prende la versione nuova se non ci sono modifiche.
            if value?.identifier != original?.identifier || value?.occurrence != original?.occurrence || !dirty {
                draft = value; original = value
            }
        }
        .confirmationDialog(askSpan == .delete ? String(localized: "Eliminare l'evento che si ripete?") : String(localized: "Salvare le modifiche all'evento che si ripete?"),
                            isPresented: Binding(get: { askSpan != nil }, set: { if !$0 { askSpan = nil } }), presenting: askSpan) { request in
            Button(request == .delete ? String(localized: "Elimina solo questo") : String(localized: "Salva solo per questo"), role: request == .delete ? .destructive : nil) {
                request == .delete ? delete(future: false) : save(future: false)
            }
            Button(request == .delete ? String(localized: "Elimina anche i futuri") : String(localized: "Salva per tutti i futuri"), role: request == .delete ? .destructive : nil) {
                request == .delete ? delete(future: true) : save(future: true)
            }
        }
        .confirmationDialog("Eliminare «\(draft?.title ?? "")»?", isPresented: $confirmDelete) {
            Button("Elimina evento", role: .destructive) { delete(future: false) }
        } message: {
            Text("L'evento viene tolto dal calendario anche sugli altri dispositivi.")
        }
    }

    /// Spostando l'inizio, la fine segue mantenendo la durata.
    private func startBinding(_ binding: Binding<EventDetail>) -> Binding<Date> {
        Binding(get: { binding.wrappedValue.start }, set: { newValue in
            let duration = binding.wrappedValue.end.timeIntervalSince(binding.wrappedValue.start)
            binding.wrappedValue.start = newValue
            binding.wrappedValue.end = newValue.addingTimeInterval(max(0, duration))
        })
    }

    private func save(future: Bool) {
        guard let draft else { return }
        do {
            let result = try CalendarStore.save(draft, futureEvents: future)
            state.appDone(.calendar, draft.isNew ? String(localized: "Evento aggiunto") : String(localized: "Evento salvato"), detail: "\(draft.title) · \(Dates.friendly(draft.start))")
            original = draft
            onSaved(result.identifier, result.start)
        } catch {
            state.appFailed(.calendar, String(localized: "Evento non salvato"), error)
        }
    }

    private func delete(future: Bool) {
        guard let draft else { return }
        do {
            try CalendarStore.delete(identifier: draft.identifier, start: draft.occurrence, futureEvents: future)
            state.appDone(.calendar, String(localized: "Evento eliminato"), detail: draft.title)
            onDeleted()
        } catch {
            state.appFailed(.calendar, String(localized: "Evento non eliminato"), error)
        }
    }

    private func duplicate() {
        guard let draft else { return }
        do {
            let result = try CalendarStore.duplicate(identifier: draft.identifier, start: draft.occurrence)
            state.appDone(.calendar, String(localized: "Evento duplicato"), detail: draft.title)
            onSaved(result.identifier, result.start)
        } catch {
            state.appFailed(.calendar, String(localized: "Evento non duplicato"), error)
        }
    }
}
