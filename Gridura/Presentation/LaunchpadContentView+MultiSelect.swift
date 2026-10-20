import AppKit

// Multi-selection: Command+click (cell), Command-drag marquee, the multi-selection menu and the
// batch actions, plus the shared layout-change animation.

/// Rubber-band rectangle drawn while Command-dragging on empty space.
final class SelectionMarqueeView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let color = DesignTokens.color("Selection") ?? .white
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        color.withAlphaComponent(0.16).setFill()
        path.fill()
        color.withAlphaComponent(0.72).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

extension LaunchpadContentView {
    // MARK: Selection state

    /// Highlighted cells in grid order.
    var selectedGroups: [LaunchpadGroup] {
        displayedGroups.filter { groupViews[$0.id]?.isHighlight == true }
    }

    /// Clears every highlight and the keyboard focus.
    @discardableResult
    func clearAllHighlights() -> Bool {
        var cleared = false
        for view in groupViews.values where view.isHighlight {
            view.isHighlight = false
            cleared = true
        }
        if activeGroupID != nil { activeGroupID = nil; cleared = true }
        return cleared
    }

    // MARK: Marquee

    func beginMarquee(at point: CGPoint) {
        marqueeStart = point
        marqueeInitialIDs = Set(groupViews.filter { $0.value.isHighlight }.keys)
        marqueeView.removeFromSuperview()
        marqueeView.frame = .zero
        marqueeView.isHidden = true
        addSubview(marqueeView, positioned: .above, relativeTo: nil)
    }

    func updateMarquee(to point: CGPoint) {
        guard let start = marqueeStart else { return }
        if marqueeView.isHidden, hypot(point.x - start.x, point.y - start.y) < 4 { return }
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        if marqueeView.isHidden { activeGroupID = nil }    // first appearance clears keyboard focus
        marqueeView.frame = rect
        marqueeView.isHidden = false
        marqueeView.needsDisplay = true

        for (id, view) in groupViews where view.superview != nil && view.window != nil {
            let hit = rect.intersects(convert(view.iconContentFrame, from: view))
            view.isHighlight = marqueeInitialIDs.contains(id) != hit      // XOR toggles
        }
    }

    func endMarquee() {
        marqueeStart = nil
        marqueeInitialIDs = []
        marqueeView.isHidden = true
        marqueeView.removeFromSuperview()
    }

    // MARK: Multi-selection menu

