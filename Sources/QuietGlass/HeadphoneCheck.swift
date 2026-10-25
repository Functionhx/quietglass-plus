import AppKit
import ShieldCore
import simd

/// `QuietGlass --headphone-check`: speaks prompts, then prints the angle, direction and
/// cover decision QuietGlass computes for each pose from HID earbud head tracking.
@MainActor
final class HeadphoneCheck {
    private let tracker = HIDHeadTracker()
    private var latest: simd_quatd?
    private var center: simd_quatd?
    private var response = ShieldResponse(comfort: 15, transition: 18)
    private var samples = 0
    private var phase = ""
    private var poses: [String: [simd_quatd]] = [:]
    private var timeline: [(TimeInterval, String, simd_quatd)] = []
    private let started = ProcessInfo.processInfo.systemUptime

    func run() {
        tracker.onSample = { [weak self] sample in self?.receive(sample.orientation) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            guard tracker.isConnected else { print("No head-tracking earbuds found."); exit(1) }
            print("Device:", tracker.deviceName ?? "?")
            tracker.start()
            say("耳机传感器正在校准，请看着屏幕，稍等十二秒")
            DispatchQueue.main.asyncAfter(deadline: .now() + HIDHeadTracker.warmUp + 0.5) { [self] in steps([("center", "请看着屏幕正前方"), ("left", "请向左转头，看向左边，保持住"), ("back1", "请转回来看屏幕"),
                   ("right", "请向右转头，看向右边，保持住"), ("back2", "请转回来看屏幕"), ("down", "请低头看键盘，保持住"),
                   ("back3", "请抬头看屏幕")]) }
        }
    }

    private func steps(_ remaining: [(String, String)]) {
        guard let (name, prompt) = remaining.first else { finish(); return }
        say(prompt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [self] in
            phase = name
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [self] in
                if name == "center" { center = Self.mean(poses["center"] ?? []) }
                phase = ""
                steps(Array(remaining.dropFirst()))
            }
        }
    }

    private func receive(_ orientation: simd_quatd) {
        samples += 1
        latest = orientation
        timeline.append((ProcessInfo.processInfo.systemUptime - started, phase.isEmpty ? "(cue)" : phase, orientation))
        guard !phase.isEmpty else { return }
        poses[phase, default: []].append(orientation)
    }

    /// Average orientation (sign-aligned quaternion mean is adequate for small spreads).
    private static func mean(_ qs: [simd_quatd]) -> simd_quatd? {
        guard let first = qs.first else { return nil }
        var sum = SIMD4<Double>.zero
        for q in qs { sum += simd_dot(q.vector, first.vector) < 0 ? -q.vector : q.vector }
        return simd_normalize(simd_quatd(vector: sum))
    }

    private func finish() {
        tracker.stop()
        guard let center else { print("no center"); exit(1) }
        for name in ["left", "back1", "right", "back2", "down", "back3"] {
            let offsets = (poses[name] ?? []).map { HeadOffset.between(center: center, current: $0, up: HIDHeadTracker.defaultUp, right: HIDHeadTracker.defaultRight) }
            guard !offsets.isEmpty else { print(name, "no data"); continue }
            let o = offsets.sorted { $0.angle < $1.angle }[offsets.count / 2]
            var r = ShieldResponse(comfort: 15, transition: 18)
            let covered = r.coverage(angle: o.angle) > 0
            print(String(format: "%-6@ angle %5.1f°  yaw %+6.1f°  pitch %+6.1f°  → %@, %@", name as NSString, o.angle, o.yaw, o.pitch,
                         ShieldDirection.from(o).rawValue as NSString, (covered ? "COVER" : "clear") as NSString))
        }
        print("samples:", samples, "reference resets:", tracker.resets)
        if ProcessInfo.processInfo.environment["HEADPHONE_TIMELINE"] != nil {
            var next = 0.0
            for (t, name, q) in timeline where t >= next {
                next = t + 0.5
                let o = HeadOffset.between(center: center, current: q, up: HIDHeadTracker.defaultUp, right: HIDHeadTracker.defaultRight)
                print(String(format: "  t=%5.1f %-6@ yaw %+6.1f pitch %+6.1f angle %5.1f", t, name as NSString, o.yaw, o.pitch, o.angle))
            }
        }
        say("测试完成")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
    }

    private func say(_ text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Tingting", text]
        try? process.run()
    }
}
