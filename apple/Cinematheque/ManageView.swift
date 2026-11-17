import SwiftUI

/// Managing the library, in Settings: its repositories, its members, and
/// this device.
struct ManageView: View {
    var body: some View {
        TabView {
            Tab("Repositories", systemImage: "externaldrive.connected.to.line.below") { RepositoriesPane() }
            Tab("Members", systemImage: "person.2") { MembersPane() }
            Tab("This Device", systemImage: "laptopcomputer") { DevicePane() }
        }
        .frame(width: 640, height: 440)
    }
}

private struct RepositoriesPane: View {
    @Environment(Library.self) private var library
    @State private var selection: Repository.ID?
    @State private var editing: Repository?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("Repositories are folders of videos your servers share over HTTP, such as a NAS's. Add each folder that holds one rendition, and name it.")
                .foregroundStyle(.secondary)
            Table(library.repositories, selection: $selection) {
                TableColumn("URL") { Text($0.url.removingPercentEncoding ?? $0.url).lineLimit(1).truncationMode(.middle) }
                TableColumn("Rendition") { Text($0.rendition.isEmpty ? "From names" : $0.rendition) }
                    .width(min: 80, ideal: 120)
                TableColumn("Copies") { Text("\($0.copies)").monospacedDigit() }
                    .width(56)
            }
            .contextMenu(forSelectionType: Repository.ID.self) { ids in
                if let id = ids.first, let repo = library.repositories.first(where: { $0.id == id }) {
                    Button("Edit…") { editing = repo }
                    Button("Remove", role: .destructive) { library.removeRepository(id) }
                }
            } primaryAction: { ids in
                editing = library.repositories.first { $0.id == ids.first }
            }
            HStack {
                Button("Add…", systemImage: "plus") { adding = true }
                Button("Remove", systemImage: "minus") {
                    if let selection { library.removeRepository(selection) }
                }
                .disabled(selection == nil)
                Spacer()
                if let activity = library.activity {
                    ProgressView().controlSize(.small)
                    Text(activity + "…").foregroundStyle(.secondary)
                } else {
                    Button("Crawl Now") { Task { await library.crawl() } }
                        .disabled(library.repositories.isEmpty)
                }
            }
        }
        .padding()
        .sheet(isPresented: $adding) { RepositorySheet(repository: nil) }
        .sheet(item: $editing) { RepositorySheet(repository: $0) }
    }
}

private struct RepositorySheet: View {
    let repository: Repository?
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var rendition = ""
    @State private var skip = ","

    var body: some View {
        Form {
            if let repository {
                LabeledContent("URL", value: repository.url.removingPercentEncoding ?? repository.url)
            } else {
                TextField("URL", text: $url, prompt: Text("http://nas.local/Video/Movies/"))
            }
            TextField("Rendition", text: $rendition, prompt: Text("From file names"))
            TextField("Skip names starting with", text: $skip)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(repository == nil ? "Add" : "Save") {
                    if let repository {
                        library.setRepository(repository.id, rendition: rendition, skip: skip)
                    } else {
                        library.addRepository(url, rendition: rendition.isEmpty ? nil : rendition, skip: skip)
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
            }
        }
    }
}

private struct MembersPane: View {
    @Environment(Library.self) private var library
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("Members share the library. To add someone, paste the key their device shows when they join.")
                .foregroundStyle(.secondary)
            List(library.members) { member in
                HStack {
                    Text(member.key).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if member.you { Text("You").foregroundStyle(.secondary) }
                    if member.founder { Text("Founder").foregroundStyle(.secondary) }
                }
                .contextMenu {
                    if !member.founder {
                        Button("Remove", role: .destructive) { library.setMember(member.key, false) }
                    }
                }
            }
            HStack {
                TextField("A new member's key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Button("Add") {
                    library.setMember(key.trimmingCharacters(in: .whitespacesAndNewlines), true)
                    key = ""
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).count != 64)
            }
        }
        .padding()
    }
}

private struct DevicePane: View {
    @Environment(Library.self) private var library
    @State private var showingSecret = false
    @State private var peer = ""

    var body: some View {
        Form {
            Section("You") {
                LabeledContent("Your key") { KeyField(key: library.status?.user ?? "") }
                LabeledContent("Library") { KeyField(key: library.status?.library ?? "") }
                LabeledContent("Founder's key") { KeyField(key: library.status?.founder ?? "") }
            }
            Section("Your other devices") {
                Text("Your secret makes another device act as you. Keep it to yourself.")
                    .foregroundStyle(.secondary)
                if showingSecret {
                    KeyField(key: library.secret ?? "")
                } else {
                    Button("Show Secret") { showingSecret = true }
                }
            }
            Section("Syncing") {
                Text("Cinematheque syncs with peers it finds on your network. For one it can't find, enter its address.")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Peer", text: $peer, prompt: Text("http://hal.local:8008"))
                    Button(peer.isEmpty ? "Sync Now" : "Sync") {
                        Task { await library.sync(peer.isEmpty ? nil : peer) }
                    }
                    .disabled(library.activity != nil)
                }
            }
        }
        .formStyle(.grouped)
    }
}
