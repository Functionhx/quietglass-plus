import AppKit
import QuartzCore
import SwiftUI

/// How a camera-triggered cover looks. Only `.glass` captures the screen; the
/// others are composited by WindowServer and cost nothing while you work.
enum CoverStyle: String, CaseIterable, Identifiable {
    case fold, frosted, curtain, black, glass
    static let preferenceKey = "coverStyle"
    static var saved: CoverStyle { CoverStyle(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .fold }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fold: return String(localized: "Fold")
        case .frosted: return String(localized: "Frosted")
        case .curtain: return String(localized: "Curtain")
        case .black: return String(localized: "Black")
        case .glass: return String(localized: "Captured blur")
        }
    }
    var detail: String {
        switch self {
        case .fold: return String(localized: "Frosts instantly, then unfolds a privacy sheet from the center like a folding phone.")
        case .frosted: return String(localized: "System frosted glass. Lowest power.")
        case .curtain: return String(localized: "Frosts instantly, then draws two curtains closed.")
        case .black: return String(localized: "Solid black.")
        case .glass: return String(localized: "Adjustable blur. Records the screen continuously while monitoring, which uses more power.")
        }
    }
    var usesScreenCapture: Bool { self == .glass }
}

final class CoverBadgeModel: ObservableObject {
    @Published var title = ""
    @Published var detail = ""
    @Published var canUnlock = false
    /// Shown when no authentication is needed to clear (looking away, no Recognize me).
    @Published var canExit = false
    @Published var exitTitle: LocalizedStringKey = "Exit blur"
    var onUnlock: (() -> Void)?
    var onExit: (() -> Void)?
}

