import SwiftUI
import ETAEngine
import HSLKit
import HSLDesign

/// Nearby stops and their next departures; tap one to track it live.
struct StopBoardView: View {
    @Environment(AppModel.self) private var app
    @State private var stops: [NearbyStop] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(HSLColor.orange) }
            ForEach(stops) { nearby in
                NavigationLink {
                    DeparturesView(stop: nearby.stop)
                } label: {
                    HStack {
                        Image(systemName: (nearby.stop.mode ?? .bus).symbolName)
                            .foregroundStyle(HSLColor.mode(nearby.stop.mode ?? .bus))
                            .frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(nearby.stop.name).font(HSLFont.body())
                            Text([nearby.stop.code, nearby.stop.platform.map { "Platform \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(HSLFont.caption(12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(nearby.distance)) m").font(HSLFont.caption()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Nearby")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let loc = await app.location.currentLocation() else {
            error = "Location not available."
            return
        }
        do {
            stops = try await app.client.nearbyStops(around: GeoPoint(loc.coordinate))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DeparturesView: View {
    let stop: StopRef
    @Environment(AppModel.self) private var app
    @State private var departures: [Departure] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            List(departures) { d in
                Button {
                    app.track(departure: d, at: stop)
                } label: {
                    HStack {
                        LineBadge(d.route.shortName, mode: d.route.mode, size: 14)
                        Text(d.headsign).font(HSLFont.body()).lineLimit(1)
                        Spacer()
                        let mins = Int(d.realtime.timeIntervalSince(ctx.date) / 60)
                        VStack(alignment: .trailing) {
                            Text(mins <= 0 ? "Now" : "\(mins) min").font(HSLFont.title(17))
                                .foregroundStyle(d.isRealtime ? HSLColor.green : .white)
                            Text(d.realtime.formatted(date: .omitted, time: .shortened))
                                .font(HSLFont.caption(11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(stop.name)
        .task {
            while !Task.isCancelled {
                if let result = try? await app.client.departures(stopId: stop.id) { departures = result.1 }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
}
