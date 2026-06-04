
import XCTest

/// Unit tests for VoxiCalAgent's pure Swift logic (intent detection, field extraction).
/// These test the fast-path heuristics independently of the LLM.
@MainActor
final class VoxiCalAgentTests: XCTestCase {

    // MARK: - detectIntent

    func testDetectIntentDeleteCommandIsDelete() {
        XCTAssertEqual(agent.intentFor("Delete my 3pm meeting"), .delete)
        XCTAssertEqual(agent.intentFor("Remove the standup tomorrow"), .delete)
        XCTAssertEqual(agent.intentFor("Cancel meeting with Priya"), .delete)
    }

    func testDetectIntentUpdateCommandIsUpdate() {
        XCTAssertEqual(agent.intentFor("Reschedule my standup to 10 AM"), .update)
        XCTAssertEqual(agent.intentFor("Move the 1:1 to Friday"), .update)
        XCTAssertEqual(agent.intentFor("Change the meeting to Zoom"), .update)
    }

    func testDetectIntentCreateCommandIsCreate() {
        XCTAssertEqual(agent.intentFor("Schedule a meeting with Karthik tomorrow"), .create)
        XCTAssertEqual(agent.intentFor("Book a call with Sarah at 3 PM"), .create)
        XCTAssertEqual(agent.intentFor("Add a standup on Friday at 9 AM"), .create)
    }

    func testDetectIntentReadQueryIsRead() {
        XCTAssertEqual(agent.intentFor("What do I have tomorrow?"), .read)
        XCTAssertEqual(agent.intentFor("Show me my meetings this week"), .read)
        XCTAssertEqual(agent.intentFor("Do I have any calls today?"), .read)
    }

    // Questions about past actions must NOT trigger mutation intents
    func testDetectIntentWhyDeleteIsUnknown() {
        XCTAssertEqual(agent.intentFor("Why did you delete the meeting?"), .unknown)
    }

    func testDetectIntentWhyUpdateIsUnknown() {
        XCTAssertEqual(agent.intentFor("Why did you move my standup?"), .unknown)
    }

    func testDetectIntentDidYouDeleteIsUnknown() {
        XCTAssertEqual(agent.intentFor("Did you delete my 1:1 with Karthik?"), .unknown)
    }

    func testDetectIntentDidYouMoveIsUnknown() {
        XCTAssertEqual(agent.intentFor("Did you move the meeting to next week?"), .unknown)
    }

    func testDetectIntentHaveYouCancelledIsUnknown() {
        XCTAssertEqual(agent.intentFor("Have you cancelled my Friday standup?"), .unknown)
    }

    func testDetectIntentWhatDidYouDoIsUnknown() {
        XCTAssertEqual(agent.intentFor("What did you change on my calendar?"), .unknown)
    }

    func testDetectIntentWhyAtStartIsUnknown() {
        XCTAssertEqual(agent.intentFor("Why is my calendar showing the wrong time?"), .unknown)
    }

    // MARK: - extractedTitle

    func testExtractedTitleWithPreposition() {
        XCTAssertEqual(agent.titleFor("Schedule a meeting with Karthik"), "Meeting with Karthik")
    }

    func testExtractedTitleAtPrepositionSTT() {
        // STT commonly substitutes "at" for "with"
        XCTAssertEqual(agent.titleFor("Schedule a meeting at Karthik on Zoom"), "Meeting with Karthik")
    }

    func testExtractedTitleCallWithPerson() {
        XCTAssertEqual(agent.titleFor("Book a call with Sarah at 3pm"), "Call with Sarah")
    }

    func testExtractedTitleCallAtPersonSTT() {
        XCTAssertEqual(agent.titleFor("Book a call at Sarah at 3pm"), "Call with Sarah")
    }

    func testExtractedTitleOneononeWithPerson() {
        XCTAssertEqual(agent.titleFor("Schedule a 1:1 with Alex tomorrow"), "1:1 with Alex")
    }

