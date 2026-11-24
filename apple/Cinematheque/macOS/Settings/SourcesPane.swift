#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SourcesPane: View {
    @Environment(Library.self) private var library
    @State private var selection: Source.ID?
    @State private var editing: Source?
    @State private var adding = false
    @State private var choosingFolder = false
    /// A source to remove, once confirmed: removing one takes its copies
    /// from the library on every device.
    @State private var removing: Source?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add the folders and servers that hold your videos, such as a NAS, and every device in the library can browse and play them.")
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
                                .rowSymbol()
                        }
                        .help(unavailable ? "\(folder.path) isn't there; its titles are dimmed until it's back" : folder.path)
                    } else {
                        Label {
                            // Folders of it on drives that aren't there.
                            Text(source.displayName) + Text(source.unavailable.isEmpty ? "" : "  \(source.unavailable.count == 1 ? "a folder" : "\(source.unavailable.count) folders") unavailable").foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "server.rack")
                                .rowSymbol()
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(source.reached.removingPercentEncoding ?? source.reached)
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
                            .help(library.folder(of: source) == nil ? "Open in Browser" : "Show in Finder")
                        Button("Remove", systemImage: "minus.circle") { removing = source }
                            .frame(width: 18)
                            .help("Remove this source and its videos, on every device")
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
            // For every device: a NAS's disks spin up for each look.
            VStack(alignment: .leading) {
                Picker("Look for videos", selection: Binding(get: { library.crawlEvery }, set: { library.setCrawlEvery($0) })) {
                    ForEach(Library.crawlChoices, id: \.hours) { Text($0.name).tag($0.hours) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Text("Look more often to see new videos sooner, or less often to let a NAS's disks rest; each look wakes them. This applies to everyone in the library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            // At the pane's foot, as Settings' actions are; refreshing is
            // File › Refresh Library's.
            HStack {
                Button("Add Folder…") { choosingFolder = true }
                    .help("Add a folder on this Mac")
                Button("Add Server…") { adding = true }
                    .help("Add a server, such as a NAS")
                Spacer()
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
        // A folder to serve from this Mac: a local one, or a mounted
        // share's (e.g., /Volumes/Shared).
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await library.addFolder(url.path) }
        }
        .fileDialogMessage("Choose a folder of videos to share with your devices.")
        .fileDialogConfirmationLabel("Add")
        .sheet(item: $editing) { SourceSheet(source: $0) }
    }

    /// A folder on this Mac opens in the Finder; a server, in the browser,
    /// which shows its listing.
    private func openLabel(_ source: Source) -> String {
        library.folder(of: source) == nil ? "Open in Browser" : "Show in Finder"
    }

    private func canOpen(_ source: Source) -> Bool {
        guard let folder = library.folder(of: source) else { return URL(web: source.reached) != nil }
        return !library.unavailableFolders.contains(folder.prefix)
    }

    private func open(_ source: Source) {
        if let folder = library.folder(of: source) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        } else if let url = URL(web: source.reached) {
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

}

/// Adding a source by its address, or editing one: where its files'
/// quality comes from, and names to skip.
private struct SourceSheet: View {
    let source: Source?
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var quality = ""
    @State private var from = Source.QualityFrom.names
    /// The prefix of names to skip, none if empty.
    @State private var skip = ""
    /// For a folder of this Mac, the folder it's served from, which
    /// Choose… changes.
    @State private var path: String?
    @State private var choosing = false
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
                    let chosen: Source.Quality = switch from {
                    case .names: .names
                    case .folder: .folder
                    case .named: .named(quality)
                    case .unknown: .unknown
                    }
                    if let source {
                        if chosen != source.qualitySetting { library.setQuality(source.id, chosen) }
                        if skip != source.skip { library.setSkip(source.id, skip) }
                        if let folder = library.folder(of: source), let path, path != folder.path {
                            Task { await library.changeFolder(folder, to: path) }
                        }
                    } else {
                        library.addSource(url, skip: skip.isEmpty ? nil : skip)
                        if chosen != .names { library.setQuality(url, chosen) }
                        Task { await library.crawl() }
                    }
                    dismiss()
                }
                .disabled((source == nil && URL(web: url) == nil) || (from == .named && quality.isEmpty))
            }
        }
        .onAppear {
            if let source {
                quality = source.quality
                from = source.quality_from
                skip = source.skip
                path = library.folder(of: source)?.path
            }
        }
    }

    /// An existing server's address, which can't change, or a folder of
    /// this Mac, which Choose… changes, as the Downloads pane's; and what
    /// can change, as Settings' forms are.
    private var form: some View {
        Form {
            if let path {
                Section {
                    LabeledContent("Folder") {
                        HStack {
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                            Button("Show in Finder", systemImage: "folder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                            Button("Choose…") { choosing = true }
                        }
                    }
                } footer: {
                    Text("If its videos move (to a new drive, say), choose where they are now: they stay in the library, nothing to look for again but what changed.")
                        .foregroundStyle(.secondary)
                }
            } else if let source {
                Section {
                    LabeledContent("Address", value: source.reached.removingPercentEncoding ?? source.reached)
                }
            }
            Section {
                Picker("Quality", selection: $from) {
                    Text("From File Names").tag(Source.QualityFrom.names)
                    Text("From the Folder Under It").tag(Source.QualityFrom.folder)
                    Text("Named").tag(Source.QualityFrom.named)
                    // Kept as it is, unless another is chosen.
                    if from == .unknown { Text("Set by a Newer Version").tag(Source.QualityFrom.unknown) }
                }
                // Only for a name, as Settings show a choice's details.
                if from == .named {
                    TextField("Name", text: $quality, prompt: Text("4K HDR"))
                }
                TextField("Skip Names Starting With", text: $skip, prompt: Text("None"))
            } footer: {
                Text("If the videos' names don't say their quality, set it here so you can choose which quality plays: from the folder each is in, just under this one (as Movies/HQ 1080p/Alien.m4v), or one name for all of them. To leave files out of the library, put them in folders whose names start with what Skip says; titles starting with it are left out too.")
                    .foregroundStyle(.secondary)
            }
            // As it is now, so one removed leaves the list.
            if let current = library.sources.first(where: { $0.id == source?.id }), !current.unavailable.isEmpty {
                Section {
                    ForEach(current.unavailable, id: \.dir) { gone in
                        LabeledContent {
                            Button("Remove Videos", systemImage: "minus.circle") { library.removeUnavailable(current.id, gone.dir) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Remove its videos; they return if the folder does")
                        } label: {
                            Label(gone.name, systemImage: "externaldrive.badge.questionmark")
                            Text("Since \(gone.date.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                } header: {
                    Text("Unavailable")
                } footer: {
                    Text("Folders that are empty now, as when a drive is unplugged. Their videos stay, dimmed, so nothing's lost while it's away; remove them if it's gone for good. After a year, they go on their own.")
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { path = url.path }
        }
        .fileDialogMessage("Choose where this folder's videos are now.")
        .fileDialogConfirmationLabel("Choose")
    }
}
#endif
