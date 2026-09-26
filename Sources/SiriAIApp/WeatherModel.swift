import CoreLocation
import MapKit
import SiriCore
import SwiftUI

/// Meteo della Home: la città scelta (Roma di serie) o, se lo attivi, la posizione del Mac.
/// Si aggiorna ogni 20 minuti e l'ultima previsione resta salvata, così all'avvio il cielo è subito quello giusto.
@MainActor @Observable
final class WeatherModel: NSObject {
    enum Status: Equatable { case idle, loading, ready, failed(String) }
    /// Ora del cielo forzata nelle prove (`--weather-demo pioggia:notte`).
    enum DemoTime: String { case giorno, notte, alba, tramonto }

    private(set) var snapshot: WeatherSnapshot?
    private(set) var status = Status.idle
    private(set) var demoTime: DemoTime?
    private(set) var isDemo = false
    /// Ultimo errore (città non trovata, servizio irraggiungibile): la previsione precedente resta visibile.
    private(set) var lastError: String?

    var city: String {
        didSet {
            guard city != oldValue else { return }
            if persists { UserDefaults.standard.set(city, forKey: "weatherCity") }
            Task { await refresh(force: true) }
        }
    }

    var usesLocation: Bool {
        didSet {
            guard usesLocation != oldValue else { return }
            if persists { UserDefaults.standard.set(usesLocation, forKey: "weatherUsesLocation") }
            Task { await refresh(force: true) }
        }
    }

    @ObservationIgnored private let persists = !CommandLine.arguments.contains("--ephemeral")
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var waiters: [CheckedContinuation<CLLocation?, Never>] = []
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var refreshing = false
    private static let cacheURL = AppPaths.support("weather.json")

    override init() {
        let args = CommandLine.arguments
        city = args.firstIndex(of: "--weather-city").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            ?? UserDefaults.standard.string(forKey: "weatherCity") ?? "Roma"
        usesLocation = UserDefaults.standard.bool(forKey: "weatherUsesLocation")
        super.init()
        if let index = args.firstIndex(of: "--weather-demo"), index + 1 < args.count {
            let parts = args[index + 1].split(separator: ":").map(String.init)
            let time = parts.count > 1 ? DemoTime(rawValue: parts[1]) : nil
            if let condition = WeatherCondition(demoName: parts[0]) {
                isDemo = true
                demoTime = time
                snapshot = WeatherSnapshot.demo(condition, isDay: time.map { $0 != .notte } ?? true, place: city, now: demoNow ?? .now)
                status = .ready
                return
            }
        }
        if let data = try? Data(contentsOf: Self.cacheURL), let cached = try? JSONDecoder().decode(WeatherSnapshot.self, from: data) {
            snapshot = cached
            status = .ready
        }
    }

    /// Momento usato per disegnare il cielo (nelle prove può essere l'alba o la notte).
    var demoNow: Date? {
        guard let demoTime else { return nil }
        let calendar = Calendar.current
        let hour: (Int, Int) = switch demoTime {
        case .giorno: (13, 0)
        case .notte: (23, 0)
        case .alba: (7, 20)
        case .tramonto: (19, 15)
        }
        return calendar.date(bySettingHour: hour.0, minute: hour.1, second: 0, of: .now)
    }

    var sky: SkyState {
        SkyState(snapshot: snapshot, now: demoNow ?? .now)
    }

    /// Aggiorna le previsioni se sono vecchie (o subito, con `force`).
    func refresh(force: Bool = false) async {
        guard !isDemo, !refreshing else { return }
        if !force, let snapshot, Date.now.timeIntervalSince(snapshot.fetched) < 20 * 60, placeMatches(snapshot) { return }
        if !force, let lastAttempt, Date.now.timeIntervalSince(lastAttempt) < 60 { return }
        refreshing = true
        defer { refreshing = false }
        lastAttempt = .now
        if snapshot == nil { status = .loading }
        do {
            let place = try await currentPlace()
            let fresh = try await WeatherService.forecast(for: place)
            snapshot = fresh
            status = .ready
            lastError = nil
            if persists, let data = try? JSONEncoder().encode(fresh) { try? data.write(to: Self.cacheURL, options: .atomic) }
        } catch {
            status = snapshot == nil ? .failed(error.localizedDescription) : .ready
            lastError = error.localizedDescription
            Agent.log("METEO: \(error.localizedDescription)")
        }
    }

    private func placeMatches(_ snapshot: WeatherSnapshot) -> Bool {
        usesLocation || snapshot.place.localizedCaseInsensitiveCompare(city) == .orderedSame || cachedPlace?.query == city
    }

    // MARK: Luogo

    private struct CachedPlace: Codable { let query: String; let place: WeatherPlace }

    private var cachedPlace: CachedPlace? {
        get { UserDefaults.standard.data(forKey: "weatherPlace").flatMap { try? JSONDecoder().decode(CachedPlace.self, from: $0) } }
        set { if persists { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "weatherPlace") } }
    }

    private func currentPlace() async throws -> WeatherPlace {
        if usesLocation, persists, let location = await requestLocation() {
            let name = await placeName(for: location) ?? "La mia posizione"
            return WeatherPlace(name: name, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        }
        if let cached = cachedPlace, cached.query == city { return cached.place }
        let place = try await WeatherService.geocode(city)
        cachedPlace = CachedPlace(query: city, place: place)
        return place
    }

    private func placeName(for location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = Locale(identifier: "it_IT")
        let items = try? await request.mapItems
        return items?.first?.addressRepresentations?.cityName ?? items?.first?.name
    }

    /// Posizione approssimativa (circa 1 km): chiede il permesso la prima volta.
    private func requestLocation() async -> CLLocation? {
        let manager = self.manager ?? {
            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            self.manager = manager
            return manager
        }()
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: manager.requestLocation()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                self.finish(with: nil)
            }
        }
    }

    private func finish(with location: CLLocation?) {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: location) }
    }
}

extension WeatherModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            switch status {
            case .authorizedAlways, .authorizedWhenInUse: self.manager?.requestLocation()
            case .denied, .restricted: self.finish(with: nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        MainActor.assumeIsolated { self.finish(with: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.finish(with: nil) }
    }
}
