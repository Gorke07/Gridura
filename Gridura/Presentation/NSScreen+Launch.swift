import AppKit

extension NSScreen {
    /// The screen the launchpad should appear on, per `LaunchShowOn`.
    static var launchScreen: NSScreen? {
        let appState = AppState.shared
        switch appState.showOn {
        case .primary:
            return NSScreen.screens.first
        case .active:
            return NSScreen.main
        case .cursor:
            let point = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) { return screen }
            return NSScreen.main ?? NSScreen.screens.first
        case .dock:
            if let screen = dockScreen() { return screen }
            return NSScreen.main ?? NSScreen.screens.first
        }
    }

    /// Screen containing the Dock, from the private CoreDock geometry.
    private static func dockScreen() -> NSScreen? {
        guard let rect = PrivateAPI.dockRectValue(), !rect.isEmpty else { return nil }
        var adjusted = rect
        if PrivateAPI.dockAutoHideEnabled() {
            var (orientation, _) = PrivateAPI.dockOrientationAndPinning()
            if orientation > 4 { orientation = 0 }
            switch orientation {
            case 2: adjusted.size.height += 50
            case 3: adjusted.size.width += 50
            case 4: adjusted.origin.x -= (adjusted.width + 50); adjusted.size.width += 50
            default: break
            }
        }
        guard let first = NSScreen.screens.first else { return nil }
        let converted = CGRect(x: adjusted.origin.x,
                               y: first.frame.height - adjusted.origin.y - adjusted.height,
                               width: adjusted.width, height: adjusted.height)
        let midpoint = CGPoint(x: converted.midX, y: converted.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(midpoint) }) { return screen }
        return NSScreen.screens.first { $0.frame.intersects(converted) }
    }
}
