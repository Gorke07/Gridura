import Foundation

/// App-internal notifications are posted on a private `NotificationCenter`, not `.default`
///. Names match the original raw strings.
enum NotificationChannel {
    static let center = NotificationCenter()

    enum Name {
        static let preferencesChanged = Notification.Name("PreferencesChanged")
        static let scanApp = Notification.Name("ScanApp")
        static let refreshPreferencesData = Notification.Name("RefreshPreferencesData")
        static let missingPages = Notification.Name("MissingPages")
        static let refreshPendingIcon = Notification.Name("RefreshPendingIcon")
    }

    enum UserInfoKey {
        static let setting = "setting"
        static let urls = "urls"
        static let delay = "delay"
    }

    /// Distributed name posted when the AppIcon setting changes.
    static let appIconChangedDistributedName = Notification.Name("Gridura.AppIconChanged")
}

extension Notification.Name {
    /// Posted on `NotificationCenter.default` when the preferences window becomes key, so tabs
    /// reload their state.
    static let refreshPreferencesDataPublic = Notification.Name("RefreshPreferencesData")
}

extension NotificationCenter {
    /// Convenience for the app-internal private channel.
}
