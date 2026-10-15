import Foundation

/// Finnish public holidays (plus Christmas Eve and Midsummer Eve, which are de facto days off).
public enum FinnishCalendar {
    public struct Holiday: Sendable, Equatable {
        public var month: Int
        public var day: Int
        public var name: String
    }

    static let helsinki = TimeZone(identifier: "Europe/Helsinki")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = helsinki
        return c
    }

    /// Easter Sunday (Anonymous Gregorian algorithm).
    public static func easter(_ year: Int) -> (month: Int, day: Int) {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return (month, day)
    }

    public static func holidays(in year: Int) -> [Holiday] {
        let cal = calendar
        var list: [Holiday] = [
            Holiday(month: 1, day: 1, name: "New Year's Day"),
            Holiday(month: 1, day: 6, name: "Epiphany"),
            Holiday(month: 5, day: 1, name: "May Day"),
            Holiday(month: 12, day: 6, name: "Independence Day"),
            Holiday(month: 12, day: 24, name: "Christmas Eve"),
            Holiday(month: 12, day: 25, name: "Christmas Day"),
            Holiday(month: 12, day: 26, name: "Boxing Day"),
        ]
        let e = easter(year)
        if let easterDate = cal.date(from: DateComponents(year: year, month: e.month, day: e.day, hour: 12)) {
            for (offset, name) in [(-2, "Good Friday"), (0, "Easter Sunday"), (1, "Easter Monday"), (39, "Ascension Day")] {
                if let d = cal.date(byAdding: .day, value: offset, to: easterDate) {
                    let c = cal.dateComponents([.month, .day], from: d)
                    list.append(Holiday(month: c.month!, day: c.day!, name: name))
                }
            }
        }
        // Midsummer Eve: the Friday between 19 and 25 June; Midsummer Day the next day.
        for day in 19...25 {
            if let d = cal.date(from: DateComponents(year: year, month: 6, day: day, hour: 12)),
               cal.component(.weekday, from: d) == 6 {
                list.append(Holiday(month: 6, day: day, name: "Midsummer Eve"))
                list.append(Holiday(month: 6, day: day + 1, name: "Midsummer Day"))
            }
        }
        // All Saints' Day: the Saturday between 31 October and 6 November.
        for offset in 0...6 {
            if let d = cal.date(from: DateComponents(year: year, month: 10, day: 31 + offset, hour: 12)),
               cal.component(.weekday, from: d) == 7 {
                let c = cal.dateComponents([.month, .day], from: d)
                list.append(Holiday(month: c.month!, day: c.day!, name: "All Saints' Day"))
            }
        }
        return list
    }

    /// The holiday on this date, if any.
    public static func holiday(on date: Date) -> Holiday? {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year else { return nil }
        return holidays(in: year).first { $0.month == c.month && $0.day == c.day }
    }

    /// "2026-10-15" in Helsinki time, for per-day settings like "working from home".
    public static func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
