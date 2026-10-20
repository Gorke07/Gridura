import AppKit
import ApplicationServices

/// Global input: the F4 / Launchpad key and the trackpad pinch.
///
/// Two `CGEventTap`s: a listen-only tap on multitouch gesture events (type 29) for the custom pinch,
/// and an active tap on key-down (F4) plus dock-control events (type 30) that can swallow the
/// system's own Launchpad / Show Desktop pinch. Both need the Accessibility permission; without it
/// nothing is installed and hot corners and the hotkey still work.
final class InputEventMonitor {
    static let shared = InputEventMonitor()

    var onF4Pressed: (() -> Void)?
    var onGestureBegan: ((TrackpadGestureDirection) -> Void)?
    var onGestureProgress: ((TrackpadGestureDirection, CGFloat) -> Void)?
    var onGestureCompleted: ((TrackpadGestureDirection, CGFloat) -> Void)?

    private enum GestureState: Equatable {
        case idle, possible, tracking(TrackpadGestureDirection), ignored
    }

    // Config
    private var trackpadType: TrackpadType = .off
    private let lockThreshold: CGFloat = 0.035
    private let movementThreshold: CGFloat = 0.06
    private let maxPinchDistance: CGFloat = 0.2
    private let maxProgressStep: CGFloat = 0.05

    // Taps
    private var keyEventTap: CFMachPort?
    private var keyRunLoopSource: CFRunLoopSource?
    private var gestureEventTap: CFMachPort?
    private var gestureRunLoopSource: CFRunLoopSource?
    private var activeConfiguration: (trackpad: TrackpadType, f4: Bool)?

    // System state
    private var observersRegistered = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var isScreenLocked = false
    private var pendingWakeRebuild: DispatchWorkItem?
    private var pendingDisabledTapRebuild: DispatchWorkItem?

    // Gesture state
    private var gestureState: GestureState = .idle
    private var previousTouches: [CGPoint] = []
    private var spreadDistance: CGFloat = 0
    private var movementDistance: CGFloat = 0
    private var movementVector: CGPoint = .zero
    private var desktopGestureEnabled = false
    private var lastProgress: CGFloat = 0
    private var gestureValid = false
    private var systemGesture: TrackpadGestureDirection?
    private var desktopGesture: TrackpadGestureDirection?
    private var systemBreak = false

    private let allowedFingerCounts: [TrackpadType: [Int]] = [.three: [3], .four: [4, 5], .five: [5]]
    private let maxFingers: [TrackpadType: Int] = [.three: 3, .four: 5, .five: 5]

    private init() {}

    // MARK: Entry points

    /// Settings / launch entry point (`updateMonitoring(force: false, …)`).
    func start(reason: String) { updateMonitoring(force: false, reason: reason) }

    func stop() { stopMonitoring() }

    /// Test hook: choose the pinch mode without installing taps.
    func configureForTesting(trackpad: TrackpadType, systemFourFingerPinch: Bool? = nil) {
        trackpadType = trackpad
        systemPinchOverride = systemFourFingerPinch
    }

    private var systemPinchOverride: Bool?

