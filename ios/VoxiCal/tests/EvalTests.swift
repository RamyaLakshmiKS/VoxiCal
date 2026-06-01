import XCTest

// Source files are compiled directly into this target — no module import needed.
final class EvalTests: XCTestCase {
    func testEvalSuite() async throws {
        let (_, failed) = await runEvaluationSuite()
        // Allow up to 2 non-deterministic LLM failures — the on-device model has
        // natural variance. Failing 3+ indicates a regression.
        XCTAssertLessThanOrEqual(failed, 2, "\(failed) eval(s) failed (threshold: 2) — check console output above for details")
    }
}
