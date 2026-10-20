import AppKit

/// Wires the triggers: FSEvents, menu bar, license, input monitor, hot corner, hotkey
///.
final class LaunchpadManager {
    static let shared = LaunchpadManager()

    private unowned let appState = AppState.shared
    let hotCornersMonitor = HotCornersMonitor.shared
    let inputEventMonitor = InputEventMonitor.shared
    let finderMonitor = FinderMonitor.shared

    private init() {}

    func setup() {
        finderMonitor.onChanged = { [weak self] in
            NotificationChannel.center.post(name: NotificationChannel.Name.scanApp, object: nil)
            _ = self
        }
        finderMonitor.start()

        // A fresh store (new profile, or the guide was skipped) has no apps yet: fill it now so the
        // grid is never empty; the guide's own scan then just diffs.
        let context = PersistenceController.shared.viewContext
        if ((try? context.count(for: AppEntity.fetchRequest())) ?? 0) == 0 {
            ApplicationManager.shared.scan(fromBackup: false) {
                LaunchpadDataManager.shared.load(nil)
            }
        }

        MenuBarManager.shared.updateStatusItem()
        UpdateManager.shared.startPeriodicChecks()

        setupInputMonitor()
        setupHotCorner()

        HotKeyCenter.shared.onTriggered = { LaunchpadWindowController.shared.toggle() }
        HotKeyCenter.shared.start()

        if launchedAsLoginItem() {
            LogManager.shared.info("login item silent launch")
        } else if appState.isFirstLaunch {
            PreferencesWindowController.shared.showGuide()
        } else {
            LaunchpadWindowController.shared.toggle()
        }
    }

    private func setupInputMonitor() {
        inputEventMonitor.onF4Pressed = { LaunchpadWindowController.shared.toggle() }
        inputEventMonitor.onGestureBegan = { gesture in
            LaunchpadWindowController.shared.handleGestureBegan(gesture)
        }
        inputEventMonitor.onGestureProgress = { gesture, progress in
            LaunchpadWindowController.shared.handleGestureProgress(gesture, progress: progress)
        }
        inputEventMonitor.onGestureCompleted = { gesture, progress in
            LaunchpadWindowController.shared.handleGestureCompleted(gesture, progress: progress)
        }
        inputEventMonitor.start(reason: "application launch")
    }

    private func setupHotCorner() {
        let monitor = hotCornersMonitor
        monitor.onTriggered = {
            LaunchpadWindowController.shared.toggle()
        }
        if appState.hotCorner != .off {
            monitor.monitoredCorner = appState.hotCorner
            monitor.start()
        }
    }

    func teardown() {
        inputEventMonitor.stop()
        hotCornersMonitor.stop()
        finderMonitor.stop()
        HotKeyCenter.shared.stop()
        UpdateManager.shared.stopPeriodicChecks()
    }

    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Applies a hot-corner change from settings.
    /// Settings change: stop, then restart with the new corner unless it is off.
    func hotCornerSettingChanged() {
        hotCornersMonitor.stop()
        guard appState.hotCorner != .off else { return }
        hotCornersMonitor.monitoredCorner = appState.hotCorner
        hotCornersMonitor.start()
    }
}

/// The `@main` entry type. A plain Swift entry that installs an
/// `AppDelegate`, matching the original (`NSPrincipalClass = NSApplication`, `LSUIElement`).
@main
enum GriduraApplication {
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
