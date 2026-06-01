import XCTest

final class AmbiguousCreateEventEvalTests: XCTestCase {
    func testAmbiguousCreateEventSuite() async throws {
        let (_, failed) = await runAmbiguousCreateEventSuite()
        XCTAssertEqual(failed, 0, "\(failed) ambiguous create-event eval(s) failed — check console output above for details")
    }
}
