import SwiftUI
import AppKit

/// About tab.
struct AboutTabView: View {
    @ObservedObject private var appState = AppState.shared

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "N/A" }
    private var displayName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "N/A"
    }

    var body: some View {
        VStack(alignment: .center) {
            CustomForm {
                Section {
                    header
                }
            }
            .scrollDisabled(true)
            .padding(.top, 10)

            footer
        }
        .frame(maxHeight: 560)
    }

    // MARK: - Header

    private var header: some View {
        VStack {
            Group {
                if let logo = NSImage(named: "Logo") {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                } else {
                    Image(systemName: "rocket.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 96, height: 96)
            .overlay(alignment: .topTrailing) {
            }
            .padding(.top, 54)
            .padding(.bottom, 20)
            .onTapGesture(count: 5) {
                // Hidden debug action in the original — left as a no-op.
            }

            Text(displayName)
                .font(.title)
                .fontWeight(.medium)
                .padding(.bottom, 10)

            HStack(spacing: 6) {
                Text(version)
                    .font(.subheadline)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .foregroundStyle(.primary)
                    .background(Color(nsColor: .tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack {
            Text(Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "N/A")
                .padding(.bottom, 20)
                .padding(.top, 16)
                .foregroundStyle(.tertiary)

            Divider()

            HStack {
                ControlGroup {
                    Button("Update") { UpdateManager.shared.checkForUpdates() }
                }
            }
            .padding(20)
        }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