private struct CoverBadge: View {
    @ObservedObject var model: CoverBadgeModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text("Privacy protected")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
            if !model.title.isEmpty {
                Text(model.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if model.canUnlock || model.canExit {
                Button { model.canUnlock ? model.onUnlock?() : model.onExit?() } label: {
                    Label(model.canUnlock ? "Unlock with Touch ID" : model.exitTitle, systemImage: model.canUnlock ? "touchid" : "xmark.circle")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.white.opacity(0.14), in: Capsule())
                .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class CoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One full-screen cover per display. Showing is always instant (the frost or
/// black is opaque on the first frame); styles only animate on top of it.
@MainActor
final class CoverSurface {
    let panel: CoverPanel
    private let effect = NSVisualEffectView()
    private let root = CALayer()
    private let dim = CALayer()
    private let stage = CALayer()
    private let leftSheet = CAGradientLayer()
    private let rightSheet = CAGradientLayer()
    private let leftShade = CALayer()
    private let rightShade = CALayer()
    private let hinge = CALayer()
    private var badge: NSHostingView<AnyView>?
    private(set) var style = CoverStyle.fold
    private var hideGeneration = 0

    init(screen: NSScreen, badgeModel: CoverBadgeModel?, includeInCaptures: Bool) {
        panel = CoverPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "QuietGlass Cover"
        panel.isFloatingPanel = true
        // Above the notch controls (+3/+4) so a passer-by cannot pause protection;
        // the cover shows the verification prompts itself.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 5)
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false // swallow clicks meant for hidden windows
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = includeInCaptures ? .readOnly : .none

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.autoresizingMask = [.width, .height]
        effect.frame = content.bounds
        content.addSubview(effect)

        let layerHost = NSView(frame: content.bounds)
        layerHost.autoresizingMask = [.width, .height]
        layerHost.wantsLayer = true
        layerHost.layer = root
        content.addSubview(layerHost)
        dim.backgroundColor = NSColor.black.cgColor
        root.addSublayer(dim)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 1600
        stage.sublayerTransform = perspective
        root.addSublayer(stage)
        for (sheet, shade) in [(leftSheet, leftShade), (rightSheet, rightShade)] {
            sheet.isDoubleSided = true
            shade.backgroundColor = NSColor.black.cgColor
            shade.opacity = 0
            sheet.addSublayer(shade)
            stage.addSublayer(sheet)
        }
        hinge.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        hinge.shadowColor = NSColor.white.cgColor
        hinge.shadowRadius = 8
        hinge.shadowOpacity = 0.8
        hinge.shadowOffset = .zero
        hinge.opacity = 0
        stage.addSublayer(hinge)

        if let badgeModel {
            let host = NSHostingView(rootView: AnyView(CoverBadge(model: badgeModel)))
            host.frame = content.bounds
            host.autoresizingMask = [.width, .height]
            content.addSubview(host)
            badge = host
        }
        panel.contentView = content
        layout(size: screen.frame.size)
    }

    func resize(to frame: NSRect) {
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        layout(size: frame.size)
    }

    private func layout(size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: size)
        root.frame = bounds
        dim.frame = bounds
        stage.frame = bounds
        let half = CGSize(width: size.width / 2, height: size.height)
        leftSheet.bounds = CGRect(origin: .zero, size: half)
        rightSheet.bounds = CGRect(origin: .zero, size: half)
        hinge.frame = CGRect(x: size.width / 2 - 1, y: 0, width: 2, height: size.height)
        leftShade.frame = leftSheet.bounds
        rightShade.frame = rightSheet.bounds
        CATransaction.commit()
    }

    /// Instantly opaque; the style animation then plays over already-hidden content.
    func show(style: CoverStyle, animated: Bool) {
        hideGeneration += 1
        let size = panel.frame.size
        let wasVisible = panel.isVisible && panel.alphaValue == 1 && self.style == style
        self.style = style
        panel.alphaValue = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.removeAllAnimations(); badge?.layer?.removeAllAnimations()
        for layer in [dim, stage, leftSheet, rightSheet, leftShade, rightShade, hinge] { layer.removeAllAnimations() }
        effect.isHidden = style == .black
        dim.opacity = style == .black ? 1 : style == .frosted ? 0.18 : 0.12
        stage.isHidden = !(style == .fold || style == .curtain)
        badge?.alphaValue = 1
        configureSheets(for: style, size: size)
        setSheets(closed: true, size: size) // final, covering geometry
        CATransaction.commit()
        panel.orderFrontRegardless()
        guard animated, !wasVisible else { return }
        switch style {
        case .fold: animateFold(opening: true, size: size)
        case .curtain: animateCurtain(closing: true, size: size)
        default: break
        }
        if style == .fold || style == .curtain { fadeBadgeIn(delay: 0.35) }
    }

    /// Reveals the screen; `completion` runs after the panel is ordered out.
    func hide(animated: Bool, completion: (() -> Void)? = nil) {
        guard panel.isVisible else { completion?(); return }
        hideGeneration += 1
        let generation = hideGeneration
        let size = panel.frame.size
        let duration: TimeInterval
        if animated {
            badge?.animator().alphaValue = 0
            switch style {
            case .fold: animateFold(opening: false, size: size); duration = 0.42
            case .curtain: animateCurtain(closing: false, size: size); duration = 0.45
            default: duration = 0
            }
        } else { duration = 0 }
        let finish = { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            if animated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.22
                    self.panel.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.hideGeneration == generation else { return }
                        self.panel.orderOut(nil)
                        self.panel.alphaValue = 1
                        completion?()
                    }
                })
            } else {
                self.panel.orderOut(nil)
                completion?()
            }
        }
        if duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { finish() }
        } else { finish() }
    }

    /// Live frosted glass keeps WindowServer recomputing the blur (~10% CPU). When
    /// nobody is there to see it, settle on solid black and drop the blur.
    func fadeToBlack() {
        guard panel.isVisible, !effect.isHidden else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = dim.opacity
        fade.toValue = 1
        fade.duration = 1.2
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in self?.effect.isHidden = true }
        }
        dim.opacity = 1
        dim.add(fade, forKey: "toBlack")
        stage.isHidden = true
        CATransaction.commit()
    }

    // MARK: Sheets

    private func configureSheets(for style: CoverStyle, size: CGSize) {
        switch style {
        case .fold:
            // Smoked glass panels, like the two halves of a folding display.
            for (sheet, flip) in [(leftSheet, false), (rightSheet, true)] {
                sheet.colors = [NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 0.86).cgColor,
                                NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.23, alpha: 0.86).cgColor,
                                NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.86).cgColor]
                sheet.locations = [0, 0.55, 1]
                sheet.startPoint = CGPoint(x: flip ? 1 : 0, y: 1)
                sheet.endPoint = CGPoint(x: flip ? 0 : 1, y: 0)
            }
        case .curtain:
            // Vertical pleats: alternating light/dark bands of a deep charcoal velvet.
            let pleats = 14
            var colors: [CGColor] = [], locations: [NSNumber] = []
            for i in 0...pleats {
                let t = Double(i) / Double(pleats)
                let light = i % 2 == 0
                colors.append(NSColor(calibratedRed: light ? 0.20 : 0.11, green: light ? 0.17 : 0.09, blue: light ? 0.24 : 0.14, alpha: 0.97).cgColor)
                locations.append(NSNumber(value: t))
            }
            for sheet in [leftSheet, rightSheet] {
                sheet.colors = colors
                sheet.locations = locations
                sheet.startPoint = CGPoint(x: 0, y: 0.5)
                sheet.endPoint = CGPoint(x: 1, y: 0.5)
            }
        default: break
        }
    }

    private func setSheets(closed: Bool, size: CGSize) {
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        leftSheet.anchorPoint = CGPoint(x: 1, y: 0.5)
        rightSheet.anchorPoint = CGPoint(x: 0, y: 0.5)
        leftSheet.position = mid
        rightSheet.position = mid
        leftSheet.transform = CATransform3DIdentity
        rightSheet.transform = CATransform3DIdentity
        leftShade.opacity = 0; rightShade.opacity = 0
        hinge.opacity = 0
    }

    private static let edgeOn = CGFloat.pi / 2 * 0.985

    /// Fold: both halves swing about the center hinge, like a folding phone opening
    /// flat (cover) or closing to a thin line (reveal).
    private func animateFold(opening: Bool, size: CGSize) {
        let duration = opening ? 0.62 : 0.4
        let timing = opening ? CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) : CAMediaTimingFunction(controlPoints: 0.6, 0, 0.84, 0.4)
        for (sheet, shade, sign) in [(leftSheet, leftShade, CGFloat(-1)), (rightSheet, rightShade, CGFloat(1))] {
            let folded = CATransform3DMakeRotation(sign * Self.edgeOn, 0, 1, 0)
            let rotation = CABasicAnimation(keyPath: "transform")
            rotation.fromValue = opening ? folded : CATransform3DIdentity
            rotation.toValue = opening ? CATransform3DIdentity : folded
            let shading = CABasicAnimation(keyPath: "opacity")
            shading.fromValue = opening ? 0.75 : 0
            shading.toValue = opening ? 0 : 0.75
            for (layer, animation) in [(sheet as CALayer, rotation as CABasicAnimation), (shade, shading)] {
                animation.duration = duration
                animation.timingFunction = timing
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
                layer.add(animation, forKey: "fold")
            }
        }
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = opening ? [1, 0.6, 0] : [0, 0.6, 1]
        glow.keyTimes = [0, 0.5, 1]
        glow.duration = duration
        glow.fillMode = .forwards
        glow.isRemovedOnCompletion = false
        hinge.add(glow, forKey: "fold")
    }

    /// Curtain: two pleated panels slide in from the screen edges and meet in the middle.
    private func animateCurtain(closing: Bool, size: CGSize) {
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        for (sheet, offstage) in [(leftSheet, CGPoint(x: 0, y: mid.y)), (rightSheet, CGPoint(x: size.width, y: mid.y))] {
            let slide: CAAnimation
            if closing {
                let spring = CASpringAnimation(keyPath: "position")
                spring.fromValue = offstage
                spring.toValue = mid
                spring.damping = 18
                spring.stiffness = 170
                spring.mass = 1
                spring.duration = min(spring.settlingDuration, 0.8)
                slide = spring
            } else {
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = mid
                move.toValue = offstage
                move.duration = 0.45
                move.timingFunction = CAMediaTimingFunction(name: .easeIn)
                slide = move
            }
            slide.fillMode = .forwards
            slide.isRemovedOnCompletion = false
            sheet.add(slide, forKey: "curtain")
        }
    }

    private func fadeBadgeIn(delay: TimeInterval) {
        badge?.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self?.badge?.animator().alphaValue = 1
            }
        }
    }
}

