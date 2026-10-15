import SwiftUI
import HSLDesign

/// Set home, work, when you need to be at work and when you leave work.
struct HomeWorkView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                PlacePicker(place: $app.homeWork.home, placeholder: "Home")
            } header: { Label("Home", systemImage: "house.fill") }

            Section {
                PlacePicker(place: $app.homeWork.work, placeholder: "Work")
            } header: { Label("Work", systemImage: "briefcase.fill") }

            Section {
                WeekdayPicker(days: $app.homeWork.workdays)
                Toggle("Different times per day", isOn: $app.homeWork.usesPerDayTimes.animation())
                if !app.homeWork.usesPerDayTimes {
                    DatePicker("Arrive at work by", selection: minutes($app.homeWork.defaultTimes.arriveAtWork),
                               displayedComponents: .hourAndMinute)
                    DatePicker("Leave work at", selection: minutes($app.homeWork.defaultTimes.leaveWork),
                               displayedComponents: .hourAndMinute)
                }
            } header: { Text("Working hours") } footer: {
                Text("Mornings plan backwards from your arrival time. Afternoons plan the first good departure after you leave work.")
            }

            if app.homeWork.usesPerDayTimes {
                ForEach(WeekdayPicker.order.filter { app.homeWork.workdays.contains($0) }, id: \.self) { day in
                    Section(Calendar.current.weekdaySymbols[day - 1]) {
                        DatePicker("Arrive at work by", selection: minutes(dayBinding(day).arriveAtWork),
                                   displayedComponents: .hourAndMinute)
                        DatePicker("Leave work at", selection: minutes(dayBinding(day).leaveWork),
                                   displayedComponents: .hourAndMinute)
                    }
                }
            }

            Section {
                Toggle("“Leave now” reminders", isOn: $app.homeWork.remindersEnabled)
            } footer: {
                Text("A heads-up 10 minutes before you should leave, and again when it's time, based on realtime departures.")
            }
        }
        .navigationTitle("Home & Work")
        .onDisappear { Task { await LeaveReminderScheduler.refresh(app: app) } }
    }

    /// Times for one weekday, seeded from the default times the first time it's edited.
    private func dayBinding(_ day: Int) -> Binding<DayTimes> {
        Binding(
            get: { app.homeWork.perDayTimes[day] ?? app.homeWork.defaultTimes },
            set: { app.homeWork.perDayTimes[day] = $0 })
    }

    /// Bridges "minutes after midnight" to a DatePicker.
    private func minutes(_ value: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: value.wrappedValue / 60, minute: value.wrappedValue % 60,
                                      second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                value.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

/// Monday-first row of weekday toggles. Days are Calendar weekdays (1 = Sunday … 7 = Saturday).
struct WeekdayPicker: View {
    @Binding var days: Set<Int>
    static let order = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        HStack {
            ForEach(Self.order, id: \.self) { day in
                let on = days.contains(day)
                Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                    .font(HSLFont.caption())
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(on ? HSLColor.blue : Color.white.opacity(0.1), in: Circle())
                    .contentShape(Circle())
                    .onTapGesture { if on { days.remove(day) } else { days.insert(day) } }
            }
        }
    }
}

/// One-line summary for lists: "Home → Work · arrive 8:30 · leave 16:30".
extension HomeWorkSetup {
    var summary: String {
        guard let home, let work else { return String(localized: "Not set") }
        let times = usesPerDayTimes
            ? "times vary by day"
            : "arrive \(defaultTimes.arriveAtWork.clockString) · leave \(defaultTimes.leaveWork.clockString)"
        return "\(home.name) ↔ \(work.name) · \(times)"
    }
}
