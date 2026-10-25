import XCTest
import simd
@testable import ShieldCore

final class HeadTrackerTests: XCTestCase {
    // Earbud frame tilted 45° about X relative to the head: a left turn rotates
    // about (0, 0.707, 0.707) in sensor coordinates.
    private let up = simd_normalize(SIMD3<Double>(0, 1, 1))
    private let right = SIMD3<Double>(1, 0, 0)

    func testTotalAngleIgnoresHowTheEarbudSits() {
        let center = simd_quatd(angle: 0.3, axis: simd_normalize(SIMD3(1, 2, 3)))
        let left45 = center * simd_quatd(angle: .pi / 4, axis: up)
        let offset = HeadOffset.between(center: center, current: left45, up: up, right: right)
        XCTAssertEqual(offset.angle, 45, accuracy: 0.01)
        XCTAssertEqual(offset.yaw, 45, accuracy: 0.01)
        XCTAssertEqual(offset.pitch, 0, accuracy: 0.01)
        XCTAssertEqual(ShieldDirection.from(offset), .left)
        // The frame-aligned AirPods formula underestimates the same turn.
        XCTAssertLessThan(HeadOffset.between(center: center, current: left45).angle, 40)
    }

    func testDirectionsForRightTurnAndLookingDown() {
        let center = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let rightTurn = HeadOffset.between(center: center, current: simd_quatd(angle: -.pi / 6, axis: up), up: up, right: right)
        XCTAssertEqual(ShieldDirection.from(rightTurn), .right)
        let down = HeadOffset.between(center: center, current: simd_quatd(angle: -.pi / 6, axis: right), up: up, right: right)
        XCTAssertEqual(ShieldDirection.from(down), .down)
        XCTAssertEqual(down.angle, 30, accuracy: 0.01)
    }

    func testStitchingKeepsOrientationContinuousAcrossResets() {
        var stitcher = HeadTrackerStitcher()
        let a = stitcher.orientation(rotation: SIMD3(0, 0, 0.5), resetCounter: 0)!
        // The device re-centers: same physical pose now reads as identity.
        let b = stitcher.orientation(rotation: SIMD3(0, 0, 0), resetCounter: 1)!
        XCTAssertEqual(stitcher.resets, 1)
        XCTAssertEqual(simd_angle(a, b), 0, accuracy: 1e-6)
        // A later 0.2 rad turn is measured from the stitched pose.
        let c = stitcher.orientation(rotation: SIMD3(0, 0, 0.2), resetCounter: 1)!
        XCTAssertEqual(simd_angle(a, c), 0.2, accuracy: 1e-6)
    }

    private func simd_angle(_ p: simd_quatd, _ q: simd_quatd) -> Double {
        var r = simd_normalize(p.inverse * q); if r.real < 0 { r = simd_quatd(vector: -r.vector) }
        return r.angle
    }
}
