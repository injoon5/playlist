import Foundation

/// Wire types for `python -m playlist_video.bridge` (see playlist_video/bridge.py).
/// Python scrapes and downloads; everything after that happens in Swift.
/// Keys are snake_case on the wire and camelCase here.

struct BridgeTrack: Codable, Hashable, Sendable {
    var index: Int?
    var title: String
    var artist: String
    var album: String
    var artworkUrl: String?
    var durationMs: Int?

    var label: String { "\(artist) - \(title)" }
}

struct BridgeDefaults: Decodable, Sendable {
    var projectRoot: String
    var playlistUrl: String
    var output: String
    var resolution: String
    var fps: Int
    var workers: Int
    var renderWorkers: Int?
    var gpu: String
    var shuffle: Bool
    var transitionDuration: Double
    var backgroundImages: [String]
    var backgroundsDir: String
}

struct ProgressEvent: Decodable, Equatable, Sendable {
    var phase: String
    var completed: Int
    var total: Int
    var message: String
    var trackIndex: Int?
    var trackLabel: String?
    var trackStatus: String?
    var slotId: Int?
    var fraction: Double?
}

/// What the Python download phase produced for one track.
struct DownloadedTrack: Decodable, Equatable, Sendable {
    var index: Int
    var audioPath: String?
    var artworkPath: String?
    var matchedVideoTitle: String?
}

/// First stdin line for `bridge download`.
struct DownloadRequest: Encodable, Sendable {
    var tracks: [BridgeTrack]
    var workers: Int
    var workdir: String

    /// One JSON line, ready to write to the bridge's stdin.
    func encodedLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

enum BridgeMessage: Sendable {
    case defaults(BridgeDefaults)
    case tracks([BridgeTrack])
    case progress(ProgressEvent)
    case downloaded([DownloadedTrack])
    case cancelled
    case error(message: String, detail: String?)
    case unknown(type: String)

    private struct Envelope: Decodable { var type: String }
    private struct TrackList: Decodable { var tracks: [BridgeTrack] }
    private struct DownloadedList: Decodable { var tracks: [DownloadedTrack] }
    private struct ErrorBody: Decodable {
        var message: String
        var detail: String?
    }

    /// Parses one stdout line. Returns nil for anything that isn't a bridge message.
    static func parse(_ line: String) -> BridgeMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let type = try decoder.decode(Envelope.self, from: data).type
            switch type {
            case "defaults": return .defaults(try decoder.decode(BridgeDefaults.self, from: data))
            case "tracks": return .tracks(try decoder.decode(TrackList.self, from: data).tracks)
            case "progress": return .progress(try decoder.decode(ProgressEvent.self, from: data))
            case "downloaded": return .downloaded(try decoder.decode(DownloadedList.self, from: data).tracks)
            case "cancelled": return .cancelled
            case "error":
                let body = try decoder.decode(ErrorBody.self, from: data)
                return .error(message: body.message, detail: body.detail)
            default: return .unknown(type: type)
            }
        } catch {
            return nil
        }
    }
}
