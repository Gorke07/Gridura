import AppKit

/// Creates and animates the launchpad panel: show/hide, gesture tracking, screen handling
///.
final class LaunchpadWindowController: NSWindowController {
    static let shared = LaunchpadWindowController()

    private unowned let appState = AppState.shared

    let backgroundVC = BackgroundViewController()
    let launchpadVC: LaunchpadViewController

    private lazy var windowSurfaceView = LaunchpadWindowSurfaceView(cornerRadius: windowCornerRadius, hiddenScale: hiddenScale)
    private var windowContentWidthConstraint: NSLayoutConstraint?
    private var windowContentHeightConstraint: NSLayoutConstraint?
    private var windowSurfaceConstraints: [NSLayoutConstraint] = []
    private var contentConstraints: [NSLayoutConstraint] = []

    private var isFirstLaunch = true
    var presentationRequestID = 0

    private let hiddenScale: CGFloat = 1.05
    private let windowCornerRadius: CGFloat = 34
    private let animationDuration: Double = 0.24
    private let trackDuration: Double = 0.42
    private let minimumWindowSize = CGSize(width: 100, height: 100)
    private let fullScreenTransitionAnimationKey = "launchpad.fullScreenTransition"

    private var screenObserver: NSObjectProtocol?
    private struct ScreenInfo { var count: Int; var visibleFrame: CGRect }
    private var screenInfo = ScreenInfo(count: NSScreen.screens.count, visibleFrame: .zero)

    private var menuBarTimer: Timer?
    private var lastMenuBarAlpha: Float = 1.0

    private var fadeState: WindowFadeState = .idle
    private var fadeGeneration: UInt = 0
    private var pendingHideCompletions: [() -> Void] = []
    private var pinStartTime: Double = 0
    var ignoreNextResignKey = false

    private override init(window: NSWindow?) {
        launchpadVC = LaunchpadViewController(nibName: nil, bundle: nil)
        super.init(window: nil)
        let panel = AlwaysKeyPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
        self.window = panel
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.alphaValue = 1
        panel.animationBehavior = .none
        panel.delegate = self

        launchpadVC.view.wantsLayer = true
        if let screen = NSScreen.launchScreen {
            screenInfo = ScreenInfo(count: NSScreen.screens.count, visibleFrame: screen.visibleFrame)
            panel.setFrame(appState.displayMode == .window ? windowRect(on: screen) : screen.frame, display: false)
        } else {
            panel.center()
        }
        applyDisplayMode()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screenParametersChanged()
        }
        screenshotDebugName = "Gridura"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var screenshotDebugName: String?

    // MARK: - Display mode

    func applyDisplayMode() {
        guard let window else { return }
        let wasVisible = window.isVisible
        let wasKey = window.isKeyWindow
        if appState.displayMode == .window {
            window.backgroundColor = .clear
            window.isOpaque = false
            window.appearance = nil
            window.styleMask = [.nonactivatingPanel, .fullSizeContentView]
            window.setPrivateCornerRadius(0)
            window.hasShadow = false
            window.contentAspectRatio = .zero
            window.minSize = .zero
            window.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
            window.level = .floating
        } else {
            applyOpaqueBlackIfNeeded(window)
            window.appearance = NSAppearance(named: .darkAqua)
            window.styleMask = [.nonactivatingPanel]
            window.contentAspectRatio = .zero
            window.setPrivateCornerRadius(0)
            window.hasShadow = false
            window.minSize = .zero
            window.collectionBehavior = [.transient, .stationary, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllApplications]
            updateLevel()
        }
        backgroundVC.refresh(sync: false)
        installContentViews()
        if let screen = NSScreen.launchScreen {
            window.setFrame(appState.displayMode == .window ? windowRect(on: screen) : screen.frame, display: true)
        }
        if wasVisible { wasKey ? window.makeKeyAndOrderFront(nil) : window.orderFront(nil) }
    }

