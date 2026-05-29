import FoundationModels
import Foundation

// MARK: - FetchCalendarEventsTool

/// Lets the LLM fetch upcoming calendar events for a given date range.
/// The model calls this autonomously whenever the user asks about their schedule.
struct FetchCalendarEventsTool: Tool, @unchecked Sendable {
    typealias Output = String

    nonisolated let name = "fetchCalendarEvents"
    nonisolated let description = """
        Fetches the user's upcoming calendar events from their iPhone calendar.
        Call this when the user asks about their schedule, meetings, appointments, or events.
        Always call searchPastResponses first — only call this if the cache has no fresh answer.
        """

    @Generable
    struct Arguments {
        @Guide(description: "How many days ahead to fetch, starting from today. Use 1 for today only, 7 for this week, 30 for this month.")
        var daysAhead: Int

        @Guide(description: "Optional keyword to filter events by title. For example 'standup' or 'doctor'. Omit to return all events.")
        var titleFilter: String?
    }

    let calendarService: CalendarService
    let cacheService: ResponseCacheService

    func call(arguments: Arguments) async throws -> String {
        let events = try await calendarService.fetchEvents(
            daysAhead: arguments.daysAhead,
            titleFilter: arguments.titleFilter
        )

        let result: String
        if events.isEmpty {
            result = "No events found for the next \(arguments.daysAhead) day(s)."
        } else {
            result = events.map(\.description).joined(separator: "\n")
        }

        await cacheService.store(
            query: "fetch daysAhead:\(arguments.daysAhead) filter:\(arguments.titleFilter ?? "none")",
            response: result,
            eventIDs: events.map(\.id)
        )

        return result
    }
}

// MARK: - DeleteCalendarEventTool

/// Lets the LLM delete a specific calendar event after the user has confirmed.
/// The model must name the event in its response before calling this tool.
struct DeleteCalendarEventTool: Tool, @unchecked Sendable {
    typealias Output = String

    nonisolated let name = "deleteCalendarEvent"
    nonisolated let description = """
        Permanently deletes a specific calendar event by its ID.
        Only call this AFTER you have named the event in your response and the user has confirmed deletion.
        You must first call fetchCalendarEvents to obtain the correct eventID before calling this tool.
        """

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

// MARK: - SearchCacheTool

/// Lets the LLM search previously cached query/response pairs before hitting EventKit.
/// This is the primary context-window management mechanism — by recalling past responses
/// from disk, the LLM avoids re-fetching the same calendar data repeatedly, keeping
/// the live session transcript lean and within the 4,096-token limit.
struct SearchCacheTool: Tool, @unchecked Sendable {
    typealias Output = String

    nonisolated let name = "searchPastResponses"
    nonisolated let description = """
        Searches previously cached VoxiCal responses for calendar information.
        Always call this FIRST before fetchCalendarEvents.
        If it returns a recent, relevant result, use that and skip fetchCalendarEvents.
        Only call fetchCalendarEvents if the cache returns nothing useful.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Key terms from the user's query to search the cache. For example 'today meetings' or 'this week schedule'.")
        var query: String
    }

    let cacheService: ResponseCacheService

    func call(arguments: Arguments) async throws -> String {
        let matches = await cacheService.search(query: arguments.query)

        guard !matches.isEmpty else {
            return "No cached responses found. Proceed to call fetchCalendarEvents."
        }

        let formatted = matches
            .map { entry in
                let age = RelativeDateTimeFormatter().localizedString(for: entry.timestamp, relativeTo: Date())
                return "[\(age)]\n\(entry.response)"
            }
            .joined(separator: "\n\n---\n\n")

        return formatted
    }
}
