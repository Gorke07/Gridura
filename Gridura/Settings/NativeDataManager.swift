import SQLite3
import Foundation
import CoreData

/// Imports the system Launchpad database.
///
/// The system DB lives at `<DARWIN_USER_DIR>/com.apple.dock.launchpad/db/db` and is read with
/// `sqlite3` through a helper process, matching the original's use of the C API.
final class NativeDataManager {
    static let shared = NativeDataManager()

    enum NativeLaunchpadError: LocalizedError {
        case databaseNotFound
        case cantOpenDatabase
        case dataError

        var errorDescription: String? {
            switch self {
            case .databaseNotFound: return NSLocalizedString("Launchpad database file not found", comment: "")
            case .cantOpenDatabase: return NSLocalizedString("Unable to open Launchpad database", comment: "")
            case .dataError: return NSLocalizedString("Database Read Error", comment: "")
            }
        }
    }

    struct NativeApp {
        var itemId: String
        var title: String
        var bundleId: String?
    }

    struct NativeItem {
        var rowId: String
        var type: Int
        var parentId: String?
        var ordering: Int
    }

    private init() {}

    /// `getconf DARWIN_USER_DIR` → `/private<dir>com.apple.dock.launchpad/db/db`.
    func databasePath() throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        task.arguments = ["DARWIN_USER_DIR"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw NativeLaunchpadError.databaseNotFound }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = "/private" + output + "com.apple.dock.launchpad/db/db"
        guard FileManager.default.fileExists(atPath: path) else { throw NativeLaunchpadError.databaseNotFound }
        return path
    }

    /// Verifies the required tables exist.
    func validateSchema(at path: String) throws {
        let tables = try query(path: path, sql: "SELECT name FROM sqlite_master WHERE type='table';")
            .compactMap { $0.first }
        let required: Set<String> = ["apps", "groups", "items"]
        guard required.isSubset(of: Set(tables)) else {
            LogManager.shared.error("Native data missing tables: \(tables)")
            throw NativeLaunchpadError.dataError
        }
    }

    func readApps(at path: String) throws -> [NativeApp] {
        try query(path: path, sql: "SELECT item_id, title, bundleid FROM apps;").map { row in
            NativeApp(itemId: row[safe: 0] ?? "", title: row[safe: 1] ?? "Unknown App", bundleId: row[safe: 2])
        }
    }

    /// `SELECT rowid, uuid, flags, type, parent_id, ordering` — the columns the shipped app reads.
    /// Empty strings come back from SQLite for NULLs, so they are normalised to `nil`.
    func readItems(at path: String) throws -> [NativeItem] {
        try query(path: path, sql: "SELECT rowid, type, parent_id, ordering FROM items ORDER BY parent_id, ordering;")
            .map { row in
                let parent = row[safe: 2].flatMap { $0.isEmpty ? nil : $0 }
                return NativeItem(rowId: row[safe: 0] ?? "",
                                  type: Int(row[safe: 1] ?? "") ?? 0,
                                  parentId: parent,
                                  ordering: Int(row[safe: 3] ?? "") ?? 0)
            }
    }

    /// Reads the group titles (folder names).
    func readGroupTitles(at path: String) throws -> [String: String] {
        var result: [String: String] = [:]
        let rows = try query(path: path, sql: "SELECT item_id, title FROM groups;")
        for row in rows {
            if let id = row[safe: 0], let title = row[safe: 1] { result[id] = title }
        }
        if result.isEmpty {
            // Older schema keeps the title on the item row.
            let items = try query(path: path, sql: "SELECT uuid, title FROM items;")
            for row in items {
                if let uuid = row[safe: 0], let title = row[safe: 1], !title.isEmpty { result[uuid] = title }
            }
        }
        return result
    }

    // MARK: - Import

    struct ImportResult {
        var apps: Int
        var folders: Int
        var pages: Int
    }

    @discardableResult
    func importLayout() throws -> ImportResult {
        let path = try databasePath()
        try validateSchema(at: path)

        let nativeApps = try readApps(at: path)
        let items = try readItems(at: path)
        let groupTitles = try readGroupTitles(at: path)

        let scanned = ApplicationManager.shared.scanDirectories(
            ApplicationManager.shared.appDirectories(PersistenceController.shared.viewContext))
        let byBundle = Dictionary(grouping: scanned) { $0.bundleId }

        // item type: 1 root, 2 page, 3 folder, 0/≥4 app.
        let roots = items.filter { $0.type == 1 }
        let pages = items.filter { $0.type == 2 && (roots.isEmpty || $0.parentId == roots.first?.rowId) }
        let folders = items.filter { $0.type == 3 }
        let folderIds = Set(folders.map(\.rowId))

        func localApp(for item: NativeItem) -> LaunchpadApp? {
            guard let native = nativeApps.first(where: { $0.itemId == item.rowId }) else { return nil }
            if let bundleId = native.bundleId, let list = byBundle[bundleId], let match = list.first { return match }
            return scanned.first { $0.name == native.title }
        }

        var appCount = 0
        var folderCount = 0
        var pageCount = 0

        let ctx = PersistenceController.shared.newBackgroundContext(named: "importNative")
        var thrown: Error?

        ctx.performAndWait {
            do {
                for entity in PersistenceController.shared.container.managedObjectModel.entities {
                    guard let name = entity.name else { continue }
                    let request = NSFetchRequest<NSFetchRequestResult>(entityName: name)
                    let delete = NSBatchDeleteRequest(fetchRequest: request)
                    delete.resultType = .resultTypeObjectIDs
                    if let result = try ctx.execute(delete) as? NSBatchDeleteResult,
                       let objectIDs = result.result as? [NSManagedObjectID] {
                        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                                                            into: [PersistenceController.shared.viewContext])
                    }
                }

                // Apps that live inside a folder are grouped by the folder of their parent page.
                let pageToFolder = Dictionary(uniqueKeysWithValues: pages.compactMap { page -> (String, String)? in
                    guard let parent = page.parentId, folderIds.contains(parent) else { return nil }
                    return (page.rowId, parent)
                })

                for (pageIndex, page) in pages.enumerated() {
                    guard pageToFolder[page.rowId] == nil else { continue }
                    pageCount += 1
                    let children = items
                        .filter { $0.parentId == page.rowId }
                        .sorted { $0.ordering < $1.ordering }
                    var slot = 0
                    for child in children {
                        if folderIds.contains(child.rowId) {
                            // Folder → collect the apps of its inner page(s).
                            let innerPages = pages.filter { $0.parentId == child.rowId }
                            var apps: [LaunchpadApp] = []
                            for inner in innerPages {
                                for innerChild in items.filter({ $0.parentId == inner.rowId }).sorted(by: { $0.ordering < $1.ordering }) {
                                    if let app = localApp(for: innerChild) { apps.append(app) }
                                }
                            }
                            guard !apps.isEmpty else { continue }
                            let group = GroupEntity(context: ctx)
                            group.id = UUID().uuidString
                            group.name = groupTitles[child.rowId] ?? NSLocalizedString("Untitled", comment: "")
                            group.isFolder = true
                            group.page = Int64(pageIndex)
                            group.order = Int64(slot)
                            group.apps = NSOrderedSet(array: apps.enumerated().map { index, app in
                                let entity = Self.makeEntity(ctx, app)
                                entity.order = Int64(index)
                                return entity
                            })
                            slot += 1
                            folderCount += 1
                        } else if let app = localApp(for: child) {
                            let group = GroupEntity(context: ctx)
                            group.id = UUID().uuidString
                            group.name = ""
                            group.isFolder = false
                            group.page = Int64(pageIndex)
                            group.order = Int64(slot)
                            group.apps = NSOrderedSet(array: [Self.makeEntity(ctx, app)])
                            slot += 1
                            appCount += 1
                        }
                    }
                }

                // Local apps the native DB does not know about go after the last page.
                let importedIds = Set((try? ctx.fetch(AppEntity.fetchRequest()))?.compactMap(\.id) ?? [])
                var extraPage = pageCount
                var extraSlot = 0
                for app in scanned where !importedIds.contains(app.id) {
                    let group = GroupEntity(context: ctx)
                    group.id = UUID().uuidString
                    group.name = ""
                    group.isFolder = false
                    group.page = Int64(extraPage)
                    group.order = Int64(extraSlot)
                    group.apps = NSOrderedSet(array: [Self.makeEntity(ctx, app)])
                    extraSlot += 1
                    if extraSlot >= AppState.shared.perPage { extraPage += 1; extraSlot = 0 }
                    appCount += 1
                }

                if ctx.hasChanges { try ctx.save() }
            } catch {
                ctx.rollback()
                thrown = error
            }
        }
        if let thrown { throw thrown }

        NotificationChannel.center.post(name: NotificationChannel.Name.preferencesChanged,
                                        object: PreferenceModule.systemData.rawValue)
        return ImportResult(apps: appCount, folders: folderCount, pages: pageCount)
    }

    private static func makeEntity(_ ctx: NSManagedObjectContext, _ app: LaunchpadApp) -> AppEntity {
        let entity = AppEntity(context: ctx)
        entity.id = app.id
        entity.name = app.name
        entity.bundleId = app.bundleId
        entity.bundleName = app.bundleName
        entity.version = app.version
        entity.build = app.build
        entity.category = app.category
        entity.url = app.url
        entity.order = 0
        entity.alias = nil
        entity.hidden = false
        return entity
    }

    // MARK: - sqlite3 helper

    /// Runs `sql` through the SQLite C API (read-only) and returns every row as strings
    /// (NULL → ""), like the original's `sqlite3_open` / `sqlite3_step` use.
    private func query(path: String, sql: String) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw NativeLaunchpadError.cantOpenDatabase
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw NativeLaunchpadError.dataError
        }
        defer { sqlite3_finalize(statement) }

        var rows: [[String]] = []
        let columns = Int(sqlite3_column_count(statement))
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String] = []
            for column in 0..<columns {
                if let text = sqlite3_column_text(statement, Int32(column)) {
                    row.append(String(cString: text))
                } else {
                    row.append("")
                }
            }
            rows.append(row)
        }
        return rows
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
