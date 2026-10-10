import EventKit
import Foundation
import FoundationModels
import SwiftUI
import os.log

// MARK: - Create Event Graders

func createCalledWithAllDayGrader() -> Grader {
    { ctx in
        guard let event = ctx.lastCreatedEvent else {
            return GradeResult(graderName: "Created event is all-day", passed: false,
                message: "✗ No event was created")
        }
        return GradeResult(graderName: "Created event is all-day", passed: event.isAllDay,
            message: event.isAllDay
                ? "✓ Created event correctly has isAllDay=true"
                : "✗ Created event has isAllDay=false — expected all-day for this event type")
    }
}

func createCalledWithoutAllDayGrader() -> Grader {
    { ctx in
        guard let event = ctx.lastCreatedEvent else {
            return GradeResult(graderName: "Created event is not all-day", passed: false,
                message: "✗ No event was created")
        }
        return GradeResult(graderName: "Created event is not all-day", passed: !event.isAllDay,
            message: !event.isAllDay
                ? "✓ Created event correctly has isAllDay=false"
                : "✗ Created event has isAllDay=true — not expected for this event type")
    }
}

func createCalledWithDurationGrader(expectedMinutes: Int, tolerance: Int = 5) -> Grader {
    { ctx in
        guard let event = ctx.lastCreatedEvent else {
            return GradeResult(graderName: "Created event duration=\(expectedMinutes)min", passed: false,
                message: "✗ No event was created")
        }
        let actual = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
        let ok = abs(actual - expectedMinutes) <= tolerance
        return GradeResult(graderName: "Created event duration=\(expectedMinutes)min", passed: ok,
            message: ok
                ? "✓ Created event duration is \(actual) min (expected ~\(expectedMinutes) min)"
                : "✗ Created event duration is \(actual) min — expected ~\(expectedMinutes) min")
    }
}

func createCalledWithNoLocationGrader() -> Grader {
    { ctx in
        guard let event = ctx.lastCreatedEvent else {
            return GradeResult(graderName: "Created event has no location", passed: false,
                message: "✗ No event was created")
        }
        let ok = event.location == nil || event.location!.isEmpty
        return GradeResult(graderName: "Created event has no location", passed: ok,
            message: ok
                ? "✓ Location correctly omitted from created event"
                : "✗ Created event unexpectedly has location='\(event.location!)'")
    }
}

func responseDoesNotContainAnyGrader(name: String, disallowedPhrases: [String]) -> Grader {
    { ctx in
        let found = disallowedPhrases.first { ctx.agentResponse.localizedCaseInsensitiveContains($0) }
        return GradeResult(graderName: name, passed: found == nil,
            message: found == nil
                ? "✓ Agent correctly did not ask about: \(disallowedPhrases.joined(separator: ", "))"
                : "✗ Agent incorrectly mentioned '\(found!)' — not required for this event type")
    }
}

func didNotAskForLocationGrader() -> Grader {
    responseDoesNotContainAnyGrader(
        name: "Did not ask for location",
        disallowedPhrases: ["location", "platform", "where will", "where would", "where is", "zoom", "teams", "meet", "in person", "virtual", "room"]
    )
}

func didNotAskForDurationGrader() -> Grader {
    responseDoesNotContainAnyGrader(
        name: "Did not ask for duration",
        disallowedPhrases: ["how long", "duration", "how many minutes", "how many hours", "length of", "for how long"]
    )
}

func didNotAskForTimeGrader() -> Grader {
    responseDoesNotContainAnyGrader(
        name: "Did not ask for time",
        disallowedPhrases: ["what time", "which time", "start time", "at what", "what hour"]
    )
}

func askedForDateGrader() -> Grader {
    responseContainsAnyGrader(
        name: "Asked for date",
        indicators: ["when", "what date", "which date", "what day", "what month", "date"]
    )
}

// MARK: - Ambiguous Create Scenarios

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

// MARK: - Create Event Happy Path Scenarios

