import AppKit

/// Layer-backed title text that never animates implicitly.
final class NonAnimatingTextLayer: CATextLayer {
    override func action(forKey event: String) -> CAAction? { NSNull() }

    override init() {
        super.init()
        isWrapped = false
        truncationMode = .end
        alignmentMode = .center
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 2)
        contentsScale = scale
        rasterizationScale = scale
        shouldRasterize = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
