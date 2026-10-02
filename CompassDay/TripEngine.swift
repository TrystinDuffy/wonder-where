import Foundation

/// Pure transitions. Persist the returned value before publishing it to the UI.
/// Live sensor presentation stays outside this durable model.
enum TripEngine {
    @discardableResult
    static func start(_ trip: inout Trip, origin: Point?, at date: Date) -> Bool {
        guard trip.status == .scheduled else { return false }
        return change(&trip) { trip in
            trip.plan.reconcileLegs()
            // A preview origin is not an observed starting point. If GPS is unavailable at
            // Start, leave it unknown until the first eligible fix from this tracking session.
            trip.origin = origin?.isValid == true ? origin : nil
            trip.startedAt = date
            trip.status = .active
            trip.trackingSessionID = UUID()
            trip.trackingStartedAt = date
            trip.lastObservedAt = nil
            if let first = trip.remainingPlaces.first {
                trip.phase = TripPhase(placeID: first.id, kind: .approaching, effectiveAt: date)
            } else {
                finish(&trip, at: date)
            }
        }
    }

    /// A new session prevents cached observations and old heading readings satisfying current guidance.
    @discardableResult
    static func beginTracking(_ trip: inout Trip, at date: Date) -> UUID {
        let id = UUID()
        guard trip.status == .active else { return id }
        _ = change(&trip) { trip in
            trip.trackingSessionID = id
            trip.trackingStartedAt = date
            trip.lastObservedAt = nil
        }
        return id
    }

    @discardableResult
    static func next(_ trip: inout Trip, expected: TripPhase, at date: Date, sample: LiveSample? = nil) -> Bool {
        guard accepts(trip, expected: expected), expected.kind == .exploring, trip.activeVisit != nil else { return false }
        return change(&trip) { trip in
            freezeBudget(&trip, at: date)
            var visit = trip.visits[expected.placeID]!
            if visit.departureRequestedAt == nil { visit.departureRequestedAt = date }
            trip.visits[expected.placeID] = visit
            trip.phase = TripPhase(placeID: expected.placeID, kind: .exiting, effectiveAt: date)
            // This command may use the latest current fix to confirm we are already at Exit.
            // Older batched observations are never allowed to confirm a later departure request.
            if let sample, sample.sessionID == trip.trackingSessionID,
               sample.timestamp >= max(trip.trackingStartedAt ?? expected.effectiveAt, expected.effectiveAt),
               sample.isFresh(at: date), let exit = trip.activePlace?.exit, exit.canConfirm(sample) {
                depart(&trip, at: date, manual: false)
            }
        }
    }

    @discardableResult
    static func confirm(_ trip: inout Trip, expected: TripPhase, at date: Date) -> Bool {
        guard accepts(trip, expected: expected), expected.kind != .exploring else { return false }
        return change(&trip) { trip in
            if expected.kind == .approaching { arrive(&trip, at: date, manual: true) }
            else { depart(&trip, at: date, manual: true) }
        }
    }

