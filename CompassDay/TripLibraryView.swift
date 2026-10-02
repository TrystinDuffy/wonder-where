import SwiftUI
import CoreLocation

struct TripLibraryView: View {
    @EnvironmentObject private var store: TripStore
    @State private var creatingPlan = false
    @State private var planName = ""
    @State private var showingSettings = false
    var onOpenCompass: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let active = store.activeTrip {
                    Section("In progress") {
                        Button {
                            store.startTrip(active.id, completion: onOpenCompass)
                        } label: {
                            Label("Resume \(active.plan.name)", systemImage: "location.north")
                        }.accessibilityIdentifier("resume-active-trip")
                        NavigationLink {
                            ConfigurationView(planID: nil, tripID: active.id, onOpenCompass: onOpenCompass)
                        } label: { tripRow(active) }
                            .accessibilityIdentifier("active-trip-details")
                    }
                }
                Section {
                    ForEach(store.library.plans) { plan in
                        NavigationLink {
                            ConfigurationView(planID: plan.id, tripID: nil, onOpenCompass: onOpenCompass)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plan.name)
                                Text("\(plan.places.count) places")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("reusable-plan-\(plan.id)")
                    }
                    .onDelete { offsets in
                        let plans = store.library.plans
                        let ids = Set(offsets.compactMap { plans.indices.contains($0) ? plans[$0].id : nil })
                        store.deletePlans(ids: ids)
                    }
                    Button("New plan", systemImage: "plus") { planName = ""; creatingPlan = true }
                        .accessibilityIdentifier("new-plan")
                } header: { Text("Reusable plans") } footer: {
                    Text("Plans keep places and time requirements. Schedule a plan to create a separate trip with dates and notifications. Deleting a plan keeps its saved trips.")
                }
                let scheduled = store.library.trips.filter { $0.status == .scheduled }.sorted { $0.scheduledStart < $1.scheduledStart }
                if !scheduled.isEmpty {
                    Section("Scheduled trips") {
                        ForEach(scheduled) { trip in
                            NavigationLink {
                                ConfigurationView(planID: nil, tripID: trip.id, onOpenCompass: onOpenCompass)
                            } label: { tripRow(trip) }
                                .accessibilityIdentifier("scheduled-trip-\(trip.id)")
                        }
                    }
                }
                let history = store.library.trips.filter { $0.status == .completed || $0.status == .canceled }
                    .sorted { ($0.completedAt ?? $0.scheduledStart) > ($1.completedAt ?? $1.scheduledStart) }
                if !history.isEmpty {
                    Section("Past trips") {
                        ForEach(history) { trip in
                            NavigationLink {
                                ConfigurationView(planID: nil, tripID: trip.id, onOpenCompass: onOpenCompass)
                            } label: { tripRow(trip) }
                        }
                    }
                }
            }
            .navigationTitle("WonderWhere")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        .accessibilityIdentifier("open-settings")
                }
            }
            .sheet(isPresented: $showingSettings) { OrganizerSettingsView() }
            .alert("New plan", isPresented: $creatingPlan) {
                TextField("Plan name", text: $planName)
                Button("Cancel", role: .cancel) { }
                Button("Create") { store.addPlan(name: planName.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func tripRow(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.plan.name)
            Text(trip.scheduledStart, format: .dateTime.month().day().year().hour().minute())
                .font(.subheadline).foregroundStyle(.secondary)
            if trip.status == .completed || trip.status == .canceled {
                Text(trip.status == .completed ? "Completed" : "Canceled")
                    .font(.caption).foregroundStyle(.secondary)
            } else if trip.status == .active {
                Text("\(trip.visitedCount)/\(trip.includedPlaces.count) places reached")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .environment(\.timeZone, TimeZone(identifier: trip.timeZoneIdentifier) ?? .current)
    }
}

struct ScheduleTripView: View {
    @EnvironmentObject private var store: TripStore
    @Environment(\.dismiss) private var dismiss
    let plan: Plan
    var onSaved: () -> Void
    @State private var tripID = UUID()
    @State private var name: String
    @State private var start: Date
    @State private var timeZoneIdentifier = TimeZone.current.identifier
    @State private var mode: TravelMode
    @State private var excluded: Set<UUID> = []
    @State private var bindings: [UUID: Date] = [:]
    @State private var editingRequirement: TimeRequirement?
    @State private var showingTimeZones = false
    @State private var saving = false
    @State private var startedLocation = false
    @State private var previewOrigin: Point?
    @State private var preview: TripScheduleProjection?
    @State private var previewLoading = false
    @State private var previewEstimates: [LegEstimate] = []
    @State private var routes = TripRoutes()

    init(plan: Plan, onSaved: @escaping () -> Void) {
        self.plan = plan
        self.onSaved = onSaved
        _name = State(initialValue: plan.name)
        _mode = State(initialValue: plan.initialMode)
        let rounded = ceil(Date().timeIntervalSince1970 / 900) * 900
        _start = State(initialValue: Date(timeIntervalSince1970: rounded))
    }

    private var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }
    private var includedPlaces: [Place] { plan.places.filter { !excluded.contains($0.id) } }
    private var includedRequirements: [TimeRequirement] { includedPlaces.flatMap(\.requirements) }
    private var missingCount: Int { includedRequirements.filter { bindings[$0.id] == nil }.count }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !includedPlaces.isEmpty && missingCount == 0 && !saving
    }
    private var previewKey: String {
        let times = includedRequirements.map { "\($0.id):\(bindings[$0.id]?.timeIntervalSince1970 ?? -1)" }.joined(separator: ";")
        return "\(start.timeIntervalSince1970):\(mode.rawValue):\(timeZoneIdentifier):\(times):\(excluded.sorted { $0.uuidString < $1.uuidString }):\(previewOrigin?.latitude ?? 0):\(previewOrigin?.longitude ?? 0)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    TextField("Trip name", text: $name)
                    DatePicker("Planned start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    Button { showingTimeZones = true } label: {
                        LabeledContent("Time zone", value: timeZoneIdentifier.replacingOccurrences(of: "_", with: " "))
                    }.tint(.primary)
                    Picker("First leg", selection: $mode) {
                        ForEach(TravelMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                    }
                    ScheduleOriginRow(location: store.location)
                }
                if plan.places.contains(where: \.isOptional) {
                    Section("Optional places") {
                        ForEach(plan.places.filter(\.isOptional)) { place in
                            Toggle(place.name, isOn: Binding(get: { !excluded.contains(place.id) }, set: { included in
                                if included { excluded.remove(place.id) } else { excluded.insert(place.id) }
                            }))
                        }
                    }
                }
                ForEach(includedPlaces.filter { !$0.requirements.isEmpty }) { place in
                    Section(place.name) {
                        ForEach(place.requirements) { requirement in
                            Button { editingRequirement = requirement } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(requirement.label.isEmpty ? requirement.kind.title : requirement.label).foregroundStyle(.primary)
                                        Text(requirement.kind.title).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let date = bindings[requirement.id] {
                                        Text(date, format: .dateTime.month().day().hour().minute()).multilineTextAlignment(.trailing)
                                    } else {
                                        Text("Choose time").foregroundStyle(.tint)
                                    }
                                }
                            }.accessibilityIdentifier("schedule-requirement-\(requirement.id.uuidString)")
                        }
                    }
                }
                Section("Estimate") {
                    if missingCount > 0 {
                        Text("Choose \(missingCount) required \(missingCount == 1 ? "time" : "times") to estimate this trip.")
                            .foregroundStyle(.secondary)
                    } else if let preview {
                        if let startBy = preview.startBy {
                            LabeledContent(preview.isAdjusted ? "Adjusted start by" : "Start by") {
                                Text(startBy, format: .dateTime.month().day().hour().minute())
                            }
                        }
                        if let completion = preview.completion {
                            LabeledContent("Estimated finish") {
                                Text(completionLabel(completion)).multilineTextAlignment(.trailing)
                            }
                        }
                        if previewLoading { Label("Getting travel estimates", systemImage: "clock").foregroundStyle(.secondary) }
                        else if preview.hasUnknownEstimates {
                            Text("Some travel estimates are unavailable. You can save this trip and enter travel durations in its configuration.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ScheduleFeedbackView(plan: plan, schedule: preview, plannedStart: start,
                                             timeZoneIdentifier: timeZoneIdentifier) { start = $0 }
                        if preview.isAdjusted {
                            Text("Flexible visits have been shortened or optional places skipped to help meet the selected times. Review the saved trip for its allocations.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Waiting for travel estimates").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("This creates a separate trip. Its dates, progress, and notifications will not change the reusable plan.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Schedule trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save", action: save).disabled(!canSave)
                        .accessibilityIdentifier("save-scheduled-trip")
                }
            }
            .sheet(item: $editingRequirement) { requirement in
                ScheduleRequirementPicker(requirement: requirement, initialDate: bindings[requirement.id] ?? start,
                                          timeZone: timeZone) { bindings[requirement.id] = $0 }
            }
            .sheet(isPresented: $showingTimeZones) { ScheduleTimeZonePicker(selection: $timeZoneIdentifier) }
            .task {
                previewOrigin = store.liveOrigin
                if store.activeTrip == nil { store.location.start(); startedLocation = true }
            }
            .onReceive(store.location.$position) { position in
                guard let position, position.isFresh(at: Date()) else { return }
                let point = Point(name: "Starting location", latitude: position.coordinate.latitude, longitude: position.coordinate.longitude)
                if previewOrigin == nil || previewOrigin!.distance(to: point) > 100 { previewOrigin = point }
            }
            .task(id: previewKey) { await loadPreview() }
            .onDisappear {
                routes.cancelAll()
                if startedLocation && store.activeTrip == nil { store.location.stop() }
            }
            .onChange(of: store.storageError) { _, error in if error != nil { saving = false } }
            .environment(\.timeZone, timeZone)
        }
    }

    private func draft() -> Trip {
        var snapshot = plan
        snapshot.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.initialMode = mode
        snapshot.reconcileLegs()
        let includedIDs = Set(includedRequirements.map(\.id))
        var trip = Trip(id: tripID, sourcePlanID: plan.id, plan: snapshot, scheduledStart: start,
                        timeZoneIdentifier: timeZoneIdentifier,
                        bindings: bindings.filter { includedIDs.contains($0.key) }, origin: previewOrigin)
        trip.skippedPlaceIDs = excluded
        return trip
    }

    @MainActor private func loadPreview() async {
        preview = nil
        guard missingCount == 0, !includedPlaces.isEmpty else { return }
        let trip = draft()
        let generation = previewKey
        previewLoading = true
        defer { if !Task.isCancelled { previewLoading = false } }
        var attempted: Set<String> = []
        for _ in 0..<(plan.places.count + 3) {
            let result = TripScheduler.project(trip: trip, liveOrigin: previewOrigin, routes: previewEstimates)
            guard !Task.isCancelled else { return }
            preview = result
            let requests = result.missingRoutes.filter { !attempted.contains($0.cacheKey) }
            if requests.isEmpty { break }
            for request in requests {
                attempted.insert(request.cacheKey)
                do {
                    let estimate = try await routes.fetch(request)
                    guard !Task.isCancelled, generation == previewKey,
                          request.isValid(for: draft(), liveOrigin: previewOrigin),
                          TripRoutes.matches(estimate, request: request) else { return }
                    previewEstimates.removeAll {
                        $0.matches(source: estimate.source, destination: estimate.destination, mode: estimate.mode) &&
                        abs($0.departureAt.timeIntervalSince(estimate.departureAt)) < 900
                    }
                    previewEstimates.append(estimate)
                    if previewEstimates.count > 128 { previewEstimates.removeFirst(previewEstimates.count - 128) }
                }
                catch { if Task.isCancelled { return } }
            }
        }
        if !Task.isCancelled {
            preview = TripScheduler.project(trip: trip, liveOrigin: previewOrigin, routes: previewEstimates)
        }
    }

    private func save() {
        guard canSave else { return }
        var trip = draft()
        trip.origin = store.liveOrigin ?? previewOrigin
        for index in trip.plan.legs.indices {
            let leg = trip.plan.legs[index]
            let source = leg.fromPlaceID.flatMap { trip.plan.place($0)?.exit.center } ?? trip.origin
            guard let source, let destination = trip.plan.place(leg.toPlaceID)?.entry.center else { continue }
            trip.plan.legs[index].estimate = previewEstimates.last {
                $0.matches(source: source, destination: destination, mode: leg.mode)
            } ?? trip.plan.legs[index].estimate
        }
        // Persist bypass estimates as well as adjacent legs; otherwise a preview-accepted skip
        // would lose its connecting-route estimate immediately after Save.
        trip.routeEstimates = previewEstimates
        let forecast = TripScheduler.project(trip: trip, liveOrigin: trip.origin, routes: previewEstimates)
        TripScheduler.apply(forecast, to: &trip)
        saving = true
        store.saveTrip(trip) { saving = false; dismiss(); onSaved() }
    }

    private func completionLabel(_ range: ClosedRange<Date>) -> String {
        completionText(range, timeZoneIdentifier: timeZoneIdentifier)
    }
}

