import Foundation

enum ScheduleEstimateSource: String, Equatable {
    case manual, current, cached, unavailable
}

struct ScheduledPlace: Identifiable, Equatable {
    var id: UUID { placeID }
    let placeID: UUID
    let arrival: ClosedRange<Date>?
    let budgetStart: ClosedRange<Date>?
    let exit: ClosedRange<Date>?
    let allocation: Int
    let incomingSource: ScheduleEstimateSource
    var incomingTravel: DurationRange? = nil
    var waiting: DurationRange? = nil
    var remainingVisitSeconds: Int? = nil
    var reducibleVisitSeconds: Int? = nil
}

struct ScheduleConflict: Identifiable, Equatable {
    var id: UUID { requirementID }
    let requirementID: UUID
    let placeID: UUID
    let kind: TimeRequirement.Kind
    let deadline: Date
    let predicted: Date
    /// `predicted` is an earliest possible time, not a complete travel forecast, when true.
    var isLowerBoundOnly = false
    var lateness: TimeInterval { max(0, predicted.timeIntervalSince(deadline)) }
}

struct TripScheduleProjection: Equatable {
    let tripID: UUID
    let revision: Int
    let status: TripStatus
    var startBy: Date?
    var completion: ClosedRange<Date>?
    var places: [ScheduledPlace]
    var conflicts: [ScheduleConflict]
    var missingRoutes: [RouteRequestContext]
    var allocations: [UUID: Int]
    var skippedPlaceIDs: Set<UUID>
    var unresolvedRequirementIDs: Set<UUID>
    var isAdjusted: Bool
    var hasCachedEstimates: Bool
    var hasTimeConflicts: Bool { !conflicts.isEmpty }
    var isRunningBehind: Bool { status == .active && hasTimeConflicts }
    /// Propagated lateness can affect several deadlines; adding it would count the same delay again.
    var maximumLateness: TimeInterval { conflicts.map(\.lateness).max() ?? 0 }
    var maximumLatenessRange: ClosedRange<TimeInterval> {
        let ranges = conflicts.map { latenessRange(for: $0) }
        return (ranges.map(\.lowerBound).max() ?? 0)...(ranges.map(\.upperBound).max() ?? 0)
    }
    var hasUnknownEstimates: Bool { !unresolvedRequirementIDs.isEmpty || places.contains { $0.exit == nil } }
    func place(_ id: UUID) -> ScheduledPlace? { places.first { $0.placeID == id } }

    func latenessRange(for conflict: ScheduleConflict) -> ClosedRange<TimeInterval> {
        // Callers must label this quantity "at least" rather than presenting a finite upper bound.
        if conflict.isLowerBoundOnly { return conflict.lateness...conflict.lateness }
        let scheduledPlace = place(conflict.placeID)
        let milestone = conflict.kind == .leaveBy ? scheduledPlace?.exit : scheduledPlace?.arrival
        guard let milestone else { return conflict.lateness...conflict.lateness }
        let lower = max(0, milestone.lowerBound.timeIntervalSince(conflict.deadline))
        let upper = max(0, milestone.upperBound.timeIntervalSince(conflict.deadline))
        return lower...upper
    }
}

