//  Created by Clinton Imaro on 20/09/2026.

import AVFoundation
import Vision
import Combine
import ShieldCore
import OSLog

enum NearbyResponse: String, CaseIterable, Identifiable {
    case warning, blur
    var id: String { rawValue }
    var title: String { self == .warning ? "Warn me" : "Blur automatically" }
}

enum NearbyCameraFailure: Error, Equatable {
    case permission, noCamera, configuration, interrupted, disconnected, stalled, analysis, recognition, ownerAccess
    case screenPermission, escapeUnavailable

    var title: String {
        switch self {
        case .permission: return "Camera access is off"
        case .noCamera: return "No camera available"
        case .interrupted: return "Camera interrupted"
        case .disconnected: return "Camera disconnected"
        case .stalled: return "Camera stopped responding"
        case .analysis: return "Face detection unavailable"
        case .configuration: return "Camera unavailable"
        case .recognition: return "Owner recognition unavailable"
        case .ownerAccess: return "Unlock your saved face to continue"
        case .screenPermission: return "Screen Recording access is off"
        case .escapeUnavailable: return "Escape shortcut is unavailable"
        }
    }
}

enum NearbyCameraStatus: Equatable {
    case off, paused, requesting, starting, watching(Int), unavailable(NearbyCameraFailure)
}

enum NearbyPauseReason: Hashable {
    case systemSleep, displaySleep, inactiveSession, protectionTest, ownerEnrollment, screenLocked, screensaver
    /// macOS normally authenticates the user when these end, so saved faces stay
    /// loaded (no extra Touch ID prompt) and a matching face clears quickly afterwards.
    var endsWithSystemUnlock: Bool {
        switch self {
        case .systemSleep, .displaySleep, .inactiveSession, .screenLocked, .screensaver: return true
        case .protectionTest, .ownerEnrollment: return false
        }
    }
}

struct NearbyFaceSample {
    let count: Int
    let capturedAt: TimeInterval
    var vector: [Float]? = nil
    var pose: OwnerPose? = nil
    var bounds: [CGRect] = []
    var faces: [CameraFace]? = nil
    var identities: [CameraIdentity?] = []
    /// "Is someone there", when presence detection is on: faces at a lower confidence.
    /// (Vision's upper-body detector found nobody at laptop distance in testing.)
    var people: Int? = nil
    /// Fraction of a 40×30 brightness grid that changed since the previous analyzed
    /// frame (presence mode). A person whose face isn't detected still moves.
    var motion: Double? = nil
    /// Share of the frame covered by a person (Vision person segmentation), measured
    /// only when no face was found: you sitting crooked or face-down still count.
    var personCoverage: Double? = nil
}

struct CameraIdentity {
    let vector: [Float]
    let pose: OwnerPose
}

enum NearbyDetection: String, CaseIterable, Identifiable {
    case facingScreen, anyFace
    var id: String { rawValue }
    var title: String { self == .facingScreen ? "Facing screen" : "Any extra face" }
}

protocol NearbyCameraSession: AnyObject {
    var previewSession: AVCaptureSession? { get }
    func start()
    func stop()
    func configureRecognition(_ enabled: Bool)
    /// Also detect upper bodies and low-confidence faces, for "is anyone there".
    func configurePresence(_ enabled: Bool)
    func configureDevice(_ id: String?)
    /// Requested face analyses per second. Shared cameras run at the fastest client's rate.
    func configureRate(_ analysesPerSecond: Double)
}

extension NearbyCameraSession {
    var previewSession: AVCaptureSession? { nil }
    func configureRecognition(_ enabled: Bool) {}
    func configurePresence(_ enabled: Bool) {}
    func configureDevice(_ id: String?) {}
    func configureRate(_ analysesPerSecond: Double) {}
}

/// Analysis cadence. Camera cost is dominated by the sensor frame rate (cameracaptured
/// uses ~21% CPU at 30 fps vs ~10% at 15 fps on an M4 MacBook Air), so the sensor runs
/// at its slowest supported rate and frames are skipped before any Vision work.
enum AnalysisRate {
    static let steady = 3.0       // one face, nothing changing
    static let responsive = 10.0  // covered with a face in view, extra faces, verification
    static let headTracking = 5.0 // CameraTracking resets after 0.4 s gaps
}

