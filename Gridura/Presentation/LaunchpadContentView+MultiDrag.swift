import AppKit

// Multi-drag: several selected cells travel as one fanned stack with a count badge
//. Paged mode, custom sort for re-ordering; merging into a folder works in
// custom and name sort.

/// Container for the cards and the badge; never takes mouse events.
final class DragOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One card of the stack: an icon preview that can be rotated about its centre.
final class LaunchpadDragCardView: NSView {
    let preview: NSView

    init(preview: NSView) {
        self.preview = preview
        super.init(frame: preview.frame)
        wantsLayer = true
        layer?.masksToBounds = false
        preview.frame = bounds
        preview.autoresizingMask = [.width, .height]
        addSubview(preview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `translate(mid) · rotate(angle) · translate(-mid)` as `sublayerTransform`.
    func setRotation(_ degrees: CGFloat, animated: Bool) {
        guard let layer else { return }
        let midX = bounds.midX, midY = bounds.midY
        var transform = CATransform3DMakeTranslation(midX, midY, 0)
        transform = CATransform3DRotate(transform, degrees * .pi / 180, 0, 0, 1)
        transform = CATransform3DTranslate(transform, -midX, -midY, 0)
        if animated {
            let animation = CABasicAnimation(keyPath: "sublayerTransform")
            animation.fromValue = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
            animation.toValue = transform
            animation.duration = 0.28
            animation.timingFunction = launchpadTimingFunction
            layer.add(animation, forKey: "rotation")
        }
        layer.sublayerTransform = transform
    }
}

/// The red count capsule on the stack's top-right corner.
final class LaunchpadDragCountBadge: NSView {
    let count: Int
    private let text: NSAttributedString

    init(count: Int) {
        self.count = count
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        text = NSAttributedString(string: "\(count)", attributes: [.font: font, .foregroundColor: NSColor.white])
        let textWidth = text.size().width
        super.init(frame: CGRect(x: 0, y: 0, width: max(CGFloat(Int(textWidth)) + 14, 24), height: 24))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.systemRed.setFill()
        capsule.fill()
        let inner = bounds.insetBy(dx: 0.5, dy: 0.5)
        let stroke = NSBezierPath(roundedRect: inner, xRadius: (bounds.height - 1) / 2, yRadius: (bounds.height - 1) / 2)
        NSColor.white.withAlphaComponent(0.6).setStroke()
        stroke.lineWidth = 1
        stroke.stroke()
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

/// State of one multi-drag (`LaunchpadMultiDrag`).
final class LaunchpadMultiDrag {
    struct Gather {
        var card: LaunchpadDragCardView
        var start: CGRect
        var target: CGRect
        var startAlpha: CGFloat
        var endAlpha: CGFloat
    }

    let sources: [LaunchpadGroupView]
    let originalPage: Int
    let originalPages: [[LaunchpadGroupView]]
    let overlay: DragOverlayView
    let badge: LaunchpadDragCountBadge
    var cards: [(card: LaunchpadDragCardView, source: LaunchpadGroupView)] = []
    var gatherStarted: CFTimeInterval = 0
    var gathering: [Gather] = []
    var lastSortPoint: CGPoint = CGPoint(x: -1000, y: -1000)
    var lastSortPage = -1
    var hoverStarted: CFTimeInterval = 0
    var hoverDestination: Int?
    var folderCandidate: LaunchpadGroupView?
    var candidateKey: String?
    var candidateWork: DispatchWorkItem?

    init(sources: [LaunchpadGroupView], originalPage: Int, originalPages: [[LaunchpadGroupView]],
         overlay: DragOverlayView, badge: LaunchpadDragCountBadge) {
        self.sources = sources
        self.originalPage = originalPage
        self.originalPages = originalPages
        self.overlay = overlay
        self.badge = badge
    }
}

extension LaunchpadContentView {
    /// Stack layout per depth: (dx × width, dy × height, rotation°).
    private static let stackLayout: [(dx: CGFloat, dy: CGFloat, rotation: CGFloat)] = [
        (0, 0, 0), (-0.035, 0.035, 7), (0.045, 0.065, -8), (-0.015, 0.095, 11),
    ]
    private static let gatherDuration: CFTimeInterval = 0.28

    // MARK: Start

    func beginMultiDrag(_ session: LaunchpadDragSession) {
        let sources = selectedGroups.compactMap { groupViews[$0.id] }
        guard sources.count >= 2 else { return }

        let size = session.preview.frame.size
        let overlay = DragOverlayView(frame: session.preview.frame)
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = false
        session.preview.removeFromSuperview()
        addSubview(overlay, positioned: .above, relativeTo: nil)
        session.preview = overlay

        let badge = LaunchpadDragCountBadge(count: sources.count)
        let multi = LaunchpadMultiDrag(sources: sources, originalPage: dragPage,
                                       originalPages: session.pages, overlay: overlay, badge: badge)

        let count = sources.count
        for (index, source) in sources.enumerated() {
            let depthIndex = count - 1 - index
            let layout = Self.stackLayout[min(depthIndex, 3)]
            let target = CGRect(x: layout.dx * size.width, y: -layout.dy * size.height,
                                width: size.width, height: size.height)
            let endAlpha: CGFloat = depthIndex > 3 ? 0 : 1

            let previewFrame = convert(source.iconContentFrame, from: source)
            guard let preview = makeDragPreview(for: source, frame: CGRect(origin: .zero, size: previewFrame.size)) else { continue }
            let card = LaunchpadDragCardView(preview: preview)
            overlay.addSubview(card)

            if source === session.source {
                card.frame = target
                card.alphaValue = endAlpha
            } else {
                let start = overlay.convert(previewFrame, from: self)
                let visible = previewFrame.intersects(bounds)
                card.frame = start
                card.alphaValue = visible ? 1 : 0
                multi.gathering.append(.init(card: card, start: start, target: target,
                                             startAlpha: visible ? 1 : 0, endAlpha: endAlpha))
            }
            card.setRotation(layout.rotation, animated: true)
            multi.cards.append((card, source))
            source.isDragging = true
        }

        badge.frame.origin = CGPoint(x: overlay.bounds.maxX - badge.frame.width * 0.55,
                                     y: overlay.bounds.maxY - badge.frame.height * 0.5)
        overlay.addSubview(badge)
        multi.gatherStarted = CACurrentMediaTime()
        session.multi = multi
    }

    // MARK: Gather animation

    func stepGather() {
        guard let multi = drag?.multi, !multi.gathering.isEmpty else { return }
        let t = min(max((CACurrentMediaTime() - multi.gatherStarted) / Self.gatherDuration, 0), 1)
        let e = CGFloat(1 - pow(1 - t, 3))          // cubic ease-out
        for item in multi.gathering {
            item.card.frame = CGRect(x: item.start.minX + (item.target.minX - item.start.minX) * e,
                                     y: item.start.minY + (item.target.minY - item.start.minY) * e,
                                     width: item.start.width + (item.target.width - item.start.width) * e,
                                     height: item.start.height + (item.target.height - item.start.height) * e)
            item.card.alphaValue = item.startAlpha + e * (item.endAlpha - item.startAlpha)
        }
        if t >= 1 { multi.gathering = [] }
    }

    // MARK: Targeting / paging

    func updateMultiTarget(_ mouse: CGPoint) {
        guard let session = drag, let multi = session.multi else { return }
        let now = CACurrentMediaTime()

        // Page hover: 28 pt edge zones or the page-indicator dots; 0.6 s to flip.
        var destination: Int?
        if appState.browsingStyle == .paged, !isWindowMode {
            if mouse.y >= safeFrame.minY && mouse.y <= safeFrame.maxY {
                if mouse.x <= bounds.minX + 28 { destination = currentPage - 1 }
                else if mouse.x >= bounds.maxX - 28 { destination = currentPage + 1 }
            }
            if let dot = pageIndicatorView.pageIndex(at: pageIndicatorView.convert(mouse, from: self)) { destination = dot }
        }
        if let dest = destination, dest != currentPage, dest >= 0,
           dest < session.pages.count || (dest == session.pages.count && appState.sortBy == .custom) {
            if multi.hoverDestination != dest {
                multi.hoverDestination = dest
                multi.hoverStarted = now
            } else if now - multi.hoverStarted >= 0.6 {
                moveStack(toPage: dest)
                setPage(dest, animated: true)
                multi.hoverStarted = now
            }
        } else {
            multi.hoverDestination = nil
        }

        guard session.pages.indices.contains(dragPage) else { return }
        let sourceSet = multi.sources
        let rest = session.pages[dragPage].filter { cell in !sourceSet.contains(where: { $0 === cell }) }

        // Folder candidate: hovering over another cell's icon.
        let overCell = rest.first { cell in
            !cell.isHidden && cell.iconContentFrame.contains(cell.convert(mouse, from: self))
        }
        let allowMerge = sourceSet.allSatisfy { $0.group?.isFolder == false }
            && (appState.sortBy == .custom || appState.sortBy == .name)
        if let over = overCell, allowMerge {
            setFolderCandidate(over, multi: multi)
            return
        }
        setFolderCandidate(nil, multi: multi)

        // Re-sort the stack when the pointer moved ≥ 4 pt or the page changed (custom sort).
        guard appState.sortBy == .custom, dataManager.currentSearchQuery.isEmpty else { return }
        let moved = hypot(mouse.x - multi.lastSortPoint.x, mouse.y - multi.lastSortPoint.y)
        guard moved >= 4 || multi.lastSortPage != dragPage else { return }
        multi.lastSortPoint = mouse
        multi.lastSortPage = dragPage
        resortStack(rest: rest, mouse: mouse)
    }

    private func setFolderCandidate(_ cell: LaunchpadGroupView?, multi: LaunchpadMultiDrag) {
        guard let cell else {
            multi.candidateWork?.cancel()
            multi.candidateKey = nil
            multi.folderCandidate?.isDraggingMerge = false
            multi.folderCandidate = nil
            return
        }
        let key = cell.group?.id ?? ""
        guard multi.candidateKey != key else { return }
        multi.candidateWork?.cancel()
        multi.candidateKey = key
        multi.folderCandidate?.isDraggingMerge = false
        multi.folderCandidate = nil
        let work = DispatchWorkItem { [weak multi, weak cell] in
            guard let multi, let cell, multi.candidateKey == key else { return }
            cell.isDraggingMerge = true
            multi.folderCandidate = cell
        }
        multi.candidateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Insertion index from the pointer: the row containing y, then the first cell whose midX ≥ x.
    private func resortStack(rest: [LaunchpadGroupView], mouse: CGPoint) {
        guard let session = drag, let multi = session.multi, let parent = dragParent(dragPage) else { return }
        let columns = appState.columns
        let point = parent.convert(mouse, from: self)

        var index = rest.count
        let rows = max(1, Int(ceil(Double(max(rest.count, 1)) / Double(columns))))
        var matchedRow: Int?
        for row in 0..<rows {
            let frame = dragSlotFrame(row * columns)
            if point.y >= frame.minY && point.y <= frame.maxY { matchedRow = row; break }
        }
        if let row = matchedRow {
            let start = row * columns
            let end = min(start + columns, rest.count)
            index = end
            for i in start..<max(end, start) where dragSlotFrame(i).midX >= point.x { index = i; break }
        } else {
            // Above the first row (visually) → front; below the last row → end.
            let first = dragSlotFrame(0)
            let aboveFirst = parent.isFlipped ? point.y < first.minY : point.y > first.maxY
            if aboveFirst { index = 0 }
        }

        var list = rest
        list.insert(contentsOf: multi.sources, at: min(index, list.count))
        let current = session.pages[dragPage]
        guard !(current.count == list.count && zip(current, list).allSatisfy({ $0 === $1 })) else { return }
        session.pages[dragPage] = list
        layoutDragPages(animated: true)
    }

    /// Carries the stack to another page.
    private func moveStack(toPage page: Int) {
        guard let session = drag, let multi = session.multi else { return }
        if page == session.pages.count { appendDragPage() }
        guard session.pages.indices.contains(page) else { return }
        for index in session.pages.indices {
            session.pages[index].removeAll { cell in multi.sources.contains(where: { $0 === cell }) }
        }
        session.pages[page].append(contentsOf: multi.sources)
        multi.lastSortPage = -1
        layoutDragPages(animated: true)
    }

    // MARK: Drop

    func endMultiDrag(cancelled: Bool) {
        guard let session = drag, let multi = session.multi else { return }
        multi.candidateWork?.cancel()
        var cancel = cancelled

        let candidate = multi.folderCandidate
        if !cancel && candidate == nil && appState.sortBy != .custom {
            ToastManager.shared.show(type: .info,
                                     message: NSLocalizedString("Dragging to reorder is only available in Custom sort mode.", comment: ""),
                                     duration: 3)
            cancel = true
        }

        if cancel {
            setFolderCandidate(nil, multi: multi)
            session.pages = multi.originalPages
            layoutDragPages(animated: true)
            if !isScrollLayout, currentPage != multi.originalPage { setPage(multi.originalPage, animated: false) }
            flyCards(toSources: true) { [weak self] in self?.finishMultiDrag(commit: nil) }
            return
        }

        if let target = candidate, let targetGroup = target.group {
            let apps = multi.sources.compactMap { $0.group?.apps }.flatMap { $0 }
            let frame = overlayFrame(forScreenRect: convert(target.iconContentFrame, from: target), in: multi)
            flyCards(to: frame, fade: true) { [weak self] in
                self?.finishMultiDrag(commit: .merge(target: targetGroup, apps: apps))
            }
            return
        }

        layoutDragPages(animated: true)
        flyCards(toSources: true) { [weak self] in self?.finishMultiDrag(commit: .reorder) }
    }

    private enum MultiCommit {
        case reorder
        case merge(target: LaunchpadGroup, apps: [LaunchpadApp])
    }

    private func overlayFrame(forScreenRect rect: CGRect, in multi: LaunchpadMultiDrag) -> CGRect {
        multi.overlay.convert(rect, from: self)
    }

    /// Cards fly to their cells' icon frames (0.28 s `T_spring`), rotation → 0.
    private func flyCards(toSources: Bool, completion: @escaping () -> Void) {
        guard let multi = drag?.multi else { completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        for (card, source) in multi.cards {
            let target = overlayFrame(forScreenRect: convert(source.iconContentFrame, from: source), in: multi)
            flyCard(card, to: target, alpha: 1)
            card.setRotation(0, animated: true)
        }
        CATransaction.commit()
    }

    private func flyCards(to frame: CGRect, fade: Bool, completion: @escaping () -> Void) {
        guard let multi = drag?.multi else { completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        for (card, _) in multi.cards {
            flyCard(card, to: frame, alpha: fade ? 0 : 1)
            card.setRotation(0, animated: true)
        }
        CATransaction.commit()
    }

    private func flyCard(_ card: NSView, to frame: CGRect, alpha: CGFloat) {
        guard let layer = card.layer else { card.frame = frame; return }
        let from = layer.presentation()?.position ?? layer.position
        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.frame = frame
        layer.opacity = Float(alpha)
        CATransaction.commit()

        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: from)
        position.toValue = NSValue(point: layer.position)
        position.duration = 0.28
        position.timingFunction = launchpadTimingFunction
        layer.add(position, forKey: "multi.fly.position")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = Float(alpha)
        fade.duration = 0.28
        fade.timingFunction = launchpadTimingFunction
        layer.add(fade, forKey: "multi.fly.opacity")
    }

    private func finishMultiDrag(commit: MultiCommit?) {
        guard let session = drag, let multi = session.multi else { return }
        multi.overlay.removeFromSuperview()
        for source in multi.sources { source.isDragging = false }
        multi.folderCandidate?.isDraggingMerge = false
        drag = nil

        switch commit {
        case .none:
            break
        case .reorder:
            clearAllHighlights()
            dataManager.commitOrder(pages: dragCommitLists(session))
        case .merge(let target, let apps):
            clearAllHighlights()
            if !target.isFolder { target.name = NSLocalizedString("Untitled", comment: "") }
            dataManager.moveApps(apps, intoFolder: target)
        }
    }
}
