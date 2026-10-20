import AppKit

/// Adds an app to the Dock by editing the Dock's persistent-apps list.
enum DockHelper {
    static func isInDock(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard let persistent = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]]
        else { return false }
        for entry in persistent {
            if let tileData = entry["tile-data"] as? [String: Any],
               let fileData = tileData["file-data"] as? [String: Any],
               let value = fileData["_CFURLString"] as? String {
                if URL(string: value)?.standardizedFileURL.path == path { return true }
            }
        }
        return false
    }

    static func addToDock(_ url: URL) {
        guard !isInDock(url) else { return }
        let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "System Events"
            tell dock preferences
                set theList to persistent apps
            end tell
        end tell
        tell application "Finder"
            set theApp to POSIX file "\(escaped)" as alias
        end tell
        tell application "System Events" to add theApp to the dock
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { LogManager.shared.error("Failed to add app to Dock: \(error)") }
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
