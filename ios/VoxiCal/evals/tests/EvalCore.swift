import EventKit
import Foundation
import FoundationModels
import SwiftUI
import os.log

// MARK: - MockCalendarService

@MainActor
final class MockCalendarService: CalendarServiceProtocol {
    var seedEvents: [CalendarEvent] = []
    private(set) var fetchCallCount = 0
    private(set) var lastFetchArgs: (start: Date, end: Date, titleFilter: String?)?
    private(set) var lastFetchResult: [CalendarEvent] = []
    private(set) var createCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var lastCreatedEvent: CalendarEvent?
    private(set) var lastUpdatedEvent: CalendarEvent?
    private(set) var lastCreateArgs: (title: String, startDate: Date, durationMinutes: Int, location: String?, notes: String?)?
    private(set) var lastUpdateArgs: (eventID: String, newTitle: String?, newStartDate: Date?, newDurationMinutes: Int?, newLocation: String?, newNotes: String?)?
    private(set) var fetchArgsHistory: [(start: Date, end: Date, titleFilter: String?)] = []

    func fetchEvents(start: Date, end: Date, titleFilter: String?) async throws -> [CalendarEvent] {
        fetchCallCount += 1
        lastFetchArgs = (start, end, titleFilter)
        fetchArgsHistory.append((start, end, titleFilter))

        let result = seedEvents
            .filter { event in
                guard event.startDate < end && event.endDate > start else { return false }
                guard let filter = titleFilter, !filter.isEmpty else { return true }
                // Title-only match — aligned with real CalendarService behavior
                return event.title.localizedCaseInsensitiveContains(filter)
            }
            .sorted { $0.startDate < $1.startDate }

        lastFetchResult = result
        return result
    }

    func deleteEvent(id: String) async throws {
        seedEvents.removeAll { $0.id == id }
    }

    func createEvent(title: String, startDate: Date, durationMinutes: Int?, location: String?, notes: String?, isAllDay: Bool) async throws -> CalendarEvent {
        createCallCount += 1
        let cal = Calendar.current
        let actualStart = isAllDay ? cal.startOfDay(for: startDate) : startDate
        let mins: Int
        if isAllDay {
            mins = 1440
        } else {
            mins = durationMinutes ?? 60
        }
        lastCreateArgs = (title, actualStart, mins, location, notes)
        let endDate = isAllDay
            ? cal.date(byAdding: .day, value: 1, to: actualStart)!
            : actualStart.addingTimeInterval(Double(mins) * 60)
        let event = CalendarEvent(
            id: UUID().uuidString,
            title: title,
            startDate: actualStart,
            endDate: endDate,
            location: location,
            notes: notes,
            isAllDay: isAllDay
        )
        seedEvents.append(event)
        lastCreatedEvent = event
        return event
    }

    func updateEvent(id: String, title: String?, startDate: Date?, durationMinutes: Int?, location: String?, notes: String?, recurrenceScope: EKSpan = .thisEvent) async throws -> CalendarEvent {
        guard let index = seedEvents.firstIndex(where: { $0.id == id }) else {
            throw CalendarError.eventNotFound(id: id)
        }
        lastUpdateArgs = (eventID: id, newTitle: title, newStartDate: startDate, newDurationMinutes: durationMinutes, newLocation: location, newNotes: notes)
        updateCallCount += 1
        let existing = seedEvents[index]

        let newTitle = title ?? existing.title

        let newStart: Date
        let newEnd: Date
        if let startDate {
            let originalDuration = existing.endDate.timeIntervalSince(existing.startDate)
            let duration = durationMinutes.map { Double($0) * 60 } ?? originalDuration
            newStart = startDate
            newEnd = startDate.addingTimeInterval(duration)
        } else if let durationMinutes {
            newStart = existing.startDate
            newEnd = existing.startDate.addingTimeInterval(Double(durationMinutes) * 60)
        } else {
            newStart = existing.startDate
            newEnd = existing.endDate
        }

        let newLocation: String?
        if let location { newLocation = location.isEmpty ? nil : location }
        else { newLocation = existing.location }

        let newNotes: String?
        if let notes { newNotes = notes.isEmpty ? nil : notes }
        else { newNotes = existing.notes }

        let updated = CalendarEvent(id: id, title: newTitle, startDate: newStart, endDate: newEnd, location: newLocation, notes: newNotes, isAllDay: existing.isAllDay)
        seedEvents[index] = updated
        lastUpdatedEvent = updated
        return updated
    }

    /// Returns the seeded event with the given identifier, or nil if not found.
    func seedEvent(id: String) -> CalendarEvent? {
        seedEvents.first { $0.id == id }
    }
}

// MARK: - Golden Test Cases (3 Simple Cases)

struct GoldenTestCase {
    let id: String
    let userQuery: String
    let category: String
    let expectedBehavior: String
    let shouldCallTool: Bool
    let seedEvents: [CalendarEvent]
}

