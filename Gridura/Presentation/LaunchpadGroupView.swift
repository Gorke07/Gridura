import AppKit

/// One grid cell: an app or a folder, with title, jiggle animation and rename editor
///.
final class LaunchpadGroupView: NSView, NSTextFieldDelegate {
    // Nested layer containers so jiggle rotation and bounce compose.
    private let jiggleBounceContainerView = NSView()
    private let jiggleContainerView = NSView()
    private let titleLayer = NonAnimatingTextLayer()

    private(set) var appView: LaunchpadAppView?
    private(set) var folderView: LaunchpadFolderView?
    private var titleEditorView: NSTextField?

    var group: LaunchpadGroup?
    var itemSide: CGFloat = 74

    // Callbacks wired by the content view.
    var onActivate: ((LaunchpadGroup) -> Void)?
    var onLongPress: ((LaunchpadGroup) -> Void)?
    /// The ✕ of an app in uninstall mode was clicked.
    var onUninstallRequest: ((LaunchpadGroup) -> Void)?
    var onRename: ((LaunchpadGroup, String) -> Void)?
    var onDragBegan: ((LaunchpadGroup, NSEvent, CGPoint) -> Void)?
    var menuProvider: ((LaunchpadGroup) -> NSMenu?)?

    private var isPressed = false
    private var mouseDownPoint: NSPoint = .zero
    private var longPressWorkItem: DispatchWorkItem?
    private var isEditingTitle = false

    private let variant: Int

