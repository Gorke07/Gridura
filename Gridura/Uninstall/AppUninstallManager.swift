import AppKit

// Leftover scan and removal.

struct AppUninstallItem: Identifiable {
    enum Kind: UInt8 { case application = 0, folder = 1, file = 2 }

    /// Raw values and display order follow 
    enum Category: UInt8, CaseIterable {
        case application = 0, appSupport, userFiles, cache, sandbox, groupContainer, httpStorage, log
        case crashLog, webKit, appScript, preference, savedState, launchAgent, aliasFile, unknown

        var title: String {
            switch self {
            case .application: return NSLocalizedString("Application Files", comment: "")
            case .appSupport: return NSLocalizedString("Application Support", comment: "")
            case .userFiles: return NSLocalizedString("User Files", comment: "")
            case .cache: return NSLocalizedString("Caches", comment: "")
            case .sandbox: return NSLocalizedString("Sandbox", comment: "")
            case .groupContainer: return NSLocalizedString("Group Containers", comment: "")
            case .httpStorage: return NSLocalizedString("HTTP Storage", comment: "")
            case .log: return NSLocalizedString("Logs", comment: "")
            case .crashLog: return NSLocalizedString("Crash Logs", comment: "")
            case .webKit: return NSLocalizedString("WebKit Data", comment: "")
            case .appScript: return NSLocalizedString("Application Scripts", comment: "")
            case .preference: return NSLocalizedString("Preferences", comment: "")
            case .savedState: return NSLocalizedString("Saved State", comment: "")
            case .launchAgent: return NSLocalizedString("Launch Items", comment: "")
            case .aliasFile: return NSLocalizedString("Alias File", comment: "")
            case .unknown: return NSLocalizedString("Other Files", comment: "")
            }
        }

        /// On-screen order: Application Files, Application Support, Caches, Sandbox, Group Containers,
        /// Preferences, Saved State, HTTP Storage, WebKit Data, Logs, Crash Logs, Application Scripts,
        /// Launch Items, Alias File, User Files, Other Files.
        var displayRank: Int {
            switch self {
            case .application: return 0
            case .appSupport: return 1
            case .cache: return 2
            case .sandbox: return 3
            case .groupContainer: return 4
            case .preference: return 5
            case .savedState: return 6
            case .httpStorage: return 7
            case .webKit: return 8
            case .log: return 9
            case .crashLog: return 10
            case .appScript: return 11
            case .launchAgent: return 12
            case .aliasFile: return 13
            case .userFiles: return 14
            case .unknown: return 15
            }
        }

        /// Categories whose removal needs the app to be quit (mask 0x1e77).
        var requiresAppQuit: Bool {
            switch self {
            case .application, .appSupport, .userFiles, .sandbox, .groupContainer, .httpStorage,
                 .webKit, .appScript, .preference, .savedState: return true
            default: return false
            }
        }
    }

    let id = UUID()
    var url: URL
    var name: String
    var displayPath: String
    var size: Int64
    var kind: Kind
    var category: Category
}

struct AppUninstallFailure {
    var item: AppUninstallItem
    var error: Error
}

final class AppUninstallManager {
    static let shared = AppUninstallManager()

    private let fm = FileManager.default
    private let home = NSHomeDirectory()
    /// `confstr` user cache and temp directories (`DARWIN_USER_CACHE_DIR`, `DARWIN_USER_TEMP_DIR`).
    private let userCacheAndTemporaryDirectories: [URL]

    private static let stopList: Set<String> = ["run", "start", "launcher", "launch", "game", "helper", "service", "app", "apple"]

    private init() {
        var urls: [URL] = []
        for name in [65538, 65537] {      // _CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR
            var buffer = [CChar](repeating: 0, count: 1024)
            let length = confstr(Int32(name), &buffer, buffer.count)
            guard length > 1 else { continue }
            let value = String(cString: buffer)
            if value.hasPrefix("/") { urls.append(URL(fileURLWithPath: value, isDirectory: true)) }
        }
        userCacheAndTemporaryDirectories = urls
    }

    // MARK: Scan

