#if os(tvOS)
import SwiftUI

// Settings' pages for the library's people, your devices, and its sources,
// as the Mac's panes have them, laid out as tvOS's Settings lays out a
// subpage: a list, each row explaining itself under the picture as it's
// focused. Pressing a row acts on it (asking first what to do, or whether
// to), as rows in tvOS have no buttons of their own.

/// The library's people: you, the founder, and others, any of whom (but the
/// founder) you may remove; and adding someone, by their device's code.
struct PeoplePage: View {
    @Environment(Library.self) private var library
    /// What adding someone last said (a wrong code, someone added).
    @State private var adding: String?
    /// Someone to remove, once confirmed: they come back only as someone new.
    @State private var removing: Member?
    @FocusState private var focus: String?

    var body: some View {
        SettingsPage(title: "People", explanation: explanation) {
            Form {
                Section {
                    ForEach(library.members) { member in
                        Button { if removable(member) { removing = member } } label: {
                            ValueLabel(title: member.name ?? "Someone Unnamed", value: [member.you ? "You" : nil, member.founder ? "Founder" : nil].compactMap(\.self).joined(separator: ", "))
                        }
                        .explained("member:" + member.key, hint(member), $focus)
                    }
                }
                .listRowInsets(SettingsView.rowInsets)
                NewDevices.someone(focus: $focus, said: $adding)
            }
            .scrollClipDisabled()
        }
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
            Text("They and their devices leave the library, and what they change from then on is refused. To come back, they join again as someone new; their watchlist and progress don't come back with them.")
        }
    }

    private var explanation: String {
        guard let focus else { return SettingsRow.people.explanation }
        if focus.hasPrefix(NewDevices.prefix) { return adding ?? NewDevices.someoneAbout }
        return library.members.first { "member:" + $0.key == focus }.map(hint) ?? ""
    }

    private func removable(_ member: Member) -> Bool { !member.you && !member.founder }

    private func hint(_ member: Member) -> String {
        if member.you { return "You, by the name everyone in the library sees, which you change under Names." }
        if member.founder { return "Founded the library, so stays in it until they hand it over, as they leave." }
        return "Press to remove them from the library, with their devices."
    }
}

/// Your devices, each (but this one) renamed or removed by pressing it; and
/// adding another, by its code.
struct DevicesPage: View {
    @Environment(Library.self) private var library
    /// What adding a device last said (a wrong code, a device added).
    @State private var adding: String?
    /// A device pressed: what to do with it, asked.
    @State private var acting: Device?
    /// The device whose name's keyboard is up.
    @State private var renaming: String?
    @FocusState private var focus: String?

    var body: some View {
        SettingsPage(title: "Your Devices", explanation: explanation) {
            Form {
                Section {
                    // This one first, as the one you're using.
                    ForEach(library.devices.filter(\.you) + library.devices.filter { !$0.you }) { device in
                        Button { if !device.you { acting = device } } label: {
                            ValueLabel(title: device.name, value: device.you ? "This Apple TV" : device.seenText)
                        }
                        .background {
                            KeyboardField(title: "Name", text: device.name, typing: Binding(get: { renaming == device.key }, set: { if !$0 { renaming = nil } })) {
                                library.renameDevice(device.key, $0)
                            }
                            .unseen()
                        }
                        .explained("device:" + device.key, hint(device), $focus)
                    }
                }
                .listRowInsets(SettingsView.rowInsets)
                NewDevices.device(focus: $focus, said: $adding)
            }
            .scrollClipDisabled()
        }
        .confirmationDialog(
            acting?.name ?? "",
            isPresented: Binding(get: { acting != nil }, set: { if !$0 { acting = nil } }),
            titleVisibility: .visible,
            presenting: acting
        ) { device in
            Button("Rename") { renaming = device.key }
            Button("Remove", role: .destructive) { library.removeDevice(device.key) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Removed, it leaves the library the next time it catches up, and comes back only by joining again.")
        }
    }

    private var explanation: String {
        guard let focus else { return SettingsRow.devices.explanation }
        if focus.hasPrefix(NewDevices.prefix) { return adding ?? NewDevices.deviceAbout }
        return library.devices.first { "device:" + $0.key == focus }.map(hint) ?? ""
    }

    private func hint(_ device: Device) -> String {
        device.you
            ? "This Apple TV, by the name your other devices know it by, which you change under Names."
            : "Press to rename it, or to remove it if you've given it away or no longer use it."
    }
}

/// The library's sources (but devices' downloads, theirs to manage), each
/// removed by pressing it, once confirmed; and adding a server by its
/// address. A Mac adds its folders, and sets where a source's quality
/// comes from.
struct SourcesPage: View {
    @Environment(Library.self) private var library
    @State private var typing = false
    /// A source to remove, once confirmed: its videos go on every device.
    @State private var removing: Source?
    @State private var problem: String?
    @FocusState private var focus: String?

    private var sources: [Source] { library.sources.filter { !$0.managed } }

