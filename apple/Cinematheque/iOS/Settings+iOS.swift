#if os(iOS)
import SwiftUI

/// The iPhone's settings, from Home's corner, as iOS's own apps' are: a
/// grouped list in a sheet, each kind of thing a page of its own. Names;
/// the library's people and your devices, each added by the code a device
/// shows as it joins; its sources, servers
/// added by address; how often to look for new videos; and Leave This
/// Library…. A Mac's folders stay on the Mac, as an iPhone shares none.
struct SettingsSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsPage] = []
    @State private var leaving = Leaving()

    private var me: Member? { library.members.first(where: \.you) }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                if let shown = leaving.problem ?? library.problem {
                    Section { Text(shown).foregroundStyle(.red) }
                }
                Section {
                    NameField(title: "This iPhone", name: library.devices.first(where: \.you)?.name) { library.setDeviceName($0) }
                    NameField(title: "You", name: me?.name) { library.setPersonName($0) }
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
                        .disabled(library.activity != nil || leaving.underWay)
                    if let activity = library.activity {
                        Text(activity + "…").foregroundStyle(.secondary)
                    }
                    Picker("Look for New Videos", selection: Binding(get: { library.crawlEvery }, set: { library.setCrawlEvery($0) })) {
                        ForEach(Library.crawlChoices, id: \.hours) { Text($0.name).tag($0.hours) }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Library")
                } footer: {
                    Text("Refresh to see videos just added, now. Looking less often lets a NAS's disks rest, as each look wakes them; this applies to everyone in the library.")
                }
                Section {
                    Button(leaving.underWay ? "Leaving…" : "Leave This Library…", role: .destructive, action: leaving.ask)
                        .disabled(leaving.underWay)
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
                case .device(let key): DevicePage(key: key)
                case .sources: SourcesPage()
                case .source(let id): SourcePage(id: id)
                }
            }
        }
        .confirmsLeaving(leaving)
    }
}

/// A page of Settings, pushed on its stack.
enum SettingsPage: Hashable {
    case people, devices, device(String), sources, source(String)
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

/// The library's people: you, and others, any of whom you may remove, by
/// pressing them or swiping; and adding someone, by their device's code.
private struct PeoplePage: View {
    @Environment(Library.self) private var library
    /// Someone to remove, once confirmed: they come back only as someone new.
    @State private var removing: Member?

    var body: some View {
        List {
            Section {
                ForEach(library.members) { member in
                    Button { if removable(member) { removing = member } } label: {
                        LabeledContent(member.name ?? "Someone Unnamed", value: member.you ? "You" : "")
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
            NewDevices.someone
        }
        .navigationTitle("People")
        .confirmsRemoving(member: $removing)
    }

    private func removable(_ member: Member) -> Bool { !member.you }
}

/// This person's devices, this iPhone first, each opening its own page
/// (its name, and removing it); swiping one removes it; then adding one, by
/// its code, and sharing.
private struct DevicesPage: View {
    @Environment(Library.self) private var library
    @State private var sharing = true

    var body: some View {
        List {
            Section {
                ForEach(library.devices.filter(\.you) + library.devices.filter { !$0.you }) { device in
                    // Each by its kind's symbol, "This iPhone" or its model
                    // under its name, as Apple's own list of devices has them.
                    NavigationLink(value: SettingsPage.device(device.key)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.you ? "This iPhone" : [device.model, device.seenText].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: device.symbol)
                        }
                    }
                    .swipeActions {
                        if !device.you {
                            Button("Remove", role: .destructive) { library.removeDevice(device.key) }
                        }
                    }
                }
            } footer: {
                Text("Your devices share your progress and lists. Choose one to rename it, or to remove it if you've given it away or no longer use it.")
            }
            NewDevices.device
            Section {
                Toggle("Share While Open", isOn: $sharing)
                    .onChange(of: sharing) { library.sharing = sharing }
            } footer: {
                Text("While Cinematheque is open, your other devices catch up with this iPhone directly, so what you watch here reaches them at once.")
            }
        }
        .navigationTitle("Your Devices")
        .onAppear { sharing = library.sharing }
    }
}

/// One of this person's devices: its name, typed in place, what kind it is,
/// and, but for this iPhone, removing it, unconfirmed, as it can join again
/// as easily (as on the Mac).
private struct DevicePage: View {
    let key: String
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    private var device: Device? { library.devices.first { $0.key == key } }

    var body: some View {
        Form {
            if let device {
                Section {
                    NameField(title: "Name", name: device.name) { name in
                        if device.you { library.setDeviceName(name) } else { library.renameDevice(device.key, name) }
                    }
                    if let model = device.model {
                        LabeledContent("Model", value: model)
                    }
                    if !device.you {
                        LabeledContent("Last Seen", value: device.seenAgo ?? "Not yet")
                    }
                } footer: {
                    Text(device.you ? "This iPhone, by the name your other devices know it by." : "The name everyone in the library sees it by.")
                }
                if !device.you {
                    Section {
                        Button("Remove Device", role: .destructive) { library.removeDevice(key) }
                    } footer: {
                        Text("Remove it if you've given it away or no longer use it. It leaves the library the next time it catches up, and comes back by joining again.")
                    }
                }
            }
        }
        .navigationTitle(device?.name ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
        // Gone (removed here or elsewhere): back to the list.
        .onChange(of: device == nil) { if device == nil { dismiss() } }
    }
}

/// Adding a device, in its page's list, as the Mac's Devices pane has New
/// Devices: those nearby offering to be added (as they show Join a
/// Library), with what kind each is under its name; one chosen opens a
/// field under it for the code it shows, its last digit adding it. As this person's own (sharing their secret, so it can act
/// as them: `device`), or someone new's (`someone`). Added, it's listed
/// above, with the rest, and leaves this section as it stops offering.
private struct NewDevices: View {
    let title: String
    /// What to do, before anything's chosen.
    let about: String
    /// Adds the device by its code, as whose it is.
    let add: (Library, NearbyDevice, String) async -> (Paired?, String?)
    /// Names the device added, and its person, if new.
    let welcome: (Library, Paired, NearbyDevice) -> Void

