import AppKit




/// Opened-folder presentation: glass panel, title, back button, flight animation
///.

// MARK: - Supporting views

/// Clip box that mirrors `cornerRadius` onto its layer.
final class OpenedFolderClipView: NSView {
    var cornerRadius: CGFloat = 0 {
        didSet {
            wantsLayer = true
            layer?.cornerRadius = cornerRadius
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The folder title above the glass panel; click → rename.
final class FolderFloatingTitleView: NSView {
    let textLayer = NonAnimatingTextLayer()
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(textLayer)
        updateTextColor()
    }

    /// `labelColor` is dynamic; its `cgColor` must be resolved against this view's appearance,
    /// not the app's default one (which rendered the title black on a dark launcher).
    private func updateTextColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            textLayer.foregroundColor = NSColor.labelColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTextColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String, font: NSFont, fullscreen: Bool) {
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        if fullscreen {
            textLayer.shadowColor = NSColor.black.withAlphaComponent(0.26).cgColor
            textLayer.shadowOpacity = 1
            textLayer.shadowRadius = 2
            textLayer.shadowOffset = CGSize(width: 0, height: -1)
        } else {
            textLayer.shadowOpacity = 0
        }
        updateTextColor()
        textLayer.string = title
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = floor(titleFont?.boundingRectForFont.height ?? 0)
        textLayer.frame = CGRect(x: 0, y: CGFloat(Int((bounds.height - h) * 0.5)), width: bounds.width, height: h)
    }

    private var titleFont: NSFont? {
        (textLayer.font as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .largeTitle).pointSize)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Scroll view locked to the vertical axis.
final class VerticalOnlyScrollView: NSScrollView {
    var onMouseDown: (() -> Void)?
    var allowsVerticalScrolling = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        borderType = .noBorder
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .automatic
        contentView = HorizontalLockedClipView()
        // NSClipView paints its own background by default (dark in the forced-dark launchpad
        // window), which would cover the glass panel — it must stay transparent.
        contentView.drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func scrollWheel(with event: NSEvent) {
        guard allowsVerticalScrolling else { return }
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?() }
}

/// Clip view that never scrolls horizontally (`constrainBoundsRect` pins x = 0).
final class HorizontalLockedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        r.origin.x = 0
        return r
    }
}

/// Borderless button that still forwards clicks (`buttonType = 7`).
final class PassthroughButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryChange)
        isBordered = false
        focusRingType = .none
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Hosts the flying icon proxies during open/close (zPosition 100).
final class FolderAnimationProxyHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.zPosition = 100
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// One flying icon (+ optional title) between a folder preview slot and its cell.
final class FolderAnimationProxyLayer: CALayer {
    struct Flight {
        var iconFrom: CGRect
        var iconTo: CGRect
        var titleFrom: CGRect
        var titleTo: CGRect
        var iconOpacityFrom: Float
        var iconOpacityTo: Float
        var titleOpacityFrom: Float
        var titleOpacityTo: Float
    }

    var flight: Flight?
    let iconLayer = CALayer()
    var titleLayer: CATextLayer?

