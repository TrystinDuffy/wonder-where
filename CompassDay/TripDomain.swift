import Foundation
import CoreLocation

/// Coordinates retain Core Location precision; names are metadata, not identity.
struct Point: Codable, Equatable {
    var name: String = ""
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var location: CLLocation { .init(latitude: latitude, longitude: longitude) }
    var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
    func distance(to other: Point) -> Double { location.distance(from: other.location) }
    func sameCoordinates(as other: Point) -> Bool { latitude == other.latitude && longitude == other.longitude }
}

struct Area: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var center: Point
    var radiusMeters: Double

    var radiusFeet: Double { radiusMeters / 0.3048 }
    var radiusLabel: String {
        if radiusMeters >= 1609.344 {
            return "\((radiusMeters / 1609.344).formatted(.number.precision(.fractionLength(0...2)))) mi"
        }
        return "\(radiusFeet.formatted(.number.precision(.fractionLength(0...1)))) ft"
    }
    var isValid: Bool { center.isValid && radiusMeters.isFinite && radiusMeters > 0 }
    func contains(_ point: Point) -> Bool { center.distance(to: point) <= radiusMeters }
    func canConfirm(_ sample: LiveSample) -> Bool {
        sample.hasValidLocation && sample.accuracy <= radiusMeters && contains(sample.point)
    }
}

struct DurationRange: Codable, Equatable {
    var minimum: Int
    var maximum: Int
    var isValid: Bool { minimum >= 0 && maximum >= minimum }
    var isFixed: Bool { minimum == maximum }
    var label: String {
        TripTimeRange(lowerMinutes: Int(ceil(Double(minimum) / 60)), upperMinutes: Int(ceil(Double(maximum) / 60))).label
    }
    static let fiveMinutes = DurationRange(minimum: 300, maximum: 300)
}

struct TimeRequirement: Identifiable, Codable, Equatable {
    enum Kind: String, CaseIterable, Codable, Identifiable {
        case appointment, arriveBy, leaveBy
        var id: String { rawValue }
        var title: String {
            switch self { case .appointment: return "Appointment"; case .arriveBy: return "Arrive by"; case .leaveBy: return "Leave by" }
        }
    }
    var id = UUID()
    var kind: Kind
    var label: String
}