    func testExtractedTitleStandupKeyword() {
        XCTAssertEqual(agent.titleFor("Set up a standup for Monday"), "Standup")
    }

    func testExtractedTitleAllHandsKeyword() {
        XCTAssertEqual(agent.titleFor("Add an all hands on Friday"), "All Hands")
    }

    func testExtractedTitleReturnsNilForNoMatch() {
        XCTAssertNil(agent.titleFor("Set a reminder for 5pm"))
    }

    func testExtractedTitleZoomNotConfusedWithPerson() {
        // "at Zoom" should not be treated as a person name
        XCTAssertNil(agent.titleFor("Schedule a meeting at Zoom tomorrow at 3pm"))
    }

    // MARK: - extractedTime

    func testExtractedTimeExact3PM() {
        let t = agent.timeFor("meeting at 3 PM")
        XCTAssertEqual(t?.hour, 15)
        XCTAssertEqual(t?.minute, 0)
    }

    func testExtractedTime10AM() {
        let t = agent.timeFor("call at 10 AM tomorrow")
        XCTAssertEqual(t?.hour, 10)
        XCTAssertEqual(t?.minute, 0)
    }

    func testExtractedTimeAroundIsNil() {
        // "around 5 PM" alone is too vague — must return nil
        XCTAssertNil(agent.timeFor("meeting around 5 PM tomorrow"))
    }

    func testExtractedTimeAroundWithPreciseAtUsesExactTime() {
        // Accumulated text may contain "around 5 PM" from the original plus "at 5 PM" from the follow-up
        let combined = "Schedule a meeting tomorrow around 5 PM on Zoom Tomorrow at 5 PM"
        let t = agent.timeFor(combined)
        XCTAssertNotNil(t, "Should extract the precise 'at 5 PM' time even when 'around' also appears")
        XCTAssertEqual(t?.hour, 17)
        XCTAssertEqual(t?.minute, 0)
    }

    func testExtractedTimeMorningIsNil() {
        XCTAssertNil(agent.timeFor("Let's meet in the morning"))
    }

    func testExtractedTimeAfternoonIsNil() {
        XCTAssertNil(agent.timeFor("Call me this afternoon"))
    }

    func testExtractedTimeWithMinutes() {
        let t = agent.timeFor("meeting at 2:30 PM")
        XCTAssertEqual(t?.hour, 14)
        XCTAssertEqual(t?.minute, 30)
    }

    func testExtractedTimeMidnight12AM() {
        let t = agent.timeFor("meeting at 12 AM")
        XCTAssertEqual(t?.hour, 0)
        XCTAssertEqual(t?.minute, 0)
    }

    func testExtractedTimeNoon12PM() {
        let t = agent.timeFor("lunch at 12 PM")
        XCTAssertEqual(t?.hour, 12)
        XCTAssertEqual(t?.minute, 0)
    }

    // MARK: - extractedDurationMinutes

    func testDurationAnHour() {
        XCTAssertEqual(agent.durationFor("meeting for an hour"), 60)
    }

    func testDurationOneHour() {
        XCTAssertEqual(agent.durationFor("call for one hour"), 60)
    }

    func testDurationMaximumOfOneHour() {
        XCTAssertEqual(agent.durationFor("The event will be maximum of one hour"), 60)
    }

    func testDurationHalfHour() {
        XCTAssertEqual(agent.durationFor("sync for half an hour"), 30)
    }

    func testDuration30Minutes() {
        XCTAssertEqual(agent.durationFor("standup for 30 minutes"), 30)
    }

    func testDuration90Minutes() {
        XCTAssertEqual(agent.durationFor("workshop for 90 minutes"), 90)
    }

    func testDurationTwoHours() {
        XCTAssertEqual(agent.durationFor("session for two hours"), 120)
    }

    func testDurationAroundTwoHoursIsExtracted() {
        // "around 2 hours" is a duration modifier, not a time — should be extracted
        XCTAssertEqual(agent.durationFor("meeting for around 2 hours"), 120)
    }

