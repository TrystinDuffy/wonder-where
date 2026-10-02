import Foundation
import CoreLocation

struct Stop: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusFeet: Double = 100
    var address: String = ""
    var hint: String?
    var instructions: [String]?
    var durationMinutes: Double?
    var arriveBy: Date?

    var visitDuration: TimeInterval { (durationMinutes ?? 5) * 60 }

    var arrivalInstructions: [String] {
        (instructions ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var navigationHint: String? {
        guard let text = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var radiusMeters: Double { radiusFeet * 0.3048 }

    func hasUsableFix(_ location: CLLocation, now: Date = Date()) -> Bool {
        location.isFresh(at: now) && location.horizontalAccuracy <= radiusMeters
    }

    func canGuide(from location: CLLocation, now: Date = Date()) -> Bool {
        guard location.isFresh(at: now) else { return false }
        let distance = location.distance(from: CLLocation(latitude: latitude, longitude: longitude))
        // Direction is useful while the GPS uncertainty circle and destination circle are separate.
        return distance > location.horizontalAccuracy + radiusMeters
    }

    func contains(_ location: CLLocation, now: Date = Date()) -> Bool {
        hasUsableFix(location, now: now) &&
        location.distance(from: CLLocation(latitude: latitude, longitude: longitude)) <= radiusMeters
    }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        latitude.isFinite && longitude.isFinite && radiusFeet.isFinite &&
        (-90...90).contains(latitude) && (-180...180).contains(longitude) &&
        radiusFeet > 0 && radiusMeters.isFinite && radiusMeters > 0 &&
        (durationMinutes == nil || (durationMinutes!.isFinite && durationMinutes! > 0 && durationMinutes! <= 1440))
    }
}

extension CLLocation {
    func isFresh(at now: Date) -> Bool {
        CLLocationCoordinate2DIsValid(coordinate) && horizontalAccuracy.isFinite && horizontalAccuracy >= 0 &&
        abs(timestamp.timeIntervalSince(now)) < 15
    }
}

struct StopVisit: Codable, Equatable {
    var arrivedAt: Date?
    var completedAt: Date?
    var completed = false
}

struct Itinerary: Codable, Equatable {
    var stops: [Stop] = []
    var activeID: UUID?
    var finished = false
    var startedAt: Date?
    var legStartedAt: Date?
    var travelLegs: [String: TravelLeg]?
    var visits: [String: StopVisit] = [:]
    var approachEstimate: ApproachEstimate?

    func visit(for id: UUID) -> StopVisit? {
        visits[id.uuidString]
    }

    var activeVisit: StopVisit? { activeID.flatMap { visit(for: $0) } }
    var arrivedID: UUID? { activeVisit == nil ? nil : activeID }
    var arrivalStartedAt: Date? { activeVisit?.arrivedAt }

    var visitedCount: Int {
        stops.filter { visit(for: $0.id) != nil }.count
    }

    func remainingTime(now: Date, approach: ClosedRange<TimeInterval>?) -> ClosedRange<TimeInterval>? {
        if finished { return 0...0 }
        guard let index = activeIndex else { return nil }
        // Looking back at a completed visit must not re-add it to the remaining schedule.
        guard activeVisit?.completed != true else { return nil }
        let hasArrived = activeVisit != nil
        if hasArrived && visitTimeRemaining(now: now) == nil { return nil }
        var lower = hasArrived ? max(0, visitTimeRemaining(now: now)!) : stops[index].visitDuration
        var upper = lower
        if !hasArrived {
            guard let approach else { return nil }
            lower += approach.lowerBound
            upper += approach.upperBound
        }
        for destinationIndex in (index + 1)..<stops.count {
            let from = stops[destinationIndex - 1], to = stops[destinationIndex]
            guard let leg = travelLegs?[TravelLeg.key(from: from, to: to)],
                  let estimate = leg.estimate,
                  estimate.matches(from: from, to: to, mode: leg.mode) else { return nil }
            let visit = visit(for: to.id)
            let duration = visit?.completed == true ? 0 : visit?.arrivedAt.map { max(0, to.visitDuration - now.timeIntervalSince($0)) } ?? to.visitDuration
            lower += Double(estimate.lowerMinutes) * 60 + duration
            upper += Double(estimate.upperMinutes) * 60 + duration
        }
        return lower...upper
    }

    var totalTime: TripTimeRange? {
        let visits = Int(ceil(stops.reduce(0) { $0 + $1.visitDuration } / 60))
        var lower = visits
        var upper = visits
        for (from, to) in zip(stops, stops.dropFirst()) {
            guard let leg = travelLegs?[TravelLeg.key(from: from, to: to)],
                  let estimate = leg.estimate,
                  estimate.matches(from: from, to: to, mode: leg.mode) else { return nil }
            lower += estimate.lowerMinutes
            upper += estimate.upperMinutes
        }
        return TripTimeRange(lowerMinutes: lower, upperMinutes: upper)
    }

    // The itinerary starts at its first place. Travel to that place has no saved origin.
    // Each deadline limits the start independently; the earliest limit satisfies them all.
    var latestStart: Date? {
        guard let lastDeadlineIndex = stops.lastIndex(where: { $0.arriveBy != nil }) else { return nil }
        var elapsed: TimeInterval = 0
        var latest: Date?
        for index in 0...lastDeadlineIndex {
            if index > 0 {
                let from = stops[index - 1], to = stops[index]
                guard let leg = travelLegs?[TravelLeg.key(from: from, to: to)],
                      let estimate = leg.estimate,
                      estimate.matches(from: from, to: to, mode: leg.mode) else { return nil }
                elapsed += from.visitDuration + Double(estimate.upperMinutes) * 60
            }
            if let deadline = stops[index].arriveBy {
                let candidate = deadline.addingTimeInterval(-elapsed)
                latest = latest.map { min($0, candidate) } ?? candidate
            }
        }
        return latest
    }

    func visitTimeRemaining(now: Date = Date()) -> TimeInterval? {
        guard let stop = activeStop, let visit = activeVisit, let arrivedAt = visit.arrivedAt else { return nil }
        return arrivedAt.addingTimeInterval(stop.visitDuration).timeIntervalSince(visit.completedAt ?? now)
    }

    var activeStop: Stop? { stops.first { $0.id == activeID } }
    var activeIndex: Int? { stops.firstIndex { $0.id == activeID } }

    mutating func upsert(_ stop: Stop) {
        guard stop.isValid else { return }
        if let index = stops.firstIndex(where: { $0.id == stop.id }) {
            let previous = stops[index]
            stops[index] = stop
            if previous.latitude != stop.latitude || previous.longitude != stop.longitude {
                visits.removeValue(forKey: stop.id.uuidString)
                finished = false
            }
        } else {
            stops.append(stop)
            finished = false
        }
        if activeID == nil { activeID = stops.first?.id }
    }

    mutating func delete(_ id: UUID) {
        guard let index = stops.firstIndex(where: { $0.id == id }) else { return }
        stops.remove(at: index)
        visits.removeValue(forKey: id.uuidString)
        if activeID == id {
            activeID = stops.isEmpty ? nil : stops[min(index, stops.count - 1)].id
            legStartedAt = Date()
        }
        if stops.isEmpty { finished = false }
    }

    mutating func move(_ id: UUID, by offset: Int) {
        guard let index = stops.firstIndex(where: { $0.id == id }),
              stops.indices.contains(index + offset) else { return }
        stops.swapAt(index, index + offset)
    }

    mutating func restart() {
        activeID = stops.first?.id
        finished = false
        startedAt = nil
        legStartedAt = nil
        visits = [:]
        approachEstimate = nil
    }

    mutating func begin(now: Date = Date()) {
        if startedAt == nil {
            if visits.isEmpty { activeID = stops.first?.id }
            startedAt = now
        }
        if activeStop == nil { activeID = stops.first?.id }
        if legStartedAt == nil { legStartedAt = startedAt }
    }

    mutating func advance(now: Date = Date()) {
        guard let index = activeIndex, var visit = activeVisit else { return }
        if !visit.completed {
            visit.completed = true
            visit.completedAt = now
            visits[stops[index].id.uuidString] = visit
        }
        if index + 1 < stops.count {
            activeID = stops[index + 1].id
            approachEstimate = nil
            legStartedAt = now
        } else if let pending = stops.first(where: { self.visit(for: $0.id)?.completed != true }) {
            // Reordering during a trip can leave unfinished places before the current one.
            activeID = pending.id
            approachEstimate = nil
            legStartedAt = now
        } else {
            finished = true
        }
    }

    mutating func back() {
        if finished { finished = false; return }
        guard let index = activeIndex, index > 0 else { return }
        activeID = stops[index - 1].id
        approachEstimate = nil
        legStartedAt = Date()
    }

    mutating func checkArrival(_ location: CLLocation, now: Date = Date()) {
        guard !finished, let stop = activeStop, visit(for: stop.id) == nil,
              stop.contains(location, now: now) else { return }
        visits[stop.id.uuidString] = StopVisit(arrivedAt: now)
    }

}

extension Itinerary {
    private enum CodingKeys: String, CodingKey {
        case stops, activeID, finished, startedAt, legStartedAt, travelLegs, visits, approachEstimate
    }
    private enum LegacyKeys: String, CodingKey { case arrivedID, arrivalStartedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stops = try values.decode([Stop].self, forKey: .stops)
        activeID = try values.decodeIfPresent(UUID.self, forKey: .activeID)
        finished = try values.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        legStartedAt = try values.decodeIfPresent(Date.self, forKey: .legStartedAt)
        travelLegs = try values.decodeIfPresent([String: TravelLeg].self, forKey: .travelLegs)
        approachEstimate = try values.decodeIfPresent(ApproachEstimate.self, forKey: .approachEstimate)
        if let saved = try values.decodeIfPresent([String: StopVisit].self, forKey: .visits) {
            visits = saved
        } else {
            visits = [:]
            // Old files discarded earlier arrival timestamps. Recover their known completion
            // status from the saved progress, without inventing countdown start times.
            if startedAt != nil, let index = activeIndex {
                for stop in stops.prefix(finished ? stops.count : index) {
                    visits[stop.id.uuidString] = StopVisit(completed: true)
                }
            }
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            if let id = try legacy.decodeIfPresent(UUID.self, forKey: .arrivedID),
               stops.contains(where: { $0.id == id }) {
                let date = try legacy.decodeIfPresent(Date.self, forKey: .arrivalStartedAt)
                visits[id.uuidString] = StopVisit(arrivedAt: date, completed: finished)
            }
        }
    }
}

struct ApproachEstimate: Codable, Equatable {
    let stopID: UUID
    let latitude: Double
    let longitude: Double
    let mode: TravelMode
    let seconds: TimeInterval
    let fetchedAt: Date

    func remainingTravel(to stop: Stop, mode: TravelMode, now: Date) -> ClosedRange<TimeInterval>? {
        guard stopID == stop.id, latitude == stop.latitude, longitude == stop.longitude,
              self.mode == mode, seconds.isFinite, seconds >= 0,
              (0..<900).contains(now.timeIntervalSince(fetchedAt)) else { return nil }
        // This is an estimated duration, not a countdown. Only a new route estimate shows travel progress.
        return seconds...(seconds * 1.2)
    }
}

enum CompassMath {
    static func coordinate(from origin: CLLocationCoordinate2D, meters: Double, bearing: Double) -> CLLocationCoordinate2D {
        let distance = meters / 6_371_000
        let direction = bearing * .pi / 180
        let latitude = origin.latitude * .pi / 180
        let longitude = origin.longitude * .pi / 180
        let targetLatitude = asin(sin(latitude) * cos(distance) + cos(latitude) * sin(distance) * cos(direction))
        let targetLongitude = longitude + atan2(sin(direction) * sin(distance) * cos(latitude), cos(distance) - sin(latitude) * sin(targetLatitude))
        return CLLocationCoordinate2D(latitude: targetLatitude * 180 / .pi,
                                      longitude: (targetLongitude * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let p1 = from.latitude * .pi / 180
        let p2 = to.latitude * .pi / 180
        let delta = (to.longitude - from.longitude) * .pi / 180
        let y = sin(delta) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(delta)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func closestRotation(current: Double, target: Double) -> Double {
        let difference = (target - current).truncatingRemainder(dividingBy: 360)
        return current + (difference > 180 ? difference - 360 : difference < -180 ? difference + 360 : difference)
    }
}

struct DistanceIndicator {
    let quarterMiles: Double
    let symbol: String
    let accessibilityDescription: String

    init(meters: Double) {
        quarterMiles = ceil(max(0, meters) / 1609.344 * 4) / 4
        switch meters {
        case ...402.336:
            symbol = "flame.fill"
            accessibilityDescription = "Hot"
        case ...3218.688:
            symbol = "sun.max.fill"
            accessibilityDescription = "Warm"
        default:
            symbol = "snowflake"
            accessibilityDescription = "Cold"
        }
    }

    var label: String {
        "\(quarterMiles.formatted(.number.precision(.fractionLength(0...2)))) mi"
    }
}


enum TravelMode: String, Codable, CaseIterable, Identifiable {
    case walking, driving, cycling
    var id: String { rawValue }
    var title: String {
        switch self { case .walking: return "Walk"; case .driving: return "Drive"; case .cycling: return "Bike" }
    }
    var symbol: String {
        switch self { case .walking: return "figure.walk"; case .driving: return "car.fill"; case .cycling: return "bicycle" }
    }
}

struct TravelLeg: Codable, Equatable {
    var mode: TravelMode = .driving
    var estimate: TravelEstimate?
    static func key(from: Stop, to: Stop) -> String { "\(from.id.uuidString):\(to.id.uuidString)" }
}

struct TravelEstimate: Codable, Equatable {
    let sourceLatitude: Double
    let sourceLongitude: Double
    let destinationLatitude: Double
    let destinationLongitude: Double
    let mode: TravelMode
    let seconds: TimeInterval
    let fetchedAt: Date

    func matches(from: Stop, to: Stop, mode: TravelMode) -> Bool {
        sourceLatitude == from.latitude && sourceLongitude == from.longitude &&
        destinationLatitude == to.latitude && destinationLongitude == to.longitude && self.mode == mode &&
        seconds.isFinite && seconds >= 0
    }
    var lowerMinutes: Int { max(1, Int(ceil(seconds / 60))) }
    var upperMinutes: Int { max(lowerMinutes, Int(ceil(seconds * 1.2 / 60))) }
    var rangeLabel: String { TripTimeRange(lowerMinutes: lowerMinutes, upperMinutes: upperMinutes).label }
}

struct TripTimeRange: Equatable {
    let lowerMinutes: Int
    let upperMinutes: Int

    var label: String {
        func duration(_ minutes: Int) -> String {
            if minutes < 60 { return "\(minutes) min" }
            let days = minutes / 1440
            let hours = (minutes % 1440) / 60
            let remainder = minutes % 60
            var parts: [String] = []
            if days > 0 { parts.append("\(days) \(days == 1 ? "day" : "days")") }
            if hours > 0 { parts.append("\(hours) hr") }
            if remainder > 0 { parts.append("\(remainder) min") }
            return parts.joined(separator: " ")
        }
        if lowerMinutes == upperMinutes { return duration(lowerMinutes) }
        if upperMinutes < 60 { return "\(lowerMinutes)–\(upperMinutes) min" }
        return "\(duration(lowerMinutes))–\(duration(upperMinutes))"
    }
}
