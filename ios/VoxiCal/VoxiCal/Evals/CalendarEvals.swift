import Foundation
import FoundationModels
import SwiftUI

// MARK: - CalendarServiceProtocol

/// Abstraction over CalendarService enabling MockCalendarService injection in evals.
protocol CalendarServiceProtocol: AnyObject {
    func fetchEvents(daysAhead: Int, daysBack: Int, titleFilter: String?) async throws -> [CalendarEvent]
    func deleteEvent(id: String) async throws
}

// MARK: - MockCalendarService

/// Controllable test double. Tracks all tool calls so graders can inspect them.
@MainActor
final class MockCalendarService: CalendarServiceProtocol {
    var seedEvents: [CalendarEvent] = []
    private(set) var fetchCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var lastFetchArgs: (daysAhead: Int, daysBack: Int, titleFilter: String?)?

    func fetchEvents(daysAhead: Int, daysBack: Int, titleFilter: String?) async throws -> [CalendarEvent] {
        fetchCallCount += 1
        lastFetchArgs = (daysAhead, daysBack, titleFilter)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -max(daysBack, 0), to: today)!
        let end   = calendar.date(byAdding: .day, value:  max(daysAhead, 1), to: today)!

        return seedEvents
            .filter { event in
                guard event.startDate >= start && event.startDate < end else { return false }
                guard let filter = titleFilter, !filter.isEmpty else { return true }
                let inTitle = event.title.localizedCaseInsensitiveContains(filter)
                let inNotes = event.notes?.localizedCaseInsensitiveContains(filter) ?? false
                return inTitle || inNotes
            }
            .sorted { $0.startDate < $1.startDate }
    }

    func deleteEvent(id: String) async throws {
        deleteCallCount += 1
        seedEvents.removeAll { $0.id == id }
    }

    func reset() {
        fetchCallCount = 0
        deleteCallCount = 0
        lastFetchArgs = nil
    }
}

// MARK: - EvalTypes

struct EvalContext {
    let userMessage: String
    let agentResponse: String
    let fetchCallCount: Int
    let lastFetchArgs: (daysAhead: Int, daysBack: Int, titleFilter: String?)?
    let seedEvents: [CalendarEvent]
}

struct GradeResult: Identifiable {
    let id = UUID()
    let graderName: String
    let passed: Bool
    let message: String
}

typealias Grader = (EvalContext) async -> GradeResult

struct EvalScenario: Identifiable {
    let id: String
    let category: String
    let name: String
    let userMessage: String
    let seedEvents: [CalendarEvent]
    let graders: [Grader]
}