    init(app: LaunchpadApp, showTitle: Bool, titleString: Any?, scale: CGFloat) {
        super.init()
        masksToBounds = false
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = scale
        if let cached = AppIconRepository.shared.cachedImage(for: app.url) {
            iconLayer.contents = cached
        } else {
            AppIconRepository.shared.icon(for: app.url) { [weak iconLayer] image in
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                iconLayer?.contents = image
                CATransaction.commit()
            }
        }
        addSublayer(iconLayer)

        if showTitle {
            let title = CATextLayer()
            title.string = titleString ?? (app.alias.isEmpty ? app.name : app.alias)
            title.alignmentMode = .center
            title.truncationMode = .end
            title.isWrapped = false
            title.contentsScale = scale
            addSublayer(title)
            titleLayer = title
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - LaunchpadContentView + opened folder

extension LaunchpadContentView {
    private var folderAppState: AppState { AppState.shared }

    var folderTitleFont: NSFont {
        let fullscreen = !isWindowMode
        let size = fullscreen
            ? NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
            : NSFont.preferredFont(forTextStyle: .title2).pointSize
        return NSFont.systemFont(ofSize: size, weight: fullscreen ? .regular : .medium)
    }

    ///
    var folderCornerRadius: CGFloat {
        if isWindowMode { return 30 }
        return max(16, min(columnSize.width, columnSize.height) * 0.24)
    }

    // MARK: Setup

    func setupFolderOverlay() {
        openedFolderBackdropView.alphaValue = 0
        openedFolderBackdropView.isHidden = true
        openedFolderBackdropView.autoresizingMask = [.width, .height]
        openedFolderBackdropView.onMouseDown = { [weak self] in self?.folderBackdropClicked() }
        addSubview(openedFolderBackdropView)

        openedFolderClipView.alphaValue = 0
        openedFolderClipView.isHidden = true

        GlassVariant.apply(to: openedFolderBlurView,
                           variant: GlassVariant.variant(fullScreen: !isWindowMode))
        openedFolderBlurView.tintColor = DesignTokens.color("FolderTint")
        openedFolderClipView.addSubview(openedFolderBlurView)

        openedFolderGlassContentView.wantsLayer = true
        openedFolderGlassContentView.autoresizingMask = [.width, .height]
        openedFolderBlurView.addSubview(openedFolderGlassContentView)

        openedFolderScrollView.autoresizingMask = [.width, .height]
        openedFolderScrollView.onMouseDown = { [weak self] in self?.folderBackdropClicked() }
        openedFolderGlassContentView.addSubview(openedFolderScrollView)
        openedFolderScrollView.documentView = openedFolderContentView
        addSubview(openedFolderClipView)

        openedFolderTitleLabel.alphaValue = 0
        openedFolderTitleLabel.isHidden = true
        openedFolderTitleLabel.onClick = { [weak self] in self?.beginFolderTitleEdit() }
        addSubview(openedFolderTitleLabel)

        if let image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back") {
            let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            openedFolderBackButton.image = image.withSymbolConfiguration(config)
        }
        openedFolderBackButton.contentTintColor = .labelColor
        openedFolderBackButton.alphaValue = 0
        openedFolderBackButton.action = #selector(LaunchpadContentView.folderBackClicked)
        openedFolderBackButton.target = self
        openedFolderBackButton.isHidden = true
        addSubview(openedFolderBackButton)
    }

    @objc func folderBackClicked() { closeFolder(animated: true) }

    private func folderBackdropClicked() {
        if openedFolderTitleEditorView != nil {
            endFolderTitleEdit(save: true)
            return
        }
        let p = window?.mouseLocationOutsideOfEventStream ?? .zero
        let local = convert(p, from: nil)
        guard !openedFolderClipView.frame.insetBy(dx: -20, dy: -20).contains(local),
              !openedFolderTitleLabel.frame.insetBy(dx: -8, dy: -8).contains(local) else { return }
        closeFolder(animated: true)
    }

    // MARK: Geometry

    /// Target frame of the glass panel, content-view coordinates (y-up).
    func openedFolderTargetFrame(appCount: Int) -> CGRect {
        let cols = max(1, folderAppState.columns)
        let folderRows = max(1, Int(ceil(Double(appCount) / Double(cols))))
        let visibleRows = isWindowMode
            ? max(1, folderAppState.rows)
            : max(1, min(max(1, folderAppState.rows), folderRows))
        let vPad = min((columnSize.height * 0.12).rounded(), 6)

        if isWindowMode {
            let width = safeFrame.width - 8
            let height = max(searchView.frame.minY - safeFrame.minY - 4, 0)
            let x = safeFrame.minX + (safeFrame.width - width) * 0.5
            return CGRect(x: x, y: searchView.frame.minY - height, width: width, height: height)
        }
        let width = columnSize.width * CGFloat(cols)
        let height = columnSize.height * CGFloat(visibleRows) + 2 * vPad
        let x = safeFrame.minX + (safeFrame.width - width) * 0.5
        let y = safeFrame.minY + (safeFrame.height - height - 42) * 0.5
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Lays out the scroll view, document view and app cells inside the panel.
    @discardableResult
    func layoutOpenedFolderContent() -> CGRect {
        guard let folder = currentOpenedFolder else { return .zero }
        let apps = folder.apps
        let cols = max(1, folderAppState.columns)
        let folderRows = max(1, Int(ceil(Double(apps.count) / Double(cols))))
        let visibleRows = isWindowMode
            ? max(1, folderAppState.rows)
            : max(1, min(max(1, folderAppState.rows), folderRows))
        let vPad = min((columnSize.height * 0.12).rounded(), 6)

        let clipFrame = openedFolderClipView.frame
        let w = clipFrame.width, h = clipFrame.height
        openedFolderBlurView.frame = CGRect(x: 0, y: 0, width: w, height: h)
        openedFolderBlurView.layer?.cornerRadius = openedFolderClipView.cornerRadius
        openedFolderGlassContentView.frame = CGRect(x: 0, y: 0, width: w, height: h)
        openedFolderScrollView.frame = CGRect(x: 0, y: vPad, width: w, height: max(h - 2 * vPad, 0))

        let contentH = max(columnSize.height * CGFloat(folderRows), h - 2 * vPad)
        openedFolderContentView.frame = CGRect(x: 0, y: 0, width: w, height: contentH)

        let rows = max(visibleRows, folderRows)
        let insetX = max(floor((w - columnSize.width * CGFloat(cols)) * 0.5), 0)
        let insetY = max(floor((contentH - columnSize.height * CGFloat(rows)) * 0.5), 0)
        // Mid-drag the in-flight order wins over the stored one.
        for (i, view) in (drag?.folderCells ?? openedFolderAppViews).enumerated() {
            view.itemSide = itemSide
            view.frame = CGRect(x: insetX + columnSize.width * CGFloat(i % cols),
                                y: insetY + columnSize.height * CGFloat(i / cols),
                                width: columnSize.width,
                                height: columnSize.height)
        }

        let maxScroll = max(contentH - openedFolderScrollView.contentView.bounds.height, 0)
        openedFolderScrollView.allowsVerticalScrolling = maxScroll > 0.5
        openedFolderScrollView.verticalScrollElasticity = maxScroll <= 0.5 ? .none : .automatic
        openedFolderScrollView.hasVerticalScroller = false
        openedFolderScrollView.hasHorizontalScroller = false

        return clipFrame
    }

    /// Frame of cell `index` inside the opened folder's document view (same maths as
    /// `layoutOpenedFolderContent`), for `count` cells.
    func openedFolderSlotFrame(index: Int, count: Int) -> CGRect {
        let cols = max(1, folderAppState.columns)
        let folderRows = max(1, Int(ceil(Double(max(count, 1)) / Double(cols))))
        let visibleRows = isWindowMode
            ? max(1, folderAppState.rows)
            : max(1, min(max(1, folderAppState.rows), folderRows))
        let rows = max(visibleRows, folderRows)
        let w = openedFolderContentView.bounds.width
        let contentH = openedFolderContentView.bounds.height
        let insetX = max(floor((w - columnSize.width * CGFloat(cols)) * 0.5), 0)
        let insetY = max(floor((contentH - columnSize.height * CGFloat(rows)) * 0.5), 0)
        return CGRect(x: insetX + columnSize.width * CGFloat(index % cols),
                      y: insetY + columnSize.height * CGFloat(index / cols),
                      width: columnSize.width, height: columnSize.height)
    }

    var currentOpenedFolder: LaunchpadGroup? {
        guard let id = openedFolderID else { return nil }
        return LaunchpadDataManager.shared.allGroups.first { $0.id == id && $0.isFolder }
    }

    /// Title frame above the panel.
    func openedFolderTitleFrame(name: String, panelFrame: CGRect) -> CGRect {
        let title = name.isEmpty ? " " : name
        let font = folderTitleFont
        let textW = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let w = min(panelFrame.width, max(textW + 16, 80))
        let h = ceil(font.boundingRectForFont.height)
        let x = (panelFrame.midX - w * 0.5).rounded()
        let y = (panelFrame.maxY + (isWindowMode ? 15 : 28)).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Re-applies geometry when the window resizes while a folder is open. Skipped while an
    /// open/close animation is running: the animation drives the model geometry, and a layout
    /// pass here would fight it (relayouting the content at the animating frame).
    func layoutOpenedFolder(animated: Bool) {
        guard !openedFolderIsAnimating, let folder = currentOpenedFolder else { return }
        openedFolderBackdropView.frame = bounds
        let target = openedFolderTargetFrame(appCount: folder.apps.count)
        openedFolderClipView.frame = target
        openedFolderClipView.cornerRadius = folderCornerRadius
        layoutOpenedFolderContent()
        openedFolderTitleLabel.frame = openedFolderTitleFrame(name: folder.displayName, panelFrame: target)
        layoutBackButton()
    }

    private func layoutBackButton() {
        guard isWindowMode else {
            openedFolderBackButton.isHidden = true
            return
        }
        let titleFrame = openedFolderTitleLabel.frame
        openedFolderBackButton.frame = CGRect(x: titleFrame.minX + 16, y: titleFrame.midY - 16, width: 32, height: 32)
    }

    // MARK: Base content fade

    private func fadeBaseContent(out: Bool, duration: TimeInterval) {
        let targets: [NSView] = [searchView,
                                 appStateBrowsingScrollTarget,
                                 pageIndicatorView,
                                 statusView].compactMap { $0 }
        let alpha: CGFloat = out ? 0.001 : 1
        let scale: CGFloat = out ? 0.94 : 1
        for view in targets {
            guard let layer = view.layer else { continue }
            // AppKit view-backed layers anchor at (0,0) and their `position` is the frame
            // origin, so the anchor point must NOT be moved: that would shift the whole view
            // by half its size (the grid came back offset). Scale about the centre with a
            // translate-scale-translate transform instead.
            let target = fadeTransform(scale: scale, size: view.bounds.size)
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = layer.presentation()?.opacity ?? layer.opacity
            opacity.toValue = Float(alpha)
            opacity.duration = duration
            opacity.timingFunction = DesignTokens.animationEaseInEaseOut
            opacity.fillMode = .forwards
            opacity.isRemovedOnCompletion = false

            let transform = CABasicAnimation(keyPath: "transform")
            transform.fromValue = layer.presentation()?.transform ?? layer.transform
            transform.toValue = target
            transform.duration = duration
            transform.timingFunction = DesignTokens.animationEaseInEaseOut
            transform.fillMode = .forwards
            transform.isRemovedOnCompletion = false

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = Float(alpha)
            layer.transform = target
            layer.add(opacity, forKey: "folder.base.opacity")
            layer.add(transform, forKey: "folder.base.transform")
            CATransaction.commit()
        }
        if out { searchView.window?.makeFirstResponder(nil) }
        isBaseContentFaded = out
    }

    /// A scale transform about the centre of `size`, valid for a layer anchored at (0,0)
    /// (AppKit view-backed layers) — the layer's frame origin stays put.
    private func fadeTransform(scale: CGFloat, size: CGSize) -> CATransform3D {
        let cx = size.width * 0.5, cy = size.height * 0.5
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        return t
    }

    /// The `position` a layer takes for `frame`, honouring its anchor point.
    private func anchorPosition(for frame: CGRect, in layer: CALayer) -> CGPoint {
        let a = layer.anchorPoint
        return CGPoint(x: frame.minX + frame.width * a.x, y: frame.minY + frame.height * a.y)
    }

    private var appStateBrowsingScrollTarget: NSView {
        folderAppState.browsingStyle == .scroll
            ? scrollModeView
            : (pageViews.indices.contains(currentPage) ? pageViews[currentPage] : pagedModeView)
    }

    // MARK: Opening

    func openFolder(groupView: LaunchpadGroupView, source: Int) {
        guard let folder = groupView.group, folder.isFolder,
              !openedFolderIsAnimating, openedFolderID == nil else { return }
        window?.makeFirstResponder(nil)
        openedFolderIsAnimating = true
        openedFolderID = folder.id
        openedFolderGroupView = groupView

        openedFolderBackdropView.layer?.backgroundColor = isWindowMode
            ? NSColor.clear.cgColor
            : NSColor.black.withAlphaComponent(0.2).cgColor

        // Source geometry from the folder icon.
        let sourceGlassInContent = groupView.folderView.map { folderView in
            folderView.convert(folderView.glassFrameInView, to: self)
        } ?? groupView.frame
        let sourceRadius = groupView.folderView?.glassCornerRadiusInView ?? folderCornerRadius
        let previewSlots = groupView.folderView.map { folderView in
            folderView.previewIconFrames(count: folder.apps.count)
                .map { folderView.convert($0, to: self) }
        } ?? []
        // The title flies from the folder cell's own title to the panel title.
        let sourceTitleFrame = groupView.convert(groupView.titleFrameInView, to: self)

        // Build the app cells.
        openedFolderAppViews.forEach { $0.removeFromSuperview() }
        openedFolderAppViews = []
        for app in folder.apps {
            let view = makeGroupView(for: LaunchpadGroup(id: folder.id + "/" + app.id,
                                                         name: app.name,
                                                         apps: [app],
                                                         order: 0, page: 0, isFolder: false))
            view.alphaValue = 0
            openedFolderContentView.addSubview(view)
            openedFolderAppViews.append(view)
        }

        let target = openedFolderTargetFrame(appCount: folder.apps.count)
        openedFolderBackdropView.frame = bounds
        openedFolderBackdropView.isHidden = false

        // The glass material resolves against the window's appearance, so the panel's glass is
        // (re)created at open time — an instance built before the window existed renders a flat
        // dark fallback instead of the proper Liquid Glass. The glass also stays EMPTY: hosting
        // the scroll view inside it degrades the material the same way, so the content floats
        // above it as a sibling (visually identical to the original).
        let oldGlass = openedFolderBlurView
        let fresh = NSGlassEffectView()
        GlassVariant.apply(to: fresh, variant: GlassVariant.variant(fullScreen: !isWindowMode))
        fresh.tintColor = DesignTokens.color("FolderTint")
        fresh.wantsLayer = true
        fresh.frame = openedFolderClipView.bounds
        fresh.autoresizingMask = [.width, .height]
        openedFolderClipView.addSubview(fresh)
        openedFolderGlassContentView.removeFromSuperview()
        openedFolderGlassContentView.frame = openedFolderClipView.bounds
        openedFolderGlassContentView.autoresizingMask = [.width, .height]
        openedFolderClipView.addSubview(openedFolderGlassContentView)
        openedFolderBlurView = fresh
        oldGlass.removeFromSuperview()

        // Model geometry is the TARGET from the start; the source only drives the animations.
        openedFolderClipView.frame = target
        openedFolderClipView.cornerRadius = folderCornerRadius
        openedFolderClipView.isHidden = false
        openedFolderClipView.alphaValue = 1
        layoutOpenedFolderContent()

        openedFolderTitleLabel.setTitle(folder.displayName, font: folderTitleFont, fullscreen: !isWindowMode)
        openedFolderTitleLabel.isHidden = false
        openedFolderTitleLabel.alphaValue = 1
        layoutBackButton()
        openedFolderBackButton.isHidden = !isWindowMode

        fadeBaseContent(out: true, duration: 0.28)

        // Flight proxies.
        let proxyHost = FolderAnimationProxyHostView(frame: bounds)
        proxyHost.autoresizingMask = [.width, .height]
        addSubview(proxyHost, positioned: .above, relativeTo: openedFolderClipView)
        let proxies = buildProxies(apps: folder.apps,
                                   slotsInContent: previewSlots,
                                   host: proxyHost,
                                   opening: true)

        let duration = 0.28
        // Flush pending layout first: AppKit syncs view geometry to the backing layer at the end
        // of the turn, and that sync discards explicit animations added before it — the panel
        // then appeared at its final size with no morph.
        layoutSubtreeIfNeeded()
        let targetTitleFrame = openedFolderTitleFrame(name: folder.displayName, panelFrame: target)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = DesignTokens.animationEaseInEaseOut
            self.openedFolderBackdropView.animator().alphaValue = 1

            // The folder icon fades out with the rest (its slot is taken over by the panel).
            groupView.animator().alphaValue = 0

            self.animateClipAppearance(from: sourceGlassInContent, radius: sourceRadius, duration: duration)
            self.animateTitle(from: sourceTitleFrame, to: targetTitleFrame, fadeTo: 1, duration: duration)

            self.openedFolderBackButton.animator().alphaValue = self.isWindowMode ? 1 : 0

            for proxy in proxies { proxy.fly(duration: duration) }
        }, completionHandler: {
            for view in self.openedFolderAppViews { view.alphaValue = 1 }
            proxyHost.removeFromSuperview()
            self.openedFolderIsAnimating = false
        })
        // AppKit builds the glass's inner layers after this turn; they must follow the morph too.
        let flightStart = CACurrentMediaTime()
        for delay in [0.0, 0.016, 0.05] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.animateGlassDescendants(from: sourceGlassInContent.size, start: flightStart,
                                              duration: duration)
            }
        }
    }

