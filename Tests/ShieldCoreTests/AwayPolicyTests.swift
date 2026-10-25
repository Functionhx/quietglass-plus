import XCTest
@testable import ShieldCore

final class AwayPolicyTests: XCTestCase {
    func testCoversOnlyAfterTheDelayWithNoFace() {
        var policy = AwayPolicy(delay: 5)
        policy.start(at: 0)
        XCTAssertFalse(policy.observe(faceCount: 1, at: 1))
        XCTAssertFalse(policy.observe(faceCount: 0, at: 3))
        XCTAssertFalse(policy.observe(faceCount: 0, at: 5.9), "Looking down for under 5 s stays clear")
        XCTAssertTrue(policy.observe(faceCount: 0, at: 6.1))
        XCTAssertTrue(policy.away)
        XCTAssertFalse(policy.observe(faceCount: 1, at: 7), "Coming back does not clear by itself")
        XCTAssertTrue(policy.away)
    }

    func testABriefFaceResetsTheTimer() {
        var policy = AwayPolicy(delay: 5)
        policy.start(at: 0)
        policy.observe(faceCount: 0, at: 4)
        policy.observe(faceCount: 1, at: 4.5)
        XCTAssertFalse(policy.observe(faceCount: 0, at: 9))
        XCTAssertTrue(policy.observe(faceCount: 0, at: 9.6))
    }

    func testUnlockRestartsAsPresentAndStalledCameraCovers() {
        var policy = AwayPolicy(delay: 5)
        policy.start(at: 0)
        policy.observe(faceCount: 0, at: 6)
        XCTAssertTrue(policy.away)
        policy.start(at: 20)
        XCTAssertFalse(policy.away)
        XCTAssertFalse(policy.checkStalled(at: 27))
        XCTAssertTrue(policy.checkStalled(at: 28.5))
    }
}
