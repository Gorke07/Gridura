import AppKit

/// Watches the configured screen corner on every screen: global + local
/// `mouseMoved` monitors, an exact corner point (< 1 pt tolerance), a per-corner "armed" flag and
/// a 0.2 s debounce.
final class HotCornersMonitor {
    static let shared = HotCornersMonitor()

    private struct CornerInfo {
        var corner: HotCornerType
        var point: CGPoint
        var screenID: String
    }

    private struct ScreenConfig {
        var frame: CGRect
        var screenID: String
        var corners: [CornerInfo]
    }

    var monitoredCorner: HotCornerType = .topRight
    var onTriggered: (() -> Void)?

    private var edgeOutMonitor: Any?
    private var edgeInMonitor: Any?
    private let debounceInterval: TimeInterval = 0.2
    private var lastTriggerTime: [String: Date] = [:]
    private var isCornerActive: [String: Bool] = [:]
    private var screenConfigs: [ScreenConfig] = []
    private var screenObserver: NSObjectProtocol?

    private init() {}

    // MARK: Start / stop

    func start() {
        guard monitoredCorner != .off else { return }
        buildScreenConfigs()
        installMonitors()
        observeScreenChanges()
        LogManager.shared.info("Hot-corner monitoring started (current corner: \(monitoredCorner)); \(NSScreen.screens.count) screens detected")
    }

    func stop() {
        removeMonitors()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        isCornerActive.removeAll()
        LogManager.shared.info("Hot-corner monitoring stopped")
    }

    /// Screen configuration changed: only the corner points are rebuilt, the monitors stay.
    func reload() {
        LogManager.shared.info("Screen configuration changed, reloading hot corners…")
        buildScreenConfigs()
    }

    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            }
    }

    private func installMonitors() {
        removeMonitors()
        edgeOutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouse(NSEvent.mouseLocation)
        }
        edgeInMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouse(NSEvent.mouseLocation)
            return event
        }
        if edgeOutMonitor == nil || edgeInMonitor == nil {
            LogManager.shared.error("HotCorner Error")
        }
    }

    private func removeMonitors() {
        if let edgeOutMonitor { NSEvent.removeMonitor(edgeOutMonitor) }
        if let edgeInMonitor { NSEvent.removeMonitor(edgeInMonitor) }
        edgeOutMonitor = nil
        edgeInMonitor = nil
    }

    // MARK: Screen configs

    private func buildScreenConfigs() {
        screenConfigs = []
        let frames = NSScreen.screens.map(\.frame)
        for (index, screen) in NSScreen.screens.enumerated() {
            let f = screen.frame
            let id = "screen_\(index)"
            let point: CGPoint
            switch monitoredCorner {
            case .topLeft: point = CGPoint(x: f.minX, y: f.maxY)
            case .topRight: point = CGPoint(x: f.maxX, y: f.maxY)
            case .bottomLeft: point = CGPoint(x: f.minX, y: f.minY)
            case .bottomRight: point = CGPoint(x: f.maxX, y: f.minY)
            case .off: point = .zero
            }
            // A corner that lies inside another screen (inclusive bounds) is a shared edge: skip it.
            let shared = frames.enumerated().contains { other in
                other.offset != index
                    && other.element.minY <= point.y && point.y <= other.element.maxY
                    && other.element.minX <= point.x && point.x <= other.element.maxX
            }
            if shared { continue }
            screenConfigs.append(ScreenConfig(frame: f, screenID: id,
                                              corners: [CornerInfo(corner: monitoredCorner, point: point, screenID: id)]))
        }
    }

    // MARK: Trigger logic

    private func handleMouse(_ mouse: CGPoint) {
        for config in screenConfigs {
            for corner in config.corners {
                let key = "\(corner.screenID)-\(corner.corner)"
                if abs(mouse.x - corner.point.x) >= 1.0 || abs(mouse.y - corner.point.y) >= 1.0 {
                    if isCornerActive[key] == true { isCornerActive[key] = false }   // left the corner → re-arm
                    continue
                }
                if isCornerActive[key] == true { continue }                          // still parked there
                let now = Date()
                if let last = lastTriggerTime[key], now.timeIntervalSince(last) < debounceInterval {
                    // debounced
                } else {
                    lastTriggerTime[key] = now
                    LogManager.shared.info("Hot corner triggered: [\(corner.screenID)] \(corner.corner)")
                    onTriggered?()
                }
                isCornerActive[key] = true
            }
        }
    }
}
