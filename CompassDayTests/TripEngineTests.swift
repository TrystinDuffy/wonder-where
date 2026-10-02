import XCTest
import CoreLocation
@testable import CompassDay

final class TripEngineTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func place(_ name: String = "Lunch", latitude: Double = 35.46, longitude: Double = -97.51) -> Place {
        Place(stop: Stop(name: name, latitude: latitude, longitude: longitude))
    }
    private func running(_ places: [Place]) -> Trip {
        var trip = Trip(plan: Plan(name: "Day", places: places), scheduledStart: instant)
        TripEngine.start(&trip, origin: nil, at: instant)
        return trip
    }
    private func sample(_ trip: Trip, point: Point, seconds: Double = 1, accuracy: Double = 5,
                        heading: Double = 0, headingAccuracy: Double = 5) -> LiveSample {
        LiveSample(area: Area(name: "Live", center: point, radiusMeters: accuracy), timestamp: instant.addingTimeInterval(seconds),
                   trueHeading: heading, headingAccuracy: headingAccuracy, headingTimestamp: instant,
                   sessionID: trip.trackingSessionID!)
    }
    private func arrive(_ trip: inout Trip, seconds: Double = 1) {
        let fix = sample(trip, point: trip.activePlace!.entry.center, seconds: seconds)
        XCTAssertTrue(TripEngine.receive(&trip, samples: [fix], sessionID: fix.sessionID, receivedAt: fix.timestamp))
    }

    func testStartIsExplicitAndIdempotent() {
        var trip = Trip(plan: Plan(name: "Day", places: [place()]), scheduledStart: instant)
        XCTAssertNil(trip.phase)
        XCTAssertNil(trip.startedAt)
        XCTAssertFalse(TripEngine.tick(&trip, at: instant))
        XCTAssertTrue(TripEngine.start(&trip, origin: nil, at: instant))
        let saved = trip
        XCTAssertFalse(TripEngine.start(&trip, origin: nil, at: instant.addingTimeInterval(100)))
        XCTAssertEqual(saved, trip)
    }

    func testStartDoesNotMistakePreviewOriginForActualStartingPoint() {
        let preview = Point(latitude: 35, longitude: -97)
        let actual = Point(latitude: 36, longitude: -96)
        var withoutGPS = Trip(plan: Plan(name: "Day", places: [place()]), scheduledStart: instant, origin: preview)
        TripEngine.start(&withoutGPS, origin: nil, at: instant)
        XCTAssertNil(withoutGPS.origin)
        var withGPS = Trip(plan: Plan(name: "Day", places: [place()]), scheduledStart: instant, origin: preview)
        TripEngine.start(&withGPS, origin: actual, at: instant)
        XCTAssertEqual(withGPS.origin, actual)
    }

    func testBatchRecordsObservedEntryBeforeOvershootWithoutAdvancing() {
        let target = place()
        var trip = running([target, place("Dinner", latitude: 36)])
        let inside = sample(trip, point: target.entry.center, seconds: 1)
        let outside = sample(trip, point: Point(latitude: 35.48, longitude: -97.51), seconds: 2)
        XCTAssertTrue(TripEngine.receive(&trip, samples: [outside, inside], sessionID: inside.sessionID, receivedAt: instant.addingTimeInterval(5)))
        XCTAssertEqual(trip.visits[target.id]?.arrivedAt, inside.timestamp)
        XCTAssertEqual(trip.activePlaceID, target.id)
        XCTAssertEqual(trip.phase?.kind, .exploring)
        if case .direction = TripNavigation.guidance(trip: trip, sample: outside, now: outside.timestamp) {} else { XCTFail("Overshoot must restore guidance") }
        XCTAssertFalse(TripEngine.receive(&trip, samples: [inside], sessionID: inside.sessionID, receivedAt: instant.addingTimeInterval(6)))
    }

    func testSparsePathCrossingDoesNotInventArrival() {
        let target = place()
        var trip = running([target])
        let before = sample(trip, point: Point(latitude: 35.45, longitude: -97.51), seconds: 1)
        let after = sample(trip, point: Point(latitude: 35.47, longitude: -97.51), seconds: 2)
        XCTAssertFalse(TripEngine.receive(&trip, samples: [before, after], sessionID: before.sessionID, receivedAt: after.timestamp))
        XCTAssertNil(trip.activeVisit)
    }

    func testExploringExitAndRepeatedNextAreDifferentPhases() {
        var first = place(), second = place("Second", latitude: 35.48)
        first.exit.center.latitude += 0.002
        second.exit.center.latitude += 0.002
        var trip = running([first, second])
        arrive(&trip)
        let command = trip.phase!
        XCTAssertTrue(TripEngine.next(&trip, expected: command, at: instant.addingTimeInterval(2)))
        XCTAssertEqual(trip.phase?.kind, .exiting)
        XCTAssertFalse(TripEngine.next(&trip, expected: command, at: instant.addingTimeInterval(3)))
        let oldExitObservation = sample(trip, point: first.exit.center, seconds: 1.5)
        XCTAssertFalse(TripEngine.receive(&trip, samples: [oldExitObservation], sessionID: oldExitObservation.sessionID, receivedAt: instant.addingTimeInterval(4)))
        let exit = sample(trip, point: first.exit.center, seconds: 4)
        XCTAssertTrue(TripEngine.receive(&trip, samples: [exit], sessionID: exit.sessionID, receivedAt: exit.timestamp))
        XCTAssertEqual(trip.activePlaceID, second.id)
        XCTAssertEqual(trip.visits[first.id]?.exitedAt, exit.timestamp)
        XCTAssertFalse(TripEngine.next(&trip, expected: command, at: instant.addingTimeInterval(5)))
        XCTAssertEqual(trip.activePlaceID, second.id)
    }

    func testNextAtExitCompletesImmediatelyAndStopsTracking() {
        let target = place()
        var trip = running([target])
        arrive(&trip)
        let fix = sample(trip, point: target.exit.center, seconds: 2)
        XCTAssertTrue(TripEngine.next(&trip, expected: trip.phase!, at: fix.timestamp, sample: fix))
        XCTAssertEqual(trip.status, .completed)
        XCTAssertNil(trip.phase)
        XCTAssertNil(trip.trackingSessionID)
        XCTAssertEqual(trip.visits[target.id]?.exitedAt, fix.timestamp)
    }

    func testExitEditCannotUseObservationFromBeforeTheEdit() {
        var target = place()
        var trip = running([target])
        arrive(&trip)
        let oldFix = sample(trip, point: target.exit.center, seconds: 2)
        let originalToken = trip.phase!
        target.exit.radiusMeters += 5
        TripEngine.upsert(&trip, place: target, at: instant.addingTimeInterval(5))
        XCTAssertNotEqual(trip.phase?.id, originalToken.id)
        XCTAssertFalse(TripEngine.next(&trip, expected: originalToken, at: instant.addingTimeInterval(6), sample: oldFix))
        XCTAssertTrue(TripEngine.next(&trip, expected: trip.phase!, at: instant.addingTimeInterval(6), sample: oldFix))
        XCTAssertEqual(trip.phase?.kind, .exiting)
        XCTAssertNil(trip.visits[target.id]?.exitedAt)
        let fresh = sample(trip, point: target.exit.center, seconds: 7)
        TripEngine.receive(&trip, samples: [fresh], sessionID: fresh.sessionID, receivedAt: fresh.timestamp)
        XCTAssertEqual(trip.status, .completed)
    }

    func testCachedPositionRelabeledWithNewSessionCannotConfirmExitOrGuide() {
        let target = place()
        var trip = running([target])
        arrive(&trip)
        var cached = sample(trip, point: target.exit.center, seconds: 2)
        let session = TripEngine.beginTracking(&trip, at: instant.addingTimeInterval(10))
        // The UI combines current session identity with the service's last stored fix.
        cached.sessionID = session
        XCTAssertEqual(TripNavigation.guidance(trip: trip, sample: cached, now: instant.addingTimeInterval(11)), .searching)
        XCTAssertTrue(TripEngine.next(&trip, expected: trip.phase!, at: instant.addingTimeInterval(11), sample: cached))
        XCTAssertEqual(trip.phase?.kind, .exiting)
        let fresh = sample(trip, point: target.exit.center, seconds: 12)
        TripEngine.receive(&trip, samples: [fresh], sessionID: session, receivedAt: fresh.timestamp)
        XCTAssertEqual(trip.status, .completed)
    }

    func testEntryAndExploreCentersAreIndependent() {
        var target = place()
        target.explore.center.latitude += 0.005
        var trip = running([target])
        arrive(&trip)
        let fix = sample(trip, point: target.entry.center)
        XCTAssertEqual(trip.currentTargetArea, target.explore)
        if case .direction = TripNavigation.guidance(trip: trip, sample: fix, now: fix.timestamp) {} else { XCTFail("Entry arrival should guide to separate Explore") }
    }

    func testGeometryEditKeepsFactsAndRejectsObservationsPredatingEdit() {
        var target = place()
        var trip = running([target])
        arrive(&trip)
        let observed = trip.activeVisit!
        target.entry.center.latitude += 0.01
        target.explore.center.latitude += 0.01
        TripEngine.upsert(&trip, place: target, at: instant.addingTimeInterval(10))
        XCTAssertEqual(trip.activeVisit, observed)
        XCTAssertEqual(trip.currentTargetArea, target.explore)
        XCTAssertEqual(trip.phase?.effectiveAt, instant.addingTimeInterval(10))
        let next = place("Next", latitude: 36)
        var pending = running([next])
        var edited = next; edited.entry.center.latitude = 37
        let staleTargetFix = sample(pending, point: edited.entry.center, seconds: 2)
        TripEngine.upsert(&pending, place: edited, at: instant.addingTimeInterval(5))
        XCTAssertFalse(TripEngine.receive(&pending, samples: [staleTargetFix], sessionID: staleTargetFix.sessionID, receivedAt: instant.addingTimeInterval(6)))
        XCTAssertNil(pending.activeVisit)
    }

    func testRemoveActiveRetainsSnapshotAndFindsAllPendingPlaces() {
        let first = place(), second = place("Second"), third = place("Third")
        var trip = running([first, second, third])
        arrive(&trip)
        TripEngine.reorder(&trip, ids: [third.id, first.id, second.id], at: instant.addingTimeInterval(2))
        XCTAssertEqual(trip.plan.places.map(\.id), [first.id, third.id, second.id])
        XCTAssertTrue(TripEngine.delete(&trip, placeID: first.id, at: instant.addingTimeInterval(3)))
        XCTAssertEqual(trip.activePlaceID, third.id)
        XCTAssertEqual(trip.visits[first.id]?.place, first)
        XCTAssertNotNil(trip.visits[first.id]?.removedAt)
        XCTAssertEqual(trip.status, .active)
    }

    func testEarlyAppointmentDepartureHasNoFutureBudgetStart() {
        var target = place()
        let requirement = TimeRequirement(kind: .appointment, label: "Lunch time")
        target.requirements = [requirement]
        var trip = running([target])
        TripEngine.editBinding(&trip, requirementID: requirement.id, date: instant.addingTimeInterval(3600), at: instant)
        arrive(&trip, seconds: 0)
        XCTAssertEqual(trip.activeVisit?.budgetElapsed(at: instant.addingTimeInterval(300)), 0)
        TripEngine.next(&trip, expected: trip.phase!, at: instant.addingTimeInterval(600))
        TripEngine.confirm(&trip, expected: trip.phase!, at: instant.addingTimeInterval(600))
        XCTAssertEqual(trip.visits[target.id]?.arrivedAt, instant)
        XCTAssertNil(trip.visits[target.id]?.budgetAnchor)
        XCTAssertEqual(trip.visits[target.id]?.exitedAt, instant.addingTimeInterval(600))
    }

    func testFutureAppointmentCanMoveButBudgetFreezesWhenItBegins() {
        var target = place()
        let requirement = TimeRequirement(kind: .appointment, label: "Appointment")
        target.requirements = [requirement]
        var trip = running([target])
        TripEngine.editBinding(&trip, requirementID: requirement.id, date: instant.addingTimeInterval(300), at: instant)
        arrive(&trip)
        TripEngine.editBinding(&trip, requirementID: requirement.id, date: instant.addingTimeInterval(600), at: instant.addingTimeInterval(100))
        XCTAssertEqual(trip.activeVisit?.budgetAnchor, instant.addingTimeInterval(600))
        TripEngine.tick(&trip, at: instant.addingTimeInterval(700))
        TripEngine.editBinding(&trip, requirementID: requirement.id, date: instant.addingTimeInterval(900), at: instant.addingTimeInterval(700))
        XCTAssertEqual(trip.activeVisit?.budgetAnchor, instant.addingTimeInterval(600))
        XCTAssertEqual(trip.activeVisit?.budgetElapsed(at: instant.addingTimeInterval(700)), 100)
    }

    func testSmallArrivalRadiusDoesNotSuppressDistantGuidance() {
        var target = place(latitude: 35.475)
        target.entry.radiusMeters = 9.144
        let trip = running([target])
        let fix = sample(trip, point: Point(latitude: 35.46, longitude: -97.51), accuracy: 304.8)
        if case .direction(let degrees, let distance) = TripNavigation.guidance(trip: trip, sample: fix, now: fix.timestamp) {
            XCTAssertEqual(degrees, 0, accuracy: 0.01)
            XCTAssertGreaterThan(distance, 1600)
        } else { XCTFail("A mile-away destination has a reliable bearing with 1,000 feet of uncertainty") }
        var broad = fix; broad.area.radiusMeters = 2000
        XCTAssertEqual(TripNavigation.guidance(trip: trip, sample: broad, now: broad.timestamp), .searching)
    }

    func testStationaryHeadingAndInvalidRecovery() {
        let target = place(latitude: 35.48)
        let trip = running([target])
        var fix = sample(trip, point: Point(latitude: 35.46, longitude: -97.51), seconds: 3600)
        // The unchanged heading still belongs to the live session; location is fresh.
        if case .direction = TripNavigation.guidance(trip: trip, sample: fix, now: fix.timestamp) {} else { XCTFail("Do not expire an unchanged heading in an active session") }
        fix.headingAvailable = false
        XCTAssertEqual(TripNavigation.guidance(trip: trip, sample: fix, now: fix.timestamp), .searching)
        fix.headingAvailable = true
        fix.trueHeading = 90
        if case .direction(let degrees, _) = TripNavigation.guidance(trip: trip, sample: fix, now: fix.timestamp) {
            XCTAssertEqual(degrees, 270, accuracy: 0.01)
        } else { XCTFail("A fresh valid heading must recover guidance") }
        XCTAssertEqual(TripNavigation.guidance(trip: trip, sample: fix, now: fix.timestamp.addingTimeInterval(20)), .searching)
    }

    func testNewTrackingSessionRejectsCachedLocationAndHeading() {
        let target = place()
        var trip = running([target])
        let old = sample(trip, point: target.entry.center)
        let newSession = TripEngine.beginTracking(&trip, at: instant.addingTimeInterval(100))
        XCTAssertFalse(TripEngine.receive(&trip, samples: [old], sessionID: newSession, receivedAt: instant.addingTimeInterval(101)))
        XCTAssertNil(trip.activeVisit)
    }

    func testSensorsWithoutTransitionsDoNotCreateDurableRevisions() {
        let target = place()
        var trip = running([target])
        let revision = trip.revision
        for second in 1...60 {
            let fix = sample(trip, point: Point(latitude: 35.4, longitude: -97.5), seconds: Double(second))
            XCTAssertFalse(TripEngine.receive(&trip, samples: [fix], sessionID: fix.sessionID, receivedAt: fix.timestamp))
        }
        XCTAssertEqual(trip.revision, revision)
        XCTAssertNil(trip.lastObservedAt)
    }

    func testMigrationPreservesUnknownHistoryAndTemplateIsParametric() throws {
        let first = Stop(name: "Lunch", latitude: 35.46, longitude: -97.51, hint: "A hint", instructions: ["First", "Second"], durationMinutes: 15)
        let second = Stop(name: "Dinner", latitude: 35.48, longitude: -97.51, arriveBy: instant.addingTimeInterval(3600))
        let legacy = Itinerary(stops: [first, second], activeID: second.id, startedAt: instant,
                               visits: [first.id.uuidString: StopVisit(completed: true)])
        let result = try TripRepository.migrate(legacy, now: instant)
        let trip = try XCTUnwrap(result.selectedTrip)
        XCTAssertEqual(trip.activePlaceID, second.id)
        XCTAssertNil(trip.visits[first.id]?.arrivedAt)
        XCTAssertNil(trip.visits[first.id]?.exitedAt)
        XCTAssertEqual(trip.visits[first.id]?.place.instructions, ["First", "Second"])
        XCTAssertEqual(trip.plan.places[0].duration, DurationRange(minimum: 900, maximum: 900))
        XCTAssertEqual(trip.plan.places[1].requirements.count, 1)
        XCTAssertEqual(trip.bindings.values.first, second.arriveBy)
        XCTAssertNotEqual(trip.plan.places[0].entry.id, trip.plan.places[0].explore.id)
        XCTAssertEqual(trip.plan.places[0].entry.center, trip.plan.places[0].exit.center)
        var changed = trip
        changed.plan.places[0].name = "New lunch"
        XCTAssertEqual(result.plans[0].places[0].name, "Lunch")
    }

    func testRepositoryBacksUpOriginalAndRejectsStaleWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacyFile = folder.appendingPathComponent("itinerary.json")
        let original = try JSONEncoder().encode(Itinerary(stops: [place().stop]))
        try original.write(to: legacyFile)
        let repository = TripRepository(directory: folder)
        var library = try await repository.load()
        XCTAssertEqual(try Data(contentsOf: legacyFile), original)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("itinerary.pre-library-migration.json")), original)
        let old = library
        library.revision += 1
        library.plans[0].name = "Updated"
        try await repository.save(library)
        do {
            try await repository.save(old)
            XCTFail("An old async write must not overwrite a new revision")
        } catch TripRepositoryError.staleRevision { }
        let reopened = try await TripRepository(directory: folder).load()
        XCTAssertEqual(reopened, library)
    }

    func testDeletingReusablePlanPreservesAllTripSnapshotsAndAllowsExplicitRecreation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var target = place()
        target.hint = "A saved hint"
        target.instructions = ["Take a photo"]
        var source = Plan(name: "Reusable day", places: [target])
        source.reconcileLegs()
        let retained = Plan(name: "Another plan", places: [place("Park")])
        let scheduled = Trip(sourcePlanID: source.id, plan: source, scheduledStart: instant)
        var active = Trip(sourcePlanID: source.id, plan: source, scheduledStart: instant)
        TripEngine.start(&active, origin: nil, at: instant)
        TripEngine.confirm(&active, expected: active.phase!, at: instant.addingTimeInterval(1))
        var past = Trip(sourcePlanID: source.id, plan: source, scheduledStart: instant)
        TripEngine.start(&past, origin: nil, at: instant)
        TripEngine.confirm(&past, expected: past.phase!, at: instant.addingTimeInterval(1))
        TripEngine.next(&past, expected: past.phase!, at: instant.addingTimeInterval(300))
        TripEngine.confirm(&past, expected: past.phase!, at: instant.addingTimeInterval(301))
        XCTAssertEqual(past.status, .completed)
        let snapshots = [scheduled, active, past]
        let repository = TripRepository(directory: folder)
        var library = TripLibrary(revision: 1, plans: [source, retained], trips: snapshots, selectedTripID: active.id)
        try await repository.save(library)

        library.plans.removeAll { $0.id == source.id }
        library.revision += 1
        try await repository.save(library)
        var reopened = try await TripRepository(directory: folder).load()

        XCTAssertEqual(reopened.plans, [retained])
        XCTAssertEqual(reopened.trips, snapshots)
        XCTAssertEqual(reopened.selectedTripID, active.id)
        XCTAssertEqual(reopened.activeTrip, active)
        XCTAssertEqual(reopened.trips.last?.visits[target.id], past.visits[target.id])
        let recreated = reopened.selectedTrip!.reusablePlan(id: source.id)
        reopened.plans.append(recreated)
        reopened.revision += 1
        try await repository.save(reopened)
        let restored = try await TripRepository(directory: folder).load()
        XCTAssertEqual(restored.plans.first { $0.id == source.id }, source)
        XCTAssertEqual(restored.trips, snapshots)
    }

    func testRecordedStateRoundTripsAcrossRelaunch() throws {
        let target = place()
        var trip = running([target])
        arrive(&trip)
        TripEngine.next(&trip, expected: trip.phase!, at: instant.addingTimeInterval(3))
        let restored = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(trip))
        XCTAssertEqual(restored, trip)
        XCTAssertEqual(restored.phase?.kind, .exiting)
        XCTAssertEqual(restored.activeVisit?.arrivedAt, instant.addingTimeInterval(1))
        XCTAssertEqual(restored.activeVisit?.departureRequestedAt, instant.addingTimeInterval(3))
    }
    func testEnablingSharedAreasFromOldEditorUsesLatestUntouchedEntry() {
        var original = place()
        original.setUsesEntryForAllAreas(false)
        original.explore.center.latitude += 0.01
        original.exit.radiusMeters *= 2
        var draft = original
        draft.setUsesEntryForAllAreas(true)
        draft.name = "Our lunch"
        var current = original
        current.entry.center.longitude += 0.02
        current.entry.radiusMeters = 120
        current.hint = "A newer hint"

        let merged = current.applyingChanges(from: original, draft: draft)

        XCTAssertTrue(merged.usesEntryForAllAreas)
        XCTAssertEqual(merged.entry, current.entry)
        XCTAssertEqual(merged.explore.center, current.entry.center)
        XCTAssertEqual(merged.exit.center, current.entry.center)
        XCTAssertEqual(merged.explore.radiusMeters, current.entry.radiusMeters)
        XCTAssertEqual(merged.exit.radiusMeters, current.entry.radiusMeters)
        XCTAssertEqual(merged.explore.id, current.explore.id)
        XCTAssertEqual(merged.exit.id, current.exit.id)
        XCTAssertEqual(merged.name, "Our lunch")
        XCTAssertEqual(merged.hint, "A newer hint")
    }

    func testOldSeparateAreaEditCannotBreakNewerSharedGeometry() {
        var original = place()
        original.setUsesEntryForAllAreas(false)
        original.explore.radiusMeters *= 2
        var draft = original
        draft.explore.center.latitude += 0.03
        draft.explore.radiusMeters = 1000
        draft.instructions = ["Take a photo"]
        var current = original
        current.entry.center.longitude += 0.02
        current.entry.radiusMeters = 75
        current.setUsesEntryForAllAreas(true)

        let merged = current.applyingChanges(from: original, draft: draft)

        XCTAssertTrue(merged.usesEntryForAllAreas)
        XCTAssertEqual(merged.sharedEntryArea, true)
        XCTAssertEqual(merged.entry, current.entry)
        XCTAssertEqual(merged.explore, current.explore)
        XCTAssertEqual(merged.exit, current.exit)
        XCTAssertEqual(merged.instructions, ["Take a photo"])
    }

    func testSharedAreasRememberExplicitSeparationAndPreserveAreaIdentities() throws {
        var target = place()
        XCTAssertTrue(target.usesEntryForAllAreas)
        let identities = [target.entry.id, target.explore.id, target.exit.id]
        target.setUsesEntryForAllAreas(false)
        let restored = try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(target))
        XCTAssertFalse(restored.usesEntryForAllAreas, "Separate controls must remain available even at matching coordinates")
        target.explore.radiusMeters = 25 * 1609.344
        target.exit.center.latitude += 0.02
        target.setUsesEntryForAllAreas(true)
        XCTAssertTrue(target.usesEntryForAllAreas)
        XCTAssertEqual(target.explore.center, target.entry.center)
        XCTAssertEqual(target.exit.radiusMeters, target.entry.radiusMeters)
        XCTAssertEqual([target.entry.id, target.explore.id, target.exit.id], identities)
        target.entry.radiusMeters = 10 * 1609.344
        target.copyEntryGeometryToOtherAreas()
        XCTAssertEqual(target.explore.radiusMeters, target.entry.radiusMeters)
    }

    func testExistingPlacesInferSharedAreaSettingWithoutChangingSeparateGeometry() throws {
        var target = place()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as! [String: Any]
        json.removeValue(forKey: "sharedEntryArea")
        let restored = try JSONDecoder().decode(Place.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(restored.usesEntryForAllAreas)
        target.explore.radiusMeters = 25 * 1609.344
        XCTAssertFalse(target.usesEntryForAllAreas)
        let separate = try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(target))
        XCTAssertFalse(separate.usesEntryForAllAreas)
        XCTAssertEqual(separate.explore.radiusMeters, target.explore.radiusMeters)
    }

    func testCitySizedExploreAreaPreservesSmallEntryAndSurvivesRelaunch() throws {
        var target = place()
        target.setUsesEntryForAllAreas(false)
        target.explore.radiusMeters = 25 * 1609.344
        XCTAssertTrue(target.isValid)
        XCTAssertTrue(target.stop.isValid)
        var trip = running([target])
        arrive(&trip)
        let cityFix = sample(trip, point: Point(latitude: 35.5, longitude: -97.51), seconds: 2)
        XCTAssertFalse(target.entry.contains(cityFix.point))
        XCTAssertTrue(target.explore.contains(cityFix.point))
        XCTAssertEqual(TripNavigation.guidance(trip: trip, sample: cityFix, now: cityFix.timestamp), .arrived)
        let restored = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(trip))
        XCTAssertEqual(restored.plan.places[0].explore.radiusMeters, 25 * 1609.344)
        XCTAssertEqual(restored.plan.places[0].entry.radiusMeters, 100 * 0.3048)
        var huge = target.entry
        huge.radiusMeters = 1e100
        XCTAssertTrue(huge.isValid)
        XCTAssertFalse(huge.radiusLabel.isEmpty, "Formatting does not narrow an unrestricted radius to Int")
    }

}
