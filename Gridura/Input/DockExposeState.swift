import AppKit
import ApplicationServices

/// What the Dock is showing right now: normal, Mission Control, App Exposé or
/// Show Desktop, read from the Dock's accessibility tree and its window list.
enum DockExposeState {
    case normal, missionControl, appExpose, showDesktop

    static func current() -> DockExposeState {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return .normal
        }
        var state = scan(AXUIElementCreateApplication(dock.processIdentifier), depth: 0)
        if state == .normal && isShowDesktopActive(dockPID: dock.processIdentifier) { state = .showDesktop }
        return state
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func scan(_ element: AXUIElement, depth: Int) -> DockExposeState {
        guard depth < 2 else { return .normal }
        let identifiers = [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute]
            .compactMap { stringAttribute(element, $0) }
        if identifiers.contains(where: { ["mc", "AXMissionControlGroup", "AXMissionControlSpacesBarGroup"].contains($0) }) {
            return .missionControl
        }
        if identifiers.contains(where: { ["appexpose", "AXExposeWindowGroup"].contains($0) }) {
            return .appExpose
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return .normal }
        for child in list {
            if stringAttribute(child, kAXRoleAttribute) == "AXDockItem" { continue }     // skip dock tiles
            let result = scan(child, depth: depth + 1)
            if result != .normal { return result }
        }
        return .normal
    }

    private static func isShowDesktopActive(dockPID: pid_t) -> Bool {
        guard let main = NSScreen.main,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        if #unavailable(macOS 27) {
            return windows.contains {
                ($0[kCGWindowOwnerPID as String] as? Int32) == dockPID && ($0[kCGWindowLayer as String] as? Int) == 18
            }
        }
        guard let manager = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else {
            return false
        }
        let size = main.frame.standardized.size
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == manager.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int, [18, 19].contains(layer),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.standardized.size == size
        }
    }
}
