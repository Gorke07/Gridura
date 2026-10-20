import AppKit

/// Entry point of the uninstall flow: Pro gate, Full Disk Access gate, then the
/// uninstall panel.
final class UninstallCoordinator {
    static let shared = UninstallCoordinator()

    private init() {}

    func begin(app: LaunchpadApp) {
        guard !app.isSourceUnavailable else { return }          // external volume not mounted
        guard PrivacyHelper.hasFullDiskAccess else {
            PermissionsWindowController.shared.show()
            return
        }
        UninstallWindowController.shared.show(app: app, icon: AppIconRepository.shared.cachedImage(for: app.url))
    }
}

enum PrivacyHelper {
    /// Full Disk Access probe: the first of `~/Library/{Mail,Messages,Safari}` that exists and is
    /// readable means access is granted.
    static var hasFullDiskAccess: Bool {
        let fm = FileManager.default
        for relative in ["Library/Mail", "Library/Messages", "Library/Safari"] {
            let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relative, isDirectory: true).path
            guard fm.fileExists(atPath: path) else { continue }
            if (try? fm.contentsOfDirectory(atPath: path)) != nil { return true }
        }
        return false
    }
}
