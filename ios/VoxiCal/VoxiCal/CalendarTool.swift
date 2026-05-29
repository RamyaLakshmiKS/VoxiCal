import FoundationModels
import Foundation

// MARK: - FetchCalendarEventsTool

/// Lets the LLM fetch upcoming calendar events for a given date range.
/// The model calls this autonomously whenever the user asks about their schedule.
struct FetchCalendarEventsTool: Tool, @unchecked Sendable {
    typealias Output = String

    nonisolated let name = "fetchCalendarEvents"
    let description = "Fetches upcoming calendar events. Call this when the user asks about their schedule, meetings, or appointments. Always call searchPastResponses first."

    @Generable
    struct Arguments {
        @Guide(description: "Number of days to fetch starting from today (inclusive). Use 1 for today only, 2 to include tomorrow, 3 for today through the day after tomorrow, 7 for this week, 30 for this month. Always use 2 when the user asks about tomorrow.")
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
            result = events.map { "\($0.description) [eventID:\($0.id)]" }.joined(separator: "\n")
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

// MARK: - SearchCacheTool

/// Lets the LLM search previously cached query/response pairs before hitting EventKit.
/// This is the primary context-window management mechanism — by recalling past responses
/// from disk, the LLM avoids re-fetching the same calendar data repeatedly, keeping
/// the live session transcript lean and within the 4,096-token limit.
struct SearchCacheTool: Tool, @unchecked Sendable {
    typealias Output = String

    nonisolated let name = "searchPastResponses"
    let description = "Searches cached responses for calendar information. Call this FIRST before fetchCalendarEvents. If a recent result is found, use it and skip fetching. Only fetch if cache returns nothing."

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