let goldenTestCases: [GoldenTestCase] = [
    // Test 1: Greeting (no tool call expected)
    GoldenTestCase(
        id: "test-greeting",
        userQuery: "Hi, how are you?",
        category: "Greeting",
        expectedBehavior: "Agent responds conversationally without calling tools",
        shouldCallTool: false,
        seedEvents: []
    ),

    // Test 2: Meeting lookup (tool call expected, events found)
    GoldenTestCase(
        id: "test-meeting-lookup",
        userQuery: "Do I have a meeting with Sarah today?",
        category: "Meeting Lookup",
        expectedBehavior: "Agent calls tool, finds Sarah's meeting, mentions it in response",
        shouldCallTool: true,
        seedEvents: [
            makeTestEvent(title: "1:1 with Sarah", daysFromNow: 0, hour: 10),
            makeTestEvent(title: "Team standup", daysFromNow: 0, hour: 9)
        ]
    ),

    // Test 3: Hallucination guard (tool call, empty calendar, must not invent meetings)
    GoldenTestCase(
        id: "test-no-hallucination",
        userQuery: "Do I have a meeting with Sarah today?",
        category: "Hallucination Guard",
        expectedBehavior: "Agent calls tool, finds no events at all, explicitly reports no events (does not hallucinate)",
        shouldCallTool: true,
        seedEvents: []
    ),

    // Test 4: Create event (all details provided — agent should call createCalendarEvent)
    GoldenTestCase(
        id: "test-create-event",
        userQuery: "Schedule a team sync tomorrow at 3pm for 30 minutes on Zoom",
        category: "Create Event",
        expectedBehavior: "Agent calls createCalendarEvent with the provided details",
        shouldCallTool: true,
        seedEvents: []
    ),

    // Test 5: Create event with conflict (agent detects overlap, reports it without creating)
    GoldenTestCase(
        id: "test-create-conflict",
        userQuery: "Schedule a sync tomorrow at 9am for 30 minutes on Teams",
        category: "Create Conflict",
        expectedBehavior: "Agent detects conflict with existing event, mentions it, does not create",
        shouldCallTool: true,
        seedEvents: [
            makeTestEvent(title: "Morning standup", daysFromNow: 1, hour: 9),
            makeTestEvent(title: "Morning standup", daysFromNow: 2, hour: 9)
        ]
    ),

    // Test 6: Update event (agent should fetch first, then call updateCalendarEvent)
    GoldenTestCase(
        id: "test-update-event",
        userQuery: "Move my team standup to 10am",
        category: "Update Event",
        expectedBehavior: "Agent calls fetchCalendarEvents then updateCalendarEvent",
        shouldCallTool: true,
        seedEvents: [
            makeTestEvent(title: "Team standup", daysFromNow: 2, hour: 9)
        ]
    ),

    // Test 7: Reschedule (update) vs create — agent should use update, not create
    GoldenTestCase(
        id: "test-create-vs-update",
        userQuery: "Reschedule my 1:1 with Sarah to 2pm",
        category: "Create vs Update",
        expectedBehavior: "Agent uses updateCalendarEvent (not create) to reschedule the existing event",
        shouldCallTool: true,
        seedEvents: [
            makeTestEvent(title: "1:1 with Sarah", daysFromNow: 3, hour: 10)
        ]
    ),

    // Test 8: Create event with missing details — agent must ask before creating
    GoldenTestCase(
        id: "test-create-missing-details",
        userQuery: "I want to schedule a meeting with Karthik",
        category: "Create Missing Details",
        expectedBehavior: "Agent asks for date, time, duration, and/or platform before calling createCalendarEvent",
        shouldCallTool: false,
        seedEvents: []
    ),

    // Test 9: No eventID exposed in response
    GoldenTestCase(
        id: "test-no-event-id-in-response",
        userQuery: "What's on my schedule today?",
        category: "No EventID Leak",
        expectedBehavior: "Agent returns event details without exposing raw eventID values to the user",
        shouldCallTool: true,
        seedEvents: [
            makeTestEvent(title: "Standup", daysFromNow: 0, hour: 9),
            makeTestEvent(title: "1:1 with Sarah", daysFromNow: 0, hour: 14)
        ]
    )
]

// MARK: - Helper Functions

func makeTestEvent(
    title: String,
    daysFromNow: Int,
    hour: Int = 10,
    durationMinutes: Int = 60,
    notes: String? = nil,
    location: String? = nil,
    isAllDay: Bool = false
) -> CalendarEvent {
    let cal = Calendar.current
    let base = cal.startOfDay(for: Date())
    let dayBase = cal.date(byAdding: .day, value: daysFromNow, to: base)!
    let start: Date
    let end: Date
    if isAllDay {
        start = cal.startOfDay(for: dayBase)
        end   = cal.date(byAdding: .day, value: 1, to: start)!
    } else {
        start = cal.date(byAdding: .hour, value: hour, to: cal.startOfDay(for: dayBase))!
        end   = start.addingTimeInterval(Double(durationMinutes) * 60)
    }
    return CalendarEvent(
        id: UUID().uuidString,
        title: title,
        startDate: start,
        endDate: end,
        location: location,
        notes: notes,
        isAllDay: isAllDay
    )
}

/// Creates multiple occurrences of a recurring-like event spread across consecutive days.
/// Each occurrence uses the same title, hour, and 60-minute duration.
/// - Parameters:
///   - title: The event title shared by all occurrences.
///   - daysFromNow: The day offset for the first occurrence.
///   - hour: The start hour (24-hour clock) for every occurrence.
///   - frequencyDays: The interval in days between consecutive occurrences.
///   - occurrences: The total number of occurrences to generate.
/// - Returns: An array of `CalendarEvent` values, one per occurrence.
func makeRecurringTestEvent(
    title: String,
    daysFromNow: Int,
    hour: Int = 10,
    frequencyDays: Int = 1,
    occurrences: Int
) -> [CalendarEvent] {
    let cal = Calendar.current
    let base = cal.startOfDay(for: Date())
    return (0..<occurrences).map { index in
        let dayOffset = daysFromNow + index * frequencyDays
        let start = cal.date(byAdding: DateComponents(day: dayOffset, hour: hour), to: base)!
        let end = start.addingTimeInterval(3600)
        return CalendarEvent(
            id: UUID().uuidString,
            title: title,
            startDate: start,
            endDate: end,
            location: nil,
            notes: nil,
            isAllDay: false
        )
    }
}

