import Foundation
import MapKit

struct RouteRequestContext: Identifiable, Equatable {
    enum Kind: String { case fullLeg, liveApproach, bypass }
    var id = UUID()
    let tripID: UUID
    let revision: Int
    let fromPlaceID: UUID?
    let toPlaceID: UUID
    let source: Point
    let destination: Point
    let mode: TravelMode
    let departureAt: Date
    let kind: Kind

    /// Stable across equivalent requests; UUID identity still rejects superseded callbacks.
    var cacheKey: String {
        [tripID.uuidString, fromPlaceID?.uuidString ?? "origin", toPlaceID.uuidString,
         String(source.latitude), String(source.longitude), String(destination.latitude), String(destination.longitude),
         mode.rawValue, kind.rawValue, String(Int(departureAt.timeIntervalSince1970 / 900))].joined(separator: ":")
    }

    func isValid(for trip: Trip, liveOrigin: Point? = nil) -> Bool {
        guard trip.id == tripID, trip.revision == revision,
              trip.status != .completed && trip.status != .canceled,
              let destinationPlace = trip.plan.place(toPlaceID),
              destination.sameCoordinates(as: destinationPlace.entry.center),
              TripScheduler.effectiveMode(trip: trip, from: fromPlaceID, to: toPlaceID) == mode else { return false }
        if kind == .liveApproach {
            guard trip.activePlaceID == toPlaceID, trip.activeVisit == nil, let liveOrigin else { return false }
            return source.distance(to: liveOrigin) <= 75
        }
        let currentSource = fromPlaceID.flatMap { trip.plan.place($0)?.exit.center } ?? trip.origin ?? liveOrigin
        return currentSource?.sameCoordinates(as: source) == true
    }
}

enum TripRouteError: LocalizedError {
    case invalidRequest, unsupportedMode
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "This route changed before its estimate was available."
        case .unsupportedMode: return "Apple Maps could not provide an estimate for this travel mode. Enter a duration instead."
        }
    }
}

enum ManualRouteContexts {
    /// Fixed endpoints remain editable. A measured current-location source only belongs to
    /// the active approach; reconstructing it as a trip-origin bypass would reject later edits.
    static func requests(for trip: Trip) -> [RouteRequestContext] {
        trip.manualRouteEstimates.compactMap { estimate in
            let matchingDestinations = trip.plan.places.filter { $0.entry.center.sameCoordinates(as: estimate.destination) }
            guard let destination = matchingDestinations.first(where: { $0.id == trip.activePlaceID }) ?? matchingDestinations.first else { return nil }
            let fixedSource = trip.plan.places.first { $0.exit.center.sameCoordinates(as: estimate.source) }
            let atTripOrigin = trip.origin?.sameCoordinates(as: estimate.source) == true
            let kind: RouteRequestContext.Kind
            let sourceID: UUID?
            if estimate.liveApproach == true {
                guard trip.status == .active, trip.activePlaceID == destination.id,
                      trip.phase?.kind == .approaching, trip.activeVisit == nil else { return nil }
                sourceID = nil
                kind = .liveApproach
            } else if let fixedSource {
                sourceID = fixedSource.id
                kind = trip.plan.leg(from: fixedSource.id, to: destination.id) == nil ? .bypass : .fullLeg
            } else if atTripOrigin {
                sourceID = nil
                kind = trip.plan.leg(from: nil, to: destination.id) == nil ? .bypass : .fullLeg
            } else {
                guard estimate.liveApproach != false else { return nil }
                guard trip.status == .active, trip.activePlaceID == destination.id,
                      trip.phase?.kind == .approaching, trip.activeVisit == nil else { return nil }
                sourceID = nil
                kind = .liveApproach
            }
            guard TripScheduler.effectiveMode(trip: trip, from: sourceID, to: destination.id) == estimate.mode else { return nil }
            return RouteRequestContext(tripID: trip.id, revision: trip.revision, fromPlaceID: sourceID,
                                       toPlaceID: destination.id, source: estimate.source, destination: estimate.destination,
                                       mode: estimate.mode, departureAt: trip.scheduledStart, kind: kind)
        }
    }
}

/// Maps estimates have no elapsed-time subtraction. Progress requires a fresh origin measurement.
@MainActor
final class TripRoutes {
    private var inFlight: [String: (UUID, MKDirections)] = [:]
    private(set) var cachedEstimates: [LegEstimate] = []

