#if os(iOS) || os(tvOS)
import SwiftUI

/// The iPhone's and Apple TV's Settings, each kind of thing a page of its
/// own: names; the library's people and your devices, each added by the
/// code a device shows as it joins; its sources, servers added by
/// address; how often to look for new videos; and Leave This Library….
/// A Mac's folders and downloads stay on the Mac.
struct SettingsView: View {
    @Environment(Library.self) private var library
    @State private var leaving = Leaving()

    private var me: Member? { library.members.first(where: \.you) }

    var body: some View {
        SettingsForm {
            if let shown = leaving.problem ?? library.problem {
                SettingsSection { Text(shown).foregroundStyle(.red) }
            }
            SettingsSection(header: "Names", footer: "Names everyone in the library sees, so they know whose devices are whose.") {
                NameField(title: "This \(Library.deviceKind)", name: library.devices.first(where: \.you)?.name) { library.setDeviceName($0) }
                    .explained()
                NameField(title: "You", name: me?.name) { library.setPersonName($0) }
                    .explained()
            }
            SettingsSection(header: "Sharing", footer: "Share the library with the people you watch with, each with their own progress and lists, and add your other devices, which share yours.") {
                SettingsLink(title: "People", value: library.members.count.formatted()) { PeoplePage() }
                    .explained()
                SettingsLink(title: "Your Devices", value: library.devices.count.formatted()) { DevicesPage() }
                    .explained()
            }
            SettingsSection(header: "Library", footer: "Refresh to see videos just added, now. Looking less often lets a NAS's disks rest, as each look wakes them; this applies to everyone in the library.") {
                SettingsLink(title: "Sources", value: library.sources.filter { !$0.managed }.count.formatted()) { SourcesPage() }
                    .explained("The servers that hold your videos, such as a NAS. Add one by its address, or change or remove one.")
                Button("Refresh Library") { Task { await library.refresh() } }
                    .disabled(library.activity != nil || leaving.underWay)
                    .explained()
                if let activity = library.activity {
                    Text(activity + "…").foregroundStyle(.secondary)
                }
                ChoiceRow(title: "Look for New Videos", choices: Library.crawlChoices.map { ($0.name, $0.hours) }, selection: Binding(get: { library.crawlEvery }, set: { library.setCrawlEvery($0) }))
                    .explained()
            }
            SettingsSection(footer: "Takes this \(Library.deviceKind) out of the library, to join another or give it to someone. Its videos stay where they are.") {
                Button(leaving.underWay ? "Leaving…" : "Leave This Library…", role: .destructive, action: leaving.ask)
                    .disabled(leaving.underWay)
                    .explained()
            }
        }
        .confirmsLeaving(leaving)
    }
}

/// The library's people: you, and others, any of whom you may remove, by
/// pressing them (or on the iPhone, swiping), once confirmed; and adding
/// someone, by their device's code.
private struct PeoplePage: View {
    @Environment(Library.self) private var library
    /// Someone to remove, once confirmed: they come back only as someone new.
    @State private var removing: Member?

    var body: some View {
        SettingsForm(title: "People") {
            SettingsSection(footer: "Each keeps their own progress and lists. Press someone to remove them, with their devices.") {
                ForEach(library.members) { member in
                    Button { if !member.you { removing = member } } label: {
                        RowLabel(title: member.name ?? "Someone Unnamed", value: member.you ? "You" : "")
                    }
                    #if os(iOS)
                    .foregroundStyle(.primary)
                    .swipeActions {
                        if !member.you { Button("Remove", role: .destructive) { removing = member } }
                    }
                    #endif
                    .explained(member.you ? "You, by the name everyone in the library sees, which you change under Names." : nil)
                }
            }
            NewDevices.someone
        }
        .confirmsRemoving(member: $removing)
    }
}

/// This person's devices, this one first, each opening its own page (its
/// name, and removing it); then adding one, by its code, and sharing.
private struct DevicesPage: View {
    @Environment(Library.self) private var library

