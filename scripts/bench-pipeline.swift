// Camera-pipeline power benchmark. Replays QuietGlass's upstream capture settings
// and the low-power settings side by side, using the real Vision + SFace path.
//
//   xcrun coremlcompiler compile Sources/QuietGlass/Resources/SFace.mlmodel /tmp
//   swiftc -O scripts/bench-pipeline.swift -o /tmp/bench-pipeline
//   /tmp/bench-pipeline upstream 30          # QuietGlass 0.1.2 settings
//   /tmp/bench-pipeline "fmt=420v dev=15 throttle=conn rate=3 ml=ane" 30
//   /tmp/bench-pipeline screen 30            # upstream's 30 fps display stream
//
// Prints this process's CPU time per second, frames analyzed and stage costs.
// Run scripts/measure-power.sh concurrently to include camera daemons.
import AVFoundation
import CoreImage
import CoreML
import ScreenCaptureKit
import Vision

let mode = CommandLine.arguments.dropFirst().first ?? "upstream"
// Options: fmt=bgra|420v|native dev=15|30 throttle=conn|delegate rate=<analyses/s> ml=cpu|ane|off cs=on|off
var options = ["fmt": "bgra", "dev": "30", "throttle": "delegate", "rate": "11", "ml": "cpu", "cs": "default"]
if mode != "upstream" {
    for pair in mode.split(separator: " ") {
        let kv = pair.split(separator: "=").map(String.init)
        if kv.count == 2 { options[kv[0]] = kv[1] }
    }
}
let rate = Double(options["rate"]!)!
let seconds = Double(CommandLine.arguments.dropFirst(2).first ?? "30") ?? 30

func cpuSeconds() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

final class Pipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let delegateThrottle = options["throttle"] == "delegate"
    let model: MLModel?
    let context = CIContext(options: [.cacheIntermediates: false])
    var lastScan: TimeInterval = 0
    var frames = 0, analyzed = 0, embeddings = 0
    var visionMs = 0.0, modelMs = 0.0

    override init() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = options["ml"] == "ane" ? .cpuAndNeuralEngine : .cpuOnly
        model = options["ml"] == "off" ? nil : try! MLModel(contentsOf: URL(fileURLWithPath: "/tmp/SFace.mlmodelc"), configuration: configuration)
        super.init()
        // Warm up so lazy ANE compilation is not billed to the measurement.
        if let model, let input = try? MLMultiArray(shape: [3, 112, 112], dataType: .float32) {
            _ = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["data": input]))
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        let now = ProcessInfo.processInfo.systemUptime
        // Upstream throttles in the delegate (every 0.09 s); the alternative throttles the connection.
        guard !delegateThrottle || now - lastScan >= 1 / rate - 0.005, let buffer = sampleBuffer.imageBuffer else { return }
        lastScan = now
        analyzed += 1
        autoreleasepool {
            let start = CFAbsoluteTimeGetCurrent()
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
            let detector = VNDetectFaceRectanglesRequest()
            detector.revision = VNDetectFaceRectanglesRequestRevision3
            try? handler.perform([detector])
            let faces = (detector.results ?? []).filter { $0.confidence >= 0.6 }
            if !faces.isEmpty {
                let landmarks = VNDetectFaceLandmarksRequest()
                landmarks.revision = VNDetectFaceLandmarksRequestRevision3
                landmarks.inputFaceObservations = faces
                try? handler.perform([landmarks])
            }
            visionMs += (CFAbsoluteTimeGetCurrent() - start) * 1000
            if model != nil { for face in faces { embed(buffer, face.boundingBox) } }
        }
    }

    func embed(_ buffer: CVPixelBuffer, _ box: CGRect) {
        let start = CFAbsoluteTimeGetCurrent()
        let w = CGFloat(CVPixelBufferGetWidth(buffer)), h = CGFloat(CVPixelBufferGetHeight(buffer))
        let crop = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: 112 / max(crop.width, 1), y: 112 / max(crop.height, 1)))
        var pixels = [UInt8](repeating: 0, count: 112 * 112 * 4)
        context.render(image, toBitmap: &pixels, rowBytes: 112 * 4, bounds: CGRect(x: 0, y: 0, width: 112, height: 112),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let input = try! MLMultiArray(shape: [3, 112, 112], dataType: .float32)
        let data = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * 112 * 112)
        for i in 0..<(112 * 112) {
            data[i] = Float(pixels[i * 4]); data[12544 + i] = Float(pixels[i * 4 + 1]); data[25088 + i] = Float(pixels[i * 4 + 2])
        }
        _ = try? model?.prediction(from: MLDictionaryFeatureProvider(dictionary: ["data": input]))
        modelMs += (CFAbsoluteTimeGetCurrent() - start) * 1000
        embeddings += 1
    }
}

