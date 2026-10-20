import AppKit

/// The launchpad grid: layout math, paging, search, cells, context menus and uninstall mode
///.
final class LaunchpadContentView: NSView {
    unowned let appState = AppState.shared
    let dataManager = LaunchpadDataManager.shared

    // Subviews, in z-order
    let scrollModeView = NSScrollView()
    var scrollDocumentView = FlippedView()
    /// Scroll-mode cells in grid order.
    var scrollCells: [LaunchpadGroupView] = []
    let searchView: LaunchpadSearchView
    let pagedModeView = NSView()
    let pageIndicatorView: LaunchpadPageIndicatorView
    let statusView = StatusView()
    private let interactionOverlayView = OverlayView()

    var pageViews: [NSView] = []
    var groupViews: [String: LaunchpadGroupView] = [:]
    private var mountedPageRange: Range<Int> = 0..<0

    // Layout results
    var safeFrame: CGRect = .zero
    var contentX: CGFloat = 0
    var contentY: CGFloat = 0
    /// In-flight single-item drag.
    var drag: LaunchpadDragSession?
    /// Command-drag rubber-band selection.
    let marqueeView = SelectionMarqueeView()
    var marqueeStart: CGPoint?
    var marqueeInitialIDs: Set<String> = []
    /// Running hide animation.
    var hideAnimation: LaunchpadHideAnimation?
    var columnSize: CGSize = .zero
    var itemSide: CGFloat = 74
    private var contentWidth: CGFloat = 0

    var totalPages = 1
    var currentPage = 0
    var displayedGroups: [LaunchpadGroup] = []

    private var loadingWorkItem: DispatchWorkItem?
    private var isLoading = false

    var activeGroupID: String?

    // Paging drag / trackpad state
    private var dragStartPoint: NSPoint?
    private var isDragPaging = false
    private var displayedDragOffset: CGFloat = 0
    private var targetDragOffset: CGFloat = 0
    private var dragDisplayLink: CADisplayLink?
    private var pagingDelta: CGFloat = 0
    private var pagingAxisIsVertical = false
    private var isTrackpadPaging = false
    private var isPagedScrollAnimating = false
    /// Horizontal swipe velocity (pt/s) handed to the next page animation.
    private var pagingVelocity: CGFloat = 0
    private var lastPagingSample: (x: CGFloat, time: TimeInterval)?
    private var pagedAnimationGeneration = 0

    private var optionUninstallWorkItem: DispatchWorkItem?
    private var isOptionUninstallModeActive = false
    private(set) var isUninstallModeActive = false

    // Opened folder
    let openedFolderBackdropView = OverlayView()
    let openedFolderClipView = OpenedFolderClipView()
    var openedFolderBlurView = NSGlassEffectView()
    let openedFolderGlassContentView = NSView()
    let openedFolderScrollView = VerticalOnlyScrollView()
    let openedFolderContentView = FlippedView()
    let openedFolderTitleLabel = FolderFloatingTitleView()
    let openedFolderBackButton = PassthroughButton()
    var openedFolderTitleEditorView: NSTextField?
    var openedFolderAppViews: [LaunchpadGroupView] = []
    /// True while the base views (search, pages, indicator, status) carry the folder
    /// open/close scale transform — their frames must not be re-set in this state, because
    /// assigning `frame` through a non-identity transform corrupts the layer geometry.
    var isBaseContentFaded = false
    var openedFolderGroupView: LaunchpadGroupView?
    var openedFolderIsAnimating = false
    var openedFolderID: String?

    private let variant: Int
    var isWindowMode: Bool { appState.displayMode == .window }

    // Callbacks
    var onRequestHideLauncher: (() -> Void)?
    var onOpenPreferences: (() -> Void)?
    var onOpenReorganize: (() -> Void)?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    init(variant: Int) {
        self.variant = variant
        self.searchView = LaunchpadSearchView(variant: variant)
        self.pageIndicatorView = LaunchpadPageIndicatorView(variant: variant)
        super.init(frame: .zero)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        scrollModeView.hasVerticalScroller = false
        scrollModeView.hasHorizontalScroller = false
        scrollModeView.drawsBackground = false
        scrollModeView.isHidden = true
        addSubview(scrollModeView)

        searchView.onDebouncedQueryChanged = { [weak self] query, previous in
            self?.handleQueryChange(query: query, previous: previous)
        }
        searchView.onSettingsButtonClicked = { [weak self] in
            self?.showBackgroundMenu()
        }
        addSubview(searchView)

        pagedModeView.wantsLayer = true
        addSubview(pagedModeView)

        pageIndicatorView.onSelectPage = { [weak self] page in
            self?.setPage(page, animated: true)
        }
        addSubview(pageIndicatorView)

        addSubview(statusView)

        interactionOverlayView.isHidden = true
        interactionOverlayView.onMouseDown = { [weak self] in self?.handleEmptyAreaClick() }
        addSubview(interactionOverlayView)

        setupFolderOverlay()

        statusView.type = .loading
        isLoading = true
        scheduleLoadingStatus()

        installKeyboardMonitorIfNeeded()

    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        performLayout()
    }