    private func applyOpaqueBlackIfNeeded(_ window: NSWindow) {
        if #unavailable(macOS 27) {
            window.backgroundColor = .black
            window.isOpaque = true
        }
    }

    func updateLevel() {
        guard let window else { return }
        window.level = appState.displayMode == .window ? .floating : (appState.hideDock ? NSWindow.Level(rawValue: 1000) : NSWindow.Level(rawValue: 19))
    }

    // MARK: - Geometry

    private func contentSize(on screen: NSScreen) -> CGSize {
        let vf = screen.visibleFrame
        let w = Double(appState.columnsPerPage) * 114 + 44
        let h = Double(appState.rowsPerPage) * 108 + 108
        let maxW = max(1, vf.width / 1.05)
        let maxH = max(1, vf.height / 1.05)
        return CGSize(width: min(maxW, max(100, w)), height: min(maxH, max(100, h)))
    }

    private func windowRect(on screen: NSScreen) -> CGRect {
        let s = contentSize(on: screen)
        let vf = screen.visibleFrame
        let W = Double(Int(s.width * 1.05))
        let H = Double(Int(s.height * 1.05))
        return CGRect(x: vf.midX - W * 0.5, y: vf.midY - H * 0.5, width: W, height: H)
    }

    func relayoutWindowFrame() {
        guard let window, appState.displayMode == .window, let screen = NSScreen.launchScreen else { return }
        window.setFrame(windowRect(on: screen), display: true)
        updateSurfaceSizeConstraints()
        installContentViews()
        launchpadVC.contentView.relayout()
    }

    // MARK: - View hierarchy

    private func installContentViews() {
        guard let window, let root = window.contentView else { return }
        let isWindowMode = appState.displayMode == .window
        let targetContainer: NSView = isWindowMode ? windowSurfaceView.contentView : root
        if backgroundVC.view.superview === targetContainer {
            updateSurfaceSizeConstraints()
            root.layoutSubtreeIfNeeded()
            return
        }

        NSLayoutConstraint.deactivate(windowSurfaceConstraints)
        NSLayoutConstraint.deactivate(contentConstraints)
        windowSurfaceConstraints.removeAll()
        contentConstraints.removeAll()
        windowSurfaceView.removeFromSuperview()

        backgroundVC.view.translatesAutoresizingMaskIntoConstraints = false
        launchpadVC.view.translatesAutoresizingMaskIntoConstraints = false

        if isWindowMode {
            windowSurfaceView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(windowSurfaceView)
            windowSurfaceConstraints = [
                windowSurfaceView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                windowSurfaceView.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            ]
            let width = windowSurfaceView.widthAnchor.constraint(equalToConstant: 100)
            let height = windowSurfaceView.heightAnchor.constraint(equalToConstant: 100)
            windowContentWidthConstraint = width
            windowContentHeightConstraint = height
            windowSurfaceConstraints.append(contentsOf: [width, height])
            NSLayoutConstraint.activate(windowSurfaceConstraints)
            windowSurfaceView.setWindowMode(true)
        } else {
            windowSurfaceView.setWindowMode(false)
        }

        for sub in [backgroundVC.view, launchpadVC.view] {
            if sub.superview !== targetContainer {
                sub.removeFromSuperview()
                targetContainer.addSubview(sub)
            }
        }
        contentConstraints = [
            backgroundVC.view.leadingAnchor.constraint(equalTo: targetContainer.leadingAnchor),
            backgroundVC.view.trailingAnchor.constraint(equalTo: targetContainer.trailingAnchor),
            backgroundVC.view.topAnchor.constraint(equalTo: targetContainer.topAnchor),
            backgroundVC.view.bottomAnchor.constraint(equalTo: targetContainer.bottomAnchor),
            launchpadVC.view.leadingAnchor.constraint(equalTo: targetContainer.leadingAnchor),
            launchpadVC.view.trailingAnchor.constraint(equalTo: targetContainer.trailingAnchor),
            launchpadVC.view.topAnchor.constraint(equalTo: targetContainer.topAnchor),
            launchpadVC.view.bottomAnchor.constraint(equalTo: targetContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(contentConstraints)
        updateSurfaceSizeConstraints()
        ToastManager.shared.attach(targetContainer, window: window)
        root.layoutSubtreeIfNeeded()
    }

    private func updateSurfaceSizeConstraints() {
        guard appState.displayMode == .window, let screen = NSScreen.launchScreen else { return }
        let size = contentSize(on: screen)
        windowContentWidthConstraint?.constant = size.width
        windowContentHeightConstraint?.constant = size.height
    }

    // MARK: - Toggle / show / hide

    func toggle() {
        guard let window else { return }
        switch fadeState {
        case .idle:
            if !window.isVisible { show(); return }
            presentationRequestID += 1
            if window.isVisible { hide() }
        case .fadingIn:
            presentationRequestID += 1
            if window.isVisible { hide() }
        case .fadingOut:
            show()
        }
    }

    func show() {
        guard let window else { return }
        presentationRequestID += 1
        let id = presentationRequestID
        positionWindow(onlyIfHidden: false)
        backgroundVC.refresh(sync: true)
        if isFirstLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.presentationRequestID == id else { return }
                self.animateShow(duration: nil)
                self.isFirstLaunch = false
            }
        } else {
            _ = window
            animateShow(duration: nil)
        }
    }

    func hide(duration: TimeInterval? = nil, completion: (() -> Void)? = nil) {
        if let completion { pendingHideCompletions.append(completion) }
        guard fadeState != .fadingOut else { return }
        if appState.displayMode == .window { hideWindowMode(duration) } else { hideFullScreen(duration) }
    }

    private func animateShow(duration: TimeInterval?) {
        pendingHideCompletions.removeAll()
        if appState.displayMode == .window { showWindowMode(duration) } else { showFullScreen(duration) }
    }

    private func positionWindow(onlyIfHidden: Bool) {
        guard let window, let screen = NSScreen.launchScreen else { return }
        if onlyIfHidden && window.isVisible { return }
        let target = appState.displayMode == .window ? windowRect(on: screen) : screen.frame
        if window.frame != target || screenInfo.visibleFrame != screen.visibleFrame {
            screenInfo = ScreenInfo(count: NSScreen.screens.count, visibleFrame: screen.visibleFrame)
            launchpadVC.contentView.relayout()
            window.setFrame(target, display: true)
            installContentViews()
        }
    }

    // MARK: - Full-screen animations

    private func showFullScreen(_ duration: TimeInterval?) {
        guard let window, let bg = backgroundVC.view.layer, let content = launchpadVC.view.layer, fadeState != .fadingIn else { return }
        updateFrameRange()
        let current = bg.presentation()?.opacity ?? bg.opacity
        let currentScale = content.presentation()?.transform.m11 ?? content.transform.m11
        let d = duration ?? Double(1 - current) * animationDuration
        animateMenuBarAlpha(from: 1 - current, to: 0, duration: d)
        content.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        content.position = CGPoint(x: window.frame.midX, y: window.frame.midY)
        fadeGeneration += 1
        let generation = fadeGeneration
        fadeState = .fadingIn
        window.backgroundColor = .clear
        window.isOpaque = false
        if !window.isVisible {
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
        }
        bg.removeAnimation(forKey: fullScreenTransitionAnimationKey)
        content.removeAnimation(forKey: fullScreenTransitionAnimationKey)

        let bgAnimation = CABasicAnimation(keyPath: "opacity")
        bgAnimation.fromValue = current
        bgAnimation.toValue = 1.0
        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = currentScale
        scaleAnimation.toValue = 1.0
        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = current
        opacityAnimation.toValue = 1.0
        for animation in [bgAnimation, scaleAnimation, opacityAnimation] {
            animation.duration = d
            animation.timingFunction = DesignTokens.animationEaseOut
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            animation.preferredFrameRateRange = currentFrameRange
        }
        let group = CAAnimationGroup()
        group.animations = [scaleAnimation, opacityAnimation]
        group.duration = d
        group.timingFunction = DesignTokens.animationEaseOut
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        group.preferredFrameRateRange = currentFrameRange

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.finishShowFullScreen(generation, backgroundLayer: bg, contentLayer: content)
        }
        bg.add(bgAnimation, forKey: fullScreenTransitionAnimationKey)
        content.add(group, forKey: fullScreenTransitionAnimationKey)
        CATransaction.commit()
    }

    private func finishShowFullScreen(_ generation: UInt, backgroundLayer: CALayer, contentLayer: CALayer) {
        guard fadeState == .fadingIn, fadeGeneration == generation else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.opacity = 1
        contentLayer.opacity = 1
        contentLayer.transform = CATransform3DIdentity
        backgroundLayer.removeAnimation(forKey: fullScreenTransitionAnimationKey)
        contentLayer.removeAnimation(forKey: fullScreenTransitionAnimationKey)
        CATransaction.commit()
        if let window { applyOpaqueBlackIfNeeded(window) }
        fadeState = .idle
    }

    private func hideFullScreen(_ duration: TimeInterval?) {
        guard let window, let bg = backgroundVC.view.layer, let content = launchpadVC.view.layer, fadeState != .fadingOut else { return }
        updateFrameRange()
        let current = bg.presentation()?.opacity ?? bg.opacity
        let currentScale = content.presentation()?.transform.m11 ?? content.transform.m11
        let d = duration ?? Double(current) * animationDuration
        animateMenuBarAlpha(from: 1 - current, to: 1, duration: d)
        content.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        content.position = CGPoint(x: window.frame.midX, y: window.frame.midY)
        fadeGeneration += 1
        let generation = fadeGeneration
        fadeState = .fadingOut
        window.backgroundColor = .clear
        window.isOpaque = false
        bg.removeAnimation(forKey: fullScreenTransitionAnimationKey)
        content.removeAnimation(forKey: fullScreenTransitionAnimationKey)

        let bgAnimation = CABasicAnimation(keyPath: "opacity")
        bgAnimation.fromValue = current
        bgAnimation.toValue = 0
        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = currentScale
        scaleAnimation.toValue = hiddenScale
        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = current
        opacityAnimation.toValue = 0
        for animation in [bgAnimation, scaleAnimation, opacityAnimation] {
            animation.duration = d
            animation.timingFunction = DesignTokens.animationEaseOut
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        let group = CAAnimationGroup()
        group.animations = [scaleAnimation, opacityAnimation]
        group.duration = d
        group.timingFunction = DesignTokens.animationEaseOut
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.finishHideFullScreen(generation, backgroundLayer: bg, contentLayer: content, window: window)
        }
        bg.add(bgAnimation, forKey: fullScreenTransitionAnimationKey)
        content.add(group, forKey: fullScreenTransitionAnimationKey)
        CATransaction.commit()
    }

    private func finishHideFullScreen(_ generation: UInt, backgroundLayer: CALayer, contentLayer: CALayer, window: NSWindow) {
        guard fadeState == .fadingOut, fadeGeneration == generation else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.opacity = 0
        contentLayer.opacity = 0
        contentLayer.transform = CATransform3DMakeScale(hiddenScale, hiddenScale, 1)
        backgroundLayer.removeAnimation(forKey: fullScreenTransitionAnimationKey)
        contentLayer.removeAnimation(forKey: fullScreenTransitionAnimationKey)
        CATransaction.commit()
        fadeState = .idle
        window.alphaValue = 0
        window.orderOut(nil)
        runPendingHideCompletions()
    }

    // MARK: - Window-mode animations

    private func showWindowMode(_ duration: TimeInterval?) {
        guard let window, fadeState != .fadingIn else { return }
        updateFrameRange()
        fadeGeneration += 1
        let generation = fadeGeneration
        fadeState = .fadingIn
        let alpha = window.alphaValue
        let d = duration ?? Double(1 - alpha) * animationDuration
        if !window.isVisible {
            window.alphaValue = alpha
            windowSurfaceView.setRevealProgress(alpha, duration: 0, immediate: true)
            window.makeKeyAndOrderFront(nil)
        }
        windowSurfaceView.setRevealProgress(1, duration: d, immediate: false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = d
            context.timingFunction = DesignTokens.animationEaseOut
            window.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.fadeState == .fadingIn, self.fadeGeneration == generation else { return }
                self.fadeState = .idle
                self.window?.alphaValue = 1
                self.windowSurfaceView.setRevealProgress(1, duration: 0, immediate: true)
            }
        })
    }

    private func hideWindowMode(_ duration: TimeInterval?) {
        guard let window, fadeState != .fadingOut else { return }
        updateFrameRange()
        fadeGeneration += 1
        let generation = fadeGeneration
        fadeState = .fadingOut
        let d = duration ?? Double(window.alphaValue) * animationDuration
        windowSurfaceView.setRevealProgress(0, duration: d, immediate: false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = d
            context.timingFunction = DesignTokens.animationEaseOut
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.fadeState == .fadingOut, self.fadeGeneration == generation else { return }
                self.fadeState = .idle
                self.window?.alphaValue = 0
                self.windowSurfaceView.setRevealProgress(0, duration: 0, immediate: true)
                self.window?.orderOut(nil)
                self.runPendingHideCompletions()
            }
        })
    }

    private func runPendingHideCompletions() {
        let completions = pendingHideCompletions
        pendingHideCompletions.removeAll()
        completions.forEach { $0() }
    }

    // MARK: - Menu bar alpha

    private var currentFrameRange: CAFrameRateRange {
        let fps = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        let f = fps <= 60 ? 60 : fps
        let maxF = min(f, 240)
        let preferred = min(maxF, 120)
        return CAFrameRateRange(minimum: 60, maximum: maxF, preferred: preferred)
    }

    private func updateFrameRange() {}

    private func animateMenuBarAlpha(from: Float, to: Float, duration: Double) {
        menuBarTimer?.invalidate()
        menuBarTimer = nil
        let start = max(0, min(from, 1))
        let end = max(0, min(to, 1))
        if duration > 0.08 && abs(end - start) >= 0.01 {
            let startTime = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                let k = max(0, min((CACurrentMediaTime() - startTime) / duration, 1))
                let alpha = max(0, min(start + (end - start) * Float(k), 1))
                guard let self else { return }
                if abs(alpha - self.lastMenuBarAlpha) >= 0.01 {
                    self.lastMenuBarAlpha = alpha
                    PrivateAPI.setMenuBarAlpha(alpha)
                }
                if k >= 1 {
                    self.lastMenuBarAlpha = end
                    PrivateAPI.setMenuBarAlpha(end)
                    timer.invalidate()
                    if self.menuBarTimer === timer { self.menuBarTimer = nil }
                }
            }
            timer.tolerance = 1.0 / 60
            RunLoop.main.add(timer, forMode: .common)
            menuBarTimer = timer
        } else {
            lastMenuBarAlpha = max(0, end)
            PrivateAPI.setMenuBarAlpha(end)
        }
    }

    // MARK: - Gesture tracking

    /// 0 unless the window is visible; otherwise the background layer's opacity × the window alpha
    /// (`visibleOpacity`).
    func visibleOpacity() -> CGFloat {
        guard let window, window.isVisible, window.alphaValue > 0.01 else { return 0 }
        let layer = backgroundVC.view.layer
        let opacity = layer?.presentation()?.opacity ?? layer?.opacity ?? 1
        return CGFloat(opacity) * window.alphaValue
    }

    func handleGestureBegan(_ gesture: TrackpadGestureDirection) {
        guard let window else { return }
        window.backgroundColor = .clear
        window.isOpaque = false
        if fadeState == .fadingOut && gesture == .pinchIn { fadeState = .idle }
        if gesture == .pinchIn { positionWindow(onlyIfHidden: false) }
        pinStartTime = 0
    }

    func handleGestureProgress(_ gesture: TrackpadGestureDirection, progress: CGFloat) {
        if appState.displayMode == .window { windowTrackProgress(progress, gesture: gesture) }
        else { trackProgress(progress, gesture: gesture) }
    }

    func handleGestureCompleted(_ gesture: TrackpadGestureDirection, progress: CGFloat) {
        trackCompleted(progress, gesture: gesture)
    }

    private func trackProgress(_ p: CGFloat, gesture: TrackpadGestureDirection) {
        guard let window, let bg = backgroundVC.view.layer, let content = launchpadVC.view.layer else { return }
        let v = gesture == .pinchOut ? 1 - p : p
        let current = bg.presentation()?.opacity ?? bg.opacity
        if pinStartTime == 0 {
            if gesture == .pinchIn {
                guard current != 1 || !window.isVisible else { return }
                if !window.isVisible {
                    backgroundVC.refresh(sync: true)
                    window.alphaValue = 1
                    window.makeKeyAndOrderFront(nil)
                }
            } else {
                guard current != 0 else { return }
            }
            pinStartTime = Date().timeIntervalSince1970
        }
        PrivateAPI.setMenuBarAlpha(Float(1 - current))
        content.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        content.position = CGPoint(x: window.frame.midX, y: window.frame.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bg.removeAllAnimations()
        content.removeAllAnimations()
        bg.opacity = Float(v)
        content.transform = CATransform3DMakeScale(1.05 - 0.05 * v, 1.05 - 0.05 * v, 1)
        content.opacity = Float(v)
        CATransaction.commit()
    }

    private func windowTrackProgress(_ p: CGFloat, gesture: TrackpadGestureDirection) {
        guard let window else { return }
        let v = gesture == .pinchOut ? 1 - p : p
        if pinStartTime == 0 {
            if gesture == .pinchIn {
                guard window.alphaValue != 1 || !window.isVisible else { return }
                if !window.isVisible {
                    window.alphaValue = 0
                    windowSurfaceView.setRevealProgress(0, duration: 0, immediate: true)
                    backgroundVC.refresh(sync: true)
                    window.makeKeyAndOrderFront(nil)
                }
            } else {
                guard window.alphaValue != 0 else { return }
            }
            pinStartTime = Date().timeIntervalSince1970
        }
        window.alphaValue = v
        windowSurfaceView.setRevealProgress(v, duration: 0, immediate: true)
    }

    private func trackCompleted(_ p: CGFloat, gesture: TrackpadGestureDirection) {
        guard pinStartTime != 0, let window else { return }
        let current = appState.displayMode == .window
            ? Double(window.alphaValue)
            : Double(backgroundVC.view.layer?.presentation()?.opacity ?? backgroundVC.view.layer?.opacity ?? 0)
        if current == 1 && gesture == .pinchIn { return }
        if current == 0 && gesture == .pinchOut { return }
        let elapsed = Date().timeIntervalSince1970 - pinStartTime
        switch gesture {
        case .pinchIn:
            if elapsed < 0.5 { animateShow(duration: nil) }
            else if p >= 0.5 { animateShow(duration: trackDuration) }
            else if p > 0 { hide(duration: trackDuration) }
        case .pinchOut:
            if elapsed < 0.5 { hide(duration: nil) }
            else if current > 0.5 { if current < 1 { animateShow(duration: trackDuration) } }
            else { hide(duration: trackDuration) }
        }
    }

    // MARK: - Screen changes

    private func screenParametersChanged() {
        guard let window else { return }
        let count = NSScreen.screens.count
        if count != screenInfo.count {
            screenInfo.count = count
            presentationRequestID += 1
            if window.isVisible {
                hide { [weak self] in self?.relayoutForScreen() }
            } else {
                relayoutForScreen()
            }
        } else {
            relayoutForScreen()
        }
    }

    private func relayoutForScreen() {
        guard let window, let screen = NSScreen.launchScreen else { return }
        let target = appState.displayMode == .window ? windowRect(on: screen) : screen.frame
        if window.frame != target || screenInfo.visibleFrame != screen.visibleFrame {
            screenInfo.visibleFrame = screen.visibleFrame
            window.setFrame(target, display: true)
            installContentViews()
            launchpadVC.contentView.relayout()
        }
        if appState.hotCorner != .off { HotCornersMonitor.shared.reload() }
    }
}

extension LaunchpadWindowController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.handleResignKey() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        PreferencesWindowController.shared.closeIfOpen()
    }

    private func handleResignKey() {
        if ignoreNextResignKey { ignoreNextResignKey = false; return }
        guard let window, window.isVisible, !window.isKeyWindow else { return }
        guard !otherAppWindowVisible() else { return }
        guard fadeState != .fadingIn else { return }
        presentationRequestID += 1
        if window.isVisible { hide() }
    }

    private func otherAppWindowVisible() -> Bool {
        let names: Set<String> = ["UninstallWindow", "PermissionsWindow", "PreferencesWindow",
                                  "ActivationWindow", "PaywallWindow", "ReorganizeLayoutWindow"]
        return NSApp.windows.contains {
            $0.isVisible && $0.alphaValue > 0 && !$0.isMiniaturized && names.contains($0.identifier?.rawValue ?? "")
        }
    }
}

enum TrackpadGestureDirection {
    case pinchIn
    case pinchOut
}
