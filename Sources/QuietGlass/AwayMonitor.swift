import AVFoundation
import Foundation
import OSLog
import ShieldCore

/// How camera protection behaves.
enum ProtectionMode: String, CaseIterable, Identifiable {
    /// Cover after you leave; you unlock by keyboard (Escape, Touch ID). No recognition.
    case away
    /// Nearby people + Recognize me: covers and clears automatically by face.
    case recognize
    static let preferenceKey = "protectionMode"
    /// One pipeline now judges leaving, identity, peeking and posture together.
    static var saved: ProtectionMode { .away }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .away: return L("Cover when I leave, unlock by keyboard")
        case .recognize: return L("Recognize my face automatically")
        }
    }
}

/// One analyzed frame, explained (debug window only).
struct AwayDebugFrame {
    enum Role: String { case you, saved, stranger, onlooker, other }
    struct Face: Identifiable {
        let id: Int
        let bounds: CGRect          // Vision coordinates: origin bottom-left, unmirrored
        let role: Role
        let yaw: Double?, pitch: Double?, roll: Double?
        let readable: Bool          // identity could be computed
        let similarity: Float?      // best similarity to any saved face
    }
    var time = Date()
    var faces: [Face] = []
    var strictFaces = 0, looseFaces = 0
    var motion: Double?
    var personCoverage: Double?
    var sinceFace: TimeInterval = 0
    var sinceMovement: TimeInterval = 0
    var onlooker = false
    var posture: [PostureIssue] = []
    var rate = 2.0
}

/// What to do when someone else is looking at your screen.
enum PeekResponse: String, CaseIterable, Identifiable {
    case off, alert, blur
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return L("Off")
        case .alert: return L("Alert me")
        case .blur: return L("Blur until they look away")
        }
    }
}

/// The lightest camera protection: face detection only, twice a second, and the
/// camera switches off entirely once the screen is covered.
@MainActor
final class AwayMonitor: ObservableObject {
    @Published private(set) var wantsMonitoring: Bool
    @Published private(set) var covered = false
    @Published private(set) var watching = false
    @Published private(set) var failure: NearbyCameraFailure?
    @Published var delay: TimeInterval {
        didSet { preferences.set(delay, forKey: "awayDelay"); policy.delay = delay }
    }
    /// Unlocking asks for Touch ID or the Mac password, so pressing Escape is not enough.
    @Published var unlockRequiresAuthentication: Bool {
        didSet { preferences.set(unlockRequiresAuthentication, forKey: "awayUnlockRequiresAuth") }
    }
    /// Within this many seconds of covering, any key unlocks without Touch ID (0 = never),
    /// like macOS's "require password after screen saver begins".
    @Published var graceSeconds: TimeInterval {
        didSet { preferences.set(graceSeconds, forKey: "awayGrace") }
    }
    /// Wall-clock time, so a Mac that slept while covered does not stay inside the grace period.
    private(set) var coveredAt: Date?
    var withinGrace: Bool {
        guard let coveredAt, graceSeconds > 0 else { return false }
        return Date().timeIntervalSince(coveredAt) < graceSeconds
    }
    var graceRemaining: TimeInterval? {
        guard let coveredAt, withinGrace else { return nil }
        return graceSeconds - Date().timeIntervalSince(coveredAt)
    }
    var onCoverage: ((Bool) -> Void)?
    /// Debug window: publishes an explained frame for every analysis.
    @Published var debugging = false
    @Published private(set) var debugFrame = AwayDebugFrame()
    @Published private(set) var debugEvents: [String] = []
    private var lastFaceSeen: TimeInterval = 0
    private var lastMovement: TimeInterval = 0
    /// The live session, for the debug preview.
    var previewSession: AVCaptureSession? { camera?.previewSession }
    /// Why the screen is covered.
    enum CoverReason { case away, stranger }
    @Published private(set) var coverReason = CoverReason.away
    /// Loads saved faces (AppModel reads the Keychain). When Recognize me is on, the
    /// same frames also answer "is it you?": someone else at the screen covers it.
    var loadFaces: (@MainActor (_ allowPrompt: Bool) async -> FaceProfiles?)?
    /// Recognize me is on but the saved faces couldn't be read quietly.
    @Published private(set) var facesNeedConfirmation = false
    @Published private(set) var recognizing = false
    /// Keep watching while covered and clear when a saved face looks at the screen.
    /// Costs the camera's power while you're away; off by default.
    @Published var unlockWhenRecognized: Bool {
        didSet { preferences.set(unlockWhenRecognized, forKey: "unlockWhenRecognized") }
    }
    private var faces: FaceProfiles?
    /// Below this best similarity to every saved sample, a readable face is a stranger.
    /// Between this and a match, it's uncertain (angle, light) and nothing happens.
    static let strangerSimilarity: Float = 0.25
    /// Share of the frame a segmented person must cover to count as present
    /// (someone seated measured 19–40 %).
    static let personThreshold = 0.05
    private var strangerStreak = 0
    private var ownerStreak = 0
    /// Someone else is facing the screen (Honor-style "someone is peeking").
    @Published private(set) var onlooker = false
    @Published var peekResponse: PeekResponse {
        didSet { preferences.set(peekResponse.rawValue, forKey: "peekResponse"); if peekResponse == .off { setOnlooker(false) } }
    }
    var onOnlooker: ((Bool) -> Void)?
    /// Gentle reminders when you lean in, slump or tilt your head for a while.
    @Published var postureReminders: Bool {
        didSet { preferences.set(postureReminders, forKey: "postureReminders"); posture.reset() }
    }
    @Published var postureHold: TimeInterval {
        didSet { preferences.set(postureHold, forKey: "postureHold"); posture.hold = postureHold }
    }
    @Published private(set) var postureCalibrated: Bool
    @Published private(set) var calibratingPosture = false
    var onPosture: ((PostureIssue) -> Void)?
    private var posture: PosturePolicy
    private var calibrationFaces: [CameraFace] = []
    private var attention = AwayMonitor.makeAttention()
    private var facingOriginal: Set<Int> = []
    private static func makeAttention() -> NearbyAttentionPolicy {
        var policy = NearbyAttentionPolicy()
        policy.maxGap = 1.2          // 2 analyses/s, with room for jitter
        policy.minimumHeight = 0.08  // a real person over your shoulder, not a poster
        return policy
    }
    private var onlookerClearedSince: TimeInterval?
    private var rate = 2.0

