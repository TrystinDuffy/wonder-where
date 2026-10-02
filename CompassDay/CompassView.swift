import SwiftUI
import CoreLocation
import MapKit

struct CompassView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var access: ConfigurationAccess
    var onOpenHome: () -> Void
    @State private var reviewID: UUID?
    @State private var showPIN = false
    @State private var confirmReveal = false

    private var trip: Trip? { store.activeTrip ?? store.selectedTrip }
    private var reviews: [VisitRecord] {
        (trip?.visits.values.map { $0 } ?? []).filter { $0.arrivedAt != nil || $0.completed }
            .sorted { ($0.arrivedAt ?? .distantPast) < ($1.arrivedAt ?? .distantPast) }
    }
    private var review: VisitRecord? { reviewID.flatMap { trip?.visits[$0] } }

    var body: some View {
        GeometryReader { viewport in
            let frame = viewport.frame(in: .global)
            let screenCenterY = frame.midY + (viewport.safeAreaInsets.bottom - viewport.safeAreaInsets.top) / 2
            navigation(screenCenterY: screenCenterY)
        }
        .sheet(isPresented: $showPIN) {
            ConfigurationUnlockView(onUnlock: { showPIN = false; onOpenHome() }, onCancel: { showPIN = false }, destinationName: "Home")
                .environmentObject(access)
        }
        .alert("Open Home?", isPresented: $confirmReveal) {
            Button("Cancel", role: .cancel) { }
            Button("Open Home") { onOpenHome() }
        } message: { Text("Home shows your saved trips and destinations.") }
    }

    private func navigation(screenCenterY: CGFloat) -> some View {
        NavigationStack {
            if let trip {
                VStack(spacing: 12) {
                    CompassProgress(trip: trip, schedules: store.schedules)
                    CompassReadout(trip: trip, review: review, location: store.location,
                                   screenCenterY: screenCenterY, onOpenHome: requestHome)
                    HStack(spacing: 16) {
                        Button("Back", systemImage: "chevron.left") { showPrevious() }
                            .buttonStyle(.bordered).disabled(previousReviewID == nil)
                            .accessibilityIdentifier("previous-place")
                        Spacer(minLength: 16)
                        if reviewID != nil {
                            Button("Resume navigation") { reviewID = nil }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("resume-navigation")
                        } else {
                            Button(trip.phase?.kind == .exiting ? "Going to Exit" : "Next") {
                                if let phase = trip.phase { store.next(tripID: trip.id, phase: phase) }
                            }.buttonStyle(.borderedProminent)
                                .disabled(trip.phase?.kind != .exploring)
                                .accessibilityIdentifier("next-place")
                        }
                    }.controlSize(.large)
                    #if targetEnvironment(simulator)
                    SimulatorPositionControls(location: store.location)
                    #endif
                }.padding(.horizontal, 20).padding(.bottom, 12)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Home", systemImage: "house") { requestHome() }
                                .accessibilityIdentifier("open-home")
                        }
                    }
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("No active trip", systemImage: "location")
                Button("Home", systemImage: "house", action: requestHome)
                    .accessibilityIdentifier("open-home")
            }
        }
    }

    private var previousReviewID: UUID? {
        let candidates = reviews.filter { $0.place.id != trip?.activePlaceID || trip?.status != .active }
        if let reviewID, let index = candidates.firstIndex(where: { $0.place.id == reviewID }) {
            return index > 0 ? candidates[index - 1].place.id : nil
        }
        return candidates.last?.place.id
    }
    private func showPrevious() { reviewID = previousReviewID }
    private func requestHome() {
        if access.hasPIN { showPIN = true } else { confirmReveal = true }
    }
}

private struct CompassProgress: View {
    let trip: Trip
    @ObservedObject var schedules: TripSchedules
    var body: some View {
        HStack {
            Text("\(trip.visitedCount)/\(trip.includedPlaces.count) Places").font(.subheadline.monospacedDigit())
                .accessibilityIdentifier("places-progress")
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Est. completion").font(.caption)
                Text(completionText(schedules.values[trip.id]?.completion, timeZoneIdentifier: trip.timeZoneIdentifier)).font(.caption.monospacedDigit())
                if schedules.values[trip.id]?.isRunningBehind == true {
                    Text("Running behind").foregroundStyle(.orange).font(.caption)
                }
            }.foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .accessibilityIdentifier("estimated-completion")
        }.frame(minHeight: 48)
    }
}

