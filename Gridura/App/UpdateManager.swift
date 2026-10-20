import AppKit
import Sparkle

/// Updates through Sparkle: the appcast at `SUFeedURL` lists releases, and only archives
/// signed with the EdDSA key behind `SUPublicEDKey` are installed. See docs/release.md.
///
/// Gridura is an agent app, so scheduled checks use Sparkle's "gentle reminders": they never pop a window;
/// the search-bar badge, the menu items and the General tab bar show `availableVersion` instead, and the
/// Update buttons open Sparkle's own window.
final class UpdateManager: NSObject {
    static let shared = UpdateManager()
    static let stateDidChange = Notification.Name("Gridura.UpdateStateDidChange")

    /// The newest version a check found (shown as a badge), nil when up to date or skipped.
    private(set) var availableVersion: String?
    /// A version Sparkle has already downloaded and will install (automatic downloads).
    private(set) var downloadedVersion: String?

    private var controller: SPUStandardUpdaterController!
    private var started = false

    private override init() {
        super.init()
        // Not started here: `startPeriodicChecks()` starts it once the launcher is up. Tests never start it.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            // Sparkle's windows must sit above the launcher (level 1002), like the original's.
            guard let window = note.object as? NSWindow, let owner = window.windowController,
                  Bundle(for: type(of: owner)).bundleIdentifier == "org.sparkle-project.Sparkle" else { return }
            window.level = NSWindow.Level(rawValue: 1002)
        }
    }

    // MARK: Settings (Sparkle keeps them in its own user defaults)

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    // MARK: Lifecycle

    /// Starts Sparkle, which then schedules its own automatic checks (daily by default).
    func startPeriodicChecks() {
        guard !started else { return }
        started = true
        controller.startUpdater()
    }

    /// Sparkle cannot be paused; kept so the app's teardown path stays symmetrical.
    func stopPeriodicChecks() {}

    // MARK: Actions

    /// User-initiated check (menu items, About tab, "New Version" bar): Sparkle shows the result.
    func checkForUpdates() {
        startPeriodicChecks()
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// "Install %@": Sparkle's window offers Install & Relaunch for the downloaded update.
    func installDownloadedUpdate() {
        checkForUpdates()
    }

    /// Silent check that only updates the badge (used by tests; Sparkle also does this on its schedule).
    func checkInBackground() {
        startPeriodicChecks()
        controller.updater.checkForUpdatesInBackground()
    }

    private func setAvailable(_ version: String?, downloaded: String? = nil) {
        guard availableVersion != version || downloadedVersion != downloaded else { return }
        availableVersion = version
        downloadedVersion = downloaded
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateManager: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["GRIDURA_TEST_FEED"]       // self-test appcast
        #else
        return nil
        #endif
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setAvailable(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        setAvailable(nil)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        // "You're up to date" arrives as an error; it is not a failure.
        if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) { return }
        LogManager.shared.error("Update check failed: \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        setAvailable(nil, downloaded: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        // "Skip This Version" removes the badge; "Remind Me Later" keeps it.
        if choice == .skip { setAvailable(nil) }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdateManager: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled checks never open a window in this agent app; the badge and menu items announce the update.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { setAvailable(update.displayVersionString) }
    }
}
