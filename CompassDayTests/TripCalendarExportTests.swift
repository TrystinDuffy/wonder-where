import XCTest
@testable import CompassDay

final class TripCalendarExportTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_767_225_600) // January 1, 2026 UTC
    private func time(_ seconds: Int) -> Date { epoch.addingTimeInterval(Double(seconds)) }
    private func place(_ name: String = "Lunch", minimum: Int = 1_800, maximum: Int = 3_600) -> Place {
        let point = Point(name: name, latitude: 35.468, longitude: -97.516)
        return Place(name: name, entry: Area(name: "Entry", center: point, radiusMeters: 30),
                     explore: Area(name: "Explore", center: point, radiusMeters: 30),
                     exit: Area(name: "Exit", center: point, radiusMeters: 30),
                     duration: .init(minimum: minimum, maximum: maximum), address: "123 Main St, Oklahoma City")
    }
    private func trip(_ places: [Place]) -> Trip {
        var result = Trip(plan: Plan(name: "Our day", places: places), scheduledStart: epoch,
                          timeZoneIdentifier: "America/Chicago", origin: Point(name: "Home", latitude: 35.5, longitude: -97.6))
        for index in result.plan.legs.indices {
            result.plan.legs[index].manualDuration = .init(minimum: 600, maximum: 720)
        }
        return result
    }
    private func export(_ trip: Trip) throws -> TripCalendarExport.Document {
        try TripCalendarExport.make(trip: trip, projection: TripScheduler.project(trip: trip, now: epoch, adapt: false), generatedAt: epoch)
    }
    private func unfolded(_ data: Data) throws -> String {
        // RFC unfolding is a byte operation. Canonical string replacement can miss
        // the continuation space when a combining scalar follows that space.
        let bytes = [UInt8](data)
        var unfolded: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if index + 2 < bytes.count, bytes[index] == 13, bytes[index + 1] == 10,
               bytes[index + 2] == 32 || bytes[index + 2] == 9 {
                index += 3
            } else {
                unfolded.append(bytes[index])
                index += 1
            }
        }
        return try XCTUnwrap(String(data: Data(unfolded), encoding: .utf8))
    }
    private func events(_ data: Data) throws -> [String] {
        try unfolded(data).components(separatedBy: "BEGIN:VEVENT\r\n").dropFirst().map {
            $0.components(separatedBy: "END:VEVENT\r\n")[0]
        }
    }
    private func property(_ name: String, event: String) -> String? {
        event.components(separatedBy: "\r\n").first { $0.hasPrefix(name + ":") }.map { String($0.dropFirst(name.count + 1)) }
    }
    private func assertError(_ expected: String, _ action: () throws -> TripCalendarExport.Document,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertTrue($0.localizedDescription.localizedCaseInsensitiveContains(expected), $0.localizedDescription, file: file, line: line)
        }
    }

    func testConservativeTimesUseSameAllocationAndIncludeAppointmentWaiting() throws {
        var lunch = place()
        let appointment = TimeRequirement(kind: .appointment, label: "Lunch reservation")
        lunch.requirements = [appointment]
        lunch.instructions = ["Check in at the front desk", "Ask for the patio"]
        var run = trip([lunch])
        run.bindings[appointment.id] = time(3_600)
        run.allocations[lunch.id] = 2_117
        let original = run
        let document = try export(run)
        let entries = try events(document.data)
        XCTAssertEqual(document.eventCount, 2)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(property("DTSTART", event: entries[0]), "20260101T000000Z")
        XCTAssertNil(property("DTEND", event: entries[0]))
        XCTAssertEqual(property("DTSTART", event: entries[1]), "20260101T001200Z")
        XCTAssertEqual(property("DTEND", event: entries[1]), "20260101T013517Z")
        XCTAssertTrue(entries[1].contains("Allocated visit: 35 min 17 sec. Configured duration: 30 min–1 hr."))
        XCTAssertTrue(entries[1].contains("Appointment waiting before the visit budget begins: 48 min."))
        XCTAssertTrue(entries[1].contains("Appointment — Lunch reservation:"))
        XCTAssertTrue(entries[1].contains("1. Check in at the front desk\\n2. Ask for the patio"))
        XCTAssertTrue(entries[1].contains("URL:https://maps.apple.com/?ll=35.4680000,-97.5160000"))
        XCTAssertTrue(entries[1].contains("GEO:35.4680000;-97.5160000"))
        XCTAssertEqual(run, original, "Sharing cannot change the trip’s allocations or progress.")
        let attachment = XCTAttachment(data: document.data, uniformTypeIdentifier: "com.apple.ical.ics")
        attachment.name = "Trip calendar with appointment waiting.ics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSharedSnapshotMatchesCalendarEventsAndKeepsTripIdentity() throws {
        var lunch = place("Lunch")
        let requirement = TimeRequirement(kind: .appointment, label: "Reservation")
        lunch.requirements = [requirement]
        var run = trip([lunch, place("Walk")])
        run.revision = 7
        run.bindings[requirement.id] = time(3_600)
        run.allocations[lunch.id] = 2_117
        let original = run
        let projection = TripScheduler.project(trip: run, now: epoch, adapt: false)
        let snapshot = try TripCalendarExport.snapshot(trip: run, projection: projection, generatedAt: epoch)
        let document = try TripCalendarExport.make(trip: run, projection: projection, generatedAt: epoch)
        let entries = try events(document.data)
        XCTAssertEqual(snapshot.tripID, run.id)
        XCTAssertEqual(snapshot.revision, 7)
        XCTAssertEqual(snapshot.name, run.plan.name)
        XCTAssertEqual(snapshot.timeZoneIdentifier, "America/Chicago")
        XCTAssertEqual(snapshot.events.count, document.eventCount)
        XCTAssertEqual(snapshot.events.map(\.id), entries.compactMap { property("UID", event: $0) })
        XCTAssertEqual(snapshot.events.map(\.title), entries.compactMap { property("SUMMARY", event: $0) })
        XCTAssertEqual(snapshot.events[0].start, run.scheduledStart)
        XCTAssertNil(snapshot.events[0].end)
        XCTAssertEqual(snapshot.events[1].start, projection.place(lunch.id)?.arrival?.upperBound)
        XCTAssertEqual(snapshot.events[1].end, projection.place(lunch.id)?.exit?.upperBound)
        XCTAssertEqual(snapshot.events[1].location, lunch.address)
        XCTAssertEqual(snapshot.events[1].point, lunch.entry.center)
        XCTAssertEqual(snapshot.events[1].url?.absoluteString, property("URL", event: entries[1]))
        XCTAssertTrue(snapshot.events[1].notes.contains("Allocated visit: 35 min 17 sec."))
        XCTAssertTrue(snapshot.events[1].notes.contains("Appointment waiting before the visit budget begins: 48 min."))
        XCTAssertTrue(snapshot.events[1].notes.contains("Use Update Apple Calendar in WonderWhere"))
        XCTAssertTrue(snapshot.events[1].notes.contains("previously shared files do not update"))
        XCTAssertEqual(run, original)
    }

    func testDSTTransitionsExportAbsoluteUTCTimes() throws {
        let dates = ISO8601DateFormatter()
        let cases = [("2026-03-08T07:00:00Z", "20260308T073000Z", "20260308T090000Z"),
                     ("2026-11-01T06:00:00Z", "20261101T063000Z", "20261101T080000Z")]
        for (departure, arrival, exit) in cases {
            var run = trip([place(minimum: 5_400, maximum: 5_400)])
            run.scheduledStart = try XCTUnwrap(dates.date(from: departure))
            run.plan.legs[0].manualDuration = .init(minimum: 1_800, maximum: 1_800)
            let document = try export(run)
            let stop = try XCTUnwrap(events(document.data).last)
            XCTAssertEqual(property("DTSTART", event: stop), arrival)
            XCTAssertEqual(property("DTEND", event: stop), exit)
            XCTAssertFalse(stop.contains("TZID="))
            XCTAssertTrue(stop.contains("Trip time zone: America/Chicago"))
        }
    }

    func testCompletedVisitUsesActualHistoryAndDoesNotInventFutureAppointmentStart() throws {
        var lunch = place("Original lunch")
        let requirement = TimeRequirement(kind: .appointment, label: "Reservation")
        lunch.requirements = [requirement]
        lunch.instructions = ["Original instruction"]
        var run = trip([lunch])
        run.bindings[requirement.id] = time(3_600)
        run.status = .completed
        run.startedAt = time(-600)
        run.completedAt = time(600)
        run.visits[lunch.id] = VisitRecord(place: lunch, arrivedAt: time(0), budgetAnchor: time(3_600),
                                         departureRequestedAt: time(500), exitedAt: time(600), completed: true)
        run.plan.places[0].name = "Edited lunch"
        run.plan.places[0].instructions = ["New instruction"]
        let entries = try events(export(run).data)
        XCTAssertEqual(property("DTSTART", event: entries[0]), "20251231T235000Z")
        XCTAssertEqual(property("SUMMARY", event: entries[1]), "Original lunch")
        XCTAssertEqual(property("DTSTART", event: entries[1]), "20260101T000000Z")
        XCTAssertEqual(property("DTEND", event: entries[1]), "20260101T001000Z")
        XCTAssertTrue(entries[1].contains("Original instruction"))
        XCTAssertFalse(entries[1].contains("New instruction"))
        XCTAssertFalse(entries[1].contains("Appointment waiting before the visit budget begins"))
        XCTAssertTrue(entries[1].contains("recorded actual time"))
    }

    func testActiveVisitPreservesArrivalAndUsesProjectedExit() throws {
        let lunch = place()
        var run = trip([lunch])
        run.status = .active
        run.startedAt = time(-900)
        run.phase = TripPhase(placeID: lunch.id, kind: .exploring, effectiveAt: time(-600))
        run.visits[lunch.id] = VisitRecord(place: lunch, arrivedAt: time(-600), budgetAnchor: time(-600), budgetAnchorFrozen: true)
        let entries = try events(export(run).data)
        XCTAssertEqual(property("DTSTART", event: entries[1]), "20251231T235000Z")
        XCTAssertEqual(property("DTEND", event: entries[1]), "20260101T005000Z")
        XCTAssertTrue(entries[1].contains("upper schedule estimate"))
    }

    func testSkipsAndRemovalsDoNotExportOrRequireBindings() throws {
        let first = place("Kept")
        var skipped = place("Skipped")
        skipped.requirements = [.init(kind: .appointment, label: "Unbound skipped appointment")]
        let removed = place("Removed")
        var run = trip([first, skipped, removed])
        run.skippedPlaceIDs.insert(skipped.id)
        run.removedPlaceIDs.insert(removed.id)
        let document = try export(run)
        let text = try unfolded(document.data)
        XCTAssertEqual(document.eventCount, 2)
        XCTAssertTrue(text.contains("SUMMARY:Kept"))
        XCTAssertFalse(text.contains("SUMMARY:Skipped"))
        XCTAssertFalse(text.contains("SUMMARY:Removed"))
        XCTAssertTrue(text.contains("Place 1 of 1."))
    }

    func testStableUIDsRevisionEscapingAndUTF8FoldingPreventPropertyInjection() throws {
        let injected = "Dinner, dessert; \\ fun\r\nBEGIN:VEVENT\nATTENDEE:mailto:someone@example.com"
        var lunch = place(injected)
        lunch.instructions = [String(repeating: "漢e\u{301}𐐷", count: 40) + "\rX-INJECTED:yes"]
        var run = trip([lunch])
        run.plan.name = "Our/day\r\nVALARM:bad"
        run.revision = 9
        let first = try export(run)
        let physical = try XCTUnwrap(String(data: first.data, encoding: .utf8))
        XCTAssertTrue(physical.hasSuffix("END:VCALENDAR\r\n"))
        XCTAssertFalse(physical.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        for line in physical.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 75)
            XCTAssertNotNil(String(data: Data(line.utf8), encoding: .utf8))
        }
        let entries = try events(first.data)
        XCTAssertEqual(entries.count, 2)
        let summary = try XCTUnwrap(property("SUMMARY", event: entries[1]))
        XCTAssertEqual(summary, "Dinner\\, dessert\\; \\\\ fun\\nBEGIN:VEVENT\\nATTENDEE:mailto:someone@example.com")
        XCTAssertNil(property("ATTENDEE", event: entries[1]))
        XCTAssertNil(property("X-INJECTED", event: entries[1]))
        XCTAssertTrue(entries[1].contains(String(repeating: "漢e\u{301}𐐷", count: 40)))
        XCTAssertFalse(first.filename.contains("/"))
        XCTAssertFalse(first.filename.contains("\r"))
        XCTAssertTrue(first.filename.hasSuffix(".ics"))
        run.revision += 1
        run.plan.places[0].name = "Renamed lunch"
        let second = try events(export(run).data)
        XCTAssertEqual(entries.map { property("UID", event: $0) }, second.map { property("UID", event: $0) })
        XCTAssertTrue(entries.allSatisfy { property("SEQUENCE", event: $0) == "9" })
        XCTAssertTrue(second.allSatisfy { property("SEQUENCE", event: $0) == "10" })
        XCTAssertFalse(physical.contains("BEGIN:VALARM\r\n"))
        XCTAssertFalse(physical.contains("ORGANIZER:"))
        run.plan.name = String(repeating: "漢e\u{301}𐐷", count: 120)
        let longName = try export(run).filename
        XCTAssertLessThanOrEqual(longName.utf8.count, 184)
        XCTAssertTrue(longName.hasSuffix(".ics"))
        XCTAssertTrue(String(repeating: "漢e\u{301}𐐷", count: 120).hasPrefix(String(longName.dropLast(4))))
    }

    func testZeroDurationEventOmitsEndButPositiveAppointmentWaitDoesNot() throws {
        var stop = place("Quick stop", minimum: 0, maximum: 0)
        var run = trip([stop])
        let zero = try XCTUnwrap(events(export(run).data).last)
        XCTAssertEqual(property("DTSTART", event: zero), "20260101T001200Z")
        XCTAssertNil(property("DTEND", event: zero))
        let appointment = TimeRequirement(kind: .appointment, label: "Meet")
        stop.requirements = [appointment]
        run = trip([stop])
        run.bindings[appointment.id] = time(3_600)
        let wait = try XCTUnwrap(events(export(run).data).last)
        XCTAssertEqual(property("DTEND", event: wait), "20260101T010000Z")

        run.status = .completed
        run.startedAt = time(0)
        run.completedAt = time(720).addingTimeInterval(0.9)
        run.visits[stop.id] = VisitRecord(place: stop, arrivedAt: time(720).addingTimeInterval(0.1),
                                         exitedAt: time(720).addingTimeInterval(0.9), completed: true)
        let sameSecond = try XCTUnwrap(events(export(run).data).last)
        XCTAssertEqual(property("DTSTART", event: sameSecond), "20260101T001200Z")
        XCTAssertNil(property("DTEND", event: sameSecond), "Subsecond history must not produce equal DTSTART and DTEND or invent a longer visit.")
        let snapshot = try TripCalendarExport.snapshot(trip: run,
                                                       projection: TripScheduler.project(trip: run, now: epoch, adapt: false),
                                                       generatedAt: epoch)
        XCTAssertEqual(snapshot.events.last?.start, time(720).addingTimeInterval(0.1))
        XCTAssertEqual(snapshot.events.last?.end, time(720).addingTimeInterval(0.9),
                       "Apple Calendar receives the recorded fractions even when iCalendar files have whole-second precision.")
    }

    func testImpossibleConstraintIsSharedWithQuantifiedConflictNotClamped() throws {
        var lunch = place(minimum: 2_700, maximum: 3_600)
        let leave = TimeRequirement(kind: .leaveBy, label: "Leave for dinner")
        lunch.requirements = [leave]
        var run = trip([lunch])
        run.bindings[leave.id] = time(3_600)
        let entry = try XCTUnwrap(events(export(run).data).last)
        XCTAssertEqual(property("DTEND", event: entry), "20260101T011200Z")
        XCTAssertTrue(entry.contains("Schedule conflict: up to 12 min past this deadline."))
        XCTAssertTrue(entry.contains("Allocated visit: 1 hr. Configured duration: 45 min–1 hr."))
        XCTAssertTrue(entry.contains("Leave by — Leave for dinner:"))
    }

    func testUnavailableAndStaleSchedulesFailWithUsefulErrors() throws {
        var run = trip([place("Missing route")])
        run.plan.legs[0].manualDuration = nil
        assertError("Missing route") { try export(run) }
        run.plan.legs[0].manualDuration = .fiveMinutes
        let projection = TripScheduler.project(trip: run, now: epoch)
        run.revision += 1
        assertError("changed") { try TripCalendarExport.make(trip: run, projection: projection, generatedAt: epoch) }
        run.revision -= 1
        run.id = UUID()
        assertError("changed") { try TripCalendarExport.make(trip: run, projection: projection, generatedAt: epoch) }
        run.status = .canceled
        assertError("canceled") { try export(run) }
        run.status = .active
        assertError("actual departure") { try export(run) }
        run = trip([])
        assertError("included place") { try export(run) }
    }

    func testMissingBindingsUnknownHistoryAndInvalidChronologyAreNotFabricated() throws {
        var stop = place("Lunch")
        stop.requirements = [.init(kind: .arriveBy, label: "Lunch deadline")]
        var run = trip([stop])
        assertError("Lunch deadline") { try export(run) }
        run.bindings[stop.requirements[0].id] = time(1_000)
        run.status = .completed
        run.startedAt = time(-600)
        run.completedAt = time(3_600)
        run.visits[stop.id] = VisitRecord(place: stop, exitedAt: time(3_600), completed: true)
        assertError("Lunch") { try export(run) }
        run.visits[stop.id]?.arrivedAt = time(4_000)
        assertError("before its arrival") { try export(run) }
    }
}
