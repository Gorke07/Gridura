import Foundation
import AppKit
import CoreData

/// App discovery, database synchronisation and layout mutations
///.
final class ApplicationManager {
    static let shared = ApplicationManager()

    static let defaultAppDirectoryPaths: [AppDirectoryPath] = [
        .system("/Applications"),
        .system("/System/Applications"),
        .system("/System/Cryptexes/App/System/Applications"),
        .userHome("/Applications"),
    ]

    /// Posted on `NSWorkspace.notificationCenter` when the Dock/menu-bar icon appearance changes
    /// so cached icons are re-rasterised. The shipped app observes the
    /// non-public `NSWorkspaceIconAppearanceConfigurationDidChangeNotification`; this mirrors it.
    static let iconAppearanceDidChange = Notification.Name("Gridura.IconAppearanceDidChange")

    /// Used only for the initial default-folder classification — never to exclude apps.
    static let blocklistAppsId: Set<String> = [
        "com.apple.QuickTimePlayerX", "com.apple.TextEdit", "com.apple.Preview", "com.apple.Stickies",
    ]
    static let allowlistAppsId: Set<String> = [
        "com.apple.AppStore", "com.apple.mobilephone", "com.apple.clock", "com.apple.Passwords",
        "com.apple.ScreenContinuity", "com.apple.systempreferences", "com.apple.Home",
        "com.apple.findmy", "com.apple.calculator",
    ]

    private let scanQueue = DispatchQueue(label: "com.griduraapp.application-scan",
                                          qos: .userInitiated, autoreleaseFrequency: .inherit)
    private var container: NSPersistentContainer { PersistenceController.shared.container }
    private unowned let appState = AppState.shared

    var customAppDirectoryCount: Int = 0

    private init() {}

    // MARK: - Effective directory list

    func appDirectories(_ context: NSManagedObjectContext) -> [AppDirectoryPath] {
        var sources: [SourceEntity] = []
        context.performAndWait {
            let request = SourceEntity.fetchRequest()
            request.predicate = NSPredicate(format: "enabled == YES")
            sources = (try? context.fetch(request)) ?? []
        }
        customAppDirectoryCount = sources.count
        appState.customAppDirectoryCount = sources.count

        let disabled = Set(appState.disabledDefaultAppDirectoryPaths)
        var result: [AppDirectoryPath] = []
        for dir in Self.defaultAppDirectoryPaths {
            let path = dir.isUserHome ? NSHomeDirectory() + dir.rawPath : dir.rawPath
            if disabled.contains(URL(fileURLWithPath: path).standardizedFileURL.path) { continue }
            result.append(dir)
        }
        let custom = sources.compactMap { entity -> AppDirectoryPath? in
            guard let path = entity.path else { return nil }
            switch entity.type {
            case 0: return .system(path)
            case 1: return .userHome(path)
            default: return .external(path)
            }
        }
        return result + custom
    }

    /// Uses `viewContext` on the main thread, otherwise a dedicated background context.
    func appDirectoriesOnAppropriateContext() -> [AppDirectoryPath] {
        if Thread.isMainThread {
            return appDirectories(PersistenceController.shared.viewContext)
        }
        let ctx = PersistenceController.shared.newBackgroundContext(named: "appDirectories")
        return appDirectories(ctx)
    }

    // MARK: - Scanning

