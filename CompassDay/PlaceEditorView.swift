import SwiftUI
import MapKit

struct PlaceEditorView: View {
    let original: Place
    var onSave: (Place, @escaping (Bool) -> Void) -> Void
    var readOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Place
    @State private var editingArea: AreaChoice?
    @State private var saving = false
    @State private var saveError: String?
    @State private var hasLocation: Bool

    init(place: Place?, readOnly: Bool = false, onSave: @escaping (Place, @escaping (Bool) -> Void) -> Void) {
        // This empty draft is never eligible to save until the user selects real geometry.
        let point = Point(name: "", latitude: 0, longitude: 0)
        let value = place ?? Place(name: "",
                                  entry: Area(name: "Entry", center: point, radiusMeters: 30.48),
                                  explore: Area(name: "Explore", center: point, radiusMeters: 30.48),
                                  exit: Area(name: "Exit", center: point, radiusMeters: 30.48))
        original = value
        self.readOnly = readOnly
        self.onSave = onSave
        _draft = State(initialValue: value)
        _hasLocation = State(initialValue: place != nil)
    }

    var body: some View {
        if readOnly {
            NavigationStack {
                Form {
                    Section {
                        PlaceAreasPreview(areas: original.usesEntryForAllAreas ? [original.entry] : [original.entry, original.explore, original.exit])
                            .frame(height: 220).listRowInsets(EdgeInsets())
                    }
                    PlaceSnapshotSections(place: original)
                }
                    .navigationTitle("Place details").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    }
            }
        } else { editor }
    }

    private var editor: some View {
        NavigationStack {
            Form {
                Section {
                    Button { editingArea = .entry } label: {
                        if hasLocation {
                            PlaceAreasPreview(areas: draft.usesEntryForAllAreas ? [draft.entry] : [draft.entry, draft.explore, draft.exit])
                                .frame(height: 220)
                                .overlay(alignment: .bottomTrailing) {
                                    Label("Edit location", systemImage: "map")
                                        .font(.subheadline).padding(10).background(.regularMaterial, in: Capsule()).padding(12)
                                }
                        } else {
                            ContentUnavailableView("Set location", systemImage: "mappin.and.ellipse")
                                .frame(height: 180)
                        }
                    }.buttonStyle(.plain).listRowInsets(EdgeInsets())
                        .accessibilityLabel("Edit place on map").accessibilityIdentifier("place-area-map")
                    TextField("Name", text: $draft.name).accessibilityIdentifier("place-name")
                        .accessibilityLabel("Name shown on arrival")
                    if !draft.address.isEmpty {
                        Text(draft.address).font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: { Text("Place") }
                Section {
                    Toggle("Use Entry for all areas", isOn: Binding(get: {
                        draft.usesEntryForAllAreas
                    }, set: { draft.setUsesEntryForAllAreas($0) }))
                        .accessibilityIdentifier("shared-entry-area")
                    areaRow(.entry)
                    if !draft.usesEntryForAllAreas {
                        areaRow(.explore)
                        areaRow(.exit)
                    }
                } header: { Text("Areas") }
                footer: { Text("Turn off to give Explore and Exit their own locations and radii.") }
                Section {
                    DurationFields(duration: $draft.duration)
                    Toggle("Optional place", isOn: $draft.isOptional)
                    if draft.isOptional {
                        Stepper("Keep priority: \(draft.keepPriority)", value: $draft.keepPriority, in: 0...100)
                        Text("Lower priorities are skipped first. Places needed to change travel mode are kept.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Time here") } footer: {
                    Text(draft.duration.isFixed
                         ? "This full visit duration is allocated. Enable Flexible duration to allow the schedule to shorten it."
                         : "The schedule starts with the maximum and can shorten the visit to its minimum. The trip shows how much time is currently allocated.")
                }
                Section {
                    ForEach(TimeRequirement.Kind.allCases, id: \.self) { kind in
                        Toggle(kind.displayName, isOn: Binding(get: {
                            draft.requirements.contains { $0.kind == kind }
                        }, set: { enabled in
                            if enabled { draft.requirements.append(TimeRequirement(kind: kind, label: "\(draft.name) — \(kind.displayName)")) }
                            else { draft.requirements.removeAll { $0.kind == kind } }
                        }))
                    }
                    ForEach($draft.requirements) { $requirement in
                        TextField("Scheduling question", text: $requirement.label)
                    }
                } header: { Text("Time requirements") }
                footer: { Text("Dates and times are supplied when scheduling a trip.") }
                Section("Navigation hint") {
                    TextField("Optional hint", text: Binding(get: { draft.hint ?? "" }, set: { draft.hint = $0.isEmpty ? nil : $0 }), axis: .vertical)
                        .lineLimit(2...5).accessibilityIdentifier("place-hint")
                }
                Section("Arrival instructions") {
                    ForEach(draft.instructions.indices, id: \.self) { index in
                        HStack(alignment: .top) {
                            Text("\(index + 1).").foregroundStyle(.secondary)
                            TextField("Instruction", text: $draft.instructions[index], axis: .vertical)
                            Menu {
                                if index > 0 { Button("Move up", systemImage: "arrow.up") { draft.instructions.swapAt(index, index - 1) } }
                                if index + 1 < draft.instructions.count { Button("Move down", systemImage: "arrow.down") { draft.instructions.swapAt(index, index + 1) } }
                                Button("Delete", systemImage: "trash", role: .destructive) { draft.instructions.remove(at: index) }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
                    Button("Add instruction", systemImage: "plus") { draft.instructions.append("") }
                        .accessibilityIdentifier("add-instruction")
                }
                if let saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red)
                            .accessibilityIdentifier("place-save-error")
                    }
                }
            }.disabled(saving)
            .navigationTitle(original.name.isEmpty ? "Add place" : "Place details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft.instructions = draft.instructions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        saving = true
                        saveError = nil
                        onSave(draft) { saved in
                            saving = false
                            if saved { dismiss() }
                            else { saveError = "Couldn’t save this place. Your changes are still here. Try again." }
                        }
                    }.disabled(saving || !hasLocation || !draft.isValid)
                        .accessibilityIdentifier("save-place")
                }
            }
            .interactiveDismissDisabled(saving)
            .sheet(item: $editingArea) { choice in
                let selected = area(choice)
                let stop: Stop? = hasLocation ? Stop(id: selected.id, name: choice == .entry ? draft.name : selected.name,
                                                    latitude: selected.center.latitude, longitude: selected.center.longitude,
                                                    radiusFeet: selected.radiusFeet, address: choice == .entry ? draft.address : "") : nil
                StopEditor(stop: stop) { stop in
                    let firstLocation = !hasLocation
                    var updated = area(choice)
                    updated.name = choice == .entry ? "Entry" : stop.name
                    updated.center = Point(name: stop.name, latitude: stop.latitude, longitude: stop.longitude)
                    if stop.radiusFeet != selected.radiusFeet { updated.radiusMeters = stop.radiusMeters }
                    if choice == .entry {
                        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.name = stop.name }
                        draft.address = stop.address
                    }
                    setArea(updated, choice)
                    if firstLocation { draft.copyEntryGeometryToOtherAreas() }
                    hasLocation = true
                }
            }
        }
    }

    private func area(_ choice: AreaChoice) -> Area {
        switch choice { case .entry: return draft.entry; case .explore: return draft.explore; case .exit: return draft.exit }
    }
    private func setArea(_ area: Area, _ choice: AreaChoice) {
        let shared = draft.usesEntryForAllAreas
        switch choice { case .entry: draft.entry = area; case .explore: draft.explore = area; case .exit: draft.exit = area }
        if shared && choice == .entry { draft.copyEntryGeometryToOtherAreas() }
    }

    private func areaRow(_ choice: AreaChoice) -> some View {
        Button { editingArea = choice } label: {
            LabeledContent(choice.rawValue) {
                HStack(spacing: 8) {
                    Text(area(choice).radiusLabel).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }.foregroundStyle(.primary)
        }.disabled(!hasLocation && choice != .entry)
            .accessibilityIdentifier("edit-\(choice.rawValue.lowercased())-area")
    }
}

