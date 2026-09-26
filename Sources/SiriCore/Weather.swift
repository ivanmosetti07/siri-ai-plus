import Foundation

// MARK: - Condizioni

/// Condizione del cielo, dai codici WMO usati da Open-Meteo.
public enum WeatherCondition: String, Codable, Sendable, CaseIterable {
    case clear, mostlyClear, partlyCloudy, cloudy, fog, drizzle, rain, heavyRain, freezingRain, snow, thunderstorm

    public init(code: Int) {
        switch code {
        case 0: self = .clear
        case 1: self = .mostlyClear
        case 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57, 66, 67: self = .freezingRain
        case 61, 63, 80, 81: self = .rain
        case 65, 82: self = .heavyRain
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 95, 96, 99: self = .thunderstorm
        default: self = .cloudy
        }
    }

    /// Nomi per la diagnostica (`--weather-demo pioggia`).
    public init?(demoName: String) {
        let names: [String: WeatherCondition] = [
            "sereno": .clear, "poco-nuvoloso": .mostlyClear, "variabile": .partlyCloudy, "nuvoloso": .cloudy, "nebbia": .fog,
            "pioggerella": .drizzle, "pioggia": .rain, "pioggia-forte": .heavyRain, "gelo": .freezingRain, "neve": .snow, "temporale": .thunderstorm,
        ]
        guard let condition = names[demoName.lowercased()] ?? WeatherCondition(rawValue: demoName) else { return nil }
        self = condition
    }

    /// Codice WMO rappresentativo (per il meteo di esempio).
    public var code: Int {
        switch self {
        case .clear: 0
        case .mostlyClear: 1
        case .partlyCloudy: 2
        case .cloudy: 3
        case .fog: 45
        case .drizzle: 53
        case .rain: 63
        case .heavyRain: 65
        case .freezingRain: 66
        case .snow: 73
        case .thunderstorm: 95
        }
    }

    public var label: String {
        switch self {
        case .clear: Language.t("Sereno", "Clear")
        case .mostlyClear: Language.t("Poco nuvoloso", "Mostly Clear")
        case .partlyCloudy: Language.t("Parzialmente nuvoloso", "Partly Cloudy")
        case .cloudy: Language.t("Nuvoloso", "Cloudy")
        case .fog: Language.t("Nebbia", "Fog")
        case .drizzle: Language.t("Pioggerella", "Drizzle")
        case .rain: Language.t("Pioggia", "Rain")
        case .heavyRain: Language.t("Pioggia forte", "Heavy Rain")
        case .freezingRain: Language.t("Pioggia gelata", "Freezing Rain")
        case .snow: Language.t("Neve", "Snow")
        case .thunderstorm: Language.t("Temporale", "Thunderstorm")
        }
    }

    /// Simbolo SF (va mostrato con i colori multipli).
    public func symbol(isDay: Bool) -> String {
        switch self {
        case .clear: isDay ? "sun.max.fill" : "moon.stars.fill"
        case .mostlyClear: isDay ? "sun.max.fill" : "moon.fill"
        case .partlyCloudy: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .freezingRain: "cloud.sleet.fill"
        case .snow: "cloud.snow.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        }
    }

    public var isWet: Bool { [.drizzle, .rain, .heavyRain, .freezingRain, .thunderstorm].contains(self) }

    /// Intensità degli elementi del cielo animato, da 0 a 1.
    public var scene: WeatherScene {
        switch self {
        case .clear: WeatherScene(clouds: 0.04)
        case .mostlyClear: WeatherScene(clouds: 0.3)
        case .partlyCloudy: WeatherScene(clouds: 0.56)
        case .cloudy: WeatherScene(clouds: 0.92)
        case .fog: WeatherScene(clouds: 0.6, fog: 0.85)
        case .drizzle: WeatherScene(clouds: 0.86, rain: 0.32)
        case .rain: WeatherScene(clouds: 0.95, rain: 0.66)
        case .heavyRain: WeatherScene(clouds: 1, rain: 1)
        case .freezingRain: WeatherScene(clouds: 0.95, rain: 0.45, snow: 0.3)
        case .snow: WeatherScene(clouds: 0.88, snow: 0.8)
        case .thunderstorm: WeatherScene(clouds: 1, rain: 0.85, thunder: 1)
        }
    }
}

/// Quanto pesano nuvole, pioggia, neve, nebbia e fulmini nel cielo animato.
public struct WeatherScene: Sendable, Equatable {
    public var clouds: Double
    public var rain: Double
    public var snow: Double
    public var fog: Double
    public var thunder: Double