    var body: some View {
        SettingsForm(title: "Your Devices") {
            SettingsSection(footer: "Your devices share your progress and lists. Choose one to rename it, or to remove it if you've given it away or no longer use it.") {
                ForEach(library.devices.filter(\.you) + library.devices.filter { !$0.you }) { device in
                    NavigationLink { DevicePage(key: device.key) } label: { DeviceLabel(device: device) }
                        #if os(iOS)
                        .swipeActions {
                            if !device.you { Button("Remove", role: .destructive) { library.removeDevice(device.key) } }
                        }
                        #endif
                        .explained()
                }
            }
            NewDevices.device
            SettingsSection(footer: "While Cinematheque is open, your other devices catch up with this \(Library.deviceKind) directly, so what you watch here reaches them at once.") {
                Toggle("Share While Open", isOn: Bindable(library).sharing)
                    .explained()
            }
        }
    }
}

/// A device, by its kind's symbol on the iPhone, with "This iPhone" or its
/// model and when it was last seen, as Apple's own lists of devices have
/// them: under its name on the iPhone, as its value on the Apple TV.
private struct DeviceLabel: View {
    let device: Device

    private var detail: String {
        device.you ? "This \(Library.deviceKind)" : [device.model, device.seenText].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        #if os(tvOS)
        ValueLabel(title: device.name, opens: true, value: detail)
        #else
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: device.symbol)
        }
        #endif
    }
}

/// One of this person's devices: its name, typed in place, what kind it is,
/// and, but for this one, when it was last seen and removing it,
/// unconfirmed, as it can join again as easily (as on the Mac).
private struct DevicePage: View {
    let key: String
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    private var device: Device? { library.devices.first { $0.key == key } }

    var body: some View {
        SettingsForm(title: device?.name ?? "Device") {
            if let device {
                SettingsSection(footer: device.you ? "This \(Library.deviceKind), by the name your other devices know it by." : "The name everyone in the library sees it by.") {
                    NameField(title: "Name", name: device.name) { name in
                        if device.you { library.setDeviceName(name) } else { library.renameDevice(device.key, name) }
                    }
                    .explained()
                    if let model = device.model {
                        ValueRow(title: "Model", value: model).explained()
                    }
                    if !device.you {
                        ValueRow(title: "Last Seen", value: device.seenAgo ?? "Not yet").explained()
                    }
                }
                if !device.you {
                    SettingsSection(footer: "Remove it if you've given it away or no longer use it. It leaves the library the next time it catches up, and comes back by joining again.") {
                        Button("Remove Device", role: .destructive) { library.removeDevice(key) }
                            .explained()
                    }
                }
            }
        }
        // Gone (removed here or elsewhere): back to the list.
        .onChange(of: device == nil) { if device == nil { dismiss() } }
    }
}

/// Adding a device, as a section at the end of its page, as the Mac's
/// Devices pane has New Devices: those nearby offering to be added (as
/// they show Join a Library), with what kind each is; one chosen takes the
/// code it shows (on the iPhone, in a field under it on the number pad, its
/// last digit adding it; on the Apple TV, on the full-screen keyboard's
/// digits). As this person's own (sharing their secret, so it can act as
/// them: `device`), or someone new's (`someone`). Added, it's listed above,
/// and leaves this section as it stops offering.
private struct NewDevices: View {
    let title: String
    /// What to do, before anything's chosen.
    let about: String
    /// Adds the device by its code, as whose it is.
    let add: (Library, NearbyDevice, String) async -> String?

    /// Another of this person's devices.
    static var device: NewDevices {
        NewDevices(
            title: "Add a Device",
            about: "On your device, choose Join a Library; it shows here, then enter the code it shows. Add only your own: it can act as you, sharing your progress and lists.",
            add: { await $0.pairPerson($1, code: $2) })
    }

    /// Someone new's device, who joins as a member.
    static var someone: NewDevices {
        NewDevices(
            title: "Add Someone",
            about: "On their device, have them choose Join a Library; it shows here, then enter the code it shows. They keep their own progress and lists.",
            add: { await $0.pairMember($1, code: $2) })
    }

    @Environment(Library.self) private var library
    @State private var adding = AddingDevices()
    #if os(iOS)
    @FocusState private var typingCode: Bool
    #endif

