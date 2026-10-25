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
    static var saved: ProtectionMode { ProtectionMode(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .away }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .away: return L("Cover when I leave, unlock by keyboard")
        case .recognize: return L("Recognize my face automatically")
        }
    }
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
    private var attention = NearbyAttentionPolicy()
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
        if watching { return LF("Watching for you · covers after %d s away", Int(delay)) }
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
        Diagnostics.log(String(format: "unlocked after %.0f s", Date().timeIntervalSince(coveredAt ?? Date())))
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
            self.policy.start(at: self.clock())
            self.attention = NearbyAttentionPolicy()
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
            camera.configureRecognition(false)
            camera.configurePresence(true)
            camera.configureRate(2)
            camera.start()
            self.watching = true
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if self.policy.checkStalled(at: self.clock()) { self.becameAway(stalled: true) }
                }
            }
            timer.tolerance = 0.5
            self.stallTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func received(_ sample: NearbyFaceSample) {
        if failure != nil { failure = nil }
        let people = sample.people ?? sample.count
        recent.append((sample.capturedAt, sample.count, people, sample.motion ?? -1))
        if recent.count > 60 { recent.removeFirst(recent.count - 60) }
        if policy.observe(faceCount: people, motion: sample.motion, at: sample.capturedAt) { becameAway(stalled: false); return }
        observeOnlookers(sample)
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
            Diagnostics.log("posture reminder: \(issue.rawValue)")
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
    private func observeOnlookers(_ sample: NearbyFaceSample) {
        guard peekResponse != .off, let faces = sample.faces else { return }
        let threat = attention.observe(faces, ownerIndex: nil, at: sample.capturedAt)
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
        if value { logger.notice("Onlooker detected"); Diagnostics.log("onlooker detected") }
        onOnlooker?(value)
    }

    private func becameAway(stalled: Bool = true) {
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
        // Nobody needs the camera until you unlock by hand.
        stopCamera()
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
