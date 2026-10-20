import AppKit

// The uninstall panel: header with the app, a grouped list of everything the
// scan found, and a Cancel / Move to Trash footer.

/// `NSButton` with extra content padding.
final class PaddedButton: NSButton {
    var contentPadding = NSEdgeInsets()

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + contentPadding.left + contentPadding.right,
                      height: size.height + contentPadding.top + contentPadding.bottom)
    }
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Anchors a floating panel on the launcher's screen above everything.
func positionedPanelFrame(width: CGFloat, height: CGFloat) -> CGRect {
    let screen = LaunchpadWindowController.shared.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    return CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
}

final class UninstallWindowController: NSWindowController, NSWindowDelegate {
    static let shared = UninstallWindowController()
    static let defaultWindowSize = CGSize(width: 560, height: 400)

    private convenience init() {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.defaultWindowSize),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.identifier = NSUserInterfaceItemIdentifier("UninstallWindow")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = CGSize(width: 480, height: 360)
        self.init(window: panel)
        panel.delegate = self
    }

    func show(app: LaunchpadApp, icon: NSImage?) {
        guard let window else { return }
        window.level = NSWindow.Level(rawValue: 1001)
        window.setFrame(positionedPanelFrame(width: Self.defaultWindowSize.width, height: Self.defaultWindowSize.height),
                        display: true)
        (window.contentView as? UninstallContentView)?.teardown()
        window.contentView = UninstallContentView(app: app, icon: icon, window: window)
        LaunchpadWindowController.shared.launchpadVC.contentView.setInteractionOverlayHidden(false)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        LaunchpadWindowController.shared.launchpadVC.contentView.setInteractionOverlayHidden(true)
        (window?.contentView as? UninstallContentView)?.teardown()
    }
}

// MARK: - Content

final class UninstallContentView: NSView {
    private let app: LaunchpadApp
    private let icon: NSImage?
    private weak var hostWindow: NSWindow?

    private var items: [AppUninstallItem] = []
    private var selectedItemIDs = Set<UUID>()
    private var collapsedCategories = Set<AppUninstallItem.Category>()
    private var isScanning = false
    private var isClosed = false

