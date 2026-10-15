# HSL Commuter — Product & Technical Plan

An iOS app for commuters in the Helsinki region (HSL area). It tells you **exactly when your vehicle will actually reach your stop**, based on where the vehicle is right now, and what to do about it: *relax*, *start walking*, *walk faster*, *run*, or *you'll miss it, take the next one*. You get this in Live Activities, widgets and notifications, and the in-app map shows HSL-styled 3D vehicles.

> Status: planning. No code yet.

---

## 1. Problem & goals

| Problem | Goal |
|---|---|
| Journey planner times are schedule-based, or the realtime estimates lag reality | Our own ETA, computed from live vehicle positions (HFP) |
| People wait at stops "just in case" | Tell the user **when to leave**, not just when the bus departs |
| Transfers are stressful: "will I make my connection?" | Check every transfer against live data and warn early |
| Checking the app over and over | Glanceable Live Activity / Dynamic Island / widget / watch |

**Core user story:** *"I commute Home → Work every weekday. At 07:40 my lock screen says: 'Bus 551 at Stop X in 6 min. Start walking in 2 min, normal pace.' At the transfer it says: 'Metro M1 in 3 min. Walk briskly, 250 m.'"*

### Non-goals (v1)
- Ticket purchase (the HSL app does this; we can deep-link to it).
- Full journey-planner replacement for one-off trips. Commute-first, ad-hoc trips later.

---

## 2. Data sources (all open data)

| Source | What | Protocol | Auth |
|---|---|---|---|
| **Digitransit Routing API v2** (`https://api.digitransit.fi/routing/v2/hsl/gtfs/v1`) | Itineraries (`planConnection`), stops, routes, patterns, route geometry, stop times incl. `realtimeArrival` / `realtimeState` | GraphQL (HTTPS) | `digitransit-subscription-key` header (free registration at portal-api.digitransit.fi) |
| **HSL High-Frequency Positioning (HFP)** (`mqtts://mqtt.hsl.fi:8883`, `wss://mqtt.hsl.fi:443/`) | ~1 Hz vehicle positions plus events: `vp`, `due`, `arr`, `dep`, `ars`, `pde`, `pas`, `doo`/`doc` (doors), `wait`… Fields: `lat`, `long`, `spd` (m/s), `hdg`, `dl` (schedule offset, s), `occu`, `stop`, `drst`, `oday`, `start`, `route`, `dir` | MQTT topics `/hfp/v2/journey/ongoing/{event}/{mode}/{oper}/{veh}/{route}/{dir}/{headsign}/{start}/{next_stop}/{geohash…}/#` | None |
| **HSL GTFS-Realtime** (`realtime.hsl.fi/realtime/{trip-updates,vehicle-positions,service-alerts}/v2/hsl`) | Trip updates, alerts (disruptions) | Protobuf over HTTPS | None |
| **Fintraffic Digitraffic rail** (`rata.digitraffic.fi`, MQTT + REST) | Commuter trains: live GPS, actual passage times per station, track numbers, cancellations | MQTT/WebSocket + REST | None (set the `Digitraffic-User` header) |
| **Apple MapKit** | Base map, 3D/realistic elevation, walking directions (`MKDirections`) | SDK | None |

**Coverage caveats to verify in Phase 0:**
- **Buses & trams:** full HFP coverage. This is our strongest signal.
- **Metro:** HFP has metro events, but positions are coarser (station/track-section based). ETA leans on events plus scheduled run times.
- **Commuter trains:** HFP train data is limited. Use **Digitraffic** as the primary train source.
- **Ferries:** use Digitransit realtime only.

---

## 3. The "true ETA" engine (the core IP)

Pure Swift package `ETAEngine` with no iOS dependencies, so it can be unit-tested and reused on the backend.