    static nonisolated func matches(_ estimate: LegEstimate, request: RouteRequestContext,
                                   sourceToleranceMeters: Double = 0) -> Bool {
        estimate.duration.isValid && estimate.mode == request.mode &&
        estimate.destination.sameCoordinates(as: request.destination) &&
        (sourceToleranceMeters == 0 ? estimate.source.sameCoordinates(as: request.source) :
            estimate.source.distance(to: request.source) <= sourceToleranceMeters)
    }

    func fetch(_ context: RouteRequestContext) async throws -> LegEstimate {
        guard context.source.isValid, context.destination.isValid else { throw TripRouteError.invalidRequest }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: context.source.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: context.destination.coordinate))
        request.departureDate = context.departureAt
        switch context.mode {
        case .walking: request.transportType = .walking
        case .driving: request.transportType = .automobile
        case .cycling: request.transportType = .cycling
        }
        let directions = MKDirections(request: request)
        if let previous = inFlight[context.cacheKey] { previous.1.cancel() }
        inFlight[context.cacheKey] = (context.id, directions)
        defer {
            if inFlight[context.cacheKey]?.0 == context.id { inFlight.removeValue(forKey: context.cacheKey) }
        }
        let response = try await withTaskCancellationHandler {
            try await directions.calculateETA()
        } onCancel: {
            Task { @MainActor in directions.cancel() }
        }
        guard !Task.isCancelled, inFlight[context.cacheKey]?.0 == context.id,
              response.expectedTravelTime.isFinite, response.expectedTravelTime >= 0 else {
            throw CancellationError()
        }
        guard response.transportType.rawValue == 0 || response.transportType == request.transportType else {
            throw TripRouteError.unsupportedMode
        }
        let duration = DurationRange(minimum: Int(ceil(response.expectedTravelTime)),
                                     maximum: Int(ceil(response.expectedTravelTime * 1.2)))
        let estimate = LegEstimate(duration: duration, source: context.source, destination: context.destination,
                                    mode: context.mode, departureAt: context.departureAt,
                                    fetchedAt: Date(), requestID: context.id)
        cachedEstimates.removeAll {
            $0.matches(source: context.source, destination: context.destination, mode: context.mode) &&
            abs($0.departureAt.timeIntervalSince(context.departureAt)) < 900
        }
        cachedEstimates.append(estimate)
        if cachedEstimates.count > 128 { cachedEstimates.removeFirst(cachedEstimates.count - 128) }
        return estimate
    }

    func cancelAll() {
        for (_, request) in inFlight.values { request.cancel() }
        inFlight.removeAll()
    }
}

enum ManualRouteEditing {
    /// Unrelated revisions are harmless; edited endpoint geometry must not be silently accepted.
    @discardableResult
    static func apply(request: RouteRequestContext, duration: DurationRange?, to trip: inout Trip,
                      liveOrigin: Point? = nil) -> Bool {
        guard duration?.isValid != false, request.tripID == trip.id,
              trip.status == .scheduled || trip.status == .active,
              let destination = trip.plan.place(request.toPlaceID),
              destination.entry.center.sameCoordinates(as: request.destination),
              TripScheduler.effectiveMode(trip: trip, from: request.fromPlaceID, to: request.toPlaceID) == request.mode else { return false }
        var manualSource = request.source
        if request.kind == .liveApproach {
            guard request.fromPlaceID == nil, trip.activePlaceID == request.toPlaceID, trip.activeVisit == nil,
                  let liveOrigin, liveOrigin.isValid else { return false }
            manualSource = liveOrigin
        } else if let sourceID = request.fromPlaceID {
            guard trip.plan.place(sourceID)?.exit.center.sameCoordinates(as: request.source) == true else { return false }
        } else if let origin = trip.origin {
            guard origin.sameCoordinates(as: request.source) else { return false }
        } else {
            // This estimate establishes its explicit initial origin for offline reuse.
            trip.origin = request.source
        }
        let old = trip.manualRouteEstimates.last {
            $0.matches(source: request.source, destination: request.destination, mode: request.mode)
        }
        trip.manualRouteEstimates.removeAll {
            $0.matches(source: request.source, destination: request.destination, mode: request.mode)
        }
        if let duration {
            trip.manualRouteEstimates.append(ManualRouteEstimate(id: old?.id ?? UUID(), source: manualSource,
                                                                destination: request.destination, mode: request.mode,
                                                                duration: duration, liveApproach: request.kind == .liveApproach))
        }
        trip.revision += 1
        return true
    }
}
