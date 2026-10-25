import XCTest
@testable import ShieldCore

final class PosturePolicyTests: XCTestCase {
    private let base = PostureBaseline(height: 0.40, centerY: 0.50, roll: 0)
    private func face(height: Double = 0.40, centerY: Double = 0.50, roll: Double = 0) -> CameraFace {
        CameraFace(bounds: CGRect(x: 0.5 - height * 0.4, y: centerY - height / 2, width: height * 0.8, height: height), yaw: 0, pitch: 0, roll: roll)
    }

    func testDetectsEachIssueAgainstTheBaseline() {
        let policy = PosturePolicy(baseline: base)
        XCTAssertEqual(policy.issues(for: face()), [])
        XCTAssertEqual(policy.issues(for: face(height: 0.55)), [.tooClose])
        XCTAssertEqual(policy.issues(for: face(centerY: 0.30)), [.slouching])
        XCTAssertEqual(policy.issues(for: face(roll: 0.35)), [.headTilt])
        XCTAssertEqual(policy.issues(for: face(height: 0.44, centerY: 0.47, roll: 0.1)), [], "Small changes are fine")
    }

    func testRemindsOnlyAfterTheHoldAndThenRespectsTheCooldown() {
        var policy = PosturePolicy(baseline: base)
        policy.hold = 60; policy.cooldown = 600
        var reminders: [PostureIssue] = []
        for t in stride(from: 0.0, through: 59, by: 1) { if let r = policy.observe(face(height: 0.56), at: t) { reminders.append(r) } }
        XCTAssertTrue(reminders.isEmpty)
        if let r = policy.observe(face(height: 0.56), at: 60.5) { reminders.append(r) }
        XCTAssertEqual(reminders, [.tooClose])
        for t in stride(from: 61.0, through: 400, by: 1) { if let r = policy.observe(face(height: 0.56), at: t) { reminders.append(r) } }
        XCTAssertEqual(reminders.count, 1, "Not again within ten minutes")
    }

    func testBriefCorrectionsDoNotResetButSustainedOnesDo() {
        var policy = PosturePolicy(baseline: base)
        policy.hold = 30
        for t in stride(from: 0.0, through: 20, by: 1) { _ = policy.observe(face(centerY: 0.28), at: t) }
        for t in stride(from: 21.0, through: 23, by: 1) { _ = policy.observe(face(), at: t) }   // 3 s upright
        var reminded = false
        for t in stride(from: 24.0, through: 31, by: 1) { reminded = reminded || policy.observe(face(centerY: 0.28), at: t) == .slouching }
        XCTAssertTrue(reminded, "A 3 s correction keeps the clock")
        var fresh = PosturePolicy(baseline: base); fresh.hold = 30
        for t in stride(from: 0.0, through: 20, by: 1) { _ = fresh.observe(face(centerY: 0.28), at: t) }
        for t in stride(from: 21.0, through: 30, by: 1) { _ = fresh.observe(face(), at: t) }      // 10 s upright
        var early = false
        for t in stride(from: 31.0, through: 45, by: 1) { early = early || fresh.observe(face(centerY: 0.28), at: t) != nil }
        XCTAssertFalse(early, "Sitting up for 10 s starts over")
    }

    func testLearnsABaselineWhenNotCalibrated() {
        var policy = PosturePolicy()
        policy.autoBaselineSamples = 10
        for t in 0..<10 { XCTAssertNil(policy.observe(face(height: 0.38), at: Double(t))) }
        XCTAssertEqual(policy.baseline?.height ?? 0, 0.38, accuracy: 0.001)
    }
}
