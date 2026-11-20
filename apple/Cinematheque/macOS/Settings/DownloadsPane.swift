#if os(macOS)
import AppKit
import SwiftUI

/// Where this Mac keeps downloads, how much they hold, and whether a kept
/// series' watched episodes go at once.
struct DownloadsPane: View {
    @Environment(Library.self) private var library

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text((library.downloadsDir as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(library.downloadsDir)
                        // Show in Finder's symbol, as in the inspector.
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: library.downloadsDir)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                        Button("Choose…", action: choose)
                    }
                }
                LabeledContent("Downloaded", value: downloaded)
                if let d = library.downloads, d.running, d.total_mb > 0 {
                    LabeledContent("Downloading") {
                        ProgressView(value: Double(min(d.done_mb, d.total_mb)), total: Double(d.total_mb)) {
                            Text("\(megabytes(d.done_mb)) of \(megabytes(d.total_mb))").monospacedDigit()
                        }
                    }
                }
            } footer: {
                Text("Your other devices can play what this Mac downloads while Cinematheque is open. It always leaves \(floor) free. In another folder, your downloads download again; the old folder's files stay until you delete them.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Delete watched downloads right away", isOn: Binding(
                    get: { library.downloads?.drop_watched ?? false },
                    set: { library.setDropWatched($0) }
                ))
            } header: {
                Text("Watched downloads")
            } footer: {
                Text("Otherwise a download you've watched stays until its space is needed, as for a series' next episodes. Either way, only downloads that another source still has are deleted, and never those you keep.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var downloaded: String {
        let held = library.downloads?.held.count ?? 0
        let size = library.downloadedBytes.formatted(.byteCount(style: .file))
        let free = library.downloads?.free.map { ", \($0.formatted(.byteCount(style: .file))) free" } ?? ""
        return "\(held == 1 ? "1 video" : "\(held.formatted()) videos"), \(size)\(free)"
    }

    private var floor: String { (library.downloads?.floor ?? 0).formatted(.byteCount(style: .file)) }

    private func megabytes(_ mb: Int) -> String { (mb * 1_000_000).formatted(.byteCount(style: .file)) }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where to keep downloads."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.setDownloads(dir: url.path)
    }
}
#endif
