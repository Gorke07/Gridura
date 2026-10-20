import AppKit

// Dragging an app out of the launcher: the preview moves into a transparent overlay window so it
// can leave the main window, and over the Dock a real AppKit drag starts so the Dock can take the
// app.

extension LaunchpadContentView {
    /// The strip the Dock occupies on `screen` (screen coordinates), nil when it auto-hides.
    func dockRect(on screen: NSScreen) -> CGRect? {
        let full = screen.frame, visible = screen.visibleFrame
        if visible.minY > full.minY + 1 {
            return CGRect(x: full.minX, y: full.minY, width: full.width, height: visible.minY - full.minY)
        }
        if visible.minX > full.minX + 1 {
            return CGRect(x: full.minX, y: full.minY, width: visible.minX - full.minX, height: full.height)
        }
        if visible.maxX < full.maxX - 1 {
            return CGRect(x: visible.maxX, y: full.minY, width: full.maxX - visible.maxX, height: full.height)
        }
        return nil
    }

    ///: called every drag tick for a plain single-app drag.
    func updateDockDrag(_ session: LaunchpadDragSession, mouse: CGPoint) {
        guard session.multi == nil, session.folderCells == nil, session.dockSession == nil,
              let window, let screen = window.screen ?? NSScreen.main,
              let app = session.source.group?.apps.first, !(session.source.group?.isFolder ?? true),
              !(appState.displayMode == .fullScreen && appState.hideDock),
              let dock = dockRect(on: screen) else { return }

        let pointer = NSEvent.mouseLocation
        let inDock = dock.insetBy(dx: -6, dy: -6).contains(pointer)

        // Window mode: near a window edge the preview moves into the overlay window (111 pt).
        if session.overlayWindow == nil, appState.displayMode == .window {
            let frame = window.frame
            let nearEdge = pointer.x < frame.minX + 111 || pointer.x > frame.maxX - 111
                || pointer.y < frame.minY + 111 || pointer.y > frame.maxY - 111
            if nearEdge || inDock { moveToOverlayWindow(session, screen: screen) }
        }

        guard inDock else { return }
        let item = NSPasteboardItem()
        item.setString(app.url.absoluteString, forType: .fileURL)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(CGRect(x: 0, y: 0, width: 1, height: 1), contents: nil)
        guard let event = NSApp.currentEvent else { return }
        let dragSession = beginDraggingSession(with: [dragItem], event: event, source: self)
        dragSession.draggingFormation = .none
        dragSession.animatesToStartingPositionsOnCancelOrFail = false
        session.dockSession = dragSession
    }

    ///: a borderless, click-through window above everything hosts the preview.
    private func moveToOverlayWindow(_ session: LaunchpadDragSession, screen: NSScreen) {
        guard let window else { return }
        let overlay = NSWindow(contentRect: screen.frame, styleMask: [], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = NSWindow.Level(rawValue: 25)
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.hidesOnDeactivate = false
        let content = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        overlay.contentView = content

        let screenRect = window.convertToScreen(convert(session.preview.frame, to: nil))
        session.preview.removeFromSuperview()
        session.preview.frame = screenRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        content.addSubview(session.preview)
        overlay.orderFrontRegardless()
        session.overlayWindow = overlay
    }
}

extension LaunchpadContentView {
    /// Exposed for the self-tests: the Dock strip on `screen`, nil when the Dock auto-hides.
    static func dockStripForTesting(on screen: NSScreen) -> CGRect? {
        LaunchpadContentView(variant: 2).dockRect(on: screen)
    }
}