private struct ScheduleOriginRow: View {
    @ObservedObject var location: LocationService
    var body: some View {
        if let point = location.position, point.isFresh(at: Date()) {
            LabeledContent("Starting location", value: "Current location")
        } else {
            LabeledContent("Starting location", value: location.message ?? "Waiting for GPS")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ScheduleRequirementPicker: View {
    let requirement: TimeRequirement
    let initialDate: Date
    let timeZone: TimeZone
    var onSave: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(requirement: TimeRequirement, initialDate: Date, timeZone: TimeZone, onSave: @escaping (Date) -> Void) {
        self.requirement = requirement; self.initialDate = initialDate; self.timeZone = timeZone; self.onSave = onSave
        _date = State(initialValue: initialDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(requirement.kind.title, selection: $date, displayedComponents: [.date, .hourAndMinute])
                Text(requirement.kind.schedulingExplanation).font(.footnote).foregroundStyle(.secondary)
                Text(timeZone.identifier.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.secondary)
            }
            .navigationTitle(requirement.label.isEmpty ? requirement.kind.title : requirement.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Set time") { onSave(date); dismiss() } }
            }
            .environment(\.timeZone, timeZone)
        }
    }
}

private struct ScheduleTimeZonePicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var identifiers: [String] {
        TimeZone.knownTimeZoneIdentifiers.filter {
            search.isEmpty || $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        NavigationStack {
            List(identifiers, id: \.self) { identifier in
                Button {
                    selection = identifier
                    dismiss()
                } label: {
                    HStack {
                        Text(identifier.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.primary)
                        Spacer()
                        if selection == identifier { Image(systemName: "checkmark") }
                    }
                }
            }
            .navigationTitle("Time zone")
            .searchable(text: $search, prompt: "City or region")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
