#if os(macOS)
import AppKit
import SwiftUI
import SystemConfiguration

/// Settings: the people who share the library, your devices (this Mac's
/// sharing among them), named in place, where videos come from, and where
/// downloads go; addresses are kept under Advanced.
struct ManageView: View {
    var body: some View {
        TabView {
            Tab("People", systemImage: "person.2") { PeoplePane() }
            Tab("Devices", systemImage: "laptopcomputer.and.iphone") { DevicesPane() }
            Tab("Sources", systemImage: "externaldrive.connected.to.line.below") { SourcesPane() }
            Tab("Downloads", systemImage: "arrow.down.circle") { DownloadsPane() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ProblemBar() }
        .frame(width: 640, height: 480)
    }
}

// People and devices.

/// A new device nearby offering to pair, to be another of yours or a new
/// member's: the code it shows, entered here, pairs it (and adds its person,
/// if joining), and `paired` moves it on.
private struct PairRow: View {
    let device: NearbyDevice
    let paired: (NearbyDevice) -> Void
    @Environment(Library.self) private var library
    @State private var code = ""
    @State private var pairing = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(device.deviceName ?? "A new device", systemImage: device.joining ? "person.crop.circle.badge.plus" : "appletv")
                Text(device.joining ? "wants to join" : "wants to pair").foregroundStyle(.secondary)
                Spacer()
                TextField("Code", text: $code, prompt: Text("Code"))
                    .labelsHidden()
                    .font(.body.monospacedDigit())
                    .frame(width: 90)
                    .onSubmit(pair)
                Button(device.joining ? "Add" : "Pair", action: pair)
                    .disabled(digits.count != 6 || pairing)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var digits: String { code.filter(\.isNumber) }

    private func pair() {
        guard digits.count == 6, !pairing else { return }
        pairing = true
        Task {
            let (joined, why) = await library.pair(device, code: digits)
            failure = why
            pairing = false
            // Out of New Devices, and into Your Devices (or People).
            if let joined {
                withAnimation {
                    library.welcome(joined, from: device)
                    paired(device)
                }
            }
        }
    }
}

/// One of your devices, its name editable here: an Apple TV can't learn
/// the name it's given in its settings, so it names itself "Apple TV".
private struct DeviceRow: View {
    let device: Device
    @Environment(Library.self) private var library
    @State private var name = ""

    var body: some View {
        HStack {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit(rename)
            if device.you {
                Text("This Mac").foregroundStyle(.secondary)
            } else {
                RemoveButton(help: "Remove it from your devices: what it changes from now on is refused, and it isn't synced with. It still knows your secret, so it could be paired again.") {
                    withAnimation { library.removeDevice(device.key) }
                }
            }
        }
        .help("Rename it for everyone in the library")
        .onAppear { name = device.name }
        .onChange(of: device.name) { name = device.name }
        // A name typed but not submitted is kept on leaving the pane.
        .onDisappear { if name != device.name { rename() } }
    }

    /// This Mac's name is advertised too, so it's set as this device's;
    /// another's, under this person.
    private func rename() {
        if device.you { library.setName(.device, name) } else { library.renameDevice(device.key, name) }
    }
}

/// A member of the library; you, by a name editable here.
private struct MemberRow: View {
    let member: Member
    @Environment(Library.self) private var library
    @State private var name = ""

    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
            if member.you {
                TextField("Your name", text: $name, prompt: Text("Your name"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .fixedSize()
                    .onSubmit { library.setName(.person, name) }
                    .help("Rename yourself for everyone in the library")
                Text("You").foregroundStyle(.secondary)
            } else {
                Text(member.name ?? "Someone")
            }
            Spacer()
            if member.founder {
                Text("Founder").foregroundStyle(.secondary)
            } else if !member.you {
                RemoveButton(help: "Remove them from the library: what they change from now on is refused") {
                    library.setMember(member.key, false)
                }
            }
        }
        .onAppear { name = member.name ?? "" }
        .onChange(of: member.name) { name = member.name ?? "" }
        .onDisappear { if member.you, name != (member.name ?? "") { library.setName(.person, name) } }
    }
}

/// Removing a row's member, device, or address: a symbol, explained by its
/// help.
private struct RemoveButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button("Remove", systemImage: "minus.circle", role: .destructive, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// A footer for the section above it that can't have one, as a collapsible
/// section can't: a section of its own, empty but for the footer.
private struct Footer: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Section {
        } footer: {
            Text(text)
        }
    }
}

/// While looking for new devices nearby, and none is found yet.
private struct Looking: View {
    var body: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text("Looking for new devices nearby…").foregroundStyle(.secondary)
        }
    }
}

