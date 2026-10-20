import Foundation
import AppKit

/// App icon loading, rasterisation and caching.
///
/// * 128 pt icons rasterised into a 256×256 Display-P3 bitmap.
/// * In-memory `NSCache`, in-flight de-duplication, 4-wide operation queue.
/// * Persistent PNG cache under `~/Library/Caches/Gridura/AppIcons`.
final class AppIconRepository {
    static let shared = AppIconRepository()

    let iconPointSize: CGFloat = 128
    let iconScale: CGFloat = 2
    let maxCachedIconPixelLength = 256

    private let cache = NSCache<NSString, NSImage>()
    private let operationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.griduraapp.icon-repository"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 4
        return q
    }()
    private let stateQueue = DispatchQueue(label: "com.griduraapp.icon-repository.state")
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]
    private var unsupportedKeys: Set<String> = []

    private let diskCacheURL: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = base.appendingPathComponent("Gridura/AppIcons", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private init() {
        cache.countLimit = 512
    }

    private func diskKey(for path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Data(path.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url.standardizedFileURL.path as NSString)
    }

    /// Requests an icon, calling `completion` on the main queue.
    func icon(for url: URL, completion: @escaping (NSImage?) -> Void) {
        let key = url.standardizedFileURL.path
        if let image = cache.object(forKey: key as NSString) {
            completion(image)
            return
        }
        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.inFlight[key] != nil {
                self.inFlight[key]?.append(completion)
                return
            }
            self.inFlight[key] = [completion]
            self.operationQueue.addOperation { [weak self] in
                guard let self else { return }
                let image = self.loadImage(for: url, key: key)
                if let image { self.cache.setObject(image, forKey: key as NSString) }
                self.stateQueue.async {
                    let callbacks = self.inFlight.removeValue(forKey: key) ?? []
                    DispatchQueue.main.async { callbacks.forEach { $0(image) } }
                }
            }
        }
    }

    private func loadImage(for url: URL, key: String) -> NSImage? {
        if let disk = loadFromDisk(key: key) { return disk }
        let workspaceIcon = NSWorkspace.shared.icon(forFile: url.path)
        if isUnsupported(workspaceIcon) {
            stateQueue.async { self.unsupportedKeys.insert(key) }
        }
        let rasterised = rasterise(workspaceIcon)
        // Icons on external volumes are not written to the disk cache.
        if !url.path.hasPrefix("/Volumes/"), let rasterised {
            writeToDisk(rasterised, key: key)
        }
        return rasterised ?? workspaceIcon
    }

    private func isUnsupported(_ image: NSImage) -> Bool {
        let descriptions = [image.debugDescription] + image.representations.map(\.debugDescription)
        return descriptions.contains {
            $0.contains("ISGenericDocumentIcon") || $0.contains("com.apple.icon-decoration.system.unsupported")
        }
    }

    private func rasterise(_ image: NSImage) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: maxCachedIconPixelLength,
                                         pixelsHigh: maxCachedIconPixelLength,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: iconPointSize, height: iconPointSize)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            ctx.imageInterpolation = .high
            NSGraphicsContext.current = ctx
            NSColor.clear.set()
            NSRect(x: 0, y: 0, width: iconPointSize, height: iconPointSize).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: iconPointSize, height: iconPointSize),
                       from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: iconPointSize, height: iconPointSize))
        out.addRepresentation(rep)
        return out
    }

    private func loadFromDisk(key: String) -> NSImage? {
        let url = diskCacheURL.appendingPathComponent("\(diskKey(for: key)).png")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private func writeToDisk(_ image: NSImage, key: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = diskCacheURL.appendingPathComponent("\(diskKey(for: key)).png")
        try? png.write(to: url, options: .atomic)
    }
}