/// Covers every display for Nearby people / Recognize me without screen capture.
@MainActor
final class PrivacyCover {
    let badge = CoverBadgeModel()
    var includeInCaptures = false {
        didSet { for surface in surfaces.values { surface.panel.sharingType = includeInCaptures ? .readOnly : .none } }
    }
    private(set) var isCovered = false
    /// Development preview: cover only this rectangle of the main display.
    var previewFrame: NSRect?
    private var style = CoverStyle.fold
    private var surfaces: [CGDirectDisplayID: CoverSurface] = [:]
    private var keepAlive: Timer?
    private var blackTimer: Timer?

    /// Fade to black after `delay` seconds of being covered; nil cancels.
    func fadeToBlack(after delay: TimeInterval?) {
        guard let delay else { blackTimer?.invalidate(); blackTimer = nil; return }
        guard isCovered, blackTimer == nil else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCovered else { return }
                for surface in self.surfaces.values { surface.fadeToBlack() }
            }
        }
        timer.tolerance = 2
        blackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func show(style: CoverStyle) {
        let animated = !isCovered || style != self.style
        reconcileScreens()
        isCovered = true
        self.style = style
        for surface in surfaces.values { surface.show(style: style, animated: animated) }
        // Another app's panel can be ordered above ours; reassert like the other shields.
        if keepAlive == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isCovered else { return }
                    for surface in self.surfaces.values where !surface.panel.isVisible || !surface.panel.isOnActiveSpace {
                        surface.panel.orderFrontRegardless()
                    }
                }
            }
            keepAlive = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Makes the main display's cover the key window without activating the app, so
    /// keystrokes reach QuietGlass (any-key unlock) instead of the hidden apps. No
    /// Input Monitoring permission is needed for this.
    func captureKeyboard() {
        guard isCovered, let primary = NSScreen.screens.first,
              let id = (primary.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let panel = surfaces[id]?.panel else { return }
        panel.becomesKeyOnlyIfNeeded = false
        panel.makeKey()
    }

    func hide(animated: Bool = true) {
        guard isCovered else { return }
        isCovered = false
        keepAlive?.invalidate(); keepAlive = nil
        blackTimer?.invalidate(); blackTimer = nil
        for surface in surfaces.values { surface.hide(animated: animated) }
    }

    func reconcileScreens() {
        var current = Set<CGDirectDisplayID>()
        let primary = NSScreen.screens.first
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            current.insert(id)
            if previewFrame != nil && screen != primary { continue }
            if let surface = surfaces[id] { surface.resize(to: previewFrame ?? screen.frame) }
            else {
                // Prompts and the unlock button live on the main display only.
                let surface = CoverSurface(screen: screen, badgeModel: screen == primary ? badge : nil, includeInCaptures: includeInCaptures)
                if let previewFrame { surface.resize(to: previewFrame) }
                surfaces[id] = surface
            }
        }
        for id in Set(surfaces.keys).subtracting(current) { surfaces.removeValue(forKey: id)?.panel.close() }
        if isCovered { for surface in surfaces.values where !surface.panel.isVisible { surface.show(style: style, animated: false) } }
    }
}