    var body: some View {
        SettingsPage(title: "Sources", explanation: problem ?? explanation) {
            Form {
                Section {
                    ForEach(sources) { source in
                        Button { removing = source } label: {
                            // The count alone, as the page is of videos; said
                            // whole to VoiceOver.
                            ValueLabel(title: source.displayName, path: source.path, value: source.copies.formatted())
                                .accessibilityValue(source.copies == 1 ? "1 video" : "\(source.copies.formatted()) videos")
                        }
                        .explained("source:" + source.id, hint(source), $focus)
                    }
                }
                .listRowInsets(SettingsView.rowInsets)
                Section {
                    Button { problem = nil; typing = true } label: { ValueLabel(title: "Add Server", opens: true, value: "") }
                        .background {
                            KeyboardField(title: "Server Address", text: "http://", keyboard: .URL, typing: $typing, submit: add)
                                .unseen()
                        }
                        .explained("add", Self.adding, $focus)
                }
                .listRowInsets(SettingsView.rowInsets)
            }
            .scrollClipDisabled()
        }
        // Removing a source can't be undone but by adding it again and
        // looking for its videos anew.
        .confirmationDialog(
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

    static let adding = "Adds a folder of videos on a server, such as a NAS, by its address as a browser would open it: http://nas.local/Video/Movies/."

    private var explanation: String {
        guard let focus else { return SettingsRow.sources.explanation }
        return focus == "add" ? Self.adding : sources.first { "source:" + $0.id == focus }.map(hint) ?? ""
    }

    private func hint(_ source: Source) -> String {
        let gone = source.unavailable.count
        let unavailable = gone == 0 ? "" : " \(gone == 1 ? "A folder" : "\(gone) folders") of it, as on a drive unplugged, \(gone == 1 ? "is" : "are") unavailable; manage them on a Mac."
        return "Press to remove it, and its videos, on every device." + unavailable
    }

    /// Adds the server typed, and looks for its videos; one that isn't a web
    /// address is explained, to type again.
    private func add(_ typed: String) {
        let address = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address != "http://", !address.isEmpty else { return }
        guard URL(web: address) != nil else {
            problem = "“\(address)” isn't a server's address, which starts with http:// or https://, as http://nas.local/Video/Movies/ does."
            return
        }
        problem = nil
        library.addSource(address, skip: nil)
        Task { await library.crawl() }
    }
}

/// Adding a device, as a section at the end of its page's list, as the
/// Mac's Devices pane has New Devices: those nearby offering to be added
/// (as they show Join a Library), each with what kind it is as its value;
/// one pressed takes the code it shows on the full-screen keyboard's
/// digits. As this person's own (sharing their secret, so it can act as
/// them: `device`), or someone new's (`someone`). Added, it's listed above,
/// and leaves this section as it stops offering. What it last said (a
/// wrong code, a device added) is the page's explanation of its rows.
struct NewDevices: View {
    let title: String
    /// Adds the device by its code, as whose it is.
    let add: (Library, NearbyDevice, String) async -> (Paired?, String?)
    /// Names the device added, and its person, if new.
    let welcome: (Library, Paired, NearbyDevice) -> Void
    var focus: FocusState<String?>.Binding
    @Binding var said: String?

    /// Its rows' focus IDs' prefix, for the page's explanation.
    static let prefix = "new:"
    static let deviceAbout = "On your device, choose Join a Library, then choose it here and enter the code it shows. Add only your own: it can act as you, sharing your progress and watchlist."
    static let someoneAbout = "On their device, have them choose Join a Library, then choose it here and enter the code it shows. They keep their own progress and watchlist."

    /// Another of this person's devices.
    static func device(focus: FocusState<String?>.Binding, said: Binding<String?>) -> NewDevices {
        NewDevices(title: "Add a Device", add: { await $0.pairPerson($1, code: $2) }, welcome: { $0.welcome($1, from: $2) }, focus: focus, said: said)
    }

    /// Someone new's device, who joins as a member.
    static func someone(focus: FocusState<String?>.Binding, said: Binding<String?>) -> NewDevices {
        NewDevices(title: "Add Someone", add: { await $0.pairMember($1, code: $2) }, welcome: { $0.welcomeMember($1, from: $2) }, focus: focus, said: said)
    }

    @Environment(Library.self) private var library
    @State private var nearby: [NearbyDevice] = []
    /// The device whose code's keyboard is up.
    @State private var entering: String?
    @State private var pairing: NearbyDevice?

    private var offering: [NearbyDevice] { nearby.filter { $0.pairing != nil } }

    var body: some View {
        Section {
            ForEach(offering) { device in
                Button { said = nil; entering = device.url } label: {
                    // What kind of device it is as its value, at the row's
                    // end, as the system's rows keep one height.
                    ValueLabel(title: device.deviceName ?? "A New Device", opens: true, value: pairing?.url == device.url ? "Adding…" : device.model ?? "")
                }
                .disabled(pairing != nil)
                .background {
                    KeyboardField(title: "The code \(device.deviceName ?? "it") shows", text: "", keyboard: .numberPad, typing: Binding(get: { entering == device.url }, set: { if !$0 { entering = nil } })) {
                        pair(device, $0)
                    }
                    .unseen()
                }
                .focused(focus, equals: Self.prefix + device.url)
            }
            if offering.isEmpty {
                HStack(spacing: 20) {
                    ProgressView()
                    Text("Looking for new devices nearby…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(title).bold()
        }
        .listRowInsets(SettingsView.rowInsets)
        .modifier(Nearby(devices: $nearby))
    }

    private func pair(_ device: NearbyDevice, _ typed: String) {
        let code = typed.filter(\.isNumber)
        guard code.count == CodeBoxes.length else {
            said = "The code is \(CodeBoxes.length) digits, as \(device.deviceName ?? "the device") shows it. Choose it again to enter it."
            return
        }
        pairing = device
        said = "Adding \(device.deviceName ?? "the device")…"
        Task {
            let (joined, why) = await add(library, device, code)
            pairing = nil
            guard let joined else {
                said = why ?? "Couldn't add it."
                return
            }
            welcome(library, joined, device)
            nearby.removeAll { $0.id == device.id }
            said = "Added \(device.deviceName ?? "it")."
        }
    }
}

private extension View {
    /// A page's row, followed by focus for its explanation, which is its
    /// hint too.
    func explained(_ id: String, _ hint: String, _ focus: FocusState<String?>.Binding) -> some View {
        focused(focus, equals: id)
            .accessibilityHint(hint)
    }
}
#endif
