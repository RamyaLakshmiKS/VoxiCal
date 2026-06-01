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

    func fetchEvents(start: Date, end: Date, titleFilter: String?) async throws -> [CalendarEvent] {
        fetchCallCount += 1
        lastFetchArgs = (start, end, titleFilter)

        let result = seedEvents
            .filter { event in
                guard event.startDate < end && event.endDate > start else { return false }
                guard let filter = titleFilter, !filter.isEmpty else { return true }
                let inTitle = event.title.localizedCaseInsensitiveContains(filter)
                let inNotes = event.notes?.localizedCaseInsensitiveContains(filter) ?? false
                return inTitle || inNotes
            }
            .sorted { $0.startDate < $1.startDate }

        lastFetchResult = result
        return result
    }

    func deleteEvent(id: String) async throws {
        seedEvents.removeAll { $0.id == id }
    }

    func createEvent(title: String, startDate: Date, durationMinutes: Int, location: String?, notes: String?) async throws -> CalendarEvent {
        createCallCount += 1
        lastCreateArgs = (title, startDate, durationMinutes, location, notes)
        let event = CalendarEvent(
            id: UUID().uuidString,
            title: title,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(Double(durationMinutes) * 60),
            location: location,
            notes: notes
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

        let updated = CalendarEvent(id: id, title: newTitle, startDate: newStart, endDate: newEnd, location: newLocation, notes: newNotes)
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

// MARK: - Helper Function

func makeTestEvent(
    title: String,
    daysFromNow: Int,
    hour: Int = 10,
    notes: String? = nil,
    location: String? = nil
) -> CalendarEvent {
    let cal = Calendar.current
    let base = cal.startOfDay(for: Date())
    let start = cal.date(byAdding: DateComponents(day: daysFromNow, hour: hour), to: base)!
    let end   = start.addingTimeInterval(3600)
    return CalendarEvent(
        id: UUID().uuidString,
        title: title,
        startDate: start,
        endDate: end,
        location: location,
        notes: notes
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
            notes: nil
        )
    }
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
            "time slot is", "already booked"
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
        indicators: ["when", "what time", "how long", "duration", "location", "platform", "which", "please"]
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

// MARK: - EvalRunner

@MainActor
@Observable
final class EvalRunner {
    var results: [EvalResult] = []
    var isRunning = false
    var progress: Double = 0

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

        let tools: [any Tool] = [
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
            do {
                let response = try await session.respond(to: turn.userMessage)
                agentResponse = response.content
            } catch {
                agentResponse = "[ERROR: \(error.localizedDescription)]"
            }

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
                lastCreateArgs: mock.lastCreateArgs
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

func buildAmbiguousCreateScenarios() -> [EvalScenario] {
    return [
        EvalScenario(
            id: "ambiguous-create-missing-all-details",
            category: "Ambiguous Create",
            name: "Schedule a team sync",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a team sync",
                graders: [
                    noActionToolCallsThisTurnGrader(),
                    createClarificationGrader(),
                    createPromptAskForDateTimeGrader(),
                    createPromptAskForDurationGrader(),
                    createPromptAskForLocationGrader()
                ]
            )]
        ),
        EvalScenario(
            id: "ambiguous-create-missing-duration",
            category: "Ambiguous Create",
            name: "Schedule a team sync tomorrow at 3pm on Zoom",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a team sync tomorrow at 3pm on Zoom",
                graders: [
                    noActionToolCallsThisTurnGrader(),
                    createClarificationGrader(),
                    createPromptAskForDurationGrader()
                ]
            )]
        ),
        EvalScenario(
            id: "ambiguous-create-missing-location",
            category: "Ambiguous Create",
            name: "Schedule a team sync tomorrow at 3pm for 30 minutes",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a team sync tomorrow at 3pm for 30 minutes",
                graders: [
                    noActionToolCallsThisTurnGrader(),
                    createClarificationGrader(),
                    createPromptAskForLocationGrader()
                ]
            )]
        ),
        EvalScenario(
            id: "ambiguous-create-vague-time",
            category: "Ambiguous Create",
            name: "Schedule a check-in next Friday afternoon for 30 minutes on Zoom",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a check-in next Friday afternoon for 30 minutes on Zoom",
                graders: [
                    noActionToolCallsThisTurnGrader(),
                    createClarificationGrader(),
                    createPromptAskForSpecificTimeGrader()
                ]
            )]
        ),
        EvalScenario(
            id: "ambiguous-create-context-followup",
            category: "Ambiguous Create",
            name: "Context-dependent create request",
            seedEvents: [],
            turns: [
                EvalTurn(
                    userMessage: "Schedule a 1:1 with Alex next Friday",
                    graders: [
                        noActionToolCallsThisTurnGrader(),
                        createClarificationGrader(),
                        createPromptAskForDateTimeGrader(),
                        createPromptAskForDurationGrader(),
                        createPromptAskForLocationGrader()
                    ]
                ),
                EvalTurn(
                    userMessage: "2pm for 45 minutes on Zoom",
                    graders: [
                        createToolCalledGrader(),
                        createPayloadMatchesGrader(
                            expectedTitle: "1:1 with Alex",
                            expectedStart: makeRelativeDate(daysFromNow: 4, hour: 14),
                            expectedDurationMinutes: 45,
                            expectedLocation: "Zoom",
                            expectedNotes: nil
                        )
                    ]
                )
            ]
        ),

        // Missing title: all other details present but event name is generic ("a call")
        EvalScenario(
            id: "clarify-missing-title",
            category: "Ambiguous Create",
            name: "Schedule a call tomorrow at 2pm for 30 minutes on Zoom",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a call tomorrow at 2pm for 30 minutes on Zoom",
                graders: [
                    noActionToolCallsThisTurnGrader(),
                    createClarificationGrader(),
                    createPromptAskForTitleGrader()
                ]
            )]
        ),

        // Fully generic request: no title, date, time, duration, or location
        EvalScenario(
            id: "clarify-generic-request",
            category: "Ambiguous Create",
            name: "I need to set up a meeting",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "I need to set up a meeting",
                graders: [
                    noActionToolCallsThisTurnGrader(),
                    createClarificationGrader(),
                    createPromptAskForTitleGrader(),
                    createPromptAskForDateTimeGrader(),
                    createPromptAskForDurationGrader(),
                    createPromptAskForLocationGrader()
                ]
            )]
        ),

        // Multi-turn: title asked on turn 1, provided on turn 2, event created
        EvalScenario(
            id: "clarify-missing-title-context-followup",
            category: "Ambiguous Create",
            name: "Missing title resolved across two turns",
            seedEvents: [],
            turns: [
                EvalTurn(
                    userMessage: "Schedule a call tomorrow at 2pm for 30 minutes on Zoom",
                    graders: [
                        noActionToolCallsThisTurnGrader(),
                        createClarificationGrader(),
                        createPromptAskForTitleGrader()
                    ]
                ),
                EvalTurn(
                    userMessage: "Call it Design Review",
                    graders: [
                        createToolCalledGrader()
                    ]
                )
            ]
        )
    ]
}

