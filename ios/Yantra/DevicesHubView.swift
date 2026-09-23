import SwiftUI
import ScaleKit

/// SRD-009: the app-wide driver registry, built once at startup. Adding a
/// device kind = implementing `DeviceDriver` + one line here.
@MainActor
enum YantraDrivers {
    static let registry: DriverRegistry = {
        let r = DriverRegistry()
        r.register(ScaleDriver())
        r.register(WatchDriver())
        r.register(BulbDriver())
        return r
    }()
}

/// SRD-009 FR-1 — the Devices hub: paired inventory + add-device flow.
/// The home screen of the multi-device app; the scale opens its feature tabs.
struct DevicesHubView: View {
    @StateObject private var store = DeviceStore.shared
    @State private var showAddSheet = false

    private var scaleDevice: PairedDevice? {
        store.devices.first { $0.kind == .scale }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(YantraDrivers.registry.allDrivers, id: \.kind) { driver in
                    section(for: driver)
                }
            }
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddDeviceSheet()
            }
        }
    }

    @ViewBuilder
    private func section(for driver: DeviceDriver) -> some View {
        Section(driver.displayName) {
            if driver.isStub {
                Label("\(driver.displayName) support is coming soon — \(driver.summary)",
                      systemImage: driver.kind.symbolName)
                    .foregroundStyle(.secondary)
            } else if let device = store.devices.first(where: { $0.kind == driver.kind }) {
                NavigationLink {
                    driverDestination(driver, device: device)
                } label: {
                    Label(device.name.isEmpty ? driver.displayName : device.name,
                          systemImage: driver.kind.symbolName)
                }
            } else {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add \(driver.displayName)", systemImage: "plus.circle")
                }
            }
        }
    }

    /// Routes to the driver's feature UI. Scale opens the existing tabs;
    /// future drivers plug in here via their own feature views.
    @ViewBuilder
    private func driverDestination(_ driver: DeviceDriver, device: PairedDevice) -> some View {
        switch driver.kind {
        case .scale:
            MainTabView(central: ScaleCentral.shared)
        case .watch:
            WatchView()
        default:
            EmptyView()
        }
    }
}

/// Add-device flow: pick the kind → driver-specific scan → pair.
struct AddDeviceSheet: View {
    @StateObject private var store = DeviceStore.shared
    @ObservedObject private var transport = DeviceTransport.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: DeviceKind?
    @State private var found: [AdvertisementSnapshot] = []

    var body: some View {
        NavigationStack {
            List {
                if selectedKind == nil {
                    Section("What do you want to add?") {
                        ForEach(YantraDrivers.registry.allDrivers, id: \.kind) { driver in
                            Button {
                                if !driver.isStub {
                                    selectedKind = driver.kind
                                    startScan(driver: driver)
                                }
                            } label: {
                                HStack {
                                    Label(driver.kind.displayName,
                                          systemImage: driver.kind.symbolName)
                                    Spacer()
                                    if driver.isStub {
                                        Text("Coming soon").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(driver.isStub)
                        }
                    }
                } else {
                    Section {
                        Button("Cancel") {
                            transport.stopScan()
                            selectedKind = nil
                            found = []
                        }
                    }
                    Section("Found devices") {
                        ForEach(found) { adv in
                            Button {
                                pair(adv)
                            } label: {
                                HStack {
                                    Text(adv.name ?? "Unknown")
                                    Spacer()
                                    Text("\(adv.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if found.isEmpty {
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add device")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func startScan(driver: DeviceDriver) {
        found = []
        let scanner = driver.makeScanner()
        scanner.onFound = { adv in
            if !found.contains(where: { $0.peripheralId == adv.peripheralId }) {
                found.append(adv)
            }
        }
        transport.scan(with: scanner)
    }

    /// Pairs the chosen device: connects via the driver's session and records
    /// it in the inventory. For the scale this re-uses the existing bind flow
    /// (ScaleCentral) so SRD-002 behavior is unchanged.
    private func pair(_ adv: AdvertisementSnapshot) {
        transport.stopScan()
        store.upsert(PairedDevice(peripheralId: adv.peripheralId, kind: adv.kind,
                                  name: adv.name ?? "", addedAt: Date()))
        switch adv.kind {
        case .scale:
            // Legacy bind flow (pair machine, slot, DFU…) — unchanged (SRD-009 FR-5).
            ScaleCentral.shared.adoptDiscovered(adv)
            dismiss()
        case .watch:
            // SRD-010: hand the discovered watch to WatchCentral for the
            // connect + KaHa handshake; the hub entry navigates via the
            // inventory row (Devices → Smart Watch).
            let watch = WatchCentral.shared
            watch.pair(WatchCentral.DiscoveredWatch(id: adv.peripheralId,
                                                    name: adv.name ?? "Storm Call 3",
                                                    rssi: adv.rssi))
            dismiss()
        default:
            // Stub kinds: recorded but no session (their SRDs are pending).
            break
        }
    }
}
