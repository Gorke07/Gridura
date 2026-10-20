import AppKit
import SwiftUI

/// Onboarding window: a borderless, transparent 540×680 window hosting a 440×580 card
///.
final class GuideWindowController: NSWindowController, NSWindowDelegate {
    static let shared = GuideWindowController()

    private convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 680),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: GuideView())
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
    }

    func show() {
        guard let window else { return }
        window.center()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    override func close() {
        window?.close()
    }
}

/// The onboarding guide's four pages.
struct GuideView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appState = AppState.shared

    @State private var index: Int

    init(startIndex: Int = 0) { _index = State(initialValue: startIndex) }
    @State private var startOnLogin = false
    @State private var importData = true
    @State private var loading = false
    @State private var hasDockIcon = DockHelper.isInDock(Bundle.main.bundleURL)
    @State private var addDockLoading = false
    @State private var accessibilityGranted = AccessibilityPermission.isGranted

    private var appDisplayName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Gridura"
    }

    private var pageCount: Int { 4 }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let background = NSImage(named: "GuideBg") {
                    Image(nsImage: background).resizable()
                } else {
                    LinearGradient(colors: [Color(hex: "1E1B4B"), Color(hex: "4C1D95")],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .opacity(colorScheme == .dark ? 0.4 : 0.6)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(8)

            VStack(alignment: .leading) {
                pagesStrip
                Spacer(minLength: 0)
                bottomBar
            }

            TitleBar(title: "", showMini: false, onClose: { GuideWindowController.shared.close() })
                .padding(.top, 10)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 440, height: 580)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.16), lineWidth: 1)
                )
        }
        .shadow(color: .black.opacity(0.32), radius: 24, x: 0, y: 10)
        .shadow(color: .black.opacity(0.16), radius: 0)
        .padding(50)
        .onAppear {
            startOnLogin = LaunchAtLogin.isEnabled
            hasDockIcon = DockHelper.isInDock(Bundle.main.bundleURL)
            accessibilityGranted = AccessibilityPermission.isGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AccessibilityPermission.isGranted
        }
    }

    // MARK: - Pages strip

    private var pagesStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            welcomePage.frame(width: 440)
            workflowPage.frame(width: 440)
            displayModePage.frame(width: 440)
            finishPage.frame(width: 440)
        }
        .frame(width: 440, height: 520, alignment: .leading)
        .offset(x: -440 * CGFloat(index))
        .animation(.spring(response: 0.8, dampingFraction: 1, blendDuration: 0), value: index)
        .frame(width: 440, alignment: .leading)
        .clipped()
    }

    // MARK: - Page 0

    private var welcomePage: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .center) {
                Group {
                    if let logo = NSImage(named: "Logo") {
                        Image(nsImage: logo).resizable().interpolation(.high).antialiased(true)
                    } else {
                        Image(systemName: "rocket.fill").resizable().scaledToFit().padding(24).foregroundStyle(.tint)
                    }
                }
                .frame(width: 120, height: 120)
                .padding(.top, 100)
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 124)

            VStack(alignment: .leading, spacing: 16) {
                Text("Welcome to \(appDisplayName)")
                    .font(.largeTitle)
                    .fontWeight(.regular)
                    .foregroundStyle(.primary)
                Text("Bring back the Launchpad you know, bring back your workflow")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            Spacer(minLength: 0)
        }
        .opacity(index == 0 ? 1 : 0)
        .animation(.spring(response: 0.8, dampingFraction: 1, blendDuration: 0).delay(0.2), value: index)
    }

    // MARK: - Page 1

    private var workflowPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Keep Your Workflow").font(.title)
                Text("Bring back the familiar Launchpad experience")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            .padding(.top, 72)

            Form {
                Section {
                    LabeledContent {
                        if hasDockIcon {
                            Image(systemName: "checkmark")
                        } else {
                            Button {
                                addToDock()
                            } label: {
                                if addDockLoading { ProgressView().controlSize(.small) } else { Text("Add to Dock") }
                            }
                        }
                    } label: {
                        Text("Keep Gridura in Your Dock")
                    }
                }
                Section {
                    LabeledContent {
                        accessRow { Toggle("", isOn: Binding(
                            get: { AppState.shared.enableF4Shortcut },
                            set: {
                                AppState.shared.enableF4Shortcut = $0
                                LogManager.shared.info("guide F4 setting changed")
                                InputEventMonitor.shared.updateMonitoring(force: false, reason: "guide F4 setting changed")
                            })).labelsHidden() }
                    } label: {
                        Text("System F4 Key")
                    }

                    LabeledContent {
                        accessRow {
                            Menu {
                                ForEach(TrackpadType.allCases, id: \.rawValue) { option in
                                    Button {
                                        AppState.shared.trackpadGesture = option
                                        LogManager.shared.info("guide trackpad setting changed")
                                        InputEventMonitor.shared.updateMonitoring(force: false, reason: "guide trackpad setting changed")
                                    } label: {
                                        HStack {
                                            Text(guideTrackpadName(option))
                                            if option == .four { Text("System default").foregroundStyle(.secondary) }
                                        }
                                    }
                                    if option == .off { Divider() }
                                }
                            } label: {
                                Text(guideTrackpadName(appState.trackpadGesture))
                            }
                            .menuStyle(.button)
                            .fixedSize()
                        }
                    } label: {
                        Text("Trackpad")
                    }

                    LabeledContent {
                        Picker("", selection: Binding(
                            get: { AppState.shared.hotCorner },
                            set: {
                                AppState.shared.hotCorner = $0
                                LaunchpadManager.shared.hotCornerSettingChanged()
                            })) {
                            ForEach(HotCornerType.allCases, id: \.rawValue) { corner in
                                Text(guideHotCornerName(corner)).tag(corner)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hot Corner")
                            if HotCornerConflict.conflicts(corner: appState.hotCorner) {
                                Text("Conflicts with system Hot Corner").font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .padding(.top, 36)
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .opacity(index == 1 ? 1 : 0)
        .animation(.spring(response: 0.8, dampingFraction: 1, blendDuration: 0).delay(0.3), value: index)
    }

    @ViewBuilder
    private func accessRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if accessibilityGranted {
            content()
        } else {
            Button("Grant Access") {
                AccessibilityPermission.request()
                accessibilityGranted = AccessibilityPermission.isGranted
                LogManager.shared.info("guide accessibility permission refreshed")
            }
        }
    }

    private func guideTrackpadName(_ type: TrackpadType) -> String {
        switch type {
        case .off: return NSLocalizedString("Off", comment: "")
        case .three: return NSLocalizedString("Pinch with 3 fingers", comment: "")
        case .four: return NSLocalizedString("Pinch with 4 or 5 fingers", comment: "")
        case .five: return NSLocalizedString("Pinch with 5 fingers", comment: "")
        }
    }

    private func guideHotCornerName(_ corner: HotCornerType) -> String {
        switch corner {
        case .topLeft: return NSLocalizedString("Top Left", comment: "")
        case .topRight: return NSLocalizedString("Top Right", comment: "")
        case .bottomLeft: return NSLocalizedString("Bottom Left", comment: "")
        case .bottomRight: return NSLocalizedString("Bottom Right", comment: "")
        case .off: return NSLocalizedString("Off", comment: "")
        }
    }

    // MARK: - Page 2

    private var displayModePage: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose Your Display Mode").font(.title)
                Text("Choose how Gridura appears when you open it")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            .padding(.top, 72)

            VStack(alignment: .center, spacing: 24) {
                HStack(spacing: 24) {
                    ForEach(DisplayModeType.allCases, id: \.rawValue) { mode in
                        displayModeOption(mode)
                    }
                }
                Text(appState.displayMode == .fullScreen
                     ? NSLocalizedString("The classic full-screen Launchpad experience", comment: "")
                     : NSLocalizedString("A modern windowed experience with custom sorting and folders", comment: ""))
                    .frame(height: 30, alignment: .top)
            }
            .padding(.top, 36)
            .padding(.horizontal, 50)

            Form {
                Section {
                    Toggle("Start at Login", isOn: $startOnLogin)
                    Toggle("Import System Launchpad Data", isOn: $importData)
                }
            }
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .padding(.top, 28)
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .opacity(index == 2 ? 1 : 0)
        .animation(.spring(response: 0.8, dampingFraction: 1, blendDuration: 0).delay(0.3), value: index)
    }

    private func displayModeOption(_ mode: DisplayModeType) -> some View {
        Button {
            appState.displayMode = mode
            LaunchpadWindowController.shared.applyDisplayMode()
        } label: {
            VStack(spacing: 9) {
                Group {
                    if let image = NSImage(named: mode == .fullScreen ? "DisplayMode/FullScreen" : "DisplayMode/Window") {
                        Image(nsImage: image).interpolation(.high).resizable()
                    } else {
                        RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    }
                }
                .frame(width: 108, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 2)
                        .opacity(appState.displayMode == mode ? 1 : 0)
                )
                Text(mode == .fullScreen ? "Full Screen" : "Window")
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Page 3

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .center, spacing: 10) {
                Group {
                    if let confetti = NSImage(named: "Confetti") {
                        Image(nsImage: confetti).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "party.popper.fill").resizable().scaledToFit().padding(24).foregroundStyle(.tint)
                    }
                }
                .frame(width: 144, height: 144)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity)

                Text("You're all set!").font(.title)
                Text("Right where your workflow belongs")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)

            VStack(alignment: .leading, spacing: 16) {
                Text("Tip:")
                VStack(alignment: .leading, spacing: 8) {
                    Text("· Click the \(Image(systemName: "ellipsis.circle")) button on the right side of the search bar, or right-click any empty area to open the main menu.")
                    Text("· Hold down the \(Image(systemName: "command")) key to select multiple items.")
                }
            }
            .foregroundStyle(.secondary)
            .padding(16)
            .background(Color(nsColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .secondarySystemFill), lineWidth: 0.5)
            )
            .padding(.top, 16)
            .padding(.horizontal, 40)

            Spacer(minLength: 0)
        }
        .opacity(index == 3 ? 1 : 0)
        .animation(.spring(response: 0.8, dampingFraction: 1, blendDuration: 0).delay(0.2), value: index)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Spacer()

            Button {
                next()
            } label: {
                Group {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else if index == 3 {
                        Text("Done")
                    } else {
                        Text("Continue")
                    }
                }
                .padding(.horizontal, 15)
                .frame(height: 40)
                .frame(minWidth: 110)
                .background(Color(nsColor: .systemFill),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(loading)
        }
        .padding(24)
        .animation(.spring(response: 0.8, dampingFraction: 1, blendDuration: 0), value: index)
    }

    // MARK: - Actions

    private func next() {
        if index < pageCount - 1 {
            index += 1
            return
        }
        finish()
    }

    private func finish() {
        LaunchAtLogin.setEnabled(startOnLogin)
        appState.isFirstLaunch = false
        loading = true

        let afterImport = { [self] in
            ApplicationManager.shared.scan(fromBackup: false) {
                LaunchpadDataManager.shared.load {
                    loading = false
                    GuideWindowController.shared.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        LaunchpadWindowController.shared.show()
                    }
                }
            }
        }

        if importData {
            do {
                _ = try NativeDataManager.shared.importLayout()
                afterImport()
            } catch {
                LogManager.shared.error("[ERROR] \(error.localizedDescription)")
                afterImport()
            }
        } else {
            afterImport()
        }
    }

    private func addToDock() {
        addDockLoading = true
        DockHelper.addToDock(Bundle.main.bundleURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            hasDockIcon = DockHelper.isInDock(Bundle.main.bundleURL)
            addDockLoading = false
        }
    }
}
