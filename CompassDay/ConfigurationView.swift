import SwiftUI
import MapKit

struct ConfigurationView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var appearance: CompassAppearance
    var planID: UUID? = nil
    var tripID: UUID? = nil
    var onOpenCompass: () -> Void
    @State private var showingMap = false
    @State private var editingPlace: PlaceEditorPresentation?
    @State private var editingLeg: Leg?
    @State private var scheduling = false
    @State private var showScheduledTrip = false
    @State private var confirmCancel = false
    @State private var editingTripTiming = false
    @State private var renamingPlan = false
    @State private var planName = ""
    @State private var preparingCalendar = false
    @State private var calendarExport: TripCalendarShareFile?
    @State private var calendarExportError: String?
    @State private var showingAppleCalendar = false
    @State private var showingGoogleCalendar = false
    @State private var editMode: EditMode = .inactive

    private struct PlaceEditorPresentation: Identifiable {
        let id: UUID
        let place: Place?
        let isNew: Bool

        static func new() -> Self { Self(id: UUID(), place: nil, isNew: true) }
        static func existing(_ place: Place) -> Self { Self(id: place.id, place: place, isNew: false) }
    }

    private var trip: Trip? { store.library.trips.first { $0.id == tripID } }
    private var plan: Plan? { trip?.plan ?? store.library.plans.first { $0.id == planID } }
    private var isReadOnly: Bool { trip?.status == .completed || trip?.status == .canceled }

    var body: some View {
        Group {
            if let plan {
                VStack(spacing: 0) {
                    Picker("Places view", selection: $showingMap) {
                        Text("List").tag(false); Text("Map").tag(true)
                    }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                    if showingMap {
                        StopsOverviewMap(stops: visiblePlaces(plan).map(\.mapStop), color: UIColor(appearance.color)) { stop in
                            editingPlace = plan.place(stop.id).map { PlaceEditorPresentation.existing($0) }
                        }
                    } else {
                        List {
                            Section {
                                if let trip { TripScheduleSummary(trip: trip, schedules: store.schedules) }
                                else {
                                    LabeledContent("Total time") {
                                        Text(TripScheduler.totalDuration(plan: plan)?.label ?? "Estimates unavailable")
                                            .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                                            .accessibilityIdentifier("total-time")
                                    }
                                }
                                if !isReadOnly { Button("Refresh travel estimates", systemImage: "arrow.clockwise") { store.retryRoutes() } }
                            }
                            if let trip {
                                Section("Trip") {
                                    if !isReadOnly { Button(trip.status == .active ? "Edit trip name and time zone" : "Edit trip name, start, and time zone") { editingTripTiming = true } }
                                    if trip.status != .scheduled {
                                        LabeledContent("Original planned start") { Text(trip.scheduledStart, format: .dateTime.month().day().hour().minute()) }
                                    }
                                }.environment(\.timeZone, TimeZone(identifier: trip.timeZoneIdentifier) ?? .current)
                                if !isReadOnly { EffectiveRouteRows(trip: trip, schedules: store.schedules) }
                            }
                            if let trip, !plan.requirements.isEmpty { timeBindings(trip) }
                            Section("Places") {
                                if plan.places.isEmpty { Text("Add a place to start building your plan.").foregroundStyle(.secondary) }
                                ForEach(Array(plan.places.enumerated()), id: \.element.id) { index, place in
                                    placeRow(place, number: index + 1)
                                        .moveDisabled(isReadOnly || (trip?.status == .active && (trip?.activePlaceID == place.id || trip?.visits[place.id] != nil)))
                                        .deleteDisabled(trip?.status == .completed || trip?.status == .canceled)
                                    if editMode != .active,
                                       let leg = plan.legs.first(where: { $0.fromPlaceID == place.id }),
                                       let next = plan.place(leg.toPlaceID) {
                                        Button { editingLeg = leg } label: {
                                            HStack(spacing: 12) {
                                                Image(systemName: "ellipsis").frame(width: 32).foregroundStyle(.tertiary)
                                                Image(systemName: leg.mode.symbol)
                                                Text(leg.mode.title)
                                                Spacer()
                                                Text(leg.duration?.label ?? "Unavailable")
                                                    .font(.subheadline).foregroundStyle(.secondary)
                                            }.foregroundStyle(Color.primary)
                                        }.accessibilityLabel("Travel to \(next.name)")
                                    }
                                }
                                .onDelete { offsets in
                                    guard !isReadOnly else { return }
                                    let ids = offsets.map { plan.places[$0].id }
                                    changePlan { value in value.places.removeAll { ids.contains($0.id) } }
                                    if let trip { for id in ids { store.changeTrip(trip.id) { TripEngine.delete(&$0, placeID: id, at: Date()) } } }
                                }
                                .onMove { source, destination in
                                    guard !isReadOnly else { return }
                                    var order = plan.places.map(\.id)
                                    order.move(fromOffsets: source, toOffset: destination)
                                    if let trip { store.changeTrip(trip.id) { TripEngine.reorder(&$0, ids: order, at: Date()) } }
                                    else { changePlan { value in value.places = order.compactMap { id in value.place(id) } } }
                                }
                                if !isReadOnly {
                                    Button("Add place", systemImage: "plus") { editingPlace = .new() }.accessibilityIdentifier("add-place")
                                }
                            }
                            Section("Starting approach") {
                                if isReadOnly {
                                    LabeledContent("Travel mode", value: plan.initialMode.title)
                                } else {
                                    Picker("Travel mode", selection: Binding(get: { plan.initialMode }, set: { mode in
                                        if let trip { store.changeTrip(trip.id) { value in
                                            guard value.status == .scheduled || value.status == .active else { return }
                                            value.plan.initialMode = mode; value.plan.reconcileLegs(); value.approachEstimate = nil
                                        } }
                                        else { changePlan { $0.initialMode = mode } }
                                    })) {
                                        ForEach(TravelMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                                    }
                                }
                                if let first = plan.legs.first {
                                    Button(isReadOnly ? "View approach estimate" : "Set approach estimate") { editingLeg = first }
                                }
                                if let trip, trip.status == .scheduled {
                                    StartingOriginControl(tripID: trip.id, location: store.location)
                                }
                            }
                            if let trip {
                                Section {
                                    NavigationLink { reminders(trip) } label: { Label("Notifications", systemImage: "bell") }
                                    NavigationLink { VisitHistoryView(tripID: trip.id) } label: {
                                        Label("Visit history", systemImage: "clock.arrow.circlepath")
                                    }.accessibilityIdentifier("visit-history")
                                    if let phase = trip.phase, phase.kind != .exploring {
                                        Button(phase.kind == .exiting ? "Confirm Exit manually" : "Confirm arrival manually") { store.confirm(tripID: trip.id, phase: phase) }
                                    }
                                    if !isReadOnly && (!trip.skippedPlaceIDs.isEmpty || plan.places.contains(where: { trip.allocation(for: $0.id) < $0.duration.maximum })) {
                                        Button("Restore optional places and durations") { store.restoreAdjustments(trip.id) }
                                    }
                                    Button("Save as reusable plan") { store.saveTemplate(from: trip, updateOriginal: false) }
                                    if trip.sourcePlanID != nil { Button("Update original reusable plan") { store.saveTemplate(from: trip, updateOriginal: true) } }
                                    Button("Schedule another trip") { scheduling = true }
                                    if trip.status == .active || trip.status == .scheduled {
                                        Button("Cancel trip", role: .destructive) { confirmCancel = true }
                                    }
                                }
                            }
                        }.environment(\.editMode, $editMode)
                    }
                }
                .navigationTitle(plan.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if trip != nil {
                                Button("Add to Apple Calendar", systemImage: "calendar.badge.plus") {
                                    showingAppleCalendar = true
                                }.accessibilityIdentifier("add-apple-calendar")
                                Button("Add to Google Calendar", systemImage: "calendar.badge.plus") {
                                    showingGoogleCalendar = true
                                }.accessibilityIdentifier("add-google-calendar")
                                Button("Share calendar", systemImage: "square.and.arrow.up") {
                                    shareCalendar()
                                }.disabled(preparingCalendar)
                                    .accessibilityIdentifier("share-trip-calendar")
                            }
                            if tripID == nil, planID != nil {
                                Button("Rename plan", systemImage: "pencil") {
                                    planName = plan.name
                                    renamingPlan = true
                                }.accessibilityIdentifier("rename-plan")
                            }
                            if !isReadOnly {
                                Button(editMode == .active ? "Done reordering" : "Reorder places", systemImage: "arrow.up.arrow.down") {
                                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                                }
                                Button("Add place", systemImage: "plus") { editingPlace = .new() }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityIdentifier("plan-options")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        if let trip {
                            if trip.status == .active { store.startTrip(trip.id, completion: onOpenCompass) }
                            else if trip.status == .scheduled { store.startTrip(trip.id, completion: onOpenCompass) }
                            else { scheduling = true }
                        } else { scheduling = true }
                    } label: {
                        Text(trip?.status == .active ? "Resume compass" : trip?.status == .scheduled ? "Start trip" : "Schedule trip")
                            .font(.headline).frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(plan.places.isEmpty)
                        .accessibilityIdentifier("open-compass").padding().background(.bar)
                }
                .sheet(item: $editingPlace) { presentation in
                    let original = presentation.place
                    let creating = presentation.isNew
                    PlaceEditorView(place: original, readOnly: isReadOnly) { draft, completion in
                        if let trip {
                            store.changeTrip(trip.id, completion: completion) { value in
                                if creating {
                                    guard value.plan.place(draft.id) == nil else { return }
                                    TripEngine.upsert(&value, place: draft, at: Date())
                                } else {
                                    guard let original, let current = value.plan.place(original.id) else { return }
                                    TripEngine.upsert(&value, place: current.applyingChanges(from: original, draft: draft), at: Date())
                                }
                            }
                        } else {
                            changePlan(completion: completion) { value in
                                if creating {
                                    guard value.place(draft.id) == nil else { return }
                                    value.places.append(draft)
                                } else {
                                    guard let original, let index = value.places.firstIndex(where: { $0.id == original.id }) else { return }
                                    value.places[index] = value.places[index].applyingChanges(from: original, draft: draft)
                                }
                            }
                        }
                    }
                }
                .sheet(item: $editingLeg) { leg in
                    LegEditorView(leg: leg, readOnly: isReadOnly) { updated in
                        if let trip {
                            store.changeTrip(trip.id) { value in
                                guard value.status == .scheduled || value.status == .active,
                                      let index = value.plan.legs.firstIndex(where: { $0.id == updated.id }) else { return }
                                value.plan.legs[index].mode = updated.mode
                                value.plan.legs[index].manualDuration = updated.manualDuration
                                value.plan.legs[index].estimate = nil
                                if updated.fromPlaceID == nil { value.plan.initialMode = updated.mode }
                                value.approachEstimate = nil
                            }
                        } else {
                            changePlan { value in
                                guard let index = value.legs.firstIndex(where: { $0.id == updated.id }) else { return }
                                value.legs[index] = updated
                                if updated.fromPlaceID == nil { value.initialMode = updated.mode }
                            }
                        }
                    }
                }
                .sheet(isPresented: $scheduling) {
                    ScheduleTripView(plan: plan) {
                        scheduling = false
                        showScheduledTrip = true
                    }
                }
                .sheet(isPresented: $editingTripTiming) {
                    if let trip { TripTimingEditor(trip: trip) }
                }
                .sheet(item: $calendarExport) { file in
                    TripCalendarShareSheet(file: file) { error in
                        calendarExport = nil
                        if let error { calendarExportError = error }
                    }
                }
                .sheet(isPresented: $showingAppleCalendar) {
                    if let tripID { TripAppleCalendarView(tripID: tripID) }
                }
                .sheet(isPresented: $showingGoogleCalendar) {
                    if let tripID { TripGoogleCalendarView(tripID: tripID) }
                }
                .navigationDestination(isPresented: $showScheduledTrip) {
                    if let id = store.library.selectedTripID { ConfigurationView(tripID: id, onOpenCompass: onOpenCompass) }
                }
                .onChange(of: isReadOnly) { _, readOnly in
                    if readOnly {
                        editMode = .inactive
                        if editingPlace?.isNew == true { editingPlace = nil }
                        editingTripTiming = false
                    }
                }
                .alert("Cancel this trip?", isPresented: $confirmCancel) {
                    Button("Keep trip", role: .cancel) { }
                    Button("Cancel trip", role: .destructive) { if let trip { store.cancelTrip(trip.id) } }
                } message: { Text("Recorded visits are kept. Location tracking and pending notifications will stop.") }
                .alert("Rename plan", isPresented: $renamingPlan) {
                    TextField("Plan name", text: $planName)
                        .accessibilityIdentifier("rename-plan-name")
                    Button("Cancel", role: .cancel) { }
                    Button("Save") {
                        let name = planName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        changePlan { $0.name = name }
                    }.disabled(planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .alert("Calendar unavailable", isPresented: Binding(
                    get: { calendarExportError != nil },
                    set: { if !$0 { calendarExportError = nil } }
                )) {
                    Button("OK", role: .cancel) { calendarExportError = nil }
                } message: { Text(calendarExportError ?? "") }
            } else { ContentUnavailableView("Plan unavailable", systemImage: "map") }
        }
    }

    private func timeBindings(_ trip: Trip) -> some View {
        Section("Scheduled times") {
            ForEach(trip.includedPlaces) { place in
                ForEach(place.requirements) { requirement in
                    if isReadOnly {
                        LabeledContent(requirement.label.isEmpty ? requirement.kind.title : requirement.label) {
                            if let date = trip.bindings[requirement.id] { Text(date, format: .dateTime.month().day().hour().minute()) }
                            else { Text("Not set").foregroundStyle(.secondary) }
                        }
                    } else {
                        RequirementBindingRow(trip: trip, placeID: place.id, requirement: requirement,
                                              value: trip.bindings[requirement.id], fallback: trip.scheduledStart)
                    }
                }
            }
        }.environment(\.timeZone, TimeZone(identifier: trip.timeZoneIdentifier) ?? .current)
    }

    private func visiblePlaces(_ plan: Plan) -> [Place] {
        plan.places.filter { trip?.skippedPlaceIDs.contains($0.id) != true }
    }
    private func changePlan(completion: ((Bool) -> Void)? = nil, _ edit: @escaping (inout Plan) -> Void) {
        if let planID { store.changePlan(planID, completion: completion, edit) }
        else { completion?(false) }
    }

    private func shareCalendar() {
        guard let trip, !preparingCalendar else { return }
        let origin = store.liveOrigin
        preparingCalendar = true
        Task {
            defer { preparingCalendar = false }
            do {
                calendarExport = try await TripCalendarShareFile.prepare(trip: trip, origin: origin, at: Date())
            } catch {
                calendarExportError = error.localizedDescription
            }
        }
    }

    private func placeRow(_ place: Place, number: Int) -> some View {
        Button { editingPlace = .existing(place) } label: {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)").font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white).frame(width: 32, height: 32).background(appearance.color, in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(place.name).font(.body).foregroundStyle(Color.primary)
                    if let trip { TripPlaceTiming(place: place, trip: trip, schedules: store.schedules) }
                    else { Text(place.duration.label).font(.subheadline).foregroundStyle(.secondary) }
                    if let trip {
                        if trip.skippedPlaceIDs.contains(place.id) { Label("Skipped", systemImage: "forward.end").font(.caption).foregroundStyle(.secondary) }
                        else if trip.visits[place.id]?.completed == true { Label("Visited", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                        else if trip.activePlaceID == place.id { Text("Current place").font(.caption).foregroundStyle(appearance.color) }
                    }
                    if place.isOptional { Text("Optional · priority \(place.keepPriority)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 3)
        }.accessibilityIdentifier("place-row-\(number)")
    }

    @ViewBuilder private func reminders(_ trip: Trip) -> some View {
        let eligibleEvents = TripReminderEligibility.events(for: trip)
        if isReadOnly { PastReminderStatusView(trip: trip) }
        else { ReminderSettingsView(reminders: Binding(get: { store.library.trips.first { $0.id == trip.id }?.reminders ?? [] }, set: { reminders in
            store.changeTrip(trip.id) { $0.reminders = reminders }
        }), arrivalNotificationsEnabled: Binding(get: { store.library.trips.first { $0.id == trip.id }?.arrivalNotificationsEnabled ?? false }, set: { enabled in
            store.changeTrip(trip.id) { $0.arrivalNotificationsEnabled = enabled }
        }), events: ([ReminderEventOption(event: .tripDeparture, title: "Before trip starts", category: .tripStart)] + trip.includedPlaces.flatMap { place in
            [ReminderEventOption(event: .placeDeparture(place.id), title: "Before leaving \(place.name)", category: .placeDeparture)] + place.requirements.map { requirement in
                let title: String
                let detail: String
                switch requirement.kind {
                case .appointment:
                    title = "Appointment at \(place.name)"
                    detail = "Before the assigned appointment time at Entry."
                case .arriveBy:
                    title = "Arrive by · \(place.name)"
                    detail = "Before the assigned Entry deadline."
                case .leaveBy:
                    title = "Leave by · \(place.name)"
                    detail = "Before the assigned Exit deadline."
                }
                return ReminderEventOption(event: .requirement(requirement.id), title: title, category: .timeRequirement,
                                           detail: requirement.label.isEmpty ? detail : "\(requirement.label)\n\(detail)")
            }
        }).filter { eligibleEvents.contains($0.event) }, service: store.reminderService)
            .environment(\.timeZone, TimeZone(identifier: trip.timeZoneIdentifier) ?? .current) }
    }
}

struct TripScheduleSummary: View {
    @EnvironmentObject private var store: TripStore
    let trip: Trip
    @ObservedObject var schedules: TripSchedules
    var body: some View {
        Group {
            LabeledContent("Status", value: trip.status == .active ? "In progress" : trip.status.rawValue.capitalized)
            if trip.status == .scheduled {
                LabeledContent("Planned start") { Text(trip.scheduledStart, format: .dateTime.month().day().hour().minute()) }
                Text("Estimates begin at this planned start.").font(.footnote).foregroundStyle(.secondary)
            } else {
                LabeledContent("Started") {
                    if let started = trip.startedAt { Text(started, format: .dateTime.month().day().hour().minute()) }
                    else { Text("Unknown").foregroundStyle(.secondary) }
                }
                if trip.status == .active {
                    Text("Estimates use current progress and time. The original planned start no longer sets the forecast.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Places") { Text("\(trip.visitedCount)/\(trip.includedPlaces.count)") }
            if let schedule = schedules.values[trip.id] {
                if let start = schedule.startBy {
                    LabeledContent(schedule.isAdjusted ? "Start by · adjusted" : "Start by") {
                        Text(start, format: .dateTime.month(.abbreviated).day().hour().minute()).multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Estimated completion") { Text(completionText(schedule.completion, timeZoneIdentifier: trip.timeZoneIdentifier)).multilineTextAlignment(.trailing) }
                if trip.status == .scheduled || trip.status == .active { TripTimeBreakdown(trip: trip, schedule: schedule) }
                if !schedule.unresolvedRequirementIDs.isEmpty { Text("Choose required times").foregroundStyle(.orange) }
                if schedule.hasCachedEstimates { Text("Using saved travel estimates").font(.caption).foregroundStyle(.secondary) }
                if schedule.isAdjusted {
                    Text("Shortened visits stay shortened until you use Restore optional places and durations.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ScheduleFeedbackView(plan: trip.plan, schedule: schedule, plannedStart: trip.scheduledStart,
                                     timeZoneIdentifier: trip.timeZoneIdentifier) { date in
                    store.changeTrip(trip.id) { value in
                        guard value.status == .scheduled else { return }
                        value.scheduledStart = date
                    }
                }
            } else { Text("Calculating schedule…").foregroundStyle(.secondary) }
        }.environment(\.timeZone, TimeZone(identifier: trip.timeZoneIdentifier) ?? .current)
    }
}

private struct TripTimeBreakdown: View {
    let trip: Trip
    let schedule: TripScheduleProjection

    var body: some View {
        LabeledContent("Visits remaining", value: totalSeconds(\.remainingVisitSeconds))
            .accessibilityIdentifier("time-breakdown-visits")
        LabeledContent("Travel remaining", value: totalRanges(\.incomingTravel))
            .accessibilityIdentifier("time-breakdown-travel")
        LabeledContent("Free time before appointments", value: totalRanges(\.waiting))
            .accessibilityIdentifier("time-breakdown-waiting")
        LabeledContent("Visit time that can be shortened", value: totalSeconds(\.reducibleVisitSeconds))
            .accessibilityIdentifier("time-breakdown-reducible")
        Text("Time that can be shortened is part of visits remaining. Free time is waiting before an appointment. Travel and waiting can offset each other; Estimated completion gives the overall finish.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private func totalSeconds(_ field: KeyPath<ScheduledPlace, Int?>) -> String {
        let values = trip.remainingPlaces.map { place -> DurationRange? in
            guard let projected = schedule.place(place.id), let seconds = projected[keyPath: field], seconds >= 0 else { return nil }
            return DurationRange(minimum: seconds, maximum: seconds)
        }
        return timingTotal(values)
    }
    private func totalRanges(_ field: KeyPath<ScheduledPlace, DurationRange?>) -> String {
        timingTotal(trip.remainingPlaces.map { place in schedule.place(place.id)?[keyPath: field] })
    }
}

private struct TripPlaceTiming: View {
    let place: Place
    let trip: Trip
    @ObservedObject var schedules: TripSchedules

    var body: some View {
        let projected = schedules.values[trip.id]?.place(place.id)
        let visit = trip.visits[place.id]
        let included = trip.includedPlaces.contains { $0.id == place.id }
        let allocatedSeconds = projected?.allocation ?? trip.allocation(for: place.id)
        let allocation = DurationRange(minimum: allocatedSeconds, maximum: allocatedSeconds)
        VStack(alignment: .leading, spacing: 4) {
            Text("Allocated \(allocation.label) · \(place.duration.isFixed ? "Fixed" : "Allowed") \(place.duration.label)")
                .accessibilityIdentifier("place-allocation-\(place.id)")
            if let arrival = visit?.arrivedAt {
                Text("Arrived \(timingDateRange(arrival...arrival, trip: trip))")
            } else if included && visit == nil {
                Text("Expected arrival: \(timingDateRange(projected?.arrival, trip: trip))")
            } else if visit != nil { Text("Arrival time unknown") }
            if let exit = visit?.exitedAt {
                Text("Left \(timingDateRange(exit...exit, trip: trip))")
            } else if included && visit?.completed != true {
                Text("Planned departure: \(timingDateRange(projected?.exit, trip: trip))")
                if !place.duration.isFixed {
                    Text("Visit can shorten by \(timingSeconds(projected?.reducibleVisitSeconds))")
                        .accessibilityIdentifier("place-reducible-\(place.id)")
                }
                if let waiting = projected?.waiting, waiting.isValid, waiting.maximum > 0 {
                    Text("Free time before appointment: \(waiting.label)")
                        .accessibilityIdentifier("place-waiting-\(place.id)")
                }
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

private func timingSeconds(_ seconds: Int?) -> String {
    guard let seconds, seconds >= 0 else { return "Unknown" }
    return DurationRange(minimum: seconds, maximum: seconds).label
}

private func timingTotal(_ values: [DurationRange?]) -> String {
    var lower = 0
    var upper = 0
    for value in values {
        guard let value, value.isValid else { return "Unknown" }
        let nextLower = lower.addingReportingOverflow(value.minimum)
        let nextUpper = upper.addingReportingOverflow(value.maximum)
        guard !nextLower.overflow, !nextUpper.overflow else { return "Unknown" }
        lower = nextLower.partialValue
        upper = nextUpper.partialValue
    }
    return DurationRange(minimum: lower, maximum: upper).label
}

private func timingDateRange(_ range: ClosedRange<Date>?, trip: Trip) -> String {
    guard let range, range.lowerBound.timeIntervalSince1970.isFinite, range.upperBound.timeIntervalSince1970.isFinite else { return "Unknown" }
    return completionText(range, timeZoneIdentifier: trip.timeZoneIdentifier)
}

/// Uses the same current allocations and travel bounds as the timeline and completion estimate.
struct ScheduleFeedbackView: View {
    let plan: Plan
    let schedule: TripScheduleProjection
    let plannedStart: Date
    let timeZoneIdentifier: String
    var onUseStartBy: ((Date) -> Void)? = nil

    var body: some View {
        if schedule.hasTimeConflicts {
            VStack(alignment: .leading, spacing: 5) {
                Label(schedule.isRunningBehind ? "Running behind" :
                        schedule.maximumLatenessRange.lowerBound > 0 ? "Schedule doesn’t fit" : "Schedule may run over",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.headline).accessibilityIdentifier("schedule-conflict-status")
                Text(schedule.conflicts.contains(where: \.isLowerBoundOnly) ?
                     "At least \(scheduleDurationText(schedule.maximumLatenessRange.lowerBound)) over" :
                     scheduleOverrunText(schedule.maximumLatenessRange))
                    .accessibilityIdentifier("schedule-overrun")
            }.foregroundStyle(.orange)
            ForEach(schedule.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(plan.place(conflict.placeID)?.name ?? "Place") · \(conflict.kind == .leaveBy ? "Leave this place by" : conflict.kind.title)")
                        .font(.subheadline.weight(.medium))
                    LabeledContent("Deadline") {
                        Text(conflict.deadline, format: .dateTime.month().day().hour().minute())
                    }
                    if conflict.isLowerBoundOnly {
                        LabeledContent(conflict.kind == .leaveBy ? "Departure no earlier than" : "Arrival no earlier than") {
                            Text(conflict.predicted, format: .dateTime.month().day().hour().minute())
                                .multilineTextAlignment(.trailing)
                        }
                        Text("At least \(scheduleDurationText(conflict.lateness)) over").foregroundStyle(.orange)
                    } else {
                        LabeledContent(conflict.kind == .leaveBy ? "Expected departure" : "Expected arrival") {
                            Text(completionText(predictedRange(conflict), timeZoneIdentifier: timeZoneIdentifier))
                                .multilineTextAlignment(.trailing)
                        }
                        Text(scheduleOverrunText(schedule.latenessRange(for: conflict))).foregroundStyle(.orange)
                    }
                }.font(.caption)
                    .accessibilityIdentifier("schedule-conflict-\(conflict.requirementID)")
            }
            if schedule.status == .scheduled {
                if let startBy = schedule.startBy, plannedStart > startBy {
                    Text("Start \(scheduleDurationText(plannedStart.timeIntervalSince(startBy))) earlier to fit the current visits and travel estimates.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let onUseStartBy {
                        Button("Use latest feasible start") { onUseStartBy(startBy) }
                            .accessibilityIdentifier("use-feasible-start")
                    }
                } else if schedule.startBy == nil && !schedule.hasUnknownEstimates {
                    Text("These times cannot all fit with the current visit durations and travel estimates, even with an earlier start. Change a deadline, visit duration, or the included places.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("incompatible-schedule-times")
                }
            }
        } else if (schedule.status == .scheduled || schedule.status == .active) &&
                    !schedule.hasUnknownEstimates && plan.places.contains(where: { !$0.requirements.isEmpty }) {
            Label(schedule.status == .active ? "On schedule" : "Schedule fits", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary).accessibilityIdentifier("schedule-fits")
        }
    }

    private func predictedRange(_ conflict: ScheduleConflict) -> ClosedRange<Date>? {
        let place = schedule.place(conflict.placeID)
        return conflict.kind == .leaveBy ? place?.exit : place?.arrival
    }
}

func scheduleDurationText(_ seconds: TimeInterval) -> String {
    durationText(.init(minimum: Int(ceil(max(0, seconds))), maximum: Int(ceil(max(0, seconds)))))
}

func scheduleOverrunText(_ range: ClosedRange<TimeInterval>) -> String {
    if range.lowerBound <= 0 { return "Up to \(scheduleDurationText(range.upperBound)) over" }
    let duration = DurationRange(minimum: Int(ceil(range.lowerBound)), maximum: Int(ceil(range.upperBound)))
    return "\(durationText(duration)) over"
}

func completionText(_ range: ClosedRange<Date>?, timeZoneIdentifier: String = TimeZone.current.identifier) -> String {
    guard let range else { return "Unavailable" }
    let zone = TimeZone(identifier: timeZoneIdentifier) ?? .current
    var calendar = Calendar.current
    calendar.timeZone = zone
    let sameDay = calendar.isDate(range.lowerBound, inSameDayAs: range.upperBound)
    let today = sameDay && calendar.isDate(range.lowerBound, inSameDayAs: Date())
    let formatter = DateIntervalFormatter()
    formatter.timeZone = zone
    formatter.dateStyle = today ? .none : .medium
    formatter.timeStyle = .short
    if calendar.isDate(range.lowerBound, equalTo: range.upperBound, toGranularity: .minute) {
        let format = Date.FormatStyle(date: today ? .omitted : .abbreviated, time: .shortened, timeZone: zone)
        return range.lowerBound.formatted(format)
    }
    return formatter.string(from: range.lowerBound, to: range.upperBound)
}

private struct LegEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var leg: Leg
    @State private var manual: Bool
    @State private var duration: DurationRange
    var onSave: (Leg) -> Void
    var readOnly: Bool
    init(leg: Leg, readOnly: Bool = false, onSave: @escaping (Leg) -> Void) {
        _leg = State(initialValue: leg)
        _manual = State(initialValue: leg.manualDuration != nil)
        _duration = State(initialValue: leg.duration ?? .fiveMinutes)
        self.onSave = onSave
        self.readOnly = readOnly
    }
    var body: some View {
        NavigationStack {
            Form {
                if readOnly {
                    LabeledContent("Travel mode", value: leg.mode.title)
                    LabeledContent("Duration", value: leg.duration?.label ?? "Unknown")
                    LabeledContent("Source", value: leg.manualDuration != nil ? "Manual estimate" : "Apple Maps")
                } else {
                Picker("Travel mode", selection: $leg.mode) {
                    ForEach(TravelMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                }.pickerStyle(.segmented)
                Toggle("Enter travel time manually", isOn: $manual)
                if manual { DurationFields(duration: $duration) }
                else {
                    LabeledContent("Apple Maps", value: leg.estimate?.duration.label ?? "Estimate unavailable")
                    Text("The upper estimate includes a 20% buffer.").font(.caption).foregroundStyle(.secondary)
                }
                }
            }.navigationTitle("Travel")
                .toolbar {
                    if readOnly {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    } else {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { leg.manualDuration = manual ? duration : nil; leg.estimate = nil; onSave(leg); dismiss() }
                                .disabled(manual && !duration.isValid)
                        }
                    }
                }
        }
    }
}

struct OrganizerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                NavigationLink { AppearanceView() } label: { Label("Appearance", systemImage: "paintpalette") }
                NavigationLink { PINSettingsView() } label: { Label("Configuration PIN", systemImage: "lock") }
                Section("WonderWhere") {
                    NavigationLink {
                        AppInformationView(title: "About", resource: "about")
                    } label: { Label("About WonderWhere", systemImage: "info.circle") }
                        .accessibilityIdentifier("about-wonderwhere")
                    NavigationLink {
                        AppInformationView(title: "Privacy Policy", resource: "privacy-policy")
                    } label: { Label("Privacy Policy", systemImage: "hand.raised") }
                        .accessibilityIdentifier("privacy-policy")
                    NavigationLink {
                        AppInformationView(title: "Help", resource: "support")
                    } label: { Label("Help", systemImage: "questionmark.circle") }
                        .accessibilityIdentifier("app-help")
                    Link(destination: URL(string: "mailto:trystinduffy@gmail.com?subject=WonderWhere%20Support")!) {
                        Label("Contact Support", systemImage: "envelope")
                    }
                    Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                        Label("Terms of Use", systemImage: "doc.text")
                    }
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                }
            }.navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct RequirementBindingRow: View {
    @EnvironmentObject private var store: TripStore
    let trip: Trip
    let placeID: UUID
    let requirement: TimeRequirement
    let value: Date?
    let fallback: Date
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { editing = true } label: {
                LabeledContent(requirement.label.isEmpty ? requirement.kind.title : requirement.label) {
                    if let value { Text(value, format: .dateTime.month().day().hour().minute()) }
                    else { Text("Set time").foregroundStyle(.orange) }
                }
            }
            RequirementTimingDetail(trip: trip, placeID: placeID, requirement: requirement, bound: value, schedules: store.schedules)
        }.sheet(isPresented: $editing) {
            RequirementTimeEditor(title: requirement.label, initial: value ?? fallback, explanation: requirement.kind.schedulingExplanation) { date in
                store.changeTrip(trip.id) { TripEngine.editBinding(&$0, requirementID: requirement.id, date: date, at: Date()) }
            }
        }
    }
}

private struct RequirementTimingDetail: View {
    let trip: Trip
    let placeID: UUID
    let requirement: TimeRequirement
    let bound: Date?
    @ObservedObject var schedules: TripSchedules

    var body: some View {
        let projected = schedules.values[trip.id]?.place(placeID)
        let observed = requirement.kind == .leaveBy ? trip.visits[placeID]?.exitedAt : trip.visits[placeID]?.arrivedAt
        let expected = observed.map { $0...$0 } ?? (requirement.kind == .leaveBy ? projected?.exit : projected?.arrival)
        VStack(alignment: .leading, spacing: 4) {
            if requirement.kind == .leaveBy, let place = trip.plan.place(placeID) {
                let arrival = trip.visits[placeID]?.arrivedAt.map { $0...$0 } ?? projected?.arrival
                let seconds = projected?.allocation ?? trip.allocation(for: placeID)
                let allocated = DurationRange(minimum: seconds, maximum: seconds).label
                Text("Expected arrival: \(timingDateRange(arrival, trip: trip))")
                Text(place.duration.isFixed
                     ? "Visit: \(allocated) · Fixed duration"
                     : "Visit: \(allocated) allocated · \(place.duration.label) allowed")
                    .accessibilityIdentifier("departure-visit-duration-\(placeID)")
            }
            Text("\(requirement.kind == .leaveBy ? "Expected departure" : "Expected arrival"): \(timingDateRange(expected, trip: trip))")
            if let bound { Text(timingDeadlineMargin(expected, deadline: bound)) }
            switch requirement.kind {
            case .leaveBy:
                Text("The planned visit must fit its set duration and this departure deadline. If both cannot fit, the schedule shows the overrun.")
            case .appointment:
                if let waiting = projected?.waiting, waiting.isValid {
                    Text("Free time before appointment: \(waiting.label)")
                } else { Text("Free time before appointment: Unknown") }
            case .arriveBy:
                Text("This is an arrival deadline; arriving early does not add waiting time.")
            }
        }.font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier("requirement-timing-\(requirement.id)")
    }
}

private func timingDeadlineMargin(_ expected: ClosedRange<Date>?, deadline: Date) -> String {
    guard let expected else { return "Time before or over deadline: Unknown" }
    let least = deadline.timeIntervalSince(expected.upperBound)
    let most = deadline.timeIntervalSince(expected.lowerBound)
    guard least.isFinite, most.isFinite else { return "Time before or over deadline: Unknown" }
    if least >= 0 { return "\(timingInterval(least, most)) before deadline" }
    if most <= 0 { return "\(timingInterval(-most, -least)) over deadline" }
    return "\(timingInterval(most, most)) before to \(timingInterval(-least, -least)) over deadline"
}

private func timingInterval(_ minimum: TimeInterval, _ maximum: TimeInterval) -> String {
    guard minimum.isFinite, maximum.isFinite, minimum >= 0, maximum >= minimum,
          maximum < Double(Int.max) else { return "Unknown" }
    return DurationRange(minimum: Int(ceil(minimum)), maximum: Int(ceil(maximum))).label
}

private struct RequirementTimeEditor: View {
    let title: String
    @State private var date: Date
    var onSave: (Date) -> Void
    var explanation: String?
    @Environment(\.dismiss) private var dismiss
    init(title: String, initial: Date, explanation: String? = nil, onSave: @escaping (Date) -> Void) {
        self.title = title; _date = State(initialValue: initial); self.explanation = explanation; self.onSave = onSave
    }
    var body: some View {
        NavigationStack {
            Form {
                DatePicker(title, selection: $date, displayedComponents: [.date, .hourAndMinute])
                if let explanation { Text(explanation).font(.footnote).foregroundStyle(.secondary) }
            }
                .navigationTitle("Scheduled time").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(date); dismiss() } }
                }
        }
    }
}

private struct TripTimingEditor: View {
    let trip: Trip
    @EnvironmentObject private var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var date: Date
    @State private var zone: String
    private var currentTrip: Trip { store.library.trips.first { $0.id == trip.id } ?? trip }
    init(trip: Trip) {
        self.trip = trip; _name = State(initialValue: trip.plan.name)
        _date = State(initialValue: trip.scheduledStart); _zone = State(initialValue: trip.timeZoneIdentifier)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Trip name", text: $name)
                if currentTrip.status == .scheduled {
                    DatePicker("Planned start", selection: $date, displayedComponents: [.date, .hourAndMinute])
                } else {
                    LabeledContent("Started") {
                        if let started = currentTrip.startedAt { Text(started, format: .dateTime.month().day().hour().minute()) }
                        else { Text("Unknown").foregroundStyle(.secondary) }
                    }
                    LabeledContent("Planned start") { Text(currentTrip.scheduledStart, format: .dateTime.month().day().hour().minute()) }
                    Text("This trip has already started. Estimates now use current progress and time; the planned start is kept as a record.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Picker("Time zone", selection: $zone) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                }
            }.environment(\.timeZone, TimeZone(identifier: zone) ?? .current)
                .navigationTitle("Trip time")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            store.changeTrip(trip.id) { value in
                                guard value.status == .scheduled || value.status == .active else { return }
                                value.plan.name = name
                                if value.status == .scheduled { value.scheduledStart = date }
                                value.timeZoneIdentifier = zone
                            }
                            dismiss()
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

private struct EffectiveRouteRows: View {
    let trip: Trip
    @ObservedObject var schedules: TripSchedules
    private var requests: [RouteRequestContext] {
        var result = schedules.values[trip.id]?.missingRoutes.filter { $0.kind != .fullLeg } ?? []
        for request in ManualRouteContexts.requests(for: trip) {
            if !result.contains(where: { $0.source.sameCoordinates(as: request.source) && $0.destination.sameCoordinates(as: request.destination) && $0.mode == request.mode }) {
                result.append(request)
            }
        }
        return result
    }
    var body: some View {
        if !requests.isEmpty {
            Section("Connection estimates") {
                ForEach(requests, id: \.cacheKey) { request in
                    NavigationLink {
                        RouteEstimateEditor(tripID: trip.id, request: request)
                    } label: {
                        Label("Travel to \(trip.plan.place(request.toPlaceID)?.name ?? "place")", systemImage: request.mode.symbol)
                    }
                }
            }
        }
    }
}

/// A foreground-only locator belongs to this explicit capture action. It never restarts or stops
/// TripStore's active background tracking session.
private struct StartingOriginControl: View {
    let tripID: UUID
    @ObservedObject var location: LocationService
    @EnvironmentObject private var store: TripStore
    @StateObject private var locator = LocationService()
    @State private var waiting = false
    @State private var ownsLocator = false
    @State private var saving = false
    @State private var feedback: String?

    var body: some View {
        Button("Use current starting location", systemImage: "location", action: begin)
            .disabled(waiting || saving)
            .accessibilityIdentifier("capture-starting-origin")
            .onReceive(location.$position) { position in
                if !ownsLocator { capture(position) }
            }
            .onReceive(locator.$position) { position in
                if ownsLocator { capture(position) }
            }
            .onDisappear { stop() }
        if waiting {
            HStack {
                ProgressView().controlSize(.small)
                Text((ownsLocator ? locator.message : location.message) ?? "Finding current location…")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { stop(); feedback = nil }
            }.accessibilityIdentifier("waiting-for-starting-origin")
        } else if saving {
            ProgressView("Saving starting location…").font(.footnote)
        } else if let feedback {
            Text(feedback).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func begin() {
        feedback = nil
        waiting = true
        if let position = location.position, position.isFresh(at: Date()) {
            capture(position)
        } else if store.activeTrip == nil {
            ownsLocator = true
            locator.start()
            capture(locator.position)
        }
    }

    private func capture(_ position: CLLocation?) {
        guard waiting, let position, position.isFresh(at: Date()) else { return }
        let point = Point(name: "Starting location", latitude: position.coordinate.latitude, longitude: position.coordinate.longitude)
        stop()
        saving = true
        Task {
            var accepted = false
            let saved = await store.transact { library in
                guard let index = library.trips.firstIndex(where: { $0.id == tripID }), library.trips[index].status == .scheduled else { return }
                library.trips[index].origin = point
                library.trips[index].revision += 1
                accepted = true
            }
            saving = false
            feedback = saved && accepted ? "Starting location updated." : "The starting location could not be updated."
            if saved && accepted { store.refresh() }
        }
    }

    private func stop() {
        waiting = false
        if ownsLocator { locator.stop(); ownsLocator = false }
    }
}

struct VisitHistoryView: View {
    let tripID: UUID
    @EnvironmentObject private var store: TripStore
    private var trip: Trip? { store.library.trips.first { $0.id == tripID } }
    private var records: [VisitRecord] {
        guard let trip else { return [] }
        let order = Dictionary(uniqueKeysWithValues: trip.plan.places.enumerated().map { ($0.element.id, $0.offset) })
        return trip.visits.values.sorted { first, second in
            let left = first.arrivedAt ?? first.exitedAt ?? first.removedAt ?? .distantPast
            let right = second.arrivedAt ?? second.exitedAt ?? second.removedAt ?? .distantPast
            if left != right { return left < right }
            let leftIndex = order[first.place.id] ?? Int.max, rightIndex = order[second.place.id] ?? Int.max
            return leftIndex == rightIndex ? first.place.id.uuidString < second.place.id.uuidString : leftIndex < rightIndex
        }
    }
    var body: some View {
        List {
            if records.isEmpty { Text("No visits have been recorded.").foregroundStyle(.secondary) }
            ForEach(records, id: \.place.id) { record in
                NavigationLink {
                    VisitRecordDetails(record: record)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.place.name)
                        if record.removedAt != nil { Label("Removed from plan", systemImage: "trash").font(.caption).foregroundStyle(.secondary) }
                        if let arrival = record.arrivedAt {
                            Text(arrival, format: .dateTime.month().day().hour().minute()).font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text(record.removedAt != nil && !record.completed ? "No arrival recorded" : "Arrival time unknown")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if record.arrivalManual || record.exitManual {
                            Text("Includes manual confirmation").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityIdentifier("visit-record-\(record.place.id.uuidString)")
            }
        }
        .navigationTitle("Visit history")
        .environment(\.timeZone, TimeZone(identifier: trip?.timeZoneIdentifier ?? "") ?? .current)
    }
}

private struct VisitRecordDetails: View {
    let record: VisitRecord
    var body: some View {
        Form {
            Section("Recorded progress") {
                LabeledContent("Status", value: record.completed ? "Completed" : record.removedAt != nil ? "Removed" : "Not completed")
                dateRow("Arrived", date: record.arrivedAt,
                        missing: record.removedAt != nil && !record.completed ? "Not recorded" : "Unknown")
                if record.arrivedAt != nil {
                    LabeledContent("Arrival confirmation", value: record.arrivalManual ? "Manual" : "Location")
                }
                dateRow("Departure requested", date: record.departureRequestedAt)
                dateRow("Exit confirmed", date: record.exitedAt, missing: record.completed ? "Unknown" : "Not recorded")
                if record.exitedAt != nil {
                    LabeledContent("Exit confirmation", value: record.exitManual ? "Manual" : "Location")
                }
                if let anchor = record.budgetAnchor { dateRow("Duration budget starts", date: anchor) }
                if let removed = record.removedAt { dateRow("Removed from plan", date: removed) }
            }
            PlaceSnapshotSections(place: record.place)
        }
        .navigationTitle(record.place.name).navigationBarTitleDisplayMode(.inline)
    }
    private func dateRow(_ title: String, date: Date?, missing: String = "Not recorded") -> some View {
        LabeledContent(title) {
            if let date { Text(date, format: .dateTime.month().day().year().hour().minute().second()).multilineTextAlignment(.trailing) }
            else { Text(missing).foregroundStyle(.secondary) }
        }
    }
}

private struct PastReminderStatusView: View {
    let trip: Trip
    var body: some View {
        List {
            if trip.reminders.isEmpty && !trip.arrivalNotificationsEnabled {
                Text("No notifications were configured.").foregroundStyle(.secondary)
            }
            if trip.arrivalNotificationsEnabled {
                Section("Arrivals") {
                    Text("Spoiler-free notifications were enabled for confirmed arrivals while the app was in the background.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(trip.reminders) { reminder in
                Section(title(reminder.event)) {
                    LabeledContent("Delivery", value: reminder.delivery.title)
                    LabeledContent("Status", value: reminder.status.rawValue == "off" ? "Inactive" : reminder.status.rawValue.capitalized)
                    if let date = reminder.scheduledAt {
                        LabeledContent("Scheduled for") { Text(date, format: .dateTime.month().day().hour().minute()) }
                    }
                    if let error = reminder.schedulingError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("Notifications")
            .environment(\.timeZone, TimeZone(identifier: trip.timeZoneIdentifier) ?? .current)
    }
    private func title(_ event: ReminderEvent) -> String {
        switch event {
        case .tripDeparture: return "Before trip starts"
        case .placeDeparture(let id): return "Before leaving \(trip.plan.place(id)?.name ?? trip.visits[id]?.place.name ?? "place")"
        case .requirement(let id):
            let requirement = trip.plan.requirements.first { $0.id == id } ?? trip.visits.values.flatMap { $0.place.requirements }.first { $0.id == id }
            guard let requirement else { return "Appointment or deadline" }
            return requirement.label.isEmpty ? requirement.kind.title : "\(requirement.kind.title) · \(requirement.label)"
        }
    }
}
