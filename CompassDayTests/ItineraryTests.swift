import XCTest
import CoreLocation
import UIKit
@testable import CompassDay

/// Compatibility and presentation utilities. Active-trip behavior is covered by TripEngineTests.
final class ItineraryTests: XCTestCase {
    private func stop(_ name: String) -> Stop { Stop(name: name, latitude: 35.46, longitude: -97.51) }

    func testBearingAndSmoothRotationAcrossNorth() {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        XCTAssertEqual(CompassMath.bearing(from: origin, to: .init(latitude: 0, longitude: 1)), 90, accuracy: 0.001)
        XCTAssertEqual(CompassMath.bearing(from: origin, to: .init(latitude: -1, longitude: 0)), 180, accuracy: 0.001)
        XCTAssertEqual(CompassMath.closestRotation(current: 359, target: 1), 361)
        XCTAssertEqual(CompassMath.closestRotation(current: 1, target: 359), -1)
    }

    @MainActor func testAppearancePersistsAndInvalidValuesFallBack() throws {
        let suite = "CompassDayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = CompassAppearance(defaults: defaults)
        appearance.accent = .purple
        appearance.icon = .kite
        appearance.border = .dots
        XCTAssertTrue(appearance.setCustomHex(" #a3c "))
        let reloaded = CompassAppearance(defaults: defaults)
        XCTAssertEqual(reloaded.accent, .purple)
        XCTAssertEqual(reloaded.icon, .kite)
        XCTAssertEqual(reloaded.border, .dots)
        XCTAssertTrue(reloaded.usesCustomColor)
        XCTAssertEqual(reloaded.customHex, "AA33CC")
        XCTAssertFalse(reloaded.setCustomHex("oops"))
        XCTAssertEqual(reloaded.customHex, "AA33CC")
        reloaded.usesCustomColor = false
        let preset = CompassAppearance(defaults: defaults)
        XCTAssertFalse(preset.usesCustomColor)
        XCTAssertEqual(preset.customHex, "AA33CC")
        defaults.set("invalid", forKey: "accentColor")
        defaults.set("invalid", forKey: "compassIcon")
        defaults.set("invalid", forKey: "compassBorder")
        defaults.set("invalid", forKey: "customColorHex")
        let fallback = CompassAppearance(defaults: defaults)
        XCTAssertEqual(fallback.accent, .blue)
        XCTAssertEqual(fallback.icon, .arrow)
        XCTAssertEqual(fallback.border, .classic)
        XCTAssertEqual(fallback.customHex, "007AFF")
    }

