import Foundation

struct TripLibrary: Codable, Equatable {
    var schemaVersion: Int = 1
    var revision: Int = 0
    var plans: [Plan] = []
    var trips: [Trip] = []
    var selectedTripID: UUID?

    var selectedTrip: Trip? { trips.first { $0.id == selectedTripID } }
    var activeTrip: Trip? { trips.first { $0.status == .active } }
    var isValid: Bool {
        schemaVersion == 1 && revision >= 0 && plans.allSatisfy(\.isValid) && trips.allSatisfy(\.isValid) &&
        Set(plans.map(\.id)).count == plans.count && Set(trips.map(\.id)).count == trips.count &&
        trips.filter { $0.status == .active }.count <= 1 &&
        (selectedTripID == nil || trips.contains { $0.id == selectedTripID })
    }
}

enum TripRepositoryError: LocalizedError {
    case invalidDocument, unsupportedVersion(Int), staleRevision, invalidLegacy
    var errorDescription: String? {
        switch self {
        case .invalidDocument: return "The saved trip library is inconsistent. The original file has been kept."
        case .unsupportedVersion(let version): return "This trip library uses version \(version), which this app cannot open."
        case .staleRevision: return "A newer trip change has already been saved. Reopen the trip before trying this change again."
        case .invalidLegacy: return "The original itinerary could not be migrated. Its file has been kept intact."
        }
    }
}

