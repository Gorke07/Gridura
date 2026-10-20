import AppKit

/// Folder cell content: a glass plate with a 3×3 preview grid of the first apps
///.
final class LaunchpadFolderView: NSView {
    var folder: LaunchpadGroup?

    private let glassView = NSGlassEffectView()
    private let contentView = NSView()
    private var previewLayers: [CALayer] = []
    private var highlightLayer: CALayer?
    private var requestTokens: [Int: String] = [:]

    /// Full-screen uses variant 3, window mode 1 (see `GlassVariant`).
    var variant: Int = GlassVariant.variant(fullScreen: true) {
        didSet { GlassVariant.apply(to: glassView, variant: variant) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        glassView.tintColor = DesignTokens.color("FolderTint")
        GlassVariant.apply(to: glassView, variant: variant)
        addSubview(glassView)

        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = true
        contentView.layer?.shouldRasterize = true
        contentView.layer?.rasterizationScale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
        addSubview(contentView, positioned: .above, relativeTo: glassView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Configuration

    func configure(folder: LaunchpadGroup) {
        self.folder = folder
        let shown = Array(folder.apps.prefix(9))

        while previewLayers.count < shown.count {
            let layer = makeMiniLayer()
            contentView.layer?.addSublayer(layer)
            previewLayers.append(layer)
        }

        for (index, layer) in previewLayers.enumerated() {
            guard index < shown.count else {
                layer.isHidden = true
                continue
            }
            layer.isHidden = false
            loadIcon(for: layer, index: index, app: shown[index])
        }
        needsLayout = true
    }

    private func makeMiniLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        layer.masksToBounds = false
        layer.allowsEdgeAntialiasing = true
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                          "frame": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        return layer
    }

    private func loadIcon(for layer: CALayer, index: Int, app: LaunchpadApp) {
        let token = UUID().uuidString
        requestTokens[index] = token
        layer.contents = AppIconRepository.shared.cachedImage(for: app.url)
        AppIconRepository.shared.icon(for: app.url) { [weak self] image in
            guard let self, self.requestTokens[index] == token else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = image
            CATransaction.commit()
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }

        // Keep the rasterised preview at native resolution when the window changes screens.
        let scale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
        contentView.layer?.rasterizationScale = scale

        let g = floor(side * 0.81)                       // glass side
        let r = max(g * 0.26, 4.0)                       // glass corner radius
        let glassFrame = CGRect(x: CGFloat(Int((bounds.width - g) * 0.5)),
                                y: CGFloat(Int((bounds.height - g) * 0.5)),
                                width: g, height: g)
        glassView.frame = glassFrame
        contentView.frame = glassFrame
        glassView.cornerRadius = CGFloat(Int(r))

        layoutPreviewIcons(glassSide: g)

        highlightLayer?.frame = bounds
        let highlightRadius = floor((side - g) * 0.5) + CGFloat(Int(r))
        highlightLayer?.cornerRadius = highlightRadius
    }

    private func layoutPreviewIcons(glassSide g: CGFloat) {
        let scale: CGFloat = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
        let cell = floor(g * 0.24 * scale) / scale
        let gap = floor(g * 0.024 * scale) / scale
        let span = cell * 3 + gap * 2
        let inset = floor(scale * (g - span) * 0.5) / scale
        let stride = cell + gap

        for (index, layer) in previewLayers.enumerated() {
            let col = CGFloat(index % 3)
            let row = CGFloat(index / 3)
            let x = floor(scale * (stride * col + inset)) / scale
            let y = floor(scale * (stride * (2 - row) + inset)) / scale
            layer.contentsScale = scale
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = CGRect(x: x, y: y, width: cell, height: cell)
            layer.opacity = 1
            CATransaction.commit()
        }
    }

    /// The 3×3 slot frames in *view* coordinates — the source rects for the folder
    /// open/close flight animation. Slots beyond the apps get the
    /// last valid frame (`min(i, 8)` fallback).
    func previewIconFrames(count: Int) -> [CGRect] {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return [] }
        let g = floor(side * 0.81)
        let scale: CGFloat = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
        let cell = floor(g * 0.24 * scale) / scale
        let gap = floor(g * 0.024 * scale) / scale
        let span = cell * 3 + gap * 2
        let inset = floor(scale * (g - span) * 0.5) / scale
        let stride = cell + gap
        let glassOrigin = CGPoint(x: CGFloat(Int((bounds.width - g) * 0.5)),
                                  y: CGFloat(Int((bounds.height - g) * 0.5)))

        var frames: [CGRect] = []
        for i in 0..<max(count, 0) {
            let slot = min(i, 8)
            let col = CGFloat(slot % 3)
            let row = CGFloat(slot / 3)
            let x = floor(scale * (stride * col + inset)) / scale
            let y = floor(scale * (stride * (2 - row) + inset)) / scale
            frames.append(CGRect(x: glassOrigin.x + x, y: glassOrigin.y + y, width: cell, height: cell))
        }
        return frames
    }

    /// Glass plate frame and radius in view coordinates (source geometry).
    var glassFrameInView: CGRect {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return .zero }
        let g = floor(side * 0.81)
        return CGRect(x: CGFloat(Int((bounds.width - g) * 0.5)),
                      y: CGFloat(Int((bounds.height - g) * 0.5)),
                      width: g, height: g)
    }

    var glassCornerRadiusInView: CGFloat {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return 0 }
        let g = floor(side * 0.81)
        return CGFloat(Int(max(g * 0.26, 4.0)))
    }

    // MARK: - Merge hover

    /// An app hovers over this folder: the glass grows to 1.24× (≈ the full cell), 0.18 s ease-out.
    var isDraggingMerge: Bool = false {
        didSet {
            guard isDraggingMerge != oldValue else { return }
            animateMergeScale(isDraggingMerge)
        }
    }

    private func animateMergeScale(_ on: Bool) {
        guard let layer = glassView.layer else { return }
        // Anchor at the centre while keeping the glass where it is.
        if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            let old = layer.anchorPoint
            let size = layer.bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: layer.position.x + size.width * (0.5 - old.x),
                                     y: layer.position.y + size.height * (0.5 - old.y))
            CATransaction.commit()
        }
        let target = on ? CATransform3DMakeScale(1.24, 1.24, 1) : CATransform3DIdentity
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.transform ?? layer.transform
        animation.toValue = target
        animation.duration = 0.18
        animation.timingFunction = DesignTokens.animationEaseOut
        layer.transform = target
        layer.add(animation, forKey: "folderMergeScale")
    }

    // MARK: - Highlight

    var isHighlight: Bool = false {
        didSet {
            guard isHighlight != oldValue else { return }
            isHighlight ? showHighlight() : hideHighlight()
        }
    }

    private func showHighlight() {
        let layer = CALayer()
        layer.backgroundColor = DesignTokens.color("Highlight")?.cgColor
        layer.cornerCurve = .continuous
        layer.zPosition = -1
        layer.actions = ["opacity": NSNull(), "transform": NSNull(), "bounds": NSNull(),
                         "position": NSNull(), "frame": NSNull()]
        self.layer?.insertSublayer(layer, at: 0)
        highlightLayer = layer
        glassView.tintColor = DesignTokens.color("FolderHighlight")
        needsLayout = true
    }

    private func hideHighlight() {
        highlightLayer?.removeFromSuperlayer()
        highlightLayer = nil
        glassView.tintColor = DesignTokens.color("FolderTint")
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        glassView.tintColor = DesignTokens.color(isHighlight ? "FolderHighlight" : "FolderTint")
        highlightLayer?.backgroundColor = DesignTokens.color("Highlight")?.cgColor
    }
}
