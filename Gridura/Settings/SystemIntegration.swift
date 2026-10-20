import Foundation
import AppKit
import ApplicationServices
import ServiceManagement

/// Start at Login via `SMAppService.mainApp`.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            LogManager.shared.error("[ERROR] Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)")
        }
    }
}

/// Accessibility permission check used by the F4 / trackpad rows.
enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt, then refreshes the event taps. From Settings the launcher window is
    /// hidden when access is still missing so the system dialog is not covered.
    @discardableResult
    static func request(hideLauncherIfDenied: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        if !granted && hideLauncherIfDenied {
            let controller = LaunchpadWindowController.shared
            controller.presentationRequestID += 1
            if controller.window?.isVisible == true { controller.hide() }
        }
        InputEventMonitor.shared.updateMonitoring(force: false, reason: "accessibility permission refreshed")
        return granted
    }
}

/// System hot-corner conflict check.
enum HotCornerConflict {
    /// Dock preference prefixes in corner order: top-left, top-right, bottom-left, bottom-right.
    private static let prefixes = ["wvous-tl", "wvous-tr", "wvous-bl", "wvous-br"]

    /// True when macOS already assigns an action to that corner (a corner that needs a modifier key
    /// or has no action does not conflict).
    static func conflicts(corner: HotCornerType) -> Bool {
        guard corner != .off else { return false }
        let index = Int(corner.rawValue)
        guard index >= 0, index < prefixes.count else { return false }
        let prefix = prefixes[index]
        let dock = "com.apple.dock" as CFString
        guard let action = CFPreferencesCopyAppValue((prefix + "-corner") as CFString, dock) as? NSNumber else { return false }
        if action.intValue == 1 { return false }                    // 1 = "–" (no action)
        guard let modifier = CFPreferencesCopyAppValue((prefix + "-modifier") as CFString, dock) as? NSNumber else { return true }
        return modifier.intValue == 0                               // needs a modifier key → no conflict
    }
}

/// The current macOS icon appearance suffix ("Light" / "Dark").
enum IconAppearanceSuffix {
    static func current() -> String {
        if let theme = CFPreferencesCopyAppValue("AppleIconAppearanceTheme" as CFString, kCFPreferencesAnyApplication) as? String {
            switch theme {
            case "RegularDark", "ClearDark", "TintedDark":
                return "Dark"
            case "RegularLight", "ClearLight", "TintedLight":
                return "Light"
            default:
                break
            }
            if theme.hasSuffix("Automatic") {
                return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "Dark" : "Light"
            }
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "Dark" : "Light"
    }
}