    func testDurationNilWhenAbsent() {
        XCTAssertNil(agent.durationFor("schedule a meeting with Karthik tomorrow"))
    }

    // MARK: - extractedDate

    func testExtractedDateTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: Date())!)
        XCTAssertEqual(agent.dateFor("meeting tomorrow at 3 PM"), tomorrow)
    }

    func testExtractedDateToday() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        XCTAssertEqual(agent.dateFor("what's on today"), today)
    }

    // MARK: - extractedLocation

    func testLocationZoom() {
        XCTAssertEqual(agent.locationFor("meeting on Zoom"), "Zoom")
    }

    func testLocationTeams() {
        XCTAssertEqual(agent.locationFor("call on Teams"), "Teams")
    }

    func testLocationGoogleMeet() {
        XCTAssertEqual(agent.locationFor("sync on Google Meet"), "Google Meet")
    }

    func testLocationNilWhenAbsent() {
        XCTAssertNil(agent.locationFor("let's talk tomorrow"))
    }

    // MARK: - buildInstructions content checks

    func testBuildInstructionsContainsNoMarkdownRule() {
        let instructions = VoxiCalAgent.buildInstructions()
        XCTAssertTrue(
            instructions.localizedCaseInsensitiveContains("NO MARKDOWN") ||
            instructions.localizedCaseInsensitiveContains("no markdown"),
            "Instructions must explicitly forbid markdown"
        )
    }

    func testBuildInstructionsContainsNoEventIDRule() {
        let instructions = VoxiCalAgent.buildInstructions()
        XCTAssertTrue(
            instructions.contains("NEVER include eventID"),
            "Instructions must tell the model never to include eventIDs in replies"
        )
    }

    func testBuildInstructionsContainsNoFabricatedIDRule() {
        let instructions = VoxiCalAgent.buildInstructions()
        XCTAssertTrue(
            instructions.localizedCaseInsensitiveContains("fabricate") ||
            instructions.localizedCaseInsensitiveContains("guess") ||
            instructions.localizedCaseInsensitiveContains("invent"),
            "Instructions must warn against fabricating event IDs"
        )
    }

    func testBuildInstructionsContainsNoTimezoneOffsetRule() {
        let instructions = VoxiCalAgent.buildInstructions()
        XCTAssertTrue(
            instructions.contains("NEVER append timezone") ||
            instructions.contains("never append timezone") ||
            instructions.contains("timezone offset"),
            "Instructions must warn against appending timezone offsets to ISO dates"
        )
    }

    func testBuildInstructionsConflictOptionsUseNoToolNames() {
        let instructions = VoxiCalAgent.buildInstructions(for: .create)
        // The conflict handling instruction must tell the model not to expose tool names to users
        let prohibitsToolExposure =
            instructions.contains("Never mention tool names") ||
            instructions.contains("never mention tool names") ||
            instructions.contains("Do not reveal internal tool names") ||
            instructions.localizedCaseInsensitiveContains("do not reveal") && instructions.localizedCaseInsensitiveContains("tool name")
        XCTAssertTrue(prohibitsToolExposure, "Conflict instructions must explicitly tell the model not to reveal tool names to users")
    }

    // MARK: - Helpers (access private API via testable extension)

    private let agent = VoxiCalAgent()
}

// MARK: - Testable extension

extension VoxiCalAgent {
    func intentFor(_ text: String) -> CalendarIntent { detectIntent(text) }
    func titleFor(_ text: String) -> String?           { extractedTitle(from: text) }
    func timeFor(_ text: String) -> (hour: Int, minute: Int)? { extractedTime(from: text) }
    func durationFor(_ text: String) -> Int?           { extractedDurationMinutes(from: text) }
    func dateFor(_ text: String) -> Date?              { extractedDate(from: text) }
    func locationFor(_ text: String) -> String?        { extractedLocation(from: text) }
}
