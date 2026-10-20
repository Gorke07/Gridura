import AppKit

/// Adds an app to the Dock by editing the Dock's persistent-apps list in its preferences and restarting the Dock.
/// (No Apple Events: they would need an Automation permission and System Events has no "add to dock" command.)
enum DockHelper {
    /// The preferences domain of the Dock; tests point it at a scratch domain and keep the Dock running.
    static var dockDomain = "com.apple.dock"
    static var restartsDock = true

    private static func persistentApps() -> [[String: Any]] {
        CFPreferencesCopyAppValue("persistent-apps" as CFString, dockDomain as CFString) as? [[String: Any]] ?? []
    }

    static func isInDock(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        for entry in persistentApps() {
            if let tileData = entry["tile-data"] as? [String: Any],
               let fileData = tileData["file-data"] as? [String: Any],
               let value = fileData["_CFURLString"] as? String {
                if URL(string: value)?.standardizedFileURL.path == path { return true }
            }
        }
        return false
    }

    /// The Dock tile for an app bundle, in the shape the Dock itself writes.
    static func tile(for url: URL) -> [String: Any] {
        let bundle = Bundle(url: url)
        let name = (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        var tileData: [String: Any] = [
            "file-data": ["_CFURLString": url.standardizedFileURL.absoluteString.hasSuffix("/")
                              ? url.standardizedFileURL.absoluteString : url.standardizedFileURL.absoluteString + "/",
                          "_CFURLStringType": 15],
            "file-label": name,
            "file-type": 41,
        ]
        if let id = bundle?.bundleIdentifier { tileData["bundle-identifier"] = id }
        return ["tile-data": tileData, "tile-type": "file-tile"]
    }

    @discardableResult
    static func addToDock(_ url: URL) -> Bool {
        guard !isInDock(url) else { return true }
        var apps = persistentApps()
        apps.append(tile(for: url))
        CFPreferencesSetAppValue("persistent-apps" as CFString, apps as CFArray, dockDomain as CFString)
        guard CFPreferencesAppSynchronize(dockDomain as CFString) else {
            LogManager.shared.error("Failed to write the Dock preferences")
            return false
        }
        if restartsDock {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            task.arguments = ["Dock"]
            try? task.run()
        }
        return true
    }

    /// Gridura itself: a copy running from a disk image or an App Translocation path would leave a dead Dock
    /// tile, so the app has to live in an Applications folder first.
    static func addSelfToDock() {
        let url = Bundle.main.bundleURL
        let path = url.standardizedFileURL.path
        let home = NSHomeDirectory() + "/Applications/"
        guard path.hasPrefix("/Applications/") || path.hasPrefix(home) else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Move Gridura to Applications first", comment: "")
            alert.informativeText = NSLocalizedString("Drag Gridura into your Applications folder, open it from there, and add it to the Dock again.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.window.level = NSWindow.Level(rawValue: 1002)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        addToDock(url)
    }
}

/// Finder "Get Info" via AppleScript.
enum FinderHelper {
    static func showGetInfo(for url: URL) {
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(path)" as alias)
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { LogManager.shared.error("Failed to show Finder Get Info: \(error)") }
    }
}
