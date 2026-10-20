import SwiftUI
import AppKit

/// A small app icon for SwiftUI lists.
struct AppIconThumbnailView: View {
    var app: LaunchpadApp
    var size: CGFloat = 20
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22).fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            AppIconRepository.shared.icon(for: app.url) { loaded in
                if let loaded { image = loaded } else { image = NSWorkspace.shared.icon(forFile: app.url.path) }
            }
        }
    }
}

/// Apps tab: app sources and hidden apps.
struct AppsTabView: View {
    @ObservedObject private var appState = AppState.shared

    @AppStorage("ShowHiddenAppsInSearch") private var showHiddenAppsInSearch = false

    @State private var directories: [AppDirectory] = []
    @State private var selectedDirectory: AppDirectory?
    @State private var hiddenApps: [LaunchpadApp] = []


    var body: some View {
        CustomForm {
            Section {
                directoriesBlock
            } header: {
                Text("App Sources")
            }

            Section {
                hiddenAppsBlock
            } header: {
                HStack(spacing: 2) {
                    Text("Hidden Apps")
                    Text(" (\(hiddenApps.count))")
                }
            }

            Section {
                Toggle("Show Hidden Apps in Search", isOn: $showHiddenAppsInSearch)
                    .controlSize(.mini)
                    .onChange(of: showHiddenAppsInSearch) { _, _ in
                        NotificationChannel.center.post(name: NotificationChannel.Name.preferencesChanged,
                                                        object: PreferenceModule.hiddenAppsSearch.rawValue)
                    }
            }
        }
        .frame(minHeight: 300)
        .frame(maxHeight: 540)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .refreshPreferencesDataPublic)) { _ in reload() }
    }

    // MARK: - Sources

    private var directoriesBlock: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selectedDirectory?.id }, set: { id in
                selectedDirectory = directories.first { $0.id == id }
            })) {
                ForEach(directories) { directory in
                    directoryRow(directory)
                        .padding(.vertical, 4)
                        .tag(directory.id)
                }
            }
            .scrollIndicators(.never)
            .frame(height: 150)

            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 4) {
                    Button {
                        addDirectory()
                    } label: {
                        Image(systemName: "plus").font(.body).frame(width: 20, height: 20)
                    }
                    .frame(width: 24, height: 20)
                    .buttonStyle(.plain)

                    Divider().frame(height: 16)

                    Button {
                        removeSelected()
                    } label: {
                        Image(systemName: "minus").font(.body).frame(width: 20, height: 20)
                    }
                    .frame(width: 24, height: 20)
                    .buttonStyle(.plain)
                    .disabled(selectedDirectory == nil || !(selectedDirectory?.isCustom ?? false))

                    Spacer()
                }
                .padding(6)
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func directoryRow(_ directory: AppDirectory) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { directory.enabled },
                set: { value in setEnabled(directory, value) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(directory))
                Text(directory.isCustom ? abbreviated(directory.path.expandedPath) : NSLocalizedString("Default path", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .background(selectedDirectory?.id == directory.id
                    ? Color(nsColor: .controlAccentColor).opacity(0.15)
                    : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture { selectedDirectory = directory }
    }

    private func displayName(_ directory: AppDirectory) -> String {
        let path = directory.path.expandedPath
        if path == "/Applications" { return "Applications" }
        if path == NSHomeDirectory() + "/Applications" { return "User Applications" }
        // The Cryptex path also contains "/System/Applications", so it must be tested first.
        if path.contains("Cryptexes") { return "System Applications (Cryptex)" }
        if path.contains("/System/Applications") { return "System Applications" }
        return (path as NSString).lastPathComponent
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Hidden apps

    @ViewBuilder
    private var hiddenAppsBlock: some View {
        if hiddenApps.isEmpty {
            VStack {
                Text("No Apps")
                Text("Right-click an app to hide it")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
        } else {
            ForEach(hiddenApps, id: \.id) { app in
                LabeledContent {
                    Button {
                        unhide(app)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor), Color(nsColor: .quaternaryLabelColor))
                    }
                    .buttonStyle(.plain)
                } label: {
                    HStack(spacing: 8) {
                        AppIconThumbnailView(app: app, size: 20).frame(width: 20, height: 20)
                        Text(app.name)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        directories = ApplicationManager.shared.directories()
        hiddenApps = LaunchpadDataManager.shared.hiddenApps()
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Please select a folder containing applications", comment: "")
        panel.prompt = NSLocalizedString("Add", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if ApplicationManager.shared.addDirectory(url) {
            NotificationChannel.center.post(name: NotificationChannel.Name.scanApp, object: nil)
            reload()
        } else {
            NSSound.beep()
        }
    }

    private func removeSelected() {
        guard let directory = selectedDirectory, directory.isCustom else { return }
        ApplicationManager.shared.removeDirectory(id: directory.id)
        selectedDirectory = nil
        NotificationChannel.center.post(name: NotificationChannel.Name.scanApp, object: nil)
        reload()
    }

    private func setEnabled(_ directory: AppDirectory, _ enabled: Bool) {
        if directory.isCustom {
            ApplicationManager.shared.setDirectoryEnabled(id: directory.id, enabled: enabled)
        } else {
            ApplicationManager.shared.setDefaultDirectory(path: directory.path, enabled: enabled)
        }
        reload()
        NotificationChannel.center.post(name: NotificationChannel.Name.scanApp, object: nil)
    }

    private func unhide(_ app: LaunchpadApp) {
        withAnimation(.easeOut) {
            hiddenApps.removeAll { $0.id == app.id }
        }
        LaunchpadDataManager.shared.unhide(app)
    }
}
