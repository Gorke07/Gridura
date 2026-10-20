import AppKit

// Single-item drag & drop on the paged grid and inside an opened folder.
// Multi-drag lives in +MultiDrag; the Dock hand-off and scroll mode are separate stages.

enum DragDropAction: Equatable {
    case insertBefore, insertAfter, merge, moveToEnd
}

enum DragEdgeZone {
    case none, left, right
}

/// All state of one in-flight drag (`LaunchpadDraggingItem`).
final class LaunchpadDragSession {
    var source: LaunchpadGroupView
    var preview: NSView
    let offset: CGPoint
    let startPage: Int
    /// The page lists being rearranged; the model is only written on drop.
    var pages: [[LaunchpadGroupView]]
    var target: LaunchpadGroupView?
    var link: CADisplayLink?
    var pendingKey: String?
    var pendingWork: DispatchWorkItem?
    var edgeZone: DragEdgeZone = .none
    var edgeStart: CFTimeInterval = 0
    var ended = false
    /// True for scripted drags (self-tests): no real pointer, no Dock hand-off.
    var isSynthetic = false
    /// Set when several selected cells are dragged as one stack.
    var multi: LaunchpadMultiDrag?
    /// Transparent window hosting the preview once it left the main window.
    var overlayWindow: NSWindow?
    /// The real AppKit drag started over the Dock so it can accept the app.
    var dockSession: NSDraggingSession?
    /// The opened folder's cells (in their dragged order) while the drag started inside a folder.
    var folderCells: [LaunchpadGroupView]?
    /// Folder the dragged app came out of (`LaunchpadDraggingItem.folderId`) or is dragged in.
    var folderID: String?

    init(source: LaunchpadGroupView, preview: NSView, offset: CGPoint, startPage: Int,
         pages: [[LaunchpadGroupView]]) {
        self.source = source
        self.preview = preview
        self.offset = offset
        self.startPage = startPage
        self.pages = pages
    }
}

extension LaunchpadContentView {
    /// `dropActionHoverDelay`.
    private static let dropActionHoverDelay: TimeInterval = 0.1
    /// `edgeHoverThreshold`.
    private static let edgeHoverThreshold: CFTimeInterval = 0.6
    private static let layoutDuration: TimeInterval = 0.36

    // MARK: Layout abstraction (paged pages vs. the scroll list)

    var isScrollLayout: Bool { appState.browsingStyle == .scroll }
    /// Index of the list the drag works on: the current page, or the single scroll list.
    var dragPage: Int { isScrollLayout ? 0 : currentPage }
    var dragCapacity: Int { isScrollLayout ? Int.max : max(1, appState.perPage) }

    func dragParent(_ page: Int) -> NSView? {
        isScrollLayout ? scrollDocumentView : (pageViews.indices.contains(page) ? pageViews[page] : nil)
    }

    func dragSlotFrame(_ index: Int) -> CGRect {
        isScrollLayout ? scrollSlotFrame(index) : slotFrame(index)
    }

    /// The lists to persist: pages as dragged, or the scroll list cut into pages.
    func dragCommitLists(_ session: LaunchpadDragSession) -> [[LaunchpadGroup]] {
        let lists = session.pages.map { $0.compactMap(\.group) }
        guard isScrollLayout, let all = lists.first else { return lists }
        let perPage = max(1, appState.perPage)
        return stride(from: 0, to: all.count, by: perPage).map { Array(all[$0..<min($0 + perPage, all.count)]) }
    }

    // MARK: Begin

