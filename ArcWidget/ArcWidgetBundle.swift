import WidgetKit
import SwiftUI

@main
struct ArcWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextFlightWidget()
        FlightLiveActivity()
    }
}