private struct CompassReadout: View {
    let trip: Trip
    let review: VisitRecord?
    let location: LocationService
    let screenCenterY: CGFloat
    let onOpenHome: () -> Void
    @EnvironmentObject private var appearance: CompassAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var revealedPlace: Place? {
        if let review { return review.place }
        guard !isFinished else { return nil }
        guard let visit = trip.activeVisit else { return nil }
        let inVisit = trip.phase?.kind == .exploring || trip.phase?.kind == .exiting
        guard visit.arrivedAt != nil || visit.arrivalManual || visit.completed || inVisit else { return nil }
        return trip.activePlace
    }

    private var isFinished: Bool { trip.status == .completed || trip.status == .canceled }

    private enum HeroPresentation: Equatable {
        case compass
        case map(UUID)
        case finished(completed: Bool)
    }

    private var heroPresentation: HeroPresentation {
        if let place = revealedPlace { return .map(place.id) }
        if isFinished { return .finished(completed: trip.status == .completed) }
        return .compass
    }

    private enum ReadingContext: Equatable {
        case navigation(UUID?)
        case history(UUID)
    }

    private var readingContext: ReadingContext {
        if let review { return .history(review.place.id) }
        return .navigation(trip.activePlaceID)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 12) {
                        hero(width: geometry.size.width)
                        if review != nil {
                            Text("Previous visit").font(.subheadline).foregroundStyle(.secondary)
                                .frame(height: 52)
                        } else if isFinished {
                            Color.clear.frame(height: 52)
                        } else {
                            LiveCompassDistance(trip: trip, location: location)
                        }
                        VStack(spacing: 16) {
                            if let review {
                                PlaceArrivalDetails(place: review.place, completed: review.completed)
                                if let date = review.arrivedAt {
                                    Text(date, format: .dateTime.month().day().hour().minute())
                                        .foregroundStyle(.secondary)
                                }
                            } else if isFinished {
                                Text(trip.status == .completed ? "Complete" : "Trip canceled")
                                    .font(.largeTitle.weight(.semibold))
                                    .accessibilityIdentifier("trip-complete")
                                Button("Back to Home", action: onOpenHome).buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("back-home")
                            } else if let place = revealedPlace {
                                PlaceArrivalDetails(place: place, visit: trip.activeVisit,
                                                    allocation: trip.allocation(for: place.id), completed: false)
                                if trip.phase?.kind == .exiting {
                                    Text("Continue to Exit").font(.subheadline).foregroundStyle(.secondary)
                                }
                            } else if let hint = trip.activePlace?.navigationHint {
                                Text(hint).multilineTextAlignment(.center).accessibilityIdentifier("navigation-hint")
                            }
                            if review == nil && !isFinished {
                                CompassLocationMessage(location: location)
                            }
                        }.frame(maxWidth: .infinity)
                    }
                    .padding(.top, max(0, screenCenterY - geometry.frame(in: .global).minY - 120))
                    .frame(width: geometry.size.width, alignment: .top)
                    .id("navigation-top")
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: readingContext) { _, _ in
                    scroll.scrollTo("navigation-top", anchor: .top)
                }
            }
        }
    }

    private func hero(width: CGFloat) -> some View {
        ZStack {
            if let place = revealedPlace {
                ArrivalPlaceMap(name: place.name, center: place.explore.center, color: appearance.color)
                    .equatable()
                    .overlay(alignment: .bottomTrailing) {
                        if review == nil {
                            LiveCompassSymbol(trip: trip, location: location, compact: true)
                                .padding(10).allowsHitTesting(false)
                        }
                    }
                    .id(place.id)
                    .transition(.opacity)
            } else if isFinished {
                Image(systemName: trip.status == .completed ? "checkmark.circle" : "stop.circle")
                    .font(.system(size: 76)).foregroundStyle(appearance.color)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
            } else {
                LiveCompassSymbol(trip: trip, location: location)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        // Navigation, history, and completion keep the same surface alive. Its
        // current content drives both directions; heading samples stay immediate.
        .geometryGroup()
        .frame(width: revealedPlace == nil ? 240 : width, height: 240)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: revealedPlace == nil ? 120 : 16))
        .animation(reduceMotion ? nil : .default, value: heroPresentation)
        .frame(maxWidth: .infinity)
    }
}

