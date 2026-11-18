import AppKit
import SwiftUI
import SystemConfiguration

/// Settings: the names others see, sharing, where videos come from, and the
/// people and devices that share the library; keys and addresses are kept
/// under Advanced.
struct ManageView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPane() }
            Tab("Sources", systemImage: "externaldrive.connected.to.line.below") { SourcesPane() }
            Tab("People & Devices", systemImage: "person.2") { PeoplePane() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ProblemBar() }
        .frame(width: 640, height: 480)
    }
}

// General.

private struct GeneralPane: View {
    @Environment(Library.self) private var library
    @State private var userName = ""
    @State private var deviceName = ""
    @State private var sharing = true

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $userName)
                    .onSubmit { library.setName(.user, userName) }
                TextField("This Mac's name", text: $deviceName)
                    .onSubmit { library.setName(.device, deviceName) }
            } footer: {
                Text("Everyone who shares the library sees these names.")
            }
            Section {
                Toggle("Share this library on your network", isOn: $sharing)
                    .onChange(of: sharing) { library.sharing = sharing }
            } footer: {
                Text(library.servingPort != nil
                    ? "Your other devices, and the people who share the library, get your changes (such as where you are in what you're watching) from this Mac, and can play videos from its folders, while Cinematheque is open."
                    : "Your changes reach your other devices only when this Mac syncs with them.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            userName = library.userName ?? ""
            deviceName = library.deviceName ?? ""
            sharing = library.sharing
        }
        // Names typed but not submitted are kept on leaving the pane.
        .onDisappear {
            if userName != (library.userName ?? "") { library.setName(.user, userName) }
            if deviceName != (library.deviceName ?? "") { library.setName(.device, deviceName) }
        }
    }
}

// Sources.

private struct SourcesPane: View {
    @Environment(Library.self) private var library
    @State private var selection: Repository.ID?
    @State private var editing: Repository?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("Cinematheque finds videos in folders on this Mac, and on servers on your network, such as a NAS.")
                .foregroundStyle(.secondary)
            Table(library.repositories, selection: $selection) {
                TableColumn("Source") { repo in
                    if let folder = library.folder(of: repo) {
                        Label {
                            Text(folder.name) + Text("  on this Mac").foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "folder")
                        }
                        .help(folder.path)
                    } else {
                        Label(repo.displayName, systemImage: "server.rack")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(repo.url.removingPercentEncoding ?? repo.url)
                    }
                }
                TableColumn("Videos") { Text($0.copies.formatted()).monospacedDigit() }
                    .width(70)
            }
            .contextMenu(forSelectionType: Repository.ID.self) { ids in
                if let repo = library.repositories.first(where: { $0.id == ids.first }) {
                    Button("Edit…") { editing = repo }
                    Button("Remove", role: .destructive) { remove(repo) }
                }
            } primaryAction: { ids in
                editing = library.repositories.first { $0.id == ids.first }
            }
            HStack {
                Menu("Add", systemImage: "plus") {
                    Button("Folder on This Mac…") { chooseFolder() }
                    Button("Network Address…") { adding = true }
                }
                .fixedSize()
                Button("Remove", systemImage: "minus") {
                    if let repo = library.repositories.first(where: { $0.id == selection }) { remove(repo) }
                }
                .disabled(selection == nil)
                Spacer()
                if let activity = library.activity {
                    ProgressView().controlSize(.small)
                    Text(activity + "…").foregroundStyle(.secondary)
                } else {
                    Button("Look for New Videos") { Task { await library.refresh() } }
                        .disabled(library.repositories.isEmpty)
                }
            }
        }
        .padding()
        .sheet(isPresented: $adding) { SourceSheet(repository: nil) }
        .sheet(item: $editing) { SourceSheet(repository: $0) }
    }

    private func remove(_ repo: Repository) {
        if let folder = library.folder(of: repo) { library.removeFolder(folder) } else { library.removeRepository(repo.id) }
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
        Task { await library.addFolder(url.path, host: Self.host) }
    }

    /// This Mac's name on the local network, e.g., `firefly.local`.
    static var host: String {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? name : name + ".local"
    }
}

/// Adding a source by its address, or editing one; its rendition and the
/// names to skip are advanced.
private struct SourceSheet: View {
    let repository: Repository?
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var rendition = ""
    @State private var skip = ","
    @State private var advanced = false