struct Place: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var entry: Area
    var explore: Area
    var exit: Area
    var duration: DurationRange = .fiveMinutes
    var isOptional = false
    var keepPriority = 0
    var hint: String?
    var instructions: [String] = []
    var address: String = ""
    var requirements: [TimeRequirement] = []
    // Optional for existing saved plans. Explicit false keeps separate controls available even
    // when all three areas happen to have the same geometry.
    var sharedEntryArea: Bool?

    var usesEntryForAllAreas: Bool {
        sharedEntryArea ?? (entry.center.sameCoordinates(as: explore.center) &&
                           entry.center.sameCoordinates(as: exit.center) &&
                           entry.radiusMeters == explore.radiusMeters && entry.radiusMeters == exit.radiusMeters)
    }

    mutating func setUsesEntryForAllAreas(_ enabled: Bool) {
        sharedEntryArea = enabled
        if enabled { copyEntryGeometryToOtherAreas() }
    }

    mutating func copyEntryGeometryToOtherAreas() {
        explore.center = entry.center
        explore.radiusMeters = entry.radiusMeters
        exit.center = entry.center
        exit.radiusMeters = entry.radiusMeters
    }

    init(id: UUID = UUID(), name: String, entry: Area, explore: Area, exit: Area,
         duration: DurationRange = .fiveMinutes, isOptional: Bool = false, keepPriority: Int = 0,
         hint: String? = nil, instructions: [String] = [], address: String = "", requirements: [TimeRequirement] = []) {
        self.id = id; self.name = name; self.entry = entry; self.explore = explore; self.exit = exit
        self.duration = duration; self.isOptional = isOptional; self.keepPriority = keepPriority
        self.hint = hint; self.instructions = instructions; self.address = address; self.requirements = requirements
    }

    init(stop: Stop) {
        let center = Point(name: stop.name, latitude: stop.latitude, longitude: stop.longitude)
        self.init(id: stop.id, name: stop.name,
                  entry: Area(id: stop.id.derived(1), name: "Entry", center: center, radiusMeters: stop.radiusMeters),
                  explore: Area(id: stop.id.derived(2), name: "Explore", center: center, radiusMeters: stop.radiusMeters),
                  exit: Area(id: stop.id.derived(3), name: "Exit", center: center, radiusMeters: stop.radiusMeters),
                  duration: .init(minimum: Int(stop.visitDuration.rounded()), maximum: Int(stop.visitDuration.rounded())),
                  hint: stop.hint, instructions: stop.arrivalInstructions, address: stop.address,
                  requirements: stop.arriveBy == nil ? [] : [.init(id: stop.id.derived(4), kind: .arriveBy, label: "Arrive at \(stop.name)")])
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entry.isValid && explore.isValid && exit.isValid && duration.isValid &&
        Set([entry.id, explore.id, exit.id]).count == 3 && Set(requirements.map(\.id)).count == requirements.count
    }
    var navigationHint: String? {
        guard let value = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    var arrivalInstructions: [String] { instructions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    /// Adapter for existing map/search presentation, never the source of trip progress.
    var stop: Stop {
        Stop(id: id, name: name, latitude: entry.center.latitude, longitude: entry.center.longitude,
             radiusFeet: entry.radiusFeet, address: address, hint: hint, instructions: instructions,
             durationMinutes: Double(duration.maximum) / 60)
    }
}

struct LegEstimate: Codable, Equatable {
    var duration: DurationRange
    var source: Point
    var destination: Point
    var mode: TravelMode
    var departureAt: Date
    var fetchedAt: Date
    var requestID = UUID()
    func matches(source: Point, destination: Point, mode: TravelMode) -> Bool {
        self.source.sameCoordinates(as: source) && self.destination.sameCoordinates(as: destination) && self.mode == mode && duration.isValid
    }
    func isCurrent(at date: Date) -> Bool { (0..<900).contains(date.timeIntervalSince(fetchedAt)) }
}

/// An explicit estimate for an effective connection, including a skipped-stop bypass.
struct ManualRouteEstimate: Identifiable, Codable, Equatable {
    var id = UUID()
    var source: Point
    var destination: Point
    var mode: TravelMode
    var duration: DurationRange
    var liveApproach: Bool?
    var isValid: Bool { source.isValid && destination.isValid && duration.isValid }
    func matches(source: Point, destination: Point, mode: TravelMode) -> Bool {
        isValid && self.source.sameCoordinates(as: source) && self.destination.sameCoordinates(as: destination) && self.mode == mode
    }
}

struct Leg: Identifiable, Codable, Equatable {
    var id = UUID()
    var fromPlaceID: UUID?
    var toPlaceID: UUID
    var mode: TravelMode = .driving
    var manualDuration: DurationRange?
    var estimate: LegEstimate?
    var duration: DurationRange? { manualDuration ?? estimate?.duration }
}

struct Plan: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var places: [Place] = []
    var legs: [Leg] = []
    var initialMode: TravelMode = .driving

    func place(_ id: UUID) -> Place? { places.first { $0.id == id } }
    func leg(from: UUID?, to: UUID) -> Leg? { legs.first { $0.fromPlaceID == from && $0.toPlaceID == to } }
    var requirements: [TimeRequirement] { places.flatMap(\.requirements) }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && places.allSatisfy(\.isValid) &&
        Set(places.map(\.id)).count == places.count && Set(requirements.map(\.id)).count == requirements.count &&
        legs.allSatisfy { leg in
            place(leg.toPlaceID) != nil && (leg.fromPlaceID == nil || place(leg.fromPlaceID!) != nil) &&
            leg.fromPlaceID != leg.toPlaceID && leg.manualDuration?.isValid != false && leg.estimate?.duration.isValid != false
        }
    }

    mutating func reconcileLegs() {
        let previous = legs
        legs = places.enumerated().map { index, place in
            let from = index == 0 ? nil : places[index - 1].id
            var leg = previous.first { $0.fromPlaceID == from && $0.toPlaceID == place.id }
                ?? Leg(fromPlaceID: from, toPlaceID: place.id,
                       mode: index == 0 ? initialMode : previous.first(where: { $0.toPlaceID == place.id })?.mode ?? .driving)
            if index == 0 { leg.mode = initialMode }
            if let estimate = leg.estimate {
                let sourceMatches = from.flatMap { self.place($0)?.exit.center }.map { estimate.source.sameCoordinates(as: $0) } ?? true
                if !sourceMatches || !estimate.destination.sameCoordinates(as: place.entry.center) || estimate.mode != leg.mode { leg.estimate = nil }
            }
            return leg
        }
    }
}

