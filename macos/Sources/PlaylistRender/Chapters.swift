import Foundation

/// Chapter list for a YouTube description, in the form YouTube turns into
/// chapters: one `<timestamp> <title>` per line, the first at `00:00`,
/// timestamps ascending. YouTube ignores the whole list unless there are at
/// least three chapters and each lasts at least 10 seconds.
public struct YouTubeChapters: Sendable, Equatable, Codable {
    public struct Chapter: Sendable, Equatable, Codable {
        public var title: String
        public var artist: String
        /// Seconds from the start of the video.
        public var start: Double

        public init(title: String, artist: String, start: Double) {
            self.title = title
            self.artist = artist
            self.start = start
        }
    }

    public static let minimumCount = 3
    public static let minimumLength = 10.0
    /// YouTube's limit for a whole description.
    public static let descriptionLimit = 5000

    public var chapters: [Chapter]
    public var totalDuration: Double

    public init(_ chapters: [Chapter], totalDuration: Double) {
        self.chapters = chapters
        self.totalDuration = totalDuration
    }

    /// The text to paste, one chapter per line.
    public var text: String {
        let long = totalDuration >= 3600
        return chapters.map { "\(Self.timestamp($0.start, long: long)) \(Self.label($0))" }
            .joined(separator: "\n") + "\n"
    }

    /// `00:00` (or `00:00:00` when the video runs an hour or more, so every
    /// line has the same form). Seconds are truncated, like YouTube does.
    public static func timestamp(_ seconds: Double, long: Bool) -> String {
        let s = max(0, Int(seconds))
        if long {
            return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// `Title - Artist`, made safe for a description: YouTube rejects
    /// descriptions containing `<` or `>`, and a line break would split the
    /// chapter.
    static func label(_ chapter: Chapter) -> String {
        let artist = chapter.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = artist.isEmpty ? chapter.title : "\(chapter.title) - \(artist)"
        let flattened = raw.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "<", with: "‹")
            .replacingOccurrences(of: ">", with: "›")
        return flattened.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Why YouTube won't show these as chapters (empty when it will).
    public var problems: [String] {
        var problems: [String] = []
        if chapters.count < Self.minimumCount {
            problems.append("YouTube needs at least \(Self.minimumCount) chapters; this video has \(chapters.count).")
        }
        let ends = chapters.dropFirst().map(\.start) + [totalDuration]
        let short = zip(chapters, ends).filter { $1 - $0.start < Self.minimumLength }.map(\.0.title)
        if let first = short.first {
            let more = short.count > 1 ? " and \(short.count - 1) more" : ""
            problems.append("“\(first)”\(more) is shorter than 10 seconds; YouTube needs every chapter to be at least 10 seconds.")
        }
        if text.count > Self.descriptionLimit {
            problems.append("The list is \(text.count) characters; a YouTube description holds at most \(Self.descriptionLimit).")
        }
        return problems
    }
}
