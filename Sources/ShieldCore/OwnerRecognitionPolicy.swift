import Foundation

/// A versioned biometric template, never a photograph or a name.
public struct OwnerTemplate: Codable, Equatable {
    public static let modelID = "sface-2021dec-rgb-v1"
    public static let dimensions = 128
    public let model: String
    public let vectors: [[Float]]
    public let openEyes: Double

    public init(vectors: [[Float]], openEyes: Double) {
        model = Self.modelID
        self.vectors = vectors
        self.openEyes = openEyes
    }

    public var isValid: Bool {
        model == Self.modelID && (3...8).contains(vectors.count) && openEyes.isFinite &&
        (0.14...0.6).contains(openEyes) && vectors.allSatisfy { v in
            guard v.count == Self.dimensions, v.allSatisfy(\.isFinite) else { return false }
            let norm = v.reduce(Float(0)) { $0 + $1 * $1 }
            return abs(norm - 1) < 0.01
        }
    }

    public static func normalize(_ values: [Float]) -> [Float]? {
        guard values.count == dimensions, values.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.000001 else { return nil }
        return values.map { $0 / norm }
    }

    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard let a = normalize(a), let b = normalize(b) else { return -1 }
        return zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }

    public func matches(_ vector: [Float]) -> Bool {
        guard isValid else { return false }
        // Deliberately stricter than SFace's LFW example threshold (0.363).
        // This similarity threshold is an operating point, not a calibrated probability.
        let scores = vectors.map { Self.similarity($0, vector) }.sorted()
        return scores[scores.count / 2] >= 0.50 && scores[0] >= 0.35
    }
}

public struct OwnerPose: Equatable {
    public let yaw: Double
    public let eyes: Double
    public let widestEye: Double
    public init(yaw: Double, eyes: Double, widestEye: Double? = nil) {
        self.yaw = yaw; self.eyes = eyes; self.widestEye = widestEye ?? eyes
    }
    // Measurement validity is separate from the angle requested by a step.
    // A visible face turning past the target must not erase enrollment.
    public var isValid: Bool { yaw.isFinite && eyes.isFinite && widestEye.isFinite && abs(yaw) <= .pi / 2 && (0...0.7).contains(eyes) && (eyes...0.7).contains(widestEye) }
}

/// A modest still-photo obstacle. RGB landmarks do not provide depth or reliable
/// presentation-attack detection; a video/deepfake may reproduce this sequence.
public struct OwnerChallenge {
    public enum Stage: Equatable { case center, turn, returnToCenter, complete }
    public private(set) var stage: Stage = .center
    public let turnPositive: Bool
    private var heldSince: TimeInterval?
    private var lastSample: TimeInterval?
    private var stageSince: TimeInterval?

    public init(turnPositive: Bool) { self.turnPositive = turnPositive }

    public var prompt: String {
        switch stage {
        case .center: return "Look at the camera"
        case .turn: return turnPositive ? "Turn slightly to your left" : "Turn slightly to your right"
        case .returnToCenter: return "Look at the camera again"
        case .complete: return "Owner verified"
        }
    }

    public mutating func observe(_ pose: OwnerPose, openEyes: Double, at time: TimeInterval) -> Bool {
        guard pose.isValid, openEyes.isFinite, openEyes >= 0.14, time.isFinite else { reset(); return false }
        if let lastSample, time <= lastSample { return stage == .complete }
        if let lastSample, time - lastSample > 0.6 { reset() }
        lastSample = time
        if let stageSince, time - stageSince > 10 { reset(); lastSample = time }
        if stageSince == nil { stageSince = time }
        let centered = abs(pose.yaw) <= 0.14
        let eyesOpen = pose.eyes >= openEyes * 0.78
        let accepted: Bool
        switch stage {
        case .center, .returnToCenter: accepted = centered && eyesOpen
        // Eye landmarks change shape in profile. Validate head motion here;
        // looking back at the camera finishes the sequence. No forced blink.
        case .turn: accepted = (turnPositive ? pose.yaw : -pose.yaw) >= 0.22 && abs(pose.yaw) <= 1.05
        case .complete: return true
        }
        guard accepted else { heldSince = nil; return false }
        if heldSince == nil { heldSince = time }
        if time - (heldSince ?? time) >= 0.25 {
            switch stage {
            case .center: stage = .turn
            case .turn: stage = .returnToCenter
            case .returnToCenter: stage = .complete
            case .complete: break
            }
            heldSince = nil
            stageSince = time
        }
        return stage == .complete
    }

