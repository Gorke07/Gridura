import AppKit

/// Fonts, shadows and asset colours shared across the grid
/// ( and ).
enum DesignTokens {
    /// Cell label font: body point size, semibold (= 13 pt on default settings).
    static let labelFont: NSFont = {
        let size = NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }()

    /// Light-appearance label font: body point size, medium.
    static let labelFontLight: NSFont = {
        let size = NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize
        return NSFont.systemFont(ofSize: size, weight: .medium)
    }()

    /// Status title font: title1 point size, regular (= 22 pt).
    static let statusTitleFont: NSFont = {
        let size = NSFont.preferredFont(forTextStyle: .title1, options: [:]).pointSize
        return NSFont.systemFont(ofSize: size, weight: .regular)
    }()

    /// Label shadow (dark appearance only): black α0.26, blur 2, offset (0, −1).
    static let labelShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }()

    /// `ceil(labelFont.boundingRectForFont.height)` (= 17).
    static var labelFontHeight: CGFloat { ceil(labelFont.boundingRectForFont.height) }

    /// The 8 pt gap below the label, reserved in the cell even when names are hidden.
    static var labelBlock: CGFloat { labelFontHeight + 8 }

    static let animationEaseInEaseOut = CAMediaTimingFunction(name: .easeInEaseOut)
    static let animationEaseOut = CAMediaTimingFunction(name: .easeOut)
    static let frameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

    // MARK: Asset colours (asset catalog names)

    static func color(_ name: String) -> NSColor? {
        NSColor(named: name)
    }
}

extension NSColor {
    /// Resolves an asset colour, falling back to a literal.
    static func resource(_ name: String, fallback: NSColor) -> NSColor {
        NSColor(named: name) ?? fallback
    }
}

/// Timing function used by the launchpad's own animations (control points 0.2, 0.9, 0.3, 1.0).
let launchpadTimingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
