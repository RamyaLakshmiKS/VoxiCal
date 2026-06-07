import EventKit
import Foundation

// MARK: - CalendarEvent

struct CalendarEvent: Codable, CustomStringConvertible, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let isAllDay: Bool

    var description: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let eventDay = calendar.startOfDay(for: startDate)

        let dayLabel: String
        if eventDay == today {
            dayLabel = "Today"
        } else if eventDay == calendar.date(byAdding: .day, value: 1, to: today) {
            dayLabel = "Tomorrow"
        } else if eventDay == calendar.date(byAdding: .day, value: -1, to: today) {
            dayLabel = "Yesterday"
        } else {
            let formatter2 = DateFormatter()
            formatter2.dateFormat = "EEE, MMM d"
            dayLabel = formatter2.string(from: startDate)
        }

        if isAllDay {
            return "• \(title) — \(dayLabel), all day"
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let startTime = formatter.string(from: startDate)
        let endTime = formatter.string(from: endDate)
        return "• \(title) — \(dayLabel) \(startTime)–\(endTime)"
    }
}

// MARK: - CalendarError

enum CalendarError: LocalizedError {
    case accessDenied
    case writeOnlyAccess
    case eventNotFound(id: String)
    case createFailed(reason: String)
    case updateFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access denied. Go to Settings → Privacy & Security → Calendars to enable full access."
        case .writeOnlyAccess:
            return "VoxiCal needs full calendar access, not just write access. Please update in Settings."
        case .eventNotFound:
            // Intentionally omit the raw event ID from the user-facing message; it is
            // noise to the user and may be confusing. The raw ID is available via the
            // associated value for logging at the call site if needed.
            return "The event could not be found. It may have already been deleted or moved."
        case .createFailed(let reason):
            return "Failed to create event: \(reason)"
        case .updateFailed(let reason):
            // Provide a human-readable prefix so the message makes sense on its own
            // even if EventKit returns a technical underlying description.
            return "Could not save your changes to the event. \(reason)"
        }
    }
}

// MARK: - CalendarServiceProtocol

protocol CalendarServiceProtocol: AnyObject {
    func fetchEvents(start: Date, end: Date, titleFilter: String?) async throws -> [CalendarEvent]
    func deleteEvent(id: String) async throws
    func createEvent(title: String, startDate: Date, durationMinutes: Int?, location: String?, notes: String?, isAllDay: Bool) async throws -> CalendarEvent
    /// Updates fields of an existing event. Pass nil to leave a field unchanged.
    /// Pass an empty string for location or notes to clear those fields.
    /// - Parameter recurrenceScope: `.thisEvent` to modify only this occurrence,
    ///   `.futureEvents` to modify this and all following occurrences.
    func updateEvent(id: String, title: String?, startDate: Date?, durationMinutes: Int?, location: String?, notes: String?, recurrenceScope: EKSpan) async throws -> CalendarEvent
}

// MARK: - CalendarService

/// Wraps EventKit to provide async read and delete operations.
/// Isolated to @MainActor so EKEventStore is always accessed from a single thread.
@MainActor
class CalendarService {
    private let store = EKEventStore()
    private(set) var hasAccess = false

    // MARK: - Permissions

