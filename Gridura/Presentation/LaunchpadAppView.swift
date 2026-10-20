import AppKit

/// One app cell's content: icon, highlight layer, merge glass and the uninstall ✕ button
///.
final class LaunchpadAppView: NSView {
    let iconView = LaunchpadAppIconView()
    private var highlightLayer: CALayer?
    private var mergeView: NSView?
    private var uninstallButton: NSButton?

    var app: LaunchpadApp?
    var isSearching = false

    var onUninstall: (() -> Void)?

    private var isUninstallModeActive = false
    private let variant: Int

    init(variant: Int) {
        self.variant = variant
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(iconView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        iconView.frame = bounds
        let side = min(bounds.width, bounds.height)
        let inner = floor(side * 0.81)
        let radius = floor((side - inner) * 0.5 + max(inner * 0.26, 4))
        mergeView?.frame = bounds
        mergeView?.layer?.cornerRadius = radius
        (mergeView as? NSGlassEffectView)?.cornerRadius = radius     // glass ignores the layer's radius
        highlightLayer?.frame = bounds
        highlightLayer?.cornerRadius = radius
        if let button = uninstallButton {
            let s = min(max(floor(side * 0.24), 12), 24)
            button.frame = CGRect(x: bounds.minX, y: bounds.maxY - s * 1.2, width: s, height: s)
            button.layer?.cornerRadius = s / 2
        }
    }

    // MARK: - Configuration

    func configure(app: LaunchpadApp) {
        self.app = app
        iconView.configure(app: app, pointSize: min(bounds.width, bounds.height))
    }

    // MARK: - States

    var isPressed: Bool = false {
        didSet { iconView.alphaValue = isPressed ? 0.8 : 1.0 }
    }

    var isHighlight: Bool = false {
        didSet {
            if isHighlight { showHighlight() } else { hideHighlight() }
        }
    }

    var isDraggingMerge: Bool = false {
        didSet {
            if isDraggingMerge { showMergeGlass() } else { hideMergeGlass() }
        }
    }

    var isUninstallMode: Bool = false {
        didSet {
            isUninstallModeActive = isUninstallMode
            if isUninstallMode { showUninstallButton() } else { hideUninstallButton() }
        }
    }

    // MARK: - Highlight layer

    private func showHighlight() {
        if highlightLayer == nil {
            let hl = CALayer()
            hl.backgroundColor = DesignTokens.color("Highlight")?.cgColor
                ?? NSColor.black.withAlphaComponent(0.32).cgColor
            hl.cornerCurve = .continuous
            hl.zPosition = -1
            hl.actions = ["opacity": NSNull(), "transform": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
            layer?.insertSublayer(hl, at: 0)
            highlightLayer = hl
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        highlightLayer?.opacity = 1
        highlightLayer?.transform = CATransform3DIdentity
    }

    private func hideHighlight() {
        highlightLayer?.removeFromSuperlayer()
        highlightLayer = nil
    }

    // MARK: - Merge glass

    private func showMergeGlass() {
        guard mergeView == nil else { return }
        let glass = NSGlassEffectView()
        glass.tintColor = DesignTokens.color("FolderTint")
        GlassVariant.apply(to: glass, variant: variant)
        glass.wantsLayer = true
        addSubview(glass, positioned: .below, relativeTo: iconView)
        mergeView = glass
        glass.frame = bounds
        needsLayout = true
        layoutSubtreeIfNeeded()

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.81
        scale.toValue = 1
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        for animation in [scale, opacity] {
            animation.duration = 0.18
            animation.timingFunction = DesignTokens.animationEaseOut
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        glass.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glass.layer?.add(scale, forKey: "merge.scale.in")
        glass.layer?.add(opacity, forKey: "merge.opacity.in")
    }

    private func hideMergeGlass() {
        guard let glass = mergeView else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.81
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = 0
        for animation in [scale, opacity] {
            animation.duration = 0.18
            animation.timingFunction = DesignTokens.animationEaseOut
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { glass.removeFromSuperview() }
        glass.layer?.add(scale, forKey: "merge.scale.out")
        glass.layer?.add(opacity, forKey: "merge.opacity.out")
        CATransaction.commit()
        mergeView = nil
    }

    // MARK: - Uninstall button

    private func showUninstallButton() {
        guard isEligibleForUninstall else { return }
        if uninstallButton == nil {
            let button = NSButton()
            button.title = ""
            button.isBordered = false
            button.image = NSImage(named: "UnstallBtn")
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(uninstallApp)
            button.wantsLayer = true
            button.alphaValue = 0
            button.layer?.opacity = 0
            button.layer?.transform = CATransform3DMakeScale(0.72, 0.72, 1)
            addSubview(button)
            uninstallButton = button
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        guard let button = uninstallButton else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1
        spring.stiffness = 520
        spring.damping = 32
        spring.initialVelocity = 0
        spring.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.72, 0.72, 1))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = spring.settlingDuration
        button.layer?.add(spring, forKey: "uninstallButton.bouncy.scale")
        button.layer?.transform = CATransform3DIdentity

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = 0.16
        opacity.timingFunction = DesignTokens.animationEaseOut
        opacity.fillMode = .forwards
        opacity.isRemovedOnCompletion = false
        button.layer?.add(opacity, forKey: "uninstallButton.opacity")
        button.alphaValue = 1
        button.layer?.opacity = 1
    }

    private func hideUninstallButton() {
        guard let button = uninstallButton else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1
        spring.stiffness = 420
        spring.damping = 36
        spring.initialVelocity = 0
        spring.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.toValue = NSValue(caTransform3D: CATransform3DMakeScale(0.72, 0.72, 1))
        spring.duration = spring.settlingDuration
        button.layer?.add(spring, forKey: "uninstallButton.bouncy.scale")
        button.layer?.transform = CATransform3DMakeScale(0.72, 0.72, 1)

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = 0
        opacity.duration = 0.12
        opacity.timingFunction = CAMediaTimingFunction(name: .easeIn)
        opacity.fillMode = .forwards
        opacity.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak button] in
            // Removed once the hide finished, unless the button was shown again meanwhile.
            guard let button, self?.uninstallButton !== button else { return }
            button.removeFromSuperview()
        }
        button.layer?.add(opacity, forKey: "uninstallButton.opacity")
        CATransaction.commit()
        button.alphaValue = 0
        button.layer?.opacity = 0
        uninstallButton = nil
    }

    /// The "✕" is offered only for removable apps when Pro is active.
    private var isEligibleForUninstall: Bool {
        guard let app else { return false }
        return Self.isRemovable(app)
    }

    /// Source available, not a protected/system app, and not Gridura itself.
    static func isRemovable(_ app: LaunchpadApp) -> Bool {
        guard !app.isSourceUnavailable else { return false }
        guard !ApplicationManager.isAppleApp(app.url) else { return false }
        return app.bundleId != "app.gridura.Gridura" && app.bundleId != "app.gridura.Gridura.debug"
    }

    @objc private func uninstallApp() { onUninstall?() }

    // MARK: - Launch press animation

    func playLaunchAnimation() {
        guard let iconLayer = iconView.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1
        animation.toValue = 1.4
        animation.duration = 0.36
        animation.timingFunction = DesignTokens.animationEaseInEaseOut
        iconLayer.add(animation, forKey: "launch.scale")
    }
}
