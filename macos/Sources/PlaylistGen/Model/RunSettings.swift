import Foundation

/// Everything the user configures, persisted as one JSON blob in UserDefaults.
struct RunSettings: Codable, Equatable {
    var playlistURL = ""
    var output = ""
    var resolution = "1920x1080"
    var fps = 30
    var workers = 6
    /// nil = automatic (one per core, capped at the track count).
    var renderWorkers: Int?
    var gpu = "auto"
    var shuffle = false
    var transitionDuration = 0.6
    /// Selected background images, in block order (empty = blurred artwork).
    var backgrounds: [String] = []
    /// Images the user added from outside assets/backgrounds.
    var extraBackgrounds: [String] = []
    var fastScrape = false

    static let resolutions: [(label: String, value: String)] = [
        ("1080p", "1920x1080"),
        ("1440p", "2560x1440"),
        ("4K", "3840x2160"),
    ]

    var size: (width: Int, height: Int) {
        let parts = resolution.lowercased().split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (1920, 1080)
    }

    private static let storageKey = "runSettings.v1"

    static func load(from defaults: UserDefaults = .standard) -> RunSettings? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(RunSettings.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Seed from the Python project's playlist_video/config.py on first launch.
    mutating func apply(_ d: BridgeDefaults) {
        playlistURL = d.playlistUrl
        output = d.output
        resolution = d.resolution
        fps = d.fps
        workers = d.workers
        renderWorkers = d.renderWorkers
        gpu = d.gpu
        shuffle = d.shuffle
        transitionDuration = d.transitionDuration
        backgrounds = d.backgroundImages
    }
}

/// m:ss or h:mm:ss for UI labels.
func formatDuration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
