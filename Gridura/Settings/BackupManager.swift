import Foundation
import AppKit
import CoreData
import CryptoKit

/// `.gridura` layout backup: JSON inside AES-GCM.
///
/// The file format is identical to the shipped app's so backups move between the two.
final class BackupManager {
    static let shared = BackupManager()

    /// 32-byte key derived from the fixed passphrase the original embeds.
    private let key: SymmetricKey = {
        let data = Data("1031_lo-Bakup".utf8)
        return SymmetricKey(data: SHA256.hash(data: data))
    }()

    private let context = PersistenceController.shared.viewContext

    static let typeIdentifier = "app.gridura.Gridura.backup"

    private init() {}

    // MARK: - DTOs

    struct Metadata: Codable {
        var version: Int
        var buildVersion: String
        var exportDate: Date
    }

    struct Setting: Codable {
        var columns: Int
        var rows: Int
        var browsingStyle: Int
    }

    struct AppDTO: Codable {
        var groupId: String?
        var id: String
        var bundleId: String
        var bundleName: String?
        var version: String?
        var build: String?
        var name: String
        var order: Int
        var url: String
        var alias: String?
        var category: String?
        var hidden: Bool
    }

    struct GroupDTO: Codable {
        var id: String
        var name: String
        var isFolder: Bool
        var page: Int
        var order: Int
    }

    struct SourceDTO: Codable {
        var id: String
        var path: String
        var type: Int
        var enabled: Bool
    }

    struct Payload: Codable {
        var setting: Setting
        var apps: [AppDTO]
        var groups: [GroupDTO]
        var sources: [SourceDTO]
    }

    struct Container: Codable {
        var metadata: Metadata
        var data: Payload
    }

    enum BackupError: LocalizedError {
        case invalidFile
        case unsupportedVersion
        case decodeFailed
        case dbFailed(Error)
        case noData

        var errorDescription: String? {
            switch self {
            case .invalidFile: return NSLocalizedString("Backup file not found", comment: "")
            case .unsupportedVersion: return NSLocalizedString("Backup version is not supported", comment: "")
            case .decodeFailed: return NSLocalizedString("Failed to read backup file", comment: "")
            case .dbFailed(let error): return String(format: NSLocalizedString("Failed to save to database: %@", comment: ""), error.localizedDescription)
            case .noData: return NSLocalizedString("Failed to read backup file", comment: "")
            }
        }
    }

    // MARK: - Export

    func export() throws -> (data: Data, fileName: String) {
        var apps: [AppDTO] = []
        var groups: [GroupDTO] = []
        var sources: [SourceDTO] = []

        context.performAndWait {
            let groupEntities = (try? context.fetch(GroupEntity.fetchRequest())) ?? []
            let appEntities = (try? context.fetch(AppEntity.fetchRequest())) ?? []
            let sourceEntities = (try? context.fetch(SourceEntity.fetchRequest())) ?? []

            groups = groupEntities.map {
                GroupDTO(id: $0.id ?? "", name: $0.name ?? "", isFolder: $0.isFolder,
                         page: Int($0.page), order: Int($0.order))
            }
            apps = appEntities.map { entity in
                AppDTO(groupId: entity.group?.id ?? nil,
                       id: entity.id ?? "",
                       bundleId: entity.bundleId ?? "",
                       bundleName: entity.bundleName,
                       version: entity.version,
                       build: entity.build,
                       name: entity.name ?? "",
                       order: Int(entity.order),
                       url: entity.url?.absoluteString ?? "",
                       alias: entity.alias,
                       category: entity.category,
                       hidden: entity.hidden)
            }
            sources = sourceEntities.map {
                SourceDTO(id: $0.id?.uuidString ?? "", path: $0.path ?? "", type: Int($0.type), enabled: $0.enabled)
            }
        }

        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "N/A"
        let payload = Payload(setting: Setting(columns: AppState.shared.columnsPerPage,
                                               rows: AppState.shared.rowsPerPage,
                                               browsingStyle: AppState.shared.browsingStyle.rawValue),
                              apps: apps, groups: groups, sources: sources)
        let container = Container(metadata: Metadata(version: 1, buildVersion: build, exportDate: Date()), data: payload)

        let encoder = JSONEncoder()
        let json = try encoder.encode(container)
        let sealed = try AES.GCM.seal(json, using: key)
        guard let combined = sealed.combined else { throw BackupError.decodeFailed }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let name = "Gridura_Backup_" + formatter.string(from: Date()) + ".gridura"
        return (combined, name)
    }

    // MARK: - Import

