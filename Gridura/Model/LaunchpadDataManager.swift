import Foundation
import AppKit
import CoreData

struct LaunchpadDisplayUpdate {
    var groups: [LaunchpadGroup]
    var totalPages: Int
    var changeKind: LaunchpadDisplayChangeKind
}

enum LaunchpadDisplayChangeKind: Int {
    case contentOnly = 0
    case structure = 1
}

/// Owns the visible layout: load, sort, search, pagination normalisation, reorganise and
/// folder operations.
final class LaunchpadDataManager {
    static let shared = LaunchpadDataManager()

    private unowned let appState = AppState.shared
    private let applicationManager = ApplicationManager.shared

    var allGroups: [LaunchpadGroup] = []
    var filteredGroups: [LaunchpadGroup] = []
    private(set) var lastDisplayUpdate: LaunchpadDisplayUpdate?
    private(set) var totalPages: Int = 0
    var currentSearchQuery: String = ""

    var didDataChange: ((LaunchpadDisplayUpdate) -> Void)?
    var didReloadCurrentUI: (() -> Void)?

    private init() {}

    // MARK: - Loading

    func load(_ completion: (() -> Void)? = nil) {
        let apps = allApps()
        AppMetadataCache.shared.refresh(apps) { [weak self] in
            guard let self else { return }
            self.allGroups = PresentationNormalizer.normalize(self.applicationManager.loadGroupsForDisplay(PersistenceController.shared.viewContext),
                                                              perPage: self.appState.perPage)
            self.publish(2)
            completion?()
        }
    }

    func setAllGroups(_ groups: [LaunchpadGroup], sync: Bool) {
        allGroups = PresentationNormalizer.normalize(groups, perPage: appState.perPage)
        if sync { applicationManager.syncViewDataToDatabase(allGroups) }
        publish(2)
    }

    // MARK: - Publishing / filtering

    func publish(_ hint: Int) {
        let columns = appState.columns
        let rows = appState.rows
        let perPage = max(1, columns * rows)
        let q = currentSearchQuery
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if q.isEmpty {
            switch appState.sortBy {
            case .custom:
                filteredGroups = allGroups
            case .name:
                let descending = appState.sortOrder == .descending
                filteredGroups = stableSort(allGroups) { a, b in
                    let r = a.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        .localizedStandardCompare(b.displayName.trimmingCharacters(in: .whitespacesAndNewlines))
                    return descending ? r == .orderedDescending : r == .orderedAscending
                }
            case .added, .opened:
                let ascending = appState.sortOrder == .ascending
                let useAdded = appState.sortBy == .added
                let apps = allGroups.flatMap(\.apps)
                let sorted = stableSort(apps) { a, b in
                    let da = (useAdded ? a.addedDate : a.lastOpenedDate) ?? .distantPast
                    let db = (useAdded ? b.addedDate : b.lastOpenedDate) ?? .distantPast
                    return ascending ? da < db : da > db
                }
                filteredGroups = sorted.map { LaunchpadGroup(id: $0.id, name: $0.name, apps: [$0], order: 0, page: 0, isFolder: false) }
            }
        } else {
            let candidates = searchCandidates()
            let scored = candidates.compactMap { app -> (LaunchpadApp, Int)? in
                guard let score = Self.score(app, query: q) else { return nil }
                return (app, score)
            }
            let sorted = stableSort(scored) { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                let r = a.0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedStandardCompare(b.0.name.trimmingCharacters(in: .whitespacesAndNewlines))
                if r != .orderedSame { return r == .orderedAscending }
                return a.0.id < b.0.id
            }
            filteredGroups = sorted.map { LaunchpadGroup(id: $0.0.id, name: $0.0.name, apps: [$0.0], order: 0, page: 0, isFolder: false) }
        }

        if q.isEmpty && appState.sortBy == .custom {
            totalPages = (filteredGroups.map(\.page).max() ?? -1) + 1
        } else {
            totalPages = max(1, Int(ceil(Double(filteredGroups.count) / Double(perPage))))
        }

        let kind: LaunchpadDisplayChangeKind
        switch hint {
        case 1: kind = .contentOnly
        case 2: kind = .structure
        default:
            if let last = lastDisplayUpdate, DisplayStructureSnapshot(last) == DisplayStructureSnapshot(totalPages: totalPages, groups: filteredGroups) {
                kind = .contentOnly
            } else {
                kind = .structure
            }
        }

        let update = LaunchpadDisplayUpdate(groups: filteredGroups, totalPages: totalPages, changeKind: kind)
        lastDisplayUpdate = update
        didDataChange?(update)
    }

