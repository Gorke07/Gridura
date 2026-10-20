import Foundation

// MARK: - Persisted enums (Int raw, 0-based, declaration order — )

/// `IconGrid` – grid preset. Raw order matters: it is persisted in UserDefaults and backups.
enum IconGridLayout: Int, CaseIterable, Codable {
    case grid7x5 = 0
    case grid8x5 = 1
    case grid9x5 = 2
    case grid10x5 = 3
    case grid7x6 = 4
    case grid8x6 = 5
    case grid9x6 = 6
    case grid10x6 = 7

    var columns: Int {
        switch self {
        case .grid7x5, .grid7x6: return 7
        case .grid8x5, .grid8x6: return 8
        case .grid9x5, .grid9x6: return 9
        case .grid10x5, .grid10x6: return 10
        }
    }

    var rows: Int {
        switch self {
        case .grid7x5, .grid8x5, .grid9x5, .grid10x5: return 5
        case .grid7x6, .grid8x6, .grid9x6, .grid10x6: return 6
        }
    }
}

/// `ViewMode`
enum BrowsingStyleType: Int, Codable {
    case paged = 0
    case scroll = 1
}

/// `DisplayMode`
enum DisplayModeType: Int, Codable, CaseIterable {
    case fullScreen = 0
    case window = 1
}

/// `AppIcon`
enum AppIconType: Int, Codable, CaseIterable {
    case gridura = 0
    case brand = 1
    case classic = 2
    case classicDark = 3
    case rocket = 4

    /// Asset-catalog base name: `AppIcon/<assetBase>-<Light|Dark>`.
    var assetBase: String {
        switch self {
        case .gridura: return "Gridura"
        case .brand: return "Brand"
        case .classic: return "Classic"
        case .classicDark: return "ClassicDark"
        case .rocket: return "Rocket"
        }
    }
}

/// `HotCorner`
enum HotCornerType: Int, Codable, CaseIterable {
    case topLeft = 0
    case topRight = 1
    case bottomLeft = 2
    case bottomRight = 3
    case off = 4
}

/// `TrackpadGesture`
enum TrackpadType: Int, Codable, CaseIterable {
    case off = 0
    case three = 1
    case four = 2
    case five = 3
}

/// `LaunchShowOn`
enum ShowOnType: Int, Codable, CaseIterable {
    case primary = 0
    case active = 1
    case cursor = 2
    case dock = 3
}

/// `ReturnToHome`
enum ReturnToHomeType: Int, Codable, CaseIterable {
    case always = 0
    case never = 1
    case after5Sec = 2
    case after15Sec = 3
    case after30Sec = 4
    case after1Min = 5
    case after5Min = 6

    /// Seconds before returning to the first page.
    var seconds: Double {
        switch self {
        case .always: return 0
        case .never: return 0
        case .after5Sec: return 5
        case .after15Sec: return 15
        case .after30Sec: return 30
        case .after1Min: return 60
        case .after5Min: return 300
        }
    }
}

/// `SortBy`
enum SortByType: Int, Codable, CaseIterable {
    case custom = 0
    case name = 1
    case added = 2
    case opened = 3
}

/// `SortOrder`
enum SortOrderType: Int, Codable, CaseIterable {
    case ascending = 0
    case descending = 1
}

/// `BackgroundType`
enum BackgroundType: Int, Codable, CaseIterable {
    case wallpaper = 0
    case glassEffect = 1
}

/// `GlassMaterial` → `NSVisualEffectView.Material` raw value.
enum GlassMaterialType: Int, Codable, CaseIterable {
    case ultraThin = 0
    case thin = 1
    case regular = 2
    case thick = 3
    case ultraThick = 4

    /// Raw values of `NSVisualEffectView.Material` as observed in the original.
    var materialRawValue: Int {
        switch self {
        case .ultraThin: return 13     // .hudWindow
        case .thin: return 15          // .fullScreenUI
        case .regular: return 6        // .popover
        case .thick: return 5          // .menu
        case .ultraThick: return 21    // .underWindowBackground
        }
    }
}

/// `PreferenceModule` – the `object` of a `PreferencesChanged` notification.
enum PreferenceModule: Int, Codable {
    case sortBy = 0
    case sortOrder = 1
    case layout = 2
    case rearrange = 3
    case browsingStyle = 4
    case background = 5
    case dockStyle = 6
    case interface = 7
    case systemData = 8
    case backupData = 9
    case hiddenAppsSearch = 10
}

/// Sub-events of `browsingStyle` change.
enum BrowsingStyleChangeReason: Int, Codable {
    case fullScreen = 0
    case window = 1
}

/// `WindowFadeState`
enum WindowFadeState {
    case idle
    case fadingIn
    case fadingOut
}

/// `AppDirectoryPath` – Codable with keys `system` / `userHome` / `external`, payload key `_0`.
enum AppDirectoryPath: Hashable, Codable {
    case system(String)
    case userHome(String)
    case external(String)

    enum CodingKeys: String, CodingKey {
        case system, userHome, external
    }
    enum PayloadKeys: String, CodingKey {
        case _0
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(String.self, forKey: .system) {
            self = .system(v)
        } else if let v = try c.decodeIfPresent(String.self, forKey: .userHome) {
            self = .userHome(v)
        } else if let v = try c.decodeIfPresent(String.self, forKey: .external) {
            self = .external(v)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown AppDirectoryPath"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system(let p):
            var n = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .system)
            try n.encode(p, forKey: ._0)
        case .userHome(let p):
            var n = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .userHome)
            try n.encode(p, forKey: ._0)
        case .external(let p):
            var n = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .external)
            try n.encode(p, forKey: ._0)
        }
    }

    var isUserHome: Bool {
        if case .userHome = self { return true }
        return false
    }

    /// The literal path; userHome paths are relative to `NSHomeDirectory()`.
    var rawPath: String {
        switch self {
        case .system(let p), .userHome(let p), .external(let p): return p
        }
    }

    var expandedPath: String {
        switch self {
        case .userHome(let p): return NSHomeDirectory() + p
        case .system(let p), .external(let p): return p
        }
    }

    var typeRaw: Int64 {
        switch self {
        case .system: return 0
        case .userHome: return 1
        case .external: return 2
        }
    }
}

/// `AppDirectory` – a resolved directory plus its `SourceEntity` identity.
struct AppDirectory: Identifiable, Hashable {
    var id: UUID
    var path: AppDirectoryPath
    var enabled: Bool
    var isCustom: Bool
}

/// A calendar/app date pair from the metadata cache.
struct AppDates: Hashable {
    var added: Date?
    var lastUsed: Date?
}
