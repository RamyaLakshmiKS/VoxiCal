import FoundationModels
import Foundation

// MARK: - FetchCalendarEventsTool

/// Lets the LLM fetch upcoming calendar events for a given date range.
/// The model calls this autonomously whenever the user asks about their schedule.
struct FetchCalendarEventsTool: Tool, @unchecked Sendable {
    typealias Output = String

    nonisolated let name = "fetchCalendarEvents"
    let description = "Fetches upcoming calendar events. Call this when the user asks about their schedule, meetings, or appointments."

    @Generable
    struct Arguments {
        @Guide(description: "Number of days to fetch starting from today (inclusive). Use 1 for today only, 2 to include tomorrow, 3 for today through the day after tomorrow, 7 for this week, 30 for this month. Always use 2 when the user asks about tomorrow.")
        var daysAhead: Int

        @Guide(description: "Optional keyword to filter events by title. For example 'standup' or 'doctor'. Omit to return all events.")
        var titleFilter: String?
    }

    let calendarService: CalendarService

    func call(arguments: Arguments) async throws -> String {
        let events = try await calendarService.fetchEvents(
            daysAhead: arguments.daysAhead,
            titleFilter: arguments.titleFilter
        )

        if events.isEmpty {
            return "No events found for the next \(arguments.daysAhead) day(s)."
        }
        return events.map { "\($0.description) [eventID:\($0.id)]" }.joined(separator: "\n")
    }
}

// MARK: - DeleteCalendarEventTool

/// Lets the LLM delete a specific calendar event after the user has confirmed.
/// The model must name the event in its response before calling this tool.
struct DeleteCalendarEventTool: Tool, @unchecked Sendable {
    typealias Output = String

    nonisolated let name = "deleteCalendarEvent"
    let description = "Deletes a calendar event by ID. Only call AFTER naming the event in your response and the user confirms. Always call fetchCalendarEvents first to get the correct eventID."

    @Generable
    struct Arguments {
        @Guide(description: "The unique eventID obtained from a prior fetchCalendarEvents call. Must be an exact ID string.")
        var eventID: String

        @Guide(description: "The title of the event being deleted, used to confirm the action to the user.")
        var eventTitle: String
    }

    let calendarService: CalendarService

    func call(arguments: Arguments) async throws -> String {
        try await calendarService.deleteEvent(id: arguments.eventID)
        return "Deleted '\(arguments.eventTitle)' from your calendar."
    }
}