/// Pure schedule calculation. Neither location readings nor projected time become visit history.
enum TripScheduler {
    static func project(trip: Trip, liveOrigin: Point? = nil, now: Date = Date(),
                        routes: [LegEstimate] = [], adapt: Bool = true) -> TripScheduleProjection {
        let routes = routes + trip.routeEstimates
        var work = trip
        for place in work.plan.places {
            work.allocations[place.id] = min(place.duration.maximum,
                                            max(0, work.allocations[place.id] ?? place.duration.maximum))
        }
        var result = forward(trip: work, liveOrigin: liveOrigin, now: now, routes: routes)
        var requestedBypasses: [RouteRequestContext] = []
        if adapt && (work.status == .scheduled || work.status == .active) {
            // Every accepted operation strictly reduces a finite allocation or removes one place.
            var attempts = max(1, work.plan.requirements.count * (work.plan.places.count * 3 + 1))
            var infeasibleRequirements = Set<UUID>()
            while let threat = result.conflicts.first(where: { !infeasibleRequirements.contains($0.requirementID) }), attempts > 0 {
                attempts -= 1
                let included = remainingPlaces(work)
                guard let threatenedIndex = included.firstIndex(where: { $0.id == threat.placeID }) else { break }
                let permitted = included.enumerated().filter {
                    $0.offset < threatenedIndex || ($0.offset == threatenedIndex && threat.kind == .leaveBy)
                }.map(\.element)
                var slack: [UUID: Int] = [:]
                for place in permitted {
                    let available = reducibleSeconds(place: place, trip: work, now: now)
                    guard available > 0 else { continue }
                    var probe = work
                    probe.allocations[place.id] = probe.allocation(for: place.id) - available
                    let probeResult = forward(trip: probe, liveOrigin: liveOrigin, now: now, routes: routes)
                    if lateness(threat.requirementID, in: probeResult) < threat.lateness - 0.001 {
                        slack[place.id] = available
                    }
                }
                if !slack.isEmpty {
                    // Find the smallest proportional reduction that satisfies the threatened anchor.
                    var lower = 0.0, upper = 1.0
                    for _ in 0..<24 {
                        let fraction = (lower + upper) / 2
                        let trial = reduced(work, slack: slack, fraction: fraction)
                        let trialResult = forward(trip: trial, liveOrigin: liveOrigin, now: now, routes: routes)
                        if lateness(threat.requirementID, in: trialResult) <= 0 { upper = fraction }
                        else { lower = fraction }
                    }
                    let reducedTrip = reduced(work, slack: slack, fraction: upper)
                    let reducedResult = forward(trip: reducedTrip, liveOrigin: liveOrigin, now: now, routes: routes)
                    if lateness(threat.requirementID, in: reducedResult) < threat.lateness - 0.001 {
                        work = reducedTrip
                        result = reducedResult
                        continue
                    }
                }
                let candidates = included.enumerated().filter {
                    $0.offset <= threatenedIndex && $0.element.isOptional &&
                    $0.element.id != (work.status == .active ? work.activePlaceID : nil) &&
                    work.visits[$0.element.id] == nil
                }.sorted {
                    $0.element.keepPriority == $1.element.keepPriority ?
                    $0.offset < $1.offset : $0.element.keepPriority < $1.element.keepPriority
                }.map(\.element)
                var accepted = false
                for candidate in candidates {
                    guard canBridgeSkipping(candidate.id, trip: work) else { continue }
                    var trial = work
                    trial.skippedPlaceIDs.insert(candidate.id)
                    let trialResult = forward(trip: trial, liveOrigin: liveOrigin, now: now, routes: routes)
                    requestedBypasses.append(contentsOf: trialResult.missingRoutes.filter { $0.kind == .bypass })
                    // Unknown travel cannot prove a skip helps. Removing its own timed stop is valid
                    // only when the remaining route has a usable projection as well.
                    guard !trialResult.hasUnknownEstimates,
                          lateness(threat.requirementID, in: trialResult) < threat.lateness - 0.001,
                          !introducesWorseConflict(before: result, after: trialResult) else { continue }
                    work = trial
                    result = trialResult
                    accepted = true
                    break
                }
                // One impossible deadline must not prevent recovering the rest of the day.
                if !accepted { infeasibleRequirements.insert(threat.requirementID) }
            }
        }
        result.allocations = work.allocations
        result.skippedPlaceIDs = work.skippedPlaceIDs
        result.isAdjusted = !work.skippedPlaceIDs.isEmpty || work.plan.places.contains {
            work.allocation(for: $0.id) < $0.duration.maximum
        }
        result.missingRoutes = uniqueRequests(result.missingRoutes + requestedBypasses)
        if work.status == .scheduled && result.unresolvedRequirementIDs.isEmpty {
            result.startBy = latestStart(trip: work, liveOrigin: liveOrigin, now: now, routes: routes)
        }
        return result
    }

    /// The caller persists this transaction. A result calculated for an old revision is discarded.
    @discardableResult
    static func apply(_ projection: TripScheduleProjection, to trip: inout Trip) -> Bool {
        guard projection.tripID == trip.id, projection.revision == trip.revision,
              trip.status == .scheduled || trip.status == .active else { return false }
        var changed = false
        for place in trip.plan.places {
            guard let proposed = projection.allocations[place.id], proposed < trip.allocation(for: place.id) else { continue }
            let lower = min(trip.allocation(for: place.id), place.duration.minimum)
            trip.allocations[place.id] = max(lower, proposed)
            changed = true
        }
        for id in projection.skippedPlaceIDs.subtracting(trip.skippedPlaceIDs) {
            guard id != (trip.status == .active ? trip.activePlaceID : nil), trip.visits[id] == nil,
                  trip.plan.places.contains(where: { $0.id == id && $0.isOptional }) else { continue }
            trip.skippedPlaceIDs.insert(id)
            changed = true
        }
        if changed { trip.revision += 1 }
        return changed
    }