private struct LiveCompassSymbol: View {
    let trip: Trip
    @ObservedObject var location: LocationService
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let sample = location.navigationSample(for: trip)
            let guidance = TripNavigation.guidance(trip: trip, sample: sample, now: context.date)
            if compact { MapGuidanceBadge(guidance: guidance) }
            else { GuidanceHero(guidance: guidance) }
        }
    }
}

private struct LiveCompassDistance: View {
    let trip: Trip
    @ObservedObject var location: LocationService
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let sample = location.navigationSample(for: trip)
            VStack(spacing: 5) {
                if let sample, sample.isFresh(at: context.date), let target = trip.currentTargetArea {
                    let indicator = DistanceIndicator(meters: sample.point.distance(to: target.center))
                    Label(indicator.label, systemImage: indicator.symbol).font(.title3.monospacedDigit())
                    Text("GPS ±\(Int(sample.accuracy / 0.3048)) ft · Area \(target.radiusLabel)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("gps-accuracy")
                } else {
                    Text("— mi").font(.title3)
                    Text("Waiting for location").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(height: 52)
        }
    }
}

private extension LocationService {
    func navigationSample(for trip: Trip) -> LiveSample? {
        guard let position, let session = trip.trackingSessionID else { return nil }
        return LiveSample(location: position, sessionID: session, trueHeading: heading,
                          headingAccuracy: headingAccuracy, headingTimestamp: headingTimestamp)
    }
}

private struct MapGuidanceBadge: View {
    let guidance: TripGuidance
    @EnvironmentObject private var appearance: CompassAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        switch guidance {
        case let .direction(degrees, _):
            CompassSymbol(icon: appearance.icon, color: appearance.color)
                .frame(width: 18, height: 42).rotationEffect(.degrees(degrees))
                .frame(width: 64, height: 64)
                .background(.regularMaterial, in: Circle())
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("compass-arrow")
                .accessibilityLabel("Compass \(Int(degrees)) degrees")
        case .arrived:
            Label("Arrived", systemImage: "checkmark")
                .font(.subheadline.weight(.medium)).padding(10)
                .background(.regularMaterial, in: Capsule())
                .accessibilityIdentifier("arrival-symbol")
        case .searching:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2).frame(width: 64, height: 64)
                .background(.regularMaterial, in: Circle())
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityIdentifier("gps-search-symbol")
                .accessibilityLabel("Finding position and direction")
        }
    }
}

private struct CompassLocationMessage: View {
    @ObservedObject var location: LocationService
    var body: some View {
        if let message = location.message {
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

private struct GuidanceHero: View {
    let guidance: TripGuidance
    @EnvironmentObject private var appearance: CompassAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var symbol: Int {
        switch guidance { case .direction: return 0; case .arrived: return 1; case .searching: return 2 }
    }
    var body: some View {
        ZStack {
            if case let .direction(degrees, _) = guidance {
                ZStack {
                    CompassBorderView(style: appearance.border)
                    CompassSymbol(icon: appearance.icon, color: appearance.color).frame(width: 65, height: 155)
                        .rotationEffect(.degrees(degrees))
                }.frame(width: 230, height: 230)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("compass-arrow")
                    .accessibilityLabel("Compass \(Int(degrees)) degrees")
                    .transition(.opacity)
            }
            if symbol == 1 {
                VStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 95)).foregroundStyle(appearance.color)
                    Text("Arrived").font(.headline).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
                    .accessibilityIdentifier("arrival-symbol").transition(.opacity)
            }
            if symbol == 2 {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 76)).foregroundStyle(appearance.color)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    Text("Finding position and direction").font(.subheadline).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
                    .accessibilityIdentifier("gps-search-symbol").transition(.opacity)
            }
        }.animation(reduceMotion ? nil : .default, value: symbol)
            .allowsHitTesting(false)
    }
}

