// Clinton Imaro was here 20/09/2026.

import Foundation
import simd

public struct HeadOffset: Equatable {
    public var yaw: Double
    public var pitch: Double
    public var angle: Double

    public init(yaw: Double, pitch: Double, angle: Double? = nil) {
        self.yaw = yaw
        self.pitch = pitch
        self.angle = angle ?? acos(max(-1, min(1, cos(yaw * .pi / 180) * cos(pitch * .pi / 180)))) * 180 / .pi
    }

    public static func between(center: simd_quatd, current: simd_quatd) -> HeadOffset {
        let relative = simd_normalize(center.inverse * current)
        let forward = relative.act(SIMD3<Double>(0, 1, 0))
        return HeadOffset(
            yaw: atan2(-forward.x, forward.y) * 180 / .pi,
            pitch: asin(max(-1, min(1, forward.z))) * 180 / .pi,
            angle: acos(max(-1, min(1, forward.y))) * 180 / .pi
        )
    }
}

public struct ShieldResponse {
    public var comfort: Double = 15
    public var transition: Double = 18
    public private(set) var dismissedUntilCentered = false
    private var isCovering = false

    public init(comfort: Double = 15, transition: Double = 18) {
        self.comfort = comfort
        self.transition = transition
    }

    public mutating func dismiss() { dismissedUntilCentered = true; isCovering = false }
    public mutating func recenter() { dismissedUntilCentered = false; isCovering = false }

    public mutating func coverage(angle: Double) -> Double {
        guard angle.isFinite else { return dismissedUntilCentered ? 0 : 1 }
        let threshold = max(2, min(30, comfort))
        if dismissedUntilCentered {
            if angle < threshold - min(2, threshold / 2) { dismissedUntilCentered = false }
            return 0
        }
        if !isCovering {
            guard angle > threshold else { return 0 }
            isCovering = true
        }
        if angle <= threshold - min(3, threshold / 2) {
            isCovering = false
            return 0
        }
        return max(0.01, min(1, (angle - threshold) / max(5, min(30, transition))))
    }
}

public enum ShieldDirection: String, CaseIterable {
    case left, right, up, down

    public static func from(_ offset: HeadOffset) -> ShieldDirection {
        if abs(offset.pitch) > abs(offset.yaw) { return offset.pitch >= 0 ? .up : .down }
        return offset.yaw >= 0 ? .left : .right
    }
}

public enum GlassMask {
    public static func opacity(position: Double, coverage: Double) -> Double {
        guard coverage.isFinite, position.isFinite else { return 0 }
        let progress = max(0, min(1, coverage))
        if progress == 0 { return 0 }
        if progress == 1 { return 1 }
        let feather = 0.48
        let linear = max(0, min(1, (progress * (1 + feather) - position) / feather))
        // Zero slope and acceleration at both ends keep the feather from
        // developing a visible edge as it enters or leaves the display.
        return linear * linear * linear * (linear * (linear * 6 - 15) + 10)
    }
}

public struct GlassTransition {
    public private(set) var value = 0.0
    private var velocity = 0.0
    public init() {}

    public mutating func advance(to requestedTarget: Double, elapsed: Double) -> Double {
        guard requestedTarget.isFinite, elapsed.isFinite else { return value }
        let target = max(0, min(1, requestedTarget))
        let dt = max(0, min(1.0 / 15, elapsed))
        let frequency = 14.0
        let displacement = value - target
        let change = velocity + frequency * displacement
        let decay = exp(-frequency * dt)
        value = target + (displacement + change * dt) * decay
        velocity = (velocity - frequency * change * dt) * decay
        if value < 0 || value > 1 { value = max(0, min(1, value)); velocity = 0 }
        if abs(value - target) < 0.001 && abs(velocity) < 0.02 { value = target; velocity = 0 }
        return value
    }

    public mutating func reset() { value = 0; velocity = 0 }
}

extension HeadOffset {
    /// For head trackers whose sensor frame is not aligned with the head, such as
    /// earbuds that sit tilted in the ear. The covering angle is the total rotation
    /// from center, which does not depend on the frame; yaw and pitch only split it
    /// along the given axes to pick the blur direction. `up` is the axis a left turn
    /// rotates about; `right` the axis looking up rotates about.
    public static func between(center: simd_quatd, current: simd_quatd, up: SIMD3<Double>, right: SIMD3<Double>) -> HeadOffset {
        var relative = simd_normalize(center.inverse * current)
        if relative.real < 0 { relative = simd_quatd(vector: -relative.vector) }
        let degrees = relative.angle * 180 / .pi
        guard degrees.isFinite, degrees > 1e-6 else { return HeadOffset(yaw: 0, pitch: 0, angle: 0) }
        let axis = relative.axis
        return HeadOffset(yaw: degrees * simd_dot(axis, up), pitch: degrees * simd_dot(axis, right), angle: degrees)
    }
}

/// Android's head tracker HID protocol (used by Sony and other earbuds) reports a
/// rotation vector whose reference frame jumps whenever the reset counter changes.
/// Stitching keeps the orientation continuous so a calibrated center stays valid.
public struct HeadTrackerStitcher {
    private var correction = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var lastCounter: UInt8?
    private var lastOutput: simd_quatd?
    public private(set) var resets = 0
    public init() {}

    /// `rotation` is the reported axis-angle vector in radians.
    public mutating func orientation(rotation: SIMD3<Double>, resetCounter: UInt8) -> simd_quatd? {
        guard rotation.x.isFinite, rotation.y.isFinite, rotation.z.isFinite else { return nil }
        let angle = simd_length(rotation)
        let raw = angle > 1e-9 ? simd_quatd(angle: angle, axis: rotation / angle) : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        if let lastCounter, lastCounter != resetCounter, let lastOutput {
            correction = simd_normalize(lastOutput * raw.inverse)
            resets += 1
        }
        lastCounter = resetCounter
        let output = simd_normalize(correction * raw)
        lastOutput = output
        return output
    }
}
