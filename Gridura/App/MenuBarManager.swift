import AppKit

/// Menu bar status item and its menu.
final class MenuBarManager: NSObject {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?

    private override init() { super.init() }

    func updateStatusItem() {
        if AppState.shared.showMenubarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                // A template image is tinted by the system like every other menu-bar icon (white on a dark bar).
                let icon = NSImage(named: "MenuBarIcon")
                icon?.isTemplate = true
                button.image = icon
                button.imageScaling = .scaleProportionallyUpOrDown
                button.imagePosition = .imageOnly
                button.target = self
                button.action = #selector(showMenu(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func showMenu(_ sender: Any?) {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            LaunchpadWindowController.shared.toggle()
            return
        }
        let menu = buildMenu()
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let settings = NSMenuItem(title: NSLocalizedString("Settings", comment: ""), action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        menu.addItem(settings)
        menu.addItem(.separator())

        let info = NSMenuItem(title: displayNameAndVersion, action: nil, keyEquivalent: "")
        info.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        info.isEnabled = false
        menu.addItem(info)

        let check = NSMenuItem(title: NSLocalizedString("Check for Updates", comment: ""), action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.image = NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90", accessibilityDescription: nil)
        menu.addItem(check)

        menu.addItem(.separator())

        let restart = NSMenuItem(title: NSLocalizedString("Restart", comment: ""), action: #selector(restart), keyEquivalent: "")
        restart.target = self
        restart.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(restart)

        let quit = NSMenuItem(title: NSLocalizedString("Quit", comment: ""), action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
        return menu
    }

    private var displayNameAndVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "N/A"
        let version = info["CFBundleShortVersionString"] as? String ?? "N/A"
        return "\(name) \(version)"
    }

    @objc private func openSettings() { PreferencesWindowController.shared.show() }
    @objc private func checkForUpdates() { UpdateManager.shared.checkForUpdates() }
    @objc func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                LogManager.shared.error("Failed to restart app: \(error.localizedDescription)")
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func quit() {
        let alert = NSAlert()
        alert.window.level = NSWindow.Level(rawValue: 1000)
        let info = Bundle.main.infoDictionary ?? [:]
        let displayName = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "N/A"
        alert.messageText = String(format: NSLocalizedString("Are you sure you want to quit %@?", comment: ""), displayName)
        alert.informativeText = NSLocalizedString("Once quit, Gridura won’t open from shortcuts or the menu bar. ", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }
}