    var body: some View {
        SettingsSection(header: title, footer: adding.note ?? about, problem: adding.problem) {
            ForEach(adding.offering) { device in
                // Again, it closes.
                Button { adding.choose(device) } label: { label(device) }
                    .disabled(adding.pairing != nil)
                    #if os(tvOS)
                    .background {
                        KeyboardField(title: "The code \(device.deviceName ?? "it") shows", text: "", input: .code, typing: Binding(get: { adding.entering == device.url }, set: { if !$0 { adding.entering = nil } })) {
                            adding.pair(device, $0) { await add(library, $0, $1) }
                        }
                        .unseen()
                    }
                    #else
                    .foregroundStyle(.primary)
                    #endif
                    .explained()
                #if os(iOS)
                if adding.entering == device.url { codeField(device) }
                #endif
            }
            if adding.offering.isEmpty { Looking() }
        }
        .modifier(Nearby(devices: $adding.nearby))
    }

    private func label(_ device: NearbyDevice) -> some View {
        #if os(tvOS)
        // What kind of device it is as its value, at the row's end, as the
        // system's rows keep one height.
        ValueLabel(title: device.deviceName ?? "A New Device", opens: true, value: adding.pairing?.url == device.url ? "Adding…" : device.model ?? "")
        #else
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName ?? "A New Device")
                if let model = device.model {
                    Text(model).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if adding.pairing?.url == device.url { ProgressView() }
        }
        #endif
    }

    #if os(iOS)
    /// Its code, typed in place on the number pad; the last digit adds it.
    private func codeField(_ device: NearbyDevice) -> some View {
        @Bindable var adding = adding
        return TextField("Code", text: $adding.code, prompt: Text("The \(CodeBoxes.length)-digit code it shows"))
            .typed(as: .code)
            .focused($typingCode)
            .disabled(adding.pairing != nil)
            .onAppear { typingCode = true }
            .onChange(of: adding.code) {
                let digits = String(adding.code.filter(\.isNumber).prefix(CodeBoxes.length))
                if digits != adding.code { adding.code = digits }
                if digits.count == CodeBoxes.length { adding.pair(device, digits) { await add(library, $0, $1) } }
            }
    }
    #endif
}

/// The library's sources (but devices' downloads, theirs to manage), each
/// opening a page of its settings (or on the iPhone, removed by swiping,
/// once confirmed); and adding a server by its address.
private struct SourcesPage: View {
    @Environment(Library.self) private var library
    @State private var adding = false
    @State private var removing: Source?

    private var sources: [Source] { library.sources.filter { !$0.managed } }

    var body: some View {
        SettingsForm(title: "Sources") {
            SettingsSection(footer: "The servers that hold your videos, such as a NAS. Every device in the library browses and plays them.") {
                ForEach(sources) { source in
                    NavigationLink { SourcePage(id: source.id) } label: { SourceLabel(source: source) }
                        #if os(iOS)
                        .swipeActions { Button("Remove", role: .destructive) { removing = source } }
                        #endif
                        .explained(hint(source))
                }
            }
            SettingsSection {
                #if os(tvOS)
                NavigationLink { AddServerPage() } label: { RowLabel(title: "Add Server", opens: true) }
                    .explained("Adds a folder of videos on a server, such as a NAS, by its address as a browser would open it.")
                #else
                Button("Add Server…") { adding = true }
                #endif
            }
        }
        #if os(iOS)
        .sheet(isPresented: $adding) { NavigationStack { AddServerPage() } }
        #endif
        .confirmsRemoving(source: $removing)
    }

    private func hint(_ source: Source) -> String {
        let gone = source.unavailable.count
        let unavailable = gone == 0 ? "" : " \(gone == 1 ? "A folder" : "\(gone) folders") of it, as on a drive unplugged, \(gone == 1 ? "is" : "are") unavailable."
        return "Choose it to change where its videos' quality comes from, or to remove it." + unavailable
    }
}

/// A source, by its server and folders (the middle cut short), and its
/// count of videos: under them on the iPhone, with any folders of it
/// unavailable; on the Apple TV, the count alone as its value, as the page
/// is of videos, said whole to VoiceOver.
private struct SourceLabel: View {
    let source: Source