    public init(clouds: Double = 0, rain: Double = 0, snow: Double = 0, fog: Double = 0, thunder: Double = 0) {
        self.clouds = clouds; self.rain = rain; self.snow = snow; self.fog = fog; self.thunder = thunder
    }
}

// MARK: - Previsioni

public struct WeatherHour: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let temperature: Double
    public let precipitationChance: Int
    public let code: Int
    public let isDay: Bool
    public var condition: WeatherCondition { WeatherCondition(code: code) }

    public init(date: Date, temperature: Double, precipitationChance: Int, code: Int, isDay: Bool) {
        self.date = date; self.temperature = temperature; self.precipitationChance = precipitationChance; self.code = code; self.isDay = isDay
    }
}

public struct WeatherDay: Codable, Sendable, Equatable {
    public let date: Date
    public let code: Int
    public let high: Double
    public let low: Double
    public let sunrise: Date?
    public let sunset: Date?
    public let uvMax: Double?
    public let precipitationChance: Int?
    public var condition: WeatherCondition { WeatherCondition(code: code) }

    public init(date: Date, code: Int, high: Double, low: Double, sunrise: Date?, sunset: Date?, uvMax: Double?, precipitationChance: Int?) {
        self.date = date; self.code = code; self.high = high; self.low = low
        self.sunrise = sunrise; self.sunset = sunset; self.uvMax = uvMax; self.precipitationChance = precipitationChance
    }
}

/// Luogo del meteo: la città scelta o la posizione del Mac.
public struct WeatherPlace: Codable, Sendable, Equatable {
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let region: String?

    public init(name: String, latitude: Double, longitude: Double, region: String? = nil) {
        self.name = name; self.latitude = latitude; self.longitude = longitude; self.region = region
    }
}

/// Il meteo di un momento: condizioni attuali, prossime ore e prossimi giorni.
public struct WeatherSnapshot: Codable, Sendable, Equatable {
    public var place: String
    public let latitude: Double
    public let longitude: Double
    public let fetched: Date
    public let temperature: Double
    public let apparent: Double
    public let humidity: Int
    public let windSpeed: Double
    public let cloudCover: Int
    public let code: Int
    public let isDay: Bool
    public let hours: [WeatherHour]
    public let days: [WeatherDay]

    public init(place: String, latitude: Double, longitude: Double, fetched: Date, temperature: Double, apparent: Double, humidity: Int,
                windSpeed: Double, cloudCover: Int, code: Int, isDay: Bool, hours: [WeatherHour], days: [WeatherDay]) {
        self.place = place; self.latitude = latitude; self.longitude = longitude; self.fetched = fetched
        self.temperature = temperature; self.apparent = apparent; self.humidity = humidity; self.windSpeed = windSpeed
        self.cloudCover = cloudCover; self.code = code; self.isDay = isDay; self.hours = hours; self.days = days
    }

    public var condition: WeatherCondition { WeatherCondition(code: code) }
    public var symbol: String { condition.symbol(isDay: isDay) }
    public var today: WeatherDay? { days.first }
    public var tomorrow: WeatherDay? { days.count > 1 ? days[1] : nil }

    /// Le prossime ore, a partire da quella in corso.
    public func upcoming(from now: Date = .now, count: Int = 24) -> [WeatherHour] {
        Array(hours.filter { $0.date > now.addingTimeInterval(-3599) }.prefix(count))
    }

