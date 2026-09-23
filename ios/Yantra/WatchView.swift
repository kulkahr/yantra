import SwiftUI
import ScaleKit

/// SRD-010 — the watch driver's feature UI: pairing, live rings (HR/steps),
/// device info, HR history timeline and the link log.
struct WatchView: View {
    @ObservedObject var watch = WatchCentral.shared
    @State private var historyDay = 0

    var body: some View {
        List {
            connectionSection
            if watch.stage == .live {
                liveSection
                historySection
                deviceSection
            }
            logSection
        }
        .navigationTitle(watch.deviceName ?? "Smart Watch")
    }

    // MARK: Sections

    private var connectionSection: some View {
        Section {
            switch watch.stage {
            case .idle:
                Button("Scan for Storm Call 3") { watch.startScan() }
                ForEach(watch.foundWatches) { w in
                    Button {
                        watch.stopScan()
                        watch.pair(w)
                    } label: {
                        HStack {
                            Text(w.name)
                            Spacer()
                            Text("\(w.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            case .scanning:
                HStack {
                    Text("Searching…")
                    Spacer()
                    Button("Stop") { watch.stopScan() }
                }
                ForEach(watch.foundWatches) { w in
                    Button { watch.stopScan(); watch.pair(w) } label: { Text(w.name) }
                }
            case .connecting, .handshaking:
                HStack {
                    ProgressView()
                    Text(stageText).padding(.leading, 6)
                }
                Button("Disconnect", role: .destructive) { watch.disconnect() }
            case .live:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Disconnect", role: .destructive) { watch.disconnect() }
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Scan again") { watch.startScan() }
            }
        } header: {
            Text("Connection")
        }
    }

    private var liveSection: some View {
        Section("Live") {
            HStack {
                Image(systemName: "heart.fill").foregroundStyle(.red)
                Text(watch.liveHealth.map { "\($0.heartRate)" } ?? "—")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("bpm").foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing) {
                    if let bp = watch.liveHealth {
                        Text("BP \(bp.systolic)/\(bp.diastolic)").font(.caption)
                        Text("stress \(bp.stress) · RR \(bp.respiratoryRate)").font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "figure.walk").foregroundStyle(.blue)
                Text(watch.liveSteps.map { "\($0.steps)" } ?? "—")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text("steps").foregroundStyle(.secondary)
                Spacer()
                if let s = watch.liveSteps, let cal = s.calories {
                    Text(String(format: "%.0f kcal · %.0f m", cal, s.meters ?? 0))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var historySection: some View {
        Section {
            Picker("Day", selection: $historyDay) {
                Text("Today").tag(0)
                Text("Yesterday").tag(1)
            }
            .pickerStyle(.segmented)
            .onChange(of: historyDay) { _, day in watch.loadHRHistory(day: day) }
            if watch.hrSamples.isEmpty {
                Text("Pull a day of auto-measured heart rate from the watch.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(watch.hrSamples.enumerated().reversed()), id: \.offset) { _, s in
                    HStack {
                        Image(systemName: "heart").foregroundStyle(.red)
                        Text("\(s.heartRate) bpm")
                        Spacer()
                        Text("BP \(s.systolic)/\(s.diastolic)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Heart-rate history")
        } footer: {
            Text("Auto-measure must be enabled on the watch (every 60 min by default).")
        }
    }

    private var deviceSection: some View {
        Section("Device") {
            if let fw = watch.firmwareVersion {
                LabeledContent("Firmware", value: fw)
            }
            if let t = watch.watchTime {
                LabeledContent("Watch clock", value: t.formatted(date: .abbreviated, time: .standard))
            }
            LabeledContent("Battery", value: watch.batteryPercent.map { "\($0)%" } ?? "—")
        }
    }

    private var logSection: some View {
        Section("Log") {
            ForEach(Array(watch.log.suffix(12).enumerated().reversed()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var stageText: String {
        switch watch.stage {
        case .connecting: return "Connecting…"
        case .handshaking: return "Handshaking…"
        default: return ""
        }
    }
}
