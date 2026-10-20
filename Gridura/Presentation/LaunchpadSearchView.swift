import AppKit

/// Search field + glass capsule / window bar.
final class LaunchpadSearchView: NSView {
    private let glassView = NSGlassEffectView()
    private let contentView = NSView()
    private let searchIcon = NSImageView()
    let inputField = LaunchpadTextField()
    private let clearButton = NSButton()
    private let settingsButton = NSButton()
    private var updateBadge: CALayer?
    private let separator = CALayer()

    var onDebouncedQueryChanged: ((String, String) -> Void)?
    var onSettingsButtonClicked: (() -> Void)?

    private var lastQuery = ""
    private var pendingQuery: String?
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.2

    /// A downloaded update is ready to install: the "More" button shows the "Update" artwork.
    var isUpdateReady = false {
        didSet { settingsButton.image = NSImage(named: isUpdateReady ? "Update" : "More") }
    }

    var isUpdateVisible = false {
        didSet { updateVisibility() }
    }

    private let variant: Int
    private var isWindowMode: Bool { AppState.shared.displayMode == .window }

    init(variant: Int) {
        self.variant = variant
        super.init(frame: .zero)
        wantsLayer = true

        glassView.wantsLayer = true
        GlassVariant.apply(to: glassView, variant: variant)
        glassView.tintColor = DesignTokens.color("SearchGlassTint")
        addSubview(glassView)

        contentView.wantsLayer = true
        addSubview(contentView)

        searchIcon.image = NSImage(named: "Search")
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(searchIcon)

        inputField.isEditable = true
        inputField.isSelectable = true
        inputField.isBezeled = false
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.usesSingleLineMode = true
        inputField.cell?.wraps = false
        inputField.cell?.isScrollable = true
        inputField.target = self
        inputField.delegate = self
        contentView.addSubview(inputField)

        configureButton(clearButton, symbol: "xmark.circle.fill", image: nil, action: #selector(clearClicked))
        configureButton(settingsButton, symbol: nil, image: NSImage(named: "More"), action: #selector(settingsClicked))
        contentView.addSubview(clearButton)
        contentView.addSubview(settingsButton)

        separator.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
        contentView.layer?.addSublayer(separator)

        let badge = CALayer()
        badge.backgroundColor = DesignTokens.color("NewBadge")?.cgColor ?? NSColor.systemRed.cgColor
        badge.cornerRadius = 4
        badge.zPosition = 10
        badge.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        contentView.layer?.addSublayer(badge)
        updateBadge = badge

        updateVisibility()
        updatePlaceholder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureButton(_ button: NSButton, symbol: String?, image: NSImage?, action: Selector) {
        button.isBordered = false
        button.title = ""
        button.bezelStyle = .regularSquare
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        } else {
            button.image = image
        }
        button.imageScaling = .scaleProportionallyUpOrDown
        button.target = self
        button.action = action
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        glassView.frame = bounds
        contentView.frame = bounds
        let w = bounds.width
        let h = bounds.height

        if isWindowMode {
            glassView.isHidden = true
            glassView.removeFromSuperview()
            contentView.layer?.cornerRadius = 0
            separator.isHidden = false
            let iconY = floor((h - 30) / 2)
            searchIcon.frame = CGRect(x: 16, y: iconY, width: 30, height: 30)
            inputField.frame = CGRect(x: 52, y: iconY - 4, width: max(w - 110, 0), height: 32)
            inputField.font = NSFont.systemFont(ofSize: 22, weight: .regular)
            clearButton.frame = CGRect(x: w - 46, y: iconY, width: 30, height: 30)
            settingsButton.frame = clearButton.frame
            separator.frame = CGRect(x: 0, y: 0, width: w, height: 1)
            separator.backgroundColor = NSColor.quinaryLabelColor.cgColor
            updateBadge?.frame = CGRect(x: settingsButton.frame.maxX - 6, y: settingsButton.frame.maxY - 6, width: 8, height: 8)
        } else {
            if glassView.superview == nil { addSubview(glassView, positioned: .below, relativeTo: contentView) }
            glassView.isHidden = false
            glassView.frame = bounds
            glassView.cornerRadius = 20
            contentView.layer?.cornerRadius = 20
            separator.isHidden = true
            searchIcon.frame = CGRect(x: 12, y: 8, width: 24, height: 24)
            inputField.frame = CGRect(x: 41, y: 4, width: 160, height: 24)
            inputField.font = NSFont.preferredFont(forTextStyle: .body)
            clearButton.frame = CGRect(x: 206, y: 8, width: 24, height: 24)
            settingsButton.frame = clearButton.frame
            updateBadge?.frame = CGRect(x: 222, y: 22, width: 8, height: 8)
        }
        updatePlaceholder()
        updateVisibility()
    }

    private func updatePlaceholder() {
        let color: NSColor = isWindowMode ? .secondaryLabelColor : NSColor.white.withAlphaComponent(0.6)
        let font: NSFont = isWindowMode ? NSFont.systemFont(ofSize: 22, weight: .regular) : NSFont.preferredFont(forTextStyle: .body)
        inputField.placeholderAttributedString = NSAttributedString(
            string: NSLocalizedString("Search Applications", comment: ""),
            attributes: [.foregroundColor: color, .font: font])
        inputField.textColor = isWindowMode ? .labelColor : .white
        searchIcon.contentTintColor = isWindowMode ? .secondaryLabelColor : .white
        clearButton.contentTintColor = isWindowMode ? .secondaryLabelColor : NSColor.white.withAlphaComponent(0.6)
        settingsButton.contentTintColor = clearButton.contentTintColor
    }

    private func updateVisibility() {
        let hasText = !inputField.stringValue.isEmpty
        clearButton.isHidden = !hasText
        settingsButton.isHidden = hasText
        updateBadge?.isHidden = !(inputField.stringValue.isEmpty && isUpdateVisible)
    }

    // MARK: - Actions

    @objc private func clearClicked() { clear(notify: true) }
    @objc private func settingsClicked() { onSettingsButtonClicked?() }

    func clear(notify: Bool) {
        inputField.stringValue = ""
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        updateVisibility()
        if notify {
            let previous = lastQuery
            lastQuery = ""
            pendingQuery = nil
            onDebouncedQueryChanged?("", previous)
        }
    }

    /// Debounced query notification.
    private func scheduleQuery() {
        let raw = inputField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .lowercased()
        updateVisibility()
        if raw == pendingQuery { return }
        debounceWorkItem?.cancel()
        pendingQuery = nil
        guard raw != lastQuery else { return }
        pendingQuery = raw
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pendingQuery == raw else { return }
            let previous = self.lastQuery
            self.lastQuery = raw
            self.pendingQuery = nil
            self.onDebouncedQueryChanged?(raw, previous)
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    func focusField() {
        window?.makeFirstResponder(inputField)
    }

    // MARK: - Window-mode drag handle

    private var mouseDownPoint: NSPoint = .zero
    private var mouseDownInWindowMode = false

    override func mouseDown(with event: NSEvent) {
        guard isWindowMode else {
            focusField()
            return
        }
        mouseDownPoint = event.locationInWindow
        mouseDownInWindowMode = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownInWindowMode, let window else { return }
        let point = event.locationInWindow
        if hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) >= 4 {
            mouseDownInWindowMode = false
            window.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownInWindowMode { focusField() }
        mouseDownInWindowMode = false
    }
}

extension LaunchpadSearchView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleQuery()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            clear(notify: true)
            return true
        }
        return false
    }
}

/// The search field. Its field editor is set up like the original `LaunchpadFieldEditor`: caret in
/// `labelColor`, spelling correction / autocompletion / candidates off, Writing Tools off.
final class LaunchpadTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = .labelColor
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.writingToolsBehavior = .none
        }
        return accepted
    }
}

