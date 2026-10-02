import SwiftUI
import MapKit

struct StopEditor: View {
    var onSave: (Stop) -> Void
    @EnvironmentObject private var appearance: CompassAppearance
    @Environment(\.dismiss) private var dismiss
    @StateObject private var location = LocationService()
    @StateObject private var search = PlaceSearchModel()
    private let original: Stop?
    private let stopID: UUID
    @State private var name: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var address: String
    @State private var radiusFeet: Double
    @State private var query = ""
    @State private var showCoordinates = false
    @State private var gettingPosition = false
    @State private var selectionTask: Task<Void, Never>?
    @State private var searchFocused = false
    @State private var mapFocusID = UUID()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case latitude, longitude }

    init(stop: Stop?, onSave: @escaping (Stop) -> Void) {
        self.onSave = onSave
        original = stop
        stopID = stop?.id ?? UUID()
        _name = State(initialValue: stop?.name ?? "")
        _latitude = State(initialValue: stop.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: stop.map { String($0.longitude) } ?? "")
        _address = State(initialValue: stop?.address ?? "")
        _radiusFeet = State(initialValue: stop?.radiusFeet ?? 100)
    }

    private var draft: Stop? {
        guard let coordinate = enteredCoordinate else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Stop(id: stopID, name: trimmedName.isEmpty ? "Pinned location" : trimmedName,
                         latitude: coordinate.latitude, longitude: coordinate.longitude, radiusFeet: radiusFeet,
                         address: address, hint: original?.hint, instructions: original?.instructions,
                         durationMinutes: original?.durationMinutes, arriveBy: original?.arriveBy)
        return value.isValid ? value : nil
    }

    private var radiusLabel: String {
        if radiusFeet >= 5280 {
            return "\((radiusFeet / 5280).formatted(.number.precision(.fractionLength(0...2)))) mi"
        }
        return "\(radiusFeet.formatted(.number.precision(.fractionLength(0...1)))) ft"
    }

    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    NativePlaceSearchField(text: $query, isFocused: $searchFocused, onSearch: { search.update(query) })
                        .frame(height: 36)
                    if searchFocused || hasQuery {
                        Button("Cancel", action: endSearch).accessibilityIdentifier("cancel-place-search")
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
                    .onChange(of: query) { _, value in
                        selectionTask?.cancel(); stopLocating(); search.update(value)
                    }

                ZStack {
                    LocationSelectionMap(coordinate: Binding(get: { enteredCoordinate }, set: { selected in
                        guard let selected else { return }
                        setCoordinate(selected)
                    }), radiusFeet: $radiusFeet, color: UIColor(appearance.color), focusID: mapFocusID)
                    .overlay(alignment: .topTrailing) {
                        VStack(spacing: 12) {
                            Button { dismissKeyboard(); mapFocusID = UUID() } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
                            }.accessibilityLabel("Fit area").accessibilityIdentifier("fit-area")
                            Button(action: beginLocating) {
                                Image(systemName: "location").frame(width: 44, height: 44)
                            }.accessibilityLabel("Use current location").accessibilityIdentifier("current-location")
                        }.buttonStyle(.bordered).buttonBorderShape(.circle)
                            .background(.regularMaterial, in: Capsule()).padding(12)
                    }
                    if hasQuery { searchResults }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Radius").font(.caption).foregroundStyle(.secondary)
                            Text(radiusLabel).monospacedDigit().accessibilityIdentifier("area-radius")
                        }
                        Spacer()
                        Button { resizeRadius(by: 0.5) } label: {
                            Image(systemName: "minus").frame(width: 28, height: 28)
                        }.accessibilityLabel("Decrease radius").accessibilityIdentifier("decrease-radius")
                        Button { resizeRadius(by: 2) } label: {
                            Image(systemName: "plus").frame(width: 28, height: 28)
                        }.accessibilityLabel("Increase radius").accessibilityIdentifier("increase-radius")
                    }.buttonStyle(.bordered).buttonBorderShape(.circle)
                    if enteredCoordinate == nil {
                        Text("Tap the map or search to choose a location.").font(.footnote).foregroundStyle(.secondary)
                    } else if !address.isEmpty {
                        Text(address).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if gettingPosition {
                        Text(location.message ?? "Finding location…").font(.footnote).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Coordinates", isExpanded: $showCoordinates) {
                        VStack(spacing: 10) {
                            LabeledContent("Latitude") {
                                TextField("35.4676", text: coordinateText($latitude))
                                    .focused($focusedField, equals: .latitude).multilineTextAlignment(.trailing)
                                    .keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                                    .accessibilityIdentifier("latitude")
                            }
                            LabeledContent("Longitude") {
                                TextField("-97.5164", text: coordinateText($longitude))
                                    .focused($focusedField, equals: .longitude).multilineTextAlignment(.trailing)
                                    .keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                                    .accessibilityIdentifier("longitude")
                            }
                            if (!latitude.isEmpty || !longitude.isEmpty) && enteredCoordinate == nil {
                                Text("Latitude: −90 to 90. Longitude: −180 to 180.").font(.caption).foregroundStyle(.red)
                            }
                            Button("Show coordinates on map") { dismissKeyboard(); mapFocusID = UUID() }
                                .disabled(enteredCoordinate == nil)
                        }.padding(.top, 10)
                    }.font(.subheadline)
                }.padding(16).background(Color(uiColor: .systemBackground))
            }
            .navigationTitle("Location").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let draft else { return }
                        onSave(draft); dismiss()
                    }.disabled(draft == nil).accessibilityIdentifier("save-location")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done", action: dismissKeyboard)
                }
            }
            .onChange(of: location.position) { _, _ in capturePosition() }
            .onDisappear { location.stop(); selectionTask?.cancel(); search.cancel() }
        }
    }

    private var searchResults: some View {
        List {
            if let error = search.error {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                Button("Retry") { search.update(query) }
            }
            ForEach(Array(search.results.enumerated()), id: \.element) { index, result in
                Button { select(result) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(appearance.color).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.title).font(.body).foregroundStyle(.primary)
                            if !result.subtitle.isEmpty { Text(result.subtitle).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 4)
                }.accessibilityIdentifier("search-result-\(index)")
            }
            if !search.loading && !search.resolving && search.error == nil && search.results.isEmpty {
                Text("No results. Try a street address or include the city.").font(.subheadline).foregroundStyle(.secondary)
            }
        }.listStyle(.plain).scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                if search.loading || search.resolving {
                    ProgressView().padding(12).background(.regularMaterial, in: Capsule()).padding(16).allowsHitTesting(false)
                }
            }
    }

    private var enteredCoordinate: CLLocationCoordinate2D? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    private func coordinateText(_ binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; address = "" })
    }
    private func setCoordinate(_ coordinate: CLLocationCoordinate2D) {
        let firstSelection = enteredCoordinate == nil
        latitude = String(coordinate.latitude); longitude = String(coordinate.longitude); address = ""
        if firstSelection { mapFocusID = UUID() }
    }
    private func setRadiusFeet(_ feet: Double) {
        guard feet.isFinite, feet > 0, (feet * 0.3048).isFinite, feet * 0.3048 > 0 else { return }
        radiusFeet = feet
    }
    private func resizeRadius(by factor: Double) {
        dismissKeyboard(); setRadiusFeet(radiusFeet * factor); mapFocusID = UUID()
    }
    private func dismissKeyboard() { focusedField = nil; searchFocused = false }
    private func endSearch() {
        selectionTask?.cancel(); search.cancel(); query = ""; searchFocused = false
    }
    private func beginLocating() {
        endSearch(); focusedField = nil; gettingPosition = true; location.start(); capturePosition()
    }
    private func capturePosition() {
        guard gettingPosition, let position = location.position, position.horizontalAccuracy >= 0,
              position.horizontalAccuracy <= 100, abs(position.timestamp.timeIntervalSinceNow) < 15 else { return }
        setCoordinate(position.coordinate)
        if name.isEmpty { name = "Current location" }
        stopLocating(); mapFocusID = UUID()
    }
    private func stopLocating() { gettingPosition = false; location.stop() }
    private func select(_ completion: MKLocalSearchCompletion) {
        selectionTask?.cancel(); dismissKeyboard(); stopLocating()
        selectionTask = Task { @MainActor in
            guard let item = await search.resolve(completion), !Task.isCancelled else { return }
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = item.name ?? completion.title }
            latitude = String(item.placemark.coordinate.latitude); longitude = String(item.placemark.coordinate.longitude)
            address = [item.placemark.thoroughfare.map { [item.placemark.subThoroughfare, $0].compactMap { $0 }.joined(separator: " ") },
                       item.placemark.locality, item.placemark.administrativeArea, item.placemark.postalCode]
                .compactMap { $0 }.joined(separator: ", ")
            if address.isEmpty { address = completion.subtitle }
            query = ""; search.cancel(); mapFocusID = UUID()
        }
    }
}