    func read(url: URL) throws -> Container {
        guard FileManager.default.fileExists(atPath: url.path) else { throw BackupError.invalidFile }
        guard let data = try? Data(contentsOf: url) else { throw BackupError.decodeFailed }
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key)
        let container = try JSONDecoder().decode(Container.self, from: plaintext)
        guard container.metadata.version <= 1 else { throw BackupError.unsupportedVersion }
        return container
    }

    func restore(_ container: Container) throws {
        let ctx = PersistenceController.shared.newBackgroundContext(named: "importBackup")
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

                var groupMap: [String: GroupEntity] = [:]
                for dto in container.data.groups {
                    let entity = GroupEntity(context: ctx)
                    entity.id = dto.id
                    entity.name = dto.name
                    entity.isFolder = dto.isFolder
                    entity.page = Int64(dto.page)
                    entity.order = Int64(dto.order)
                    entity.apps = NSOrderedSet()
                    groupMap[dto.id] = entity
                }

                var orderedByGroup: [String: [AppEntity]] = [:]
                for dto in container.data.apps {
                    let entity = AppEntity(context: ctx)
                    entity.id = dto.id
                    entity.bundleId = dto.bundleId
                    entity.bundleName = dto.bundleName ?? ""
                    entity.version = dto.version ?? ""
                    entity.build = dto.build ?? ""
                    entity.name = dto.name
                    entity.order = Int64(dto.order)
                    entity.url = URL(string: dto.url)
                    entity.alias = dto.alias
                    entity.category = dto.category ?? ""
                    entity.hidden = dto.hidden
                    if let groupId = dto.groupId, let group = groupMap[groupId] {
                        entity.group = group
                        orderedByGroup[groupId, default: []].append(entity)
                    }
                }
                for (groupId, apps) in orderedByGroup {
                    guard let group = groupMap[groupId] else { continue }
                    group.apps = NSOrderedSet(array: apps.sorted { $0.order < $1.order })
                }

                for dto in container.data.sources {
                    let entity = SourceEntity(context: ctx)
                    entity.id = UUID(uuidString: dto.id) ?? UUID()
                    entity.path = dto.path
                    entity.type = Int64(dto.type)
                    entity.enabled = dto.enabled
                }

                if ctx.hasChanges { try ctx.save() }
            } catch {
                ctx.rollback()
                thrown = error
            }
        }
        if let thrown { throw BackupError.dbFailed(thrown) }
    }

    // MARK: - UI flows

    /// Export with the accessory-view file-name panel.
    func presentExportFlow(completion: ((URL?) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = NSLocalizedString("Export Backup", comment: "")
        panel.prompt = NSLocalizedString("Export", comment: "")
        panel.message = NSLocalizedString("Please select a folder to save the backup file", comment: "")

        let defaultName: String
        do { defaultName = try export().fileName } catch { defaultName = "Gridura_Backup.gridura" }
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 34))
        let label = NSTextField(labelWithString: NSLocalizedString("File Name:", comment: ""))
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 0, y: 7, width: 70, height: 20)
        let field = NSTextField(frame: NSRect(x: 74, y: 4, width: 306, height: 24))
        field.stringValue = (defaultName as NSString).deletingPathExtension
        accessory.addSubview(label)
        accessory.addSubview(field)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, let folder = panel.url else { completion?(nil); return }
        var name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = (defaultName as NSString).deletingPathExtension }
        if !name.hasSuffix(".gridura") { name += ".gridura" }
        let target = folder.appendingPathComponent(name)

        do {
            let (data, _) = try export()
            try data.write(to: target, options: .atomic)
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Export Success", comment: "")
            alert.informativeText = String(format: NSLocalizedString("Backup exported successfully to:\n%@", comment: ""), target.path)
            alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
            alert.runModal()
            completion?(target)
        } catch {
            LogManager.shared.error("[ERROR] \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = String(format: NSLocalizedString("Export Failed: %@", comment: ""), error.localizedDescription)
            alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
            alert.runModal()
            completion?(nil)
        }
    }

    /// Import step 1: choose and decode a backup. Errors are shown here; the
    /// returned container is confirmed in the Replace sheet before anything is overwritten.
    func pickBackup() -> Container? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = NSLocalizedString("Import Backup", comment: "")
        panel.prompt = NSLocalizedString("Import", comment: "")
        panel.message = NSLocalizedString("Please select a Gridura backup file to import", comment: "")
        panel.allowedContentTypes = [UTType(exportedAs: Self.typeIdentifier, conformingTo: .data)]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try read(url: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(format: NSLocalizedString("Import Failed: %@", comment: ""), error.localizedDescription)
            alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
            alert.runModal()
            return nil
        }
    }

    /// Import step 2: replace the library with `container` and announce the result.
    func applyRestore(_ container: Container) {
        do {
            try restore(container)
            LaunchpadDataManager.shared.currentSearchQuery = ""
            LaunchpadDataManager.shared.load(nil)
            ApplicationManager.shared.scan(fromBackup: true) { }
            NotificationChannel.center.post(name: NotificationChannel.Name.preferencesChanged,
                                            object: PreferenceModule.backupData.rawValue,
                                            userInfo: [NotificationChannel.UserInfoKey.setting: [
                                                "columns": container.data.setting.columns,
                                                "rows": container.data.setting.rows,
                                                "browsingStyle": container.data.setting.browsingStyle,
                                            ]])
            let success = NSAlert()
            success.messageText = NSLocalizedString("Import Success", comment: "")
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            success.informativeText = String(format: NSLocalizedString("Current data has been restored to %@", comment: ""),
                                             formatter.string(from: container.metadata.exportDate))
            success.addButton(withTitle: NSLocalizedString("Done", comment: ""))
            success.runModal()
        } catch {
            let failure = NSAlert()
            failure.messageText = String(format: NSLocalizedString("Import Failed: %@", comment: ""), error.localizedDescription)
            failure.addButton(withTitle: NSLocalizedString("Done", comment: ""))
            failure.runModal()
        }
    }
}

import UniformTypeIdentifiers