    func testHintsPersistAndExistingStopsDecodeWithoutHints() throws {
        var place = stop("Secret destination")
        let oldData = try JSONEncoder().encode(place)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("hint"))
        let oldStop = try JSONDecoder().decode(Stop.self, from: oldData)
        XCTAssertNil(oldStop.navigationHint)
        place.hint = "  Follow the smell of pancakes.  "
        let reloaded = try JSONDecoder().decode(Stop.self, from: JSONEncoder().encode(place))
        XCTAssertEqual(reloaded.navigationHint, "Follow the smell of pancakes.")
        place.hint = " \n "
        XCTAssertNil(place.navigationHint)
    }

    @MainActor func testConfigurationPINValidationPersistenceAndRecovery() throws {
        let suite = "CompassDayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = ConfigurationAccess(defaults: defaults)
        XCTAssertFalse(access.hasPIN)
        XCTAssertFalse(access.setPIN("123"))
        XCTAssertFalse(access.setPIN("１２３４"))
        XCTAssertTrue(access.setPIN("0426"))
        let reloaded = ConfigurationAccess(defaults: defaults)
        XCTAssertTrue(reloaded.hasPIN)
        XCTAssertFalse(reloaded.isUnlocked)
        XCTAssertFalse(reloaded.unlock("0000"))
        XCTAssertFalse(reloaded.isUnlocked)
        XCTAssertTrue(reloaded.unlock("0426"))
        XCTAssertTrue(reloaded.isUnlocked)
        reloaded.removePIN()
        XCTAssertFalse(ConfigurationAccess(defaults: defaults).hasPIN)
    }

    func testDistanceIndicatorRoundsUpToQuarterMilesAndUsesActualDistanceForIcons() {
        let cases: [(Double, Double, String)] = [
            (0, 0, "flame.fill"), (1, 0.25, "flame.fill"),
            (402.336, 0.25, "flame.fill"), (402.337, 0.5, "sun.max.fill"),
            (1000, 0.75, "sun.max.fill"), (1609.344, 1, "sun.max.fill"),
            (3218.688, 2, "sun.max.fill"), (3218.689, 2.25, "snowflake"),
            (4828.032, 3, "snowflake"), (4828.033, 3.25, "snowflake")
        ]
        for (meters, roundedMiles, symbol) in cases {
            let indicator = DistanceIndicator(meters: meters)
            XCTAssertEqual(indicator.quarterMiles, roundedMiles, "Distance: \(meters) meters")
            XCTAssertEqual(indicator.symbol, symbol)
        }
    }

    @MainActor func testLocationFailuresKeepFreshFixesAndRecoverWithoutRelaunch() {
        let service = LocationService()
        let manager = CLLocationManager()
        let good = CLLocation(latitude: 35.46, longitude: -97.51)
        service.locationManager(manager, didUpdateLocations: [good])
        XCTAssertNotNil(service.position)
        let invalid = CLLocation(coordinate: good.coordinate, altitude: 0, horizontalAccuracy: -1,
                                 verticalAccuracy: -1, timestamp: Date())
        service.locationManager(manager, didUpdateLocations: [invalid])
        XCTAssertEqual(service.position, good)
        service.locationManager(manager, didFailWithError: CLError(.locationUnknown))
        XCTAssertEqual(service.position, good)
        service.locationManager(manager, didFailWithError: CLError(.headingFailure))
        XCTAssertEqual(service.position, good)
        service.locationManager(manager, didFailWithError: CLError(.denied))
        XCTAssertNil(service.position)
        service.locationManager(manager, didUpdateLocations: [good])
        XCTAssertEqual(service.position, good)
    }

    @MainActor func testHeadingValidationRecoveryAndNorthCrossing() {
        let service = LocationService()
        let date = Date()
        service.acceptHeading(trueHeading: 359, accuracy: 5, timestamp: date, now: date)
        XCTAssertEqual(service.heading, 359)
        service.acceptHeading(trueHeading: 180, accuracy: 5, timestamp: date.addingTimeInterval(-1), now: date)
        XCTAssertEqual(service.heading, 359) // An out-of-order callback cannot rotate the arrow backward.
        service.acceptHeading(trueHeading: 1, accuracy: 5, timestamp: date.addingTimeInterval(1), now: date)
        XCTAssertEqual(CompassMath.closestRotation(current: -359, target: -service.heading!), -361)
        service.acceptHeading(trueHeading: 180, accuracy: 100, timestamp: date.addingTimeInterval(2), now: date)
        XCTAssertNil(service.heading)
        service.acceptHeading(trueHeading: -1, accuracy: 5, timestamp: date.addingTimeInterval(3), now: date)
        XCTAssertNil(service.heading) // Do not substitute magnetic north for a true-north bearing.
        service.acceptHeading(trueHeading: 90, accuracy: 5, timestamp: date.addingTimeInterval(4), now: date)
        XCTAssertEqual(service.heading, 90)
        service.stop()
        XCTAssertNil(service.heading)
        service.acceptHeading(trueHeading: 270, accuracy: 5, timestamp: date.addingTimeInterval(5), now: date)
        XCTAssertEqual(service.heading, 270)
    }

    func testHeadingObservationEpochRejectsQueuedPreLockAndPreRecoveryCallbacks() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var session = HeadingObservationSession()
        XCTAssertFalse(session.accepts(date))
        session.begin(at: date)
        XCTAssertTrue(session.accepts(date))
        XCTAssertFalse(session.accepts(date.addingTimeInterval(-0.1)))
        session.end()
        XCTAssertFalse(session.accepts(date.addingTimeInterval(1)))
        session.begin(at: date.addingTimeInterval(2))
        XCTAssertFalse(session.accepts(date.addingTimeInterval(1.9)))
        XCTAssertTrue(session.accepts(date.addingTimeInterval(2)))
        // Sensor recovery starts another epoch, while an uninterrupted session has no timeout.
        session.begin(at: date.addingTimeInterval(10))
        XCTAssertFalse(session.accepts(date.addingTimeInterval(9.9)))
        XCTAssertTrue(session.accepts(date.addingTimeInterval(10)))
        XCTAssertEqual(session.startedAt, date.addingTimeInterval(10))
    }

    func testTimeRangesUseHoursAndDaysAtUnitBoundaries() {
        let cases: [(Int, Int, String)] = [
            (59, 59, "59 min"), (60, 60, "1 hr"), (61, 61, "1 hr 1 min"),
            (59, 61, "59 min–1 hr 1 min"),
            (1439, 1439, "23 hr 59 min"), (1440, 1440, "1 day"),
            (1441, 1441, "1 day 1 min"), (1501, 1501, "1 day 1 hr 1 min"),
            (1439, 1441, "23 hr 59 min–1 day 1 min"),
            (2880, 4320, "2 days–3 days")
        ]
        for (lower, upper, expected) in cases {
            XCTAssertEqual(TripTimeRange(lowerMinutes: lower, upperMinutes: upper).label, expected)
        }
        let estimate = TravelEstimate(sourceLatitude: 0, sourceLongitude: 0,
                                      destinationLatitude: 1, destinationLongitude: 1,
                                      mode: .walking, seconds: 86400, fetchedAt: Date())
        XCTAssertEqual(estimate.rangeLabel, "1 day–1 day 4 hr 48 min")
    }

    func testLegacyHistoryDecodeRetainsKnownProgressWithoutInventingTimes() throws {
        let first = stop("First"), current = stop("Current"), last = stop("Last")
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let old = Itinerary(stops: [first, current, last], activeID: current.id, startedAt: arrival.addingTimeInterval(-600))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "visits")
        json["arrivedID"] = current.id.uuidString
        json["arrivalStartedAt"] = arrival.timeIntervalSinceReferenceDate
        let legacy = try JSONDecoder().decode(Itinerary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.visit(for: first.id)?.completed == true)
        XCTAssertNil(legacy.visit(for: first.id)?.arrivedAt)
        XCTAssertNil(legacy.visit(for: first.id)?.completedAt)
        XCTAssertEqual(legacy.visit(for: current.id)?.arrivedAt, arrival)
        XCTAssertNil(legacy.visit(for: last.id))
        let migrated = try TripRepository.migrate(legacy).selectedTrip!
        XCTAssertNil(migrated.visits[first.id]?.budgetAnchor)
        XCTAssertEqual(migrated.visits[current.id]?.arrivedAt, arrival)
    }

    func testLegacyInstructionsAndDeadlinesDecodeWithoutNewFields() throws {
        var old = stop("Destination")
        let withoutFields = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(Stop.self, from: withoutFields)
        XCTAssertNil(decoded.arriveBy)
        XCTAssertEqual(decoded.visitDuration, 300)
        XCTAssertTrue(decoded.arrivalInstructions.isEmpty)
        old.instructions = ["  First instruction  ", "", "Second instruction", " "]
        old.arriveBy = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = try JSONDecoder().decode(Stop.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(updated.arrivalInstructions, ["First instruction", "Second instruction"])
        XCTAssertEqual(updated.arriveBy, old.arriveBy)
    }

    func testLegacyTravelEstimatesOnlyMigrateMatchingCoordinatesAndModes() throws {
        let first = stop("First"), second = stop("Second")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let oldEstimate = TravelEstimate(sourceLatitude: first.latitude, sourceLongitude: first.longitude,
                                        destinationLatitude: second.latitude, destinationLongitude: second.longitude,
                                        mode: .cycling, seconds: 600, fetchedAt: date)
        let key = TravelLeg.key(from: first, to: second)
        var old = Itinerary(stops: [first, second], travelLegs: [key: TravelLeg(mode: .cycling, estimate: oldEstimate)])
        let migrated = try TripRepository.migrate(old, now: date).selectedTrip!
        XCTAssertEqual(migrated.plan.leg(from: first.id, to: second.id)?.mode, .cycling)
        XCTAssertEqual(migrated.plan.leg(from: first.id, to: second.id)?.estimate?.duration,
                       DurationRange(minimum: 600, maximum: 720))
        old.stops[1].latitude += 0.01
        let moved = try TripRepository.migrate(old, now: date).selectedTrip!
        XCTAssertNil(moved.plan.leg(from: first.id, to: second.id)?.estimate)
    }

    func testCardinalBearingsAndAntimeridian() {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        for (latitude, longitude, bearing) in [(1.0, 0.0, 0.0), (0, 1, 90), (-1, 0, 180), (0, -1, 270)] {
            XCTAssertEqual(CompassMath.bearing(from: origin, to: .init(latitude: latitude, longitude: longitude)), bearing, accuracy: 0.001)
        }
        XCTAssertEqual(CompassMath.bearing(from: .init(latitude: 0, longitude: 179.9),
                                          to: .init(latitude: 0, longitude: -179.9)), 90, accuracy: 0.001)
        let destination = CompassMath.coordinate(from: origin, meters: 1000, bearing: 270)
        XCTAssertEqual(CLLocation(latitude: 0, longitude: 0).distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude)),
                       1000, accuracy: 6)
    }
}
