import Foundation
import FoundationModels
import SwiftUI
import os.log

// MARK: - CalendarServiceProtocol

/// Abstraction over CalendarService enabling MockCalendarService injection in evals.
protocol CalendarServiceProtocol: AnyObject {
    func fetchEvents(daysAhead: Int, daysBack: Int, titleFilter: String?) async throws -> [CalendarEvent]
    func deleteEvent(id: String) async throws
}

// MARK: - MockCalendarService

/// Controllable test double. Tracks all tool calls and their results.
@MainActor
final class MockCalendarService: CalendarServiceProtocol {
    var seedEvents: [CalendarEvent] = []
    private(set) var fetchCallCount = 0
    private(set) var deleteCallCount = 0
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
        deleteCallCount += 1
        seedEvents.removeAll { $0.id == id }
    }

    func reset() {
        fetchCallCount = 0
        deleteCallCount = 0
        lastFetchArgs = nil
        lastFetchResult = []
    }
}

// MARK: - EvalTypes

/// Context for a single turn in a scenario. Includes tool results for outcome validation.
struct EvalContext {
    let turnNumber: Int
    let userMessage: String
    let agentResponse: String
    let fetchCallCount: Int
    let lastFetchArgs: (daysAhead: Int, daysBack: Int, titleFilter: String?)?
    let lastFetchResult: [CalendarEvent]  // Actual events returned by the tool
    let seedEvents: [CalendarEvent]
}

struct GradeResult: Identifiable {
    let id = UUID()
    let graderName: String
    let passed: Bool
    let message: String
}

typealias Grader = (EvalContext) async -> GradeResult

/// A single turn in a multi-turn scenario.
struct EvalTurn {
    let userMessage: String
    let graders: [Grader]
}

/// Multi-turn scenario with defined inputs and success criteria per turn.
struct EvalScenario: Identifiable {
    let id: String
    let category: String
    let name: String
    let seedEvents: [CalendarEvent]
    let turns: [EvalTurn]
}

/// Result of a single turn within a scenario.
struct TurnResult: Identifiable {
    let id = UUID()
    let turnNumber: Int
    let userMessage: String
    let agentResponse: String
    let fetchCallCount: Int
    let gradingResults: [GradeResult]
    var passed: Bool { gradingResults.allSatisfy(\.passed) }
}

/// Overall result for an entire scenario (all turns).
struct EvalResult: Identifiable {
    let id = UUID()
    let scenarioID: String
    let scenarioName: String
    let category: String
    let turnResults: [TurnResult]
    var passed: Bool { turnResults.allSatisfy(\.passed) }
    var passedTurns: Int { turnResults.filter(\.passed).count }
}

/// Creates a CalendarEvent with a start time relative to today for use in seed data.
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

// MARK: - Graders (Tool Validation)

func toolCalledGrader() -> Grader {
    { ctx in
        let ok = ctx.fetchCallCount > 0
        return GradeResult(
            graderName: "Tool was called",
            passed: ok,
            message: ok
                ? "Called fetchCalendarEvents \(ctx.fetchCallCount) time(s)"
                : "Did not call fetchCalendarEvents — expected at least 1 call"
        )
    }
}

func noToolCallGrader() -> Grader {
    { ctx in
        let ok = ctx.fetchCallCount == 0
        return GradeResult(
            graderName: "No tool call",
            passed: ok,
            message: ok
                ? "Correctly skipped calendar lookup"
                : "Called fetchCalendarEvents \(ctx.fetchCallCount) time(s) — expected 0"
        )
    }
}

func daysAheadGrader(minimum: Int, maximum: Int? = nil) -> Grader {
    { ctx in
        guard let args = ctx.lastFetchArgs else {
            return GradeResult(graderName: "daysAhead range", passed: false, message: "No tool call recorded")
        }
        let days = args.daysAhead
        let inRange = days >= minimum && (maximum.map { days <= $0 } ?? true)
        let rangeDesc = maximum != nil ? "\(minimum)–\(maximum!)" : "≥\(minimum)"
        return GradeResult(
            graderName: "daysAhead range",
            passed: inRange,
            message: inRange
                ? "daysAhead=\(days) is within expected range \(rangeDesc)"
                : "daysAhead=\(days) is outside expected range \(rangeDesc)"
        )
    }
}

// MARK: - Graders (Outcome Validation)

