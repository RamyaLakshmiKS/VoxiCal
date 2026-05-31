import FoundationModels
import Foundation
import os.log

// MARK: - Shared Date Parsing

/// Parses a date string in "yyyy-MM-dd'T'HH:mm" format using the device's local timezone.
private func parseISO(_ iso: String) -> Date? {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.date(from: iso)
}

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
        let toolMsg = "[TOOL: fetchCalendarEvents] daysAhead=\(arguments.daysAhead), daysBack=\(arguments.daysBack), \(filterStr)"
        print(toolMsg)
        logger.info("\(toolMsg, privacy: .public)")
        
        let events = try await calendarService.fetchEvents(
            daysAhead: arguments.daysAhead,
            daysBack: arguments.daysBack,
            titleFilter: arguments.titleFilter
        )

        if events.isEmpty {
            let resultMsg = "[TOOL RESULT] No events found"
            print(resultMsg)
            logger.info("\(resultMsg, privacy: .public)")
            return "No events found for the requested time range."
        }
        
        let resultMsg = "[TOOL RESULT] Returned \(events.count) events"
        print(resultMsg)
        logger.info("\(resultMsg, privacy: .public)")

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
        let toolMsg = "[TOOL: deleteCalendarEvent] eventID=\(arguments.eventID), title=\(arguments.eventTitle)"
        print(toolMsg)
        logger.info("\(toolMsg, privacy: .public)")

        try await calendarService.deleteEvent(id: arguments.eventID)

        let resultMsg = "[TOOL RESULT] Successfully deleted event: \(arguments.eventTitle)"
        print(resultMsg)
        logger.info("\(resultMsg, privacy: .public)")

        return "Deleted '\(arguments.eventTitle)' from your calendar."
    }
}

// MARK: - CreateCalendarEventTool

/// Lets the LLM create a new calendar event after confirming all details with the user.
/// Built-in conflict detection returns overlap info without creating when conflicts exist.
struct CreateCalendarEventTool: Tool, @unchecked Sendable {
    typealias Output = String

    nonisolated let name = "createCalendarEvent"
    let description = "Creates a new calendar event. Only call after the user has confirmed the title, date, time, duration, and meeting platform. Performs conflict detection automatically."

    private let logger = Logger(subsystem: "com.ramya-app.VoxiCal.calendar", category: "CreateTool")

    @Generable
    struct Arguments {
        @Guide(description: "The title or name of the event.")
        var title: String

        @Guide(description: "Start date and time in YYYY-MM-DDTHH:MM format using local time. Example: '2025-06-15T15:00' for June 15 at 3:00 PM.")
        var startISO: String

        @Guide(description: "Duration of the event in minutes, as confirmed by the user. Always ask the user if not specified.")
        var durationMinutes: Int

        @Guide(description: "Meeting platform or room (e.g., 'Zoom', 'Google Meet', 'Teams', 'Conference Room A', 'In person'). Always ask if not provided. Omit only if user explicitly says there is none.")
        var location: String?

        @Guide(description: "Optional notes or description. Omit if not provided by the user.")
        var notes: String?

        @Guide(description: "Set to true only when the user has explicitly confirmed they want to create the event despite an existing scheduling conflict. Default is false.")
        var confirmDespiteConflict: Bool
    }

    let calendarService: any CalendarServiceProtocol

