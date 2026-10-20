import AppKit

/// Panel that can become key and main without being activated.
final class AlwaysKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Window-mode chrome: rounded surface with shadow that scales on show/hide
///.
final class LaunchpadWindowSurfaceView: NSView {
    let contentView = NSView()
    let surfaceCornerRadius: CGFloat
    let hiddenScale: CGFloat
    let scaleAnimationKey = "windowScale"
    var isWindowMode = false

    init(cornerRadius: CGFloat, hiddenScale: CGFloat) {
        self.surfaceCornerRadius = cornerRadius
        self.hiddenScale = hiddenScale
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        contentView.wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setWindowMode(_ on: Bool) {
        isWindowMode = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyShadow(on)
        if !on || on {
            layer?.removeAnimation(forKey: scaleAnimationKey)
            layer?.transform = CATransform3DIdentity
            if !on { layer?.shadowPath = nil }
        }
        contentView.layer?.cornerRadius = on ? surfaceCornerRadius : 0
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = on
        contentView.layer?.borderWidth = on ? 0.8 : 0
        contentView.layer?.borderColor = on ? NSColor.tertiaryLabelColor.cgColor : nil
        CATransaction.commit()
        needsLayout = on
    }

    private func applyShadow(_ on: Bool) {
        guard let layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = on ? 0.25 : 0
        layer.shadowRadius = on ? 8 : 0
        layer.shadowOffset = CGSize(width: 0, height: on ? -4 : 0)
        layer.shadowPath = (on && !bounds.isEmpty)
            ? CGPath(roundedRect: bounds, cornerWidth: surfaceCornerRadius, cornerHeight: surfaceCornerRadius, transform: nil)
            : nil
    }

    override func layout() {
        super.layout()
        if isWindowMode {
            layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.position = CGPoint(x: frame.midX, y: frame.midY)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyShadow(true)
            CATransaction.commit()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        contentView.layer?.borderColor = isWindowMode ? NSColor.tertiaryLabelColor.cgColor : nil
    }

    /// Reveal progress 0 → hiddenScale, 1 → identity.
    func setRevealProgress(_ progress: CGFloat, duration: TimeInterval, immediate: Bool) {
        guard isWindowMode, let layer else { return }
        let t = max(0, min(progress, 1))
        let scale = hiddenScale + t * (1 - hiddenScale)
        let from = layer.presentation()?.transform.m11 ?? layer.transform.m11
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: scaleAnimationKey)
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        guard !immediate, duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = from
        animation.toValue = scale
        animation.duration = duration
        animation.timingFunction = DesignTokens.animationEaseOut
        animation.preferredFrameRateRange = DesignTokens.frameRateRange
        layer.add(animation, forKey: scaleAnimationKey)
    }
}