struct EvalResult: Identifiable {
    let id = UUID()
    let scenarioID: String
    let scenarioName: String
    let category: String
    let userMessage: String
    let agentResponse: String
    let fetchCallCount: Int
    let gradingResults: [GradeResult]
    var passed: Bool { gradingResults.allSatisfy(\.passed) }
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

// MARK: - Graders

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

func daysBackGrader(minimum: Int, maximum: Int? = nil) -> Grader {
    { ctx in
        guard let args = ctx.lastFetchArgs else {
            return GradeResult(graderName: "daysBack range", passed: false, message: "No tool call recorded")
        }
        let days = args.daysBack
        let inRange = days >= minimum && (maximum.map { days <= $0 } ?? true)
        let rangeDesc = maximum != nil ? "\(minimum)–\(maximum!)" : "≥\(minimum)"
        return GradeResult(
            graderName: "daysBack range",
            passed: inRange,
            message: inRange
                ? "daysBack=\(days) is within expected range \(rangeDesc)"
                : "daysBack=\(days) is outside expected range \(rangeDesc)"
        )
    }
}

func responseContainsGrader(_ keyword: String) -> Grader {
    { ctx in
        let found = ctx.agentResponse.localizedCaseInsensitiveContains(keyword)
        return GradeResult(
            graderName: "Response contains '\(keyword)'",
            passed: found,
            message: found
                ? "Response mentions '\(keyword)'"
                : "Response does not mention '\(keyword)'"
        )
    }
}

func responseDoesNotContainGrader(_ keyword: String) -> Grader {
    { ctx in
        let found = ctx.agentResponse.localizedCaseInsensitiveContains(keyword)
        return GradeResult(
            graderName: "Response omits '\(keyword)'",
            passed: !found,
            message: !found
                ? "Response correctly omits '\(keyword)'"
                : "Response unexpectedly mentions '\(keyword)'"
        )
    }
}

/// Passes when the agent's response signals that no matching events were found
/// rather than inventing a meeting. Catches hallucination on empty or mismatched results.
func noEventsFoundGrader() -> Grader {
    { ctx in
        let indicators = [
            "no meeting", "no event", "no appointment",
            "nothing scheduled", "nothing on your calendar",
            "don't see", "doesn't appear", "doesn't show",
            "couldn't find", "not scheduled", "not found",
            "not have", "don't have any"
        ]
        let passed = indicators.contains {
            ctx.agentResponse.localizedCaseInsensitiveContains($0)
        }
        return GradeResult(
            graderName: "No events found (hallucination check)",
            passed: passed,
            message: passed
                ? "Agent correctly reported no matching events"
                : "Agent may have hallucinated — response does not indicate 'no events found'. Got: \"\(ctx.agentResponse)\""
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

        let agentResponse: String
        do {
            let response = try await session.respond(to: scenario.userMessage)
            agentResponse = response.content
        } catch {
            agentResponse = "[ERROR: \(error.localizedDescription)]"
        }

        let context = EvalContext(
            userMessage: scenario.userMessage,
            agentResponse: agentResponse,
            fetchCallCount: mock.fetchCallCount,
            lastFetchArgs: mock.lastFetchArgs,
            seedEvents: scenario.seedEvents
        )

        var gradingResults: [GradeResult] = []
        for grader in scenario.graders {
            gradingResults.append(await grader(context))
        }

        return EvalResult(
            scenarioID: scenario.id,
            scenarioName: scenario.name,
            category: scenario.category,
            userMessage: scenario.userMessage,
            agentResponse: agentResponse,
            fetchCallCount: mock.fetchCallCount,
            gradingResults: gradingResults
        )
    }
}

// MARK: - Scenarios: Category A — Greetings

// Scenario 1 (four variants): greeting with no calendar intent.
// Success criteria: agent responds conversationally, fetchCallCount == 0.

private let categoryAScenarios: [EvalScenario] = [
    EvalScenario(id: "A1a", category: "Category A — Greetings", name: "Greeting: \"Hi\"",
                 userMessage: "Hi", seedEvents: [], graders: [noToolCallGrader()]),
    EvalScenario(id: "A1b", category: "Category A — Greetings", name: "Greeting: \"Hello\"",
                 userMessage: "Hello", seedEvents: [], graders: [noToolCallGrader()]),
    EvalScenario(id: "A1c", category: "Category A — Greetings", name: "Greeting: \"Good morning\"",
                 userMessage: "Good morning", seedEvents: [], graders: [noToolCallGrader()]),
    EvalScenario(id: "A1d", category: "Category A — Greetings", name: "Greeting: \"Hey\"",
                 userMessage: "Hey", seedEvents: [], graders: [noToolCallGrader()])
]

// MARK: - Scenarios: Category B — Meeting Lookup

// Scenarios 2–5: lookup by person name, company, email address, and org.
// All expect fetchCalendarEvents to be called with an appropriate daysAhead value.
//
// B4 note: MockCalendarService searches title AND notes, so an event whose notes
// contain "john.doe@gmail.com" is returned when the agent fetches all events for
// the week without a titleFilter.
//
// B5 note: seed event is 35 days out; agent should use daysAhead ≥ 35 (ideally 60).

private let categoryBScenarios: [EvalScenario] = [
    EvalScenario(
        id: "B2",
        category: "Category B — Meeting Lookup",
        name: "Meeting with Sarah today",
        userMessage: "Do I have a meeting with Sarah today?",
        seedEvents: [
            makeTestEvent(title: "1:1 with Sarah", daysFromNow: 0, hour: 10),
            makeTestEvent(title: "Team standup",   daysFromNow: 0, hour: 9)
        ],
        graders: [toolCalledGrader(), daysAheadGrader(minimum: 1, maximum: 2), responseContainsGrader("Sarah")]
    ),
    EvalScenario(
        id: "B3",
        category: "Category B — Meeting Lookup",
        name: "Meeting with Google today",
        userMessage: "Do I have any meetings with Google today?",
        seedEvents: [
            makeTestEvent(title: "Google Partnership Sync", daysFromNow: 0, hour: 14),
            makeTestEvent(title: "Lunch with team",         daysFromNow: 0, hour: 12)
        ],
        graders: [toolCalledGrader(), daysAheadGrader(minimum: 1, maximum: 2), responseContainsGrader("Google")]
    ),
    EvalScenario(
        id: "B4",
        category: "Category B — Meeting Lookup",
        name: "Meeting with email address this week",
        userMessage: "Do I have a meeting with john.doe@gmail.com this week?",
        seedEvents: [
            makeTestEvent(title: "Project Sync", daysFromNow: 3, hour: 11,
                          notes: "Attendees: john.doe@gmail.com, jane.smith@company.com")
        ],
        graders: [toolCalledGrader(), daysAheadGrader(minimum: 7), responseContainsGrader("john.doe")]
    ),
    EvalScenario(
        id: "B5",
        category: "Category B — Meeting Lookup",
        name: "Meeting with OpenAI next month",
        userMessage: "Do I have any meetings scheduled with OpenAI next month?",
        seedEvents: [
            makeTestEvent(title: "OpenAI Strategy Call", daysFromNow: 35, hour: 15)
        ],
        graders: [toolCalledGrader(), daysAheadGrader(minimum: 35), responseContainsGrader("OpenAI")]
    )
]

// MARK: - Scenarios: Category B (Negative) — Hallucination Guard

// These scenarios seed events that do NOT match the user's query.
// The agent must call the tool, read the real results, and report "no match" —
// not invent a meeting. A passing eval here means hallucination is suppressed.

private let categoryBNegativeScenarios: [EvalScenario] = [

    // B2N: Calendar has events today, but NONE with Sarah.
    // Agent must not fabricate a Sarah meeting.
    EvalScenario(
        id: "B2N",
        category: "Category B (Negative) — Hallucination Guard",
        name: "No Sarah meeting — other events exist today",
        userMessage: "Do I have a meeting with Sarah today?",
        seedEvents: [
            makeTestEvent(title: "Team standup",     daysFromNow: 0, hour: 9),
            makeTestEvent(title: "Lunch with John",  daysFromNow: 0, hour: 12),
            makeTestEvent(title: "Product review",   daysFromNow: 0, hour: 15)
        ],
        graders: [
            toolCalledGrader(),
            noEventsFoundGrader()
        ]
    ),

    // B3N: Calendar has events today, but NONE with Google.
    // Agent must not fabricate a Google meeting.
    EvalScenario(
        id: "B3N",
        category: "Category B (Negative) — Hallucination Guard",
        name: "No Google meeting — other events exist today",
        userMessage: "Do I have any meetings with Google today?",
        seedEvents: [
            makeTestEvent(title: "Internal roadmap review", daysFromNow: 0, hour: 10),
            makeTestEvent(title: "1:1 with manager",        daysFromNow: 0, hour: 14)
        ],
        graders: [
            toolCalledGrader(),
            noEventsFoundGrader()
        ]
    )
]

// MARK: - EvalView

struct EvalView: View {
    @State private var runner = EvalRunner()

    private let allScenarios = categoryAScenarios + categoryBScenarios + categoryBNegativeScenarios

    var body: some View {
        Group {
            if runner.results.isEmpty && !runner.isRunning {
                emptyState
            } else {
                resultsList
            }
        }
        .navigationTitle("Eval Runner")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Run All") {
                    Task { await runner.run(scenarios: allScenarios) }
                }
                .disabled(runner.isRunning)
            }
        }
        .overlay {
            if runner.isRunning {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView(value: runner.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                        Text("Running \(Int(runner.progress * Double(allScenarios.count)))/\(allScenarios.count)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "testtube.2")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("\(allScenarios.count) scenarios ready")
                .font(.headline)
            Text("Tap \"Run All\" to execute the eval suite against the on-device model.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var resultsList: some View {
        List {
            summarySection
            ForEach(runner.results) { result in
                EvalResultRow(result: result)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var summarySection: some View {
        let passed  = runner.results.filter(\.passed).count
        let total   = runner.results.count
        let allPass = passed == total
        return Section {
            HStack(spacing: 10) {
                Image(systemName: allPass ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(allPass ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(passed) / \(total) passed").font(.headline)
                    Text(allPass ? "All scenarios passed" : "\(total - passed) scenario(s) failed")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - EvalResultRow

private struct EvalResultRow: View {
    let result: EvalResult
    @State private var expanded = false

    var body: some View {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.passed ? .green : .red)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.scenarioName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Text(result.category)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.tertiary).font(.caption).padding(.top, 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded { expandedDetail }
        }
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            detailRow(label: "User",  value: result.userMessage)
            detailRow(label: "Agent", value: result.agentResponse)
            HStack {
                Text("Tool calls").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(result.fetchCallCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(result.fetchCallCount > 0 ? .primary : .secondary)
            }
            Divider()
            Text("Graders").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(result.gradingResults) { grade in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: grade.passed ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(grade.passed ? .green : .red).font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(grade.graderName).font(.caption.weight(.medium))
                        Text(grade.message).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption).foregroundStyle(.primary)
        }
    }
}
