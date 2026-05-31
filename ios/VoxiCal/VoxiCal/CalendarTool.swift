import FoundationModels
import Foundation
import os.log

// MARK: - Shared Date Parsing

/// Parses "yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm", or "yyyy-MM-dd'T'HH:mm:ss" using local timezone.
private func parseISO(_ iso: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    switch iso.count {
    case 10: f.dateFormat = "yyyy-MM-dd"
    case 16: f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    default: f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    }
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
            Start date in YYYY-MM-DD format. Compute from today's date: \
            "today" → today's date, "2 days ago" → subtract 2 days, \
            "next Monday" → the date of next Monday, \
            "August 15th" → the literal date. Always use local calendar date.
            """)
        var startISO: String

        @Guide(description: """
            End date in YYYY-MM-DD format, inclusive. \
            For a single day set the same value as startISO. \
            For a range: "this week" → 6 days after startISO, \
            "next month" → last day of that month, \
            "past 3 days through tomorrow" → tomorrow's date.
            """)
        var endISO: String

        @Guide(description: "Specific name or keyword to filter by — e.g. 'Karthik', 'standup', 'doctor'. Omit for broad queries like 'what's on my schedule' or 'any meetings'. NEVER use generic words like 'meeting' or 'appointment' — they miss events not titled that way.")
        var titleFilter: String?
    }

    let calendarService: any CalendarServiceProtocol

    func call(arguments: Arguments) async throws -> String {
        let filterStr = arguments.titleFilter.map { "filter: \($0)" } ?? "no filter"
        // (effective filter computed after wildcard normalization below)
        let toolMsg = "[TOOL: fetchCalendarEvents] start=\(arguments.startISO), end=\(arguments.endISO), \(filterStr)"
        logger.info("\(toolMsg, privacy: .public)")

        guard let startDate = parseISO(arguments.startISO) else {
            return "Invalid start date '\(arguments.startISO)'. Use YYYY-MM-DD format."
        }
        guard let endDay = parseISO(arguments.endISO) else {
            return "Invalid end date '\(arguments.endISO)'. Use YYYY-MM-DD format."
        }
        // Make end exclusive: fetch up to end of the specified end day
        let endDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: endDay))!

        // Normalize wildcard filters (*, all, any) to nil so all events are returned.
        let effectiveFilter: String? = arguments.titleFilter.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty || t == "*" || t.lowercased() == "all" || t.lowercased() == "any") ? nil : t
        }

        let events = try await calendarService.fetchEvents(
            start: startDate,
            end: endDate,
            titleFilter: effectiveFilter
        )

        if events.isEmpty {
            let resultMsg = "[TOOL RESULT] No events found"
            logger.info("\(resultMsg, privacy: .public)")
            if let filter = arguments.titleFilter, !filter.isEmpty {
                return "No events found matching '\(filter)'. There is no meeting involving '\(filter)' in this time range. Do not search again without the filter — unrelated events are not a match."
            }
            return "No events found for the requested time range."
        }
        
        let resultMsg = "[TOOL RESULT] Returned \(events.count) events"
        logger.info("\(resultMsg, privacy: .public)")

        // Separate human-readable event lines from internal IDs so the model
        // doesn't echo IDs into the user-facing response.
        let eventLines = events.map { event -> String in
            var parts = [event.description]
            if let loc = event.location { parts.append("at \(loc)") }
            if let notes = event.notes  { parts.append("(\(notes))") }
            return parts.joined(separator: " ")
        }.joined(separator: "\n")

        let idSection = events.map { "  \($0.title): \($0.id)" }.joined(separator: "\n")

        return """
        \(eventLines)

        [INTERNAL — DO NOT SHOW TO USER — use only for update/delete tool calls]
        \(idSection)
        """
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
        logger.info("\(toolMsg, privacy: .public)")

        try await calendarService.deleteEvent(id: arguments.eventID)

        let resultMsg = "[TOOL RESULT] Successfully deleted event: \(arguments.eventTitle)"
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

        @Guide(description: "Start date and time in YYYY-MM-DDTHH:MM format using local time. Compute from today's ISO date. Example: if today is 2026-05-31, then tomorrow 9am = '2026-06-01T09:00'.")
        var startISO: String

        @Guide(description: "Duration in minutes, as explicitly stated by the user. Omit (nil) if the user has not specified a duration — the tool will prompt you to ask first. NEVER assume 60 or any default.")
        var durationMinutes: Int?

        @Guide(description: "Meeting platform or room (e.g., 'Zoom', 'Google Meet', 'Teams', 'Conference Room A', 'In person'). Always ask if not provided. Omit only if user explicitly says there is none.")
        var location: String?

        @Guide(description: "Optional notes or description. Omit if not provided by the user.")
        var notes: String?

    }

    let calendarService: any CalendarServiceProtocol

    func call(arguments: Arguments) async throws -> String {
        guard let durationMinutes = arguments.durationMinutes else {
            logger.info("[TOOL: createCalendarEvent] blocked — duration missing")
            return "Duration not specified. Ask the user how long the event should be (in minutes) before calling this tool again."
        }

        let toolMsg = "[TOOL: createCalendarEvent] title=\(arguments.title), start=\(arguments.startISO), duration=\(durationMinutes)min"
        logger.info("\(toolMsg, privacy: .public)")

        guard let startDate = parseISO(arguments.startISO) else {
            let err = "[TOOL RESULT] Invalid date format: \(arguments.startISO)"
            logger.warning("\(err, privacy: .public)")
            return "Invalid date format '\(arguments.startISO)'. Use YYYY-MM-DDTHH:MM (e.g., '2025-06-15T15:00')."
        }

        let endDate = startDate.addingTimeInterval(Double(durationMinutes) * 60)

        // Always run conflict detection.
        let overlapping = try await calendarService.fetchEvents(start: startDate, end: endDate, titleFilter: nil)
        if !overlapping.isEmpty {
            let conflictList = overlapping.map {
                "• \($0.title) — \($0.description.components(separatedBy: "—").last?.trimmingCharacters(in: .whitespaces) ?? "")"
            }.joined(separator: "\n")
            let conflictIDs = overlapping.map { "  \($0.title): \($0.id)" }.joined(separator: "\n")
            let resultMsg = "[TOOL RESULT] Conflict detected: \(overlapping.count) overlapping event(s)"
            logger.info("\(resultMsg, privacy: .public)")
            return """
            Conflict detected. The new event overlaps with:
            \(conflictList)

            Tell the user conversationally and ask how to proceed. Options:
            (a) Pick a different time → call createCalendarEvent with the new time
            (b) Move the existing event → call updateCalendarEvent using its ID below
            (c) Replace the existing event → call deleteCalendarEvent then createCalendarEvent
            Do NOT act until the user chooses.

            [INTERNAL — DO NOT SHOW TO USER]
            \(conflictIDs)
            """
        }

        let created = try await calendarService.createEvent(
            title: arguments.title,
            startDate: startDate,
            durationMinutes: durationMinutes,
            location: arguments.location,
            notes: arguments.notes
        )

        let resultMsg = "[TOOL RESULT] Created event: \(created.title)"
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

        @Guide(description: "New start date and time in YYYY-MM-DDTHH:MM local format. Compute from today's ISO date — e.g., if today is 2026-05-30, then 'next Monday 2pm' = '2026-06-01T14:00'. Omit to keep unchanged.")
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
        logger.info("\(toolMsg, privacy: .public)")

        var newStartDate: Date? = nil
        if let iso = arguments.newStartISO {
            guard let date = parseISO(iso) else {
                let err = "[TOOL RESULT] Invalid date format: \(iso)"
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
        logger.info("\(resultMsg, privacy: .public)")

        return "Updated '\(arguments.currentTitle)': \(updated.description)."
    }
}
