import Foundation
import EventKit
import CoreLocation

/// Explicit calendar snapshots. This actor owns both EventKit and its receipt file;
/// sensor updates, clock ticks, and trip edits never write to Calendar on their own.
actor TripAppleCalendarService {
    static let shared = TripAppleCalendarService()
    static let google = TripAppleCalendarService(
        destination: .existingCalendar,
        persistence: FileTripCalendarReceiptStorage(filename: "google-calendar-connections.json"))

    enum Destination: Equatable { case newCalendar, existingCalendar }
    enum Authorization: Equatable { case notDetermined, denied, restricted, writeOnly, fullAccess }
    struct Account: Identifiable, Equatable {
        let id: String
        let title: String
        let isDefault: Bool
    }
    struct Connection: Equatable {
        let calendarID: String
        let name: String
        let accountTitle: String
        let eventCount: Int
        let updatedAt: Date
        let pending: Bool
    }
    struct Overview {
        let authorization: Authorization
        let accounts: [Account]
        let writableCalendars: [TripCalendarRecord]
        let defaultAccountID: String?
        let connection: Connection?
        let calendarMissing: Bool
    }
    enum Failure: LocalizedError {
        case permission, unavailableAccount, missingCalendar, readOnlyCalendar, invalidSnapshot, staleSnapshot
        case calendarSelectionRequired, unavailableCalendar, missingExistingCalendar, changedCalendarSelection
        case ambiguousRecovery, changedEvent, receipt(Error), calendar(Error)
        var errorDescription: String? {
            switch self {
            case .permission: return "Allow full Calendar access in Settings to add or update trip events."
            case .unavailableAccount: return "The selected calendar account is unavailable or cannot create calendars. Check the account in Calendar or Settings."
            case .calendarSelectionRequired: return "Select the Google calendar where you want to add this trip."
            case .unavailableCalendar: return "The selected calendar is unavailable. Check that its account has Calendars enabled in Settings, then select it again."
            case .missingExistingCalendar: return "The calendar used for this trip was removed or is unavailable. Select a calendar and reconnect explicitly to add the trip there."
            case .changedCalendarSelection: return "This trip is already connected to a different calendar. Reopen its calendar settings to update the connected calendar."
            case .missingCalendar: return "This trip’s calendar was removed or is unavailable. Recreate it explicitly if you want a new calendar."
            case .readOnlyCalendar: return "This trip’s calendar is now read-only. Restore permission in Calendar before updating it."
            case .invalidSnapshot: return "The trip calendar contains missing, duplicate, or invalid event times. Review the trip’s schedule and try again."
            case .staleSnapshot: return "This trip calendar has already been updated from a newer trip revision. Reopen the current trip before updating Calendar."
            case .ambiguousRecovery: return "More than one Calendar item matches this trip. Review duplicate trip calendars or events in Calendar before trying again."
            case .changedEvent: return "A trip event was moved, had its WonderWhere reference removed, or became a repeating event or invitation. Restore that event in Calendar before updating; it has been left unchanged."
            case .receipt: return "WonderWhere could not save its calendar connection. Calendar may already contain the changes; try again to recover the connection without creating another calendar."
            case .calendar(let error): return "Calendar could not save the trip: \(error.localizedDescription)"
            }
        }
    }

    private let backend: TripCalendarBackend
    private let persistence: TripCalendarReceiptStorage
    private let destination: Destination

    init(destination: Destination = .newCalendar,
         backend: TripCalendarBackend = EventKitTripCalendarBackend(),
         persistence: TripCalendarReceiptStorage? = nil) {
        self.destination = destination
        self.backend = backend
        self.persistence = persistence ?? FileTripCalendarReceiptStorage(
            filename: destination == .newCalendar ? "apple-calendar-connections.json" : "google-calendar-connections.json")
    }

    /// Only call in response to the user's Connect Calendar action.
    func requestAccess() async throws -> Bool {
        if backend.authorization == .fullAccess { return true }
        return try await backend.requestAccess()
    }

    func inspect(tripID: UUID) throws -> Overview {
        let manifest = try readManifest()
        let authorization = backend.authorization
        let link = manifest.links[tripID.uuidString]
        guard authorization == .fullAccess else {
            return Overview(authorization: authorization, accounts: [], writableCalendars: [], defaultAccountID: nil,
                            connection: link.map { connection($0, calendar: nil) }, calendarMissing: false)
        }
        backend.refresh()
        let accounts = backend.accounts
        // EventKit does not reliably identify a Google provider. Let the user choose
        // from every writable calendar, with its actual account name for context.
        let writableCalendars = backend.calendars.filter(\.writable).sorted {
            if $0.accountTitle != $1.accountTitle {
                return $0.accountTitle.localizedStandardCompare($1.accountTitle) == .orderedAscending
            }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
        let calendar = try link.flatMap { try resolveCalendar($0) }
        return Overview(authorization: authorization, accounts: accounts, writableCalendars: writableCalendars,
                        defaultAccountID: destination == .newCalendar ? (accounts.first(where: \.isDefault)?.id ?? accounts.first?.id) : nil,
                        connection: link.map { connection($0, calendar: calendar) },
                        calendarMissing: link != nil && calendar == nil)
    }

    /// No suspension during mutation: a second Update cannot interleave with this commit.
    @discardableResult
    func synchronize(snapshot: TripCalendarExport.Snapshot, accountID: String?, calendarName: String,
                     recreateMissing: Bool = false, existingCalendarID: String? = nil) throws -> Connection {
        guard backend.authorization == .fullAccess else { throw Failure.permission }
        guard !snapshot.events.isEmpty,
              Set(snapshot.events.map(\.id)).count == snapshot.events.count,
              snapshot.events.allSatisfy({ !$0.id.isEmpty && $0.start.timeIntervalSince1970.isFinite &&
                  ($0.end == nil || ($0.end!.timeIntervalSince1970.isFinite && $0.end! >= $0.start)) })
        else { throw Failure.invalidSnapshot }
        backend.refresh()
        var manifest = try readManifest()
        let oldLink = manifest.links[snapshot.tripID.uuidString]
        if let oldLink, snapshot.revision < oldLink.revision { throw Failure.staleSnapshot }
        var resolved = try oldLink.flatMap { try resolveCalendar($0) }
        if oldLink != nil && resolved == nil && !recreateMissing {
            throw destination == .existingCalendar ? Failure.missingExistingCalendar : Failure.missingCalendar
        }
        if let resolved, !resolved.writable { throw Failure.readOnlyCalendar }
        if destination == .existingCalendar, let resolved, let existingCalendarID, existingCalendarID != resolved.id {
            throw Failure.changedCalendarSelection
        }
        let trimmedName = calendarName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? snapshot.name : trimmedName
        var link = oldLink
        do {
            if resolved == nil {
                switch destination {
                case .newCalendar:
                    guard let accountID, backend.accounts.contains(where: { $0.id == accountID }) else {
                        throw Failure.unavailableAccount
                    }
                    resolved = try backend.createCalendar(name: name, accountID: accountID)
                case .existingCalendar:
                    guard let existingCalendarID, !existingCalendarID.isEmpty else { throw Failure.calendarSelectionRequired }
                    guard let selected = backend.calendars.first(where: { $0.id == existingCalendarID }) else {
                        throw Failure.unavailableCalendar
                    }
                    guard selected.writable else { throw Failure.readOnlyCalendar }
                    resolved = selected
                }
                if destination == .existingCalendar, var previous = oldLink {
                    // An explicit reconnect may select the same synced calendar under
                    // a new identifier. Retain ownership and search windows so it
                    // updates those events instead of adding a second trip copy.
                    previous.calendarID = resolved!.id
                    previous.accountID = resolved!.accountID
                    previous.accountTitle = resolved!.accountTitle
                    previous.name = resolved!.name
                    link = previous
                } else {
                    link = TripCalendarLink(tripID: snapshot.tripID, token: UUID(),
                                            calendarID: resolved!.id, accountID: resolved!.accountID,
                                            accountTitle: resolved!.accountTitle, name: resolved!.name,
                                            eventIDs: [:], starts: [], revision: snapshot.revision,
                                            updatedAt: Date(), pending: false)
                }
            }
            guard let calendar = resolved, var current = link else { throw Failure.missingCalendar }
            current.calendarID = calendar.id
            let existing = try ownedEvents(current, calendar: calendar)
            let desiredIDs = Set(snapshot.events.map(\.id))
            if destination == .newCalendar { try backend.renameCalendar(id: calendar.id, name: name) }
            var savedIDs: [String: String] = [:]
            for event in snapshot.events {
                let notes = Self.notes(event.notes, tripID: snapshot.tripID, token: current.token, eventID: event.id)
                savedIDs[event.id] = try backend.saveEvent(event, calendarID: calendar.id,
                                                         existingID: existing[event.id]?.id,
                                                         notes: notes, timeZoneIdentifier: snapshot.timeZoneIdentifier)
            }
            for (key, event) in existing where !desiredIDs.contains(key) {
                try backend.removeEvent(id: event.id)
            }
            current.name = destination == .newCalendar ? name : calendar.name
            current.accountID = calendar.accountID
            current.accountTitle = calendar.accountTitle
            current.eventIDs = savedIDs
            current.starts = Self.uniqueStarts(current.starts + snapshot.events.map(\.start))
            current.revision = snapshot.revision
            current.updatedAt = Date()
            current.pending = true
            manifest.links[snapshot.tripID.uuidString] = current
            // Persist the identities and search windows before EventKit is allowed to commit.
            // A crash or receipt failure afterward is recovered by IDs and ownership markers.
            try writeManifest(manifest)
            try backend.commit()
            current.pending = false
            manifest.links[snapshot.tripID.uuidString] = current
            try writeManifest(manifest)
            return connection(current, calendar: calendar, name: current.name)
        } catch {
            backend.reset()
            // Keep any persisted intent: even if the commit result was uncertain,
            // retry must recover that calendar before considering another creation.
            if let failure = error as? Failure { throw failure }
            throw Failure.calendar(error)
        }
    }

    private func readManifest() throws -> TripCalendarManifest {
        do { return try persistence.load() }
        catch { throw Failure.receipt(error) }
    }
    private func writeManifest(_ manifest: TripCalendarManifest) throws {
        do { try persistence.save(manifest) }
        catch { throw Failure.receipt(error) }
    }
    private func connection(_ link: TripCalendarLink, calendar: TripCalendarRecord?, name: String? = nil) -> Connection {
        Connection(calendarID: calendar?.id ?? link.calendarID, name: name ?? calendar?.name ?? link.name,
                   accountTitle: calendar?.accountTitle ?? link.accountTitle,
                   eventCount: link.eventIDs.count, updatedAt: link.updatedAt, pending: link.pending)
    }

    private func resolveCalendar(_ link: TripCalendarLink) throws -> TripCalendarRecord? {
        if let calendar = backend.calendars.first(where: { $0.id == link.calendarID }) { return calendar }
        // Existing calendars belong to the user. Events moved to another calendar
        // must not cause future updates to silently follow them there.
        if destination == .existingCalendar { return nil }
        // EventKit identifiers can change after a full account sync. A title is not ownership.
        guard backend.accounts.contains(where: { $0.id == link.accountID }) else { throw Failure.unavailableAccount }
        let matches = backend.calendars.filter { calendar in
            calendar.accountID == link.accountID && backend.events(calendarID: calendar.id, starts: link.starts).contains {
                Self.ownedKey(notes: $0.notes, tripID: link.tripID, token: link.token) != nil
            }
        }
        guard matches.count <= 1 else { throw Failure.ambiguousRecovery }
        return matches.first
    }

    private func ownedEvents(_ link: TripCalendarLink, calendar: TripCalendarRecord) throws -> [String: TripCalendarEventRecord] {
        var found: [String: TripCalendarEventRecord] = [:]
        var records = backend.events(calendarID: calendar.id, starts: link.starts)
        for (key, identifier) in link.eventIDs {
            if let event = backend.event(id: identifier) {
                guard event.calendarID == calendar.id,
                      Self.ownedKey(notes: event.notes, tripID: link.tripID, token: link.token) == key else {
                    throw Failure.changedEvent
                }
                records.append(event)
            }
        }
        for event in records {
            guard let key = Self.ownedKey(notes: event.notes, tripID: link.tripID, token: link.token) else { continue }
            guard !event.protectedFromUpdates else { throw Failure.changedEvent }
            if let other = found[key], other.id != event.id { throw Failure.ambiguousRecovery }
            found[key] = event
        }
        return found
    }

    static func notes(_ original: String, tripID: UUID, token: UUID, eventID: String) -> String {
        let instructions = original.replacingOccurrences(
            of: "Static calendar snapshot; changes in Compass Day do not update this calendar.",
            with: "Update this calendar explicitly from WonderWhere after changing the trip. It does not update automatically.")
        return instructions + "\n\n" + marker(tripID: tripID, token: token, eventID: eventID)
    }
    // Calendar ownership markers remain stable across the WonderWhere rename.
    static func marker(tripID: UUID, token: UUID, eventID: String) -> String {
        "[Compass Day \(tripID.uuidString.lowercased())/\(token.uuidString.lowercased())/\(Data(eventID.utf8).base64EncodedString())]"
    }
    static func ownedKey(notes: String?, tripID: UUID, token: UUID) -> String? {
        let prefix = "[Compass Day \(tripID.uuidString.lowercased())/\(token.uuidString.lowercased())/"
        let lines = (notes ?? "").components(separatedBy: .newlines)
        let matches = lines.compactMap { line -> String? in
            guard line.hasPrefix(prefix), line.hasSuffix("]"),
                  let data = Data(base64Encoded: String(line.dropFirst(prefix.count).dropLast())),
                  let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
            return key
        }
        return matches.count == 1 ? matches.first : nil
    }
    static func uniqueStarts(_ dates: [Date]) -> [Date] {
        // A one-day query around each historical scheduled start avoids EventKit's
        // four-year predicate limit and does not scan unrelated calendar history.
        Array(Set(dates.map { floor($0.timeIntervalSince1970 / 86_400) * 86_400 })).sorted().map(Date.init(timeIntervalSince1970:))
    }
}

struct TripCalendarRecord: Identifiable, Equatable {
    var id: String
    var name: String
    var accountID: String
    var accountTitle: String
    var writable: Bool
}
struct TripCalendarEventRecord {
    var id: String
    var calendarID: String
    var notes: String?
    var start: Date
    var protectedFromUpdates: Bool = false
}
struct TripCalendarLink: Codable {
    var tripID: UUID
    var token: UUID
    var calendarID: String
    var accountID: String
    var accountTitle: String
    var name: String
    var eventIDs: [String: String]
    var starts: [Date]
    var revision: Int
    var updatedAt: Date
    var pending: Bool
}
struct TripCalendarManifest: Codable {
    var version = 1
    var links: [String: TripCalendarLink] = [:]
}
protocol TripCalendarReceiptStorage {
    func load() throws -> TripCalendarManifest
    func save(_ manifest: TripCalendarManifest) throws
}
struct FileTripCalendarReceiptStorage: TripCalendarReceiptStorage {
    var url: URL
    init(url: URL? = nil, filename: String = "apple-calendar-connections.json") {
        if let url { self.url = url; return }
        var directory = URL.applicationSupportDirectory.appending(path: "CompassDay")
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["COMPASS_UI_TEST_DATA"], UUID(uuidString: id) != nil {
            directory = directory.appending(path: "tests/\(id)")
        }
        #endif
        self.url = directory.appendingPathComponent(filename)
    }
    func load() throws -> TripCalendarManifest {
        guard FileManager.default.fileExists(atPath: url.path) else { return TripCalendarManifest() }
        let result = try JSONDecoder().decode(TripCalendarManifest.self, from: Data(contentsOf: url))
        guard result.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
    func save(_ manifest: TripCalendarManifest) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

protocol TripCalendarBackend: AnyObject {
    var authorization: TripAppleCalendarService.Authorization { get }
    var accounts: [TripAppleCalendarService.Account] { get }
    var calendars: [TripCalendarRecord] { get }
    func requestAccess() async throws -> Bool
    func refresh()
    func event(id: String) -> TripCalendarEventRecord?
    func events(calendarID: String, starts: [Date]) -> [TripCalendarEventRecord]
    func createCalendar(name: String, accountID: String) throws -> TripCalendarRecord
    func renameCalendar(id: String, name: String) throws
    func saveEvent(_ event: TripCalendarExport.Event, calendarID: String, existingID: String?, notes: String,
                   timeZoneIdentifier: String) throws -> String
    func removeEvent(id: String) throws
    func commit() throws
    func reset()
}

/// All uses are confined to TripAppleCalendarService's actor, including EventKit queries.
final class EventKitTripCalendarBackend: TripCalendarBackend {
    private let store = EKEventStore()
    private var stagedCalendars: [String: EKCalendar] = [:]
    private var stagedEvents: [String: EKEvent] = [:]
    var authorization: TripAppleCalendarService.Authorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .writeOnly: return .writeOnly
        case .fullAccess: return .fullAccess
        @unknown default: return .denied
        }
    }
    var accounts: [TripAppleCalendarService.Account] {
        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        let defaultID = store.defaultCalendarForNewEvents.flatMap { $0.allowsContentModifications ? $0.source?.sourceIdentifier : nil }
        return store.sources.filter { source in
            switch source.sourceType {
            case .local: return true
            case .calDAV, .exchange, .mobileMe: return writable.contains { $0.source?.sourceIdentifier == source.sourceIdentifier }
            default: return false
            }
        }.map { TripAppleCalendarService.Account(id: $0.sourceIdentifier, title: $0.title, isDefault: $0.sourceIdentifier == defaultID) }
            .sorted { $0.isDefault != $1.isDefault ? $0.isDefault : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var calendars: [TripCalendarRecord] { store.calendars(for: .event).map(record) }
    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }
    func refresh() { store.refreshSourcesIfNecessary() }
    func event(id: String) -> TripCalendarEventRecord? {
        (store.calendarItem(withIdentifier: id) as? EKEvent).map(record)
    }
    func events(calendarID: String, starts: [Date]) -> [TripCalendarEventRecord] {
        guard let calendar = calendar(calendarID) else { return [] }
        var found: [String: TripCalendarEventRecord] = [:]
        for start in TripAppleCalendarService.uniqueStarts(starts) {
            let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-1),
                                                     end: start.addingTimeInterval(86_401), calendars: [calendar])
            for event in store.events(matching: predicate) { found[event.calendarItemIdentifier] = record(event) }
        }
        return Array(found.values)
    }
    func createCalendar(name: String, accountID: String) throws -> TripCalendarRecord {
        guard let source = store.source(withIdentifier: accountID) else { throw TripAppleCalendarService.Failure.unavailableAccount }
        let value = EKCalendar(for: .event, eventStore: store)
        value.source = source
        value.title = name
        try store.saveCalendar(value, commit: false)
        stagedCalendars[value.calendarIdentifier] = value
        return record(value)
    }
    func renameCalendar(id: String, name: String) throws {
        guard let value = calendar(id) else { throw TripAppleCalendarService.Failure.missingCalendar }
        value.title = name
        try store.saveCalendar(value, commit: false)
        stagedCalendars[id] = value
    }
    func saveEvent(_ event: TripCalendarExport.Event, calendarID: String, existingID: String?, notes: String,
                   timeZoneIdentifier: String) throws -> String {
        guard let calendar = calendar(calendarID) else { throw TripAppleCalendarService.Failure.missingCalendar }
        let value: EKEvent
        if let existingID {
            guard let current = store.calendarItem(withIdentifier: existingID) as? EKEvent,
                  current.calendar.calendarIdentifier == calendarID, !current.hasAttendees, !current.hasRecurrenceRules else {
                throw TripAppleCalendarService.Failure.changedEvent
            }
            value = current
        } else {
            value = EKEvent(eventStore: store)
            value.calendar = calendar
            value.alarms = []
        }
        value.title = event.title
        value.startDate = event.start
        // EventKit supports zero-length timed events; nil DTEND in .ics is the same instant.
        value.endDate = event.end ?? event.start
        value.timeZone = TimeZone(identifier: timeZoneIdentifier)
        value.isAllDay = false
        value.notes = notes
        value.url = event.url
        value.location = event.location
        if let point = event.point, point.isValid {
            let location = EKStructuredLocation(title: event.location ?? point.name)
            location.geoLocation = CLLocation(latitude: point.latitude, longitude: point.longitude)
            value.structuredLocation = location
        } else { value.structuredLocation = nil }
        try store.save(value, span: .thisEvent, commit: false)
        stagedEvents[value.calendarItemIdentifier] = value
        return value.calendarItemIdentifier
    }
    func removeEvent(id: String) throws {
        guard let value = store.calendarItem(withIdentifier: id) as? EKEvent else { return }
        guard !value.hasAttendees, !value.hasRecurrenceRules else { throw TripAppleCalendarService.Failure.changedEvent }
        try store.remove(value, span: .thisEvent, commit: false)
    }
    func commit() throws {
        try store.commit()
        stagedCalendars.removeAll()
        stagedEvents.removeAll()
    }
    func reset() {
        store.reset()
        stagedCalendars.removeAll()
        stagedEvents.removeAll()
    }
    private func calendar(_ id: String) -> EKCalendar? { stagedCalendars[id] ?? store.calendar(withIdentifier: id) }
    private func record(_ calendar: EKCalendar) -> TripCalendarRecord {
        TripCalendarRecord(id: calendar.calendarIdentifier, name: calendar.title,
                           accountID: calendar.source?.sourceIdentifier ?? "", accountTitle: calendar.source?.title ?? "Calendar",
                           writable: calendar.allowsContentModifications)
    }
    private func record(_ event: EKEvent) -> TripCalendarEventRecord {
        TripCalendarEventRecord(id: event.calendarItemIdentifier, calendarID: event.calendar.calendarIdentifier,
                                notes: event.notes, start: event.startDate,
                                protectedFromUpdates: event.hasAttendees || event.hasRecurrenceRules)
    }
}