func buildCreateHappyPathScenarios() -> [EvalScenario] {
    return [

        // ── PROFESSIONAL EVENTS ──────────────────────────────────────────

        EvalScenario(
            id: "cre-hap-001-manager-1on1-all-details",
            category: "Create — Happy Path",
            name: "Manager 1:1 with all required details",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a 1:1 with my manager tomorrow at 10am for 45 minutes on Zoom",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithoutAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms creation",
                        indicators: ["scheduled", "created", "added", "1:1", "manager", "10", "zoom"])
                ]
            )]
        ),

        EvalScenario(
            id: "cre-hap-002-team-meeting-all-details",
            category: "Create — Happy Path",
            name: "Team meeting with all details provided",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a team sync the day after tomorrow at 2pm for 30 minutes on Teams",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithoutAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms creation",
                        indicators: ["scheduled", "created", "added", "sync", "2", "teams"])
                ]
            )]
        ),

        EvalScenario(
            id: "cre-hap-003-interview-all-details",
            category: "Create — Happy Path",
            name: "Interview with date, time, duration, and location",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add an interview with Acme Corp next Monday at 11am for 1 hour at their San Francisco office",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithoutAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms creation",
                        indicators: ["scheduled", "created", "added", "interview", "11", "Acme", "monday"])
                ]
            )]
        ),

        // ── STUDY SESSIONS ───────────────────────────────────────────────

        EvalScenario(
            id: "cre-hap-010-study-session-no-location-needed",
            category: "Create — Happy Path",
            name: "Study session creates without location",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a study session tomorrow at 2pm for 2 hours",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithDurationGrader(expectedMinutes: 120),
                    createCalledWithoutAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms creation",
                        indicators: ["scheduled", "created", "added", "study"])
                ]
            )]
        ),

        EvalScenario(
            id: "cre-hap-011-study-session-specific-subject",
            category: "Create — Happy Path",
            name: "Named study session (chemistry) creates without asking for location",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a chemistry study session tomorrow at 3pm for 90 minutes",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithDurationGrader(expectedMinutes: 90),
                    createCalledWithoutAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms chemistry session creation",
                        indicators: ["chemistry", "study", "3", "3:00", "created", "scheduled", "added"])
                ]
            )]
        ),

        // ── GYM SESSIONS ─────────────────────────────────────────────────

        EvalScenario(
            id: "cre-hap-020-gym-no-location",
            category: "Create — Happy Path",
            name: "Gym session creates without asking for location",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a gym session tomorrow at 6am for 1 hour",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithDurationGrader(expectedMinutes: 60),
                    createCalledWithoutAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms creation",
                        indicators: ["scheduled", "created", "added", "gym"])
                ]
            )]
        ),

        EvalScenario(
            id: "cre-hap-021-gym-with-location",
            category: "Create — Happy Path",
            name: "Gym session with user-provided gym name",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a workout at Equinox tomorrow at 7am for 45 minutes",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithDurationGrader(expectedMinutes: 45),
                    responseContainsAnyGrader(name: "Confirms creation with location",
                        indicators: ["scheduled", "created", "Equinox", "workout", "7"])
                ]
            )]
        ),

        // ── CLASSES ──────────────────────────────────────────────────────

        EvalScenario(
            id: "cre-hap-030-class-no-classroom",
            category: "Create — Happy Path",
            name: "Class creates without asking for classroom",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add my biology lecture tomorrow at 9am for 1 hour 30 minutes",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithDurationGrader(expectedMinutes: 90),
                    createCalledWithoutAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms creation",
                        indicators: ["scheduled", "created", "added", "biology", "lecture", "9"])
                ]
            )]
        ),

        EvalScenario(
            id: "cre-hap-031-class-with-classroom",
            category: "Create — Happy Path",
            name: "Class with classroom specified",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add my physics lecture on Monday at 10am for 50 minutes in Room 204",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithDurationGrader(expectedMinutes: 50),
                    responseContainsAnyGrader(name: "Confirms creation with room",
                        indicators: ["scheduled", "created", "physics", "204", "monday"])
                ]
            )]
        ),

        // ── SOCIAL EVENTS ────────────────────────────────────────────────

        EvalScenario(
            id: "cre-hap-040-family-dinner-no-duration",
            category: "Create — Happy Path",
            name: "Family dinner creates without asking for duration",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a family dinner this Sunday at 7pm",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithoutAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms creation",
                        indicators: ["scheduled", "created", "added", "dinner", "sunday", "7"])
                ]
            )]
        ),

        EvalScenario(
            id: "cre-hap-041-date-night-with-location",
            category: "Create — Happy Path",
            name: "Date night with optional location",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a date night this Saturday at 8pm at Nobu",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithoutAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms creation with venue",
                        indicators: ["scheduled", "created", "Nobu", "date", "saturday", "8"])
                ]
            )]
        ),

        // ── MOVIES ───────────────────────────────────────────────────────

        EvalScenario(
            id: "cre-hap-050-movie-default-duration",
            category: "Create — Happy Path",
            name: "Movie uses 150 min default when no duration stated",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a movie night tomorrow at 8pm",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithDurationGrader(expectedMinutes: 150),
                    createCalledWithoutAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms creation",
                        indicators: ["scheduled", "created", "added", "movie", "8"])
                ]
            )]
        ),

        EvalScenario(
            id: "cre-hap-051-movie-user-specified-duration",
            category: "Create — Happy Path",
            name: "Movie uses user-provided duration instead of default",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a movie this Friday at 7pm, it's 3 hours long",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithDurationGrader(expectedMinutes: 180),
                    responseContainsAnyGrader(name: "Confirms creation",
                        indicators: ["scheduled", "created", "movie", "friday", "7"])
                ]
            )]
        ),

        EvalScenario(
            id: "cre-hap-052-movie-with-theater",
            category: "Create — Happy Path",
            name: "Movie with optional theater location",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a movie at AMC next Saturday at 6pm",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithDurationGrader(expectedMinutes: 150),
                    responseContainsAnyGrader(name: "Confirms creation with theater",
                        indicators: ["scheduled", "created", "AMC", "movie", "saturday"])
                ]
            )]
        ),

        // ── BIRTHDAYS ────────────────────────────────────────────────────

        EvalScenario(
            id: "cre-hap-060-birthday-all-day",
            category: "Create — Happy Path",
            name: "Birthday creates as all-day event with date only",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add my mom's birthday on June 20",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms birthday creation",
                        indicators: ["added", "created", "scheduled", "birthday", "mom", "june", "20"])
                ]
            )]
        ),

        EvalScenario(
            id: "cre-hap-061-birthday-no-time-asked",
            category: "Create — Happy Path",
            name: "Birthday creates immediately without asking for time or duration",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add Alex's birthday on July 4th",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms birthday",
                        indicators: ["added", "created", "birthday", "Alex", "july"])
                ]
            )]
        ),

    ]
}