    private let preferences: UserDefaults
    private let makeCamera: (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession
    private let clock: () -> TimeInterval
    private var policy: AwayPolicy
    private var camera: NearbyCameraSession?
    private var generation = 0
    private var pauseReasons: Set<NearbyPauseReason> = []
    private var stallTimer: Timer?
    /// Recent (time, faces, people) samples, logged when the screen covers so a false
    /// trigger can be diagnosed from Console: subsystem local.clinton.QuietGlass, category Away.
    private var recent: [(TimeInterval, Int, Int, Double)] = []
    private let logger = Logger(subsystem: "local.clinton.QuietGlass", category: "Away")
    /// Seconds before covering when someone was last seen; shown in Settings.
    @Published private(set) var lastCoverNote: String?

    init(preferences: UserDefaults = .standard,
         makeCamera: @escaping (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession = { SharedFaceCamera(completion: $0) },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.preferences = preferences
        self.makeCamera = makeCamera
        self.clock = clock
        let delay = preferences.object(forKey: "awayDelay") as? Double ?? 5
        self.delay = delay
        policy = AwayPolicy(delay: delay)
        unlockRequiresAuthentication = preferences.object(forKey: "awayUnlockRequiresAuth") as? Bool ?? true
        graceSeconds = preferences.object(forKey: "awayGrace") as? Double ?? 60
        unlockWhenRecognized = preferences.bool(forKey: "unlockWhenRecognized")
        peekResponse = PeekResponse(rawValue: preferences.string(forKey: "peekResponse") ?? "") ?? .alert
        postureReminders = preferences.object(forKey: "postureReminders") as? Bool ?? true
        let hold = preferences.object(forKey: "postureHold") as? Double ?? 60
        postureHold = hold
        let saved = preferences.data(forKey: "postureBaseline").flatMap { try? JSONDecoder().decode(PostureBaseline.self, from: $0) }
        var posture = PosturePolicy(baseline: saved)
        posture.hold = hold
        self.posture = posture
        postureCalibrated = saved != nil
        wantsMonitoring = preferences.bool(forKey: "awayEnabled")
    }

    var status: String {
        if let failure { return failure.title }
        if covered { return L("Covered · Camera off until you unlock") }
        if !pauseReasons.isEmpty && wantsMonitoring { return L("Paused while your Mac is inactive") }
        if watching { return recognizing ? LF("Watching for you and your face · covers after %d s away", Int(delay)) : LF("Watching for you · covers after %d s away", Int(delay)) }
        return wantsMonitoring ? L("Starting camera…") : L("Off")
    }

    func setEnabled(_ value: Bool) {
        wantsMonitoring = value
        preferences.set(value, forKey: "awayEnabled")
        if value { begin() } else { stopCamera(); setCovered(false) }
    }

    /// Call after launch once the app is wired up.
    func restore() { if wantsMonitoring { begin() } }

    /// Clears the cover (after the caller's authentication) and watches again.
    func unlock() {
        guard covered else { return }
        note(String(format: "unlocked after %.0f s", Date().timeIntervalSince(coveredAt ?? Date())))
        setCovered(false)
        begin()
    }

    func suspend(for reason: NearbyPauseReason) {
        guard pauseReasons.insert(reason).inserted else { return }
        stopCamera()
        // Unlocking the screen or the login session authenticates; a covered screen
        // from before stays covered across sleep, which may not ask for a password.
    }

    func resume(after reason: NearbyPauseReason) {
        guard pauseReasons.remove(reason) != nil else { return }
        if covered && (reason == .screenLocked || reason == .inactiveSession) { setCovered(false) }
        if wantsMonitoring && !covered { begin() }
    }

    private func begin() {
        guard wantsMonitoring, pauseReasons.isEmpty, !covered else { return }
        stopCamera()
        generation += 1
        let token = generation
        failure = nil
        Task { [weak self] in
            guard await NearbyPeople.requestCameraAccess() else {
                self?.failure = .permission
                return
            }
            guard let self, self.generation == token, self.wantsMonitoring, !self.covered else { return }
            self.strangerStreak = 0; self.ownerStreak = 0
            self.policy.start(at: self.clock())
            self.attention = Self.makeAttention()
            self.rate = 2
            let camera = self.makeCamera { [weak self] result in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    switch result {
                    case .success(let sample): self.received(sample)
                    case .failure(let failure): self.failure = failure
                    }
                }
            }
            self.camera = camera
            camera.configureDevice(self.preferences.string(forKey: CameraSelection.preferenceKey))
            camera.configureRecognition(self.recognizing && self.faces != nil)
            camera.configurePresence(true)
            camera.configureRate(2)
            camera.start()
            self.watching = true
            // Saved faces load in the background; leaving, peeking and posture work meanwhile.
            self.loadSavedFaces(allowPrompt: false, token: token)
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token, !self.covered else { return }
                    if self.policy.checkStalled(at: self.clock()) { self.becameAway(stalled: true) }
                }
            }
            timer.tolerance = 0.5
            self.stallTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func loadSavedFaces(allowPrompt: Bool, token: Int) {
        guard let loadFaces else { return }
        Task { [weak self] in
            let loaded = await loadFaces(allowPrompt)
            guard let self, self.generation == token else { return }
            self.faces = loaded
            self.recognizing = loaded != nil
            self.facesNeedConfirmation = loaded == nil && self.preferences.bool(forKey: "ownerRecognitionEnabled")
            self.camera?.configureRecognition(loaded != nil)
        }
    }

    /// Settings: "Confirm with Touch ID" when the quiet read wasn't allowed.
    func confirmSavedFaces() { loadSavedFaces(allowPrompt: true, token: generation) }

    /// Re-reads saved faces (Recognize me toggled, a face added or deleted).
    func reloadFaces() {
        guard wantsMonitoring, !covered, pauseReasons.isEmpty else { return }
        begin()
    }

    /// Indices of faces that match a saved person.
    private func savedFaceIndices(_ sample: NearbyFaceSample) -> Set<Int> {
        guard let faces else { return [] }
        return Set(sample.identities.indices.filter { index in
            guard let identity = sample.identities[index], identity.pose.isValid else { return false }
            return faces.match(identity.vector) != nil
        })
    }

    private func largestFace(_ sample: NearbyFaceSample) -> Int? {
        sample.bounds.indices.max { sample.bounds[$0].width * sample.bounds[$0].height < sample.bounds[$1].width * sample.bounds[$1].height }
    }

    private func received(_ sample: NearbyFaceSample) {
        if failure != nil { failure = nil }
        let saved = savedFaceIndices(sample)
        let primary = largestFace(sample)
        if (sample.people ?? sample.count) > 0 || (sample.personCoverage ?? 0) >= Self.personThreshold { lastFaceSeen = sample.capturedAt }
        if let motion = sample.motion, motion >= policy.activityThreshold { lastMovement = sample.capturedAt }
        defer { if debugging { publishDebug(sample, saved: saved, primary: primary) } }
        if covered {
            // Only reached when "unlock when it sees me" keeps the camera on.
            if let primary, saved.contains(primary) { ownerStreak += 1 } else { ownerStreak = 0 }
            if ownerStreak >= 2 {
                note(String(format: "unlocked by a saved face after %.0f s", Date().timeIntervalSince(coveredAt ?? Date())))
                setCovered(false)
                begin()
            }
            return
        }
        // A person in the picture counts even when their face isn't detected.
        let segmented = (sample.personCoverage ?? 0) >= Self.personThreshold ? 1 : 0
        let people = max(sample.people ?? sample.count, segmented)
        recent.append((sample.capturedAt, sample.count, people, sample.personCoverage ?? sample.motion ?? -1))
        if recent.count > 60 { recent.removeFirst(recent.count - 60) }
        if policy.observe(faceCount: people, motion: sample.motion, at: sample.capturedAt) { becameAway(stalled: false); return }
        if recognizing, let primary, let faces {
            // Clearly someone else at the screen for ~2 s: cover. Uncertain readings
            // (your own face at an angle or in poor light) neither cover nor reset.
            if saved.contains(primary) { strangerStreak = 0 }
            else if sample.identities.indices.contains(primary), let identity = sample.identities[primary], identity.pose.isValid,
                    faces.bestSimilarity(identity.vector) < Self.strangerSimilarity {
                strangerStreak += 1
                if strangerStreak >= 4 { becameStranger(); return }
            }
        }
        let trusted = (preferences.object(forKey: "trustSavedFaces") as? Bool ?? true) ? saved.subtracting(primary.map { [$0] } ?? []) : []
        observeOnlookers(sample, ignoring: trusted)
        observePosture(sample)
    }

    /// Uses the largest face: yours, at the keyboard.
    private func observePosture(_ sample: NearbyFaceSample) {
        let face = sample.faces?.max { $0.bounds.height < $1.bounds.height }
        if calibratingPosture {
            if let face { calibrationFaces.append(face) }
            if calibrationFaces.count >= 6, let baseline = PosturePolicy.baseline(from: calibrationFaces) {
                posture = PosturePolicy(baseline: baseline); posture.hold = postureHold
                preferences.set(try? JSONEncoder().encode(baseline), forKey: "postureBaseline")
                postureCalibrated = true
                calibratingPosture = false
                logger.notice("Posture calibrated")
            }
            return
        }
        guard postureReminders, !onlooker else { return }
        let hadBaseline = posture.baseline != nil
        if let issue = posture.observe(face, at: sample.capturedAt) {
            logger.notice("Posture reminder: \(issue.rawValue, privacy: .public)")
            note("posture reminder: \(issue.rawValue)")
            onPosture?(issue)
        }
        if !hadBaseline, let learned = posture.baseline {
            preferences.set(try? JSONEncoder().encode(learned), forKey: "postureBaseline")
            postureCalibrated = true
        }
    }

    /// "This is how I sit": the next three seconds become the posture baseline.
    func calibratePosture() {
        calibrationFaces.removeAll()
        calibratingPosture = true
    }

    /// Reuses upstream's facing-screen policy: an extra face must face the screen for a
    /// moment; brief passers-by and people facing away are ignored.
    private func observeOnlookers(_ sample: NearbyFaceSample, ignoring trusted: Set<Int> = []) {
        guard peekResponse != .off, let all = sample.faces else { return }
        // Saved companions sitting beside you aren't onlookers.
        let kept = all.indices.filter { !trusted.contains($0) }
        let faces = kept.map { all[$0] }
        defer { facingOriginal = Set(attention.facingIndices.compactMap { kept.indices.contains($0) ? kept[$0] : nil }) }
        // Tell the policy which face is you (the largest), so after any gap your own
        // face is never mistaken for an onlooker.
        let mine = faces.indices.max { faces[$0].bounds.height < faces[$1].bounds.height }
        let threat = attention.observe(faces, ownerIndex: mine, at: sample.capturedAt)
        if threat { onlookerClearedSince = nil; setOnlooker(true) }
        else if onlooker {
            // Hold the alert briefly so it doesn't flicker as heads move.
            if onlookerClearedSince == nil { onlookerClearedSince = sample.capturedAt }
            if sample.capturedAt - (onlookerClearedSince ?? sample.capturedAt) >= 1.5 { setOnlooker(false) }
        }
        // Look more often while a second face is in view.
        let wanted = sample.count > 1 || onlooker ? 4.0 : 2.0
        if wanted != rate { rate = wanted; camera?.configureRate(wanted) }
    }

    private func setOnlooker(_ value: Bool) {
        guard onlooker != value else { return }
        onlooker = value
        if value { logger.notice("Onlooker detected") }
        note(value ? "onlooker detected" : "onlooker gone")
        onOnlooker?(value)
    }

    private func publishDebug(_ sample: NearbyFaceSample, saved: Set<Int>, primary: Int?) {
        var frame = AwayDebugFrame()
        frame.faces = (sample.faces ?? []).enumerated().map { index, face in
            let identity = sample.identities.indices.contains(index) ? sample.identities[index] : nil
            let readable = identity?.pose.isValid == true
            let role: AwayDebugFrame.Role
            if saved.contains(index) { role = index == primary ? .you : .saved }
            else if index == primary {
                let best = identity.flatMap { faces?.bestSimilarity($0.vector) } ?? 1
                role = recognizing && readable && best < Self.strangerSimilarity ? .stranger : .you
            }
            else if facingOriginal.contains(index) { role = .onlooker }
            else { role = .other }
            let similarity = readable ? identity.flatMap { id in faces?.bestSimilarity(id.vector) } : nil
            return .init(id: index, bounds: face.bounds, role: role, yaw: face.yaw, pitch: face.pitch, roll: face.roll, readable: readable, similarity: similarity)
        }
        frame.strictFaces = sample.count
        frame.looseFaces = sample.people ?? sample.count
        frame.motion = sample.motion
        frame.personCoverage = sample.personCoverage
        frame.sinceFace = max(0, sample.capturedAt - lastFaceSeen)
        frame.sinceMovement = max(0, sample.capturedAt - lastMovement)
        frame.onlooker = onlooker
        if let face = frame.faces.first(where: { $0.id == primary }), let source = sample.faces?[face.id] {
            frame.posture = Array(posture.issues(for: source)).sorted { $0.rawValue < $1.rawValue }
        }
        frame.rate = rate
        debugFrame = frame
    }

    /// Mirrors decisions into the debug window's event list.
    private func note(_ line: String) {
        Diagnostics.log(line)
        guard debugging else { return }
        let stamp = Date().formatted(date: .omitted, time: .standard)
        debugEvents.insert("\(stamp)  \(line)", at: 0)
        if debugEvents.count > 30 { debugEvents.removeLast(debugEvents.count - 30) }
    }

    private func becameStranger() {
        note("stranger cover: the face at the screen isn't saved")
        coverReason = .stranger
        setCovered(true)
        if !(unlockWhenRecognized && recognizing) { stopCamera() } else { ownerStreak = 0 }
    }

    private func becameAway(stalled: Bool = true) {
        coverReason = .away
        let now = clock()
        let lastSeen = recent.last(where: { $0.2 > 0 }).map { now - $0.0 }
        let window = recent.filter { now - $0.0 <= max(delay, 6) + 1 }
        let summary = window.map { $0.3 < 0 ? "\($0.1)/\($0.2)" : String(format: "%d/%d/%.0f%%", $0.1, $0.2, $0.3 * 100) }.joined(separator: " ")
        let line = "away cover: \(stalled ? "camera stalled" : "nobody seen"); last person \(lastSeen.map { String(format: "%.1f s", $0) } ?? "never") ago; delay \(Int(delay)) s; faces/loose/motion: \(summary)"
        logger.notice("\(line, privacy: .public)")
        Diagnostics.log(line)
        lastCoverNote = stalled ? L("Last cover: the camera stopped sending frames")
            : LF("Last cover: nobody seen for %d s", Int((lastSeen ?? delay).rounded()))
        recent.removeAll()
        setCovered(true)
        // Nobody needs the camera until you unlock by hand — unless it should
        // recognize you coming back.
        if unlockWhenRecognized && recognizing { ownerStreak = 0; camera?.configureRate(2) } else { stopCamera() }
    }

    private func stopCamera() {
        setOnlooker(false)
        generation += 1
        camera?.stop(); camera = nil
        stallTimer?.invalidate(); stallTimer = nil
        watching = false
    }

    private func setCovered(_ value: Bool) {
        guard covered != value else { return }
        coveredAt = value ? Date() : nil
        covered = value
        onCoverage?(value)
    }
}
