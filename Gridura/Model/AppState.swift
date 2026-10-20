import Foundation
import SwiftUI

/// All persisted settings (UserDefaults via `@AppStorage`). Keys, types, defaults and raw
/// values are byte-compatible with the original app 2.4.0.
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Obfuscation constant observed in the original (`0x5A5A5A5A`). Kept for compatibility.
    let key: Int = 0x5A5A5A5A

    // MARK: Persisted

    @AppStorage("LastNewVersion") var lastNewVersion: String = "1.0"
    @AppStorage("IsFirstLaunch") var isFirstLaunch: Bool = true
    @AppStorage("IconGrid") var iconGrid: IconGridLayout = .grid7x5
    @AppStorage("columns") var columnsPerPage: Int = 7
    @AppStorage("rows") var rowsPerPage: Int = 5
    @AppStorage("ViewMode") var browsingStyle: BrowsingStyleType = .paged
    @AppStorage("ShowMenubarIcon") var showMenubarIcon: Bool = true
    @AppStorage("ShowDockIcon") var showDockIcon: Bool = true
    @AppStorage("DisplayMode") var displayMode: DisplayModeType = .fullScreen
    @AppStorage("IsFullScreen") var hideDock: Bool = false
    @AppStorage("AppIcon") var appIcon: AppIconType = .gridura
    @AppStorage("HotCorner") var hotCorner: HotCornerType = .off
    @AppStorage("TrackpadGesture") var trackpadGesture: TrackpadType = .four
    @AppStorage("EnableF4Shortcut") var enableF4Shortcut: Bool = false
    @AppStorage("LaunchShowOn") var showOn: ShowOnType = .primary
    @AppStorage("ReturnToHome") var returnToHome: ReturnToHomeType = .after5Min
    @AppStorage("SortBy") var sortBy: SortByType = .custom
    @AppStorage("SortOrder") var sortOrder: SortOrderType = .ascending
    @AppStorage("HideNames") var hideNames: Bool = false
    @AppStorage("ShowHiddenAppsInSearch") var showHiddenAppsInSearch: Bool = false
    @AppStorage("EnableOptionUninstallMode") var enableOptionUninstallMode: Bool = true
    @AppStorage("BackgroundType") var backgroundType: BackgroundType = .wallpaper
    @AppStorage("IsBlurWallpaper") var isBlurWallpaper: Bool = true
    @AppStorage("WallpaperBlurRadius") var wallpaperBlurRadius: Int = 30
    @AppStorage("GlassMaterial") var glassMaterial: GlassMaterialType = .ultraThin
    @AppStorage("LastHiddenTime") var lastHiddenTime: Double = 0
    @AppStorage("V2UpdateKey") var updateKey: Int = 0
    @AppStorage("DisabledDefaultAppDirectoryPaths") var disabledDefaultAppDirectoryPathsValue: String = ""

    // MARK: Non-persisted published

    @Published var hiddenAppCount: Int = 0
    @Published var customAppDirectoryCount: Int = 0
    @Published var currentPage: Int = 0

    // MARK: Derived

    /// `DisabledDefaultAppDirectoryPaths` is a JSON array of path strings.
    var disabledDefaultAppDirectoryPaths: [String] {
        guard let data = disabledDefaultAppDirectoryPathsValue.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    var columns: Int { max(columnsPerPage, 1) }
    var rows: Int { max(rowsPerPage, 1) }
    var perPage: Int { max(1, columns * rows) }

    private init() {
        // Keep `columns`/`rows` in sync with a loaded `IconGrid` preset on first launch.
        if !UserDefaults.standard.bool(forKey: "Gridura.initialisedGrid") {
            columnsPerPage = iconGrid.columns
            rowsPerPage = iconGrid.rows
            UserDefaults.standard.set(true, forKey: "Gridura.initialisedGrid")
        }
    }

    /// Applies an `IconGrid` preset to the separate `columns`/`rows` keys (Preferences UI does this).
    func applyIconGrid(_ grid: IconGridLayout) {
        iconGrid = grid
        columnsPerPage = grid.columns
        rowsPerPage = grid.rows
    }
}
