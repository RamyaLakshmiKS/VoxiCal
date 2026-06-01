import XCTest

final class UpdateEventEvalTests: XCTestCase {
    func testUpdateEventSuite() async throws {
        let (_, failed) = await runUpdateEventEvalSuite()
        // Allow up to 3 non-deterministic LLM failures — the on-device model has
        // natural variance. Failing 4+ scenarios indicates a regression.
        XCTAssertLessThanOrEqual(failed, 3, "\(failed) update-event eval(s) failed (threshold: 3) — check console output above for details")
    }
}