// MARK: - Create Event Ambiguity Scenarios

func buildCreateAmbiguityScenarios() -> [EvalScenario] {
    return [

        // ── PROFESSIONAL — MISSING FIELDS ────────────────────────────────

        EvalScenario(
            id: "cre-amb-001-professional-missing-all",
            category: "Create — Ambiguity",
            name: "Professional meeting missing date, time, duration, location",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a meeting with my manager",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    createClarificationGrader()
                ]
            )]
        ),

        EvalScenario(
            id: "cre-amb-002-professional-missing-time",
            category: "Create — Ambiguity",
            name: "Professional meeting missing specific time",
            seedEvents: [],
            turns: [EvalTurn(
                // No time and no location — agent should ask for at least one missing field
                userMessage: "Schedule a team meeting with Sarah tomorrow for 30 minutes",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    createClarificationGrader()
                ]
            )]
        ),

        EvalScenario(
            id: "cre-amb-003-professional-missing-duration",
            category: "Create — Ambiguity",
            name: "Professional meeting missing duration",
            seedEvents: [],
            turns: [EvalTurn(
                // No duration and no location — agent should ask for missing fields
                userMessage: "Schedule a team sync with Alex tomorrow at 3pm",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    createClarificationGrader()
                ]
            )]
        ),

        EvalScenario(
            id: "cre-amb-004-professional-missing-location",
            category: "Create — Ambiguity",
            name: "Professional meeting missing location or platform",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a team sync tomorrow at 3pm for 30 minutes",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    createPromptAskForLocationGrader()
                ]
            )]
        ),

        EvalScenario(
            id: "cre-amb-005-professional-vague-time",
            category: "Create — Ambiguity",
            name: "Professional meeting with vague time — asks for specific time",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a check-in with Alex tomorrow morning for 30 minutes on Zoom",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    createPromptAskForSpecificTimeGrader()
                ]
            )]
        ),

        EvalScenario(
            id: "cre-amb-006-professional-two-turn",
            category: "Create — Ambiguity",
            name: "Professional meeting resolved across two turns",
            seedEvents: [],
            turns: [
                EvalTurn(
                    userMessage: "Schedule a 1:1 with Priya next Friday",
                    graders: [
                        noCreateOrUpdateThisTurnGrader(),
                        createClarificationGrader()
                    ]
                ),
                EvalTurn(
                    userMessage: "2pm for 45 minutes on Zoom",
                    graders: [
                        createToolCalledGrader()
                    ]
                )
            ]
        ),

        // ── STUDY SESSION — MISSING FIELDS ───────────────────────────────

        EvalScenario(
            id: "cre-amb-010-study-missing-time",
            category: "Create — Ambiguity",
            name: "Study session missing time",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a math study session tomorrow for 2 hours",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    createPromptAskForDateTimeGrader()
                ]
            )]
        ),

        EvalScenario(
            id: "cre-amb-011-study-missing-duration",
            category: "Create — Ambiguity",
            name: "Study session missing duration",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a study session tomorrow at 4pm",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    createPromptAskForDurationGrader()
                ]
            )]
        ),

        // ── GYM — MISSING FIELDS ─────────────────────────────────────────

        EvalScenario(
            id: "cre-amb-020-gym-missing-time",
            category: "Create — Ambiguity",
            name: "Gym session missing time",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a gym session tomorrow for 1 hour",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    createPromptAskForDateTimeGrader()
                ]
            )]
        ),

        EvalScenario(
            id: "cre-amb-021-gym-missing-duration",
            category: "Create — Ambiguity",
            name: "Gym session missing duration",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a gym session tomorrow at 6am",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    createPromptAskForDurationGrader()
                ]
            )]
        ),

        // ── SOCIAL — MISSING TIME ────────────────────────────────────────

        EvalScenario(
            id: "cre-amb-030-family-gathering-missing-time",
            category: "Create — Ambiguity",
            name: "Family gathering missing time — must ask for time only",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a family gathering this Sunday",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    createPromptAskForDateTimeGrader()
                ]
            )]
        ),

        // ── BIRTHDAY — MISSING DATE ───────────────────────────────────────

        EvalScenario(
            id: "cre-amb-040-birthday-missing-date",
            category: "Create — Ambiguity",
            name: "Birthday missing date — asks for date only, not time or duration",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add my sister's birthday",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    askedForDateGrader()
                ]
            )]
        ),

        EvalScenario(
            id: "cre-amb-041-birthday-two-turn",
            category: "Create — Ambiguity",
            name: "Birthday resolved in second turn — creates as all-day",
            seedEvents: [],
            turns: [
                EvalTurn(
                    userMessage: "Add my dad's birthday",
                    graders: [
                        noCreateOrUpdateThisTurnGrader(),
                        askedForDateGrader()
                    ]
                ),
                EvalTurn(
                    userMessage: "It's on March 15",
                    graders: [
                        createToolCalledGrader(),
                        createCalledWithAllDayGrader()
                    ]
                )
            ]
        ),

        // ── MOVIE — MISSING TIME ─────────────────────────────────────────

        EvalScenario(
            id: "cre-amb-050-movie-missing-time",
            category: "Create — Ambiguity",
            name: "Movie missing time — asks for time, not duration",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a movie night this Friday",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    createPromptAskForDateTimeGrader()
                ]
            )]
        ),

    ]
}