    static func totalDuration(plan: Plan) -> DurationRange? {
        var minimum = plan.places.reduce(0) { $0 + $1.duration.minimum }
        var maximum = plan.places.reduce(0) { $0 + $1.duration.maximum }
        for (from, to) in zip(plan.places, plan.places.dropFirst()) {
            guard let leg = plan.leg(from: from.id, to: to.id),
                  let duration = leg.manualDuration ?? leg.estimate?.duration else { return nil }
            minimum += duration.minimum
            maximum += duration.maximum
        }
        return DurationRange(minimum: minimum, maximum: maximum)
    }

    private static func remainingPlaces(_ trip: Trip) -> [Place] {
        let places = trip.plan.places.filter {
            !trip.skippedPlaceIDs.contains($0.id) && !trip.removedPlaceIDs.contains($0.id) &&
            trip.visits[$0.id]?.completed != true
        }
        guard trip.status == .active, let active = trip.activePlaceID,
              let index = places.firstIndex(where: { $0.id == active }), index != 0 else { return places }
        return [places[index]] + places.enumerated().filter { $0.offset != index }.map(\.element)
    }

    private static func reduced(_ trip: Trip, slack: [UUID: Int], fraction: Double) -> Trip {
        var result = trip
        for (id, available) in slack {
            result.allocations[id] = trip.allocation(for: id) - min(available, Int(ceil(Double(available) * fraction)))
        }
        return result
    }

    private static func reducibleSeconds(place: Place, trip: Trip, now: Date) -> Int {
        var floor = place.duration.minimum
        if let visit = trip.visits[place.id], let anchor = visit.budgetAnchor {
            floor = max(floor, Int(ceil(max(0, now.timeIntervalSince(anchor)))))
        }
        return max(0, trip.allocation(for: place.id) - floor)
    }

    private static func lateness(_ requirementID: UUID, in projection: TripScheduleProjection) -> TimeInterval {
        projection.conflicts.first { $0.requirementID == requirementID }?.lateness ?? 0
    }

    private static func introducesWorseConflict(before: TripScheduleProjection, after: TripScheduleProjection) -> Bool {
        after.conflicts.contains { $0.lateness > lateness($0.requirementID, in: before) + 0.001 }
    }