    /// Scena animata: la condizione, con la copertura nuvolosa reale quando non piove.
    public var scene: WeatherScene {
        var scene = condition.scene
        if !condition.isWet, condition != .snow, condition != .fog {
            scene.clouds = min(1, max(0.02, 0.5 * scene.clouds + 0.5 * Double(cloudCover) / 100))
        }
        return scene
    }

    public static func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }
}

/// Il consiglio del giorno, come l'intestazione delle previsioni orarie di Meteo.
public struct WeatherInsight: Sendable, Equatable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) { self.title = title; self.detail = detail }
}

extension WeatherSnapshot {
    public func insight(now: Date = .now) -> WeatherInsight {
        let calendar = Calendar.current
        let next = Array(upcoming(from: now, count: 12).dropFirst())
        let hour = calendar.component(.hour, from: now)
        let evening = hour >= 18 || hour < 5
        let t = Self.degrees(temperature)
        let feels = abs(apparent - temperature) >= 3 ? Language.t(", percepiti \(Self.degrees(apparent))", ", feels like \(Self.degrees(apparent))") : ""
        // In inglese l'ora nel formato della lingua («3 PM»).
        func at(_ item: WeatherHour) -> String {
            Language.isEnglish ? item.date.formatted(.dateTime.hour().locale(Dates.locale)) : "\(calendar.component(.hour, from: item.date))"
        }

        if condition == .thunderstorm {
            return WeatherInsight(title: Language.t("Temporale in corso", "Thunderstorm now"),
                                  detail: Language.t("Pioggia forte e fulmini: meglio restare al riparo. Adesso \(t)\(feels).",
                                                     "Heavy rain and lightning: best to stay indoors. It's \(t) now\(feels)."))
        }
        if let storm = next.first(where: { $0.condition == .thunderstorm }) {
            return WeatherInsight(title: Language.t("Temporali in arrivo", "Thunderstorms coming"),
                                  detail: Language.t("Possibili temporali verso le \(at(storm)). Tieni l'ombrello a portata di mano.",
                                                     "Thunderstorms possible around \(at(storm)). Keep an umbrella handy."))
        }
        if condition.isWet {
            if let dry = next.first(where: { !$0.condition.isWet && $0.precipitationChance < 35 }) {
                return WeatherInsight(title: Language.t("Sta piovendo", "It's raining"),
                                      detail: Language.t("Dovrebbe smettere verso le \(at(dry)). Adesso \(t)\(feels).",
                                                         "It should stop around \(at(dry)). It's \(t) now\(feels)."))
            }
            return WeatherInsight(title: Language.t("Pioggia per ore", "Rain for hours"),
                                  detail: Language.t("Non smette prima di sera: porta l'ombrello. Adesso \(t)\(feels).",
                                                     "It won't stop before evening: take an umbrella. It's \(t) now\(feels)."))
        }
        if condition == .snow {
            return WeatherInsight(title: Language.t("Nevica", "It's snowing"),
                                  detail: Language.t("Strade scivolose: esci con calma. Adesso \(t)\(feels).",
                                                     "Slippery roads: take it slow if you go out. It's \(t) now\(feels)."))
        }
        if let snow = next.first(where: { $0.condition == .snow }) {
            return WeatherInsight(title: Language.t("Neve in arrivo", "Snow coming"),
                                  detail: Language.t("Possibile neve verso le \(at(snow)). Adesso \(t)\(feels).",
                                                     "Snow possible around \(at(snow)). It's \(t) now\(feels)."))
        }
        if let rain = next.first(where: { $0.condition.isWet || $0.precipitationChance >= 50 }) {
            return WeatherInsight(title: Language.t("Porta l'ombrello", "Take an umbrella"),
                                  detail: Language.t("Pioggia probabile verso le \(at(rain)) (\(rain.precipitationChance)%). Adesso \(t)\(feels).",
                                                     "Rain likely around \(at(rain)) (\(rain.precipitationChance)%). It's \(t) now\(feels)."))
        }
        if condition == .fog {
            return WeatherInsight(title: Language.t("Nebbia", "Fog"),
                                  detail: Language.t("Visibilità ridotta: se guidi, vai piano. Adesso \(t)\(feels).",
                                                     "Low visibility: if you're driving, go slowly. It's \(t) now\(feels)."))
        }
        if evening, let tomorrow, let today {
            let difference = tomorrow.high - today.high
            if difference <= -4 {
                return WeatherInsight(title: Language.t("Domani più fresco", "Cooler tomorrow"),
                                      detail: Language.t("Massima di \(Self.degrees(tomorrow.high)), \(Int(abs(difference).rounded()))° in meno di oggi. \(tomorrow.condition.label).",
                                                         "High of \(Self.degrees(tomorrow.high)), \(Int(abs(difference).rounded()))° lower than today. \(tomorrow.condition.label)."))
            }
            if difference >= 4 {
                return WeatherInsight(title: Language.t("Domani più caldo", "Warmer tomorrow"),
                                      detail: Language.t("Massima di \(Self.degrees(tomorrow.high)), \(Int(difference.rounded()))° in più di oggi. \(tomorrow.condition.label).",
                                                         "High of \(Self.degrees(tomorrow.high)), \(Int(difference.rounded()))° higher than today. \(tomorrow.condition.label)."))
            }
        }
        if !evening, let today, today.high >= 31 {
            return WeatherInsight(title: Language.t("Giornata calda", "Hot day"),
                                  detail: Language.t("Fino a \(Self.degrees(today.high)) nel pomeriggio: bevi spesso e cerca l'ombra.",
                                                     "Up to \(Self.degrees(today.high)) in the afternoon: drink often and look for shade."))
        }
        if isDay, let uv = today?.uvMax, uv >= 7 {
            return WeatherInsight(title: Language.t("Sole forte", "Strong sun"),
                                  detail: Language.t("Indice UV \(Int(uv.rounded())): se stai fuori metti la crema solare.",
                                                     "UV index \(Int(uv.rounded())): if you're outside, put on sunscreen."))
        }
        switch condition {
        case .clear, .mostlyClear:
            if evening || !isDay {
                let low = (tomorrow?.low ?? today?.low).map { Language.t(" Minima di \(Self.degrees($0)) stanotte.", " Low of \(Self.degrees($0)) tonight.") } ?? ""
                return WeatherInsight(title: Language.t("Cielo sereno", "Clear skies"),
                                      detail: Language.t("Serata limpida, nessuna pioggia in vista.\(low)", "Clear evening, no rain in sight.\(low)"))
            }
            let high = today.map { Language.t(" Massima di \(Self.degrees($0.high)).", " High of \(Self.degrees($0.high)).") } ?? ""
            return WeatherInsight(title: Language.t("Giornata di sole", "Sunny day"), detail: Language.t("Nessuna pioggia prevista.\(high)", "No rain expected.\(high)"))
        case .partlyCloudy:
            if evening || !isDay {
                return WeatherInsight(title: Language.t("Qualche nuvola", "A few clouds"),
                                      detail: Language.t("Serata variabile ma asciutta. Adesso \(t)\(feels).", "Changeable but dry evening. It's \(t) now\(feels)."))
            }
            return WeatherInsight(title: Language.t("Sole e nuvole", "Sun and clouds"),
                                  detail: Language.t("Cielo variabile ma asciutto nelle prossime ore. Adesso \(t)\(feels).",
                                                     "Changeable but dry skies over the next few hours. It's \(t) now\(feels)."))
        default:
            return WeatherInsight(title: Language.t("Cielo coperto", "Overcast"),
                                  detail: Language.t("Nuvole ma niente pioggia nelle prossime ore. Adesso \(t)\(feels).",
                                                     "Clouds but no rain over the next few hours. It's \(t) now\(feels)."))
        }
    }

