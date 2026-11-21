import CoreGraphics
import CoreText
import Foundation

/// Port of playlist_video/text.py: easing, shadowed text textures, marquee
/// timing and edge-fade profiles.

/// Cubic in/out, the one easing curve used for every motion in the video.
public func easeInOutCubic(_ u: Double) -> Double {
    let u = min(max(u, 0), 1)
    return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
}

/// Margin baked around every text texture for the shadow blur to fall off in.
public let textTexturePad = 10

public let marqueeHoldSeconds = 2.6
public let marqueeFadeInSeconds = 0.35
public let marqueeFadeOutSeconds = 0.5
public let marqueeSpeed = 28.0  // px/s

public struct MarqueeState: Equatable, Sendable {
    /// Scroll offset in pixels (fractional; 0 at rest).
    public var offset: Double
    /// Seconds since the slide started, nil while holding at rest.
    public var slideElapsed: Double?
    /// Seconds until the slide arrives back at rest, nil while holding.
    public var slideRemaining: Double?
}

/// Holds at 0 for `hold` seconds, then slides one full tile width at constant
/// speed, arriving back at 0 exactly as the tile wraps (seamless loop).
public func marqueeState(
    t: Double, tileWidth: Double, speed: Double = marqueeSpeed, hold: Double = marqueeHoldSeconds
) -> MarqueeState {
    let slideTime = max(tileWidth / speed, 0.6)
    let period = hold + slideTime
    let phase = t.truncatingRemainder(dividingBy: period)
    if phase < hold {
        return MarqueeState(offset: 0, slideElapsed: nil, slideRemaining: nil)
    }
    let elapsed = phase - hold
    return MarqueeState(offset: speed * elapsed, slideElapsed: elapsed, slideRemaining: slideTime - elapsed)
}

/// How strongly the left-edge fade applies (0 at rest, eased up to 1 while
/// sliding, eased back to 0 just before the text comes to rest).
public func marqueeLeftFadeAmount(_ state: MarqueeState) -> Double {
    guard let elapsed = state.slideElapsed, let remaining = state.slideRemaining else { return 0 }
    let fadeIn = easeInOutCubic(min(elapsed / marqueeFadeInSeconds, 1))
    let fadeOut = easeInOutCubic(min(remaining / marqueeFadeOutSeconds, 1))
    return min(fadeIn, fadeOut)
}

/// Per-pixel alpha (0…1) across a marquee window: the right edge always
/// fades out, the left edge fades by `leftAmount` (0 = no left fade).
public func marqueeFadeProfile(width: Int, fadeWidth: Int, leftAmount: Double) -> [Double] {
    let fade = Double(max(1, min(fadeWidth, width / 2)))
    return (0..<width).map { x in
        let left = 1 - leftAmount + leftAmount * min(max(Double(x) / fade, 0), 1)
        let right = min(max(Double(width - 1 - x) / fade, 0), 1)
        return min(left, right)
    }
}

/// One line of text rendered at its natural width onto a transparent canvas,
/// plus a matching soft drop-shadow layer (PIL `render_text_texture`). The
/// two are kept apart so the glyphs can be composited with vibrancy
/// (plus-lighter) while the shadow still darkens normally.
public struct TextTexture {
    public let glyphs: CGImage
    public let shadow: CGImage?
    /// Width of the inked glyphs (excludes padding).
    public let inkWidth: Double
    /// Distance from the texture's top edge down to the text baseline.
    public let baselineFromTop: Double
    /// Composite the glyphs with plus-lighter, like Apple's vibrant labels.
    public let vibrant: Bool

    /// The texture as PIL sized it: ink width plus padding on both sides.
    public var paddedWidth: Int { glyphs.width }
    public var height: Int { glyphs.height }

    public init(text: String, font: CTFont, color: CGColor, vibrant: Bool = false, shadow: Bool = true) {
        let line = makeLine(text, font: font, color: color)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let pad = Double(textTexturePad)
        let inkWidth = max(1, ink.width.isFinite ? ink.width : 1)
        let inkHeight = max(1, ink.height.isFinite ? ink.height : 1)
        let width = Int(ceil(inkWidth)) + textTexturePad * 2
        let height = Int(ceil(inkHeight)) + textTexturePad * 2
        // Ink top-left sits at (pad, pad), as in the Python texture.
        let origin = CGPoint(x: pad - ink.minX, y: pad + ink.maxY)

        if shadow {
            let shadowCtx = Imaging.makeContext(width: width, height: height)
            let shadowLine = makeLine(text, font: font, color: CGContext.rgba(0, 0, 0, vibrant ? 120 : 160))
            shadowCtx.textPosition = CGPoint(x: origin.x, y: origin.y + 2)
            CTLineDraw(shadowLine, shadowCtx)
            self.shadow = Imaging.blur(shadowCtx.makeImage()!, sigma: 3, clampEdges: false)
        } else {
            self.shadow = nil
        }
        let ctx = Imaging.makeContext(width: width, height: height)
        ctx.textPosition = origin
        CTLineDraw(line, ctx)

        self.glyphs = ctx.makeImage()!
        self.inkWidth = inkWidth
        self.baselineFromTop = origin.y
        self.vibrant = vibrant
    }

    /// Draw shadow then glyphs with the texture's top-left at `point`.
    func draw(in ctx: CGContext, at point: CGPoint) {
        if let shadow { ctx.drawImage(shadow, at: point) }
        ctx.saveGState()
        if vibrant { ctx.setBlendMode(.plusLighter) }
        ctx.drawImage(glyphs, at: point)
        ctx.restoreGState()
    }
}

func makeLine(_ text: String, font: CTFont, color: CGColor, tabularDigits: Bool = false) -> CTLine {
    var attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    if tabularDigits {
        // Fixed-advance figures so the time labels don't jitter as digits change.
        let features: [[CFString: Any]] = [[
            kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
            kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
        ]]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFeatureSettingsAttribute: features] as CFDictionary
        )
        attributes[NSAttributedString.Key(kCTFontAttributeName as String)] =
            CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, descriptor)
    }
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
}

/// Height PIL reports for `textbbox((0, 0), "Ag")[3]`: ascender line down to
/// the lowest inked pixel of "Ag".
func referenceLineHeight(_ font: CTFont) -> Int {
    let line = makeLine("Ag", font: font, color: CGContext.rgba(255, 255, 255, 255))
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    return Int((CTFontGetAscent(font) - ink.minY).rounded())
}
