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
        formatter.timeStyle = .short
        let time = formatter.string(from: startDate)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let eventDay = calendar.startOfDay(for: startDate)

        let dayLabel: String
        if eventDay == today {
            dayLabel = "Today"
        } else if eventDay == calendar.date(byAdding: .day, value: 1, to: today) {
            dayLabel = "Tomorrow"
        } else {
            let formatter2 = DateFormatter()
            formatter2.dateFormat = "EEE, MMM d"
            dayLabel = formatter2.string(from: startDate)
        }

        return "• \(title) — \(dayLabel) \(time)"
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

    /// Returns events from `daysBack` days ago through `daysAhead` days forward, optionally filtered by title keyword.
    /// - Parameters:
    ///   - daysAhead: Days forward from today (max 180, ≈ 6 months).
    ///   - daysBack: Days backward from today (max 180). Use 0 for today-only start.
    ///   - titleFilter: Optional keyword matched case-insensitively against title.
    func fetchEvents(daysAhead: Int, daysBack: Int = 0, titleFilter: String? = nil) async throws -> [CalendarEvent] {
        guard hasAccess || EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarError.accessDenied
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -max(daysBack, 0), to: today)!
        let end = calendar.date(byAdding: .day, value: max(daysAhead, 1), to: today)!

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

// MARK: - Protocol Conformance

extension CalendarService: CalendarServiceProtocol {}