    /// Adds the source→target appearance animations without touching the model geometry
    /// (the model is already at the target).
    private func animateClipAppearance(from source: CGRect, radius sourceRadius: CGFloat,
                                        duration: TimeInterval) {
        let target = openedFolderClipView.frame
        let targetRadius = openedFolderClipView.cornerRadius
        // `NSGlassEffectView` only materialises its backing layer once it is on screen, so the
        // glass layer must not gate the clip animation: gating on it silently dropped the whole
        // morph (the panel then appeared at its final size with no grow animation).
        guard let layer = openedFolderClipView.layer else { return }

        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: CGRect(origin: layer.bounds.origin, size: source.size))
        bounds.toValue = NSValue(rect: CGRect(origin: layer.bounds.origin, size: target.size))
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: anchorPosition(for: source, in: layer))
        position.toValue = NSValue(point: anchorPosition(for: target, in: layer))
        let radius = CABasicAnimation(keyPath: "cornerRadius")
        radius.fromValue = sourceRadius
        radius.toValue = targetRadius
        for anim in [bounds, position, radius] {
            anim.duration = duration
            anim.timingFunction = DesignTokens.animationEaseInEaseOut
            layer.add(anim, forKey: "folder.clip.\(anim.keyPath ?? "")")
        }

        // The glass and its content sit at the model (target) size from the start; without their
        // own size animation the clip only crops them instead of scaling the panel.
        for view in [openedFolderBlurView as NSView, openedFolderGlassContentView] {
            guard let l = view.layer else { continue }
            let b = CABasicAnimation(keyPath: "bounds")
            b.fromValue = NSValue(rect: CGRect(origin: l.bounds.origin, size: source.size))
            b.toValue = NSValue(rect: l.bounds)
            let p = CABasicAnimation(keyPath: "position")
            p.fromValue = NSValue(point: CGPoint(x: source.width * l.anchorPoint.x,
                                                 y: source.height * l.anchorPoint.y))
            p.toValue = NSValue(point: l.position)
            for anim in [b, p] {
                anim.duration = duration
                anim.timingFunction = DesignTokens.animationEaseInEaseOut
                l.add(anim, forKey: "folder.glass.\(anim.keyPath ?? "")")
            }
        }

        if let blurLayer = openedFolderBlurView.layer {
            let blurRadius = CABasicAnimation(keyPath: "cornerRadius")
            blurRadius.fromValue = sourceRadius
            blurRadius.toValue = targetRadius
            blurRadius.duration = duration
            blurRadius.timingFunction = DesignTokens.animationEaseInEaseOut
            blurLayer.add(blurRadius, forKey: "folder.glass.cornerRadius")
        }
    }

    /// Flies the folder title between two frames with a fade.
    private func animateTitle(from source: CGRect, to target: CGRect, fadeTo: Float,
                              duration: TimeInterval) {
        guard let layer = openedFolderTitleLabel.layer else { return }
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: CGRect(origin: layer.bounds.origin, size: source.size))
        bounds.toValue = NSValue(rect: CGRect(origin: layer.bounds.origin, size: target.size))
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: anchorPosition(for: source, in: layer))
        position.toValue = NSValue(point: anchorPosition(for: target, in: layer))
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = layer.presentation()?.opacity ?? (fadeTo == 1 ? 0 : 1)
        opacity.toValue = fadeTo
        for anim in [bounds, position, opacity] {
            anim.duration = duration
            anim.timingFunction = DesignTokens.animationEaseInEaseOut
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        openedFolderTitleLabel.frame = target
        layer.opacity = fadeTo
        layer.add(bounds, forKey: "folder.title.bounds")
        layer.add(position, forKey: "folder.title.position")
        layer.add(opacity, forKey: "folder.title.opacity")
        CATransaction.commit()
    }

    // MARK: Proxies

    private func buildProxies(apps: [LaunchpadApp], slotsInContent: [CGRect],
                              host: FolderAnimationProxyHostView, opening: Bool) -> [FolderAnimationProxyLayer] {
        let cols = max(1, folderAppState.columns)
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let showTitle = !folderAppState.hideNames
        let visibleSlots = cols * max(1, folderAppState.rows)

        var proxies: [FolderAnimationProxyLayer] = []
        for (i, app) in apps.enumerated() {
            if i >= max(9, visibleSlots) { break }
            guard i < openedFolderAppViews.count else { break }
            let cellView = openedFolderAppViews[i]

            // Destination icon frame (window coords → content coords).
            // The real icon is the cell's `appView` (`itemSide` square), not the whole cell.
            // Cells are laid out lazily; read `appView.frame` only after its layout pass ran.
            cellView.layoutSubtreeIfNeeded()
            let iconSide = min(cellView.bounds.width, cellView.bounds.height)
            let dstIcon = cellView.convert(cellView.appView?.frame
                ?? CGRect(x: (cellView.bounds.width - iconSide) * 0.5,
                          y: (cellView.bounds.height - iconSide) * 0.5,
                          width: iconSide, height: iconSide), to: self)
            let srcIcon = slotsInContent.indices.contains(i) ? slotsInContent[i] : dstIcon
            // The label flies with the icon: destination-sized rect above the source
            // slot, landing on the cell's own title.
            let dstTitle = cellView.convert(cellView.titleFrameInView, to: self)
            let srcTitle = CGRect(x: srcIcon.midX - dstTitle.width * 0.5,
                                  y: srcIcon.minY - dstTitle.height * 0.85,
                                  width: dstTitle.width, height: dstTitle.height)

            let proxy = FolderAnimationProxyLayer(app: app, showTitle: showTitle,
                                              titleString: cellView.titleString, scale: scale)
            if opening {
                proxy.configureFlight(iconFrom: srcIcon, iconTo: dstIcon,
                                      titleFrom: srcTitle, titleTo: dstTitle,
                                      iconOpacityFrom: i <= 8 ? 1 : 0, iconOpacityTo: 1,
                                      titleOpacityFrom: 0, titleOpacityTo: 1)
            } else {
                proxy.configureFlight(iconFrom: dstIcon, iconTo: srcIcon,
                                      titleFrom: dstTitle, titleTo: srcTitle,
                                      iconOpacityFrom: 1, iconOpacityTo: i <= 8 ? 1 : 0,
                                      titleOpacityFrom: 1, titleOpacityTo: 0)
            }
            host.layer?.addSublayer(proxy)
            proxies.append(proxy)
        }
        return proxies
    }

    // MARK: Closing

    func closeFolder(animated: Bool, completion: (() -> Void)? = nil) {
        guard openedFolderID != nil, !openedFolderIsAnimating else { completion?(); return }
        endFolderTitleEdit(save: true)
        refreshFolderIconPreview()
        openedFolderIsAnimating = true

        guard let folderCell = openedFolderGroupView,
              let sourceGlassView = folderCell.folderView else {
            teardownOpenedFolder()
            openedFolderID = nil
            openedFolderGroupView = nil
            openedFolderIsAnimating = false
            fadeBaseContent(out: false, duration: 0.28)
            completion?()
            return
        }

        let sourceGlass = sourceGlassView.convert(sourceGlassView.glassFrameInView, to: self)
        let sourceRadius = sourceGlassView.glassCornerRadiusInView
        let slots = sourceGlassView.previewIconFrames(count: currentOpenedFolder?.apps.count ?? 0)
            .map { sourceGlassView.convert($0, to: self) }

        if !animated {
            fadeBaseContent(out: false, duration: 0.28)
            teardownOpenedFolder()
            openedFolderID = nil
            openedFolderGroupView = nil
            openedFolderIsAnimating = false
            completion?()
            return
        }

        let proxyHost = FolderAnimationProxyHostView(frame: bounds)
        proxyHost.autoresizingMask = [.width, .height]
        addSubview(proxyHost, positioned: .above, relativeTo: openedFolderClipView)
        let proxies = buildProxies(apps: currentOpenedFolder?.apps ?? [],
                                   slotsInContent: slots, host: proxyHost, opening: false)

        layoutSubtreeIfNeeded()
        fadeBaseContent(out: false, duration: 0.28)
        for view in openedFolderAppViews { view.alphaValue = 0 }

        // Model geometry → source; animate the appearance from the current (open) state.
        let currentFrame = openedFolderClipView.frame
        let currentRadius = openedFolderClipView.cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        openedFolderClipView.frame = sourceGlass
        openedFolderClipView.cornerRadius = sourceRadius
        openedFolderBlurView.layer?.cornerRadius = sourceRadius
        CATransaction.commit()

        let duration = 0.28
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = DesignTokens.animationEaseInEaseOut
            self.openedFolderBackdropView.animator().alphaValue = 0
            self.animateClipAppearance(from: currentFrame, radius: currentRadius, duration: duration)
            // The title flies back into the folder cell's own title slot and fades out.
            let sourceTitleFrame = folderCell.convert(folderCell.titleFrameInView, to: self)
            self.animateTitle(from: self.openedFolderTitleLabel.frame,
                              to: sourceTitleFrame, fadeTo: 0, duration: duration)

            self.openedFolderBackButton.animator().alphaValue = 0
            // The folder icon stays hidden for the whole flight and is revealed by the
            // teardown once the proxies have landed: fading it in *during* the flight
            // would show the preview under the still-flying icons (the folder looked off).
            for proxy in proxies { proxy.fly(duration: duration) }
        }, completionHandler: {
            proxyHost.removeFromSuperview()
            self.teardownOpenedFolder()
            self.openedFolderID = nil
            self.openedFolderGroupView = nil
            self.openedFolderIsAnimating = false
            completion?()
        })
    }

    /// Tears the overlay down without animation.
    func teardownOpenedFolder() {
        for view in openedFolderAppViews { view.removeFromSuperview() }
        openedFolderAppViews = []

        openedFolderBackdropView.alphaValue = 0
        openedFolderBackdropView.isHidden = true
        openedFolderClipView.alphaValue = 0
        openedFolderClipView.isHidden = true
        openedFolderClipView.frame = .zero
        openedFolderTitleLabel.alphaValue = 0
        openedFolderTitleLabel.isHidden = true
        openedFolderTitleLabel.frame = .zero
        openedFolderBackButton.alphaValue = 0
        openedFolderBackButton.isHidden = true
        endFolderTitleEdit(save: false)

        openedFolderScrollView.contentView.scroll(to: .zero)
        openedFolderGroupView?.alphaValue = 1
    }

    func refreshFolderIconPreview() {
        guard let cell = openedFolderGroupView,
              let folder = currentOpenedFolder else { return }
        cell.folderView?.configure(folder: folder)
    }

    // MARK: Title rename

    func beginFolderTitleEdit() {
        guard let folder = currentOpenedFolder, openedFolderTitleEditorView == nil else { return }
        let font = folderTitleFont
        let lineHeight = ceil(font.boundingRectForFont.height)
        let editor = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: lineHeight + 8))
        editor.font = font
        editor.alignment = .center
        editor.lineBreakMode = .byTruncatingTail
        editor.placeholderString = NSLocalizedString("Untitled", comment: "")
        editor.stringValue = folder.name
        editor.target = self
        editor.action = #selector(LaunchpadContentView.folderTitleEditDone)
        editor.isHidden = false
        addSubview(editor)
        openedFolderTitleEditorView = editor
        layoutFolderTitleEditor()
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)
    }

    private func layoutFolderTitleEditor() {
        guard let editor = openedFolderTitleEditorView else { return }
        let panel = openedFolderClipView.frame
        let font = folderTitleFont
        let h = ceil(font.boundingRectForFont.height) + 8
        let w = floor(max(panel.width - 12, 0))
        let titleFrame = openedFolderTitleFrame(name: " ", panelFrame: panel)
        let x = (openedFolderClipView.frame.midX - w * 0.5).rounded()
        let y = (titleFrame.minY - floor((h - titleFrame.height) / 2)).rounded()
        editor.frame = CGRect(x: x, y: y, width: w, height: h)
    }

    @objc func folderTitleEditDone() { endFolderTitleEdit(save: true) }

    func endFolderTitleEdit(save: Bool) {
        guard let editor = openedFolderTitleEditorView else { return }
        let value = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        openedFolderTitleEditorView = nil
        editor.removeFromSuperview()
        window?.makeFirstResponder(nil)
        guard save, let folder = currentOpenedFolder else { return }
        LaunchpadDataManager.shared.renameFolder(folder, name: value)
        openedFolderTitleLabel.setTitle(value.isEmpty ? NSLocalizedString("Untitled", comment: "") : value,
                                        font: folderTitleFont, fullscreen: !isWindowMode)
    }
}

