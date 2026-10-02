import SwiftUI

struct ReminderEventOption: Identifiable {
    enum Category: Equatable { case tripStart, placeDeparture, timeRequirement }
    var event: ReminderEvent
    var title: String
    var category: Category
    var detail: String? = nil
    var id: ReminderEvent { event }
}

struct ReminderSettingsView: View {
    @Binding var reminders: [TripReminder]
    @Binding var arrivalNotificationsEnabled: Bool
    var events: [ReminderEventOption]
    @ObservedObject var service: TripReminderService
    @Environment(\.openURL) private var openURL
    @State private var draft: ReminderSettingsDraft
    @State private var arrivalDraft: Bool
    @State private var pendingArrival: Bool?

    init(reminders: Binding<[TripReminder]>, arrivalNotificationsEnabled: Binding<Bool>,
         events: [ReminderEventOption], service: TripReminderService) {
        _reminders = reminders
        _arrivalNotificationsEnabled = arrivalNotificationsEnabled
        self.events = events
        self.service = service
        _draft = State(initialValue: ReminderSettingsDraft(records: reminders.wrappedValue))
        _arrivalDraft = State(initialValue: arrivalNotificationsEnabled.wrappedValue)
    }

    var body: some View {
        Form {
            if !options(.tripStart).isEmpty {
                Section {
                    ForEach(options(.tripStart)) { option in eventControls(option) }
                } header: { Text("Trip start") } footer: {
                    Text("Uses your planned trip start. The default is 15 minutes before; change the lead time when enabled.")
                }
            }
            Section {
                Toggle("When you arrive", isOn: Binding(
                    get: { arrivalDraft },
                    set: { setArrivalsEnabled($0) }))
                    .accessibilityIdentifier("notification-arrivals")
            } header: { Text("Arrivals") } footer: {
                Text("Sends a spoiler-free notification when GPS confirms Entry while your phone is locked or the app is in the background. It does not reveal the place name and has no advance warning.")
            }
            if !options(.placeDeparture).isEmpty {
                Section {
                    ForEach(options(.placeDeparture)) { option in eventControls(option) }
                } header: { Text("Place departures") } footer: {
                    Text("Uses each place’s planned Exit time, including time spent moving within the place. It updates when your schedule changes.")
                }
            }
            if !options(.timeRequirement).isEmpty {
                Section {
                    ForEach(options(.timeRequirement)) { option in eventControls(option) }
                } header: { Text("Appointments and deadlines") } footer: {
                    Text("Uses the date and time you assigned to each appointment or deadline.")
                }
            }
            Section {
                Text("Notifications and alarms do not reveal place names. Scheduled alerts can be delivered while WonderWhere is closed. Their times update when the app runs or receives location updates.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if service.authorization[.notification] == .denied || service.authorization[.alarm] == .denied {
                Section("Permission needed") {
                    if service.authorization[.notification] == .denied {
                        Text("Notifications are blocked in iOS Settings. Trip, place, and arrival notifications cannot be delivered until you allow them.")
                            .foregroundStyle(.red)
                    }
                    if service.authorization[.alarm] == .denied {
                        Text("Alarms are blocked in iOS Settings. Events using Alarm delivery cannot ring until you allow alarms.")
                            .foregroundStyle(.red)
                    }
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            if let error = service.permissionError {
                Section { Text(error).foregroundStyle(.red) }
            }
            let hiddenErrors = draft.records.filter { record in
                record.schedulingError != nil && (!record.enabled || !events.contains { $0.event == record.event })
            }
            if !hiddenErrors.isEmpty {
                Section("Notification errors") {
                    ForEach(hiddenErrors) { record in
                        Text(record.schedulingError ?? "Notification unavailable").font(.footnote).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("All") { setAllEnabled(true) }
                    .disabled(arrivalDraft && events.allSatisfy { option in draft.records.contains { $0.event == option.event && $0.enabled } })
                    .accessibilityIdentifier("notifications-all")
                Button("None") { setAllEnabled(false) }
                    .disabled(!arrivalDraft && !draft.records.contains(where: \.enabled))
                    .accessibilityIdentifier("notifications-none")
            }
        }
        .task { await service.refreshAuthorization() }
        .onChange(of: reminders) { _, records in draft.receive(records) }
        .onChange(of: arrivalNotificationsEnabled) { _, enabled in
            if pendingArrival == nil || pendingArrival == enabled {
                arrivalDraft = enabled
                pendingArrival = nil
            }
        }
    }

    private func options(_ category: ReminderEventOption.Category) -> [ReminderEventOption] {
        events.filter { $0.category == category }
    }

    @ViewBuilder private func eventControls(_ option: ReminderEventOption) -> some View {
        Toggle(isOn: enabledBinding(option.event)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(option.title)
                if let detail = option.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
        }.accessibilityIdentifier(option.event == .tripDeparture ? "notification-trip-start" : "notification-\(option.id)")
        if let reminder = draft.records.first(where: { $0.event == option.event }), reminder.enabled {
            Picker("Delivery", selection: deliveryBinding(option.event)) {
                Text("Notification").tag(ReminderDelivery.notification)
                if TripReminderService.supportsAlarms { Text("Alarm").tag(ReminderDelivery.alarm) }
            }
            HStack {
                Text("Minutes before")
                Spacer()
                TextField("15", value: leadBinding(option.event), format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .frame(minWidth: 60, maxWidth: 100)
                    .accessibilityLabel("Minutes before \(option.title)")
            }
            statusRow(reminder)
        }
    }

    @ViewBuilder
    private func statusRow(_ reminder: TripReminder) -> some View {
        if let error = reminder.schedulingError {
            Text(error).font(.footnote).foregroundStyle(.red)
        } else {
            switch reminder.status {
            case .scheduled:
                if let date = reminder.scheduledAt {
                    LabeledContent("Scheduled for") { Text(date, format: .dateTime.month().day().hour().minute()) }
                        .foregroundStyle(.secondary)
                }
            case .consumed:
                Text("This notification has finished or was dismissed. Turn it off and on to schedule it again.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .past:
                Text("The notification time has passed. It will not ring unexpectedly.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .waitingForTime:
                Text("Waiting for an event time or travel estimate.").font(.footnote).foregroundStyle(.secondary)
            case .pending:
                Label("Scheduling", systemImage: "clock").foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
    }

    private func enabledBinding(_ event: ReminderEvent) -> Binding<Bool> {
        Binding(get: { draft.records.first(where: { $0.event == event })?.enabled ?? false }, set: { enabled in
            edit(event) { $0.setEnabled(enabled) }
            if enabled {
                let delivery = draft.records.first(where: { $0.event == event })?.delivery ?? .notification
                Task { await service.requestAuthorization(for: delivery) }
            }
        })
    }

    private func deliveryBinding(_ event: ReminderEvent) -> Binding<ReminderDelivery> {
        Binding(get: { draft.records.first(where: { $0.event == event })?.delivery ?? .notification }, set: { delivery in
            edit(event) { $0.edit(delivery: delivery) }
            Task { await service.requestAuthorization(for: delivery) }
        })
    }

    private func leadBinding(_ event: ReminderEvent) -> Binding<Int> {
        Binding(get: { (draft.records.first(where: { $0.event == event })?.leadSeconds ?? 900) / 60 }, set: { minutes in
            edit(event) { $0.edit(leadSeconds: min(max(0, minutes), 60 * 24 * 30) * 60) }
        })
    }

    private func edit(_ event: ReminderEvent, change: (inout TripReminder) -> Void) {
        draft.edit(event, change: change)
        reminders = draft.records
    }

    private func setArrivalsEnabled(_ enabled: Bool, requestPermission: Bool = true) {
        arrivalDraft = enabled
        pendingArrival = enabled
        arrivalNotificationsEnabled = enabled
        if enabled && requestPermission { Task { await service.requestAuthorization(for: .notification) } }
    }

    private func setAllEnabled(_ enabled: Bool) {
        draft.setAllEnabled(enabled, events: events.map(\.event))
        reminders = draft.records
        setArrivalsEnabled(enabled, requestPermission: false)
        if enabled {
            let deliveries = ReminderDelivery.allCases.filter { delivery in
                delivery == .notification || draft.records.contains { record in
                    record.enabled && record.delivery == delivery && events.contains { $0.event == record.event }
                }
            }
            Task { for delivery in deliveries { await service.requestAuthorization(for: delivery) } }
        }
    }
}

/// Keeps native controls responsive while the durable store commits asynchronously. An older
/// acknowledgement cannot erase a newer local edit, and receipts only merge for the same revision.
struct ReminderSettingsDraft {
    private(set) var records: [TripReminder]
    private var pending: Set<UUID> = []

    init(records: [TripReminder]) { self.records = records }

    mutating func edit(_ event: ReminderEvent, change: (inout TripReminder) -> Void) {
        if let index = records.firstIndex(where: { $0.event == event }) {
            change(&records[index])
            pending.insert(records[index].id)
        } else {
            var record = TripReminder(event: event)
            change(&record)
            records.append(record)
            pending.insert(record.id)
        }
    }

    /// Bulk actions preserve stable identities and do not re-arm an already enabled event.
    mutating func setAllEnabled(_ enabled: Bool, events: [ReminderEvent]) {
        var seen: Set<ReminderEvent> = []
        let affectedEvents = enabled ? events : records.map(\.event)
        for event in affectedEvents where seen.insert(event).inserted {
            if let current = records.first(where: { $0.event == event }) {
                guard current.enabled != enabled else { continue }
            } else if !enabled { continue }
            edit(event) { $0.setEnabled(enabled) }
        }
    }

    mutating func receive(_ committed: [TripReminder]) {
        let committedIDs = Set(committed.map(\.id))
        records.removeAll { !committedIDs.contains($0.id) && !pending.contains($0.id) }
        for receipt in committed {
            guard let index = records.firstIndex(where: { $0.id == receipt.id }) else {
                records.append(receipt)
                continue
            }
            if records[index].desiredRevision == receipt.desiredRevision {
                records[index] = receipt
                pending.remove(receipt.id)
            } else if !pending.contains(receipt.id) {
                records[index] = receipt
            }
        }
    }
}
