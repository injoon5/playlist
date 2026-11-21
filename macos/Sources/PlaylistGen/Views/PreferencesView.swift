import PlaylistSource
import SwiftUI

/// Settings window (⌘,).
struct PreferencesView: View {
    var body: some View {
        TabView {
            Tab("Rendering", systemImage: "film") {
                RenderingSettings()
            }
            Tab("Tools", systemImage: "wrench.and.screwdriver") {
                ToolsSettings()
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
                Text("Reads the playlist page directly instead of opening it in a hidden web view first. Either way, the other reader is the fallback.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// yt-dlp, ffmpeg and deno: where they were found, overrides, and updating yt-dlp.
private struct ToolsSettings: View {
    @Environment(AppModel.self) private var model

    private var hasOverrides: Bool {
        Tool.allCases.contains { !(UserDefaults.standard.string(forKey: $0.overrideKey) ?? "").isEmpty }
    }

    var body: some View {
        Form {
            Section {
                ToolRow(tool: .ytDlp, subtitle: model.ytDlpVersion.map { "Version \($0)" } ?? "Finds and downloads each song")
                ToolRow(tool: .ffmpeg, subtitle: "Converts the downloaded audio")
                ToolRow(tool: .deno, subtitle: "Runs YouTube’s player scripts for yt-dlp", alternative: .node)
                if hasOverrides {
                    Button("Use Automatic Locations") {
                        for tool in Tool.allCases { UserDefaults.standard.removeObject(forKey: tool.overrideKey) }
                        recheck()
                    }
                }
            } footer: {
                Text("Install all three with Homebrew: \(ToolPaths.installCommand)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                HStack {
                    if model.isCheckingTools {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    } else if let problem = model.toolProblem {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            .accessibilityHidden(true)
                        Text(problem.localizedDescription).lineLimit(4)
                    } else if model.tools != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text("Ready to download")
                    }
                    Spacer()
                    Button("Check Again", action: recheck)
                        .disabled(model.isCheckingTools)
                }
                HStack {
                    switch model.ytDlpUpdate {
                    case .idle:
                        Text("YouTube changes often. If songs stop downloading, update yt-dlp.")
                            .foregroundStyle(.secondary)
                    case .running:
                        ProgressView().controlSize(.small)
                        Text("Updating yt-dlp…")
                    case .finished(let output):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text(output.isEmpty ? "yt-dlp is up to date." : output).lineLimit(3).textSelection(.enabled)
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(message).lineLimit(4).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Update yt-dlp") { Task { await model.updateYtDlp() } }
                        .disabled(model.toolSearch?.ytDlp == nil || model.ytDlpUpdate == .running || model.run?.isActive == true)
                        .help(updateHelp)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var updateHelp: String {
        guard let ytDlp = model.toolSearch?.ytDlp else { return "yt-dlp isn’t installed" }
        return "Runs “\(ToolUpdater.updateCommand(for: ytDlp).display)”"
    }

    private func recheck() {
        Task { await model.checkTools() }
    }
}

/// One tool: where it is (and how it was found), with a Choose… override.
private struct ToolRow: View {
    @Environment(AppModel.self) private var model
    let tool: Tool
    let subtitle: String
    /// Shown when `tool` is missing but this one can stand in (node for deno).
    var alternative: Tool?
    @AppStorage private var override: String

    init(tool: Tool, subtitle: String, alternative: Tool? = nil) {
        self.tool = tool
        self.subtitle = subtitle
        self.alternative = alternative
        _override = AppStorage(wrappedValue: "", tool.overrideKey)
    }

    private var located: LocatedTool? { model.toolSearch?.located[tool] }

    private var status: (path: String, detail: String?) {
        if let bad = model.toolSearch?.invalidOverrides[tool] {
            return (bad, "Not an executable")
        }
        if let located {
            return (located.path, located.source.rawValue)
        }
        if let alternative, let other = model.toolSearch?.located[alternative] {
            return ("Not found", "yt-dlp will use \(alternative.rawValue) at \(other.path)")
        }
        return ("Not found", nil)
    }

    var body: some View {
        LabeledContent {
            HStack {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(status.path)
                        .foregroundStyle(located == nil ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let detail = status.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Button("Choose…") {
                    Task {
                        if let path = await Panels.chooseExecutable(message: "Choose the \(tool.rawValue) executable.", current: located?.path) {
                            override = path
                            await model.checkTools()
                        }
                    }
                }
                .accessibilityLabel("Choose \(tool.rawValue)")
            }
        } label: {
            Text(tool.rawValue)
            Text(subtitle)
        }
    }
}