// MARK: - Proxy flight

extension FolderAnimationProxyLayer {
    /// Local rect of a window/content rect inside this proxy's union frame.
    private func local(_ rect: CGRect, in union: CGRect) -> CGRect {
        CGRect(x: rect.minX - union.minX, y: rect.minY - union.minY,
               width: rect.width, height: rect.height)
    }

    func configureFlight(iconFrom: CGRect, iconTo: CGRect,
                         titleFrom: CGRect, titleTo: CGRect,
                         iconOpacityFrom: Float, iconOpacityTo: Float,
                         titleOpacityFrom: Float, titleOpacityTo: Float) {
        flight = Flight(iconFrom: iconFrom, iconTo: iconTo,
                        titleFrom: titleFrom, titleTo: titleTo,
                        iconOpacityFrom: iconOpacityFrom, iconOpacityTo: iconOpacityTo,
                        titleOpacityFrom: titleOpacityFrom, titleOpacityTo: titleOpacityTo)

        // The union of every stage hosts the flight; the model sits at the source, `fly` walks
        // it to the destination.
        let union = iconFrom.union(iconTo).union(titleFrom).union(titleTo).insetBy(dx: -24, dy: -24)
        frame = union
        position = CGPoint(x: union.midX, y: union.midY)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounds = CGRect(origin: .zero, size: union.size)
        iconLayer.frame = local(iconFrom, in: union)
        iconLayer.opacity = iconOpacityFrom
        if let title = titleLayer {
            title.frame = local(titleFrom, in: union)
            title.opacity = titleOpacityFrom
            title.isHidden = false
        }
        CATransaction.commit()
    }

