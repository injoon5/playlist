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

/// Open and save panels, shown as sheets on the window they were asked
/// from (the main window or Settings), like any document-style Mac app.
@MainActor
enum Panels {
    private static func present(_ panel: NSSavePanel) async -> Bool {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            return await panel.beginSheetModal(for: window) == .OK
        }
        return panel.runModal() == .OK
    }

    static func chooseOutput(current: String) async -> String? {
        let panel = NSSavePanel()
        panel.message = "Choose where to save the video."
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let url = URL(fileURLWithPath: current.isEmpty ? AppModel.defaultOutputPath : current)
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        return await present(panel) ? panel.url?.path : nil
    }

    /// Save another copy of a finished video (and its chapters file).
    static func saveCopy(of output: RunModel.Output) async {
        let source = URL(fileURLWithPath: output.videoPath)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = source.lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard await present(panel), let dest = panel.url, dest.standardizedFileURL != source.standardizedFileURL else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }  // the panel already asked
            try fm.copyItem(at: source, to: dest)
            let chapters = dest.deletingPathExtension().path + "_description.txt"
            try? fm.removeItem(atPath: chapters)
            try? fm.copyItem(atPath: output.descriptionPath, toPath: chapters)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            let alert = NSAlert(error: error)
            if let window = NSApp.mainWindow {
                await alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    static func chooseImages() async -> [String] {
        let panel = NSOpenPanel()
        panel.message = "Choose images to use as video backgrounds."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        return await present(panel) ? panel.urls.map(\.path) : []
    }

    /// A command-line tool (Settings › Tools). Starts in the folder of the
    /// current one, else Homebrew's bin folder.
    static func chooseExecutable(message: String, current: String?) async -> String? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        let start = current.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.directoryURL = start
        return await present(panel) ? panel.url?.path : nil
    }
}
