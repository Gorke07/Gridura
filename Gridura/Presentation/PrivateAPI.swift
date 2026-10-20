import Foundation
import AppKit
import CoreGraphics

/// Thin wrappers around the private frameworks the original uses. Every call degrades
/// gracefully when the symbol or selector is unavailable.
enum PrivateAPI {

    // MARK: - SkyLight / CoreGraphics Services

    private static let skyLight: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
    typealias CGSSetMenuBarInsetAndAlphaFn = @convention(c) (Int32, Double, Double, Float) -> Void
    typealias CGSHWCaptureWindowListFn = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, Int, UInt32) -> Unmanaged<CFArray>?

    private static let mainConnectionID: CGSMainConnectionIDFn? = {
        guard let handle = skyLight, let sym = dlsym(handle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: CGSMainConnectionIDFn.self)
    }()

    private static let setMenuBarInsetAndAlpha: CGSSetMenuBarInsetAndAlphaFn? = {
        guard let handle = skyLight, let sym = dlsym(handle, "CGSSetMenuBarInsetAndAlpha") else { return nil }
        return unsafeBitCast(sym, to: CGSSetMenuBarInsetAndAlphaFn.self)
    }()

    private static let hwCaptureWindowList: CGSHWCaptureWindowListFn? = {
        guard let handle = skyLight, let sym = dlsym(handle, "CGSHWCaptureWindowList") else { return nil }
        return unsafeBitCast(sym, to: CGSHWCaptureWindowListFn.self)
    }()

    static var connectionID: Int32 { mainConnectionID?() ?? 0 }

    static func setMenuBarAlpha(_ alpha: Float) {
        guard let fn = setMenuBarInsetAndAlpha else { return }
        fn(connectionID, 0.0, 1.0, max(0, min(1, alpha)))
    }

    /// Screenshots a window list, used to capture the live desktop wallpaper.
    static func captureWindow(_ windowID: CGWindowID, options: UInt32 = 0x80a00) -> CGImage? {
        guard let fn = hwCaptureWindowList else { return nil }
        var id = windowID
        guard let array = fn(connectionID, &id, 1, options)?.takeRetainedValue() as? [CGImage] else { return nil }
        return array.first
    }

    // MARK: - CoreDock (Dock geometry)

    typealias CoreDockGetAutoHideEnabledFn = @convention(c) () -> Bool
    typealias CoreDockGetOrientationAndPinningFn = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
    typealias CoreDockGetRectFn = @convention(c) (UnsafeMutablePointer<CGRect>) -> Void

    private static let coreDock: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/CoreDock.framework/CoreDock", RTLD_LAZY)

    private static let dockAutoHide: CoreDockGetAutoHideEnabledFn? = {
        guard let handle = coreDock, let sym = dlsym(handle, "CoreDockGetAutoHideEnabled") else { return nil }
        return unsafeBitCast(sym, to: CoreDockGetAutoHideEnabledFn.self)
    }()
    private static let dockOrientation: CoreDockGetOrientationAndPinningFn? = {
        guard let handle = coreDock, let sym = dlsym(handle, "CoreDockGetOrientationAndPinning") else { return nil }
        return unsafeBitCast(sym, to: CoreDockGetOrientationAndPinningFn.self)
    }()
    private static let dockRect: CoreDockGetRectFn? = {
        guard let handle = coreDock, let sym = dlsym(handle, "CoreDockGetRect") else { return nil }
        return unsafeBitCast(sym, to: CoreDockGetRectFn.self)
    }()

    typealias CoreDockSendNotificationFn = @convention(c) (CFString, Int32) -> Void
    private static let dockNotification: CoreDockSendNotificationFn? = {
        guard let handle = coreDock, let sym = dlsym(handle, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(sym, to: CoreDockSendNotificationFn.self)
    }()

    /// `CoreDockSendNotification` — e.g. `com.apple.showdesktop.awake` closes Show Desktop.
    static func sendDockNotification(_ name: String) { dockNotification?(name as CFString, 0) }

    static func dockAutoHideEnabled() -> Bool { dockAutoHide?() ?? false }

    static func dockOrientationAndPinning() -> (orientation: Int32, pinning: Int32) {
        guard let fn = dockOrientation else { return (0, 0) }
        var orientation: Int32 = 0
        var pinning: Int32 = 0
        fn(&orientation, &pinning)
        return (orientation, pinning)
    }

    static func dockRectValue() -> CGRect? {
        guard let fn = dockRect else { return nil }
        var rect = CGRect.zero
        fn(&rect)
        return rect
    }
}

extension NSWindow {
    /// Calls the private `_setCornerRadius:` when present.
    func setPrivateCornerRadius(_ radius: CGFloat) {
        let selector = NSSelectorFromString("_setCornerRadius:")
        guard responds(to: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        let imp = method(for: selector)
        let fn = unsafeBitCast(imp, to: Fn.self)
        fn(self, selector, radius)
    }
}

/// `NSGlassEffectView` private KVC keys.
enum GlassVariant {
    static func apply(to view: NSView, variant: Int) {
        guard view.responds(to: NSSelectorFromString("_variant")) else { return }
        view.setValue(variant, forKey: "_variant")
        if view.responds(to: NSSelectorFromString("_adaptiveAppearance")) {
            view.setValue(1, forKey: "_adaptiveAppearance")
        }
    }

    /// Variant used in full-screen / window mode on macOS ≥ 27; 2 on macOS 26.
    static func variant(fullScreen: Bool) -> Int {
        if #available(macOS 27, *) { return fullScreen ? 3 : 1 }
        return 2
    }
}
