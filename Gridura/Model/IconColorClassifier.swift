import CoreGraphics
import Foundation

/// Icon colour ranking for "Reorganize › Icon Color": a 32×32 hue histogram.
/// Ranks: 0 red, 1 orange, 2 yellow, 3 green, 4 blue, 5 purple, 6 black, 7 gray, 8 white.
enum IconColorClassifier {
    static func rank(of image: CGImage) -> Double? {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        var hueWeights = [Double](repeating: 0, count: 12)
        var grayWeights = [Double](repeating: 0, count: 5)
        var grayValues = [Double](repeating: 0, count: 5)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[index + 3]) / 255
            guard a >= 0.2 else { continue }
            let r = min(Double(pixels[index]) / 255 / a, 1)
            let g = min(Double(pixels[index + 1]) / 255 / a, 1)
            let b = min(Double(pixels[index + 2]) / 255 / a, 1)
            let maxV = max(r, g, b), minV = min(r, g, b), delta = maxV - minV
            if maxV == 0 || delta / maxV < 0.12 {                       // achromatic
                let bucket = min(Int(maxV * 5), 4)
                grayWeights[bucket] += a
                grayValues[bucket] += a * maxV
            } else {
                var hue: Double
                if maxV == r { hue = fmod((g - b) / delta, 6) }
                else if maxV == g { hue = (b - r) / delta + 2 }
                else { hue = (r - g) / delta + 4 }
                func frac(_ x: Double) -> Double { x - floor(x) }
                hue = frac(frac(hue / 6 + 1) + 1.0 / 24) * 12           // 12 bins of 30°, bin 0 centred on red
                hueWeights[min(Int(hue), 11)] += a
            }
        }

        func argmax(_ values: [Double]) -> Int {
            var best = 0
            for (i, v) in values.enumerated() where v > values[best] { best = i }
            return best
        }
        let hueIndex = argmax(hueWeights), grayIndex = argmax(grayWeights)
        guard max(hueWeights[hueIndex], grayWeights[grayIndex]) > 0 else { return nil }
        if hueWeights[hueIndex] < grayWeights[grayIndex] {
            let value = grayValues[grayIndex] / grayWeights[grayIndex]
            return value < 0.25 ? 6 : (value < 0.8 ? 7 : 8)
        }
        switch hueIndex {
        case 0, 11: return 0
        case 1: return 1
        case 2: return 2
        case 3, 4, 5: return 3
        case 6, 7, 8: return 4
        default: return 5
        }
    }
}
