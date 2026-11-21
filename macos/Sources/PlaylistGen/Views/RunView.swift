import AppKit
import SwiftUI

/// Progress for a run: a compact status header, the song list with inline
/// progress (like Music's downloads or a Finder copy), and the log behind
/// "Show Details".
struct RunView: View {
    @Environment(AppModel.self) private var model
    let run: RunModel
    @State private var showDetails = false
    @State private var showChapters = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            RunHeader(run: run)
            Divider()
            SongProgressList(run: run)
            Divider()
            details
        }
        .toolbar {
            if run.isActive {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .cancel) {
                        run.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(run.state == .cancelling)
                    .help("Stop and delete the files made so far (⌘.)")
                }
            } else {
                if let output = run.output {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: URL(fileURLWithPath: output.videoPath)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .help("Share the video with AirDrop, Messages, Mail, and more")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showChapters.toggle()
                        } label: {
                            Label("Chapters", systemImage: "list.bullet.rectangle")
                        }
                        .help("YouTube chapters for the description")
                        .popover(isPresented: $showChapters, arrowEdge: .bottom) {
                            ChaptersPopover(output: output)
                        }
                    }
                }
                ToolbarItem(placement: .navigation) {
                    Button {
                        model.closeRun()
                    } label: {
                        Label("Back to Playlist", systemImage: "chevron.backward")
                    }
                    .help("Return to the song list (⌘[)")
                }
            }
        }
        .navigationTitle(URL(fileURLWithPath: run.config.output).lastPathComponent)
        .navigationSubtitle("\(run.config.tracks.count) songs · \(run.config.width)×\(run.config.height)")
        // A failure's full story is in the log; don't make people hunt for it.
        .onChange(of: run.state) { _, state in
            if case .failed = state { showDetails = true }
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { showDetails.toggle() }
                } label: {
                    Label(showDetails ? "Hide Details" : "Show Details", systemImage: "chevron.right")
                        .labelStyle(DisclosureLabelStyle(expanded: showDetails))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Details")
                .accessibilityValue(showDetails ? "Expanded" : "Collapsed")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if showDetails {
                LogTextView(lines: run.log)
                    .frame(height: 170)
                    .background(.background.secondary)
            }
        }
    }
}

/// Chevron that rotates like a disclosure triangle.
private struct DisclosureLabelStyle: LabelStyle {
    var expanded: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
            configuration.title
        }
        .foregroundStyle(.secondary)
    }
}

