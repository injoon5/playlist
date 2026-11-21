import AppKit
import SwiftUI

struct RunView: View {
    @Environment(AppModel.self) private var model
    let run: RunModel

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let output = run.output {
                    ResultBanner(output: output)
                }
                HStack(alignment: .top, spacing: 14) {
                    if let output = run.output {
                        DescriptionBox(output: output)
                            .frame(width: 340)
                    } else {
                        GroupBox("Active") { slots }
                            .frame(width: 340)
                    }
                    GroupBox("Tracks") {
                        RunTableView(rows: run.rows)
                            .frame(minHeight: 140)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(16)
            .frame(minHeight: 320)

            LogTextView(lines: run.log)
                .frame(minHeight: 90, idealHeight: 150)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if run.isActive {
                    Button(role: .cancel) {
                        run.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.glass)
                    .disabled(run.state == .cancelling)
                    .help("Stop downloading and rendering (⌘.)")
                } else {
                    Button {
                        model.closeRun()
                    } label: {
                        Label("Back to Songs", systemImage: "chevron.backward")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.glass)
                    .help("Return to the song list (⌘[)")
                }
            }
        }
        .navigationTitle("Playlist Gen")
        .navigationSubtitle(URL(fileURLWithPath: run.config.output).lastPathComponent)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
                .font(.system(size: 26))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(run.headline)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timing(now: context.date))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: run.progress.value)
                    .progressViewStyle(.linear)
                    .tint(tint)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch run.state {
        case .running, .cancelling:
            Image(systemName: run.phase == "download" ? "arrow.down.circle" : run.phase == "concat" ? "square.stack.3d.down.right" : "film")
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, options: .repeating)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private var tint: Color {
        switch run.state {
        case .finished: .green
        case .failed: .red
        case .cancelled, .cancelling: .secondary
        case .running: .accentColor
        }
    }

    private func timing(now: Date) -> String {
        let end = run.finishedAt ?? now
        let elapsed = end.timeIntervalSince(run.startedAt)
        var text = "Elapsed \(formatDuration(elapsed))"
        let p = run.progress.value
        if run.isActive, p > 0.03, p < 1 {
            text += " · about \(formatDuration(elapsed * (1 - p) / p)) left"
        }
        return text
    }

    @ViewBuilder
    private var slots: some View {
        let active = run.slots.values.sorted { $0.id < $1.id }
        if active.isEmpty {
            Text(run.isActive ? "Waiting…" : "Idle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(active) { slot in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: slot.phase == "download" ? "arrow.down" : "film")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(slot.label)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(Int(slot.fraction * 100))%")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            ProgressView(value: slot.fraction)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(4)
            }
        }
    }
}

private struct ResultBanner: View {
    let output: RunModel.Output

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: output.videoPath).lastPathComponent)
                    .font(.headline)
                Text(output.videoPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output.videoPath)])
            }
            .buttonStyle(.glass)
            Button("Play", systemImage: "play.fill") {
                NSWorkspace.shared.open(URL(fileURLWithPath: output.videoPath))
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DescriptionBox: View {
    let output: RunModel.Output
    @State private var copied = false

    var body: some View {
        GroupBox {
            ScrollView {
                Text(output.descriptionText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
        } label: {
            HStack {
                Text("YouTube Chapters")
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.descriptionText, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
        }
    }
}
