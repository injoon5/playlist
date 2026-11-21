import Foundation

/// yt-dlp command lines and output parsing (port of the pure parts of
/// `playlist_video/downloader.py`).
public enum YTDLP {
    /// YouTube's bot check ("Sign in to confirm you're not a bot") hits some
    /// clients more than others; each download tries these in order.
    public static let clientFallbacks = ["android", "ios", "tv_embedded", "web"]
    /// Errors that mean "this client was blocked", for the failure hint.
    public static let retryablePatterns = ["sign in to confirm", "not a bot", "requested format is not available"]
    /// How far a hit's duration may drift from Apple Music's before it's
    /// treated as the wrong song.
    public static let durationTolerance = 0.20
    public static let searchCandidates = 5

    static let thumbMarker = "YTDLP_THUMB::"
    static let titleMarker = "YTDLP_TITLE::"
    static let pathMarker = "YTDLP_PATH::"
    static let progressMarker = "YTDLP_PROGRESS::"

    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var duration: Double?
        public var title: String

        public init(id: String, duration: Double?, title: String) {
            self.id = id
            self.duration = duration
            self.title = title
        }

        /// No flat-search results: let yt-dlp search and download in one go.
        public static let searchFallback = Candidate(id: "__search__", duration: nil, title: "")
        public var isSearchFallback: Bool { id == Self.searchFallback.id }
    }

    // MARK: - Command lines

    /// Where deno / node are, so yt-dlp needn't find them on PATH.
    public struct JSRuntimes: Equatable, Sendable {
        public var deno: String?
        public var node: String?

        public init(deno: String? = nil, node: String? = nil) {
            self.deno = deno
            self.node = node
        }

        public init(_ tools: ToolPaths) {
            self.init(deno: tools[.deno]?.path, node: tools[.node]?.path)
        }
    }

    /// `--js-runtimes deno --js-runtimes node`, as in Python, with each
    /// runtime's location appended (`deno:/path`) when it's known.
    static func jsRuntimeArguments(_ runtimes: JSRuntimes) -> [String] {
        ["--js-runtimes", runtimes.deno.map { "deno:\($0)" } ?? "deno",
         "--js-runtimes", runtimes.node.map { "node:\($0)" } ?? "node"]
    }

    public static func searchQuery(artist: String, title: String) -> String {
        "\(artist) - \(title) audio"
    }

    /// Flat search: one `id<TAB>duration<TAB>title` line per result.
    public static func searchArguments(query: String, runtimes: JSRuntimes = JSRuntimes()) -> [String] {
        ["ytsearch\(searchCandidates):\(query)", "--flat-playlist", "--print", "%(id)s\t%(duration)s\t%(title)s", "--no-warnings"]
            + jsRuntimeArguments(runtimes)
    }

    /// Best audio, extracted without re-encoding, via one player client.
    /// `target` is a watch URL or `ytsearch1:<query>`.
    public static func downloadArguments(
        target: String, client: String, outputTemplate: String,
        ffmpegLocation: String? = nil, runtimes: JSRuntimes = JSRuntimes()
    ) -> [String] {
        var args = [
            target,
            "-f", "bestaudio/best",
            "--extract-audio", "--audio-format", "best", "--audio-quality", "0",
            "--no-playlist",
            "--no-simulate",
        ]
        args += jsRuntimeArguments(runtimes)
        args += [
            "--extractor-args", "youtube:player_client=\(client)",
            "-o", outputTemplate,
            "--print", "video:\(thumbMarker)%(thumbnail)s",
            "--print", "video:\(titleMarker)%(title)s",
            "--print", "after_move:\(pathMarker)%(filepath)s",
            "--no-warnings",
            "--newline",
            // --print implies --quiet, which hides progress; ask for it back
            // in a form that's easy to parse.
            "--progress",
            "--progress-template",
            "download:\(progressMarker)%(progress.downloaded_bytes)s/%(progress.total_bytes)s/%(progress.total_bytes_estimate)s",
        ]
        if let ffmpegLocation { args += ["--ffmpeg-location", ffmpegLocation] }
        return args
    }

    public static func watchURL(_ id: String) -> String { "https://www.youtube.com/watch?v=\(id)" }

    // MARK: - Output parsing

    /// Parses flat-search output. Lines that aren't `id<TAB>…` results (e.g.
    /// an `ERROR:` line, since stderr shares the pipe) are skipped.
    public static func parseSearchOutput(_ lines: [String]) -> [Candidate] {
        lines.compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let id = parts.first, !id.isEmpty,
                  id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            let rawDuration = parts[1]
            let duration = rawDuration.uppercased() == "NA" ? nil : Double(rawDuration)
            return Candidate(id: id, duration: duration, title: parts.count >= 3 ? parts[2] : "")
        }
    }

    /// Candidates within the duration tolerance first (closest first), then
    /// the rest in search order. Without an expected duration, search order.
    public static func rank(_ candidates: [Candidate], expectedMs: Int?) -> [Candidate] {
        guard let expectedMs, expectedMs > 0 else { return candidates }
        let expected = Double(expectedMs) / 1000
        func within(_ c: Candidate) -> Bool {
            guard let d = c.duration else { return false }
            return abs(d - expected) / expected <= durationTolerance
        }
        let good = candidates.enumerated()
            .filter { within($0.element) }
            .sorted { a, b in
                let da = abs((a.element.duration ?? 0) - expected)
                let db = abs((b.element.duration ?? 0) - expected)
                return da == db ? a.offset < b.offset : da < db
            }
            .map(\.element)
        guard !good.isEmpty else { return candidates }
        return good + candidates.filter { !within($0) }
    }

    /// True when both durations are known and differ by more than the tolerance.
    public static func durationMismatch(expectedMs: Int?, actualSec: Double?) -> Bool {
        guard let expectedMs, let actualSec, expectedMs > 0, actualSec > 0 else { return false }
        let expected = Double(expectedMs) / 1000
        return abs(actualSec - expected) / expected > durationTolerance
    }

    /// `003_Artist_Title`, with anything but word characters, `-`, `.` and
    /// space replaced by `_`, at most 120 characters (like `_safe_name`).
    public static func safeName(index: Int, artist: String, title: String) -> String {
        let raw = String(format: "%03d", index) + "_\(artist)_\(title)"
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let props = scalar.properties
            let isWord = props.isAlphabetic || props.numericType != nil || scalar == "_"
                || props.generalCategory == .nonspacingMark || props.generalCategory == .spacingMark
            let keep = isWord || scalar == "-" || scalar == "." || scalar == " "
            scalars.append(keep ? scalar : "_")
            if scalars.count == 120 { break }
        }
        return String(scalars)
    }

    /// 0…1 from yt-dlp's default progress line (`[download]  45.2% of …`).
    public static func parsePercent(_ line: String) -> Double? {
        guard line.contains("[download]"), line.contains("%"),
              let match = line.firstMatch(of: /(\d+(?:\.\d+)?)\s*%/),
              let value = Double(match.1) else { return nil }
        return min(1, max(0, value / 100))
    }

    /// 0…1 from our progress template (`YTDLP_PROGRESS::done/total/estimate`).
    public static func parseProgressTemplate(_ line: String) -> Double? {
        guard let range = line.range(of: progressMarker) else { return nil }
        let fields = line[range.upperBound...].split(separator: "/", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard fields.count == 3, let done = fields[0] else { return nil }
        guard let total = fields[1] ?? fields[2], total > 0 else { return nil }
        return min(1, max(0, done / total))
    }

    public enum OutputLine: Equatable {
        case thumbnail(String)
        case title(String)
        case path(String)
        case progress(Double)
        /// A progress line without a usable fraction (unknown size).
        case progressUnknown
        case other(String)
    }

    /// One line of download output. `NA` values count as missing.
    public static func classify(_ line: String) -> OutputLine {
        func value(after marker: String) -> String? {
            let v = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return v.isEmpty || v.uppercased() == "NA" ? nil : v
        }
        if line.hasPrefix(thumbMarker) { return value(after: thumbMarker).map(OutputLine.thumbnail) ?? .other(line) }
        if line.hasPrefix(titleMarker) { return value(after: titleMarker).map(OutputLine.title) ?? .other(line) }
        if line.hasPrefix(pathMarker) { return value(after: pathMarker).map(OutputLine.path) ?? .other(line) }
        if line.contains(progressMarker) {
            return parseProgressTemplate(line).map(OutputLine.progress) ?? .progressUnknown
        }
        if let pct = parsePercent(line) { return .progress(pct) }
        return .other(line)
    }

    /// The last line of real output (not our markers), for error messages.
    public static func lastError(in lines: [String]) -> String {
        let errors = lines.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("YTDLP_") && !$0.contains(progressMarker)
        }
        // Prefer an explicit "ERROR:" line over trailing chatter.
        return errors.last(where: { $0.hasPrefix("ERROR:") }) ?? errors.last ?? "unknown yt-dlp failure"
    }

    /// "(all player-client fallbacks failed)" when the last error looks like a bot check.
    public static func failureHint(_ error: String?) -> String {
        guard let error else { return "" }
        let lower = error.lowercased()
        return retryablePatterns.contains(where: lower.contains) ? " (all player-client fallbacks failed)" : ""
    }
}
