import Foundation
import Testing
@testable import SiriCore

@Suite struct WeatherTests {
    static let sample = """
    {"latitude":41.89,"longitude":12.48,"utc_offset_seconds":7200,"timezone":"Europe/Rome",
     "current":{"time":"2026-09-22T20:15","interval":900,"temperature_2m":21.9,"apparent_temperature":22.2,"relative_humidity_2m":60,
                "is_day":0,"weather_code":0,"wind_speed_10m":6.5,"cloud_cover":10},
     "hourly":{"time":["2026-09-22T20:00","2026-09-22T21:00","2026-09-22T22:00","2026-09-22T23:00"],
               "temperature_2m":[21.9,20.8,null,19.1],"precipitation_probability":[0,5,10,null],
               "weather_code":[0,1,2,3],"is_day":[0,0,0,0]},
     "daily":{"time":["2026-09-22","2026-09-23"],"weather_code":[2,61],"temperature_2m_max":[25.0,19.4],"temperature_2m_min":[18.2,16.9],
              "sunrise":["2026-09-22T07:10","2026-09-23T07:11"],"sunset":["2026-09-22T19:21","2026-09-23T19:19"],
              "uv_index_max":[4.9,3.1],"precipitation_probability_max":[0,80]}}
    """

    @Test func parsesOpenMeteo() throws {
        let place = WeatherPlace(name: "Roma", latitude: 41.89, longitude: 12.48)
        let snapshot = try WeatherService.parse(Data(Self.sample.utf8), place: place, fetched: .now)
        #expect(snapshot.place == "Roma")
        #expect(snapshot.condition == .clear)
        #expect(!snapshot.isDay)
        #expect(snapshot.humidity == 60)
        #expect(snapshot.hours.count == 3)   // l'ora senza temperatura viene saltata
        #expect(snapshot.hours.last?.precipitationChance == 0)
        #expect(snapshot.days.count == 2)
        #expect(snapshot.tomorrow?.condition == .rain)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let sunset = try #require(snapshot.today?.sunset)
        #expect(calendar.component(.hour, from: sunset) == 19 && calendar.component(.minute, from: sunset) == 21)
    }

    @Test func mapsWMOCodes() {
        #expect(WeatherCondition(code: 0) == .clear)
        #expect(WeatherCondition(code: 45) == .fog)
        #expect(WeatherCondition(code: 81) == .rain)
        #expect(WeatherCondition(code: 82) == .heavyRain)
        #expect(WeatherCondition(code: 86) == .snow)
        #expect(WeatherCondition(code: 99) == .thunderstorm)
        #expect(WeatherCondition(demoName: "pioggia-forte") == .heavyRain)
        #expect(WeatherCondition.thunderstorm.scene.thunder == 1)
        #expect(WeatherCondition.clear.symbol(isDay: false) == "moon.stars.fill")
    }

    @Test func suggestsUmbrellaBeforeRain() {
        let now = Date.now
        let hours = (0..<12).map { index in
            WeatherHour(date: now.addingTimeInterval(Double(index) * 3600), temperature: 20, precipitationChance: index == 3 ? 70 : 5,
                        code: index == 3 ? 61 : 2, isDay: true)
        }
        let snapshot = WeatherSnapshot(place: "Roma", latitude: 0, longitude: 0, fetched: now, temperature: 20, apparent: 20, humidity: 50,
                                       windSpeed: 5, cloudCover: 40, code: 2, isDay: true, hours: hours, days: [])
        let insight = snapshot.insight(now: now)
        #expect(insight.title == "Porta l'ombrello")
        #expect(insight.detail.contains("70%"))
    }

    @Test func demoIsConsistent() {
        let demo = WeatherSnapshot.demo(.snow, isDay: false)
        #expect(demo.condition == .snow)
        #expect(demo.hours.count == 72)
        #expect(demo.days.count == 3)
        #expect(demo.insight().title == "Nevica")
    }
}
