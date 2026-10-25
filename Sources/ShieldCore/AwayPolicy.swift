import Foundation

/// "Cover when I leave": covers after no face has been seen for `delay` seconds and the
/// picture has gone still. Someone slumped or turned so their face isn't detected
/// still moves; an empty chair doesn't. Identity is not checked; clearing is manual
/// (keyboard / Touch ID), so the camera can stop entirely while covered.
public struct AwayPolicy {
    public var delay: TimeInterval
    /// Fraction of sampled points whose brightness changed between analyzed frames
    /// that counts as someone moving (a person sitting still measured 0.9–11 %).
    public var activityThreshold = 0.015
    /// Recent movement keeps you present this long after the last face. Field logs
    /// showed people sitting with their face out of frame for 15 s while still moving.
    public var stillFor: TimeInterval = 5
    /// With no face at all for this long, cover even if something moves (people
    /// walking behind the chair must not hold the screen open).
    public var hardLimit: TimeInterval = 60
    public private(set) var away = false
    private var lastFace: TimeInterval?
    private var lastSample: TimeInterval?
    private var lastActivity: TimeInterval?

    public init(delay: TimeInterval = 5) { self.delay = delay }

    /// Starts (or restarts after unlocking) as present.
    public mutating func start(at time: TimeInterval) {
        away = false
        lastFace = time
        lastSample = time
        lastActivity = time
    }

    /// Returns true when this sample makes the user count as away. `motion` is the
    /// changed fraction of the picture since the previous sample, when measured.
    @discardableResult public mutating func observe(faceCount: Int, motion: Double? = nil, at time: TimeInterval) -> Bool {
        guard !away, time.isFinite else { return false }
        if let lastSample, time < lastSample { return false }
        lastSample = time
        if let motion, motion >= activityThreshold { lastActivity = time }
        if faceCount > 0 { lastFace = time; return false }
        return becomeAwayIfDue(at: time)
    }

    /// Camera frames stopped arriving: after the same delay plus a margin, assume away
    /// rather than leave the screen clear with nobody watching it.
    @discardableResult public mutating func checkStalled(at time: TimeInterval) -> Bool {
        guard !away, let lastSample, time - lastSample >= delay + 3 else { return false }
        away = true
        return true
    }

    private mutating func becomeAwayIfDue(at time: TimeInterval) -> Bool {
        let noFace = time - (lastFace ?? time)
        guard noFace >= delay else { return false }
        let moving = time - (lastActivity ?? -.infinity) < stillFor
        guard !moving || noFace >= max(hardLimit, delay) else { return false }
        away = true
        return true
    }
}
