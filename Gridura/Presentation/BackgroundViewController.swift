import AppKit
import CoreImage

/// Wallpaper capture, blur and glass background.
final class BackgroundViewController: NSViewController {
    private unowned let appState = AppState.shared

    private let wallpaperContainerLayer = CALayer()
    private let wallpaperLayer = CALayer()
    private let standbyWallpaperLayer = CALayer()
    private var visualView: NSVisualEffectView?
    private var glassView: NSGlassEffectView?

    private let wallpaperQueue = DispatchQueue(label: "app.gridura.Gridura.wallpaper", qos: .userInitiated)
    private var wallpaperRequestToken = 0
    private var defaultsObserver: NSObjectProtocol?

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true

        wallpaperContainerLayer.masksToBounds = true
        wallpaperContainerLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        configureWallpaperLayer(wallpaperLayer)
        configureWallpaperLayer(standbyWallpaperLayer)
        standbyWallpaperLayer.opacity = 0
        wallpaperContainerLayer.addSublayer(standbyWallpaperLayer)
        wallpaperContainerLayer.addSublayer(wallpaperLayer)
        view.layer?.addSublayer(wallpaperContainerLayer)

        if !appState.isBlurWallpaper && appState.wallpaperBlurRadius > 0 {
            appState.wallpaperBlurRadius = 0
        }