    public mutating func pause() { heldSince = nil }

    public mutating func reset() {
        stage = .center
        heldSince = nil
        lastSample = nil
        stageSince = nil
    }
}

public struct OwnerPresence {
    public private(set) var covered = true
    public private(set) var challenge: OwnerChallenge
    private var missingSince: TimeInterval?
    private var lastSample: TimeInterval?

    public init(turnPositive: Bool) { challenge = OwnerChallenge(turnPositive: turnPositive) }
    private var recoveryUntil: TimeInterval?
    private var recoverySince: TimeInterval?
    private var quickClearUntil: TimeInterval?
    private var quickClearSince: TimeInterval?
    public var recoveringLandmarks: Bool { recoveryUntil != nil }

    /// Until `time`, a matching face held for 0.4 s clears protection without the
    /// movement check. Used right after macOS itself authenticated the user (unlock,
    /// wake), or always when the user turns the movement check off.
    /// Starts clear because macOS has just authenticated the user (screen unlock). Any
    /// sustained mismatch or absence still covers after the usual 0.35 s.
    public mutating func startVerified() {
        covered = false
        missingSince = nil
    }

    public mutating func allowQuickClear(until time: TimeInterval) {
        quickClearUntil = time
        quickClearSince = nil
    }

    public mutating func interrupt(turnPositive: Bool) {
        self = OwnerPresence(turnPositive: turnPositive)
    }

    @discardableResult public mutating func observe(matches: Bool, pose: OwnerPose?, openEyes: Double, at time: TimeInterval,
                                                  continuousFaceWithMissingLandmarks: Bool = false) -> Bool {
        guard time.isFinite else { return covered }
        if let lastSample, time <= lastSample { return covered }
        if let lastSample, time - lastSample > 0.6 {
            covered = true
            challenge.reset()
            missingSince = nil
            recoveryUntil = nil; recoverySince = nil
        }
        lastSample = time
        guard matches, let pose, pose.isValid else {
            if continuousFaceWithMissingLandmarks {
                if !covered && recoveryUntil == nil { recoveryUntil = time + 1.5 }
                if let until = recoveryUntil, time > until { recoveryUntil = nil }
            } else { recoveryUntil = nil }
            recoverySince = nil
            quickClearSince = nil
            // A dropped landmark or brief mismatch must not count as a held
            // pose. Restart the sequence only after sustained loss, using the
            // same short grace period as the existing cover decision.
            challenge.pause()
            if missingSince == nil { missingSince = time }
            if time - (missingSince ?? time) >= 0.35 {
                covered = true
                if recoveryUntil == nil { challenge.reset() }
            }
            return covered
        }
        missingSince = nil
        if covered, let until = quickClearUntil, time <= until {
            if quickClearSince == nil { quickClearSince = time }
            if time - (quickClearSince ?? time) >= 0.4 { covered = false; quickClearSince = nil }
            return covered
        }
        if let until = recoveryUntil {
            if time > until { recoveryUntil = nil; recoverySince = nil; challenge.reset(); covered = true }
            else if covered {
                if recoverySince == nil { recoverySince = time }
                if time - (recoverySince ?? time) >= 0.4 {
                    covered = false; recoveryUntil = nil; recoverySince = nil
                }
                return covered
            } else { recoveryUntil = nil; recoverySince = nil }
        }
        if covered && challenge.observe(pose, openEyes: openEyes, at: time) { covered = false }
        return covered
    }

    public static func isContinuousFace(_ previous: CGRect?, _ current: CGRect?) -> Bool {
        guard let previous, let current, !previous.isEmpty, !current.isEmpty else { return false }
        let intersection = previous.intersection(current)
        let overlap = max(0, intersection.width) * max(0, intersection.height)
        let union = previous.width * previous.height + current.width * current.height - overlap
        return union > 0 && overlap / union >= 0.6
    }
}

