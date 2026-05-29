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

    var description: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let start = formatter.string(from: startDate)
        var text = "• \(title) — \(start)"
        if let loc = location, !loc.isEmpty {
            text += " (\(loc))"
        }
        return text
    }
}

// MARK: - CalendarError

enum CalendarError: LocalizedError {
    case accessDenied
    case writeOnlyAccess
    case eventNotFound(id: String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access denied. Go to Settings → Privacy & Security → Calendars to enable full access."
        case .writeOnlyAccess:
            return "VoxiCal needs full calendar access, not just write access. Please update in Settings."
        case .eventNotFound(let id):
            return "Event not found (ID: \(id)). It may have already been deleted."
        }
    }
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

    /// Returns events from today through `daysAhead` days, optionally filtered by title keyword.
    func fetchEvents(daysAhead: Int, titleFilter: String? = nil) async throws -> [CalendarEvent] {
        guard hasAccess || EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarError.accessDenied
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: max(daysAhead, 1), to: start)!

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let raw = store.events(matching: predicate)

        return raw
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
                    notes: event.notes
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
}