    func stopMonitoring() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stopMonitoring() }
            return
        }
        pendingWakeRebuild?.cancel(); pendingWakeRebuild = nil
        pendingDisabledTapRebuild?.cancel(); pendingDisabledTapRebuild = nil
        stopListeners()
    }

    /// `updateMonitoring(force:reason:)`.
    func updateMonitoring(force: Bool, reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateMonitoring(force: force, reason: reason) }
            return
        }
        registerNotificationObserversOnce()
        pendingWakeRebuild?.cancel(); pendingWakeRebuild = nil
        pendingDisabledTapRebuild?.cancel(); pendingDisabledTapRebuild = nil

        let trusted = AXIsProcessTrusted()
        let trackpad = AppState.shared.trackpadGesture
        let f4 = AppState.shared.enableF4Shortcut
        if !trusted || (trackpad == .off && !f4) {
            stopListeners()
            return
        }
        if !force, let active = activeConfiguration, active.trackpad == trackpad, active.f4 == f4,
           healthCheck(trackpad: active.trackpad, f4: active.f4) {
            return
        }
        stopListeners()
        startListeners(trackpad, f4)
    }

    // MARK: Event taps

    private func startListeners(_ trackpad: TrackpadType, _ f4: Bool) {
        trackpadType = trackpad
        if keyEventTap != nil || gestureEventTap != nil {
            LogManager.shared.info("Trackpad listeners already exist. Recreating…")
            stopListeners()
        }
        // Key tap: F4 → keyDown (1<<10); trackpad ≠ off → type 30 (dock control).
        let keyMask: CGEventMask = (f4 ? 1 << 10 : 0) | (trackpad != .off ? 1 << 30 : 0)

        if trackpad != .off {
            gestureEventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                                options: .listenOnly, eventsOfInterest: 1 << 29,
                                                callback: { _, type, event, _ in
                InputEventMonitor.shared.gestureCallback(type, event)
                return Unmanaged.passUnretained(event)
            }, userInfo: nil)
            guard let tap = gestureEventTap else {
                LogManager.shared.error("Gesture tap create failed.")
                stopListeners()
                return
            }
            gestureRunLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), gestureRunLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        if keyMask != 0 {
            keyEventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                            options: .defaultTap, eventsOfInterest: keyMask,
                                            callback: { _, type, event, _ in
                InputEventMonitor.shared.keyCallback(type, event)
            }, userInfo: nil)
            guard let tap = keyEventTap else {
                LogManager.shared.error("Key tap create failed")
                stopListeners()
                return
            }
            keyRunLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), keyRunLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        if healthCheck(trackpad: trackpad, f4: f4) {
            activeConfiguration = (trackpad, f4)
            LogManager.shared.info("Trackpad listeners started.")
        } else {
            LogManager.shared.error("Trackpad listeners failed health check after creation.")
            stopListeners()
        }
    }

    private func healthCheck(trackpad: TrackpadType, f4: Bool) -> Bool {
        if trackpad == .off && !f4 { return true }
        let gestureOK = trackpad == .off || (gestureEventTap != nil && gestureRunLoopSource != nil
            && CFMachPortIsValid(gestureEventTap) && CGEvent.tapIsEnabled(tap: gestureEventTap!))
        let keyOK = keyEventTap != nil && keyRunLoopSource != nil
            && CFMachPortIsValid(keyEventTap) && CGEvent.tapIsEnabled(tap: keyEventTap!)
        return gestureOK && keyOK
    }

    private func stopListeners() {
        activeConfiguration = nil
        guard keyEventTap != nil || gestureEventTap != nil || keyRunLoopSource != nil || gestureRunLoopSource != nil else {
            return
        }
        if let source = keyRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let source = gestureRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        for tap in [keyEventTap, gestureEventTap] {
            guard let tap else { continue }
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        keyEventTap = nil; keyRunLoopSource = nil
        gestureEventTap = nil; gestureRunLoopSource = nil
        resetGestureState()
        LogManager.shared.info("Trackpad listeners stopped.")
    }

    private func isTapDisabled(_ type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }

    /// Disabled by timeout or user input: rebuild right away (`scheduleDisabledTapRebuild`).
    private func scheduleDisabledTapRebuild(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.scheduleDisabledTapRebuild(reason: reason) }
            return
        }
        guard pendingDisabledTapRebuild == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDisabledTapRebuild = nil
            LogManager.shared.info("Rebuilding disabled event taps. reason:\(reason)")
            self.updateMonitoring(force: true, reason: "event tap disabled:\(reason)")
        }
        pendingDisabledTapRebuild = work
        DispatchQueue.main.async(execute: work)
    }

    // MARK: Key tap

    private func keyCallback(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard AXIsProcessTrusted() else {
            LogManager.shared.error("Accessibility permission is not granted. eventType:\(type.rawValue)")
            stopListeners()
            return pass
        }
        if isTapDisabled(type) {
            scheduleDisabledTapRebuild(reason: "key:\(type.rawValue)")
            return pass
        }
        guard let nsEvent = NSEvent(cgEvent: event) else { return pass }

        switch type.rawValue {
        case CGEventType.keyDown.rawValue:
            guard nsEvent.modifierFlags.contains(.function) else { return pass }
            guard [129, 130, 131, 177].contains(Int(nsEvent.keyCode)) else { return pass }
            LogManager.shared.info("F4 event received. keyCode:\(nsEvent.keyCode); locked\(isScreenLocked)")
            if !isScreenLocked {
                DispatchQueue.main.async { [weak self] in self?.onF4Pressed?() }
            }
            return nil                                          // swallowed (even when locked)
        case 30:
            if isScreenLocked { return nil }
            switch nsEvent.momentumPhase.rawValue {
            case 4:                                             // non-pinch dock gesture
                return hideOnForeignDockGesture(nsEvent) ? pass : nil
            case 8:                                             // pinch dock gesture
                switch trackpadType {
                case .three:
                    return hideOnForeignDockGesture(nsEvent) ? pass : nil
                case .five where gestureState == .idle:
                    return pass
                default:
                    return handleSystemGesture(event, nsEvent) ? nil : pass
                }
            default:
                return pass
            }
        default:
            return pass
        }
    }

    /// A foreign dock gesture (Mission Control swipe, …) hides the launcher. Returns false when our
    /// own pinch is running (the system gesture is then swallowed).
    private func hideOnForeignDockGesture(_ event: NSEvent) -> Bool {
        switch gestureState {
        case .tracking: return false
        case .possible: resetGestureState()
        case .idle, .ignored: break
        }
        if event.phase == .began {
            DispatchQueue.main.async {
                let controller = LaunchpadWindowController.shared
                controller.presentationRequestID += 1
                if controller.window?.isVisible == true { controller.hide() }
            }
        }
        return true
    }

    // MARK: System (Dock) pinch

    private func handleSystemGesture(_ cg: CGEvent, _ event: NSEvent) -> Bool {
        let value = cg.getDoubleValueField(CGEventField(rawValue: 124)!)
        guard value.isFinite else { return false }
        let signed = (cg.getIntegerValueField(CGEventField(rawValue: 136)!) & 1) != 0 ? value : -value

        if event.phase.contains(.began) {
            desktopGesture = nil
            if !gestureValid { LogManager.shared.info("[WARNING] Gesture unavailable") }
            if !systemBreak {
                systemBreak = true
                LogManager.shared.info("[SystemGesture]: system gesture takes over")
            }
            if systemGesture != nil { finishSystemGesture() }
            let gesture: TrackpadGestureDirection = signed < 0 ? .pinchOut : .pinchIn
            switch DockExposeState.current() {
            case .normal:
                let shown = LaunchpadWindowController.shared.visibleOpacity()
                if signed >= 0 && shown >= 0.99 { return true }                    // already shown → swallow
                if signed < 0 && shown <= 0.01 {                                   // spread while hidden → Show Desktop
                    resetGestureState()
                    desktopGesture = gesture
                    return false
                }
                let previous = gestureState
                systemGesture = gesture
                gestureState = .tracking(gesture)
                if previous != .tracking(gesture) { notifyBegan(gesture) }
            case .showDesktop:
                resetGestureState()
                desktopGesture = gesture
                return false
            case .missionControl, .appExpose:
                return true                                                        // intercept
            }
        }

        // changed / ended / cancelled
        var isEnd: Bool
        if event.phase.contains(.ended) {
            if desktopGesture != nil { resetGestureState(); return false }
            isEnd = true
        } else {
            if desktopGesture != nil {
                if event.phase.contains(.cancelled) { resetGestureState() }
                return false
            }
            isEnd = event.phase.contains(.cancelled)
        }
        if abs(value) > .ulpOfOne, let gesture = systemGesture {
            let raw = gesture == .pinchOut ? min(signed, 0) : max(signed, 0)
            let progress = CGFloat(min(abs(raw), 1.0))
            lastProgress = progress
            notifyProgress(gesture, progress)
        }
        if systemGesture != nil && isEnd { finishSystemGesture() }
        return systemGesture != nil
    }

    private func finishSystemGesture() {
        guard let gesture = systemGesture else { return }
        let progress = lastProgress
        resetGestureState()
        notifyCompleted(gesture, progress)
    }

    // MARK: Custom multitouch pinch

    private func gestureCallback(_ type: CGEventType, _ event: CGEvent) {
        guard AXIsProcessTrusted() else {
            LogManager.shared.error("Accessibility permission is not granted. eventType:\(type.rawValue)")
            stopListeners()
            return
        }
        if isTapDisabled(type) {
            scheduleDisabledTapRebuild(reason: "gesture:\(type.rawValue)")
            return
        }
        guard type.rawValue == 29, let nsEvent = NSEvent(cgEvent: event) else { return }
        handleCustomGesture(nsEvent)
    }

    private func handleCustomGesture(_ event: NSEvent) {
        let touches = event.touches(matching: .touching, in: nil).map(\.normalizedPosition)
        let active = !event.phase.contains(.ended) && !event.phase.contains(.cancelled) && event.phase != []
        processTouches(touches, active: active)
    }

    /// The custom pinch state machine, fed with normalised finger positions. `active` is false
    /// when the gesture phase is ended/cancelled.
    func processTouches(_ touches: [CGPoint], active: Bool) {
        if isScreenLocked { return }
        if systemBreak { return }
        let count = touches.count

        if count == 0 && !active {                               // fingers lifted
            if case .tracking(let gesture) = gestureState {
                let progress = lastProgress
                notifyCompleted(gesture, progress)
            }
            resetGestureState()
            return
        }

        var proceed: Bool
        if allowedFingerCounts[trackpadType]?.contains(count) == true {
            if gestureState == .idle {
                gestureValid = true
                gestureState = .possible
                if trackpadType == .four || trackpadType == .five {
                    let systemPinchOn = systemPinchOverride ?? Self.systemFourFingerPinchEnabled()
                    desktopGestureEnabled = systemPinchOn
                    systemBreak = systemPinchOn
                    if systemPinchOn { return }                  // the system dock-control events drive it
                }
                previousTouches = touches
                spreadDistance = 0
                movementVector = .zero
                movementDistance = 0
                return
            }
            proceed = true
        } else {
            proceed = gestureState != .idle
        }
        guard count >= 3, count <= (maxFingers[trackpadType] ?? 3), proceed else { return }
        guard let (previousAligned, currentAligned) = align(previousTouches, touches) else {
            previousTouches = touches
            return
        }
        let (previousCentroid, previousSpread) = metrics(previousAligned)
        let (currentCentroid, currentSpread) = metrics(currentAligned)
        spreadDistance += currentSpread - previousSpread            // > 0 ⇒ fingers spreading
        movementVector.x += currentCentroid.x - previousCentroid.x
        movementVector.y += currentCentroid.y - previousCentroid.y
        movementDistance = hypot(movementVector.x, movementVector.y)
        previousTouches = touches

        switch gestureState {
        case .idle, .ignored:
            return
        case .possible:
            if movementDistance > movementThreshold { return }       // translation ⇒ not a pinch
            if abs(spreadDistance) <= lockThreshold { return }       // not decisive yet
            let gesture: TrackpadGestureDirection = spreadDistance >= 0 ? .pinchOut : .pinchIn
            switch DockExposeState.current() {
            case .normal:
                let shown = LaunchpadWindowController.shared.visibleOpacity()
                if shown >= 0.99 && spreadDistance < 0 { gestureState = .ignored; return }
                if shown <= 0.01 && spreadDistance >= 0 { gestureState = .ignored; return }
            case .showDesktop:
                if spreadDistance < 0 {
                    // Pinch-in while the desktop is shown closes Show Desktop, then we begin opening.
                    PrivateAPI.sendDockNotification(
                        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
                            ? "com.apple.showdesktop.set" : "com.apple.showdesktop.awake")
                } else {
                    gestureState = .ignored
                    return
                }
            case .missionControl, .appExpose:
                gestureState = .ignored
                return
            }
            spreadDistance = 0
            notifyBegan(gesture)
            notifyProgress(gesture, 0)
            gestureState = .tracking(gesture)
        case .tracking(let gesture):
            let distance = gesture == .pinchOut ? spreadDistance : -spreadDistance
            let target = min(max(distance / maxPinchDistance, 0), 1)
            let delta = target - lastProgress
            var progress = abs(delta) <= maxProgressStep ? target : lastProgress + (delta > 0 ? maxProgressStep : -maxProgressStep)
            progress = min(max(progress, 0), 1)
            lastProgress = progress
            notifyProgress(gesture, progress)
        }
    }

    /// `centroid = mean(P)`, `spread = Σ |p − centroid|²` (not square-rooted)
    private func metrics(_ points: [CGPoint]) -> (CGPoint, CGFloat) {
        guard !points.isEmpty else { return (.zero, 0) }
        let centroid = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                               y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        let spread = points.reduce(CGFloat(0)) { $0 + pow($1.x - centroid.x, 2) + pow($1.y - centroid.y, 2) }
        return (centroid, spread)
    }

    /// Pairs the previous and current fingers. Equal counts are used as they are; with different
    /// counts the larger set is reduced to the combination/permutation closest to the smaller one.
    private func align(_ previous: [CGPoint], _ current: [CGPoint]) -> ([CGPoint], [CGPoint])? {
        if previous.count == current.count { return (previous, current) }
        let k = min(previous.count, current.count)
        guard k > 0, allowedFingerCounts[trackpadType]?.contains(k) == true else { return nil }
        let previousIsLarger = previous.count > current.count
        let larger = previousIsLarger ? previous : current
        let smaller = previousIsLarger ? current : previous

        var best: [CGPoint]?
        var bestCost = CGFloat.greatestFiniteMagnitude
        func permutations(_ items: [CGPoint]) -> [[CGPoint]] {
            guard items.count > 1 else { return [items] }
            return items.indices.flatMap { index -> [[CGPoint]] in
                var rest = items
                let head = rest.remove(at: index)
                return permutations(rest).map { [head] + $0 }
            }
        }
        func combinations(_ items: [CGPoint], _ size: Int) -> [[CGPoint]] {
            if size == 0 { return [[]] }
            guard items.count >= size else { return [] }
            return (0...(items.count - size)).flatMap { index in
                combinations(Array(items[(index + 1)...]), size - 1).map { [items[index]] + $0 }
            }
        }
        for combination in combinations(larger, k) {
            for ordering in permutations(combination) {
                let cost = zip(ordering, smaller).reduce(CGFloat(0)) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }
                if cost < bestCost { bestCost = cost; best = ordering }
            }
        }
        guard let chosen = best else { return nil }
        return previousIsLarger ? (chosen, smaller) : (smaller, chosen)
    }

    /// `TrackpadFourFingerPinchGesture == 2` in `com.apple.AppleMultitouchTrackpad`.
    private static func systemFourFingerPinchEnabled() -> Bool {
        let value = CFPreferencesCopyAppValue("TrackpadFourFingerPinchGesture" as CFString,
                                              "com.apple.AppleMultitouchTrackpad" as CFString)
        guard let number = value as? NSNumber else {
            LogManager.shared.info("[WARNING] TrackpadFourFingerPinchGesture: no numeric value found")
            return false
        }
        return number.intValue == 2
    }

    private func resetGestureState() {
        gestureState = .idle
        previousTouches = []
        lastProgress = 0
        spreadDistance = 0
        movementDistance = 0
        movementVector = .zero
        gestureValid = false
        systemGesture = nil
        desktopGesture = nil
        systemBreak = false
    }

    // MARK: Callbacks (always on the main queue)

    private func notifyBegan(_ gesture: TrackpadGestureDirection) {
        DispatchQueue.main.async { [weak self] in self?.onGestureBegan?(gesture) }
    }

    private func notifyProgress(_ gesture: TrackpadGestureDirection, _ progress: CGFloat) {
        DispatchQueue.main.async { [weak self] in self?.onGestureProgress?(gesture, progress) }
    }

    private func notifyCompleted(_ gesture: TrackpadGestureDirection, _ progress: CGFloat) {
        DispatchQueue.main.async { [weak self] in self?.onGestureCompleted?(gesture, progress) }
    }

    // MARK: Sleep / wake / lock

    private func registerNotificationObserversOnce() {
        guard !observersRegistered else { return }
        observersRegistered = true
        let center = NSWorkspace.shared.notificationCenter

        func observe(_ name: Notification.Name, _ handler: @escaping () -> Void) {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() })
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.isScreenLocked = false
            self?.resume(reason: "sessionDidBecomeActive")
        }
        observe(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.suspend("sessionDidResignActive") }
        observe(NSWorkspace.didWakeNotification) { [weak self] in self?.resume(reason: "didWake") }
        observe(NSWorkspace.willSleepNotification) { [weak self] in self?.suspend("willSleep") }
        observe(NSWorkspace.screensDidWakeNotification) { [weak self] in self?.resume(reason: "screensDidWake") }
        observe(NSWorkspace.screensDidSleepNotification) { [weak self] in self?.suspend("screensDidSleep") }

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                self?.isScreenLocked = true
                LogManager.shared.info("Screen locked.")
            })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                self?.isScreenLocked = false
                LogManager.shared.info("Screen unlocked.")
                self?.updateMonitoring(force: true, reason: "screen unlocked")
            })
        LogManager.shared.info("Notification observers registered")
    }

    private func suspend(_ reason: String) {
        LogManager.shared.info("System suspend. notification:\(reason). Stopping listener.")
        pendingWakeRebuild?.cancel(); pendingWakeRebuild = nil
        pendingDisabledTapRebuild?.cancel(); pendingDisabledTapRebuild = nil
        stopListeners()
    }

    /// After wake the taps are rebuilt 2 s later, once the session is settled.
    private func resume(reason: String) {
        LogManager.shared.info("System resume. reason:\(reason) Rebuilding after 2.0s.")
        resetGestureState()
        pendingWakeRebuild?.cancel()
        pendingDisabledTapRebuild?.cancel(); pendingDisabledTapRebuild = nil
        stopListeners()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingWakeRebuild = nil
            self?.updateMonitoring(force: true, reason: "system resume:\(reason)")
        }
        pendingWakeRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}