    /// Another of this person's devices.
    static var device: NewDevices {
        NewDevices(
            title: "Add a Device",
            about: "On your device, choose Join a Library; it shows here, then enter the code it shows. Add only your own: it can act as you, sharing your progress and lists.",
            add: { await $0.pairPerson($1, code: $2) },
            welcome: { $0.welcome($1, from: $2) })
    }

    /// Someone new's device, who joins as a member.
    static var someone: NewDevices {
        NewDevices(
            title: "Add Someone",
            about: "On their device, have them choose Join a Library; it shows here, then enter the code it shows. They keep their own progress and lists.",
            add: { await $0.pairMember($1, code: $2) },
            welcome: { $0.welcomeMember($1, from: $2) })
    }

    @Environment(Library.self) private var library
    @State private var nearby: [NearbyDevice] = []
    /// The device whose code is asked for, in a field under it.
    @State private var entering: NearbyDevice?
    @State private var code = ""
    @FocusState private var typingCode: Bool
    @State private var pairing: NearbyDevice?
    @State private var problem: String?
    @State private var added: String?

    private var offering: [NearbyDevice] { nearby.filter { $0.pairing != nil } }

    var body: some View {
        Section {
            ForEach(offering) { device in
                Button {
                    problem = nil
                    added = nil
                    code = ""
                    // Again, it closes.
                    entering = entering?.url == device.url ? nil : device
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
                // Its code, typed in place on the number pad; the last digit
                // adds it.
                if entering?.url == device.url {
                    TextField("Code", text: $code, prompt: Text("The \(CodeBoxes.length)-digit code it shows"))
                        .keyboardType(.numberPad)
                        .focused($typingCode)
                        .disabled(pairing != nil)
                        .onAppear { typingCode = true }
                        .onChange(of: code) {
                            let digits = String(code.filter(\.isNumber).prefix(CodeBoxes.length))
                            if digits != code { code = digits }
                            if digits.count == CodeBoxes.length { pair(device, digits) }
                        }
                }
            }
            if offering.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Looking for new devices nearby…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let problem { Text(problem).foregroundStyle(.red) } else { Text(added ?? about) }
        }
        .modifier(Nearby(devices: $nearby))
    }

    private func pair(_ device: NearbyDevice, _ typed: String) {
        let code = typed.filter(\.isNumber)
        guard code.count == CodeBoxes.length else {
            problem = "The code is \(CodeBoxes.length) digits, as \(device.deviceName ?? "the device") shows it."
            return
        }
        pairing = device
        problem = nil
        Task {
            let (joined, why) = await add(library, device, code)
            pairing = nil
            guard let joined else {
                // Cleared, to type again.
                self.code = ""
                problem = why ?? "Couldn't add it."
                return
            }
            entering = nil
            welcome(library, joined, device)
            // Gone from here as it stops offering, it's listed above.
            nearby.removeAll { $0.id == device.id }
            added = "Added \(device.deviceName ?? "it")."
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
        .confirmsRemoving(source: $removing)
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
    @State private var from = Source.QualityFrom.path
    @State private var quality = ""
    @State private var skip = ""
    @State private var removing: Source?

    private var source: Source? { library.sources.first { $0.id == id } }

    var body: some View {
        Form {
            if let source {
                Section {
                    LabeledContent("Address") {
                        Text(source.reached.removingPercentEncoding ?? source.reached)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if let url = URL(web: source.reached) {
                        Link("Open in Safari", destination: url)
                    }
                    LabeledContent("Videos", value: source.copies.formatted())
                }
                Section {
                    Picker("Quality", selection: $from) {
                        Text("From Names and Folders").tag(Source.QualityFrom.path)
                        Text("Named").tag(Source.QualityFrom.named)
                        // Kept as it is, unless another is chosen: a newer version's.
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
                    Text("Each video's quality, so you can choose which plays, comes from its name, else the nearest folder above it that says one (as TV Shows/1080p/30 Rock/), taken whole (HQ 1080p30 Surround). If neither says it, name one for all of them.")
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
        .confirmsRemoving(source: $removing)
    }

    /// Saves where the quality comes from, once it can be: a name, once
    /// one's typed.
    private func saveQuality() {
        guard let source else { return }
        let chosen: Source.Quality = switch from {
        case .path: .path
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
    @State private var from = Source.QualityFrom.path
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
                        Text("From Names and Folders").tag(Source.QualityFrom.path)
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
        case .named: library.setQuality(url, .named(quality))
        case .path, .unknown: break
        }
        Task { await library.crawl() }
        dismiss()
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
#endif