func makeRelativeDate(daysFromNow: Int, hour: Int, minute: Int = 0) -> Date {
    let cal = Calendar.current
    let base = cal.startOfDay(for: Date())
    return cal.date(byAdding: DateComponents(day: daysFromNow, hour: hour, minute: minute), to: base)!
}

// MARK: - Eval Types

struct EvalContext {
    let userMessage: String
    let agentResponse: String
    let fetchCallCount: Int
    let turnFetchCallCount: Int
    let lastFetchResult: [CalendarEvent]
    let createCallCount: Int
    let turnCreateCallCount: Int
    let updateCallCount: Int
    let turnUpdateCallCount: Int
    let lastCreatedEvent: CalendarEvent?
    let lastCreateArgs: (title: String, startDate: Date, durationMinutes: Int, location: String?, notes: String?)?
    let lastFetchArgs: (start: Date, end: Date, titleFilter: String?)?
    let fetchArgsHistory: [(start: Date, end: Date, titleFilter: String?)]
}

struct GradeResult: Identifiable {
    let id = UUID()
    let graderName: String
    let passed: Bool
    let message: String
}

typealias Grader = (EvalContext) async -> GradeResult

struct EvalTurn {
    let userMessage: String
    let graders: [Grader]
}

struct EvalScenario: Identifiable {
    let id: String
    let category: String
    let name: String
    let seedEvents: [CalendarEvent]
    let turns: [EvalTurn]
}

struct TurnResult: Identifiable {
    let id = UUID()
    let userMessage: String
    let agentResponse: String
    let fetchCallCount: Int
    let gradingResults: [GradeResult]
    var passed: Bool { gradingResults.allSatisfy(\.passed) }
}

struct EvalResult: Identifiable {
    let id = UUID()
    let scenarioID: String
    let scenarioName: String
    let category: String
    let turnResults: [TurnResult]
    var passed: Bool { turnResults.allSatisfy(\.passed) }
}

// MARK: - Code-Based Graders

func noToolCallGrader() -> Grader {
    { ctx in
        let ok = ctx.fetchCallCount == 0
        return GradeResult(
            graderName: "No tool call",
            passed: ok,
            message: ok
                ? "✓ Correctly skipped calendar lookup"
                : "✗ Called fetchCalendarEvents \(ctx.fetchCallCount) time(s) — expected 0"
        )
    }
}

func toolCalledGrader() -> Grader {
    { ctx in
        let ok = ctx.fetchCallCount > 0
        return GradeResult(
            graderName: "Tool called",
            passed: ok,
            message: ok
                ? "✓ Called fetchCalendarEvents \(ctx.fetchCallCount) time(s)"
                : "✗ Did not call tool — expected at least 1 call"
        )
    }
}

func eventFoundAndMentionedGrader() -> Grader {
    { ctx in
        let toolFoundEvents = !ctx.lastFetchResult.isEmpty
        guard toolFoundEvents else {
            return GradeResult(
                graderName: "Event found and mentioned",
                passed: false,
                message: "✗ Tool returned no events"
            )
        }

        let response = ctx.agentResponse.lowercased()

        // Pass if any significant word (>3 chars) from any event title appears in the response.
        // This handles cases where the agent paraphrases the title (e.g. "meeting with Sarah"
        // instead of "1:1 with Sarah") while still catching hallucinations.
        let anyMentioned = ctx.lastFetchResult.contains { event in
            let title = event.title.lowercased()
            if response.contains(title) { return true }
            return title.split(separator: " ").map(String.init)
                .filter { $0.count > 3 }
                .contains { response.contains($0) }
        }
        let eventTitles = ctx.lastFetchResult.map { $0.title.lowercased() }

        return GradeResult(
            graderName: "Event found and mentioned",
            passed: anyMentioned,
            message: anyMentioned
                ? "✓ Agent mentioned event: \(eventTitles.joined(separator: ", "))"
                : "✗ Agent did not mention found events"
        )
    }
}

func noEventsFoundGrader() -> Grader {
    { ctx in
        // Explicit hallucination: agent positively claimed a meeting exists when none should.
        let hallucinations = ["yes, you have", "you have a meeting", "you have an appointment", "you have an event"]
        if hallucinations.contains(where: { ctx.agentResponse.localizedCaseInsensitiveContains($0) }) {
            return GradeResult(
                graderName: "No events hallucination check",
                passed: false,
                message: "✗ Agent hallucinated a meeting that doesn't exist"
            )
        }
        // Also check the agent explicitly acknowledged no match.
        let indicators = [
            "no meeting", "no event", "no appointment",
            "nothing scheduled", "don't have", "not have",
            "not scheduled", "couldn't find", "cannot find", "can't find",
            "do not have", "doesn't appear"
        ]
        let found = indicators.contains { ctx.agentResponse.localizedCaseInsensitiveContains($0) }
        return GradeResult(
            graderName: "No events hallucination check",
            passed: found,
            message: found
                ? "✓ Agent correctly reported no matching events"
                : "✗ Agent may have hallucinated — did not report 'no matching events'"
        )
    }
}

func createToolCalledGrader() -> Grader {
    { ctx in
        let ok = ctx.createCallCount > 0
        return GradeResult(
            graderName: "Create tool called",
            passed: ok,
            message: ok
                ? "✓ Called createCalendarEvent \(ctx.createCallCount) time(s)"
                : "✗ Did not call createCalendarEvent — expected at least 1 call"
        )
    }
}

func updateToolCalledGrader() -> Grader {
    { ctx in
        let ok = ctx.updateCallCount > 0
        return GradeResult(
            graderName: "Update tool called",
            passed: ok,
            message: ok
                ? "✓ Called updateCalendarEvent \(ctx.updateCallCount) time(s)"
                : "✗ Did not call updateCalendarEvent — expected at least 1 call"
        )
    }
}

