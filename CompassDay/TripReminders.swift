import Foundation
import SwiftUI
import UserNotifications
import AlarmKit

enum ReminderEvent: Codable, Hashable, Sendable {
    case tripDeparture
    case placeDeparture(UUID)
    case requirement(UUID)
}

/// Shared by notification controls and system scheduling so an enabled event can still occur.
enum TripReminderEligibility {
    static func events(for trip: Trip) -> Set<ReminderEvent> {
        guard trip.status == .scheduled || trip.status == .active else { return [] }
        var events: Set<ReminderEvent> = trip.status == .scheduled ? [.tripDeparture] : []
        for place in trip.remainingPlaces {
            events.insert(.placeDeparture(place.id))
            for requirement in place.requirements {
                if requirement.kind == .arriveBy && trip.visits[place.id]?.arrivedAt != nil { continue }
                events.insert(.requirement(requirement.id))
            }
        }
        return events
    }
}

enum ReminderDelivery: String, Codable, CaseIterable, Identifiable, Sendable {
    case notification, alarm
    var id: String { rawValue }
    var title: String { self == .alarm ? "Alarm" : "Notification" }
}

enum ReminderStatus: String, Codable, Sendable {
    case off, waitingForTime, pending, scheduled, consumed, past, denied, unsupported, failed
}

enum ReminderAuthorization: Equatable, Sendable {
    case notDetermined, authorized, denied, unsupported
}

/// Desired settings and confirmed system state are intentionally separate.
struct TripReminder: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var event: ReminderEvent
    var delivery: ReminderDelivery = .notification
    var leadSeconds = 15 * 60
    var enabled = false
    var activationID = UUID()
    var desiredRevision = UUID()
    var scheduledAt: Date?
    var scheduledDelivery: ReminderDelivery?
    var schedulingError: String?
    var consumed = false
    var status: ReminderStatus = .off

    mutating func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        desiredRevision = UUID()
        if value {
            activationID = UUID()
            consumed = false
            scheduledAt = nil
            scheduledDelivery = nil
            schedulingError = nil
            status = .pending
        }
    }

    mutating func edit(delivery: ReminderDelivery? = nil, leadSeconds: Int? = nil) {
        if let delivery { self.delivery = delivery }
        if let leadSeconds { self.leadSeconds = max(0, leadSeconds) }
        desiredRevision = UUID()
        schedulingError = nil
    }
}

struct ReminderScheduleContext: Sendable {
    var tripID: UUID
    var lifecycleAllowsReminders: Bool
    var eventDates: [ReminderEvent: Date]
    var validEvents: Set<ReminderEvent>
}

struct SystemReminderState: Equatable, Sendable {
    var date: Date
    var delivery: ReminderDelivery
    var isAlerting = false
}

struct ReminderSystemSnapshot: Sendable {
    var pending: [UUID: SystemReminderState] = [:]
    var delivered: Set<UUID> = []
    var authorization: [ReminderDelivery: ReminderAuthorization] = [:]
    var alarmInventoryKnown = false
}

struct ReminderDecision: Equatable {
    enum Action: Equatable {
        case none
        case cancel
        case schedule(Date)
    }
    var action: Action
    var reminder: TripReminder
}

/// Pure reconciliation logic is exercised without requesting permissions or scheduling real alerts.
enum ReminderPlanner {
    static func shouldCancelAlarm(_ reminder: TripReminder, system: ReminderSystemSnapshot) -> Bool {
        system.pending[reminder.id]?.delivery == .alarm ||
            (!system.alarmInventoryKnown && reminder.scheduledDelivery == .alarm)
    }

