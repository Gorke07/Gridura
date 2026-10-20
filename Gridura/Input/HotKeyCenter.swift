import AppKit
import Carbon.HIToolbox

/// The `launchApp` shortcut, stored like the KeyboardShortcuts library does
/// (`KeyboardShortcuts_launchApp` = `{"carbonKeyCode":49,"carbonModifiers":2048}`); ⌥Space by default
///.
struct LaunchShortcut: Equatable {
    var keyCode: Int
    var carbonModifiers: Int

    static let defaultsKey = "KeyboardShortcuts_launchApp"
    static let optionSpace = LaunchShortcut(keyCode: kVK_Space, carbonModifiers: optionKey)

    /// The stored shortcut: the default when nothing was ever stored, nil once cleared.
    static func current() -> LaunchShortcut? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return .optionSpace }
        if raw.isEmpty { return nil }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
              let key = object["carbonKeyCode"], let modifiers = object["carbonModifiers"] else { return .optionSpace }
        return LaunchShortcut(keyCode: key, carbonModifiers: modifiers)
    }

    func save() {
        UserDefaults.standard.set("{\"carbonKeyCode\":\(keyCode),\"carbonModifiers\":\(carbonModifiers)}",
                                  forKey: Self.defaultsKey)
    }

    static func clear() { UserDefaults.standard.set("", forKey: defaultsKey) }

    var containsOption: Bool { carbonModifiers & optionKey != 0 }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        return result
    }

    /// "⌃⌥⇧⌘" + key, as shown in the recorder and in the Option-uninstall warning.
    var description: String {
        var text = ""
        if carbonModifiers & controlKey != 0 { text += "⌃" }
        if carbonModifiers & optionKey != 0 { text += "⌥" }
        if carbonModifiers & shiftKey != 0 { text += "⇧" }
        if carbonModifiers & cmdKey != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Function and navigation keys may be used without a modifier.
    static func isStandaloneKey(_ keyCode: Int) -> Bool {
        (specialKeys[keyCode] ?? "").hasPrefix("F") && keyCode != kVK_Escape
    }

    private static func keyName(_ keyCode: Int) -> String {
        if let name = specialKeys[keyCode] { return name }
        // Translate through the current keyboard layout.
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layout) else { return "Key \(keyCode)" }
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers the launch shortcut as a system-wide Carbon hot key (no Input Monitoring permission
/// needed) and fires `onTriggered` on key-up, like the library's `onKeyUp`.
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    static let registrationStateDidChange = Notification.Name("GriduraKeyboardShortcuts.registrationStateDidChange")

    var onTriggered: (() -> Void)?
    /// The `RegisterEventHotKey` status of the last registration; nil when it succeeded or nothing is set.
    private(set) var registrationError: OSStatus?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func start() {
        installHandlerIfNeeded()
        unregister()           // starting twice must not trip over our own registration
        register()
    }

    func stop() { unregister() }

    /// Re-registers after the stored shortcut changed.
    func reload() {
        unregister()
        register()
    }

    /// Raw hot-key event kinds seen so far (pressed = 5, released = 6), for diagnostics.
    private(set) var seenEventKinds: [UInt32] = []

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let kind = event.map { GetEventKind($0) } ?? 0
            HotKeyCenter.shared.seenEventKinds.append(kind)
            // The shortcut fires on key-up, like the library's `onKeyUp`.
            if kind == UInt32(kEventHotKeyReleased) {
                DispatchQueue.main.async { HotKeyCenter.shared.onTriggered?() }
            }
            return noErr
        }, specs.count, &specs, nil, &handlerRef)
    }

    private func register() {
        registrationError = nil
        guard let shortcut = LaunchShortcut.current() else {
            NotificationCenter.default.post(name: Self.registrationStateDidChange, object: nil)
            return
        }
        let id = EventHotKeyID(signature: OSType(0x424C4B59), id: 1)     // 'BLKY'
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.carbonModifiers), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            registrationError = status
            hotKeyRef = nil
            LogManager.shared.error("Hotkey registration failed. name:launchApp; shortcut:\(shortcut.description); error:\(status)")
        }
        NotificationCenter.default.post(name: Self.registrationStateDidChange, object: nil)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