final class PlaceSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    @Published var loading = false
    @Published var resolving = false
    @Published var error: String?
    private let completer = MKLocalSearchCompleter()
    private var activeSearch: MKLocalSearch?
    private var query = ""
    private var resolutionID: UUID?

    override init() {
        super.init()
        completer.delegate = self
        completer.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35.4676, longitude: -97.5164), latitudinalMeters: 60000, longitudinalMeters: 60000)
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelResolution()
        error = nil
        loading = !query.isEmpty
        if query.isEmpty { completer.cancel(); results = [] }
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard !query.isEmpty else { return }
        results = Array(completer.results.prefix(12))
        loading = false
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard !query.isEmpty else { return }
        loading = false
        self.error = "Search is unavailable. Check your connection or enter coordinates."
    }

    @MainActor func resolve(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        cancelResolution()
        let id = UUID()
        resolutionID = id
        resolving = true
        error = nil
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        activeSearch = search
        defer {
            if resolutionID == id { resolving = false; activeSearch = nil; resolutionID = nil }
        }
        do {
            let response = try await search.start()
            guard !Task.isCancelled, resolutionID == id else { return nil }
            guard let item = response.mapItems.first else {
                error = "Location not found. Try another result."
                return nil
            }
            return item
        } catch {
            if !Task.isCancelled, resolutionID == id { self.error = "Couldn’t load this place. Check your connection and try again." }
            return nil
        }
    }

    private func cancelResolution() {
        resolutionID = nil
        activeSearch?.cancel()
        activeSearch = nil
        resolving = false
    }

    func cancel() { completer.cancel(); cancelResolution() }
}

