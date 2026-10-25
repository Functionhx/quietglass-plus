import XCTest
@testable import ShieldCore

final class FaceProfilesTests: XCTestCase {
    /// Unit vector along `axis`, nudged so different calls are not identical.
    private func unit(_ axis: Int, tilt: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: OwnerTemplate.dimensions)
        v[axis] = 1; v[(axis + 1) % v.count] = tilt
        return OwnerTemplate.normalize(v)!
    }
    private func template(_ axis: Int) -> OwnerTemplate {
        OwnerTemplate(vectors: (0..<5).map { unit(axis, tilt: Float($0) * 0.05) }, openEyes: 0.3)
    }

    func testMatchesAnyEnrolledPersonAndPicksTheClosest() {
        let me = FaceProfile(name: "Me", template: template(0))
        let partner = FaceProfile(name: "Partner", template: template(10))
        let profiles = FaceProfiles([me, partner])
        XCTAssertTrue(profiles.isValid)
        XCTAssertEqual(profiles.match(unit(0, tilt: 0.1))?.id, me.id)
        XCTAssertEqual(profiles.match(unit(10, tilt: 0.1))?.id, partner.id)
        XCTAssertNil(profiles.match(unit(40)), "A stranger must not match anyone")
    }

    func testRejectsEmptyOversizedAndDuplicateCollections() {
        XCTAssertFalse(FaceProfiles([]).isValid)
        let many = (0..<(FaceProfiles.maximumCount + 1)).map { FaceProfile(name: "\($0)", template: template($0 * 3)) }
        XCTAssertFalse(FaceProfiles(many).isValid)
        let one = FaceProfile(name: "Me", template: template(0))
        XCTAssertFalse(FaceProfiles([one, one]).isValid)
    }

    func testDecodesCurrentAndLegacySingleTemplatePayloads() throws {
        let legacy = template(0)
        let migrated = try XCTUnwrap(FaceProfiles.decode(JSONEncoder().encode(legacy)))
        XCTAssertEqual(migrated.profiles.count, 1)
        XCTAssertEqual(migrated.profiles[0].template, legacy)
        XCTAssertEqual(migrated.profiles[0].name, FaceProfiles.defaultName)

        let current = FaceProfiles([FaceProfile(name: "Me", template: template(0)), FaceProfile(name: "Partner", template: template(10))])
        XCTAssertEqual(FaceProfiles.decode(try JSONEncoder().encode(current)), current)
        XCTAssertNil(FaceProfiles.decode(Data("{}".utf8)))
    }
}

final class OwnerQuickClearTests: XCTestCase {
    private let center = OwnerPose(yaw: 0, eyes: 0.3)

    func testMatchingFaceClearsWithoutMovementCheckDuringQuickClearWindow() {
        var presence = OwnerPresence(turnPositive: true)
        presence.allowQuickClear(until: 10)
        presence.observe(matches: false, pose: nil, openEyes: 0.3, at: 1.0) // camera warming up, nobody yet
        XCTAssertTrue(presence.covered)
        presence.observe(matches: true, pose: center, openEyes: 0.3, at: 1.1)
        presence.observe(matches: true, pose: center, openEyes: 0.3, at: 1.3)
        XCTAssertTrue(presence.covered, "Needs 0.4 s of consecutive matches")
        presence.observe(matches: true, pose: center, openEyes: 0.3, at: 1.6)
        XCTAssertFalse(presence.covered)
    }

    func testMismatchRestartsTheHoldAndExpiredWindowRequiresMovementCheck() {
        var presence = OwnerPresence(turnPositive: true)
        presence.allowQuickClear(until: 2)
        presence.observe(matches: true, pose: center, openEyes: 0.3, at: 1.0)
        presence.observe(matches: false, pose: center, openEyes: 0.3, at: 1.2)
        presence.observe(matches: true, pose: center, openEyes: 0.3, at: 1.3)
        presence.observe(matches: true, pose: center, openEyes: 0.3, at: 1.6)
        XCTAssertTrue(presence.covered, "A stranger frame must restart the hold")
        for t in stride(from: 2.1, through: 4.0, by: 0.1) {
            presence.observe(matches: true, pose: center, openEyes: 0.3, at: t)
        }
        XCTAssertTrue(presence.covered, "After the window, holding still is not enough")
        XCTAssertEqual(presence.challenge.stage, .turn)
    }
}

final class OwnerStartVerifiedTests: XCTestCase {
    func testStartsClearAfterSystemUnlockButCoversAStranger() {
        var presence = OwnerPresence(turnPositive: true)
        presence.startVerified()
        XCTAssertFalse(presence.covered)
        presence.observe(matches: true, pose: OwnerPose(yaw: 0, eyes: 0.3), openEyes: 0.3, at: 1.0)
        XCTAssertFalse(presence.covered)
        presence.observe(matches: false, pose: OwnerPose(yaw: 0, eyes: 0.3), openEyes: 0.3, at: 1.2)
        presence.observe(matches: false, pose: OwnerPose(yaw: 0, eyes: 0.3), openEyes: 0.3, at: 1.6)
        XCTAssertTrue(presence.covered, "Someone else at the keyboard still covers")
    }
}