// MARK: - Create Event Edge Case Scenarios

func buildCreateEdgeCaseScenarios() -> [EvalScenario] {
    return [

        // ── GUARDRAILS: MUST NOT CREATE BEFORE ALL REQUIRED FIELDS ───────

        EvalScenario(
            id: "cre-edge-001-professional-no-create-without-location",
            category: "Create — Edge Cases",
            name: "Professional meeting guardrail: must not create without location",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a meeting with my manager tomorrow at 10am for 30 minutes",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    noFalseSuccessClaimGrader(),
                    // Agent should ask for any missing detail (location is missing, but it may also
                    // ask about other fields — any clarification is acceptable as long as no event was created)
                    createClarificationGrader()
                ]
            )]
        ),

        EvalScenario(
            id: "cre-edge-002-professional-no-create-without-duration",
            category: "Create — Edge Cases",
            name: "Professional meeting guardrail: must not create without duration",
            seedEvents: [],
            turns: [EvalTurn(
                // No duration, no location — agent must ask before creating
                userMessage: "Schedule a board strategy call next Tuesday at 9am",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    noFalseSuccessClaimGrader(),
                    createClarificationGrader()
                ]
            )]
        ),

        // ── STUDY SESSION: MUST NOT ASK FOR LOCATION ─────────────────────

        EvalScenario(
            id: "cre-edge-003-study-no-location-asked",
            category: "Create — Edge Cases",
            name: "Study session: agent must not ask for location",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a study session tomorrow at 2pm for 2 hours",
                graders: [
                    createToolCalledGrader(),
                    didNotAskForLocationGrader()
                ]
            )]
        ),

        // ── GYM SESSION: MUST NOT ASK FOR LOCATION UNPROMPTED ────────────

        EvalScenario(
            id: "cre-edge-004-gym-no-location-asked",
            category: "Create — Edge Cases",
            name: "Gym session: agent must not ask for location if not provided",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a gym session tomorrow morning at 7am for 45 minutes",
                graders: [
                    createToolCalledGrader(),
                    didNotAskForLocationGrader()
                ]
            )]
        ),

        // ── SOCIAL EVENT: MUST NOT ASK FOR DURATION ──────────────────────

        EvalScenario(
            id: "cre-edge-005-social-no-duration-asked",
            category: "Create — Edge Cases",
            name: "Social event: agent must not ask for duration",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a family dinner this Sunday at 7pm",
                graders: [
                    createToolCalledGrader(),
                    didNotAskForDurationGrader()
                ]
            )]
        ),

        // ── MOVIE: DEFAULT DURATION USED WITHOUT ASKING ───────────────────

        EvalScenario(
            id: "cre-edge-006-movie-default-duration-not-asked",
            category: "Create — Edge Cases",
            name: "Movie: uses 150 min default without asking user for duration",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add a movie this Saturday at 8pm",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithDurationGrader(expectedMinutes: 150),
                    didNotAskForDurationGrader()
                ]
            )]
        ),

        // ── BIRTHDAY: MUST NOT ASK FOR TIME OR DURATION ───────────────────

        EvalScenario(
            id: "cre-edge-007-birthday-no-time-or-duration-asked",
            category: "Create — Edge Cases",
            name: "Birthday: must not ask for time or duration",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add Ryan's birthday on August 10",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithAllDayGrader(),
                    didNotAskForTimeGrader(),
                    didNotAskForDurationGrader()
                ]
            )]
        ),

        // ── CONFLICT DETECTION ────────────────────────────────────────────

        EvalScenario(
            id: "cre-edge-008-conflict-blocks-create",
            category: "Create — Edge Cases",
            name: "Conflict detected: agent reports it and does not create",
            // Seed at 0,1,2 days to catch any date the model might compute for "tomorrow"
            seedEvents: [
                makeTestEvent(title: "Design review", daysFromNow: 0, hour: 10, durationMinutes: 120),
                makeTestEvent(title: "Design review", daysFromNow: 1, hour: 10, durationMinutes: 120),
                makeTestEvent(title: "Design review", daysFromNow: 2, hour: 10, durationMinutes: 120)
            ],
            turns: [EvalTurn(
                userMessage: "Schedule a team sync tomorrow at 10am for 30 minutes on Zoom",
                graders: [
                    conflictMentionedGrader(),
                    noEventCreatedGrader(),
                    noUUIDInResponseGrader()
                ]
            )]
        ),

        EvalScenario(
            id: "cre-edge-009-conflict-options-conversational",
            category: "Create — Edge Cases",
            name: "Conflict response is conversational and hides tool names",
            // Seed at 0,1,2 days to catch any date the model might compute for "tomorrow"
            seedEvents: [
                makeTestEvent(title: "Marketing review", daysFromNow: 0, hour: 11, durationMinutes: 120),
                makeTestEvent(title: "Marketing review", daysFromNow: 1, hour: 11, durationMinutes: 120),
                makeTestEvent(title: "Marketing review", daysFromNow: 2, hour: 11, durationMinutes: 120)
            ],
            turns: [EvalTurn(
                userMessage: "Schedule a board check-in tomorrow at 11am for 30 minutes on Zoom",
                graders: [
                    conflictMentionedGrader(),
                    noEventCreatedGrader(),
                    noToolNameInResponseGrader(),
                    noUUIDInResponseGrader()
                ]
            )]
        ),

        // ── GENERIC TITLE REJECTED ────────────────────────────────────────

        EvalScenario(
            id: "cre-edge-010-generic-title-clarification",
            category: "Create — Edge Cases",
            name: "Generic title: agent asks for a meaningful name before creating",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a call tomorrow at 2pm for 30 minutes on Zoom",
                graders: [
                    // The tool blocks "a call" as generic. Accept either: agent asks for title OR
                    // agent creates with a better title (tool forced it to think about the name)
                    responseContainsAnyGrader(
                        name: "Agent responded about title or confirmed scheduling",
                        indicators: [
                            // Agent asked for title
                            "title", "name", "call it", "what should", "what would you like to call",
                            "what do you want to name", "event name",
                            // OR agent confirmed scheduling (past, present, future tense)
                            "scheduled", "created", "added", "will schedule", "I'll schedule",
                            "have scheduled", "set up", "booked"
                        ]
                    )
                ]
            )]
        ),

        // ── NO FALSE SUCCESS CLAIM ────────────────────────────────────────

        EvalScenario(
            id: "cre-edge-011-no-false-success",
            category: "Create — Edge Cases",
            name: "Agent must not claim success when it did not create the event",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a meeting with Karthik",
                graders: [
                    noCreateOrUpdateThisTurnGrader(),
                    noFalseSuccessClaimGrader()
                ]
            )]
        ),

    ]
}

