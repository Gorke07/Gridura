import AppKit

/// Application delegate: launch, activation, reopen, terminate.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let helperWindowIdentifiers: Set<String> = [
        "UninstallWindow", "PermissionsWindow", "PreferencesWindow",
        "ActivationWindow", "PaywallWindow", "ReorganizeLayoutWindow",
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "N/A"
        let build = info["CFBundleVersion"] as? String ?? "N/A"
        LogManager.shared.info("Application Launch \(version)(\(build))")
        // The overlay must keep rendering (open/close animations, wallpaper updates) even while
        // the app is inactive; App Nap freezes the window commits and stale frames stay on screen.
        ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                              reason: "Gridura overlay rendering")
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["GRIDURA_SELFTEST"] {
            SelfTest.run(test)
            return
        }
        #endif
        applySelectedAppIcon()
        iconObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NotificationChannel.appIconChangedDistributedName, object: nil, queue: .main) { [weak self] _ in
                self?.applySelectedAppIcon()
            })
        iconObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                self?.applySelectedAppIcon()
            })
        LaunchpadManager.shared.setup()
        if ProcessInfo.processInfo.environment["GRIDURA_DEBUG_WINDOWS"] != nil {
            dumpWindows()
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in self.dumpWindows() }
        }
    }

    private var iconObservers: [NSObjectProtocol] = []

    /// The Dock shows the icon picked in Settings › General (light or dark art by system theme).
    private func applySelectedAppIcon() {
        let type = AppState.shared.appIcon
        let name = "AppIcon/\(type.assetBase)-\(IconAppearanceSuffix.current())"
        if let image = NSImage(named: name) { NSApp.applicationIconImage = image }
    }

    private func dumpWindows() {
        for window in NSApp.windows {
            LogManager.shared.info("WINDOW id=\(window.identifier?.rawValue ?? "-") visible=\(window.isVisible) level=\(window.level.rawValue) frame=\(window.frame) class=\(type(of: window)) alpha=\(window.alphaValue)")
        }
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        // The Accessibility permission may have been granted while we were in the background.
        InputEventMonitor.shared.updateMonitoring(force: false, reason: "application became active")
        for window in NSApp.windows where window.isVisible && window.alphaValue > 0 && !window.isMiniaturized {
            let id = window.identifier?.rawValue ?? ""
            if ["UninstallWindow", "PermissionsWindow", "PreferencesWindow"].contains(id) {
                window.level = NSWindow.Level(rawValue: 1001)
            }
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.handleResignActive() }
    }

    private func handleResignActive() {
        let front = NSWorkspace.shared.frontmostApplication
        let visible = NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 && !$0.isMiniaturized }
        let noUninstallWindow = !visible.contains { $0.identifier?.rawValue == "UninstallWindow" }
        if front?.bundleIdentifier != "com.apple.SecurityAgent" || noUninstallWindow {
            for window in visible where helperWindowIdentifiers.contains(window.identifier?.rawValue ?? "") {
                window.level = .normal
            }
            let controller = LaunchpadWindowController.shared
            controller.presentationRequestID += 1
            if controller.window?.isVisible == true { controller.hide() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !AppState.shared.isFirstLaunch { LaunchpadWindowController.shared.toggle() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        LaunchpadDataManager.shared.flushPendingSync()
        LaunchpadManager.shared.teardown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
