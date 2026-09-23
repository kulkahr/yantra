import SwiftUI

/// The scale driver's feature tabs (SRD-009 §3.1) — identical to the original
/// app shell, now reachable from the Devices hub.
struct MainTabView: View {
    @ObservedObject var central: ScaleCentral

    var body: some View {
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
