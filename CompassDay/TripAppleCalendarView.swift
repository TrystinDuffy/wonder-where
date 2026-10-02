import SwiftUI

struct TripAppleCalendarView: View {
    @EnvironmentObject private var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    let tripID: UUID
    @State private var snapshot: TripCalendarExport.Snapshot?
    @State private var overview: TripAppleCalendarService.Overview?
    @State private var calendarName = ""
    @State private var accountID: String?
    @State private var seededName = false
    @State private var loading = true
    @State private var saving = false
    @State private var requestingAccess = false
    @State private var message: String?
    @State private var success: String?

    private let service = TripAppleCalendarService.shared
    private var trip: Trip? { store.library.trips.first { $0.id == tripID } }
    private var connected: Bool { overview?.connection != nil && overview?.calendarMissing != true }
    private var hasAccess: Bool { overview?.authorization == .fullAccess }
    private var actionTitle: String {
        if overview?.calendarMissing == true { return "Recreate calendar" }
        if overview?.connection?.pending == true { return "Retry update" }
        return connected ? "Update calendar" : "Create calendar"
    }
    private var canSave: Bool {
        snapshot != nil && hasAccess && !loading && !saving && !requestingAccess &&
        !calendarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (connected || accountID != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if loading { ProgressView("Preparing calendar…") }
                if let message {
                    Section {
                        Text(message).foregroundStyle(.red).accessibilityIdentifier("apple-calendar-error")
                        Button("Refresh") { Task { await load() } }.disabled(saving || requestingAccess)
                    }
                }
                if let success {
                    Section {
                        Label(success, systemImage: "checkmark.circle")
                            .accessibilityIdentifier("apple-calendar-success")
                    }
                }
                Section("Calendar") {
                    TextField("Calendar name", text: $calendarName)
                        .accessibilityIdentifier("apple-calendar-name")
                        .disabled(saving)
                    if hasAccess {
                        if connected, let connection = overview?.connection {
                            LabeledContent("Account", value: connection.accountTitle)
                            LabeledContent(connection.pending ? "Last attempt" : "Last updated") {
                                Text(connection.updatedAt, format: .dateTime.month().day().hour().minute())
                            }
                            if connection.pending {
                                Text("The last update could not be confirmed. Retry it to recover the calendar connection.")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            if overview?.calendarMissing == true {
                                Text("The calendar previously created for this trip is no longer available. You can create it again in the account below.")
                                    .foregroundStyle(.secondary)
                            }
                            Picker("Account", selection: $accountID) {
                                Text("Choose account").tag(Optional<String>.none)
                                ForEach(overview?.accounts ?? []) { account in
                                    Text(account.title).tag(Optional(account.id))
                                }
                            }.accessibilityIdentifier("apple-calendar-account").disabled(saving)
                            if overview?.accounts.isEmpty == true {
                                Text("No account is available for creating a calendar. Add an account in Apple Calendar or iPhone Settings, then return here.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Allow calendar access to create a separate calendar for this trip and update its events later.")
                            .foregroundStyle(.secondary)
                        if overview?.authorization == .denied || overview?.authorization == .restricted {
                            Text("Calendar access is turned off. You can change this in Settings.")
                                .foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        } else {
                            Button("Allow Calendar Access") { Task { await requestAccess() } }
                                .accessibilityIdentifier("apple-calendar-access")
                                .disabled(requestingAccess || loading)
                        }
                    }
                }
                if let snapshot {
                    Section {
                        ForEach(snapshot.events) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title)
                                Text(event.start, format: .dateTime.month().day().hour().minute())
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if let end = event.end, end > event.start {
                                    Text("Until \(end, format: .dateTime.month().day().hour().minute())")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                if let location = event.location, !location.isEmpty {
                                    Text(location).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text("\(snapshot.events.count) events") } footer: {
                        Text("Times use this trip’s current schedule, including appointment waiting. Choose Update calendar after changing the trip. Events you add yourself are kept.")
                    }
                    .environment(\.timeZone, TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current)
                }
                Section("Sharing") {
                    Text("Choose your iCloud account to share the calendar. In Apple Calendar, tap Calendars, then the info button beside this calendar, then Add Person.")
                        .foregroundStyle(.secondary)
                    if connected {
                        Button("Open Apple Calendar", systemImage: "calendar") {
                            let date = snapshot?.events.first?.start ?? Date()
                            if let url = URL(string: "calshow:\(Int(date.timeIntervalSinceReferenceDate))") {
                                openURL(url) { opened in
                                    if !opened { message = "Apple Calendar could not be opened. Open the Calendar app from your Home Screen." }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Apple Calendar").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(saving || requestingAccess)
                        .accessibilityIdentifier("apple-calendar-done")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle.replacingOccurrences(of: " calendar", with: "")) { Task { await save() } }
                        .accessibilityLabel(actionTitle).disabled(!canSave)
                        .accessibilityIdentifier("apple-calendar-save")
                }
            }
            .task { await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && !saving && !requestingAccess {
                    Task { await load() }
                }
            }
        }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        message = nil
        success = nil
        do {
            let result = try await service.inspect(tripID: tripID)
            overview = result
            if !seededName {
                calendarName = result.connection?.name ?? trip?.plan.name ?? "Trip"
                seededName = true
            }
            if accountID == nil { accountID = result.defaultAccountID ?? result.accounts.first?.id }
            guard let trip else { message = "This trip is no longer available."; snapshot = nil; return }
            let origin = store.liveOrigin
            let date = Date()
            snapshot = try await Task.detached(priority: .userInitiated) {
                let projection = TripScheduler.project(trip: trip, liveOrigin: origin, now: date, adapt: false)
                return try TripCalendarExport.snapshot(trip: trip, projection: projection, generatedAt: date)
            }.value
        } catch {
            snapshot = nil
            message = error.localizedDescription
        }
    }

    @MainActor private func requestAccess() async {
        requestingAccess = true
        defer { requestingAccess = false }
        do {
            _ = try await service.requestAccess()
            await load()
        } catch { message = error.localizedDescription }
    }

    @MainActor private func save() async {
        guard let snapshot, canSave else { return }
        // A name/geometry/progress edit requires another review before writing the calendar.
        guard trip?.revision == snapshot.revision else {
            await load()
            message = "The trip changed. Review the refreshed events, then try again."
            return
        }
        saving = true
        success = nil
        message = nil
        defer { saving = false }
        do {
            let updating = connected
            let connection = try await service.synchronize(snapshot: snapshot, accountID: accountID,
                calendarName: calendarName.trimmingCharacters(in: .whitespacesAndNewlines),
                recreateMissing: overview?.calendarMissing == true)
            calendarName = connection.name
            overview = try await service.inspect(tripID: tripID)
            success = updating ? "Calendar updated with \(connection.eventCount) events." : "Calendar created with \(connection.eventCount) events."
        } catch {
            message = error.localizedDescription
            if let result = try? await service.inspect(tripID: tripID) { overview = result }
        }
    }
}
