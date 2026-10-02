import XCTest
@testable import CompassDay

final class TripSchedulerTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private func time(_ minutes: Int) -> Date { epoch.addingTimeInterval(Double(minutes * 60)) }
    private func place(_ name: String, minutes: Int = 5, minimum: Int? = nil,
                       optional: Bool = false, priority: Int = 0, longitude: Double = -97.5,
                       requirement: TimeRequirement.Kind? = nil) -> Place {
        let point = Point(name: name, latitude: 35.4, longitude: longitude)
        return Place(name: name, entry: Area(name: "Entry", center: point, radiusMeters: 30),
                     explore: Area(name: "Explore", center: point, radiusMeters: 30),
                     exit: Area(name: "Exit", center: point, radiusMeters: 30),
                     duration: .init(minimum: (minimum ?? minutes) * 60, maximum: minutes * 60),
                     isOptional: optional, keepPriority: priority,
                     requirements: requirement.map { [.init(kind: $0, label: "\(name) time")] } ?? [])
    }
    private func trip(_ places: [Place], start: Int = 0, approach: Int = 0, travel: Int = 0) -> Trip {
        var result = Trip(plan: Plan(name: "Day", places: places), scheduledStart: time(start),
                          origin: Point(latitude: 35.3, longitude: -97.6))
        for index in result.plan.legs.indices {
            let minutes = index == 0 ? approach : travel
            result.plan.legs[index].manualDuration = .init(minimum: minutes * 60, maximum: minutes * 60)
        }
        return result
    }
    private func bind(_ place: Place, at minute: Int, to trip: inout Trip) {
        trip.bindings[place.requirements[0].id] = time(minute)
    }
    private func active(_ trip: inout Trip, place: Place, at minute: Int, arrived: Bool) {
        trip.status = .active
        trip.startedAt = time(0)
        trip.phase = TripPhase(placeID: place.id, kind: arrived ? .exploring : .approaching, effectiveAt: time(minute))
        if arrived {
            trip.visits[place.id] = VisitRecord(place: place, arrivedAt: time(minute), budgetAnchor: time(minute), budgetAnchorFrozen: true)
        }
    }
    private func route(from: Point, to: Place, duration: Int, departure: Int = 0, fetched: Int = 0,
                       mode: TravelMode = .driving) -> LegEstimate {
        LegEstimate(duration: .init(minimum: duration * 60, maximum: duration * 60), source: from,
                    destination: to.entry.center, mode: mode, departureAt: time(departure), fetchedAt: time(fetched))
    }

    func testImpossibleIntervalBetweenAppointmentsCannotBeFixedByStartingEarlier() {
        let lunch = place("Lunch", minutes: 30, requirement: .appointment)
        let next = place("Next", requirement: .arriveBy)
        var run = trip([lunch, next], start: 0, travel: 10)
        bind(lunch, at: 60, to: &run)
        bind(next, at: 80, to: &run)
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertNil(projection.startBy)
        XCTAssertTrue(projection.hasTimeConflicts)
        XCTAssertFalse(projection.isRunningBehind)
        XCTAssertFalse(projection.hasUnknownEstimates)
        XCTAssertEqual(projection.place(next.id)?.arrival?.upperBound, time(100))
        XCTAssertEqual(projection.conflicts.first?.lateness, 20 * 60)
        XCTAssertEqual(projection.conflicts.count, 1)
        XCTAssertEqual(projection.conflicts.first?.isLowerBoundOnly, false)
        XCTAssertEqual(projection.maximumLateness, 20 * 60)
        XCTAssertEqual(projection.maximumLatenessRange, 1_200...1_200)

        run.scheduledStart = time(-120)
        let earlier = TripScheduler.project(trip: run, now: time(0))
        XCTAssertNil(earlier.startBy)
        XCTAssertEqual(earlier.maximumLateness, 20 * 60)
        XCTAssertEqual(earlier.place(next.id)?.arrival?.upperBound, time(100))
    }

    func testAppointmentAndExitAtSameTimeProveConflictWithoutStartingOrigin() {
        var dinner = place("Dinner", minutes: 5, requirement: .appointment)
        let leaveBy = TimeRequirement(kind: .leaveBy, label: "Leave dinner")
        dinner.requirements.append(leaveBy)
        var run = trip([dinner])
        run.origin = nil
        run.plan.legs[0].manualDuration = nil
        bind(dinner, at: 60, to: &run)
        run.bindings[leaveBy.id] = time(60)

        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertTrue(projection.hasTimeConflicts)
        XCTAssertFalse(projection.isRunningBehind)
        XCTAssertEqual(projection.conflicts.count, 1)
        XCTAssertEqual(projection.conflicts.first?.requirementID, leaveBy.id)
        XCTAssertEqual(projection.conflicts.first?.isLowerBoundOnly, true)
        XCTAssertEqual(projection.conflicts.first?.predicted, time(65))
        XCTAssertEqual(projection.maximumLateness, 300)
        XCTAssertTrue(projection.hasUnknownEstimates)
        XCTAssertNil(projection.place(dinner.id)?.arrival)
        XCTAssertNil(projection.place(dinner.id)?.budgetStart)
        XCTAssertNil(projection.place(dinner.id)?.exit)
        XCTAssertNil(projection.completion)
        XCTAssertNil(projection.startBy)
        XCTAssertTrue(run.visits.isEmpty)
        XCTAssertNil(run.startedAt)
    }

    func testUnknownConnectingTravelStillProvesMinimumAppointmentGap() {
        let lunch = place("Lunch", minutes: 30, requirement: .appointment)
        let next = place("Next", requirement: .arriveBy)
        var run = trip([lunch, next])
        bind(lunch, at: 60, to: &run)
        bind(next, at: 80, to: &run)
        run.plan.legs[1].manualDuration = nil

        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(projection.conflicts.count, 1)
        XCTAssertEqual(projection.conflicts.first?.isLowerBoundOnly, true)
        XCTAssertEqual(projection.conflicts.first?.predicted, time(90))
        XCTAssertEqual(projection.maximumLateness, 10 * 60)
        XCTAssertNil(projection.place(next.id)?.arrival)
        XCTAssertNil(projection.completion)
        XCTAssertTrue(projection.hasUnknownEstimates)
        XCTAssertEqual(projection.missingRoutes.first?.toPlaceID, next.id)

        run.scheduledStart = time(-120)
        let earlier = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(earlier.maximumLateness, 10 * 60)
        XCTAssertNil(earlier.completion)
    }

    func testKnownTravelMinimumStrengthensProofAfterUnknownInitialApproach() {
        let lunch = place("Lunch", minutes: 30, requirement: .appointment)
        let next = place("Next", requirement: .arriveBy)
        var run = trip([lunch, next])
        bind(lunch, at: 60, to: &run)
        bind(next, at: 80, to: &run)
        run.origin = nil
        run.plan.legs[0].manualDuration = nil
        run.plan.legs[1].manualDuration = .init(minimum: 10 * 60, maximum: 12 * 60)

        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(projection.conflicts.count, 1)
        XCTAssertEqual(projection.conflicts.first?.isLowerBoundOnly, true)
        XCTAssertEqual(projection.conflicts.first?.predicted, time(100))
        XCTAssertEqual(projection.maximumLateness, 20 * 60)
        XCTAssertNil(projection.place(next.id)?.arrival)
        XCTAssertNil(projection.completion)
        XCTAssertTrue(projection.hasUnknownEstimates)
    }

    func testLowerBoundConflictCanShortenFlexibleTimeWithoutInventingTravel() {
        var dinner = place("Dinner", minutes: 30, minimum: 10, requirement: .appointment)
        let leaveBy = TimeRequirement(kind: .leaveBy, label: "Leave dinner")
        dinner.requirements.append(leaveBy)
        var run = trip([dinner])
        run.origin = nil
        run.plan.legs[0].manualDuration = nil
        bind(dinner, at: 60, to: &run)
        run.bindings[leaveBy.id] = time(80)

        let before = TripScheduler.project(trip: run, now: time(0), adapt: false)
        XCTAssertEqual(before.maximumLateness, 10 * 60)
        XCTAssertEqual(before.conflicts.first?.isLowerBoundOnly, true)
        let adapted = TripScheduler.project(trip: run, now: time(0))
        XCTAssertFalse(adapted.hasTimeConflicts)
        XCTAssertEqual(adapted.allocations[dinner.id], 20 * 60)
        XCTAssertEqual(run.plan.places[0].duration.maximum, 30 * 60)
        XCTAssertTrue(adapted.hasUnknownEstimates)
        XCTAssertNil(adapted.completion)
        XCTAssertNil(adapted.place(dinner.id)?.arrival)
        XCTAssertTrue(adapted.skippedPlaceIDs.isEmpty)
    }

    func testCompletedEarlyAppointmentRemainsHistoryWhenNextTravelIsUnknown() {
        let dinner = place("Dinner", minutes: 30, requirement: .appointment)
        let next = place("Next", minutes: 5, requirement: .arriveBy)
        var run = trip([dinner, next])
        bind(dinner, at: 60, to: &run)
        bind(next, at: 120, to: &run)
        run.status = .active
        run.startedAt = time(0)
        run.phase = TripPhase(placeID: next.id, kind: .approaching, effectiveAt: time(10))
        run.visits[dinner.id] = VisitRecord(place: dinner, arrivedAt: time(0),
                                           departureRequestedAt: time(10), exitedAt: time(10), completed: true)
        let history = run.visits[dinner.id]

        let projection = TripScheduler.project(trip: run, now: time(10))
        XCTAssertNil(projection.place(dinner.id))
        XCTAssertFalse(projection.hasTimeConflicts)
        XCTAssertNil(projection.completion)
        XCTAssertEqual(run.visits[dinner.id], history)
        XCTAssertNil(run.visits[dinner.id]?.budgetAnchor)
        XCTAssertEqual(run.visits[dinner.id]?.exitedAt, time(10))
    }

    func testTimingComponentsKeepAppointmentWaitingSeparateFromVisitFlexibility() {
        let stop = place("Appointment", minutes: 30, minimum: 10, requirement: .appointment)
        var run = trip([stop])
        run.plan.legs[0].manualDuration = .init(minimum: 10 * 60, maximum: 20 * 60)
        bind(stop, at: 60, to: &run)

        let projection = TripScheduler.project(trip: run, now: time(0))
        let row = projection.place(stop.id)
        XCTAssertEqual(row?.incomingTravel, .init(minimum: 600, maximum: 1_200))
        XCTAssertEqual(row?.waiting, .init(minimum: 2_400, maximum: 3_000))
        XCTAssertEqual(row?.remainingVisitSeconds, 1_800)
        XCTAssertEqual(row?.reducibleVisitSeconds, 1_200)
        XCTAssertEqual(row?.allocation, 1_800)
        // Travel and waiting vary in opposite directions, so completion must retain the
        // forward propagation rather than adding the components' independent extrema.
        XCTAssertEqual(projection.completion, time(90)...time(90))
    }

    func testActiveTimingComponentsUseRemainingWaitAndStoredBudgetElapsedTime() {
        let stop = place("Appointment", minutes: 30, minimum: 10, requirement: .appointment)
        var run = trip([stop])
        bind(stop, at: 60, to: &run)
        active(&run, place: stop, at: 10, arrived: true)
        run.visits[stop.id]?.budgetAnchor = time(60)
        run.visits[stop.id]?.budgetAnchorFrozen = false
        let recordedVisit = run.visits[stop.id]

        let early = TripScheduler.project(trip: run, now: time(30)).place(stop.id)
        XCTAssertEqual(early?.incomingTravel, .init(minimum: 0, maximum: 0))
        XCTAssertEqual(early?.waiting, .init(minimum: 1_800, maximum: 1_800))
        XCTAssertEqual(early?.remainingVisitSeconds, 1_800)
        XCTAssertEqual(early?.reducibleVisitSeconds, 1_200)

        let underway = TripScheduler.project(trip: run, now: time(65)).place(stop.id)
        XCTAssertEqual(underway?.waiting, .init(minimum: 0, maximum: 0))
        XCTAssertEqual(underway?.remainingVisitSeconds, 1_500)
        XCTAssertEqual(underway?.reducibleVisitSeconds, 1_200)

        let over = TripScheduler.project(trip: run, now: time(95)).place(stop.id)
        XCTAssertEqual(over?.remainingVisitSeconds, 0)
        XCTAssertEqual(over?.reducibleVisitSeconds, 0)
        XCTAssertEqual(run.visits[stop.id], recordedVisit)
    }

    func testUnknownTravelAndHistoricalBudgetRemainUnknownInTimingComponents() {
        let stop = place("Stop")
        var run = trip([stop])
        run.origin = nil
        run.plan.legs[0].manualDuration = nil
        let future = TripScheduler.project(trip: run, now: time(0)).place(stop.id)
        XCTAssertNil(future?.incomingTravel)
        XCTAssertEqual(future?.waiting, .init(minimum: 0, maximum: 0))
        XCTAssertEqual(future?.remainingVisitSeconds, 300)
        XCTAssertEqual(future?.reducibleVisitSeconds, 0)

        active(&run, place: stop, at: 0, arrived: false)
        run.phase?.kind = .exploring
        run.visits[stop.id] = VisitRecord(place: stop)
        let historical = TripScheduler.project(trip: run, now: time(60)).place(stop.id)
        XCTAssertEqual(historical?.incomingTravel, .init(minimum: 0, maximum: 0))
        XCTAssertNil(historical?.waiting)
        XCTAssertNil(historical?.remainingVisitSeconds)
        XCTAssertNil(historical?.reducibleVisitSeconds)
        XCTAssertNil(run.visits[stop.id]?.arrivedAt)
        XCTAssertNil(run.visits[stop.id]?.budgetAnchor)
    }

    func testEarlierBindingLeaveByMovesArrivalWhileAppointmentWaitKeepsCompletion() {
        let first = place("Flexible visit", minutes: 30, minimum: 10, requirement: .leaveBy)
        let appointment = place("Appointment", minutes: 5, requirement: .appointment)
        var run = trip([first, appointment], approach: 10, travel: 10)
        bind(first, at: 50, to: &run)
        bind(appointment, at: 80, to: &run)
        let original = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(original.place(first.id)?.exit, time(40)...time(40))
        XCTAssertEqual(original.place(appointment.id)?.arrival, time(50)...time(50))
        XCTAssertEqual(original.place(appointment.id)?.waiting, .init(minimum: 1_800, maximum: 1_800))

        bind(first, at: 45, to: &run)
        let nonbinding = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(nonbinding.allocations, original.allocations)
        XCTAssertEqual(nonbinding.place(appointment.id)?.arrival, original.place(appointment.id)?.arrival)

        bind(first, at: 35, to: &run)
        let binding = TripScheduler.project(trip: run, now: time(0))
        XCTAssertFalse(binding.hasTimeConflicts)
        XCTAssertEqual(binding.allocations[first.id], 1_500)
        XCTAssertEqual(binding.place(first.id)?.exit, time(35)...time(35))
        XCTAssertEqual(binding.place(first.id)?.remainingVisitSeconds, 1_500)
        XCTAssertEqual(binding.place(first.id)?.reducibleVisitSeconds, 900)
        XCTAssertEqual(binding.place(appointment.id)?.arrival, time(45)...time(45))
        XCTAssertEqual(binding.place(appointment.id)?.waiting, .init(minimum: 2_100, maximum: 2_100))
        XCTAssertEqual(binding.completion, original.completion)
        XCTAssertEqual(binding.completion, time(85)...time(85))
    }

    func testLeaveByRespectsConfiguredDurationAndElapsedVisitTime() {
        // Minute zero represents 3 p.m.; the Exit deadline is always 5 p.m.
        let cases: [(name: String, arrival: Int, minimum: Int, maximum: Int, now: Int?,
                     allocation: Int, exit: Int, late: Int)] = [
            ("3:20 arrival keeps full flexible hour", 20, 45, 60, nil, 60, 80, 0),
            ("4:10 arrival shortens to fifty minutes", 70, 45, 60, nil, 50, 120, 0),
            ("4:30 arrival preserves forty-five-minute minimum", 90, 45, 60, nil, 45, 135, 15),
            ("Early fixed hour is not extended to the deadline", 20, 60, 60, nil, 60, 80, 0),
            ("Late fixed hour is not shortened to the deadline", 70, 60, 60, nil, 60, 130, 10),
            ("Fifty elapsed minutes cannot be reduced to forty-five", 90, 45, 60, 140, 50, 140, 20),
            ("Overrun preserves actual time without expanding the allocation", 90, 45, 60, 165, 60, 165, 45)
        ]
        for example in cases {
            let stop = place("Visit", minutes: example.maximum, minimum: example.minimum, requirement: .leaveBy)
            var run = trip([stop], approach: example.arrival)
            bind(stop, at: 120, to: &run)
            if example.now != nil { active(&run, place: stop, at: example.arrival, arrived: true) }
            let recordedVisits = run.visits
            let projection = TripScheduler.project(trip: run, now: time(example.now ?? 0))
            let allocation = projection.allocations[stop.id] ?? -1
            XCTAssertEqual(allocation, example.allocation * 60, example.name)
            XCTAssertGreaterThanOrEqual(allocation, example.minimum * 60, example.name)
            XCTAssertLessThanOrEqual(allocation, example.maximum * 60, example.name)
            XCTAssertEqual(projection.place(stop.id)?.exit, time(example.exit)...time(example.exit), example.name)
            XCTAssertEqual(projection.maximumLateness, Double(example.late * 60), example.name)
            XCTAssertEqual(projection.hasTimeConflicts, example.late > 0, example.name)
            TripScheduler.apply(projection, to: &run)
            XCTAssertEqual(run.allocation(for: stop.id), example.allocation * 60, example.name)
            XCTAssertEqual(run.plan.places[0].duration, stop.duration, example.name)
            XCTAssertEqual(run.visits, recordedVisits, example.name)
        }
    }

    func testRunningBehindOnlyDescribesAnActiveTrip() {
        let stop = place("Stop", minutes: 30, requirement: .leaveBy)
        var run = trip([stop])
        bind(stop, at: 20, to: &run)
        let scheduled = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(scheduled.status, .scheduled)
        XCTAssertTrue(scheduled.hasTimeConflicts)
        XCTAssertFalse(scheduled.isRunningBehind)
        XCTAssertEqual(scheduled.maximumLateness, 10 * 60)

        active(&run, place: stop, at: 0, arrived: true)
        let navigating = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(navigating.status, .active)
        XCTAssertTrue(navigating.hasTimeConflicts)
        XCTAssertTrue(navigating.isRunningBehind)
        XCTAssertEqual(navigating.maximumLateness, 10 * 60)

        for status in [TripStatus.completed, .canceled] {
            run.status = status
            let ended = TripScheduler.project(trip: run, now: time(60))
            XCTAssertEqual(ended.status, status)
            XCTAssertFalse(ended.hasTimeConflicts)
            XCTAssertFalse(ended.isRunningBehind)
            XCTAssertEqual(ended.maximumLatenessRange, 0...0)
        }
    }

    func testEarlierPlannedStartReducesOverrunButEarlierExitDeadlineIncreasesIt() {
        let stop = place("Stop", minutes: 30, requirement: .leaveBy)
        var run = trip([stop])
        bind(stop, at: 20, to: &run)
        let original = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(original.maximumLateness, 10 * 60)
        XCTAssertEqual(original.startBy, time(-10))
        XCTAssertEqual(original.place(stop.id)?.exit?.upperBound, time(30))

        run.scheduledStart = time(-10)
        let earlierStart = TripScheduler.project(trip: run, now: time(0))
        XCTAssertFalse(earlierStart.hasTimeConflicts)
        XCTAssertEqual(earlierStart.maximumLatenessRange, 0...0)
        XCTAssertEqual(earlierStart.place(stop.id)?.exit?.upperBound, time(20))

        run.scheduledStart = time(0)
        bind(stop, at: 10, to: &run)
        let earlierDeadline = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(earlierDeadline.maximumLateness, 20 * 60)
        XCTAssertEqual(earlierDeadline.startBy, time(-20))
        XCTAssertEqual(earlierDeadline.place(stop.id)?.exit?.upperBound, time(30))
        XCTAssertEqual(run.scheduledStart, time(0))
        XCTAssertEqual(earlierDeadline.allocations[stop.id], 30 * 60)
    }

    func testMaximumOverrunDoesNotAddDelaysSharedBySeveralDeadlines() {
        let first = place("First", minutes: 30, requirement: .leaveBy)
        let second = place("Second", minutes: 0, requirement: .arriveBy)
        var run = trip([first, second])
        bind(first, at: 10, to: &run)
        bind(second, at: 15, to: &run)
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(projection.conflicts.count, 2)
        XCTAssertEqual(projection.conflicts.map(\.lateness), [1_200, 900])
        XCTAssertEqual(projection.maximumLateness, 1_200)
        XCTAssertEqual(projection.maximumLatenessRange, 1_200...1_200)
    }

    func testOverrunRangeUsesEntryForArrivalAndExitForLeaveBy() {
        var stop = place("Stop", minutes: 30, requirement: .arriveBy)
        let leaveBy = TimeRequirement(kind: .leaveBy, label: "Leave")
        stop.requirements.append(leaveBy)
        var run = trip([stop])
        run.plan.legs[0].manualDuration = .init(minimum: 10 * 60, maximum: 12 * 60)
        bind(stop, at: 11, to: &run)
        run.bindings[leaveBy.id] = time(41)
        let tight = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(tight.conflicts.count, 2)
        for conflict in tight.conflicts {
            XCTAssertEqual(tight.latenessRange(for: conflict), 0...60)
        }
        XCTAssertEqual(tight.maximumLateness, 60)
        XCTAssertEqual(tight.maximumLatenessRange, 0...60)

        bind(stop, at: 5, to: &run)
        run.bindings[leaveBy.id] = time(35)
        let late = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(late.conflicts.count, 2)
        for conflict in late.conflicts {
            XCTAssertEqual(late.latenessRange(for: conflict), 300...420)
        }
        XCTAssertEqual(late.maximumLateness, 420)
        XCTAssertEqual(late.maximumLatenessRange, 300...420)
    }

    func testLateObservedAppointmentDoesNotKeepLaterScheduleBehind() {
        let lunch = place("Lunch", minutes: 20, requirement: .appointment)
        let next = place("Next", requirement: .arriveBy)
        var run = trip([lunch, next], travel: 10)
        bind(lunch, at: 60, to: &run)
        bind(next, at: 120, to: &run)
        active(&run, place: lunch, at: 70, arrived: true)
        let projection = TripScheduler.project(trip: run, now: time(70))
        XCTAssertFalse(projection.hasTimeConflicts)
        XCTAssertEqual(projection.place(next.id)?.arrival?.upperBound, time(100))
    }

    func testLatestStartIncludesInitialApproachAndAppointmentWaiting() {
        let lunch = place("Lunch", minutes: 30, requirement: .appointment)
        let next = place("Next", requirement: .arriveBy)
        var run = trip([lunch, next], approach: 15, travel: 10)
        bind(lunch, at: 60, to: &run)
        bind(next, at: 120, to: &run)
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(projection.startBy, time(45))
        XCTAssertEqual(projection.place(lunch.id)?.arrival?.upperBound, time(15))
        XCTAssertEqual(projection.place(lunch.id)?.budgetStart?.upperBound, time(60))
        XCTAssertEqual(projection.completion?.upperBound, time(105))
    }

    func testFlexibleReductionIsProportionalAndDoesNotChangeConfiguredRanges() {
        let first = place("First", minutes: 60, minimum: 20)
        let second = place("Second", minutes: 60, minimum: 20)
        let last = place("Last", minutes: 0, requirement: .arriveBy)
        var run = trip([first, second, last])
        bind(last, at: 90, to: &run)
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(projection.allocations[first.id], 45 * 60)
        XCTAssertEqual(projection.allocations[second.id], 45 * 60)
        XCTAssertFalse(projection.hasTimeConflicts)
        XCTAssertTrue(TripScheduler.apply(projection, to: &run))
        XCTAssertEqual(run.plan.places[0].duration.maximum, 60 * 60)
        XCTAssertEqual(run.allocation(for: first.id), 45 * 60)
    }

    func testWaitingBeforeAnAppointmentIsNotShortenedWhenItCannotHelp() {
        let first = place("First", minutes: 60, minimum: 20)
        let appointment = place("Appointment", minutes: 30, requirement: .appointment)
        let last = place("Last", requirement: .arriveBy)
        var run = trip([first, appointment, last], travel: 10)
        bind(appointment, at: 120, to: &run)
        bind(last, at: 155, to: &run)
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertTrue(projection.hasTimeConflicts)
        XCTAssertEqual(projection.allocations[first.id], 60 * 60)
    }

    func testActiveAllocationCannotBeReducedBelowElapsedTime() {
        let current = place("Current", minutes: 60, minimum: 10, requirement: .leaveBy)
        var run = trip([current])
        bind(current, at: 45, to: &run)
        active(&run, place: current, at: 0, arrived: true)
        let projection = TripScheduler.project(trip: run, now: time(50))
        XCTAssertEqual(projection.allocations[current.id], 50 * 60)
        XCTAssertEqual(projection.conflicts.first?.lateness, 5 * 60)
    }

    func testAllocationDoesNotExpandWhenDeadlineIsMovedLater() {
        let current = place("Current", minutes: 60, minimum: 10, requirement: .leaveBy)
        var run = trip([current])
        bind(current, at: 30, to: &run)
        let first = TripScheduler.project(trip: run, now: time(0))
        XCTAssertTrue(TripScheduler.apply(first, to: &run))
        bind(current, at: 120, to: &run)
        let later = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(later.allocations[current.id], 30 * 60)
    }

    func testCurrentApproachDestinationCannotBeAutomaticallySkipped() {
        let current = place("Current", minutes: 60, optional: true, requirement: .arriveBy)
        var run = trip([current])
        bind(current, at: 5, to: &run)
        active(&run, place: current, at: 0, arrived: false)
        let origin = run.origin!
        run.approachEstimate = route(from: origin, to: current, duration: 10)
        let projection = TripScheduler.project(trip: run, liveOrigin: origin, now: time(0))
        XCTAssertFalse(projection.skippedPlaceIDs.contains(current.id))
        XCTAssertTrue(projection.hasTimeConflicts)
    }

    func testTimedOptionalPlaceCanBeSkippedBeforeStart() {
        let optional = place("Optional", minutes: 60, optional: true, requirement: .arriveBy)
        var run = trip([optional], approach: 10)
        bind(optional, at: 5, to: &run)
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertTrue(projection.skippedPlaceIDs.contains(optional.id))
        XCTAssertFalse(projection.hasTimeConflicts)
    }

    func testOptionalSkipNeedsKnownReplacementRoute() {
        let first = place("First", minutes: 0, longitude: -97.1)
        let optional = place("Optional", minutes: 60, optional: true, longitude: -97.2)
        let last = place("Last", minutes: 0, longitude: -97.3, requirement: .arriveBy)
        var run = trip([first, optional, last], travel: 10)
        bind(last, at: 30, to: &run)
        let unknown = TripScheduler.project(trip: run, now: time(0))
        XCTAssertFalse(unknown.skippedPlaceIDs.contains(optional.id))
        XCTAssertTrue(unknown.missingRoutes.contains { $0.kind == .bypass && $0.toPlaceID == last.id })
        let bridge = route(from: first.exit.center, to: last, duration: 10)
        let known = TripScheduler.project(trip: run, now: time(0), routes: [bridge])
        XCTAssertTrue(known.skippedPlaceIDs.contains(optional.id))
        XCTAssertEqual(known.place(last.id)?.arrival?.upperBound, time(10))
    }

    func testTravelModeChangePlaceIsRetained() {
        let first = place("First", minutes: 0, longitude: -97.1)
        let parking = place("Parking", minutes: 60, optional: true, longitude: -97.2)
        let last = place("Last", minutes: 0, longitude: -97.3, requirement: .arriveBy)
        var run = trip([first, parking, last], travel: 10)
        run.plan.legs[2].mode = .walking
        bind(last, at: 30, to: &run)
        let bridge = route(from: first.exit.center, to: last, duration: 1, mode: .walking)
        let projection = TripScheduler.project(trip: run, now: time(0), routes: [bridge])
        XCTAssertFalse(projection.skippedPlaceIDs.contains(parking.id))
    }

    func testLowerPriorityOptionalPlaceIsSkippedFirst() {
        let first = place("First", minutes: 0, longitude: -97.1)
        let high = place("High", minutes: 30, optional: true, priority: 10, longitude: -97.2)
        let low = place("Low", minutes: 30, optional: true, priority: 1, longitude: -97.3)
        let last = place("Last", minutes: 0, longitude: -97.4, requirement: .arriveBy)
        var run = trip([first, high, low, last])
        bind(last, at: 40, to: &run)
        let bridge = route(from: high.exit.center, to: last, duration: 0, departure: 30)
        let projection = TripScheduler.project(trip: run, now: time(0), routes: [bridge])
        XCTAssertTrue(projection.skippedPlaceIDs.contains(low.id))
        XCTAssertFalse(projection.skippedPlaceIDs.contains(high.id))
    }

    func testUnknownOfflineTravelDoesNotInventCompletionOrLatestStart() {
        let first = place("First", requirement: .arriveBy)
        var run = trip([first])
        run.plan.legs[0].manualDuration = nil
        bind(first, at: 60, to: &run)
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertNil(projection.completion)
        XCTAssertNil(projection.startBy)
        XCTAssertTrue(projection.hasUnknownEstimates)
        XCTAssertEqual(projection.missingRoutes.count, 1)
    }

    func testRemainingTravelDoesNotCountDownWithoutNewLocationEstimate() {
        let current = place("Current", minutes: 0)
        var run = trip([current])
        active(&run, place: current, at: 0, arrived: false)
        let origin = run.origin!
        run.approachEstimate = route(from: origin, to: current, duration: 10)
        let projection = TripScheduler.project(trip: run, liveOrigin: origin, now: time(1))
        XCTAssertEqual(projection.place(current.id)?.arrival?.upperBound, time(11))
        let stale = TripScheduler.project(trip: run, liveOrigin: origin, now: time(10))
        XCTAssertNil(stale.completion)
    }

    func testDifferentBoundsUseSameAllocatedVisitDuration() {
        let current = place("Current", minutes: 30, minimum: 10)
        var run = trip([current])
        run.plan.legs[0].manualDuration = .init(minimum: 10 * 60, maximum: 12 * 60)
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(projection.completion, time(40)...time(42))
        XCTAssertEqual(projection.place(current.id)?.allocation, 30 * 60)
    }

    func testProjectionFromOldRevisionCannotChangeTrip() {
        let current = place("Current", minutes: 60, minimum: 10, requirement: .leaveBy)
        var run = trip([current])
        bind(current, at: 30, to: &run)
        let projection = TripScheduler.project(trip: run, now: time(0))
        run.revision += 1
        XCTAssertFalse(TripScheduler.apply(projection, to: &run))
        XCTAssertEqual(run.allocation(for: current.id), 60 * 60)
    }

    func testOldRouteResponseDoesNotMatchEditedCoordinatesOrRevision() {
        let current = place("Current")
        var run = trip([current])
        let context = RouteRequestContext(tripID: run.id, revision: run.revision, fromPlaceID: nil,
                                            toPlaceID: current.id, source: run.origin!, destination: current.entry.center,
                                            mode: .driving, departureAt: time(0), kind: .fullLeg)
        XCTAssertTrue(context.isValid(for: run))
        run.plan.places[0].entry.center.latitude += 1
        XCTAssertFalse(context.isValid(for: run))
        run.plan.places[0] = current
        run.revision += 1
        XCTAssertFalse(context.isValid(for: run))
    }

    func testCachedMapsEstimateIsLabeledAndQueuedForRefresh() {
        let current = place("Current")
        var run = trip([current])
        run.plan.legs[0].manualDuration = nil
        run.plan.legs[0].estimate = route(from: run.origin!, to: current, duration: 10, fetched: -60)
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertTrue(projection.hasCachedEstimates)
        XCTAssertEqual(projection.place(current.id)?.incomingSource, .cached)
        XCTAssertEqual(projection.completion?.upperBound, time(15))
        XCTAssertEqual(projection.missingRoutes.count, 1)
    }

    func testEarlierEntryDeadlineCanCoexistWithLaterAppointment() {
        var current = place("Current", minutes: 30, requirement: .arriveBy)
        current.requirements.append(.init(kind: .appointment, label: "Appointment"))
        var run = trip([current], approach: 10)
        run.bindings[current.requirements[0].id] = time(60)
        run.bindings[current.requirements[1].id] = time(90)
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(projection.startBy, time(50))
        XCTAssertEqual(projection.completion?.upperBound, time(120))
    }

    func testUnboundTimeRequirementDoesNotPretendScheduleIsKnown() {
        let current = place("Current", requirement: .appointment)
        var run = trip([current])
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(projection.unresolvedRequirementIDs, [current.requirements[0].id])
        XCTAssertNil(projection.completion)
        XCTAssertNil(projection.startBy)
        XCTAssertTrue(projection.hasUnknownEstimates)
        XCTAssertEqual(projection.place(current.id)?.incomingTravel, .init(minimum: 0, maximum: 0))
        XCTAssertNil(projection.place(current.id)?.waiting)

        active(&run, place: current, at: 0, arrived: true)
        run.visits[current.id]?.budgetAnchorFrozen = false
        let unfrozen = TripScheduler.project(trip: run, now: time(0))
        XCTAssertNil(unfrozen.place(current.id)?.waiting)
        run.visits[current.id]?.budgetAnchorFrozen = true
        let frozen = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(frozen.place(current.id)?.waiting, .init(minimum: 0, maximum: 0))
    }

    func testAcceptedBypassEstimateSurvivesSerializationAndReopening() throws {
        let first = place("First", minutes: 0, longitude: -97.1)
        let optional = place("Optional", minutes: 60, optional: true, longitude: -97.2)
        let last = place("Last", minutes: 0, longitude: -97.3, requirement: .arriveBy)
        var run = trip([first, optional, last], travel: 10)
        bind(last, at: 30, to: &run)
        run.routeEstimates = [route(from: first.exit.center, to: last, duration: 10)]
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertTrue(TripScheduler.apply(projection, to: &run))
        let reopened = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(run))
        let offline = TripScheduler.project(trip: reopened, now: time(1))
        XCTAssertTrue(offline.skippedPlaceIDs.contains(optional.id))
        XCTAssertEqual(offline.completion?.upperBound, time(10))
    }

    func testUnavoidableCurrentLatenessDoesNotPreventLaterRecovery() {
        let current = place("Current", minutes: 10, requirement: .leaveBy)
        let flexible = place("Flexible", minutes: 60, minimum: 10)
        let last = place("Last", minutes: 0, requirement: .arriveBy)
        var run = trip([current, flexible, last])
        bind(current, at: 15, to: &run)
        bind(last, at: 60, to: &run)
        active(&run, place: current, at: 0, arrived: true)
        let projection = TripScheduler.project(trip: run, now: time(20))
        XCTAssertEqual(projection.allocations[flexible.id], 40 * 60)
        XCTAssertEqual(projection.conflicts.map(\.placeID), [current.id])
        XCTAssertEqual(projection.place(last.id)?.arrival?.upperBound, time(60))
    }

    func testManualBypassSurvivesReopeningAndTakesPrecedenceOverMaps() throws {
        let first = place("First", minutes: 0, longitude: -97.1)
        let optional = place("Optional", minutes: 60, optional: true, longitude: -97.2)
        let last = place("Last", minutes: 0, longitude: -97.3, requirement: .arriveBy)
        var run = trip([first, optional, last], travel: 10)
        bind(last, at: 30, to: &run)
        let request = RouteRequestContext(tripID: run.id, revision: run.revision, fromPlaceID: first.id,
                                           toPlaceID: last.id, source: first.exit.center, destination: last.entry.center,
                                           mode: .driving, departureAt: time(0), kind: .bypass)
        XCTAssertTrue(ManualRouteEditing.apply(request: request, duration: .init(minimum: 600, maximum: 720), to: &run))
        let projection = TripScheduler.project(trip: run, now: time(0),
                                                routes: [route(from: first.exit.center, to: last, duration: 200)])
        XCTAssertTrue(projection.skippedPlaceIDs.contains(optional.id))
        XCTAssertEqual(projection.place(last.id)?.incomingSource, .manual)
        XCTAssertTrue(TripScheduler.apply(projection, to: &run))
        let reopened = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(run))
        let offline = TripScheduler.project(trip: reopened, now: time(500))
        XCTAssertEqual(offline.completion, time(10)...time(12))
        XCTAssertEqual(offline.place(last.id)?.incomingSource, .manual)
        XCTAssertTrue(offline.missingRoutes.isEmpty)
    }

    func testManualBypassDoesNotApplyAfterGeometryOrModeChanges() {
        let first = place("First", minutes: 0, longitude: -97.1)
        let optional = place("Optional", minutes: 60, optional: true, longitude: -97.2)
        let last = place("Last", minutes: 0, longitude: -97.3, requirement: .arriveBy)
        var run = trip([first, optional, last], travel: 10)
        bind(last, at: 30, to: &run)
        let request = RouteRequestContext(tripID: run.id, revision: run.revision, fromPlaceID: first.id,
                                           toPlaceID: last.id, source: first.exit.center, destination: last.entry.center,
                                           mode: .driving, departureAt: time(0), kind: .bypass)
        XCTAssertTrue(ManualRouteEditing.apply(request: request, duration: .init(minimum: 600, maximum: 600), to: &run))
        run.plan.places[2].entry.center.latitude += 0.1
        XCTAssertFalse(ManualRouteEditing.apply(request: request, duration: .init(minimum: 0, maximum: 0), to: &run))
        let changed = TripScheduler.project(trip: run, now: time(0))
        XCTAssertFalse(changed.skippedPlaceIDs.contains(optional.id))
        XCTAssertTrue(changed.missingRoutes.contains { $0.kind == .bypass })
        run.plan.places[2] = last
        run.plan.legs[2].mode = .walking
        XCTAssertFalse(ManualRouteEditing.apply(request: request, duration: .init(minimum: 0, maximum: 0), to: &run))
    }

    func testManualBypassEditDoesNotReplaceUnrelatedTripState() {
        let first = place("First", minutes: 0, longitude: -97.1)
        let last = place("Last", minutes: 0, longitude: -97.3)
        var run = trip([first, last])
        let request = RouteRequestContext(tripID: run.id, revision: run.revision, fromPlaceID: first.id,
                                           toPlaceID: last.id, source: first.exit.center, destination: last.entry.center,
                                           mode: .driving, departureAt: time(0), kind: .fullLeg)
        run.revision += 1
        run.plan.places[0].name = "Updated name"
        XCTAssertTrue(ManualRouteEditing.apply(request: request, duration: .init(minimum: 600, maximum: 600), to: &run))
        XCTAssertEqual(run.plan.places[0].name, "Updated name")
        XCTAssertEqual(run.manualRouteEstimates.count, 1)
        XCTAssertTrue(ManualRouteEditing.apply(request: request, duration: nil, to: &run))
        XCTAssertTrue(run.manualRouteEstimates.isEmpty)
    }

    func testUnknownHistoricalCompletionDoesNotBecomeCurrentTime() {
        let current = place("Current")
        var run = trip([current])
        run.status = .completed
        run.completedAt = nil
        XCTAssertNil(TripScheduler.project(trip: run, now: time(60)).completion)
        XCTAssertNil(TripScheduler.project(trip: run, now: time(120)).completion)
        run.completedAt = time(30)
        XCTAssertEqual(TripScheduler.project(trip: run, now: time(120)).completion, time(30)...time(30))
    }

    func testUnknownTravelAfterLastDeadlineDoesNotHideValidLatestStart() {
        let appointment = place("Appointment", minutes: 5, requirement: .arriveBy)
        let later = place("Later", minutes: 5, longitude: -97.2)
        var run = trip([appointment, later], approach: 10)
        bind(appointment, at: 60, to: &run)
        run.plan.legs[1].manualDuration = nil
        let projection = TripScheduler.project(trip: run, now: time(0))
        XCTAssertEqual(projection.startBy, time(50))
        XCTAssertNil(projection.completion)
        XCTAssertTrue(projection.hasUnknownEstimates)
        XCTAssertEqual(projection.missingRoutes.first?.toPlaceID, later.id)
    }

    func testSavedLiveApproachCanBeEditedAtNewCurrentLocation() throws {
        let current = place("Current", longitude: -97.1)
        var run = trip([current])
        active(&run, place: current, at: 0, arrived: false)
        let earlierLocation = Point(latitude: 35.35, longitude: -97.4)
        let currentLocation = Point(latitude: 35.36, longitude: -97.3)
        run.manualRouteEstimates = [.init(source: earlierLocation, destination: current.entry.center,
                                          mode: .driving, duration: .init(minimum: 600, maximum: 720))]
        let request = try XCTUnwrap(ManualRouteContexts.requests(for: run).first)
        XCTAssertEqual(request.kind, .liveApproach)
        XCTAssertNil(request.fromPlaceID)
        XCTAssertTrue(ManualRouteEditing.apply(request: request, duration: .init(minimum: 300, maximum: 360),
                                               to: &run, liveOrigin: currentLocation))
        XCTAssertEqual(run.manualRouteEstimates.count, 1)
        XCTAssertEqual(run.manualRouteEstimates.first?.source, currentLocation)
        let projection = TripScheduler.project(trip: run, liveOrigin: currentLocation, now: time(0))
        XCTAssertEqual(projection.place(current.id)?.incomingSource, .manual)
        XCTAssertEqual(projection.place(current.id)?.arrival, time(5)...time(6))
        let editedRequest = try XCTUnwrap(ManualRouteContexts.requests(for: run).first)
        XCTAssertTrue(ManualRouteEditing.apply(request: editedRequest, duration: nil, to: &run, liveOrigin: currentLocation))
        XCTAssertTrue(run.manualRouteEstimates.isEmpty)
    }

    func testOldLiveManualEstimateDisappearsWhenItsApproachEnds() {
        let first = place("First", longitude: -97.1)
        let next = place("Next", longitude: -97.2)
        var run = trip([first, next])
        active(&run, place: first, at: 0, arrived: false)
        run.manualRouteEstimates = [.init(source: Point(latitude: 35.35, longitude: -97.4),
                                          destination: first.entry.center, mode: .driving,
                                          duration: .init(minimum: 600, maximum: 720))]
        XCTAssertEqual(ManualRouteContexts.requests(for: run).count, 1)
        run.phase = TripPhase(placeID: next.id, kind: .approaching, effectiveAt: time(10))
        XCTAssertTrue(ManualRouteContexts.requests(for: run).isEmpty)
        run.status = .scheduled
        run.phase = nil
        XCTAssertTrue(ManualRouteContexts.requests(for: run).isEmpty)
    }

    func testLiveManualEstimateAtTripOriginRetainsItsProvenance() throws {
        let first = place("First", longitude: -97.1)
        let next = place("Next", longitude: -97.2)
        var run = trip([first, next])
        active(&run, place: first, at: 0, arrived: false)
        let origin = try XCTUnwrap(run.origin)
        let live = RouteRequestContext(tripID: run.id, revision: run.revision, fromPlaceID: nil,
                                       toPlaceID: first.id, source: origin, destination: first.entry.center,
                                       mode: .driving, departureAt: time(0), kind: .liveApproach)
        XCTAssertTrue(ManualRouteEditing.apply(request: live, duration: .init(minimum: 600, maximum: 720),
                                               to: &run, liveOrigin: origin))
        XCTAssertEqual(run.manualRouteEstimates.first?.liveApproach, true)
        let reopened = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(ManualRouteContexts.requests(for: reopened).first?.kind, .liveApproach)
        run.phase = TripPhase(placeID: next.id, kind: .approaching, effectiveAt: time(10))
        XCTAssertTrue(ManualRouteContexts.requests(for: run).isEmpty)
    }
}
