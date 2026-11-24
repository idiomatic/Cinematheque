#if os(iOS)
import SwiftUI

/// The iPhone's settings, from Home's corner, as iOS's own apps' are: a
/// grouped list in a sheet, each kind of thing a page of its own. Names;
/// the library's people and your devices (devices by address among them),
/// each added by the code a device shows as it joins; its sources, servers
/// added by address; how often to look for new videos; and Leave This
/// Library…. A Mac's folders stay on the Mac, as an iPhone shares none.
struct SettingsSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Library.showsSyncActivity) private var showsSyncActivity = false
    @State private var path: [SettingsPage] = []
    @State private var confirmingLeave = false
    @State private var choosingSuccessor = false
    @State private var leaving = false
    @State private var problem: String?

    private var me: Member? { library.members.first(where: \.you) }
    private var others: [Member] { library.members.filter { !$0.you } }
    /// The founder's only device: leaving takes the founder with it, so it
    /// hands the library over first, or, if no one else is in it, ends it.
    private var foundersOnly: Bool { me?.founder == true && library.status?.others == 0 }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                if let shown = problem ?? library.problem {
                    Section { Text(shown).foregroundStyle(.red) }
                }
                Section {
                    NameField(title: "This iPhone", name: library.devices.first(where: \.you)?.name) { library.setName(.device, $0) }
                    NameField(title: "You", name: me?.name) { library.setName(.person, $0) }
                } header: {
                    Text("Names")
                } footer: {
                    Text("Names everyone in the library sees, so they know whose devices are whose.")
                }
                Section {
                    NavigationLink(value: SettingsPage.people) { LabeledContent("People", value: library.members.count.formatted()) }
                    NavigationLink(value: SettingsPage.devices) { LabeledContent("Your Devices", value: library.devices.count.formatted()) }
                } header: {
                    Text("Sharing")
                } footer: {
                    Text("Share the library with the people you watch with, each with their own progress and lists, and add your other devices, which share yours.")
                }
                Section {
                    NavigationLink(value: SettingsPage.sources) { LabeledContent("Sources", value: library.sources.filter { !$0.managed }.count.formatted()) }
                    Button("Refresh Library") { Task { await library.refresh() } }
                        .disabled(library.activity != nil || leaving)
                    if let activity = library.activity {
                        Text(activity + "…").foregroundStyle(.secondary)
                    }
                    Picker("Look for New Videos", selection: Binding(get: { library.crawlEvery }, set: { library.setCrawlEvery($0) })) {
                        ForEach(Library.crawlChoices, id: \.hours) { Text($0.name).tag($0.hours) }
                    }
                    .pickerStyle(.navigationLink)
                    Toggle("Show Sync Activity", isOn: $showsSyncActivity)
                } header: {
                    Text("Library")
                } footer: {
                    Text("Refresh to see videos just added, now. Looking less often lets a NAS's disks rest, as each look wakes them; this applies to everyone in the library.")
                }
                Section {
                    Button(leaving ? "Leaving…" : "Leave This Library…", role: .destructive, action: askToLeave)
                        .disabled(leaving)
                } footer: {
                    Text("Takes this iPhone out of the library, to join another or give it to someone. Its videos stay where they are.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .people: PeoplePage()
                case .devices: DevicesPage()
                case .addSomeone: AddDevicePage.someone
                case .addDevice: AddDevicePage.device
                case .sources: SourcesPage()
                case .source(let id): SourcePage(id: id)
                case .addresses: AddressesPage()
                }
            }
        }
        #if DEBUG
        // `CINEMATHEQUE_PAGE`: a page to open (adding, from its list's).
        .onAppear {
            switch Launch.page {
            case "people": path = [.people]
            case "add-someone": path = [.people, .addSomeone]
            case "devices": path = [.devices]
            case "add-device": path = [.devices, .addDevice]
            case "sources": path = [.sources]
            case "source": path = [.sources] + (library.sources.first { !$0.managed }.map { [.source($0.id)] } ?? [])
            default: break
            }
        }
        #endif
        // Hard to undo, so asked first.
        .alert(foundersOnly ? "End This Library?" : "Leave This Library?", isPresented: $confirmingLeave) {
            Button(foundersOnly ? "Leave and End It" : "Leave", role: .destructive) { if foundersOnly { end() } else { leave(successor: nil) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(foundersOnly
                ? "No one else is in this library, so once this iPhone leaves, it's gone for good. Its videos stay where they are."
                : "This iPhone leaves the library, and your other devices no longer list it. To come back, pair it again.")
        }
        // The founder's only device leaving: someone takes over first.
        .confirmationDialog("Who takes over the library?", isPresented: $choosingSuccessor, titleVisibility: .visible) {
            ForEach(others) { member in
                Button(member.name ?? "Someone Unnamed") { leave(successor: member.key) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You founded this library, and this iPhone is your only device in it, so someone takes over as its founder before it leaves.")
        }
    }

    /// Asks first: who takes over, if the founder's only device leaves with
    /// others in the library; else whether to leave.
    private func askToLeave() {
        if foundersOnly, !others.isEmpty { choosingSuccessor = true } else { confirmingLeave = true }
    }

    private func leave(successor: String?) { leaving { await library.leaveLibrary(successor: successor) } }

    /// Leaves a library no one else is in, ending it.
    private func end() { leaving { await library.endLibrary() } }

    private func leaving(_ by: @escaping () async -> String?) {
        leaving = true
        problem = nil
        Task {
            problem = await by()
            leaving = false
        }
    }
}

/// A page of Settings, pushed on its stack.
enum SettingsPage: Hashable {
    case people, devices, addSomeone, addDevice, sources, source(String), addresses
}

/// A name, typed in place, as iOS's forms take text; saved as it's
/// submitted or left, a blank one put back as it was.
private struct NameField: View {
    let title: String
    let name: String?
    let save: (String) -> Void
    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $typed, prompt: Text("Unnamed"))
                .multilineTextAlignment(.trailing)
                .focused($typing)
                .submitLabel(.done)
                .onSubmit(commit)
        }
        .onAppear { typed = name ?? "" }
        .onChange(of: name) { if !typing { typed = name ?? "" } }
        .onChange(of: typing) { if !typing { commit() } }
    }

    private func commit() {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == name { typed = name ?? "" } else { save(trimmed) }
    }
}

