import AppKit
import SwiftUI

/// Preferences window shell: an `NSPanel` with a custom 5-button toolbar and a lazily built
/// SwiftUI tab per item.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    /// Languages whose labels are long enough that the original widens the window.
    private static let wideLanguages = ["bg", "fr", "de", "ru", "uk", "pl"]

    /// 460 for the wide languages, otherwise 400.
    private static var windowWidth: CGFloat {
        let language = (Bundle.main.preferredLocalizations.first ?? "en")
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        for candidate in wideLanguages where language == candidate || language.hasPrefix(candidate + "-") {
            return 460
        }
        return 400
    }

    private var preferencesViewController: PreferencesViewController?

    private convenience init() {
        let width = Self.windowWidth
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 340),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.identifier = NSUserInterfaceItemIdentifier("PreferencesWindow")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 400, height: 0)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        self.init(window: panel)
        let controller = PreferencesViewController()
        panel.contentViewController = controller
        preferencesViewController = controller
        panel.delegate = self
    }

    // MARK: - Show / hide

    func show() {
        // The panel is torn down on close, so rebuild it on demand.
        if window == nil { rebuild() }
        guard let window else { return }
        position(window)
        window.level = NSWindow.Level(rawValue: 1001)
        LaunchpadWindowController.shared.launchpadVC.contentView.setInteractionOverlayHidden(false)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func rebuild() {
        let width = Self.windowWidth
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 340),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.identifier = NSUserInterfaceItemIdentifier("PreferencesWindow")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 400, height: 0)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let controller = PreferencesViewController()
        panel.contentViewController = controller
        panel.delegate = self
        preferencesViewController = controller
        window = panel
    }

    override func close() {
        window?.performClose(nil)
    }

    func closeIfOpen() {
        guard window?.isVisible == true else { return }
        window?.performClose(nil)
    }

    func showReorganize() {
        show()
        preferencesViewController?.selectTab(index: PreferencesViewController.advancedTabIndex)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: Notification.Name("Gridura.ShowReorganize"), object: nil)
        }
    }

    func showGuide() {
        GuideWindowController.shared.show()
    }

    /// Rebuilds every tab so a licence change is reflected immediately.
    func reloadAll() {
        preferencesViewController?.reloadAllTabs()
    }

    private func position(_ window: NSWindow) {
        let screen = LaunchpadWindowController.shared.window?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(),
                             y: (visible.midY - size.height / 2).rounded())
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        LaunchpadWindowController.shared.launchpadVC.contentView.setInteractionOverlayHidden(true)
        preferencesViewController?.tearDownTabs()
        if let panel = window {
            panel.delegate = nil
            panel.contentViewController = nil
        }
        preferencesViewController = nil
        // Dropping the reference means the panel is rebuilt next time `show()` runs.
        window = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        preferencesViewController?.ensureSelectedTab()
        NotificationCenter.default.post(name: .refreshPreferencesDataPublic, object: nil)
    }
}

/// Hosts the toolbar and the tab view, and keeps the window height in sync with the current tab
///.
final class PreferencesViewController: NSViewController {
    static let advancedTabIndex = 3

    private let toolbarHeight: CGFloat = 58
    private let tabSwitchAnimationDuration: TimeInterval = 0.24

    private let tabView = NSTabView()
    private let toolbar = NSView()
    private var tabButtons: [NSButton] = []
    private var tabButtonImages: [NSImageView] = []
    private var tabButtonLabels: [NSTextField] = []

    private(set) var selectedTabIndex = 0
    private var lastMeasuredContentHeight: CGFloat?
    private var isAdjustingWindowHeight = false
    private var tabControllers: [Int: SizingHostingController<AnyView>] = [:]

    private let tabSpecs: [(image: String, title: String)] = [
        ("Tab/General", "General"),
        ("Tab/Interface", "Interface"),
        ("Tab/Apps", "Apps"),
        ("Tab/Advanced", "Advanced"),
        ("Tab/Info", "About"),
    ]

    override func loadView() {
        view = PreferencesRootView(frame: NSRect(x: 0, y: 0, width: 400, height: 540))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildToolbar()
        buildTabView()
        ensureTabController(0)
        tabView.selectTabViewItem(at: 0)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        ensureSelectedTab()
        adjustWindowHeight(index: selectedTabIndex, animated: false, measure: true)
    }

    // MARK: - Toolbar

