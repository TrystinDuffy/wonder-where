import XCTest
@testable import CompassDay

final class TripAppleCalendarTests: XCTestCase {
    private let departure = Date(timeIntervalSince1970: 1_767_225_600)
    private func snapshot(id: UUID = UUID(), revision: Int = 1, includeLunch: Bool = true,
                          delay: TimeInterval = 0) -> TripCalendarExport.Snapshot {
        var events = [TripCalendarExport.Event(id: "departure", title: "Depart — Our day", start: departure.addingTimeInterval(delay),
                                               end: nil, notes: "Static calendar snapshot; changes in Compass Day do not update this calendar.",
                                               location: "Home", point: Point(name: "Home", latitude: 35.5, longitude: -97.6),
                                               url: URL(string: "https://maps.apple.com/?ll=35.5,-97.6"))]
        if includeLunch {
            events.append(.init(id: "lunch", title: "Lunch", start: departure.addingTimeInterval(600 + delay),
                                end: departure.addingTimeInterval(4_200 + delay), notes: "1. Check in\n2. Ask for the patio",
                                location: "123 Main St", point: Point(latitude: 35.4, longitude: -97.5),
                                url: URL(string: "https://maps.apple.com/?ll=35.4,-97.5")))
        }
        return .init(tripID: id, revision: revision, name: "Our day", timeZoneIdentifier: "America/Chicago", events: events)
    }
    private func create(_ service: TripAppleCalendarService, _ value: TripCalendarExport.Snapshot) async throws -> TripAppleCalendarService.Connection {
        try await service.synchronize(snapshot: value, accountID: "account", calendarName: value.name)
    }
    private func errorContains(_ needle: String, action: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected an error containing \(needle)", file: file, line: line) }
        catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(needle), error.localizedDescription, file: file, line: line) }
    }

    func testCreateAndExplicitUpdateReuseCalendarAndEventIdentitiesAfterRelaunch() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        let first = try await create(service, value)
        let initialIDs = Set(backend.savedEvents.keys)
        XCTAssertEqual(first.eventCount, 2)
        XCTAssertEqual(backend.savedCalendars.count, 1)
        XCTAssertTrue(backend.savedDetails.values.allSatisfy { $0.timeZone == "America/Chicago" })
        XCTAssertEqual(backend.savedDetails.values.first { $0.event.id == "lunch" }?.event.url, value.events[1].url)
        XCTAssertTrue(backend.savedEvents.values.allSatisfy { $0.notes?.contains("does not update automatically") == true || $0.notes?.contains("Check in") == true })
        let relaunched = TripAppleCalendarService(backend: backend, persistence: storage)
        let second = try await create(relaunched, snapshot(id: value.tripID, revision: 2, delay: 7_200))
        XCTAssertEqual(first.calendarID, second.calendarID)
        XCTAssertEqual(Set(backend.savedEvents.keys), initialIDs)
        XCTAssertEqual(backend.createCount, 1)
        XCTAssertEqual(backend.savedDetails.values.first { $0.event.id == "lunch" }?.event.start, departure.addingTimeInterval(7_800))
        XCTAssertFalse(second.pending)
    }

    func testSkippingRemovesOnlyOwnedEventsAndPreservesManuallyAddedEvents() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        let connection = try await create(service, value)
        backend.savedEvents["personal"] = .init(id: "personal", calendarID: connection.calendarID, notes: "Added in Calendar", start: departure)
        let updated = try await create(service, snapshot(id: value.tripID, revision: 2, includeLunch: false))
        XCTAssertEqual(updated.eventCount, 1)
        XCTAssertEqual(backend.savedEvents.count, 2)
        XCTAssertEqual(backend.savedEvents["personal"]?.notes, "Added in Calendar")
        XCTAssertEqual(backend.removedCount, 1)
    }

    func testReceiptFailureBeforeEventKitCommitLeavesCalendarUntouched() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        storage.failOnSave = [1]
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        await errorContains("connection") { _ = try await self.create(service, value) }
        XCTAssertTrue(backend.savedCalendars.isEmpty)
        XCTAssertTrue(backend.savedEvents.isEmpty)
        XCTAssertEqual(backend.commitCount, 0)
        XCTAssertEqual(backend.resetCount, 1)
        storage.failOnSave = []
        _ = try await create(service, value)
        XCTAssertEqual(backend.savedCalendars.count, 1)
        XCTAssertEqual(backend.savedEvents.count, 2)
    }

    func testFailedFinalReceiptRecoversCommittedEventsWithoutDuplicates() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        storage.failOnSave = [2]
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        await errorContains("connection") { _ = try await self.create(service, value) }
        let firstIDs = Set(backend.savedEvents.keys)
        XCTAssertEqual(firstIDs.count, 2)
        XCTAssertEqual(storage.manifest.links[value.tripID.uuidString]?.pending, true)
        let relaunched = TripAppleCalendarService(backend: backend, persistence: storage)
        let inspected = try await relaunched.inspect(tripID: value.tripID)
        XCTAssertTrue(inspected.connection?.pending == true)
        let result = try await create(relaunched, value)
        XCTAssertFalse(result.pending)
        XCTAssertEqual(Set(backend.savedEvents.keys), firstIDs)
        XCTAssertEqual(backend.createCount, 1)
    }

    func testUncertainCommitResultRecoversCalendarInsteadOfCreatingAnother() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        backend.failCommitAfterSaving = true
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        await errorContains("Calendar could not save") { _ = try await self.create(service, value) }
        let calendarID = try XCTUnwrap(backend.savedCalendars.keys.first)
        XCTAssertEqual(storage.manifest.links[value.tripID.uuidString]?.pending, true)
        backend.failCommitAfterSaving = false
        let result = try await create(TripAppleCalendarService(backend: backend, persistence: storage), value)
        XCTAssertEqual(result.calendarID, calendarID)
        XCTAssertEqual(backend.createCount, 1)
        XCTAssertEqual(backend.savedEvents.count, 2)
    }

    func testFailedCommitWithNoCalendarRequiresExplicitRecreation() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        backend.failCommitBeforeSaving = true
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        await errorContains("Calendar could not save") { _ = try await self.create(service, value) }
        XCTAssertTrue(backend.savedCalendars.isEmpty)
        backend.failCommitBeforeSaving = false
        await errorContains("Recreate") { _ = try await self.create(service, value) }
        XCTAssertEqual(backend.createCount, 1)
        let overview = try await service.inspect(tripID: value.tripID)
        XCTAssertTrue(overview.calendarMissing)
        _ = try await service.synchronize(snapshot: value, accountID: "account", calendarName: value.name, recreateMissing: true)
        XCTAssertEqual(backend.savedCalendars.count, 1)
    }

    func testPartialStagingFailureResetsAllChangesToExistingCalendar() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        let connection = try await create(service, value)
        let originalStarts = backend.savedEvents.mapValues(\.start)
        backend.failOnEventSave = backend.saveCount + 2
        await errorContains("Calendar could not save") {
            _ = try await service.synchronize(snapshot: self.snapshot(id: value.tripID, revision: 2, delay: 8_000),
                                              accountID: "account", calendarName: "Changed name")
        }
        XCTAssertEqual(backend.savedEvents.mapValues(\.start), originalStarts)
        XCTAssertEqual(backend.savedCalendars[connection.calendarID]?.name, value.name)
        XCTAssertEqual(storage.manifest.links[value.tripID.uuidString]?.revision, 1)
        XCTAssertEqual(backend.resetCount, 1)
    }

    func testAccountSyncIdentifierChangesRecoverByOwnedMarkers() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        let initial = try await create(service, value)
        var replacement = try XCTUnwrap(backend.savedCalendars.removeValue(forKey: initial.calendarID))
        replacement.id = "synced-calendar"
        backend.savedCalendars[replacement.id] = replacement
        let originals = backend.savedEvents
        backend.savedEvents = [:]
        for (id, original) in originals {
            var event = original
            event.id = "synced-\(id)"
            event.calendarID = replacement.id
            backend.savedEvents[event.id] = event
        }
        let result = try await create(TripAppleCalendarService(backend: backend, persistence: storage), value)
        XCTAssertEqual(result.calendarID, replacement.id)
        XCTAssertEqual(backend.savedEvents.count, 2)
        XCTAssertEqual(backend.createCount, 1)
    }

    func testDeletingCalendarDoesNotSilentlyCreateReplacement() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        let first = try await create(service, value)
        backend.savedCalendars = [:]
        backend.savedEvents = [:]
        await errorContains("Recreate") { _ = try await self.create(service, value) }
        XCTAssertEqual(backend.createCount, 1)
        let replacement = try await service.synchronize(snapshot: value, accountID: "account", calendarName: "New calendar", recreateMissing: true)
        XCTAssertNotEqual(first.calendarID, replacement.calendarID)
        XCTAssertEqual(replacement.name, "New calendar")
    }

    func testPermissionDenialAndRevocationDoNotQueryOrModifyCalendarData() async throws {
        for authorization in [TripAppleCalendarService.Authorization.notDetermined, .denied, .restricted, .writeOnly] {
            let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
            backend.authorization = authorization
            let service = TripAppleCalendarService(backend: backend, persistence: storage)
            let overview = try await service.inspect(tripID: value.tripID)
            XCTAssertEqual(overview.authorization, authorization)
            XCTAssertTrue(overview.accounts.isEmpty)
            XCTAssertFalse(overview.calendarMissing)
            await errorContains("full Calendar access") { _ = try await self.create(service, value) }
            XCTAssertEqual(backend.queryCount, 0)
            XCTAssertEqual(backend.createCount, 0)
            XCTAssertEqual(backend.permissionRequestCount, 0)
        }
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        _ = try await create(service, value)
        backend.authorization = .denied
        let overview = try await service.inspect(tripID: value.tripID)
        XCTAssertNotNil(overview.connection)
        XCTAssertFalse(overview.calendarMissing, "Denied access is not evidence that the calendar was deleted.")
    }

    func testExplicitPermissionRequestOnlyAndDefaultAccountSelection() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts()
        backend.authorization = .notDetermined
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        let granted = try await service.requestAccess()
        XCTAssertTrue(granted)
        XCTAssertEqual(backend.permissionRequestCount, 1)
        let overview = try await service.inspect(tripID: UUID())
        XCTAssertEqual(overview.defaultAccountID, "account")
        _ = try await service.requestAccess()
        XCTAssertEqual(backend.permissionRequestCount, 1)
    }

    func testReadOnlyCalendarAndMissingAccountCannotBeSilentlyReplaced() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        let connection = try await create(service, value)
        backend.savedCalendars[connection.calendarID]?.writable = false
        await errorContains("read-only") { _ = try await self.create(service, value) }
        backend.savedCalendars = [:]
        backend.accountValues = []
        await errorContains("account") {
            _ = try await service.synchronize(snapshot: value, accountID: "account", calendarName: value.name, recreateMissing: true)
        }
        XCTAssertEqual(backend.createCount, 1)
    }

    func testMovedUnmarkedOrInvitationEventsAreNeverOverwritten() async throws {
        for mutation in ["moved", "unmarked", "invitation"] {
            let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
            let service = TripAppleCalendarService(backend: backend, persistence: storage)
            _ = try await create(service, value)
            let key = try XCTUnwrap(backend.savedEvents.keys.first)
            if mutation == "moved" { backend.savedEvents[key]?.calendarID = "someone-elses-calendar" }
            if mutation == "unmarked" { backend.savedEvents[key]?.notes = "Edited outside Compass Day" }
            if mutation == "invitation" { backend.savedEvents[key]?.protectedFromUpdates = true }
            let saveCount = backend.saveCount
            await errorContains("left unchanged") { _ = try await self.create(service, value) }
            XCTAssertEqual(backend.saveCount, saveCount)
            XCTAssertEqual(backend.savedEvents.count, 2)
        }
    }

    func testAmbiguousOwnedDuplicatesRequireReviewInsteadOfDestructiveGuessing() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        _ = try await create(service, value)
        var duplicate = try XCTUnwrap(backend.savedEvents.values.first)
        duplicate.id = "user-created-copy"
        backend.savedEvents[duplicate.id] = duplicate
        await errorContains("More than one") { _ = try await self.create(service, value) }
        XCTAssertEqual(backend.savedEvents.count, 3)
        XCTAssertEqual(backend.removedCount, 0)
    }

    func testOlderRevisionCannotOverwriteNewerCalendarUpdate() async throws {
        let backend = FakeCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot(revision: 8)
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        _ = try await create(service, value)
        await errorContains("newer trip revision") { _ = try await self.create(service, self.snapshot(id: value.tripID, revision: 7)) }
        XCTAssertEqual(backend.commitCount, 1)
    }

    func testMarkerRequiresExactTripTokenAndSingleWellFormedLine() {
        let tripID = UUID(), token = UUID(), eventID = "lunch 🥐 / line\nnext"
        let marker = TripAppleCalendarService.marker(tripID: tripID, token: token, eventID: eventID)
        XCTAssertEqual(TripAppleCalendarService.ownedKey(notes: "Normal notes\n" + marker, tripID: tripID, token: token), eventID)
        XCTAssertNil(TripAppleCalendarService.ownedKey(notes: marker, tripID: UUID(), token: token))
        XCTAssertNil(TripAppleCalendarService.ownedKey(notes: marker, tripID: tripID, token: UUID()))
        XCTAssertNil(TripAppleCalendarService.ownedKey(notes: marker + "\n" + marker, tripID: tripID, token: token))
        XCTAssertNil(TripAppleCalendarService.ownedKey(notes: "Some text " + marker, tripID: tripID, token: token))
        XCTAssertNil(TripAppleCalendarService.ownedKey(notes: String(marker.dropLast()), tripID: tripID, token: token))
    }

    func testReceiptFileRoundTripAndCorruptFileAreHandledWithoutCreatingCalendar() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileTripCalendarReceiptStorage(url: directory.appendingPathComponent("connections.json"))
        let backend = FakeCalendarBackend(), value = snapshot()
        let service = TripAppleCalendarService(backend: backend, persistence: storage)
        let created = try await create(service, value)
        let restored = try await TripAppleCalendarService(backend: backend, persistence: storage).inspect(tripID: value.tripID)
        XCTAssertEqual(restored.connection?.calendarID, created.calendarID)
        try Data("invalid receipt".utf8).write(to: storage.url, options: .atomic)
        await errorContains("connection") { _ = try await self.create(service, value) }
        XCTAssertEqual(backend.createCount, 1)
    }

    private func existingCalendarBackend() -> FakeCalendarBackend {
        let backend = FakeCalendarBackend()
        // Account names are user configurable; no provider inference is permitted.
        backend.savedCalendars["personal"] = .init(id: "personal", name: "Family plans", accountID: "personal-account",
                                                   accountTitle: "My account", writable: true)
        return backend
    }

    private func addToExisting(_ service: TripAppleCalendarService, _ value: TripCalendarExport.Snapshot,
                               calendarID: String? = "personal", reconnect: Bool = false) async throws -> TripAppleCalendarService.Connection {
        try await service.synchronize(snapshot: value, accountID: nil, calendarName: value.name,
                                      recreateMissing: reconnect, existingCalendarID: calendarID)
    }

    func testExistingCalendarListsAllWritableCalendarsWithoutProviderGuessOrDefault() async throws {
        let backend = existingCalendarBackend(), storage = MemoryCalendarReceipts()
        backend.savedCalendars["local"] = .init(id: "local", name: "On my phone", accountID: "local-account",
                                                accountTitle: "On My iPhone", writable: true)
        backend.savedCalendars["subscription"] = .init(id: "subscription", name: "Holidays", accountID: "subscription-account",
                                                       accountTitle: "Google", writable: false)
        let service = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: storage)
        let overview = try await service.inspect(tripID: UUID())
        XCTAssertEqual(Set(overview.writableCalendars.map(\.id)), ["personal", "local"])
        XCTAssertEqual(overview.writableCalendars.first(where: { $0.id == "personal" })?.accountTitle, "My account")
        XCTAssertNil(overview.defaultAccountID)
        XCTAssertNil(overview.connection)
        XCTAssertEqual(backend.createCount, 0)
        XCTAssertEqual(backend.saveCount, 0)
    }

    func testExistingCalendarRequiresExplicitAvailableWritableSelection() async throws {
        let backend = existingCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        backend.savedCalendars["read-only"] = .init(id: "read-only", name: "Read only", accountID: "personal-account",
                                                    accountTitle: "My account", writable: false)
        let service = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: storage)
        await errorContains("Select the Google calendar") { _ = try await self.addToExisting(service, value, calendarID: nil) }
        await errorContains("unavailable") { _ = try await self.addToExisting(service, value, calendarID: "missing") }
        await errorContains("read-only") { _ = try await self.addToExisting(service, value, calendarID: "read-only") }
        XCTAssertEqual(backend.createCount, 0)
        XCTAssertEqual(backend.renameCount, 0)
        XCTAssertEqual(backend.saveCount, 0)
        XCTAssertEqual(backend.commitCount, 0)
        XCTAssertTrue(storage.manifest.links.isEmpty)
    }

    func testExistingCalendarPreservesMetadataPersonalEventsAndOtherTripEvents() async throws {
        let backend = existingCalendarBackend(), storage = MemoryCalendarReceipts(), first = snapshot(), second = snapshot(delay: 86_400)
        let originalCalendar = backend.savedCalendars["personal"]
        backend.savedEvents["appointment"] = .init(id: "appointment", calendarID: "personal", notes: "Personal appointment", start: departure)
        let service = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: storage)
        let firstConnection = try await addToExisting(service, first)
        _ = try await addToExisting(service, second)
        let firstDepartureID = try XCTUnwrap(storage.manifest.links[first.tripID.uuidString]?.eventIDs["departure"])
        let otherIDs = Set(try XCTUnwrap(storage.manifest.links[second.tripID.uuidString]).eventIDs.values)
        let otherStarts = backend.savedEvents.filter { otherIDs.contains($0.key) }.mapValues(\.start)
        let updated = try await addToExisting(service, snapshot(id: first.tripID, revision: 2, includeLunch: false, delay: 600))
        XCTAssertEqual(firstConnection.name, "Family plans")
        XCTAssertEqual(updated.name, "Family plans")
        XCTAssertEqual(backend.savedCalendars["personal"], originalCalendar)
        XCTAssertEqual(backend.savedEvents["appointment"]?.notes, "Personal appointment")
        XCTAssertEqual(backend.savedEvents.filter { otherIDs.contains($0.key) }.mapValues(\.start), otherStarts)
        XCTAssertEqual(backend.savedEvents[firstDepartureID]?.start, departure.addingTimeInterval(600))
        XCTAssertEqual(backend.savedEvents.count, 4)
        XCTAssertEqual(backend.removedCount, 1)
        XCTAssertEqual(backend.createCount, 0)
        XCTAssertEqual(backend.renameCount, 0)
    }

    func testAppleAndExistingCalendarConnectionsForSameTripRemainIndependent() async throws {
        let backend = existingCalendarBackend(), appleStorage = MemoryCalendarReceipts(), googleStorage = MemoryCalendarReceipts(), value = snapshot()
        let apple = TripAppleCalendarService(backend: backend, persistence: appleStorage)
        let google = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: googleStorage)
        let appleConnection = try await create(apple, value)
        let googleConnection = try await addToExisting(google, value)
        let appleLink = try XCTUnwrap(appleStorage.manifest.links[value.tripID.uuidString])
        let googleLink = try XCTUnwrap(googleStorage.manifest.links[value.tripID.uuidString])
        XCTAssertNotEqual(appleConnection.calendarID, googleConnection.calendarID)
        XCTAssertNotEqual(appleLink.token, googleLink.token)
        XCTAssertTrue(Set(appleLink.eventIDs.values).isDisjoint(with: googleLink.eventIDs.values))
        _ = try await addToExisting(google, snapshot(id: value.tripID, revision: 3, includeLunch: false, delay: 600))
        XCTAssertEqual(appleStorage.manifest.links[value.tripID.uuidString]?.revision, 1)
        XCTAssertEqual(backend.savedEvents[appleLink.eventIDs["lunch"]!]?.start, departure.addingTimeInterval(600))
        _ = try await create(apple, snapshot(id: value.tripID, revision: 2, delay: 3_600))
        XCTAssertEqual(googleStorage.manifest.links[value.tripID.uuidString]?.revision, 3)
        XCTAssertEqual(backend.savedEvents[googleLink.eventIDs["departure"]!]?.start, departure.addingTimeInterval(600))
        XCTAssertEqual(backend.savedCalendars["personal"]?.name, "Family plans")
        XCTAssertEqual(backend.savedEvents.count, 3)
        XCTAssertEqual(backend.createCount, 1)
    }

    func testExistingUpdateUsesSavedTargetAndCannotSilentlySwitchCalendar() async throws {
        let backend = existingCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        backend.savedCalendars["other"] = .init(id: "other", name: "Work", accountID: "work-account", accountTitle: "Work", writable: true)
        let service = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: storage)
        _ = try await addToExisting(service, value)
        let originalIDs = Set(backend.savedEvents.keys)
        backend.savedCalendars["personal"]?.name = "Renamed in Calendar"
        let updated = try await addToExisting(service, snapshot(id: value.tripID, revision: 2), calendarID: nil)
        XCTAssertEqual(updated.name, "Renamed in Calendar")
        await errorContains("different calendar") {
            _ = try await self.addToExisting(service, self.snapshot(id: value.tripID, revision: 3), calendarID: "other", reconnect: true)
        }
        XCTAssertEqual(storage.manifest.links[value.tripID.uuidString]?.calendarID, "personal")
        XCTAssertEqual(storage.manifest.links[value.tripID.uuidString]?.revision, 2)
        XCTAssertEqual(Set(backend.savedEvents.keys), originalIDs)
        XCTAssertTrue(backend.savedEvents.values.allSatisfy { $0.calendarID == "personal" })
        XCTAssertEqual(backend.renameCount, 0)
    }

    func testMissingExistingCalendarRequiresExplicitReconnectEvenAfterAccountRemoval() async throws {
        let backend = existingCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: storage)
        _ = try await addToExisting(service, value)
        backend.savedCalendars = [:]
        backend.savedEvents = [:]
        backend.accountValues = []
        backend.savedCalendars["replacement"] = .init(id: "replacement", name: "Trip plans", accountID: "new-account", accountTitle: "Other account", writable: true)
        let overview = try await service.inspect(tripID: value.tripID)
        XCTAssertTrue(overview.calendarMissing)
        XCTAssertEqual(overview.connection?.calendarID, "personal")
        await errorContains("reconnect explicitly") { _ = try await self.addToExisting(service, value, calendarID: "replacement") }
        XCTAssertTrue(backend.savedEvents.isEmpty)
        let result = try await addToExisting(service, value, calendarID: "replacement", reconnect: true)
        XCTAssertEqual(result.calendarID, "replacement")
        XCTAssertEqual(result.name, "Trip plans")
        XCTAssertEqual(backend.savedEvents.count, 2)
        XCTAssertEqual(backend.createCount, 0)
        XCTAssertEqual(backend.renameCount, 0)
    }

    func testMissingExistingCalendarDoesNotFollowEventsMovedToAnotherCalendar() async throws {
        let backend = existingCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: storage)
        _ = try await addToExisting(service, value)
        backend.savedCalendars.removeValue(forKey: "personal")
        backend.savedCalendars["other"] = .init(id: "other", name: "Other plans", accountID: "personal-account", accountTitle: "My account", writable: true)
        for id in backend.savedEvents.keys { backend.savedEvents[id]?.calendarID = "other" }
        let overview = try await service.inspect(tripID: value.tripID)
        XCTAssertTrue(overview.calendarMissing)
        let saveCount = backend.saveCount
        await errorContains("reconnect explicitly") { _ = try await self.addToExisting(service, value, calendarID: "other") }
        XCTAssertEqual(backend.saveCount, saveCount)
        XCTAssertEqual(storage.manifest.links[value.tripID.uuidString]?.calendarID, "personal")
    }

    func testExistingCalendarBecomingReadOnlyCannotBeReplacedDuringUpdate() async throws {
        let backend = existingCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: storage)
        _ = try await addToExisting(service, value)
        backend.savedCalendars["personal"]?.writable = false
        backend.savedCalendars["other"] = .init(id: "other", name: "Other plans", accountID: "personal-account", accountTitle: "My account", writable: true)
        let saveCount = backend.saveCount
        await errorContains("read-only") { _ = try await self.addToExisting(service, value, calendarID: "other", reconnect: true) }
        XCTAssertEqual(backend.saveCount, saveCount)
        XCTAssertEqual(storage.manifest.links[value.tripID.uuidString]?.calendarID, "personal")
        XCTAssertEqual(backend.createCount, 0)
    }

    func testExplicitExistingCalendarReconnectAfterSyncReusesOwnedEventsWithoutDuplicates() async throws {
        let backend = existingCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
        let service = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: storage)
        _ = try await addToExisting(service, value)
        let token = storage.manifest.links[value.tripID.uuidString]?.token
        var calendar = try XCTUnwrap(backend.savedCalendars.removeValue(forKey: "personal"))
        calendar.id = "resynced-calendar"
        backend.savedCalendars[calendar.id] = calendar
        let oldEvents = backend.savedEvents
        backend.savedEvents = [:]
        for (id, original) in oldEvents {
            var event = original
            event.id = "resynced-\(id)"
            event.calendarID = calendar.id
            backend.savedEvents[event.id] = event
        }
        let resyncedIDs = Set(backend.savedEvents.keys)
        let result = try await addToExisting(service, snapshot(id: value.tripID, revision: 2, delay: 600),
                                             calendarID: calendar.id, reconnect: true)
        XCTAssertEqual(result.calendarID, calendar.id)
        XCTAssertEqual(storage.manifest.links[value.tripID.uuidString]?.token, token)
        XCTAssertEqual(Set(backend.savedEvents.keys), resyncedIDs)
        XCTAssertEqual(backend.savedEvents.count, 2)
        XCTAssertEqual(backend.createCount, 0)
        XCTAssertEqual(backend.renameCount, 0)
    }

    func testExistingCalendarReceiptAndCommitFailuresRetryWithoutDuplicates() async throws {
        for failure in ["intent", "receipt", "before-commit", "after-commit"] {
            let backend = existingCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot()
            let original = backend.savedCalendars["personal"]
            if failure == "intent" { storage.failOnSave = [1] }
            if failure == "receipt" { storage.failOnSave = [2] }
            if failure == "before-commit" { backend.failCommitBeforeSaving = true }
            if failure == "after-commit" { backend.failCommitAfterSaving = true }
            let service = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: storage)
            await errorContains("could not save") { _ = try await self.addToExisting(service, value) }
            let committedIDs = Set(backend.savedEvents.keys)
            if failure == "intent" || failure == "before-commit" { XCTAssertTrue(committedIDs.isEmpty) }
            else { XCTAssertEqual(committedIDs.count, 2) }
            storage.failOnSave = []
            backend.failCommitBeforeSaving = false
            backend.failCommitAfterSaving = false
            let relaunched = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: storage)
            let recovered = try await addToExisting(relaunched, value)
            XCTAssertFalse(recovered.pending)
            XCTAssertEqual(recovered.calendarID, "personal")
            XCTAssertEqual(backend.savedEvents.count, 2)
            if !committedIDs.isEmpty { XCTAssertEqual(Set(backend.savedEvents.keys), committedIDs) }
            XCTAssertEqual(backend.savedCalendars["personal"], original)
            XCTAssertEqual(backend.createCount, 0)
            XCTAssertEqual(backend.renameCount, 0)
        }
    }

    func testExistingCalendarStaleSnapshotAndRevokedPermissionDoNotModifyEvents() async throws {
        let backend = existingCalendarBackend(), storage = MemoryCalendarReceipts(), value = snapshot(revision: 3)
        let service = TripAppleCalendarService(destination: .existingCalendar, backend: backend, persistence: storage)
        _ = try await addToExisting(service, value)
        await errorContains("newer trip revision") { _ = try await self.addToExisting(service, self.snapshot(id: value.tripID, revision: 2)) }
        backend.authorization = .denied
        let queryCount = backend.queryCount
        let overview = try await service.inspect(tripID: value.tripID)
        XCTAssertTrue(overview.writableCalendars.isEmpty)
        XCTAssertNotNil(overview.connection)
        XCTAssertFalse(overview.calendarMissing)
        await errorContains("full Calendar access") { _ = try await self.addToExisting(service, value) }
        XCTAssertEqual(backend.queryCount, queryCount)
        XCTAssertEqual(backend.commitCount, 1)
    }

    func testAppleAndGoogleReceiptFilesHaveDifferentStablePaths() {
        let apple = FileTripCalendarReceiptStorage()
        let google = FileTripCalendarReceiptStorage(filename: "google-calendar-connections.json")
        XCTAssertEqual(apple.url.lastPathComponent, "apple-calendar-connections.json")
        XCTAssertEqual(google.url.lastPathComponent, "google-calendar-connections.json")
        XCTAssertEqual(apple.url.deletingLastPathComponent(), google.url.deletingLastPathComponent())
        XCTAssertNotEqual(apple.url, google.url)
    }
}