    init(variant: Int) {
        self.variant = variant
        super.init(frame: .zero)
        wantsLayer = true

        jiggleBounceContainerView.wantsLayer = true
        jiggleContainerView.wantsLayer = true
        jiggleBounceContainerView.layer?.anchorPoint = CGPoint(x: 0, y: 0)
        jiggleContainerView.layer?.anchorPoint = CGPoint(x: 0, y: 0)
        jiggleBounceContainerView.autoresizingMask = [.width, .height]
        jiggleContainerView.autoresizingMask = [.width, .height]
        addSubview(jiggleBounceContainerView)
        jiggleBounceContainerView.addSubview(jiggleContainerView)
        layer?.addSublayer(titleLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Configuration

    private var contentSignature = ""

    private static func signature(of group: LaunchpadGroup) -> String {
        "\(group.isFolder)|\(group.name)|" + group.apps.map { "\($0.id)=\($0.alias)" }.joined(separator: ",")
    }

    /// Reused cells (content-only reloads) pick up renames and folder membership changes here.
    func syncIfNeeded(with group: LaunchpadGroup, hideNames: Bool) {
        guard Self.signature(of: group) != contentSignature, !isEditing, !isDragging else { return }
        configure(with: group, hideNames: hideNames)
    }

    func configure(with group: LaunchpadGroup, hideNames: Bool) {
        contentSignature = Self.signature(of: group)
        self.group = group
        appView?.removeFromSuperview()
        folderView?.removeFromSuperview()
        appView = nil
        folderView = nil

        if group.isFolder {
            let view = LaunchpadFolderView()
            view.variant = variant
            jiggleContainerView.addSubview(view)
            folderView = view
            view.configure(folder: group)
        } else if let app = group.apps.first {
            let view = LaunchpadAppView(variant: variant)
            view.onUninstall = { [weak self] in
                guard let self, let g = self.group else { return }
                self.onUninstallRequest?(g)
            }
            jiggleContainerView.addSubview(view)
            appView = view
            view.configure(app: app)
        }
        updateTitle(hideNames: hideNames)
        needsLayout = true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        jiggleBounceContainerView.frame = bounds
        jiggleContainerView.frame = bounds
        jiggleBounceContainerView.layer?.position = bounds.origin
        jiggleContainerView.layer?.position = bounds.origin

        let fontH = DesignTokens.labelFontHeight
        let hideNames = AppState.shared.hideNames
        let labelBlock: CGFloat = (hideNames && !isEditingTitle) ? 0 : fontH + 8
        let top = max(floor((bounds.height - (labelBlock + itemSide)) * 0.5), 0)

        let contentFrame = CGRect(x: floor((bounds.width - itemSide) * 0.5),
                                  y: labelBlock + top, width: itemSide, height: itemSide)
        appView?.frame = contentFrame
        folderView?.frame = contentFrame

        let titleWidth = max(bounds.width - 12, 0)
        titleLayer.frame = CGRect(x: 6, y: floor((labelBlock - fontH) * 0.5) + top,
                                  width: titleWidth, height: labelBlock == 0 ? 0 : fontH)
        titleEditorView?.frame = titleEditorFrame(label: CGRect(x: 6, y: top, width: titleWidth, height: labelBlock))

        withoutActions { titleLayer.transform = CATransform3DIdentity }
        refreshTitleText()
    }

    /// The title layer's frame in this view's coordinates — the source/target rect for the
    /// folder open/close title flight.
    var titleFrameInView: CGRect { titleLayer.frame }

    /// The icon content frame in this view's coordinates (the drag source/target rect).
    var iconContentFrame: CGRect { contentViewFrame() ?? bounds }

    /// The cell is hidden (alpha 0) while its floating preview is being dragged.
    var isDragging = false {
        didSet { alphaValue = isDragging ? 0 : 1 }
    }

    /// The styled title string, so flight proxies render exactly like the cell's own title.
    var titleString: Any? { titleLayer.string }

    // MARK: - Title

    private func updateTitle(hideNames: Bool) {
        guard let group else { return }
        let text = displayText(for: group)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let string = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: string.length)
        if isDark {
            string.addAttribute(.font, value: DesignTokens.labelFont, range: range)
            string.addAttribute(.foregroundColor, value: NSColor.white, range: range)
            string.addAttribute(.shadow, value: DesignTokens.labelShadow, range: range)
        } else {
            string.addAttribute(.font, value: DesignTokens.labelFontLight, range: range)
            string.addAttribute(.foregroundColor, value: NSColor.black.withAlphaComponent(0.85), range: range)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        // Truncation is the layer's job (`truncationMode = .end`): a truncating paragraph style makes
        // CATextLayer draw nothing at all for names wider than the cell.
        string.addAttribute(.paragraphStyle, value: paragraph, range: range)
        fullTitle = string
        withoutActions {
            titleLayer.isHidden = hideNames || isEditingTitle
        }
        truncatedForWidth = -1                            // new text: never skip the refit for an unchanged width
        refreshTitleText()
    }

    /// The untruncated, styled title.
    private var fullTitle: NSAttributedString?
    private var truncatedForWidth: CGFloat = -1

    /// Fits the title into the label width with a trailing "…". `CATextLayer`'s own truncation draws
    /// nothing at all when a name is wider than the cell (seen in window mode), so it is done here.
    private func refreshTitleText() {
        guard let full = fullTitle else { return }
        let width = titleLayer.bounds.width
        if width <= 0 {                                   // not laid out yet: show it whole
            withoutActions { titleLayer.string = full }
            truncatedForWidth = -1
            return
        }
        guard width != truncatedForWidth || (titleLayer.string as? NSAttributedString)?.string.hasSuffix("…") == nil else { return }
        truncatedForWidth = width
        var result = full
        if ceil(full.size().width) > width, full.length > 1 {
            let attributes = full.attributes(at: 0, effectiveRange: nil)
            let ellipsis = NSAttributedString(string: "…", attributes: attributes)
            var low = 0, high = full.length
            while low < high {                            // longest prefix that still fits with the ellipsis
                let mid = (low + high + 1) / 2
                let candidate = NSMutableAttributedString(attributedString: full.attributedSubstring(from: NSRange(location: 0, length: mid)))
                candidate.append(ellipsis)
                if ceil(candidate.size().width) <= width { low = mid } else { high = mid - 1 }
            }
            let prefix = NSMutableAttributedString(attributedString: full.attributedSubstring(from: NSRange(location: 0, length: low)))
            result = NSMutableAttributedString(attributedString: prefix)
            (result as! NSMutableAttributedString).append(ellipsis)
        }
        withoutActions { titleLayer.string = result }
    }

    private func displayText(for group: LaunchpadGroup) -> String {
        group.displayName
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTitle(hideNames: AppState.shared.hideNames)
    }

    // MARK: - State propagation

    var isHighlight: Bool = false {
        didSet {
            appView?.isHighlight = isHighlight
            folderView?.isHighlight = isHighlight
        }
    }

    var isDraggingMerge: Bool = false {
        didSet {
            appView?.isDraggingMerge = isDraggingMerge
            folderView?.isDraggingMerge = isDraggingMerge
        }
    }

    var isUninstallMode: Bool = false {
        didSet {
            appView?.isUninstallMode = isUninstallMode
            if isUninstallMode {
                startJiggle()
                if group?.isFolder == true { folderView?.layer?.removeAllAnimations() }
            } else {
                stopJiggle()
            }
        }
    }

    // MARK: - Jiggle

    private let jiggleRotationKey = "gridura.uninstall.jiggle.rotation"
    private let jiggleBounceKey = "gridura.uninstall.jiggle.bounce"

    func startJiggle() {
        guard let container = jiggleContainerView.layer, let bounce = jiggleBounceContainerView.layer else { return }
        guard container.animation(forKey: jiggleRotationKey) == nil else { return }
        let r1 = Double.random(in: 0...1)
        let r2 = Double.random(in: 0...1)
        let begin = CACurrentMediaTime() + r1 * 0.03

        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        let angle = 0.024 + r2 * 0.006
        func transform(_ a: CGFloat) -> CATransform3D {
            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, mid.x, mid.y, 0)
            t = CATransform3DRotate(t, a, 0, 0, 1)
            t = CATransform3DTranslate(t, -mid.x, -mid.y, 0)
            return t
        }
        let rotation = CAKeyframeAnimation(keyPath: "transform")
        rotation.values = [transform(-angle), transform(angle)]
        rotation.autoreverses = true
        rotation.duration = 0.105 + r1 * 0.02
        rotation.repeatCount = .infinity
        rotation.timingFunction = DesignTokens.animationEaseInEaseOut
        rotation.isRemovedOnCompletion = false
        rotation.beginTime = begin
        container.add(rotation, forKey: jiggleRotationKey)

        let amplitude = 0.8 + r2 * 0.6
        let bounceAnimation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounceAnimation.values = [amplitude, -amplitude]
        bounceAnimation.autoreverses = true
        bounceAnimation.duration = 0.12 + r2 * 0.025
        bounceAnimation.repeatCount = .infinity
        bounceAnimation.timingFunction = DesignTokens.animationEaseInEaseOut
        bounceAnimation.isRemovedOnCompletion = false
        bounceAnimation.beginTime = begin
        bounce.add(bounceAnimation, forKey: jiggleBounceKey)
    }

    func stopJiggle() {
        withoutActions {
            jiggleContainerView.layer?.removeAnimation(forKey: jiggleRotationKey)
            jiggleBounceContainerView.layer?.removeAnimation(forKey: jiggleBounceKey)
            jiggleContainerView.layer?.transform = CATransform3DIdentity
            jiggleBounceContainerView.layer?.transform = CATransform3DIdentity
        }
    }

    // MARK: - Mouse handling

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Only the icon (plus a little slack for the ✕ badge) and the title text belong to the cell; the rest of
    /// its slot is empty grid space, so clicks and drags there reach the grid (close / page swipe / menu).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if isEditingTitle { return super.hitTest(point) }
        if iconContentFrame.insetBy(dx: -8, dy: -8).contains(local) { return super.hitTest(point) }
        if !AppState.shared.hideNames, titleTextRect().insetBy(dx: -4, dy: -4).contains(local) { return super.hitTest(point) }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard group != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Control-click behaves as a right click (shows the context menu)
        if modifiers.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        if modifiers == .command, let content = contentViewFrame(), content.contains(point) {
            isHighlight.toggle()
            return
        }

        // Click on the title text → inline rename
        if !isEditingTitle, !AppState.shared.hideNames, titleTextRect().contains(point) {
            beginRename()
            return
        }

        let content = contentViewFrame()
        if let content, content.contains(point) {
            isPressed = true
            appView?.isPressed = true
            if !isUninstallMode {
                scheduleLongPress()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
        if isPressed && distance >= 4 {
            cancelLongPress()
            if let group {
                // Grab offset inside the icon content, clamped to it.
                let c = contentViewFrame() ?? bounds
                let offset = CGPoint(x: min(max(mouseDownPoint.x - c.minX, 0), c.width),
                                     y: min(max(mouseDownPoint.y - c.minY, 0), c.height))
                onDragBegan?(group, event, offset)
            }
            isPressed = false
            appView?.isPressed = false
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false; appView?.isPressed = false }
        cancelLongPress()
        guard isPressed, let group else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let content = contentViewFrame(), content.contains(point) {
            onActivate?(group)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let group, let menu = menuProvider?(group) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let group else { return nil }
        return menuProvider?(group)
    }

    func contentViewFrame() -> CGRect? {
        appView?.frame ?? folderView?.frame
    }

    private func scheduleLongPress() {
        cancelLongPress()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isPressed, let group = self.group else { return }
            self.isPressed = false
            self.appView?.isPressed = false
            self.onLongPress?(group)
        }
        longPressWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: item)
    }

    private func cancelLongPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
    }

