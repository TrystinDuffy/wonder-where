import SwiftUI

/// Native editor for a connection outside a Plan's canonical legs.
struct RouteEstimateEditor: View {
    let tripID: UUID
    let request: RouteRequestContext
    @EnvironmentObject private var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @State private var duration = DurationRange.fiveMinutes
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var initialized = false

    private var trip: Trip? { store.library.trips.first { $0.id == tripID } }
    private var fromName: String {
        request.fromPlaceID.flatMap { trip?.plan.place($0)?.name } ??
        (request.kind == .liveApproach ? "Current location" : "Starting location")
    }
    private var toName: String { trip?.plan.place(request.toPlaceID)?.name ?? request.destination.name }

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("From", value: fromName)
                LabeledContent("To", value: toName)
                LabeledContent("Travel mode") { Label(request.mode.title, systemImage: request.mode.symbol) }
            }
            Section {
                if initialized { DurationFields(duration: $duration) }
            } header: { Text("Manual travel time") }
            footer: {
                Text("This range is your estimate. It is saved for these locations and this travel mode, and is not replaced by Apple Maps.")
            }
            if existingEstimate != nil {
                Section {
                    Button("Use Apple Maps instead", role: .destructive) { save(remove: true) }
                        .disabled(saving)
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Travel estimate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(remove: false) }
                    .disabled(!duration.isValid || saving || trip == nil)
                    .accessibilityIdentifier("save-route-estimate")
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if let estimate = existingEstimate { duration = estimate.duration }
        }
    }

    private var existingEstimate: ManualRouteEstimate? {
        trip?.manualRouteEstimates.last {
            $0.matches(source: request.source, destination: request.destination, mode: request.mode)
        }
    }

    private func save(remove: Bool) {
        saving = true
        errorMessage = nil
        let liveOrigin = store.liveOrigin
        Task {
            var accepted = false
            let saved = await store.transact { library in
                guard let index = library.trips.firstIndex(where: { $0.id == tripID }) else { return }
                accepted = ManualRouteEditing.apply(request: request, duration: remove ? nil : duration,
                                                    to: &library.trips[index], liveOrigin: liveOrigin)
            }
            saving = false
            if saved && accepted {
                store.refresh()
                dismiss()
            } else {
                errorMessage = saved ? "This connection changed while you were editing. Return to the trip and open its current connection." :
                    "The estimate could not be saved. Please try again."
            }
        }
    }
}