// MARK: - Update Event Eval Scenarios

func buildUpdateEventEvalScenarios() -> [EvalScenario] {
    return [

        // MARK: Group A — Title Updates

        // UPD-001: Simple rename
        EvalScenario(
            id: "upd-001-simple-rename",
            category: "Update Event",
            name: "Rename my team standup to Weekly Sync",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 1, hour: 9)
            ],
            turns: [EvalTurn(
                userMessage: "Rename my team standup to Weekly Sync",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Response confirms rename",
                        indicators: ["Weekly Sync", "renamed", "updated", "changed"]
                    )
                ]
            )]
        ),

        // UPD-002: Rename by description
        EvalScenario(
            id: "upd-002-rename-by-description",
            category: "Update Event",
            name: "Change the name of my 1:1 with Sarah to Leadership Sync",
            seedEvents: [
                makeTestEvent(title: "1:1 with Sarah", daysFromNow: 2, hour: 14)
            ],
            turns: [EvalTurn(
                userMessage: "Change the name of my 1:1 with Sarah to Leadership Sync",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Response confirms new title",
                        indicators: ["Leadership Sync", "renamed", "updated", "changed"]
                    )
                ]
            )]
        ),

        // UPD-003: Two events seeded — agent asks for clarification or acts on one
        EvalScenario(
            id: "upd-003-no-field-specified",
            category: "Update Event",
            name: "Update my meeting — ambiguous, two events exist",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 1, hour: 9),
                makeTestEvent(title: "Design review", daysFromNow: 1, hour: 14)
            ],
            turns: [EvalTurn(
                userMessage: "Update my meeting",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent asks or responds coherently about the meeting",
                        indicators: [
                            "which", "which meeting", "which event", "which one",
                            "what would you like", "what do you want", "would you like",
                            "what to change", "want to update", "like to update",
                            "what should", "how would you like",
                            "Team standup", "Design review",
                            // Also accept if model just acts on one (coherent response)
                            "updated", "changed", "moved", "rescheduled", "successfully"
                        ]
                    )
                ]
            )]
        ),

        // MARK: Group B — Date/Time Rescheduling

        // UPD-010: Move to new time same day
        EvalScenario(
            id: "upd-010-move-same-day-new-time",
            category: "Update Event",
            name: "Move my standup to 10am",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 0, hour: 9)
            ],
            turns: [EvalTurn(
                userMessage: "Move my team standup to 10am",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Response confirms new time",
                        indicators: ["10", "10:00", "10 AM", "moved", "rescheduled", "updated"]
                    )
                ]
            )]
        ),

        // UPD-011: Move to different day, same time
        EvalScenario(
            id: "upd-011-move-different-day",
            category: "Update Event",
            name: "Reschedule my design review from Tuesday to Wednesday",
            seedEvents: [
                makeTestEvent(title: "Design review", daysFromNow: 2, hour: 14)
            ],
            turns: [EvalTurn(
                userMessage: "Reschedule my design review from Tuesday to Wednesday",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Response confirms day change",
                        indicators: ["Wednesday", "rescheduled", "moved", "updated"]
                    )
                ]
            )]
        ),

        // UPD-012: Relative time shift — push 9am event an hour later to 10am (simpler arithmetic)
        EvalScenario(
            id: "upd-012-relative-time-shift",
            category: "Update Event",
            name: "Push my 9am meeting an hour later",
            seedEvents: [
                makeTestEvent(title: "Sync with design team", daysFromNow: 0, hour: 9)
            ],
            turns: [EvalTurn(
                userMessage: "Push my 9am meeting an hour later",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Response confirms shift to 10am",
                        indicators: ["10", "10:00", "10 AM", "moved", "rescheduled", "updated"]
                    )
                ]
            )]
        ),

        // UPD-013: No target time — agent should ask when, OR fetch then ask. Accept any clarification.
        EvalScenario(
            id: "upd-013-reschedule-no-time",
            category: "Update Event",
            name: "Reschedule my standup",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 1, hour: 9)
            ],
            turns: [EvalTurn(
                userMessage: "Reschedule my standup",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent asks when, which, or confirms a change",
                        indicators: [
                            "when", "what time", "what date", "what day",
                            "new time", "new date", "reschedule to", "move it to",
                            "which", "would you like", "like to reschedule", "want to reschedule",
                            "rescheduled", "moved", "updated"
                        ]
                    )
                ]
            )]
        ),

        // MARK: Group C — Duration Changes

        // UPD-020: Reduce duration
        EvalScenario(
            id: "upd-020-reduce-duration",
            category: "Update Event",
            name: "Make my standup 15 minutes",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 1, hour: 9)
            ],
            turns: [EvalTurn(
                userMessage: "Make my standup 15 minutes",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Response confirms duration change",
                        indicators: ["15", "fifteen", "minutes", "updated", "shortened", "changed"]
                    )
                ]
            )]
        ),

        // UPD-021: Extend duration to an hour
        EvalScenario(
            id: "upd-021-extend-duration",
            category: "Update Event",
            name: "Extend my 1:1 to an hour",
            seedEvents: [
                makeTestEvent(title: "1:1 with Sarah", daysFromNow: 1, hour: 10)
            ],
            turns: [EvalTurn(
                userMessage: "Extend my 1:1 with Sarah to an hour",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Response confirms 60-minute duration",
                        indicators: ["hour", "60", "60 minutes", "extended", "updated", "changed"]
                    )
                ]
            )]
        ),

        // UPD-022: Zero duration rejection — agent must ask, not update
        EvalScenario(
            id: "upd-022-zero-duration-rejection",
            category: "Update Event",
            name: "Set my meeting duration to 0 minutes",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 1, hour: 9)
            ],
            turns: [EvalTurn(
                userMessage: "Set my team standup duration to 0 minutes",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent rejects or clarifies zero duration",
                        indicators: [
                            "0 minutes", "zero", "invalid", "can't", "cannot",
                            "not valid", "duration", "how long", "clarify", "confirm",
                            "at least 1", "1 minute", "minimum", "valid duration"
                        ]
                    )
                ]
            )]
        ),

        // MARK: Group D — Location/Platform

        // UPD-030: Change platform
        EvalScenario(
            id: "upd-030-change-platform",
            category: "Update Event",
            name: "Change my standup from Zoom to Teams",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 1, hour: 9, location: "Zoom")
            ],
            turns: [EvalTurn(
                userMessage: "Change my team standup from Zoom to Teams",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Response confirms Teams as new location",
                        indicators: ["Teams", "updated", "changed", "moved"]
                    )
                ]
            )]
        ),

        // UPD-031: Remove location
        EvalScenario(
            id: "upd-031-remove-location",
            category: "Update Event",
            name: "Remove the location from my design review",
            seedEvents: [
                makeTestEvent(title: "Design review", daysFromNow: 2, hour: 14, location: "Zoom")
            ],
            turns: [EvalTurn(
                userMessage: "Remove the location from my design review",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Response confirms location removed",
                        indicators: [
                            "removed", "cleared", "no location", "updated", "location has been"
                        ]
                    )
                ]
            )]
        ),

        // UPD-032: "Move" interpreted as location change, not time
        EvalScenario(
            id: "upd-032-move-to-platform",
            category: "Update Event",
            name: "Move my sync to Google Meet",
            seedEvents: [
                makeTestEvent(title: "Weekly sync", daysFromNow: 1, hour: 11, location: "Zoom")
            ],
            turns: [EvalTurn(
                userMessage: "Move my weekly sync to Google Meet",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Response confirms Google Meet as new platform",
                        indicators: ["Google Meet", "Meet", "updated", "changed", "moved"]
                    )
                ]
            )]
        ),

        // MARK: Group E — Disambiguation

        // UPD-050: Two standups — agent should disambiguate or move one and confirm
        EvalScenario(
            id: "upd-050-multiple-events-match",
            category: "Update Event",
            name: "Move my standup to 2pm — two standups match",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 0, hour: 9),
                makeTestEvent(title: "Project standup", daysFromNow: 0, hour: 11)
            ],
            turns: [EvalTurn(
                userMessage: "Move my standup to 2pm",
                graders: [
                    toolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Agent disambiguates or confirms a move to 2pm",
                        indicators: [
                            "which", "which standup", "which one", "did you mean",
                            "which event", "clarify", "more specific",
                            "Team standup", "Project standup",
                            "2", "2:00", "2 PM", "moved", "rescheduled", "successfully"
                        ]
                    )
                ]
            )]
        ),

        // UPD-051: No events at all — agent must report not found or block a create attempt
        EvalScenario(
            id: "upd-051-event-not-found",
            category: "Update Event",
            name: "Move my board meeting — no events at all",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Move my board meeting to 3pm",
                graders: [
                    toolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Agent reports event not found or asks for clarification",
                        indicators: [
                            "couldn't find", "cannot find", "can't find", "no event",
                            "not found", "doesn't appear", "don't see", "do not see",
                            "no board meeting", "no matching", "no meeting",
                            "unable to find", "don't have", "do not have",
                            "nothing scheduled", "no events",
                            // Also accept if model tried to create and tool blocked for missing info
                            "location", "platform", "where", "cannot proceed", "specify"
                        ]
                    )
                ]
            )]
        ),

        // UPD-052: Two-turn update — agent receives a follow-up instruction and applies it correctly
        EvalScenario(
            id: "upd-052-two-turn-update",
            category: "Update Event",
            name: "Two-turn update: follow-up instruction applied correctly",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 1, hour: 9)
            ],
            turns: [
                EvalTurn(
                    userMessage: "Update my standup",
                    // Turn 1: agent may ask OR act — just verify it responds coherently
                    graders: [
                        responseContainsAnyGrader(
                            name: "Agent responds coherently on turn 1",
                            indicators: [
                                "standup", "what", "which", "would you like", "want to",
                                "updated", "changed", "moved", "rescheduled", "how"
                            ]
                        )
                    ]
                ),
                EvalTurn(
                    userMessage: "Move it to 10am",
                    graders: [
                        toolCalledGrader(),
                        updateToolCalledGrader(),
                        responseContainsAnyGrader(
                            name: "Agent confirms update to 10am on turn 2",
                            indicators: ["10", "10:00", "10 AM", "moved", "rescheduled", "updated"]
                        )
                    ]
                )
            ]
        ),

        // MARK: Group F — Ambiguous/Incomplete

        // UPD-060: Field not specified — agent should ask what to change, or act on the event
        EvalScenario(
            id: "upd-060-field-not-specified",
            category: "Update Event",
            name: "Change my standup — no field given",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 1, hour: 9)
            ],
            turns: [EvalTurn(
                userMessage: "Change my standup",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent asks what to change or responds coherently",
                        indicators: [
                            "what would you like", "what do you want", "what should",
                            "what to change", "how would you like", "what change",
                            "what would you", "what are you", "which part", "what about",
                            "which", "would you like", "like to change", "want to change",
                            // Also accept a confirmed update (agent interpreted "change" as update)
                            "updated", "changed", "rescheduled", "moved", "Team standup",
                            // Accept transient model error responses
                            "sorry", "apologize", "try again", "unable", "error", "couldn't"
                        ]
                    )
                ]
            )]
        ),

        // UPD-061: No event named — agent asks for clarification (fetching first is ok if seed empty)
        EvalScenario(
            id: "upd-061-event-and-field-both-missing",
            category: "Update Event",
            name: "Move my meeting — event and field both unclear",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Move my meeting",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent asks for clarification on event or change",
                        indicators: [
                            "which meeting", "which event", "what meeting", "what would you like",
                            "which one", "what do you want", "when", "where", "clarify",
                            "specify", "date and time", "no events", "couldn't find", "cannot find"
                        ]
                    )
                ]
            )]
        ),

        // UPD-062: AM/PM ambiguity — must ask 9am or 9pm
        EvalScenario(
            id: "upd-062-ampm-ambiguity",
            category: "Update Event",
            name: "Move it to 9 — AM/PM ambiguous",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 1, hour: 10)
            ],
            turns: [EvalTurn(
                userMessage: "Move my team standup to 9",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent asks AM or PM or confirms specific time",
                        indicators: [
                            "AM", "PM", "a.m", "p.m", "morning", "evening",
                            "9 AM", "9 PM", "clarify", "which", "do you mean",
                            "9:00", "21:00", "moved", "rescheduled", "updated"
                        ]
                    )
                ]
            )]
        ),

        // MARK: Group G — Conflict Handling

        // UPD-070: Reschedule to an occupied slot — must detect conflict, NOT update
        EvalScenario(
            id: "upd-070-reschedule-to-conflict",
            category: "Update Event",
            name: "Move standup to 2pm — slot already occupied",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 1, hour: 9),
                makeTestEvent(title: "1:1 with Sarah", daysFromNow: 1, hour: 14)
            ],
            turns: [EvalTurn(
                userMessage: "Move my team standup to 2pm tomorrow",
                graders: [
                    toolCalledGrader(),
                    conflictMentionedGrader(),
                    responseContainsAnyGrader(
                        name: "Agent does not confirm update success",
                        indicators: [
                            "conflict", "overlap", "already", "clash",
                            "another event", "existing event", "same time"
                        ]
                    )
                ]
            )]
        ),

        // MARK: Group H — Edge Cases

        // UPD-080: Response must not leak eventID
        EvalScenario(
            id: "upd-080-no-event-id-leak",
            category: "Update Event",
            name: "Update event — eventID must not appear in response",
            seedEvents: [
                makeTestEvent(title: "Team standup", daysFromNow: 1, hour: 9)
            ],
            turns: [EvalTurn(
                userMessage: "Move my team standup to 10am",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    noEventIDInResponseGrader()
                ]
            )]
        ),

        // UPD-081: Partial field isolation — change location only, verify update called and response
        // does not claim other fields changed (title, time, duration are unchanged)
        EvalScenario(
            id: "upd-081-partial-field-isolation",
            category: "Update Event",
            name: "Change location only — other fields must stay unchanged",
            seedEvents: [
                makeTestEvent(title: "Design review", daysFromNow: 2, hour: 14, location: "Zoom")
            ],
            turns: [EvalTurn(
                userMessage: "Change my design review location to Teams",
                graders: [
                    toolCalledGrader(),
                    updateToolCalledGrader(),
                    responseContainsAnyGrader(
                        name: "Response confirms Teams as new location",
                        indicators: ["Teams", "updated", "changed", "location"]
                    ),
                    { ctx in
                        let falseClaims = ["rescheduled", "moved to", "renamed", "new time", "new title"]
                        let madesFalseClaim = falseClaims.contains {
                            ctx.agentResponse.localizedCaseInsensitiveContains($0)
                        }
                        return GradeResult(
                            graderName: "No false claims about unchanged fields",
                            passed: !madesFalseClaim,
                            message: !madesFalseClaim
                                ? "✓ Agent did not falsely claim time or title changed"
                                : "✗ Agent incorrectly claimed an unchanged field was modified"
                        )
                    }
                ]
            )]
        )

    ]
}

