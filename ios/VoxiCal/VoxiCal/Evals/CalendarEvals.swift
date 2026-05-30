import Foundation
import FoundationModels
import SwiftUI
import os.log

// MARK: - CalendarServiceProtocol

protocol CalendarServiceProtocol: AnyObject {
    func fetchEvents(daysAhead: Int, daysBack: Int, titleFilter: String?) async throws -> [CalendarEvent]
    func deleteEvent(id: String) async throws
}

// MARK: - MockCalendarService

@MainActor
final class MockCalendarService: CalendarServiceProtocol {
    var seedEvents: [CalendarEvent] = []
    private(set) var fetchCallCount = 0
    private(set) var lastFetchArgs: (daysAhead: Int, daysBack: Int, titleFilter: String?)?
    private(set) var lastFetchResult: [CalendarEvent] = []

    func fetchEvents(daysAhead: Int, daysBack: Int, titleFilter: String?) async throws -> [CalendarEvent] {
        fetchCallCount += 1
        lastFetchArgs = (daysAhead, daysBack, titleFilter)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -max(daysBack, 0), to: today)!
        let end   = calendar.date(byAdding: .day, value:  max(daysAhead, 1), to: today)!

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

    // Test 3: Hallucination guard (tool call, no events, must report accurately)
    GoldenTestCase(
        id: "test-no-hallucination",
        userQuery: "Do I have a meeting with Sarah today?",
        category: "Hallucination Guard",
        expectedBehavior: "Agent calls tool, finds NO Sarah meeting, explicitly reports no events (does not hallucinate)",
        shouldCallTool: true,
        seedEvents: [
            makeTestEvent(title: "Team standup", daysFromNow: 0, hour: 9),
            makeTestEvent(title: "Lunch with John", daysFromNow: 0, hour: 12)
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

        let eventTitles = ctx.lastFetchResult.map { $0.title.lowercased() }
        let response = ctx.agentResponse.lowercased()

        let anyMentioned = eventTitles.contains { title in
            response.contains(title) || response.contains(title.split(separator: " ").first.map(String.init) ?? "")
        }

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
        let toolFoundEvents = !ctx.lastFetchResult.isEmpty
        guard !toolFoundEvents else {
            return GradeResult(
                graderName: "No events hallucination check",
                passed: false,
                message: "✗ Tool found \(ctx.lastFetchResult.count) event(s) but agent said no events"
            )
        }

        let indicators = [
            "no meeting", "no event", "no appointment",
            "nothing scheduled", "don't have", "not have",
            "not scheduled", "couldn't find"
        ]
        let found = indicators.contains { ctx.agentResponse.localizedCaseInsensitiveContains($0) }

        return GradeResult(
            graderName: "No events hallucination check",
            passed: found,
            message: found
                ? "✓ Agent correctly reported no events (no hallucination)"
                : "✗ Agent may have hallucinated — did not report 'no events'"
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
            DeleteCalendarEventTool(calendarService: mock)
        ]

        let session = LanguageModelSession(
            tools: tools,
            instructions: CalendarViewModel.agentInstructions
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
                lastFetchResult: mock.lastFetchResult
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

        if testCase.shouldCallTool {
            graders.append(toolCalledGrader())
            // If events are in seed, expect them to be mentioned
            if !testCase.seedEvents.isEmpty {
                graders.append(eventFoundAndMentionedGrader())
            } else {
                // Empty seed = expect "no events" response
                graders.append(noEventsFoundGrader())
            }
        } else {
            graders.append(noToolCallGrader())
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