    private static func forward(trip: Trip, liveOrigin: Point?, now: Date, routes: [LegEstimate]) -> TripScheduleProjection {
        var output = TripScheduleProjection(tripID: trip.id, revision: trip.revision, status: trip.status,
                                            places: [], conflicts: [],
                                            missingRoutes: [], allocations: trip.allocations,
                                            skippedPlaceIDs: trip.skippedPlaceIDs, unresolvedRequirementIDs: [], isAdjusted: false,
                                            hasCachedEstimates: false)
        if trip.status == .completed {
            output.completion = trip.completedAt.map { $0...$0 }
            return output
        }
        if trip.status == .canceled { return output }
        let places = remainingPlaces(trip)
        var cursor: ClosedRange<Date>? = (trip.status == .active ? now : trip.scheduledStart)...(trip.status == .active ? now : trip.scheduledStart)
        // This proof stays separate from the forecast. Missing travel is nonnegative, but is
        // never converted into a zero-duration route or a known arrival/completion estimate.
        var earliestCursor: Date? = trip.status == .active ? now : trip.scheduledStart
        for (index, place) in places.enumerated() {
            let visit = trip.visits[place.id]
            let allocation = trip.allocation(for: place.id)
            var arrival: ClosedRange<Date>?
            var earliestArrival: Date?
            var incomingTravel: DurationRange?
            var source = ScheduleEstimateSource.current
            if let visit {
                arrival = visit.arrivedAt.map { $0...$0 }
                earliestArrival = arrival?.lowerBound
                incomingTravel = .init(minimum: 0, maximum: 0)
            } else {
                let from = index == 0 ? nil : places[index - 1]
                let departure = cursor?.upperBound ?? now
                let travel = travelDuration(trip: trip, from: from, to: place, first: index == 0,
                                            liveOrigin: liveOrigin, departure: departure, now: now, routes: routes)
                source = travel.source
                incomingTravel = travel.duration
                if let request = travel.request { output.missingRoutes.append(request) }
                if source == .cached { output.hasCachedEstimates = true }
                if let cursor, let duration = travel.duration {
                    let lower = cursor.lowerBound.addingTimeInterval(Double(duration.minimum))
                    let upper = cursor.upperBound.addingTimeInterval(Double(duration.maximum))
                    arrival = lower...upper
                }
                earliestArrival = arrival?.lowerBound ?? earliestCursor?.addingTimeInterval(Double(travel.duration?.minimum ?? 0))
            }
            let appointment = place.requirements.filter { $0.kind == .appointment }.compactMap { trip.bindings[$0.id] }.max()
            let hasUnboundAppointment = place.requirements.contains { $0.kind == .appointment && trip.bindings[$0.id] == nil }
            var budget: ClosedRange<Date>?
            if let anchor = visit?.budgetAnchor { budget = anchor...anchor }
            else if let arrival {
                budget = max(arrival.lowerBound, appointment ?? .distantPast)...max(arrival.upperBound, appointment ?? .distantPast)
            }
            var exit: ClosedRange<Date>?
            if let budget {
                let earliest = budget.lowerBound.addingTimeInterval(Double(allocation))
                let latest = budget.upperBound.addingTimeInterval(Double(allocation))
                exit = (visit == nil ? earliest : max(now, earliest))...(visit == nil ? latest : max(now, latest))
            }
            var earliestExit = exit?.lowerBound
            if earliestExit == nil, visit == nil {
                // An appointment independently anchors a future visit even when an earlier
                // unknown leg prevents computing its arrival. Unknown visit history stays unknown.
                let earliestBudget: Date?
                if let earliestArrival { earliestBudget = max(earliestArrival, appointment ?? .distantPast) }
                else { earliestBudget = appointment }
                earliestExit = earliestBudget?.addingTimeInterval(Double(allocation))
            }
            for requirement in place.requirements {
                // Entry observations turn Entry deadlines into history, even when they were late.
                if requirement.kind != .leaveBy && visit != nil { continue }
                guard let deadline = trip.bindings[requirement.id] else {
                    output.unresolvedRequirementIDs.insert(requirement.id)
                    continue
                }
                let predicted = requirement.kind == .leaveBy ? exit?.upperBound : arrival?.upperBound
                if let predicted, predicted > deadline {
                    output.conflicts.append(ScheduleConflict(requirementID: requirement.id, placeID: place.id,
                                                             kind: requirement.kind, deadline: deadline, predicted: predicted))
                } else if predicted == nil,
                          let earliest = requirement.kind == .leaveBy ? earliestExit : earliestArrival,
                          earliest > deadline {
                    output.conflicts.append(ScheduleConflict(requirementID: requirement.id, placeID: place.id,
                                                             kind: requirement.kind, deadline: deadline, predicted: earliest,
                                                             isLowerBoundOnly: true))
                }
            }
            var waiting: DurationRange?
            var remainingVisitSeconds: Int?
            var reducibleVisitSeconds: Int?
            if let visit {
                // Unknown historical accounting stays unknown in the UI, even when the visit
                // itself is known to have been reached. Clock updates never alter its history.
                if let anchor = visit.budgetAnchor {
                    let wait = max(0, anchor.timeIntervalSince(now))
                    if !hasUnboundAppointment || visit.budgetAnchorFrozen {
                        waiting = secondsRange(lower: wait, upper: wait)
                    }
                    remainingVisitSeconds = Int(ceil(max(0, Double(allocation) - visit.budgetElapsed(at: now))))
                    reducibleVisitSeconds = reducibleSeconds(place: place, trip: trip, now: now)
                }
            } else {
                remainingVisitSeconds = allocation
                reducibleVisitSeconds = reducibleSeconds(place: place, trip: trip, now: now)
                if !place.requirements.contains(where: { $0.kind == .appointment }) {
                    waiting = .init(minimum: 0, maximum: 0)
                } else if !hasUnboundAppointment, let arrival, let budget {
                    // Earlier arrival causes more waiting; the two components are correlated.
                    waiting = secondsRange(lower: budget.upperBound.timeIntervalSince(arrival.upperBound),
                                           upper: budget.lowerBound.timeIntervalSince(arrival.lowerBound))
                }
            }
            output.places.append(ScheduledPlace(placeID: place.id, arrival: arrival, budgetStart: budget,
                                                 exit: exit, allocation: allocation, incomingSource: source,
                                                 incomingTravel: incomingTravel, waiting: waiting,
                                                 remainingVisitSeconds: remainingVisitSeconds,
                                                 reducibleVisitSeconds: reducibleVisitSeconds))
            cursor = exit
            earliestCursor = earliestExit
        }
        output.completion = output.unresolvedRequirementIDs.isEmpty ? cursor : nil
        let order = Dictionary(uniqueKeysWithValues: places.enumerated().map { ($0.element.id, $0.offset) })
        output.conflicts.sort { left, right in
            let leftIndex = order[left.placeID] ?? 0, rightIndex = order[right.placeID] ?? 0
            return leftIndex == rightIndex ? left.deadline < right.deadline : leftIndex < rightIndex
        }
        return output
    }