    func relayout() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func performLayout() {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return }
        let isWindow = isWindowMode
        let F = isWindow ? window.frame : screen.frame
        let V = screen.visibleFrame
        let S = isWindow ? NSEdgeInsets() : screen.safeAreaInsets
        let cols = appState.columns
        let rows = appState.rows

        // safeFrame
        if isWindow {
            safeFrame = bounds
        } else {
            let top0 = max(S.top, 0), left = max(S.left, 0), right = max(S.right, 0), bottom = max(S.bottom, 0)
            let menuGap = F.maxY - V.maxY
            let top = menuGap >= 0 ? max(S.top, menuGap) : top0
            var r = CGRect(x: F.minX + left, y: F.minY + bottom,
                           width: max(F.width - left - right, 0),
                           height: max(F.height - top - bottom, 0))
            if !appState.hideDock {
                let dl = max(V.minX - F.minX, 0), dr = max(F.maxX - V.maxX, 0), db = max(V.minY - F.minY, 0)
                r.origin.x += dl; r.origin.y += db
                r.size.width = max(r.width - dl - dr, 0)
                r.size.height = max(r.height - db, 0)
            }
            safeFrame = r.offsetBy(dx: -F.minX, dy: -F.minY)
        }

        // column size / item side
        var availH: CGFloat
        if isWindow {
            columnSize = CGSize(width: 114, height: 108)
            contentWidth = CGFloat(cols) * 114
            availH = CGFloat(rows) * 108
            itemSide = 74
        } else {
            let extra = appState.columnsPerPage > 6 ? appState.columnsPerPage - 7 : 0
            let maxColW = (CGFloat(extra) * 80 + 1760) / CGFloat(cols)
            let colW = min(safeFrame.width / CGFloat(cols + 1), maxColW)
            availH = safeFrame.height - 88 - 56
            let rowH = availH / CGFloat(rows)
            columnSize = CGSize(width: colW, height: rowH)
            let labelBlock = DesignTokens.labelBlock
            let iconCap = max(min(rowH - labelBlock, colW), 0)
            let a = max(floor(iconCap / 8) * 8, 0)
            let b = max(floor(min(rowH, colW) * 0.72 / 8) * 8, 0)
            itemSide = min(maxItemSide(forScreenHeight: F.height), min(a, b))
            contentWidth = colW * CGFloat(cols)
        }

        // content origin & frames
        contentX = isWindow ? safeFrame.minX + 22 : safeFrame.minX + (safeFrame.width - contentWidth) * 0.5
        contentY = 88 + (bounds.height - safeFrame.maxY)
        let topMargin: CGFloat = isWindow ? 70 : 88
        contentY = topMargin + (bounds.height - safeFrame.maxY)
        _ = availH

        if isWindow {
            if !isBaseContentFaded { searchView.frame = CGRect(x: safeFrame.minX, y: safeFrame.maxY - 56, width: safeFrame.width, height: 56) }
        } else {
            if !isBaseContentFaded {
                searchView.frame = CGRect(x: safeFrame.minX + (safeFrame.width - 240) * 0.5,
                                          y: safeFrame.maxY - 16 - 40, width: 240, height: 40)
            }
        }
        if !isBaseContentFaded {
            statusView.frame = CGRect(x: safeFrame.minX + (safeFrame.width - 300) * 0.5,
                                      y: safeFrame.minY + 56 + (safeFrame.height - 144 - 300) * 0.5,
                                      width: 300, height: 300)
        }

        pageIndicatorView.isHidden = totalPages < 2 || appState.browsingStyle == .scroll
        let indicatorHeight: CGFloat = 24
        let indicatorWidth = pageIndicatorView.intrinsicContentSize.width
        if !isBaseContentFaded {
            pageIndicatorView.frame = CGRect(x: safeFrame.midX - indicatorWidth / 2,
                                             y: safeFrame.minY + 16,
                                             width: indicatorWidth, height: indicatorHeight)
        }