    /// Meteo di esempio per le prove (`--weather-demo`): nessuna richiesta di rete.
    public static func demo(_ condition: WeatherCondition, isDay: Bool, place: String = "Roma", now: Date = .now) -> WeatherSnapshot {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let base = condition == .snow ? 1.0 : (condition.isWet ? 16.0 : 22.0)
        var hours: [WeatherHour] = []
        for index in 0..<72 {
            let date = start.addingTimeInterval(Double(index) * 3600)
            let hour = index % 24
            let temperature = base + 5 * sin(Double(hour - 9) / 24 * 2 * .pi)
            let chance = condition.isWet || condition == .snow ? 60 + (index * 7) % 35 : (index * 3) % 12
            hours.append(WeatherHour(date: date, temperature: temperature, precipitationChance: chance, code: condition.code, isDay: (7..<19).contains(hour)))
        }
        let days = (0..<3).map { offset -> WeatherDay in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            return WeatherDay(date: day, code: condition.code, high: base + 5 - Double(offset), low: base - 5 - Double(offset),
                              sunrise: day.addingTimeInterval(7 * 3600 + 10 * 60), sunset: day.addingTimeInterval(19 * 3600 + 20 * 60),
                              uvMax: 5, precipitationChance: condition.isWet ? 80 : 5)
        }
        let current = hours.first { calendar.isDate($0.date, equalTo: now, toGranularity: .hour) } ?? hours[12]
        return WeatherSnapshot(place: place, latitude: 41.89, longitude: 12.48, fetched: now, temperature: current.temperature,
                               apparent: current.temperature - 1, humidity: condition.isWet ? 88 : 55, windSpeed: condition == .thunderstorm ? 32 : 9,
                               cloudCover: Int(condition.scene.clouds * 100), code: condition.code, isDay: isDay, hours: hours, days: days)
    }
}