/// Serial disk ownership prevents an older asynchronous write winning over a newer revision.
/// All Foundation encoding and file operations execute on the actor, away from the UI actor.
actor TripRepository {
    let directory: URL
    let libraryFileURL: URL
    let legacyFileURL: URL
    private var lastSaved: TripLibrary?

    init(directory: URL? = nil, legacyFileURL: URL? = nil) {
        let folder = directory ?? URL.applicationSupportDirectory.appending(path: "CompassDay", directoryHint: .isDirectory)
        self.directory = folder
        self.libraryFileURL = folder.appendingPathComponent("library.json")
        self.legacyFileURL = legacyFileURL ?? folder.appendingPathComponent("itinerary.json")
    }

    func load() throws -> TripLibrary {
        let manager = FileManager.default
        if manager.fileExists(atPath: libraryFileURL.path) {
            let data = try Data(contentsOf: libraryFileURL)
            struct Version: Decodable { var schemaVersion: Int }
            let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
            guard version == 1 else { throw TripRepositoryError.unsupportedVersion(version) }
            let result = try JSONDecoder().decode(TripLibrary.self, from: data)
            guard result.isValid else { throw TripRepositoryError.invalidDocument }
            lastSaved = result
            return result
        }
        guard manager.fileExists(atPath: legacyFileURL.path) else {
            let empty = TripLibrary()
            lastSaved = empty
            return empty
        }
        let original = try Data(contentsOf: legacyFileURL)
        let legacy = try JSONDecoder().decode(Itinerary.self, from: original)
        let migrated = try Self.migrate(legacy)
        try ensureDirectory()
        let backup = directory.appendingPathComponent("itinerary.pre-library-migration.json")
        if !manager.fileExists(atPath: backup.path) {
            try original.write(to: backup, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            guard try Data(contentsOf: backup) == original else { throw TripRepositoryError.invalidLegacy }
        }
        // The legacy file is retained too. A crash before this commit simply retries migration.
        try write(migrated)
        lastSaved = migrated
        return migrated
    }

    func save(_ library: TripLibrary) throws {
        guard library.isValid else { throw TripRepositoryError.invalidDocument }
        if let previous = lastSaved {
            guard library.revision >= previous.revision else { throw TripRepositoryError.staleRevision }
            if library.revision == previous.revision {
                guard library == previous else { throw TripRepositoryError.staleRevision }
                return
            }
        }
        try write(library)
        lastSaved = library
    }

    private func write(_ library: TripLibrary) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(library)
        // Validate our own encoding before replacing the prior document.
        let decoded = try JSONDecoder().decode(TripLibrary.self, from: data)
        guard decoded == library && decoded.isValid else { throw TripRepositoryError.invalidDocument }
        try data.write(to: libraryFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
    }

    static func migrate(_ legacy: Itinerary, now: Date = Date()) throws -> TripLibrary {
        guard legacy.stops.allSatisfy(\.isValid), Set(legacy.stops.map(\.id)).count == legacy.stops.count else {
            throw TripRepositoryError.invalidLegacy
        }
        let places = legacy.stops.map(Place.init(stop:))
        var plan = Plan(name: "My Day", places: places, initialMode: legacy.approachEstimate?.mode ?? .driving)
        plan.reconcileLegs()
        for index in plan.legs.indices {
            guard let sourceID = plan.legs[index].fromPlaceID,
                  let from = legacy.stops.first(where: { $0.id == sourceID }),
                  let to = legacy.stops.first(where: { $0.id == plan.legs[index].toPlaceID }),
                  let oldLeg = legacy.travelLegs?[TravelLeg.key(from: from, to: to)] else { continue }
            plan.legs[index].mode = oldLeg.mode
            if let old = oldLeg.estimate, old.matches(from: from, to: to, mode: oldLeg.mode) {
                plan.legs[index].estimate = LegEstimate(
                    duration: .init(minimum: Int(ceil(old.seconds)), maximum: Int(ceil(old.seconds * 1.2))),
                    source: Point(latitude: old.sourceLatitude, longitude: old.sourceLongitude),
                    destination: Point(latitude: old.destinationLatitude, longitude: old.destinationLongitude),
                    mode: old.mode, departureAt: legacy.startedAt ?? now, fetchedAt: old.fetchedAt)
            }
        }
        var trip = Trip(sourcePlanID: plan.id, plan: plan, scheduledStart: legacy.startedAt ?? now)
        for stop in legacy.stops {
            if let date = stop.arriveBy, let requirement = trip.plan.place(stop.id)?.requirements.first { trip.bindings[requirement.id] = date }
            guard let visit = legacy.visit(for: stop.id), let place = trip.plan.place(stop.id) else { continue }
            // Existing historic timestamps are facts. Nil stays nil, including inferred legacy visits.
            trip.visits[stop.id] = VisitRecord(place: place, arrivedAt: visit.arrivedAt,
                                              budgetAnchor: visit.arrivedAt, budgetAnchorFrozen: visit.arrivedAt != nil,
                                              departureRequestedAt: visit.completedAt, exitedAt: visit.completedAt,
                                              completed: visit.completed)
        }
        trip.startedAt = legacy.startedAt
        if legacy.finished {
            trip.status = .completed
            trip.completedAt = trip.visits.values.compactMap(\.exitedAt).max()
        } else if legacy.startedAt != nil || !trip.visits.isEmpty {
            if let active = trip.remainingPlaces.first(where: { $0.id == legacy.activeID }) ?? trip.remainingPlaces.first {
                trip.status = .active
                let visit = trip.visits[active.id]
                trip.phase = TripPhase(placeID: active.id, kind: visit == nil ? .approaching : .exploring,
                                       effectiveAt: legacy.legStartedAt ?? visit?.arrivedAt ?? legacy.startedAt ?? now)
            } else {
                trip.status = .completed
                trip.completedAt = trip.visits.values.compactMap(\.exitedAt).max()
            }
        }
        // A legacy approach estimate has no saved source coordinates. It cannot be safely reused.
        trip.approachEstimate = nil
        var library = TripLibrary(revision: 1, plans: [plan], trips: [trip], selectedTripID: trip.id)
        if legacy.stops.isEmpty && legacy.startedAt == nil {
            // An empty migrated plan is useful, but an unscheduled empty run is not.
            library.trips = []
            library.selectedTripID = nil
        }
        guard library.isValid else { throw TripRepositoryError.invalidLegacy }
        return library
    }
}