private enum AreaChoice: String, CaseIterable, Identifiable {
    case entry = "Entry", explore = "Explore", exit = "Exit"
    var id: String { rawValue }
}

struct DurationFields: View {
    @Binding var duration: DurationRange
    @State private var flexible: Bool
    @State private var minimumText: String
    @State private var maximumText: String

    init(duration: Binding<DurationRange>) {
        _duration = duration
        let value = duration.wrappedValue
        _flexible = State(initialValue: !value.isFixed)
        _minimumText = State(initialValue: Self.minutes(value.isFixed ? 0 : value.minimum))
        _maximumText = State(initialValue: Self.minutes(value.maximum))
    }

    var body: some View {
        Toggle("Flexible duration", isOn: $flexible)
            .onChange(of: flexible) { _, _ in updateDuration() }
        if flexible {
            LabeledContent("Minimum minutes") {
                TextField("0", text: $minimumText)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("minimum-duration")
                    .onChange(of: minimumText) { _, _ in updateDuration() }
            }
        }
        LabeledContent(flexible ? "Maximum minutes" : "Minutes") {
            TextField("5", text: $maximumText)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .accessibilityIdentifier("visit-duration")
                .onChange(of: maximumText) { _, _ in updateDuration() }
        }
        if !duration.isValid {
            Text("Enter a duration of zero or more, with a maximum at least as long as the minimum.")
                .foregroundStyle(.red)
        }
    }