@MainActor
final class NearbyPeople: ObservableObject {
    private enum OwnerNoticeState {
        case checking, matching, unmatched, unreadable, noFace, additionalFaces
    }
    // The switch represents the user's choice, not temporary camera availability.
    @Published private(set) var detection: NearbyDetection
    @Published private(set) var wantsMonitoring: Bool
    @Published private(set) var enabled = false
    @Published private(set) var requesting = false
    @Published private(set) var covered = false
    @Published private(set) var alertActive = false
    @Published private(set) var status: NearbyCameraStatus = .off
    @Published private(set) var response: NearbyResponse
    @Published private(set) var warningSoundEnabled: Bool
    @Published private(set) var warningDelay: TimeInterval
    @Published private(set) var warningSecondsRemaining: Int?
    @Published private(set) var pauseSecondsRemaining: Int?
    @Published private(set) var cameras: [CameraChoice] = []
    @Published private(set) var selectedCameraID: String
    let owner: OwnerRecognition
    var onCoverage: ((Bool) -> Void)?
    var onMonitoring: ((Bool) -> Void)?
    var prepareMonitoring: (() -> NearbyCameraFailure?)?
    private let preferences: UserDefaults
    private let cameraAccess: () async -> Bool
    private let makeCamera: (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession
    private let clock: () -> TimeInterval
    private let wallClock: () -> Date
    private let usesWatchdog: Bool
    private var worker: NearbyCameraSession?
    private var presence = NearbyPresence()
    private var attention = NearbyAttentionPolicy()
    private var generation = 0
    private var lastFrame: TimeInterval = 0
    private var lastAcceptedFrame: TimeInterval?
    private var warmingCapture = false
    private var watchdog: Timer?
    private var warningTimer: Timer?
    private var pauseTimer: Timer?
    private var pauseUntil: Date?
    private var pauseUptimeUntil: TimeInterval?
    private var immediateBlur = false
    private var warningPolicy = NearbyWarningPolicy()
    private var ownerObservation: AnyCancellable?
    private var ownerRequired = false
    private var ownerPresence = OwnerPresence(turnPositive: Bool.random())
    private var lastMatchedBounds: CGRect?
    @Published private(set) var ownerPrompt = "Look at the camera"
    @Published private var ownerNoticeState: OwnerNoticeState = .checking
    private var ownerNoticeCandidate: OwnerNoticeState?
    private var ownerNoticeCandidateSince: TimeInterval = 0
    private var pauseReasons: Set<NearbyPauseReason> = []
    private var analysisRate = AnalysisRate.responsive
    /// Saved faces other than the one at the screen do not count as onlookers.
    @Published private(set) var trustSavedFaces: Bool
    /// Ask for a small head turn before clearing (a modest obstacle to photos).
    @Published private(set) var requireMovementCheck: Bool
    private var quickClearDeadline: TimeInterval?
    private var startVerified = false
    private var cameraObservers: [NSObjectProtocol] = []

    init(preferences: UserDefaults = .standard,
         cameraAccess: @escaping () async -> Bool = NearbyPeople.requestCameraAccess,
         makeCamera: @escaping (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession = { SharedFaceCamera(completion: $0) },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallClock: @escaping () -> Date = Date.init,
         usesWatchdog: Bool = true, owner: OwnerRecognition? = nil) {
        self.preferences = preferences
        self.cameraAccess = cameraAccess
        self.makeCamera = makeCamera
        self.clock = clock
        self.wallClock = wallClock
        self.usesWatchdog = usesWatchdog
        self.owner = owner ?? OwnerRecognition(preferences: preferences)
        selectedCameraID = preferences.string(forKey: CameraSelection.preferenceKey) ?? ""
        detection = NearbyDetection(rawValue: preferences.string(forKey: "nearbyDetection") ?? "") ?? .facingScreen
        wantsMonitoring = preferences.bool(forKey: "nearbyEnabled")
        response = NearbyResponse(rawValue: preferences.string(forKey: "nearbyResponse") ?? "") ?? .blur
        warningSoundEnabled = preferences.object(forKey: "nearbyWarningSound") as? Bool ?? true
        trustSavedFaces = preferences.object(forKey: "trustSavedFaces") as? Bool ?? true
        requireMovementCheck = preferences.object(forKey: "requireMovementCheck") as? Bool ?? true
        warningDelay = NearbyWarningPolicy.normalizedDelay(
            preferences.object(forKey: "nearbyWarningDelay") as? Double ?? NearbyWarningPolicy.defaultDelay)
        if wantsMonitoring, let until = preferences.object(forKey: "nearbyPauseUntil") as? Date, until > wallClock() {
            pauseUntil = until
            pauseSecondsRemaining = min(300, Int(ceil(until.timeIntervalSince(wallClock()))))
            pauseUptimeUntil = clock() + Double(pauseSecondsRemaining ?? 0)
        }
        ownerObservation = self.owner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        refreshCameras()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            cameraObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshCameras() }
            })
        }
    }

    func refreshCameras() {
        cameras = CameraSelection.devices().map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func selectCamera(_ id: String) {
        guard id != selectedCameraID else { return }
        selectedCameraID = id
        preferences.set(id, forKey: CameraSelection.preferenceKey)
        if wantsMonitoring && !temporarilyPaused { begin() }
    }

    nonisolated static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    var canRetry: Bool {
        if case .unavailable = status { return true }
        return false
    }

    var needsCameraPermission: Bool { status == .unavailable(.permission) }
    var needsAttention: Bool { alertActive || canRetry }
    var requiresBlur: Bool { response == .blur || warningPolicy.escalated || immediateBlur }
    var temporarilyPaused: Bool { pauseUntil != nil }
    var noticeTitle: String {
        if case .unavailable(let failure) = status { return failure.title }
        if ownerRequired { return ownerNoticeTitle }
        return "Additional face detected"
    }
    var noticeDetail: String {
        if covered { return "Blur stays on · Esc to stop" }
        if let remaining = warningSecondsRemaining {
            let minutes = remaining / 60
            let seconds = String(format: "%02d", remaining % 60)
            return LF("Blurs in %d:%@ · Esc to stop", minutes, seconds)
        }
        if canRetry { return "Open Settings to retry" }
        return "Look around · Esc to dismiss"
    }

    private var ownerNoticeTitle: String {
        switch ownerNoticeState {
        case .checking: return "Checking your face…"
        case .matching: return alertActive ? ownerPrompt : "Owner verified"
        case .unmatched: return "Owner not verified"
        case .unreadable: return "Face the camera in good light"
        case .noFace: return "No face in view"
        case .additionalFaces: return "Additional face detected"
        }
    }

    var message: String {
        switch status {
        case .off: return "Off"
        case .paused:
            if let seconds = pauseSecondsRemaining { return LF("Paused · Resumes in %d:%02d", seconds / 60, seconds % 60) }
            return pauseReasons.contains(.protectionTest) ? "Paused during protection check" : "Paused while your Mac is inactive"
        case .requesting: return ownerRequired ? "Unlocking your saved face…" : "Waiting for camera access…"
        case .starting: return covered ? "Restarting camera · Blur stays on" : "Starting camera…"
        case .unavailable(let failure): return L(failure.title) + L(covered ? " · Blur stays on" : " · Monitoring stopped")
        case .watching(let count):
            if ownerRequired {
                return ownerNoticeTitle
            }
            if count == 0 { return covered ? "No face in view · Blur stays on" : "No face in view · Detection is limited" }
            if alertActive { return count > 1 ? "Additional face detected" : "Waiting for a steady single face…" }
            return count > 1 ? "Checking nearby head directions…" : "One face in view"
        }
    }

    func setDetection(_ value: NearbyDetection) {
        detection = value
        preferences.set(value.rawValue, forKey: "nearbyDetection")
        attention = NearbyAttentionPolicy()
        presence.interrupt()
    }

    func setResponse(_ value: NearbyResponse) {
        guard response != value else { return }
        response = value
        preferences.set(value.rawValue, forKey: "nearbyResponse")
        resetWarningDeadline()
        updateProtection()
    }

    func setWarningDelay(_ seconds: TimeInterval) {
        let value = NearbyWarningPolicy.normalizedDelay(seconds)
        guard value != warningDelay else { return }
        warningDelay = value
        preferences.set(value, forKey: "nearbyWarningDelay")
        updateProtection()
    }

    func setTrustSavedFaces(_ value: Bool) {
        guard trustSavedFaces != value else { return }
        trustSavedFaces = value
        preferences.set(value, forKey: "trustSavedFaces")
        attention = NearbyAttentionPolicy()
    }

    func setRequireMovementCheck(_ value: Bool) {
        guard requireMovementCheck != value else { return }
        requireMovementCheck = value
        preferences.set(value, forKey: "requireMovementCheck")
        if value { ownerPresence.allowQuickClear(until: quickClearDeadline ?? -.infinity) } else { armQuickClear() }
    }

    /// Re-applied whenever the owner policy is recreated.
    private func armQuickClear() {
        if !requireMovementCheck { ownerPresence.allowQuickClear(until: .infinity) }
        else if let deadline = quickClearDeadline { ownerPresence.allowQuickClear(until: deadline) }
    }

    func setWarningSoundEnabled(_ value: Bool) {
        guard warningSoundEnabled != value else { return }
        warningSoundEnabled = value
        preferences.set(value, forKey: "nearbyWarningSound")
    }

    func setEnabled(_ value: Bool) {
        guard value else { stop(); return }
        cancelTimedPause()
        wantsMonitoring = true
        preferences.set(true, forKey: "nearbyEnabled")
        guard !enabled, !requesting else { return }
        begin()
    }

    func retry() {
        guard wantsMonitoring, canRetry else { return }
        begin()
    }

    // Called after the app has connected protection and shortcut callbacks.
    func restore() {
        guard wantsMonitoring, !enabled, !requesting, !canRetry else { return }
        if pauseUntil != nil { updatePauseDeadline(); return }
        begin()
    }

    func blurNow() {
        guard wantsMonitoring, needsAttention, !temporarilyPaused else { return }
        immediateBlur = true
        alertActive = true
        if !ownerRequired { presence.requireClear() }
        updateProtection()
    }

    func pauseForFiveMinutes() {
        guard wantsMonitoring else { return }
        stopSession()
        pauseUntil = wallClock().addingTimeInterval(300)
        pauseUptimeUntil = clock() + 300
        preferences.set(pauseUntil, forKey: "nearbyPauseUntil")
        status = .paused
        updatePauseDeadline()
    }

    func resumeNow() {
        guard wantsMonitoring, temporarilyPaused else { return }
        cancelTimedPause()
        begin()
    }

    func updatePauseDeadline() {
        guard let pauseUntil else { return }
        // Wall time includes sleep; uptime prevents a backward clock change
        // from extending a five-minute pause indefinitely.
        let seconds = min(pauseUntil.timeIntervalSince(wallClock()), (pauseUptimeUntil ?? clock()) - clock())
        let remaining = min(300, max(0, Int(ceil(seconds))))
        if remaining == 0 { cancelTimedPause(); if wantsMonitoring { begin() }; return }
        if pauseSecondsRemaining != remaining { pauseSecondsRemaining = remaining }
        status = .paused
        guard pauseTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePauseDeadline() }
        }
        pauseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelTimedPause() {
        pauseUntil = nil
        pauseUptimeUntil = nil
        pauseSecondsRemaining = nil
        pauseTimer?.invalidate(); pauseTimer = nil
        preferences.removeObject(forKey: "nearbyPauseUntil")
    }

    func suspend(for reason: NearbyPauseReason) {
        guard pauseReasons.insert(reason).inserted else { return }
        stopSession(keepFaces: reason.endsWithSystemUnlock)
        if wantsMonitoring { status = .paused }
    }

    func resume(after reason: NearbyPauseReason) {
        guard pauseReasons.remove(reason) != nil else { return }
        if reason.endsWithSystemUnlock { quickClearDeadline = clock() + 20 }
        // Unlocking the screen or returning to this login session always authenticates.
        if reason == .screenLocked || reason == .inactiveSession { startVerified = true }
        restore()
    }

    private func begin() {
        guard !temporarilyPaused else { updatePauseDeadline(); return }
        guard pauseReasons.isEmpty else { status = .paused; return }
        guard !owner.busy, !owner.enrolling else { return }
        if let failure = prepareMonitoring?() {
            failed(failure)
            return
        }
        generation += 1
        let token = generation
        worker?.stop(); worker = nil
        watchdog?.invalidate(); watchdog = nil
        presence.interrupt()
        attention = NearbyAttentionPolicy()
        ownerRequired = owner.enabled
        ownerPresence = OwnerPresence(turnPositive: Bool.random())
        armQuickClear()
        resetOwnerNotice()
        ownerPrompt = ownerPresence.challenge.prompt
        if ownerRequired {
            enabled = true // Remain armed/turn-off-able if authentication fails.
            if startVerified && owner.profiles != nil { ownerPresence.startVerified() }
            else { alertActive = true }
        }
        startVerified = false
        requesting = true
        status = .requesting
        // Owner mode starts protected, including while authentication is pending.
        updateProtection()
        Task { [weak self, cameraAccess] in
            guard let self, self.generation == token else { return }
            if self.ownerRequired {
                do { try await self.owner.prepareForMonitoring() }
                catch {
                    guard self.generation == token else { return }
                    self.failed(.ownerAccess)
                    return
                }
            }
            let allowed = await cameraAccess()
            guard self.generation == token else { return }
            self.requesting = false
            guard allowed else { self.failed(.permission); return }
            self.enabled = true
            self.lastFrame = self.clock()
            self.lastAcceptedFrame = nil
            self.status = .starting
            self.updateProtection()
            let worker = self.makeCamera { [weak self] result in
                Task { @MainActor in
                    guard let self, self.generation == token, self.enabled else { return }
                    switch result {
                    case .success(let sample): self.received(sample)
                    case .failure(let failure): self.failed(failure)
                    }
                }
            }
            self.worker = worker
            self.analysisRate = AnalysisRate.responsive
            worker.configureDevice(self.selectedCameraID)
            worker.configureRecognition(self.ownerRequired)
            worker.configureRate(self.analysisRate)
            worker.start()
            if self.usesWatchdog {
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.checkCameraHealth() }
                }
                self.watchdog = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    func checkCameraHealth() {
        guard enabled, worker != nil, clock() - lastFrame > 4 else { return }
        failed(.stalled)
    }

    private func received(_ sample: NearbyFaceSample) {
        let now = clock()
        guard sample.count >= 0, sample.capturedAt.isFinite, sample.capturedAt >= lastFrame,
              sample.capturedAt <= now, now - sample.capturedAt <= 1 else { return }
        if let lastAcceptedFrame, sample.capturedAt <= lastAcceptedFrame { return }
        if let lastAcceptedFrame, sample.capturedAt - lastAcceptedFrame > 0.6 {
            ownerNoticeCandidate = nil
        }
        lastAcceptedFrame = sample.capturedAt
        lastFrame = sample.capturedAt
        let ownerIndices = sample.identities.indices.filter { index in
            guard let identity = sample.identities[index] else { return false }
            return owner.match(identity.vector) != nil && identity.pose.isValid
        }
        // Upstream treats exactly one matching face as the owner. With several saved
        // people trusted, the largest matching face is the owner and the other saved
        // faces are companions, invisible to the onlooker checks.
        let trusting = ownerRequired && trustSavedFaces
        func area(_ index: Int) -> CGFloat {
            sample.bounds.indices.contains(index) ? sample.bounds[index].width * sample.bounds[index].height : 0
        }
        let ownerIndex = trusting ? ownerIndices.max { area($0) < area($1) } : ownerIndices.count == 1 ? ownerIndices.first : nil
        let companions = trusting ? Set(ownerIndices).subtracting(ownerIndex.map { [$0] } ?? []) : []
        let facingThreat: Bool
        if let faces = sample.faces {
            let kept = faces.indices.filter { !companions.contains($0) }
            let keptOwner = ownerIndex.flatMap { kept.firstIndex(of: $0) }
            facingThreat = attention.observe(kept.map { faces[$0] }, ownerIndex: ownerRequired ? keptOwner : nil, at: sample.capturedAt)
        } else { facingThreat = sample.count - companions.count > 1 }
        let extraThreat = detection == .anyFace ? sample.count - companions.count > 1 : facingThreat
        let detected: Bool
        if ownerRequired {
            let identity = ownerIndex.flatMap { sample.identities[$0] }
            let vector = identity?.vector ?? (sample.count == 1 ? sample.vector : nil)
            let pose = identity?.pose ?? (sample.count == 1 ? sample.pose : nil)
            let matchedFace = vector.flatMap { owner.match($0) }
            let ownerMatches = !extraThreat && matchedFace != nil && pose?.isValid == true
            let ownerBounds = ownerIndex.flatMap { sample.bounds.indices.contains($0) ? sample.bounds[$0] : nil } ?? (sample.count == 1 ? sample.bounds.first : nil)
            let lostLandmarks = sample.count == 1 && (vector == nil || pose?.isValid != true) &&
                OwnerPresence.isContinuousFace(lastMatchedBounds, ownerBounds)
            detected = ownerPresence.observe(matches: ownerMatches, pose: pose, openEyes: matchedFace?.template.openEyes ?? 0.3,
                                             at: sample.capturedAt, continuousFaceWithMissingLandmarks: lostLandmarks)
            if ownerMatches { lastMatchedBounds = ownerBounds }
            else if !lostLandmarks { lastMatchedBounds = nil }
            if detected && !alertActive && !ownerPresence.recoveringLandmarks { ownerPresence.interrupt(turnPositive: Bool.random()); armQuickClear() }
            let prompt = ownerPresence.recoveringLandmarks ? "Face the camera again" : ownerPresence.challenge.prompt
            if ownerPrompt != prompt { ownerPrompt = prompt }
            let observation: OwnerNoticeState
            if extraThreat { observation = .additionalFaces }
            else if sample.count == 0 { observation = .noFace }
            else if vector == nil || pose?.isValid != true { observation = .unreadable }
            else { observation = ownerMatches ? .matching : .unmatched }
            updateOwnerNotice(observation, at: sample.capturedAt)
        } else {
            // Preserve the existing steady-clear and no-face behavior.
            detected = presence.observe(faceCount: sample.count == 0 ? 0 : extraThreat ? 2 : 1, at: sample.capturedAt)
        }
        if detected != alertActive { alertActive = detected }
        let next = NearbyCameraStatus.watching(sample.count)
        if status != next { status = next }
        updateProtection()
        updateAnalysisRate(faceCount: sample.count)
    }

    /// Steady 3/s while one face is settled (clear) or nobody is in view (covered);
    /// 10/s while verifying a returning face or tracking additional faces, so
    /// prompts and the movement check stay responsive. All policies are time-based.
    private func updateAnalysisRate(faceCount: Int) {
        let settling = faceCount > 1 || (alertActive && faceCount > 0) || (ownerRequired && ownerNoticeCandidate != nil)
        let rate = settling ? AnalysisRate.responsive : AnalysisRate.steady
        guard rate != analysisRate else { return }
        analysisRate = rate
        worker?.configureRate(rate)
    }

    private func resetOwnerNotice() {
        ownerNoticeState = .checking
        ownerNoticeCandidate = nil
        lastMatchedBounds = nil
    }

    // Stabilize presentation only. Every fresh sample still reaches the owner
    // policy above, so a delayed label cannot defer blur or authorize clearing.
    private func updateOwnerNotice(_ observation: OwnerNoticeState, at time: TimeInterval) {
        guard observation != ownerNoticeState else { ownerNoticeCandidate = nil; return }
        if ownerNoticeCandidate != observation {
            ownerNoticeCandidate = observation
            ownerNoticeCandidateSince = time
        }
        guard time - ownerNoticeCandidateSince >= 0.3 else { return }
        ownerNoticeState = observation
        ownerNoticeCandidate = nil
    }

    private func failed(_ failure: NearbyCameraFailure) {
        generation += 1
        worker?.stop(); worker = nil
        watchdog?.invalidate(); watchdog = nil
        requesting = false
        presence.interrupt()
        if ownerRequired {
            ownerPresence.interrupt(turnPositive: Bool.random())
            armQuickClear()
            resetOwnerNotice()
            alertActive = true
            owner.endMonitoring()
        }
        status = .unavailable(failure)
        updateProtection()
    }

    private func updateProtection() {
        if !alertActive && !canRetry { immediateBlur = false }
        updateWarningDeadline()
        if warningPolicy.escalated && !alertActive {
            alertActive = true
            if !ownerRequired { presence.requireClear() }
        }
        let nextCovered = (response == .blur && alertActive) || warningPolicy.escalated || immediateBlur
        let nextWarming = nextCovered || (response == .blur && enabled && !canRetry)
        if nextWarming != warmingCapture {
            warmingCapture = nextWarming
            onMonitoring?(nextWarming)
        }
        if nextCovered != covered {
            covered = nextCovered
            onCoverage?(nextCovered)
        }
    }

    func checkWarningDeadline() {
        updateProtection()
    }

    private func updateWarningDeadline() {
        warningPolicy.update(active: response == .warning && needsAttention, delay: warningDelay, at: clock())
        if warningSecondsRemaining != warningPolicy.secondsRemaining {
            warningSecondsRemaining = warningPolicy.secondsRemaining
        }
        guard let remaining = warningSecondsRemaining, remaining > 0 else {
            warningTimer?.invalidate(); warningTimer = nil
            return
        }
        guard warningTimer == nil else { return }
        // Camera callbacks can stop during a failure. The deadline and countdown
        // therefore have their own clock and do not depend on another frame.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkWarningDeadline() }
        }
        warningTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func resetWarningDeadline() {
        warningTimer?.invalidate(); warningTimer = nil
        warningPolicy = NearbyWarningPolicy()
        warningSecondsRemaining = nil
    }

    func stop(file: StaticString = #fileID, line: UInt = #line) {
        if wantsMonitoring {
            Logger(subsystem: "local.clinton.QuietGlass", category: "NearbyPeople")
                .notice("Detection turned off at \(String(describing: file), privacy: .public):\(line)")
        }
        wantsMonitoring = false
        preferences.set(false, forKey: "nearbyEnabled")
        cancelTimedPause()
        stopSession()
    }

    func shutdown() {
        pauseTimer?.invalidate(); pauseTimer = nil
        for observer in cameraObservers { NotificationCenter.default.removeObserver(observer) }
        cameraObservers.removeAll()
        stopSession()
    }

    private func stopSession(keepFaces: Bool = false) {
        generation += 1
        worker?.stop(); worker = nil
        watchdog?.invalidate(); watchdog = nil
        resetWarningDeadline()
        requesting = false
        enabled = false
        covered = false
        alertActive = false
        immediateBlur = false
        warmingCapture = false
        presence = NearbyPresence()
        attention = NearbyAttentionPolicy()
        if !keepFaces { owner.endMonitoring() }
        ownerRequired = false
        resetOwnerNotice()
        ownerPresence = OwnerPresence(turnPositive: Bool.random())
        lastAcceptedFrame = nil
        status = .off
        onCoverage?(false)
        onMonitoring?(false)
    }
}