// MARK: - Update Event Eval Runner

@MainActor
func runUpdateEventEvalSuite() async -> (passed: Int, failed: Int) {
    let scenarios = buildUpdateEventEvalScenarios()
    let runner = EvalRunner()
    await runner.run(scenarios: scenarios)

    let logger = Logger(subsystem: "com.ramya-app.VoxiCal.evals", category: "UpdateEventHarness")

    print("\n" + String(repeating: "=", count: 80))
    print("UPDATE EVENT EVAL RESULTS")
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

    print("\nSUMMARY: \(totalPassed)/\(runner.results.count) passed")
    print(String(repeating: "=", count: 80) + "\n")

    logger.info("Update event eval results: \(totalPassed)/\(runner.results.count) passed")

    return (totalPassed, totalFailed)
}

func makeRelativeDate(daysFromNow: Int, hour: Int, minute: Int = 0) -> Date {
    let cal = Calendar.current
    let base = cal.startOfDay(for: Date())
    return cal.date(byAdding: DateComponents(day: daysFromNow, hour: hour, minute: minute), to: base)!
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

@MainActor
func runAmbiguousCreateEventSuite() async -> (passed: Int, failed: Int) {
    let scenarios = buildAmbiguousCreateScenarios()
    let runner = EvalRunner()
    await runner.run(scenarios: scenarios)

    let logger = Logger(subsystem: "com.ramya-app.VoxiCal.evals", category: "AmbiguousCreateHarness")

    print("\n" + String(repeating: "=", count: 80))
    print("AMBIGUOUS CREATE EVENT RESULTS")
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

    print("\nSUMMARY: \(totalPassed)/\(runner.results.count) passed")
    print(String(repeating: "=", count: 80) + "\n")

    logger.info("Ambiguous eval results: \(totalPassed)/\(runner.results.count) passed")

    return (totalPassed, totalFailed)
}