    var body: some View {
        Form {
            Section {
                if let repository {
                    LabeledContent("Address", value: repository.url.removingPercentEncoding ?? repository.url)
                } else {
                    TextField("Address", text: $url, prompt: Text("http://nas.local/Video/Movies/"))
                }
            } footer: {
                if repository == nil {
                    Text("The address of a folder of videos on a server, as a browser would open it.")
                }
            }
            Section("Advanced", isExpanded: $advanced) {
                TextField("Rendition", text: $rendition, prompt: Text("From file names"))
                Text("Name its rendition (e.g., 4K HDR) only if its files' names don't show it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Skip names starting with", text: $skip)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(repository == nil ? "Add" : "Save") {
                    if let repository {
                        library.setRepository(repository.id, rendition: rendition, skip: skip)
                    } else {
                        library.addRepository(url, rendition: rendition.isEmpty ? nil : rendition, skip: skip)
                        Task { await library.crawl() }
                    }
                    dismiss()
                }
                .disabled(repository == nil && URL(string: url)?.scheme?.hasPrefix("http") != true)
            }
        }
        .onAppear {
            if let repository {
                rendition = repository.rendition
                skip = repository.skip
                advanced = !rendition.isEmpty || skip != ","
            }
        }
    }
}

// People and devices.

private struct PeoplePane: View {
    @Environment(Library.self) private var library
    @State private var nearby: [Peer] = []
    @State private var showingSecret = false
    @State private var advanced = false
    @State private var address = ""
    @State private var key = ""

    var body: some View {
        Form {
            Section("People") {
                ForEach(library.members) { member in
                    HStack {
                        Label(member.name ?? "Someone", systemImage: "person.crop.circle")
                        if member.you { Text("You").foregroundStyle(.secondary) }
                        Spacer()
                        if member.founder {
                            Text("Founder").foregroundStyle(.secondary)
                        } else {
                            Button("Remove", role: .destructive) { library.setMember(member.key, false) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                ForEach(waiting) { peer in
                    HStack {
                        Label((peer.person.flatMap { $0.isEmpty ? nil : $0 } ?? "Someone") + "’s " + (peer.device.flatMap { $0.isEmpty ? nil : $0 } ?? "device"), systemImage: "person.crop.circle.badge.questionmark")
                        Text("wants to join").foregroundStyle(.secondary)
                        Spacer()
                        Button("Add") {
                            if let user = peer.user { library.setMember(user, true) }
                        }
                    }
                }
            }
            Section {
                ForEach(library.devices) { device in
                    HStack {
                        Label(device.name, systemImage: "desktopcomputer")
                        if device.you { Text("This Mac").foregroundStyle(.secondary) }
                    }
                }
                DisclosureGroup("Add a Device", isExpanded: $showingSecret) {
                    Text("On the new device, choose to link it to you, and enter your secret below. It makes that device act as you, so keep it to yourself.")
                        .foregroundStyle(.secondary)
                    if showingSecret { KeyField(key: library.secret ?? "") }
                    LabeledContent("Founder's key") { KeyField(key: library.status?.founder ?? "") }
                }
            } header: {
                Text("Your Devices")
            }
            Section("Advanced", isExpanded: $advanced) {
                LabeledContent("Your key") { KeyField(key: library.status?.user ?? "") }
                HStack {
                    TextField("A new member's key", text: $key, prompt: Text("To add someone by their key"))
                        .font(.body.monospaced())
                    Button("Add") {
                        library.setMember(key.trimmingCharacters(in: .whitespacesAndNewlines), true)
                        key = ""
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).count != 64)
                }
                Text("Devices off your network, such as one behind another router (NAT), can be reached by address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(nearby.filter(\.added)) { peer in
                    HStack {
                        Text(peer.url).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            library.setPeer(peer.url, false)
                            Task { nearby = await library.peers() }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Address", text: $address, prompt: Text("http://hal.example.com:8008"))
                    Button("Add") {
                        library.setPeer(address, true)
                        address = ""
                        Task { nearby = await library.peers() }
                    }
                    .disabled(URL(string: address)?.scheme?.hasPrefix("http") != true)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Who's nearby, now and then.
            while !Task.isCancelled {
                nearby = await library.peers()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Devices of this library nearby whose users aren't members yet.
    private var waiting: [Peer] {
        var seen: Set<String> = []
        return nearby.filter { $0.ours && !$0.member && !$0.added && $0.user != nil && seen.insert($0.user!).inserted }
    }
}
