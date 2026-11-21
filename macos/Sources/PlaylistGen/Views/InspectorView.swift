import ImageIO
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                PreviewPane()
            }

            Section("Video") {
                Picker("Resolution", selection: $model.settings.resolution) {
                    ForEach(RunSettings.resolutions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                Picker("Frame Rate", selection: $model.settings.fps) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                LabeledContent("Transition") {
                    HStack {
                        Slider(value: $model.settings.transitionDuration, in: 0...2, step: 0.1)
                        Text(model.settings.transitionDuration == 0
                             ? "Off" : String(format: "%.1f s", model.settings.transitionDuration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .help("Fade through black between songs")
            }

            Section {
                BackgroundPicker()
            } header: {
                Text("Background")
            } footer: {
                Text(model.settings.backgrounds.isEmpty
                     ? "Each song uses its own artwork, blurred."
                     : "Images play in numbered order, each covering an equal run of songs.")
                    .foregroundStyle(.secondary)
            }

            Section("Save To") {
                HStack {
                    PathControlView(path: model.settings.output)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") {
                        if let path = Panels.chooseOutput(current: model.settings.output) {
                            model.settings.output = path
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Thumbnails of assets/backgrounds plus user-added images. Click to toggle;
/// the badge shows block order.
struct BackgroundPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(model.backgroundCandidates, id: \.self) { path in
                    let order = model.settings.backgrounds.firstIndex(of: path)
                    Button {
                        model.toggleBackground(path)
                    } label: {
                        BackgroundThumbnail(path: path, order: order)
                    }
                    .buttonStyle(.plain)
                    .help((path as NSString).lastPathComponent)
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        if model.settings.extraBackgrounds.contains(path) {
                            Button("Remove from List") { model.removeExtraBackground(path) }
                        }
                    }
                }
            }
            HStack {
                Button("Add Images…") {
                    model.addBackgrounds(Panels.chooseImages())
                }
                Spacer()
                Button("Use Song Artwork") { model.settings.backgrounds = [] }
                    .disabled(model.settings.backgrounds.isEmpty)
            }
            .controlSize(.small)
        }
    }
}

struct BackgroundThumbnail: View {
    let path: String
    let order: Int?
    @State private var image: CGImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(order != nil ? Color.accentColor : Color.primary.opacity(0.1),
                                  lineWidth: order != nil ? 2.5 : 1)
            }
            .opacity(order != nil ? 1 : 0.75)

            if let order {
                Text("\(order + 1)")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        .task(id: path) {
            let path = path
            image = await Task.detached(priority: .utility) {
                Thumbnail.make(path: path, maxPixel: 240).map(PreviewFrame.init(image:))
            }.value?.image
        }
    }
}

enum Thumbnail {
    static func make(path: String, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Live preview of the selected track, drawn by the same renderer as the video.
struct PreviewPane: View {
    @Environment(AppModel.self) private var model
    @State private var preview = PreviewModel()

    var body: some View {
        @Bindable var preview = preview
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black)
                if let frame = preview.frame {
                    Image(decorative: frame.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if model.previewKey == nil {
                    Text("Load a playlist to preview")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if preview.isRendering && preview.frame == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(CGFloat(model.settings.size.width) / CGFloat(model.settings.size.height), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let key = preview.key {
                HStack(spacing: 8) {
                    Button {
                        preview.isPlaying.toggle()
                    } label: {
                        Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 14)
                    }
                    .buttonStyle(.borderless)
                    .help(preview.isPlaying ? "Pause" : "Play the preview")
                    Slider(value: $preview.time, in: 0...max(key.duration, 0.1)) { editing in
                        if editing { preview.isPlaying = false }
                    }
                    .controlSize(.small)
                    Text(formatDuration(preview.time))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .task(id: model.previewKey) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await preview.update(key: model.previewKey)
        }
        .onChange(of: preview.time) {
            guard !preview.isPlaying else { return }
            Task { await preview.render() }
        }
    }
}
