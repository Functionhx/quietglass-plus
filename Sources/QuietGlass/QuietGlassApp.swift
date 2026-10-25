// Clinton Imaro was here 20/09/2026.

import AppKit
import Combine
import ShieldCore

@main
struct QuietGlassApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--headphone-check") {
            // Development aid: voice-guided check of HID earbud head tracking.
            let check = HeadphoneCheck()
            check.run()
            withExtendedLifetime(check) { app.run() }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--preview-cover") {
            // Development aid: cover, hold, reveal and quit, without camera or settings.
            let style = CoverStyle(rawValue: CommandLine.arguments.dropFirst(index + 1).first ?? "") ?? .fold
            let cover = PrivacyCover()
            cover.includeInCaptures = true
            if let screen = NSScreen.main {
                let size = NSSize(width: 960, height: 600)
                cover.previewFrame = NSRect(x: screen.frame.maxX - size.width - 20, y: screen.frame.minY + 20, width: size.width, height: size.height)
            }
            cover.badge.title = String(localized: "No face in view")
            cover.badge.detail = String(localized: "Look at the camera to unlock")
            cover.badge.canUnlock = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cover.show(style: style) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { cover.hide() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
            withExtendedLifetime(cover) { app.run() }
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var notch: NotchBarController!
    private var privacySettings: PrivacySettingsController!
    private var headSetup: HeadSetupController!
    private var profilePicker: ProfilePickerController!
    private var keyMonitor: Any?
    private var observation: AnyCancellable?
    private var floatingObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        QuietGlassIntentBridge.model = model
        if Bundle.main.url(forResource: "Metadata", withExtension: "appintents") != nil {
            QuietGlassShortcuts.updateAppShortcutParameters()
        }
        notch = NotchBarController(model: model)
        privacySettings = PrivacySettingsController(model: model)
        headSetup = HeadSetupController(model: model)
        profilePicker = ProfilePickerController(model: model)
        model.onShowProfiles = { [weak self] anchor, fromControls in
            guard let self else { return }
            if fromControls { self.notch.showProfiles(self.profilePicker) }
            else { self.profilePicker.show(relativeTo: anchor, fromControls: false) }
        }
        model.privacy.onPrepareAreaSelection = { [weak self] in
            self?.notch.closeControls()
            self?.privacySettings.hideForAreaSelection()
        }
        model.onOpenPrivacySettings = { [weak self] in self?.showPrivacySettings() }
        model.onOpenProfileSettings = { [weak self] in self?.notch.closeControls(); self?.privacySettings.showProfiles() }
        model.onOpenNearbySettings = { [weak self] in self?.notch.closeControls(); self?.privacySettings.showNearbyPeople() }
        model.onOpenControls = { [weak self] in
            self?.privacySettings.hideForAreaSelection()
            self?.notch.showControls()
        }
        model.onRequestHeadSetup = { [weak self] in self?.notch.closeControls(); self?.headSetup.show() }
        model.onCancelHeadSetup = { [weak self] in self?.headSetup.close() }
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: L("QuietGlass"))
        item("About QuietGlass", #selector(showAbout), in: applicationMenu)
        applicationMenu.addItem(.separator())
        item("Settings…", #selector(showPrivacySettings), in: applicationMenu, key: ",")
        item("Downloads & Updates…", #selector(showDownloads), in: applicationMenu)
        item("Check for Updates…", #selector(checkForUpdates), in: applicationMenu)
        applicationMenu.addItem(.separator())
        item("Quit QuietGlass", #selector(quit), in: applicationMenu, key: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let viewItem = NSMenuItem(title: L("View"), action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: L("View"))
        let sidebar = item("Toggle Sidebar", #selector(toggleSettingsSidebar), in: viewMenu, key: "s")
        sidebar.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(.separator())
        let fullScreen = NSMenuItem(title: L("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreen)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let helpItem = NSMenuItem(title: L("Help"), action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: L("Help"))
        item("QuietGlass Help", #selector(showHelp), in: helpMenu)
        item("Report an Issue…", #selector(reportIssue), in: helpMenu)
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = AppIcon.view.image()
        statusItem.button?.setAccessibilityLabel("QuietGlass")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        buildMenu(menu)
        observation = model.$coverage.combineLatest(model.privacy.$instant).sink { [weak self] value, instant in
            self?.statusItem.button?.image = (value > 0 || instant ? AppIcon.viewOff : .view).image()
        }
        floatingObservation = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateFloatingControls()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Away cover holds keyboard focus: any key is an unlock attempt and never
            // reaches the hidden apps.
            if self.model.away.covered {
                self.model.unlockAway()
                return nil
            }
            if self.model.recordingShortcut {
                self.model.recordShortcut(event)
                return nil
            }
            if event.keyCode == 53, self.model.headSetupActive {
                self.headSetup.close()
                return nil
            }
            if event.keyCode == 53, self.model.coverage > 0 || self.model.privacy.wantsProtection {
                self.model.dismissShield()
                return nil
            }
            if event.keyCode == 53 { self.notch.closeControls() }
            return event
        }
        // The floating control bar is opt-in (menu bar → Show Floating Controls);
        // everything on it is also in the menu bar menu.
        if Self.showsFloatingControls { notch.show() }
        // Settings opens on its own only until camera protection is set up, so a
        // login launch stays out of the way.
        if !model.cameraProtectionOn { privacySettings.show() }
        if UserDefaults.standard.bool(forKey: "showControlsAfterRelaunch") {
            UserDefaults.standard.removeObject(forKey: "showControlsAfterRelaunch")
            if Self.showsFloatingControls { notch.showControls() } else { privacySettings.show() }
        }
        model.nearby.restore()
        model.away.restore()
        // Documentation screenshots: open straight to camera protection.
        if CommandLine.arguments.contains("--show-nearby-settings") {
            privacySettings.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.privacySettings.showNearbyPeople() }
        }
        model.updates.checkIfDue()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu(menu) }

    func applicationDidResignActive(_ notification: Notification) {
        if NSApp.activationPolicy() == .regular, !privacySettings.isVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: L("QuietGlass · ") + L(model.status), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let profiles = NSMenuItem(title: L("Profile"), action: nil, keyEquivalent: "")
        let profileMenu = NSMenu(title: L("Profile"))
        for profile in PrivacyProfile.allCases {
            let entry = item(profile.title, #selector(selectProfile(_:)), in: profileMenu)
            entry.representedObject = profile.rawValue
            entry.state = model.currentProfile == profile ? .on : .off
        }
        profiles.submenu = profileMenu
        menu.addItem(profiles)
        item("Control", #selector(showControls), in: menu)
        item("Settings…", #selector(showPrivacySettings), in: menu)
        item(notch.isVisible ? "Hide Notch" : "Show Notch", #selector(toggleNotch), in: menu)
        item("Move Notch Down", #selector(resetNotch), in: menu)
        menu.addItem(.separator())
        item(model.privacy.instant ? "Clear Privacy Blur" : "Blur Screen", #selector(togglePrivacy), in: menu, shortcut: "⌃⌥⌘P")
        item("Blur an Area", #selector(chooseArea), in: menu, shortcut: model.areaShortcutLabel)
        item(model.enabled ? "Pause Head Tracking" : "Start Head Tracking", #selector(toggleTracking), in: menu)
        let center = item("Center My Gaze", #selector(recenter), in: menu, shortcut: model.shortcutLabel)
        center.isEnabled = model.canRecenter
        item(model.previewing ? "Clear Preview" : "Preview Blur for 5 Seconds", #selector(preview), in: menu)
        item("Clear Screen", #selector(clear), in: menu)
        menu.addItem(.separator())
        item("About QuietGlass", #selector(showAbout), in: menu)
        item("QuietGlass Help", #selector(showHelp), in: menu)
        item("Downloads & Updates…", #selector(showDownloads), in: menu)
        menu.addItem(.separator())
        item("Quit QuietGlass", #selector(quit), in: menu, key: "q")
    }

    @discardableResult private func item(_ title: String, _ action: Selector, in menu: NSMenu,
                                        key: String = "", shortcut: String? = nil) -> NSMenuItem {
        let displayTitle = shortcut.map { "\(L(title))    \($0)" } ?? L(title)
        let entry = NSMenuItem(title: displayTitle, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let profile = PrivacyProfile(rawValue: raw) { model.applyProfile(profile) }
    }

    @objc private func toggleSettingsSidebar() { privacySettings.toggleSidebar() }
    @objc private func showControls() { notch.showControls() }
    @objc private func showPrivacySettings() { notch.closeControls(); privacySettings.show() }
    @objc private func togglePrivacy() { model.toggleInstantShield() }
    @objc private func chooseArea() { model.privacy.chooseArea() }
    private static var showsFloatingControls: Bool { UserDefaults.standard.bool(forKey: "showFloatingControls") }

    /// Unless pinned, the floating controls appear only while a captured blur (instant
    /// blur, a window, an area, Focus, head-tracking blur) is on, offering a way out.
    /// The capture-free cover carries its own exit button above them.
    private func updateFloatingControls() {
        guard !Self.showsFloatingControls else { return }
        let privacy = model.privacy
        let blurring = !model.cover.isCovered && (model.coverage > 0.001 || privacy.fullScreen ||
            (!privacy.paused && (privacy.selectedWindow != nil || !privacy.protectedAreas.isEmpty || privacy.focusEnabled)))
        if blurring && !notch.isVisible { notch.show() }
        else if !blurring && notch.isVisible { notch.hide() }
    }
    @objc private func toggleNotch() {
        notch.toggleVisibility()
        UserDefaults.standard.set(notch.isVisible, forKey: "showFloatingControls")
    }
    @objc private func resetNotch() {
        notch.resetPosition(); notch.show()
        UserDefaults.standard.set(true, forKey: "showFloatingControls")
    }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Privacy for what’s on your Mac.\nBuilt by Clinton Imaro · Open source under the MIT License.")
        ])
    }
    @objc private func showHelp() {
        if let guide = Bundle.main.url(forResource: "QuietGlass Help", withExtension: "html") {
            NSWorkspace.shared.open(guide)
        }
    }
    @objc private func showDownloads() { openProjectPage("releases/latest") }
    @objc private func checkForUpdates() { privacySettings.showUpdates(); Task { await model.updates.check() } }
    @objc private func reportIssue() { openProjectPage("issues") }
    private func openProjectPage(_ path: String) {
        guard let url = URL(string: "https://github.com/clintonimaroo/quietglass/\(path)") else { return }
        NSWorkspace.shared.open(url)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        privacySettings.show()
        if Self.showsFloatingControls { notch.show() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        profilePicker.hide()
        model.shutdown()
        notch.shutdown()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    @objc private func toggleTracking() { model.setEnabled(!model.enabled) }
    @objc private func recenter() { model.recenter() }
    @objc private func preview() { notch.preview() }
    @objc private func clear() { model.dismissShield() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