private struct PlaceArrivalDetails: View {
    let place: Place
    var visit: VisitRecord? = nil
    var allocation: Int = 0
    let completed: Bool
    var body: some View {
        VStack(spacing: 14) {
            Text(place.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                .accessibilityIdentifier("arrival-name")
            if completed { Label("Visit complete", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            else if let visit { VisitCountdown(visit: visit, allocation: allocation) }
            ForEach(Array(place.arrivalInstructions.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1).").fontWeight(.semibold).foregroundStyle(.secondary)
                    Text(text).frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("arrival-instruction-\(index)")
            }
        }.frame(maxWidth: .infinity)
    }
}

private struct VisitCountdown: View {
    let visit: VisitRecord
    let allocation: Int
    var body: some View {
        if let anchor = visit.budgetAnchor {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = anchor.addingTimeInterval(Double(allocation)).timeIntervalSince(visit.exitedAt ?? context.date)
                let seconds = max(0, Int(ceil(remaining)))
                VStack(spacing: 8) {
                    Label(remaining < 0 ? "Over allocated time" : String(format: "%d:%02d remaining", seconds / 60, seconds % 60), systemImage: "timer")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(remaining < 0 ? .orange : .secondary)
                        .accessibilityIdentifier("visit-countdown")
                    if anchor > context.date {
                        Text("Visit begins \(anchor.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// The camera depends only on the revealed place, never on live heading or distance.
/// A native button owns the tap; the map is a preview rather than another scroll surface.
private struct ArrivalPlaceMap: View, Equatable {
    let name: String
    let center: Point
    let color: Color
    @State private var mapsUnavailable = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.center == rhs.center && lhs.color == rhs.color
    }

    private var camera: MapCamera {
        MapCamera(centerCoordinate: center.coordinate, distance: 500, heading: 0, pitch: 60)
    }

    var body: some View {
        Button {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: center.coordinate))
            item.name = name
            let camera = MKMapCamera(lookingAtCenter: center.coordinate, fromDistance: 500, pitch: 60, heading: 0)
            mapsUnavailable = !item.openInMaps(launchOptions: [MKLaunchOptionsCameraKey: camera])
        } label: {
            ZStack(alignment: .topTrailing) {
                Map(position: .constant(.camera(camera)), interactionModes: []) {
                    Marker(name, coordinate: center.coordinate).tint(color)
                }
                .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
                .mapControlVisibility(.hidden)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                Label("Apple Maps", systemImage: "arrow.up.right")
                    .font(.caption.weight(.medium)).padding(8)
                    .background(.regularMaterial, in: Capsule()).padding(10)
            }
            .frame(height: 240)
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(name) in Apple Maps")
        .accessibilityHint("Shows a close-up map of this place’s Explore area")
        .accessibilityIdentifier("arrival-map")
        .alert("Apple Maps unavailable", isPresented: $mapsUnavailable) {
            Button("OK", role: .cancel) { }
        } message: { Text("Apple Maps could not be opened. Check that the Maps app is installed on this iPhone.") }
    }
}

#if targetEnvironment(simulator)
private struct SimulatorPositionControls: View {
    @ObservedObject var location: LocationService
    @State private var latitude = "35.4676"
    @State private var longitude = "-97.5164"
    @State private var heading = 0.0
    @State private var accuracy = 3.0
    @State private var expanded = false
    @FocusState private var editingCoordinate: Bool
    var body: some View {
        DisclosureGroup("Simulator location", isExpanded: $expanded) {
            VStack(spacing: 8) {
                HStack {
                    TextField("Latitude", text: $latitude).focused($editingCoordinate).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("simulator-latitude")
                    TextField("Longitude", text: $longitude).focused($editingCoordinate).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("simulator-longitude")
                    Button("Apply") { editingCoordinate = false; inject() }.accessibilityIdentifier("apply-simulator-position")
                }.textFieldStyle(.roundedBorder)
                Slider(value: $heading, in: 0...360).accessibilityLabel("Phone heading").accessibilityIdentifier("simulator-heading")
                Picker("GPS accuracy", selection: $accuracy) { Text("±3 m").tag(3.0); Text("±300 m").tag(300.0) }.pickerStyle(.segmented)
            }
        }.font(.caption)
            .onAppear {
                if let position = location.position {
                    latitude = String(position.coordinate.latitude); longitude = String(position.coordinate.longitude)
                }
            }
            .onChange(of: heading) { _, _ in inject() }
            .onChange(of: accuracy) { _, _ in inject() }
            .task {
                while !Task.isCancelled {
                    inject()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
    }
    private func inject() {
        guard let lat = Double(latitude), let lon = Double(longitude), (-90...90).contains(lat), (-180...180).contains(lon) else { return }
        location.inject(CLLocation(coordinate: .init(latitude: lat, longitude: lon), altitude: 0,
                                   horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: Date()), heading: heading.truncatingRemainder(dividingBy: 360))
    }
}
#endif