    /// Corrupt recovery data must never authorize a new alert. Obsolete known identities can
    /// still be canceled: that action cannot cause duplicate or unexpected delivery.
    static func decisionWhenJournalUnavailable(for original: TripReminder,
                                               context: ReminderScheduleContext,
                                               system: ReminderSystemSnapshot,
                                               message: String) -> ReminderDecision {
        var result = original
        result.schedulingError = "Notification recovery data could not be opened. \(message)"
        guard !original.enabled || !context.lifecycleAllowsReminders || !context.validEvents.contains(original.event) else {
            result.status = .failed
            return ReminderDecision(action: .none, reminder: result)
        }
        let knownPending = system.pending[original.id] != nil || original.scheduledAt != nil
        result.status = .off
        result.scheduledAt = nil
        result.scheduledDelivery = nil
        return ReminderDecision(action: knownPending ? .cancel : .none, reminder: result)
    }

    static func decision(for original: TripReminder, context: ReminderScheduleContext,
                         system: ReminderSystemSnapshot, now: Date) -> ReminderDecision {
        var reminder = original
        if !reminder.consumed { reminder.schedulingError = nil }
        let existing = system.pending[reminder.id]
        let hasSystemRecord = existing != nil || reminder.scheduledAt != nil
        func cancelOrNone() -> ReminderDecision.Action { hasSystemRecord ? .cancel : .none }

        guard reminder.enabled, context.lifecycleAllowsReminders, context.validEvents.contains(reminder.event) else {
            reminder.status = .off
            reminder.scheduledAt = nil
            reminder.scheduledDelivery = nil
            return ReminderDecision(action: cancelOrNone(), reminder: reminder)
        }

        if reminder.consumed {
            // A missed lead time was never delivered or dismissed. Keep that explanation
            // while retaining the same protection against silently re-arming it.
            if reminder.status != .past { reminder.status = .consumed }
            // Do not interrupt an alarm that is currently ringing.
            let action: ReminderDecision.Action = existing?.isAlerting == false ? .cancel : .none
            return ReminderDecision(action: action, reminder: reminder)
        }

        let permission = system.authorization[reminder.delivery] ?? .notDetermined
        guard permission == .authorized else {
            reminder.status = permission == .unsupported ? .unsupported : .denied
            reminder.schedulingError = permission == .unsupported
                ? "Ringing alarms require iOS 26 or later. Choose Notification."
                : "Allow \(reminder.delivery == .alarm ? "alarms" : "notifications") in Settings to schedule this alert."
            reminder.scheduledAt = nil
            reminder.scheduledDelivery = nil
            return ReminderDecision(action: cancelOrNone(), reminder: reminder)
        }

        // A missing previously scheduled item was delivered or removed by the person/system.
        // Moving its target time later must not silently re-arm it.
        if system.delivered.contains(reminder.id) || existing?.isAlerting == true
            || (reminder.scheduledAt != nil && existing == nil) {
            reminder.consumed = true
            reminder.status = .consumed
            if original.status == .pending {
                reminder.schedulingError = "A previous scheduling attempt was interrupted. Turn this notification off and on to schedule it again."
            }
            return ReminderDecision(action: .none, reminder: reminder)
        }

        guard let eventDate = context.eventDates[reminder.event] else {
            reminder.status = .waitingForTime
            reminder.scheduledAt = nil
            reminder.scheduledDelivery = nil
            return ReminderDecision(action: cancelOrNone(), reminder: reminder)
        }
        let requestedDate = eventDate.addingTimeInterval(-Double(max(0, reminder.leadSeconds)))
        // Calendar triggers have second precision; never repeatedly replace subsecond differences.
        let date = Date(timeIntervalSince1970: floor(requestedDate.timeIntervalSince1970))
        guard date > now else {
            reminder.status = .past
            reminder.consumed = true
            reminder.scheduledAt = nil
            reminder.scheduledDelivery = nil
            return ReminderDecision(action: cancelOrNone(), reminder: reminder)
        }
        if let existing, existing.delivery == reminder.delivery, abs(existing.date.timeIntervalSince(date)) < 1 {
            // Also repairs a crash between system scheduling and saving its receipt.
            reminder.status = .scheduled
            reminder.scheduledAt = existing.date
            reminder.scheduledDelivery = existing.delivery
            return ReminderDecision(action: .none, reminder: reminder)
        }
        reminder.status = .pending
        return ReminderDecision(action: .schedule(date), reminder: reminder)
    }
}

