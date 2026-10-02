import SwiftUI
import Combine
import CoreLocation

/// Forecast publications are independent of durable plan and visit publications.
@MainActor final class TripSchedules: ObservableObject {
    @Published private(set) var values: [UUID: TripScheduleProjection] = [:]
    func set(_ value: TripScheduleProjection) {
        if values[value.tripID] != value { values[value.tripID] = value }
    }
}

@MainActor
final class TripStore: ObservableObject {
    @Published private(set) var library = TripLibrary()
    @Published private(set) var isLoading = true
    @Published var storageError: String?
    let location = LocationService()
    let schedules = TripSchedules()
    let reminderService: TripReminderService
    private let repository: TripRepository
    private let routes = TripRoutes()
    private var writeTail: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var routeTasks: [String: Task<Void, Never>] = [:]
    private var routeAttempts: [String: Date] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var trackingTripID: UUID?
    private var trackingSessionID: UUID?
    private var foreground = true
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var remindersRunning = false
    private var trackingSyncTask: Task<Void, Never>?
    private var refreshRunning = false
    private var refreshAgain = false
    private var canWrite = false
    private var arrivalHaptics: Task<Void, Never>?

    var selectedTrip: Trip? { library.trips.first { $0.id == library.selectedTripID } }
    var activeTrip: Trip? { library.trips.first { $0.status == .active } }
    var liveOrigin: Point? {
        guard let position = location.position, position.isFresh(at: Date()) else { return nil }
        return Point(name: "Starting location", latitude: position.coordinate.latitude, longitude: position.coordinate.longitude)
    }