    func multiSelectionMenu() -> NSMenu {
        let groups = selectedGroups
        let folders = groups.filter(\.isFolder)
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: String(format: NSLocalizedString("Selected %d items", comment: ""), groups.count),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(string: header.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        menu.addItem(header)
        menu.addItem(.separator())

        func item(_ title: String, symbol: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) { item.image = image }
            return item
        }

        let hasVisibleApps = groups.contains { group in group.apps.contains { !$0.hidden } }
        if folders.isEmpty {
            menu.addItem(item(NSLocalizedString("Create New Folder", comment: ""), symbol: "folder.badge.plus",
                              action: #selector(handleCreateFolderFromMultiSelection), enabled: hasVisibleApps))
            menu.addItem(.separator())
        } else if folders.count == 1 {
            let title = String(format: NSLocalizedString("Merge into “%@”", comment: ""), folders[0].displayName)
            menu.addItem(item(title, symbol: "folder.fill", action: #selector(handleMergeMultiSelectionIntoSelectedFolder)))
            menu.addItem(.separator())
        } else {
            menu.addItem(item(NSLocalizedString("Merge into New Folder", comment: ""), symbol: "folder.fill.badge.plus",
                              action: #selector(handleMergeMultiSelectionIntoNewFolder)))
            menu.addItem(.separator())
        }

        let moveInfo = dataManager.pageMoveTargets()
        let pageTargets = moveInfo.targets.filter { $0.availableSlots >= groups.count }
        if folders.isEmpty {
            let move = item(NSLocalizedString("Move to", comment: ""), symbol: "folder", action: #selector(noop))
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for folder in moveInfo.folders {
                let entry = NSMenuItem(title: folder.displayName, action: #selector(handleMoveMultiSelectionToFolder(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = folder
                entry.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                submenu.addItem(entry)
            }
            if appState.browsingStyle == .paged {
                if !moveInfo.folders.isEmpty && !pageTargets.isEmpty { submenu.addItem(.separator()) }
                for target in pageTargets { submenu.addItem(pageItem(target.pageIndex, action: #selector(handleMoveMultiSelectionToPage(_:)))) }
            }
            move.submenu = submenu
            move.action = nil
            move.isEnabled = !submenu.items.isEmpty
            menu.addItem(move)
            menu.addItem(item(NSLocalizedString("Hide", comment: ""), symbol: "eye.slash", action: #selector(handleHideMultiSelection)))
        } else if appState.browsingStyle == .paged {
            let move = item(NSLocalizedString("Move to page", comment: ""), symbol: "folder", action: #selector(noop))
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for target in pageTargets { submenu.addItem(pageItem(target.pageIndex, action: #selector(handleMoveMultiSelectionGroupsToPage(_:)))) }
            move.submenu = submenu
            move.action = nil
            move.isEnabled = !submenu.items.isEmpty
            menu.addItem(move)
        }
        return menu
    }

    private func pageItem(_ page: Int, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: String(format: NSLocalizedString("Page %d", comment: ""), page + 1),
                               action: action, keyEquivalent: "")
        entry.target = self
        entry.tag = page
        return entry
    }

    @objc private func noop() {}

    // MARK: Actions

    @objc func handleCreateFolderFromMultiSelection() {
        let apps = selectedGroups.flatMap(\.apps)
        let hidden = apps.filter(\.hidden)
        if !hidden.isEmpty {
            let names = ListFormatter.localizedString(byJoining: hidden.map(\.name))
            ToastManager.shared.show(type: .warning,
                                     message: String(format: NSLocalizedString("Cannot create folder. Unhide these apps first: %@", comment: ""), names),
                                     duration: 6)
            return
        }
        guard !apps.isEmpty else { return }
        clearAllHighlights()
        performLayoutChange(scale: 0.85) {
            _ = dataManager.createFolderAtEnd(appIds: apps.map(\.id))
        }
        ToastManager.shared.show(type: .info,
                                 message: NSLocalizedString("New folder placed at the end", comment: ""), duration: 2)
    }

    @objc func handleMergeMultiSelectionIntoSelectedFolder() {
        let groups = selectedGroups
        guard let folder = groups.first(where: \.isFolder) else { return }
        let apps = groups.filter { !$0.isFolder }.flatMap(\.apps)
        guard !apps.isEmpty else { return }
        clearAllHighlights()
        performLayoutChange(scale: 0.85) { dataManager.moveApps(apps, intoFolder: folder) }
    }

    @objc func handleMergeMultiSelectionIntoNewFolder() {
        let apps = selectedGroups.flatMap(\.apps)
        guard !apps.isEmpty else { return }
        clearAllHighlights()
        performLayoutChange(scale: 0.85) { _ = dataManager.createFolderAtEnd(appIds: apps.map(\.id)) }
    }

    @objc func handleMoveMultiSelectionToFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? LaunchpadGroup else { return }
        let apps = selectedGroups.filter { !$0.isFolder }.flatMap(\.apps)
        guard !apps.isEmpty else { return }
        clearAllHighlights()
        performLayoutChange(scale: 0.85) { dataManager.moveApps(apps, intoFolder: folder) }
    }

    @objc func handleMoveMultiSelectionToPage(_ sender: NSMenuItem) {
        moveSelectedGroups(toPage: sender.tag)
    }

    @objc func handleMoveMultiSelectionGroupsToPage(_ sender: NSMenuItem) {
        moveSelectedGroups(toPage: sender.tag)
    }

    private func moveSelectedGroups(toPage page: Int) {
        let groups = selectedGroups
        guard !groups.isEmpty else { return }
        clearAllHighlights()
        performLayoutChange(scale: 0.85) { dataManager.move(groups, toPage: page) }
    }

    @objc func handleHideMultiSelection() {
        let ids = selectedGroups.filter { !$0.isFolder }.flatMap(\.apps).map(\.id)
        guard !ids.isEmpty else { return }
        clearAllHighlights()
        hideApps(ids: ids)
    }

    // MARK: Layout-change animation

    /// Runs `mutation` (a data-manager operation that republishes synchronously) and animates every
    /// cell from where it was: moved cells glide, new ones scale/fade in from `sourcePoint`
    /// (0.36 s `T_spring`, key `folder.layoutChange`). Skipped while a folder is open, outside
    /// custom/name sort, or while searching.
    func performLayoutChange(sourcePoint: CGPoint? = nil, scale: CGFloat = 0.85, _ mutation: () -> Void) {
        guard layoutChangeAnimationAllowed else { mutation(); return }
        let before = captureCellOrigins()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mutation()
        layoutSubtreeIfNeeded()
        CATransaction.commit()
        animateLayoutChange(from: before, sourcePoint: sourcePoint, appearScale: scale)
    }

    var layoutChangeAnimationAllowed: Bool {
        openedFolderID == nil && window != nil
            && (appState.sortBy == .custom || appState.sortBy == .name)
            && dataManager.currentSearchQuery.isEmpty
    }

    /// Origin of every mounted cell in this view's coordinates.
    func captureCellOrigins() -> [String: CGPoint] {
        var origins: [String: CGPoint] = [:]
        for (id, view) in groupViews where view.superview != nil {
            origins[id] = convert(view.bounds, from: view).origin
        }
        return origins
    }

    func animateLayoutChange(from before: [String: CGPoint], sourcePoint: CGPoint?, appearScale: CGFloat) {
        for (id, view) in groupViews {
            guard let layer = view.layer, view.superview != nil else { continue }
            let now = convert(view.bounds, from: view).origin
            let position = CABasicAnimation(keyPath: "position")
            position.toValue = NSValue(point: layer.position)
            var animations: [CAAnimation] = []

            if let old = before[id] {
                guard hypot(old.x - now.x, old.y - now.y) > 0.5 else { continue }
                position.fromValue = NSValue(point: CGPoint(x: layer.position.x + old.x - now.x,
                                                            y: layer.position.y + old.y - now.y))
                animations = [position]
            } else {
                let source = sourcePoint ?? now
                position.fromValue = NSValue(point: CGPoint(x: layer.position.x + source.x - now.x,
                                                            y: layer.position.y + source.y - now.y))
                let cx = view.bounds.width * 0.5, cy = view.bounds.height * 0.5
                var start = CATransform3DMakeTranslation(cx, cy, 0)
                start = CATransform3DScale(start, appearScale, appearScale, 1)
                start = CATransform3DTranslate(start, -cx, -cy, 0)
                let transform = CABasicAnimation(keyPath: "transform")
                transform.fromValue = start
                transform.toValue = layer.transform
                let opacity = CABasicAnimation(keyPath: "opacity")
                opacity.fromValue = 0
                opacity.toValue = layer.opacity
                animations = [position, transform, opacity]
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = 0.36
            group.timingFunction = launchpadTimingFunction
            layer.add(group, forKey: "folder.layoutChange")
        }
    }
}
