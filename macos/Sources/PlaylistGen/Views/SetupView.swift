import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let run = model.run {
                RunView(run: run)
            } else {
                SetupView()
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        // Once per launch: reopening the window (e.g. after closing it during a run) keeps the backend.
        .task { if model.environment == nil { await model.connect() } }
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    /// Remembered across launches and across visits to the run screen.
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        @Bindable var model = model
        trackArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !model.tracks.isEmpty { StatusBar() }
            }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    PlaylistLinkField()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.requestGenerate()
                    } label: {
                        // "film" sits on the text's centre line; "film.stack" rode high.
                        Label("Generate", systemImage: "film")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!model.canGenerate)
                    .help(model.generateBlocker ?? "Make one video from the included songs (⌘↩)")
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Video Settings", systemImage: "sidebar.trailing")
                    }
                    .help(showInspector ? "Hide video settings" : "Show video settings")
                }
            }
            .navigationTitle("Playlist Gen")
            .navigationSubtitle(subtitle)
            .alert(
                "“\((model.confirmReplacePath.map { ($0 as NSString).lastPathComponent }) ?? "")” already exists. Do you want to replace it?",
                isPresented: Binding(get: { model.confirmReplacePath != nil }, set: { if !$0 { model.confirmReplacePath = nil } })
            ) {
                Button("Replace", role: .destructive) {
                    model.confirmReplacePath = nil
                    model.generate()
                }
                Button("Cancel", role: .cancel) { model.confirmReplacePath = nil }
            } message: {
                Text("The existing video is overwritten when the new one is finished. To keep both, choose another name under Save To.")
            }
    }

    private var subtitle: String {
        guard !model.tracks.isEmpty else { return "Apple Music to video" }
        return "\(model.tracks.count) songs"
    }

    @ViewBuilder
    private var trackArea: some View {
        @Bindable var model = model
        if let error = model.environmentError {
            ContentUnavailableView {
                Label("Can’t Start the Python Backend", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await model.connect() } }
                    .buttonStyle(.glassProminent)
                SettingsLink { Text("Open Settings…") }
                    .buttonStyle(.glass)
            }
        } else if model.environment == nil {
            VStack(spacing: 10) {
                ProgressView()
                Text("Starting the Python Backend…").font(.headline)
                Text("The first launch can take a minute while uv sets up its environment.")
                    .foregroundStyle(.secondary)
            }
        } else if model.tracks.isEmpty {
            if model.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading Playlist…").font(.headline)
                    Text("Reading the tracklist from Apple Music. This can take a few seconds.")
                        .foregroundStyle(.secondary)
                }
            } else if case .failed(let message) = model.loadState {
                ContentUnavailableView {
                    Label("Couldn’t Load the Playlist", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    if AppModel.isAppleMusicLink(model.settings.playlistURL) {
                        Button("Try Again") { model.loadTracks() }
                            .buttonStyle(.glassProminent)
                    }
                    Button {
                        model.pasteLinkAndLoad()
                    } label: {
                        Label("Paste Link and Load", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.glass)
                }
            } else {
                EmptyPlaylistView()
            }
        } else {
            TrackTableView(rows: $model.tracks, focusedRow: $model.previewTrackID)
        }
    }
}

/// The playlist link, in the toolbar like Safari's address field.
private struct PlaylistLinkField: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            TextField("Apple Music playlist link", text: $model.settings.playlistURL)
                .textFieldStyle(.plain)
                .onSubmit { model.loadTracks() }
                .onChange(of: model.settings.playlistURL) { model.clearLoadError() }
                .disabled(model.isLoading)
                .accessibilityLabel("Playlist link")
            if model.isLoading {
                ProgressView().controlSize(.small)
                Button("Stop", systemImage: "xmark.circle.fill") { model.cancelLoad() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop loading")
            } else if !model.settings.playlistURL.isEmpty {
                Button(model.tracks.isEmpty ? "Load" : "Reload", systemImage: "arrow.clockwise") {
                    model.loadTracks()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.environment == nil)
                .help(model.tracks.isEmpty ? "Load the playlist (⌘L)" : "Reload the playlist (⌘L)")
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 320, idealWidth: 460, maxWidth: 560)
    }
}

/// First-run guidance: one obvious thing to do.
private struct EmptyPlaylistView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Start with a Playlist", systemImage: "music.note.list")
        } description: {
            VStack(spacing: 10) {
                Text("In Music, choose Share › Copy Link on any playlist, then load it here.")
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    step(1, "Load the playlist")
                    step(2, "Pick, reorder, or rename songs")
                    step(3, "Click Generate")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        } actions: {
            Button {
                model.pasteLinkAndLoad()
            } label: {
                Label("Paste Link and Load", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(model.environment == nil)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        GridRow {
            Text("\(n)")
                .font(.caption.bold().monospacedDigit())
                .frame(width: 18, height: 18)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
            Text(text)
                .accessibilityLabel("Step \(n): \(text)")
        }
    }
}

/// Selection summary and list tools under the table.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            Button("Include All") { model.setAllIncluded(true, undoManager: undoManager) }
                .disabled(model.includedCount == model.tracks.count)
                .help("Check every song (⌥⌘A)")
            Button("Exclude All") { model.setAllIncluded(false, undoManager: undoManager) }
                .disabled(model.includedCount == 0)
                .help("Uncheck every song (⌥⇧⌘A)")
            Toggle("Shuffle", isOn: $model.settings.shuffle)
                .toggleStyle(.checkbox)
                .help("Shuffle the selected songs when generating, instead of using the list order")

            Spacer()

            if let warning = warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: String {
        let n = model.includedCount
        let total = model.tracks.count
        let songs = n == total
            ? (n == 1 ? "1 song" : "\(n) songs")
            : "\(n) of \(total) songs"
        return "\(songs) · \(formatLongDuration(model.includedDuration))"
    }

    /// Reasons Generate is disabled that the user can fix from here.
    private var warning: String? {
        if case .failed(let message) = model.loadState { return message }
        if model.includedCount == 0 { return "Include at least one song to generate a video." }
        if model.settings.backgrounds.count > model.includedCount {
            return "More background images (\(model.settings.backgrounds.count)) than included songs."
        }
        return nil
    }
}

/// "1 hr, 58 min" / "48 min" style, like Music's status bar (no seconds
/// once there's a minute or more).
func formatLongDuration(_ seconds: Double) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .short
    let value: Double
    if seconds >= 60 {
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        value = (seconds / 60).rounded() * 60
    } else {
        formatter.allowedUnits = [.second]
        value = seconds.rounded()
    }
    return formatter.string(from: value) ?? formatDuration(seconds)
}

/// Finder-style estimate: "About 4 minutes left", "Less than a minute left".
func formatTimeLeft(_ seconds: Double) -> String {
    guard seconds >= 60 else { return "Less than a minute left" }
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
    let rounded = (seconds / 60).rounded() * 60
    return "About \(formatter.string(from: rounded) ?? formatDuration(seconds)) left"
}