    // Text stays a local editing draft, including an empty field. A numeric formatter binding
    // can restore the previous value while a user is clearing it to type its replacement.
    private func updateDuration() {
        let maximum = Self.seconds(maximumText) ?? -1
        let minimum = flexible ? (Self.seconds(minimumText) ?? -1) : maximum
        duration = DurationRange(minimum: minimum, maximum: maximum)
    }

    private static func seconds(_ text: String) -> Int? {
        guard let minutes = try? Double(text, format: .number), minutes.isFinite, minutes >= 0,
              minutes * 60 < Double(Int.max) else { return nil }
        return Int((minutes * 60).rounded())
    }

    private static func minutes(_ seconds: Int) -> String {
        (Double(seconds) / 60).formatted(.number.precision(.fractionLength(0...4)).grouping(.never))
    }
}

extension TimeRequirement.Kind {
    var schedulingExplanation: String {
        switch self {
        case .appointment: return "Reach Entry by this time. Early arrival creates free time before the appointment; the allocated visit begins at the appointment."
        case .arriveBy: return "The latest time to reach this place’s Entry area. Arriving early does not require waiting before the visit."
        case .leaveBy: return "The latest time to reach this place’s Exit area. The planned visit must respect its fixed duration or allowed minimum–maximum range. If that duration cannot fit before this deadline, the schedule shows the overrun."
        }
    }
    var displayName: String {
        switch self { case .appointment: return "Appointment"; case .arriveBy: return "Arrive by"; case .leaveBy: return "Leave by" }
    }
}

extension Area {
    func legacyStop(name: String) -> Stop {
        Stop(id: id, name: name, latitude: center.latitude, longitude: center.longitude, radiusFeet: radiusMeters / 0.3048)
    }
}

extension Place {
    var mapStop: Stop {
        Stop(id: id, name: name, latitude: entry.center.latitude, longitude: entry.center.longitude, radiusFeet: entry.radiusMeters / 0.3048, address: address)
    }
    static func from(_ stop: Stop) -> Place {
        let point = Point(name: stop.name, latitude: stop.latitude, longitude: stop.longitude)
        return Place(id: stop.id, name: stop.name,
                     entry: Area(name: "Entry", center: point, radiusMeters: stop.radiusMeters),
                     explore: Area(name: "Explore", center: point, radiusMeters: stop.radiusMeters),
                     exit: Area(name: "Exit", center: point, radiusMeters: stop.radiusMeters),
                     address: stop.address)
    }
    /// Merge only fields the editor changed, so unrelated edits cannot be overwritten by its initial snapshot.
    func applyingChanges(from original: Place, draft: Place) -> Place {
        var result = self
        // Resolve linking before merging geometry: an old editor must not break a newer
        // shared setting, and enabling sharing must use the latest untouched Entry.
        let shared = draft.sharedEntryArea != original.sharedEntryArea ? draft.usesEntryForAllAreas : usesEntryForAllAreas
        if draft.name != original.name { result.name = draft.name }
        if draft.address != original.address { result.address = draft.address }
        if draft.sharedEntryArea != original.sharedEntryArea { result.sharedEntryArea = draft.sharedEntryArea }
        if draft.entry != original.entry { result.entry = draft.entry }
        if draft.explore != original.explore { result.explore = draft.explore }
        if draft.exit != original.exit { result.exit = draft.exit }
        if draft.duration != original.duration { result.duration = draft.duration }
        if draft.isOptional != original.isOptional { result.isOptional = draft.isOptional }
        if draft.keepPriority != original.keepPriority { result.keepPriority = draft.keepPriority }
        if draft.hint != original.hint { result.hint = draft.hint }
        if draft.instructions != original.instructions { result.instructions = draft.instructions }
        if draft.requirements != original.requirements { result.requirements = draft.requirements }
        if shared { result.copyEntryGeometryToOtherAreas() }
        return result
    }
}

