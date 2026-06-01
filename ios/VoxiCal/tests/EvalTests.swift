import XCTest

// Source files are compiled directly into this target — no module import needed.
final class EvalTests: XCTestCase {
    func testEvalSuite() async throws {
        let (_, failed) = await runEvaluationSuite()
        XCTAssertEqual(failed, 0, "\(failed) eval(s) failed — check console output above for details")
    }
}