func conflictMentionedGrader() -> Grader {
    { ctx in
        let indicators = [
            "conflict", "overlap", "already have", "already scheduled",
            "clash", "same time", "existing event", "another event",
            "already an event", "already a meeting", "cannot create",
            "can't create", "unable to schedule", "time is taken",
            "time slot is", "already booked",
            // Broader conflict language the LLM may use
            "there is already", "there's already", "scheduling issue",
            "you already", "currently scheduled", "scheduling conflict",
            "occurs at the same", "that time", "that slot",
            "reschedule", "different time", "pick another",
            "overlapping", "occupied"
        ]
        let ok = indicators.contains { ctx.agentResponse.localizedCaseInsensitiveContains($0) }
        return GradeResult(
            graderName: "Conflict mentioned",
            passed: ok,
            message: ok
                ? "✓ Agent mentioned the scheduling conflict"
                : "✗ Agent did not mention the conflict despite overlap"
        )
    }
}

func noEventCreatedGrader() -> Grader {
    { ctx in
        let ok = ctx.createCallCount == 0
        return GradeResult(
            graderName: "No event created (conflict case)",
            passed: ok,
            message: ok
                ? "✓ Correctly did not create event when conflict exists"
                : "✗ Created event despite unresolved conflict"
        )
    }
}

func noCreateBeforeConfirmGrader() -> Grader {
    { ctx in
        let ok = ctx.createCallCount == 0
        return GradeResult(
            graderName: "No create before confirmation",
            passed: ok,
            message: ok
                ? "✓ Did not create event without confirming missing details"
                : "✗ Created event without confirming duration/location"
        )
    }
}

func askedForMissingDetailsGrader() -> Grader {
    { ctx in
        let indicators = [
            "duration", "how long", "how many minutes",
            "location", "platform", "where will", "where would",
            "zoom", "teams", "in person", "video call", "phone call",
            "when", "what date", "what time", "what day"
        ]
        let ok = indicators.contains { ctx.agentResponse.localizedCaseInsensitiveContains($0) }
        return GradeResult(
            graderName: "Asked for missing details",
            passed: ok,
            message: ok
                ? "✓ Agent asked for missing event details"
                : "✗ Agent did not ask for date/duration/location"
        )
    }
}

func noEventIDInResponseGrader() -> Grader {
    { ctx in
        let exposed = ctx.agentResponse.localizedCaseInsensitiveContains("eventID") ||
                      ctx.agentResponse.contains("[eventID:") ||
                      ctx.agentResponse.contains("INTERNAL") ||
                      ctx.agentResponse.contains("Event ID:")
        return GradeResult(
            graderName: "No eventID exposed to user",
            passed: !exposed,
            message: !exposed
                ? "✓ Agent did not expose eventIDs in response"
                : "✗ Agent included eventID or internal values in user-facing response"
        )
    }
}

func updateNotCreateGrader() -> Grader {
    { ctx in
        let ok = ctx.updateCallCount > 0 && ctx.createCallCount == 0
        return GradeResult(
            graderName: "Update used instead of create",
            passed: ok,
            message: ok
                ? "✓ Agent used updateCalendarEvent (not create) for rescheduling"
                : "✗ Agent used createCalendarEvent instead of updateCalendarEvent (update:\(ctx.updateCallCount), create:\(ctx.createCallCount))"
        )
    }
}

func noActionToolCallsThisTurnGrader() -> Grader {
    { ctx in
        let ok = ctx.turnFetchCallCount == 0 && ctx.turnCreateCallCount == 0 && ctx.turnUpdateCallCount == 0
        return GradeResult(
            graderName: "No action tools on this turn",
            passed: ok,
            message: ok
                ? "✓ Did not call any calendar tool during this turn"
                : "✗ Called a calendar tool during a turn that should have clarified instead"
        )
    }
}

/// Passes if the agent did NOT create or update an event this turn.
/// Unlike noActionToolCallsThisTurnGrader, this allows fetchCalendarEvents (e.g., checking availability).
func noCreateOrUpdateThisTurnGrader() -> Grader {
    { ctx in
        let ok = ctx.turnCreateCallCount == 0 && ctx.turnUpdateCallCount == 0
        return GradeResult(
            graderName: "No create/update before confirmation",
            passed: ok,
            message: ok
                ? "✓ Correctly did not create or update event without confirming missing details"
                : "✗ Created or updated event during a turn that should have clarified missing details first"
        )
    }
}

func responseContainsAnyGrader(name: String, indicators: [String]) -> Grader {
    { ctx in
        let ok = indicators.contains { ctx.agentResponse.localizedCaseInsensitiveContains($0) }
        return GradeResult(
            graderName: name,
            passed: ok,
            message: ok
                ? "✓ Agent asked for the missing or ambiguous detail"
                : "✗ Agent response did not clearly ask for clarification"
        )
    }
}

func createPayloadMatchesGrader(
    expectedTitle: String,
    expectedStart: Date,
    expectedDurationMinutes: Int,
    expectedLocation: String?,
    expectedNotes: String? = nil
) -> Grader {
    { ctx in
        guard let created = ctx.lastCreatedEvent else {
            return GradeResult(
                graderName: "Create payload matches expected values",
                passed: false,
                message: "✗ No created event was captured"
            )
        }

        let durationMinutes = Int(created.endDate.timeIntervalSince(created.startDate) / 60)
        let ok = created.title == expectedTitle &&
            Calendar.current.isDate(created.startDate, equalTo: expectedStart, toGranularity: .minute) &&
            durationMinutes == expectedDurationMinutes &&
            created.location == expectedLocation &&
            created.notes == expectedNotes

        let expectedDescription = "title=\(expectedTitle), start=\(expectedStart), duration=\(expectedDurationMinutes), location=\(expectedLocation ?? "nil")"
        return GradeResult(
            graderName: "Create payload matches expected values",
            passed: ok,
            message: ok
                ? "✓ Created event matched the expected payload"
                : "✗ Created event did not match expected payload: \(expectedDescription); got title=\(created.title), start=\(created.startDate), duration=\(durationMinutes), location=\(created.location ?? "nil")"
        )
    }
}