    private static func secondsRange(lower: TimeInterval, upper: TimeInterval) -> DurationRange {
        DurationRange(minimum: Int(floor(max(0, lower))), maximum: Int(ceil(max(0, upper))))
    }

    private struct TravelResult {
        var duration: DurationRange?
        var source: ScheduleEstimateSource
        var request: RouteRequestContext?
    }

    private static func travelDuration(trip: Trip, from: Place?, to: Place, first: Bool, liveOrigin: Point?,
                                       departure: Date, now: Date, routes: [LegEstimate]) -> TravelResult {
        let activeApproach = first && trip.status == .active
        let origin = from?.exit.center ?? (activeApproach ? liveOrigin : (trip.origin ?? liveOrigin))
        let fromID = from?.id
        let mode = effectiveMode(trip: trip, from: fromID, to: to.id)
        let configured = trip.plan.leg(from: fromID, to: to.id)
        let requestKind: RouteRequestContext.Kind = activeApproach ? .liveApproach :
            (isCanonicalConnection(trip: trip, from: fromID, to: to.id) ? .fullLeg : .bypass)
        // Full-leg manual durations are not a live countdown and cannot stand in for remaining travel.
        if !activeApproach, let manual = configured?.manualDuration {
            return TravelResult(duration: manual, source: .manual, request: nil)
        }
        guard let origin else { return TravelResult(duration: nil, source: .unavailable, request: nil) }
        if let manual = trip.manualRouteEstimates.last(where: {
            $0.isValid && $0.mode == mode && $0.destination.sameCoordinates(as: to.entry.center) &&
            (activeApproach || $0.liveApproach != true) &&
            (activeApproach ? $0.source.distance(to: origin) <= 75 : $0.source.sameCoordinates(as: origin))
        }) {
            return TravelResult(duration: manual.duration, source: .manual, request: nil)
        }
        let request = RouteRequestContext(tripID: trip.id, revision: trip.revision, fromPlaceID: fromID,
                                           toPlaceID: to.id, source: origin, destination: to.entry.center,
                                           mode: mode, departureAt: departure, kind: requestKind)
        let estimates = (activeApproach ? [trip.approachEstimate].compactMap { $0 } :
                         [configured?.estimate].compactMap { $0 }) + routes
        let match = estimates.filter {
            TripRoutes.matches($0, request: request, sourceToleranceMeters: activeApproach ? 75 : 0)
        }.min {
            let firstContext = abs($0.departureAt.timeIntervalSince(departure))
            let secondContext = abs($1.departureAt.timeIntervalSince(departure))
            return abs(firstContext - secondContext) < 1 ? $0.fetchedAt > $1.fetchedAt : firstContext < secondContext
        }
        guard let match else { return TravelResult(duration: nil, source: .unavailable, request: request) }
        let age = now.timeIntervalSince(match.fetchedAt)
        let fresh = age >= -5 && age <= (activeApproach ? 120 : 900) && abs(match.departureAt.timeIntervalSince(departure)) <= 900
        if activeApproach && !fresh { return TravelResult(duration: nil, source: .unavailable, request: request) }
        return TravelResult(duration: match.duration, source: fresh ? .current : .cached, request: fresh ? nil : request)
    }

