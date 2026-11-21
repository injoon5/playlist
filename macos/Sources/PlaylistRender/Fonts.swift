import AppKit
import CoreText

/// Fonts for the video text: SF Pro (the system UI font, with automatic
/// optical sizing). Core Text's system cascade fills in other scripts per
/// glyph — Hangul comes from Apple SD Gothic Neo at the matching weight — so
/// Korean titles render properly without bundling a font.
public enum VideoFonts {
    /// A font whose em size is `size` pixels.
    public static func font(size: Int, weight: NSFont.Weight) -> CTFont {
        NSFont.systemFont(ofSize: CGFloat(size), weight: weight) as CTFont
    }
}