    func scan(app: LaunchpadApp) -> [AppUninstallItem] {
        let appURL = app.url
        if (try? appURL.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true {
            return [makeItem(appURL, forcedCategory: .aliasFile)]
        }

        var seen = Set<String>()
        var urls: [URL] = []
        func addIfExists(_ url: URL) {
            let key = url.standardizedFileURL.path.lowercased()
            guard !seen.contains(key), fm.fileExists(atPath: url.path) else { return }
            seen.insert(key)
            urls.append(url)
        }

        addIfExists(appURL)
        let identities = identityTokens(app)
        if identities.isEmpty {
            LogManager.shared.info("[WARNING] Uninstall scan identity is empty for app=\(app.name), bundleId=\(app.bundleId), path=\(appURL.path)")
        }
        directCandidates(identities).forEach(addIfExists)
        bundlePrefixedTemp(app.bundleId).forEach(addIfExists)

        if app.bundleId.lowercased() == "com.openai.codex" {
            addIfExists(URL(fileURLWithPath: home).appendingPathComponent(".codex"))
            addIfExists(URL(fileURLWithPath: home).appendingPathComponent("Documents/Codex"))
        }
        for root in searchRoots() {
            for url in matchChildren(root: root, identities: identities, bundleId: app.bundleId) { addIfExists(url) }
        }
        if urls.count <= 1 && !urls.contains(where: { $0 != appURL }) {
            LogManager.shared.info("[WARNING] Uninstall scan found no items besides the app for app=\(app.name)")
        }

        var items = urls.map { makeItem($0, forcedCategory: nil) }
        items.sort { a, b in
            if (a.kind == .application) != (b.kind == .application) { return a.kind == .application }
            return a.displayPath.localizedStandardCompare(b.displayPath) == .orderedAscending
        }
        return items
    }

    // MARK: Tokens

    private func isValidToken(_ s: String) -> Bool { !s.isEmpty && s != "." && s != ".." && !s.contains("/") }

    /// `com.vendor.app.launcher` → `com.vendor.app` (needs ≥ 4 components and a "launcher" tail).
    private func launcherParent(_ bundleId: String) -> String? {
        let parts = bundleId.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts.last?.lowercased() == "launcher" else { return nil }
        return parts.dropLast().joined(separator: ".")
    }

    private func identityTokens(_ app: LaunchpadApp) -> Set<String> {
        let bundleId = app.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = bundleId.lowercased()
        if lowered == "com.apple.safari.webapp" { return [] }
        if lowered.hasPrefix("com.apple.safari.webapp.") { return isValidToken(bundleId) ? [bundleId] : [] }

        var candidates: [(String, Bool)] = []       // (value, isBundleLike source: 1, 2, 7, 8)
        candidates.append((bundleId, true))
        if let parent = launcherParent(bundleId) { candidates.append((parent, true)) }
        candidates.append((app.name, false))
        candidates.append((app.defaultName, false))
        candidates.append((app.alias.isEmpty ? app.name : app.alias, false))
        candidates.append((app.bundleName, false))
        candidates.append((app.url.deletingPathExtension().lastPathComponent, true))
        if let executable = executableName(app.url) { candidates.append((executable, true)) }

        var tokens = Set<String>()
        for (raw, bundleLike) in candidates {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2, isValidToken(value) else { continue }
            let lower = value.lowercased()
            guard !Self.stopList.contains(lower), !value.allSatisfy(\.isNumber) else { continue }
            if bundleLike && value.count < 4 && !value.contains(".") { continue }
            tokens.insert(lower)
        }
        return tokens
    }

    private func executableName(_ appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist), let executable = info["CFBundleExecutable"] as? String else { return nil }
        return URL(fileURLWithPath: executable).deletingPathExtension().lastPathComponent
    }

    // MARK: Search locations

    private func directCandidates(_ tokens: Set<String>) -> [URL] {
        var urls: [URL] = []
        for library in ["\(home)/Library", "/Library"] {
            for token in tokens {
                for sub in ["Application Support", "Caches", "Containers", "Group Containers", "HTTPStorages",
                            "Logs", "WebKit", "Application Scripts"] {
                    urls.append(URL(fileURLWithPath: "\(library)/\(sub)/\(token)"))
                }
                urls.append(URL(fileURLWithPath: "\(library)/Preferences/\(token).plist"))
                urls.append(URL(fileURLWithPath: "\(library)/Saved Application State/\(token).savedState"))
            }
        }
        return urls
    }

    private func searchRoots() -> [URL] {
        let user = ["Application Support", "Caches", "Containers", "Group Containers", "HTTPStorages", "Logs",
                    "Preferences", "Saved Application State", "WebKit", "Application Scripts", "LaunchAgents",
                    "Logs/DiagnosticReports", "Logs/CrashReporter"].map { "\(home)/Library/\($0)" }
        let system = ["Application Support", "Caches", "LaunchAgents", "LaunchDaemons", "Logs", "Preferences",
                      "Logs/DiagnosticReports", "Logs/CrashReporter"].map { "/Library/\($0)" }
        return (user + system).map { URL(fileURLWithPath: $0) }
    }

    // MARK: Matching

