import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Bitmap, resize and blur helpers shared by the renderer.
///
/// Every context is 8-bit BGRA (premultiplied, little-endian), sRGB, with a
/// y-down coordinate system so positions read the same as the Python/PIL code
/// they were ported from. Rows are packed (bytesPerRow == width * 4) so a
/// frame's buffer can be piped to ffmpeg as `-pix_fmt bgra` without copying.
public enum Imaging {
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    static let ciContext = CIContext(options: [
        .workingColorSpace: Imaging.colorSpace,  // blur in gamma space, like PIL
        .outputColorSpace: Imaging.colorSpace,
        .cacheIntermediates: false,
    ])

    /// A transparent y-down context. Draw images with `drawImage` (not `draw`).
    public static func makeContext(width: Int, height: Int) -> CGContext {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            fatalError("Couldn't allocate a \(width)x\(height) bitmap")
        }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.interpolationQuality = .high
        return ctx
    }

    public static func loadImage(at path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        // Like PIL's Image.open: EXIF orientation is not applied.
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Lanczos resize to an exact pixel size (PIL `Image.resize(..., LANCZOS)`).
    public static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage {
        guard
            let format = vImage_CGImageFormat(
                bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo)
            ),
            var src = try? vImage_Buffer(cgImage: image, format: format),
            var dst = try? vImage_Buffer(width: width, height: height, bitsPerPixel: 32)
        else {
            return redraw(image, width: width, height: height)
        }
        defer {
            src.free()
            dst.free()
        }
        let error = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError, let out = try? dst.createCGImage(format: format) else {
            return redraw(image, width: width, height: height)
        }
        return out
    }

    private static func redraw(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let ctx = makeContext(width: width, height: height)
        ctx.drawImage(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Gaussian blur with standard deviation `sigma` (PIL `GaussianBlur(radius=sigma)`).
    /// `clampEdges` repeats edge pixels outward instead of fading to transparent.
    public static func blur(_ image: CGImage, sigma: Double, clampEdges: Bool) -> CGImage {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let source = clampEdges ? input.clampedToExtent() : input
        let blurred = source.applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        return ciContext.createCGImage(
            blurred, from: extent, format: .BGRA8, colorSpace: colorSpace
        ) ?? image
    }

    /// Apple's continuous-curvature ("squircle") rounded rectangle.
    public static func continuousRoundedRect(_ rect: CGRect, radius: Double) -> CGPath {
        RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
    }

    /// A dark system-material look: heavy blur, boosted saturation (vibrancy),
    /// edges clamped so the blur doesn't fade in from transparent.
    public static func material(_ image: CGImage, sigma: Double, saturation: Double) -> CGImage {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
            .cropped(to: extent)
        return ciContext.createCGImage(output, from: extent, format: .BGRA8, colorSpace: colorSpace) ?? image
    }

    /// Crop a centered `width`x`height` window out of `image` (integer offsets, like PIL).
    static func centerCrop(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let left = (image.width - width) / 2
        let top = (image.height - height) / 2
        return image.cropping(to: CGRect(x: left, y: top, width: width, height: height)) ?? image
    }

    /// Scale to cover `width`x`height` (times `overscan`), then center-crop.
    static func cover(_ image: CGImage, width: Int, height: Int, overscan: Double = 1) -> CGImage {
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height)) * overscan
        let scaled = resize(
            image,
            width: Int(Double(image.width) * scale),
            height: Int(Double(image.height) * scale)
        )
        return centerCrop(scaled, width: width, height: height)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

extension CGContext {
    /// Draw an image upright in a y-down context.
    func drawImage(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }

    func drawImage(_ image: CGImage, at point: CGPoint) {
        drawImage(image, in: CGRect(x: point.x, y: point.y, width: CGFloat(image.width), height: CGFloat(image.height)))
    }

    static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(colorSpace: Imaging.colorSpace, components: [r / 255, g / 255, b / 255, a / 255])!
    }
}