    func beginDrag(group: LaunchpadGroup, event: NSEvent, offset: CGPoint) {
        let folderCell = openedFolderID != nil
            ? openedFolderAppViews.first { $0.group?.id == group.id } : nil
        guard drag == nil, dataManager.currentSearchQuery.isEmpty,
              openedFolderID == nil || folderCell != nil,
              let cell = folderCell ?? groupViews[group.id],
              isScrollLayout || pageViews.indices.contains(currentPage),
              !openedFolderIsAnimating else { return }

        let previewFrame = cell.convert(cell.iconContentFrame, to: self)
        guard let preview = makeDragPreview(for: cell, frame: previewFrame) else { return }
        addSubview(preview, positioned: .above, relativeTo: nil)

        let perPage = max(1, appState.perPage)
        var pages: [[LaunchpadGroupView]] = []
        if isScrollLayout {
            pages = [scrollCells]
        } else {
            for page in 0..<max(totalPages, 1) {
                let start = page * perPage
                let end = min(start + perPage, displayedGroups.count)
                pages.append(start < end ? displayedGroups[start..<end].compactMap { groupViews[$0.id] } : [])
            }
        }

        let session = LaunchpadDragSession(source: cell, preview: preview, offset: offset,
                                           startPage: currentPage, pages: pages)
        drag = session
        cell.isDragging = true
        if folderCell != nil {
            session.folderCells = openedFolderAppViews
            session.folderID = openedFolderID
        } else if cell.isHighlight, selectedGroups.count >= 2 {
            beginMultiDrag(session)
        }

        let link = displayLink(target: self, selector: #selector(dragTick(_:)))
        link.add(to: .main, forMode: .common)
        session.link = link
    }

    /// True for the single dragged cell and for every source of a multi-drag.
    func isDraggedCell(_ cell: LaunchpadGroupView) -> Bool {
        guard let session = drag else { return false }
        return cell === session.source || (session.multi?.sources.contains(where: { $0 === cell }) ?? false)
    }

    /// The floating copy of an icon (`makeDragPreview`): icon only, no title, alpha 0.85.
    func makeDragPreview(for cell: LaunchpadGroupView, frame: CGRect) -> NSView? {
        guard let group = cell.group else { return nil }
        let preview: NSView
        if group.isFolder {
            let view = LaunchpadFolderView(frame: frame)
            view.variant = GlassVariant.variant(fullScreen: !isWindowMode)
            view.configure(folder: group)
            preview = view
        } else if let app = group.apps.first {
            // Lifted app icon rides on a Liquid Glass tile, like the folder preview.
            let container = NSView(frame: frame)
            let side = min(frame.width, frame.height)
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.autoresizingMask = [.width, .height]
            glass.tintColor = nil
            glass.cornerRadius = side * 0.26
            GlassVariant.apply(to: glass, variant: GlassVariant.variant(fullScreen: !isWindowMode))
            container.addSubview(glass)
            let view = LaunchpadAppIconView(frame: container.bounds)
            view.autoresizingMask = [.width, .height]
            view.configure(app: app, pointSize: side)
            container.addSubview(view)
            preview = container
        } else {
            return nil
        }
        preview.wantsLayer = true
        preview.layer?.opacity = group.isFolder ? 0.85 : 1
        if !group.isFolder {
            preview.layer?.shadowColor = NSColor.black.cgColor
            preview.layer?.shadowOpacity = 0.28
            preview.layer?.shadowRadius = 14
            preview.layer?.shadowOffset = CGSize(width: 0, height: -6)
        }
        return preview
    }

    // MARK: Per-frame update

    @objc func dragTick(_ link: CADisplayLink) {
        guard let session = drag, !session.ended, let window else { return }
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        dragStep(mouse: convert(window.mouseLocationOutsideOfEventStream, from: nil), pressed: pressed)
        _ = session
    }

    /// One display-link step; separate from the tick so tests can drive it.
    func dragStep(mouse: CGPoint, pressed: Bool) {
        guard let session = drag, !session.ended else { return }
        if !pressed && session.dockSession == nil {
            endDrag(cancelled: false)
            return
        }
        if session.multi != nil {
            session.preview.setFrameOrigin(CGPoint(x: mouse.x - session.offset.x, y: mouse.y - session.offset.y))
            updateMultiTarget(mouse)
            stepGather()
            return
        }
        updateTarget(mouse)
        if session.folderCells != nil { detachFromFolderIfOutside() }

        if !session.isSynthetic { updateDockDrag(session, mouse: mouse) }
        if let overlay = session.overlayWindow {
            // The preview lives in the overlay window: position it from the screen pointer.
            let screenFrame = overlay.frame
            session.preview.setFrameOrigin(CGPoint(x: NSEvent.mouseLocation.x - screenFrame.minX - session.offset.x,
                                                   y: NSEvent.mouseLocation.y - screenFrame.minY - session.offset.y))
            return
        }
        var origin = CGPoint(x: mouse.x - session.offset.x, y: mouse.y - session.offset.y)
        if isWindowMode {
            let size = session.preview.frame.size
            origin.x = min(max(origin.x, 0), bounds.width - size.width)
            origin.y = min(max(origin.y, 0), bounds.height - size.height)
        }
        session.preview.setFrameOrigin(origin)
        if session.folderCells == nil {
            if isScrollLayout { autoscrollForDrag(mouse) } else { handleEdgeZone(mouse.x) }
        }
    }

    // MARK: Target computation

    func updateTarget(_ mouse: CGPoint) {
        if let session = drag, let cells = session.folderCells {
            updateFolderTarget(mouse, cells: cells)
            return
        }
        guard let session = drag, session.pages.indices.contains(dragPage) else { return }
        let cells = session.pages[dragPage].filter { !$0.isHidden }

        for cell in cells {
            let local = cell.convert(mouse, from: self)
            guard cell.bounds.contains(local) else { continue }
            let content = cell.iconContentFrame
            let action: DragDropAction = local.x < content.minX ? .insertBefore
                : local.x > content.maxX ? .insertAfter : .merge
            if action == .merge && cell === session.source {
                clearMergeTarget()
                cancelPendingAction()
                return
            }
            if let current = session.target, current !== cell || action != .merge {
                clearMergeTarget()
            }
            schedule(cell, action)
            return
        }

        // Empty area after the last item → move to the end of the page [I].
        if let last = cells.last {
            let frame = convert(last.bounds, from: last)
            if mouse.y < frame.minY || (mouse.y <= frame.maxY && mouse.x > frame.maxX) {
                schedule(last, .moveToEnd)
                return
            }
        }
        clearMergeTarget()
        cancelPendingAction()
    }

    func clearMergeTarget() {
        drag?.target?.isDraggingMerge = false
        drag?.target = nil
    }

    private func cancelPendingAction() {
        drag?.pendingWork?.cancel()
        drag?.pendingWork = nil
        drag?.pendingKey = nil
    }

    // MARK: Hover delay and action application

    private func schedule(_ cell: LaunchpadGroupView, _ action: DragDropAction) {
        guard let session = drag else { return }
        let key = "\(cell.group?.id ?? "")/\(action)"
        if session.pendingKey == key { return }
        session.pendingWork?.cancel()
        session.pendingKey = key
        let work = DispatchWorkItem { [weak self] in self?.applyDropAction(cell, action) }
        session.pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropActionHoverDelay, execute: work)
    }

