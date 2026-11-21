import CoreText
import Foundation

/// Port of `compute_layout` in playlist_video/frames.py: every position on
/// the "Now Playing" screen. Artwork, title, meta, progress bar and time labels form
/// one block, vertically centered on the canvas.
public struct Layout: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let artSize: Int
    public let blockX: Int
    public let artY: Int
    public let titleY: Int
    public let metaY: Int
    public let barX: Int
    public let barWidth: Int
    public let barY: Int
    public let barHeight: Int
    public let labelY: Int
    /// Continuous (squircle) corner radius for the artwork, scaled with its size.
    public var artCornerRadius: Double { Double(artSize) * 0.03 }
    public let titleFont: CTFont
    public let metaFont: CTFont
    public let timeFont: CTFont

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let h = Double(height)

        artSize = Int(h * 0.42)
        // Title and meta share a size; the title stands out by weight and opacity.
        let textSize = Int(h * 0.032)
        let timeSize = Int(h * 0.022)
        titleFont = VideoFonts.font(size: textSize, weight: .semibold)
        metaFont = VideoFonts.font(size: textSize, weight: .regular)
        timeFont = VideoFonts.font(size: timeSize, weight: .medium)

        let titleH = referenceLineHeight(titleFont)
        let metaH = referenceLineHeight(metaFont)
        let timeH = referenceLineHeight(timeFont)

        let gapArtTitle = Int(h * 0.04)
        let gapTitleMeta = Int(h * 0.004)
        let gapMetaBar = Int(h * 0.035)
        barHeight = 6
        let gapBarLabel = 14

        let blockHeight = artSize + gapArtTitle + titleH + gapTitleMeta + metaH
            + gapMetaBar + barHeight + gapBarLabel + timeH
        artY = Int(Double(height - blockHeight) / 2)
        blockX = Int(Double(width) * 0.5 - Double(artSize) / 2)
        titleY = artY + artSize + gapArtTitle
        metaY = titleY + titleH + gapTitleMeta
        barX = blockX
        barWidth = artSize
        barY = metaY + metaH + gapMetaBar
        labelY = barY + barHeight + gapBarLabel
    }

    /// Text is positioned by baseline so every track's title sits at the same
    /// height. (Python aligned each string's own ink top, so a title without
    /// capitals or ascenders sat lower than one with them.)
    func baseline(forTopOf top: Int, font: CTFont) -> Double {
        Double(top) + Double(CTFontGetCapHeight(font))
    }
}
