// Clinton Imaro was here 20/09/2026.

import AppKit
import Carbon
import Combine
import CoreMotion
import ShieldCore
import simd

@MainActor
final class AppModel: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    @Published private(set) var trackingSource: HeadTrackingSource
    let cameraTracking = CameraHeadTracking()
    private var cameraPauses: Set<NearbyPauseReason> = []
    private var protectCameraOnResume = false
    @Published private(set) var enabled = false
    @Published private(set) var connected = false
    @Published private(set) var calibrated = false
    @Published private(set) var coverage = 0.0
    /// Live head position for the setup and settings views, at most 5 Hz. Head motion
    /// arrives at 25-30 Hz; publishing every sample re-rendered Settings and the notch
    /// bar each time (~30% CPU). Shield decisions use `liveOffset` at full rate.
    @Published private(set) var offset = HeadOffset(yaw: 0, pitch: 0)
    private var liveOffset = HeadOffset(yaw: 0, pitch: 0)
    private var offsetPublished: TimeInterval = 0
    // Assigned on every motion sample; only notify views when the text changes.
    private(set) var status = "Ready when you are" { willSet { if newValue != status { objectWillChange.send() } } }
    private(set) var detail = "Connect your AirPods to this Mac, then start head tracking." { willSet { if newValue != detail { objectWillChange.send() } } }
    @Published private(set) var captureNotice: String?
    @Published private(set) var screenPermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var restarting = false
    @Published private(set) var previewing = false
    @Published private(set) var shortcutError: String?
    @Published private(set) var areaShortcutError: String?
    let areaShortcutLabel = "⌃⌥⌘A"
    @Published var recordingShortcut = false
    @Published var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: "includeBlurInCaptures")
            overlay.includeInCaptures = demoMode
            privacy.includeInCaptures = demoMode
            cover.includeInCaptures = demoMode
        }
    }
    /// Lock the Mac after this many minutes covered with nobody in view (0 = never).
    @Published var autoLockMinutes = UserDefaults.standard.integer(forKey: "autoLockMinutes") {
        didSet { UserDefaults.standard.set(autoLockMinutes, forKey: "autoLockMinutes"); updateAutoLock() }
    }
    /// Look of camera-triggered covers. Every style except `.glass` avoids screen capture.
    @Published var coverStyle = CoverStyle.saved {
        didSet {
            guard coverStyle != oldValue else { return }
            UserDefaults.standard.set(coverStyle.rawValue, forKey: CoverStyle.preferenceKey)
            // Move an active cover between the capture-free cover and the captured blur.
            privacy.setNearbyMonitoring(nearby.enabled && coverStyle.usesScreenCapture)
            privacy.setNearbyCovered(nearby.covered && coverStyle.usesScreenCapture)
            updateCover()
        }
    }
    @Published var comfort: Double { didSet { save("comfort", comfort); refreshResponse() } }
    @Published var transition: Double { didSet { save("transition", transition); refreshResponse() } }
    @Published var blur: Double { didSet { save("blur", blur); privacy.blurRadius = blur } }
    @Published private(set) var shortcutLabel: String
    @Published private(set) var privacyShortcutError: String?
    @Published private(set) var learning = false
    @Published private(set) var learningProgress = 0.0
    @Published private(set) var suggestedComfort: Double?
    @Published private(set) var learningNotice: String?
    @Published private(set) var headSetupActive = false

    @Published var perDisplayTracking = false {
        didSet { displayTracking.invalidate(); displayCalibrationIDs = []; clearOverlay(); updateShield() }
    }
    @Published private(set) var displayCalibrationIDs = Set<UInt32>()
    @Published private(set) var displayCalibrationNotice: String?
    private var displayTracking = DisplayHeadTracking()
    private var displayCalibrationTask: Task<Void, Never>?
    private var displayLayout: [UInt32: CGRect] = [:]

    let privacy = PrivacyController()
    let nearby = NearbyPeople()
    let protectionCheck = ProtectionCheck()
    let loginPreference = LoginPreference()
    let updates = AppUpdates()
    private var maintenanceObservations: [AnyCancellable] = []
    private var protectionCheckObservation: AnyCancellable?
    private var nearbyObservation: AnyCancellable?
    var onOpenPrivacySettings: (() -> Void)?
    var onOpenControls: (() -> Void)?
    var onOpenProfileSettings: (() -> Void)?
    var onOpenNearbySettings: (() -> Void)?
    var onShowProfiles: ((NSView, Bool) -> Void)?
    var onRequestHeadSetup: (() -> Void)?
    var onCancelHeadSetup: (() -> Void)?

    private let motion = CMHeadphoneMotionManager()
    /// Earbuds using Android's head tracker HID protocol, e.g. Sony WF-1000XM6.
    private let headphones = HIDHeadTracker()
    private let overlay = ShieldOverlay()
    let cover = PrivacyCover()
    /// "Cover when I leave" mode: detection only, manual unlock, camera off while covered.
    let away = AwayMonitor()
    private var awayObservation: AnyCancellable?
    @Published var protectionMode = ProtectionMode.saved {
        didSet {
            guard protectionMode != oldValue else { return }
            UserDefaults.standard.set(protectionMode.rawValue, forKey: ProtectionMode.preferenceKey)
            // Carry the master switch over to the other mode.
            let wasOn = oldValue == .away ? away.wantsMonitoring : nearby.wantsMonitoring
            if oldValue == .away { away.setEnabled(false) } else { nearby.stop() }
            if wasOn { setCameraProtection(true) }
        }
    }
    private var demoCovered = false
    /// Head tracking (AirPods, earbuds, camera) is turned away, shown with the capture-free cover.
    private var headCovered = false
    private let shortcuts = GlobalShortcuts()
    private var response = ShieldResponse()
    private var center: simd_quatd?
    private var latest: simd_quatd?
    private var sourceLocation: CMDeviceMotion.SensorLocation?
    private var lastSample: TimeInterval = 0
    private var lastPublished: TimeInterval = 0
    private var everCalibrated = false
    private var dismissedForLoss = false
    private var pendingCalibration = false
    private var timer: Timer?
    private var previewEnd: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var absentSince: Date?
    private let peekAlert = PeekAlert()
    private let postureAlert = PeekAlert()
    /// "Blur until they look away" is showing; Exit suppresses it for a minute.
    private var peekCovered = false
    private var peekSuppressedUntil = Date.distantPast
    private var graceTimer: Timer?
    private var autoLockTimer: Timer?
    private var keyCode: UInt32
    private var keyModifiers: UInt32
    private var privacyObservation: AnyCancellable?
    private var calibration = AdaptiveCalibration()
    private var learningStarted: TimeInterval = 0
    private var setupSnapshot: HeadSetupSnapshot?
    private var motionReferenceGeneration = 0

    private struct HeadSetupSnapshot {
        let enabled: Bool
        let comfort: Double
        let center: simd_quatd?
        let source: CMDeviceMotion.SensorLocation?
        let generation: Int
        let calibrated: Bool
        let everCalibrated: Bool
        let dismissedForLoss: Bool
        let response: ShieldResponse
    }

    override init() {
        let prefs = UserDefaults.standard
        trackingSource = HeadTrackingSource(rawValue: prefs.string(forKey: "headTrackingSource") ?? "") ?? .airPods
        demoMode = prefs.bool(forKey: "includeBlurInCaptures")
        comfort = prefs.object(forKey: "comfort") == nil ? 15 : max(2, min(30, prefs.double(forKey: "comfort")))
        transition = prefs.object(forKey: "transition") == nil ? 18 : max(5, min(30, prefs.double(forKey: "transition")))
        blur = prefs.object(forKey: "blur") == nil ? 28 : max(10, min(70, prefs.double(forKey: "blur")))
        keyCode = prefs.object(forKey: "shortcutKey") == nil ? UInt32(kVK_ANSI_C) : UInt32(prefs.integer(forKey: "shortcutKey"))
        keyModifiers = prefs.object(forKey: "shortcutModifiers") == nil ? UInt32(controlKey | optionKey | cmdKey) : UInt32(prefs.integer(forKey: "shortcutModifiers"))
        shortcutLabel = prefs.string(forKey: "shortcutLabel") ?? "⌃⌥⌘C"
        super.init()
        cameraTracking.onChange = { [weak self] in self?.receiveCameraTracking() }
        headphones.onSample = { [weak self] sample in
            guard let self, self.enabled, self.trackingSource == .headphones else { return }
            self.receive(orientation: sample.orientation)
        }
        headphones.onConnectionChange = { [weak self] connected in
            guard let self, self.enabled, self.trackingSource == .headphones else { return }
            if connected { self.beginMotionIfAvailable() } else { self.motionDisconnected() }
        }
        nearby.onCoverage = { [weak self] value in
            guard let self else { return }
            self.privacy.setNearbyCovered(value && self.coverStyle.usesScreenCapture)
            self.updateCover()
        }
        // Upstream keeps a 30 fps full-resolution screen stream warm while monitoring so the
        // captured blur appears instantly. The capture-free cover needs no warm-up.
        nearby.onMonitoring = { [weak self] value in
            guard let self else { return }
            self.privacy.setNearbyMonitoring(value && self.coverStyle.usesScreenCapture)
        }
        // The check opens its own camera session. Away mode must let go of the camera too:
        // two sessions fight over the device, and a starved away monitor reads it as
        // "nobody here" and covers the screen.
        protectionCheck.onBegin = { [weak self] in
            self?.nearby.suspend(for: .protectionTest); self?.away.suspend(for: .protectionTest); self?.pauseCamera(for: .protectionTest)
            Diagnostics.log("protection check started; away paused")
        }
        protectionCheck.onEnd = { [weak self] in
            self?.nearby.resume(after: .protectionTest); self?.away.resume(after: .protectionTest); self?.resumeCamera(after: .protectionTest)
            Diagnostics.log("protection check ended; away resumed")
        }
        protectionCheck.onDemoCoverage = { [weak self] value in
            guard let self else { return }
            if self.coverStyle.usesScreenCapture { self.privacy.setTestCovered(value) }
            else { self.demoCovered = value; self.updateCover() }
        }
        protectionCheck.demoAvailable = { [weak self] in
            guard let self else { return false }
            return !self.coverStyle.usesScreenCapture || self.privacy.captureUnavailable == false
        }
        protectionCheckObservation = protectionCheck.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }
        maintenanceObservations = [
            loginPreference.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            updates.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        ]
        nearby.prepareMonitoring = { [weak self] in
            guard let self else { return .escapeUnavailable }
            if self.nearby.response == .blur, self.coverStyle.usesScreenCapture, !self.screenPermission { return .screenPermission }
            guard self.shortcuts.armEscape(true) else {
                self.privacyShortcutError = "Escape is unavailable. Nearby people could not start."
                return .escapeUnavailable
            }
            return nil
        }
        nearbyObservation = nearby.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.refreshEscape()
            self?.updateShield()
            self?.updateCover()
        }
        cover.includeInCaptures = demoMode
        cover.badge.onUnlock = { [weak self] in
            guard let self else { return }
            if self.away.covered { self.unlockAway() } else { self.unlockCoverWithAuthentication() }
        }
        cover.badge.onExit = { [weak self] in
            guard let self else { return }
            if self.away.covered { self.unlockAway() }
            else if self.peekCovered { self.peekSuppressedUntil = Date().addingTimeInterval(60); self.updateOnlooker(false) }
            else { self.dismissShield() }
        }
        away.onCoverage = { [weak self] _ in self?.updateCover() }
        away.onOnlooker = { [weak self] watching in self?.updateOnlooker(watching) }
        away.onPosture = { [weak self] issue in
            guard let self, !self.away.covered, !self.away.onlooker else { return }
            switch issue {
            case .tooClose: self.postureAlert.flash(symbol: "arrow.up.backward.and.arrow.down.forward", text: "Posture: you're very close to the screen")
            case .slouching: self.postureAlert.flash(symbol: "figure.seated.side", text: "Posture: sit up a little")
            case .headTilt: self.postureAlert.flash(symbol: "level", text: "Posture: your head is tilted")
            }
        }
        awayObservation = away.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.refreshEscape()
        }
        privacy.blurRadius = blur
        overlay.includeInCaptures = demoMode
        privacy.includeInCaptures = demoMode
        if screenPermission { UserDefaults.standard.set(true, forKey: "screenAccessPreviouslyGranted") }
        motion.delegate = self
        refreshResponse()
        shortcuts.onRecenter = { [weak self] in self?.recenter() }
        shortcuts.onEscape = { [weak self] in
            guard let self else { return }
            if self.headSetupActive { self.onCancelHeadSetup?() }
            else if self.away.covered { self.unlockAway() }
            else if self.cover.isCovered && self.nearby.covered && self.nearby.owner.enabled {
                // Escape used to clear everything. With Recognize me, a covered screen
                // must not be dismissible by whoever is sitting at the keyboard.
                self.authenticateThen("Turn off QuietGlass protection.") { $0.dismissShield() }
            } else { self.dismissShield() }
        }
        shortcuts.onPrivacy = { [weak self] in self?.toggleInstantShield() }
        shortcuts.onArea = { [weak self] in self?.privacy.chooseArea() }
        shortcuts.onPeek = { [weak self] value in self?.privacy.setPeeking(value) }
        overlay.onClear = { [weak self] in self?.refreshEscape() }
        privacy.requestEscape = { [weak self] in self?.shortcuts.armEscape(true) ?? false }
        privacy.onRulesChanged = { [weak self] in
            self?.refreshResponse()
            self?.updateShield()
        }
        privacy.onActivityChanged = { [weak self] in
            guard let self else { return }
            self.refreshEscape()
            if !self.shortcuts.armPeek(self.privacy.instant) {
                self.privacyShortcutError = "Hold to peek is in use by another app. Escape still clears the shield."
            }
            self.updateShield()
        }
        privacyObservation = privacy.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if !shortcuts.setPrivacyShortcut() {
            privacyShortcutError = "⌃⌥⌘P is in use by another app. Use Shield screen in the menu instead."
        }
        if !shortcuts.setAreaShortcut() {
            areaShortcutError = "⌃⌥⌘A is in use by another app. Use Choose area or the notch button."
        }
        overlay.onCaptureStatus = { [weak self] notice in
            if self?.captureNotice != notice { self?.captureNotice = notice }
        }
        overlay.onPermissionDenied = { [weak self] in
            guard let self else { return }
            self.screenPermission = false
            self.stopPreview()
            self.clearOverlay()
            self.status = "Screen access needed"
            self.captureNotice = "Screen access is unavailable. Open Screen Settings to restore it."
        }
        if !shortcuts.setRecenter(keyCode: keyCode, modifiers: keyModifiers) {
            shortcutError = "The recenter shortcut is in use. Record a different one."
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.overlay.activeSpaceChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshScreenPermission(); self?.loginPreference.refresh(); self?.updates.checkIfDue() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.prepareForSleep() }
        })
        let nearbyLifecycle: [(Notification.Name, Notification.Name, NearbyPauseReason)] = [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .displaySleep),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession)
        ]
        for (pause, resume, reason) in nearbyLifecycle {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: pause, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.nearby.suspend(for: reason); self?.away.suspend(for: reason); self?.pauseCamera(for: reason) }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: resume, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.nearby.resume(after: reason); self?.away.resume(after: reason); self?.resumeCamera(after: reason) }
            })
        }
        // Screen lock and screen saver keep the display on but nobody needs the camera.
        let systemCovers: [(String, String, NearbyPauseReason)] = [
            ("com.apple.screenIsLocked", "com.apple.screenIsUnlocked", .screenLocked),
            ("com.apple.screensaver.didstart", "com.apple.screensaver.didstop", .screensaver)
        ]
        for (pause, resume, reason) in systemCovers {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: .init(pause), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.nearby.suspend(for: reason); self?.away.suspend(for: reason); self?.pauseCamera(for: reason) }
            })
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: .init(resume), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.nearby.resume(after: reason); self?.away.resume(after: reason); self?.resumeCamera(after: reason) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.nearby.resume(after: .systemSleep)
                self.away.resume(after: .systemSleep)
                self.resumeCamera(after: .systemSleep)
                guard self.enabled else { return }
                self.detail = "Look at your screen and recenter after waking your Mac."
                self.beginMotionIfAvailable()
                self.updateShield()
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        refreshDisplays()
        privacy.start()
    }

    var fullCoverAngle: Int { Int(comfort + transition) }
    var canRecenter: Bool { trackingSource == .camera ? enabled && cameraTracking.failure == nil && cameraPauses.isEmpty : enabled && connected && latest != nil && ProcessInfo.processInfo.systemUptime - lastSample < 1.5 }
    var hasCompletedHeadSetup: Bool { UserDefaults.standard.bool(forKey: "headSetupCompleted.v1") }
    var screenAccessPreviouslyGranted: Bool { UserDefaults.standard.bool(forKey: "screenAccessPreviouslyGranted") }
    var screenAccessAction: String { screenAccessPreviouslyGranted ? "Restore screen access" : "Allow screen access" }

    var connectedDisplays: [(id: UInt32, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (id, screen.localizedName)
        }
    }

    func calibrateDisplay(_ id: UInt32) {
        displayCalibrationTask?.cancel()
        displayCalibrationTask = Task { [weak self] in
            for second in stride(from: 3, through: 1, by: -1) {
                guard let self else { return }
                self.displayCalibrationNotice = LF("Face the selected display · %@", "\(second)")
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
            guard let self, self.perDisplayTracking, self.canRecenter, let latest = self.latest,
                  self.connectedDisplays.contains(where: { $0.id == id }) else {
                self?.displayCalibrationNotice = "Motion unavailable. Connect your AirPods and try again."
                return
            }
            if !self.calibrated { self.recenter() }
            self.displayTracking.calibrate(id, at: latest)
            self.displayCalibrationIDs = Set(self.displayTracking.centers.keys)
            self.displayCalibrationNotice = "Display centered. Repeat for your other displays."
            self.updateShield()
        }
    }

    /// A cover is not a lock: after a longer absence, lock macOS itself.
    private func updateAutoLock() {
        let absent = autoLockMinutes > 0 && (away.covered || (nearby.covered && nearby.status == .watching(0)))
        guard absent else { absentSince = nil; autoLockTimer?.invalidate(); autoLockTimer = nil; return }
        if absentSince == nil { absentSince = Date() }
        guard autoLockTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let since = self.absentSince else { return }
                guard Date().timeIntervalSince(since) >= Double(self.autoLockMinutes) * 60 else { return }
                self.absentSince = nil
                self.autoLockTimer?.invalidate(); self.autoLockTimer = nil
                ScreenLock.lockNow()
            }
        }
        timer.tolerance = 5
        autoLockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Shows the capture-free cover for Nearby people / Recognize me and keeps its prompt current.
    func updateCover() {
        updateAutoLock()
        // "Away" always uses the capture-free cover: the camera is off, nothing else runs.
        let wanted = away.covered || peekCovered || (!coverStyle.usesScreenCapture && (nearby.covered || demoCovered || headCovered))
        guard wanted else { cover.hide(); graceTimer?.invalidate(); graceTimer = nil; refreshEscape(); return }
        let title = away.covered ? L("You stepped away") : peekCovered ? L("Someone is looking at your screen") : nearby.covered ? nearby.noticeTitle : headCovered ? L("Looking away") : L("Protection check")
        let detail = away.covered
            ? (away.withinGrace || !away.unlockRequiresAuthentication ? L("Press any key to unlock") : L("Press Esc to unlock with Touch ID"))
            : peekCovered ? L("Clears when they look away")
            : nearby.owner.enabled && nearby.covered ? String(localized: "Look at the camera to unlock") : ""
        if cover.badge.title != title { cover.badge.title = title }
        if cover.badge.detail != detail { cover.badge.detail = detail }
        let canUnlock = away.covered ? away.unlockRequiresAuthentication && !away.withinGrace : nearby.owner.enabled && nearby.covered
        cover.badge.exitTitle = away.covered ? "Unlock" : "Exit blur"
        if cover.badge.canUnlock != canUnlock { cover.badge.canUnlock = canUnlock }
        if cover.badge.canExit != !canUnlock { cover.badge.canExit = !canUnlock }
        cover.show(style: coverStyle == .glass ? .fold : coverStyle)
        // Away: nobody is watching and the camera is off; stop the live blur too.
        cover.fadeToBlack(after: away.covered ? 15 : nil)
        if away.covered {
            cover.captureKeyboard()
            // Switch the prompt to Touch ID when the any-key window ends.
            graceTimer?.invalidate(); graceTimer = nil
            if let remaining = away.graceRemaining {
                let timer = Timer(timeInterval: remaining + 0.1, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.updateCover() }
                }
                graceTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        refreshEscape()
    }

    /// Someone else faces the screen in away mode: warn with a pill, or blur until
    /// they look away. The away cover itself takes precedence.
    private func updateOnlooker(_ watching: Bool) {
        let active = watching && !away.covered && Date() >= peekSuppressedUntil
        if active && away.peekResponse == .alert { peekAlert.show() } else { peekAlert.hide() }
        let blur = active && away.peekResponse == .blur
        if peekCovered != blur { peekCovered = blur; updateCover() }
    }

    /// Opens GitHub's bug form with the environment, settings (no names or images) and
    /// the recent diagnostics filled in, for you to review before submitting.
    func reportBug() {
        Diagnostics.log("bug report opened")
        let mode = protectionMode == .away ? "away" : "recognize"
        var settings = ["Protection: \(mode), \(cameraProtectionOn ? "on" : "off"); cover style \(coverStyle.rawValue); auto-lock \(autoLockMinutes) min"]
        if protectionMode == .away {
            settings.append("Away: cover after \(Int(away.delay)) s; any key for \(Int(away.graceSeconds)) s; Touch ID \(away.unlockRequiresAuthentication ? "on" : "off"); peek \(away.peekResponse.rawValue); posture \(away.postureReminders ? "on" : "off")")
            if let note = away.lastCoverNote { settings.append("Last cover: \(note)") }
        } else {
            settings.append("Recognize: saved faces \(nearby.owner.faces.count); detection \(nearby.detection.rawValue); response \(nearby.response.rawValue); head turn \(nearby.requireMovementCheck ? "on" : "off")")
        }
        settings.append("Head tracking: \(trackingSource.rawValue), \(enabled ? "on" : "off")")
        Diagnostics.reportBug(settings: settings)
    }

    /// Master switch for camera protection in the current mode.
    var cameraProtectionOn: Bool { protectionMode == .away ? away.wantsMonitoring : nearby.wantsMonitoring }

    func setCameraProtection(_ value: Bool) {
        if protectionMode == .away {
            if value { guard shortcuts.armEscape(true) else { privacyShortcutError = "Escape is unavailable. Nearby people could not start."; return } }
            away.setEnabled(value)
        } else { setNearbyPeople(value) }
        refreshEscape()
    }

    /// Back at the Mac: Escape or the cover's button, then Touch ID if required.
    func unlockAway() {
        guard away.covered else { return }
        if away.unlockRequiresAuthentication && !away.withinGrace { authenticateThen("Unlock your screen.") { $0.away.unlock() } }
        else { away.unlock() }
    }

    /// Fallback when the camera cannot recognize you (poor light, new glasses):
    /// Touch ID or the Mac password pauses Nearby people for five minutes.
    private func unlockCoverWithAuthentication() {
        authenticateThen("Pause QuietGlass protection for 5 minutes.") { $0.nearby.pauseForFiveMinutes() }
    }

    private var authenticating = false
    private func authenticateThen(_ reason: String, _ action: @escaping @MainActor (AppModel) -> Void) {
        guard !authenticating else { return }
        authenticating = true
        Task { @MainActor [weak self] in
            defer { self?.authenticating = false }
            guard let context = try? await OwnerRecognition.authenticateUser(reason) else { return }
            context.invalidate()
            guard let self else { return }
            action(self)
        }
    }

    private func refreshDisplays() {
        cover.reconcileScreens()
        let layout = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, CGRect)? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (id, screen.frame)
        })
        if !displayLayout.isEmpty, displayLayout != layout { invalidateDisplayCalibration() }
        displayLayout = layout
        overlay.reconcileScreens()
    }

    private func invalidateDisplayCalibration() {
        displayCalibrationTask?.cancel(); displayCalibrationTask = nil
        displayTracking.invalidate()
        displayCalibrationIDs = []
        if perDisplayTracking { displayCalibrationNotice = "Head motion changed. Center each display again." }
    }

    var currentProfile: PrivacyProfile? {
        if privacy.focusEnabled { return .focus }
        return PrivacyProfile.allCases.first { $0 != .focus && $0.settings.comfort == comfort && $0.settings.transition == transition && $0.settings.blur == blur }
    }

    var notchClearsProtection: Bool {
        previewing || privacy.fullScreen || privacy.focusEnabled || nearby.wantsMonitoring
    }

    var nearbyBlurUnavailable: Bool { (nearby.enabled || nearby.requesting || nearby.covered) && nearby.requiresBlur && privacy.captureUnavailable }
    var nearbyNeedsAttention: Bool { nearby.needsAttention || nearbyBlurUnavailable || nearby.temporarilyPaused || protectionCheck.demoSeconds != nil || protectionCheck.demoBlurred }
    var nearbyNoticeTitle: String {
        if protectionCheck.demoSeconds != nil || protectionCheck.demoBlurred { return "Protection test" }
        if nearby.temporarilyPaused { return "Nearby people paused" }
        return nearbyBlurUnavailable ? "Privacy blur unavailable" : nearby.noticeTitle
    }
    var nearbyNoticeDetail: String {
        if let seconds = protectionCheck.demoSeconds { return LF("Test blur starts in %d seconds", seconds) }
        if protectionCheck.demoBlurred {
            return privacy.captureUnavailable ? "Test blur unavailable · Check Screen Recording" : "Test blur clears automatically · Esc to stop"
        }
        if let seconds = nearby.pauseSecondsRemaining {
            return LF("Resumes in %d:%02d", seconds / 60, seconds % 60)
        }
        if nearbyBlurUnavailable { return "Open Settings to restore it" }
        if nearby.covered && !privacy.ready { return "Preparing blur · Esc to clear" }
        return nearby.noticeDetail
    }

    func blurNearbyNow() {
        guard screenPermission else { requestScreenPermission(); return }
        nearby.blurNow()
    }

    func applyProfile(_ profile: PrivacyProfile) {
        comfort = profile.settings.comfort
        transition = profile.settings.transition
        blur = profile.settings.blur
        setFocus(profile == .focus)
        updateShield()
    }

    func setFocus(_ value: Bool) {
        if value { stop() }
        privacy.setFocus(value)
    }

    func setNearbyPeople(_ value: Bool) {
        if value, nearby.owner.busy || nearby.owner.enrolling { return }
        nearby.setEnabled(value)
        if value, nearby.status == .unavailable(.screenPermission) { requestScreenPermission() }
    }

    func setNearbyResponse(_ value: NearbyResponse) {
        if value == .blur, nearby.enabled || nearby.requesting, !screenPermission { requestScreenPermission(); return }
        nearby.setResponse(value)
    }

    func retryNearbyPeople() {
        if nearby.response == .blur, !screenPermission { requestScreenPermission(); return }
        guard shortcuts.armEscape(true) else { privacyShortcutError = "Escape is unavailable. Nearby people could not start."; return }
        nearby.retry()
    }

    func retryNearbyBlur() {
        guard screenPermission else { requestScreenPermission(); return }
        privacy.start()
        if !privacy.captureUnavailable { privacy.setNearbyCovered(nearby.covered) }
    }

    func setTrackingSource(_ source: HeadTrackingSource) {
        guard source != trackingSource else { return }
        stop()
        trackingSource = source
        UserDefaults.standard.set(source.rawValue, forKey: "headTrackingSource")
        switch source {
        case .camera: detail = "Use your camera to blur when you turn away. Start tracking to calibrate."
        case .headphones: detail = "Connect earbuds that support head tracking, such as Sony WF-1000XM6."
        case .airPods: detail = "Connect your AirPods to this Mac, then start head tracking."
        }
    }

    func selectTrackingCamera(_ id: String) {
        let resume = enabled && trackingSource == .camera
        if resume { protectCameraOnResume = cameraTracking.policy.calibrated || cameraTracking.policy.coverage > 0; cameraTracking.stop() }
        nearby.selectCamera(id)
        if resume { startCameraTracking() }
    }

    func retryCameraTracking() { startCameraTracking() }

    private func startCameraTracking() {
        guard enabled, trackingSource == .camera, cameraPauses.isEmpty else { return }
        refreshResponse()
        cameraTracking.start(deviceID: nearby.selectedCameraID, keepCovered: protectCameraOnResume)
        protectCameraOnResume = false
        receiveCameraTracking()
    }

    private func receiveCameraTracking() {
        guard enabled, trackingSource == .camera else { return }
        connected = cameraTracking.policy.hasFace
        calibrated = cameraTracking.policy.calibrated
        setOffset(cameraTracking.policy.offset)
        detail = cameraTracking.message
        objectWillChange.send()
        updateShield()
    }

    func pauseCamera(for reason: NearbyPauseReason) {
        guard cameraPauses.insert(reason).inserted, enabled, trackingSource == .camera else { return }
        protectCameraOnResume = protectCameraOnResume || cameraTracking.policy.calibrated || cameraTracking.policy.coverage > 0
        cameraTracking.stop(); clearOverlay()
        status = "Camera head tracking paused"
    }

    func resumeCamera(after reason: NearbyPauseReason) {
        guard cameraPauses.remove(reason) != nil else { return }
        startCameraTracking()
    }

    func setEnabled(_ value: Bool) {
        if value { start() } else { stop() }
    }

    func start() {
        guard !enabled else { return }
        if trackingSource == .camera {
            guard screenPermission else { requestScreenPermission(); return }
            guard shortcuts.armEscape(true) else { privacyShortcutError = "Escape is unavailable. Camera tracking could not start."; return }
            enabled = true; dismissedForLoss = false
            startCameraTracking(); return
        }
        if trackingSource == .headphones {
            enabled = true
            status = "Connecting to headphones"
            detail = headphones.isConnected ? "Look at the screen, then click Center my gaze." : "Connect earbuds that support head tracking, such as Sony WF-1000XM6."
            beginMotionIfAvailable()
            return
        }
        if !headSetupActive, !hasCompletedHeadSetup, let onRequestHeadSetup {
            onRequestHeadSetup()
            return
        }
        let auth = CMHeadphoneMotionManager.authorizationStatus()
        guard auth != .denied && auth != .restricted else {
            status = "Motion permission needed"
            detail = "Allow QuietGlass in System Settings → Privacy & Security → Motion & Fitness."
            return
        }
        enabled = true
        status = "Connecting to AirPods"
        detail = "Wear at least one AirPod, look at the screen, then click Center my gaze."
        motion.startConnectionStatusUpdates()
        beginMotionIfAvailable()
    }

    func stop() {
        cancelLearning()
        invalidateDisplayCalibration()
        enabled = false
        protectCameraOnResume = false
        cameraTracking.stop()
        motion.stopDeviceMotionUpdates()
        motion.stopConnectionStatusUpdates()
        headphones.stop()
        center = nil
        latest = nil
        sourceLocation = nil
        calibrated = false
        connected = false
        everCalibrated = false
        dismissedForLoss = false
        pendingCalibration = false
        response.recenter()
        stopPreview()
        clearOverlay()
        status = "Paused"
        detail = "Your screen stays clear while head tracking is paused."
    }

    private func beginMotionIfAvailable() {
        if trackingSource == .headphones {
            guard enabled, headphones.isConnected, !headphones.streaming else { return }
            motionReferenceGeneration += 1
            invalidateDisplayCalibration()
            headphones.start()
            return
        }
        guard trackingSource == .airPods, enabled, !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable else { return }
        motionReferenceGeneration += 1
        invalidateDisplayCalibration()
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
            guard let self, self.enabled else { return }
            if let error {
                self.detail = error.localizedDescription
                return
            }
            if let sample { self.receive(sample) }
        }
    }

    private func receive(_ sample: CMDeviceMotion) {
        guard enabled, trackingSource == .airPods else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let q = sample.attitude.quaternion
        guard q.x.isFinite, q.y.isFinite, q.z.isFinite, q.w.isFinite else { return }
        if let previous = sourceLocation, previous != sample.sensorLocation {
            motionReferenceGeneration += 1
            invalidateDisplayCalibration()
            cancelLearning(message: "The active AirPod changed. Recenter and try again.")
            center = nil
            calibrated = false
            detail = "The active AirPod changed. Face your screen and recenter."
        }
        sourceLocation = sample.sensorLocation
        receive(orientation: simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w))
    }

    /// Shared by AirPods and HID earbuds.
    private func receive(orientation: simd_quatd) {
        let now = ProcessInfo.processInfo.systemUptime
        latest = simd_normalize(orientation)
        lastSample = now
        if !connected { connected = true }
        if pendingCalibration { recenter() }
        if let center, let latest, now - lastPublished > 1.0 / 30 {
            lastPublished = now
            setOffset(headOffset(center: center, current: latest))
            if learning { calibration.record(angle: liveOffset.angle) }
            updateShield()
        } else if center == nil {
            updateShield()
            if !everCalibrated { status = "Center your gaze" }
        }
    }

    func recenter() {
        cancelLearning()
        if !enabled { start() }
        guard enabled else { return }
        if trackingSource == .camera {
            if cameraTracking.failure != nil { startCameraTracking() } else { cameraTracking.recenter() }
            return
        }
        guard connected, ProcessInfo.processInfo.systemUptime - lastSample < 1.5, let latest else {
            pendingCalibration = true
            detail = "Waiting for motion. Keep your AirPods connected and face the screen."
            return
        }
        center = latest
        if perDisplayTracking, let facing = displayTracking.facing { displayTracking.calibrate(facing, at: latest) }
        calibrated = true
        everCalibrated = true
        pendingCalibration = false
        dismissedForLoss = false
        setOffset(HeadOffset(yaw: 0, pitch: 0), force: true)
        response.recenter()
        stopPreview()
        clearOverlay()
        status = "Watching your head motion"
        detail = LF("Small movements stay clear. Turn past %d° to cover the screen.", Int(comfort))
    }

    func dismissShield(file: StaticString = #fileID, line: UInt = #line) {
        protectionCheck.stopDemonstration()
        nearby.stop(file: file, line: line)
        if trackingSource == .camera { stop() }
        cancelLearning()
        stopPreview()
        response.dismiss()
        displayTracking.dismiss()
        dismissedForLoss = true
        privacy.dismissAll()
        clearOverlay()
        status = enabled ? "Shield dismissed" : "Paused"
        detail = "Face your screen to rearm, or use Center my gaze."
    }

    private func updateShield() {
        if privacy.fullScreen {
            stopPreview()
            if privacy.captureUnavailable { status = "Privacy capture needs attention" }
            else if !privacy.ready { status = "Preparing privacy blur" }
            else { status = privacy.nearbyCovered ? L("Covered · ") + L(nearby.noticeTitle) : privacy.peeking ? "Peeking at your screen" : "Privacy blur is on" }
            return
        }
        guard !previewing else { return }
        if learning { clearOverlay(); status = "Learning your normal movement"; return }
        if headSetupActive { clearOverlay(); status = "Setting up head tracking"; return }
        guard enabled else {
            clearOverlay()
            if privacy.focusEnabled { status = "Focus mode is on" }
            else if nearby.wantsMonitoring { status = nearby.message }
            else { status = "Ready when you are" }
            return
        }
        if privacy.ruleMode == .pause {
            clearOverlay()
            status = LF("Head blur paused for %@", privacy.frontAppName)
            return
        }
        if trackingSource == .camera {
            guard cameraPauses.isEmpty else { clearOverlay(); return }
            let value = cameraTracking.policy.coverage
            guard applyCoverage(value, direction: .from(cameraTracking.policy.offset)) else { return }
            status = cameraTracking.message
            return
        }
        if !connected || !calibrated {
            if everCalibrated && !dismissedForLoss {
                guard applyCoverage(1, direction: .left) else { return }
                status = "Covered while motion is unavailable"
            } else { clearOverlay() }
            return
        }
        if perDisplayTracking, !connectedDisplays.isEmpty, connectedDisplays.allSatisfy({ displayCalibrationIDs.contains($0.id) }), let latest {
            let settings = privacy.ruleMode.settings(comfort: comfort, transition: transition, blur: blur)
            let values = displayTracking.coverage(current: latest, displays: connectedDisplays.map(\.id),
                                                  comfort: settings.comfort, transition: settings.transition)
            let maximum = values.values.max() ?? 0
            guard applyCoverage(maximum, direction: .from(liveOffset), displays: values) else { return }
            status = displayCalibrationIDs.isEmpty ? "Center each display to use display tracking" : "Protecting displays you turn away from"
            return
        }
        let value = response.coverage(angle: liveOffset.angle)
        if !response.dismissedUntilCentered { dismissedForLoss = false }
        guard applyCoverage(value, direction: .from(liveOffset)) else { return }
        if response.dismissedUntilCentered { status = "Shield dismissed until you face center" }
        else if value > 0.001 { status = LF("Screen covered %d%%", Int(value * 100)) }
        else { status = "Watching your head motion" }
    }

    @discardableResult private func applyCoverage(_ value: Double, direction: ShieldDirection, displays: [UInt32: Double]? = nil) -> Bool {
        defer { refreshEscape() }
        // Capture-free styles cover the whole screen once you turn past the threshold;
        // the gradual, directional blur (and per-display coverage) needs screen capture.
        if !coverStyle.usesScreenCapture && displays == nil {
            let wanted = value > 0.001
            if wanted, !shortcuts.armEscape(true) {
                clearOverlay()
                status = "Escape is unavailable"
                detail = "Another app reserved Escape. Pause that shortcut and try again."
                return false
            }
            if headCovered != wanted { headCovered = wanted; updateCover() }
            if coverage != value { coverage = value }
            return true
        }
        if value > 0.001 {
            guard screenPermission else {
                clearOverlay()
                status = "Screen access needed"
                return false
            }
            guard shortcuts.armEscape(true) else {
                clearOverlay()
                status = "Escape is unavailable"
                detail = "Another app reserved Escape. Pause that shortcut and try again."
                return false
            }
            let radius = previewing ? blur : privacy.ruleMode.settings(comfort: comfort, transition: transition, blur: blur).blur
            overlay.show(coverage: value, direction: direction, blurRadius: radius, displays: displays)
        } else {
            overlay.fadeOut()
        }
        if coverage != value { coverage = value }
        return true
    }

    private func clearOverlay() {
        overlay.clear()
        if headCovered { headCovered = false; updateCover() }
        if coverage != 0 { coverage = 0 }
        refreshEscape()
    }

    /// Escape is a global hotkey, which takes it away from every other app. Hold it only
    /// while something is actually covering or blurring the screen; monitoring alone
    /// (Nearby people, away mode, head tracking) leaves Escape to the frontmost app.
    private func refreshEscape() {
        let visibleProtection = !privacy.paused && (privacy.selectedWindow != nil || !privacy.protectedAreas.isEmpty || privacy.focusEnabled || privacy.scanEnabled)
        shortcuts.armEscape(cover.isCovered || coverage > 0 || privacy.fullScreen || visibleProtection || overlay.isCapturing)
    }


    func toggleInstantShield() {
        cancelLearning()
        stopPreview()
        privacy.toggleInstant()
        if !privacy.instant {
            if enabled { updateShield() } else { status = "Ready when you are" }
        }
    }

    func learnMovement() {
        guard canRecenter, !privacy.instant else {
            learningNotice = "Start head tracking and connect your AirPods first."
            return
        }
        recenter()
        guard calibrated else { return }
        calibration = AdaptiveCalibration()
        suggestedComfort = nil
        learningNotice = nil
        learningProgress = 0
        learningStarted = ProcessInfo.processInfo.systemUptime
        learning = true
        clearOverlay()
    }

    func cancelLearning(message: String? = nil) {
        guard learning else { return }
        learning = false
        learningProgress = 0
        learningNotice = message
    }

    func applyCalibration() {
        guard let suggestedComfort else { return }
        comfort = suggestedComfort
        self.suggestedComfort = nil
        learningNotice = "Sensitivity updated. Recenter whenever your sitting position changes."
        updateShield()
    }

    @discardableResult func beginHeadSetup() -> Bool {
        guard !headSetupActive, !privacy.instant else { return false }
        setupSnapshot = HeadSetupSnapshot(enabled: enabled, comfort: comfort, center: center,
                                          source: sourceLocation, generation: motionReferenceGeneration, calibrated: calibrated,
                                          everCalibrated: everCalibrated, dismissedForLoss: dismissedForLoss,
                                          response: response)
        cancelLearning()
        suggestedComfort = nil
        learningNotice = nil
        headSetupActive = true
        stopPreview()
        clearOverlay()
        return true
    }

    func finishHeadSetup(completed: Bool) {
        guard let snapshot = setupSnapshot else { return }
        setupSnapshot = nil
        cancelLearning()
        suggestedComfort = nil
        learningNotice = nil
        headSetupActive = false
        if completed, canRecenter {
            recenter()
            UserDefaults.standard.set(true, forKey: "headSetupCompleted.v1")
        } else if snapshot.enabled && enabled {
            comfort = snapshot.comfort
            center = snapshot.source == sourceLocation && snapshot.generation == motionReferenceGeneration ? snapshot.center : nil
            calibrated = snapshot.calibrated && center != nil && connected
            everCalibrated = snapshot.everCalibrated
            dismissedForLoss = snapshot.dismissedForLoss
            response = snapshot.response
            refreshResponse()
            if let center, let latest { setOffset(headOffset(center: center, current: latest), force: true) }
        } else {
            comfort = snapshot.comfort
            stop()
        }
        updateShield()
    }

    func previewShield() {
        guard !privacy.instant else { return }
        cancelLearning()
        stopPreview()
        guard applyCoverage(1, direction: .right) else { return }
        previewing = true
        status = "Preview ends in 5 seconds"
        previewEnd = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard !Task.isCancelled, let self, self.previewing else { return }
            self.stopPreview(immediate: false)
            if self.enabled { self.updateShield() }
            else { self.status = "Ready when you are" }
        }
    }

    private func stopPreview(immediate: Bool = true) {
        previewEnd?.cancel()
        previewEnd = nil
        previewing = false
        if immediate { clearOverlay() }
        else { overlay.fadeOut(); coverage = 0 }
    }

    func openMotionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Motion")!)
    }

    func requestScreenPermission() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        refreshScreenPermission()
        if !screenPermission {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Saves the language choice and relaunches, since bundles resolve languages at launch.
    func setLanguage(_ language: AppLanguage) {
        guard language != AppLanguage.current else { return }
        language.apply()
        restartForScreenPermission()
    }

    func restartForScreenPermission() {
        guard !restarting else { return }
        restarting = true
        stop()
        UserDefaults.standard.set(true, forKey: "showControlsAfterRelaunch")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] application, error in
            Task { @MainActor in
                guard application != nil, error == nil else {
                    UserDefaults.standard.removeObject(forKey: "showControlsAfterRelaunch")
                    self?.restarting = false
                    self?.captureNotice = "Could not restart QuietGlass. Quit and reopen the app."
                    return
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func refreshScreenPermission() {
        guard !overlay.isCapturing else { return }
        let permission = CGPreflightScreenCaptureAccess()
        guard permission != screenPermission else { return }
        screenPermission = permission
        captureNotice = nil
        if permission {
            UserDefaults.standard.set(true, forKey: "screenAccessPreviouslyGranted")
            if enabled { updateShield() }
            else { status = "Ready when you are" }
        } else {
            stopPreview()
            clearOverlay()
            status = "Screen access needed"
        }
    }

    func recordShortcut(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { recordingShortcut = false; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            shortcutError = "Include Command, Control, or Option in your shortcut."
            return
        }
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        label += names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        if keyCode == UInt32(event.keyCode), keyModifiers == modifiers {
            recordingShortcut = false
            shortcutError = nil
            return
        }
        guard shortcuts.setRecenter(keyCode: UInt32(event.keyCode), modifiers: modifiers) else {
            shortcutError = "That shortcut is already in use. Try another combination."
            return
        }
        keyCode = UInt32(event.keyCode)
        keyModifiers = modifiers
        shortcutLabel = label
        let prefs = UserDefaults.standard
        prefs.set(Int(keyCode), forKey: "shortcutKey")
        prefs.set(Int(modifiers), forKey: "shortcutModifiers")
        prefs.set(label, forKey: "shortcutLabel")
        shortcutError = nil
        recordingShortcut = false
    }

    private func heartbeat() {
        refreshScreenPermission()
        guard enabled else { return }
        if trackingSource == .camera { return }
        let auth = CMHeadphoneMotionManager.authorizationStatus()
        if trackingSource == .airPods, auth == .denied || auth == .restricted {
            stop()
            status = "Motion permission needed"
            detail = "Allow QuietGlass in Privacy & Security → Motion & Fitness, then start again."
            return
        }
        if ProcessInfo.processInfo.systemUptime - lastSample > 1.5 {
            cancelLearning(message: "Motion was interrupted. Reconnect your AirPods and try again.")
            if connected {
                motionReferenceGeneration += 1
                invalidateDisplayCalibration()
                connected = false
                center = nil
                calibrated = false
                detail = "Motion stopped. Wear your AirPods and recenter when they reconnect."
            }
            if !everCalibrated { status = trackingSource == .headphones ? "Waiting for headphone motion" : "Waiting for AirPods motion" }
            if trackingSource == .headphones {
                // Settling after power-up is not an interruption.
                if headphones.warmingUp { status = "Headphone sensor is settling…"; return }
                headphones.stop()
            }
            beginMotionIfAvailable()
            updateShield()
        }
        if learning {
            learningProgress = min(1, (ProcessInfo.processInfo.systemUptime - learningStarted) / 8)
            if learningProgress >= 1 {
                learning = false
                suggestedComfort = calibration.recommendation
                learningNotice = suggestedComfort == nil ? "Too much motion or too few samples. Face your screen and try again." : "Review the suggested angle before applying it."
                updateShield()
            }
        }
    }

    private func prepareForSleep() {
        motionReferenceGeneration += 1
        invalidateDisplayCalibration()
        cancelLearning(message: "Calibration stopped while your Mac slept.")
        nearby.suspend(for: .systemSleep)
        away.suspend(for: .systemSleep)
        pauseCamera(for: .systemSleep)
        privacy.dismissAll()
        motion.stopDeviceMotionUpdates()
        headphones.stop()
        center = nil
        latest = nil
        connected = false
        calibrated = false
        stopPreview()
        clearOverlay()
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in self?.beginMotionIfAvailable() }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in
            guard let self, self.enabled, self.trackingSource == .airPods else { return }
            self.motionDisconnected()
        }
    }

    private func motionDisconnected() {
        motionReferenceGeneration += 1
        invalidateDisplayCalibration()
        cancelLearning(message: "AirPods disconnected. Reconnect and try again.")
        connected = false
        calibrated = false
        center = nil
        latest = nil
        detail = trackingSource == .headphones ? "Headphones disconnected. Face the screen and recenter after reconnecting."
            : "AirPods disconnected. Face the screen and recenter after reconnecting."
        updateShield()
    }

    private func setOffset(_ value: HeadOffset, force: Bool = false) {
        liveOffset = value
        let now = ProcessInfo.processInfo.systemUptime
        let moved = abs(value.yaw - offset.yaw) >= 0.5 || abs(value.pitch - offset.pitch) >= 0.5
        guard force || (moved && now - offsetPublished >= 0.2) else { return }
        offsetPublished = now
        offset = value
    }

    /// Earbud sensor frames are tilted in the ear; measure the total turn instead.
    private func headOffset(center: simd_quatd, current: simd_quatd) -> HeadOffset {
        guard trackingSource == .headphones else { return HeadOffset.between(center: center, current: current) }
        return HeadOffset.between(center: center, current: current, up: HIDHeadTracker.defaultUp, right: HIDHeadTracker.defaultRight)
    }

    private func refreshResponse() {
        let settings = privacy.ruleMode.settings(comfort: comfort, transition: transition, blur: blur)
        cameraTracking.comfort = settings.comfort
        cameraTracking.transition = settings.transition
        response.comfort = settings.comfort
        response.transition = settings.transition
    }

    private func save(_ key: String, _ value: Double) { UserDefaults.standard.set(value, forKey: key) }

    func shutdown() {
        updates.shutdown()
        protectionCheck.close()
        nearby.shutdown()
        stop()
        privacy.shutdown()
        timer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
