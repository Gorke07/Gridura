import Foundation

/// Reads and caches Spotlight dates for app URLs. Dates are never
/// persisted in Core Data; they live only here for sorting.
final class AppMetadataCache {
    static let shared = AppMetadataCache()

    private let queue = DispatchQueue(label: "com.griduraapp.metadata", qos: .utility)
    private let lock = NSLock()
    private var cache: [URL: AppDates] = [:]
    private var isRefreshing = false

    private init() {}

    func cachedDates(for url: URL) -> AppDates {
        lock.lock(); defer { lock.unlock() }
        return cache[url] ?? AppDates(added: nil, lastUsed: nil)
    }

    func readDates(for url: URL) -> AppDates {
        guard let item = NSMetadataItem(url: url) else { return AppDates(added: nil, lastUsed: nil) }
        let values = item.values(forAttributes: ["kMDItemDateAdded", "kMDItemContentCreationDate", "kMDItemLastUsedDate"]) ?? [:]
        let added = (values["kMDItemDateAdded"] ?? values["kMDItemContentCreationDate"]) as? Date
        let lastUsed = values["kMDItemLastUsedDate"] as? Date
        return AppDates(added: added, lastUsed: lastUsed)
    }

    func refresh(_ apps: [LaunchpadApp], completion: (() -> Void)? = nil) {
        lock.lock()
        if isRefreshing { lock.unlock(); return }
        isRefreshing = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            for app in apps {
                let dates = self.readDates(for: app.url)
                self.lock.lock()
                let existing = self.cache[app.url]
                if existing != dates { self.cache[app.url] = dates }
                self.lock.unlock()
                app.addedDate = dates.added
                app.lastOpenedDate = dates.lastUsed
            }
            self.lock.lock(); self.isRefreshing = false; self.lock.unlock()
            DispatchQueue.main.async { completion?() }
        }
    }
}