    func requestAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            hasAccess = true
        case .notDetermined:
            let granted = try await store.requestFullAccessToEvents()
            hasAccess = granted
            if !granted { throw CalendarError.accessDenied }
        case .denied, .restricted:
            throw CalendarError.accessDenied
        case .writeOnly:
            throw CalendarError.writeOnlyAccess
        @unknown default:
            break
        }
    }

    // MARK: - Fetch

    func fetchEvents(start: Date, end: Date, titleFilter: String? = nil) async throws -> [CalendarEvent] {
        guard hasAccess || EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarError.accessDenied
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let raw = store.events(matching: predicate)

        return raw
            .filter { event in
                event.startDate < end && event.endDate > start
            }
            .filter { event in
                guard let filter = titleFilter, !filter.isEmpty else { return true }
                return event.title?.localizedCaseInsensitiveContains(filter) == true
            }
            .map { event in
                CalendarEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "(No title)",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    location: event.location,
                    notes: event.notes,
                    isAllDay: event.isAllDay
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Delete

    /// Deletes a single occurrence of the event identified by `id`.
    func deleteEvent(id: String) async throws {
        store.reset()

        if let event = store.event(withIdentifier: id) {
            try store.remove(event, span: .thisEvent, commit: true)
            return
        }

        // After a remote calendar sync the store may prepend a calendar-specific
        // prefix to the identifier (e.g. "calendarID:eventUUID"). Fall back to
        // searching a ±7-day window for an event whose identifier ends with the
        // UUID portion we originally stored.
        let idSuffix    = id.components(separatedBy: ":").last ?? id
        let windowStart = Date().addingTimeInterval(-7 * 86400)
        let windowEnd   = Date().addingTimeInterval( 7 * 86400)
        let predicate   = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        if let event = store.events(matching: predicate).first(where: {
            $0.eventIdentifier?.hasSuffix(idSuffix) == true
        }) {
            try store.remove(event, span: .thisEvent, commit: true)
            return
        }

        throw CalendarError.eventNotFound(id: id)
    }

    // MARK: - Create

    func createEvent(title: String, startDate: Date, durationMinutes: Int?, location: String?, notes: String?, isAllDay: Bool) async throws -> CalendarEvent {
        guard hasAccess || EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarError.accessDenied
        }

        let cal = Calendar.current
        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = title
        ekEvent.isAllDay = isAllDay
        ekEvent.location = location
        ekEvent.notes = notes
        ekEvent.calendar = store.defaultCalendarForNewEvents

        if isAllDay {
            let dayStart = cal.startOfDay(for: startDate)
            ekEvent.startDate = dayStart
            ekEvent.endDate = cal.date(byAdding: .day, value: 1, to: dayStart)!
        } else {
            ekEvent.startDate = startDate
            let mins = durationMinutes ?? 60
            ekEvent.endDate = startDate.addingTimeInterval(Double(mins) * 60)
        }

        do {
            try store.save(ekEvent, span: .thisEvent, commit: true)
        } catch {
            throw CalendarError.createFailed(reason: error.localizedDescription)
        }

        return CalendarEvent(
            id: ekEvent.eventIdentifier ?? UUID().uuidString,
            title: title,
            startDate: ekEvent.startDate,
            endDate: ekEvent.endDate,
            location: location,
            notes: notes,
            isAllDay: isAllDay
        )
    }

    // MARK: - Update

    /// Updates fields of an existing event. Pass nil to leave a field unchanged.
    /// Pass an empty string for location or notes to clear those fields.
    ///
    /// - Parameter recurrenceScope: Controls which occurrences of a recurring event are
    ///   modified. Pass `.thisEvent` (the default at all call sites) to change only the
    ///   selected occurrence, or `.futureEvents` to change this and all following ones.
    func updateEvent(
        id: String,
        title: String?,
        startDate: Date?,
        durationMinutes: Int?,
        location: String?,
        notes: String?,
        recurrenceScope: EKSpan
    ) async throws -> CalendarEvent {
        store.reset()

        let event: EKEvent
        if let e = store.event(withIdentifier: id) {
            event = e
        } else {
            // Fallback: sync may have prepended a calendar prefix to the identifier
            let idSuffix    = id.components(separatedBy: ":").last ?? id
            let windowStart = Date().addingTimeInterval(-7 * 86400)
            let windowEnd   = Date().addingTimeInterval( 7 * 86400)
            let predicate   = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
            guard let found = store.events(matching: predicate).first(where: {
                $0.eventIdentifier?.hasSuffix(idSuffix) == true
            }) else {
                throw CalendarError.eventNotFound(id: id)
            }
            event = found
        }

        if let title { event.title = title }

        if let newStart = startDate {
            // Preserve the original wall-clock duration when only the start time changes.
            // Using absolute TimeInterval arithmetic (seconds since reference date) is
            // DST-safe: if the event crosses a DST boundary the displayed clock times will
            // shift by the DST offset, which is the correct behaviour (the meeting is still
            // the same number of minutes long regardless of the clock change).
            let originalDuration = event.endDate.timeIntervalSince(event.startDate)
            let duration = durationMinutes.map { Double($0) * 60 } ?? originalDuration
            event.startDate = newStart
            event.endDate = newStart.addingTimeInterval(duration)
        } else if let durationMinutes {
            event.endDate = event.startDate.addingTimeInterval(Double(durationMinutes) * 60)
        }

        if let location { event.location = location.isEmpty ? nil : location }
        if let notes    { event.notes    = notes.isEmpty    ? nil : notes }

        do {
            try store.save(event, span: recurrenceScope, commit: true)
        } catch {
            throw CalendarError.updateFailed(reason: error.localizedDescription)
        }

        return CalendarEvent(
            id: event.eventIdentifier ?? id,
            title: event.title ?? "(No title)",
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location,
            notes: event.notes,
            isAllDay: event.isAllDay
        )
    }
}

// MARK: - Protocol Conformance

extension CalendarService: CalendarServiceProtocol {}