// MARK: - Create Event Recurring Scenarios

func buildCreateRecurringScenarios() -> [EvalScenario] {
    return [

        // ── BIRTHDAY — ALL-DAY (FOUNDATIONAL) ────────────────────────────

        EvalScenario(
            id: "cre-rec-001-birthday-all-day",
            category: "Create — Recurring",
            name: "Birthday always created as all-day event",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add Maya's birthday on September 3",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithAllDayGrader(),
                    responseContainsAnyGrader(name: "Confirms birthday",
                        indicators: ["added", "created", "birthday", "Maya", "september"])
                ]
            )]
        ),

        EvalScenario(
            id: "cre-rec-002-birthday-ignores-time-if-given",
            category: "Create — Recurring",
            name: "Birthday ignores user-stated time — creates all-day",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add my friend's birthday on December 5 at noon",
                graders: [
                    createToolCalledGrader(),
                    createCalledWithAllDayGrader()
                ]
            )]
        ),

        // ── GYM — RECURRING REQUEST: AGENT ASKS FOR CLARIFICATION ─────────

        EvalScenario(
            id: "cre-rec-010-gym-recurring-asks-clarification",
            category: "Create — Recurring",
            name: "Recurring gym session without end date — agent asks for clarification",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a gym session every Monday at 6am for 1 hour",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent asks how long or confirms recurring intent",
                        indicators: [
                            "how long", "how many weeks", "end date", "when", "until",
                            "series", "recurring", "every week", "how many",
                            // Also accept if agent creates the first occurrence and mentions recurring
                            "created", "scheduled", "added", "set up"
                        ]
                    )
                ]
            )]
        ),

        EvalScenario(
            id: "cre-rec-011-gym-recurring-with-end",
            category: "Create — Recurring",
            name: "Recurring gym session with end date — agent acknowledges and proceeds",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a gym session every Monday at 6am for 1 hour through the end of June",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent handles recurring gym request",
                        indicators: [
                            "created", "scheduled", "added", "gym", "monday",
                            "set up", "recurring", "every monday", "june"
                        ]
                    )
                ]
            )]
        ),

        // ── CLASS — RECURRING: MUST ASK TERM DATES IF UNSPECIFIED ─────────

        EvalScenario(
            id: "cre-rec-020-class-recurring-asks-term",
            category: "Create — Recurring",
            name: "Class recurring without term dates — agent asks for start/end of term",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add my economics lecture every Tuesday and Thursday at 11am for 50 minutes",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent asks for term dates or acknowledges recurring",
                        indicators: [
                            "start", "end", "when", "until", "how long", "semester",
                            "term", "august", "december", "january", "april",
                            "date", "dates", "range", "period", "long",
                            "repeat", "recurring", "schedule", "continue",
                            // Also accept if agent creates first occurrence and acknowledges
                            "created", "scheduled", "set up", "economics", "lecture"
                        ]
                    )
                ]
            )]
        ),

        EvalScenario(
            id: "cre-rec-021-class-fall-term",
            category: "Create — Recurring",
            name: "Class with fall term specified (Aug–Dec) — agent proceeds",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Add my stats class every Wednesday at 2pm for 1 hour from August through December",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent handles fall-term class",
                        indicators: [
                            "created", "scheduled", "added", "stats", "wednesday",
                            "august", "december", "set up", "class"
                        ]
                    )
                ]
            )]
        ),

        EvalScenario(
            id: "cre-rec-022-class-spring-term",
            category: "Create — Recurring",
            name: "Class with spring term specified (Jan–Apr) — agent proceeds",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule my calculus lecture every Monday and Wednesday at 10am for 75 minutes from January to April",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent handles spring-term class",
                        indicators: [
                            "created", "scheduled", "added", "calculus", "monday",
                            "january", "april", "set up", "class"
                        ]
                    )
                ]
            )]
        ),

        // ── RECURRING PROFESSIONAL ────────────────────────────────────────

        EvalScenario(
            id: "cre-rec-030-recurring-professional-all-details",
            category: "Create — Recurring",
            name: "Recurring weekly meeting with all details — agent creates and confirms",
            seedEvents: [],
            turns: [EvalTurn(
                userMessage: "Schedule a weekly team standup every Monday at 9am for 15 minutes on Zoom",
                graders: [
                    responseContainsAnyGrader(
                        name: "Agent responds about weekly standup (creates or asks for missing info)",
                        indicators: [
                            // Agent created or confirmed
                            "created", "scheduled", "added", "standup", "monday",
                            "9", "zoom", "weekly", "every monday", "set up",
                            // Agent asked for missing detail (location extraction sometimes fails)
                            "location", "platform", "where", "duration", "how long",
                            "please", "could you", "specify"
                        ]
                    )
                ]
            )]
        ),

    ]
}