    private func applyDropAction(_ cell: LaunchpadGroupView, _ action: DragDropAction) {
        guard let session = drag, !session.ended else { return }
        let sort = appState.sortBy
        if session.folderCells != nil {
            applyFolderDropAction(cell, action)
            return
        }

        switch action {
        case .merge:
            guard sort == .custom || sort == .name,
                  session.source.group?.isFolder == false,   // folders never go into folders
                  cell !== session.source else { return }
            cell.isDraggingMerge = true
            session.target = cell

        case .insertBefore, .insertAfter, .moveToEnd:
            guard sort == .custom,
                  let pageIndex = session.pages.firstIndex(where: { $0.contains(where: { $0 === session.source }) }),
                  session.pages[pageIndex].contains(where: { $0 === cell }) else { return }
            clearMergeTarget()
            var list = session.pages[pageIndex]
            guard let from = list.firstIndex(where: { $0 === session.source }),
                  let targetIndex = list.firstIndex(where: { $0 === cell }) else { return }
            var newIndex = action == .moveToEnd
                ? list.count
                : targetIndex + (action == .insertAfter ? 1 : 0)
            if from < newIndex { newIndex -= 1 }
            guard newIndex != from else { return }
            list.remove(at: from)
            list.insert(session.source, at: newIndex)
            session.pages[pageIndex] = list
            layoutDragPages(animated: true)
        }
    }

