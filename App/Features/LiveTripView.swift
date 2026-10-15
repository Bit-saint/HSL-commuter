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

        if let live = session.focusLeg {
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
                                VehicleMarker(mode: live.mode, line: live.line,
                                              heading: live.tracker?.displayHeading(at: now) ?? 0,
                                              cam: cam, isFocus: session.focusLeg?.index == i)
                            }
                            .annotationTitles(.hidden)
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
                LineBadge(line, mode: mode, showsIcon: false, size: 12)
                if isFocus {
                    Circle().stroke(.white, lineWidth: 3).background(Circle().fill(HSLColor.green))
                        .frame(width: 16, height: 16)
                    Rectangle().fill(.white).frame(width: 2, height: 14)
                }
            }
            .offset(y: -max(side * 0.18, 28) - (isFocus ? 18 : 0))
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
            if let live = session.focusLeg {
                RouteCard(session: session, live: live, onStop: onStop)
                etaRow(live)
                paceBanner(live)
                tiles(live)
                if session.missedLeg != nil {
                    Button(action: onReplan) {
                        Label("Find the next option", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(HSLColor.red, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
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
                    Text(pace.message(now: session.now)).font(HSLFont.caption()).opacity(0.9)
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
    private func tiles(_ live: CommuteSession.LiveLeg) -> some View {
        let occ = Occupancy.label(live.tracker?.occupancyPercent)
        HStack(spacing: 8) {
            InfoTile("How full", dot: occ.1) {
                Text(occ.0).font(HSLFont.title(18)).foregroundStyle(occ.1)
                if let p = live.tracker?.occupancyPercent {
                    Text("\(p)% full").font(HSLFont.caption(11)).foregroundStyle(.secondary)
                }
            }
            InfoTile("Speed") {
                Text("\(Int(((live.tracker?.currentSpeed ?? 0) * 3.6).rounded()))").font(HSLFont.title(18))
                Text("km/h").font(HSLFont.caption(11)).foregroundStyle(.secondary)
            }
            InfoTile("Arrive") {
                let end = live.alightingETA?.expected ?? live.leg.end
                Text(end.formatted(date: .omitted, time: .shortened)).font(HSLFont.title(18))
                Text(live.leg.to.name).font(HSLFont.caption(11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func actions(_ live: CommuteSession.LiveLeg) -> some View {
        HStack(spacing: 10) {
            Button(action: onStop) {
                Text("Stop").frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(.white.opacity(0.1), in: Capsule())
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
        .font(HSLFont.body())
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

/// The green card from the reference design: line badge, headsign, progress, origin.
struct RouteCard: View {
    let session: CommuteSession
    let live: CommuteSession.LiveLeg
    var onStop: () -> Void

    var body: some View {
        let color = HSLColor.mode(live.mode)
        let progress = session.progress(for: live)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LineBadge(live.line, mode: live.mode, showsIcon: true, size: 15)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                Button(action: onStop) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30).background(.black.opacity(0.25), in: Circle())
                }
                .buttonStyle(.plain)
            }
            Text("Heading to").font(HSLFont.caption()).opacity(0.85)
            Text(live.headsign).font(HSLFont.display(30)).lineLimit(1).minimumScaleFactor(0.6)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3)).frame(height: 5)
                    Capsule().fill(.white).frame(width: geo.size.width * progress, height: 5)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .overlay(Circle().fill(color).frame(width: 8, height: 8))
                        .offset(x: max(geo.size.width * progress - 8, 0))
                }
                .animation(.linear(duration: 1), value: progress)
            }
            .frame(height: 16)
            HStack {
                Text("from \(live.leg.from.name)").font(HSLFont.caption(12))
                Spacer()
                Text("to \(live.leg.to.name)").font(HSLFont.caption(12)).underline()
            }
            .opacity(0.9)
        }
        .padding(16)
        .background(
            LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