private enum CalendarTestError: Error { case failed }
private final class MemoryCalendarReceipts: TripCalendarReceiptStorage {
    var manifest = TripCalendarManifest()
    var saveCount = 0
    var failOnSave: Set<Int> = []
    func load() throws -> TripCalendarManifest { manifest }
    func save(_ manifest: TripCalendarManifest) throws {
        saveCount += 1
        if failOnSave.contains(saveCount) { throw CalendarTestError.failed }
        self.manifest = manifest
    }
}
private final class FakeCalendarBackend: TripCalendarBackend {
    struct Detail { var event: TripCalendarExport.Event; var timeZone: String }
    var authorization: TripAppleCalendarService.Authorization = .fullAccess
    var accountValues = [TripAppleCalendarService.Account(id: "account", title: "iCloud", isDefault: true)]
    var savedCalendars: [String: TripCalendarRecord] = [:]
    var savedEvents: [String: TripCalendarEventRecord] = [:]
    var savedDetails: [String: Detail] = [:]
    var stagedCalendars: [String: TripCalendarRecord] = [:]
    var stagedEvents: [String: TripCalendarEventRecord] = [:]
    var stagedDetails: [String: Detail] = [:]
    var stagedRemoved: Set<String> = []
    var createCount = 0, renameCount = 0, saveCount = 0, removedCount = 0, commitCount = 0, resetCount = 0, queryCount = 0, permissionRequestCount = 0
    var failOnEventSave: Int?
    var failCommitBeforeSaving = false, failCommitAfterSaving = false
    var accounts: [TripAppleCalendarService.Account] { queryCount += 1; return accountValues }
    var calendars: [TripCalendarRecord] { queryCount += 1; return Array(savedCalendars.values) }
    func requestAccess() async throws -> Bool { permissionRequestCount += 1; authorization = .fullAccess; return true }
    func refresh() { queryCount += 1 }
    func event(id: String) -> TripCalendarEventRecord? { queryCount += 1; return savedEvents[id] }
    func events(calendarID: String, starts: [Date]) -> [TripCalendarEventRecord] {
        queryCount += 1
        let days = TripAppleCalendarService.uniqueStarts(starts)
        return savedEvents.values.filter { event in
            event.calendarID == calendarID && days.contains { event.start >= $0.addingTimeInterval(-1) && event.start <= $0.addingTimeInterval(86_401) }
        }
    }
    func createCalendar(name: String, accountID: String) throws -> TripCalendarRecord {
        createCount += 1
        let value = TripCalendarRecord(id: "calendar-\(createCount)", name: name, accountID: accountID, accountTitle: "iCloud", writable: true)
        stagedCalendars[value.id] = value
        return value
    }
    func renameCalendar(id: String, name: String) throws {
        renameCount += 1
        guard var value = stagedCalendars[id] ?? savedCalendars[id] else { throw CalendarTestError.failed }
        value.name = name
        stagedCalendars[id] = value
    }
    func saveEvent(_ event: TripCalendarExport.Event, calendarID: String, existingID: String?, notes: String,
                   timeZoneIdentifier: String) throws -> String {
        saveCount += 1
        if failOnEventSave == saveCount { throw CalendarTestError.failed }
        let id = existingID ?? "event-\(UUID().uuidString)"
        stagedEvents[id] = .init(id: id, calendarID: calendarID, notes: notes, start: event.start)
        stagedDetails[id] = .init(event: event, timeZone: timeZoneIdentifier)
        return id
    }
    func removeEvent(id: String) throws { removedCount += 1; stagedRemoved.insert(id) }
    func commit() throws {
        commitCount += 1
        if failCommitBeforeSaving { throw CalendarTestError.failed }
        savedCalendars.merge(stagedCalendars) { _, new in new }
        savedEvents.merge(stagedEvents) { _, new in new }
        savedDetails.merge(stagedDetails) { _, new in new }
        for id in stagedRemoved { savedEvents.removeValue(forKey: id); savedDetails.removeValue(forKey: id) }
        clearStaged()
        if failCommitAfterSaving { throw CalendarTestError.failed }
    }
    func reset() { resetCount += 1; clearStaged() }
    private func clearStaged() { stagedCalendars = [:]; stagedEvents = [:]; stagedDetails = [:]; stagedRemoved = [] }
}
