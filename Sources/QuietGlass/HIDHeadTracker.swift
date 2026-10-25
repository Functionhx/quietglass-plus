import Foundation
import IOKit.hid
import ShieldCore
import simd

/// Head tracking from earbuds that implement Android's head tracker HID protocol
/// (Sensor page 0x20, usage 0xE1, description "#AndroidHeadTracker#1.0"), such as
/// Sony WF-1000XM6. Apple's CMHeadphoneMotionManager only serves AirPods and Beats.
///
/// Reports: rotation vector (3 × int16, ±π rad) + angular velocity (3 × int16) +
/// reset counter. Feature report 1 switches reporting and sensor power, so the
/// earbuds' IMU only runs while QuietGlass is tracking.
@MainActor
final class HIDHeadTracker {
    struct Sample { let orientation: simd_quatd; let time: TimeInterval }

    /// Axes measured on a WF-1000XM6 worn normally: the earbud frame is pitched about
    /// 45° from the head, so a left turn rotates about (−0.1, 0.68, 0.72).
    static let defaultUp = simd_normalize(SIMD3<Double>(-0.1, 0.68, 0.72))
    static let defaultRight: SIMD3<Double> = {
        let x = SIMD3<Double>(1, 0, 0)
        return simd_normalize(x - simd_dot(x, defaultUp) * defaultUp)
    }()

    /// After power-up the WF-1000XM6's sensor fusion drifts ~4°/s in pitch for about
    /// 12 s before settling, so samples are held back until then.
    static let warmUp: TimeInterval = 12

    var onSample: ((Sample) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    private(set) var deviceName: String?
    private(set) var streaming = false
    var resets: Int { stitcher.resets }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private var stitcher = HeadTrackerStitcher()
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var wantsStream = false
    private var streamStarted: TimeInterval = 0
    var warmingUp: Bool { streaming && ProcessInfo.processInfo.systemUptime - streamStarted < Self.warmUp }

    init() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0xE1] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let tracker = Unmanaged<HIDHeadTracker>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { tracker.attach(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let tracker = Unmanaged<HIDHeadTracker>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { tracker.detach(device) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    var isConnected: Bool { device != nil }

    func start() {
        wantsStream = true
        guard let device, !streaming else { return }
        stitcher = HeadTrackerStitcher()
        streamStarted = ProcessInfo.processInfo.systemUptime
        // bit 0: all events, bit 1: full power, bits 2-7: report interval in ms (40 ≈ 25 Hz).
        streaming = setControl(on: device, 1 | 1 << 1 | 40 << 2)
    }

    func stop() {
        wantsStream = false
        guard let device, streaming else { return }
        _ = setControl(on: device, 0) // reporting off, sensor powered down
        streaming = false
    }

    private func attach(_ candidate: IOHIDDevice) {
        guard device == nil, Self.isHeadTracker(candidate) else { return }
        device = candidate
        deviceName = IOHIDDeviceGetProperty(candidate, kIOHIDProductKey as CFString) as? String
        IOHIDDeviceRegisterInputReportCallback(candidate, reportBuffer, 64, { context, _, _, _, reportID, report, length in
            let tracker = Unmanaged<HIDHeadTracker>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { tracker.receive(reportID: reportID, report: report, length: length) }
        }, Unmanaged.passUnretained(self).toOpaque())
        onConnectionChange?(true)
        if wantsStream { start() }
    }

    private func detach(_ removed: IOHIDDevice) {
        guard let device, CFEqual(device, removed) else { return }
        self.device = nil
        deviceName = nil
        streaming = false
        onConnectionChange?(false)
    }

    private func receive(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard streaming, reportID == 1, length >= 13 else { return }
        // On macOS the buffer starts with the report ID when the device uses report IDs.
        let base = length >= 14 ? 1 : 0
        func value(_ offset: Int) -> Double {
            Double(Int16(bitPattern: UInt16(report[base + offset]) | UInt16(report[base + offset + 1]) << 8)) * .pi / 32767
        }
        let rotation = SIMD3(value(0), value(2), value(4))
        guard let orientation = stitcher.orientation(rotation: rotation, resetCounter: report[base + 12]), !warmingUp else { return }
        onSample?(Sample(orientation: orientation, time: ProcessInfo.processInfo.systemUptime))
    }

    private func setControl(on device: IOHIDDevice, _ value: UInt8) -> Bool {
        var report: [UInt8] = [1, value]
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 1, &report, report.count) == kIOReturnSuccess
    }

    /// Only devices that describe themselves as Android head trackers.
    private static func isHeadTracker(_ device: IOHIDDevice) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64)
        var length = CFIndex(buffer.count)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 2, &buffer, &length) == kIOReturnSuccess, length > 1 else { return false }
        let text = String(decoding: buffer[1..<min(length, 24)].prefix { $0 != 0 }, as: UTF8.self)
        return text.hasPrefix("#AndroidHeadTracker#")
    }
}
