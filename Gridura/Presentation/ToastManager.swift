import AppKit
import SwiftUI

enum ToastType {
    case info
    case warning
    case error

    var symbol: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// Manages transient messages hosted in a pass-through SwiftUI view
///.
final class ToastManager {
    static let shared = ToastManager()

    final class Model: ObservableObject {
        @Published var toasts: [Toast] = []
    }

    struct Toast: Identifiable {
        let id = UUID()
        var type: ToastType
        var message: String
    }

    private let model = Model()
    private var hostingView: PassthroughHostingView<ToastsView>?
    private var container: NSView?
    private var window: NSWindow?
    private var dismissWorkItems: [UUID: DispatchWorkItem] = [:]
    private var onDismissHandlers: [UUID: () -> Void] = [:]

    private init() {}

    func attach(_ container: NSView, window: NSWindow) {
        self.container = container
        self.window = window
        hostingView?.removeFromSuperview()      // re-attached on every content-view install
        let view = PassthroughHostingView(rootView: ToastsView(model: model))
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        hostingView = view
    }

    func relayout() {}

    func show(type: ToastType, message: String, duration: TimeInterval = 3, persistent: Bool = false, onDismiss: (() -> Void)? = nil) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let toast = Toast(type: type, message: trimmed)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0)) {
            model.toasts.append(toast)
        }
        if let onDismiss { onDismissHandlers[toast.id] = onDismiss }
        guard !persistent, duration > 0 else { return }
        let item = DispatchWorkItem { [weak self] in self?.dismiss(toast.id) }
        dismissWorkItems[toast.id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    func dismiss(_ id: UUID) {
        dismissWorkItems[id]?.cancel()
        dismissWorkItems[id] = nil
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0)) {
            model.toasts.removeAll { $0.id == id }
        }
        let handler = onDismissHandlers.removeValue(forKey: id)
        handler?()
    }
}

/// Hosting view that passes through clicks in empty areas.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}

struct ToastsView: View {
    @ObservedObject var model: ToastManager.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.toasts) { toast in
                ToastItemView(toast: toast)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 24)
        .padding(.bottom, 20)
        .animation(.spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0), value: model.toasts.count)
    }
}

private struct ToastItemView: View {
    let toast: ToastManager.Toast

    private var tint: Color {
        switch toast.type {
        case .info: return Color(nsColor: DesignTokens.color("Pro") ?? .systemGreen)
        case .warning: return Color(.sRGB, red: 0.961, green: 0.651, blue: 0.137)
        case .error: return Color(.sRGB, red: 0.886, green: 0.333, blue: 0.333)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: toast.type.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
            Text(toast.message)
                .font(.body)
                .foregroundStyle(.primary)
            Button {
                ToastManager.shared.dismiss(toast.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 260, alignment: .leading)
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16))
    }
}
