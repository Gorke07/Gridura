import AppKit

/// Draws one app icon with fade-in, plus the "source unavailable" badge
///.
final class LaunchpadAppIconView: NSView {
    let imageLayer = CALayer()

    private var requestToken: String = UUID().uuidString
    private var badgeLayer: CALayer?
    private var currentURL: URL?
    private var hasImage = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        let scale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.contentsScale = scale
        imageLayer.opacity = 0
        imageLayer.actions = disabledActions
        layer?.addSublayer(imageLayer)
    }

    private var disabledActions: [String: CAAction] {
        ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
    }

    override func layout() {
        super.layout()
        withoutActions {
            imageLayer.frame = bounds
            imageLayer.contentsScale = max(window?.backingScaleFactor ?? 2, 1)
        }
        layoutBadge()
    }

    /// Loads (or reuses) the icon for an app.
    func configure(app: LaunchpadApp, pointSize: CGFloat) {
        currentURL = app.url
        requestToken = UUID().uuidString
        let token = requestToken
        // A cache hit applies at once with no fade; a miss fades in when nothing is shown yet.
        if let cached = AppIconRepository.shared.cachedImage(for: app.url) {
            apply(cached, fade: false)
            setSourceUnavailable(app.isSourceUnavailable)
            return
        }
        let fadeOnApply = !hasImage

        AppIconRepository.shared.icon(for: app.url) { [weak self] image in
            guard let self, self.requestToken == token, let image else { return }
            self.apply(image, fade: fadeOnApply)
        }
        setSourceUnavailable(app.isSourceUnavailable)
    }

    private func apply(_ image: NSImage, fade: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        // Without a fade the icon must become visible right here: the layer starts transparent.
        if !fade { imageLayer.opacity = 1 }
        CATransaction.commit()
        hasImage = true
        guard fade else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.18
        animation.timingFunction = DesignTokens.animationEaseOut
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        imageLayer.opacity = 1
        imageLayer.add(animation, forKey: "icon.fade.in")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutBadge()
    }

    // MARK: - Unavailable badge

    private func setSourceUnavailable(_ unavailable: Bool) {
        guard unavailable else {
            badgeLayer?.removeFromSuperlayer()
            badgeLayer = nil
            return
        }
        guard badgeLayer == nil else { return }
        let badge = CALayer()
        badge.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer?.addSublayer(badge)
        badgeLayer = badge
        renderBadge(badge)
    }

    private func layoutBadge() {
        guard let badge = badgeLayer else { return }
        let side = min(bounds.width, bounds.height) * 0.4
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let size = (side * scale).rounded() / scale
        badge.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        badge.position = CGPoint(x: bounds.midX.rounded(), y: bounds.midY.rounded())
        renderBadge(badge)
    }

    private func renderBadge(_ badge: CALayer) {
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let side = badge.bounds.width
        guard side > 0 else { return }
        let config = NSImage.SymbolConfiguration(pointSize: (side * scale).rounded() / scale, weight: .bold)
            .applying(.init(hierarchicalColor: .white))
        let image = NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        badge.contents = image
        badge.contentsScale = scale
        badge.shadowColor = NSColor.black.cgColor
        badge.shadowOpacity = 0.45
        badge.shadowRadius = 3
        badge.shadowOffset = CGSize(width: 0, height: -1)
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
