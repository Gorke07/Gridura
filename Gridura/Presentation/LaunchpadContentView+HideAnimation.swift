import AppKit

// Hide animation: the hidden icons shrink out from their centre, the data
// manager hides them, then the remaining cells glide into the gaps.

/// A floating snapshot of an icon that shrinks away (`LaunchpadHidePreviewView`).
final class LaunchpadHidePreviewView: NSView {
    private let iconLayer = CALayer()

    init(frame: CGRect, snapshot: NSImage?, scale: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = scale
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        iconLayer.bounds = CGRect(origin: .zero, size: frame.size)
        iconLayer.position = CGPoint(x: frame.width * 0.5, y: frame.height * 0.5)
        iconLayer.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "opacity": NSNull()]
        if let snapshot {
            iconLayer.contents = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        layer?.addSublayer(iconLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `hideFromCenter`: scale 1 → 0.08, opacity [1, 1, 0] @ [0, 0.65, 1], 0.18 s ease-in.
    func hideFromCenter(completion: @escaping () -> Void) {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.08
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.65, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        iconLayer.transform = CATransform3DMakeScale(0.08, 0.08, 1)
        iconLayer.opacity = 0
        iconLayer.add(group, forKey: "hideFromCenter")
        CATransaction.commit()
    }
}

/// State of one running hide (`LaunchpadHideAnimation`).
final class LaunchpadHideAnimation {
    var originals: [LaunchpadGroupView] = []
    var previews: [LaunchpadHidePreviewView] = []
    var commit: (() -> Void)?
    var previousOrigins: [String: CGPoint] = [:]
}

extension LaunchpadContentView {
    /// `hideApps(ids)`.
    func hideApps(ids: [String]) {
        cancelHideAnimation()
        let idSet = Set(ids)
        let apps = dataManager.allGroups.flatMap(\.apps).filter { idSet.contains($0.id) }
        guard !apps.isEmpty else { return }

        let mounted = Array(groupViews.values) + openedFolderAppViews
        let targets = mounted.filter { view in
            guard let group = view.group, !group.isFolder, let app = group.apps.first,
                  idSet.contains(app.id), view.superview != nil, !view.isHidden else { return false }
            return convert(view.bounds, from: view).intersects(bounds)
        }
        guard window != nil, !targets.isEmpty else {
            dataManager.hide(apps: apps)
            return
        }

        let animation = LaunchpadHideAnimation()
        hideAnimation = animation
        animation.previousOrigins = captureCellOrigins()
        let scale = max(window?.backingScaleFactor ?? 2, 2)

        for view in targets {
            let frame = convert(view.iconContentFrame, from: view)
            var snapshot: NSImage?
            if let icon = view.appView, icon.bounds.width > 0,
               let rep = icon.bitmapImageRepForCachingDisplay(in: icon.bounds) {
                icon.cacheDisplay(in: icon.bounds, to: rep)
                let image = NSImage(size: icon.bounds.size)
                image.addRepresentation(rep)
                snapshot = image
            }
            let preview = LaunchpadHidePreviewView(frame: frame, snapshot: snapshot, scale: scale)
            addSubview(preview, positioned: .above, relativeTo: nil)
            animation.previews.append(preview)
            animation.originals.append(view)
            view.alphaValue = 0
        }

        animation.commit = { [weak self, weak animation] in
            guard let self, let animation, self.hideAnimation === animation else { return }
            // Closing the opened folder when all of its apps are going away.
            if let folderID = self.openedFolderID,
               let folder = self.dataManager.allGroups.first(where: { $0.id == folderID }),
               folder.apps.allSatisfy({ idSet.contains($0.id) }) {
                self.closeFolder(animated: false)
            }
            self.dataManager.hide(apps: apps) { [weak self] in
                self?.settleAfterHide(animation)
            }
        }

        var remaining = animation.previews.count
        for preview in animation.previews {
            preview.hideFromCenter { [weak self, weak animation] in
                remaining -= 1
                guard remaining == 0, let animation, self?.hideAnimation === animation else { return }
                let commit = animation.commit
                animation.commit = nil
                commit?()
            }
        }
    }

    ///: previews go away and the remaining cells glide into the gaps (0.36 s).
    private func settleAfterHide(_ animation: LaunchpadHideAnimation) {
        guard hideAnimation === animation else { return }
        animation.previews.forEach { $0.removeFromSuperview() }
        animation.originals.forEach { $0.alphaValue = 1 }
        layoutSubtreeIfNeeded()
        animateLayoutChange(from: animation.previousOrigins, sourcePoint: nil, appearScale: 1)
        hideAnimation = nil
    }

    ///: finish a running hide at once (pending commit runs, previews removed).
    func cancelHideAnimation() {
        guard let animation = hideAnimation else { return }
        let commit = animation.commit
        animation.commit = nil
        animation.previews.forEach { $0.removeFromSuperview() }
        animation.originals.forEach { $0.alphaValue = 1 }
        hideAnimation = nil
        commit?()
    }
}
