import SwiftUI
import MapKit
import ETAEngine
import HSLDesign

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: Commute?
    @State private var addingNew = false

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                NavigationLink {
                    HomeWorkView()
                } label: {
                    VStack(alignment: .leading) {
                        Label("Home & Work", systemImage: "house.and.flag.fill").font(HSLFont.body())
                        Text(app.homeWork.summary).font(HSLFont.caption(12)).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Your commute") }

            Section {
                ForEach(app.commutes) { c in
                    Button { editing = c } label: {
                        VStack(alignment: .leading) {
                            Text(c.name).font(HSLFont.body())
                            Text(subtitle(c)).font(HSLFont.caption(12)).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { app.commutes.remove(atOffsets: $0) }
                Button("Add commute", systemImage: "plus") { addingNew = true }
            } header: { Text("Other commutes") } footer: {
                Text("E.g. gym or school. Home ↔ work is set above.")
            }

            Section {
                HStack {
                    Text("Walking speed")
                    Spacer()
                    Text(String(format: "%.1f km/h", app.walkingSpeed * 3.6)).foregroundStyle(.secondary)
                }
                Slider(value: $app.walkingSpeed, in: 0.9...2.0, step: 0.05)
                Stepper("Extra time at stop: \(Int(app.extraBuffer)) s", value: $app.extraBuffer, in: 0...180, step: 15)
            } header: { Text("You") } footer: {
                Text("Walking speed is learned automatically while you walk to stops during live tracking.")
            }

            Section {
                SecureField("Digitransit API key", text: $app.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Link("Get a free key", destination: URL(string: "https://portal-api.digitransit.fi")!)
            } header: { Text("Data") }

            Section {
                Button("Location: allow “Always”") { app.location.requestPermission() }
                Button("Enable notifications") { Task { await app.notifications.requestAuthorization() } }
            } header: { Text("Permissions") } footer: {
                Text("“Always” location keeps live tracking running with the screen locked.")
            }

            Section {
                Text("Data: HSL & Digitransit (CC BY 4.0), Fintraffic Digitraffic (CC BY 4.0). Unofficial personal app, not affiliated with HSL.")
                    .font(HSLFont.caption(12)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .sheet(item: $editing) { c in
            CommuteEditor(commute: c) { updated in
                if let i = app.commutes.firstIndex(where: { $0.id == updated.id }) { app.commutes[i] = updated }
            }
        }
        .sheet(isPresented: $addingNew) {
            CommuteEditor(commute: nil) { app.commutes.append($0) }
        }
    }

    private func subtitle(_ c: Commute) -> String {
        let days = c.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")
        let time = c.arriveByMinutes.map { String(format: "arrive by %d:%02d", $0 / 60, $0 % 60) } ?? "leave any time"
        return "\(days) · \(time)"
    }
}

struct CommuteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var origin: SavedPlace?
    @State private var destination: SavedPlace?
    @State private var hasArriveBy: Bool
    @State private var arriveBy: Date
    @State private var weekdays: Set<Int>
    @State private var reminders: Bool
    private let id: UUID
    var onSave: (Commute) -> Void

    init(commute: Commute?, onSave: @escaping (Commute) -> Void) {
        self.onSave = onSave
        id = commute?.id ?? UUID()
        _name = State(initialValue: commute?.name ?? "Home → Work")
        _origin = State(initialValue: commute?.origin)
        _destination = State(initialValue: commute?.destination)
        _hasArriveBy = State(initialValue: commute?.arriveByMinutes != nil)
        let minutes = commute?.arriveByMinutes ?? 8 * 60 + 30
        _arriveBy = State(initialValue: Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date())
        _weekdays = State(initialValue: commute?.weekdays ?? [2, 3, 4, 5, 6])
        _reminders = State(initialValue: commute?.remindersEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section("From") { PlacePicker(place: $origin, placeholder: "Home") }
                Section("To") { PlacePicker(place: $destination, placeholder: "Work") }
                Section {
                    Toggle("Arrive by", isOn: $hasArriveBy)
                    if hasArriveBy {
                        DatePicker("Time", selection: $arriveBy, displayedComponents: .hourAndMinute)
                    }
                    WeekdayPicker(days: $weekdays)
                    Toggle("“Leave now” reminders", isOn: $reminders)
                } header: { Text("Schedule") }
            }
            .navigationTitle("Commute")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let origin, let destination else { return }
                        let comps = Calendar.current.dateComponents([.hour, .minute], from: arriveBy)
                        onSave(Commute(id: id, name: name, origin: origin, destination: destination,
                                       arriveByMinutes: hasArriveBy ? (comps.hour ?? 8) * 60 + (comps.minute ?? 0) : nil,
                                       weekdays: weekdays, remindersEnabled: reminders))
                        dismiss()
                    }
                    .disabled(origin == nil || destination == nil)
                }
            }
        }
    }
}

/// Search for an address or place with MapKit, biased to the Helsinki region.
struct PlacePicker: View {
    @Binding var place: SavedPlace?
    var placeholder: String
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var results: [MKMapItem] = []

    var body: some View {
        if let place {
            HStack {
                Text(place.name)
                Spacer()
                Button("Change") { self.place = nil }
            }
        } else {
            TextField("Search \(placeholder.lowercased()) address", text: $query)
                .onSubmit { Task { await search() } }
                .task(id: query) {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await search()
                }
            Button("Use current location", systemImage: "location.fill") {
                Task {
                    if let loc = await app.location.currentLocation() {
                        place = SavedPlace(name: placeholder, latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
                    }
                }
            }
            ForEach(results, id: \.self) { item in
                Button {
                    let c = item.placemark.coordinate
                    place = SavedPlace(name: item.name ?? placeholder, latitude: c.latitude, longitude: c.longitude)
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.name ?? "")
                        Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func search() async {
        guard query.count >= 3 else { results = []; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: .init(latitude: 60.19, longitude: 24.94),
                                            latitudinalMeters: 60_000, longitudinalMeters: 90_000)
        results = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
    }
}

/// First-run setup: API key, permissions, first commute.
struct SetupView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    Text("Know exactly when your bus, tram, metro, train or ferry really arrives, and whether to walk, hurry or run.")
                        .font(HSLFont.body())
                }
                Section {
                    SecureField("Digitransit API key", text: $app.apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Link("Get a free key at portal-api.digitransit.fi", destination: URL(string: "https://portal-api.digitransit.fi")!)
                } header: { Text("1. Data access") }
                Section {
                    Button("Allow location") { app.location.requestPermission() }
                    Button("Allow notifications") { Task { await app.notifications.requestAuthorization() } }
                } header: { Text("2. Permissions") }
                Section {
                    NavigationLink {
                        HomeWorkView()
                    } label: {
                        if app.homeWork.isComplete {
                            Label(app.homeWork.summary, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(HSLColor.green)
                        } else {
                            Label("Set home, work and working hours", systemImage: "house.and.flag")
                        }
                    }
                } header: { Text("3. Your commute") }
            }
            .navigationTitle("Welcome")
            .toolbar {
                Button("Done") { app.hasCompletedSetup = true }
                    .disabled(app.apiKey.isEmpty)
            }
        }
    }
}