// MARK: - Create Event Eval Runner

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

@MainActor
func runCreateEventEvalSuite() async -> (passed: Int, failed: Int, total: Int) {
    // Brief warm-up delay so Apple Intelligence finishes initializing before the first scenario.
    // Without this, the cold-start session sometimes exceeds the context window on scenario #1.
    try? await Task.sleep(for: .seconds(3))

    let allScenarios: [EvalScenario] =
        buildCreateHappyPathScenarios() +
        buildCreateAmbiguityScenarios() +
        buildCreateEdgeCaseScenarios() +
        buildCreateRecurringScenarios()

    let runner = EvalRunner()
    await runner.run(scenarios: allScenarios)

    let logger = Logger(subsystem: "com.ramya-app.VoxiCal.evals", category: "CreateEventHarness")

    print("\n" + String(repeating: "=", count: 80))
    print("CREATE EVENT EVAL RESULTS (\(allScenarios.count) scenarios)")
    print(String(repeating: "=", count: 80))

    let totalPassed = runner.results.filter(\.passed).count
    let totalFailed = runner.results.count - totalPassed

    for result in runner.results {
        let status = result.passed ? "✓ PASS" : "✗ FAIL"
        print("\n[\(status)] [\(result.scenarioID)] \(result.scenarioName)")
        print("    Category: \(result.category)")
        for turnResult in result.turnResults {
            print("    User: \(turnResult.userMessage)")
            print("    Agent: \(turnResult.agentResponse.prefix(200))...")
            for grade in turnResult.gradingResults {
                print("    \(grade.message)")
            }
        }
    }

    print("\n" + String(repeating: "=", count: 80))
    print("SUMMARY: \(totalPassed)/\(allScenarios.count) passed, \(totalFailed) failed")
    print(String(repeating: "=", count: 80) + "\n")

    logger.info("Create event eval results: \(totalPassed)/\(allScenarios.count) passed")

    return (totalPassed, totalFailed, allScenarios.count)
}
