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

    private var commute: Commute? {
        guard let base = selectedCommute ?? app.commutes.first else { return nil }
        return reversed ? base.reversed : base
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let commute {
                    header(commute)
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
                    ContentUnavailableView("No commute yet", systemImage: "house.and.flag",
                                           description: Text("Add your home and work in Settings."))
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
                ForEach(app.commutes) { c in
                    Button(c.name) { selectedCommute = c; reversed = false }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(commute.origin.name).font(HSLFont.caption()).foregroundStyle(.secondary)
                    Text(commute.destination.name).font(HSLFont.title())
                        .foregroundStyle(.white)
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

    private func load() async {
        guard let commute else { return }
        loading = true
        defer { loading = false }
        do {
            let origin = await app.location.currentLocation().map { GeoPoint($0.coordinate) }
            // Use the current location if we're not obviously elsewhere (> 2 km from origin).
            let from = origin.flatMap { $0.distance(to: commute.origin.point) < 2_000 ? $0 : nil }
            options = try await Planner.options(for: commute, app: app, from: from)
            error = nil
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
