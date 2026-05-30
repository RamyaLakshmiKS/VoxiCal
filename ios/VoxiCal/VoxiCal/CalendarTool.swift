import FoundationModels
import Foundation
import os.log

// MARK: - FetchCalendarEventsTool

/// Lets the LLM fetch calendar events for a given date range (past and future).
/// The model calls this autonomously whenever the user asks about their schedule.
struct FetchCalendarEventsTool: Tool, @unchecked Sendable {
    typealias Output = String

    nonisolated let name = "fetchCalendarEvents"
    let description = "Fetches calendar events. Call this when the user asks about their schedule, meetings, or appointments — past or future."
    
    private let logger = Logger(subsystem: "com.ramya-app.VoxiCal.calendar", category: "FetchTool")

    @Generable
    struct Arguments {
        @Guide(description: """
            Number of days to fetch starting from today (inclusive). \
            Use 1 for today only, 2 to include tomorrow, 7 for this week, \
            30 for this month, 60 for next month, up to 180 for queries \
            spanning several months. Always use 2 when the user asks about tomorrow.
            """)
        var daysAhead: Int

        @Guide(description: """
            Number of days to look back from today (0 = no history). \
            Use 30 for last month, 60 for two months ago, up to 180 (≈ 6 months). \
            Combine with daysAhead to span past and future together.
            """)
        var daysBack: Int

        @Guide(description: "Optional keyword to filter events by title. For example 'standup' or 'doctor'. Omit to return all events.")
        var titleFilter: String?
    }

    let calendarService: any CalendarServiceProtocol

    func call(arguments: Arguments) async throws -> String {
        let filterStr = arguments.titleFilter.map { "filter: \($0)" } ?? "no filter"
        logger.info("[TOOL: fetchCalendarEvents] daysAhead=\(arguments.daysAhead), daysBack=\(arguments.daysBack), \(filterStr)")
        let events = try await calendarService.fetchEvents(
            daysAhead: arguments.daysAhead,
            daysBack: arguments.daysBack,
            titleFilter: arguments.titleFilter
        )

        if events.isEmpty {
            logger.info("[TOOL RESULT] No events found")
            return "No events found for the requested time range."
        }
        
        logger.info("[TOOL RESULT] Returned \(events.count) events")

        return events.map { event in
            var parts = [event.description]
            if let loc = event.location { parts.append("Location: \(loc)") }
            if let notes = event.notes   { parts.append("Notes: \(notes)") }
            parts.append("[eventID:\(event.id)]")
            return parts.joined(separator: " | ")
        }.joined(separator: "\n")
    }
}

// MARK: - DeleteCalendarEventTool

/// Lets the LLM delete a specific calendar event after the user has confirmed.
/// The model must name the event in its response before calling this tool.
struct DeleteCalendarEventTool: Tool, @unchecked Sendable {
    typealias Output = String

    nonisolated let name = "deleteCalendarEvent"
    let description = "Deletes a calendar event by ID. Only call AFTER naming the event in your response and the user confirms. Always call fetchCalendarEvents first to get the correct eventID."
    
    private let logger = Logger(subsystem: "com.ramya-app.VoxiCal.calendar", category: "DeleteTool")

    @Generable
    struct Arguments {
        @Guide(description: "The unique eventID obtained from a prior fetchCalendarEvents call. Must be an exact ID string.")
        var eventID: String

        @Guide(description: "The title of the event being deleted, used to confirm the action to the user.")
        var eventTitle: String
    }

    let calendarService: any CalendarServiceProtocol

    func call(arguments: Arguments) async throws -> String {
        logger.info("[TOOL: deleteCalendarEvent] eventID=\(arguments.eventID), title=\(arguments.eventTitle)")
        try await calendarService.deleteEvent(id: arguments.eventID)
        logger.info("[TOOL RESULT] Successfully deleted event: \(arguments.eventTitle)")
        return "Deleted '\(arguments.eventTitle)' from your calendar."
    }
}
