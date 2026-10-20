import AppKit

/// The Full Disk Access panel shown before the first uninstall.
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PermissionsWindowController()

    private convenience init() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 490, height: 300),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.identifier = NSUserInterfaceItemIdentifier("PermissionsWindow")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        self.init(window: panel)
        panel.delegate = self
    }

    func show() {
        guard let window else { return }
        let view = SystemPermissionsView()
        view.onCancel = { [weak window] in window?.close() }
        window.contentView = view
        window.level = NSWindow.Level(rawValue: 1001)
        window.setFrame(positionedPanelFrame(width: 490, height: 300), display: true)
        LaunchpadWindowController.shared.launchpadVC.contentView.setInteractionOverlayHidden(false)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        LaunchpadWindowController.shared.launchpadVC.contentView.setInteractionOverlayHidden(true)
        window?.contentView = nil
    }
}

private final class SystemPermissionsView: NSView {
    var onCancel: (() -> Void)?

    private let headerCard = NSView()
    private let stepsCard = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: NSLocalizedString("Full Disk Access", comment: ""))
    private let reasonLabel = NSTextField(wrappingLabelWithString:
        NSLocalizedString("Due to macOS restrictions, Full Disk Access is required to uninstall apps. \nGridura only uses this permission for app uninstallation and never accesses or collects your personal data.", comment: ""))
    private let stepOneLabel = NSTextField(labelWithString: "")
    private let stepTwoLabel = NSTextField(labelWithString: "")
    private let stepHintLabel = NSTextField(wrappingLabelWithString:
        NSLocalizedString("Click add icon and add manually if Gridura not found", comment: ""))
    private let cancelButton = PaddedButton()
    private let authorizeButton = PaddedButton()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 490, height: 300))
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func font(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }

    /// `text` with `highlight` set in bold.
    private func attributed(_ text: String, bold highlight: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font(.body), .foregroundColor: NSColor.labelColor])
        let range = (text as NSString).range(of: highlight)
        if range.location != NSNotFound { result.addAttribute(.font, value: font(.body, weight: .bold), range: range) }
        return result
    }

    private func build() {
        for card in [headerCard, stepsCard] {
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor.quinarySystemFill.cgColor
            card.layer?.cornerRadius = 12
            card.layer?.borderColor = NSColor.secondarySystemFill.cgColor
            card.layer?.borderWidth = 1
        }
        iconView.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        iconView.contentTintColor = .labelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = font(.body)
        reasonLabel.font = font(.subheadline)
        reasonLabel.textColor = .secondaryLabelColor
        reasonLabel.lineBreakMode = .byCharWrapping
        reasonLabel.setContentCompressionResistancePriority(.init(1000), for: .vertical)
        reasonLabel.setContentHuggingPriority(.init(1000), for: .vertical)

        let grant = NSLocalizedString("Grant Permission", comment: "")
        stepOneLabel.attributedStringValue = attributed(NSLocalizedString("1. Click Grant Permission", comment: ""), bold: grant)
        stepTwoLabel.attributedStringValue = attributed(NSLocalizedString("2. Find and enable Gridura", comment: ""), bold: "Gridura")
        stepHintLabel.font = font(.subheadline)
        stepHintLabel.textColor = .secondaryLabelColor
        stepHintLabel.maximumNumberOfLines = 2

        for button in [cancelButton, authorizeButton] {
            button.bezelStyle = .push
            button.contentPadding = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
            button.invalidateIntrinsicContentSize()
        }
        cancelButton.title = NSLocalizedString("Cancel", comment: "")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        authorizeButton.bezelColor = .controlAccentColor
        authorizeButton.contentTintColor = .white
        authorizeButton.attributedTitle = NSAttributedString(string: grant, attributes: [.foregroundColor: NSColor.white])
        authorizeButton.target = self
        authorizeButton.action = #selector(openFullDiskAccessSettings)

        for view in [headerCard, stepsCard, cancelButton, authorizeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [iconView, titleLabel, reasonLabel] { view.translatesAutoresizingMaskIntoConstraints = false; headerCard.addSubview(view) }
        for view in [stepOneLabel, stepTwoLabel, stepHintLabel] { view.translatesAutoresizingMaskIntoConstraints = false; stepsCard.addSubview(view) }

        NSLayoutConstraint.activate([
            headerCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            headerCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            headerCard.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            iconView.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: headerCard.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 14),
            reasonLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            reasonLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            reasonLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            reasonLabel.bottomAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: -12),
            stepsCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stepsCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stepsCard.topAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: 14),
            stepOneLabel.leadingAnchor.constraint(equalTo: stepsCard.leadingAnchor, constant: 16),
            stepOneLabel.trailingAnchor.constraint(equalTo: stepsCard.trailingAnchor, constant: -10),
            stepOneLabel.topAnchor.constraint(equalTo: stepsCard.topAnchor, constant: 14),
            stepTwoLabel.leadingAnchor.constraint(equalTo: stepOneLabel.leadingAnchor),
            stepTwoLabel.trailingAnchor.constraint(equalTo: stepOneLabel.trailingAnchor),
            stepTwoLabel.topAnchor.constraint(equalTo: stepOneLabel.bottomAnchor, constant: 14),
            stepHintLabel.leadingAnchor.constraint(equalTo: stepOneLabel.leadingAnchor),
            stepHintLabel.trailingAnchor.constraint(equalTo: stepOneLabel.trailingAnchor),
            stepHintLabel.topAnchor.constraint(equalTo: stepTwoLabel.bottomAnchor, constant: 4),
            stepHintLabel.bottomAnchor.constraint(equalTo: stepsCard.bottomAnchor, constant: -14),
            authorizeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            authorizeButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stepsCard.bottomAnchor.constraint(lessThanOrEqualTo: authorizeButton.topAnchor, constant: -14),
            cancelButton.trailingAnchor.constraint(equalTo: authorizeButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: authorizeButton.centerYAnchor),
        ])
    }

    @objc private func cancel() { onCancel?() }

    /// Opens Privacy › Full Disk Access; the window stays open.
    @objc private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