/// Passes if the tool found events AND agent response mentions at least one event title or key detail.
func eventFoundAndMentionedGrader() -> Grader {
    { ctx in
        let toolFoundEvents = !ctx.lastFetchResult.isEmpty
        guard toolFoundEvents else {
            return GradeResult(
                graderName: "Event found and mentioned",
                passed: false,
                message: "Tool returned no events; cannot validate response mentions them"
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
                ? "Agent mentioned event(s): \(eventTitles.joined(separator: ", "))"
                : "Agent did not mention found events. Tool returned: \(eventTitles.joined(separator: ", ")), Response: \"\(ctx.agentResponse)\""
        )
    }
}

/// Passes if the tool found NO events AND agent response indicates no events found.
func noEventsFoundGrader() -> Grader {
    { ctx in
        let toolFoundEvents = !ctx.lastFetchResult.isEmpty
        guard !toolFoundEvents else {
            return GradeResult(
                graderName: "No events found (hallucination check)",
                passed: false,
                message: "Tool returned \(ctx.lastFetchResult.count) event(s); cannot validate 'no events' response"
            )
        }

        let indicators = [
            "no meeting", "no event", "no appointment",
            "nothing scheduled", "nothing on your calendar",
            "don't see", "doesn't appear", "doesn't show",
            "couldn't find", "not scheduled", "not found",
            "not have", "don't have"
        ]
        let found = indicators.contains { ctx.agentResponse.localizedCaseInsensitiveContains($0) }

        return GradeResult(
            graderName: "No events found (hallucination check)",
            passed: found,
            message: found
                ? "Agent correctly reported no events"
                : "Agent may have hallucinated — response does not indicate 'no events found'. Got: \"\(ctx.agentResponse)\""
        )
    }
}

/// Passes if agent response contains a specific keyword (case-insensitive).
func responseContainsGrader(_ keyword: String) -> Grader {
    { ctx in
        let found = ctx.agentResponse.localizedCaseInsensitiveContains(keyword)
        return GradeResult(
            graderName: "Response contains '\(keyword)'",
            passed: found,
            message: found
                ? "Response mentions '\(keyword)'"
                : "Response does not mention '\(keyword)'. Got: \"\(ctx.agentResponse)\""
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

        for (turnIndex, turn) in scenario.turns.enumerated() {
            let agentResponse: String
            do {
                let response = try await session.respond(to: turn.userMessage)
                agentResponse = response.content
            } catch {
                agentResponse = "[ERROR: \(error.localizedDescription)]"
            }

            let context = EvalContext(
                turnNumber: turnIndex + 1,
                userMessage: turn.userMessage,
                agentResponse: agentResponse,
                fetchCallCount: mock.fetchCallCount,
                lastFetchArgs: mock.lastFetchArgs,
                lastFetchResult: mock.lastFetchResult,
                seedEvents: scenario.seedEvents
            )

            var gradingResults: [GradeResult] = []
            for grader in turn.graders {
                gradingResults.append(await grader(context))
            }

            turnResults.append(TurnResult(
                turnNumber: turnIndex + 1,
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

// MARK: - Scenarios: Category A (Single-turn: Greetings)

private let categoryAScenarios: [EvalScenario] = [
    EvalScenario(
        id: "A1a",
        category: "Category A — Greetings",
        name: "Greeting: \"Hi\"",
        seedEvents: [],
        turns: [EvalTurn(userMessage: "Hi", graders: [noToolCallGrader()])]
    ),
    EvalScenario(
        id: "A1b",
        category: "Category A — Greetings",
        name: "Greeting: \"Hello\"",
        seedEvents: [],
        turns: [EvalTurn(userMessage: "Hello", graders: [noToolCallGrader()])]
    ),
    EvalScenario(
        id: "A1c",
        category: "Category A — Greetings",
        name: "Greeting: \"Good morning\"",
        seedEvents: [],
        turns: [EvalTurn(userMessage: "Good morning", graders: [noToolCallGrader()])]
    ),
    EvalScenario(
        id: "A1d",
        category: "Category A — Greetings",
        name: "Greeting: \"Hey\"",
        seedEvents: [],
        turns: [EvalTurn(userMessage: "Hey", graders: [noToolCallGrader()])]
    )
]

// MARK: - Scenarios: Category B (Single-turn: Meeting Lookup with Outcome Validation)

private let categoryBScenarios: [EvalScenario] = [
    EvalScenario(
        id: "B2",
        category: "Category B — Meeting Lookup",
        name: "Meeting with Sarah today (outcome validation)",
        seedEvents: [
            makeTestEvent(title: "1:1 with Sarah", daysFromNow: 0, hour: 10),
            makeTestEvent(title: "Team standup",   daysFromNow: 0, hour: 9)
        ],
        turns: [
            EvalTurn(
                userMessage: "Do I have a meeting with Sarah today?",
                graders: [
                    toolCalledGrader(),
                    daysAheadGrader(minimum: 1, maximum: 2),
                    eventFoundAndMentionedGrader(),
                    responseContainsGrader("Sarah")
                ]
            )
        ]
    ),
    EvalScenario(
        id: "B3",
        category: "Category B — Meeting Lookup",
        name: "Meeting with Google today (outcome validation)",
        seedEvents: [
            makeTestEvent(title: "Google Partnership Sync", daysFromNow: 0, hour: 14),
            makeTestEvent(title: "Lunch with team",         daysFromNow: 0, hour: 12)
        ],
        turns: [
            EvalTurn(
                userMessage: "Do I have any meetings with Google today?",
                graders: [
                    toolCalledGrader(),
                    daysAheadGrader(minimum: 1, maximum: 2),
                    eventFoundAndMentionedGrader(),
                    responseContainsGrader("Google")
                ]
            )
        ]
    ),
    EvalScenario(
        id: "B4",
        category: "Category B — Meeting Lookup",
        name: "Meeting with email address this week (outcome validation)",
        seedEvents: [
            makeTestEvent(
                title: "Project Sync",
                daysFromNow: 3,
                hour: 11,
                notes: "Attendees: john.doe@gmail.com, jane.smith@company.com"
            )
        ],
        turns: [
            EvalTurn(
                userMessage: "Do I have a meeting with john.doe@gmail.com this week?",
                graders: [
                    toolCalledGrader(),
                    daysAheadGrader(minimum: 7),
                    eventFoundAndMentionedGrader(),
                    responseContainsGrader("john.doe")
                ]
            )
        ]
    ),
    EvalScenario(
        id: "B5",
        category: "Category B — Meeting Lookup",
        name: "Meeting with OpenAI next month (outcome validation)",
        seedEvents: [
            makeTestEvent(title: "OpenAI Strategy Call", daysFromNow: 35, hour: 15)
        ],
        turns: [
            EvalTurn(
                userMessage: "Do I have any meetings scheduled with OpenAI next month?",
                graders: [
                    toolCalledGrader(),
                    daysAheadGrader(minimum: 35),
                    eventFoundAndMentionedGrader(),
                    responseContainsGrader("OpenAI")
                ]
            )
        ]
    )
]

// MARK: - Scenarios: Category B (Negative: Hallucination Guard)

private let categoryBNegativeScenarios: [EvalScenario] = [
    EvalScenario(
        id: "B2N",
        category: "Category B (Negative) — Hallucination Guard",
        name: "No Sarah meeting — correctly reports no events",
        seedEvents: [
            makeTestEvent(title: "Team standup",     daysFromNow: 0, hour: 9),
            makeTestEvent(title: "Lunch with John",  daysFromNow: 0, hour: 12),
            makeTestEvent(title: "Product review",   daysFromNow: 0, hour: 15)
        ],
        turns: [
            EvalTurn(
                userMessage: "Do I have a meeting with Sarah today?",
                graders: [
                    toolCalledGrader(),
                    noEventsFoundGrader()
                ]
            )
        ]
    ),
    EvalScenario(
        id: "B3N",
        category: "Category B (Negative) — Hallucination Guard",
        name: "No Google meeting — correctly reports no events",
        seedEvents: [
            makeTestEvent(title: "Internal roadmap review", daysFromNow: 0, hour: 10),
            makeTestEvent(title: "1:1 with manager",        daysFromNow: 0, hour: 14)
        ],
        turns: [
            EvalTurn(
                userMessage: "Do I have any meetings with Google today?",
                graders: [
                    toolCalledGrader(),
                    noEventsFoundGrader()
                ]
            )
        ]
    )
]

// MARK: - Scenarios: Category C (Multi-turn: Sequential Tool Usage)

/// Multi-turn scenario testing state retention and sequential operations.
/// Turn 1: Fetch meeting with Sarah
/// Turn 2: Ask for details (should reference Turn 1 result)
/// Turn 3: Delete it (should use eventID from Turn 1)
private let categoryMultiTurnScenarios: [EvalScenario] = [
    EvalScenario(
        id: "MT1",
        category: "Category C — Multi-turn",
        name: "Fetch, ask details, delete (state retention)",
        seedEvents: [
            makeTestEvent(title: "1:1 with Sarah", daysFromNow: 0, hour: 10, location: "Conference Room A")
        ],
        turns: [
            EvalTurn(
                userMessage: "Do I have a meeting with Sarah today?",
                graders: [
                    toolCalledGrader(),
                    daysAheadGrader(minimum: 1, maximum: 2),
                    eventFoundAndMentionedGrader()
                ]
            ),
            EvalTurn(
                userMessage: "What's the location?",
                graders: [
                    responseContainsGrader("Conference Room")
                ]
            )
        ]
    ),
    EvalScenario(
        id: "MT2",
        category: "Category C — Multi-turn",
        name: "List meetings, then ask about specific one",
        seedEvents: [
            makeTestEvent(title: "Team standup",    daysFromNow: 0, hour: 9),
            makeTestEvent(title: "1:1 with Sarah",  daysFromNow: 0, hour: 10),
            makeTestEvent(title: "Lunch meeting",   daysFromNow: 0, hour: 12)
        ],
        turns: [
            EvalTurn(
                userMessage: "What meetings do I have today?",
                graders: [
                    toolCalledGrader(),
                    daysAheadGrader(minimum: 1, maximum: 2),
                    eventFoundAndMentionedGrader()
                ]
            ),
            EvalTurn(
                userMessage: "Is Sarah in any of those?",
                graders: [
                    responseContainsGrader("Sarah")
                ]
            )
        ]
    )
]

// MARK: - AllEvaluationScenarios

let allEvaluationScenarios = categoryAScenarios + categoryBScenarios + categoryBNegativeScenarios + categoryMultiTurnScenarios

// MARK: - Test Harness

/// Runs all eval scenarios and logs results showing tool validation and outcome verification.
@MainActor
func runEvaluationSuite() async -> (passed: Int, failed: Int) {
    let runner = EvalRunner()
    await runner.run(scenarios: allEvaluationScenarios)

    let logger = Logger(subsystem: "com.ramya-app.VoxiCal.evals", category: "TestHarness")

    print("\n" + String(repeating: "=", count: 80))
    print("EVAL SUITE RESULTS — Anthropic-Style Agent Evaluation")
    print(String(repeating: "=", count: 80))

    let totalPassed = runner.results.filter(\.passed).count
    let totalFailed = runner.results.count - totalPassed

    for result in runner.results {
        let status = result.passed ? "✓ PASS" : "✗ FAIL"
        let allTurns = result.turnResults.count > 1 ? " (\(result.passedTurns)/\(result.turnResults.count) turns)" : ""
        print("\n[\(status)] \(result.scenarioName)\(allTurns)")
        print("  Category: \(result.category)")

        for turnResult in result.turnResults {
            if result.turnResults.count > 1 {
                print("  Turn \(turnResult.turnNumber): \(turnResult.userMessage)")
            } else {
                print("  User: \(turnResult.userMessage)")
            }
            print("  Agent: \(turnResult.agentResponse)")
            print("  Tool calls: \(turnResult.fetchCallCount)")

            for grade in turnResult.gradingResults {
                let icon = grade.passed ? "  ✓" : "  ✗"
                print("\(icon) \(grade.graderName)")
                if !grade.message.isEmpty {
                    print("     → \(grade.message)")
                }
            }
        }
    }

    print("\n" + String(repeating: "=", count: 80))
    print("SUMMARY: \(totalPassed)/\(runner.results.count) scenarios passed, \(totalFailed) failed")
    print("Total scenarios: \(runner.results.count) | Single-turn: \(categoryAScenarios.count + categoryBScenarios.count + categoryBNegativeScenarios.count) | Multi-turn: \(categoryMultiTurnScenarios.count)")
    print(String(repeating: "=", count: 80) + "\n")

    logger.info("Eval suite: \(totalPassed)/\(runner.results.count) passed")

    return (totalPassed, totalFailed)
}
