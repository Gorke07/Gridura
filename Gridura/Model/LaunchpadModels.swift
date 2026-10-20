import Foundation

/// In-memory app record. Mirrors `LaunchpadApp`.
final class LaunchpadApp {
    var id: String
    var name: String
    /// Non-localized file name (without extension) — used for search keys.
    var defaultName: String
    var alias: String
    var order: Int
    var hidden: Bool
    var url: URL
    var isSourceUnavailable: Bool
    var bundleId: String
    var category: String
    var addedDate: Date?
    var lastOpenedDate: Date?
    var bundleName: String
    var version: String
    var build: String

    // Search keys
    var nameFull: String = ""
    var nameAbbr: String = ""
    var aliasFull: String = ""
    var aliasAbbr: String = ""
    var defaultFull: String = ""
    var defaultAbbr: String = ""

    init(id: String = UUID().uuidString,
         name: String,
         defaultName: String = "",
         alias: String = "",
         order: Int = 0,
         hidden: Bool = false,
         url: URL,
         isSourceUnavailable: Bool = false,
         bundleId: String = "",
         category: String = "",
         addedDate: Date? = nil,
         lastOpenedDate: Date? = nil,
         bundleName: String = "",
         version: String = "",
         build: String = "") {
        self.id = id
        self.name = name
        self.defaultName = defaultName
        self.alias = alias
        self.order = order
        self.hidden = hidden
        self.url = url
        self.isSourceUnavailable = isSourceUnavailable
        self.bundleId = bundleId
        self.category = category
        self.addedDate = addedDate
        self.lastOpenedDate = lastOpenedDate
        self.bundleName = bundleName
        self.version = version
        self.build = build
        regenerateSearchKeys()
    }

    var standardizedPath: String { url.standardizedFileURL.path }

    /// Identity key used by the sync (separator U+001F).
    var identityKey: String {
        let first = bundleId.isEmpty ? url.absoluteString : bundleId
        return [first, bundleName, version, build].joined(separator: "\u{1F}")
    }

    var identityKeyShort: String {
        let first = bundleId.isEmpty ? url.absoluteString : bundleId
        return [first, bundleName].joined(separator: "\u{1F}")
    }

    func regenerateSearchKeys() {
        let n = SearchKeyGenerator.keys(for: name)
        nameFull = n.full
        nameAbbr = n.abbr
        let a = SearchKeyGenerator.keys(for: alias)
        aliasFull = a.full
        aliasAbbr = a.abbr
        let d = SearchKeyGenerator.keys(for: defaultName)
        defaultFull = d.full
        defaultAbbr = d.abbr
    }
}

/// A slot in the grid: either one app or a folder of apps.
final class LaunchpadGroup {
    var id: String
    var name: String
    var apps: [LaunchpadApp]
    var order: Int
    var page: Int
    var isFolder: Bool

    init(id: String = UUID().uuidString,
         name: String,
         apps: [LaunchpadApp],
         order: Int = 0,
         page: Int = 0,
         isFolder: Bool = false) {
        self.id = id
        self.name = name
        self.apps = apps
        self.order = order
        self.page = page
        self.isFolder = isFolder
    }

    /// Folder → name (or "Untitled"); single app → alias if any else name.
    var displayName: String {
        if isFolder {
            return name.isEmpty ? NSLocalizedString("Untitled", comment: "") : name
        }
        guard let first = apps.first else { return NSLocalizedString("Untitled", comment: "") }
        return first.alias.isEmpty ? first.name : first.alias
    }

    /// Never uses the alias.
    var originalName: String {
        if isFolder {
            return name.isEmpty ? NSLocalizedString("Untitled", comment: "") : name
        }
        return apps.first?.name ?? NSLocalizedString("Untitled", comment: "")
    }

    var addedDate: Date { apps.compactMap(\.addedDate).max() ?? .distantPast }
    var lastOpenedDate: Date { apps.compactMap(\.lastOpenedDate).max() ?? .distantPast }

    var contentSignature: GroupContentSignature {
        GroupContentSignature(group: self)
    }
}

/// Cheap equality signature that decides whether a recycled cell needs a rebuild.
struct GroupContentSignature: Equatable {
    struct AppSignature: Equatable {
        var id: String
        var name: String
        var alias: String
        var order: Int
        var hidden: Bool
        var url: String
        var isSourceUnavailable: Bool
    }

    var name: String
    var order: Int
    var page: Int
    var isFolder: Bool
    var apps: [AppSignature]

    init(group: LaunchpadGroup) {
        name = group.name
        order = group.order
        page = group.page
        isFolder = group.isFolder
        apps = group.apps.map {
            AppSignature(id: $0.id, name: $0.name, alias: $0.alias, order: $0.order,
                         hidden: $0.hidden, url: $0.url.absoluteString,
                         isSourceUnavailable: $0.isSourceUnavailable)
        }
    }
}
