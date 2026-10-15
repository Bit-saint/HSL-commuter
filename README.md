# HSL Commuter

A personal iOS 18 app for commuting in the Helsinki region. It computes **when your bus, tram, metro, train or ferry actually reaches your stop**, from the vehicle's live position. It also tells you whether to **relax, start walking, walk briskly, run, or give up and take the next one**: on a Live Activity, in the Dynamic Island, in widgets and through alerts. The live view follows your vehicle on a 3D Apple Maps view, with HSL-styled 3D vehicles.

See [PLAN.md](PLAN.md) for the design.

## Features

- **Arrival estimates from live vehicle positions.** HSL's high-frequency positioning feed (HFP) sends roughly one GPS fix per second per vehicle. The app projects each fix onto the route, smooths it with a filter, and adds stop-to-stop running times it learns on the device. Dwell times and timing points (where an early vehicle waits for the timetable) are included. The result is blended with Digitransit's own realtime estimate and shown as a range ("4–6 min") when the app is uncertain.
- **Pace advice.** The app uses your walking distance (MapKit walking route) and your personal walking speed, which it learns while you walk. The states are: relax, leave soon, start walking, walk briskly, run, or you'll miss it.
- **Transfer guard.** While you're on the first vehicle, the app checks whether you'll make the next one and warns you early.
- **Departure picker.** Ranks options to minimise time spent standing at stops while still arriving on time.
- **Live Activity and Dynamic Island**, with a countdown that keeps ticking without any server.
- **"Leave now" reminders** using local notifications that are re-planned in background refresh. No server is needed.
- **Widgets.** Next departure on the home and lock screen, plus a "Start live tracking" button.
- **3D map.** Pitched follow camera with pre-rendered, camera-aligned vehicle sprites for every mode: bus, articulated trunk bus, U-bus, Artic tram, Raide-Jokeri light rail, M300 metro, Sm5 train and Suomenlinna-style ferry.
- **Every mode.** Bus, tram and metro positions come from HFP. Commuter trains also use Fintraffic Digitraffic GPS (matched automatically). Ferries use HFP or realtime data where available.

## Build and install (personal sideload)

Requirements: a Mac with **Xcode 16+**, an iPhone on **iOS 18+**, and a free or paid Apple ID.

1. Install XcodeGen: `brew install xcodegen`
2. `cp Config/Local.example.xcconfig Config/Local.xcconfig` and fill in:
   - `BUNDLE_ID_PREFIX`: anything unique, e.g. `com.yourname`
   - `DEVELOPMENT_TEAM`: your team ID (Xcode → Settings → Accounts)
   - `DIGITRANSIT_API_KEY`: optional here; you can also paste it in the app. Get a free key at <https://portal-api.digitransit.fi>.
3. `xcodegen generate && open HSLCommuter.xcodeproj`
4. Select your iPhone and press Run. On the phone, trust the developer profile under Settings → General → VPN & Device Management.
5. On first launch: paste the API key, allow location (**Always** gives the most reliable locked-screen tracking) and notifications, and add your Home → Work commute.

**Free Apple ID notes**
- The app has to be re-installed from Xcode every **7 days**. A paid account ($99/yr) makes it last a year.
- If signing fails on the **Time Sensitive Notifications** entitlement, delete `com.apple.developer.usernotifications.time-sensitive` from `project.yml` and regenerate. Alerts then arrive as normal notifications.
- If signing fails on **App Groups**, remove the `com.apple.security.application-groups` entries. Everything works except the home-screen widget, which will show "Open the app to plan". Live Activities don't need App Groups.

## Project layout

```
project.yml                 XcodeGen spec (app + widget extension)
Config/                     xcconfig + generated Info.plists/entitlements
Packages/CommuterKit/       Swift package
  ETAEngine/                pure Swift: geometry, Kalman filter, segment model, ETA, pace, transfers
  HSLKit/                   Digitransit GraphQL, MQTT-over-WebSocket client, HFP, Digitraffic rail
  HSLDesign/                HSL colours/typography, line badges, 3D vehicle renderer + sprite cache
App/                        SwiftUI app: Today, live trip map + sheet, nearby stops, settings
  Services/CommuteSession   the live engine (vehicles + you → advice, Live Activity, alerts)
Shared/                     Live Activity attributes, App Group store, App Intent (app + widgets)
Widgets/                    Live Activity / Dynamic Island + next-departure widget
```

## Tests

`ETAEngine` and `HSLKit` have unit tests (geometry, filter, ETA, pace and transfer logic, HFP/MQTT/GraphQL decoding):

```
cd Packages/CommuterKit && swift test
```

## How it works while the phone is locked

There's no server. When you start live tracking (from the app, a reminder notification, the widget or Siri), the app starts a background location session, the same mechanism navigation apps use. That keeps the HFP connection and the Live Activity updating until you stop or arrive. Before the commute, when the app isn't running, reminders are scheduled ahead from realtime data and refreshed when iOS grants background refresh time. They're accurate to roughly a minute, and switch to second-level accuracy once tracking starts.

## Data and credits

Data from HSL / Digitransit (CC BY 4.0) and Fintraffic Digitraffic (CC BY 4.0). HSL colours are used for a personal, unofficial app. This app is not affiliated with HSL.
