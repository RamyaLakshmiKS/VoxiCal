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
        case .eventNotFound(let id):
            return "Event not found (ID: \(id)). It may have already been deleted."
        case .createFailed(let reason):
            return "Failed to create event: \(reason)"
        case .updateFailed(let reason):
            return "Failed to update event: \(reason)"
        }
    }
}

// MARK: - CalendarServiceProtocol

protocol CalendarServiceProtocol: AnyObject {
    func fetchEvents(start: Date, end: Date, titleFilter: String?) async throws -> [CalendarEvent]
    func deleteEvent(id: String) async throws
    func createEvent(title: String, startDate: Date, durationMinutes: Int, location: String?, notes: String?) async throws -> CalendarEvent
    func updateEvent(id: String, title: String?, startDate: Date?, durationMinutes: Int?, location: String?, notes: String?) async throws -> CalendarEvent
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
        guard let event = store.event(withIdentifier: id) else {
            throw CalendarError.eventNotFound(id: id)
        }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    // MARK: - Create

    func createEvent(title: String, startDate: Date, durationMinutes: Int, location: String?, notes: String?) async throws -> CalendarEvent {
        guard hasAccess || EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarError.accessDenied
        }

        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = title
        ekEvent.startDate = startDate
        ekEvent.endDate = startDate.addingTimeInterval(Double(durationMinutes) * 60)
        ekEvent.location = location
        ekEvent.notes = notes
        ekEvent.calendar = store.defaultCalendarForNewEvents

        do {
            try store.save(ekEvent, span: .thisEvent, commit: true)
        } catch {
            throw CalendarError.createFailed(reason: error.localizedDescription)
        }

        return CalendarEvent(
            id: ekEvent.eventIdentifier ?? UUID().uuidString,
            title: title,
            startDate: startDate,
            endDate: ekEvent.endDate,
            location: location,
            notes: notes,
            isAllDay: false
        )
    }

    // MARK: - Update

    /// Updates fields of an existing event. Pass nil to leave a field unchanged.
    /// Pass an empty string for location or notes to clear those fields.
    func updateEvent(id: String, title: String?, startDate: Date?, durationMinutes: Int?, location: String?, notes: String?) async throws -> CalendarEvent {
        guard let event = store.event(withIdentifier: id) else {
            throw CalendarError.eventNotFound(id: id)
        }

        if let title { event.title = title }

        if let startDate {
            let originalDuration = event.endDate.timeIntervalSince(event.startDate)
            let duration = durationMinutes.map { Double($0) * 60 } ?? originalDuration
            event.startDate = startDate
            event.endDate = startDate.addingTimeInterval(duration)
        } else if let durationMinutes {
            event.endDate = event.startDate.addingTimeInterval(Double(durationMinutes) * 60)
        }

        if let location { event.location = location.isEmpty ? nil : location }
        if let notes    { event.notes    = notes.isEmpty    ? nil : notes }

        do {
            try store.save(event, span: .thisEvent, commit: true)
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
