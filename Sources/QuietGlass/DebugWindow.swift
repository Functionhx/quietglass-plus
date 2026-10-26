import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Settings → Camera protection → Debug: the live camera with every face boxed and
/// labeled the way QuietGlass judges it, plus the numbers behind each decision.
@MainActor
final class DebugWindowController: NSObject, NSWindowDelegate {
    static let shared = DebugWindowController()
    private var window: NSWindow?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        model.away.debugging = true
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = L("QuietGlass Debug")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: DebugView(away: model.away))
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.away.debugging = false
    }
}

private struct DebugView: View {
    @ObservedObject var away: AwayMonitor
    @State private var session: AVCaptureSession?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Color.black
                    if let session { DebugPreview(session: session) } else {
                        Text(away.covered ? "Camera off while covered" : "Camera not running").foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ForEach(away.debugFrame.faces) { face in
                            let rect = CGRect(x: (1 - face.bounds.maxX) * geo.size.width, y: (1 - face.bounds.maxY) * geo.size.height,
                                              width: face.bounds.width * geo.size.width, height: face.bounds.height * geo.size.height)
                            Rectangle().stroke(color(face.role), lineWidth: 2.5)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                            Text(label(face))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(color(face.role), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.black)
                                .fixedSize()
                                .position(x: rect.midX, y: max(10, rect.minY - 11))
                        }
                    }
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 14) {
                    legend(.you, "You"); legend(.saved, "Saved"); legend(.stranger, "Stranger"); legend(.onlooker, "Onlooker (facing screen)"); legend(.other, "Not looking / too small")
                }
                .font(.system(size: 11))
            }
            .frame(minWidth: 520)

            VStack(alignment: .leading, spacing: 8) {
                Text("Live readings").font(.headline)
                reading("State", away.covered ? (away.coverReason == .stranger ? L("Covered · stranger") : L("Covered · away")) : away.watching ? L("Watching") : L("Off"))
                reading("Recognize me", away.recognizing ? L("On") : L("Off"))
                reading("Faces (strict / loose)", "\(away.debugFrame.strictFaces) / \(away.debugFrame.looseFaces)")
                reading("Picture change", away.debugFrame.motion.map { String(format: "%.1f %%", $0 * 100) } ?? "–")
                reading("No face for", String(format: "%.1f s", away.debugFrame.sinceFace))
                reading("Still for", String(format: "%.1f s", away.debugFrame.sinceMovement))
                reading("Covers when", LF("no face ≥ %d s and still ≥ 5 s", Int(away.delay)))
                reading("Onlooker", away.debugFrame.onlooker ? L("Yes") : L("No"))
                reading("Posture", away.debugFrame.posture.isEmpty ? L("OK") : away.debugFrame.posture.map(\.rawValue).joined(separator: ", "))
                reading("Analyses per second", String(format: "%.0f", away.debugFrame.rate))
                Divider().padding(.vertical, 4)
                Text("Recent decisions").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if away.debugEvents.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
                        ForEach(away.debugEvents, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                Text("Frames stay on this Mac and are never saved.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(width: 330)
        }
        .padding(18)
        .onAppear { session = away.previewSession }
        .onReceive(tick) { _ in if session !== away.previewSession { session = away.previewSession } }
    }

    private func label(_ face: AwayDebugFrame.Face) -> String {
        let name: String
        switch face.role {
        case .you: name = L("You")
        case .saved: name = L("Saved")
        case .stranger: name = L("Stranger")
        case .onlooker: name = L("Onlooker")
        case .other: name = L("Not looking")
        }
        let deg = { (r: Double?) in r.map { String(format: "%+.0f°", $0 * 180 / .pi) } ?? "?" }
        let match = face.similarity.map { String(format: "  sim %.2f", $0) } ?? ""
        return "\(name)  yaw \(deg(face.yaw)) pitch \(deg(face.pitch))  \(Int(face.bounds.height * 100))%\(match)"
    }
    private func color(_ role: AwayDebugFrame.Role) -> Color {
        switch role {
        case .you: return .green
        case .saved: return .cyan
        case .stranger: return .red
        case .onlooker: return Color(red: 0.94, green: 0.5, blue: 0.85)
        case .other: return .gray
        }
    }
    private func legend(_ role: AwayDebugFrame.Role, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(color(role)).frame(width: 10, height: 10); Text(text) }
    }
    private func reading(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)) }
            .font(.system(size: 12))
    }
}

/// Mirrored like a mirror (as in FaceTime), matching how the overlay is drawn.
private struct DebugPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ view: PreviewView, context: Context) {
        if view.preview.session !== session { view.preview.session = session }
    }
    final class PreviewView: NSView {
        let preview: AVCaptureVideoPreviewLayer
        init(session: AVCaptureSession) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            wantsLayer = true
            preview.videoGravity = .resizeAspect
            // Mirror with the layer itself: the connection may not exist yet when the
            // view first lays out, so a connection setting can silently not apply.
            preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            layer?.addSublayer(preview)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
            unmirrorConnection()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.unmirrorConnection() }
        }
        /// Keep the connection itself unmirrored so the layer flip isn't undone.
        private func unmirrorConnection() {
            guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }
}
