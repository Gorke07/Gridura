import AppKit
import SwiftUI

/// Settings row control that records the `launchApp` shortcut: click, press the
/// combination, Esc cancels, the cancel button (or ⌫) clears it.
struct ShortcutRecorderView: NSViewRepresentable {
    func makeNSView(context: Context) -> ShortcutRecorderField { ShortcutRecorderField() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutRecorderField, context: Context) -> CGSize? {
        CGSize(width: 150, height: 24)
    }
    func updateNSView(_ nsView: ShortcutRecorderField, context: Context) { nsView.showCurrent() }
}

final class ShortcutRecorderField: NSSearchField, NSSearchFieldDelegate {
    private var monitor: Any?
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        alignment = .center
        placeholderString = NSLocalizedString("Record Shortcut", comment: "")
        focusRingType = .none
        (cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (cell as? NSSearchFieldCell)?.cancelButtonCell?.target = self
        (cell as? NSSearchFieldCell)?.cancelButtonCell?.action = #selector(clearShortcut)
        showCurrent()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: HotKeyCenter.registrationStateDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    deinit { stopRecording() }

    @objc private func refresh() { showCurrent() }

    func showCurrent() {
        guard !isRecording else { return }
        stringValue = LaunchShortcut.current()?.description ?? ""
    }

    @objc private func clearShortcut() {
        LaunchShortcut.clear()
        HotKeyCenter.shared.reload()
        stringValue = ""
        window?.makeFirstResponder(nil)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { startRecording() }
        return accepted
    }

    func controlTextDidEndEditing(_ obj: Notification) { stopRecording() }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        stringValue = ""
        placeholderString = NSLocalizedString("Press Shortcut", comment: "")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        placeholderString = NSLocalizedString("Record Shortcut", comment: "")
        showCurrent()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = Int(event.keyCode)
        if flags.isEmpty && keyCode == 53 {                      // Esc cancels
            window?.makeFirstResponder(nil)
            return nil
        }
        if flags.isEmpty && (keyCode == 51 || keyCode == 117) {  // ⌫ / ⌦ clear
            clearShortcut()
            return nil
        }
        let usable = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        guard usable || LaunchShortcut.isStandaloneKey(keyCode) else {
            NSSound.beep()
            return nil
        }

        let previous = LaunchShortcut.current()
        let shortcut = LaunchShortcut(keyCode: keyCode, carbonModifiers: LaunchShortcut.carbonModifiers(from: flags))
        shortcut.save()
        HotKeyCenter.shared.reload()
        if HotKeyCenter.shared.registrationError != nil {
            // Taken by another app or macOS: restore the previous shortcut and say so.
            if let previous { previous.save() } else { LaunchShortcut.clear() }
            HotKeyCenter.shared.reload()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("Could not set shortcut", comment: "")
            alert.informativeText = NSLocalizedString("Another app or macOS is already using this shortcut.", comment: "")
            alert.runModal()
        }
        window?.makeFirstResponder(nil)
        return nil
    }
}
