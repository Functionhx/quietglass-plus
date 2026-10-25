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

    func testMovementWithoutAFaceKeepsYouPresentUntilTheHardLimit() {
        var policy = AwayPolicy(delay: 5)
        policy.start(at: 0)
        // Slumped: no face detected, but the picture keeps changing.
        for t in stride(from: 0.5, through: 15, by: 0.5) {
            XCTAssertFalse(policy.observe(faceCount: 0, motion: 0.04, at: t), "still moving at \(t)")
        }
        // Becomes still: covers once 5 s of stillness follow 5 s without a face.
        XCTAssertFalse(policy.observe(faceCount: 0, motion: 0.002, at: 18))
        XCTAssertTrue(policy.observe(faceCount: 0, motion: 0.002, at: 20.1))
    }

    func testSomeoneWalkingBehindDoesNotHoldTheScreenOpenForever() {
        var policy = AwayPolicy(delay: 5)
        policy.start(at: 0)
        var coveredAt: Double?
        for t in stride(from: 0.5, through: 90, by: 0.5) where coveredAt == nil {
            if policy.observe(faceCount: 0, motion: 0.2, at: t) { coveredAt = t }
        }
        XCTAssertEqual(coveredAt ?? -1, 60, accuracy: 0.01)
    }

    func testSmallFlickerIsNotMovement() {
        var policy = AwayPolicy(delay: 5)
        policy.start(at: 0)
        var coveredAt: Double?
        for t in stride(from: 0.5, through: 10, by: 0.5) where coveredAt == nil {
            if policy.observe(faceCount: 0, motion: 0.005, at: t) { coveredAt = t }
        }
        XCTAssertEqual(coveredAt ?? -1, 5, accuracy: 0.01)
    }
}