    func searchCandidates() -> [LaunchpadApp] {
        var result = allGroups.flatMap(\.apps)
        if appState.showHiddenAppsInSearch {
            let hidden = applicationManager.hiddenApps(PersistenceController.shared.viewContext)
            let existing = Set(result.map(\.id))
            result += hidden.filter { !existing.contains($0.id) }
        }
        return result
    }

    /// Score with 9 fields, priorities 0–8; prefix → priority, contains → priority + 20.
    static func score(_ app: LaunchpadApp, query: String) -> Int? {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        }
        let fields: [(String, Int)] = [
            (fold(app.alias), 0),
            (fold(app.name), 1),
            (app.aliasAbbr, 2),
            (app.aliasFull, 3),
            (app.nameAbbr, 4),
            (app.nameFull, 5),
            (fold(app.defaultName), 6),
            (app.defaultFull, 7),
            (app.defaultAbbr, 8),
        ]
        var best: Int?
        for (field, priority) in fields where !field.isEmpty {
            if field.hasPrefix(query) {
                best = min(best ?? .max, priority)
            } else if field.contains(query) {
                best = min(best ?? .max, priority + 20)
            }
        }
        return best
    }

    // MARK: - Helpers

    func allApps() -> [LaunchpadApp] {
        allGroups.flatMap(\.apps)
    }

    private func stableSort<T>(_ items: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        items.enumerated()
            .sorted { a, b in
                if areInIncreasingOrder(a.element, b.element) { return true }
                if areInIncreasingOrder(b.element, a.element) { return false }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: - Compaction

    func fillEmptySlots() {
        let perPage = appState.perPage
        let sorted = allGroups.sorted { ($0.page, $0.order) < ($1.page, $1.order) }
        for (index, group) in sorted.enumerated() {
            group.page = index / perPage
            group.order = index % perPage
        }
        allGroups = sorted
        publish(2)
        applicationManager.syncViewDataToDatabase(allGroups)
    }

    // MARK: - Page move targets

    func pageMoveTargets() -> (targets: [LaunchpadPageMoveTarget], folders: [LaunchpadGroup]) {
        let perPage = appState.perPage
        let maxPage = allGroups.map(\.page).max() ?? 0
        var targets: [LaunchpadPageMoveTarget] = []
        for page in 0...max(0, maxPage) {
            let count = allGroups.filter { $0.page == page }.count
            targets.append(LaunchpadPageMoveTarget(pageIndex: page, availableSlots: perPage - count))
        }
        return (targets, allGroups.filter(\.isFolder))
    }

    func move(_ groups: [LaunchpadGroup], toPage page: Int) {
        let perPage = appState.perPage
        let existing = allGroups.filter { candidate in
            !groups.contains(where: { $0 === candidate }) && candidate.page == page
        }
        var order = existing.count
        for group in groups {
            group.page = page
            group.order = order
            order += 1
        }
        allGroups = PresentationNormalizer.normalize(allGroups, perPage: perPage)
        publish(2)
        applicationManager.syncViewDataToDatabase(allGroups)
    }

    // MARK: - Drag & drop persistence

    /// Writes the on-screen order of a drag back to the model: `group.page = p`, `group.order = i`.
    func commitOrder(pages: [[LaunchpadGroup]]) {
        let ordered = Self.assignPages(pages)
        let rest = allGroups.filter { g in !ordered.contains(where: { $0 === g }) }
        allGroups = ordered + rest
        // A pure reorder keeps every cell view: the drop animation already put them in place.
        saveLayout(reorderOnly: allGroups.allSatisfy { !$0.apps.isEmpty })
    }

    /// Drops `source` onto `target`: a plain app becomes the folder "Untitled".
    /// `pages` carries the dragged order (custom sort) or is nil to keep the stored order.
    func mergeGroup(source: LaunchpadGroup, into target: LaunchpadGroup, pages: [[LaunchpadGroup]]?) {
        if !target.isFolder {
            target.isFolder = true
            target.name = NSLocalizedString("Untitled", comment: "")
        }
        target.apps.append(contentsOf: source.apps)
        if let pages {
            let ordered = Self.assignPages(pages.map { $0.filter { $0 !== source } })
            let rest = allGroups.filter { g in g !== source && !ordered.contains(where: { $0 === g }) }
            allGroups = ordered + rest
        } else {
            allGroups.removeAll { $0 === source }
        }
        saveLayout()
    }

    private static func assignPages(_ pages: [[LaunchpadGroup]]) -> [LaunchpadGroup] {
        var result: [LaunchpadGroup] = []
        for (p, list) in pages.enumerated() {
            for (i, group) in list.enumerated() {
                group.page = p
                group.order = i
                result.append(group)
            }
        }
        return result
    }

    /// Writes a dragged order of apps inside a folder.
    func commitFolderOrder(folderID: String, appIDs: [String]) {
        guard let folder = allGroups.first(where: { $0.id == folderID }) else { return }
        var remaining = folder.apps
        var ordered: [LaunchpadApp] = []
        for id in appIDs {
            if let index = remaining.firstIndex(where: { $0.id == id }) { ordered.append(remaining.remove(at: index)) }
        }
        folder.apps = ordered + remaining
        publish(1)
        applicationManager.syncViewDataToDatabase(allGroups)
    }

    private func saveLayout(reorderOnly: Bool = false) {
        let before = allGroups.count
        allGroups.removeAll { $0.apps.isEmpty }       // a folder emptied by dragging its last app out
        allGroups = PresentationNormalizer.normalize(allGroups, perPage: appState.perPage)
        publish(reorderOnly && allGroups.count == before ? 1 : 2)
        if reorderOnly {
            scheduleDatabaseSync()          // keep the Core Data save out of the drop animation's frames
        } else {
            applicationManager.syncViewDataToDatabase(allGroups)
        }
    }

    private var syncPending = false

    private func scheduleDatabaseSync() {
        guard !syncPending else { return }
        syncPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.flushPendingSync() }
    }

    /// Writes a deferred layout save; also called when the app terminates.
    func flushPendingSync() {
        guard syncPending else { return }
        syncPending = false
        applicationManager.syncViewDataToDatabase(allGroups)
    }

    // MARK: - Folder operations

    @discardableResult
    func createFolderAtEnd(appIds: [String]) -> LaunchpadGroup? {
        guard !appIds.isEmpty else { return nil }
        let perPage = appState.perPage
        var selected: [LaunchpadApp] = []
        for id in appIds {
            for group in allGroups {
                if let app = group.apps.first(where: { $0.id == id }) {
                    selected.append(app)
                    group.apps.removeAll { $0 === app }
                    break
                }
            }
        }
        allGroups.removeAll { $0.apps.isEmpty }
        let lastPage = allGroups.map(\.page).max() ?? 0
        let lastCount = allGroups.filter { $0.page == lastPage }.count
        var page = lastPage
        var order = lastCount
        if lastCount >= perPage { page += 1; order = 0 }
        let folder = LaunchpadGroup(name: NSLocalizedString("Untitled", comment: ""), apps: selected,
                                    order: order, page: page, isFolder: true)
        allGroups.append(folder)
        allGroups = PresentationNormalizer.normalize(allGroups, perPage: perPage)
        publish(2)
        applicationManager.syncViewDataToDatabase(allGroups)
        return folder
    }

    /// Ungroup: the apps become single groups at the end of the folder's original page (they spill
    /// onto the following pages when it is full)
    func dissolveFolder(_ folder: LaunchpadGroup) {
        guard let index = allGroups.firstIndex(where: { $0 === folder }) else { return }
        let page = folder.page
        let singles = folder.apps.map {
            LaunchpadGroup(id: UUID().uuidString, name: $0.name, apps: [$0], order: 0, page: page, isFolder: false)
        }
        allGroups.remove(at: index)
        let endOfPage = (allGroups.lastIndex { $0.page == page }).map { $0 + 1 } ?? min(index, allGroups.count)
        allGroups.insert(contentsOf: singles, at: endOfPage)
        allGroups = PresentationNormalizer.normalize(allGroups, perPage: appState.perPage)
        publish(2)
        applicationManager.syncViewDataToDatabase(allGroups)
    }

    func renameFolder(_ folder: LaunchpadGroup, name: String) {
        folder.name = name
        let ctx = PersistenceController.shared.viewContext
        applicationManager.renameFolder(ctx, groupId: folder.id, name: name)
        publish(1)
    }

    func setAlias(_ app: LaunchpadApp, alias: String) {
        app.alias = alias
        app.regenerateSearchKeys()
        applicationManager.setAlias(PersistenceController.shared.viewContext, appId: app.id, alias: alias)
        publish(1)
    }

    /// Moves one app to the end of `page` — a plain group moves as it is, an app inside a folder
    /// comes out as a new single group (menu "Move to ▸ Page N").
    func moveApp(_ app: LaunchpadApp, toPage page: Int) {
        guard let source = allGroups.first(where: { $0.apps.contains { $0 === app } }) else { return }
        if !source.isFolder {
            move([source], toPage: page)
            return
        }
        source.apps.removeAll { $0 === app }
        allGroups.removeAll { $0.apps.isEmpty }
        allGroups.append(LaunchpadGroup(id: UUID().uuidString, name: app.name, apps: [app],
                                        order: Int.max, page: page, isFolder: false))
        saveLayout()
    }

    func moveApps(_ apps: [LaunchpadApp], intoFolder folder: LaunchpadGroup) {
        let perPage = appState.perPage
        for app in apps {
            for group in allGroups where group !== folder {
                group.apps.removeAll { $0 === app }
            }
        }
        allGroups.removeAll { $0.apps.isEmpty && !$0.isFolder }
        folder.isFolder = true
        folder.apps.append(contentsOf: apps)
        allGroups = PresentationNormalizer.normalize(allGroups, perPage: perPage)
        publish(2)
        applicationManager.syncViewDataToDatabase(allGroups)
    }

    // MARK: - Hidden apps

    /// Restores a hidden app to the end of the layout.
    func unhide(_ app: LaunchpadApp) {
        let ctx = PersistenceController.shared.viewContext
        applicationManager.setHidden(ctx, appId: app.id, hide: false)
        load(nil)
    }

    func hiddenApps() -> [LaunchpadApp] {
        applicationManager.hiddenApps(PersistenceController.shared.viewContext)
    }

    func hide(_ app: LaunchpadApp) {
        hide(apps: [app])
    }

    /// Hides `apps` and reloads once; `completion` runs after the grid republished.
    func hide(apps: [LaunchpadApp], completion: (() -> Void)? = nil) {
        let ctx = PersistenceController.shared.viewContext
        for app in apps { applicationManager.setHidden(ctx, appId: app.id, hide: true) }
        load { completion?() }
    }

    func restoreAllHidden() {
        let ctx = PersistenceController.shared.viewContext
        applicationManager.restoreAllHidden(ctx)
        load(nil)
    }

    // MARK: - Reorganize

    /// One optional direction per sort key, as in the original's packed options.
    private struct ReorganizeRules {
        var name: OrganizeSortDirection?
        var added: OrganizeSortDirection?
        var lastUsed: OrganizeSortDirection?
        var iconColor: OrganizeSortDirection?
        var folderRule: FolderRule
        var applePlacement: OrganizePlacement
        var sortFolderContents: Bool
        var fillEmptySlots: Bool
        var pageIndexes: Set<Int>?

        enum FolderRule { case keep, removeAll, moveToFront, moveToBack }
    }

    /// Maps the sheet's single method + direction onto the rules, then reorganises. When icon-colour
    /// sorting is requested the icons of the affected apps are classified first.
    func reorganize(_ options: LayoutOrganizeOptions, completion: (() -> Void)? = nil) {
        LogManager.shared.info("Reorganizing layout, applying rules")
        var rules = ReorganizeRules(
            folderRule: options.removesAllFolders ? .removeAll
                : (options.folderPlacement == .front ? .moveToFront : (options.folderPlacement == .back ? .moveToBack : .keep)),
            applePlacement: options.appleAppPlacement,
            sortFolderContents: options.sortsFolderContents,
            fillEmptySlots: options.reorganizeAcrossPages,
            pageIndexes: nil)
        switch options.sortMethod {
        case .currentOrder: break
        case .name: rules.name = options.sortDirection
        case .dateAdded: rules.added = options.sortDirection
        case .lastUsed: rules.lastUsed = options.sortDirection
        case .iconColor: rules.iconColor = options.sortDirection
        }
        switch options.scope {
        case .allPages: rules.pageIndexes = nil
        case .currentPage: rules.pageIndexes = [appState.currentPage]
        case .specificPage: rules.pageIndexes = options.selectedPages.isEmpty ? nil : options.selectedPages
        }

        guard rules.iconColor != nil else {
            applyReorganize(rules, colors: [:])
            completion?()
            return
        }
        let apps = allGroups
            .filter { rules.pageIndexes?.contains($0.page) ?? true }
            .flatMap(\.apps)
        var colors: [String: Double] = [:]
        var remaining = apps.count
        guard remaining > 0 else {
            applyReorganize(rules, colors: [:])
            completion?()
            return
        }
        for app in apps {
            AppIconRepository.shared.icon(for: app.url) { [weak self] image in
                if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let rank = IconColorClassifier.rank(of: cg) {
                    colors[app.id] = rank
                }
                remaining -= 1
                if remaining == 0 {
                    self?.applyReorganize(rules, colors: colors)
                    completion?()
                }
            }
        }
    }

    private func applyReorganize(_ rules: ReorganizeRules, colors: [String: Double]) {
        let perPage = max(1, appState.perPage)
        var groups = allGroups
        let pages = rules.pageIndexes ?? Set(groups.map(\.page))
        func byPageOrder(_ list: [LaunchpadGroup]) -> [LaunchpadGroup] {
            list.sorted { $0.page != $1.page ? $0.page < $1.page : $0.order < $1.order }
        }

        if rules.folderRule == .removeAll {
            groups = byPageOrder(groups).flatMap { group -> [LaunchpadGroup] in
                guard group.isFolder, pages.contains(group.page) else { return [group] }
                return group.apps.map { LaunchpadGroup(id: UUID().uuidString, name: $0.name, apps: [$0],
                                                      order: 0, page: group.page, isFolder: false) }
            }
            groups = PresentationNormalizer.normalize(groups, perPage: perPage)
        } else if rules.sortFolderContents {
            for group in groups where group.isFolder && pages.contains(group.page) {
                group.apps = sortApps(group.apps, rules: rules, colors: colors)
            }
        }

        if !rules.fillEmptySlots {
            // Items stay on their page and are sorted within it.
            for page in pages.sorted() {
                let onPage = groups.filter { $0.page == page }.sorted { $0.order < $1.order }
                for (index, group) in sortGroups(onPage, rules: rules, colors: colors).enumerated() {
                    group.page = page
                    group.order = index
                }
            }
        } else if let first = pages.min(), let last = pages.max() {
            // Pack the selected pages; following pages shift by the change in page count.
            let span = last - first + 1
            let selected = sortGroups(byPageOrder(groups.filter { pages.contains($0.page) }), rules: rules, colors: colors)
            for (index, group) in selected.enumerated() {
                group.page = first + index / perPage
                group.order = index % perPage
            }
            let delta = Int(ceil(Double(selected.count) / Double(perPage))) - span
            if delta != 0 { for group in groups where group.page > last && !pages.contains(group.page) { group.page += delta } }
            groups = byPageOrder(groups)
        }

        allGroups = PresentationNormalizer.normalize(groups, perPage: perPage)
        appState.sortBy = .custom                       // reorganizing always switches to custom order
        publish(2)
        applicationManager.syncViewDataToDatabase(allGroups)
        NotificationCenter.default.post(name: .refreshPreferencesDataPublic, object: nil)
    }

    private func isAppleGroup(_ group: LaunchpadGroup) -> Bool {
        !group.isFolder && (group.apps.first.map { ApplicationManager.isAppleApp($0.url) } ?? false)
    }

    /// Most frequent colour rank among a group's apps (ties → the smallest rank); nil without colours.
    private func groupColor(_ group: LaunchpadGroup, colors: [String: Double]) -> Double? {
        var counts: [Double: Int] = [:]
        for app in group.apps { if let rank = colors[app.id] { counts[rank, default: 0] += 1 } }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }

    private func trimmed(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The comparator chain: folder rule, Apple placement, colour, name, added, last used, then
    /// the original offset (stable).
    private func sortGroups(_ groups: [LaunchpadGroup], rules: ReorganizeRules, colors: [String: Double]) -> [LaunchpadGroup] {
        let indexed = groups.enumerated().map { (offset: $0.offset, group: $0.element) }
        func ordered(_ a: (offset: Int, group: LaunchpadGroup), _ b: (offset: Int, group: LaunchpadGroup)) -> Bool {
            let ga = a.group, gb = b.group
            switch rules.folderRule {
            case .moveToFront: if ga.isFolder != gb.isFolder { return ga.isFolder }
            case .moveToBack: if ga.isFolder != gb.isFolder { return !ga.isFolder }
            case .keep, .removeAll: break
            }
            if rules.applePlacement != .keep {
                func key(_ g: LaunchpadGroup) -> Bool { rules.applePlacement == .front ? !isAppleGroup(g) : isAppleGroup(g) }
                let ka = key(ga), kb = key(gb)
                if ka != kb { return !ka && kb }
            }
            if let direction = rules.iconColor {
                let ca = groupColor(ga, colors: colors), cb = groupColor(gb, colors: colors)
                let asc = direction == .ascending
                if ca == nil && cb != nil { return false }
                if ca != nil && cb == nil { return true }
                if let ca, let cb, ca != cb { return asc ? ca < cb : ca > cb }
                let r = trimmed(ga.displayName).localizedStandardCompare(trimmed(gb.displayName))
                if r != .orderedSame { return asc ? r == .orderedAscending : r == .orderedDescending }
                return asc ? ga.id < gb.id : ga.id > gb.id
            }
            if let direction = rules.name {
                let r = trimmed(ga.displayName).localizedStandardCompare(trimmed(gb.displayName))
                if r != .orderedSame { return direction == .ascending ? r == .orderedAscending : r == .orderedDescending }
            }
            if let direction = rules.added, ga.addedDate != gb.addedDate {
                return direction == .ascending ? ga.addedDate < gb.addedDate : ga.addedDate > gb.addedDate
            }
            if let direction = rules.lastUsed, ga.lastOpenedDate != gb.lastOpenedDate {
                return direction == .ascending ? ga.lastOpenedDate < gb.lastOpenedDate : ga.lastOpenedDate > gb.lastOpenedDate
            }
            return a.offset < b.offset
        }
        return indexed.sorted(by: ordered).map(\.group)
    }

    private func sortApps(_ apps: [LaunchpadApp], rules: ReorganizeRules, colors: [String: Double]) -> [LaunchpadApp] {
        let indexed = apps.enumerated().map { (offset: $0.offset, app: $0.element) }
        func ordered(_ a: (offset: Int, app: LaunchpadApp), _ b: (offset: Int, app: LaunchpadApp)) -> Bool {
            let pa = a.app, pb = b.app
            if let direction = rules.iconColor {
                let ca = colors[pa.id], cb = colors[pb.id]
                let asc = direction == .ascending
                if ca == nil && cb != nil { return false }
                if ca != nil && cb == nil { return true }
                if let ca, let cb, ca != cb { return asc ? ca < cb : ca > cb }
                let r = trimmed(pa.name).localizedStandardCompare(trimmed(pb.name))
                if r != .orderedSame { return asc ? r == .orderedAscending : r == .orderedDescending }
                return asc ? pa.id < pb.id : pa.id > pb.id
            }
            if let direction = rules.name {
                let r = trimmed(pa.name).localizedStandardCompare(trimmed(pb.name))
                if r != .orderedSame { return direction == .ascending ? r == .orderedAscending : r == .orderedDescending }
            }
            let da = pa.addedDate ?? .distantPast, db = pb.addedDate ?? .distantPast
            if let direction = rules.added, da != db { return direction == .ascending ? da < db : da > db }
            let la = pa.lastOpenedDate ?? .distantPast, lb = pb.lastOpenedDate ?? .distantPast
            if let direction = rules.lastUsed, la != lb { return direction == .ascending ? la < lb : la > lb }
            return a.offset < b.offset
        }
        return indexed.sorted(by: ordered).map(\.app)
    }
}

/// Organize rules.
enum OrganizeSortMethod: String, CaseIterable {
    case currentOrder, name, dateAdded, lastUsed, iconColor

    var title: String {
        switch self {
        case .currentOrder: return NSLocalizedString("Current Order", comment: "")
        case .name: return NSLocalizedString("Name", comment: "")
        case .dateAdded: return NSLocalizedString("Date Added", comment: "")
        case .lastUsed: return NSLocalizedString("Last Used", comment: "")
        case .iconColor: return NSLocalizedString("Icon Color", comment: "")
        }
    }
}

enum OrganizeSortDirection: String, CaseIterable {
    case ascending, descending

    var title: String {
        switch self {
        case .ascending: return NSLocalizedString("Ascending", comment: "")
        case .descending: return NSLocalizedString("Descending", comment: "")
        }
    }
}

enum OrganizePlacement: String, CaseIterable {
    case front, keep, back

    var title: String {
        switch self {
        case .front: return NSLocalizedString("Before Apps", comment: "")
        case .keep: return NSLocalizedString("Mixed with Apps", comment: "")
        case .back: return NSLocalizedString("After Apps", comment: "")
        }
    }
}

enum OrganizePageScope: String, CaseIterable {
    case currentPage, allPages, specificPage

    var title: String {
        switch self {
        case .currentPage: return NSLocalizedString("Current Page", comment: "")
        case .allPages: return NSLocalizedString("All Pages", comment: "")
        case .specificPage: return NSLocalizedString("Selected Pages", comment: "")
        }
    }
}

struct LayoutOrganizeOptions {
    var sortMethod: OrganizeSortMethod = .currentOrder
    var sortDirection: OrganizeSortDirection = .ascending
    var folderPlacement: OrganizePlacement = .keep
    var appleAppPlacement: OrganizePlacement = .keep
    var removesAllFolders = false
    var sortsFolderContents = false
    var reorganizeAcrossPages = true
    var scope: OrganizePageScope = .allPages
    var selectedPages: Set<Int> = []
}

struct LaunchpadPageMoveTarget {
    var pageIndex: Int
    var availableSlots: Int
}

/// Structural comparison used to decide whether a publish is a content-only or structural change.
struct DisplayStructureSnapshot: Equatable {
    var totalPages: Int
    var groupIDsInOrder: [String]
    var geometry: [String: (page: Int, order: Int)]

    init(totalPages: Int, groups: [LaunchpadGroup]) {
        self.totalPages = totalPages
        self.groupIDsInOrder = groups.map(\.id)
        var geometry: [String: (page: Int, order: Int)] = [:]
        for group in groups { geometry[group.id] = (group.page, group.order) }
        self.geometry = geometry
    }

    init(_ update: LaunchpadDisplayUpdate) {
        self.init(totalPages: update.totalPages, groups: update.groups)
    }

    static func == (lhs: DisplayStructureSnapshot, rhs: DisplayStructureSnapshot) -> Bool {
        guard lhs.totalPages == rhs.totalPages, lhs.groupIDsInOrder == rhs.groupIDsInOrder else { return false }
        guard lhs.geometry.count == rhs.geometry.count else { return false }
        for (key, value) in lhs.geometry {
            guard let other = rhs.geometry[key], other == value else { return false }
        }
        return true
    }
}

/// Pagination normalisation: overflow spills to following pages, then pages are compacted
///.
enum PresentationNormalizer {
    /// Overflow spills onto the following pages, then empty pages are closed up
    /// (`compactPages`): partially filled pages keep their place.
    static func normalize(_ groups: [LaunchpadGroup], perPage: Int) -> [LaunchpadGroup] {
        guard perPage > 0 else { return groups }
        var byPage: [Int: [LaunchpadGroup]] = [:]
        for group in groups {
            var page = max(group.page, 0)
            while (byPage[page]?.count ?? 0) >= perPage { page += 1 }
            group.page = page
            byPage[page, default: []].append(group)
        }
        var result: [LaunchpadGroup] = []
        var hasMissingPages = false
        for (newIndex, page) in byPage.keys.sorted().enumerated() {
            if page != newIndex { hasMissingPages = true }
            for (index, group) in (byPage[page] ?? []).enumerated() {
                group.page = newIndex
                group.order = index
                result.append(group)
            }
        }
        if hasMissingPages {
            DispatchQueue.main.async {
                NotificationChannel.center.post(name: NotificationChannel.Name.missingPages, object: nil)
            }
        }
        return result
    }
}
