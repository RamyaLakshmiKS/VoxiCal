import Foundation
import FoundationModels
import SwiftUI
import os.log

// MARK: - CalendarServiceProtocol

protocol CalendarServiceProtocol: AnyObject {
    func fetchEvents(start: Date, end: Date, titleFilter: String?) async throws -> [CalendarEvent]
    func deleteEvent(id: String) async throws
    func createEvent(title: String, startDate: Date, durationMinutes: Int, location: String?, notes: String?) async throws -> CalendarEvent
    func updateEvent(id: String, title: String?, startDate: Date?, durationMinutes: Int?, location: String?, notes: String?) async throws -> CalendarEvent
}

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

    func fetchEvents(start: Date, end: Date, titleFilter: String?) async throws -> [CalendarEvent] {
        fetchCallCount += 1
        lastFetchArgs = (start, end, titleFilter)

        let result = seedEvents
            .filter { event in
                guard event.startDate >= start && event.startDate < end else { return false }
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
    let lastFetchResult: [CalendarEvent]
    let createCallCount: Int
    let updateCallCount: Int
    let lastCreatedEvent: CalendarEvent?
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
            let agentResponse: String
            do {
                let response = try await session.respond(to: turn.userMessage)
                agentResponse = response.content
            } catch {
                agentResponse = "[ERROR: \(error.localizedDescription)]"
            }

            let context = EvalContext(
                userMessage: turn.userMessage,
                agentResponse: agentResponse,
                fetchCallCount: mock.fetchCallCount,
                lastFetchResult: mock.lastFetchResult,
                createCallCount: mock.createCallCount,
                updateCallCount: mock.updateCallCount,
                lastCreatedEvent: mock.lastCreatedEvent
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
