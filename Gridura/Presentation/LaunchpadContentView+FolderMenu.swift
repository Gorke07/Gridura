import AppKit

// Context menu of a folder cell.

extension LaunchpadContentView {
    func folderMenu(for group: LaunchpadGroup) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func item(_ title: String, symbol: String, action: Selector?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.representedObject = group
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }

        menu.addItem(item(NSLocalizedString("Open", comment: ""), symbol: "arrow.up.forward.app",
                          action: #selector(folderMenuOpen(_:))))
        menu.addItem(.separator())

        if !appState.hideNames {
            menu.addItem(item(NSLocalizedString("Rename", comment: ""), symbol: "pencil",
                              action: #selector(folderMenuRename(_:))))
            menu.addItem(.separator())
        }

        if appState.browsingStyle == .paged {
            let move = item(NSLocalizedString("Move to", comment: ""), symbol: "folder", action: nil)
            move.setAccessibilityLabel(NSLocalizedString("Move folder", comment: ""))
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for target in dataManager.pageMoveTargets().targets {
                let entry = NSMenuItem(title: String(format: NSLocalizedString("Page %d", comment: ""), target.pageIndex + 1),
                                       action: #selector(folderMenuMoveToPage(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = group
                entry.tag = target.pageIndex
                if target.pageIndex == group.page {
                    entry.state = .on
                    entry.isEnabled = false
                } else {
                    entry.isEnabled = target.availableSlots > 0
                }
                submenu.addItem(entry)
            }
            move.submenu = submenu
            menu.addItem(move)
            menu.addItem(.separator())
        }

        menu.addItem(item(NSLocalizedString("Ungroup", comment: ""), symbol: "folder.badge.minus",
                          action: #selector(folderMenuUngroup(_:))))
        return menu
    }

    @objc private func folderMenuOpen(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? LaunchpadGroup, let cell = groupViews[group.id] else { return }
        openFolder(groupView: cell, source: 0)
    }

    @objc private func folderMenuRename(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? LaunchpadGroup else { return }
        groupViews[group.id]?.beginRename()
    }

    @objc private func folderMenuMoveToPage(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? LaunchpadGroup else { return }
        let page = sender.tag
        performLayoutChange { dataManager.move([group], toPage: page) }
    }

    /// Ungroup: the apps pop out of the folder's centre (initial scale 0.15).
    @objc private func folderMenuUngroup(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? LaunchpadGroup else { return }
        var source: CGPoint?
        if let cell = groupViews[group.id] {
            let frame = convert(cell.iconContentFrame, from: cell)
            source = CGPoint(x: frame.midX - columnSize.width / 2, y: frame.midY - columnSize.height / 2)
        }
        performLayoutChange(sourcePoint: source, scale: 0.15) { dataManager.dissolveFolder(group) }
    }
}
