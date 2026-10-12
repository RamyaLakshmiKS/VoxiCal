import EventKit
import Foundation
import FoundationModels
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

        @Guide(description: "Specific name or keyword to filter by. RULES: (1) MUST use for person queries: 'meeting with Karthik' → titleFilter='Karthik'. (2) USE for specific event-type keywords user explicitly names: 'standup' → 'standup', 'doctor' → 'doctor'. (3) MUST NOT use for broad queries ('what is on my schedule', 'any meetings today') — omit entirely. (4) NEVER use generic words: meeting, meetings, appointment, appointments, event, events, call, calls. (5) If filter returns empty, report immediately — do NOT retry without filter.")
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

        // Normalize wildcards and generic words to nil so all events are returned.
        // Generic words like "meeting" as a filter would miss events not titled that way.
        let genericFilterWords: Set<String> = [
            "meeting", "meetings", "appointment", "appointments",
            "event", "events", "call", "calls", "session", "sessions",
            "schedule", "calendar", "*", "all", "any"
        ]
        let effectiveFilter: String? = arguments.titleFilter.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty || genericFilterWords.contains(t.lowercased())) ? nil : t
        }

        let events = try await calendarService.fetchEvents(
            start: startDate,
            end: endDate,
            titleFilter: effectiveFilter
        )

        let maxEvents = 25
        let truncated = events.count > maxEvents
        let displayEvents = truncated ? Array(events.prefix(maxEvents)) : events

        if displayEvents.isEmpty {
            let resultMsg = "[TOOL RESULT] No events found"
            logger.info("\(resultMsg, privacy: .public)")
            if let filter = arguments.titleFilter, !filter.isEmpty {
                return "No events found matching '\(filter)'. There is no meeting involving '\(filter)' in this time range. Do not search again without the filter — unrelated events are not a match."
            }
            return "No events found for the requested time range."
        }

        let resultMsg = "[TOOL RESULT] Returned \(displayEvents.count) events"
        logger.info("\(resultMsg, privacy: .public)")

        // Separate human-readable event lines from internal IDs so the model
        // doesn't echo IDs into the user-facing response.
        let eventLines = displayEvents.map { event -> String in
            var parts = [event.description]
            if let loc = event.location { parts.append("at \(loc)") }
            if let notes = event.notes  { parts.append("(\(notes))") }
            return parts.joined(separator: " ")
        }.joined(separator: "\n")

        let idFormatter = DateFormatter()
        idFormatter.locale = Locale(identifier: "en_US_POSIX")
        idFormatter.dateFormat = "EEE MMM d HH:mm"
        let idSection = displayEvents.map { "  \($0.title) (\(idFormatter.string(from: $0.startDate))): \($0.id)" }.joined(separator: "\n")

        let truncationNotice = truncated ? "\n(Showing \(maxEvents) of \(events.count) events — narrow your date range to see more.)" : ""
        return """
        \(eventLines)\(truncationNotice)

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
        @Guide(description: "Event type: professional, study, gym, class, social, movie, or birthday.")
        var eventType: String

        @Guide(description: "The title or name of the event.")
        var title: String

        @Guide(description: "Start datetime in YYYY-MM-DDTHH:MM format. Birthdays use YYYY-MM-DD only. If user said a date but NO specific time, use YYYY-MM-DD so the tool blocks and asks you to collect the time.")
        var startISO: String

        @Guide(description: "Duration in minutes. Omit for social events and birthdays. Movies default to 150 min if not stated. For professional/study/gym/class: provide only what the user explicitly said.")
        var durationMinutes: Int?

        @Guide(description: "Platform or venue. Required only for professional events. Include for other types only if user mentioned it.")
        var location: String?

        @Guide(description: "true for all-day events (birthdays only). When true, only the date in startISO is used.")
        var isAllDay: Bool

        @Guide(description: "Optional notes. Omit if not provided.")
        var notes: String?

    }

    let calendarService: any CalendarServiceProtocol

    func call(arguments: Arguments) async throws -> String {
        if arguments.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("[TOOL: createCalendarEvent] blocked — title missing")
            return "Event title not specified. Ask the user for a clear title before calling this tool."
        }

        if arguments.startISO.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("[TOOL: createCalendarEvent] blocked — startISO missing")
            return "Start date and time not specified. Ask the user for the date and time (e.g., 2026-06-01T15:00) before calling this tool."
        }

        let lowerStart = arguments.startISO.lowercased()
        // Only check for vague times if startISO doesn't look like an ISO date (YYYY-MM-DD...)
        let looksLikeISO = arguments.startISO.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
        let vagueTimeIndicators = ["morning", "afternoon", "evening", "around", "later", "after lunch", "before lunch", "tonight", "this afternoon"]
        if !looksLikeISO && vagueTimeIndicators.contains(where: { lowerStart.contains($0) }) {
            logger.info("[TOOL: createCalendarEvent] blocked — vague start time: \(arguments.startISO)")
            return "The time provided is vague. Ask the user for a specific start time (e.g., 2026-06-01T15:00) before creating the event."
        }

        // Block date-only ISO (10 chars) — time was not specified.
        if !arguments.isAllDay && arguments.startISO.count == 10 {
            logger.info("[TOOL: createCalendarEvent] blocked — date given without time: \(arguments.startISO)")
            return "Start time not specified — only a date was given. Ask the user for a specific start time before calling this tool."
        }

        // Normalize event type early — used in subsequent checks.
        let eventTypeLower = arguments.eventType.lowercased()

        // Block isAllDay=true for non-birthday event types.
        if arguments.isAllDay && eventTypeLower != "birthday" && eventTypeLower != "holiday" {
            logger.info("[TOOL: createCalendarEvent] blocked — isAllDay=true for non-birthday type: \(eventTypeLower)")
            return "isAllDay should only be true for birthdays and holidays. This is a '\(eventTypeLower)' event — set isAllDay=false and ask the user for a specific time."
        }

        // Normalize empty location to nil
        let effectiveLocation: String? = arguments.location.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }

        // Enforce event-type-specific required fields
        let type = eventTypeLower
        let isProfessional = type == "professional"
        let isMovieType = type == "movie"
        let isSocialType = ["social", "birthday"].contains(type)

        // Compute effective duration (needed for conflict window and later creation).
        let effectiveDuration: Int?
        if arguments.isAllDay {
            effectiveDuration = nil
        } else if isMovieType {
            effectiveDuration = arguments.durationMinutes ?? 150
        } else if isSocialType {
            effectiveDuration = arguments.durationMinutes
        } else {
            effectiveDuration = arguments.durationMinutes  // May be nil; checked after conflict detection
        }

        let toolMsg = "[TOOL: createCalendarEvent] type=\(type), title=\(arguments.title), start=\(arguments.startISO), duration=\(effectiveDuration.map(String.init) ?? "nil"), allDay=\(arguments.isAllDay)"
        logger.info("\(toolMsg, privacy: .public)")

        guard let startDate = parseISO(arguments.startISO) else {
            let err = "[TOOL RESULT] Invalid date format: \(arguments.startISO)"
            logger.warning("\(err, privacy: .public)")
            return "Invalid date format '\(arguments.startISO)'. Use YYYY-MM-DDTHH:MM (e.g., '2025-06-15T15:00')."
        }

        // Conflict detection runs FIRST — report conflicts regardless of other missing fields.
        if !arguments.isAllDay {
            let mins = effectiveDuration ?? 60
            let endDate = startDate.addingTimeInterval(Double(mins) * 60)
            let overlapping = try await calendarService.fetchEvents(start: startDate, end: endDate, titleFilter: nil)
            if !overlapping.isEmpty {
                let conflictList = overlapping.map {
                    "• \($0.title) at \($0.description.components(separatedBy: "—").last?.trimmingCharacters(in: .whitespaces) ?? "")"
                }.joined(separator: "\n")
                logger.info("[TOOL RESULT] Scheduling conflict: \(overlapping.count) overlapping event(s)")
                return """
                Scheduling conflict: the new event overlaps with \(conflictList).
                Tell the user about this conflict conversationally. Offer: (a) pick a different time, (b) reschedule the conflicting event, (c) replace it. Do NOT act until the user decides.
                """
            }
        }

        // Block generic event titles (checked AFTER conflict detection so that an
        // overlapping time is always surfaced first — a conflict is more important
        // to the user than a title nicety).
        let titleLower = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let genericTitles: Set<String> = [
            "call", "a call", "meeting", "a meeting", "event", "an event",
            "appointment", "session", "a session", "sync", "a sync", "chat", "a chat"
        ]
        if genericTitles.contains(titleLower) {
            logger.info("[TOOL: createCalendarEvent] blocked — generic title: \(arguments.title)")
            return "The title '\(arguments.title)' is too generic. Ask the user what the event should be called (e.g., 'Call with John', 'Sprint Review', 'Doctor Appointment')."
        }

        // Location: required only for professional events (checked after conflict detection)
        if isProfessional && effectiveLocation == nil {
            logger.info("[TOOL: createCalendarEvent] blocked — professional event missing location")
            return "Location or platform not specified. Ask the user where the meeting will take place (e.g., Zoom, Conference Room A) before calling this tool."
        }

        // Duration: required for professional, study, gym, class (checked after conflict detection)
        if !arguments.isAllDay && !isMovieType && !isSocialType && effectiveDuration == nil {
            logger.info("[TOOL: createCalendarEvent] blocked — duration missing for eventType=\(type)")
            return "Duration not specified. Ask the user how long the event should be (in minutes) before calling this tool again."
        }

        let created = try await calendarService.createEvent(
            title: arguments.title,
            startDate: startDate,
            durationMinutes: effectiveDuration,
            location: effectiveLocation,
            notes: arguments.notes,
            isAllDay: arguments.isAllDay
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

        // Fix 2: Validate newDurationMinutes before calling service.
        if let dur = arguments.newDurationMinutes, dur <= 0 {
            return "Duration must be at least 1 minute. Please specify a valid duration."
        }

        var newStartDate: Date? = nil
        if let iso = arguments.newStartISO {
            guard let date = parseISO(iso) else {
                let err = "[TOOL RESULT] Invalid date format: \(iso)"
                logger.warning("\(err, privacy: .public)")
                return "Invalid date format '\(iso)'. Use YYYY-MM-DDTHH:MM (e.g., '2025-06-15T15:00')."
            }
            newStartDate = date
        }

        // Fix 3: Conflict detection before saving.
        // Compute the new time window to check for conflicts.
        if newStartDate != nil || arguments.newDurationMinutes != nil {
            // We need to know the current event's times to compute the new window.
            // Fetch a narrow range around newStartDate (or we use what we have).
            // Only check conflicts when the time is actually changing.
            if let checkStart = newStartDate {
                // Determine end of the new window: prefer explicit new duration,
                // fall back to a 24-hour sentinel so we catch any overlap.
                let checkEnd: Date
                if let dur = arguments.newDurationMinutes {
                    checkEnd = checkStart.addingTimeInterval(Double(dur) * 60)
                } else {
                    // Duration unknown at this point — assume 60 minutes as a
                    // conservative default for conflict detection.
                    checkEnd = checkStart.addingTimeInterval(60 * 60)
                }

                let overlapping = try await calendarService.fetchEvents(
                    start: checkStart,
                    end: checkEnd,
                    titleFilter: nil
                )
                // Exclude the event being updated from the conflict list.
                let conflicts = overlapping.filter { $0.id != arguments.eventID }
                if !conflicts.isEmpty {
                    let conflictList = conflicts.map {
                        "• \($0.title) — \($0.description.components(separatedBy: "—").last?.trimmingCharacters(in: .whitespaces) ?? "")"
                    }.joined(separator: "\n")
                    let conflictIDs = conflicts.map { "  \($0.title): \($0.id)" }.joined(separator: "\n")
                    let resultMsg = "[TOOL RESULT] Conflict detected: \(conflicts.count) overlapping event(s)"
                    logger.info("\(resultMsg, privacy: .public)")
                    return """
                    That time conflicts with:
                    \(conflictList)

                    Tell the user conversationally and ask how to proceed. Options:
                    (a) Pick a different time → call updateCalendarEvent with the new time
                    (b) Move the conflicting event → call updateCalendarEvent on it using its ID below
                    (c) Replace the conflicting event → call deleteCalendarEvent then proceed
                    Do NOT act until the user chooses.

                    [INTERNAL — DO NOT SHOW TO USER]
                    \(conflictIDs)
                    """
                }
            }
        }

        // Fix 1: Wrap service call in do-catch so the LLM always gets a recoverable string.
        let updated: CalendarEvent
        do {
            updated = try await calendarService.updateEvent(
                id: arguments.eventID,
                title: arguments.newTitle,
                startDate: newStartDate,
                durationMinutes: arguments.newDurationMinutes,
                location: arguments.newLocation,
                notes: arguments.newNotes,
                recurrenceScope: .thisEvent
            )
        } catch CalendarError.eventNotFound {
            return "I couldn't find that event — it may have been deleted. Please try again."
        } catch CalendarError.updateFailed(let reason) {
            return "I wasn't able to update the event: \(reason). Please try again."
        } catch {
            return "Something went wrong updating the event. Please try again."
        }

        let resultMsg = "[TOOL RESULT] Updated event: \(updated.title)"
        logger.info("\(resultMsg, privacy: .public)")

        // Fix 4: Success string uses the actual updated CalendarEvent's description.
        return "Updated '\(arguments.currentTitle)': \(updated.description)."
    }
}
