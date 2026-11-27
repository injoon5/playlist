import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation
import Metal

/// Everything needed to draw one track's clip.
public struct TrackRenderInput: Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var artworkPath: String?
    public var backgroundPath: String?
    /// Clip length in seconds (the audio's duration).
    public var duration: Double
    public var width: Int
    public var height: Int
    public var transitionDuration: Double

    public init(
        title: String, artist: String, album: String, artworkPath: String?, backgroundPath: String?,
        duration: Double, width: Int, height: Int, transitionDuration: Double
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkPath = artworkPath
        self.backgroundPath = backgroundPath
        self.duration = duration
        self.width = width
        self.height = height
        self.transitionDuration = transitionDuration
    }

    public var metaText: String { album.isEmpty ? artist : "\(artist) — \(album)" }
}

/// Port of `build_track_renderer` (playlist_video/frames.py) plus the
/// dip-through-black transition (transitions.py).
///
/// Static artwork, text and backgrounds are prepared once with Core
/// Graphics; every frame is then composited by Core Image on the GPU (Metal)
/// straight into an IOSurface-backed pixel buffer that VideoToolbox encodes,
/// so frames never round-trip through the CPU.
///
/// Not thread-safe; give each render job its own renderer.
public final class TrackRenderer {
    public let input: TrackRenderInput
    public let layout: Layout
    private let background: Background
    private var staticLayers = StaticLayers(base: nil, foreground: nil, texts: [])
    private let marquees: [Marquee]
    private var marqueeImages: [(glyphs: CIImage, shadow: CIImage?)] = []
    /// Per-frame overlays are cached while their inputs don't change: the
    /// time labels change once a second, the edge-fade mask only while the
    /// left fade eases in or out. Reusing the same CIImage also lets Core
    /// Image reuse its GPU texture instead of uploading a new one per frame.
    private var labelCache: (left: String, right: String, image: CIImage)?
    private var maskCache: [Int: (leftAmount: Double, image: CIImage)] = [:]
    private lazy var progressGeometry = ProgressGeometry(layout: layout, height: height)

    private struct StaticLayers {
        /// Still path: background + foreground + static text, flattened.
        var base: CIImage?
        /// Gradient path: the foreground (artwork + shadow) over the moving gradient…
        var foreground: CIImage?
        /// …and static text, composited per frame so vibrancy sees the gradient.
        var texts: [TextLayer]
    }

    private struct TextLayer {
        var shadow: CIImage?
        var glyphs: CIImage
        var vibrant: Bool
    }

    private struct Marquee {
        let texture: TextTexture
        /// Visible window (y-down), centred on the artwork column.
        let window: CGRect
        /// Where the texture's top edge sits (y-down).
        let textureTop: Double
        /// One repeat: the padded texture plus a breathing gap.
        let tileWidth: Double
        let fadeWidth: Int
    }

