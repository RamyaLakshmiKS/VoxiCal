import XCTest

/// XCTest wrapper for the agent behavior eval suite.
///
/// Validates that the agent always responds in plain conversational prose (no markdown),
/// never exposes internal event IDs or tool names in user-facing responses, handles
/// conflict options cleanly, and does not misclassify question-about-past-action messages
/// as mutation intents.
///
/// Threshold: ≤2 failures tolerated for LLM non-determinism.
final class AgentBehaviorEvalTests: XCTestCase {
    func testAgentBehaviorSuite() async throws {
        let (passed, failed) = await runAgentBehaviorEvalSuite()
        let total = passed + failed
        XCTAssertGreaterThan(total, 0, "Expected at least one scenario to run")
        XCTAssertLessThanOrEqual(
            failed, 2,
            "Agent behavior eval: \(failed)/\(total) scenarios failed (threshold: ≤2). " +
            "Check console output for details."
        )
    }
}
