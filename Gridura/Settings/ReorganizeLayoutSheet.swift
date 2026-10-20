import SwiftUI
import AppKit

/// Reorganize Layout sheet.
struct ReorganizeLayoutSheet: View {
    @ObservedObject private var appState = AppState.shared
    var onDismiss: () -> Void

    @State private var sortMethod: OrganizeSortMethod = .currentOrder
    @State private var sortDirection: OrganizeSortDirection = .ascending
    @State private var folderPlacement: OrganizePlacement = .keep
    @State private var removesAllFolders = false
    @State private var sortsFolderContents = false
    @State private var fillsEmptySlots = false
    @State private var appleAppPlacement: OrganizePlacement = .keep
    @State private var pageScope: OrganizePageScope = .allPages
    @State private var selectedPageIndexes: Set<Int> = []
    @State private var isResettingLayout = false

    private var pageCount: Int { max(LaunchpadDataManager.shared.totalPages, 1) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .center, spacing: 10) {
                content
                footer
            }
            .padding(.bottom, 20)
            .padding(.horizontal, 20)
        }
        .frame(width: 400)
        .frame(maxHeight: 560)
        .interactiveDismissDisabled(isResettingLayout)
        .ignoresSafeArea(.all, edges: .all)
    }

    private var content: some View {
        CustomForm {
            Section {
                Picker("Sort By", selection: $sortMethod) {
                    ForEach(OrganizeSortMethod.allCases, id: \.self) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.menu)

                if sortMethod != .currentOrder {
                    Picker("Order", selection: $sortDirection) {
                        ForEach(OrganizeSortDirection.allCases, id: \.self) { direction in
                            Text(orderName(direction)).tag(direction)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }

                Picker("Apple App Placement", selection: $appleAppPlacement) {
                    ForEach(OrganizePlacement.allCases, id: \.self) { placement in
                        Text(applePlacementName(placement)).tag(placement)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                Toggle(isOn: $removesAllFolders) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ungroup All Folders")
                        if removesAllFolders {
                            Text("Ungrouped apps are added to the end of their original page. If the page is full, they continue onto the next page and may shift apps on later pages.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .controlSize(.mini)

                if !removesAllFolders {
                    Picker("Folder Placement", selection: $folderPlacement) {
                        ForEach(OrganizePlacement.allCases, id: \.self) { placement in
                            Text(folderPlacementName(placement)).tag(placement)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Also Sort Apps in Folders", isOn: $sortsFolderContents)
                        .controlSize(.mini)
                }
            }

            Section {
                Picker("Apply To", selection: $pageScope) {
                    if appState.browsingStyle == .paged {
                        Text("Current Page (\(appState.currentPage + 1))").tag(OrganizePageScope.currentPage)
                    } else {
                        Text("Current Page").tag(OrganizePageScope.currentPage)
                    }
                    Text("All Pages").tag(OrganizePageScope.allPages)
                    Text("Selected Pages").tag(OrganizePageScope.specificPage)
                }
                .pickerStyle(.menu)

                if pageScope == .specificPage {
                    pageChooser
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if pageScope != .currentPage {
                    Toggle(isOn: $fillsEmptySlots) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reorganize Across Pages")
                            Text("Reorganize all apps and folders as a single layout, moving items between pages when needed.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.mini)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 1, blendDuration: 0), value: pageScope)
        }
    }

    private var pageChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selectedPageIndexes.isEmpty
                     ? NSLocalizedString("Select at least one page", comment: "")
                     : String(format: NSLocalizedString("%d pages selected", comment: ""), selectedPageIndexes.count))
                Spacer()
                Button("Select All") { selectedPageIndexes = Set(1...pageCount) }
                Button("Clear") { selectedPageIndexes.removeAll() }
            }
            .controlSize(.small)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 12, alignment: .leading)],
                      alignment: .leading,
                      spacing: 8) {
                ForEach(1...pageCount, id: \.self) { index in
                    Toggle("Page \(index)", isOn: Binding(
                        get: { selectedPageIndexes.contains(index) },
                        set: { on in
                            if on { selectedPageIndexes.insert(index) } else { selectedPageIndexes.remove(index) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 4) {
                noteText
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .tint(.accentColor)
            .accessibilityElement(children: .combine)
            .environment(\.openURL, OpenURLAction { handleNoteLink($0) })

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    apply()
                } label: {
                    HStack(spacing: 6) {
                        if isResettingLayout { ProgressView().controlSize(.small) }
                        Text("Reorganize")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .disabled(isResettingLayout || (pageScope == .specificPage && selectedPageIndexes.isEmpty))
            }
            .padding(.top, 10)
        }
    }

    /// The note carries a `gridura://export-backup` Markdown link (localised
    /// as whole sentences), handled by `OpenURLAction` below.
    private var noteText: Text {
        return Text(LocalizedStringKey("Reorganizing will replace your current layout. [Back Up Your Layout ↗](gridura://export-backup)"))
    }

    private func handleNoteLink(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "gridura" else { return .systemAction }
        switch url.host {
        case "export-backup": BackupManager.shared.presentExportFlow()
        default: return .discarded
        }
        return .handled
    }

    // MARK: - Apply

    private func apply() {
        isResettingLayout = true
        var options = LayoutOrganizeOptions()
        options.sortMethod = sortMethod
        options.sortDirection = sortDirection
        options.folderPlacement = folderPlacement
        options.appleAppPlacement = appleAppPlacement
        options.removesAllFolders = removesAllFolders
        options.sortsFolderContents = sortsFolderContents
        options.reorganizeAcrossPages = fillsEmptySlots
        options.scope = pageScope
        options.selectedPages = selectedPageIndexes
        LaunchpadDataManager.shared.reorganize(options) {
            DispatchQueue.main.async {
                isResettingLayout = false
                onDismiss()
            }
        }
    }

    // MARK: - Names

    private func orderName(_ direction: OrganizeSortDirection) -> String {
        switch sortMethod {
        case .name:
            return direction == .ascending
                ? NSLocalizedString("Ascending", comment: "")
                : NSLocalizedString("Descending", comment: "")
        case .dateAdded:
            return direction == .ascending
                ? NSLocalizedString("Oldest First", comment: "")
                : NSLocalizedString("Newest First", comment: "")
        case .lastUsed:
            return direction == .ascending
                ? NSLocalizedString("Least Recent", comment: "")
                : NSLocalizedString("Most Recent", comment: "")
        case .iconColor:
            return direction == .ascending
                ? NSLocalizedString("Red → White", comment: "")
                : NSLocalizedString("White → Red", comment: "")
        case .currentOrder:
            return direction == .ascending
                ? NSLocalizedString("Ascending", comment: "")
                : NSLocalizedString("Descending", comment: "")
        }
    }

    private func folderPlacementName(_ placement: OrganizePlacement) -> String {
        switch placement {
        case .front: return NSLocalizedString("Before Apps", comment: "")
        case .keep: return NSLocalizedString("Mixed with Apps", comment: "")
        case .back: return NSLocalizedString("After Apps", comment: "")
        }
    }

    private func applePlacementName(_ placement: OrganizePlacement) -> String {
        switch placement {
        case .front: return NSLocalizedString("Before Other Apps", comment: "")
        case .keep: return NSLocalizedString("Mixed with Other Apps", comment: "")
        case .back: return NSLocalizedString("After Other Apps", comment: "")
        }
    }
}
