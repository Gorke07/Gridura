#!/usr/bin/env swift
// Draws Gridura's own icon set into Assets.xcassets (no third-party artwork):
//   AppIcon.appiconset      — the Dock / Finder icon
//   AppIcon/<Base>-<Light|Dark>.imageset — the five choices in Settings › General (+ runtime Dock icon)
//   Logo.imageset           — About tab and onboarding guide
//   MenuBarIcon.imageset    — template glyph for the status item
//   DisplayMode/*.imageset  — the Full Screen / Window previews in Settings and the guide
//   Search, More, Update, Tab/*, Status/* — monochrome glyphs (SF Symbols rendered as templates)
//   UnstallBtn, Confetti, GuideBg — uninstall ✕ button and the onboarding artwork
//
// Run:  swift Scripts/generate_icons.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("Gridura/Resources/Assets.xcassets")

// MARK: - Helpers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Renders a `size`×`size` px bitmap; `draw` works in a 1024-point canvas (y up).
func render(size: Int, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.interpolationQuality = .high
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// macOS-style squircle (superellipse, n = 5) centred in the 1024 canvas.
func squircle(half: CGFloat = 412) -> CGPath {
    let path = CGMutablePath()
    let n = 5.0, steps = 360
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = 512 + half * CGFloat(c.sign == .minus ? -pow(abs(c), 2 / n) : pow(abs(c), 2 / n))
        let y = 512 + half * CGFloat(s.sign == .minus ? -pow(abs(s), 2 / n) : pow(abs(s), 2 / n))
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func gradient(_ colors: [NSColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray,
               locations: locations)!
}

func fill(_ cg: CGContext, path: CGPath, gradient g: CGGradient, from: CGPoint, to: CGPoint) {
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    cg.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Icon body: soft shadow, gradient fill, top gloss and a hairline edge. `content` draws inside the clip.
func iconBody(_ cg: CGContext, top: NSColor, bottom: NSColor, edge: NSColor, shadow: Bool = true,
              _ content: () -> Void) {
    let body = squircle()
    if shadow {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.38).cgColor)
        cg.addPath(body)
        cg.setFillColor(bottom.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }
    fill(cg, path: body, gradient: gradient([top, bottom]), from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    cg.saveGState()
    cg.addPath(body)
    cg.clip()
    // Gloss: a faint light falling from the top edge.
    cg.drawLinearGradient(gradient([NSColor.white.withAlpha(0.20), NSColor.white.withAlpha(0)]),
                          start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    content()
    cg.restoreGState()
    cg.addPath(body)
    cg.setStrokeColor(edge.cgColor)
    cg.setLineWidth(4)
    cg.strokePath()
}

extension NSColor {
    func withAlpha(_ a: CGFloat) -> NSColor { withAlphaComponent(a) }
}

// MARK: - Motifs

/// 3×3 app grid; tile (0,0) is the amber accent, the rest fade diagonally.
func drawTileGrid(_ cg: CGContext, tile: NSColor = .white, accent: Bool = true) {
    let size: CGFloat = 150, gap: CGFloat = 40, radius: CGFloat = 40
    let start = 512 - (3 * size + 2 * gap) / 2
    for row in 0..<3 {
        for col in 0..<3 {
            let rect = CGRect(x: start + CGFloat(col) * (size + gap),
                              y: start + CGFloat(2 - row) * (size + gap), width: size, height: size)
            let path = roundedRect(rect, radius)
            if row == 0 && col == 0 && accent {
                cg.saveGState()
                cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0xFF9F1C, 0.55).cgColor)
                fill(cg, path: path, gradient: gradient([color(0xFFE08A), color(0xFF9F1C)]),
                     from: CGPoint(x: rect.midX, y: rect.maxY), to: CGPoint(x: rect.midX, y: rect.minY))
                cg.restoreGState()
            } else {
                cg.addPath(path)
                cg.setFillColor(tile.withAlpha(max(0.95 - 0.12 * CGFloat(row + col), 0.35)).cgColor)
                cg.fillPath()
            }
        }
    }
}

/// Nine coloured dots, the classic launcher look.
func drawDots(_ cg: CGContext, bright: Bool) {
    let palette: [UInt32] = bright
        ? [0xFF5F57, 0xFF9F0A, 0xFFD60A, 0x30D158, 0x40C8E0, 0x0A84FF, 0x5E5CE6, 0xBF5AF2, 0xFF375F]
        : [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x00C7BE, 0x007AFF, 0x5856D6, 0xAF52DE, 0xFF2D55]
    let diameter: CGFloat = 148, gap: CGFloat = 48
    let start = 512 - (3 * diameter + 2 * gap) / 2
    for row in 0..<3 {
        for col in 0..<3 {
            let rect = CGRect(x: start + CGFloat(col) * (diameter + gap),
                              y: start + CGFloat(2 - row) * (diameter + gap), width: diameter, height: diameter)
            let base = color(palette[row * 3 + col])
            fill(cg, path: CGPath(ellipseIn: rect, transform: nil),
                 gradient: gradient([base.blended(withFraction: 0.35, of: .white) ?? base, base]),
                 from: CGPoint(x: rect.midX, y: rect.maxY), to: CGPoint(x: rect.midX, y: rect.minY))
        }
    }
}

func drawLetterG(_ cg: CGContext, fillColors: [NSColor]) {
    var font = NSFont.systemFont(ofSize: 640, weight: .heavy)
    if let rounded = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: rounded, size: 640) { font = f }
    let attributed = NSAttributedString(string: "G", attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    cg.saveGState()
    cg.translateBy(x: 512 - bounds.midX, y: 512 - bounds.midY)
    // Use the glyph outline as a clip so the letter can carry a gradient.
    cg.setTextDrawingMode(.clip)
    cg.textPosition = .zero
    CTLineDraw(line, cg)
    cg.drawLinearGradient(gradient(fillColors), start: CGPoint(x: 0, y: bounds.maxY + 40),
                          end: CGPoint(x: 0, y: bounds.minY - 40), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
}

func drawRocket(_ cg: CGContext, body: NSColor, window: NSColor, flame: [NSColor]) {
    cg.saveGState()
    cg.translateBy(x: 512, y: 512)
    cg.rotate(by: -.pi / 4)
    cg.scaleBy(x: 1.0, y: 1.0)

    // Flame
    let flamePath = CGMutablePath()
    flamePath.move(to: CGPoint(x: -64, y: -130))
    flamePath.addCurve(to: CGPoint(x: 0, y: -330), control1: CGPoint(x: -80, y: -230), control2: CGPoint(x: -20, y: -270))
    flamePath.addCurve(to: CGPoint(x: 64, y: -130), control1: CGPoint(x: 20, y: -270), control2: CGPoint(x: 80, y: -230))
    flamePath.closeSubpath()
    fill(cg, path: flamePath, gradient: gradient(flame), from: CGPoint(x: 0, y: -130), to: CGPoint(x: 0, y: -330))

    // Fins
    for sign in [CGFloat(-1), 1] {
        let fin = CGMutablePath()
        fin.move(to: CGPoint(x: sign * 100, y: 10))
        fin.addCurve(to: CGPoint(x: sign * 215, y: -190), control1: CGPoint(x: sign * 190, y: -20), control2: CGPoint(x: sign * 220, y: -110))
        fin.addLine(to: CGPoint(x: sign * 100, y: -130))
        fin.closeSubpath()
        cg.addPath(fin)
        cg.setFillColor(body.blended(withFraction: 0.25, of: .black)?.cgColor ?? body.cgColor)
        cg.fillPath()
    }

    // Body
    let hull = CGMutablePath()
    hull.move(to: CGPoint(x: 0, y: 330))
    hull.addCurve(to: CGPoint(x: 112, y: 70), control1: CGPoint(x: 78, y: 250), control2: CGPoint(x: 112, y: 160))
    hull.addLine(to: CGPoint(x: 112, y: -130))
    hull.addLine(to: CGPoint(x: -112, y: -130))
    hull.addLine(to: CGPoint(x: -112, y: 70))
    hull.addCurve(to: CGPoint(x: 0, y: 330), control1: CGPoint(x: -112, y: 160), control2: CGPoint(x: -78, y: 250))
    hull.closeSubpath()
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: NSColor.black.withAlpha(0.25).cgColor)
    cg.addPath(hull)
    cg.setFillColor(body.cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Window
    let ring = CGRect(x: -58, y: 62, width: 116, height: 116)
    cg.addEllipse(in: ring)
    cg.setFillColor(body.blended(withFraction: 0.3, of: .black)?.cgColor ?? body.cgColor)
    cg.fillPath()
    cg.addEllipse(in: ring.insetBy(dx: 14, dy: 14))
    cg.setFillColor(window.cgColor)
    cg.fillPath()
    cg.restoreGState()
}

// MARK: - Variants

struct Variant {
    var name: String                         // base used in "AppIcon/<name>-<Light|Dark>"
    var draw: (CGContext, Bool) -> Void      // (context, dark)
}

let variants: [Variant] = [
    Variant(name: "Gridura") { cg, dark in
        iconBody(cg, top: dark ? color(0x2D2A4A) : color(0x7B6BFF), bottom: dark ? color(0x0E0C20) : color(0x2B1CA6),
                 edge: NSColor.white.withAlpha(dark ? 0.10 : 0.22)) { drawTileGrid(cg) }
    },
    Variant(name: "Brand") { cg, dark in
        iconBody(cg, top: dark ? color(0x16394A) : color(0x2FE0CF), bottom: dark ? color(0x061219) : color(0x0A5FE0),
                 edge: NSColor.white.withAlpha(dark ? 0.10 : 0.22)) {
            drawLetterG(cg, fillColors: dark ? [color(0xCFFCF6), color(0x39D0C0)] : [.white, color(0xDDF4FF)])
        }
    },
    Variant(name: "Classic") { cg, dark in
        iconBody(cg, top: dark ? color(0x46464D) : .white, bottom: dark ? color(0x17171A) : color(0xDDE0E8),
                 edge: dark ? NSColor.white.withAlpha(0.10) : NSColor.black.withAlpha(0.12)) { drawDots(cg, bright: dark) }
    },
    Variant(name: "ClassicDark") { cg, _ in
        iconBody(cg, top: color(0x46464D), bottom: color(0x17171A), edge: NSColor.white.withAlpha(0.10)) {
            drawDots(cg, bright: true)
        }
    },
    Variant(name: "Rocket") { cg, dark in
        iconBody(cg, top: dark ? color(0x4B2A6B) : color(0xFFA23F), bottom: dark ? color(0x180D2C) : color(0xE5245E),
                 edge: NSColor.white.withAlpha(dark ? 0.10 : 0.22)) {
            drawRocket(cg, body: .white, window: dark ? color(0x6C4BB8) : color(0xE5245E),
                       flame: [color(0xFFE08A), color(0xFF7A1C), color(0xFF2D55, 0.0)])
        }
    },
]

// MARK: - Output

func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func writeJSON(_ object: Any, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

func imagesetContents(light: String, dark: String, template: Bool = false) -> [String: Any] {
    var result: [String: Any] = [
        "images": [
            ["idiom": "mac", "filename": light, "scale": "2x"],
            ["idiom": "mac", "filename": dark, "scale": "2x",
             "appearances": [["appearance": "luminosity", "value": "dark"]]],
        ],
        "info": ["author": "xcode", "version": 1],
    ]
    if template { result["properties"] = ["template-render-intent": "template"] }
    return result
}

do {
    // 1. Choices in Settings: AppIcon/<Base>-<Light|Dark>.imageset (512 px; both appearances share the art).
    for variant in variants {
        for (suffix, dark) in [("Light", false), ("Dark", true)] {
            let dir = catalog.appendingPathComponent("AppIcon/\(variant.name)-\(suffix).imageset")
            let png = render(size: 512) { variant.draw($0, dark) }
            let lightName = "AppIcon_\(variant.name)-\(suffix)-light@2x.png"
            let darkName = "AppIcon_\(variant.name)-\(suffix)-dark@2x.png"
            try write(png, to: dir.appendingPathComponent(lightName))
            try write(png, to: dir.appendingPathComponent(darkName))
            try writeJSON(imagesetContents(light: lightName, dark: darkName), to: dir.appendingPathComponent("Contents.json"))
        }
    }

    // 2. Dock / Finder icon: the default Gridura variant at every macOS size.
    let appIconDir = catalog.appendingPathComponent("AppIcon.appiconset")
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        try write(render(size: size) { variants[0].draw($0, false) }, to: appIconDir.appendingPathComponent("icon_\(size).png"))
    }

    // 3. Logo (About tab, guide): the same icon at 1024 px, dark variant for dark appearance.
    let logoDir = catalog.appendingPathComponent("Logo.imageset")
    try write(render(size: 1024) { variants[0].draw($0, false) }, to: logoDir.appendingPathComponent("Logo-light@2x.png"))
    try write(render(size: 1024) { variants[0].draw($0, true) }, to: logoDir.appendingPathComponent("Logo-dark@2x.png"))

    // 4. Menu bar template glyph: 3×3 rounded tiles, 34×30 px (17×15 pt @2x), black on clear.
    func menuGlyph() -> Data {
        let width = 34, height = 30
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)     // draw in pixel units
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        let tile: CGFloat = 8.5, gap: CGFloat = 2.5
        let originX = (CGFloat(width) - (3 * tile + 2 * gap)) / 2, originY = (CGFloat(height) - (3 * tile + 2 * gap)) / 2
        for row in 0..<3 {
            for col in 0..<3 {
                let rect = CGRect(x: originX + CGFloat(col) * (tile + gap), y: originY + CGFloat(2 - row) * (tile + gap),
                                  width: tile, height: tile)
                cg.addPath(roundedRect(rect, 2.4))
                cg.setFillColor(NSColor.black.cgColor)
                cg.fillPath()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    let menuDir = catalog.appendingPathComponent("MenuBarIcon.imageset")
    try write(menuGlyph(), to: menuDir.appendingPathComponent("MenuBarIcon-light@2x.png"))
    try write(menuGlyph(), to: menuDir.appendingPathComponent("MenuBarIcon-dark@2x.png"))
    try writeJSON(imagesetContents(light: "MenuBarIcon-light@2x.png", dark: "MenuBarIcon-dark@2x.png", template: true),
                  to: menuDir.appendingPathComponent("Contents.json"))

    // 5. Display-mode previews (288×192 px): a desktop with either the full-screen grid or a window.
    func displayModePreview(window: Bool) -> Data {
        let width = 288, height = 192
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)     // draw in pixel units
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        // Desktop wallpaper.
        cg.drawLinearGradient(gradient([color(0x3A1C8C), color(0x1B6FD6), color(0xF0608C)], [0, 0.55, 1]),
                              start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        cg.saveGState()
        cg.addRect(full); cg.clip()
        cg.drawRadialGradient(gradient([NSColor.white.withAlpha(0.28), NSColor.white.withAlpha(0)]),
                              startCenter: CGPoint(x: 70, y: 150), startRadius: 0,
                              endCenter: CGPoint(x: 70, y: 150), endRadius: 120, options: [])
        cg.restoreGState()

        func tiles(in area: CGRect, columns: Int, rows: Int, size: CGFloat, color tile: NSColor) {
            let gapX = (area.width - CGFloat(columns) * size) / CGFloat(columns + 1)
            let gapY = (area.height - CGFloat(rows) * size) / CGFloat(rows + 1)
            for row in 0..<rows {
                for col in 0..<columns {
                    let rect = CGRect(x: area.minX + gapX + CGFloat(col) * (size + gapX),
                                      y: area.maxY - gapY - size - CGFloat(row) * (size + gapY), width: size, height: size)
                    cg.addPath(roundedRect(rect, size * 0.28)); cg.setFillColor(tile.cgColor); cg.fillPath()
                }
            }
        }
        if window {
            let panel = CGRect(x: 42, y: 26, width: 204, height: 140)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: NSColor.black.withAlpha(0.35).cgColor)
            cg.addPath(roundedRect(panel, 18)); cg.setFillColor(NSColor.white.withAlpha(0.80).cgColor); cg.fillPath()
            cg.restoreGState()
            let search = CGRect(x: panel.minX + 14, y: panel.maxY - 30, width: panel.width - 28, height: 16)
            cg.addPath(roundedRect(search, 8)); cg.setFillColor(NSColor.black.withAlpha(0.10).cgColor); cg.fillPath()
            tiles(in: CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: panel.height - 36),
                  columns: 5, rows: 3, size: 20, color: color(0x4B4F66, 0.55))
        } else {
            cg.setFillColor(NSColor.black.withAlpha(0.32).cgColor); cg.fill(full)
            let search = CGRect(x: 104, y: 166, width: 80, height: 12)
            cg.addPath(roundedRect(search, 6)); cg.setFillColor(NSColor.white.withAlpha(0.28).cgColor); cg.fillPath()
            tiles(in: CGRect(x: 14, y: 30, width: 260, height: 128), columns: 7, rows: 3, size: 22,
                  color: NSColor.white.withAlpha(0.82))
            for i in 0..<3 {
                let dot = CGRect(x: 133 + CGFloat(i) * 12, y: 14, width: 6, height: 6)
                cg.setFillColor(NSColor.white.withAlpha(i == 0 ? 0.95 : 0.45).cgColor)
                cg.fillEllipse(in: dot)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    for (name, isWindow) in [("FullScreen", false), ("Window", true)] {
        let dir = catalog.appendingPathComponent("DisplayMode/\(name).imageset")
        let light = "DisplayMode_\(name)-light@2x.png", dark = "DisplayMode_\(name)-dark@2x.png"
        let png = displayModePreview(window: isWindow)
        try write(png, to: dir.appendingPathComponent(light))
        try write(png, to: dir.appendingPathComponent(dark))
        try writeJSON(imagesetContents(light: light, dark: dark), to: dir.appendingPathComponent("Contents.json"))
    }

    // 6. Monochrome template glyphs rendered from SF Symbols (tinted by the app at draw time).
    func symbolGlyph(_ name: String, pixels: Int, point: CGFloat, weight: NSFont.Weight) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let configuration = NSImage.SymbolConfiguration(pointSize: point, weight: weight)
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let side = CGFloat(pixels)
            let fit = min(side / symbol.size.width, side / symbol.size.height) * 0.86
            let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
            let rect = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
            symbol.draw(in: rect)
            NSColor.black.setFill()
            rect.fill(using: .sourceAtop)
        } else {
            print("missing SF Symbol: \(name)")
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Writes `<folder>/<name>.imageset` with identical light/dark art.
    func writeImageSet(_ folder: String, _ name: String, prefix: String, png: Data, template: Bool) throws {
        let dir = catalog.appendingPathComponent("\(folder)\(name).imageset")
        let light = "\(prefix)-light@2x.png", dark = "\(prefix)-dark@2x.png"
        try write(png, to: dir.appendingPathComponent(light))
        try write(png, to: dir.appendingPathComponent(dark))
        try writeJSON(imagesetContents(light: light, dark: dark, template: template), to: dir.appendingPathComponent("Contents.json"))
    }

    let glyphs: [(folder: String, name: String, prefix: String, symbol: String, pixels: Int, weight: NSFont.Weight)] = [
        ("", "Search", "Search", "magnifyingglass", 48, .semibold),
        ("", "More", "More", "ellipsis.circle", 48, .regular),
        ("", "Update", "Update", "arrow.up.circle.fill", 48, .regular),
        ("Tab/", "General", "Tab_General", "gearshape", 48, .regular),
        ("Tab/", "Interface", "Tab_Interface", "macwindow", 48, .regular),
        ("Tab/", "Apps", "Tab_Apps", "square.grid.2x2", 48, .regular),
        ("Tab/", "Advanced", "Tab_Advanced", "slider.horizontal.3", 48, .regular),
        ("Tab/", "Info", "Tab_Info", "info.circle", 48, .regular),
        ("Status/", "Loading", "Status_Loading", "circle.dotted", 720, .ultraLight),
        ("Status/", "SearchEmpty", "Status_SearchEmpty", "magnifyingglass", 720, .ultraLight),
    ]
    for g in glyphs {
        try writeImageSet(g.folder, g.name, prefix: g.prefix,
                          png: symbolGlyph(g.symbol, pixels: g.pixels, point: CGFloat(g.pixels) * 0.7, weight: g.weight),
                          template: true)
    }

    // 7. Uninstall ✕ button (96 px): light disc, dark cross.
    func uninstallButton() -> Data {
        let size = 96
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size, height: size)
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        let disc = CGRect(x: 6, y: 6, width: 84, height: 84)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: NSColor.black.withAlpha(0.30).cgColor)
        cg.addEllipse(in: disc); cg.setFillColor(color(0xE9EAEE).cgColor); cg.fillPath()
        cg.restoreGState()
        fill(cg, path: CGPath(ellipseIn: disc, transform: nil), gradient: gradient([.white, color(0xD9DBE2)]),
             from: CGPoint(x: 48, y: 90), to: CGPoint(x: 48, y: 6))
        cg.setStrokeColor(color(0x2B2D36).cgColor)
        cg.setLineWidth(8); cg.setLineCap(.round)
        cg.move(to: CGPoint(x: 33, y: 33)); cg.addLine(to: CGPoint(x: 63, y: 63))
        cg.move(to: CGPoint(x: 63, y: 33)); cg.addLine(to: CGPoint(x: 33, y: 63))
        cg.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    try writeImageSet("", "UnstallBtn", prefix: "UnstallBtn", png: uninstallButton(), template: false)

    // 8. Onboarding: confetti burst (576 px) and the guide's soft gradient background (880×1160 px).
    func confetti() -> Data {
        let size = 576
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size, height: size)
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        var seed: UInt64 = 0xB3_1A_0C_E5
        func random() -> CGFloat {                       // small deterministic generator
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
        let palette: [UInt32] = [0xFF5F57, 0xFF9F0A, 0xFFD60A, 0x30D158, 0x40C8E0, 0x0A84FF, 0x7D7AFF, 0xBF5AF2, 0xFF375F]
        for _ in 0..<70 {
            let angle = random() * 2 * .pi
            let radius = 70 + random() * 205
            let center = CGPoint(x: 288 + cos(angle) * radius, y: 288 + sin(angle) * radius)
            let w = 12 + random() * 22, h = 8 + random() * 12
            cg.saveGState()
            cg.translateBy(x: center.x, y: center.y)
            cg.rotate(by: random() * .pi)
            cg.setFillColor(color(palette[Int(random() * CGFloat(palette.count)) % palette.count]).cgColor)
            if random() < 0.35 {
                cg.fillEllipse(in: CGRect(x: -w / 2, y: -w / 2, width: w * 0.7, height: w * 0.7))
            } else {
                cg.addPath(roundedRect(CGRect(x: -w / 2, y: -h / 2, width: w, height: h), 3)); cg.fillPath()
            }
            cg.restoreGState()
        }
        // The party popper in the middle: the Gridura grid tile.
        let tile = CGRect(x: 208, y: 208, width: 160, height: 160)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlpha(0.3).cgColor)
        fill(cg, path: roundedRect(tile, 40), gradient: gradient([color(0x7B6BFF), color(0x2B1CA6)]),
             from: CGPoint(x: 288, y: 368), to: CGPoint(x: 288, y: 208))
        cg.restoreGState()
        cg.setStrokeColor(NSColor.white.cgColor); cg.setLineWidth(18); cg.setLineCap(.round); cg.setLineJoin(.round)
        cg.move(to: CGPoint(x: 246, y: 286)); cg.addLine(to: CGPoint(x: 278, y: 252)); cg.addLine(to: CGPoint(x: 336, y: 322))
        cg.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    try writeImageSet("", "Confetti", prefix: "Confetti", png: confetti(), template: false)

    func guideBackground() -> Data {
        let width = 880, height = 1160
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.drawLinearGradient(gradient([color(0x1B1550), color(0x3D1D8F), color(0x0B5FD0)], [0, 0.55, 1]),
                              start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        let blobs: [(CGPoint, CGFloat, UInt32)] = [
            (CGPoint(x: 160, y: 1000), 520, 0xFF6BB5), (CGPoint(x: 760, y: 820), 480, 0x4DD0FF),
            (CGPoint(x: 220, y: 330), 460, 0x8F6BFF), (CGPoint(x: 700, y: 130), 420, 0xFFB44D),
        ]
        for (center, radius, hex) in blobs {
            cg.drawRadialGradient(gradient([color(hex, 0.75), color(hex, 0)]), startCenter: center, startRadius: 0,
                                  endCenter: center, endRadius: radius, options: [])
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    try writeImageSet("", "GuideBg", prefix: "GuideBg", png: guideBackground(), template: false)

    // 9. Drop artwork that nothing references any more (original export leftovers).
    for unused in ["Device.imageset", "Success.imageset", "Time.imageset", "Settings.imageset", "Folder.imageset",
                   "Status/Expired.imageset"] {
        try? FileManager.default.removeItem(at: catalog.appendingPathComponent(unused))
    }

    print("Icons written to \(catalog.path)")
} catch {
    print("Failed: \(error)")
    exit(1)
}
