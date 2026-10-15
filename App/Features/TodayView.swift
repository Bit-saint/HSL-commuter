import SwiftUI
import ETAEngine
import HSLKit
import HSLDesign

/// Home screen: the best time to leave for your commute, with alternatives.
struct TodayView: View {
    @Environment(AppModel.self) private var app
    @State private var selectedCommute: Commute?
    @State private var options: [PlannedOption] = []
    @State private var loading = false
    @State private var error: String?
    @State private var reversed = false

    /// Picked commute, else the one that fits the time of day (to work / to home).
    private var commute: Commute? {
        guard let base = selectedCommute ?? app.suggestedCommute() else { return nil }
        return reversed ? app.counterpart(of: base) : base
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let suggestion = app.places.suggestion {
                    SuggestionCard(suggestion: suggestion,
                                   accept: { app.places.accept(suggestion) },
                                   dismiss: { app.places.dismiss(suggestion) })
                }
                if let commute {
                    header(commute)
                    ContextBanners(commute: commute)
                    if let best = options.first {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            BestOptionCard(option: best, now: ctx.date) { start(best, commute) }
                        }
                    }
                    if options.count > 1 {
                        Text("Other options").font(HSLFont.title(18)).padding(.top, 8)
                        ForEach(options.dropFirst()) { option in
                            OptionRow(option: option).onTapGesture { start(option, commute) }
                        }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(HSLColor.orange)
                            .font(HSLFont.body(14))
                    }
                } else {
                    ContentUnavailableView {
                        Label("No commute yet", systemImage: "house.and.flag")
                    } description: {
                        Text("Set your home, work and working hours to get leave-time advice.")
                    } actions: {
                        NavigationLink("Set Home & Work") { HomeWorkView() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
        }
        .background(Color.black)
        .navigationTitle(greeting)
        .refreshable { await load() }
        .task(id: commute?.id) { await load() }
        .task {
            // Keep realtime estimates fresh while the screen is visible.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await load()
            }
        }
        .overlay { if loading && options.isEmpty { ProgressView() } }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
    }

    @ViewBuilder
    private func header(_ commute: Commute) -> some View {
        HStack {
            Menu {
                ForEach(app.allCommutes()) { c in
                    Button(c.name) { selectedCommute = c; reversed = false }
                }
                if selectedCommute != nil {
                    Button("Automatic (by time of day)") { selectedCommute = nil; reversed = false }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("From \(commute.origin.name)").font(HSLFont.caption()).foregroundStyle(.secondary)
                    Text(commute.destination.name).font(HSLFont.title())
                        .foregroundStyle(.white)
                    if let label = timeLabel(commute) {
                        Text(label).font(HSLFont.caption(12)).foregroundStyle(HSLColor.blue)
                    }
                }
            }
            Spacer()
            Button {
                reversed.toggle()
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle.fill").font(.title)
            }
        }
    }

    private func timeLabel(_ c: Commute) -> String? {
        if let m = c.arriveByMinutes { return "Arrive by \(m.clockString)" }
        if let m = c.leaveAtMinutes { return "Leaving at \(m.clockString)" }
        return nil
    }

    private func load() async {
        guard let commute else { return }
        loading = true
        defer { loading = false }
        do {
            let origin = await app.location.currentLocation().map { GeoPoint($0.coordinate) }
            // Use the current location if we're not obviously elsewhere (> 2 km from origin).
            let from = origin.flatMap { $0.distance(to: commute.origin.point) < 2_000 ? $0 : nil }
            await app.refreshWeather(near: from ?? commute.origin.point)
            let planned = try await Planner.options(for: commute, app: app, from: from)
            // Keep occupancy we already know while the new probe runs.
            let known = Dictionary(options.map { ($0.id, $0.occupancy) }, uniquingKeysWith: { a, _ in a })
            options = planned.map { o in var o = o; o.occupancy = known[o.id] ?? nil; return o }
            error = nil
            options = await Planner.withOccupancy(options, app: app)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func start(_ option: PlannedOption, _ commute: Commute) {
        app.startSession(itinerary: option.itinerary, destinationName: commute.destination.name)
    }
}

struct BestOptionCard: View {
    var option: PlannedOption
    var now: Date
    var onStart: () -> Void

    var body: some View {
        let leave = option.leaveAt.timeIntervalSince(now)
        let color: Color = leave > 180 ? HSLColor.green : (leave > 0 ? HSLColor.yellow : HSLColor.orange)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(leave > 0 ? "Leave in" : "Leave now").font(HSLFont.body()).opacity(0.85)
                Spacer()
                if option.isRealtime { LiveBadge() }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if leave > 0 {
                    Text("\(Int(leave / 60))").font(HSLFont.display(64))
                    Text("min").font(HSLFont.title())
                } else {
                    Text("Go!").font(HSLFont.display(56))
                }
            }
            LegStrip(legs: option.itinerary.legs)
            OptionExtras(option: option)
            HStack {
                if let first = option.firstTransit {
                    Text("\(first.route?.shortName ?? "") from \(first.from.name) at \(first.start.formatted(date: .omitted, time: .shortened))")
                        .font(HSLFont.caption())
                }
                Spacer()
                Text("Arrive \(option.arrival.formatted(date: .omitted, time: .shortened))").font(HSLFont.caption())
            }
            .opacity(0.9)
            Button(action: onStart) {
                Label("Start live tracking", systemImage: "location.north.line.fill")
                    .font(HSLFont.body())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.22), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(
            LinearGradient(colors: [color.opacity(0.95), color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

struct OptionRow: View {
    var option: PlannedOption

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                LegStrip(legs: option.itinerary.legs)
                Text("Leave \(option.leaveAt.formatted(date: .omitted, time: .shortened)) · arrive \(option.arrival.formatted(date: .omitted, time: .shortened))")
                    .font(HSLFont.caption()).foregroundStyle(.secondary)
                OptionExtras(option: option)
            }
            Spacer()
            Text("\(Int(option.itinerary.duration / 60)) min").font(HSLFont.title(18))
        }
        .padding(14)
        .background(HSLColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Walk → bus → metro chips.
struct LegStrip: View {
    var legs: [Leg]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(legs.enumerated()), id: \.offset) { i, leg in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).opacity(0.6) }
                if leg.mode.isTransit {
                    LineBadge(leg.route?.shortName ?? "", mode: leg.mode, size: 13)
                } else {
                    HStack(spacing: 2) {
                        Image(systemName: "figure.walk")
                        Text("\(max(Int(leg.duration / 60), 1))")
                    }
                    .font(HSLFont.caption(12))
                }
            }
        }
    }
}

struct LiveBadge: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.white).frame(width: 6, height: 6).opacity(pulse ? 0.3 : 1)
            Text("LIVE").font(.system(size: 11, weight: .heavy, design: .rounded))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.white.opacity(0.2), in: Capsule())
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } }
    }
}


