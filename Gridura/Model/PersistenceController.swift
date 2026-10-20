import Foundation
import AppKit
import CoreData

/// Core Data stack. Store at `~/Library/Application Support/Gridura/Gridura.sqlite`
/// (not sandboxed), lightweight migration enabled — byte-compatible with the original
///.
final class PersistenceController {
    static let shared = PersistenceController()

    private var _container: NSPersistentContainer?
    private let lock = NSLock()

    var container: NSPersistentContainer {
        lock.lock()
        defer { lock.unlock() }
        if let c = _container { return c }
        let c = makeContainer()
        _container = c
        return c
    }

    var viewContext: NSManagedObjectContext { container.viewContext }

    private func makeContainer() -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "Gridura")
        #if DEBUG
        // Self-test runs keep their data away from the real store.
        if let dir = ProcessInfo.processInfo.environment["GRIDURA_STORE_DIR"],
           let description = container.persistentStoreDescriptions.first {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            description.url = URL(fileURLWithPath: dir).appendingPathComponent("Gridura.sqlite")
        }
        #endif
        if let description = container.persistentStoreDescriptions.first {
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        }
        container.loadPersistentStores { [weak self] _, error in
            guard let error = error as NSError? else { return }
            let storePath = container.persistentStoreDescriptions.first?.url?.path ?? "nil"
            self?.presentLoadError(error, storePath: storePath)
        }
        // Use the local `container` here: `viewContext` would re-enter the `container` getter and
        // deadlock on the non-recursive lock.
        configure(container.viewContext, name: "viewContext")
        return container
    }

    private func presentLoadError(_ error: NSError, storePath: String) {
        LogManager.shared.error("Unresolved error \(error), \(error.userInfo)")
        let lines = [
            "Store Path: \(storePath)",
            "Domain: \(error.domain)",
            "Code: \(error.code)",
            "Description: \(error.localizedDescription)",
            "UserInfo: \(error.userInfo.description)",
        ]
        let text = lines.joined(separator: "\n")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = NSLocalizedString("Database Initialization Failed", comment: "")
            alert.informativeText = text
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    /// Applies the settings common to every context in the original app.
    @discardableResult
    func configure(_ context: NSManagedObjectContext, name: String) -> NSManagedObjectContext {
        context.automaticallyMergesChangesFromParent = true
        context.name = name
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.undoManager = nil
        context.shouldDeleteInaccessibleFaults = true
        return context
    }

    /// A background context with the same settings as the original's named contexts.
    func newBackgroundContext(named name: String) -> NSManagedObjectContext {
        configure(container.newBackgroundContext(), name: name)
    }
}