    /// Re-applies the in-flight drag order after an unrelated layout pass without cutting running glides.
    func reconcileDragLayout() {
        guard let session = drag, session.folderCells == nil,
              appState.browsingStyle == .paged else { return }
        let capacity = dragCapacity
        for (page, list) in session.pages.enumerated() {
            guard let parent = dragParent(page) else { continue }
            for (index, cell) in list.enumerated() {
                if cell.superview !== parent { cell.removeFromSuperview(); parent.addSubview(cell) }
                cell.isHidden = index >= capacity
                let frame = dragSlotFrame(min(index, capacity - 1))
                cell.itemSide = itemSide
                if cell.frame != frame { cell.frame = frame }
            }
        }
    }

    /// Lays every page list out in its slots (0.36 s ease-in-out); cells past the page capacity are
    /// hidden; the dragged cell is placed without animation.
    func layoutDragPages(animated: Bool) {
        guard let session = drag else { return }
        let capacity = dragCapacity
        for (page, list) in session.pages.enumerated() {
            guard let parent = dragParent(page) else { continue }
            for (index, cell) in list.enumerated() {
                if cell.superview !== parent {
                    cell.removeFromSuperview()
                    parent.addSubview(cell)
                }
                cell.isHidden = index >= capacity
                let frame = dragSlotFrame(min(index, capacity - 1))
                cell.itemSide = itemSide
                if isDraggedCell(cell) || !animated || cell.isHidden {
                    cell.layer?.removeAllAnimations()
                    cell.frame = frame
                } else {
                    glide(cell, to: frame, duration: Self.layoutDuration, timing: .easeInEaseOut)
                }
            }
        }
    }