        if appState.browsingStyle == .scroll {
            if drag == nil { buildScrollMode() }      // a rebuild mid-drag would destroy the dragged cells
        } else {
            buildPagedMode()
        }

        // A layout pass mid-drag would snap every cell back to the stored order; keep the dragged order.
        reconcileDragLayout()

        if openedFolderID != nil { layoutOpenedFolder(animated: false) }
    }

    private func maxItemSide(forScreenHeight h: CGFloat) -> CGFloat {
        switch h {
        case 1080...: return 128
        case 1050..<1080: return 120
        case 980..<1050: return 104
        case 940..<980: return 96
        case 900..<940: return 88
        case 820..<900: return 80
        case 720..<820: return 72
        default: return 56
        }
    }

    // MARK: - Paged mode

    private func buildPagedMode() {
        scrollModeView.isHidden = true
        pagedModeView.isHidden = false
        let W = bounds.width, H = bounds.height
        if !isBaseContentFaded {
            pagedModeView.frame = CGRect(x: 0, y: 0, width: W * CGFloat(max(totalPages, 1)), height: H)
        }

        while pageViews.count < max(totalPages, 1) {
            let view = NSView(frame: .zero)
            view.wantsLayer = true
            pagedModeView.addSubview(view)
            pageViews.append(view)
        }
        if !isBaseContentFaded {
            for (index, view) in pageViews.enumerated() {
                view.frame = CGRect(x: CGFloat(index) * W, y: 0, width: W, height: H)
                view.isHidden = index >= totalPages
            }
        }
        mountAllPages()
        applyPagedOffset(animated: false)
    }

    private func mountAllPages() {
        // For simplicity mount every page (page counts are small), reusing cells by group id.
        var liveIDs = Set<String>()
        for (index, view) in pageViews.enumerated() where index < totalPages {
            let perPage = appState.perPage
            let start = index * perPage
            let end = min(start + perPage, displayedGroups.count)
            guard start < end else { continue }
            let groups = Array(displayedGroups[start..<end])
            for (slot, group) in groups.enumerated() {
                liveIDs.insert(group.id)
                let cell = groupViews[group.id] ?? makeGroupView(for: group)
                cell.syncIfNeeded(with: group, hideNames: appState.hideNames)
                groupViews[group.id] = cell
                if cell.superview !== view { cell.removeFromSuperview(); view.addSubview(cell) }
                place(cell: cell, slot: slot)
            }
        }
        for (id, view) in groupViews where !liveIDs.contains(id) {
            view.removeFromSuperview()
            groupViews.removeValue(forKey: id)
        }
    }

    func makeGroupView(for group: LaunchpadGroup) -> LaunchpadGroupView {
        let view = LaunchpadGroupView(variant: variant)
        view.configure(with: group, hideNames: appState.hideNames)
        view.onActivate = { [weak self] g in self?.activate(g) }
        view.onLongPress = { [weak self] g in self?.enterUninstallMode(focused: g) }
        view.onRename = { [weak self] g, name in
            guard let self else { return }
            if g.isFolder { self.dataManager.renameFolder(g, name: name) }
            else if let app = g.apps.first { self.dataManager.setAlias(app, alias: name) }
        }
        view.onUninstallRequest = { group in
            guard !group.isFolder, let app = group.apps.first else { return }
            UninstallCoordinator.shared.begin(app: app)
        }
        view.onDragBegan = { [weak self] g, event, offset in self?.beginDrag(group: g, event: event, offset: offset) }
        view.menuProvider = { [weak self] g in self?.contextMenu(for: g) }
        return view
    }

    /// Frame of grid slot `slot` inside a page view.
    func slotFrame(_ slot: Int) -> CGRect {
        let columns = appState.columns
        let row = slot / columns
        let col = slot % columns
        let x = contentX + CGFloat(col) * columnSize.width
        let y = bounds.height - contentY - CGFloat(row + 1) * columnSize.height
        return CGRect(origin: CGPoint(x: x, y: y), size: columnSize)
    }

    func place(cell: LaunchpadGroupView, slot: Int) {
        cell.itemSide = itemSide
        cell.frame = slotFrame(slot)
    }

    private func applyPagedOffset(animated: Bool) {
        let targetX: CGFloat
        if isDragPaging || displayedDragOffset != 0 {
            targetX = -CGFloat(currentPage) * bounds.width + displayedDragOffset
        } else {
            targetX = -CGFloat(currentPage) * bounds.width
        }
        guard let layer = pagedModeView.layer else { return }
        if animated {
            // Rest position of the strip for the current page; the layer's position is origin + width / 2.
            let restX = -CGFloat(currentPage) * bounds.width
            let from = layer.presentation()?.position.x ?? layer.position.x
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "pageScroll")
            pagedModeView.frame.origin.x = restX
            CATransaction.commit()
            let to = layer.position.x

            // Slightly under-damped spring that carries the swipe's release velocity.
            let spring = CASpringAnimation(keyPath: "position.x")
            spring.mass = 1
            spring.stiffness = 240
            spring.damping = 27
            let distance = to - from
            spring.initialVelocity = abs(distance) > 1 ? max(-30, min(30, pagingVelocity / distance)) : 0
            pagingVelocity = 0
            spring.duration = spring.settlingDuration
            if #available(macOS 27, *) { spring.preferredFrameRateRange = DesignTokens.frameRateRange }
            spring.fromValue = from
            spring.toValue = to
            pagedAnimationGeneration += 1
            let generation = pagedAnimationGeneration
            isPagedScrollAnimating = true
            layer.add(spring, forKey: "pageScroll")
            DispatchQueue.main.asyncAfter(deadline: .now() + spring.settlingDuration) { [weak self] in
                guard let self, self.pagedAnimationGeneration == generation else { return }
                self.isPagedScrollAnimating = false
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "pageScroll")
            pagedModeView.frame.origin.x = targetX
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    // MARK: - Scroll mode

    /// Frame of scroll-mode slot `index` inside the (flipped) document view.
    func scrollSlotFrame(_ index: Int) -> CGRect {
        let columns = max(appState.columns, 1)
        let colW = isWindowMode ? 114 : columnSize.width
        let rowH = isWindowMode ? 108 : columnSize.height
        let top: CGFloat = isWindowMode ? 14 : contentY
        return CGRect(x: contentX + CGFloat(index % columns) * colW,
                      y: top + CGFloat(index / columns) * rowH, width: colW, height: rowH)
    }

    private func buildScrollMode() {
        pagedModeView.isHidden = true
        scrollModeView.isHidden = false
        scrollModeView.frame = isWindowMode
            ? CGRect(x: 0, y: 0, width: bounds.width, height: searchView.frame.minY)
            : bounds

        let doc = FlippedView(frame: .zero)
        let columns = appState.columns
        let rows = appState.rows
        let rowH = isWindowMode ? 108 : columnSize.height
        let top: CGFloat = isWindowMode ? 14 : contentY
        let count = displayedGroups.count
        let contentRows = (count + max(columns, 1) - 1) / max(columns, 1)   // a partial last row still needs its height
        let height = max(top + CGFloat(contentRows) * rowH + top, scrollModeView.bounds.height)
        doc.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        for view in groupViews.values { view.removeFromSuperview() }
        groupViews.removeAll()
        scrollCells.removeAll()
        for (index, group) in displayedGroups.enumerated() {
            let cell = makeGroupView(for: group)
            cell.itemSide = itemSide
            cell.frame = scrollSlotFrame(index)
            doc.addSubview(cell)
            groupViews[group.id] = cell
            scrollCells.append(cell)
        }
        _ = rows
        // An overlay scroller that hides itself shows in window mode.
        scrollModeView.scrollerStyle = .overlay
        scrollModeView.autohidesScrollers = true
        scrollModeView.hasVerticalScroller = isWindowMode
        scrollModeView.documentView = doc
        scrollDocumentView = doc
    }

    // MARK: - Data updates

    /// Blocks interaction with the grid while another window (preferences, guide) is open
    ///.
    func setInteractionOverlayHidden(_ hidden: Bool) {
        interactionOverlayView.isHidden = hidden
    }

    func reload(_ update: LaunchpadDisplayUpdate) {
        totalPages = max(1, update.totalPages)
        displayedGroups = update.groups
        currentPage = min(currentPage, totalPages - 1)
        cancelLoadingStatus()
        statusView.type = update.groups.isEmpty ? .searchNoResult : .none

        // A structural change rebuilds the grid; drop the opened folder if it vanished.
        if update.changeKind == .structure, let id = openedFolderID,
           !update.groups.contains(where: { $0.id == id && $0.isFolder }) {
            teardownOpenedFolder()
            openedFolderID = nil
            openedFolderGroupView = nil
        }

        let structureChanged = update.changeKind == .structure
        if structureChanged {
            for view in groupViews.values { view.removeFromSuperview() }
            groupViews.removeAll()
            while pageViews.count > totalPages { pageViews.removeLast().removeFromSuperview() }
        }
        pageIndicatorView.update(totalPages: totalPages, currentPage: currentPage)
        relayout()
        appState.currentPage = currentPage
    }

    func showLoading() {
        isLoading = true
        statusView.type = .none
        scheduleLoadingStatus()
    }

    func returnToFirstPage() {
        setPage(0, animated: false)
    }

    func refreshIcons(urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        for (_, view) in groupViews {
            guard let group = view.group, let app = group.apps.first, paths.contains(app.standardizedPath) else { continue }
            view.appView?.iconView.configure(app: app, pointSize: itemSide)
        }
    }

    /// Clears the search field when the launchpad closes.
    func clearSearchFromOutside() {
        searchView.clear(notify: false)
        searchView.inputField.stringValue = ""
    }

    private func scheduleLoadingStatus() {
        loadingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isLoading else { return }
            self.statusView.type = .loading
        }
        loadingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func cancelLoadingStatus() {
        isLoading = false
        loadingWorkItem?.cancel()
        loadingWorkItem = nil
    }

    // MARK: - Paging

    func setPage(_ index: Int, animated: Bool) {
        guard appState.browsingStyle == .paged else { return }
        let clamped = max(0, min(index, totalPages - 1))
        guard clamped != currentPage else {
            applyPagedOffset(animated: animated && displayedDragOffset != 0)
            displayedDragOffset = 0
            return
        }
        currentPage = clamped
        appState.currentPage = clamped
        pageIndicatorView.update(totalPages: totalPages, currentPage: clamped)
        displayedDragOffset = 0
        applyPagedOffset(animated: animated)
    }

    func previousPage() { setPage(currentPage - 1, animated: true) }
    func nextPage() { setPage(currentPage + 1, animated: true) }

    // MARK: - Scroll wheel / trackpad

    override func scrollWheel(with event: NSEvent) {
        guard appState.browsingStyle == .paged, totalPages > 1 else {
            super.scrollWheel(with: event)
            return
        }
        if event.hasPreciseScrollingDeltas {
            handlePreciseScroll(event)
        } else {
            handleLineScroll(event)
        }
    }

    private func handlePreciseScroll(_ event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        switch event.phase {
        case .began:
            pagingDelta = 0
            pagingAxisIsVertical = abs(dx) < abs(dy)
            isTrackpadPaging = true
            fallthrough
        case .changed:
            let dominant = pagingAxisIsVertical ? dy : dx
            pagingDelta += dominant
            setPagedDragTarget(rubberBand(pagingDelta))
        case .ended, .cancelled:
            stopPagedDragLink()
            isTrackpadPaging = false
            let threshold: CGFloat = pagingAxisIsVertical ? 10 : 50
            if isPagedScrollAnimating { displayedDragOffset = 0; applyPagedOffset(animated: false); return }
            if abs(pagingDelta) <= threshold {
                displayedDragOffset = 0
                applyPagedOffset(animated: true)
            } else if pagingDelta >= 0 {
                displayedDragOffset = 0
                previousPage()
            } else {
                displayedDragOffset = 0
                nextPage()
            }
            pagingDelta = 0
        default:
            break
        }
    }

    private func handleLineScroll(_ event: NSEvent) {
        let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let dt = event.timestamp - lastLineScrollTime
        lastLineScrollTime = event.timestamp
        if (dt > 0.05 && abs(d) < 2) || (dt > 0.3 && abs(d) > 2) {
            if d < 0 { nextPage() } else { previousPage() }
        }
    }

    private var lastLineScrollTime: TimeInterval = 0

    /// Resistance only past the first / last page; between pages the strip follows 1:1.
    private func rubberBand(_ x: CGFloat) -> CGFloat {
        let atEdge = (currentPage == 0 && x > 0) || (currentPage >= totalPages - 1 && x < 0)
        guard atEdge else { return x }
        let limit = min(max(bounds.width * 0.08, 48), 72)
        guard abs(x) > limit else { return x }
        let e = abs(x) - limit
        return (limit + e * 180 / (e + 180)) * (x < 0 ? -1 : 1)
    }

    // MARK: Smoothed live drag ( `updatePagedDragFrame`)

    private var pagedDragLink: CADisplayLink?
    private var pagedDragTarget: CGFloat = 0
    private var pagedDragPresented: CGFloat = 0

    /// Sets the offset the strip should reach; a display link eases the shown offset toward it.
    private func setPagedDragTarget(_ target: CGFloat) {
        pagedDragTarget = target
        guard pagedDragLink == nil else { return }
        pagedDragPresented = displayedDragOffset
        let link = displayLink(target: self, selector: #selector(updatePagedDragFrame(_:)))
        link.add(to: .main, forMode: .common)
        pagedDragLink = link
    }

    private func stopPagedDragLink() {
        pagedDragLink?.invalidate()
        pagedDragLink = nil
    }

    @objc private func updatePagedDragFrame(_ link: CADisplayLink) {
        let d = pagedDragTarget - pagedDragPresented
        if abs(d) < 0.1 {
            pagedDragPresented = pagedDragTarget
            displayedDragOffset = pagedDragPresented
            applyPagedOffset(animated: false)
            stopPagedDragLink()
            return
        }
        let dt = link.targetTimestamp - link.timestamp
        let k: CGFloat = dt <= 1.0 / 120 ? 0.21 : (dt / (1.0 / 60) < 1 ? min(CGFloat(dt / (1.0 / 60)) * 0.42, 0.58) : 0.42)
        pagedDragPresented += d * k
        displayedDragOffset = pagedDragPresented
        applyPagedOffset(animated: false)
    }

    // MARK: - Mouse drag paging

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            beginMarquee(at: convert(event.locationInWindow, from: nil))
            dragStartPoint = nil
            return
        }
        if modifiers.contains(.control) { showBackgroundMenu(); return }
        dragStartPoint = convert(event.locationInWindow, from: nil)
        isDragPaging = false
        pagingVelocity = 0
        lastPagingSample = nil
    }

    override func mouseDragged(with event: NSEvent) {
        if marqueeStart != nil {
            updateMarquee(to: convert(event.locationInWindow, from: nil))
            return
        }
        guard let start = dragStartPoint, appState.browsingStyle == .paged else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - start.x
        let dy = point.y - start.y
        if !isDragPaging && abs(dx) >= 4 && abs(dy) < abs(dx) { isDragPaging = true }
        guard isDragPaging else { return }
        setPagedDragTarget(rubberBand(dx))
        let now = event.timestamp
        if let last = lastPagingSample, now > last.time {
            let v = (point.x - last.x) / CGFloat(now - last.time)
            pagingVelocity = pagingVelocity * 0.6 + v * 0.4
        }
        lastPagingSample = (point.x, now)
    }

    override func mouseUp(with event: NSEvent) {
        if marqueeStart != nil {
            endMarquee()
            return
        }
        defer { dragStartPoint = nil; isDragPaging = false; lastPagingSample = nil; pagingVelocity = 0 }
        stopPagedDragLink()
        if isDragPaging {
            let dx = pagedDragTarget            // where the pointer is, not the eased value still catching up
            displayedDragOffset = 0
            if abs(dx) <= 50 { applyPagedOffset(animated: true) }
            else if dx > 0 { previousPage() }
            else { nextPage() }
            return
        }
        guard let start = dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - start.x, point.y - start.y) < 4 {
            handleEmptyAreaClick()
        }
    }

    private func handleEmptyAreaClick() {
        if clearAllHighlights() { return }
        if isUninstallModeActive { exitUninstallMode(); return }
        onRequestHideLauncher?()
    }

    // MARK: - Activation

    func activate(_ group: LaunchpadGroup) {
        if group.isFolder {
            // 0 = pointer, 1 = keyboard.
            if let cell = groupViews[group.id] { openFolder(groupView: cell, source: 0) }
            return
        }
        guard let app = group.apps.first else { return }
        guard !app.isSourceUnavailable else { return }
        groupViews[group.id]?.appView?.playLaunchAnimation()
        let url = app.url
        hideLauncherThen {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { LogManager.shared.error("Failed to open \(url.path): \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Selection

    private func select(group: LaunchpadGroup) {
        clearSelection()
        activeGroupID = group.id
        groupViews[group.id]?.isHighlight = true
    }

    func clearSelection() {
        if let id = activeGroupID { groupViews[id]?.isHighlight = false }
        activeGroupID = nil
    }

    private func activateSelection() {
        if let id = activeGroupID, let group = displayedGroups.first(where: { $0.id == id }) {
            activate(group)
        } else if !searchView.inputField.stringValue.isEmpty, let first = displayedGroups.first {
            activate(first)            // Return in a search with nothing selected opens the top result
        }
    }

    private func moveSelection(dx: Int, dy: Int) {
        let perPage = appState.perPage
        let columns = appState.columns
        if activeGroupID == nil {
            if let first = displayedGroups.first { select(group: first) }
            return
        }
        let flatIndex = displayedGroups.firstIndex { $0.id == activeGroupID } ?? 0
        var slot = flatIndex % perPage
        var page = flatIndex / perPage
        if dy != 0 {
            slot += dy * columns
        } else {
            slot += dx
        }
        if slot < 0 {
            if page > 0 { page -= 1; slot += perPage } else { slot = 0 }
        } else if slot >= perPage {
            if page < totalPages - 1 { page += 1; slot -= perPage } else { slot = perPage - 1 }
        }
        let target = page * perPage + slot
        guard target >= 0, target < displayedGroups.count else { return }
        select(group: displayedGroups[target])
        if page != currentPage { setPage(page, animated: true) }
    }

    // MARK: - Keyboard

    private var keyboardMonitor: Any?

    private func installKeyboardMonitorIfNeeded() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Active only while our window is key and no sheet is up.
            guard let self, self.window?.isKeyWindow == true, self.window?.attachedSheet == nil else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Any key leaves the Option-hold uninstall mode first.
        if isOptionUninstallModeActive { optionKeyUp() }
        if isUninstallModeActive, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            exitUninstallMode()
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "," {
            onOpenPreferences?()
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }
        // While a folder / app title is being edited, Return and the arrows belong to that text field
        // (Return commits through its action; the arrows move the caret).
        let titleEditing = openedFolderTitleEditorView != nil || groupViews.values.contains(where: \.isEditing)
            || openedFolderAppViews.contains(where: \.isEditing)
        if titleEditing, [36, 76, 123, 124, 125, 126].contains(Int(event.keyCode)) { return false }
        switch event.keyCode {
        case 123: // left
            if modifiers.contains(.command) { previousPage() } else { moveSelection(dx: -1, dy: 0) }
            return true
        case 124: // right
            if modifiers.contains(.command) { nextPage() } else { moveSelection(dx: 1, dy: 0) }
            return true
        case 125: // down
            if modifiers.isEmpty { moveSelection(dx: 0, dy: 1); return true }
            return false
        case 126: // up
            if modifiers.isEmpty { moveSelection(dx: 0, dy: -1); return true }
            return false
        case 36, 76: // return
            // Not while an input method is composing text in the field editor.
            if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            if modifiers.isEmpty { activateSelection(); return true }
            return false
        case 53: // esc
            handleEscape()
            return true
        default:
            let isEditingText = openedFolderTitleEditorView != nil || groupViews.values.contains(where: \.isEditing)
                || openedFolderAppViews.contains(where: \.isEditing)
            // Once the search field is being edited it handles its own keys (caret, delete, further letters);
            // re-focusing it here would select all and every letter would replace the previous one.
            if let editor = searchView.inputField.currentEditor(), window?.firstResponder === editor { return false }
            if !isEditingText, let characters = event.characters, !characters.isEmpty,
               !characters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }),
               modifiers.isEmpty || modifiers == .shift {
                searchView.focusField()
                searchView.inputField.currentEditor()?.insertText(characters)
                return true
            }
            return false
        }
    }

    /// Esc, in order: cancel drag → clear multi-selection → cancel title edit → (folder open:
    /// exit uninstall mode or close the folder) → exit uninstall mode → clear search → clear keyboard
    /// selection → close Preferences / Permissions window → hide the launcher.
    private func handleEscape() {
        if isDragPaging { dragStartPoint = nil; isDragPaging = false; displayedDragOffset = 0; applyPagedOffset(animated: false); return }
        if drag != nil { endDrag(cancelled: true); return }
        if selectedGroups.count >= 2 { clearAllHighlights(); return }
        if openedFolderTitleEditorView != nil { endFolderTitleEdit(save: false); return }
        if let editing = (Array(groupViews.values) + openedFolderAppViews).first(where: { $0.isEditing }) {
            editing.cancelRename()
            return
        }
        if openedFolderID != nil {
            if isUninstallModeActive { exitUninstallMode() } else { closeFolder(animated: true) }
            return
        }
        if isUninstallModeActive { exitUninstallMode(); return }
        if !searchView.inputField.stringValue.isEmpty { searchView.clear(notify: true); return }
        if clearAllHighlights() { return }
        for helper in [PreferencesWindowController.shared.window, PermissionsWindowController.shared.window] {
            if let helper, helper.isVisible { helper.close(); return }
        }
        onRequestHideLauncher?()
    }

    // MARK: - Option-hold uninstall

    func optionKeyDown() {
        guard appState.enableOptionUninstallMode, !isUninstallModeActive else { return }
        optionUninstallWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isOptionUninstallModeActive = true
            self.enterUninstallMode(focused: nil)
        }
        optionUninstallWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func optionKeyUp() {
        optionUninstallWorkItem?.cancel()
        optionUninstallWorkItem = nil
        if isOptionUninstallModeActive {
            isOptionUninstallModeActive = false
            exitUninstallMode()
        }
    }

    func enterUninstallMode(focused: LaunchpadGroup?) {
        guard !isUninstallModeActive else { return }
        isUninstallModeActive = true
        for view in groupViews.values { view.isUninstallMode = true }
        _ = focused
    }

    func exitUninstallMode() {
        guard isUninstallModeActive else { return }
        isUninstallModeActive = false
        for view in groupViews.values { view.isUninstallMode = false }
    }

    // MARK: - Search

    /// Where the grid was before a search started (`SearchReturnPosition`).
    private struct SearchReturnPosition {
        var browsingStyle: BrowsingStyleType
        var page: Int
        var scrollOrigin: CGPoint
    }
    private var searchReturnPosition: SearchReturnPosition?

    private func handleQueryChange(query: String, previous: String) {
        if previous.isEmpty && !query.isEmpty {
            exitUninstallMode()
            searchReturnPosition = SearchReturnPosition(browsingStyle: appState.browsingStyle, page: currentPage,
                                                        scrollOrigin: scrollModeView.contentView.bounds.origin)
            // Jump to the top, unanimated.
            if appState.browsingStyle == .scroll {
                scrollModeView.contentView.scroll(to: .zero)
                scrollModeView.reflectScrolledClipView(scrollModeView.contentView)
            } else {
                setPage(0, animated: false)
            }
            dataManager.currentSearchQuery = query
            reloadFromDataManager()
            if appState.browsingStyle == .scroll {
                scrollModeView.contentView.scroll(to: .zero)
                scrollModeView.reflectScrolledClipView(scrollModeView.contentView)
            }
        } else if !previous.isEmpty && query.isEmpty {
            dataManager.currentSearchQuery = ""
            reloadFromDataManager()
            // Restore the position only when the browsing style did not change meanwhile.
            if let position = searchReturnPosition, position.browsingStyle == appState.browsingStyle {
                if position.browsingStyle == .scroll {
                    scrollModeView.contentView.scroll(to: position.scrollOrigin)
                    scrollModeView.reflectScrolledClipView(scrollModeView.contentView)
                } else {
                    setPage(min(max(position.page, 0), max(totalPages - 1, 0)), animated: false)
                }
            }
            searchReturnPosition = nil
        } else {
            dataManager.currentSearchQuery = query
            reloadFromDataManager()
        }
    }

    private func reloadFromDataManager() {
        dataManager.publish(2)
    }

    // MARK: - Context menus

}

extension LaunchpadContentView: NSDraggingSource {
    /// `.private` (8) like the original; the Dock answers `.generic` when it takes the app.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.generic, .private]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard drag?.dockSession === session else { return }
        endDrag(cancelled: operation == .generic)
    }
}

/// Overlay that swallows clicks and reports a plain mouse-down.
final class OverlayView: NSView {
    var onMouseDown: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { onMouseDown?() }
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
}

/// A flipped container used by the scroll-mode document view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Drag payload carried on the pasteboard.
struct DragPayload {
    var app: LaunchpadApp
    var groupId: String

    static let typeIdentifier = NSPasteboard.PasteboardType("app.gridura.Gridura.group")

    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        let dict: [String: String] = ["appId": app.id, "groupId": groupId, "name": app.name]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let string = String(data: data, encoding: .utf8) {
            item.setString(string, forType: Self.typeIdentifier)
        }
        return item
    }
}