final class FaceCamera: NSObject, NearbyCameraSession, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let captureQueue = DispatchQueue(label: "local.clinton.QuietGlass.camera", qos: .userInitiated)
    private let queue = FaceCamera.captureQueue
    private let session = AVCaptureSession()
    var previewSession: AVCaptureSession? { session }
    private let completion: (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void
    private var lastScan: TimeInterval = 0
    private var interval: TimeInterval = 1 / AnalysisRate.responsive
    private weak var device: AVCaptureDevice?
    private var stopped = false
    private var observers: [NSObjectProtocol] = []
    private var analysisFailures = 0
    private var recognition = false
    private var presence = false
    private var previousGrid: [UInt8]?
    private lazy var segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private var recognizer: OwnerFaceModel?
    private var deviceID: String?

    init(recognition: Bool = false, completion: @escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) {
        self.recognition = recognition; self.completion = completion
    }

    func configureRecognition(_ enabled: Bool) {
        queue.async { [self] in
            guard !stopped else { return }
            recognition = enabled
            if enabled && recognizer == nil {
                do { recognizer = try OwnerFaceModel() }
                catch { completion(.failure(.recognition)) }
            } else if !enabled { recognizer = nil }
        }
    }
    func configureDevice(_ id: String?) { queue.async { [self] in deviceID = id } }
    func configurePresence(_ enabled: Bool) { queue.async { [self] in presence = enabled } }
    func configureRate(_ analysesPerSecond: Double) {
        queue.async { [self] in
            guard analysesPerSecond > 0 else { return }
            interval = 1 / analysesPerSecond
            if let device { limitFrameRate(device) }
        }
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            do {
                if recognition && recognizer == nil {
                    do { recognizer = try OwnerFaceModel() }
                    catch { throw NearbyCameraFailure.recognition }
                }
                guard let device = CameraSelection.device(id: deviceID) else { throw NearbyCameraFailure.noCamera }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                // The sensor's native biplanar format: Vision and Core Image read it
                // directly, avoiding a BGRA conversion of every captured frame.
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                output.setSampleBufferDelegate(self, queue: queue)
                session.beginConfiguration()
                if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw NearbyCameraFailure.configuration
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()
                // Only the on-screen preview is mirrored. Pose directions must
                // always refer to the person's own left and right.
                if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                self.device = device
                observe(AVCaptureSession.runtimeErrorNotification, object: session, failure: .configuration)
                observe(AVCaptureSession.wasInterruptedNotification, object: session, failure: .interrupted)
                observe(AVCaptureDevice.wasDisconnectedNotification, object: device, failure: .disconnected)
                session.startRunning()
                if !session.isRunning { completion(.failure(.configuration)) }
                // The session preset resets frame durations on start; limit afterwards.
                limitFrameRate(device)
            } catch { completion(.failure(error as? NearbyCameraFailure ?? .configuration)) }
        }
    }

    private func personCoverage(in buffer: CVPixelBuffer) -> Double? {
        guard (try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([segmentation])) != nil,
              let mask = segmentation.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(mask, .readOnly); defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask), stride = CVPixelBufferGetBytesPerRow(mask)
        var on = 0, total = 0
        for y in Swift.stride(from: 0, to: height, by: 4) {
            for x in Swift.stride(from: 0, to: width, by: 4) { total += 1; if base[y * stride + x] > 127 { on += 1 } }
        }
        return total > 0 ? Double(on) / Double(total) : nil
    }

    /// Samples 1,200 points of the luma plane (no conversion, ~microseconds) and returns
    /// the share whose brightness moved by more than 12 levels since the last call.
    private func motion(in buffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var grid = [UInt8](repeating: 0, count: 1200)
        for y in 0..<30 { for x in 0..<40 { grid[y * 40 + x] = base[(y * height / 30 + height / 60) * stride + x * width / 40 + width / 80] } }
        defer { previousGrid = grid }
        guard let previous = previousGrid else { return nil }
        var changed = 0
        for i in 0..<1200 where abs(Int(grid[i]) - Int(previous[i])) > 12 { changed += 1 }
        return Double(changed) / 1200
    }

    /// Runs the sensor at the slowest supported rate that still delivers the requested
    /// analyses. Upstream asked for 10 fps, which the built-in camera (15-30 fps) rejects,
    /// so it captured at 30 fps.
    private func limitFrameRate(_ device: AVCaptureDevice) {
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return }
        let fps = min(range.maxFrameRate, max(range.minFrameRate, ceil(1 / interval)))
        let duration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
        guard CMTimeCompare(device.activeVideoMinFrameDuration, duration) != 0 || CMTimeCompare(device.activeVideoMaxFrameDuration, duration) != 0,
              (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if #available(macOS 15.0, *), device.isAutoVideoFrameRateEnabled { return }
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private func observe(_ name: Notification.Name, object: AnyObject, failure: NearbyCameraFailure) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [self] in
                guard !self.stopped else { return }
                self.completion(.failure(failure))
            }
        })
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            for output in session.outputs {
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            }
            session.stopRunning()
            for output in session.outputs { session.removeOutput(output) }
            for input in session.inputs { session.removeInput(input) }
            recognizer = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        // Allow a few ms of jitter so a 15 fps sensor yields exactly 3 or 10 analyses/s.
        guard !stopped, now - lastScan >= interval - 0.01, let buffer = sampleBuffer.imageBuffer else { return }
        lastScan = now
        do {
            let sample = try autoreleasepool {
                let faces: [VNFaceObservation]
                var people: Int?
                if recognition {
                    faces = try OwnerFaceDetector.observations(in: buffer)
                } else {
                    let request = VNDetectFaceRectanglesRequest()
                    request.revision = VNDetectFaceRectanglesRequestRevision3
                    try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
                    let all = request.results ?? []
                    faces = all.filter { $0.confidence >= 0.6 }
                    if presence { people = all.filter { $0.confidence >= 0.3 }.count }
                }
                var sample = NearbyFaceSample(count: faces.count, capturedAt: now, bounds: faces.map(\.boundingBox))
                sample.people = people
                if presence {
                    sample.motion = motion(in: buffer)
                    // Faces are cheaper to trust; segment the person only when none was found
                    // (~11 ms on the Neural Engine, measured on an M4).
                    if (people ?? faces.count) == 0 { sample.personCoverage = personCoverage(in: buffer) }
                }
                sample.faces = faces.map { CameraFace(bounds: $0.boundingBox, yaw: $0.yaw?.doubleValue, pitch: $0.pitch?.doubleValue, roll: $0.roll?.doubleValue) }
                if recognition {
                    guard let recognizer else { throw OwnerModelError.unavailable }
                    sample.identities = try faces.map { face in
                        guard let features = try recognizer.features(buffer: buffer, face: face) else { return nil }
                        return CameraIdentity(vector: features.vector, pose: features.pose)
                    }
                    if faces.count == 1, let identity = sample.identities.first ?? nil {
                        sample.vector = identity.vector; sample.pose = identity.pose
                    }
                }
                return sample
            }
            analysisFailures = 0
            completion(.success(sample))
        } catch {
            analysisFailures += 1
            if analysisFailures >= 3 { completion(.failure(.analysis)) }
        }
    }
}
