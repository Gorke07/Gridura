import Foundation
import AppKit

/// FSEvents monitor over the app directories.
final class FinderMonitor {
    static let shared = FinderMonitor()

    var onChanged: (() -> Void)?

    private let eventQueue = DispatchQueue(label: "com.griduraapp.fsevents")
    private var stream: FSEventStreamRef?
    private var refreshWorkItem: DispatchWorkItem?
    private var volumeObservers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        stop()
        let paths = ApplicationManager.shared.appDirectoriesOnAppropriateContext()
            .map(\.expandedPath)
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else {
            LogManager.shared.info("没有可监听的应用目录")
            return
        }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<FinderMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.scheduleChangeNotify()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context,
                                               paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        else {
            LogManager.shared.error("创建 FSEventStream 失败")
            return
        }
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        if !FSEventStreamStart(stream) {
            LogManager.shared.error("启动 FSEventStream 失败")
            FSEventStreamInvalidate(stream)
            return
        }
        self.stream = stream
        observeVolumes()
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        for observer in volumeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        volumeObservers.removeAll()
        LogManager.shared.info("停止监听")
    }

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, label) in [(NSWorkspace.didMountNotification, "Volume Mount"),
                              (NSWorkspace.didUnmountNotification, "Volume Unmount")] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                LogManager.shared.info(label)
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                let sources = (try? PersistenceController.shared.viewContext.fetch(SourceEntity.fetchRequest())) ?? []
                let related = sources.contains { $0.type == 2 && ($0.path?.hasPrefix(url.path) ?? false) }
                guard related else {
                    LogManager.shared.info("\(url.path) 与外接应用来源无关，跳过")
                    return
                }
                self?.start()
                self?.onChanged?()
            }
            volumeObservers.append(observer)
        }
    }

    private func scheduleChangeNotify() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                LogManager.shared.info("AppFileMonitor 监听到目录变化重新扫描应用")
                self?.onChanged?()
            }
            self.refreshWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
        }
    }
}