struct NativePlaceSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onSearch: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISearchTextField {
        let field = UISearchTextField()
        field.placeholder = "Place or address"
        field.accessibilityIdentifier = "place-search"
        field.autocorrectionType = .no
        field.returnKeyType = .search
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.clearButtonMode = .whileEditing
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: UISearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        // UIKit owns focus on touch-down. Only resign here after an explicit navigation action.
        if !isFocused && field.isFirstResponder { field.resignFirstResponder() }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativePlaceSearchField
        init(_ parent: NativePlaceSearchField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ textField: UITextField) { parent.isFocused = true }
        func textFieldDidEndEditing(_ textField: UITextField) { parent.isFocused = false }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { parent.onSearch(); return true }
        func textFieldShouldClear(_ textField: UITextField) -> Bool { parent.text = ""; return true }
    }
}


struct LocationSelectionMap: UIViewRepresentable {
    @Binding var coordinate: CLLocationCoordinate2D?
    @Binding var radiusFeet: Double
    let color: UIColor
    let focusID: UUID
    private var radiusMeters: Double { radiusFeet * 0.3048 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.accessibilityIdentifier = "location-map"
        map.isPitchEnabled = false
        map.pointOfInterestFilter = .includingAll
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.placePin(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let needsFit = coordinator.focusID != focusID
        coordinator.focusID = focusID
        coordinator.updateGeometry(in: map)
        if needsFit { coordinator.requestFit(in: map) }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: LocationSelectionMap
        var focusID: UUID?
        var pin: MKPointAnnotation?
        var radiusHandle: MKPointAnnotation?
        var circle: MKCircle?
        private var radiusObservation: NSKeyValueObservation?
        private var radiusDragging = false
        private var radiusBeforeDragging: Double?
        private var radiusBearing = Double.pi / 2
        private var bearingBeforeDragging = Double.pi / 2
        private var changingRegion = false
        private var pendingFit = false
        init(_ parent: LocationSelectionMap) { self.parent = parent }

        func updateGeometry(in map: MKMapView) {
            guard let coordinate = parent.coordinate else {
                if let pin { map.removeAnnotation(pin); self.pin = nil }
                if let radiusHandle { map.removeAnnotation(radiusHandle); self.radiusHandle = nil }
                radiusObservation = nil
                if let circle { map.removeOverlay(circle); self.circle = nil }
                return
            }
            if let pin {
                let view = map.view(for: pin) as? MKMarkerAnnotationView
                let dragging = view?.dragState == .starting || view?.dragState == .dragging
                if !dragging && (pin.coordinate.latitude != coordinate.latitude || pin.coordinate.longitude != coordinate.longitude) {
                    pin.coordinate = coordinate
                }
                view?.markerTintColor = parent.color
            } else {
                let pin = MKPointAnnotation(); pin.coordinate = coordinate; pin.title = "Selected location"
                self.pin = pin; map.addAnnotation(pin)
            }
            // The stored radius is unrestricted. MapKit can only display the mappable world.
            let displayRadius = min(max(0, parent.radiusMeters), 20_037_508)
            let edge = radiusCoordinate(center: coordinate, radius: displayRadius)
            if let radiusHandle {
                if !radiusDragging { radiusHandle.coordinate = edge }
                (map.view(for: radiusHandle) as? MKMarkerAnnotationView)?.markerTintColor = parent.color
            } else {
                let handle = MKPointAnnotation(); handle.coordinate = edge; handle.title = "Radius"
                radiusHandle = handle
                radiusObservation = handle.observe(\.coordinate, options: [.new]) { [weak self, weak map] annotation, _ in
                    guard let self, let map, self.radiusDragging else { return }
                    self.updateRadius(from: annotation.coordinate, in: map)
                }
                map.addAnnotation(handle)
            }
            if let circle, circle.coordinate.latitude == coordinate.latitude, circle.coordinate.longitude == coordinate.longitude,
               circle.radius == displayRadius {
                if let renderer = map.renderer(for: circle) as? MKCircleRenderer {
                    renderer.fillColor = parent.color.withAlphaComponent(0.16)
                    renderer.strokeColor = parent.color.withAlphaComponent(0.8)
                    renderer.setNeedsDisplay()
                }
                return
            }
            if let circle { map.removeOverlay(circle) }
            let circle = MKCircle(center: coordinate, radius: displayRadius)
            self.circle = circle; map.addOverlay(circle)
        }

        func requestFit(in map: MKMapView) {
            if changingRegion || radiusDragging { pendingFit = true; return }
            fit(in: map)
        }
        private func fit(in map: MKMapView) {
            pendingFit = false
            let center = parent.coordinate ?? CLLocationCoordinate2D(latitude: 35.4676, longitude: -97.5164)
            let mapPoint = MKMapPoint(center)
            let pointsPerMeter = MKMapPointsPerMeterAtLatitude(center.latitude)
            let meters = parent.coordinate == nil ? 700 : max(30, min(parent.radiusMeters, 20_037_508) * 3)
            let minimumSpan = min(MKMapRect.world.size.width, max(1, pointsPerMeter * meters))
            var rect = MKMapRect(x: mapPoint.x - minimumSpan / 2, y: mapPoint.y - minimumSpan / 2,
                                 width: minimumSpan, height: minimumSpan)
            if let circle { rect = rect.union(circle.boundingMapRect) }
            if !rect.origin.x.isFinite || !rect.origin.y.isFinite || !rect.size.width.isFinite || !rect.size.height.isFinite {
                rect = .world
            } else {
                rect = rect.intersection(.world)
                if rect.isNull || rect.isEmpty { rect = .world }
            }
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24), animated: map.window != nil)
        }
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) { changingRegion = true }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            changingRegion = false
            if pendingFit && !radiusDragging { fit(in: mapView) }
        }
        @objc func placePin(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let map = gesture.view as? MKMapView else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            parent.coordinate = coordinate
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is MKAnnotationView || current is UIControl { return false }
                view = current.superview
            }
            return true
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is MKPointAnnotation else { return nil }
            let isRadius = (annotation as AnyObject) === radiusHandle
            let identifier = isRadius ? "radius-handle" : "selected-pin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation; view.markerTintColor = parent.color; view.isDraggable = true
            view.canShowCallout = false; view.displayPriority = .required
            view.glyphImage = isRadius ? UIImage(systemName: "arrow.left.and.right") : nil
            view.titleVisibility = .hidden
            view.accessibilityLabel = isRadius ? "Radius handle" : "Selected location pin"
            view.accessibilityHint = isRadius ? "Touch and hold, then drag to resize the area." : "Touch and hold, then drag to move the center."
            view.accessibilityIdentifier = identifier
            return view
        }
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            if (view.annotation as AnyObject?) === radiusHandle {
                if newState == .starting || newState == .dragging {
                    if !radiusDragging {
                        radiusBeforeDragging = parent.radiusFeet
                        bearingBeforeDragging = radiusBearing
                    }
                    radiusDragging = true
                }
                else if newState == .ending || newState == .canceling {
                    if newState == .ending, let coordinate = view.annotation?.coordinate {
                        updateRadius(from: coordinate, in: mapView)
                    } else if let radiusBeforeDragging {
                        parent.radiusFeet = radiusBeforeDragging
                        radiusBearing = bearingBeforeDragging
                    }
                    radiusDragging = false
                    radiusBeforeDragging = nil
                    view.setDragState(.none, animated: false)
                    updateGeometry(in: mapView)
                    if pendingFit && !changingRegion { fit(in: mapView) }
                }
                return
            }
            if newState == .ending {
                if let coordinate = view.annotation?.coordinate { parent.coordinate = coordinate }
                view.setDragState(.none, animated: false)
            } else if newState == .canceling { view.setDragState(.none, animated: false) }
        }
        private func updateRadius(from coordinate: CLLocationCoordinate2D, in map: MKMapView) {
            guard let center = parent.coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return }
            let meters = CLLocation(latitude: center.latitude, longitude: center.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard meters.isFinite, meters > 0 else { return }
            let startLatitude = center.latitude * .pi / 180
            let endLatitude = coordinate.latitude * .pi / 180
            let longitudeChange = (coordinate.longitude - center.longitude) * .pi / 180
            radiusBearing = atan2(sin(longitudeChange) * cos(endLatitude),
                                  cos(startLatitude) * sin(endLatitude) - sin(startLatitude) * cos(endLatitude) * cos(longitudeChange))
            parent.radiusFeet = meters / 0.3048
            updateGeometry(in: map)
        }
        private func radiusCoordinate(center: CLLocationCoordinate2D, radius: Double) -> CLLocationCoordinate2D {
            let angularDistance = radius / 6_378_137
            let latitude = center.latitude * .pi / 180
            let longitude = center.longitude * .pi / 180
            let endLatitude = asin(max(-1, min(1, sin(latitude) * cos(angularDistance) + cos(latitude) * sin(angularDistance) * cos(radiusBearing))))
            let endLongitude = longitude + atan2(sin(radiusBearing) * sin(angularDistance) * cos(latitude),
                                                cos(angularDistance) - sin(latitude) * sin(endLatitude))
            let wrappedLongitude = (endLongitude * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
            return CLLocationCoordinate2D(latitude: endLatitude * 180 / .pi, longitude: wrappedLongitude)
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = parent.color.withAlphaComponent(0.16)
            renderer.strokeColor = parent.color.withAlphaComponent(0.8)
            renderer.lineWidth = 2
            return renderer
        }
    }
}