    static func effectiveMode(trip: Trip, from: UUID?, to: UUID) -> TravelMode {
        if let leg = trip.plan.leg(from: from, to: to) { return leg.mode }
        guard let destination = trip.plan.places.firstIndex(where: { $0.id == to }) else { return trip.plan.initialMode }
        if destination == 0 { return trip.plan.initialMode }
        return trip.plan.leg(from: trip.plan.places[destination - 1].id, to: to)?.mode ?? trip.plan.initialMode
    }

    private static func isCanonicalConnection(trip: Trip, from: UUID?, to: UUID) -> Bool {
        guard let index = trip.plan.places.firstIndex(where: { $0.id == to }) else { return false }
        return index == 0 ? from == nil : from == trip.plan.places[index - 1].id
    }

    private static func canBridgeSkipping(_ id: UUID, trip: Trip) -> Bool {
        let remaining = remainingPlaces(trip)
        guard let index = remaining.firstIndex(where: { $0.id == id }) else { return false }
        if index == remaining.count - 1 { return true }
        let beforeID = index == 0 ? nil : remaining[index - 1].id
        let afterID = remaining[index + 1].id
        let canonical = trip.plan.places
        let start = beforeID.flatMap { id in canonical.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        guard let end = canonical.firstIndex(where: { $0.id == afterID }) else { return false }
        guard start <= end else { return false }
        var mode: TravelMode?
        for target in start...end {
            let from = target == 0 ? nil : canonical[target - 1].id
            let nextMode = effectiveMode(trip: trip, from: from, to: canonical[target].id)
            if let mode, mode != nextMode { return false }
            mode = nextMode
        }
        return true
    }

    private static func latestStart(trip: Trip, liveOrigin: Point?, now: Date, routes: [LegEstimate]) -> Date? {
        let places = remainingPlaces(trip)
        guard !places.isEmpty else { return nil }
        var latestArrival: Date?
        for index in places.indices.reversed() {
            let place = places[index]
            var latestExit: Date?
            if index + 1 < places.count, let nextLimit = latestArrival {
                let travel = travelDuration(trip: trip, from: place, to: places[index + 1], first: false,
                                            liveOrigin: liveOrigin, departure: nextLimit, now: now, routes: routes)
                guard let duration = travel.duration else { return nil }
                latestExit = nextLimit.addingTimeInterval(-Double(duration.maximum))
            }
            for requirement in place.requirements where requirement.kind == .leaveBy {
                if let date = trip.bindings[requirement.id] { latestExit = min(latestExit ?? .distantFuture, date) }
            }
            latestArrival = latestExit?.addingTimeInterval(-Double(trip.allocation(for: place.id)))
            let appointment = place.requirements.filter { $0.kind == .appointment }.compactMap { trip.bindings[$0.id] }.max()
            // An earlier Entry deadline can coexist with waiting for an appointment. Only a
            // downstream departure limit can make that appointment's visit budget impossible.
            if let appointment, let latestArrival, latestArrival < appointment { return nil }
            for requirement in place.requirements where requirement.kind != .leaveBy {
                guard let date = trip.bindings[requirement.id] else { continue }
                latestArrival = min(latestArrival ?? .distantFuture, date)
            }
        }
        guard let limit = latestArrival else { return nil }
        let approach = travelDuration(trip: trip, from: nil, to: places[0], first: true,
                                       liveOrigin: liveOrigin, departure: limit, now: now, routes: routes)
        guard let duration = approach.duration else { return nil }
        let candidate = limit.addingTimeInterval(-Double(duration.maximum))
        var verification = trip
        verification.scheduledStart = candidate
        let check = forward(trip: verification, liveOrigin: liveOrigin, now: now, routes: routes)
        let constrainedMilestonesKnown = places.allSatisfy { place in
            place.requirements.allSatisfy { requirement in
                guard trip.bindings[requirement.id] != nil else { return false }
                let scheduled = check.place(place.id)
                return requirement.kind == .leaveBy ? scheduled?.exit != nil : scheduled?.arrival != nil
            }
        }
        // Travel after the final timed milestone can make completion unknown without changing
        // the latest departure needed to satisfy all known Entry/Exit constraints.
        return check.conflicts.isEmpty && constrainedMilestonesKnown ? candidate : nil
    }

    private static func uniqueRequests(_ requests: [RouteRequestContext]) -> [RouteRequestContext] {
        var keys = Set<String>()
        return requests.filter { keys.insert($0.cacheKey).inserted }
    }
}
