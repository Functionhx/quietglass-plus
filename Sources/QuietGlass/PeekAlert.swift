import AppKit
import SwiftUI

final class PillContent: ObservableObject {
    @Published var symbol = "eyes"
    @Published var text: LocalizedStringKey = "Someone is looking at your screen"
    @Published var urgent = true
}

/// A pill below the notch: the Honor-style "someone is looking at your screen" alert and
/// posture reminders. It never takes focus or clicks, and is hidden from screen sharing.
@MainActor
final class PeekAlert {
    private var panel: NSPanel?
    var includeInCaptures = false
    let content = PillContent()

    /// Shows a one-off message, then hides it.
    func flash(symbol: String, text: LocalizedStringKey, for seconds: TimeInterval = 6) {
        content.symbol = symbol; content.text = text; content.urgent = false
        panel = nil // re-measure for the new text
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.hide() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let screen = NSScreen.screens.first else { return }
        let size = panel.frame.size
        let top = screen.visibleFrame.maxY - 10
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: top - size.height))
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { Task { @MainActor in if panel.alphaValue == 0 { panel.orderOut(nil) } } })
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: PeekPill(content: content))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = includeInCaptures ? .readOnly : .none
        panel.contentView = host
        return panel
    }
}

private struct PeekPill: View {
    @ObservedObject var content: PillContent
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 10) {
            if content.urgent {
                ZStack {
                    Circle().fill(Color.red.opacity(0.35)).frame(width: 18, height: 18).scaleEffect(pulse ? 1.25 : 0.8).opacity(pulse ? 0 : 1)
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                }
            }
            Image(systemName: content.symbol).font(.system(size: 15, weight: .semibold))
            Text(content.text).font(.system(size: 14, weight: .semibold))
                .lineLimit(1).fixedSize()
        }
        .fixedSize()
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .padding(6)
        .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true } }
    }
}