        defaultsObserver = NotificationChannel.center.addObserver(
            forName: NotificationChannel.Name.preferencesChanged, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.object as? Int, PreferenceModule(rawValue: raw) == .background else { return }
                self?.refresh(sync: false)
            }
        updateContainerFrame()
    }

    private func configureWallpaperLayer(_ layer: CALayer) {
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.actions = ["contents": NSNull(), "filters": NSNull(), "opacity": NSNull(),
                         "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateContainerFrame()
    }

    private func updateContainerFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperContainerLayer.frame = view.bounds
        wallpaperLayer.frame = view.bounds
        standbyWallpaperLayer.frame = view.bounds
        CATransaction.commit()
    }

    // MARK: - Refresh

    func refresh(sync: Bool) {
        if appState.displayMode == .fullScreen {
            glassView?.removeFromSuperview()
            glassView = nil
            // The wallpaper capture needs Screen Recording access (granted per bundle identity);
            // without it the capture comes back blank and the launcher would be see-through, so
            // fall back to the glass material.
            if appState.backgroundType == .glassEffect || !CGPreflightScreenCaptureAccess() {
                wallpaperRequestToken += 1
                clearWallpaper(scale: backingScale)
                installVisualEffect(material: appState.glassMaterial)
            } else {
                if sync { captureWallpaperSync() } else { captureWallpaperAsync() }
            }
        } else {
            wallpaperRequestToken += 1
            clearWallpaper(scale: backingScale)
            visualView?.removeFromSuperview()
            visualView = nil
            installGlass()
        }
    }

    private var backingScale: CGFloat {
        view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // MARK: - Visual effect / glass

    private func installVisualEffect(material: GlassMaterialType) {
        let effect: NSVisualEffectView
        if let existing = visualView {
            effect = existing
        } else {
            effect = NSVisualEffectView()
            effect.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(effect)
            NSLayoutConstraint.activate([
                effect.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                effect.topAnchor.constraint(equalTo: view.topAnchor),
                effect.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            visualView = effect
        }
        effect.blendingMode = .behindWindow
        effect.material = NSVisualEffectView.Material(rawValue: material.materialRawValue) ?? .hudWindow
        effect.state = .active
    }

    private func installGlass() {
        let glass: NSGlassEffectView
        if let existing = glassView {
            glass = existing
        } else {
            glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                glass.topAnchor.constraint(equalTo: view.topAnchor),
                glass.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            glassView = glass
        }
        glass.style = .regular
        glass.cornerRadius = 34
        if #available(macOS 27, *) {
            glass.tintColor = DesignTokens.color("WindowGlassTint")
        }
        GlassVariant.apply(to: glass, variant: GlassVariant.variant(fullScreen: false))
    }

    // MARK: - Wallpaper

    private func clearWallpaper(scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperLayer.removeAllAnimations()
        standbyWallpaperLayer.removeAllAnimations()
        wallpaperLayer.contents = nil
        standbyWallpaperLayer.contents = nil
        wallpaperLayer.contentsScale = scale
        standbyWallpaperLayer.contentsScale = scale
        wallpaperLayer.opacity = 1
        standbyWallpaperLayer.opacity = 0
        CATransaction.commit()
    }

    private func wallpaperUnavailable() {
        clearWallpaper(scale: backingScale)
        visualView?.removeFromSuperview()
        visualView = nil
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    private func captureWallpaperSync() {
        wallpaperRequestToken += 1
        let token = wallpaperRequestToken
        let target = wallpaperLayer.contents == nil ? wallpaperLayer : standbyWallpaperLayer
        let configured = configureFilters(target)
        var image: CGImage?
        wallpaperQueue.sync { image = Self.captureWallpaper(on: view.window?.screen ?? NSScreen.main) }
        guard token == wallpaperRequestToken else { return }
        guard let image else { wallpaperUnavailable(); return }
        let shown = !configured && appState.isBlurWallpaper
            ? cpuBlurred(image, radius: CGFloat(appState.wallpaperBlurRadius)) : image
        applyImage(blurFallback: nil, cgImage: shown, to: target, token: token, animated: false)
        visualView?.removeFromSuperview()
        visualView = nil
    }

    private func captureWallpaperAsync() {
        wallpaperRequestToken += 1
        let token = wallpaperRequestToken
        let screen = view.window?.screen ?? NSScreen.main
        wallpaperQueue.async { [weak self] in
            guard let self else { return }
            let image = Self.captureWallpaper(on: screen)
            DispatchQueue.main.async {
                guard token == self.wallpaperRequestToken else { return }
                guard let image else { self.wallpaperUnavailable(); return }
                let target = self.wallpaperLayer.contents == nil ? self.wallpaperLayer : self.standbyWallpaperLayer
                let configured = self.configureFilters(target)
                let shown = !configured && self.appState.isBlurWallpaper
                    ? self.cpuBlurred(image, radius: CGFloat(self.appState.wallpaperBlurRadius)) : image
                self.applyImage(blurFallback: nil, cgImage: shown, to: target, token: token, animated: true)
            }
        }
    }

    /// Captures the live desktop wallpaper window for a screen.
    static func captureWallpaper(on screen: NSScreen?) -> CGImage? {
        guard let screen else { return nil }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let displayBounds = CGDisplayBounds(displayID)
        guard let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }

        var best: (CGWindowID, Double)?
        for info in infos {
            guard let wid = info[kCGWindowNumber as String] as? NSNumber,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            let intersection = bounds.intersection(displayBounds)
            guard !intersection.isNull, displayBounds.width > 0, displayBounds.height > 0 else { continue }
            let coverage = (intersection.width * intersection.height) / (displayBounds.width * displayBounds.height)
            guard coverage > 0.9 else { continue }
            var score = coverage
            if let name = info[kCGWindowName as String] as? String, name.hasPrefix("Wallpaper") { score += 2 }
            if let layer = info[kCGWindowLayer as String] as? Int, layer < 0 { score += 1 }
            if best == nil || score > best!.1 { best = (CGWindowID(wid.uint32Value), score) }
        }
        guard let best else { return nil }
        return PrivateAPI.captureWindow(best.0)
    }

    /// Applies dim + blur filters to a wallpaper layer. Returns false when CAFilter is unavailable.
    private func configureFilters(_ layer: CALayer) -> Bool {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else {
            layer.filters = nil
            layer.shouldRasterize = false
            LogManager.shared.error("wallpaper failed: CAFilter unavailable")
            return false
        }
        let dim: CGFloat = appState.isBlurWallpaper ? 0.7 : 0.8
        let colorMatrix = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "colorMatrix")?.takeUnretainedValue() as? NSObject
        colorMatrix?.setValue(Self.colorMatrixValue(dim: dim), forKey: "inputColorMatrix")

        guard let colorMatrix else {
            layer.filters = nil
            layer.shouldRasterize = false
            LogManager.shared.error("wallpaper failed: colorMatrix filter unavailable")
            return false
        }
        if appState.isBlurWallpaper {
            let saturate = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "colorSaturate")?.takeUnretainedValue() as? NSObject
            saturate?.setValue(1.4, forKey: "inputAmount")
            let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
            blur?.setValue(true, forKey: "inputHardEdges")
            blur?.setValue(CGFloat(appState.wallpaperBlurRadius), forKey: "inputRadius")
            if let saturate, let blur {
                layer.filters = [blur, saturate, colorMatrix]
            } else {
                layer.filters = [colorMatrix]
            }
        } else {
            layer.filters = [colorMatrix]
        }
        layer.shouldRasterize = true
        layer.rasterizationScale = backingScale
        return true
    }

    /// Puts the captured wallpaper on `layer`. Asynchronous swaps (settings change) crossfade the new
    /// layer over the old one: opacity 0 → 1, 0.36 s ease-in-out.
    private func applyImage(blurFallback: CGImage?, cgImage: CGImage? = nil, to layer: CALayer, token: Int, animated: Bool) {
        let other = layer === wallpaperLayer ? standbyWallpaperLayer : wallpaperLayer
        let hadPrevious = other.contents != nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = blurFallback ?? cgImage
        layer.contentsScale = backingScale
        if animated && hadPrevious { wallpaperContainerLayer.addSublayer(layer) }    // new layer on top
        CATransaction.commit()
        layer.opacity = 1

        guard animated && hadPrevious else {
            other.contents = nil
            other.opacity = 0
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.36
        fade.timingFunction = DesignTokens.animationEaseInEaseOut
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, token == self.wallpaperRequestToken else { return }   // stale results are ignored
            other.contents = nil
            other.opacity = 0
        }
        layer.add(fade, forKey: "wallpaper.crossfade")
        CATransaction.commit()
    }

    /// CPU Gaussian blur used when the layer filters are unavailable (`CIGaussianBlur`).
    private func cpuBlurred(_ image: CGImage, radius: CGFloat) -> CGImage {
        let context = CIContext(options: [.cacheIntermediates: false])
        let input = CIImage(cgImage: image)
        let extent = input.extent
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        defer { context.clearCaches() }
        guard let output = filter.outputImage?.cropped(to: extent),
              let result = context.createCGImage(output, from: extent) else { return image }
        return result
    }

    deinit {
        if let defaultsObserver { NotificationChannel.center.removeObserver(defaultsObserver) }
    }
}

extension BackgroundViewController {
    /// `CAColorMatrix` is a C struct that Swift cannot import, so the 20-float matrix is wrapped
    /// in an `NSValue` by hand for `CAFilter.inputColorMatrix`.
    static func colorMatrixValue(dim: CGFloat) -> NSValue {
        let d = Float(dim)
        var matrix: [Float] = [
            d, 0, 0, 0, 0,
            0, d, 0, 0, 0,
            0, 0, d, 0, 0,
            0, 0, 0, 1, 0,
        ]
        return withUnsafeBytes(of: &matrix) { buffer in
            NSValue(bytes: buffer.baseAddress!, objCType: "{CAColorMatrix=ffffffffffffffffffff}")
        }
    }
}