    /// Moves `view` to `frame` with an explicit `position` animation. The model frame is applied at
    /// once; `animator().frame` did not animate these layer-backed cells.
    func glide(_ view: NSView, to frame: CGRect, duration: TimeInterval,
                       timing: CAMediaTimingFunctionName, fadeTo opacity: Float? = nil) {
        guard let layer = view.layer else { view.frame = frame; return }
        let from = layer.presentation()?.position ?? layer.position
        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = frame
        if let opacity { layer.opacity = opacity }
        CATransaction.commit()

        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: from)
        position.toValue = NSValue(point: layer.position)
        position.duration = duration
        position.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(position, forKey: "drag.glide.position")
        if let opacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = opacity
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: timing)
            layer.add(fade, forKey: "drag.glide.opacity")
        }
    }

    // MARK: Edge zones

    private func handleEdgeZone(_ x: CGFloat) {
        guard let session = drag else { return }
        let zone: DragEdgeZone = x < safeFrame.minX + 10 ? .left
            : x > safeFrame.maxX - 10 ? .right : .none
        if zone != session.edgeZone {
            session.edgeZone = zone
            session.edgeStart = CACurrentMediaTime()
            return
        }
        guard zone != .none, CACurrentMediaTime() - session.edgeStart >= Self.edgeHoverThreshold else { return }
        flipPage(zone)
        session.edgeStart = CACurrentMediaTime()
    }

    func flipPage(_ zone: DragEdgeZone) {
        guard let session = drag, openedFolderID == nil else { return }
        let old = currentPage
        var new = old
        switch zone {
        case .left:
            guard old > 0 else { return }
            new = old - 1
        case .right:
            if old + 1 < session.pages.count {
                new = old + 1
            } else {
                // Right edge on the last page: append an empty page unless this page is only the
                // dragged item (custom sort only).
                let onlyDragged = session.pages[old].count == 1 && session.pages[old][0] === session.source
                guard appState.sortBy == .custom, !onlyDragged else { return }
                appendDragPage()
                new = old + 1
            }
        case .none:
            return
        }

        clearMergeTarget()
        cancelPendingAction()

        if appState.sortBy == .custom {
            // Move the dragged cell to the destination page list.
            for index in session.pages.indices { session.pages[index].removeAll { $0 === session.source } }
            let capacity = max(1, appState.perPage)
            let at = min(session.pages[new].count, capacity - 1)
            session.pages[new].insert(session.source, at: at)
            layoutDragPages(animated: true)
        }
        setPage(new, animated: true)
    }

    func appendDragPage() {
        guard let session = drag else { return }
        totalPages += 1
        session.pages.append([])
        while pageViews.count < totalPages {
            let view = NSView(frame: .zero)
            view.wantsLayer = true
            pagedModeView.addSubview(view)
            pageViews.append(view)
        }
        let width = bounds.width, height = bounds.height
        pagedModeView.setFrameSize(CGSize(width: width * CGFloat(totalPages), height: height))
        for (index, view) in pageViews.enumerated() {
            view.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
            view.isHidden = index >= totalPages
        }
        pageIndicatorView.update(totalPages: totalPages, currentPage: currentPage)
    }

    // MARK: Drop

    func endDrag(cancelled: Bool) {
        guard let session = drag, !session.ended else { return }
        session.ended = true
        session.link?.invalidate()
        session.link = nil
        session.pendingWork?.cancel()

        if session.multi != nil {
            endMultiDrag(cancelled: cancelled)
            return
        }
        if cancelled {
            clearMergeTarget()
            let back = previewDestination(for: session)
            dataManager.publish(2)
            if appState.browsingStyle == .paged { setPage(session.startPage, animated: true) }
            animatePreview(to: back, commit: false)
            return
        }
        if session.target != nil {
            mergeDrop()
        } else {
            animatePreviewBack(commit: true)
        }
    }

    private func animatePreviewBack(commit: Bool) {
        guard let session = drag else { return }
        animatePreview(to: previewDestination(for: session), commit: commit)
    }

    /// The source cell's icon frame in the coordinates the preview currently lives in.
    func previewDestination(for session: LaunchpadDragSession) -> CGRect {
        let inSelf = session.source.convert(session.source.iconContentFrame, to: self)
        guard let overlay = session.overlayWindow, let window else { return inSelf }
        let screenRect = window.convertToScreen(convert(inSelf, to: nil))
        return screenRect.offsetBy(dx: -overlay.frame.minX, dy: -overlay.frame.minY)
    }

    /// `animatePreviewBack`: 0.36 s ease-out onto the source cell.
    private func animatePreview(to destination: CGRect, commit: Bool) {
        guard let session = drag else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finishDrag(commit: commit) }
        glide(session.preview, to: destination, duration: Self.layoutDuration, timing: .easeOut, fadeTo: 1)
        CATransaction.commit()
    }

    private func finishDrag(commit: Bool) {
        guard let session = drag else { return }
        session.preview.removeFromSuperview()
        session.overlayWindow?.orderOut(nil)
        session.overlayWindow = nil
        session.source.isDragging = false
        clearMergeTarget()
        drag = nil
        guard commit else { return }
        if session.folderCells != nil {
            commitFolderOrderAfterDrop(session)
        } else {
            commitOrderAfterDrop(session)
        }
    }

    ///: persist the dragged order, or explain why nothing changes.
    private func commitOrderAfterDrop(_ session: LaunchpadDragSession) {
        guard dataManager.currentSearchQuery.isEmpty else { return }
        guard appState.sortBy == .custom else {
            ToastManager.shared.show(type: .info,
                                     message: NSLocalizedString("Dragging to reorder is only available in Custom sort mode.", comment: ""),
                                     duration: 3)
            return
        }
        let pages = dragCommitLists(session)
        dataManager.commitOrder(pages: pages)
    }

    // MARK: Merge drop

    private func mergeDrop() {
        guard let session = drag, let target = session.target,
              let targetGroup = target.group, let sourceGroup = session.source.group else {
            animatePreviewBack(commit: true)
            return
        }
        target.isDraggingMerge = false
        session.target = nil

        // Close the gap left by the dragged cell and fly the preview into its mini slot.
        for index in session.pages.indices { session.pages[index].removeAll { $0 === session.source } }
        session.source.isHidden = true
        layoutDragPages(animated: true)

        let slotIndex = min(targetGroup.isFolder ? targetGroup.apps.count : 1, 8)
        let probe = LaunchpadFolderView(frame: CGRect(origin: .zero, size: target.iconContentFrame.size))
        let slots = probe.previewIconFrames(count: slotIndex + 1)
        let content = target.convert(target.iconContentFrame, to: self)
        let slot = slots.indices.contains(slotIndex)
            ? slots[slotIndex].offsetBy(dx: content.minX, dy: content.minY)
            : content

        let from = session.preview.frame
        let cx = from.width * 0.5, cy = from.height * 0.5
        var transform = CATransform3DMakeTranslation(slot.midX - from.midX, slot.midY - from.midY, 0)
        transform = CATransform3DTranslate(transform, cx, cy, 0)
        transform = CATransform3DScale(transform, slot.width / from.width, slot.height / from.height, 1)
        transform = CATransform3DTranslate(transform, -cx, -cy, 0)

        let pages = appState.sortBy == .custom ? session.pages.map { $0.compactMap(\.group) } : nil

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            session.preview.removeFromSuperview()
            session.source.removeFromSuperview()
            session.source.isDragging = false
            self.drag = nil
            self.dataManager.mergeGroup(source: sourceGroup, into: targetGroup, pages: pages)
        }
        if let layer = session.preview.layer {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = layer.transform
            animation.toValue = transform
            animation.duration = Self.layoutDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.transform = transform
            layer.add(animation, forKey: "folder.drop")
        }
        CATransaction.commit()
    }
}