    private let appIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let headerTextStack = NSStackView()
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    private let documentContainer = NSView()
    private let rowsStack = NSStackView()
    private let loadingIndicator = NSProgressIndicator()
    private let footerSeparator = NSBox()
    private let allCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("All", comment: ""), target: nil, action: nil)
    private let cancelButton = PaddedButton()
    private let removeButton = PaddedButton()

    private var headers: [UninstallCategoryHeaderView] = []
    private var rows: [AppUninstallItemRowView] = []

    init(app: LaunchpadApp, icon: NSImage?, window: NSWindow) {
        self.app = app
        self.icon = icon
        self.hostWindow = window
        super.init(frame: CGRect(origin: .zero, size: UninstallWindowController.defaultWindowSize))
        build()
        startScan()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The sheet swallows mouse and key events that are not for its controls.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event) }

    private func bodyFont(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }

    // MARK: Build

    private func build() {
        wantsLayer = true

        appIconView.image = icon
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.stringValue = app.alias.isEmpty ? app.name : app.alias
        titleLabel.font = bodyFont(.title3, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.font = bodyFont(.subheadline)
        sizeLabel.textColor = .secondaryLabelColor
        headerTextStack.orientation = .vertical
        headerTextStack.alignment = .leading
        headerTextStack.spacing = 4
        headerTextStack.addArrangedSubview(titleLabel)
        headerTextStack.addArrangedSubview(sizeLabel)
        separator.boxType = .separator

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = documentContainer
        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading
        documentContainer.addSubview(rowsStack)
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.isDisplayedWhenStopped = false

        footerSeparator.boxType = .separator
        allCheckbox.font = bodyFont(.body)
        allCheckbox.target = self
        allCheckbox.action = #selector(toggleAll)

        for button in [cancelButton, removeButton] {
            button.bezelStyle = .push
            button.isBordered = true
            button.font = bodyFont(.body)
            button.contentPadding = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        }
        cancelButton.title = NSLocalizedString("Cancel", comment: "")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        removeButton.keyEquivalent = "\r"
        removeButton.bezelColor = .controlAccentColor
        removeButton.contentTintColor = .white
        removeButton.target = self
        removeButton.action = #selector(remove)
        setRemoveTitle(NSLocalizedString("Move to Trash", comment: ""))
        removeButton.invalidateIntrinsicContentSize()
        cancelButton.invalidateIntrinsicContentSize()

        for view in [appIconView, headerTextStack, separator, scrollView, loadingIndicator,
                     footerSeparator, allCheckbox, cancelButton, removeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        documentContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            appIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            appIconView.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            appIconView.widthAnchor.constraint(equalToConstant: 48),
            appIconView.heightAnchor.constraint(equalToConstant: 48),
            headerTextStack.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: 8),
            headerTextStack.centerYAnchor.constraint(equalTo: appIconView.centerYAnchor),
            headerTextStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            documentContainer.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            documentContainer.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            documentContainer.topAnchor.constraint(equalTo: clip.topAnchor),
            documentContainer.widthAnchor.constraint(equalTo: clip.widthAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: documentContainer.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: documentContainer.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: documentContainer.topAnchor, constant: 10),
            rowsStack.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor, constant: -10),
            rowsStack.widthAnchor.constraint(equalTo: documentContainer.widthAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerSeparator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -64),
            allCheckbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            allCheckbox.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            removeButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            cancelButton.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: removeButton.centerYAnchor),
        ])
        refreshFooter()
    }

    private func setRemoveTitle(_ title: String) {
        removeButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white, .font: bodyFont(.body),
        ])
    }

    // MARK: Scan lifecycle

    private func startScan() {
        guard !isClosed else { return }
        isScanning = true
        loadingIndicator.startAnimation(nil)
        setControlsEnabled(false)
        let app = self.app
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = AppUninstallManager.shared.scan(app: app)
            DispatchQueue.main.async { self?.scanFinished(found) }
        }
    }

    private func scanFinished(_ found: [AppUninstallItem]) {
        guard !isClosed else { return }
        items = found
        selectedItemIDs = Set(found.map(\.id))        // everything is selected by default
        rebuildRows()
        isScanning = false
        loadingIndicator.stopAnimation(nil)
        setControlsEnabled(true)
        refreshFooter()
    }

    private func refreshFooter() {
        allCheckbox.state = (!items.isEmpty && selectedItemIDs.count == items.count) ? .on : .off
        removeButton.isEnabled = !isScanning && !selectedItemIDs.isEmpty
        let total = items.filter { selectedItemIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
        sizeLabel.stringValue = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        cancelButton.isEnabled = enabled
        removeButton.isEnabled = enabled && !selectedItemIDs.isEmpty
        allCheckbox.isEnabled = enabled
        headers.forEach { $0.setEnabled(enabled) }
        rows.forEach { $0.setEnabled(enabled) }
    }

    // MARK: Rows

    private func categoryState(_ category: AppUninstallItem.Category) -> NSControl.StateValue {
        let ids = items.filter { $0.category == category }.map(\.id)
        let selected = ids.filter { selectedItemIDs.contains($0) }.count
        return selected == 0 ? .off : (selected == ids.count ? .on : .mixed)
    }

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { rowsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        headers = []
        rows = []
        let grouped = Dictionary(grouping: items, by: \.category)
        for category in grouped.keys.sorted(by: { $0.displayRank < $1.displayRank }) {
            let collapsed = collapsedCategories.contains(category)
            let header = UninstallCategoryHeaderView(title: category.title, state: categoryState(category), expanded: !collapsed)
            header.onToggle = { [weak self] in
                guard let self else { return }
                if self.collapsedCategories.contains(category) { self.collapsedCategories.remove(category) }
                else { self.collapsedCategories.insert(category) }
                self.rebuildRows(); self.refreshFooter()
            }
            header.onSelectionChanged = { [weak self] on in
                guard let self else { return }
                for item in self.items where item.category == category {
                    if on { self.selectedItemIDs.insert(item.id) } else { self.selectedItemIDs.remove(item.id) }
                }
                self.rebuildRows(); self.refreshFooter()
            }
            headers.append(header)
            rowsStack.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            header.heightAnchor.constraint(equalToConstant: 28).isActive = true

            let container = NSStackView()
            container.orientation = .vertical
            container.spacing = 0
            container.alignment = .leading
            container.isHidden = collapsed
            rowsStack.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true

            for item in grouped[category] ?? [] {
                let row = AppUninstallItemRowView(contentLeadingInset: 18, item: item, selected: selectedItemIDs.contains(item.id))
                row.onSelectionChanged = { [weak self] on in
                    guard let self else { return }
                    if on { self.selectedItemIDs.insert(item.id) } else { self.selectedItemIDs.remove(item.id) }
                    self.rebuildRows(); self.refreshFooter()
                }
                rows.append(row)
                container.addArrangedSubview(row)
                row.heightAnchor.constraint(equalToConstant: 46).isActive = true
                row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            }
        }
        if items.count == 1, items[0].category == .aliasFile {
            let notice = NSTextField(wrappingLabelWithString:
                NSLocalizedString("Only the alias file itself will be removed. The original app and its related files will not be scanned or deleted.", comment: ""))
            notice.font = bodyFont(.footnote)
            notice.textColor = .secondaryLabelColor
            notice.maximumNumberOfLines = 0
            let wrapper = NSView()
            notice.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(notice)
            NSLayoutConstraint.activate([
                notice.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 18),
                notice.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -18),
                notice.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 6),
                notice.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -10),
            ])
            rowsStack.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    @objc private func toggleAll() {
        if allCheckbox.state == .on { selectedItemIDs = Set(items.map(\.id)) } else { selectedItemIDs.removeAll() }
        rebuildRows()
        refreshFooter()
    }

    @objc private func cancel() { hostWindow?.close() }

    // MARK: Remove

    @objc private func remove() {
        guard !isScanning else { return }
        setControlsEnabled(false)
        removeButton.isEnabled = false
        setRemoveTitle(NSLocalizedString("Removing...", comment: ""))
        let selected = items.filter { selectedItemIDs.contains($0.id) }

        let touchesApp = selected.contains { $0.kind == .application || $0.category.requiresAppQuit }
        let running = runningInstances()
        if !running.isEmpty && touchesApp {
            showRunningAlert(running, selected: selected)
            return
        }
        performRemoval(selected)
    }

    private func runningInstances() -> [NSRunningApplication] {
        let target = app.url.standardizedFileURL
        func matches(_ running: NSRunningApplication) -> Bool { running.bundleURL?.standardizedFileURL == target }
        var bundleId = app.bundleId
        if bundleId.isEmpty { bundleId = Bundle(url: app.url)?.bundleIdentifier ?? "" }
        var found: [NSRunningApplication] = []
        if !bundleId.isEmpty {
            found = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter(matches)
        }
        if found.isEmpty { found = NSWorkspace.shared.runningApplications.filter(matches) }
        return found.filter { !$0.isTerminated }
    }

    private func showRunningAlert(_ running: [NSRunningApplication], selected: [AppUninstallItem]) {
        guard let window = hostWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("%@ Is Running", comment: ""), app.alias.isEmpty ? app.name : app.alias)
        alert.informativeText = NSLocalizedString("Force quitting may cause unsaved changes to be lost.", comment: "")
        if let icon { icon.size = NSSize(width: 128, height: 128); alert.icon = icon }
        alert.addButton(withTitle: NSLocalizedString("Force Quit", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.forceQuit(running, then: selected)
            } else {
                self.setControlsEnabled(true)
                self.setRemoveTitle(NSLocalizedString("Remove", comment: ""))
            }
        }
    }

    /// `forceTerminate()`, then poll every 0.2 s for up to 8 s; if it is still running, ask again.
    private func forceQuit(_ running: [NSRunningApplication], then selected: [AppUninstallItem]) {
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        let deadline = Date().addingTimeInterval(8)
        func poll() {
            if running.allSatisfy(\.isTerminated) {
                performRemoval(selected)
            } else if Date() >= deadline {
                let stillRunning = runningInstances()
                if stillRunning.isEmpty { performRemoval(selected) } else { showRunningAlert(stillRunning, selected: selected) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
            }
        }
        poll()
    }

    private func performRemoval(_ selected: [AppUninstallItem]) {
        let name = app.alias.isEmpty ? app.name : app.alias
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let failures = AppUninstallManager.shared.remove(selected, appName: name)
            DispatchQueue.main.async { self?.removalFinished(selected: selected, failures: failures) }
        }
    }

    private func removalFinished(selected: [AppUninstallItem], failures: [AppUninstallFailure]) {
        guard !isClosed else { return }
        if failures.isEmpty {
            if let url = URL(string: "file:///System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag%20to%20trash.aif") {
                NSSound(contentsOf: url, byReference: false)?.play()
            }
            hostWindow?.close()
            NotificationChannel.center.post(name: NotificationChannel.Name.scanApp, object: nil)
            return
        }
        LogManager.shared.error("Uninstall failed app=\(app.name) bundleId=\(app.bundleId) selectedCount=\(selected.count) failureCount=\(failures.count)")
        for failure in failures {
            let error = failure.error as NSError
            LogManager.shared.error("Uninstall failure item=\(failure.item.url.path) domain=\(error.domain) code=\(error.code) \(error.localizedDescription)")
        }
        let failedIDs = Set(failures.map(\.item.id))
        items = items.filter { item in failedIDs.contains(item.id) || !selected.contains(where: { $0.id == item.id }) }
        selectedItemIDs = failedIDs
        collapsedCategories = []
        rebuildRows()
        setControlsEnabled(true)
        refreshFooter()
        setRemoveTitle(NSLocalizedString("Remove", comment: ""))

        guard let window = hostWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Uninstall Failed", comment: "")
        alert.informativeText = String.localizedStringWithFormat(
            NSLocalizedString("%d item could not be removed. Please try again or remove it manually in Finder.", comment: ""),
            failures.count)
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.beginSheetModal(for: window)
    }

    // MARK: Teardown

    func teardown() {
        isClosed = true
        isScanning = false
        loadingIndicator.stopAnimation(nil)
        if let sheet = hostWindow?.attachedSheet { hostWindow?.endSheet(sheet) }
        rowsStack.arrangedSubviews.forEach { rowsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        headers = []; rows = []
        appIconView.image = nil
        items = []; selectedItemIDs = []; collapsedCategories = []
        for button in [allCheckbox, cancelButton, removeButton] { button.target = nil; button.action = nil }
    }
}