// MARK: - Open-Meteo

public enum WeatherError: LocalizedError {
    case http(Int)
    case placeNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): Language.t("Il servizio meteo non risponde (errore \(code)).", "The weather service isn't responding (error \(code)).")
        case .placeNotFound(let name): Language.t("Non trovo la città «\(name)».", "I can't find the city “\(name)”.")
        }
    }
}

/// Previsioni da Open-Meteo: servizio gratuito e senza chiave. Riceve solo le coordinate arrotondate (circa 1 km) o il nome della città.
public enum WeatherService {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration)
    }()

    public static func forecast(for place: WeatherPlace, now: Date = .now) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,is_day,weather_code,wind_speed_10m,cloud_cover"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "3"),
        ]
        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw WeatherError.http(http.statusCode) }
        return try parse(data, place: place, fetched: now)
    }

    /// Coordinate di una città («Roma», «Milano»…).
    public static func geocode(_ name: String) async throws -> WeatherPlace {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: Language.current.rawValue),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw WeatherError.http(http.statusCode) }
        struct Results: Decodable {
            struct Result: Decodable { let name: String; let latitude: Double; let longitude: Double; let admin1: String? }
            let results: [Result]?
        }
        guard let first = try JSONDecoder().decode(Results.self, from: data).results?.first else { throw WeatherError.placeNotFound(name) }
        return WeatherPlace(name: first.name, latitude: first.latitude, longitude: first.longitude, region: first.admin1)
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature: Double
            let apparentTemperature: Double?
            let humidity: Double?
            let isDay: Int?
            let weatherCode: Int
            let windSpeed: Double?
            let cloudCover: Double?
            enum CodingKeys: String, CodingKey {
                case temperature = "temperature_2m", apparentTemperature = "apparent_temperature", humidity = "relative_humidity_2m"
                case isDay = "is_day", weatherCode = "weather_code", windSpeed = "wind_speed_10m", cloudCover = "cloud_cover"
            }
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature: [Double?]
            let precipitationProbability: [Double?]?
            let weatherCode: [Int?]
            let isDay: [Int?]?
            enum CodingKeys: String, CodingKey {
                case time, temperature = "temperature_2m", precipitationProbability = "precipitation_probability", weatherCode = "weather_code", isDay = "is_day"
            }
        }
        struct Daily: Decodable {
            let time: [String]
            let weatherCode: [Int?]
            let high: [Double?]
            let low: [Double?]
            let sunrise: [String?]?
            let sunset: [String?]?
            let uvIndexMax: [Double?]?
            let precipitationProbabilityMax: [Double?]?
            enum CodingKeys: String, CodingKey {
                case time, weatherCode = "weather_code", high = "temperature_2m_max", low = "temperature_2m_min", sunrise, sunset
                case uvIndexMax = "uv_index_max", precipitationProbabilityMax = "precipitation_probability_max"
            }
        }
        let timezone: String?
        let utcOffsetSeconds: Int?
        let current: Current
        let hourly: Hourly
        let daily: Daily
        enum CodingKeys: String, CodingKey { case timezone, utcOffsetSeconds = "utc_offset_seconds", current, hourly, daily }
    }

    /// Legge la risposta di Open-Meteo (orari locali del luogo, senza fuso nel testo).
    public static func parse(_ data: Data, place: WeatherPlace, fetched: Date) throws -> WeatherSnapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let zone = response.timezone.flatMap(TimeZone.init(identifier:)) ?? response.utcOffsetSeconds.flatMap(TimeZone.init(secondsFromGMT:)) ?? .current
        func formatter(_ format: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = format
            return formatter
        }
        let minutes = formatter("yyyy-MM-dd'T'HH:mm")
        let days = formatter("yyyy-MM-dd")

        let hourly = response.hourly
        var hours: [WeatherHour] = []
        for index in hourly.time.indices {
            guard let date = minutes.date(from: hourly.time[index]),
                  let temperature = hourly.temperature[safe: index] ?? nil,
                  let code = hourly.weatherCode[safe: index] ?? nil else { continue }
            let chance = (hourly.precipitationProbability?[safe: index] ?? nil).map { Int($0.rounded()) } ?? 0
            let isDay = (hourly.isDay?[safe: index] ?? nil).map { $0 == 1 } ?? true
            hours.append(WeatherHour(date: date, temperature: temperature, precipitationChance: chance, code: code, isDay: isDay))
        }

        let daily = response.daily
        var forecastDays: [WeatherDay] = []
        for index in daily.time.indices {
            guard let date = days.date(from: daily.time[index]),
                  let code = daily.weatherCode[safe: index] ?? nil,
                  let high = daily.high[safe: index] ?? nil,
                  let low = daily.low[safe: index] ?? nil else { continue }
            let sunrise = (daily.sunrise?[safe: index] ?? nil).flatMap { minutes.date(from: $0) }
            let sunset = (daily.sunset?[safe: index] ?? nil).flatMap { minutes.date(from: $0) }
            let uv = daily.uvIndexMax?[safe: index] ?? nil
            let chance = (daily.precipitationProbabilityMax?[safe: index] ?? nil).map { Int($0.rounded()) }
            forecastDays.append(WeatherDay(date: date, code: code, high: high, low: low, sunrise: sunrise, sunset: sunset, uvMax: uv, precipitationChance: chance))
        }

        let current = response.current
        return WeatherSnapshot(
            place: place.name, latitude: place.latitude, longitude: place.longitude, fetched: fetched,
            temperature: current.temperature, apparent: current.apparentTemperature ?? current.temperature,
            humidity: Int((current.humidity ?? 0).rounded()), windSpeed: current.windSpeed ?? 0,
            cloudCover: Int((current.cloudCover ?? 0).rounded()), code: current.weatherCode, isDay: (current.isDay ?? 1) == 1,
            hours: hours, days: forecastDays)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
