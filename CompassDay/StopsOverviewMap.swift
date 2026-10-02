import SwiftUI
import MapKit

struct StopsOverviewMap: UIViewRepresentable {
    let stops: [Stop]
    let color: UIColor
    let onEdit: (Stop) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> OverviewMapView {
        let map = OverviewMapView()
        let configuration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = configuration
        map.showsBuildings = true
        map.showsCompass = true
        map.tintColor = .secondaryLabel
        map.isPitchEnabled = true
        map.delegate = context.coordinator
        map.accessibilityIdentifier = "stops-overview-map"
        map.accessibilityLabel = "All places map"
        map.onSizeChange = { [weak coordinator = context.coordinator] map in
            coordinator?.fitAll(map)
        }
        var buttonConfiguration = UIButton.Configuration.plain()
        buttonConfiguration.title = "Fit all"
        buttonConfiguration.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        buttonConfiguration.imagePadding = 8
        buttonConfiguration.baseForegroundColor = .label
        buttonConfiguration.background.backgroundColor = .secondarySystemGroupedBackground
        buttonConfiguration.cornerStyle = .capsule
        buttonConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        let fitButton = UIButton(configuration: buttonConfiguration)
        fitButton.accessibilityIdentifier = "fit-all-stops"
        fitButton.addAction(UIAction { [weak map, weak coordinator = context.coordinator] _ in
            guard let map else { return }
            coordinator?.restoreOverview(map)
        }, for: .touchUpInside)
        fitButton.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(fitButton)
        NSLayoutConstraint.activate([
            fitButton.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -16),
            fitButton.bottomAnchor.constraint(equalTo: map.bottomAnchor, constant: -16)
        ])
        return map
    }

    func updateUIView(_ map: OverviewMapView, context: Context) {
        let coordinator = context.coordinator
        let positionsChanged = coordinator.positions != stops.map { "\($0.id):\($0.latitude):\($0.longitude)" }
        let dataChanged = coordinator.parent.stops != stops || map.annotations.isEmpty
        coordinator.parent = self
        if dataChanged {
            map.removeAnnotations(map.annotations)
            map.addAnnotations(stops.enumerated().map { NumberedStop(stop: $0.element, number: $0.offset + 1) })
        }
        for annotation in map.annotations {
            (map.view(for: annotation) as? MKMarkerAnnotationView)?.markerTintColor = color
        }
        if positionsChanged {
            coordinator.positions = stops.map { "\($0.id):\($0.latitude):\($0.longitude)" }
            map.removeOverlays(map.overlays)
            if stops.count > 1 {
                let coordinates = stops.map(\.coordinate)
                map.addOverlay(MKPolyline(coordinates: coordinates, count: coordinates.count), level: .aboveRoads)
            }
        }
        if positionsChanged { coordinator.fitAll(map) }
    }

    final class OverviewMapView: MKMapView {
        var onSizeChange: ((MKMapView) -> Void)?
        private var previousSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != previousSize, bounds.width > 0, bounds.height > 0 else { return }
            previousSize = bounds.size
            onSizeChange?(self)
        }
    }

    final class NumberedStop: NSObject, MKAnnotation {
        let stop: Stop
        let number: Int
        var coordinate: CLLocationCoordinate2D { stop.coordinate }
        var title: String? { stop.name }
        init(stop: Stop, number: Int) { self.stop = stop; self.number = number }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: StopsOverviewMap
        var positions: [String] = []
        private var overviewCamera: MKMapCamera?
        init(_ parent: StopsOverviewMap) { self.parent = parent }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let stop = annotation as? NumberedStop else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "overview-stop") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "overview-stop")
            view.annotation = annotation
            view.markerTintColor = parent.color
            view.glyphTintColor = .white
            view.glyphText = "\(stop.number)"
            view.titleVisibility = .hidden
            view.subtitleVisibility = .hidden
            view.displayPriority = .required
            view.canShowCallout = true
            view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
            view.accessibilityIdentifier = "overview-stop-\(stop.number)"
            view.accessibilityLabel = "\(stop.number). \(stop.stop.name)"
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            guard let annotation = view.annotation as? NumberedStop else { return }
            parent.onEdit(annotation.stop)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = UIColor.secondaryLabel.withAlphaComponent(0.55)
            renderer.lineWidth = 2.5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func restoreOverview(_ map: MKMapView) {
            guard let camera = overviewCamera else { fitAll(map); return }
            map.setCamera(camera, animated: !UIAccessibility.isReduceMotionEnabled)
        }

        func fitAll(_ map: MKMapView) {
            guard !parent.stops.isEmpty, map.bounds.width > 100, map.bounds.height > 100 else { return }
            let previousCamera = map.camera.copy() as! MKMapCamera
            let shouldAnimate = overviewCamera != nil && !UIAccessibility.isReduceMotionEnabled
            var rect = MKMapRect.null
            for stop in parent.stops {
                let point = MKMapPoint(stop.coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
            let minimumSpan = 350 * MKMapPointsPerMeterAtLatitude(parent.stops[0].latitude)
            rect = rect.insetBy(dx: -max(0, minimumSpan - rect.width) / 2,
                                dy: -max(0, minimumSpan - rect.height) / 2)
            let padding = UIEdgeInsets(top: 80, left: 50, bottom: 80, right: 50)
            let flatCamera = previousCamera.copy() as! MKMapCamera
            flatCamera.pitch = 0
            flatCamera.heading = 0
            map.setCamera(flatCamera, animated: false)
            map.setVisibleMapRect(rect, edgePadding: padding, animated: false)
            let tiltedCamera = map.camera.copy() as! MKMapCamera
            tiltedCamera.heading = 0
            tiltedCamera.pitch = 45
            map.setCamera(tiltedCamera, animated: false)

            // Calculate the fitted camera synchronously, before rendering another frame.
            // Only the final camera change gets MapKit's native animation.
            let safeRect = map.bounds.inset(by: padding)
            if safeRect.width > 0, safeRect.height > 0 {
                for _ in 0..<12 {
                    let points = parent.stops.map { map.convert($0.coordinate, toPointTo: map) }
                    guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { break }
                    if points.allSatisfy({ safeRect.contains($0) }) { break }
                    let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
                    let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
                    let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
                    let camera = map.camera.copy() as! MKMapCamera
                    camera.centerCoordinate = map.convert(center, toCoordinateFrom: map)
                    let scale = max((maxX - minX) / safeRect.width, (maxY - minY) / safeRect.height)
                    camera.centerCoordinateDistance *= max(1.08, scale * 1.05)
                    map.setCamera(camera, animated: false)
                }
            }
            let fittedCamera = map.camera.copy() as! MKMapCamera
            overviewCamera = fittedCamera
            if shouldAnimate { map.setCamera(previousCamera, animated: false) }
            map.setCamera(fittedCamera, animated: shouldAnimate)
        }
    }
}
