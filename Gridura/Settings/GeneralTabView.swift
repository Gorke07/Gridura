import SwiftUI
import AppKit

/// General tab.
struct GeneralTabView: View {
    @ObservedObject private var appState = AppState.shared

    @AppStorage("EnableF4Shortcut") private var enableF4Shortcut = false
    @AppStorage("TrackpadGesture") private var trackpadGesture: TrackpadType = .four
    @AppStorage("HotCorner") private var hotCorner: HotCornerType = .off
    @AppStorage("ShowMenubarIcon") private var showMenubarIcon = true
    @AppStorage("AppIcon") private var appIcon: AppIconType = .gridura

    @State private var startAtLogin = LaunchAtLogin.isEnabled
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    @State private var hasDockIcon = DockHelper.isInDock(Bundle.main.bundleURL)
    @State private var addDockLoading = false
    @State private var iconSuffix = IconAppearanceSuffix.current()
    @State private var newVersion: String? = UpdateManager.shared.availableVersion ?? UpdateManager.shared.downloadedVersion


    var body: some View {
        VStack(alignment: .center) {
            CustomForm {
                Section("Launch") {
                    Toggle("Start at Login", isOn: $startAtLogin)
                        .controlSize(.mini)
                        .onChange(of: startAtLogin) { _, value in LaunchAtLogin.setEnabled(value) }
                }

                Section {
                    LabeledContent {
                        ShortcutRecorderView()
                    } label: {
                        Text("Hotkey")
                    }

                    LabeledContent {
                        f4Content
                    } label: {
                        SettingsLabel(title: "System F4 Key")
                    }

                    LabeledContent {
                        trackpadContent
                    } label: {
                        SettingsLabel(title: "Trackpad")
                    }

                    LabeledContent {
                        hotCornerContent
                    } label: {
                        hotCornerLabel
                    }

                    LabeledContent {
                        Button { } label: {
                            Text("Hold \(Image(systemName: "command")) + Click or Drag")
                        }
                        .buttonStyle(.plain)
                    } label: {
                        SettingsLabel(title: "Multi-Select")
                    }
                }

                Section("Appearance") {
                    Toggle("Show Menu Bar Icon", isOn: $showMenubarIcon)
                        .controlSize(.mini)
                        .onChange(of: showMenubarIcon) { _, _ in MenuBarManager.shared.updateStatusItem() }
                }

                Section {
                    if !hasDockIcon {
                        LabeledContent {
                            Button(action: addToDock) {
                                if addDockLoading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Add to Dock")
                                }
                            }
                            .disabled(addDockLoading)
                        } label: {
                            SettingsLabel(title: "Show Dock Icon",
                                          subtitle: "Keep Gridura in the Dock for quick access")
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    LabeledContent {
                        HStack(spacing: 16) {
                            ForEach(AppIconType.allCases, id: \.rawValue) { type in
                                iconCell(type)
                            }
                        }
                    } label: {
                        SettingsLabel(title: "App Icon",
                                      info: "If the icon doesn’t update, remove the app from the Dock and add it again.")
                    }
                }
            }
            if let version = newVersion {
                Divider()
                newVersionBar(version)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 1.0, blendDuration: 0), value: hasDockIcon)
        .frame(maxHeight: 540)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .refreshPreferencesDataPublic)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UpdateManager.stateDidChange)) { _ in
            newVersion = UpdateManager.shared.availableVersion ?? UpdateManager.shared.downloadedVersion
        }
        .onReceive(NotificationChannel.center.publisher(for: NotificationChannel.Name.refreshPreferencesData)) { _ in refresh() }
    }

    // MARK: - Rows

    @ViewBuilder
    private var f4Content: some View {
        if accessibilityGranted {
            Toggle("", isOn: $enableF4Shortcut)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: enableF4Shortcut) { _, _ in
                    LogManager.shared.info("F4 setting changed")
                    InputEventMonitor.shared.start(reason: "F4 setting changed")
                }
        } else {
            Button("Grant Access") {
                AccessibilityPermission.request(hideLauncherIfDenied: true)
                refresh()
            }
        }
    }

    @ViewBuilder
    private var trackpadContent: some View {
        if accessibilityGranted {
            Menu {
                ForEach(TrackpadType.allCases, id: \.rawValue) { option in
                    Button {
                        trackpadGesture = option
                        LogManager.shared.info("trackpad setting changed")
                    } label: {
                        HStack {
                            Text(trackpadName(option))
                            if option == .four {
                                Text("System default").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if option == .off { Divider() }
                }
            } label: {
                Text(trackpadName(trackpadGesture))
            }
            .menuStyle(.button)
            .fixedSize()
        } else {
            Button("Grant Access") {
                AccessibilityPermission.request(hideLauncherIfDenied: true)
                refresh()
            }
        }
    }

    @ViewBuilder
    private var hotCornerContent: some View {
        Picker(selection: $hotCorner) {
            ForEach(HotCornerType.allCases, id: \.rawValue) { corner in
                Text(hotCornerName(corner)).tag(corner)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .onChange(of: hotCorner) { _, _ in
            LaunchpadManager.shared.hotCornerSettingChanged()
            NotificationChannel.center.post(name: NotificationChannel.Name.preferencesChanged,
                                            object: PreferenceModule.dockStyle.rawValue)
        }
    }

    private var hotCornerLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Hot Corner")
            if HotCornerConflict.conflicts(corner: hotCorner) {
                Text("Conflicts with system Hot Corner")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func iconCell(_ type: AppIconType) -> some View {
        VStack(spacing: 6) {
            if let image = NSImage(named: "AppIcon/\(baseName(type))-\(iconSuffix)") {
                Image(nsImage: image)
                    .interpolation(.high)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 32, height: 32)
            }
            Circle()
                .fill(.tint)
                .frame(width: 4, height: 4)
                .opacity(appIcon == type ? 1 : 0)
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { setIcon(type) }
        }
    }

    /// "New Version x" with a red dot — a click starts the update flow.
    private func newVersionBar(_ version: String) -> some View {
        HStack(spacing: 8) {
            Button { UpdateManager.shared.checkForUpdates() } label: {
                HStack {
                    ZStack {
                        Circle().fill(Color(red: 1, green: 0.231, blue: 0.188).opacity(0.2)).frame(width: 12, height: 12)
                        Circle().fill(.red).frame(width: 6, height: 6)
                    }
                    Text("New Version \(version)")
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func refresh() {
        iconSuffix = IconAppearanceSuffix.current()
        accessibilityGranted = AccessibilityPermission.isGranted
        hasDockIcon = DockHelper.isInDock(Bundle.main.bundleURL)
        startAtLogin = LaunchAtLogin.isEnabled
    }

    private func addToDock() {
        addDockLoading = true
        DockHelper.addToDock(Bundle.main.bundleURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            hasDockIcon = DockHelper.isInDock(Bundle.main.bundleURL)
            addDockLoading = false
        }
    }

    private func setIcon(_ type: AppIconType) {
        appIcon = type
        DistributedNotificationCenter.default().postNotificationName(NotificationChannel.appIconChangedDistributedName,
                                                                    object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func baseName(_ type: AppIconType) -> String { type.assetBase }

    private func trackpadName(_ type: TrackpadType) -> String {
        switch type {
        case .off: return NSLocalizedString("Off", comment: "")
        case .three: return NSLocalizedString("Pinch with 3 fingers", comment: "")
        case .four: return NSLocalizedString("Pinch with 4 or 5 fingers", comment: "")
        case .five: return NSLocalizedString("Pinch with 5 fingers", comment: "")
        }
    }

    private func hotCornerName(_ corner: HotCornerType) -> String {
        switch corner {
        case .topLeft: return NSLocalizedString("Top Left", comment: "")
        case .topRight: return NSLocalizedString("Top Right", comment: "")
        case .bottomLeft: return NSLocalizedString("Bottom Left", comment: "")
        case .bottomRight: return NSLocalizedString("Bottom Right", comment: "")
        case .off: return NSLocalizedString("Off", comment: "")
        }
    }
}

/// Hot-key recorder. The shipped app uses `KeyboardShortcuts.Recorder(for: .launchApp)`; the
/// rebuild stores the same `⌥Space` default and hands the raw combination to `HotKeyCenter`.