    var body: some View {
        #if os(tvOS)
        ValueLabel(title: source.displayName, path: source.path, opens: true, value: source.copies.formatted())
            .accessibilityValue(source.videosText)
        #else
        let gone = source.unavailable.count
        VStack(alignment: .leading, spacing: 2) {
            Text(source.displayName).lineLimit(1).truncationMode(.middle)
            Text(gone == 0 ? source.videosText : "\(source.videosText), \(gone == 1 ? "a folder" : "\(gone) folders") unavailable")
                .font(.footnote).foregroundStyle(.secondary)
        }
        #endif
    }
}

/// A source's settings: its address (on the iPhone, opened in Safari),
/// where its files' quality comes from and names to skip, its unavailable
/// folders, each removable, and removing it, once confirmed.
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
        SettingsForm(title: source?.path.last ?? "Source") {
            if let source {
                SettingsSection(footer: "Where every device in the library reaches it.") {
                    #if os(tvOS)
                    ValueRow(title: "Address", value: source.reached.removingPercentEncoding ?? source.reached).explained()
                    #else
                    LabeledContent("Address") {
                        Text(source.reached.removingPercentEncoding ?? source.reached)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if let url = URL(web: source.reached) {
                        Link("Open in Safari", destination: url)
                    }
                    #endif
                    ValueRow(title: "Videos", value: source.copies.formatted()).explained()
                }
                SettingsSection(footer: "Each video's quality, so you can choose which plays, comes from its name, else the nearest folder above it that says one (as TV Shows/1080p/30 Rock/), taken whole (HQ 1080p30 Surround). If neither says it, name one for all of them.") {
                    SourceQualityPicker(from: $from, name: $quality, submit: saveQuality)
                        .onChange(of: from) { saveQuality() }
                }
                SettingsSection(header: "Skip Names Starting With", footer: "Folders and files whose names start with this are left out of the library, and titles that do too.") {
                    TextRow(title: "Prefix", text: $skip, input: .verbatim) {
                        if skip != source.skip { library.setSkip(source.id, skip) }
                    }
                    .explained()
                }
                UnavailableFolders(source: source)
                SettingsSection {
                    Button("Remove Source…", role: .destructive) { removing = source }
                        .explained("Its videos go from the library, on every device, though its files stay where they are.")
                }
            }
        }
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
        let chosen = Source.Quality(from: from, name: quality)
        if case .named(let name) = chosen, name.isEmpty { return }
        if chosen != source.qualitySetting { library.setQuality(source.id, chosen) }
    }
}

/// Adding a server by its address, how its files' quality is read, and
/// names to skip: on the iPhone, a sheet, Add in its bar; on the Apple TV,
/// a page, Add Server at its end.
private struct AddServerPage: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var from = Source.QualityFrom.path
    @State private var quality = ""
    @State private var skip = ""
    #if os(iOS)
    @FocusState private var typing: Bool
    #endif

    var body: some View {
        SettingsForm(title: "Add Server") {
            SettingsSection(footer: "The address of a folder of videos on a server, as a browser would open it.") {
                #if os(tvOS)
                TextRow(title: "Address", text: $url, input: .address)
                    .explained("The address of a folder of videos on a server, as a browser would open it: http://nas.local/Video/Movies/.")
                #else
                // Focused at once, Return adding it, as the sheet is for it.
                TextField("Server Address", text: $url, prompt: Text(verbatim: "http://nas.local/Video/Movies/"))
                    .typed(as: .address)
                    .focused($typing)
                    .submitLabel(.done)
                    .onSubmit(add)
                    .onAppear { typing = true }
                #endif
            }
            SettingsSection(footer: "Where each video's quality comes from: its name or folders, else one you name for all of them.") {
                SourceQualityPicker(from: $from, name: $quality)
            }
            SettingsSection(header: "Skip Names Starting With", footer: "Folders and files whose names start with this are left out of the library.") {
                TextRow(title: "Prefix", text: $skip, input: .verbatim)
                    .explained()
            }
            #if os(tvOS)
            SettingsSection {
                Button("Add Server", action: add)
                    .disabled(!valid)
                    .explained("Adds it, and looks for its videos.")
            }
            #endif
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Add", action: add).disabled(!valid) }
        }
        #endif
    }

    private var valid: Bool { Library.webAddress(url) != nil && !(from == .named && quality.isEmpty) }

    private func add() {
        guard valid, library.addServer(url, quality: Source.Quality(from: from, name: quality), skip: skip) else { return }
        dismiss()
    }
}
#endif
