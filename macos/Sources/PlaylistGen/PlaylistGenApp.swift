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
                if let output = model.run?.output { Panels.saveCopy(of: output) }
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
            Button("Select All Songs") { model.setAllIncluded(true) }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(model.tracks.isEmpty || model.run != nil)
            Button("Deselect All Songs") { model.setAllIncluded(false) }
                .keyboardShortcut("a", modifiers: [.command, .option, .shift])
                .disabled(model.tracks.isEmpty || model.run != nil)
            Divider()
            Button("Cancel Generation") { model.run?.cancel() }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.run?.isActive == true {
            let alert = NSAlert()
            alert.messageText = "Stop generating the video?"
            alert.informativeText = "Quitting cancels the current run."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Keep Running")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        model.shutdown()
        return .terminateNow
    }
}
