import Foundation

/// "Cover when I leave": covers after no face has been seen for `delay` seconds.
/// Identity is not checked; clearing is manual (keyboard / Touch ID), so the camera
/// can stop entirely while covered.
public struct AwayPolicy {
    public var delay: TimeInterval
    public private(set) var away = false
    private var lastFace: TimeInterval?
    private var lastSample: TimeInterval?

    public init(delay: TimeInterval = 5) { self.delay = delay }

    /// Starts (or restarts after unlocking) as present.
    public mutating func start(at time: TimeInterval) {
        away = false
        lastFace = time
        lastSample = time
    }

    /// Returns true when this sample makes the user count as away.
    @discardableResult public mutating func observe(faceCount: Int, at time: TimeInterval) -> Bool {
        guard !away, time.isFinite else { return false }
        if let lastSample, time < lastSample { return false }
        lastSample = time
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
        guard time - (lastFace ?? time) >= delay else { return false }
        away = true
        return true
    }
}
