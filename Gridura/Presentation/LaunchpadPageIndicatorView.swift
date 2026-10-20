import AppKit

/// Page dots inside a glass capsule.
final class LaunchpadPageIndicatorView: NSView {
    private let glassView = NSGlassEffectView()
    private var buttons: [PageIndicatorButton] = []

    var onSelectPage: ((Int) -> Void)?
    private var trackingArea: NSTrackingArea?

    private let variant: Int

    init(variant: Int) {
        self.variant = variant
        super.init(frame: .zero)
        wantsLayer = true

        glassView.wantsLayer = true
        glassView.cornerRadius = 12
        glassView.alphaValue = 0
        GlassVariant.apply(to: glassView, variant: variant)
        glassView.tintColor = DesignTokens.color("FolderTint")
        addSubview(glassView)

    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let n = buttons.count
        return NSSize(width: CGFloat(6 * max(n - 1, 0) + n * 14 + 12), height: 24)
    }

    /// Frames instead of Auto Layout: the content view sizes this view by hand, so a stack view's own
    /// width constraints fought the frame-derived ones (conflicting-constraints log).
    override func layout() {
        super.layout()
        glassView.frame = bounds
        var x: CGFloat = 6
        for button in buttons {
            button.frame = CGRect(x: x, y: floor((bounds.height - 14) / 2), width: 14, height: 14)
            x += 14 + 6
        }
    }

    /// The page whose dot is under `point` (this view's coordinates), nil elsewhere.
    func pageIndex(at point: CGPoint) -> Int? {
        for (index, button) in buttons.enumerated() {
            let frame = convert(button.bounds, from: button).insetBy(dx: -4, dy: -4)
            if frame.contains(point) { return index }
        }
        return nil
    }

    func update(totalPages: Int, currentPage: Int) {
        while buttons.count < totalPages {
            let button = PageIndicatorButton()
            button.tag = buttons.count
            button.target = self
            button.action = #selector(handleIndicatorClick(_:))
            addSubview(button)
            buttons.append(button)
        }
        while buttons.count > totalPages {
            buttons.removeLast().removeFromSuperview()
        }
        for (index, button) in buttons.enumerated() {
            button.isActive = index == currentPage
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        glassView.alphaValue = 0
        glassView.layer?.removeAllAnimations()
    }

    @objc private func handleIndicatorClick(_ sender: NSButton) {
        onSelectPage?(sender.tag)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { animateGlass(to: 1) }
    override func mouseExited(with event: NSEvent) { animateGlass(to: 0) }

    private func animateGlass(to value: CGFloat) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = glassView.alphaValue
        animation.toValue = value
        animation.duration = 0.28
        animation.timingFunction = DesignTokens.animationEaseInEaseOut
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        glassView.wantsLayer = true
        glassView.layer?.add(animation, forKey: "indicator.opacity")
        glassView.alphaValue = value
    }
}

/// One page dot.
final class PageIndicatorButton: NSButton {
    private let dotLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    var isActive: Bool = false {
        didSet { updateDot(animated: true) }
    }
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        wantsLayer = true
        dotLayer.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
        layer?.addSublayer(dotLayer)
        updateDot(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateDot(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; updateDot(animated: true) }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateDot(animated: true) }

    private func updateDot(animated: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let diameter: CGFloat = (isHovered && !isActive) ? 10 : 8
        let color: NSColor
        if dark {
            color = isActive ? NSColor.white.withAlphaComponent(1.0) : NSColor.white.withAlphaComponent(0.3)
        } else {
            color = isActive ? NSColor.black.withAlphaComponent(0.6) : NSColor.black.withAlphaComponent(0.2)
        }
        let frame = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        CATransaction.begin()
        if !animated { CATransaction.setDisableActions(true) }
        dotLayer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dotLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        dotLayer.cornerRadius = diameter / 2
        dotLayer.backgroundColor = color.cgColor
        CATransaction.commit()
        _ = frame
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDot(animated: false)
    }
}
