import SwiftUI
import Charts
import HealthKit
import ScaleKit

// MARK: - Measure (SRD-003)

struct MeasureView: View {
    @ObservedObject var central: ScaleCentral

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                weightCard
                statusCard
                if case .failed(let msg) = central.stage {
                    Text(msg).font(.footnote).foregroundStyle(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Measure")
        }
    }

    private var weightCard: some View {
        VStack(spacing: 6) {
            if let rec = central.lastRecord {
                Text(String(format: "%.2f", rec.weightKg))
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("kg").font(.title3).foregroundStyle(.secondary)
                if let z = rec.impedanceOhm {
                    Text("impedance \(z) Ω").font(.footnote).foregroundStyle(.secondary)
                }
                Text(rec.utc, format: .dateTime).font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("—")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text("step on the scale").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(stageText, systemImage: stageIcon).font(.headline)
            if central.lastRecord != nil {
                Text("\(central.recordCount) record(s) this session")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var stageText: String {
        switch central.stage {
        case .idle: return "Not connected"
        case .scanning: return "Scanning for scale…"
        case .connecting: return "Connecting…"
        case .handshaking: return "Handshake…"
        case .paired: return "Paired ✓"
        case .live: return "Live — step on the scale"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    private var stageIcon: String {
        switch central.stage {
        case .live: return "figure.stand"
        case .paired: return "checkmark.seal"
        case .failed: return "exclamationmark.triangle"
        default: return "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - History (SRD-004 FR-5/FR-6)

struct HistoryView: View {
    @State private var records: [MeasurementRecord] = []
    @State private var showExport = false
    @State private var exportText = ""
    @State private var healthMessage = ""

    private let profile = BodyComposer.Profile(sexMale: true, age: 33, heightMeters: 1.75)

    var body: some View {
        NavigationStack {
            List {
                if records.count >= 2 {
                    Section("Trend") {
                        Chart(records.sorted { $0.utc < $1.utc }) { r in
                            LineMark(x: .value("Date", r.utc), y: .value("kg", r.weightKg))
                            PointMark(x: .value("Date", r.utc), y: .value("kg", r.weightKg))
                        }
                        .frame(height: 180)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                Section("Measurements (\(records.count))") {
                    ForEach(records.reversed()) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.2f kg", r.weightKg))
                                .font(.headline)
                            HStack {
                                Text(r.utc, format: .dateTime)
                                if let z = r.impedanceOhm { Text("· \(z) Ω") }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                Button {
                    exportText = CSVExporter.export(records: records)
                    showExport = true
                } label: { Image(systemName: "square.and.arrow.up") }
                .disabled(records.isEmpty)
                Button {
                    healthMessage = HealthKitWriter.writeWeight(records: records)
                } label: { Image(systemName: "heart") }
                .disabled(records.isEmpty)
            }
            .alert("CSV Export", isPresented: $showExport) {
                Button("Done", role: .cancel) {}
            } message: {
                Text("CSV ready — \(records.count) rows. Copy from share sheet.")
            }
            .onAppear { records = MeasurementStore.shared.loadAll() }
        }
    }
}

// MARK: - Device (SRD-002)

struct DeviceView: View {
    @ObservedObject var central: ScaleCentral
    @StateObject private var profile = ProfileStore.shared
    @State private var slot = 1

    var body: some View {
        NavigationStack {
            List {
                Section("Bind record") {
                    if let rec = BindStore.shared.record {
                        Label("Bound ✓", systemImage: "checkmark.seal.fill")
                            .font(.headline).foregroundStyle(.green)
                        LabeledRow("DeviceId", rec.deviceId)
                        LabeledRow("MAC", rec.mac)
                        LabeledRow("Slot", "\(rec.slot)")
                        LabeledRow("Firmware", rec.firmwareVersion)
                        LabeledRow("Bound", rec.boundAt.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Label("No scale bound yet", systemImage: "link.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Profile (SRD-005 — pushed at session start)") {
                    Picker("Sex", selection: $profile.sexMale) {
                        Text("Male").tag(true)
                        Text("Female").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Stepper("Age: \(profile.age)", value: $profile.age, in: 5...120)
                    HStack {
                        Text("Height")
                        Spacer()
                        Text(String(format: "%.0f cm", profile.heightCm))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $profile.heightCm, in: 100...220, step: 1)
                }
                Section("Scan & bind") {
                    HStack {
                        Button(central.stage == .scanning ? "Stop scan" : "Scan") {
                            if central.stage == .scanning { central.stopScan() } else { central.startScan() }
                        }
                        Spacer()
                        Picker("Slot", selection: $slot) {
                            ForEach(1...5, id: \.self) { Text("Slot \($0)").tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    ForEach(central.foundScales) { s in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.name).font(.headline)
                                Text("\(s.mac) · \(s.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Bind") { central.bind(s, slot: slot) }
                                .buttonStyle(.borderedProminent)
                                .disabled(central.stage == .connecting || central.stage == .handshaking)
                        }
                    }
                    if central.foundScales.isEmpty, central.stage == .scanning {
                        Text("Step on the scale to wake it…").foregroundStyle(.secondary)
                    }
                }
                Section("Session") {
                    if let rec = BindStore.shared.record {
                        Button("Start weigh-in session") {
                            // Reconnect via the bind-time peripheral id; the
                            // central falls back to MAC-matched scan when nil.
                            let scale = ScaleCentral.DiscoveredScale(
                                id: rec.peripheralId.flatMap { UUID(uuidString: $0) } ?? UUID(),
                                name: "Scale", mac: rec.mac, rssi: 0)
                            central.startSession(with: scale)
                        }
                        .disabled(central.stage == .connecting || central.stage == .handshaking)
                    }
                }
                Section("Debug log") {
                    ForEach(Array(central.log.suffix(30).enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Device")
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value) }
    }
}
