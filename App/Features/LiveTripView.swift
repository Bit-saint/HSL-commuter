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
    @State private var expanded = false
    @State private var panelExpanded = true
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        GeometryReader { geo in
            if hSize == .regular && geo.size.width > 700 {
                // iPad: trip panel beside the map, whole timeline visible.
                HStack(spacing: 0) {
                    ScrollView {
                        sheet(expanded: $panelExpanded, grabber: false)
                            .padding(.top, 8)
                    }
                    .frame(width: min(440, geo.size.width * 0.42))
                    .background(HSLColor.surface.ignoresSafeArea())
                    mapLayer
                }
            } else {
                // Phone: bottom sheet that scrolls when the timeline is opened up.
                ZStack(alignment: .bottom) {
                    mapLayer
                    ViewThatFits(in: .vertical) {
                        sheet(expanded: $expanded, grabber: true)
                        ScrollView { sheet(expanded: $expanded, grabber: true) }
                            .scrollBounceBehavior(.basedOnSize)
                    }
                    .frame(maxHeight: geo.size.height * 0.68)
                    .background(HSLColor.surface, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                }
            }
        }
        .background(Color.black)
        .onChange(of: session.tick) { _, _ in updateCamera() }
        .onChange(of: is3D) { _, _ in follow = true; updateCamera(animated: true) }
        .onChange(of: follow) { _, on in if on { updateCamera(animated: true) } }
    }

    private var mapLayer: some View {
        ZStack(alignment: .topTrailing) {
            TripMapView(session: session, camera: $camera, is3D: is3D, cam: $cam)
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in follow = false })
                .ignoresSafeArea()
            VStack(alignment: .trailing, spacing: 10) {
                if let replay = session.replay { DemoControls(replay: replay) }
                MapButtons(is3D: $is3D, follow: $follow)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private func sheet(expanded: Binding<Bool>, grabber: Bool) -> some View {
        LiveTripSheet(session: session, expanded: expanded, showsGrabber: grabber,
                      onStop: { app.stopSession() }, onReplan: { Task { await app.replan() } })
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
                // Show the approaching vehicle and your stop, once it's near.
                let stop = live.leg.from.location
                if let v = live.tracker?.displayLocation(at: now), v.distance(to: stop) < 3_000 {
                    center = GeoPoint(latitude: (v.latitude + stop.latitude) / 2, longitude: (v.longitude + stop.longitude) / 2)
                    distance = min(max(v.distance(to: stop) * 2.2, 500), 6_000)
                    heading = v.bearing(to: stop)
                } else {
                    center = stop
                }
            case .walking:
                // The whole way from where you are to the stop, looking towards the stop.
                let stop = live.leg.from.location
                let path = session.walkPath(before: live.index)
                let me = session.userLocation.map { GeoPoint($0.coordinate) } ?? path.first ?? stop
                let fit = fitCamera([me, stop] + path)
                center = fit.center
                distance = min(max(fit.span * 2.2, 450), 5_000)
                heading = me.distance(to: stop) > 30 ? me.bearing(to: stop) : heading
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

/// Demo playback: pause, speed and skip ahead.
struct DemoControls: View {
    let replay: TripReplay

    var body: some View {
        HStack(spacing: 12) {
            Text("DEMO").font(.system(size: 11, weight: .heavy, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(HSLColor.orange, in: Capsule())
            Button { replay.togglePause() } label: {
                Image(systemName: replay.paused ? "play.fill" : "pause.fill")
            }
            .accessibilityLabel(replay.paused ? Text("Play") : Text("Pause"))
            Menu {
                ForEach(TripReplay.speeds, id: \.self) { s in
                    Button("\(Int(s))×") { replay.setSpeed(s) }
                }
            } label: {
                Text("\(Int(replay.speed))×").monospacedDigit()
            }
            Button { replay.skip(60) } label: { Image(systemName: "goforward.60") }
                .accessibilityLabel(Text("Skip a minute"))
        }
        .font(HSLFont.caption(14))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Centre and size (m) of the box around some points.
private func fitCamera(_ pts: [GeoPoint]) -> (center: GeoPoint, span: Double) {
    let lats = pts.map(\.latitude), lons = pts.map(\.longitude)
    guard let a = lats.min(), let b = lats.max(), let c = lons.min(), let d = lons.max() else {
        return (pts.first ?? GeoPoint(latitude: 60.17, longitude: 24.94), 500)
    }
    let span = GeoPoint(latitude: a, longitude: c).distance(to: GeoPoint(latitude: b, longitude: d))
    return (GeoPoint(latitude: (a + b) / 2, longitude: (c + d) / 2), span)
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
            let now = session.replay?.now ?? timeline.date
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
    @Binding var expanded: Bool
    var showsGrabber = true
    var onStop: () -> Void
    var onReplan: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if showsGrabber { Capsule().fill(.white.opacity(0.3)).frame(width: 40, height: 5) }
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
                NextStepCard(session: session, live: live)
                RouteCard(session: session, onStop: onStop, expanded: $expanded)
                OccupancyAskCard(session: session, live: live)
                actions(live)
            } else {
                arrivedView
            }
        }
        .padding(14)
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

/// What to do next, first: when to leave, which stop to walk to and when to be there.
/// While riding: where and when to get off. No minute ranges, no speeds.
struct NextStepCard: View {
    let session: CommuteSession
    let live: CommuteSession.LiveLeg

    private var riding: Bool { if case .riding = session.phase { return true }; return false }
    private var now: Date { session.now }

    var body: some View {
        if riding { ridingView } else { boardingView }
    }

    // MARK: Walking to / waiting at the stop

    private var boardingView: some View {
        let state = session.pace?.state ?? .relax
        let atStop = state == .atStop || { if case .waiting = session.phase { return true }; return false }()
        let fg: Color = state == .walkBriskly ? .black : .white
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: atStop ? "mappin.circle.fill" : icon(state)).font(.system(size: 22, weight: .bold))
                Text(atStop ? "At \(live.leg.from.name)" : title(state)).font(HSLFont.title(22)).lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                if !atStop, let leave = session.pace?.leaveAt, leave.timeIntervalSince(now) >= 60,
                   state == .relax || state == .leaveSoon {
                    Text("in \(Int(leave.timeIntervalSince(now) / 60)) min").font(HSLFont.body(15)).opacity(0.85)
                }
            }
            if !atStop {
                // Where to go.
                HStack(spacing: 6) {
                    Image(systemName: "figure.walk")
                    Text(walkLine).lineLimit(1).minimumScaleFactor(0.8)
                }
                .font(HSLFont.body(15))
            }
            HStack(spacing: 6) {
                LineBadge(live.line, mode: live.mode, size: 13)
                Text("→ \(live.headsign)").font(HSLFont.body(15)).lineLimit(1)
                if let seat = session.fullness(for: live)?.level { SeatLight(seat, size: 11) }
                Spacer(minLength: 4)
                Text(atStop ? departsText : beThereText).font(HSLFont.caption(13)).opacity(0.9)
            }
            if !atStop, let app = indoorsHint {
                Text(app).font(HSLFont.caption(12)).opacity(0.85)
            }
            if session.locationIsRough, let acc = session.locationAccuracy {
                Label("Location is approximate (±\(Int(acc.rounded())) m), so walking times are rough",
                      systemImage: "location.slash")
                    .font(HSLFont.caption(12)).opacity(0.9)
            }
        }
        .padding(14)
        .foregroundStyle(atStop ? Color.white : fg)
        .background(atStop ? Color.white.opacity(0.08) : HSLColor.pace(state),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.snappy, value: state)
    }

    private func title(_ state: PaceState) -> String {
        switch state {
        case .relax, .leaveSoon:
            if let leave = session.pace?.leaveAt { return "Leave at \(CommuteSession.clock(leave))" }
            return "Leave soon"
        case .goNow: return "Start walking now"
        case .walkBriskly: return "Walk briskly"
        case .run: return "Run"
        case .willMiss: return "You won't make this one"
        case .atStop: return "At the stop"
        case .onBoard: return "On board"
        }
    }

    private var walkLine: String {
        let d = session.walkDistance ?? session.plannedWalk(before: live.index)
        let dist = d >= 1000 ? String(format: "%.1f km", d / 1000) : "\(Int((d / 10).rounded()) * 10) m"
        var text = session.locationIsRough
            ? String(localized: "Walk about \(dist) to \(live.leg.from.name)")
            : String(localized: "Walk \(dist) to \(live.leg.from.name)")
        if let p = live.platform { text += live.mode == .rail ? " · track \(p)" : " · platform \(p)" }
        return text
    }

    private var beThereText: String {
        guard let by = session.boardBy else { return "" }
        return "be there by \(CommuteSession.clock(by))"
    }

    private var departsText: String {
        guard let eta = live.boardingETA, !eta.isPassed else { return "" }
        let mins = Int(eta.expected.timeIntervalSince(now) / 60)
        let platform = live.platform.map { live.mode == .rail ? "track \($0) · " : "platform \($0) · " } ?? ""
        return platform + "leaves \(CommuteSession.clock(eta.expected))" + (mins < 10 ? " (\(max(mins, 0)) min)" : "")
    }

    private var indoorsHint: String? {
        guard let state = session.pace?.state, state == .relax || state == .leaveSoon else { return nil }
        return session.paceMessage.hasPrefix("Stay inside") ? "Stay inside until then" : nil
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

    // MARK: On board

    private var ridingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "arrow.down.right.circle.fill").font(.system(size: 22, weight: .bold))
                Text("Get off at \(live.leg.to.name)").font(HSLFont.title(21)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                if let eta = live.alightingETA, !eta.isPassed {
                    Text(CommuteSession.clock(eta.expected)).font(HSLFont.number(20))
                }
            }
            HStack(spacing: 6) {
                LineBadge(live.line, mode: live.mode, size: 13)
                Text("→ \(live.headsign)").font(HSLFont.body(15)).lineLimit(1)
                if let seat = session.fullness(for: live)?.level { SeatLight(seat, size: 11) }
                Spacer(minLength: 4)
                if let next = session.nextStopName(for: live) {
                    Text("next: \(next)").font(HSLFont.caption(12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let t = session.transfer {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.swap")
                    Text(transferText(t)).font(HSLFont.caption(13))
                    Spacer()
                }
                .padding(10)
                .background(transferColor(t.risk).opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(14)
        .foregroundStyle(.white)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func transferText(_ t: TransferAssessment) -> String {
        let mins = Int(t.slack / 60)
        switch t.risk {
        case .comfortable: return "Change OK · \(mins) min to spare"
        case .tight: return "Tight change · under 2 min to spare"
        case .needsHurry: return "Hurry at the change: walk fast"
        case .missed: return "You'll likely miss the change"
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
}

/// Where you're going and the whole trip as a top-to-bottom timeline, walking included.
/// Collapsed it shows the part you're on now; tap to see every stop.
struct RouteCard: View {
    let session: CommuteSession
    var onStop: () -> Void
    @Binding var expanded: Bool

    var body: some View {
        let timeline = TripTimeline.Model(session: session)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heading to").font(HSLFont.caption()).foregroundStyle(.secondary)
                    Text(session.destinationName).font(HSLFont.display(24)).lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer()
                if let arrive = timeline.nodes.last?.arrive {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Arrive").font(HSLFont.caption()).foregroundStyle(.secondary)
                        Text(CommuteSession.clock(arrive)).font(HSLFont.number(22))
                    }
                }
                Button(action: onStop) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30).background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Stop tracking"))
                .padding(.leading, 6)
            }
            TicketRow(itinerary: session.itinerary)
            TripTimeline(model: timeline, expanded: expanded)
            if timeline.canCollapse {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Show less" : "Show whole trip")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .font(HSLFont.caption(13))
                    .foregroundStyle(HSLColor.blue)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Start · leave 7:54
/// ┆ walk 6 min
/// Kauppatori · 8:00 · wait 2 min
/// │ [2] → Olympiaterminaali · dep 8:02 ● live
/// Lasipalatsi · 8:09
/// Arrival and leave times in white; departures and waits in gray, each departure marked live or timetable.
struct TripTimeline: View {
    let model: Model
    var expanded: Bool

    enum Trust { case live, realtime, timetable }

    struct Node {
        var name: String
        var arrive: Date?
        var leave: Date?
        var wait: Int?
        var passed = false
    }

    struct Segment {
        var line: String?
        var mode: TransitMode
        var headsign: String?
        var depart: Date?
        var trust: Trust?
        var minutes: Int
        var current: Bool
        var done: Bool
    }

    struct Model {
        var nodes: [Node] = []
        var segments: [Segment] = []
        /// Index of the segment you're on (or heading for).
        var current = 0

        var canCollapse: Bool { nodes.count > 3 }

        @MainActor
        init(session: CommuteSession) {
            let legs = session.itinerary.legs
            guard !legs.isEmpty else { return }
            let (currentRange, doneBefore): (Range<Int>, Int) = {
                switch session.phase {
                case .walking(let i):
                    let start = (session.transitIndices.last { $0 < i }).map { $0 + 1 } ?? 0
                    return (start..<max(i, start), start)
                case .waiting(let i): return (i..<(i + 1), i)
                case .riding(let i): return (i..<(i + 1), i)
                case .arrived: return (legs.count..<legs.count, legs.count)
                }
            }()
            // Before the first vehicle the trip starts when you leave, not when the plan said.
            let beforeFirst: Bool = {
                if case .walking(let i) = session.phase { return i == session.transitIndices.first }
                return false
            }()
            var t = legs[0].start
            if beforeFirst, let leave = session.pace?.leaveAt { t = leave }
            let startName = legs[0].from.name
            nodes.append(Node(name: startName.isEmpty || startName.lowercased() == "origin"
                              ? String(localized: "Start") : startName,
                              leave: legs[0].mode.isTransit ? nil : t, passed: doneBefore > 0))
            for (i, leg) in legs.enumerated() {
                let done = i < doneBefore
                if leg.mode.isTransit {
                    let live = session.legs[i]
                    let eta = live?.boardingETA
                    let dep = eta?.expected ?? leg.start
                    let arr = live?.alightingETA?.expected ?? leg.end
                    let trust: Trust? = {
                        switch eta?.source {
                        case .liveVehicle?: return .live
                        case .realtimeFeed?: return .realtime
                        case .schedule?: return .timetable
                        case .passed?: return nil
                        case nil: return leg.isRealtime ? .realtime : .timetable
                        }
                    }()
                    if let a = nodes[nodes.count - 1].arrive {
                        nodes[nodes.count - 1].wait = max(Int((dep.timeIntervalSince(a) / 60).rounded()), 0)
                    }
                    segments.append(Segment(line: live?.line ?? leg.route?.shortName ?? leg.mode.displayName,
                                            mode: leg.mode, headsign: live?.headsign ?? leg.headsign, depart: dep,
                                            trust: done ? nil : trust,
                                            minutes: max(Int((arr.timeIntervalSince(dep) / 60).rounded()), 1),
                                            current: currentRange.contains(i), done: done))
                    nodes.append(Node(name: leg.to.name, arrive: arr, passed: done))
                    t = arr
                } else {
                    let arr = t.addingTimeInterval(leg.duration)
                    segments.append(Segment(line: nil, mode: .walk, minutes: max(Int((leg.duration / 60).rounded()), 1),
                                            current: currentRange.contains(i), done: done))
                    let name = i == legs.count - 1 ? session.destinationName : leg.to.name
                    nodes.append(Node(name: name, arrive: arr, passed: done))
                    t = arr
                }
            }
            // The first stop: be there by the boarding time, not when the plan's walk ends.
            if beforeFirst, let first = legs.firstIndex(where: \.mode.isTransit), first > 0, nodes.count > first,
               let by = session.boardBy {
                nodes[first].arrive = by
                if let dep = segments[first].depart {
                    nodes[first].wait = max(Int((dep.timeIntervalSince(by) / 60).rounded()), 0)
                }
            }
            current = segments.firstIndex { $0.current } ?? segments.firstIndex { !$0.done } ?? max(segments.count - 1, 0)
        }
    }

    private enum Row: Identifiable {
        case node(Int), segment(Int), more(Int)
        var id: String {
            switch self {
            case .node(let k): return "n\(k)"
            case .segment(let k): return "s\(k)"
            case .more(let k): return "m\(k)"
            }
        }
    }

    private var rows: [Row] {
        let n = model.segments.count
        var out: [Row] = []
        if expanded || !model.canCollapse {
            for k in 0..<n { out += [.node(k), .segment(k)] }
            out.append(.node(n))
            return out
        }
        // The stretch you're on, the next one, then a summary and where you end up.
        let c = min(model.current, max(n - 1, 0))
        let last = min(c + 1, n - 1)
        for k in c...last { out += [.node(k), .segment(k)] }
        let hidden = n - 1 - last
        if hidden > 0 { out.append(.more(hidden)) }
        out.append(.node(n))
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                switch row {
                case .node(let k): nodeRow(model.nodes[k])
                case .segment(let k): segmentRow(model.segments[k])
                case .more(let count): moreRow(count)
                }
            }
        }
    }

    private func nodeRow(_ node: Node) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(node.passed ? Color.white.opacity(0.4) : .white)
                .frame(width: 12, height: 12)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).font(HSLFont.body(15)).foregroundStyle(node.passed ? .secondary : .primary)
                    .lineLimit(1)
                if let wait = node.wait {
                    Text("wait \(wait) min").font(HSLFont.caption(12)).foregroundStyle(.gray)
                }
            }
            Spacer(minLength: 6)
            if let leave = node.leave {
                Text("leave \(CommuteSession.clock(leave))").font(HSLFont.number(16))
            } else if let arrive = node.arrive {
                Text(CommuteSession.clock(arrive)).font(HSLFont.number(16))
                    .foregroundStyle(node.passed ? .secondary : .primary)
            }
        }
        .padding(.vertical, 3)
    }

    private func segmentRow(_ seg: Segment) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if seg.mode == .walk {
                    VLine().stroke(Color.gray.opacity(seg.done ? 0.4 : 1),
                                   style: StrokeStyle(lineWidth: seg.current ? 3 : 2, lineCap: .round, dash: [2, 5]))
                        .frame(width: 3)
                } else {
                    Capsule().fill(HSLColor.mode(seg.mode).opacity(seg.done ? 0.35 : 1))
                        .frame(width: seg.current ? 6 : 4)
                }
            }
            .frame(width: 22)
            .frame(maxHeight: .infinity)
            if seg.mode == .walk {
                Label("Walk \(seg.minutes) min", systemImage: "figure.walk")
                    .font(HSLFont.caption(13))
                    .foregroundStyle(seg.current ? Color.white : Color.gray)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        LineBadge(seg.line ?? "", mode: seg.mode, showsIcon: true, size: 12)
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .stroke(.white.opacity(seg.current ? 0.9 : 0), lineWidth: 1.5))
                        if let h = seg.headsign {
                            Text("→ \(h)").font(HSLFont.caption(13)).lineLimit(1)
                        }
                        Text("\(seg.minutes) min").font(HSLFont.caption(12)).foregroundStyle(.gray)
                    }
                    if let dep = seg.depart, !seg.done {
                        HStack(spacing: 5) {
                            Text("dep \(CommuteSession.clock(dep))").font(HSLFont.caption(12)).foregroundStyle(.gray)
                            if let trust = seg.trust { TrustMark(trust: trust) }
                        }
                    }
                }
                .opacity(seg.done ? 0.5 : 1)
                .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func moreRow(_ count: Int) -> some View {
        HStack(spacing: 10) {
            VLine().stroke(Color.gray, style: StrokeStyle(lineWidth: 2, dash: [1, 4]))
                .frame(width: 2).frame(width: 22).frame(maxHeight: .infinity)
            Text("\(count) more", comment: "Collapsed timeline: number of further trip parts")
                .font(HSLFont.caption(12)).foregroundStyle(.gray)
                .padding(.vertical, 6)
            Spacer()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// "● live" (vehicle position), "● realtime" (HSL's prediction) or "timetable".
struct TrustMark: View {
    var trust: TripTimeline.Trust

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var label: LocalizedStringKey {
        switch trust {
        case .live: return "live"
        case .realtime: return "realtime"
        case .timetable: return "timetable"
        }
    }

    private var color: Color {
        switch trust {
        case .live: return HSLColor.green
        case .realtime: return Color(hex: 0x7FC8F8)
        case .timetable: return .gray
        }
    }
}

private struct VLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
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
