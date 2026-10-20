import SwiftUI
import AppKit

/// Advanced tab: behaviour, layout maintenance, updates and diagnostics.
struct AdvancedTabView: View {
    @ObservedObject private var appState = AppState.shared

    @AppStorage("LaunchShowOn") private var showOn: ShowOnType = .primary
    @AppStorage("ReturnToHome") private var returnToHome: ReturnToHomeType = .after5Min
    @AppStorage("EnableOptionUninstallMode") private var enableOptionUninstallMode = true

    @State private var systemImportAlert = false
    @State private var reorganizeLayoutSheet = false
    @State private var autoDownloadPopover = false

    @State private var autoCheck = UpdateManager.shared.automaticallyChecksForUpdates
    @State private var autoDownload = UpdateManager.shared.automaticallyDownloadsUpdates

    @State private var isLogExporting = false
    @State private var logExportMessage = ""
    @State private var showLogAlert = false
    @State private var logAlertTitle = "Error"

    @State private var launchShortcut: LaunchShortcut? = LaunchShortcut.current()
    @State private var backupData: BackupManager.Container?


    private var hotkeyConflict: Bool {
        enableOptionUninstallMode && (launchShortcut?.containsOption ?? false)
    }

    var body: some View {
        VStack {
            CustomForm {
                Section("Behavior") {
                    Picker(selection: $showOn) {
                        ForEach(ShowOnType.allCases, id: \.rawValue) { option in
                            Text(showOnName(option)).tag(option)
                        }
                    } label: {
                        Text("Show Gridura on")
                    }
                    .pickerStyle(.menu)

                    Picker(selection: $returnToHome) {
                        ForEach(ReturnToHomeType.allCases, id: \.rawValue) { option in
                            Text(returnToHomeName(option)).tag(option)
                        }
                    } label: {
                        SettingsLabel(title: "Return To Main Page",
                                      subtitle: "Return to the first page or resume where you left off when reopening Gridura")
                    }
                    .pickerStyle(.menu)

                    Toggle(isOn: $enableOptionUninstallMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hold Option for Uninstall")
                            if hotkeyConflict {
                                Text(String(format: NSLocalizedString("May conflict with the hotkey(%@)", comment: ""), launchShortcut?.description ?? ""))
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .controlSize(.mini)
                }

                Section("Layout") {
                    LabeledContent {
                        Button("Restore") { systemImportAlert = true }
                    } label: {
                        SettingsLabel(title: "System Launchpad Data",
                                      subtitle: "Restore the system launchpad layout data")
                    }

                    LabeledContent {
                        HStack(spacing: 8) {
                            Button("Import") {
                                backupData = BackupManager.shared.pickBackup()
                            }
                            Button("Export") {
                                BackupManager.shared.presentExportFlow()
                            }
                        }
                    } label: {
                        SettingsLabel(title: "Layout Data Backup",
                                      subtitle: "Import or export your Gridura layout to back up, restore, or transfer it between devices")
                    }

                    Button {
                        reorganizeLayoutSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reorganize Layout")
                                Text("Reorganize layout based on selected rules")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Section("Update") {
                    LabeledContent {
                        Toggle("", isOn: Binding(
                            get: { autoCheck },
                            set: { value in
                                autoCheck = value
                                UpdateManager.shared.automaticallyChecksForUpdates = value
                            }
                        ))
                        .controlSize(.mini)
                        .labelsHidden()
                    } label: {
                        Text("Auto Check for Updates")
                    }

                    LabeledContent {
                        Toggle("", isOn: Binding(
                            get: { autoDownload },
                            set: { value in
                                autoDownload = value
                                UpdateManager.shared.automaticallyDownloadsUpdates = value
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(!autoCheck)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Auto Download Updates")
                            Button {
                                autoDownloadPopover.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .popover(isPresented: $autoDownloadPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                                Text("Downloaded updates will be installed when you quit Gridura. Choose “Install” from the right-click menu to install immediately.")
                                    .padding()
                            }
                        }
                    }
                }

                Section("Diagnostics") {
                    LabeledContent("Logs") {
                        Button {
                            exportLogs()
                        } label: {
                            HStack(spacing: 6) {
                                if isLogExporting { ProgressView().controlSize(.small) }
                                Text(isLogExporting ? "Exporting…" : "Export")
                            }
                        }
                        .disabled(isLogExporting)
                    }
                }
            }
        }
        .frame(maxHeight: 540)
        .sheet(isPresented: Binding(get: { backupData != nil }, set: { if !$0 { backupData = nil } })) {
            if let backup = backupData { replaceSheet(backup) }
        }
        .onAppear { launchShortcut = LaunchShortcut.current() }
        .onReceive(NotificationCenter.default.publisher(for: HotKeyCenter.registrationStateDidChange)) { _ in
            launchShortcut = LaunchShortcut.current()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshPreferencesDataPublic)) { _ in
            autoCheck = UpdateManager.shared.automaticallyChecksForUpdates
            autoDownload = UpdateManager.shared.automaticallyDownloadsUpdates
        }
        .alert("Confirm Import?", isPresented: $systemImportAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Continue", role: .confirm) { importSystem() }
        } message: {
            Text("The current app layout and folders will be overwritten.\nThis action cannot be undone.\nDo you want to continue?")
        }
        .alert(logAlertTitle, isPresented: $showLogAlert) {
            Button("Done", role: .cancel) { }
        } message: {
            Text(logExportMessage)
        }
        .sheet(isPresented: $reorganizeLayoutSheet) {
            ReorganizeLayoutSheet(onDismiss: { reorganizeLayoutSheet = false })
        }
    }

    // MARK: - Actions

    private func importSystem() {
        do {
            let result = try NativeDataManager.shared.importLayout()
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Restore Success", comment: "")
            alert.informativeText = String(format: NSLocalizedString("Successfully imported %1$d apps, %2$d folders and %3$d pages", comment: ""),
                                           result.apps, result.folders, result.pages)
            alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Restore Failed", comment: "")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
            alert.runModal()
        }
    }

    private func exportLogs() {
        isLogExporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error>
            do { result = .success(try LogManager.shared.export()) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                isLogExporting = false
                switch result {
                case .success(let url):
                    logAlertTitle = "Success"
                    logExportMessage = NSLocalizedString("Success: ", comment: "") + url.lastPathComponent
                case .failure(let error):
                    logAlertTitle = "Error"
                    logExportMessage = error.localizedDescription
                }
                showLogAlert = true
            }
        }
    }

    // MARK: - Names

    private func showOnName(_ type: ShowOnType) -> String {
        switch type {
        case .primary: return NSLocalizedString("Main Screen", comment: "")
        case .active: return NSLocalizedString("Active Screen", comment: "")
        case .cursor: return NSLocalizedString("Cursor Screen", comment: "")
        case .dock: return NSLocalizedString("Dock Screen", comment: "")
        }
    }

    private func returnToHomeName(_ type: ReturnToHomeType) -> String {
        switch type {
        case .always: return NSLocalizedString("Always", comment: "")
        case .never: return NSLocalizedString("Never", comment: "")
        case .after5Sec: return NSLocalizedString("After 5 seconds", comment: "")
        case .after15Sec: return NSLocalizedString("After 15 seconds", comment: "")
        case .after30Sec: return NSLocalizedString("After 30 seconds", comment: "")
        case .after1Min: return NSLocalizedString("After 1 minute", comment: "")
        case .after5Min: return NSLocalizedString("After 5 minutes", comment: "")
        }
    }

    // MARK: Replace sheet

    private func replaceSheet(_ backup: BackupManager.Container) -> some View {
        let payload = backup.data
        let style = BrowsingStyleType(rawValue: payload.setting.browsingStyle) == .scroll
            ? NSLocalizedString("Scroll", comment: "") : NSLocalizedString("Paged", comment: "")
        return VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replace Current Layout?").font(.body.bold())
                    Text("The current app layout and folders will be overwritten.\nThis action cannot be undone.\nDo you want to continue?")
                        .font(.subheadline)
                }
                VStack(alignment: .leading) {
                    stat("Icon Grid", "\(payload.setting.columns) x \(payload.setting.rows)")
                    stat("Browsing Style", style)
                    stat("Apps", payload.apps.count.formatted())
                    stat("Folders", payload.groups.filter(\.isFolder).count.formatted())
                    stat("App Sources", payload.sources.count.formatted())
                    stat("Hidden Apps", payload.apps.filter(\.hidden).count.formatted())
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack(spacing: 10) {
                Text(backup.metadata.exportDate.formatted()).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { backupData = nil }.keyboardShortcut(.cancelAction)
                Button("Replace") {
                    backupData = nil
                    DispatchQueue.main.async { BackupManager.shared.applyRestore(backup) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(width: 360)
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
            Divider()
        }
        .padding(.top, 5)
        .padding(.bottom, 3)
    }
}
