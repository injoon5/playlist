import Foundation

/// Everything the user configures, persisted as one JSON blob in UserDefaults.
/// Defaults match playlist_video/config.py.
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

    enum Aspect: String, CaseIterable, Identifiable {
        case wide = "16:9"
        case macBook = "16:10"
        var id: String { rawValue }
        var label: String { self == .wide ? "16:9" : "16:10" }
    }

    enum Size: String, CaseIterable, Identifiable {
        case hd = "1080p", qhd = "1440p", uhd = "4K"
        var id: String { rawValue }
        var width: Int { [.hd: 1920, .qhd: 2560, .uhd: 3840][self]! }
    }

    static func resolution(_ aspect: Aspect, _ size: Size) -> String {
        let w = size.width
        let h = aspect == .wide ? w * 9 / 16 : w * 10 / 16
        return "\(w)x\(h)"
    }

    var aspect: Aspect {
        get {
            let (w, h) = self.size
            return abs(Double(w) / Double(h) - 1.6) < 0.01 ? .macBook : .wide
        }
        set { resolution = Self.resolution(newValue, sizeTier) }
    }

    var sizeTier: Size {
        get { Size.allCases.min { abs($0.width - size.width) < abs($1.width - size.width) } ?? .hd }
        set { resolution = Self.resolution(aspect, newValue) }
    }

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

    /// First-launch settings: the defaults from the Python project's
    /// playlist_video/config.py (RESOLUTION 1920x1080, FPS 30, WORKERS 6,
    /// RENDER_WORKERS 4, GPU auto, SHUFFLE off, TRANSITION_DURATION 0.6,
    /// BACKGROUND_IMAGE bg1 + bg2). The output path is filled in by AppModel.
    static func firstLaunch(backgroundsDir: URL?) -> RunSettings {
        var settings = RunSettings()
        settings.renderWorkers = 4
        if let dir = backgroundsDir {
            settings.backgrounds = ["bg1.jpeg", "bg2.jpeg"]
                .map { dir.appending(path: $0).path }
                .filter { FileManager.default.fileExists(atPath: $0) }
        }
        return settings
    }
}

/// m:ss or h:mm:ss for UI labels.
func formatDuration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
