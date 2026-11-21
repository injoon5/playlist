import SwiftUI

/// Settings window (⌘,).
struct PreferencesView: View {
    var body: some View {
        TabView {
            Tab("Rendering", systemImage: "film") {
                RenderingSettings()
            }
            Tab("Backend", systemImage: "terminal") {
                BackendSettings()
            }
        }
        .frame(width: 520)
        .scenePadding(.minimum, edges: .bottom)
    }
}

private struct RenderingSettings: View {
    @Environment(AppModel.self) private var model
    private let cores = ProcessInfo.processInfo.activeProcessorCount

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Video format", selection: $model.settings.gpu) {
                    Text("HEVC").tag("auto")
                    Text("H.264").tag("h264")
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Frames are composited on the GPU with Metal and encoded by the Media Engine. HEVC makes smaller files; H.264 plays on older devices.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Stepper(value: $model.settings.workers, in: 1...16) {
                    LabeledContent("Simultaneous downloads", value: "\(model.settings.workers)")
                }
                Picker("Simultaneous renders", selection: $model.settings.renderWorkers) {
                    Text("Automatic").tag(Int?.none)
                    ForEach(1...max(1, cores), id: \.self) { n in
                        Text("\(n)").tag(Int?.some(n))
                    }
                }
            }
            Section {
                Toggle("Try the fast playlist reader first", isOn: $model.settings.fastScrape)
            } footer: {
                Text("Reads the playlist page directly and falls back to headless Chromium if that fails.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Where the Python project (scraping + yt-dlp) and uv live.
private struct BackendSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ToolEnvironment.rootOverrideKey) private var rootOverride = ""
    @AppStorage(ToolEnvironment.uvOverrideKey) private var uvOverride = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Project folder") {
                    HStack {
                        PathControlView(path: rootOverride.isEmpty ? (model.environment?.projectRoot.path ?? "") : rootOverride)
                        Button("Choose…") {
                            Task {
                                if let path = await Panels.chooseFolder(
                                    message: "Choose the playlist-gen repository folder.",
                                    current: model.environment?.projectRoot.path
                                ) {
                                    rootOverride = path
                                    reconnect()
                                }
                            }
                        }
                    }
                }
                LabeledContent("uv") {
                    HStack {
                        Text(uvOverride.isEmpty ? (model.environment?.uv.path ?? "Not found") : uvOverride)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            Task {
                                if let path = await Panels.chooseExecutable(message: "Choose the uv executable.") {
                                    uvOverride = path
                                    reconnect()
                                }
                            }
                        }
                    }
                }
                if !rootOverride.isEmpty || !uvOverride.isEmpty {
                    Button("Use Automatic Locations") {
                        rootOverride = ""
                        uvOverride = ""
                        reconnect()
                    }
                }
            } footer: {
                Text("Python reads the playlist and downloads audio with yt-dlp. This app draws and encodes the video.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    if model.isConnecting {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                    } else if let error = model.environmentError {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text(error).lineLimit(3)
                    } else if model.environment != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Connected")
                    }
                    Spacer()
                    Button("Reconnect", action: reconnect)
                        .disabled(model.isConnecting)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func reconnect() {
        Task { await model.connect() }
    }
}
