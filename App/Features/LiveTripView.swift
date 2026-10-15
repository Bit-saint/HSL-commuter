import SwiftUI
import MapKit
import ETAEngine
import HSLKit
import HSLDesign

/// Full-screen live commute: 3D map following your vehicle plus the HSL-styled info sheet.
struct LiveTripView: View {
    let session: CommuteSession
    @Environment(AppModel.self) private var app
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var follow = true
    @State private var is3D = true
    @State private var cam = CameraState()

    var body: some View {
        ZStack(alignment: .bottom) {
            TripMapView(session: session, camera: $camera, is3D: is3D, cam: $cam)
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in follow = false })
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    MapButtons(is3D: $is3D, follow: $follow)
                }
                .padding(.horizontal)
                Spacer()
            }

            LiveTripSheet(session: session, onStop: { app.stopSession() }, onReplan: { Task { await app.replan() } })
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .background(Color.black)
        .onChange(of: session.tick) { _, _ in updateCamera() }
        .onChange(of: is3D) { _, _ in follow = true; updateCamera(animated: true) }
        .onChange(of: follow) { _, on in if on { updateCamera(animated: true) } }
    }

    private func updateCamera(animated: Bool = true) {
        guard follow else { return }
        let now = session.now
        var center: GeoPoint?
        var heading = cam.heading
        var distance = 650.0

        if let option = session.recovery?.selected, session.recovery?.isSuggestion == false {
            let stop = option.boardingStop.location
            let me = session.userLocation.map { GeoPoint($0.coordinate) } ?? option.walkPath.first ?? stop
            center = GeoPoint(latitude: (me.latitude + stop.latitude) / 2, longitude: (me.longitude + stop.longitude) / 2)
            distance = min(max(me.distance(to: stop) * 2.6, 450), 5_000)
            heading = me.bearing(to: stop)
        } else if let live = session.focusLeg {
            switch session.phase {
            case .riding:
                // Chase camera behind the vehicle, like a game.
                center = live.tracker?.displayLocation(at: now)
                heading = live.tracker?.displayHeading(at: now) ?? heading
                distance = 420
            case .waiting:
                // Show the approaching vehicle and your stop.
                let stop = live.leg.from.location
                if let v = live.tracker?.displayLocation(at: now) {
                    center = GeoPoint(latitude: (v.latitude + stop.latitude) / 2, longitude: (v.longitude + stop.longitude) / 2)
                    distance = min(max(v.distance(to: stop) * 2.2, 500), 6_000)
                    heading = v.bearing(to: stop)
                } else {
                    center = stop
                }
            case .walking:
                let stop = live.leg.from.location
                if let user = session.userLocation.map({ GeoPoint($0.coordinate) }) {
                    center = GeoPoint(latitude: (user.latitude + stop.latitude) / 2, longitude: (user.longitude + stop.longitude) / 2)
                    distance = min(max(user.distance(to: stop) * 2.4, 450), 4_000)
                    heading = user.bearing(to: stop)
                } else {
                    center = stop
                }
            case .arrived:
                break
            }
        }
        guard let center else { return }
        let target = MapCamera(centerCoordinate: center.coordinate, distance: distance,
                               heading: heading, pitch: is3D ? 62 : 0)
        if animated {
            withAnimation(.linear(duration: 1)) { camera = .camera(target) }
        } else {
            camera = .camera(target)
        }
    }
}

struct CameraState: Equatable {
    var heading: Double = 0
    var pitch: Double = 60
    var distance: Double = 650
}

