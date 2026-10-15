import EventKit
import Foundation

/// Reads (never writes) your calendar: the first meeting of the day, and days marked off.
@MainActor
final class CalendarService {
    private let store = EKEventStore()

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
    }

    private func events(on date: Date) -> [EKEvent] {
        guard hasAccess else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
    }

    /// Start of the first timed event between 6:00 and `before` (minutes after midnight), if any.
    func firstMeetingMinutes(on date: Date, before: Int) -> Int? {
        events(on: date)
            .filter { !$0.isAllDay && $0.availability != .free }
            .compactMap { e -> Int? in
                let c = Calendar.current.dateComponents([.hour, .minute], from: e.startDate)
                let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                return (6 * 60...before).contains(m) ? m : nil
            }
            .min()
    }

    private static let dayOffWords = [
        "wfh", "remote", "work from home", "etä", "etätyö", "loma", "vacation", "holiday", "sick",
        "sairas", "ooo", "out of office", "day off", "vapaa", "lomapäivä",
    ]

    /// Title of an all-day event that means "not commuting today" (vacation, WFH, sick…).
    func dayOffEvent(on date: Date) -> String? {
        events(on: date).first { e in
            guard e.isAllDay || e.endDate.timeIntervalSince(e.startDate) >= 8 * 3600 else { return false }
            let title = (e.title ?? "").lowercased()
            return Self.dayOffWords.contains { title.contains($0) }
        }?.title
    }
}