enum TripStatus: String, Codable { case scheduled, active, completed, canceled }

struct TripPhase: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case approaching, exploring, exiting }
    var id = UUID()
    var placeID: UUID
    var kind: Kind
    var effectiveAt: Date
}

struct VisitRecord: Codable, Equatable {
    /// Retained independently from editable places, including after their deletion.
    var place: Place
    var arrivedAt: Date?
    var budgetAnchor: Date?
    var budgetAnchorFrozen = false
    var departureRequestedAt: Date?
    var exitedAt: Date?
    var completed = false
    var arrivalManual = false
    var exitManual = false
    var removedAt: Date?

    func budgetElapsed(at date: Date) -> TimeInterval {
        guard let anchor = budgetAnchor else { return 0 }
        return max(0, (exitedAt ?? date).timeIntervalSince(anchor))
    }
    func effectiveBudgetAnchor(at date: Date) -> Date? {
        guard let anchor = budgetAnchor, anchor <= (exitedAt ?? date) else { return nil }
        return anchor
    }
}

struct Trip: Identifiable, Codable, Equatable {
    var id = UUID()
    var sourcePlanID: UUID?
    var plan: Plan
    var scheduledStart: Date
    var timeZoneIdentifier: String = TimeZone.current.identifier
    var bindings: [UUID: Date] = [:]
    var origin: Point?
    var status: TripStatus = .scheduled
    var startedAt: Date?
    var completedAt: Date?
    var phase: TripPhase?
    var visits: [UUID: VisitRecord] = [:]
    var allocations: [UUID: Int] = [:]
    var skippedPlaceIDs: Set<UUID> = []
    var removedPlaceIDs: Set<UUID> = []
    var revision: Int = 0
    var approachEstimate: LegEstimate?
    /// Accepted bypass forecasts survive relaunch; the scheduler still verifies endpoints/mode.
    var routeEstimates: [LegEstimate] = []
    private var manualRouteStorage: [ManualRouteEstimate]?
    var manualRouteEstimates: [ManualRouteEstimate] {
        get { manualRouteStorage ?? [] }
        set { manualRouteStorage = newValue }
    }
    var trackingSessionID: UUID?
    var trackingStartedAt: Date?
    var lastObservedAt: Date?
    var reminders: [TripReminder] = []
    var arrivalNotificationsEnabled = false

    init(id: UUID = UUID(), sourcePlanID: UUID? = nil, plan: Plan, scheduledStart: Date,
         timeZoneIdentifier: String = TimeZone.current.identifier, bindings: [UUID: Date] = [:], origin: Point? = nil) {
        self.id = id; self.sourcePlanID = sourcePlanID; self.plan = plan; self.scheduledStart = scheduledStart
        self.timeZoneIdentifier = timeZoneIdentifier; self.bindings = bindings; self.origin = origin
        self.plan.reconcileLegs()
        self.allocations = Dictionary(uniqueKeysWithValues: plan.places.map { ($0.id, $0.duration.maximum) })
    }

    var activePlaceID: UUID? { phase?.placeID }
    var activePlace: Place? { activePlaceID.flatMap { plan.place($0) } }
    var activeVisit: VisitRecord? { activePlaceID.flatMap { visits[$0] } }
    var includedPlaces: [Place] { plan.places.filter { !skippedPlaceIDs.contains($0.id) && !removedPlaceIDs.contains($0.id) } }
    var remainingPlaces: [Place] { includedPlaces.filter { visits[$0.id]?.completed != true } }
    var visitedCount: Int { includedPlaces.filter { visits[$0.id] != nil }.count }
    var currentTargetArea: Area? {
        guard let place = activePlace, let phase else { return nil }
        switch phase.kind { case .approaching: return place.entry; case .exploring: return place.explore; case .exiting: return place.exit }
    }
    var commandToken: TripPhase? { phase }
    func allocation(for id: UUID) -> Int { allocations[id] ?? plan.place(id)?.duration.maximum ?? 0 }
    func appointment(for placeID: UUID) -> Date? {
        plan.place(placeID)?.requirements.filter { $0.kind == .appointment }.compactMap { bindings[$0.id] }.max()
    }
    func visitTimeRemaining(at now: Date) -> TimeInterval? {
        guard let visit = activeVisit, let anchor = visit.budgetAnchor else { return nil }
        return anchor.addingTimeInterval(Double(allocation(for: visit.place.id))).timeIntervalSince(visit.exitedAt ?? now)
    }
    var isValid: Bool {
        plan.isValid && (origin?.isValid != false) && TimeZone(identifier: timeZoneIdentifier) != nil &&
        (phase == nil || (status == .active && activePlace != nil)) &&
        allocations.allSatisfy { $0.value >= 0 } && visits.allSatisfy { key, value in key == value.place.id && value.place.isValid } &&
        manualRouteEstimates.allSatisfy(\.isValid)
    }
    func reusablePlan(name: String? = nil, id: UUID = UUID()) -> Plan {
        var result = plan
        result.id = id
        if let name { result.name = name }
        result.reconcileLegs()
        // Runtime route forecasts should be refreshed for a future calendar instance.
        for index in result.legs.indices { result.legs[index].estimate = nil }
        return result
    }
}

