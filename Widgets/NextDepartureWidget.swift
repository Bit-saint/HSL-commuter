import AppIntents
import SwiftUI
import WidgetKit
import ETAEngine
import HSLDesign

struct NextDepartureEntry: TimelineEntry {
    var date: Date
    var departure: SharedStore.NextDeparture?
}

struct NextDepartureProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextDepartureEntry {
        NextDepartureEntry(date: .now, departure: .init(
            commuteName: "Work", line: "550", mode: .trunkBus, stopName: "Pasila",
            departure: .now.addingTimeInterval(600), leaveAt: .now.addingTimeInterval(300),
            arrival: .now.addingTimeInterval(1800), isRealtime: true, updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (NextDepartureEntry) -> Void) {
        completion(SharedStore.nextDeparture.map { NextDepartureEntry(date: .now, departure: $0) } ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextDepartureEntry>) -> Void) {
        let dep = SharedStore.nextDeparture
        // Countdowns tick on their own; ask for a reload once the departure has passed.
        let reload = max(dep?.departure ?? .now.addingTimeInterval(1800), .now.addingTimeInterval(300))
        completion(Timeline(entries: [NextDepartureEntry(date: .now, departure: dep)], policy: .after(reload)))
    }
}

struct NextDepartureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextDeparture", provider: NextDepartureProvider()) { entry in
            NextDepartureView(entry: entry)
                .containerBackground(Color.black, for: .widget)
        }
        .configurationDisplayName("Next departure")
        .description("When to leave for your commute.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct NextDepartureView: View {
    var entry: NextDepartureEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let d = entry.departure, d.departure > entry.date {
            switch family {
            case .accessoryInline:
                Text("\(d.line) · leave \(d.leaveAt, style: .relative)")
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Text("\(d.line) from \(d.stopName)").font(.headline).lineLimit(1)
                    Text("Leave \(d.leaveAt, style: .relative)").font(.body)
                }
            default:
                full(d)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "tram.fill").font(.title2)
                Text("Open the app to plan").font(.caption)
            }
            .foregroundStyle(.white)
        }
    }

    private func full(_ d: SharedStore.NextDeparture) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                LineBadge(d.line, mode: d.mode, size: 13)
                Spacer()
                if d.isRealtime { Circle().fill(HSLColor.green).frame(width: 7, height: 7) }
            }
            Text(d.leaveAt > entry.date ? "Leave in" : "Departs in").font(HSLFont.caption(11)).foregroundStyle(.secondary)
            Text(timerInterval: entry.date...(d.leaveAt > entry.date ? d.leaveAt : d.departure), countsDown: true)
                .font(HSLFont.number(28))
            Text("\(d.stopName) → \(d.commuteName)").font(HSLFont.caption(11)).lineLimit(1).foregroundStyle(.secondary)
            if family == .systemMedium {
                Button(intent: StartCommuteIntent()) {
                    Label("Start live tracking", systemImage: "location.north.line.fill")
                        .font(HSLFont.caption(12))
                }
                .tint(HSLColor.blue)
            }
        }
        .foregroundStyle(.white)
    }
}
