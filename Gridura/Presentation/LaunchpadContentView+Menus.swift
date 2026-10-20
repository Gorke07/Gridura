import AppKit

// App context menu and the background ("More") menu.

extension LaunchpadContentView {
    // MARK: App context menu

    func contextMenu(for group: LaunchpadGroup) -> NSMenu? {
        if groupViews[group.id]?.isHighlight == true, selectedGroups.count >= 2 { return multiSelectionMenu() }
        if group.isFolder { return folderMenu(for: group) }
        guard let app = group.apps.first else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        func item(_ title: String, symbol: String, action: Selector?, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.isEnabled = enabled
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) { item.image = image }
            item.representedObject = app
            return item
        }

        let sourceAvailable = !app.isSourceUnavailable
        menu.addItem(item(NSLocalizedString("Open", comment: ""), symbol: "arrow.up.forward.app",
                          action: #selector(menuOpen(_:)), enabled: sourceAvailable))
        menu.addItem(item(NSLocalizedString("Show in Finder", comment: ""), symbol: "finder",
                          action: #selector(menuShowInFinder(_:)), enabled: sourceAvailable))
        menu.addItem(item(NSLocalizedString("Add App to Dock", comment: ""), symbol: "dock.rectangle",
                          action: #selector(menuAddToDock(_:)),
                          enabled: sourceAvailable && !DockHelper.isInDock(app.url)))
        menu.addItem(.separator())

        if let move = moveToMenuItem(for: app) { menu.addItem(move) }

        let hideTitle = app.hidden ? NSLocalizedString("Unhide", comment: "") : NSLocalizedString("Hide", comment: "")
        menu.addItem(item(hideTitle, symbol: app.hidden ? "eye" : "eye.slash",
                          action: #selector(menuToggleHide(_:))))
        menu.addItem(.separator())
        menu.addItem(item(NSLocalizedString("Get Info", comment: ""), symbol: "info.circle",
                          action: #selector(menuGetInfo(_:)), enabled: sourceAvailable))
        if !appState.hideNames {
            menu.addItem(item(NSLocalizedString("Rename", comment: ""), symbol: "pencil",
                              action: #selector(menuRename(_:)), enabled: !app.hidden))
            menu.addItem(.separator())
        }
        menu.addItem(item(NSLocalizedString("Uninstall", comment: ""), symbol: "xmark.bin",
                          action: #selector(menuUninstall(_:)),
                          enabled: LaunchpadAppView.isRemovable(app)))
        return menu
    }

    /// "Move to ▸": pages (with their folders) in paged mode, the folder list in scroll mode.
    private func moveToMenuItem(for app: LaunchpadApp) -> NSMenuItem? {
        let info = dataManager.pageMoveTargets()
        let paged = appState.browsingStyle == .paged
        guard paged || !info.folders.isEmpty else { return nil }

        let container = dataManager.allGroups.first { $0.apps.contains { $0 === app } }
        let appPage = container?.page ?? currentPage

        let move = NSMenuItem(title: NSLocalizedString("Move to", comment: ""), action: nil, keyEquivalent: "")
        move.keyEquivalentModifierMask = .command
        move.image = NSImage(systemSymbolName: "folder", accessibilityDescription: NSLocalizedString("Move to folder", comment: ""))
        move.isEnabled = !app.hidden

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        func folderEntry(_ folder: LaunchpadGroup) -> NSMenuItem {
            let contains = folder.apps.contains { $0 === app }
            let entry = NSMenuItem(title: (contains ? "✓ " : "") + folder.displayName,
                                   action: #selector(menuMoveToFolder(_:)), keyEquivalent: "")
            entry.target = self
            entry.isEnabled = !contains
            entry.representedObject = [app, folder] as [AnyObject]
            return entry
        }

        if paged {
            for target in info.targets {
                if target.pageIndex > 0 { submenu.addItem(.separator()) }
                let entry = NSMenuItem(title: String(format: NSLocalizedString("Page %d", comment: ""), target.pageIndex + 1),
                                       action: #selector(menuMoveToPage(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = target.pageIndex
                entry.representedObject = app
                entry.state = target.pageIndex == appPage ? .on : .off
                entry.isEnabled = target.pageIndex != appPage && target.availableSlots > 0
                submenu.addItem(entry)
                for folder in info.folders where folder.page == target.pageIndex { submenu.addItem(folderEntry(folder)) }
            }
        } else {
            for folder in info.folders { submenu.addItem(folderEntry(folder)) }
        }
        move.submenu = submenu
        return move
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? LaunchpadApp,
              let group = displayedGroups.first(where: { $0.apps.first === app }) ?? openedFolderGroup(for: app) else { return }
        activate(group)
    }

    private func openedFolderGroup(for app: LaunchpadApp) -> LaunchpadGroup? {
        openedFolderAppViews.compactMap(\.group).first { $0.apps.first === app }
    }

    @objc private func menuShowInFinder(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? LaunchpadApp else { return }
        hideLauncherThen { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
    }

    @objc private func menuAddToDock(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? LaunchpadApp else { return }
        DockHelper.addToDock(app.url)
    }

    @objc private func menuGetInfo(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? LaunchpadApp else { return }
        hideLauncherThen { FinderHelper.showGetInfo(for: app.url) }
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? LaunchpadApp else { return }
        let cell = groupViews.values.first { $0.group?.apps.first === app }
            ?? openedFolderAppViews.first { $0.group?.apps.first === app }
        cell?.beginRename()
    }

    @objc private func menuUninstall(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? LaunchpadApp else { return }
        UninstallCoordinator.shared.begin(app: app)
    }

    @objc private func menuToggleHide(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? LaunchpadApp else { return }
        if app.hidden { dataManager.unhide(app) } else { hideApps(ids: [app.id]) }
    }

    @objc private func menuMoveToPage(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? LaunchpadApp else { return }
        let page = sender.tag
        performLayoutChange { dataManager.moveApp(app, toPage: page) }
    }

    @objc private func menuMoveToFolder(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [AnyObject],
              let app = pair[0] as? LaunchpadApp, let folder = pair[1] as? LaunchpadGroup else { return }
        performLayoutChange { dataManager.moveApps([app], intoFolder: folder) }
    }

    /// Bumps `presentationRequestID` (cancelling any pending show), hides the launcher, and runs
    /// `action` when the hide finished (Open, Show in Finder, Get Info — ).
    func hideLauncherThen(_ action: @escaping () -> Void) {
        let controller = LaunchpadWindowController.shared
        controller.presentationRequestID += 1
        controller.hide(completion: action)
    }

    // MARK: Background / "More" menu

    func showBackgroundMenu() {
        guard let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(backgroundMenu(), with: event, for: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(backgroundMenu(), with: event, for: self)
    }

    private func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, symbol: String, action: Selector, key: String = "",
                 to menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = .command }
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
            return item
        }

        _ = add(NSLocalizedString("Settings", comment: ""), symbol: "gear", action: #selector(bgSettings), key: ",", to: menu)
        menu.addItem(.separator())

        let header = NSMenuItem(title: NSLocalizedString("Sort By", comment: ""), action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: header.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor,
        ])
        header.isEnabled = false
        menu.addItem(header)

        let sortOptions: [(String, String, SortByType, [(String, SortOrderType)])] = [
            (NSLocalizedString("Custom", comment: ""), "arrow.up.left.square", .custom, []),
            (NSLocalizedString("Name", comment: ""), "character.square", .name,
             [(NSLocalizedString("Ascending", comment: ""), .ascending), (NSLocalizedString("Descending", comment: ""), .descending)]),
            (NSLocalizedString("Date Added", comment: ""), "externaldrive", .added,
             [(NSLocalizedString("Newest First", comment: ""), .descending), (NSLocalizedString("Oldest First", comment: ""), .ascending)]),
            (NSLocalizedString("Date Last Opened", comment: ""), "clock", .opened,
             [(NSLocalizedString("Most Recent", comment: ""), .descending), (NSLocalizedString("Least Recent", comment: ""), .ascending)]),
        ]
        for (title, symbol, sort, orders) in sortOptions {
            let item = add(title, symbol: symbol, action: #selector(bgSort(_:)), to: menu)
            item.representedObject = sort.rawValue
            item.state = appState.sortBy == sort ? .on : .off
            guard sort != .custom else { continue }
            do {
                // Non-custom sorts carry a submenu of orders (the click on the row itself keeps the order).
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for (orderTitle, order) in orders {
                    let entry = NSMenuItem(title: orderTitle, action: #selector(bgSortOrder(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = [sort.rawValue, order.rawValue]
                    entry.state = appState.sortBy == sort && appState.sortOrder == order ? .on : .off
                    submenu.addItem(entry)
                }
                item.submenu = submenu
                item.action = nil
            }
        }
        menu.addItem(.separator())

        let displayMode = NSMenuItem(title: NSLocalizedString("Display Mode", comment: ""), action: nil, keyEquivalent: "")
        displayMode.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        let displaySub = NSMenu()
        for (title, mode) in [(NSLocalizedString("Full Screen", comment: ""), DisplayModeType.fullScreen),
                              (NSLocalizedString("Window", comment: ""), .window)] {
            let item = NSMenuItem(title: title, action: #selector(bgDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = appState.displayMode == mode ? .on : .off
            displaySub.addItem(item)
        }
        displayMode.submenu = displaySub
        menu.addItem(displayMode)

        let browsingStyle = NSMenuItem(title: NSLocalizedString("Browsing Style", comment: ""), action: nil, keyEquivalent: "")
        browsingStyle.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        let styleSub = NSMenu()
        for (title, style) in [(NSLocalizedString("Paged", comment: ""), BrowsingStyleType.paged),
                               (NSLocalizedString("Scroll", comment: ""), .scroll)] {
            let item = NSMenuItem(title: title, action: #selector(bgBrowsingStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = appState.browsingStyle == style ? .on : .off
            styleSub.addItem(item)
        }
        browsingStyle.submenu = styleSub
        menu.addItem(browsingStyle)
        menu.addItem(.separator())

        _ = add(NSLocalizedString("Reorganize Layout", comment: ""), symbol: "square.grid.2x2",
                action: #selector(bgReorganize), to: menu)

        menu.addItem(.separator())
        let updates = UpdateManager.shared
        if let downloaded = updates.downloadedVersion {
            _ = add(String(format: NSLocalizedString("Install %@", comment: ""), downloaded),
                    symbol: "arrow.up.circle", action: #selector(bgInstallUpdate), to: menu)
        } else if let available = updates.availableVersion {
            _ = add(String(format: NSLocalizedString("Update to %@", comment: ""), available),
                    symbol: "arrow.up.circle", action: #selector(bgCheckForUpdate), to: menu)
        } else {
            _ = add(NSLocalizedString("Check for Updates", comment: ""),
                    symbol: "arrow.trianglehead.2.clockwise.rotate.90", action: #selector(bgCheckForUpdate), to: menu)
        }

        menu.addItem(.separator())
        _ = add(NSLocalizedString("Restart", comment: ""), symbol: "arrow.clockwise", action: #selector(bgRestart), to: menu)
        _ = add(NSLocalizedString("Quit", comment: ""), symbol: "power", action: #selector(bgQuit), key: "q", to: menu)
        return menu
    }

    @objc private func bgSettings() { onOpenPreferences?() }
    @objc private func bgReorganize() { onOpenReorganize?() }
    @objc private func bgQuit() { NSApp.terminate(nil) }
    @objc private func bgRestart() { MenuBarManager.shared.restart() }
    @objc private func bgCheckForUpdate() { UpdateManager.shared.checkForUpdates() }
    @objc private func bgInstallUpdate() { UpdateManager.shared.installDownloadedUpdate() }

    @objc private func bgSort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let sort = SortByType(rawValue: raw) else { return }
        appState.sortBy = sort
        dataManager.publish(2)
    }

    @objc private func bgSortOrder(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2,
              let sort = SortByType(rawValue: pair[0]), let order = SortOrderType(rawValue: pair[1]) else { return }
        appState.sortBy = sort
        appState.sortOrder = order
        dataManager.publish(2)
    }

    @objc private func bgDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let mode = DisplayModeType(rawValue: raw) else { return }
        appState.displayMode = mode
        NotificationChannel.center.post(name: NotificationChannel.Name.preferencesChanged,
                                        object: PreferenceModule.layout.rawValue)
    }

    @objc private func bgBrowsingStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let style = BrowsingStyleType(rawValue: raw) else { return }
        appState.browsingStyle = style
        NotificationChannel.center.post(name: NotificationChannel.Name.preferencesChanged,
                                        object: PreferenceModule.browsingStyle.rawValue)
    }
}
