import Foundation
import CoreData

// Manual `NSManagedObject` subclasses for the Gridura model.
// Attribute names, types and relationships mirror the original byte-for-byte so that an
// original app store layout (Gridura.sqlite).

@objc(AppEntity)
public final class AppEntity: NSManagedObject {
    @NSManaged public var id: String?
    @NSManaged public var name: String?
    @NSManaged public var bundleId: String?
    @NSManaged public var bundleName: String?
    @NSManaged public var version: String?
    @NSManaged public var build: String?
    @NSManaged public var category: String?
    @NSManaged public var url: URL?
    @NSManaged public var order: Int64
    @NSManaged public var alias: String?
    @NSManaged public var hidden: Bool
    @NSManaged public var group: GroupEntity?

    @nonobjc public class func fetchRequest() -> NSFetchRequest<AppEntity> {
        NSFetchRequest<AppEntity>(entityName: "AppEntity")
    }

    /// Convenience non-optional projection of `hidden` (nil in older stores counts as false).
    public var isHidden: Bool { primitiveValue(forKey: "hidden") == nil ? false : hidden }
}

@objc(GroupEntity)
public final class GroupEntity: NSManagedObject {
    @NSManaged public var id: String?
    @NSManaged public var name: String?
    @NSManaged public var isFolder: Bool
    @NSManaged public var page: Int64
    @NSManaged public var order: Int64
    @NSManaged public var apps: NSOrderedSet?

    @nonobjc public class func fetchRequest() -> NSFetchRequest<GroupEntity> {
        NSFetchRequest<GroupEntity>(entityName: "GroupEntity")
    }

    public var orderedApps: [AppEntity] {
        (apps?.array as? [AppEntity]) ?? []
    }
}

@objc(SourceEntity)
public final class SourceEntity: NSManagedObject {
    @NSManaged public var id: UUID?
    @NSManaged public var path: String?
    @NSManaged public var enabled: Bool
    @NSManaged public var type: Int64

    @nonobjc public class func fetchRequest() -> NSFetchRequest<SourceEntity> {
        NSFetchRequest<SourceEntity>(entityName: "SourceEntity")
    }
}