// MARK: - Inside an opened folder

extension LaunchpadContentView {
    /// Same targeting as the grid on the folder's cells; merging is disabled.
    fileprivate func updateFolderTarget(_ mouse: CGPoint, cells: [LaunchpadGroupView]) {
        guard let session = drag else { return }
        for cell in cells where !cell.isHidden {
            let local = cell.convert(mouse, from: self)
            guard cell.bounds.contains(local) else { continue }
            if cell === session.source { cancelFolderPending(); return }
            // Inside a folder every position is an insertion: left half before, right half after.
            scheduleFolderAction(cell, local.x < cell.iconContentFrame.midX ? .insertBefore : .insertAfter)
            return
        }
        cancelFolderPending()
    }

    private func cancelFolderPending() {
        drag?.pendingWork?.cancel()
        drag?.pendingWork = nil
        drag?.pendingKey = nil
    }

    private func scheduleFolderAction(_ cell: LaunchpadGroupView, _ action: DragDropAction) {
        guard let session = drag else { return }
        let key = "\(cell.group?.id ?? "")/\(action)"
        if session.pendingKey == key { return }
        session.pendingWork?.cancel()
        session.pendingKey = key
        let work = DispatchWorkItem { [weak self] in self?.applyDropAction(cell, action) }
        session.pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Re-orders the folder's cells (custom sort only), 0.36 s ease-in-out.
    fileprivate func applyFolderDropAction(_ cell: LaunchpadGroupView, _ action: DragDropAction) {
        guard let session = drag, var list = session.folderCells, appState.sortBy == .custom,
              action != .merge,
              let from = list.firstIndex(where: { $0 === session.source }),
              let targetIndex = list.firstIndex(where: { $0 === cell }) else { return }
        var newIndex = action == .moveToEnd ? list.count : targetIndex + (action == .insertAfter ? 1 : 0)
        if from < newIndex { newIndex -= 1 }
        guard newIndex != from else { return }
        list.remove(at: from)
        list.insert(session.source, at: newIndex)
        session.folderCells = list
        openedFolderAppViews = list
        layoutFolderCells(animated: true)
    }

    fileprivate func layoutFolderCells(animated: Bool) {
        guard let session = drag, let list = session.folderCells else { return }
        for (index, cell) in list.enumerated() {
            let frame = openedFolderSlotFrame(index: index, count: list.count)
            if cell === session.source || !animated {
                cell.layer?.removeAllAnimations()
                cell.frame = frame
            } else {
                glide(cell, to: frame, duration: 0.36, timing: .easeInEaseOut)
            }
        }
    }

    /// Dragging the preview out of the glass panel turns the app into a grid cell and closes the
    /// folder.
    fileprivate func detachFromFolderIfOutside() {
        guard let session = drag, session.folderCells != nil, !openedFolderIsAnimating,
              appState.sortBy == .custom, !openedFolderClipView.isHidden,
              let folder = currentOpenedFolder, let app = session.source.group?.apps.first,
              let parent = dragParent(dragPage) else { return }
        let panel = convert(openedFolderScrollView.bounds, from: openedFolderScrollView)
        guard !session.preview.frame.intersects(panel) else { return }

        cancelFolderPending()
        session.target?.isDraggingMerge = false
        session.target = nil

        // A new single-app cell at the end of the current page, hidden under the preview.
        let detached = LaunchpadGroup(id: UUID().uuidString, name: app.name, apps: [app],
                                      order: 0, page: dragPage, isFolder: false)
        let newView = makeGroupView(for: detached)
        groupViews[detached.id] = newView
        parent.addSubview(newView)
        newView.isDragging = true
        session.pages[dragPage].append(newView)
        layoutDragPages(animated: false)

        // The app leaves the folder's model and cells.
        let oldView = session.source
        folder.apps.removeAll { $0 === app }
        openedFolderAppViews.removeAll { $0 === oldView }
        oldView.removeFromSuperview()
        session.folderCells = nil
        session.folderID = folder.id
        session.source = newView
        layoutOpenedFolderContent()
        refreshFolderIconPreview()
        closeFolder(animated: true)
    }

    fileprivate func commitFolderOrderAfterDrop(_ session: LaunchpadDragSession) {
        guard dataManager.currentSearchQuery.isEmpty else { return }
        guard appState.sortBy == .custom else {
            ToastManager.shared.show(type: .info,
                                     message: NSLocalizedString("Dragging to reorder is only available in Custom sort mode.", comment: ""),
                                     duration: 3)
            return
        }
        guard let folderID = session.folderID, let list = session.folderCells else { return }
        dataManager.commitFolderOrder(folderID: folderID, appIDs: list.compactMap { $0.group?.apps.first?.id })
    }
}

// MARK: - Scroll-mode auto-scroll

extension LaunchpadContentView {
    /// Scrolls the list while the pointer is within 70 pt of its top or bottom edge.
    fileprivate func autoscrollForDrag(_ mouse: CGPoint) {
        let edge: CGFloat = 70, maxSpeed: CGFloat = 18
        let clip = scrollModeView.contentView
        let local = mouse.y - scrollModeView.frame.minY
        let height = scrollModeView.bounds.height
        var delta: CGFloat = 0
        if local > height - edge { delta = -min((local - (height - edge)) / edge, 1) * maxSpeed }
        else if local < edge { delta = min((edge - local) / edge, 1) * maxSpeed }
        guard delta != 0, let doc = scrollModeView.documentView else { return }
        let maxY = max(doc.frame.height - clip.bounds.height, 0)
        let y = min(max(clip.bounds.origin.y + delta, 0), maxY)
        clip.setBoundsOrigin(CGPoint(x: clip.bounds.origin.x, y: y))
        scrollModeView.reflectScrolledClipView(clip)
    }
}