func durationText(_ range: DurationRange) -> String {
    TripTimeRange(lowerMinutes: Int(ceil(Double(range.minimum) / 60)), upperMinutes: Int(ceil(Double(range.maximum) / 60))).label
}


/// Shared read-only presentation for saved plans and the original snapshot attached to a visit.
struct PlaceSnapshotSections: View {
    let place: Place
    var body: some View {
        Section("Place") {
            LabeledContent("Name", value: place.name)
            if !place.address.isEmpty { LabeledContent("Address", value: place.address) }
        }
        Section("Areas") {
            ForEach([place.entry, place.explore, place.exit]) { area in
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent(area.name, value: "\(area.radiusLabel) radius")
                    Text("\(area.center.latitude.formatted(.number.precision(.fractionLength(6)))), \(area.center.longitude.formatted(.number.precision(.fractionLength(6))))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        Section("Time here") {
            LabeledContent("Duration", value: place.duration.label)
            LabeledContent("Optional", value: place.isOptional ? "Yes" : "No")
            if place.isOptional { LabeledContent("Keep priority", value: String(place.keepPriority)) }
        }
        if !place.requirements.isEmpty {
            Section("Time requirements") {
                ForEach(place.requirements) { requirement in
                    LabeledContent(requirement.kind.title, value: requirement.label)
                }
            }
        }
        if let hint = place.navigationHint {
            Section("Navigation hint") { Text(hint) }
        }
        if !place.arrivalInstructions.isEmpty {
            Section("Arrival instructions") {
                ForEach(Array(place.arrivalInstructions.enumerated()), id: \.offset) { index, instruction in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1).").foregroundStyle(.secondary)
                        Text(instruction)
                    }
                }
            }
        }
    }
}

/// A map preview remains visible beside the place's alias. Editing opens the native location map.
private struct PlaceAreasPreview: UIViewRepresentable {
    let areas: [Area]
    @EnvironmentObject private var appearance: CompassAppearance

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.isUserInteractionEnabled = false
        map.showsCompass = false
        map.accessibilityElementsHidden = true
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        let color = UIColor(appearance.color)
        guard coordinator.areas != areas || coordinator.color != color else { return }
        coordinator.areas = areas
        coordinator.color = color
        map.removeAnnotations(map.annotations)
        map.removeOverlays(map.overlays)
        let circles = areas.filter(\.isValid).map { area in
            // Only the rendering is bounded by the Earth's map extent; the saved area is unchanged.
            MKCircle(center: area.center.coordinate, radius: min(area.radiusMeters, 20_000_000))
        }
        map.addOverlays(circles)
        for area in areas where area.isValid {
            let pin = MKPointAnnotation()
            pin.coordinate = area.center.coordinate
            pin.title = area.name
            map.addAnnotation(pin)
        }
        let bounds = circles.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }.intersection(.world)
        if !bounds.isNull, !bounds.isEmpty {
            map.setVisibleMapRect(bounds, edgePadding: UIEdgeInsets(top: 44, left: 32, bottom: 48, right: 32), animated: false)
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var areas: [Area] = []
        var color: UIColor = .systemBlue
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = color.withAlphaComponent(0.09)
            renderer.strokeColor = color.withAlphaComponent(0.65)
            renderer.lineWidth = 2
            return renderer
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
            view.markerTintColor = color
            return view
        }
    }
}