struct LiveSample: Equatable {
    var area: Area
    var timestamp: Date
    var trueHeading: Double?
    var headingAccuracy: Double?
    var headingTimestamp: Date?
    var sessionID: UUID
    var locationAvailable = true
    var headingAvailable = true

    init(area: Area, timestamp: Date, trueHeading: Double? = nil, headingAccuracy: Double? = nil,
         headingTimestamp: Date? = nil, sessionID: UUID, locationAvailable: Bool = true, headingAvailable: Bool = true) {
        self.area = area; self.timestamp = timestamp; self.trueHeading = trueHeading; self.headingAccuracy = headingAccuracy
        self.headingTimestamp = headingTimestamp; self.sessionID = sessionID
        self.locationAvailable = locationAvailable; self.headingAvailable = headingAvailable
    }
    init(location: CLLocation, sessionID: UUID, trueHeading: Double? = nil, headingAccuracy: Double? = nil, headingTimestamp: Date? = nil) {
        self.init(area: Area(name: "Current location", center: Point(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude), radiusMeters: location.horizontalAccuracy),
                  timestamp: location.timestamp, trueHeading: trueHeading, headingAccuracy: headingAccuracy,
                  headingTimestamp: headingTimestamp, sessionID: sessionID)
    }
    var point: Point { area.center }
    var accuracy: Double { area.radiusMeters }
    var coordinate: CLLocationCoordinate2D { point.coordinate }
    var location: CLLocation {
        .init(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: timestamp)
    }
    var hasValidLocation: Bool { locationAvailable && point.isValid && accuracy.isFinite && accuracy >= 0 }
    func isFresh(at now: Date) -> Bool { hasValidLocation && (-5...15).contains(now.timeIntervalSince(timestamp)) }
}

enum TripGuidance: Equatable {
    case searching
    case arrived
    case direction(degrees: Double, distanceMeters: Double)
}

enum TripNavigation {
    static func guidance(trip: Trip, sample: LiveSample?, now: Date) -> TripGuidance {
        guard trip.status == .active, let target = trip.currentTargetArea, let phase = trip.phase,
              let sample, sample.sessionID == trip.trackingSessionID, sample.isFresh(at: now),
              sample.timestamp >= (trip.trackingStartedAt ?? phase.effectiveAt) else { return .searching }
        if phase.kind == .exploring && target.contains(sample.point) && sample.accuracy <= target.radiusMeters { return .arrived }
        let distance = target.center.distance(to: sample.point)
        guard sample.headingAvailable, let heading = sample.trueHeading, heading.isFinite, (0..<360).contains(heading),
              let headingAccuracy = sample.headingAccuracy, headingAccuracy.isFinite, headingAccuracy >= 0,
              let headingDate = sample.headingTimestamp, headingDate >= (trip.trackingStartedAt ?? phase.effectiveAt),
              distance > sample.accuracy else { return .searching }
        // A stationary phone can legitimately retain an unchanged heading during a valid tracking session.
        let uncertainty = asin(min(1, sample.accuracy / distance)) * 180 / .pi + headingAccuracy
        guard uncertainty < 90 else { return .searching }
        let bearing = CompassMath.bearing(from: sample.coordinate, to: target.center.coordinate)
        return .direction(degrees: (bearing - heading + 360).truncatingRemainder(dividingBy: 360), distanceMeters: distance)
    }
}

extension UUID {
    /// Stable migration identities: retrying a migration cannot duplicate the same area's identity.
    fileprivate func derived(_ discriminator: UInt8) -> UUID {
        var bytes = uuid
        bytes.15 ^= discriminator
        return UUID(uuid: bytes)
    }
}
