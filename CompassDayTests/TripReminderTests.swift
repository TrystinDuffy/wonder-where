import XCTest
@testable import CompassDay

final class TripReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func context(for event: ReminderEvent = .tripDeparture, date: Date? = nil,
                         active: Bool = true, valid: Bool = true) -> ReminderScheduleContext {
        ReminderScheduleContext(tripID: UUID(), lifecycleAllowsReminders: active,
                                eventDates: date.map { [event: $0] } ?? [:],
                                validEvents: valid ? [event] : [])
    }

    private func enabled(event: ReminderEvent = .tripDeparture) -> TripReminder {
        var record = TripReminder(event: event)
        record.setEnabled(true)
        return record
    }

    private var authorized: ReminderSystemSnapshot {
        ReminderSystemSnapshot(authorization: [.notification: .authorized, .alarm: .authorized])
    }

    func testTripStartNotificationIsEligibleOnlyBeforeStarting() {
        let place = Place(stop: Stop(name: "Lunch", latitude: 35.46, longitude: -97.51))
        var trip = Trip(plan: Plan(name: "Day", places: [place]), scheduledStart: now)
        XCTAssertEqual(TripReminderEligibility.events(for: trip), [.tripDeparture, .placeDeparture(place.id)])

        TripEngine.start(&trip, origin: nil, at: now)
        XCTAssertEqual(TripReminderEligibility.events(for: trip), [.placeDeparture(place.id)])
        TripEngine.cancel(&trip, at: now)
        XCTAssertTrue(TripReminderEligibility.events(for: trip).isEmpty)
        trip.status = .completed
        XCTAssertTrue(TripReminderEligibility.events(for: trip).isEmpty)
    }

    func testNotificationEligibilityFollowsProgressAndRetainsAppointmentAfterEarlyArrival() {
        var completed = Place(stop: Stop(name: "Breakfast", latitude: 35.46, longitude: -97.51))
        completed.requirements = [.init(kind: .leaveBy, label: "Breakfast deadline")]
        var current = Place(stop: Stop(name: "Lunch", latitude: 35.47, longitude: -97.51))
        let arriveBy = TimeRequirement(kind: .arriveBy, label: "Reach lunch")
        let appointment = TimeRequirement(kind: .appointment, label: "Lunch reservation")
        let leaveBy = TimeRequirement(kind: .leaveBy, label: "Leave lunch")
        current.requirements = [arriveBy, appointment, leaveBy]
        var skipped = Place(stop: Stop(name: "Ice cream", latitude: 35.48, longitude: -97.51))
        skipped.requirements = [.init(kind: .appointment, label: "Ice cream time")]
        skipped.isOptional = true
        var removed = Place(stop: Stop(name: "Park", latitude: 35.49, longitude: -97.51))
        removed.requirements = [.init(kind: .arriveBy, label: "Reach park")]
        let upcoming = Place(stop: Stop(name: "Dinner", latitude: 35.50, longitude: -97.51))
        var trip = Trip(plan: Plan(name: "Day", places: [completed, current, skipped, removed, upcoming]), scheduledStart: now)
        trip.status = .active
        trip.startedAt = now.addingTimeInterval(-3600)
        trip.phase = TripPhase(placeID: current.id, kind: .exploring, effectiveAt: now)
        trip.visits[completed.id] = VisitRecord(place: completed, arrivedAt: now.addingTimeInterval(-3000),
                                              exitedAt: now.addingTimeInterval(-2400), completed: true)
        trip.visits[current.id] = VisitRecord(place: current, arrivedAt: now)
        trip.bindings[appointment.id] = now.addingTimeInterval(3600)
        trip.skippedPlaceIDs.insert(skipped.id)
        trip.removedPlaceIDs.insert(removed.id)

        let eligible = TripReminderEligibility.events(for: trip)

        XCTAssertEqual(eligible, [.placeDeparture(current.id), .requirement(appointment.id),
                                  .requirement(leaveBy.id), .placeDeparture(upcoming.id)])
        var settings = ReminderSettingsDraft(records: [])
        settings.setAllEnabled(true, events: Array(eligible))
        XCTAssertEqual(Set(settings.records.map(\.event)), eligible)
        XCTAssertFalse(settings.records.contains { $0.event == .requirement(arriveBy.id) })
    }

    func testNewReminderSchedulesAtEventMinusLead() {
        let record = enabled()
        let result = ReminderPlanner.decision(for: record,
            context: context(date: now.addingTimeInterval(3600)), system: authorized, now: now)
        XCTAssertEqual(result.action, .schedule(now.addingTimeInterval(2700)))
        XCTAssertEqual(result.reminder.status, .pending)
        XCTAssertNil(result.reminder.scheduledAt, "Desired time is not yet a successful system receipt")
    }

    func testMatchingPendingReminderIsNotScheduledAgainAndRepairsMissingReceipt() {
        let record = enabled()
        var system = authorized
        let scheduled = now.addingTimeInterval(2700)
        system.pending[record.id] = SystemReminderState(date: scheduled, delivery: .notification)
        let result = ReminderPlanner.decision(for: record,
            context: context(date: now.addingTimeInterval(3600)), system: system, now: now)
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.reminder.scheduledAt, scheduled)
        XCTAssertEqual(result.reminder.status, .scheduled)
    }

    func testMovingPendingTimeReplacesSameIdentity() {
        var record = enabled()
        record.scheduledAt = now.addingTimeInterval(2700)
        var system = authorized
        system.pending[record.id] = SystemReminderState(date: record.scheduledAt!, delivery: .notification)
        let result = ReminderPlanner.decision(for: record,
            context: context(date: now.addingTimeInterval(7200)), system: system, now: now)
        XCTAssertEqual(result.action, .schedule(now.addingTimeInterval(6300)))
        XCTAssertEqual(result.reminder.id, record.id)
    }

    func testDismissedReminderDoesNotRearmWhenEventMovesLater() {
        var record = enabled()
        record.scheduledAt = now.addingTimeInterval(-60)
        record.status = .scheduled
        let result = ReminderPlanner.decision(for: record,
            context: context(date: now.addingTimeInterval(7200)), system: authorized, now: now)
        XCTAssertEqual(result.action, .none)
        XCTAssertTrue(result.reminder.consumed)
        XCTAssertEqual(result.reminder.status, .consumed)
    }

    func testRemovedFutureAlarmDoesNotSilentlyReappear() {
        var record = enabled()
        record.delivery = .alarm
        record.scheduledAt = now.addingTimeInterval(3600)
        record.status = .scheduled
        let result = ReminderPlanner.decision(for: record,
            context: context(date: now.addingTimeInterval(7200)), system: authorized, now: now)
        XCTAssertEqual(result.action, .none)
        XCTAssertTrue(result.reminder.consumed)
    }

    func testInterruptedSchedulingWithoutSystemRecordNeedsDeliberateReenable() {
        var record = enabled()
        record.scheduledAt = now.addingTimeInterval(3600)
        record.status = .pending
        let result = ReminderPlanner.decision(for: record,
            context: context(date: now.addingTimeInterval(7200)), system: authorized, now: now)
        XCTAssertEqual(result.action, .none)
        XCTAssertTrue(result.reminder.consumed)
        XCTAssertNotNil(result.reminder.schedulingError)
    }

    func testExplicitReenableAllowsAnotherDeliveryWithoutChangingStableID() {
        var record = enabled()
        record.scheduledAt = now.addingTimeInterval(-60)
        record.consumed = true
        let oldID = record.id
        let oldActivation = record.activationID
        record.setEnabled(false)
        record.setEnabled(true)
        let result = ReminderPlanner.decision(for: record,
            context: context(date: now.addingTimeInterval(3600)), system: authorized, now: now)
        XCTAssertEqual(record.id, oldID)
        XCTAssertNotEqual(record.activationID, oldActivation)
        XCTAssertEqual(result.action, .schedule(now.addingTimeInterval(2700)))
    }

    func testChangingLeadDoesNotRearmConsumedReminder() {
        var record = enabled()
        record.consumed = true
        record.edit(leadSeconds: 300)
        let result = ReminderPlanner.decision(for: record,
            context: context(date: now.addingTimeInterval(3600)), system: authorized, now: now)
        XCTAssertEqual(result.action, .none)
        XCTAssertTrue(result.reminder.consumed)
    }

    func testPastReminderDoesNotFireImmediately() {
        let result = ReminderPlanner.decision(for: enabled(),
            context: context(date: now.addingTimeInterval(300)), system: authorized, now: now)
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.reminder.status, .past)
        XCTAssertTrue(result.reminder.consumed)
    }

    func testPastLeadTimeRemainsPastAcrossReconciliationAndLaterScheduleUntilExplicitReenable() {
        let record = enabled()
        let pastContext = context(date: now.addingTimeInterval(300))
        let initial = ReminderPlanner.decision(for: record, context: pastContext, system: authorized, now: now)
        let repeated = ReminderPlanner.decision(for: initial.reminder, context: pastContext,
                                                system: authorized, now: now.addingTimeInterval(1))
        let futureContext = context(date: now.addingTimeInterval(7200))
        let moved = ReminderPlanner.decision(for: repeated.reminder, context: futureContext,
                                             system: authorized, now: now.addingTimeInterval(2))

        for result in [initial, repeated, moved] {
            XCTAssertEqual(result.action, .none)
            XCTAssertEqual(result.reminder.status, .past)
            XCTAssertTrue(result.reminder.consumed)
            XCTAssertNil(result.reminder.scheduledAt)
            XCTAssertEqual(result.reminder.id, record.id)
            XCTAssertEqual(result.reminder.activationID, record.activationID)
        }
        var reenabled = moved.reminder
        reenabled.setEnabled(false)
        reenabled.setEnabled(true)
        let explicitlyScheduled = ReminderPlanner.decision(for: reenabled, context: futureContext,
                                                           system: authorized, now: now.addingTimeInterval(3))
        XCTAssertEqual(explicitlyScheduled.action, .schedule(now.addingTimeInterval(6300)))
        XCTAssertEqual(explicitlyScheduled.reminder.status, .pending)
        XCTAssertFalse(explicitlyScheduled.reminder.consumed)
        XCTAssertEqual(explicitlyScheduled.reminder.id, record.id)
        XCTAssertNotEqual(explicitlyScheduled.reminder.activationID, record.activationID)
    }

    func testDeniedPermissionIsVisibleAndCancelsExistingRequest() {
        var record = enabled()
        record.scheduledAt = now.addingTimeInterval(3000)
        let system = ReminderSystemSnapshot(authorization: [.notification: .denied])
        let result = ReminderPlanner.decision(for: record,
            context: context(date: now.addingTimeInterval(3600)), system: system, now: now)
        XCTAssertEqual(result.action, .cancel)
        XCTAssertEqual(result.reminder.status, .denied)
        XCTAssertNotNil(result.reminder.schedulingError)
        XCTAssertFalse(result.reminder.consumed)
    }

    func testUnsupportedAlarmOffersNotificationInstead() {
        var record = enabled()
        record.delivery = .alarm
        let system = ReminderSystemSnapshot(authorization: [.alarm: .unsupported])
        let result = ReminderPlanner.decision(for: record,
            context: context(date: now.addingTimeInterval(3600)), system: system, now: now)
        XCTAssertEqual(result.reminder.status, .unsupported)
        XCTAssertEqual(result.action, .none)
    }

    func testCompletionOrSkipCancelsPendingReminder() {
        var record = enabled(event: .placeDeparture(UUID()))
        record.scheduledAt = now.addingTimeInterval(2700)
        for ctx in [context(for: record.event, active: false), context(for: record.event, valid: false)] {
            let result = ReminderPlanner.decision(for: record, context: ctx, system: authorized, now: now)
            XCTAssertEqual(result.action, .cancel)
            XCTAssertEqual(result.reminder.status, .off)
            XCTAssertNil(result.reminder.scheduledAt)
        }
    }

    func testUnknownTravelTimeCancelsObsoletePendingTimeWithoutInventingOne() {
        var record = enabled()
        record.scheduledAt = now.addingTimeInterval(2700)
        var system = authorized
        system.pending[record.id] = SystemReminderState(date: record.scheduledAt!, delivery: .notification)
        let result = ReminderPlanner.decision(for: record, context: context(), system: system, now: now)
        XCTAssertEqual(result.action, .cancel)
        XCTAssertEqual(result.reminder.status, .waitingForTime)
    }

    func testActiveRingingAlarmIsNotReplacedOrCanceledByTimeChange() {
        var record = enabled()
        record.delivery = .alarm
        record.scheduledAt = now.addingTimeInterval(-60)
        var system = authorized
        system.pending[record.id] = SystemReminderState(date: record.scheduledAt!, delivery: .alarm, isAlerting: true)
        let result = ReminderPlanner.decision(for: record,
            context: context(date: now.addingTimeInterval(3600)), system: system, now: now)
        XCTAssertEqual(result.action, .none)
        XCTAssertTrue(result.reminder.consumed)
    }

    func testCodableRoundTripPreservesIdentitySettingsAndReceipt() throws {
        var record = enabled(event: .requirement(UUID()))
        record.scheduledAt = now.addingTimeInterval(5000)
        record.scheduledDelivery = .notification
        record.status = .scheduled
        let decoded = try JSONDecoder().decode(TripReminder.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
    }

    func testRapidDesiredEditsSurviveEarlierCommitAcknowledgement() {
        var draft = ReminderSettingsDraft(records: [])
        draft.edit(.tripDeparture) { $0.setEnabled(true) }
        let firstCommit = draft.records
        draft.edit(.tripDeparture) { $0.edit(leadSeconds: 300) }
        let secondRevision = draft.records[0].desiredRevision
        draft.receive(firstCommit)
        XCTAssertEqual(draft.records.count, 1)
        XCTAssertTrue(draft.records[0].enabled)
        XCTAssertEqual(draft.records[0].leadSeconds, 300)
        XCTAssertEqual(draft.records[0].desiredRevision, secondRevision)
    }

    func testAllNotificationsPreservesConsumedRecordsAndExistingPreferences() {
        var consumed = enabled()
        consumed.consumed = true
        consumed.status = .consumed
        consumed.scheduledAt = now.addingTimeInterval(-60)
        let departureEvent = ReminderEvent.placeDeparture(UUID())
        var departure = enabled(event: departureEvent)
        departure.edit(delivery: .alarm, leadSeconds: 300)
        let requirementEvent = ReminderEvent.requirement(UUID())
        var draft = ReminderSettingsDraft(records: [consumed, departure])
        let eligible = [ReminderEvent.tripDeparture, departureEvent, requirementEvent, requirementEvent]

        draft.setAllEnabled(true, events: eligible)

        XCTAssertEqual(draft.records.count, 3)
        XCTAssertEqual(draft.records.first { $0.event == .tripDeparture }, consumed,
                       "All must not re-arm a dismissed event that is already enabled")
        XCTAssertEqual(draft.records.first { $0.event == departureEvent }, departure)
        let added = draft.records.first { $0.event == requirementEvent }!
        XCTAssertTrue(added.enabled)
        XCTAssertEqual(added.leadSeconds, 900)
        XCTAssertEqual(added.delivery, .notification)
        let firstResult = draft.records
        draft.setAllEnabled(true, events: eligible)
        XCTAssertEqual(draft.records, firstResult, "Repeated All must preserve IDs, activations, and revisions")
    }

    func testNoneDisablesHiddenEventsWithoutCreatingRecordsAndAllOnlyEnablesEligibleEvents() {
        let start = enabled()
        let hidden = enabled(event: .placeDeparture(UUID()))
        let missing = ReminderEvent.requirement(UUID())
        var draft = ReminderSettingsDraft(records: [start, hidden])

        draft.setAllEnabled(false, events: [.tripDeparture, missing])

        XCTAssertEqual(draft.records.map(\.id), [start.id, hidden.id])
        XCTAssertTrue(draft.records.allSatisfy { !$0.enabled })
        XCTAssertEqual(draft.records.map(\.activationID), [start.activationID, hidden.activationID])
        let firstResult = draft.records
        draft.setAllEnabled(false, events: [.tripDeparture, missing])
        XCTAssertEqual(draft.records, firstResult)
        draft.setAllEnabled(true, events: [.tripDeparture, missing])
        XCTAssertEqual(draft.records.first { $0.event == .tripDeparture }?.id, start.id)
        XCTAssertEqual(draft.records.first { $0.event == hidden.event }?.enabled, false,
                       "All must not turn a hidden or skipped event back on")
        XCTAssertEqual(draft.records.first { $0.event == missing }?.enabled, true)
    }

    func testEditingTwoReminderEventsBeforeCommitKeepsBoth() {
        let second = ReminderEvent.placeDeparture(UUID())
        var draft = ReminderSettingsDraft(records: [])
        draft.edit(.tripDeparture) { $0.setEnabled(true) }
        let firstCommit = draft.records
        draft.edit(second) { $0.setEnabled(true) }
        draft.receive(firstCommit)
        XCTAssertEqual(draft.records.count, 2)
        XCTAssertTrue(draft.records.allSatisfy(\.enabled))
        XCTAssertEqual(Set(draft.records.map(\.event)), [.tripDeparture, second])
    }

    func testMatchingReceiptMergesButOlderRevisionCannotOverwriteDraft() {
        var draft = ReminderSettingsDraft(records: [enabled()])
        draft.edit(.tripDeparture) { $0.edit(leadSeconds: 600) }
        var receipt = draft.records[0]
        receipt.status = .scheduled
        receipt.scheduledAt = now.addingTimeInterval(1200)
        draft.receive([receipt])
        XCTAssertEqual(draft.records[0].scheduledAt, receipt.scheduledAt)
        XCTAssertEqual(draft.records[0].status, .scheduled)
        draft.edit(.tripDeparture) { $0.edit(leadSeconds: 0) }
        draft.receive([receipt])
        XCTAssertEqual(draft.records[0].leadSeconds, 0)
    }


    func testUnreadableJournalNeverSchedulesNewOrChangedActiveReminder() {
        var record = enabled()
        let first = ReminderPlanner.decisionWhenJournalUnavailable(for: record,
            context: context(date: now.addingTimeInterval(3600)), system: authorized, message: "Unreadable")
        XCTAssertEqual(first.action, .none)
        XCTAssertEqual(first.reminder.status, .failed)
        XCTAssertNotNil(first.reminder.schedulingError)
        record.scheduledAt = now.addingTimeInterval(1800)
        var system = authorized
        system.pending[record.id] = SystemReminderState(date: record.scheduledAt!, delivery: .notification)
        let changed = ReminderPlanner.decisionWhenJournalUnavailable(for: record,
            context: context(date: now.addingTimeInterval(7200)), system: system, message: "Unreadable")
        XCTAssertEqual(changed.action, .none)
        XCTAssertEqual(changed.reminder.scheduledAt, record.scheduledAt)
    }

    func testUnreadableJournalStillCancelsDisabledSkippedOrFinishedReminder() {
        var record = enabled()
        record.scheduledAt = now.addingTimeInterval(1800)
        let finished = context(active: false)
        let skipped = context(valid: false)
        for ctx in [finished, skipped] {
            let result = ReminderPlanner.decisionWhenJournalUnavailable(for: record,
                context: ctx, system: authorized, message: "Unreadable")
            XCTAssertEqual(result.action, .cancel)
            XCTAssertEqual(result.reminder.status, .off)
            XCTAssertNil(result.reminder.scheduledAt)
            XCTAssertNotNil(result.reminder.schedulingError)
        }
        record.setEnabled(false)
        let disabled = ReminderPlanner.decisionWhenJournalUnavailable(for: record,
            context: context(date: now.addingTimeInterval(3600)), system: authorized, message: "Unreadable")
        XCTAssertEqual(disabled.action, .cancel)
    }

    func testUnreadableJournalCancelsDiscoveredPendingIDWithoutTripReceipt() {
        let record = enabled()
        var system = authorized
        system.pending[record.id] = SystemReminderState(date: now.addingTimeInterval(1800), delivery: .alarm)
        let result = ReminderPlanner.decisionWhenJournalUnavailable(for: record,
            context: context(active: false), system: system, message: "Unreadable")
        XCTAssertEqual(result.action, .cancel)
        XCTAssertNil(result.reminder.scheduledAt)
        var unused = enabled()
        unused.setEnabled(false)
        let noPending = ReminderPlanner.decisionWhenJournalUnavailable(for: unused,
            context: context(active: false), system: authorized, message: "Unreadable")
        XCTAssertEqual(noPending.action, .none)
    }


    func testCancellationDoesNotFailOnAnAlarmAlreadyAbsentFromKnownInventory() {
        var record = enabled()
        record.scheduledDelivery = .alarm
        record.scheduledAt = now.addingTimeInterval(-60)
        var system = authorized
        system.alarmInventoryKnown = true
        XCTAssertFalse(ReminderPlanner.shouldCancelAlarm(record, system: system))
        system.alarmInventoryKnown = false
        XCTAssertTrue(ReminderPlanner.shouldCancelAlarm(record, system: system),
                      "When inventory cannot be read, still attempt cancellation of a known alarm receipt")
        system.alarmInventoryKnown = true
        system.pending[record.id] = SystemReminderState(date: now.addingTimeInterval(60), delivery: .alarm)
        XCTAssertTrue(ReminderPlanner.shouldCancelAlarm(record, system: system))
    }

}
