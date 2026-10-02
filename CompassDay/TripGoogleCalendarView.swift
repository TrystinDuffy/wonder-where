import SwiftUI

/// Google calendars already connected to iOS use the system calendar account session.
/// The user chooses the account/calendar; EventKit has no reliable Google provider field.
struct TripGoogleCalendarView: View {
    @EnvironmentObject private var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    let tripID: UUID
    @State private var snapshot: TripCalendarExport.Snapshot?
    @State private var overview: TripAppleCalendarService.Overview?
    @State private var calendarID: String?
    @State private var loading = false
    @State private var saving = false
    @State private var requestingAccess = false
    @State private var message: String?
    @State private var success: String?

    private let service = TripAppleCalendarService.google
    private var trip: Trip? { store.library.trips.first { $0.id == tripID } }
    private var connected: Bool { overview?.connection != nil && overview?.calendarMissing != true }
    private var hasAccess: Bool { overview?.authorization == .fullAccess }
    private var calendars: [TripCalendarRecord] { overview?.writableCalendars ?? [] }
    private var selectedCalendar: TripCalendarRecord? { calendars.first { $0.id == calendarID } }
    private var accountSetupInstructions: String {
        if #available(iOS 18, *) {
            return "In iPhone Settings, open Apps → Calendar → Calendar Accounts → Add Account → Google, sign in, and turn on Calendars. If the account is already added, turn on Calendars for that account."
        }
        return "In iPhone Settings, open Calendar → Accounts → Add Account → Google, sign in, and turn on Calendars. If the account is already added, turn on Calendars for that account."
    }
    private var actionTitle: String {
        if overview?.connection?.pending == true && connected { return "Retry update" }
        return connected ? "Update events" : "Add events"
    }
    private var canSave: Bool {
        snapshot != nil && hasAccess && !loading && !saving && !requestingAccess &&
        (connected || selectedCalendar != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if loading { ProgressView("Preparing events…") }
                if let message {
                    Section {
                        Text(message).foregroundStyle(.red)
                            .accessibilityIdentifier("google-calendar-error")
                    }
                }
                if let success {
                    Section {
                        Label(success, systemImage: "checkmark.circle")
                            .accessibilityIdentifier("google-calendar-success")
                        Text("Your iPhone syncs these events with the selected account. Open Google Calendar to check that they have appeared.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if hasAccess {
                        if connected, let connection = overview?.connection {
                            LabeledContent("Calendar") {
                                Text(connection.name).accessibilityIdentifier("google-calendar-connected-name")
                            }
                            LabeledContent("Account", value: connection.accountTitle)
                            LabeledContent(connection.pending ? "Last attempt" : "Last saved") {
                                Text(connection.updatedAt, format: .dateTime.month().day().hour().minute())
                            }
                            if connection.pending {
                                Text("The last save could not be confirmed. Retry to finish saving the same events.")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            if overview?.calendarMissing == true {
                                Text("The previously selected calendar is unavailable. Reconnect its account, or choose a replacement. Adding to a replacement keeps any events in the previous calendar.")
                                    .foregroundStyle(.secondary)
                            }
                            Picker("Calendar", selection: $calendarID) {
                                Text("Choose calendar").tag(Optional<String>.none)
                                ForEach(calendars) { calendar in
                                    VStack(alignment: .leading) {
                                        Text(calendar.name)
                                        Text(calendar.accountTitle).font(.caption).foregroundStyle(.secondary)
                                    }.tag(Optional(calendar.id))
                                }
                            }
                            .pickerStyle(.navigationLink)
                            .accessibilityIdentifier("google-calendar-picker")
                            .disabled(saving)
                            if let selectedCalendar {
                                LabeledContent("Account", value: selectedCalendar.accountTitle)
                            }
                            if calendars.isEmpty {
                                Text("No writable calendars are available. Connect your Google account to this iPhone, then refresh.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Allow Calendar access to add this trip’s events to a Google calendar connected to your iPhone and update them later.")
                            .foregroundStyle(.secondary)
                        if overview?.authorization == .denied || overview?.authorization == .restricted {
                            Text("Calendar access is turned off. You can change this in Settings.")
                                .foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        } else {
                            Button("Allow Calendar Access") { Task { await requestAccess() } }
                                .accessibilityIdentifier("google-calendar-access")
                                .disabled(requestingAccess || loading)
                        }
                    }
                } header: { Text("Destination calendar") } footer: {
                    if !connected {
                        Text("Choose a calendar from your Google account. Calendars connected to this iPhone are listed with their account names.")
                    }
                }
                Section {
                    DisclosureGroup("Don’t see your Google calendar?") {
                        Text(accountSetupInstructions)
                            .foregroundStyle(.secondary)
                        Text("Signing into the Google Calendar app alone does not connect that account to the iPhone’s calendar settings.")
                            .foregroundStyle(.secondary)
                        Link("Google’s account setup instructions", destination: URL(string: "https://support.google.com/calendar/answer/99358?co=GENIE.Platform%3DiOS&hl=en")!)
                    }
                    Button("Refresh calendars", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(loading || saving || requestingAccess)
                        .accessibilityIdentifier("google-calendar-refresh")
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
                        Text("Times use this trip’s current schedule, including appointment waiting. Choose Update after changing the trip. Other events in the calendar are kept.")
                    }
                    .environment(\.timeZone, TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current)
                }
                Section("Separate calendar and sharing") {
                    Text("For a calendar containing only this trip, create one in Google Calendar on the web, then select it here after it syncs to your iPhone. Manage who can see it in Google Calendar’s Settings and sharing.")
                        .foregroundStyle(.secondary)
                    Link("Create a calendar in Google", destination: URL(string: "https://calendar.google.com/calendar/r/settings/createcalendar")!)
                    Link("Open Google Calendar", destination: URL(string: "https://calendar.google.com/calendar/")!)
                }
            }
            .navigationTitle("Google Calendar").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(saving || requestingAccess)
                        .accessibilityIdentifier("google-calendar-done")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle.replacingOccurrences(of: " events", with: "")) { Task { await save() } }
                        .accessibilityLabel(actionTitle).disabled(!canSave)
                        .accessibilityIdentifier("google-calendar-save")
                }
            }
            .interactiveDismissDisabled(saving || requestingAccess)
            .task { await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && !saving && !requestingAccess { Task { await load() } }
            }
        }
    }

    @MainActor private func load() async {
        guard !loading && !saving else { return }
        loading = true
        defer { loading = false }
        message = nil
        success = nil
        do {
            let result = try await service.inspect(tripID: tripID)
            overview = result
            if !result.writableCalendars.contains(where: { $0.id == calendarID }) { calendarID = nil }
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
            let connection = try await service.synchronize(snapshot: snapshot, accountID: nil,
                calendarName: selectedCalendar?.name ?? overview?.connection?.name ?? snapshot.name,
                recreateMissing: overview?.calendarMissing == true,
                existingCalendarID: connected ? nil : calendarID)
            overview = try await service.inspect(tripID: tripID)
            success = "\(updating ? "Updated" : "Added") \(connection.eventCount) events in \(connection.name)."
        } catch {
            message = error.localizedDescription
            if let result = try? await service.inspect(tripID: tripID) { overview = result }
        }
    }
}