// MARK: - Category header and item row

private final class UninstallCategoryHeaderView: NSView {
    var onToggle: (() -> Void)?
    var onSelectionChanged: ((Bool) -> Void)?
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let toggleButton = NSButton()
    private let titleLabel: NSTextField

    init(title: String, state: NSControl.StateValue, expanded: Bool) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        checkbox.allowsMixedState = true
        checkbox.state = state
        checkbox.target = self
        checkbox.action = #selector(selectAction)
        toggleButton.isBordered = false
        toggleButton.setButtonType(.momentaryChange)
        toggleButton.imagePosition = .imageOnly
        toggleButton.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        toggleButton.target = self
        toggleButton.action = #selector(toggleAction)
        titleLabel.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize)
        titleLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(titleClicked)))
        for view in [checkbox, toggleButton, titleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 18),
            checkbox.heightAnchor.constraint(equalToConstant: 18),
            toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 14),
            toggleButton.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleButton.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setEnabled(_ enabled: Bool) {
        checkbox.isEnabled = enabled
        toggleButton.isEnabled = enabled
        titleLabel.textColor = enabled ? .secondaryLabelColor : .disabledControlTextColor
    }

    @objc private func selectAction() { onSelectionChanged?(checkbox.state != .off) }
    @objc private func toggleAction() { if toggleButton.isEnabled { onToggle?() } }
    @objc private func titleClicked() { if toggleButton.isEnabled { onToggle?() } }
}