    private func buildToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        view.addSubview(toolbar)

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        view.addSubview(separator)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),

            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        var previous: NSView?
        for (index, spec) in tabSpecs.enumerated() {
            let (button, imageView, label) = makeTabButton(index: index, spec: spec)
            toolbar.addSubview(button)
            NSLayoutConstraint.activate([
                button.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -8),
                button.widthAnchor.constraint(equalTo: toolbar.widthAnchor, multiplier: 0.2, constant: -8),
                button.heightAnchor.constraint(equalToConstant: 48),
            ])
            if let previous {
                button.leadingAnchor.constraint(equalTo: previous.trailingAnchor).isActive = true
            } else {
                button.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 20).isActive = true
            }
            previous = button
            tabButtons.append(button)
            tabButtonImages.append(imageView)
            tabButtonLabels.append(label)
        }
        updateToolbarAppearance()
    }

    private func makeTabButton(index: Int, spec: (image: String, title: String))
        -> (NSButton, NSImageView, NSTextField) {
        let button = NSButton(title: "", target: self, action: #selector(tabButtonClicked(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.tag = index
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(named: spec.image)
        imageView.image?.isTemplate = true
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 24),
            imageView.heightAnchor.constraint(equalToConstant: 24),
        ])

        let label = NSTextField(labelWithString: spec.title)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        return (button, imageView, label)
    }

    private func updateToolbarAppearance() {
        let accent = NSColor.controlAccentColor
        let secondary = NSColor.secondaryLabelColor
        for index in tabButtons.indices {
            let isSelected = index == selectedTabIndex
            tabButtons[index].layer?.backgroundColor = isSelected
                ? NSColor.quaternarySystemFill.cgColor
                : NSColor.clear.cgColor
            tabButtonImages[index].contentTintColor = isSelected ? accent : secondary
            tabButtonLabels[index].textColor = isSelected ? accent : secondary
        }
    }

    @objc private func tabButtonClicked(_ sender: NSButton) {
        selectTab(index: sender.tag)
    }

    func selectTab(index: Int) {
        guard index >= 0, index < tabSpecs.count, index != selectedTabIndex else { return }
        selectedTabIndex = index
        lastMeasuredContentHeight = nil
        updateToolbarAppearance()
        tabView.selectTabViewItem(at: index)
        ensureTabController(index)
        adjustWindowHeight(index: index, animated: true, measure: true)
    }

    // MARK: - Tab view

    private func buildTabView() {
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .noTabsNoBorder
        view.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 1),
            tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        for _ in tabSpecs {
            let item = NSTabViewItem()
            item.view = NSView()
            tabView.addTabViewItem(item)
        }
    }

    /// Builds the SwiftUI controller for a tab the first time it is shown.
    @discardableResult
    private func ensureTabController(_ index: Int) -> SizingHostingController<AnyView>? {
        if let existing = tabControllers[index] { return existing }
        guard index >= 0, index < tabSpecs.count,
              index < tabView.numberOfTabViewItems else { return nil }

        let controller = SizingHostingController(rootView: AnyView(rootView(for: index)))
        controller.onLayout = { [weak self] in self?.tabDidLayout(index) }
        addChild(controller)

        let item = tabView.tabViewItem(at: index)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        item.view = controller.view
        tabControllers[index] = controller
        return controller
    }

    func ensureSelectedTab() {
        ensureTabController(selectedTabIndex)
    }

    @ViewBuilder
    private func rootView(for index: Int) -> some View {
        switch index {
        case 0: GeneralTabView()
        case 1: InterfaceTabView()
        case 2: AppsTabView()
        case 3: AdvancedTabView()
        default: AboutTabView()
        }
    }

    private func tabDidLayout(_ index: Int) {
        guard index == selectedTabIndex else { return }
        view.layoutSubtreeIfNeeded()
        guard let itemView = tabView.tabViewItem(at: index).view else { return }
        let height = itemView.fittingSize.height.rounded()
        guard height > 0 else { return }
        if let last = lastMeasuredContentHeight, abs(height - last) <= 0.5 { return }
        adjustWindowHeight(index: index, animated: false, height: height)
    }

    // MARK: - Height

    /// Measures the tab's fitting height and resizes the window to it.
    private func adjustWindowHeight(index: Int, animated: Bool, measure: Bool) {
        var height = lastMeasuredContentHeight ?? 0
        if measure, let itemView = tabView.tabViewItem(at: index).view {
            height = itemView.fittingSize.height.rounded()
        }
        guard height > 0 else { return }
        adjustWindowHeight(index: index, animated: animated, height: height)
    }

    private func adjustWindowHeight(index: Int, animated: Bool, height: CGFloat) {
        guard let window = view.window, !isAdjustingWindowHeight else { return }
        guard height > 0 else { return }

        let content = NSRect(x: 0, y: 0, width: view.bounds.width, height: height + toolbarHeight)
        let target = window.frameRect(forContentRect: content)
        lastMeasuredContentHeight = height

        let delta = window.frame.height - target.height
        guard abs(delta) > 0.5 else { return }

        var frame = window.frame
        frame.origin.y += delta
        frame.size.height = target.height

        if animated {
            isAdjustingWindowHeight = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = tabSwitchAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                self?.isAdjustingWindowHeight = false
            })
        } else {
            window.setFrame(frame, display: true)
        }
    }

    // MARK: - Teardown

    func tearDownTabs() {
        for (index, controller) in tabControllers {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            tabView.tabViewItem(at: index).view = NSView()
        }
        tabControllers.removeAll()
        lastMeasuredContentHeight = nil
    }

    func reloadAllTabs() {
        tearDownTabs()
        ensureSelectedTab()
        adjustWindowHeight(index: selectedTabIndex, animated: false, measure: true)
    }
}

/// The window content root; only overrides first-responder acceptance.
final class PreferencesRootView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
