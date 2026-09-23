import SwiftUI

@main
struct FireflyApp: App {
    var body: some Scene {
        WindowGroup {
            // SRD-009: the Devices hub is the app root; the scale's feature
            // tabs (Measure/History/Device) live under the paired device.
            DevicesHubView()
        }
    }
}