final class Screen: NSObject, SCStreamOutput {
    var frames = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) { frames += 1 }
}

let queue = DispatchQueue(label: "bench.camera", qos: .userInitiated)
if mode == "screen" {
    // Upstream keeps a full-resolution 30 fps display stream alive during Nearby people monitoring.
    let output = Screen()
    let semaphore = DispatchSemaphore(value: 0)
    var stream: SCStream?
    Task { do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let display = content.displays[0]
        let config = SCStreamConfiguration()
        config.width = display.width * 2; config.height = display.height * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3; config.showsCursor = false; config.pixelFormat = kCVPixelFormatType_32BGRA
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        semaphore.signal()
    } catch { print(error); exit(1) } }
    semaphore.wait()
    let cpu0 = cpuSeconds()
    Thread.sleep(forTimeInterval: seconds)
    queue.sync { print(String(format: "screen: %.1f fps delivered, %.1f%% CPU (this process)", Double(output.frames) / seconds, (cpuSeconds() - cpu0) / seconds * 100)) }
    _ = stream
    exit(0)
}

print("Center Stage enabled by user:", AVCaptureDevice.isCenterStageEnabled, "mode:", AVCaptureDevice.centerStageControlMode.rawValue)
if options["cs"] == "off" { AVCaptureDevice.centerStageControlMode = .app; AVCaptureDevice.isCenterStageEnabled = false }
let pipeline = Pipeline()
let session = AVCaptureSession()
let device = AVCaptureDevice.default(for: .video)!
let output = AVCaptureVideoDataOutput()
output.alwaysDiscardsLateVideoFrames = true
switch options["fmt"] {
case "bgra": output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
case "420v": output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
default: break
}
output.setSampleBufferDelegate(pipeline, queue: queue)
session.beginConfiguration()
session.sessionPreset = .vga640x480
session.addInput(try! AVCaptureDeviceInput(device: device))
session.addOutput(output)
session.commitConfiguration()
session.startRunning()
// The session preset resets frame durations when it starts, so configure afterwards.
if let fps = Int32(options["dev"]!), (try? device.lockForConfiguration()) != nil {
    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
    device.unlockForConfiguration()
}
if options["throttle"] == "conn" { output.connection(with: .video)?.videoMinFrameDuration = CMTime(value: 100, timescale: CMTimeScale(rate * 100)) }
print("options", options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
      "| output format", output.videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] ?? "?")
Thread.sleep(forTimeInterval: 2)
queue.sync { pipeline.frames = 0; pipeline.analyzed = 0; pipeline.embeddings = 0; pipeline.visionMs = 0; pipeline.modelMs = 0 }
let cpu0 = cpuSeconds()
Thread.sleep(forTimeInterval: seconds)
let cpu = (cpuSeconds() - cpu0) / seconds * 100
queue.sync {
    print(String(format: "%@: camera %.1f fps delivered, %.1f analyzed/s, %.1f embeddings/s", mode, Double(pipeline.frames) / seconds, Double(pipeline.analyzed) / seconds, Double(pipeline.embeddings) / seconds))
    print(String(format: "  vision %.2f ms/frame, sface %.2f ms/face, process CPU %.1f%%", pipeline.visionMs / Double(max(pipeline.analyzed, 1)), pipeline.modelMs / Double(max(pipeline.embeddings, 1)), cpu))
}
session.stopRunning()
