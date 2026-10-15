import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            Tab("Commute", systemImage: "figure.walk.departure") {
                NavigationStack { TodayView() }
            }
            Tab("Nearby", systemImage: "mappin.and.ellipse") {
                NavigationStack { StopBoardView() }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { app.session != nil },
            set: { if !$0 { app.stopSession() } })) {
            if let session = app.session {
                LiveTripView(session: session)
            }
        }
        .sheet(isPresented: Binding(get: { !app.hasCompletedSetup }, set: { _ in })) {
            SetupView()
                .interactiveDismissDisabled()
        }
    }
}
