import Foundation
import CoreGraphics

/// Posture from the face alone. A laptop camera rarely sees shoulders, but the face
/// box tells a lot relative to how you sit when calibrated: it grows when you lean in,
/// sinks when you slump, and rotates when you tilt your head.
public enum PostureIssue: String, CaseIterable, Equatable {
    case tooClose, slouching, headTilt
}

public struct PostureBaseline: Codable, Equatable {
    public let height: Double     // face height, fraction of the frame
    public let centerY: Double    // Vision coordinates: 0 bottom, 1 top
    public let roll: Double       // radians
    public init(height: Double, centerY: Double, roll: Double) {
        self.height = height; self.centerY = centerY; self.roll = roll
    }
}

public struct PosturePolicy {
    public var baseline: PostureBaseline?
    /// A problem must last this long before a reminder.
    public var hold: TimeInterval = 60
    /// The same reminder at most once per this interval.
    public var cooldown: TimeInterval = 600
    /// Without a calibration, the median of the first samples becomes the baseline.
    public var autoBaselineSamples = 60

    private var since: [PostureIssue: TimeInterval] = [:]
    private var goodSince: [PostureIssue: TimeInterval] = [:]
    private var lastReminded: [PostureIssue: TimeInterval] = [:]
    private var learning: [(Double, Double, Double)] = []

    public init(baseline: PostureBaseline? = nil) { self.baseline = baseline }

    public static func baseline(from faces: [CameraFace]) -> PostureBaseline? {
        let usable = faces.filter(\.valid)
        guard usable.count >= 3 else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return PostureBaseline(height: median(usable.map { Double($0.bounds.height) }),
                               centerY: median(usable.map { Double($0.bounds.midY) }),
                               roll: median(usable.map { $0.roll ?? 0 }))
    }

    /// Current issues for one face, ignoring how long they have lasted.
    public func issues(for face: CameraFace) -> Set<PostureIssue> {
        guard let baseline, face.valid else { return [] }
        var result: Set<PostureIssue> = []
        let height = Double(face.bounds.height)
        if height >= baseline.height * 1.3 { result.insert(.tooClose) }
        // Sinking: the face drops by a fifth of its own height or more without coming closer.
        if baseline.centerY - Double(face.bounds.midY) >= max(0.08, baseline.height * 0.45), height < baseline.height * 1.15 {
            result.insert(.slouching)
        }
        if let roll = face.roll, abs(roll - baseline.roll) >= 15 * .pi / 180 { result.insert(.headTilt) }
        return result
    }

    /// Feed the largest face (nil when nobody is in view). Returns a reminder when an
    /// issue has lasted `hold` seconds; brief corrections under 5 s don't reset it.
    public mutating func observe(_ face: CameraFace?, at time: TimeInterval) -> PostureIssue? {
        guard let face, face.valid else { return nil }
        if baseline == nil {
            learning.append((Double(face.bounds.height), Double(face.bounds.midY), face.roll ?? 0))
            if learning.count >= autoBaselineSamples {
                func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
                baseline = PostureBaseline(height: median(learning.map(\.0)), centerY: median(learning.map(\.1)), roll: median(learning.map(\.2)))
                learning.removeAll()
            }
            return nil
        }
        let current = issues(for: face)
        var reminder: PostureIssue?
        for issue in PostureIssue.allCases {
            if current.contains(issue) {
                goodSince[issue] = nil
                if since[issue] == nil { since[issue] = time }
                if time - (since[issue] ?? time) >= hold, time - (lastReminded[issue] ?? -.infinity) >= cooldown, reminder == nil {
                    reminder = issue
                    lastReminded[issue] = time
                }
            } else if since[issue] != nil {
                if goodSince[issue] == nil { goodSince[issue] = time }
                if time - (goodSince[issue] ?? time) >= 5 { since[issue] = nil; goodSince[issue] = nil }
            }
        }
        return reminder
    }

    public mutating func reset() { since = [:]; goodSince = [:] }
}