    func fly(duration: TimeInterval) {
        guard let f = flight else { return }
        let union = frame

        let iconBounds = CABasicAnimation(keyPath: "bounds")
        iconBounds.fromValue = NSValue(rect: CGRect(origin: .zero, size: iconLayer.bounds.size))
        iconBounds.toValue = NSValue(rect: CGRect(origin: .zero, size: f.iconTo.size))
        let iconPosition = CABasicAnimation(keyPath: "position")
        iconPosition.fromValue = NSValue(point: iconLayer.position)
        iconPosition.toValue = NSValue(point: CGPoint(x: f.iconTo.midX - union.minX,
                                                      y: f.iconTo.midY - union.minY))
        let iconOpacity = CABasicAnimation(keyPath: "opacity")
        iconOpacity.fromValue = iconLayer.presentation()?.opacity ?? f.iconOpacityFrom
        iconOpacity.toValue = f.iconOpacityTo

        for anim in [iconBounds, iconPosition, iconOpacity] {
            anim.duration = duration
            anim.timingFunction = DesignTokens.animationEaseInEaseOut
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.frame = local(f.iconTo, in: union)
        iconLayer.opacity = f.iconOpacityTo
        iconLayer.add(iconBounds, forKey: "folder.proxy.icon.bounds")
        iconLayer.add(iconPosition, forKey: "folder.proxy.icon.position")
        iconLayer.add(iconOpacity, forKey: "folder.proxy.icon.opacity")
        if let title = titleLayer {
            let titleBounds = CABasicAnimation(keyPath: "bounds")
            titleBounds.fromValue = NSValue(rect: CGRect(origin: .zero, size: title.bounds.size))
            titleBounds.toValue = NSValue(rect: CGRect(origin: .zero, size: f.titleTo.size))
            let titlePosition = CABasicAnimation(keyPath: "position")
            titlePosition.fromValue = NSValue(point: title.position)
            titlePosition.toValue = NSValue(point: CGPoint(x: f.titleTo.midX - union.minX,
                                                           y: f.titleTo.midY - union.minY))
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = title.presentation()?.opacity ?? f.titleOpacityFrom
            fade.toValue = f.titleOpacityTo
            for anim in [titleBounds, titlePosition, fade] {
                anim.duration = duration
                anim.timingFunction = DesignTokens.animationEaseInEaseOut
            }
            title.frame = local(f.titleTo, in: union)
            title.opacity = f.titleOpacityTo
            title.add(titleBounds, forKey: "folder.proxy.title.bounds")
            title.add(titlePosition, forKey: "folder.proxy.title.position")
            title.add(fade, forKey: "folder.proxy.title.opacity")
        }
        CATransaction.commit()
    }
}


extension LaunchpadContentView {
    /// The glass material builds its inner layers (`SDFLayer`, …) lazily at their final size, so
    /// the clip morph only crops them. Gives every inner layer the same size animation, aligned
    /// to the clip's start time, so the material scales with the panel.
    func animateGlassDescendants(from sourceSize: CGSize, start: CFTimeInterval, duration: TimeInterval) {
        guard openedFolderIsAnimating, let root = openedFolderBlurView.layer else { return }
        let rootSize = root.bounds.size
        guard rootSize.width > 0, rootSize.height > 0 else { return }
        let rx = sourceSize.width / rootSize.width, ry = sourceSize.height / rootSize.height

        func walk(_ layer: CALayer) {
            for sub in layer.sublayers ?? [] {
                if sub.animation(forKey: "folder.glass.bounds") == nil {
                    let size = sub.bounds.size
                    let b = CABasicAnimation(keyPath: "bounds")
                    b.fromValue = NSValue(rect: CGRect(origin: sub.bounds.origin,
                                                       size: CGSize(width: size.width * rx, height: size.height * ry)))
                    b.toValue = NSValue(rect: sub.bounds)
                    let p = CABasicAnimation(keyPath: "position")
                    p.fromValue = NSValue(point: CGPoint(x: sub.position.x * rx, y: sub.position.y * ry))
                    p.toValue = NSValue(point: sub.position)
                    for anim in [b, p] {
                        anim.duration = duration
                        anim.timingFunction = DesignTokens.animationEaseInEaseOut
                        anim.beginTime = sub.convertTime(start, from: nil)
                        anim.fillMode = .backwards
                        sub.add(anim, forKey: "folder.glass.\(anim.keyPath ?? "")")
                    }
                }
                walk(sub)
            }
        }
        walk(root)
    }
}
