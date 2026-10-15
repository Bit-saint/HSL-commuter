import SwiftUI
import WidgetKit

@main
struct CommuterWidgets: WidgetBundle {
    var body: some Widget {
        CommuteLiveActivity()
        NextDepartureWidget()
    }
}
