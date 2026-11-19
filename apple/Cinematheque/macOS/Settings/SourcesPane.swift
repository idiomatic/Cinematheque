#if os(macOS)
import AppKit
import SwiftUI

struct SourcesPane: View {
    @Environment(Library.self) private var library
    @State private var selection: Source.ID?
    @State private var editing: Source?
    @State private var adding = false
    /// A source to remove, once confirmed: removing one takes its copies
    /// from the library on every device.
    @State private var removing: Source?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Cinematheque finds videos in folders on this Mac, and on servers on your network, such as a NAS.")
                .foregroundStyle(.secondary)
            // Devices' downloads are theirs to manage (see Downloads).
            Table(library.sources.filter { !$0.managed }, selection: $selection) {
                TableColumn("Source") { source in
                    if let folder = library.folder(of: source) {
                        let unavailable = library.unavailableFolders.contains(folder.prefix)
                        Label {
                            Text(folder.name) + Text(unavailable ? "  unavailable on this Mac" : "  on this Mac").foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: unavailable ? "folder.badge.questionmark" : "folder")
                        }
                        .help(unavailable ? "\(folder.path) isn't there (a share unmounted, or a drive unplugged?); its titles show dimmed until it's back." : folder.path)
                    } else {
                        Label {
                            // Folders of it on drives that aren't there.
                            Text(source.displayName) + Text(source.unavailable.isEmpty ? "" : "  \(source.unavailable.count == 1 ? "a folder" : "\(source.unavailable.count) folders") unavailable").foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "server.rack")
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(source.url.removingPercentEncoding ?? source.url)
                    }
                }
                TableColumn("Videos") { Text($0.copies.formatted()).monospacedDigit() }
                    .width(70)
                    .alignment(.trailing)
                // What acts on a source, beside it.
                TableColumn("") { source in
                    // A fixed width each, so the symbols (a folder's is wider
                    // than Safari's) line up down the column.
                    HStack(spacing: 10) {
                        Button(openLabel(source), systemImage: library.folder(of: source) == nil ? "safari" : "folder") { open(source) }
                            .frame(width: 18)
                            .disabled(!canOpen(source))
                            .help(library.folder(of: source) == nil ? "See what the server lists, in your browser" : "See the folder in the Finder")
                        Button("Remove", systemImage: "minus.circle") { removing = source }
                            .frame(width: 18)
                            .help("Remove this source, and the copies it holds, for every device")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .width(52)
            }
            .contextMenu(forSelectionType: Source.ID.self) { ids in
                if let source = library.sources.first(where: { $0.id == ids.first }) {
                    Button(openLabel(source)) { open(source) }
                        .disabled(!canOpen(source))
                    Divider()
                    Button("Edit…") { editing = source }
                    Button("Remove…", role: .destructive) { removing = source }
                }
            } primaryAction: { ids in
                editing = library.sources.first { $0.id == ids.first }
            }
            HStack {
                Button("Add Folder…") { chooseFolder() }
                    .help("Add a folder on this Mac")
                Button("Add Server…") { adding = true }
                    .help("Add a server on your network, such as a NAS, by its address")
                Spacer()
                // For every device: a NAS's disks spin up for each look.
                Picker("Look for videos", selection: Binding(get: { library.crawlEvery }, set: { library.setCrawlEvery($0) })) {
                    ForEach(Library.crawlChoices, id: \.hours) { Text($0.name).tag($0.hours) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("How often your devices look for new videos as they open, for everyone in the library; Refresh Library looks at once. A NAS's disks spin up each time.")
                // Nothing in the row comes or goes: the spinner keeps its
                // place, and the button is dimmed while a refresh runs (its
                // steps show in the library window's status bar).
                ProgressView().controlSize(.small).opacity(library.activity == nil ? 0 : 1)
                    .help(library.activity.map { $0 + "…" } ?? "")
                Button("Refresh Library") { Task { await library.refresh() } }
                    .help("Catch up with your devices, then look for new videos")
                    .disabled(library.sources.isEmpty || library.activity != nil)
            }
        }
        .padding()
        // The one confirmation: removing a source can't be undone but by
        // adding it again and looking for its videos anew.
        .confirmationDialog(
            removing.map { "Remove “\(name(of: $0))”?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { source in
            Button("Remove", role: .destructive) { remove(source) }
            Button("Cancel", role: .cancel) {}
        } message: { source in
            Text(removalMessage(source))
        }
        .sheet(isPresented: $adding) { SourceSheet(source: nil) }
        .sheet(item: $editing) { SourceSheet(source: $0) }
    }

    /// A folder on this Mac opens in the Finder; a server, in the browser,
    /// which shows its listing.
    private func openLabel(_ source: Source) -> String {
        library.folder(of: source) == nil ? "Open in Browser" : "Show in Finder"
    }

    private func canOpen(_ source: Source) -> Bool {
        guard let folder = library.folder(of: source) else { return URL(string: source.url) != nil }
        return !library.unavailableFolders.contains(folder.prefix)
    }

    private func open(_ source: Source) {
        if let folder = library.folder(of: source) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        } else if let url = URL(string: source.url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func name(of source: Source) -> String {
        library.folder(of: source)?.name ?? source.displayName
    }

    private func removalMessage(_ source: Source) -> String {
        let copies = source.copies == 1 ? "Its one video goes" : "Its \(source.copies.formatted()) videos go"
        let sharing = library.folder(of: source) == nil ? "" : " This Mac stops sharing the folder."
        return "\(copies) from the library, on every device, though its files stay where they are.\(sharing) You can add it again."
    }

    private func remove(_ source: Source) {
        if let folder = library.folder(of: source) { library.removeFolder(folder) } else { library.removeSource(source.id) }
    }

    /// A folder to serve from this Mac: a local one, or a mounted share's
    /// (e.g., /Volumes/Shared).
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose a folder of videos. Cinematheque shares it with your other devices while it's open."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await library.addFolder(url.path, host: Library.localHost) }
    }
}

/// Adding a source by its address, or editing one; its quality and the
/// names to skip are advanced.
private struct SourceSheet: View {
    let source: Source?
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var quality = ""
    @State private var skip = ","
    @State private var advanced = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            // A new one's address, as Finder's Connect to Server takes one: a
            // field the sheet's width, ready to type in.
            if source == nil {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Server Address", text: $url, prompt: Text("Server Address"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($typing)
                    // Verbatim, so its example isn't made a link.
                    Text(verbatim: "The address of a folder of videos on a server, as a browser would open it, such as http://nas.local/Video/Movies/.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding([.horizontal, .top], 20)
                .onAppear { typing = true }
            }
            form
        }
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(source == nil ? "Add" : "Save") {
                    if let source {
                        library.setSource(source.id, quality: quality, skip: skip)
                    } else {
                        library.addSource(url, quality: quality.isEmpty ? nil : quality, skip: skip)
                        Task { await library.crawl() }
                    }
                    dismiss()
                }
                .disabled(source == nil && URL(string: url)?.scheme?.hasPrefix("http") != true)
            }
        }
        .onAppear {
            if let source {
                quality = source.quality
                skip = source.skip
                advanced = !quality.isEmpty || skip != ","
            }
        }
    }

    /// An existing one's address, which can't change, and what can, as
    /// Settings' forms are.
    private var form: some View {
        Form {
            if let source {
                Section {
                    LabeledContent("Address", value: source.url.removingPercentEncoding ?? source.url)
                }
            }
            Section("Advanced", isExpanded: $advanced) {
                TextField("Quality", text: $quality, prompt: Text("From file names"))
            }
            if advanced {
                Footer("Name its quality (e.g., 4K HDR) only if its files' names don't show it.")
                Section {
                    TextField("Skip names starting with", text: $skip)
                }
            }
            // As it is now, so one removed leaves the list.
            if let current = library.sources.first(where: { $0.id == source?.id }), !current.unavailable.isEmpty {
                Section {
                    ForEach(current.unavailable, id: \.dir) { gone in
                        HStack {
                            Label(gone.name, systemImage: "externaldrive.badge.questionmark")
                            Text("since \(gone.date.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove Videos", systemImage: "minus.circle") { library.removeUnavailable(current.id, gone.dir) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Remove its videos from the library, for every device, as if it were deleted; they come back if it does")
                        }
                    }
                } header: {
                    Text("Unavailable")
                } footer: {
                    Text("Folders that held videos and are empty now, as a drive's is when it's unplugged. Their videos stay, dimmed, until they're back, for a year, or until you remove them.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
#endif