public struct OwnerEnrollment {
    public private(set) var challenge: OwnerChallenge
    public private(set) var vectors: [[Float]] = []
    private var eyeSamples: [Double] = []
    private var lastCollected: TimeInterval?
    public init(turnPositive: Bool) { challenge = OwnerChallenge(turnPositive: turnPositive) }
    public var template: OwnerTemplate? {
        guard vectors.count == 5, challenge.stage == .complete else { return nil }
        let result = OwnerTemplate(vectors: vectors, openEyes: eyeSamples.sorted()[eyeSamples.count / 2])
        return result.isValid ? result : nil
    }
    public var prompt: String { vectors.count < 5 ? "Look at the camera" : challenge.prompt }
    public var progress: Double {
        if vectors.count < 5 { return Double(vectors.count) * 0.04 }
        switch challenge.stage {
        case .center: return 0.2
        case .turn: return 1.0 / 3
        case .returnToCenter: return 2.0 / 3
        case .complete: return 1
        }
    }
    public mutating func reset() {
        vectors.removeAll(); eyeSamples.removeAll(); lastCollected = nil; challenge.reset()
    }
    public mutating func observe(vector: [Float]?, pose: OwnerPose?, faceCount: Int, at time: TimeInterval) {
        guard time.isFinite, faceCount == 1, let vector = vector.flatMap(OwnerTemplate.normalize),
              let pose, pose.isValid else { reset(); return }
        if let first = vectors.first, OwnerTemplate.similarity(first, vector) < 0.55 { reset(); return }
        if vectors.count < 5 {
            guard abs(pose.yaw) <= 0.14, (0.14...0.6).contains(pose.eyes) else { return }
            if let lastCollected, time - lastCollected < 0.25 { return }
            vectors.append(vector); eyeSamples.append(pose.eyes); lastCollected = time
        } else {
            _ = challenge.observe(pose, openEyes: eyeSamples.sorted()[eyeSamples.count / 2], at: time)
        }
    }
}

/// One enrolled person (or an alternate appearance of one), like Face ID's
/// alternate appearance but for several people who may see the screen.
public struct FaceProfile: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public let template: OwnerTemplate
    public init(id: UUID = UUID(), name: String, template: OwnerTemplate) {
        self.id = id; self.name = name; self.template = template
    }
}

/// Everything saved in the Keychain: every face allowed to clear protection.
public struct FaceProfiles: Codable, Equatable {
    public static let maximumCount = 5
    public static let defaultName = "Me"
    public var profiles: [FaceProfile]
    public init(_ profiles: [FaceProfile]) { self.profiles = profiles }

    public var isValid: Bool {
        (1...Self.maximumCount).contains(profiles.count) && profiles.allSatisfy { $0.template.isValid } &&
        Set(profiles.map(\.id)).count == profiles.count
    }

    /// The best-scoring profile among those that pass the per-template rule.
    public func match(_ vector: [Float]) -> FaceProfile? {
        profiles.filter { $0.template.matches(vector) }
            .max { $0.template.medianSimilarity(vector) < $1.template.medianSimilarity(vector) }
    }

    /// Highest cosine similarity to any saved sample of anyone. Used to call someone a
    /// stranger only when they are clearly unlike every saved face; matching a face
    /// still uses the stricter per-template rule above.
    public func bestSimilarity(_ vector: [Float]) -> Float {
        guard let v = OwnerTemplate.normalize(vector) else { return -1 }
        return profiles.flatMap(\.template.vectors).map { OwnerTemplate.similarity($0, v) }.max() ?? -1
    }

    /// Reads the current payload, or the single-template payload saved by QuietGlass 0.1.x.
    public static func decode(_ data: Data) -> FaceProfiles? {
        let decoder = JSONDecoder()
        if let value = try? decoder.decode(FaceProfiles.self, from: data), value.isValid { return value }
        if let legacy = try? decoder.decode(OwnerTemplate.self, from: data), legacy.isValid {
            return FaceProfiles([FaceProfile(name: defaultName, template: legacy)])
        }
        return nil
    }
}

extension OwnerTemplate {
    public func medianSimilarity(_ vector: [Float]) -> Float {
        let scores = vectors.map { Self.similarity($0, vector) }.sorted()
        return scores.isEmpty ? -1 : scores[scores.count / 2]
    }
}
