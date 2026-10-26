import XCTest
import ShieldCore
@testable import QuietGlass

private final class FakeCamera: NearbyCameraSession {
    let completion: (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void
    var started = false, stopped = false, recognition = true, rate = 0.0
    init(_ completion: @escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) { self.completion = completion }
    func start() { started = true }
    func stop() { stopped = true }
    func configureRecognition(_ enabled: Bool) { recognition = enabled }
    func configureRate(_ analysesPerSecond: Double) { rate = analysesPerSecond }
}

@MainActor final class AwayMonitorTests: XCTestCase {
    private var cameras: [FakeCamera] = []
    private var now = 100.0
    private var suite = ""

    private func makeMonitor() -> AwayMonitor {
        suite = "QuietGlass.AwayTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(5.0, forKey: "awayDelay")
        return AwayMonitor(preferences: preferences, makeCamera: { [unowned self] in
            let camera = FakeCamera($0); cameras.append(camera); return camera
        }, clock: { [unowned self] in now })
    }
    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }

    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("did not settle")
    }
    private func send(faces: Int, advance: Double = 0.5) async {
        now += advance
        cameras.last!.completion(.success(NearbyFaceSample(count: faces, capturedAt: now)))
        for _ in 0..<10 { await Task.yield() }
    }

    func testCoversAfterLeavingStopsTheCameraAndUnlockWatchesAgain() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty }
        XCTAssertFalse(cameras[0].recognition, "Away mode never loads the face model")
        XCTAssertEqual(cameras[0].rate, 2)
        await send(faces: 1)
        for _ in 0..<8 { await send(faces: 0) }   // 4 s without a face
        XCTAssertFalse(monitor.covered)
        for _ in 0..<3 { await send(faces: 0) }
        XCTAssertTrue(monitor.covered)
        XCTAssertTrue(cameras[0].stopped, "No camera while covered")
        monitor.unlock()
        XCTAssertFalse(monitor.covered)
        await wait { self.cameras.count == 2 }
        XCTAssertTrue(cameras[1].started)
    }

    func testAnyKeyGraceStartsWhenCoveredAndCanBeTurnedOff() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.graceSeconds, 60, "Default: any key unlocks for the first minute")
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty }
        XCTAssertFalse(monitor.withinGrace, "No grace before covering")
        for _ in 0..<12 { await send(faces: 0) }
        XCTAssertTrue(monitor.covered)
        XCTAssertTrue(monitor.withinGrace)
        XCTAssertEqual(monitor.graceRemaining ?? 0, 60, accuracy: 1)
        monitor.graceSeconds = 0
        XCTAssertFalse(monitor.withinGrace, "Off: always Touch ID")
        monitor.unlock()
        XCTAssertNil(monitor.coveredAt)
    }

    private func send(faces: [CameraFace], advance: Double = 0.25) async {
        now += advance
        cameras.last!.completion(.success(NearbyFaceSample(count: faces.count, capturedAt: now, faces: faces)))
        for _ in 0..<10 { await Task.yield() }
    }

    func testSomeoneFacingTheScreenRaisesAPeekAlertThatClearsWhenTheyLeave() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        var events: [Bool] = []
        monitor.onOnlooker = { events.append($0) }
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty }
        let me = CameraFace(bounds: CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.4), yaw: 0, pitch: 0)
        let peeker = CameraFace(bounds: CGRect(x: 0.75, y: 0.45, width: 0.12, height: 0.18), yaw: 0.05, pitch: 0)
        for _ in 0..<6 { await send(faces: [me]) }
        XCTAssertFalse(monitor.onlooker)
        for _ in 0..<8 { await send(faces: [me, peeker]) }
        XCTAssertTrue(monitor.onlooker, "A second face facing the screen for ~2 s is an onlooker")
        XCTAssertEqual(cameras[0].rate, 4, "Looks more often while someone else is in view")
        for _ in 0..<10 { await send(faces: [me]) }
        XCTAssertFalse(monitor.onlooker)
        XCTAssertEqual(events, [true, false])
        XCTAssertFalse(monitor.covered, "A peek alert never counts as away")
    }

    func testCalibratedPostureRemindsWhenLeaningIn() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        var issues: [PostureIssue] = []
        monitor.onPosture = { issues.append($0) }
        monitor.postureHold = 2
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty }
        let upright = CameraFace(bounds: CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4), yaw: 0, pitch: 0, roll: 0)
        let close = CameraFace(bounds: CGRect(x: 0.25, y: 0.2, width: 0.44, height: 0.58), yaw: 0, pitch: 0, roll: 0)
        monitor.calibratePosture()
        for _ in 0..<6 { await send(faces: [upright]) }
        XCTAssertTrue(monitor.postureCalibrated)
        XCTAssertFalse(monitor.calibratingPosture)
        for _ in 0..<4 { await send(faces: [close]) }    // 1 s
        XCTAssertTrue(issues.isEmpty)
        for _ in 0..<6 { await send(faces: [close]) }    // past 2 s
        XCTAssertEqual(issues, [.tooClose])
        XCTAssertFalse(monitor.covered)
    }

    private let me: [Float] = OwnerTemplate.normalize([1] + Array(repeating: 0, count: 127))!
    private let stranger: [Float] = OwnerTemplate.normalize([0, 1] + Array(repeating: 0, count: 126))!
    private func savedMe() -> FaceProfiles {
        FaceProfiles([FaceProfile(name: "Me", template: OwnerTemplate(vectors: Array(repeating: me, count: 5), openEyes: 0.3))])
    }
    private func send(identities: [[Float]?], advance: Double = 0.5) async {
        now += advance
        let bounds = identities.indices.map { CGRect(x: 0.35 - Double($0) * 0.3, y: 0.3, width: 0.3 - Double($0) * 0.15, height: 0.4 - Double($0) * 0.2) }
        var sample = NearbyFaceSample(count: identities.count, capturedAt: now, bounds: bounds,
                                      faces: bounds.map { CameraFace(bounds: $0, yaw: 0, pitch: 0, roll: 0) })
        sample.identities = identities.map { $0.map { CameraIdentity(vector: $0, pose: OwnerPose(yaw: 0, eyes: 0.3)) } }
        cameras.last!.completion(.success(sample))
        for _ in 0..<10 { await Task.yield() }
    }

    func testAStrangerAtTheScreenCoversWhenRecognizeMeIsOn() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        monitor.loadFaces = { [unowned self] _ in self.savedMe() }
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty && monitor.recognizing }
        XCTAssertTrue(cameras[0].recognition, "Recognition runs on the same camera frames")
        for _ in 0..<6 { await send(identities: [me]) }
        XCTAssertFalse(monitor.covered)
        for _ in 0..<3 { await send(identities: [stranger]) }
        XCTAssertFalse(monitor.covered, "Three readings are not enough")
        await send(identities: [stranger])
        XCTAssertTrue(monitor.covered)
        XCTAssertEqual(monitor.coverReason, .stranger)
        XCTAssertTrue(cameras[0].stopped, "Manual unlock: the camera rests while covered")
    }

    func testAnUncertainMatchIsNeverAStranger() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        monitor.loadFaces = { [unowned self] _ in self.savedMe() }
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty && monitor.recognizing }
        // You at an angle: similarity 0.4 — below a match, above "clearly someone else".
        let blurry = OwnerTemplate.normalize([0.4, 0.92] + Array(repeating: 0, count: 126))!
        for _ in 0..<12 { await send(identities: [blurry]) }
        XCTAssertFalse(monitor.covered)
    }

    func testUnreadableFacesAreNotStrangers() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        monitor.loadFaces = { [unowned self] _ in self.savedMe() }
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty && monitor.recognizing }
        for _ in 0..<10 { await send(identities: [nil]) }   // turned away, too small, no landmarks
        XCTAssertFalse(monitor.covered)
    }

    func testUnlocksWhenASavedFaceComesBack() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        monitor.loadFaces = { [unowned self] _ in self.savedMe() }
        monitor.unlockWhenRecognized = true
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty && monitor.recognizing }
        for _ in 0..<12 { await send(identities: []) }
        XCTAssertTrue(monitor.covered)
        XCTAssertEqual(monitor.coverReason, .away)
        XCTAssertFalse(cameras[0].stopped, "Keeps watching to recognize you")
        await send(identities: [stranger]); await send(identities: [stranger])
        XCTAssertTrue(monitor.covered, "A stranger never unlocks it")
        await send(identities: [me]); await send(identities: [me])
        XCTAssertFalse(monitor.covered)
    }

    func testSavedCompanionsAreNotOnlookers() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        monitor.loadFaces = { [unowned self] _ in self.savedMe() }
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty && monitor.recognizing }
        for _ in 0..<12 { await send(identities: [me, me], advance: 0.25) }
        XCTAssertFalse(monitor.onlooker, "A saved face beside you is not peeking")
        XCTAssertFalse(monitor.covered)
    }

    func testPeekAlertOffIgnoresOnlookers() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        monitor.peekResponse = .off
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty }
        let me = CameraFace(bounds: CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.4), yaw: 0, pitch: 0)
        let peeker = CameraFace(bounds: CGRect(x: 0.75, y: 0.45, width: 0.12, height: 0.18), yaw: 0, pitch: 0)
        for _ in 0..<12 { await send(faces: [me, peeker]) }
        XCTAssertFalse(monitor.onlooker)
    }

    func testProtectionStartsBeforeSavedFacesLoadAndNeverWaitsOnAPrompt() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        var prompts: [Bool] = []
        monitor.loadFaces = { allowPrompt in prompts.append(allowPrompt); return nil }   // Keychain wants a prompt
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty && !prompts.isEmpty }
        XCTAssertTrue(monitor.watching, "Leaving, peeking and posture work without saved faces")
        XCTAssertEqual(prompts, [false], "Never prompts on its own")
        XCTAssertFalse(monitor.recognizing)
        monitor.confirmSavedFaces()
        await wait { prompts.count == 2 }
        XCTAssertEqual(prompts.last, true)
    }

    func testASegmentedPersonWithoutAFaceIsStillPresent() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty }
        for _ in 0..<30 {   // 15 s slumped, face never detected, perfectly still
            now += 0.5
            var sample = NearbyFaceSample(count: 0, capturedAt: now)
            sample.people = 0; sample.motion = 0; sample.personCoverage = 0.3
            cameras.last!.completion(.success(sample))
            for _ in 0..<10 { await Task.yield() }
        }
        XCTAssertFalse(monitor.covered)
        for _ in 0..<12 {   // the chair is empty
            now += 0.5
            var sample = NearbyFaceSample(count: 0, capturedAt: now)
            sample.people = 0; sample.motion = 0; sample.personCoverage = 0.004
            cameras.last!.completion(.success(sample))
            for _ in 0..<10 { await Task.yield() }
        }
        XCTAssertTrue(monitor.covered)
    }

    func testScreenUnlockClearsAnAwayCover() async throws {
        try XCTSkipIf(AVCaptureAuthorization.denied, "camera access denied for the test runner")
        let monitor = makeMonitor()
        monitor.setEnabled(true)
        await wait { !self.cameras.isEmpty }
        for _ in 0..<12 { await send(faces: 0) }
        XCTAssertTrue(monitor.covered)
        monitor.suspend(for: .screenLocked)
        monitor.resume(after: .screenLocked)
        XCTAssertFalse(monitor.covered, "macOS authenticated the unlock")
        monitor.suspend(for: .systemSleep)
        XCTAssertFalse(monitor.covered)
    }
}

import AVFoundation
private enum AVCaptureAuthorization {
    static var denied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }
}