    init(fileURL: URL? = nil) {
        var directory = fileURL?.deletingLastPathComponent()
        #if DEBUG
        if directory == nil, let id = ProcessInfo.processInfo.environment["COMPASS_UI_TEST_DATA"], UUID(uuidString: id) != nil {
            directory = URL.applicationSupportDirectory.appending(path: "CompassDay/tests/\(id)")
        }
        #endif
        reminderService = TripReminderService(receiptURL: directory?.appendingPathComponent("reminder-receipts.json"))
        repository = TripRepository(directory: directory, legacyFileURL: fileURL)
        location.onLocations = { [weak self] locations in self?.receive(locations) }
        reminderService.$authorization.dropFirst().sink { [weak self] _ in
            Task { @MainActor in await self?.reconcileReminders() }
        }.store(in: &subscriptions)
        Task {
            do {
                library = try await repository.load()
                canWrite = true
                if library.plans.isEmpty && library.trips.isEmpty {
                    _ = await transact { $0.plans.append(Plan(name: "My adventure")) }
                }
                isLoading = false
                await syncTracking()
                refresh()
                startHeartbeat()
            } catch {
                storageError = "Your saved trips could not be opened. The original files have been kept. \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    /// Queue edits against the most recently committed revision, never an earlier screen snapshot.
    @discardableResult
    func transact(_ edit: @escaping (inout TripLibrary) -> Void) async -> Bool {
        let previous = writeTail
        let task = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            guard let self, self.canWrite else { return false }
            var next = self.library
            edit(&next)
            guard next != self.library else { return true }
            next.revision = self.library.revision + 1
            // Location callbacks may arrive long after the scene's background transition.
            // Give each durable commit a bounded opportunity to finish while locked.
            let backgroundID: UIBackgroundTaskIdentifier = self.foreground ? .invalid :
                UIApplication.shared.beginBackgroundTask(withName: "Commit trip progress", expirationHandler: nil)
            defer {
                if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
            }
            do {
                try await self.repository.save(next)
                let newArrival = next.trips.contains { trip in
                    guard let previous = self.library.trips.first(where: { $0.id == trip.id }) else { return false }
                    return trip.visits.contains { id, visit in
                        visit.arrivedAt != nil && previous.visits[id]?.arrivedAt == nil
                    }
                }
                self.library = next
                if newArrival && self.foreground { self.pulseArrival() }
                return true
            } catch {
                self.storageError = "This change could not be saved. Your last saved trip is intact. \(error.localizedDescription)"
                return false
            }
        }
        writeTail = Task { _ = await task.value }
        return await task.value
    }

    func changeTrip(_ id: UUID, completion: ((Bool) -> Void)? = nil, _ edit: @escaping (inout Trip) -> Void) {
        Task {
            let saved = await transact { library in
                guard let index = library.trips.firstIndex(where: { $0.id == id }) else { return }
                let before = library.trips[index]
                edit(&library.trips[index])
                if before != library.trips[index], before.revision == library.trips[index].revision { library.trips[index].revision += 1 }
            }
            completion?(saved)
            await syncTracking()
            refresh()
        }
    }

    func changePlan(_ id: UUID, completion: ((Bool) -> Void)? = nil, _ edit: @escaping (inout Plan) -> Void) {
        Task {
            let saved = await transact { library in
                guard let index = library.plans.firstIndex(where: { $0.id == id }) else { return }
                edit(&library.plans[index])
                library.plans[index].reconcileLegs()
            }
            completion?(saved)
            refresh()
        }
    }

    func addPlan(name: String) {
        Task { _ = await transact { $0.plans.append(Plan(name: name)) }; refresh() }
    }
    func deletePlans(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        Task {
            _ = await transact { library in
                library.plans.removeAll { ids.contains($0.id) }
            }
            refresh()
        }
    }
    func selectTrip(_ id: UUID) {
        Task { _ = await transact { $0.selectedTripID = id }; refresh() }
    }
    func saveTrip(_ trip: Trip, completion: @escaping () -> Void) {
        Task {
            let saved = await transact { library in
                library.trips.append(trip)
                library.selectedTripID = trip.id
            }
            if saved { refresh(); completion() }
        }
    }
    func saveTemplate(from trip: Trip, updateOriginal: Bool) {
        Task {
            _ = await transact { library in
                guard let current = library.trips.first(where: { $0.id == trip.id }) else { return }
                let template = current.reusablePlan(id: updateOriginal ? current.sourcePlanID ?? UUID() : UUID())
                if let index = library.plans.firstIndex(where: { $0.id == template.id }) { library.plans[index] = template }
                else { library.plans.append(template) }
            }
            refresh()
        }
    }

    func startTrip(_ id: UUID, completion: @escaping () -> Void) {
        Task {
            guard activeTrip == nil || activeTrip?.id == id else {
                storageError = "Finish or cancel the current trip before starting another."
                return
            }
            let origin = liveOrigin
            var startError: String?
            let saved = await transact { library in
                guard let index = library.trips.firstIndex(where: { $0.id == id }),
                      !library.trips.contains(where: { $0.status == .active && $0.id != id }) else { return }
                if library.trips[index].status == .scheduled {
                    let trip = library.trips[index]
                    guard !trip.includedPlaces.isEmpty else {
                        startError = "Include at least one place before starting this trip."
                        return
                    }
                    let missing = trip.includedPlaces.flatMap(\.requirements).filter { trip.bindings[$0.id] == nil }
                    guard missing.isEmpty else {
                        startError = "Set a time for each included appointment and deadline before starting this trip."
                        return
                    }
                    TripEngine.start(&library.trips[index], origin: origin, at: Date())
                }
                library.selectedTripID = id
            }
            if let startError { storageError = startError; return }
            guard saved, selectedTrip?.status == .active else { return }
            await syncTracking()
            refresh()
            completion()
        }
    }

    func next(tripID: UUID, phase: TripPhase) {
        let sample = liveSample
        changeTrip(tripID) { TripEngine.next(&$0, expected: phase, at: Date(), sample: sample) }
    }
    func confirm(tripID: UUID, phase: TripPhase) {
        changeTrip(tripID) { TripEngine.confirm(&$0, expected: phase, at: Date()) }
    }
    func cancelTrip(_ id: UUID) { changeTrip(id) { TripEngine.cancel(&$0, at: Date()) } }
    func restoreAdjustments(_ id: UUID) {
        changeTrip(id) { trip in
            trip.skippedPlaceIDs = []
            for place in trip.plan.places where trip.visits[place.id]?.completed != true {
                trip.allocations[place.id] = max(place.duration.maximum, Int(ceil(trip.visits[place.id]?.budgetElapsed(at: Date()) ?? 0)))
            }
        }
    }

    var liveSample: LiveSample? {
        guard let position = location.position, let session = trackingSessionID else { return nil }
        return LiveSample(location: position, sessionID: session, trueHeading: location.heading,
                          headingAccuracy: location.headingAccuracy, headingTimestamp: location.headingTimestamp)
    }

    func sceneChanged(_ phase: ScenePhase) {
        foreground = phase == .active
        location.setForeground(foreground)
        if foreground {
            endBackgroundTask()
            Task { await syncTracking(); refresh(); await reminderService.refreshAuthorization() }
        } else {
            arrivalHaptics?.cancel()
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save trip progress") { [weak self] in
                    Task { @MainActor in self?.endBackgroundTask() }
                }
            }
            Task { await writeTail?.value; endBackgroundTask() }
        }
    }
    private func pulseArrival() {
        arrivalHaptics?.cancel()
        arrivalHaptics = Task { @MainActor in
            let generator = UINotificationFeedbackGenerator()
            for pulse in 0..<3 {
                if pulse > 0 {
                    do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                generator.notificationOccurred(.success)
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func syncTracking() async {
        // Every caller queues a reconciliation; a cancellation during an earlier disk write
        // must still stop the session after that write finishes.
        let previous = trackingSyncTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performTrackingSync()
        }
        let queued = Task { _ = await task.value }
        trackingSyncTask = queued
        await queued.value
    }

    private func performTrackingSync() async {
        guard let trip = activeTrip else {
            if trackingTripID != nil { location.stop() }
            trackingTripID = nil; trackingSessionID = nil
            return
        }
        if trackingTripID != trip.id {
            // When In Use background sessions must originate while the app is foregrounded.
            guard foreground else { return }
            let id = trip.id
            let saved = await transact { library in
                guard let index = library.trips.firstIndex(where: { $0.id == id }),
                      library.trips[index].status == .active else { return }
                TripEngine.beginTracking(&library.trips[index], at: Date())
            }
            guard saved, let current = activeTrip, current.id == id,
                  let session = current.trackingSessionID else { return }
            trackingTripID = id
            trackingSessionID = session
            location.start(backgroundTracking: true)
        }
        if let current = activeTrip, let target = current.activePlaceID {
            let predecessor = current.includedPlaces.prefix { $0.id != target }.last?.id
            location.updateMode(TripScheduler.effectiveMode(trip: current, from: predecessor, to: target))
        }
    }

    private func receive(_ positions: [CLLocation]) {
        guard let id = trackingTripID, let session = trackingSessionID else { return }
        let samples = positions.map { LiveSample(location: $0, sessionID: session) }
        let receivedAt = Date()
        Task {
            var newArrivals: [(UUID, Date)] = []
            let saved = await transact { library in
                guard let index = library.trips.firstIndex(where: { $0.id == id }),
                      library.trips[index].status == .active,
                      library.trips[index].trackingSessionID == session else { return }
                let before = library.trips[index]
                if before.origin == nil, let sessionStart = before.trackingStartedAt,
                   let first = samples.sorted(by: { $0.timestamp < $1.timestamp }).first(where: {
                       $0.timestamp >= sessionStart && $0.isFresh(at: receivedAt)
                   }) {
                    library.trips[index].origin = first.point
                    library.trips[index].revision += 1
                }
                TripEngine.receive(&library.trips[index], samples: samples, sessionID: session, receivedAt: receivedAt)
                if library.trips[index].arrivalNotificationsEnabled {
                    newArrivals = library.trips[index].visits.compactMap { placeID, visit in
                        guard before.visits[placeID] == nil, let arrival = visit.arrivedAt else { return nil }
                        return (placeID, arrival)
                    }
                }
            }
            if saved && !foreground {
                for (placeID, date) in newArrivals {
                    if let error = await reminderService.notifyArrival(tripID: id, placeID: placeID, arrivedAt: date) { storageError = error }
                }
            }
            await syncTracking()
            refresh()
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                if self.foreground {
                    if let id = self.activeTrip?.id {
                        _ = await self.transact { library in
                            guard let index = library.trips.firstIndex(where: { $0.id == id }) else { return }
                            TripEngine.tick(&library.trips[index], at: Date())
                        }
                    }
                    self.refresh()
                }
            }
        }
    }

    func refresh() {
        guard !isLoading else { return }
        if refreshRunning { refreshAgain = true; return }
        refreshRunning = true
        Task {
            defer { refreshRunning = false }
            repeat {
                refreshAgain = false
                let origin = liveOrigin
                let ids = library.trips.map(\.id)
                for id in ids {
                    guard let trip = library.trips.first(where: { $0.id == id }) else { continue }
                    var projection = TripScheduler.project(trip: trip, liveOrigin: origin)
                    if (trip.status == .scheduled || trip.status == .active) &&
                        (projection.allocations != trip.allocations || projection.skippedPlaceIDs != trip.skippedPlaceIDs) {
                        let proposed = projection
                        let saved = await transact { library in
                            guard let index = library.trips.firstIndex(where: { $0.id == id }) else { return }
                            TripScheduler.apply(proposed, to: &library.trips[index])
                        }
                        guard saved, let committed = library.trips.first(where: { $0.id == id }) else { continue }
                        projection = TripScheduler.project(trip: committed, liveOrigin: liveOrigin, adapt: false)
                        refreshAgain = true
                    }
                    // A forecast and its reminders must describe committed allocations and stops.
                    guard let current = library.trips.first(where: { $0.id == id }), current.revision == projection.revision else {
                        refreshAgain = true
                        continue
                    }
                    schedules.set(projection)
                    if current.status == .scheduled || current.status == .active {
                        for request in projection.missingRoutes { requestRoute(request) }
                    }
                }
                for plan in library.plans { refreshPlanRoutes(plan) }
                await reconcileReminders()
            } while refreshAgain && !Task.isCancelled
        }
    }

    private func requestRoute(_ request: RouteRequestContext) {
        let key = request.kind == .liveApproach ?
            "approach:\(request.tripID):\(request.revision):\(request.toPlaceID):\(request.mode.rawValue)" : request.cacheKey
        let interval: TimeInterval = request.kind == .liveApproach ? 20 : 60
        guard routeTasks[key] == nil, Date().timeIntervalSince(routeAttempts[key] ?? .distantPast) > interval else { return }
        routeAttempts[key] = Date()
        routeTasks[key] = Task {
            defer { routeTasks[key] = nil }
            do {
                let result: LegEstimate
                #if DEBUG
                if let raw = ProcessInfo.processInfo.environment["COMPASS_UI_TEST_ETA_SECONDS"], let seconds = Double(raw) {
                    result = LegEstimate(duration: .init(minimum: Int(seconds), maximum: Int(seconds * 1.2)), source: request.source,
                                         destination: request.destination, mode: request.mode, departureAt: request.departureAt, fetchedAt: Date(), requestID: request.id)
                } else { result = try await routes.fetch(request) }
                #else
                result = try await routes.fetch(request)
                #endif
                let origin = liveOrigin
                _ = await transact { library in
                    guard let index = library.trips.firstIndex(where: { $0.id == request.tripID }),
                          request.id == result.requestID,
                          request.isValid(for: library.trips[index], liveOrigin: origin) else { return }
                    if request.kind == .liveApproach { library.trips[index].approachEstimate = result }
                    else if request.kind == .fullLeg,
                            let leg = library.trips[index].plan.legs.firstIndex(where: { $0.fromPlaceID == request.fromPlaceID && $0.toPlaceID == request.toPlaceID }) {
                        library.trips[index].plan.legs[leg].estimate = result
                    }
                    else if request.kind == .bypass {
                        library.trips[index].routeEstimates.removeAll {
                            $0.matches(source: result.source, destination: result.destination, mode: result.mode)
                        }
                        library.trips[index].routeEstimates.append(result)
                    }
                    // Forecast data does not change the configuration revision.
                }
                refresh()
            } catch { /* An unavailable route stays visibly unknown; manual estimates remain available. */ }
        }
    }

    private func refreshPlanRoutes(_ plan: Plan) {
        for (from, to) in zip(plan.places, plan.places.dropFirst()) {
            guard let leg = plan.leg(from: from.id, to: to.id), leg.manualDuration == nil,
                  leg.estimate?.isCurrent(at: Date()) != true else { continue }
            let context = RouteRequestContext(tripID: plan.id, revision: library.revision, fromPlaceID: from.id, toPlaceID: to.id,
                                              source: from.exit.center, destination: to.entry.center, mode: leg.mode, departureAt: Date(), kind: .fullLeg)
            let key = context.cacheKey
            guard routeTasks[key] == nil, Date().timeIntervalSince(routeAttempts[key] ?? .distantPast) > 60 else { continue }
            routeAttempts[key] = Date()
            routeTasks[key] = Task {
                defer { routeTasks[key] = nil }
                do {
                    let estimate = try await routes.fetch(context)
                    _ = await transact { library in
                        guard let p = library.plans.firstIndex(where: { $0.id == plan.id }),
                              let l = library.plans[p].legs.firstIndex(where: { $0.id == leg.id }),
                              let source = library.plans[p].place(from.id)?.exit.center,
                              let destination = library.plans[p].place(to.id)?.entry.center,
                              estimate.matches(source: source, destination: destination, mode: library.plans[p].legs[l].mode) else { return }
                        library.plans[p].legs[l].estimate = estimate
                    }
                } catch { }
            }
        }
    }

    func retryRoutes() { routeAttempts = [:]; refresh() }

    func reconcileReminders() async {
        guard !remindersRunning, !isLoading else { return }
        remindersRunning = true
        defer { remindersRunning = false }
        for trip in library.trips where !trip.reminders.isEmpty {
            let projection = TripScheduler.project(trip: trip, liveOrigin: liveOrigin, adapt: false)
            let result = await reminderService.reconcile(reminders: trip.reminders, context: reminderContext(trip, projection))
            guard result != trip.reminders else { continue }
            _ = await transact { library in
                guard let index = library.trips.firstIndex(where: { $0.id == trip.id }) else { return }
                for reminder in result {
                    guard let r = library.trips[index].reminders.firstIndex(where: { $0.id == reminder.id }),
                          library.trips[index].reminders[r].desiredRevision == reminder.desiredRevision else { continue }
                    library.trips[index].reminders[r] = reminder
                }
            }
        }
    }

    private func reminderContext(_ trip: Trip, _ projection: TripScheduleProjection) -> ReminderScheduleContext {
        var dates: [ReminderEvent: Date] = [:]
        let valid = TripReminderEligibility.events(for: trip)
        if valid.contains(.tripDeparture) {
            dates[.tripDeparture] = trip.scheduledStart
        }
        for place in trip.includedPlaces {
            let departure = ReminderEvent.placeDeparture(place.id)
            if valid.contains(departure) { dates[departure] = projection.place(place.id)?.exit?.upperBound }
            for requirement in place.requirements {
                let event = ReminderEvent.requirement(requirement.id)
                guard valid.contains(event) else { continue }
                dates[event] = trip.bindings[requirement.id]
            }
        }
        return ReminderScheduleContext(tripID: trip.id, lifecycleAllowsReminders: trip.status == .scheduled || trip.status == .active,
                                       eventDates: dates, validEvents: valid)
    }
}
