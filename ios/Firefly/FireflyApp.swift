import SwiftUI

@main
struct FireflyApp: App {
    @StateObject private var central = ScaleCentral()

    var body: some Scene {
        WindowGroup {
            TabView {
                MeasureView(central: central)
                    .tabItem { Label("Measure", systemImage: "scalemass") }
                HistoryView()
                    .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
                DeviceView(central: central)
                    .tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }
            }
        }
    }
}