    func scanDirectories(_ dirs: [AppDirectoryPath]) -> [LaunchpadApp] {
        var results: [LaunchpadApp] = []
        var seenPaths: Set<String> = []

        for dir in dirs {
            let base = dir.isUserHome ? NSHomeDirectory() + dir.rawPath : dir.rawPath
            let baseURL = URL(fileURLWithPath: base)
            guard let enumerator = FileManager.default.enumerator(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isAliasFileKey, .isSymbolicLinkKey, .typeIdentifierKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: nil
            ) else { continue }

            for case let url as URL in enumerator {
                guard enumerator.level <= 3 else { continue }
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey, .isApplicationKey])
                let isApp = values?.isApplication ?? false
                let isAlias = values?.isAliasFile ?? false
                let isSymlink = values?.isSymbolicLink ?? false
                guard isApp || isAlias || isSymlink else { continue }
                guard let resolved = resolveApp(url) else { continue }
                if isNestedInsideAnotherApp(resolved.resolved) { continue }
                guard let app = makeLaunchpadApp(bundleURL: resolved.resolved, displayURL: resolved.original) else { continue }
                let key = app.url.standardizedFileURL.path
                if seenPaths.contains(key) { continue }
                seenPaths.insert(key)
                results.append(app)
            }
        }
        return dedupeByIdentity(results)
    }

    /// Resolves aliases and verifies the target is an `.app` package.
    func resolveApp(_ url: URL) -> (original: URL, resolved: URL)? {
        let values = try? url.resourceValues(forKeys: [.isAliasFileKey])
        var resolved = url
        if values?.isAliasFile == true {
            guard let r = try? URL(resolvingAliasFileAt: url, options: []) else { return nil }
            resolved = r
        }
        guard resolved.pathExtension == "app",
              NSWorkspace.shared.isFilePackage(atPath: resolved.path) else { return nil }
        return (url, resolved)
    }

    /// True when more than one path component ends with ".app" (app bundled inside an app).
    func isNestedInsideAnotherApp(_ url: URL) -> Bool {
        let appComponents = url.pathComponents.filter { $0.hasSuffix(".app") }
        return appComponents.count > 1
    }

    private func dedupeByIdentity(_ apps: [LaunchpadApp]) -> [LaunchpadApp] {
        var seen: Set<String> = []
        var result: [LaunchpadApp] = []
        for app in apps {
            let key = app.identityKey
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(app)
        }
        return result
    }

    // MARK: - Bundle metadata

    struct BundleMetadata {
        var bundleId: String
        var bundleName: String
        var version: String
        var build: String
        var category: String
    }

    static func infoPlistURL(for bundleURL: URL) -> URL? {
        let direct = bundleURL.appendingPathComponent("Contents/Info.plist")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let wrapped = bundleURL.appendingPathComponent("WrappedBundle/Info.plist")
        if FileManager.default.fileExists(atPath: wrapped.path) { return wrapped }
        let wrapper = bundleURL.appendingPathComponent("Wrapper", isDirectory: true)
        if let children = try? FileManager.default.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for child in children where child.pathExtension == "app" {
                let candidate = child.appendingPathComponent("Contents/Info.plist")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    func readMetadata(_ bundleURL: URL) -> BundleMetadata? {
        guard let plistURL = Self.infoPlistURL(for: bundleURL),
              let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        func str(_ key: String) -> String { dict[key] as? String ?? "" }
        return BundleMetadata(bundleId: str("CFBundleIdentifier"),
                              bundleName: str("CFBundleName"),
                              version: str("CFBundleShortVersionString"),
                              build: str("CFBundleVersion"),
                              category: str("LSApplicationCategoryType"))
    }

    /// Seven-step display name resolution, then `deletingPathExtension`.
    func resolveDisplayName(_ url: URL) -> String {
        var name: String?
        if let bundle = Bundle(url: url) {
            if let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName, !localized.isEmpty {
                name = localized
            } else if let v = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String, !v.isEmpty {
                name = v
            } else if let v = bundle.localizedInfoDictionary?["CFBundleName"] as? String, !v.isEmpty {
                name = v
            } else if let v = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !v.isEmpty {
                name = v
            } else if let v = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !v.isEmpty {
                name = v
            } else {
                name = FileManager.default.displayName(atPath: url.path)
            }
        } else {
            name = url.lastPathComponent
        }
        let resolved = name ?? url.lastPathComponent
        return (resolved as NSString).deletingPathExtension
    }

    func makeLaunchpadApp(bundleURL: URL, displayURL: URL) -> LaunchpadApp? {
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        let meta = readMetadata(bundleURL)
        let name = resolveDisplayName(displayURL)

        var bundleId = ""
        var bundleName = ""
        var category = ""
        var version = ""
        var build = ""
        if let meta {
            bundleId = meta.bundleId
            bundleName = meta.bundleName
            version = meta.version
            build = meta.build
            category = meta.category
        } else {
            let info = bundle.infoDictionary ?? [:]
            bundleId = bundle.bundleIdentifier ?? ""
            bundleName = info["CFBundleName"] as? String ?? ""
            category = info["LSApplicationCategoryType"] as? String ?? ""
            version = info["CFBundleShortVersionString"] as? String ?? ""
            build = info["CFBundleVersion"] as? String ?? ""
        }
        if bundleId == "app.gridura.Gridura" || bundleId == "app.gridura.Gridura.debug" { return nil }

        let app = LaunchpadApp(name: name, alias: "", url: displayURL, bundleId: bundleId, category: category,
                               bundleName: bundleName, version: version, build: build)
        app.defaultName = (displayURL.lastPathComponent as NSString).deletingPathExtension
        app.regenerateSearchKeys()
        return app
    }

    // MARK: - Scan entry & sync

    func scan(fromBackup: Bool, completion: @escaping () -> Void) {
        scanQueue.async { [weak self] in
            guard let self else { return }
            let ctx = PersistenceController.shared.newBackgroundContext(named: "scanDirectories")
            let apps = self.scanDirectories(self.appDirectories(ctx))
            let syncCtx = PersistenceController.shared.newBackgroundContext(named: "syncContext")
            syncCtx.performAndWait {
                self.syncLocalScanToDatabase(syncCtx, fromBackup: fromBackup, scanned: apps)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    private func syncLocalScanToDatabase(_ ctx: NSManagedObjectContext, fromBackup: Bool, scanned: [LaunchpadApp]) {
        let perPage = appState.perPage
        let style = appState.browsingStyle
        let request = AppEntity.fetchRequest()
        let entities = (try? ctx.fetch(request)) ?? []
        if entities.isEmpty {
            initialLayout(ctx, apps: scanned, perPage: perPage)
        } else {
            diffSync(ctx, fromBackup: fromBackup, scanned: scanned, entities: entities, perPage: perPage, style: style)
        }
    }

    // MARK: Initial layout

    private func initialLayout(_ ctx: NSManagedObjectContext, apps: [LaunchpadApp], perPage: Int) {
        var appleTop: [LaunchpadApp] = []
        var utilities: [LaunchpadApp] = []
        var games: [LaunchpadApp] = []
        var other: [LaunchpadApp] = []
        var others: [LaunchpadApp] = []

        for app in apps {
            if !Self.isAppleApp(app.url) {
                others.append(app)
            } else {
                switch Self.defaultFolder(for: app) {
                case nil: appleTop.append(app)
                case "Utilities": utilities.append(app)
                case "Games": games.append(app)
                default: other.append(app)
                }
            }
        }

        func byName(_ a: LaunchpadApp, _ b: LaunchpadApp) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        appleTop.sort(by: byName)
        utilities.sort(by: byName)
        games.sort(by: byName)
        other.sort(by: byName)
        others.sort(by: byName)

        var groups: [GroupEntity] = []
        var appsForGroup: [(GroupEntity, [LaunchpadApp])] = []

        func singleGroup(_ app: LaunchpadApp) -> GroupEntity {
            let g = GroupEntity(context: ctx)
            g.id = UUID().uuidString
            g.name = ""
            g.isFolder = false
            g.page = 0
            g.order = 0
            let e = makeEntity(ctx, app)
            g.apps = NSOrderedSet(array: [e])
            return g
        }

        func folderGroup(_ name: String, _ list: [LaunchpadApp]) -> GroupEntity? {
            guard !list.isEmpty else { return nil }
            let g = GroupEntity(context: ctx)
            g.id = UUID().uuidString
            g.name = NSLocalizedString(name, comment: "")
            g.isFolder = true
            g.page = 0
            g.order = 0
            g.apps = NSOrderedSet(array: list.enumerated().map { idx, app in
                let e = makeEntity(ctx, app)
                e.order = Int64(idx)
                return e
            })
            return g
        }

        for app in appleTop { groups.append(singleGroup(app)) }
        if let g = folderGroup("Utilities", utilities) { groups.append(g) }
        if let g = folderGroup("Other", other) { groups.append(g) }
        if let g = folderGroup("Games", games) { groups.append(g) }
        for app in others { groups.append(singleGroup(app)) }
        appsForGroup.removeAll()

        for (index, group) in groups.enumerated() {
            group.order = Int64(index)
            group.page = Int64(index / max(perPage, 1))
        }
        save(ctx)
    }

    private func makeEntity(_ ctx: NSManagedObjectContext, _ app: LaunchpadApp) -> AppEntity {
        let e = AppEntity(context: ctx)
        e.id = app.id
        e.name = app.name
        e.bundleId = app.bundleId
        e.bundleName = app.bundleName
        e.version = app.version
        e.build = app.build
        e.category = app.category
        e.url = app.url
        e.order = 0
        e.alias = nil
        e.hidden = false
        return e
    }

    // MARK: Diff sync

    private func diffSync(_ ctx: NSManagedObjectContext, fromBackup: Bool, scanned: [LaunchpadApp],
                          entities: [AppEntity], perPage: Int, style: BrowsingStyleType) {
        let unavailableExternal = unavailableExternalSourcePaths(ctx)

        // Repair entities with empty metadata.
        for entity in entities where (entity.bundleName ?? "").isEmpty && (entity.version ?? "").isEmpty && (entity.build ?? "").isEmpty {
            guard let url = entity.url, let meta = readMetadata(url) else { continue }
            entity.bundleName = meta.bundleName
            entity.version = meta.version
            entity.build = meta.build
        }

        let unmatchedScanned = scanned
        var matchedEntityIDs: Set<ObjectIdentifier> = []
        var updatedURLs: [URL] = []
        var newURLs: [URL] = []

        // Pass 1: identity(4) with path preference.
        var byIdentity: [String: [Int]] = [:]
        for (i, app) in unmatchedScanned.enumerated() { byIdentity[app.identityKey, default: []].append(i) }
        var consumed = Set<Int>()

        for entity in entities where entity.group != nil {
            let key = identity4(entity)
            guard var candidates = byIdentity[key] else { continue }
            candidates = candidates.filter { !consumed.contains($0) }
            guard !candidates.isEmpty else { continue }
            let entityPath = entity.url?.standardizedFileURL.path
            let chosen = candidates.first { unmatchedScanned[$0].standardizedPath == entityPath } ?? candidates[0]
            if updateEntity(entity, from: unmatchedScanned[chosen]) { updatedURLs.append(entity.url ?? unmatchedScanned[chosen].url) }
            consumed.insert(chosen)
            matchedEntityIDs.insert(ObjectIdentifier(entity))
        }

        // Pass 2: same standardized URL + bundleId, else bundleId+bundleName.
        for entity in entities where entity.group != nil && !matchedEntityIDs.contains(ObjectIdentifier(entity)) {
            let entityPath = entity.url?.standardizedFileURL.path
            let entityBundle = entity.bundleId ?? ""
            var candidates = unmatchedScanned.enumerated().filter { !consumed.contains($0.offset) && $0.element.standardizedPath == entityPath && $0.element.bundleId == entityBundle }
            if candidates.count == 1, let match = candidates.first {
                if updateEntity(entity, from: match.element) { updatedURLs.append(entity.url ?? match.element.url) }
                consumed.insert(match.offset); matchedEntityIDs.insert(ObjectIdentifier(entity)); continue
            }
            let shortKey = "\(entityBundle.isEmpty ? (entity.url?.absoluteString ?? "") : entityBundle)\u{1F}\(entity.bundleName ?? "")"
            candidates = unmatchedScanned.enumerated().filter { !consumed.contains($0.offset) && $0.element.identityKeyShort == shortKey }
            if candidates.count == 1, let match = candidates.first {
                if updateEntity(entity, from: match.element) { updatedURLs.append(entity.url ?? match.element.url) }
                consumed.insert(match.offset); matchedEntityIDs.insert(ObjectIdentifier(entity))
            }
        }

        // Removal for unmatched entities.
        let scannedPaths = Set(scanned.map(\.standardizedPath))
        let buildEmptyPaths = Set(scanned.filter { $0.build.isEmpty }.map(\.standardizedPath))
        let identityKeys = Set(scanned.map(\.identityKey))
        let knownDirs = appDirectories(ctx).map { $0.expandedPath }

        for entity in entities where !matchedEntityIDs.contains(ObjectIdentifier(entity)) {
            guard let url = entity.url else {
                ctx.delete(entity)
                continue
            }
            let path = url.standardizedFileURL.path
            if entity.group == nil { ctx.delete(entity); continue }
            if Self.path(path, isUnderAnyOf: unavailableExternal) { continue }
            if buildEmptyPaths.contains(path) { continue }
            if !identityKeys.contains(identity4(entity)),
               Self.path(path, isUnderAnyOf: knownDirs),
               !scannedPaths.contains(path),
               FileManager.default.fileExists(atPath: path) { continue }
            deleteEntity(entity, ctx: ctx)
        }

        // Insertion for unmatched scanned apps.
        for (i, app) in unmatchedScanned.enumerated() where !consumed.contains(i) {
            if app.build.isEmpty { continue }
            let slot = nextFreeSlot(ctx, fromBackup: fromBackup, perPage: perPage, isScroll: style == .scroll)
            let g = GroupEntity(context: ctx)
            g.id = UUID().uuidString
            g.name = ""
            g.isFolder = false
            g.page = Int64(slot.page)
            g.order = Int64(slot.order)
            let e = makeEntity(ctx, app)
            g.apps = NSOrderedSet(array: [e])
            newURLs.append(app.url)
        }

        save(ctx)

        if !updatedURLs.isEmpty {
            NotificationChannel.center.post(name: NotificationChannel.Name.refreshPendingIcon, object: nil,
                                            userInfo: [NotificationChannel.UserInfoKey.urls: updatedURLs,
                                                       NotificationChannel.UserInfoKey.delay: 0.5])
        }
        if !newURLs.isEmpty {
            NotificationChannel.center.post(name: NotificationChannel.Name.refreshPendingIcon, object: nil,
                                            userInfo: [NotificationChannel.UserInfoKey.urls: newURLs,
                                                       NotificationChannel.UserInfoKey.delay: 5.0])
        }
    }

    private func identity4(_ entity: AppEntity) -> String {
        let first = (entity.bundleId ?? "").isEmpty ? (entity.url?.absoluteString ?? "") : (entity.bundleId ?? "")
        return [first, entity.bundleName ?? "", entity.version ?? "", entity.build ?? ""].joined(separator: "\u{1F}")
    }

    @discardableResult
    private func updateEntity(_ entity: AppEntity, from app: LaunchpadApp) -> Bool {
        var changed = false
        func assign(_ current: String?, _ new: String, _ key: String) {
            if (current ?? "") != new { entity.setValue(new, forKey: key); changed = true }
        }
        assign(entity.bundleId, app.bundleId, "bundleId")
        assign(entity.bundleName, app.bundleName, "bundleName")
        assign(entity.version, app.version, "version")
        assign(entity.build, app.build, "build")
        assign(entity.name, app.name, "name")
        assign(entity.category, app.category, "category")
        if entity.url != app.url {
            entity.url = app.url
            changed = true
        }
        return changed
    }

    private func deleteEntity(_ entity: AppEntity, ctx: NSManagedObjectContext) {
        if let group = entity.group, group.orderedApps.count <= 1 {
            ctx.delete(group)
        }
        ctx.delete(entity)
    }

    // MARK: Next free slot

    func nextFreeSlot(_ ctx: NSManagedObjectContext, fromBackup: Bool, perPage: Int, isScroll: Bool) -> (page: Int, order: Int) {
        let request = GroupEntity.fetchRequest()
        request.predicate = NSPredicate(format: "page != -1")
        request.sortDescriptors = [NSSortDescriptor(key: "page", ascending: true), NSSortDescriptor(key: "order", ascending: true)]
        let groups = (try? ctx.fetch(request)) ?? []
        var page: Int
        if fromBackup {
            page = 100
        } else {
            let byPage = Dictionary(grouping: groups, by: { Int($0.page) })
            if !isScroll {
                page = byPage.keys.sorted().first { (byPage[$0]?.count ?? 0) < perPage }
                    ?? ((byPage.keys.max() ?? -1) + 1)
            } else {
                let last = byPage.keys.max() ?? 0
                page = (byPage[last]?.count ?? 0) < perPage ? last : last + 1
            }
        }
        let order = (groups.filter { $0.page == Int64(page) }.map(\.order).max() ?? 0) + 1
        return (page, Int(order))
    }

    // MARK: External sources

    func unavailableExternalSourcePaths(_ ctx: NSManagedObjectContext) -> [String] {
        let request = SourceEntity.fetchRequest()
        request.predicate = NSPredicate(format: "enabled == YES AND type == %lld", 2)
        let sources = (try? ctx.fetch(request)) ?? []
        return sources.compactMap { entity in
            guard let path = entity.path else { return nil }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return (!exists || !isDir.boolValue) ? path : nil
        }
    }

    static func path(_ path: String, isUnderAnyOf dirs: [String]) -> Bool {
        dirs.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: Apple-app detection

    static let appleAppDirectories: [String] = [
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Cryptexes/App/System/Applications",
        "/System/Library/CoreServices",
        "/System/Library/CoreServices/Applications",
    ]

    static func isAppleApp(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return appleAppDirectories.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func defaultFolder(for app: LaunchpadApp) -> String? {
        let path = app.url.path
        if path.hasPrefix("/System/Applications/Utilities/") || path.hasPrefix("/System/Library/CoreServices/") {
            return "Utilities"
        }
        let category = app.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if category == "public.app-category.games" || category.hasSuffix("-games") { return "Games" }
        let byCategory = ["", "public.app-category.education", "public.app-category.reference",
                          "public.app-category.utilities", "public.app-category.graphics-design"].contains(category)
        if (byCategory || blocklistAppsId.contains(app.bundleId)) && !allowlistAppsId.contains(app.bundleId) {
            return "Other"
        }
        return nil
    }

    // MARK: Loading groups for display

    func loadGroupsForDisplay(_ ctx: NSManagedObjectContext) -> [LaunchpadGroup] {
        var groups: [LaunchpadGroup] = []
        ctx.performAndWait {
            let request = GroupEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "page", ascending: true), NSSortDescriptor(key: "order", ascending: true)]
            request.relationshipKeyPathsForPrefetching = ["apps"]
            var entities = (try? ctx.fetch(request)) ?? []

            // Repair: empty groups, duplicate ids.
            var seenGroupIDs = Set<String>()
            var seenAppIDs = Set<String>()
            var didRepair = false
            for group in entities {
                let apps = group.orderedApps
                if apps.isEmpty {
                    ctx.delete(group)
                    didRepair = true
                    continue
                }
                if let id = group.id, seenGroupIDs.contains(id) {
                    group.id = UUID().uuidString
                    didRepair = true
                }
                if let id = group.id { seenGroupIDs.insert(id) }
                for app in apps {
                    if let id = app.id, seenAppIDs.contains(id) {
                        app.id = UUID().uuidString
                        didRepair = true
                    }
                    if let id = app.id { seenAppIDs.insert(id) }
                }
            }
            if didRepair { save(ctx) }

            let unavailable = unavailableExternalSourcePaths(ctx)
            entities = entities.filter { !$0.isDeleted && $0.page != -1 }

            for group in entities {
                let apps = group.orderedApps
                    .sorted { $0.order < $1.order }
                    .filter { !$0.isHidden }
                    .map { entity -> LaunchpadApp in
                        let app = self.launchpadApp(from: entity)
                        if let url = entity.url {
                            app.isSourceUnavailable = Self.path(url.standardizedFileURL.path, isUnderAnyOf: unavailable)
                        }
                        return app
                    }
                groups.append(LaunchpadGroup(id: group.id ?? UUID().uuidString,
                                             name: group.name ?? "",
                                             apps: apps,
                                             order: Int(group.order),
                                             page: Int(group.page),
                                             isFolder: group.isFolder))
            }
        }
        return groups
    }

    func launchpadApp(from entity: AppEntity) -> LaunchpadApp {
        let url = entity.url ?? URL(fileURLWithPath: "/")
        let app = LaunchpadApp(id: entity.id ?? UUID().uuidString,
                               name: entity.name ?? "",
                               alias: entity.alias ?? "",
                               order: Int(entity.order),
                               hidden: entity.isHidden,
                               url: url,
                               bundleId: entity.bundleId ?? "",
                               category: entity.category ?? "",
                               bundleName: entity.bundleName ?? "",
                               version: entity.version ?? "",
                               build: entity.build ?? "")
        app.defaultName = ((try? url.resourceValues(forKeys: [.nameKey]))?.name as NSString? ?? url.lastPathComponent as NSString).deletingPathExtension
        let dates = AppMetadataCache.shared.cachedDates(for: url)
        app.addedDate = dates.added
        app.lastOpenedDate = dates.lastUsed
        app.regenerateSearchKeys()
        return app
    }

    // MARK: Writing the layout back

    func syncViewDataToDatabase(_ groups: [LaunchpadGroup]) {
        let ctx = PersistenceController.shared.newBackgroundContext(named: "syncView")
        ctx.performAndWait {
            let groupRequest = GroupEntity.fetchRequest()
            groupRequest.predicate = NSPredicate(format: "page != -1")
            groupRequest.relationshipKeyPathsForPrefetching = ["apps"]
            let existingGroups = (try? ctx.fetch(groupRequest)) ?? []
            var byID: [String: GroupEntity] = [:]
            for g in existingGroups { if let id = g.id { byID[id] = g } }

            let appRequest = AppEntity.fetchRequest()
            appRequest.predicate = NSPredicate(format: "hidden == NO OR hidden == nil")
            let visibleApps = (try? ctx.fetch(appRequest)) ?? []
            var appsByID: [String: AppEntity] = [:]
            for a in visibleApps { if let id = a.id { appsByID[id] = a } }

            var keptIDs = Set<String>()
            for g in groups {
                let entity = byID[g.id] ?? {
                    let e = GroupEntity(context: ctx)
                    e.id = g.id
                    return e
                }()
                entity.name = g.name
                entity.isFolder = g.isFolder
                entity.order = Int64(g.order)
                entity.page = Int64(g.page)
                var ordered: [AppEntity] = []
                for (index, app) in g.apps.enumerated() {
                    guard let ae = appsByID[app.id] else { continue }
                    ae.alias = app.alias
                    ae.order = Int64(index)
                    ordered.append(ae)
                }
                entity.apps = NSOrderedSet(array: ordered)
                keptIDs.insert(g.id)
            }
            for entity in existingGroups where !(entity.id.map { keptIDs.contains($0) } ?? false) {
                ctx.delete(entity)
            }
            if ctx.hasChanges, (try? ctx.save()) == nil { ctx.rollback() }
        }
    }

    // MARK: Hide / unhide / restore

    func setHidden(_ ctx: NSManagedObjectContext, appId: String, hide: Bool) {
        let request = AppEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", appId)
        guard let app = (try? ctx.fetch(request))?.first else { return }
        let slot = nextFreeSlot(ctx, fromBackup: false, perPage: appState.perPage, isScroll: appState.browsingStyle == .scroll)
        if let group = app.group {
            if group.isFolder {
                if hide {
                    if let existing = app.group {
                        existing.apps = NSOrderedSet(array: existing.orderedApps.filter { $0 !== app })
                        if existing.orderedApps.isEmpty { ctx.delete(existing) }
                    }
                    let g = GroupEntity(context: ctx)
                    g.id = UUID().uuidString
                    g.name = ""
                    g.isFolder = false
                    g.page = -1
                    g.order = 0
                    g.apps = NSOrderedSet(array: [app])
                }
            } else {
                if hide {
                    group.page = -1
                    group.order = 0
                } else {
                    group.page = Int64(slot.page)
                    group.order = Int64(slot.order)
                }
            }
        }
        app.hidden = hide
        save(ctx)
        refreshHiddenCount(ctx)
    }

    func hiddenApps(_ ctx: NSManagedObjectContext) -> [LaunchpadApp] {
        let request = AppEntity.fetchRequest()
        request.predicate = NSPredicate(format: "hidden == YES")
        let entities = (try? ctx.fetch(request)) ?? []
        let unavailable = unavailableExternalSourcePaths(ctx)
        return entities.map { entity in
            let app = launchpadApp(from: entity)
            if let url = entity.url {
                app.isSourceUnavailable = Self.path(url.standardizedFileURL.path, isUnderAnyOf: unavailable)
            }
            return app
        }
    }

    @discardableResult
    func restoreAllHidden(_ ctx: NSManagedObjectContext) -> Int {
        let request = GroupEntity.fetchRequest()
        request.predicate = NSPredicate(format: "page == -1")
        request.relationshipKeyPathsForPrefetching = ["apps"]
        let groups = (try? ctx.fetch(request)) ?? []
        guard !groups.isEmpty else { return 0 }
        let maxPage = groups.map(\.page).max() ?? 0
        let actualMax = fetchMaxPage(ctx)
        var restored = 0
        for group in groups {
            group.page = actualMax + 1
            group.order = 100
            for app in group.orderedApps where app.isHidden {
                app.hidden = false
                restored += 1
            }
        }
        _ = maxPage
        save(ctx)
        refreshHiddenCount(ctx)
        return restored
    }

    private func fetchMaxPage(_ ctx: NSManagedObjectContext) -> Int64 {
        let request = GroupEntity.fetchRequest()
        request.predicate = NSPredicate(format: "page != -1")
        let groups = (try? ctx.fetch(request)) ?? []
        return groups.map(\.page).max() ?? 0
    }

    func refreshHiddenCount(_ ctx: NSManagedObjectContext) {
        let request = AppEntity.fetchRequest()
        request.predicate = NSPredicate(format: "hidden == YES")
        let count = (try? ctx.count(for: request)) ?? 0
        DispatchQueue.main.async { AppState.shared.hiddenAppCount = count }
    }

    // MARK: Folder merging / aliases

    func mergeGroup(_ ctx: NSManagedObjectContext, sourceGroupId: String, targetGroupId: String) {
        let request = GroupEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ OR id == %@", sourceGroupId, targetGroupId)
        let groups = (try? ctx.fetch(request)) ?? []
        guard let source = groups.first(where: { $0.id == sourceGroupId }),
              let target = groups.first(where: { $0.id == targetGroupId }) else { return }
        if !target.isFolder {
            target.isFolder = true
            target.name = NSLocalizedString("Untitled", comment: "")
        }
        let merged = target.orderedApps + source.orderedApps
        target.apps = NSOrderedSet(array: merged.enumerated().map { idx, app in app.order = Int64(idx); return app })
        ctx.delete(source)
        save(ctx)
    }

    func mergeFolder(_ ctx: NSManagedObjectContext, sourceId: String, folderId: String) {
        mergeGroup(ctx, sourceGroupId: sourceId, targetGroupId: folderId)
    }

    func renameFolder(_ ctx: NSManagedObjectContext, groupId: String, name: String) {
        let request = GroupEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", groupId)
        guard let group = (try? ctx.fetch(request))?.first else { return }
        group.name = name
        save(ctx)
    }

    func setAlias(_ ctx: NSManagedObjectContext, appId: String, alias: String) {
        let request = AppEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", appId)
        guard let app = (try? ctx.fetch(request))?.first else { return }
        app.alias = alias
        save(ctx)
    }

    // MARK: - Source management for the Preferences Apps tab

    /// Every configured source — the four built-in defaults plus the user's, in the order the UI
    /// shows them.
    func directories() -> [AppDirectory] {
        let ctx = PersistenceController.shared.viewContext
        var sources: [SourceEntity] = []
        ctx.performAndWait {
            let request = SourceEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "type", ascending: true)]
            sources = (try? ctx.fetch(request)) ?? []
        }
        let disabled = Set(appState.disabledDefaultAppDirectoryPaths)
        var result: [AppDirectory] = []
        for dir in Self.defaultAppDirectoryPaths {
            let path = dir.isUserHome ? NSHomeDirectory() + dir.rawPath : dir.rawPath
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            result.append(AppDirectory(id: Self.stableID(for: standardized),
                                       path: dir,
                                       enabled: !disabled.contains(standardized),
                                       isCustom: false))
        }
        for source in sources {
            guard let raw = source.path, let id = source.id else { continue }
            let type = source.type
            let path: AppDirectoryPath
            switch type {
            case 0: path = .system(raw)
            case 1: path = .userHome(raw)
            default: path = .external(raw)
            }
            result.append(AppDirectory(id: id, path: path, enabled: source.enabled, isCustom: true))
        }
        return result
    }

    /// The built-in rows get a deterministic ID so the UI can address them without a store row.
    private static func stableID(for path: String) -> UUID {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Data(path.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hex = String(format: "%016llx", hash)
        let padded = hex + hex
        let uuidString = "\(padded.prefix(8))-\(padded.dropFirst(8).prefix(4))-\(padded.dropFirst(12).prefix(4))-\(padded.dropFirst(16).prefix(4))-\(padded.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString) ?? UUID()
    }

    /// Adds a user directory. Paths under the home directory are stored home-relative, paths under
    /// `/Volumes` as external ("Add").
    @discardableResult
    func addDirectory(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !path.isEmpty else { return false }
        let home = NSHomeDirectory()
        let stored: AppDirectoryPath
        if path.hasPrefix("/Volumes/") {
            stored = .external(path)
        } else if path.hasPrefix(home) {
            stored = .userHome(String(path.dropFirst(home.count)))
        } else {
            stored = .system(path)
        }
        let ctx = PersistenceController.shared.viewContext
        var duplicate = false
        ctx.performAndWait {
            let request = SourceEntity.fetchRequest()
            let existing = (try? ctx.fetch(request)) ?? []
            duplicate = existing.contains { $0.path == stored.rawPath }
            guard !duplicate else { return }
            let entity = SourceEntity(context: ctx)
            entity.id = UUID()
            entity.path = stored.rawPath
            entity.enabled = true
            entity.type = stored.typeRaw
            try? ctx.save()
        }
        return !duplicate
    }

    func removeDirectory(id: UUID) {
        let ctx = PersistenceController.shared.viewContext
        ctx.performAndWait {
            let request = SourceEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            guard let entity = (try? ctx.fetch(request))?.first else { return }
            ctx.delete(entity)
            try? ctx.save()
        }
    }

    func setDirectoryEnabled(id: UUID, enabled: Bool) {
        let ctx = PersistenceController.shared.viewContext
        ctx.performAndWait {
            let request = SourceEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            guard let entity = (try? ctx.fetch(request))?.first else { return }
            entity.enabled = enabled
            try? ctx.save()
        }
    }

    /// Toggles one of the four built-in directories through `DisabledDefaultAppDirectoryPaths`.
    func setDefaultDirectory(path: AppDirectoryPath, enabled: Bool) {
        let full = path.isUserHome ? NSHomeDirectory() + path.rawPath : path.rawPath
        let standardized = URL(fileURLWithPath: full).standardizedFileURL.path
        var disabled = appState.disabledDefaultAppDirectoryPaths
        if enabled {
            disabled.removeAll { $0 == standardized }
        } else if !disabled.contains(standardized) {
            disabled.append(standardized)
        }
        if let data = try? JSONEncoder().encode(disabled), let string = String(data: data, encoding: .utf8) {
            appState.disabledDefaultAppDirectoryPathsValue = string
        }
    }

    // MARK: Helpers

    @discardableResult
    private func save(_ ctx: NSManagedObjectContext) -> Bool {
        guard ctx.hasChanges else { return true }
        do { try ctx.save(); return true }
        catch {
            LogManager.shared.error("后台保存失败: \(error)")
            return false
        }
    }
}
