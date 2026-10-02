import CoreLocation
import Combine

/// Incoming heading callbacks must belong to the current foreground sensor session.
/// This does not expire a stored, unchanged heading during an uninterrupted session.
struct HeadingObservationSession {
    private(set) var startedAt: Date?
    mutating func begin(at date: Date) { startedAt = date }
    mutating func end() { startedAt = nil }
    func accepts(_ timestamp: Date) -> Bool { startedAt.map { timestamp >= $0 } ?? false }
}

/// A sensor session. TripStore owns the navigation instance; editors use a foreground-only instance.
@MainActor
final class LocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var position: CLLocation?
    @Published private(set) var heading: Double?
    @Published private(set) var headingAccuracy: Double?
    @Published private(set) var message: String?
    private(set) var headingTimestamp: Date?
    var onLocations: (([CLLocation]) -> Void)?
    var headingAvailable: Bool { CLLocationManager.headingAvailable() }
    private let manager = CLLocationManager()
    private var running = false
    private var backgroundTracking = false
    private var foreground = true
    private var preciseLocation = true
    private var currentMode: TravelMode?
    private var headingSession = HeadingObservationSession()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingOrientation = .portrait
    }

    func start(backgroundTracking: Bool = false) {
        manager.stopUpdatingHeading()
        invalidateHeading()
        running = true
        self.backgroundTracking = backgroundTracking
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { activate() }
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if !value {
            manager.stopUpdatingHeading()
            invalidateHeading()
            if !backgroundTracking { manager.stopUpdatingLocation() }
        } else if running { activate() }
    }

    func updateMode(_ mode: TravelMode) {
        guard currentMode != mode else { return }
        currentMode = mode
        manager.activityType = mode == .driving ? .automotiveNavigation : .fitness
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        backgroundTracking = false
        invalidateHeading()
    }

    private func invalidateHeading() {
        headingSession.end()
        heading = nil
        headingAccuracy = nil
        headingTimestamp = nil
    }

    private func activate() {
        guard running else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            preciseLocation = manager.accuracyAuthorization == .fullAccuracy
            message = !preciseLocation ? "Enable Precise Location in Settings for accurate arrival detection." : nil
            #if !targetEnvironment(simulator)
            manager.allowsBackgroundLocationUpdates = backgroundTracking
            manager.showsBackgroundLocationIndicator = backgroundTracking
            #endif
            manager.pausesLocationUpdatesAutomatically = !backgroundTracking
            if foreground || backgroundTracking { manager.startUpdatingLocation() }
            if foreground && Self.headingAvailableOnDevice {
                if headingSession.startedAt == nil { headingSession.begin(at: Date()) }
                manager.startUpdatingHeading()
            }
        case .denied, .restricted:
            position = nil
            invalidateHeading()
            message = "Allow location access for WonderWhere in Settings."
        default: break
        }
    }

    private static var headingAvailableOnDevice: Bool { CLLocationManager.headingAvailable() }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { activate() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Preserve intermediate observations, including entry followed by an overshoot in one batch.
        let valid = locations.filter {
            CLLocationCoordinate2DIsValid($0.coordinate) && $0.horizontalAccuracy.isFinite && $0.horizontalAccuracy >= 0
        }.sorted { $0.timestamp < $1.timestamp }
        guard !valid.isEmpty else { return }
        if let newest = valid.last, position == nil || newest.timestamp >= position!.timestamp { position = newest }
        if preciseLocation { message = nil }
        onLocations?(valid)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard running, foreground, headingSession.accepts(newHeading.timestamp) else { return }
        acceptHeading(trueHeading: newHeading.trueHeading, accuracy: newHeading.headingAccuracy, timestamp: newHeading.timestamp)
    }

    func acceptHeading(trueHeading: Double, accuracy: Double, timestamp: Date, now: Date = Date()) {
        guard abs(timestamp.timeIntervalSince(now)) < 15,
              headingTimestamp == nil || timestamp >= headingTimestamp! else { return }
        headingTimestamp = timestamp
        headingAccuracy = accuracy
        // An unchanged heading stays usable within a continuous foreground sensor session.
        heading = trueHeading.isFinite && (0..<360).contains(trueHeading) &&
            accuracy.isFinite && (0..<90).contains(accuracy) ? trueHeading : nil
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        if running && (foreground || backgroundTracking) { manager.startUpdatingLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let error = error as? CLError {
            if error.code == .headingFailure {
                invalidateHeading()
                // Core Location may recover by delivering a later heading callback. Keep that
                // recovery path open while rejecting callbacks queued before the failure.
                if running && foreground { headingSession.begin(at: Date()) }
                return
            }
            if error.code == .locationUnknown { return }
        }
        position = nil
        invalidateHeading()
        if running && foreground { headingSession.begin(at: Date()) }
        message = "Location is unavailable. Check Location Services in Settings."
    }

    #if targetEnvironment(simulator)
    func inject(_ location: CLLocation, heading: Double, accuracy: Double = 1) {
        position = location
        acceptHeading(trueHeading: heading, accuracy: accuracy, timestamp: Date())
        onLocations?([location])
    }
    #endif
}