private final class AppUninstallItemRowView: NSView {
    var onSelectionChanged: ((Bool) -> Void)?
    private let item: AppUninstallItem
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let pathLabel: NSTextField
    private let sizeLabel: NSTextField
    private let revealButton = NSButton()
    private let separator = NSBox()

    init(contentLeadingInset: CGFloat, item: AppUninstallItem, selected: Bool) {
        self.item = item
        titleLabel = NSTextField(labelWithString: item.name)
        pathLabel = NSTextField(labelWithString: item.displayPath)
        sizeLabel = NSTextField(labelWithString: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
        super.init(frame: .zero)

        checkbox.state = selected ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(toggle)
        iconView.image = item.kind == .folder
            ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(forFile: item.url.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        let body = NSFont.preferredFont(forTextStyle: .body).pointSize
        let sub = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        titleLabel.font = .systemFont(ofSize: body)
        titleLabel.lineBreakMode = .byTruncatingTail
        pathLabel.font = .systemFont(ofSize: sub)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        sizeLabel.font = .systemFont(ofSize: sub)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right
        for label in [titleLabel, pathLabel] {
            label.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            label.setContentHuggingPriority(.init(250), for: .horizontal)
        }
        revealButton.bezelStyle = .circular
        revealButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        revealButton.imageScaling = .scaleProportionallyDown
        revealButton.target = self
        revealButton.action = #selector(reveal)
        separator.boxType = .separator

        for view in [checkbox, iconView, titleLabel, pathLabel, sizeLabel, revealButton, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeadingInset),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 16),
            checkbox.heightAnchor.constraint(equalToConstant: 16),
            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: sizeLabel.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            pathLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            pathLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            revealButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            revealButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            revealButton.widthAnchor.constraint(equalToConstant: 18),
            revealButton.heightAnchor.constraint(equalToConstant: 18),
            sizeLabel.trailingAnchor.constraint(equalTo: revealButton.leadingAnchor, constant: -12),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setEnabled(_ enabled: Bool) {
        checkbox.isEnabled = enabled
        revealButton.isEnabled = enabled
    }

    @objc private func toggle() { onSelectionChanged?(checkbox.state == .on) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
}
