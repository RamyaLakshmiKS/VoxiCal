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

    func updateEvent(id: String, title: String?, startDate: Date?, durationMinutes: Int?, location: String?, notes: String?) async throws -> CalendarEvent {
        guard let index = seedEvents.firstIndex(where: { $0.id == id }) else {
            throw CalendarError.eventNotFound(id: id)
        }
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
                            expectedStart: makeRelativeDate(daysFromNow: 5, hour: 14),
                            expectedDurationMinutes: 45,
                            expectedLocation: "Zoom",
                            expectedNotes: nil
                        )
                    ]
                )
            ]
        )
    ]
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
