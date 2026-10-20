import AppKit

/// Loading / no-result placeholder.
final class StatusView: NSView {
    enum StatusType: Int {
        case loading = 0
        case searchNoResult = 1
        case none = 2
    }

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    var type: StatusType = .none {
        didSet { update() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .secondaryLabelColor
        addSubview(imageView)
        titleLabel.alignment = .center
        titleLabel.font = DesignTokens.statusTitleFont
        titleLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func update() {
        switch type {
        case .loading:
            isHidden = false
            imageView.image = NSImage(named: "Status/Loading") ?? NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
            titleLabel.stringValue = NSLocalizedString("Initializing", comment: "")
        case .searchNoResult:
            isHidden = false
            imageView.image = NSImage(named: "Status/SearchEmpty") ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            titleLabel.stringValue = NSLocalizedString("No Results", comment: "")
        case .none:
            isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleH = titleLabel.intrinsicContentSize.height
        let imageY = bounds.midY + (titleH + 136) / 2 - 120
        imageView.frame = CGRect(x: bounds.midX - 60, y: imageY, width: 120, height: 120)
        let titleW = min(bounds.width, max(1, titleLabel.intrinsicContentSize.width))
        titleLabel.frame = CGRect(x: bounds.midX - titleW / 2, y: imageY - 16 - titleH, width: titleW, height: titleH)
    }
}