/// The library's people: you, the founder, and others, any of whom (but the
/// founder) you may remove, by pressing them or swiping; and adding someone,
/// by their device's code.
private struct PeoplePage: View {
    @Environment(Library.self) private var library
    /// Someone to remove, once confirmed: they come back only as someone new.
    @State private var removing: Member?

    var body: some View {
        List {
            Section {
                ForEach(library.members) { member in
                    Button { if removable(member) { removing = member } } label: {
                        LabeledContent(member.name ?? "Someone Unnamed", value: [member.you ? "You" : nil, member.founder ? "Founder" : nil].compactMap(\.self).joined(separator: ", "))
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        if removable(member) {
                            Button("Remove", role: .destructive) { removing = member }
                        }
                    }
                }
            } footer: {
                Text("Each keeps their own progress and lists. Press someone to remove them, with their devices.")
            }
            Section {
                NavigationLink("Add Someone", value: SettingsPage.addSomeone)
            }
        }
        .navigationTitle("People")
        // Hard to undo, so asked first.
        .confirmationDialog(
            "Remove \(removing?.name ?? "Them")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { member in
            Button("Remove", role: .destructive) { library.removeMember(member.key) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They and their devices leave the library, and what they change from then on is refused. To come back, they join again as someone new; their lists and progress don't come back with them.")
        }
    }

    private func removable(_ member: Member) -> Bool { !member.you && !member.founder }
}

/// Your devices, this one first, each other renamed or removed by pressing
/// it (asked which) or swiping; adding another, by its code; and sharing
/// the library while the app runs.
private struct DevicesPage: View {
    @Environment(Library.self) private var library
    /// A device pressed: what to do with it, asked.
    @State private var acting: Device?
    @State private var renaming: Device?
    @State private var name = ""
    @State private var sharing = true

