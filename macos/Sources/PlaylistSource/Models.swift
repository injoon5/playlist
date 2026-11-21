import Foundation

/// One song from an Apple Music playlist (port of `playlist_video.models.Track`'s
/// input fields). The field names match the JSON the app has always persisted
/// in its session file, so existing sessions still load.
public struct PlaylistTrack: Codable, Hashable, Sendable {
    /// 1-based position in the run; nil until a run assigns it.
    public var index: Int?
    public var title: String
    public var artist: String
    public var album: String
    public var artworkUrl: String?
    public var durationMs: Int?

    public init(
        index: Int? = nil, title: String, artist: String, album: String,
        artworkUrl: String? = nil, durationMs: Int? = nil
    ) {
        self.index = index
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkUrl = artworkUrl
        self.durationMs = durationMs
    }

    /// "Artist - Title", like `track_label()` in Python.
    public var label: String { "\(artist) - \(title)" }
}

/// What the download phase produced for one track.
public struct DownloadedTrack: Equatable, Sendable {
    public var index: Int
    public var audioPath: String?
    public var artworkPath: String?
    public var matchedVideoTitle: String?
    /// Duration of the downloaded audio (ffprobe), when known.
    public var durationSec: Double?

    public init(
        index: Int, audioPath: String? = nil, artworkPath: String? = nil,
        matchedVideoTitle: String? = nil, durationSec: Double? = nil
    ) {
        self.index = index
        self.audioPath = audioPath
        self.artworkPath = artworkPath
        self.matchedVideoTitle = matchedVideoTitle
        self.durationSec = durationSec
    }
}

/// Per-track state during downloading (same strings the Python pipeline used).
public enum DownloadStatus: String, Sendable {
    case pending, downloading, ok, skipped, failed, cancelled
}

/// Port of `playlist_video.models.ProgressEvent` for the download phase.
public struct ProgressEvent: Equatable, Sendable {
    public var phase: String
    public var completed: Int
    public var total: Int
    public var message: String
    public var trackIndex: Int?
    public var trackLabel: String?
    public var trackStatus: String?
    public var slotId: Int?
    public var fraction: Double?

    public init(
        phase: String, completed: Int, total: Int, message: String,
        trackIndex: Int? = nil, trackLabel: String? = nil, trackStatus: String? = nil,
        slotId: Int? = nil, fraction: Double? = nil
    ) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.message = message
        self.trackIndex = trackIndex
        self.trackLabel = trackLabel
        self.trackStatus = trackStatus
        self.slotId = slotId
        self.fraction = fraction
    }
}

/// Everything the downloader reports while it works.
public enum DownloadEvent: Sendable {
    case progress(ProgressEvent)
    /// A diagnostic line (what the Python downloader printed when not quiet).
    case log(String)
}
