#if DEBUG
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Headless UI checks, run with `GRIDURA_SELFTEST=drag` (and `GRIDURA_STORE_DIR` pointing at
/// a scratch directory). Results go to `/tmp/gridura_selftest.log`; the process then exits.
enum SelfTest {
    private static let logPath = "/tmp/gridura_selftest.log"
    private static var window: NSWindow?

    static func log(_ text: String) {
        let line = text + "\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    static func run(_ name: String) {
        try? FileManager.default.removeItem(atPath: logPath)
        log("AXIsProcessTrusted=\(AXIsProcessTrusted())")
        if ProcessInfo.processInfo.environment["GRIDURA_STRESS_LAYOUT"] != nil {
            // Stressor: an unrelated layout pass every 30 ms must never disturb a drag in flight.
            func contents(_ v: NSView, _ out: inout [LaunchpadContentView]) {
                if let c = v as? LaunchpadContentView { out.append(c) }
                v.subviews.forEach { contents($0, &out) }
            }
            Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                var found: [LaunchpadContentView] = []
                for w in NSApp.windows { if let v = w.contentView { contents(v, &found) } }
                found.forEach { $0.relayout() }
            }
        }
        log("selftest \(name) start; store=\(ProcessInfo.processInfo.environment["GRIDURA_STORE_DIR"] ?? "REAL")")
        guard ProcessInfo.processInfo.environment["GRIDURA_STORE_DIR"] != nil else {
            log("refusing to run without GRIDURA_STORE_DIR")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)

        if name == "dockdrag" {
            runDockDrag()
            return
        }
        if name == "pinch" {
            runPinch()
            return
        }
        if name == "trash" {
            runTrash()
            return
        }
        if name == "f4" {
            runF4()
            return
        }
        if name == "hotkey" {
            runHotkey()
            return
        }
        if name == "shot-uninstall" {
            runUninstallShot()
            return
        }
        if name == "shot-guide" {
            runGuideShot()
            return
        }
        if name == "shot-prefs" {
            runPrefsShot()
            return
        }
        if name.hasPrefix("shot-") {
            runShot(String(name.dropFirst(5)))
            return
        }
        if name == "update" {
            runUpdate()
            return
        }
        if name == "scan" {
            runScan()
            return
        }
        if name == "tour2" {
            ApplicationManager.shared.scan(fromBackup: false) {
                LaunchpadDataManager.shared.load {
                    let controller = LaunchpadWindowController.shared
                    controller.show()
                    after(3.0) {
                        guard let win = controller.window else { NSApp.terminate(nil); return }
                        win.level = NSWindow.Level(rawValue: 2000)
                        runTour2(controller.launchpadVC.contentView, win)
                    }
                }
            }
            return
        }
        if name == "tour" {
            ApplicationManager.shared.scan(fromBackup: false) {
                LaunchpadDataManager.shared.load {
                    let controller = LaunchpadWindowController.shared
                    controller.show()
                    after(3.0) {
                        guard let win = controller.window else { NSApp.terminate(nil); return }
                        runTour(controller, win)
                    }
                }
            }
            return
        }
        if name == "folder-anim" {
            ApplicationManager.shared.scan(fromBackup: false) {
                LaunchpadDataManager.shared.load {
                    let controller = LaunchpadWindowController.shared
                    controller.show()
                    after(3.0) {
                        guard let win = controller.window else { NSApp.terminate(nil); return }
                        runFolderAnimation(controller.launchpadVC.contentView, win)
                    }
                }
            }
            return
        }
        if name == "realdrag-app" || name == "realclick" || name == "realsearch" || name == "realsearch2" || name == "realrename" || name == "readme-shots" {
            // The genuine launcher window (panel, view controller, its mouse monitors) with real events.
            // Fill the scratch store first (as the other tests do), then bring up the real launcher.
            ApplicationManager.shared.scan(fromBackup: false) {
                log("scan done; loading")
                LaunchpadDataManager.shared.load {
                    log("loaded; creating the launcher window")
                    let controller = LaunchpadWindowController.shared
                    controller.show()
                    after(3.0) {
                        guard let win = controller.window else { log("no launcher window"); NSApp.terminate(nil); return }
                        win.level = NSWindow.Level(rawValue: 2000)          // keep every click inside our window
                        log("launcher visible=\(win.isVisible) level=\(win.level.rawValue) frame=\(win.frame)")
                        if name == "readme-shots" { runReadmeShots(controller, win) } else if name == "realrename" { runRealRename(controller, win) } else if name == "realsearch2" { runRealSearch2(controller, win) } else if name == "realsearch" { runRealSearch(controller, win) } else if name == "realclick" { runRealClick(controller, win) } else { runRealDrag(controller.launchpadVC.contentView, win) }
                    }
                }
            }
            return
        }
        let dm = LaunchpadDataManager.shared
        let content = LaunchpadContentView(variant: GlassVariant.variant(fullScreen: true))
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = content
        let realPointer = name == "realdrag"
        if realPointer {
            // Real pointer events: an opaque, top-level window covers the screen so no other app is hit.
            win.backgroundColor = .black
            win.level = NSWindow.Level(rawValue: 2000)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            win.alphaValue = 0.01
            win.ignoresMouseEvents = true
            win.level = .normal
            win.orderFrontRegardless()
        }
        window = win
        dm.didDataChange = { content.reload($0) }

        ApplicationManager.shared.scan(fromBackup: false) {
            dm.load {
                switch name {
                case "reorg": after(0.5) { runReorganize(dm) }
                case "realdrag": after(1.5) { runRealDrag(content, win) }
                case "multi": after(1.0) { runMulti(content, dm) }
                case "hide": after(1.0) { runHide(content, dm) }
                case "folder": after(1.0) { runFolder(content, dm) }
                default: after(1.0) { runDrag(content, dm, mode: name) }
                }
            }
        }
    }

    static func beginSyntheticDrag(_ content: LaunchpadContentView, group: LaunchpadGroup, cell: LaunchpadGroupView) -> LaunchpadDragSession? {
        let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        content.beginDrag(group: group, event: event,
                          offset: CGPoint(x: cell.iconContentFrame.width / 2, y: cell.iconContentFrame.height / 2))
        guard let session = content.drag else { return nil }
        session.link?.invalidate(); session.link = nil
        session.isSynthetic = true
        return session
    }

    static func runMulti(_ content: LaunchpadContentView, _ dm: LaunchpadDataManager) {
        log("initial: \(names(content, 12))")
        let groups = Array(content.displayedGroups.prefix(3))
        for group in groups { content.groupViews[group.id]?.isHighlight = true }
        log("selected: \(content.selectedGroups.map { $0.apps.first?.name ?? "?" })")
        guard let dragged = content.groupViews[groups[1].id],
              let session = beginSyntheticDrag(content, group: groups[1], cell: dragged),
              session.multi != nil else { log("multi-drag did not start"); NSApp.terminate(nil); return }
        log("multi started: cards=\(session.multi?.cards.count ?? 0)")
        // Rest on the left margin of the cell at index 8 → the stack lands before it.
        let target = content.groupViews[content.displayedGroups[8].id]!
        let frame = content.convert(target.bounds, from: target)
        let rest = CGPoint(x: frame.minX + 10, y: frame.midY)
        let start = content.convert(CGPoint(x: dragged.iconContentFrame.midX, y: dragged.iconContentFrame.midY), from: dragged)
        script(content, path: [(start, 0.2), (rest, 0.6)]) {
            after(1.5) {
                log("after multi drop: \(names(content, 12))")
                iconReport(content, "multi")
                log("selection left: \(content.selectedGroups.count)")
                log("DONE")
                NSApp.terminate(nil)
            }
        }
    }

    static func runHide(_ content: LaunchpadContentView, _ dm: LaunchpadDataManager) {
        log("initial: \(names(content, 8))")
        guard let app = content.displayedGroups[3].apps.first else { NSApp.terminate(nil); return }
        log("hiding \(app.name)")
        content.hideApps(ids: [app.id])
        after(3.0) {
            log("after hide: \(names(content, 8))  groups=\(content.displayedGroups.count)")
            iconReport(content, "hide")
            log("hidden apps: \(dm.hiddenApps().map(\.name))")
            log("DONE")
            NSApp.terminate(nil)
        }
    }

    static func runFolder(_ content: LaunchpadContentView, _ dm: LaunchpadDataManager) {
        guard let folder = content.displayedGroups.first(where: { $0.isFolder && $0.apps.count >= 4 }),
              let cell = content.groupViews[folder.id] else { log("no folder"); NSApp.terminate(nil); return }
        log("folder \(folder.displayName) apps=\(folder.apps.map(\.name))")
        content.openFolder(groupView: cell, source: 0)
        after(1.0) {
            log("opened: views=\(content.openedFolderAppViews.count)")
            iconReport(content, "folder-open")
            guard let first = content.openedFolderAppViews.first,
                  let firstGroup = first.group,
                  let session = beginSyntheticDrag(content, group: firstGroup, cell: first),
                  session.folderCells != nil else { log("folder drag did not start"); NSApp.terminate(nil); return }
            let third = content.openedFolderAppViews[2]
            let frame = content.convert(third.bounds, from: third)
            let start = content.convert(CGPoint(x: first.iconContentFrame.midX, y: first.iconContentFrame.midY), from: first)
            let rest = CGPoint(x: frame.maxX - 6, y: frame.midY)
            script(content, path: [(start, 0.2), (rest, 0.5)]) {
                after(1.0) {
                    log("folder order now: \(folder.apps.map(\.name))")
                    iconReport(content, "folder-reordered")
                    // Second drag: pull the first app out of the panel.
                    guard let again = content.openedFolderAppViews.first, let g2 = again.group,
                          let s2 = beginSyntheticDrag(content, group: g2, cell: again) else { log("2nd drag failed"); NSApp.terminate(nil); return }
                    _ = s2
                    let start2 = content.convert(CGPoint(x: again.iconContentFrame.midX, y: again.iconContentFrame.midY), from: again)
                    let outside = CGPoint(x: content.bounds.midX, y: 80)
                    script(content, path: [(start2, 0.2), (outside, 0.6)]) {
                        after(2.0) {
                            iconReport(content, "folder-detach")
                            log("after detach: folder apps=\(folder.apps.map(\.name)) folderOpen=\(content.openedFolderID != nil)")
                            log("grid first 8: \(names(content, 8))  groups=\(content.displayedGroups.count)")
                            log("DONE")
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    /// `GRIDURA_SELFTEST=shot-<general|interface|apps|advanced|about>`: renders a settings tab to
    /// `/tmp/gridura_<tab>.png` (light and dark) so the layout can be inspected without the UI.
    static func runShot(_ tab: String) {
        func view(for tab: String) -> AnyView {
            switch tab {
            case "general": return AnyView(GeneralTabView())
            case "interface": return AnyView(InterfaceTabView())
            case "apps": return AnyView(AppsTabView())
            case "advanced": return AnyView(AdvancedTabView())
            default: return AnyView(AboutTabView())
            }
        }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view(for: tab).frame(width: 520))
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            host.frame = CGRect(origin: .zero, size: CGSize(width: 520, height: max(size.height, 200)))
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/gridura_\(tab)_\(suffix).png"))
            }
        }
        log("DONE")
        NSApp.terminate(nil)
    }

    /// Drags an icon with real mouse events down onto the Dock strip, checks that the real AppKit drag
    /// session for the Dock started, then returns to the grid and releases away from the Dock — so
    /// nothing is ever dropped onto (or added to) the user's Dock.
    static func runDockDrag() {
        let previousHideDock = AppState.shared.hideDock
        AppState.shared.hideDock = false                  // the Dock hand-off is off while the Dock is covered
        let screen = NSScreen.main ?? NSScreen.screens[0]
        guard let dock = LaunchpadContentView.dockStripForTesting(on: screen) else {
            log("no visible Dock strip on this screen (auto-hide?)"); AppState.shared.hideDock = previousHideDock
            NSApp.terminate(nil); return
        }
        log("dock strip (screen coords) = \(dock)")
        let dm = LaunchpadDataManager.shared
        let content = LaunchpadContentView(variant: GlassVariant.variant(fullScreen: true))
        let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = content
        win.backgroundColor = .black
        win.level = NSWindow.Level(rawValue: 2000)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        dm.didDataChange = { content.reload($0) }
        ApplicationManager.shared.scan(fromBackup: false) {
            dm.load {
                after(1.5) {
                    let mainHeight = NSScreen.screens[0].frame.height
                    func cg(_ viewPoint: CGPoint) -> CGPoint {
                        let p = win.convertPoint(toScreen: content.convert(viewPoint, to: nil))
                        return CGPoint(x: p.x, y: mainHeight - p.y)
                    }
                    func post(_ type: CGEventType, _ point: CGPoint) {
                        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                            .post(tap: .cghidEventTap)
                    }
                    guard let a = content.groupViews[content.displayedGroups[0].id],
                          !content.displayedGroups[0].isFolder else { log("no app cell"); NSApp.terminate(nil); return }
                    let start = cg(content.convert(CGPoint(x: a.iconContentFrame.midX, y: a.iconContentFrame.midY), from: a))
                    // Over the Dock strip (CG coordinates: y grows downwards from the main screen's top).
                    let dockPoint = CGPoint(x: dock.midX, y: mainHeight - dock.midY)
                    let back = cg(CGPoint(x: content.bounds.midX, y: content.bounds.midY))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { post(.leftMouseUp, back); NSApp.terminate(nil) }
                    func line(_ from: CGPoint, _ to: CGPoint, _ n: Int) -> [(CGEventType, CGPoint)] {
                        (1...n).map { i in
                            let t = CGFloat(i) / CGFloat(n)
                            return (.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                        }
                    }
                    var steps: [(CGEventType, CGPoint)] = [(.mouseMoved, start), (.leftMouseDown, start)]
                    steps += line(start, dockPoint, 50)
                    for _ in 0..<45 { steps.append((.leftMouseDragged, dockPoint)) }
                    var checkedAt = steps.count - 1
                    steps += line(dockPoint, back, 40)
                    steps.append((.leftMouseUp, back))
                    var index = 0
                    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
                        if index == checkedAt {
                            log("over the Dock: drag=\(content.drag != nil) dockSession=\(content.drag?.dockSession != nil) overlay=\(content.drag?.overlayWindow != nil)")
                            checkedAt = -1
                        }
                        guard index < steps.count else {
                            timer.invalidate()
                            after(2.0) {
                                log("after release: drag=\(content.drag == nil ? "ended" : "STUCK")")
                                AppState.shared.hideDock = previousHideDock
                                log("DONE")
                                NSApp.terminate(nil)
                            }
                            return
                        }
                        post(steps[index].0, steps[index].1)
                        index += 1
                    }
                }
            }
        }
    }

    /// Feeds the pinch state machine four fingers closing in (pinch-in) and then spreading (pinch-out)
    /// and logs the began / progress / completed callbacks.
    static func runPinch() {
        let monitor = InputEventMonitor.shared
        monitor.configureForTesting(trackpad: .four, systemFourFingerPinch: false)
        var events: [String] = []
        monitor.onGestureBegan = { events.append("began(\($0))") }
        monitor.onGestureProgress = { events.append(String(format: "progress(%@ %.2f)", "\($0)", $1)) }
        monitor.onGestureCompleted = { events.append(String(format: "completed(%@ %.2f)", "\($0)", $1)) }

        // Four fingers around (0.5, 0.5); `radius` shrinks for a pinch-in.
        func fingers(_ radius: CGFloat) -> [CGPoint] {
            [CGPoint(x: 0.5 - radius, y: 0.5), CGPoint(x: 0.5 + radius, y: 0.5),
             CGPoint(x: 0.5, y: 0.5 - radius), CGPoint(x: 0.5, y: 0.5 + radius)]
        }
        AppState.shared.trackpadGesture = .four
        // The system four-finger pinch preference decides who drives the gesture; report what it is.
        let value = CFPreferencesCopyAppValue("TrackpadFourFingerPinchGesture" as CFString,
                                              "com.apple.AppleMultitouchTrackpad" as CFString)
        log("system four-finger pinch pref = \(String(describing: value))")
        for radius in stride(from: CGFloat(0.30), through: 0.05, by: -0.02) {
            monitor.processTouches(fingers(radius), active: true)
        }
        monitor.processTouches([], active: false)
        // The callbacks hop to the main queue, so let it drain before reading them.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        log("pinch-in: \(events.count) event(s): first=\(events.first ?? "none") last=\(events.last ?? "none")")
        log("   sequence: \(events.prefix(4))")
        events.removeAll()
        // A second gesture: spreading while the launcher is hidden is ignored by the spec.
        monitor.processTouches([], active: false)
        for radius in stride(from: CGFloat(0.05), through: 0.35, by: 0.02) {
            monitor.processTouches(fingers(radius), active: true)
        }
        monitor.processTouches([], active: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        log("pinch-out (launcher hidden → ignored by spec): \(events.count) event(s)")
        log("DONE")
        after(0.5) { NSApp.terminate(nil) }
    }

    /// Runs the real removal path on a throw-away app and leftover files that this test creates.
    static func runTrash() {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let root = "/tmp/gridura_trash_test"
        try? fm.removeItem(atPath: root)
        let appPath = "\(root)/BeTrashProbe.app"
        try? fm.createDirectory(atPath: "\(appPath)/Contents/MacOS", withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.gridura.trashprobe", "CFBundleName": "BeTrashProbe",
                                    "CFBundleExecutable": "BeTrashProbe", "CFBundlePackageType": "APPL"]
        (plist as NSDictionary).write(toFile: "\(appPath)/Contents/Info.plist", atomically: true)
        fm.createFile(atPath: "\(appPath)/Contents/MacOS/BeTrashProbe", contents: Data("x".utf8))
        let cache = "\(home)/Library/Caches/com.gridura.trashprobe"
        let prefs = "\(home)/Library/Preferences/com.gridura.trashprobe.plist"
        try? fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        fm.createFile(atPath: "\(cache)/blob", contents: Data(count: 4096))
        fm.createFile(atPath: prefs, contents: Data("{}".utf8))

        let url = URL(fileURLWithPath: appPath)
        guard let app = ApplicationManager.shared.makeLaunchpadApp(bundleURL: url, displayURL: url) else {
            log("could not read the probe app"); NSApp.terminate(nil); return
        }
        let items = AppUninstallManager.shared.scan(app: app)
        log("scan found \(items.count): \(items.map { "\($0.category):\($0.displayPath)" })")
        let failures = AppUninstallManager.shared.remove(items, appName: "BeTrashProbe")
        log("failures=\(failures.count)")
        for item in items { log("exists after remove? \(fm.fileExists(atPath: item.url.path)) \(item.displayPath)") }
        let inTrash = (try? fm.contentsOfDirectory(atPath: "\(home)/.Trash").filter { $0.contains("BeTrashProbe") || $0.contains("trashprobe") }) ?? []
        log("in Trash: \(inTrash)")
        // Clean up what the probe left in the Trash and /tmp.
        for name in inTrash { try? fm.removeItem(atPath: "\(home)/.Trash/\(name)") }
        try? fm.removeItem(atPath: root)
        log("DONE")
        NSApp.terminate(nil)
    }

    /// Starts the real event taps with the F4 option on and presses the Launchpad key (keyCode 131 + fn).
    static func runF4() {
        let defaults = UserDefaults.standard
        let previousF4 = defaults.object(forKey: "EnableF4Shortcut")
        let previousTrackpad = defaults.object(forKey: "TrackpadGesture")
        AppState.shared.enableF4Shortcut = true
        AppState.shared.trackpadGesture = .off
        var fired = 0
        InputEventMonitor.shared.onF4Pressed = { fired += 1 }
        InputEventMonitor.shared.updateMonitoring(force: true, reason: "self-test")
        after(1.0) {
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 131, keyDown: true)
            event?.flags = .maskSecondaryFn
            event?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 131, keyDown: false)
            up?.flags = .maskSecondaryFn
            after(0.1) { up?.post(tap: .cghidEventTap) }
        }
        after(2.0) {
            log("F4 tap fired \(fired) time(s)")
            InputEventMonitor.shared.stop()
            if let previousF4 { defaults.set(previousF4, forKey: "EnableF4Shortcut") } else { defaults.removeObject(forKey: "EnableF4Shortcut") }
            if let previousTrackpad { defaults.set(previousTrackpad, forKey: "TrackpadGesture") } else { defaults.removeObject(forKey: "TrackpadGesture") }
            log("restored: F4=\(AppState.shared.enableF4Shortcut) trackpad=\(AppState.shared.trackpadGesture)")
            log("DONE")
            NSApp.terminate(nil)
        }
    }

    /// Registers a throw-away shortcut (⌃⌥⌘F18), presses it with real key events and checks that the
    /// Carbon handler fires; the user's stored shortcut is restored afterwards.
    static func runHotkey() {
        let previous = UserDefaults.standard.string(forKey: LaunchShortcut.defaultsKey)
        LaunchShortcut(keyCode: 40 /* K */, carbonModifiers: controlKey | optionKey | cmdKey).save()
        var fired = 0
        HotKeyCenter.shared.onTriggered = { fired += 1 }
        HotKeyCenter.shared.start()
        HotKeyCenter.shared.start()      // idempotent
        log("registrationError=\(String(describing: HotKeyCenter.shared.registrationError)) shortcut=\(LaunchShortcut.current()?.description ?? "nil")")
        // WindowServer matches hot keys against the real modifier state, so press the modifiers first.
        func post(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        let all: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let sequence: [(Double, CGKeyCode, Bool, CGEventFlags)] = [
            (0.5, 59, true, .maskControl), (0.55, 58, true, [.maskControl, .maskAlternate]), (0.6, 55, true, all),
            (0.7, 40, true, all), (0.78, 40, false, all),
            (0.85, 55, false, [.maskControl, .maskAlternate]), (0.9, 58, false, .maskControl), (0.95, 59, false, []),
        ]
        for (time, code, down, flags) in sequence { after(time) { post(code, down, flags) } }
        after(1.5) {
            log("hotkey fired \(fired) time(s); raw event kinds=\(HotKeyCenter.shared.seenEventKinds)")
            if let previous { UserDefaults.standard.set(previous, forKey: LaunchShortcut.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: LaunchShortcut.defaultsKey) }
            log("restored shortcut=\(LaunchShortcut.current()?.description ?? "nil")")
            log("DONE")
            NSApp.terminate(nil)
        }
    }

    /// Opens the uninstall panel for `GRIDURA_SELFTEST_APP` and the Full Disk Access panel, capturing both.
    static func runUninstallShot() {
        let path = ProcessInfo.processInfo.environment["GRIDURA_SELFTEST_APP"] ?? "/Applications/Claude.app"
        let url = URL(fileURLWithPath: path)
        guard let app = ApplicationManager.shared.makeLaunchpadApp(bundleURL: url, displayURL: url) else {
            log("cannot read app"); NSApp.terminate(nil); return
        }
        UninstallWindowController.shared.show(app: app, icon: NSWorkspace.shared.icon(forFile: path))
        after(2.5) {
            if let window = UninstallWindowController.shared.window,
               let image = PrivateAPI.captureWindow(CGWindowID(window.windowNumber)) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/gridura_uninstall.png"))
                log("uninstall panel captured, size=\(window.frame.size)")
            }
            UninstallWindowController.shared.close()
            PermissionsWindowController.shared.show()
            after(1.2) {
                if let window = PermissionsWindowController.shared.window,
                   let image = PrivateAPI.captureWindow(CGWindowID(window.windowNumber)) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "/tmp/gridura_permissions.png"))
                    log("permissions panel captured, size=\(window.frame.size)")
                }
                log("DONE")
                NSApp.terminate(nil)
            }
        }
    }

    /// Captures the four onboarding pages to `/tmp/gridura_guide_<n>.png`.
    static func runGuideShot() {
        func capture(_ index: Int) {
            guard index < 4 else { log("DONE"); NSApp.terminate(nil); return }
            let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 540, height: 680), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentView = NSHostingView(rootView: GuideView(startIndex: index))
            window.orderFrontRegardless()
            after(1.8) {
                if let image = PrivateAPI.captureWindow(CGWindowID(window.windowNumber)) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "/tmp/gridura_guide_\(index).png"))
                    log("page \(index) captured")
                }
                window.orderOut(nil)
                capture(index + 1)
            }
        }
        capture(0)
    }

    /// Mid-interaction captures with real mouse events: merge hover, reorder, multi-drag stack, rename, open folder.
    static func runTour2(_ content: LaunchpadContentView, _ win: NSWindow) {
        let mainHeight = NSScreen.screens[0].frame.height
        func cg(_ point: CGPoint) -> CGPoint {
            let p = win.convertPoint(toScreen: content.convert(point, to: nil))
            return CGPoint(x: p.x, y: mainHeight - p.y)
        }
        func post(_ type: CGEventType, _ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        var shotIndex = 0
        func shot(_ name: String) {
            shotIndex += 1
            if let image = PrivateAPI.captureWindow(CGWindowID(win.windowNumber)) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/gridura_tour2_\(shotIndex)_\(name).png"))
            }
        }
        func viewPoint(_ cell: LaunchpadGroupView, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
            content.convert(CGPoint(x: x, y: y), from: cell)
        }
        func center(_ cell: LaunchpadGroupView) -> CGPoint { viewPoint(cell, cell.iconContentFrame.midX, cell.iconContentFrame.midY) }
        let cells = content.displayedGroups.map { content.groupViews[$0.id]! }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { post(.leftMouseUp, .zero); NSApp.terminate(nil) }

        /// Plays real events, then calls `done`.
        func play(_ steps: [(CGEventType, CGPoint)], done: @escaping () -> Void) {
            var i = 0
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
                guard i < steps.count else { timer.invalidate(); done(); return }
                post(steps[i].0, steps[i].1); i += 1
            }
        }
        func glide(_ a: CGPoint, _ b: CGPoint, _ n: Int = 30) -> [(CGEventType, CGPoint)] {
            (1...n).map { k in let t = CGFloat(k) / CGFloat(n); return (.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
        }
        func hold(_ p: CGPoint, _ frames: Int) -> [(CGEventType, CGPoint)] { Array(repeating: (.leftMouseDragged, p), count: frames) }

        // 1. Merge hover: hold app 0 over the centre of app 3.
        let a = cg(center(cells[0])), onThree = cg(center(cells[3]))
        play([(.mouseMoved, a), (.leftMouseDown, a)] + glide(a, onThree) + hold(onThree, 24)) {
            shot("merge-hover")
            // 2. Move to the left margin of app 8: reorder gap opens while dragging.
            let cell8 = cells[8]
            let margin = cg(viewPoint(cell8, 10, cell8.bounds.midY))
            play(glide(onThree, margin, 30) + hold(margin, 30)) {
                shot("reorder-gap")
                play([(.leftMouseUp, margin)]) {
                    after(1.0) {
                        // 3. Multi-drag stack with the badge.
                        let selected = Array(content.displayedGroups.prefix(3))
                        for g in selected { content.groupViews[g.id]?.isHighlight = true }
                        let live = content.displayedGroups.prefix(3).map { content.groupViews[$0.id]! }
                        let p0 = cg(center(live[1])), far = cg(viewPoint(live[1], 700, -300))
                        play([(.mouseMoved, p0), (.leftMouseDown, p0)] + glide(p0, far, 40) + hold(far, 30)) {
                            shot("multi-stack")
                            play([(.leftMouseUp, far)]) {
                                after(1.2) {
                                    content.clearAllHighlights()
                                    // 4. Rename editor.
                                    if let first = content.displayedGroups.first.flatMap({ content.groupViews[$0.id] }) {
                                        first.beginRename()
                                    }
                                    after(0.6) {
                                        shot("rename")
                                        win.makeFirstResponder(nil)
                                        // 5. Open folder.
                                        if let folder = content.displayedGroups.first(where: { $0.isFolder && $0.apps.count >= 4 }),
                                           let cell = content.groupViews[folder.id] {
                                            content.openFolder(groupView: cell, source: 0)
                                        }
                                        after(1.2) {
                                            shot("folder-open")
                                            iconReport(content, "tour2-end")
                                            log("DONE")
                                            NSApp.terminate(nil)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Visits the main launcher states in the real window and captures each to `/tmp/gridura_tour_<n>_<name>.png`:
    /// grid, search, uninstall mode, scroll mode, window mode, and a drag in progress. Preferences are restored.
    static func runTour(_ controller: LaunchpadWindowController, _ win: NSWindow) {
        let content = controller.launchpadVC.contentView
        let state = AppState.shared
        let original = (state.displayMode, state.browsingStyle)
        var step = 0
        func shot(_ name: String) {
            step += 1
            if let image = PrivateAPI.captureWindow(CGWindowID(win.windowNumber)) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/gridura_tour_\(step)_\(name).png"))
            }
            iconReport(content, name)
        }
        func announce(_ module: PreferenceModule) {
            NotificationChannel.center.post(name: NotificationChannel.Name.preferencesChanged, object: module.rawValue)
        }
        shot("grid")
        // 1. Search
        content.searchView.inputField.stringValue = "ch"
        content.searchView.onDebouncedQueryChanged?("ch", "")
        after(0.8) {
            shot("search")
            content.searchView.clear(notify: true)
            // 2. Uninstall (jiggle) mode with the ✕ buttons
            after(0.6) {
                content.enterUninstallMode(focused: nil)
                after(0.8) {
                    shot("uninstall-mode")
                    content.exitUninstallMode()
                    // 3. Scroll mode
                    state.browsingStyle = .scroll
                    announce(.browsingStyle)
                    after(1.2) {
                        shot("scroll-mode")
                        if let last = content.scrollCells.last {
                            let doc = content.scrollDocumentView
                            log("scroll mode: document height=\(doc.frame.height) last cell maxY=\(last.frame.maxY) cells=\(content.scrollCells.count) columns=\(state.columns)")
                            if last.frame.maxY > doc.frame.height + 0.5 { log("FAIL: last row is outside the scrollable document (unreachable)") }
                        }
                        state.browsingStyle = original.1
                        announce(.browsingStyle)
                        // 4. Window mode
                        after(1.0) {
                            state.displayMode = .window
                            announce(.layout)
                            after(1.6) {
                                shot("window-mode")
                                for cell in content.groupViews.values.sorted(by: { ($0.group?.name ?? "") < ($1.group?.name ?? "") }) {
                                    guard let text = cell.titleString as? NSAttributedString, text.length > 0 else { continue }
                                    let width = ceil(text.size().width), frame = cell.titleFrameInView
                                    if width > frame.width && cell.frame.minX >= 0 && cell.frame.minX < content.bounds.width {
                                        log("long title: \(text.string) text=\(width) layer=\(frame) cell=\(cell.frame.size)")
                                    }
                                }
                                state.displayMode = original.0
                                announce(.layout)
                                after(1.6) {
                                    log("restored displayMode=\(state.displayMode) browsing=\(state.browsingStyle)")
                                    log("DONE")
                                    NSApp.terminate(nil)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Opens and closes a folder in the real launcher window, capturing frames during both animations
    /// to `/tmp/gridura_anim_<open|close>_<n>.png` (the first complaint: oversized first frame, off-centre close).
    static func runFolderAnimation(_ content: LaunchpadContentView, _ win: NSWindow) {
        guard let folder = content.displayedGroups.first(where: { $0.isFolder && $0.apps.count >= 4 }),
              let cell = content.groupViews[folder.id] else { log("no folder"); NSApp.terminate(nil); return }
        func shot(_ tag: String) {
            // Captures stall the frame loop; the hitch probe runs without them unless GRIDURA_SHOTS is set.
            guard ProcessInfo.processInfo.environment["GRIDURA_SHOTS"] != nil else { return }
            if let image = PrivateAPI.captureWindow(CGWindowID(win.windowNumber)) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/gridura_anim_\(tag).png"))
            }
        }
        let times: [Double] = [0.04, 0.09, 0.15, 0.22, 0.6]
        let openProbe = FrameProbe()
        openProbe.start(on: content, label: "folder open")
        content.openFolder(groupView: cell, source: 0)
        after(1.2) { log(openProbe.stop()) }
        for (i, t) in times.enumerated() { after(t) { shot("open_\(i)") } }
        after(1.5) {
            let closeProbe = FrameProbe()
            closeProbe.start(on: content, label: "folder close")
            content.closeFolder(animated: true)
            after(1.2) { log(closeProbe.stop()) }
            for (i, t) in times.enumerated() { after(t) { shot("close_\(i)") } }
        }
        after(3.0) { log("DONE"); NSApp.terminate(nil) }
    }



    /// Genuine key events into the genuine launcher: type-to-search without focusing the field first.
    static func runRealSearch(_ controller: LaunchpadWindowController, _ win: NSWindow) {
        let content = controller.launchpadVC.contentView
        let keys: [(Character, CGKeyCode)] = [("c", 8), ("h", 4), ("r", 15), ("o", 31)]
        func key(_ code: CGKeyCode, down: Bool) {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.post(tap: .cghidEventTap)
        }
        func shot(_ tag: String) {
            if let image = PrivateAPI.captureWindow(CGWindowID(win.windowNumber)) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/gridura_search_\(tag).png"))
            }
        }
        func report(_ label: String) {
            let names = content.displayedGroups.prefix(8).map { $0.displayName }
            log("[\(label)] field=\"\(content.searchView.inputField.stringValue)\" results=\(content.displayedGroups.count) first=\(names) page=\(content.currentPage) firstResponder=\(String(describing: type(of: win.firstResponder as Any)))")
        }
        report("before typing")
        var index = 0
        func next() {
            guard index < keys.count else {
                after(0.8) {
                    shot("typed"); report("typed")
                    key(51, down: true); key(51, down: false)                 // delete
                    after(0.6) {
                        report("after delete")
                        for _ in 0..<3 { key(51, down: true); key(51, down: false) }   // empty the field with Delete
                        after(0.7) { report("field emptied by Delete"); if content.displayedGroups.count < 100 { log("FAIL: emptying the field did not restore the full grid") } }
                    }
                    after(1.8) {
                        key(53, down: true); key(53, down: false)             // Esc: clears the query first
                        after(0.8) {
                            report("after Esc"); log("launcher visible=\(win.isVisible)")
                            log("DONE"); NSApp.terminate(nil)
                        }
                    }
                }
                return
            }
            let (ch, code) = keys[index]; index += 1
            key(code, down: true); key(code, down: false)
            after(0.35) { report("typed \(ch)"); next() }
        }
        after(0.5) { next() }
        after(30) { log("FAIL: timeout"); NSApp.terminate(nil) }
    }


    /// Search semantics with real key events: diacritic-insensitive match, ordering, Return launches the first hit.
    static func runRealSearch2(_ controller: LaunchpadWindowController, _ win: NSWindow) {
        let content = controller.launchpadVC.contentView
        func typeText(_ text: String) {
            for ch in text {
                let units = Array(String(ch).utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e?.post(tap: .cghidEventTap)
                }
            }
        }
        func key(_ code: CGKeyCode) {
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) }
        }
        func report(_ label: String) {
            log("[\(label)] field=\"\(content.searchView.inputField.stringValue)\" results=\(content.displayedGroups.count) first=\(content.displayedGroups.prefix(6).map { $0.displayName })")
        }
        after(0.5) {
            typeText("masaustu")
            after(0.8) {
                report("masaustu")
                let hit = content.displayedGroups.contains { $0.displayName.contains("Masaüstü") }
                if !hit { log("FAIL: 'masaustu' did not match a name containing 'Masaüstü'") }
                content.searchView.clear(notify: true)
                after(0.6) {
                    typeText("calculator")
                    after(0.8) {
                        report("calculator")
                        if content.displayedGroups.first?.displayName != "Calculator" { log("FAIL: 'calculator' should rank Calculator first") }
                        key(36)                                                 // Return → launch the first result
                        after(2.0) {
                            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.calculator" }
                            log("launcher visible=\(win.isVisible) alpha=\(win.alphaValue); Calculator running=\(!running.isEmpty)")
                            if win.isVisible && win.alphaValue > 0.01 { log("FAIL: Return did not hide the launcher") }
                            if running.isEmpty { log("FAIL: Return did not launch Calculator") }
                            running.forEach { $0.terminate() }
                            log("DONE"); NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
        after(30) { log("FAIL: timeout"); NSApp.terminate(nil) }
    }


    /// Folder renaming with real events: from the opened folder's title and from the grid cell's title.
    static func runRealRename(_ controller: LaunchpadWindowController, _ win: NSWindow) {
        let content = controller.launchpadVC.contentView
        let mainHeight = NSScreen.screens[0].frame.height
        func cg(_ point: CGPoint) -> CGPoint {
            let screen = win.convertPoint(toScreen: content.convert(point, to: nil))
            return CGPoint(x: screen.x, y: mainHeight - screen.y)
        }
        func post(_ type: CGEventType, _ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        func click(_ p: CGPoint, then: @escaping () -> Void) {
            post(.mouseMoved, p)
            after(0.15) { post(.leftMouseDown, p); after(0.08) { post(.leftMouseUp, p); after(0.5, then) } }
        }
        func typeText(_ text: String) {
            for ch in text {
                let units = Array(String(ch).utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e?.post(tap: .cghidEventTap)
                }
                usleep(30_000)
            }
        }
        func key(_ code: CGKeyCode) {
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) }
        }
        guard let folder = content.displayedGroups.first(where: { $0.isFolder && $0.apps.count >= 2 }),
              let cell = content.groupViews[folder.id] else { log("FAIL: no folder"); NSApp.terminate(nil); return }
        let originalName = folder.name
        log("folder id=\(folder.id) name=\"\(originalName)\"")
        content.openFolder(groupView: cell, source: 0)
        after(1.2) {
            // 1. rename from the opened folder's title: click, type, Return
            let titleFrame = content.openedFolderTitleLabel.frame
            click(cg(CGPoint(x: titleFrame.midX, y: titleFrame.midY))) {
                log("editor open=\(content.openedFolderTitleEditorView != nil) text=\"\(content.openedFolderTitleEditorView?.stringValue ?? "-")\"")
                if content.openedFolderTitleEditorView == nil { log("FAIL: clicking the folder title did not start editing") }
                typeText("Çalışma Ğ1")
                after(0.4) {
                    log("typed: editor text=\"\(content.openedFolderTitleEditorView?.stringValue ?? "-")\"")
                    key(36)                                               // Return
                    after(0.6) {
                        log("after Return: editor open=\(content.openedFolderTitleEditorView != nil) folder.name=\"\(folder.name)\"")
                        if folder.name != "Çalışma Ğ1" { log("FAIL: Return did not commit the folder name") }
                        if content.openedFolderTitleEditorView != nil { log("FAIL: editor still open after Return") }
                        // 2. Esc while editing cancels
                        let frame2 = content.openedFolderTitleLabel.frame
                        click(cg(CGPoint(x: frame2.midX, y: frame2.midY))) {
                            typeText("XXX")
                            after(0.3) {
                                key(53)                                   // Esc
                                after(0.6) {
                                    log("after Esc: editor open=\(content.openedFolderTitleEditorView != nil) folder.name=\"\(folder.name)\" folder open=\(content.openedFolderID != nil)")
                                    if folder.name != "Çalışma Ğ1" { log("FAIL: Esc should cancel the edit") }
                                    // 3. click away commits
                                    let frame3 = content.openedFolderTitleLabel.frame
                                    click(cg(CGPoint(x: frame3.midX, y: frame3.midY))) {
                                        typeText("2")
                                        after(0.3) {
                                            let away = cg(CGPoint(x: content.bounds.maxX - 40, y: content.bounds.midY))
                                            click(away) {
                                                log("after click-away: editor open=\(content.openedFolderTitleEditorView != nil) folder.name=\"\(folder.name)\" folder open=\(content.openedFolderID != nil)")
                                                if content.openedFolderTitleEditorView != nil { log("FAIL: click-away left the editor open") }
                                                if !folder.name.hasSuffix("2") { log("NOTE: click-away did not commit (name=\(folder.name))") }
                                                // 4. close the folder; the grid cell must show the new name; rename from the cell
                                                content.closeFolder(animated: true)
                                                after(1.2) {
                                                    guard let cell = content.groupViews[folder.id] else { log("FAIL: folder cell vanished"); NSApp.terminate(nil); return }
                                                    let shown = (cell.titleString as? NSAttributedString)?.string ?? (cell.titleString as? String) ?? "?"
                                                    log("grid cell title=\"\(shown)\" folder.name=\"\(folder.name)\"")
                                                    if shown != folder.name { log("FAIL: grid cell title does not show the renamed folder") }
                                                    let tf = content.convert(cell.titleFrameInView, from: cell)
                                                    click(cg(CGPoint(x: tf.midX, y: tf.midY))) {
                                                        log("grid rename: editing=\(cell.isEditing)")
                                                        if !cell.isEditing { log("FAIL: clicking the cell title did not start editing") }
                                                        typeText("Son Ad")
                                                        after(0.3) {
                                                            key(36)
                                                            after(0.6) {
                                                                let shown2 = (cell.titleString as? NSAttributedString)?.string ?? "?"
                                                                log("after grid Return: editing=\(cell.isEditing) folder.name=\"\(folder.name)\" shown=\"\(shown2)\"")
                                                                if folder.name != "Son Ad" { log("FAIL: grid rename did not commit") }
                                                                // 5. the context menu's Rename (beginRename) on an app: alias commit, title, search
                                                                guard let appGroup = content.displayedGroups.first(where: { !$0.isFolder }),
                                                                      let appCell = content.groupViews[appGroup.id] else { log("FAIL: no app"); NSApp.terminate(nil); return }
                                                                appCell.beginRename()
                                                                after(0.4) {
                                                                    log("menu rename: editing=\(appCell.isEditing)")
                                                                    typeText("Hesap Makinesi")
                                                                    after(0.3) {
                                                                        key(36)
                                                                        after(0.6) {
                                                                            let live = content.groupViews[appGroup.id]
                                                                            let shown3 = (live?.titleString as? NSAttributedString)?.string ?? "?"
                                                                            log("after menu rename: displayName=\"\(appGroup.displayName)\" shown=\"\(shown3)\" editing=\(live?.isEditing ?? false)")
                                                                            if !appGroup.displayName.contains("Hesap Makinesi") { log("FAIL: app rename did not commit") }
                                                                            if !shown3.contains("Hesap Makinesi") { log("FAIL: app cell title not refreshed") }
                                                                            content.searchView.inputField.stringValue = "hesap"
                                                                            content.searchView.onDebouncedQueryChanged?("hesap", "")
                                                                            after(0.8) {
                                                                                let found = content.displayedGroups.contains { $0.apps.first?.id == appGroup.apps.first?.id }      // result groups are rebuilt per app
                                                                                log("search 'hesap' finds the renamed app: \(found)")
                                                                                if !found { log("FAIL: renamed app not found by its new name") }
                                                                                log("DONE"); NSApp.terminate(nil)
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        after(40) { log("FAIL: timeout"); NSApp.terminate(nil) }
    }


    /// Captures the README gallery to `/tmp/gridura_readme_<name>.png`: the real launcher over a stand-in wallpaper
    /// (the window capture cannot see behind-window material, and no desktop picture is available to the test).
    static func runReadmeShots(_ controller: LaunchpadWindowController, _ win: NSWindow) {
        let content = controller.launchpadVC.contentView
        let state = AppState.shared
        if let host = content.superview {
            let image = NSImage(size: host.bounds.size, flipped: false) { rect in
                NSGradient(colors: [NSColor(red: 0.10, green: 0.07, blue: 0.30, alpha: 1),
                                    NSColor(red: 0.30, green: 0.18, blue: 0.62, alpha: 1),
                                    NSColor(red: 0.85, green: 0.35, blue: 0.55, alpha: 1),
                                    NSColor(red: 0.98, green: 0.62, blue: 0.40, alpha: 1)])?
                    .draw(in: rect, angle: 35)
                return true
            }
            let imageView = NSImageView(frame: host.bounds)
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            imageView.autoresizingMask = [.width, .height]
            host.addSubview(imageView, positioned: .below, relativeTo: content)
        }
        func shot(_ name: String) {
            if let image = PrivateAPI.captureWindow(CGWindowID(win.windowNumber)) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/gridura_readme_\(name).png"))
            }
        }
        after(1.5) {
            shot("grid")
            // A query whose hits are all Apple apps, so the gallery shows no personal software.
            let apple = Set(LaunchpadDataManager.shared.allApps().filter { $0.bundleId.hasPrefix("com.apple.") }.map(\.id))
            let pool = LaunchpadDataManager.shared.allApps()
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            var best = (query: "cal", hits: 0)
            for a in letters { for b in letters {
                let q = String([a, b])
                let hits = pool.filter { LaunchpadDataManager.score($0, query: q) != nil }      // the same matching the search uses
                if hits.count > best.hits, hits.allSatisfy({ apple.contains($0.id) }) { best = (q, hits.count) }
            } }
            let query = best.query
            log("search query: \(query)")
            content.searchView.inputField.stringValue = query
            content.searchView.onDebouncedQueryChanged?(query, "")
            after(1.0) {
                shot("search")
                content.searchView.clear(notify: true)
                after(0.8) {
                    if let folder = content.displayedGroups.first(where: { $0.isFolder && $0.apps.count >= 6 }),
                       let cell = content.groupViews[folder.id] {
                        content.openFolder(groupView: cell, source: 0)
                        after(1.4) {
                            shot("folder")
                            content.closeFolder(animated: true)
                            after(1.0) {
                                let original = state.displayMode
                                state.displayMode = .window
                                NotificationChannel.center.post(name: NotificationChannel.Name.preferencesChanged, object: PreferenceModule.layout.rawValue)
                                after(2.0) {
                                    shot("window")
                                    state.displayMode = original
                                    NotificationChannel.center.post(name: NotificationChannel.Name.preferencesChanged, object: PreferenceModule.layout.rawValue)
                                    after(1.0) { log("DONE"); NSApp.terminate(nil) }
                                }
                            }
                        }
                    } else { log("no folder with 6+ apps"); NSApp.terminate(nil) }
                }
            }
        }
        _ = state
    }

    /// Real HID mouse in the genuine launcher: a horizontal drag on empty space must change the page,
    /// a click on empty space (screen margin, or a cell's padding beside its icon) must hide the launcher.
    static func runRealClick(_ controller: LaunchpadWindowController, _ win: NSWindow) {
        let content = controller.launchpadVC.contentView
        let mainHeight = NSScreen.screens[0].frame.height
        func cg(_ point: CGPoint) -> CGPoint {
            let screen = win.convertPoint(toScreen: content.convert(point, to: nil))
            return CGPoint(x: screen.x, y: mainHeight - screen.y)
        }
        func post(_ type: CGEventType, _ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        func click(_ p: CGPoint, then: @escaping () -> Void) {
            post(.mouseMoved, p)
            after(0.15) { post(.leftMouseDown, p); after(0.08) { post(.leftMouseUp, p); after(0.8, then) } }
        }
        let margin = CGPoint(x: 40, y: content.bounds.midY)
        guard let cell = content.groupViews.values.first(where: { $0.superview != nil && !$0.isHidden && $0.group != nil && content.bounds.contains(CGPoint(x: content.convert($0.bounds, from: $0).midX, y: content.convert($0.bounds, from: $0).midY)) }) else {
            log("FAIL: no cells"); NSApp.terminate(nil); return
        }
        let icon = content.convert(cell.iconContentFrame, from: cell)
        let cellFrame = content.convert(cell.bounds, from: cell)
        let padding = CGPoint(x: (cellFrame.minX + icon.minX) / 2, y: icon.midY)     // inside the cell, left of the icon
        log("margin=\(margin) padding=\(padding) icon=\(icon) cell=\(cellFrame) page=\(content.currentPage) pages=\(content.totalPages)")

        let start = cg(margin)
        let from = cg(CGPoint(x: content.bounds.midX, y: content.bounds.minY + 12))     // bottom strip, empty
        var steps: [CGPoint] = []
        for i in 0...30 { steps.append(CGPoint(x: from.x - CGFloat(i) * 12, y: from.y)) }
        // 1. click in the cell padding (page 0 on screen) → hides
        click(cg(padding)) {
            log("after padding click: launcher visible=\(win.isVisible) alpha=\(win.alphaValue)")
            if win.isVisible && win.alphaValue > 0.01 { log("FAIL: click in cell padding did not hide the launcher") }
            controller.show()
            after(1.5) {
                // 2. drag on empty space → next page
                post(.mouseMoved, from)
                after(0.2) {
                    post(.leftMouseDown, from)
                    var i = 0
                    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { t in
                        if i < steps.count {
                            post(.leftMouseDragged, steps[i]); i += 1
                            if i == 28 { log("mid-swipe: pointer dx=\(steps[i - 1].x - from.x) strip x=\(content.pagedModeView.frame.origin.x) (page 0 rest = 0; follows 1:1, eased)") }
                            return
                        }
                        t.invalidate()
                        post(.leftMouseUp, steps.last ?? from)
                        after(1.0) {
                            log("after empty-space drag: page=\(content.currentPage) (expected 1); pagedView frame.x=\(content.pagedModeView.frame.origin.x) layer.pos.x=\(content.pagedModeView.layer?.position.x ?? -1) presentation.x=\(content.pagedModeView.layer?.presentation()?.position.x ?? -1) W=\(content.bounds.width) frame.w=\(content.pagedModeView.frame.width)")
                            if content.currentPage != 1 { log("FAIL: drag on empty space did not page") }
                            if let image = PrivateAPI.captureWindow(CGWindowID(win.windowNumber)) {
                                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                                    .write(to: URL(fileURLWithPath: "/tmp/gridura_page1.png"))
                            }
                            // 3. click in the screen margin → hides
                            click(start) {
                                log("after margin click: launcher visible=\(win.isVisible) alpha=\(win.alphaValue)")
                                if win.isVisible && win.alphaValue > 0.01 { log("FAIL: click in margin did not hide the launcher") }
                                log("DONE"); NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
        after(40) { log("FAIL: timeout"); NSApp.terminate(nil) }
    }

    /// Drives the grid with genuine mouse events (down, 60 Hz drags, up) through the HID tap — the same
    /// path a user's pointer takes — and logs the order before and after.
    static func runRealDrag(_ content: LaunchpadContentView, _ win: NSWindow) {
        let mainHeight = NSScreen.screens[0].frame.height
        func cg(_ point: CGPoint) -> CGPoint {
            let screen = win.convertPoint(toScreen: content.convert(point, to: nil))
            return CGPoint(x: screen.x, y: mainHeight - screen.y)
        }
        func post(_ type: CGEventType, _ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        guard content.displayedGroups.count > 4,
              let a = content.groupViews[content.displayedGroups[0].id],
              let c = content.groupViews[content.displayedGroups[2].id] else { log("not enough cells"); NSApp.terminate(nil); return }
        log("initial: \(names(content))")
        // Stand-in wallpaper for the glass check: a colourful image in the launcher's own view tree,
        // just under the grid (the window capture cannot see behind-window material).
        if ProcessInfo.processInfo.environment["GRIDURA_BACKDROP"] != nil, let host = content.superview {
            let image = NSImage(size: host.bounds.size, flipped: false) { rect in
                NSGradient(colors: [.systemPink, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemIndigo])?
                    .draw(in: rect, angle: 35)
                return true
            }
            let imageView = NSImageView(frame: host.bounds)
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            imageView.autoresizingMask = [.width, .height]
            host.addSubview(imageView, positioned: .below, relativeTo: content)
        }
        func shot(_ tag: String) {
            if let image = PrivateAPI.captureWindow(CGWindowID(win.windowNumber)) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/gridura_realdrag_\(tag).png"))
            }
        }
        shot("before")
        let start = cg(content.convert(CGPoint(x: a.iconContentFrame.midX, y: a.iconContentFrame.midY), from: a))
        let cFrame = content.convert(c.bounds, from: c)
        let end = cg(CGPoint(x: cFrame.maxX - 20, y: cFrame.midY))
        log("start=\(start) end=\(end) window=\(win.frame) key=\(win.isKeyWindow)")

        // Safety net: never leave the button pressed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { post(.leftMouseUp, end); NSApp.terminate(nil) }

        let probe = FrameProbe()
        probe.start(on: content, label: "real drag + drop")
        var steps: [(CGEventType, CGPoint)] = [(.mouseMoved, start), (.mouseMoved, start), (.leftMouseDown, start)]
        let travel = 40
        for i in 1...travel {
            let t = CGFloat(i) / CGFloat(travel)
            steps.append((.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
        }
        for _ in 0..<36 { steps.append((.leftMouseDragged, end)) }      // rest ≈ 0.6 s
        steps.append((.leftMouseUp, end))
        var index = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            if index == steps.count - 1, ProcessInfo.processInfo.environment["GRIDURA_TRACE_DROP"] != nil, let session = content.drag {
                let src = session.source, prev = session.preview
                let t0 = CACurrentMediaTime()
                Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { tr in
                    let dt = CACurrentMediaTime() - t0
                    let pf = prev.layer?.presentation()?.frame ?? .zero
                    let sf = content.convert(src.iconContentFrame, from: src)
                    let name = src.group?.displayName ?? "?"
                    log(String(format: "t=%.3f preview.x=%.0f prevAlive=%d | %@ cell.x=%.0f alpha=%.2f hidden=%d", dt, pf.minX, prev.superview != nil ? 1 : 0, name, sf.minX, src.alphaValue, src.isHidden ? 1 : 0))
                    if dt > 0.7 { tr.invalidate() }
                }
            }
            if index == 70, ProcessInfo.processInfo.environment["GRIDURA_FORCE_LAYOUT"] != nil { content.relayout() }
            if index == 78 {
                let row = content.groupViews.values.filter { $0.superview === a.superview && abs($0.frame.minY - a.frame.minY) < 2 }.sorted { $0.frame.minX < $1.frame.minX }.prefix(4)
                log("cells just before mouse-up (left→right): \(row.map { $0.group?.displayName ?? "?" })")
            }
            if index == 60, ProcessInfo.processInfo.environment["GRIDURA_SHOT_MID"] != nil { shot("mid") }
            if index == steps.count - 1, ProcessInfo.processInfo.environment["GRIDURA_SHOT_DROP"] != nil {
                for (i, t) in [0.05, 0.15, 0.25, 0.35, 0.45, 0.6, 0.9].enumerated() { after(t) { shot("drop\(i)") } }
            }
            guard index < steps.count else {
                timer.invalidate()
                after(2.0) {
                    log(probe.stop())
                    shot("after")
                    let visible = content.groupViews.values.filter { $0.superview != nil && !$0.isHidden && $0.alphaValue > 0.01 }.count
                    // Every app icon must actually be drawn: a layer left at opacity 0 shows only the label.
                    let apps = content.groupViews.values.compactMap { $0.appView }
                    let drawn = apps.filter { $0.iconView.imageLayer.contents != nil && $0.iconView.imageLayer.opacity > 0.99 }.count
                    log("cells in view=\(content.groupViews.count) visible=\(visible) page=\(content.currentPage) app icons drawn=\(drawn)/\(apps.count)")
                    if drawn != apps.count { log("FAIL: \(apps.count - drawn) app icon(s) are invisible after the drop") }
                    log("after real drop: \(names(content))")
                    log("drag session left: \(content.drag == nil ? "none" : "STUCK")")
                    log("DONE")
                    NSApp.terminate(nil)
                }
                return
            }
            post(steps[index].0, steps[index].1)
            index += 1
        }
    }

    /// Opens the real preferences window and captures each tab to `/tmp/gridura_prefs_<n>.png`.
    static func runPrefsShot() {
        PreferencesWindowController.shared.show()
        after(1.0) {
            guard let window = PreferencesWindowController.shared.window,
                  let controller = window.contentViewController as? PreferencesViewController else {
                log("no prefs window"); NSApp.terminate(nil); return
            }
            let dark = ProcessInfo.processInfo.environment["GRIDURA_SHOT_DARK"] != nil
            if dark { window.appearance = NSAppearance(named: .darkAqua) }
            func capture(_ index: Int) {
                guard index < 5 else { log("DONE"); NSApp.terminate(nil); return }
                controller.selectTab(index: index)
                after(1.2) {
                    // A real window capture (shows the actual materials and dark appearance).
                    window.alphaValue = 1
                    func scrollViews(in view: NSView) -> [NSScrollView] {
                        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews(in:))
                    }
                    func snap(_ suffix: String) {
                        window.displayIfNeeded()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                        if let image = PrivateAPI.captureWindow(CGWindowID(window.windowNumber)) {
                            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                                .write(to: URL(fileURLWithPath: "/tmp/gridura_prefs_\(index)\(dark ? "_dark" : "")\(suffix).png"))
                            log("tab \(index)\(suffix): window=\(window.frame.size) captured")
                        } else {
                            log("tab \(index)\(suffix): capture failed")
                        }
                    }
                    snap("")
                    // Also the part below the fold: scroll every scroll view to its end.
                    if let root = window.contentView {
                        let scrollers = scrollViews(in: root)
                        for scroller in scrollers {
                            guard let doc = scroller.documentView else { continue }
                            let maxY = max(doc.frame.height - scroller.contentView.bounds.height, 0)
                            if maxY > 1 {
                                scroller.contentView.scroll(to: CGPoint(x: 0, y: doc.isFlipped ? maxY : 0))
                                scroller.reflectScrolledClipView(scroller.contentView)
                            }
                        }
                        log("tab \(index): scroll views=\(scrollers.count)")
                        snap("_bottom")
                    }
                    capture(index + 1)
                }
            }
            capture(0)
        }
    }

    /// Feeds a local appcast to the updater and logs what it found.
    static func runUpdate() {
        let feed = "/tmp/gridura_appcast.xml"
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><title>1.0.1</title><sparkle:version>99998</sparkle:version><sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
            <enclosure url="https://example.invalid/Gridura-1.0.1.zip" sparkle:version="99998" length="1" type="application/octet-stream"/></item>
          <item><title>1.2.0</title><sparkle:version>99999</sparkle:version><sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
            <enclosure url="https://example.invalid/Gridura-1.2.0.zip" sparkle:version="99999" length="1" type="application/octet-stream"/></item>
        </channel></rss>
        """
        try? xml.write(toFile: feed, atomically: true, encoding: .utf8)
        setenv("GRIDURA_TEST_FEED", "http://127.0.0.1:8765/gridura_appcast.xml", 1)                    // read by UpdateManager's feed override (DEBUG)
        log("before: available=\(UpdateManager.shared.availableVersion ?? "nil")")
        UpdateManager.shared.checkInBackground()
        after(5.0) {
            log("after check: available=\(UpdateManager.shared.availableVersion ?? "nil") downloaded=\(UpdateManager.shared.downloadedVersion ?? "nil")")
            if UpdateManager.shared.availableVersion != "1.2.0" { log("FAIL: Sparkle did not report the newest version (1.2.0)") }
            log("DONE")
            NSApp.terminate(nil)
        }
    }

    static func runReorganize(_ dm: LaunchpadDataManager) {
        func first(_ n: Int = 14) -> [String] { dm.allGroups.prefix(n).map { $0.apps.first?.name ?? $0.name } }
        log("initial: \(first())")
        var options = LayoutOrganizeOptions()
        options.sortMethod = .iconColor
        options.sortDirection = .ascending
        options.scope = .allPages
        options.reorganizeAcrossPages = true
        let started = Date()
        dm.reorganize(options) {
            log("icon color asc (\(String(format: "%.2f", Date().timeIntervalSince(started))) s): \(first())  sortBy=\(AppState.shared.sortBy)")
            var byName = LayoutOrganizeOptions()
            byName.sortMethod = .name
            byName.sortDirection = .descending
            byName.folderPlacement = .front
            byName.scope = .allPages
            dm.reorganize(byName) {
                log("name desc, folders first: \(first())")
                let pages = Dictionary(grouping: dm.allGroups, by: \.page).mapValues(\.count)
                log("pages: \(pages.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })")
                log("DONE")
                NSApp.terminate(nil)
            }
        }
    }

    /// `GRIDURA_SELFTEST=scan GRIDURA_SELFTEST_APP=/Applications/Foo.app`: logs the leftover scan.
    static func runScan() {
        guard let path = ProcessInfo.processInfo.environment["GRIDURA_SELFTEST_APP"] else {
            log("set GRIDURA_SELFTEST_APP"); NSApp.terminate(nil); return
        }
        let url = URL(fileURLWithPath: path)
        guard let app = ApplicationManager.shared.makeLaunchpadApp(bundleURL: url, displayURL: url) else {
            log("could not read app at \(path)"); NSApp.terminate(nil); return
        }
        log("app: \(app.name) bundleId=\(app.bundleId)")
        let started = Date()
        let items = AppUninstallManager.shared.scan(app: app)
        log("scan took \(String(format: "%.2f", Date().timeIntervalSince(started))) s, \(items.count) items")
        for item in items {
            log("  [\(item.category)] \(item.kind) \(item.displayPath)  \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
        }
        log("DONE")
        NSApp.terminate(nil)
    }

    /// Display-link frame probe: reports frames and hitches (> 25 ms between frames) until stopped.
    final class FrameProbe: NSObject {
        private var last: CFTimeInterval = 0
        private(set) var frames = 0
        private(set) var hitches: [Double] = []
        private(set) var hitchFrames: [Int] = []
        private var link: CADisplayLink?
        var label = ""
        func start(on view: NSView, label: String) {
            self.label = label
            frames = 0; hitches = []; hitchFrames = []; last = 0
            // A main-thread timer (not a display link, which pauses while nothing is drawn): a gap
            // well over its 4 ms period means the main thread was blocked.
            let t = Timer(timeInterval: 1.0 / 240, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        private var timer: Timer?
        private func tick() {
            let now = CACurrentMediaTime()
            if last > 0 {
                let dt = (now - last) * 1000
                frames += 1
                if dt > 12 { hitches.append(dt); hitchFrames.append(frames) }
            }
            last = now
        }
        func stop() -> String {
            timer?.invalidate(); timer = nil
            let worst = hitches.max().map { String(format: "%.0f", $0) } ?? "0"
            return "[\(label)] frames=\(frames) hitches(>25ms)=\(hitches.count) worst=\(worst)ms at frames \(hitchFrames)"
        }
    }

    static func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    /// "icons drawn=a/b": app icons whose layer has contents and is fully opaque, grid and opened folder.
    static func iconReport(_ content: LaunchpadContentView, _ label: String) {
        let cells = Array(content.groupViews.values) + content.openedFolderAppViews
        let apps = cells.compactMap { $0.appView }
        let drawn = apps.filter { $0.iconView.imageLayer.contents != nil && $0.iconView.imageLayer.opacity > 0.99 }.count
        let folders = cells.compactMap { $0.folderView }.count
        log("[\(label)] app icons drawn=\(drawn)/\(apps.count) folders=\(folders) alphaZero=\(cells.filter { $0.alphaValue < 0.01 }.count)")
        if drawn != apps.count { log("FAIL[\(label)]: \(apps.count - drawn) invisible icon(s)") }
    }

    static func names(_ content: LaunchpadContentView, _ n: Int = 8) -> [String] {
        content.displayedGroups.prefix(n).map { $0.apps.first?.name ?? $0.name }
    }

    /// Scripted pointer path: (point, seconds-to-hold) steps sampled at 60 Hz, then release.
    static func script(_ content: LaunchpadContentView, path: [(CGPoint, TimeInterval)], done: @escaping () -> Void) {
        var steps: [CGPoint] = []
        var last = path[0].0
        for (point, hold) in path {
            let distance = hypot(point.x - last.x, point.y - last.y)
            let moveSteps = max(1, Int(distance / 12))
            for i in 1...moveSteps {
                let t = CGFloat(i) / CGFloat(moveSteps)
                steps.append(CGPoint(x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t))
            }
            for _ in 0..<Int(hold * 60) { steps.append(point) }
            last = point
        }
        var index = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            if index < steps.count {
                content.dragStep(mouse: steps[index], pressed: true)
                index += 1
            } else {
                timer.invalidate()
                content.dragStep(mouse: steps.last ?? .zero, pressed: false)
                done()
            }
        }
    }

    static func cellFrames(_ content: LaunchpadContentView, _ n: Int = 6) -> [String] {
        content.displayedGroups.prefix(n).compactMap { g in
            content.groupViews[g.id].map { "\(g.apps.first?.name ?? g.name)@\(Int($0.frame.minX)),\(Int($0.frame.minY))" }
        }
    }

    static func runDrag(_ content: LaunchpadContentView, _ dm: LaunchpadDataManager, mode: String) {
        log("sortBy=\(AppState.shared.sortBy) browsing=\(AppState.shared.browsingStyle) bounds=\(content.bounds)")
        log("initial: \(names(content))")
        guard content.displayedGroups.count > 6,
              let a = content.groupViews[content.displayedGroups[0].id],
              let c = content.groupViews[content.displayedGroups[2].id] else {
            log("not enough cells"); NSApp.terminate(nil); return
        }
        let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        content.beginDrag(group: content.displayedGroups[0], event: event,
                          offset: CGPoint(x: a.iconContentFrame.width / 2, y: a.iconContentFrame.height / 2))
        guard let session = content.drag else { log("beginDrag produced no session"); NSApp.terminate(nil); return }
        session.link?.invalidate(); session.link = nil
        session.isSynthetic = true

        // A realistic path: grab A's icon centre, travel right along the row, rest on C's right margin, release.
        let aCenter = content.convert(CGPoint(x: a.iconContentFrame.midX, y: a.iconContentFrame.midY), from: a)
        let cFrame = content.convert(c.bounds, from: c)
        let center = content.convert(CGPoint(x: c.iconContentFrame.midX, y: c.iconContentFrame.midY), from: c)
        let rest = mode == "merge" ? center : CGPoint(x: cFrame.maxX - 20, y: cFrame.midY)
        log("path: \(aCenter) -> \(rest)")
        script(content, path: [(aCenter, 0.2), (rest, 0.5)]) {
            log("released; session.ended=\(session.ended) order=\(session.pages.first?.prefix(6).map { $0.group?.apps.first?.name ?? "?" } ?? [])")
            after(1.8) {
                log("after drop displayed: \(names(content))")
                iconReport(content, mode)
                log("after drop frames: \(cellFrames(content))")
                dm.load {
                    after(1.0) {
                        log("after db reload displayed: \(names(content))")
                        log("after db reload frames: \(cellFrames(content))")
                        log("DONE")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}
#endif