    // MARK: - Rename

    /// The title text's rectangle: its width clipped to the label, centred, slightly inset.
    private func titleTextRect() -> CGRect {
        guard let text = titleLayer.string as? NSAttributedString else { return .zero }
        let frame = titleLayer.frame
        let width = min(ceil(text.size().width), frame.width)
        return CGRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: frame.height)
            .insetBy(dx: -2, dy: -1)
    }

    /// Editor frame: min(cell width, text width + padding), centred on the label.
    private func titleEditorFrame(label: CGRect) -> CGRect {
        let textWidth = ((titleEditorView?.stringValue ?? "") as NSString)
            .size(withAttributes: [.font: DesignTokens.labelFont]).width
        let width = min(bounds.width, ceil(textWidth) + 24)
        return CGRect(x: (bounds.width - width) / 2, y: label.minY, width: width, height: label.height)
    }

    func beginRename() {
        guard let group, titleEditorView == nil else { return }
        isEditingTitle = true
        let editor = NSTextField()
        editor.stringValue = displayText(for: group)
        editor.isBordered = false
        editor.drawsBackground = true
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        editor.backgroundColor = dark ? NSColor.white.withAlphaComponent(0.2) : NSColor.black.withAlphaComponent(0.06)
        editor.focusRingType = .none
        editor.alignment = .center
        editor.font = DesignTokens.labelFont
        editor.textColor = .labelColor
        editor.lineBreakMode = .byClipping
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 8
        editor.target = self
        editor.action = #selector(commitRename)
        editor.delegate = self
        editor.usesSingleLineMode = true
        addSubview(editor)
        titleEditorView = editor
        updateTitle(hideNames: false)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(editor)
    }

    @objc private func commitRename() {
        guard let group, let editor = titleEditorView else { return }
        let value = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        endRename()
        onRename?(group, value)
    }

    func cancelRename() {
        endRename()
    }

    private func endRename() {
        isEditingTitle = false
        // Clear the reference first: removing the editor ends its editing and would re-enter commit.
        let editor = titleEditorView
        titleEditorView = nil
        editor?.removeFromSuperview()
        updateTitle(hideNames: AppState.shared.hideNames)
        needsLayout = true
    }

    var isEditing: Bool { isEditingTitle }

    // MARK: - Helpers

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    func reloadTitle(hideNames: Bool) { updateTitle(hideNames: hideNames) }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { needsLayout = true }

    /// Ending the edit (Return, or clicking elsewhere) commits.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard titleEditorView != nil else { return }
        commitRename()
    }

    /// Esc restores the old name.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelRename()
        return true
    }
}
