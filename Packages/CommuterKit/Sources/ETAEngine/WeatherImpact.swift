import Foundation

public struct WeatherConditions: Codable, Sendable, Equatable {
    /// °C
    public var temperature: Double
    /// mm in the coming hour
    public var precipitation: Double
    /// mm over the past ~12 hours (for ice after rain/sleet)
    public var recentPrecipitation: Double
    /// m/s
    public var windSpeed: Double
    public var time: Date

    public init(temperature: Double, precipitation: Double, recentPrecipitation: Double = 0,
                windSpeed: Double, time: Date) {
        self.temperature = temperature
        self.precipitation = precipitation
        self.recentPrecipitation = recentPrecipitation
        self.windSpeed = windSpeed
        self.time = time
    }
}

/// What the weather means for walking to the stop.
public struct WeatherImpact: Sendable, Equatable {
    /// Multiply your normal walking speed by this.
    public var walkingFactor: Double
    /// Extra seconds of margin at the stop.
    public var extraBuffer: TimeInterval
    public var isSlippery: Bool
    /// Better to wait indoors and leave just in time.
    public var waitIndoors: Bool
    /// Short, friendly headline, e.g. "Slippery today: leave about 2 min earlier".
    public var headline: String?
    public var symbol: String

    public static let neutral = WeatherImpact(walkingFactor: 1, extraBuffer: 0, isSlippery: false,
                                              waitIndoors: false, headline: nil, symbol: "sun.max.fill")

    public static func assess(_ w: WeatherConditions) -> WeatherImpact {
        var impact = WeatherImpact.neutral
        let t = w.temperature
        let snowing = t <= 0.5 && w.precipitation >= 0.2
        // Ice: around zero with fresh precipitation, or a freeze after a wet day.
        let slippery = (-4...2).contains(t) && (w.precipitation > 0 || w.recentPrecipitation > 0.5)

        if slippery {
            impact.walkingFactor = 0.82
            impact.extraBuffer = 60
            impact.isSlippery = true
            impact.headline = "Slippery today: leave about 2 min earlier"
            impact.symbol = "snowflake"
        } else if snowing {
            impact.walkingFactor = 0.88
            impact.extraBuffer = 45
            impact.headline = "Snowing: we've slowed your walking pace"
            impact.symbol = "cloud.snow.fill"
        } else if w.precipitation >= 2 {
            impact.extraBuffer = 20
            impact.headline = "Heavy rain: wait inside, we'll time it"
            impact.symbol = "cloud.heavyrain.fill"
        } else if w.precipitation >= 0.3 {
            impact.headline = "Rain: wait inside until it's time to go"
            impact.symbol = "cloud.rain.fill"
        }
        if w.windSpeed >= 12 {
            impact.walkingFactor = min(impact.walkingFactor, 0.94)
            impact.extraBuffer = max(impact.extraBuffer, 20)
            if impact.headline == nil { impact.headline = "Strong wind: walking a little slower"; impact.symbol = "wind" }
        }
        if t <= -10, impact.headline == nil {
            impact.headline = "\(Int(t.rounded()))°C: stay inside, we'll tell you when to go"
            impact.symbol = "thermometer.snowflake"
        }
        impact.waitIndoors = t < 0 || w.precipitation >= 0.3 || w.windSpeed >= 10
        return impact
    }
}