struct TripMapView: View {
    let session: CommuteSession
    @Binding var camera: MapCameraPosition
    var is3D: Bool
    @Binding var cam: CameraState

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { timeline in
            let now = timeline.date
            Map(position: $camera) {
                ForEach(Array(session.itinerary.legs.enumerated()), id: \.offset) { i, leg in
                    if let live = session.legs[i], let tracker = live.tracker,
                       let b = live.boardIndex, let a = live.alightIndex {
                        let stops = tracker.pattern.stops
                        MapPolyline(coordinates: tracker.pattern.polyline
                            .slice(from: stops[b].distanceAlong, to: stops[a].distanceAlong).map(\.coordinate))
                            .stroke(HSLColor.mode(leg.mode), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    } else if leg.mode.isTransit {
                        MapPolyline(coordinates: leg.geometry.map(\.coordinate))
                            .stroke(HSLColor.mode(leg.mode).opacity(0.7), lineWidth: 6)
                    } else {
                        MapPolyline(coordinates: leg.geometry.map(\.coordinate))
                            .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [1, 8]))
                    }
                }

                ForEach(session.transitIndices, id: \.self) { i in
                    if let live = session.legs[i] {
                        Annotation(live.leg.from.name, coordinate: live.leg.from.location.coordinate) {
                            StopMarker(color: HSLColor.mode(live.mode), label: live.leg.from.stop?.code)
                        }
                        Annotation(live.leg.to.name, coordinate: live.leg.to.location.coordinate) {
                            StopMarker(color: HSLColor.mode(live.mode), label: live.leg.to.stop?.code)
                        }
                        if let loc = live.tracker?.displayLocation(at: now) {
                            Annotation("", coordinate: loc.coordinate, anchor: .center) {
                                VehicleMarker(mode: live.mode, line: live.line, seat: session.fullness(for: live)?.level,
                                              heading: live.tracker?.displayHeading(at: now) ?? 0,
                                              cam: cam, isFocus: session.focusLeg?.index == i)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                }
                if let option = session.recovery?.selected {
                    // Where to go: walking path to the new stop, then the new route.
                    MapPolyline(coordinates: option.walkPath.map(\.coordinate))
                        .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [2, 8]))
                    ForEach(Array(option.itinerary.legs.enumerated()), id: \.offset) { _, leg in
                        if leg.mode.isTransit {
                            MapPolyline(coordinates: leg.geometry.map(\.coordinate))
                                .stroke(HSLColor.mode(leg.mode).opacity(0.9),
                                        style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [10, 6]))
                        }
                    }
                    Annotation(option.boardingStop.name, coordinate: option.boardingStop.location.coordinate) {
                        VStack(spacing: 3) {
                            LineBadge(option.line, mode: option.firstTransit.mode, size: 13)
                            Image(systemName: "mappin.circle.fill").font(.system(size: 30))
                                .foregroundStyle(.white, HSLColor.mode(option.firstTransit.mode))
                        }
                    }
                }
                UserAnnotation()
            }
            .mapStyle(is3D
                      ? .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll)
                      : .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .continuous) { ctx in
                cam = CameraState(heading: ctx.camera.heading, pitch: ctx.camera.pitch, distance: ctx.camera.distance)
            }
        }
    }
}

/// Pre-rendered pseudo-3D vehicle, oriented to the camera, sized to real-world scale.
struct VehicleMarker: View {
    var mode: TransitMode
    var line: String
    var seat: CrowdLevel?
    var heading: Double
    var cam: CameraState
    var isFocus: Bool

    var body: some View {
        let model = VehicleModel.model(for: mode)
        // Approximate MapKit scale: points per meter from camera distance.
        let ppm = max(min(max(1_400 / max(cam.distance, 50), 0.2), 8), 36 / model.length) // at least ~36 pt long
        let cache = VehicleSpriteCache.shared
        let side = cache.nativeSide(for: mode) * ppm / 3
        ZStack {
            if let img = cache.sprite(mode: mode, relativeHeading: heading - cam.heading, pitch: cam.pitch) {
                img.resizable().interpolation(.high).frame(width: side, height: side)
            } else {
                VehicleSpriteView(mode: mode, relativeHeading: heading - cam.heading, pitch: cam.pitch, pointsPerMeter: ppm)
            }
            VStack(spacing: 2) {
                if let seat { SeatLight(seat, size: 12) }
                LineBadge(line, mode: mode, showsIcon: false, size: 12)
                if isFocus {
                    Circle().stroke(.white, lineWidth: 3).background(Circle().fill(HSLColor.green))
                        .frame(width: 16, height: 16)
                    Rectangle().fill(.white).frame(width: 2, height: 14)
                }
            }
            .offset(y: -max(side * 0.18, 28) - (isFocus ? 18 : 0) - (seat != nil ? 12 : 0))
        }
    }
}

struct StopMarker: View {
    var color: Color
    var label: String?

