import SwiftUI
import AppKit

/// `CustomForm` — the grouped form every settings tab is built on.
struct CustomForm<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form {
            content()
        }
        .scrollIndicators(.never, axes: [.vertical, .horizontal])
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .formStyle(.grouped)
    }
}

/// Label with an optional subtitle and an optional info popover.
struct SettingsLabel: View {
    var title: String
    var subtitle: String?
    var info: String?

    @State private var showInfo = false

    var body: some View {
        if subtitle == nil && info == nil {
            Text(title)
        } else {
            full
        }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                if let info {
                    Button {
                        showInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .popover(isPresented: $showInfo, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                        Text(info).padding()
                    }
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A square asset "placard" image used next to settings rows.
struct CustomImage: View {
    var name: String
    var size: CGFloat
    var color: Color
    var isMultiply: Bool

    var body: some View {
        if let image = NSImage(named: name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .modifier(MultiplyModifier(enabled: isMultiply, color: color))
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

private struct MultiplyModifier: ViewModifier {
    var enabled: Bool
    var color: Color

    func body(content: Content) -> some View {
        if enabled { content.colorMultiply(color) } else { content }
    }
}

/// `PlacardToggle` — toggle with a leading placard icon.
struct PlacardToggle<Content: View>: View {
    @Binding var isOn: Bool
    var icon: String
    var disabled: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CustomImage(name: icon, size: 20, color: .white, isMultiply: true)
                .padding(.top, -1)
                .padding(.leading, -2)
                .padding(.trailing, -6)
            Toggle(isOn: $isOn, label: content)
                .controlSize(.mini)
                .toggleStyle(.switch)
                .disabled(disabled)
        }
    }
}

/// `TitleBar` — fake traffic lights used by the guide / activation windows.
struct TitleBar: View {
    var title: String
    var showMini: Bool = false
    var onClose: (() -> Void)?
    var onMini: (() -> Void)?

    @State private var isHoveringClose = false
    @State private var isHoveringMini = false

    var body: some View {
        HStack(spacing: 9) {
            trafficLight(color: Color(hex: "FF5F57"), symbol: "xmark", hovering: isHoveringClose) { onClose?() }
            if showMini {
                trafficLight(color: Color(hex: "FEBC2E"), symbol: "minus", hovering: isHoveringMini) { onMini?() }
            }
            if !title.isEmpty {
                Text(title).font(.headline)
            }
        }
        .padding(9)
    }

    private func trafficLight(color: Color, symbol: String, hovering: Bool, action: @escaping () -> Void) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
            .frame(width: 14, height: 14)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(Color.black.opacity(0.6))
                    .opacity(hovering ? 1 : 0)
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) { setHover(symbol: symbol, hovering) }
            }
            .onTapGesture(perform: action)
    }

    private func setHover(symbol: String, _ value: Bool) {
        if symbol == "xmark" { isHoveringClose = value } else { isHoveringMini = value }
    }
}

/// Hosting controller that reports its measured height so the preferences window can resize
///.
final class SizingHostingController<V: View>: NSHostingController<V> {
    var onLayout: (() -> Void)?

    override func viewDidLayout() {
        super.viewDidLayout()
        DispatchQueue.main.async { [weak self] in self?.onLayout?() }
    }
}

extension Color {
    /// `Color(hex:)` —.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