/// Day off, working from home, weather: the context that changes today's advice.
struct ContextBanners: View {
    let commute: Commute
    @Environment(AppModel.self) private var app

    private var isHomeWork: Bool { commute.id == HomeWorkSetup.toWorkID || commute.id == HomeWorkSetup.toHomeID }

    var body: some View {
        VStack(spacing: 8) {
            if isHomeWork {
                switch app.dayStatus() {
                case .dayOff(let reason, let symbol):
                    banner(symbol: symbol, color: HSLColor.green, title: reason,
                           subtitle: "No reminders today. You can still plan a trip.") {
                        if reason == "Working from home" {
                            Button("Undo") { app.setWorkingFromHome(false) }.font(HSLFont.caption())
                        }
                    }
                case .workday:
                    if commute.id == HomeWorkSetup.toWorkID, app.session == nil {
                        Button {
                            app.setWorkingFromHome(true)
                        } label: {
                            Label("Working from home today", systemImage: "house.fill")
                                .font(HSLFont.caption()).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if let headline = app.weatherImpact.headline {
                banner(symbol: app.weatherImpact.symbol, color: HSLColor.ferry, title: headline,
                       subtitle: app.weather.map { String(format: "%.0f°C · FMI forecast", $0.temperature) } ?? "") {
                    EmptyView()
                }
            }
        }
    }

    private func banner<Trailing: View>(symbol: String, color: Color, title: String, subtitle: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(HSLFont.body(15))
                if !subtitle.isEmpty { Text(subtitle).font(HSLFont.caption(12)).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing()
        }
        .padding(12)
        .background(HSLColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// "Looks like you work in Keilaniemi. Use it?"
struct SuggestionCard: View {
    let suggestion: PlaceLearningService.Suggestion
    var accept: () -> Void
    var dismiss: () -> Void

    private var text: (title: String, body: String, symbol: String) {
        switch suggestion {
        case .home(let p): return ("Is this home?", "You spend most nights near \(p.name).", "house.fill")
        case .work(let p): return ("Is this work?", "You're near \(p.name) most weekdays.", "briefcase.fill")
        case .times(let a, let l):
            let parts = [a.map { "arrive around \($0.clockString)" }, l.map { "leave around \($0.clockString)" }]
                .compactMap { $0 }.joined(separator: " and ")
            return ("Update your times?", "You usually \(parts).", "clock.fill")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text.title, systemImage: text.symbol).font(HSLFont.title(17))
            Text(text.body).font(HSLFont.body(14)).foregroundStyle(.secondary)
            HStack {
                Button("Not now", action: dismiss).buttonStyle(.bordered)
                Button("Yes, use it", action: accept).buttonStyle(.borderedProminent)
            }
            .font(HSLFont.body(14))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HSLColor.blue.opacity(0.22), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Occupancy chip and disruption line for an option.
struct OptionExtras: View {
    let option: PlannedOption

    var body: some View {
        if option.occupancy != nil || option.crowd != nil || !option.disruptions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let crowd = option.crowd {
                    // Rider reports beat the sensor: they're what people actually saw.
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                        Text(crowd.label(now: Date()))
                    }
                    .font(HSLFont.caption(11))
                    .foregroundStyle(Occupancy.color(crowd.level))
                } else if let occ = option.occupancy {
                    let label = Occupancy.label(occ)
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                        Text("\(label.0) · \(occ)% full")
                    }
                    .font(HSLFont.caption(11))
                    .foregroundStyle(label.1)
                }
                ForEach(option.disruptions.prefix(2)) { d in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(d.summary)
                    }
                    .font(HSLFont.caption(11))
                    .foregroundStyle(d.severity == .severe ? HSLColor.red : HSLColor.yellow)
                }
            }
        }
    }
}
