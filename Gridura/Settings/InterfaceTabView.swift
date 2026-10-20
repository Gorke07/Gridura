import SwiftUI

/// Interface tab.
struct InterfaceTabView: View {
    @ObservedObject private var appState = AppState.shared

    @AppStorage("DisplayMode") private var displayMode: DisplayModeType = .fullScreen
    @AppStorage("IsFullScreen") private var hideDock = false
    @AppStorage("columns") private var columns = 7
    @AppStorage("rows") private var rows = 5
    @AppStorage("ViewMode") private var browsingStyle: BrowsingStyleType = .paged
    @AppStorage("SortBy") private var sortBy: SortByType = .custom
    @AppStorage("SortOrder") private var sortOrder: SortOrderType = .ascending
    @AppStorage("HideNames") private var hideNames = false
    @AppStorage("BackgroundType") private var backgroundType: BackgroundType = .wallpaper
    @AppStorage("WallpaperBlurRadius") private var wallpaperBlurRadius = 30
    @AppStorage("GlassMaterial") private var glassMaterial: GlassMaterialType = .ultraThin

    @State private var glassLevel: Double = 0


    var body: some View {
        CustomForm {
            Section {
                LabeledContent {
                    HStack(spacing: 12) {
                        displayModeOption(.fullScreen)
                        displayModeOption(.window)
                    }
                } label: {
                    SettingsLabel(title: "Display Mode")
                }

                if displayMode == .fullScreen {
                    Toggle("Hide Dock", isOn: $hideDock)
                        .controlSize(.mini)
                        .onChange(of: hideDock) { _, _ in
                            LaunchpadWindowController.shared.updateLevel()
                            post(.layout)
                        }
                }
            }

            Section("Layout") {
                LabeledContent {
                    HStack(spacing: 8) {
                        stepperBox($columns)
                        Image(systemName: "xmark").bold().foregroundStyle(.tertiary)
                        stepperBox($rows)
                    }
                } label: {
                    SettingsLabel(title: "Icon Grid")
                }

                Picker(selection: $browsingStyle) {
                    Text("Paged").tag(BrowsingStyleType.paged)
                    Text("Scroll").tag(BrowsingStyleType.scroll)
                } label: {
                    SettingsLabel(title: "Browsing Style")
                }
                .pickerStyle(.radioGroup)
                .onChange(of: browsingStyle) { _, _ in post(.browsingStyle) }

                Picker(selection: $sortBy) {
                    ForEach(SortByType.allCases, id: \.rawValue) { option in
                        Text(sortByName(option)).tag(option)
                    }
                } label: {
                    SettingsLabel(title: "Sort By",
                                  info: "Dragging to reorder is only available in Custom sort mode.")
                }
                .pickerStyle(.menu)
                .onChange(of: sortBy) { _, _ in post(.sortBy, delay: 0.1) }

                if sortBy != .custom {
                    Picker(selection: $sortOrder) {
                        Text(orderName(ascending: true)).tag(SortOrderType.ascending)
                        Text(orderName(ascending: false)).tag(SortOrderType.descending)
                    } label: {
                        SettingsLabel(title: "Order")
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: sortOrder) { _, _ in post(.sortOrder, delay: 0.05) }
                }

                Toggle(isOn: $hideNames) {
                    HStack(spacing: 4) { Text("Hide Names") }
                }
                .toggleStyle(.switch)
                .onChange(of: hideNames) { _, _ in post(.interface) }
            }

            if browsingStyle == .paged {
                Section {
                    LabeledContent {
                        Button("Reorganize") { post(.rearrange) }
                    } label: {
                        SettingsLabel(title: "Fill Empty Slots",
                                      subtitle: "Moves apps forward to fill empty slots based on the current row and column layout.")
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if displayMode == .fullScreen {
                Section("Background") {
                    Picker("Type", selection: $backgroundType) {
                        Text("System Wallpaper").tag(BackgroundType.wallpaper)
                        Text("Glass Effect").tag(BackgroundType.glassEffect)
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: backgroundType) { _, _ in post(.background) }

                    if backgroundType == .wallpaper {
                        LabeledContent("Blur Wallpaper") {
                            Slider(value: Binding(
                                get: { Double(wallpaperBlurRadius) },
                                set: { wallpaperBlurRadius = Int($0) }
                            ), in: 0...40, step: 10)
                        }
                        .onChange(of: wallpaperBlurRadius) { _, value in
                            appState.isBlurWallpaper = value > 0
                            post(.background)
                        }
                    } else {
                        LabeledContent("Glass Material") {
                            Slider(value: $glassLevel, in: 0...4, step: 1)
                        }
                        .onChange(of: glassLevel) { _, value in
                            appState.glassMaterial = GlassMaterialType(rawValue: Int(value)) ?? .regular
                            post(.background)
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 1, blendDuration: 0), value: browsingStyle)
        .frame(maxHeight: 540)
        .onAppear { glassLevel = Double(appState.glassMaterial.rawValue) }
    }

    private func displayModeOption(_ mode: DisplayModeType) -> some View {
        Button {
            displayMode = mode
            LaunchpadWindowController.shared.applyDisplayMode()
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let image = NSImage(named: mode == .fullScreen ? "DisplayMode/FullScreen" : "DisplayMode/Window") {
                        Image(nsImage: image).interpolation(.high).resizable()
                    } else {
                        RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    }
                }
                .frame(width: 72, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 2)
                        .opacity(displayMode == mode ? 1 : 0)
                )
                Text(mode == .fullScreen ? "Full Screen" : "Window")
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private func stepperBox(_ value: Binding<Int>) -> some View {
        HStack {
            Text(value.wrappedValue, format: .number)
                .frame(width: 32)
            Stepper("", value: value, in: 4...15, step: 1)
                .labelsHidden()
                .controlSize(.small)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.8)
        )
        .onChange(of: value.wrappedValue) { _, _ in post(.layout) }
    }

    private func sortByName(_ sort: SortByType) -> String {
        switch sort {
        case .custom: return NSLocalizedString("Custom", comment: "")
        case .name: return NSLocalizedString("Name", comment: "")
        case .added: return NSLocalizedString("Date Added", comment: "")
        case .opened: return NSLocalizedString("Date Last Opened", comment: "")
        }
    }

    private func orderName(ascending: Bool) -> String {
        switch sortBy {
        case .name:
            return ascending ? NSLocalizedString("Ascending", comment: "") : NSLocalizedString("Descending", comment: "")
        case .added:
            return ascending ? NSLocalizedString("Oldest First", comment: "") : NSLocalizedString("Newest First", comment: "")
        case .opened:
            return ascending ? NSLocalizedString("Least Recent", comment: "") : NSLocalizedString("Most Recent", comment: "")
        case .custom:
            return ascending ? NSLocalizedString("Ascending", comment: "") : NSLocalizedString("Descending", comment: "")
        }
    }

    private func post(_ module: PreferenceModule, delay: TimeInterval = 0) {
        let body = { NotificationChannel.center.post(name: NotificationChannel.Name.preferencesChanged, object: module.rawValue) }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body) } else { body() }
    }
}