func createClarificationGrader() -> Grader {
    responseContainsAnyGrader(
        name: "Asked for clarification",
        indicators: ["when", "what time", "how long", "duration", "location", "platform", "which", "please",
                     "where", "what date", "what day", "specific time", "start time", "date", "time"]
    )
}

func createPromptAskForDateTimeGrader() -> Grader {
    responseContainsAnyGrader(
        name: "Asked for date or time",
        indicators: ["when", "what time", "what date", "what day", "time", "date"]
    )
}

func createPromptAskForDurationGrader() -> Grader {
    responseContainsAnyGrader(
        name: "Asked for duration",
        indicators: ["duration", "how long", "how many minutes", "minutes"]
    )
}

func createPromptAskForLocationGrader() -> Grader {
    responseContainsAnyGrader(
        name: "Asked for location or platform",
        indicators: ["location", "platform", "zoom", "teams", "meet", "where"]
    )
}

func createPromptAskForSpecificTimeGrader() -> Grader {
    responseContainsAnyGrader(
        name: "Asked for a specific time",
        indicators: ["specific time", "exact time", "what time", "which time", "what hour"]
    )
}

func createPromptAskForTitleGrader() -> Grader {
    responseContainsAnyGrader(
        name: "Asked for event title or name",
        indicators: ["title", "name", "call it", "what should", "name the event", "event name", "what to call", "what would you like to call", "what do you want to call"]
    )
}

func titleFilterUsedGrader(expectedFilter: String) -> Grader {
    { ctx in
        guard let args = ctx.lastFetchArgs else {
            return GradeResult(graderName: "titleFilter used: \(expectedFilter)", passed: false,
                message: "✗ fetchCalendarEvents was never called — cannot check titleFilter")
        }
        guard let filter = args.titleFilter else {
            return GradeResult(graderName: "titleFilter used: \(expectedFilter)", passed: false,
                message: "✗ Called without titleFilter — expected filter='\(expectedFilter)'")
        }
        let ok = filter.localizedCaseInsensitiveContains(expectedFilter)
        return GradeResult(graderName: "titleFilter used: \(expectedFilter)", passed: ok,
            message: ok ? "✓ Called with titleFilter='\(filter)'"
                       : "✗ titleFilter was '\(filter)' — expected to contain '\(expectedFilter)'")
    }
}

func noTitleFilterUsedGrader() -> Grader {
    { ctx in
        guard let args = ctx.lastFetchArgs else {
            return GradeResult(graderName: "No titleFilter on broad query", passed: false,
                message: "✗ fetchCalendarEvents was never called")
        }
        let usedFilter = args.titleFilter.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        return GradeResult(graderName: "No titleFilter on broad query", passed: !usedFilter,
            message: !usedFilter
                ? "✓ Called without titleFilter — correct for a broad schedule query"
                : "✗ Used titleFilter='\(args.titleFilter!)' on a broad query — misses events not named with that word")
    }
}

func singleFetchCallThisTurnGrader() -> Grader {
    { ctx in
        let ok = ctx.turnFetchCallCount == 1
        return GradeResult(graderName: "Single fetch call this turn", passed: ok,
            message: ok ? "✓ fetchCalendarEvents called exactly once this turn"
                : ctx.turnFetchCallCount == 0
                    ? "✗ Not called this turn — expected exactly 1 call"
                    : "✗ Called \(ctx.turnFetchCallCount) times — must use a single call for the full date range")
    }
}

func fetchedForCorrectDayGrader(expectedDate: Date) -> Grader {
    { ctx in
        guard let args = ctx.lastFetchArgs else {
            return GradeResult(graderName: "Fetched correct day", passed: false,
                message: "✗ fetchCalendarEvents was never called")
        }
        let cal = Calendar.current
        // Only verify start date — end date varies based on whether the agent treats endISO as inclusive or adds a day.
        let startOk = cal.isDate(args.start, inSameDayAs: expectedDate)
        let df = DateFormatter(); df.dateFormat = "EEE, MMM d yyyy"
        return GradeResult(graderName: "Fetched correct day", passed: startOk,
            message: startOk ? "✓ Fetched correct day: \(df.string(from: expectedDate))"
                             : "✗ Wrong start date: fetched=\(df.string(from: args.start)), expected=\(df.string(from: expectedDate))")
    }
}

func noFetchPositiveClaimGrader() -> Grader {
    { ctx in
        guard ctx.turnFetchCallCount == 0 else {
            return GradeResult(graderName: "No hallucination without fetch", passed: true,
                message: "✓ Agent fetched before answering — not a hallucination risk")
        }
        let positiveClaims = ["you have", "you've got", "there is a", "there's a",
            "i see", "i found", "you're scheduled", "you are scheduled",
            "your meeting", "your appointment", "your event", "yes, you"]
        let madePositiveClaim = positiveClaims.contains { ctx.agentResponse.localizedCaseInsensitiveContains($0) }
        return GradeResult(graderName: "No hallucination without fetch", passed: !madePositiveClaim,
            message: !madePositiveClaim
                ? "✓ Agent did not assert event existence without fetching calendar data"
                : "✗ Agent made a positive event claim without calling fetchCalendarEvents — potential hallucination")
    }
}