    var body: some View {
        List {
            Section {
                ForEach(library.devices.filter(\.you) + library.devices.filter { !$0.you }) { device in
                    // Each by its kind's symbol, "This iPhone" or its model
                    // under its name, as Apple's own list of devices has them.
                    Button { if !device.you { acting = device } } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                if let caption = device.you ? "This iPhone" : device.model {
                                    Text(caption).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: device.symbol)
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        if !device.you {
                            Button("Remove", role: .destructive) { library.removeDevice(device.key) }
                            Button("Rename") { rename(device) }
                        }
                    }
                }
            } footer: {
                Text("Your devices share your progress and lists. Press one to rename it, or to remove it if you've given it away or no longer use it.")
            }
            Section {
                NavigationLink("Add a Device", value: SettingsPage.addDevice)
            }
            Section {
                Toggle("Share While Open", isOn: $sharing)
                    .onChange(of: sharing) { library.sharing = sharing }
            } footer: {
                Text("While Cinematheque is open, your other devices catch up with this iPhone directly, so what you watch here reaches them at once.")
            }
            // As the Mac's Devices pane has them, under its Advanced.
            Section {
                NavigationLink("Devices by Address", value: SettingsPage.addresses)
            } footer: {
                Text("For a device that isn't found nearby, such as one at another home.")
            }
        }
        .navigationTitle("Your Devices")
        .onAppear { sharing = library.sharing }
        .confirmationDialog(
            acting?.name ?? "",
            isPresented: Binding(get: { acting != nil }, set: { if !$0 { acting = nil } }),
            titleVisibility: .visible,
            presenting: acting
        ) { device in
            Button("Rename") { rename(device) }
            Button("Remove", role: .destructive) { library.removeDevice(device.key) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Removed, it leaves the library the next time it catches up, and comes back only by joining again.")
        }
        .alert("Rename \(renaming?.name ?? "It")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { device in
            TextField("Name", text: $name)
            Button("Rename") { library.renameDevice(device.key, name) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func rename(_ device: Device) {
        name = device.name
        renaming = device
    }
}

/// Adding a device: one nearby offering to be added (as it shows Join a
/// Library), with what kind it is under its name, chosen, then the code it
/// shows, typed. As this person's own (sharing their secret, so it can act
/// as them: `device`), or someone new's (`someone`). Added, it goes back to
/// the list, where the device now is.
private struct AddDevicePage: View {
    let title: String
    /// What to do, before anything's chosen.
    let about: String
    /// Adds the device by its code, as whose it is.
    let add: (Library, NearbyDevice, String) async -> (Paired?, String?)
    /// Names the device added, and its person, if new.
    let welcome: (Library, Paired, NearbyDevice) -> Void

    /// Another of this person's devices.
    static var device: AddDevicePage {
        AddDevicePage(
            title: "Add a Device",
            about: "On your device, choose Join a Library, then choose it here and enter the code it shows. Add only your own: it can act as you, sharing your progress and lists.",
            add: { await $0.pairPerson($1, code: $2) },
            welcome: { $0.welcome($1, from: $2) })
    }

    /// Someone new's device, who joins as a member.
    static var someone: AddDevicePage {
        AddDevicePage(
            title: "Add Someone",
            about: "On their device, have them choose Join a Library, then choose it here and enter the code it shows. They keep their own progress and lists.",
            add: { await $0.pairMember($1, code: $2) },
            welcome: { $0.welcomeMember($1, from: $2) })
    }

    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var nearby: [NearbyDevice] = []
    /// The device whose code is asked for.
    @State private var entering: NearbyDevice?
    @State private var code = ""
    @State private var pairing: NearbyDevice?
    @State private var problem: String?

    private var offering: [NearbyDevice] { nearby.filter { $0.pairing != nil } }

    var body: some View {
        List {
            Section {
                ForEach(offering) { device in
                    Button {
                        problem = nil
                        code = ""
                        entering = device
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.deviceName ?? "A New Device")
                                if let model = device.model {
                                    Text(model).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if pairing?.url == device.url { ProgressView() }
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(pairing != nil)
                }
                if offering.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for new devices nearby…").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if let problem { Text(problem).foregroundStyle(.red) } else { Text(about) }
            }
        }
        .navigationTitle(title)
        .modifier(Nearby(devices: $nearby))
        .alert("Enter the Code", isPresented: Binding(get: { entering != nil }, set: { if !$0 { entering = nil } }), presenting: entering) { device in
            TextField("Code", text: $code)
                .keyboardType(.numberPad)
            Button("Add") { pair(device, code) }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("The \(CodeBoxes.length)-digit code \(device.deviceName ?? "the device") shows.")
        }
        #if DEBUG
        // `CINEMATHEQUE_PAIR`: a code for the first device found.
        .task(id: offering.first?.url) {
            if let device = offering.first, let code = Launch.pair { pair(device, code) }
        }
        #endif
    }

    private func pair(_ device: NearbyDevice, _ typed: String) {
        let code = typed.filter(\.isNumber)
        guard code.count == CodeBoxes.length else {
            problem = "The code is \(CodeBoxes.length) digits, as \(device.deviceName ?? "the device") shows it. Choose it again to enter it."
            return
        }
        pairing = device
        problem = nil
        Task {
            let (joined, why) = await add(library, device, code)
            pairing = nil
            guard let joined else {
                problem = why ?? "Couldn't add it."
                return
            }
            welcome(library, joined, device)
            dismiss()
        }
    }
}

/// The library's sources (but devices' downloads, theirs to manage), each
/// opening a page of its settings, or removed by swiping, once confirmed;
/// and adding a server by its address.
private struct SourcesPage: View {
    @Environment(Library.self) private var library
    @State private var adding = false
    @State private var removing: Source?

    private var sources: [Source] { library.sources.filter { !$0.managed } }

    var body: some View {
        List {
            Section {
                ForEach(sources) { source in
                    NavigationLink(value: SettingsPage.source(source.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName).lineLimit(1).truncationMode(.middle)
                            Text(videos(source)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { removing = source }
                    }
                }
            } footer: {
                Text("The servers that hold your videos, such as a NAS. Every device in the library browses and plays them.")
            }
            Section {
                Button("Add Server…") { adding = true }
            }
        }
        .navigationTitle("Sources")
        .sheet(isPresented: $adding) { AddServerSheet() }
        .removingSource($removing)
        #if DEBUG
        .onAppear {
            if let server = Launch.server {
                library.addSource(server, skip: nil)
                Task { await library.crawl() }
            }
        }
        #endif
    }

    /// Its count of videos, and any folders of it unavailable.
    private func videos(_ source: Source) -> String {
        let count = source.copies == 1 ? "1 video" : "\(source.copies.formatted()) videos"
        let gone = source.unavailable.count
        return gone == 0 ? count : "\(count), \(gone == 1 ? "a folder" : "\(gone) folders") unavailable"
    }
}

/// A source's settings: its address (opened in Safari), where its files'
/// quality comes from and names to skip, its unavailable folders, each
/// removable, and removing it.
private struct SourcePage: View {
    let id: String
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var from = Source.QualityFrom.names
    @State private var quality = ""
    @State private var skip = ""
    @State private var removing: Source?

    private var source: Source? { library.sources.first { $0.id == id } }

    var body: some View {
        Form {
            if let source {
                Section {
                    LabeledContent("Address") {
                        Text(source.url.removingPercentEncoding ?? source.url)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if let url = URL(web: source.url) {
                        Link("Open in Safari", destination: url)
                    }
                    LabeledContent("Videos", value: source.copies.formatted())
                }
                Section {
                    Picker("Quality", selection: $from) {
                        Text("From File Names").tag(Source.QualityFrom.names)
                        Text("From the Folder Under It").tag(Source.QualityFrom.folder)
                        Text("Named").tag(Source.QualityFrom.named)
                        // Kept as it is, unless another is chosen.
                        if from == .unknown { Text("Set by a Newer Version").tag(Source.QualityFrom.unknown) }
                    }
                    .onChange(of: from) { saveQuality() }
                    if from == .named {
                        LabeledContent("Name") {
                            TextField("Name", text: $quality, prompt: Text("4K HDR"))
                                .multilineTextAlignment(.trailing)
                                .onSubmit(saveQuality)
                        }
                    }
                } footer: {
                    Text("If the videos' names don't say their quality, set it here so you can choose which quality plays: from the folder each is in, just under this one (as Movies/HQ 1080p/Alien.m4v), or one name for all of them.")
                }
                // Its name a heading, too long to sit beside what's typed.
                Section {
                    TextField("Skip", text: $skip, prompt: Text("None"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { library.setSkip(source.id, skip) }
                } header: {
                    Text("Skip Names Starting With")
                } footer: {
                    Text("Folders and files whose names start with this are left out of the library, and titles that do too.")
                }
                if !source.unavailable.isEmpty {
                    Section {
                        ForEach(source.unavailable, id: \.dir) { gone in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(gone.name)
                                    Text("Since \(gone.date.formatted(date: .abbreviated, time: .omitted))").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Remove Videos", role: .destructive) { library.removeUnavailable(source.id, gone.dir) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Unavailable")
                    } footer: {
                        Text("Folders that are empty now, as when a drive is unplugged. Their videos stay, dimmed, so nothing's lost while it's away; remove them if it's gone for good. After a year, they go on their own.")
                    }
                }
                Section {
                    Button("Remove Source…", role: .destructive) { removing = source }
                }
            }
        }
        .navigationTitle(source?.path.last ?? "Source")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let source else { return }
            from = source.quality_from
            quality = source.quality
            skip = source.skip
        }
        // Gone (removed here or elsewhere): back to the list.
        .onChange(of: source == nil) { if source == nil { dismiss() } }
        .removingSource($removing)
    }

    /// Saves where the quality comes from, once it can be: a name, once
    /// one's typed.
    private func saveQuality() {
        guard let source else { return }
        let chosen: Source.Quality = switch from {
        case .names: .names
        case .folder: .folder
        case .named: .named(quality)
        case .unknown: .unknown
        }
        if case .named(let name) = chosen, name.isEmpty { return }
        if chosen != source.qualitySetting { library.setQuality(source.id, chosen) }
    }
}

/// Adding a server by its address, and how its files' quality is read.
private struct AddServerSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var from = Source.QualityFrom.names
    @State private var quality = ""
    @State private var skip = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server Address", text: $url, prompt: Text(verbatim: "http://nas.local/Video/Movies/"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit(add)
                } footer: {
                    Text("The address of a folder of videos on a server, as a browser would open it.")
                }
                Section {
                    Picker("Quality", selection: $from) {
                        Text("From File Names").tag(Source.QualityFrom.names)
                        Text("From the Folder Under It").tag(Source.QualityFrom.folder)
                        Text("Named").tag(Source.QualityFrom.named)
                    }
                    if from == .named {
                        LabeledContent("Name") {
                            TextField("Name", text: $quality, prompt: Text("4K HDR")).multilineTextAlignment(.trailing)
                        }
                    }
                }
                Section("Skip Names Starting With") {
                    TextField("Skip", text: $skip, prompt: Text("None"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(!valid)
                }
            }
            .onAppear { typing = true }
        }
    }

    private var valid: Bool { webAddress(url) != nil && !(from == .named && quality.isEmpty) }

    private func add() {
        guard valid, let url = webAddress(url) else { return }
        library.addSource(url, skip: skip.isEmpty ? nil : skip)
        switch from {
        case .folder: library.setQuality(url, .folder)
        case .named: library.setQuality(url, .named(quality))
        case .names, .unknown: break
        }
        Task { await library.crawl() }
        dismiss()
    }
}

/// Devices this one syncs with by address, as one it can't find nearby (at
/// another home, or behind another router); on this iPhone only.
private struct AddressesPage: View {
    @Environment(Library.self) private var library
    @State private var nearby: [NearbyDevice] = []
    @State private var address = ""

    var body: some View {
        List {
            Section {
                ForEach(nearby.filter(\.added)) { device in
                    HStack {
                        Text(device.url).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Forget") { forget(device.url) }
                            .buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button("Forget", role: .destructive) { forget(device.url) }
                    }
                }
                HStack {
                    TextField("Device Address", text: $address, prompt: Text(verbatim: "http://hal.local:8008/"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(.borderless)
                        .disabled(webAddress(address) == nil)
                }
            } footer: {
                Text(verbatim: "Add a device by address if it isn't found nearby, such as one at another home or behind another router: http://hal.example.com:8008/. This iPhone syncs with it too.")
            }
        }
        .navigationTitle("Devices by Address")
        .task { nearby = await library.nearby() }
    }

    private func add() {
        guard let url = webAddress(address) else { return }
        library.addDeviceAddress(url)
        address = ""
        Task { nearby = await library.nearby() }
    }

    private func forget(_ url: String) {
        library.forgetDeviceAddress(url)
        Task { nearby = await library.nearby() }
    }
}

/// An address as typed, made a web address: `http://` put first if it names
/// no scheme ("nas.local/Video/Movies/"); nil if it isn't one even so.
private func webAddress(_ typed: String) -> String? {
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let address = trimmed.contains("://") ? trimmed : "http://" + trimmed
    return URL(web: address) != nil ? address : nil
}

private extension View {
    /// Asks before removing a source: it can't be undone but by adding it
    /// again and looking for its videos anew.
    func removingSource(_ removing: Binding<Source?>) -> some View {
        modifier(RemovingSource(removing: removing))
    }
}

private struct RemovingSource: ViewModifier {
    @Binding var removing: Source?
    @Environment(Library.self) private var library

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove “\(removing?.displayName ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { source in
            Button("Remove", role: .destructive) { library.removeSource(source.id) }
            Button("Cancel", role: .cancel) {}
        } message: { source in
            Text("\(source.copies == 1 ? "Its one video goes" : "Its \(source.copies.formatted()) videos go") from the library, on every device, though its files stay where they are. You can add it again.")
        }
    }
}
#endif