    public var width: Int { input.width }
    public var height: Int { input.height }
    private var frameRect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    public init(_ input: TrackRenderInput) {
        self.input = input
        let w = input.width, h = input.height
        layout = Layout(width: w, height: h)
        background = Background.prepare(
            width: w, height: h, backgroundPath: input.backgroundPath,
            artworkPath: input.artworkPath, seedText: input.artist + input.title
        )
        let fg = Imaging.makeContext(width: w, height: h)
        let fgBounds = Self.drawArtwork(into: fg, layout: layout, artworkPath: input.artworkPath)

        let viewport = layout.artSize
        let fadeWidth = max(20, Int(Double(viewport) * 0.07))
        let gap = max(40, Int(Double(viewport) * 0.18))
        let pad = Double(textTexturePad)
        var marquees: [Marquee] = []

        // Title: solid white. Meta: a vibrant secondary label (plus-lighter).
        let texts: [(String, CTFont, CGColor, Bool, Int)] = [
            (input.title, layout.titleFont, CGContext.rgba(255, 255, 255, 255), false, layout.titleY),
            (input.metaText, layout.metaFont, CGContext.rgba(255, 255, 255, 120), true, layout.metaY),
        ]
        var staticTexts: [(texture: TextTexture, origin: CGPoint)] = []
        for (text, font, color, vibrant, top) in texts {
            let texture = TextTexture(text: text, font: font, color: color, vibrant: vibrant)
            let textureTop = layout.baseline(forTopOf: top, font: font) - texture.baselineFromTop
            if texture.inkWidth > Double(viewport) {
                // Window = artwork column plus the shadow pad on both sides.
                let window = CGRect(
                    x: Double(layout.blockX) - pad, y: textureTop,
                    width: Double(viewport) + 2 * pad, height: Double(texture.height)
                )
                marquees.append(Marquee(
                    texture: texture, window: window, textureTop: textureTop,
                    tileWidth: Double(texture.paddedWidth + gap), fadeWidth: fadeWidth
                ))
            } else {
                staticTexts.append((texture, CGPoint(x: Double(layout.blockX) - pad, y: textureTop)))
            }
        }
        self.marquees = marquees

        let fgImage = fg.makeImage()!
        let frameH = Double(h)
        func place(_ image: CGImage, topLeft: CGPoint) -> CIImage {
            CIImage(cgImage: image).transformed(by: CGAffineTransform(
                translationX: topLeft.x, y: frameH - topLeft.y - Double(image.height)
            ))
        }
        switch background {
        case .still(let image):
            // Everything static is flattened once on the CPU (including the
            // vibrant meta line, which needs the background under it).
            let base = Imaging.makeContext(width: w, height: h)
            base.drawImage(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            base.drawImage(fgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            for (texture, origin) in staticTexts {
                texture.draw(in: base, at: origin)
            }
            staticLayers = StaticLayers(base: CIImage(cgImage: base.makeImage()!), foreground: nil, texts: [])
        case .gradient:
            let rect = fgBounds.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            let foreground = fgImage.cropping(to: rect).map { place($0, topLeft: rect.origin) }
            let texts = staticTexts.map { texture, origin in
                TextLayer(
                    shadow: texture.shadow.map { place($0, topLeft: origin) },
                    glyphs: place(texture.glyphs, topLeft: origin),
                    vibrant: texture.vibrant
                )
            }
            staticLayers = StaticLayers(base: nil, foreground: foreground, texts: texts)
        }
        marqueeImages = marquees.map { m in
            (CIImage(cgImage: m.texture.glyphs), m.texture.shadow.map { CIImage(cgImage: $0) })
        }
    }

    /// Artwork with its soft cast shadow and rounded corners. Returns the
    /// area touched.
    private static func drawArtwork(into ctx: CGContext, layout: Layout, artworkPath: String?) -> CGRect {
        let art = layout.artSize
        let x = layout.blockX, y = layout.artY

        let margin = max(60, art / 5)
        let blurRadius = max(30, art / 12)
        let shadowSize = art + margin * 2
        let shadowCtx = Imaging.makeContext(width: shadowSize, height: shadowSize)
        let drop = Int(Double(margin) * 0.25)
        let radius = layout.artCornerRadius
        shadowCtx.addPath(Imaging.continuousRoundedRect(
            CGRect(x: margin, y: margin + drop, width: art, height: art), radius: radius
        ))
        shadowCtx.setFillColor(CGContext.rgba(0, 0, 0, 130))
        shadowCtx.fillPath()
        let shadow = Imaging.blur(shadowCtx.makeImage()!, sigma: Double(blurRadius), clampEdges: false)
        let shadowRect = CGRect(x: x - margin, y: y - margin, width: shadowSize, height: shadowSize)
        ctx.drawImage(shadow, in: shadowRect)

        let artRect = CGRect(x: x, y: y, width: art, height: art)
        ctx.saveGState()
        ctx.addPath(Imaging.continuousRoundedRect(artRect, radius: radius))
        ctx.clip()
        if let path = artworkPath, let image = Imaging.loadImage(at: path) {
            ctx.drawImage(Imaging.resize(image, width: art, height: art), in: artRect)
        } else {
            ctx.setFillColor(CGContext.rgba(40, 40, 45, 255))
            ctx.fill(artRect)
        }
        ctx.restoreGState()
        return shadowRect.union(artRect)
    }

    // MARK: - Frames

    /// Frames in a clip of `duration` seconds (Python's banker's rounding).
    public static func frameCount(duration: Double, fps: Int) -> Int {
        max(1, Int((duration * Double(fps)).rounded(.toNearestOrEven)))
    }

    /// Render the frame at time `t` into `pixelBuffer` on the GPU.
    public func render(at t: Double, into pixelBuffer: CVPixelBuffer) {
        GPU.context.render(frame(at: t), to: pixelBuffer, bounds: frameRect, colorSpace: Imaging.colorSpace)
    }

    /// The frame at time `t` as an image (previews, parity checks).
    public func image(at t: Double) -> CGImage {
        GPU.context.createCGImage(frame(at: t), from: frameRect, format: .BGRA8, colorSpace: Imaging.colorSpace)!
    }

    /// The whole frame as a Core Image graph (bottom-left origin).
    public func frame(at t: Double) -> CIImage {
        var image: CIImage
        switch background {
        case .still:
            image = staticLayers.base!
        case .gradient(let gradient):
            image = gradient.image(width: width, height: height, t: t, duration: input.duration)
            if let foreground = staticLayers.foreground {
                image = foreground.composited(over: image)
            }
            for text in staticLayers.texts {
                image = composite(text.shadow, text.glyphs, vibrant: text.vibrant, over: image)
            }
        }

        for (i, marquee) in marquees.enumerated() {
            image = drawMarquee(marquee, index: i, at: t, over: image)
        }
        image = drawProgress(at: t, over: image)
        image = applyTransition(at: t, to: image)
        return image.composited(over: CIImage(color: .black)).cropped(to: frameRect)
    }

    private func composite(_ shadow: CIImage?, _ glyphs: CIImage, vibrant: Bool, over image: CIImage) -> CIImage {
        var out = image
        if let shadow { out = shadow.composited(over: out) }
        if vibrant {
            // Plus-lighter: how Apple's vibrant labels blend with what's behind them.
            return glyphs.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: out])
        }
        return glyphs.composited(over: out)
    }

