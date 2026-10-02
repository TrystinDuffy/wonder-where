import Foundation

/// Shared calendar snapshot for iCalendar files and Apple Calendar. Projection never edits a trip.
enum TripCalendarExport {
    struct Document {
        let data: Data
        let filename: String
        let eventCount: Int
    }

    struct Snapshot: Equatable {
        let tripID: UUID
        let revision: Int
        let name: String
        let timeZoneIdentifier: String
        let events: [Event]
    }

    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date?
        let notes: String
        let location: String?
        let point: Point?
        let url: URL?
    }

    enum ExportError: LocalizedError {
        case canceled
        case staleSchedule
        case noPlaces
        case missingStart
        case missingTimes([String])
        case unboundRequirements([String])
        case invalidTimes(String)

        var errorDescription: String? {
            switch self {
            case .canceled:
                return "This trip was canceled. Schedule a new trip to share its calendar."
            case .staleSchedule:
                return "The trip changed while its schedule was being calculated. Try sharing again."
            case .noPlaces:
                return "Add at least one included place before sharing the trip calendar."
            case .missingStart:
                return "The trip’s actual departure time is unknown, so its calendar cannot be exported."
            case .missingTimes(let places):
                return "Arrival or departure times are unavailable for: \(places.joined(separator: ", ")). Set missing travel times or complete the schedule before sharing. Unknown recorded times cannot be reconstructed."
            case .unboundRequirements(let requirements):
                return "Set the required times before sharing: \(requirements.joined(separator: ", "))."
            case .invalidTimes(let place):
                return "The saved times for \(place) are invalid or its departure is before its arrival. Review the trip’s timing before sharing."
            }
        }
    }

    static func make(trip: Trip, projection: TripScheduleProjection, generatedAt: Date) throws -> Document {
        let snapshot = try snapshot(trip: trip, projection: projection, generatedAt: generatedAt)
        let formatter = dateFormatter()
        let stamp = try dateString(generatedAt, formatter: formatter, context: "the export")
        let sequence = String(max(0, snapshot.revision))
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//WonderWhere//Trip Calendar Export//EN",
                     "CALSCALE:GREGORIAN", "X-WR-CALNAME:\(escape(snapshot.name))"]
        for event in snapshot.events {
            lines += try contentLines(for: event, stamp: stamp, sequence: sequence, formatter: formatter)
        }
        lines.append("END:VCALENDAR")
        let contents = lines.map(fold).joined(separator: "\r\n") + "\r\n"
        return Document(data: Data(contents.utf8), filename: filename(snapshot.name), eventCount: snapshot.events.count)
    }

    static func snapshot(trip: Trip, projection: TripScheduleProjection, generatedAt: Date) throws -> Snapshot {
        guard trip.status != .canceled else { throw ExportError.canceled }
        guard projection.tripID == trip.id, projection.revision == trip.revision,
              projection.status == trip.status else { throw ExportError.staleSchedule }
        let places = trip.includedPlaces.filter { !projection.skippedPlaceIDs.contains($0.id) }
        guard !places.isEmpty else { throw ExportError.noPlaces }
        let unbound = places.flatMap { place in
            place.requirements.filter { trip.bindings[$0.id] == nil }.map {
                "\(place.name) — \($0.label.isEmpty ? $0.kind.title : $0.label)"
            }
        }
        guard unbound.isEmpty else { throw ExportError.unboundRequirements(unbound) }
        let departure: Date
        if trip.status == .scheduled {
            departure = trip.scheduledStart
        } else {
            guard let actual = trip.startedAt else { throw ExportError.missingStart }
            departure = actual
        }

        let utc = dateFormatter()
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: trip.timeZoneIdentifier) ?? .gmt
        local.dateFormat = "MMM d, yyyy 'at' h:mm:ss a zzz"
        _ = try dateString(generatedAt, formatter: utc, context: "the export")
        var events: [Event] = []
        var departureNotes = ["Trip: \(trip.plan.name)",
                              "Calendar snapshot. Use Update Apple Calendar in WonderWhere to apply trip changes; previously shared files do not update.",
                              "Trip time zone: \(trip.timeZoneIdentifier)",
                              trip.status == .scheduled ? "Scheduled trip departure." : "Recorded actual trip departure.",
                              "Initial travel mode: \(trip.plan.initialMode.title).",
                              "Includes \(places.count) places. Travel between places is not a separate calendar event."]
        if projection.hasCachedEstimates {
            departureNotes.append("Some travel estimates are cached and may have changed.")
        }
        if !projection.conflicts.isEmpty {
            departureNotes.append("The schedule has timing conflicts. See the affected place events for their deadlines and overruns.")
        }
        events.append(try event(id: "\(trip.id.uuidString.lowercased())-departure@compassday.app",
                                title: "Depart — \(trip.plan.name)", start: departure, end: nil,
                                notes: departureNotes.joined(separator: "\n"), point: trip.origin,
                                location: trip.origin?.name, formatter: utc))

        var missing: [String] = []
        for (index, currentPlace) in places.enumerated() {
            let visit = trip.visits[currentPlace.id]
            let recorded = visit?.completed == true
            // Finished visits keep the details and geometry that were recorded at the time.
            let place = recorded ? (visit?.place ?? currentPlace) : currentPlace
            let scheduled = projection.place(place.id)
            let start = visit?.arrivedAt ?? (recorded ? nil : scheduled?.arrival?.upperBound)
            let end = visit?.exitedAt ?? (recorded ? nil : scheduled?.exit?.upperBound)
            guard let start, let end else {
                missing.append(place.name)
                continue
            }
            guard end >= start else { throw ExportError.invalidTimes(place.name) }
            let allocation = scheduled?.allocation ?? trip.allocation(for: place.id)
            var notes = ["Trip: \(trip.plan.name)", "Place \(index + 1) of \(places.count).",
                         "Calendar snapshot. Use Update Apple Calendar in WonderWhere to apply trip changes; previously shared files do not update.",
                         "Trip time zone: \(trip.timeZoneIdentifier)",
                         "Arrival: \(local.string(from: start)) (\(visit?.arrivedAt == nil ? "upper schedule estimate" : "recorded actual time")).",
                         "Departure: \(local.string(from: end)) (\(visit?.exitedAt == nil ? "upper schedule estimate" : "recorded actual time")).",
                         "Allocated visit: \(duration(allocation)). Configured duration: \(duration(place.duration.minimum))–\(duration(place.duration.maximum)).",
                         "This event spans Entry arrival through confirmed or expected Exit, including any appointment waiting. Estimated times use the schedule’s conservative upper bounds and current allocation."]
            if let anchor = visit?.effectiveBudgetAnchor(at: generatedAt) ?? scheduled?.budgetStart?.upperBound,
               anchor > start, anchor <= end {
                notes.append("Appointment waiting before the visit budget begins: \(duration(Int(anchor.timeIntervalSince(start).rounded(.up)))).")
            }
            if let scheduled, scheduled.incomingSource == .cached {
                notes.append("Incoming travel uses a cached estimate.")
            }
            if !place.address.isEmpty { notes.append("Address: \(place.address)") }
            notes += ["Entry coordinates: \(coordinates(place.entry.center))", "Apple Maps: \(mapsURL(place.entry.center))"]
            if !place.exit.center.sameCoordinates(as: place.entry.center) {
                notes.append("Exit coordinates: \(coordinates(place.exit.center))")
                notes.append("Exit in Apple Maps: \(mapsURL(place.exit.center))")
            }
            if let hint = place.navigationHint { notes.append("Hint: \(hint)") }
            if !place.arrivalInstructions.isEmpty {
                notes.append("Instructions:")
                notes += place.arrivalInstructions.enumerated().map { "\($0.offset + 1). \($0.element)" }
            }
            // Current requirements match the bound schedule; historical observations remain actual.
            for requirement in currentPlace.requirements {
                guard let bound = trip.bindings[requirement.id] else { continue }
                _ = try dateString(bound, formatter: utc, context: place.name)
                notes.append("\(requirement.kind.title) — \(requirement.label): \(local.string(from: bound)).")
                if requirement.kind == .appointment {
                    notes.append("Reach Entry by the appointment; the visit budget begins no earlier than that time.")
                }
                let actual = requirement.kind == .leaveBy ? visit?.exitedAt : visit?.arrivedAt
                if let actual, actual > bound {
                    notes.append("Recorded \(requirement.kind.title.lowercased()) overrun: \(duration(Int(actual.timeIntervalSince(bound).rounded(.up)))).")
                } else if let conflict = projection.conflicts.first(where: { $0.requirementID == requirement.id }) {
                    notes.append("Schedule conflict: \(conflict.isLowerBoundOnly ? "at least " : "up to ")\(duration(Int(conflict.lateness.rounded(.up)))) past this deadline.")
                }
            }
            events.append(try event(id: "\(trip.id.uuidString.lowercased())-\(place.id.uuidString.lowercased())@compassday.app",
                                    title: place.name, start: start, end: end > start ? end : nil,
                                    notes: notes.joined(separator: "\n"), point: place.entry.center,
                                    location: place.address.isEmpty ? place.name : place.address, formatter: utc))
        }
        guard missing.isEmpty else { throw ExportError.missingTimes(missing) }
        return Snapshot(tripID: trip.id, revision: trip.revision, name: trip.plan.name,
                        timeZoneIdentifier: trip.timeZoneIdentifier, events: events)
    }

    private static func event(id: String, title: String, start: Date, end: Date?, notes: String,
                              point: Point?, location: String?, formatter: DateFormatter) throws -> Event {
        _ = try dateString(start, formatter: formatter, context: title)
        if let end { _ = try dateString(end, formatter: formatter, context: title) }
        let validPoint = point?.isValid == true ? point : nil
        return Event(id: id, title: title, start: start, end: end, notes: notes, location: location,
                     point: validPoint, url: validPoint.flatMap { URL(string: mapsURL($0)) })
    }

    private static func contentLines(for event: Event, stamp: String, sequence: String,
                                     formatter: DateFormatter) throws -> [String] {
        let serializedStart = try dateString(event.start, formatter: formatter, context: event.title)
        let serializedEnd = try event.end.map { try dateString($0, formatter: formatter, context: event.title) }
        var lines = ["BEGIN:VEVENT", "UID:\(event.id)", "SEQUENCE:\(sequence)", "DTSTAMP:\(stamp)",
                     "DTSTART:\(serializedStart)"]
        // RFC 5545 requires DTEND to be later than DTSTART. Distinct sensor timestamps
        // within one calendar second still describe an instantaneous exported event.
        if let serializedEnd, serializedEnd != serializedStart { lines.append("DTEND:\(serializedEnd)") }
        lines += ["SUMMARY:\(escape(event.title))", "DESCRIPTION:\(escape(event.notes))"]
        if let location = event.location, !location.isEmpty { lines.append("LOCATION:\(escape(location))") }
        if let point = event.point {
            lines.append("GEO:\(number(point.latitude));\(number(point.longitude))")
        }
        if let url = event.url { lines.append("URL:\(url.absoluteString)") }
        lines.append("END:VEVENT")
        return lines
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }

    private static func dateString(_ date: Date, formatter: DateFormatter, context: String) throws -> String {
        guard date.timeIntervalSince1970.isFinite else { throw ExportError.invalidTimes(context) }
        let year = formatter.calendar.component(.year, from: date)
        guard (1...9999).contains(year) else { throw ExportError.invalidTimes(context) }
        let result = formatter.string(from: date)
        guard result.utf8.count == 16 else { throw ExportError.invalidTimes(context) }
        return result
    }

    /// RFC 5545 TEXT escaping must happen before content-line folding.
    private static func escape(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        let permitted = normalized.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" }
        return String(String.UnicodeScalarView(permitted))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    /// The continuation space counts toward 75 octets; never split a UTF-8 scalar.
    private static func fold(_ line: String) -> String {
        var result = ""
        var octets = 0
        for scalar in line.unicodeScalars {
            let part = String(scalar)
            let count = part.utf8.count
            if octets + count > 75 {
                result += "\r\n "
                octets = 1
            }
            result += part
            octets += count
        }
        return result
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private static func coordinates(_ point: Point) -> String { "\(number(point.latitude)), \(number(point.longitude))" }
    private static func mapsURL(_ point: Point) -> String {
        "https://maps.apple.com/?ll=\(number(point.latitude)),\(number(point.longitude))"
    }
    private static func duration(_ seconds: Int) -> String {
        let value = max(0, seconds)
        let days = value / 86_400
        let hours = value % 86_400 / 3_600
        let minutes = value % 3_600 / 60
        let remainder = value % 60
        let parts = [(days, "day"), (hours, "hr"), (minutes, "min"), (remainder, "sec")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "0 sec" : parts.joined(separator: " ")
    }
    private static func filename(_ name: String) -> String {
        let permitted = name.unicodeScalars.map { scalar -> String in
            if scalar.value < 32 || "/\\:?%*|\"<>".unicodeScalars.contains(scalar) { return "-" }
            return String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var base = ""
        var octets = 0
        for character in permitted {
            let part = String(character)
            guard octets + part.utf8.count <= 180 else { break }
            base += part
            octets += part.utf8.count
        }
        return "\(base.isEmpty || base.allSatisfy({ $0 == "." }) ? "WonderWhere Trip" : base).ics"
    }
}