    func call(arguments: Arguments) async throws -> String {
        let toolMsg = "[TOOL: createCalendarEvent] title=\(arguments.title), start=\(arguments.startISO), duration=\(arguments.durationMinutes)min, override=\(arguments.confirmDespiteConflict)"
        print(toolMsg)
        logger.info("\(toolMsg, privacy: .public)")

        guard let startDate = parseISO(arguments.startISO) else {
            let err = "[TOOL RESULT] Invalid date format: \(arguments.startISO)"
            print(err)
            logger.warning("\(err, privacy: .public)")
            return "Invalid date format '\(arguments.startISO)'. Use YYYY-MM-DDTHH:MM (e.g., '2025-06-15T15:00')."
        }

        let endDate = startDate.addingTimeInterval(Double(arguments.durationMinutes) * 60)

        // Conflict detection — skipped if the user already confirmed override
        if !arguments.confirmDespiteConflict {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let eventDay = cal.startOfDay(for: startDate)
            let daysFromToday = cal.dateComponents([.day], from: today, to: eventDay).day ?? 0

            if daysFromToday >= 0 {
                let daysAhead = max(1, daysFromToday + 1)
                let existing = try await calendarService.fetchEvents(daysAhead: daysAhead, daysBack: 0, titleFilter: nil)
                let overlapping = existing.filter { $0.startDate < endDate && $0.endDate > startDate }

                if !overlapping.isEmpty {
                    let conflictList = overlapping.map { "• \($0.title) at \($0.description.components(separatedBy: "—").last?.trimmingCharacters(in: .whitespaces) ?? "")" }.joined(separator: "\n")
                    let resultMsg = "[TOOL RESULT] Conflict detected: \(overlapping.count) overlapping event(s)"
                    print(resultMsg)
                    logger.info("\(resultMsg, privacy: .public)")
                    return "Conflict detected — you already have:\n\(conflictList)\n\nAsk the user whether to pick a different time or proceed anyway."
                }
            }
        }

        let created = try await calendarService.createEvent(
            title: arguments.title,
            startDate: startDate,
            durationMinutes: arguments.durationMinutes,
            location: arguments.location,
            notes: arguments.notes
        )

        let resultMsg = "[TOOL RESULT] Created event: \(created.title)"
        print(resultMsg)
        logger.info("\(resultMsg, privacy: .public)")

        return "Created '\(created.title)' — \(created.description.components(separatedBy: "—").last?.trimmingCharacters(in: .whitespaces) ?? "")."
    }
}

// MARK: - UpdateCalendarEventTool

/// Lets the LLM update specific fields of an existing calendar event.
/// Always requires a prior fetchCalendarEvents call to obtain the eventID.
struct UpdateCalendarEventTool: Tool, @unchecked Sendable {
    typealias Output = String

    nonisolated let name = "updateCalendarEvent"
    let description = "Updates an existing calendar event. Always call fetchCalendarEvents first to get the exact eventID. Only pass fields the user explicitly wants changed."

    private let logger = Logger(subsystem: "com.ramya-app.VoxiCal.calendar", category: "UpdateTool")

    @Generable
    struct Arguments {
        @Guide(description: "The exact eventID from a prior fetchCalendarEvents call. Never guess or construct an ID.")
        var eventID: String

        @Guide(description: "The current title of the event, used to confirm the update to the user.")
        var currentTitle: String

        @Guide(description: "New title if the user wants to rename the event. Omit to keep unchanged.")
        var newTitle: String?

        @Guide(description: "New start date and time in YYYY-MM-DDTHH:MM local format. For relative changes ('next hour', 'next Monday', 'Friday at 2pm'), compute the actual date from today before calling. Omit to keep unchanged.")
        var newStartISO: String?

        @Guide(description: "New duration in minutes. Only include if the user explicitly changes the duration. Omit to keep the original duration.")
        var newDurationMinutes: Int?

        @Guide(description: "New meeting platform or location. Pass empty string \"\" to clear. Omit (nil) to leave unchanged.")
        var newLocation: String?

        @Guide(description: "New notes or description. Pass empty string \"\" to clear. Omit (nil) to leave unchanged.")
        var newNotes: String?
    }

    let calendarService: any CalendarServiceProtocol

    func call(arguments: Arguments) async throws -> String {
        let toolMsg = "[TOOL: updateCalendarEvent] eventID=\(arguments.eventID), title=\(arguments.currentTitle)"
        print(toolMsg)
        logger.info("\(toolMsg, privacy: .public)")

        var newStartDate: Date? = nil
        if let iso = arguments.newStartISO {
            guard let date = parseISO(iso) else {
                let err = "[TOOL RESULT] Invalid date format: \(iso)"
                print(err)
                logger.warning("\(err, privacy: .public)")
                return "Invalid date format '\(iso)'. Use YYYY-MM-DDTHH:MM (e.g., '2025-06-15T15:00')."
            }
            newStartDate = date
        }

        let updated = try await calendarService.updateEvent(
            id: arguments.eventID,
            title: arguments.newTitle,
            startDate: newStartDate,
            durationMinutes: arguments.newDurationMinutes,
            location: arguments.newLocation,
            notes: arguments.newNotes
        )

        let resultMsg = "[TOOL RESULT] Updated event: \(updated.title)"
        print(resultMsg)
        logger.info("\(resultMsg, privacy: .public)")

        return "Updated '\(arguments.currentTitle)': \(updated.description)."
    }
}