    /// y-down rect → Core Image rect.
    private func ciRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: Double(height) - r.maxY, width: r.width, height: r.height)
    }

    /// Continuous wraparound scroll through the (text + gap) tile at
    /// sub-pixel offsets, so the motion is smooth. Python stepped by whole
    /// pixels, which at ~0.93 px/frame made the scroll visibly stutter.
    private func drawMarquee(_ marquee: Marquee, index: Int, at t: Double, over image: CIImage) -> CIImage {
        let images = marqueeImages[index]
        let state = marqueeState(t: t, tileWidth: marquee.tileWidth)
        let offset = state.offset.truncatingRemainder(dividingBy: marquee.tileWidth)
        let window = ciRect(marquee.window)
        let y = Double(height) - marquee.textureTop - Double(marquee.texture.height)

        var glyphs = CIImage.empty()
        var shadow = CIImage.empty()
        var x = marquee.window.minX - offset
        while x < marquee.window.maxX {
            let move = CGAffineTransform(translationX: x, y: y)
            glyphs = images.glyphs.transformed(by: move).composited(over: glyphs)
            if let s = images.shadow { shadow = s.transformed(by: move).composited(over: shadow) }
            x += marquee.tileWidth
        }

        // Edge fades: a 1-pixel-tall alpha profile stretched over the window.
        let leftAmount = marqueeLeftFadeAmount(state)
        let mask: CIImage
        if let cached = maskCache[index], cached.leftAmount == leftAmount {
            mask = cached.image
        } else {
            let profile = marqueeFadeProfile(
                width: Int(marquee.window.width.rounded()), fadeWidth: marquee.fadeWidth, leftAmount: leftAmount
            )
            mask = CIImage(cgImage: Self.maskImage(profile))
                .clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: 1, y: window.height)
                    .concatenating(CGAffineTransform(translationX: window.minX, y: window.minY)))
                .cropped(to: window)
            maskCache[index] = (leftAmount, mask)
        }
        func masked(_ layer: CIImage) -> CIImage {
            layer.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask,
            ]).cropped(to: window)
        }
        return composite(
            images.shadow == nil ? nil : masked(shadow), masked(glyphs),
            vibrant: marquee.texture.vibrant, over: image
        )
    }

    private static func maskImage(_ profile: [Double]) -> CGImage {
        let bytes = profile.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: bytes.count, height: 1, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: bytes.count, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    /// Progress bar plus elapsed / remaining labels: a small CPU overlay
    /// (two layers: vibrant track + labels, solid fill) placed on the GPU frame.
    /// Everything about the progress overlay that doesn't depend on time.
    private struct ProgressGeometry {
        let barW: CGFloat, barH: CGFloat, radius: CGFloat
        let pad: CGFloat = 2
        let baselineY: CGFloat
        let regionW: Int, regionH: Int
        let track: CGRect
        let trackPath: CGPath
        /// Labels layer and fill layer placements (Core Image, y-up).
        let labelPlace: CGAffineTransform
        let fillPlace: CGAffineTransform
        let labelFont: CTFont
        let labelColor = CGContext.rgba(255, 255, 255, 150)
        let trackColor = CGContext.rgba(255, 255, 255, 55)
        let fillColor = CGContext.rgba(255, 255, 255, 235)

        init(layout: Layout, height: Int) {
            barW = CGFloat(layout.barWidth)
            barH = CGFloat(layout.barHeight)
            radius = barH / 2
            baselineY = CGFloat(layout.labelY - layout.barY) + CTFontGetAscent(layout.timeFont) + pad
            regionH = Int(ceil(baselineY + CTFontGetDescent(layout.timeFont) + 4))
            regionW = Int(barW + pad * 2)
            track = CGRect(x: pad, y: pad, width: barW, height: barH)
            trackPath = CGPath(roundedRect: track, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let origin = CGPoint(x: CGFloat(layout.barX) - pad, y: CGFloat(layout.barY) - pad)
            labelPlace = CGAffineTransform(translationX: origin.x, y: CGFloat(height) - origin.y - CGFloat(regionH))
            fillPlace = CGAffineTransform(translationX: origin.x, y: CGFloat(height) - origin.y - (barH + pad * 2))
            labelFont = tabularDigitsFont(layout.timeFont)
        }
    }

    /// Progress bar plus elapsed / remaining labels: a small CPU overlay
    /// (two layers: vibrant track + labels, solid fill) placed on the GPU frame.
    private func drawProgress(at t: Double, over image: CIImage) -> CIImage {
        let g = progressGeometry
        let duration = input.duration

        // Track + labels: redrawn only when a label changes (once a second).
        let leftText = Self.clock(t), rightText = "-" + Self.clock(max(duration - t, 0))
        let labels: CIImage
        if let cached = labelCache, cached.left == leftText, cached.right == rightText {
            labels = cached.image
        } else {
            let ctx = Imaging.makeContext(width: g.regionW, height: g.regionH)
            ctx.addPath(g.trackPath)
            ctx.setFillColor(g.trackColor)
            ctx.fillPath()
            let left = makeLine(leftText, font: g.labelFont, color: g.labelColor)
            let right = makeLine(rightText, font: g.labelFont, color: g.labelColor)
            let rightWidth = CTLineGetTypographicBounds(right, nil, nil, nil)
            ctx.textPosition = CGPoint(x: g.pad, y: g.baselineY)
            CTLineDraw(left, ctx)
            ctx.textPosition = CGPoint(x: g.pad + g.barW - rightWidth, y: g.baselineY)
            CTLineDraw(right, ctx)
            labels = CIImage(cgImage: ctx.makeImage()!).transformed(by: g.labelPlace)
            labelCache = (leftText, rightText, labels)
        }
        var out = labels.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])

        let progress = duration <= 0 ? 0 : min(max(t / duration, 0), 1)
        let fillW = g.barW * progress
        if fillW > 0 {
            // Pill-shaped fill, clipped to the track so a sliver still looks right.
            // It moves by a fraction of a pixel every frame, so it's drawn per frame
            // (a few thousand pixels) to keep its anti-aliased edge exact.
            let fillCtx = Imaging.makeContext(width: g.regionW, height: Int(g.barH + g.pad * 2))
            fillCtx.addPath(g.trackPath)
            fillCtx.clip()
            let fill = CGRect(x: g.pad, y: g.pad, width: max(fillW, g.barH), height: g.barH)
                .offsetBy(dx: min(0, fillW - g.barH), dy: 0)
            fillCtx.addPath(CGPath(roundedRect: fill, cornerWidth: g.radius, cornerHeight: g.radius, transform: nil))
            fillCtx.setFillColor(g.fillColor)
            fillCtx.fillPath()
            out = CIImage(cgImage: fillCtx.makeImage()!).transformed(by: g.fillPlace).composited(over: out)
        }
        return out
    }

    /// `m:ss`, truncating like the Python labels.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", Int(s / 60), Int(s.truncatingRemainder(dividingBy: 60)))
    }

    /// Length of the dip through black at each end of the clip, nil if none.
    static func fadeDuration(of input: TrackRenderInput) -> Double? {
        guard input.transitionDuration > 0, input.duration > 0 else { return nil }
        return min(input.transitionDuration, max(0.05, input.duration / 2 - 0.05))
    }

    /// When the fade-in is over and the picture is steady (nil: from the start).
    static func firstSteadyTime(of input: TrackRenderInput) -> Double? {
        fadeDuration(of: input)
    }

    /// Keynote-style dip through black at the clip edges: ease toward black
    /// while very slightly zooming.
    private func applyTransition(at t: Double, to image: CIImage) -> CIImage {
        let duration = input.duration
        guard let fade = Self.fadeDuration(of: input) else { return image }
        let u: Double
        if t < fade {
            u = easeInOutCubic(t / fade)
        } else if t > duration - fade {
            u = easeInOutCubic((duration - t) / fade)
        } else {
            return image
        }
        if u >= 0.999 { return image }

        let scale = 1 + (1 - u) * 0.035
        var out = image.cropped(to: frameRect)
        if scale > 1.0005 {
            let cx = Double(width) / 2, cy = Double(height) / 2
            out = out.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: cx, y: cy)))
        }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1 - u)).cropped(to: frameRect)
        return black.composited(over: out.composited(over: CIImage(color: .black)).cropped(to: frameRect))
    }
}

/// The shared Metal-backed Core Image context used for every frame.
public enum GPU {
    public static let device = MTLCreateSystemDefaultDevice()

    public static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            // Composite in gamma-encoded sRGB like Core Graphics / PIL, at half-float precision.
            .workingColorSpace: Imaging.colorSpace,
            .workingFormat: CIFormat.RGBAh,
            .outputColorSpace: Imaging.colorSpace,
            .cacheIntermediates: true,
            .name: "PlaylistRender",
        ]
        if let device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()
}
