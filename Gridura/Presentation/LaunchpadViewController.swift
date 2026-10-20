import AppKit

/// Hosts the grid inside the launchpad window: data wiring, observers and ReturnToHome
///.
final class LaunchpadViewController: NSViewController {
    private unowned let appState = AppState.shared
    private let dataManager = LaunchpadDataManager.shared

    private(set) var contentView: LaunchpadContentView
    private var eventObserver: NSObjectProtocol?
    private var globalMouseDownMonitor: Any?
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 2.0
    private var hasInitializedUpdateManager = false
    private var appearUpdateLayout = true
    private var iconAppearanceObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        contentView = LaunchpadContentView(variant: GlassVariant.variant(fullScreen: AppState.shared.displayMode == .fullScreen))
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentView.frame = view.bounds
        contentView.autoresizingMask = [.width, .height]
        view.addSubview(contentView)

        contentView.onRequestHideLauncher = { [weak self] in
            guard let window = self?.view.window as? AlwaysKeyPanel else { return }
            LaunchpadWindowController.shared.hide()
            _ = window
        }
        contentView.onOpenPreferences = { PreferencesWindowController.shared.show() }
        contentView.onOpenReorganize = { PreferencesWindowController.shared.showReorganize() }

        dataManager.didDataChange = { [weak self] update in
            self?.contentView.reload(update)
        }
        installObservers()
        contentView.showLoading()
        dataManager.load { [weak self] in
            self?.contentView.relayout()
        }
    }

    /// The display mode the window was last styled for (to tell a mode switch from a grid change).
    private var appliedDisplayMode = AppState.shared.displayMode
    private var updateObserver: NSObjectProtocol?

    /// Update badge + button artwork follow `UpdateManager`.
    private func refreshUpdateBadge() {
        let updates = UpdateManager.shared
        contentView.searchView.isUpdateVisible = updates.availableVersion != nil || updates.downloadedVersion != nil
        contentView.searchView.isUpdateReady = updates.downloadedVersion != nil
    }

    private func installObservers() {
        updateObserver = NotificationCenter.default.addObserver(
            forName: UpdateManager.stateDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.refreshUpdateBadge()
            }
        refreshUpdateBadge()
        eventObserver = NotificationChannel.center.addObserver(
            forName: nil, object: nil, queue: .main) { [weak self] note in
                self?.handleInternalNotification(note)
            }
        // The shipped app observes the non-public `NSWorkspaceIconAppearanceConfigurationDidChangeNotification`
        //. It is not exposed to Swift, so the same trigger is rebuilt from the
        // public theme-change notifications plus the effective-appearance KVO below.
        iconAppearanceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: ApplicationManager.iconAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.dataManager.load(nil)
            }
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                self?.dataManager.load(nil)
            }
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.dataManager.load(nil)
        }
    }

    private func handleInternalNotification(_ note: Notification) {
        switch note.name {
        case NotificationChannel.Name.preferencesChanged:
            guard let raw = note.object as? Int, let module = PreferenceModule(rawValue: raw) else { return }
            switch module {
            case .sortBy, .sortOrder, .browsingStyle, .hiddenAppsSearch:
                dataManager.publish(2)
            case .layout:
                // A display-mode switch re-styles the window; a grid-size change only re-frames it.
                if appliedDisplayMode != appState.displayMode {
                    appliedDisplayMode = appState.displayMode
                    LaunchpadWindowController.shared.applyDisplayMode()
                } else {
                    LaunchpadWindowController.shared.relayoutWindowFrame()
                }
                contentView.relayout()
            case .interface, .dockStyle:
                contentView.relayout()
            case .rearrange:
                dataManager.fillEmptySlots()
            case .background:
                break
            case .systemData:
                dataManager.load(nil)
            case .backupData:
                if let setting = note.userInfo?[NotificationChannel.UserInfoKey.setting] as? [String: Int] {
                    if let columns = setting["columns"] { appState.columnsPerPage = columns }
                    if let rows = setting["rows"] { appState.rowsPerPage = rows }
                    if let style = setting["browsingStyle"], let value = BrowsingStyleType(rawValue: style) {
                        appState.browsingStyle = value
                    }
                    dataManager.publish(2)
                    LaunchpadWindowController.shared.relayoutWindowFrame()
                }
            }
        case NotificationChannel.Name.scanApp:
            ApplicationManager.shared.scan(fromBackup: false) { [weak self] in
                self?.dataManager.load(nil)
            }
        case NotificationChannel.Name.refreshPendingIcon:
            guard let urls = note.userInfo?[NotificationChannel.UserInfoKey.urls] as? [URL], !urls.isEmpty else { return }
            let delay = note.userInfo?[NotificationChannel.UserInfoKey.delay] as? Double ?? 5.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.contentView.refreshIcons(urls: urls)
            }
        default:
            break
        }
    }

    // MARK: - Appearance

    override func viewWillAppear() {
        super.viewWillAppear()
        if shouldReturnToHome() { contentView.returnToFirstPage() }
        view.window?.makeFirstResponder(contentView)
        installGlobalMouseDownMonitor()
        if appearUpdateLayout {
            contentView.relayout()
            appearUpdateLayout = false
        }
        debounce(appearing: true)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        invalidateDebounce()
        removeGlobalMouseDownMonitor()
        appState.lastHiddenTime = Date().timeIntervalSince1970
        contentView.exitUninstallMode()
        contentView.clearSearchFromOutside()
        dataManager.currentSearchQuery = ""
        debounce(appearing: false)
    }

    private func shouldReturnToHome() -> Bool {
        switch appState.returnToHome {
        case .always: return true
        case .never: return false
        default:
            let last = appState.lastHiddenTime
            guard last > 0 else { return false }
            return Date().timeIntervalSince1970 - last >= appState.returnToHome.seconds
        }
    }

    private func debounce(appearing: Bool) {
        invalidateDebounce()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if appearing {
            } else {
                self.dataManager.load(nil)
            }
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
        _ = hasInitializedUpdateManager
    }

    private func invalidateDebounce() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    // MARK: - Global mouse monitor

    private func installGlobalMouseDownMonitor() {
        guard globalMouseDownMonitor == nil else { return }
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleGlobalClick(event)
        }
    }

    private func removeGlobalMouseDownMonitor() {
        if let monitor = globalMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseDownMonitor = nil
        }
    }

    private func handleGlobalClick(_ event: NSEvent) {
        guard let window = view.window, window.isVisible else { return }
        let location = NSEvent.mouseLocation
        guard let dockItem = DockHitTester.dockItem(at: location) else { return }
        if dockItem.isSelf { return }
        LaunchpadWindowController.shared.presentationRequestID += 1
        LaunchpadWindowController.shared.hide()
    }

    // MARK: - Flags (Option hold)

    override func flagsChanged(with event: NSEvent) {
        let optionDown = event.modifierFlags.contains(.option)
        if optionDown { contentView.optionKeyDown() } else { contentView.optionKeyUp() }
        super.flagsChanged(with: event)
    }

    deinit {
        if let eventObserver { NotificationChannel.center.removeObserver(eventObserver) }
        if let iconAppearanceObserver { NSWorkspace.shared.notificationCenter.removeObserver(iconAppearanceObserver) }
        if let themeObserver { DistributedNotificationCenter.default().removeObserver(themeObserver) }
        appearanceObservation = nil
        removeGlobalMouseDownMonitor()
    }
}

/// Hit-tests the Dock via the accessibility API.
enum DockHitTester {
    struct Item {
        var title: String
        var bundleId: String?
        var isSelf: Bool
    }

    static func dockItem(at screenPoint: NSPoint) -> Item? {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(dockApp.processIdentifier)
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(element, Float(screenPoint.x), Float(screenPoint.y), &hit)
        guard result == .success, let hit else { return nil }

        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(hit, kAXSubroleAttribute as CFString, &subrole)
        guard let subroleString = subrole as? String, subroleString == "AXApplicationDockItem" else { return nil }

        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(hit, kAXTitleAttribute as CFString, &title)
        let name = title as? String ?? ""
        let bundleId = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleIdentifier
        return Item(title: name, bundleId: bundleId, isSelf: bundleId == Bundle.main.bundleIdentifier)
    }
}
