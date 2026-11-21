import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Append-only run log in an NSTextView (selectable, monospaced, follows the tail).
struct LogTextView: NSViewRepresentable {
    var lines: [RunModel.LogLine]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isAutomaticLinkDetectionEnabled = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
        let coordinator = context.coordinator
        if lines.count < coordinator.appended {
            storage.setAttributedString(NSAttributedString())
            coordinator.appended = 0
        }
        guard lines.count > coordinator.appended else { return }
        let atBottom = scroll.verticalScroller.map { $0.floatValue > 0.98 || $0.isHidden } ?? true
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let chunk = NSMutableAttributedString()
        for line in lines[coordinator.appended...] {
            let color: NSColor = switch line.kind {
            case .info: .labelColor
            case .success: .systemGreen
            case .warning: .systemOrange
            case .error: .systemRed
            case .output: .secondaryLabelColor
            }
            chunk.append(NSAttributedString(
                string: line.text + "\n", attributes: [.font: font, .foregroundColor: color]
            ))
        }
        storage.append(chunk)
        coordinator.appended = lines.count
        if atBottom { text.scrollToEndOfDocument(nil) }
    }

    @MainActor final class Coordinator {
        var appended = 0
    }
}

/// NSPathControl showing a file location; double-click reveals it in Finder.
struct PathControlView: NSViewRepresentable {
    var path: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.isEditable = false
        control.focusRingType = .none
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        control.backgroundColor = .clear
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.target = context.coordinator
        control.doubleAction = #selector(Coordinator.reveal(_:))
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        let url = path.isEmpty ? nil : URL(fileURLWithPath: path)
        if control.url != url { control.url = url }
    }

    @MainActor final class Coordinator: NSObject {
        @objc func reveal(_ sender: NSPathControl) {
            guard let url = sender.clickedPathItem?.url ?? sender.url else { return }
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url.deletingLastPathComponent())
            }
        }
    }
}

@MainActor
enum Panels {
    static func chooseOutput(current: String) -> String? {
        let panel = NSSavePanel()
        panel.title = "Save Video As"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        if !current.isEmpty {
            let url = URL(fileURLWithPath: current)
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        } else {
            panel.nameFieldStringValue = "playlist_video.mp4"
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Save another copy of a finished video (and its chapters file).
    static func saveCopy(of output: RunModel.Output) {
        let source = URL(fileURLWithPath: output.videoPath)
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = source.lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dest = panel.url, dest.standardizedFileURL != source.standardizedFileURL else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }  // the panel already asked
            try fm.copyItem(at: source, to: dest)
            let chapters = dest.deletingPathExtension().path + "_description.txt"
            try? fm.removeItem(atPath: chapters)
            try? fm.copyItem(atPath: output.descriptionPath, toPath: chapters)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func chooseImages() -> [String] {
        let panel = NSOpenPanel()
        panel.title = "Add Background Images"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }

    static func chooseFolder(title: String, current: String?) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let current { panel.directoryURL = URL(fileURLWithPath: current) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func chooseExecutable(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
