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
        .task { await model.connect() }
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true

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
                    .help(model.generateBlocker ?? "Render the selected songs into one video (⌘↩)")
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
                Text("A video with the same name is already in that folder. Replacing it overwrites it when the new video is finished. You can pick another name under Save To.")
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
            ProgressView("Starting…")
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
                    Button("Try Again") { model.loadTracks() }
                        .buttonStyle(.glassProminent)
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
                .disabled(model.isLoading)
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
                    step(3, "Click Generate Video")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        } actions: {
            Button {
                if let link = NSPasteboard.general.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), link.contains("music.apple.com") {
                    model.settings.playlistURL = link
                }
                model.loadTracks()
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
            Text(text)
        }
    }
}

/// Selection summary and list tools under the table.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            Button("Select All") { model.setAllIncluded(true) }
                .disabled(model.includedCount == model.tracks.count)
            Button("Deselect All") { model.setAllIncluded(false) }
                .disabled(model.includedCount == 0)
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
        let songs = n == 1 ? "1 song" : "\(n) songs"
        return "\(songs) selected · \(formatLongDuration(model.includedDuration))"
    }

    /// Reasons Generate is disabled that the user can fix from here.
    private var warning: String? {
        if case .failed(let message) = model.loadState { return message }
        if model.includedCount == 0 { return "Select at least one song to generate a video." }
        if model.settings.backgrounds.count > model.includedCount {
            return "More backgrounds (\(model.settings.backgrounds.count)) than selected songs."
        }
        return nil
    }
}

/// "1 hr 58 min" style, like Music's status bar.
func formatLongDuration(_ seconds: Double) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
    formatter.unitsStyle = .short
    return formatter.string(from: seconds) ?? formatDuration(seconds)
}