/// Who's nearby, often, so a new device shows soon after it offers to
/// pair.
private struct Nearby: ViewModifier {
    @Environment(Library.self) private var library
    @Binding var devices: [NearbyDevice]

    func body(content: Content) -> some View {
        content.task {
            while !Task.isCancelled {
                devices = await library.nearby()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct PeoplePane: View {
    @Environment(Library.self) private var library
    @State private var nearby: [NearbyDevice] = []

    var body: some View {
        Form {
            Section {
                ForEach(library.members) { member in MemberRow(member: member) }
                ForEach(waiting) { device in
                    HStack {
                        Label((device.personName ?? "Someone") + "’s " + (device.deviceName ?? "device"), systemImage: "person.crop.circle.badge.questionmark")
                        Text("wants to join").foregroundStyle(.secondary)
                        Spacer()
                        Button("Add") {
                            if let key = device.person_key { library.setMember(key, true) }
                        }
                    }
                }
            } header: {
                Text("People")
            } footer: {
                Text("Everyone who shares the library sees your name. To add someone, they choose Join Someone's Library on their device, which shows a code: enter it in Devices, under New Devices.")
            }
        }
        .formStyle(.grouped)
        .modifier(Nearby(devices: $nearby))
    }

    /// Devices of this library nearby whose people aren't members yet.
    /// (New devices offering to pair have no library yet.)
    private var waiting: [NearbyDevice] {
        var seen: Set<String> = []
        return nearby.filter { $0.ours && !$0.member && !$0.added && $0.person_key != nil && seen.insert($0.person_key!).inserted }
    }
}

private struct DevicesPane: View {
    @Environment(Library.self) private var library
    @State private var nearby: [NearbyDevice] = []
    @State private var sharing = true
    @State private var advanced = false
    @State private var address = ""

    var body: some View {
        Form {
            Section {
                ForEach(library.devices) { device in DeviceRow(device: device) }
            } header: {
                Text("Your Devices")
            } footer: {
                Text("Everyone who shares the library sees your devices' names.")
            }
            Section {
                Toggle("Share this library on your network", isOn: $sharing)
                    .onChange(of: sharing) { library.sharing = sharing }
            } footer: {
                Text(library.servingPort != nil
                    ? "Your other devices, and the people who share the library, get your changes (such as where you are in what you're watching) from this Mac, and can play videos from its folders, while Cinematheque is open."
                    : "Your changes reach your other devices only when this Mac syncs with them.")
            }
            Section {
                ForEach(nearby.filter { $0.pairing != nil }) { device in
                    PairRow(device: device) { done in nearby.removeAll { $0.id == done.id } }
                }
                if !nearby.contains(where: { $0.pairing != nil }) { Looking() }
            } header: {
                Text("New Devices")
            } footer: {
                Text("To add another of your devices, choose I Use Cinematheque on Another Device on it; to add someone, they choose Join Someone's Library on theirs. Either shows a code: enter it here, beside its name.")
            }
            Section("Advanced", isExpanded: $advanced) {
                ForEach(nearby.filter(\.added)) { device in
                    HStack {
                        Text(device.url).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        RemoveButton(help: "Stop reaching it by this address") {
                            library.setDeviceAddress(device.url, false)
                            Task { nearby = await library.nearby() }
                        }
                    }
                }
                HStack {
                    Text("Address")
                    TextField("Address", text: $address, prompt: Text("http://hal.example.com:8008"))
                        .labelsHidden()
                    Button("Add") {
                        library.setDeviceAddress(address, true)
                        address = ""
                        Task { nearby = await library.nearby() }
                    }
                    .disabled(URL(string: address)?.scheme?.hasPrefix("http") != true)
                }
            }
            if advanced {
                Footer("Devices off your network, such as one behind another router (NAT), can be reached by address.")
            }
        }
        .formStyle(.grouped)
        .modifier(Nearby(devices: $nearby))
        .onAppear { sharing = library.sharing }
    }
}

// Sources.

private struct SourcesPane: View {
    @Environment(Library.self) private var library
    @State private var selection: Source.ID?
    @State private var editing: Source?
    @State private var adding = false

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
            }
            .contextMenu(forSelectionType: Source.ID.self) { ids in
                if let source = library.sources.first(where: { $0.id == ids.first }) {
                    Button(openLabel(source)) { open(source) }
                        .disabled(!canOpen(source))
                    Divider()
                    Button("Edit…") { editing = source }
                    Button("Remove", role: .destructive) { remove(source) }
                }
            } primaryAction: { ids in
                editing = library.sources.first { $0.id == ids.first }
            }
            HStack {
                Button("Add Folder…", systemImage: "folder.badge.plus") { chooseFolder() }
                    .help("Add a folder on this Mac")
                Button("Add Server…", systemImage: "server.rack") { adding = true }
                    .help("Add a server on your network, such as a NAS, by its address")
                // A bare minus, as under tables on the Mac.
                Button("Remove", systemImage: "minus") {
                    if let source = library.sources.first(where: { $0.id == selection }) { remove(source) }
                }
                .labelStyle(.iconOnly)
                .help("Remove the selected source")
                .disabled(selection == nil)
                if let source = selected {
                    Button(openLabel(source), systemImage: library.folder(of: source) == nil ? "safari" : "folder") { open(source) }
                        .disabled(!canOpen(source))
                        .help(library.folder(of: source) == nil ? "See what the server lists, in your browser" : "See the folder in the Finder")
                }
                Spacer()
                if let activity = library.activity {
                    ProgressView().controlSize(.small)
                    Text(activity + "…").foregroundStyle(.secondary)
                } else {
                    Button("Refresh Library") { Task { await library.refresh() } }
                        .disabled(library.sources.isEmpty)
                }
            }
        }
        .padding()
        .sheet(isPresented: $adding) { SourceSheet(source: nil) }
        .sheet(item: $editing) { SourceSheet(source: $0) }
    }

    private var selected: Source? { library.sources.first { $0.id == selection } }

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

/// Adding a source by its address, or editing one; its rendition and the
/// names to skip are advanced.
private struct SourceSheet: View {
    let source: Source?
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var rendition = ""
    @State private var skip = ","
    @State private var advanced = false

    var body: some View {
        Form {
            Section {
                if let source {
                    LabeledContent("Address", value: source.url.removingPercentEncoding ?? source.url)
                } else {
                    TextField("Address", text: $url, prompt: Text("http://nas.local/Video/Movies/"))
                }
            } footer: {
                if source == nil {
                    Text("The address of a folder of videos on a server, as a browser would open it.")
                }
            }
            Section("Advanced", isExpanded: $advanced) {
                TextField("Rendition", text: $rendition, prompt: Text("From file names"))
            }
            if advanced {
                Footer("Name its rendition (e.g., 4K HDR) only if its files' names don't show it.")
                Section {
                    TextField("Skip names starting with", text: $skip)
                }
            }
            // As it is now, so one forgotten leaves the list.
            if let current = library.sources.first(where: { $0.id == source?.id }), !current.unavailable.isEmpty {
                Section {
                    ForEach(current.unavailable, id: \.dir) { gone in
                        HStack {
                            Label(gone.name, systemImage: "externaldrive.badge.questionmark")
                            Text("since \(gone.date.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary)
                            Spacer()
                            Button("Forget") { library.forgetUnavailable(current.id, gone.dir) }
                                .help("Forget it as if deleted: its videos go, for every device")
                        }
                    }
                } header: {
                    Text("Unavailable")
                } footer: {
                    Text("Folders that held videos and are empty now, as a drive's is when it's unplugged. Their videos stay, dimmed, until they're back, for a year, or until you forget them.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(source == nil ? "Add" : "Save") {
                    if let source {
                        library.setSource(source.id, rendition: rendition, skip: skip)
                    } else {
                        library.addSource(url, rendition: rendition.isEmpty ? nil : rendition, skip: skip)
                        Task { await library.crawl() }
                    }
                    dismiss()
                }
                .disabled(source == nil && URL(string: url)?.scheme?.hasPrefix("http") != true)
            }
        }
        .onAppear {
            if let source {
                rendition = source.rendition
                skip = source.skip
                advanced = !rendition.isEmpty || skip != ","
            }
        }
    }
}
// Downloads.

/// Where this Mac keeps downloads, how much they hold, and whether a kept
/// series' watched episodes go at once.
private struct DownloadsPane: View {
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
                        // Symbols: choosing a folder, and revealing it, as
                        // the Finder's own reveal arrow does.
                        Button("Choose Folder…", systemImage: "folder", action: choose)
                            .labelStyle(.iconOnly)
                            .help("Choose another folder for downloads")
                        Button("Show in Finder", systemImage: "arrow.forward.circle") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: library.downloadsDir)
                        }
                        .labelStyle(.iconOnly)
                        .help("Show in Finder")
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
                Text("Your other devices can play what this Mac downloads while Cinematheque is open. It always leaves \(floor) free.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Delete watched downloads right away", isOn: Binding(
                    get: { library.downloads?.drop_watched ?? false },
                    set: { library.setDownloads(dropWatched: $0) }
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
        panel.message = "Choose where Cinematheque keeps downloads. What you've downloaded downloads again there; the old folder's files stay until you delete them."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.setDownloads(dir: url.path)
    }
}

#endif