    /// Retain each eligible observation in delivery order. A sparse segment is never an arrival.
    @discardableResult
    static func receive(_ trip: inout Trip, samples: [LiveSample], sessionID: UUID, receivedAt: Date) -> Bool {
        guard trip.status == .active, trip.trackingSessionID == sessionID, let sessionStart = trip.trackingStartedAt else { return false }
        // lastObservedAt is only persisted when a durable transition happens. Duplicate samples
        // are also harmless because a new phase and its effective time guard every transition.
        var observationCursor = trip.lastObservedAt
        return change(&trip) { trip in
            for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
                guard trip.status == .active, sample.sessionID == sessionID, sample.hasValidLocation,
                      sample.timestamp >= sessionStart, sample.timestamp <= receivedAt.addingTimeInterval(5),
                      observationCursor.map({ sample.timestamp > $0 }) ?? true else { continue }
                observationCursor = sample.timestamp
                guard let phase = trip.phase, sample.timestamp >= phase.effectiveAt else { continue }
                if phase.kind == .approaching, trip.activePlace?.entry.canConfirm(sample) == true {
                    arrive(&trip, at: sample.timestamp, manual: false)
                    trip.lastObservedAt = sample.timestamp
                } else if phase.kind == .exiting, trip.activePlace?.exit.canConfirm(sample) == true {
                    depart(&trip, at: sample.timestamp, manual: false)
                    trip.lastObservedAt = sample.timestamp
                }
            }
            freezeBudget(&trip, at: receivedAt)
        }
    }

    @discardableResult
    static func tick(_ trip: inout Trip, at date: Date) -> Bool {
        guard trip.status == .active else { return false }
        return change(&trip) { freezeBudget(&$0, at: date) }
    }

    @discardableResult
    static func upsert(_ trip: inout Trip, place: Place, at date: Date) -> Bool {
        guard place.isValid, trip.status == .active || trip.status == .scheduled else { return false }
        return change(&trip) { trip in
            freezeBudget(&trip, at: date)
            let previousActivePlace = trip.activePlace
            if let index = trip.plan.places.firstIndex(where: { $0.id == place.id }) {
                let old = trip.plan.places[index]
                trip.plan.places[index] = place
                if old.duration != place.duration {
                    trip.allocations[place.id] = min(place.duration.maximum, max(place.duration.minimum, trip.allocation(for: place.id)))
                }
            } else {
                trip.plan.places.append(place)
                trip.allocations[place.id] = place.duration.maximum
            }
            trip.removedPlaceIDs.remove(place.id)
            trip.plan.reconcileLegs()
            if let phase = trip.phase, phase.placeID == place.id {
                if let previousActivePlace,
                   geometryChanged(previousActivePlace.entry, place.entry) ||
                    geometryChanged(previousActivePlace.explore, place.explore) ||
                    geometryChanged(previousActivePlace.exit, place.exit) {
                    trip.phase = TripPhase(placeID: place.id, kind: phase.kind, effectiveAt: date)
                    trip.approachEstimate = nil
                }
                refreshFutureBudget(&trip, placeID: place.id, at: date)
            }
            let requirementIDs = Set(trip.plan.requirements.map(\.id))
            trip.bindings = trip.bindings.filter { requirementIDs.contains($0.key) }
        }
    }

    @discardableResult
    static func delete(_ trip: inout Trip, placeID: UUID, at date: Date) -> Bool {
        guard (trip.status == .active || trip.status == .scheduled), let place = trip.plan.place(placeID) else { return false }
        return change(&trip) { trip in
            freezeBudget(&trip, at: date)
            if trip.status == .active {
                var visit = trip.visits[placeID] ?? VisitRecord(place: place)
                visit.removedAt = visit.removedAt ?? date
                trip.visits[placeID] = visit
                trip.removedPlaceIDs.insert(placeID)
            }
            trip.plan.places.removeAll { $0.id == placeID }
            trip.plan.reconcileLegs()
            if trip.activePlaceID == placeID { selectNext(&trip, at: date) }
        }
    }

    @discardableResult
    static func reorder(_ trip: inout Trip, ids: [UUID], at date: Date) -> Bool {
        guard trip.status == .scheduled || trip.status == .active else { return false }
        return change(&trip) { trip in
            let protected: [Place]
            if trip.status == .active {
                protected = trip.plan.places.filter { trip.visits[$0.id]?.completed == true || $0.id == trip.activePlaceID }
            } else { protected = [] }
            let protectedIDs = Set(protected.map(\.id))
            var seen = protectedIDs
            var future: [Place] = []
            for id in ids where seen.insert(id).inserted {
                if let place = trip.plan.place(id) { future.append(place) }
            }
            future += trip.plan.places.filter { !seen.contains($0.id) }
            trip.plan.places = protected + future
            trip.plan.reconcileLegs()
        }
    }

    @discardableResult
    static func editBinding(_ trip: inout Trip, requirementID: UUID, date: Date?, at now: Date) -> Bool {
        guard trip.status == .scheduled || trip.status == .active,
              let place = trip.plan.places.first(where: { $0.requirements.contains(where: { $0.id == requirementID }) }) else { return false }
        return change(&trip) { trip in
            freezeBudget(&trip, at: now)
            trip.bindings[requirementID] = date
            refreshFutureBudget(&trip, placeID: place.id, at: now)
        }
    }

    @discardableResult
    static func restore(_ trip: inout Trip, placeID: UUID) -> Bool {
        guard trip.plan.place(placeID) != nil, trip.status == .scheduled || trip.status == .active else { return false }
        return change(&trip) { trip in
            trip.skippedPlaceIDs.remove(placeID)
            if let place = trip.plan.place(placeID) { trip.allocations[placeID] = place.duration.maximum }
        }
    }

    @discardableResult
    static func cancel(_ trip: inout Trip, at date: Date) -> Bool {
        guard trip.status == .scheduled || trip.status == .active else { return false }
        return change(&trip) { trip in
            freezeBudget(&trip, at: date)
            trip.status = .canceled
            trip.phase = nil
            trip.trackingSessionID = nil
            trip.trackingStartedAt = nil
        }
    }

    private static func accepts(_ trip: Trip, expected: TripPhase) -> Bool {
        trip.status == .active && trip.phase == expected && trip.plan.place(expected.placeID) != nil
    }

    private static func arrive(_ trip: inout Trip, at date: Date, manual: Bool) {
        guard let place = trip.activePlace, let phase = trip.phase, phase.kind == .approaching else { return }
        if trip.visits[place.id] == nil {
            let anchor = max(date, trip.appointment(for: place.id) ?? date)
            trip.visits[place.id] = VisitRecord(place: place, arrivedAt: date, budgetAnchor: anchor,
                                              budgetAnchorFrozen: anchor <= date, arrivalManual: manual)
        }
        trip.phase = TripPhase(placeID: place.id, kind: .exploring, effectiveAt: date)
        trip.approachEstimate = nil
    }

    private static func depart(_ trip: inout Trip, at date: Date, manual: Bool) {
        guard let id = trip.activePlaceID, trip.phase?.kind == .exiting, var visit = trip.visits[id] else { return }
        if !visit.completed {
            visit.exitedAt = date
            visit.completed = true
            visit.exitManual = manual
            // Departing before the appointment is an explicit early departure, not a future visit.
            if let anchor = visit.budgetAnchor, anchor > date {
                visit.budgetAnchor = nil
                visit.budgetAnchorFrozen = false
            } else if visit.budgetAnchor != nil { visit.budgetAnchorFrozen = true }
            trip.visits[id] = visit
        }
        selectNext(&trip, at: date)
    }

    private static func selectNext(_ trip: inout Trip, at date: Date) {
        trip.approachEstimate = nil
        if let next = trip.remainingPlaces.first {
            trip.phase = TripPhase(placeID: next.id, kind: .approaching, effectiveAt: date)
        } else { finish(&trip, at: date) }
    }

    private static func finish(_ trip: inout Trip, at date: Date) {
        trip.status = .completed
        trip.completedAt = trip.completedAt ?? date
        trip.phase = nil
        trip.trackingSessionID = nil
        trip.trackingStartedAt = nil
    }

    private static func freezeBudget(_ trip: inout Trip, at date: Date) {
        guard let id = trip.activePlaceID, var visit = trip.visits[id], !visit.completed,
              !visit.budgetAnchorFrozen, let anchor = visit.budgetAnchor, anchor <= date else { return }
        visit.budgetAnchorFrozen = true
        trip.visits[id] = visit
    }

    private static func refreshFutureBudget(_ trip: inout Trip, placeID: UUID, at date: Date) {
        guard var visit = trip.visits[placeID], !visit.completed, !visit.budgetAnchorFrozen, let arrival = visit.arrivedAt else { return }
        visit.budgetAnchor = max(arrival, trip.appointment(for: placeID) ?? arrival)
        if let anchor = visit.budgetAnchor, anchor <= date { visit.budgetAnchorFrozen = true }
        trip.visits[placeID] = visit
    }

    private static func geometryChanged(_ lhs: Area?, _ rhs: Area?) -> Bool {
        guard let lhs, let rhs else { return lhs != rhs }
        return lhs.id != rhs.id || !lhs.center.sameCoordinates(as: rhs.center) || lhs.radiusMeters != rhs.radiusMeters
    }

    private static func change(_ trip: inout Trip, _ operation: (inout Trip) -> Void) -> Bool {
        let previous = trip
        operation(&trip)
        guard previous != trip else { return false }
        trip.revision = previous.revision + 1
        return true
    }
}
