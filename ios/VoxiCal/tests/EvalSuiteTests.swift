import XCTest

/// Bridges the eval harness (`runEvaluationSuite`) into XCTest so that
/// `xcodebuild test -only-testing:VoxiCalTests` actually executes the
/// agent-behavior evals. Without an XCTestCase entry point, XCTest discovers
/// zero tests and the command "passes" vacuously.
final class EvalSuiteTests: XCTestCase {

    @MainActor
    func testAgentBehaviorEvals() async {
        let (passed, failed) = await runEvaluationSuite()
        print("Eval summary: \(passed) passed, \(failed) failed")
        XCTAssertGreaterThan(passed + failed, 0, "No eval scenarios were executed")
        XCTAssertEqual(failed, 0, "\(failed) eval scenario(s) failed — see EVALUATION RESULTS above")
    }
}