### 3.1 Matching an itinerary leg to a live vehicle
1. Digitransit leg → `trip.gtfsId` (e.g. `HSL:1055_20261015_Ti_2_0715`), `route.gtfsId`, `directionId`, `serviceDay`, first-stop scheduled departure.
2. Map to the HFP topic filter: `route = 1055`, `dir = directionId + 1` (HFP uses 1/2, GTFS uses 0/1), `start = 07:15`, `oday = 2026-10-15`.
3. Subscribe to `/hfp/v2/journey/ongoing/+/+/+/+/1055/2/+/07:15/#`. Only that one vehicle's messages arrive, which keeps it cheap.
4. If the trip hasn't started yet (vehicle on a previous trip / at the depot), track the **previous block trip** where possible. Otherwise fall back to the Digitransit realtime estimate with low confidence.

### 3.2 Estimating arrival at the user's stop
```
ETA = now + Σ (remaining segment travel times) + Σ (expected dwell at intermediate stops) + signal/terminal holds
```
- **Position → progress:** project the GPS point onto the pattern polyline (`pattern.geometry`) to get *distance along route*. Smooth with a 1D Kalman filter (state = distance, speed) to reject GPS jumps and `loc != GPS` fixes.
- **Segment times:** for each stop-to-stop segment, keep a running estimate of travel time by time-of-day bucket. It starts from the schedule and learns from observed `dep`→`arr` HFP events, on device first and later on the backend across all users.
- **Dwell:** `pde`/`doo`/`doc` events tell us whether the vehicle is still at a stop. Expected dwell per stop comes from history. Timing points (`tlr`/`tla` events, `wait`) mean the vehicle won't leave early, so clamp to the scheduled departure at timing stops.
- **Blend:** final ETA = weighted blend of (a) our model, (b) Digitransit `realtimeArrival`, (c) schedule + current `dl`. The weights depend on data freshness and distance (far away: trust the schedule more; close: trust physics more).
- **Output:** `ETA`, **confidence interval** (P10–P90), `freshness` (age of last fix), `source`. The UI shows "4 min" when confident and "4–6 min" when not.

### 3.3 "Do I need to hurry?" — pace advisor
Inputs: user location (CoreLocation), walking route to the boarding stop (MapKit walking directions, cached per stop), vehicle ETA distribution, and the user's **personal walking speed** (calibrated from CoreMotion pedometer / HealthKit `walkingSpeed`, default 1.35 m/s).

```
required_speed = walk_distance / (ETA_P10 − now − safety_buffer)
```
`P10` is the pessimistic case where the vehicle comes early. `safety_buffer` is 30 s by default, 60 s for trains (doors close early).

| State | Rule (relative to personal speed v) | Message |
|---|---|---|
| 🟢 **Wait** | leave_time > now + 1 min | "Leave in 3 min" |
| 🔵 **Go now** | leave_time within 1 min | "Start walking now" |
| 🟡 **Walk briskly** | required ≤ 1.3·v | "Walk briskly — 240 m" |
| 🟠 **Run** | required ≤ 2.2·v (≈ jogging) | "Run! 1 min margin" |
| 🔴 **Miss** | above that | "You'll miss it. Next: 551 in 12 min" (+ re-plan) |

Hysteresis keeps it from flickering between states.

### 3.4 Transfer guard
For every transfer in the commute: `slack = next_leg_ETA(departure) − (prev_leg_ETA(arrival) + transfer_walk_time)`. If slack < 0 for the realistic case, alert early (while still on the first vehicle) and offer the best alternative from a fresh `planConnection` query.

### 3.5 "When should I leave home?"
For the saved commute, evaluate the next N departures of the first leg. Pick the one that minimises *total time standing at stops* while still arriving by the user's target time, and schedule the "leave now" alert from the live ETA instead of the timetable.

---

## 4. iOS app architecture

- **Target:** iOS 17+ (SwiftUI `Map` with `MapCamera`, Observation framework, interactive widgets, modern ActivityKit). Swift 6, strict concurrency.
- **Structure:** Xcode project + local Swift packages:

```
HSLCommuter.xcodeproj
├─ App/                       SwiftUI app (features, navigation)
├─ Widgets/                   WidgetKit + Live Activity extension
├─ Packages/
│  ├─ HSLKit/                 Digitransit GraphQL client, HFP MQTT client, GTFS-RT, Digitraffic rail
│  ├─ ETAEngine/              Pure Swift: matching, Kalman, segment model, pace advisor, transfer guard
│  ├─ CommuteCore/            Saved commutes, scheduling, persistence (SwiftData), shared App Group store
│  └─ HSLDesign/              Colors, typography, mode icons, vehicle sprites, reusable components
└─ Backend/ (phase 6)         Swift (Vapor) push service
```

- **Networking:** plain `URLSession` + `Codable` for GraphQL (small query set, no Apollo needed). MQTT via **CocoaMQTT** or **mqtt-nio** over WebSocket.
- **State:** `@Observable` view models; `CommuteSession` actor owns the live subscriptions while a commute is active.
- **Persistence:** SwiftData for saved commutes/places, plus an App Group container for sharing with widgets.

### 4.1 Screens
1. **Onboarding:** location permission, notifications, set Home & Work (MapKit search), usual arrival time and days.
2. **Today (home):** next recommended departure, big "Leave in X min" card, pace state, transfer timeline.
3. **Live trip / map (the screenshot-style screen):** 3D map following your vehicle, bottom sheet with line badge, "Heading to …", progress bar, next stop, **true ETA**, occupancy (`occu` → "Seats / Standing / Full"), speed, arrival time.
4. **Stop board:** departures from nearby stops with true ETAs.
5. **Commutes:** manage multiple commutes (work, gym, kid's school).
6. **Settings:** walking speed calibration, buffers, notification styles.

---

## 5. Notifications, widgets & Live Activities

| Surface | Use | Realtime? |
|---|---|---|
| **Live Activity + Dynamic Island** | The main glanceable surface: line badge, minutes, pace state, progress bar | Yes, updated by the app while it runs (active commute) or by **ActivityKit push** from the backend |
| **Time-sensitive notifications** | "Leave in 2 min", "Run!", "Connection at risk", "Disruption on your line" | Yes, local, or remote from the backend |
| **Home/Lock-screen widgets** | Next departure for saved commute; countdown via `Text(timerInterval:)` | Partly: timeline budget is limited (~40–70 reloads/day), so countdown is local and data is refreshed opportunistically |
| **Apple Watch** (later) | Complication + haptic "run" tap | Phase 7 |

**Key iOS constraint:** the app cannot keep an MQTT socket open in the background indefinitely. Strategy:
- **During an active commute** (user tapped "Start" or geofence/schedule triggered it), run as a navigation-style session with background location updates. This keeps the app alive while you're walking/riding, so the HFP connection and local Live Activity updates work **without a backend**. This is enough for the MVP.
- **Before the commute** (the "leave in 5 min" phase while the phone is idle), you need **server push**. The backend watches HFP for subscribed trips and sends ActivityKit push updates and time-sensitive alerts (Phase 6).

---

## 6. Map & 3D vehicles

- **MapKit (SwiftUI `Map`)** with `.standard(elevation: .realistic, emphasis: .muted)`, pitched `MapCamera` (60–70°) that follows the vehicle with heading, buildings in 3D. Route polyline in the mode colour; stops as small HSL stop markers.
- **Vehicle rendering:** MapKit cannot place real 3D models on the map. Options:
  1. **Recommended (MVP):** model HSL vehicles (bus in blue livery, articulated bus, Artic tram, M300 metro, Sm5 train, ferry) once in Blender/Reality Composer. Pre-render each into **sprite sheets at 32–64 headings × 2–3 pitch angles**. Pick the frame from `vehicle.heading − camera.heading` and camera pitch, and draw it as an `Annotation`. It looks 3D, is cheap on battery, and is pure MapKit.
  2. **Upgrade:** live RealityKit/SceneKit layer synced to the MapKit camera. Hard to keep in sync; experimental.
  3. **Alternative engine:** Mapbox Maps SDK v11 supports true glTF **model layers** (the style in the reference screenshot). That means leaving Apple Maps, so it's a fallback if option 1 doesn't look good enough.
- **Animation:** interpolate between 1 Hz HFP fixes along the route polyline (dead-reckoning with `spd`), so vehicles glide instead of jumping.

---

## 7. HSL visual style

- **Colours** (from HSL's public design system; verify against current brand guidelines):
  HSL blue `#007AC9` (bus), tram green `#00985F`, metro orange `#FF6319`, commuter train purple `#8C4799`, ferry cyan `#00B9E4`, city bikes yellow `#F2B62D`, trunk-line bus orange.
- **Typography:** HSL uses *Gotham Rounded*, which is commercially licensed. Use **SF Pro Rounded** unless we license Gotham.
- **Iconography:** HSL-style mode pictograms and line badges (rounded rectangle, mode colour, white number).
- **Dark mode first** for the live view (like the screenshot), light mode supported.
- ⚠️ **Branding/legal:** HSL's name, logo and livery are trademarks. For personal use this is fine. **Publishing to the App Store as "official"-looking requires HSL's permission.** Otherwise we ship as "HSL-styled", with a different name/logo and attribution ("Data: HSL & Digitransit, CC BY 4.0").

---

## 8. Backend (Phase 6)

Small Swift (Vapor) or Go service:
- Registers user's upcoming commute trips plus ActivityKit push tokens and APNs device tokens.
- One shared HFP subscription per active trip (deduplicated across users), running the **same `ETAEngine` package**.
- Sends Live Activity updates (budget-aware: only when the minute or pace state changes) and time-sensitive alerts.
- Aggregates anonymous segment travel times to improve the model for everyone.
- Proxies the Digitransit key so it isn't shipped in the app.
- Hosting: one small container (Fly.io / Hetzner in Helsinki for low latency to mqtt.hsl.fi).

---

## 9. Roadmap

| Phase | Deliverable | Notes |
|---|---|---|
| **0. Spike** (≈1 wk) | Digitransit key; CLI that plans Home→Work, matches legs to HFP, prints live ETA vs Digitransit vs actual | Validates the core idea and metro/train coverage |
| **1. Data layer** | `HSLKit`: GraphQL queries, HFP client, Digitraffic client, models + tests | |
| **2. ETA engine v1** | Matching, polyline projection, Kalman, schedule-based segment model, pace advisor, transfer guard | Pure Swift, heavily unit-tested with recorded HFP fixtures |
| **3. App MVP** | Onboarding, saved commute, Today screen, live trip sheet (2D map) | |
| **4. Live Activity + notifications** | Dynamic Island, lock screen, local time-sensitive alerts during active session | **First usable release (TestFlight)** |
| **5. 3D map** | Pitched follow camera, HSL vehicle sprites, smooth interpolation | |
| **6. Backend push** | Pre-commute "leave now" while app is closed, learned segment times | |
| **7. Polish** | Widgets, Apple Watch, Siri/App Intents ("When's my bus?"), disruption alerts, accessibility, Finnish/Swedish/English | |

### Success metrics
- ETA error at T−5 min: median < 30 s, P90 < 90 s (measure ours vs Digitransit estimate vs actual `arr`/`dep` event).
- "Missed it" rate for users who followed the pace advice: < 5 %.
- Average wait at the first stop: < 2 min.

---

## 10. Open questions

1. **Minimum iOS version:** iOS 17 (broader reach) or iOS 18 (newer MapKit/widget APIs)?
2. **Backend:** OK to run a small server from Phase 6 on, or should we stay device-only (no "leave now" pushes while the app is closed)?
3. **Branding:** personal project / TestFlight only, or App Store? If App Store, do we contact HSL about using the brand?
4. **3D vehicles:** happy with the MapKit + pre-rendered sprite approach, or is true 3D important enough to consider Mapbox?
5. **Scope of modes for MVP:** bus + tram + metro first, trains (Digitraffic) in a follow-up?
6. **Apple Watch** in v1 or later?

## 11. Practical notes
- iOS builds and the simulator need **Xcode on macOS**. `HSLKit` and `ETAEngine` are pure Swift packages, so they can be built and tested on Linux/CI too.
- Attribution required: HSL/Digitransit open data is CC BY 4.0; Digitraffic is CC BY 4.0.
