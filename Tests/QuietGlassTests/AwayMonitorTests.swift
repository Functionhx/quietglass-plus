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