func personNameInFetchFilterGrader(personName: String) -> Grader {
    { ctx in
        guard ctx.turnFetchCallCount > 0 else {
            return GradeResult(graderName: "Person name in titleFilter: \(personName)", passed: false,
                message: "✗ fetchCalendarEvents not called — expected a fetch with titleFilter='\(personName)'")
        }
        guard let args = ctx.lastFetchArgs else {
            return GradeResult(graderName: "Person name in titleFilter: \(personName)", passed: false,
                message: "✗ No fetch args captured")
        }
        let filterUsed = args.titleFilter?.localizedCaseInsensitiveContains(personName) == true
        return GradeResult(graderName: "Person name in titleFilter: \(personName)", passed: filterUsed,
            message: filterUsed
                ? "✓ Used titleFilter='\(args.titleFilter!)' for '\(personName)' query"
                : "✗ Did not use '\(personName)' as titleFilter (got: \(args.titleFilter ?? "nil")) — unfiltered fetch may cause false positives")
    }
}

func noMarkdownInResponseGrader() -> Grader {
    { ctx in
        let r = ctx.agentResponse
        let hasBullets   = r.contains("• ") || r.contains("- ") || r.contains("* ")
        let hasBold      = r.range(of: #"\*\*[^*]+\*\*"#, options: .regularExpression) != nil
        let hasHeaders   = r.range(of: #"\n#{1,3}\s"#, options: .regularExpression) != nil
        let hasNumbered  = r.range(of: #"\n\d+\.\s"#, options: .regularExpression) != nil
        let hasMarkdown  = hasBullets || hasBold || hasHeaders || hasNumbered
        return GradeResult(graderName: "No markdown in voice response", passed: !hasMarkdown,
            message: !hasMarkdown
                ? "✓ Response uses plain conversational text suitable for TTS"
                : "✗ Response contains markdown (bullets=\(hasBullets), bold=\(hasBold), headers=\(hasHeaders), numbered=\(hasNumbered)) — sounds broken when read aloud")
    }
}

func noUUIDInResponseGrader() -> Grader {
    { ctx in
        let uuidPattern    = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        let longHexPattern = #"[0-9A-Fa-f]{16,}"#
        let hasUUID        = ctx.agentResponse.range(of: uuidPattern, options: .regularExpression) != nil
        let hasLongHex     = ctx.agentResponse.range(of: longHexPattern, options: .regularExpression) != nil
        let hasMarkers     = ctx.agentResponse.contains("INTERNAL")
                          || ctx.agentResponse.contains("[eventID:")
                          || ctx.agentResponse.contains("Event ID:")
                          || ctx.agentResponse.contains("eventID")
        let exposed = hasUUID || hasLongHex || hasMarkers
        return GradeResult(graderName: "No UUID or eventID in response", passed: !exposed,
            message: !exposed
                ? "✓ No raw event IDs or internal markers in user-facing response"
                : "✗ Response contains UUID/hex/INTERNAL marker (uuid=\(hasUUID), longHex=\(hasLongHex), marker=\(hasMarkers)) — eventID leaked to user")
    }
}

func nothingScheduledNotDontKnowGrader() -> Grader {
    { ctx in
        let emptyIndicators = ["nothing scheduled", "no events", "no meetings", "no appointments",
            "nothing on", "nothing coming up", "calendar is empty",
            "don't have anything", "do not have anything", "you're free", "you are free",
            "couldn't find", "cannot find", "can't find", "didn't find", "don't see"]
        let uncertaintyIndicators = ["i'm not sure", "i don't know", "i cannot determine",
            "i can't tell", "not certain", "unclear", "not able to"]
        let expressesDontKnow = uncertaintyIndicators.contains { ctx.agentResponse.localizedCaseInsensitiveContains($0) }
        if expressesDontKnow {
            return GradeResult(graderName: "Empty calendar: state fact not uncertainty", passed: false,
                message: "✗ Agent said 'I don't know' — should state 'nothing scheduled' as a fact when tool confirms empty")
        }
        let statesEmpty = emptyIndicators.contains { ctx.agentResponse.localizedCaseInsensitiveContains($0) }
        return GradeResult(graderName: "Empty calendar: state fact not uncertainty", passed: statesEmpty,
            message: statesEmpty ? "✓ Agent correctly reported no scheduled events"
                                 : "✗ Agent did not clearly state calendar is empty for the requested period")
    }
}

func eventTitleMentionedByNameGrader(expectedTitle: String) -> Grader {
    { ctx in
        let response = ctx.agentResponse.lowercased()
        let titleLower = expectedTitle.lowercased()
        if response.contains(titleLower) {
            return GradeResult(graderName: "Event title mentioned: \(expectedTitle)", passed: true,
                message: "✓ Agent mentioned '\(expectedTitle)' in response")
        }
        let words = titleLower.split(separator: " ").map(String.init).filter { $0.count > 3 }
        let anyWordMatch = words.contains { response.contains($0) }
        return GradeResult(graderName: "Event title mentioned: \(expectedTitle)", passed: anyWordMatch,
            message: anyWordMatch
                ? "✓ Agent mentioned key words from '\(expectedTitle)'"
                : "✗ Agent did not mention '\(expectedTitle)' or any keyword from it")
    }
}

func eventCountMatchesGrader(expectedCount: Int) -> Grader {
    { ctx in
        let actual = ctx.lastFetchResult.count
        let ok = actual == expectedCount
        return GradeResult(graderName: "Fetch returned expected event count", passed: ok,
            message: ok ? "✓ Tool returned exactly \(expectedCount) event(s) as expected"
                       : "✗ Tool returned \(actual) event(s) — expected \(expectedCount). Wrong date range or titleFilter may have over/under-filtered.")
    }
}

func refetchOnNewDayQueryGrader() -> Grader {
    { ctx in
        let ok = ctx.turnFetchCallCount >= 1
        return GradeResult(graderName: "Re-fetched for new day query", passed: ok,
            message: ok ? "✓ Agent called fetchCalendarEvents again for the new date (\(ctx.turnFetchCallCount) call(s) this turn)"
                       : "✗ Agent answered a new-day follow-up without fetching — may be reusing stale context")
    }
}

func nonCalendarQueryNoFetchGrader() -> Grader {
    { ctx in
        let ok = ctx.turnFetchCallCount == 0
        return GradeResult(graderName: "No calendar fetch for non-calendar query", passed: ok,
            message: ok ? "✓ Agent correctly skipped calendar fetch for a non-calendar query"
                       : "✗ Agent called fetchCalendarEvents \(ctx.turnFetchCallCount) time(s) for a query that does not require calendar access")
    }
}

// MARK: - Additional Graders

/// Fails if the response contains any tool name that should be hidden from users.
func noToolNameInResponseGrader() -> Grader {
    { ctx in
        let toolNames = ["createCalendarEvent", "updateCalendarEvent", "deleteCalendarEvent", "fetchCalendarEvents"]
        let exposed = toolNames.contains { ctx.agentResponse.contains($0) }
        return GradeResult(
            graderName: "No internal tool name in response",
            passed: !exposed,
            message: !exposed
                ? "✓ Agent did not expose internal tool names to the user"
                : "✗ Agent mentioned an internal tool name in the user-facing response (e.g. createCalendarEvent, updateCalendarEvent)"
        )
    }
}

/// Fails if the response starts with a numbered list marker ("1.", "2.") on any line.
func noNumberedListGrader() -> Grader {
    { ctx in
        let hasNumbered = ctx.agentResponse.range(of: #"(^|\n)\d+\.\s"#, options: .regularExpression) != nil
        return GradeResult(
            graderName: "No numbered list",
            passed: !hasNumbered,
            message: !hasNumbered
                ? "✓ Response does not use a numbered list"
                : "✗ Response uses a numbered list — sounds unnatural when read aloud by TTS"
        )
    }
}

/// Passes only when the response contains none of the common markdown patterns AND
/// none of the numbered-list patterns. Combines noMarkdownInResponseGrader + noNumberedListGrader.
func strictlyPlainTextGrader() -> Grader {
    { ctx in
        let r = ctx.agentResponse
        let hasBullets  = r.contains("• ") || r.range(of: #"(^|\n)[*-] "#, options: .regularExpression) != nil
        let hasBold     = r.range(of: #"\*\*[^*]+\*\*"#, options: .regularExpression) != nil
        let hasHeaders  = r.range(of: #"\n#{1,3}\s"#, options: .regularExpression) != nil
        let hasNumbered = r.range(of: #"(^|\n)\d+\.\s"#, options: .regularExpression) != nil
        let hasMarkdown = hasBullets || hasBold || hasHeaders || hasNumbered
        return GradeResult(
            graderName: "Strictly plain text (no markdown, no lists)",
            passed: !hasMarkdown,
            message: !hasMarkdown
                ? "✓ Response is plain conversational prose — safe for TTS"
                : "✗ Response contains formatting (bullets=\(hasBullets), bold=\(hasBold), headers=\(hasHeaders), numbered=\(hasNumbered)) — sounds broken when read aloud"
        )
    }
}

/// Passes when the response does NOT confirm an action that the tool did not actually perform.
func noFalseSuccessClaimGrader() -> Grader {
    { ctx in
        // If no mutation tool was called this turn, agent must not claim success
        let noMutation = ctx.turnCreateCallCount == 0 && ctx.turnUpdateCallCount == 0
        guard noMutation else {
            return GradeResult(graderName: "No false success claim", passed: true,
                message: "✓ A mutation tool was called — success claim is plausible")
        }
        let falseClaims = ["successfully created", "successfully scheduled", "successfully updated",
                           "successfully rescheduled", "successfully deleted", "successfully moved",
                           "successfully removed", "has been created", "has been updated",
                           "has been rescheduled", "has been deleted"]
        let hasFalseClaim = falseClaims.contains { ctx.agentResponse.localizedCaseInsensitiveContains($0) }
        return GradeResult(graderName: "No false success claim", passed: !hasFalseClaim,
            message: !hasFalseClaim
                ? "✓ Agent did not falsely claim a mutation succeeded without calling the tool"
                : "✗ Agent claimed success for an action it did not perform (no mutation tool was called)")
    }
}

// MARK: - EvalRunner

@MainActor
@Observable
final class EvalRunner {
    var results: [EvalResult] = []
    var isRunning = false
    var progress: Double = 0
    var fetchOnly: Bool = false

    func run(scenarios: [EvalScenario]) async {
        guard !isRunning else { return }
        isRunning = true
        results = []
        progress = 0

        for (index, scenario) in scenarios.enumerated() {
            if index > 0 { try? await Task.sleep(for: .seconds(3)) }
            let result = await runScenario(scenario)
            results.append(result)
            progress = Double(index + 1) / Double(scenarios.count)
        }

        isRunning = false
    }

    private func runScenario(_ scenario: EvalScenario) async -> EvalResult {
        let mock = MockCalendarService()
        mock.seedEvents = scenario.seedEvents

        // Read-only scenarios only need the fetch tool — omitting Create/Update saves ~800 tokens
        // of tool schema context, preventing context window overflow on longer read queries.
        let tools: [any Tool] = fetchOnly
            ? [FetchCalendarEventsTool(calendarService: mock)]
            : [
                FetchCalendarEventsTool(calendarService: mock),
                DeleteCalendarEventTool(calendarService: mock),
                CreateCalendarEventTool(calendarService: mock),
                UpdateCalendarEventTool(calendarService: mock)
              ]

        let instructions = VoxiCalAgent.buildInstructions()

        let session = LanguageModelSession(
            tools: tools,
            instructions: instructions
        )

        var turnResults: [TurnResult] = []

        for turn in scenario.turns {
            let previousFetchCount = mock.fetchCallCount
            let previousCreateCount = mock.createCallCount
            let previousUpdateCount = mock.updateCallCount

            let agentResponse: String
            var lastError: Error?
            var responseContent: String?
            for attempt in 1...3 {
                do {
                    let response = try await session.respond(to: turn.userMessage)
                    responseContent = response.content
                    break
                } catch {
                    lastError = error
                    let desc = error.localizedDescription.lowercased()
                    let isTransient = desc.contains("error -1") || desc.contains("generation")
                    guard isTransient && attempt < 3 else { break }
                    try? await Task.sleep(for: .seconds(Double(attempt * 3)))
                }
            }
            agentResponse = responseContent ?? "[ERROR: \(lastError?.localizedDescription ?? "unknown")]"

            let turnFetchCount = mock.fetchCallCount - previousFetchCount
            let turnCreateCount = mock.createCallCount - previousCreateCount
            let turnUpdateCount = mock.updateCallCount - previousUpdateCount

            let context = EvalContext(
                userMessage: turn.userMessage,
                agentResponse: agentResponse,
                fetchCallCount: mock.fetchCallCount,
                turnFetchCallCount: turnFetchCount,
                lastFetchResult: mock.lastFetchResult,
                createCallCount: mock.createCallCount,
                turnCreateCallCount: turnCreateCount,
                updateCallCount: mock.updateCallCount,
                turnUpdateCallCount: turnUpdateCount,
                lastCreatedEvent: mock.lastCreatedEvent,
                lastCreateArgs: mock.lastCreateArgs,
                lastFetchArgs: mock.lastFetchArgs,
                fetchArgsHistory: mock.fetchArgsHistory
            )

            var gradingResults: [GradeResult] = []
            for grader in turn.graders {
                gradingResults.append(await grader(context))
            }

            turnResults.append(TurnResult(
                userMessage: turn.userMessage,
                agentResponse: agentResponse,
                fetchCallCount: mock.fetchCallCount,
                gradingResults: gradingResults
            ))
        }

        return EvalResult(
            scenarioID: scenario.id,
            scenarioName: scenario.name,
            category: scenario.category,
            turnResults: turnResults
        )
    }
}

// MARK: - Build Scenarios from Test Cases

func buildEvalScenarios() -> [EvalScenario] {
    return goldenTestCases.map { testCase in
        var graders: [Grader] = []

        switch testCase.id {
        case "test-greeting":
            graders.append(noToolCallGrader())

        case "test-meeting-lookup":
            graders.append(toolCalledGrader())
            graders.append(eventFoundAndMentionedGrader())

        case "test-no-hallucination":
            graders.append(toolCalledGrader())
            graders.append(noEventsFoundGrader())

        case "test-create-event":
            graders.append(createToolCalledGrader())

        case "test-create-conflict":
            graders.append(toolCalledGrader())
            graders.append(conflictMentionedGrader())
            graders.append(noEventCreatedGrader())

        case "test-update-event":
            graders.append(toolCalledGrader())
            graders.append(updateToolCalledGrader())

        case "test-create-vs-update":
            graders.append(toolCalledGrader())
            graders.append(updateNotCreateGrader())

        case "test-create-missing-details":
            graders.append(noCreateBeforeConfirmGrader())
            graders.append(askedForMissingDetailsGrader())

        case "test-no-event-id-in-response":
            graders.append(toolCalledGrader())
            graders.append(noEventIDInResponseGrader())

        default:
            if testCase.shouldCallTool {
                graders.append(toolCalledGrader())
            } else {
                graders.append(noToolCallGrader())
            }
        }

        return EvalScenario(
            id: testCase.id,
            category: testCase.category,
            name: testCase.userQuery,
            seedEvents: testCase.seedEvents,
            turns: [EvalTurn(userMessage: testCase.userQuery, graders: graders)]
        )
    }
}

// MARK: - Test Harness

@MainActor
func runEvaluationSuite() async -> (passed: Int, failed: Int) {
    let scenarios = buildEvalScenarios()
    let runner = EvalRunner()
    await runner.run(scenarios: scenarios)

    let logger = Logger(subsystem: "com.ramya-app.VoxiCal.evals", category: "TestHarness")

    print("\n" + String(repeating: "=", count: 80))
    print("EVALUATION RESULTS - 3 Code-Based Test Cases")
    print(String(repeating: "=", count: 80))

    let totalPassed = runner.results.filter(\.passed).count
    let totalFailed = runner.results.count - totalPassed

    for result in runner.results {
        let status = result.passed ? "✓ PASS" : "✗ FAIL"
        print("\n[\(status)] \(result.scenarioName)")
        print("    Category: \(result.category)")

        for turnResult in result.turnResults {
            print("    User: \(turnResult.userMessage)")
            print("    Agent: \(turnResult.agentResponse)")
            print("    Tool calls: \(turnResult.fetchCallCount)")

            for grade in turnResult.gradingResults {
                print("    \(grade.message)")
            }
        }
    }

    print("\n" + String(repeating: "=", count: 80))
    print("SUMMARY: \(totalPassed)/\(runner.results.count) passed")
    print(String(repeating: "=", count: 80) + "\n")

    logger.info("Eval results: \(totalPassed)/\(runner.results.count) passed")

    return (totalPassed, totalFailed)
}
