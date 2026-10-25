import Foundation
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

    private let preferences: UserDefaults
    private let makeCamera: (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession
    private let clock: () -> TimeInterval
    private var policy: AwayPolicy
    private var camera: NearbyCameraSession?
    private var generation = 0
    private var pauseReasons: Set<NearbyPauseReason> = []
    private var stallTimer: Timer?

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
            camera.configureRate(2)
            camera.start()
            self.watching = true
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if self.policy.checkStalled(at: self.clock()) { self.becameAway() }
                }
            }
            timer.tolerance = 0.5
            self.stallTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func received(_ sample: NearbyFaceSample) {
        if failure != nil { failure = nil }
        if policy.observe(faceCount: sample.count, at: sample.capturedAt) { becameAway() }
    }

    private func becameAway() {
        setCovered(true)
        // Nobody needs the camera until you unlock by hand.
        stopCamera()
    }

    private func stopCamera() {
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
