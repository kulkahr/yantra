import SwiftUI
import Charts
import HealthKit
import ScaleKit

// MARK: - Measure (SRD-003)

struct MeasureView: View {
    @ObservedObject var central: ScaleCentral
    @ObservedObject private var people = PersonStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    weightCard
                    if central.lastRecord != nil { compositionCard }
                    statusCard
                    if case .failed(let msg) = central.stage {
                        Text(msg).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding()
            }
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

    /// Issue #7 — body composition for the latest weigh-in (issue #8: the scale
    /// sends only weight+impedance; composition is computed app-side, like the
    /// official app). Uses the weighing person's profile when set.
    private var compositionCard: some View {
        let rec = central.lastRecord!
        let profile: BodyComposer.Profile = {
            if let p = people.person(id: rec.personId) {
                return BodyComposer.Profile(sexMale: p.sexMale, age: p.age,
                                            heightMeters: p.heightCm / 100)
            }
            return ProfileStore.shared.composerProfile
        }()
        let c = BodyComposer.compose(weightKg: rec.weightKg,
                                     impedanceOhm: rec.impedanceOhm.map(Double.init),
                                     profile: profile)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Body composition").font(.headline)
                Spacer()
                Text(people.person(id: rec.personId)?.name ?? "Default profile")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metric("BMI", c.bmi, format: "%.1f")
                metric("Fat", c.fatPercent, format: "%.1f%%")
                metric("Fat mass", c.fatMassKg, format: "%.1f kg")
                metric("Muscle", c.musclePercent, format: "%.1f%%")
                metric("Water", c.waterPercent, format: "%.1f%%")
                metric("Protein", c.proteinKg, format: "%.1f kg")
                metric("Bone", c.boneKg, format: "%.1f kg")
                metric("BMR", Double(c.basalMetabolismKcal), format: "%.0f kcal")
                metric("Visceral", c.visceralFatLevel, format: "%.1f")
            }
            if !c.impedanceBased {
                Label("No impedance — fat % is a BMI-based estimate",
                      systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func metric(_ name: String, _ value: Double, format: String) -> some View {
        VStack(spacing: 2) {
            Text(String(format: format, value))
                .font(.system(.body, design: .rounded).weight(.semibold))
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(stageText, systemImage: stageIcon).font(.headline)
            if let p = PersonStore.shared.activePerson {
                Text("Weighing as \(p.name) (slot \(p.slot))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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

// MARK: - History (SRD-004 FR-5/FR-6) + per-person assignment

struct HistoryView: View {
    @State private var records: [MeasurementRecord] = []
    @State private var showExport = false
    @State private var exportText = ""
    @State private var healthMessage = ""
    /// Issue #5: History defaults to following the ACTIVE person; the user can
    /// still pin a specific person or see everything.
    private enum Scope: Equatable {
        case followActive
        case all
        case person(UUID)
    }
    @State private var scope: Scope = .followActive
    @State private var showAssignment = false
    @State private var assigning: [MeasurementRecord] = []

    @ObservedObject private var people = PersonStore.shared

    /// Records with no owning person — the user is asked to assign each one.
    private var unassigned: [MeasurementRecord] {
        records.filter { $0.personId == nil }
    }

    private var visibleRecords: [MeasurementRecord] {
        switch scope {
        case .all:
            return records
        case .person(let id):
            return records.filter { $0.personId == id }
        case .followActive:
            guard let id = people.activePersonId else { return records }
            return records.filter { $0.personId == id }
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: return "All"
        case .person(let id): return people.person(id: id)?.name ?? "?"
        case .followActive:
            if let p = people.activePerson { return "\(p.name) ●" }
            return "All (no active person)"
        }
    }

    private func displayName(for rec: MeasurementRecord) -> String {
        people.person(id: rec.personId)?.name ?? "Unassigned"
    }

    var body: some View {
        NavigationStack {
            List {
                if !unassigned.isEmpty {
                    Section {
                        Button {
                            assigning = unassigned
                            showAssignment = true
                        } label: {
                            Label("\(unassigned.count) unassigned weight(s) — tap to assign",
                                  systemImage: "person.badge.questionmark")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if visibleRecords.count >= 2 {
                    Section("Trend") {
                        Chart(visibleRecords.sorted { $0.utc < $1.utc }) { r in
                            LineMark(x: .value("Date", r.utc), y: .value("kg", r.weightKg))
                            PointMark(x: .value("Date", r.utc), y: .value("kg", r.weightKg))
                                .foregroundStyle(by: .value("Person", displayName(for: r)))
                        }
                        .frame(height: 180)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                Section("Measurements (\(visibleRecords.count))") {
                    ForEach(visibleRecords.reversed()) { r in
                        recordRow(r)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Follow active person \(scope == .followActive ? "✓" : "")") { scope = .followActive }
                        Button("All records \(scope == .all ? "✓" : "")") { scope = .all }
                        Section("People") {
                            ForEach(people.people) { p in
                                Button("\(p.name) (slot \(p.slot)) \(scope == .person(p.id) ? "✓" : "")") { scope = .person(p.id) }
                            }
                        }
                    } label: {
                        Label(scopeTitle, systemImage: "person.2")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        exportText = CSVExporter.export(records: visibleRecords,
                                                        people: people.people)
                        showExport = true
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(visibleRecords.isEmpty)
                    Button {
                        healthMessage = HealthKitWriter.writeWeight(records: visibleRecords)
                    } label: { Image(systemName: "heart") }
                    .disabled(visibleRecords.isEmpty)
                }
            }
            .alert("CSV Export", isPresented: $showExport) {
                Button("Done", role: .cancel) {}
            } message: {
                Text("CSV ready — \(visibleRecords.count) rows. Copy from share sheet.")
            }
            .sheet(isPresented: $showAssignment) {
                AssignmentSheet(records: assigning) { reload() }
            }
            .onAppear { reload() }
        }
    }

    private func reload() {
        records = MeasurementStore.shared.loadAll()
    }

    @ViewBuilder
    private func recordRow(_ r: MeasurementRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(String(format: "%.2f kg", r.weightKg)).font(.headline)
                Spacer()
                if let p = people.person(id: r.personId) {
                    Label(p.name, systemImage: "person.fill")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.blue.opacity(0.12)))
                        .foregroundStyle(.blue)
                } else {
                    Button("Assign person…") {
                        assigning = [r]
                        showAssignment = true
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            HStack {
                Text(r.utc, format: .dateTime)
                if let z = r.impedanceOhm { Text("· \(z) Ω") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Ask the user who each unassigned weight belongs to. Every record must be
/// either assigned to a person or explicitly skipped (kept as "unassigned").
/// Records pulled from scale memory (offline weigh-ins) land here.
private struct AssignmentSheet: View {
    let records: [MeasurementRecord]
    let onDone: () -> Void

    @ObservedObject private var people = PersonStore.shared
    @State private var chosen: [UUID: UUID] = [:]      // recordId → personId
    @State private var skipped: Set<UUID> = []
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    private let skipMarker = UUID()   // sentinel for "explicitly skipped"

    var body: some View {
        NavigationStack {
            List {
                Section("Who do these belong to?") {
                    ForEach(records) { rec in
                        recordRow(rec)
                    }
                }
                Section("Assign all remaining to…") {
                    ForEach(people.people) { p in
                        Button {
                            for r in records { chosen[r.id] = p.id }
                        } label: {
                            Label("All → \(p.name)", systemImage: "person.fill")
                        }
                    }
                    if people.people.count > 1 {
                        // Round-robin convenience: each record to the next person.
                        Button {
                            for (i, r) in records.enumerated() {
                                chosen[r.id] = people.people[i % people.people.count].id
                            }
                        } label: {
                            Label("Cycle through people", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                Section("Add person") {
                    HStack {
                        TextField("Name", text: $newName)
                            .textInputAutocapitalization(.words)
                        Button("Add") { addPerson() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                      || people.slotsInUse.count >= 5)
                    }
                }
            }
            .navigationTitle("Assign weights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { apply() }
            }
        }
    }

    @ViewBuilder
    private func recordRow(_ rec: MeasurementRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "%.2f kg", rec.weightKg)).font(.headline)
                    Text(rec.utc, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let pid = chosen[rec.id] {
                    Label(people.person(id: pid)?.name ?? "?", systemImage: "person.fill.checkmark")
                        .font(.caption).foregroundStyle(.blue)
                } else if skipped.contains(rec.id) {
                    Label("Skipped", systemImage: "slash.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Person", selection: binding(for: rec)) {
                Text("— choose —").tag(UUID?.none)
                ForEach(people.people) { p in
                    Text(p.name).tag(UUID?.some(p.id))
                }
                Text("Skip (leave unassigned)").tag(Optional(skipMarker))
            }
            .pickerStyle(.menu)
        }
    }

    private func binding(for rec: MeasurementRecord) -> Binding<UUID?> {
        Binding(
            get: {
                if let c = chosen[rec.id] { return c }
                return skipped.contains(rec.id) ? skipMarker : nil
            },
            set: { newValue in
                skipped.remove(rec.id)
                chosen[rec.id] = nil
                switch newValue {
                case .some(let v) where v == skipMarker: skipped.insert(rec.id)
                case .some(let v): chosen[rec.id] = v
                case .none: break
                }
            })
    }

    /// Quick add: creates a person from the inline field (default profile;
    /// edit afterwards to set sex/age/height).
    private func addPerson() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard let p = people.add(name: name,
                                 profile: (sexMale: true, age: 30, heightCm: 170)) else { return }
        newName = ""
        // If only one record is on the table, assign it straight away.
        if records.count == 1, chosen[records[0].id] == nil {
            chosen[records[0].id] = p.id
        }
    }

    /// Persist choices: assigned records get their person; skipped or untouched
    /// records stay unassigned (offered again in History).
    private func apply() {
        for var rec in records {
            if let pid = chosen[rec.id] {
                rec.personId = pid
                MeasurementStore.shared.update(rec)
            }
        }
        onDone()
        dismiss()
    }
}

// MARK: - Device (SRD-002) + People (multi-user)

struct DeviceView: View {
    @ObservedObject var central: ScaleCentral
    @StateObject private var profile = ProfileStore.shared
    @ObservedObject private var people = PersonStore.shared
    @State private var slot = 1
    @State private var newPersonName = ""
    @State private var newPersonSlot = 1
    @State private var editingPerson: Person?

    var body: some View {
        NavigationStack {
            List {
                bindSection
                peopleSection
                profileSection
                scanSection
                sessionSection
                debugSection
            }
            .navigationTitle("Device")
            .sheet(item: $editingPerson) { p in
                PersonEditorView(person: p)
            }
        }
    }

    // MARK: Sections

    private var bindSection: some View {
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
    }

    private var peopleSection: some View {
        Section {
            if people.people.isEmpty {
                Text("Add the people who use this scale (max 5 — one per scale slot).")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(people.people) { p in
                    personRow(p)
                }
            }
            addPersonRow
        } header: {
            Text("People")
        } footer: {
            Text("The active person's slot is armed at weigh-in; new records are attributed to them. Unassigned records can be assigned in History.")
        }
    }

    @ViewBuilder
    private func personRow(_ p: Person) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.name).font(.headline)
                    if people.activePersonId == p.id {
                        Text("ACTIVE").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    }
                }
                Text("slot \(p.slot) · \(p.sexMale ? "m" : "f") · \(p.age) y · " +
                     String(format: "%.0f cm", p.heightCm))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if people.activePersonId != p.id {
                Button("Set active") { people.setActive(p) }
                    .buttonStyle(.bordered)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { editingPerson = p }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                people.remove(p)
            } label: { Label("Remove", systemImage: "trash") }
            Button {
                editingPerson = p
            } label: { Label("Edit", systemImage: "pencil") }
        }
    }

    private var addPersonRow: some View {
        HStack {
            TextField("New person's name", text: $newPersonName)
                .textInputAutocapitalization(.words)
            Picker("Slot", selection: $newPersonSlot) {
                ForEach(Array(1...5), id: \.self) { s in
                    Text("S\(s)")
                        .tag(s)
                        .disabled(people.slotsInUse.contains(s))
                }
            }
            .pickerStyle(.menu)
            Button("Add") {
                let name = newPersonName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                if people.add(name: name,
                              profile: (sexMale: true, age: 30, heightCm: 170),
                              preferredSlot: newPersonSlot) != nil {
                    newPersonName = ""
                    newPersonSlot = (1...5).first { !people.slotsInUse.contains($0) } ?? 1
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(newPersonName.trimmingCharacters(in: .whitespaces).isEmpty
                      || people.slotsInUse.count >= 5)
        }
    }

    private var profileSection: some View {
        Section {
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
        } header: {
            Text("Default profile (SRD-005 — pushed at session start)")
        } footer: {
            Text("Used for people without their own sex/age/height.")
        }
    }

    private var scanSection: some View {
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
    }

    private var sessionSection: some View {
        Section("Session") {
            if let rec = BindStore.shared.record {
                if let p = people.activePerson {
                    Label("Weighing as \(p.name) (slot \(p.slot))",
                          systemImage: "figure.stand")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !people.people.isEmpty {
                    Label("No active person — new weigh-ins will need assignment in History",
                          systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button("Start weigh-in session") {
                    let scale = ScaleCentral.DiscoveredScale(
                        id: rec.peripheralId.flatMap { UUID(uuidString: $0) } ?? UUID(),
                        name: "Scale", mac: rec.mac, rssi: 0)
                    central.startSession(with: scale)
                }
                .disabled(central.stage == .connecting || central.stage == .handshaking)
            }
        }
    }

    private var debugSection: some View {
        Section("Debug log") {
            ForEach(Array(central.log.suffix(30).enumerated().reversed()), id: \.offset) { _, line in
                Text(line).font(.system(size: 11, design: .monospaced))
            }
        }
    }
}

/// Edit a person's name + profile (0x1001 user-info push values).
private struct PersonEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var people = PersonStore.shared
    @State var person: Person

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $person.name)
                        .textInputAutocapitalization(.words)
                }
                Section("Profile (pushed as 0x1001 user-info)") {
                    Picker("Sex", selection: $person.sexMale) {
                        Text("Male").tag(true)
                        Text("Female").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Stepper("Age: \(person.age)", value: $person.age, in: 5...120)
                    HStack {
                        Text("Height")
                        Spacer()
                        Text(String(format: "%.0f cm", person.heightCm))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $person.heightCm, in: 100...220, step: 1)
                    if person.targetWeightKg != nil {
                        LabeledRow("Target", String(format: "%.1f kg", person.targetWeightKg!))
                    }
                }
                Section {
                    LabeledRow("Scale slot", "\(person.slot)")
                } footer: {
                    Text("The slot is this person's identity on the scale (1–5).")
                }
            }
            .navigationTitle("Edit person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Save") {
                    let mutated = person
                    people.rename(mutated, to: mutated.name)
                    people.updateProfile(mutated, sexMale: mutated.sexMale,
                                         age: mutated.age, heightCm: mutated.heightCm,
                                         targetWeightKg: .some(mutated.targetWeightKg))
                    dismiss()
                }
            }
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
