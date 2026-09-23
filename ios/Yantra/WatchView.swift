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
                sleepSection
                spo2Section
                storedSection
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
            dayPicker
            if watch.hrDated.isEmpty {
                Text("Pull a day of auto-measured heart rate from the watch.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(watch.hrDated.enumerated().reversed()), id: \.offset) { _, entry in
                    HStack {
                        Text(entry.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Image(systemName: "heart").foregroundStyle(.red)
                        Text("\(entry.sample.heartRate) bpm")
                        Spacer()
                        Text("BP \(entry.sample.systolic)/\(entry.sample.diastolic)")
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

    private var sleepSection: some View {
        Section {
            if watch.sleepHours.isEmpty {
                Text("Pull a day of 10-minute sleep tracking from the watch.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let totals = sleepTotals
                HStack {
                    stageBar
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(String(format: "%.1f h", totals.sleep / 60),
                              systemImage: "bed.double.fill").foregroundStyle(.indigo)
                        Text("deep \(Int(totals.deep))m · REM \(Int(totals.rem))m · light \(Int(totals.light))m")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(watch.sleepHours.reversed()), id: \.hour) { h in
                    if h.totalSleepMinutes > 0 {
                        HStack {
                            Text(String(format: "%02d:00", h.hour))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("\(Int(h.totalSleepMinutes)) min")
                            Spacer()
                            Text("\(Int(h.deepMinutes))D \(Int(h.remMinutes))R \(Int(h.lightMinutes))L")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Sleep")
        } footer: {
            Text("Stages are 2.5-minute readings packed 4-per-byte, decoded exactly as the official app (awake / light / deep / REM).")
        }
    }

    private var spo2Section: some View {
        Section {
            if watch.spo2Samples.isEmpty {
                Text("Pull a day of periodic blood-oxygen readings from the watch.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Image(systemName: "lungs.fill").foregroundStyle(.cyan)
                    Text("\(watch.spo2Average.map { "\($0)%" } ?? "—")")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text("avg SpO₂").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(watch.spo2Samples.count) samples")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(watch.spo2Samples.suffix(12).enumerated().reversed()), id: \.offset) { _, s in
                    HStack {
                        Text(s.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text("\(s.percent)%")
                        Spacer()
                        ProgressView(value: Double(s.percent), total: 100)
                            .frame(width: 80)
                    }
                }
            }
        } header: {
            Text("Blood oxygen (SpO₂)")
        }
    }

    private var storedSection: some View {
        Section("Stored days (local)") {
            let stored = WatchStore.shared.days
            if stored.isEmpty {
                Text("Pulled history is saved locally day by day.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(stored.prefix(7)) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(d.dayKey).font(.caption.monospaced())
                            Spacer()
                            if d.spo2Average != nil {
                                Image(systemName: "lungs.fill").font(.caption).foregroundStyle(.cyan)
                            }
                            if d.sleepTotalMinutes > 0 {
                                Image(systemName: "bed.double.fill").font(.caption).foregroundStyle(.indigo)
                            }
                        }
                        Text("\(d.steps) steps · " +
                             (d.spo2Average.map { "SpO₂ \($0)% · " } ?? "") +
                             (d.sleepTotalMinutes > 0 ? String(format: "sleep %.1f h", d.sleepTotalMinutes / 60) : "no sleep"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var dayPicker: some View {
        Picker("Day", selection: $historyDay) {
            Text("Today").tag(0)
            Text("Yesterday").tag(1)
        }
        .pickerStyle(.segmented)
        .onChange(of: historyDay) { _, day in watch.loadDayHistory(day: day) }
    }

    private var sleepTotals: (sleep: Double, deep: Double, rem: Double, light: Double, awake: Double) {
        (watch.sleepHours.reduce(0) { $0 + $1.totalSleepMinutes },
         watch.sleepHours.reduce(0) { $0 + $1.deepMinutes },
         watch.sleepHours.reduce(0) { $0 + $1.remMinutes },
         watch.sleepHours.reduce(0) { $0 + $1.lightMinutes },
         watch.sleepHours.reduce(0) { $0 + $1.awakeMinutes })
    }

    /// One stacked bar per hour, segments colored by stage share.
    private var stageBar: some View {
        let totals = sleepTotals
        let total = max(totals.sleep + totals.awake, 1)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 1) {
                Capsule().fill(.indigo).frame(width: 90 * totals.deep / total, height: 10)
                Capsule().fill(.purple).frame(width: 90 * totals.rem / total, height: 10)
                Capsule().fill(.blue).frame(width: 90 * totals.light / total, height: 10)
                Capsule().fill(.gray.opacity(0.4)).frame(width: 90 * totals.awake / total, height: 10)
            }
            Text("D · R · L · awake").font(.caption2).foregroundStyle(.secondary)
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