    var body: some View {
        VStack(spacing: 2) {
            Circle().fill(.white).frame(width: 14, height: 14)
                .overlay(Circle().stroke(color, lineWidth: 4))
            if let label {
                Text(label).font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 4).background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }
}

struct MapButtons: View {
    @Binding var is3D: Bool
    @Binding var follow: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button { is3D.toggle() } label: {
                Text(is3D ? "2D" : "3D").font(.system(size: 15, weight: .heavy, design: .rounded)).frame(width: 44, height: 44)
            }
            Divider().frame(width: 30)
            Button { follow = true } label: {
                Image(systemName: follow ? "location.north.line.fill" : "location.north.line").frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(.primary)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Bottom sheet

struct LiveTripSheet: View {
    let session: CommuteSession
    var onStop: () -> Void
    var onReplan: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Capsule().fill(.white.opacity(0.3)).frame(width: 40, height: 5)
            if let recovery = session.recovery {
                // Missed or late: show the fastest ways on and where to go.
                if recovery.isSuggestion, let live = session.focusLeg { etaRow(live) }
                RecoveryPanel(session: session, recovery: recovery)
                if !recovery.isSuggestion {
                    Button(action: onStop) {
                        Text("Stop tracking").font(HSLFont.body()).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else if let live = session.focusLeg {
                if live.platformChanged, let p = live.platform, !riding {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.arrow.down")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Track change: \(live.line) now leaves from track \(p)").font(HSLFont.body(15))
                            if let old = live.previousPlatform {
                                Text("Was track \(old) at \(live.leg.from.name)").font(HSLFont.caption(12)).opacity(0.9)
                            }
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(HSLColor.orange, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if let d = session.disruptions.first {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.summary).font(HSLFont.body(15))
                            Text(d.consequence).font(HSLFont.caption(12)).opacity(0.9)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background((d.severity == .severe ? HSLColor.red : HSLColor.orange).opacity(0.85),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                RouteCard(session: session, live: live, onStop: onStop)
                etaRow(live)
                paceBanner(live)
                OccupancyAskCard(session: session, live: live)
                actions(live)
            } else {
                arrivedView
            }
        }
        .padding(14)
        .background(HSLColor.surface, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .foregroundStyle(.white)
    }

    private var riding: Bool { if case .riding = session.phase { return true }; return false }

    @ViewBuilder
    private func etaRow(_ live: CommuteSession.LiveLeg) -> some View {
        let eta = riding ? live.alightingETA : live.boardingETA
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(riding ? "Next stop" : "Arrives at \(live.leg.from.name)")
                    .font(HSLFont.caption()).foregroundStyle(.secondary)
                Text(riding ? (session.nextStopName(for: live) ?? live.leg.to.name) : (session.nextStopName(for: live).map { "Now near \($0)" } ?? live.headsign))
                    .font(HSLFont.title(19)).lineLimit(1)
                HStack(spacing: 6) {
                    if !riding, let platform = live.platform {
                        Text(live.mode == .rail ? "Track \(platform)" : "Platform \(platform)")
                            .font(HSLFont.caption(12)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(live.platformChanged ? HSLColor.orange : Color.white.opacity(0.15), in: Capsule())
                    }
                    if let d = eta?.distanceRemaining, d > 50, eta?.isPassed == false {
                        let km = d >= 1000 ? String(format: "%.1f km", d / 1000) : "\(Int(d)) m"
                        let by = [.metro, .rail, .tram, .lightRail].contains(live.mode) ? "by rail" : (live.mode == .ferry ? "by sea" : "by road")
                        Text("\(km) \(by)").font(HSLFont.caption(12)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if let eta {
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(eta.isPassed ? "Gone" : eta.minutesLabel(from: session.now)).font(HSLFont.number(40))
                        if !eta.isPassed { Text("min").font(HSLFont.body(15)) }
                    }
                    HStack(spacing: 4) {
                        Circle().fill(eta.source == .liveVehicle ? HSLColor.green : .gray).frame(width: 6, height: 6)
                        Text(sourceLabel(eta)).font(HSLFont.caption(11)).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .padding(.horizontal, 4)
    }

    private func sourceLabel(_ eta: ETAEstimate) -> String {
        switch eta.source {
        case .liveVehicle: return "live position"
        case .realtimeFeed: return "realtime"
        case .schedule: return "timetable"
        case .passed: return "departed"
        }
    }

    @ViewBuilder
    private func paceBanner(_ live: CommuteSession.LiveLeg) -> some View {
        if let pace = session.pace, pace.state != .onBoard {
            HStack(spacing: 12) {
                Image(systemName: icon(pace.state)).font(.system(size: 26, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(pace.state.title).font(HSLFont.title(18))
                    Text(session.paceMessage).font(HSLFont.caption()).opacity(0.9)
                }
                Spacer()
                if let v = pace.requiredSpeed, v > 0, pace.state != .atStop {
                    VStack(alignment: .trailing) {
                        Text(String(format: "%.1f", v * 3.6)).font(HSLFont.number(22))
                        Text("km/h needed").font(HSLFont.caption(10)).opacity(0.8)
                    }
                }
            }
            .padding(14)
            .foregroundStyle(pace.state == .walkBriskly ? Color.black : Color.white)
            .background(HSLColor.pace(pace.state), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .animation(.snappy, value: pace.state)
        } else if let transfer = session.transfer {
            HStack {
                Image(systemName: "arrow.triangle.swap")
                Text(transferText(transfer)).font(HSLFont.caption())
                Spacer()
            }
            .padding(12)
            .background(transferColor(transfer.risk).opacity(0.25), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func transferText(_ t: TransferAssessment) -> String {
        let mins = Int(t.slack / 60)
        switch t.risk {
        case .comfortable: return "Connection OK · \(mins) min to spare"
        case .tight: return "Tight connection · under 2 min to spare"
        case .needsHurry: return "Hurry at the transfer: walk fast"
        case .missed: return "You'll likely miss the connection"
        }
    }

    private func transferColor(_ r: TransferRisk) -> Color {
        switch r {
        case .comfortable: return HSLColor.green
        case .tight: return HSLColor.yellow
        case .needsHurry: return HSLColor.orange
        case .missed: return HSLColor.red
        }
    }

    private func icon(_ s: PaceState) -> String {
        switch s {
        case .relax: return "cup.and.saucer.fill"
        case .leaveSoon: return "clock.fill"
        case .goNow: return "figure.walk"
        case .walkBriskly: return "figure.walk.motion"
        case .run: return "figure.run"
        case .willMiss: return "xmark.octagon.fill"
        case .atStop: return "mappin.circle.fill"
        case .onBoard: return "tram.fill"
        }
    }

    @ViewBuilder
    private func actions(_ live: CommuteSession.LiveLeg) -> some View {
        HStack(spacing: 10) {
            Button(action: onStop) {
                Text("Stop").frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(.white.opacity(0.1), in: Capsule())
            }
            Button { session.reportMissed() } label: {
                Text(riding ? "Missed change?" : "I missed it").frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(HSLColor.red.opacity(0.85), in: Capsule())
            }
            if riding {
                Button { session.skipLeg() } label: {
                    Text("I got off").frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(HSLColor.blue, in: Capsule())
                }
            } else {
                Button { session.confirmOnBoard() } label: {
                    Text("I'm on it").frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(HSLColor.green, in: Capsule())
                }
            }
        }
        .font(HSLFont.body(15))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .buttonStyle(.plain)
    }

    private var arrivedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "flag.checkered").font(.largeTitle)
            Text("Almost there: walk to \(session.destinationName)").font(HSLFont.title(18))
            Button(action: onStop) {
                Text("Done").frame(maxWidth: .infinity).padding(.vertical, 14).background(HSLColor.blue, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The coloured card: line badge with its seat light, headsign, and the whole trip as a timeline.
struct RouteCard: View {
    let session: CommuteSession
    let live: CommuteSession.LiveLeg
    var onStop: () -> Void

    var body: some View {
        let color = HSLColor.mode(live.mode)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LineBadge(live.line, mode: live.mode, showsIcon: true, size: 15)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                if let seat = session.fullness(for: live)?.level { SeatLight(seat, size: 13) }
                Spacer()
                Button(action: onStop) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30).background(.black.opacity(0.25), in: Circle())
                }
                .buttonStyle(.plain)
            }
            Text("Heading to").font(HSLFont.caption()).opacity(0.85)
            Text(live.headsign).font(HSLFont.display(30)).lineLimit(1).minimumScaleFactor(0.6)
            TripTimeline(session: session)
                .padding(12)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(16)
        .background(
            LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// Kilta 19:02 ── Kerava 19:20 ── Helsinki 20:00
/// Arrivals in white; start times and waits at the changes in gray. Live estimates when we have them.
struct TripTimeline: View {
    let session: CommuteSession

    struct Node: Identifiable {
        var id: Int
        var name: String
        var arrive: Date?
        var depart: Date?
        var walk: TimeInterval = 0
        var passed = false
    }

    struct Segment {
        var line: String
        var mode: TransitMode
        var current: Bool
        var done: Bool
    }

    private var model: (nodes: [Node], segments: [Segment]) {
        let legs = session.itinerary.legs
        let transit = legs.indices.filter { legs[$0].mode.isTransit }
        var nodes: [Node] = []
        var segments: [Segment] = []
        let focus = session.focusLeg?.index
        let arrived: Bool = { if case .arrived = session.phase { return true }; return false }()
        for (k, i) in transit.enumerated() {
            let leg = legs[i]
            let live = session.legs[i]
            let depart = live?.boardingETA?.expected ?? leg.start
            let arrive = live?.alightingETA?.expected ?? leg.end
            let done = arrived || (focus.map { i < $0 } ?? false)
            if k == 0 {
                nodes.append(Node(id: i, name: leg.from.name, depart: depart, passed: done || focus.map { i < $0 || isRiding($0) } == true))
            } else {
                nodes[nodes.count - 1].depart = depart
                let prev = transit[k - 1]
                nodes[nodes.count - 1].walk = legs[(prev + 1)..<i].filter { !$0.mode.isTransit }.map(\.duration).reduce(0, +)
            }
            segments.append(Segment(line: live?.line ?? leg.route?.shortName ?? leg.mode.displayName, mode: leg.mode,
                                    current: focus == i, done: done))
            nodes.append(Node(id: i + 10_000, name: leg.to.name, arrive: arrive, passed: done))
        }
        return (nodes, segments)
    }

    private func isRiding(_ i: Int) -> Bool {
        if case .riding(let r) = session.phase { return r == i }
        return false
    }

    var body: some View {
        let m = model
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(m.nodes.enumerated()), id: \.element.id) { k, node in
                    if k > 0 { connector(m.segments[k - 1]) }
                    nodeView(node, first: k == 0, last: k == m.nodes.count - 1)
                }
            }
        }
    }

    private func nodeView(_ node: Node, first: Bool, last: Bool) -> some View {
        VStack(alignment: first ? .leading : (last ? .trailing : .center), spacing: 2) {
            Circle()
                .fill(node.passed ? Color.white.opacity(0.4) : .white)
                .frame(width: 12, height: 12)
                .frame(height: 24)
            Text(node.name).font(HSLFont.caption(13)).foregroundStyle(.white).lineLimit(1)
            if let arrive = node.arrive {
                Text(time(arrive)).font(HSLFont.number(15)).foregroundStyle(.white)
            }
            if let depart = node.depart {
                if let arrive = node.arrive {
                    let wait = max(depart.timeIntervalSince(arrive) - node.walk, 0)
                    Text("dep \(time(depart))").font(HSLFont.caption(12)).foregroundStyle(.gray)
                    HStack(spacing: 3) {
                        if node.walk >= 60 {
                            Image(systemName: "figure.walk")
                            Text("\(Int(node.walk / 60))")
                        }
                        Text("wait \(Int((wait / 60).rounded())) min")
                    }
                    .font(HSLFont.caption(11)).foregroundStyle(.gray)
                } else {
                    Text(time(depart)).font(HSLFont.number(15)).foregroundStyle(.gray)
                }
            }
        }
        .fixedSize()
    }

    private func connector(_ seg: Segment) -> some View {
        ZStack {
            Capsule().fill(HSLColor.mode(seg.mode).opacity(seg.done ? 0.35 : 1))
                .frame(height: seg.current ? 5 : 3)
            LineBadge(seg.line, mode: seg.mode, showsIcon: true, size: 11)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(seg.current ? 0.9 : 0), lineWidth: 1.5))
                .opacity(seg.done ? 0.5 : 1)
        }
        .frame(minWidth: 70, maxWidth: .infinity)
        .frame(height: 24)
        .padding(.horizontal, 4)
    }

    private func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}


/// "How full is 550?" asked now and then while you ride. One tap, shared with other riders.
struct OccupancyAskCard: View {
    let session: CommuteSession
    let live: CommuteSession.LiveLeg

    var body: some View {
        if session.occupancyThanks {
            Label("Thanks! That helps other riders.", systemImage: "heart.fill")
                .font(HSLFont.body(14))
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(HSLColor.green.opacity(0.25), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.opacity)
        } else if session.occupancyAskLeg == live.index {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("How full is \(live.line)?").font(HSLFont.title(17))
                    Spacer()
                    Button { session.dismissOccupancyAsk() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).opacity(0.6)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    ForEach(CrowdLevel.allCases, id: \.self) { level in
                        Button { session.answerOccupancy(level) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: Occupancy.symbol(level)).font(.system(size: 18, weight: .semibold))
                                Text(level.title).font(HSLFont.caption(13))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Occupancy.color(level).opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(Occupancy.color(level))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