private struct RunHeader: View {
    @Environment(AppModel.self) private var model
    let run: RunModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusIcon
                .font(.system(size: 30))
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(run.headline)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if run.isActive {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(timing(now: context.date))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                if run.isActive {
                    ProgressView(value: run.progress.value)
                        .progressViewStyle(.linear)
                }
                HStack(alignment: .center) {
                    Text(run.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    if run.isActive {
                        StepIndicator(phase: run.phase)
                    } else if let output = run.output {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output.videoPath)])
                        }
                        .help("Show the video in Finder (⌥⌘R)")
                        Button("Save a Copy…") { Task { await Panels.saveCopy(of: output) } }
                            .help("Save another copy of the video and its chapters (⇧⌘S)")
                        Button("Play") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: output.videoPath))
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button(run.state == .cancelled ? "Start Again" : "Try Again") { model.retryRun() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.environment == nil)
                            .help("Generate the same video again")
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch run.state {
        case .running, .cancelling:
            Image(systemName: run.phase == "download" ? "arrow.down.circle" : run.phase == "concat" ? "square.stack.3d.down.right" : "film")
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
        case .finished where run.leftOutCount > 0:
            Image(systemName: "checkmark.circle.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
                .symbolRenderingMode(.hierarchical)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .symbolRenderingMode(.multicolor)
        case .cancelled:
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func timing(now: Date) -> String {
        if run.state == .cancelling { return "" }
        let elapsed = now.timeIntervalSince(run.startedAt)
        let p = run.progress.value
        guard p > 0.03, elapsed > 10 else { return "Estimating time left…" }
        return formatTimeLeft(elapsed * (1 - p) / p)
    }
}

/// Download › Render › Finish, with the current step emphasised.
private struct StepIndicator: View {
    let phase: String
    private let steps = [("download", "Download"), ("render", "Render"), ("concat", "Finish")]

    var body: some View {
        let current = steps.firstIndex { $0.0 == phase } ?? 0
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if i > 0 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 4) {
                    Image(systemName: i < current ? "checkmark.circle.fill" : i == current ? "circle.dotted.circle" : "circle")
                        .foregroundStyle(i < current ? AnyShapeStyle(.green) : i == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .symbolEffect(.pulse, isActive: i == current)
                    Text(step.1)
                        .fontWeight(i == current ? .semibold : .regular)
                        .foregroundStyle(i == current ? .primary : .secondary)
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(current + 1) of 3: \(steps[current].1)")
    }
}

/// Every song with artwork and its own status / progress.
private struct SongProgressList: View {
    let run: RunModel

    var body: some View {
        let fractions = Dictionary(
            run.slots.values.compactMap { slot in slot.trackIndex.map { ($0, slot.fraction) } },
            uniquingKeysWith: max
        )
        List(run.rows) { row in
            SongProgressRow(
                row: row, track: run.track(index: row.id), fraction: fractions[row.id]
            )
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .environment(\.defaultMinListRowHeight, 48)
    }
}

private struct SongProgressRow: View {
    let row: RunModel.Row
    let track: BridgeTrack?
    let fraction: Double?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(row.id)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            ArtworkThumbnail(urlString: track?.artworkUrl)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1)
                Text(row.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 16)
            status
                .frame(width: 190, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.id). \(row.title), \(row.artist)")
        .accessibilityValue(accessibilityStatus)
    }

    private var accessibilityStatus: String {
        let text = Self.describe(row).0
        guard let fraction, row.status == "downloading" || row.status == "rendering" else { return text }
        return "\(text), \(Int((fraction * 100).rounded())) percent"
    }

    @ViewBuilder
    private var status: some View {
        let (text, symbol, color) = Self.describe(row)
        if let fraction, row.status == "downloading" || row.status == "rendering" {
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 110)
                    .controlSize(.small)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 42, alignment: .trailing)
            }
            .help(text)
        } else {
            Label(text, systemImage: symbol)
                .foregroundStyle(color)
                .labelStyle(.titleAndIcon)
        }
    }

    /// Human wording + symbol + colour for a (phase, status) pair.
    static func describe(_ row: RunModel.Row) -> (String, String, Color) {
        switch (row.phase, row.status) {
        case ("download", "pending"): ("Waiting", "clock", .secondary)
        case ("download", "downloading"): ("Downloading", "arrow.down.circle", .accentColor)
        case ("download", "ok"): ("Downloaded", "arrow.down.circle.fill", .secondary)
        case ("render", "pending"): ("Ready to Render", "clock", .secondary)
        case ("render", "rendering"): ("Rendering", "film", .accentColor)
        case ("render", "ok"): ("Done", "checkmark.circle.fill", .green)
        case (_, "skipped"): ("Not Found on YouTube", "exclamationmark.circle", .orange)
        case (_, "failed"): ("Failed", "xmark.octagon.fill", .red)
        case (_, "cancelled"): ("Stopped", "stop.circle", .secondary)
        default: (row.status.capitalized, "circle", .secondary)
        }
    }
}

/// Album artwork from Apple Music (cached on disk), with a placeholder.
struct ArtworkThumbnail: View {
    let urlString: String?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: urlString) {
            guard let path = await ArtworkCache.shared.localPath(for: urlString) else { return }
            image = NSImage(contentsOfFile: path)
        }
    }
}

private struct ChaptersPopover: View {
    let output: RunModel.Output
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YouTube Chapters")
                .font(.headline)
            ScrollView {
                Text(output.descriptionText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 380, height: 260)
            HStack {
                Text("Also saved next to the video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.descriptionText, forType: .string)
                    copied = true
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        .padding(16)
    }
}