@available(iOS 26.0, *)
private struct CompassAlarmMetadata: AlarmMetadata {
    var tripID: UUID
    var reminderID: UUID
}

/// Calls are serialized even though platform scheduling APIs suspend. The caller persists returned
/// receipts only when each record's desiredRevision still matches its current desired settings.
@MainActor
final class TripReminderService: ObservableObject {
    @Published private(set) var authorization: [ReminderDelivery: ReminderAuthorization] = [:]
    @Published private(set) var permissionError: String?
    private let center: UNUserNotificationCenter
    private var previousOperation: Task<[TripReminder], Never>?
    private var latestReceipts: [UUID: TripReminder] = [:]
    private let defaults: UserDefaults
    private let receiptStore: ReminderReceiptStore
    private static let prefix = "compassday.reminder."

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard,
         receiptURL: URL? = nil) {
        self.center = center
        self.defaults = defaults
        self.receiptStore = ReminderReceiptStore(fileURL: receiptURL ?? URL.applicationSupportDirectory
            .appending(path: "CompassDay/reminder-receipts.json"))
    }

    static var supportsAlarms: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: authorization[.notification] = .authorized
        case .denied: authorization[.notification] = .denied
        default: authorization[.notification] = .notDetermined
        }
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: authorization[.alarm] = .authorized
            case .denied: authorization[.alarm] = .denied
            default: authorization[.alarm] = .notDetermined
            }
        } else { authorization[.alarm] = .unsupported }
    }

    @discardableResult
    func requestAuthorization(for delivery: ReminderDelivery) async -> Bool {
        permissionError = nil
        do {
            if delivery == .notification {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } else if #available(iOS 26.0, *) {
                _ = try await AlarmManager.shared.requestAuthorization()
            } else {
                permissionError = "Ringing alarms require iOS 26 or later."
            }
        } catch { permissionError = error.localizedDescription }
        await refreshAuthorization()
        return authorization[delivery] == .authorized
    }

    func reconcile(reminders: [TripReminder], context: ReminderScheduleContext,
                   now: Date = Date()) async -> [TripReminder] {
        let previous = previousOperation
        let operation = Task { @MainActor in
            _ = await previous?.value
            return await self.performReconciliation(reminders: reminders, context: context, now: max(now, Date()))
        }
        previousOperation = operation
        return await operation.value
    }

    func cancel(reminders: [TripReminder], tripID: UUID) async -> [TripReminder] {
        await reconcile(reminders: reminders,
                        context: ReminderScheduleContext(tripID: tripID, lifecycleAllowsReminders: false,
                                                         eventDates: [:], validEvents: []))
    }

    private func performReconciliation(reminders: [TripReminder], context: ReminderScheduleContext,
                                       now: Date) async -> [TripReminder] {
        await refreshAuthorization()
        let requests = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        var system = ReminderSystemSnapshot(authorization: authorization)
        for request in requests {
            guard request.identifier.hasPrefix(Self.prefix),
                  let id = UUID(uuidString: String(request.identifier.dropFirst(Self.prefix.count))),
                  let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { continue }
            system.pending[id] = SystemReminderState(date: date, delivery: .notification)
        }
        system.delivered = Set(delivered.compactMap { notification in
            guard notification.request.identifier.hasPrefix(Self.prefix),
                  let id = UUID(uuidString: String(notification.request.identifier.dropFirst(Self.prefix.count))),
                  let desired = reminders.first(where: { $0.id == id }),
                  notification.request.content.userInfo["activationID"] as? String == desired.activationID.uuidString
            else { return nil }
            return id
        })
        var alarmReadError: String?
        if #available(iOS 26.0, *), authorization[.alarm] == .authorized {
            do {
                for alarm in try AlarmManager.shared.alarms {
                    guard case .fixed(let date) = alarm.schedule else { continue }
                    system.pending[alarm.id] = SystemReminderState(date: date, delivery: .alarm,
                                                                  isAlerting: alarm.state == .alerting)
                }
                system.alarmInventoryKnown = true
            } catch { alarmReadError = error.localizedDescription }
        }
        var notificationCount = requests.count
        var results: [TripReminder] = []
        let savedReceipts: [UUID: TripReminder]
        do { savedReceipts = try await receiptStore.read() }
        catch {
            let journalError = error.localizedDescription
            return reminders.map { record in
                let decision = ReminderPlanner.decisionWhenJournalUnavailable(
                    for: record, context: context, system: system, message: journalError)
                var result = decision.reminder
                if decision.action == .cancel {
                    do { try cancelSystemReminder(record, system: system) }
                    catch {
                        result.status = .failed
                        result.scheduledAt = record.scheduledAt
                        result.scheduledDelivery = record.scheduledDelivery
                        result.schedulingError = "The old alert could not be canceled. \(error.localizedDescription) Recovery data is also unavailable: \(journalError)"
                    }
                }
                latestReceipts[result.id] = result
                return result
            }
        }
        for settings in reminders {
            var original = settings
            if let receipt = latestReceipts[settings.id] ?? savedReceipts[settings.id],
               receipt.desiredRevision == settings.desiredRevision {
                original = receipt
            }
            if let alarmReadError, original.delivery == .alarm || original.scheduledDelivery == .alarm {
                original.status = .failed
                original.schedulingError = "Could not check scheduled alarms. \(alarmReadError)"
                results.append(original)
                continue
            }
            let decision = ReminderPlanner.decision(for: original, context: context, system: system, now: now)
            var result = decision.reminder
            var didCancel = false
            do {
                switch decision.action {
                case .none: break
                case .cancel:
                    try cancelSystemReminder(original, system: system)
                    if system.pending[original.id]?.delivery == .notification { notificationCount -= 1 }
                    system.pending.removeValue(forKey: original.id)
                case .schedule(let date):
                    if result.delivery == .notification, notificationCount >= 64,
                       system.pending[result.id]?.delivery != .notification {
                        throw ReminderServiceError.notificationLimit
                    }
                    try cancelSystemReminder(original, system: system)
                    didCancel = true
                    if system.pending[original.id]?.delivery == .notification { notificationCount -= 1 }
                    // Commit intent before invoking the external scheduler. After an interrupted
                    // attempt, the inventory can recover it or require deliberate re-enabling.
                    var intent = result
                    intent.scheduledAt = date
                    intent.scheduledDelivery = result.delivery
                    intent.status = .pending
                    try await receiptStore.save(intent)
                    try await schedule(result, date: date, tripID: context.tripID)
                    if result.delivery == .notification { notificationCount += 1 }
                    result.scheduledAt = date
                    result.scheduledDelivery = result.delivery
                    result.status = .scheduled
                    system.pending[result.id] = SystemReminderState(date: date, delivery: result.delivery)
                }
            } catch {
                result.status = .failed
                result.schedulingError = error.localizedDescription
                // A failed operation is not a confirmed cancellation/scheduling receipt.
                result.scheduledAt = didCancel ? nil : original.scheduledAt
                result.scheduledDelivery = didCancel ? nil : original.scheduledDelivery
            }
            do { try await receiptStore.save(result) }
            catch {
                result.schedulingError = "The system alert was updated, but its receipt could not be saved. \(error.localizedDescription)"
                result.status = .failed
            }
            latestReceipts[result.id] = result
            results.append(result)
        }
        return results
    }

    private func cancelSystemReminder(_ reminder: TripReminder, system: ReminderSystemSnapshot) throws {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(reminder.id)])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(reminder.id)])
        if #available(iOS 26.0, *), ReminderPlanner.shouldCancelAlarm(reminder, system: system) {
            try AlarmManager.shared.cancel(id: reminder.id)
        }
    }

    private func schedule(_ reminder: TripReminder, date: Date, tripID: UUID) async throws {
        if reminder.delivery == .notification {
            let content = UNMutableNotificationContent()
            content.title = "WonderWhere"
            switch reminder.event {
            case .tripDeparture: content.body = "Your trip is starting soon. Open WonderWhere for the planned start time."
            case .placeDeparture: content.body = "It’s almost time to leave this place. Open WonderWhere for your planned departure."
            case .requirement: content.body = "A trip appointment or deadline is coming up. Open WonderWhere for details."
            }
            content.sound = .default
            content.threadIdentifier = "compassday.\(tripID.uuidString)"
            content.userInfo = ["tripID": tripID.uuidString, "reminderID": reminder.id.uuidString,
                                "activationID": reminder.activationID.uuidString]
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            let request = UNNotificationRequest(identifier: Self.identifier(reminder.id), content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try await center.add(request)
        } else if #available(iOS 26.0, *) {
            let alert: AlarmPresentation.Alert
            if #available(iOS 26.1, *) { alert = AlarmPresentation.Alert(title: "WonderWhere alert") }
            else {
                alert = AlarmPresentation.Alert(title: "WonderWhere alert",
                    stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"))
            }
            let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert),
                metadata: CompassAlarmMetadata(tripID: tripID, reminderID: reminder.id), tintColor: .orange)
            _ = try await AlarmManager.shared.schedule(id: reminder.id,
                configuration: .alarm(schedule: .fixed(date), attributes: attributes))
        } else { throw ReminderServiceError.alarmUnavailable }
    }

    /// Call once after a durable, newly recorded background arrival, not during history replay.
    /// A stable persisted receipt additionally prevents replay after relaunch from notifying twice.
    func notifyArrival(tripID: UUID, placeID: UUID, arrivedAt: Date) async -> String? {
        let identifier = "compassday.arrival.\(tripID.uuidString).\(placeID.uuidString).\(Int(arrivedAt.timeIntervalSince1970))"
        let receiptKey = "delivered.\(identifier)"
        guard !defaults.bool(forKey: receiptKey) else { return nil }
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            return "Allow notifications in Settings for background arrival notices."
        }
        let content = UNMutableNotificationContent()
        content.title = "You've arrived"
        content.body = "Open WonderWhere to see this place."
        content.sound = .default
        content.threadIdentifier = "compassday.\(tripID.uuidString)"
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            defaults.set(true, forKey: receiptKey)
            return nil
        } catch { return error.localizedDescription }
    }

    private static func identifier(_ id: UUID) -> String { prefix + id.uuidString }
}

private enum ReminderServiceError: LocalizedError {
    case alarmUnavailable, notificationLimit
    var errorDescription: String? {
        switch self {
        case .alarmUnavailable: "Ringing alarms require iOS 26 or later. Choose Notification."
        case .notificationLimit: "The device's pending notification limit has been reached. Disable another notification and try again."
        }
    }
}

/// Independent recovery journal for the interval between external scheduling and Trip persistence.
/// Atomic writes happen on this actor's executor, with data available after the first device unlock.
private actor ReminderReceiptStore {
    let fileURL: URL
    private var loaded: [UUID: TripReminder]?
    init(fileURL: URL) { self.fileURL = fileURL }

    func read() throws -> [UUID: TripReminder] {
        if let loaded { return loaded }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loaded = [:]
            return [:]
        }
        let records = try JSONDecoder().decode([TripReminder].self, from: Data(contentsOf: fileURL))
        guard Set(records.map(\.id)).count == records.count else { throw CocoaError(.fileReadCorruptFile) }
        let result = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        loaded = result
        return result
    }

    func save(_ record: TripReminder) throws {
        var records = try read()
        guard records[record.id] != record else { return }
        records[record.id] = record
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Array(records.values))
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        loaded = records
    }
}
