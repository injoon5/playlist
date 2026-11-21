import AppKit
import SwiftUI

@main
struct PlaylistGenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Playlist Gen", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            PlaylistCommands(model: model)
            InspectorCommands()
        }

        Settings {
            PreferencesView()
                .environment(model)
        }
    }
}

struct PlaylistCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {
            Button("Save a Copy…") {
                if let output = model.run?.output { Task { await Panels.saveCopy(of: output) } }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(model.run?.output == nil)
            Button("Show in Finder") {
                if let output = model.run?.output {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output.videoPath)])
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(model.run?.output == nil)
        }
        CommandMenu("Playlist") {
            Button("Load Playlist") { model.loadTracks() }
                .keyboardShortcut("l")
                .disabled(model.environment == nil || model.run != nil || model.isLoading)
            Button("Generate Video") { model.requestGenerate() }
                .keyboardShortcut(.return)
                .disabled(!model.canGenerate)
            Divider()
            Button("Include All Songs") { model.setAllIncluded(true) }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(model.tracks.isEmpty || model.run != nil)
            Button("Exclude All Songs") { model.setAllIncluded(false) }
                .keyboardShortcut("a", modifiers: [.command, .option, .shift])
                .disabled(model.tracks.isEmpty || model.run != nil)
            Divider()
            Button("Stop Generating") { model.run?.cancel() }
                .keyboardShortcut(".")
                .disabled(model.run?.state != .running)
            Button("Back to Playlist") { model.closeRun() }
                .keyboardShortcut("[")
                .disabled(model.run == nil || model.run?.isActive == true)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a bridge whose process already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Needed when launched as a bare executable (`swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Closing the window quits, except mid-render: then the render keeps
    /// going (Dock progress + a notification when done) and clicking the
    /// Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model?.run?.isActive != true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.run?.isActive == true {
            let alert = NSAlert()
            alert.messageText = "Quit while the video is being generated?"
            alert.informativeText = "Quitting stops generating and deletes the unfinished video."
            alert.addButton(withTitle: "Quit").hasDestructiveAction = true
            alert.addButton(withTitle: "Keep Generating")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        model.shutdown()
        return .terminateNow
    }
}
