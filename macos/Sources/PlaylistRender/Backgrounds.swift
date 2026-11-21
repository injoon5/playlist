import CoreGraphics
import CoreImage
import CryptoKit
import Foundation

/// Port of playlist_video/backgrounds.py.
public enum Background {
    /// A still image: a user background or blurred artwork.
    case still(CGImage)
    /// The default generated diagonal gradient, panned slowly over time.
    case gradient(Gradient)

    public struct Gradient: Sendable {
        public var top: (r: Double, g: Double, b: Double)
        public var bottom: (r: Double, g: Double, b: Double)
        public var marginWidth: Int
        public var marginHeight: Int
    }

    /// Custom image → blurred artwork → generated gradient, like `prepare_background`.
    public static func prepare(
        width: Int, height: Int, backgroundPath: String?, artworkPath: String?, seedText: String
    ) -> Background {
        if let backgroundPath, let image = Imaging.loadImage(at: backgroundPath) {
            return .still(Imaging.cover(image, width: width, height: height))
        }
        if let artworkPath, let art = Imaging.loadImage(at: artworkPath) {
            return .still(blurredArtwork(art, width: width, height: height))
        }
        return .gradient(gradient(width: width, height: height, seedText: seedText))
    }

    /// Apple Music–style backdrop: the artwork under a heavy, saturated
    /// blur with a dark material tint so white text stays readable.
    static func blurredArtwork(_ art: CGImage, width: Int, height: Int) -> CGImage {
        let covered = Imaging.cover(art, width: width, height: height, overscan: 1.15)
        let blurred = Imaging.material(covered, sigma: Double(height) * 0.05, saturation: 1.8)
        let ctx = Imaging.makeContext(width: width, height: height)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.drawImage(blurred, in: rect)
        ctx.setFillColor(CGContext.rgba(0, 0, 0, 0.38 * 255))
        ctx.fill(rect)
        return ctx.makeImage()!
    }

    /// Deterministic per-track colours from md5(artist + title), as in Python.
    static func gradient(width: Int, height: Int, seedText: String) -> Gradient {
        let digest = Insecure.MD5.hash(data: Data(seedText.utf8))
        let seed = digest.reduce(0) { ($0 * 256 + Int($1)) % 360 }
        let hue = Double(seed) / 360
        let hue2 = (hue + 0.12).truncatingRemainder(dividingBy: 1)
        return Gradient(
            top: hsvToRGB(hue, 0.55, 0.26),
            bottom: hsvToRGB(hue2, 0.65, 0.15),
            marginWidth: Int(Double(width) * 0.15),
            marginHeight: Int(Double(height) * 0.15)
        )
    }

    /// Python's `colorsys.hsv_to_rgb`.
    static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        if s == 0 { return (v, v, v) }
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    /// Split `images` into contiguous blocks across `trackCount` tracks
    /// (`assign_track_backgrounds`): one entry per track, nil when no images.
    public static func assign<T>(_ images: [T], trackCount: Int) -> [T?] {
        guard !images.isEmpty, trackCount > 0 else { return Array(repeating: nil, count: trackCount) }
        return (0..<trackCount).map { images[$0 * images.count / trackCount] }
    }
}

extension Background.Gradient {
    /// The panned gradient for time `t`, generated on the GPU. The oversized
    /// texture in Python is a linear ramp, so a CILinearGradient offset by
    /// the pan gives the same pixels without allocating it.
    func image(width: Int, height: Int, t: Double, duration: Double) -> CIImage {
        let bigW = Double(width + 2 * marginWidth)
        let bigH = Double(height + 2 * marginHeight)
        let period = max(duration, 18)
        let phase = t / period * 2 * .pi
        let dx = Double(marginWidth) * (0.5 + 0.5 * sin(phase))
        let dy = Double(marginHeight) * (0.5 + 0.5 * cos(phase * 0.85))

        // blend(x, y) = (x / (bigW-1) + y / (bigH-1)) / 2 in y-down big-texture
        // pixels; convert the ramp's endpoints to Core Image's y-up space.
        let a = 1 / (2 * (bigW - 1)), b = 1 / (2 * (bigH - 1))
        let norm = a * a + b * b
        let start = CGPoint(x: -dx, y: -dy)
        let end = CGPoint(x: start.x + a / norm, y: start.y + b / norm)
        let h = Double(height)
        let srgb = Imaging.colorSpace
        return CIImage.empty().applyingFilter("CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: start.x, y: h - start.y),
            "inputPoint1": CIVector(x: end.x, y: h - end.y),
            "inputColor0": CIColor(red: top.r, green: top.g, blue: top.b, alpha: 1, colorSpace: srgb)!,
            "inputColor1": CIColor(red: bottom.r, green: bottom.g, blue: bottom.b, alpha: 1, colorSpace: srgb)!,
        ]).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