    private func looksLikeBundleId(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    private func isForeignBundleIdentifier(_ child: String, bundleId: String) -> Bool {
        guard looksLikeBundleId(child), !bundleId.isEmpty else { return false }
        let lowerChild = child.lowercased(), lowerBundle = bundleId.lowercased()
        if lowerChild == lowerBundle { return false }
        if let parent = launcherParent(bundleId) {
            for suffix in ["", ".plist", ".binarycookies", ".savedstate"] where child == parent + suffix { return false }
        }
        if lowerChild.hasPrefix(lowerBundle + ".") { return false }
        return true
    }

    private func groupContainerMatches(_ child: String, bundleId: String) -> Bool {
        let b = bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidToken(b), looksLikeBundleId(b), b != "com.apple.safari.webapp" else { return false }
        var remainder = child
        if let dot = remainder.firstIndex(of: ".") {
            let head = String(remainder[..<dot])
            let isTeamID = head.count == 10 && head.allSatisfy { ($0.isUppercase && $0.isLetter) || $0.isNumber }
            if isTeamID || head == "group" { remainder = String(remainder[remainder.index(after: dot)...]) }
        }
        let r = remainder.lowercased()
        return r == b || r.hasPrefix(b + ".") || r == launcherParent(b)
    }

    /// Whole-word, case-insensitive occurrence of `token` in `name` (neighbours must not be letters/digits).
    private func wholeWordMatch(_ name: String, _ token: String) -> Bool {
        let chars = Array(name), needle = Array(token)
        guard !needle.isEmpty, needle.count <= chars.count else { return false }
        for start in 0...(chars.count - needle.count) where Array(chars[start..<(start + needle.count)]) == needle {
            let before = start > 0 ? chars[start - 1] : nil
            let after = start + needle.count < chars.count ? chars[start + needle.count] : nil
            let beforeOK = before.map { !($0.isLetter || $0.isNumber) } ?? true
            let afterOK = after.map { !($0.isLetter || $0.isNumber) } ?? true
            if beforeOK && afterOK { return true }
        }
        return false
    }

    private func matchChildren(root: URL, identities: Set<String>, bundleId: String) -> [URL] {
        guard !identities.isEmpty, fm.fileExists(atPath: root.path) else { return [] }
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
                                                  options: .skipsHiddenFiles)
        } catch {
            LogManager.shared.info("[WARNING] Uninstall scan failed to read directory=\(root.path), error=\(error.localizedDescription)")
            return []
        }
        var matches: [URL] = []
        for child in children {
            let name = child.lastPathComponent
            if root.lastPathComponent == "Group Containers" {
                if groupContainerMatches(name, bundleId: bundleId) { matches.append(child) }
                continue
            }
            if name.lowercased().hasPrefix("com.apple.safari.webapp.") {
                let n = name.lowercased(), b = bundleId.lowercased()
                if n == b || n.hasPrefix(b + ".") { matches.append(child) }
                continue
            }
            if isForeignBundleIdentifier(name, bundleId: bundleId) { continue }
            let lowerName = name.lowercased()
            for token in identities where !token.isEmpty && token.count <= name.count {
                if wholeWordMatch(lowerName, token) { matches.append(child); break }
            }
        }
        return matches
    }

    private func bundlePrefixedTemp(_ bundleId: String) -> [URL] {
        guard looksLikeBundleId(bundleId), bundleId.lowercased() != "com.apple.safari.webapp" else { return [] }
        var tokens = [bundleId.lowercased()]
        if !bundleId.lowercased().hasPrefix("com.apple.safari.webapp."), let parent = launcherParent(bundleId) {
            tokens.append(parent.lowercased())
        }
        var urls: [URL] = []
        for directory in userCacheAndTemporaryDirectories {
            guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else { continue }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent.lowercased()
                if tokens.contains(where: { name == $0 || (name.hasPrefix($0 + ".") && name.count > $0.count + 1) }) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    // MARK: Items, categories, size

    private func makeItem(_ url: URL, forcedCategory: AppUninstallItem.Category?) -> AppUninstallItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isApplicationKey])
        let kind: AppUninstallItem.Kind = values?.isApplication == true ? .application
            : (values?.isDirectory == true ? .folder : .file)
        let path = url.path
        let display = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        return AppUninstallItem(url: url, name: fm.displayName(atPath: path), displayPath: String(display),
                                size: size(of: url), kind: kind,
                                category: forcedCategory ?? category(of: url, isApplication: kind == .application))
    }

    private func category(of url: URL, isApplication: Bool) -> AppUninstallItem.Category {
        if isApplication || url.pathExtension.lowercased() == "app" { return .application }
        let path = url.standardizedFileURL.path
        if userCacheAndTemporaryDirectories.contains(where: { path.hasPrefix($0.standardizedFileURL.path) }) { return .cache }
        if path.hasPrefix("\(home)/.codex") || path.hasPrefix("\(home)/Documents/Codex") { return .userFiles }

        let library = "\(home)/Library/"
        func inside(_ rel: String) -> Bool { path.hasPrefix(library + rel + "/") || path.hasPrefix("/Library/" + rel + "/") }
        if inside("Logs/DiagnosticReports") || inside("Logs/CrashReporter") { return .crashLog }
        if inside("Caches") { return .cache }
        if inside("Containers") { return .sandbox }
        if inside("Group Containers") { return .groupContainer }
        if inside("Application Support") { return .appSupport }
        if inside("HTTPStorages") { return .httpStorage }
        if inside("WebKit") { return .webKit }
        if inside("Application Scripts") { return .appScript }
        if inside("LaunchAgents") || path.hasPrefix("/Library/LaunchDaemons/") { return .launchAgent }
        if inside("Preferences") { return .preference }
        if inside("Saved Application State") { return .savedState }
        if inside("Logs") { return .log }
        return .unknown
    }

    private func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isAliasFileKey, .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey,
                                         .totalFileSizeKey, .fileSizeKey]
        func fileSize(_ values: URLResourceValues) -> Int64 { Int64(values.totalFileSize ?? values.fileSize ?? 0) }
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true || values.isAliasFile == true || values.isRegularFile == true { return fileSize(values) }
        guard values.isDirectory == true,
              let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: keys) else { continue }
            if childValues.isSymbolicLink == true { continue }
            if childValues.isRegularFile == true || childValues.isAliasFile == true { total &+= fileSize(childValues) }
        }
        return total
    }

    // MARK: Removal

    func remove(_ items: [AppUninstallItem], appName: String) -> [AppUninstallFailure] {
        var failures: [AppUninstallFailure] = []
        for item in items {
            guard fm.fileExists(atPath: item.url.path) else {
                LogManager.shared.info("Uninstall item already missing, treating as removed item=\(item.url.path)")
                continue
            }
            for attempt in 0..<5 {
                do {
                    try fm.trashItem(at: item.url, resultingItemURL: nil)
                    break
                } catch {
                    if isPermissionError(error) && adminTrashFallback(item.url, appName: appName) {
                        LogManager.shared.info("[INFO] Uninstall admin trash fallback succeeded for path=\(item.url.path)")
                        break
                    }
                    if !fm.fileExists(atPath: item.url.path) {
                        LogManager.shared.info("Uninstall source disappeared, treating as removed attempt=\(attempt + 1)")
                        break
                    }
                    if attempt == 4 || !isRetryable(error) {
                        LogManager.shared.error("Uninstall trash failed attempt=\(attempt + 1) category=\(item.category) kind=\(item.kind) path=\(item.url.path) error=\(error)")
                        failures.append(AppUninstallFailure(item: item, error: error))
                        break
                    }
                    Thread.sleep(forTimeInterval: min(0.1 * pow(2, Double(attempt)), 0.8))
                    if !fm.fileExists(atPath: item.url.path) { break }
                }
            }
        }
        return failures
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == 513 { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == 13 || ns.code == 1) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSPOSIXErrorDomain && (underlying.code == 13 || underlying.code == 1) { return true }
            if underlying.domain == NSOSStatusErrorDomain && underlying.code == -5000 { return true }
        }
        return false
    }

    private func isRetryable(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == 512 { return true }
        return ns.domain == NSPOSIXErrorDomain && [16, 35, 26].contains(ns.code)
    }

    /// The admin fallback only applies to `/Applications/*.app`.
    private func isAdminEligible(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/Applications/") && path.hasSuffix(".app")
            && path != "/Applications" && path != "/Applications/" && !path.hasPrefix("/System/")
    }

    private func adminTrashFallback(_ url: URL, appName: String) -> Bool {
        guard isAdminEligible(url), fm.fileExists(atPath: url.path) else { return false }
        let trash = URL(fileURLWithPath: home).appendingPathComponent(".Trash")
        let destination = freeName(in: trash, for: url.lastPathComponent)

        func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "mv \(shellQuoted(url.path)) \(shellQuoted(destination.path))"
        func appleScriptEscaped(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let prompt = String(format: NSLocalizedString("Gridura needs administrator permission to move %@ to the Trash.", comment: ""), appName)
        let source = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges with prompt \"\(appleScriptEscaped(prompt))\""
        guard let script = NSAppleScript(source: source) else {
            LogManager.shared.info("Uninstall failed to create script for path=\(url.path)")
            return false
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            LogManager.shared.info("Uninstall admin trash fallback failed for path=\(url.path), error=\(error)")
            return false
        }
        guard !fm.fileExists(atPath: url.path), fm.fileExists(atPath: destination.path) else {
            LogManager.shared.info("Uninstall admin trash fallback completed without expected move, source=\(url.path), destination=\(destination.path)")
            return false
        }
        return true
    }

    /// `<base> N<.ext>` when the name is taken (a space, then the number, before the extension).
    private func freeName(in directory: URL, for name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 1
        repeat {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
